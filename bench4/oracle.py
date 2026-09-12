#!/usr/bin/env python3
"""Independent semantic oracle and deterministic LEX4 benchmark workload.

The oracle is deliberately a small, boring Python model.  It does not import
the LEX4 implementation and it never answers a query by calling an adapter.
That separation is important: a native reader which returns the wrong answer
must stop a run, even when its timing looks attractive.

The public pieces are useful to both the benchmark driver and tests:

``make_fixture``
    Create one of the deterministic workload fixtures.
``Oracle``
    Compute canonical ranks, exact answers, prefix intervals/enumerations,
    renders, snippets, checksums, and graph/concept answers.
``workload``
    Produce the same semantic operations for every adapter.  Warmups and
    measured operations differ only in phase; the operation payloads are
    identical, so a reader cannot receive less work in the timed phase.

All key ordering is by UTF-8 bytes, matching the proposed automaton contract
and avoiding locale/Python-version ordering surprises.  IDs are intentionally
not contiguous in the rich fixture and duplicate keys are retained as separate
rows so homograph handling is observable.
"""

from __future__ import annotations

import bisect
import hashlib
import json
import os
from dataclasses import replace
from dataclasses import dataclass, field
from typing import Iterable, Iterator, Mapping, Sequence


SEED = 0x4C45583400040001
SCHEMA_VERSION = 1
FIXTURE_NAMES = ("flat", "repeated", "prose_heavy", "pathological_prefix", "rich")

_FNV_OFFSET = 0xCBF29CE484222325
_FNV_PRIME = 0x100000001B3


def _fnv_bytes(value: int, data: bytes) -> int:
    for byte in data:
        value = ((value ^ byte) * _FNV_PRIME) & 0xFFFFFFFFFFFFFFFF
    return value


def _fnv_u64(value: int, number: int) -> int:
    return _fnv_bytes(value, int(number).to_bytes(8, "little", signed=False))


def _key_bytes(value: str) -> bytes:
    return value.encode("utf-8", "surrogatepass")


@dataclass(frozen=True, slots=True)
class Entry:
    """One lexical entry in the benchmark projection."""

    ident: int
    key: str
    definition: bytes
    language: str = "en"
    sense_ids: tuple[int, ...] = ()
    concept_ids: tuple[int, ...] = ()
    homograph: bool = False

    def canonical(self) -> dict[str, object]:
        return {
            "id": self.ident,
            "key": self.key,
            "definition_hex": self.definition.hex(),
            "language": self.language,
            "senses": list(self.sense_ids),
            "concepts": list(self.concept_ids),
            "homograph": self.homograph,
        }


@dataclass(frozen=True, slots=True)
class Sense:
    ident: int
    entry_id: int
    language: str
    concept_id: int | None
    definition: bytes

    def canonical(self) -> dict[str, object]:
        return {
            "id": self.ident,
            "entry": self.entry_id,
            "language": self.language,
            "concept": self.concept_id,
            "definition_hex": self.definition.hex(),
        }


@dataclass(frozen=True, slots=True)
class Concept:
    ident: int
    label: str
    members: tuple[int, ...]

    def canonical(self) -> dict[str, object]:
        return {"id": self.ident, "label": self.label, "members": list(self.members)}


@dataclass(frozen=True, slots=True)
class Relation:
    source: int
    predicate: str
    target: int
    asserted_by: str = "fixture-source"
    certainty: str = "asserted"

    def canonical(self) -> dict[str, object]:
        return {
            "source": self.source,
            "predicate": self.predicate,
            "target": self.target,
            "asserted_by": self.asserted_by,
            "certainty": self.certainty,
        }


