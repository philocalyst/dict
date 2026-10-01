#!/usr/bin/env python3
"""Exact-byte shared generative-set screen.

The model represents a lexicon as a set of generated forms rather than a
parent edge for every form.  A signature is a fixed byte template with one
stem argument (prefix+suffix or repeated argument) or two arguments separated
by fixed bytes.  Sparse occupied argument tuples are charged explicitly, as
are raw exceptions, stems, signatures, lexicon-order permutations, occurrence
ranks, framing, and CRC.

This is a bounded capability gate.  It is intentionally independent of the
production bz4 wire format and does not claim that a signature is a gold
morphological analysis.
"""

from __future__ import annotations

import argparse
import collections
import dataclasses
import hashlib
import json
import pathlib
import struct
import sys
import zlib
from typing import Iterable, Sequence

import screen


MAGIC = b"PGS1"
MODE = 0
MAX_OUTPUT_DEFAULT = 1 << 20
MIN_STEM = 2
MAX_FIXED = 8
MAX_REPEAT_MIDDLE = 8
MAX_TWO_STEM = 16


@dataclasses.dataclass(frozen=True)
class Signature:
    """A fixed byte context around one or two generated arguments."""

    kind: int  # 1 affix, 2 repeated argument, 3 two-hole
    literals: tuple[bytes, ...]

    @property
    def arity(self) -> int:
        return 2 if self.kind == 3 else 1

    def apply(self, args: Sequence[bytes]) -> bytes:
        if len(args) != self.arity:
            raise ValueError("signature arity mismatch")
        if self.kind == 1:
            return self.literals[0] + args[0] + self.literals[1]
        if self.kind == 2:
            return self.literals[0] + args[0] + self.literals[1] + args[0] + self.literals[2]
        if self.kind == 3:
            return self.literals[0] + args[0] + self.literals[1] + args[1] + self.literals[2]
        raise ValueError("bad signature kind")


@dataclasses.dataclass(frozen=True)
class Candidate:
    signature: Signature
    args: tuple[bytes, ...]


def sig_key(signature: Signature) -> tuple[object, ...]:
    return (signature.kind, tuple(signature.literals))


def _add_candidate(out: dict[Signature, tuple[bytes, ...]], signature: Signature, args: tuple[bytes, ...]) -> None:
    if any(len(arg) < MIN_STEM for arg in args):
        return
    out.setdefault(signature, args)


