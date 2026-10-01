"""Auditable bounded development screen; no confirmation-20 access."""
from pathlib import Path
import argparse
import hashlib
import json
import time
import adapter

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--limit',type=int,default=2048)
    parser.add_argument('--out',required=True); parser.add_argument('--priced-refit',action='store_true'); args=parser.parse_args()
    # The second policy is explicit, preserving the first frozen negative run.
    root=adapter.FRONTIER
    sources=[root.parent/'bz4/data/omw.eval8.bin',
             root/'evidence/corpora/ud-fi-train/exploratory-80/text.txt',
             root/'evidence/corpora/ud-tr-train/exploratory-80/text.txt']
    out=adapter.HERE/args.out; out.mkdir(parents=True,exist_ok=False); records=[]
    provenance=adapter.fingerprint()
    (out/'implementation.json').write_text(json.dumps(provenance,indent=2)+'\n')
    for file in ('adapter.py','prices.zig','screen.py'):
        (out/file).write_bytes((adapter.HERE/file).read_bytes())
    for source in sources:
        raw=source.read_bytes()[:args.limit]; name=source.parent.parent.name+'-'+source.name
        start=time.perf_counter(); frame=adapter.encode(raw,block_bytes=65536,priced_refit=args.priced_refit)
        elapsed=time.perf_counter()-start; decoded=adapter.decode(frame)
        if decoded != raw: raise AssertionError(name)
        (out/(name+'.raw')).write_bytes(raw); (out/(name+'.b4')).write_bytes(frame)
        record=dict(source=str(source),raw_bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest(),
                    implementation=provenance,policy='native-priced-refit-v2' if args.priced_refit else 'first-grid',
                    frame_sha256=hashlib.sha256(frame).hexdigest(),complete_bytes=len(frame),
                    encode_seconds=elapsed,external_decode_exact=True,trials=adapter.LAST_SEARCH)
        records.append(record); (out/'results.json').write_text(json.dumps(records,indent=2)+'\n')
        print(name,len(raw),len(frame),round(elapsed,3),flush=True)

if __name__=='__main__': main()
