"""Flat phrase-dictionary compression experiment for the bzip4 frontier.

This module is deliberately self contained.  It is a *reference experiment*,
not a production codec and not a claim that the individual ingredients are
new.  A model is learned deterministically from bytes supplied to ``train``;
the complete model is serialized in every frame.  A frame therefore remains
lossless for arbitrary bytes and has no dependency on a pre-trained language
model or on a fixture-specific token list.

The two model families in this file are:

``lex_huff``
    Generic lexical/UTF-8-unit phrase mining (word, separator and punctuation
    units) followed by longest-match phrase tokenization and a static canonical
    Huffman code over phrase IDs and literal bytes.
``ngram_huff``
    Generic byte n-gram mining over the same training bytes.  It does not know
    XML, SGML, words, or any language-specific token.  It is an intentionally
    adversarial control for the lexical segmentation hypothesis.
``lex_fixed``
    The lexical dictionary with fixed-width symbol IDs.  It is a decoder-speed
    control: one bounded table lookup and one bulk expansion per phrase, with
    no entropy-tree walk.

All phrase entries are stored as a flat, front-coded byte table.  Phrase values
never refer to other phrases, so decoding cannot recurse or grow an unbounded
expansion stack.  The public decoder validates every frame boundary, model
length, bit count, symbol range, output length, CRC, and padding bit.

The wire format is intentionally simple enough to audit.  Integers are little
endian.  ``decode_block`` is independently restartable after model parsing;
``prepare`` exposes the one-time model/table construction so callers can
measure cold setup separately from a retained reader.
"""

from __future__ import annotations

import binascii
import dataclasses
import hashlib
import heapq
import math
import struct
import time
from array import array
from collections import Counter
from typing import Iterable, Iterator, Optional, Sequence


MAGIC = b"PHR1"
MODEL_MAGIC = b"PMOD"
VERSION = 1
MODEL_VERSION = 1
HEADER = struct.Struct("<4sBBHIIQIIII")
# magic, version, variant, header size, block target, block count, raw length,
# model bytes, directory bytes, metadata CRC, reserved.
DIR = struct.Struct("<QIIII")
# payload absolute offset, encoded bytes, raw bytes, raw CRC32, valid bits.
MODEL_HEAD = struct.Struct("<4sBBBBIQ")
# magic, version, coder, variant, scope, phrase count, training bytes.

HEADER_BYTES = HEADER.size
DIR_BYTES = DIR.size
MAX_FRAME_BYTES = 512 * 1024 * 1024
MAX_RAW_BYTES = 512 * 1024 * 1024
MAX_MODEL_BYTES = 8 * 1024 * 1024
MAX_BLOCK_BYTES = 64 * 1024 * 1024
MAX_BLOCKS = 1_000_000
MAX_PHRASES = 4096
MAX_PHRASE_BYTES = 96
MAX_CODE_BITS = 32

VARIANTS = {
    "lex_huff": (1, 0),
    "ngram_huff": (2, 0),
    "lex_fixed": (3, 1),
    # This name is useful in ledgers.  It uses exactly the lex_huff codec but
    # the model's scope byte records that the encoder was fit on the input.
    "input_lex_huff": (4, 0),
    # Two-pass minimum-bit lexical parse; same flat Huffman wire coder.
    "lex_dp_huff": (5, 0),
}
VARIANT_NAMES = {v[0]: k for k, v in VARIANTS.items()}
CODER_NAMES = {0: "huff", 1: "fixed"}


class FrameError(ValueError):
    """Raised for malformed, truncated, or resource-exhausting frames."""


class ModelError(ValueError):
    """Raised for malformed or internally inconsistent models."""


@dataclasses.dataclass
class PhraseModel:
    variant: str
    phrases: tuple[bytes, ...]
    code_lengths: tuple[int, ...]
    coder: str
    scope: str = "training"
    training_bytes: int = 0
    training_sha256: str = ""
    options: dict = dataclasses.field(default_factory=dict)
    # Derived, intentionally not serialized.
    _codes: tuple[tuple[int, int], ...] = dataclasses.field(default_factory=tuple, repr=False)
    _decode_tree: tuple[tuple[int, int, int], ...] = dataclasses.field(default_factory=tuple, repr=False)
    _trie: tuple[dict[int, int], ...] = dataclasses.field(default_factory=tuple, repr=False)
    _terminal: tuple[int, ...] = dataclasses.field(default_factory=tuple, repr=False)
    _max_phrase: int = dataclasses.field(default=0, repr=False)

    @property
    def variant_id(self) -> int:
        try:
            return VARIANTS[self.variant][0]
        except KeyError as exc:
            raise ModelError(f"unknown variant {self.variant!r}") from exc

    @property
    def phrase_count(self) -> int:
        return len(self.phrases)

    @property
    def symbol_count(self) -> int:
        return self.phrase_count + 256

    @property
    def max_phrase_bytes(self) -> int:
        return self._max_phrase

    @property
    def id_width(self) -> int:
        return max(1, (self.symbol_count - 1).bit_length())

    def serialize(self) -> bytes:
        """Serialize the complete model, including every expansion byte."""
        if self.phrase_count > MAX_PHRASES:
            raise ModelError("too many phrases")
        if self.coder not in CODER_NAMES.values():
            raise ModelError("unknown coder")
        if len(self.phrases) != len(set(self.phrases)):
            raise ModelError("duplicate phrases")
        if tuple(sorted(self.phrases)) != self.phrases:
            raise ModelError("phrases must be sorted for front coding")
        coder_id = 0 if self.coder == "huff" else 1
        scope_id = 1 if self.scope == "input" else 0
        head = MODEL_HEAD.pack(
            MODEL_MAGIC,
            MODEL_VERSION,
            coder_id,
            self.variant_id,
            scope_id,
            self.phrase_count,
            self.training_bytes,
        )
        out = bytearray(head)
        previous = b""
        for phrase in self.phrases:
            if not phrase or len(phrase) > MAX_PHRASE_BYTES:
                raise ModelError("invalid phrase length")
            prefix = 0
            max_prefix = min(len(previous), len(phrase), 255)
            while prefix < max_prefix and previous[prefix] == phrase[prefix]:
                prefix += 1
            suffix = phrase[prefix:]
            if len(suffix) > 255:
                raise ModelError("phrase suffix too long")
            out.extend((prefix, len(suffix)))
            out.extend(suffix)
            previous = phrase
        if self.coder == "huff":
            if len(self.code_lengths) != self.symbol_count:
                raise ModelError("wrong Huffman length table")
            if any((x < 1 or x > MAX_CODE_BITS) for x in self.code_lengths):
                raise ModelError("invalid Huffman length")
            out.extend(bytes(self.code_lengths))
        if len(out) > MAX_MODEL_BYTES:
            raise ModelError("model exceeds limit")
        return bytes(out)


