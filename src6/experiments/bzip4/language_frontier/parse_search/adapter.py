"""Bounded full-frame grammar search; decoder is the unchanged public v4 CLI.

No normalized bytes, external model, or bzip3 imports. A selector costs nothing:
the selected grammar itself is delivered in the native frame. Encoder search
effort is substantial and must be reported as full adapter wall time.
"""
from __future__ import annotations
from collections import Counter
from itertools import product
from pathlib import Path
import math
import hashlib
import re
import struct
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
FRONTIER = HERE.parent
CAPTURE = FRONTIER / 'evidence/bin/capture_frame'
PUBLIC = FRONTIER.parent / 'bz4/v3/zig-out/bin/bz4'
CONFIGS = tuple(product(('runs', 'unicode', 'records'), (64, 256), (False, True), (2, 6)))
LAST_SEARCH = []

def fingerprint():
    resources=[Path(__file__),CAPTURE,PUBLIC,HERE/'prices.zig']
    if (HERE/'prices').is_file(): resources.append(HERE/'prices')
    return {str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in resources}

def atoms(raw, boundary):
    if boundary == 'runs':
        return re.findall(rb'[A-Za-z\x80-\xff]+|[0-9]+|[^A-Za-z0-9\x80-\xff]', raw)
    if boundary == 'records':
        chunks = raw.splitlines(keepends=True)
        return [c[i:i+128] for c in chunks for i in range(0, len(c), 128)]
    # surrogateescape preserves invalid bytes and prevents accidental replacement.
    text = raw.decode('utf-8', 'surrogateescape')
    chunks = []; start = 0; previous = None
    for i, c in enumerate(text):
        kind = 'a' if c.isalpha() else 'd' if c.isdigit() else 'x'
        if i and (kind != previous or kind == 'x'):
            chunks.append(text[start:i].encode('utf-8', 'surrogateescape')); start = i
        previous = kind
    if text: chunks.append(text[start:].encode('utf-8', 'surrogateescape'))
    return chunks

def grammar(raw, block_bytes, config, prices=None):
    boundary, budget, define_once, phrase_span = config
    blocks = [atoms(raw[i:i+block_bytes], boundary) for i in range(0, len(raw), block_bytes)] or [[]]
    freq = Counter(a for b in blocks for a in b)
    # Count across lexical TYPES: productive fragments must reduce the delivered
    # dictionary, not simply reflect frequent payload words.
    counts = Counter()
    for word in freq:
        for length in (2, 3, 4, 6, 8, 12, 16, 32, 64):
            for i in range(len(word)-length+1): counts[word[i:i+length]] += 1
    def benefit(s,n):
        if prices is None: return (n-1)*(len(s)-1)-len(s)-3
        spelling=sum(prices.get(bytes((b,)),7.0) for b in s)
        use=prices.get(s,math.log2(1+len(freq)/n))
        return (n-1)*(spelling-use)-spelling-12
    ranked = sorted(((s, n) for s, n in counts.items() if n >= 3),
                    key=lambda sn: (-benefit(*sn), sn[0]))
    selected = [(s,n) for s,n in ranked[:budget] if benefit(s,n)>0]
    bodies = []; pieces = {}; byfirst = {}
    for s, n in selected:
        token = 256+len(bodies); bodies.append(tuple(s)); pieces[s] = token
        byfirst.setdefault(s[0], []).append((s, token, max(0.25, prices.get(s,math.log2(1+len(freq)/n)) if prices is not None else math.log2(1+len(freq)/n))))
    wordmap = {}
    for word, count in freq.items():
        # Competing overlapping fragments are segmented jointly, using a frozen
        # type-frequency spelling source; full native bytes arbitrate candidates.
        cost = [float('inf')]*(len(word)+1); path = [None]*(len(word)+1); cost[0] = 0
        for i, byte in enumerate(word):
            choices = [(bytes((byte,)), byte, prices.get(bytes((byte,)),7.0) if prices is not None else 7.0)] + byfirst.get(byte, [])
            for s, token, price in choices:
                j = i+len(s)
                if word.startswith(s, i) and cost[i]+price < cost[j]:
                    cost[j] = cost[i]+price; path[j] = (i, token)
        seq = []; pos = len(word)
        while pos:
            pos, tok = path[pos]; seq.append(tok)
        seq.reverse()
        if len(seq) > 1 and (count > 1 or define_once):
            tok = 256+len(bodies); bodies.append(tuple(seq)); wordmap[word] = [tok]
        else: wordmap[word] = seq
    streams = [[t for a in b for t in wordmap[a]] for b in blocks]
    # Variable-arity phrase proposals compete at each location; avoid pair-only
    # growth and expose longer structures immediately, before shorter merges.
    for _ in range(3):
        phrases = Counter(tuple(b[i:i+n]) for b in streams for n in range(2, phrase_span+1)
                          for i in range(len(b)-n+1))
        chosen = sorted(((p,c) for p,c in phrases.items() if c >= 3),
                        key=lambda pc: (-((pc[1]-1)*(len(pc[0])-1)-3), pc[0]))[:budget]
        choices = {}
        for p, c in chosen:
            if (c-1)*(len(p)-1) <= 3: continue
            tok = 256+len(bodies); bodies.append(p)
            choices.setdefault(p[0], []).append((p,tok,(c-1)*(len(p)-1)-3))
        if not choices: break
        for bi, b in enumerate(streams):
            out=[]; i=0
            while i < len(b):
                matches=[x for x in choices.get(b[i], []) if tuple(b[i:i+len(x[0])]) == x[0]]
                if matches:
                    p,tok,_ = max(matches, key=lambda x: (x[2],len(x[0]),-x[1])); out.append(tok); i+=len(p)
                else: out.append(b[i]); i+=1
            streams[bi]=out
    # Remove unreachable proposals before fitting: this is graph reachability,
    # not the previously negative per-entry price-pruning experiment.
    live=set(); stack=[t for b in streams for t in b if t >= 256]
    while stack:
        t=stack.pop()
        if t in live: continue
        live.add(t); stack.extend(k for k in bodies[t-256] if k >= 256)
    ordered=sorted(live); mapping={t:256+i for i,t in enumerate(ordered)}
    mapped=lambda s: tuple(mapping.get(t,t) for t in s)
    return [mapped(bodies[t-256]) for t in ordered], [mapped(b) for b in streams]

