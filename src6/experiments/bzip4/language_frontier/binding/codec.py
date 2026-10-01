"""Charged one-hole lexical-context reference codec.

This is a bounded storage experiment, not production bz4 code.  A training
pass discovers complete newline-delimited byte records whose equal byte
islands surround one to six deterministic byte-word slots.  A model entry is
therefore a ranked program ``literal + binding[var] + ...``; variable IDs may
repeat, so one exact word/phrase can fill several slots.  Evaluation records
are represented by either a raw event or ``(template id, bindings)``.
Binding bytes are always carried by the frame, either inline or through a
charged model dictionary; nothing about the tokenizer or a language dictionary
is external to the frame.

The frame uses zlib only as a labelled diagnostic entropy backend.  This keeps
the transform and all accounting easy to inspect while allowing a direct
comparison with the already-built v4 executable.  The model deliberately has
no recursion and every decoded length/reference is bounded.
"""

from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass
import binascii
import difflib
import struct
from typing import Iterable, Sequence
import zlib


MAGIC = b"BNG1"
MODEL_MAGIC = b"BMD1"
VERSION = 1
BACKEND_ZLIB_DIAGNOSTIC = 1

# The frame header covers the model and restart directory.  Payload bytes are
# checked by per-block CRCs and by the exact payload length in the header.
HEADER = struct.Struct("<4sBBBBIQQQQII")
DIR = struct.Struct("<QIIIB3x")
MODEL_HEAD = struct.Struct("<4sBBBBQII")
HEADER_BYTES = HEADER.size
DIR_BYTES = DIR.size
MODEL_HEAD_BYTES = MODEL_HEAD.size

MAX_FRAME_BYTES = 512 * 1024 * 1024
MAX_BLOCK_BYTES = 64 * 1024
MAX_BLOCKS = 1_000_000
MAX_MODEL_BYTES = 8 * 1024 * 1024
MAX_TEMPLATES = 1024
MAX_BINDINGS = 4096
# Six slots cover short phrase records while keeping expansion and model
# references finite.  The selected lane still charges every slot binding;
# this is not an unbounded grammar.
MAX_SLOTS = 6
MAX_RECORD_BYTES = 1 * 1024 * 1024
MAX_CONTEXT_BYTES = 1024
MAX_BINDING_BYTES = MAX_RECORD_BYTES
MAX_EVENTS_PER_BLOCK = MAX_BLOCK_BYTES + 1
MAX_EVENT_BYTES = MAX_BLOCK_BYTES * 16 + 128

# Model policy: byte-only scanner, with no Unicode validity or normalization.
POLICY_BYTE_WORD = 1
MODEL_FLAGS = 0


class FrameError(ValueError):
    """Raised for malformed, truncated, or resource-exhausting frames."""


@dataclass(frozen=True, order=True)
class Template:
    """A nonrecursive ranked context with up to three byte slots.

    ``literals`` has one more item than ``variables``.  Expansion is
    ``literal[0] + binding[variables[0]] + literal[1] + ...``.  Variable IDs
    may repeat, so a derivation can bind one exact word/phrase once and replay
    it at several positions.
    """

    literals: tuple[bytes, ...]
    variables: tuple[int, ...]

    def __post_init__(self) -> None:
        if not 2 <= len(self.literals) <= MAX_SLOTS + 1 or len(self.variables) + 1 != len(self.literals):
            raise ValueError("template slot/literal arity is outside bounds")
        if any(not literal for literal in self.literals):
            raise ValueError("template literals must be nonempty")
        if any(variable < 0 or variable >= MAX_SLOTS for variable in self.variables):
            raise ValueError("template variable ID is outside bounds")
        if len(set(self.variables)) > MAX_SLOTS:
            raise ValueError("template has too many variables")
        if set(self.variables) != set(range(max(self.variables) + 1)):
            raise ValueError("template variable IDs must be canonical")
        if sum(map(len, self.literals)) > MAX_CONTEXT_BYTES:
            raise ValueError("template context is too large")

    @property
    def slot_count(self) -> int:
        return max(self.variables, default=-1) + 1

    @property
    def prefix(self) -> bytes:
        """Compatibility accessor for the one-hole description."""

        return self.literals[0]

    @property
    def suffix(self) -> bytes:
        """Compatibility accessor for the one-hole description."""

        return self.literals[-1]


