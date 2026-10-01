"""Small, adversarial review oracles for the isolated ``bwt_context`` codec.

These tests intentionally reach the reference codec's private wire helpers.  A
review of a self-describing format needs to distinguish a malformed field that
is rejected by its own bound from a random payload bit that merely trips the
directory CRC.  The tests therefore build a few minimal, correctly resealed
frames and exercise the independent BWT oracle, entropy state, MTF mask, and
factor parser separately.
"""

from __future__ import annotations

import itertools
import random
import struct
import sys
from dataclasses import replace
from pathlib import Path
import unittest


HERE = Path(__file__).resolve().parent
FRONTIER = HERE.parent
if str(FRONTIER) not in sys.path:
    sys.path.insert(0, str(FRONTIER))

from bwt_context import codec  # noqa: E402


def _reseal(frame: bytes) -> bytes:
    """Recompute only the format's metadata checksum after a metadata edit."""

    fields = codec._HEADER.unpack_from(frame)
    model_length = fields[8]
    directory_length = fields[9]
    payload_at = codec.HEADER_SIZE + model_length + directory_length
    result = bytearray(frame)
    checksum = codec._crc32(bytes(result[:36]) + bytes(result[40:payload_at]))
    struct.pack_into("<I", result, 36, checksum)
    return bytes(result)


def _frame_with_block(raw: bytes, model: codec.Model, block: bytes, *, checksum: int | None = None) -> bytes:
    """Build a one-block frame around an explicitly constructed coded block."""

    model_wire = model.wire()
    directory_wire = codec._DIRECTORY.pack(0, len(block), len(raw), codec._crc32(raw) if checksum is None else checksum)
    head_without_checksum = codec._HEADER.pack(
        codec.MAGIC,
        codec.VERSION,
        model.variant,
        0,
        codec.HEADER_SIZE,
        len(raw),
        1,
        len(raw),
        len(model_wire),
        len(directory_wire),
        len(block),
        0,
    )[:36]
    metadata_checksum = codec._crc32(head_without_checksum + model_wire + directory_wire)
    header = codec._HEADER.pack(
        codec.MAGIC,
        codec.VERSION,
        model.variant,
        0,
        codec.HEADER_SIZE,
        len(raw),
        1,
        len(raw),
        len(model_wire),
        len(directory_wire),
        len(block),
        metadata_checksum,
    )
    return header + model_wire + directory_wire + block


def _coded_block(source: bytes, model: codec.Model, *, flags: int = 0, table_offset: int = 0) -> bytes:
    last, primary = codec._bwt_transform(source)
    tokens, mask = codec._mtf_tokens(last)
    entropy = codec._rans_encode(tokens, model, table_offset=table_offset)
    return codec._BLOCK.pack(1, primary, len(source), len(tokens), 0, flags) + mask + entropy


def _naive_bwt(data: bytes) -> tuple[bytes, int]:
    rotations = sorted(range(len(data)), key=lambda index: (data[index:] + data[:index], index))
    return bytes(data[(index - 1) % len(data)] for index in rotations), rotations.index(0)


