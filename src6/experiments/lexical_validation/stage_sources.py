#!/usr/bin/env python3
"""Prepare hash-locked whole-record native-v3 inputs before LTC outcomes.

This client neither changes nor invokes the candidate codec. It checks the
reserved oracle and runs the already frozen native projection/LPB producer.
"""
from __future__ import annotations
import argparse,hashlib,json,pathlib,subprocess
REPO=pathlib.Path(__file__).resolve().parents[3]
RESERVED=pathlib.Path('/workspace/scratch/structural-holdout')
MANIFEST_SHA='6e1709311f9f677d57e4b93dfb118674e8d01cc70d140e62f9dd9b6d74e87f4a'
PAIRS=('tur-eng','ara-eng','jpn-eng')
PRODUCER=pathlib.Path('/workspace/scratch/lexical-pages-complete/bin/lexical-pages')
FREEZE=REPO/'src6/experiments/lexical_constructions/evidence/DEV-2-OWNED-FREEZE-20261001.json'
FREEZE_SHA='1f524079af2a999550f0cf2c633cf6db16bdc6ee41a4b6d48d621fe7ccdced84'
def sha(path):
    h=hashlib.sha256()
    with path.open('rb')as f:
        for part in iter(lambda:f.read(1<<20),b''):h.update(part)
    return h.hexdigest()
def file(path):return {'path':str(path),'bytes':path.stat().st_size,'sha256':sha(path)}
def verified(spec):
    path=pathlib.Path(spec['path'])
    if path.stat().st_size!=spec['bytes']or sha(path)!=spec['sha256']:raise ValueError('source hash mismatch '+str(path))
    return path
def u32(data,at):return int.from_bytes(data[at:at+4],'little')
def old_digest(data):return hashlib.sha256(data[:32]+data[64:]).digest()
def lpb(path,expected_roots):
    data=path.read_bytes()
    if len(data)<64 or data[:8]!=b'LPB1\2\0\0\0'or u32(data,16)!=24 or u32(data,20)or old_digest(data)!=data[32:64]:raise ValueError('LPB envelope')
    pages,roots=u32(data,8),u32(data,12);at=64+24*pages;first=rawsum=0;groups=[];packet_hash=hashlib.sha256()
    if roots!=expected_roots or at>len(data):raise ValueError('all source rows required')
    for i in range(pages):
        row=64+24*i;start,n,raw,stored,offset=(u32(data,row+4*j)for j in range(5))
        if start!=first or not n or raw!=stored or offset!=at or u32(data,row+20)or stored>len(data)-at or stored>1024*1024:raise ValueError('fixed raw source group')
        frame=data[at:at+stored]
        if len(frame)<64 or frame[:8]!=b'LPD1\1\0\0\0'or u32(frame,8)!=n or u32(frame,12)!=n or old_digest(frame)!=frame[32:64]:raise ValueError('flat source frame')
        payload=64+4*(n+1)
        if payload>len(frame)or u32(frame,64)or u32(frame,payload-4)!=len(frame)-payload:raise ValueError('flat root offsets')
        for j in range(n):
            a,b=u32(frame,64+4*j),u32(frame,68+4*j)
            if a>=b or b>len(frame)-payload:raise ValueError('complete root packet bounds')
            packet=frame[payload+a:payload+b]
            if packet[:5]!=b'LXP6\3':raise ValueError('explicit packet v3 required')
            packet_hash.update(len(packet).to_bytes(4,'little'));packet_hash.update(packet)
        groups.append({'first':first,'roots':n,'raw_bytes':stored,'offset':at,'sha256':hashlib.sha256(frame).hexdigest()});first+=n;at+=stored;rawsum+=stored
    if first!=roots or at!=len(data)or rawsum!=int.from_bytes(data[24:32],'little'):raise ValueError('complete source totals')
    return file(path)|{'pages':pages,'roots':roots,'groups':groups,'length_delimited_native_packets_sha256':packet_hash.hexdigest()}
