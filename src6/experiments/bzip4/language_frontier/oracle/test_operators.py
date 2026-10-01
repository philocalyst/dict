from fractions import Fraction
from itertools import product
import unittest

from operators import PrefixCDF, Source, advance, compose, identity, persistent_binary_source


class OperatorTests(unittest.TestCase):
    def setUp(self):
        self.source = persistent_binary_source()
        self.initial = (Fraction(1, 2), Fraction(1, 2))

    def test_all_fixed_length_strings_normalize(self):
        for length in range(7):
            mass = sum(advance(self.initial, self.source.fragment(bytes(x)))[0]
                       for x in product(b"ab", repeat=length))
            self.assertEqual(mass, 1)

    def test_composition_is_associative_and_preserves_identity(self):
        a, b, c = (self.source.fragment(x) for x in (b"aba", b"baab", b"bbb"))
        self.assertEqual(compose(compose(a, b), c), compose(a, compose(b, c)))
        self.assertEqual(compose(identity(2), a), a)
        self.assertEqual(compose(a, identity(2)), a)
        self.assertEqual(compose(a, b), self.source.fragment(b"ababaab"))

    def test_fragment_skip_matches_each_byte_exactly(self):
        text = b"aaaabbbbaabababbb"
        probability, posterior = Fraction(1), self.initial
        for byte in text:
            step, posterior = advance(posterior, self.source.emission[byte])
            probability *= step
        self.assertEqual(advance(self.initial, self.source.fragment(text)), (probability, posterior))

    def test_shared_grammar_dag_needs_no_hidden_state_reset(self):
        stem = self.source.fragment(b"abaab")
        affix = self.source.fragment(b"bb")
        family = compose(compose(affix, stem), affix)
        self.assertEqual(family, self.source.fragment(b"bbabaabbb"))
        for boundary in ((Fraction(1), Fraction(0)), (Fraction(0), Fraction(1)), self.initial):
            self.assertEqual(advance(boundary, family), advance(boundary, self.source.fragment(b"bbabaabbb")))

    def test_same_last_byte_does_not_imply_same_predictive_state(self):
        _, first = advance(self.initial, self.source.fragment(b"aaaaa"))
        _, second = advance(self.initial, self.source.fragment(b"bbbba"))
        self.assertNotEqual(first, second)
        self.assertNotEqual(advance(first, self.source.emission[ord("a")])[0],
                            advance(second, self.source.emission[ord("a")])[0])

    def test_complete_macro_codebook_preserves_total_mass(self):
        codebook = self.source.codebook((b"a", b"ba", b"bba", b"bbb"))
        for boundary in (self.initial, (Fraction(4, 5), Fraction(1, 5))):
            self.assertEqual(sum(advance(boundary, op)[0] for op in codebook.values()), 1)
        for invalid in ((b"a", b"ab", b"b"), (b"a", b"ba"), (b"a", b"a", b"b")):
            with self.assertRaises(ValueError):
                self.source.codebook(invalid)

    def test_bad_generator_rejected(self):
        with self.assertRaises(ValueError):
            Source({ord("a"): ((Fraction(2),),)})
        with self.assertRaises(ValueError):
            advance((Fraction(1), Fraction(1)), identity(2))
        with self.assertRaises(ValueError):
            advance((Fraction(2), Fraction(-1)), identity(2))

    def test_cumulative_vector_index_matches_full_matrix_probabilities(self):
        operators = tuple(self.source.codebook((b"a", b"ba", b"bba", b"bbb")).values())
        index = PrefixCDF(operators)
        for numerator in range(11):
            belief = (Fraction(numerator, 10), Fraction(10 - numerator, 10))
            left = Fraction(0)
            for symbol, operator in enumerate(operators):
                probability, _ = advance(belief, operator)
                self.assertEqual(index.boundary(belief, symbol), left)
                self.assertEqual(index.boundary(belief, symbol + 1), left + probability)
                self.assertEqual(index.locate(belief, left), symbol)
                self.assertEqual(index.locate(belief, left + probability / 2), symbol)
                left += probability

    def test_cumulative_index_skips_zero_mass_and_rejects_bad_inputs(self):
        zero = ((Fraction(0),),)
        unit = ((Fraction(1),),)
        index = PrefixCDF((zero, unit, zero))
        self.assertEqual(index.locate((Fraction(1),), Fraction(0)), 1)
        self.assertEqual(index.locate((Fraction(1),), Fraction(999, 1000)), 1)
        for bad in (Fraction(-1), Fraction(1)):
            with self.assertRaises(ValueError):
                index.locate((Fraction(1),), bad)
        for invalid in ((), (zero,), (unit, unit)):
            with self.assertRaises(ValueError):
                PrefixCDF(invalid)


if __name__ == "__main__":
    unittest.main()
