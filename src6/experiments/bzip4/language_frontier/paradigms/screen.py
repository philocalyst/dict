#!/usr/bin/env python3
"""Bounded byte-exact screen for productive word relations.

This is intentionally an isolated experiment.  It is a small, auditable
frame with checked edit programs, not a replacement for the current bz4 wire
format.  The screen is useful before changing the production codec because it
charges parent IDs, operation bytes, model/templates, payload IDs, framing,
and all literal separators while still making the decoder independently
verifiable.
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
from typing import Iterable, Iterator, Sequence


MAGIC = b"PPL1"
MAX_OUTPUT_DEFAULT = 1 << 20


def uvarint(n: int) -> bytes:
    if n < 0:
        raise ValueError(f"negative varint: {n}")
    out = bytearray()
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


def take_uvarint(data: bytes, pos: int) -> tuple[int, int]:
    value = 0
    shift = 0
    for _ in range(5):
        if pos >= len(data):
            raise ValueError("truncated varint")
        byte = data[pos]
        pos += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, pos
        shift += 7
    raise ValueError("overlong varint")


def hash_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def word_kind(byte: int) -> int:
    """The current v4 learner's byte-level run classes."""

    if (65 <= byte <= 90) or (97 <= byte <= 122) or byte >= 0x80:
        return 1
    if 48 <= byte <= 57:
        return 2
    return 0


@dataclasses.dataclass(frozen=True)
class Piece:
    is_word: bool
    value: bytes | int


def scan(data: bytes) -> tuple[list[bytes], list[Piece]]:
    """Return first-appearance word types and an exact mixed stream.

    No bytes are decoded as text.  Literal runs are kept as bytes and words
    are contiguous runs of one current-v4 kind.  The function is deliberately
    deterministic and does not discard empty/invalid UTF-8 fragments.
    """

    words: list[bytes] = []
    index: dict[bytes, int] = {}
    pieces: list[Piece] = []
    at = 0
    literal = bytearray()

    def flush_literal() -> None:
        if literal:
            pieces.append(Piece(False, bytes(literal)))
            literal.clear()

    while at < len(data):
        kind = word_kind(data[at])
        if kind == 0:
            literal.append(data[at])
            at += 1
            continue
        flush_literal()
        end = at + 1
        while end < len(data) and word_kind(data[end]) == kind:
            end += 1
        word = data[at:end]
        word_id = index.get(word)
        if word_id is None:
            word_id = len(words)
            index[word] = word_id
            words.append(word)
        pieces.append(Piece(True, word_id))
        at = end
    flush_literal()
    return words, pieces


Op = tuple[str, int | bytes]


def _coalesce(ops: list[Op]) -> list[Op]:
    out: list[Op] = []
    for kind, value in ops:
        if not out or out[-1][0] != kind:
            out.append((kind, value))
            continue
        old_kind, old_value = out[-1]
        if kind in ("C", "D"):
            assert isinstance(old_value, int) and isinstance(value, int)
            out[-1] = (old_kind, old_value + value)
        else:
            assert isinstance(old_value, bytes) and isinstance(value, bytes)
            out[-1] = (old_kind, old_value + value)
    return out


def align(parent: bytes, target: bytes, max_edits: int) -> tuple[int, list[Op]] | None:
    """Canonical byte edit alignment, bounded by Levenshtein distance.

    Equal bytes have zero cost and are preferred.  For equal-cost edits the
    stable order is substitution, deletion, insertion.  This produces a
    finite deterministic program; the later frame charges its actual op
    bytes, rather than pretending edit distance itself is compressed size.
    """

    n, m = len(parent), len(target)
    inf = max_edits + 1
    dp = [[inf] * (m + 1) for _ in range(n + 1)]
    dp[0][0] = 0
    for i in range(1, n + 1):
        dp[i][0] = i if i <= max_edits else inf
    for j in range(1, m + 1):
        dp[0][j] = j if j <= max_edits else inf
    for i in range(1, n + 1):
        lo = max(1, i - max_edits)
        hi = min(m, i + max_edits)
        for j in range(lo, hi + 1):
            best = inf
            if parent[i - 1] == target[j - 1]:
                best = dp[i - 1][j - 1]
            else:
                best = min(best, dp[i - 1][j - 1] + 1)
            best = min(best, dp[i - 1][j] + 1)
            best = min(best, dp[i][j - 1] + 1)
            dp[i][j] = best
    distance = dp[n][m]
    if distance > max_edits:
        return None

    raw: list[Op] = []
    i, j = n, m
    while i or j:
        if i and j and parent[i - 1] == target[j - 1] and dp[i][j] == dp[i - 1][j - 1]:
            raw.append(("C", 1))
            i -= 1
            j -= 1
            continue
        # The order here is the documented deterministic tie-break.
        if i and j and dp[i][j] == dp[i - 1][j - 1] + 1:
            raw.append(("S", bytes((target[j - 1],))))
            i -= 1
            j -= 1
            continue
        if i and dp[i][j] == dp[i - 1][j] + 1:
            raw.append(("D", 1))
            i -= 1
            continue
        if j and dp[i][j] == dp[i][j - 1] + 1:
            raw.append(("I", bytes((target[j - 1],))))
            j -= 1
            continue
        raise AssertionError("alignment predecessor missing")
    raw.reverse()
    return distance, _coalesce(raw)


def op_param_bytes(kind: str, value: int | bytes) -> int:
    if kind in ("C", "D"):
        assert isinstance(value, int)
        return 1 + len(uvarint(value))
    assert isinstance(value, bytes)
    return 1 + len(uvarint(len(value))) + len(value)


