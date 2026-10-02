#!/usr/bin/env python3
"""Complete framed cost oracle for admitted reflected cursor-lane pages.

The exact existing LPB1 ordinal groups are retained. Independent blocks are
actually encoded, decoded and compared. Empty/raw blocks are charged exactly;
all root checkpoints, schema markers, SHA256s and routing metadata are paid.
No timing claims are made while other frontier workers are running.
"""
from __future__ import annotations
import argparse, hashlib, json, pathlib, struct, sys
import zstandard
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'bzip4' / 'frontier_python'))
from protocol.native_bzip3 import Bzip3Session, _Bzip3Bindings

MAX_PAGE = 1024 * 1024

def sha(data): return hashlib.sha256(data).hexdigest()
def u32(data, at): return struct.unpack_from('<I', data, at)[0]
def frame_digest(data): return hashlib.sha256(data[:32] + data[64:]).digest()

def bundle(path):
    data = path.read_bytes()
    assert len(data) >= 64 and data[:5] == b'LPB1\x02' and u32(data, 16) == 24
    assert frame_digest(data) == data[32:64]
    pages, roots = u32(data, 8), u32(data, 12)
    assert pages <= (len(data)-64)//24
    at, next_root, result, groups = 64 + pages*24, 0, [], []
    for i in range(pages):
        first,count,raw,stored,offset = struct.unpack_from('<5I', data, 64+i*24)
        assert first == next_root and offset == at and raw == stored and data[64+i*24+20:64+i*24+24] == bytes(4)
        assert stored <= min(MAX_PAGE, len(data)-at)
        frame = data[at:at+stored]
        assert frame_digest(frame) == frame[32:64]
        result.append(frame); groups.append((first,count)); at += stored; next_root += count
    assert at == len(data) and next_root == roots
    return data, result, groups

def sections(frame):
    assert frame[:6] == b'LPC1\x01\x03'
    roots,n,skeleton,total = struct.unpack_from('<4I',frame,8)
    assert n == 4 and total == len(frame)
    lengths_at = 64 + (roots+1)*(n+1)*4
    lengths = struct.unpack_from('<4I',frame,lengths_at)
    lane_at = lengths_at+n*4+skeleton
    metadata = frame[64:lane_at]
    at, lanes = lane_at, []
    for length in lengths:
        lanes.append(frame[at:at+length]); at += length
    assert at == len(frame)
    return metadata, lanes

class Codec:
    def __init__(self, name):
        self.name = name
        if name == 'zstd19':
            self.encoder = zstandard.ZstdCompressor(level=19)
            self.decoder = zstandard.ZstdDecompressor()
        else:
            self.session = Bzip3Session(MAX_PAGE, bindings=_Bzip3Bindings(pathlib.Path('/workspace/scratch/libbzip3.so')))
    def encode(self, data):
        if not data: return b''
        return self.encoder.compress(data) if self.name == 'zstd19' else self.session.encode_block(data)
    def decode(self, data, raw):
        if not raw: assert not data; return b''
        return self.decoder.decompress(data, max_output_size=raw) if self.name == 'zstd19' else self.session.decode_block(data, raw)

# LCC1: 16B routing header + exact64B original schema/checksum header;
# 16B block directory + encoded payload for every actual restart block.
def container(frame, grouping, codec):
    metadata, lanes = sections(frame)
    if grouping == 'independent': blocks = [metadata, *lanes]; mode = 0
    elif grouping == 'hot_cold': blocks = [metadata + lanes[0] + lanes[2] + lanes[3], lanes[1]]; mode = 1
    else: raise ValueError(grouping)
    header = b'LCC1'+bytes([1,mode,0,0])+struct.pack('<II',len(blocks),len(frame))+frame[:64]
    directory, payload, chosen = bytearray(), bytearray(), []
    for raw in blocks:
        trial = codec.encode(raw)
        encoded, tag = (trial, 1 if codec.name == 'bzip3' else 2) if len(trial)<len(raw) else (raw,0)
        assert (codec.decode(encoded,len(raw)) if tag else encoded) == raw
        directory.extend(struct.pack('<III4B',len(raw),len(encoded),len(header)+len(blocks)*16+len(payload),tag,0,0,0))
        payload.extend(encoded); chosen.append(tag)
    result = header+directory+payload
    assert restore(result, codec) == frame
    return result, [len(b) for b in blocks], chosen

