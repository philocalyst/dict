#!/usr/bin/env python3
"""Exhaustive tiny checks for the contextual surface source."""

from __future__ import annotations

import itertools
import unittest

from codec import (
    Model,
    decode_frame,
    encode_map,
    encode_marginal,
    enumerate_prefix_mass,
    enumerate_token_paths,
    viterbi_tokens,
)
from adapter import decode as adapter_decode
from adapter import encode as adapter_encode


def tiny_model(class_count: int = 2) -> Model:
    tokens = [bytes((byte,)) for byte in range(256)] + [b"ab", b"aba", b"ba"]
    destinations = [(byte * 3 + 1) % class_count for byte in range(256)]
    destinations.extend((1 % class_count, 0, 1 % class_count))
    rows = []
    for source_class in range(class_count):
        row = [1] * 256 + [5 + source_class, 3, 2 + source_class]
        rows.append(row)
    return Model(tokens, destinations, rows, class_count=class_count)


class ContextualSurfaceTests(unittest.TestCase):
    def test_frontier_normalization_and_exhaustive_prefix_mass(self) -> None:
        model = tiny_model()
        for length in range(5):
            for symbols in itertools.product(b"ab", repeat=length):
                prefix = bytes(symbols)
                state = model.initial_state()
                chain_mass = 1.0
                for byte in prefix:
                    probabilities = model.byte_probs(state)
                    self.assertAlmostEqual(sum(probabilities), 1.0, places=12)
                    chain_mass *= probabilities[byte]
                    state = model.advance(state, byte)
                    self.assertLessEqual(len(state.active), max(map(len, model.tokens)))
                self.assertAlmostEqual(chain_mass, enumerate_prefix_mass(prefix, model), places=12)

    def test_class_rows_are_not_iid_control(self) -> None:
        contextual = tiny_model()
        iid_tokens = list(contextual.tokens)
        iid_destinations = [0] * len(iid_tokens)
        iid_rows = [[sum(contextual.freqs[c][i] for c in range(contextual.class_count)) for i in range(len(iid_tokens))]]
        iid = Model(iid_tokens, iid_destinations, iid_rows, class_count=1)
        state_context = contextual.initial_state()
        state_iid = iid.initial_state()
        for byte in b"ababa":
            state_context = contextual.advance(state_context, byte)
            state_iid = iid.advance(state_iid, byte)
        probs_context = contextual.byte_probs(state_context)
        probs_iid = iid.byte_probs(state_iid)
        self.assertGreater(max(abs(a - b) for a, b in zip(probs_context, probs_iid)), 1.0e-8)

    def test_complete_boundary_mass_and_viterbi_are_same_source(self) -> None:
        model = tiny_model()
        paths = enumerate_token_paths(b"aba", model)
        self.assertGreater(len(paths), 1)
        self.assertLessEqual(sum(mass for _, mass in paths), enumerate_prefix_mass(b"aba", model))
        path = viterbi_tokens(b"ab", model)
        self.assertGreaterEqual(len(path), 1)
        map_frame, map_stats = encode_map(b"ab", model)
        marginal_frame, marginal_stats = encode_marginal(b"ab", model)
        self.assertTrue(map_stats["round_trip"])
        self.assertTrue(marginal_stats["round_trip"])
        self.assertEqual(decode_frame(map_frame), b"ab")
        self.assertEqual(decode_frame(marginal_frame), b"ab")

    def test_round_trip_preserves_mixed_bytes_and_rejects_truncation(self) -> None:
        model = tiny_model()
        raw = ("Cafe\u0301 東京\nПривет مرحبا\t".encode("utf-8") + b"\xff\xfe\x00\x80\xc3(") * 3
        for encoder in (encode_map, encode_marginal):
            frame, stats = encoder(raw, model)
            self.assertTrue(stats["round_trip"])
            self.assertEqual(decode_frame(frame), raw)
            with self.assertRaises(ValueError):
                decode_frame(frame[:-1])

    def test_quickbench_adapter_fits_and_decodes_a_self_contained_frame(self) -> None:
        raw = b"ababa\x00\xff" * 4
        frame = adapter_encode(raw, block_bytes=64, mode="map", max_tokens=300)
        self.assertEqual(adapter_decode(frame), raw)
        with self.assertRaises(ValueError):
            adapter_encode(raw, block_bytes=len(raw) - 1)


if __name__ == "__main__":
    unittest.main()
