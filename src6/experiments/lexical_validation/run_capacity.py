#!/usr/bin/env python3
"""Registered uniform capacity-only retest; never change fit/model policy."""
from __future__ import annotations
import argparse, hashlib, json, os, pathlib, resource, signal, subprocess
from run_fixed import shared, control_base, locked, CHECKPOINT, CHECKPOINT_SHA, HERE, REPO

FIRST = HERE / 'evidence/FIRST-FIXED-20261002.json'
FIRST_SHA = 'a81f59055a0261b511100328096946b8c618bfce45aba60370b3b25c8b4687da'
NATIVE_AS_BYTES = 4 * 1024 * 1024 * 1024
NATIVE_TIMEOUT_SECONDS = 1800

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def save(path, data): path.write_text(json.dumps(data, sort_keys=True, indent=2) + '\n')
def bounded_native(argv, directory, *, timeout_seconds=NATIVE_TIMEOUT_SECONDS,
                   address_space_bytes=NATIVE_AS_BYTES):
    """The registered caller always uses the fixed defaults; overrides are unit tests only."""
    status_path = directory / 'native-status.json'
    status = {'argv': argv, 'address_space_bytes': address_space_bytes,
              'timeout_seconds': timeout_seconds, 'new_process_session': True,
              'timeout_action': 'SIGKILL entire process group, then reap',
              'state': 'launching', 'timed_out': False, 'exit': None}
    save(status_path, status)
    def address_bound():
        resource.setrlimit(resource.RLIMIT_AS, (address_space_bytes, address_space_bytes))
    with (directory / 'native.jsonl').open('w') as out, (directory / 'native.stderr.txt').open('w') as err:
        try:
            process = subprocess.Popen(argv, cwd=REPO, stdout=out, stderr=err,
                                       start_new_session=True, preexec_fn=address_bound)
        except (OSError, subprocess.SubprocessError) as error:
            status.update(state='launch_failed', launch_error=repr(error))
            save(status_path, status)
            return status
        status.update(pid=process.pid, process_group=process.pid, state='running')
        save(status_path, status)
        print(json.dumps({'pid': process.pid, 'process_group': process.pid,
                          'argv': argv, 'output': str(directory),
                          'address_space_bytes': address_space_bytes,
                          'timeout_seconds': timeout_seconds}), flush=True)
        try:
            status['exit'] = process.wait(timeout=timeout_seconds)
            status['state'] = 'completed' if status['exit'] == 0 else 'native_failed'
        except subprocess.TimeoutExpired:
            status.update(timed_out=True, state='timeout', process_group_kill_requested=True)
            try:
                os.killpg(process.pid, signal.SIGKILL)
                status['process_group_kill_sent'] = True
            except ProcessLookupError:
                status['process_group_kill_sent'] = False
            status['exit'] = process.wait()
        save(status_path, status)
    return status
