import importlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

from tools import package_windows as packager

ROOT = Path(__file__).parents[1]


def windows_helper(version="0.11.0"):
    data = bytearray(512)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 60, 128)
    data[128:132] = b"PE\x00\x00"
    struct.pack_into("<H", data, 132, 0x8664)
    struct.pack_into("<H", data, 150, 0x2000)
    marker = ('{"schema":1,"version":"' + version + '"}').encode()
    data[256:256 + len(marker)] = marker
    return bytes(data)


class PackageWindowsTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="am-windows-package-test-")
        self.addCleanup(directory.cleanup)
        self.temp = Path(directory.name).resolve()
        self.root = self.temp / "source"
        self.root.mkdir()
        self.output = self.temp / "runtime.zip"
        self.manifest = json.loads((ROOT / "resources/release-manifest.json").read_text())
        for group in ("main_actions", "media_explorer_actions", "support_files"):
            for name in self.manifest[group]:
                source = self.manifest.get("aliases", {}).get(name, name)
                self.write(source, f"fixture: {name}\n".encode())
        self.write("SoundPrep.lua", b"-- @version 0.11.0\n")
        self.write("resources/native-contract.json", b'{"schema":1,"version":"0.11.0"}\n')
        self.write("resources/release-manifest.json", json.dumps(self.manifest).encode())
        self.write("LICENSE", b"MIT License\nCopyright fixture\n")
        self.write("build/reaper_audition_macro.dll", windows_helper())

    def write(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def package(self, **changes):
        arguments = {"root": self.root, "output": self.output}
        arguments.update(changes)
        return packager.package_windows(**arguments)

    def test_only_runtime_allowlist_and_main_helper_ship(self):
        for name in ("native/analysis.cpp", "native/zwicker.cpp", "native/lufs_meter.cpp",
                     "OtherScripts/Zwicker/private.py", "worker/analyze.py", "tools/private.py",
                     "tests/private.lua", "data/bank.json", "build/reaper_audition_macro.pdb",
                     "build/reaper_audition_macro_worker.dll", "README.md"):
            self.write(name, b"private sentinel must not ship")
        report = self.package()
        expected = {name for group in ("main_actions", "media_explorer_actions", "support_files")
                    for name in self.manifest[group]}
        expected.update(("LICENSE", "build/reaper_audition_macro.dll"))
        with zipfile.ZipFile(self.output) as archive:
            self.assertEqual(set(archive.namelist()), {"SoundPrep/" + name for name in expected})
            for name in archive.namelist():
                self.assertNotIn(b"private sentinel", archive.read(name), name)
            for license in ("LICENSE", "native/vendor/mosqito.LICENSE.md", "native/vendor/ebur128.LICENSE.MIT"):
                self.assertIn("SoundPrep/" + license, archive.namelist())
            self.assertEqual(archive.read("SoundPrep/README.md"),
                             (self.root / "docs/release-readme.md").read_bytes())
        self.assertEqual(report["version"], "0.11.0")
        self.assertEqual(report["helper_version"], "0.11.0")
        self.assertEqual(report["files"], len(expected))
        self.assertEqual(report["sha256"], packager.release.digest(self.output.read_bytes()))

    def test_invalid_or_stale_helper_preserves_existing_output(self):
        self.output.write_bytes(b"previous archive")
        wrong_arch = bytearray(windows_helper())
        struct.pack_into("<H", wrong_arch, 132, 0x014c)
        for data in (b"not a PE", bytes(wrong_arch), windows_helper("0.10.21")):
            self.write("build/reaper_audition_macro.dll", data)
            with self.subTest(data=data[:2]), self.assertRaises(ValueError):
                self.package()
            self.assertEqual(self.output.read_bytes(), b"previous archive")
        self.assertFalse(list(self.temp.glob(".am-windows-package-*")))

    def test_missing_runtime_input_preserves_existing_output(self):
        self.output.write_bytes(b"previous archive")
        (self.root / "native/vendor/mosqito.LICENSE.md").unlink()
        with self.assertRaisesRegex(ValueError, "Required release file is missing"):
            self.package()
        self.assertEqual(self.output.read_bytes(), b"previous archive")
        self.assertFalse(list(self.temp.glob(".am-windows-package-*")))

    def test_failed_write_preserves_output_and_cleans_owned_temporary_files(self):
        self.output.write_bytes(b"previous archive")

        def fail(archive, entries):
            archive.write_bytes(b"partial")
            raise OSError("disk full fixture")

        with mock.patch.object(packager.release, "write_zip", side_effect=fail):
            with self.assertRaisesRegex(OSError, "disk full"):
                self.package()
        self.assertEqual(self.output.read_bytes(), b"previous archive")
        self.assertFalse(list(self.temp.glob(".am-windows-package-*")))

    def test_success_replaces_old_archive_and_is_deterministic(self):
        self.output.write_bytes(b"obsolete archive")
        self.package()
        second = self.temp / "second.zip"
        self.package(output=second)
        self.assertEqual(self.output.read_bytes(), second.read_bytes())

    def test_failed_atomic_replace_preserves_output(self):
        self.output.write_bytes(b"previous archive")
        with mock.patch.object(packager.os, "replace", side_effect=OSError("replacement denied")):
            with self.assertRaisesRegex(OSError, "replacement denied"):
                self.package()
        self.assertEqual(self.output.read_bytes(), b"previous archive")
        self.assertFalse(list(self.temp.glob(".am-windows-package-*")))

    def test_output_cannot_replace_a_runtime_or_helper_input(self):
        for name in ("docs/release-readme.md", "resources/release-manifest.json",
                     "build/reaper_audition_macro.dll"):
            path = self.root / name
            original = path.read_bytes()
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "package input"):
                self.package(output=path)
            self.assertEqual(path.read_bytes(), original)

    def test_symlink_output_does_not_modify_target(self):
        target = self.temp / "keep"
        target.write_bytes(b"keep")
        try:
            self.output.symlink_to(target)
        except OSError:
            self.skipTest("Creating symlinks is not supported by this test host")
        with self.assertRaisesRegex(ValueError, "symlinks"):
            self.package()
        self.assertEqual(target.read_bytes(), b"keep")

    def test_cli_and_import_have_no_archive_side_effects(self):
        with mock.patch.object(sys, "argv", ["package_windows.py", str(self.output)]):
            importlib.reload(packager)
        self.assertFalse(self.output.exists())
        result = subprocess.run([sys.executable, str(ROOT / "tools/package_windows.py"),
                                 str(self.output), "--root", str(self.root)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["helper_version"], "0.11.0")
        self.assertTrue(zipfile.is_zipfile(self.output))


if __name__ == "__main__":
    unittest.main()
