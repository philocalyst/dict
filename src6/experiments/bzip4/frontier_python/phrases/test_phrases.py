from __future__ import annotations

import binascii
import hashlib
from pathlib import Path
import random
import struct
import sys
import unittest

if __package__:
    from . import phrases
else:  # Preserve direct execution from this directory.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import phrases


class PhraseCodecTests(unittest.TestCase):
    def roundtrip(self, data: bytes, variant: str = "lex_huff", block: int = 17) -> bytes:
        model = phrases.train(data[: min(len(data), 4096)], variant=variant, max_phrases=128, max_phrase_bytes=32)
        frame = phrases.encode(data, model, block_bytes=block)
        self.assertEqual(phrases.decode(frame), data)
        prepared = phrases.prepare(frame)
        rebuilt = b"".join(prepared.decode_block(i) for i in range(len(prepared.records)))
        self.assertEqual(rebuilt, data)
        for i in range(len(prepared.records)):
            self.assertEqual(phrases.decode_block(frame, i), prepared.decode_block(i))
        return frame

    def test_empty_and_small(self) -> None:
        for data in (b"", b"x", b"\x00\xff", bytes(range(256))):
            for variant in ("lex_huff", "ngram_huff", "lex_fixed", "lex_dp_huff"):
                self.roundtrip(data, variant, block=3)

    def test_unicode_invalid_and_pathological(self) -> None:
        data = ("English 日本語 العربية हिन्दी\n<entry attr='x'>".encode("utf-8") * 40) + b"\xff\xfe\x80" * 100
        for variant in ("lex_huff", "ngram_huff", "lex_fixed", "lex_dp_huff"):
            self.roundtrip(data, variant, block=31)
        self.roundtrip(b"A" * 10000, "lex_huff", block=64)
        rng = random.Random(921)
        self.roundtrip(bytes(rng.randrange(256) for _ in range(12000)), "lex_huff", block=257)

    def test_deterministic(self) -> None:
        data = (b"same words and punctuation <x>\n" * 500) + bytes(range(256))
        m1 = phrases.train(data[:4096], variant="lex_huff", max_phrases=128)
        m2 = phrases.train(data[:4096], variant="lex_huff", max_phrases=128)
        self.assertEqual(m1.serialize(), m2.serialize())
        self.assertEqual(phrases.encode(data, m1, 97), phrases.encode(data, m2, 97))
        dp1 = phrases.train(data[:4096], variant="lex_dp_huff", max_phrases=128)
        dp2 = phrases.train(data[:4096], variant="lex_dp_huff", max_phrases=128)
        self.assertEqual(dp1.serialize(), dp2.serialize())
        self.assertEqual(dp1.options.get("dp_rounds"), 2)
        self.assertEqual(phrases.encode(data, dp1, 97), phrases.encode(data, dp2, 97))

    def test_frame_mutations_and_truncation(self) -> None:
        data = b"abcdef <tag> value\n" * 200
        model = phrases.train(data[:4096], variant="lex_huff", max_phrases=64)
        frame = phrases.encode(data, model, block_bytes=128)
        for cut in (0, 1, 39, 40, len(frame) // 2, len(frame) - 1):
            with self.subTest(cut=cut), self.assertRaises((phrases.FrameError, ValueError, struct.error)):
                phrases.decode(frame[:cut])
        for at in (0, 4, 12, len(frame) - 1):
            mutated = bytearray(frame)
            mutated[at] ^= 0x01
            with self.subTest(at=at), self.assertRaises(phrases.FrameError):
                phrases.decode(bytes(mutated))
        with self.assertRaises(phrases.FrameError):
            phrases.decode(frame + b"\x00")

    def test_noncanonical_extra_payload_padding_rejected(self) -> None:
        data = b"phrase phrase phrase phrase" * 100
        model = phrases.train(data[:4096], variant="lex_huff", max_phrases=32)
        frame = phrases.encode(data, model, block_bytes=64)
        magic, version, variant, hs, target, count, raw_len, model_len, dir_len, crc, reserved = phrases.HEADER.unpack_from(frame)
        self.assertGreater(count, 0)
        directory_start = phrases.HEADER_BYTES + model_len
        last_directory_start = directory_start + (count - 1) * phrases.DIR_BYTES
        first = list(phrases.DIR.unpack_from(frame, last_directory_start))
        # Add one byte to the first coded payload but keep its bit count.  The
        # metadata CRC is resealed so this reaches the canonical-padding check.
        offset, encoded, block_raw, block_crc, bits = first
        body_end = offset + encoded
        if frame[offset] != 1:
            self.skipTest("unexpected raw fallback for tiny test block")
        bad = bytearray(frame[:body_end] + b"\x00" + frame[body_end:])
        first[1] += 1
        bad[last_directory_start : last_directory_start + phrases.DIR_BYTES] = phrases.DIR.pack(*first)
        header_zero = phrases._metadata_header(
            variant_id=variant,
            block_bytes=target,
            block_count=count,
            raw_length=raw_len,
            model_length=model_len,
            directory_length=dir_len,
            metadata_crc=0,
        )
        model_blob = bytes(bad[phrases.HEADER_BYTES : phrases.HEADER_BYTES + model_len])
        directory_blob = bytes(bad[directory_start : directory_start + dir_len])
        new_crc = binascii.crc32(header_zero + model_blob + directory_blob) & 0xFFFFFFFF
        bad[: phrases.HEADER_BYTES] = phrases._metadata_header(
            variant_id=variant,
            block_bytes=target,
            block_count=count,
            raw_length=raw_len,
            model_length=model_len,
            directory_length=dir_len,
            metadata_crc=new_crc,
        )
        with self.assertRaises(phrases.FrameError):
            phrases.decode(bytes(bad))

    def test_directory_bounds_rejected(self) -> None:
        data = b"x" * 500
        model = phrases.train(data[:100], variant="lex_huff")
        frame = bytearray(phrases.encode(data, model, block_bytes=100))
        _, _, variant, target, count, raw_len, model_len, dir_len, _, _ = (None,) * 10
        fields = list(phrases.HEADER.unpack_from(frame))
        model_len = fields[7]
        directory_start = phrases.HEADER_BYTES + model_len
        record = list(phrases.DIR.unpack_from(frame, directory_start))
        record[0] = 0
        frame[directory_start : directory_start + phrases.DIR_BYTES] = phrases.DIR.pack(*record)
        fields[9] = 0
        header_zero = phrases._metadata_header(
            variant_id=fields[2],
            block_bytes=fields[4],
            block_count=fields[5],
            raw_length=fields[6],
            model_length=fields[7],
            directory_length=fields[8],
            metadata_crc=0,
        )
        model_blob = bytes(frame[phrases.HEADER_BYTES : phrases.HEADER_BYTES + fields[7]])
        directory_blob = bytes(frame[directory_start : directory_start + fields[8]])
        fields[9] = binascii.crc32(header_zero + model_blob + directory_blob) & 0xFFFFFFFF
        frame[: phrases.HEADER_BYTES] = phrases._metadata_header(
            variant_id=fields[2],
            block_bytes=fields[4],
            block_count=fields[5],
            raw_length=fields[6],
            model_length=fields[7],
            directory_length=fields[8],
            metadata_crc=fields[9],
        )
        with self.assertRaises(phrases.FrameError):
            phrases.decode(bytes(frame))


if __name__ == "__main__":
    unittest.main()
