#!/usr/bin/env python3
"""Exact reconstruction and malformed-rANS checks for the geometry proposal."""
import random
import unittest

import geometry


class GeometryTest(unittest.TestCase):
    def test_wrapped_surface_and_unicode(self):
        fixtures = [
            b"", b" ", b"\n", b"a b\nc", b"a  b\n\nc\td\r\ne",
            b"a" * 71 + b"\n" + b"word again\n", bytes(range(256)),
            "日本語の語形\nArabic العربية German Straße\n".encode(),
            b"a\x00b \xff\xfe\n\xc0\x80 tail",
        ]
        rng = random.Random(20261001)
        fixtures += [bytes(rng.choice(b" abcd\n\t\r\x00\xff")
                           for _ in range(rng.randrange(2048))) for _ in range(150)]
        for width in (1, 32, 72, 4096):
            for raw in fixtures:
                with self.subTest(width=width, raw_bytes=len(raw)):
                    normalized, events = geometry.propose(raw, width)
                    rows = geometry.frequencies(events)
                    flags = geometry.pack(events, rows)
                    self.assertEqual(len(normalized), len(raw))
                    self.assertEqual(geometry.realize(normalized, flags, rows,
                                                      len(events), width), raw)

    def test_predictable_wrap_removes_error_events(self):
        raw = b"word word\nword word\nword"
        normalized, events = geometry.propose(raw, 9)
        self.assertEqual(normalized, b"word word word word word")
        self.assertEqual(events, [(0, 0), (1, 0), (0, 0), (1, 0)])
        self.assertEqual(geometry.frequencies(events), [4096, 4096])

    def test_malformed_streams_reject(self):
        raw = b"a b\nc d\ne f g\n" * 100
        normalized, events = geometry.propose(raw, 5)
        rows = geometry.frequencies(events)
        flags = geometry.pack(events, rows)
        for altered in (b"", flags[:3], flags[:-1], flags + b"\x00",
                        b"\x00" * 4 + flags[4:], b"\xff" * 4 + flags[4:]):
            with self.subTest(flags=len(altered)):
                with self.assertRaises(ValueError):
                    geometry.realize(normalized, altered, rows, len(events), 5)
        for count in (len(events)-1, len(events)+1, -1, len(normalized)+1):
            with self.assertRaises(ValueError):
                geometry.realize(normalized, flags, rows, count, 5)
        for invalid_rows in ([-1, 1], [4097, 4096], [1]):
            with self.assertRaises(ValueError):
                geometry.realize(normalized, flags, invalid_rows, len(events), 5)


if __name__ == "__main__":
    unittest.main()
