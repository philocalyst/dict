"""Complete restartable framing shared by the native control and workers.

The frame is deliberately boring and fixed-width:

* 32-byte little-endian header;
* one 16-byte directory record per independent block;
* the actual native block bytes concatenated after the directory.

The directory stores a payload-relative offset, encoded length, raw length,
and CRC-32 of the decoded block.  The native bzip3 block also carries its own
checksum; the directory checksum makes the Python control's framing and
random-block checks explicit rather than trusting a successful C return alone.
"""

from __future__ import annotations

from dataclasses import dataclass
import struct
import zlib


MAGIC = b"B3PY"
VERSION = 1
HEADER_BYTES = 32
RECORD_BYTES = 16
MAX_BLOCKS = 1_000_000
HEADER = struct.Struct("<4sBBHIIIIII")
# Four u32 fields fit the frozen 16-byte restart record: payload-relative
# offset, encoded length, raw length, and decoded CRC-32.
RECORD = struct.Struct("<IIII")


class FrameError(ValueError):
    pass


@dataclass(frozen=True)
class BlockRecord:
    payload_offset: int
    encoded_bytes: int
    raw_bytes: int
    crc32: int


@dataclass(frozen=True)
class Bzip3Frame:
    """A validated view over a complete framed byte string."""

    wire: bytes
    raw_bytes: int
    block_bytes: int
    records: tuple[BlockRecord, ...]
    payload_offset: int
    payload_bytes: int

    @property
    def block_count(self) -> int:
        return len(self.records)

    def block_encoded(self, index: int) -> bytes:
        if index < 0 or index >= len(self.records):
            raise FrameError("block index out of range")
        record = self.records[index]
        start = self.payload_offset + record.payload_offset
        return self.wire[start : start + record.encoded_bytes]

    def block_record(self, index: int) -> BlockRecord:
        if index < 0 or index >= len(self.records):
            raise FrameError("block index out of range")
        return self.records[index]


def _metadata_crc(header_without_crc: bytes, directory: bytes) -> int:
    return zlib.crc32(header_without_crc + directory) & 0xFFFFFFFF


def frame_blocks(blocks: list[bytes] | tuple[bytes, ...], raw_blocks: list[bytes] | tuple[bytes, ...], block_bytes: int) -> bytes:
    """Build a complete control frame from native block bytes.

    ``raw_blocks`` is supplied by the caller so the directory's lengths and
    checksums are based on the exact bytes that were fed to bzip3.  It is not
    retained after framing.
    """

    if len(blocks) != len(raw_blocks):
        raise FrameError("encoded/raw block count mismatch")
    if block_bytes <= 0 or block_bytes > 0xFFFFFFFF:
        raise FrameError(f"invalid block size {block_bytes}")
    if len(blocks) > MAX_BLOCKS:
        raise FrameError("too many blocks")
    raw_total = sum(len(block) for block in raw_blocks)
    payload_total = sum(len(block) for block in blocks)
    if raw_total > 0xFFFFFFFF or payload_total > 0xFFFFFFFF:
        raise FrameError("frame lengths exceed protocol u32 fields")

    directory = bytearray(len(blocks) * RECORD_BYTES)
    if len(directory) > 0xFFFFFFFF:
        raise FrameError("directory exceeds u32 length")
    offset = 0
    for index, (encoded, raw) in enumerate(zip(blocks, raw_blocks)):
        if not raw or len(raw) > block_bytes:
            raise FrameError(f"invalid raw block length at index {index}: {len(raw)}")
        if len(encoded) == 0:
            raise FrameError(f"empty encoded block at index {index}")
        if len(encoded) > 0xFFFFFFFF:
            raise FrameError("encoded block exceeds u32 length")
        if offset > 0xFFFFFFFF:
            raise FrameError("payload offset exceeds u32 restart record")
        RECORD.pack_into(directory, index * RECORD_BYTES, offset, len(encoded), len(raw), zlib.crc32(raw) & 0xFFFFFFFF)
        offset += len(encoded)

    payload_at = HEADER_BYTES + len(directory)
    header_without_crc = HEADER.pack(
        MAGIC,
        VERSION,
        0,
        HEADER_BYTES,
        raw_total,
        block_bytes,
        len(blocks),
        len(directory),
        payload_total,
        0,
    )
    metadata_crc = _metadata_crc(header_without_crc[:28], bytes(directory))
    header = HEADER.pack(
        MAGIC,
        VERSION,
        0,
        HEADER_BYTES,
        raw_total,
        block_bytes,
        len(blocks),
        len(directory),
        payload_total,
        metadata_crc,
    )
    return header + bytes(directory) + b"".join(blocks)


