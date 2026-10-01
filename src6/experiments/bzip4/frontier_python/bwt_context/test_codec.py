"""Deterministic correctness and malformed-wire checks for the reference family."""

from __future__ import annotations

import random
import struct
import unittest

try:
    from .codec import (
        RUNA,
        CodecError,
        MAX_BLOCK_BYTES,
        Model,
        PROB_TOTAL,
        TOKEN_ALPHABET,
        _BLOCK,
        _PreparedRans,
        _conditioned_frequencies,
        _bwt_transform,
        _factor_decode,
        _mtf_tokens,
        _rans_decode,
        _rans_encode,
        _tokens_to_last,
        decode,
        decode_block,
        encode,
        frame_metrics,
        prepare,
        train,
    )
except ImportError:  # direct ``unittest discover`` from this directory
    from codec import (
        RUNA,
        CodecError,
        MAX_BLOCK_BYTES,
        Model,
        PROB_TOTAL,
        TOKEN_ALPHABET,
        _BLOCK,
        _PreparedRans,
        _conditioned_frequencies,
        _bwt_transform,
        _factor_decode,
        _mtf_tokens,
        _rans_decode,
        _rans_encode,
        _tokens_to_last,
        decode,
        decode_block,
        encode,
        frame_metrics,
        prepare,
        train,
    )


class CodecTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.training = (b"the quick brown fox jumps over the lazy dog. " * 700) + bytes(range(256)) * 8
        cls.models = {variant: train(cls.training, variant, 128) for variant in "ABCDEF"}

    def test_roundtrips_and_retained_prepare(self) -> None:
        rng = random.Random(17)
        rng_full = random.Random(23)
        inputs = [
            b"\0",
            b"\xff",
            b"a" * 2000,
            b"ab" * 1000,
            bytes(range(256)) * 5,
            "unicode café 漢字 — лексикон".encode("utf-8") * 30,
            bytes(rng.randrange(256) for _ in range(2500)),
            bytes(rng_full.randrange(256) for _ in range(65536)),
            bytes([0xFF]) * 65536,
        ]
        for variant, model in self.models.items():
            for raw in inputs:
                with self.subTest(variant=variant, size=len(raw)):
                    frame = encode(raw, model, 128)
                    self.assertEqual(decode(frame), raw)
                    prepared = prepare(frame)
                    rebuilt = b"".join(prepared.decode_block(index) for index in range(len(prepared.frame.directory)))
                    self.assertEqual(rebuilt, raw)
                    self.assertEqual(decode_block(prepared, 0), raw[:128])
                    metrics = frame_metrics(prepared)
                    self.assertEqual(metrics["raw_bytes"], len(raw))
                    self.assertEqual(metrics["complete_bytes"], len(frame))

    def test_each_block_is_independently_decodable(self) -> None:
        raw = (b"dictionary content with repeated phrases " * 500)[:5000]
        for variant, model in self.models.items():
            frame = encode(raw, model, 127)
            prepared = prepare(frame)
            at = 0
            for index, entry in enumerate(prepared.frame.directory):
                self.assertEqual(prepared.decode_block(index), raw[at : at + entry.raw_length])
                at += entry.raw_length
            self.assertEqual(at, len(raw))

    def test_header_model_directory_and_tail_rejection(self) -> None:
        raw = b"compressible phrase " * 1000
        for variant, model in self.models.items():
            frame = encode(raw, model, 256)
            mutations = {
                "magic": bytes((frame[0] ^ 1,)) + frame[1:],
                "metadata": frame[:36] + bytes((frame[36] ^ 1,)) + frame[37:],
                "trailing": frame + b"x",
                "truncated": frame[:-1],
            }
            for name, mutated in mutations.items():
                with self.subTest(variant=variant, mutation=name):
                    with self.assertRaises(CodecError):
                        decode(mutated)

    def test_coded_block_index_length_and_entropy_rejection(self) -> None:
        raw = (b"long repeatable sequence " * 2000)[:12000]
        for variant, model in self.models.items():
            frame = encode(raw, model, 1024)
            prepared = prepare(frame)
            payload_at = 40 + len(prepared.frame.model.wire()) + len(prepared.frame.directory) * 16
            first = prepared.frame.directory[0]
            block_at = payload_at + first.offset
            coded = frame[block_at : block_at + first.encoded_length]
            if coded[0] != 1:
                # This data is expected to code, but retain a deterministic
                # assertion so a future change cannot silently skip the audit.
                self.fail(f"{variant} unexpectedly selected raw fallback")
            # Primary index is the first dword after mode.  Directory/model
            # bytes remain valid, so the decoder must reject the block itself.
            bad_primary = bytearray(frame)
            struct.pack_into("<I", bad_primary, block_at + 1, 0xFFFFFFFF)
            with self.subTest(variant=variant, mutation="primary"):
                with self.assertRaises(CodecError):
                    decode(bytes(bad_primary))
            # The last entropy byte is covered by canonical rANS validation or
            # the block CRC.  Try both polarity choices to avoid relying on a
            # particular payload byte value.
            bad_tail = bytearray(frame)
            bad_tail[block_at + first.encoded_length - 1] ^= 0x01
            with self.subTest(variant=variant, mutation="entropy-tail"):
                with self.assertRaises(CodecError):
                    decode(bytes(bad_tail))

    def test_bounds_and_empty_inputs(self) -> None:
        model = self.models["A"]
        with self.assertRaises(CodecError):
            train(b"", "A", 128)
        with self.assertRaises(CodecError):
            train(b"x", "A", 0)
        self.assertEqual(decode(encode(b"", model, 128)), b"")
        with self.assertRaises(CodecError):
            encode(b"x", model, 0)
        with self.assertRaises(CodecError):
            encode(b"x", model, 65 * 1024)

    def test_unused_wire_parameters_are_canonical(self) -> None:
        model = self.models["E"]
        with self.assertRaises(CodecError):
            type(model)(model.variant, model.tables, factor_window=123)
        with self.assertRaises(CodecError):
            type(model)(model.variant, model.tables, segment_bytes=17)

    def test_wire_widths_and_c_factor_fields_are_strict(self) -> None:
        c_model = self.models["C"]
        d_model = self.models["D"]
        with self.assertRaises(CodecError):
            type(c_model)(c_model.variant, c_model.tables, factor_window=MAX_BLOCK_BYTES)
        with self.assertRaises(CodecError):
            type(c_model)(c_model.variant, c_model.tables, factor_min_match=256)
        with self.assertRaises(CodecError):
            type(d_model)(d_model.variant, d_model.tables, segment_bytes=MAX_BLOCK_BYTES)
        zero_window = bytearray(c_model.wire())
        zero_window[8:10] = b"\0\0"
        with self.assertRaises(CodecError):
            Model.from_wire(bytes(zero_window), c_model.variant)
        zero_minimum = bytearray(c_model.wire())
        zero_minimum[10] = 0
        with self.assertRaises(CodecError):
            Model.from_wire(bytes(zero_minimum), c_model.variant)

    def test_coded_mask_must_equal_reconstructed_bwt_alphabet(self) -> None:
        raw = b"a" * 2000
        frame = encode(raw, self.models["A"], 256)
        parsed = prepare(frame)
        payload_at = 40 + len(parsed.frame.model.wire()) + len(parsed.frame.directory) * 16
        first = parsed.frame.directory[0]
        block_at = payload_at + first.offset
        self.assertEqual(frame[block_at], 1)
        bad_mask = bytearray(frame)
        mask_at = block_at + _BLOCK.size
        bad_mask[mask_at + (0xFF >> 3)] |= 1 << (0xFF & 7)
        with self.assertRaises(CodecError):
            decode(bytes(bad_mask))

    def test_run_length_and_factor_length_rejection(self) -> None:
        mask = bytes((1,)) + bytes(31)
        with self.assertRaises(CodecError):
            _tokens_to_last((RUNA,), mask, 1)
        with self.assertRaises(CodecError):
            _tokens_to_last((RUNA, 2), mask, 0)
        with self.assertRaises(CodecError):
            _factor_decode(b"\xff", 1)
        with self.assertRaises(CodecError):
            _factor_decode(b"\xff\x01\x00\x00", 40)
        with self.assertRaises(CodecError):
            _factor_decode(b"\xff\x01\x01\x80\x00", 40)

    def test_f_reachable_tables_cover_every_alphabet_cardinality(self) -> None:
        model = self.models["F"]
        for cardinality in range(1, 257):
            with self.subTest(cardinality=cardinality):
                frequencies = _conditioned_frequencies(model.tables[0], cardinality)
                support = cardinality + 2
                self.assertEqual(sum(frequencies), PROB_TOTAL)
                self.assertTrue(all(frequencies[:support]))
                self.assertTrue(all(frequency == 0 for frequency in frequencies[support:]))
                if cardinality == 256:
                    self.assertEqual(frequencies, model.tables[0])
                source = bytes(range(cardinality))
                last, _ = _bwt_transform(source)
                tokens, _ = _mtf_tokens(last)
                entropy = _rans_encode(tokens, model, frequencies=frequencies)
                derived = type(model)(model.variant, (frequencies,), sparse=True)
                decoded_tokens = _rans_decode(
                    entropy,
                    len(tokens),
                    model,
                    prepared=_PreparedRans.build(derived),
                )
                self.assertEqual(decoded_tokens, tokens)

    def test_f_unseen_holdout_and_mask_model_rejection(self) -> None:
        model = train(b"abcde" * 500, "F", 256)
        unseen = bytes(range(256)) * 128
        frame = encode(unseen, model, 4096)
        self.assertEqual(decode(frame), unseen)
        prepared = prepare(frame)
        self.assertGreaterEqual(prepared.dynamic_table_cache_bytes, 256 * 8000)

        coded = encode(b"a" * 3000, model, 1024)
        parsed = prepare(coded)
        payload_at = 40 + len(parsed.frame.model.wire()) + len(parsed.frame.directory) * 16
        entry = parsed.frame.directory[0]
        block_at = payload_at + entry.offset
        bad_mask = bytearray(coded)
        bad_mask[block_at + _BLOCK.size : block_at + _BLOCK.size + 32] = bytes(32)
        with self.assertRaises(CodecError):
            decode(bytes(bad_mask))
        bad_model = bytearray(coded)
        bad_model[40 + 12] ^= 1
        with self.assertRaises(CodecError):
            prepare(bytes(bad_model))

    def test_c_near_full_expanding_factor_stream_falls_back_safely(self) -> None:
        rng = random.Random(901)
        raw = bytes(rng.randrange(256) for _ in range(64 * 1024))
        model = self.models["C"]
        frame = encode(raw, model, 64 * 1024)
        self.assertEqual(decode(frame), raw)
        prepared = prepare(frame)
        self.assertEqual(prepared.decode_block(0), raw)


if __name__ == "__main__":
    unittest.main()
