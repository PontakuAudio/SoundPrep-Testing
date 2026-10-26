#!/usr/bin/env python3
"""Create allowlisted runtime ZIPs and a ReaPack index from local release inputs.

All output files are flat GitHub Release assets. ReaPack downloads each file
individually; it does not unpack our manual-install ZIPs. No network, git writes,
installation, upload, or publication occurs here.

ReaPack's Source::targetPath puts script sources in
Scripts/<index name>/<category>/<file>, but extension sources directly in
UserPlugins/<file>. See https://github.com/cfillion/reapack/blob/master/src/source.cpp
and https://github.com/cfillion/reapack/wiki/Index-Format.
"""
from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import struct
import tempfile
from urllib.parse import quote, urlsplit
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PLATFORMS = {"macos": ("darwin64", "darwin-arm64"), "windows": ("win64",)}
NATIVE_NAMES = {"macos": "reaper_audition_macro.dylib", "windows": "reaper_audition_macro.dll"}
ZIP_LABELS = {"macos": "macos-universal", "windows": "windows-x64"}
EXCLUDED_PARTS = {"data", "build", "tests", ".git", ".codex", ".agents", "__pycache__"}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def safe_path(value):
    if (not isinstance(value, str) or not value or "\\" in value or ":" in value
            or any(ord(char) < 32 for char in value) or value.startswith("/")):
        raise ValueError(f"Unsafe package path: {value!r}")
    path = PurePosixPath(value)
    if any(part in ("", ".", "..") for part in value.split("/")):
        raise ValueError(f"Unsafe package path: {value!r}")
    if any(part.casefold() in EXCLUDED_PARTS for part in path.parts):
        raise ValueError(f"Excluded user/build/test path: {value}")
    return value


def read_input(root, relative):
    relative = safe_path(relative)
    path = root / relative
    # Reject symlinks even when they currently point inside the tree: release
    # contents must not depend on an unlisted user file or external checkout.
    if any(parent.is_symlink() for parent in (path, *path.parents) if parent != root.parent):
        raise ValueError(f"Symlinks are not release inputs: {relative}")
    if not path.is_file():
        raise ValueError(f"Required release file is missing: {relative}")
    return path.read_bytes()


def load_runtime(root, manifest_path):
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema") != 1:
        raise ValueError("Unsupported release manifest")
    aliases = manifest.get("aliases", {})
    if not isinstance(aliases, dict):
        raise ValueError("Manifest aliases must map target paths to source paths")
    for target, source in aliases.items():
        safe_path(target)
        safe_path(source)
    entries, folded = [], set()
    groups = (("main_actions", "main"), ("media_explorer_actions", "mediaexplorer"), ("support_files", None))
    for group, section in groups:
        names = manifest.get(group)
        if not isinstance(names, list):
            raise ValueError(f"Missing manifest list: {group}")
        for name in names:
            safe_path(name)
            if name.casefold() in folded:
                raise ValueError(f"Duplicate package path: {name}")
            folded.add(name.casefold())
            if section and not name.endswith(".lua"):
                raise ValueError(f"Action must be a Lua script: {name}")
            entries.append({"path": name, "main": section, "data": read_input(root, aliases.get(name, name))})
    if set(aliases) - {entry["path"] for entry in entries}:
        raise ValueError("Manifest alias target is not in the allowlist")
    license_name = manifest.get("license_file", "LICENSE")
    safe_path(license_name)
    if license_name.casefold() in folded:
        raise ValueError("License must have its own manifest entry")
    entries.append({"path": license_name, "main": None, "data": read_input(root, license_name)})
    if not entries[-1]["data"].strip():
        raise ValueError("Project LICENSE is empty")
    main = manifest.get("package_name")
    if main not in manifest["main_actions"] or "/" in main:
        raise ValueError("Package name must identify a root Main action")
    return manifest, sorted(entries, key=lambda entry: entry["path"])


def validate_version(version):
    if not re.fullmatch(r"[0-9][A-Za-z0-9.-]*", version):
        raise ValueError(f"Invalid release version: {version}")
    if any(int(number) > 65535 for number in re.findall(r"\d+", version)):
        raise ValueError("ReaPack version segments must fit unsigned 16 bits")
    return version


