#!/usr/bin/env python3
"""Development-only paid sparse-context screen for P6F1 grammar roots.

The root bits are an entropy estimate, not a wire size. Native WGA framing and
integer entropy coding must confirm any candidate before it is called a win.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import json
import math
from pathlib import Path
import struct
import sys
import zlib

PAGE = 65536


def varint(value: int) -> bytes:
    if value < 0:
        raise ValueError("negative varint")
    out = bytearray()
    while value >= 128:
        out.append(128 | (value & 127))
        value >>= 7
    out.append(value)
    return bytes(out)


def read_graph(path: Path):
    data = path.read_bytes()
    if data[:4] != b"P6F1":
        raise ValueError("forward DAG graph required")
    offset = 4
    arrays = []
    for _ in range(4):
        length = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        array = struct.unpack_from(f"<{length}I", data, offset)
        offset += 4 * length
        arrays.append(array)
    if offset != len(data):
        raise ValueError("graph trailing bytes")
    return arrays


def grammar_model_bytes(offsets, children):
    wire = bytearray()
    for start, end in zip(offsets, offsets[1:]):
        wire.extend(varint(end - start))
        for child in children[start:end]:
            wire.extend(varint(child))
    return len(wire), len(zlib.compress(wire, 9))


def expansion_suffixes(offsets, children, width: int = 4):
    """Return each root's last bytes, without materializing full expansions."""
    sys.setrecursionlimit(100000)
    known = [(1, bytes([i])) for i in range(256)] + [None] * (len(offsets) - 1)
    active = set()

    def visit(root):
        if known[root] is not None:
            return known[root]
        if root in active:
            raise ValueError("cyclic grammar")
        active.add(root)
        index = root - 256
        length = 0
        suffix = b""
        for child in children[offsets[index]:offsets[index + 1]]:
            child_length, child_suffix = visit(child)
            length = min(width, length + child_length)
            suffix = (suffix + child_suffix)[-width:]
        active.remove(root)
        known[root] = length, suffix
        return known[root]

    for root in range(256, len(known)):
        visit(root)
    return known


def base_bits(root: int, global_count: Counter, total: int) -> float:
    return math.log2(total / global_count[root])


def best_row(context, events: Counter, baseline, max_top: int, raw_overhead: bool):
    total = sum(events.values())
    if total < 2:
        return None
    ranked = sorted(events, key=lambda root: (-events[root], root))
    current = None
    for top_size in range(1, min(max_top, len(ranked)) + 1):
        selected = ranked[:top_size]
        remaining = total - sum(events[root] for root in selected)
        row_bits = 0.0
        for root in selected:
            count = events[root]
            row_bits += count * math.log2(total / count)
        if remaining:
            row_bits += remaining * math.log2(total / remaining)
        escape = set(selected)
        for root, count in events.items():
            if root not in escape:
                row_bits += count * baseline(root)
        fallback_bits = sum(count * baseline(root) for root, count in events.items())
        # One row tag, context IDs, event count, event IDs and scaled frequencies.
        serialized = (b"".join(varint(part) for part in context)
                      + varint(top_size)
                      + b"".join(varint(root) + varint(events[root]) for root in selected)
                      + varint(remaining))
        metadata = len(serialized) + (1 if raw_overhead else 0)
        gain = fallback_bits - row_bits - 8 * metadata
        if gain > 0 and (current is None or gain > current[0]):
            current = gain, tuple(selected), row_bits, fallback_bits, serialized
    return current


def selected_model(contexts, baseline, max_top: int):
    rows = {}
    for context, events in contexts.items():
        candidate = best_row(context, events, baseline(context), max_top, True)
        if candidate is not None:
            rows[context] = candidate
    return rows


def row_cost(root: int, row, events: Counter, fallback) -> float:
    if row is None:
        return fallback(root)
    selected = row[1]
    total = sum(events.values())
    if root in selected:
        return math.log2(total / events[root])
    remaining = total - sum(events[item] for item in selected)
    return math.log2(total / remaining) + fallback(root)


def evaluate(offsets, children, block_ends, roots, max_top: int, context_mode: str):
    global_count = Counter(roots)
    total = len(roots)
    first = defaultdict(Counter)
    second = defaultdict(Counter)
    signatures = expansion_suffixes(offsets, children) if context_mode == "byte-suffix" else None
    for start, end in zip(block_ends, block_ends[1:]):
        prev1 = prev2 = 256 + len(offsets)
        suffix = (256, 256, 256, 256)
        for root in roots[start:end]:
            if context_mode == "byte-suffix":
                first[(suffix[-1],)][root] += 1
                second[suffix[-2:]][root] += 1
                length, tail = signatures[root]
                suffix = (suffix + tuple(tail))[-4:]
            else:
                first[(prev1,)][root] += 1
                second[(prev2, prev1)][root] += 1
            prev2, prev1 = prev1, root
    global_bits = sum(count * base_bits(root, global_count, total)
                      for root, count in global_count.items())
    first_rows = selected_model(first,
                                lambda _context: lambda root: base_bits(root, global_count, total),
                                max_top)

    def first_bits(context):
        previous = (context[-1],)
        return lambda root: row_cost(root, first_rows.get(previous), first[previous],
                                     lambda symbol: base_bits(symbol, global_count, total))

    second_rows = selected_model(second, first_bits, max_top)
    first_gain = sum(row[3] - row[2] for row in first_rows.values())
    second_gain = sum(row[3] - row[2] for row in second_rows.values())
    inventory_raw, inventory_zlib = grammar_model_bytes(offsets, children)
    global_wire = b"".join(varint(global_count[root]) for root in range(256 + len(offsets) - 1))
    row_wires = []
    for rows in (first_rows, second_rows):
        wire = b"".join(row[-1] for _, row in sorted(rows.items()))
        row_wires.append({"rows": len(rows), "raw_bytes": len(wire),
                          "zlib_bytes": len(zlib.compress(wire, 9)),
                          "gross_entropy_saving_bytes": sum(row[3] - row[2] for row in rows.values()) / 8})
    return {
        "context_mode": context_mode,
        "grammar_rules": len(offsets) - 1, "grammar_children": len(children),
        "source_pages": len(block_ends) - 1, "root_occurrences": total,
        "distinct_roots": len(global_count),
        "grammar_inventory_raw_bytes": inventory_raw,
        "grammar_inventory_zlib9_bytes": inventory_zlib,
        "global_root_count_raw_bytes": len(global_wire),
        "global_root_count_zlib9_bytes": len(zlib.compress(global_wire, 9)),
        "order0_ideal_root_bytes": global_bits / 8,
        "first_order_rows": row_wires[0], "second_order_rows": row_wires[1],
        "first_order_net_raw_metadata_bytes": (first_gain / 8) - row_wires[0]["raw_bytes"],
        "second_order_net_raw_metadata_bytes": (second_gain / 8) - row_wires[1]["raw_bytes"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("graph", type=Path)
    parser.add_argument("--max-top", type=int, default=4)
    parser.add_argument("--context", choices=("exact-root", "byte-suffix"), default="exact-root")
    args = parser.parse_args()
    if not 1 <= args.max_top <= 16:
        raise SystemExit("max-top must be 1..16")
    print(json.dumps(evaluate(*read_graph(args.graph), args.max_top, args.context), sort_keys=True))


if __name__ == "__main__":
    main()
