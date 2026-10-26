import importlib.util
import math
import os
from pathlib import Path
import shutil
import struct
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("multichannel_analyze", Path(__file__).parents[1] / "worker/analyze.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class MultichannelWorkerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="AM multichannel 日本語 ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.ffmpeg = shutil.which("ffmpeg")
        if not self.ffmpeg:
            self.skipTest("FFmpeg is not installed")
        self.serial = 0

    def audio(self, amplitudes, bits=32, floating=True, duration=.43, rf64=False, extensible=False, rate=48000):
        self.serial += 1
        path = self.root / f"audio {self.serial}.wav"
        channels = len(amplitudes)
        width, tag = bits // 8, 3 if floating else 1
        period = bytearray()
        for frame in range(48):
            for amplitude in amplitudes:
                value = amplitude * math.sin(2 * math.pi * frame / 48)
                if floating:
                    period.extend(struct.pack("<f" if bits == 32 else "<d", value))
                else:
                    number = round(value * (2 ** (bits - 1) - 1))
                    period.extend((number + 128).to_bytes(1, "little") if bits == 8
                                  else number.to_bytes(width, "little", signed=True))
        frames = round(duration * rate)
        data = (bytes(period) * (frames // 48 + 1))[:frames * channels * width]
        fmt = struct.pack("<HHIIHH", 0xfffe if extensible else tag, channels, rate,
                          rate * channels * width, channels * width, bits)
        if extensible:
            fmt += struct.pack("<HHII", 22, bits, 0, tag) + b"\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71"
        payload = b"fmt " + struct.pack("<I", len(fmt)) + fmt
        payload += b"JUNK\x03\x00\x00\x00abc\x00"
        payload += b"data" + struct.pack("<I", 0xffffffff if rf64 else len(data)) + data + (b"\x00" if len(data) % 2 else b"")
        if rf64:
            ds64 = struct.pack("<QQQI", len(payload) + 40, len(data), frames, 0)
            path.write_bytes(b"RF64\xff\xff\xff\xffWAVEds64\x1c\x00\x00\x00" + ds64 + payload)
        else:
            path.write_bytes(b"RIFF" + struct.pack("<I", len(payload) + 4) + b"WAVE" + payload)
        return path

    def request(self, path, basis=None, channels=None):
        stat = path.stat()
        request = {"identity": {"path": str(path), "size": stat.st_size, "mtime": int(stat.st_mtime)},
                   "ffmpeg": self.ffmpeg, "analyzer_key": "multichannel-test", "timeout": 20}
        if basis is not None:
            request["analysis"] = {"revision": 1, "source_channels": channels, "basis": basis}
        return request

    def analyze(self, amplitudes, basis=None, **kwargs):
        path = self.audio(amplitudes, **kwargs)
        return worker.analyze(self.request(path, basis, len(amplitudes)), self.root / "cancel")

    def assert_measurements(self, result, reference, delta=.015):
        self.assertAlmostEqual(result["max_momentary_lufs"], reference["max_momentary_lufs"], delta=delta)
        self.assertAlmostEqual(result["true_peak_dbtp"], reference["true_peak_dbtp"], delta=.04)

    def test_discrete_mapping_matches_explicit_stereo_and_odd_channel_count(self):
        result = self.analyze([.2, .1, -.1, .3, .05], "downmix_discrete")
        reference = self.analyze([(.2 - .1 + .05) / 3, (.1 + .3) / 2])
        self.assert_measurements(result, reference)
        self.assertEqual(result["channels"], 5)
        self.assertEqual(result["measurement_channels"], 2)
        self.assertEqual(result["profile"], worker.MULTICHANNEL_PROFILE)
        self.assertEqual(result["analysis"], {"revision": 1, "source_channels": 5, "basis": "downmix_discrete"})
        self.assertEqual(reference["profile"], worker.PROFILE)

    def test_antiphase_downmix_silence_does_not_hide_unmixed_loudest_channel(self):
        mapped = self.analyze([.25, .125, -.25, -.125], "downmix_discrete")
        original = self.analyze([.25, .125, -.25, -.125], "loudest_channel")
        reference = self.analyze([.25])
        self.assertEqual(mapped["status"], "silence")
        self.assertIsNone(mapped["true_peak_dbtp"])
        self.assert_measurements(original, reference)

    def test_loudest_channel_includes_channel_three_and_ignores_surround_layout(self):
        result = self.analyze([.01, .02, .5, .03, .04, .05], "loudest_channel")
        self.assert_measurements(result, self.analyze([.5]))

    def test_ambix_mapping_matches_w_y_stereo(self):
        result = self.analyze([.2, .1, .8, .9], "downmix_ambix")
        self.assert_measurements(result, self.analyze([.15, .05]))

    def test_silent_w_keeps_peak_from_other_ambix_channels(self):
        result = self.analyze([0, .75, .01, .02], "ambix_w")
        reference = self.analyze([.75])
        self.assertEqual(result["status"], "silence")
        self.assertIsNone(result["max_momentary_lufs"])
        self.assertAlmostEqual(result["true_peak_dbtp"], reference["true_peak_dbtp"], delta=.04)

    def test_ambix_w_is_dual_mono_but_peak_uses_all_channels(self):
        result = self.analyze([.125, .75, .01, .02], "ambix_w")
        self.assertAlmostEqual(result["max_momentary_lufs"], self.analyze([.125])["max_momentary_lufs"], delta=.015)
        self.assertAlmostEqual(result["true_peak_dbtp"], self.analyze([.75])["true_peak_dbtp"], delta=.04)

    def test_128_channels_use_last_channel_for_loudness_and_peak(self):
        result = self.analyze([0] * 127 + [.5], "loudest_channel")
        self.assert_measurements(result, self.analyze([.5]))
        self.assertEqual(result["channels"], 128)

    def test_128_channel_downmix_matches_stereo_reference(self):
        result = self.analyze([.2, -.1] * 64, "downmix_discrete")
        self.assert_measurements(result, self.analyze([.2, -.1]))

    def test_filter_and_pcm_paths_agree_at_64_channel_boundary(self):
        reference = self.analyze([.5])
        for count in (64, 65):
            with self.subTest(channels=count):
                result = self.analyze([0] * (count - 1) + [.5], "loudest_channel")
                self.assert_measurements(result, reference)

    def test_wide_nonstandard_sample_rate_preserves_window_phase(self):
        result = self.analyze([0] * 64 + [.25], "loudest_channel", rate=11025, duration=.137)
        reference = self.analyze([.25], rate=11025, duration=.137)
        self.assert_measurements(result, reference)

    def test_high_channel_ambix_silent_w_keeps_all_channel_peak(self):
        result = self.analyze([0] * 120 + [.5], "ambix_w")
        self.assertEqual(result["status"], "silence")
        self.assertIsNone(result["max_momentary_lufs"])
        self.assertAlmostEqual(result["true_peak_dbtp"], self.analyze([.5])["true_peak_dbtp"], delta=.04)

    def test_high_channel_ambix_w_excludes_louder_later_channel_from_momentary(self):
        result = self.analyze([.125] + [0] * 79 + [.75], "ambix_w")
        self.assertAlmostEqual(result["max_momentary_lufs"], self.analyze([.125])["max_momentary_lufs"], delta=.015)
        self.assertAlmostEqual(result["true_peak_dbtp"], self.analyze([.75])["true_peak_dbtp"], delta=.04)

    def test_high_channel_pcm24_rf64_and_float64_extensible(self):
        for options in ({"bits": 24, "floating": False, "rf64": True},
                        {"bits": 64, "floating": True, "extensible": True}):
            with self.subTest(options=options):
                result = self.analyze([.125, .0625] + [0] * 79, "downmix_ambix", **options)
                self.assert_measurements(result, self.analyze([.09375, .03125]))

    def test_wide_unsigned_pcm_silence_uses_midpoint_padding(self):
        result = self.analyze([0] * 65, "loudest_channel", bits=8, floating=False, duration=.02)
        self.assertEqual(result["status"], "silence")
        self.assertIsNone(result["true_peak_dbtp"])

    def test_quiet_generic_channels_remain_normalizable_with_conservative_peak(self):
        for amplitude in (.000125, .00049):
            with self.subTest(amplitude=amplitude):
                result = self.analyze([0, 0, amplitude], "loudest_channel")
                self.assertEqual(result["status"], "ready")
                self.assertTrue(math.isfinite(result["max_momentary_lufs"]))
                self.assertTrue(result["true_peak_is_upper_bound"])
                self.assertEqual(result["true_peak_dbtp"], -60)
                self.assertGreaterEqual(10 ** (result["true_peak_dbtp"] / 20), amplitude)
                # Even the complete rounding interval lies below this bound.
                self.assertGreaterEqual(worker.ROUNDED_PEAK_UPPER_BOUND, .0005)

    def test_sparse_128_channel_downmix_remains_normalizable_when_peak_rounds_to_zero(self):
        result = self.analyze([0] * 127 + [.01], "downmix_discrete")
        self.assertEqual(result["status"], "ready")
        self.assertTrue(result["true_peak_is_upper_bound"])
        self.assertGreaterEqual(10 ** (result["true_peak_dbtp"] / 20), .01 / 64)
        self.assertTrue(-90 < result["max_momentary_lufs"] < -60)

    def test_quiet_ambix_w_uses_other_channel_peak_when_available(self):
        for other_peak in (.00025, .75):
            with self.subTest(other_peak=other_peak):
                result = self.analyze([.000125, other_peak, 0, 0], "ambix_w")
                self.assertEqual(result["status"], "ready")
                if other_peak < .0005:
                    self.assertTrue(result["true_peak_is_upper_bound"])
                    self.assertEqual(result["true_peak_dbtp"], -60)
                else:
                    self.assertNotIn("true_peak_is_upper_bound", result)
                    self.assertAlmostEqual(result["true_peak_dbtp"], 20 * math.log10(other_peak), delta=.04)

    def test_true_silence_and_below_threshold_audio_do_not_receive_peak_bound(self):
        for amplitude in (0, .0000001):
            with self.subTest(amplitude=amplitude):
                result = self.analyze([amplitude] * 4, "loudest_channel")
                self.assertEqual(result["status"], "silence")
                self.assertIsNone(result["max_momentary_lufs"])
                self.assertIsNone(result["true_peak_dbtp"])
                self.assertNotIn("true_peak_is_upper_bound", result)
        cancelled = self.analyze([.125, .125, -.125, -.125], "downmix_discrete")
        self.assertEqual(cancelled["status"], "silence")
        self.assertNotIn("true_peak_is_upper_bound", cancelled)

    def test_quiet_legacy_audio_keeps_its_original_silence_policy(self):
        result = self.analyze([.000125])
        self.assertEqual(result["status"], "silence")
        self.assertIsNone(result["max_momentary_lufs"])
        self.assertIsNone(result["true_peak_dbtp"])
        self.assertNotIn("true_peak_is_upper_bound", result)

    def test_missing_peak_metadata_cannot_claim_a_safe_upper_bound(self):
        with mock.patch.object(worker, "parse_metadata", return_value=(-18, None)):
            result = self.analyze([.1] * 3, "loudest_channel")
        self.assertEqual(result["status"], "silence")
        self.assertNotIn("true_peak_is_upper_bound", result)

    def test_descriptor_rejects_invalid_and_stale_modes(self):
        valid = {"revision": 1, "source_channels": 4, "basis": "ambix_w"}
        for changes in ({"revision": 2}, {"revision": True}, {"source_channels": 2},
                        {"source_channels": 129}, {"source_channels": True},
                        {"basis": "auto"}, {"basis": []}, {"source_channels": 6}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                worker.analysis_spec({"analysis": dict(valid, **changes)}, changes.get("source_channels", 4))
        with self.assertRaisesRegex(ValueError, "channel count changed"):
            worker.analyze(self.request(self.audio([.1] * 3), "downmix_discrete", 4), self.root / "cancel")
        with self.assertRaisesRegex(ValueError, "mono/stereo"):
            worker.analyze(self.request(self.audio([.1] * 3)), self.root / "cancel")

    def test_one_analyzer_process_for_all_channels(self):
        original = worker.subprocess.Popen
        for count in (4, 64, 128):
            with self.subTest(channels=count), mock.patch.object(worker.subprocess, "Popen", wraps=original) as launch:
                self.analyze([.1] * count, "loudest_channel", duration=.02)
                analyzer_calls = [call for call in launch.call_args_list
                                  if os.path.normcase(os.path.abspath(call.args[0][0]))
                                  == os.path.normcase(os.path.abspath(self.ffmpeg))]
                self.assertEqual(len(analyzer_calls), 1)
                command = analyzer_calls[0].args[0]
                self.assertNotIn("-filter_complex_script", command)
                self.assertNotIn("-/filter_complex", command)
                self.assertEqual("-filter_complex" in command, count <= 64)
                self.assertFalse(analyzer_calls[0].kwargs.get("shell", False))

    def test_filter_graph_command_budget_includes_long_unicode_windows_paths(self):
        # Inspect commands from analyze(), not a parallel command builder. The
        # largest graph is AmbiX W at 64 channels; larger inputs use raw PCM.
        for basis in worker.BASES:
            for count in range(3, 65):
                if "ambix" in basis and math.isqrt(count) ** 2 != count:
                    continue
                with self.subTest(basis=basis, channels=count):
                    path = self.audio([0] * count, duration=.001)
                    probe = mock.Mock(stdout=worker.json.dumps({"streams": [
                        {"channels": count, "sample_rate": "48000", "duration": "0.001"}
                    ]}).encode())
                    process = mock.Mock(returncode=0)
                    process.poll.return_value = 0
                    with mock.patch.object(worker.subprocess, "run", return_value=probe), \
                            mock.patch.object(worker.subprocess, "Popen", return_value=process) as launch:
                        worker.analyze(self.request(path, basis, count), self.root / "cancel")
                    launch.assert_called_once()
                    command = list(launch.call_args.args[0])
                    self.assertIn("-filter_complex", command)
                    graph = command[command.index("-filter_complex") + 1]
                    self.assertLess(len(graph), 10000)
                    self.assertFalse(launch.call_args.kwargs.get("shell", False))
                    # Reserve >4,000 UTF-16 units each for executable and input
                    # paths, including spaces and surrogate pairs. CreateProcessW
                    # allows 32,767 units including the final NUL, not 8,191.
                    directory = "C:\\" + "音🥁 " * 1000
                    command[0] = directory + "\\ffmpeg.exe"
                    command[command.index("-i") + 1] = directory + "\\source.wav"
                    units = len(worker.subprocess.list2cmdline(command).encode("utf-16-le")) // 2 + 1
                    self.assertLess(units, 24576)

    def test_wide_extraction_checks_cancellation_between_blocks(self):
        path = self.audio([.1] * 128)
        checks = 0
        def cancel_check():
            nonlocal checks
            checks += 1
            if checks == 2:
                raise InterruptedError("cancelled")
        with self.assertRaises(InterruptedError):
            worker.prepare_wide_pcm(path, self.root / "spool", {"source_channels": 128, "basis": "loudest_channel"},
                                    48000, cancel_check)
        self.assertEqual(checks, 2)

    def test_wide_non_pcm_has_clear_error_and_does_not_launch_analyzer(self):
        source = self.root / "compressed.audio"
        source.write_bytes(b"not PCM WAV")
        probe = mock.Mock(stdout=b'{"streams":[{"channels":128,"sample_rate":"48000","duration":"1"}]}')
        with mock.patch.object(worker.subprocess, "run", return_value=probe), \
                mock.patch.object(worker.subprocess, "Popen") as launch, \
                self.assertRaisesRegex(ValueError, "above 64 channels requires"):
            worker.analyze(self.request(source, "loudest_channel", 128), self.root / "cancel")
        launch.assert_not_called()

    def test_source_change_during_wide_extraction_discards_result(self):
        path = self.audio([.1] * 128, duration=.02)
        prepare = worker.prepare_wide_pcm
        def changing_source(*args, **kwargs):
            value = prepare(*args, **kwargs)
            with path.open("ab") as source:
                source.write(b"changed")
            return value
        with mock.patch.object(worker, "prepare_wide_pcm", side_effect=changing_source), \
                self.assertRaisesRegex(ValueError, "Source changed during analysis"):
            worker.analyze(self.request(path, "loudest_channel", 128), self.root / "cancel")


if __name__ == "__main__":
    unittest.main()