@dataclasses.dataclass(frozen=True)
class DirectoryRecord:
    offset: int
    encoded_bytes: int
    raw_bytes: int
    crc32: int
    valid_bits: int


@dataclasses.dataclass
class Prepared:
    """Validated frame with one-time model/table setup made explicit."""

    frame: bytes
    model: PhraseModel
    block_bytes: int
    raw_length: int
    records: tuple[DirectoryRecord, ...]
    model_bytes: int
    metadata_bytes: int
    payload_offset: int
    setup_ns: int = 0

    def decode_block(self, index: int) -> bytes:
        if index < 0 or index >= len(self.records):
            raise FrameError("block index out of range")
        record = self.records[index]
        start = record.offset
        end = start + record.encoded_bytes
        if start < self.payload_offset or end > len(self.frame):
            raise FrameError("block payload out of frame")
        payload = self.frame[start:end]
        if not payload:
            raise FrameError("empty block payload")
        if record.raw_bytes > self.block_bytes:
            raise FrameError("raw block exceeds target")
        mode = payload[0]
        body = payload[1:]
        if mode == 0:
            if record.valid_bits != 0 or len(body) != record.raw_bytes:
                raise FrameError("invalid raw block metadata")
            result = bytes(body)
        elif mode == 1:
            if record.raw_bytes and record.valid_bits <= 0:
                raise FrameError("empty coded block bitstream")
            expected_body_bytes = (record.valid_bits + 7) // 8
            if len(body) != expected_body_bytes:
                raise FrameError("coded payload has noncanonical padding bytes")
            if record.valid_bits > len(body) * 8:
                raise FrameError("bit count exceeds payload")
            if record.valid_bits < len(body) * 8:
                unused = len(body) * 8 - record.valid_bits
                if unused >= 8:
                    raise FrameError("coded payload has excessive padding")
                if unused and (body[-1] & ((1 << unused) - 1)):
                    raise FrameError("nonzero padding bits")
            if self.model.coder == "huff":
                result = _decode_huffman(body, record.valid_bits, self.model, record.raw_bytes)
            elif self.model.coder == "fixed":
                result = _decode_fixed(body, record.valid_bits, self.model, record.raw_bytes)
            else:
                raise FrameError("unknown model coder")
        else:
            raise FrameError("unknown block mode")
        if len(result) != record.raw_bytes:
            raise FrameError("decoded block length mismatch")
        if _crc32(result) != record.crc32:
            raise FrameError("block CRC mismatch")
        _set_metrics(
            block_decodes=_LAST_METRICS.get("block_decodes", 0) + 1,
            output_bytes=_LAST_METRICS.get("output_bytes", 0) + len(result),
        )
        return result


_LAST_METRICS: dict = {}


def clear_metrics() -> None:
    """Reset the process-local metrics dictionary before a timed operation."""
    _LAST_METRICS.clear()


def metrics() -> dict:
    """Return a copy of the most recent operation metrics."""
    return dict(_LAST_METRICS)


def _set_metrics(**values: object) -> None:
    _LAST_METRICS.update(values)


def _crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _valid_variant(variant: str) -> tuple[int, int]:
    try:
        return VARIANTS[variant]
    except KeyError as exc:
        raise ModelError(f"unsupported variant {variant!r}") from exc


def _utf8_unit(data: bytes, at: int) -> int:
    """Return a conservative UTF-8 sequence length, or one byte on failure."""
    b = data[at]
    if b < 0x80:
        return 1
    if 0xC2 <= b <= 0xDF:
        need = 2
    elif 0xE0 <= b <= 0xEF:
        need = 3
    elif 0xF0 <= b <= 0xF4:
        need = 4
    else:
        return 1
    if at + need > len(data):
        return 1
    tail = data[at + 1 : at + need]
    if any((x & 0xC0) != 0x80 for x in tail):
        return 1
    # Reject overlong and surrogate forms.  A rejected leading byte still
    # becomes a byte unit and is therefore always lossless.
    try:
        data[at : at + need].decode("utf-8")
    except UnicodeDecodeError:
        return 1
    return need


def _is_word_byte(b: int) -> bool:
    return 48 <= b <= 57 or 65 <= b <= 90 or 97 <= b <= 122 or b == 0x5F


def _is_space_byte(b: int) -> bool:
    return b in (0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20)


def _lexical_units(data: bytes) -> list[bytes]:
    """Split bytes into generic word/space/Unicode-codepoint/punctuation units.

    This is deliberately a byte-safe structural tokenizer.  It has no XML
    names, English vocabulary, language list, or special markup token.
    """
    units: list[bytes] = []
    at = 0
    n = len(data)
    while at < n:
        b = data[at]
        if _is_word_byte(b):
            end = at + 1
            while end < n and _is_word_byte(data[end]):
                end += 1
            units.append(data[at:end])
            at = end
            continue
        if _is_space_byte(b):
            end = at + 1
            # Keep very long runs split so that a single pathological run
            # cannot create a giant candidate phrase.
            while end < n and _is_space_byte(data[end]) and end - at < 16:
                end += 1
            units.append(data[at:end])
            at = end
            continue
        width = _utf8_unit(data, at) if b >= 0x80 else 1
        units.append(data[at : at + width])
        at += width
    return units


def _candidate_counts_lex(data: bytes, max_phrase: int) -> Counter[bytes]:
    units = _lexical_units(data)
    counts: Counter[bytes] = Counter()
    # Whole units include repeated words and repeated Unicode codepoints.
    for unit in units:
        if 3 <= len(unit) <= max_phrase:
            counts[unit] += 1
    # Adjacent unit spans approximate multiword and markup-fragment mining.
    for i in range(len(units)):
        joined = bytearray()
        for j in range(i, min(len(units), i + 7)):
            joined.extend(units[j])
            if len(joined) > max_phrase:
                break
            if len(joined) >= 3:
                counts[bytes(joined)] += 1
    return counts