def restore(data, codec):
    assert len(data)>=80 and data[:5] == b'LCC1\x01' and data[5] in (0,1) and data[6:8] == bytes(2)
    count,total = struct.unpack_from('<II',data,8)
    assert count == (5 if data[5] == 0 else 2) and total <= MAX_PAGE
    assert count <= (len(data)-80)//16
    at, blocks = 80+count*16, []
    for i in range(count):
        raw,stored,offset,tag,r1,r2,r3 = struct.unpack_from('<III4B',data,80+i*16)
        assert not (r1|r2|r3) and tag in (0,1,2) and offset == at
        assert tag == 0 or tag == (1 if codec.name == 'bzip3' else 2)
        assert raw<=total and stored<=len(data)-at
        encoded=data[at:at+stored];at+=stored
        blocks.append(codec.decode(encoded,raw) if tag else encoded)
        assert len(blocks[-1]) == raw
    assert at == len(data)
    if data[5] == 0: result=data[16:80]+b''.join(blocks)
    else:
        roots,n,skeleton,_ = struct.unpack_from('<4I',data,16+8)
        metadata_bytes=(roots+1)*(n+1)*4+n*4+skeleton
        lengths=struct.unpack_from('<4I',blocks[0],(roots+1)*(n+1)*4)
        assert len(blocks[0]) == metadata_bytes+lengths[0]+lengths[2]+lengths[3] and len(blocks[1])==lengths[1]
        hot=blocks[0]
        result=data[16:80]+hot[:metadata_bytes+lengths[0]]+blocks[1]+hot[metadata_bytes+lengths[0]:]
    assert len(result)==total and frame_digest(result)==result[32:64]
    return result

def pack_bundle(source, groups, raw_frames, stored_frames, mode, backend):
    """LCB1 pays the same64B ordinal envelope and24B/page directories."""
    out = bytearray(source[:64 + 24*len(groups)])
    out[:8] = b'LCB1' + bytes([1, mode, 1 if backend == 'bzip3' else 2, 0])
    struct.pack_into('<Q', out, 24, sum(map(len, raw_frames)))
    for i, (group, raw, stored) in enumerate(zip(groups, raw_frames, stored_frames)):
        struct.pack_into('<5I4B', out, 64+i*24, group[0], group[1], len(raw), len(stored), len(out), mode, 0, 0, 0)
        out.extend(stored)
    out[32:64] = frame_digest(out)
    assert len(out) == 64+24*len(groups)+sum(map(len,stored_frames))
    return bytes(out)

def verify_stored_bundle(data, expected, codec, mode):
    assert data[:4] == b'LCB1' and data[4] == 1 and data[5] == mode and data[7] == 0
    assert frame_digest(data) == data[32:64]
    pages, roots = u32(data,8),u32(data,12)
    assert pages == len(expected) and pages <= (len(data)-64)//24
    at, first = 64+24*pages, 0
    for i, original in enumerate(expected):
        start,count,raw,stored,offset,tag,a,b,c = struct.unpack_from('<5I4B',data,64+i*24)
        assert start == first and offset == at and raw == len(original) and tag == mode and not(a|b|c)
        assert stored <= len(data)-at
        payload=data[at:at+stored]
        restored=restore(payload,codec) if mode in (2,3) else codec.decode(payload,raw)
        assert restored==original
        at+=stored;first+=count
    assert at==len(data) and first==roots

