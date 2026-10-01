#!/usr/bin/env python3
"""A tiny compiled latent-belief transducer for lossless byte experiments.

The encoder may use a floating-point HMM teacher.  The frame never contains
the teacher, though: it contains only integer CDF rows and a next-state table.
Decoding therefore performs a table lookup, a range-code update, and a state
assignment.  This is deliberately a research artifact, not a replacement for
the native bz4 implementation.

Protocol (LBEL1):

    magic/version/flags, HMM state count, compiled state count, alphabet,
    range precision, restart interval, output length, restart count,
    exact byte length of this header, then for each compiled state a complete
    uint16 CDF (258 entries) and uint16 next-state row (257 entries), followed
    by restart records (output offset, initial state, payload length), payloads
    and a CRC32 over everything before the checksum.

The 257th symbol is EOS.  Non-final restart segments code exactly their known
number of bytes; the final segment codes those bytes followed by EOS.  Length
is still explicit and charged, while EOS makes the causal distribution a
normalized variable-length source.  Restart state IDs are explicit and checked
against the prior segment's state transition.
"""

from __future__ import annotations

import hashlib
import math
import struct
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence


BYTE_ALPHABET = 256
EOS = 256
ALPHABET = 257
TOTAL = 1 << 14
MAGIC = b"LBEL"
VERSION = 1
MAX_OUTPUT = 1 << 26
MAX_STATES = 64
MAX_PAYLOAD = 1 << 28
RANGE_PRECISION = 32
RANGE_TOP = 1 << RANGE_PRECISION
MASK32 = RANGE_TOP - 1
HALF = RANGE_TOP >> 1
FIRST_QUARTER = RANGE_TOP >> 2
THIRD_QUARTER = FIRST_QUARTER * 3


class FrameError(ValueError):
    """Malformed or truncated LBEL frame."""


def _normalize(v: Sequence[float]) -> list[float]:
    if any((not math.isfinite(x)) or x < 0.0 for x in v):
        raise ValueError("probability vector contains a negative or non-finite value")
    s = sum(v)
    if not (s > 0.0) or not math.isfinite(s):
        raise ValueError("non-positive probability vector")
    return [x / s for x in v]


def _safe_log2(p: float) -> float:
    return -math.log2(max(p, 1e-300))


@dataclass(frozen=True)
class HMM:
    """Teacher parameters; never serialized in an LBEL frame."""

    initial: tuple[float, ...]
    transition: tuple[tuple[float, ...], ...]
    emission: tuple[tuple[float, ...], ...]

    @property
    def states(self) -> int:
        return len(self.initial)


@dataclass(frozen=True)
class Compiled:
    """Everything the decoder needs, all integer and frame-chargeable."""

    cdf: tuple[tuple[int, ...], ...]
    next_state: tuple[tuple[int, ...], ...]
    representatives: tuple[tuple[float, ...], ...]
    teacher_states: int
    clustering: str

    @property
    def states(self) -> int:
        return len(self.cdf)


@dataclass(frozen=True)
class Restart:
    offset: int
    state: int
    payload: bytes


@dataclass(frozen=True)
class FrameStats:
    total: int
    header: int
    tables: int
    restarts: int
    payload: int
    checksum: int
    output: int
    segments: int


def initial_model(data: bytes, states: int) -> HMM:
    """Deterministically initialize a small sticky HMM from byte counts.

    This is not an external language model.  The training input is explicit,
    local, and frozen by the screen harness.  Symbol modulo-state boosts keep
    the initial rows distinguishable before EM; subsequent rows are learned.
    """

    if states < 1:
        raise ValueError("states must be positive")
    counts = [1.0] * ALPHABET
    for b in data:
        counts[b] += 1.0
    counts[EOS] += 1.0
    total = sum(counts)
    global_p = [x / total for x in counts]

    initial = [1.0 / states] * states
    transition: list[list[float]] = []
    for i in range(states):
        row = [0.0] * states
        for j in range(states):
            row[j] = 1.0 if states == 1 else (0.72 if i == j else 0.28 / (states - 1))
        transition.append(row)

    emission: list[list[float]] = []
    for i in range(states):
        row: list[float] = []
        for symbol, p in enumerate(global_p):
            # The deterministic residue partition is merely an initialization
            # device.  It is not exposed to, or assumed by, the decoder.
            boost = 2.75 if symbol != EOS and symbol % states == i else 1.0
            row.append(p * boost)
        emission.append(_normalize(row))
    return HMM(tuple(initial), tuple(tuple(r) for r in transition), tuple(tuple(r) for r in emission))


