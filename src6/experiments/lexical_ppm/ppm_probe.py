#!/usr/bin/env python3
"""Prequential ideal bits for one joint lexical PPM-D model; no archive."""
from __future__ import annotations

from collections import OrderedDict
import hashlib
import itertools
import json
import math
import pathlib
import resource
import sys
import unicodedata

MAX_RAW = 1 << 20
MAX_ADDRESS = 512 << 20
END = 256


def byte_tokens(raw: bytes):
    at = 0
    while at < len(raw):
        word = (65 <= raw[at] <= 90 or 97 <= raw[at] <= 122 or
                48 <= raw[at] <= 57 or raw[at] >= 128)
        end = at + 1
        while end < len(raw):
            other = (65 <= raw[end] <= 90 or 97 <= raw[end] <= 122 or
                     48 <= raw[end] <= 57 or raw[end] >= 128)
            if other != word:
                break
            end += 1
        yield raw[at:end], word
        at = end


def cjk_scalar(cp: int) -> bool:
    return (0x3040 <= cp <= 0x30FF or 0x3400 <= cp <= 0x9FFF or
            0x20000 <= cp <= 0x2FA1F or 0xAC00 <= cp <= 0xD7AF)


def scalar_tokens(raw: bytes):
    decoded = raw.decode("utf-8", "surrogateescape")
    buffer = bytearray()
    kind = -1
    for char in decoded:
        encoded = char.encode("utf-8", "surrogateescape")
        cp = ord(char)
        next_kind = 2 if cjk_scalar(cp) else int(unicodedata.category(char)[0] in "LMN")
        if buffer and (next_kind != kind or next_kind == 2):
            yield bytes(buffer), kind != 0
            buffer.clear()
        buffer.extend(encoded)
        kind = next_kind
    if buffer:
        yield bytes(buffer), kind != 0


class Row:
    __slots__ = ("counts", "total")

    def __init__(self):
        self.counts: dict[int, int] = {}
        self.total = 0

    def add(self, symbol: int):
        before = self.counts.get(symbol, 0)
        self.counts[symbol] = before + 1
        self.total += 1
        return before == 0


class PPM:
    """PPM-D with whole-row LRU; every retained row has every successor."""

    def __init__(self, max_rows: int, max_edges: int, base_alphabet: int | None):
        self.root = Row()
        self.rows: OrderedDict[tuple[int, tuple[int, ...]], Row] = OrderedDict()
        self.max_rows = max_rows
        self.max_edges = max_edges
        self.base_alphabet = base_alphabet
        self.edges = 0
        self.peak_rows = 0
        self.peak_edges = 0
        self.replacements = 0
        self.escapes = [0] * 5
        self.hits = [0] * 5

    def price(self, symbol: int | None, history: list[int]) -> float:
        excluded: set[int] = set()
        bits = 0.0
        for order in range(min(4, len(history)), -1, -1):
            key = (order, tuple(history[-order:])) if order else None
            row = self.rows.get(key) if order else self.root
            if row is None:
                continue
            if order:
                self.rows.move_to_end(key)
            removed = 0
            removed_types = 0
            for old in excluded:
                count = row.counts.get(old)
                if count:
                    removed += count
                    removed_types += 1
            total = row.total - removed
            types = len(row.counts) - removed_types
            if types == 0:
                continue
            count = row.counts.get(symbol, 0)
            if count and symbol not in excluded:
                bits += math.log2(total / (count - 0.5))
                self.hits[order] += 1
                return bits
            bits += math.log2(2 * total / types)
            self.escapes[order] += 1
            excluded.update(row.counts)
        if self.base_alphabet is None:
            if symbol is not None:
                raise AssertionError("a previously seen ID must hit root")
            return bits
        allowed = self.base_alphabet - len(excluded)
        if allowed <= 0 or symbol in excluded:
            raise AssertionError("bad uniform byte fallback")
        return bits + math.log2(allowed)

    def update(self, symbol: int, history: list[int]):
        self.root.add(symbol)
        for order in range(1, min(4, len(history)) + 1):
            key = (order, tuple(history[-order:]))
            row = self.rows.pop(key, None)
            if row is None:
                row = Row()
            else:
                self.edges -= len(row.counts)
            row.add(symbol)
            new_edges = len(row.counts)
            while self.rows and (len(self.rows) >= self.max_rows or
                                 self.edges + new_edges > self.max_edges):
                _, removed = self.rows.popitem(last=False)
                self.edges -= len(removed.counts)
                self.replacements += 1
            if len(self.rows) >= self.max_rows or self.edges + new_edges > self.max_edges:
                raise MemoryError("context state cap cannot admit a complete row")
            self.rows[key] = row
            self.edges += new_edges
            self.peak_rows = max(self.peak_rows, len(self.rows))
            self.peak_edges = max(self.peak_edges, self.edges)


