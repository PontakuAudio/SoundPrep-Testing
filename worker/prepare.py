#!/usr/bin/env python3
"""Supervise one persistent isolated REAPER. Never controls the user's REAPER."""
from pathlib import Path
import configparser
import json
import os
import shutil
import signal
import subprocess
import sys
import time


def atomic_json(path, value):
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')
    temp.replace(path)


def resource_directory(source, target):
    marker = target / '.audition-macro-worker'
    if target.exists() and not marker.is_file():
        raise ValueError('Refusing an unowned worker resource directory')
    if target.resolve() == source.resolve():
        raise ValueError('Worker must not use the main resource directory')
    target.mkdir(parents=True, exist_ok=True)
    marker.write_text('Disposable Audition Macro rendering process\n', encoding='utf-8')
    (target / '.audition-macro-worker-ready').unlink(missing_ok=True)
    prefs = configparser.ConfigParser(interpolation=None, strict=False)
    prefs.read(source / 'reaper.ini', encoding='utf-8')
    # No startup actions, last projects, recording defaults or user templates.
    config = {'loadlastproj': '0', 'lastproject': '', 'newprojdo': '0', 'verchk': '0'}
    for key, value in prefs.items('REAPER') if prefs.has_section('REAPER') else []:
        if key.startswith(('vstpath', 'clappath', 'lv2path')) or key in ('defpitchcfg', 'defstretchmode'):
            config[key] = value
    (target / 'reaper.ini').write_text('[REAPER]\n' + ''.join(f'{k}={v}\n' for k, v in config.items()), encoding='utf-8')
    for pattern in ('reaper-license.rk', 'reaper-*plugins*.ini', 'reaper-jsfx.ini'):
        for file in source.glob(pattern):
            shutil.copy2(file, target / file.name)
    for folder in ('Effects', 'Data'):
        dest = target / folder
        if not dest.exists() and (source / folder).is_dir():
            if os.name == 'nt':
                # NTFS directory junctions do not require administrator or
                # Developer Mode privileges; avoid copying whole sample trees.
                import _winapi
                _winapi.CreateJunction(str((source / folder).resolve()), str(dest))
            else:
                dest.symlink_to(source / folder, target_is_directory=True)
    plugins = target / 'UserPlugins'
    plugins.mkdir(exist_ok=True)
    extension = 'dll' if os.name == 'nt' else 'dylib'
    for pattern in (f'reaper_sws*.{extension}', f'reaper_js_ReaScriptAPI*.{extension}'):
        for file in (source / 'UserPlugins').glob(pattern):
            dest = plugins / file.name
            if not dest.exists():
                if os.name == 'nt':
                    shutil.copy2(file, dest)
                else:
                    dest.symlink_to(file.resolve())


def stop_owned(child):
    if child is None:
        return
    if child.poll() is None:
        try:
            if os.name == 'nt':
                child.terminate()
            else:
                os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            # The owned child can exit between poll() and signalling it. Still
            # reap it, then let run() finish cleaning the owned staging files.
            pass
        try:
            child.wait(timeout=6)
        except subprocess.TimeoutExpired:
            try:
                if os.name == 'nt':
                    child.kill()
                else:
                    os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait(timeout=3)


def run(config):
    """One process for the entire session; never respawn while auditioning."""
    child = None
    directory = Path(config['directory'])
    host = directory / 'host'
    started = time.monotonic()
    try:
        resource_directory(Path(config['resource']), host)
        suffix = '.dll' if os.name == 'nt' else '.dylib'
        shutil.copy2(config['worker_plugin'], host / ('UserPlugins/reaper_audition_macro_worker' + suffix))
        (host / '.audition-macro-worker-command').write_text(config['bootstrap'] + '\n', encoding='utf-8')
        argv = [config['executable'], '-newinst', '-noactivate', '-nosplash',
                '-cfgfile', str(host / 'reaper.ini'), '-new']
        startup = None
        if os.name == 'nt':
            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = subprocess.SW_HIDE
        with open(directory / 'host.log', 'wb') as log:
            child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                     startupinfo=startup,
                                     start_new_session=os.name != 'nt',
                                     creationflags=subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.BELOW_NORMAL_PRIORITY_CLASS if os.name == 'nt' else 0)
            try:
                os.setpriority(os.PRIO_PROCESS, child.pid, 10)
            except (OSError, AttributeError):
                pass
            ready = False
            while True:
                if (directory / 'stop').exists():
                    return {'status': 'stopped'}
                if config.get('single_job'):
                    result = directory / 'result.json'
                    if result.is_file():
                        return json.loads(result.read_text(encoding='utf-8'))
                    if time.monotonic() - started > config['timeout']:
                        raise TimeoutError('Drop render timed out')
                else:
                    heartbeat = directory / 'heartbeat'
                    if not heartbeat.exists() or time.time() - heartbeat.stat().st_mtime > 120:
                        return {'status': 'stopped', 'reason': 'parent heartbeat expired'}
                if child.poll() is not None:
                    raise RuntimeError(f'Render process exited ({child.returncode})')
                if not ready and (directory / 'worker-ready').exists():
                    ready = True
                    atomic_json(directory / 'ready.json', {'pid': child.pid, 'status': 'ready'})
                if not ready and time.monotonic() - started > 45:
                    raise TimeoutError('Render host startup timed out')
                running = directory / 'running.json'
                if running.exists() and time.time() - running.stat().st_mtime > config['timeout']:
                    raise TimeoutError('Background render timed out; restarting requires a new session')
                time.sleep(.1)
    finally:
        stop_owned(child)
        if config.get('single_job') and (host / '.audition-macro-worker').is_file() and host.resolve() != Path(config['resource']).resolve():
            # Cold jobs keep only their small logs/results and media awaiting
            # the parent's copy. Do not accumulate DLL/license copies per drop.
            shutil.rmtree(host)
        # Projects receive permanent copies; these numbered directories are
        # exclusively owned staging jobs. Keep logs/config for diagnostics.
        for entry in directory.iterdir():
            if entry.name.isdecimal() and entry.is_dir() and not entry.is_symlink():
                shutil.rmtree(entry)


def main():
    config = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
    try:
        result = run(config)
    except Exception as error:
        result = {'status': 'error', 'error': str(error)}
    atomic_json(Path(config['directory']) / 'exit.json', result)


if __name__ == '__main__':
    main()
