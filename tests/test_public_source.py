import copy
import importlib.util
import json
from pathlib import Path
import re
import struct
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("prepare_public_source", ROOT / "tools/prepare_public_source.py")
public = importlib.util.module_from_spec(spec)
spec.loader.exec_module(public)


class PublicSourceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="am-public-source-test-")
        self.addCleanup(temporary.cleanup)
        self.temp = Path(temporary.name).resolve()
        self.root = self.temp / "source"
        self.root.mkdir()
        self.output = self.temp / "public"
        self.manifest = json.loads((ROOT / "resources/release-manifest.json").read_text(encoding="utf-8"))
        self.public_manifest = json.loads((ROOT / public.PUBLIC_FILES).read_text(encoding="utf-8"))
        self.public_manifest["files"].append("tests/unit/nested.lua")
        runtime = self.manifest["main_actions"] + self.manifest["media_explorer_actions"]
        runtime += self.manifest["support_files"] + [self.manifest["license_file"]]
        inputs = set(self.public_manifest["files"]) | set(self.public_manifest["aliases"].values())
        for name in set(runtime) | inputs:
            self.write(name, "safe source fixture\n")
        self.write("SoundPrep.lua", "-- @version 0.10.25\n")
        self.write("README.md", "private historical README\n")
        self.write(public.PUBLIC_README, "# SoundPrep\nPublic install and build guide.\n")
        self.write(".gitignore", "*.pyc\n")
        self.write("resources/native-contract.json", '{"schema":1,"version":"0.10.25"}\n')
        self.write("native/preview.cpp", "void preview() {}\n")
        self.write("native/vendor/README.md", "Bundled library provenance.\n")
        self.write("native/README.md", "Historical notes must not ship.\n")
        self.write("tools/prepare_public_source.py", "# safe tool fixture\n")
        self.write("tests/run.lua", "print('regressions')\n")
        self.write("tests/native_drop_host.mm", "// isolated test host source\n")
        self.write("tests/unit/nested.lua", "-- source dependency\n")
        self.save_manifest()
        self.save_public_manifest()

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def save_manifest(self):
        self.write(public.MANIFEST, json.dumps(self.manifest))

    def save_public_manifest(self):
        self.write(public.PUBLIC_FILES, json.dumps(self.public_manifest))

    def approve(self, *paths):
        self.public_manifest["files"].extend(paths)
        self.save_public_manifest()

    def test_complete_runtime_and_build_sources_with_public_readme_and_hashes(self):
        self.output.mkdir()  # An explicitly empty destination is supported.
        report = public.prepare_source(self.root, self.output)
        runtime = set(self.manifest["main_actions"] + self.manifest["media_explorer_actions"]
                      + self.manifest["support_files"] + [self.manifest["license_file"]])
        self.assertEqual(set(report["runtime_files"]), runtime)
        self.assertTrue(all((self.output / path).is_file() for path in runtime))
        self.assertEqual((self.output / "README.md").read_bytes(), (self.root / public.PUBLIC_README).read_bytes())
        self.assertNotEqual((self.output / "README.md").read_bytes(), (self.root / "README.md").read_bytes())
        for target, source in public.REQUIRED_ALIASES.items():
            self.assertEqual((self.output / target).read_bytes(), (self.root / source).read_bytes())
        for path in ("native/preview.cpp", "native/vendor/README.md", "CMakeLists.txt",
                     "worker/analyze.py", "worker/prepare.py", "worker/prepare.lua", "tests/native_drop_host.mm",
                     "tests/unit/nested.lua", "tests/native-bar-cases.json",
                     ".github/workflows/windows.yml", ".github/workflows/release.yml"):
            self.assertTrue((self.output / path).is_file(), path)
        self.assertNotIn("worker/analyze.py", runtime)
        self.assertIn("native/vendor/mosqito.LICENSE.md", runtime)
        self.assertIn("native/vendor/ebur128.LICENSE.MIT", runtime)
        self.assertFalse((self.output / "native/README.md").exists())
        self.assertEqual(report["privacy"]["status"], "pass")
        self.assertFalse(report["git_history_included"])
        self.assertFalse(report["prebuilt_helpers_included"])
        self.assertNotIn(str(self.root), json.dumps(report))
        written = json.loads((self.output / public.OUTPUT_MANIFEST).read_text(encoding="utf-8"))
        self.assertEqual(written, report)
        for entry in report["files"]:
            data = (self.output / entry["path"]).read_bytes()
            self.assertEqual(entry["sha256"], public.digest(data))
            self.assertEqual(entry["bytes"], len(data))
        for pattern in ("data/", "build/", "tests/artifacts/", "__pycache__/"):
            self.assertIn(pattern, (self.output / ".gitignore").read_text(encoding="utf-8").splitlines())

    def test_workspace_data_artifacts_media_reports_and_excluded_symlinks_never_ship(self):
        for name in ("data/bank.json", "build/host/reaper-license.rk", ".git/config",
                     ".codex/config.toml", "tests/artifacts/private.lua", "tests/reports/private.py",
                     "tests/generated/private.cpp", "tests/media/private.wav", "tests/capture.png",
                     "tests/measurements.json", "docs/private-report.json", "docs/validation.md",
                     "tools/.credentials.py", "private.py", "native/new_algorithm.cpp",
                     "native/new_algorithm.h", "tests/new_native_test.cpp", "tools/new_reference.py",
                     "tests/new_lua_test.lua", "OtherScripts/Zwicker/analyzer/fast_loudness.py",
                     *public.PRIVATE_FILES):
            self.write(name, "PRIVATE EXCLUDED FIXTURE\n")
        outside = self.temp / "private"
        outside.mkdir()
        (outside / "hidden.lua").write_text("PRIVATE LINK TARGET")
        (self.root / "tests/build").symlink_to(outside, target_is_directory=True)
        (self.root / "native/data").symlink_to(outside, target_is_directory=True)
        report = public.prepare_source(self.root, self.output)
        for entry in report["files"]:
            self.assertNotIn(b"PRIVATE", (self.output / entry["path"]).read_bytes())
        self.assertFalse((self.output / ".git").exists())
        self.assertFalse((self.output / "tests/measurements.json").exists())

    def test_private_inputs_are_rejected_even_when_added_to_runtime_or_public_allowlist(self):
        original_runtime, original_public = copy.deepcopy(self.manifest), copy.deepcopy(self.public_manifest)
        for name in (*sorted(public.PRIVATE_FILES), "OtherScripts/Zwicker/analyzer/fast_loudness.py",
                     "NATIVE/Zwicker.cpp", "otherscripts/reference.py"):
            for through_runtime in (True, False):
                self.manifest, self.public_manifest = copy.deepcopy(original_runtime), copy.deepcopy(original_public)
                if through_runtime:
                    self.manifest["support_files"].append(name)
                else:
                    self.public_manifest["files"].append(name)
                self.save_manifest()
                self.save_public_manifest()
                with self.subTest(name=name, runtime=through_runtime), self.assertRaisesRegex(ValueError, "Private implementation"):
                    public.prepare_source(self.root, self.output)
                self.assertFalse(self.output.exists())

    def test_runtime_cannot_implicitly_add_unreviewed_sources_or_private_aliases(self):
        self.write("native/future_engine.cpp", "unreviewed implementation")
        self.manifest["support_files"].append("native/future_engine.cpp")
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "explicitly approved"):
            public.prepare_source(self.root, self.output)
        self.manifest["support_files"].pop()
        self.manifest["aliases"] = {"README.md": "native/zwicker.cpp"}
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "Private implementation"):
            public.prepare_source(self.root, self.output)
        self.assertFalse(self.output.exists())

    def test_public_allowlist_rejects_duplicates_generated_outputs_and_unsafe_aliases(self):
        original = copy.deepcopy(self.public_manifest)
        for name in ("native/preview.cpp", "NATIVE/preview.cpp", "prebuilt/manifest.json",
                     "public-source-manifest.json", "../private.py"):
            self.public_manifest = copy.deepcopy(original)
            self.public_manifest["files"].append(name)
            self.save_public_manifest()
            with self.subTest(name=name), self.assertRaises(ValueError):
                public.prepare_source(self.root, self.output)
        self.public_manifest = copy.deepcopy(original)
        self.public_manifest["aliases"]["native/preview.cpp"] = "native/analysis.cpp"
        self.save_public_manifest()
        with self.assertRaisesRegex(ValueError, "Private implementation"):
            public.prepare_source(self.root, self.output)
        for target in public.REQUIRED_ALIASES:
            self.public_manifest = copy.deepcopy(original)
            del self.public_manifest["aliases"][target]
            self.save_public_manifest()
            with self.subTest(target=target), self.assertRaisesRegex(ValueError, "reviewed aliases"):
                public.prepare_source(self.root, self.output)
        self.assertFalse(self.output.exists())

    def test_required_missing_file_and_unsafe_manifest_fail_without_output(self):
        missing = self.root / "lib/am/app.lua"
        contents = missing.read_bytes()
        missing.unlink()
        with self.assertRaisesRegex(ValueError, "Required source file"):
            public.prepare_source(self.root, self.output)
        missing.write_bytes(contents)
        original = copy.deepcopy(self.manifest)
        for name in ("../outside.lua", "/absolute.lua", "lib/../private.lua", "data/bank.json",
                     "build/helper.lua", "lib\\file.lua", ".git/config", "LIB/am/app.lua"):
            self.manifest = copy.deepcopy(original)
            self.manifest["support_files"].append(name)
            self.save_manifest()
            with self.subTest(name=name), self.assertRaises(ValueError):
                public.prepare_source(self.root, self.output)
            self.assertFalse(self.output.exists())

    def test_symlink_file_directory_root_or_destination_is_rejected(self):
        outside = self.temp / "outside"
        outside.mkdir()
        (outside / "private.py").write_text("private target")
        candidates = (
            (self.root / "tools/linked.py", outside / "private.py", False, "tools/linked.py"),
            (self.root / "tests/linked", outside, True, "tests/linked/private.py"),
        )
        for link, target, directory, approved in candidates:
            self.approve(approved)
            link.symlink_to(target, target_is_directory=directory)
            try:
                with self.assertRaisesRegex(ValueError, "Symlink"):
                    public.prepare_source(self.root, self.output)
            finally:
                link.unlink()
                self.public_manifest["files"].remove(approved)
                self.save_public_manifest()
        root_link = self.temp / "linked-source"
        root_link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            public.prepare_source(root_link, self.output)
        self.output.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            public.prepare_source(self.root, self.output)
        self.assertEqual((outside / "private.py").read_text(encoding="utf-8"), "private target")
        self.output.unlink()
        (self.temp / "linked-parent").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            public.prepare_source(self.root, self.temp / "linked-parent/new-output")
        self.assertFalse((outside / "new-output").exists())

    def test_nonempty_destination_is_preserved(self):
        self.output.mkdir()
        sentinel = self.output / "keep.txt"
        sentinel.write_text("existing work")
        with self.assertRaisesRegex(ValueError, "empty"):
            public.prepare_source(self.root, self.output)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "existing work")
        self.assertEqual(list(self.output.iterdir()), [sentinel])

    def test_empty_destination_is_removed_before_windows_directory_rename(self):
        self.output.mkdir()
        rename = public.os.rename

        def windows_rename(source, destination):
            # Windows MoveFileEx rejects replacing an existing directory,
            # including an empty directory accepted by POSIX rename.
            if Path(destination).exists():
                raise PermissionError("Windows cannot replace a directory")
            return rename(source, destination)

        with mock.patch.object(public.os, "replace", side_effect=windows_rename), \
                mock.patch.object(public.os, "rename", side_effect=windows_rename) as moved:
            report = public.prepare_source(self.root, self.output)
        self.assertEqual(moved.call_count, 1)
        self.assertEqual(report["privacy"]["status"], "pass")
        self.assertTrue((self.output / public.OUTPUT_MANIFEST).is_file())
        self.assertFalse(list(self.temp.glob(".am-public-source-*")))

    def test_file_arriving_after_final_validation_prevents_rmdir_and_is_preserved(self):
        self.output.mkdir()
        rmdir = Path.rmdir
        sentinel = self.output / "arrived.txt"

        def concurrent_write(path):
            if path == self.output:
                sentinel.write_text("new user work")
            return rmdir(path)

        with mock.patch.object(Path, "rmdir", concurrent_write):
            with self.assertRaises(OSError):
                public.prepare_source(self.root, self.output)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "new user work")
        self.assertEqual(list(self.output.iterdir()), [sentinel])
        self.assertFalse(list(self.temp.glob(".am-public-source-*")))

    def test_nonempty_destination_recreated_before_rename_is_preserved(self):
        self.output.mkdir()
        rename = public.os.rename
        sentinel = self.output / "arrived.txt"

        def concurrent_destination(source, destination):
            self.output.mkdir()
            sentinel.write_text("new user work")
            return rename(source, destination)

        with mock.patch.object(public.os, "rename", side_effect=concurrent_destination):
            with self.assertRaises(OSError):
                public.prepare_source(self.root, self.output)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "new user work")
        self.assertEqual(list(self.output.iterdir()), [sentinel])
        self.assertFalse(list(self.temp.glob(".am-public-source-*")))

    def test_privacy_fails_before_copy_and_never_reports_the_matched_secret(self):
        self.approve("tools/unsafe.py")
        values = [
            "/" + "Users" + "/private-owner/recording.wav",
            "C:" + "\\" + "Users" + "\\" + "private-owner" + "\\project",
            "gh" + "p_" + "A" * 36,
            "-----BEGIN " + "OPENSSH PRIVATE KEY-----",
            "AK" + "IA" + "A" * 16,
            "https://github.com/kita971/" + "ReaScript/actions",
        ]
        for value in values:
            self.write("tools/unsafe.py", value)
            with self.subTest(value=value), self.assertRaises(public.PrivacyError) as raised:
                public.prepare_source(self.root, self.output)
            self.assertFalse(self.output.exists())
            safe_report = json.dumps(raised.exception.report)
            self.assertNotIn(value, safe_report)
            self.assertNotIn(value, str(raised.exception))
            self.assertEqual(raised.exception.report["findings"][0]["path"], "tools/unsafe.py")

    def test_only_exact_synthetic_windows_profile_exception_is_allowed(self):
        fixture = "C:" + "\\" + "Users" + "\\" + "音" + "\\AppData\\Local"
        self.write("tests/platform.lua", fixture)
        report = public.prepare_source(self.root, self.output)
        self.assertEqual(len(report["privacy"]["synthetic_fixture_exceptions"]), 1)
        for path, text in (("tests/platform.lua", fixture.replace("音", "real-person")),
                           ("tools/other.py", fixture)):
            if path not in self.public_manifest["files"]:
                self.approve(path)
            self.write(path, text)
            with self.subTest(path=path), self.assertRaises(public.PrivacyError):
                public.prepare_source(self.root, self.temp / "another-output")
            if path == "tests/platform.lua":
                self.write(path, fixture)

    def test_output_is_deterministic_and_contains_no_unlisted_files(self):
        first = public.prepare_source(self.root, self.output)
        second_dir = self.temp / "second"
        second = public.prepare_source(self.root, second_dir)
        self.assertEqual(first, second)
        snapshot = lambda directory: {path.relative_to(directory).as_posix(): path.read_bytes()
                                      for path in directory.rglob("*") if path.is_file()}
        self.assertEqual(snapshot(self.output), snapshot(second_dir))
        self.assertEqual(set(snapshot(self.output)), {entry["path"] for entry in first["files"]} | {public.OUTPUT_MANIFEST})

    def test_helper_arguments_must_be_supplied_as_a_pair_before_output(self):
        for kwargs in ({"macos_helper": self.temp / "mac.dylib"}, {"windows_helper": self.temp / "win.dll"}):
            with self.subTest(kwargs=kwargs), self.assertRaisesRegex(ValueError, "supplied together"):
                public.prepare_source(self.root, self.output, **kwargs)
            self.assertFalse(self.output.exists())

    def helpers(self):
        mac, win = self.temp / "helper.dylib", self.temp / "helper.dll"
        marker = b'{"schema":1,"version":"0.10.25","features":{}}'
        data = bytearray(512)
        struct.pack_into(">II", data, 0, 0xcafebabe, 2)
        for index, cpu in enumerate((0x01000007, 0x0100000c)):
            offset = 128 + index * 128
            struct.pack_into(">IIIII", data, 8 + index * 20, cpu, 0, offset, 128, 2)
            data[offset:offset + len(marker)] = marker
        mac.write_bytes(data)
        data = bytearray(512)
        data[:2] = b"MZ"
        struct.pack_into("<I", data, 60, 128)
        data[128:132] = b"PE\x00\x00"
        struct.pack_into("<H", data, 132, 0x8664)
        struct.pack_into("<H", data, 150, 0x2000)
        data[256:256 + len(marker)] = marker
        win.write_bytes(data)
        return mac, win

    def test_verified_helpers_and_manifest_are_copied_after_text_privacy_scan(self):
        mac, win = self.helpers()
        report = public.prepare_source(self.root, self.output, macos_helper=mac, windows_helper=win)
        self.assertTrue(report["prebuilt_helpers_included"])
        self.assertEqual((self.output / "prebuilt/reaper_audition_macro.dylib").read_bytes(), mac.read_bytes())
        self.assertEqual((self.output / "prebuilt/reaper_audition_macro.dll").read_bytes(), win.read_bytes())
        manifest = json.loads((self.output / "prebuilt/manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["version"], "0.10.25")
        self.assertEqual(manifest["helper_version"], "0.10.25")
        for entry in manifest["files"]:
            self.assertEqual(entry["sha256"], public.digest((self.output / entry["path"]).read_bytes()))
        self.assertEqual(report["privacy"]["status"], "pass")
        self.assertEqual(report["privacy"]["scanned_files"], len(report["files"]) - 3)

    def test_invalid_helper_cannot_leave_a_partial_snapshot(self):
        mac, win = self.helpers()
        win.write_bytes(b"wrong-format")
        with self.assertRaises(ValueError):
            public.prepare_source(self.root, self.output, macos_helper=mac, windows_helper=win)
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.temp.glob(".am-public-source-*")))

    def test_privacy_failure_does_not_validate_or_copy_helpers(self):
        self.write("lib/am/app.lua", "gh" + "p_" + "A" * 36)
        with mock.patch.object(public, "prepare_prebuilt_helpers") as helpers:
            with self.assertRaises(public.PrivacyError):
                public.prepare_source(self.root, self.output, macos_helper="unused", windows_helper="unused")
            helpers.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_actual_allowlist_covers_current_lua_regressions_and_never_native_engine(self):
        manifest = json.loads((ROOT / public.PUBLIC_FILES).read_text(encoding="utf-8"))
        paths = set(manifest["files"])
        dependencies = set(re.findall(r"dofile\(['\"]([^'\"]+)['\"]\)", (ROOT / "tests/run.lua").read_text(encoding="utf-8")))
        self.assertFalse(dependencies - paths, dependencies - paths)
        self.assertFalse(paths & public.PRIVATE_FILES)
        self.assertFalse(any(path.startswith("OtherScripts/") for path in paths))


if __name__ == "__main__":
    unittest.main()
