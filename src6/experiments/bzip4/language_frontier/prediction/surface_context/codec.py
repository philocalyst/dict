#!/usr/bin/env python3
"""Contextual surface-source codec for a bounded language-frontier screen.

The source is a finite token automaton, not an iid piece emitter.  At a
boundary class ``c`` it draws token ``t`` from a positive row ``P(t|c)``,
emits ``t``'s bytes, then moves to the deterministic class ``g(t)``.  The
surface decoder marginalizes every tokenization and class path by keeping a
trie frontier.  A frontier node carries the vector of token-start origin
classes; terminal mass is routed through ``g(t)``.

This is a research wire, deliberately separate from v4.  Its arithmetic
coder is integer E3 range coding, while the marginal frontier uses floating
beliefs and fixed 20-bit integer CDFs.  Therefore byte-for-byte portability
across architectures is not claimed until the floating calculations are
replaced by a canonical fixed-point representation.  Every model row,
transition class, token surface, raw length, payload length, and arithmetic
flush is charged in the frame.
"""

from __future__ import annotations

import bisect
import hashlib
import json
import math
import os
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence


MAGIC = b"SCX1"
CDF_BITS = 20
CDF_SCALE = 1 << CDF_BITS
TOP = (1 << 64) - 1
MASK = TOP
HALF = 1 << 63
FIRST_QTR = 1 << 62
THIRD_QTR = 3 << 62

MAX_RAW_LEN = 1 << 16
MAX_TOKEN_COUNT = 4096
MAX_TOKEN_LEN = 32
MAX_MODEL_BYTES = 1 << 20
MAX_FRAME_BYTES = 2 << 20
MAX_TOTAL_FREQ = 1 << 40
DEFAULT_CLASSES = 4
DEFAULT_MAX_TOKENS = 512
DEFAULT_MIN_PAIR_COUNT = 4


def varint(value: int) -> bytes:
    if value < 0:
        raise ValueError("varint cannot encode a negative value")
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def read_varint(buf: bytes, at: int) -> tuple[int, int]:
    value = 0
    shift = 0
    while True:
        if at >= len(buf) or shift > 63:
            raise ValueError("truncated varint")
        byte = buf[at]
        at += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, at
        shift += 7


