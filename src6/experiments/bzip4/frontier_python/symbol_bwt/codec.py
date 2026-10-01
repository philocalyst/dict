"""Charged grammar-root BWT/MTF/RUNA codec reference.

This is an isolated experiment for the language-compression frontier.  The
encoder first builds a complete pair grammar using the read-only grammar
family, tokenizes each independently addressed raw block into literal/rule
root IDs, and then applies a cyclic BWT, full-alphabet MTF, bijective
RUNA/RUNB zero runs, and one canonical Huffman model.  Every discovered byte
of state is serialized in the frame: the grammar DAG, event-code lengths,
block token/event lengths, BWT primary, checksums, directory, and bit
padding.

The decoder is deliberately plain Python.  Grammar rules are validated and
pre-expanded once; decoded root IDs are expanded by bulk byte copies.  This
module does not import an external entropy codec and does not claim native
speed.  The BWT/suffix-sort ingredients are established prior art; this
experiment only measures the charged combination against the fixed controls.
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
import binascii
import heapq
import struct
import time
from typing import Iterable, Sequence

try:  # package import when used as frontier_python.symbol_bwt
    from ..grammar import grammar as _grammar
except ImportError:  # top-level import used by the frozen worker harness
    from grammar import grammar as _grammar


MAGIC = b"SBW1"
VERSION = 1
HEADER = struct.Struct("<4sBBHIIQIIIQIII")
HEADER_BYTES = HEADER.size
# Payload-relative offset, encoded bytes including the mode byte, decoded raw
# bytes, root-token count, MTF-event count, cyclic-BWT primary, CRC-32, and
# exact valid Huffman bits.  The explicit token/event fields keep the decoder
# bounded without relying on an unstored sentinel.
DIRECTORY = struct.Struct("<QIIIIIII")
DIRECTORY_BYTES = DIRECTORY.size
EVENT_MAGIC = b"EHD1"
EVENT_HEAD = struct.Struct("<4sBI")

MODE_RAW = 0
MODE_CODED = 1
RUN_A = 0
RUN_B = 1

MAX_FRAME_BYTES = 512 * 1024 * 1024
MAX_RAW_BYTES = 512 * 1024 * 1024
MAX_BLOCK_BYTES = 4 * 1024 * 1024
MAX_BLOCKS = 1_000_000
MAX_EVENT_BITS = 512 * 1024 * 1024 * 8
MAX_CODE_BITS = 32

_LAST_METRICS: dict[str, object] = {}


class FrameError(ValueError):
    """Raised for malformed, truncated, or resource-exhausting frames."""


class ModelError(ValueError):
    """Raised for invalid encoder/decoder models."""


def _crc(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF


def _uleb(value: int) -> bytes:
    if value < 0:
        raise ValueError("negative ULEB")
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def _read_uleb(data: bytes, at: int, *, limit: int) -> tuple[int, int]:
    value = 0
    shift = 0
    for count in range(10):
        if at >= len(data):
            raise FrameError("truncated ULEB")
        part = data[at]
        at += 1
        if count == 9 and part > 1:
            raise FrameError("ULEB overflow")
        value |= (part & 0x7F) << shift
        if not (part & 0x80):
            if count and part == 0:
                raise FrameError("non-canonical ULEB")
            if value > limit:
                raise FrameError("ULEB exceeds bound")
            return value, at
        shift += 7
    raise FrameError("overlong ULEB")


def _huffman_lengths(frequencies: Sequence[int]) -> tuple[int, ...]:
    """Deterministic bounded Huffman lengths with a depth fallback."""

    used = [i for i, count in enumerate(frequencies) if count > 0]
    if not used:
        return tuple(0 for _ in frequencies)
    if len(used) == 1:
        result = [0] * len(frequencies)
        result[used[0]] = 1
        return tuple(result)
    parent = [-1] * len(frequencies)
    heap: list[tuple[int, int, int]] = [(int(frequencies[s]), s, s) for s in used]
    heapq.heapify(heap)
    next_node = len(frequencies)
    while len(heap) > 1:
        left_count, left_min, left = heapq.heappop(heap)
        right_count, right_min, right = heapq.heappop(heap)
        node = next_node
        next_node += 1
        parent.extend([-1] * (node + 1 - len(parent)))
        parent[left] = node
        parent[right] = node
        heapq.heappush(heap, (left_count + right_count, min(left_min, right_min), node))
    lengths = [0] * len(frequencies)
    maximum = 0
    for symbol in used:
        depth = 0
        node = symbol
        while parent[node] >= 0:
            depth += 1
            node = parent[node]
        lengths[symbol] = depth
        maximum = max(maximum, depth)
    if maximum > MAX_CODE_BITS:
        width = max(1, (len(used) - 1).bit_length())
        for symbol in used:
            lengths[symbol] = width
    return tuple(lengths)


def _canonical_codes(lengths: Sequence[int]) -> tuple[tuple[int, int] | None, ...]:
    entries = sorted((int(length), symbol) for symbol, length in enumerate(lengths) if length)
    result: list[tuple[int, int] | None] = [None] * len(lengths)
    code = 0
    previous = 0
    for length, symbol in entries:
        if length < 1 or length > MAX_CODE_BITS:
            raise ModelError("Huffman code length outside bound")
        code <<= length - previous
        if code >= (1 << length):
            raise ModelError("oversubscribed Huffman lengths")
        result[symbol] = (code, length)
        code += 1
        previous = length
    return tuple(result)


def _huffman_tree(lengths: Sequence[int]) -> tuple[tuple[int, int, int], ...]:
    codes = _canonical_codes(lengths)
    tree: list[list[int]] = [[-1, -1, -1]]
    for symbol, item in enumerate(codes):
        if item is None:
            continue
        code, width = item
        node = 0
        for bit_index in range(width - 1, -1, -1):
            if tree[node][2] >= 0:
                raise FrameError("Huffman prefix collision")
            bit = (code >> bit_index) & 1
            child = tree[node][bit]
            if child < 0:
                child = len(tree)
                tree[node][bit] = child
                tree.append([-1, -1, -1])
            node = child
        if tree[node][2] >= 0 or tree[node][0] >= 0 or tree[node][1] >= 0:
            raise FrameError("duplicate Huffman code")
        tree[node][2] = symbol
    return tuple((left, right, symbol) for left, right, symbol in tree)


def _huffman_encode(events: Sequence[int], lengths: Sequence[int]) -> tuple[bytes, int]:
    codes = _canonical_codes(lengths)
    out = bytearray()
    accumulator = 0
    bits = 0
    for symbol in events:
        if symbol < 0 or symbol >= len(codes) or codes[symbol] is None:
            raise ModelError(f"event {symbol} has no Huffman code")
        code, width = codes[symbol]  # type: ignore[misc]
        accumulator = (accumulator << width) | code
        bits += width
        while bits >= 8:
            bits -= 8
            out.append((accumulator >> bits) & 0xFF)
            accumulator &= (1 << bits) - 1 if bits else 0
    valid_bits = len(out) * 8
    if bits:
        out.append((accumulator << (8 - bits)) & 0xFF)
        valid_bits = (len(out) - 1) * 8 + bits
    return bytes(out), valid_bits


def _huffman_decode(body: bytes, valid_bits: int, event_count: int, tree: Sequence[tuple[int, int, int]]) -> list[int]:
    if valid_bits <= 0 or (valid_bits + 7) // 8 != len(body):
        raise FrameError("invalid Huffman bit length")
    if valid_bits > MAX_EVENT_BITS:
        raise FrameError("Huffman bit length exceeds bound")
    padding = (-valid_bits) & 7
    if padding and body[-1] & ((1 << padding) - 1):
        raise FrameError("non-zero Huffman padding")
    output: list[int] = []
    node = 0
    for position in range(valid_bits):
        bit = (body[position // 8] >> (7 - (position & 7))) & 1
        child = tree[node][bit]
        if child < 0:
            raise FrameError("Huffman stream enters missing branch")
        node = child
        symbol = tree[node][2]
        if symbol >= 0:
            output.append(symbol)
            if len(output) > event_count:
                raise FrameError("too many Huffman events")
            node = 0
    if node != 0 or len(output) != event_count:
        raise FrameError("Huffman event count or terminal code mismatch")
    return output


def _cyclic_suffix_order(values: Sequence[int]) -> list[int]:
    """Prefix-doubling cyclic rotation ordering over arbitrary integer IDs."""

    n = len(values)
    if n <= 0:
        raise ValueError("empty BWT sequence")
    # Compress initial IDs to a dense rank range.  This is not wire state.
    classes = {value: index for index, value in enumerate(sorted(set(values)))}
    rank = [classes[value] for value in values]
    order = list(range(n))
    shift = 1
    while shift < n:
        order.sort(key=lambda index: (rank[index], rank[(index + shift) % n]))
        next_rank = [0] * n
        class_count = 1
        previous = order[0]
        previous_key = (rank[previous], rank[(previous + shift) % n])
        next_rank[previous] = 0
        for index in order[1:]:
            key = (rank[index], rank[(index + shift) % n])
            if key != previous_key:
                class_count += 1
                previous_key = key
            next_rank[index] = class_count - 1
        rank = next_rank
        if class_count == n:
            break
        shift <<= 1
    return order


def _bwt_transform(values: Sequence[int]) -> tuple[tuple[int, ...], int]:
    if not values or len(values) > MAX_BLOCK_BYTES:
        raise ValueError("invalid BWT sequence length")
    order = _cyclic_suffix_order(values)
    n = len(values)
    primary = order.index(0)
    last = tuple(values[(position - 1) % n] for position in order)
    return last, primary


def _inverse_bwt(last: Sequence[int], primary: int) -> tuple[int, ...]:
    n = len(last)
    if not n or primary < 0 or primary >= n:
        raise FrameError("invalid BWT primary")
    # Stable occurrence ranks identify the LF permutation without a dense
    # alphabet assumption.  The grammar root alphabet is nevertheless fully
    # known to the frame; this map is decoder-local scratch state.
    counts = Counter(last)
    starts: dict[int, int] = {}
    total = 0
    for symbol in sorted(counts):
        starts[symbol] = total
        total += counts[symbol]
    seen: dict[int, int] = {}
    lf = [0] * n
    for row, symbol in enumerate(last):
        occurrence = seen.get(symbol, 0)
        seen[symbol] = occurrence + 1
        lf[row] = starts[symbol] + occurrence
    output = [0] * n
    row = primary
    for at in range(n - 1, -1, -1):
        output[at] = last[row]
        row = lf[row]
    return tuple(output)


def _mtf_encode(last: Sequence[int], alphabet_size: int) -> tuple[int, ...]:
    if alphabet_size <= 0:
        raise ValueError("empty MTF alphabet")
    symbols = list(range(alphabet_size))
    positions = {symbol: symbol for symbol in symbols}
    ranks: list[int] = []
    for value in last:
        rank = positions.get(value)
        if rank is None:
            raise ModelError("BWT symbol outside grammar alphabet")
        ranks.append(rank)
        if rank:
            for offset in range(rank, 0, -1):
                shifted = symbols[offset - 1]
                symbols[offset] = shifted
                positions[shifted] = offset
            symbols[0] = value
            positions[value] = 0
    return tuple(ranks)


def _mtf_decode(ranks: Sequence[int], alphabet_size: int) -> tuple[int, ...]:
    if alphabet_size <= 0:
        raise FrameError("empty MTF alphabet")
    symbols = list(range(alphabet_size))
    output: list[int] = []
    for rank in ranks:
        if rank < 0 or rank >= alphabet_size:
            raise FrameError("MTF rank outside full grammar alphabet")
        value = symbols[rank]
        output.append(value)
        if rank:
            symbols[1 : rank + 1] = symbols[:rank]
            symbols[0] = value
    return tuple(output)


def _run_events(length: int) -> list[int]:
    if length <= 0:
        raise ValueError("zero run must be positive")
    result: list[int] = []
    value = length
    while value:
        value -= 1
        result.append(RUN_B if value & 1 else RUN_A)
        value >>= 1
    return result


def _ranks_to_events(ranks: Sequence[int]) -> tuple[int, ...]:
    events: list[int] = []
    pending = 0
    for rank in ranks:
        if rank == 0:
            pending += 1
            continue
        if pending:
            events.extend(_run_events(pending))
            pending = 0
        events.append(rank + 1)
    if pending:
        events.extend(_run_events(pending))
    return tuple(events)


def _events_to_ranks(events: Sequence[int], token_count: int, alphabet_size: int) -> tuple[int, ...]:
    ranks: list[int] = []
    run = 0
    power = 1
    in_run = False
    for event in events:
        if event == RUN_A or event == RUN_B:
            if not in_run:
                run = 0
                power = 1
                in_run = True
            run += power if event == RUN_A else power * 2
            if run > token_count - len(ranks):
                raise FrameError("MTF zero run exceeds token count")
            power <<= 1
            if power > token_count + 1:
                raise FrameError("MTF run power exceeds bound")
            continue
        if in_run:
            ranks.extend([0] * run)
            in_run = False
            run = 0
            power = 1
        rank = event - 1
        if rank < 1 or rank >= alphabet_size:
            raise FrameError("MTF event rank outside grammar alphabet")
        ranks.append(rank)
        if len(ranks) > token_count:
            raise FrameError("too many MTF ranks")
    if in_run:
        ranks.extend([0] * run)
    if len(ranks) != token_count:
        raise FrameError("MTF token length mismatch")
    return tuple(ranks)


def _tokenize(data: bytes, model: _grammar.Model) -> list[int]:
    # This stable grammar helper is read-only.  It returns literal/rule root
    # IDs and falls back to literals for any rule absent from a frozen model.
    return _grammar._tokenize_with_model(data, model)


@dataclass
class Model:
    """Complete grammar-root and event model retained by a frame."""

    grammar_model: _grammar.Model
    event_lengths: tuple[int, ...]
    block_bytes: int = 16 * 1024
    build_options: dict[str, object] | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.grammar_model, _grammar.Model):
            raise ModelError("grammar_model must be a grammar.Model")
        expected = self.grammar_model.symbol_count + 1
        self.event_lengths = tuple(int(value) for value in self.event_lengths)
        if len(self.event_lengths) != expected:
            raise ModelError("event table length does not match grammar alphabet")
        if any(value < 1 or value > MAX_CODE_BITS for value in self.event_lengths):
            raise ModelError("event table has an absent or oversized code")
        _canonical_codes(self.event_lengths)
        if self.block_bytes <= 0 or self.block_bytes > MAX_BLOCK_BYTES:
            raise ModelError("block_bytes outside bound")

    @property
    def symbol_count(self) -> int:
        return self.grammar_model.symbol_count

    @property
    def event_count(self) -> int:
        return len(self.event_lengths)

    @property
    def rule_count(self) -> int:
        return self.grammar_model.rule_count

    @property
    def grammar_bytes(self) -> int:
        return len(self.grammar_model.serialize())

    @property
    def event_model_bytes(self) -> int:
        return EVENT_HEAD.size + len(self.event_lengths)

    def serialize_grammar(self) -> bytes:
        return self.grammar_model.serialize()

    def serialize_events(self) -> bytes:
        return EVENT_HEAD.pack(EVENT_MAGIC, VERSION, len(self.event_lengths)) + bytes(self.event_lengths)

    @classmethod
    def from_blobs(cls, grammar_blob: bytes, event_blob: bytes, block_bytes: int) -> "Model":
        try:
            grammar_model = _grammar.Model.from_bytes(grammar_blob)
        except (_grammar.FrameError, _grammar.ModelError) as exc:
            # Normalize only the grammar module's declared malformed-model
            # errors.  Do not turn MemoryError or an implementation bug into a
            # recoverable frame rejection.
            raise FrameError(f"invalid grammar model: {exc}") from exc
        if len(event_blob) < EVENT_HEAD.size:
            raise FrameError("truncated event model")
        magic, version, count = EVENT_HEAD.unpack_from(event_blob)
        if magic != EVENT_MAGIC or version != VERSION or count != grammar_model.symbol_count + 1:
            raise FrameError("invalid event model header")
        if len(event_blob) != EVENT_HEAD.size + count:
            raise FrameError("event model length mismatch")
        lengths = tuple(event_blob[EVENT_HEAD.size:])
        if any(value < 1 or value > MAX_CODE_BITS for value in lengths):
            raise FrameError("event Huffman length outside bound")
        try:
            _canonical_codes(lengths)
        except ModelError as exc:
            raise FrameError(str(exc)) from exc
        return cls(grammar_model=grammar_model, event_lengths=lengths, block_bytes=block_bytes)


def _make_grammar_model(
    raw: bytes,
    block_bytes: int,
    *,
    max_rules: int,
    max_passes: int,
    min_count: int,
    pair_policy: str,
    scope: str,
) -> _grammar.Model:
    # The BWT lane does not use grammar's own event coder.  A fixed grammar
    # model therefore stores exactly the discovered DAG and its root alphabet;
    # the separate BWT event table below is the only entropy state we charge.
    model, _ = _grammar._build_input_model(
        raw,
        block_bytes,
        coder="fixed",
        max_rules=max_rules,
        max_passes=max_passes,
        min_count=min_count,
        pair_policy=pair_policy,
    )
    model.scope = scope
    return model


def _event_counts(raw: bytes, model: _grammar.Model, block_bytes: int) -> tuple[int, ...]:
    counts = [1] * (model.symbol_count + 1)
    for start in range(0, len(raw), block_bytes):
        tokens = _tokenize(raw[start : start + block_bytes], model)
        if not tokens:
            continue
        last, _ = _bwt_transform(tokens)
        ranks = _mtf_encode(last, model.symbol_count)
        for event in _ranks_to_events(ranks):
            counts[event] += 1
    return tuple(counts)


def train(
    training: bytes,
    **opts: object,
) -> Model:
    """Build a complete grammar-root/BWT event model.

    ``input_fit=True`` marks a model built on the encoded input.  This is
    ordinary two-pass compression only when the returned frame stores the full
    model, which :func:`encode` always does.  The default is a training-scope
    model suitable for a separate holdout.  Options intentionally mirror the
    grammar builder's bounded controls: ``max_rules`` (4096/8192),
    ``max_passes`` (24), ``min_count`` and ``pair_policy``.
    """

    if not isinstance(training, (bytes, bytearray, memoryview)):
        raise TypeError("training must be bytes-like")
    raw = bytes(training)
    block_bytes = int(opts.get("block_bytes", 16 * 1024))
    max_rules = int(opts.get("max_rules", 4096))
    max_passes = int(opts.get("max_passes", 24))
    min_count = int(opts.get("min_count", 4))
    pair_policy = str(opts.get("pair_policy", "consistent"))
    input_fit = bool(opts.get("input_fit", False))
    if len(raw) > MAX_RAW_BYTES:
        raise ModelError("training exceeds raw bound")
    scope = "input" if input_fit else "training"
    grammar_model = _make_grammar_model(
        raw,
        block_bytes,
        max_rules=max_rules,
        max_passes=max_passes,
        min_count=min_count,
        pair_policy=pair_policy,
        scope=scope,
    )
    counts = _event_counts(raw, grammar_model, block_bytes)
    lengths = _huffman_lengths(counts)
    # All event IDs have a unit count, so the full known rank alphabet remains
    # decodable for arbitrary bytes not seen during training.
    return Model(
        grammar_model=grammar_model,
        event_lengths=lengths,
        block_bytes=block_bytes,
        build_options={
            "max_rules": max_rules,
            "max_passes": max_passes,
            "min_count": min_count,
            "pair_policy": pair_policy,
            "input_fit": input_fit,
        },
    )


def _encoded_block(raw: bytes, model: Model) -> tuple[bytes, int, int, int, int, int]:
    tokens = _tokenize(raw, model.grammar_model)
    if not tokens or len(tokens) > MAX_BLOCK_BYTES:
        raise ModelError("invalid grammar root token block")
    last, primary = _bwt_transform(tokens)
    ranks = _mtf_encode(last, model.symbol_count)
    events = _ranks_to_events(ranks)
    body, valid_bits = _huffman_encode(events, model.event_lengths)
    coded = bytes((MODE_CODED,)) + body
    raw_candidate = bytes((MODE_RAW,)) + raw
    if len(coded) >= len(raw_candidate):
        return raw_candidate, 0, 0, 0, 0, len(tokens)
    return coded, len(tokens), len(events), primary, valid_bits, len(tokens)


@dataclass(frozen=True)
class DirectoryRecord:
    offset: int
    encoded_bytes: int
    raw_bytes: int
    token_count: int
    event_count: int
    primary: int
    crc32: int
    valid_bits: int


def _metadata_crc(header_zero: bytes, grammar_blob: bytes, event_blob: bytes, directory: bytes) -> int:
    return _crc(header_zero + grammar_blob + event_blob + directory)


def encode(data: bytes, model: Model, block_bytes: int = 16 * 1024) -> bytes:
    """Encode complete independently addressed blocks against ``model``."""

    if not isinstance(data, (bytes, bytearray, memoryview)):
        raise TypeError("data must be bytes-like")
    raw = bytes(data)
    if len(raw) > MAX_RAW_BYTES:
        raise FrameError("input exceeds raw bound")
    if not isinstance(model, Model):
        raise TypeError("model must be a symbol_bwt.Model")
    if block_bytes <= 0 or block_bytes > MAX_BLOCK_BYTES:
        raise ValueError("block_bytes outside bound")
    block_count = 0 if not raw else (len(raw) - 1) // block_bytes + 1
    if block_count > MAX_BLOCKS:
        raise FrameError("block count exceeds bound")
    grammar_blob = model.serialize_grammar()
    event_blob = model.serialize_events()
    if len(grammar_blob) > _grammar.MAX_MODEL_BYTES:
        raise FrameError("grammar model exceeds bound")
    encoded_blocks: list[bytes] = []
    records: list[DirectoryRecord] = []
    payload = bytearray()
    coded_blocks = 0
    raw_blocks = 0
    entropy_bits = 0
    token_total = 0
    event_total = 0
    padding_bits = 0
    for start in range(0, len(raw), block_bytes):
        raw_block = raw[start : start + block_bytes]
        encoded, token_count, event_count, primary, valid_bits, _ = _encoded_block(raw_block, model)
        mode = encoded[0]
        if mode == MODE_CODED:
            coded_blocks += 1
            entropy_bits += valid_bits
            padding_bits += (-valid_bits) & 7
            token_total += token_count
            event_total += event_count
        else:
            raw_blocks += 1
        offset = len(payload)
        payload.extend(encoded)
        records.append(
            DirectoryRecord(
                offset=offset,
                encoded_bytes=len(encoded),
                raw_bytes=len(raw_block),
                token_count=token_count,
                event_count=event_count,
                primary=primary,
                crc32=_crc(raw_block),
                valid_bits=valid_bits,
            )
        )
    directory = bytearray(len(records) * DIRECTORY_BYTES)
    for index, record in enumerate(records):
        DIRECTORY.pack_into(
            directory,
            index * DIRECTORY_BYTES,
            record.offset,
            record.encoded_bytes,
            record.raw_bytes,
            record.token_count,
            record.event_count,
            record.primary,
            record.crc32,
            record.valid_bits,
        )
    header_zero = HEADER.pack(
        MAGIC,
        VERSION,
        0,
        HEADER_BYTES,
        block_bytes,
        block_count,
        len(raw),
        len(grammar_blob),
        len(event_blob),
        len(directory),
        len(payload),
        model.symbol_count,
        0,
        0,
    )
    metadata_crc = _metadata_crc(header_zero, grammar_blob, event_blob, bytes(directory))
    header = HEADER.pack(
        MAGIC,
        VERSION,
        0,
        HEADER_BYTES,
        block_bytes,
        block_count,
        len(raw),
        len(grammar_blob),
        len(event_blob),
        len(directory),
        len(payload),
        model.symbol_count,
        metadata_crc,
        0,
    )
    frame = header + grammar_blob + event_blob + bytes(directory) + bytes(payload)
    if len(frame) > MAX_FRAME_BYTES:
        raise FrameError("frame exceeds bound")
    global _LAST_METRICS
    _LAST_METRICS = {
        "complete_bytes": len(frame),
        "raw_bytes": len(raw),
        "header_bytes": HEADER_BYTES,
        "grammar_model_bytes": len(grammar_blob),
        "event_model_bytes": len(event_blob),
        "model_bytes": len(grammar_blob) + len(event_blob),
        "directory_bytes": len(directory),
        "payload_bytes": len(payload),
        "coded_blocks": coded_blocks,
        "raw_blocks": raw_blocks,
        "entropy_bits": entropy_bits,
        "padding_bits": padding_bits,
        "root_token_count": token_total,
        "event_count": event_total,
        "rule_count": model.rule_count,
        "symbol_count": model.symbol_count,
        "scope": model.grammar_model.scope,
        "grammar": dict(model.grammar_model.grammar_metrics or {}),
        "pair_policy": (model.build_options or {}).get("pair_policy"),
    }
    return frame


@dataclass
class _ParsedFrame:
    wire: bytes
    block_bytes: int
    raw_length: int
    model: Model
    records: tuple[DirectoryRecord, ...]
    payload_offset: int


def _parse_frame(frame: bytes) -> _ParsedFrame:
    if not isinstance(frame, (bytes, bytearray, memoryview)):
        raise FrameError("frame must be bytes-like")
    wire = bytes(frame)
    if len(wire) < HEADER_BYTES or len(wire) > MAX_FRAME_BYTES:
        raise FrameError("frame length outside bound")
    (
        magic,
        version,
        flags,
        header_size,
        block_bytes,
        block_count,
        raw_length,
        grammar_length,
        event_length,
        directory_length,
        payload_length,
        symbol_count,
        metadata_crc,
        reserved,
    ) = HEADER.unpack_from(wire)
    if magic != MAGIC or version != VERSION or flags or header_size != HEADER_BYTES or reserved:
        raise FrameError("invalid symbol-BWT header")
    if not (1 <= block_bytes <= MAX_BLOCK_BYTES) or block_count > MAX_BLOCKS:
        raise FrameError("invalid block configuration")
    if raw_length > MAX_RAW_BYTES:
        raise FrameError("raw length exceeds bound")
    if grammar_length > _grammar.MAX_MODEL_BYTES:
        raise FrameError("grammar model length exceeds bound")
    # The event model is one fixed dense byte per reachable MTF event plus its
    # small header.  Enforce this before slicing attacker-controlled metadata;
    # the grammar rule cap bounds the full known rank alphabet.
    max_event_model = EVENT_HEAD.size + (_grammar.MAX_RULES + 256 + 1)
    if event_length < EVENT_HEAD.size or event_length > max_event_model:
        raise FrameError("event model length exceeds bound")
    if directory_length > MAX_BLOCKS * DIRECTORY_BYTES:
        raise FrameError("directory length exceeds bound")
    if payload_length > MAX_FRAME_BYTES:
        raise FrameError("payload length exceeds bound")
    expected_blocks = 0 if raw_length == 0 else (raw_length - 1) // block_bytes + 1
    if block_count != expected_blocks or directory_length != block_count * DIRECTORY_BYTES:
        raise FrameError("invalid directory length")
    grammar_at = HEADER_BYTES
    event_at = grammar_at + grammar_length
    directory_at = event_at + event_length
    payload_at = directory_at + directory_length
    if payload_at > len(wire) or payload_length != len(wire) - payload_at:
        raise FrameError("frame lengths do not cover wire")
    grammar_blob = wire[grammar_at:event_at]
    event_blob = wire[event_at:directory_at]
    directory_blob = wire[directory_at:payload_at]
    header_zero = HEADER.pack(
        MAGIC,
        VERSION,
        0,
        HEADER_BYTES,
        block_bytes,
        block_count,
        raw_length,
        grammar_length,
        event_length,
        directory_length,
        payload_length,
        symbol_count,
        0,
        0,
    )
    if metadata_crc != _metadata_crc(header_zero, grammar_blob, event_blob, directory_blob):
        raise FrameError("metadata checksum mismatch")
    model = Model.from_blobs(grammar_blob, event_blob, block_bytes)
    if model.symbol_count != symbol_count:
        raise FrameError("header grammar alphabet mismatch")
    records: list[DirectoryRecord] = []
    expected_offset = 0
    raw_total = 0
    for index in range(block_count):
        fields = DIRECTORY.unpack_from(directory_blob, index * DIRECTORY_BYTES)
        record = DirectoryRecord(*fields)
        if record.offset != expected_offset or record.encoded_bytes <= 1:
            raise FrameError(f"invalid block offset/length at {index}")
        if record.raw_bytes <= 0 or record.raw_bytes > block_bytes:
            raise FrameError(f"invalid raw block length at {index}")
        if index + 1 < block_count and record.raw_bytes != block_bytes:
            raise FrameError("short non-final block")
        if record.offset + record.encoded_bytes > payload_length:
            raise FrameError("block payload exceeds frame")
        mode = wire[payload_at + record.offset]
        body_len = record.encoded_bytes - 1
        if mode == MODE_RAW:
            if record.token_count or record.event_count or record.primary or record.valid_bits or body_len != record.raw_bytes:
                raise FrameError("invalid raw block metadata")
        elif mode == MODE_CODED:
            if not record.token_count or record.token_count > record.raw_bytes:
                raise FrameError("invalid root token count")
            if not record.event_count or record.event_count > record.token_count * 2 + 16:
                raise FrameError("invalid event count")
            if record.primary >= record.token_count or record.valid_bits <= 0:
                raise FrameError("invalid BWT/Huffman metadata")
            if (record.valid_bits + 7) // 8 != body_len:
                raise FrameError("coded body length does not match valid bits")
        else:
            raise FrameError("unknown block mode")
        expected_offset += record.encoded_bytes
        raw_total += record.raw_bytes
        if raw_total > MAX_RAW_BYTES:
            raise FrameError("directory raw total exceeds bound")
        records.append(record)
    if expected_offset != payload_length or raw_total != raw_length:
        raise FrameError("directory totals mismatch")
    return _ParsedFrame(wire, block_bytes, raw_length, model, tuple(records), payload_at)


@dataclass
class Prepared:
    """Parsed frame with grammar expansions and the event tree retained."""

    parsed: _ParsedFrame
    setup_ns: int = 0
    decode_event_ops: int = 0
    decode_root_ops: int = 0
    decode_copy_bytes: int = 0
    _tree: tuple[tuple[int, int, int], ...] = ()
    _table: tuple[bytes, ...] = ()

    def __post_init__(self) -> None:
        self._tree = _huffman_tree(self.parsed.model.event_lengths)
        self._table = _grammar._LEAF_TABLE + self.parsed.model.grammar_model.expansions

    @property
    def frame(self) -> bytes:
        return self.parsed.wire

    @property
    def model(self) -> Model:
        return self.parsed.model

    def decode_block(self, index: int) -> bytes:
        if index < 0 or index >= len(self.parsed.records):
            raise FrameError("block index out of range")
        record = self.parsed.records[index]
        start = self.parsed.payload_offset + record.offset
        end = start + record.encoded_bytes
        if start < self.parsed.payload_offset or end > len(self.parsed.wire):
            raise FrameError("block payload outside frame")
        encoded = self.parsed.wire[start:end]
        mode = encoded[0]
        if mode == MODE_RAW:
            result = encoded[1:]
            if len(result) != record.raw_bytes:
                raise FrameError("raw block length mismatch")
        elif mode == MODE_CODED:
            body = encoded[1:]
            events = _huffman_decode(body, record.valid_bits, record.event_count, self._tree)
            self.decode_event_ops += len(events)
            ranks = _events_to_ranks(events, record.token_count, self.model.symbol_count)
            last = _mtf_decode(ranks, self.model.symbol_count)
            root_tokens = _inverse_bwt(last, record.primary)
            if len(root_tokens) != record.token_count:
                raise FrameError("BWT token count mismatch")
            output = bytearray()
            for symbol in root_tokens:
                if symbol < 0 or symbol >= len(self._table):
                    raise FrameError("root symbol outside grammar table")
                expansion = self._table[symbol]
                if len(output) + len(expansion) > record.raw_bytes:
                    raise FrameError("grammar expansion exceeds block length")
                output.extend(expansion)
                self.decode_root_ops += 1
                self.decode_copy_bytes += len(expansion)
            if len(output) != record.raw_bytes:
                raise FrameError("grammar expansion length mismatch")
            result = bytes(output)
        else:
            raise FrameError("invalid block mode")
        if _crc(result) != record.crc32:
            raise FrameError("block CRC mismatch")
        return result

    def decode_all(self) -> bytes:
        output = bytearray()
        for index in range(len(self.parsed.records)):
            output.extend(self.decode_block(index))
        if len(output) != self.parsed.raw_length:
            raise FrameError("decoded frame length mismatch")
        return bytes(output)


def prepare(frame: bytes) -> Prepared:
    started = time.perf_counter_ns()
    parsed = _parse_frame(frame)
    prepared = Prepared(parsed)
    prepared.setup_ns = time.perf_counter_ns() - started
    return prepared


def decode(frame: bytes | Prepared) -> bytes:
    return (frame if isinstance(frame, Prepared) else prepare(frame)).decode_all()


def decode_all(frame: bytes | Prepared) -> bytes:
    return decode(frame)


def decode_block(frame: bytes | Prepared, index: int) -> bytes:
    return (frame if isinstance(frame, Prepared) else prepare(frame)).decode_block(index)


def frame_metrics(frame: bytes | Prepared) -> dict[str, object]:
    prepared = frame if isinstance(frame, Prepared) else prepare(frame)
    parsed = prepared.parsed
    payload_bytes = len(parsed.wire) - parsed.payload_offset
    coded = sum(
        1
        for record in parsed.records
        if parsed.wire[parsed.payload_offset + record.offset] == MODE_CODED
    )
    raw_blocks = len(parsed.records) - coded
    entropy_bits = sum(record.valid_bits for record in parsed.records)
    grammar_blob = parsed.model.serialize_grammar()
    event_blob = parsed.model.serialize_events()
    expansion_bytes = parsed.model.grammar_model.preexpanded_bytes
    # Logical native-sized estimate, separate from Python object RSS.  The
    # canonical tree has three i32 fields per node; MTF scratch is one symbol
    # array plus one rank map over the full stored grammar alphabet.
    huff_tree_bytes = len(prepared._tree) * 12
    mtf_scratch_bytes = parsed.model.symbol_count * 8
    return {
        "complete_bytes": len(parsed.wire),
        "frame_bytes": len(parsed.wire),
        "raw_bytes": parsed.raw_length,
        "header_bytes": HEADER_BYTES,
        "grammar_model_bytes": len(grammar_blob),
        "event_model_bytes": len(event_blob),
        "model_bytes": len(grammar_blob) + len(event_blob),
        "directory_bytes": len(parsed.records) * DIRECTORY_BYTES,
        "payload_bytes": payload_bytes,
        "block_count": len(parsed.records),
        "block_bytes": parsed.block_bytes,
        "coded_blocks": coded,
        "raw_blocks": raw_blocks,
        "entropy_bits": entropy_bits,
        "padding_bits": sum((-record.valid_bits) & 7 for record in parsed.records if record.valid_bits),
        "rule_count": parsed.model.rule_count,
        "symbol_count": parsed.model.symbol_count,
        "root_token_count": sum(record.token_count for record in parsed.records),
        "event_count": sum(record.event_count for record in parsed.records),
        "grammar_preexpanded_bytes": expansion_bytes,
        "prepared_setup_ns": prepared.setup_ns,
        "prepared_huffman_tree_bytes_estimate": huff_tree_bytes,
        "prepared_mtf_scratch_bytes_estimate": mtf_scratch_bytes,
        "prepared_state_bytes_estimate": expansion_bytes + huff_tree_bytes + mtf_scratch_bytes,
        "decode_event_ops": prepared.decode_event_ops,
        "decode_root_ops": prepared.decode_root_ops,
        "decode_copy_bytes": prepared.decode_copy_bytes,
        "scope": parsed.model.grammar_model.scope,
        "pair_policy": (parsed.model.build_options or {}).get("pair_policy"),
        "grammar": dict(parsed.model.grammar_model.grammar_metrics or {}),
    }


def metrics(frame: bytes | Prepared | None = None) -> dict[str, object]:
    """Return current frame metrics or the most recent encoder metrics."""

    if frame is None:
        return dict(_LAST_METRICS)
    return frame_metrics(frame)


__all__ = [
    "MAGIC",
    "HEADER",
    "DIRECTORY",
    "FrameError",
    "ModelError",
    "Model",
    "Prepared",
    "train",
    "encode",
    "prepare",
    "decode",
    "decode_all",
    "decode_block",
    "frame_metrics",
    "metrics",
]
