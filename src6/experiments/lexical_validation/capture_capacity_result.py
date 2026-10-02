#!/usr/bin/env python3
"""Copy the completed registered result and audit every published artifact hash."""
from __future__ import annotations
import hashlib, json, pathlib, shutil
from run_fixed import shared

HERE = pathlib.Path(__file__).resolve().parent
SOURCE = pathlib.Path('/workspace/scratch/lexical-constructions-v2-capacity-validation-20261002/capacity-validation.json')
SOURCE_SHA = '5946056f3314bf972c45bcb769a6f4786b56296394dc64d1724e9ccb067900dd'
REGISTRATION = HERE / 'evidence/ROOT-CAPACITY-REGISTRATION-20261002.json'
REGISTRATION_SHA = 'ec4aab670f573405f1725d6aab73999d45e81236011a3ecdae264845506ca0ca'

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    if sha(SOURCE) != SOURCE_SHA or sha(REGISTRATION) != REGISTRATION_SHA:
        raise ValueError('registered completed result changed')
    ledger = json.loads(SOURCE.read_text())
    files = {}
    def verify(path, digest, size=None):
        path = pathlib.Path(path)
        if sha(path) != digest or (size is not None and path.stat().st_size != size):
            raise ValueError('artifact mismatch: ' + str(path))
        files[str(path)] = {'sha256': digest, 'bytes': path.stat().st_size}
    verify(ledger['freeze'], ledger['freeze_sha256'])
    verify(ledger['checkpoint'], ledger['checkpoint_sha256'])
    verify(ledger['native_binary'], ledger['native_binary_sha256'])
    verify(ledger['stage_source'], ledger['stage_source_sha256'])
    verify(REGISTRATION, REGISTRATION_SHA)
    if [row['pair'] for row in ledger['lanes']] != ['tur-eng', 'ara-eng', 'jpn-eng']:
        raise ValueError('every predeclared source required')
    roots = pages = projections = artifact_count = 0
    for row in ledger['lanes']:
        if row['native_exit'] != 0 or len(row['native_rows']) != 10 or len(row['variants']) != 10 or len(row['controls']) != 4:
            raise ValueError('all native candidates and controls must complete')
        status = row['native_status']
        if status['state'] != 'completed' or status['timed_out'] or status['address_space_bytes'] != 4 * 1024**3 or status['timeout_seconds'] != 1800:
            raise ValueError('registered process bound/status mismatch')
        directory = pathlib.Path(row['native_argv'][-1])
        verify(directory / 'native-status.json', row['native_status_sha256'])
        verify(directory / 'native.jsonl', row['native_proof_sha256'])
        verify(directory / 'native.stderr.txt', row['native_stderr_sha256'])
        source = row['source_lpb']; verify(source['path'], source['sha256'], source['bytes'])
        roots += source['roots']; pages += source['pages']
        projections += row['gates']['direct_typed_headword_roots']
        original_observations = {native['original_native_observation'] for native in row['native_rows']}
        if len(original_observations) != 1: raise ValueError('original native observations disagree')
        typed = []
        for name, variant in row['variants'].items():
            path = pathlib.Path(variant['path']); verify(path, variant['sha256'], variant['complete_bytes'])
            groups, frame = shared.read_global(path.read_bytes())
            if len(groups) != source['pages'] or path.read_bytes()[64:96].hex() != source['sha256']:
                raise ValueError('source/group provenance mismatch')
            native = next(record for record in row['native_rows'] if record['variant'] == name)
            stats = native['stats']; outer = 128 + 24 * source['pages']
            if native['roots'] != source['roots'] or native['pages'] != source['pages']:
                raise ValueError('native source count mismatch')
            if stats['model_bytes'] + stats['dictionary_stream_bytes'] + stats['root_stream_bytes'] + stats['root_directory_bytes'] + 96 != len(frame):
                raise ValueError('all inner costs must be paid')
            if len(frame) + outer != variant['complete_bytes']: raise ValueError('all outer costs must be paid')
            if frame[5] & 1: typed.append(name)
            if row['pair'] == 'tur-eng' and variant.get('first_fixed_identical_sha256') != variant['sha256']:
                raise ValueError('all ten Turkish first-fixed frames must be identical')
            artifact_count += 1
        for variant in row['controls'].values():
            verify(variant['path'], variant['sha256'], variant['complete_bytes'])
            if variant['first_fixed_sha256'] != variant['sha256']: raise ValueError('first-fixed control changed')
            artifact_count += 1
        for profile, candidates in (('complete_size', shared.VARIANTS), ('typed_access', typed)):
            chosen = min(candidates, key=lambda name: (row['variants'][name]['complete_bytes'], shared.VARIANTS.index(name)))
            if row[profile + '_choice'] != chosen: raise ValueError('frozen selector changed')
            selector = directory / (profile + '-adaptive.lgb')
            verify(selector, row['variants'][chosen]['sha256'], row['variants'][chosen]['complete_bytes'])
            artifact_count += 1
    if (roots, pages, projections, artifact_count) != (64999, 991, 454993, 48):
        raise ValueError('complete registered source/matrix totals required')
    target = HERE / 'evidence/CAPACITY-RESULT-20261002.json'; shutil.copyfile(SOURCE, target)
    audit = {'protocol': 'LTCV2-CAPACITY-RESULT-ARTIFACT-AUDIT/1',
        'result': str(target), 'result_sha256': sha(target),
        'registration': str(REGISTRATION), 'registration_sha256': REGISTRATION_SHA,
        'source': str(pathlib.Path(__file__)), 'source_sha256': sha(pathlib.Path(__file__)),
        'published_frames': artifact_count, 'source_roots': roots, 'source_groups': pages,
        'full_native/source/root/group_observations': 10 * roots,
        'direct_typed_headword_projections': projections,
        'all_source_records_and_original_groups': True, 'all_ten_TR_first_fixed_frames_identical': True,
        'all_twelve_first_fixed_controls_identical': True, 'no_timeouts': True,
        'files': files, 'timing': False, 'peak_RSS': 'not measured; fixed4GiB virtual address-space cap is not a peak RSS measurement'}
    output = HERE / 'evidence/CAPACITY-ARTIFACT-AUDIT-20261002.json'
    output.write_text(json.dumps(audit, sort_keys=True, indent=2) + '\n')
    print(json.dumps({'result': str(target), 'result_sha256': sha(target),
                     'audit': str(output), 'audit_sha256': sha(output), 'published_frames': artifact_count}))

if __name__ == '__main__': main()
