"""Exact fragment algebra for a finite-state generative source.

A fragment is both an emitted string and a transfer operator.  Matrix
multiplication sums over the hidden states *inside* the fragment, so composing
two fragments preserves all boundary-state uncertainty.  This oracle uses
Fractions; it makes no claim about the speed of a future integer implementation.
"""

from __future__ import annotations

from fractions import Fraction
from functools import reduce

Matrix = tuple[tuple[Fraction, ...], ...]
Belief = tuple[Fraction, ...]


def identity(size: int) -> Matrix:
    return tuple(tuple(Fraction(i == j) for j in range(size)) for i in range(size))


def compose(left: Matrix, right: Matrix) -> Matrix:
    """The summary of concatenation, in emission order: M(xy)=M(x)M(y)."""
    size = len(left)
    if len(right) != size:
        raise ValueError("incompatible operator dimensions")
    return tuple(
        tuple(sum((left[i][k] * right[k][j] for k in range(size)), Fraction(0))
              for j in range(size))
        for i in range(size)
    )


def advance(belief: Belief, operator: Matrix) -> tuple[Fraction, Belief]:
    """Return fragment probability and the posterior after observing it."""
    if len(belief) != len(operator) or sum(belief) != 1 or any(value < 0 for value in belief):
        raise ValueError("invalid boundary belief")
    mass = tuple(
        sum((belief[i] * operator[i][j] for i in range(len(belief))), Fraction(0))
        for j in range(len(belief))
    )
    probability = sum(mass)
    if probability <= 0:
        raise ValueError("impossible fragment")
    return probability, tuple(value / probability for value in mass)


class PrefixCDF:
    """Index a complete macro alphabet without evaluating every matrix.

    The kth boundary is q dot sum_{j<k}(M_j 1).  Preparing cumulative
    row-sum vectors turns inverse-CDF lookup into O(H log P), followed by
    one O(H squared) posterior update for the selected fragment.  The
    vectors can be derived from operators; they need not be stored twice.

    This exact-rational oracle is an algebra test, not a wire codec.
    """

    def __init__(self, operators: tuple[Matrix, ...]):
        if not operators:
            raise ValueError("empty macro alphabet")
        self.size = len(operators[0])
        if not self.size:
            raise ValueError("empty state space")
        cumulative = [tuple(Fraction(0) for _ in range(self.size))]
        for operator in operators:
            if len(operator) != self.size or any(
                len(row) != self.size or any(value < 0 for value in row)
                for row in operator
            ):
                raise ValueError("invalid macro operator")
            cumulative.append(tuple(
                cumulative[-1][i] + sum(operator[i]) for i in range(self.size)
            ))
        if any(value != 1 for value in cumulative[-1]):
            raise ValueError("macro alphabet is not normalized")
        self.cumulative = tuple(cumulative)

    def _check_belief(self, belief: Belief) -> None:
        if len(belief) != self.size or sum(belief) != 1 or any(x < 0 for x in belief):
            raise ValueError("invalid boundary belief")

    def boundary(self, belief: Belief, index: int) -> Fraction:
        self._check_belief(belief)
        if not 0 <= index < len(self.cumulative):
            raise ValueError("boundary outside macro alphabet")
        return sum((q * mass for q, mass in zip(belief, self.cumulative[index])), Fraction(0))

    def locate(self, belief: Belief, quantile: Fraction) -> int:
        self._check_belief(belief)
        if not 0 <= quantile < 1:
            raise ValueError("quantile outside unit interval")
        left, right = 0, len(self.cumulative) - 1
        while right - left > 1:
            middle = (left + right) // 2
            if self.boundary(belief, middle) <= quantile:
                left = middle
            else:
                right = middle
        return left


class Source:
    """An edge-emitting hidden-state source, normalized over a charged length.

    `emission[b][i][j]` jointly chooses output byte b and destination state j.
    For every source state i, summing over b,j must give one.  There are no
    oracle boundaries, scripts, future labels or external word dictionaries.
    """

    def __init__(self, emission: dict[int, Matrix]):
        if not emission:
            raise ValueError("empty alphabet")
        self.size = len(next(iter(emission.values())))
        if not self.size:
            raise ValueError("empty state space")
        for byte, matrix in emission.items():
            if not 0 <= byte <= 255 or len(matrix) != self.size:
                raise ValueError("invalid emission")
            if any(len(row) != self.size or any(value < 0 for value in row) for row in matrix):
                raise ValueError("invalid matrix")
        for i in range(self.size):
            if sum(sum(matrix[i]) for matrix in emission.values()) != 1:
                raise ValueError("emissions must be row stochastic")
        self.emission = emission

    def fragment(self, text: bytes) -> Matrix:
        return reduce(compose, (self.emission[b] for b in text), identity(self.size))

    def codebook(self, words: tuple[bytes, ...]) -> dict[bytes, Matrix]:
        """Compile a complete prefix code of surface strings into operators.

        This is the exact bridge to variable-length emissions.  A bag of
        overlapping phrases is NOT a prefix code; selecting a hidden parse
        would reintroduce latent path cost.  Incomplete alphabets are rejected.
        A real format must separately handle a final partial phrase and charge
        both codebook and model; this oracle does not serialize them.
        """
        if not words or len(set(words)) != len(words) or any(not w for w in words):
            raise ValueError("invalid codebook")
        if any(x != y and y.startswith(x) for x in words for y in words):
            raise ValueError("ambiguous codebook")
        summaries = {word: self.fragment(word) for word in words}
        for i in range(self.size):
            if sum(sum(matrix[i]) for matrix in summaries.values()) != 1:
                raise ValueError("incomplete codebook")
        return summaries


def persistent_binary_source() -> Source:
    """A tiny test source: noisy emissions reveal a persistent hidden regime."""
    return Source({
        ord("a"): ((Fraction(7, 10), Fraction(1, 20)),
                   (Fraction(1, 20), Fraction(1, 5))),
        ord("b"): ((Fraction(1, 5), Fraction(1, 20)),
                   (Fraction(1, 20), Fraction(7, 10))),
    })