def source_version(runtime, main):
    source = next(entry["data"] for entry in runtime if entry["path"] == main).decode("utf-8")
    match = re.search(r"^--\s*@version\s+(\S+)\s*$", source, re.MULTILINE)
    if not match:
        raise ValueError("Main script has no @version")
    return validate_version(match.group(1))


def validate_helper(path, platform, helper_version, contract=None):
    data = path.read_bytes()
    if platform == "windows":
        if len(data) < 64 or data[:2] != b"MZ":
            raise ValueError("Windows helper is not a PE DLL")
        offset = struct.unpack_from("<I", data, 60)[0]
        if (offset + 24 > len(data) or data[offset:offset + 4] != b"PE\x00\x00"
                or struct.unpack_from("<H", data, offset + 4)[0] != 0x8664
                or not struct.unpack_from("<H", data, offset + 22)[0] & 0x2000):
            raise ValueError("Windows helper must be a Windows x64 PE DLL")
    else:
        formats = {b"\xca\xfe\xba\xbe": (">", 20), b"\xbe\xba\xfe\xca": ("<", 20),
                   b"\xca\xfe\xba\xbf": (">", 32), b"\xbf\xba\xfe\xca": ("<", 32)}
        if data[:4] not in formats or len(data) < 8:
            raise ValueError("macOS helper must be a universal arm64/x86_64 Mach-O")
        endian, stride = formats[data[:4]]
        count = struct.unpack_from(endian + "I", data, 4)[0]
        if not 2 <= count <= 16 or 8 + count * stride > len(data):
            raise ValueError("Invalid universal Mach-O architecture table")
        architectures = set()
        for index in range(count):
            start = 8 + index * stride
            architectures.add(struct.unpack_from(endian + "I", data, start)[0])
            offset, length = struct.unpack_from(endian + ("QQ" if stride == 32 else "II"), data, start + 8)
            if offset < 8 + count * stride or not length or offset + length > len(data):
                raise ValueError("Invalid universal Mach-O slice")
        if not {0x01000007, 0x0100000c}.issubset(architectures):
            raise ValueError("macOS helper is missing arm64 or x86_64")
    marker = f'"version":"{helper_version}"'.encode()
    if marker not in data:
        raise ValueError(f"{platform} helper does not contain native contract version {helper_version}")
    # A version string alone cannot distinguish a rebuilt helper from an older
    # binary with the same version (for example one still exposing Search UI).
    required = {name: feature["revision"] for name, feature in (contract or {}).get("features", {}).items()
                if feature.get("platform", platform) == platform}
    if required:
        records = []
        for raw in re.findall(rb'\{"schema":[^{}\x00]{1,256},"features":\{[^{}\x00]{0,2048}\}\}', data):
            try:
                info = json.loads(raw)
            except (ValueError, UnicodeDecodeError):
                continue
            if info.get("version") == helper_version and info.get("platform") == platform:
                records.append(info)
        if not records or any(info.get("schema") != 1 or any(
                type(info["features"].get(name)) is not int or info["features"][name] < revision
                for name, revision in required.items()) for info in records):
            raise ValueError(f"{platform} helper does not satisfy required native feature revisions")
    return data


def asset_name(relative):
    basename = re.sub(r"[^A-Za-z0-9._-]+", "-", PurePosixPath(relative).name)
    return f"am-{digest(relative.encode())[:16]}-{basename}"


def filename_component(value, label):
    if (not value or value in (".", "..") or re.search(r'[<>:"/\\|?*\x00-\x1f]', value)
            or value.endswith((".", " "))):
        raise ValueError(f"Invalid {label}: {value!r}")
    return value


def download_base(repository, base, tag):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", tag) or tag in ("main", "master", "latest"):
        raise ValueError("Tag must be a fixed, filename-safe release tag")
    if base:
        url = base.replace("{tag}", quote(tag, safe=""))
    else:
        if (not repository or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)
                or any(part in (".", "..") for part in repository.split("/"))):
            raise ValueError("Specify --repository owner/public-repository or --download-base")
        url = f"https://github.com/{repository}/releases/download/{quote(tag, safe='')}"
    parsed = urlsplit(url)
    if (parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password
            or parsed.query or parsed.fragment or tag not in parsed.path.split("/")
            or "/latest/" in parsed.path or parsed.path.endswith("/latest")):
        raise ValueError("Download base must be an HTTPS URL containing the fixed release tag")
    return url.rstrip("/")


def node_signature(element):
    return (element.tag, tuple(sorted(element.attrib.items())), (element.text or "").strip(),
            tuple(node_signature(child) for child in element))


