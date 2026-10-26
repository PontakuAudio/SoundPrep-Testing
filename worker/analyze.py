#!/usr/bin/env python3
"""Cancelable, offline EBU R128 analysis. No REAPER API runs on this thread.

FFmpeg measures 400 ms momentary windows at 100 ms intervals. Mono is measured
as dual mono (the audition path outputs stereo); a 400 ms zero tail also gives
short effects a complete window. This is an explicit, versioned cache policy.

Multichannel v2 measures an explicit stereo downmix, the loudest dual-mono
channel, or dual-mono AmbiX W. Original-channel modes retain the maximum true
peak of every channel. Above 64 channels, uncompressed PCM/float WAV or RF64
is required: bounded extraction avoids FFmpeg's channel-conversion limit.
"""
from __future__ import annotations
import argparse
import array
import json
import math
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import time

PROFILE = "ffmpeg-ebur128-m100ms-dualmono-zero-tail-v1"
MULTICHANNEL_PROFILE = "ffmpeg-ebur128-m100ms-multichannel-v2"
BASES = {"downmix_discrete", "downmix_ambix", "loudest_channel", "ambix_w"}
# FFmpeg f_ebur128.c SET_META uses "%.3f" for linear peak amplitudes.
# A reported zero is below 0.0005; 0.001 is a conservative upper bound.
ROUNDED_PEAK_UPPER_BOUND = 0.001


def atomic_json(path: Path, value: dict) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2,
                                    allow_nan=False) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def identity(path: Path) -> tuple[int, int]:
    stat = path.stat()
    return stat.st_size, stat.st_mtime_ns


def parse_metadata(lines, momentary_before=None, check=None, momentary_windows=None,
                   peak_observation=None) -> tuple[float | None, float | None]:
    momentary, peak = None, 0.0
    timestamp, frame = 0.0, 0
    for index, line in enumerate(lines):
        if check is not None and index % 4096 == 0:
            check()
        if momentary_before is not None and "pts_time:" in line:
            timestamp = float(line.split("pts_time:", 1)[1].split()[0])
        if momentary_windows is not None and line.startswith("frame:"):
            frame = int(line.split(":", 1)[1].split()[0])
        if "lavfi.r128.M=" in line:
            value = float(line.split("lavfi.r128.M=", 1)[1].strip())
            eligible = momentary_before is None or timestamp < momentary_before
            if momentary_windows is not None:
                hops, warmup, w_only = momentary_windows
                eligible = frame % hops >= warmup and (not w_only or frame < hops)
            if math.isfinite(value) and eligible:
                momentary = max(momentary, value) if momentary is not None else value
        elif re.search(r"lavfi\.r128\.true_peaks_ch\d+=", line):
            value = float(line.rsplit("=", 1)[1].strip())
            if math.isfinite(value):
                peak = max(peak, value)
                if peak_observation is not None and value == 0:
                    peak_observation["reported_zero"] = True
        elif "lavfi.r128.true_peak=" in line:
            value = float(line.rsplit("=", 1)[1].strip())
            if math.isfinite(value):
                peak = max(peak, value)
                if peak_observation is not None and value == 0:
                    peak_observation["reported_zero"] = True
    return momentary, (20 * math.log10(peak) if peak > 0 else None)


def analysis_spec(request, channels):
    spec = request.get("analysis")
    if spec is None:
        if channels not in (1, 2):
            raise ValueError("Only mono/stereo audio is supported by this analysis profile")
        return None
    if not isinstance(spec, dict) or set(spec) != {"revision", "source_channels", "basis"}:
        raise ValueError("Invalid multichannel analysis descriptor")
    count, basis = spec["source_channels"], spec["basis"]
    if (type(spec["revision"]) is not int or spec["revision"] != 1
            or type(count) is not int or not 3 <= count <= 128
            or not isinstance(basis, str) or basis not in BASES):
        raise ValueError("Invalid multichannel analysis revision, channel count or basis")
    if channels != count:
        raise ValueError("Source channel count changed before analysis")
    if basis in ("downmix_ambix", "ambix_w") and math.isqrt(count) ** 2 != count:
        raise ValueError("AmbiX analysis requires a complete square channel count")
    return dict(spec)


