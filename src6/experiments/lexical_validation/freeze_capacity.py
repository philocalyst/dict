#!/usr/bin/env python3
"""Freeze the capacity-only build after all tests and strict retained DEV identities."""
from __future__ import annotations
import hashlib, json, pathlib, shutil, sys, zstandard
from capacity_checks import CHECKS, INSTALL, CORE, ORDER, guarded, sha, write
from prepare_capacity import HERE, ROOT, TARGET, FREEZE, FREEZE_SHA

CAPTURE = pathlib.Path('/workspace/scratch/lexical-constructions-v2-capacity-capture')

def main():
    original = guarded()
    tested = json.loads((CHECKS / 'tests.json').read_text())
    replay = json.loads((CHECKS / 'replay.json').read_text())
    install = json.loads((CHECKS / 'install.json').read_text())
    if [row['mode'] for row in tested] != ['Debug', 'ReleaseSafe', 'ReleaseFast'] or any(row['exit'] for row in tested):
        raise ValueError('three green test modes required')
    if [row['case'] for row in replay] != ['rich128', 'omw-ja-dev512'] or any(len(row['frame_identities']) != 12 for row in replay):
        raise ValueError('twenty candidate identities and four selector identities required')
    binary = pathlib.Path(install['binary'])
    if install['exit'] or sha(binary) != install['binary_sha256']:
        raise ValueError('installed tested binary changed')
    for row in tested:
        if sha(pathlib.Path(row['log'])) != row['log_sha256']: raise ValueError('test proof changed')
    for row in replay:
        if sha(pathlib.Path(row['native_proof'])) != row['native_proof_sha256']: raise ValueError('native proof changed')
        if sha(pathlib.Path(row['source'])) != row['source_sha256']: raise ValueError('DEV source changed')
        for identity in row['frame_identities'].values():
            if sha(pathlib.Path(identity['path'])) != identity['sha256']: raise ValueError('replay frame changed')
            if 'historical_path' in identity and pathlib.Path(identity['path']).read_bytes() != pathlib.Path(identity['historical_path']).read_bytes():
                raise ValueError('historical frame identity changed')
    CAPTURE.mkdir(exist_ok=True); (CAPTURE / 'source').mkdir(exist_ok=True); (CAPTURE / 'stage').mkdir(exist_ok=True)
    inputs = [(path, CAPTURE / 'source' / path.name) for path in sorted(TARGET.glob('*.zig'))]
    inputs += [(binary, CAPTURE / binary.name)]
    for path in (HERE / 'prepare_capacity.py', HERE / 'capacity_checks.py', pathlib.Path(__file__),
                 HERE / 'run_capacity.py',
                 HERE / 'CAPACITY-PROPOSAL-20261002.md', HERE / 'evidence/CAPACITY-SOURCE-20261002.json',
                 HERE / 'evidence/CAPACITY-RESOURCE-ONLY-20261002.patch'):
        inputs.append((path, CAPTURE / 'stage' / path.name))
    for path, target in inputs:
        if target.exists() and sha(target) != sha(path): raise ValueError('immutable capture overwrite')
        shutil.copy2(path, target)
    dependencies = dict(original['additional_runtime_dependency_sha256'])
    for name in ('rich128', 'omw-ja-dev512'):
        dependencies.update(original['cases'][name]['screen']['provenance']['sources_sha256'])
    for path in (pathlib.Path(sys.executable).resolve(), pathlib.Path(zstandard.backend_c.__file__),
                 HERE / 'run_fixed.py', HERE / 'run_capacity.py'):
        dependencies[str(path)] = sha(path)
    evidence = {str(CHECKS / name): sha(CHECKS / name)
                for name in ('tests.json', 'install.json', 'install.log', 'replay.json')}
    evidence.update({row['log']: row['log_sha256'] for row in tested})
    report = {'protocol': 'LTCV2-CAPACITY-ONLY-FREEZE/1',
        'phase': 'capacity correction frozen; same DEV frames and native gates; no fresh capacity outcomes read',
        'original_freeze': str(FREEZE), 'original_freeze_sha256': FREEZE_SHA,
        'first_fixed_validation': str(HERE / 'evidence/FIRST-FIXED-20261002.json'),
        'first_fixed_validation_sha256': sha(HERE / 'evidence/FIRST-FIXED-20261002.json'),
        'source_checkpoint': str(HERE / 'evidence/SOURCE-CHECKPOINT-20261001.json'),
        'source_checkpoint_sha256': sha(HERE / 'evidence/SOURCE-CHECKPOINT-20261001.json'),
        'capacity_source': json.loads((HERE / 'evidence/CAPACITY-SOURCE-20261002.json').read_text()),
        'policy': original['policy'], 'limits': dict(original['limits']), 'schema': original['schema'],
        'tests': tested, 'install': install, 'dev_replays': replay,
        'capture': str(CAPTURE), 'captured_binary': str(CAPTURE / binary.name),
        'captured_binary_sha256': sha(binary),
        'snapshot_sha256': {str(target): sha(target) for _, target in inputs},
        'dependency_sha256': dependencies, 'evidence_sha256': evidence,
        'timing': False, 'interpretation': 'resource-only acceptance-profile revision; no compression improvement; first fixed failures and losses remain visible',
        'ownership': original['ownership'],
        'build': {'argv': install['argv'], 'native_core': str(CORE),
                  'portable_replay': original['schema']['portable_replay']}}
    report['limits'].update({'lexemes': 500_000, 'aggregate_work': 128 * 1024 * 1024,
                             'entropy_absolute_events': 128 * 1024 * 1024,
                             'native_packet_work': 128 * 1024 * 1024,
                             'dictionary_work': 128 * 1024 * 1024})
    output = HERE / 'evidence/CAPACITY-FREEZE-20261002.json'; write(output, report)
    print(json.dumps({'manifest': str(output), 'sha256': sha(output),
                      'binary_sha256': sha(binary), 'native_core': str(CORE)}))

if __name__ == '__main__': main()
