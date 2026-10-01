"""Bounded Python reference families for the second BWT experiment.

This module is deliberately independent from the production codecs.  It is a
small, strict, self-describing frame format used to test a concrete hypothesis:
the former candidate mixed MTF events and ULEB run lengths in one byte model.

The six variants are intentionally simple ablations:

``A``
    BZip2-style bijective RUNA/RUNB coding.  Non-zero MTF ranks occupy a
    separate, non-overlapping symbol alphabet and a single static rANS model.
``B``
    A plus three static rANS models selected by previous event class (start,
    zero-run, or non-zero/EOB).
``C``
    A plus a reversible bounded LZ factorizer before BWT.  Match references are
    reconstructed by the decoder with bulk periodic copies.
``D``
    A plus four locally clustered rANS tables.  A selector byte for every
    token segment is stored in the block, so the local choice is fully charged.
``E``
    A two-table representation ablation: each block chooses raw-BWT or
    factorized-BWT, and the chosen representation flag selects its complete
    global table.
``F``
    A's one stored table, renormalized per block to the event IDs reachable
    from that block's serialized alphabet mask.  The derived table is keyed
    only by alphabet cardinality and retained in a bounded decoder cache.

The decoder has no native compression dependency.  The encoder uses a bounded
prefix-doubling cyclic suffix sort, which is intentionally reference-quality
and not a claim about native construction speed.
"""

from __future__ import annotations

from dataclasses import dataclass
import math
import struct
import zlib
from typing import Iterable, Sequence


MAGIC = b"B4PC"
VERSION = 1
HEADER_SIZE = 40
DIRECTORY_RECORD_SIZE = 16
MODEL_MAGIC = b"M1"
PROB_BITS = 12
PROB_TOTAL = 1 << PROB_BITS
RANS_LOWER_BOUND = 1 << 23
TOKEN_ALPHABET = 258  # RUNA, RUNB, ranks 2..256, and EOB up to 257.
RUNA = 0
RUNB = 1
MAX_BLOCK_BYTES = 64 * 1024
MAX_RAW_BYTES = 512 * 1024 * 1024
MAX_FRAME_BYTES = 512 * 1024 * 1024
MAX_MODEL_BYTES = 128 * 1024
FACTOR_MIN_MATCH = 40
FACTOR_WINDOW = 64 * 1024 - 1  # stored as an unsigned 16-bit model field
FACTOR_HASH = 4
FACTOR_CANDIDATES = 24
SEGMENT_BYTES = 512
LOCAL_TABLES = 4
MAX_WIRE_U16 = 0xFFFF
MAX_WIRE_U8 = 0xFF

VARIANT_A = 0
VARIANT_B = 1
VARIANT_C = 2
VARIANT_D = 3
VARIANT_E = 4
VARIANT_F = 5
VARIANT_NAMES = {
    "A": VARIANT_A,
    "B": VARIANT_B,
    "C": VARIANT_C,
    "D": VARIANT_D,
    "E": VARIANT_E,
    "F": VARIANT_F,
}
VARIANT_LABELS = {value: key for key, value in VARIANT_NAMES.items()}

_HEADER = struct.Struct("<4sBBBBIIQIIII")
_DIRECTORY = struct.Struct("<IIII")
_BLOCK = struct.Struct("<BIIIHB")
_MODEL_HEAD = struct.Struct("<2sBBBBHH")


class CodecError(ValueError):
    """Raised for malformed frames, invalid models, or invalid arguments."""


def _fail(message: str) -> None:
    raise CodecError(message)


def _crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def _uleb(value: int) -> bytes:
    if value < 0:
        _fail("negative ULEB value")
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def _read_uleb(data: bytes, at: int, *, limit: int | None = None) -> tuple[int, int]:
    value = 0
    shift = 0
    start = at
    # Python integers do not overflow; the explicit byte cap still prevents an
    # attacker from making parsing proportional to an unbounded integer.
    while at < len(data) and at - start < 10:
        byte = data[at]
        at += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            if at - start > 1 and byte == 0:
                _fail("non-canonical ULEB")
            if limit is not None and value > limit:
                _fail("ULEB exceeds bound")
            return value, at
        shift += 7
    _fail("truncated or overlong ULEB")


def _validate_variant(variant: int | str) -> int:
    if isinstance(variant, str):
        try:
            variant = VARIANT_NAMES[variant.upper()]
        except KeyError:
            _fail("unknown variant")
    if variant not in VARIANT_LABELS:
        _fail("unknown variant")
    return int(variant)


def _context_count(variant: int) -> int:
    return 3 if variant == VARIANT_B else 1


def _table_count(variant: int) -> int:
    if variant == VARIANT_D:
        return LOCAL_TABLES
    if variant == VARIANT_E:
        return 2
    return _context_count(variant)


def _context_for_previous(previous: int | None) -> int:
    if previous is None:
        return 0
    if previous == RUNA or previous == RUNB:
        return 1
    return 2


def _build_cdf(frequencies: Sequence[int], *, allow_zero: bool = False) -> tuple[int, ...]:
    if len(frequencies) != TOKEN_ALPHABET:
        _fail("wrong frequency table length")
    total = 0
    cdf = [0]
    for frequency in frequencies:
        if frequency < 0 or (frequency == 0 and not allow_zero):
            _fail("invalid frequency")
        total += frequency
        cdf.append(total)
    if total != PROB_TOTAL:
        _fail("bad frequency total")
    return tuple(cdf)