def script_bytes(ops: Sequence[Op]) -> int:
    return sum(op_param_bytes(kind, value) for kind, value in ops)


def shape(ops: Sequence[Op]) -> tuple[str, ...]:
    return tuple(kind for kind, _ in ops)


def classify(ops: Sequence[Op]) -> str:
    kinds = tuple(kind for kind, _ in ops)
    if kinds == ("C", "I"):
        return "prefix_only"
    if kinds == ("I", "C"):
        return "suffix_only"
    if kinds == ("I", "C", "I"):
        return "circumfix"
    if "S" in kinds and kinds.count("C") >= 2:
        return "substitution_nonprefix"
    if "I" in kinds and kinds.count("C") >= 2:
        return "infix"
    if "D" in kinds and kinds.count("C") >= 2:
        return "deletion_nonprefix"
    if "S" in kinds:
        return "substitution"
    return "other_edit"


def relation_cost(parent_delta: int, ops: Sequence[Op], tag: int = 2) -> int:
    # tag + source distance + op count + op parameters.  Keeping op count
    # explicit makes malformed/truncated programs detectable.
    return 1 + len(uvarint(parent_delta)) + len(uvarint(len(ops))) + script_bytes(ops)


def independent_cost(word: bytes) -> int:
    return 1 + len(uvarint(len(word))) + len(word)


def common_prefix(a: bytes, b: bytes) -> int:
    keep = 0
    for x, y in zip(a, b):
        if x != y:
            break
        keep += 1
    return keep


def prefix_cost(parent_delta: int, keep: int, suffix: bytes) -> int:
    return 1 + len(uvarint(parent_delta)) + len(uvarint(keep)) + len(uvarint(len(suffix))) + len(suffix)


@dataclasses.dataclass
class Candidate:
    parent: int
    ops: list[Op]
    distance: int
    family: str
    cost: int


def candidate_parents(words: Sequence[bytes], index: int, max_edits: int, max_word: int) -> Iterator[int]:
    """Deterministic bounded retrieval, not a nearest-word oracle.

    We use endpoint/length buckets, then a fixed fallback of the nearest
    earlier types by (length difference, first-appearance distance, index).
    The candidate rule is frozen and independent of observed savings.
    """

    target = words[index]
    if len(target) > max_word:
        return
    selected: set[int] = set()
    for j in range(index):
        parent = words[j]
        if len(parent) > max_word or abs(len(parent) - len(target)) > max_edits:
            continue
        endpoint = (parent[:2] == target[:2]) or (parent[-2:] == target[-2:])
        same_end = parent[:1] == target[:1] or parent[-1:] == target[-1:]
        if endpoint or same_end:
            selected.add(j)
    # A small fixed fallback prevents endpoint indexing from making a class
    # disappear on very short/circumfixed words, while still charging IDs.
    fallback = sorted(
        (
            (abs(len(words[j]) - len(target)), index - j, j)
            for j in range(index)
            if len(words[j]) <= max_word and abs(len(words[j]) - len(target)) <= max_edits
        )
    )[:8]
    selected.update(j for _, _, j in fallback)
    for j in sorted(selected):
        yield j


def best_relation(words: Sequence[bytes], index: int, max_edits: int, max_word: int) -> Candidate | None:
    if len(words[index]) > max_word:
        return None
    best: Candidate | None = None
    for parent_index in candidate_parents(words, index, max_edits, max_word):
        result = align(words[parent_index], words[index], max_edits)
        if result is None:
            continue
        distance, ops = result
        if not any(kind != "C" for kind, _ in ops):
            continue
        delta = index - parent_index
        cost = relation_cost(delta, ops)
        candidate = Candidate(parent_index, ops, distance, classify(ops), cost)
        # Prefer lower complete record cost, then fewer edits, then nearer
        # parent.  The tie order is part of the format policy.
        key = (cost, distance, delta, parent_index)
        if best is None or key < (best.cost, best.distance, index - best.parent, best.parent):
            best = candidate
    if best is not None and best.cost < independent_cost(words[index]):
        return best
    return None


@dataclasses.dataclass
class FrameStats:
    mode: str
    order: str
    header: int
    model: int
    templates: int
    template_bytes: int
    dictionary: int
    payload: int
    crc: int
    padding: int
    total: int
    words: int
    word_occurrences: int
    relations: int
    novel_relations: int
    relation_parent: int
    relation_ops: int
    relation_literals: int
    by_family: dict[str, int]
    input_hash: str
    output_hash: str
    roundtrip: bool

    def as_dict(self) -> dict[str, object]:
        return dataclasses.asdict(self)


def order_words(first_words: Sequence[bytes], order: str) -> tuple[list[bytes], dict[int, int]]:
    if order == "first":
        ordered = list(first_words)
    elif order == "lex":
        ordered = sorted(first_words)
    else:
        raise ValueError(order)
    # Word types are unique, so a direct byte map prices payload IDs without a
    # hidden search/oracle and avoids an O(n^2) `list.index` pass.
    direct = {word: i for i, word in enumerate(ordered)}
    ids = {id_: direct[word] for id_, word in enumerate(first_words)}
    return ordered, ids


def encode_payload(pieces: Sequence[Piece], remap: dict[int, int]) -> bytes:
    out = bytearray()
    for piece in pieces:
        if piece.is_word:
            out.append(1)
            out.extend(uvarint(remap[int(piece.value)]))
        else:
            literal = bytes(piece.value)
            out.append(0)
            out.extend(uvarint(len(literal)))
            out.extend(literal)
    return bytes(out)


