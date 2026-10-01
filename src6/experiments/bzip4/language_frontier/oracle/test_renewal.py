"""Independent finite-universe checks for the research probability model."""

from fractions import Fraction
from itertools import product
import unittest

from renewal import Piece, Renewal


class RenewalTests(unittest.TestCase):
    def setUp(self):
        self.model = Renewal((Piece(b"a", 2), Piece(b"b", 1), Piece(b"ab", 4), Piece(b"ba", 3)))

    def strings(self, length):
        return [bytes(values) for values in product(self.model.alphabet, repeat=length)]

    def test_partition_matches_independent_enumeration(self):
        for length in range(7):
            total = sum((sum(self.model.path_masses(x)) for x in self.strings(length)), Fraction(0))
            self.assertEqual(total, self.model.partition(length))
            self.assertEqual(sum(self.model.prefix_mass(x, length) for x in self.strings(length)), 1)

    def test_prefix_probabilities_are_causal_exact_marginals(self):
        for length in range(1, 6):
            strings = self.strings(length)
            for observed in range(length + 1):
                for prefix in self.strings(observed):
                    enumerated = sum((self.model.prefix_mass(x, length) for x in strings if x.startswith(prefix)), Fraction(0))
                    self.assertEqual(self.model.prefix_mass(prefix, length), enumerated)

    def test_decoder_cdf_chain_equals_surface_probability(self):
        for text in self.strings(5):
            probability = Fraction(1)
            for at, byte in enumerate(text):
                row = self.model.next_byte(text[:at], len(text))
                self.assertEqual(sum(row.values()), 1)
                probability *= row[byte]
            self.assertEqual(probability, self.model.prefix_mass(text, len(text)))

    def test_duplicate_latent_labels_do_not_improve_surface_probability(self):
        plain = Renewal((Piece(b"a", 4), Piece(b"b", 4), Piece(b"ab", 8)))
        split = Renewal((Piece(b"a", 4), Piece(b"b", 4), *(Piece(b"ab", 1) for _ in range(8))))
        text = b"ababab"
        self.assertEqual(plain.prefix_mass(text, len(text)), split.prefix_mass(text, len(text)))
        self.assertGreater(split.ambiguity_bits(text), plain.ambiguity_bits(text) + 8)

    def test_unique_parse_and_arbitrary_byte_alphabet(self):
        model = Renewal(tuple(Piece(bytes((b,)), 1) for b in (0, 0x80, 0xFF)))
        text = b"\x00\xff\x80"
        self.assertEqual(model.ambiguity_bits(text), 0)
        self.assertEqual(model.prefix_mass(text, len(text)), Fraction(1, 27))

    def test_rejects_invalid_models_lengths_and_queries(self):
        for pieces in ((), (Piece(b"", 1),), (Piece(b"x", 0),)):
            with self.assertRaises(ValueError):
                Renewal(pieces)
        model = Renewal((Piece(b"ab", 1),))
        with self.assertRaises(ValueError):
            model.prefix_mass(b"", 1)
        with self.assertRaises(ValueError):
            model.next_byte(b"ab", 2)
        with self.assertRaises(ValueError):
            model.next_byte(b"x", 2)


if __name__ == "__main__":
    unittest.main()