class ArithmeticEncoder:
    """64-bit integer E1/E2/E3 arithmetic encoder."""

    def __init__(self) -> None:
        self.low = 0
        self.high = TOP
        self.pending = 0
        self.underflow_events = 0
        self.bits: list[int] = []

    def _emit_bit(self, bit: int) -> None:
        self.bits.append(bit)
        self.bits.extend([1 - bit] * self.pending)
        self.pending = 0

    def put(self, symbol: int, freqs: Sequence[int]) -> None:
        if symbol < 0 or symbol >= len(freqs) or freqs[symbol] <= 0:
            raise ValueError("arithmetic symbol has no positive frequency")
        cumulative = [0]
        for freq in freqs:
            if freq <= 0:
                raise ValueError("arithmetic rows must have positive frequencies")
            cumulative.append(cumulative[-1] + freq)
        total = cumulative[-1]
        if total <= 0 or total > MAX_TOTAL_FREQ:
            raise ValueError("arithmetic model total is out of bounds")
        span = self.high - self.low + 1
        self.high = self.low + (span * cumulative[symbol + 1] // total) - 1
        self.low += span * cumulative[symbol] // total
        while True:
            if self.high < HALF:
                self._emit_bit(0)
            elif self.low >= HALF:
                self._emit_bit(1)
                self.low -= HALF
                self.high -= HALF
            elif self.low >= FIRST_QTR and self.high < THIRD_QTR:
                self.pending += 1
                self.underflow_events += 1
                self.low -= FIRST_QTR
                self.high -= FIRST_QTR
            else:
                break
            self.low = (self.low << 1) & MASK
            self.high = ((self.high << 1) | 1) & MASK

    def finish(self) -> bytes:
        self.pending += 1
        self._emit_bit(0 if self.low < FIRST_QTR else 1)
        while len(self.bits) < 64:
            self.bits.append(0)
        while len(self.bits) % 8:
            self.bits.append(0)
        out = bytearray()
        for at in range(0, len(self.bits), 8):
            byte = 0
            for bit in self.bits[at : at + 8]:
                byte = (byte << 1) | bit
            out.append(byte)
        return bytes(out)


class ArithmeticDecoder:
    """Matching integer E3 decoder."""

    def __init__(self, payload: bytes) -> None:
        self.payload = payload
        self.bit_pos = 0
        self.low = 0
        self.high = TOP
        self.code = 0
        for _ in range(64):
            self.code = ((self.code << 1) | self._read_bit()) & MASK

    def _read_bit(self) -> int:
        if self.bit_pos >= len(self.payload) * 8:
            return 0
        byte = self.payload[self.bit_pos // 8]
        bit = (byte >> (7 - self.bit_pos % 8)) & 1
        self.bit_pos += 1
        return bit

    def get(self, freqs: Sequence[int]) -> int:
        cumulative = [0]
        for freq in freqs:
            if freq <= 0:
                raise ValueError("arithmetic rows must have positive frequencies")
            cumulative.append(cumulative[-1] + freq)
        total = cumulative[-1]
        if total <= 0 or total > MAX_TOTAL_FREQ:
            raise ValueError("arithmetic model total is out of bounds")
        span = self.high - self.low + 1
        value = ((self.code - self.low + 1) * total - 1) // span
        symbol = bisect.bisect_right(cumulative, value) - 1
        if symbol < 0 or symbol >= len(freqs):
            raise ValueError("bad arithmetic symbol")
        self.high = self.low + (span * cumulative[symbol + 1] // total) - 1
        self.low += span * cumulative[symbol] // total
        while True:
            if self.high < HALF:
                pass
            elif self.low >= HALF:
                self.low -= HALF
                self.high -= HALF
                self.code -= HALF
            elif self.low >= FIRST_QTR and self.high < THIRD_QTR:
                self.low -= FIRST_QTR
                self.high -= FIRST_QTR
                self.code -= FIRST_QTR
            else:
                break
            self.low = (self.low << 1) & MASK
            self.high = ((self.high << 1) | 1) & MASK
            self.code = ((self.code << 1) | self._read_bit()) & MASK
        return symbol


def quantized_cdf(probabilities: Sequence[float]) -> list[int]:
    """Make a positive integer CDF row from a floating posterior."""

    freqs = [max(1, int(round(probability * CDF_SCALE))) for probability in probabilities]
    if sum(freqs) > MAX_TOTAL_FREQ:
        raise ValueError("quantized CDF total is out of bounds")
    return freqs


def log2_prob(freq: int, total: int) -> float:
    return -math.log2(freq / total)


def bpe_inventory(
    data: bytes,
    *,
    max_tokens: int = DEFAULT_MAX_TOKENS,
    max_len: int = MAX_TOKEN_LEN,
    min_pair_count: int = DEFAULT_MIN_PAIR_COUNT,
) -> tuple[list[bytes], list[int], int]:
    """Build a deterministic byte BPE inventory and seed counts.

    The policy is corpus-independent: initial singleton bytes, non-overlapping
    adjacent-pair merges, minimum pair count, maximum surface length, and
    deterministic gain/byte tie breaks are all fixed.  No script, case,
    Unicode, or whitespace class is consulted.
    """

    if max_tokens < 256 or max_tokens > MAX_TOKEN_COUNT:
        raise ValueError("max_tokens is out of bounds")
    if max_len < 1 or max_len > MAX_TOKEN_LEN:
        raise ValueError("max_len is out of bounds")
    tokens = [bytes((byte,)) for byte in range(256)]
    known = set(tokens)
    sequence = list(data)
    seed_counts: Counter[int] = Counter(sequence)
    merges = 0
    while len(tokens) < max_tokens and sequence:
        pair_counts: Counter[tuple[int, int]] = Counter(zip(sequence, sequence[1:]))
        candidates: list[tuple[int, int, int, bytes, tuple[int, int]]] = []
        for pair, count in pair_counts.items():
            left, right = pair
            merged = tokens[left] + tokens[right]
            if count < min_pair_count or len(merged) > max_len or merged in known:
                continue
            gain = (count - 1) * max(1, len(merged) - 1)
            candidates.append((-gain, -count, -len(merged), merged, pair))
        if not candidates:
            break
        candidates.sort()
        _, _, _, merged, pair = candidates[0]
        token_id = len(tokens)
        tokens.append(merged)
        known.add(merged)
        seed_counts[token_id] = 0
        rewritten: list[int] = []
        at = 0
        left, right = pair
        while at < len(sequence):
            if at + 1 < len(sequence) and sequence[at] == left and sequence[at + 1] == right:
                rewritten.append(token_id)
                seed_counts[token_id] += 1
                at += 2
            else:
                rewritten.append(sequence[at])
                at += 1
        sequence = rewritten
        merges += 1
    # Add-one smoothing is part of the fixed source policy.  It ensures that
    # every token row remains positive even when BPE created an unused token.
    freqs = [seed_counts[token_id] + 1 for token_id in range(len(tokens))]
    return tokens, freqs, merges


def viterbi_tokens(data: bytes, model: "Model") -> list[int]:
    """Best token/class path under the exact contextual source."""

    n = len(data)
    classes = model.class_count
    inf = float("inf")
    dp = [[inf] * classes for _ in range(n + 1)]
    prev: list[list[tuple[int, int, int] | None]] = [[None] * classes for _ in range(n + 1)]
    dp[0][0] = 0.0
    for at in range(n):
        for source_class in range(classes):
            base = dp[at][source_class]
            if base == inf:
                continue
            for token_id in model.by_first.get(data[at], ()):
                token = model.tokens[token_id]
                end = at + len(token)
                if end <= n:
                    if data[at:end] != token:
                        continue
                elif token[: n - at] != data[at:n]:
                    continue
                end = min(end, n)
                destination = model.next_class[token_id]
                candidate = base + log2_prob(model.freqs[source_class][token_id], model.row_totals[source_class])
                if candidate < dp[end][destination] - 1.0e-12:
                    dp[end][destination] = candidate
                    prev[end][destination] = (at, source_class, token_id)
    destination = min(range(classes), key=lambda c: (dp[n][c], c))
    if dp[n][destination] == inf:
        raise ValueError("no contextual Viterbi path")
    path: list[int] = []
    at = n
    current = destination
    while at:
        previous = prev[at][current]
        if previous is None:
            raise AssertionError("broken Viterbi predecessor")
        previous_at, previous_class, token_id = previous
        path.append(token_id)
        at, current = previous_at, previous_class
    path.reverse()
    return path


def _continuation_features(path: Sequence[int], token_count: int) -> list[dict[int, float]]:
    """Sparse next-token distributions used only to learn ``g(t)``."""

    following: list[Counter[int]] = [Counter() for _ in range(token_count)]
    occurrences = Counter(path)
    for left, right in zip(path, path[1:]):
        following[left][right] += 1
    features: list[dict[int, float]] = []
    for token_id in range(token_count):
        total = float(sum(following[token_id].values()))
        feature = {
            next_id: count / total for next_id, count in following[token_id].items()
        }
        # Occurrence frequency is a distributional feature, not a script/case
        # rule.  It prevents all unseen BPE tokens collapsing into one class.
        feature[token_count] = math.log1p(occurrences[token_id])
        features.append(feature)
    return features


def _squared_sparse_distance(left: dict[int, float], right: dict[int, float]) -> float:
    keys = set(left) | set(right)
    return sum((left.get(key, 0.0) - right.get(key, 0.0)) ** 2 for key in keys)


def cluster_destinations(path: Sequence[int], token_count: int, class_count: int) -> list[int]:
    """Deterministic Lloyd clustering of token continuation signatures."""

    if class_count < 1:
        raise ValueError("class_count must be positive")
    if class_count == 1:
        return [0] * token_count
    features = _continuation_features(path, token_count)
    order = sorted(range(token_count), key=lambda token_id: tuple(sorted(features[token_id].items())))
    centers = [dict(features[order[(index * len(order)) // class_count]]) for index in range(class_count)]
    assignments = [0] * token_count
    for _ in range(6):
        for token_id, feature in enumerate(features):
            assignments[token_id] = min(
                range(class_count),
                key=lambda cluster: (_squared_sparse_distance(feature, centers[cluster]), cluster),
            )
        for cluster in range(class_count):
            members = [token_id for token_id, assigned in enumerate(assignments) if assigned == cluster]
            if not members:
                continue
            keys = set().union(*(features[token_id] for token_id in members))
            centers[cluster] = {
                key: sum(features[token_id].get(key, 0.0) for token_id in members) / len(members)
                for key in keys
            }
    return assignments


def fit_model(
    train: bytes,
    *,
    class_count: int = DEFAULT_CLASSES,
    max_tokens: int = DEFAULT_MAX_TOKENS,
    max_len: int = MAX_TOKEN_LEN,
    min_pair_count: int = DEFAULT_MIN_PAIR_COUNT,
) -> tuple["Model", dict[str, int]]:
    """Fit rows and transitions from one deterministic encoder-only path."""

    tokens, seed_freqs, merges = bpe_inventory(
        train,
        max_tokens=max_tokens,
        max_len=max_len,
        min_pair_count=min_pair_count,
    )
    seed_model = Model(tokens, [0] * len(tokens), [seed_freqs], class_count=1)
    seed_path = viterbi_tokens(train, seed_model)
    next_class = cluster_destinations(seed_path, len(tokens), class_count)
    counts = [[1] * len(tokens) for _ in range(class_count)]
    source_class = 0
    for token_id in seed_path:
        counts[source_class][token_id] += 1
        source_class = next_class[token_id]
    model = Model(tokens, next_class, counts, class_count=class_count)
    return model, {
        "bpe_merges": merges,
        "seed_path_tokens": len(seed_path),
        "train_bytes": len(train),
        "class_count": class_count,
        "token_count": len(tokens),
    }


@dataclass
class TrieNode:
    children: dict[int, int]
    terminal: list[list[float]]
    subtree: list[float]
    descendants: list[float]


@dataclass
class SurfaceState:
    root: list[float]
    active: dict[int, list[float]]


class Model:
    """Validated source model and its marginal trie frontier."""

    def __init__(
        self,
        tokens: Sequence[bytes],
        next_class: Sequence[int],
        freqs: Sequence[Sequence[int]],
        *,
        class_count: int,
    ) -> None:
        if not tokens or len(tokens) > MAX_TOKEN_COUNT:
            raise ValueError("token vocabulary is out of bounds")
        if len(next_class) != len(tokens):
            raise ValueError("token transition count mismatch")
        if class_count < 1 or class_count > 16 or len(freqs) != class_count:
            raise ValueError("class rows are out of bounds")
        if any(len(row) != len(tokens) for row in freqs):
            raise ValueError("class row width mismatch")
        seen: set[bytes] = set()
        for token, destination in zip(tokens, next_class):
            if not token or len(token) > MAX_TOKEN_LEN or token in seen:
                raise ValueError("token is empty, too long, or duplicated")
            if destination < 0 or destination >= class_count:
                raise ValueError("token destination class is out of bounds")
            seen.add(token)
        if {token[0] for token in tokens if len(token) == 1} != set(range(256)):
            raise ValueError("model requires all singleton byte fallbacks")
        self.tokens = list(tokens)
        self.next_class = list(next_class)
        self.freqs = [list(row) for row in freqs]
        self.class_count = class_count
        self.row_totals = [sum(row) for row in self.freqs]
        if any(total <= 0 or total > MAX_TOTAL_FREQ for total in self.row_totals):
            raise ValueError("class row total is out of bounds")
        if any(freq <= 0 or freq > MAX_TOTAL_FREQ for row in self.freqs for freq in row):
            raise ValueError("class frequencies must be positive bounded integers")
        self.by_first: dict[int, list[int]] = defaultdict(list)
        for token_id, token in enumerate(self.tokens):
            self.by_first[token[0]].append(token_id)
        self.nodes: list[TrieNode] = []
        self._build_trie()

    def _new_node(self) -> int:
        node = TrieNode(
            {},
            [[0.0] * self.class_count for _ in range(self.class_count)],
            [0.0] * self.class_count,
            [0.0] * self.class_count,
        )
        self.nodes.append(node)
        return len(self.nodes) - 1

    def _build_trie(self) -> None:
        root = self._new_node()
        assert root == 0
        for token_id, token in enumerate(self.tokens):
            node_id = root
            for byte in token:
                child = self.nodes[node_id].children.get(byte)
                if child is None:
                    child = self._new_node()
                    self.nodes[node_id].children[byte] = child
                node_id = child
            node = self.nodes[node_id]
            destination = self.next_class[token_id]
            for source_class, row_total in enumerate(self.row_totals):
                node.terminal[source_class][destination] += self.freqs[source_class][token_id] / row_total

        def finish(node_id: int) -> list[float]:
            node = self.nodes[node_id]
            for child_id in node.children.values():
                child_mass = finish(child_id)
                for source_class, value in enumerate(child_mass):
                    node.descendants[source_class] += value
            for source_class in range(self.class_count):
                node.subtree[source_class] = node.descendants[source_class] + sum(node.terminal[source_class])
            return node.subtree

        root_mass = finish(0)
        if any(abs(value - 1.0) > 1.0e-12 for value in root_mass):
            raise ValueError("token trie is not normalized")

    def initial_state(self) -> SurfaceState:
        root = [0.0] * self.class_count
        root[0] = 1.0
        return SurfaceState(root, {})

    def byte_probs(self, state: SurfaceState) -> list[float]:
        probs = [0.0] * 256
        root_node = self.nodes[0]
        for byte, child_id in root_node.children.items():
            child = self.nodes[child_id]
            probs[byte] += sum(state.root[c] * child.subtree[c] for c in range(self.class_count))
        for node_id, masses in state.active.items():
            node = self.nodes[node_id]
            for source_class, mass in enumerate(masses):
                denominator = node.descendants[source_class]
                if mass <= 0.0 or denominator <= 0.0:
                    continue
                for byte, child_id in node.children.items():
                    probs[byte] += mass * self.nodes[child_id].subtree[source_class] / denominator
        total = sum(probs)
        if total <= 0.0 or not math.isfinite(total):
            raise ValueError("empty surface frontier")
        return [probability / total for probability in probs]

    def advance(self, state: SurfaceState, byte: int) -> SurfaceState:
        if byte < 0 or byte > 255:
            raise ValueError("surface byte out of range")
        selected = 0.0
        new_root = [0.0] * self.class_count
        new_active: dict[int, list[float]] = {}

        def add_active(node_id: int, source_class: int, value: float) -> None:
            if value <= 0.0:
                return
            masses = new_active.setdefault(node_id, [0.0] * self.class_count)
            masses[source_class] += value

        root_node = self.nodes[0]
        root_child_id = root_node.children.get(byte)
        if root_child_id is not None:
            child = self.nodes[root_child_id]
            for source_class, root_mass in enumerate(state.root):
                if root_mass <= 0.0:
                    continue
                selected += root_mass * child.subtree[source_class]
                for destination, value in enumerate(child.terminal[source_class]):
                    new_root[destination] += root_mass * value
                add_active(root_child_id, source_class, root_mass * child.descendants[source_class])

        for node_id, masses in state.active.items():
            node = self.nodes[node_id]
            child_id = node.children.get(byte)
            if child_id is None:
                continue
            child = self.nodes[child_id]
            for source_class, mass in enumerate(masses):
                denominator = node.descendants[source_class]
                if mass <= 0.0 or denominator <= 0.0:
                    continue
                scale = mass / denominator
                selected += scale * child.subtree[source_class]
                for destination, value in enumerate(child.terminal[source_class]):
                    new_root[destination] += scale * value
                add_active(child_id, source_class, scale * child.descendants[source_class])

        if selected <= 0.0 or not math.isfinite(selected):
            raise ValueError("surface byte has zero model mass")
        inverse = 1.0 / selected
        return SurfaceState(
            [value * inverse for value in new_root],
            {
                node_id: [value * inverse for value in masses]
                for node_id, masses in new_active.items()
            },
        )


def header_for(raw_len: int, model: Model, mode: int) -> bytes:
    if raw_len < 0 or raw_len > MAX_RAW_LEN:
        raise ValueError("raw length is out of bounds")
    if mode not in (0, 1):
        raise ValueError("unknown frame mode")
    out = bytearray(MAGIC)
    out.append(mode)
    out.append(CDF_BITS)
    out.extend(varint(raw_len))
    out.extend(varint(model.class_count))
    out.extend(varint(len(model.tokens)))
    for token, destination in zip(model.tokens, model.next_class):
        out.extend(varint(len(token)))
        out.extend(token)
        out.append(destination)
    for row in model.freqs:
        for freq in row:
            out.extend(varint(freq))
    if len(out) > MAX_MODEL_BYTES:
        raise ValueError("model header is out of bounds")
    return bytes(out)


@dataclass
class ParsedFrame:
    mode: int
    raw_len: int
    model: Model
    payload: bytes
    path_count: int | None
    header_bytes: int


def parse_frame(frame: bytes) -> ParsedFrame:
    if len(frame) < 8 or len(frame) > MAX_FRAME_BYTES or frame[:4] != MAGIC:
        raise ValueError("bad surface-context magic")
    mode = frame[4]
    if mode not in (0, 1) or frame[5] != CDF_BITS:
        raise ValueError("unsupported surface-context header")
    at = 6
    raw_len, at = read_varint(frame, at)
    if raw_len > MAX_RAW_LEN:
        raise ValueError("raw length is out of bounds")
    class_count, at = read_varint(frame, at)
    token_count, at = read_varint(frame, at)
    if class_count < 1 or class_count > 16 or token_count < 256 or token_count > MAX_TOKEN_COUNT:
        raise ValueError("model dimensions are out of bounds")
    tokens: list[bytes] = []
    destinations: list[int] = []
    seen: set[bytes] = set()
    for _ in range(token_count):
        token_len, at = read_varint(frame, at)
        if token_len < 1 or token_len > MAX_TOKEN_LEN or token_len > len(frame) - at:
            raise ValueError("truncated token surface")
        token = frame[at : at + token_len]
        at += token_len
        if at >= len(frame) or token in seen:
            raise ValueError("duplicate token surface")
        destination = frame[at]
        at += 1
        seen.add(token)
        tokens.append(token)
        destinations.append(destination)
    freqs: list[list[int]] = []
    for _ in range(class_count):
        row: list[int] = []
        for _ in range(token_count):
            freq, at = read_varint(frame, at)
            if freq <= 0 or freq > MAX_TOTAL_FREQ:
                raise ValueError("invalid contextual row frequency")
            row.append(freq)
        freqs.append(row)
    if at - 6 > MAX_MODEL_BYTES:
        raise ValueError("model header is out of bounds")
    model = Model(tokens, destinations, freqs, class_count=class_count)
    header_bytes = at
    path_count: int | None = None
    if mode == 0:
        path_count, at = read_varint(frame, at)
        if path_count > raw_len + 1:
            raise ValueError("MAP path count exceeds raw length")
    payload_len, at = read_varint(frame, at)
    if payload_len < 8 or payload_len > MAX_FRAME_BYTES or payload_len != len(frame) - at:
        raise ValueError("truncated or trailing arithmetic payload")
    return ParsedFrame(mode, raw_len, model, frame[at:], path_count, header_bytes)


def _decode_map(parsed: ParsedFrame, *, verify_canonical: bool = True) -> bytes:
    assert parsed.path_count is not None
    decoder = ArithmeticDecoder(parsed.payload)
    restored = bytearray()
    offset = 0
    source_class = 0
    decoded_ids: list[int] = []
    for step in range(parsed.path_count):
        if offset >= parsed.raw_len:
            raise ValueError("MAP path has tokens after raw length")
        token_id = decoder.get(parsed.model.freqs[source_class])
        decoded_ids.append(token_id)
        token = parsed.model.tokens[token_id]
        end = offset + len(token)
        if end > parsed.raw_len and step != parsed.path_count - 1:
            raise ValueError("only final MAP token may cross raw length")
        restored.extend(token)
        offset = min(end, parsed.raw_len)
        source_class = parsed.model.next_class[token_id]
    if offset != parsed.raw_len:
        raise ValueError("MAP path ended before raw length")
    result = bytes(restored[: parsed.raw_len])
    if verify_canonical:
        canonical = ArithmeticEncoder()
        source_class = 0
        for token_id in decoded_ids:
            canonical.put(token_id, parsed.model.freqs[source_class])
            source_class = parsed.model.next_class[token_id]
        if canonical.finish() != parsed.payload:
            raise ValueError("non-canonical or corrupted MAP payload")
    return result


def _decode_marginal(parsed: ParsedFrame, *, verify_canonical: bool = True) -> bytes:
    decoder = ArithmeticDecoder(parsed.payload)
    state = parsed.model.initial_state()
    restored = bytearray()
    for _ in range(parsed.raw_len):
        probabilities = parsed.model.byte_probs(state)
        freqs = quantized_cdf(probabilities)
        byte = decoder.get(freqs)
        restored.append(byte)
        state = parsed.model.advance(state, byte)
    result = bytes(restored)
    if verify_canonical:
        canonical = ArithmeticEncoder()
        state = parsed.model.initial_state()
        for byte in result:
            canonical.put(byte, quantized_cdf(parsed.model.byte_probs(state)))
            state = parsed.model.advance(state, byte)
        if canonical.finish() != parsed.payload:
            raise ValueError("non-canonical or corrupted marginal payload")
    return result


def decode_frame(frame: bytes, *, verify_canonical: bool = True) -> bytes:
    parsed = parse_frame(frame)
    result = (
        _decode_map(parsed, verify_canonical=verify_canonical)
        if parsed.mode == 0
        else _decode_marginal(parsed, verify_canonical=verify_canonical)
    )
    if len(result) != parsed.raw_len:
        raise ValueError("decoded raw length mismatch")
    return result


def encode_map(data: bytes, model: Model) -> tuple[bytes, dict[str, float | int | bool]]:
    if len(data) > MAX_RAW_LEN:
        raise ValueError("raw length is out of bounds")
    path = viterbi_tokens(data, model)
    encoder = ArithmeticEncoder()
    source_class = 0
    exact_bits = 0.0
    for token_id in path:
        row = model.freqs[source_class]
        exact_bits += log2_prob(row[token_id], model.row_totals[source_class])
        encoder.put(token_id, row)
        source_class = model.next_class[token_id]
    payload = encoder.finish()
    frame = header_for(len(data), model, 0) + varint(len(path)) + varint(len(payload)) + payload
    ok = decode_frame(frame, verify_canonical=False) == data
    return frame, {
        "round_trip": ok,
        "path_tokens": len(path),
        "exact_model_bits": exact_bits,
        "payload_bits": len(payload) * 8,
        "underflow_events": encoder.underflow_events,
    }


def encode_marginal(data: bytes, model: Model) -> tuple[bytes, dict[str, float | int | bool]]:
    if len(data) > MAX_RAW_LEN:
        raise ValueError("raw length is out of bounds")
    encoder = ArithmeticEncoder()
    state = model.initial_state()
    exact_bits = 0.0
    for byte in data:
        probabilities = model.byte_probs(state)
        exact_bits -= math.log2(probabilities[byte])
        encoder.put(byte, quantized_cdf(probabilities))
        state = model.advance(state, byte)
    payload = encoder.finish()
    frame = header_for(len(data), model, 1) + varint(len(payload)) + payload
    ok = decode_frame(frame, verify_canonical=False) == data
    return frame, {
        "round_trip": ok,
        "exact_model_bits": exact_bits,
        "payload_bits": len(payload) * 8,
        "underflow_events": encoder.underflow_events,
    }


def enumerate_prefix_mass(prefix: bytes, model: Model) -> float:
    """Exhaustive tiny oracle for all token/class paths covering ``prefix``."""

    total = 0.0

    def visit(emitted: bytes, source_class: int, mass: float) -> None:
        nonlocal total
        if len(emitted) >= len(prefix):
            if emitted[: len(prefix)] == prefix:
                total += mass
            return
        for token_id, token in enumerate(model.tokens):
            candidate = emitted + token
            if candidate[: len(prefix)] != prefix[: len(candidate)]:
                continue
            probability = model.freqs[source_class][token_id] / model.row_totals[source_class]
            visit(candidate, model.next_class[token_id], mass * probability)

    visit(b"", 0, 1.0)
    return total


def enumerate_token_paths(prefix: bytes, model: Model) -> list[tuple[list[int], float]]:
    """Tiny exhaustive MAP/marginal path oracle for complete boundaries."""

    out: list[tuple[list[int], float]] = []

    def visit(emitted: bytes, source_class: int, path: list[int], mass: float) -> None:
        if emitted == prefix:
            out.append((list(path), mass))
            return
        for token_id, token in enumerate(model.tokens):
            end = len(emitted) + len(token)
            if end > len(prefix) or prefix[len(emitted) : end] != token:
                continue
            path.append(token_id)
            visit(
                emitted + token,
                model.next_class[token_id],
                path,
                mass * model.freqs[source_class][token_id] / model.row_totals[source_class],
            )
            path.pop()

    visit(b"", 0, [], 1.0)
    return out


def model_json(model: Model) -> dict[str, object]:
    return {
        "class_count": model.class_count,
        "token_count": len(model.tokens),
        "max_token_len": max(map(len, model.tokens)),
        "header_bytes_map": len(header_for(0, model, 0)),
        "header_bytes_marginal": len(header_for(0, model, 1)),
        "row_totals": model.row_totals,
        "next_class_histogram": dict(Counter(model.next_class)),
    }


def encode_both(data: bytes, model: Model) -> dict[str, object]:
    map_frame, map_stats = encode_map(data, model)
    marginal_frame, marginal_stats = encode_marginal(data, model)
    map_parsed = parse_frame(map_frame)
    marginal_parsed = parse_frame(marginal_frame)
    return {
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "model": model_json(model),
        "map": {
            **map_stats,
            "header_bytes": map_parsed.header_bytes,
            "frame_bytes": len(map_frame),
            "frame_sha256": hashlib.sha256(map_frame).hexdigest(),
        },
        "marginal": {
            **marginal_stats,
            "header_bytes": marginal_parsed.header_bytes,
            "frame_bytes": len(marginal_frame),
            "frame_sha256": hashlib.sha256(marginal_frame).hexdigest(),
        },
    }
