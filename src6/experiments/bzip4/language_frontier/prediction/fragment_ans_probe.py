#!/usr/bin/env python3
"""Tiny exact probe for ANS, bits-back, and cached HMM fragments.

This is an accounting/proof artifact, not a production codec.  It uses the
exact edge-emitting source in ``../oracle/operators.py`` and answers a narrow
question: can an ANS integer by itself carry the posterior uncertainty of a
latent source, or does the decoder still need a belief/context table?

The probe reports four independently checkable facts:

* two histories ending in the same byte have different exact next-byte CDFs;
* a complete prefix-free macro codebook is normalized, but its phrase CDF
  still depends on the incoming belief;
* BB-ANS can remove the posterior-code term only after a posterior sample is
  seeded; without seed, the first item pays the joint code. A naive whole-path
  HMM posterior uses forward/backward, while state-space interleaving uses
  conditional posterior CDFs;
* a structured H=4 source has diagonal+rank-one byte operators, but products
  of two or three operators grow in residual rank, so factoring cached phrase
  operators does not reduce both model bytes and runtime work.

No bytes are claimed as a compressed result.  The output is a falsifiable
operation/model-size screen for a possible phrase-ANS implementation.
"""

from __future__ import annotations

import argparse
import math
import sys
from fractions import Fraction
from pathlib import Path
from typing import Iterable, Sequence


HERE = Path(__file__).resolve().parent
ORACLE = HERE.parent / "oracle"
if str(ORACLE) not in sys.path:
    sys.path.insert(0, str(ORACLE))

from operators import (  # type: ignore[import-not-found]  # noqa: E402
    Belief,
    Matrix,
    Source,
    advance,
    compose,
    identity,
    persistent_binary_source,
)


TOTAL = 1 << 14


def entropy(probabilities: Iterable[Fraction]) -> float:
    return -sum(float(p) * math.log2(float(p)) for p in probabilities if p)


def fraction_text(value: Fraction) -> str:
    return str(value.numerator) if value.denominator == 1 else f"{value.numerator}/{value.denominator}"


def quantized_count(probability: Fraction, total: int = TOTAL) -> int:
    """Nearest positive ANS frequency for a binary event."""

    count = (probability * total + Fraction(1, 2)).numerator // (probability * total + Fraction(1, 2)).denominator
    return max(1, min(total - 1, count))


def rank(matrix: Matrix) -> int:
    """Exact Gaussian rank for the tiny Fraction matrices in this probe."""

    rows = [list(row) for row in matrix]
    height = len(rows)
    width = len(rows[0]) if rows else 0
    pivot = 0
    for column in range(width):
        selected = next((row for row in range(pivot, height) if rows[row][column]), None)
        if selected is None:
            continue
        rows[pivot], rows[selected] = rows[selected], rows[pivot]
        scale = rows[pivot][column]
        rows[pivot] = [value / scale for value in rows[pivot]]
        for row in range(height):
            if row == pivot or not rows[row][column]:
                continue
            scale = rows[row][column]
            rows[row] = [left - scale * right for left, right in zip(rows[row], rows[pivot])]
        pivot += 1
    return pivot


def matmul(left: Matrix, right: Matrix) -> Matrix:
    size = len(left)
    return tuple(
        tuple(sum((left[i][k] * right[k][j] for k in range(size)), Fraction(0)) for j in range(size))
        for i in range(size)
    )


def matrix_sub(left: Matrix, right: Matrix) -> Matrix:
    return tuple(
        tuple(left[i][j] - right[i][j] for j in range(len(left))) for i in range(len(left))
    )


def terminal_vector(operator: Matrix) -> tuple[Fraction, ...]:
    """Return ``M_w 1``: phrase probabilities from each source state."""

    return tuple(sum(row, Fraction(0)) for row in operator)


def cumulative_terminal_vectors(
    operators: dict[bytes, Matrix], words: Sequence[bytes]
) -> tuple[tuple[Fraction, ...], ...]:
    """Build exact ``R_k = sum_{w<k} M_w 1`` vectors for phrase CDFs."""

    size = len(next(iter(operators.values())))
    running = [Fraction(0)] * size
    cumulative: list[tuple[Fraction, ...]] = []
    for word in words:
        for state, value in enumerate(terminal_vector(operators[word])):
            running[state] += value
        cumulative.append(tuple(running))
    return tuple(cumulative)


def phrase_cdf(
    belief: Belief, cumulative_vectors: Sequence[tuple[Fraction, ...]]
) -> tuple[Fraction, ...]:
    """Evaluate each phrase CDF entry as the H-lane dot product ``q R_k``."""

    return tuple(
        sum((q * value for q, value in zip(belief, vector)), Fraction(0))
        for vector in cumulative_vectors
    )


def diagonal_product(factors: Sequence[Matrix]) -> Matrix:
    size = len(factors[0])
    return tuple(
        tuple(
            (Fraction(1) if i == j else Fraction(0))
            * math.prod((factor[i][i] for factor in factors), start=Fraction(1))
            for j in range(size)
        )
        for i in range(size)
    )