def _candidate_counts_ngram(data: bytes, max_phrase: int) -> Counter[bytes]:
    """Count generic byte n-grams without consulting lexical categories."""
    counts: Counter[bytes] = Counter()
    n = len(data)
    # Long windows are sampled on even offsets to cap training CPU/memory.  A
    # phrase still comes from the complete first MiB, not from a holdout.
    lengths = (2, 3, 4, 5, 6, 8, 10, 12, 16, 24, min(32, max_phrase))
    for length in lengths:
        if length < 2 or length > max_phrase or length > n:
            continue
        step = 1 if length <= 6 else 2
        local: Counter[bytes] = Counter()
        for at in range(0, n - length + 1, step):
            local[data[at : at + length]] += 1
        # Keep only the useful tail before adding the next length.  This makes
        # random bytes cheap while preserving recurring language fragments.
        for phrase, count in local.items():
            if count >= 2:
                counts[phrase] = max(counts.get(phrase, 0), count)
    return counts


def _select_phrases(
    counts: Counter[bytes],
    *,
    max_phrases: int,
    max_phrase: int,
    min_count: int,
) -> tuple[bytes, ...]:
    scored: list[tuple[int, int, int, bytes]] = []
    for phrase, count in counts.items():
        if count < min_count or len(phrase) < 3 or len(phrase) > max_phrase:
            continue
        # This is only a candidate ranking.  The actual serialized model and
        # Huffman lengths are charged later.  The explicit fixed cost helps
        # reject attractive-looking one-off or two-hit strings.
        gain = count * (len(phrase) - 1) - (len(phrase) + 4) * 2
        if gain > 0:
            scored.append((gain, count, len(phrase), phrase))
    scored.sort(key=lambda x: (-x[0], -x[1], -x[2], x[3]))
    chosen: list[bytes] = []
    seen: set[bytes] = set()
    for _, _, _, phrase in scored:
        if phrase in seen:
            continue
        chosen.append(phrase)
        seen.add(phrase)
        if len(chosen) >= max_phrases:
            break
    chosen.sort()
    return tuple(chosen)


def _build_trie(phrases: Sequence[bytes]) -> tuple[tuple[dict[int, int], ...], tuple[int, ...]]:
    nodes: list[dict[int, int]] = [{}]
    terminal = [-1]
    for phrase_id, phrase in enumerate(phrases):
        node = 0
        for b in phrase:
            child = nodes[node].get(b)
            if child is None:
                child = len(nodes)
                nodes[node][b] = child
                nodes.append({})
                terminal.append(-1)
            node = child
        if terminal[node] >= 0:
            raise ModelError("duplicate phrase in trie")
        terminal[node] = phrase_id
    return tuple(nodes), tuple(terminal)


def _next_symbol(data: bytes, at: int, model: PhraseModel) -> tuple[int, int]:
    """Return (symbol, consumed bytes) using a bounded trie walk."""
    node = 0
    best = -1
    consumed = 0
    limit = min(len(data), at + model.max_phrase_bytes)
    while at + consumed < limit:
        child = model._trie[node].get(data[at + consumed])
        if child is None:
            break
        node = child
        consumed += 1
        token = model._terminal[node]
        if token >= 0:
            best = token
            best_len = consumed
    if best >= 0:
        return best, best_len
    return model.phrase_count + data[at], 1


def _token_frequencies(data: bytes, model: PhraseModel) -> tuple[list[int], int, int]:
    freq = [1] * model.symbol_count
    at = 0
    phrase_symbols = 0
    literal_symbols = 0
    while at < len(data):
        symbol, consumed = _next_symbol(data, at, model)
        freq[symbol] += 1
        if symbol < model.phrase_count:
            phrase_symbols += 1
        else:
            literal_symbols += 1
        at += consumed
    return freq, phrase_symbols, literal_symbols


def _huffman_model_from_counts(
    *,
    variant: str,
    phrases: tuple[bytes, ...],
    training: bytes,
    scope: str,
    options: dict,
    freq: Sequence[int],
) -> PhraseModel:
    """Build a Huffman model from an explicit parse recount.

    The ordinary lexical path uses greedy counts.  The DP path calls this
    helper after each minimum-bit parse so code lengths are refit to the parse
    that actually selected the phrases.
    """
    expected = len(phrases) + 256
    if len(freq) != expected:
        raise ModelError("wrong explicit frequency table length")
    lengths = _huffman_lengths(freq)
    codes = _canonical_codes(lengths)
    tree = _decode_tree(codes)
    trie, terminal = _build_trie(phrases)
    return PhraseModel(
        variant=variant,
        phrases=phrases,
        code_lengths=lengths,
        coder="huff",
        scope=scope,
        training_bytes=len(training),
        training_sha256=_sha256(training),
        options=dict(options),
        _codes=codes,
        _decode_tree=tree,
        _trie=trie,
        _terminal=terminal,
        _max_phrase=max((len(p) for p in phrases), default=0),
    )


def _huffman_model_from_phrases(
    *,
    variant: str,
    phrases: tuple[bytes, ...],
    training: bytes,
    scope: str,
    options: dict,
) -> PhraseModel:
    """Construct provisional code lengths from a greedy parse."""
    provisional = PhraseModel(
        variant=variant,
        phrases=phrases,
        code_lengths=(),
        coder="huff",
        scope=scope,
        training_bytes=len(training),
        training_sha256=_sha256(training),
        options=dict(options),
        _max_phrase=max((len(p) for p in phrases), default=0),
    )
    provisional._trie, provisional._terminal = _build_trie(phrases)
    freq, _, _ = _token_frequencies(training, provisional)
    return _huffman_model_from_counts(
        variant=variant,
        phrases=phrases,
        training=training,
        scope=scope,
        options=options,
        freq=freq,
    )


def _dp_parse(data: bytes, model: PhraseModel) -> tuple[array, list[int], int, int, int]:
    """Minimum-bit parse over a flat phrase trie.

    ``choices[at]`` is a phrase ID or ``-1`` for one literal byte.  The
    dynamic program stores only the best cost at each byte boundary; phrase
    expansions are still flat and the decoder never sees this state.
    """
    n = len(data)
    costs = [0] * (n + 1)
    choices = array("i", [-1]) * n
    max_phrase = model.max_phrase_bytes
    if model.coder != "huff":
        raise ModelError("DP parser requires Huffman model")
    for at in range(n - 1, -1, -1):
        literal_symbol = model.phrase_count + data[at]
        best_cost = model._codes[literal_symbol][1] + costs[at + 1]
        best_id = -1
        node = 0
        consumed = 0
        limit = min(n, at + max_phrase)
        while at + consumed < limit:
            child = model._trie[node].get(data[at + consumed])
            if child is None:
                break
            node = child
            consumed += 1
            phrase_id = model._terminal[node]
            if phrase_id >= 0:
                candidate = model._codes[phrase_id][1] + costs[at + consumed]
                if candidate < best_cost or (
                    candidate == best_cost
                    and (best_id < 0 or len(model.phrases[phrase_id]) > 1)
                ):
                    best_cost = candidate
                    best_id = phrase_id
        costs[at] = best_cost
        choices[at] = best_id

    freq = [1] * model.symbol_count
    phrase_symbols = 0
    literal_symbols = 0
    at = 0
    while at < n:
        phrase_id = choices[at]
        if phrase_id >= 0:
            consumed = len(model.phrases[phrase_id])
            if consumed <= 0 or at + consumed > n:
                raise ModelError("DP choice outside input")
            freq[phrase_id] += 1
            phrase_symbols += 1
        else:
            consumed = 1
            freq[model.phrase_count + data[at]] += 1
            literal_symbols += 1
        at += consumed
    return choices, freq, phrase_symbols, literal_symbols, costs[0] if n else 0


