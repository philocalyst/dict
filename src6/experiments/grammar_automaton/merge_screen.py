#!/usr/bin/env python3
"""Optimistic diagnostic for merging sparse native-event contexts.

Contexts are grouped by their strongest lifted next symbol in a base row.
Every key is charged; a group pays one shared table. This is a screen only:
the native wire must serialize the actual map and refit complete frames.
"""
from __future__ import annotations

from collections import Counter, defaultdict
import argparse
import json
import math
from pathlib import Path

from event_screen import features, read_trace


def gain(counts: Counter, base: Counter):
    n = sum(counts.values())
    total = sum(base.values())
    return sum(count * math.log2((count / n) / (base[sym] / total))
               for sym, count in counts.items())


def screen(path: Path):
    base = defaultdict(Counter)
    contexts = defaultdict(lambda: defaultdict(Counter))
    widths = {}
    prev = prev2 = None
    for ev in read_trace(path):
        row, sym, _, suffix_len, _, _, _ = ev
        if suffix_len == 0:
            prev = prev2 = None
        base[row][sym] += 1
        for family, value, width in features(ev, prev, prev2):
            contexts[family][row, value][sym] += 1
            widths[family] = width
        prev2, prev = prev, ev
    results = []
    for family, rows in contexts.items():
        grouped = defaultdict(lambda: {"keys": [], "counts": Counter()})
        for (row, key), counts in rows.items():
            n = sum(counts.values())
            if n < 8:
                continue
            all_n = sum(base[row].values())
            # The key's strongest positive log-lift, excluding singleton
            # noise. A cluster is (base row, lifted next symbol).
            lifted = max(
                ((sym, c * math.log2((c / n) / (base[row][sym] / all_n)))
                 for sym, c in counts.items() if c >= 2),
                key=lambda pair: pair[1], default=None)
            if lifted is None or lifted[1] <= 0:
                continue
            group = grouped[row, lifted[0]]
            group["keys"].append(key)
            group["counts"].update(counts)
        wins = []
        for (row, symbol), group in grouped.items():
            counts = group["counts"]
            keys = len(group["keys"])
            # Deliberate lower bound: one table, each key plus a row target.
            overhead = 24 + 12 * len(counts) + keys * (widths[family] + 8)
            net = gain(counts, base[row]) - overhead
            if net > 0:
                wins.append((net, row, symbol, keys, sum(counts.values()), len(counts)))
        wins.sort(reverse=True)
        results.append({
            "family": family, "candidate_groups": len(grouped),
            "optimistic_merged_groups": len(wins),
            "optimistic_net_bits": round(sum(x[0] for x in wins), 1),
            "best": [{"net_bits": round(net, 1), "base_row": row,
                      "lifted_symbol": symbol, "keys": keys,
                      "events": n, "symbols": support}
                     for net, row, symbol, keys, n, support in wins[:5]],
        })
    results.sort(key=lambda result: result["optimistic_net_bits"], reverse=True)
    return {"trace": str(path), "families": results}


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("traces", nargs="+", type=Path)
    for trace in ap.parse_args().traces:
        print(json.dumps(screen(trace)))
