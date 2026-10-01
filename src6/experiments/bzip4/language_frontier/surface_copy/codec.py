"""SCM3: integer causal copy posterior with recursive literal backoff."""
from collections import defaultdict, deque
from bisect import bisect_right
import hashlib
import struct
import zlib

Q = 65536
HEAD = struct.Struct('>4sBBBBIQ32s')
SPAN = struct.Struct('>III')
TOP = (1 << 32) - 1
HALF, QUARTER = 1 << 31, 1 << 30


def normalize(values, total=Q):
    """Exact sum, largest remainder, stable insertion-order ties."""
    s = sum(values)
    if not s:
        raise ValueError('zero source mass')
    pairs = [divmod(v * total, s) for v in values]
    out = [x[0] for x in pairs]
    for i in sorted(range(len(values)), key=lambda i: -pairs[i][1])[:total-sum(out)]:
        out[i] += 1
    return out


class Arithmetic:
    def __init__(self, payload=None):
        self.low, self.high, self.pending = 0, TOP, 0
        self.bits = []
        self.payload, self.at, self.code = payload, 0, 0
        if payload is not None:
            for _ in range(32):
                self.code = (self.code << 1) | self.read()

    def read(self):
        if self.at >= 8 * len(self.payload):
            return 0
        b = (self.payload[self.at // 8] >> (7-self.at % 8)) & 1
        self.at += 1
        return b

    def emit(self, b):
        self.bits.append(b)
        self.bits.extend([1-b] * self.pending)
        self.pending = 0

    def step(self, counts, symbol=None):
        cdf = [0]
        for c in counts:
            cdf.append(cdf[-1]+c)
        span = self.high-self.low+1
        decoding = self.payload is not None
        if decoding:
            v = ((self.code-self.low+1)*cdf[-1]-1)//span
            symbol = bisect_right(cdf, v)-1
            if not 0 <= symbol < 256:
                raise ValueError('invalid arithmetic state')
        self.high = self.low+span*cdf[symbol+1]//cdf[-1]-1
        self.low += span*cdf[symbol]//cdf[-1]
        while True:
            if self.high < HALF:
                if not decoding: self.emit(0)
                shift = 0
            elif self.low >= HALF:
                if not decoding: self.emit(1)
                shift = HALF
            elif self.low >= QUARTER and self.high < 3*QUARTER:
                if not decoding: self.pending += 1
                shift = QUARTER
            else:
                break
            self.low = (self.low-shift)*2
            self.high = (self.high-shift)*2+1
            if decoding:
                self.code = (self.code-shift)*2+self.read()
        return symbol

    def finish(self):
        self.pending += 1
        self.emit(0 if self.low < QUARTER else 1)
        self.bits.extend([0]*max(0,32-len(self.bits)))
        self.bits.extend([0]*((-len(self.bits)) % 8))
        return bytes(sum(self.bits[i+j] << (7-j) for j in range(8))
                     for i in range(0,len(self.bits),8))


class Source:
    def __init__(self, policy=0, frontier=32, survival=1, start=2):
        self.policy, self.k, self.survival, self.start = policy,frontier,survival,start
        self.history = bytearray()
        self.index = {n:{} for n in (2,4,8)}
        self.literal = {n:{} for n in (0,1,2,4)}
        self.escape, self.active = Q, {}
        self.max_frontier = self.copy_steps = 0

    def prediction(self):
        h = self.history
        literal = [256]*256
        for n in (0,1,2,4):
            if len(h) < n: continue
            key = bytes(h[-n:]) if n else b''
            row = self.literal[n].get(key)
            if row is not None:
                if n == 0:
                    literal = normalize([1+row.get(b,0) for b in range(256)])
                else:
                    values = [16*literal[b]+Q*row.get(b,0) for b in range(256)]
                    literal = [1+x for x in normalize(values,Q-256)]
        mass, ages = {}, {}
        escape = self.escape
        for j,(w,age) in self.active.items():
            if j >= len(h):
                escape += w
                continue
            denominator = 16 if not self.survival else 4+min(age,60)
            keep = w*(denominator-1)//denominator
            escape += w-keep
            mass[j] = keep
            ages[j] = age
        starts = {}
        for n in (8,4,2):
            if len(h) < n: continue
            candidates = self.index[n].get(bytes(h[-n:]),())
            if candidates:
                factor = {2:1,4:2,8:4}[n] if self.policy else 1
                for j in candidates: starts[j] = starts.get(j,0)+factor
                if not self.policy: break
        # A zero start is the same-backend literal-only control.
        budget = escape*self.start//4 if starts else 0
        if budget:
            js = sorted(starts)
            for j,w in zip(js,normalize([starts[j] for j in js],budget)):
                assert j < len(h)
                mass[j] = mass.get(j,0)+w
                ages.setdefault(j,0)
        escape -= budget
        probs = [escape*x for x in literal]
        for j,w in mass.items(): probs[h[j]] += w*Q
        # Explicitly quantized emission law, positive for every byte.
        counts = [1+p*65280//(Q*Q) for p in probs]
        self.pending = mass,ages,escape,literal
        return counts

    def observe(self,b):
        h = self.history
        mass,ages,escape,literal = self.pending
        weights,age_next = {},{}
        for j,w in mass.items():
            assert j < len(h)
            if h[j] == b and w:
                weights[j+1] = weights.get(j+1,0)+w*Q
                age_next[j+1] = max(age_next.get(j+1,0),ages[j]+1)
        js = sorted(weights, key=lambda j:(-weights[j],-j))
        dropped = sum(weights[j] for j in js[self.k:])
        js = js[:self.k]
        normalized = normalize([escape*literal[b]+dropped]+[weights[j] for j in js])
        self.escape = normalized[0]
        self.active = {j:(w,age_next[j]) for j,w in zip(js,normalized[1:]) if w}
        self.max_frontier = max(self.max_frontier,len(self.active))
        self.copy_steps += bool(self.active)
        # Update indexes using prefix before b, but only make its now-decoded
        # continuation available after b is appended.
        for n in (0,1,2,4):
            if len(h) < n: continue
            key = bytes(h[-n:]) if n else b''
            row = self.literal[n].setdefault(key,{})
            row[b] = row.get(b,0)+1
            if sum(row.values()) >= 4096:
                for x in row: row[x] = (row[x]+1)//2
        for n in (2,4,8):
            if len(h) < n: continue
            key = bytes(h[-n:])
            positions = self.index[n].setdefault(key,deque(maxlen=self.k))
            positions.append(len(h))
        h.append(b)


def encode(raw, *, block_bytes=65536, policy=0, frontier=32, survival=1, start=2):
    if policy not in (0,1) or frontier not in (8,32) or survival not in (0,1) or start not in (0,1,2,3):
        raise ValueError('unsupported source policy')
    if not 1 <= block_bytes <= 65536 or len(raw) > 8*1024*1024:
        raise ValueError('invalid block size')
    out = bytearray(HEAD.pack(b'SCM3',policy,frontier,survival,start,block_bytes,len(raw),hashlib.sha256(raw).digest()))
    for at in range(0,len(raw),block_bytes):
        block = raw[at:at+block_bytes]
        model, coder = Source(policy,frontier,survival,start), Arithmetic()
        for b in block:
            coder.step(model.prediction(),b)
            model.observe(b)
        payload = coder.finish()
        out.extend(SPAN.pack(len(block),len(payload),zlib.crc32(payload)))
        out.extend(payload)
    return bytes(out)


def decode(frame, *, output_budget=8*1024*1024):
    if len(frame) < HEAD.size: raise ValueError('truncated header')
    magic,policy,k,survival,start,block_size,length,digest = HEAD.unpack_from(frame)
    if magic != b'SCM3' or policy not in (0,1) or k not in (8,32) or survival not in (0,1) or start not in (0,1,2,3):
        raise ValueError('invalid header')
    if not 1 <= block_size <= 65536 or length > min(output_budget,8*1024*1024):
        raise ValueError('output budget/block size')
    at, out = HEAD.size,bytearray()
    while len(out) < length:
        if at+SPAN.size > len(frame): raise ValueError('truncated block')
        n,p,crc = SPAN.unpack_from(frame,at)
        at += SPAN.size
        if n != min(block_size,length-len(out)) or p < 4 or p > n*2+16 or at+p > len(frame):
            raise ValueError('invalid block bounds')
        payload = frame[at:at+p]
        if zlib.crc32(payload) != crc: raise ValueError('payload checksum')
        coder, model = Arithmetic(payload), Source(policy,k,survival,start)
        at += p
        for _ in range(n):
            b = coder.step(model.prediction())
            model.observe(b)
            out.append(b)
    if at != len(frame) or hashlib.sha256(out).digest() != digest:
        raise ValueError('trailing bytes or checksum mismatch')
    return bytes(out)