@dataclass(frozen=True)
class Model:
    """All state needed by the decoder, including the binding dictionary."""

    templates: tuple[Template, ...] = ()
    bindings: tuple[bytes, ...] = ()
    training_bytes: int = 0
    policy: int = POLICY_BYTE_WORD

    def __post_init__(self) -> None:
        if self.policy != POLICY_BYTE_WORD:
            raise ValueError("unknown scanner policy")
        if len(self.templates) > MAX_TEMPLATES:
            raise ValueError("too many templates")
        if len(self.bindings) > MAX_BINDINGS:
            raise ValueError("too many bindings")
        if not 0 <= self.training_bytes <= 0xFFFFFFFFFFFFFFFF:
            raise ValueError("training byte count outside u64")
        for template in self.templates:
            if sum(map(len, template.literals)) > MAX_CONTEXT_BYTES:
                raise ValueError("template context is too large")
        for binding in self.bindings:
            if not binding or len(binding) > MAX_BINDING_BYTES:
                raise ValueError("binding outside bounds")

    def to_bytes(self) -> bytes:
        if len(self.templates) > 0xFFFFFFFF or len(self.bindings) > 0xFFFFFFFF:
            raise ValueError("model count outside u32")
        out = bytearray(
            MODEL_HEAD.pack(
                MODEL_MAGIC,
                VERSION,
                self.policy,
                MODEL_FLAGS,
                0,
                self.training_bytes,
                len(self.templates),
                len(self.bindings),
            )
        )
        for template in self.templates:
            # The wire needs the number of slot *occurrences*; variable IDs
            # inside them may repeat and therefore be fewer.
            out.extend(_put_uleb(len(template.variables)))
            for index, literal in enumerate(template.literals):
                out.extend(_put_uleb(len(literal)))
                out.extend(literal)
                if index < len(template.variables):
                    out.extend(_put_uleb(template.variables[index]))
        for binding in self.bindings:
            out.extend(_put_uleb(len(binding)))
            out.extend(binding)
        if len(out) > MAX_MODEL_BYTES:
            raise ValueError("serialized model exceeds bound")
        return bytes(out)

    @classmethod
    def from_bytes(cls, data: bytes) -> "Model":
        if len(data) < MODEL_HEAD_BYTES or len(data) > MAX_MODEL_BYTES:
            raise FrameError("model size outside bound")
        magic, version, policy, flags, reserved, training_bytes, template_count, binding_count = MODEL_HEAD.unpack_from(data)
        if magic != MODEL_MAGIC or version != VERSION or policy != POLICY_BYTE_WORD or flags != MODEL_FLAGS or reserved:
            raise FrameError("invalid model header")
        if template_count > MAX_TEMPLATES or binding_count > MAX_BINDINGS:
            raise FrameError("model table count exceeds bound")
        at = MODEL_HEAD_BYTES
        templates: list[Template] = []
        for _ in range(template_count):
            occurrence_count, at = _read_uleb(data, at, limit=MAX_SLOTS)
            if occurrence_count == 0:
                raise FrameError("template must have a slot")
            literals: list[bytes] = []
            variables: list[int] = []
            total_literals = 0
            for index in range(occurrence_count + 1):
                literal_len, at = _read_uleb(data, at, limit=MAX_CONTEXT_BYTES)
                if literal_len == 0 or at + literal_len > len(data):
                    raise FrameError("invalid template literal")
                literal = data[at : at + literal_len]
                at += literal_len
                total_literals += literal_len
                if total_literals > MAX_CONTEXT_BYTES:
                    raise FrameError("template context exceeds bound")
                literals.append(literal)
                if index < occurrence_count:
                    variable, at = _read_uleb(data, at, limit=MAX_SLOTS - 1)
                    variables.append(variable)
            try:
                templates.append(Template(tuple(literals), tuple(variables)))
            except ValueError as exc:
                raise FrameError(str(exc)) from exc
        bindings: list[bytes] = []
        for _ in range(binding_count):
            length, at = _read_uleb(data, at, limit=MAX_BINDING_BYTES)
            if length == 0 or at + length > len(data):
                raise FrameError("invalid binding")
            bindings.append(data[at : at + length])
            at += length
        if at != len(data):
            raise FrameError("trailing model bytes")
        try:
            return cls(tuple(templates), tuple(bindings), training_bytes, policy)
        except ValueError as exc:
            raise FrameError(str(exc)) from exc