def _frequencies_from_counts(counts: Sequence[int]) -> tuple[int, ...]:
    if len(counts) != TOKEN_ALPHABET:
        _fail("wrong count table length")
    # One count per symbol makes every possible token representable.  This is
    # charged in the wire model, and avoids an unsafe training/holdout alphabet
    # assumption.  Unlike the old byte model, RUNA/RUNB and EOB are typed
    # events, not bytes followed by a mixed ULEB stream.
    base = [1] * TOKEN_ALPHABET
    distributable = PROB_TOTAL - TOKEN_ALPHABET
    total = sum(max(0, int(count)) for count in counts)
    if total == 0:
        quotient, remainder = divmod(PROB_TOTAL, TOKEN_ALPHABET)
        for index in range(remainder):
            base[index] = quotient + 1
        for index in range(remainder, TOKEN_ALPHABET):
            base[index] = quotient
        return tuple(base)
    remainders = [0] * TOKEN_ALPHABET
    assigned = TOKEN_ALPHABET
    for index, count in enumerate(counts):
        product = max(0, int(count)) * distributable
        extra, remainder = divmod(product, total)
        base[index] += extra
        assigned += extra
        remainders[index] = remainder
    # Stable largest-remainder allocation.  Ties resolve toward the lower
    # symbol, so training is deterministic across Python versions.
    while assigned < PROB_TOTAL:
        best = max(range(TOKEN_ALPHABET), key=lambda i: (remainders[i], -i))
        base[best] += 1
        remainders[best] = -1
        assigned += 1
    return tuple(base)


def _conditioned_frequencies(base: Sequence[int], alphabet_count: int) -> tuple[int, ...]:
    """Renormalize A's weights over the event IDs reachable for one mask.

    A block with ``k`` distinct bytes can emit RUNA/RUNB (0 and 1), ranks
    2..k, and EOB (k+1): exactly ``k + 2`` symbols.  The alphabet mask is
    already part of the block header, so this conditioning adds no selector
    bytes and depends only on ``k``, not on the byte values in the mask.
    """
    if len(base) != TOKEN_ALPHABET or not (1 <= alphabet_count <= 256):
        _fail("invalid conditioned alphabet cardinality")
    support = alphabet_count + 2
    weights = [int(value) for value in base[:support]]
    if any(value <= 0 for value in weights):
        _fail("conditioned model has zero reachable weight")
    total = sum(weights)
    # The stored A frequencies are already smoothed.  Do not add another
    # unit prior here: condition by exact integer renormalization, then use
    # largest remainder only for the unavoidable 12-bit rounding.  In
    # particular, a 256-byte alphabet must reproduce the stored table.
    frequencies = [0] * TOKEN_ALPHABET
    remainders = [0] * support
    assigned = 0
    for symbol, weight in enumerate(weights):
        quotient, remainder = divmod(weight * PROB_TOTAL, total)
        frequencies[symbol] = quotient
        assigned += quotient
        remainders[symbol] = remainder
    while assigned < PROB_TOTAL:
        best = max(range(support), key=lambda index: (remainders[index], -index))
        frequencies[best] += 1
        remainders[best] = -1
        assigned += 1
    _build_cdf(frequencies, allow_zero=True)
    return tuple(frequencies)


def _model_score(table: Sequence[int], counts: Sequence[int]) -> int:
    """Integer cross-entropy proxy used for local selector decisions."""
    score = 0
    for symbol, count in enumerate(counts):
        if count:
            # A fixed-point -log2 proxy; the common denominator is omitted.
            frequency = table[symbol]
            score += int(count) * ((PROB_BITS * 1024) - int(math.log2(frequency) * 1024))
    return score


@dataclass(frozen=True)
class Model:
    variant: int
    tables: tuple[tuple[int, ...], ...]
    segment_bytes: int = SEGMENT_BYTES
    factor_window: int = FACTOR_WINDOW
    factor_min_match: int = FACTOR_MIN_MATCH
    sparse: bool = False

    def __post_init__(self) -> None:
        if self.variant not in VARIANT_LABELS:
            _fail("invalid model variant")
        if len(self.tables) != _table_count(self.variant):
            _fail("wrong model table count")
        if self.sparse and self.variant != VARIANT_F:
            _fail("sparse model is only valid for F's derived table")
        for table in self.tables:
            _build_cdf(table, allow_zero=self.sparse)
        if self.variant == VARIANT_D:
            if not (1 <= self.segment_bytes <= MAX_WIRE_U16):
                _fail("invalid segment size")
        elif self.segment_bytes != SEGMENT_BYTES:
            _fail("non-canonical unused segment size")
        if self.variant == VARIANT_C:
            if not (1 <= self.factor_window <= MAX_WIRE_U16):
                _fail("invalid factor window")
            if not (4 <= self.factor_min_match <= min(self.factor_window, MAX_WIRE_U8)):
                _fail("invalid factor minimum")
        elif self.factor_window != FACTOR_WINDOW or self.factor_min_match != FACTOR_MIN_MATCH:
            _fail("non-canonical unused factor parameters")

    @property
    def table_count(self) -> int:
        return len(self.tables)

    def wire(self) -> bytes:
        if self.sparse:
            _fail("derived sparse model cannot be serialized")
        head = _MODEL_HEAD.pack(
            MODEL_MAGIC,
            self.variant,
            self.table_count,
            0,
            0,
            self.segment_bytes,
            self.factor_window if self.variant == VARIANT_C else 0,
        )
        body = bytearray(head)
        body.extend(bytes((self.factor_min_match if self.variant == VARIANT_C else 0, 0)))
        for table in self.tables:
            for frequency in table:
                body.extend(struct.pack("<H", frequency))
        if len(body) > MAX_MODEL_BYTES:
            _fail("model too large")
        return bytes(body)

    @staticmethod
    def from_wire(wire: bytes, expected_variant: int) -> "Model":
        if len(wire) < _MODEL_HEAD.size + 2:
            _fail("truncated model")
        magic, variant, count, flags, reserved, segment_bytes, factor_window = _MODEL_HEAD.unpack_from(wire)
        factor_min_match, factor_reserved = wire[_MODEL_HEAD.size : _MODEL_HEAD.size + 2]
        if magic != MODEL_MAGIC or variant != expected_variant or flags or reserved or factor_reserved:
            _fail("invalid model header")
        if count != _table_count(variant):
            _fail("invalid model table count")
        expected = _MODEL_HEAD.size + 2 + count * TOKEN_ALPHABET * 2
        if len(wire) != expected:
            _fail("non-canonical model length")
        at = _MODEL_HEAD.size + 2
        tables: list[tuple[int, ...]] = []
        for _ in range(count):
            table = tuple(struct.unpack_from("<" + "H" * TOKEN_ALPHABET, wire, at))
            at += TOKEN_ALPHABET * 2
            _build_cdf(table)
            tables.append(table)
        if variant != VARIANT_D and segment_bytes != SEGMENT_BYTES:
            # Keep a stable value on all frames, even when selectors are not
            # used, so malformed models cannot smuggle a new decode policy.
            _fail("invalid unused segment size")
        if variant == VARIANT_C:
            # C stores both factor parameters directly.  Zero is reserved for
            # non-C models and must not silently expand to a default here.
            if not (1 <= factor_window <= MAX_WIRE_U16):
                _fail("invalid factor window")
            if not (4 <= factor_min_match <= min(factor_window, MAX_WIRE_U8)):
                _fail("invalid factor minimum")
        if variant != VARIANT_C and (factor_window or factor_min_match):
            _fail("invalid unused factor parameters")
        return Model(
            variant=variant,
            tables=tuple(tables),
            segment_bytes=segment_bytes,
            factor_window=factor_window or FACTOR_WINDOW,
            factor_min_match=factor_min_match or FACTOR_MIN_MATCH,
        )