def _forward_backward(hmm: HMM, observations: Sequence[int]) -> tuple[list[list[float]], list[float], list[list[float]]]:
    """Scaled forward/backward pass returning alpha, scales, beta."""

    k = hmm.states
    n = len(observations)
    if n == 0:
        raise ValueError("HMM requires EOS observation")
    alpha: list[list[float]] = [[0.0] * k for _ in range(n)]
    scales = [0.0] * n

    for state in range(k):
        alpha[0][state] = hmm.initial[state] * hmm.emission[state][observations[0]]
    scales[0] = sum(alpha[0])
    if scales[0] <= 0.0:
        raise ValueError("underflow at HMM start")
    alpha[0] = [x / scales[0] for x in alpha[0]]
    for t in range(1, n):
        prev = alpha[t - 1]
        row = alpha[t]
        symbol = observations[t]
        for j in range(k):
            row[j] = sum(prev[i] * hmm.transition[i][j] for i in range(k)) * hmm.emission[j][symbol]
        scales[t] = sum(row)
        if scales[t] <= 0.0:
            raise ValueError("underflow in HMM forward pass")
        for j in range(k):
            row[j] /= scales[t]

    beta: list[list[float]] = [[0.0] * k for _ in range(n)]
    beta[-1] = [1.0] * k
    for t in range(n - 2, -1, -1):
        nxt = observations[t + 1]
        for i in range(k):
            beta[t][i] = sum(
                hmm.transition[i][j] * hmm.emission[j][nxt] * beta[t + 1][j]
                for j in range(k)
            ) / scales[t + 1]
    return alpha, scales, beta


def train_hmm(data: bytes, states: int, iterations: int = 6) -> HMM:
    """Train a deterministic small HMM with Baum--Welch EM."""

    if not data:
        raise ValueError("cannot train on empty data")
    observations = list(data) + [EOS]
    hmm = initial_model(data, states)
    k = states
    for _ in range(iterations):
        alpha, scales, beta = _forward_backward(hmm, observations)
        gamma: list[list[float]] = [[0.0] * k for _ in observations]
        for t in range(len(observations)):
            row = [alpha[t][i] * beta[t][i] for i in range(k)]
            z = sum(row)
            if z <= 0.0:
                row = [1.0 / k] * k
            else:
                row = [x / z for x in row]
            gamma[t] = row

        initial = list(gamma[0])
        transition_counts = [[1e-5] * k for _ in range(k)]
        for t in range(len(observations) - 1):
            nxt = observations[t + 1]
            denom = 0.0
            xi = [[0.0] * k for _ in range(k)]
            for i in range(k):
                for j in range(k):
                    value = alpha[t][i] * hmm.transition[i][j] * hmm.emission[j][nxt] * beta[t + 1][j]
                    xi[i][j] = value
                    denom += value
            if denom > 0.0:
                for i in range(k):
                    for j in range(k):
                        transition_counts[i][j] += xi[i][j] / denom
        transition = [_normalize(row) for row in transition_counts]

        emission_counts = [[1e-5] * ALPHABET for _ in range(k)]
        for t, symbol in enumerate(observations):
            for i in range(k):
                emission_counts[i][symbol] += gamma[t][i]
        emission = [_normalize(row) for row in emission_counts]
        hmm = HMM(tuple(_normalize(initial)), tuple(tuple(r) for r in transition), tuple(tuple(r) for r in emission))
    return hmm


def predictive(hmm: HMM, belief: Sequence[float]) -> list[float]:
    """p(next symbol | belief), before emitting the next symbol."""

    return [sum(belief[i] * hmm.emission[i][symbol] for i in range(hmm.states)) for symbol in range(ALPHABET)]


def advance(hmm: HMM, belief: Sequence[float], symbol: int) -> list[float]:
    """Exact HMM belief update after a symbol."""

    p = sum(belief[i] * hmm.emission[i][symbol] for i in range(hmm.states))
    if p <= 0.0:
        raise ValueError("zero-probability teacher transition")
    posterior = [belief[i] * hmm.emission[i][symbol] / p for i in range(hmm.states)]
    return _normalize([sum(posterior[i] * hmm.transition[i][j] for i in range(hmm.states)) for j in range(hmm.states)])


