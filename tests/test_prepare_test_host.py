#!/usr/bin/env python3
"""Regression for isolated host audio settings; does not launch REAPER."""
import configparser
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
AUDIO = {
    "coreaudiobs": "256",
    "coreaudiobsuse": "1",
    "coreaudioignorereset": "0",
    "coreaudioignprojsr": "1",
    "coreaudioindevnew": "Input Fixture Device",
    "coreaudiooutdevnew": "Output Fixture Device",
    "coreaudiosrate": "48000",
    "coreaudiosrateuse": "1",
}


def snapshot(directory):
    return {
        str(path.relative_to(directory)): path.read_bytes() if path.is_file() else None
        for path in directory.rglob("*")
    }


@unittest.skipUnless(sys.platform == "darwin", "The disposable REAPER host preparer is macOS-only")
class PrepareTestHost(unittest.TestCase):
    def test_audio_section_casing_and_isolation(self):
        for section in ("reaper", "REAPER", "ReApEr"):
            with self.subTest(section=section), tempfile.TemporaryDirectory(prefix="am-host-config-") as directory:
                resource = Path(directory) / "original"
                resource.mkdir()
                (resource / "Effects").mkdir()
                (resource / "Effects/user_effect.jsfx").write_text("desc:Original user effect\n")
                (resource / "Effects/AuditionMacro").mkdir()
                (resource / "Effects/AuditionMacro/channels_v1").write_text("desc:Channel fixture\n")
                settings = "".join(f"{key}={value}\n" for key, value in AUDIO.items())
                (resource / "reaper.ini").write_text(
                    f"[{section}]\n" + settings
                    + "loadlastproj=1\nlastproject=/user/private/project.rpp\naudiocloseinactive=1\n"
                    + "startupaction=_USER_STARTUP\ncsurf_cnt=1\ncoreaudio_unlisted=secret\n"
                    + "[Other]\nprivate_setting=secret\n"
                )
                before = snapshot(resource)
                target = Path(directory) / "test-host"
                result = subprocess.run(
                    [sys.executable, str(ROOT / "tools/prepare_test_host.py"),
                     "--resource", str(resource), "--directory", str(target)],
                    text=True, capture_output=True, check=False,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                copied = configparser.ConfigParser(interpolation=None)
                copied.read(target / "reaper.ini")
                self.assertEqual(copied.sections(), ["REAPER"])
                expected = dict(AUDIO, loadlastproj="0", lastproject="", audiocloseinactive="0")
                self.assertEqual(dict(copied["REAPER"]), expected)
                self.assertTrue((target / ".audition-macro-test").is_file())
                self.assertTrue((target / "Effects").is_dir())
                self.assertFalse((target / "Effects").is_symlink())
                self.assertFalse((target / "Effects/AuditionMacro").is_symlink())
                (target / "Effects/AuditionMacro/channels_v1").write_text("desc:Isolated change\n")
                (target / "Effects/test_only_probe.jsfx").write_text("desc:Test only\n")
                self.assertEqual(snapshot(resource), before, "Original resource directory changed")


if __name__ == "__main__":
    unittest.main()