def _crc(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF


def _put_uleb(value: int) -> bytes:
    if value < 0:
        raise ValueError("ULEB128 cannot encode negative values")
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def _uleb_len(value: int) -> int:
    return len(_put_uleb(value))


def _read_uleb(data: bytes, at: int, *, limit: int) -> tuple[int, int]:
    value = 0
    shift = 0
    for count in range(10):
        if at >= len(data):
            raise FrameError("truncated ULEB128")
        part = data[at]
        at += 1
        if count == 9 and part > 1:
            raise FrameError("ULEB128 overflow")
        value |= (part & 0x7F) << shift
        if not (part & 0x80):
            if count and part == 0:
                raise FrameError("noncanonical ULEB128")
            if value > limit:
                raise FrameError("ULEB128 value exceeds bound")
            return value, at
        shift += 7
    raise FrameError("ULEB128 overflow")


def _is_word_byte(value: int) -> bool:
    """Language-neutral byte scanner: ASCII alnum or any high byte."""

    return value >= 0x80 or 0x30 <= value <= 0x39 or 0x41 <= value <= 0x5A or 0x61 <= value <= 0x7A


def _word_spans(record: bytes) -> Iterable[tuple[int, int]]:
    at = 0
    while at < len(record):
        while at < len(record) and not _is_word_byte(record[at]):
            at += 1
        start = at
        while at < len(record) and _is_word_byte(record[at]):
            at += 1
        if at > start:
            yield start, at


def _records(data: bytes) -> list[bytes]:
    """Split only on LF; every other byte remains data."""

    if not data:
        return []
    result: list[bytes] = []
    at = 0
    while at < len(data):
        end = data.find(b"\n", at)
        if end < 0:
            result.append(data[at:])
            break
        result.append(data[at : end + 1])
        at = end + 1
    return result


def _template_cost(template: Template) -> int:
    cost = _uleb_len(template.slot_count)
    for index, literal in enumerate(template.literals):
        cost += _uleb_len(len(literal)) + len(literal)
        if index < len(template.variables):
            cost += _uleb_len(template.variables[index])
    return cost


def _raw_event_cost(record: bytes) -> int:
    return 1 + _uleb_len(len(record)) + len(record)


def _inline_binding_cost(binding: bytes) -> int:
    return 1 + _uleb_len(len(binding)) + len(binding)


def _ref_binding_cost(index: int) -> int:
    return 1 + _uleb_len(index)


def _template_event_cost(template_id: int, bindings: Sequence[bytes], binding_ids: Sequence[int | None]) -> int:
    base = 1 + _uleb_len(template_id)
    for binding, binding_id in zip(bindings, binding_ids):
        base += _inline_binding_cost(binding) if binding_id is None else _ref_binding_cost(binding_id)
    return base


def _pack_records(records: Sequence[bytes], block_bytes: int) -> list[bytes]:
    if block_bytes < 1 or block_bytes > MAX_BLOCK_BYTES:
        raise ValueError("block_bytes outside bound")
    blocks: list[bytes] = []
    current = bytearray()
    for record in records:
        if len(record) > MAX_RECORD_BYTES:
            raise ValueError("record exceeds bound")
        if len(record) > block_bytes:
            if current:
                blocks.append(bytes(current))
                current.clear()
            for at in range(0, len(record), block_bytes):
                blocks.append(record[at : at + block_bytes])
            continue
        if current and len(current) + len(record) > block_bytes:
            blocks.append(bytes(current))
            current.clear()
        current.extend(record)
    if current:
        blocks.append(bytes(current))
    if len(blocks) > MAX_BLOCKS:
        raise ValueError("too many blocks")
    return blocks


def _canonical_variables(values: Sequence[tuple[bytes, ...]]) -> tuple[int, ...]:
    """Share slot IDs only when every derivation binds the same bytes."""

    if not values:
        return ()
    width = len(values[0])
    parent = list(range(width))

    def find(index: int) -> int:
        while parent[index] != index:
            parent[index] = parent[parent[index]]
            index = parent[index]
        return index

    def union(left: int, right: int) -> None:
        left, right = find(left), find(right)
        if left != right:
            parent[right] = left

    for left in range(width):
        for right in range(left + 1, width):
            if all(row[left] == row[right] for row in values):
                union(left, right)
    ids: dict[int, int] = {}
    result: list[int] = []
    for index in range(width):
        root = find(index)
        if root not in ids:
            ids[root] = len(ids)
        result.append(ids[root])
    return tuple(result)


def _bindings_for_variables(values: tuple[bytes, ...], variables: Sequence[int]) -> tuple[bytes, ...]:
    result: list[bytes | None] = [None] * (max(variables, default=-1) + 1)
    for value, variable in zip(values, variables):
        if result[variable] is None:
            result[variable] = value
        elif result[variable] != value:
            raise ValueError("inconsistent repeated variable binding")
    return tuple(item for item in result if item is not None)


def _word_template(record: bytes, *, max_context_bytes: int) -> tuple[Template, tuple[bytes, ...]] | None:
    spans = list(_word_spans(record))
    if not 1 <= len(spans) <= MAX_SLOTS:
        return None
    literals: list[bytes] = []
    values: list[bytes] = []
    at = 0
    for start, end in spans:
        literal = record[at:start]
        if not literal:
            return None
        literals.append(literal)
        values.append(record[start:end])
        at = end
    if not record[at:]:
        return None
    literals.append(record[at:])
    if sum(map(len, literals)) > max_context_bytes:
        return None
    # The template starts with independent slots; group-level canonicalization
    # below identifies repeated same-word positions across all derivations.
    try:
        return Template(tuple(literals), tuple(range(len(values)))), tuple(values)
    except ValueError:
        return None


def _anti_unify_pair(left: bytes, right: bytes, *, max_context_bytes: int) -> tuple[Template, tuple[tuple[bytes, ...], tuple[bytes, ...]]] | None:
    """Anti-unify two records at stable equal byte islands.

    Equal islands become literals; each differing island becomes a slot.  The
    procedure is bounded to three slots and rejects leading/trailing/empty
    literals, which prevents a whole unrelated record from becoming a cheap
    one-slot alias.  It is deliberately not a probabilistic parser.
    """

    if not left or len(left) > MAX_RECORD_BYTES or len(right) > MAX_RECORD_BYTES:
        return None
    matcher = difflib.SequenceMatcher(a=left, b=right, autojunk=False)
    gaps = [opcode for opcode in matcher.get_opcodes() if opcode[0] != "equal"]
    if not gaps or len(gaps) > MAX_SLOTS:
        return None
    literals: list[bytes] = []
    left_values: list[bytes] = []
    right_values: list[bytes] = []
    left_at = right_at = 0
    for _, left_start, left_end, right_start, right_end in gaps:
        literal_left = left[left_at:left_start]
        literal_right = right[right_at:right_start]
        if not literal_left or literal_left != literal_right:
            return None
        left_value = left[left_start:left_end]
        right_value = right[right_start:right_end]
        if not left_value or not right_value:
            return None
        literals.append(literal_left)
        left_values.append(left_value)
        right_values.append(right_value)
        left_at, right_at = left_end, right_end
    tail_left, tail_right = left[left_at:], right[right_at:]
    if not tail_left or tail_left != tail_right:
        return None
    literals.append(tail_left)
    if sum(map(len, literals)) > max_context_bytes:
        return None
    all_values = (tuple(left_values), tuple(right_values))
    variables = _canonical_variables(all_values)
    try:
        template = Template(tuple(literals), variables)
        return template, (
            _bindings_for_variables(tuple(left_values), variables),
            _bindings_for_variables(tuple(right_values), variables),
        )
    except ValueError:
        return None


def _candidate_groups(training: bytes, *, max_context_bytes: int) -> dict[Template, list[tuple[bytes, ...]]]:
    groups: dict[Template, list[tuple[bytes, ...]]] = defaultdict(list)
    for record in _records(training):
        if not record or len(record) > MAX_RECORD_BYTES:
            continue
        candidate = _word_template(record, max_context_bytes=max_context_bytes)
        if candidate is not None:
            template, values = candidate
            groups[template].append(values)

    # A small, deterministic pair screen adds true anti-unification: two
    # records may differ in markup/phrase islands rather than having the same
    # maximal-word skeleton.  Similar-length/prefix/suffix buckets cap the
    # quadratic work and are part of the frozen policy.
    buckets: dict[tuple[int, bytes, bytes, int], list[bytes]] = defaultdict(list)
    for record in _records(training):
        if len(record) > MAX_RECORD_BYTES or not record:
            continue
        spans = list(_word_spans(record))
        key = (len(spans), record[:8], record[-8:], len(record) // 16)
        if len(buckets[key]) < 32 and record not in buckets[key]:
            buckets[key].append(record)
    for records in buckets.values():
        for left_index in range(len(records)):
            for right_index in range(left_index + 1, len(records)):
                candidate = _anti_unify_pair(records[left_index], records[right_index], max_context_bytes=max_context_bytes)
                if candidate is None:
                    continue
                template, values = candidate
                groups[template].extend(values)
    # Canonicalize exact word skeletons and pair candidates together.  This is
    # where repeated same-word slots become one variable identity in the
    # serialized ranked program whenever every derivation agrees.
    normalized: dict[Template, list[tuple[bytes, ...]]] = defaultdict(list)
    for template, values in groups.items():
        if not values or any(len(row) != len(template.variables) for row in values):
            continue
        variables = _canonical_variables(values)
        try:
            canonical = Template(template.literals, variables)
        except ValueError:
            continue
        # Keep occurrence-level rows here.  The template carries the repeated
        # variable IDs, and the encoder derives the shorter unique binding
        # tuple at pricing/serialization time.
        normalized[canonical].extend(values)
    return normalized


def train(
    training: bytes,
    *,
    max_templates: int = 96,
    max_bindings: int = 512,
    min_uses: int = 2,
    max_context_bytes: int = MAX_CONTEXT_BYTES,
) -> Model:
    """Learn a bounded template/binding model from training bytes only.

    Candidate selection is a single corpus-independent lower-bound MDL screen:
    repeated templates need at least two *different* bindings and their
    estimated inline event saving must pay the serialized literal context.
    The final frame still charges all model and event bytes, so this screen is
    intentionally conservative and not a claim of optimal induction.
    """

    if not isinstance(training, bytes):
        raise TypeError("training must be bytes")
    if not 0 <= max_templates <= MAX_TEMPLATES or not 0 <= max_bindings <= MAX_BINDINGS:
        raise ValueError("model caps outside bound")
    if min_uses < 2:
        raise ValueError("min_uses must be at least two")
    if max_context_bytes < 2 or max_context_bytes > MAX_CONTEXT_BYTES:
        raise ValueError("max_context_bytes outside bound")
    groups = _candidate_groups(training, max_context_bytes=max_context_bytes)
    ranked: list[tuple[int, int, int, Template, list[tuple[bytes, ...]]]] = []
    for template, values in groups.items():
        distinct = set(values)
        if len(values) < min_uses or len(distinct) < 2:
            continue
        # IDs are one byte for the bounded table in the normal case.  Use the
        # actual candidate rank-independent lower bound for deterministic
        # pruning; dictionary bindings are selected in a second pass.
        event_save = 0
        for row in values:
            try:
                bindings = _bindings_for_variables(row, template.variables)
            except ValueError:
                continue
            expanded = b"".join(literal + (bindings[template.variables[index]] if index < len(template.variables) else b"") for index, literal in enumerate(template.literals))
            event_save += max(0, _raw_event_cost(expanded) - _template_event_cost(0, bindings, [None] * len(bindings)))
        score = event_save - _template_cost(template)
        if score <= 0:
            continue
        ranked.append((score, len(values), len(distinct), template, values))
    ranked.sort(key=lambda item: (-item[0], -item[1], -item[2], item[3].prefix, item[3].suffix))
    selected = ranked[:max_templates]
    templates = tuple(item[3] for item in selected)

    # Build a global binding dictionary only when a value's repeated reference
    # can pay its own serialized bytes.  This charges repeated same-word slots
    # without turning every one-off argument into model overhead.
    value_counts: Counter[bytes] = Counter()
    for _, _, _, template, values in selected:
        for row in values:
            try:
                value_counts.update(_bindings_for_variables(row, template.variables))
            except ValueError:
                continue
    binding_candidates: list[tuple[int, bytes]] = []
    for value, count in value_counts.items():
        if count < 2:
            continue
        model_cost = _uleb_len(len(value)) + len(value)
        if max_bindings == 0:
            continue
        saving = count * (_inline_binding_cost(value) - _ref_binding_cost(max_bindings - 1)) - model_cost
        if saving > 0:
            binding_candidates.append((saving, value))
    binding_candidates.sort(key=lambda item: (-item[0], item[1]))
    bindings = tuple(value for _, value in binding_candidates[:max_bindings])
    return Model(templates=templates, bindings=bindings, training_bytes=len(training))


def _match_record(model: Model, record: bytes) -> tuple[int, tuple[bytes, ...]] | None:
    candidates: list[tuple[int, int, int, tuple[bytes, ...]]] = []
    for template_id, template in enumerate(model.templates):
        if not record.startswith(template.literals[0]):
            continue
        bindings: list[bytes | None] = [None] * template.slot_count
        at = len(template.literals[0])
        valid = True
        for index, literal in enumerate(template.literals[1:]):
            end = record.find(literal, at)
            if end <= at:
                valid = False
                break
            value = record[at:end]
            variable = template.variables[index]
            if bindings[variable] is None:
                bindings[variable] = value
            elif bindings[variable] != value:
                valid = False
                break
            at = end + len(literal)
        if not valid or at != len(record) or any(value is None for value in bindings):
            continue
        concrete = tuple(value for value in bindings if value is not None)
        binding_ids = [model.bindings.index(value) if value in model.bindings else None for value in concrete]
        cost = _template_event_cost(template_id, concrete, binding_ids)
        # Prefer the lower event cost, then a longer fixed context, then ID.
        candidates.append((cost, -sum(map(len, template.literals)), template_id, concrete))
    if not candidates:
        return None
    _, _, template_id, bindings = min(candidates)
    return template_id, bindings


def _encode_event_stream(model: Model, records: Sequence[bytes]) -> tuple[bytes, dict[str, int]]:
    binding_ids = {value: index for index, value in enumerate(model.bindings)}
    events = bytearray(_put_uleb(len(records)))
    raw_events = template_events = inline_bindings = binding_refs = 0
    for record in records:
        if len(record) > MAX_RECORD_BYTES:
            raise ValueError("record exceeds bound")
        match = _match_record(model, record)
        raw_cost = _raw_event_cost(record)
        if match is None:
            use_template = False
        else:
            template_id, bindings = match
            binding_refs_for_cost = [binding_ids.get(binding) for binding in bindings]
            template_cost = _template_event_cost(template_id, bindings, binding_refs_for_cost)
            use_template = template_cost < raw_cost
        if not use_template:
            events.append(0)
            events.extend(_put_uleb(len(record)))
            events.extend(record)
            raw_events += 1
            continue
        template_id, bindings = match  # type: ignore[misc]
        events.append(1)
        events.extend(_put_uleb(template_id))
        for binding in bindings:
            binding_id = binding_ids.get(binding)
            if binding_id is not None:
                events.append(0)
                events.extend(_put_uleb(binding_id))
                binding_refs += 1
            else:
                events.append(1)
                events.extend(_put_uleb(len(binding)))
                events.extend(binding)
                inline_bindings += 1
        template_events += 1
    if len(events) > MAX_EVENT_BYTES:
        raise ValueError("event stream exceeds bound")
    return bytes(events), {
        "record_count": len(records),
        "raw_events": raw_events,
        "template_events": template_events,
        "inline_bindings": inline_bindings,
        "binding_refs": binding_refs,
    }


def encode(model: Model, data: bytes, *, block_bytes: int = MAX_BLOCK_BYTES, compression_level: int = 9) -> bytes:
    """Encode exact bytes into a bounded self-contained frame."""

    if not isinstance(model, Model) or not isinstance(data, bytes):
        raise TypeError("encode expects Model and bytes")
    if not 0 <= compression_level <= 9:
        raise ValueError("compression level outside zlib range")
    model_bytes = model.to_bytes()
    blocks = _pack_records(_records(data), block_bytes)
    payload = bytearray()
    directory = bytearray()
    records_total = 0
    event_stats = Counter()
    for block in blocks:
        block_records = _records(block)
        # A block produced by splitting a long record may have no LF; treating
        # it as one record is intentional and keeps the transform exact.
        event_stream, stats = _encode_event_stream(model, block_records)
        event_stats.update(stats)
        records_total += len(block_records)
        coded = zlib.compress(event_stream, compression_level)
        mode = 0
        body = coded
        if len(event_stream) <= len(coded):
            mode = 1
            body = event_stream
        offset = len(payload)
        payload.extend(body)
        directory.extend(DIR.pack(offset, len(body), len(block), _crc(block), mode))
    if not blocks and data:
        raise AssertionError("nonempty input must produce blocks")
    if len(blocks) > MAX_BLOCKS or len(payload) > MAX_FRAME_BYTES:
        raise ValueError("frame payload outside bound")
    metadata_crc = _crc(
        HEADER.pack(
            MAGIC,
            VERSION,
            BACKEND_ZLIB_DIAGNOSTIC,
            0,
            max(0, min(31, block_bytes.bit_length() - 1)),
            len(blocks),
            len(data),
            len(model_bytes),
            len(directory),
            len(payload),
            _crc(model_bytes),
            0,
        )
        + model_bytes
        + directory
    )
    header = HEADER.pack(
        MAGIC,
        VERSION,
        BACKEND_ZLIB_DIAGNOSTIC,
        0,
        max(0, min(31, block_bytes.bit_length() - 1)),
        len(blocks),
        len(data),
        len(model_bytes),
        len(directory),
        len(payload),
        _crc(model_bytes),
        metadata_crc,
    )
    frame = bytes(header + model_bytes + directory + payload)
    if len(frame) > MAX_FRAME_BYTES:
        raise ValueError("frame exceeds bound")
    # Keep diagnostics available without making them wire state.  The caller
    # can recompute from frame_info; this local assertion catches accounting
    # errors in development.
    if records_total != event_stats["record_count"]:
        raise AssertionError("event accounting mismatch")
    return frame


def _decode_event_stream(model: Model, stream: bytes, expected_raw: int) -> tuple[bytes, dict[str, int]]:
    if len(stream) > MAX_EVENT_BYTES:
        raise FrameError("event stream exceeds bound")
    count, at = _read_uleb(stream, 0, limit=MAX_EVENTS_PER_BLOCK)
    out = bytearray()
    raw_events = template_events = inline_bindings = binding_refs = 0
    for _ in range(count):
        if at >= len(stream):
            raise FrameError("truncated event stream")
        tag = stream[at]
        at += 1
        if tag == 0:
            length, at = _read_uleb(stream, at, limit=MAX_RECORD_BYTES)
            if at + length > len(stream) or len(out) + length > MAX_BLOCK_BYTES:
                raise FrameError("raw event exceeds block bound")
            out.extend(stream[at : at + length])
            at += length
            raw_events += 1
        elif tag == 1:
            template_id, at = _read_uleb(stream, at, limit=MAX_TEMPLATES - 1)
            if template_id >= len(model.templates) or at >= len(stream):
                raise FrameError("invalid template reference")
            template = model.templates[template_id]
            bindings: list[bytes] = []
            for _ in range(template.slot_count):
                if at >= len(stream):
                    raise FrameError("truncated template binding")
                binding_mode = stream[at]
                at += 1
                if binding_mode == 0:
                    binding_id, at = _read_uleb(stream, at, limit=MAX_BINDINGS - 1)
                    if binding_id >= len(model.bindings):
                        raise FrameError("invalid binding reference")
                    binding = model.bindings[binding_id]
                    binding_refs += 1
                elif binding_mode == 1:
                    length, at = _read_uleb(stream, at, limit=MAX_BINDING_BYTES)
                    if length == 0 or at + length > len(stream):
                        raise FrameError("invalid inline binding")
                    binding = stream[at : at + length]
                    at += length
                    inline_bindings += 1
                else:
                    raise FrameError("unknown binding mode")
                bindings.append(binding)
            piece_len = sum(map(len, template.literals)) + sum(len(binding) for binding in bindings)
            if piece_len > MAX_RECORD_BYTES or len(out) + piece_len > MAX_BLOCK_BYTES:
                raise FrameError("template expansion exceeds block bound")
            for index, literal in enumerate(template.literals):
                out.extend(literal)
                if index < len(template.variables):
                    out.extend(bindings[template.variables[index]])
            template_events += 1
        else:
            raise FrameError("unknown event tag")
    if at != len(stream):
        raise FrameError("trailing event bytes")
    if len(out) != expected_raw:
        raise FrameError("decoded block length mismatch")
    return bytes(out), {
        "event_count": count,
        "raw_events": raw_events,
        "template_events": template_events,
        "inline_bindings": inline_bindings,
        "binding_refs": binding_refs,
    }


def _zlib_decode(body: bytes) -> bytes:
    decoder = zlib.decompressobj()
    result = decoder.decompress(body, MAX_EVENT_BYTES + 1)
    if len(result) > MAX_EVENT_BYTES or decoder.unconsumed_tail:
        raise FrameError("zlib event stream exceeds bound")
    tail = decoder.flush(MAX_EVENT_BYTES + 1 - len(result))
    result += tail
    if len(result) > MAX_EVENT_BYTES or not decoder.eof or decoder.unused_data:
        raise FrameError("invalid zlib event stream")
    return result


def _parse_frame(frame: bytes) -> tuple[Model, list[tuple[int, int, int, int, int]], bytes, int]:
    if not isinstance(frame, bytes) or len(frame) < HEADER_BYTES or len(frame) > MAX_FRAME_BYTES:
        raise FrameError("frame size outside bound")
    fields = HEADER.unpack_from(frame)
    magic, version, backend, flags, block_log, block_count, raw_len, model_len, dir_len, payload_len, model_crc, metadata_crc = fields
    if magic != MAGIC or version != VERSION or backend != BACKEND_ZLIB_DIAGNOSTIC or flags != 0 or block_log > 31:
        raise FrameError("invalid frame header")
    if block_count > MAX_BLOCKS or model_len > MAX_MODEL_BYTES or dir_len != block_count * DIR_BYTES:
        raise FrameError("frame table bound mismatch")
    total = HEADER_BYTES + model_len + dir_len + payload_len
    if total != len(frame) or total > MAX_FRAME_BYTES:
        raise FrameError("frame lengths mismatch")
    model_bytes = frame[HEADER_BYTES : HEADER_BYTES + model_len]
    directory_bytes = frame[HEADER_BYTES + model_len : HEADER_BYTES + model_len + dir_len]
    payload = frame[HEADER_BYTES + model_len + dir_len :]
    if _crc(model_bytes) != model_crc:
        raise FrameError("model CRC mismatch")
    metadata_header = HEADER.pack(magic, version, backend, flags, block_log, block_count, raw_len, model_len, dir_len, payload_len, model_crc, 0)
    if _crc(metadata_header + model_bytes + directory_bytes) != metadata_crc:
        raise FrameError("metadata CRC mismatch")
    model = Model.from_bytes(model_bytes)
    directory: list[tuple[int, int, int, int, int]] = []
    previous_end = 0
    total_raw = 0
    for index in range(block_count):
        offset, coded_len, block_raw_len, block_crc, mode = DIR.unpack_from(directory_bytes, index * DIR_BYTES)
        if mode not in (0, 1) or offset != previous_end or offset + coded_len > len(payload) or block_raw_len > MAX_BLOCK_BYTES:
            raise FrameError("invalid block directory")
        previous_end = offset + coded_len
        total_raw += block_raw_len
        if total_raw > raw_len:
            raise FrameError("block raw lengths exceed frame length")
        directory.append((offset, coded_len, block_raw_len, block_crc, mode))
    if previous_end != len(payload) or total_raw != raw_len:
        raise FrameError("block directory total mismatch")
    return model, directory, payload, raw_len


def decode(frame: bytes) -> bytes:
    """Decode and independently validate a complete frame."""

    model, directory, payload, raw_len = _parse_frame(frame)
    output = bytearray()
    for offset, coded_len, block_raw_len, block_crc, mode in directory:
        body = payload[offset : offset + coded_len]
        stream = body if mode == 1 else _zlib_decode(body)
        block, _ = _decode_event_stream(model, stream, block_raw_len)
        if _crc(block) != block_crc:
            raise FrameError("block CRC mismatch")
        output.extend(block)
        if len(output) > raw_len:
            raise FrameError("decoded frame exceeds declared length")
    if len(output) != raw_len:
        raise FrameError("decoded frame length mismatch")
    return bytes(output)


def frame_info(frame: bytes) -> dict[str, int | str]:
    """Return complete-byte accounting after validating frame metadata."""

    model, directory, payload, raw_len = _parse_frame(frame)
    model_len = len(model.to_bytes())
    directory_len = len(directory) * DIR_BYTES
    raw_blocks = sum(1 for _, _, _, _, mode in directory if mode == 1)
    return {
        "frame_bytes": len(frame),
        "raw_bytes": raw_len,
        "model_bytes": model_len,
        "directory_bytes": directory_len,
        "payload_bytes": len(payload),
        "blocks": len(directory),
        "raw_blocks": raw_blocks,
        "templates": len(model.templates),
        "bindings": len(model.bindings),
        "backend": "zlib-diagnostic",
        "training_bytes": model.training_bytes,
    }


def model_info(model: Model) -> dict[str, int]:
    """Return charged model size and table counts for a trained model."""

    return {
        "model_bytes": len(model.to_bytes()),
        "templates": len(model.templates),
        "bindings": len(model.bindings),
        "training_bytes": model.training_bytes,
    }


__all__ = [
    "BACKEND_ZLIB_DIAGNOSTIC",
    "FrameError",
    "Model",
    "Template",
    "decode",
    "encode",
    "frame_info",
    "model_info",
    "train",
]