def build_index(previous, index_name, category_name, manifest, version, sources, author, release_time, website):
    filename_component(index_name, "index name")
    # One stable folder below the index name keeps every relative runtime path
    # intact. A caller can choose its display name, not traverse directories.
    filename_component(category_name, "category")
    if previous:
        raw = previous.read_bytes()
        if b"<!DOCTYPE" in raw.upper() or b"<!ENTITY" in raw.upper():
            raise ValueError("DTD/entity declarations are not accepted in previous indexes")
        root = ET.fromstring(raw)
        if root.tag != "index" or root.get("version") != "1" or root.get("name") != index_name:
            raise ValueError("Previous index identity does not match; repository names must stay stable")
    else:
        root = ET.Element("index", {"version": "1", "name": index_name})
    categories = [node for node in root.findall("category") if node.get("name") == category_name]
    if len(categories) > 1:
        raise ValueError("Duplicate category in previous index")
    category = categories[0] if categories else ET.SubElement(root, "category", {"name": category_name})
    matches = [node for node in category.findall("reapack") if node.get("name") == manifest["package_name"]]
    if len(matches) > 1:
        raise ValueError("Duplicate package in previous index")
    package = matches[0] if matches else ET.SubElement(category, "reapack", {
        "name": manifest["package_name"], "type": "script", "desc": manifest["description"]})
    if package.get("type") != "script":
        raise ValueError("Previous package has a different type")
    attributes = {"name": version, "author": author}
    if release_time is not None:
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", release_time):
            raise ValueError("Release time must be UTC YYYY-MM-DDTHH:MM:SSZ")
        try:
            datetime.strptime(release_time, "%Y-%m-%dT%H:%M:%SZ")
        except ValueError as error:
            raise ValueError("Release time must be a valid UTC date and time") from error
        attributes["time"] = release_time
    candidate = ET.Element("version", attributes)
    for source in sources:
        attr = {key: source[key] for key in ("file", "platform", "type", "main", "hash") if source.get(key)}
        ET.SubElement(candidate, "source", attr).text = source["url"]
    existing = [node for node in package.findall("version") if node.get("name") == version]
    if existing:
        if len(existing) != 1 or node_signature(existing[0]) != node_signature(candidate):
            raise ValueError(f"Published version {version} is immutable; release a new version")
    else:
        package.append(candidate)
    if website:
        parsed = urlsplit(website)
        if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
            raise ValueError("Website must be an HTTPS URL")
        metadata = root.find("metadata")
        if metadata is None:
            metadata = ET.SubElement(root, "metadata")
        links = [node for node in metadata.findall("link") if node.get("rel") == "website"]
        if not links:
            ET.SubElement(metadata, "link", {"rel": "website"}).text = website
        elif (links[0].get("href") or links[0].text) != website:
            raise ValueError("Previous index website differs; update repository metadata deliberately")
    ET.indent(root, space="  ")
    return ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"


