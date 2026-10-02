#!/usr/bin/env python3
"""First frozen LTCv2 whole-source validation; failures remain visible.

No codec mutation, filtering, timing or fit policy changes. A source receives
both paid backend scopes even if the immutable native candidate client fails.
"""
from __future__ import annotations
import argparse,hashlib,importlib.util,json,pathlib,struct,subprocess
HERE=pathlib.Path(__file__).resolve().parent
REPO=HERE.parents[2]
CHECKPOINT=HERE/'evidence/SOURCE-CHECKPOINT-20261001.json'
CHECKPOINT_SHA='064e8b9d65c249dcf0d424bcd8a2b98fd0e3fa9ae483dc07e3ce5ef6fa0e3fbf'
FREEZE=REPO/'src6/experiments/lexical_constructions/evidence/DEV-2-OWNED-FREEZE-20261001.json'
FREEZE_SHA='1f524079af2a999550f0cf2c633cf6db16bdc6ee41a4b6d48d621fe7ccdced84'
BINARY=pathlib.Path('/workspace/scratch/lexical-constructions-v2-owned-capture/lexical-shared-constructions')
BINARY_SHA='9544111de6f587d4d374e169f8391922dcfa7d1a10151a14c5a76e638dfc5597'
spec=importlib.util.spec_from_file_location('frozen_ltc_whole_controls',REPO/'src6/experiments/lexical_constructions/shared_screen.py')
shared=importlib.util.module_from_spec(spec);spec.loader.exec_module(shared)
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def locked(record):
    p=pathlib.Path(record['path'])
    if p.stat().st_size!=record['bytes']or sha(p)!=record['sha256']:raise ValueError('locked artifact changed '+str(p))
    return p
def control_base(source,rawframes,groups):
    data=bytearray(128+24*len(groups));data[:8]=b'LGB1\1\0\0\0'
    struct.pack_into('<6I',data,8,len(groups),sum(n for _,n in groups),24,len(data),0,0)
    canonical=0
    for i,((first,n),raw)in enumerate(zip(groups,rawframes)):
        end=canonical+len(raw)-64-4*(n+1)
        struct.pack_into('<6I',data,128+24*i,first,n,len(raw),canonical,end,0);canonical=end
    struct.pack_into('<2Q',data,32,sum(map(len,rawframes)),canonical);data[64:96]=hashlib.sha256(source).digest();data[96:128]=shared.digest(data)
    return bytes(data)
