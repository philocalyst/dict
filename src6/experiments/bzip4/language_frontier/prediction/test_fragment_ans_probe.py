#!/usr/bin/env python3
"""Unit checks for the exact ANS/fragment accounting probe."""

from __future__ import annotations

import unittest
from fractions import Fraction
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from fragment_ans_probe import (
    TOTAL,
    cumulative_terminal_vectors,
    diagonal_product,
    matrix_sub,
    phrase_cdf,
    persistent_binary_source,
    rank,
    structured_h4,
)
from operators import advance


class FragmentAnsProbeTests(unittest.TestCase):
    def test_same_last_byte_has_distinct_exact_cdf(self) -> None:
        source = persistent_binary_source()
        initial = (Fraction(1, 2), Fraction(1, 2))
        first = advance(initial, source.fragment(b"aaaaa"))[1]
        second = advance(initial, source.fragment(b"bbbba"))[1]
        p_first = advance(first, source.emission[ord("a")])[0]
        p_second = advance(second, source.emission[ord("a")])[0]
        self.assertNotEqual(p_first, p_second)
        self.assertNotEqual(
            (p_first * TOTAL + Fraction(1, 2)).numerator // (p_first * TOTAL + Fraction(1, 2)).denominator,
            (p_second * TOTAL + Fraction(1, 2)).numerator // (p_second * TOTAL + Fraction(1, 2)).denominator,
        )

    def test_complete_phrase_codebook_normalizes_for_each_belief(self) -> None:
        source = persistent_binary_source()
        words = (b"a", b"ba", b"bba", b"bbb")
        operators = source.codebook(words)
        cumulative = cumulative_terminal_vectors(operators, words)
        for belief in ((Fraction(1, 2), Fraction(1, 2)), (Fraction(4, 5), Fraction(1, 5))):
            probabilities = [advance(belief, operators[word])[0] for word in words]
            self.assertEqual(sum(probabilities), 1)
            cdf = phrase_cdf(belief, cumulative)
            self.assertEqual(cdf[-1], 1)
            self.assertEqual(
                tuple(cdf[index] - (cdf[index - 1] if index else 0) for index in range(len(cdf))),
                tuple(probabilities),
            )

    def test_diagonal_rank_one_byte_grows_in_phrase_product(self) -> None:
        source, matrices, diagonals = structured_h4()
        for byte in (ord("a"), ord("b")):
            self.assertEqual(rank(matrix_sub(matrices[byte], diagonals[byte])), 1)
        for word, expected_rank in ((b"a", 1), (b"ba", 2), (b"bba", 3)):
            operator = source.fragment(word)
            diagonal = diagonal_product([diagonals[byte] for byte in word])
            self.assertEqual(rank(matrix_sub(operator, diagonal)), expected_rank)


if __name__ == "__main__":
    unittest.main()
