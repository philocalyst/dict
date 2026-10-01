#!/usr/bin/env python3
"""Bounded phrase-operator/reset experiment.

This module intentionally contains no archive format.  It loads an already
written HMM teacher, compiles a complete byte+EOS prefix code, and measures
whether products of edge-emission matrices are close enough to rank one to
reset a persistent belief.  All input files are read-only and bounded by the
CLI limit (64 KiB by default).

The implementation uses Python floats for the real-data screen.  The
companion tests use exact ``Fraction`` matrices for the algebraic invariants;
float results are exploratory diagnostics, not a proof of a compressor gain.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import math
import os
import struct
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator, Sequence


EOS = 256
ALPHABET = 257
DEFAULT_LIMIT = 1 << 16
RESET_THRESHOLDS = (0.0, 1e-4, 1e-3, 1e-2)

Vector = tuple[float, ...]
Matrix = tuple[tuple[float, ...], ...]


def sha256_path(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def read_bounded(path: Path, limit: int) -> bytes:
    """Read one bounded development input and reject untouched material."""

    if path.name.endswith(".untouched.bin") or ".untouched." in path.name:
        raise ValueError(f"refusing untouched input: {path}")
    if path.stat().st_size > limit:
        raise ValueError(f"input exceeds {limit} bytes: {path}")
    return path.read_bytes()


def _check_matrix(matrix: Matrix, size: int | None = None) -> int:
    h = len(matrix) if size is None else size
    if h <= 0 or len(matrix) != h or any(len(row) != h for row in matrix):
        raise ValueError("non-square matrix")
    if any((not math.isfinite(x) or x < 0.0) for row in matrix for x in row):
        raise ValueError("non-finite or negative matrix coefficient")
    return h


def matrix_identity(h: int) -> Matrix:
    return tuple(tuple(1.0 if i == j else 0.0 for j in range(h)) for i in range(h))


def matrix_multiply(left: Matrix, right: Matrix) -> Matrix:
    h = _check_matrix(left)
    _check_matrix(right, h)
    return tuple(
        tuple(sum(left[i][k] * right[k][j] for k in range(h)) for j in range(h))
        for i in range(h)
    )


def row_times_matrix(row: Sequence[float], matrix: Matrix) -> Vector:
    h = _check_matrix(matrix)
    if len(row) != h:
        raise ValueError("vector/matrix dimension mismatch")
    return tuple(sum(row[i] * matrix[i][j] for i in range(h)) for j in range(h))


def matrix_row_sums(matrix: Matrix) -> Vector:
    return tuple(sum(row) for row in matrix)


def vector_normalize(vector: Sequence[float]) -> Vector:
    total = sum(vector)
    if not math.isfinite(total) or total <= 0.0:
        raise ValueError("cannot normalize non-positive vector")
    result = tuple(x / total for x in vector)
    if any(not math.isfinite(x) or x < 0.0 for x in result):
        raise ValueError("invalid normalized vector")
    return result


def matrix_fragment(operators: Sequence[Matrix], symbols: Sequence[int], h: int) -> Matrix:
    result = matrix_identity(h)
    for symbol in symbols:
        if symbol < 0 or symbol >= len(operators):
            raise ValueError(f"invalid symbol {symbol}")
        result = matrix_multiply(result, operators[symbol])
    return result


@dataclass(frozen=True)
class HMMTeacher:
    initial: Vector
    transition: Matrix
    emission: tuple[Vector, ...]
    path: str
    sha256: str

    @property
    def states(self) -> int:
        return len(self.initial)


def load_teacher(path: Path) -> HMMTeacher:
    """Load the stored belief teacher without training or rewriting it."""

    raw = json.loads(path.read_text())
    h = int(raw["states"])
    initial = tuple(float(x) for x in raw["initial"])
    transition = tuple(tuple(float(x) for x in row) for row in raw["transition"])
    emission = tuple(tuple(float(x) for x in row) for row in raw["emission"])
    if len(initial) != h or len(transition) != h or len(emission) != h:
        raise ValueError(f"teacher dimension mismatch: {path}")
    _check_matrix(transition, h)
    if any(len(row) != ALPHABET for row in emission):
        raise ValueError(f"teacher alphabet is not bytes+EOS: {path}")
    if abs(sum(initial) - 1.0) > 1e-8:
        raise ValueError("teacher initial vector is not normalized")
    for row in transition:
        if abs(sum(row) - 1.0) > 1e-7:
            raise ValueError("teacher transition row is not normalized")
    for row in emission:
        if abs(sum(row) - 1.0) > 1e-7:
            raise ValueError("teacher emission row is not normalized")
    return HMMTeacher(
        initial=vector_normalize(initial),
        transition=transition,
        emission=emission,
        path=str(path),
        sha256=sha256_path(path),
    )


def edge_operators(teacher: HMMTeacher) -> tuple[Matrix, ...]:
    """Return M_b[i,j] = p(b | i) p(j | i) for bytes and EOS."""

    h = teacher.states
    return tuple(
        tuple(
            tuple(teacher.emission[i][symbol] * teacher.transition[i][j] for j in range(h))
            for i in range(h)
        )
        for symbol in range(ALPHABET)
    )


def stationary_vector(transition: Matrix, iterations: int = 2048) -> Vector:
    """Deterministic stationary posterior used only as a diagnostic baseline."""

    h = _check_matrix(transition)
    q = tuple(1.0 / h for _ in range(h))
    for _ in range(iterations):
        nxt = row_times_matrix(q, transition)
        if max(abs(nxt[i] - q[i]) for i in range(h)) < 1e-15:
            return vector_normalize(nxt)
        q = vector_normalize(nxt)
    return vector_normalize(q)


def _row_normalized(matrix: Matrix) -> tuple[Vector, ...]:
    rows: list[Vector] = []
    for row in matrix:
        total = sum(row)
        if total <= 0.0 or not math.isfinite(total):
            raise ValueError("operator has an impossible incoming row")
        rows.append(tuple(x / total for x in row))
    return tuple(rows)


def row_dispersion(matrix: Matrix) -> float:
    """Maximum total-variation distance between row-normalized rows."""

    rows = _row_normalized(matrix)
    result = 0.0
    for i, left in enumerate(rows):
        for right in rows[i + 1 :]:
            result = max(result, 0.5 * sum(abs(a - b) for a, b in zip(left, right)))
    return result


def best_shared_posterior(matrix: Matrix) -> Vector:
    """r-weighted row average; one normalized posterior for this fragment."""

    rows = _row_normalized(matrix)
    weights = matrix_row_sums(matrix)
    total = sum(weights)
    return vector_normalize(
        [sum(weights[i] * rows[i][j] for i in range(len(rows))) / total for j in range(len(rows))]
    )


def rank_estimate(matrix: Matrix, relative_tolerance: float = 1e-12) -> int:
    """Small, dependency-free numerical row rank estimate via Gram--Schmidt."""

    basis: list[list[float]] = []
    scale = max((math.sqrt(sum(x * x for x in row)) for row in matrix), default=0.0)
    if scale == 0.0:
        return 0
    threshold = scale * relative_tolerance
    for row in matrix:
        residual = list(row)
        for direction in basis:
            projection = sum(a * b for a, b in zip(residual, direction))
            for j in range(len(residual)):
                residual[j] -= projection * direction[j]
        norm = math.sqrt(sum(x * x for x in residual))
        if norm > threshold:
            basis.append([x / norm for x in residual])
    return len(basis)


def rank_one_residual(matrix: Matrix, shared: Vector) -> float:
    """Relative Frobenius residual after M ~= r * shared^T."""

    rows = matrix_row_sums(matrix)
    residual = 0.0
    norm = 0.0
    for i, row in enumerate(matrix):
        for j, value in enumerate(row):
            approximation = rows[i] * shared[j]
            residual += (value - approximation) ** 2
            norm += value * value
    return math.sqrt(residual / norm) if norm > 0.0 else 0.0


def cross_ratio_log_diameter(matrix: Matrix) -> float | None:
    """Return finite Birkhoff cross-ratio diameter, or None when invalid.

    For each row pair i,j, max_{k,l} log(Mik*Mjl/(Mil*Mjk)) is the largest
    log row-ratio minus the smallest log row-ratio, so this is O(H^3), not
    O(H^4).  Zeros make the projective diameter infinite and are reported as
    unavailable rather than silently clipped.
    """

    h = _check_matrix(matrix)
    if any(value <= 0.0 for row in matrix for value in row):
        return None
    result = 0.0
    for i in range(h):
        for j in range(i + 1, h):
            ratios = [math.log(matrix[i][k]) - math.log(matrix[j][k]) for k in range(h)]
            result = max(result, max(ratios) - min(ratios))
    return result


def fragment_metrics(matrix: Matrix) -> dict[str, float | int | None | list[float]]:
    shared = best_shared_posterior(matrix)
    delta = cross_ratio_log_diameter(matrix)
    tau = None if delta is None else math.tanh(delta / 4.0)
    return {
        "row_dispersion_tv": row_dispersion(matrix),
        "rank_estimate": rank_estimate(matrix),
        "rank1_relative_frobenius": rank_one_residual(matrix, shared),
        "cross_ratio_log_diameter": delta,
        "birkhoff_tau": tau,
        "row_sums": list(matrix_row_sums(matrix)),
        "r": list(matrix_row_sums(matrix)),
        "v": list(shared),
    }


@dataclass(frozen=True)
class Phrase:
    symbols: tuple[int, ...]
    surface: bytes
    kind: str


class _TrieNode:
    __slots__ = ("children", "phrase")

    def __init__(self) -> None:
        self.children: dict[int, _TrieNode] = {}
        self.phrase: tuple[int, ...] | None = None


def _insert_candidate(root: _TrieNode, word: bytes) -> bool:
    node = root
    path: list[int] = []
    for value in word:
        if node.phrase is not None:
            return False
        path.append(value)
        node = node.children.setdefault(value, _TrieNode())
    if node.phrase is not None or node.children:
        return False
    node.phrase = tuple(path)
    return True


def make_candidates(data: bytes, *, limit: int = 8, max_len: int = 12) -> list[bytes]:
    """Frequent whitespace-delimited spans, with deterministic prefix policy."""

    counts = collections.Counter(token for token in data.split() if 2 <= len(token) <= max_len)
    ordered = sorted(counts, key=lambda token: (-counts[token], -len(token), token))
    result: list[bytes] = []
    for token in ordered:
        if any(token.startswith(previous) or previous.startswith(token) for previous in result):
            continue
        result.append(token)
        if len(result) >= limit:
            break
    return result


def make_morpheme_proxy(data: bytes, *, limit: int = 8, max_len: int = 6) -> list[bytes]:
    """Frequent byte substrings; intentionally not a linguistic analyzer."""

    counts: collections.Counter[bytes] = collections.Counter()
    for token in data.split():
        if len(token) < 2:
            continue
        for width in range(2, min(max_len, len(token)) + 1):
            for at in range(len(token) - width + 1):
                fragment = token[at : at + width]
                counts[fragment] += 1
    ordered = sorted(counts, key=lambda token: (-counts[token], -len(token), token))
    return ordered[:limit]


def complete_prefix_code(candidates: Sequence[bytes]) -> tuple[Phrase, ...]:
    """Expand finite candidate paths into a complete byte+EOS prefix code.

    Candidate leaves are exact byte phrases.  At every internal node a
    ``prefix+EOS`` leaf handles the final partial phrase.  Missing byte
    siblings are one-leaf fallback phrases.  The returned ordering is by
    symbol sequence and is prefix-free by construction.
    """

    root = _TrieNode()
    accepted: list[bytes] = []
    for candidate in sorted(set(candidates), key=lambda value: (len(value), value)):
        if candidate and _insert_candidate(root, candidate):
            accepted.append(candidate)
    phrases: list[Phrase] = []

    def walk(node: _TrieNode, prefix: tuple[int, ...]) -> None:
        if node.phrase is not None:
            phrases.append(Phrase(prefix, bytes(prefix), "candidate"))
            return
        # EOS is a terminal leaf at every internal node.  It is the root EOS
        # phrase when prefix is empty, and the final-partial fallback otherwise.
        phrases.append(Phrase(prefix + (EOS,), bytes(prefix), "eos" if not prefix else "terminal"))
        for symbol in range(256):
            child = node.children.get(symbol)
            if child is None:
                surface = bytes(prefix + (symbol,))
                phrases.append(Phrase(prefix + (symbol,), surface, "fallback"))
            else:
                walk(child, prefix + (symbol,))

    walk(root, ())
    phrases.sort(key=lambda phrase: phrase.symbols)
    if not phrases:
        raise AssertionError("complete codebook is empty")
    # Internal validation: no two words may have a prefix relation.
    for left, right in zip(phrases, phrases[1:]):
        if right.symbols[: len(left.symbols)] == left.symbols:
            raise AssertionError("prefix-code expansion is ambiguous")
    return tuple(phrases)


def parse_codebook(phrases: Sequence[Phrase], symbols: Sequence[int]) -> list[int]:
    """Parse symbols through a prefix code and return phrase indices."""

    by_symbols = {phrase.symbols: i for i, phrase in enumerate(phrases)}
    prefixes = {
        phrase.symbols[:at]
        for phrase in phrases
        for at in range(1, len(phrase.symbols) + 1)
    }
    # Prefix-free phrase lookup by incrementally growing a tuple is adequate
    # for this bounded probe and makes final-EOS semantics explicit.
    output: list[int] = []
    current: list[int] = []
    for symbol in symbols:
        current.append(int(symbol))
        key = tuple(current)
        if key in by_symbols:
            output.append(by_symbols[key])
            current.clear()
        elif key not in prefixes:
            raise ValueError(f"symbol stream is outside complete codebook near {key!r}")
    if current:
        raise ValueError("input ended without terminal EOS phrase")
    return output


def _quantiles(values: Sequence[float]) -> dict[str, float | None]:
    if not values:
        return {"min": None, "mean": None, "p50": None, "p95": None, "max": None}
    ordered = sorted(values)
    def at(frac: float) -> float:
        return ordered[min(len(ordered) - 1, int(frac * (len(ordered) - 1)))]
    return {
        "min": ordered[0],
        "mean": sum(ordered) / len(ordered),
        "p50": at(0.50),
        "p95": at(0.95),
        "max": ordered[-1],
    }


def summarize_metrics(metrics: Sequence[dict[str, float | int | None | list[float]]]) -> dict[str, object]:
    dispersions = [float(m["row_dispersion_tv"]) for m in metrics]
    residuals = [float(m["rank1_relative_frobenius"]) for m in metrics]
    taus = [float(m["birkhoff_tau"]) for m in metrics if m["birkhoff_tau"] is not None]
    deltas = [float(m["cross_ratio_log_diameter"]) for m in metrics if m["cross_ratio_log_diameter"] is not None]
    ranks = collections.Counter(int(m["rank_estimate"]) for m in metrics)
    return {
        "count": len(metrics),
        "row_dispersion_tv": _quantiles(dispersions),
        "rank1_relative_frobenius": _quantiles(residuals),
        "cross_ratio_log_diameter": _quantiles(deltas),
        "birkhoff_tau": _quantiles(taus),
        "rank_estimate_counts": {str(k): v for k, v in sorted(ranks.items())},
    }


def cumulative_mass_vectors(metrics: Sequence[dict[str, float | int | None | list[float]]]) -> tuple[Vector, ...]:
    """Precompute R_k = sum_{w<k} M_w 1 from each phrase's r vector."""

    if not metrics:
        return ()
    h = len(metrics[0]["r"])  # type: ignore[arg-type]
    running = [0.0] * h
    result: list[Vector] = []
    for metric in metrics:
        for i, value in enumerate(metric["r"]):  # type: ignore[index]
            running[i] += float(value)
        result.append(tuple(running))
    return tuple(result)


