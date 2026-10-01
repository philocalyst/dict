"""Exact, deliberately slow oracle for a latent piece-emission model.

This is not a compressor or a throughput benchmark.  Fractions and exhaustive
enumeration make the probability claims in the faster experiments falsifiable.
Only the emitted bytes are observed; piece boundaries and piece identities are
latent.  The output length is known (and must be charged by a real frame).
"""

from __future__ import annotations

from dataclasses import dataclass
from fractions import Fraction
from functools import cache
from math import log2


@dataclass(frozen=True)
class Piece:
    text: bytes
    weight: int


class Renewal:
    """A normalized distribution on strings of one given byte length.

    Let F(x) sum the product of piece probabilities over all exact parses of x.
    Summing F(x) over every length-n string gives Z(n).  The recurrence for Z
    depends on piece lengths, not on unrevealed text, so conditioning on a
    charged length is causal: P(x | n) = F(x) / Z(n).

    Separate pieces may emit identical bytes.  Keeping those aliases is useful
    for proving that ambiguity alone is not evidence of better compression.
    """

    def __init__(self, pieces: tuple[Piece, ...]):
        if not pieces or any(not p.text or p.weight <= 0 for p in pieces):
            raise ValueError("pieces must be nonempty strings with positive weights")
        self.pieces = pieces
        total = sum(p.weight for p in pieces)
        self.probabilities = tuple(Fraction(p.weight, total) for p in pieces)
        self.alphabet = tuple(sorted({byte for p in pieces for byte in p.text}))

    @cache
    def partition(self, length: int) -> Fraction:
        """Mass of all derivations emitting exactly `length` bytes."""
        if length < 0:
            return Fraction(0)
        if length == 0:
            return Fraction(1)
        return sum(
            (prob * self.partition(length - len(piece.text))
             for piece, prob in zip(self.pieces, self.probabilities)),
            Fraction(0),
        )

    def boundary_masses(self, text: bytes) -> list[Fraction]:
        """Forward sum at exact piece boundaries; no greedy parse is chosen."""
        mass = [Fraction(0)] * (len(text) + 1)
        mass[0] = Fraction(1)
        for end in range(1, len(text) + 1):
            for piece, prob in zip(self.pieces, self.probabilities):
                start = end - len(piece.text)
                if start >= 0 and text[start:end] == piece.text:
                    mass[end] += mass[start] * prob
        return mass

    def prefix_mass(self, prefix: bytes, length: int) -> Fraction:
        """P(prefix | output length), summing both complete and partial pieces."""
        if length < 0 or not self.partition(length):
            raise ValueError("unreachable output length")
        if len(prefix) > length:
            return Fraction(0)
        forward = self.boundary_masses(prefix)
        # Paths whose current piece ends exactly at the observed prefix.
        total = forward[-1] * self.partition(length - len(prefix))
        # Paths still inside a piece.  Its unobserved tail is deterministic;
        # all subsequent pieces are marginalized through the length partition.
        for start, mass in enumerate(forward[:-1]):
            if not mass:
                continue
            suffix = prefix[start:]
            for piece, prob in zip(self.pieces, self.probabilities):
                if len(piece.text) > len(suffix) and piece.text.startswith(suffix):
                    total += mass * prob * self.partition(length - start - len(piece.text))
        return total / self.partition(length)

    def next_byte(self, prefix: bytes, length: int) -> dict[int, Fraction]:
        if len(prefix) >= length:
            raise ValueError("no byte remains")
        denominator = self.prefix_mass(prefix, length)
        if not denominator:
            raise ValueError("impossible prefix")
        return {
            byte: self.prefix_mass(prefix + bytes((byte,)), length) / denominator
            for byte in self.alphabet
        }

    def path_masses(self, text: bytes) -> list[Fraction]:
        """Independent exhaustive path oracle, only suitable for tiny strings."""
        if not text:
            return [Fraction(1)]
        paths: list[Fraction] = []
        for piece, prob in zip(self.pieces, self.probabilities):
            if text.startswith(piece.text):
                paths.extend(prob * tail for tail in self.path_masses(text[len(piece.text):]))
        return paths

    def ambiguity_bits(self, text: bytes) -> float:
        paths = self.path_masses(text)
        if not paths:
            raise ValueError("unrepresentable text")
        return log2(sum(paths) / max(paths))


if __name__ == "__main__":
    original = Renewal((Piece(b"a", 4), Piece(b"b", 4), Piece(b"ab", 8)))
    aliases = Renewal((Piece(b"a", 4), Piece(b"b", 4), *(Piece(b"ab", 1) for _ in range(8))))
    for text in (b"ab", b"abab", b"ababab"):
        print({
            "text": text.decode("ascii"),
            "same_surface_probability": original.prefix_mass(text, len(text)) == aliases.prefix_mass(text, len(text)),
            "original_gap_bits": original.ambiguity_bits(text),
            "aliased_gap_bits": aliases.ambiguity_bits(text),
            "compression_record": False,
        })
