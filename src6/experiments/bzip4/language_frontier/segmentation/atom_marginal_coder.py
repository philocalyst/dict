#!/usr/bin/env python3
"""Complete-frame negative control for a marginal lexical circuit.

This deliberately simple wire prototype treats each v4 atom as a finite
weighted-circuit leaf.  Its probability is the exact unigram segmentation
sum, while the atom strings and quantized weights are stored in the frame.
It uses a self-contained 64-bit arithmetic coder and decoder so the reported
totals include the model/header and payload, not an entropy estimate.  It is
not proposed as a v4 replacement: atom IDs are decoded as whole leaves and
there is no current-v4 past bucket.  The purpose is to test whether the
marginal gain survives an explicit charge for the circuit's leaves.
"""

from __future__ import annotations

import argparse
import bisect
import hashlib
import json
import math
import os
from collections import Counter, defaultdict

from marginal_gap import atoms, build_inventory


TOP = (1 << 64) - 1
MASK = 0xFFFFFFFFFFFFFFFF


def varint(n: int) -> bytes:
    out = bytearray()
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


def marginal_nlls(atom_freq: Counter[bytes], pieces: list[bytes], alpha: float) -> dict[bytes, float]:
    by_first: dict[int, list[bytes]] = defaultdict(list)
    for p in pieces:
        by_first[p[0]].append(p)
    counts: Counter[bytes] = Counter()
    for text, weight in atom_freq.items():
        for b in text:
            counts[bytes((b,))] += weight
        for at, byte in enumerate(text):
            for p in by_first.get(byte, ()):
                if text.startswith(p, at):
                    counts[p] += weight
    vocab = list(counts)
    total = sum(counts.values()) + alpha * len(vocab)
    logp = {p: math.log2((counts[p] + alpha) / total) for p in vocab}
    result: dict[bytes, float] = {}
    for text in atom_freq:
        forward = [-math.inf] * (len(text) + 1)
        forward[0] = 0.0
        for at in range(len(text)):
            if forward[at] == -math.inf:
                continue
            byte = bytes((text[at],))
            edge = -logp.get(byte, -math.log2(alpha / total))
            forward[at + 1] = logadd2(forward[at + 1], forward[at] - edge)
            for p in by_first.get(text[at], ()):
                if text.startswith(p, at):
                    forward[at + len(p)] = logadd2(forward[at + len(p)], forward[at] + logp[p])
        result[text] = -forward[-1]
    return result


def map_nlls(atom_freq: Counter[bytes], pieces: list[bytes], alpha: float) -> dict[bytes, float]:
    by_first: dict[int, list[bytes]] = defaultdict(list)
    for p in pieces:
        by_first[p[0]].append(p)
    counts: Counter[bytes] = Counter()
    for text, weight in atom_freq.items():
        for b in text:
            counts[bytes((b,))] += weight
        for at, byte in enumerate(text):
            for p in by_first.get(byte, ()):
                if text.startswith(p, at):
                    counts[p] += weight
    vocab = list(counts)
    total = sum(counts.values()) + alpha * len(vocab)
    logp = {p: math.log2((counts[p] + alpha) / total) for p in vocab}
    result: dict[bytes, float] = {}
    for text in atom_freq:
        best = [math.inf] * (len(text) + 1)
        best[0] = 0.0
        for at in range(len(text)):
            if best[at] == math.inf:
                continue
            byte = bytes((text[at],))
            edge = -logp.get(byte, -math.log2(alpha / total))
            best[at + 1] = min(best[at + 1], best[at] + edge)
            for p in by_first.get(text[at], ()):
                if text.startswith(p, at):
                    best[at + len(p)] = min(best[at + len(p)], best[at] - logp[p])
        result[text] = best[-1]
    return result


def logadd(a: float, b: float) -> float:
    if a == -math.inf:
        return b
    if b == -math.inf:
        return a
    if a < b:
        a, b = b, a
    return a + math.log1p(math.exp(b - a))


def logadd2(a: float, b: float) -> float:
    if a == -math.inf:
        return b
    if b == -math.inf:
        return a
    if a < b:
        a, b = b, a
    return a + math.log2(1.0 + math.exp2(b - a))


def quantize(logmass: dict[bytes, float], atom_freq: Counter[bytes]) -> list[int]:
    peak = max(logmass.values())
    # Quantizing a normalized relative mass to integer frequencies is part of
    # the charged model.  A floor of one keeps every observed leaf decodable.
    return [max(1, int(round(math.exp2(logmass[text] - peak) * 1_000_000))) for text in atom_freq]


def cdf(freq: list[int]) -> tuple[list[int], int]:
    cum = [0]
    for f in freq:
        cum.append(cum[-1] + f)
    return cum, cum[-1]


