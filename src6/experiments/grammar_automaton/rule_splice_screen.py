#!/usr/bin/env python3
"""Optimistic previous-definition substring screen on an exact P6F1 graph.

This estimates whether dictionary definitions deserve a dedicated native
splice opcode. It does not model native PAST, names, definition scheduling,
or the actual splice wire, so its bytes are never reported as codec sizes.
"""
from __future__ import annotations

from collections import defaultdict, deque
from bisect import bisect_right
import json
from pathlib import Path
import struct
import sys


def arrays(path: Path):
    data = path.read_bytes()
    if data[:4] != b"P6F1":
        raise ValueError("expected preserved-ID forward grammar")
    pos = 4
    out = []
    for _ in range(4):
        count, = struct.unpack_from("<I", data, pos)
        pos += 4
        out.append(struct.unpack_from(f"<{count}I", data, pos))
        pos += count * 4
    if pos != len(data):
        raise ValueError("trailing graph bytes")
    return out


def gamma_bits(n: int) -> int:
    if n <= 0:
        raise ValueError(n)
    return 2 * (n.bit_length() - 1) + 1


def native_delta_bytes(path: Path):
    data = path.read_bytes()
    if data[:4] not in (b"wgj\x01", b"wga\x01", b"bz4\x03"):
        raise ValueError("unrecognized native frame")
    pos = 4

    def var():
        nonlocal pos
        value = 0
        for shift in range(0, 35, 7):
            b = data[pos]
            pos += 1
            value |= (b & 127) << shift
            if b < 128:
                return value
        raise ValueError("bad frame varint")

    header_len = var()
    pos += header_len  # all native entropy tables
    total = 0
    while True:
        kind = data[pos]
        pos += 1
        if kind == 0:
            break
        if kind & 1:
            _definitions, _expanded_scratch, delta_len = var(), var(), var()
        else:
            delta_len = 0
        if kind & 2:
            _raw, _items, payload_len = var(), var(), var()
        else:
            payload_len = 0
        pos += delta_len + payload_len
        total += delta_len
    if pos != len(data):
        raise ValueError("trailing native frame")
    return total


def screen_child_sequences(body_off, kids, order, delta_bytes, recent):
    """Gross upper diagnostic for exact repeated grammar-child subsequences."""
    index = defaultdict(lambda: deque(maxlen=16))
    best_per_rule = []
    total_kids = sum(body_off[e + 1] - body_off[e] for e in order)
    gross_bits = 8 * delta_bytes / max(1, total_kids)
    for order_index, entry in enumerate(order):
        body = kids[body_off[entry] : body_off[entry + 1]]
        best = (0.0, None)
        for at in range(len(body) - 1):
            for donor_index, donor_entry, donor_at in index[(body[at], body[at + 1])]:
                distance = order_index - donor_index
                if not 1 <= distance <= recent:
                    continue
                donor = kids[body_off[donor_entry] : body_off[donor_entry + 1]]
                length = 2
                while at + length < len(body) and donor_at + length < len(donor) and body[at + length] == donor[donor_at + length]:
                    length += 1
                operand_bits = 3 + gamma_bits(distance) + gamma_bits(donor_at + 1) + gamma_bits(length)
                gain = length * gross_bits - operand_bits
                if gain > best[0]:
                    best = (gain, (entry, donor_entry, distance, at, donor_at, length, operand_bits))
        if best[1] is not None:
            best_per_rule.append((round(best[0] / 8, 2), *best[1]))
        for at in range(len(body) - 1):
            index[(body[at], body[at + 1])].append((order_index, entry, at))
    best_per_rule.sort(reverse=True)
    return {
        "first_demand_child_events": total_kids,
        "gross_native_delta_bits_per_graph_child": round(gross_bits, 4),
        "positive_exact_child_sequence_splices": len(best_per_rule),
        "optimistic_saved_bytes": round(sum(item[0] for item in best_per_rule), 2),
        "best_ten": best_per_rule[:10],
        "warning": "Gross native delta bytes include names and arities; marginal savings per child may be much lower",
    }


def first_demand_order(body_off, kids, toks):
    state = bytearray(len(body_off) - 1)
    order = []

    def visit(entry):
        if state[entry] == 2:
            return
        if state[entry] == 1:
            raise ValueError("cyclic grammar")
        state[entry] = 1
        for child in kids[body_off[entry] : body_off[entry + 1]]:
            if child >= 256:
                visit(child - 256)
        state[entry] = 2
        order.append(entry)

    for tok in toks:
        if tok >= 256:
            visit(tok - 256)
    return order


