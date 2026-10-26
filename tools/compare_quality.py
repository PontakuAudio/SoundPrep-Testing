#!/usr/bin/env python3
"""Compare the SAME PCM fixture against two source trees (no REAPER launch).

Exact PCM comparison is mandatory. Timing is reported, never silently treated
as a reliable speedup or as a DAW/audio-device latency measurement.
"""
import argparse
import hashlib
import json
import platform
from pathlib import Path
import statistics
import subprocess
import tempfile


def command(args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--runs', type=int, default=5)
    args = parser.parse_args()
    if args.runs < 3:
        parser.error('At least three alternating runs are required')
    root = Path(__file__).resolve().parents[1]
    fixture = root / 'tests/preview_regression.cpp'
    report = {'schema_version': 1, 'scope': 'synthetic PCM; callback wall times; fixture CPU includes setup/assertions/file I/O; no real decoder/FX/device',
              'environment': {'platform': platform.platform(), 'machine': platform.machine(),
                              'compiler': command(['clang++', '--version']).splitlines()[0]},
              'fixture_sha256': sha(fixture), 'runs': {'before': [], 'after': []}}
    digests = {}
    with tempfile.TemporaryDirectory(prefix='am-quality-') as temporary:
        temp = Path(temporary)
        for name, tree in [('before', args.baseline.resolve()), ('after', root)]:
            subprocess.run(['clang++', '-std=c++17', '-O2', '-Wall', '-Wextra', '-Werror',
                            '-I', str(tree / 'native'), str(fixture), '-o', str(temp / name)], check=True)
            report[name + '_preview_sha256'] = sha(tree / 'native/preview.cpp')
            report[name + '_native_dependencies'] = {
                path.name: sha(path) for path in sorted((tree / 'native').glob('*.h'))}
        for run in range(args.runs):
            # Alternate order to reduce thermal/scheduling order bias.
            for name in (['before', 'after'] if run % 2 == 0 else ['after', 'before']):
                pcm = temp / (name + '.pcm')
                result = json.loads(command([str(temp / name), str(pcm)]))
                result['pcm_sha256'] = sha(pcm)
                if name in digests and digests[name] != result['pcm_sha256']:
                    raise RuntimeError('Nondeterministic PCM in ' + name)
                digests[name] = result['pcm_sha256']
                report['runs'][name].append(result)
    report['pcm_identical'] = digests['before'] == digests['after']
    metrics = ('mean_us', 'p95_us', 'p99_us', 'max_us', 'fixture_cpu_seconds')
    report['median'] = {name: {key: statistics.median(row[key] for row in rows)
                              for key in metrics} for name, rows in report['runs'].items()}
    report['median_change_percent'] = {key: (report['median']['after'][key] /
                                           report['median']['before'][key] - 1) * 100
                                       for key in metrics}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: report[key] for key in ('pcm_identical', 'median', 'median_change_percent')}, indent=2))
    if not report['pcm_identical']:
        raise SystemExit('FAIL: PCM changed; review before accepting this revision')


if __name__ == '__main__':
    main()