def main():
    p=argparse.ArgumentParser();p.add_argument('flat',type=pathlib.Path);p.add_argument('columns',type=pathlib.Path);p.add_argument('--retain-directory',type=pathlib.Path);args=p.parse_args()
    flat_raw, flat, groups=bundle(args.flat);col_raw,cols,colgroups=bundle(args.columns);assert groups==colgroups
    overhead=64+24*len(groups)
    all_records=[]
    for backend in ('bzip3','zstd19'):
        codec=Codec(backend)
        comparisons={}
        for name, frames in [('flat',flat),('columns_whole',cols)]:
            encoded=[codec.encode(f) for f in frames]
            assert all(codec.decode(c,len(f))==f for f,c in zip(frames,encoded))
            comparisons[name]=sum(map(len,encoded))+overhead
            if args.retain_directory:
                args.retain_directory.mkdir(parents=True,exist_ok=True)
                stored_bundle=pack_bundle(flat_raw,groups,frames,encoded,0 if name=='flat' else 1,backend)
                verify_stored_bundle(stored_bundle,frames,codec,0 if name=='flat' else 1)
                (args.retain_directory/f'{name}.{backend}.lcb').write_bytes(stored_bundle)
            print(json.dumps({'representation':name,'backend':backend,'complete_bytes':comparisons[name],'pages':len(groups),'roots':sum(g[1] for g in groups),'block_count':len(groups),'max_decoded_frame':max(map(len,frames)),'gate':'every exact compressed full frame','timing':False},sort_keys=True))
        for name in ('independent','hot_cold'):
            enc=[container(f,name,codec) for f in cols]
            comparisons[name]=sum(len(e[0]) for e in enc)+overhead
            accesses={}
            for query, indices in [('headword',[0,4] if name=='independent' else [0]),('rich_headword_first_sense_label',[0,1,4] if name=='independent' else [0]),('natural_headword_preserved_definition',[0,1,2,4] if name=='independent' else [0,1])]:
                accesses[query]={'total_decoded_block_bytes_all_pages':sum(sum(e[1][i] for i in indices) for e in enc),'max_decoded_block_bytes_per_page':max(sum(e[1][i] for i in indices) for e in enc),'max_native_decoder_calls_per_page':max(sum(e[2][i]!=0 for i in indices) for e in enc),'scope':'mechanical necessary stream-volume bound, not timing; metadata read includes all root checkpoints'}
            record={'representation':name,'backend':backend,'complete_bytes':comparisons[name],'delta_vs_flat_percent':100*(comparisons[name]/comparisons['flat']-1),'pages':len(groups),'roots':sum(g[1] for g in groups),'block_count':sum(len(e[1]) for e in enc),'routing_header_directory_bytes':sum(80+16*len(e[1]) for e in enc),'accesses':accesses,'gate':'all restart blocks exact; each complete restored original admitted columns frame digest exact','timing':False}
            print(json.dumps(record,sort_keys=True));all_records.append(record)
            if args.retain_directory:
                args.retain_directory.mkdir(parents=True,exist_ok=True)
                stored_bundle=pack_bundle(flat_raw,groups,cols,[e[0] for e in enc],2 if name=='independent' else 3,backend)
                verify_stored_bundle(stored_bundle,cols,codec,2 if name=='independent' else 3)
                assert len(stored_bundle)==comparisons[name]
                (args.retain_directory/f'{name}.{backend}.lcb').write_bytes(stored_bundle)
                for i,(data,_,_) in enumerate(enc):(args.retain_directory/f'{name}.{backend}.{i:05d}.lcc').write_bytes(data)
    print(json.dumps({'provenance':{'flat_bundle':str(args.flat),'flat_sha256':sha(flat_raw),'columns_bundle':str(args.columns),'columns_sha256':sha(col_raw),'script_sha256':sha(pathlib.Path(__file__).read_bytes()),'zstd_python':zstandard.__version__,'bzip3_library_sha256':sha(pathlib.Path('/workspace/scratch/libbzip3.so').read_bytes()),'selection':'no size tuning; threshold from columns header; identical fixed native root groups; actual independently compressed framed costs','scope':'ordinal page bundle, no lexical/identity indexes; complete representation/routing/checksum bytes charged; no timings'}},sort_keys=True))
if __name__=='__main__':main()
