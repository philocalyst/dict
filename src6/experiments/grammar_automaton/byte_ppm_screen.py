#!/usr/bin/env python3
"""Exact-byte prequential ideal-bit screen for a bounded PPM/match codec.

This is an encoder-side entropy diagnostic, not a compressed file. Every
prediction uses only earlier bytes. A complete codec must still quantize the
CDF, code it, frame the stream, and independently decode it.
"""

from __future__ import annotations

from collections import OrderedDict
import hashlib
import json
import math
from pathlib import Path
import sys


PPM_ORDERS = (1, 2, 4, 8, 16, 32)
PPM_CONTEXT_CAP = 32768
PPM_SUCCESSOR_CAP = 16
PPM_LOW_ORDER_SUCCESSOR_CAP = 256
MATCH_ORDERS = (8, 16)
MATCH_CONTEXT_CAP = 32768
MIX_EXPERTS = ("ppm4", "ppm8", "ppm16", "ppm32", "match8", "match16")


class PPM:
    def __init__(self):
        self.base = [0] * 256
        self.base_total = 0
        self.tables = {order: OrderedDict() for order in PPM_ORDERS}
        self.skipped_new_successors = 0

    def probabilities(self, raw: bytes, at: int, symbol: int):
        """Witten-Bell backoff: (count + distinct * lower)/(total + distinct)."""
        probability = (self.base[symbol] + 0.5) / (self.base_total + 128)
        result = {"ppm0": probability}
        for order in PPM_ORDERS:
            if at >= order:
                row = self.tables[order].get(raw[at - order:at])
                if row is not None:
                    counts, total = row
                    distinct = len(counts)
                    probability = (counts.get(symbol, 0) + distinct * probability) / (total + distinct)
            result[f"ppm{order}"] = probability
        return result

    def accept(self, raw: bytes, at: int, symbol: int):
        self.base[symbol] += 1
        self.base_total += 1
        for order in PPM_ORDERS:
            if at < order:
                continue
            key = raw[at - order:at]
            table = self.tables[order]
            row = table.get(key)
            if row is None:
                if len(table) == PPM_CONTEXT_CAP:
                    table.popitem(last=False)
                table[key] = ({symbol: 1}, 1)
            else:
                counts, total = row
                cap = PPM_LOW_ORDER_SUCCESSOR_CAP if order <= 2 else PPM_SUCCESSOR_CAP
                if symbol in counts or len(counts) < cap:
                    counts[symbol] = counts.get(symbol, 0) + 1
                    table[key] = (counts, total + 1)
                else:
                    self.skipped_new_successors += 1
                table.move_to_end(key)


class ExactMatch:
    def __init__(self, order: int):
        self.order = order
        self.cache = OrderedDict()
        self.hits = 0
        self.misses = 0
        self.eligible = 0

    def probability(self, raw: bytes, at: int, symbol: int, fallback: float):
        if at < self.order:
            return fallback
        previous = self.cache.get(raw[at - self.order:at])
        if previous is None:
            return fallback
        p_hit = (self.hits + 0.5) / (self.hits + self.misses + 1)
        self.eligible += 1
        if symbol == previous:
            self.hits += 1
            return p_hit + (1 - p_hit) * fallback
        self.misses += 1
        return (1 - p_hit) * fallback

    def accept(self, raw: bytes, at: int, symbol: int):
        if at < self.order:
            return
        key = raw[at - self.order:at]
        if key not in self.cache and len(self.cache) == MATCH_CONTEXT_CAP:
            self.cache.popitem(last=False)
        self.cache[key] = symbol
        self.cache.move_to_end(key)


def screen(raw: bytes):
    ppm = PPM()
    matches = {order: ExactMatch(order) for order in MATCH_ORDERS}
    losses = {f"ppm{order}": 0.0 for order in (0,) + PPM_ORDERS}
    losses.update({f"match{order}": 0.0 for order in MATCH_ORDERS})
    # This is a true online Bayesian mixture of fixed, causal experts. Its
    # ideal log loss is at most log2(6) bits above the best listed expert.
    expert_losses = [0.0] * len(MIX_EXPERTS)
    mixture_loss = 0.0
    for at, symbol in enumerate(raw):
        probabilities = ppm.probabilities(raw, at, symbol)
        for order, expert in matches.items():
            probabilities[f"match{order}"] = expert.probability(
                raw, at, symbol, probabilities["ppm16"])
        for name in losses:
            losses[name] -= math.log2(probabilities[name])
        least_loss = min(expert_losses)
        weights = [math.exp2(-(value - least_loss)) for value in expert_losses]
        probability = sum(weights[i] * probabilities[name]
                          for i, name in enumerate(MIX_EXPERTS)) / sum(weights)
        mixture_loss -= math.log2(probability)
        for i, name in enumerate(MIX_EXPERTS):
            expert_losses[i] -= math.log2(probabilities[name])
        ppm.accept(raw, at, symbol)
        for expert in matches.values():
            expert.accept(raw, at, symbol)
    candidate_bits = {key: round(value, 2) for key, value in losses.items()}
    candidate_bits["bayesian_fixed_prior_mixture"] = round(mixture_loss, 2)
    return {
        "status": "development_only_ideal_entropy_not_frame_bytes",
        "source_sha256": hashlib.sha256(raw).hexdigest(),
        "raw_bytes": len(raw),
        "candidate_ideal_bits": candidate_bits,
        "match_stats": {str(order): {
            "eligible": match.eligible, "hits": match.hits, "misses": match.misses,
            "live_contexts": len(match.cache)
        } for order, match in matches.items()},
        "ppm_live_contexts": {str(order): len(ppm.tables[order]) for order in PPM_ORDERS},
        "ppm_skipped_new_successors": ppm.skipped_new_successors,
        "assumptions": "Exact bytes. PPM orders 0,1,2,4,8,16,32; causal Witten-Bell distinct-count recursive backoff; 32768 LRU rows/order; at most 16 successors in orders >=4 and 256 in orders 1,2; exact 8/16-byte last-successor match with KT hit probability; Bayesian mixture of six listed experts with equal fixed prior.",
        "limits": "Ideal real probabilities omit integer CDF quantization, arithmetic termination, raw-length/header/CRC bytes and a native decoder. The Bayesian static-regret bound applies only to ideal probabilities, not to an eventual integer coder.",
    }


if __name__ == "__main__":
    path = Path(sys.argv[1])
    print(json.dumps(screen(path.read_bytes()), indent=2))
