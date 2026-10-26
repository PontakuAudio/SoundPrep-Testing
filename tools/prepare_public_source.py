#!/usr/bin/env python3
"""Prepare a reviewed source snapshot without Git history or workspace data.

Only reviewed, explicitly allowlisted public sources are copied. New native
analysis implementations stay private; an optional verified pair of prebuilt
helpers makes the snapshot ready for public CI. This tool never publishes.
Privacy failures report relative filenames, line numbers and rule names only.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = "resources/release-manifest.json"
PUBLIC_README = "docs/release-readme.md"
PUBLIC_FILES = "resources/public-source-files.json"
OUTPUT_MANIFEST = "public-source-manifest.json"
EXCLUDED_PARTS = {
    "data", "build", "artifacts", "reports", "test-results", "generated", "media",
    ".git", ".codex", ".agents", "__pycache__", ".pytest_cache",
}
PRIVATE_FILES = {
    "native/analysis.cpp", "native/zwicker.cpp", "native/zwicker.h",
    "native/lufs_meter.cpp", "native/lufs_meter.h", "native/test_analysis.cpp",
    "native/test_zwicker.cpp", "native/test_lufs_meter.cpp", "tools/zwicker_reference.py",
}
REQUIRED_ALIASES = {
    "README.md": PUBLIC_README,
    ".github/workflows/windows.yml": "resources/public-workflows/windows.yml",
    ".github/workflows/release.yml": "resources/public-workflows/release.yml",
}
PRIVACY_RULES = {
    "home-directory-literal": re.compile(
        r"/(?:Users|home)/[A-Za-z0-9_\u0080-\uffff][^/\s\"'<>]*"
        r"|[A-Za-z]:\\+Users\\+[A-Za-z0-9_\u0080-\uffff][^\\\s\"'<>]*"
    ),
    "private-development-repository": re.compile(
        r"https?://github\.com/kita971/" + r"ReaScript(?:[/#?\s\"')]|$)"
    ),
    "github-token": re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    "private-key": re.compile(r"-----BEGIN (?:RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----"),
    "aws-access-key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
}
# An invented Unicode profile is required by the Windows path unit test. Match
# only its exact filename and matched username; no test directory is exempt.
FIXTURE_EXCEPTIONS = {
    ("tests/platform.lua", "home-directory-literal", "C:" + "\\" + "Users" + "\\" + "音"),
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def linked(path):
    return path.is_symlink() or getattr(path, "is_junction", lambda: False)()


def reject_linked_ancestors(path, label):
    # macOS presents its standard temporary roots through these system aliases.
    # Accept only their exact OS destinations, never arbitrary directory links.
    aliases = {Path("/tmp"): Path("/private/tmp"), Path("/var"): Path("/private/var"),
               Path("/etc"): Path("/private/etc")} if sys.platform == "darwin" else {}
    path = path.absolute()
    for part in (path, *path.parents):
        if linked(part) and not (part in aliases and part.resolve() == aliases[part]):
            raise ValueError(f"{label} must not use symlink directories")


def safe_relative(value):
    if (not isinstance(value, str) or not value or "\\" in value or ":" in value
            or value.startswith("/") or any(ord(char) < 32 for char in value)):
        raise ValueError("Unsafe source path")
    parts = value.split("/")
    if any(part in ("", ".", "..") or part.casefold() in EXCLUDED_PARTS for part in parts):
        raise ValueError(f"Excluded or traversing source path: {value}")
    if value.casefold() in PRIVATE_FILES or parts[0].casefold() == "otherscripts":
        raise ValueError(f"Private implementation cannot be published: {value}")
    if parts[0].casefold() == "prebuilt" or value.casefold() == OUTPUT_MANIFEST:
        raise ValueError(f"Generated output cannot be a source input: {value}")
    return PurePosixPath(value).as_posix()


def read_input(root, relative):
    relative = safe_relative(relative)
    path = root / relative
    current = root
    for part in PurePosixPath(relative).parts:
        current = current / part
        if linked(current):
            raise ValueError(f"Symlink source input: {relative}")
    if not path.resolve().is_relative_to(root):
        raise ValueError(f"Source input escapes root: {relative}")
    if not path.is_file():
        raise ValueError(f"Required source file is missing: {relative}")
    return path.read_bytes()


def public_inputs(root):
    manifest = json.loads(read_input(root, PUBLIC_FILES))
    if manifest.get("schema") != 1 or not isinstance(manifest.get("files"), list):
        raise ValueError("Unsupported public source allowlist")
    selected, folded = set(), set()
    for value in manifest["files"]:
        name = safe_relative(value)
        if name.casefold() in folded:
            raise ValueError(f"Duplicate public source path: {name}")
        folded.add(name.casefold())
        selected.add(name)
    for required in (PUBLIC_FILES, MANIFEST, ".gitignore", *REQUIRED_ALIASES):
        if required not in selected:
            raise ValueError(f"Public source allowlist is missing: {required}")
    aliases = manifest.get("aliases", {})
    if not isinstance(aliases, dict):
        raise ValueError("Public source aliases must be an object")
    for target, source in aliases.items():
        safe_relative(target)
        safe_relative(source)
        if target not in selected or source not in selected:
            raise ValueError(f"Public alias target and source must be allowlisted: {target}")
    if any(aliases.get(target) != source for target, source in REQUIRED_ALIASES.items()):
        raise ValueError("Public README and workflows must use their reviewed aliases")
    return selected, aliases


def select_files(root):
    selected, aliases = public_inputs(root)
    manifest = json.loads(read_input(root, MANIFEST))
    if manifest.get("schema") != 1:
        raise ValueError("Unsupported release manifest")
    runtime, folded = set(), set()
    for group in ("main_actions", "media_explorer_actions", "support_files"):
        values = manifest.get(group)
        if not isinstance(values, list):
            raise ValueError(f"Missing runtime manifest group: {group}")
        for value in values:
            name = safe_relative(value)
            if name.casefold() in folded:
                raise ValueError(f"Duplicate runtime manifest path: {name}")
            folded.add(name.casefold())
            runtime.add(name)
    license_file = safe_relative(manifest.get("license_file", "LICENSE"))
    if license_file.casefold() in folded:
        raise ValueError("License must have its own runtime manifest entry")
    runtime.add(license_file)
    if runtime - selected:
        raise ValueError("Runtime files must be explicitly approved in the public source allowlist: "
                         + ", ".join(sorted(runtime - selected)))
    runtime_aliases = manifest.get("aliases", {})
    if not isinstance(runtime_aliases, dict):
        raise ValueError("Runtime aliases must be an object")
    for target, source in runtime_aliases.items():
        safe_relative(target)
        safe_relative(source)
        if target not in runtime or source not in selected:
            raise ValueError("Runtime aliases must use allowlisted source files")
    main = safe_relative(manifest.get("package_name", ""))
    if main not in manifest["main_actions"] or "/" in main:
        raise ValueError("Package name must identify a root Main action")
    version_match = re.search(rb"^--\s*@version\s+(\d+\.\d+\.\d+)\s*$", read_input(root, main), re.M)
    if not version_match:
        raise ValueError("Main script has no release version")
    version = version_match[1].decode("ascii")
    if f"docs/releases/{version}.md" not in selected:
        raise ValueError("Current release notes must be explicitly allowlisted")
    files = {}
    names = {}
    for name in sorted(selected):
        key = name.casefold()
        if key in names:
            raise ValueError(f"Case-insensitive source path collision: {name}")
        names[key] = name
        files[name] = read_input(root, aliases.get(name, name))
    if "README.md" not in runtime:
        raise ValueError("Runtime manifest must include README.md")
    # A clean source checkout must continue to ignore newly created local data.
    ignore = files[".gitignore"].decode("utf-8")
    for pattern in ("data/", "build/", "__pycache__/", "*.pyc", "tests/artifacts/"):
        if pattern not in ignore.splitlines():
            ignore += ("\n" if ignore and not ignore.endswith("\n") else "") + pattern + "\n"
    files[".gitignore"] = ignore.encode("utf-8")
    return version, runtime, files, aliases


def scan_privacy(files):
    findings, exceptions = [], []
    for path, data in sorted(files.items()):
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            findings.append({"path": path, "line": 0, "rule": "unexpected-binary-input"})
            continue
        for line_number, line in enumerate(text.splitlines(), 1):
            for rule, pattern in PRIVACY_RULES.items():
                for match in pattern.finditer(line):
                    finding = {"path": path, "line": line_number, "rule": rule}
                    if (path, rule, match[0]) in FIXTURE_EXCEPTIONS:
                        exceptions.append(finding)
                    else:
                        findings.append(finding)
    return {"status": "fail" if findings else "pass", "scanned_files": len(files),
            "findings": findings, "synthetic_fixture_exceptions": exceptions}


class PrivacyError(ValueError):
    def __init__(self, report):
        self.report = report
        locations = ", ".join(f'{v["path"]}:{v["line"]} ({v["rule"]})' for v in report["findings"])
        super().__init__("Privacy scan failed: " + locations)


def check_destination(output):
    reject_linked_ancestors(output, "Destination")
    if linked(output):
        raise ValueError("Destination must not be a symlink")
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise ValueError("Destination must be absent or an empty directory")


def prepare_prebuilt_helpers(root, macos_helper, windows_helper):
    spec = importlib.util.spec_from_file_location("am_prebuilt_helpers", ROOT / "tools/prebuilt_helpers.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.prepare_prebuilt_helpers(root, macos_helper, windows_helper)


def prepare_source(root, output, *, macos_helper=None, windows_helper=None):
    if (macos_helper is None) != (windows_helper is None):
        raise ValueError("--macos-helper and --windows-helper must be supplied together")
    root, output = Path(root), Path(output)
    reject_linked_ancestors(root, "Source root")
    if linked(root):
        raise ValueError("Source root must not be a symlink")
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise ValueError("Source root must be a directory")
    check_destination(output)
    output = output.absolute()
    if root.is_relative_to(output.resolve()):
        raise ValueError("Destination must not contain the source root")
    version, runtime, files, aliases = select_files(root)
    privacy = scan_privacy(files)
    if privacy["findings"]:
        raise PrivacyError(privacy)
    if macos_helper is not None:
        files.update(prepare_prebuilt_helpers(root, macos_helper, windows_helper))
    report = {
        "schema": 1, "version": version, "git_history_included": False,
        "runtime_files": sorted(runtime),
        "substitutions": [{"path": target, "source": source} for target, source in sorted(aliases.items())],
        "prebuilt_helpers_included": macos_helper is not None,
        "excluded_categories": ["Git history", "user data", "build outputs", "media", "raw validation reports",
                                "private native analysis implementations", "unreviewed source files"],
        "privacy": privacy,
        "files": [{"path": path, "sha256": digest(data), "bytes": len(data)}
                  for path, data in sorted(files.items())],
    }
    # Finish all selection, reads and privacy checks before touching output.
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".am-public-source-", dir=output.parent))
    try:
        for relative, data in files.items():
            target = staging / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            if relative.endswith(".sh"):
                target.chmod(0o755)
        (staging / OUTPUT_MANIFEST).write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        check_destination(output)
        # Windows cannot replace even an empty destination directory. Remove
        # only the validated empty directory: rmdir fails if a file arrives
        # after validation, and rename also fails if a nonempty target appears.
        # Failure cleanup below is restricted to our own staging directory.
        if output.exists():
            output.rmdir()
        os.rename(staging, output)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path, required=True, help="Absent or empty destination directory")
    parser.add_argument("--macos-helper", type=Path, help="Verified universal helper; requires --windows-helper")
    parser.add_argument("--windows-helper", type=Path, help="Verified x64 helper; requires --macos-helper")
    args = parser.parse_args()
    try:
        report = prepare_source(args.root, args.output, macos_helper=args.macos_helper,
                                windows_helper=args.windows_helper)
    except PrivacyError as error:
        print(json.dumps(error.report, indent=2, ensure_ascii=False), file=sys.stderr)
        return 1
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(json.dumps({"version": report["version"], "files": len(report["files"]),
                      "runtime_files": len(report["runtime_files"]), "privacy": report["privacy"],
                      "manifest": OUTPUT_MANIFEST}, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
