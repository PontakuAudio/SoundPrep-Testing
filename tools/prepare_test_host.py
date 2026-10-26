#!/usr/bin/env python3
"""Prepare an isolated macOS REAPER resource directory; never launches REAPER."""
from pathlib import Path
import argparse
import configparser
import math
import shutil
import struct
import wave

parser = argparse.ArgumentParser()
parser.add_argument("--directory", type=Path, default=Path("/tmp/audition-macro-dev/host"))
parser.add_argument("--resource", type=Path, default=Path.home() / "Library/Application Support/REAPER")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
target, resource = args.directory.resolve(), args.resource.resolve()
assert target != resource, "Refusing to use the normal REAPER resource directory"
target.mkdir(parents=True, exist_ok=True)
assert not (target / "reaper.ini").exists() or (target / ".audition-macro-test").exists(), "Not an owned test host"
(target / ".audition-macro-test").write_text("Audition Macro disposable test resource directory\n")
(target / "UserPlugins").mkdir(exist_ok=True)
for name in ("reaper_js_ReaScriptAPI64ARM.dylib", "reaper_sws-arm64.dylib"):
    source, dest = resource / "UserPlugins" / name, target / "UserPlugins" / name
    if source.exists() and not dest.exists():
        dest.symlink_to(source)
native = root / "build/reaper_audition_macro.dylib"
if native.exists():
    assert not (target / "UserPlugins/reaper_audition_macro.dylib").exists(), "Do not replace a potentially loaded native binary; stop the test host first"
    shutil.copy2(native, target / "UserPlugins/reaper_audition_macro.dylib")
# Give test-only probes their own Effects directory, never the user's directory.
effects = target / "Effects"
assert not effects.is_symlink(), "Old test host: replace its Effects symlink with an owned directory first"
effects.mkdir(exist_ok=True)
for source in (resource / "Effects").iterdir():
    dest = effects / source.name
    if not dest.exists():
        if source.name == 'AuditionMacro' and source.is_dir():
            # The drop processor installs versioned JSFX here. Keep this
            # writable namespace owned by the test host, including after the
            # processor has been installed in the normal resource directory.
            shutil.copytree(source, dest)
        else:
            dest.symlink_to(source, target_is_directory=source.is_dir())
probe = effects / "am_response_probe"
if not probe.exists():
    probe.symlink_to(root / "tests/audio_response_probe.jsfx")
for pattern in ("reaper-license.rk", "reaper-*plugins*.ini", "reaper-clap-*.ini", "reaper-jsfx.ini"):
    for source in resource.glob(pattern):
        shutil.copy2(source, target / source.name)
if not (target / "reaper.ini").exists():
    # Use the already configured CoreAudio device/rate without inheriting user
    # projects, control surfaces, or startup actions. Fresh REAPER defaults can
    # otherwise request a different rate and block in an audio-error dialog.
    original = configparser.ConfigParser(interpolation=None, strict=False)
    original.read(resource / "reaper.ini")
    audio_keys = ("coreaudiobs", "coreaudiobsuse", "coreaudioignorereset", "coreaudioignprojsr",
                  "coreaudioindevnew", "coreaudiooutdevnew", "coreaudiosrate", "coreaudiosrateuse")
    # REAPER writes this section as [reaper] on some installations. Unlike
    # option names, ConfigParser section lookup is case-sensitive.
    reaper_section = next((section for section in original.sections() if section.casefold() == "reaper"), None)
    audio = "".join(f"{key}={original.get(reaper_section, key)}\n" for key in audio_keys
                    if reaper_section is not None and original.has_option(reaper_section, key))
    (target / "reaper.ini").write_text("[REAPER]\nloadlastproj=0\nlastproject=\naudiocloseinactive=0\n" + audio)
# The integration scripts intentionally use this known disposable fixture path.
fixtures = Path("/tmp/audition-macro-dev")
fixtures.mkdir(exist_ok=True)
with wave.open(str(fixtures / "test.wav"), "wb") as wav:
    wav.setparams((1, 2, 48000, 0, "NONE", "not compressed"))
    wav.writeframes(b"".join(struct.pack("<h", int(4096 * math.sin(2 * math.pi * 1000 * i / 48000))) for i in range(48000)))
with wave.open(str(fixtures / "impulse.wav"), "wb") as wav:
    wav.setparams((1, 2, 48000, 0, "NONE", "not compressed"))
    wav.writeframes(b"".join(struct.pack("<h", 30000 if i == 2400 else 0) for i in range(24000)))
(fixtures / "search-fixtures").mkdir(exist_ok=True)
for name in ("slam", "hit", "door", "metal_clang"):
    shutil.copyfile(fixtures / "test.wav", fixtures / f"search-fixtures/{name}.wav")
(fixtures / "phrase-fixtures").mkdir(exist_ok=True)
for name in ("heavy_metal_slam", "light_metal_hit", "heavy_wood_impact", "heavy_metal_hit_voice",
             "heavy_metal_hit_music", "heavy_metal_door_close", "heavy_metal_gate_close"):
    shutil.copyfile(fixtures / "test.wav", fixtures / f"phrase-fixtures/{name}.wav")
print(f"Prepared: {target}")
print(f"Run REAPER with -newinst -cfgfile '{target}/reaper.ini' '{root}/tests/reaper_smoke.lua'")

# Keep waveform tests away from bridge/job files: native directory refreshes
# can unload the selected preview when files beside the fixtures change.
(fixtures / "media-fixtures").mkdir(exist_ok=True)
for name in ("test.wav", "impulse.wav"):
    shutil.copyfile(fixtures / name, fixtures / "media-fixtures" / name)
with wave.open(str(fixtures / "media-fixtures/latency.wav"), "wb") as wav:
    wav.setparams((1, 2, 48000, 0, "NONE", "not compressed"))
    wav.writeframes(b"".join(struct.pack("<h", int(800 * math.sin(2 * math.pi * 1000 * i / 48000))) for i in range(48000 * 20)))
