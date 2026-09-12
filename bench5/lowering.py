"""Pure LEX4-JSON to neutral LEX5 input lowering.

This module is a reviewable host contract, not a native encoder or reader.  It
keeps the five legacy fixtures' normalized records and physical facts while
leaving source documents/bindings empty because the fixtures contain no source
events.  Query answers and schedules are intentionally outside this module.
"""

from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass
from typing import Mapping, Sequence


SENSE_ENTRY_PREDICATE = "sense_of"
BOOK_ID_RULE = "fixture-name-as-book-id"
SCHEMA_VERSION = 1
I64_MIN = -(1 << 63)
I64_MAX = (1 << 63) - 1
VALUE_KINDS = frozenset({"string", "symbol", "boolean", "product"})
RECORD_KINDS = frozenset({"entry", "sense", "concept"})


class LoweringError(ValueError):
    """Canonical fixture data cannot be lowered without semantic loss."""


@dataclass(frozen=True)
class NeutralValue:
    value_id: int
    kind: str
    payload: object


@dataclass(frozen=True)
class NeutralRecord:
    kind: str
    ordinal: int
    external_id: int
    book_kind_namespace: tuple[str, str]
    language: str | None = None
    label: bytes | None = None
    features_value: int | None = None


@dataclass(frozen=True)
class NeutralKey:
    ordinal: int
    key: bytes
    entry_ordinal: int
    entry_external_id: int


@dataclass(frozen=True)
class NeutralRef:
    kind: str
    ordinal: int
    external_id: int
    book_kind_namespace: tuple[str, str]


@dataclass(frozen=True)
class NeutralFact:
    ordinal: int
    kind: str
    subject: NeutralRef
    predicate: str | None
    object: NeutralRef
    properties_value: int | None = None
    origin: str = ""
    legacy_index: int | None = None


@dataclass(frozen=True)
class NeutralInput:
    schema: int
    book: str
    fixture: str
    seed: int
    metadata: Mapping[str, object]
    values: tuple[NeutralValue, ...]
    records: tuple[NeutralRecord, ...]
    keys: tuple[NeutralKey, ...]
    facts: tuple[NeutralFact, ...]
    predicates: tuple[str, ...]
    documents: tuple[object, ...] = ()
    bindings: tuple[object, ...] = ()


class _ValuePool:
    def __init__(self) -> None:
        self.values: list[NeutralValue] = []
        self.index: dict[tuple[str, object], int] = {}

    def add(self, kind: str, payload: object) -> int:
        if isinstance(payload, list):
            payload = tuple(payload)
        if isinstance(payload, dict):
            payload = tuple(sorted(payload.items()))
        key = (kind, payload)
        found = self.index.get(key)
        if found is not None:
            return found
        value_id = len(self.values)
        self.index[key] = value_id
        self.values.append(NeutralValue(value_id, kind, payload))
        return value_id

    def product(self, fields: Sequence[tuple[str, int]]) -> int:
        for field_name, value_id in fields:
            if not isinstance(field_name, str) or not field_name:
                raise LoweringError("product field name must be a non-empty string")
            if isinstance(value_id, bool) or not isinstance(value_id, int):
                raise LoweringError(f"product field {field_name!r} must reference a ValueId")
        return self.add("product", tuple(fields))


def _object(value: object, name: str) -> Mapping[str, object]:
    if not isinstance(value, Mapping):
        raise LoweringError(f"{name} must be an object")
    return value


def _list(value: object, name: str) -> list[object]:
    if not isinstance(value, list):
        raise LoweringError(f"{name} must be an array")
    return value


def _text(value: object, name: str) -> str:
    if not isinstance(value, str):
        raise LoweringError(f"{name} must be a string")
    return value


