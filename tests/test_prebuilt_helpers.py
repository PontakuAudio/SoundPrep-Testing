"""Public binary packaging fails closed on stale, altered or redirected inputs."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("prebuilt_helpers", ROOT / "tools/prebuilt_helpers.py")
prebuilt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prebuilt)


def helper_bytes(platform, version="0.11.0"):
    data = bytearray(512)
    if platform == "macos":
        struct.pack_into(">II", data, 0, 0xcafebabe, 2)
        for index, cpu in enumerate((0x01000007, 0x0100000c)):
            struct.pack_into(">IIIII", data, 8 + index * 20, cpu, 0, 128 + index * 128, 128, 2)
    else:
        data[:2] = b"MZ"
        struct.pack_into("<I", data, 60, 128)
        data[128:132] = b"PE\x00\x00"
        struct.pack_into("<H", data, 132, 0x8664)
        struct.pack_into("<H", data, 150, 0x2000)
    marker = ('{"schema":1,"version":"' + version + '"}').encode()
    data[300:300 + len(marker)] = marker
    return bytes(data)


class PrebuiltHelperTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="am-prebuilt-")
        self.addCleanup(self.directory.cleanup)
        self.temp = Path(self.directory.name).resolve()
        self.root = self.temp / "source"
        (self.root / "resources").mkdir(parents=True)
        (self.root / "SoundPrep.lua").write_text("-- @version 0.11.0\n", encoding="utf-8")
        (self.root / "resources/native-contract.json").write_text(
            '{"schema":1,"version":"0.11.0"}\n', encoding="utf-8")
        self.mac, self.win = self.temp / "helper.dylib", self.temp / "helper.dll"
        self.mac.write_bytes(helper_bytes("macos"))
        self.win.write_bytes(helper_bytes("windows"))

    def prepare(self):
        return prebuilt.prepare_prebuilt_helpers(self.root, self.mac, self.win)

    def install_fixture(self):
        for relative, data in self.prepare().items():
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        return json.loads((self.root / prebuilt.MANIFEST).read_bytes())

    def save_manifest(self, manifest):
        (self.root / prebuilt.MANIFEST).write_text(json.dumps(manifest), encoding="utf-8")

    def test_preparation_is_deterministic_and_has_no_write_side_effects(self):
        before = sorted(path.relative_to(self.root) for path in self.root.rglob("*"))
        files = self.prepare()
        self.assertEqual(set(files), {prebuilt.MANIFEST, *prebuilt.HELPERS.values()})
        self.assertEqual(files, self.prepare())
        self.assertEqual(before, sorted(path.relative_to(self.root) for path in self.root.rglob("*")))
        manifest = json.loads(files[prebuilt.MANIFEST])
        for entry in manifest["files"]:
            self.assertEqual(entry["bytes"], len(files[entry["path"]]))
            self.assertEqual(entry["sha256"], hashlib.sha256(files[entry["path"]]).hexdigest())

    def test_complete_fixture_verifies_both_platforms_and_cli(self):
        manifest = self.install_fixture()
        self.assertEqual(prebuilt.verify_prebuilt_helpers(self.root), manifest)
        result = subprocess.run([sys.executable, str(ROOT / "tools/prebuilt_helpers.py"),
                                 "--root", str(self.root)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)["verified"])

    def test_lua_only_version_can_be_newer_but_cannot_predate_helper(self):
        script = self.root / "SoundPrep.lua"
        script.write_text("-- @version 0.12.0\n", encoding="utf-8")
        manifest = self.install_fixture()
        self.assertEqual(manifest["version"], "0.12.0")
        self.assertEqual(manifest["helper_version"], "0.11.0")
        prebuilt.verify_prebuilt_helpers(self.root)
        script.write_text("-- @version 0.10.0\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "older"):
            self.prepare()

    def test_canonical_soundprep_version_is_used_instead_of_legacy_entrypoint(self):
        (self.root / "Audition Macro.lua").write_text("-- @version 0.10.25\n", encoding="utf-8")
        self.assertEqual(prebuilt.release_versions(self.root), ("0.11.0", "0.11.0"))
        (self.root / "SoundPrep.lua").unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            self.prepare()

    def test_wrong_architecture_format_and_contract_version_are_rejected(self):
        for path, platform in ((self.mac, "macos"), (self.win, "windows")):
            original = path.read_bytes()
            for invalid in (b"not a library", helper_bytes(platform, "0.10.25"),
                            helper_bytes("windows" if platform == "macos" else "macos")):
                with self.subTest(platform=platform, data=invalid[:8]):
                    path.write_bytes(invalid)
                    with self.assertRaises(ValueError):
                        self.prepare()
            path.write_bytes(original)
        broken = bytearray(self.win.read_bytes())
        struct.pack_into("<H", broken, 132, 0x14c)  # x86 is not supported.
        self.win.write_bytes(broken)
        with self.assertRaisesRegex(ValueError, "x64"):
            self.prepare()

    def test_changed_binary_and_size_are_rejected(self):
        manifest = self.install_fixture()
        path = self.root / prebuilt.HELPERS["windows"]
        original = path.read_bytes()
        path.write_bytes(original + b"altered")
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            prebuilt.verify_prebuilt_helpers(self.root)
        path.write_bytes(original)
        manifest["files"][1]["bytes"] += 1
        self.save_manifest(manifest)
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            prebuilt.verify_prebuilt_helpers(self.root)

    def test_hash_update_cannot_hide_wrong_binary_contract_or_format(self):
        manifest = self.install_fixture()
        for data in (helper_bytes("windows", "0.10.25"), b"source code rather than DLL"):
            path = self.root / prebuilt.HELPERS["windows"]
            path.write_bytes(data)
            manifest["files"][1].update(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
            self.save_manifest(manifest)
            with self.assertRaises(ValueError):
                prebuilt.verify_prebuilt_helpers(self.root)

    def test_stale_manifest_or_checkout_version_is_rejected(self):
        baseline = self.install_fixture()
        for field in ("version", "helper_version"):
            manifest = copy.deepcopy(baseline)
            manifest[field] = "0.10.25"
            self.save_manifest(manifest)
            with self.assertRaisesRegex(ValueError, "versions"):
                prebuilt.verify_prebuilt_helpers(self.root)
        self.save_manifest(baseline)
        (self.root / "SoundPrep.lua").write_text("-- @version 0.11.1\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "versions"):
            prebuilt.verify_prebuilt_helpers(self.root)

    def test_manifest_paths_and_entry_schema_are_an_exact_allowlist(self):
        baseline = self.install_fixture()
        for value in ("../helper.dll", "/tmp/helper.dll", "prebuilt/../helper.dll",
                      "prebuilt\\helper.dll", "prebuilt/REAPER_AUDITION_MACRO.DLL", "C:/helper.dll"):
            manifest = copy.deepcopy(baseline)
            manifest["files"][1]["path"] = value
            self.save_manifest(manifest)
            with self.subTest(path=value), self.assertRaisesRegex(ValueError, "allowlisted"):
                prebuilt.verify_prebuilt_helpers(self.root)
        mutations = [
            lambda m: m["files"].pop(),
            lambda m: m["files"].append(m["files"][0]),
            lambda m: m["files"].__setitem__(1, m["files"][0]),
            lambda m: m["files"][1].update(platform="linux"),
            lambda m: m["files"][1].update(bytes=True),
            lambda m: m["files"][1].update(sha256="F" * 64),
            lambda m: m["files"][1].update(source="private.cpp"),
            lambda m: m.update(schema=True),
            lambda m: m.update(extra=True),
        ]
        for mutate in mutations:
            manifest = copy.deepcopy(baseline)
            mutate(manifest)
            self.save_manifest(manifest)
            with self.assertRaises(ValueError):
                prebuilt.verify_prebuilt_helpers(self.root)

    def test_missing_and_unlisted_files_are_rejected(self):
        self.install_fixture()
        extra = self.root / "prebuilt/private.pdb"
        extra.write_bytes(b"debug data")
        with self.assertRaisesRegex(ValueError, "unlisted"):
            prebuilt.verify_prebuilt_helpers(self.root)
        extra.unlink()
        (self.root / prebuilt.HELPERS["windows"]).unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            prebuilt.verify_prebuilt_helpers(self.root)

    def test_symlinked_files_and_roots_are_rejected(self):
        link = self.temp / "linked.dll"
        try:
            link.symlink_to(self.win)
        except OSError as error:
            self.skipTest(f"Symlink creation unavailable: {error}")
        with self.assertRaisesRegex(ValueError, "Symlinks"):
            prebuilt.prepare_prebuilt_helpers(self.root, self.mac, link)
        self.install_fixture()
        root_link = self.temp / "linked-source"
        root_link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "Symlinks"):
            prebuilt.verify_prebuilt_helpers(root_link)
        path = self.root / prebuilt.HELPERS["windows"]
        path.unlink()
        path.symlink_to(self.win)
        with self.assertRaisesRegex(ValueError, "Symlinks"):
            prebuilt.verify_prebuilt_helpers(self.root)


if __name__ == "__main__":
    unittest.main()