def cdf_values(q: Sequence[float], cumulative: Sequence[Vector]) -> list[float]:
    return [0.0] + [sum(q[i] * boundary[i] for i in range(len(q))) for boundary in cumulative]


def binary_search_cdf(cdf: Sequence[float], target: float) -> int:
    if not cdf or target < cdf[0] or target >= cdf[-1] + 1e-15:
        raise ValueError("CDF target outside range")
    lo, hi = 0, len(cdf) - 1
    while lo + 1 < hi:
        mid = (lo + hi) // 2
        if cdf[mid] <= target:
            lo = mid
        else:
            hi = mid
    return min(lo, len(cdf) - 2)


def binary_search_cumulative_vectors(
    q: Sequence[float], cumulative: Sequence[Vector], target: float
) -> int:
    """Find a phrase with O(H log P) dot products from cached ``R_k``.

    ``cumulative[k]`` is the boundary after phrase ``k``.  We deliberately do
    not materialize every scalar CDF value here; only the binary-search
    boundaries are evaluated.  This is the optimization a phrase decoder can
    use after one-time operator preparation.
    """

    if not cumulative:
        raise ValueError("empty cumulative codebook")
    total = sum(q[i] * cumulative[-1][i] for i in range(len(q)))
    if target < 0.0 or target >= total + 1e-15:
        raise ValueError("CDF target outside range")
    lo, hi = 0, len(cumulative)
    while lo < hi:
        mid = (lo + hi) // 2
        boundary = sum(q[i] * cumulative[mid][i] for i in range(len(q)))
        if boundary <= target:
            lo = mid + 1
        else:
            hi = mid
    return min(lo, len(cumulative) - 1)


