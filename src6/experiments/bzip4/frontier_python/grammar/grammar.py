"""Global batch pair grammar reference codec for the bzip4 frontier.

This is an intentionally small, auditable grammar experiment.  The encoder may
look at the complete byte string, but every piece of decoder state it discovers
is written into the frame: the ordered grammar DAG, literal alphabet, canonical
code lengths, restart directory, checksums, and bit padding.  Encoder-only
frequency counts are retained for metrics and are intentionally not wire state.

The grammar builder uses deterministic batched pair substitution.  A pass
counts adjacent symbol pairs in all raw blocks, chooses high-count pairs, and
replaces every selected non-overlapping pair in one scan.  Rules are appended
after a pass, so their children always have earlier IDs.  Reachability/use
post-pruning inlines unused and one-use rules; the surviving DAG is serialized
with ULEB128 references.  The decoder pre-expands the bounded rules exactly
once, then decodes each block with a canonical Huffman (or fixed-width
diagnostic) stream and performs bulk byte copies from a flat expansion table.

The ingredients are established grammar/dictionary techniques, not a novelty
claim.  The experiment's falsifiable question is whether a charged shared DAG
reduces complete independently-addressable frames on the frozen dictionary
corpora without making preparation unbounded.
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
import binascii
import heapq
import math
import struct
import time
from typing import Iterable, Sequence


MAGIC = b"GBR1"
MODEL_MAGIC = b"GMD1"
VERSION = 1
MODEL_VERSION = 1
ALGORITHM_ID = 1  # batched pair-substitution grammar
CODER_HUFFMAN = 0
CODER_FIXED = 1
SCOPE_INPUT = 0
SCOPE_TRAINING = 1

# Header: magic, version, flags, header size, block target, block count,
# raw length, model length, directory length, payload length, metadata CRC,
# reserved.  All metadata is covered by the CRC with the CRC field zeroed.
HEADER = struct.Struct("<4sBBHIIQIIQII")
HEADER_BYTES = HEADER.size
# Payload-relative offset, encoded length, raw length, decoded CRC-32, valid
# bit count.  The final field charges canonical bit padding explicitly.
DIR = struct.Struct("<QIIII")
DIR_BYTES = DIR.size
# Model magic, version, coder, algorithm, scope, rule count, source bytes,
# symbol count.
MODEL_HEAD = struct.Struct("<4sBBBBIQI")
MODEL_HEAD_BYTES = MODEL_HEAD.size

MAX_FRAME_BYTES = 512 * 1024 * 1024
MAX_RAW_BYTES = 512 * 1024 * 1024
MAX_BLOCKS = 1_000_000
MAX_BLOCK_BYTES = 4 * 1024 * 1024
MAX_MODEL_BYTES = 16 * 1024 * 1024
MAX_RULES = 8192
MAX_RULE_ARITY = 512
MAX_EXPANSION_BYTES = 512
MAX_PREEXPANDED_BYTES = 8 * 1024 * 1024
MAX_CODE_BITS = 32
PAIR_BASE = 256 + MAX_RULES

_LEAF_TABLE = tuple(bytes((value,)) for value in range(256))
_LAST_METRICS: dict[str, object] = {}


class FrameError(ValueError):
    """Raised for malformed, truncated, or resource-exhausting frames."""


class ModelError(ValueError):
    """Raised for malformed or internally inconsistent grammar models."""


def _put_uleb(value: int) -> bytes:
    if value < 0:
        raise ValueError("ULEB128 cannot encode a negative value")
    result = bytearray()
    while value >= 0x80:
        result.append((value & 0x7F) | 0x80)
        value >>= 7
    result.append(value)
    return bytes(result)


def _uleb_len(value: int) -> int:
    return len(_put_uleb(value))


def _read_uleb(data: bytes, at: int, *, limit: int = (1 << 63) - 1) -> tuple[int, int]:
    value = 0
    shift = 0
    for count in range(10):
        if at >= len(data):
            raise FrameError("truncated ULEB128")
        part = data[at]
        at += 1
        if count == 9 and part > 1:
            raise FrameError("ULEB128 integer overflow")
        value |= (part & 0x7F) << shift
        if not (part & 0x80):
            if count and part == 0:
                raise FrameError("non-canonical ULEB128")
            if value > limit:
                raise FrameError("ULEB128 value exceeds bound")
            return value, at
        shift += 7
    raise FrameError("ULEB128 integer overflow")


def _crc(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF


def _derive_expansions(rules: Sequence[Sequence[int]]) -> tuple[bytes, ...]:
    """Validate earlier-reference order and return bounded flat expansions."""

    if len(rules) > MAX_RULES:
        raise ModelError("too many grammar rules")
    expansions: list[bytes] = []
    total = 0
    for index, rule in enumerate(rules):
        if not 2 <= len(rule) <= MAX_RULE_ARITY:
            raise ModelError("grammar rule arity outside bound")
        output = bytearray()
        for ref in rule:
            if not isinstance(ref, int) or ref < 0 or ref >= 256 + index:
                raise ModelError("rule contains a forward or invalid reference")
            if ref < 256:
                output.append(ref)
            else:
                child = expansions[ref - 256]
                if len(output) + len(child) > MAX_EXPANSION_BYTES:
                    raise ModelError("grammar expansion exceeds bound")
                output.extend(child)
        if not output or len(output) > MAX_EXPANSION_BYTES:
            raise ModelError("invalid grammar expansion length")
        total += len(output)
        if total > MAX_PREEXPANDED_BYTES:
            raise ModelError("pre-expanded grammar table exceeds bound")
        expansions.append(bytes(output))
    return tuple(expansions)


def _huffman_lengths(frequencies: Sequence[int]) -> tuple[int, ...]:
    """Build deterministic canonical Huffman lengths.

    A highly pathological frequency sequence can produce a very deep tree.
    The bounded fallback is still a valid canonical code and keeps the frame
    parser's one-byte length table and bit reader resource-bounded.
    """

    used = [index for index, count in enumerate(frequencies) if count > 0]
    lengths = [0] * len(frequencies)
    if not used:
        return tuple(lengths)
    if len(used) == 1:
        lengths[used[0]] = 1
        return tuple(lengths)

    # Node IDs below len(frequencies) are leaves.  Internal IDs follow.
    parent: list[int] = [-1] * len(frequencies)
    heap: list[tuple[int, int, int]] = []
    next_node = len(frequencies)
    for symbol in used:
        heapq.heappush(heap, (int(frequencies[symbol]), symbol, symbol))
    while len(heap) > 1:
        left_count, left_min, left = heapq.heappop(heap)
        right_count, right_min, right = heapq.heappop(heap)
        node = next_node
        next_node += 1
        while len(parent) <= node:
            parent.append(-1)
        parent[left] = node
        parent[right] = node
        heapq.heappush(heap, (left_count + right_count, min(left_min, right_min), node))

    maximum = 0
    for symbol in used:
        depth = 0
        node = symbol
        while parent[node] >= 0:
            depth += 1
            node = parent[node]
        lengths[symbol] = depth
        maximum = max(maximum, depth)
    if maximum > MAX_CODE_BITS:
        width = max(1, (len(used) - 1).bit_length())
        for symbol in used:
            lengths[symbol] = width
    return tuple(lengths)


def _canonical_codes(lengths: Sequence[int]) -> tuple[tuple[int, int] | None, ...]:
    entries = sorted((length, symbol) for symbol, length in enumerate(lengths) if length)
    result: list[tuple[int, int] | None] = [None] * len(lengths)
    code = 0
    previous = 0
    for length, symbol in entries:
        if length < 1 or length > MAX_CODE_BITS:
            raise ModelError("Huffman code length outside bound")
        code <<= length - previous
        if code >= (1 << length):
            raise ModelError("oversubscribed canonical Huffman lengths")
        result[symbol] = (code, length)
        code += 1
        previous = length
    return tuple(result)


def _huffman_tree(lengths: Sequence[int]) -> tuple[tuple[int, int, int], ...]:
    codes = _canonical_codes(lengths)
    tree: list[list[int]] = [[-1, -1, -1]]
    for symbol, item in enumerate(codes):
        if item is None:
            continue
        code, width = item
        node = 0
        for bit_index in range(width - 1, -1, -1):
            if tree[node][2] >= 0:
                raise FrameError("Huffman code is a prefix of another code")
            bit = (code >> bit_index) & 1
            child = tree[node][bit]
            if child < 0:
                child = len(tree)
                tree[node][bit] = child
                tree.append([-1, -1, -1])
            node = child
        if tree[node][2] >= 0 or tree[node][0] >= 0 or tree[node][1] >= 0:
            raise FrameError("duplicate or non-canonical Huffman code")
        tree[node][2] = symbol
    return tuple((left, right, symbol) for left, right, symbol in tree)


def _encode_huffman(tokens: Sequence[int], lengths: Sequence[int]) -> tuple[bytes, int]:
    codes = _canonical_codes(lengths)
    output = bytearray()
    accumulator = 0
    bits = 0
    for symbol in tokens:
        if symbol < 0 or symbol >= len(codes) or codes[symbol] is None:
            raise ModelError(f"symbol {symbol} has no Huffman code")
        code, width = codes[symbol]  # type: ignore[misc]
        accumulator = (accumulator << width) | code
        bits += width
        while bits >= 8:
            bits -= 8
            output.append((accumulator >> bits) & 0xFF)
            if bits:
                accumulator &= (1 << bits) - 1
            else:
                accumulator = 0
    if bits:
        output.append((accumulator << (8 - bits)) & 0xFF)
    return bytes(output), len(output) * 8 if bits == 0 else (len(output) - 1) * 8 + bits


def _encode_fixed(tokens: Sequence[int], symbol_count: int) -> tuple[bytes, int]:
    width = max(1, (symbol_count - 1).bit_length())
    output = bytearray()
    accumulator = 0
    bits = 0
    for symbol in tokens:
        if symbol < 0 or symbol >= symbol_count:
            raise ModelError("fixed-width symbol outside alphabet")
        accumulator = (accumulator << width) | symbol
        bits += width
        while bits >= 8:
            bits -= 8
            output.append((accumulator >> bits) & 0xFF)
            if bits:
                accumulator &= (1 << bits) - 1
            else:
                accumulator = 0
    if bits:
        output.append((accumulator << (8 - bits)) & 0xFF)
    return bytes(output), len(tokens) * width


def _decode_huffman(
    body: bytes,
    valid_bits: int,
    tree: Sequence[tuple[int, int, int]],
    *,
    max_symbols: int | None = None,
) -> list[int]:
    if valid_bits <= 0 or (valid_bits + 7) // 8 != len(body):
        raise FrameError("invalid Huffman bit count")
    if valid_bits & 7:
        padding = 8 - (valid_bits & 7)
        if body and body[-1] & ((1 << padding) - 1):
            raise FrameError("non-zero Huffman padding")
    output: list[int] = []
    node = 0
    for position in range(valid_bits):
        bit = (body[position // 8] >> (7 - (position & 7))) & 1
        child = tree[node][bit]
        if child < 0:
            raise FrameError("Huffman stream enters a missing branch")
        node = child
        symbol = tree[node][2]
        if symbol >= 0:
            output.append(symbol)
            if max_symbols is not None and len(output) > max_symbols:
                raise FrameError("Huffman token count exceeds declared block bound")
            node = 0
    if node != 0:
        raise FrameError("Huffman stream ends in an incomplete code")
    return output


def _decode_fixed(
    body: bytes,
    valid_bits: int,
    symbol_count: int,
    *,
    max_symbols: int | None = None,
) -> list[int]:
    width = max(1, (symbol_count - 1).bit_length())
    if valid_bits <= 0 or (valid_bits + 7) // 8 != len(body) or valid_bits % width:
        raise FrameError("invalid fixed-width bit count")
    padding = (-valid_bits) & 7
    if padding and body[-1] & ((1 << padding) - 1):
        raise FrameError("non-zero fixed-width padding")
    result: list[int] = []
    for start in range(0, valid_bits, width):
        value = 0
        for bit_offset in range(width):
            position = start + bit_offset
            value = (value << 1) | ((body[position // 8] >> (7 - (position & 7))) & 1)
        if value >= symbol_count:
            raise FrameError("fixed-width symbol outside alphabet")
        result.append(value)
        if max_symbols is not None and len(result) > max_symbols:
            raise FrameError("fixed-width token count exceeds declared block bound")
    return result


def _token_blocks(data: bytes, block_bytes: int) -> list[list[int]]:
    return [list(data[start : start + block_bytes]) for start in range(0, len(data), block_bytes)]


def _packed_pair(left: int, right: int) -> int:
    return left * PAIR_BASE + right


def _build_grammar(
    data: bytes,
    block_bytes: int,
    *,
    max_rules: int = 4096,
    max_passes: int = 10,
    min_count: int = 4,
    pair_policy: str = "overlap_greedy",
) -> tuple[tuple[tuple[int, ...], ...], list[list[int]], dict[str, object]]:
    """Build one shared DAG over block-local symbol streams.

    Pair counts use packed integer keys rather than tuple objects.  This keeps
    encoder memory bounded on the full 8 MiB lane while retaining deterministic
    global aggregation.  Rule creation is batched per pass, so no O(N*rules)
    rescanning occurs.
    """

    if block_bytes <= 0 or block_bytes > MAX_BLOCK_BYTES:
        raise ValueError("block_bytes outside grammar bound")
    if max_rules < 0 or max_rules > MAX_RULES:
        raise ValueError("max_rules outside grammar bound")
    if pair_policy not in {"overlap_greedy", "consistent"}:
        raise ValueError("pair_policy must be 'overlap_greedy' or 'consistent'")
    blocks = _token_blocks(data, block_bytes)
    rules: list[tuple[int, ...]] = []
    expansions = list(_LEAF_TABLE)
    passes = 0
    replacements = 0
    candidates_seen = 0
    max_per_pass = 512

    while passes < max_passes and len(rules) < max_rules:
        passes += 1
        counts: dict[int, int] = {}
        for sequence in blocks:
            for at in range(len(sequence) - 1):
                key = _packed_pair(sequence[at], sequence[at + 1])
                counts[key] = counts.get(key, 0) + 1
        if not counts:
            break
        ranked: list[tuple[int, int, int, int]] = []
        for key, count in counts.items():
            if count < min_count:
                continue
            left, right = divmod(key, PAIR_BASE)
            if left >= len(expansions) or right >= len(expansions):
                raise ModelError("pair counter produced invalid symbol")
            expanded_len = len(expansions[left]) + len(expansions[right])
            if expanded_len > MAX_EXPANSION_BYTES:
                continue
            # Each rule has at least arity+two ULEB references and an event
            # record.  This conservative score avoids creating many rules that
            # post-pruning would immediately discard.
            definition_cost = 3 + _uleb_len(left) + _uleb_len(right)
            score = count - definition_cost
            if score > 0:
                ranked.append((score, count, left, right))
        if not ranked:
            break
        ranked.sort(key=lambda item: (-item[0], -item[1], item[2], item[3]))
        ranked = ranked[: min(max_per_pass, max_rules - len(rules))]
        if pair_policy == "consistent":
            # SEA/SPiRE-style ChoosingPairs control: reject self-pairs and
            # select a role-consistent matching.  A token cannot be the right
            # side of one selected pair and the left side of another, so the
            # selected pairs cannot overlap during replacement.
            selected_candidates: list[tuple[int, int, int, int]] = []
            used_left: set[int] = set()
            used_right: set[int] = set()
            for candidate in ranked:
                _, _, left, right = candidate
                if left == right or left in used_right or right in used_left:
                    continue
                selected_candidates.append(candidate)
                used_left.add(left)
                used_right.add(right)
            ranked = selected_candidates
        candidates_seen += len(ranked)
        selected = {_packed_pair(left, right): position for position, (_, _, left, right) in enumerate(ranked)}
        base = len(rules)
        changed_blocks: list[list[int]] = []
        used: set[int] = set()
        for sequence in blocks:
            result: list[int] = []
            at = 0
            while at < len(sequence):
                if at + 1 < len(sequence):
                    key = _packed_pair(sequence[at], sequence[at + 1])
                    position = selected.get(key)
                    if position is not None:
                        result.append(256 + base + position)
                        used.add(position)
                        replacements += 1
                        at += 2
                        continue
                result.append(sequence[at])
                at += 1
            changed_blocks.append(result)
        if not used:
            break
        remap: dict[int, int] = {}
        for position, (_, _, left, right) in enumerate(ranked):
            if position in used:
                remap[position] = 256 + len(rules)
                rules.append((left, right))
                expansions.append(expansions[left] + expansions[right])
        blocks = [
            [remap.get(value - 256 - base, value) if value >= 256 + base else value for value in sequence]
            for sequence in changed_blocks
        ]

    # Reachability/use post-pruning.  A rule is worth retaining when it has
    # at least two *stored* references: root-stream occurrences plus direct
    # references from each reachable rule definition counted once.  Do not
    # multiply a child by the runtime expansion count of a parent.  A child
    # appearing once in a rule used a thousand times still has one stored
    # definition site and should be inlined into that parent.
    reachable: set[int] = set()
    pending: list[int] = [ref - 256 for sequence in blocks for ref in sequence if ref >= 256]
    while pending:
        index = pending.pop()
        if index in reachable:
            continue
        if index < 0 or index >= len(rules):
            raise ModelError("pruning saw an invalid reachable rule")
        reachable.add(index)
        pending.extend(ref - 256 for ref in rules[index] if ref >= 256)
    uses = [0] * len(rules)
    for sequence in blocks:
        for ref in sequence:
            if ref >= 256:
                uses[ref - 256] = min(2, uses[ref - 256] + 1)
    for index in reachable:
        for ref in rules[index]:
            if ref >= 256:
                child = ref - 256
                uses[child] = min(2, uses[child] + 1)
    keep = [count >= 2 for count in uses]
    new_ids: dict[int, int] = {}
    for index, retain in enumerate(keep):
        if retain:
            new_ids[index] = 256 + len(new_ids)
    memo: dict[int, tuple[int, ...]] = {}

    def lower(ref: int) -> tuple[int, ...]:
        if ref < 256:
            return (ref,)
        index = ref - 256
        if keep[index]:
            return (new_ids[index],)
        if index in memo:
            return memo[index]
        output: list[int] = []
        for child in rules[index]:
            output.extend(lower(child))
        if not output:
            raise ModelError("pruning produced an empty rule")
        memo[index] = tuple(output)
        return memo[index]

    pruned_rules: list[tuple[int, ...]] = []
    for index, retain in enumerate(keep):
        if retain:
            children: list[int] = []
            for child in rules[index]:
                children.extend(lower(child))
            if len(children) < 2:
                raise ModelError("retained rule collapsed below binary arity")
            pruned_rules.append(tuple(children))
    pruned_blocks = [[child for ref in sequence for child in lower(ref)] for sequence in blocks]
    # Validate the final DAG and ensure pruning did not create oversized rules.
    _derive_expansions(pruned_rules)
    return tuple(pruned_rules), pruned_blocks, {
        "passes": passes,
        "candidate_pairs": candidates_seen,
        "batched_replacements": replacements,
        "pre_prune_rules": len(rules),
        "post_prune_rules": len(pruned_rules),
        "pair_policy": pair_policy,
    }


def _frequencies(blocks: Sequence[Sequence[int]], symbol_count: int) -> tuple[int, ...]:
    # Literal escapes have a unit prior so every arbitrary byte remains
    # decodable.  Internal rules are coded only when they occur as top-level
    # events in this model; a frozen model therefore skips uncoded rules during
    # held-out tokenization and falls back to literals.  Canonical lengths are
    # the complete decoder entropy model; raw frequencies remain diagnostics.
    counts = [1] * min(256, symbol_count)
    counts.extend([0] * (symbol_count - len(counts)))
    for sequence in blocks:
        for symbol in sequence:
            if symbol < 0 or symbol >= symbol_count:
                raise ModelError("token outside model alphabet")
            counts[symbol] += 1
    return tuple(counts)


def _build_model_from_blocks(
    data: bytes,
    blocks: list[list[int]],
    rules: tuple[tuple[int, ...], ...],
    *,
    coder: str,
    scope: str,
    grammar_metrics: dict[str, object],
) -> "Model":
    if coder not in {"huff", "fixed"}:
        raise ValueError("coder must be 'huff' or 'fixed'")
    symbol_count = 256 + len(rules)
    frequencies = _frequencies(blocks, symbol_count)
    lengths = _huffman_lengths(frequencies) if coder == "huff" else tuple(0 for _ in range(symbol_count))
    grammar_metrics = dict(grammar_metrics)
    if rules:
        rule_expansions = _derive_expansions(rules)
        grammar_metrics["max_rule_expansion_bytes"] = max(len(value) for value in rule_expansions)
        grammar_metrics["avg_rule_expansion_bytes"] = sum(len(value) for value in rule_expansions) / len(rules)
    else:
        grammar_metrics["max_rule_expansion_bytes"] = 0
        grammar_metrics["avg_rule_expansion_bytes"] = 0.0
    model = Model(
        rules=rules,
        coder=coder,
        scope=scope,
        training_bytes=len(data),
        frequencies=frequencies,
        code_lengths=lengths,
        grammar_metrics=grammar_metrics,
    )
    return model


def _build_input_model(
    data: bytes,
    block_bytes: int,
    *,
    coder: str,
    max_rules: int,
    max_passes: int,
    min_count: int,
    pair_policy: str,
) -> tuple["Model", list[list[int]]]:
    rules, blocks, grammar_metrics = _build_grammar(
        data,
        block_bytes,
        max_rules=max_rules,
        max_passes=max_passes,
        min_count=min_count,
        pair_policy=pair_policy,
    )
    return _build_model_from_blocks(data, blocks, rules, coder=coder, scope="input", grammar_metrics=grammar_metrics), blocks


def train(
    training: bytes,
    *,
    block_bytes: int = 16 * 1024,
    coder: str = "huff",
    max_rules: int = 4096,
    max_passes: int = 10,
    min_count: int = 4,
    pair_policy: str = "overlap_greedy",
) -> "Model":
    """Build a frozen grammar/model from a disjoint training byte prefix."""

    if not isinstance(training, (bytes, bytearray, memoryview)):
        raise TypeError("training must be bytes-like")
    raw = bytes(training)
    model, _ = _build_input_model(
        raw,
        block_bytes,
        coder=coder,
        max_rules=max_rules,
        max_passes=max_passes,
        min_count=min_count,
        pair_policy=pair_policy,
    )
    model.scope = "training"
    return model


@dataclass
class Model:
    rules: tuple[tuple[int, ...], ...]
    coder: str = "huff"
    scope: str = "input"
    training_bytes: int = 0
    frequencies: tuple[int, ...] = ()
    code_lengths: tuple[int, ...] = ()
    grammar_metrics: dict[str, object] | None = None
    expansions: tuple[bytes, ...] = ()

    def __post_init__(self) -> None:
        if self.coder not in {"huff", "fixed"}:
            raise ModelError("unknown entropy coder")
        if self.scope not in {"input", "training"}:
            raise ModelError("unknown model scope")
        self.rules = tuple(tuple(int(ref) for ref in rule) for rule in self.rules)
        self.expansions = _derive_expansions(self.rules)
        symbol_count = self.symbol_count
        if self.frequencies:
            if len(self.frequencies) != symbol_count or any(value < 0 for value in self.frequencies):
                raise ModelError("frequency table length/value mismatch")
        else:
            self.frequencies = tuple([1] * 256 + [0] * len(self.rules))
        if self.coder == "huff":
            if any(value <= 0 for value in self.frequencies[:256]):
                raise ModelError("Huffman literal frequencies must be positive")
            if self.code_lengths:
                if len(self.code_lengths) != symbol_count:
                    raise ModelError("Huffman length table length mismatch")
                if any(length <= 0 for length in self.code_lengths[:256]):
                    raise ModelError("Huffman literal code lengths must be positive")
                _canonical_codes(self.code_lengths)
            else:
                self.code_lengths = _huffman_lengths(self.frequencies)
        else:
            self.code_lengths = tuple(0 for _ in range(symbol_count))
        if self.training_bytes < 0 or self.training_bytes > MAX_RAW_BYTES:
            raise ModelError("training byte count outside bound")

    @property
    def rule_count(self) -> int:
        return len(self.rules)

    @property
    def symbol_count(self) -> int:
        return 256 + len(self.rules)

    @property
    def preexpanded_bytes(self) -> int:
        return sum(len(value) for value in self.expansions)

    def serialize(self) -> bytes:
        if self.rule_count > MAX_RULES:
            raise ModelError("too many grammar rules")
        coder_id = CODER_HUFFMAN if self.coder == "huff" else CODER_FIXED
        scope_id = SCOPE_INPUT if self.scope == "input" else SCOPE_TRAINING
        result = bytearray(
            MODEL_HEAD.pack(
                MODEL_MAGIC,
                MODEL_VERSION,
                coder_id,
                ALGORITHM_ID,
                scope_id,
                self.rule_count,
                self.training_bytes,
                self.symbol_count,
            )
        )
        for rule in self.rules:
            result.extend(_put_uleb(len(rule)))
            for ref in rule:
                if ref < 0 or ref >= 256 + self.rule_count:
                    raise ModelError("rule reference outside model alphabet")
                result.extend(_put_uleb(ref))
        # Canonical lengths are sufficient to reconstruct the complete code;
        # frequencies would be redundant decoder state and are deliberately
        # retained only in encoder-side metrics.  A dense byte table makes the
        # charged alphabet explicit and keeps model parsing bounded.
        if self.coder == "huff":
            if len(self.code_lengths) != self.symbol_count:
                raise ModelError("wrong Huffman length table")
            result.extend(bytes(self.code_lengths))
        if len(result) > MAX_MODEL_BYTES:
            raise ModelError("serialized grammar model exceeds bound")
        return bytes(result)

    @classmethod
    def from_bytes(cls, data: bytes) -> "Model":
        if len(data) < MODEL_HEAD_BYTES:
            raise FrameError("truncated grammar model header")
        magic, version, coder_id, algorithm, scope_id, rule_count, training_bytes, symbol_count = MODEL_HEAD.unpack_from(data)
        if magic != MODEL_MAGIC or version != MODEL_VERSION or algorithm != ALGORITHM_ID:
            raise FrameError("invalid grammar model header")
        if coder_id not in {CODER_HUFFMAN, CODER_FIXED} or scope_id not in {SCOPE_INPUT, SCOPE_TRAINING}:
            raise FrameError("invalid grammar coder or scope")
        if rule_count > MAX_RULES or symbol_count != 256 + rule_count:
            raise FrameError("invalid grammar symbol count")
        at = MODEL_HEAD_BYTES
        rules: list[tuple[int, ...]] = []
        for index in range(rule_count):
            arity, at = _read_uleb(data, at, limit=MAX_RULE_ARITY)
            if arity < 2:
                raise FrameError("grammar rule arity below two")
            children: list[int] = []
            for _ in range(arity):
                ref, at = _read_uleb(data, at, limit=255 + index)
                if ref >= 256 + index:
                    raise FrameError("grammar forward reference")
                children.append(ref)
            rules.append(tuple(children))
        if coder_id == CODER_HUFFMAN:
            if len(data) - at != symbol_count:
                raise FrameError("grammar Huffman length table has wrong size")
            lengths = list(data[at : at + symbol_count])
            at += symbol_count
            if any(length > MAX_CODE_BITS for length in lengths):
                raise FrameError("grammar code length outside bound")
            # Frequencies are intentionally not wire state.  Internal rules
            # may legitimately have length zero when they occur only inside a
            # retained definition; literals must remain codeable escapes.
            frequencies = [1] * 256 + [0] * rule_count
        else:
            lengths = [0] * symbol_count
            frequencies = [1] * 256 + [0] * rule_count
        if at != len(data):
            raise FrameError("trailing grammar model bytes")
        if any(frequencies[index] == 0 for index in range(256)):
            raise FrameError("grammar model omitted a literal frequency")
        coder = "huff" if coder_id == CODER_HUFFMAN else "fixed"
        if coder == "huff":
            if any(length <= 0 for length in lengths[:256]):
                raise FrameError("grammar Huffman table omitted a literal")
            try:
                _canonical_codes(lengths)
            except ModelError as exc:
                raise FrameError(str(exc)) from exc
        try:
            model = cls(
                rules=tuple(rules),
                coder=coder,
                scope="input" if scope_id == SCOPE_INPUT else "training",
                training_bytes=training_bytes,
                frequencies=tuple(frequencies),
                code_lengths=tuple(lengths),
            )
        except ModelError as exc:
            # A model blob is already at the hostile-wire boundary.  Do not
            # leak an internal constructor exception to callers of prepare().
            raise FrameError(str(exc)) from exc
        return model


def _build_trie(model: Model) -> tuple[list[dict[int, int]], list[int]]:
    trie: list[dict[int, int]] = [{}]
    terminal = [-1]
    for index, expansion in enumerate(model.expansions):
        symbol = 256 + index
        # A hand-built/future frozen model may omit an event code for an
        # internal rule that is never a top-level training symbol.  Keep its
        # literal edges available through the trie, but never select an
        # uncodable rule during held-out tokenization.
        if model.coder == "huff" and model.code_lengths[symbol] == 0:
            continue
        node = 0
        for value in expansion:
            child = trie[node].get(value)
            if child is None:
                child = len(trie)
                trie[node][value] = child
                trie.append({})
                terminal.append(-1)
            node = child
        # Longest-match ties choose the earlier rule ID for determinism.
        if terminal[node] < 0 or symbol < terminal[node]:
            terminal[node] = symbol
    return trie, terminal


def _tokenize_with_model(data: bytes, model: Model) -> list[int]:
    if not model.rules:
        return list(data)
    trie, terminal = _build_trie(model)
    output: list[int] = []
    at = 0
    while at < len(data):
        node = 0
        best = -1
        best_length = 0
        cursor = at
        while cursor < len(data):
            child = trie[node].get(data[cursor])
            if child is None:
                break
            node = child
            cursor += 1
            if terminal[node] >= 0:
                best = terminal[node]
                best_length = cursor - at
        if best < 0:
            output.append(data[at])
            at += 1
        else:
            output.append(best)
            at += best_length
    return output


@dataclass(frozen=True)
class DirectoryRecord:
    offset: int
    encoded_bytes: int
    raw_bytes: int
    crc32: int
    valid_bits: int


@dataclass
class Prepared:
    frame: bytes
    model: Model
    block_bytes: int
    raw_length: int
    records: tuple[DirectoryRecord, ...]
    model_bytes: int
    directory_bytes: int
    payload_offset: int
    setup_ns: int = 0
    decode_symbol_ops: int = 0
    decode_copy_bytes: int = 0
    _huffman_tree: tuple[tuple[int, int, int], ...] = ()
    _symbol_table: tuple[bytes, ...] = ()

    def decode_block(self, index: int) -> bytes:
        if index < 0 or index >= len(self.records):
            raise FrameError("block index out of range")
        record = self.records[index]
        start = self.payload_offset + record.offset
        end = start + record.encoded_bytes
        if start < self.payload_offset or end > len(self.frame):
            raise FrameError("block payload outside frame")
        payload = self.frame[start:end]
        if not payload:
            raise FrameError("empty grammar block payload")
        mode = payload[0]
        body = payload[1:]
        if mode == 0:
            if record.valid_bits != 0 or len(body) != record.raw_bytes:
                raise FrameError("invalid raw grammar block metadata")
            result = bytes(body)
        elif mode == 1:
            expected = (record.valid_bits + 7) // 8
            if record.valid_bits <= 0 or len(body) != expected:
                raise FrameError("invalid coded grammar block bit length")
            if self.model.coder == "huff":
                symbols = _decode_huffman(body, record.valid_bits, self._huffman_tree, max_symbols=record.raw_bytes)
            else:
                symbols = _decode_fixed(body, record.valid_bits, self.model.symbol_count, max_symbols=record.raw_bytes)
            output = bytearray()
            for symbol in symbols:
                if symbol < 0 or symbol >= len(self._symbol_table):
                    raise FrameError("decoded grammar symbol outside table")
                expansion = self._symbol_table[symbol]
                if len(output) + len(expansion) > record.raw_bytes:
                    raise FrameError("decoded grammar block exceeds declared length")
                output.extend(expansion)
                self.decode_symbol_ops += 1
                self.decode_copy_bytes += len(expansion)
            if len(output) != record.raw_bytes:
                raise FrameError("decoded grammar block length mismatch")
            result = bytes(output)
        else:
            raise FrameError("unknown grammar block mode")
        if _crc(result) != record.crc32:
            raise FrameError("grammar block checksum mismatch")
        return result

    def decode_all(self) -> bytes:
        if not self.records:
            if self.raw_length != 0:
                raise FrameError("empty grammar directory with non-empty frame")
            return b""
        result = bytearray()
        for index in range(len(self.records)):
            result.extend(self.decode_block(index))
        if len(result) != self.raw_length:
            raise FrameError("grammar frame output length mismatch")
        return bytes(result)


def _metadata_crc(header_without_crc: bytes, model_blob: bytes, directory: bytes) -> int:
    return _crc(header_without_crc + model_blob + directory)


def _frame(
    raw_blocks: Sequence[bytes],
    encoded_blocks: Sequence[bytes],
    model: Model,
    block_bytes: int,
) -> bytes:
    if len(raw_blocks) != len(encoded_blocks):
        raise FrameError("raw/encoded block count mismatch")
    model_blob = model.serialize()
    directory = bytearray(len(raw_blocks) * DIR_BYTES)
    payload = bytearray()
    raw_total = sum(len(block) for block in raw_blocks)
    if raw_total > MAX_RAW_BYTES:
        raise FrameError("raw frame exceeds limit")
    offset = 0
    for index, (raw, encoded) in enumerate(zip(raw_blocks, encoded_blocks)):
        if not raw or len(raw) > block_bytes or not encoded:
            raise FrameError(f"invalid grammar block lengths at {index}")
        mode = encoded[0]
        valid_bits = 0 if mode == 0 else getattr(encoded, "valid_bits", 0)
        # Encoded blocks carry the valid-bit count in a private tuple-like
        # wrapper in encode(); this branch is replaced before framing.
        if len(encoded) > 0xFFFFFFFF:
            raise FrameError("encoded grammar block exceeds u32 length")
        payload.extend(encoded)
        # Placeholder filled by encode() through _frame_with_bits.
        DIR.pack_into(directory, index * DIR_BYTES, offset, len(encoded), len(raw), _crc(raw), valid_bits)
        offset += len(encoded)
    if raw_total == 0 and raw_blocks:
        raise FrameError("empty raw block list must represent an empty frame")
    return _frame_with_directory(raw_total, raw_blocks, encoded_blocks, model_blob, bytes(directory), bytes(payload), block_bytes)


def _frame_with_directory(
    raw_total: int,
    raw_blocks: Sequence[bytes],
    encoded_blocks: Sequence[bytes],
    model_blob: bytes,
    directory: bytes,
    payload: bytes,
    block_bytes: int,
) -> bytes:
    count = len(raw_blocks)
    if count > MAX_BLOCKS or len(directory) != count * DIR_BYTES:
        raise FrameError("invalid grammar directory")
    header_zero = HEADER.pack(
        MAGIC,
        VERSION,
        0,
        HEADER_BYTES,
        block_bytes,
        count,
        raw_total,
        len(model_blob),
        len(directory),
        len(payload),
        0,
        0,
    )
    metadata_crc = _metadata_crc(header_zero, model_blob, directory)
    header = HEADER.pack(
        MAGIC,
        VERSION,
        0,
        HEADER_BYTES,
        block_bytes,
        count,
        raw_total,
        len(model_blob),
        len(directory),
        len(payload),
        metadata_crc,
        0,
    )
    frame = header + model_blob + directory + payload
    if len(frame) > MAX_FRAME_BYTES:
        raise FrameError("grammar frame exceeds limit")
    return frame


def encode(
    data: bytes,
    block_bytes: int = 16 * 1024,
    model: Model | None = None,
    *,
    variant: str = "input_huff",
    max_rules: int = 4096,
    max_passes: int = 10,
    min_count: int = 4,
    pair_policy: str = "overlap_greedy",
) -> bytes:
    """Encode independently addressed blocks against one charged grammar.

    With no model, ``variant`` chooses an input-fit grammar and event coder.
    This is ordinary two-pass compression, not held-out predictive training:
    the resulting grammar and canonical event lengths are serialized in the
    returned frame.
    Supplying ``model`` uses a frozen training grammar and its charged event
    model, rebuilding only block tokenization against that table.
    """

    if not isinstance(data, (bytes, bytearray, memoryview)):
        raise TypeError("data must be bytes-like")
    raw = bytes(data)
    if len(raw) > MAX_RAW_BYTES:
        raise FrameError("input exceeds grammar raw limit")
    if block_bytes <= 0 or block_bytes > MAX_BLOCK_BYTES:
        raise ValueError("block_bytes outside grammar bound")
    if model is None:
        if variant not in {"input_huff", "input_fixed", "huff", "fixed"}:
            raise ValueError("unknown input grammar variant")
        coder = "fixed" if variant in {"input_fixed", "fixed"} else "huff"
        model, token_blocks = _build_input_model(
            raw,
            block_bytes,
            coder=coder,
            max_rules=max_rules,
            max_passes=max_passes,
            min_count=min_count,
            pair_policy=pair_policy,
        )
    else:
        if not isinstance(model, Model):
            raise TypeError("model must be a grammar Model")
        token_blocks = [
            _tokenize_with_model(raw[start : start + block_bytes], model)
            for start in range(0, len(raw), block_bytes)
        ]
    raw_blocks = [raw[start : start + block_bytes] for start in range(0, len(raw), block_bytes)]
    encoded_blocks: list[bytes] = []
    valid_bits: list[int] = []
    coded_blocks = 0
    raw_fallbacks = 0
    entropy_bits = 0
    root_event_count = sum(len(tokens) for tokens in token_blocks)
    root_lengths = [
        (1 if symbol < 256 else len(model.expansions[symbol - 256]))
        for tokens in token_blocks
        for symbol in tokens
    ]
    symbol_count = model.symbol_count
    for raw_block, tokens in zip(raw_blocks, token_blocks):
        if model.coder == "huff":
            body, bits = _encode_huffman(tokens, model.code_lengths)
        else:
            body, bits = _encode_fixed(tokens, symbol_count)
        coded_candidate = b"\x01" + body
        raw_candidate = b"\x00" + raw_block
        if len(coded_candidate) < len(raw_candidate):
            encoded_blocks.append(coded_candidate)
            valid_bits.append(bits)
            coded_blocks += 1
            entropy_bits += bits
        else:
            encoded_blocks.append(raw_candidate)
            valid_bits.append(0)
            raw_fallbacks += 1
    model_blob = model.serialize()
    payload = b"".join(encoded_blocks)
    directory = bytearray(len(raw_blocks) * DIR_BYTES)
    offset = 0
    for index, (raw_block, encoded_block, bits) in enumerate(zip(raw_blocks, encoded_blocks, valid_bits)):
        DIR.pack_into(directory, index * DIR_BYTES, offset, len(encoded_block), len(raw_block), _crc(raw_block), bits)
        offset += len(encoded_block)
    frame = _frame_with_directory(len(raw), raw_blocks, encoded_blocks, model_blob, bytes(directory), payload, block_bytes)
    global _LAST_METRICS
    _LAST_METRICS = {
        "complete_bytes": len(frame),
        "frame_bytes": len(frame),
        "raw_bytes": len(raw),
        "header_bytes": HEADER_BYTES,
        "model_bytes": len(model_blob),
        "directory_bytes": len(directory),
        "payload_bytes": len(payload),
        "coded_blocks": coded_blocks,
        "raw_blocks": raw_fallbacks,
        "entropy_bits": entropy_bits,
        "padding_bits": sum((8 - bits % 8) % 8 for bits in valid_bits if bits),
        "rule_count": model.rule_count,
        "rule_expansion_bytes": model.preexpanded_bytes,
        "max_root_expansion_bytes": max(root_lengths, default=0),
        "avg_root_expansion_bytes": (sum(root_lengths) / len(root_lengths)) if root_lengths else 0.0,
        "root_event_count": root_event_count,
        "frequency_records_encoder_only": sum(1 for value in model.frequencies if value),
        "entropy_table_bytes": model.symbol_count if model.coder == "huff" else 0,
        "coder": model.coder,
        "scope": model.scope,
        "grammar": dict(model.grammar_metrics or {}),
    }
    return frame


def prepare(frame: bytes, *, max_frame_bytes: int = MAX_FRAME_BYTES, max_raw_bytes: int = MAX_RAW_BYTES) -> Prepared:
    started = time.perf_counter_ns()
    if not isinstance(frame, (bytes, bytearray, memoryview)):
        raise FrameError("frame must be bytes-like")
    wire = bytes(frame)
    if len(wire) < HEADER_BYTES:
        raise FrameError("truncated grammar frame header")
    if len(wire) > max_frame_bytes:
        raise FrameError("grammar frame exceeds configured limit")
    magic, version, flags, header_size, block_bytes, block_count, raw_length, model_length, directory_length, payload_length, metadata_crc, reserved = HEADER.unpack_from(wire)
    if magic != MAGIC or version != VERSION or flags != 0 or header_size != HEADER_BYTES or reserved != 0:
        raise FrameError("invalid grammar frame header")
    if block_bytes <= 0 or block_bytes > MAX_BLOCK_BYTES or block_count > MAX_BLOCKS:
        raise FrameError("invalid grammar block configuration")
    if raw_length > max_raw_bytes:
        raise FrameError("grammar raw length exceeds configured limit")
    model_at = HEADER_BYTES
    directory_at = model_at + model_length
    payload_at = directory_at + directory_length
    if directory_length != block_count * DIR_BYTES or payload_at > len(wire) or payload_length != len(wire) - payload_at:
        raise FrameError("grammar frame lengths do not cover wire")
    model_blob = wire[model_at:directory_at]
    directory = wire[directory_at:payload_at]
    header_zero = HEADER.pack(
        MAGIC,
        VERSION,
        0,
        HEADER_BYTES,
        block_bytes,
        block_count,
        raw_length,
        model_length,
        directory_length,
        payload_length,
        0,
        0,
    )
    if metadata_crc != _metadata_crc(header_zero, model_blob, directory):
        raise FrameError("grammar metadata checksum mismatch")
    model = Model.from_bytes(model_blob)
    records: list[DirectoryRecord] = []
    expected_offset = 0
    raw_sum = 0
    for index in range(block_count):
        offset, encoded_bytes, raw_bytes, crc32, valid_bits = DIR.unpack_from(directory, index * DIR_BYTES)
        if offset != expected_offset or encoded_bytes == 0 or offset + encoded_bytes > payload_length:
            raise FrameError(f"grammar directory is invalid at block {index}")
        if raw_bytes == 0 or raw_bytes > block_bytes:
            raise FrameError(f"grammar raw block length is invalid at block {index}")
        if index + 1 < block_count and raw_bytes != block_bytes:
            raise FrameError("non-final grammar block is short")
        mode_at = payload_at + offset
        if mode_at >= len(wire):
            raise FrameError("grammar block mode outside payload")
        mode = wire[mode_at]
        body_bytes = encoded_bytes - 1
        if mode == 0:
            if valid_bits != 0 or body_bytes != raw_bytes:
                raise FrameError("invalid raw grammar directory metadata")
        elif mode == 1:
            if valid_bits <= 0 or (valid_bits + 7) // 8 != body_bytes:
                raise FrameError("invalid coded grammar directory metadata")
        else:
            raise FrameError("unknown grammar block mode in directory")
        expected_offset += encoded_bytes
        raw_sum += raw_bytes
        if raw_sum > max_raw_bytes:
            raise FrameError("grammar directory raw lengths exceed bound")
        records.append(DirectoryRecord(offset, encoded_bytes, raw_bytes, crc32, valid_bits))
    expected_count = 0 if raw_length == 0 else (raw_length - 1) // block_bytes + 1
    if expected_count != block_count or raw_sum != raw_length or expected_offset != payload_length:
        raise FrameError("grammar directory totals mismatch")
    tree = _huffman_tree(model.code_lengths) if model.coder == "huff" else ()
    table = _LEAF_TABLE + model.expansions
    return Prepared(
        frame=wire,
        model=model,
        block_bytes=block_bytes,
        raw_length=raw_length,
        records=tuple(records),
        model_bytes=model_length,
        directory_bytes=directory_length,
        payload_offset=payload_at,
        setup_ns=time.perf_counter_ns() - started,
        _huffman_tree=tree,
        _symbol_table=table,
    )


def decode(frame: bytes | Prepared) -> bytes:
    prepared = frame if isinstance(frame, Prepared) else prepare(frame)
    return prepared.decode_all()


def decode_all(frame: bytes | Prepared) -> bytes:
    return decode(frame)


def decode_block(frame: bytes | Prepared, index: int) -> bytes:
    prepared = frame if isinstance(frame, Prepared) else prepare(frame)
    return prepared.decode_block(index)


def frame_metrics(frame: bytes | Prepared) -> dict[str, object]:
    prepared = frame if isinstance(frame, Prepared) else prepare(frame)
    payload_bytes = len(prepared.frame) - prepared.payload_offset
    coded = sum(1 for record in prepared.records if prepared.frame[prepared.payload_offset + record.offset] == 1)
    raw_blocks = len(prepared.records) - coded
    entropy_bits = sum(record.valid_bits for record in prepared.records)
    return {
        "complete_bytes": len(prepared.frame),
        "frame_bytes": len(prepared.frame),
        "raw_bytes": prepared.raw_length,
        "header_bytes": HEADER_BYTES,
        "model_bytes": prepared.model_bytes,
        "directory_bytes": prepared.directory_bytes,
        "payload_bytes": payload_bytes,
        "block_count": len(prepared.records),
        "block_bytes": prepared.block_bytes,
        "coded_blocks": coded,
        "raw_blocks": raw_blocks,
        "entropy_bits": entropy_bits,
        "padding_bits": sum((8 - record.valid_bits % 8) % 8 for record in prepared.records if record.valid_bits),
        "rule_count": prepared.model.rule_count,
        "rule_expansion_bytes": prepared.model.preexpanded_bytes,
        "frequency_records_encoder_only": None,
        "entropy_table_bytes": prepared.model.symbol_count if prepared.model.coder == "huff" else 0,
        "coder": prepared.model.coder,
        "scope": prepared.model.scope,
        "prepared_setup_ns": prepared.setup_ns,
        "decode_symbol_ops": prepared.decode_symbol_ops,
        "decode_copy_bytes": prepared.decode_copy_bytes,
        "grammar": dict(prepared.model.grammar_metrics or {}),
    }


def metrics(frame: bytes | Prepared | None = None) -> dict[str, object]:
    """Return frame metrics, or the last encode metrics when no frame is given."""

    if frame is None:
        return dict(_LAST_METRICS)
    return frame_metrics(frame)


__all__ = [
    "MAGIC",
    "MODEL_MAGIC",
    "HEADER",
    "DIR",
    "MODEL_HEAD",
    "FrameError",
    "ModelError",
    "Model",
    "DirectoryRecord",
    "Prepared",
    "train",
    "encode",
    "prepare",
    "decode",
    "decode_all",
    "decode_block",
    "frame_metrics",
    "metrics",
]