def enumerate_candidates(word: bytes) -> list[Candidate]:
    """Enumerate a bounded, deterministic family of productive templates.

    Affix candidates are limited to eight literal bytes at either edge.  The
    repeated-argument and two-hole families use short fixed contexts, which
    prevents an all-splits quadratic search from becoming a hidden oracle.
    """

    n = len(word)
    found: dict[Signature, tuple[bytes, ...]] = {}

    # CONTROL: one contiguous stem with fixed prefix and suffix.
    for prefix_len in range(min(MAX_FIXED, n) + 1):
        max_suffix = min(MAX_FIXED, n - prefix_len - MIN_STEM)
        for suffix_len in range(max_suffix + 1):
            end = n - suffix_len
            if end - prefix_len < MIN_STEM:
                continue
            if prefix_len == 0 and suffix_len == 0:
                continue
            signature = Signature(1, (word[:prefix_len], word[end:]))
            _add_candidate(found, signature, (word[prefix_len:end],))

    # MAIN CANDIDATE: one repeated argument with fixed contexts.
    for prefix_len in range(min(MAX_FIXED, n) + 1):
        for suffix_len in range(min(MAX_FIXED, n - prefix_len) + 1):
            core_end = n - suffix_len
            for stem_len in range(MIN_STEM, min(MAX_TWO_STEM, (core_end - prefix_len) // 2) + 1):
                max_middle = core_end - prefix_len - 2 * stem_len
                if max_middle < 1:
                    continue
                for middle_len in range(1, min(MAX_REPEAT_MIDDLE, max_middle) + 1):
                    second = prefix_len + stem_len + middle_len
                    if word[prefix_len : prefix_len + stem_len] != word[second : second + stem_len]:
                        continue
                    signature = Signature(2, (word[:prefix_len], word[prefix_len + stem_len : second], word[core_end:]))
                    _add_candidate(found, signature, (word[prefix_len : prefix_len + stem_len],))

    # TWO-HOLE: two independent stems with a short fixed middle/context.
    # This supports noncontiguous composition without smuggling a parent ID.
    for prefix_len in range(min(4, n) + 1):
        for suffix_len in range(min(4, n - prefix_len) + 1):
            core = word[prefix_len : n - suffix_len]
            if len(core) < 2 * MIN_STEM + 1:
                continue
            for first_len in range(MIN_STEM, min(MAX_TWO_STEM, len(core)) + 1):
                max_second = min(MAX_TWO_STEM, len(core) - first_len - 1)
                for second_len in range(MIN_STEM, max_second + 1):
                    middle = core[first_len : len(core) - second_len]
                    if not (1 <= len(middle) <= MAX_REPEAT_MIDDLE):
                        continue
                    signature = Signature(3, (word[:prefix_len], middle, word[n - suffix_len :] if suffix_len else b""))
                    _add_candidate(signature=signature, args=(core[:first_len], core[-second_len:]), out=found)

    return [Candidate(signature, args) for signature, args in sorted(found.items(), key=lambda item: sig_key(item[0]))]


@dataclasses.dataclass
class Assignment:
    words: list[bytes]
    signatures: list[Signature]
    groups: list[list[tuple[bytes, ...]]]
    exceptions: list[bytes]
    stems: list[bytes]


def choose_assignments(words: Sequence[bytes]) -> Assignment:
    """Choose by frozen support/rule order, not by measured byte savings."""

    all_candidates = [enumerate_candidates(word) for word in words]
    supports: collections.Counter[Signature] = collections.Counter()
    for candidates in all_candidates:
        supports.update({candidate.signature for candidate in candidates})

    selected: list[Candidate | None] = []
    for candidates in all_candidates:
        eligible = [candidate for candidate in candidates if supports[candidate.signature] >= 2]
        eligible.sort(
            key=lambda candidate: (
                -supports[candidate.signature],
                candidate.signature.kind,
                sum(len(piece) for piece in candidate.signature.literals),
                sig_key(candidate.signature),
                candidate.args,
            )
        )
        selected.append(eligible[0] if eligible else None)

    grouped: dict[Signature, list[tuple[bytes, ...]]] = collections.defaultdict(list)
    exceptions: list[bytes] = []
    for word, candidate in zip(words, selected):
        if candidate is None:
            exceptions.append(word)
            continue
        if candidate.signature.apply(candidate.args) != word:
            raise AssertionError("candidate does not generate target")
        grouped[candidate.signature].append(candidate.args)

    # A support threshold is applied again after per-word selection.  A
    # singleton group is not productive and is charged as an exception.
    productive: dict[Signature, list[tuple[bytes, ...]]] = {}
    for signature, args in grouped.items():
        if len(args) >= 2:
            productive[signature] = sorted(args)
        else:
            exceptions.extend(signature.apply(arg) for arg in args)
    signatures = sorted(productive, key=sig_key)
    groups = [productive[signature] for signature in signatures]
    stems = sorted({arg for group in groups for args in group for arg in args})
    return Assignment(list(words), signatures, groups, sorted(exceptions), stems)


def _write_bytes(out: bytearray, value: bytes) -> None:
    out.extend(screen.uvarint(len(value)))
    out.extend(value)


def _read_bytes(data: bytes, pos: int) -> tuple[bytes, int]:
    length, pos = screen.take_uvarint(data, pos)
    if length > len(data) - pos:
        raise ValueError("literal overrun")
    return data[pos : pos + length], pos + length


def _write_signature(out: bytearray, signature: Signature) -> None:
    out.append(signature.kind)
    out.extend(screen.uvarint(len(signature.literals)))
    for literal in signature.literals:
        _write_bytes(out, literal)


def _read_signature(data: bytes, pos: int) -> tuple[Signature, int]:
    if pos >= len(data):
        raise ValueError("truncated signature")
    kind = data[pos]
    pos += 1
    literal_count, pos = screen.take_uvarint(data, pos)
    expected = {1: 2, 2: 3, 3: 3}.get(kind)
    if expected is None or literal_count != expected:
        raise ValueError("bad signature arity")
    literals: list[bytes] = []
    for _ in range(literal_count):
        literal, pos = _read_bytes(data, pos)
        literals.append(literal)
    return Signature(kind, tuple(literals)), pos


def _write_sparse_args(out: bytearray, group: Sequence[tuple[int, ...]], stem_count: int) -> None:
    if not group:
        raise ValueError("empty productive group")
    arity = len(group[0])
    if arity == 2:
        previous_rank = -1
        for first, second in group:
            rank = first * stem_count + second
            if rank < previous_rank:
                raise ValueError("sparse tuples not sorted")
            out.extend(screen.uvarint(rank - previous_rank - 1))
            previous_rank = rank
        return
    previous = [-1] * arity
    for args in group:
        if len(args) != arity or any(value < 0 for value in args):
            raise ValueError("bad sparse argument tuple")
        for axis, value in enumerate(args):
            if value < previous[axis]:
                raise ValueError("sparse tuples not sorted")
            out.extend(screen.uvarint(value - previous[axis] - 1))
            previous[axis] = value


def _read_sparse_args(data: bytes, pos: int, count: int, arity: int, stem_count: int) -> tuple[list[tuple[int, ...]], int]:
    if arity == 2:
        previous_rank = -1
        result: list[tuple[int, ...]] = []
        for _ in range(count):
            delta, pos = screen.take_uvarint(data, pos)
            rank = previous_rank + delta + 1
            first, second = divmod(rank, stem_count)
            if first >= stem_count or second >= stem_count or rank <= previous_rank:
                raise ValueError("sparse pair ID out of range")
            result.append((first, second))
            previous_rank = rank
        return result, pos
    previous = [-1] * arity
    result: list[tuple[int, ...]] = []
    for _ in range(count):
        values: list[int] = []
        for axis in range(arity):
            delta, pos = screen.take_uvarint(data, pos)
            value = previous[axis] + delta + 1
            if value >= stem_count or value < previous[axis]:
                raise ValueError("sparse stem ID out of range")
            values.append(value)
            previous[axis] = value
        result.append(tuple(values))
    return result, pos


@dataclasses.dataclass
class GenerationStats:
    mode: str
    order: str
    header: int
    model: int
    signature_bytes: int
    stem_bytes: int
    occupancy_bytes: int
    exception_bytes: int
    permutation_bytes: int
    dictionary: int
    payload: int
    crc: int
    total: int
    words: int
    word_occurrences: int
    groups: int
    generated_words: int
    exceptions: int
    one_arg_groups: int
    two_arg_groups: int
    signatures_support: dict[str, int]
    input_hash: str
    output_hash: str
    roundtrip: bool

    def as_dict(self) -> dict[str, object]:
        return dataclasses.asdict(self)


def _model_for(
    assignment: Assignment,
    first_words: Sequence[bytes],
    order: str,
) -> tuple[bytes, list[bytes], dict[str, int]]:
    stems = assignment.stems
    stem_ids = {stem: index for index, stem in enumerate(stems)}
    signatures = assignment.signatures
    out = bytearray()
    out.extend(screen.uvarint(len(signatures)))
    out.extend(screen.uvarint(len(stems)))
    out.extend(screen.uvarint(len(signatures)))
    out.extend(screen.uvarint(len(assignment.exceptions)))

    signature_start = len(out)
    for signature in signatures:
        _write_signature(out, signature)
    signature_bytes = len(out) - signature_start

    stem_start = len(out)
    for stem in stems:
        _write_bytes(out, stem)
    stem_bytes = len(out) - stem_start

    occupancy_start = len(out)
    support_counts: dict[str, int] = {}
    for signature_id, (signature, args_group) in enumerate(zip(signatures, assignment.groups)):
        out.extend(screen.uvarint(signature_id))
        out.extend(screen.uvarint(len(args_group)))
        ids = [tuple(stem_ids[arg] for arg in args) for args in args_group]
        _write_sparse_args(out, ids, len(stems))
        label = {1: "affix", 2: "repeat_arg", 3: "two_hole"}[signature.kind]
        support_counts[label] = support_counts.get(label, 0) + len(args_group)
    occupancy_bytes = len(out) - occupancy_start

    exception_start = len(out)
    for word in assignment.exceptions:
        _write_bytes(out, word)
    exception_bytes = len(out) - exception_start

    permutation_bytes = 0
    if order == "first":
        lex_index = {word: index for index, word in enumerate(assignment.words)}
        permutation = [lex_index[word] for word in first_words]
        permutation_start = len(out)
        out.extend(screen.uvarint(len(permutation)))
        for value in permutation:
            out.extend(screen.uvarint(value))
        permutation_bytes = len(out) - permutation_start
    else:
        out.extend(screen.uvarint(0))

    lex_words = list(assignment.words)
    return bytes(out), lex_words, {
        "signature_bytes": signature_bytes,
        "stem_bytes": stem_bytes,
        "occupancy_bytes": occupancy_bytes,
        "exception_bytes": exception_bytes,
        "permutation_bytes": permutation_bytes,
        "groups": len(signatures),
        "generated_words": sum(len(group) for group in assignment.groups),
        "exceptions": len(assignment.exceptions),
        "one_arg_groups": sum(signature.kind != 3 for signature in signatures),
        "two_arg_groups": sum(signature.kind == 3 for signature in signatures),
        "signatures_support": {str(key): value for key, value in sorted(support_counts.items())},
    }


def _decode_model(model: bytes, count: int, order: str, first_words: Sequence[bytes] | None = None) -> list[bytes]:
    pos = 0
    signature_count, pos = screen.take_uvarint(model, pos)
    stem_count, pos = screen.take_uvarint(model, pos)
    group_count, pos = screen.take_uvarint(model, pos)
    exception_count, pos = screen.take_uvarint(model, pos)
    if group_count != signature_count or signature_count > count or stem_count > count * 4 + 1:
        raise ValueError("bad generated-set counts")
    signatures: list[Signature] = []
    for _ in range(signature_count):
        signature, pos = _read_signature(model, pos)
        signatures.append(signature)
    stems: list[bytes] = []
    for _ in range(stem_count):
        stem, pos = _read_bytes(model, pos)
        if len(stem) < MIN_STEM:
            raise ValueError("stem too short")
        stems.append(stem)

    words: list[bytes] = []
    seen: set[bytes] = set()
    for _ in range(group_count):
        signature_id, pos = screen.take_uvarint(model, pos)
        if signature_id >= signature_count:
            raise ValueError("bad generated signature ID")
        assignment_count, pos = screen.take_uvarint(model, pos)
        if assignment_count < 2:
            raise ValueError("nonproductive generated group")
        args_ids, pos = _read_sparse_args(model, pos, assignment_count, signatures[signature_id].arity, stem_count)
        for ids in args_ids:
            args = tuple(stems[index] for index in ids)
            word = signatures[signature_id].apply(args)
            if word in seen:
                raise ValueError("duplicate generated word")
            seen.add(word)
            words.append(word)

    for _ in range(exception_count):
        word, pos = _read_bytes(model, pos)
        if word in seen:
            raise ValueError("exception duplicates generated word")
        seen.add(word)
        words.append(word)

    permutation: list[int] = []
    if order == "first":
        permutation_count, pos = screen.take_uvarint(model, pos)
        if permutation_count != count:
            raise ValueError("bad first-use permutation count")
        for _ in range(permutation_count):
            value, pos = screen.take_uvarint(model, pos)
            if value >= len(words) or value in permutation:
                raise ValueError("bad first-use permutation")
            permutation.append(value)
    else:
        marker, pos = screen.take_uvarint(model, pos)
        if marker != 0:
            raise ValueError("unexpected lexicographic permutation")

    if pos != len(model) or len(words) != count:
        raise ValueError("generated-set count/trailing bytes mismatch")
    lex_words = sorted(words)
    if order == "first":
        # The permutation indexes canonical lexicographic ranks.  Compare the
        # reconstructed bytes rather than trusting a hidden word identity.
        if sorted(permutation) != list(range(count)):
            raise ValueError("first-use permutation is not bijective")
        return [lex_words[index] for index in permutation]
    return lex_words


def _decode_frame(frame: bytes) -> bytes:
    if len(frame) < len(MAGIC) + 2 + 4 or frame[:4] != MAGIC:
        raise ValueError("bad/truncated generated-set frame")
    mode, order_code = frame[4], frame[5]
    if mode != MODE or order_code not in (0, 1):
        raise ValueError("bad generated-set mode/order")
    order = "first" if order_code == 0 else "lex"
    pos = 6
    raw_len, pos = screen.take_uvarint(frame, pos)
    count, pos = screen.take_uvarint(frame, pos)
    model_len, pos = screen.take_uvarint(frame, pos)
    payload_len, pos = screen.take_uvarint(frame, pos)
    if model_len > len(frame) - pos:
        raise ValueError("generated-set model overrun")
    model = frame[pos : pos + model_len]
    pos += model_len
    if payload_len > len(frame) - pos - 4:
        raise ValueError("generated-set payload overrun")
    payload = frame[pos : pos + payload_len]
    pos += payload_len
    if pos + 4 != len(frame):
        raise ValueError("generated-set trailing bytes")
    words = _decode_model(model, count, order)
    decoded = screen.decode_payload(payload, words, raw_len)
    expected_crc = struct.unpack_from("<I", frame, pos)[0]
    if zlib.crc32(decoded) & 0xFFFFFFFF != expected_crc:
        raise ValueError("generated-set CRC mismatch")
    return decoded


def build_frame(
    data: bytes,
    first_words: Sequence[bytes],
    pieces: Sequence[screen.Piece],
    order: str = "lex",
) -> tuple[bytes, GenerationStats]:
    if order not in ("first", "lex"):
        raise ValueError("generated-set supports first or lex order")
    ordered, remap = screen.order_words(first_words, "lex")
    assignment = choose_assignments(ordered)
    model, lex_words, model_stats = _model_for(assignment, first_words, order)
    payload_remap = remap if order == "lex" else {index: index for index in range(len(first_words))}
    payload = screen.encode_payload(pieces, payload_remap)
    header = bytearray(MAGIC)
    header.extend(bytes((MODE, 0 if order == "first" else 1)))
    header.extend(screen.uvarint(len(data)))
    header.extend(screen.uvarint(len(first_words)))
    header.extend(screen.uvarint(len(model)))
    header.extend(screen.uvarint(len(payload)))
    crc = struct.pack("<I", zlib.crc32(data) & 0xFFFFFFFF)
    frame = bytes(header) + model + payload + crc
    decoded = _decode_frame(frame)
    if decoded != data:
        raise AssertionError("generated-set frame round-trip mismatch")
    stats = GenerationStats(
        mode="generative_set",
        order=order,
        header=len(header),
        model=len(model),
        signature_bytes=model_stats["signature_bytes"],
        stem_bytes=model_stats["stem_bytes"],
        occupancy_bytes=model_stats["occupancy_bytes"],
        exception_bytes=model_stats["exception_bytes"],
        permutation_bytes=model_stats["permutation_bytes"],
        dictionary=len(model),
        payload=len(payload),
        crc=len(crc),
        total=len(frame),
        words=len(first_words),
        word_occurrences=sum(piece.is_word for piece in pieces),
        groups=model_stats["groups"],
        generated_words=model_stats["generated_words"],
        exceptions=model_stats["exceptions"],
        one_arg_groups=model_stats["one_arg_groups"],
        two_arg_groups=model_stats["two_arg_groups"],
        signatures_support=model_stats["signatures_support"],
        input_hash=screen.hash_hex(data),
        output_hash=screen.hash_hex(frame),
        roundtrip=True,
    )
    return frame, stats


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input")
    parser.add_argument("--limit", type=int, default=65_536)
    parser.add_argument("--order", choices=("first", "lex", "both"), default="both")
    args = parser.parse_args(argv)
    if args.limit < 0:
        parser.error("limit must be non-negative")
    path = pathlib.Path(args.input)
    full = path.read_bytes()
    data = full[: args.limit] if args.limit else full
    first_words, pieces = screen.scan(data)
    orders = (args.order,) if args.order != "both" else ("first", "lex")
    print(json.dumps({
        "input": args.input,
        "input_bytes": len(data),
        "source_bytes": len(full),
        "input_hash": screen.hash_hex(data),
        "word_types": len(first_words),
        "word_occurrences": sum(piece.is_word for piece in pieces),
        "note": "shared generative-set gate; all ranks/order side data charged",
    }, sort_keys=True))
    for order in orders:
        frame, stats = build_frame(data, first_words, pieces, order)
        _, independent = screen.build_frame(data, first_words, pieces, "independent", order, 0, 128, 0)
        row = stats.as_dict()
        row["frame_bytes"] = len(frame)
        row["independent_bytes"] = independent.total
        row["delta_vs_independent"] = len(frame) - independent.total
        print(json.dumps(row, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
