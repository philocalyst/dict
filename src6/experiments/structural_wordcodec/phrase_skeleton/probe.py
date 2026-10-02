#!/usr/bin/env python3
"""Source-only discovery diagnostic for exact one-slot phrase skeletons.

This is intentionally not a compressed frame or a codec result. It finds
repeated ordered anchors around variable whole-word slots. It charges a
literal template table and event tags but grants the slot values zero bits,
and charges the replaced fixed anchors their full original byte length.
Consequently `optimistic_saved` is an optimistic score for the *specified*
literal-table wire, not a codec result or a universal upper bound. Native M
often codes those fixed bytes for far less than their raw size. The separate
`raw_anchor_ceiling` is an upper bound on direct fixed-byte removal before
all wire costs, but it too says nothing about savings over native M.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import math
import pathlib
import unicodedata

PAGE = 65536
MAX_TOKEN = 96
MAX_CANDIDATES = 256
SHAPES = ((2, 2), (2, 4), (4, 2), (4, 4), (2, 6), (6, 2), (6, 6))


def varint_bytes(n: int) -> int:
    out = 1
    while n >= 128:
        n >>= 7
        out += 1
    return out


def char_bytes(c: str) -> bytes:
    return c.encode("utf-8", "surrogateescape")


def kind(c: str) -> str:
    cat = unicodedata.category(c)
    if cat[0] in "LNM":
        return "w"
    if c.isspace():
        return "s"
    return "x"


def tokenize(raw: bytes, scalar_words: bool = False) -> list[tuple[bytes, str]]:
    """Exact, page-local UTF-8 scalar tokenization with malformed-byte fallback."""
    chars = raw.decode("utf-8", "surrogateescape")
    out: list[tuple[bytes, str]] = []
    part = bytearray()
    previous = ""
    for c in chars:
        data = char_bytes(c)
        k = kind(c)
        grouped = k == "s" or (k == "w" and not scalar_words)
        if part and (k != previous or not grouped or len(part) + len(data) > MAX_TOKEN):
            out.append((bytes(part), previous))
            part.clear()
        part.extend(data)
        previous = k
    if part:
        out.append((bytes(part), previous))
    assert b"".join(t for t, _ in out) == raw
    return out


def discover(raw: bytes, max_candidates: int = MAX_CANDIDATES, scalar_words: bool = False) -> dict:
    ids: dict[bytes, int] = {}
    spellings: list[bytes] = []
    token_kinds: list[str] = []
    pages: list[tuple[list[int], list[str]]] = []
    total_tokens = 0
    token_counts: collections.Counter[int] = collections.Counter()
    for at in range(0, len(raw), PAGE):
        tok = tokenize(raw[at : at + PAGE], scalar_words)
        seq = []
        ks = []
        for word, k in tok:
            n = ids.get(word)
            if n is None:
                n = len(spellings)
                ids[word] = n
                spellings.append(word)
                token_kinds.append(k)
            seq.append(n)
            ks.append(k)
            token_counts[n] += 1
        pages.append((seq, ks))
        total_tokens += len(seq)

    # Keyed by the exact ordered token IDs on both sides of one word slot.
    groups: dict[tuple, list[tuple[int, int]]] = collections.defaultdict(list)
    for page, (seq, ks) in enumerate(pages):
        for slot, k in enumerate(ks):
            if k != "w":
                continue
            for left, right in SHAPES:
                if slot < left or slot + right >= len(seq):
                    continue
                key = (left, right, *seq[slot - left : slot], *seq[slot + 1 : slot + 1 + right])
                uses = groups[key]
                if len(uses) < 4096:
                    uses.append((page, slot))

    vocab = len(spellings)
    id_bits = math.ceil(math.log2(max(2, vocab)))
    event_bits = math.ceil(math.log2(max(2, max_candidates + 1))) + 1
    token_bits = [
        -math.log2((token_counts[i] + 1) / (total_tokens + vocab))
        for i in range(vocab)
    ]
    candidates = []
    for key, uses in groups.items():
        if len(uses) < 2:
            continue
        left, right = key[:2]
        variants = {pages[p][0][slot] for p, slot in uses}
        if len(variants) < 2:
            continue
        fixed = key[2:]
        if sum(token_kinds[t] == "w" for t in fixed) < 2:
            continue
        fixed_bytes = sum(len(spellings[t]) for t in fixed)
        if fixed_bytes < 8:
            continue
        # Explicit hypothetical wire: a byte-count and raw bytes for each
        # anchor token, both slot offsets, and a one-byte candidate-count tag.
        table_bytes = sum(varint_bytes(len(spellings[t])) + len(spellings[t]) for t in fixed)
        table_bytes += varint_bytes(left) + varint_bytes(right) + 1
        # Evenly split 16-bit event ID is conservative for <=256 selected
        # patterns; no entropy gain for a frequent pattern is assumed here.
        event_bytes = 2
        # Upper bound grants every slot ID/byte/definition and all page
        # entropy tables for free, and pretends anchors otherwise cost raw.
        optimistic = len(uses) * (fixed_bytes - event_bytes) - table_bytes
        anchor_bits = sum(token_bits[t] for t in fixed)
        id_table_bits = len(fixed) * id_bits + 8 * (varint_bytes(left) + varint_bytes(right) + 1)
        entropy_proxy = len(uses) * (anchor_bits - event_bits) - id_table_bits
        if optimistic <= 0 and entropy_proxy <= 0:
            continue
        candidates.append((optimistic, entropy_proxy, key, uses, fixed_bytes, table_bytes, anchor_bits, id_table_bits))

    def select(pricing: str) -> tuple[list[dict], float, int]:
        rank = 0 if pricing == "raw" else 1
        ordered = sorted(candidates, key=lambda x: (-x[rank], x[2]))
        occupied = [bytearray(len(seq)) for seq, _ in pages]
        selected: list[dict] = []
        total = 0.0
        raw_anchor_ceiling = 0
        for _, _, key, uses, fixed_bytes, table_bytes, anchor_bits, id_table_bits in ordered:
            left, right = key[:2]
            accepted = []
            for p, slot in uses:
                start, stop = slot - left, slot + right + 1
                if any(occupied[p][start:stop]):
                    continue
                accepted.append((p, slot))
            saving = (len(accepted) * (fixed_bytes - 2) - table_bytes) if pricing == "raw" else (
                (len(accepted) * (anchor_bits - event_bits) - id_table_bits) / 8
            )
            if saving <= 0 or len(accepted) < 2:
                continue
            for p, slot in accepted:
                occupied[p][slot - left : slot + right + 1] = b"\x01" * (left + right + 1)
            selected.append(
                {
                    "left_tokens": left,
                    "right_tokens": right,
                    "uses": len(accepted),
                    "distinct_slot_values": len({pages[p][0][slot] for p, slot in accepted}),
                    "fixed_bytes_per_use": fixed_bytes,
                    "fixed_word_anchors": sum(token_kinds[t] == "w" for t in key[2:]),
                    "literal_table_bytes": table_bytes,
                    "id_table_bits": id_table_bits,
                    "anchor_unigram_bits_per_use": round(anchor_bits, 4),
                    "diagnostic_saved_bytes": round(saving, 4),
                    "anchors_hex": [spellings[t].hex() for t in key[2:]],
                }
            )
            total += saving
            raw_anchor_ceiling += len(accepted) * fixed_bytes
            if len(selected) >= max_candidates:
                break
        return selected, total, raw_anchor_ceiling

    raw_selected, raw_saved, raw_ceiling = select("raw")
    entropy_selected, entropy_saved, entropy_ceiling = select("entropy")
    return {
        "source_sha256": hashlib.sha256(raw).hexdigest(),
        "source_bytes": len(raw),
        "segmentation": "scalars" if scalar_words else "runs",
        "pages": len(pages),
        "tokens": total_tokens,
        "distinct_tokens": len(spellings),
        "candidate_groups": len(candidates),
        "selected_templates": len(raw_selected),
        "mode_selector_bytes": 1,
        "optimistic_saved_bytes": round(raw_saved - 1, 4),
        "optimistic_saved_pct_raw": round(100 * (raw_saved - 1) / max(1, len(raw)), 5),
        "raw_anchor_ceiling_bytes": raw_ceiling,
        "entropy_selected_templates": len(entropy_selected),
        "entropy_anchor_ceiling_bytes": entropy_ceiling,
        "unigram_id_bits": id_bits,
        "unigram_event_bits": event_bits,
        "unigram_model_allowance_bytes": 128,
        "unigram_proxy_saved_bytes": round(entropy_saved - 1 - 128, 4),
        "warning": "Source-only diagnostics: raw-anchor score grants zero-cost slots; unigram proxy prices anchor IDs and an assumed event/table budget but is not a native or bzip3 frame.",
        "top_templates": raw_selected[:20],
        "top_unigram_templates": entropy_selected[:20],
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("source", type=pathlib.Path)
    ap.add_argument("--prefix", type=int, default=0, help="Optional exact byte-prefix limit")
    ap.add_argument("--max-candidates", type=int, default=MAX_CANDIDATES)
    ap.add_argument("--segmentation", choices=("runs", "scalars", "both"), default="both")
    ns = ap.parse_args()
    raw = ns.source.read_bytes()
    if ns.prefix:
        raw = raw[: ns.prefix]
    if ns.segmentation == "both":
        result = {mode: discover(raw, ns.max_candidates, mode == "scalars") for mode in ("runs", "scalars")}
    else:
        result = discover(raw, ns.max_candidates, ns.segmentation == "scalars")
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