def validate_cdf(
    metrics: Sequence[dict[str, float | int | None | list[float]]],
    q: Sequence[float],
) -> dict[str, float | int | bool]:
    cumulative = cumulative_mass_vectors(metrics)
    cdf = cdf_values(q, cumulative)
    direct = [0.0]
    for metric in metrics:
        direct.append(direct[-1] + sum(q[i] * float(metric["r"][i]) for i in range(len(q))))  # type: ignore[index]
    max_error = max(abs(a - b) for a, b in zip(cdf, direct))
    # Use deterministic interior points and compare binary-search index to
    # direct linear lookup, exercising the O(H log P) query path.
    checks = 0
    mismatches = 0
    optimized_mismatches = 0
    for index in range(min(31, max(0, len(metrics)))):
        lower, upper = cdf[index], cdf[index + 1]
        target = lower + (upper - lower) * 0.37
        chosen = binary_search_cdf(cdf, target)
        optimized = binary_search_cumulative_vectors(q, cumulative, target)
        linear = max(0, min(len(metrics) - 1, next((j for j in range(len(metrics)) if cdf[j + 1] > target), len(metrics) - 1)))
        mismatches += int(chosen != linear)
        optimized_mismatches += int(optimized != linear)
        checks += 1
    return {
        "row_sum": cdf[-1],
        "direct_row_sum": direct[-1],
        "max_cdf_error": max_error,
        "binary_checks": checks,
        "binary_mismatches": mismatches,
        "optimized_binary_mismatches": optimized_mismatches,
        "ok": max_error <= 1e-8 and abs(cdf[-1] - 1.0) <= 1e-7 and mismatches == 0 and optimized_mismatches == 0,
    }