def decode_payload(payload: bytes, words: Sequence[bytes], raw_len: int) -> bytes:
    out = bytearray()
    pos = 0
    while pos < len(payload):
        tag = payload[pos]
        pos += 1
        if tag == 0:
            length, pos = take_uvarint(payload, pos)
            if length > len(payload) - pos:
                raise ValueError("literal overrun")
            out.extend(payload[pos : pos + length])
            pos += length
        elif tag == 1:
            word_id, pos = take_uvarint(payload, pos)
            if word_id >= len(words):
                raise ValueError("word ID out of range")
            out.extend(words[word_id])
        else:
            raise ValueError(f"bad payload tag {tag}")
        if len(out) > raw_len:
            raise ValueError("output budget exceeded")
    if len(out) != raw_len:
        raise ValueError("raw length mismatch")
    return bytes(out)


def best_cut(words: Sequence[bytes], index: int, window: int = 32, least: int = 1) -> tuple[int, int, bytes] | None:
    """The current CUT control: longest prefix among the last `window` types."""

    target = words[index]
    first = max(0, index - window)
    best: tuple[int, int, bytes] | None = None
    for parent in range(first, index):
        keep = common_prefix(words[parent], target)
        if keep < least:
            continue
        suffix = target[keep:]
        delta = index - parent
        candidate = (delta, keep, suffix)
        if best is None or (keep, -len(suffix), -delta, -parent) > (
            best[1],
            -len(best[2]),
            -best[0],
            -(index - best[0]),
        ):
            best = candidate
    if best is not None and prefix_cost(best[0], best[1], best[2]) < independent_cost(target):
        return best
    return None


def _op_code(kind: str) -> int:
    return {"C": 0, "D": 1, "I": 2, "S": 3}[kind]


def _op_kind(code: int) -> str:
    return ("C", "D", "I", "S")[code]


def param_bytes(ops: Sequence[Op]) -> int:
    """Bytes for parameters when op kinds come from a shared template."""

    total = 0
    for kind, value in ops:
        if kind in ("C", "D"):
            assert isinstance(value, int)
            total += len(uvarint(value))
        else:
            assert isinstance(value, bytes)
            total += len(uvarint(len(value))) + len(value)
    return total


ProgramOp = tuple[str, int | None]


def program_descriptor(parent: bytes, ops: Sequence[Op]) -> tuple[ProgramOp, ...]:
    """Factor fixed edit geometry into a reusable program template.

    A final COPY that consumes the parent's remaining bytes is represented by
    R (copy-remainder) and has no per-edge length parameter.  Other COPY,
    DELETE, and SUB lengths are constants of the program template. INSERT is
    variable and keeps its per-edge length/literal.  This is the productive
    distinction from merely sharing an opcode string: recurring stem geometry
    is paid once, while each edge still pays its exception bytes.
    """

    source = 0
    out: list[ProgramOp] = []
    for kind, value in ops:
        if kind == "C":
            assert isinstance(value, int)
            if source + value == len(parent):
                out.append(("R", None))
            else:
                out.append(("C", value))
            source += value
        elif kind == "D":
            assert isinstance(value, int)
            out.append(("D", value))
            source += value
        elif kind == "I":
            assert isinstance(value, bytes)
            out.append(("I", None))
        elif kind == "S":
            assert isinstance(value, bytes)
            out.append(("S", len(value)))
            source += len(value)
        else:
            raise AssertionError(kind)
    if source != len(parent):
        raise AssertionError("descriptor did not consume parent")
    return tuple(out)


def program_key(parent: bytes, ops: Sequence[Op]) -> tuple[ProgramOp, ...]:
    return program_descriptor(parent, ops)


def program_model_bytes(template: Sequence[ProgramOp]) -> int:
    # Descriptor opcode plus fixed parameter where applicable.  INSERT has a
    # variable literal and therefore has no fixed template parameter.
    total = len(uvarint(len(template)))
    for kind, value in template:
        total += 1
        if kind in ("C", "D", "S"):
            assert isinstance(value, int)
            total += len(uvarint(value))
    return total


def program_edge_bytes(template: Sequence[ProgramOp], ops: Sequence[Op]) -> int:
    total = 0
    for descriptor, (kind, value) in zip(template, ops):
        assert descriptor[0] in (kind, "R") or (descriptor[0] == "R" and kind == "C")
        if descriptor[0] == "I":
            assert kind == "I" and isinstance(value, bytes)
            total += len(uvarint(len(value))) + len(value)
        elif descriptor[0] == "S":
            assert kind == "S" and isinstance(value, bytes)
            if len(value) != descriptor[1]:
                raise AssertionError("SUB length mismatch")
            total += len(value)
    return total


def emit_program_params(out: bytearray, template: Sequence[ProgramOp], ops: Sequence[Op]) -> None:
    for descriptor, (kind, value) in zip(template, ops):
        if descriptor[0] == "I":
            assert kind == "I" and isinstance(value, bytes)
            out.extend(uvarint(len(value)))
            out.extend(value)
        elif descriptor[0] == "S":
            assert kind == "S" and isinstance(value, bytes)
            if len(value) != descriptor[1]:
                raise AssertionError("SUB length mismatch")
            out.extend(value)


def take_program_params(
    data: bytes, pos: int, template: Sequence[ProgramOp]
) -> tuple[list[Op], int]:
    ops: list[Op] = []
    for kind, value in template:
        if kind in ("C", "D"):
            assert isinstance(value, int)
            ops.append((kind, value))
        elif kind == "R":
            ops.append(("C", -1))
        elif kind == "I":
            length, pos = take_uvarint(data, pos)
            if length > len(data) - pos:
                raise ValueError("truncated program insertion")
            ops.append(("I", data[pos : pos + length]))
            pos += length
        elif kind == "S":
            assert isinstance(value, int)
            if value > len(data) - pos:
                raise ValueError("truncated program substitution")
            ops.append(("S", data[pos : pos + value]))
            pos += value
        else:
            raise ValueError("bad program descriptor")
    return ops, pos


