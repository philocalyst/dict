"""Charged static binary grammar with topology-derived predictive edges.

Research wire only. Floating forward posterior is not a portable integer
specification. The grammar is delivered; there is no external teacher.
"""
from __future__ import annotations
import argparse, hashlib, math, struct, sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'segmentation'))
from weighted_emission_coder import ArithmeticEncoder, ArithmeticDecoder, varint, read_varint, quantized_byte_cdf

MAX_RAW = 1 << 20
MAX_RULES = 1024
MAX_LENGTH = 256
MAGIC = b'GSG1'

def fit(data: bytes, rules: int = 192, min_count: int = 3, *, return_sequence=False):
    if len(data)>MAX_RAW: raise ValueError('training size bounds')
    if not 0 <= rules <= MAX_RULES: raise ValueError('rules out of bounds')
    tokens = [bytes([b]) for b in range(256)]
    counts = [data.count(bytes([b])) + 1 for b in range(256)]
    seq = list(data); grammar = []
    for _ in range(rules):
        pairs = Counter(zip(seq, seq[1:]))
        candidates = [(n, a, b) for (a,b),n in pairs.items() if n >= min_count and len(tokens[a])+len(tokens[b]) <= MAX_LENGTH]
        if not candidates: break
        n,a,b = max(candidates, key=lambda x:(x[0],-x[1],-x[2]))
        token = tokens[a]+tokens[b]
        if token in tokens: break
        idx = len(tokens); tokens.append(token); counts.append(n)
        grammar.append((a,b,n)); out=[]; p=0
        while p < len(seq):
            if p+1 < len(seq) and seq[p]==a and seq[p+1]==b: out.append(idx); p+=2
            else: out.append(seq[p]); p+=1
        seq=out
    return (counts[:256], grammar,seq) if return_sequence else (counts[:256],grammar)

class Model:
    def __init__(self, literals, grammar, boundary=0, strength=4, *, root_edges=(), topology=0):
        if boundary not in (0,1,2) or strength not in (0,4,7): raise ValueError('unsupported policy')
        if len(literals)!=256 or len(grammar)>MAX_RULES: raise ValueError('model bounds')
        self.boundary=boundary; self.strength=strength; self.grammar=list(grammar)
        self.root_edges=list(root_edges); self.topology=topology
        if topology not in (0,1,2) or len(root_edges)>4096: raise ValueError('topology bounds')
        self.tokens=[bytes([b]) for b in range(256)]; self.counts=list(literals)
        self.right=list(range(256))
        for a,b,n in grammar:
            if not 0 <= a < len(self.tokens) or not 0 <= b < len(self.tokens) or not 0 < n <= MAX_RAW: raise ValueError('bad grammar reference/count')
            token=self.tokens[a]+self.tokens[b]
            if len(token)>MAX_LENGTH: raise ValueError('expansion bound')
            self.tokens.append(token); self.counts.append(n); self.right.append(self.right[b])
        if any(not 0 < n <= MAX_RAW+1 for n in self.counts): raise ValueError('frequency bounds')
        self.keys=[self.key(i) for i in range(len(self.tokens))]
        edges=defaultdict(Counter)
        for a,b,n in grammar:
            if topology==1: continue
            edges[self.key(a)][b]+=n
            if boundary==1:
                # Legacy grid control deliberately depth-weights the shared
                # last-byte context; ancestors are not distinct contexts.
                while a>=256:
                    a=grammar[a-256][1]; edges[self.key(a)][b]+=n
        for a,b,n in root_edges:
            if not 0<=a<len(self.tokens) or not 0<=b<len(self.tokens) or not 0<n<=MAX_RAW: raise ValueError('root edge bounds')
            edges[self.key(a)][b]+=n
        self.edges={k:{i:n/sum(row.values()) for i,n in sorted(row.items())} for k,row in edges.items()}
        total=sum(self.counts); self.base=[n/total for n in self.counts]
        self.by_first=defaultdict(list)
        for i,t in enumerate(self.tokens): self.by_first[t[0]].append(i)
        self.base_bytes=[0.0]*256
        for i,p in enumerate(self.base): self.base_bytes[self.tokens[i][0]]+=p
    def key(self,i):
        if self.boundary==0: return i
        if self.boundary==1: return self.right[i]
        return int.from_bytes(self.tokens[i][-2:], 'big')+65536*(len(self.tokens[i][-2:])==2)
    def row(self,k):
        e=self.edges.get(k); alpha=self.strength/8 if e else 0
        row=[(1-alpha)*p for p in self.base]
        if e:
            for i,p in e.items(): row[i]+=alpha*p
        return row
    def initial(self): return ({-1:1.0},{})
    def predictions(self,state):
        roots,active=state; starts=defaultdict(float); common=0.0
        for k,m in roots.items():
            e=self.edges.get(k); alpha=self.strength/8 if e else 0
            common+=m*(1-alpha)
            if e:
                for i,p in e.items(): starts[i]+=m*alpha*p
        probs=[common*p for p in self.base_bytes]
        for i,m in starts.items(): probs[self.tokens[i][0]]+=m
        for (suffix,dst),m in active.items(): probs[suffix[0]]+=m
        return probs,(common,starts)
    def advance(self,state,byte,starts=None):
        if starts is None: _,starts=self.predictions(state)
        roots=defaultdict(float); active=defaultdict(float)
        def add(suffix,dst,m):
            if len(suffix)==1: roots[dst]+=m
            else: active[(suffix[1:],dst)]+=m
        common,special=starts
        for i in self.by_first[byte]:
            m=common*self.base[i]+special.get(i,0.0)
            add(self.tokens[i],self.keys[i],m)
        for (suffix,dst),m in state[1].items():
            if suffix[0]==byte: add(suffix,dst,m)
        z=sum(roots.values())+sum(active.values())
        if z<=0: raise ValueError('zero posterior')
        return ({k:m/z for k,m in sorted(roots.items())},{k:m/z for k,m in sorted(active.items())})