def _suffix_array_cyclic(data: bytes) -> list[int]:
    """Bounded O(n log n) cyclic suffix/rotation ordering."""
    n = len(data)
    if n == 0:
        _fail("empty BWT input")
    order = list(range(n))
    rank = list(data)
    shift = 1
    while shift < n:
        order.sort(key=lambda index: (rank[index], rank[(index + shift) % n]))
        next_rank = [0] * n
        classes = 1
        previous = order[0]
        next_rank[previous] = 0
        for index in order[1:]:
            if (rank[index], rank[(index + shift) % n]) != (
                rank[previous],
                rank[(previous + shift) % n],
            ):
                classes += 1
            next_rank[index] = classes - 1
            previous = index
        rank = next_rank
        if classes == n:
            break
        shift <<= 1
    return order


def _bwt_transform(data: bytes) -> tuple[bytes, int]:
    if not data or len(data) > MAX_BLOCK_BYTES:
        _fail("invalid BWT block length")
    order = _suffix_array_cyclic(data)
    n = len(data)
    primary = order.index(0)
    last = bytes(data[(position - 1) % n] for position in order)
    return last, primary


def _inverse_bwt(last: bytes, primary: int) -> bytes:
    n = len(last)
    if not n or primary < 0 or primary >= n:
        _fail("invalid BWT primary index")
    counts = [0] * 256
    for byte in last:
        counts[byte] += 1
    starts = [0] * 256
    total = 0
    for symbol, count in enumerate(counts):
        starts[symbol] = total
        total += count
    seen = [0] * 256
    lf = [0] * n
    for row, byte in enumerate(last):
        lf[row] = starts[byte] + seen[byte]
        seen[byte] += 1
    output = bytearray(n)
    row = primary
    for at in range(n - 1, -1, -1):
        output[at] = last[row]
        row = lf[row]
    return bytes(output)


def _mtf_tokens(last: bytes) -> tuple[tuple[int, ...], bytes]:
    alphabet = sorted(set(last))
    symbols = list(alphabet)
    tokens: list[int] = []
    pending_zero = 0
    for byte in last:
        rank = symbols.index(byte)
        if rank == 0:
            pending_zero += 1
        else:
            if pending_zero:
                tokens.extend(_run_tokens(pending_zero))
                pending_zero = 0
            tokens.append(rank + 1)  # ranks 1.. become symbols 2..
        if rank:
            symbols.pop(rank)
            symbols.insert(0, byte)
    if pending_zero:
        tokens.extend(_run_tokens(pending_zero))
    tokens.append(len(alphabet) + 1)  # EOB
    mask = bytearray(32)
    for symbol in alphabet:
        mask[symbol >> 3] |= 1 << (symbol & 7)
    return tuple(tokens), bytes(mask)


def _run_tokens(length: int) -> tuple[int, ...]:
    if length <= 0:
        _fail("empty zero run")
    out: list[int] = []
    value = length
    # This is the bijective binary representation used by bzip2's RUNA/RUNB:
    # decrement before taking a bit.  It maps every positive length uniquely.
    while value:
        value -= 1
        out.append(RUNB if value & 1 else RUNA)
        value >>= 1
    return tuple(out)


def _alphabet_from_mask(mask: bytes) -> list[int]:
    if len(mask) != 32:
        _fail("invalid alphabet mask")
    alphabet = [symbol for symbol in range(256) if mask[symbol >> 3] & (1 << (symbol & 7))]
    if not alphabet:
        _fail("empty MTF alphabet")
    return alphabet


