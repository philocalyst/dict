#!/usr/bin/env python3
"""Compose exact construction-prefix packets with paid generic XML registers.

The dictionary representation and authoritative native model are unchanged.
Independent cold packet byte streams use a reversible lexical construction
transform before the same bzip3/zstd controls. All block headers, operands,
original/transformed sizes, checksums and ordinal frame costs are charged.
"""
import argparse,json,pathlib,struct,sys,time
from prefix_screen import transform,restore_raw
from screen import bundle,Codec,frame_digest,sha,MAX_PAGE,pack_bundle
ROOT=pathlib.Path(__file__).resolve().parents[1]/'word_constructions'
sys.path.insert(0,str(ROOT))
import attribute_register,scope_register

class Ledger:
    """Optional clocks; verification and retained evidence are never encoder work."""
    def __init__(self, enabled=False):
        self.enabled=enabled;self.ns={};self.calls={}
    def call(self, phase, fn, *args):
        if not self.enabled:return fn(*args)
        start=time.perf_counter_ns()
        result=fn(*args)
        self.ns[phase]=self.ns.get(phase,0)+time.perf_counter_ns()-start
        self.calls[phase]=self.calls.get(phase,0)+1
        return result

def forward(cold,mode):
    if mode==0:return cold,{'literal':True}
    stage,stats=attribute_register.forward(cold)
    if mode==2:
        stage,scoped=scope_register.forward(stage);stats={'attribute':stats,'scope':scoped}
    return stage,stats

def inverse(transformed,mode):
    if mode==0:return transformed
    if mode==2:transformed=scope_register.inverse(transformed)
    return attribute_register.inverse(transformed)

def encode(raw,hot,cold,mode,codec,ledger=None):
    ledger=ledger or Ledger()
    candidate_start=time.perf_counter_ns()if ledger.enabled else 0
    previous_verification_ns=ledger.ns.get('verification_inverse',0)
    transformed,stats=ledger.call('constructor_forward',forward,cold,mode)
    assert ledger.call('verification_inverse',inverse,transformed,mode)==cold
    constructor = mode != 0 and len(transformed) <= 131072 and len(cold) <= 262144
    if not constructor:
        transformed=cold
    hottrial=ledger.call('hot_backend_encode',codec.encode,hot)
    hotencoded,hottag=(hottrial,1 if codec.name=='bzip3'else 2)if len(hottrial)<len(hot)else(hot,0)
    trial=ledger.call('cold_backend_encode',codec.encode,transformed)
    cold_trial=(struct.pack('<I',len(transformed))+trial)if constructor else trial
    coldencoded,coldtag=(cold_trial,(0x80 if constructor else 0)|(1 if codec.name=='bzip3'else 2))if len(cold_trial)<len(cold)else(cold,0)
    head=b'LCP2'+bytes([1,mode,1 if codec.name=='bzip3'else 2,0])+struct.pack('<II',2,len(raw))+raw[:64]
    dirs=struct.pack('<III4B',len(hot),len(hotencoded),112,hottag,0,0,0)+struct.pack('<III4B',len(cold),len(coldencoded),112+len(hotencoded),coldtag,0,0,0)
    result=head+dirs+hotencoded+coldencoded
    if ledger.enabled:
        verification_ns=ledger.ns.get('verification_inverse',0)-previous_verification_ns
        ledger.ns['candidate_pipeline']=ledger.ns.get('candidate_pipeline',0)+time.perf_counter_ns()-candidate_start-verification_ns
        ledger.calls['candidate_pipeline']=ledger.calls.get('candidate_pipeline',0)+1
    assert ledger.call('verification_candidate_decode',decode,result,codec)==raw
    return result,len(transformed),stats

def decode(data,codec):
    assert len(data)>=112 and data[:5]==b'LCP2\x01'and data[5]in(0,1,2)and data[6]==(1 if codec.name=='bzip3'else 2)and data[7]==0
    count,total=struct.unpack_from('<II',data,8);assert count==2 and 64<=total<=MAX_PAGE
    at,blocks=112,[]
    for i in range(2):
        raw,stored,offset,tag,a,b,c=struct.unpack_from('<III4B',data,80+16*i)
        assert not(a|b|c)and offset==at and raw<=total and stored<=len(data)-at
        encoded=data[at:at+stored];at+=stored
        if tag&0x80:
            assert i==1 and data[5]!=0 and tag&0x7f==data[6]and len(encoded)>=4
            intermediate=struct.unpack_from('<I',encoded)[0];assert intermediate<=2*MAX_PAGE
            decoded=inverse(codec.decode(encoded[4:],intermediate),data[5])
        else:
            assert tag==0 or tag==data[6]
            decoded=codec.decode(encoded,raw)if tag else encoded
        assert len(decoded)==raw;blocks.append(decoded)
    result=data[16:80]+b''.join(blocks)
    assert at==len(data)and len(result)==total and frame_digest(result)==result[32:64]
    return result

