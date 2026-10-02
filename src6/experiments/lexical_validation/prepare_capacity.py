#!/usr/bin/env python3
"""Copy the audited LTCv2 source with only registered capacity ceilings changed."""
from __future__ import annotations
import difflib, hashlib, json, pathlib

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
FREEZE = ROOT / 'src6/experiments/lexical_constructions/evidence/DEV-2-OWNED-FREEZE-20261001.json'
FREEZE_SHA = '1f524079af2a999550f0cf2c633cf6db16bdc6ee41a4b6d48d621fe7ccdced84'
SOURCE = pathlib.Path('/workspace/scratch/lexical-constructions-v2-owned-capture/source')
TARGET = ROOT / 'src6/experiments/lexical_capacity'
EDITS = {
    'entropy.zig': [('pub const max_events: usize = 8_000_000;',
                     'pub const max_events: usize = 128 * 1024 * 1024;')],
    'surface.zig': [('pub const default_max_lexemes: usize = 100_000;',
                     'pub const default_max_lexemes: usize = 500_000;')],
    'global_runner.zig': [('.max_work = 64_000_000', '.max_work = 128 * 1024 * 1024')],
}

def sha(data): return hashlib.sha256(data).hexdigest()

def main():
    if sha(FREEZE.read_bytes()) != FREEZE_SHA:
        raise ValueError('original independently audited freeze changed')
    frozen = json.loads(FREEZE.read_text())
    TARGET.mkdir(exist_ok=True)
    files, diff = {}, []
    for source in sorted(SOURCE.glob('*.zig')):
        original = source.read_bytes()
        if frozen['snapshot_sha256'][str(source)] != sha(original):
            raise ValueError('audited source changed: ' + str(source))
        text = original.decode()
        for before, after in EDITS.get(source.name, []):
            count = text.count(before)
            expected = 3 if source.name == 'global_runner.zig' else 1
            if count != expected:
                raise ValueError('resource edit count mismatch: ' + source.name)
            text = text.replace(before, after)
        result = text.encode()
        target = TARGET / source.name
        if target.exists() and target.read_bytes() != result:
            raise ValueError('capacity snapshot overwrite refused: ' + str(target))
        target.write_bytes(result)
        files[source.name] = {'original_path': str(source), 'original_sha256': sha(original),
                              'path': str(target), 'sha256': sha(result), 'changed': result != original}
        if result != original:
            diff.extend(difflib.unified_diff(original.decode().splitlines(keepends=True),
                                           text.splitlines(keepends=True),
                                           fromfile='audited/' + source.name,
                                           tofile='capacity/' + source.name))
    if {name for name, row in files.items() if row['changed']} != set(EDITS):
        raise ValueError('only the three declared source files may change')
    diff_path = HERE / 'evidence/CAPACITY-RESOURCE-ONLY-20261002.patch'
    diff_path.write_text(''.join(diff))
    protocol = HERE / 'CAPACITY-PROPOSAL-20261002.md'
    report = {'protocol': 'LTCV2-CAPACITY-ONLY-SOURCE/1', 'phase': 'prepared; no fresh validation',
              'original_freeze': str(FREEZE), 'original_freeze_sha256': FREEZE_SHA,
              'proposal': str(protocol), 'proposal_sha256': sha(protocol.read_bytes()),
              'prepare_source': str(pathlib.Path(__file__)), 'prepare_source_sha256': sha(pathlib.Path(__file__).read_bytes()),
              'precise_diff': str(diff_path), 'precise_diff_sha256': sha(diff_path.read_bytes()),
              'codec_files': files, 'resource_changes': {'lexemes': [100_000, 500_000],
                  'absolute_entropy_events': [8_000_000, 128 * 1024 * 1024],
                  'global_aggregate_work': [64_000_000, 128 * 1024 * 1024]},
              'unchanged': 'schema/wire/ten options/order/ties/models/source/groups/per-root non-work limits/semantic limits; old freeze and first fixed failures preserved',
              'old_runner_comment': 'historical 8M entropy comment retained verbatim; actual constant is recorded above to keep the codec diff resource-only'}
    output = HERE / 'evidence/CAPACITY-SOURCE-20261002.json'
    output.write_text(json.dumps(report, sort_keys=True, indent=2) + '\n')
    print(json.dumps({'source_manifest': str(output), 'sha256': sha(output.read_bytes()), 'files': len(files)}))

if __name__ == '__main__': main()