def _residual_lex_counts(
    data: bytes,
    choices: Sequence[int],
    model: PhraseModel,
    max_phrase: int,
) -> Counter[bytes]:
    """Mine only contiguous runs left literal by a DP parse."""
    counts: Counter[bytes] = Counter()
    run = bytearray()
    at = 0
    while at < len(data):
        phrase_id = choices[at]
        if phrase_id >= 0:
            if run:
                counts.update(_candidate_counts_lex(bytes(run), max_phrase))
                run.clear()
            at += len(model.phrases[phrase_id])
        else:
            run.append(data[at])
            at += 1
    if run:
        counts.update(_candidate_counts_lex(bytes(run), max_phrase))
    return counts


def _remap_recount(
    old_phrases: tuple[bytes, ...],
    old_freq: Sequence[int],
    new_phrases: tuple[bytes, ...],
) -> list[int]:
    """Carry explicit token counts across a sorted phrase-table update."""
    old_index = {phrase: index for index, phrase in enumerate(old_phrases)}
    old_count = len(old_phrases)
    new_count = len(new_phrases)
    result = [1] * (new_count + 256)
    for new_id, phrase in enumerate(new_phrases):
        old_id = old_index.get(phrase)
        if old_id is not None:
            result[new_id] += int(old_freq[old_id]) - 1
    for byte in range(256):
        result[new_count + byte] += int(old_freq[old_count + byte]) - 1
    return result


def _finalize_dp_model(
    *,
    training: bytes,
    initial_phrases: tuple[bytes, ...],
    max_phrases: int,
    max_phrase: int,
    min_count: int,
    scope: str,
    options: dict,
) -> PhraseModel:
    """Run two parse → refit → prune/replenish rounds."""
    phrase_set = tuple(sorted(initial_phrases))
    model = _huffman_model_from_phrases(
        variant="lex_dp_huff",
        phrases=phrase_set,
        training=training,
        scope=scope,
        options=options,
    )
    final_freq: list[int] = [1] * (len(phrase_set) + 256)
    final_phrase_symbols = 0
    final_literal_symbols = 0
    final_cost = 0
    for round_index in range(2):
        choices, freq, phrase_symbols, literal_symbols, bit_cost = _dp_parse(training, model)
        used_ids = sorted({choices[at] for at in range(len(choices)) if choices[at] >= 0})
        used_phrases = tuple(model.phrases[index] for index in used_ids)
        if round_index == 0:
            residual = _residual_lex_counts(training, choices, model, max_phrase)
            room = max(0, max_phrases - len(used_phrases))
            additions = _select_phrases(
                residual,
                max_phrases=room,
                max_phrase=max_phrase,
                min_count=max(2, min_count - 1),
            )
            phrase_set = tuple(sorted(set(used_phrases).union(additions)))
            # Refit code lengths to the first DP parse, carrying all literal
            # and phrase counts into the expanded table.
            refit_freq = _remap_recount(model.phrases, freq, phrase_set)
            model = _huffman_model_from_counts(
                variant="lex_dp_huff",
                phrases=phrase_set,
                training=training,
                scope=scope,
                options=options,
                freq=refit_freq,
            )
        else:
            # Final prune: every retained rule was selected by the second
            # minimum-bit parse.  The explicit recount becomes the stored
            # entropy model, with phrase IDs remapped to the pruned table.
            phrase_set = tuple(sorted(used_phrases))
            final_freq = _remap_recount(model.phrases, freq, phrase_set)
            final_phrase_symbols = phrase_symbols
            final_literal_symbols = literal_symbols
            final_cost = bit_cost
            model = _huffman_model_from_counts(
                variant="lex_dp_huff",
                phrases=phrase_set,
                training=training,
                scope=scope,
                options=options,
                freq=final_freq,
            )
    model.options = dict(model.options)
    model.options.update(
        {
            "dp_rounds": 2,
            "dp_final_bits": final_cost,
            "dp_final_phrase_symbols": final_phrase_symbols,
            "dp_final_literal_symbols": final_literal_symbols,
            "dp_initial_phrase_count": len(initial_phrases),
            "dp_final_phrase_count": len(model.phrases),
        }
    )
    _set_metrics(
        train_bytes=len(training),
        train_sha256=model.training_sha256,
        variant=model.variant,
        scope=scope,
        coder=model.coder,
        phrase_count=model.phrase_count,
        phrase_bytes=sum(len(x) for x in model.phrases),
        phrase_symbols=final_phrase_symbols,
        literal_symbols=final_literal_symbols,
        entropy_bits=final_cost,
        model_bytes=len(model.serialize()),
        id_width=model.id_width,
        dp_rounds=2,
        dp_initial_phrase_count=len(initial_phrases),
        dp_final_phrase_count=len(model.phrases),
    )
    return model


def _huffman_lengths(freq: Sequence[int]) -> tuple[int, ...]:
    if not freq:
        return ()
    if len(freq) == 1:
        return (1,)
    # Explicit nodes keep tie-breaking deterministic and make the generated
    # lengths easy to audit.  (A production implementation would avoid the
    # second Python object graph; this is a reference experiment.)
    @dataclasses.dataclass
    class Node:
        weight: int
        minimum: int
        serial: int
        left: Optional["Node"] = None
        right: Optional["Node"] = None
        symbol: int = -1

    serial = 0
    nodes: list[tuple[int, int, int, Node]] = []
    for symbol, weight in enumerate(freq):
        node = Node(max(1, int(weight)), symbol, serial, symbol=symbol)
        nodes.append((node.weight, node.minimum, node.serial, node))
        serial += 1
    heapq.heapify(nodes)
    while len(nodes) > 1:
        a = heapq.heappop(nodes)[3]
        b = heapq.heappop(nodes)[3]
        node = Node(a.weight + b.weight, min(a.minimum, b.minimum), serial, left=a, right=b)
        serial += 1
        heapq.heappush(nodes, (node.weight, node.minimum, node.serial, node))
    root = nodes[0][3]
    lengths = [0] * len(freq)
    stack: list[tuple[Node, int]] = [(root, 0)]
    while stack:
        node, depth = stack.pop()
        if node.symbol >= 0:
            lengths[node.symbol] = max(1, depth)
        else:
            assert node.left is not None and node.right is not None
            stack.append((node.right, depth + 1))
            stack.append((node.left, depth + 1))
    if max(lengths, default=0) > MAX_CODE_BITS:
        raise ModelError("Huffman depth exceeds wire limit")
    return tuple(lengths)