def dump_bytes(bodies, blocks):
    words=[0x44533442,2,len(bodies),len(blocks),0,0]
    for b in bodies:
        if len(b) < 2: raise ValueError('arity')
        words.extend((len(b),*b))
    for b in blocks: words.extend((len(b),*b))
    return struct.pack('<'+'I'*len(words), *words)

def invoke(argv):
    p=subprocess.run([str(x) for x in argv], capture_output=True, timeout=120)
    if p.returncode: raise RuntimeError(p.stderr.decode(errors='replace'))
    return p

def encode(raw: bytes, *, block_bytes: int, **options) -> bytes:
    global LAST_SEARCH
    if block_bytes < 1: raise ValueError('block_bytes')
    unknown=set(options)-{'config','native_control','priced_refit'}
    if unknown: raise ValueError('unknown options: '+str(sorted(unknown)))
    if options.get('config') is not None and (type(options['config']) is not int or not 0<=options['config']<len(CONFIGS)):
        raise ValueError('config must be integer in [0,24)')
    for key in ('native_control','priced_refit'):
        if key in options and type(options[key]) is not bool: raise ValueError(key+' must be bool')
    configs=CONFIGS if options.get('config') is None else (CONFIGS[int(options['config'])],)
    before=fingerprint()
    LAST_SEARCH=[]; best=None
    with tempfile.TemporaryDirectory(prefix='parse-search-', dir=HERE) as tmp:
        d=Path(tmp); source=d/'raw'; source.write_bytes(raw)
        if options.get('native_control', True):
            start=time.perf_counter(); p=invoke([CAPTURE,'raw',source,d/'native.b4',block_bytes])
            best=(d/'native.b4').read_bytes()
            LAST_SEARCH.append(dict(config='native', bytes=len(best), seconds=time.perf_counter()-start, log=p.stderr.decode()))
        evaluated=[]
        for config in configs:
            start=time.perf_counter(); bodies,blocks=grammar(raw,block_bytes,config)
            (d/'parse.b4sd').write_bytes(dump_bytes(bodies,blocks))
            p=invoke([CAPTURE,'saved',source,d/'parse.b4sd',d/'trial.b4','0'])
            frame=(d/'trial.b4').read_bytes()
            LAST_SEARCH.append(dict(config=config,bytes=len(frame),seconds=time.perf_counter()-start,log=p.stderr.decode()))
            evaluated.append((len(frame),config))
            if best is None or len(frame)<len(best): best=frame
        # A deterministic coordinate step refits the winning structural graph
        # under new inventory and phrase-depth budgets; native total bytes,
        # including rows and names, decide every accepted change.
        if len(configs)>1:
            _, winner=min(evaluated)
            neighbors=[(winner[0],n,winner[2],winner[3]) for n in (32,128,512)]
            neighbors += [(winner[0],winner[1],winner[2],n) for n in (4,8,12)]
            for config in neighbors:
                start=time.perf_counter(); bodies,blocks=grammar(raw,block_bytes,config)
                (d/'parse.b4sd').write_bytes(dump_bytes(bodies,blocks))
                p=invoke([CAPTURE,'saved',source,d/'parse.b4sd',d/'trial.b4','0'])
                frame=(d/'trial.b4').read_bytes()
                LAST_SEARCH.append(dict(config=config,phase='coordinate',bytes=len(frame),seconds=time.perf_counter()-start,log=p.stderr.decode()))
                evaluated.append((len(frame),config))
                if len(frame)<len(best): best=frame
        if options.get('priced_refit',False):
            # Native measured-bucket use charges include the selected static
            # context rows and silent class transitions. They guide a NEW shared
            # fragment inventory and overlap DP; no existing-entry pruning.
            _, seed=min(evaluated)
            bodies,blocks=grammar(raw,block_bytes,seed)
            (d/'parse.b4sd').write_bytes(dump_bytes(bodies,blocks))
            p=invoke([CAPTURE,'saved',source,d/'parse.b4sd',d/'seed.b4','0'])
            classes=int(re.search(r'classes=(\d+)',p.stderr.decode())[1])
            start=time.perf_counter(); stats=invoke([HERE/'prices',d/'parse.b4sd',classes])
            expanded=[]
            for body in bodies:
                expanded.append(b''.join(bytes((t,)) if t<256 else expanded[t-256] for t in body))
            literal_line=next(line for line in stats.stderr.decode().splitlines() if line.startswith('literal\t'))
            literal=float(literal_line.split('\t')[1])
            prices={bytes((b,)):literal for b in range(256)}
            for line in stats.stderr.decode().splitlines():
                if not line.startswith('price\t'): continue
                _,entry,bits,uses,byte=line.split('\t'); entry=int(entry); uses=int(uses); byte=int(byte)
                if uses:
                    spelling=bytes((byte,)) if byte>=0 else expanded[entry]
                    prices[spelling]=max(0.25,float(bits)/uses)
            LAST_SEARCH.append(dict(config=seed,phase='native-prices',seconds=time.perf_counter()-start,priced_symbols=len(prices)))
            refits=(seed,(seed[0],seed[1],not seed[2],seed[3]),(seed[0],min(1024,seed[1]*2),seed[2],seed[3]))
            for config in refits:
                start=time.perf_counter(); bodies,blocks=grammar(raw,block_bytes,config,prices)
                (d/'parse.b4sd').write_bytes(dump_bytes(bodies,blocks))
                p=invoke([CAPTURE,'saved',source,d/'parse.b4sd',d/'trial.b4','0'])
                frame=(d/'trial.b4').read_bytes()
                LAST_SEARCH.append(dict(config=config,phase='priced-graph',bytes=len(frame),seconds=time.perf_counter()-start,log=p.stderr.decode()))
                if len(frame)<len(best): best=frame
        if fingerprint()!=before: raise RuntimeError('encoder implementation changed during search')
        return best

def decode(frame: bytes) -> bytes:
    with tempfile.TemporaryDirectory(prefix='parse-decode-', dir=HERE) as tmp:
        d=Path(tmp); (d/'frame').write_bytes(frame)
        invoke([PUBLIC,'d',d/'frame',d/'raw','1'])
        return (d/'raw').read_bytes()
