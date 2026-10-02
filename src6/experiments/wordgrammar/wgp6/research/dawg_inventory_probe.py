#!/usr/bin/env python3
"""Charged inventory-size diagnostic: sorted front coding vs minimal DAFSA.

This compares two exact representations of the same byte-sorted type set.
The same first-use-ID Huffman payload is charged on both sides. A separate
bridge ledger prices a sorted-rank -> first-use-rank permutation required by
an integration that keeps the old lexical automaton's first-use naming.

No native frame is emitted. Raw model bytes and a common static byte-Huffman
packing are reported. A native class/bucket placement map remains a separate
integration cost and is not inferred here.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import math
import sys
from dataclasses import dataclass, field
from pathlib import Path

import lexical_factor_probe as lp


@dataclass
class Node:
    final: bool = False
    edges: dict[int, int] = field(default_factory=dict)


@dataclass
class CompactNode:
    final: bool = False
    edges: dict[bytes, int] = field(default_factory=dict)


def packed_byte_huffman(raw: bytes) -> dict[str, int]:
    """Pack bytes with an optimal static Huffman row and charge its table."""
    counts = [0] * 256
    for b in raw:
        counts[b] += 1
    lengths = lp.huffman_lengths(counts)
    bits = sum(n * length for n, length in zip(counts, lengths))
    # Canonical Huffman codes are identified by this complete 256-byte length
    # vector. Raw length makes the packed component independently parseable.
    header = 1 + len(lp.uleb(len(raw))) + 256
    payload = (bits + 7) // 8
    return {
        "header_bytes": header,
        "payload_bytes": payload,
        "total_bytes": header + payload,
        "huffman_payload_bits": bits,
    }


def minimize_sorted_words(words: list[bytes]) -> tuple[list[Node], list[int], list[int], int]:
    """Build a minimal acyclic DFA incrementally from sorted unique words.

    Returns states, child-before-parent topological order, accepted suffix
    path counts in old-state coordinates, and the root path count.
    """
    states = [Node()]
    register: dict[int, list[int]] = collections.defaultdict(list)
    previous = b""
    path = [0]

    def canonicalize(sid: int) -> int:
        node = states[sid]
        items = tuple(sorted(node.edges.items()))
        sig_hash = hash((node.final, items))
        for candidate in register.get(sig_hash, ()):
            other = states[candidate]
            if node.final == other.final and node.edges == other.edges:
                return candidate
        register[sig_hash].append(sid)
        return sid

    for word in words:
        shared = lp.lcp(previous, word)
        for depth in range(len(previous), shared, -1):
            sid = path[depth]
            target = canonicalize(sid)
            parent = path[depth - 1]
            states[parent].edges[previous[depth - 1]] = target

        path = path[: shared + 1]
        for byte in word[shared:]:
            child = len(states)
            states.append(Node())
            states[path[-1]].edges[byte] = child
            path.append(child)
        states[path[-1]].final = True
        previous = word

    # Finish the last word's open suffix. Keep the root as its own state.
    for depth in range(len(previous), 0, -1):
        sid = path[depth]
        target = canonicalize(sid)
        states[path[depth - 1]].edges[previous[depth - 1]] = target

    # Produce a deterministic postorder of the reachable DAG. The root is the
    # final ID, and all targets then have smaller IDs, so a target delta is a
    # compact, unambiguous serialized operand.
    order: list[int] = []
    seen: set[int] = set()
    stack: list[tuple[int, bool]] = [(0, False)]
    while stack:
        sid, expanded = stack.pop()
        if expanded:
            order.append(sid)
            continue
        if sid in seen:
            continue
        seen.add(sid)
        stack.append((sid, True))
        for _, target in reversed(sorted(states[sid].edges.items())):
            if target not in seen:
                stack.append((target, False))

    ways = [0] * len(states)
    for sid in order:
        node = states[sid]
        ways[sid] = int(node.final) + sum(ways[t] for t in node.edges.values())
    return states, order, ways, ways[0]


def serialize_dawg(states: list[Node], order: list[int]) -> bytes:
    """Serialize all graph structure, including state/arc counts and finals."""
    new_id = {old: i for i, old in enumerate(order)}
    arc_count = sum(len(states[sid].edges) for sid in order)
    out = bytearray()
    out.append(1)  # diagnostic graph serialization version
    out += lp.uleb(len(order))
    out += lp.uleb(arc_count)
    # Accepting-state bits are packed in topological order.
    finals = bytearray((len(order) + 7) // 8)
    for i, old in enumerate(order):
        if states[old].final:
            finals[i >> 3] |= 1 << (i & 7)
    out += finals
    for old in order:
        edges = sorted(states[old].edges.items())
        out += lp.uleb(len(edges))
        src = new_id[old]
        for label, target in edges:
            dst = new_id[target]
            if dst >= src:
                raise AssertionError("postorder target is not earlier than source")
            out.append(label)
            out += lp.uleb(src - dst)
    return bytes(out)


def path_compact(states: list[Node], order: list[int]) -> tuple[list[CompactNode], list[int], list[int], int]:
    """Merge nonfinal unary paths into byte-string arcs."""
    reachable = set(order)
    keep = {
        sid for sid in order
        if sid == 0 or states[sid].final or len(states[sid].edges) != 1
    }
    compact = [CompactNode() for _ in states]
    for sid in keep:
        compact[sid].final = states[sid].final
        for first, target in sorted(states[sid].edges.items()):
            label = bytearray((first,))
            cursor = target
            while cursor not in keep:
                node = states[cursor]
                if cursor not in reachable or node.final or len(node.edges) != 1:
                    raise AssertionError("invalid unary path during compaction")
                next_label, cursor = next(iter(node.edges.items()))
                label.append(next_label)
            compact[sid].edges[bytes(label)] = cursor

    compact_order: list[int] = []
    seen: set[int] = set()
    stack: list[tuple[int, bool]] = [(0, False)]
    while stack:
        sid, expanded = stack.pop()
        if expanded:
            compact_order.append(sid)
            continue
        if sid in seen:
            continue
        seen.add(sid)
        stack.append((sid, True))
        for _, target in reversed(sorted(compact[sid].edges.items())):
            if target not in seen:
                stack.append((target, False))

    ways = [0] * len(states)
    for sid in compact_order:
        ways[sid] = int(compact[sid].final) + sum(
            ways[target] for target in compact[sid].edges.values()
        )
    return compact, compact_order, ways, ways[0]


def serialize_compact_dawg(states: list[CompactNode], order: list[int]) -> bytes:
    """Serialize a path-compacted DAFSA with byte-string edge labels."""
    new_id = {old: i for i, old in enumerate(order)}
    arc_count = sum(len(states[sid].edges) for sid in order)
    out = bytearray((2,))  # path-compacted diagnostic graph version
    out += lp.uleb(len(order))
    out += lp.uleb(arc_count)
    finals = bytearray((len(order) + 7) // 8)
    for i, old in enumerate(order):
        if states[old].final:
            finals[i >> 3] |= 1 << (i & 7)
    out += finals
    for old in order:
        edges = sorted(states[old].edges.items())
        out += lp.uleb(len(edges))
        src = new_id[old]
        for label, target in edges:
            dst = new_id[target]
            if dst >= src:
                raise AssertionError("compacted target is not earlier than source")
            out += lp.uleb(len(label))
            out += label
            out += lp.uleb(src - dst)
    return bytes(out)


def validate_rank_order(words: list[bytes], states: list[Node], order: list[int], ways: list[int], n: int) -> None:
    """Unrank every accepted path and require exact sorted inventory equality."""
    new_id = {old: i for i, old in enumerate(order)}
    if ways[0] != n:
        raise AssertionError(f"root accepts {ways[0]} paths, expected {n}")
    # This diagnostic deliberately checks every rank: the rank mapping is part
    # of the codec contract, not just a graph-size estimate.
    for rank, expected in enumerate(words):
        sid = 0
        remaining = rank
        out = bytearray()
        while True:
            node = states[sid]
            if node.final:
                if remaining == 0:
                    break
                remaining -= 1
            chosen = None
            for label, target in sorted(node.edges.items()):
                count = ways[target]
                if remaining < count:
                    out.append(label)
                    chosen = target
                    break
                remaining -= count
            if chosen is None:
                raise AssertionError("rank escaped graph paths")
            sid = chosen
        if bytes(out) != expected:
            raise AssertionError(f"rank {rank} decoded incorrectly")
    # Keep use of topological IDs in the validation: this also catches stale
    # or unreachable state paths before serializing the candidate.
    if new_id[0] != len(order) - 1:
        raise AssertionError("root is not the final topological state")


def validate_compact_rank_order(words: list[bytes], states: list[CompactNode], order: list[int], ways: list[int], n: int) -> None:
    """Check that every compact-graph rank returns the byte-exact word."""
    if ways[0] != n:
        raise AssertionError(f"compacted root accepts {ways[0]} paths, expected {n}")
    new_id = {old: i for i, old in enumerate(order)}
    for rank, expected in enumerate(words):
        sid = 0
        remaining = rank
        out = bytearray()
        while True:
            node = states[sid]
            if node.final:
                if remaining == 0:
                    break
                remaining -= 1
            chosen = None
            for label, target in sorted(node.edges.items()):
                count = ways[target]
                if remaining < count:
                    out += label
                    chosen = target
                    break
                remaining -= count
            if chosen is None:
                raise AssertionError("rank escaped compact graph paths")
            sid = chosen
        if bytes(out) != expected:
            raise AssertionError(f"compacted rank {rank} decoded incorrectly")
    if new_id[0] != len(order) - 1:
        raise AssertionError("compacted root is not the final topological state")


def first_use_rank_map(inv: lp.Inventory) -> list[int]:
    """Return the decoder bridge: first-use rank -> sorted lexical rank."""
    sorted_to_first = [-1] * len(inv.names)
    first_to_sorted = [-1] * len(inv.names)
    next_rank = 0
    for lexical_rank in inv.token_ids:
        if sorted_to_first[lexical_rank] == -1:
            sorted_to_first[lexical_rank] = next_rank
            first_to_sorted[next_rank] = lexical_rank
            next_rank += 1
    if next_rank != len(first_to_sorted):
        raise AssertionError("some type has no first use")
    return first_to_sorted


def occurrence_source(inv: lp.Inventory) -> dict[str, int]:
    """Charge same first-use Huffman ID stream for both inventory models."""
    first_counts = [0] * len(inv.names)
    next_rank = 0
    sorted_to_first = [-1] * len(inv.names)
    first_to_sorted: list[int] = []
    for sorted_rank in inv.token_ids:
        if sorted_to_first[sorted_rank] == -1:
            sorted_to_first[sorted_rank] = next_rank
            first_to_sorted.append(sorted_rank)
            next_rank += 1
        first_counts[sorted_to_first[sorted_rank]] += 1
    lengths = lp.huffman_lengths(first_counts)
    bits = sum(c * length for c, length in zip(first_counts, lengths))
    id_header = len(lp.uleb(len(lengths))) + len(lengths)
    occurrence_header = 4 + len(lp.uleb(len(inv.token_ids))) + id_header
    return {
        "first_use_id_huffman_header_bytes": id_header,
        "occurrence_frame_header_bytes": 4 + len(lp.uleb(len(inv.token_ids))),
        "occurrence_payload_bytes": (bits + 7) // 8,
        "occurrence_payload_bits": bits,
        "shared_occurrence_source_bytes": occurrence_header + (bits + 7) // 8,
    }


def inventory_row(data: bytes, limit: int, source_name: str) -> dict:
    inv = lp.inventory(data, limit)
    frontcoded = bytearray()
    frontcoded += lp.uleb(len(inv.names))
    previous = b""
    for word in inv.names:
        prefix = lp.lcp(previous, word)
        suffix = word[prefix:]
        frontcoded += lp.uleb(prefix) + lp.uleb(len(suffix)) + suffix
        previous = word

    states, order, ways, graph_type_count = minimize_sorted_words(inv.names)
    validate_rank_order(inv.names, states, order, ways, len(inv.names))
    dawg_uncompacted = serialize_dawg(states, order)
    compact_states, compact_order, compact_ways, compact_type_count = path_compact(states, order)
    validate_compact_rank_order(inv.names, compact_states, compact_order, compact_ways, len(inv.names))
    dawg = serialize_compact_dawg(compact_states, compact_order)
    if graph_type_count != len(inv.names):
        raise AssertionError("DAFSA cardinality mismatch")
    if compact_type_count != len(inv.names):
        raise AssertionError("path-compacted DAFSA cardinality mismatch")

    shared_occ = occurrence_source(inv)
    direct_raw = bytes(frontcoded)
    graph_raw = dawg
    direct_pack = packed_byte_huffman(direct_raw)
    graph_pack = packed_byte_huffman(graph_raw)

    mapping = first_use_rank_map(inv)
    map_raw = b"".join(lp.uleb(rank) for rank in mapping)
    map_pack = packed_byte_huffman(map_raw)

    raw_common = shared_occ["shared_occurrence_source_bytes"]
    direct_raw_total = raw_common + len(direct_raw)
    graph_raw_total = raw_common + len(graph_raw)
    direct_pack_total = raw_common + direct_pack["total_bytes"]
    graph_pack_total = raw_common + graph_pack["total_bytes"]
    direct_raw_mapped = direct_raw_total + len(map_raw)
    graph_raw_mapped = graph_raw_total + len(map_raw)
    direct_pack_mapped = direct_pack_total + map_pack["total_bytes"]
    graph_pack_mapped = graph_pack_total + map_pack["total_bytes"]
    graph_raw_with_bridge_vs_sorted = raw_common + len(graph_raw) + len(map_raw)
    graph_pack_with_bridge_vs_sorted = raw_common + graph_pack["total_bytes"] + map_pack["total_bytes"]

    return {
        "source": source_name,
        "limit_bytes": limit,
        "input_sha256_prefix": hashlib.sha256(data[:limit]).hexdigest(),
        "inventory": {
            "types": len(inv.names),
            "occurrences": len(inv.token_ids),
            "letter_run_type_bytes": sum(map(len, inv.names)),
            "invalid_utf8_types": inv.invalid_utf8_types,
            "types_over_64_codepoints": inv.long_types,
        },
        "dawg": {
            "representation": "path-compacted labeled arcs; nonfinal unary states omitted",
            "states": len(compact_order),
            "arcs": sum(len(compact_states[sid].edges) for sid in compact_order),
            "raw_model_bytes": len(graph_raw),
            "packed_model": graph_pack,
            "root_path_count": compact_type_count,
            "uncompacted_audit": {
                "states": len(order),
                "arcs": sum(len(states[sid].edges) for sid in order),
                "raw_model_bytes": len(dawg_uncompacted),
                "packed_model": packed_byte_huffman(dawg_uncompacted),
            },
        },
        "frontcoded": {
            "raw_model_bytes": len(direct_raw),
            "packed_model": direct_pack,
        },
        "shared_occurrence_source": shared_occ,
        "first_use_bridge": {
            "description": "decoder bridge: first-use-rank -> sorted lexical-rank permutation, shared by both inventory representations",
            "raw_uleb_vector_bytes": len(map_raw),
            "packed_static_byte_huffman": map_pack,
            "native_class_bucket_placement": "not priced; requires native plan/frame integration",
        },
        "totals_with_same_first_use_id_payload": {
            "frontcoded_raw_bytes": direct_raw_total,
            "dawg_raw_bytes": graph_raw_total,
            "dawg_minus_frontcoded_raw_bytes": graph_raw_total - direct_raw_total,
            "frontcoded_byte_huffman_bytes": direct_pack_total,
            "dawg_byte_huffman_bytes": graph_pack_total,
            "dawg_minus_frontcoded_byte_huffman_bytes": graph_pack_total - direct_pack_total,
        },
        "totals_with_first_use_bridge": {
            "frontcoded_raw_bytes": direct_raw_mapped,
            "dawg_raw_bytes": graph_raw_mapped,
            "dawg_minus_frontcoded_raw_bytes": graph_raw_mapped - direct_raw_mapped,
            "frontcoded_byte_huffman_bytes": direct_pack_mapped,
            "dawg_byte_huffman_bytes": graph_pack_mapped,
            "dawg_minus_frontcoded_byte_huffman_bytes": graph_pack_mapped - direct_pack_mapped,
        },
        "dawg_bridge_charged_only_against_sorted_rank_control": {
            "frontcoded_sorted_rank_raw_bytes": direct_raw_total,
            "dawg_plus_first_use_bridge_raw_bytes": graph_raw_with_bridge_vs_sorted,
            "dawg_plus_bridge_minus_sorted_frontcoded_raw_bytes": graph_raw_with_bridge_vs_sorted - direct_raw_total,
            "frontcoded_sorted_rank_byte_huffman_bytes": direct_pack_total,
            "dawg_plus_first_use_bridge_byte_huffman_bytes": graph_pack_with_bridge_vs_sorted,
            "dawg_plus_bridge_minus_sorted_frontcoded_byte_huffman_bytes": graph_pack_with_bridge_vs_sorted - direct_pack_total,
        },
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    root = Path("/workspace/dict/src6/experiments/bzip4/language_frontier/evidence/runs/storage-screen-auto-20260926-strict/samples")
    ap.add_argument("--freedict", type=Path, default=root / "freedict-eval8-end-to-end/external-decoded.bin")
    ap.add_argument("--gcide", type=Path, default=root / "gcide-eval8-end-to-end/external-decoded.bin")
    ap.add_argument("--omw", type=Path, default=root / "omw-eval8-end-to-end/external-decoded.bin")
    ap.add_argument("--sizes", type=int, nargs="+", default=[1 << 20, 8 << 20])
    ap.add_argument("--output", type=Path)
    args = ap.parse_args()

    rows = []
    for name in ("freedict", "gcide", "omw"):
        path: Path = getattr(args, name)
        data = path.read_bytes()
        for limit in args.sizes:
            print(f"building {name} {limit} bytes", file=sys.stderr, flush=True)
            rows.append(inventory_row(data, limit, name))
    result = {
        "purpose": "sorted exact type inventory: front coding vs minimal DAFSA",
        "status": "diagnostic only; no native frame or complete class/bucket mapping claim",
        "backend": "same optimal static byte-Huffman packing of each serialized inventory/map component; code-length vector and raw component length charged",
        "occurrence_backend": "same static Huffman type-ID source by first-use order on both sides",
        "rows": rows,
    }
    encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded)
    print(encoded, end="")


if __name__ == "__main__":
    main()
