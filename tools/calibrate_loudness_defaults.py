#!/usr/bin/env python3
"""Measure local mono/stereo effects with the production LUFS/Zwicker kernels.

Input JSON: [{"path": "/absolute/audio.wav", "id": "door-1", "family": "door"}].
Uses FFmpeg for development-only decoding to 48 kHz; the application uses
REAPER. No audio/path names are copied into the report, and sources are read
only. Run again with --targets to evaluate candidate sones against -18 LUFS-M
Max, +18 dB max boost, -1 dBTP ceiling and the existing -20 dBFS = 79 dB SPL
model calibration. Include the same complete-source + 400 ms tail as Preview.
"""
import argparse
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import re
import statistics
import subprocess
import tempfile


def summarize(results, targets):
    groups = defaultdict(list)
    for result in results:
        groups[result['family']].append(result)
    summary = []
    for target in targets:
        row = dict(target_sones=target)
        for mode in ('max', 'p95'):
            families = {family: [next(t for t in r['targets'] if t['target_sones'] == target)[mode]
                                for r in records] for family, records in groups.items()}
            flat = [r for records in families.values() for r in records]
            row[mode] = dict(
                family_mae_db=statistics.mean(statistics.mean(abs(r['delta_reference_db']) for r in rs) for rs in families.values()),
                family_bias_db=statistics.mean(statistics.mean(r['delta_reference_db'] for r in rs) for rs in families.values()),
                median_lufs_m_max=statistics.median(r['lufs_m_max'] for r in flat),
                min_lufs_m_max=min(r['lufs_m_max'] for r in flat), max_lufs_m_max=max(r['lufs_m_max'] for r in flat),
                peak_capped_count=sum(r['capped'] for r in flat),
                families={family: dict(mae_db=statistics.mean(abs(r['delta_reference_db']) for r in rs),
                                       bias_db=statistics.mean(r['delta_reference_db'] for r in rs))
                          for family, rs in families.items()})
        row['combined_family_mae_db'] = statistics.mean(row[m]['family_mae_db'] for m in ('max', 'p95'))
        summary.append(row)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--targets', type=float, nargs='*', default=[])
    parser.add_argument('--workers', type=int, default=2)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    args.output.mkdir(parents=True, exist_ok=True)
    executable = args.output.resolve() / 'calibrate_loudness'
    sources = [root / p for p in ('tools/calibrate_loudness_defaults.cpp', 'native/zwicker.cpp', 'native/lufs_meter.cpp')]
    subprocess.run(['clang++', '-std=c++17', '-O2', '-ffp-contract=off', *map(str, sources), '-o', str(executable)], check=True)
    manifest = json.loads(args.manifest.read_text())
    assert 1 <= args.workers <= 4 and manifest
    assert len({row['id'] for row in manifest}) == len(manifest)
    assert all(re.fullmatch(r'[A-Za-z0-9_-]+', row['id']) and row['family'] for row in manifest)

    def measure(row):
        path = Path(row['path']).resolve()
        metadata = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'a:0',
            '-show_entries', 'stream=channels,sample_rate', '-of', 'json', str(path)]))['streams'][0]
        channels = metadata['channels']
        assert channels in (1, 2), 'Select mono/stereo files explicitly; do not guess a multichannel downmix'
        with tempfile.TemporaryDirectory(dir=args.output) as directory:
            pcm = Path(directory) / 'audio.f64'
            subprocess.run(['ffmpeg', '-v', 'error', '-nostdin', '-i', str(path), '-map', '0:a:0',
                '-ar', '48000', '-c:a', 'pcm_f64le', '-f', 'f64le', str(pcm)], check=True)
            result = json.loads(subprocess.check_output([str(executable), str(pcm), str(channels), *map(str, args.targets)]))
        with path.open('rb') as source:
            digest = hashlib.file_digest(source, 'sha256').hexdigest()
        result.update(id=row['id'], family=row['family'], source_sha256=digest,
                      source_sample_rate=int(metadata['sample_rate']))
        print(json.dumps({k: result[k] for k in ('id', 'family', 'reference_max_sones', 'reference_p95_sones', 'reference_peak_capped')}), flush=True)
        (args.output / (row['id'] + '.json')).write_text(json.dumps(result, indent=2) + '\n')
        return result

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        results = list(pool.map(measure, manifest))
    report = dict(reference_lufs_m_max=-18, ceiling_dbtp=-1, max_boost_db=18,
                  reference_dbfs=-20, reference_spl_db=79, response_tail_seconds=.4,
                  targets=args.targets, cases=results, summary=summarize(results, args.targets),
                  engine_sha256={str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources})
    (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'Completed {len(results)} effects in {len({r["family"] for r in results})} families', flush=True)


if __name__ == '__main__':
    main()
