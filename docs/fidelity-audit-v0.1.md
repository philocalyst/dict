# Semantic fidelity audit v0.1

This audit is a review of the current `src/semantic.zig` model and
`src/semantic_format.zig` reference encoding against the lexical and graph
structures the project promises to preserve. It is deliberately a capability
inventory, not a claim that the implementation already covers the whole plan.

The comparison uses the TEI P5 dictionary module and the TEI Lex-0 project,
the OntoLex-Lemon core and lexicography module, and the RDF 1.2 abstract data
model. TEI Lex-0 is a community specification and recommendation for
machine-readable dictionaries; its repository and generated schema are the
normative starting points for a Lex-0 importer. The current TEI Guidelines
remain the broader source-structure reference.

Primary references:

- [TEI P5, chapter 9: Dictionaries](https://tei-c.org/Vault/P5/2.0.0/doc/tei-p5-doc/en/html/DI.html)
- [TEI P5 `<sense>`](https://tei-c.org/release/doc/tei-p5-doc/en/html/ref-sense.html)
- [TEI P5 `<form>`](https://tei-c.org/release/doc/tei-p5-doc/en/html/ref-form.html)
- [TEI P5 `<entryFree>`](https://tei-c.org/release/doc/tei-p5-doc/en/html/ref-entryFree.html)
- [TEI P5 responsibility and certainty attributes](https://tei-c.org/release/doc/tei-p5-doc/en/html/ref-att.global.responsibility.html)
- [TEI Lex-0 repository and ODD](https://github.com/BCDH/tei-lex-0)
- [OntoLex-Lemon core model](https://ontolex.github.io/ontolex/specification.html)
- [OntoLex lexicography module](https://ontolex.github.io/lexicog/)
- [RDF 1.2 Concepts and Abstract Syntax](https://www.w3.org/TR/rdf12-concepts/)
- [BCP 47 language tags, RFC 5646](https://www.rfc-editor.org/rfc/rfc5646.html)
- [Unicode normalization, UAX #15](https://unicode.org/reports/tr15/)
- [Unicode text segmentation, UAX #29](https://unicode.org/reports/tr29/)

## Reading the status labels

`Implemented` means the field or invariant exists in the in-memory model and
is represented by the v0.1 semantic encoding. `Partial` means the shape can
carry some source data, but a required distinction, scope, or standard
semantics is absent. `Missing` means the current model has no faithful native
representation; placing the data in an opaque string or generic attribute
would be a lossy workaround. `Planned` refers to `plan.md` only and must not
be read as existing behavior.

The format round-trip claim is narrower than source round-trip fidelity. The
encoder preserves a valid `semantic.Model` exactly in its supported fields,
including array order and duplicate values imported with `addValueExact`.
It cannot restore source XML serialization choices, source profile metadata,
or distinctions that the model never received.

## Current representation

The model has six useful identity domains:

| Domain | Current representation | Fidelity consequence |
| --- | --- | --- |
| Immutable value | `ValueId` into typed `Value` array | Exact equal values can be shared; source occurrences must remain outside the value table. |
| Lexical or structural entity | `EntityId` plus `EntityKind`, optional external ID, label, and source scope | Entry, lexeme, sense, form, pronunciation, source, and other classes have an identity slot; most class-specific fields are not native yet. |
| Relation occurrence | `AssertionId` into ordered participants and attributes | Parallel, contradictory, inferred, retracted, evidence-bearing, and statement-quoting assertions can remain distinct. |
| Source document node | `DocumentNodeId` with qualified name, parent, ordered children, and attributes | Generic TEI and extension elements can be retained as a tree with mixed content. |
| Namespace-qualified name | namespace URI/prefix plus local name | The expanded name and observed prefix survive; declaration scope and XML base do not. |
| Source root | Ordered `roots` array plus source-scoped document nodes | Multiple source documents/roots can be retained with duplicate-safe source identities, base URIs, and explicit anchors. Assertion graph context is represented separately as default, named, or source-scoped anonymous. |

`semantic_format` encodes the namespaces, sources, values, entities,
documents, roots, assertions, and typed anchor arrays in deterministic order with checked
IDs, lengths, tags, UTF-8 validation, URI checks, checksums, and decode
budgets. The current wire version is major `0`, minor `3`, magic
`LEXSEM\0\1`; v0.2 is explicitly rejected rather than reinterpreted. It is a reference encoding, not yet the compact snapshot format
described in the plan.

## Coverage matrix

| Area | Standard or source requirement | Current capability | Status | Required acceptance evidence |
| --- | --- | --- | --- | --- |
| Entry identity | TEI entry is a source article; OntoLex distinguishes a lexicographic `Entry` from a lexical entry | `EntityKind.entry` and generic document nodes exist, with optional external ID/label | Partial | Two source entries describing the same lexeme remain separate entities and export with their source IDs and order. |
| Lexeme identity | OntoLex lexical entry can be a word, multiword expression, or affix and can have its own senses/forms | `lexeme` entity kind and generic assertions can point to it | Partial | A fixture round-trip preserves lexical-entry identity, entry-to-lexeme alignment, and ownership without relying on string equality. |
| Sense identity and nesting | TEI senses may nest to arbitrary depth and group definitions, examples, and translations | `sense` kind, document nesting, and n-ary assertions are available; no typed sense-owner/parent field | Partial | Nested sub-senses, sense order, scope of each definition/example, and a sense shared by multiple views survive a semantic round trip. |
| Written/spoken forms | TEI `<form>` groups orthography, pronunciation, hyphenation, syllabification, and variants; OntoLex `Form` has one or more written representations | `form` and `pronunciation` kinds plus `Text` values; no native form-to-entry, representation, or pronunciation feature fields | Partial | Orthographic, IPA, hyphenated, syllabified, and variant representations retain their occurrence identity, notation, language, and owner. |
| Grammar/features | TEI `gramGrp` may carry POS, gender, number, case, tense, mood, inflection class, and subcategorization; the plan requires feature bundles and alternatives | `feature_bundle` kind and generic attributes can carry labels, but there is no feature schema, negation, alternative, scope, or typed value constraint | Partial | Feature values, alternatives, negated features, inherited defaults, and exceptions compare equal to an unfactored reference model. |
| Definitions and examples | TEI definitions/examples can contain rich mixed content and nested references | Text values and generic document nodes preserve child order; no typed owner/view links are required | Partial | A definition with inline markup, cross-reference, and repeated text remains attached to the correct sense and source span. |
| Unstructured entries | TEI `<entryFree>` admits dictionary elements in any combination | Generic names, attributes, and ordered children can represent the tree | Implemented for tree shape; partial for import semantics | Every retained node/attribute/child is present, including unknown namespaced elements; typed projection records its source node. |
| Etymology | TEI etymology can contain forms, languages, dates, citations, and nested structure | `etymology_event` plus arbitrary role-labelled assertion participants and temporal metadata | Partial | Multi-source etymology events preserve participant roles, order, language, dates, evidence, and unresolved targets. |
| Translation | OntoLex/vartrans and TEI translations are scoped relations with language and lexical/usage qualifiers | Assertions support role-labelled targets, evidence, state, certainty, and arbitrary attributes | Partial | A translation attached to one sense, with target language, variant, evidence, and unresolved lexicalization, never leaks to another sense. |
| Related entries | TEI `re`, `xr`, `oRef`, and `pRef` retain cross-reference occurrence and display context | Assertions and unresolved targets can hold relation and target text | Partial | A cross-reference preserves source display text, target URI/ID, unresolved status, source node, order, and relation type. |
| Generic relation shape | RDF triples; n-ary relations need a relation occurrence/resource to attach qualifiers | First-class `Assertion` with ordered role-labelled participants, predicate, attrs, evidence, state, certainty, and temporal interval | Implemented for n-ary occurrence relations | Differential tests compare every assertion tuple including multiplicity, role order, qualifiers, and assertion identity. |
| Relation cycles and parallel claims | RDF graphs permit cycles; lexical graphs commonly contain parallel claims | Entity IDs and assertion IDs are references; no recursive expansion is performed | Implemented | Self edges, cycles, duplicate endpoints with different evidence, and contradictory claims round-trip and query distinctly. |
| Assertion state | Source/editorial workflows need asserted, inferred, retracted, disputed claims | `AssertionState` and `Certainty` are explicit fields | Implemented, coarse | A fixture proves state and certainty are queryable per assertion and never inferred from target text. |
| Quoted/annotated statements | RDF 1.2 adds quoted triples as RDF terms; annotations may target a statement itself | `Target.statement` refers to an earlier `AssertionId`; nested quoted statements retain identity and order | Implemented for backward-only statement terms; partial for arbitrary cyclic RDF triple terms | A graph fixture preserves a statement used as another statement's subject/object without converting it to a lossy string. |
| RDF terms and datasets | RDF has IRIs, blank nodes, literals, triple terms, default/named graphs, datatypes and language-tagged strings | URI, QName, entity, text, bytes, scalar values, assertions, and explicit `GraphContext` exist; context supports default/named/entity or document-scoped anonymous identity | Partial | RDF fixture import/export is isomorphic, preserving graph names, blank-node identity, literal datatype, language tag, direction, and quoted triples. |
| Evidence and provenance | TEI `@source`, `@resp`, `@cert`, `@change`, and RDF statement metadata may refer to agents, sources, and exact locations | Evidence has source entity/document node; v0.3 adds source identity, assertion ownership, and typed assertion anchors | Partial | Source agent, responsibility, change event, confidence, quote, and exact source span remain attached to the same assertion/occurrence. |
| Source anchors | TEI linking attributes (`xml:id`, `@corresp`, `@synch`, `@sameAs`, `@next`, `@prev`) identify and connect source occurrences | v0.3 has non-deduplicated source records, source-scoped entity/assertion ownership, and typed node/span mappings | Implemented for typed source scope/anchors; partial for import projection | Anchor targets and source spans resolve with source-scoped IDs while preserving unresolved links and original occurrence order. |
| Document mixed content | TEI allows text and arbitrary children in source order; this is critical for inline markup | `DocumentChild` retains node, text, comment, and processing-instruction order | Implemented for represented child kinds | Mixed-content fixtures compare child tag and value sequence exactly, including empty and repeated text nodes. |
| Document attributes | TEI global/lexicographic/typed attributes carry language, source, linking, rendering, normalization, and editorial information | Ordered generic `Attribute` arrays with qualified names and `ValueId` | Implemented as generic data; partial as semantics | Every attribute is preserved by expanded name, prefix, value identity, and order; recognized profiles map selected attributes without dropping the generic copy. |
| Source lexical serialization | Semantic preservation differs from byte-exact XML preservation: quoting, entity spelling, whitespace tokens, and attribute order may matter | Text and attribute values survive; no token tape, entity-reference node, CDATA distinction, doctype, or lexical residual | Missing for byte-exact; partial for semantic | A byte-exact profile either reproduces the original bytes or explicitly records an archival residual and its size in the ledger. |
| Namespaces and base URI | XML namespace declarations and `xml:base` affect QName/IRI interpretation; prefixes are aliases, not identity | Namespace URI, prefix, and local name are stored; no declaration scope or base URI | Partial | Nested prefix rebinding, default namespace, undeclared-prefix errors, and relative URI resolution are tested under a declared source profile. |
| Language | BCP 47 language tags are structured identifiers; TEI `xml:lang` may be inherited; RDF 1.2 also has text direction | `Text.language` and `script` are arbitrary UTF-8 strings with no tag validation, inheritance, variety, or direction | Partial | Valid/invalid BCP 47, inherited language, script/region variants, and ltr/rtl direction retain exact source and effective values. |
| Unicode identity and search | UAX #15/#29 distinguish source text, normalized equivalence, and grapheme boundaries | Source text bytes are retained; no normalization/search profile in this layer | Implemented for exact source; missing for derived search | Composed/decomposed forms remain distinct source values while profile-versioned keys match only when configured. |
| Unknown extension data | TEI and Lex-0 permit profile-specific extensions and generic attributes/elements | Generic document nodes and values retain unknown element names and fields | Partial | An extension fixture round-trips without schema knowledge; later typed interpretation must retain the original generic node and source identity. |
| Scalar and missing states | RDF/XML Schema datatypes distinguish lexical/value spaces; editorial data needs absent, unknown, and uncertain values | Boolean, signed/unsigned integer, decimal, URI, QName, sequence, bytes, unknown, absent, uncertain are distinct | Partial | All current variants compare tag and payload exactly; unknown/absent/uncertain never collapse; datatype lexical forms and future set/bag distinctions survive. |
| Temporal data | TEI datable values support partial/approximate/custom dates; lexical resources use dates, periods, and historical uncertainty | Signed year, optional month/day, interval, precision enum | Partial | BCE/year-zero policy, invalid calendar dates, open/approximate ranges, time zones, custom calendars, and original lexical forms are tested. |
| Ordering and cardinality | Source order, sense order, participant order, and relation multiplicity can carry meaning | Arrays preserve order; assertions require at least two participants; documents have one parent and ordered roots | Implemented for current arrays; partial for declared collection semantics | Ordered, set-like, and multiset properties are explicit in the reference model; no importer silently sorts or deduplicates occurrences. |
| Stable identity | TEI `xml:id`, source IDs, and external lexical IDs must survive rebuilds and source joins | v0.3 has explicit source IDs; source records preserve duplicate external IDs and entities/assertions carry source scope | Partial | IDs are scoped by source/profile, duplicates are rejected or explicitly disambiguated, and compaction preserves external identity mappings. |
| Serialization compatibility | A compact representation must remain checked against a canonical semantic oracle | v0.3 reference format is deterministic, checked, bounded, and exact for source records/anchors; v0.2 is explicitly rejected rather than ambiguously decoded | Implemented as reference; compact format missing | Golden snapshots, version rejection, unknown-feature handling, and semantic digest equality run on every format change. |

## Highest-priority expressive gaps

These gaps block a claim of maximum-fidelity lexical interchange. They should
be resolved before compact storage or performance tuning is allowed to define
the semantic contract.

1. **Source/profile identity and scope (P0).** v0.3 adds a source manifest,
   duplicate-safe source-scoped identifiers, base URI, source ownership on
   entities/assertions, and explicit typed mappings to source document nodes
   with declared spans. Language/default context and typed lexical views remain
   open; byte-exact token tape is deliberately separate work. Identical IDs
   from two dictionaries are no longer conflated by this layer.
2. **Statement targets and graph context (P0).** `Target.statement` now
   preserves backward-only nested assertion terms, while `GraphContext` keeps
   default, named, and source-scoped anonymous contexts explicit. Arbitrary
   cyclic RDF triple terms and richer graph manifests remain future work.
3. **Typed lexical views (P0).** Represent entry/lexeme/sense/form ownership,
   sense hierarchy/order, written representations, pronunciation, and feature
   bundles as typed relations or schema-declared views over source nodes. The
   existing `EntityKind` labels do not by themselves express these fields.
4. **Language and literal fidelity (P0).** Replace free-form language strings
   with a validated but source-preserving language-tag type, add direction, and
   give literals an optional datatype IRI and original lexical form. Add
   explicit set/bag semantics and a typed sequence policy.
5. **Source anchors and editorial provenance (P1).** v0.3 promotes source IDs,
   node mappings, and declared spans to first-class structures. Responsibility
   agents, changes, certainty precision, and richer links remain open. Generic
   attributes remain necessary for extensions, but cannot provide safe
   resolution or query planning by themselves.
6. **Temporal and calendar model (P1).** Generalize `Date`/`Temporal` to
   preserve time, zone/offset, open boundaries, calendar/custom lexical forms,
   approximation, and source spelling. Keep normalized comparison separate
   from preserved representation.
7. **Semantic/byte-exact preservation boundary (P1).** Add an explicit source
   token tape or archival residual option for XML declarations, entity
   references, CDATA, whitespace and quoting. State clearly which import
   profiles promise semantic preservation versus byte identity.
8. **Extension schema and migration (P1).** Add schema/profile descriptors for
   user-defined entity kinds, predicates, value datatypes, cardinalities,
   inheritance, and constraints. Unknown fields need a versioned extension
   envelope so a newer reader can preserve data it does not interpret.

The generic `bytes` and `unknown` variants are useful escape hatches, but using
them for any of the P0 items would preserve payload bytes while losing the
meaning, scope, identity, or queryable relation promised by the model.

## Versioned compatibility recommendations

1. Keep the current `LEXSEM` v0.3 as the canonical semantic oracle. Do not change an
   existing tag's meaning, enum ordinal, field order, or validation rule under
   the same minor version. The current deterministic body is valuable as a
   differential target even when a compact format is introduced.
2. Add a profile/manifest section before adding lexical semantics. It should
   identify source documents, importer profile and revision, namespace/base
   bindings, language/default scopes, schema vocabulary, and whether semantic
   or byte-exact preservation is promised. A profile digest belongs in index
   identity and benchmark manifests.
3. Treat a newly required distinction as a new major format or a negotiated
   extension section. A minor version may add optional sections only when an
   old reader can skip them without changing the meaning of fields it does
   understand. Unknown sections must be length-delimited; unknown data must be
   preserved or cause an explicit unsupported-feature error according to the
   profile.
4. Allocate distinct ID domains for source nodes, lexical entities, values,
   assertions, and statement terms. External IDs need a source/profile scope,
   original spelling, and collision policy. Never deduplicate identity-bearing
   occurrences because their text or endpoint tuples compare equal.
5. Make relation occurrence the common interchange primitive. Binary edges may
   be a compact view, but the canonical form must retain predicate, ordered
   roles, targets (including statement terms), graph/source context, evidence,
   editorial state, certainty, temporal qualifiers, and source anchors.
6. Preserve original lexical forms alongside normalized comparison values for
   language tags, IRIs, dates, numbers, and analyzed keys. A normalization
   profile/version must be part of the derived value's identity; it must never
   overwrite source bytes.
7. Require semantic digest equality after every compact-format encode/decode.
   The digest must cover tags, IDs, order, source/profile context, explicit
   absence, unresolved bytes/status, and generic extensions. A byte digest is a
   separate gate for token-tape profiles.

## Acceptance rubric for the next semantic implementation

The next implementation slice earns 10/10 only when all mandatory rows pass.
An implementation that passes the current v0.1 model tests but fails any P0
row is a useful prototype, not a complete fidelity layer.

### A. Source and lexical fixture

Build a pinned fixture containing two dictionaries with overlapping IDs and
the same spelling in composed and decomposed Unicode forms. Include an entry,
homograph, nested senses, canonical/variant/inflected forms, IPA, hyphenation,
syllabification, grammar alternatives and negation, definition/example mixed
content, `entryFree`, etymology, translations, related entries, citations,
`xml:id`, `xml:lang`, `xml:base`, `@source`, `@resp`, `@cert`, `@change`,
`@corresp`, `@next`, `@prev`, custom namespaced attributes, comments, and
processing instructions.

The reference importer must retain:

- source document and source-scoped ID for every identity-bearing occurrence;
- exact text, language/script/direction, notation, and original attribute value;
- node and attribute order, mixed-content order, repeated values, and empty
  values;
- source-node anchors for every typed lexical projection; and
- generic extension nodes/attributes when the profile does not recognize them.

The semantic output digest before and after the reference format round trip
must match. A semantic-preservation profile must document any XML lexical
details it intentionally drops. A byte-exact profile must compare source
bytes or a declared residual reconstruction result.

The v0.3 source slice covers source identity, ownership, and typed node/span
anchors. It does not claim byte-exact token tape reconstruction, inherited
language or direction semantics, or a complete TEI/OntoLex schema projection;
those remain separate fidelity gates rather than being inferred from generic
attributes or document ancestry.

### B. Relation and provenance fixture

Include binary, n-ary, self, cyclic, parallel, inferred, retracted,
disputed, uncertain, unresolved, and statement-about-statement relations.
Give each relation distinct role order, evidence, source span, responsible
agent, temporal qualifier, and graph/source context. Verify that:

- no parallel assertion is merged;
- reversing a relation is a view unless an explicit inverse assertion exists;
- role order and repeated participants remain intact;
- unresolved target bytes, URI, label, and status survive;
- quoted/embedded statements preserve assertion identity; and
- forward, reverse, filtered, and bounded graph queries agree with the slow
  reference evaluator, including cycles and duplicate endpoints.

### C. Typed value fixture

Exercise all current variants and the required additions: language tags with
script/region/variant and direction, URI/IRI original spelling, datatype IRI,
integer/decimal lexical spelling, float/NaN/Infinity policy, partial and
custom-calendar dates, time zone/offset, open and approximate intervals,
ordered sequence, set, bag, unknown, absent, uncertain, and opaque bytes.

The test must prove that equal value-space values with different source
lexical forms are not merged when source fidelity requires their distinction.
It must also prove that explicit absence, unknown, null-like extension data,
and omitted fields remain separate states.

### D. Compatibility and hostile input

For every new field, add a v0.1 golden fixture, a supported-reader fixture,
an older-reader behavior test, and malformed inputs for invalid tags, counts,
references, cycles, nesting, UTF-8, language tags, IRIs, dates, lengths,
unknown extensions, and checksum/truncation. Decoding must obey independent
limits for bytes, nodes, strings, relation participants, recursion/graph
visits, and materialized output.

### Scoring

| Area | Weight | Full credit |
| --- | ---: | --- |
| Source/lexical identity and order | 2.0 | Fixture A has digest equality and no occurrence collapse. |
| Typed lexical views and extensions | 2.0 | Entry/sense/form/feature semantics are queryable and generic source data remains. |
| Relation and statement fidelity | 2.5 | Fixture B preserves all relation identity, roles, qualifiers, contexts, and statement terms. |
| Literal/language/time fidelity | 1.5 | Fixture C preserves original and effective values with explicit comparison profiles. |
| Format/version/hostile-input behavior | 1.5 | Golden, compatibility, corruption, and budget suites pass. |
| Documentation and reproducibility | 0.5 | Profile, source revisions, fixtures, and semantic digest are pinned. |

The score is capped at 5/10 if any P0 gap is hidden behind `bytes`, a generic
attribute, or an undocumented convention. It is capped at 8/10 if source
order/identity or unresolved relation data is dropped. Performance and compact
size are measured only after this rubric passes; neither can compensate for
lost semantics.
