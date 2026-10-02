#!/usr/bin/env python3
"""Cheap, exact-byte accounting probe for a stem × tail-class source.

This is a type-inventory diagnostic, not a WGP6 frame or a claim about an
entropy backend.  It scans WGP's letter-run atoms, builds a front-coded
literal-inventory control, then compares a productive source that emits a
stem symbol and a class-conditioned tail-signature symbol for every
occurrence.  No word IDs, occupied word-pair list, or first-use permutation
are sent by the candidate.

All strings are preserved byte-for-byte.  Candidate split points are valid
UTF-8 codepoint boundaries; malformed and overlong atoms stay literal
identity stems.  There is no Unicode normalization or external vocabulary.
"""

from __future__ import annotations

import argparse
import collections
import heapq
import json
import math
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

TOKEN_RE = re.compile(rb"[A-Za-z\x80-\xff]+")


def uleb(n: int) -> bytes:
    if n < 0:
        raise ValueError("negative ULEB")
    out = bytearray()
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


def lcp(a: bytes, b: bytes) -> int:
    n = min(len(a), len(b))
    i = 0
    while i < n and a[i] == b[i]:
        i += 1
    return i


def huffman_lengths(counts: list[int]) -> list[int]:
    """Deterministic optimal binary Huffman lengths; a singleton costs 1 bit."""
    ids = [i for i, c in enumerate(counts) if c]
    if not ids:
        return [0] * len(counts)
    if len(ids) == 1:
        out = [0] * len(counts)
        out[ids[0]] = 1
        return out
    heap: list[tuple[int, int, int]] = []
    left: list[int] = []
    right: list[int] = []
    for i in ids:
        heapq.heappush(heap, (counts[i], i, -(i + 1)))
    serial = len(counts)
    while len(heap) > 1:
        ca, _, a = heapq.heappop(heap)
        cb, _, b = heapq.heappop(heap)
        node = len(left)
        left.append(a)
        right.append(b)
        heapq.heappush(heap, (ca + cb, serial, node))
        serial += 1
    root = heap[0][2]
    out = [0] * len(counts)
    stack = [(root, 0)]
    while stack:
        node, depth = stack.pop()
        if node < 0:
            out[-node - 1] = depth
        else:
            stack.append((right[node], depth + 1))
            stack.append((left[node], depth + 1))
    return out


def shannon_bits(counts: Iterable[int]) -> float:
    vals = [x for x in counts if x]
    total = sum(vals)
    return sum(x * math.log2(total / x) for x in vals)


@dataclass
class Inventory:
    names: list[bytes]
    counts: list[int]
    ids: dict[bytes, int]
    token_ids: list[int]
    raw_bytes: int
    invalid_utf8_types: int
    long_types: int


def inventory(data: bytes, limit: int) -> Inventory:
    data = data[:limit]
    freq: collections.Counter[bytes] = collections.Counter()
    token_ids_by_occurrence: list[bytes] = []
    for m in TOKEN_RE.finditer(data):
        word = m.group(0)
        freq[word] += 1
        token_ids_by_occurrence.append(word)
    names = sorted(freq)
    ids = {w: i for i, w in enumerate(names)}
    counts = [freq[w] for w in names]
    invalid = 0
    long = 0
    for w in names:
        try:
            text = w.decode("utf-8", "strict")
        except UnicodeDecodeError:
            invalid += 1
            continue
        if len(text) > 64:
            long += 1
    return Inventory(
        names=names,
        counts=counts,
        ids=ids,
        token_ids=[ids[w] for w in token_ids_by_occurrence],
        raw_bytes=len(data),
        invalid_utf8_types=invalid,
        long_types=long,
    )


def literal_inventory_cost(names: list[bytes]) -> dict[str, int]:
    literal = len(uleb(len(names)))
    prev = b""
    for w in names:
        n = lcp(prev, w)
        suffix = w[n:]
        literal += len(uleb(n)) + len(uleb(len(suffix))) + len(suffix)
        prev = w
    return {"count_and_front_coded_literals": literal}


def frontcoded_records(records: list[bytes]) -> int:
    """Count a sorted byte-string table using the same LCP+suffix scheme."""
    out = len(uleb(len(records)))
    previous = b""
    for record in records:
        shared = lcp(previous, record)
        suffix = record[shared:]
        out += len(uleb(shared)) + len(uleb(len(suffix))) + len(suffix)
        previous = record
    return out