def header(n,model,mode):
    out=bytearray(b'GSG2'+bytes([mode,model.boundary,model.strength]))
    out+=varint(n)+varint(len(model.grammar))
    for count in model.counts[:256]: out+=varint(count)
    for a,b,count in model.grammar: out+=varint(a)+varint(b)+varint(count)
    out.append(model.topology); out+=varint(len(model.root_edges))
    for a,b,count in model.root_edges: out+=varint(a)+varint(b)+varint(count)
    return bytes(out)

def encode_model(raw,model,mode=1):
    if len(raw)>MAX_RAW or mode not in (0,1): raise ValueError('encode bounds')
    enc=ArithmeticEncoder(); bits=0.; peak=0; path=[]
    if mode:
        state=model.initial()
        for byte in raw:
            probs,starts=model.predictions(state)
            if abs(sum(probs)-1)>1e-9: raise AssertionError('normalization')
            bits-=math.log2(probs[byte]); enc.put(byte,quantized_byte_cdf(probs))
            state=model.advance(state,byte,starts); peak=max(peak,len(state[0])+len(state[1]))
    else:
        pos=0; k=-1
        while pos<len(raw):
            row=model.row(k); matches=[]
            for i in model.by_first[raw[pos]]:
                token=model.tokens[i]; size=min(len(token),len(raw)-pos)
                if raw[pos:pos+size]==token[:size]: matches.append(((-math.log2(row[i]))/size,i,size))
            _,i,size=min(matches); enc.put(i,[max(1,round(p*(1<<20))) for p in row])
            bits-=math.log2(row[i]); pos+=size; k=model.keys[i]; path.append(i)
    payload=enc.finish(); h=header(len(raw),model,mode)
    framing=(varint(len(path)) if mode==0 else b'')+varint(len(payload))
    frame=h+framing+payload
    return frame,dict(frame=len(frame),header=len(h),payload=len(payload),framing=len(framing),rules=len(model.grammar),states=len(model.edges),peak_frontier=peak,max_fragment=max(map(len,model.tokens)),model_bits=bits,path_count=len(path))