def observed_beliefs(hmm: HMM, data: bytes, stride: int = 4) -> list[list[float]]:
    """Sample teacher beliefs reached on the frozen training stream."""

    out: list[list[float]] = [list(hmm.initial)]
    belief = list(hmm.initial)
    for index, symbol in enumerate(list(data) + [EOS]):
        if index % max(1, stride) == 0:
            out.append(list(belief))
        belief = advance(hmm, belief, symbol)
    return out


def _distance(a: Sequence[float], b: Sequence[float]) -> float:
    return sum((x - y) * (x - y) for x, y in zip(a, b))


def _mean(vectors: Sequence[Sequence[float]]) -> list[float]:
    if not vectors:
        raise ValueError("empty cluster")
    d = len(vectors[0])
    return _normalize([sum(v[i] for v in vectors) / len(vectors) for i in range(d)])


def cluster_beliefs(samples: Sequence[Sequence[float]], states: int, mode: str) -> list[list[float]]:
    """Compile observed beliefs into deterministic representative states.

    State zero is always the true initial belief: the decoder's first row is
    not a centroid that silently differs from the model's declared start.
    ``observed`` is nearest-centroid refinement; ``balanced`` sorts by the
    first posterior coordinate and gives each row an equal observed mass.  The
    latter is an intentionally simple ablation, not a hidden selector.
    """

    if states < 1 or states > len(samples):
        raise ValueError("invalid compiled state count")
    if mode not in {"observed", "balanced"}:
        raise ValueError("clustering mode must be observed or balanced")
    q0 = list(samples[0])
    if states == 1:
        return [q0]
    if mode == "balanced":
        ordered = sorted((list(s) for s in samples[1:]), key=lambda q: (q[0], tuple(q)))
        centers = [q0]
        # Equal-count groups make table rows observable rather than assigning
        # one row to a tiny tail of the teacher trajectory.
        n = len(ordered)
        for c in range(states - 1):
            lo = (c * n) // (states - 1)
            hi = ((c + 1) * n) // (states - 1)
            centers.append(_mean(ordered[lo:hi] or [q0]))
        return centers

    centers: list[list[float]] = [q0]
    # Farthest-point deterministic seeding, then 8 fixed refinement rounds.
    for _ in range(states - 1):
        candidate = max(
            samples,
            key=lambda q: (min(_distance(q, center) for center in centers), tuple(q)),
        )
        centers.append(list(candidate))
    for _ in range(8):
        groups: list[list[list[float]]] = [[] for _ in centers]
        for q in samples:
            which = min(range(len(centers)), key=lambda i: (_distance(q, centers[i]), i))
            groups[which].append(list(q))
        # Keep row zero exactly at q0 so initial-state semantics are explicit.
        centers[0] = q0
        for i in range(1, len(centers)):
            if groups[i]:
                centers[i] = _mean(groups[i])
    return centers


def quantize_probabilities(probabilities: Sequence[float], total: int = TOTAL) -> tuple[int, ...]:
    """Round a distribution to positive integer frequencies exactly summing total."""

    if len(probabilities) != ALPHABET or total < ALPHABET:
        raise ValueError("bad alphabet or range total")
    p = _normalize(probabilities)
    spare = total - ALPHABET
    raw = [x * spare for x in p]
    floor = [int(x) for x in raw]
    frequencies = [1 + x for x in floor]
    left = spare - sum(floor)
    order = sorted(range(ALPHABET), key=lambda i: (-(raw[i] - floor[i]), i))
    for i in order[:left]:
        frequencies[i] += 1
    if sum(frequencies) != total or any(x <= 0 for x in frequencies):
        raise AssertionError("CDF quantization failed")
    return tuple(frequencies)


def _cdf_from_frequencies(frequencies: Sequence[int]) -> tuple[int, ...]:
    result = [0]
    for f in frequencies:
        result.append(result[-1] + int(f))
    return tuple(result)