def raw_records(records: list[bytes]) -> int:
    return len(uleb(len(records))) + sum(_model_string(record) for record in records)


def make_splits(inv: Inventory, max_root: int = 12) -> tuple[list[tuple[bytes, tuple[bytes, bytes]]], dict[str, int]]:
    """Select a shared contiguous core for each valid short UTF-8 atom.

    First pass counts the number of distinct lexical types containing each
    proper codepoint-aligned substring of 2..max_root codepoints.  Each type
    then chooses the candidate with the largest byte-weighted support score;
    score = core_bytes * (support-1)/support.  Equal scores prefer more
    support, then a longer core, then bytewise lexical order.  A nonpositive
    score stays as an identity stem with empty prefix/suffix.

    The heuristic is intentionally fixed and inspectable.  It does not use
    target-codec feedback or a per-corpus parameter search.
    """
    decoded: list[tuple[str, ...] | None] = []
    subcount: collections.Counter[str] = collections.Counter()
    for w in inv.names:
        try:
            cp = tuple(w.decode("utf-8", "strict"))
        except UnicodeDecodeError:
            decoded.append(None)
            continue
        if len(cp) > 64:
            decoded.append(None)
            continue
        decoded.append(cp)
        seen: set[str] = set()
        n = len(cp)
        for i in range(n):
            hi = min(n, i + max_root)
            for j in range(i + 2, hi + 1):
                if j - i == n:
                    continue
                seen.add("".join(cp[i:j]))
        subcount.update(seen)

    result: list[tuple[bytes, tuple[bytes, bytes]]] = []
    factored = 0
    for w, cp in zip(inv.names, decoded):
        if cp is None:
            result.append((w, (b"", b"")))
            continue
        best: tuple[float, int, int, bytes, bytes, bytes] | None = None
        n = len(cp)
        for i in range(n):
            hi = min(n, i + max_root)
            for j in range(i + 2, hi + 1):
                if j - i == n:
                    continue
                core = "".join(cp[i:j])
                support = subcount[core]
                if support < 2:
                    continue
                core_b = core.encode("utf-8")
                pre_b = "".join(cp[:i]).encode("utf-8")
                suf_b = "".join(cp[j:]).encode("utf-8")
                score = len(core_b) * (support - 1) / support
                key = (score, support, len(core_b), bytes(255 - b for b in core_b), pre_b, suf_b)
                if best is None or key > best:
                    best = key
                    chosen = (core_b, (pre_b, suf_b))
        if best is not None and best[0] > 0:
            result.append(chosen)
            factored += 1
        else:
            result.append((w, (b"", b"")))
    return result, {"factored_types": factored, "candidate_substrings": len(subcount)}


def _model_string(s: bytes) -> int:
    return len(uleb(len(s))) + len(s)


def direct_source(inv: Inventory) -> dict:
    table = literal_inventory_cost(inv.names)["count_and_front_coded_literals"]
    hlen = huffman_lengths(inv.counts)
    huff_header = len(uleb(len(hlen))) + len(hlen)
    bits = sum(c * l for c, l in zip(inv.counts, hlen))
    operand_raw = sum(len(uleb(i)) * inv.counts[i] for i in range(len(inv.names)))
    model = 4 + len(uleb(len(inv.token_ids))) + table + huff_header
    payload = (bits + 7) // 8
    return {
        "model_bytes": model,
        "payload_bytes": payload,
        "total_bytes": model + payload,
        "huffman_payload_bits": bits,
        "raw_uleb_operand_bytes": operand_raw,
        "shannon_type_id_bits": shannon_bits(inv.counts),
        "model_components": {
            "frame_and_occurrence_count": 4 + len(uleb(len(inv.token_ids))),
            "front_coded_type_literals": table,
            "word_id_huffman_lengths": huff_header,
        },
    }


