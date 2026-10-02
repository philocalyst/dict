#!/usr/bin/env python3
"""Prequential, model-charged estimate for a standalone word-order codec.

All probabilities are updated only from prior tokens. The output is an ideal
entropy diagnostic; it omits integer coder rounding and framing, so it is not
an archive-size result.
"""
from __future__ import annotations

from collections import Counter, OrderedDict, defaultdict
import hashlib
import json
import math
from pathlib import Path
import sys
import unicodedata


MAX_CONTEXTS = 32768
MAX_SUCCESSORS = 16
CONTEXT_ORDERS = (1, 2, 3, 4)
CONTEXT_WEIGHTS = (1, 2, 4, 8)
GLOBAL_PRIOR_MASS = 8


def unicode_word_spans(raw: bytes):
    """Unicode words, with byte-exact invalid-UTF-8 fallback.

    A non-ASCII run splits after eight scalars or 32 bytes; an ASCII run
    splits after 64 bytes. Empty separator events between chunks are valid.
    """
    decoded = raw.decode("utf-8", "surrogateescape")
    start = None
    at = 0
    codepoints = 0
    has_nonascii = False
    for char in decoded:
        encoded = char.encode("utf-8", "surrogateescape")
        word_char = unicodedata.category(char)[0] in "LMN"
        if word_char:
            if start is None:
                start = at
                codepoints = 0
                has_nonascii = False
            nonascii = has_nonascii or len(encoded) > 1
            if codepoints >= (8 if nonascii else 64) or at + len(encoded) - start > (32 if nonascii else 64):
                yield start, at
                start = at
                codepoints = 0
                has_nonascii = False
            codepoints += 1
            has_nonascii |= len(encoded) > 1
        elif start is not None:
            yield start, at
            start = None
        at += len(encoded)
    if start is not None:
        yield start, at
    if at != len(raw):
        raise AssertionError("UTF-8 byte accounting")


def bits(p: float):
    if not 0 < p <= 1:
        raise ValueError(p)
    return -math.log2(p)


def gamma(n: int):
    return 2 * (n.bit_length() - 1) + 1


class Spelling:
    def __init__(self):
        self.rows = defaultdict(Counter)
        self.totals = Counter()

    def price_and_update(self, token: bytes):
        price = gamma(len(token) + 1)
        previous = 256
        for byte in token:
            price += bits((self.rows[previous][byte] + 0.5) /
                          (self.totals[previous] + 128))
            self.rows[previous][byte] += 1
            self.totals[previous] += 1
            previous = byte
        return price


class Lexicon:
    def __init__(self):
        self.ids = {}
        self.counts = []
        self.total = 0
        self.new = 0
        self.spelling = Spelling()
        self.spelling_bits = 0.0

    def price_and_update(self, token: bytes):
        p_new = (self.new + 0.5) / (self.total + 1)
        if token in self.ids:
            ident = self.ids[token]
            # Known-symbol KT estimate over the currently known inventory.
            choice = ((self.counts[ident] + 0.5) /
                      (self.total + 0.5 * len(self.counts)))
            price = bits(1 - p_new) + bits(choice)
            self.counts[ident] += 1
            fresh = False
        else:
            ident = len(self.counts)
            self.ids[token] = ident
            self.counts.append(1)
            spelling = self.spelling.price_and_update(token)
            self.spelling_bits += spelling
            price = bits(p_new) + spelling
            self.new += 1
            fresh = True
        self.total += 1
        return ident, price, fresh


class Predictor:
    def __init__(self, order: int):
        self.order = order
        self.cache = OrderedDict()
        self.hits = 0
        self.misses = 0
        self.flags = 0
        self.saved_global_bits = 0.0
        self.flag_bits = 0.0
        self.total_bits = 0.0

    def accept(self, history, word_id: int, global_price: float):
        if len(history) < self.order:
            self.total_bits += global_price
            return
        context = tuple(history[-self.order:])
        state = self.cache.get(context)
        if state is not None and state[1] >= 2:
            hit = state[0] == word_id
            p_hit = (self.hits + 0.5) / (self.hits + self.misses + 1)
            cost = bits(p_hit if hit else 1 - p_hit)
            self.flag_bits += cost
            self.flags += 1
            if hit:
                self.hits += 1
                self.saved_global_bits += global_price
                self.total_bits += cost
            else:
                self.misses += 1
                self.total_bits += cost + global_price
        else:
            self.total_bits += global_price
        if state is None:
            if len(self.cache) == MAX_CONTEXTS:
                self.cache.popitem(last=False)
            self.cache[context] = (word_id, 1)
        else:
            self.cache[context] = (word_id, min(state[1] + 1, 2))
            self.cache.move_to_end(context)