def compile_model(hmm: HMM, data: bytes, compiled_states: int, mode: str) -> Compiled:
    """Compile representative-belief rows and finite transitions."""

    samples = observed_beliefs(hmm, data)
    representatives = cluster_beliefs(samples, compiled_states, mode)
    cdfs: list[tuple[int, ...]] = []
    transitions: list[tuple[int, ...]] = []
    for belief in representatives:
        probabilities = predictive(hmm, belief)
        cdfs.append(_cdf_from_frequencies(quantize_probabilities(probabilities)))
        next_row: list[int] = []
        for symbol in range(ALPHABET):
            next_belief = advance(hmm, belief, symbol)
            which = min(
                range(len(representatives)),
                key=lambda i: (_distance(next_belief, representatives[i]), i),
            )
            next_row.append(which)
        transitions.append(tuple(next_row))
    return Compiled(
        cdf=tuple(cdfs),
        next_state=tuple(transitions),
        representatives=tuple(tuple(q) for q in representatives),
        teacher_states=hmm.states,
        clustering=mode,
    )


def teacher_cross_entropy(hmm: HMM, data: bytes) -> float:
    belief = list(hmm.initial)
    total = 0.0
    for symbol in list(data) + [EOS]:
        total += _safe_log2(predictive(hmm, belief)[symbol])
        belief = advance(hmm, belief, symbol)
    return total


def compiled_cross_entropy(compiled: Compiled, data: bytes) -> float:
    state = 0
    total = 0.0
    for symbol in list(data) + [EOS]:
        cdf = compiled.cdf[state]
        total += _safe_log2((cdf[symbol + 1] - cdf[symbol]) / TOTAL)
        state = compiled.next_state[state][symbol]
    return total


