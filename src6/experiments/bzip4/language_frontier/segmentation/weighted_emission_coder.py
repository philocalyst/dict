#!/usr/bin/env python3
"""Lossless weighted piece-emission automaton (bounded research wire).

Unlike `atom_marginal_coder.py`, this file never stores a list of observed
surface atoms.  Its header stores only a bounded byte-piece vocabulary and
integer token weights.  A latent token sequence emits its bytes
deterministically.  MAP mode sends the Viterbi token-ID path; marginal mode
arithmetic-codes surface bytes from the exact posterior over a finite trie
frontier.  Both modes charge the same vocabulary header, raw length, CDF
precision, arithmetic flush, and payload.

The model is an infinite token stream truncated by the charged raw length. At
the root it chooses one token according to the integer PMF.  The marginal
coder keeps boundary masses for the last `max_piece` possible token starts and
trie nodes for their observed prefixes; descendants are represented by
subtree mass, so it does not expand one state per vocabulary token or store a
surface-word dictionary. Singleton bytes make every byte sequence decodable.
The v4 static codec is not modified by this lab prototype.  The floating-point
posterior is deliberately a research control: cross-architecture bitwise
frame portability is not promised until its CDF arithmetic is made canonical.
"""

from __future__ import annotations

import argparse
import bisect
import hashlib
import itertools
import json
import math
import os
from collections import Counter, defaultdict
from dataclasses import dataclass

from marginal_gap import atoms, build_inventory


TOP = (1 << 64) - 1
MASK = TOP
HALF = 1 << 63
FIRST_QTR = 1 << 62
THIRD_QTR = 3 << 62
CDF_SCALE = 1 << 20
# Safety limits for this research wire.  They bound parser allocations and
# keep integer arithmetic well away from the 64-bit coding interval's range.
MAX_RAW_LEN = 1 << 20
MAX_TOKEN_COUNT = 4096
MAX_TOKEN_LEN = 64
MAX_MODEL_BYTES = 1 << 20
MAX_TOTAL_FREQ = 1 << 40
MAX_FRAME_BYTES = 16 << 20


def varint(n: int) -> bytes:
    out = bytearray()
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)
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


def log2p(f: int, total: int) -> float:
    return math.log2(f / total)


def make_tokens(data: bytes, max_piece: int, min_occ: int, max_vocab: int) -> tuple[list[bytes], list[int]]:
    _, atom_freq = atoms(data)
    pieces = build_inventory(atom_freq, max_piece, min_occ, max_vocab)
    counts: Counter[bytes] = Counter()
    for byte in data:
        counts[bytes((byte,))] += 1
    for text, weight in atom_freq.items():
        for piece in pieces:
            start = 0
            while True:
                at = text.find(piece, start)
                if at < 0:
                    break
                counts[piece] += weight
                start = at + 1
    # Fixed additive smoothing gives every retained and singleton token a
    # positive integer PMF.  Counts and inventory are fully charged in the
    # frame header.
    tokens = [bytes((b,)) for b in range(256)] + pieces
    freq = [max(1, counts[token] + 1) for token in tokens]
    return tokens, freq


def logadd2(a: float, b: float) -> float:
    """Stable base-2 log-sum-exp for the bounded EM pass."""
    if a == -math.inf:
        return b
    if b == -math.inf:
        return a
    if a < b:
        a, b = b, a
    return a + math.log2(1.0 + math.exp2(b - a))