def screen(graph: Path, native_frame: Path, recent: int = 1024):
    body_off, kids, block_off, toks = arrays(graph)
    order = first_demand_order(body_off, kids, toks)
    expanded = {}
    raw_expanded_bytes = 0
    skipped_long = 0
    for entry in order:
        parts = []
        for child in kids[body_off[entry] : body_off[entry + 1]]:
            parts.append(bytes([child]) if child < 256 else expanded[child - 256])
        surface = b"".join(parts)
        expanded[entry] = surface
        raw_expanded_bytes += len(surface)
        if len(surface) > 4096:
            skipped_long += 1
    delta_bytes = native_delta_bytes(native_frame)
    bits_per_surface_byte = 8 * delta_bytes / max(1, raw_expanded_bytes)
    fourgram = defaultdict(lambda: deque(maxlen=16))
    top = []
    credited_bits = 0.0
    aligned = []
    child_events = sum(body_off[e + 1] - body_off[e] for e in order)
    gross_child_bits = 8 * delta_bytes / max(1, child_events)
    for order_index, entry in enumerate(order):
        surface = expanded[entry]
        if len(surface) > 4096:
            continue
        best = (0.0, None)
        best_aligned = (0.0, None)
        child_starts = {}
        child_ends = []
        offset = 0
        for child_index, child in enumerate(kids[body_off[entry] : body_off[entry + 1]]):
            child_starts[offset] = child_index
            offset += 1 if child < 256 else len(expanded[child - 256])
            child_ends.append(offset)
        for at in range(len(surface) - 3):
            for donor_index, donor_entry, donor_at in fourgram[surface[at : at + 4]]:
                distance = order_index - donor_index
                if distance < 1 or distance > recent:
                    continue
                donor = expanded[donor_entry]
                length = 4
                while at + length < len(surface) and donor_at + length < len(donor) and surface[at + length] == donor[donor_at + length]:
                    length += 1
                operand_bits = 3 + gamma_bits(distance) + gamma_bits(donor_at + 1) + gamma_bits(length)
                gain = length * bits_per_surface_byte - operand_bits
                if gain > best[0]:
                    best = (gain, (entry, donor_entry, distance, at, donor_at, length, operand_bits))
                if at in child_starts:
                    first_child = child_starts[at]
                    ending_children = bisect_right(child_ends, at + length)
                    count = ending_children - first_child
                    if count >= 2:
                        whole_length = child_ends[ending_children - 1] - at
                        whole_operand_bits = 3 + gamma_bits(distance) + gamma_bits(donor_at + 1) + gamma_bits(whole_length)
                        whole_gain = count * gross_child_bits - whole_operand_bits
                        if whole_gain > best_aligned[0]:
                            best_aligned = (whole_gain, (entry, donor_entry, distance, first_child,
                                count, donor_at, whole_length, whole_operand_bits))
        if best[1] is not None:
            credited_bits += best[0]
            top.append((round(best[0] / 8, 2), *best[1]))
        if best_aligned[1] is not None:
            aligned.append((best_aligned[0], best_aligned[1]))
        for at in range(len(surface) - 3):
            fourgram[surface[at : at + 4]].append((order_index, entry, at))
    top.sort(reverse=True)
    aligned.sort(reverse=True)
    return {
        "graph": str(graph), "entries": len(body_off) - 1,
        "first_demand_definitions": len(order), "source_pages": len(block_off) - 1,
        "expanded_definition_bytes": raw_expanded_bytes,
        "surface_bytes_per_entry": round(raw_expanded_bytes / max(1, len(order)), 3),
        "skipped_definitions_over_4096_bytes": skipped_long,
        "native_delta_frame": str(native_frame),
        "native_delta_compressed_bytes": delta_bytes,
        "estimated_native_bits_per_surface_byte": bits_per_surface_byte,
        "recent_definition_limit": recent,
        "credit_rule": "one best non-overlapping splice per definition, gamma operands plus 3-bit opcode floor",
        "positive_definition_splices": len(top),
        "optimistic_total_saved_bytes": round(credited_bits / 8, 2),
        "best_ten": top[:10],
        "child_aligned_surface_splices": {
            "gross_bits_per_skipped_child": round(gross_child_bits, 4),
            "positive_splices": len(aligned),
            "optimistic_saved_bytes": round(sum(g for g, _ in aligned) / 8, 2),
            "after_extra_8B_each": round(sum(max(0.0, g / 8 - 8) for g, _ in aligned), 2),
            "after_extra_16B_each": round(sum(max(0.0, g / 8 - 16) for g, _ in aligned), 2),
            "best_ten": [(round(g / 8, 2), *details) for g, details in aligned[:10]],
            "warning": "Gross average child price and first-demand order are optimistic; actual native scheduling and marginal event costs require a wire trial",
        },
        "exact_child_sequences": screen_child_sequences(body_off, kids, order, delta_bytes, recent),
        "note": "Optimistic screen only: average native delta bytes do not give marginal savings for a particular splice. Actual definition scheduling, event prices, splice table cost, and complete frame still required",
    }


if __name__ == "__main__":
    graph = Path(sys.argv[1])
    frame = Path(sys.argv[2])
    print(json.dumps(screen(graph, frame), indent=2))