def native_rows(path, failed):
    rows, partial = [], None
    lines = path.read_text().splitlines()
    for index, line in enumerate(lines):
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            if not failed or index != len(lines) - 1: raise
            partial = line
    return rows, partial
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--freeze', type=pathlib.Path, required=True)
    parser.add_argument('--expected-freeze-sha256', required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    if sha(args.freeze) != args.expected_freeze_sha256: raise ValueError('registered capacity freeze changed')
    if sha(CHECKPOINT) != CHECKPOINT_SHA or sha(FIRST) != FIRST_SHA: raise ValueError('original evidence changed')
    freeze = json.loads(args.freeze.read_text()); checkpoint = json.loads(CHECKPOINT.read_text())
    first = {row['pair']: row for row in json.loads(FIRST.read_text())['lanes']}
    for key in ('snapshot_sha256', 'dependency_sha256', 'evidence_sha256'):
        for path, digest in freeze[key].items():
            if sha(pathlib.Path(path)) != digest: raise ValueError('frozen dependency changed: ' + path)
    binary = pathlib.Path(freeze['captured_binary'])
    if sha(binary) != freeze['captured_binary_sha256']: raise ValueError('capacity native binary changed')
    for lane in checkpoint['lanes']:
        for key in ('projection', 'projection_manifest', 'rows_oracle', 'raw_tei_source', 'producer_proof', 'flat_lpb'):
            locked(lane[key])
    args.output.mkdir(parents=True, exist_ok=True)
    ledger = {'protocol': 'LTCV2-CAPACITY-ONLY-WHOLE-SOURCE-VALIDATION/1',
        'phase': 'one all-source retest under separately audited uniform capacity profile; no model/policy/source changes',
        'freeze': str(args.freeze), 'freeze_sha256': args.expected_freeze_sha256,
        'original_first_fixed': str(FIRST), 'original_first_fixed_sha256': FIRST_SHA,
        'checkpoint': str(CHECKPOINT), 'checkpoint_sha256': CHECKPOINT_SHA,
        'native_binary': str(binary), 'native_binary_sha256': sha(binary),
        'stage_source': str(pathlib.Path(__file__)), 'stage_source_sha256': sha(pathlib.Path(__file__)),
        'limits': freeze['limits'], 'policy': freeze['policy'], 'lanes': [], 'timing': False,
        'native_process_bound': {'address_space_bytes': NATIVE_AS_BYTES,
            'timeout_seconds': NATIVE_TIMEOUT_SECONDS, 'new_process_session': True,
            'timeout_action': 'SIGKILL entire process group, reap, record failure and continue all sources'},
        'failure_policy': 'all original records/groups, all three sources; preserve fail-fast failures and controls; no limit lift/retry/tuning/omission',
        'interpretation': 'capacity repair alone is not a compression improvement; retained first fixed failures and Turkish loss remain visible'}
    output = args.output / 'capacity-validation.json'
    for lane in checkpoint['lanes']:
        for key in ('projection', 'projection_manifest', 'rows_oracle', 'raw_tei_source', 'producer_proof', 'flat_lpb'): locked(lane[key])
        source_path = locked(lane['flat_lpb']); directory = args.output / lane['pair']; directory.mkdir(exist_ok=True)
        argv = [str(binary), str(source_path), str(directory)]
        native_status = bounded_native(argv, directory); code = native_status['exit']
        rows, partial = native_rows(directory / 'native.jsonl', code != 0)
        if tuple(row['variant'] for row in rows) != shared.VARIANTS[:len(rows)]: raise ValueError('matrix/order changed')
        row = {'pair': lane['pair'], 'source_lpb': lane['flat_lpb'], 'projection': lane['projection'],
            'source_selection': lane['selection'], 'source_material': lane['material_oracle'],
            'native_argv': argv, 'native_exit': code, 'native_rows': rows,
            'native_status': native_status, 'native_status_sha256': sha(directory / 'native-status.json'),
            'native_partial_trailing_json': partial,
            'native_proof_sha256': sha(directory / 'native.jsonl'),
            'native_stderr': (directory / 'native.stderr.txt').read_text(),
            'native_stderr_sha256': sha(directory / 'native.stderr.txt'),
            'candidate_count_declared': 10, 'candidate_count_completed': len(rows),
            'status': 'all ten native gates complete' if code == 0 else 'whole-source capacity profile failed; no size claim',
            'controls': {}, 'variants': {}, 'original_first_fixed_status': first[lane['pair']]['status']}
        ledger['lanes'].append(row); save(output, ledger)
        source, rawframes, groups = shared.page.old_bundle(source_path)
        base = control_base(source, rawframes, groups); whole = shared.whole_flat(rawframes, groups)
        for backend in ('bzip3', 'zstd19'):
            codec = shared.page.Codec(backend); matched = shared.page.control(source, groups, rawframes, codec)
            if backend == 'bzip3':
                codec.session = shared.page.flat_controls.Bzip3Session(32 * 1024 * 1024,
                    bindings=shared.page.flat_controls._Bzip3Bindings(pathlib.Path('/workspace/scratch/libbzip3.so')))
            global_control = shared.whole_control(base, whole, codec)
            for scope, data, suffix in (('matched_pages', matched, '.lpb'), ('whole_flat', global_control, '.lgc')):
                key = scope + '/' + backend; historical = first[lane['pair']]['controls'][key]
                if hashlib.sha256(data).hexdigest() != historical['sha256'] or len(data) != historical['complete_bytes']:
                    raise ValueError('unchanged control bytes required: ' + lane['pair'] + '/' + key)
                path = directory / ('flat.' + scope + '.' + backend + suffix); path.write_bytes(data)
                row['controls'][key] = {'path': str(path), 'complete_bytes': len(data), 'sha256': sha(path),
                    'first_fixed_sha256': historical['sha256'],
                    'gate': 'actual complete backend frame reopened/decoded exact; byte-identical to first fixed control'}
        if code == 0:
            if len(rows) != 10 or any(r['roots'] != lane['flat_lpb']['roots'] or r['pages'] != lane['flat_lpb']['pages'] for r in rows):
                raise ValueError('all records/groups required')
            typed = []
            for variant in shared.VARIANTS:
                path = directory / (variant + '.lgb'); data = path.read_bytes(); records, frame = shared.read_global(data)
                if data[64:96].hex() != lane['flat_lpb']['sha256'] or len(records) != len(groups): raise ValueError('source provenance mismatch')
                if frame[5] & 1: typed.append(variant)
                variant_row = {'path': str(path), 'complete_bytes': len(data), 'sha256': sha(path),
                    'direct_typed_headword': bool(frame[5] & 1),
                    'delta_percent': {k: 100 * (len(data) / v['complete_bytes'] - 1) for k, v in row['controls'].items()}}
                if variant in first[lane['pair']]['variants']:
                    historical = first[lane['pair']]['variants'][variant]
                    if historical['sha256'] != variant_row['sha256']: raise ValueError('previous heldout accepted frame changed')
                    variant_row['first_fixed_identical_sha256'] = historical['sha256']
                row['variants'][variant] = variant_row
            for profile, candidates in (('complete_size', shared.VARIANTS), ('typed_access', typed)):
                choice = min(candidates, key=lambda v: (row['variants'][v]['complete_bytes'], shared.VARIANTS.index(v)))
                row[profile + '_choice'] = choice
                (directory / (profile + '-adaptive.lgb')).write_bytes((directory / (choice + '.lgb')).read_bytes())
            row['gates'] = {'full_native/source/root/group_roots': 10 * lane['flat_lpb']['roots'],
                'direct_typed_headword_roots': len(typed) * lane['flat_lpb']['roots'], 'all_source_records': True}
            row['resident_preparation'] = {r['variant']: {'decoded_stock_bytes': r['stats']['decoded_dictionary_bytes'],
                'owned_lexeme_index_bytes': r['decoded_lexeme_index_bytes'], 'owned_model_heap_bytes': r['prepared_model_owned_heap_bytes'],
                'page_value_bytes': r['prepared_page_value_bytes'], 'borrowed_bundle_bytes': r['complete_bundle_bytes'],
                'scope': 'retained payload/components; full pool and native/source admission paid before projection; allocator/transient/stack overhead excluded; not peak RSS'} for r in rows}
        else:
            row['first_failed_variant'] = shared.VARIANTS[len(rows)] if len(rows) < 10 else 'unknown'
            row['not_completed_due_fail_fast'] = list(shared.VARIANTS[len(rows) + 1:])
            row['gates'] = {'complete_frozen_baseline_source_records': lane['flat_lpb']['roots'], 'candidate_family_completed': False}
        save(output, ledger)
        print(lane['pair'], row['status'], 'native_exit', code, 'completed', len(rows), 'controls', len(row['controls']), flush=True)
    print(json.dumps({'ledger': str(output), 'sha256': sha(output), 'timing': False}), flush=True)

if __name__ == '__main__': main()