def _canonical_codes(lengths: Sequence[int]) -> tuple[tuple[int, int], ...]:
    if not lengths:
        return ()
    pairs = sorted((length, symbol) for symbol, length in enumerate(lengths) if length)
    codes = [(0, 0)] * len(lengths)
    code = 0
    previous = 0
    for length, symbol in pairs:
        code <<= length - previous
        if code >= (1 << length):
            raise ModelError("oversubscribed Huffman lengths")
        codes[symbol] = (code, length)
        code += 1
        previous = length
    return tuple(codes)


def _decode_tree(codes: Sequence[tuple[int, int]]) -> tuple[tuple[int, int, int], ...]:
    # node = (zero child, one child, symbol), child -1 means absent.
    nodes: list[list[int]] = [[-1, -1, -1]]
    for symbol, (code, length) in enumerate(codes):
        if length <= 0:
            continue
        node = 0
        for bit_index in range(length - 1, -1, -1):
            if nodes[node][2] >= 0:
                raise ModelError("Huffman leaf has child")
            bit = (code >> bit_index) & 1
            child = nodes[node][bit]
            if child < 0:
                child = len(nodes)
                nodes[node][bit] = child
                nodes.append([-1, -1, -1])
            node = child
        if nodes[node][2] >= 0 or nodes[node][0] >= 0 or nodes[node][1] >= 0:
            raise ModelError("duplicate or prefix Huffman code")
        nodes[node][2] = symbol
    return tuple((x[0], x[1], x[2]) for x in nodes)


def _finalize_model(
    *,
    variant: str,
    phrases: tuple[bytes, ...],
    training: bytes,
    scope: str,
    options: dict,
) -> PhraseModel:
    _, coder_id = _valid_variant(variant)
    coder = "fixed" if coder_id else "huff"
    # A temporary model is enough to tokenize training and derive frequencies.
    temporary = PhraseModel(
        variant=variant,
        phrases=phrases,
        code_lengths=(),
        coder=coder,
        scope=scope,
        training_bytes=len(training),
        training_sha256=_sha256(training),
        options=dict(options),
    )
    trie, terminal = _build_trie(phrases)
    temporary._trie = trie
    temporary._terminal = terminal
    temporary._max_phrase = max((len(p) for p in phrases), default=0)
    # Greedy longest-match tokenization can leave shorter candidates shadowed.
    # Drop such rules before deriving code lengths so their bytes are never
    # charged without an opportunity to decode them.
    used = [False] * len(phrases)
    at = 0
    while at < len(training):
        symbol, consumed = _next_symbol(training, at, temporary)
        if symbol < len(phrases):
            used[symbol] = True
        at += consumed
    if any(not keep for keep in used):
        phrases = tuple(phrase for phrase, keep in zip(phrases, used) if keep)
        temporary = PhraseModel(
            variant=variant,
            phrases=phrases,
            code_lengths=(),
            coder=coder,
            scope=scope,
            training_bytes=len(training),
            training_sha256=_sha256(training),
            options=dict(options),
        )
        temporary._trie, temporary._terminal = _build_trie(phrases)
        temporary._max_phrase = max((len(p) for p in phrases), default=0)
        trie, terminal = temporary._trie, temporary._terminal
    freq, phrase_symbols, literal_symbols = _token_frequencies(training, temporary)
    if coder == "huff":
        lengths = _huffman_lengths(freq)
        codes = _canonical_codes(lengths)
        tree = _decode_tree(codes)
    else:
        lengths = tuple([temporary.id_width] * temporary.symbol_count)
        codes = tuple((x, temporary.id_width) for x in range(temporary.symbol_count))
        tree = ()
    model = PhraseModel(
        variant=variant,
        phrases=phrases,
        code_lengths=lengths,
        coder=coder,
        scope=scope,
        training_bytes=len(training),
        training_sha256=_sha256(training),
        options=dict(options),
        _codes=codes,
        _decode_tree=tree,
        _trie=trie,
        _terminal=terminal,
        _max_phrase=max((len(p) for p in phrases), default=0),
    )
    model_bytes = len(model.serialize())
    _set_metrics(
        train_bytes=len(training),
        train_sha256=model.training_sha256,
        variant=variant,
        scope=scope,
        coder=coder,
        phrase_count=len(phrases),
        phrase_bytes=sum(len(x) for x in phrases),
        phrase_symbols=phrase_symbols,
        literal_symbols=literal_symbols,
        model_bytes=model_bytes,
        id_width=model.id_width,
    )
    return model


def train(training: bytes, **opts: object) -> PhraseModel:
    """Learn a deterministic flat phrase model from ``training`` bytes.

    Options:
      ``variant``: ``lex_huff`` (default), ``lex_dp_huff``, ``ngram_huff``,
      ``lex_fixed``, or ``input_lex_huff``.  The latter is a ledger label for a
      model fit on all bytes supplied by the caller and must not be described
      as first-MiB unseen generalization.
      ``max_phrases`` (default 1024), ``max_phrase_bytes`` (default 48), and
      ``min_count`` (default 3).
    """
    if not isinstance(training, (bytes, bytearray, memoryview)):
        raise TypeError("training must be bytes-like")
    raw = bytes(training)
    variant = str(opts.get("variant", "lex_huff"))
    _valid_variant(variant)
    max_phrases = int(opts.get("max_phrases", 1024))
    max_phrase = int(opts.get("max_phrase_bytes", 48))
    min_count = int(opts.get("min_count", 3))
    if max_phrases < 0 or max_phrases > MAX_PHRASES:
        raise ModelError("max_phrases outside limit")
    if max_phrase < 3 or max_phrase > MAX_PHRASE_BYTES:
        raise ModelError("max_phrase_bytes outside limit")
    if min_count < 2:
        raise ModelError("min_count must be at least two")
    if variant in ("lex_huff", "lex_fixed", "input_lex_huff", "lex_dp_huff"):
        counts = _candidate_counts_lex(raw, max_phrase)
    else:
        counts = _candidate_counts_ngram(raw, max_phrase)
    phrases = _select_phrases(
        counts,
        max_phrases=max_phrases,
        max_phrase=max_phrase,
        min_count=min_count,
    )
    scope = "input" if variant == "input_lex_huff" else str(opts.get("scope", "training"))
    options = {
        "max_phrases": max_phrases,
        "max_phrase_bytes": max_phrase,
        "min_count": min_count,
        "candidate_count": len(counts),
    }
    if variant == "lex_dp_huff":
        return _finalize_dp_model(
            training=raw,
            initial_phrases=phrases,
            max_phrases=max_phrases,
            max_phrase=max_phrase,
            min_count=min_count,
            scope=scope,
            options=options,
        )
    return _finalize_model(
        variant=variant,
        phrases=phrases,
        training=raw,
        scope=scope,
        options=options,
    )