def encode_program_template(out: bytearray, template: Sequence[ProgramOp]) -> None:
    out.extend(uvarint(len(template)))
    codes = {"C": 0, "R": 1, "D": 2, "I": 3, "S": 4}
    for kind, value in template:
        out.append(codes[kind])
        if kind in ("C", "D", "S"):
            assert isinstance(value, int)
            out.extend(uvarint(value))


def decode_program_template(data: bytes, pos: int) -> tuple[tuple[ProgramOp, ...], int]:
    count, pos = take_uvarint(data, pos)
    if count > 255:
        raise ValueError("program too long")
    kinds = ("C", "R", "D", "I", "S")
    result: list[ProgramOp] = []
    for _ in range(count):
        if pos >= len(data) or data[pos] >= len(kinds):
            raise ValueError("bad program descriptor")
        kind = kinds[data[pos]]
        pos += 1
        value: int | None = None
        if kind in ("C", "D", "S"):
            value, pos = take_uvarint(data, pos)
        result.append((kind, value))
    return tuple(result), pos


def emit_params(out: bytearray, ops: Sequence[Op], include_kinds: bool) -> None:
    if include_kinds:
        out.extend(uvarint(len(ops)))
    for kind, value in ops:
        if include_kinds:
            out.append(_op_code(kind))
        if kind in ("C", "D"):
            assert isinstance(value, int)
            out.extend(uvarint(value))
        else:
            assert isinstance(value, bytes)
            out.extend(uvarint(len(value)))
            out.extend(value)


def take_params(data: bytes, pos: int, kinds: Sequence[str] | None) -> tuple[list[Op], int]:
    if kinds is None:
        count, pos = take_uvarint(data, pos)
        if count > 255:
            raise ValueError("too many edit operations")
        ops: list[Op] = []
        for _ in range(count):
            if pos >= len(data):
                raise ValueError("truncated operation kind")
            code = data[pos]
            pos += 1
            if code > 3:
                raise ValueError("bad operation kind")
            kind = _op_kind(code)
            value, pos = take_uvarint(data, pos)
            if kind in ("C", "D"):
                ops.append((kind, value))
            else:
                if value > len(data) - pos:
                    raise ValueError("truncated edit literal")
                ops.append((kind, data[pos : pos + value]))
                pos += value
        return ops, pos
    ops: list[Op] = []
    for kind in kinds:
        value, pos = take_uvarint(data, pos)
        if kind in ("C", "D"):
            ops.append((kind, value))
        else:
            if value > len(data) - pos:
                raise ValueError("truncated edit literal")
            ops.append((kind, data[pos : pos + value]))
            pos += value
    return ops, pos


def apply_ops(parent: bytes, ops: Sequence[Op], max_output: int) -> bytes:
    src = 0
    out = bytearray()
    for kind, value in ops:
        if kind == "C":
            assert isinstance(value, int)
            if value == -1:
                value = len(parent) - src
            if value > len(parent) - src:
                raise ValueError("COPY source overrun")
            out.extend(parent[src : src + value])
            src += value
        elif kind == "D":
            assert isinstance(value, int)
            if value > len(parent) - src:
                raise ValueError("DELETE source overrun")
            src += value
        elif kind == "I":
            assert isinstance(value, bytes)
            out.extend(value)
        elif kind == "S":
            assert isinstance(value, bytes)
            if len(value) > len(parent) - src:
                raise ValueError("SUB source overrun")
            out.extend(value)
            src += len(value)
        else:
            raise ValueError(f"bad operation {kind}")
        if len(out) > max_output:
            raise ValueError("edit output budget exceeded")
    if src != len(parent):
        raise ValueError("edit did not consume parent")
    return bytes(out)


def choose_templates(candidates: Sequence[Candidate | None]) -> dict[tuple[str, ...], int]:
    counts = collections.Counter(
        shape(candidate.ops)
        for candidate in candidates
        if candidate is not None
    )
    templates: dict[tuple[str, ...], int] = {}
    for candidate in candidates:
        if candidate is None:
            continue
        key = shape(candidate.ops)
        if counts[key] >= 2 and key not in templates:
            templates[key] = len(templates)
    return templates


def final_edit_candidates(
    words: Sequence[bytes], max_edits: int, max_word: int, edit_limit: int
) -> tuple[list[Candidate | None], dict[tuple[str, ...], int]]:
    """Two fixed passes: discover, charge shared shapes, then recheck edges."""

    initial = [
        best_relation(words, i, max_edits, max_word) if i and i < edit_limit else None
        for i in range(len(words))
    ]
    templates = choose_templates(initial)
    final: list[Candidate | None] = []
    for i, candidate in enumerate(initial):
        if candidate is None:
            final.append(None)
            continue
        template_id = templates.get(shape(candidate.ops))
        if template_id is None:
            cost = 1 + len(uvarint(i - candidate.parent)) + script_bytes(candidate.ops)
        else:
            cost = 1 + len(uvarint(i - candidate.parent)) + len(uvarint(template_id)) + param_bytes(candidate.ops)
        if cost < independent_cost(words[i]):
            final.append(dataclasses.replace(candidate, cost=cost))
        else:
            final.append(None)
    # Drop templates which lost all of their edges.  This is deterministic,
    # and avoids charging an unused shape as if it were a free global model.
    used = collections.Counter(shape(c.ops) for c in final if c is not None)
    templates = {key: n for key, n in templates.items() if used[key] >= 2}
    return final, templates


