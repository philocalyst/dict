"""Reversible structural/context separation experiment.

The module deliberately works on bytes, not parsed dictionary records.  Each
block is transformed independently and then sent to zlib.  zlib is a standard
codec used here as an explicitly labelled diagnostic bound; the transform and
its inverse are the object of this experiment, not a claim of a new entropy
decoder.

Public API:

``train(training, variant=...)``
    Build the charged model from the training partition only.
``encode(model, data, block_bytes=...)``
    Produce a self-contained frame with independently decodable blocks.
``decode(frame)`` / ``decode_block(frame, index)``
    Validate and reconstruct all bytes or one block.
``frame_info(frame)``
    Return accounting information without decoding every payload.

The frame is intentionally boring and defensive.  Header, model, directory,
transformed lengths, checksums, and fallback choices are all serialized.  No
external dictionary or hidden model state is needed to decode a frame.
"""

from __future__ import annotations

import binascii
import struct
import zlib
from dataclasses import dataclass
from typing import Iterable, Sequence


MAGIC = b"B4ST"
VERSION = 1
BACKEND_ZLIB_DIAGNOSTIC = 1
MAX_BLOCK_BYTES = 64 * 1024
MAX_FRAME_BYTES = 512 * 1024 * 1024
MAX_MODEL_BYTES = 32 * 1024 * 1024
MAX_BLOCKS = 1_000_000

# Header fields are little-endian and fixed width.  The last field is a CRC of
# the header with that field zeroed, followed by the exact model and directory.
HEADER_FMT = "<4sBBBBIQIIIQIII"
HEADER_SIZE = struct.calcsize(HEADER_FMT)
DIR_FMT = "<QIIIIIB3s"
DIR_SIZE = struct.calcsize(DIR_FMT)
TRANS_FMT = "<4sBBHIII"
TRANS_SIZE = struct.calcsize(TRANS_FMT)
TRANS_MAGIC = b"TRS1"
MODEL_MAGIC = b"SMD1"

CLASS_COUNT = 8
# Byte classes are a deterministic wire-level choice.  In particular, bytes
# with the high bit set are classified by byte value only; invalid UTF-8 is
# never rejected or normalized.


class FrameError(ValueError):
    """Raised when a frame, model, or transformed block is malformed."""


_VARIANT_TO_CODE = {"raw": 0, "shape": 1, "byteclass": 2, "templates": 3}
_CODE_TO_VARIANT = {value: key for key, value in _VARIANT_TO_CODE.items()}


def _classify_byte(value: int) -> int:
    if value in (0x09, 0x0A, 0x0D, 0x20):
        return 0  # common whitespace
    if 0x30 <= value <= 0x39:
        return 1  # ASCII digit
    if 0x61 <= value <= 0x7A:
        return 2  # ASCII lower case
    if 0x41 <= value <= 0x5A:
        return 3  # ASCII upper case
    if 0x21 <= value <= 0x7E:
        return 4  # punctuation / symbols (alnum was handled above)
    if 0x80 <= value <= 0xBF:
        return 5  # UTF-8 continuation-shaped or arbitrary high byte
    if 0xC0 <= value <= 0xFF:
        return 6  # UTF-8 lead-shaped or arbitrary high byte
    return 7  # remaining controls, including DEL and NUL


CLASS_MAP = bytes(_classify_byte(value) for value in range(256))


