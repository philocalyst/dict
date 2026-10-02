#!/usr/bin/env python3
"""DEV complete global-stock frames, with page and whole-flat controls.

The native binary has admitted every candidate before this byte ledger runs.
No timing claim; every candidate/model/stock/root index and original group
directory is charged. Whole-flat controls resolve a whole block per cold read,
so their sizes are relevant but their access architecture differs explicitly.
"""
from __future__ import annotations
import argparse, hashlib, importlib.util, json, pathlib, struct
HERE=pathlib.Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('lexical_constructions_page_ledger',HERE/'screen.py')
page=importlib.util.module_from_spec(spec);spec.loader.exec_module(page)
VARIANTS=('global_packet_ans','global_typed','global_surface','global_joint','global_owner','global_causal_surface','global_causal_joint','global_causal_joint_frequency','global_causal_owner','global_causal_owner_frequency')
def sha(data):return hashlib.sha256(data).hexdigest()
def u32(data,at):return struct.unpack_from('<I',data,at)[0]
def digest(data):return hashlib.sha256(data[:96]+data[128:]).digest()
def read_global(data):
    if len(data)<128 or data[:8]!=b'LGB1\1\0\0\0' or digest(data)!=data[96:128]:raise ValueError('invalid global bundle')
    groups,roots,stride,offset,size,reserved=struct.unpack_from('<6I',data,8)
    if stride!=24 or reserved or data[48:64]!=bytes(16) or groups>(len(data)-128)//24 or offset!=128+24*groups or size!=len(data)-offset:raise ValueError('invalid global directory')
    frame=data[offset:]
    if len(frame)<96 or frame[:4]!=b'LTC1' or frame[4]not in(1,2) or hashlib.sha256(frame[:64]+frame[96:]).digest()!=frame[64:96] or u32(frame,16)!=roots:raise ValueError('invalid shared native frame')
    records=[];ordinal=canonical=rawsum=0
    for i in range(groups):
        first,n,raw,start,end,zero=struct.unpack_from('<6I',data,128+i*24)
        if first!=ordinal or not n or start!=canonical or end<start or zero or raw!=64+4*(n+1)+end-start:raise ValueError('invalid source group')
        records.append((first,n,raw,start,end));ordinal+=n;canonical=end;rawsum+=raw
    if ordinal!=roots or canonical!=u32(frame,52) or struct.unpack_from('<2Q',data,32)!=(rawsum,canonical):raise ValueError('source footprint mismatch')
    model,stock,streams=struct.unpack_from('<3I',frame,28)
    if 96+model+stock+4*(roots+1)+streams!=len(frame):raise ValueError('native section lengths')
    offsets=struct.unpack_from('<'+str(roots+1)+'I',frame,96+model+stock)
    if offsets[0] or offsets[-1]!=streams or any(b-a<4 for a,b in zip(offsets,offsets[1:])):raise ValueError('independent root index')
    return records,frame
def canonical_packets(rawframes,groups):
    result=[]
    for raw,(_,n)in zip(rawframes,groups):
        if raw[:8]!=b'LPD1\1\0\0\0' or u32(raw,8)!=n or u32(raw,12)!=n:raise ValueError('source page contract')
        payload=64+4*(n+1);offsets=struct.unpack_from('<'+str(n+1)+'I',raw,64)
        if offsets[0] or offsets[-1]!=len(raw)-payload:raise ValueError('source packet offsets')
        result.extend(raw[payload+a:payload+b]for a,b in zip(offsets,offsets[1:]))
    return result
def whole_flat(rawframes,groups):
    packets=canonical_packets(rawframes,groups);n=len(packets)
    head=bytearray(64);head[:8]=b'LPD1\1\0\0\0';struct.pack_into('<3I',head,8,n,n,sum(map(len,packets)))
    if rawframes:head[24:32]=rawframes[0][24:32]
    offsets=[0]
    for packet in packets:offsets.append(offsets[-1]+len(packet))
    data=head+struct.pack('<'+str(n+1)+'I',*offsets)+b''.join(packets);data[32:64]=page.frame_digest(data)
    if canonical_packets([data],[(0,n)])!=packets:raise ValueError('whole-flat canonical packet reconstruction')
    return bytes(data)
def whole_control(global_image,raw,codec):
    encoded=codec.encode(raw);compressed=len(encoded)<len(raw);stored=encoded if compressed else raw
    if(codec.decode(stored,len(raw))if compressed else stored)!=raw:raise ValueError('whole control decode')
    groups=u32(global_image,8);at=128+24*groups;data=bytearray(global_image[:at]);data[:8]=b'LGC1'+bytes((1,1 if codec.name=='bzip3'else 2,int(compressed),0))
    struct.pack_into('<I',data,24,len(stored));struct.pack_into('<I',data,28,len(raw));data.extend(stored);data[96:128]=digest(data)
    # The complete framed control is reopened and decoded, not just its trial.
    if digest(data)!=data[96:128] or u32(data,20)!=at or u32(data,24)!=len(data)-at:raise ValueError('whole control envelope')
    restored=codec.decode(bytes(data[at:]),u32(data,28))if data[6]else bytes(data[at:])
    if restored!=raw:raise ValueError('whole control stored decode')
    return bytes(data)