def em_fit_freqs(data: bytes, tokens: list[bytes], freqs: list[int], rounds: int) -> list[int]:
    """Fit unigram token weights with bounded forward/backward EM.

    The E-step scores the same renewal-prefix distribution used by the
    marginal coder.  It includes a final token that may cross the charged raw
    length, so this is not the complete-token-only count used by the cheap
    substring seed.  Frequencies are rounded expected usages and remain fully
    serialized in the frame header.  This intentionally small (normally two
    round) pass is a reproducible compressor policy, not an external model.
    """
    if rounds <= 0 or not data:
        return list(freqs)
    by_first: dict[int, list[int]] = defaultdict(list)
    for i, token in enumerate(tokens):
        by_first[token[0]].append(i)
    current = list(freqs)
    n = len(data)
    for _ in range(rounds):
        total = float(sum(current))
        logp = [math.log2(freq / total) for freq in current]
        # log_likelihood[at] is the probability that a fresh token stream
        # emits data[at:] as a prefix, conditional on a boundary at `at`.
        log_likelihood = [-math.inf] * (n + 1)
        log_likelihood[n] = 0.0
        for at in range(n - 1, -1, -1):
            remaining = n - at
            value = -math.inf
            for i in by_first.get(data[at], ()):
                token = tokens[i]
                length = len(token)
                if length <= remaining:
                    end = at + length
                    if data[at:end] == token:
                        value = logadd2(value, logp[i] + log_likelihood[end])
                elif token[:remaining] == data[at:n]:
                    # The charged raw length ends inside this final token.
                    value = logadd2(value, logp[i])
            log_likelihood[at] = value
        if log_likelihood[0] == -math.inf:
            raise ValueError("EM model cannot emit input prefix")

        # log_forward[at] is the probability of reaching an exact token
        # boundary at `at` while matching the observed prefix.
        log_forward = [-math.inf] * (n + 1)
        log_forward[0] = 0.0
        for at in range(n):
            if log_forward[at] == -math.inf:
                continue
            for i in by_first.get(data[at], ()):
                token = tokens[i]
                end = at + len(token)
                if end <= n and data[at:end] == token:
                    log_forward[end] = logadd2(log_forward[end], log_forward[at] + logp[i])

        expected = [0.0] * len(tokens)
        log_z = log_likelihood[0]
        for at in range(n):
            if log_forward[at] == -math.inf:
                continue
            remaining = n - at
            for i in by_first.get(data[at], ()):
                token = tokens[i]
                length = len(token)
                if length <= remaining:
                    end = at + length
                    if data[at:end] == token:
                        log_weight = log_forward[at] + logp[i] + log_likelihood[end] - log_z
                    else:
                        continue
                elif token[:remaining] == data[at:n]:
                    log_weight = log_forward[at] + logp[i] - log_z
                else:
                    continue
                expected[i] += 2.0**log_weight
        current = [max(1, int(round(value))) for value in expected]
    return current