def structured_h4() -> tuple[Source, dict[int, Matrix], dict[int, Matrix]]:
    """Return M_b = diag(e_b) (alpha I + beta 11^T/H).

    Each byte matrix is exactly diagonal plus rank one.  Products retain the
    diagonal product plus a residual whose rank grows with phrase length.
    """

    size = 4
    alpha = Fraction(3, 4)
    beta = 1 - alpha
    transition = tuple(
        tuple(alpha * (i == j) + beta / size for j in range(size)) for i in range(size)
    )
    emission_prob = {
        ord("a"): (Fraction(9, 10), Fraction(7, 10), Fraction(3, 10), Fraction(1, 10)),
    }
    emission_prob[ord("b")] = tuple(1 - value for value in emission_prob[ord("a")])
    matrices: dict[int, Matrix] = {}
    diagonal_factors: dict[int, Matrix] = {}
    for byte, probabilities in emission_prob.items():
        diagonal_factors[byte] = tuple(
            tuple(alpha * probabilities[i] if i == j else Fraction(0) for j in range(size))
            for i in range(size)
        )
        matrices[byte] = tuple(
            tuple(probabilities[i] * transition[i][j] for j in range(size)) for i in range(size)
        )
    return Source(matrices), matrices, diagonal_factors


def print_uncertainty_proof(source: Source) -> None:
    initial: Belief = (Fraction(1, 2), Fraction(1, 2))
    rows = []
    for history in (b"aaaaa", b"bbbba"):
        _, belief = advance(initial, source.fragment(history))
        p_a, _ = advance(belief, source.emission[ord("a")])
        rows.append((history, belief, p_a))
    print("uncertainty_proof=same_last_byte_different_belief")
    for history, belief, probability in rows:
        print(
            f"history={history!r} belief=({fraction_text(belief[0])},{fraction_text(belief[1])}) "
            f"p_next_a={fraction_text(probability)} p_next_a_bits={-math.log2(float(probability)):.9f}"
        )
    first, second = rows[0][2], rows[1][2]
    if first == second:
        raise AssertionError("the oracle source failed to distinguish predictive beliefs")
    print(f"next_a_total_variation={float(abs(first - second)):.9f}")
    print(f"ans_freq_a_total={TOTAL} history1={quantized_count(first)} history2={quantized_count(second)}")
    print("conclusion=one_context_free_ans_cdf_cannot_be_exact_for_both_histories")


def print_phrase_report(source: Source) -> None:
    words = (b"a", b"ba", b"bba", b"bbb")
    operators = source.codebook(words)
    cumulative_vectors = cumulative_terminal_vectors(operators, words)
    beliefs: tuple[tuple[str, Belief], ...] = (
        ("uniform", (Fraction(1, 2), Fraction(1, 2))),
        ("biased", (Fraction(4, 5), Fraction(1, 5))),
    )
    print("phrase_codebook=complete_prefix_free words=a,ba,bba,bbb")
    for name, belief in beliefs:
        probabilities = tuple(advance(belief, operators[word])[0] for word in words)
        expected_length = sum(probability * len(word) for probability, word in zip(probabilities, words))
        fixed_bits_per_byte = math.ceil(math.log2(len(words))) / float(expected_length)
        entropy_bits_per_byte = entropy(probabilities) / float(expected_length)
        print(
            f"phrase_belief={name} probabilities="
            f"{','.join(fraction_text(value) for value in probabilities)} "
            f"sum={fraction_text(sum(probabilities))} expected_len={float(expected_length):.9f} "
            f"fixed_id_bpb={fixed_bits_per_byte:.9f} entropy_id_bpb={entropy_bits_per_byte:.9f}"
        )
        cdf = phrase_cdf(belief, cumulative_vectors)
        differences = tuple(
            cdf[index] - (cdf[index - 1] if index else 0) for index in range(len(cdf))
        )
        if differences != probabilities:
            raise AssertionError("cached cumulative phrase vectors disagree with operator probabilities")
        if cdf[-1] != 1:
            raise AssertionError("complete phrase codebook did not produce a unit CDF")
        print(f"phrase_cdf_{name}={','.join(fraction_text(value) for value in cdf)}")
    uniform = tuple(advance(beliefs[0][1], operators[word])[0] for word in words)
    biased = tuple(advance(beliefs[1][1], operators[word])[0] for word in words)
    total_variation = sum(abs(a - b) for a, b in zip(uniform, biased)) / 2
    print(f"phrase_id_total_variation={float(total_variation):.9f}")
    print(
        "phrase_runtime_tradeoff="
        "cache_r_w=M_w1_and_cumulative_R_k; exact_phrase_cdf_needs_P_H_dot_products "
        "(or_H_logP_inverse_search)_plus_one_selected_H2_posterior_matvec "
        "unless_belief_context_rows_are_precompiled"
    )
    uniform_length = sum(
        advance(beliefs[0][1], operators[word])[0] * len(word) for word in words
    )
    print(
        f"uniform_phrase_lookup_rate_per_byte={float(1 / uniform_length):.9f} "
        f"cached_selected_H2_matvec_per_byte={float(1 / uniform_length):.9f} "
        f"exact_phrase_cdf_H_dot_products_per_byte={float(len(words) / uniform_length):.9f}"
    )