def serialize_model(
    words: Sequence[bytes],
    mode: str,
    max_edits: int = 4,
    max_word: int = 128,
    edit_limit: int | None = None,
) -> tuple[bytes, list[bytes], dict[str, int | dict[str, int]], list[Candidate | None]]:
    """Serialize dictionary records and return words in decoder ID order."""

    out = bytearray()
    stats: dict[str, int | dict[str, int]] = {
        "templates": 0,
        "dictionary": 0,
        "relations": 0,
        "novel_relations": 0,
        "relation_parent": 0,
        "relation_ops": 0,
        "relation_literals": 0,
        "by_family": {},
    }
    candidates: list[Candidate | None] = [None] * len(words)
    if mode == "independent":
        for word in words:
            out.append(0)
            out.extend(uvarint(len(word)))
            out.extend(word)
    elif mode == "cut":
        for i, word in enumerate(words):
            cut = best_cut(words, i)
            if cut is None:
                out.append(0)
                out.extend(uvarint(len(word)))
                out.extend(word)
                continue
            delta, keep, suffix = cut
            out.append(1)
            out.extend(uvarint(delta))
            out.extend(uvarint(keep))
            out.extend(uvarint(len(suffix)))
            out.extend(suffix)
            stats["relations"] = int(stats["relations"]) + 1
            stats["relation_parent"] = int(stats["relation_parent"]) + len(uvarint(delta))
            stats["relation_ops"] = int(stats["relation_ops"]) + len(uvarint(keep)) + len(uvarint(len(suffix))) + 1
            families = stats["by_family"]
            assert isinstance(families, dict)
            families["prefix_only"] = families.get("prefix_only", 0) + 1
    elif mode == "edit":
        if edit_limit is None:
            edit_limit = len(words)
        candidates, templates = final_edit_candidates(words, max_edits, max_word, edit_limit)
        stats["templates"] = len(templates)
        out.extend(uvarint(len(templates)))
        for template in templates:
            out.extend(uvarint(len(template)))
            out.extend(_op_code(kind) for kind in template)
        for i, word in enumerate(words):
            candidate = candidates[i]
            if candidate is None:
                out.append(0)
                out.extend(uvarint(len(word)))
                out.extend(word)
                continue
            template_id = templates.get(shape(candidate.ops))
            out.append(2 if template_id is not None else 3)
            delta = i - candidate.parent
            out.extend(uvarint(delta))
            if template_id is not None:
                out.extend(uvarint(template_id))
                emit_params(out, candidate.ops, include_kinds=False)
            else:
                emit_params(out, candidate.ops, include_kinds=True)
            stats["relations"] = int(stats["relations"]) + 1
            if candidate.family not in ("prefix_only",):
                stats["novel_relations"] = int(stats["novel_relations"]) + 1
            stats["relation_parent"] = int(stats["relation_parent"]) + len(uvarint(delta))
            stats["relation_ops"] = int(stats["relation_ops"]) + (
                param_bytes(candidate.ops)
                if template_id is not None
                else len(uvarint(len(candidate.ops))) + script_bytes(candidate.ops)
            )
            stats["relation_literals"] = int(stats["relation_literals"]) + sum(
                len(value) for kind, value in candidate.ops if kind in ("I", "S") and isinstance(value, bytes)
            )
            families = stats["by_family"]
            assert isinstance(families, dict)
            families[candidate.family] = families.get(candidate.family, 0) + 1
    elif mode == "program":
        # Discover with the same exact byte alignment, then retain only
        # program geometries that recur.  Fixed geometry is paid once in the
        # model; edge literals and parent IDs remain per relation.
        if edit_limit is None:
            edit_limit = len(words)
        initial: list[Candidate | None] = [
            best_relation(words, i, max_edits, max_word) if i and i < edit_limit else None
            for i in range(len(words))
        ]
        program_keys: list[tuple[ProgramOp, ...] | None] = [
            program_key(words[candidate.parent], candidate.ops) if candidate is not None else None
            for candidate in initial
        ]
        counts = collections.Counter(key for key in program_keys if key is not None)
        templates: dict[tuple[ProgramOp, ...], int] = {}
        for key in program_keys:
            if key is not None and counts[key] >= 2 and key not in templates:
                templates[key] = len(templates)
        out.extend(uvarint(len(templates)))
        for template in templates:
            encode_program_template(out, template)
        used: collections.Counter[tuple[ProgramOp, ...]] = collections.Counter()
        retained: list[Candidate | None] = []
        # We must reserve the leading table before records, but can decide
        # whether a candidate pays after the table is known.  Singleton
        # geometries deliberately fall back to an independent record.
        for i, candidate in enumerate(initial):
            if candidate is None:
                retained.append(None)
                continue
            key = program_keys[i]
            assert key is not None
            template_id = templates.get(key)
            if template_id is None:
                retained.append(None)
                continue
            cost = 1 + len(uvarint(i - candidate.parent)) + len(uvarint(template_id))
            cost += program_edge_bytes(key, candidate.ops)
            if cost < independent_cost(words[i]):
                retained.append(candidate)
                used[key] += 1
            else:
                retained.append(None)
        # Freeze only templates that have paying edges.  If a template lost
        # all edges, rebuild the table and records once; no score-driven loop.
        templates = {key: value for key, value in templates.items() if used[key] >= 2}
        out = bytearray()
        out.extend(uvarint(len(templates)))
        for template in templates:
            encode_program_template(out, template)
        for i, word in enumerate(words):
            candidate = retained[i]
            key = program_keys[i] if candidate is not None else None
            template_id = templates.get(key) if key is not None else None
            if candidate is None or template_id is None:
                out.append(0)
                out.extend(uvarint(len(word)))
                out.extend(word)
                continue
            out.append(4)
            delta = i - candidate.parent
            out.extend(uvarint(delta))
            out.extend(uvarint(template_id))
            emit_program_params(out, key, candidate.ops)
            stats["relations"] = int(stats["relations"]) + 1
            if candidate.family != "prefix_only":
                stats["novel_relations"] = int(stats["novel_relations"]) + 1
            stats["relation_parent"] = int(stats["relation_parent"]) + len(uvarint(delta))
            stats["relation_ops"] = int(stats["relation_ops"]) + len(uvarint(template_id)) + program_edge_bytes(
                key, candidate.ops
            )
            stats["relation_literals"] = int(stats["relation_literals"]) + sum(
                len(value) for kind, value in candidate.ops if kind in ("I", "S") and isinstance(value, bytes)
            )
            families = stats["by_family"]
            assert isinstance(families, dict)
            families[candidate.family] = families.get(candidate.family, 0) + 1
        stats["templates"] = len(templates)
    else:
        raise ValueError(f"unknown dictionary mode {mode}")
    stats["dictionary"] = len(out)
    return bytes(out), list(words), stats, candidates