def _crc(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF


def _put_uleb(value: int) -> bytes:
    if value < 0:
        raise ValueError("ULEB128 cannot encode a negative value")
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def _uleb_len(value: int) -> int:
    return len(_put_uleb(value))


def _read_uleb(data: bytes, at: int, *, limit: int | None = None) -> tuple[int, int]:
    """Read one canonical unsigned LEB128 value with a bounded 64-bit width."""

    value = 0
    shift = 0
    start = at
    for count in range(10):
        if at >= len(data):
            raise FrameError("truncated ULEB128")
        part = data[at]
        at += 1
        if count == 9 and part > 1:
            raise FrameError("ULEB128 integer overflow")
        value |= (part & 0x7F) << shift
        if not (part & 0x80):
            if count and part == 0:
                raise FrameError("non-canonical ULEB128")
            if limit is not None and value > limit:
                raise FrameError("ULEB128 value exceeds bound")
            return value, at
        shift += 7
    raise FrameError("ULEB128 integer overflow")


def _tokenize(data: bytes, class_map: bytes = CLASS_MAP) -> list[tuple[int, bytes]]:
    """Return maximal same-class runs while retaining exact byte slices."""

    if len(class_map) != 256 or any(value >= CLASS_COUNT for value in class_map):
        raise FrameError("invalid byte-class map")
    result: list[tuple[int, bytes]] = []
    at = 0
    while at < len(data):
        category = class_map[data[at]]
        end = at + 1
        while end < len(data) and class_map[data[end]] == category:
            end += 1
        result.append((category, data[at:end]))
        at = end
    return result


Descriptor = tuple[int, int]
Template = tuple[Descriptor, ...]


@dataclass(frozen=True)
class Model:
    """All training-derived state needed by a transform decoder."""

    variant: str
    class_map: bytes = CLASS_MAP
    templates: tuple[Template, ...] = ()
    training_bytes: int = 0

    def __post_init__(self) -> None:
        if self.variant not in _VARIANT_TO_CODE:
            raise ValueError(f"unknown variant: {self.variant}")
        if self.variant == "raw" and self.templates:
            raise ValueError("raw model cannot contain templates")
        if len(self.class_map) != 256 or any(value >= CLASS_COUNT for value in self.class_map):
            raise ValueError("class_map must contain 256 class IDs")
        if len(self.templates) > 255:
            raise ValueError("too many templates")
        for template in self.templates:
            if not template or len(template) > 255:
                raise ValueError("template must contain 1..255 descriptors")
            for category, length in template:
                if not 0 <= category < CLASS_COUNT or not 0 < length <= MAX_BLOCK_BYTES:
                    raise ValueError("invalid template descriptor")

    @property
    def code(self) -> int:
        return _VARIANT_TO_CODE[self.variant]

    def to_bytes(self) -> bytes:
        if self.variant == "raw":
            return b""
        if self.training_bytes < 0 or self.training_bytes > 0xFFFFFFFF:
            raise ValueError("training byte count out of range")
        out = bytearray(MODEL_MAGIC)
        out.extend(struct.pack("<BBBBI", self.code, len(self.templates), 0, 0, self.training_bytes))
        out.extend(self.class_map)
        for template in self.templates:
            out.append(len(template))
            for category, length in template:
                out.append(category)
                out.extend(_put_uleb(length))
        return bytes(out)

    @classmethod
    def from_bytes(cls, variant: str, data: bytes) -> "Model":
        if variant not in _VARIANT_TO_CODE:
            raise FrameError("unknown model variant")
        if variant == "raw":
            if data:
                raise FrameError("raw model must be empty")
            return cls(variant="raw")
        if len(data) < 4 + 8 + 256:
            raise FrameError("truncated model")
        if data[:4] != MODEL_MAGIC:
            raise FrameError("invalid model magic")
        model_code, template_count, reserved_a, reserved_b, training_bytes = struct.unpack(
            "<BBBBI", data[4:12]
        )
        if model_code != _VARIANT_TO_CODE[variant] or reserved_a or reserved_b:
            raise FrameError("model/header variant mismatch")
        class_map = data[12:268]
        if len(class_map) != 256 or any(value >= CLASS_COUNT for value in class_map):
            raise FrameError("invalid class map")
        at = 268
        templates: list[Template] = []
        for _ in range(template_count):
            if at >= len(data):
                raise FrameError("truncated template table")
            descriptor_count = data[at]
            at += 1
            if descriptor_count == 0:
                raise FrameError("empty template")
            descriptors: list[Descriptor] = []
            for _ in range(descriptor_count):
                if at >= len(data):
                    raise FrameError("truncated template descriptor")
                category = data[at]
                at += 1
                length, at = _read_uleb(data, at, limit=MAX_BLOCK_BYTES)
                if category >= CLASS_COUNT or not 0 < length <= MAX_BLOCK_BYTES:
                    raise FrameError("invalid template descriptor")
                descriptors.append((category, length))
            templates.append(tuple(descriptors))
        if at != len(data):
            raise FrameError("trailing model bytes")
        if variant != "templates" and templates:
            raise FrameError("non-template model contains templates")
        return cls(variant=variant, class_map=class_map, templates=tuple(templates), training_bytes=training_bytes)


def _descriptor_cost(descriptor: Descriptor) -> int:
    return 1 + _uleb_len(descriptor[1])


def _select_templates(training: bytes, class_map: bytes, max_templates: int) -> tuple[Template, ...]:
    """Select a bounded repeated descriptor vocabulary from training bytes.

    This is intentionally a small deterministic selector rather than an
    attempt at an optimal grammar.  Limiting the sampled descriptor prefix
    makes training memory bounded even for a byte-heavy corpus.
    """

    if max_templates <= 0:
        return ()
    tokens = _tokenize(training, class_map)
    descriptors = [(category, len(value)) for category, value in tokens]
    # A 60k-descriptor sample is enough to expose common structural sequences,
    # while keeping the Python Counter bounded on punctuation-heavy data.
    descriptors = descriptors[:60_000]
    if len(descriptors) < 2:
        return ()

    candidates: list[tuple[int, int, Template]] = []
    for width in range(2, 7):
        if len(descriptors) < width:
            break
        counts: dict[Template, int] = {}
        for at in range(len(descriptors) - width + 1):
            sequence = tuple(descriptors[at : at + width])
            counts[sequence] = counts.get(sequence, 0) + 1
        for sequence, count in counts.items():
            if count < 2:
                continue
            if any(length > MAX_BLOCK_BYTES for _, length in sequence):
                continue
            descriptor_bytes = sum(_descriptor_cost(item) for item in sequence)
            # A template event costs tag + a small ID in the usual case.  The
            # model itself is charged below as one descriptor sequence.
            event_bytes = 2
            model_bytes = 1 + descriptor_bytes
            score = (descriptor_bytes - event_bytes) * count - model_bytes
            if score > 0:
                candidates.append((score, count, sequence))

    candidates.sort(key=lambda item: (-item[0], -item[1], -len(item[2]), item[2]))
    result: list[Template] = []
    seen: set[Template] = set()
    for _, _, sequence in candidates:
        if sequence in seen:
            continue
        result.append(sequence)
        seen.add(sequence)
        if len(result) >= max_templates:
            break
    return tuple(result)


def train(training: bytes, *, variant: str = "templates", max_templates: int = 96) -> Model:
    """Train a model from a disjoint byte prefix.

    No bytes outside ``training`` are inspected.  For non-raw variants the
    static class map is serialized into the frame to make the charged model
    explicit, even though this particular map is deterministic.
    """

    if variant not in _VARIANT_TO_CODE:
        raise ValueError(f"unknown variant: {variant}")
    training = bytes(training)
    if variant == "raw":
        return Model(variant="raw", training_bytes=len(training))
    templates: tuple[Template, ...] = ()
    if variant == "templates":
        templates = _select_templates(training, CLASS_MAP, max_templates)
    return Model(
        variant=variant,
        class_map=CLASS_MAP,
        templates=templates,
        training_bytes=len(training),
    )


def _encode_descriptors(descriptors: Sequence[Descriptor]) -> bytes:
    out = bytearray()
    for category, length in descriptors:
        out.append(category)
        out.extend(_put_uleb(length))
    return bytes(out)


def _encode_lanes(tokens: Sequence[tuple[int, bytes]]) -> bytes:
    lanes = [bytearray() for _ in range(CLASS_COUNT)]
    for category, value in tokens:
        lanes[category].extend(value)
    return b"".join(bytes(lane) for lane in lanes)


def _encode_template_events(
    descriptors: Sequence[Descriptor], templates: Sequence[Template]
) -> bytes:
    # Longest-first matching makes event choices deterministic and gives the
    # selector a fair chance to amortize repeated shape sequences.
    by_width: dict[int, dict[Template, int]] = {}
    for index, template in enumerate(templates):
        by_width.setdefault(len(template), {})[template] = index
    widths = sorted(by_width, reverse=True)
    out = bytearray()
    at = 0
    while at < len(descriptors):
        matched = False
        for width in widths:
            if at + width > len(descriptors):
                continue
            sequence = tuple(descriptors[at : at + width])
            index = by_width[width].get(sequence)
            if index is None:
                continue
            out.append(1)
            out.extend(_put_uleb(index))
            at += width
            matched = True
            break
        if matched:
            continue
        category, length = descriptors[at]
        out.append(0)
        out.append(category)
        out.extend(_put_uleb(length))
        at += 1
    return bytes(out)


def _pack_selectors(categories: Iterable[int]) -> bytes:
    values = list(categories)
    out = bytearray((len(values) * 3 + 7) // 8)
    bit_at = 0
    for category in values:
        if not 0 <= category < CLASS_COUNT:
            raise ValueError("invalid class selector")
        byte_at = bit_at >> 3
        shift = bit_at & 7
        value = category << shift
        out[byte_at] |= value & 0xFF
        if shift > 5:
            out[byte_at + 1] |= (value >> 8) & 0xFF
        bit_at += 3
    return bytes(out)


def _unpack_selectors(data: bytes, count: int) -> list[int]:
    expected = (count * 3 + 7) // 8
    if len(data) != expected:
        raise FrameError("invalid selector length")
    values: list[int] = []
    bit_at = 0
    for _ in range(count):
        byte_at = bit_at >> 3
        shift = bit_at & 7
        value = data[byte_at] >> shift
        if shift > 5:
            value |= data[byte_at + 1] << (8 - shift)
        value &= 0x07
        if value >= CLASS_COUNT:
            raise FrameError("invalid class selector")
        values.append(value)
        bit_at += 3
    # Bits after the final selector are required to be zero.  This removes an
    # otherwise ambiguous alias for the same transformed block.
    unused = len(data) * 8 - count * 3
    if unused:
        if data[-1] >> (8 - unused):
            raise FrameError("non-canonical selector tail")
    return values


def _make_transform(model: Model, raw: bytes) -> bytes:
    if model.variant == "raw":
        return raw
    if model.variant in ("shape", "templates"):
        tokens = _tokenize(raw, model.class_map)
        descriptors = [(category, len(value)) for category, value in tokens]
        if model.variant == "shape":
            events = _encode_descriptors(descriptors)
            mode = 1
        else:
            events = _encode_template_events(descriptors, model.templates)
            mode = 3
        header = struct.pack(TRANS_FMT, TRANS_MAGIC, VERSION, mode, 0, len(events), len(tokens), len(raw))
        return header + events + _encode_lanes(tokens)
    if model.variant == "byteclass":
        categories = [model.class_map[value] for value in raw]
        selectors = _pack_selectors(categories)
        tokens = [(category, bytes([value])) for category, value in zip(categories, raw)]
        header = struct.pack(TRANS_FMT, TRANS_MAGIC, VERSION, 2, 0, len(selectors), len(raw), len(raw))
        return header + selectors + _encode_lanes(tokens)
    raise ValueError("unknown model variant")


def _parse_transform(model: Model, transformed: bytes, expected_raw_len: int) -> bytes:
    if model.variant == "raw":
        if len(transformed) != expected_raw_len:
            raise FrameError("raw transformed length mismatch")
        return transformed
    if len(transformed) < TRANS_SIZE:
        raise FrameError("truncated transform header")
    magic, version, mode, flags, event_len, token_count, raw_len = struct.unpack(
        TRANS_FMT, transformed[:TRANS_SIZE]
    )
    if magic != TRANS_MAGIC or version != VERSION or flags:
        raise FrameError("invalid transform header")
    if raw_len != expected_raw_len:
        raise FrameError("transform/raw length mismatch")
    if event_len > len(transformed) - TRANS_SIZE:
        raise FrameError("transform event stream out of bounds")
    event_data = transformed[TRANS_SIZE : TRANS_SIZE + event_len]
    lane_data = transformed[TRANS_SIZE + event_len :]

    if model.variant == "shape" and mode != 1:
        raise FrameError("shape mode mismatch")
    if model.variant == "templates" and mode != 3:
        raise FrameError("template mode mismatch")
    if model.variant == "byteclass" and mode != 2:
        raise FrameError("byteclass mode mismatch")

    if mode == 1:
        descriptors: list[Descriptor] = []
        at = 0
        for _ in range(token_count):
            if at >= len(event_data):
                raise FrameError("truncated shape descriptor")
            category = event_data[at]
            at += 1
            length, at = _read_uleb(event_data, at, limit=MAX_BLOCK_BYTES)
            if category >= CLASS_COUNT or length == 0:
                raise FrameError("invalid shape descriptor")
            descriptors.append((category, length))
        if at != len(event_data):
            raise FrameError("trailing shape event bytes")
        return _reconstruct_lanes(descriptors, lane_data, raw_len)

    if mode == 3:
        descriptors = []
        at = 0
        # ``token_count`` counts expanded descriptors, not template events;
        # template events are variable width and are therefore parsed until
        # the exact event stream ends.
        while at < len(event_data):
            if at >= len(event_data):
                raise FrameError("truncated template event")
            tag = event_data[at]
            at += 1
            if tag == 0:
                if at >= len(event_data):
                    raise FrameError("truncated literal template event")
                category = event_data[at]
                at += 1
                length, at = _read_uleb(event_data, at, limit=MAX_BLOCK_BYTES)
                if category >= CLASS_COUNT or length == 0:
                    raise FrameError("invalid literal template descriptor")
                descriptors.append((category, length))
            elif tag == 1:
                index, at = _read_uleb(event_data, at, limit=len(model.templates) - 1 if model.templates else 0)
                if index >= len(model.templates):
                    raise FrameError("template index out of bounds")
                descriptors.extend(model.templates[index])
            else:
                raise FrameError("unknown template event")
            if len(descriptors) > token_count:
                raise FrameError("template expansion exceeds declared token count")
        if at != len(event_data):
            raise FrameError("trailing template event bytes")
        if len(descriptors) != token_count:
            raise FrameError("template token count mismatch")
        if len(descriptors) == 0 and raw_len:
            raise FrameError("nonempty block has no descriptors")
        return _reconstruct_lanes(descriptors, lane_data, raw_len)

    if mode == 2:
        categories = _unpack_selectors(event_data, token_count)
        if token_count != raw_len:
            raise FrameError("byteclass selector count mismatch")
        descriptors = [(category, 1) for category in categories]
        return _reconstruct_lanes(descriptors, lane_data, raw_len)
    raise FrameError("unknown transform mode")


def _reconstruct_lanes(descriptors: Sequence[Descriptor], lane_data: bytes, raw_len: int) -> bytes:
    expected = sum(length for _, length in descriptors)
    if expected != raw_len:
        raise FrameError("descriptor output length mismatch")
    lane_lengths = [0] * CLASS_COUNT
    for category, length in descriptors:
        if not 0 <= category < CLASS_COUNT or length <= 0:
            raise FrameError("invalid lane descriptor")
        lane_lengths[category] += length
    if sum(lane_lengths) != len(lane_data):
        raise FrameError("lane payload length mismatch")
    starts: list[int] = []
    at = 0
    for length in lane_lengths:
        starts.append(at)
        at += length
    cursors = starts[:]
    out = bytearray()
    for category, length in descriptors:
        cursor = cursors[category]
        end = cursor + length
        lane_end = starts[category] + lane_lengths[category]
        if end > lane_end:
            raise FrameError("lane read out of bounds")
        out.extend(lane_data[cursor:end])
        cursors[category] = end
    for category in range(CLASS_COUNT):
        if cursors[category] != starts[category] + lane_lengths[category]:
            raise FrameError("lane bytes were not consumed exactly")
    return bytes(out)


@dataclass(frozen=True)
class _Record:
    offset: int
    wire_len: int
    raw_len: int
    transformed_len: int
    raw_crc: int
    transformed_crc: int
    mode: int


@dataclass(frozen=True)
class _Frame:
    frame: bytes
    model: Model
    block_bytes: int
    raw_len: int
    model_len: int
    directory_len: int
    payload_len: int
    payload_at: int
    records: tuple[_Record, ...]


def _header_without_crc(
    *,
    variant: int,
    block_bytes: int,
    raw_len: int,
    block_count: int,
    model_len: int,
    directory_len: int,
    payload_len: int,
    model_crc: int,
    directory_crc: int,
) -> bytes:
    return struct.pack(
        HEADER_FMT,
        MAGIC,
        VERSION,
        variant,
        BACKEND_ZLIB_DIAGNOSTIC,
        0,
        block_bytes,
        raw_len,
        block_count,
        model_len,
        directory_len,
        payload_len,
        model_crc,
        directory_crc,
        0,
    )


def encode(model: Model, data: bytes, *, block_bytes: int = 16 * 1024, level: int = 9) -> bytes:
    """Encode ``data`` into independently decodable framed blocks."""

    if not isinstance(model, Model):
        raise TypeError("model must be a Model")
    if not 1 <= block_bytes <= MAX_BLOCK_BYTES:
        raise ValueError("block_bytes must be in 1..65536")
    if not 0 <= level <= 9:
        raise ValueError("zlib level must be in 0..9")
    data = bytes(data)
    model_bytes = model.to_bytes()
    if len(model_bytes) > MAX_MODEL_BYTES:
        raise ValueError("model too large")

    payload = bytearray()
    records: list[_Record] = []
    for start in range(0, len(data), block_bytes):
        raw = data[start : start + block_bytes]
        transformed = _make_transform(model, raw)
        compressed = zlib.compress(transformed, level)
        if len(compressed) < len(transformed):
            mode = 1
            wire = compressed
        else:
            mode = 0
            wire = transformed
        offset = len(payload)
        payload.extend(wire)
        records.append(
            _Record(
                offset=offset,
                wire_len=len(wire),
                raw_len=len(raw),
                transformed_len=len(transformed),
                raw_crc=_crc(raw),
                transformed_crc=_crc(transformed),
                mode=mode,
            )
        )
    if len(records) > MAX_BLOCKS:
        raise ValueError("too many blocks")

    directory = bytearray()
    for record in records:
        directory.extend(
            struct.pack(
                DIR_FMT,
                record.offset,
                record.wire_len,
                record.raw_len,
                record.transformed_len,
                record.raw_crc,
                record.transformed_crc,
                record.mode,
                b"\0\0\0",
            )
        )
    model_crc = _crc(model_bytes)
    directory_crc = _crc(directory)
    prefix = _header_without_crc(
        variant=model.code,
        block_bytes=block_bytes,
        raw_len=len(data),
        block_count=len(records),
        model_len=len(model_bytes),
        directory_len=len(directory),
        payload_len=len(payload),
        model_crc=model_crc,
        directory_crc=directory_crc,
    )
    header_crc = _crc(prefix + model_bytes + directory)
    header = struct.pack(
        HEADER_FMT,
        MAGIC,
        VERSION,
        model.code,
        BACKEND_ZLIB_DIAGNOSTIC,
        0,
        block_bytes,
        len(data),
        len(records),
        len(model_bytes),
        len(directory),
        len(payload),
        model_crc,
        directory_crc,
        header_crc,
    )
    frame = header + model_bytes + bytes(directory) + bytes(payload)
    if len(frame) > MAX_FRAME_BYTES:
        raise ValueError("frame too large")
    return frame


def _parse_frame(frame: bytes, *, max_frame_bytes: int = MAX_FRAME_BYTES) -> _Frame:
    frame = bytes(frame)
    if len(frame) > max_frame_bytes:
        raise FrameError("frame exceeds configured bound")
    if len(frame) < HEADER_SIZE:
        raise FrameError("truncated frame header")
    (
        magic,
        version,
        variant_code,
        backend,
        flags,
        block_bytes,
        raw_len,
        block_count,
        model_len,
        directory_len,
        payload_len,
        model_crc,
        directory_crc,
        header_crc,
    ) = struct.unpack(HEADER_FMT, frame[:HEADER_SIZE])
    if magic != MAGIC:
        raise FrameError("invalid frame magic")
    if version != VERSION:
        raise FrameError("unsupported frame version")
    if backend != BACKEND_ZLIB_DIAGNOSTIC or flags:
        raise FrameError("unsupported backend or flags")
    if variant_code not in _CODE_TO_VARIANT:
        raise FrameError("unknown transform variant")
    if not 1 <= block_bytes <= MAX_BLOCK_BYTES:
        raise FrameError("invalid block size")
    if block_count > MAX_BLOCKS or model_len > MAX_MODEL_BYTES:
        raise FrameError("frame resource limit exceeded")
    expected_blocks = (raw_len + block_bytes - 1) // block_bytes if raw_len else 0
    if block_count != expected_blocks:
        raise FrameError("block count does not match raw length")
    if directory_len != block_count * DIR_SIZE:
        raise FrameError("invalid directory length")
    payload_at = HEADER_SIZE + model_len + directory_len
    if payload_at < HEADER_SIZE or payload_len != len(frame) - payload_at:
        raise FrameError("frame sections out of bounds")
    model_bytes = frame[HEADER_SIZE : HEADER_SIZE + model_len]
    directory = frame[HEADER_SIZE + model_len : payload_at]
    if _crc(model_bytes) != model_crc or _crc(directory) != directory_crc:
        raise FrameError("model or directory checksum mismatch")
    expected_header = _header_without_crc(
        variant=variant_code,
        block_bytes=block_bytes,
        raw_len=raw_len,
        block_count=block_count,
        model_len=model_len,
        directory_len=directory_len,
        payload_len=payload_len,
        model_crc=model_crc,
        directory_crc=directory_crc,
    )
    if _crc(expected_header + model_bytes + directory) != header_crc:
        raise FrameError("header checksum mismatch")
    model = Model.from_bytes(_CODE_TO_VARIANT[variant_code], model_bytes)
    records: list[_Record] = []
    cursor = 0
    raw_cursor = 0
    for at in range(0, directory_len, DIR_SIZE):
        offset, wire_len, block_raw_len, transformed_len, raw_crc, transformed_crc, mode, reserved = struct.unpack(
            DIR_FMT, directory[at : at + DIR_SIZE]
        )
        if reserved != b"\0\0\0" or mode not in (0, 1):
            raise FrameError("invalid directory record")
        expected_raw_len = min(block_bytes, raw_len - raw_cursor)
        if block_raw_len != expected_raw_len or block_raw_len == 0:
            raise FrameError("invalid block raw length")
        if offset != cursor or offset + wire_len > payload_len or transformed_len > max_frame_bytes:
            raise FrameError("non-contiguous or out-of-bounds payload")
        if mode == 0 and wire_len != transformed_len:
            raise FrameError("raw block wire length mismatch")
        if transformed_len == 0:
            raise FrameError("empty transformed block")
        records.append(
            _Record(
                offset=offset,
                wire_len=wire_len,
                raw_len=block_raw_len,
                transformed_len=transformed_len,
                raw_crc=raw_crc,
                transformed_crc=transformed_crc,
                mode=mode,
            )
        )
        cursor += wire_len
        raw_cursor += block_raw_len
    if cursor != payload_len or raw_cursor != raw_len:
        raise FrameError("directory does not cover frame payload")
    return _Frame(
        frame=frame,
        model=model,
        block_bytes=block_bytes,
        raw_len=raw_len,
        model_len=model_len,
        directory_len=directory_len,
        payload_len=payload_len,
        payload_at=payload_at,
        records=tuple(records),
    )


def _decode_record(view: _Frame, index: int) -> bytes:
    if not 0 <= index < len(view.records):
        raise IndexError("block index out of range")
    record = view.records[index]
    wire = view.frame[view.payload_at + record.offset : view.payload_at + record.offset + record.wire_len]
    if len(wire) != record.wire_len:
        raise FrameError("truncated block payload")
    if record.mode == 0:
        transformed = wire
    else:
        decompressor = zlib.decompressobj()
        try:
            transformed = decompressor.decompress(wire, record.transformed_len + 1)
            if len(transformed) > record.transformed_len:
                raise FrameError("decompressed block exceeds declared length")
            transformed += decompressor.flush()
        except zlib.error as exc:
            raise FrameError("invalid zlib payload") from exc
        if (
            not decompressor.eof
            or decompressor.unused_data
            or decompressor.unconsumed_tail
            or len(transformed) != record.transformed_len
        ):
            raise FrameError("non-canonical or truncated zlib payload")
    if len(transformed) != record.transformed_len or _crc(transformed) != record.transformed_crc:
        raise FrameError("transformed block checksum mismatch")
    raw = _parse_transform(view.model, transformed, record.raw_len)
    if len(raw) != record.raw_len or _crc(raw) != record.raw_crc:
        raise FrameError("decoded block checksum mismatch")
    return raw


def decode_block(frame: bytes, index: int, *, max_frame_bytes: int = MAX_FRAME_BYTES) -> bytes:
    """Validate frame metadata and decode exactly one independently addressed block."""

    view = _parse_frame(frame, max_frame_bytes=max_frame_bytes)
    return _decode_record(view, index)


def decode(frame: bytes, *, max_frame_bytes: int = MAX_FRAME_BYTES, max_output_bytes: int | None = None) -> bytes:
    """Decode and checksum every block in a frame."""

    view = _parse_frame(frame, max_frame_bytes=max_frame_bytes)
    if max_output_bytes is not None and view.raw_len > max_output_bytes:
        raise FrameError("decoded output exceeds configured bound")
    output = bytearray()
    for index in range(len(view.records)):
        output.extend(_decode_record(view, index))
    if len(output) != view.raw_len:
        raise FrameError("decoded output length mismatch")
    return bytes(output)


def frame_info(frame: bytes, *, max_frame_bytes: int = MAX_FRAME_BYTES) -> dict:
    """Return complete storage and conservative decode-work accounting."""

    view = _parse_frame(frame, max_frame_bytes=max_frame_bytes)
    compressed_payload = sum(record.wire_len for record in view.records if record.mode == 1)
    raw_payload = sum(record.wire_len for record in view.records if record.mode == 0)
    transform_bytes = sum(record.transformed_len for record in view.records)
    return {
        "variant": view.model.variant,
        "backend": "zlib-diagnostic",
        "block_bytes": view.block_bytes,
        "block_count": len(view.records),
        "raw_bytes": view.raw_len,
        "header_bytes": HEADER_SIZE,
        "model_bytes": view.model_len,
        "directory_bytes": view.directory_len,
        "payload_bytes": view.payload_len,
        "complete_bytes": len(view.frame),
        "compressed_payload_bytes": compressed_payload,
        "raw_fallback_payload_bytes": raw_payload,
        "transformed_bytes": transform_bytes,
        "decode_work_bytes": view.raw_len + transform_bytes,
        "cold_block_metadata_bytes": HEADER_SIZE + view.model_len + view.directory_len,
        "model_training_bytes": view.model.training_bytes,
        "template_count": len(view.model.templates),
        "blocks": tuple(
            {
                "offset": record.offset,
                "wire_bytes": record.wire_len,
                "raw_bytes": record.raw_len,
                "transformed_bytes": record.transformed_len,
                "mode": "zlib" if record.mode else "raw",
            }
            for record in view.records
        ),
    }


__all__ = [
    "FrameError",
    "Model",
    "CLASS_MAP",
    "MAX_BLOCK_BYTES",
    "train",
    "encode",
    "decode",
    "decode_block",
    "frame_info",
]
