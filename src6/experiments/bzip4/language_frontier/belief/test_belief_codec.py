#!/usr/bin/env python3
"""Protocol and safety tests for the compiled latent-belief frame."""

from __future__ import annotations

import struct
import unittest
import zlib

from belief_codec import (
    EOS,
    FrameError,
    compile_model,
    compiled_cross_entropy,
    decode_frame,
    encode_frame,
    train_hmm,
)


class BeliefCodecTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.train = (b"alpha beta gamma delta\n" * 512) + bytes(range(256))
        cls.hmm = train_hmm(cls.train, 4, iterations=3)
        cls.compiled = compile_model(cls.hmm, cls.train, 4, "observed")

    def test_round_trip_empty_and_arbitrary_bytes(self) -> None:
        source = b"\x00\xff\xfe\xc3\x28\x00\n\r\t" + bytes(range(256)) + "A\u0301\u65e5".encode("utf-8")
        for payload in (b"", source, source * 20):
            frame, stats = encode_frame(payload, self.compiled, restart_interval=97)
            self.assertEqual(decode_frame(frame), payload)
            self.assertEqual(stats.output, len(payload))

    def test_state_rows_are_fully_integer_and_causal(self) -> None:
        self.assertEqual(self.compiled.cdf[0][-1], 1 << 14)
        self.assertEqual(len(self.compiled.next_state[0]), 257)
        state = 0
        for symbol in list(b"alpha") + [EOS]:
            self.assertGreaterEqual(self.compiled.cdf[state][symbol + 1] - self.compiled.cdf[state][symbol], 1)
            state = self.compiled.next_state[state][symbol]

    def test_truncated_and_corrupt_frames_reject(self) -> None:
        frame, _ = encode_frame(bytes(range(256)) * 3, self.compiled, restart_interval=41)
        for bad in (frame[:-1], frame[:-9], frame[:40] + bytes([frame[40] ^ 1]) + frame[41:]):
            with self.assertRaises(FrameError):
                decode_frame(bad)

    @staticmethod
    def _with_crc_mutation(frame: bytes, offset: int, value: bytes) -> bytes:
        mutated = bytearray(frame)
        mutated[offset : offset + len(value)] = value
        mutated[-4:] = struct.pack("<I", zlib.crc32(mutated[:-4]) & 0xFFFFFFFF)
        return bytes(mutated)

    def test_checked_tables_reject_even_with_valid_checksum(self) -> None:
        frame, _ = encode_frame(bytes(range(256)) * 3, self.compiled, restart_interval=41)
        fixed = 26
        cdf_bad = self._with_crc_mutation(frame, fixed, struct.pack("<H", 1))
        with self.assertRaises(FrameError):
            decode_frame(cdf_bad)
        next_at = fixed + self.compiled.states * (257 + 1) * 2
        next_bad = self._with_crc_mutation(frame, next_at, struct.pack("<H", 65535))
        with self.assertRaises(FrameError):
            decode_frame(next_bad)
        restart_at = next_at + self.compiled.states * 257 * 2
        restart_bad = self._with_crc_mutation(frame, restart_at, struct.pack("<I", 1))
        with self.assertRaises(FrameError):
            decode_frame(restart_bad)

    def test_checked_output_budget_rejects_even_with_valid_checksum(self) -> None:
        frame, _ = encode_frame(b"safe", self.compiled)
        output_length_at = 16
        budget_bad = self._with_crc_mutation(frame, output_length_at, struct.pack("<I", (1 << 26) + 1))
        with self.assertRaises(FrameError):
            decode_frame(budget_bad)

    def test_compiled_cross_entropy_is_finite(self) -> None:
        value = compiled_cross_entropy(self.compiled, b"alpha beta")
        self.assertTrue(value > 0.0)


if __name__ == "__main__":
    unittest.main()
