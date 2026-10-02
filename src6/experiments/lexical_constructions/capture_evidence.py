#!/usr/bin/env python3
"""Lightweight immutable v2 DEV capture; never encodes, times, or tunes data."""
from __future__ import annotations
import hashlib, json, pathlib, shutil, subprocess
HERE=pathlib.Path(__file__).resolve().parent
SCRATCH=pathlib.Path('/workspace/scratch')
NAMES=('rich128','omw-ja-dev512')
EXPECTED={'rich128':'96479afc64f6a211f7b34471a130bf624dce91bb5217b5d6e8b16e2571505c93','omw-ja-dev512':'1cd8c6fe48a5ee003e81973e3b15541ee90fadd9abbd84e9e2eddea18ad389d4'}
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    snapshot=SCRATCH/'lexical-constructions-v2-capture';snapshot.mkdir(exist_ok=True)
    sources=snapshot/'source';sources.mkdir(exist_ok=True)
    for path in sorted(HERE.iterdir()):
        if path.is_file()and path.suffix in('.zig','.py','.md'):
            target=sources/path.name
            if target.exists()and sha(target)!=sha(path):raise ValueError('refusing snapshot overwrite '+path.name)
            shutil.copyfile(path,target)
    report={'protocol':'LEXICAL-SHARED-CONSTRUCTION-DEV-CAPTURE/2','scope':'DEV only; frozen old native v3 Entry, first-class semantic Document in meaningful tests; no inferred analysis of natural sources','head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=HERE,text=True).strip(),'compiler':{'version':subprocess.check_output(['/home/agent/.local/bin/zig','version'],text=True).strip(),'executable':'/home/agent/.local/bin/zig'},'test':{'optimize':'ReleaseSafe','status':'pass','first_failure':'new wrong-kind-reference fixture used nonexistent Item.representation; corrected to native Form.representations; corrected build/test exit0','lexical_core':'/workspace/scratch/dict-core-v3-6f043/src6/root.zig'},'timing':False,'cases':{},'snapshot':str(snapshot),'instrumentation_source':str(pathlib.Path(__file__)),'instrumentation_sha256':sha(pathlib.Path(__file__))}
    for name in NAMES:
        directory=SCRATCH/('lexical-constructions-v2-global-'+name)
        ledger=json.loads((directory/'screen.json').read_text());rows=[json.loads(line)for line in(directory/'native.jsonl').read_text().splitlines()]
        if ledger['input_sha256']!=EXPECTED[name]or len(rows)!=10:raise ValueError('input/matrix gate')
        variants=list(ledger['variants']);variants.remove('adaptive')
        if len(variants)!=10 or {r['variant']for r in rows}!=set(variants):raise ValueError('candidate matrix mismatch')
        for path,digest in ledger['provenance']['sources_sha256'].items():
            if sha(pathlib.Path(path))!=digest:raise ValueError('source mutation '+path)
        binary=pathlib.Path(ledger['provenance']['native_binary']);target=snapshot/binary.name
        if sha(binary)!=ledger['provenance']['native_binary_sha256']:raise ValueError('binary mutation')
        if target.exists()and sha(target)!=sha(binary):raise ValueError('snapshot binary mismatch')
        shutil.copyfile(binary,target)
        typed=[]
        for variant in variants:
            data=(directory/(variant+'.lgb')).read_bytes();row=next(r for r in rows if r['variant']==variant)
            if len(data)!=row['complete_bundle_bytes'] or hashlib.sha256(data).hexdigest()!=ledger['variants'][variant]['sha256']:raise ValueError('frame/stats mismatch')
            offset=int.from_bytes(data[20:24],'little')
            if data[offset+5]&1:typed.append(variant)
        typed_choice=min(typed,key=lambda v:(ledger['variants'][v]['complete_bytes'],variants.index(v)))
        shutil.copyfile(directory/(typed_choice+'.lgb'),directory/'typed-adaptive.lgb')
        row=next(r for r in rows if r['variant']==typed_choice);s=row['stats']
        pool_payload=s['decoded_dictionary_bytes']+row['decoded_lexeme_index_bytes']+row['prepared_model_owned_heap_bytes']
        report['cases'][name]={'screen':ledger,'screen_path':str(directory/'screen.json'),'screen_sha256':sha(directory/'screen.json'),'native_rows':rows,'native_jsonl_sha256':sha(directory/'native.jsonl'),'complete_size_choice':ledger['selected_global_variant'],'typed_access_choice':typed_choice,'typed_access_result':ledger['variants'][typed_choice],'typed_access_artifact':str(directory/'typed-adaptive.lgb'),'memory':{'typed_owned_dynamic_payload_bytes':pool_payload,'decoded_literal_pool_bytes':s['decoded_dictionary_bytes'],'owned_lexeme_index_bytes':row['decoded_lexeme_index_bytes'],'owned_model_heap_bytes':row['prepared_model_owned_heap_bytes'],'page_value_bytes':row['prepared_page_value_bytes'],'borrowed_complete_bundle_bytes':row['complete_bundle_bytes'],'scope':'dynamic payload plus page value, excluding allocator overhead/capacity, stack capability copies and transient full admission/reencoding arenas; not a measured peak-RSS claim'},'gates':{'candidate_encodes':10,'full_native_roots':10*ledger['roots'],'typed_projection_roots':len(typed)*ledger['roots'],'original_groups':ledger['pages'],'all_exact_source/native/semantic/root/group_gates':True}}
    deps={}
    for path in sorted((HERE.parents[2]/'vendor'/'bzip3').rglob('*')):
        if path.is_file()and path.suffix in('.c','.h'):deps[str(path)]=sha(path)
    report['vendor_sources_sha256']=deps
    report['snapshot_sha256']={str(p):sha(p)for p in sorted(snapshot.rglob('*'))if p.is_file()}
    output=HERE/'evidence'/'DEV-2-GLOBAL-20261001.json';output.write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
    print(json.dumps({'evidence':str(output),'sha256':sha(output),'snapshot':str(snapshot),'typed_choices':{k:v['typed_access_choice']for k,v in report['cases'].items()}},sort_keys=True))
if __name__=='__main__':main()
