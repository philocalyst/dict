#!/usr/bin/env python3
"""Exact two-whole-word-slot skeleton density, source-only diagnostic.

Each slot is one complete Unicode word run. Fixed ordered anchors surround
and separate them. The unigram proxy cancels the two slot IDs against the
same IDs in its baseline, then charges anchor-token surprisal, template-ID
events, geometry and fixed anchor IDs. It is optimistic relative to a native
M frame and is never a compressed-size result.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import math
from pathlib import Path

from probe import PAGE, tokenize

SHAPES = ((2, 2, 4), (2, 2, 6), (2, 2, 8))


def discover(raw: bytes, inventory: int = 1024) -> dict:
    ids: dict[bytes, int] = {}
    spellings: list[bytes] = []
    token_kinds: list[str] = []
    counts: collections.Counter[int] = collections.Counter()
    pages: list[tuple[list[int], list[str]]] = []
    for start in range(0, len(raw), PAGE):
        seq, kinds = [], []
        for surface, kind in tokenize(raw[start:start + PAGE]):
            if surface not in ids:
                ids[surface] = len(spellings)
                spellings.append(surface)
                token_kinds.append(kind)
            n = ids[surface]
            seq.append(n)
            kinds.append(kind)
            counts[n] += 1
        pages.append((seq, kinds))
    total_tokens = sum(len(seq) for seq, _ in pages)
    vocab = len(spellings)
    id_bits = math.ceil(math.log2(max(2, vocab)))
    event_bits = math.ceil(math.log2(max(2, inventory + 1))) + 1
    token_bits = [-math.log2((counts[t] + 1) / (total_tokens + vocab)) for t in range(vocab)]

    groups: dict[tuple, list[tuple[int, int]]] = collections.defaultdict(list)
    for page, (seq, kinds) in enumerate(pages):
        for slot1, kind in enumerate(kinds):
            if kind != "w":
                continue
            for left, right, distance in SHAPES:
                slot2 = slot1 + distance
                if slot1 < left or slot2 + right >= len(seq) or kinds[slot2] != "w":
                    continue
                fixed = (*seq[slot1 - left:slot1], *seq[slot1 + 1:slot2], *seq[slot2 + 1:slot2 + right + 1])
                key = (left, right, distance, *fixed)
                uses = groups[key]
                if len(uses) < 4096:
                    uses.append((page, slot1))

    candidates = []
    for key, uses in groups.items():
        if len(uses) < 2:
            continue
        left, right, distance = key[:3]
        values1 = {pages[p][0][slot1] for p, slot1 in uses}
        values2 = {pages[p][0][slot1 + distance] for p, slot1 in uses}
        if len(values1) < 2 or len(values2) < 2:
            continue
        fixed = key[3:]
        if sum(token_kinds[t] == "w" for t in fixed) < 2:
            continue
        anchor_bits = sum(token_bits[t] for t in fixed)
        table_bits = len(fixed) * id_bits + 3 * 8
        possible = len(uses) * (anchor_bits - event_bits) - table_bits
        if possible > 0:
            candidates.append((possible, key, uses, anchor_bits, table_bits))
    candidates.sort(key=lambda x: (-x[0], x[1]))
    occupied = [bytearray(len(seq)) for seq, _ in pages]
    selected = []
    saving_bits = 0.0
    anchor_raw_bytes = 0
    for _, key, uses, anchor_bits, table_bits in candidates:
        left, right, distance = key[:3]
        accepted = []
        for page, slot1 in uses:
            begin, end = slot1 - left, slot1 + distance + right + 1
            if any(occupied[page][begin:end]):
                continue
            accepted.append((page, slot1))
        gain = len(accepted) * (anchor_bits - event_bits) - table_bits
        if len(accepted) < 2 or gain <= 0:
            continue
        for page, slot1 in accepted:
            begin, end = slot1 - left, slot1 + distance + right + 1
            occupied[page][begin:end] = b"\x01" * (end - begin)
        raw_per = sum(len(spellings[t]) for t in key[3:])
        anchor_raw_bytes += len(accepted) * raw_per
        saving_bits += gain
        selected.append({
            "uses": len(accepted),
            "left": left,
            "right": right,
            "slot_distance": distance,
            "span_tokens": left + distance + right + 1,
            "distinct_slot1": len({pages[p][0][slot1] for p, slot1 in accepted}),
            "distinct_slot2": len({pages[p][0][slot1 + distance] for p, slot1 in accepted}),
            "anchor_raw_bytes_per_use": raw_per,
            "anchor_unigram_bits_per_use": round(anchor_bits, 4),
            "table_bits": table_bits,
            "proxy_saved_bytes": round(gain / 8, 4),
            "fixed_hex": [spellings[t].hex() for t in key[3:]],
        })
        if len(selected) == inventory:
            break
    return {
        "source_sha256": hashlib.sha256(raw).hexdigest(),
        "source_bytes": len(raw),
        "pages": len(pages),
        "tokens": total_tokens,
        "distinct_tokens": vocab,
        "candidate_groups": len(candidates),
        "selected_templates": len(selected),
        "raw_anchor_ceiling_bytes": anchor_raw_bytes,
        "id_bits": id_bits,
        "event_bits": event_bits,
        "model_allowance_bytes": 128,
        "mode_selector_bytes": 1,
        "unigram_proxy_saved_bytes": round(saving_bits / 8 - 129, 4),
        "warning": "Source-only optimistic proxy, not a frame: exact full-word slots, static unigram baseline, slot price assumed to cancel, fixed allowance for rows.",
        "top_templates": selected[:20],
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("source", type=Path)
    ap.add_argument("--inventory", type=int, default=1024)
    ns = ap.parse_args()
    print(json.dumps(discover(ns.source.read_bytes(), ns.inventory), separators=(",", ":")))


if __name__ == "__main__":
    main()