class ArithmeticEncoder:
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

    def put(self, symbol: int, freqs: list[int]) -> None:
        cumulative = [0]
        for freq in freqs:
            cumulative.append(cumulative[-1] + freq)
        total = cumulative[-1]
        if total <= 0 or total > MAX_TOTAL_FREQ:
            raise ValueError("arithmetic model total is out of bounds")
        lo_count = cumulative[symbol]
        hi_count = cumulative[symbol + 1]
        span = self.high - self.low + 1
        self.high = self.low + (span * hi_count // total) - 1
        self.low += span * lo_count // total
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
        # A minimum 64-bit decoder seed makes the frame self-contained for both
        # tiny and large messages.  Pad only after the final arithmetic bit;
        # these zeros are charged payload bytes, not a free side channel.  The
        # finish is not eight terminal bytes appended after the stream.
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
        bit = (byte >> (7 - (self.bit_pos % 8))) & 1
        self.bit_pos += 1
        return bit

    def get(self, freqs: list[int]) -> int:
        cumulative = [0]
        for freq in freqs:
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


def quantized_byte_cdf(probs: list[float]) -> list[int]:
    # Every singleton is present, so probabilities are positive.  The fixed
    # denominator and minimum one make the CDF decoder total and deterministic
    # even when a model probability is below arithmetic precision.
    freqs = [max(1, int(round(prob * CDF_SCALE))) for prob in probs]
    return freqs


@dataclass(eq=False)
class TrieNode:
    """A byte-prefix node with token-terminal and descendant mass."""

    children: dict[int, "TrieNode"]
    terminal: float = 0.0
    subtree: float = 0.0


@dataclass
class EmissionState:
    """Normalized renewal frontier at one observed output prefix.

    ``root_mass`` is the probability mass whose token boundary is exactly at
    the current prefix.  Each active trie node stores the mass of the boundary
    from which a token started; the node's subtree mass accounts for all token
    choices that can still emit the observed suffix.  There can be at most one
    start per byte of the longest token, and equal trie nodes are merged.
    """

    root_mass: float
    active: dict[TrieNode, float]


@dataclass
class Model:
    tokens: list[bytes]
    freqs: list[int]
    require_singletons: bool = False

    def __post_init__(self) -> None:
        if len(self.tokens) != len(self.freqs):
            raise ValueError("token/frequency count mismatch")
        if not self.tokens or len(self.tokens) > MAX_TOKEN_COUNT:
            raise ValueError("token vocabulary is out of bounds")
        if any(not isinstance(freq, int) or isinstance(freq, bool) or freq <= 0 for freq in self.freqs):
            raise ValueError("token frequencies must be positive integers")
        self.total = sum(self.freqs)
        if self.total > MAX_TOTAL_FREQ:
            raise ValueError("token frequency total is out of bounds")
        self.by_first: dict[int, list[int]] = defaultdict(list)
        self.root = TrieNode({})
        self.max_piece = 0
        seen: set[bytes] = set()
        singleton_bytes: set[int] = set()
        for i, token in enumerate(self.tokens):
            if not token or len(token) > MAX_TOKEN_LEN or token in seen:
                raise ValueError("token is empty, too long, or duplicated")
            seen.add(token)
            if len(token) == 1:
                singleton_bytes.add(token[0])
            self.by_first[token[0]].append(i)
            self.max_piece = max(self.max_piece, len(token))
            node = self.root
            for byte in token:
                node = node.children.setdefault(byte, TrieNode({}))
            node.terminal += self.freqs[i] / self.total
        self.prob = [freq / self.total for freq in self.freqs]
        self._set_subtree_mass(self.root)
        if abs(self.root.subtree - 1.0) > 1.0e-12:
            raise ValueError("token trie is not normalized")
        self.has_full_singletons = singleton_bytes == set(range(256))
        if self.require_singletons and not self.has_full_singletons:
            raise ValueError("WAM frame must include every singleton byte")

    def _set_subtree_mass(self, node: TrieNode) -> float:
        node.subtree = node.terminal + sum(self._set_subtree_mass(child) for child in node.children.values())
        return node.subtree

    def initial_state(self) -> EmissionState:
        return EmissionState(1.0, {})

    def byte_probs(self, state: EmissionState) -> list[float]:
        """Return next-byte probabilities by summing trie-frontier mass."""
        probs = [0.0] * 256
        for byte, child in self.root.children.items():
            probs[byte] += state.root_mass * child.subtree
        for node, boundary_mass in state.active.items():
            # A token terminal at this node already contributed to root_mass
            # when the node was entered; only proper descendants can emit the
            # next byte from an active frontier.
            for byte, child in node.children.items():
                probs[byte] += boundary_mass * child.subtree
        total = sum(probs)
        if total <= 0.0:
            raise ValueError("empty automaton state")
        return [prob / total for prob in probs]

    def advance(self, state: EmissionState, byte: int) -> EmissionState:
        """Advance the normalized trie frontier after one surface byte."""
        selected = 0.0
        new_root = 0.0
        new_active: defaultdict[TrieNode, float] = defaultdict(float)

        root_child = self.root.children.get(byte)
        if root_child is not None:
            selected += state.root_mass * root_child.subtree
            new_root += state.root_mass * root_child.terminal
            if root_child.children:
                new_active[root_child] += state.root_mass

        for node, boundary_mass in state.active.items():
            child = node.children.get(byte)
            if child is None:
                continue
            selected += boundary_mass * child.subtree
            new_root += boundary_mass * child.terminal
            if child.children:
                new_active[child] += boundary_mass

        if selected <= 0.0:
            raise ValueError("surface byte has zero model mass")
        inv = 1.0 / selected
        return EmissionState(
            new_root * inv,
            {node: mass * inv for node, mass in new_active.items() if mass > 0.0},
        )


def viterbi_tokens(data: bytes, model: Model) -> list[int]:
    """Find a best token path, allowing a final token to be truncated.

    The marginal stream is conditioned on the charged raw length and therefore
    includes paths whose final token crosses that boundary.  Allowing the MAP
    baseline the same prefix semantics avoids attributing a boundary artifact
    to latent-path marginalization.  The decoder truncates the reconstructed
    token stream to the already charged raw length.
    """
    n = len(data)
    inf = float("inf")
    dp = [inf] * (n + 1)
    prev_pos = [-1] * (n + 1)
    prev_token = [-1] * (n + 1)
    dp[0] = 0.0
    token_cost = [-log2p(f, model.total) for f in model.freqs]
    for at in range(n):
        if dp[at] == inf:
            continue
        for i in model.by_first.get(data[at], ()):
            token = model.tokens[i]
            end = at + len(token)
            if end <= n:
                if data[at:end] != token:
                    continue
            elif token[: n - at] != data[at:n]:
                continue
            end = min(end, n)
            candidate = dp[at] + token_cost[i]
            if candidate < dp[end] - 1.0e-12:
                dp[end] = candidate
                prev_pos[end] = at
                prev_token[end] = i
    if prev_pos[n] < 0 and n != 0:
        raise ValueError("no Viterbi path")
    path: list[int] = []
    at = n
    while at:
        path.append(prev_token[at])
        at = prev_pos[at]
    path.reverse()
    return path


def header_for(raw_len: int, model: Model, mode: int) -> bytes:
    if raw_len < 0 or raw_len > MAX_RAW_LEN:
        raise ValueError("raw length is out of bounds")
    if mode not in (0, 1):
        raise ValueError("unknown weighted-emission mode")
    if not model.has_full_singletons:
        raise ValueError("WAM frame requires every singleton byte")
    out = bytearray(b"WAM1")
    out.append(mode)
    out.append(20)  # CDF precision, charged and fixed by the policy.
    out.extend(varint(raw_len))
    out.extend(varint(len(model.tokens)))
    for token, freq in zip(model.tokens, model.freqs):
        out.extend(varint(len(token)))
        out.extend(token)
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


def parse_frame(frame: bytes) -> ParsedFrame:
    """Parse and validate the complete self-delimiting research frame.

    The declared raw length and payload length are part of the model's
    charge.  Requiring the payload to end exactly at EOF is important here:
    arithmetic decoders conventionally pad a short input with zero bytes, so
    decoding a truncated stream must not silently look like a valid frame.
    """
    if len(frame) < 6 or len(frame) > MAX_FRAME_BYTES or frame[:4] != b"WAM1":
        raise ValueError("bad weighted-emission magic")
    mode = frame[4]
    if mode not in (0, 1):
        raise ValueError("unknown weighted-emission mode")
    if frame[5] != 20:
        raise ValueError("unsupported CDF precision")
    at = 6
    raw_len, at = read_varint(frame, at)
    if raw_len > MAX_RAW_LEN:
        raise ValueError("raw length is out of bounds")
    token_count, at = read_varint(frame, at)
    if token_count == 0 or token_count > MAX_TOKEN_COUNT:
        raise ValueError("token vocabulary is out of bounds")
    tokens: list[bytes] = []
    freqs: list[int] = []
    seen: set[bytes] = set()
    for _ in range(token_count):
        token_len, at = read_varint(frame, at)
        if token_len == 0 or token_len > MAX_TOKEN_LEN or token_len > len(frame) - at:
            raise ValueError("truncated token")
        token = frame[at : at + token_len]
        at += token_len
        freq, at = read_varint(frame, at)
        if freq == 0 or freq > MAX_TOTAL_FREQ or token in seen:
            raise ValueError("invalid or duplicate token")
        seen.add(token)
        tokens.append(token)
        freqs.append(freq)
    if at - 6 > MAX_MODEL_BYTES:
        raise ValueError("model header is out of bounds")
    path_count: int | None = None
    if mode == 0:
        path_count, at = read_varint(frame, at)
        if path_count > raw_len:
            raise ValueError("MAP path count exceeds raw length")
    payload_len, at = read_varint(frame, at)
    # finish() pads the complete payload to a minimum eight-byte decoder seed;
    # it does not append eight terminal bytes after the arithmetic stream.
    if payload_len < 8 or payload_len > MAX_FRAME_BYTES or payload_len != len(frame) - at:
        raise ValueError("truncated or trailing arithmetic payload")
    payload = frame[at : at + payload_len]
    return ParsedFrame(mode, raw_len, Model(tokens, freqs, require_singletons=True), payload, path_count)


def decode_frame(frame: bytes) -> bytes:
    """Decode either mode from a complete frame, checking its raw length."""
    parsed = parse_frame(frame)
    dec = ArithmeticDecoder(parsed.payload)
    restored = bytearray()
    decoded_ids: list[int] = []
    if parsed.mode == 0:
        assert parsed.path_count is not None
        offset = 0
        for step in range(parsed.path_count):
            if offset >= parsed.raw_len:
                raise ValueError("MAP path has tokens after raw length")
            token_id = dec.get(parsed.model.freqs)
            decoded_ids.append(token_id)
            token = parsed.model.tokens[token_id]
            end = offset + len(token)
            if end > parsed.raw_len:
                if step != parsed.path_count - 1:
                    raise ValueError("only the final MAP token may cross raw length")
                if end - parsed.raw_len > parsed.model.max_piece - 1:
                    raise ValueError("MAP final token overflow is out of bounds")
            offset = min(end, parsed.raw_len)
            restored.extend(token)
        if offset != parsed.raw_len:
            raise ValueError("MAP path ended before raw length")
        del restored[parsed.raw_len:]
    else:
        state = parsed.model.initial_state()
        for _ in range(parsed.raw_len):
            probs = parsed.model.byte_probs(state)
            byte = dec.get(quantized_byte_cdf(probs))
            restored.append(byte)
            state = parsed.model.advance(state, byte)
    if len(restored) != parsed.raw_len:
        raise ValueError("decoded raw length mismatch")
    result = bytes(restored)
    canonical = ArithmeticEncoder()
    if parsed.mode == 0:
        for token_id in decoded_ids:
            canonical.put(token_id, parsed.model.freqs)
    else:
        state = parsed.model.initial_state()
        for byte in result:
            canonical.put(byte, quantized_byte_cdf(parsed.model.byte_probs(state)))
            state = parsed.model.advance(state, byte)
    if canonical.finish() != parsed.payload:
        raise ValueError("non-canonical or corrupted arithmetic payload")
    return result


def encode_map(data: bytes, model: Model) -> tuple[bytes, bool]:
    if len(data) > MAX_RAW_LEN:
        raise ValueError("raw length is out of bounds")
    path = viterbi_tokens(data, model)
    enc = ArithmeticEncoder()
    for token_id in path:
        enc.put(token_id, model.freqs)
    payload = enc.finish()
    frame = header_for(len(data), model, 0) + varint(len(path)) + varint(len(payload)) + payload
    return frame, decode_frame(frame) == data


def encode_marginal(data: bytes, model: Model) -> tuple[bytes, bool]:
    frame, ok, _, _ = encode_marginal_with_stats(data, model)
    return frame, ok


def encode_marginal_with_stats(data: bytes, model: Model) -> tuple[bytes, bool, float, int]:
    """Encode marginal bytes and expose exact-vs-quantized coding cost.

    ``exact_bits`` is the negative log probability under the unquantized
    floating posterior used by the automaton.  ``payload_bits`` is the actual
    byte-aligned arithmetic payload, including the minimum eight-byte decoder
    seed/padding requirement.
    Their difference is diagnostic only; the frame also charges the model
    header and raw length.
    """
    if len(data) > MAX_RAW_LEN:
        raise ValueError("raw length is out of bounds")
    enc = ArithmeticEncoder()
    state = model.initial_state()
    exact_bits = 0.0
    for byte in data:
        probs = model.byte_probs(state)
        exact_bits -= math.log2(probs[byte])
        enc.put(byte, quantized_byte_cdf(probs))
        state = model.advance(state, byte)
    payload = enc.finish()
    frame = header_for(len(data), model, 1) + varint(len(payload)) + payload
    return frame, decode_frame(frame) == data, exact_bits, len(payload) * 8


def enumerate_token_paths(data: bytes, model: Model) -> list[tuple[bytes, float]]:
    """Tiny oracle: enumerate all token paths for short strings only."""
    out: list[tuple[bytes, float]] = []

    def visit(at: int, emitted: bytes, logprob: float) -> None:
        if at == len(data):
            out.append((emitted, logprob))
            return
        for i in model.by_first.get(data[at], ()):
            token = model.tokens[i]
            end = at + len(token)
            if end <= len(data) and data[at:end] == token:
                visit(end, emitted + token, logprob + math.log2(model.prob[i]))

    visit(0, b"", 0.0)
    return out


def enumerate_prefix_mass(prefix: bytes, model: Model) -> float:
    """Exact tiny oracle for the infinite stream's prefix probability.

    A path is complete once it emits at least the requested prefix.  Thus a
    final token is allowed to straddle the prefix boundary, exactly as the
    live-suffix automaton does.  This is deliberately only a short-string
    test oracle; production coding uses the merged floating-point state.
    """
    total = 0.0

    def visit(emitted: bytes, mass: float) -> None:
        nonlocal total
        if len(emitted) >= len(prefix):
            if emitted[: len(prefix)] == prefix:
                total += mass
            return
        for token, freq in zip(model.tokens, model.freqs):
            candidate = emitted + token
            if candidate[: len(prefix)] != prefix[: len(candidate)]:
                continue
            visit(candidate, mass * (freq / model.total))

    visit(b"", 1.0)
    return total


def enumerate_prefix_paths(prefix: bytes, model: Model) -> list[tuple[list[int], float]]:
    """Enumerate tiny prefix-compatible token paths for MAP auditing."""
    out: list[tuple[list[int], float]] = []

    def visit(emitted: bytes, path: list[int], logprob: float) -> None:
        if len(emitted) >= len(prefix):
            if emitted[: len(prefix)] == prefix:
                out.append((list(path), logprob))
            return
        for i, token in enumerate(model.tokens):
            candidate = emitted + token
            if candidate[: len(prefix)] != prefix[: len(candidate)]:
                continue
            path.append(i)
            visit(candidate, path, logprob + math.log2(model.prob[i]))
            path.pop()

    visit(b"", [], 0.0)
    return out


def self_test() -> None:
    # Force the midpoint-straddling (E3) renormalization path, then decode it
    # independently.  A common-top-byte-only coder can pass ordinary corpus
    # samples while eventually collapsing its integer interval here.
    arithmetic_freqs = [1, 2, 1]
    arithmetic_symbols = [1, 0, 2, 1, 1, 2, 0, 1]
    arithmetic_encoder = ArithmeticEncoder()
    for symbol in arithmetic_symbols:
        arithmetic_encoder.put(symbol, arithmetic_freqs)
    assert arithmetic_encoder.underflow_events > 0
    arithmetic_decoder = ArithmeticDecoder(arithmetic_encoder.finish())
    assert [arithmetic_decoder.get(arithmetic_freqs) for _ in arithmetic_symbols] == arithmetic_symbols

    em_tokens = [b"a", b"b", b"ab"]
    em_freqs = em_fit_freqs(b"abab", em_tokens, [1, 1, 1], 2)
    assert len(em_freqs) == len(em_tokens) and all(freq > 0 for freq in em_freqs)

    model = Model([b"a", b"b", b"ab"], [4, 4, 1])
    paths = enumerate_token_paths(b"ab", model)
    assert len(paths) == 2, paths
    masses = [2.0**logprob for _, logprob in paths]
    assert max(masses) <= sum(masses) + 1e-15
    # Complete-boundary DP agrees with exhaustive token-path enumeration; the
    # prefix oracle below deliberately tests the separate straddling case.
    complete_dp = [0.0] * 3
    complete_dp[0] = 1.0
    for at in range(2):
        for i in model.by_first.get(b"ab"[at], ()):
            token = model.tokens[i]
            end = at + len(token)
            if end <= 2 and b"ab"[at:end] == token:
                complete_dp[end] += complete_dp[at] * model.prob[i]
    assert abs(complete_dp[2] - sum(masses)) < 1e-15
    # Prefix-MAP has the same final-partial-token semantics as the marginal
    # coder, rather than receiving an accidental complete-boundary advantage.
    for prefix in (b"a", b"ab", b"aba"):
        prefix_paths = enumerate_prefix_paths(prefix, model)
        best_prefix = max(logprob for _, logprob in prefix_paths)
        map_path = viterbi_tokens(prefix, model)
        map_logprob = sum(math.log2(model.prob[i]) for i in map_path)
        assert abs(map_logprob - best_prefix) < 1e-12, (prefix, map_logprob, best_prefix)
    # Exhaustive short-prefix check: multiplying the automaton's normalized
    # next-byte probabilities must equal direct path enumeration, including a
    # token that straddles the requested prefix boundary.
    for length in range(4):
        for symbols in itertools.product(b"ab", repeat=length):
            prefix = bytes(symbols)
            state = model.initial_state()
            chain_mass = 1.0
            for byte in prefix:
                probs = model.byte_probs(state)
                assert abs(sum(probs) - 1.0) < 1e-12
                chain_mass *= probs[byte]
                state = model.advance(state, byte)
                assert len(state.active) <= model.max_piece - 1
            oracle_mass = enumerate_prefix_mass(prefix, model)
            assert abs(chain_mass - oracle_mass) < 1e-12, (prefix, chain_mass, oracle_mass)
    # A model with no multi-byte aliases has one parse for every string over
    # its alphabet, hence MAP and marginal complete-path masses coincide.
    unique = Model([b"a", b"b"], [4, 4])
    unique_paths = enumerate_token_paths(b"ab", unique)
    assert len(unique_paths) == 1
    assert abs(max(2.0**p for _, p in unique_paths) - sum(2.0**p for _, p in unique_paths)) < 1e-15
    for raw in (b"", b"a", b"ab", b"aba", bytes(range(32))):
        m = Model([bytes((b,)) for b in range(256)] + [b"ab", b"aba"], [1] * 256 + [3, 2])
        map_frame, map_ok = encode_map(raw, m)
        marginal_frame, marginal_ok = encode_marginal(raw, m)
        assert map_ok and marginal_ok, (raw, map_ok, marginal_ok)
        assert decode_frame(map_frame) == raw
        assert decode_frame(marginal_frame) == raw
        try:
            decode_frame(marginal_frame[:-1])
        except ValueError:
            pass
        else:
            raise AssertionError("truncated frame decoded successfully")
        try:
            decode_frame(marginal_frame + b"\x00")
        except ValueError:
            pass
        else:
            raise AssertionError("trailing frame bytes accepted")

    # Altered payload length plus truncation is not enough to fool the
    # self-delimiting parser: canonical re-encoding must also match every
    # payload bit, including padding bits that arithmetic decoding may not
    # consume.
    stress_raw = bytes(range(256)) * 4
    stress_model = Model([bytes((b,)) for b in range(256)], [1] * 256, require_singletons=True)
    stress_frame, stress_ok = encode_marginal(stress_raw, stress_model)
    assert stress_ok
    parsed_stress = parse_frame(stress_frame)
    payload_start = len(stress_frame) - len(parsed_stress.payload)
    varint_start = payload_start - 1
    while varint_start > 0 and stress_frame[varint_start - 1] & 0x80:
        varint_start -= 1
    truncated = stress_frame[:-1]
    altered_length = len(truncated) - payload_start
    altered = truncated[:varint_start] + varint(altered_length) + truncated[payload_start:]
    try:
        decode_frame(altered)
    except ValueError:
        pass
    else:
        raise AssertionError("altered length plus truncation accepted")
    corrupted = bytearray(stress_frame)
    corrupted[-1] ^= 1
    try:
        decode_frame(bytes(corrupted))
    except ValueError:
        pass
    else:
        raise AssertionError("non-canonical payload accepted")

    # Parser resource limits are checked before any vocabulary allocation or
    # trie construction.
    oversized_raw = b"WAM1\x01\x14" + varint(MAX_RAW_LEN + 1)
    try:
        parse_frame(oversized_raw)
    except ValueError:
        pass
    else:
        raise AssertionError("oversized raw length accepted")
    try:
        Model([b"a"], [MAX_TOTAL_FREQ + 1])
    except ValueError:
        pass
    else:
        raise AssertionError("oversized model weight accepted")


def run_one(data: bytes, max_piece: int, min_occ: int, max_vocab: int, em_rounds: int = 0) -> list[dict[str, object]]:
    tokens, freqs = make_tokens(data, max_piece, min_occ, max_vocab)
    if em_rounds:
        freqs = em_fit_freqs(data, tokens, freqs, em_rounds)
    model = Model(tokens, freqs)
    map_frame, map_ok = encode_map(data, model)
    marginal_frame, marginal_ok, exact_marginal_bits, marginal_payload_bits = encode_marginal_with_stats(data, model)
    parsed_map = parse_frame(map_frame)
    map_path = viterbi_tokens(data, model)
    exact_map_bits = sum(-log2p(model.freqs[token_id], model.total) for token_id in map_path)
    map_payload_bits = len(parsed_map.payload) * 8
    return [
        {
            "mode": "map",
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "tokens": len(tokens),
            "piece_tokens": len(tokens) - 256,
            "em_rounds": em_rounds,
            "header_bytes": len(header_for(len(data), model, 0)),
            "frame_bytes": len(map_frame),
            "exact_model_bits": exact_map_bits,
            "payload_bits": map_payload_bits,
            "payload_minus_exact_bits": map_payload_bits - exact_map_bits,
            "round_trip": map_ok,
            "frame_sha256": hashlib.sha256(map_frame).hexdigest(),
        },
        {
            "mode": "marginal",
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "tokens": len(tokens),
            "piece_tokens": len(tokens) - 256,
            "em_rounds": em_rounds,
            "header_bytes": len(header_for(len(data), model, 1)),
            "frame_bytes": len(marginal_frame),
            "exact_model_bits": exact_marginal_bits,
            "payload_bits": marginal_payload_bits,
            "payload_minus_exact_bits": marginal_payload_bits - exact_marginal_bits,
            "round_trip": marginal_ok,
            "frame_sha256": hashlib.sha256(marginal_frame).hexdigest(),
        },
    ]


def mixed_control() -> bytes:
    """Deterministic multilingual/invalid-byte fixture, byte-preserving."""
    text = "Cafe\u0301 東京\nПривет مرحبا\tAaAa 123123\x00\n".encode("utf-8")
    return (text + bytes([0xFF, 0xFE, 0xC3, 0x28, 0x80, 0x00])) * 256


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--max-piece", type=int, default=8)
    ap.add_argument("--min-occ", type=int, default=2)
    ap.add_argument("--max-vocab", type=int, default=512)
    ap.add_argument("--em-rounds", type=int, default=0, help="bounded forward/backward unigram EM rounds (0 keeps substring seed)")
    ap.add_argument("--mixed-control", action="store_true", help="also run a deterministic multilingual/invalid-byte fixture")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    self_test()
    rows: list[dict[str, object]] = []
    for path in args.paths:
        with open(path, "rb") as stream:
            data = stream.read(args.limit or -1)
        rows.extend({"path": os.path.abspath(path), **row} for row in run_one(data, args.max_piece, args.min_occ, args.max_vocab, args.em_rounds))
    if args.mixed_control:
        data = mixed_control()
        rows.extend({"path": "<mixed-control>", **row} for row in run_one(data, args.max_piece, args.min_occ, args.max_vocab, args.em_rounds))
    if args.json:
        print(json.dumps(rows, sort_keys=True))
    else:
        print("path\tmode\tbytes\ttokens\tpiece_tokens\theader_bytes\tframe_bytes\tround_trip\tsha256\tframe_sha256")
        for row in rows:
            print("\t".join(str(row[k]) for k in ("path", "mode", "bytes", "tokens", "piece_tokens", "header_bytes", "frame_bytes", "round_trip", "sha256", "frame_sha256")))


if __name__ == "__main__":
    main()