def _finite(value: float) -> float:
    return value if math.isfinite(value) else 1e300


def rollout(
    teacher: HMMTeacher,
    phrases: Sequence[Phrase],
    phrase_indices: Sequence[int],
    matrices: Sequence[Matrix],
    metrics: Sequence[dict[str, float | int | None | list[float]]],
    threshold: float,
) -> dict[str, float | int | bool]:
    """Run exact and closed approximate belief recurrences on one phrase path."""

    h = teacher.states
    exact_q = teacher.initial
    approx_q = teacher.initial
    exact_bits = 0.0
    approx_bits = 0.0
    resets = 0
    max_probability_error = 0.0
    for phrase_index in phrase_indices:
        matrix = matrices[phrase_index]
        metric = metrics[phrase_index]
        r = tuple(float(x) for x in metric["r"])  # type: ignore[arg-type]
        v = tuple(float(x) for x in metric["v"])  # type: ignore[arg-type]
        exact_mass_vec = row_times_matrix(exact_q, matrix)
        exact_p = sum(exact_mass_vec)
        exact_q = vector_normalize(exact_mass_vec)
        approx_p = sum(approx_q[i] * r[i] for i in range(h))
        exact_bits += -math.log2(max(exact_p, 1e-300))
        approx_bits += -math.log2(max(approx_p, 1e-300))
        max_probability_error = max(max_probability_error, abs(approx_p - exact_p))
        reset = float(metric["row_dispersion_tv"]) <= (1e-15 if threshold == 0.0 else threshold)
        if reset:
            resets += 1
            approx_q = vector_normalize(v)
        else:
            approx_q = vector_normalize(row_times_matrix(approx_q, matrix))
    return {
        "phrases": len(phrase_indices),
        "resets": resets,
        "reset_fraction": resets / len(phrase_indices) if phrase_indices else 0.0,
        "exact_teacher_bits": exact_bits,
        "closed_approx_bits": approx_bits,
        "excess_bits": approx_bits - exact_bits,
        "exact_bits_per_input_symbol": exact_bits / max(1, sum(len(phrases[i].surface) for i in phrase_indices)),
        "closed_bits_per_input_symbol": approx_bits / max(1, sum(len(phrases[i].surface) for i in phrase_indices)),
        "max_probability_error": max_probability_error,
        "roundtrip_path_is_deterministic": True,
    }


