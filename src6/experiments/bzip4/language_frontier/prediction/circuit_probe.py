#!/usr/bin/env python3
"""Diagnostic screen for a type-weighted mixture-of-products circuit.

This command intentionally reports cross entropy and charged parameter bytes,
not a compressed frame.  It is the cheap disproof gate before implementing an
integer marginal arithmetic stream.  No diagnostic number here is a storage
win.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

from spelling_model import atom_list, sha256


ROWS = 2  # start byte, interior byte; both rows include the END hazard
ALPHABET = 257


def script(text: bytes) -> int:
    if not text:
        return 0
    byte = text[0]
    if byte >= 0x80:
        return 1
    if 65 <= byte <= 90 or 97 <= byte <= 122:
        return 2
    if 48 <= byte <= 57:
        return 3
    return 4


def bucket(position: int) -> int:
    """Return a decoder-visible position row.

    The row cannot depend on the final length: the decoder does not know where
    END will occur until it decodes END.  Both rows therefore model the same
    257-way alphabet (256 bytes plus END), with the interior row carrying the
    termination hazard for every non-empty word.
    """

    return 0 if position == 0 else 1


def seed(types: list[bytes], components: int) -> list[int]:
    return [((script(text) - 1) * 2 + int(len(text) >= 8)) % components for text in types]


def tables(types: list[bytes], assignments: list[int], components: int) -> tuple[list[list[list[int]]], list[int]]:
    counts = [[[1] * ALPHABET for _ in range(ROWS)] for _ in range(components)]
    prior = [1] * components
    for text, component in zip(types, assignments):
        prior[component] += 1
        if not text:
            counts[component][0][256] += 1
            continue
        counts[component][0][text[0]] += 1
        for byte in text[1:]:
            counts[component][1][byte] += 1
        # Every non-empty word ends from the interior row.  This is a genuine
        # variable-length generator, not an oracle-selected final-position
        # row.
        counts[component][1][256] += 1
    return counts, prior


def logp(text: bytes, component: int, counts: list[list[list[int]]]) -> float:
    value = 0.0
    if not text:
        row = counts[component][0]
        return math.log2(row[256] / sum(row))
    row = counts[component][0]
    value += math.log2(row[text[0]] / sum(row))
    row = counts[component][1]
    for byte in text[1:]:
        value += math.log2(row[byte] / sum(row))
    # END is emitted from the same row that emits every post-start byte.  No
    # input length or final-position oracle is used.
    return value + math.log2(row[256] / sum(row))


def train(train: bytes, components: int, rounds: int) -> tuple[list[list[list[int]]], list[int]]:
    types = list(dict.fromkeys(atom_list(train)))
    assignments = seed(types, components)
    counts, prior = tables(types, assignments, components)
    for _ in range(rounds):
        assignments = [
            max(
                range(components),
                key=lambda component: (logp(text, component, counts) + math.log2(prior[component] / sum(prior)), -component),
            )
            for text in types
        ]
        counts, prior = tables(types, assignments, components)
    return counts, prior


def score(data: bytes, counts: list[list[list[int]]], prior: list[int]) -> tuple[float, float, int]:
    types = list(dict.fromkeys(atom_list(data)))
    hard = 0.0
    marginal = 0.0
    for text in types:
        values = [logp(text, component, counts) + math.log2(prior[component] / sum(prior)) for component in range(len(prior))]
        best = max(values)
        hard += -best
        marginal += -(best + math.log2(sum(2.0 ** (value - best) for value in values)))
    return hard, marginal, len(types)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("train", type=Path)
    parser.add_argument("input", type=Path)
    parser.add_argument("--components", type=int, default=8)
    parser.add_argument("--rounds", type=int, default=3)
    args = parser.parse_args()
    train_bytes = args.train.read_bytes()
    input_bytes = args.input.read_bytes()
    counts, prior = train(train_bytes, args.components, args.rounds)
    hard, marginal, type_count = score(input_bytes, counts, prior)
    # u32 counts, u32 priors, and a tiny fixed metadata prefix are charged in
    # the prospective wire format.  u16 was too optimistic for larger train
    # prefixes: a byte count can exceed 65535 even when the type population is
    # modest.  This remains a lower bound: boundaries, arithmetic precision,
    # and occurrence selectors are not included.
    model_bytes = 8 + args.components * 4 + args.components * ROWS * ALPHABET * 4
    print(
        f"train={args.train} input={args.input} train_bytes={len(train_bytes)} "
        f"input_bytes={len(input_bytes)} train_sha256={sha256(train_bytes)} "
        f"input_sha256={sha256(input_bytes)} components={args.components} rounds={args.rounds} "
        f"types={type_count} model_bytes_lower_bound={model_bytes} "
        f"hard_type_bits={hard:.1f} marginal_type_bits={marginal:.1f} "
        f"hard_type_bytes_plus_model={(hard / 8 + model_bytes):.1f} "
        f"marginal_type_bytes_plus_model={(marginal / 8 + model_bytes):.1f} "
        f"diagnostic_only=1"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