def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);args=p.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    if sha(CHECKPOINT)!=CHECKPOINT_SHA or sha(FREEZE)!=FREEZE_SHA or sha(BINARY)!=BINARY_SHA:raise ValueError('audited checkpoint/codec changed')
    checkpoint=json.loads(CHECKPOINT.read_text());freeze=json.loads(FREEZE.read_text())
    for path,h in freeze['snapshot_sha256'].items():
        if sha(pathlib.Path(path))!=h:raise ValueError('immutable snapshot changed')
    for path,h in freeze['additional_runtime_dependency_sha256'].items():
        if sha(pathlib.Path(path))!=h:raise ValueError('runtime dependency changed '+path)
    for case in freeze['cases'].values():
        for path,h in case['screen']['provenance']['sources_sha256'].items():
            if sha(pathlib.Path(path))!=h:raise ValueError('source dependency changed '+path)
    ledger={'protocol':'LTCV2-FIRST-FIXED-WHOLE-SOURCE-VALIDATION/1','phase':'first heldout outcomes; all codec/model/limit/selector policies frozen beforehand','checkpoint':str(CHECKPOINT),'checkpoint_sha256':CHECKPOINT_SHA,'freeze':str(FREEZE),'freeze_sha256':FREEZE_SHA,'native_binary':str(BINARY),'native_binary_sha256':BINARY_SHA,'stage_source':str(pathlib.Path(__file__)),'stage_source_sha256':sha(pathlib.Path(__file__)),'lanes':[],'timing':False,'failure_policy':'record immutable client fail-fast; no source omissions/limit lift/retry/selector tuning; run all declared sources and both backend controls even on candidate failure'}
    output=args.output/'fixed-validation.json'
    for lane in checkpoint['lanes']:
        for key in('projection','projection_manifest','rows_oracle','raw_tei_source','producer_proof','flat_lpb'):locked(lane[key])
        source_path=locked(lane['flat_lpb']);directory=args.output/lane['pair'];directory.mkdir(exist_ok=True)
        argv=[str(BINARY),str(source_path),str(directory)]
        with(directory/'native.jsonl').open('w')as out,(directory/'native.stderr.txt').open('w')as err:run=subprocess.run(argv,cwd=REPO,stdout=out,stderr=err)
        rows=[json.loads(line)for line in(directory/'native.jsonl').read_text().splitlines()]
        if [r['variant']for r in rows]!=list(shared.VARIANTS[:len(rows)]):raise ValueError('native candidate order changed')
        row={'pair':lane['pair'],'source_lpb':lane['flat_lpb'],'projection':lane['projection'],'source_selection':lane['selection'],'source_material':lane['material_oracle'],'native_argv':argv,'native_exit':run.returncode,'native_rows':rows,'native_proof_sha256':sha(directory/'native.jsonl'),'native_stderr':(directory/'native.stderr.txt').read_text(),'native_stderr_sha256':sha(directory/'native.stderr.txt'),'candidate_count_declared':10,'candidate_count_completed':len(rows),'status':'all ten native gates complete'if run.returncode==0 else'whole-source candidate family failed under frozen resources; no size claim','controls':{},'variants':{}}
        ledger['lanes'].append(row);output.write_text(json.dumps(ledger,sort_keys=True,indent=2)+'\n')
        source,rawframes,groups=shared.page.old_bundle(source_path);base=control_base(source,rawframes,groups);whole=shared.whole_flat(rawframes,groups)
        for backend in('bzip3','zstd19'):
            codec=shared.page.Codec(backend);matched=shared.page.control(source,groups,rawframes,codec)
            if backend=='bzip3':codec.session=shared.page.flat_controls.Bzip3Session(32*1024*1024,bindings=shared.page.flat_controls._Bzip3Bindings(pathlib.Path('/workspace/scratch/libbzip3.so')))
            global_control=shared.whole_control(base,whole,codec)
            for scope,data,suffix in(('matched_pages',matched,'.lpb'),('whole_flat',global_control,'.lgc')):
                path=directory/('flat.'+scope+'.'+backend+suffix);path.write_bytes(data);row['controls'][scope+'/'+backend]={'path':str(path),'complete_bytes':len(data),'sha256':sha(path),'gate':'actual framed backend reopened/decoded and exact original admitted native packet bytes preserved'}
        if run.returncode==0:
            if len(rows)!=10 or any(r['roots']!=lane['flat_lpb']['roots']or r['pages']!=lane['flat_lpb']['pages']for r in rows):raise ValueError('all records/groups required')
            typed=[]
            for variant in shared.VARIANTS:
                path=directory/(variant+'.lgb');data=path.read_bytes();records,frame=shared.read_global(data)
                if data[64:96].hex()!=lane['flat_lpb']['sha256']or len(records)!=len(groups):raise ValueError('source provenance mismatch')
                if frame[5]&1:typed.append(variant)
                row['variants'][variant]={'path':str(path),'complete_bytes':len(data),'sha256':sha(path),'direct_typed_headword':bool(frame[5]&1),'delta_percent':{k:100*(len(data)/v['complete_bytes']-1)for k,v in row['controls'].items()}}
            for profile,candidates in(('complete_size',shared.VARIANTS),('typed_access',typed)):
                choice=min(candidates,key=lambda v:(row['variants'][v]['complete_bytes'],shared.VARIANTS.index(v)));row[profile+'_choice']=choice
                (directory/(profile+'-adaptive.lgb')).write_bytes((directory/(choice+'.lgb')).read_bytes())
            row['gates']={'full_native/source/root/group_roots':10*lane['flat_lpb']['roots'],'direct_typed_headword_roots':len(typed)*lane['flat_lpb']['roots'],'all_source_records':True}
        else:
            row['first_failed_variant']=shared.VARIANTS[len(rows)]if len(rows)<10 else'unknown';row['not_completed_due_fail_fast']=list(shared.VARIANTS[len(rows)+1:]);row['gates']={'complete_frozen_baseline_source_records':lane['flat_lpb']['roots'],'candidate_family_completed':False}
        output.write_text(json.dumps(ledger,sort_keys=True,indent=2)+'\n');print(lane['pair'],row['status'],'native_exit',run.returncode,'completed',len(rows),'controls',len(row['controls']),flush=True)
    print(json.dumps({'ledger':str(output),'sha256':sha(output),'timing':False}),flush=True)
if __name__=='__main__':main()