class _RangeEncoder:
    def __init__(self) -> None:
        self.low = 0
        self.high = MASK32
        self.pending = 0
        self.bits: list[int] = []

    def _emit(self, bit: int) -> None:
        self.bits.append(bit)
        fill = 1 - bit
        while self.pending:
            self.bits.append(fill)
            self.pending -= 1

    def symbol(self, cdf: Sequence[int], symbol: int) -> None:
        start, end = cdf[symbol], cdf[symbol + 1]
        span = self.high - self.low + 1
        self.high = self.low + (span * end // TOTAL) - 1
        self.low = self.low + (span * start // TOTAL)
        while True:
            if self.high < HALF:
                self._emit(0)
            elif self.low >= HALF:
                self._emit(1)
                self.low -= HALF
                self.high -= HALF
            elif self.low >= FIRST_QUARTER and self.high < THIRD_QUARTER:
                self.pending += 1
                self.low -= FIRST_QUARTER
                self.high -= FIRST_QUARTER
            else:
                break
            self.low <<= 1
            self.high = (self.high << 1) | 1

    def finish(self) -> bytes:
        self.pending += 1
        self._emit(0 if self.low < FIRST_QUARTER else 1)
        while len(self.bits) % 8:
            self.bits.append(0)
        out = bytearray()
        for at in range(0, len(self.bits), 8):
            byte = 0
            for bit in self.bits[at : at + 8]:
                byte = (byte << 1) | bit
            out.append(byte)
        return bytes(out)


class _RangeDecoder:
    def __init__(self, payload: bytes) -> None:
        if not payload:
            raise FrameError("empty range payload")
        self.payload = payload
        self.position = 0
        self.bit_position = 0
        self.low = 0
        self.high = MASK32
        self.code = 0
        for _ in range(RANGE_PRECISION):
            self.code = (self.code << 1) | self._read_bit()

    def _read_bit(self) -> int:
        if self.position >= len(self.payload):
            return 0
        bit = (self.payload[self.position] >> (7 - self.bit_position)) & 1
        self.bit_position += 1
        if self.bit_position == 8:
            self.position += 1
            self.bit_position = 0
        return bit

    def symbol(self, cdf: Sequence[int]) -> int:
        span = self.high - self.low + 1
        if span <= 0:
            raise FrameError("invalid range span")
        count = ((self.code - self.low + 1) * TOTAL - 1) // span
        if count < 0 or count >= TOTAL:
            raise FrameError("range count outside CDF")
        # Small alphabets make a linear scan transparent and deterministic;
        # this is intentionally replaceable by a binary search in native code.
        symbol = 0
        while symbol + 1 < len(cdf) and cdf[symbol + 1] <= count:
            symbol += 1
        if symbol >= ALPHABET:
            raise FrameError("CDF lookup overflow")
        self.high = self.low + (span * cdf[symbol + 1] // TOTAL) - 1
        self.low = self.low + (span * cdf[symbol] // TOTAL)
        while True:
            if self.high < HALF:
                pass
            elif self.low >= HALF:
                self.low -= HALF
                self.high -= HALF
                self.code -= HALF
            elif self.low >= FIRST_QUARTER and self.high < THIRD_QUARTER:
                self.low -= FIRST_QUARTER
                self.high -= FIRST_QUARTER
                self.code -= FIRST_QUARTER
            else:
                break
            self.low <<= 1
            self.high = (self.high << 1) | 1
            self.code = (self.code << 1) | self._read_bit()
        return symbol


def _pack_tables(compiled: Compiled) -> bytes:
    out = bytearray()
    for row in compiled.cdf:
        if len(row) != ALPHABET + 1 or row[-1] != TOTAL:
            raise ValueError("invalid CDF row")
        out.extend(struct.pack("<" + "H" * len(row), *row))
    for row in compiled.next_state:
        if len(row) != ALPHABET or any(x >= compiled.states for x in row):
            raise ValueError("invalid next-state row")
        out.extend(struct.pack("<" + "H" * len(row), *row))
    return bytes(out)


def _unpack_tables(raw: bytes, states: int) -> tuple[tuple[tuple[int, ...], ...], tuple[tuple[int, ...], ...], int]:
    table_bytes = states * (ALPHABET + 1 + ALPHABET) * 2
    if len(raw) < table_bytes:
        raise FrameError("truncated model tables")
    pos = 0
    cdfs: list[tuple[int, ...]] = []
    for _ in range(states):
        size = (ALPHABET + 1) * 2
        row = tuple(struct.unpack("<" + "H" * (ALPHABET + 1), raw[pos : pos + size]))
        pos += size
        if row[0] != 0 or row[-1] != TOTAL or any(row[i] >= row[i + 1] for i in range(ALPHABET)):
            raise FrameError("invalid CDF table")
        cdfs.append(row)
    next_rows: list[tuple[int, ...]] = []
    for _ in range(states):
        size = ALPHABET * 2
        row = tuple(struct.unpack("<" + "H" * ALPHABET, raw[pos : pos + size]))
        pos += size
        if any(x >= states for x in row):
            raise FrameError("next-state reference out of bounds")
        next_rows.append(row)
    return tuple(cdfs), tuple(next_rows), pos


def encode_frame(data: bytes, compiled: Compiled, restart_interval: int = 4096) -> tuple[bytes, FrameStats]:
    """Encode bytes with a compiled model and charged restart segments."""

    if len(data) > MAX_OUTPUT:
        raise ValueError("output too large")
    if restart_interval < 1 or restart_interval > MAX_OUTPUT:
        raise ValueError("bad restart interval")
    tables = _pack_tables(compiled)
    records: list[Restart] = []
    state = 0
    offset = 0
    if not data:
        cuts = [0]
    else:
        cuts = list(range(0, len(data), restart_interval))
    for segment_index, start in enumerate(cuts):
        end = min(len(data), start + restart_interval)
        coder = _RangeEncoder()
        current = state
        for value in data[start:end]:
            coder.symbol(compiled.cdf[current], value)
            current = compiled.next_state[current][value]
        if end == len(data):
            coder.symbol(compiled.cdf[current], EOS)
        payload = coder.finish()
        records.append(Restart(start, state, payload))
        state = current
        offset = end
        del segment_index, offset

    header_len = 4 + 1 + 1 + 1 + 1 + 2 + 2 + 4 + 4 + 2 + 4
    header_len += len(tables) + len(records) * 10
    header = bytearray()
    header.extend(MAGIC)
    header.extend(struct.pack("<BBBBHHIIHI", VERSION, 0, compiled.teacher_states, compiled.states,
                              ALPHABET, TOTAL, restart_interval, len(data), len(records), header_len))
    header.extend(tables)
    for record in records:
        header.extend(struct.pack("<IHI", record.offset, record.state, len(record.payload)))
    body = bytes(header) + b"".join(r.payload for r in records)
    checksum = zlib.crc32(body) & 0xFFFFFFFF
    frame = body + struct.pack("<I", checksum)
    stats = FrameStats(
        total=len(frame),
        header=header_len,
        tables=len(tables),
        restarts=len(records) * 10,
        payload=sum(len(r.payload) for r in records),
        checksum=4,
        output=len(data),
        segments=len(records),
    )
    return frame, stats


def _parse_header(frame: bytes) -> tuple[Compiled, int, int, list[tuple[int, int, int]]]:
    fixed = 4 + 1 + 1 + 1 + 1 + 2 + 2 + 4 + 4 + 2 + 4
    if len(frame) < fixed + 4 or frame[:4] != MAGIC:
        raise FrameError("bad LBEL magic or short frame")
    version, flags, teacher_states, states, alphabet, total, restart_interval, output_len, count, header_len = struct.unpack(
        "<BBBBHHIIHI", frame[4:fixed]
    )
    if version != VERSION or flags != 0 or alphabet != ALPHABET or total != TOTAL:
        raise FrameError("unsupported frame parameters")
    if not (1 <= teacher_states <= MAX_STATES and 1 <= states <= MAX_STATES):
        raise FrameError("state count outside safety bound")
    if output_len > MAX_OUTPUT or restart_interval < 1 or count < 1 or count > output_len + 1:
        raise FrameError("invalid output/restart limits")
    expected_tables = states * (ALPHABET + 1 + ALPHABET) * 2
    expected_header = fixed + expected_tables + count * 10
    if header_len != expected_header or header_len > len(frame) - 4:
        raise FrameError("invalid header length")
    cdfs, next_rows, pos = _unpack_tables(frame[fixed : fixed + expected_tables], states)
    if pos != expected_tables:
        raise FrameError("table parser mismatch")
    records: list[tuple[int, int, int]] = []
    at = fixed + expected_tables
    previous = -1
    for _ in range(count):
        offset, state, payload_len = struct.unpack("<IHI", frame[at : at + 10])
        at += 10
        if state >= states or offset <= previous or offset > output_len:
            raise FrameError("invalid restart record")
        if payload_len > MAX_PAYLOAD:
            raise FrameError("payload exceeds safety bound")
        records.append((offset, state, payload_len))
        previous = offset
    if records[0][0] != 0 or records[-1][0] != output_len:
        # For a non-empty stream the last record starts before output_len; its
        # covered end is inferred from the following record or output length.
        if records[0][0] != 0 or (output_len != 0 and records[-1][0] >= output_len):
            raise FrameError("restart offsets do not cover output")
    compiled = Compiled(cdf=cdfs, next_state=next_rows, representatives=tuple(), teacher_states=teacher_states, clustering="frame")
    return compiled, header_len, output_len, records


def decode_frame(frame: bytes, max_output: int = MAX_OUTPUT) -> bytes:
    """Independently parse, checksum, and decode a complete frame."""

    compiled, header_len, output_len, records = _parse_header(frame)
    if output_len > max_output:
        raise FrameError("output exceeds caller budget")
    payload_at = header_len
    payload_end = len(frame) - 4
    expected_crc = struct.unpack("<I", frame[-4:])[0]
    if zlib.crc32(frame[:-4]) & 0xFFFFFFFF != expected_crc:
        raise FrameError("checksum mismatch")

    result = bytearray()
    expected_state = 0
    for index, (offset, start_state, payload_len) in enumerate(records):
        if offset != len(result) or start_state != expected_state:
            raise FrameError("restart state/offset mismatch")
        if payload_len > payload_end - payload_at:
            raise FrameError("truncated payload segment")
        payload = frame[payload_at : payload_at + payload_len]
        payload_at += payload_len
        next_offset = records[index + 1][0] if index + 1 < len(records) else output_len
        segment_len = next_offset - offset
        decoder = _RangeDecoder(payload)
        state = start_state
        for _ in range(segment_len):
            symbol = decoder.symbol(compiled.cdf[state])
            if symbol == EOS:
                raise FrameError("premature EOS")
            result.append(symbol)
            state = compiled.next_state[state][symbol]
        if index + 1 == len(records):
            symbol = decoder.symbol(compiled.cdf[state])
            if symbol != EOS:
                raise FrameError("missing EOS")
        expected_state = state
    if payload_at != payload_end or len(result) != output_len:
        raise FrameError("trailing payload or output length mismatch")
    return bytes(result)


def frame_sha256(frame: bytes) -> str:
    return hashlib.sha256(frame).hexdigest()


def model_sha256(compiled: Compiled) -> str:
    return hashlib.sha256(_pack_tables(compiled)).hexdigest()


def compiled_state_trace(compiled: Compiled, data: bytes) -> list[int]:
    state = 0
    trace = [state]
    for symbol in list(data) + [EOS]:
        state = compiled.next_state[state][symbol]
        trace.append(state)
    return trace


def iter_bytes(path: Path, limit: int | None = None) -> bytes:
    raw = path.read_bytes()
    return raw if limit is None else raw[:limit]
