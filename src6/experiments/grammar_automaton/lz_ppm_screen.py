#!/usr/bin/env python3
"""Paid ideal-bit falsifier for bounded exact-span copies over PPM8 literals.

An encoder can inspect ahead to choose a copy; the decoder's candidate donor
set is reconstructed solely from the preceding decoded bytes. This diagnostic
still omits range-coder rounding and fixed frame bytes.
"""

from __future__ import annotations

from collections import OrderedDict
import hashlib
import json
import math
from pathlib import Path
import sys

from byte_ppm_screen import PPM


CONTEXT_BYTES = 16
MAX_CONTEXTS = 65536
DONORS_PER_CONTEXT = 4
MAX_COPY = 65535


def gamma(n: int):
    return 2 * (n.bit_length() - 1) + 1


class Donors:
    def __init__(self):
        self.rows = OrderedDict()

    def get(self, raw: bytes, position: int):
        if position < CONTEXT_BYTES:
            return ()
        return self.rows.get(raw[position-CONTEXT_BYTES:position], ())

    def accept(self, raw: bytes, position: int):
        if position < CONTEXT_BYTES:
            return
        key = raw[position-CONTEXT_BYTES:position]
        row = self.rows.get(key)
        if row is None:
            if len(self.rows) == MAX_CONTEXTS:
                self.rows.popitem(last=False)
            self.rows[key] = [position]
        else:
            row.append(position)
            if len(row) > DONORS_PER_CONTEXT:
                del row[0]
            self.rows.move_to_end(key)


def literal_losses(raw: bytes):
    model = PPM()
    prefix = [0.0]
    for position, symbol in enumerate(raw):
        probability = model.probabilities(raw, position, symbol)["ppm8"]
        prefix.append(prefix[-1] - math.log2(probability))
        model.accept(raw, position, symbol)
    return prefix, model


def longest_copy(raw: bytes, at: int, donor_positions):
    limit = min(len(raw) - at, MAX_COPY)
    best = (0, 0, 0)  # length, distance, two-bit donor rank
    for rank, donor in enumerate(reversed(donor_positions)):
        length = 0
        while length < limit and raw[donor + length] == raw[at + length]:
            length += 1
        if length > best[0]:
            best = (length, at - donor, rank)
    return best


def screen(raw: bytes):
    prefix, ppm_model = literal_losses(raw)
    donors = Donors()
    position = 0
    hits = misses = eligible = copied_bytes = 0
    literal_flags = copy_flags = payload_bits = saved_literal_bits = 0.0
    copy_count = 0
    while position < len(raw):
        candidates = donors.get(raw, position)
        if candidates:
            eligible += 1
            length, distance, rank = longest_copy(raw, position, candidates)
            p_copy = (hits + 0.5) / (hits + misses + 1)
            copy_cost = gamma(distance) + gamma(length) + 2 if length >= CONTEXT_BYTES else math.inf
            saved = prefix[position + length] - prefix[position]
            # A full copy command must beat its own flag and operands. We do
            # not credit skipped future eligibility flags, making this gate
            # conservative relative to this particular greedy parse.
            if length >= CONTEXT_BYTES and saved > copy_cost - math.log2(p_copy):
                copy_flags += -math.log2(p_copy)
                payload_bits += copy_cost
                saved_literal_bits += saved
                copied_bytes += length
                copy_count += 1
                hits += 1
                for index in range(position, position + length):
                    donors.accept(raw, index)
                position += length
                continue
            literal_flags += -math.log2(1 - p_copy)
            misses += 1
        donors.accept(raw, position)
        position += 1
    baseline_bits = prefix[-1]
    estimated_bits = baseline_bits - saved_literal_bits + payload_bits + literal_flags + copy_flags
    return {
        "status": "development_only_ideal_entropy_not_frame_bytes",
        "source_sha256": hashlib.sha256(raw).hexdigest(),
        "raw_bytes": len(raw),
        "ppm8_literal_ideal_bytes": round(baseline_bits / 8, 2),
        "lz_ppm8_ideal_bytes": round(estimated_bits / 8, 2),
        "candidate_ideal_bits": {"ppm8_literals": round(baseline_bits, 2),
                                 "lz_ppm8": round(estimated_bits, 2)},
        "literal_bits_removed_by_copies": round(saved_literal_bits, 2),
        "copy_operand_bits": round(payload_bits, 2),
        "copy_flag_bits": round(copy_flags, 2),
        "literal_flag_bits": round(literal_flags, 2),
        "copy_count": copy_count,
        "copied_bytes": copied_bytes,
        "eligible_positions": eligible,
        "literal_decisions_at_eligible_positions": misses,
        "live_donor_contexts": len(donors.rows),
        "ppm_live_contexts": {str(order): len(row) for order, row in ppm_model.tables.items()},
        "assumptions": "Exact previous-16-byte context, 65536 LRU contexts, four latest exact donors/context, copy <=65535 bytes; gamma distance and length, 2-bit donor rank, KT copy/literal flag on every eligible decoded position; PPM8 literals and PPM state updated over copied bytes.",
        "limits": "Greedy source-aware parse; ideal PPM and flag probabilities, no range rounding/header/CRC/source-length bytes. Every candidate's operands and flags are counted, but no complete decoder exists; this is a falsifier only.",
    }


if __name__ == "__main__":
    print(json.dumps(screen(Path(sys.argv[1]).read_bytes()), indent=2))