def write_zip(path, entries):
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(entries.items()):
            info = zipfile.ZipInfo("SoundPrep/" + name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = (0o100755 if name.endswith(".sh") else 0o100644) << 16
            archive.writestr(info, data)


def package_release(*, root, output, repository=None, base=None, version=None, tag=None,
                    macos_helper=None, windows_helper=None, platform="all", previous_index=None,
                    index_name="SoundPrep", category="Media Explorer", author="Pontaku Audio",
                    website=None, release_time=None, manifest_path=None):
    root, output = Path(root).resolve(), Path(output).absolute()
    if output.exists():
        raise ValueError("Output directory already exists; use a new staging directory")
    manifest, runtime = load_runtime(root, Path(manifest_path) if manifest_path else root / "resources/release-manifest.json")
    declared = source_version(runtime, manifest["package_name"])
    version = validate_version(version or declared)
    if version != declared:
        raise ValueError("Release version differs from the main script @version")
    tag = tag or "v" + version
    base = download_base(repository, base, tag)
    if platform not in ("all", *PLATFORMS):
        raise ValueError("Platform must be all, macos, or windows")
    selected = tuple(PLATFORMS) if platform == "all" else (platform,)
    native_contract = json.loads(read_input(root, "resources/native-contract.json"))
    helper_version = validate_version(native_contract["version"])
    helpers, inputs = {}, {"macos": macos_helper, "windows": windows_helper}
    for name in selected:
        if not inputs[name]:
            raise ValueError(f"Missing --{name}-helper for {platform} package")
        helpers[name] = validate_helper(Path(inputs[name]), name, helper_version, native_contract)
    assets, sources, files = {}, [], []
    for entry in runtime:
        asset = asset_name(entry["path"])
        if asset in assets:
            raise ValueError(f"Release asset filename collision: {asset}")
        assets[asset] = entry["data"]
        checksum = digest(entry["data"])
        files.append({"path": entry["path"], "asset": asset, "sha256": checksum, "main": entry["main"]})
        # All sources are platform-specific, including Lua. Linux must not
        # install an incomplete package without a supported native helper.
        for name in selected:
            for target in PLATFORMS[name]:
                sources.append({"file": entry["path"], "platform": target, "main": entry["main"],
                                "hash": "1220" + checksum, "url": base + "/" + quote(asset, safe="")})
    for name in selected:
        filename, data = NATIVE_NAMES[name], helpers[name]
        assets[filename] = data
        for target in PLATFORMS[name]:
            sources.append({"file": filename, "platform": target, "type": "extension",
                            "hash": "1220" + digest(data), "url": base + "/" + filename})
    index = build_index(Path(previous_index) if previous_index else None, index_name, category, manifest,
                        version, sources, author, release_time, website)
    report = {"schema": 1, "version": version, "helper_version": helper_version, "tag": tag,
              "release_time": release_time,
              "download_base": base, "platforms": list(selected), "publish_ready": platform == "all",
              "index_name": index_name, "category": category, "package": manifest["package_name"],
              "script_install_root": f"Scripts/{index_name}/{category}", "files": files,
              "native_helpers": [{"platform": name, "asset": NATIVE_NAMES[name],
                                  "sha256": digest(helpers[name]),
                                  "install_path": "UserPlugins/" + NATIVE_NAMES[name]} for name in selected]}
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".am-release-", dir=output.parent) as temporary:
        staging = Path(temporary) / "release"
        staging.mkdir()
        for filename, data in assets.items():
            (staging / filename).write_bytes(data)
        (staging / "index.xml").write_bytes(index)
        for name in selected:
            contents = {entry["path"]: entry["data"] for entry in runtime}
            contents["build/" + NATIVE_NAMES[name]] = helpers[name]
            write_zip(staging / f"soundprep-{version}-{ZIP_LABELS[name]}.zip", contents)
        (staging / "release.json").write_text(json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        sums = "".join(f"{digest(path.read_bytes())}  {path.name}\n" for path in sorted(staging.iterdir()))
        (staging / "SHA256SUMS").write_text(sums, encoding="utf-8")
        # The public output becomes visible only after all checks and files
        # succeed. Existing release directories are never overwritten.
        if output.exists():
            raise ValueError("Output directory appeared while packaging")
        staging.rename(output)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path, required=True)
    destination = parser.add_mutually_exclusive_group(required=True)
    destination.add_argument("--repository", help="Public release repository, owner/name")
    destination.add_argument("--download-base", help="HTTPS release directory containing its tag, or a {tag} placeholder")
    parser.add_argument("--version", help="Must match the main script header; defaults to that header")
    parser.add_argument("--tag", help="Immutable release tag; defaults to v<VERSION>")
    parser.add_argument("--platform", choices=("all", "macos", "windows"), default="all",
                        help="Single-platform output is a local candidate; only all is publish_ready")
    parser.add_argument("--macos-helper", type=Path)
    parser.add_argument("--windows-helper", type=Path)
    parser.add_argument("--previous-index", type=Path)
    parser.add_argument("--index-name", default="SoundPrep")
    parser.add_argument("--category", default="Media Explorer")
    parser.add_argument("--author", default="Pontaku Audio")
    parser.add_argument("--website")
    parser.add_argument("--release-time", help="Fixed UTC YYYY-MM-DDTHH:MM:SSZ for ReaPack Last Update; release workflows use the commit time")
    args = vars(parser.parse_args(argv))
    args["base"] = args.pop("download_base")
    try:
        report = package_release(**args)
    except (OSError, ValueError, KeyError, ET.ParseError) as error:
        parser.exit(1, f"Release packaging failed: {error}\n")
    print(json.dumps({key: report[key] for key in ("version", "helper_version", "platforms", "publish_ready")}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