def encode(raw: bytes, *, block_bytes=65536, rules=192, boundary=1, strength=4, mode=1, topology=0, edge_cap=256, **options)->bytes:
    if options: raise ValueError('unknown options')
    if len(raw)>min(block_bytes,MAX_RAW): raise ValueError('prototype accepts one bounded block')
    literals,grammar,seq=fit(raw,rules,return_sequence=True)
    edges=select_edges(seq,edge_cap) if topology else ()
    return encode_model(raw,Model(literals,grammar,boundary,strength,root_edges=edges,topology=topology),mode)[0]

def select_edges(seq,cap):
    if not 0<=cap<=4096: raise ValueError('edge cap')
    # Every retained next-fragment count is charged. Remaining rows back off
    # to global fragments; no root token sequence or privileged parse is sent.
    counts=Counter(zip(seq,seq[1:]))
    return [(a,b,n) for (a,b),n in sorted(counts.items(),key=lambda x:(-x[1],x[0]))[:cap] if n>=2]

def parse(frame):
    if len(frame)>16<<20 or len(frame)<7 or frame[:4] not in (MAGIC,b'GSG2'): raise ValueError('bad frame')
    mode,boundary,strength=frame[4:7]
    if mode not in (0,1): raise ValueError('bad mode')
    p=7; n,p=read_varint(frame,p); count,p=read_varint(frame,p)
    if n>MAX_RAW or count>MAX_RULES: raise ValueError('size bound')
    literals=[]; grammar=[]
    for _ in range(256): v,p=read_varint(frame,p); literals.append(v)
    for _ in range(count):
        a,p=read_varint(frame,p); b,p=read_varint(frame,p); v,p=read_varint(frame,p); grammar.append((a,b,v))
    topology=0; edges=[]
    if frame[:4]==b'GSG2':
        if p>=len(frame): raise ValueError('truncated topology')
        topology=frame[p];p+=1;edge_count,p=read_varint(frame,p)
        if edge_count>4096: raise ValueError('edge count bound')
        for _ in range(edge_count):
            a,p=read_varint(frame,p);b,p=read_varint(frame,p);v,p=read_varint(frame,p);edges.append((a,b,v))
    model=Model(literals,grammar,boundary,strength,root_edges=edges,topology=topology); paths=0
    if mode==0:
        paths,p=read_varint(frame,p)
        if paths>n: raise ValueError('path bounds')
    size,p=read_varint(frame,p)
    if size<8 or size!=len(frame)-p: raise ValueError('payload bounds')
    return n,model,mode,paths,frame[p:]

def decode(frame: bytes)->bytes:
    n,model,mode,paths,payload=parse(frame); dec=ArithmeticDecoder(payload); enc=ArithmeticEncoder(); out=bytearray()
    if mode:
        state=model.initial()
        for _ in range(n):
            probs,starts=model.predictions(state); freqs=quantized_byte_cdf(probs)
            byte=dec.get(freqs); enc.put(byte,freqs); out.append(byte); state=model.advance(state,byte,starts)
    else:
        k=-1
        for step in range(paths):
            if len(out)>=n: raise ValueError('extra path')
            freqs=[max(1,round(p*(1<<20))) for p in model.row(k)]
            i=dec.get(freqs); enc.put(i,freqs); token=model.tokens[i]
            if len(out)+len(token)>n and step!=paths-1: raise ValueError('partial nonfinal')
            out+=token[:n-len(out)]; k=model.keys[i]
    if len(out)!=n or enc.finish()!=payload: raise ValueError('corrupt/noncanonical payload')
    return bytes(out)

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('operation',choices=['encode','decode']); parser.add_argument('input'); parser.add_argument('output'); args=parser.parse_args()
    data=Path(args.input).read_bytes(); result=decode(data) if args.operation=='decode' else encode(data,block_bytes=MAX_RAW)
    Path(args.output).write_bytes(result)