class _BitWriter:
    __slots__ = ("out", "acc", "bits", "total")

    def __init__(self) -> None:
        self.out = bytearray()
        self.acc = 0
        self.bits = 0
        self.total = 0

    def put(self, code: int, length: int) -> None:
        if length <= 0:
            raise FrameError("zero-width code")
        self.acc = (self.acc << length) | code
        self.bits += length
        self.total += length
        while self.bits >= 8:
            self.bits -= 8
            self.out.append((self.acc >> self.bits) & 0xFF)
            if self.bits:
                self.acc &= (1 << self.bits) - 1
            else:
                self.acc = 0

    def finish(self) -> tuple[bytes, int]:
        if self.bits:
            self.out.append((self.acc << (8 - self.bits)) & 0xFF)
        return bytes(self.out), self.total


def _encode_symbols(data: bytes, model: PhraseModel) -> tuple[bytes, int, int, int, int]:
    writer = _BitWriter()
    at = 0
    phrase_symbols = 0
    literal_symbols = 0
    lookup_steps = 0
    while at < len(data):
        symbol, consumed = _next_symbol(data, at, model)
        lookup_steps += consumed
        if symbol < model.phrase_count:
            phrase_symbols += 1
        else:
            literal_symbols += 1
        code, length = model._codes[symbol]
        writer.put(code, length)
        at += consumed
    encoded, bits = writer.finish()
    return encoded, bits, phrase_symbols, literal_symbols, lookup_steps


def _encode_dp_symbols(data: bytes, model: PhraseModel) -> tuple[bytes, int, int, int, int]:
    """Encode a block with the same minimum-bit parser used by the DP trainer."""
    choices, _, phrase_symbols, literal_symbols, _ = _dp_parse(data, model)
    writer = _BitWriter()
    at = 0
    lookup_steps = 0
    while at < len(data):
        phrase_id = choices[at]
        if phrase_id >= 0:
            consumed = len(model.phrases[phrase_id])
            symbol = phrase_id
        else:
            consumed = 1
            symbol = model.phrase_count + data[at]
        code, length = model._codes[symbol]
        writer.put(code, length)
        lookup_steps += consumed
        at += consumed
    encoded, bits = writer.finish()
    return encoded, bits, phrase_symbols, literal_symbols, lookup_steps


def _decode_huffman(payload: bytes, valid_bits: int, model: PhraseModel, expected: int) -> bytes:
    tree = model._decode_tree
    if not tree:
        raise FrameError("missing Huffman tree")
    out = bytearray()
    node = 0
    phrase_expansions = 0
    lookup_steps = 0
    for at in range(valid_bits):
        bit = (payload[at >> 3] >> (7 - (at & 7))) & 1
        child = tree[node][bit]
        lookup_steps += 1
        if child < 0:
            raise FrameError("invalid Huffman code")
        node = child
        symbol = tree[node][2]
        if symbol >= 0:
            if symbol < model.phrase_count:
                phrase_expansions += 1
                out.extend(model.phrases[symbol])
            else:
                out.append(symbol - model.phrase_count)
            if len(out) > expected:
                raise FrameError("decoded block exceeds declared length")
            node = 0
    if node != 0:
        raise FrameError("truncated Huffman symbol")
    _set_metrics(
        phrase_expansions=_LAST_METRICS.get("phrase_expansions", 0) + phrase_expansions,
        lookup_steps=_LAST_METRICS.get("lookup_steps", 0) + lookup_steps,
    )
    return bytes(out)


def _decode_fixed(payload: bytes, valid_bits: int, model: PhraseModel, expected: int) -> bytes:
    width = model.id_width
    if valid_bits % width:
        raise FrameError("fixed stream has partial symbol")
    out = bytearray()
    symbols = valid_bits // width
    phrase_expansions = 0
    lookup_steps = 0
    for symbol_index in range(symbols):
        value = 0
        for bit_index in range(width):
            at = symbol_index * width + bit_index
            value = (value << 1) | ((payload[at >> 3] >> (7 - (at & 7))) & 1)
        lookup_steps += 1
        if value >= model.symbol_count:
            raise FrameError("fixed symbol outside alphabet")
        if value < model.phrase_count:
            phrase_expansions += 1
            out.extend(model.phrases[value])
        else:
            out.append(value - model.phrase_count)
        if len(out) > expected:
            raise FrameError("decoded block exceeds declared length")
    _set_metrics(
        phrase_expansions=_LAST_METRICS.get("phrase_expansions", 0) + phrase_expansions,
        lookup_steps=_LAST_METRICS.get("lookup_steps", 0) + lookup_steps,
    )
    return bytes(out)


def _metadata_header(
    *,
    variant_id: int,
    block_bytes: int,
    block_count: int,
    raw_length: int,
    model_length: int,
    directory_length: int,
    metadata_crc: int,
) -> bytes:
    return HEADER.pack(
        MAGIC,
        VERSION,
        variant_id,
        HEADER_BYTES,
        block_bytes,
        block_count,
        raw_length,
        model_length,
        directory_length,
        metadata_crc,
        0,
    )


