"""Separate subsequent GSG2 experiment: paid actual root-adjacency counts."""
import itertools,json,sys,subprocess
from pathlib import Path
from codec import fit,Model,select_edges,encode_model,decode
from screen import INPUTS,HERE,sha

def run(name,raw,train,cap,topology,rules):
    literals,grammar,seq=fit(train,rules,return_sequence=True)
    edges=select_edges(seq,cap)
    model=Model(literals,grammar,2,4,root_edges=edges,topology=topology)
    frame,stats=encode_model(raw,model)
    assert decode(frame)==raw
    return frame,dict(name=name,raw_bytes=len(raw),input_sha256=sha(raw),train_sha256=sha(train),edge_cap=cap,root_edges=len(edges),topology=topology,rules_budget=rules,frame_sha256=sha(frame),roundtrip=True,**stats)

def main():
    phase=sys.argv[1]; rows=[]; out=HERE/'results'
    if phase=='grid':
        for path in sorted(INPUTS.glob('*.bin')):
            if not path.name.startswith(('freedict','omw')):continue
            data=path.read_bytes()
            for cap,topology in itertools.product((64,256),(1,2)):
                for kind,raw,train in [('self',data[:2048],data[:2048]),('held-dev',data[2048:4096],data[:2048])]:
                    frame,r=run(path.stem+'-'+kind,raw,train,cap,topology,192); rows.append(r);print(json.dumps(r),flush=True)
                    (out/(r['name']+f'-root-c{cap}-t{topology}.gsg')).write_bytes(frame)
        (out/'root-grid.json').write_text(json.dumps(rows,indent=2)+'\n')
    else:
        frozen=json.loads((out/'root-freeze.json').read_text())
        for path in sorted(INPUTS.glob('*.bin')):
            raw=path.read_bytes()[:16384]
            frame,r=run(path.stem,raw,raw,**frozen['policy']);rows.append(r)
            fp=out/(path.stem+'-root.gsg');fp.write_bytes(frame);target=out/(path.stem+'-root.decoded')
            subprocess.run([sys.executable,str(HERE/'codec.py'),'decode',str(fp),str(target)],check=True)
            assert target.read_bytes()==raw;r['fresh_roundtrip']=True;print(json.dumps(r),flush=True)
        (out/'root-frozen.json').write_text(json.dumps(rows,indent=2)+'\n')
if __name__=='__main__': main()
