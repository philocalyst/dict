#!/usr/bin/env python3
"""Add only audited runtime-stage bounds to the immutable capacity freeze."""
from __future__ import annotations
import json, pathlib, shutil
from run_capacity import NATIVE_AS_BYTES, NATIVE_TIMEOUT_SECONDS, sha

HERE = pathlib.Path(__file__).resolve().parent
OLD = HERE / 'evidence/CAPACITY-FREEZE-20261002.json'
OLD_SHA = 'e4dba008ce6ed33187d99dd9af20a89ceda8debdc00230819856ba34516e8b09'
CAPTURE = pathlib.Path('/workspace/scratch/lexical-constructions-v2-capacity-capture')
TESTS = pathlib.Path('/workspace/scratch/lexical-constructions-v2-capacity-checks/bounded-stage-tests.json')

def main():
    if sha(OLD) != OLD_SHA: raise ValueError('initial capacity freeze changed')
    report = json.loads(OLD.read_text()); stage = HERE / 'run_capacity.py'
    for key in ('snapshot_sha256', 'dependency_sha256', 'evidence_sha256'):
        for path, digest in report[key].items():
            if pathlib.Path(path) == stage and key == 'dependency_sha256': continue
            if sha(pathlib.Path(path)) != digest: raise ValueError('immutable capacity evidence changed: ' + path)
    tests = json.loads(TESTS.read_text())
    if not tests['all_passed'] or len(tests['cases']) != 6 or tests['dictionary_fits'] != 0:
        raise ValueError('meaningful stage-bound tests required; no new fits')
    bounded = CAPTURE / 'stage-bounded'; bounded.mkdir(exist_ok=True)
    for source in (stage, HERE / 'test_capacity_bounds.py', pathlib.Path(__file__)):
        target = bounded / source.name
        if target.exists() and sha(target) != sha(source): raise ValueError('immutable bounded stage overwrite')
        shutil.copy2(source, target); report['snapshot_sha256'][str(target)] = sha(target)
    report['dependency_sha256'][str(stage)] = sha(stage)
    report['evidence_sha256'][str(TESTS)] = sha(TESTS)
    report['protocol'] = 'LTCV2-CAPACITY-ONLY-FREEZE/2'
    report['stage_revision'] = {'previous_freeze': str(OLD), 'previous_freeze_sha256': OLD_SHA,
        'scope': 'runner process bounds and proof-before-output only; no codec/source/model/policy/test-build/DEV-frame change',
        'stage_source': str(stage), 'stage_source_sha256': sha(stage),
        'native_process_bound': {'address_space_bytes': NATIVE_AS_BYTES,
            'timeout_seconds': NATIVE_TIMEOUT_SECONDS, 'new_process_session': True,
            'timeout_action': 'SIGKILL entire process group then reap; persist status and continue all three sources and controls'},
        'test_proof': str(TESTS), 'test_proof_sha256': sha(TESTS),
        'proof_gate': 'all immutable freeze/runtime/source hashes verified before output creation',
        'codec_binary_unchanged_sha256': report['captured_binary_sha256']}
    output = HERE / 'evidence/CAPACITY-FREEZE-BOUNDED-20261002.json'
    output.write_text(json.dumps(report, sort_keys=True, indent=2) + '\n')
    print(json.dumps({'manifest': str(output), 'sha256': sha(output),
        'stage_sha256': sha(stage), 'codec_binary_unchanged_sha256': report['captured_binary_sha256'],
        'bounds': report['stage_revision']['native_process_bound']}))

if __name__ == '__main__': main()
