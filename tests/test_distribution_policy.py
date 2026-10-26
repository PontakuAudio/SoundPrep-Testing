"""Verify the actual distribution boundary and retained upstream notices."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("policy_packager", ROOT / "tools/package_release.py")
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class DistributionPolicyTests(unittest.TestCase):
    def test_upstream_files_match_recorded_originals_and_notices_ship(self):
        provenance = json.loads((ROOT / "resources/third-party-provenance.json").read_text(encoding="utf-8"))
        runtime = json.loads((ROOT / "resources/release-manifest.json").read_text(encoding="utf-8"))
        public = set(json.loads((ROOT / "resources/public-source-files.json").read_text(encoding="utf-8"))["files"])
        shipped = set(runtime["support_files"]) | {runtime["license_file"]}
        for entry in provenance["files"]:
            with self.subTest(path=entry["path"]):
                self.assertEqual(hashlib.sha256((ROOT / entry["path"]).read_bytes()).hexdigest(), entry["sha256"])
                self.assertIn(entry["path"], public)
                if entry["path"] != "native/vendor/json.hpp":
                    self.assertIn(entry["path"], shipped)
        for path in ("LICENSE", "THIRD_PARTY_NOTICES.md", "native/vendor/json.THIRD_PARTY_NOTICES.md",
                     "native/vendor/abseil.LICENSE", "resources/third-party-provenance.json"):
            self.assertIn(path, shipped)
            self.assertIn(path, public)
        notice = (ROOT / "native/vendor/json.THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
        for author in ("Björn Hoehrmann", "Florian Loitsch", "Evan Nemerson", "The Abseil Authors"):
            self.assertIn(author, notice)
        self.assertIn("Permission is hereby granted", notice)
        self.assertIn("Apache", notice)

    def test_dictionary_assistance_is_absent_from_source_and_runtime_exports(self):
        runtime = json.loads((ROOT / "resources/release-manifest.json").read_text(encoding="utf-8"))
        shipped = set(runtime["support_files"] + runtime["main_actions"] + runtime["media_explorer_actions"])
        public = set(json.loads((ROOT / "resources/public-source-files.json").read_text(encoding="utf-8"))["files"])
        withheld = {"resources/search-dictionary.json", "resources/synonyms.json",
                    "docs/search-assistance.md", "docs/search-dictionary-sources.md",
                    "lib/am/search.lua", "lib/am/search_dictionary.lua", "lib/am/search_phrase.lua",
                    "lib/am/search_session.lua", "tests/search.lua", "tests/search_vocabulary.lua",
                    "tests/reaper_search.lua", "tests/reaper_search_bar.lua", "tests/reaper_search_phrases.lua"}
        withheld.update(f"actions/{prefix} - Search {action}.lua"
                        for prefix in ("SoundPrep", "Audition Macro")
                        for action in ("Assist", "Expand", "Restore"))
        self.assertFalse(withheld & public)
        self.assertFalse(withheld & shipped)
        contract = json.loads((ROOT / "resources/native-contract.json").read_text(encoding="utf-8"))
        self.assertFalse(any(c["command"].startswith("search:") for c in contract["bar"]["controls"]))
        self.assertGreaterEqual(contract["features"]["bar"]["revision"], 4)

    def test_same_version_helper_with_stale_features_is_rejected(self):
        # A structurally valid PE fixture with a current version but obsolete UI.
        import struct
        data = bytearray(512)
        data[:2] = b"MZ"
        struct.pack_into("<I", data, 60, 128)
        data[128:132] = b"PE\x00\x00"
        struct.pack_into("<H", data, 132, 0x8664)
        struct.pack_into("<H", data, 150, 0x2000)
        contract = {"features": {"bar": {"revision": 4}}}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "helper.dll"
            for revision in (3, 4):
                info = {"schema": 1, "version": "0.11.0", "platform": "windows", "features": {"bar": revision}}
                marker = json.dumps(info, separators=(",", ":")).encode()
                sample = data.copy()
                sample[256:256 + len(marker)] = marker
                path.write_bytes(sample)
                if revision == 3:
                    with self.assertRaisesRegex(ValueError, "feature revisions"):
                        packager.validate_helper(path, "windows", "0.11.0", contract)
                else:
                    self.assertEqual(packager.validate_helper(path, "windows", "0.11.0", contract), sample)


if __name__ == "__main__":
    unittest.main()