def feed_spelling(model: PPM, token: bytes, first_use: bool) -> float:
    history: list[int] = []
    bits = 0.0
    for symbol in itertools.chain(token, (END,)):
        if first_use:
            bits += model.price(symbol, history)
        model.update(symbol, history)
        history.append(symbol)
        if len(history) > 4:
            history.pop(0)
    return bits


def probe(raw: bytes, mode: str):
    tokenize = byte_tokens if mode == "byte" else scalar_tokens
    word = PPM(80_000, 400_000, None)
    spelling = PPM(40_000, 160_000, 257)
    ids: dict[bytes, int] = {}
    history: list[int] = []
    parts = {key: 0.0 for key in ("word_known_bits", "separator_known_bits",
                                       "word_new_escape_bits", "separator_new_escape_bits",
                                       "word_spelling_bits", "separator_spelling_bits")}
    counts = {key: 0 for key in ("word_events", "separator_events", "new_word_types", "new_separator_types")}
    reconstructed = hashlib.sha256()
    reconstructed_len = 0
    for token, is_word in tokenize(raw):
        if not token:
            raise AssertionError("empty token")
        reconstructed.update(token)
        reconstructed_len += len(token)
        category = "word" if is_word else "separator"
        counts[category + "_events"] += 1
        old_id = ids.get(token)
        first_use = old_id is None
        lexical_bits = word.price(old_id, history)
        if first_use:
            parts[category + "_new_escape_bits"] += lexical_bits
            counts["new_" + category + "_types"] += 1
            identifier = len(ids)
            ids[token] = identifier
        else:
            parts[category + "_known_bits"] += lexical_bits
            identifier = old_id
        spell_bits = feed_spelling(spelling, token, first_use)
        if first_use:
            parts[category + "_spelling_bits"] += spell_bits
        word.update(identifier, history)
        history.append(identifier)
        if len(history) > 4:
            history.pop(0)
    if reconstructed_len != len(raw) or reconstructed.digest() != hashlib.sha256(raw).digest():
        raise AssertionError("tokenizer not byte exact")
    ideal_bits = sum(parts.values())
    return {
        "mode": mode, "source_bytes": len(raw), "source_sha256": hashlib.sha256(raw).hexdigest(),
        "events": sum(counts[k] for k in ("word_events", "separator_events")),
        "vocabulary": len(ids), "counts": counts, "parts_bits": parts,
        "lexical_bits": sum(v for k, v in parts.items() if "spelling" not in k),
        "spelling_bits": sum(v for k, v in parts.items() if "spelling" in k),
        "ideal_bits": ideal_bits, "optimistic_complete_bytes": math.ceil((ideal_bits + 1) / 8) + 24,
        "lexical_state": {"rows": len(word.rows), "edges": word.edges,
                          "peak_rows": word.peak_rows, "peak_edges": word.peak_edges,
                          "root_successors": len(word.root.counts), "replacements": word.replacements,
                          "hits_by_order": word.hits, "escapes_by_order": word.escapes},
        "spelling_state": {"rows": len(spelling.rows), "edges": spelling.edges,
                           "peak_rows": spelling.peak_rows, "peak_edges": spelling.peak_edges,
                           "root_successors": len(spelling.root.counts),
                           "replacements": spelling.replacements,
                           "hits_by_order": spelling.hits, "escapes_by_order": spelling.escapes},
        "process_peak_rss_kib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
    }


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("byte", "scalar"):
        raise SystemExit("usage: ppm_probe.py byte|scalar INPUT")
    mode, path = sys.argv[1], pathlib.Path(sys.argv[2])
    raw = path.read_bytes()
    if len(raw) > MAX_RAW:
        raise ValueError("source > 1 MiB")
    resource.setrlimit(resource.RLIMIT_AS, (MAX_ADDRESS, MAX_ADDRESS))
    result = probe(raw, mode)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
