"""Independent integer identities for the proposed SCM4 cumulative law.

This checks algebra and bounds, not the codec implementation or its speed.
The unsimplified reference deliberately retains all factors from the model.
"""

import random
import unittest

Q = 65536


class CumulativeIdentityTests(unittest.TestCase):
    def check_suffix(self, n, count, lower):
        reference = (Q - 256) * (Q * count + 16 * lower) // (Q * (n + 16))
        reduced = 255 * (4096 * count + lower) // (16 * (n + 16))
        self.assertEqual(reference, reduced)
        self.assertLessEqual(255 * (4096 * count + lower), 4_293_857_280)

    def check_emission(self, escape, lower, copies):
        reference = (Q - 256) * (escape * lower + Q * copies) // (Q * Q)
        reduced = (255 * (escape * lower + Q * copies)) >> 24
        self.assertEqual(reference, reduced)
        self.assertLess(255 * (escape * lower + Q * copies), 1 << 40)

    def test_extreme_intermediates(self):
        for n in (0, 1, 15, 16, 255, 4095):
            for count in (0, n // 2, n):
                for lower in (0, 1, Q // 2, Q - 1, Q):
                    self.check_suffix(n, count, lower)
        for escape in (0, 1, Q // 2, Q - 1, Q):
            for copies in (0, (Q - escape) // 2, Q - escape):
                for lower in (0, 1, Q // 2, Q - 1, Q):
                    self.check_emission(escape, lower, copies)

    def test_random_integer_equivalence(self):
        rng = random.Random(0xCDF4)
        for _ in range(4096):
            n = rng.randrange(4096)
            self.check_suffix(n, rng.randrange(n + 1), rng.randrange(Q + 1))
            escape = rng.randrange(Q + 1)
            self.check_emission(escape, rng.randrange(Q + 1), rng.randrange(Q - escape + 1))

    def test_complete_cdfs(self):
        rng = random.Random(42)
        for _ in range(32):
            counts = [rng.randrange(16) for _ in range(256)]
            total, prefix = sum(counts), 0
            literal = []
            for k in range(257):
                literal.append(k + 255 * (4096 * prefix + 256 * k) // (16 * (total + 16)))
                if k < 256:
                    prefix += counts[k]
            escape, copied_byte = rng.randrange(1, Q + 1), rng.randrange(256)
            emitted = [k + ((255 * (escape * literal[k] + Q * ((Q - escape) if k > copied_byte else 0))) >> 24)
                       for k in range(257)]
            for cdf in (literal, emitted):
                self.assertEqual((cdf[0], cdf[-1]), (0, Q))
                self.assertTrue(all(a < b for a, b in zip(cdf, cdf[1:])))


if __name__ == "__main__":
    unittest.main()
