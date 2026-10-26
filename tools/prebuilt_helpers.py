#!/usr/bin/env python3
"""Validate the two reviewed helper binaries used by the public distribution.

The public checkout contains previously published native source, but the new
analysis engine is distributed only inside these prebuilt DLL/dylib files.
This module never compiles, downloads, installs, or modifies a helper.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = "prebuilt/manifest.json"
HELPERS = {
    "macos": "prebuilt/reaper_audition_macro.dylib",
    "windows": "prebuilt/reaper_audition_macro.dll",
}

_spec = importlib.util.spec_from_file_location("_am_release_packager", Path(__file__).with_name("package_release.py"))
_packager = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_packager)


def checked_path(path):
    """Reject symlinks before resolving a path, including ancestor symlinks."""
    path = Path(path).absolute()
    if any(part == ".." for part in path.parts):
        raise ValueError(f"Path traversal is not a prebuilt input: {path}")
    if any(parent.is_symlink() for parent in (path, *path.parents)):
        raise ValueError(f"Symlinks are not prebuilt inputs: {path}")
    if not path.is_file():
        raise ValueError(f"Required prebuilt input is missing: {path}")
    return path


def release_versions(root):
    root = Path(root).absolute()
    script = checked_path(root / "SoundPrep.lua").read_text(encoding="utf-8")
    match = re.search(r"^--\s*@version\s+(\S+)\s*$", script, re.MULTILINE)
    if not match:
        raise ValueError("Main script has no @version")
    contract = json.loads(checked_path(root / "resources/native-contract.json").read_text(encoding="utf-8"))
    if not isinstance(contract, dict) or contract.get("schema") != 1:
        raise ValueError("Unsupported native contract")
    values = (match[1], contract.get("version"))
    for value in values:
        if not isinstance(value, str) or not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", value):
            raise ValueError("Package and helper versions must be major.minor.patch")
        _packager.validate_version(value)
    if tuple(map(int, values[0].split("."))) < tuple(map(int, values[1].split("."))):
        raise ValueError("Package version is older than the native helper version")
    return values


def prepare_prebuilt_helpers(root, macos_helper, windows_helper):
    """Return validated binary and manifest bytes without writing any files."""
    version, helper_version = release_versions(root)
    contract = json.loads(checked_path(Path(root) / "resources/native-contract.json").read_text(encoding="utf-8"))
    inputs = {"macos": macos_helper, "windows": windows_helper}
    result, entries = {}, []
    for platform, relative in HELPERS.items():
        if inputs[platform] is None:
            raise ValueError(f"Missing {platform} helper")
        path = checked_path(inputs[platform])
        data = _packager.validate_helper(path, platform, helper_version, contract)
        result[relative] = data
        entries.append({"platform": platform, "path": relative, "bytes": len(data),
                        "sha256": hashlib.sha256(data).hexdigest()})
    manifest = {"schema": 1, "version": version, "helper_version": helper_version, "files": entries}
    result[MANIFEST] = (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode("utf-8")
    return result


def verify_prebuilt_helpers(root):
    """Check exact helper names, versions, formats, sizes and SHA-256 hashes."""
    root = Path(root).absolute()
    manifest = json.loads(checked_path(root / MANIFEST).read_text(encoding="utf-8"))
    if (not isinstance(manifest, dict)
            or set(manifest) != {"schema", "version", "helper_version", "files"}
            or type(manifest["schema"]) is not int or manifest["schema"] != 1):
        raise ValueError("Unsupported prebuilt manifest")
    version, helper_version = release_versions(root)
    contract = json.loads(checked_path(root / "resources/native-contract.json").read_text(encoding="utf-8"))
    if manifest["version"] != version or manifest["helper_version"] != helper_version:
        raise ValueError("Prebuilt manifest versions do not match this checkout")
    files = manifest["files"]
    if not isinstance(files, list) or len(files) != len(HELPERS):
        raise ValueError("Prebuilt manifest must contain exactly the macOS and Windows helpers")
    seen = set()
    for entry in files:
        if not isinstance(entry, dict) or set(entry) != {"platform", "path", "bytes", "sha256"}:
            raise ValueError("Invalid prebuilt manifest file entry")
        platform = entry["platform"]
        if not isinstance(platform, str) or platform not in HELPERS or platform in seen:
            raise ValueError("Invalid or duplicate prebuilt platform")
        seen.add(platform)
        if entry["path"] != HELPERS[platform]:
            raise ValueError("Prebuilt path must use the exact allowlisted helper name")
        if (type(entry["bytes"]) is not int or entry["bytes"] <= 0
                or not isinstance(entry["sha256"], str)
                or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"])):
            raise ValueError("Invalid prebuilt size or SHA-256")
        data = _packager.validate_helper(checked_path(root / HELPERS[platform]), platform, helper_version, contract)
        if entry["bytes"] != len(data) or entry["sha256"] != hashlib.sha256(data).hexdigest():
            raise ValueError(f"Prebuilt {platform} helper size or SHA-256 does not match its manifest")
    # Unexpected build/debug/source files cannot silently travel beside helpers.
    expected = {"manifest.json", *(Path(name).name for name in HELPERS.values())}
    if {path.name for path in (root / "prebuilt").iterdir()} != expected:
        raise ValueError("Prebuilt directory contains unlisted files")
    return manifest


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    try:
        manifest = verify_prebuilt_helpers(args.root)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"Prebuilt validation failed: {error}\n")
    print(json.dumps({"version": manifest["version"], "helper_version": manifest["helper_version"],
                      "platforms": sorted(HELPERS), "verified": True}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