class SparseContextMixture:
    """Causal sparse successor counts with an exact normalized backoff prior.

    The global prior mass and four context weights are fixed, so a future
    integer coder can use a Fenwick global CDF plus at most 64 corrections.
    Each row admits at most 16 successors, and each order has 32768 LRU rows.
    """

    def __init__(self):
        self.tables = {order: OrderedDict() for order in CONTEXT_ORDERS}
        self.total_bits = [0.0] * len(CONTEXT_ORDERS)
        self.eligible = [0] * len(CONTEXT_ORDERS)

    def preview(self, model: Lexicon, history, ident):
        if ident is None:
            return None
        global_den = 2 * model.total + len(model.counts)
        global_num = 2 * model.counts[ident] + 1
        base_probability = global_num / global_den
        extra_num = 0
        extra_den = 0
        choices = []
        for order, weight in zip(CONTEXT_ORDERS, CONTEXT_WEIGHTS):
            if len(history) >= order:
                row = self.tables[order].get(tuple(history[-order:]))
                if row is not None:
                    counts, total = row
                    extra_num += weight * counts.get(ident, 0)
                    extra_den += weight * total
            numerator = GLOBAL_PRIOR_MASS * global_num + global_den * extra_num
            denominator = global_den * (GLOBAL_PRIOR_MASS + extra_den)
            choices.append((bits(numerator / denominator), bits(base_probability), extra_den > 0))
        return choices

    def accept(self, history, ident, global_price, preview):
        for index in range(len(CONTEXT_ORDERS)):
            if preview is None:
                self.total_bits[index] += global_price
            else:
                conditional, base, eligible = preview[index]
                self.total_bits[index] += global_price + conditional - base
                self.eligible[index] += eligible
        for order in CONTEXT_ORDERS:
            if len(history) < order:
                continue
            key = tuple(history[-order:])
            table = self.tables[order]
            row = table.get(key)
            if row is None:
                if len(table) == MAX_CONTEXTS:
                    table.popitem(last=False)
                counts = {ident: 1}
                table[key] = (counts, 1)
            else:
                counts, total = row
                if ident in counts or len(counts) < MAX_SUCCESSORS:
                    counts[ident] = counts.get(ident, 0) + 1
                    table[key] = (counts, total + 1)
                table.move_to_end(key)


def screen(raw: bytes):
    word_model = Lexicon()
    sep_model = Lexicon()
    predictors = {order: Predictor(order) for order in (1, 2, 3, 4, 8, 16)}
    sparse_mixture = SparseContextMixture()
    history = []
    word_bits = 0.0
    separator_bits = 0.0
    first_uses = 0
    sep_first_uses = 0
    at = 0
    for start, end in unicode_word_spans(raw):
        sep = raw[at:start]
        _, cost, fresh = sep_model.price_and_update(sep)
        separator_bits += cost
        sep_first_uses += fresh
        word_token = raw[start:end]
        preview = sparse_mixture.preview(word_model, history, word_model.ids.get(word_token))
        word_id, cost, fresh = word_model.price_and_update(word_token)
        word_bits += cost
        first_uses += fresh
        for predictor in predictors.values():
            predictor.accept(history, word_id, cost)
        sparse_mixture.accept(history, word_id, cost, preview)
        history.append(word_id)
        at = end
    if at < len(raw) or not history:
        sep = raw[at:]
        _, cost, fresh = sep_model.price_and_update(sep)
        separator_bits += cost
        sep_first_uses += fresh
    candidates = [{"mode": "global_words", "estimated_bytes": round((word_bits + separator_bits) / 8, 2)}]
    for order, predictor in predictors.items():
        candidates.append({
            "mode": f"last_successor_order{order}",
            "estimated_bytes": round((predictor.total_bits + separator_bits) / 8, 2),
            "eligible_flags": predictor.flags, "hits": predictor.hits,
            "misses": predictor.misses, "flag_bits": round(predictor.flag_bits, 2),
            "global_word_bits_avoided": round(predictor.saved_global_bits, 2),
            "live_contexts": len(predictor.cache),
        })
    for index, order in enumerate(CONTEXT_ORDERS):
        candidates.append({
            "mode": f"sparse_mixture_through_order{order}",
            "estimated_bytes": round((sparse_mixture.total_bits[index] + separator_bits) / 8, 2),
            "eligible_known_word_events": sparse_mixture.eligible[index],
            "live_contexts_per_order": {
                str(o): len(sparse_mixture.tables[o]) for o in CONTEXT_ORDERS[:index + 1]
            },
        })
    return {
        "status": "development_only_ideal_entropy_not_frame_bytes",
        "raw_bytes": len(raw), "source_sha256": hashlib.sha256(raw).hexdigest(),
        "unicode_version_used_by_encoder_screen": unicodedata.unidata_version,
        "word_tokens": len(history), "word_types": len(word_model.ids),
        "word_first_uses": first_uses, "word_spelling_bits": round(word_model.spelling_bits, 2),
        "separator_tokens": sep_model.total, "separator_types": len(sep_model.ids),
        "separator_first_uses": sep_first_uses,
        "separator_spelling_bits": round(sep_model.spelling_bits, 2),
        "word_global_bits": round(word_bits, 2),
        "separator_bits": round(separator_bits, 2),
        "candidate_ideal_bits": candidates,
        "coding_assumptions": "Unicode letter/mark/number runs capped at eight non-ASCII scalars or 64 ASCII bytes; invalid UTF-8 literal separator; KT new/known and token frequencies; first-use byte spelling with order-1 KT; gamma token length; exact separators; 32768 LRU contexts/order and at most 16 recorded successors/context; fixed integer sparse-mixture masses 8,1,2,4,8; last-successor flags after two visits",
        "limits": "Ideal entropy omits integer coder rounding, frame index/CRC, mode signaling, token-boundary bits, and complete decoder implementation; no archive-size claim",
    }


if __name__ == "__main__":
    path = Path(sys.argv[1])
    print(json.dumps(screen(path.read_bytes()), indent=2))