def multichannel_graph(spec):
    """Explicit channel indices avoid FFmpeg's speaker-layout weighting."""
    count, basis = spec["source_channels"], spec["basis"]
    meter = "apad=pad_dur=0.4,ebur128=metadata=1:peak=true:dualmono=true"
    # Branches share stdout: direct writes prevent independent AVIO buffers
    # from interleaving fragments of metadata lines.
    readings = "ametadata=print:file=-:direct=1"
    peak = "ametadata=print:key=lavfi.r128.true_peak:file=-:direct=1"
    if basis.startswith("downmix_"):
        if basis == "downmix_ambix":
            left, right = "0.5*c0+0.5*c1", "0.5*c0-0.5*c1"
        else:
            left = "+".join(f"{1 / ((count + 1) // 2):.17g}*c{i}" for i in range(0, count, 2))
            right = "+".join(f"{1 / (count // 2):.17g}*c{i}" for i in range(1, count, 2))
        return f"[0:a:0]pan=stereo|c0={left}|c1={right},{meter},{readings}[out0]", 1
    graph = [f"[0:a:0]asplit={count}" + "".join(f"[ch{i}]" for i in range(count))]
    for index in range(count):
        metadata = readings if basis == "loudest_channel" or index == 0 else peak
        graph.append(f"[ch{index}]pan=mono|c0=c{index},{meter},{metadata}[out{index}]")
    return ";".join(graph), count


def pcm_wave_info(source, expected_channels, expected_rate):
    """Read PCM WAV/RF64 without libswresample's 64-channel conversion limit."""
    size = os.fstat(source.fileno()).st_size
    header = source.read(12)
    if len(header) != 12 or header[:4] not in (b"RIFF", b"RF64") or header[8:] != b"WAVE":
        raise ValueError("Analysis above 64 channels requires an uncompressed PCM/float WAV or RF64 file")
    rf64 = header[:4] == b"RF64"
    end = size if rf64 else struct.unpack_from("<I", header, 4)[0] + 8
    if end > size or end < 12:
        raise ValueError("Truncated WAV container")
    fmt, data, data64 = None, None, None
    while source.tell() + 8 <= end:
        chunk, length = struct.unpack("<4sI", source.read(8))
        offset = source.tell()
        if chunk == b"ds64" and rf64:
            if length < 28 or offset + length > end:
                raise ValueError("Invalid RF64 size information")
            riff64, data64 = struct.unpack("<QQ", source.read(16))
            end = riff64 + 8
            if end > size or end < offset + length:
                raise ValueError("Truncated RF64 container")
        if chunk == b"data" and length == 0xffffffff and rf64 and data64 is not None:
            length = data64
        if offset + length + length % 2 > end:
            raise ValueError("Truncated WAV chunk")
        if chunk == b"fmt ":
            if fmt is not None or not 16 <= length <= 65536:
                raise ValueError("Invalid WAV format chunk")
            source.seek(offset)
            fmt = source.read(length)
        elif chunk == b"data":
            if data is not None:
                raise ValueError("Multiple WAV audio data chunks are unsupported")
            data = (offset, length)
        source.seek(offset + length + length % 2)
    if fmt is None or data is None:
        raise ValueError("Missing WAV format or audio data")
    tag, channels, rate, byte_rate, align, bits = struct.unpack_from("<HHIIHH", fmt)
    if tag == 0xfffe:
        if (len(fmt) < 40 or struct.unpack_from("<H", fmt, 16)[0] < 22
                or fmt[28:40] != b"\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71"):
            raise ValueError("Unsupported extensible WAV format")
        tag = struct.unpack_from("<I", fmt, 24)[0]
    if (tag == 1 and bits not in (8, 16, 24, 32, 64)) or (tag == 3 and bits not in (32, 64)) or tag not in (1, 3):
        raise ValueError("Analysis above 64 channels requires uncompressed PCM/float WAV audio")
    width = bits // 8
    if (channels != expected_channels or rate != expected_rate or rate <= 0
            or align != channels * width or byte_rate != rate * align or data[1] % align):
        raise ValueError("Invalid or changed PCM WAV channel/sample format")
    raw_format = ("f" if tag == 3 else "s") + str(bits) + "le"
    if bits == 8:
        raw_format = "u8"
    return {"offset": data[0], "frames": data[1] // align, "width": width,
            "align": align, "tag": tag, "bits": bits, "raw_format": raw_format}