def factor_source(inv: Inventory, splits: list[tuple[bytes, tuple[bytes, bytes]]], class_mode: str, literal_mode: str) -> dict:
    stems = sorted({s for s, _ in splits})
    signatures = sorted({sig for _, sig in splits})
    stem_id = {s: i for i, s in enumerate(stems)}
    sig_id = {s: i for i, s in enumerate(signatures)}
    stem_freq = [0] * len(stems)
    sig_freq_by_stem: list[collections.Counter[int]] = [collections.Counter() for _ in stems]
    for i, ((stem, sig), count) in enumerate(zip(splits, inv.counts)):
        si, ti = stem_id[stem], sig_id[sig]
        stem_freq[si] += count
        sig_freq_by_stem[si][ti] += count

    if class_mode == "one":
        class_keys = {s: (0,) for s in range(len(stems))}
    elif class_mode == "top1":
        class_keys = {
            s: (min(c.items(), key=lambda x: (-x[1], signatures[x[0]]))[0],)
            for s, c in enumerate(sig_freq_by_stem)
        }
    elif class_mode == "top2":
        class_keys = {
            s: tuple(t for t, _ in sorted(c.items(), key=lambda x: (-x[1], signatures[x[0]]))[:2])
            for s, c in enumerate(sig_freq_by_stem)
        }
    else:
        raise ValueError(class_mode)

    key_to_stems: dict[tuple[int, ...], list[int]] = collections.defaultdict(list)
    for s in range(len(stems)):
        key_to_stems[class_keys[s]].append(s)
    class_groups = sorted(key_to_stems.items(), key=lambda kv: (kv[0], kv[1][0]))
    stem_class = [0] * len(stems)
    for ci, (_, members) in enumerate(class_groups):
        for s in members:
            stem_class[s] = ci

    class_supports: list[list[int]] = []
    class_counts: list[collections.Counter[int]] = []
    for _, members in class_groups:
        counts: collections.Counter[int] = collections.Counter()
        for s in members:
            counts.update(sig_freq_by_stem[s])
        class_counts.append(counts)
        class_supports.append(sorted(counts, key=lambda t: signatures[t]))

    # Serialize a self-contained model: literal stem and signature tables,
    # class support sets, stem->class map, then all canonical Huffman lengths.
    frame = 4 + len(uleb(len(inv.token_ids)))
    if literal_mode == "raw":
        stem_literals = raw_records(stems)
        signature_records = [uleb(len(pre)) + pre + uleb(len(suf)) + suf for pre, suf in signatures]
        sig_literals = raw_records(signature_records)
    elif literal_mode == "frontcoded":
        stem_literals = frontcoded_records(stems)
        signature_records = [uleb(len(pre)) + pre + uleb(len(suf)) + suf for pre, suf in signatures]
        sig_literals = frontcoded_records(signature_records)
    else:
        raise ValueError(literal_mode)
    class_map = len(uleb(len(stem_class))) + sum(len(uleb(c)) for c in stem_class)
    support_bytes = len(uleb(len(class_groups)))
    tail_lengths: list[dict[int, int]] = []
    tail_bits = 0
    tail_raw_operands = 0
    support_pairs = 0
    observed_pairs = 0
    h_t_given_class = 0.0
    h_t_given_stem = 0.0
    for s, row in enumerate(sig_freq_by_stem):
        h_t_given_stem += shannon_bits(row.values())
    for ci, (support, counts) in enumerate(zip(class_supports, class_counts)):
        support_bytes += len(uleb(len(support)))
        for t in support:
            support_bytes += len(uleb(t))
        ordered_counts = [counts[t] for t in support]
        lens = huffman_lengths(ordered_counts)
        tail_lengths.append(dict(zip(support, lens)))
        support_bytes += len(uleb(len(lens))) + len(lens)
        tail_bits += sum(c * l for c, l in zip(ordered_counts, lens))
        h_t_given_class += shannon_bits(ordered_counts)
        local = {t: i for i, t in enumerate(support)}
        # The raw ULEB operand ledger is exact, even though the actual priced
        # payload uses the rows above.
        for t, c in counts.items():
            tail_raw_operands += c * len(uleb(local[t]))
        members = class_groups[ci][1]
        support_pairs += len(members) * len(support)
        observed_pairs += sum(len(sig_freq_by_stem[s]) for s in members)

    stem_lengths = huffman_lengths(stem_freq)
    stem_huff_header = len(uleb(len(stem_lengths))) + len(stem_lengths)
    stem_bits = sum(c * l for c, l in zip(stem_freq, stem_lengths))
    total_bits = stem_bits + tail_bits
    payload = (total_bits + 7) // 8
    model = frame + stem_literals + sig_literals + class_map + support_bytes + stem_huff_header

    raw_stem_operands = 0
    for s, count in enumerate(stem_freq):
        raw_stem_operands += count * len(uleb(s))
    raw_pair_operands = raw_stem_operands + tail_raw_operands
    observed_type_pairs = len(splits)
    possible_type_pairs = support_pairs
    return {
        "mode": class_mode,
        "literal_mode": literal_mode,
        "model_bytes": model,
        "payload_bytes": payload,
        "total_bytes": model + payload,
        "huffman_payload_bits": total_bits,
        "stem_operand_bits": stem_bits,
        "tail_operand_bits": tail_bits,
        "raw_uleb_operand_bytes": raw_pair_operands,
        "shannon_stem_bits": shannon_bits(stem_freq),
        "shannon_tail_given_stem_bits": h_t_given_stem,
        "shannon_tail_given_class_bits": h_t_given_class,
        "conditional_penalty_bits": h_t_given_class - h_t_given_stem,
        "conditional_penalty_bits_per_occurrence": (h_t_given_class - h_t_given_stem) / len(inv.token_ids) if inv.token_ids else 0.0,
        "model_components": {
            "frame_and_occurrence_count": frame,
            "stem_literals": stem_literals,
            "signature_literals": sig_literals,
            "stem_to_class_map": class_map,
            "class_support_and_tail_code_lengths": support_bytes,
            "stem_id_huffman_lengths": stem_huff_header,
        },
        "inventory": {
            "stems": len(stems),
            "tail_signatures": len(signatures),
            "classes": len(class_groups),
            "observed_stem_tail_types": observed_type_pairs,
            "supported_stem_tail_pairs": possible_type_pairs,
            "unobserved_generated_pairs": possible_type_pairs - observed_type_pairs,
            "observed_fraction_of_class_support": (observed_pairs / possible_type_pairs) if possible_type_pairs else 0,
        },
    }


