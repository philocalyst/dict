#!/usr/bin/env python3
"""Small tests for exact segmentation, PPM normalization, and state caps."""
import math
import unittest

from ppm_probe import PPM, byte_tokens, probe, scalar_tokens


class ProbeTests(unittest.TestCase):
    def test_arbitrary_bytes_round_trip_both_modes(self):
        for raw in (b"", b"a\x00\xffB\n", bytes(range(256)) * 2,
                    "日本語の本。Arabic عربي café e\u0301".encode()):
            for tokenizer in (byte_tokens, scalar_tokens):
                self.assertEqual(b"".join(token for token, _ in tokenizer(raw)), raw)
            for mode in ("byte", "scalar"):
                result = probe(raw, mode)
                self.assertEqual(result["source_bytes"], len(raw))
                self.assertGreaterEqual(result["optimistic_complete_bytes"], 24)

    def test_cjk_scalars_are_individual_events(self):
        raw = "日本語abc。".encode()
        tokens = list(scalar_tokens(raw))
        self.assertEqual([token for token, _ in tokens],
                         ["日".encode(), "本".encode(), "語".encode(), b"abc", "。".encode()])

    def test_lexical_ppm_probability_normalization(self):
        model = PPM(100, 1000, None)
        history = []
        for symbol in (0, 1, 0, 2, 0, 1, 3, 0, 1, 0):
            model.update(symbol, history)
            history.append(symbol)
            history = history[-4:]
        for context in ([], [0], [1, 0], [0, 1, 0], [0, 1, 0, 1]):
            total = sum(2 ** -model.price(symbol, context)
                        for symbol in (*model.root.counts, None))
            self.assertTrue(math.isclose(total, 1.0, abs_tol=1e-12), (context, total))

    def test_row_replacement_keeps_complete_successors(self):
        model = PPM(2, 4, None)
        history = [9]
        for symbol in (0, 1, 2, 3):
            model.update(symbol, history)
        self.assertEqual(model.rows[(1, (9,))].counts, {0: 1, 1: 1, 2: 1, 3: 1})
        model.update(4, [8])
        self.assertGreater(model.replacements, 0)
        self.assertLessEqual(model.edges, model.max_edges)


if __name__ == "__main__":
    unittest.main()
