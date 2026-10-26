#!/usr/bin/env python3
"""Install a local release candidate through ReaPack in a fresh macOS test host.

Uses the installed ReaPack binary but never its user configuration or registry.
Only source URLs in a disposable index are changed to local file URLs; release
hashes, platforms, install paths and action sections remain unchanged. This
tests ReaPack installation, not public HTTPS delivery. Only owned child processes
are stopped, under the same lock as run_macos_quality.py.
"""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_host(reaper, host, startup, timeout):
    with (host / (startup.stem + ".log")).open("w") as log:
        child = subprocess.Popen([str(reaper), "-newinst", "-nosplash", "-cfgfile",
                                  str(host / "reaper.ini"), str(startup)],
                                 stdout=log, stderr=log)
        try:
            code = child.wait(timeout=timeout)
        finally:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
        if code:
            raise RuntimeError(f"Owned REAPER exited with status {code}: {host}")


def bootstrap(host, codec, body, output):
    quote = lambda value: json.dumps(str(value), ensure_ascii=False)
    return f"""local r=reaper
assert(r.GetResourcePath()=={quote(host)} and r.file_exists({quote(host / '.audition-macro-test')}))
local J=dofile({quote(codec)})
local done=false
local function finish(result)
  if done then return end;done=true
  local f=assert(io.open({quote(output)},'w'));f:write(J.encode(result));f:close()
  r.OnStopButton()
  r.Main_SaveProjectEx(0,{quote(host / 'finished.rpp')},8)
  r.Main_OnCommand(40004,0)
end
local function guarded(fn)
  local ok,err=xpcall(fn,debug.traceback)
  if not ok then finish({{status='FAIL',error=tostring(err)}})end
end
r.defer(function()guarded(function()
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
{body}
end)end)
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", type=Path, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--resource", type=Path, default=Path.home() / "Library/Application Support/REAPER")
    parser.add_argument("--reaper", type=Path, default=Path("/Applications/REAPER.app/Contents/MacOS/REAPER"))
    parser.add_argument("--timeout", type=int, default=90)
    args = parser.parse_args()
    root, release, host = args.root.resolve(), args.release.resolve(), args.directory.resolve()
    if sys.platform != "darwin" or args.timeout <= 0:
        parser.error("Requires macOS and a positive timeout")
    if host.exists():
        parser.error("Use a fresh disposable directory; an existing host is never modified")
    report = json.loads((release / "release.json").read_text())
    if "macos" not in report["platforms"]:
        parser.error("Release candidate must contain the macOS helper")
    reapack = args.resource / "UserPlugins/reaper_reapack-arm64.dylib"
    if not reapack.is_file():
        parser.error("An installed Apple Silicon ReaPack binary is required")
    lock = (Path(tempfile.gettempdir()) / "audition-macro-quality-runner.lock").open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.error("Another isolated quality host is running")

    # Validate the exact staged release before changing any URL for the local
    # transport test. Do not trust a pathname from arbitrary remote metadata.
    index = ET.parse(release / "index.xml")
    sources = index.findall(".//source")
    for source in sources:
        asset = Path(unquote(urlsplit(source.text or "").path)).name
        if not asset or not (release / asset).is_file():
            raise ValueError(f"Missing local source asset: {asset}")
        if source.get("hash") != "1220" + sha256(release / asset):
            raise ValueError(f"Source checksum differs: {asset}")
        source.text = (release / asset).as_uri()
    subprocess.run([sys.executable, str(root / "tools/prepare_test_host.py"),
                    "--directory", str(host), "--resource", str(args.resource)], check=True,
                   stdout=subprocess.DEVNULL)
    # prepare_test_host copies a helper for normal audio tests. This test must
    # prove ReaPack installs it, so remove that new owned copy before launch.
    native_path = host / "UserPlugins/reaper_audition_macro.dylib"
    if native_path.exists():
        native_path.unlink()
    shutil.copy2(reapack, host / "UserPlugins" / reapack.name)
    (host / "reapack.ini").write_text(
        "[general]\nversion=4\n[install]\nautoinstall=0\npromptobsolete=0\n"
        "[remotes]\nsize=1\nremote0=ReaPack|https://reapack.com/index.xml|0|0\n")
    local_index = host / "local-index.xml"
    index.write(local_index, encoding="utf-8", xml_declaration=True)
    install_root = host / report["script_install_root"]
    main_script = install_root / report["package"]
    quote = lambda value: json.dumps(str(value), ensure_ascii=False)
    first_report, second_report = host / "install.json", host / "restart.json"
    body = f"""
  assert(r.APIExists('ReaPack_AddSetRepository'),'ReaPack API unavailable')
  assert(not r.APIExists('AM_HelperInfo'),'Helper was present before ReaPack install')
  local ok,err=r.ReaPack_AddSetRepository({quote(report['index_name'])},{quote(local_index.as_uri())},true,1)
  assert(ok,err);r.ReaPack_ProcessQueue(true)
  local deadline=r.time_precise()+{max(1, args.timeout - 10)}
  local function poll()
    guarded(function()
      local entry=r.ReaPack_GetOwner({quote(main_script)})
      if entry then
        local files={{}}
        local i=0
        while true do
          local present,path,sections,kind=r.ReaPack_EnumOwnedFiles(entry,i)
          if not present then break end
          files[#files+1]={{path=path,sections=sections,type=kind}};i=i+1
        end
        r.ReaPack_FreeEntry(entry)
        if #files>={len(report['files'])} and r.file_exists({quote(native_path)}) then
          finish({{status='PASS',files=files,reaper=r.GetAppVersion()}});return
        end
      end
      if r.time_precise()>deadline then
        finish({{status='FAIL',error='Timed out waiting for installed package ownership'}})
      else r.defer(poll)end
    end)
  end
  r.defer(poll)
"""
    startup = host / "install-bootstrap.lua"
    startup.write_text(bootstrap(host, root / "lib/am/json.lua", body, first_report))
    run_host(args.reaper, host, startup, args.timeout)
    installed = json.loads(first_report.read_text())
    if installed.get("status") != "PASS":
        raise RuntimeError(installed)

    expected = {str(install_root / row["path"]): row["sha256"] for row in report["files"]}
    native = next(row for row in report["native_helpers"] if row["platform"] == "macos")
    expected[str(host / native["install_path"])] = native["sha256"]
    # ReaPack 1.2.6's script-entry API omits extension-typed source overrides.
    # The committed registry retains them; read that test-only database after
    # shutdown to validate the full mixed-type package and its native owner.
    database = sqlite3.connect((host / "ReaPack/registry.db").as_uri() + "?mode=ro", uri=True)
    try:
        rows = database.execute(
            "SELECT f.path,f.type FROM files f JOIN entries e ON f.entry=e.id "
            "WHERE e.remote=? AND e.category=? AND e.package=? AND e.version=?",
            (report["index_name"], report["category"], report["package"], report["version"])).fetchall()
    finally:
        database.close()
    owned = {str(host / path) for path, kind in rows}
    if (native["install_path"], 2) not in rows:
        raise RuntimeError("Native helper is not registered as an extension owned by this package")
    if owned != set(expected):
        raise RuntimeError(f"Owned paths differ: missing={set(expected)-owned}, extra={owned-set(expected)}")
    for path, checksum in expected.items():
        if sha256(Path(path)) != checksum:
            raise RuntimeError(f"Installed contents differ: {path}")
    kb = [shlex.split(line) for line in (host / "reaper-kb.ini").read_text().splitlines()
          if line.startswith("SCR ")]
    actions = {}
    for row in kb:
        path = Path(row[-1])
        if not path.is_absolute():
            path = host / "Scripts" / path
        if path.is_relative_to(install_root):
            actions[str(path)] = int(row[2])
    expected_actions = {str(install_root / row["path"]): 0 if row["main"] == "main" else 32063
                        for row in report["files"] if row["main"]}
    if actions != expected_actions:
        raise RuntimeError(f"Action registrations differ: missing={expected_actions.items()-actions.items()}, "
                           f"extra={actions.items()-expected_actions.items()}")

    body = f"""
  package.path={quote(install_root / 'lib/?.lua')}..';'..package.path
  local info=require('am.native').require(r)
  assert(info.version=={quote(report['helper_version'])},'Native version differs after restart')
  finish({{status='PASS',helper=info,reaper=r.GetAppVersion()}})
"""
    startup = host / "restart-bootstrap.lua"
    startup.write_text(bootstrap(host, install_root / "lib/am/json.lua", body, second_report))
    run_host(args.reaper, host, startup, args.timeout)
    restarted = json.loads(second_report.read_text())
    if restarted.get("status") != "PASS":
        raise RuntimeError(restarted)
    result = {"status": "PASS", "transport": "local-file-url", "platform": "darwin-arm64",
              "version": report["version"], "helper_version": report["helper_version"],
              "installed_files": len(expected), "registered_actions": len(expected_actions),
              "main_actions": sum(value == 0 for value in expected_actions.values()),
              "media_explorer_actions": sum(value == 32063 for value in expected_actions.values()),
              "index_sha256": sha256(release / "index.xml"), "host": str(host)}
    (host / "reapack-smoke.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
