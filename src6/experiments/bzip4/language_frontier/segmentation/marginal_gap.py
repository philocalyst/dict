#!/usr/bin/env python3
"""Exact segmentation marginal-vs-MAP screen.

This is a diagnostic, not a replacement codec.  It builds one deterministic
bounded byte-piece inventory from the input, assigns one smoothed unigram PMF,
and computes both the Viterbi path cost and the exact forward (log-sum) cost
for every same-kind atom.  The inventory spelling/model charge is reported
separately; no external tokenizer, dictionary, LM, or Unicode normalization is
used.  The result answers whether latent segmentation alternatives are large
enough to justify a real lossless marginal coder.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from collections import Counter, defaultdict


def kind(b: int) -> int:
    # Keep v4's policy exactly: ASCII letters or any high byte are a letter;
    # ASCII digits are a digit; all other bytes are singleton atoms.
    if (65 <= b <= 90) or (97 <= b <= 122) or b >= 128:
        return 0
    if 48 <= b <= 57:
        return 1
    return 2


def atoms(data: bytes) -> tuple[list[bytes], Counter[bytes]]:
    out: list[bytes] = []
    freq: Counter[bytes] = Counter()
    at = 0
    while at < len(data):
        k = kind(data[at])
        end = at + 1
        if k != 2:
            while end < len(data) and kind(data[end]) == k:
                end += 1
        text = data[at:end]
        out.append(text)
        freq[text] += 1
        at = end
    return out, freq


def logadd(a: float, b: float) -> float:
    if a == -math.inf:
        return b
    if b == -math.inf:
        return a
    if a < b:
        a, b = b, a
    return a + math.log1p(math.exp(b - a))


def logadd2(a: float, b: float) -> float:
    """Stable log-sum-exp when values are log2 probabilities."""
    if a == -math.inf:
        return b
    if b == -math.inf:
        return a
    if a < b:
        a, b = b, a
    return a + math.log2(1.0 + math.exp2(b - a))


def exact_paths(text: bytes, pieces: list[bytes], logp: dict[bytes, float]) -> list[float]:
    """Tiny exhaustive oracle, used only to audit the two DP recurrences."""
    out: list[float] = []

    def visit(at: int, score: float) -> None:
        if at == len(text):
            out.append(score)
            return
        byte = bytes((text[at],))
        visit(at + 1, score + logp[byte])
        for piece in pieces:
            if text.startswith(piece, at):
                visit(at + len(piece), score + logp[piece])

    visit(0, 0.0)
    return out


def posterior_entropy(text: bytes, pieces: list[bytes], logp: dict[bytes, float], total: float) -> float:
    """H(Z|X) for the same finite segmentation paths, in bits.

    `total` is the PMF denominator.  The recursion keeps an unnormalized path
    mass Z and unnormalized mass-weighted surprisal A; this gives an honest
    lower-bound diagnostic for BB-ANS seed accounting, not a guessed parse
    count.
    """
    z = [0.0] * (len(text) + 1)
    a = [0.0] * (len(text) + 1)
    z[-1] = 1.0
    for at in range(len(text) - 1, -1, -1):
        byte = bytes((text[at],))
        token_options = [(byte, at + 1)]
        token_options.extend((p, at + len(p)) for p in pieces if text.startswith(p, at))
        for token, end in token_options:
            lp = logp.get(token, -math.log2(total))
            prob = 2.0**lp
            mass = prob * z[end]
            z[at] += mass
            a[at] += prob * (a[end] - math.log2(prob) * z[end])
    if z[0] == 0.0:
        return 0.0
    return max(0.0, a[0] / z[0] + math.log2(z[0]))


def self_test() -> None:
    # Inventory and PMF chosen so the toy has both a unique and an ambiguous
    # string.  All computations here are exact enough for a 1e-9 assertion.
    vocab = [b"a", b"b", b"ab"]
    probs = {b"a": 0.5, b"b": 0.25, b"ab": 0.25}
    logp = {piece: math.log2(prob) for piece, prob in probs.items()}
    for text, expected_count in ((b"a", 1), (b"ab", 2), (b"aba", 2)):
        paths = exact_paths(text, [b"ab"], logp)
        assert len(paths) == expected_count, (text, paths)
        best = max(paths)
        summed = math.log2(sum(2.0**score for score in paths))
        assert best <= summed + 1e-12
        # The forward DP must match the exhaustive sum in base-2 logs.
        forward = [-math.inf] * (len(text) + 1)
        forward[0] = 0.0
        for at in range(len(text)):
            if forward[at] == -math.inf:
                continue
            forward[at + 1] = logadd2(forward[at + 1], forward[at] + logp[bytes((text[at],))])
            if text.startswith(b"ab", at):
                forward[at + 2] = logadd2(forward[at + 2], forward[at] + logp[b"ab"])
        assert abs(forward[-1] - summed) < 1e-9, (text, forward[-1], summed)
        # The Viterbi DP must match the exhaustive maximum.
        dp = [-math.inf] * (len(text) + 1)
        dp[0] = 0.0
        for at in range(len(text)):
            if dp[at] == -math.inf:
                continue
            dp[at + 1] = max(dp[at + 1], dp[at] + logp[bytes((text[at],))])
            if text.startswith(b"ab", at):
                dp[at + 2] = max(dp[at + 2], dp[at] + logp[b"ab"])
        assert abs(dp[-1] - best) < 1e-9, (text, dp[-1], best)
    # A token inventory with no usable multi-byte edge has exactly one path;
    # the marginalization gap must be zero.
    unique = exact_paths(b"xyz", [], {bytes((b,)): -8.0 for b in b"xyz"})
    assert len(unique) == 1 and abs(max(unique) - math.log2(sum(2.0**x for x in unique))) < 1e-12


def build_inventory(
    atom_freq: Counter[bytes], max_piece: int, min_occ: int, max_vocab: int
) -> list[bytes]:
    occ: Counter[bytes] = Counter()
    for text, weight in atom_freq.items():
        if len(text) < 2 or kind(text[0]) == 2:
            continue
        limit = min(max_piece, len(text))
        for start in range(len(text)):
            for end in range(start + 2, min(len(text), start + limit) + 1):
                occ[text[start:end]] += weight
    choices = [p for p, n in occ.items() if n >= min_occ]
    choices.sort(key=lambda p: (-(occ[p] * (len(p) - 1)), -len(p), p))
    return choices[:max_vocab]


def screen(data: bytes, args: argparse.Namespace) -> dict[str, object]:
    atom_stream, atom_freq = atoms(data)
    pieces = build_inventory(atom_freq, args.max_piece, args.min_occ, args.max_vocab)
    by_first: dict[int, list[bytes]] = defaultdict(list)
    for piece in pieces:
        by_first[piece[0]].append(piece)

    # The PMF is learned from the same bounded slice.  Bytes remain fallback
    # symbols, so every byte sequence has at least one path.  The inventory
    # model cost is *not* hidden in these numbers; it is reported below.
    counts: Counter[bytes] = Counter()
    for text, weight in atom_freq.items():
        for b in text:
            counts[bytes((b,))] += weight
        # Count occurrences, weighted by atom frequency.  This can count a
        # repeated piece more than once in one atom, as a true unigram LM.
        for at, byte in enumerate(text):
            for p in by_first.get(byte, ()):
                if text.startswith(p, at):
                    counts[p] += weight
    vocab = list(counts)
    alpha = args.alpha
    total = sum(counts.values()) + alpha * len(vocab)
    logp = {p: math.log2((counts[p] + alpha) / total) for p in vocab}

    map_bits = 0.0
    marginal_bits = 0.0
    bytes_covered = 0
    ambiguous_atoms = 0
    path_count_log10 = 0.0
    posterior_entropy_sum = 0.0
    for text, weight in atom_freq.items():
        n = len(text)
        best = [math.inf] * (n + 1)
        forward = [-math.inf] * (n + 1)
        best[0] = 0.0
        forward[0] = 0.0
        for at in range(n):
            if best[at] == math.inf:
                continue
            byte = bytes((text[at],))
            # Each edge stores negative log probability (bits).
            edge = -logp.get(byte, -math.log2((alpha) / total))
            if best[at] + edge < best[at + 1]:
                best[at + 1] = best[at] + edge
            forward[at + 1] = logadd2(forward[at + 1], forward[at] - edge)
            for p in by_first.get(text[at], ()):
                if text.startswith(p, at):
                    end = at + len(p)
                    edge = -logp[p]
                    if best[at] + edge < best[end]:
                        best[end] = best[at] + edge
                    forward[end] = logadd2(forward[end], forward[at] - edge)
        map_nll = best[n]
        marginal_nll = -forward[n]
        gap = map_nll - marginal_nll
        if gap < -1.0e-8:
            raise AssertionError((text, map_nll, marginal_nll, gap))
        # log path count under a uniform edge count is a useful ambiguity
        # sanity signal, but is not used as a coding score.
        ways = [-math.inf] * (n + 1)
        ways[0] = 0.0
        for at in range(n):
            if ways[at] == -math.inf:
                continue
            ways[at + 1] = logadd(ways[at + 1], ways[at])
            for p in by_first.get(text[at], ()):
                if text.startswith(p, at):
                    ways[at + len(p)] = logadd(ways[at + len(p)], ways[at])
        if ways[n] > math.log(2.0) + 1e-9:
            ambiguous_atoms += weight
        path_count_log10 += weight * ways[n] / math.log(10.0)
        posterior_entropy_sum += weight * posterior_entropy(text, pieces, logp, total)
        map_bits += weight * map_nll
        marginal_bits += weight * marginal_nll
        bytes_covered += weight * len(text)

    # Explicit diagnostic model charge: each retained piece must be spelled
    # once and named from a bounded inventory.  This is deliberately separate
    # from the marginal gap and must be replaced by actual bz4 frame bytes for
    # any promotion decision.
    model_bits = sum(8 * len(p) + math.ceil(math.log2(max(1, len(pieces) + 1))) for p in pieces)
    return {
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "atoms": len(atom_stream),
        "atom_types": len(atom_freq),
        "pieces": len(pieces),
        "model_bits_diagnostic": model_bits,
        "map_bits": map_bits,
        "marginal_bits": marginal_bits,
        "gap_bits": map_bits - marginal_bits,
        "gap_bits_per_byte": (map_bits - marginal_bits) / max(1, bytes_covered),
        "gap_bits_per_atom": (map_bits - marginal_bits) / max(1, len(atom_stream)),
        "ambiguous_atoms": ambiguous_atoms,
        "path_count_log10": path_count_log10,
        "posterior_entropy_bits": posterior_entropy_sum,
        "posterior_entropy_bits_per_atom": posterior_entropy_sum / max(1, len(atom_stream)),
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--max-piece", type=int, default=8)
    ap.add_argument("--min-occ", type=int, default=2)
    ap.add_argument("--max-vocab", type=int, default=4096)
    ap.add_argument("--alpha", type=float, default=0.5)
    ap.add_argument("--limit", type=int, default=0, help="read only the first N bytes")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--mixed-control", action="store_true", help="also screen a deterministic mixed UTF-8/invalid-byte control")
    ap.add_argument("--random-control", action="store_true", help="also screen deterministic random bytes")
    args = ap.parse_args()
    self_test()
    rows = []
    for path in args.paths:
        with open(path, "rb") as f:
            data = f.read(args.limit or -1)
            rows.append({"path": os.path.abspath(path), **screen(data, args)})
    if args.mixed_control:
        # U+0301 combining mark, CJK, Arabic, Cyrillic, mixed casing, NUL,
        # whitespace, and deliberately invalid UTF-8 bytes.  The learner sees
        # only bytes; this fixture is a round-trip/ambiguity control.
        control = ("Cafe\u0301 東京\nПривет مرحبا\tAaAa 123123\x00\n".encode("utf-8") + bytes([0xff, 0xfe, 0xc3, 0x28, 0x80, 0x00])) * 256
        rows.append({"path": "<mixed-control>", **screen(control, args)})
    if args.random_control:
        state = 0x9E3779B9
        random_bytes = bytearray()
        for _ in range(16_384):
            state ^= (state << 13) & 0xFFFFFFFF
            state ^= state >> 17
            state ^= (state << 5) & 0xFFFFFFFF
            random_bytes.append(state & 0xFF)
        rows.append({"path": "<random-control>", **screen(bytes(random_bytes), args)})
    if args.json:
        print(json.dumps(rows, sort_keys=True))
    else:
        print("path\tbytes\tsha256\tpieces\tmodel_bits_diag\tmap_bits\tmarginal_bits\tgap_bits\tgap_bits_per_byte\tgap_bits_per_atom\tambiguous_atoms\tpath_count_log10\tposterior_entropy_bits\tposterior_entropy_bits_per_atom")
        for row in rows:
            print("\t".join(str(row[k]) for k in ("path", "bytes", "sha256", "pieces", "model_bits_diagnostic", "map_bits", "marginal_bits", "gap_bits", "gap_bits_per_byte", "gap_bits_per_atom", "ambiguous_atoms", "path_count_log10", "posterior_entropy_bits", "posterior_entropy_bits_per_atom")))


if __name__ == "__main__":
    main()