def deserialize_model(model: bytes, count: int, mode: str, max_output: int) -> tuple[list[bytes], int]:
    pos = 0
    templates: list[tuple[str, ...]] = []
    program_templates: list[tuple[ProgramOp, ...]] = []
    if mode == "edit":
        template_count, pos = take_uvarint(model, pos)
        if template_count > count:
            raise ValueError("template count exceeds word count")
        for _ in range(template_count):
            shape_len, pos = take_uvarint(model, pos)
            if shape_len > 255 or shape_len > len(model) - pos:
                raise ValueError("bad template length")
            template_shape: list[str] = []
            for code in model[pos : pos + shape_len]:
                if code > 3:
                    raise ValueError("bad template opcode")
                template_shape.append(_op_kind(code))
            pos += shape_len
            templates.append(tuple(template_shape))
    elif mode == "program":
        template_count, pos = take_uvarint(model, pos)
        if template_count > count:
            raise ValueError("program template count exceeds word count")
        for _ in range(template_count):
            template, pos = decode_program_template(model, pos)
            program_templates.append(template)

    words: list[bytes] = []
    relation_count = 0
    for index in range(count):
        if pos >= len(model):
            raise ValueError("truncated dictionary")
        tag = model[pos]
        pos += 1
        if tag == 0:
            length, pos = take_uvarint(model, pos)
            if length > len(model) - pos:
                raise ValueError("truncated independent word")
            word = model[pos : pos + length]
            pos += length
        elif tag == 1 and mode == "cut":
            delta, pos = take_uvarint(model, pos)
            keep, pos = take_uvarint(model, pos)
            suffix_len, pos = take_uvarint(model, pos)
            if delta == 0 or delta > index:
                raise ValueError("bad CUT parent")
            if keep > len(words[index - delta]) or suffix_len > len(model) - pos:
                raise ValueError("bad CUT bounds")
            suffix = model[pos : pos + suffix_len]
            pos += suffix_len
            word = words[index - delta][:keep] + suffix
            relation_count += 1
        elif tag in (2, 3) and mode == "edit":
            delta, pos = take_uvarint(model, pos)
            if delta == 0 or delta > index:
                raise ValueError("bad edit parent")
            if tag == 2:
                template_id, pos = take_uvarint(model, pos)
                if template_id >= len(templates):
                    raise ValueError("bad template ID")
                ops, pos = take_params(model, pos, templates[template_id])
            else:
                ops, pos = take_params(model, pos, None)
            word = apply_ops(words[index - delta], ops, max_output)
            relation_count += 1
        elif tag == 4 and mode == "program":
            delta, pos = take_uvarint(model, pos)
            template_id, pos = take_uvarint(model, pos)
            if delta == 0 or delta > index or template_id >= len(program_templates):
                raise ValueError("bad program reference")
            ops, pos = take_program_params(model, pos, program_templates[template_id])
            word = apply_ops(words[index - delta], ops, max_output)
            relation_count += 1
        else:
            raise ValueError(f"bad dictionary tag {tag} in {mode}")
        if len(word) > max_output:
            raise ValueError("word output budget exceeded")
        words.append(word)
    if pos != len(model):
        raise ValueError("trailing dictionary bytes")
    return words, relation_count


MODE_CODES = {"independent": 0, "cut": 1, "edit": 2, "program": 4}
CODE_MODES = {value: key for key, value in MODE_CODES.items()}
ORDER_CODES = {"first": 0, "lex": 1}
CODE_ORDERS = {value: key for key, value in ORDER_CODES.items()}


@dataclasses.dataclass
class _TrieNode:
    terminal: bool = False
    children: dict[int, "_TrieNode"] = dataclasses.field(default_factory=dict)


def build_dafsa(words: Sequence[bytes]) -> tuple[list[tuple[bool, tuple[tuple[int, int], ...]]], int]:
    """Build a minimal acyclic word automaton in deterministic byte order."""

    root = _TrieNode()
    for word in words:
        node = root
        for byte in word:
            node = node.children.setdefault(byte, _TrieNode())
        node.terminal = True

    states: list[tuple[bool, tuple[tuple[int, int], ...]]] = []
    intern: dict[tuple[bool, tuple[tuple[int, int], ...]], int] = {}

    def visit(node: _TrieNode) -> int:
        edges = tuple((label, visit(child)) for label, child in sorted(node.children.items()))
        signature = (node.terminal, edges)
        state = intern.get(signature)
        if state is not None:
            return state
        state = len(states)
        intern[signature] = state
        states.append(signature)
        return state

    root_id = visit(root)
    return states, root_id