def serialize_operator_model(
    teacher_states: int,
    phrases: Sequence[Phrase],
    matrices: Sequence[Matrix],
    metrics: Sequence[dict[str, float | int | None | list[float]]],
    threshold: float,
) -> tuple[int, int, int]:
    """Build a real uncompressed diagnostic model blob and return its sizes.

    The blob is not an archive.  It deliberately stores every phrase symbol,
    flag, length and coefficient as little-endian float64 so the reported
    serialized cost cannot be mistaken for an entropy estimate.
    """

    exact_count = 0
    reset_count = 0
    blob = bytearray(struct.pack("<4sHHdI", b"OPR1", teacher_states, len(phrases), threshold, 0))
    for phrase, matrix, metric in zip(phrases, matrices, metrics):
        reset = float(metric["row_dispersion_tv"]) <= (1e-15 if threshold == 0.0 else threshold)
        blob.extend(struct.pack("<BH", 1 if reset else 0, len(phrase.symbols)))
        blob.extend(struct.pack("<" + "H" * len(phrase.symbols), *phrase.symbols))
        if reset:
            reset_count += 1
            values = tuple(float(x) for x in metric["r"]) + tuple(float(x) for x in metric["v"])  # type: ignore[arg-type]
        else:
            exact_count += 1
            values = tuple(value for row in matrix for value in row)
        blob.extend(struct.pack("<" + "d" * len(values), *values))
    derived_coefficients = exact_count * teacher_states * teacher_states * 8 + reset_count * teacher_states * 2 * 8
    return len(blob), derived_coefficients, reset_count


