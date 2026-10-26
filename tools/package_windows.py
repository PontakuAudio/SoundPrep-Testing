#!/usr/bin/env python3
"""Package the Windows runtime allowlist and validated native helper as a ZIP.

This CI artifact has the same manual-install layout as a release ZIP. Native
sources, development tools/tests, the worker helper, and debug symbols are not
included. Inputs are checked before creating a temporary archive; an existing
output is replaced only after the new archive has been written successfully.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import tempfile

if __package__:
    from . import package_release as release
else:
    import package_release as release

ROOT = Path(__file__).resolve().parents[1]


def package_windows(*, root, output, helper=None):
    root, output = Path(root), Path(output).absolute()
    if root.is_symlink() or output.is_symlink():
        raise ValueError("Source root and output must not be symlinks")
    root = root.resolve()
    output = output.parent.resolve() / output.name
    if output.exists() and not output.is_file():
        raise ValueError("Output must be a ZIP file path")
    helper = Path(helper) if helper else root / "build" / release.NATIVE_NAMES["windows"]
    if helper.is_symlink():
        raise ValueError("Native helper must not be a symlink")
    helper = helper.resolve()
    manifest_path = root / "resources/release-manifest.json"
    # Use the same safe input reader for the manifest itself as for its entries.
    release.read_input(root, "resources/release-manifest.json")
    manifest, runtime = release.load_runtime(root, manifest_path)
    version = release.source_version(runtime, manifest["package_name"])
    contract = json.loads(release.read_input(root, "resources/native-contract.json"))
    helper_version = release.validate_version(contract["version"])
    native_data = release.validate_helper(helper, "windows", helper_version, contract)

    inputs = {manifest_path, helper, root / "resources/native-contract.json"}
    aliases = manifest.get("aliases", {})
    inputs.update(root / aliases.get(entry["path"], entry["path"]) for entry in runtime)
    if output in inputs:
        raise ValueError("Output must not replace a package input")
    entries = {entry["path"]: entry["data"] for entry in runtime}
    entries["build/" + release.NATIVE_NAMES["windows"]] = native_data

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".am-windows-package-", dir=output.parent) as directory:
        archive = Path(directory) / "runtime.zip"
        release.write_zip(archive, entries)
        checksum = release.digest(archive.read_bytes())
        os.replace(archive, output)
    return {"version": version, "helper_version": helper_version,
            "files": len(entries), "sha256": checksum}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="Destination ZIP file")
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--helper", type=Path, help="Defaults to build/reaper_audition_macro.dll")
    try:
        report = package_windows(**vars(parser.parse_args(argv)))
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"Windows runtime packaging failed: {error}\n")
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