def serialize_dafsa(words: Sequence[bytes]) -> tuple[bytes, int, int]:
    states, root_id = build_dafsa(words)
    out = bytearray()
    out.extend(uvarint(len(states)))
    out.extend(uvarint(root_id))
    for terminal, edges in states:
        out.append(int(terminal))
        out.extend(uvarint(len(edges)))
        for label, child in edges:
            out.append(label)
            out.extend(uvarint(child))
    return bytes(out), len(states), root_id


def deserialize_dafsa(model: bytes, count: int, max_output: int) -> list[bytes]:
    pos = 0
    state_count, pos = take_uvarint(model, pos)
    root_id, pos = take_uvarint(model, pos)
    if state_count == 0 or root_id >= state_count:
        raise ValueError("bad DAFSA root")
    states: list[tuple[bool, tuple[tuple[int, int], ...]]] = []
    for _ in range(state_count):
        if pos >= len(model):
            raise ValueError("truncated DAFSA state")
        terminal = model[pos]
        pos += 1
        if terminal > 1:
            raise ValueError("bad DAFSA terminal bit")
        degree, pos = take_uvarint(model, pos)
        if degree > 256:
            raise ValueError("DAFSA degree too large")
        edges: list[tuple[int, int]] = []
        previous = -1
        for _ in range(degree):
            if pos >= len(model):
                raise ValueError("truncated DAFSA edge")
            label = model[pos]
            pos += 1
            child, pos = take_uvarint(model, pos)
            if child >= state_count or label <= previous:
                raise ValueError("bad DAFSA edge")
            previous = label
            edges.append((label, child))
        states.append((bool(terminal), tuple(edges)))
    if pos != len(model):
        raise ValueError("trailing DAFSA bytes")

    words: list[bytes] = []
    stack: list[tuple[int, bytes]] = [(root_id, b"")]
    while stack:
        state, prefix = stack.pop()
        terminal, edges = states[state]
        if terminal:
            words.append(prefix)
            if len(words) > count:
                raise ValueError("DAFSA terminal count exceeds header")
        # Push reverse so enumeration is byte-lexicographic.
        for label, child in reversed(edges):
            next_prefix = prefix + bytes((label,))
            if len(next_prefix) > max_output:
                raise ValueError("DAFSA output budget exceeded")
            stack.append((child, next_prefix))
    if len(words) != count:
        raise ValueError("DAFSA word count mismatch")
    return words


def _build_dafsa_frame(
    data: bytes,
    first_words: Sequence[bytes],
    pieces: Sequence[Piece],
) -> tuple[bytes, FrameStats]:
    words, remap = order_words(first_words, "lex")
    model, state_count, _ = serialize_dafsa(words)
    payload = encode_payload(pieces, remap)
    header = bytearray(MAGIC)
    header.extend(bytes((3, ORDER_CODES["lex"])))
    header.extend(uvarint(len(data)))
    header.extend(uvarint(len(words)))
    header.extend(uvarint(len(model)))
    header.extend(uvarint(len(payload)))
    crc = struct.pack("<I", zlib.crc32(data) & 0xFFFFFFFF)
    frame = bytes(header) + model + payload + crc
    decoded = decode_frame(frame)
    if decoded != data:
        raise AssertionError("DAFSA frame round-trip mismatch")
    stats = FrameStats(
        mode="dafsa",
        order="lex",
        header=len(header),
        model=len(model),
        templates=0,
        template_bytes=0,
        dictionary=len(model),
        payload=len(payload),
        crc=len(crc),
        padding=0,
        total=len(frame),
        words=len(words),
        word_occurrences=sum(piece.is_word for piece in pieces),
        relations=0,
        novel_relations=0,
        relation_parent=0,
        relation_ops=0,
        relation_literals=0,
        by_family={"states": state_count},
        input_hash=hash_hex(data),
        output_hash=hash_hex(frame),
        roundtrip=True,
    )
    return frame, stats


def build_frame(
    data: bytes,
    first_words: Sequence[bytes],
    pieces: Sequence[Piece],
    mode: str,
    order: str,
    max_edits: int,
    max_word: int = 128,
    edit_limit: int | None = None,
) -> tuple[bytes, FrameStats]:
    if mode == "dafsa":
        return _build_dafsa_frame(data, first_words, pieces)
    words, remap = order_words(first_words, order)
    model, decoder_words, model_stats, _ = serialize_model(
        words, mode, max_edits, max_word, edit_limit
    )
    assert decoder_words == words
    payload = encode_payload(pieces, remap)
    header = bytearray(MAGIC)
    header.extend(bytes((MODE_CODES[mode], ORDER_CODES[order])))
    header.extend(uvarint(len(data)))
    header.extend(uvarint(len(words)))
    header.extend(uvarint(len(model)))
    header.extend(uvarint(len(payload)))
    crc = struct.pack("<I", zlib.crc32(data) & 0xFFFFFFFF)
    frame = bytes(header) + model + payload + crc
    decoded = decode_frame(frame)
    if decoded != data:
        raise AssertionError("frame round-trip mismatch")
    by_family = model_stats["by_family"]
    assert isinstance(by_family, dict)
    relation_count = int(model_stats["relations"])
    novel_count = int(model_stats["novel_relations"])
    template_bytes = 0
    if mode == "edit":
        # The template table is a leading varint plus (length, opcode bytes)
        # for every template.  It is excluded from relation record bytes.
        pos = 0
        template_count, pos = take_uvarint(model, pos)
        template_bytes = pos
        for _ in range(template_count):
            length, pos = take_uvarint(model, pos)
            template_bytes += length
            pos += length
    elif mode == "program":
        pos = 0
        template_count, pos = take_uvarint(model, pos)
        template_bytes = pos
        for _ in range(template_count):
            before = pos
            _, pos = decode_program_template(model, pos)
            template_bytes += pos - before
    stats = FrameStats(
        mode=mode,
        order=order,
        header=len(header),
        model=len(model),
        templates=int(model_stats["templates"]),
        template_bytes=template_bytes,
        dictionary=len(model) - template_bytes,
        payload=len(payload),
        crc=len(crc),
        padding=0,
        total=len(frame),
        words=len(words),
        word_occurrences=sum(piece.is_word for piece in pieces),
        relations=relation_count,
        novel_relations=novel_count,
        relation_parent=int(model_stats["relation_parent"]),
        relation_ops=int(model_stats["relation_ops"]),
        relation_literals=int(model_stats["relation_literals"]),
        by_family=by_family,
        input_hash=hash_hex(data),
        output_hash=hash_hex(frame),
        roundtrip=True,
    )
    return frame, stats