def prepare_wide_pcm(path, destination, spec, sample_rate, check):
    """Read the source once, using bounded blocks and a single FFmpeg analyzer.

    OFF puts original channel bytes into separate, zero-padded mono segments.
    Boundaries and startup windows match FFmpeg's integer 100 ms blocks, also
    at rates not divisible by ten. ON writes the explicit mix as float64.
    """
    count, basis = spec["source_channels"], spec["basis"]
    downmix = basis.startswith("downmix_")
    with path.open("rb") as source, destination.open("w+b") as output:
        pcm = pcm_wave_info(source, count, sample_rate)
        width, frames = pcm["width"], pcm["frames"]
        hop = max(1, sample_rate // 10)
        segment_hops = math.ceil((frames + math.ceil(sample_rate * .4)) / hop)
        segment = segment_hops * hop
        warmup_hops = math.ceil((sample_rate * 4 // 10) / hop) - 1
        if not downmix:
            output.truncate(segment * width * count)
            # Zero amplitude is 128, not zero, for unsigned 8-bit PCM.
            if pcm["bits"] == 8:
                silence = b"\x80" * 65536
                for position in range(0, segment * count, len(silence)):
                    check()
                    output.write(silence[:min(len(silence), segment * count - position)])
        source.seek(pcm["offset"])
        frame_offset = 0
        while frame_offset < frames:
            check()
            block_frames = min(8192, frames - frame_offset)
            block = source.read(block_frames * pcm["align"])
            if len(block) != block_frames * pcm["align"]:
                raise ValueError("Source changed or WAV audio is truncated")
            if downmix:
                if pcm["bits"] == 24:
                    values = [int.from_bytes(block[i:i + 3], "little", signed=True)
                              for i in range(0, len(block), 3)]
                else:
                    code = ("f" if width == 4 else "d") if pcm["tag"] == 3 else {1: "B", 2: "h", 4: "i", 8: "q"}[width]
                    values = array.array(code)
                    values.frombytes(block)
                    if sys.byteorder != "little" and width > 1:
                        values.byteswap()
                scale = 1 if pcm["tag"] == 3 else 2 ** (pcm["bits"] - 1)
                bias = 128 if pcm["bits"] == 8 else 0
                mixed = array.array("d")
                for index in range(0, len(values), count):
                    if basis == "downmix_ambix":
                        w, y = (values[index] - bias) / scale, (values[index + 1] - bias) / scale
                        mixed.extend(((w + y) * .5, (w - y) * .5))
                    else:
                        left, right = values[index:index + count:2], values[index + 1:index + count:2]
                        mixed.extend(((sum(left) / len(left) - bias) / scale,
                                      (sum(right) / len(right) - bias) / scale))
                if sys.byteorder != "little":
                    mixed.byteswap()
                output.write(mixed.tobytes())
            else:
                channel_data = bytearray(block_frames * width)
                for channel in range(count):
                    for byte in range(width):
                        channel_data[byte::width] = block[channel * width + byte::pcm["align"]]
                    output.seek((channel * segment + frame_offset) * width)
                    output.write(channel_data)
            frame_offset += block_frames
    return ("f64le" if downmix else pcm["raw_format"], 2 if downmix else 1,
            None if downmix else (segment_hops, warmup_hops, basis == "ambix_w"))


def analyze(request: dict, cancel: Path) -> dict:
    if cancel.exists():
        raise InterruptedError("Analysis superseded or session closed")
    path = Path(request["identity"]["path"])
    before = identity(path)
    expected = request["identity"]
    if before[0] != expected["size"] or int(before[1] / 1e9) != expected["mtime"]:
        raise ValueError("Source changed before analysis")
    ffmpeg = request["ffmpeg"]
    ffprobe = str(Path(ffmpeg).with_name("ffprobe.exe" if os.name == "nt" else "ffprobe"))
    probe = subprocess.run([ffprobe, "-v", "error", "-select_streams", "a:0",
                            "-show_entries", "stream=sample_rate,channels,duration:format=duration",
                            "-of", "json", str(path)], capture_output=True, timeout=15, check=True,
                            creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
    if cancel.exists():
        raise InterruptedError("Analysis superseded or session closed")
    info = json.loads(probe.stdout)
    streams = info.get("streams", [])
    if not streams:
        raise ValueError("No audio stream found")
    stream = streams[0]
    spec = analysis_spec(request, stream["channels"])
    duration = float(stream.get("duration", info.get("format", {}).get("duration", 0)))
    started = time.monotonic()
    def check():
        if cancel.exists():
            raise InterruptedError("Analysis superseded or session closed")
        if time.monotonic() - started > request.get("timeout", 180):
            raise TimeoutError("Analysis timeout")
    with tempfile.TemporaryDirectory(prefix="audition-loudness-") as directory:
        metadata_path, error_path = Path(directory) / "metadata", Path(directory) / "error"
        command = [ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-threads", "1"]
        momentary_windows = None
        if spec is not None and spec["source_channels"] > 64:
            raw_path = Path(directory) / "channels.pcm"
            raw_format, measurement_channels, momentary_windows = prepare_wide_pcm(
                path, raw_path, spec, int(stream["sample_rate"]), check)
            command += ["-f", raw_format, "-ar", str(stream["sample_rate"]),
                        "-ac", str(measurement_channels), "-i", str(raw_path),
                        "-map", "0:a:0", "-vn", "-af",
                        "apad=pad_dur=0.4,ebur128=metadata=1:peak=true:dualmono=true,"
                        "ametadata=print:file=-:direct=1",
                        "-c:a", "pcm_f64le", "-f", "null", "-"]
        elif spec is not None:
            graph, outputs = multichannel_graph(spec)
            # -filter_complex is shared by older and current FFmpeg releases;
            # -filter_complex_script was removed, and -/filter_complex is newer.
            # This path is bounded to 64 channels (<10 KiB of graph). Popen
            # passes arguments directly, avoiding cmd.exe's 8191-character limit.
            command += ["-i", str(path), "-filter_complex_threads", "1",
                        "-filter_complex", graph]
            for index in range(outputs):
                command += ["-map", f"[out{index}]"]
            command += ["-c:a", "pcm_f64le", "-f", "null", "-"]
        else:
            command += ["-i", str(path), "-map", "0:a:0", "-vn", "-af",
                        "apad=pad_dur=0.4,ebur128=metadata=1:peak=true:dualmono=true,ametadata=print:file=-",
                        "-f", "null", "-"]
        check()
        with metadata_path.open("wb") as output, error_path.open("wb") as errors:
            process = subprocess.Popen(command, stdout=output, stderr=errors,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
            try:
                while process.poll() is None:
                    check()
                    time.sleep(0.03)
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
            if process.returncode:
                raise RuntimeError(error_path.read_text(errors="replace")[-2000:])
        peak_observation = {}
        with metadata_path.open(encoding="utf-8", errors="replace") as data:
            momentary, true_peak = parse_metadata(data, check=check, momentary_windows=momentary_windows,
                                                 peak_observation=peak_observation)
    if cancel.exists():
        raise InterruptedError("Analysis superseded or session closed")
    if identity(path) != before:
        raise ValueError("Source changed during analysis; result discarded")
    peak_is_upper_bound = (spec is not None and true_peak is None
                           and momentary is not None and momentary >= -100
                           and peak_observation.get("reported_zero", False))
    if peak_is_upper_bound:
        # Keep real, quiet v2 signals eligible for linked normalization without
        # another analyzer pass. Legacy v1 silence/cache semantics stay intact.
        true_peak = 20 * math.log10(ROUNDED_PEAK_UPPER_BOUND)
    silent = true_peak is None or momentary is None or momentary < -100
    result = {"status": "silence" if silent else "ready", "identity": expected,
            "profile": MULTICHANNEL_PROFILE if spec is not None else PROFILE, "analyzer_key": request["analyzer_key"],
            "max_momentary_lufs": None if silent else momentary,
            "true_peak_dbtp": true_peak, "duration": duration,
            "sample_rate": int(stream["sample_rate"]), "channels": stream["channels"],
            "source_mtime_ns": before[1], "elapsed_seconds": time.monotonic() - started,
            "measured_at": int(time.time())}
    if spec is not None:
        result["analysis"] = spec
        result["measurement_channels"] = 2 if spec["basis"].startswith("downmix_") else 1
    if peak_is_upper_bound:
        result["true_peak_is_upper_bound"] = True
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("request", type=Path)
    parser.add_argument("result", type=Path)
    parser.add_argument("cancel", type=Path)
    args = parser.parse_args()
    request = json.loads(args.request.read_text(encoding="utf-8"))
    try:
        result = analyze(request, args.cancel)
    except InterruptedError as exc:
        result = {"status": "cancelled", "error": str(exc)}
    except Exception as exc:
        result = {"status": "error", "error": str(exc)}
    result["job_id"] = request["job_id"]
    atomic_json(args.result, result)
    return 0 if result["status"] in ("ready", "silence", "cancelled") else 1


if __name__ == "__main__":
    raise SystemExit(main())
