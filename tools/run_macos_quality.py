#!/usr/bin/env python3
"""Run existing real-REAPER acceptance tests in a new disposable resource path.

Never loads user projects or replaces installed helpers. A timed-out owned
process is terminated and reported as failure, not as a successful test.
"""
import argparse
import fcntl
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import wave


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--suite', choices=('direct', 'take_fx', 'project_lifecycle', 'render_benchmark', 'preview_channels', 'multichannel_drop', 'multichannel_normalize', 'live_normalization', 'native_analysis', 'startup', 'item_volume', 'drop_analysis', 'editor_lifecycle'), required=True)
    parser.add_argument('--reaper', type=Path, default=Path('/Applications/REAPER.app/Contents/MacOS/REAPER'))
    parser.add_argument('--timeout', type=int, default=120)
    parser.add_argument('--corpus-manifest', type=Path, help='Optional local effect expectations for native_analysis')
    args = parser.parse_args()
    root, host = args.root.resolve(), args.directory.resolve()
    if sys.platform != 'darwin':
        parser.error('This launcher is for macOS; use the Windows integration runner on Windows')
    if host.exists():
        parser.error('Use a fresh directory; existing hosts or loaded helpers are never replaced')
    if args.timeout <= 0:
        parser.error('Timeout must be positive')
    if args.corpus_manifest and args.suite != 'native_analysis':
        parser.error('--corpus-manifest requires --suite native_analysis')
    # prepare_test_host.py has shared disposable media paths. Keep this lock
    # alive through host shutdown, including when the caller interrupts us.
    lock = (Path(tempfile.gettempdir()) / 'audition-macro-quality-runner.lock').open('a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.error('Another quality host is running; execute real-host suites serially')
    subprocess.run([sys.executable, str(root / 'tools/prepare_test_host.py'),
                    '--directory', str(host)], check=True)
    if args.corpus_manifest:
        shutil.copyfile(args.corpus_manifest, host / 'loudness-corpus.json')
    (host / 'media-fixtures').mkdir()
    source = Path('/tmp/audition-macro-dev/test.wav')
    shutil.copy2(source, host / 'media-fixtures/test.wav')
    with wave.open(str(host / 'silence.wav'), 'wb') as output:
        output.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
        output.writeframes(bytes(96000))
    directory = host / 'media 素材'
    directory.mkdir()
    with wave.open(str(source), 'rb') as input_file:
        data, params = input_file.readframes(input_file.getnframes()), input_file.getparams()
    with wave.open(str(directory / "test one's 音.wav"), 'wb') as output:
        output.setparams(params)
        output.writeframes(data * 2)
    report_name = {'direct': 'direct-review', 'take_fx': 'take-fx',
                   'project_lifecycle': 'project-lifecycle', 'render_benchmark': 'render-benchmark',
                   'preview_channels': 'preview-channels', 'multichannel_drop': 'multichannel-drop',
                   'multichannel_normalize': 'multichannel-normalize',
                   'live_normalization': 'live-normalization',
                   'native_analysis': 'native-analysis', 'startup': 'startup', 'item_volume': 'item-volume', 'drop_analysis': 'drop-analysis', 'editor_lifecycle': 'windows-review'}[args.suite]
    report_path = host / (report_name + '.json')
    quote = lambda value: json.dumps(str(value), ensure_ascii=False)
    bootstrap = host / 'quality-bootstrap.lua'
    bootstrap.write_text(f'''local r=reaper
assert(r.GetResourcePath()=={quote(host)} and r.file_exists({quote(host / '.audition-macro-test')}))
local function quit()
  r.OnStopButton()
  r.Main_SaveProjectEx(0,{quote(host / 'finished.rpp')},8)
  r.Main_OnCommand(40004,0)
end
local function watch()
  local file=io.open({quote(report_path)},'r')
  if file then file:close();quit()else r.defer(watch)end
end
r.defer(function()
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  -- Pin the offline render format instead of inheriting the device's last rate.
  r.GetSetProjectInfo(0,'PROJECT_SRATE',48000,true)
  r.GetSetProjectInfo(0,'PROJECT_SRATE_USE',1,true)
  local ok,err=xpcall(function()dofile({quote(root / ('tests/reaper_' + args.suite + '.lua'))})end,debug.traceback)
  if not ok then
    local f=assert(io.open({quote(host / 'bootstrap-error.txt')},'w'));f:write(err);f:close();quit()
  elseif {quote(args.suite)}~='project_lifecycle' then r.defer(watch)end
end)
''')
    with (host / 'launch.log').open('w') as log:
        # The lifecycle suite owns startup and shutdown itself. Run it directly
        # so the launcher cannot change the initial project's dirty/audio state.
        startup = root / 'tests/reaper_project_lifecycle.lua' if args.suite == 'project_lifecycle' else bootstrap
        child = subprocess.Popen([str(args.reaper), '-newinst', '-nosplash', '-cfgfile',
                                  str(host / 'reaper.ini'), str(startup)], stdout=log, stderr=log)
        try:
            code = child.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            raise SystemExit(f'FAIL: timed out; owned process stopped. Logs: {host}')
        finally:
            # Also reap on Ctrl-C or another wait error. Never signal an
            # unrelated REAPER process or use process-name based termination.
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
    if code != 0 or not report_path.exists():
        raise SystemExit(f'FAIL: REAPER exit {code}; missing/invalid result. Logs: {host}')
    report = json.loads(report_path.read_text())
    print(json.dumps(report, indent=2, ensure_ascii=False))
    if report.get('status') != 'PASS':
        raise SystemExit('FAIL: acceptance suite did not pass')


if __name__ == '__main__':
    main()
