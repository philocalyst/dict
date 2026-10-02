#!/usr/bin/env python3
"""Paid, bounded context induction for exact word-wrap residuals.

Only the encoder needs numpy. The decoder uses transmitted integer frequencies
and at most sixteen numeric comparisons per separator. Features are byte-level
observations available before reconstructing that separator; no word lists,
language identifiers, field names, or normalized Unicode spellings are used.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct

import geometry

MAX_LEAVES = 256
MAX_DEPTH = 16


def features(column, previous, following, width):
    return (int(column + 1 + len(following) > width), min(column, 4096),
            min(len(following), 4096), previous[-1] if previous else 0,
            following[0] if following else 0)


def observations(raw, width=72):
    chunks = geometry.parts(raw)
    columns, labels, column = [], [], 0
    for i, chunk in enumerate(chunks):
        if chunk in (b" ", b"\n") and i + 1 < len(chunks):
            row = features(column, chunks[i-1] if i else b"", chunks[i+1], width)
            columns.append(row)
            labels.append(row[0] ^ int(chunk == b"\n"))
        column = geometry.advance(column, chunk)
    return columns, labels


def probability(zeros, ones):
    if not zeros:
        return 0 if ones else geometry.SCALE // 2
    if not ones:
        return geometry.SCALE
    return max(1, min(geometry.SCALE-1, round(geometry.SCALE * zeros / (zeros+ones))))


def fit(columns, labels, max_leaves=MAX_LEAVES):
    import numpy as np
    if not 1 <= max_leaves <= MAX_LEAVES:
        raise ValueError("tree leaf limit")
    x = np.asarray(columns, dtype=np.uint16).reshape((-1, 5))
    y = np.asarray(labels, dtype=np.uint8)
    if len(x) != len(y):
        raise ValueError("observation length")

    def entropy(z, o):
        n = z + o
        # Floating scores select a proposal; actual wire frequencies are integer.
        with np.errstate(divide="ignore", invalid="ignore"):
            return (np.where(n > 0, n * np.log2(n), 0) -
                    np.where(z > 0, z * np.log2(z), 0) -
                    np.where(o > 0, o * np.log2(o), 0))

    def node(indices, depth):
        ones = int(y[indices].sum())
        zeros = len(indices) - ones
        out = {"indices": indices, "depth": depth,
               "zero": probability(zeros, ones), "gain": 0.0}
        if depth >= MAX_DEPTH or not zeros or not ones:
            return out
        parent = float(entropy(float(zeros), float(ones)))
        for feature in range(5):
            counts = np.bincount(x[indices, feature], minlength=2).astype(np.float64)
            one = np.bincount(x[indices, feature], weights=y[indices], minlength=len(counts))
            left_n, left_o = np.cumsum(counts)[:-1], np.cumsum(one)[:-1]
            right_n, right_o = len(indices) - left_n, ones - left_o
            # One additional branch and leaf costs six actual model bytes.
            gain = parent - entropy(left_n-left_o, left_o) - entropy(right_n-right_o, right_o) - 48
            gain[(left_n == 0) | (right_n == 0)] = -math.inf
            if len(gain):
                threshold = int(np.argmax(gain))
                value = float(gain[threshold])
                if value > out["gain"]:
                    out.update(gain=value, feature=feature, threshold=threshold)
        return out

    root = node(np.arange(len(y)), 0)
    leaves = [root]
    while len(leaves) < max_leaves:
        selected_index = max(range(len(leaves)), key=lambda i: leaves[i]["gain"])
        selected = leaves[selected_index]
        if selected["gain"] <= 0:
            break
        indices = selected.pop("indices")
        left = x[indices, selected["feature"]] <= selected["threshold"]
        selected["left"] = node(indices[left], selected["depth"]+1)
        selected["right"] = node(indices[~left], selected["depth"]+1)
        leaves.pop(selected_index)
        leaves.extend((selected["left"], selected["right"]))

    def freeze(n):
        if "left" not in n:
            return (0, n["zero"])
        return (n["feature"]+1, n["threshold"], freeze(n["left"]), freeze(n["right"]))
    return freeze(root)


def serialize(tree):
    if tree[0] == 0:
        return struct.pack("<BH", 0, tree[1])
    return struct.pack("<BH", tree[0], tree[1]) + serialize(tree[2]) + serialize(tree[3])


def parse(model):
    at, leaves = 0, 0

    def take(depth):
        nonlocal at, leaves
        if depth > MAX_DEPTH or at+3 > len(model):
            raise ValueError("tree depth or truncation")
        kind, value = struct.unpack_from("<BH", model, at)
        at += 3
        if kind == 0:
            leaves += 1
            if value > geometry.SCALE or leaves > MAX_LEAVES:
                raise ValueError("tree frequency or leaf limit")
            return (0, value)
        if kind > 5 or value > (4096 if kind in (2, 3) else 255 if kind in (4, 5) else 1):
            raise ValueError("tree feature limit")
        return (kind, value, take(depth+1), take(depth+1))
    tree = take(0)
    if at != len(model):
        raise ValueError("tree trailing bytes")
    return tree


def leaf_frequency(tree, row):
    while tree[0]:
        tree = tree[2] if row[tree[0]-1] <= tree[1] else tree[3]
    return tree[1]


def pack(tree, columns, labels):
    state, emitted = geometry.LOW, bytearray()
    for row, symbol in zip(reversed(columns), reversed(labels)):
        zero = leaf_frequency(tree, row)
        start, frequency = (0, zero) if symbol == 0 else (zero, geometry.SCALE-zero)
        if not frequency:
            raise ValueError("zero-probability tree event")
        maximum = ((geometry.LOW >> 12) << 8) * frequency
        while state >= maximum:
            emitted.append(state & 255)
            state >>= 8
        state = (state // frequency) * geometry.SCALE + state % frequency + start
    return struct.pack("<I", state) + bytes(reversed(emitted))


def realize(normalized, flags, model, count, width=72):
    tree = parse(model)
    if len(flags) < 4 or not 0 <= count <= len(normalized) or not 1 <= width <= 4096:
        raise ValueError("tree residual header")
    state, = struct.unpack_from("<I", flags)
    if not geometry.LOW <= state < geometry.LOW * 256:
        raise ValueError("tree residual state")
    chunks, output, at, seen, column = geometry.parts(normalized), [], 4, 0, 0
    for i, chunk in enumerate(chunks):
        if chunk in (b" ", b"\n") and i+1 < len(chunks):
            if chunk != b" " or seen >= count:
                raise ValueError("tree residual slot")
            row = features(column, chunks[i-1] if i else b"", chunks[i+1], width)
            zero = leaf_frequency(tree, row)
            residue = state & (geometry.SCALE-1)
            symbol = int(residue >= zero)
            start, frequency = (0, zero) if symbol == 0 else (zero, geometry.SCALE-zero)
            if not frequency:
                raise ValueError("tree residual frequency")
            state = frequency * (state >> 12) + residue - start
            while state < geometry.LOW:
                if at >= len(flags):
                    raise ValueError("tree residual truncation")
                state = (state << 8) | flags[at]
                at += 1
            chunk = b"\n" if (row[0] ^ symbol) else b" "
            seen += 1
        output.append(chunk)
        column = geometry.advance(column, chunk)
    if seen != count or at != len(flags) or state != geometry.LOW:
        raise ValueError("tree residual tail")
    return b"".join(output)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("input", type=Path)
    p.add_argument("--max-leaves", type=int, default=MAX_LEAVES)
    p.add_argument("--output-prefix", type=Path)
    args = p.parse_args()
    if args.input.stat().st_size > geometry.LIMIT:
        raise ValueError("input limit")
    raw = args.input.read_bytes()
    normalized, basic_events = geometry.propose(raw, 72)
    columns, labels = observations(raw)
    if len(columns) != len(basic_events):
        raise ValueError("event parity")
    tree = fit(columns, labels, args.max_leaves)
    model = serialize(tree)
    flags = pack(tree, columns, labels)
    if realize(normalized, flags, model, len(labels)) != raw:
        raise ValueError("exact source gate")
    if args.output_prefix:
        args.output_prefix.with_suffix(".model").write_bytes(model)
        args.output_prefix.with_suffix(".flags").write_bytes(flags)
    basic = geometry.pack(basic_events, geometry.frequencies(basic_events))
    print(json.dumps({"source_sha256":hashlib.sha256(raw).hexdigest(), "raw_bytes":len(raw),
        "events":len(labels),"width":72,"max_leaves":args.max_leaves,"model_bytes":len(model),
        "flags_bytes":len(flags),"charged_model_plus_flags_bytes":len(model)+len(flags),
        "basic_flags_bytes":len(basic),"saved_bytes":len(basic)-len(model)-len(flags),
        "model_sha256":hashlib.sha256(model).hexdigest(),
        "flags_sha256":hashlib.sha256(flags).hexdigest(),
        "source_identity":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "scope":"exact residual cost screen; native normalized payload unchanged; full wrapper integration pending"}))


if __name__ == "__main__":
    main()