def oracle(projection,rows,pair,expected):
    count=content_bytes=key_hits=0;identities=set();material=hashlib.sha256();previous=-1
    with projection.open('rb')as p,rows.open('rb')as r:
        for line in p:
            fields=line.rstrip(b'\n').split(b'\t')
            if len(fields)!=3:raise ValueError('three-column native projection')
            identity=bytes.fromhex(fields[0].decode());keys=[bytes.fromhex(k.decode())for k in fields[1].split(b',')];content=bytes.fromhex(fields[2].decode());row_line=r.readline()
            if not row_line:raise ValueError('missing complete source oracle')
            row=json.loads(row_line)
            if identity.decode('utf-8')!=row['row_id']or identity in identities or [k.decode('utf-8')for k in keys]!=row['keys']or len(keys)!=row['key_count']:raise ValueError('identity/ordered keys mismatch')
            if len(content)!=row['content_bytes']or hashlib.sha256(content).hexdigest()!=row['content_sha256']:raise ValueError('complete serialized record mismatch')
            content.decode('utf-8');identities.add(identity)
            modulus=16 if pair=='jpn-eng'else 1
            if int(hashlib.sha256(row['source_entry_id'].encode()).hexdigest(),16)%modulus or row['source_ordinal']<=previous:raise ValueError('predeclared whole-record selection/order mismatch')
            previous=row['source_ordinal'];count+=1;content_bytes+=len(content);key_hits+=len(keys)
            for value in(identity,*keys,content):material.update(len(value).to_bytes(8,'little'));material.update(value)
        if r.read(1)or count!=expected:raise ValueError('all complete records required')
    return {'rows':count,'content_bytes':content_bytes,'ordered_key_hits':key_hits,'length_delimited_material_sha256':material.hexdigest(),'gate':'every projection identity/ordered key/complete serialized entry byte string matches rows.jsonl; source order and predeclared selection retained','caveat':'complete adapter-normalized TEI entry XML, not original raw TEI byte stream; front matter excluded by original declared adapter'}
def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);args=p.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    if sha(RESERVED/'manifest.json')!=MANIFEST_SHA or sha(FREEZE)!=FREEZE_SHA:raise ValueError('reserved/frozen manifest changed')
    top=json.loads((RESERVED/'manifest.json').read_text());lock=REPO/'src6/bench/structural2026/sources.json'
    if sha(lock)!=top['source_lock_sha256']:raise ValueError('source lock mismatch')
    stage={'protocol':'LTCV2-WHOLE-RECORD-SOURCE-CHECKPOINT/1','phase':'source/native-baseline preparation only; no candidate outcomes','candidate_freeze':file(FREEZE),'reserved_manifest':file(RESERVED/'manifest.json'),'producer':file(PRODUCER),'stage_source':file(pathlib.Path(__file__)),'source_adapters':{str(q):sha(q)for q in(REPO/'src6/bench/structural2026/prepare_holdout.py',REPO/'src6/bench/real-world/prepare.py',lock)},'lanes':[],'candidate_capacity':'frozen limits unchanged; a whole-source candidate/budget failure is visible, not a truncated source or codec size loss'}
    checkpoint=args.output/'source-checkpoint.json'
    for pair in PAIRS:
        source_dir=RESERVED/'dictionaries'/pair;manifest=source_dir/'projection-manifest.json';doc=json.loads(manifest.read_text());projection=verified(doc['projection_tsv']);rows=verified(doc['rows_jsonl']);raw=verified(doc['source_manifest'])
        material=oracle(projection,rows,pair,doc['rows']);lane=args.output/pair;lane.mkdir(exist_ok=True);prefix=lane/'native';argv=[str(PRODUCER),'natural',str(projection),'--entries','0','--retain-prefix',str(prefix)]
        record={'pair':pair,'projection':file(projection),'projection_manifest':file(manifest),'rows_oracle':file(rows),'raw_tei_source':file(raw),'selection':doc['stats']['selection'],'material_oracle':material,'producer_argv':argv};stage['lanes'].append(record);checkpoint.write_text(json.dumps(stage,sort_keys=True,indent=2)+'\n')
        with(lane/'producer.jsonl').open('w')as out,(lane/'producer.stderr.txt').open('w')as err:r=subprocess.run(argv,cwd=REPO,stdout=out,stderr=err)
        record['producer_exit']=r.returncode
        if r.returncode:checkpoint.write_text(json.dumps(stage,sort_keys=True,indent=2)+'\n');raise SystemExit(r.returncode)
        if 'all_flat_shared_shape_roots_admitted_native_equal_and_complete_native_observation_equal'not in(lane/'producer.jsonl').read_text():raise ValueError('complete frozen native producer gate missing')
        record['producer_proof']=file(lane/'producer.jsonl');record['flat_lpb']=lpb(pathlib.Path(str(prefix)+'.flat.raw.lpb'),doc['rows']);checkpoint.write_text(json.dumps(stage,sort_keys=True,indent=2)+'\n');print(pair,doc['rows'],'all record material/native/group gates; checkpoint updated',flush=True)
    print(json.dumps({'checkpoint':str(checkpoint),'sha256':sha(checkpoint),'candidate_outcomes':False}),flush=True)
if __name__=='__main__':main()
