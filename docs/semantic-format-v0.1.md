# Semantic snapshot format v0.3

This document specifies the current `LEXSEM\0\1` semantic snapshot emitted by
`src/semantic_format.zig`. It is a canonical reference format for the current
in-memory semantic model. It is deliberately uncompressed so that a future
columnar or bzip3 format can be checked against it for exact fidelity.

## Compatibility and integrity

The first eight bytes are the ASCII magic `LEXSEM`, followed by zero and one.
The version is major `0`, minor `3`. A reader requires exactly this version and
rejects unknown flags. v0.2 is intentionally rejected: it has no source or
anchor sections, so treating v0.2 bytes as v0.3 would silently change record
boundaries. A future compatible reader may provide an explicit v0.2 decoder,
but it must materialize unscoped records rather than guessing source identity.
All integers are unsigned or
signed two's-complement little-endian values. IDs are checked `u32` indices;
they are never native pointers or serialized Zig structs.

The fixed header is 112 bytes:

| Offset | Size | Meaning |
|---:|---:|---|
| 0 | 8 | magic `LEXSEM\0\1` |
| 8 | 2 | major |
| 10 | 2 | minor |
| 12 | 4 | flags, currently zero |
| 16 | 4 | header size, 112 |
| 20 | 8 | exact file length |
| 28 | 8 | FNV-1a-64 checksum of bytes after the header |
| 36 | 8 | namespace count |
| 44 | 8 | value count |
| 52 | 8 | entity count |
| 60 | 8 | assertion count |
| 68 | 8 | document-node count |
| 76 | 8 | root count |
| 84 | 8 | source count |
| 92 | 8 | entity-anchor count |
| 100 | 8 | assertion-anchor count |
| 108 | 4 | reserved, zero |

The body checksum detects accidental corruption. It is not a cryptographic
signature and does not authenticate an untrusted source.

## Lengths and limits

Every count and byte length in the body is a `u64`. A reader checks conversion
to `usize`, remaining input, and configured `DecodeOptions` limits before
allocation. The default limits cover total bytes, items, strings, sequences,
attributes, participants, evidence, children, and document depth. A limit
failure is `error.ResourceLimit`; truncated input is `error.Truncated`; a
declared length smaller than the supplied input is `error.InvalidLength`.
Unknown tags, invalid option markers, foreign IDs, invalid enum values, and
trailing bytes have distinct validation errors. A valid snapshot can contain
zero records in any section.

Semantic validation errors remain distinct as well: namespace/name, UTF-8,
URI, external-ID, cardinality/assertion, date/range, document-cycle,
multiple-parent, duplicate-root, and duplicate-child failures are reported by
their corresponding `semantic_format.Error` member rather than being folded
into a generic parse failure.

## Body order

The body contains nine length-prefixed sections in this order:

1. namespaces
2. sources
3. values
4. entities
5. document nodes
6. document roots
7. assertions
8. entity anchors
9. assertion anchors

Each section begins with a `u64` count that must equal its header count.
Records remain in their original array order. The decoder appends records in
that order and preserves every ID, including equal values that were present in
a manually assembled model.

## Primitive encodings

A byte string is `u64 length` followed by exactly that many bytes. Textual
fields are required to be valid UTF-8; `Value.bytes` and unresolved target
`bytes` are opaque and may contain arbitrary octets. An optional string is a
one-byte marker (`0` absent, `1` present) followed by a byte string when
present. A marker other than zero or one is invalid.

An optional ID uses the same marker followed by a checked `u32` ID. Enum tags
are the declaration order of the corresponding Zig enum. Tags are validated
before conversion.

Qualified names contain namespace ID, local string, and source prefix string.
The prefix is retained even though namespace URI and local name determine
semantic identity.

## Values

Each value begins with a tag:

| Tag | Variant and payload |
|---:|---|
| 0 | `text`: bytes, optional language, optional script, optional notation |
| 1 | `bytes`: opaque bytes |
| 2 | `boolean`: byte 0 or 1 |
| 3 | `signed_integer`: `i64` |
| 4 | `unsigned_integer`: `u64` |
| 5 | `decimal`: `i64 coefficient`, `i32 scale` |
| 6 | `uri`: UTF-8 URI |
| 7 | `qualified_name` |
| 8 | `entity`: entity ID |
| 9 | `sequence`: count followed by value IDs in order |
| 10 | `unknown`: optional reason |
| 11 | `absent`, no payload |
| 12 | `uncertain`: value ID and certainty enum |

`bytes`, `absent`, and `unknown` are distinct states. The decoder does not
reinterpret opaque bytes as text and does not collapse an explicit absent value
into an omitted field.

## Entities, documents, and assertions

An entity contains its kind enum, optional external ID, optional source ID, and
optional label value ID. A source record preserves an optional external ID and
base URI. Source records are never deduplicated: two records with the same
external ID have distinct source identity. A document node contains a
qualified name, optional source ID, optional parent ID,
attributes, and one ordered child list. Child tags are node, text value,
comment value, and processing instruction; the latter carries a UTF-8 target
and value ID. Mixed content order is therefore retained exactly. Roots are an
ordered list of document IDs.

An assertion contains predicate ID, ordered participants, ordered attributes,
ordered evidence, state, certainty, optional temporal metadata, and a graph
context. A participant contains its UTF-8 role and a target tag:

| Tag | Target and payload |
|---:|---|
| 0 | entity ID |
| 1 | value ID |
| 2 | unresolved target: opaque bytes, optional URI, optional label, status |
| 3 | statement/assertion ID |

Statement targets are backward-only. Assertion `i` may refer to assertion IDs
less than `i`; a forward or dangling ID is `error.InvalidStatementReference`.
This makes nested quoted statements deterministic and bounded while retaining
their identity as graph terms. Evidence contains optional source entity,
document node, quote value, provenance value, and ordered attributes.

The context is encoded after temporal metadata:

| Tag | Context and payload |
|---:|---|
| 0 | default context, with no payload |
| 1 | named context: entity ID |
| 2 | anonymous context: optional source discriminator, then `u64` source-local ID |

An anonymous source discriminator is either entity (tag 0) or document (tag 1).
Default, named, and anonymous contexts are distinct identities even when their
numeric IDs happen to match. Context is part of the assertion model and is
never inferred from generic attributes. Parallel assertions, retractions,
evidence occurrences, unresolved translations, and cycles in the semantic
graph remain separate records.

Each assertion may carry an explicit source ID. Entity-anchor records and
assertion-anchor records map an entity or assertion occurrence to a source ID
and document-node ID. An anchor may carry a span with a declared unit (`byte`,
`utf8_codepoint`, `utf16_code_unit`, or `grapheme`) and ordered half-open
`start`/`end` offsets. The decoder validates every source, node, entity, and
assertion reference and rejects reversed spans. Repeated anchors remain
repeated records; they are never inferred from document ancestry or merged by
equal payload.

Dates encode presence, signed year, optional month, and optional day.
Temporal precision is optional. Builder validation rejects impossible dates,
reverse ranges, invalid references, duplicate roots, document cycles, and
multiple parents.

## Determinism and future formats

Encoding does not sort or hash-cons records. Given the same model arrays and
bytes, it emits byte-identical output. A future compact format must preserve
this format's array order, occurrence identity, mixed-content order, explicit
absence, opaque bytes, unresolved targets, statement identity, graph context,
and evidence. It must use a new major version or an explicitly negotiated
section codec; readers must never silently treat an unknown encoding as this
reference format.
