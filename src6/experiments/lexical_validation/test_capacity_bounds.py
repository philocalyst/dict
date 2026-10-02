#!/usr/bin/env python3
"""Small process-bound tests; no dictionary candidate fitting or source outcomes."""
from __future__ import annotations
import json, pathlib, subprocess, sys, tempfile
from run_capacity import bounded_native, native_rows, NATIVE_AS_BYTES

def main():
    output = pathlib.Path('/workspace/scratch/lexical-constructions-v2-capacity-checks/bounded-stage-tests.json')
    results = []
    with tempfile.TemporaryDirectory(prefix='ltc-process-bounds-') as temporary:
        root = pathlib.Path(temporary)
        def case(name, code, **bounds):
            directory = root / name; directory.mkdir()
            status = bounded_native([sys.executable, '-c', code], directory, **bounds)
            results.append({'case': name, 'status': status})
            return directory, status
        directory, status = case('success-and-default-as',
            'import json,resource; print(json.dumps({"as":resource.getrlimit(resource.RLIMIT_AS)}))')
        assert status['exit'] == 0 and status['state'] == 'completed'
        assert json.loads((directory / 'native.jsonl').read_text())['as'] == [NATIVE_AS_BYTES, NATIVE_AS_BYTES]
        _, status = case('native-failure', 'raise SystemExit(23)')
        assert status['exit'] == 23 and status['state'] == 'native_failed'
        directory = root / 'launch-failure'; directory.mkdir()
        status = bounded_native(['/nonexistent-ltc-test-command'], directory)
        results.append({'case': 'launch-failure', 'status': status})
        assert status['exit'] is None and status['state'] == 'launch_failed'
        directory, status = case('address-bound',
            'import sys\ntry: b=bytearray(128*1024*1024)\nexcept MemoryError: sys.exit(27)\nsys.exit(99)',
            address_space_bytes=64 * 1024 * 1024)
        assert status['exit'] == 27 and not status['timed_out']
        directory, status = case('timeout-group-and-partial-row',
            'import pathlib,subprocess,sys,time\n'
            'child=subprocess.Popen([sys.executable,"-c","import time; time.sleep(60)"])\n'
            'pathlib.Path(sys.argv[0] if False else ' + repr(str(root / 'descendant.pid')) + ').write_text(str(child.pid))\n'
            'print("{\\\"unfinished\\\":",end="",flush=True)\ntime.sleep(60)', timeout_seconds=0.5)
        assert status['timed_out'] and status['exit'] < 0 and status['process_group_kill_sent']
        descendant = int((root / 'descendant.pid').read_text())
        descendant_status = pathlib.Path('/proc') / str(descendant) / 'status'
        if descendant_status.exists():
            state = next(line for line in descendant_status.read_text().splitlines() if line.startswith('State:'))
            assert '\tZ' in state, 'descendant still running after group kill'
        rows, partial = native_rows(directory / 'native.jsonl', True)
        assert rows == [] and partial is not None
        results[-1]['descendant_pid'] = descendant
        results[-1]['descendant_dead_or_zombie'] = True
        # The stale initial freeze intentionally rejects the revised stage.
        # This tests that proof rejection never creates the requested output.
        rejected = root / 'must-not-be-created'
        freeze = pathlib.Path(__file__).parent / 'evidence/CAPACITY-FREEZE-20261002.json'
        process = subprocess.run([sys.executable, str(pathlib.Path(__file__).parent / 'run_capacity.py'),
            '--freeze', str(freeze), '--expected-freeze-sha256', 'incorrect', '--output', str(rejected)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert process.returncode != 0 and not rejected.exists()
        results.append({'case': 'freeze-before-output-creation', 'exit': process.returncode,
                        'output_created': rejected.exists()})
    output.write_text(json.dumps({'protocol': 'LTC-CAPACITY-BOUNDED-STAGE-TESTS/1',
        'cases': results, 'all_passed': True, 'dictionary_fits': 0}, sort_keys=True, indent=2) + '\n')
    print(json.dumps({'tests': str(output), 'passed': len(results), 'dictionary_fits': 0}))

if __name__ == '__main__': main()
