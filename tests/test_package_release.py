import copy
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location("package_release", ROOT / "tools/package_release.py")
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


def macos_helper():
    data = bytearray(512)
    struct.pack_into(">II", data, 0, 0xcafebabe, 2)
    for index, cpu in enumerate((0x01000007, 0x0100000c)):
        offset = 128 + index * 128
        struct.pack_into(">IIIII", data, 8 + index * 20, cpu, 0, offset, 128, 2)
        marker = b'{"schema":1,"version":"0.10.21","features":{}}'
        data[offset:offset + len(marker)] = marker
    return bytes(data)


def windows_helper():
    data = bytearray(512)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 60, 128)
    data[128:132] = b"PE\x00\x00"
    struct.pack_into("<H", data, 132, 0x8664)
    struct.pack_into("<H", data, 150, 0x2000)
    marker = b'{"schema":1,"version":"0.10.21","features":{}}'
    data[256:256 + len(marker)] = marker
    return bytes(data)


class PackageReleaseTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="am-release-test-")
        self.addCleanup(directory.cleanup)
        self.temp = Path(directory.name)
        self.root = self.temp / "source"
        self.root.mkdir()
        self.manifest = json.loads((ROOT / "resources/release-manifest.json").read_text())
        for group in ("main_actions", "media_explorer_actions", "support_files"):
            for name in self.manifest[group]:
                self.write(self.manifest.get("aliases", {}).get(name, name), f"fixture: {name}\n".encode())
        self.write("SoundPrep.lua", b"-- @version 0.10.25\n-- fixture\n")
        self.write("resources/native-contract.json", b'{"schema":1,"version":"0.10.21"}\n')
        self.write("LICENSE", b"MIT License\nCopyright fixture\n")
        self.save_manifest()
        self.mac = self.temp / "native.dylib"
        self.mac.write_bytes(macos_helper())
        self.win = self.temp / "native.dll"
        self.win.write_bytes(windows_helper())
        self.serial = 0

    def write(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def save_manifest(self):
        self.write("resources/release-manifest.json", json.dumps(self.manifest).encode())

    def package(self, **changes):
        self.serial += 1
        output = self.temp / f"release-{self.serial}"
        args = dict(root=self.root, output=output, repository="PontakuAudio/SoundPrep",
                    macos_helper=self.mac, windows_helper=self.win)
        args.update(changes)
        report = packager.package_release(**args)
        return output, report

    def test_complete_package_uses_only_tagged_individual_assets_and_correct_sections(self):
        output, report = self.package()
        self.assertTrue(report["publish_ready"])
        self.assertEqual(report["version"], "0.10.25")
        self.assertEqual(report["helper_version"], "0.10.21")
        self.assertEqual(report["script_install_root"], "Scripts/SoundPrep/Media Explorer")
        index = ET.parse(output / "index.xml")
        self.assertEqual(index.getroot().get("name"), "SoundPrep")
        self.assertEqual(index.find("./category/reapack").get("name"), "SoundPrep.lua")
        self.assertEqual(index.find("./category/reapack/version").get("author"), "Pontaku Audio")
        sources = index.findall("./category/reapack/version/source")
        self.assertEqual({source.get("platform") for source in sources}, {"darwin64", "darwin-arm64", "win64"})
        for source in sources:
            url = source.text
            self.assertTrue(url.startswith("https://github.com/PontakuAudio/SoundPrep/releases/download/v0.10.25/"))
            self.assertFalse(url.endswith(".zip"))
            asset = unquote(Path(urlsplit(url).path).name)
            data = (output / asset).read_bytes()
            self.assertEqual(source.get("hash"), "1220" + packager.digest(data))
            filename = source.get("file")
            if source.get("type") == "extension":
                self.assertIn(filename, {"reaper_audition_macro.dylib", "reaper_audition_macro.dll"})
                self.assertNotIn("/", filename)  # extension targets ignore the category
                self.assertIsNone(source.get("main"))
            elif filename in self.manifest["main_actions"]:
                self.assertEqual(source.get("main"), "main")
            elif filename in self.manifest["media_explorer_actions"]:
                self.assertEqual(source.get("main"), "mediaexplorer")
            else:
                self.assertIsNone(source.get("main"))
        self.assertEqual({source.get("file") for source in sources if source.get("main")}, {"SoundPrep.lua"})
        self.assertEqual(len([source for source in sources if source.get("main") == "main"]), 3)
        self.assertFalse(any(source.get("main") == "mediaexplorer" for source in sources))

    def test_manual_zips_preserve_runtime_layout_and_exclude_user_or_host_data(self):
        for name in ("data/bank.json", "data/inserted-media/private.wav", "build/host/reaper-license.rk",
                     "tests/artifacts/capture.png", "docs/private-report.json", "worker/prepare.py", "worker/analyze.py"):
            self.write(name, b"private fixture must not ship")
        output, _ = self.package()
        expected = set(self.manifest["main_actions"] + self.manifest["media_explorer_actions"]
                       + self.manifest["support_files"] + ["LICENSE"])
        for platform in ("macos", "windows"):
            archive_path = output / f"soundprep-0.10.25-{packager.ZIP_LABELS[platform]}.zip"
            with zipfile.ZipFile(archive_path) as archive:
                names = {name.removeprefix("SoundPrep/") for name in archive.namelist()}
                self.assertEqual(names, expected | {"build/" + packager.NATIVE_NAMES[platform]})
                self.assertIn("resources/audition_macro_channels_v1.jsfx", names)
                self.assertIn("THIRD_PARTY_NOTICES.md", names)
                self.assertIn("native/vendor/json.LICENSE.MIT", names)
                self.assertIn("native/vendor/json.THIRD_PARTY_NOTICES.md", names)
                self.assertIn("native/vendor/abseil.LICENSE", names)
                self.assertIn("native/vendor/mosqito.LICENSE.md", names)
                self.assertIn("native/vendor/ebur128.LICENSE.MIT", names)
                self.assertNotIn("worker/analyze.py", names)
                self.assertEqual(archive.read("SoundPrep/lib/am/app.lua"), (self.root / "lib/am/app.lua").read_bytes())
                self.assertEqual(archive.read("SoundPrep/README.md"), (self.root / "docs/release-readme.md").read_bytes())
        for path in output.iterdir():
            if path.suffix != ".zip":
                self.assertNotIn(b"private fixture must not ship", path.read_bytes())

    def test_checksums_cover_every_other_output_and_are_deterministic(self):
        first, _ = self.package()
        second, _ = self.package()
        snapshot = lambda root: {path.name: path.read_bytes() for path in root.iterdir()}
        self.assertEqual(snapshot(first), snapshot(second))
        names = set()
        for line in (first / "SHA256SUMS").read_text().splitlines():
            checksum, name = line.split("  ", 1)
            self.assertEqual(checksum, packager.digest((first / name).read_bytes()))
            names.add(name)
        self.assertEqual(names, {path.name for path in first.iterdir()} - {"SHA256SUMS"})

    def test_fixed_release_time_sets_last_update_and_keeps_builds_reproducible(self):
        timestamp = "2026-10-26T07:54:30Z"
        first, report = self.package(release_time=timestamp)
        second, _ = self.package(release_time=timestamp, previous_index=first / "index.xml")
        self.assertEqual(ET.parse(first / "index.xml").find("./category/reapack/version").get("time"), timestamp)
        self.assertEqual(report["release_time"], timestamp)
        self.assertEqual(json.loads((first / "release.json").read_text())["release_time"], timestamp)
        self.assertEqual({p.name: p.read_bytes() for p in first.iterdir()},
                         {p.name: p.read_bytes() for p in second.iterdir()})
        with self.assertRaisesRegex(ValueError, "immutable"):
            self.package(release_time="2026-10-27T07:54:30Z", previous_index=first / "index.xml")

    def test_invalid_release_time_fails_before_creating_output(self):
        for timestamp in ("", "2026-10-26", "2026-10-26T16:54:30+09:00", "2026-02-30T00:00:00Z",
                          "2026-13-01T00:00:00Z", "2026-10-26T24:00:00Z", "2026-10-26T07:54:60Z"):
            with self.subTest(timestamp=timestamp), self.assertRaisesRegex(ValueError, "Release time"):
                self.package(release_time=timestamp)
        self.assertFalse(any(self.temp.glob("release-*")))

    def test_previous_versions_and_other_packages_are_preserved(self):
        previous = self.temp / "previous.xml"
        previous.write_text('''<index version="1" name="SoundPrep">
<category name="Media Explorer"><reapack name="SoundPrep.lua" type="script" desc="SoundPrep">
<version name="0.10.24" author="old" time="2026-10-01T09:00:00Z"><source file="old.lua" main="main" hash="1220abc">https://old.invalid/v0.10.24/old.lua</source><changelog>Old release notes</changelog></version>
</reapack><reapack name="Other.lua" type="script"><version name="1"><source>https://other.invalid/file.lua</source></version></reapack></category>
<metadata><link rel="website">https://example.com</link></metadata></index>''')
        before = ET.parse(previous).getroot()
        output, _ = self.package(previous_index=previous, website="https://example.com", release_time="2026-10-26T07:54:30Z")
        after = ET.parse(output / "index.xml").getroot()
        old = "./category/reapack[@name='SoundPrep.lua']/version[@name='0.10.24']"
        other = "./category/reapack[@name='Other.lua']"
        self.assertEqual(packager.node_signature(before.find(old)), packager.node_signature(after.find(old)))
        self.assertEqual(packager.node_signature(before.find(other)), packager.node_signature(after.find(other)))
        self.assertEqual(len(after.findall("./category/reapack[@name='SoundPrep.lua']/version")), 2)

    def test_identical_existing_version_is_idempotent(self):
        first, _ = self.package()
        second, _ = self.package(previous_index=first / "index.xml")
        self.assertEqual((first / "index.xml").read_bytes(), (second / "index.xml").read_bytes())

    def test_legacy_package_history_and_urls_are_preserved_when_explicitly_carried_forward(self):
        previous = self.temp / "legacy-package.xml"
        previous.write_text('''<index version="1" name="SoundPrep">
<category name="Media Explorer"><reapack name="Audition Macro.lua" type="script" desc="Audition Macro">
<version name="0.10.25" author="takumakanai"><source file="Audition Macro.lua" main="main" hash="1220abc">https://github.com/kita971/AuditionMacro/releases/download/v0.10.25/old.lua</source></version>
</reapack></category></index>''')
        original = previous.read_bytes()
        old_path = "./category/reapack[@name='Audition Macro.lua']"
        before = packager.node_signature(ET.parse(previous).find(old_path))
        output, _ = self.package(previous_index=previous)
        after = ET.parse(output / "index.xml")
        self.assertEqual(packager.node_signature(after.find(old_path)), before)
        self.assertEqual(previous.read_bytes(), original)
        self.assertIsNotNone(after.find("./category/reapack[@name='SoundPrep.lua']"))

    def test_old_brand_index_requires_explicit_migration_and_is_never_rewritten(self):
        previous = self.temp / "audition-macro-index.xml"
        original = b'<index version="1" name="Audition Macro"><category name="Media Explorer"/></index>'
        previous.write_bytes(original)
        with self.assertRaisesRegex(ValueError, "identity"):
            self.package(previous_index=previous)
        self.assertEqual(previous.read_bytes(), original)
        self.assertFalse(any(self.temp.glob("release-*")))

    def test_existing_version_cannot_be_changed_by_content_or_download_location(self):
        first, _ = self.package()
        previous = first / "index.xml"
        with self.assertRaisesRegex(ValueError, "immutable"):
            self.package(previous_index=previous, repository="other/repository")
        self.write("lib/am/app.lua", b"changed release content")
        with self.assertRaisesRegex(ValueError, "immutable"):
            self.package(previous_index=previous)

    def test_missing_license_required_file_or_helper_fails_before_creating_output(self):
        for missing in ("LICENSE", "native/vendor/mosqito.LICENSE.md",
                        "native/vendor/ebur128.LICENSE.MIT", "lib/am/wave_channels.lua",
                        "resources/audition_macro_channels_v1.jsfx"):
            path = self.root / missing
            content = path.read_bytes()
            path.unlink()
            try:
                with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, "Required release file"):
                    self.package()
            finally:
                path.write_bytes(content)
        with self.assertRaisesRegex(ValueError, "Missing --windows-helper"):
            self.package(windows_helper=None)
        self.assertFalse(any(self.temp.glob("release-*")))

    def test_explicit_single_platform_is_a_non_publishable_local_candidate(self):
        output, report = self.package(platform="macos", windows_helper=None)
        self.assertFalse(report["publish_ready"])
        self.assertEqual(report["platforms"], ["macos"])
        self.assertFalse((output / "reaper_audition_macro.dll").exists())
        sources = ET.parse(output / "index.xml").findall("./category/reapack/version/source")
        self.assertEqual({node.get("platform") for node in sources}, {"darwin64", "darwin-arm64"})

    def test_existing_output_is_never_overwritten(self):
        output = self.temp / "existing"
        output.mkdir()
        sentinel = output / "unchanged"
        sentinel.write_bytes(b"keep")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.package(output=output)
        self.assertEqual(sentinel.read_bytes(), b"keep")

    def test_manifest_rejects_traversal_user_paths_duplicates_and_symlinks(self):
        original = copy.deepcopy(self.manifest)
        for name in ("../secret", "/absolute/file", "data/bank.json", "build/host/reaper-license.rk",
                     "tests/artifacts/private", "lib/./am/app.lua", "lib\\am\\app.lua", "LIB/am/app.lua"):
            self.manifest = copy.deepcopy(original)
            self.manifest["support_files"].append(name)
            self.save_manifest()
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.package()
        self.manifest = original
        self.save_manifest()
        app = self.root / "lib/am/app.lua"
        app.unlink()
        app.symlink_to(self.mac)
        with self.assertRaisesRegex(ValueError, "Symlinks"):
            self.package()

    def test_wrong_architecture_truncated_or_stale_helpers_are_rejected(self):
        invalid_mac = bytearray(macos_helper())
        struct.pack_into(">I", invalid_mac, 28, 0x01000007)
        for platform, invalid in (("macos", bytes(invalid_mac)), ("macos", macos_helper()[:30]),
                                  ("windows", b"not a DLL"), ("windows", windows_helper().replace(b"0.10.21", b"0.10.17"))):
            path = self.mac if platform == "macos" else self.win
            good = path.read_bytes()
            path.write_bytes(invalid)
            try:
                with self.subTest(platform=platform), self.assertRaises(ValueError):
                    self.package()
            finally:
                path.write_bytes(good)
        wrong_win = bytearray(windows_helper())
        struct.pack_into("<H", wrong_win, 132, 0x14c)
        self.win.write_bytes(wrong_win)
        with self.assertRaisesRegex(ValueError, "x64"):
            self.package()

    def test_version_tag_and_base_are_validated(self):
        with self.assertRaisesRegex(ValueError, "differs"):
            self.package(version="0.10.26")
        for tag in ("latest", "main", "../v0.10.25"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                self.package(tag=tag)
        for base in ("https://example.com/latest", "http://example.com/v0.10.25",
                     "https://user:password@example.com/v0.10.25", "https://example.com/v0.10.25?token=secret"):
            with self.subTest(base=base), self.assertRaises(ValueError):
                self.package(base=base)
        output, report = self.package(repository=None, base="https://downloads.example.com/releases/{tag}")
        self.assertEqual(report["download_base"], "https://downloads.example.com/releases/v0.10.25")
        self.assertIn(b"https://downloads.example.com/releases/v0.10.25/", (output / "index.xml").read_bytes())

    def test_index_identity_and_dtd_are_rejected(self):
        first, _ = self.package()
        with self.assertRaisesRegex(ValueError, "identity"):
            self.package(previous_index=first / "index.xml", index_name="Different")
        previous = self.temp / "entity.xml"
        previous.write_text('<!DOCTYPE index [<!ENTITY x "unsafe">]><index version="1" name="SoundPrep"/>')
        with self.assertRaisesRegex(ValueError, "DTD"):
            self.package(previous_index=previous)

    def test_allowlist_covers_all_current_modules_actions_and_required_assets(self):
        manifest = json.loads((ROOT / "resources/release-manifest.json").read_text())
        listed = set(manifest["main_actions"] + manifest["media_explorer_actions"] + manifest["support_files"])
        for folder, pattern in (("lib/am", "*.lua"), ("actions", "*.lua"), ("resources/chains", "*.RfxChain")):
            required = {path.relative_to(ROOT).as_posix() for path in (ROOT / folder).glob(pattern)}
            withheld = {"lib/am/search.lua", "lib/am/search_dictionary.lua",
                        "lib/am/search_phrase.lua", "lib/am/search_session.lua"}
            withheld.update(f"actions/{prefix} - Search {action}.lua"
                            for prefix in ("SoundPrep", "Audition Macro")
                            for action in ("Assist", "Expand", "Restore"))
            self.assertLessEqual(required - withheld, listed)
            self.assertFalse(listed & withheld)
        self.assertNotIn("worker/analyze.py", listed)
        self.assertIn("native/vendor/mosqito.LICENSE.md", listed)
        self.assertIn("native/vendor/ebur128.LICENSE.MIT", listed)
        self.assertNotIn("worker/prepare.py", listed)
        self.assertNotIn("worker/prepare.lua", listed)
        self.assertEqual(manifest["package_name"], "SoundPrep.lua")
        self.assertEqual(manifest["main_actions"], ["SoundPrep.lua"])
        self.assertEqual(manifest["media_explorer_actions"], [])
        # Optional actions and old aliases stay at their original paths, so an
        # update does not delete existing action registrations or shortcuts.
        self.assertIn("SoundPrep - Install actions.lua", manifest["support_files"])
        for path in ROOT.glob("SoundPrep - *.lua"):
            self.assertIn(path.name, manifest["support_files"])
        for group in ("main_actions", "media_explorer_actions"):
            for name in manifest[group]:
                self.assertIn("SoundPrep", name)
                legacy = name.replace("SoundPrep", "Audition Macro")
                self.assertIn(legacy, manifest["support_files"])
                self.assertNotIn(legacy, manifest[group])


if __name__ == "__main__":
    unittest.main()