def _tokens_to_last(tokens: Sequence[int], mask: bytes, expected_length: int) -> bytes:
    alphabet = _alphabet_from_mask(mask)
    eob = len(alphabet) + 1
    symbols = list(alphabet)
    output = bytearray()
    at = 0
    while at < len(tokens):
        token = tokens[at]
        at += 1
        if token == eob:
            if at != len(tokens):
                _fail("tokens after EOB")
            break
        if token == RUNA or token == RUNB:
            run = 0
            power = 1
            while True:
                bit = 1 if token == RUNB else 0
                run += power * (bit + 1 if bit else 1)
                if at >= len(tokens):
                    _fail("run without EOB")
                token = tokens[at]
                at += 1
                if token != RUNA and token != RUNB:
                    # The next non-run token was consumed as a lookahead.
                    at -= 1
                    break
                power <<= 1
                if power > expected_length + 1:
                    _fail("run length overflow")
            if run > expected_length - len(output):
                _fail("run exceeds BWT length")
            output.extend(b"\0" * run)  # placeholder, replaced below
            # MTF rank zero is the current front symbol, not byte zero.
            if run:
                front = symbols[0]
                output[-run:] = bytes((front,)) * run
            continue
        if token < 2 or token > len(alphabet):
            _fail("invalid non-zero MTF rank")
        rank = token - 1
        value = symbols[rank]
        output.append(value)
        symbols.pop(rank)
        symbols.insert(0, value)
    else:
        _fail("missing EOB")
    if len(output) != expected_length:
        _fail("MTF length mismatch")
    return bytes(output)


def _factor_encode(raw: bytes, window: int, minimum: int) -> bytes:
    """Greedy bounded LZ factorization with an escaped marker."""
    if len(raw) < minimum:
        return raw
    positions: dict[bytes, list[int]] = {}
    out = bytearray()
    at = 0
    n = len(raw)

    def remember(position: int) -> None:
        if position + FACTOR_HASH <= n:
            key = raw[position : position + FACTOR_HASH]
            bucket = positions.setdefault(key, [])
            bucket.append(position)
            if len(bucket) > FACTOR_CANDIDATES * 2:
                del bucket[: len(bucket) - FACTOR_CANDIDATES * 2]

    while at < n:
        best_length = 0
        best_distance = 0
        if at + minimum <= n:
            key = raw[at : at + FACTOR_HASH]
            candidates = positions.get(key, ())
            for position in reversed(candidates):
                distance = at - position
                if distance <= 0:
                    continue
                if distance > window:
                    break
                length = FACTOR_HASH
                maximum = min(n - at, window + FACTOR_HASH)
                while length < maximum and raw[position + length] == raw[at + length]:
                    length += 1
                if length >= minimum and length > best_length:
                    best_length = length
                    best_distance = distance
                    if length == maximum:
                        break
        if best_length:
            out.extend((0xFF, 1))
            out.extend(_uleb(best_distance))
            out.extend(_uleb(best_length - minimum))
            for consumed in range(best_length):
                remember(at + consumed)
            at += best_length
            continue
        byte = raw[at]
        if byte == 0xFF:
            out.extend((0xFF, 0))
        else:
            out.append(byte)
        remember(at)
        at += 1
    return bytes(out)


def _factor_source(raw: bytes, model: Model) -> tuple[bytes, bool]:
    """Select a bounded factor stream, or retain raw bytes with an explicit flag."""
    candidate = _factor_encode(raw, model.factor_window, model.factor_min_match)
    # A factor stream that expands a block is not allowed to push the bounded
    # suffix sorter past its memory contract.  Coded blocks record whether the
    # factor parser must run, so raw bytes remain unambiguous (including 0xff).
    if len(candidate) <= MAX_BLOCK_BYTES and len(candidate) < len(raw):
        return candidate, True
    return raw, False


