#!/usr/bin/env python3
"""Finite independent codec replication; preserve subprocess bytes before parsing."""
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
BINARY = Path('/tmp/bzip4-install/bin/bzip4-experiment')
EXPECTED = 'a0ff2f567e9eed41f00f0365c7d2a5538f020bd020fd994e420ba0c45436cf8f'
OUT = HERE / 'evidence/runs/bzip4-round2-independent-root-helper'
CORPORA = ('freedict-eng-spa', 'gcide-054', 'omw-ja-20')


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def save(name, value):
    (OUT / name).write_text(json.dumps(value, indent=2) + '\n')


def main():
    if digest(BINARY) != EXPECTED:
        raise SystemExit('Frozen binary mismatch; no measurements started.')
    # Refuse to overwrite any prior run, even a partially completed one.
    OUT.mkdir(parents=True, exist_ok=False)
    (OUT / 'raw').mkdir()
    inputs = [HERE / 'evidence/corpora' / corpus / 'projection.tsv' for corpus in CORPORA]
    sources = sorted((ROOT / 'src6/experiments/bzip4').glob('*.zig'))
    sources += [ROOT / 'src6/compression.zig', Path(__file__).resolve()]
    sources += sorted((ROOT / 'vendor/bzip3').rglob('*.h'))
    sources += sorted((ROOT / 'vendor/bzip3').rglob('*.c'))
    paths = [BINARY, *sources, *inputs]
    before = {str(path): {'bytes': path.stat().st_size, 'sha256': digest(path)} for path in paths}
    save('manifest.json', {
        'purpose': 'Independent complete replication after original stdout capture gap; no retries or selected samples.',
        'protocol': '3 corpora x 2 block sizes x 3 samples, serial fixed order; all original measurements retained separately.',
        'cache_caveat': 'OS caches not reset; fixed within-process lane order; descriptive host-local timing.',
        'artifacts_before': before,
    })
    samples = []
    for corpus, source in zip(CORPORA, inputs):
        for block in (16384, 65536):
            for repetition in (1, 2, 3):
                label = f'{corpus}-{block}-{repetition}'
                command = [str(BINARY), '--input', str(source), '--input-format', 'projection_content',
                           '--candidate', 'bwt', '--training-bytes', '1048576',
                           '--max-eval-bytes', '8388608', '--block-bytes', str(block),
                           '--measure', '--quiet-gate', 'BZIP4-EXPERIMENT-QUIET-GATE']
                started = time.time_ns()
                try:
                    completed = subprocess.run(command, cwd=ROOT, capture_output=True, timeout=120)
                    stdout, stderr, returncode = completed.stdout, completed.stderr, completed.returncode
                    failure = None
                except subprocess.TimeoutExpired as error:
                    stdout, stderr, returncode = error.stdout or b'', error.stderr or b'', None
                    failure = 'timeout'
                # Original bytes are persisted before interpretation. Never reconstruct logs.
                stdout_path = OUT / 'raw' / f'{label}.stdout.tsv'
                stderr_path = OUT / 'raw' / f'{label}.stderr.txt'
                stdout_path.write_bytes(stdout)
                stderr_path.write_bytes(stderr)
                row = {'corpus': corpus, 'block_bytes': block, 'sample': repetition,
                       'command': command, 'started_unix_ns': started,
                       'finished_unix_ns': time.time_ns(), 'returncode': returncode,
                       'failure': failure, 'stdout': str(stdout_path), 'stderr': str(stderr_path),
                       'stdout_sha256': digest(stdout_path), 'stderr_sha256': digest(stderr_path)}
                samples.append(row)
                save('samples.json', samples)
                try:
                    pairs = [line.split('\t', 1) for line in stdout.decode('utf-8').splitlines()]
                    metrics = dict(pairs)
                    if len(metrics) != len(pairs):
                        raise ValueError('duplicate metric field')
                    row['metrics'] = metrics
                    row['ok'] = returncode == 0 and metrics.get('roundtrip') == 'ok'
                except (ValueError, UnicodeError) as error:
                    row['ok'] = False
                    row['parse_failure'] = str(error)
                save('samples.json', samples)
                print(f'{label}: exit={returncode} ok={row["ok"]}', flush=True)
    after = {str(path): {'bytes': path.stat().st_size, 'sha256': digest(path)} for path in paths}
    save('artifacts-after.json', after)
    stable = before == after
    summary = []
    for corpus in CORPORA:
        for block in (16384, 65536):
            group = [row for row in samples if row['corpus'] == corpus and row['block_bytes'] == block]
            cell = {'corpus': corpus, 'block_bytes': block, 'successful_samples': sum(row['ok'] for row in group)}
            if all(row['ok'] for row in group):
                for field in ('bzip4_total_bytes', 'bzip3_matched_total_bytes', 'train_ns',
                              'bzip4_encode_ns', 'bzip4_decode_all_ns',
                              'bzip3_retained_encode_ns', 'bzip3_retained_decode_all_ns'):
                    values = [int(row['metrics'][field]) for row in group]
                    cell[field] = {'samples': values, 'median': statistics.median(values)}
            summary.append(cell)
    save('summary.json', {'artifacts_unchanged': stable, 'cells': summary})
    if not stable or not all(row['ok'] for row in samples):
        raise SystemExit('Replication retains failures or artifact drift; inspect evidence.')
    print(OUT, flush=True)


if __name__ == '__main__':
    main()
