#!/usr/bin/env python3
"""Compare all seven WAV fixtures from two real REAPER direct acceptance runs.

Require identical PCM format, length and every sample; ignore WAV metadata.
Missing fixtures and mismatches fail. No automatic tolerance or resampling.
"""
import argparse
import hashlib
import json
from pathlib import Path
import wave

FIXTURES = ('direct1.wav', 'direct2.wav', 'direct3.wav', 'raw.wav',
            'reference1.wav', 'reference2.wav', 'reference3.wav')


def compare(before, after):
    rows = []
    for name in FIXTURES:
        with wave.open(str(before / name)) as a, wave.open(str(after / name)) as b:
            params = a.getparams()
            left, right = a.readframes(a.getnframes()), b.readframes(b.getnframes())
            # A truncated data chunk must not pass by matching another truncation.
            if len(left) != params.nframes * params.nchannels * params.sampwidth:
                raise ValueError('Truncated baseline: ' + name)
            if len(right) != b.getnframes() * b.getnchannels() * b.getsampwidth():
                raise ValueError('Truncated candidate: ' + name)
            rows.append({'file': name, 'format_equal': params == b.getparams(),
                         'sample_rate': params.framerate, 'channels': params.nchannels,
                         'sample_width_bytes': params.sampwidth, 'frames': params.nframes,
                         'pcm_identical': left == right,
                         'before_sha256': hashlib.sha256(left).hexdigest(),
                         'after_sha256': hashlib.sha256(right).hexdigest()})
    return {'scope': 'real REAPER offline-render PCM; excludes WAV metadata',
            'status': 'PASS' if all(row['format_equal'] and row['pcm_identical'] for row in rows) else 'FAIL',
            'files': rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('before', type=Path)
    parser.add_argument('after', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    result = compare(args.before, args.after)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(result['status'] + ': seven real-render PCM fixtures')
    if result['status'] != 'PASS':
        raise SystemExit(1)


if __name__ == '__main__':
    main()