def open_frame(wire: bytes, *, max_raw_bytes: int = 512 * 1024 * 1024, max_frame_bytes: int = 512 * 1024 * 1024) -> Bzip3Frame:
    """Validate all fixed metadata and return a frame view over immutable bytes."""

    if not isinstance(wire, (bytes, bytearray, memoryview)):
        raise FrameError("frame must be bytes-like")
    wire = bytes(wire)
    if len(wire) < HEADER_BYTES:
        raise FrameError("truncated frame header")
    if len(wire) > max_frame_bytes:
        raise FrameError("frame exceeds configured limit")
    magic, version, flags, header_size, raw_total, block_bytes, count, directory_bytes, payload_bytes, metadata_crc = HEADER.unpack_from(wire)
    if magic != MAGIC:
        raise FrameError(f"invalid frame magic {magic!r}")
    if version != VERSION:
        raise FrameError(f"unsupported frame version {version}")
    if flags != 0 or header_size != HEADER_BYTES:
        raise FrameError("invalid frame flags or header size")
    if block_bytes == 0:
        raise FrameError("zero block size")
    if count > MAX_BLOCKS:
        raise FrameError("too many blocks")
    if raw_total > max_raw_bytes:
        raise FrameError("frame raw bytes exceed configured limit")
    if directory_bytes != count * RECORD_BYTES:
        raise FrameError("directory length does not match block count")
    payload_at = HEADER_BYTES + directory_bytes
    if payload_at > len(wire) or payload_bytes != len(wire) - payload_at:
        raise FrameError("payload length or trailing bytes mismatch")
    directory = wire[HEADER_BYTES:payload_at]
    if metadata_crc != _metadata_crc(wire[:28], directory):
        raise FrameError("metadata CRC mismatch")

    records: list[BlockRecord] = []
    expected_offset = 0
    raw_sum = 0
    for index in range(count):
        offset, encoded_len, raw_len, crc32 = RECORD.unpack_from(directory, index * RECORD_BYTES)
        if offset != expected_offset:
            raise FrameError(f"non-contiguous payload offset at block {index}")
        if encoded_len == 0 or offset + encoded_len > payload_bytes:
            raise FrameError(f"encoded block {index} is outside payload")
        if raw_len == 0 or raw_len > block_bytes:
            raise FrameError(f"invalid raw length at block {index}")
        if index + 1 < count and raw_len != block_bytes:
            raise FrameError(f"non-final block {index} has short raw length")
        expected_offset += encoded_len
        raw_sum += raw_len
        if raw_sum > max_raw_bytes:
            raise FrameError("raw block lengths exceed configured limit")
        records.append(BlockRecord(offset, encoded_len, raw_len, crc32))
    if expected_offset != payload_bytes:
        raise FrameError("directory does not cover complete payload")
    if raw_sum != raw_total:
        raise FrameError("directory raw lengths do not match header")
    expected_count = 0 if raw_total == 0 else (raw_total - 1) // block_bytes + 1
    if expected_count != count:
        raise FrameError("block count does not match raw length and boundary")
    return Bzip3Frame(wire, raw_total, block_bytes, tuple(records), payload_at, payload_bytes)


def block_crc32(raw: bytes) -> int:
    return zlib.crc32(raw) & 0xFFFFFFFF


__all__ = [
    "MAGIC",
    "VERSION",
    "HEADER_BYTES",
    "RECORD_BYTES",
    "MAX_BLOCKS",
    "FrameError",
    "BlockRecord",
    "Bzip3Frame",
    "frame_blocks",
    "open_frame",
    "block_crc32",
]