def main():
    p=argparse.ArgumentParser();p.add_argument('flat',type=pathlib.Path);p.add_argument('directory',type=pathlib.Path);p.add_argument('--pages',type=pathlib.Path);p.add_argument('--native-binary',type=pathlib.Path,required=True);p.add_argument('--lexical-core',type=pathlib.Path,required=True);args=p.parse_args()
    if any(s in str(args.flat).lower()for s in('final','holdout')):raise ValueError('heldout tuning forbidden')
    source,rawframes,groups=page.old_bundle(args.flat);source_hash=sha(source)
    native={name:args.directory.joinpath(name+'.lgb').read_bytes()for name in VARIANTS}
    parsed={name:read_global(data)for name,data in native.items()}
    expected=[];canonical=0
    for (first,n),raw in zip(groups,rawframes):
        end=canonical+len(raw)-64-4*(n+1);expected.append((first,n,len(raw),canonical,end));canonical=end
    if any(records!=expected for records,_ in parsed.values())or any(data[64:96].hex()!=source_hash for data in native.values()):raise ValueError('original source group/hash mismatch')
    chosen=min(VARIANTS,key=lambda name:(len(native[name]),VARIANTS.index(name)));args.directory.joinpath('adaptive.lgb').write_bytes(native[chosen])
    ledger={'protocol':'LEXICAL-SHARED-CONSTRUCTION-SCREEN/2','input':str(args.flat),'input_sha256':source_hash,'pages':len(groups),'roots':sum(n for _,n in groups),'variants':{},'controls':{},'timing':False,'selected_global_variant':chosen,'encoder_candidates_paid':len(VARIANTS),'policy':'fixed complete-global-frame minimum; every proposal fully encoded and natively admitted; no name/language rules','access_scope':'independent root ANS streams after entire shared literal stock + models are explicitly prepared and full native/source admission passes; decoded-pool RAM and setup must be included in later access comparisons'}
    raw=whole_flat(rawframes,groups)
    for backend in('bzip3','zstd19'):
        codec=page.Codec(backend)
        matched=page.control(source,groups,rawframes,codec)
        if backend=='bzip3':
            # Controls share literals/models globally too; use an explicitly
            # paid bounded large-block session, not a 1MiB split.
            codec.session=page.flat_controls.Bzip3Session(32*1024*1024,bindings=page.flat_controls._Bzip3Bindings(pathlib.Path('/workspace/scratch/libbzip3.so')))
        whole=whole_control(native[chosen],raw,codec)
        for scope,data,suffix in(('matched_pages',matched,'.lpb'),('whole_flat',whole,'.lgc')):
            args.directory.joinpath('flat.'+scope+'.'+backend+suffix).write_bytes(data)
            ledger['controls'][scope+'/'+backend]={'complete_bytes':len(data),'sha256':sha(data),'access_scope':'one original page decompress'if scope=='matched_pages'else'whole global flat block decompress; no independent compressed roots'}
    for name,data in{**native,'adaptive':native[chosen]}.items():
        ledger['variants'][name]={'complete_bytes':len(data),'sha256':sha(data),'delta_percent':{backend:100*(len(data)/row['complete_bytes']-1)for backend,row in ledger['controls'].items()}}
    if args.pages:
        old=json.loads(args.pages.joinpath('screen.json').read_text())
        if old['input_sha256']!=source_hash:raise ValueError('paged ablation source mismatch')
        ledger['page_stock_ablation']={'evidence':str(args.pages/'screen.json'),'sha256':sha(args.pages.joinpath('screen.json').read_bytes()),'variants':old['variants']}
    dependency_sources={str(path):sha(path.read_bytes())for path in sorted(args.lexical_core.parent.rglob('*.zig'))}
    for path in sorted(HERE.glob('*.zig')):dependency_sources[str(path)]=sha(path.read_bytes())
    for path in(HERE.parent/'lexical_pages'/'dag.zig',HERE.parent/'lexical_pages'/'workloads.zig',HERE.parent/'lexical_columns'/'screen.py',HERE/'screen.py',pathlib.Path(__file__)):
        dependency_sources[str(path)]=sha(path.read_bytes())
    ledger['provenance']={'native_binary':str(args.native_binary),'native_binary_sha256':sha(args.native_binary.read_bytes()),'lexical_core':str(args.lexical_core),'native_contract':'explicit frozen v3 core; generic current-schema tests are a separate source policy','sources_sha256':dependency_sources,'bzip3_library_sha256':sha(pathlib.Path('/workspace/scratch/libbzip3.so').read_bytes()),'zstandard_version':page.flat_controls.zstandard.__version__,'scope':'DEV only; complete actual framed output and exact native/source/projection gates; no timing ranks'}
    args.directory.joinpath('screen.json').write_text(json.dumps(ledger,sort_keys=True,indent=2)+'\n');print(json.dumps(ledger,sort_keys=True))
if __name__=='__main__':main()