def encode(data: bytes, model: PhraseModel, block_bytes: int = 16384) -> bytes:
    """Encode ``data`` into independently decodable phrase blocks."""
    if not isinstance(data, (bytes, bytearray, memoryview)):
        raise TypeError("data must be bytes-like")
    raw = bytes(data)
    if len(raw) > MAX_RAW_BYTES:
        raise ValueError("input exceeds limit")
    if not isinstance(model, PhraseModel):
        raise TypeError("model must be PhraseModel")
    if block_bytes <= 0 or block_bytes > MAX_BLOCK_BYTES:
        raise ValueError("invalid block_bytes")
    # Re-serialize and parse the model first.  This catches a caller that
    # mutated derived fields and makes the exact bytes charged in the frame
    # explicit.
    model_bytes = model.serialize()
    block_count = (len(raw) + block_bytes - 1) // block_bytes
    if block_count > MAX_BLOCKS:
        raise ValueError("too many blocks")
    payloads: list[bytes] = []
    records_no_offsets: list[tuple[int, int, int, int]] = []
    total_bits = 0
    coded_blocks = 0
    raw_blocks = 0
    phrase_symbols = 0
    literal_symbols = 0
    lookup_steps = 0
    started = time.perf_counter_ns()
    for index in range(block_count):
        start = index * block_bytes
        block = raw[start : start + block_bytes]
        if model.coder == "huff":
            if model.variant == "lex_dp_huff":
                body, bits, pcount, lcount, steps = _encode_dp_symbols(block, model)
            else:
                body, bits, pcount, lcount, steps = _encode_symbols(block, model)
        elif model.coder == "fixed":
            body_writer = _BitWriter()
            at = 0
            bits = 0
            pcount = lcount = steps = 0
            while at < len(block):
                symbol, consumed = _next_symbol(block, at, model)
                body_writer.put(symbol, model.id_width)
                bits += model.id_width
                steps += consumed
                if symbol < model.phrase_count:
                    pcount += 1
                else:
                    lcount += 1
                at += consumed
            body, bits = body_writer.finish()
        else:
            raise ValueError("unknown model coder")
        coded = b"\x01" + body
        if len(coded) < 1 + len(block):
            payload = coded
            coded_blocks += 1
            total_bits += bits
        else:
            payload = b"\x00" + block
            bits = 0
            raw_blocks += 1
        payloads.append(payload)
        records_no_offsets.append((len(payload), len(block), _crc32(block), bits))
        phrase_symbols += pcount
        literal_symbols += lcount
        lookup_steps += steps
    directory_length = block_count * DIR_BYTES
    payload_offset = HEADER_BYTES + len(model_bytes) + directory_length
    records: list[DirectoryRecord] = []
    at = payload_offset
    directory = bytearray()
    for payload, (encoded_len, raw_len, crc, bits) in zip(payloads, records_no_offsets):
        record = DirectoryRecord(at, encoded_len, raw_len, crc, bits)
        records.append(record)
        directory.extend(DIR.pack(record.offset, record.encoded_bytes, record.raw_bytes, record.crc32, record.valid_bits))
        at += len(payload)
    header_zero = _metadata_header(
        variant_id=model.variant_id,
        block_bytes=block_bytes,
        block_count=block_count,
        raw_length=len(raw),
        model_length=len(model_bytes),
        directory_length=directory_length,
        metadata_crc=0,
    )
    metadata_crc = _crc32(header_zero + model_bytes + bytes(directory))
    header = _metadata_header(
        variant_id=model.variant_id,
        block_bytes=block_bytes,
        block_count=block_count,
        raw_length=len(raw),
        model_length=len(model_bytes),
        directory_length=directory_length,
        metadata_crc=metadata_crc,
    )
    frame = header + model_bytes + bytes(directory) + b"".join(payloads)
    if len(frame) > MAX_FRAME_BYTES:
        raise ValueError("frame exceeds limit")
    elapsed = time.perf_counter_ns() - started
    _set_metrics(
        operation="encode",
        encode_ns=elapsed,
        raw_bytes=len(raw),
        frame_bytes=len(frame),
        header_bytes=HEADER_BYTES,
        model_bytes=len(model_bytes),
        directory_bytes=directory_length,
        payload_bytes=sum(len(x) for x in payloads),
        block_count=block_count,
        block_bytes=block_bytes,
        coded_blocks=coded_blocks,
        raw_blocks=raw_blocks,
        phrase_symbols=phrase_symbols,
        literal_symbols=literal_symbols,
        lookup_steps=lookup_steps,
        entropy_bits=total_bits,
        padding_bits=sum((8 - (x % 8)) % 8 for x in [r[3] for r in records_no_offsets] if x),
        metadata_crc=metadata_crc,
        model_scope=model.scope,
        variant=model.variant,
        coder=model.coder,
    )
    return frame


def _deserialize_model(blob: bytes, expected_variant: int) -> PhraseModel:
    if len(blob) < MODEL_HEAD.size:
        raise FrameError("truncated model header")
    magic, version, coder_id, variant_id, scope_id, count, train_len = MODEL_HEAD.unpack_from(blob, 0)
    if magic != MODEL_MAGIC or version != MODEL_VERSION:
        raise FrameError("invalid model header")
    if variant_id != expected_variant or variant_id not in VARIANT_NAMES:
        raise FrameError("model/frame variant mismatch")
    if coder_id not in CODER_NAMES:
        raise FrameError("invalid model coder")
    if scope_id not in (0, 1):
        raise FrameError("invalid model scope")
    if count > MAX_PHRASES:
        raise FrameError("too many model phrases")
    phrases: list[bytes] = []
    at = MODEL_HEAD.size
    previous = b""
    for _ in range(count):
        if at + 2 > len(blob):
            raise FrameError("truncated front-coded phrase")
        prefix = blob[at]
        suffix_len = blob[at + 1]
        at += 2
        if prefix > len(previous) or at + suffix_len > len(blob):
            raise FrameError("invalid front-coded phrase")
        phrase = previous[:prefix] + blob[at : at + suffix_len]
        at += suffix_len
        if not phrase or len(phrase) > MAX_PHRASE_BYTES:
            raise FrameError("invalid phrase length")
        if phrases and phrase <= phrases[-1]:
            raise FrameError("phrases not strictly sorted")
        phrases.append(bytes(phrase))
        previous = phrase
    symbol_count = count + 256
    coder = CODER_NAMES[coder_id]
    if coder == "huff":
        if at + symbol_count != len(blob):
            raise FrameError("invalid Huffman model tail")
        lengths = tuple(blob[at : at + symbol_count])
        if any(x < 1 or x > MAX_CODE_BITS for x in lengths):
            raise FrameError("invalid Huffman model lengths")
        try:
            codes = _canonical_codes(lengths)
            tree = _decode_tree(codes)
        except ModelError as exc:
            raise FrameError(str(exc)) from exc
    else:
        if at != len(blob):
            raise FrameError("invalid fixed model tail")
        dummy = PhraseModel(
            variant=VARIANT_NAMES[variant_id],
            phrases=tuple(phrases),
            code_lengths=(),
            coder="fixed",
            scope="input" if scope_id else "training",
            training_bytes=train_len,
        )
        lengths = tuple([dummy.id_width] * symbol_count)
        codes = tuple((x, dummy.id_width) for x in range(symbol_count))
        tree = ()
    variant = VARIANT_NAMES[variant_id]
    model = PhraseModel(
        variant=variant,
        phrases=tuple(phrases),
        code_lengths=lengths,
        coder=coder,
        scope="input" if scope_id else "training",
        training_bytes=train_len,
        _codes=codes,
        _decode_tree=tree,
        _max_phrase=max((len(p) for p in phrases), default=0),
    )
    trie, terminal = _build_trie(model.phrases)
    model._trie = trie
    model._terminal = terminal
    # Serialization has no hidden bytes, so this also catches a future parser
    # accidentally accepting an alternate representation.
    try:
        if model.serialize() != blob:
            raise FrameError("noncanonical model encoding")
    except ModelError as exc:
        raise FrameError(str(exc)) from exc
    return model


