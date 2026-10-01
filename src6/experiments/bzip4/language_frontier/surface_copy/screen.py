"""Bounded development screen; writes complete artifacts in owned lane."""
import argparse
import hashlib
import itertools
import json
from pathlib import Path
from codec import encode,decode

HERE = Path(__file__).resolve().parent
INPUTS = HERE.parent/'evidence/runs/wam-screen-preflight-20260926/inputs'
NAMES = ('web2','freedict-eval8','omw-eval8','ud-fi-test-form','ud-tr-test-form','ud-ar-test-form')
GRID = [dict(policy=p,frontier=k,survival=s,start=r)
        for p,k,s,r in itertools.product((0,1),(8,32),(0,1),(1,2,3))]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--confirm',action='store_true')
    args = parser.parse_args()
    run = HERE/'runs'/('confirm-v3' if args.confirm else 'screen-v3')
    run.mkdir(parents=True,exist_ok=True)
    if args.confirm:
        frozen = json.loads((HERE/'runs/screen-v3/frozen.json').read_text())
        configs = frozen+[dict(policy=0,frontier=8,survival=0,start=0)]
        lengths = (16384,65536)
    else:
        configs = GRID+[dict(policy=0,frontier=8,survival=0,start=0)]
        lengths = (2048,)
        (run/'predeclared.json').write_text(json.dumps(GRID,indent=2))
    (run/'codec-source.json').write_text(json.dumps(dict(path=str(HERE/'codec.py'),sha256=hashlib.sha256((HERE/'codec.py').read_bytes()).hexdigest()),indent=2))
    rows = []
    for i,config in enumerate(configs):
        total = 0
        for n in lengths:
            for name in NAMES:
                raw = (INPUTS/f'{name}.prefix65536.bin').read_bytes()[:n]
                frame = encode(raw,block_bytes=65536,**config)
                assert decode(frame) == raw
                path = run/f'p{i}-{name}-{n}.scm'
                path.write_bytes(frame)
                row = dict(policy_index=i,options=config,name=name,length=n,bytes=len(frame),
                           input_sha256=hashlib.sha256(raw).hexdigest(),frame_sha256=hashlib.sha256(frame).hexdigest(),
                           frame=str(path),roundtrip=True)
                rows.append(row)
                total += len(frame)
                (run/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
        print(i,config,total,flush=True)
    if not args.confirm:
        rank = sorted(range(len(GRID)),key=lambda i:sum(r['bytes'] for r in rows if r['policy_index']==i))
        (run/'frozen.json').write_text(json.dumps([GRID[i] for i in rank[:3]],indent=2)+'\n')


if __name__ == '__main__': main()