def _copy_match(output: bytearray, distance: int, length: int) -> None:
    if distance <= 0 or distance > len(output):
        _fail("factor reference out of range")
    # The source is periodic under LZ overlap.  Materialize at most one period
    # and extend in large slices, keeping decoder work proportional to output.
    pattern = bytes(output[-distance:])
    output.extend((pattern * ((length + distance - 1) // distance))[:length])


def _factor_decode(
    encoded: bytes,
    expected_length: int,
    minimum: int = FACTOR_MIN_MATCH,
    window: int = FACTOR_WINDOW,
) -> bytes:
    output = bytearray()
    at = 0
    while at < len(encoded):
        byte = encoded[at]
        at += 1
        if byte != 0xFF:
            output.append(byte)
        else:
            if at >= len(encoded):
                _fail("truncated factor marker")
            op = encoded[at]
            at += 1
            if op == 0:
                output.append(0xFF)
            elif op == 1:
                distance, at = _read_uleb(encoded, at, limit=window)
                extra, at = _read_uleb(encoded, at, limit=MAX_BLOCK_BYTES)
                length = minimum + extra
                if length > MAX_BLOCK_BYTES or len(output) + length > expected_length:
                    _fail("factor match exceeds output bound")
                _copy_match(output, distance, length)
            else:
                _fail("invalid factor marker")
        if len(output) > expected_length:
            _fail("factor output exceeds expected length")
    if len(output) != expected_length:
        _fail("factor output length mismatch")
    return bytes(output)


def _rans_encode(
    tokens: Sequence[int],
    model: Model,
    selectors: Sequence[int] | None = None,
    table_offset: int = 0,
    frequencies: Sequence[int] | None = None,
) -> bytes:
    if table_offset < 0 or table_offset >= len(model.tables):
        _fail("invalid rANS table selector")
    state = RANS_LOWER_BOUND
    emitted = bytearray()
    tables = (tuple(frequencies),) if frequencies is not None else model.tables
    cdfs = [_build_cdf(table, allow_zero=model.variant == VARIANT_F and frequencies is not None) for table in tables]
    for index in range(len(tokens) - 1, -1, -1):
        if model.variant == VARIANT_E:
            context = table_offset
        elif model.variant == VARIANT_B:
            context = _context_for_previous(tokens[index - 1] if index else None)
        elif model.variant == VARIANT_D:
            if selectors is None or index // model.segment_bytes >= len(selectors):
                _fail("missing local selector")
            context = selectors[index // model.segment_bytes]
        else:
            context = 0
        symbol = tokens[index]
        frequency = tables[context][symbol]
        start = cdfs[context][symbol]
        max_state = ((RANS_LOWER_BOUND >> PROB_BITS) << 8) * frequency
        while state >= max_state:
            emitted.append(state & 0xFF)
            state >>= 8
        state = (state // frequency << PROB_BITS) + (state % frequency) + start
        if state > 0xFFFFFFFF:
            _fail("rANS state overflow")
    return struct.pack("<I", state) + bytes(reversed(emitted))


@dataclass(frozen=True)
class _PreparedRans:
    """Immutable decoder tables retained across independent block decodes."""

    model: Model
    cdfs: tuple[tuple[int, ...], ...]
    slots: tuple[tuple[int, ...], ...]

    @staticmethod
    def build(model: Model) -> "_PreparedRans":
        cdfs = tuple(_build_cdf(table, allow_zero=model.variant == VARIANT_F) for table in model.tables)
        all_slots: list[tuple[int, ...]] = []
        for table in model.tables:
            slot = [0] * PROB_TOTAL
            running = 0
            for symbol, frequency in enumerate(table):
                slot[running : running + frequency] = [symbol] * frequency
                running += frequency
            all_slots.append(tuple(slot))
        return _PreparedRans(model, cdfs, tuple(all_slots))


def _rans_decode(
    encoded: bytes,
    output_length: int,
    model: Model,
    selectors: Sequence[int] | None = None,
    prepared: _PreparedRans | None = None,
    table_offset: int = 0,
) -> tuple[int, ...]:
    if table_offset < 0 or table_offset >= len(model.tables):
        _fail("invalid rANS table selector")
    if len(encoded) < 4:
        _fail("truncated rANS stream")
    state = struct.unpack_from("<I", encoded)[0]
    if state < RANS_LOWER_BOUND:
        _fail("invalid rANS state")
    if prepared is None:
        prepared = _PreparedRans.build(model)
    elif prepared.model.variant != model.variant or prepared.model.table_count != model.table_count:
        _fail("prepared model mismatch")
    cdfs = prepared.cdfs
    slots = prepared.slots
    at = 4
    output = [0] * output_length
    previous: int | None = None
    for index in range(output_length):
        if model.variant == VARIANT_E:
            context = table_offset
        elif model.variant == VARIANT_B:
            context = _context_for_previous(previous)
        elif model.variant == VARIANT_D:
            if selectors is None or index // model.segment_bytes >= len(selectors):
                _fail("missing local selector")
            context = selectors[index // model.segment_bytes]
        else:
            context = 0
        slot_value = state & (PROB_TOTAL - 1)
        symbol = slots[context][slot_value]
        output[index] = symbol
        frequency = prepared.model.tables[context][symbol]
        state = frequency * (state >> PROB_BITS) + slot_value - cdfs[context][symbol]
        while state < RANS_LOWER_BOUND:
            if at >= len(encoded):
                _fail("truncated rANS renormalization")
            state = (state << 8) | encoded[at]
            at += 1
        previous = symbol
    if at != len(encoded) or state != RANS_LOWER_BOUND:
        _fail("non-canonical rANS tail")
    return tuple(output)


def _segment_counts(tokens: Sequence[int], segment_bytes: int) -> list[list[int]]:
    result = []
    for start in range(0, len(tokens), segment_bytes):
        counts = [0] * TOKEN_ALPHABET
        for symbol in tokens[start : start + segment_bytes]:
            counts[symbol] += 1
        result.append(counts)
    return result


def _selector_for_segment(counts: Sequence[int], model: Model) -> int:
    return min(range(model.table_count), key=lambda index: (_model_score(model.tables[index], counts), index))


def _conditioned_model(model: Model, alphabet_count: int) -> Model:
    if model.variant != VARIANT_F:
        _fail("conditioned model requested for non-F variant")
    return Model(
        variant=VARIANT_F,
        tables=(_conditioned_frequencies(model.tables[0], alphabet_count),),
        sparse=True,
    )


def _block_tokens(raw: bytes, model: Model) -> tuple[bytes, int, bytes, list[int], int]:
    def code_source(source: bytes, block_flags: int, table_offset: int = 0) -> bytes:
        last, primary = _bwt_transform(source)
        tokens, mask = _mtf_tokens(last)
        selectors: list[int] = []
        if model.variant == VARIANT_D:
            selectors = [
                _selector_for_segment(counts, model)
                for counts in _segment_counts(tokens, model.segment_bytes)
            ]
        frequencies = None
        if model.variant == VARIANT_F:
            frequencies = _conditioned_frequencies(model.tables[0], len(_alphabet_from_mask(mask)))
        entropy = _rans_encode(tokens, model, selectors, table_offset, frequencies)
        block_head = _BLOCK.pack(1, primary, len(source), len(tokens), len(selectors), block_flags)
        return block_head + mask + bytes(selectors) + entropy

    if model.variant == VARIANT_E:
        raw_coded = code_source(raw, 0, 0)
        factor_source, factorized = _factor_source(raw, model)
        if factorized:
            factor_coded = code_source(factor_source, 1, 1)
            _, _, coded, source = min(
                (
                    (len(raw_coded), 0, raw_coded, raw),
                    (len(factor_coded), 1, factor_coded, factor_source),
                ),
                key=lambda candidate: (candidate[0], candidate[1], candidate[2]),
            )
        else:
            coded, source = raw_coded, raw
        return coded, len(source), b"", [], 0

    source = raw
    block_flags = 0
    if model.variant == VARIANT_C:
        source, factorized = _factor_source(raw, model)
        block_flags = 1 if factorized else 0
    coded = code_source(source, block_flags)
    return coded, len(source), b"", [], 0


def _counts_for_tokens(tokens: Sequence[int], variant: int) -> list[list[int]]:
    tables = [[0] * TOKEN_ALPHABET for _ in range(_table_count(variant))]
    previous: int | None = None
    for index, symbol in enumerate(tokens):
        if variant == VARIANT_B:
            context = _context_for_previous(previous)
        else:
            context = 0
        tables[context][symbol] += 1
        previous = symbol
    return tables


def _cluster_tables(segment_histograms: list[list[int]]) -> tuple[tuple[int, ...], ...]:
    if not segment_histograms:
        return (tuple(_frequencies_from_counts([1] * TOKEN_ALPHABET)),) * LOCAL_TABLES
    k = min(LOCAL_TABLES, len(segment_histograms))
    # Evenly spaced deterministic seeds followed by two bounded Lloyd rounds.
    centroids = [list(segment_histograms[(i * len(segment_histograms)) // k]) for i in range(k)]
    assignments = [0] * len(segment_histograms)
    for _ in range(2):
        for index, histogram in enumerate(segment_histograms):
            assignments[index] = min(
                range(k),
                key=lambda cluster: (sum(abs(a - b) for a, b in zip(histogram, centroids[cluster])), cluster),
            )
        for cluster in range(k):
            members = [segment_histograms[i] for i, assigned in enumerate(assignments) if assigned == cluster]
            if members:
                centroids[cluster] = [sum(row[symbol] for row in members) for symbol in range(TOKEN_ALPHABET)]
    tables = [_frequencies_from_counts(centroid) for centroid in centroids]
    while len(tables) < LOCAL_TABLES:
        tables.append(tables[-1])
    return tuple(tables)


def train(training: bytes, variant: int | str = "A", block_bytes: int = 16 * 1024) -> Model:
    """Train one of the explicit variants on a bounded prefix."""
    variant_id = _validate_variant(variant)
    if not training or block_bytes <= 0 or block_bytes > MAX_BLOCK_BYTES:
        _fail("invalid training arguments")
    if len(training) > MAX_RAW_BYTES:
        _fail("training exceeds bound")
    counts = [[0] * TOKEN_ALPHABET for _ in range(_table_count(variant_id))]
    local_segments: list[list[int]] = []
    factor_model = (
        Model(
            variant=VARIANT_C,
            tables=(tuple(_frequencies_from_counts([1] * TOKEN_ALPHABET)),),
            factor_window=FACTOR_WINDOW,
            factor_min_match=FACTOR_MIN_MATCH,
        )
        if variant_id in (VARIANT_C, VARIANT_E)
        else None
    )
    for start in range(0, len(training), block_bytes):
        raw = training[start : start + block_bytes]
        source = raw
        if variant_id == VARIANT_C:
            assert factor_model is not None
            source, _ = _factor_source(raw, factor_model)
        if variant_id == VARIANT_E:
            raw_last, _ = _bwt_transform(raw)
            raw_tokens, _ = _mtf_tokens(raw_last)
            for symbol in raw_tokens:
                counts[0][symbol] += 1
            assert factor_model is not None
            factor_source, factorized = _factor_source(raw, factor_model)
            if factorized:
                factor_last, _ = _bwt_transform(factor_source)
                factor_tokens, _ = _mtf_tokens(factor_last)
                for symbol in factor_tokens:
                    counts[1][symbol] += 1
            continue
        last, _ = _bwt_transform(source)
        tokens, _ = _mtf_tokens(last)
        block_counts = _counts_for_tokens(tokens, variant_id)
        for table_index, table_counts in enumerate(block_counts):
            for symbol, count in enumerate(table_counts):
                counts[table_index][symbol] += count
        if variant_id == VARIANT_D:
            local_segments.extend(_segment_counts(tokens, SEGMENT_BYTES))
    if variant_id == VARIANT_D:
        tables = _cluster_tables(local_segments)
    else:
        tables = tuple(_frequencies_from_counts(table_counts) for table_counts in counts)
    return Model(
        variant=variant_id,
        tables=tables,
        segment_bytes=SEGMENT_BYTES,
        factor_window=FACTOR_WINDOW if variant_id == VARIANT_C else FACTOR_WINDOW,
        factor_min_match=FACTOR_MIN_MATCH if variant_id == VARIANT_C else FACTOR_MIN_MATCH,
    )


@dataclass(frozen=True)
class _DirectoryEntry:
    offset: int
    encoded_length: int
    raw_length: int
    checksum: int


@dataclass(frozen=True)
class Frame:
    wire: bytes
    variant: int
    block_bytes: int
    raw_length: int
    model: Model
    directory: tuple[_DirectoryEntry, ...]
    payload: bytes


def _parse_frame(wire: bytes) -> Frame:
    if len(wire) > MAX_FRAME_BYTES or len(wire) < HEADER_SIZE:
        _fail("frame size out of bounds")
    (
        magic,
        version,
        variant,
        flags,
        header_size,
        block_bytes,
        block_count,
        raw_length,
        model_length,
        directory_length,
        payload_length,
        metadata_checksum,
    ) = _HEADER.unpack_from(wire)
    if magic != MAGIC or version != VERSION or flags or header_size != HEADER_SIZE:
        _fail("invalid frame header")
    variant = _validate_variant(variant)
    if not (1 <= block_bytes <= MAX_BLOCK_BYTES):
        _fail("invalid block size")
    if raw_length > MAX_RAW_BYTES:
        _fail("raw length exceeds bound")
    expected_blocks = (raw_length + block_bytes - 1) // block_bytes if raw_length else 0
    if block_count != expected_blocks or directory_length != block_count * DIRECTORY_RECORD_SIZE:
        _fail("invalid block directory length")
    if model_length > MAX_MODEL_BYTES:
        _fail("model exceeds bound")
    payload_at = HEADER_SIZE + model_length + directory_length
    if payload_at > len(wire) or payload_length != len(wire) - payload_at:
        _fail("frame length mismatch")
    model_wire = wire[HEADER_SIZE : HEADER_SIZE + model_length]
    model = Model.from_wire(model_wire, variant)
    directory_wire = wire[HEADER_SIZE + model_length : payload_at]
    crc_head = bytearray(wire[:36])
    actual_checksum = _crc32(bytes(crc_head) + model_wire + directory_wire)
    if actual_checksum != metadata_checksum:
        _fail("metadata checksum mismatch")
    directory: list[_DirectoryEntry] = []
    expected_offset = 0
    raw_total = 0
    for index in range(block_count):
        offset, encoded_length, block_raw, checksum = _DIRECTORY.unpack_from(directory_wire, index * DIRECTORY_RECORD_SIZE)
        if offset != expected_offset or not encoded_length or not block_raw or block_raw > block_bytes:
            _fail("invalid directory entry")
        if index + 1 < block_count and block_raw != block_bytes:
            _fail("short non-final block")
        expected_offset += encoded_length
        raw_total += block_raw
        if expected_offset > payload_length:
            _fail("directory exceeds payload")
        directory.append(_DirectoryEntry(offset, encoded_length, block_raw, checksum))
    if expected_offset != payload_length or raw_total != raw_length:
        _fail("directory totals mismatch")
    return Frame(
        wire=wire,
        variant=variant,
        block_bytes=block_bytes,
        raw_length=raw_length,
        model=model,
        directory=tuple(directory),
        payload=wire[payload_at:],
    )


def _decode_block(
    frame: Frame,
    index: int,
    prepared: _PreparedRans | None = None,
    dynamic_cache: dict[int, _PreparedRans] | None = None,
) -> bytes:
    if index < 0 or index >= len(frame.directory):
        _fail("block index out of range")
    entry = frame.directory[index]
    encoded = frame.payload[entry.offset : entry.offset + entry.encoded_length]
    if not encoded:
        _fail("empty block")
    if encoded[0] == 0:
        raw = encoded[1:]
        if len(raw) != entry.raw_length:
            _fail("raw block length mismatch")
    elif encoded[0] == 1:
        if len(encoded) < _BLOCK.size + 32:
            _fail("truncated coded block")
        mode, primary, transformed_length, token_length, selector_count, block_flags = _BLOCK.unpack_from(encoded)
        if mode != 1 or not transformed_length or transformed_length > MAX_BLOCK_BYTES:
            _fail("invalid coded block header")
        if frame.variant in (VARIANT_C, VARIANT_E):
            if block_flags & ~1:
                _fail("invalid factor flags")
        elif block_flags:
            _fail("unexpected factor flags")
        if not token_length or token_length > transformed_length * 2 + 16:
            _fail("invalid token length")
        at = _BLOCK.size
        mask = encoded[at : at + 32]
        at += 32
        expected_selectors = (
            (token_length + frame.model.segment_bytes - 1) // frame.model.segment_bytes
            if frame.variant == VARIANT_D
            else 0
        )
        if selector_count != expected_selectors:
            _fail("invalid selector count")
        if at + selector_count > len(encoded):
            _fail("truncated selector list")
        selectors = list(encoded[at : at + selector_count])
        if any(selector >= frame.model.table_count for selector in selectors):
            _fail("invalid selector")
        at += selector_count
        table_offset = block_flags if frame.variant == VARIANT_E else 0
        block_prepared = prepared
        if frame.variant == VARIANT_F:
            alphabet_count = len(_alphabet_from_mask(mask))
            if dynamic_cache is None:
                block_prepared = _PreparedRans.build(_conditioned_model(frame.model, alphabet_count))
            else:
                block_prepared = dynamic_cache.get(alphabet_count)
                if block_prepared is None:
                    block_prepared = _PreparedRans.build(_conditioned_model(frame.model, alphabet_count))
                    dynamic_cache[alphabet_count] = block_prepared
        tokens = _rans_decode(encoded[at:], token_length, frame.model, selectors, block_prepared, table_offset)
        last = _tokens_to_last(tokens, mask, transformed_length)
        # The mask is part of the coded block, so it must be the exact
        # in-use alphabet, not merely a superset that happens to admit the
        # MTF ranks.  This also makes the F cardinality selector canonical.
        if set(last) != set(_alphabet_from_mask(mask)):
            _fail("alphabet mask does not match BWT symbols")
        source = _inverse_bwt(last, primary)
        if frame.variant in (VARIANT_C, VARIANT_E) and (block_flags & 1):
            raw = _factor_decode(
                source,
                entry.raw_length,
                frame.model.factor_min_match,
                frame.model.factor_window,
            )
        else:
            if len(source) != entry.raw_length:
                _fail("decoded block size mismatch")
            raw = source
    else:
        _fail("invalid block mode")
    if _crc32(raw) != entry.checksum:
        _fail("block checksum mismatch")
    return raw


class Prepared:
    """Parsed frame with model CDF/shape state retained across block decodes."""

    def __init__(self, frame: Frame):
        self.frame = frame
        self._rans = _PreparedRans.build(frame.model)
        self._dynamic_rans: dict[int, _PreparedRans] = {}
        # A conservative logical initialization charge: model wire plus native
        # sized CDF entries (u16) and symbol lookup slots (u16; ranks reach
        # 257). Python object overhead is intentionally not disguised as this
        # portable logical bound.
        base_bytes = len(frame.model.wire()) + len(frame.model.tables) * (
            (TOKEN_ALPHABET + 1) * 2 + PROB_TOTAL * 2
        )
        # F's cardinality-keyed derived tables are bounded to all 256 possible
        # alphabet sizes. Charge the complete cache capacity up front, even
        # though construction is lazy, so a cold block never receives a free
        # derived-table build.
        self.dynamic_table_cache_bytes = 256 * ((TOKEN_ALPHABET + 1) * 2 + PROB_TOTAL * 2) if frame.variant == VARIANT_F else 0
        self.initialization_bytes = base_bytes + self.dynamic_table_cache_bytes

    def decode_block(self, index: int) -> bytes:
        return _decode_block(self.frame, index, self._rans, self._dynamic_rans)

    def decode_all(self) -> bytes:
        output = bytearray()
        for index in range(len(self.frame.directory)):
            output.extend(self.decode_block(index))
        if len(output) != self.frame.raw_length:
            _fail("decoded frame length mismatch")
        return bytes(output)


def prepare(frame: bytes) -> Prepared:
    """Parse and validate a frame once, retaining model initialization state."""
    return Prepared(_parse_frame(bytes(frame)))


def decode(frame: bytes) -> bytes:
    return prepare(frame).decode_all()


def decode_block(frame: bytes | Prepared, index: int) -> bytes:
    return (frame if isinstance(frame, Prepared) else prepare(frame)).decode_block(index)


def encode(data: bytes, model: Model, block_bytes: int = 16 * 1024) -> bytes:
    """Encode a complete frame, including model, directory, checksums and raw fallbacks."""
    if not isinstance(data, (bytes, bytearray, memoryview)):
        _fail("data must be bytes-like")
    data = bytes(data)
    if len(data) > MAX_RAW_BYTES or block_bytes <= 0 or block_bytes > MAX_BLOCK_BYTES:
        _fail("input or block size exceeds bound")
    if not isinstance(model, Model):
        _fail("invalid model")
    model_wire = model.wire()
    encoded_blocks: list[bytes] = []
    directory: list[_DirectoryEntry] = []
    payload_offset = 0
    for start in range(0, len(data), block_bytes):
        raw = data[start : start + block_bytes]
        coded, _, _, _, _ = _block_tokens(raw, model)
        if len(coded) < len(raw) + 1:
            encoded_block = coded
        else:
            encoded_block = b"\0" + raw
        encoded_blocks.append(encoded_block)
        directory.append(_DirectoryEntry(payload_offset, len(encoded_block), len(raw), _crc32(raw)))
        payload_offset += len(encoded_block)
    directory_wire = b"".join(_DIRECTORY.pack(e.offset, e.encoded_length, e.raw_length, e.checksum) for e in directory)
    payload = b"".join(encoded_blocks)
    head_without_crc = _HEADER.pack(
        MAGIC,
        VERSION,
        model.variant,
        0,
        HEADER_SIZE,
        block_bytes,
        len(directory),
        len(data),
        len(model_wire),
        len(directory_wire),
        len(payload),
        0,
    )[:36]
    metadata_checksum = _crc32(head_without_crc + model_wire + directory_wire)
    header = _HEADER.pack(
        MAGIC,
        VERSION,
        model.variant,
        0,
        HEADER_SIZE,
        block_bytes,
        len(directory),
        len(data),
        len(model_wire),
        len(directory_wire),
        len(payload),
        metadata_checksum,
    )
    frame = header + model_wire + directory_wire + payload
    if len(frame) > MAX_FRAME_BYTES:
        _fail("frame exceeds bound")
    return frame


def frame_metrics(frame: bytes | Prepared) -> dict[str, int | str]:
    prepared = frame if isinstance(frame, Prepared) else prepare(frame)
    parsed = prepared.frame
    model_bytes = len(parsed.model.wire())
    directory_bytes = len(parsed.directory) * DIRECTORY_RECORD_SIZE
    return {
        "variant": VARIANT_LABELS[parsed.variant],
        "raw_bytes": parsed.raw_length,
        "complete_bytes": len(parsed.wire),
        "header_bytes": HEADER_SIZE,
        "model_bytes": model_bytes,
        "directory_bytes": directory_bytes,
        "payload_bytes": len(parsed.payload),
        "block_count": len(parsed.directory),
        "max_encoded_block": max((entry.encoded_length for entry in parsed.directory), default=0),
        "initialization_bytes": prepared.initialization_bytes,
        "dynamic_table_cache_bytes": prepared.dynamic_table_cache_bytes,
    }


__all__ = [
    "CodecError",
    "Frame",
    "Model",
    "Prepared",
    "VARIANT_A",
    "VARIANT_B",
    "VARIANT_C",
    "VARIANT_D",
    "VARIANT_E",
    "VARIANT_F",
    "decode",
    "decode_block",
    "encode",
    "frame_metrics",
    "prepare",
    "train",
]
