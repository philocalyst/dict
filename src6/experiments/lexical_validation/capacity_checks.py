#!/usr/bin/env python3
"""Tests and strict same-DEV byte identity for the resource-only LTC snapshot."""
from __future__ import annotations
import argparse, hashlib, json, pathlib, shutil, subprocess
from prepare_capacity import FREEZE, FREEZE_SHA, TARGET, HERE, ROOT

SCRATCH = pathlib.Path('/workspace/scratch')
CHECKS = SCRATCH / 'lexical-constructions-v2-capacity-checks'
INSTALL = SCRATCH / 'lexical-constructions-v2-capacity-install'
CORE = SCRATCH / 'dict-core-v3-6f043/src6/root.zig'
ZIG = pathlib.Path('/home/agent/.local/bin/zig')
MANIFEST = HERE / 'evidence/CAPACITY-SOURCE-20261002.json'
ORDER = ('global_packet_ans', 'global_typed', 'global_surface', 'global_joint',
         'global_owner', 'global_causal_surface', 'global_causal_joint',
         'global_causal_joint_frequency', 'global_causal_owner',
         'global_causal_owner_frequency')

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def write(path, data): path.write_text(json.dumps(data, sort_keys=True, indent=2) + '\n')
def guarded():
    if sha(FREEZE) != FREEZE_SHA: raise ValueError('original freeze changed')
    source = json.loads(MANIFEST.read_text())
    for row in source['codec_files'].values():
        if sha(pathlib.Path(row['path'])) != row['sha256']:
            raise ValueError('capacity source changed')
        if sha(pathlib.Path(row['original_path'])) != row['original_sha256']:
            raise ValueError('audited snapshot changed')
    frozen = json.loads(FREEZE.read_text())
    for name in ('rich128', 'omw-ja-dev512'):
        for path, digest in frozen['cases'][name]['screen']['provenance']['sources_sha256'].items():
            if sha(pathlib.Path(path)) != digest: raise ValueError('original dependency changed: ' + path)
    for path, digest in frozen['additional_runtime_dependency_sha256'].items():
        if sha(pathlib.Path(path)) != digest: raise ValueError('runtime dependency changed: ' + path)
    return frozen
def run(argv, log, cwd=ROOT):
    with log.open('w') as out:
        process = subprocess.Popen(argv, cwd=cwd, stdout=out, stderr=subprocess.STDOUT)
        print(json.dumps({'pid': process.pid, 'argv': argv, 'log': str(log)}), flush=True)
        code = process.wait()
    return {'argv': argv, 'exit': code, 'log': str(log), 'log_sha256': sha(log)}
def tests():
    guarded(); rows = []
    for mode in ('Debug', 'ReleaseSafe', 'ReleaseFast'):
        argv = [str(ZIG), 'build', '--build-file', str(TARGET / 'build.zig'),
                '-Dlexical-core=' + str(CORE), '-Doptimize=' + mode,
                '--summary', 'all', 'test']
        row = {'mode': mode, **run(argv, CHECKS / (mode + '.log'))}
        rows.append(row); write(CHECKS / 'tests.json', rows)
        if row['exit']: raise SystemExit(row['exit'])
        print('passed ' + mode, flush=True)
    row = run([str(ZIG), 'build', '--build-file', str(TARGET / 'build.zig'),
               '-Dlexical-core=' + str(CORE), '-Doptimize=ReleaseSafe',
               '--prefix', str(INSTALL), '--summary', 'all'], CHECKS / 'install.log')
    row['binary'] = str(INSTALL / 'bin/lexical-shared-constructions')
    if not row['exit']: row['binary_sha256'] = sha(pathlib.Path(row['binary']))
    write(CHECKS / 'install.json', row)
    if row['exit']: raise SystemExit(row['exit'])
def replay():
    frozen = guarded()
    tested = json.loads((CHECKS / 'tests.json').read_text())
    if len(tested) != 3 or any(row['exit'] for row in tested): raise ValueError('three green modes required')
    install = json.loads((CHECKS / 'install.json').read_text()); binary = pathlib.Path(install['binary'])
    if install['exit'] or sha(binary) != install['binary_sha256']: raise ValueError('tested binary changed')
    rows = []
    for name in ('rich128', 'omw-ja-dev512'):
        old = frozen['cases'][name]['screen']; source = pathlib.Path(old['input'])
        if sha(source) != old['input_sha256']: raise ValueError('DEV source changed')
        previous = SCRATCH / ('lexical-constructions-v2-owned-' + name)
        directory = SCRATCH / ('lexical-constructions-v2-capacity-' + name)
        directory.mkdir(exist_ok=True)
        argv = [str(binary), str(source), str(directory)]
        with (directory / 'native.jsonl').open('w') as out, (directory / 'native.stderr.txt').open('w') as err:
            process = subprocess.Popen(argv, cwd=ROOT, stdout=out, stderr=err)
            print(json.dumps({'case': name, 'pid': process.pid, 'argv': argv,
                              'output': str(directory)}), flush=True)
            code = process.wait()
        if code: raise ValueError('native replay failed: ' + name)
        native = [json.loads(line) for line in (directory / 'native.jsonl').read_text().splitlines()]
        if tuple(row['variant'] for row in native) != ORDER: raise ValueError('candidate matrix changed')
        if any(row['roots'] != old['roots'] or row['pages'] != old['pages'] for row in native):
            raise ValueError('source rows/groups changed')
        identities = {}
        for variant in ORDER:
            current, historical = directory / (variant + '.lgb'), previous / (variant + '.lgb')
            if historical.read_bytes() != current.read_bytes(): raise ValueError('DEV wire changed: ' + variant)
            identities[variant] = {'path': str(current), 'sha256': sha(current), 'bytes': current.stat().st_size,
                                   'historical_path': str(historical), 'historical_sha256': sha(historical)}
        chosen = old['selected_global_variant']; typed = frozen['cases'][name]['typed_access_choice']
        for profile, variant in (('adaptive', chosen), ('typed-adaptive', typed)):
            path = directory / (profile + '.lgb'); shutil.copyfile(directory / (variant + '.lgb'), path)
            if path.read_bytes() != (previous / (profile + '.lgb')).read_bytes():
                raise ValueError('selector frame changed')
            identities[profile] = {'path': str(path), 'sha256': sha(path), 'bytes': path.stat().st_size}
        row = {'case': name, 'native_argv': argv, 'native_exit': code,
               'source': str(source), 'source_sha256': sha(source), 'source_bytes': source.stat().st_size,
               'native_proof': str(directory / 'native.jsonl'), 'native_proof_sha256': sha(directory / 'native.jsonl'),
               'native_stderr_sha256': sha(directory / 'native.stderr.txt'), 'native_rows': native,
               'frame_identities': identities, 'gates': {'exact_all_ten_complete_candidate_bytes': True,
                   'source_native_semantics_root_group_roots': 10 * old['roots'],
                   'direct_typed_headword_roots': 7 * old['roots'], 'full_source_records': old['roots'],
                   'original_groups': old['pages'], 'no_policy_change': True}, 'timing': False}
        rows.append(row); write(CHECKS / 'replay.json', rows)
        print('strict identity complete ' + name, flush=True)
    guarded()
def main():
    parser = argparse.ArgumentParser(); parser.add_argument('phase', choices=('tests', 'replay'))
    args = parser.parse_args(); CHECKS.mkdir(exist_ok=True)
    if args.phase == 'tests': tests()
    else: replay()
if __name__ == '__main__': main()