@dataclass(frozen=True, slots=True)
class Fixture:
    """Immutable fixture input shared by the oracle and all adapters."""

    name: str
    entries: tuple[Entry, ...]
    senses: tuple[Sense, ...] = ()
    concepts: tuple[Concept, ...] = ()
    relations: tuple[Relation, ...] = ()
    seed: int = SEED
    metadata: Mapping[str, object] = field(default_factory=dict)

    def canonical(self) -> dict[str, object]:
        return {
            "schema": SCHEMA_VERSION,
            "fixture": self.name,
            "seed": self.seed,
            "entries": [entry.canonical() for entry in self.entries],
            "senses": [sense.canonical() for sense in self.senses],
            "concepts": [concept.canonical() for concept in self.concepts],
            "relations": [relation.canonical() for relation in self.relations],
            "metadata": dict(sorted(self.metadata.items())),
        }

    def canonical_bytes(self) -> bytes:
        return (json.dumps(self.canonical(), ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")

    def semantic_digest(self) -> str:
        return hashlib.sha256(self.canonical_bytes()).hexdigest()

    def prose_bytes(self) -> int:
        return sum(len(entry.definition) for entry in self.entries)

    def by_id(self) -> dict[int, Entry]:
        return {entry.ident: entry for entry in self.entries}


def _definition(index: int, *, variant: int = 0) -> bytes:
    templates = (
        "A deterministic lexical definition with usage, evidence, and a stable repeated phrase.",
        "A second wording records a distinct source occurrence while preserving semantic order.",
        "The fixture keeps prose ordinary rather than synthetic; snippets must return its prefix.",
        "A multilingual note mentions café, 東京, and Μῆνιν to exercise UTF-8 payloads.",
    )
    text = f"{templates[variant % len(templates)]} record {index} seed {SEED:016x}."
    return text.encode("utf-8")


def _flat_entries(records: int, *, pathological: bool = False, repeated: bool = False, prose_heavy: bool = False) -> tuple[Entry, ...]:
    rows: list[Entry] = []
    for i in range(records):
        if pathological and i < max(2, records * 3 // 4):
            key = f"pathological-prefix-{i:08d}"
        elif i % 37 == 0:
            key = f"entry-{i:08d}-e\u0301-🧪"
        elif i % 29 == 0:
            key = f"entry-{i:08d}-é-東京"
        elif i % 17 == 0:
            key = f"entry-{i:08d}-special.%_!?"
        else:
            key = f"entry-{i:08d}"
        content = _definition(i, variant=i if not repeated else 0)
        if prose_heavy:
            content = (b"A repeated prose sentence for grammar measurements. " * 24) + f"record {i}.".encode()
        # A duplicate key is a homograph, not a lost row.  Keep the IDs apart.
        rows.append(Entry(i * 2 + 1, key, content, homograph=(i % 31 == 0)))
        if i % 41 == 0 and i + 1 < records:
            rows.append(Entry(i * 2 + 2, key, _definition(i + records, variant=1), homograph=True))
    return tuple(rows)


def _rich_fixture(records: int) -> Fixture:
    # Keep enough rows for prefix classes while keeping the graph compact.  The
    # IDs are deliberately sparse; no adapter may infer rank == source ID.
    base = list(_flat_entries(max(records, 24)))
    languages = ("en", "fr", "de", "ja")
    senses: list[Sense] = []
    concepts: list[Concept] = []
    concept_members: dict[int, list[int]] = {}
    for ordinal, entry in enumerate(base):
        language = languages[ordinal % len(languages)]
        concept_id = 500 + ordinal // 3
        sense_id = 10_000 + ordinal * 7
        sense = Sense(sense_id, entry.ident, language, concept_id, entry.definition)
        senses.append(sense)
        concept_members.setdefault(concept_id, []).append(sense_id)
    for concept_id, members in sorted(concept_members.items()):
        concepts.append(Concept(concept_id, f"concept-{concept_id}", tuple(members)))
    entry_by_id = {entry.ident: entry for entry in base}
    enriched: list[Entry] = []
    sense_by_entry = {sense.entry_id: sense for sense in senses}
    for entry in base:
        sense = sense_by_entry[entry.ident]
        enriched.append(
            Entry(
                entry.ident,
                entry.key,
                entry.definition,
                language=sense.language,
                sense_ids=(sense.ident,),
                concept_ids=(sense.concept_id,) if sense.concept_id is not None else (),
                homograph=entry.homograph,
            )
        )
    relations: list[Relation] = []
    for left, right in zip(senses, senses[1:]):
        if left.language == right.language:
            relations.append(Relation(left.ident, "see_also", right.ident))
        elif left.concept_id != right.concept_id:
            relations.append(Relation(left.ident, "translation", right.ident, certainty="candidate"))
    relations.extend(
        (
            Relation(senses[0].ident, "hypernym", senses[3].ident),
            Relation(senses[3].ident, "hyponym", senses[0].ident),
            Relation(senses[2].ident, "near_synonym", senses[5].ident, certainty="disputed"),
        )
    )
    return Fixture(
        "rich",
        tuple(enriched),
        tuple(senses),
        tuple(concepts),
        tuple(relations),
        metadata={
            "graph": "concept-memberships-and-asserted-relations",
            "languages": list(languages),
            "source": "benchmark-rich-fixture",
            "relation_algebra": {
                "hypernym": {"inverse": "hyponym", "transitive": True},
                "hyponym": {"inverse": "hypernym", "transitive": True},
                "see_also": {"symmetric": True},
                "translation": {"symmetric": False, "membership_projection": True},
            },
        },
    )


def make_fixture(name: str, records: int = 64) -> Fixture:
    """Build a deterministic fixture by name.

    ``records`` counts the base generated records.  Duplicate homographs may
    make the resulting entry count larger; that fact is part of the fixture
    metadata and is reported rather than silently normalised away.
    """

    if records < 8:
        raise ValueError("records must be at least 8 so every prefix class exists")
    if name not in FIXTURE_NAMES:
        raise ValueError(f"unknown fixture {name!r}; expected one of {FIXTURE_NAMES}")
    if name == "flat":
        entries = _flat_entries(records)
        return Fixture(name, entries, metadata={"projection": "entry/key/definition", "base_records": records})
    if name == "repeated":
        entries = _flat_entries(records, repeated=True)
        return Fixture(name, entries, metadata={"projection": "entry/key/definition", "base_records": records, "duplicate_prose": True})
    if name == "prose_heavy":
        entries = _flat_entries(records, prose_heavy=True)
        return Fixture(name, entries, metadata={"projection": "entry/key/definition", "base_records": records, "long_repeated_prose": True})
    if name == "pathological_prefix":
        entries = _flat_entries(records, pathological=True)
        return Fixture(name, entries, metadata={"projection": "entry/key/definition", "base_records": records, "pathological_prefix": "pathological-prefix-"})
    return _rich_fixture(records)


class Oracle:
    """Independent answers for all benchmark operations."""

    def __init__(self, fixture: Fixture):
        self.fixture = fixture
        self._by_id = fixture.by_id()
        self._ranked = tuple(sorted(fixture.entries, key=lambda entry: (_key_bytes(entry.key), entry.ident)))
        self._keys = tuple(_key_bytes(entry.key) for entry in self._ranked)
        self._senses = {sense.ident: sense for sense in fixture.senses}
        self._concepts = {concept.ident: concept for concept in fixture.concepts}
        self._relations = tuple(fixture.relations)

    @property
    def cardinality(self) -> int:
        return len(self._ranked)

    @property
    def ranked_entries(self) -> tuple[Entry, ...]:
        return self._ranked

    def exact_ids(self, key: str) -> list[int]:
        needle = _key_bytes(key)
        return [entry.ident for entry in self._ranked if _key_bytes(entry.key) == needle]

    @staticmethod
    def _prefix_upper(prefix: bytes) -> bytes | None:
        if not prefix:
            return None
        value = bytearray(prefix)
        index = len(value) - 1
        while index >= 0 and value[index] == 0xFF:
            index -= 1
        if index < 0:
            return None
        value[index] += 1
        del value[index + 1 :]
        return bytes(value)

    def prefix_interval(self, prefix: str) -> tuple[int, int]:
        needle = _key_bytes(prefix)
        lo = bisect.bisect_left(self._keys, needle)
        upper = self._prefix_upper(needle)
        hi = len(self._keys) if upper is None else bisect.bisect_left(self._keys, upper)
        # A byte-lexicographic upper bound is exact for UTF-8 prefixes.  Keep a
        # defensive check here so a future key normalisation cannot make the
        # oracle silently return a non-prefix interval.
        while lo < hi and not self._ranked[lo].key.startswith(prefix):
            lo += 1
        while hi > lo and not self._ranked[hi - 1].key.startswith(prefix):
            hi -= 1
        return lo, hi

    def prefix_ids(self, prefix: str) -> list[int]:
        lo, hi = self.prefix_interval(prefix)
        return [entry.ident for entry in self._ranked[lo:hi]]

    def select(self, rank: int) -> Entry:
        if rank < 0 or rank >= len(self._ranked):
            raise IndexError(f"rank {rank} outside 0..{len(self._ranked) - 1}")
        return self._ranked[rank]

    def render(self, ident: int) -> bytes:
        try:
            return self._by_id[ident].definition
        except KeyError as exc:
            raise KeyError(f"unknown entry ID {ident}") from exc

    def snippet(self, ident: int, limit: int) -> bytes:
        if limit < 0:
            raise ValueError("snippet limit cannot be negative")
        return self.render(ident)[:limit]

    def structure_checksum(self) -> str:
        payload = {
            "ranked": [(entry.ident, entry.key) for entry in self._ranked],
            "senses": [sense.canonical() for sense in sorted(self._senses.values(), key=lambda item: item.ident)],
            "concepts": [concept.canonical() for concept in sorted(self._concepts.values(), key=lambda item: item.ident)],
            "relations": [relation.canonical() for relation in sorted(self._relations, key=lambda item: (item.source, item.predicate, item.target))],
        }
        encoded = (json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        return hashlib.sha256(encoded).hexdigest()

    def query_checksum(self, operations: Iterable["Operation"] | None = None) -> str:
        # The checksum is a canonical digest of the complete normalized query
        # responses.  The adapter reimplements this traversal independently;
        # it must not call this method or share answer objects with the oracle.
        values: list[object] = []
        for operation in operations if operations is not None else workload(self.fixture, 32):
            if operation.op == "exact":
                result: object = (operation.op, operation.key, self.exact_ids(operation.key))
            elif operation.op in ("prefix_interval", "prefix_enumerate"):
                lo, hi = self.prefix_interval(operation.key)
                result = (operation.op, operation.key, (lo, hi))
                if operation.op == "prefix_enumerate":
                    result = (operation.op, operation.key, (lo, hi), self.prefix_ids(operation.key))
            elif operation.op == "select":
                entry = self.select(operation.ident or 0)
                result = (operation.op, {"op": "select", "id": entry.ident, "key": entry.key, "rank": operation.ident})
            elif operation.op in ("render", "snippet"):
                value = self.render(operation.ident or 0) if operation.op == "render" else self.snippet(operation.ident or 0, operation.limit or 0)
                result = (operation.op, operation.ident, operation.limit, value.hex())
            elif operation.op == "concept_members":
                result = (operation.op, operation.ident, list(self.concept_members(operation.ident or 0)))
            elif operation.op == "translations":
                result = (operation.op, operation.ident, operation.language, list(self.translations(operation.ident or 0, operation.language or "")))
            elif operation.op == "relations":
                result = (operation.op, operation.ident, operation.predicate, [relation.canonical() for relation in self.relations(operation.ident or 0, operation.predicate or "")])
            else:
                raise ValueError(f"unknown oracle operation {operation.op!r}")
            values.append(result)
        encoded = (json.dumps(values, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        return hashlib.sha256(encoded).hexdigest()

    def concept_members(self, concept_id: int) -> tuple[int, ...]:
        concept = self._concepts.get(concept_id)
        if concept is None:
            return ()
        return concept.members

    def translations(self, sense_id: int, language: str) -> tuple[int, ...]:
        sense = self._senses.get(sense_id)
        if sense is None or sense.concept_id is None:
            return ()
        members = self.concept_members(sense.concept_id)
        return tuple(
            member
            for member in members
            if member != sense_id and (not language or self._senses.get(member, Sense(0, 0, "", None, b"")).language == language)
        )

    def relations(self, source: int, predicate: str = "") -> tuple[Relation, ...]:
        return tuple(
            relation
            for relation in self._relations
            if relation.source == source and (not predicate or relation.predicate == predicate)
        )


@dataclass(frozen=True, slots=True)
class Operation:
    op: str
    key: str = ""
    ident: int | None = None
    limit: int | None = None
    language: str | None = None
    predicate: str | None = None
    category: str = ""
    # ``sample`` is a deterministic request nonce.  It is deliberately not
    # part of semantic answers, but is put on the native wire so a reader
    # cannot mistake repeated benchmark samples for one cacheable request.
    # The nonce is generated by ``workload`` and is never an oracle answer.
    sample: int = 0

    def wire(self) -> dict[str, object]:
        value: dict[str, object] = {"op": self.op}
        # Empty exact/prefix inputs are real workload cases, not an omitted
        # field.  Preserve the key field for those operations so a native
        # reader cannot confuse ``key=""`` with an invalid/missing query.
        if self.op in ("exact", "prefix_interval", "prefix_enumerate"):
            value["key"] = self.key
        if self.ident is not None:
            value["id"] = self.ident
        if self.limit is not None:
            value["limit"] = self.limit
        if self.language is not None:
            value["language"] = self.language
        if self.predicate is not None:
            value["predicate"] = self.predicate
        if self.category:
            value["category"] = self.category
        value["sample"] = self.sample
        return value


def workload(fixture: Fixture, repetitions: int = 64) -> tuple[Operation, ...]:
    """Return a deterministic, class-balanced semantic workload.

    The first cycle explicitly includes every required cardinality class.  A
    second cycle is generated for larger runs without changing its operation
    shapes.  Every adapter therefore performs the same number of interval,
    enumeration, rendering, and graph operations.
    """

    oracle = Oracle(fixture)
    entries = oracle.ranked_entries
    if not entries:
        raise ValueError("fixture must contain at least one entry")
    keys = [entry.key for entry in entries]
    duplicate_key = next((entry.key for entry in entries if len(oracle.exact_ids(entry.key)) > 1), keys[0])
    one_key = next((entry.key for entry in entries if len(oracle.prefix_ids(entry.key)) == 1), keys[-1])
    many_key = next((entry.key for entry in entries if 1 < len(oracle.prefix_ids(entry.key)) < len(entries)), keys[0][:3])
    pathological_key = "pathological-prefix-" if fixture.name == "pathological_prefix" else ""
    probes: list[Operation] = [
        Operation("exact", key=duplicate_key, category="hit_duplicate"),
        Operation("exact", key="absent-ß-東京", category="miss"),
        Operation("exact", key="", category="miss_empty"),
        Operation("prefix_interval", key="", category="many_empty"),
        Operation("prefix_enumerate", key="", category="many_empty"),
        Operation("prefix_interval", key="zzzz-no-such-prefix", category="zero"),
        Operation("prefix_enumerate", key="zzzz-no-such-prefix", category="zero"),
        Operation("prefix_interval", key=one_key, category="one"),
        Operation("prefix_enumerate", key=one_key, category="one"),
        Operation("prefix_interval", key=many_key[: max(1, len(many_key) // 2)], category="many"),
        Operation("prefix_enumerate", key=many_key[: max(1, len(many_key) // 2)], category="many"),
        *(() if fixture.name != "pathological_prefix" else (
            Operation("prefix_interval", key=pathological_key, category="pathological"),
            Operation("prefix_enumerate", key=pathological_key, category="pathological"),
        )),
    ]
    for index in range(min(4, len(entries))):
        entry = entries[index]
        probes.extend(
            (
                Operation("select", ident=index, category="select"),
                Operation("render", ident=entry.ident, category="render"),
                Operation("snippet", ident=entry.ident, limit=17 + index, category="snippet"),
            )
        )
    if fixture.senses:
        first_sense = fixture.senses[0]
        probes.extend(
            (
                Operation("concept_members", ident=first_sense.concept_id or 0, category="concept"),
                Operation("translations", ident=first_sense.ident, language="fr", category="translation"),
                Operation("relations", ident=first_sense.ident, predicate="", category="relations"),
            )
        )
    if repetitions <= 0:
        return ()
    # A repetition count smaller than the number of probes must not silently
    # drop whole operation classes.  The first schedule is therefore a full
    # stratified pass over every probe, and additional repetitions are added
    # as complete passes plus a deterministic prefix.  This is intentionally
    # not ``probes[i % len(probes)]``: each returned operation receives a
    # unique sample nonce and the sample count for every class is explicit.
    count = max(repetitions, len(probes))
    cycles, remainder = divmod(count, len(probes))
    # Later passes deliberately rotate semantic inputs.  A reader may cache
    # its decoded index as part of normal operation, but it cannot use the
    # first pass (or a preflight schedule) as a table of all timed answers.
    duplicate_keys = [
        entry.key for entry in entries if len(oracle.exact_ids(entry.key)) > 1
    ] or [keys[0]]
    one_keys = [entry.key for entry in entries if len(oracle.prefix_ids(entry.key)) == 1] or [keys[-1]]
    many_keys = [
        entry.key[: max(1, len(entry.key) // 3)]
        for entry in entries
        if 1 < len(oracle.prefix_ids(entry.key[: max(1, len(entry.key) // 3)])) < len(entries)
    ] or [keys[0][:1]]
    graph_senses = list(fixture.senses)
    graph_concepts = list(fixture.concepts)

    def variant(operation: Operation, cycle: int) -> Operation:
        if cycle == 0:
            return operation
        if operation.op == "exact":
            if operation.category == "hit_duplicate":
                return replace(operation, key=duplicate_keys[cycle % len(duplicate_keys)])
            if operation.category == "miss":
                return replace(operation, key=f"absent-ß-東京-{cycle}")
            return operation
        if operation.op in ("prefix_interval", "prefix_enumerate"):
            if operation.category == "zero":
                return replace(operation, key=f"zzzz-no-such-prefix-{cycle}")
            if operation.category == "one":
                return replace(operation, key=one_keys[cycle % len(one_keys)])
            if operation.category == "many":
                return replace(operation, key=many_keys[cycle % len(many_keys)])
            if operation.category == "many_empty":
                return replace(operation, key=keys[cycle % len(keys)][:1])
            return operation
        if operation.op == "select":
            return replace(operation, ident=(int(operation.ident or 0) + cycle * 7) % len(entries))
        if operation.op in ("render", "snippet"):
            entry = entries[(cycle * 7 + int(operation.ident or 0)) % len(entries)]
            return replace(operation, ident=entry.ident, limit=(operation.limit or 0) + cycle if operation.op == "snippet" else operation.limit)
        if graph_senses and operation.op == "concept_members":
            return replace(operation, ident=graph_concepts[cycle % len(graph_concepts)].ident)
        if graph_senses and operation.op == "translations":
            sense = graph_senses[cycle % len(graph_senses)]
            return replace(operation, ident=sense.ident, language=("", "fr", "de", "ja")[cycle % 4])
        if graph_senses and operation.op == "relations":
            sense = graph_senses[cycle % len(graph_senses)]
            return replace(operation, ident=sense.ident, predicate=("", "translation", "hypernym", "near_synonym")[cycle % 4])
        return operation

    scheduled: list[Operation] = []
    for cycle in range(cycles):
        scheduled.extend(variant(operation, cycle) for operation in probes)
    scheduled.extend(variant(operation, cycles) for operation in probes[:remainder])
    return tuple(replace(operation, sample=index) for index, operation in enumerate(scheduled))


def expected(oracle: Oracle, operation: Operation) -> dict[str, object]:
    """Return a canonical expected response for one operation."""

    if operation.op == "exact":
        values = oracle.exact_ids(operation.key)
        return {"op": operation.op, "ids": values, "cardinality": len(values)}
    if operation.op == "prefix_interval":
        lo, hi = oracle.prefix_interval(operation.key)
        return {"op": operation.op, "lo": lo, "hi": hi, "cardinality": hi - lo}
    if operation.op == "prefix_enumerate":
        values = oracle.prefix_ids(operation.key)
        lo, hi = oracle.prefix_interval(operation.key)
        return {"op": operation.op, "ids": values, "lo": lo, "hi": hi, "cardinality": len(values)}
    if operation.op == "select":
        entry = oracle.select(operation.ident or 0)
        return {"op": operation.op, "id": entry.ident, "key": entry.key, "rank": operation.ident}
    if operation.op == "render":
        value = oracle.render(operation.ident or 0)
        return {"op": operation.op, "id": operation.ident, "bytes_hex": value.hex(), "bytes": len(value)}
    if operation.op == "snippet":
        value = oracle.snippet(operation.ident or 0, operation.limit or 0)
        return {"op": operation.op, "id": operation.ident, "limit": operation.limit, "bytes_hex": value.hex(), "bytes": len(value)}
    if operation.op == "concept_members":
        values = list(oracle.concept_members(operation.ident or 0))
        return {"op": operation.op, "id": operation.ident, "members": values, "cardinality": len(values)}
    if operation.op == "translations":
        values = list(oracle.translations(operation.ident or 0, operation.language or ""))
        return {"op": operation.op, "id": operation.ident, "language": operation.language, "members": values, "cardinality": len(values)}
    if operation.op == "relations":
        relations = [relation.canonical() for relation in oracle.relations(operation.ident or 0, operation.predicate or "")]
        return {"op": operation.op, "id": operation.ident, "relations": relations, "cardinality": len(relations)}
    raise ValueError(f"unknown operation {operation.op!r}")


def write_tsv(fixture: Fixture, path: str | bytes | os.PathLike[str]) -> None:
    """Write the common key/definition projection consumed by adapters."""

    from pathlib import Path

    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("wb") as stream:
        stream.write(f"# fixture={fixture.name}\n".encode("utf-8"))
        stream.write(f"# seed={fixture.seed:016x}\n".encode("ascii"))
        for entry in fixture.entries:
            # TSV uses escaped fields so arbitrary tabs/newlines cannot alter
            # row boundaries.  The adapter loader is required to unescape.
            key = entry.key.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")
            definition = entry.definition.replace(b"\\", b"\\\\").replace(b"\t", b"\\t").replace(b"\n", b"\\n")
            stream.write(str(entry.ident).encode("ascii") + b"\t" + key.encode("utf-8") + b"\t" + definition + b"\n")


def write_fixture_json(fixture: Fixture, path: str | bytes | os.PathLike[str]) -> None:
    """Write canonical fixture input, including rich graph fields.

    This is source data for a native compiler, not a table of expected query
    answers. Keeping it separate from the TSV projection prevents a graph
    reader from silently receiving only flat key/definition semantics.
    """

    from pathlib import Path

    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(fixture.canonical_bytes())


__all__ = [
    "Concept",
    "Entry",
    "Fixture",
    "FIXTURE_NAMES",
    "Operation",
    "Oracle",
    "Relation",
    "SEED",
    "Sense",
    "expected",
    "make_fixture",
    "workload",
    "write_fixture_json",
    "write_tsv",
]
