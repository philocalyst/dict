import random
import unittest

try:
    from .orientation import HEADER, reverse_runs, unpack
except ImportError:
    from orientation import HEADER, reverse_runs, unpack


class OrientationTest(unittest.TestCase):
    def test_involution_on_arbitrary_bytes(self):
        rng = random.Random(914)
        examples = [b"", bytes(range(256)), b"one\x00two 123 4\xff\x81z",
                    "İstanbul كتاب 日本語 e\u0301 中文 русский".encode()]
        examples.extend(rng.randbytes(n) for n in range(0, 10000, 127))
        for raw in examples:
            self.assertEqual(reverse_runs(reverse_runs(raw)), raw)
            framed = HEADER.pack(b"B4OR", 1, 1, 0, len(raw))
            self.assertEqual(unpack(framed, reverse_runs(raw)), raw)

    def test_header_validation(self):
        valid = HEADER.pack(b"B4OR", 1, 0, 0, 3)
        self.assertEqual(unpack(valid, b"abc"), b"abc")
        for size in range(HEADER.size):
            with self.assertRaises(ValueError):
                unpack(valid[:size], b"abc")
        for bad in [HEADER.pack(b"fail", 1, 0, 0, 3),
                    HEADER.pack(b"B4OR", 2, 0, 0, 3),
                    HEADER.pack(b"B4OR", 1, 2, 0, 3),
                    HEADER.pack(b"B4OR", 1, 0, 1, 3),
                    HEADER.pack(b"B4OR", 1, 0, 0, 4)]:
            with self.assertRaises(ValueError):
                unpack(bad, b"abc")


if __name__ == "__main__":
    unittest.main()