def run_one(path: Path, limit: int) -> dict:
    data = path.read_bytes()[:limit]
    inv = inventory(data, len(data))
    splits, split_stats = make_splits(inv)
    base = direct_source(inv)
    candidates = [factor_source(inv, splits, mode, literal_mode)
                  for mode in ("one", "top1", "top2")
                  for literal_mode in ("raw", "frontcoded")]
    best = min(candidates, key=lambda x: x["total_bytes"])
    return {
        "input": str(path),
        "input_bytes": len(data),
        "input_sha256": __import__("hashlib").sha256(data).hexdigest(),
        "type_inventory": {
            "types": len(inv.names),
            "occurrences": len(inv.token_ids),
            "surface_bytes": sum(map(len, inv.names)),
            "invalid_utf8_types_kept_as_identity": inv.invalid_utf8_types,
            "over_64_codepoint_types_kept_as_identity": inv.long_types,
            **split_stats,
        },
        "direct_front_coded_control": base,
        "factorized_candidates": candidates,
        "best_factorized_mode": best["mode"],
        "best_factorized_literal_mode": best["literal_mode"],
        "best_factorized_delta_bytes": best["total_bytes"] - base["total_bytes"],
        "factorized_model_saving_bytes": base["model_bytes"] - best["model_bytes"],
        "factorized_payload_delta_bytes": best["payload_bytes"] - base["payload_bytes"],
        "factorized_huffman_payload_delta_bits": best["huffman_payload_bits"] - base["huffman_payload_bits"],
        "ratio_factorized_to_direct": best["total_bytes"] / base["total_bytes"] if base["total_bytes"] else 0,
        "scope_note": "Exact counted diagnostic model and Huffman operands over letter-run type inventory; not a codec frame. Non-letter atoms and surrounding structure are common and omitted.",
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("inputs", nargs="+", type=Path)
    ap.add_argument("--bytes", type=int, default=8 << 20)
    ap.add_argument("--json", type=Path)
    args = ap.parse_args()
    rows = [run_one(p, args.bytes) for p in args.inputs]
    out = {"schema": "wgp6-lexical-factor-probe-1", "limit_bytes": args.bytes, "rows": rows}
    payload = json.dumps(out, indent=2, sort_keys=True) + "\n"
    if args.json:
        args.json.write_text(payload)
    print(payload, end="")


if __name__ == "__main__":
    main()
