"""Bounded dev grid; never reads confirmation-20 data."""
import argparse, hashlib, itertools, json, subprocess, sys
from pathlib import Path
from codec import fit, Model, encode_model, decode

HERE=Path(__file__).resolve().parent
INPUTS=HERE.parent/'evidence/runs/wam-screen-preflight-20260926/inputs'

def sha(data): return hashlib.sha256(data).hexdigest()
def row(name,raw,train,rules,boundary,strength,mode=1):
    lit,grammar=fit(train,rules); model=Model(lit,grammar,boundary,strength)
    frame,stats=encode_model(raw,model,mode)
    assert decode(frame)==raw
    return frame,dict(name=name,input_sha256=sha(raw),train_sha256=sha(train),raw_bytes=len(raw),rules_budget=rules,boundary=boundary,strength=strength,mode=mode,roundtrip=True,frame_sha256=sha(frame),**stats)

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('phase',choices=['grid','frozen']); args=parser.parse_args()
    rows=[]; out=HERE/'results'; out.mkdir(exist_ok=True)
    files=sorted(INPUTS.glob('*.bin'))
    if args.phase=='grid':
        # Two language workloads and disjoint held development slices.
        for path in files:
            if not path.name.startswith(('freedict','omw')): continue
            data=path.read_bytes()
            for rules,boundary,strength in itertools.product((64,192),range(3),(4,7)):
                for kind,raw,train in [('self',data[:2048],data[:2048]),('held-dev',data[2048:4096],data[:2048])]:
                    _,r=row(path.stem+'-'+kind,raw,train,rules,boundary,strength); rows.append(r)
                    print(json.dumps(r),flush=True)
        (out/'grid.json').write_text(json.dumps(rows,indent=2)+'\n')
    else:
        # Globally frozen policies after grid: fixed budgets, no per-file choice.
        policies=json.loads((out/'freeze.json').read_text())['policies']
        for path in files:
            raw=path.read_bytes()[:16384]
            inp=out/(path.stem+'.raw'); inp.write_bytes(raw)
            for policy in policies:
                for mode in (1,0):
                    frame,r=row(path.stem,raw,raw,mode=mode,**policy)
                    stem=f'{path.stem}-r{policy["rules"]}-b{policy["boundary"]}-s{policy["strength"]}-m{mode}'
                    fp=out/(stem+'.gsg'); fp.write_bytes(frame); restored=out/(stem+'.decoded')
                    subprocess.run([sys.executable,str(HERE/'codec.py'),'decode',str(fp),str(restored)],check=True)
                    assert restored.read_bytes()==raw
                    r['fresh_roundtrip']=True; rows.append(r); print(json.dumps(r),flush=True)
                control=dict(policy,strength=0)
                frame,r=row(path.stem,raw,raw,mode=1,**control)
                stem=f'{path.stem}-r{policy["rules"]}-no-edges'
                fp=out/(stem+'.gsg'); fp.write_bytes(frame); restored=out/(stem+'.decoded')
                subprocess.run([sys.executable,str(HERE/'codec.py'),'decode',str(fp),str(restored)],check=True)
                assert restored.read_bytes()==raw
                r['fresh_roundtrip']=True; rows.append(r); print(json.dumps(r),flush=True)
        (out/'frozen.json').write_text(json.dumps(rows,indent=2)+'\n')

if __name__=='__main__': main()
