"""Independent public-API oracle; deliberately does not reuse worker tests."""

from pathlib import Path
import bisect
import random
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from bwt_context import codec as bwt


class BwtIndependentAudit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        rng = random.Random(912673)
        cls.training = (
            b"shared fragments across unrelated dictionary entries; " * 32
            + bytes(range(256)) * 4
            + rng.randbytes(2048)
        )
        cls.models = {v: bwt.train(cls.training, v, 512) for v in "ABCDEF"}

    def test_conditioning_is_identity_when_nothing_is_excluded(self):
        original = self.models["F"].tables[0]
        self.assertEqual(bwt._conditioned_frequencies(original, 256), original)
        for alphabet_count in range(1, 257):
            table = bwt._conditioned_frequencies(original, alphabet_count)
            self.assertEqual(sum(table), 4096)
            self.assertTrue(all(value > 0 for value in table[:alphabet_count + 2]))
            self.assertTrue(all(value == 0 for value in table[alphabet_count + 2:]))

    def test_rotation_sort_against_naive_definition(self):
        rng = random.Random(40271)
        for length in range(1, 65):
            for alphabet in (1, 2, 7, 256):
                data = bytes(rng.randrange(alphabet) for _ in range(length))
                last, primary = bwt._bwt_transform(data)
                rotations = sorted(data[i:] + data[:i] for i in range(length))
                self.assertEqual(last, bytes(row[-1] for row in rotations))
                # Periodic inputs can have several equal original rotations;
                # do not incorrectly demand a particular equal-key primary.
                self.assertEqual(rotations[primary], data)
                self.assertEqual(bwt._inverse_bwt(last, primary), data)

    def test_entropy_against_scalar_interval_decoder(self):
        # This oracle searches cumulative intervals and never uses the worker's
        # slot table, CDF helper, or decoder. It checks both E table offsets.
        rng = random.Random(71291)
        for variant in ("A", "E"):
            model = self.models[variant]
            for table_index, frequencies in enumerate(model.tables):
                tokens = tuple(rng.randrange(258) for _ in range(503))
                encoded = bwt._rans_encode(tokens, model, table_offset=table_index)
                cumulative = [0]
                for frequency in frequencies:
                    cumulative.append(cumulative[-1] + frequency)
                state = struct.unpack_from("<I", encoded)[0]
                at = 4
                restored = []
                for _ in tokens:
                    remainder = state % 4096
                    symbol = bisect.bisect_right(cumulative, remainder) - 1
                    restored.append(symbol)
                    state = frequencies[symbol] * (state // 4096) + remainder - cumulative[symbol]
                    while state < 2**23:
                        state = state * 256 + encoded[at]
                        at += 1
                self.assertEqual(tuple(restored), tokens)
                self.assertEqual((state, at), (2**23, len(encoded)))

    def test_differential_blocks_and_unseen_bytes(self):
        rng = random.Random(451)
        cases = (
            b"",
            rng.randbytes(3073),
            b"\xff\x00\xc0\x80\xed\xa0\x80" * 159,
            b"abracadabra!" * 591,
            "異なる言語 café فهرس\n".encode() * 87,
        )
        for variant, model in self.models.items():
            for boundary in (31, 257, 4096):
                for data in cases:
                    with self.subTest(variant=variant, boundary=boundary, size=len(data)):
                        wire = bwt.encode(data, model, boundary)
                        self.assertEqual(bwt.decode(wire), data)
                        prepared = bwt.prepare(wire)
                        blocks = []
                        for index, start in enumerate(range(0, len(data), boundary)):
                            block = prepared.decode_block(index)
                            self.assertEqual(block, data[start : start + boundary])
                            blocks.append(block)
                        self.assertEqual(b"".join(blocks), data)

    def test_factorizer_expansion_at_maximum_boundary(self):
        # Escapes increase the transformed length on random or 0xff-rich data.
        # Valid raw input must remain encodable through bounded raw fallback.
        rng = random.Random(7201)
        for data in (rng.randbytes(65536), b"\xff" + rng.randbytes(65535)):
            wire = bwt.encode(data, self.models["C"], 65536)
            self.assertEqual(bwt.decode(wire), data)

    def test_mutations_either_reject_or_preserve_exact_bytes(self):
        data = (b"a meaningful repeated fragment and changed ending. " * 90)[:4096]
        for variant, model in self.models.items():
            wire = bwt.encode(data, model, 1024)
            rng = random.Random(710 + ord(variant))
            for trial in range(48):
                altered = bytearray(wire)
                position = rng.randrange(len(altered))
                altered[position] ^= 1 << rng.randrange(8)
                try:
                    restored = bwt.decode(bytes(altered))
                except bwt.CodecError:
                    continue
                self.assertEqual(restored, data, (variant, trial, position))
            for cut in (0, 1, 39, len(wire) // 2, len(wire) - 1):
                with self.assertRaises(bwt.CodecError):
                    bwt.decode(wire[:cut])


if __name__ == "__main__":
    unittest.main()
