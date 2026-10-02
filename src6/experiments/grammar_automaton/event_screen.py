#!/usr/bin/env python3
"""Paid optimistic context screen on byte-identical native event traces.

Only token-start decisions are eligible. Odd/even source pages check whether
the correlations generalize. A survivor still needs actual native framing.
"""
from __future__ import annotations

from collections import Counter, defaultdict
import argparse
import json
import math
from pathlib import Path
import struct


def read_trace(path: Path):
    buf = path.read_bytes()
    if buf[:4] != b"WGT3":
        raise ValueError("bad trace")
    count = struct.unpack_from("<I", buf, 4)[0]
    if len(buf) != 8 + count * 16:
        raise ValueError("bad trace length")
    return struct.iter_unpack("<HHIBBIH", memoryview(buf)[8:])


def features(ev, prev, prev2):
    _, _, suffix, suffix_len, _, _, _ = ev
    for width in range(1, suffix_len + 1):
        value = suffix & ((1 << (8 * width)) - 1)
        yield f"suffix{width}", value, 8 * width
        if prev is not None and width <= 2:
            yield f"suffix{width}+kind", (value, prev[4]), 8 * width + 2
    if prev is None:
        return
    yield "kind", prev[4], 2
    yield "first_symbol", prev[1], 16
    length_bin = min(16, prev[5].bit_length() - 1)
    yield "length_bin", length_bin, 5
    yield "kind+length_bin", (prev[4], length_bin), 7
    yield "second_base_row", prev[0], 16
    if prev2 is not None:
        yield "two_kinds", (prev2[4], prev[4]), 4
        yield "three_base_rows", (prev2[0], prev[0]), 32
        yield "kind+second_row", (prev[4], prev[0]), 18


def ideal_gain(counts: Counter, base: Counter) -> float:
    n = sum(counts.values())
    total = sum(base.values())
    return sum(v * math.log2((v / n) / (base[s] / total)) for s, v in counts.items())


def heldout_gain(train: Counter, base: Counter, test: Counter) -> float:
    n = sum(train.values())
    total = sum(base.values())
    alpha = 16.0
    symbols = set(train) | set(base) | set(test)
    base_den = total + 0.25 * len(symbols)
    score = 0.0
    for sym, count in test.items():
        p_base = (base[sym] + 0.25) / base_den
        p_ctx = (train[sym] + alpha * p_base) / (n + alpha)
        score += count * math.log2(p_ctx / p_base)
    return score


def screen(path: Path):
    base = defaultdict(Counter)
    base_train = defaultdict(Counter)
    pairs = defaultdict(lambda: defaultdict(Counter))
    train = defaultdict(lambda: defaultdict(Counter))
    test = defaultdict(lambda: defaultdict(Counter))
    pages = -1
    events = 0
    prev = prev2 = None
    for ev in read_trace(path):
        row, sym, _, suffix_len, _, _, _ = ev
        if suffix_len == 0:
            pages += 1
            prev = prev2 = None
        elif prev is not None and row != prev[6]:
            raise ValueError("noncausal previous-row trace")
        base[row][sym] += 1
        if pages % 2 == 0:
            base_train[row][sym] += 1
        for family, value, key_bits in features(ev, prev, prev2):
            key = (row, value)
            pairs[family][key][sym] += 1
            (train if pages % 2 == 0 else test)[family][key][sym] += 1
        prev2, prev = prev, ev
        events += 1
    results = []
    for family, contexts in pairs.items():
        ranked = []
        for (row, value), counts in contexts.items():
            ideal = ideal_gain(counts, base[row])
            # Deliberate UNDERCHARGE: real native table and selector metadata
            # are usually larger than this bound.
            key_bits = 32 if family.startswith("suffix4") else 24 if family.startswith("suffix3") else 16
            overhead = 24 + key_bits + 12 * len(counts)
            net = ideal - overhead
            one = train[family].get((row, value), Counter())
            other = test[family].get((row, value), Counter())
            heldout = heldout_gain(one, base_train[row], other) if one and other else 0.0
            ranked.append((net, ideal, heldout, row, value, sum(counts.values()), len(counts)))
        ranked.sort(reverse=True)
        winners = [r for r in ranked if r[0] > 0]
        results.append({
            "family": family, "contexts": len(contexts),
            "optimistic_selected": len(winners),
            "optimistic_net_bits": round(sum(r[0] for r in winners), 1),
            "heldout_bits_for_selected": round(sum(r[2] for r in winners), 1),
            "best": [{"net_bits": round(net, 1), "ideal_bits": round(ideal, 1),
                      "heldout_bits": round(held, 1), "row": row,
                      "key": value, "events": n, "symbols": symbols}
                     for net, ideal, held, row, value, n, symbols in ranked[:4]],
        })
    results.sort(key=lambda x: x["optimistic_net_bits"], reverse=True)
    return {"trace": str(path), "events": events, "pages": pages + 1,
            "base_rows": len(base), "families": results}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("traces", type=Path, nargs="+")
    args = parser.parse_args()
    for path in args.traces:
        print(json.dumps(screen(path)))
