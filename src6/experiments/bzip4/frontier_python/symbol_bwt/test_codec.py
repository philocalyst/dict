from __future__ import annotations

import os
import random
import struct
import unittest

from . import codec as _codec
from .codec import (
    DIRECTORY,
    HEADER,
    FrameError,
    decode,
    decode_block,
    encode,
    prepare,
    train,
)


class SymbolBwtCodecTests(unittest.TestCase):
    def make_frame(self, data: bytes, block_bytes: int = 257) -> bytes:
        model = train(
            data,
            block_bytes=block_bytes,
            max_rules=256,
            max_passes=8,
            pair_policy="consistent",
            input_fit=True,
        )
        first = encode(data, model, block_bytes)
        second = encode(data, model, block_bytes)
        self.assertEqual(first, second)
        return first

    def test_empty_small_unicode_random_and_pathological(self) -> None:
        cases = [
            b"",
            b"a",
            b"\x00\xff\x80\x01",
            "日本語 — mixed UTF-8".encode(),
            bytes(range(256)) * 3,
            b"abracadabra " * 1000,
            os.urandom(1300),
        ]
        for data in cases:
            with self.subTest(length=len(data)):
                frame = self.make_frame(data)
                self.assertEqual(decode(frame), data)
                prepared = prepare(frame)
                blocks = [prepared.decode_block(i) for i in range(len(prepared.parsed.records))]
                self.assertEqual(b"".join(blocks), data)

    def test_corrupt_truncated_and_padding_rejected(self) -> None:
        data = (b"dictionary entry <sense>repeat</sense> " * 200) + b"tail"
        frame = self.make_frame(data, block_bytes=512)
        for cut in (0, 1, len(frame) // 2, len(frame) - 1):
            with self.subTest(cut=cut):
                with self.assertRaises(FrameError):
                    decode(frame[:cut])
        # Metadata mutation is rejected by the frame CRC.
        mutated = bytearray(frame)
        mutated[HEADER.size + 1] ^= 0x01
        with self.assertRaises(FrameError):
            decode(bytes(mutated))

        prepared = prepare(frame)
        coded = next(
            (record for record in prepared.parsed.records if frame[prepared.parsed.payload_offset + record.offset] == 1),
            None,
        )
        if coded is None:
            self.skipTest("test data unexpectedly selected raw fallback")
        # Re-sealing only the metadata CRC cannot make an extra body byte
        # valid: strict coded-block parsing requires exact
        # ceil(valid_bits/8), not arbitrary padding bytes.
        index = next(i for i, record in enumerate(prepared.parsed.records) if record is coded)
        payload_start = prepared.parsed.payload_offset + coded.offset
        malformed = bytearray(frame)
        malformed[payload_start : payload_start + coded.encoded_bytes] += b"\x00"
        # Rebuild the directory offset/length and metadata CRC while leaving
        # the event bit count unchanged.  This is intentionally a hostile
        # frame with a valid outer checksum.
        old_header = list(HEADER.unpack_from(malformed))
        old_header[10] += 1  # payload length
        old_header[12] = 0
        directory_at = HEADER.size + old_header[7] + old_header[8]
        directory = bytearray(malformed[directory_at : directory_at + old_header[9]])
        fields = list(DIRECTORY.unpack_from(directory, index * DIRECTORY.size))
        fields[1] += 1
        DIRECTORY.pack_into(directory, index * DIRECTORY.size, *fields)
        # Keep subsequent block offsets coherent if present.
        for later in range(index + 1, old_header[5]):
            later_fields = list(DIRECTORY.unpack_from(directory, later * DIRECTORY.size))
            later_fields[0] += 1
            DIRECTORY.pack_into(directory, later * DIRECTORY.size, *later_fields)
        old_header_bytes = HEADER.pack(*old_header)
        grammar_blob = bytes(malformed[HEADER.size : HEADER.size + old_header[7]])
        event_blob = bytes(malformed[HEADER.size + old_header[7] : directory_at])
        import binascii

        old_header[12] = binascii.crc32(old_header_bytes[:0] + grammar_blob + event_blob + bytes(directory)) & 0xFFFFFFFF
        # Metadata checksum covers a zeroed-CRC header, not the malformed
        # header currently in the buffer.
        old_header[12] = binascii.crc32(
            HEADER.pack(*old_header[:12], 0, old_header[13]) + grammar_blob + event_blob + bytes(directory)
        ) & 0xFFFFFFFF
        rebuilt = HEADER.pack(*old_header) + grammar_blob + event_blob + bytes(directory) + bytes(
            malformed[directory_at + old_header[9] :]
        )
        with self.assertRaises(FrameError):
            decode(rebuilt)

    def test_index_bounds_and_block_decode(self) -> None:
        data = bytes(range(251)) * 20
        frame = self.make_frame(data, block_bytes=251)
        prepared = prepare(frame)
        with self.assertRaises(FrameError):
            prepared.decode_block(-1)
        with self.assertRaises(FrameError):
            prepared.decode_block(len(prepared.parsed.records))
        for index in range(len(prepared.parsed.records)):
            self.assertEqual(decode_block(frame, index), data[index * 251 : (index + 1) * 251])

    def test_encode_block_count_bound(self) -> None:
        model = train(b"ab", block_bytes=1, max_rules=8, max_passes=2, input_fit=True)
        old_limit = _codec.MAX_BLOCKS
        try:
            _codec.MAX_BLOCKS = 1
            with self.assertRaises(FrameError):
                encode(b"ab", model, block_bytes=1)
        finally:
            _codec.MAX_BLOCKS = old_limit

    def test_declared_model_lengths_are_bounded_before_slicing(self) -> None:
        frame = self.make_frame(b"bounded metadata " * 100, block_bytes=128)
        fields = list(HEADER.unpack_from(frame))
        fields[7] = _codec._grammar.MAX_MODEL_BYTES + 1
        with self.assertRaises(FrameError):
            decode(HEADER.pack(*fields) + frame[HEADER.size:])
        fields = list(HEADER.unpack_from(frame))
        fields[8] = HEADER.size + _codec._grammar.MAX_RULES + 257
        with self.assertRaises(FrameError):
            decode(HEADER.pack(*fields) + frame[HEADER.size:])


if __name__ == "__main__":
    unittest.main()