class Encoder:
    def __init__(self, freq: list[int]) -> None:
        self.cum, self.total = cdf(freq)
        self.low = 0
        self.high = TOP
        self.out = bytearray()

    def put(self, sym: int) -> None:
        span = self.high - self.low + 1
        self.high = self.low + (span * self.cum[sym + 1] // self.total) - 1
        self.low += span * self.cum[sym] // self.total
        while (self.low >> 56) == (self.high >> 56):
            self.out.append(self.high >> 56)
            self.low = (self.low << 8) & MASK
            self.high = ((self.high << 8) | 0xFF) & MASK

    def finish(self) -> bytes:
        self.out.extend(self.low.to_bytes(8, "big"))
        return bytes(self.out)


class Decoder:
    def __init__(self, payload: bytes, freq: list[int]) -> None:
        self.cum, self.total = cdf(freq)
        self.low = 0
        self.high = TOP
        self.pos = 0
        self.code = 0
        for _ in range(8):
            self.code = ((self.code << 8) | (payload[self.pos] if self.pos < len(payload) else 0)) & MASK
            self.pos += 1

    def get(self) -> int:
        span = self.high - self.low + 1
        value = ((self.code - self.low + 1) * self.total - 1) // span
        sym = bisect.bisect_right(self.cum, value) - 1
        self.high = self.low + (span * self.cum[sym + 1] // self.total) - 1
        self.low += span * self.cum[sym] // self.total
        while (self.low >> 56) == (self.high >> 56):
            self.low = (self.low << 8) & MASK
            self.high = ((self.high << 8) | 0xFF) & MASK
            self.code = ((self.code << 8) | (0 if self.pos >= len(self.payload) else self.payload[self.pos])) & MASK
            self.pos += 1
        return sym


def encode_decode(atoms_list: list[bytes], unique: list[bytes], freq: list[int]) -> tuple[bytes, bool, int, int]:
    index = {text: i for i, text in enumerate(unique)}
    enc = Encoder(freq)
    for text in atoms_list:
        enc.put(index[text])
    payload = enc.finish()
    # Keep the decode check independent of the payload's trailing flush bytes.
    dec = Decoder(payload, freq)
    dec.payload = payload
    restored = [unique[dec.get()] for _ in atoms_list]
    return payload, restored == atoms_list, len(payload), sum(map(len, restored))


def frame(data: bytes, mode: str, max_piece: int, min_occ: int, max_vocab: int, alpha: float) -> dict[str, object]:
    atom_stream, atom_freq = atoms(data)
    pieces = build_inventory(atom_freq, max_piece, min_occ, max_vocab)
    nll = marginal_nlls(atom_freq, pieces, alpha)
    maps = map_nlls(atom_freq, pieces, alpha)
    empirical = {text: math.log2(atom_freq[text] / len(atom_stream)) for text in atom_freq}
    if mode == "marginal":
        logmass = {text: -value for text, value in nll.items()}
    elif mode == "map":
        logmass = {text: -value for text, value in maps.items()}
    else:
        logmass = empirical
    # `quantize` expects log probabilities; nll is -log p.
    freq = quantize(logmass, atom_freq)
    payload, ok, payload_len, _ = encode_decode(atom_stream, list(atom_freq), freq)
    header = bytearray(b"AMG1")
    header.extend(varint(len(atom_freq)))
    for text, f in zip(atom_freq, freq):
        header.extend(varint(len(text)))
        header.extend(text)
        header.extend(varint(f))
    header.extend(varint(len(payload)))
    return {
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "atoms": len(atom_stream),
        "atom_types": len(atom_freq),
        "pieces": len(pieces),
        "mode": mode,
        "header_bytes": len(header),
        "payload_bytes": payload_len,
        "frame_bytes": len(header) + len(payload),
        "round_trip": ok,
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--max-piece", type=int, default=8)
    ap.add_argument("--min-occ", type=int, default=2)
    ap.add_argument("--max-vocab", type=int, default=2048)
    ap.add_argument("--alpha", type=float, default=0.5)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    rows = []
    for path in args.paths:
        with open(path, "rb") as f:
            data = f.read(args.limit or -1)
        for mode in ("empirical", "map", "marginal"):
            rows.append({"path": os.path.abspath(path), **frame(data, mode, args.max_piece, args.min_occ, args.max_vocab, args.alpha)})
    if args.json:
        print(json.dumps(rows, sort_keys=True))
    else:
        print("path\tmode\tbytes\tatom_types\tpieces\theader_bytes\tpayload_bytes\tframe_bytes\tround_trip")
        for row in rows:
            print("\t".join(str(row[k]) for k in ("path", "mode", "bytes", "atom_types", "pieces", "header_bytes", "payload_bytes", "frame_bytes", "round_trip")))


if __name__ == "__main__":
    main()
