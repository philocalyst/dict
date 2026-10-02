#!/usr/bin/env python3
"""Exact construction-prefix cuts; nested cold packets retain byte adjacency.

This input-specific cost oracle cuts the first two reflected Entry byte fields.
Both full restored native canonical packets and source frame SHA are unchanged.
Native reflection implementation verifies these boundaries before admission.
"""
from __future__ import annotations
import argparse, json, pathlib, struct
from screen import bundle, Codec, sha, frame_digest, MAX_PAGE, pack_bundle

def varint(data,at):
    value=0
    for i in range(10):
        byte=data[at];at+=1
        assert i!=9 or byte<=1
        value|=(byte&127)<<(i*7)
        if byte<128:
            assert i==0 or byte!=0
            return value,at
    raise AssertionError('integer overflow')

def transform(frame):
    assert frame[:6]==b'LPD1\x01\x00'
    count=struct.unpack_from('<I',frame,8)[0]
    payload=64+(count+1)*4
    prefixes,cold,offsets=bytearray(),bytearray(),[]
    for i in range(count):
        start,end=struct.unpack_from('<II',frame,64+i*4)
        packet=frame[payload+start:payload+end]
        assert packet[:5]==b'LXP6\x03'
        # Canonical v3 begins with the reflected Entry declared-default mask.
        _,at=varint(packet,5)
        for field in range(2):
            length,at=varint(packet,at)
            assert length<=len(packet)-at
            at+=length
        offsets.append((len(cold),len(prefixes)))
        prefixes.extend(packet[5:at]);cold.extend(packet[at:])
    offsets.append((len(cold),len(prefixes)))
    header=bytearray(frame[:64]);header[:8]=b'LPP1\x01\x03\x02\x00'
    struct.pack_into('<III',header,12,2,len(cold),64+8*(count+1)+len(prefixes)+len(cold))
    raw=header+b''.join(struct.pack('<II',*o) for o in offsets)+prefixes+cold
    raw[32:64]=frame_digest(raw)
    assert restore_raw(raw)==frame
    return bytes(raw),bytes(raw[64:64+8*(count+1)]+prefixes),bytes(cold)

def restore_raw(raw):
    assert raw[:8]==b'LPP1\x01\x03\x02\x00' and frame_digest(raw)==raw[32:64]
    count,lanes,cold,total=struct.unpack_from('<4I',raw,8)
    assert lanes==2 and total==len(raw)
    prefix_at=64+8*(count+1);cold_at=len(raw)-cold
    packets=[]
    for i in range(count):
        c,h=struct.unpack_from('<II',raw,64+i*8);nc,nh=struct.unpack_from('<II',raw,64+(i+1)*8)
        assert c<=nc<=cold and h<=nh<=cold_at-prefix_at
        packet=b'LXP6\x03'+raw[prefix_at+h:prefix_at+nh]+raw[cold_at+c:cold_at+nc]
        packets.append(packet)
    header=bytearray(raw[:64]);header[:8]=b'LPD1\x01\x00\x00\x00';struct.pack_into('<III',header,12,count,sum(map(len,packets)),0)
    offsets=[];at=0
    for packet in packets:offsets.append(at);at+=len(packet)
    offsets.append(at)
    frame=header+b''.join(struct.pack('<I',o) for o in offsets)+b''.join(packets)
    frame[32:64]=frame_digest(frame)
    return bytes(frame)

def container(raw,hot,cold,codec):
    header=b'LCP1\x01\x00\x00\x00'+struct.pack('<II',2,len(raw))+raw[:64]
    directory,payload=bytearray(),bytearray()
    for block in (hot,cold):
        trial=codec.encode(block)
        encoded,tag=(trial,1 if codec.name=='bzip3'else 2) if len(trial)<len(block) else(block,0)
        assert(codec.decode(encoded,len(block))if tag else encoded)==block
        directory.extend(struct.pack('<III4B',len(block),len(encoded),112+len(payload),tag,0,0,0));payload.extend(encoded)
    data=header+directory+payload
    assert restore(data,codec)==raw
    return data

def restore(data,codec):
    assert len(data)>=112 and data[:8]==b'LCP1\x01\x00\x00\x00'
    count,total=struct.unpack_from('<II',data,8);assert count==2 and total<=MAX_PAGE
    at,blocks=112,[]
    for i in range(count):
        raw,stored,offset,tag,a,b,c=struct.unpack_from('<III4B',data,80+16*i)
        assert not(a|b|c)and tag in(0,1,2)and offset==at and raw<=total and stored<=len(data)-at
        assert tag==0 or tag==(1 if codec.name=='bzip3'else 2)
        block=data[at:at+stored];at+=stored
        decoded=codec.decode(block,raw)if tag else block;assert len(decoded)==raw
        blocks.append(decoded)
    raw=data[16:80]+b''.join(blocks)
    assert at==len(data)and len(raw)==total and frame_digest(raw)==raw[32:64]
    return raw

def main():
    p=argparse.ArgumentParser();p.add_argument('flat',type=pathlib.Path);p.add_argument('--retain-directory',type=pathlib.Path);args=p.parse_args()
    source,frames,groups=bundle(args.flat);overhead=64+24*len(groups)
    transformed=[transform(f)for f in frames]
    for backend in('bzip3','zstd19'):
        codec=Codec(backend)
        baseline=[codec.encode(f)for f in frames]
        encoded=[container(*parts,codec)for parts in transformed]
        for f,c in zip(frames,encoded):assert restore_raw(restore(c,codec))==f
        total=overhead+sum(map(len,encoded));flat_total=overhead+sum(map(len,baseline))
        record={'representation':'root_construction_prefix','backend':backend,'complete_bytes':total,'flat_complete_bytes':flat_total,'delta_percent':100*(total/flat_total-1),'pages':len(groups),'roots':sum(g[1]for g in groups),'headword_hot_decoded_bytes_all_pages':sum(len(t[1])for t in transformed),'baseline_decoded_bytes_all_pages':sum(map(len,frames)),'decoded_headword_work_reduction':sum(map(len,frames))/sum(len(t[1])for t in transformed),'max_hot_decoded_bytes':max(len(t[1])for t in transformed),'max_full_decoded_bytes':max(len(t[1])+len(t[2])for t in transformed),'header_restart_directory_bytes':112*len(groups),'gate':'every exact native Entry packet and complete original admitted source frame unchanged; independently compressed blocks restored SHA exact','timing':False}
        print(json.dumps(record,sort_keys=True))
        if args.retain_directory:
            args.retain_directory.mkdir(parents=True,exist_ok=True)
            for i,c in enumerate(encoded):(args.retain_directory/f'prefix.{backend}.{i:05d}.lcp').write_bytes(c)
            for i,(raw,hot,cold) in enumerate(transformed):
                (args.retain_directory/f'prefix.{i:05d}.raw.lpp').write_bytes(raw)
                (args.retain_directory/f'prefix.{i:05d}.hot.raw').write_bytes(hot)
                (args.retain_directory/f'prefix.{i:05d}.cold.raw').write_bytes(cold)
            stored=pack_bundle(source,groups,[t[0]for t in transformed],encoded,4,backend)
            assert len(stored)==total
            (args.retain_directory/f'prefix.{backend}.lcb').write_bytes(stored)
    print(json.dumps({'provenance':{'source':str(args.flat),'source_sha256':sha(source),'script_sha256':sha(pathlib.Path(__file__).read_bytes()),'scope':'same fixed full native root groups; complete64B ordinal header and24B/page directory paid; no lexical/identity indexes; cut operation from native root fields, exact all nested bytes retained'}},sort_keys=True))
if __name__=='__main__':main()