def inventory_report(
    teacher: HMMTeacher,
    inventory_name: str,
    phrases: Sequence[Phrase],
    operators: Sequence[Matrix],
    target: bytes | None = None,
    candidate_count: int = 0,
) -> dict[str, object]:
    metrics = [fragment_metrics(matrix) for matrix in operators]
    report: dict[str, object] = {
        "inventory": inventory_name,
        "phrase_count": len(phrases),
        "candidate_count": candidate_count,
        "surface_bytes": sum(len(phrase.surface) for phrase in phrases),
        "metrics": summarize_metrics(metrics),
    }
    if inventory_name != "complete_prefix":
        report["normalized_codebook"] = False
        report["normalization_note"] = "overlapping diagnostic inventory; do not treat phrase masses as a source"
        return report
    row_count = teacher.states
    row_errors = [
        abs(sum(float(metric["r"][i]) for metric in metrics) - 1.0)  # type: ignore[index]
        for i in range(row_count)
    ]
    report["normalized_codebook"] = True
    report["complete_codebook_max_row_mass_error"] = max(row_errors, default=0.0)
    cumulative = cumulative_mass_vectors(metrics)
    report["cdf"] = validate_cdf(metrics, teacher.initial)
    report["final_partial_phrase_rule"] = "internal prefix + EOS terminal leaf; exact candidate leaf then root EOS"
    report["phrase_kind_counts"] = dict(collections.Counter(phrase.kind for phrase in phrases))
    if target is not None:
        phrase_indices = parse_codebook(phrases, tuple(target) + (EOS,))
        # Product of phrase operators must match the direct teacher path.
        q = teacher.initial
        direct_bits = 0.0
        byte_operators = edge_operators(teacher)
        for symbol in tuple(target) + (EOS,):
            mass = row_times_matrix(q, byte_operators[symbol])
            p = sum(mass)
            direct_bits += -math.log2(max(p, 1e-300))
            q = vector_normalize(mass)
        report["parsed_phrase_count"] = len(phrase_indices)
        report["direct_teacher_bits"] = direct_bits
        report["rollout"] = {}
        for threshold in RESET_THRESHOLDS:
            key = f"{threshold:.0e}" if threshold else "0"
            report["rollout"][key] = rollout(  # type: ignore[index]
                teacher, phrases, phrase_indices, operators, metrics, threshold
            )
        exact_phrase = report["rollout"]["0"]["exact_teacher_bits"]  # type: ignore[index]
        report["exact_phrase_vs_direct_abs_bits"] = abs(float(exact_phrase) - direct_bits)
        model_costs: dict[str, object] = {}
        for threshold in RESET_THRESHOLDS:
            key = f"{threshold:.0e}" if threshold else "0"
            serialized, derived, reset_count = serialize_operator_model(
                teacher.states, phrases, operators, metrics, threshold
            )
            exact_count = len(phrases) - reset_count
            model_costs[key] = {
                "reset_phrases": reset_count,
                "exact_phrases": exact_count,
                "serialized_model_bytes": serialized,
                "derived_coefficient_bytes": derived,
                "phrase_symbol_bytes_uncompressed": sum(2 * len(phrase.symbols) for phrase in phrases),
                "accounting_note": "diagnostic model blob only; no payload/archive/decode claim",
            }
        report["model_costs"] = model_costs
        report["prefix_parse_surface_bytes"] = sum(len(phrases[i].surface) for i in phrase_indices)
        report["prefix_parse_surface_matches_target"] = b"".join(phrases[i].surface for i in phrase_indices) == target
        report["cdf_cached_boundaries"] = len(cumulative)
    return report