class BWTReviewTests(unittest.TestCase):
    def test_bwt_matches_independent_rotation_oracle(self) -> None:
        for length in range(1, 10):
            for values in itertools.product(range(2), repeat=length):
                raw = bytes(values)
                expected_last, expected_primary = _naive_bwt(raw)
                last, primary = codec._bwt_transform(raw)
                self.assertEqual((last, primary), (expected_last, expected_primary))
                self.assertEqual(codec._inverse_bwt(last, primary), raw)

        rng = random.Random(0xB4C)
        for length in range(1, 80):
            raw = bytes(rng.randrange(7) for _ in range(length))
            last, primary = codec._bwt_transform(raw)
            self.assertEqual((last, primary), _naive_bwt(raw))
            self.assertEqual(codec._inverse_bwt(last, primary), raw)

    def test_resealed_c_zero_factor_fields_are_rejected_after_repair(self) -> None:
        raw = b"long repeatable sequence " * 200
        model = codec.train(raw, "C", 128)
        frame = codec.encode(raw, model, 128)
        model_at = codec.HEADER_SIZE

        zero_window = bytearray(frame)
        zero_window[model_at + 8 : model_at + 10] = b"\0\0"
        with self.assertRaises(codec.CodecError):
            codec.decode(_reseal(bytes(zero_window)))

        zero_minimum = bytearray(frame)
        zero_minimum[model_at + 10] = 0
        with self.assertRaises(codec.CodecError):
            codec.decode(_reseal(bytes(zero_minimum)))

    def test_model_constructor_rejects_values_that_wire_cannot_pack(self) -> None:
        training = b"factorized text " * 100
        c_model = codec.train(training, "C", 128)
        d_model = codec.train(training, "D", 128)
        with self.assertRaises(codec.CodecError):
            replace(c_model, factor_window=codec.MAX_BLOCK_BYTES)
        with self.assertRaises(codec.CodecError):
            replace(d_model, segment_bytes=codec.MAX_BLOCK_BYTES)
        with self.assertRaises(codec.CodecError):
            replace(c_model, factor_min_match=256)

    def test_resealed_mask_with_unused_symbol_is_rejected_after_repair(self) -> None:
        raw = b"abcd" * 1000
        model = codec.train(raw, "A", 512)
        last, primary = codec._bwt_transform(raw)
        tokens, mask = codec._mtf_tokens(last)
        alphabet = codec._alphabet_from_mask(mask)
        extra = next(symbol for symbol in range(max(alphabet) + 1, 256) if symbol not in alphabet)
        expanded_mask = bytearray(mask)
        expanded_mask[extra >> 3] |= 1 << (extra & 7)
        self.assertEqual(tokens[-1], len(alphabet) + 1)
        # Appending an unused symbol preserves every MTF rank; only EOB moves
        # one slot because it is defined as alphabet_size + 1.
        expanded_tokens = tokens[:-1] + (tokens[-1] + 1,)
        entropy = codec._rans_encode(expanded_tokens, model)
        block = codec._BLOCK.pack(1, primary, len(raw), len(expanded_tokens), 0, 0)
        block += bytes(expanded_mask) + entropy
        frame = _frame_with_block(raw, model, block)
        with self.assertRaises(codec.CodecError):
            codec.decode(frame)

    def test_resealed_block_bounds_reject_before_crc(self) -> None:
        raw = b"abcd" * 1000
        model = codec.train(raw, "A", 512)
        block = _coded_block(raw, model)
        frame = _frame_with_block(raw, model, block)
        payload_at = codec.HEADER_SIZE + len(model.wire()) + codec.DIRECTORY_RECORD_SIZE

        bad_primary = bytearray(frame)
        struct.pack_into("<I", bad_primary, payload_at + 1, len(raw))
        with self.assertRaises(codec.CodecError):
            codec.decode(bytes(bad_primary))

        bad_token_length = bytearray(frame)
        struct.pack_into("<I", bad_token_length, payload_at + 9, len(raw) * 2 + 17)
        with self.assertRaises(codec.CodecError):
            codec.decode(bytes(bad_token_length))

        bad_mask = bytearray(frame)
        bad_mask[payload_at + codec._BLOCK.size : payload_at + codec._BLOCK.size + 32] = b"\0" * 32
        with self.assertRaises(codec.CodecError):
            codec.decode(bytes(bad_mask))

        # The first four bytes after the mask are the rANS state.  This is a
        # direct entropy-state violation, not a directory CRC mutation.
        bad_state = bytearray(frame)
        entropy_at = payload_at + codec._BLOCK.size + 32
        struct.pack_into("<I", bad_state, entropy_at, codec.RANS_LOWER_BOUND - 1)
        with self.assertRaises(codec.CodecError):
            codec.decode(bytes(bad_state))

    def test_malformed_factor_stream_is_rejected_by_factor_parser(self) -> None:
        raw = b"x"
        model = codec.train(b"factorized text " * 100, "C", 128)
        malformed_source = b"\xff"  # marker without its operation byte
        block = _coded_block(malformed_source, model, flags=1)
        frame = _frame_with_block(raw, model, block, checksum=codec._crc32(raw))
        with self.assertRaises(codec.CodecError):
            codec.decode(frame)

        with self.assertRaises(codec.CodecError):
            codec._factor_decode(b"\xff", 1)
        with self.assertRaises(codec.CodecError):
            codec._factor_decode(b"\xff\x02", 1)
        with self.assertRaises(codec.CodecError):
            codec._factor_decode(b"\xff\x01\x01\x00", 40)

    def test_e_wire_charges_two_tables_and_representation_flags(self) -> None:
        raw = b"abcd" * 1000 + b"a" * 5000 + bytes(range(256)) * 20
        model = codec.train(raw, "E", 1024)
        frame = codec.encode(raw, model, 1024)
        prepared = codec.prepare(frame)
        self.assertEqual(model.table_count, 2)
        self.assertEqual(len(model.wire()), 1044)
        flags: set[int] = set()
        payload_at = codec.HEADER_SIZE + len(model.wire()) + len(prepared.frame.directory) * codec.DIRECTORY_RECORD_SIZE
        for entry in prepared.frame.directory:
            encoded = frame[payload_at + entry.offset : payload_at + entry.offset + entry.encoded_length]
            if encoded[0] == 1:
                flags.add(codec._BLOCK.unpack_from(encoded)[-1])
        self.assertEqual(flags, {0, 1})
        self.assertEqual(codec.decode(frame), raw)

    def test_f_sparse_conditioning_is_bounded_and_lossless(self) -> None:
        model = codec.train(b"abcde" * 500, "F", 256)
        raw = bytes(range(256)) * 16
        frame = codec.encode(raw, model, 4096)
        prepared = codec.prepare(frame)
        self.assertEqual(codec.decode(frame), raw)
        self.assertGreaterEqual(prepared.dynamic_table_cache_bytes, 256 * 8000)
        # Conditioning a full 256-byte alphabet has no unreachable event IDs;
        # it must therefore be the original positive model, not a second unit
        # prior layered on top of it.
        self.assertEqual(codec._conditioned_frequencies(model.tables[0], 256), model.tables[0])
        derived = codec._conditioned_model(model, 1)
        self.assertTrue(derived.sparse)
        self.assertEqual(sum(derived.tables[0]), codec.PROB_TOTAL)
        self.assertTrue(all(value == 0 for value in derived.tables[0][3:]))


if __name__ == "__main__":
    unittest.main()
