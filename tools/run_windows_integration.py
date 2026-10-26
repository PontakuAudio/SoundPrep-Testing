"""Run the Windows review in a fresh, owned REAPER with synthetic media only."""
import argparse
import configparser
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import time
import wave


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resource', type=Path, default=Path(os.environ.get('APPDATA', '')) / 'REAPER')
    parser.add_argument('--executable', type=Path, default=Path('C:/Program Files/REAPER (x64)/reaper.exe'))
    parser.add_argument('--inspect-seconds', type=int, default=0, help='Keep the tested search UI open briefly for visual inspection (0-60)')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--drag-test', action='store_true', help='Wait for real list/waveform drags in the disposable host (10 minutes)')
    mode.add_argument('--direct-test', action='store_true', help='Measure in-process item rendering without a visible test window')
    mode.add_argument('--editor-test', action='store_true', help='Exercise native editor panels through drag waits and close/reopen')
    mode.add_argument('--seek-test', action='store_true', help='Exercise real waveform clicks after preview EOF, Stop and Pause')
    mode.add_argument('--preset-test', action='store_true', help='Verify unified preset saving, drafts, settings and direct buttons')
    mode.add_argument('--playback-test', action='store_true', help='Verify range repeat and item rendering during timeline playback')
    args = parser.parse_args()
    if os.name != 'nt':
        parser.error('This integration runner requires Windows')
    if not 0 <= args.inspect_seconds <= 60:
        parser.error('--inspect-seconds must be between 0 and 60')
    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location('prepare', root / 'worker/prepare.py')
    worker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(worker)
    directory = Path(tempfile.mkdtemp(prefix='windows-review-', dir=root / 'build'))
    host = directory / 'host'
    print(f'Test host: {host}', flush=True)
    worker.resource_directory(args.resource.resolve(), host)
    # The review uses bundled JSFX only. Never scan third-party plug-ins (or
    # trigger their activation dialogs) in this synthetic interactive host.
    empty_plugins = host / 'empty-plugins'
    empty_plugins.mkdir()
    prefs = configparser.ConfigParser(interpolation=None, strict=False)
    prefs.read(host / 'reaper.ini', encoding='utf-8')
    for key in ('vstpath', 'vstpath64', 'clappath', 'clappath64', 'lv2path'):
        prefs['REAPER'][key] = str(empty_plugins)
    prefs['audioconfig'] = {'mode': '4', 'dummy_srate': '48000', 'dummy_blocksize': '512'}
    prefs['REAPER']['offlineinact'] = '0'  # Hidden test host still needs its dummy clock.
    with (host / 'reaper.ini').open('w', encoding='utf-8') as file:
        prefs.write(file, space_around_delimiters=False)
    (host / '.audition-macro-test').write_text('Disposable Windows integration host\n', encoding='utf-8')
    if args.direct_test:
        (host / '.audition-macro-test-observe-windows').write_text('Observe only this test host\n', encoding='utf-8')
    (host / '.audition-macro-test-inspect').write_text(str(args.inspect_seconds), encoding='utf-8')
    for name in ('reaper_audition_macro.dll', 'reaper_am_test_host.dll'):
        shutil.copy2(root / 'build/windows/Release' / name, host / 'UserPlugins' / name)
    media = host / 'media 素材'
    media.mkdir()
    with wave.open(str(media / "test one's 音.wav"), 'wb') as wav:
        wav.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
        wav.writeframes(b''.join(struct.pack('<h', int(4096 * math.sin(2 * math.pi * 440 * i / 48000))) for i in range(96000)))
    script = root / ('tests/reaper_playback.lua' if args.playback_test else 'tests/reaper_presets.lua' if args.preset_test else 'tests/reaper_windows_seek.lua' if args.seek_test else 'tests/reaper_editor_lifecycle.lua' if args.editor_test else 'tests/reaper_windows_direct.lua' if args.direct_test else 'tests/reaper_windows_drag.lua' if args.drag_test else 'tests/reaper_windows_review.lua')
    (host / '.audition-macro-test-command').write_text(script.as_posix() + '\n', encoding='utf-8')
    result = host / 'windows-review.json'
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = subprocess.SW_HIDE
    child = None
    try:
        child = subprocess.Popen([str(args.executable), '-newinst', '-noactivate', '-nosplash',
                                  '-cfgfile', str(host / 'reaper.ini'), '-new'], startupinfo=startup)
        deadline = time.monotonic() + (660 if args.drag_test else 180)
        previous = None
        while not result.exists():
            if child.poll() is not None:
                raise RuntimeError(f'Test REAPER exited: {child.returncode}; logs: {host}')
            if time.monotonic() > deadline:
                raise TimeoutError(f'Test REAPER did not complete; logs: {host}')
            progress = host / 'windows-review-progress.json'
            if progress.exists():
                current = json.loads(progress.read_text(encoding='utf-8'))
                if current != previous:
                    print(json.dumps(current, ensure_ascii=True), flush=True)
                    previous = current
            time.sleep(.2)
        report = json.loads(result.read_text(encoding='utf-8'))
        if args.direct_test and report['status'] == 'PASS':
            comparisons = []
            for index in range(1, 4):
                with wave.open(str(host / f'direct-media/direct{index}.wav'), 'rb') as direct, wave.open(str(host / f'direct-media/reference{index}.wav'), 'rb') as reference:
                    assert direct.getparams() == reference.getparams(), 'Direct/reference audio format or duration differs'
                    actual = direct.readframes(direct.getnframes())
                    expected = reference.readframes(reference.getnframes())
                    assert any(actual), 'Both comparison renders must not be silent'
                    assert actual == expected, 'Direct rendering changed audio samples'
                    comparisons.append({'case': index, 'frames': direct.getnframes(), 'sample_rate': direct.getframerate(), 'identical_pcm': True})
            report['audio_comparisons'] = comparisons
            result.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
        print(json.dumps(report, ensure_ascii=True, indent=2))
        print(f'Results retained: {result}')
        return 0 if report['status'] == 'PASS' else 1
    finally:
        worker.stop_owned(child)


if __name__ == '__main__':
    raise SystemExit(main())