def _baseline_report(case_dir: Path) -> dict[str, object]:
    dev_json = case_dir / "dev.json"
    if not dev_json.exists():
        return {}
    raw = json.loads(dev_json.read_text())
    out: dict[str, object] = {}
    if isinstance(raw.get("baseline_v4"), dict):
        frame = raw["baseline_v4"].get("frame", {})
        out["v4_bytes"] = frame.get("bytes")
        out["v4_sha256"] = frame.get("sha256")
    if isinstance(raw.get("baseline_bzip3"), dict):
        storage = raw["baseline_bzip3"].get("storage", {})
        out["bzip3_bytes"] = storage.get("total")
        out["bzip3_payload_bytes"] = storage.get("payload")
    return out


def run_case(case_dir: Path, limit: int) -> dict[str, object]:
    requested = case_dir / "teacher-k8.json"
    if requested.exists():
        teacher_path = requested
        teacher_requested = "k8"
    else:
        teachers = sorted(case_dir.glob("teacher-k*.json"), key=lambda p: int(p.stem.split("-k", 1)[1]))
        if not teachers:
            raise FileNotFoundError(f"no teacher in {case_dir}")
        teacher_path = teachers[-1]
        teacher_requested = "k8_missing_fallback_highest"
    train_path = case_dir / "train.bin"
    target_path = case_dir / "dev.target.bin"
    train = read_bounded(train_path, limit)
    target = read_bounded(target_path, limit)
    teacher = load_teacher(teacher_path)
    operators = edge_operators(teacher)
    words = make_candidates(train)
    morphemes = make_morpheme_proxy(train)
    complete = complete_prefix_code(words)
    word_ops = [matrix_fragment(operators, tuple(word), teacher.states) for word in words]
    morpheme_ops = [matrix_fragment(operators, tuple(fragment), teacher.states) for fragment in morphemes]
    complete_ops = [matrix_fragment(operators, phrase.symbols, teacher.states) for phrase in complete]
    return {
        "case": case_dir.name,
        "limit_bytes": limit,
        "train": {"path": str(train_path), "bytes": len(train), "sha256": sha256_path(train_path)},
        "target": {"path": str(target_path), "bytes": len(target), "sha256": sha256_path(target_path)},
        "teacher": {
            "requested": teacher_requested,
            "path": teacher.path,
            "bytes": teacher_path.stat().st_size,
            "sha256": teacher.sha256,
            "states": teacher.states,
        },
        "baseline_reference": _baseline_report(case_dir),
        "policy": {
            "word_candidate_limit": 8,
            "word_candidate_max_bytes": 12,
            "morpheme_proxy_limit": 8,
            "morpheme_proxy_max_bytes": 6,
            "reset_thresholds": list(RESET_THRESHOLDS),
            "shared_posterior": "r-weighted row average per fragment",
        },
        "inventories": {
            "word": inventory_report(teacher, "word", tuple(Phrase(tuple(word), word, "word") for word in words), word_ops),
            "morpheme_proxy": inventory_report(
                teacher,
                "morpheme_proxy",
                tuple(Phrase(tuple(fragment), fragment, "morpheme_proxy") for fragment in morphemes),
                morpheme_ops,
            ),
            "complete_prefix": inventory_report(
                teacher, "complete_prefix", complete, complete_ops, target, candidate_count=len(words)
            ),
        },
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    here = Path(__file__).resolve()
    default_root = here.parent.parent / "belief" / "runs" / "latent-belief-dev-20260926"
    parser.add_argument("--runs-root", type=Path, default=default_root)
    parser.add_argument("--out", type=Path, default=here.parent / "results.json")
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    args = parser.parse_args(argv)
    if args.limit <= 0 or args.limit > DEFAULT_LIMIT:
        parser.error(f"--limit must be in 1..{DEFAULT_LIMIT}")
    cases = [path for path in sorted(args.runs_root.iterdir()) if path.is_dir() and path.name.endswith("-eval8-64k")]
    if not cases:
        parser.error(f"no bounded eval cases under {args.runs_root}")
    result = {
        "schema": 1,
        "experiment": "forgetful_phrase_operators",
        "command": " ".join(sys.argv),
        "runs_root": str(args.runs_root),
        "read_policy": "stored teachers only; train.bin/dev.target.bin only; no untouched inputs",
        "cases": [run_case(case, args.limit) for case in cases],
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"out": str(args.out), "cases": [case["case"] for case in result["cases"]]}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