def main():
    p=argparse.ArgumentParser();p.add_argument('flat',type=pathlib.Path);p.add_argument('--retain-directory',type=pathlib.Path);p.add_argument('--quiet-gate',choices=['ROOT-EXPLICIT-QUIET-GATE']);args=p.parse_args()
    source,frames,groups=bundle(args.flat);transformed=[transform(f)for f in frames];overhead=64+24*len(groups)
    for backend in('bzip3','zstd19'):
        ledger=Ledger(args.quiet_gate is not None)
        codec=ledger.call('backend_initialization',Codec,backend)
        baseline=sum(len(ledger.call('flat_baseline_encode',codec.encode,f))for f in frames)+overhead
        all_encoded={}
        for mode in(0,1,2):
            encoded=[encode(*p,mode,codec,ledger)for p in transformed]
            all_encoded[mode]=encoded
            assert all(restore_raw(decode(e[0],codec))==f for e,f in zip(encoded,frames))
            total=overhead+sum(len(e[0])for e in encoded)
            print(json.dumps({'representation':'root_prefix_with_exact_literal_register','construction_mode':('literal','attribute','attribute_scope')[mode],'backend':backend,'complete_bytes':total,'flat_complete_bytes':baseline,'delta_percent':100*(total/baseline-1),'pages':len(groups),'roots':sum(g[1]for g in groups),'headword_hot_decoded_bytes_all_pages':sum(len(p[1])for p in transformed),'actual_intermediate_bytes':sum(e[1]for e in encoded),'original_cold_bytes':sum(len(p[2])for p in transformed),'outer_framing_bytes':overhead,'routing_directory_bytes':112*len(groups),'transformed_length_operand_bytes':sum(4 for e in encoded if e[0][108]&0x80),'gate':'all constructor inverses exact; every independently compressed block exact; restored original admitted native packet/frame SHA exact','timing':False},sort_keys=True))
            if args.retain_directory:
                args.retain_directory.mkdir(parents=True,exist_ok=True)
                for i,encodedpage in enumerate(encoded):
                    (args.retain_directory/f'register{mode}.{backend}.{i:05d}.lcp').write_bytes(encodedpage[0])
                    raw,hot,cold=transformed[i];stage,stats=forward(cold,mode)
                    (args.retain_directory/f'register{mode}.{i:05d}.stage.raw').write_bytes(stage)
                    (args.retain_directory/f'register{mode}.{i:05d}.stats.json').write_text(json.dumps(stats,sort_keys=True)+'\n')
                stored=pack_bundle(source,groups,[p[0]for p in transformed],[e[0]for e in encoded],5+mode,backend);assert len(stored)==total
                (args.retain_directory/f'register{mode}.{backend}.lcb').write_bytes(stored)
        choices=ledger.call('selection',lambda:[min(range(3),key=lambda m:(len(all_encoded[m][i][0]),m))for i in range(len(groups))])
        selected=[all_encoded[m][i]for i,m in enumerate(choices)]
        total=overhead+sum(len(e[0])for e in selected)
        print(json.dumps({'representation':'root_prefix_register_adaptive','backend':backend,'complete_bytes':total,'flat_complete_bytes':baseline,'delta_percent':100*(total/baseline-1),'pages':len(groups),'roots':sum(g[1]for g in groups),'choices':{('literal','attribute','attribute_scope')[m]:choices.count(m)for m in range(3)},'construction_encoding_trials_paid':3*len(groups),'hot_backend_encodes_paid':3*len(groups),'headword_hot_decoded_bytes_all_pages':sum(len(p[1])for p in transformed),'policy':'fixed global minimum actual complete frame among literal/attribute/attribute_scope cold representations; deterministic lower mode on ties; no corpus-specific hyperparameters','gate':'every candidate full native canonical packet frame restored exactly; selected same complete header/directory/operand costs','timing':False},sort_keys=True))
        if args.retain_directory:
            for i,e in enumerate(selected):(args.retain_directory/f'register_adaptive.{backend}.{i:05d}.lcp').write_bytes(e[0])
            stored=pack_bundle(source,groups,[p[0]for p in transformed],[e[0]for e in selected],8,backend)
            assert len(stored)==total
            (args.retain_directory/f'register_adaptive.{backend}.lcb').write_bytes(stored)
        if ledger.enabled:
            paid=sum(ledger.ns.get(k,0)for k in('candidate_pipeline','selection'))
            print(json.dumps({'protocol':'LEXICAL-REGISTER-ENCODING-TIME/1','backend':backend,'paid_candidate_and_selection_ns':paid,'phase_ns':ledger.ns,'phase_calls':ledger.calls,'construction_encoding_trials_paid':3*len(groups),'scope':'candidate_pipeline includes all three constructor forward trials, all hot/cold backend trials, fallback decisions and complete per-page frame assembly; named forward/backend phases are subsets of candidate_pipeline; verification, evidence IO, root-prefix preparation and process startup excluded; backend initialization separate; no persistent learned model','quiet_gate':True},sort_keys=True))
    print(json.dumps({'provenance':{'source':str(args.flat),'source_sha256':sha(source),'script_sha256':sha(pathlib.Path(__file__).read_bytes()),'attribute_forward_sha256':sha((ROOT/'attribute_register.py').read_bytes()),'scope_forward_sha256':sha((ROOT/'scope_register.py').read_bytes()),'scope':'exact same native root groups; generic tag-like record/literal construction ops only; no external dictionary/inferred language/presentation rewrite; ordinal envelope only; no timing claims'}},sort_keys=True))
if __name__=='__main__':main()
