#!/usr/bin/env python3
"""Exact-rational algebra and prefix-code safety tests for this lane."""

from __future__ import annotations

import unittest
from fractions import Fraction

from operator_probe import (
    EOS,
    binary_search_cdf,
    complete_prefix_code,
    cumulative_mass_vectors,
    cdf_values,
    binary_search_cumulative_vectors,
    matrix_multiply,
    parse_codebook,
    row_times_matrix,
    validate_cdf,
    vector_normalize,
)


FMatrix = tuple[tuple[Fraction, ...], ...]


def fcompose(left: FMatrix, right: FMatrix) -> FMatrix:
    h = len(left)
    return tuple(
        tuple(sum((left[i][k] * right[k][j] for k in range(h)), Fraction(0)) for j in range(h))
        for i in range(h)
    )


def frow(row: tuple[Fraction, ...], matrix: FMatrix) -> tuple[Fraction, ...]:
    return tuple(sum((row[i] * matrix[i][j] for i in range(len(row))), Fraction(0)) for j in range(len(row)))


class ExactOperatorTests(unittest.TestCase):
    def test_rank_one_reset_preserves_fragment_mass_for_every_belief(self) -> None:
        matrix: FMatrix = (
            (Fraction(1, 5), Fraction(1, 10)),
            (Fraction(1, 20), Fraction(3, 20)),
        )
        r = tuple(sum(row) for row in matrix)
        v = (Fraction(1, 3), Fraction(2, 3))
        approximation: FMatrix = tuple(tuple(r[i] * v[j] for j in range(2)) for i in range(2))
        for q in ((Fraction(1), Fraction(0)), (Fraction(0), Fraction(1)), (Fraction(2, 5), Fraction(3, 5))):
            exact = sum(frow(q, matrix))
            approx = sum(frow(q, approximation))
            self.assertEqual(exact, approx)

    def test_posterior_is_bounded_and_normalized(self) -> None:
        matrix: FMatrix = (
            (Fraction(1, 4), Fraction(1, 4)),
            (Fraction(1, 8), Fraction(3, 8)),
        )
        q = (Fraction(1, 3), Fraction(2, 3))
        mass = frow(q, matrix)
        probability = sum(mass)
        posterior = tuple(value / probability for value in mass)
        self.assertEqual(sum(posterior), Fraction(1))
        self.assertTrue(all(Fraction(0) <= value <= Fraction(1) for value in posterior))

    def test_fragment_composition_matches_two_step_chain(self) -> None:
        first: FMatrix = (
            (Fraction(1, 4), Fraction(1, 4)),
            (Fraction(1, 10), Fraction(2, 5)),
        )
        second: FMatrix = (
            (Fraction(1, 2), Fraction(1, 5)),
            (Fraction(1, 8), Fraction(3, 8)),
        )
        q = (Fraction(3, 7), Fraction(4, 7))
        composed = fcompose(first, second)
        one_step = frow(q, composed)
        two_step = frow(frow(q, first), second)
        self.assertEqual(one_step, two_step)

    def test_impossible_and_negative_models_are_rejected(self) -> None:
        with self.assertRaises(ValueError):
            # A negative coefficient cannot be a transfer operator.
            matrix_multiply(((1.0, -1.0), (0.0, 1.0)), ((1.0, 0.0), (0.0, 1.0)))
        with self.assertRaises(ValueError):
            # A zero-mass fragment has no posterior.
            vector_normalize(row_times_matrix((1.0, 0.0), ((0.0, 0.0), (0.0, 0.0))))

    def test_complete_prefix_code_handles_exact_and_partial_terminal_phrase(self) -> None:
        phrases = complete_prefix_code([b"abc"])
        exact = parse_codebook(phrases, tuple(b"abc") + (EOS,))
        partial = parse_codebook(phrases, tuple(b"ab") + (EOS,))
        self.assertEqual(b"".join(phrases[i].surface for i in exact), b"abc")
        self.assertEqual(b"".join(phrases[i].surface for i in partial), b"ab")
        self.assertTrue(any(phrases[i].kind == "terminal" for i in partial))
        symbols = [phrase.symbols for phrase in phrases]
        self.assertEqual(len(symbols), len(set(symbols)))
        for left in symbols:
            for right in symbols:
                if left != right:
                    self.assertFalse(right[: len(left)] == left)

    def test_cdf_prefix_vectors_and_binary_search(self) -> None:
        # Three normalized phrase masses over H=2; these emulate precomputed
        # r_w vectors and avoid floating-point accumulation in this invariant.
        metrics = [
            {"r": [0.2, 0.4]},
            {"r": [0.3, 0.1]},
            {"r": [0.5, 0.5]},
        ]
        q = (0.25, 0.75)
        cdf = cdf_values(q, cumulative_mass_vectors(metrics))
        self.assertAlmostEqual(cdf[-1], 1.0)
        self.assertEqual(binary_search_cdf(cdf, 0.1), 0)
        self.assertEqual(binary_search_cdf(cdf, 0.4), 1)
        self.assertEqual(binary_search_cumulative_vectors(q, cumulative_mass_vectors(metrics), 0.4), 1)
        self.assertTrue(validate_cdf(metrics, q)["ok"])


if __name__ == "__main__":
    unittest.main()