def _parse_frame(frame: bytes) -> Prepared:
    started = time.perf_counter_ns()
    if not isinstance(frame, (bytes, bytearray, memoryview)):
        raise TypeError("frame must be bytes-like")
    frame = bytes(frame)
    if len(frame) > MAX_FRAME_BYTES or len(frame) < HEADER_BYTES:
        raise FrameError("frame size outside limits")
    (
        magic,
        version,
        variant_id,
        header_size,
        block_bytes,
        block_count,
        raw_length,
        model_length,
        directory_length,
        metadata_crc,
        reserved,
    ) = HEADER.unpack_from(frame, 0)
    if magic != MAGIC or version != VERSION:
        raise FrameError("invalid frame magic/version")
    if header_size != HEADER_BYTES or reserved != 0:
        raise FrameError("invalid frame header")
    if variant_id not in VARIANT_NAMES:
        raise FrameError("unknown frame variant")
    if block_bytes <= 0 or block_bytes > MAX_BLOCK_BYTES:
        raise FrameError("invalid block target")
    if block_count > MAX_BLOCKS or raw_length > MAX_RAW_BYTES:
        raise FrameError("frame resource limit")
    expected_blocks = (raw_length + block_bytes - 1) // block_bytes
    if block_count != expected_blocks:
        raise FrameError("block count does not match raw length")
    if directory_length != block_count * DIR_BYTES:
        raise FrameError("invalid directory length")
    metadata_end = HEADER_BYTES + model_length + directory_length
    if model_length > MAX_MODEL_BYTES or metadata_end > len(frame):
        raise FrameError("truncated model or directory")
    model_blob = frame[HEADER_BYTES : HEADER_BYTES + model_length]
    directory_blob = frame[HEADER_BYTES + model_length : metadata_end]
    header_zero = _metadata_header(
        variant_id=variant_id,
        block_bytes=block_bytes,
        block_count=block_count,
        raw_length=raw_length,
        model_length=model_length,
        directory_length=directory_length,
        metadata_crc=0,
    )
    if _crc32(header_zero + model_blob + directory_blob) != metadata_crc:
        raise FrameError("metadata CRC mismatch")
    model = _deserialize_model(model_blob, variant_id)
    records: list[DirectoryRecord] = []
    at = 0
    previous_end = metadata_end
    for _ in range(block_count):
        offset, encoded, raw_bytes, crc, valid_bits = DIR.unpack_from(directory_blob, at)
        at += DIR_BYTES
        if raw_bytes > block_bytes:
            raise FrameError("directory raw length exceeds block target")
        if encoded < 1 or offset != previous_end:
            raise FrameError("non-contiguous directory")
        end = offset + encoded
        if end < offset or end > len(frame):
            raise FrameError("directory payload outside frame")
        if valid_bits > (encoded - 1) * 8:
            raise FrameError("directory bit count outside payload")
        records.append(DirectoryRecord(offset, encoded, raw_bytes, crc, valid_bits))
        previous_end = end
    if previous_end != len(frame):
        raise FrameError("trailing or missing payload bytes")
    setup_ns = time.perf_counter_ns() - started
    prepared = Prepared(
        frame=frame,
        model=model,
        block_bytes=block_bytes,
        raw_length=raw_length,
        records=tuple(records),
        model_bytes=model_length,
        metadata_bytes=HEADER_BYTES + model_length + directory_length,
        payload_offset=metadata_end,
        setup_ns=setup_ns,
    )
    _set_metrics(
        operation="prepare",
        setup_ns=setup_ns,
        frame_bytes=len(frame),
        raw_bytes=raw_length,
        block_count=block_count,
        block_bytes=block_bytes,
        header_bytes=HEADER_BYTES,
        model_bytes=model_length,
        directory_bytes=directory_length,
        payload_bytes=len(frame) - metadata_end,
        phrase_count=model.phrase_count,
        model_scope=model.scope,
        variant=model.variant,
        coder=model.coder,
    )
    return prepared


def prepare(frame: bytes) -> Prepared:
    """Validate and prepare a frame once for retained/random block reads."""
    return _parse_frame(frame)


def decode_block(frame: bytes, index: int) -> bytes:
    """Validate a frame and decode one independently restartable block."""
    prepared = _parse_frame(frame)
    started = time.perf_counter_ns()
    result = prepared.decode_block(index)
    _set_metrics(
        operation="decode_block",
        setup_ns=prepared.setup_ns,
        decode_ns=time.perf_counter_ns() - started,
        block_index=index,
    )
    return result


def decode(frame: bytes) -> bytes:
    """Decode and CRC-check all blocks in a frame."""
    prepared = _parse_frame(frame)
    started = time.perf_counter_ns()
    out = bytearray()
    for index in range(len(prepared.records)):
        out.extend(prepared.decode_block(index))
    if len(out) != prepared.raw_length:
        raise FrameError("frame output length mismatch")
    _set_metrics(
        operation="decode",
        setup_ns=prepared.setup_ns,
        decode_ns=time.perf_counter_ns() - started,
        output_bytes=len(out),
        frame_bytes=len(frame),
        raw_bytes=prepared.raw_length,
        block_count=len(prepared.records),
        block_bytes=prepared.block_bytes,
        model_bytes=prepared.model_bytes,
        metadata_bytes=prepared.metadata_bytes,
    )
    return bytes(out)


__all__ = [
    "FrameError",
    "ModelError",
    "PhraseModel",
    "Prepared",
    "clear_metrics",
    "decode",
    "decode_block",
    "encode",
    "metrics",
    "prepare",
    "train",
]