def _integer(value: object, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise LoweringError(f"{name} must be an integer")
    if value < I64_MIN or value > I64_MAX:
        raise LoweringError(f"{name} is outside signed i64 range")
    return value


def _boolean(value: object, name: str) -> bool:
    if not isinstance(value, bool):
        raise LoweringError(f"{name} must be a boolean")
    return value


def _bytes_hex(value: object, name: str) -> bytes:
    encoded = _text(value, name)
    try:
        return bytes.fromhex(encoded)
    except ValueError as exc:
        raise LoweringError(f"{name} is not valid hexadecimal") from exc


def _required(row: Mapping[str, object], fields: Sequence[str], name: str) -> None:
    missing = [field for field in fields if field not in row]
    if missing:
        raise LoweringError(f"{name} missing fields: {', '.join(missing)}")


def _reject_unknown(row: Mapping[str, object], fields: Sequence[str], name: str) -> None:
    unknown = sorted(set(row) - set(fields))
    if unknown:
        raise LoweringError(f"{name} has unlowered fields: {', '.join(unknown)}")


def _namespace(book: str, kind: str) -> tuple[str, str]:
    return (book, kind)


def _ref(records: Mapping[tuple[str, int], NeutralRecord], kind: str, external_id: int, name: str) -> NeutralRef:
    record = records.get((kind, external_id))
    if record is None:
        raise LoweringError(f"{name} references missing {kind} ID {external_id}")
    return NeutralRef(kind, record.ordinal, record.external_id, record.book_kind_namespace)


def _value_ref(values: Mapping[int, NeutralValue], value_id: object, name: str) -> NeutralValue:
    if isinstance(value_id, bool) or not isinstance(value_id, int):
        raise LoweringError(f"{name} must be a ValueId")
    target = values.get(value_id)
    if target is None:
        raise LoweringError(f"{name} references missing ValueId {value_id}")
    return target


def _product_fields(values: Mapping[int, NeutralValue], value_id: object, name: str) -> tuple[tuple[str, int], ...]:
    product = _value_ref(values, value_id, name)
    if product.kind != "product" or not isinstance(product.payload, tuple):
        raise LoweringError(f"{name} must reference a product Value")
    fields: list[tuple[str, int]] = []
    seen: set[str] = set()
    for index, field in enumerate(product.payload):
        if not isinstance(field, tuple) or len(field) != 2:
            raise LoweringError(f"{name}.payload[{index}] is not a named ValueId field")
        field_name, member_id = field
        if not isinstance(field_name, str) or not field_name:
            raise LoweringError(f"{name}.payload[{index}] has an invalid field name")
        if field_name in seen:
            raise LoweringError(f"{name} repeats field {field_name!r}")
        seen.add(field_name)
        if isinstance(member_id, bool) or not isinstance(member_id, int):
            raise LoweringError(f"{name}.{field_name} is not a ValueId")
        _value_ref(values, member_id, f"{name}.{field_name}")
        fields.append((field_name, member_id))
    return tuple(fields)


def _record_ref(record: NeutralRef, records: Mapping[tuple[str, int], NeutralRecord], book: str, name: str) -> NeutralRecord:
    if not isinstance(record, NeutralRef):
        raise LoweringError(f"{name} is not a typed NeutralRef")
    if record.kind not in RECORD_KINDS:
        raise LoweringError(f"{name} has unsupported record kind {record.kind!r}")
    if isinstance(record.ordinal, bool) or not isinstance(record.ordinal, int) or record.ordinal < 0:
        raise LoweringError(f"{name}.ordinal is invalid")
    if isinstance(record.external_id, bool) or not isinstance(record.external_id, int) or not (I64_MIN <= record.external_id <= I64_MAX):
        raise LoweringError(f"{name}.external_id is outside signed i64 range")
    if record.book_kind_namespace != _namespace(book, record.kind):
        raise LoweringError(f"{name} has the wrong Book+Kind namespace")
    target = records.get((record.kind, record.external_id))
    if target is None or target.ordinal != record.ordinal:
        raise LoweringError(f"{name} does not resolve by Book+Kind ID")
    return target


def validate_neutral(value: NeutralInput) -> None:
    """Validate the complete declared neutral shape, without consulting an oracle."""

    if not isinstance(value, NeutralInput):
        raise LoweringError("value is not a NeutralInput")
    if isinstance(value.schema, bool) or not isinstance(value.schema, int) or value.schema != SCHEMA_VERSION:
        raise LoweringError(f"unsupported neutral schema {value.schema!r}")
    if not isinstance(value.book, str) or not value.book:
        raise LoweringError("neutral book must be a non-empty string")
    if not isinstance(value.fixture, str) or not value.fixture:
        raise LoweringError("neutral fixture must be a non-empty string")
    if isinstance(value.seed, bool) or not isinstance(value.seed, int) or not (I64_MIN <= value.seed <= I64_MAX):
        raise LoweringError("neutral seed is outside signed i64 range")
    if not isinstance(value.metadata, Mapping):
        raise LoweringError("neutral metadata must be an object")
    if value.documents != () or value.bindings != ():
        raise LoweringError("legacy fixtures have no source documents or bindings")

    if not isinstance(value.values, tuple):
        raise LoweringError("neutral values must be a tuple")
    values: dict[int, NeutralValue] = {}
    for expected_id, item in enumerate(value.values):
        if not isinstance(item, NeutralValue):
            raise LoweringError(f"values[{expected_id}] is not a NeutralValue")
        if isinstance(item.value_id, bool) or not isinstance(item.value_id, int) or item.value_id != expected_id:
            raise LoweringError("ValueIds are not contiguous")
        if item.kind not in VALUE_KINDS:
            raise LoweringError(f"values[{expected_id}] has unsupported kind {item.kind!r}")
        if item.kind == "string" and not isinstance(item.payload, bytes):
            raise LoweringError(f"values[{expected_id}] string payload is not bytes")
        if item.kind == "symbol" and not isinstance(item.payload, str):
            raise LoweringError(f"values[{expected_id}] symbol payload is not a string")
        if item.kind == "boolean" and not isinstance(item.payload, bool):
            raise LoweringError(f"values[{expected_id}] boolean payload is not bool")
        if item.kind == "product":
            if not isinstance(item.payload, tuple):
                raise LoweringError(f"values[{expected_id}] product payload is not a tuple")
        values[item.value_id] = item
    # Product fields can point to any complete ValueId, so validate them once
    # after the full value table has been assembled as well as checking shape.
    for item in value.values:
        if item.kind == "product":
            _product_fields(values, item.value_id, f"values[{item.value_id}]")

    if not isinstance(value.records, tuple):
        raise LoweringError("neutral records must be a tuple")
    records: dict[tuple[str, int], NeutralRecord] = {}
    ordinals_by_kind: dict[str, list[int]] = {kind: [] for kind in RECORD_KINDS}
    for index, record in enumerate(value.records):
        if not isinstance(record, NeutralRecord):
            raise LoweringError(f"records[{index}] is not a NeutralRecord")
        if record.kind not in RECORD_KINDS:
            raise LoweringError(f"records[{index}] has unsupported kind {record.kind!r}")
        if isinstance(record.ordinal, bool) or not isinstance(record.ordinal, int) or record.ordinal < 0:
            raise LoweringError(f"records[{index}].ordinal is invalid")
        if record.ordinal != len(ordinals_by_kind[record.kind]):
            raise LoweringError(f"{record.kind} record ordinals are not contiguous")
        ordinals_by_kind[record.kind].append(record.ordinal)
        if isinstance(record.external_id, bool) or not isinstance(record.external_id, int) or not (I64_MIN <= record.external_id <= I64_MAX):
            raise LoweringError(f"records[{index}].external_id is outside signed i64 range")
        identity = (record.kind, record.external_id)
        if identity in records:
            raise LoweringError("duplicate Book+Kind external identity")
        if record.book_kind_namespace != _namespace(value.book, record.kind):
            raise LoweringError("record external-ID namespace is not Book+Kind")
        if record.kind in {"entry", "sense"}:
            if not isinstance(record.language, str):
                raise LoweringError(f"records[{index}] language must be a string")
            if record.label is not None:
                raise LoweringError(f"records[{index}] has an unexpected label")
            if record.features_value is None:
                raise LoweringError(f"records[{index}] is missing its features ValueId")
        else:
            if record.language is not None:
                raise LoweringError(f"records[{index}] concept has an unexpected language")
            if not isinstance(record.label, bytes):
                raise LoweringError(f"records[{index}] concept label is not bytes")
            if record.features_value is not None:
                raise LoweringError(f"records[{index}] concept has unexpected features")
        if record.features_value is not None:
            _value_ref(values, record.features_value, f"records[{index}].features_value")
            fields = _product_fields(values, record.features_value, f"records[{index}].features_value")
            expected_fields = ("definition", "homograph") if record.kind == "entry" else ("definition",)
            if record.kind in {"entry", "sense"} and tuple(name for name, _ in fields) != expected_fields:
                raise LoweringError(f"records[{index}] has the wrong feature fields")
            for field_name, member_id in fields:
                member = values[member_id]
                expected_kind = "boolean" if field_name == "homograph" else "string"
                if member.kind != expected_kind:
                    raise LoweringError(f"records[{index}].features.{field_name} has the wrong Value kind")
        records[identity] = record

    if not isinstance(value.predicates, tuple):
        raise LoweringError("predicate catalogue must be a tuple")
    if any(not isinstance(predicate, str) or not predicate for predicate in value.predicates):
        raise LoweringError("predicate catalogue contains an empty/non-string name")
    if len(set(value.predicates)) != len(value.predicates):
        raise LoweringError("predicate catalogue repeats a name")
    if value.predicates.count(SENSE_ENTRY_PREDICATE) != 1:
        raise LoweringError("predicate catalogue must declare sense_of exactly once")

    if not isinstance(value.keys, tuple):
        raise LoweringError("neutral keys must be a tuple")
    keyed_entries: list[int] = []
    for expected_ordinal, key in enumerate(value.keys):
        if not isinstance(key, NeutralKey):
            raise LoweringError(f"keys[{expected_ordinal}] is not a NeutralKey")
        if key.ordinal != expected_ordinal:
            raise LoweringError("key ordinals are not contiguous")
        if not isinstance(key.key, bytes):
            raise LoweringError(f"keys[{expected_ordinal}].key is not bytes")
        if isinstance(key.entry_ordinal, bool) or not isinstance(key.entry_ordinal, int) or key.entry_ordinal < 0:
            raise LoweringError(f"keys[{expected_ordinal}].entry_ordinal is invalid")
        if isinstance(key.entry_external_id, bool) or not isinstance(key.entry_external_id, int) or not (I64_MIN <= key.entry_external_id <= I64_MAX):
            raise LoweringError(f"keys[{expected_ordinal}].entry_external_id is outside signed i64 range")
        entry = records.get(("entry", key.entry_external_id))
        if entry is None or entry.ordinal != key.entry_ordinal:
            raise LoweringError("key row targets the wrong entry ordinal")
        keyed_entries.append(key.entry_ordinal)
    entry_count = len(ordinals_by_kind["entry"])
    if sorted(keyed_entries) != list(range(entry_count)):
        raise LoweringError("key rows do not cover each entry exactly once")

    if not isinstance(value.facts, tuple):
        raise LoweringError("neutral facts must be a tuple")
    sense_of_subjects: set[int] = set()
    membership_pairs: set[tuple[int, int]] = set()
    legacy_indices: list[int] = []
    fact_predicates: set[str] = set()
    for expected_ordinal, fact in enumerate(value.facts):
        if not isinstance(fact, NeutralFact):
            raise LoweringError(f"facts[{expected_ordinal}] is not a NeutralFact")
        if isinstance(fact.ordinal, bool) or not isinstance(fact.ordinal, int) or fact.ordinal != expected_ordinal:
            raise LoweringError("fact ordinals are not contiguous")
        subject = _record_ref(fact.subject, records, value.book, f"facts[{expected_ordinal}].subject")
        target = _record_ref(fact.object, records, value.book, f"facts[{expected_ordinal}].object")
        if fact.properties_value is not None:
            _product_fields(values, fact.properties_value, f"facts[{expected_ordinal}].properties_value")
        if not isinstance(fact.origin, str):
            raise LoweringError(f"facts[{expected_ordinal}].origin is not a string")
        if fact.kind == "membership":
            if subject.kind != "sense" or target.kind != "concept":
                raise LoweringError("membership endpoints must be sense -> concept")
            if fact.predicate is not None or fact.properties_value is not None:
                raise LoweringError("membership facts cannot have predicates or properties")
            if fact.origin != "sense.concept" or fact.legacy_index is not None:
                raise LoweringError("membership provenance is malformed")
            pair = (subject.external_id, target.external_id)
            if pair in membership_pairs:
                raise LoweringError("repeated physical membership fact")
            membership_pairs.add(pair)
        elif fact.kind == "relation":
            if not isinstance(fact.predicate, str) or not fact.predicate:
                raise LoweringError("relation fact has no predicate")
            if fact.predicate not in value.predicates:
                raise LoweringError("relation fact references an undeclared predicate")
            fact_predicates.add(fact.predicate)
            if fact.predicate == SENSE_ENTRY_PREDICATE:
                if subject.kind != "sense" or target.kind != "entry":
                    raise LoweringError("sense_of endpoints must be sense -> entry")
                if fact.properties_value is not None or fact.origin != "sense.entry" or fact.legacy_index is not None:
                    raise LoweringError("sense_of provenance/properties are malformed")
                if subject.ordinal in sense_of_subjects:
                    raise LoweringError("sense_of is repeated for one sense")
                sense_of_subjects.add(subject.ordinal)
            else:
                if subject.kind != "sense" or target.kind != "sense":
                    raise LoweringError("legacy relation endpoints must be sense -> sense")
                if fact.origin != "legacy.relation" or isinstance(fact.legacy_index, bool) or not isinstance(fact.legacy_index, int) or fact.legacy_index < 0:
                    raise LoweringError("legacy relation provenance is malformed")
                legacy_indices.append(fact.legacy_index)
                if fact.properties_value is None:
                    raise LoweringError("legacy relation is missing claim properties")
                fields = _product_fields(values, fact.properties_value, f"facts[{expected_ordinal}].properties_value")
                if tuple(name for name, _ in fields) != ("asserted_by", "certainty_token"):
                    raise LoweringError("legacy relation properties have an unexpected field")
                if any(values[member_id].kind != "symbol" for _, member_id in fields):
                    raise LoweringError("legacy relation properties must be symbol Values")
        else:
            raise LoweringError(f"unsupported neutral fact kind {fact.kind!r}")

    if sense_of_subjects != {record.ordinal for record in value.records if record.kind == "sense"}:
        raise LoweringError("sense_of facts do not cover exactly the sense records")
    if tuple(legacy_indices) != tuple(range(len(legacy_indices))):
        raise LoweringError("legacy relation rows are missing or out of order")
    if not fact_predicates.issubset(set(value.predicates)):
        raise LoweringError("fact predicate is absent from the predicate catalogue")


def lower_fixture_json(root: Mapping[str, object]) -> NeutralInput:
    """Lower one canonical ``bench4.oracle.Fixture.canonical()`` object.

    The result has one physical membership fact per non-null sense concept and
    one physical sense-to-entry fact per sense.  Legacy inverse arrays are
    checked before those facts are emitted.  Relation rows are never deduped.
    """

    if not isinstance(root, Mapping):
        raise LoweringError("fixture must be an object")
    _required(root, ("schema", "fixture", "seed", "entries", "senses", "concepts", "relations", "metadata"), "fixture")
    _reject_unknown(root, ("schema", "fixture", "seed", "entries", "senses", "concepts", "relations", "metadata"), "fixture")
    schema = _integer(root["schema"], "schema")
    if schema != SCHEMA_VERSION:
        raise LoweringError(f"unsupported fixture schema {schema}; expected {SCHEMA_VERSION}")
    book = _text(root["fixture"], "fixture")
    seed = _integer(root["seed"], "seed")
    if not book:
        raise LoweringError("fixture/book name cannot be empty")
    entries_json = _list(root["entries"], "entries")
    senses_json = _list(root["senses"], "senses")
    concepts_json = _list(root["concepts"], "concepts")
    relations_json = _list(root["relations"], "relations")
    metadata = _object(root["metadata"], "metadata")
    pool = _ValuePool()
    records: list[NeutralRecord] = []
    entry_rows: list[Mapping[str, object]] = []
    entry_ids: set[int] = set()
    entry_ordinals: dict[int, int] = {}

    for ordinal, raw in enumerate(entries_json):
        row = _object(raw, f"entries[{ordinal}]")
        _required(row, ("id", "key", "definition_hex", "language", "senses", "concepts", "homograph"), f"entries[{ordinal}]")
        _reject_unknown(row, ("id", "key", "definition_hex", "language", "senses", "concepts", "homograph"), f"entries[{ordinal}]")
        external_id = _integer(row["id"], f"entries[{ordinal}].id")
        if external_id in entry_ids:
            raise LoweringError(f"duplicate entry ID {external_id}")
        entry_ids.add(external_id)
        entry_ordinals[external_id] = ordinal
        entry_rows.append(row)
        definition = _bytes_hex(row["definition_hex"], f"entries[{ordinal}].definition_hex")
        homograph = _boolean(row["homograph"], f"entries[{ordinal}].homograph")
        definition_value = pool.add("string", definition)
        homograph_value = pool.add("boolean", homograph)
        features = pool.product((("definition", definition_value), ("homograph", homograph_value)))
        records.append(
            NeutralRecord(
                "entry",
                ordinal,
                external_id,
                _namespace(book, "entry"),
                language=_text(row["language"], f"entries[{ordinal}].language"),
                features_value=features,
            )
        )

    sense_rows: list[Mapping[str, object]] = []
    sense_ids: set[int] = set()
    sense_entry_ids: list[int] = []
    sense_concepts: list[int | None] = []
    for ordinal, raw in enumerate(senses_json):
        row = _object(raw, f"senses[{ordinal}]")
        _required(row, ("id", "entry", "language", "concept", "definition_hex"), f"senses[{ordinal}]")
        _reject_unknown(row, ("id", "entry", "language", "concept", "definition_hex"), f"senses[{ordinal}]")
        external_id = _integer(row["id"], f"senses[{ordinal}].id")
        if external_id in sense_ids:
            raise LoweringError(f"duplicate sense ID {external_id}")
        sense_ids.add(external_id)
        entry_id = _integer(row["entry"], f"senses[{ordinal}].entry")
        if entry_id not in entry_ids:
            raise LoweringError(f"senses[{ordinal}] references missing entry {entry_id}")
        concept_value = row["concept"]
        concept_id = None if concept_value is None else _integer(concept_value, f"senses[{ordinal}].concept")
        sense_rows.append(row)
        sense_entry_ids.append(entry_id)
        sense_concepts.append(concept_id)
        definition_value = pool.add("string", _bytes_hex(row["definition_hex"], f"senses[{ordinal}].definition_hex"))
        features = pool.product((("definition", definition_value),))
        records.append(
            NeutralRecord(
                "sense",
                ordinal,
                external_id,
                _namespace(book, "sense"),
                language=_text(row["language"], f"senses[{ordinal}].language"),
                features_value=features,
            )
        )

    concept_rows: list[Mapping[str, object]] = []
    concept_ids: set[int] = set()
    for ordinal, raw in enumerate(concepts_json):
        row = _object(raw, f"concepts[{ordinal}]")
        _required(row, ("id", "label", "members"), f"concepts[{ordinal}]")
        _reject_unknown(row, ("id", "label", "members"), f"concepts[{ordinal}]")
        external_id = _integer(row["id"], f"concepts[{ordinal}].id")
        if external_id in concept_ids:
            raise LoweringError(f"duplicate concept ID {external_id}")
        concept_ids.add(external_id)
        members = _list(row["members"], f"concepts[{ordinal}].members")
        member_ids = [_integer(member, f"concepts[{ordinal}].members[]") for member in members]
        if len(set(member_ids)) != len(member_ids):
            raise LoweringError(f"concept {external_id} repeats a physical member")
        for member_id in member_ids:
            if member_id not in sense_ids:
                raise LoweringError(f"concept {external_id} references missing sense {member_id}")
        concept_rows.append(row)
        records.append(
            NeutralRecord(
                "concept",
                ordinal,
                external_id,
                _namespace(book, "concept"),
                label=_text(row["label"], f"concepts[{ordinal}].label").encode("utf-8", "surrogatepass"),
            )
        )

    for ordinal, (sense_row, concept_id) in enumerate(zip(sense_rows, sense_concepts)):
        if concept_id is not None and concept_id not in concept_ids:
            raise LoweringError(f"senses[{ordinal}] references missing concept {concept_id}")

    # Inverse arrays are semantic input checks, not independent authorities.
    senses_by_entry: dict[int, list[int]] = {entry_id: [] for entry_id in entry_ids}
    concepts_by_entry: dict[int, list[int]] = {entry_id: [] for entry_id in entry_ids}
    for sense_row, entry_id, concept_id in zip(sense_rows, sense_entry_ids, sense_concepts):
        sense_id = _integer(sense_row["id"], "sense.id")
        senses_by_entry[entry_id].append(sense_id)
        if concept_id is not None:
            concepts_by_entry[entry_id].append(concept_id)
    for entry_row in entry_rows:
        entry_id = _integer(entry_row["id"], "entry.id")
        listed_senses = tuple(_integer(item, "entry.senses[]") for item in _list(entry_row["senses"], "entry.senses"))
        listed_concepts = tuple(_integer(item, "entry.concepts[]") for item in _list(entry_row["concepts"], "entry.concepts"))
        if listed_senses != tuple(senses_by_entry[entry_id]):
            raise LoweringError(f"entry {entry_id} inverse senses disagree with Sense.entry")
        if listed_concepts != tuple(concepts_by_entry[entry_id]):
            raise LoweringError(f"entry {entry_id} inverse concepts disagree with Sense.concept")
    senses_by_concept: dict[int, list[int]] = {concept_id: [] for concept_id in concept_ids}
    for sense_row, concept_id in zip(sense_rows, sense_concepts):
        if concept_id is not None:
            senses_by_concept[concept_id].append(_integer(sense_row["id"], "sense.id"))
    for concept_row in concept_rows:
        concept_id = _integer(concept_row["id"], "concept.id")
        listed_members = tuple(_integer(item, "concept.members[]") for item in _list(concept_row["members"], "concept.members"))
        if listed_members != tuple(senses_by_concept[concept_id]):
            raise LoweringError(f"concept {concept_id} inverse members disagree with Sense.concept")

    records_by_external = {(record.kind, record.external_id): record for record in records}
    keys = tuple(
        NeutralKey(
            ordinal,
            _text(row["key"], f"entries[{ordinal}].key").encode("utf-8", "surrogatepass"),
            entry_ordinals[_integer(row["id"], f"entries[{ordinal}].id")],
            _integer(row["id"], f"entries[{ordinal}].id"),
        )
        for ordinal, row in enumerate(entry_rows)
    )
    facts: list[NeutralFact] = []
    # The genuine normalized relationship is sense -> entry, one row per sense.
    for ordinal, (sense_id, entry_id) in enumerate(zip((int(row["id"]) for row in sense_rows), sense_entry_ids)):
        facts.append(
            NeutralFact(
                ordinal,
                "relation",
                _ref(records_by_external, "sense", sense_id, "sense.entry"),
                SENSE_ENTRY_PREDICATE,
                _ref(records_by_external, "entry", entry_id, "sense.entry"),
                origin="sense.entry",
            )
        )
    # Membership is physically represented once; Concept.members is its inverse.
    for sense_id, concept_id in zip((int(row["id"]) for row in sense_rows), sense_concepts):
        if concept_id is None:
            continue
        facts.append(
            NeutralFact(
                len(facts),
                "membership",
                _ref(records_by_external, "sense", sense_id, "sense.concept"),
                None,
                _ref(records_by_external, "concept", concept_id, "sense.concept"),
                origin="sense.concept",
            )
        )
    predicates: list[str] = [SENSE_ENTRY_PREDICATE]
    for ordinal, raw in enumerate(relations_json):
        row = _object(raw, f"relations[{ordinal}]")
        _required(row, ("source", "predicate", "target", "asserted_by", "certainty"), f"relations[{ordinal}]")
        _reject_unknown(row, ("source", "predicate", "target", "asserted_by", "certainty"), f"relations[{ordinal}]")
        source_id = _integer(row["source"], f"relations[{ordinal}].source")
        target_id = _integer(row["target"], f"relations[{ordinal}].target")
        predicate = _text(row["predicate"], f"relations[{ordinal}].predicate")
        asserted_by = _text(row["asserted_by"], f"relations[{ordinal}].asserted_by")
        certainty = _text(row["certainty"], f"relations[{ordinal}].certainty")
        if predicate not in predicates:
            predicates.append(predicate)
        asserted_value = pool.add("symbol", asserted_by)
        certainty_value = pool.add("symbol", certainty)
        properties = pool.product((("asserted_by", asserted_value), ("certainty_token", certainty_value)))
        facts.append(
            NeutralFact(
                len(facts),
                "relation",
                _ref(records_by_external, "sense", source_id, f"relations[{ordinal}].source"),
                predicate,
                _ref(records_by_external, "sense", target_id, f"relations[{ordinal}].target"),
                properties,
                origin="legacy.relation",
                legacy_index=ordinal,
            )
        )

    lowered = NeutralInput(
        schema,
        book,
        book,
        seed,
        deepcopy(dict(metadata)),
        tuple(pool.values),
        tuple(records),
        keys,
        tuple(facts),
        tuple(predicates),
    )
    validate_neutral(lowered)
    return lowered


__all__ = [
    "BOOK_ID_RULE",
    "LoweringError",
    "NeutralFact",
    "NeutralInput",
    "NeutralKey",
    "NeutralRecord",
    "NeutralRef",
    "NeutralValue",
    "SENSE_ENTRY_PREDICATE",
    "lower_fixture_json",
    "validate_neutral",
]
