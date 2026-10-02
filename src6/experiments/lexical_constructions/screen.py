#!/usr/bin/env python3
"""DEV complete-frame comparisons; no clocks and no detached entropy estimates.

The native runner has already gated every native field, production packet,
source observation and hot projection for each candidate. This screen retains
actual complete matched flat controls and an actual native adaptive bundle.
"""
from __future__ import annotations
import argparse, hashlib, importlib.util, json, pathlib, struct, sys

HERE = pathlib.Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('lexical_constructions_flat_controls',HERE.parent/'lexical_columns'/'screen.py')
flat_controls=importlib.util.module_from_spec(spec);spec.loader.exec_module(flat_controls)
Codec,old_bundle,frame_digest=flat_controls.Codec,flat_controls.bundle,flat_controls.frame_digest

VARIANTS = ('packet_ans', 'typed', 'surface', 'joint', 'joint_frequency', 'joint_global', 'joint_owner', 'joint_owner_frequency', 'causal_surface', 'causal_joint', 'causal_owner', 'causal_owner_frequency')
def sha(data: bytes) -> str: return hashlib.sha256(data).hexdigest()
def read_ltb(data: bytes):
    if len(data) < 64 or data[:8] != b'LTB1\1\0\0\0' or frame_digest(data) != data[32:64]:
        raise ValueError('invalid complete native bundle')
    pages, roots, stride, reserved = struct.unpack_from('<4I', data, 8)
    if stride != 24 or reserved or pages > (len(data)-64)//24: raise ValueError('invalid directory')
    at, ordinal, records, frames, rawsum = 64+pages*24, 0, [], [], 0
    for i in range(pages):
        first,n,raw,size,offset,zero = struct.unpack_from('<6I',data,64+i*24)
        if first != ordinal or not n or offset != at or zero or size > len(data)-at: raise ValueError('invalid record')
        frame=data[at:at+size]
        if len(frame)<96 or frame[:4]!=b'LTC1' or frame[4]not in(1,2) or sha(frame[:64]+frame[96:])!=frame[64:96].hex(): raise ValueError('invalid native page')
        if struct.unpack_from('<I',frame,16)[0]!=n or raw != 64+4*(n+1)+struct.unpack_from('<I',frame,52)[0]: raise ValueError('root source footprint mismatch')
        records.append((first,n,raw)); frames.append(frame); rawsum+=raw; ordinal+=n;at+=size
    if at!=len(data) or ordinal!=roots or rawsum!=struct.unpack_from('<Q',data,24)[0]:raise ValueError('invalid totals')
    return records, frames
def pack_native(records,frames):
    head=bytearray(64);head[:8]=b'LTB1\1\0\0\0'
    struct.pack_into('<3I',head,8,len(records),sum(n for _,n,_ in records),24)
    struct.pack_into('<Q',head,24,sum(raw for _,_,raw in records))
    directory,payload=bytearray(),bytearray();at=64+24*len(records)
    for (first,n,raw),frame in zip(records,frames):
        directory.extend(struct.pack('<6I',first,n,raw,len(frame),at,0));payload.extend(frame);at+=len(frame)
    out=head+directory+payload;out[32:64]=frame_digest(out)
    read_ltb(out);return bytes(out)
def control(source, groups, rawframes, codec):
    # Faithful LPB1 envelope, paying every actual backend frame and raw fallback.
    out=bytearray(source[:64+24*len(groups)]);at=len(out)
    if codec.name=='bzip3':out[:8]=b'LPB1\2\0\0\0'
    else:out[:8]=b'LZB1\1\0\2\0'
    for i,(raw,group)in enumerate(zip(rawframes,groups)):
        trial=codec.encode(raw);compressed=len(trial)<len(raw);encoded=trial if compressed else raw
        if (codec.decode(encoded,len(raw))if compressed else encoded)!=raw:raise ValueError('control reconstruction')
        row=64+24*i
        struct.pack_into('<5I',out,row,group[0],group[1],len(raw),len(encoded),at)
        out[row+20:row+24]=bytes(((1 if codec.name=='bzip3'else 2)if compressed else 0,0,0,0))
        out.extend(encoded);at+=len(encoded)
    out[32:64]=frame_digest(out);return bytes(out)
def main():
    p=argparse.ArgumentParser();p.add_argument('flat',type=pathlib.Path);p.add_argument('directory',type=pathlib.Path);args=p.parse_args()
    if 'final'in str(args.flat).lower():raise ValueError('FINAL tuning forbidden')
    source,rawframes,groups=old_bundle(args.flat)
    native={name:args.directory.joinpath(name+'.ltb').read_bytes()for name in VARIANTS}
    parsed={name:read_ltb(data)for name,data in native.items()}
    expected=[(f,n,len(raw))for (f,n),raw in zip(groups,rawframes)]
    if any(records!=expected for records,_ in parsed.values()):raise ValueError('source group mismatch')
    chosen=[min(VARIANTS,key=lambda name:(len(parsed[name][1][i]),VARIANTS.index(name)))for i in range(len(groups))]
    adaptive=pack_native(expected,[parsed[name][1][i]for i,name in enumerate(chosen)])
    args.directory.joinpath('adaptive.ltb').write_bytes(adaptive)
    ledger={'protocol':'LEXICAL-DIRECT-GRAMMAR-SCREEN/1','input':str(args.flat),'input_sha256':sha(source),'pages':len(groups),'roots':sum(n for _,n in groups),'variants':{},'controls':{},'timing':False,'selected_pages':{n:chosen.count(n)for n in VARIANTS},'encoder_candidates_paid':len(VARIANTS)*len(groups),'policy':'fixed global complete-frame minimum across all declared representation/order/context candidates; every candidate encoded and admitted; no source-name or language rule'}
    for backend in ('bzip3','zstd19'):
        codec=Codec(backend);data=control(source,groups,rawframes,codec)
        args.directory.joinpath('flat.'+backend+'.lpb').write_bytes(data)
        ledger['controls'][backend]={'complete_bytes':len(data),'sha256':sha(data)}
    for name,data in {**native,'adaptive':adaptive}.items():
        ledger['variants'][name]={'complete_bytes':len(data),'sha256':sha(data),'delta_percent':{backend:100*(len(data)/row['complete_bytes']-1)for backend,row in ledger['controls'].items()}}
    ledger['provenance']={'scope':'DEV only; original native T and production packet/source oracle; direct context rANS rather than generic backend over templates; all framing/models/seek indices paid','python_screen_sha256':sha(pathlib.Path(__file__).read_bytes()),'native_evidence':str(args.directory/'native.jsonl'),'shared_flat_control_module':str(HERE.parent/'lexical_columns'/'screen.py'),'shared_flat_control_sha256':sha((HERE.parent/'lexical_columns'/'screen.py').read_bytes())}
    args.directory.joinpath('screen.json').write_text(json.dumps(ledger,sort_keys=True,indent=2)+'\n')
    print(json.dumps(ledger,sort_keys=True))
if __name__=='__main__':main()