def decode_frame(frame: bytes) -> bytes:
    if len(frame) < len(MAGIC) + 2 + 4:
        raise ValueError("truncated frame")
    if frame[:4] != MAGIC:
        raise ValueError("bad frame magic")
    mode_code, order_code = frame[4], frame[5]
    mode = CODE_MODES.get(mode_code, "dafsa" if mode_code == 3 else None)
    if mode is None or order_code not in CODE_ORDERS:
        raise ValueError("bad frame mode/order")
    pos = 6
    raw_len, pos = take_uvarint(frame, pos)
    count, pos = take_uvarint(frame, pos)
    model_len, pos = take_uvarint(frame, pos)
    payload_len, pos = take_uvarint(frame, pos)
    if model_len > len(frame) - pos:
        raise ValueError("model overrun")
    model = frame[pos : pos + model_len]
    pos += model_len
    if payload_len > len(frame) - pos - 4:
        raise ValueError("payload overrun")
    payload = frame[pos : pos + payload_len]
    pos += payload_len
    if pos + 4 != len(frame):
        raise ValueError("trailing frame bytes")
    if mode == "dafsa":
        words = deserialize_dafsa(model, count, max(raw_len, MAX_OUTPUT_DEFAULT))
    else:
        words, _ = deserialize_model(model, count, mode, max(raw_len, MAX_OUTPUT_DEFAULT))
    decoded = decode_payload(payload, words, raw_len)
    expected_crc = struct.unpack_from("<I", frame, pos)[0]
    if zlib.crc32(decoded) & 0xFFFFFFFF != expected_crc:
        raise ValueError("payload CRC mismatch")
    return decoded


def parse_mode_list(raw: str) -> list[str]:
    modes = [item.strip() for item in raw.split(",") if item.strip()]
    allowed = {"independent", "cut", "edit", "program", "dafsa"}
    if not modes or any(mode not in allowed for mode in modes):
        raise ValueError(f"modes must be a comma list from {sorted(allowed)}")
    return modes


def run_screen(args: argparse.Namespace) -> list[dict[str, object]]:
    path = pathlib.Path(args.input)
    full = path.read_bytes()
    data = full[: args.limit] if args.limit else full
    first_words, pieces = scan(data)
    modes = parse_mode_list(args.modes)
    orders = [args.order] if args.order != "both" else ["first", "lex"]
    rows: list[dict[str, object]] = []
    print(
        json.dumps(
            {
                "input": str(path),
                "input_bytes": len(data),
                "source_bytes": len(full),
                "input_hash": hash_hex(data),
                "word_types": len(first_words),
                "word_occurrences": sum(piece.is_word for piece in pieces),
                "literal_pieces": sum(not piece.is_word for piece in pieces),
                "limit": args.limit,
                "max_edits": args.max_edits,
                "max_word": args.max_word,
                "edit_limit": args.edit_limit,
            },
            sort_keys=True,
        )
    )
    for mode in modes:
        mode_orders = ["lex"] if mode == "dafsa" else orders
        for order in mode_orders:
            frame, stats = build_frame(
                data,
                first_words,
                pieces,
                mode,
                order,
                args.max_edits,
                args.max_word,
                args.edit_limit,
            )
            row = stats.as_dict()
            row["frame_bytes"] = len(frame)
            rows.append(row)
            print(json.dumps(row, sort_keys=True))
    return rows


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="exact byte input")
    parser.add_argument("--limit", type=int, default=262_144, help="prefix bytes to screen (0 means all)")
    parser.add_argument(
        "--modes",
        default="independent,cut,edit,dafsa",
        help="comma list: independent,cut,edit,program,dafsa",
    )
    parser.add_argument("--order", choices=("first", "lex", "both"), default="both")
    parser.add_argument("--max-edits", type=int, default=4)
    parser.add_argument("--max-word", type=int, default=128)
    parser.add_argument(
        "--edit-limit",
        type=int,
        default=2_000,
        help="only first N ordered types get edit candidates; others remain independent",
    )
    args = parser.parse_args(argv)
    if args.limit < 0 or args.max_edits < 0 or args.max_word < 1 or args.edit_limit < 0:
        parser.error("limits must be non-negative and max-word positive")
    try:
        run_screen(args)
    except (OSError, ValueError, AssertionError) as exc:
        print(f"screen failed: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