def print_bits_back_report(source: Source) -> None:
    initial: Belief = (Fraction(1, 2), Fraction(1, 2))
    joint: list[list[Fraction]] = []
    for byte in (ord("a"), ord("b")):
        joint.append([
            sum(initial[i] * source.emission[byte][i][j] for i in range(2))
            for j in range(2)
        ])
    observed = [sum(row) for row in joint]
    latent = [sum(joint[observed_byte][j] for observed_byte in range(2)) for j in range(2)]
    conditional_latent_entropy = 0.0
    joint_entropy = 0.0
    for observed_byte, row in enumerate(joint):
        p_observed = observed[observed_byte]
        posterior = [value / p_observed for value in row]
        conditional_latent_entropy += float(p_observed) * entropy(posterior)
        joint_entropy += -sum(float(value) * math.log2(float(value)) for value in row if value)
    observed_entropy = entropy(observed)
    latent_entropy = entropy(latent)
    mutual_information = observed_entropy + latent_entropy - joint_entropy
    print("bits_back_one_symbol=latent_destination_state")
    print(
        f"observed_entropy={observed_entropy:.9f} latent_entropy={latent_entropy:.9f} "
        f"posterior_seed_entropy={conditional_latent_entropy:.9f} joint_entropy={joint_entropy:.9f} "
        f"mutual_information={mutual_information:.9f}"
    )
    print(
        "bits_back_tradeoff="
        "exact_posterior_seed_subtracts_H(Z|B); zero_seed_first_item_pays_joint="
        f"{joint_entropy:.9f}_bits_vs_marginal_{observed_entropy:.9f}_bits; "
        f"initial_overhead={conditional_latent_entropy:.9f}_bits"
    )
    print(
        "hmm_inference_ops="
        "vanilla_predictive_ans_needs_forward_filter_n_H2_products; full_path_posterior_needs_forward_backward, "
        "but_IconoCLaSM_interleaves_state_posterior_and_needs_Q_conditional_CDFs"
    )


def print_factor_report() -> None:
    source, matrices, diagonal_factors = structured_h4()
    words = (b"a", b"ba", b"bba", b"bbb")
    print("factor_source=H4_Mb=diag(emission_b)(alpha_I+beta_ones/H)")
    for byte in (ord("a"), ord("b")):
        matrix = matrices[byte]
        diagonal = diagonal_factors[byte]
        print(f"byte={chr(byte)} full_rank={rank(matrix)} residual_rank_after_exact_diagonal_plus_rank1={rank(matrix_sub(matrix, diagonal))}")
    full_storage = 0
    factored_storage = 0
    full_runtime = 0
    factored_runtime = 0
    for word in words:
        factors = [matrices[byte] for byte in word]
        operator = source.fragment(word)
        diagonal = diagonal_product([diagonal_factors[byte] for byte in word])
        residual_rank = rank(matrix_sub(operator, diagonal))
        full_coefficients = 4 * 4
        factored_coefficients = 4 + 2 * 4 * residual_rank
        full_storage += full_coefficients
        factored_storage += factored_coefficients
        full_runtime += 4 * 4
        factored_runtime += 4 + 2 * 4 * residual_rank
        print(
            f"word={word!r} length={len(word)} operator_rank={rank(operator)} "
            f"residual_rank={residual_rank} full_coefficients={full_coefficients} "
            f"diag_lowrank_coefficients={factored_coefficients}"
        )
    print(
        f"factor_totals=full_coefficients={full_storage} diag_lowrank_coefficients={factored_storage} "
        f"full_matvec_ops={full_runtime} diag_lowrank_ops={factored_runtime}"
    )
    if factored_storage <= full_storage:
        raise AssertionError("this structured probe was expected to expose phrase factor growth")
    print(
        "factor_conclusion=rank1_byte_factor_is_exact_but_phrase_products_grow_to_rank3; "
        "no_model_and_runtime_win_for_cached_lengths_1,2,3,3"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--length", type=int, default=32, help="sequence length for operation-accounting notes")
    args = parser.parse_args()
    if args.length < 1:
        raise SystemExit("--length must be positive")
    source = persistent_binary_source()
    print(f"probe=fragment_ans_bitsback length={args.length} total={TOTAL}")
    print_uncertainty_proof(source)
    print_phrase_report(source)
    print_bits_back_report(source)
    print_factor_report()
    print(
        f"operation_accounting=H2_current_exact_filter_muladds={args.length * 4} "
        f"H4_current_exact_filter_muladds={args.length * 16} "
        f"H4_full_path_forward_backward_muladds={(2 * args.length - 1) * 16}"
    )
    print("validation=oracle_algebra_exact_not_compressed_frame")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
