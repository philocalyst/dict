# src6 lexical contract: adversarial standards/API review

Status: initial design critique with a subsequent executable follow-up. The
typed model, packet/archive and query implementation now exist; the ten tests
in `semantic_test.zig` pass in Debug, ReleaseSafe and ReleaseFast. See
[follow-up status](#follow-up-status-represented-surface-versus-conformance)
for repaired representation gaps and remaining interoperability requirements.
The illustrative APIs below are design suggestions, not the shipped surface;
use [README](../README.md) and [example.zig](../example.zig) for current usage.

## Initial verdict

The proposed split is the right starting point: ordinary typed lexical entries
and entry-local immutable packets can give direct key lookup without forcing a
universal triple table or a property bag on every kind. A small assertion type
is still needed for links that have evidence or qualifiers; that is a semantic
claim, not a universal storage representation.

Three changes are blocking before the public API is frozen:

| Priority | Change | Why it is a blocker |
|---|---|---|
| P0 | Make the source-to-packet bridge a first-class, many-to-many mapping with source order and residuals. | TEI deliberately distinguishes a presentation view from an expanded lexical view and asks that their relationship be retained. An entry packet without an origin map cannot round-trip `entryFree`, mixed content, reordered definitions, or stand-off references. |
| P0 | Keep `Entry`, `Form`, `Representation`, `Sense`, `LexicalConcept`, `Denotation`, and `Translation` as distinct identities and target domains. | OntoLex's `Form` is a grammatical realization while representations are its written/phonetic strings; a `LexicalSense` mediates an entry-to-reference pair, while a `LexicalConcept` is a mental abstraction. Collapsing any of these makes the same spelling or gloss answer the wrong question. |
| P0 | Make claim identity, target locus, evidence, and uncertainty first-class. | A citation, annotation, or uncertain POS can qualify one translation, one feature value, or one source span, not an entire entry. Record-level confidence and unqualified edge deduplication lose this scope. |

Until these are present, describe the artifact as a **lexical representation**,
not as TEI/LIFT/OntoLex conformance. The model can be compact and queryable
without pretending that its source projection is a standard serializer.

## What the standards actually require

TEI P5 has both structured `entry` and freer `entryFree`; senses nest
recursively, and forms, grammar, definitions, citations, usage, etymology,
cross-references, notes, and related entries can be attached at different
levels. It also explicitly distinguishes a typographic/source view from a
rearranged lexical view and asks for links between them. See [TEI Dictionaries](https://tei-c.org/release/doc/tei-p5-doc/en/html/DI.html),
[TEI `entry`](https://tei-c.org/release/doc/tei-p5-doc/en/html/ref-entry.html),
[TEI `entryFree`](https://tei-c.org/release/doc/tei-p5-doc/en/html/ref-entryFree.html),
[TEI `sense`](https://tei-c.org/release/doc/tei-p5-doc/en/html/ref-sense.html),
and [TEI `form`](https://tei-c.org/release/doc/tei-p5-doc/en/html/ref-form.html).

OntoLex is a graph vocabulary, not an XML interchange schema. It requires a
lexical entry to have at least one form and permits at most one canonical form;
one form may have multiple written representations and multiple phonetic
representations. It distinguishes `sense` + `reference` from direct `denotes`,
and `evokes` from an ontological reference. Its `vartrans` module reifies
translation relations, and its decomposition module gives ordered components
for multiword expressions. These distinctions are in the [OntoLex community report](https://www.w3.org/2016/05/ontolex/).

The LIFT repository states that the most recent **published** version is 0.13
and links a dedicated 0.13 Relax NG schema. Pin that schema, rather than using
an unqualified or newer development schema: [LIFT standard README](https://github.com/sillsdev/lift-standard),
[published LIFT 0.13 schema](https://raw.githubusercontent.com/sillsdev/lift-standard/master/LIFTDotNet/LiftIO/Validation/lift-0.13.rng),
and [published LIFT 0.13 ranges schema](https://raw.githubusercontent.com/sillsdev/lift-standard/master/LIFTDotNet/LiftIO/Validation/lift-ranges-0.13.rng).
The 0.13 schema carries multilingual forms, annotations, traits, fields,
pronunciations/media, etymology, examples/translations, relations, recursive
subsenses, entry/sense order, IDs, and user ranges. Its interleave models and
Schematron assertions are part of the conformance target, not optional hints.

## Lexical model contract

### Typed products at the public boundary

Use ordinary products with ordinary ownership:

```zig
pub const EntryInput = struct {
    id: SourceOrExternalId,
    content: []const EntryItemInput, // the one authoritative order
};

pub const EntryItemInput = union(enum) {
    form: FormInput,
    gram: GramGroupInput,
    sense: SenseInput,
    etymology: EtymologyInput,
    claim: ClaimInput,
    extension: ExtensionInput,
};

pub const FormInput = struct {
    kind: FormKind,
    content: []const FormItemInput,
};

pub const FormItemInput = union(enum) {
    representation: RepresentationInput,
    features: FeatureStructureInput,
    extension: ExtensionInput,
};

pub const SenseInput = struct {
    id: SourceOrExternalId,
    content: []const SenseItemInput,
    children: []const SenseInput,
};

pub const SenseItemInput = union(enum) {
    definition: DefinitionInput,
    gloss: GlossInput,
    example: ExampleInput,
    claim: ClaimInput,
    gram: GramGroupInput,
    media: MediaInput,
    subsense: u32, // index into this sense's children, preserving placement
    extension: ExtensionInput,
};
```

This is illustrative public shape, not an implementation claim. It is useful
because the fields communicate ownership and cardinality to Zig callers. Do
not replace it with `Record { kind, properties }`, a universal `[]Value`, or a
single `written` field. Open extensions belong in an explicitly namespaced
extension sequence; recognized fields remain typed.

`content` is the one ordered tagged union of known constituents plus extension
handles. `SenseInput.children` is a child table; a `subsense` item points into
that table so child placement remains part of the same order. Typed convenience
iterators (`entry.forms()`, `entry.senses()`, `sense.translations()`) filter the
sequence without making a second semantic copy. A packet must not force every
top-level constituent into a sense: TEI permits a form or grammatical group at
entry, homograph, and sense level, and definitions may occur inside a
translation citation.

### Earlier scaffold audit (historical findings, not the current release status)

The current `src6` files already have the useful typed union and recursive
values, but several fields still make the contract above unrepresentable. These
are concrete gaps in the visible scaffold, not requests for a broader
abstraction:

| Current seam | Adversarial failure | Required boundary change |
|---|---|---|
| `model.Reference.local` is one string; `validate.Context.ids` and `query.resolve` search one entry's metadata IDs. | `#x` in two source documents, a local fragment in another entry, and an unresolved external target have no distinct scope or state. A caller cannot tell “not found yet” from “invalid local rank”, and `Entry.id` is not a source-document identity. | Carry document/base scope, target domain, owner, and resolution state. Keep raw target/display text for unresolved source/external links; reject only a malformed reference in a domain that claims to be local. |
| `model.Annotation` now has `target`/`locus` and `model.Certainty` has `asserted`, `degree`, `given`, and evidence. | The representation can carry a TEI-like scoped certainty, but it still has no profile-aware target-domain/locus validation or importer/exporter mapping for TEI responsibility, source, and alternate-value semantics. | Keep the repaired fields; add source-scoped target resolution and prove them with a schema-aware TEI importer/exporter. Do not collapse certainty into a record confidence. |
| `model.Relation` now has optional `target`, ordered role-labelled `participants`, `category`, `state`, and `Translation.content`. | N-ary claims and citation-local grammar/notes are representable, but there is still no explicit claim product/ID separate from metadata and no predicate-specific participant/cardinality validation for TEI/LIFT/OntoLex profiles. | Retain a stable claim identity and evidence-bearing projection; validate/export relation direction, category, and qualifiers under each named profile. |
| `Representation` now has `meta` (including identity/origins) and `features`; language is carried by its rich `Text`. | Duplicate IPA occurrences and representation features survive the packet, but representation metadata IDs are not returned by `query.resolve`, and no standard importer/exporter proves the form/representation cardinalities. | Keep the repaired occurrence fields; add an explicit representation view/identity lookup and profile tests for OntoLex/TEI/LIFT mappings. |
| `Concept.reference` and `Relation` targets are both the generic `Reference` union. Validation special-cases only local `evokes`/`lexicalized_sense`. | A lexical concept, a sense's ontology denotation, and a direct `denotes` shortcut can share bytes while answering different OntoLex questions; an external IRI is not typed as a denotation or concept. | Use separate `LexicalConcept`, `DenotationRef`, and `LexicalSense` target domains and validate the `sense` → `reference` → denotation and `entry` → `evokes` → concept paths independently. |
| `Entry.sources` still embeds complete source bytes; `Origin` rows and `residuals` now preserve repeated spans, and `SourceExtent`/`Resource.source` can share hot bounds. `Anchor` remains `{ source, start, end }`; `render.write` is semantic reconstruction. | Shared source bodies are still duplicated when embedded, anchors have no document/base scope, and there is no source event/token order or explicit packet/source `OriginMap` destination. A source definition split into gloss + definition, or a packet item merged from two source spans, cannot be explained or exported faithfully. | Keep `Origin`/residuals as the repaired representation layer, then add a scoped source archive and ordered source nodes with many-to-many origin rows (`copied`/`normalized`/`split`/`merged`/`derived`). Treat raw-file retention as separately charged archival mode. |
| `walk.Language` now retains effective value plus declaration; chained selections seed parent context, and `TextMatch.inlines()` walks inline language events. | Reset/unknown is no longer collapsed for query results, but `Item.children()` still treats every `content: []const Item` as the same descendant edge, and `query.resolve` does not expose representation/feature/range identities. | Keep the repaired context-carrying cursor; label lexical, citation, qualifier, and source containment edges, and provide typed identity views for non-`Item` values. |
| `Value.structure` now has `Structure.meta/type/fields`; `Feature.range` remains a `Reference`; `Range`, `RangeElement`, `Resource.range`, and `Resource.source` exist. | TEI feature structure values still have no explicit re-entrancy/reference-node product, and LIFT range IDs/labels/parentage have no schema-aware importer/exporter or standalone ranges interchange proof. | Keep the repaired typed values and range resources; add reference-node identity/collection semantics where needed and validate/serialize the pinned LIFT 0.13 range profile. |
| `archive.Hit` carries only `EntryId`, spelling, and a form byte string; `lookup` compares raw bytes. `Archive.load` decompresses a whole page and decodes a whole `Entry`. | A hit cannot report language, normalization profile, representation/form identity, or source origin; a metadata-only filter necessarily touches prose/source bytes, and one entry shares a page decode with unrelated entries. | Put search-profile/language/form identity and origin in the index, and introduce independently addressed packet/text spans (`TextRef`) or an explicit cold-page contract. Measure page reads for lookup versus render separately. |
| `archive`/`packet`/`compression` are not exported by current `src6/root.zig`, while the public examples necessarily name future `Compiler`/`Book` APIs. | A snippet can look ergonomic but cannot currently be compiled against the advertised public module; this is representation guidance, not evidence of a usable API. | Either export the eventual build/archive modules or label the examples as compile-gated design tests. The acceptance test should compile the exact construction and query shown here. |

The first three rows are the three P0 changes in the verdict. The remaining
rows are P1 boundary checks: they do not require a universal record table, but
they do require that the typed model expose enough identity and scope for the
standards profiles and direct-query promise to be honest.

### Follow-up status: represented surface versus conformance

The current scaffold has repaired a substantial part of the representation
contract. `Reference.resource` distinguishes a controlled range/concept
resource from an entry address; `Reference.unresolved` preserves a target that
cannot be resolved. `Origin` plus `Entry.residuals` preserve repeated and
unmapped source spans, while `Resource.source` and `validate.SourceIndex` let entries
share source-length bounds. Representation metadata/features, denotation
objects, structured feature values, certainty scope, relation participants and
categories, translation-local content, and standalone range resources are now
ordinary packet values. The contextual `walk.Language` and inline cursor also
preserve declaration versus effective language. The new semantic tests exercise
these repaired values and pure-Zig packet round trips.

Those repairs establish a useful lexical representation; they do not establish
interchange conformance. The following evidence is still absent:

| Profile or promise | What is represented now | What must still be built and tested |
|---|---|---|
| TEI P5 dictionaries | Typed entry/sense/form/citation-like values, rich inline content, source anchors, certainty fields, and residual bytes. | A named TEI P5/customization importer and exporter, source event/token order, `xml:id`/base-scope resolution, `entryFree`/`dictScrap` retention, and round trips proving the relationship between source and lexical views. See [TEI Dictionaries](https://tei-c.org/release/doc/tei-p5-doc/en/html/DI.html), [TEI certainty](https://tei-c.org/release/doc/tei-p5-doc/en/html/ref-certainty.html), and [TEI feature structures](https://tei-c.org/release/doc/tei-p5-doc/en/html/FS.html). |
| LIFT 0.13 | Multilingual text, recursive senses, traits/fields, annotations, examples/translations, media, IDs, order, and standalone range resources have typed homes. | A pinned `version="0.13"` importer/exporter, Relax NG plus Schematron validation, `id`/`guid`/`order`/`lang` behavior, duplicate-per-parent diagnostics, and a separate ranges-document round trip. See the [published LIFT 0.13 schema](https://raw.githubusercontent.com/sillsdev/lift-standard/master/LIFTDotNet/LiftIO/Validation/lift-0.13.rng) and [ranges schema](https://raw.githubusercontent.com/sillsdev/lift-standard/master/LIFTDotNet/LiftIO/Validation/lift-ranges-0.13.rng). |
| OntoLex/RDF | Separate form, representation, sense denotation, lexical concept, resource address, and qualified translation/relation values. | RDF/Turtle or JSON-LD lowering using the OntoLex/synsem/decomp/vartrans IRIs; cardinality and graph checks for `reference`, `evokes`, `denotes`, ordered decomposition, and translation direction. The [OntoLex community report](https://www.w3.org/2016/05/ontolex/) is a semantic mapping target, not proof that the Zig packet is an RDF serializer. |
| Direct lookup/lazy payload | A direct hot key index, resource catalog, bounded pages, real bzip3 path, and contextual lexical cursors. | Search-profile/language/form identity in hits, independent text/page references, metadata-only filters that prove zero prose-page reads, codec/API/block metadata, and measured cold/warm byte ledgers. |

Thus the tests should be read as **representation gates**. They do not bless a
claim of TEI, LIFT, or OntoLex conformance until the corresponding importer,
exporter, validator, and round-trip evidence exist.

### Root reconciliation of the review

The critique is retained as design evidence, but not every suggested new type
or table is accepted. Current common metadata supplies claim/representation
identity without another parallel identity store. `Anchor.source` names a
document resource; coordinates are scoped by that identity. An `Origin` belongs
to the semantic value whose metadata contains it, so its destination is not
missing merely because a separate destination column is absent. Repeated rows
and multiple owners represent many-to-many source mappings. The remaining gap
is proving importer/exporter mappings, not adding a second origin database.

Current root exports the archive and compression modules, and `example.zig` is
a separately compiled public client. `load` selects Entry versus Resource from
the address type; `Match.values(.representations)` and `.child(.text)` retain
field-level context. The earlier unexported-module and representation-context
findings are repaired. Arbitrary non-Item identity lookup, profile-specific
cardinality/domain checks and independent lazy text decoding remain open.

A final bounded Luna/max review checked the actual source-index lifetime and
query projection paths. It found an inactive-union-field hazard in generic
`child`/`values`: naming a union payload does not prove its tag. These operations
now require structs, with separate expected-compile-error tests for scalar and
slice projection. Tagged values remain available for exhaustive `switch`.
Tree traversal and field projections share `Language.at`, tested against the
same declaration pointers and explicit resets. The review found no concrete
source-index ownership defect; borrowed index keys must remain immutable.

### Identity spaces

Keep these IDs separate even when they happen to have the same bytes:

| Identity | Meaning | Never infer |
|---|---|---|
| `EntryId` | One normalized lexical entry in this snapshot. | That it is the same as a TEI/LIFT source entry or an RDF IRI. |
| `FormId` | One grammatical realization owned by an entry. | That each spelling variant is a new form. |
| `RepresentationId` | One written, phonetic, transliterated, or other representation occurrence. | That equal strings have equal scope, language, or provenance. |
| `SenseId` | One sense occurrence owned by one lexical entry; children are recursive. | That equal definitions or glosses identify the same sense. |
| `LexicalConceptId` | A language-independent mental/conceptual grouping. | That it is an ontology denotation or a translation cluster. |
| `DenotationRef` | An ontology/entity/predicate IRI or source resource referenced by a sense. | That it is a concept node or a definition string. |
| `ResourceId` / `RangeId` | A standalone controlled source, range, or concept resource addressable by the archive. | That a resource address is an entry-local lexical item or that its external target exists merely because it is well-formed. |
| `ClaimId` | One asserted, inferred, disputed, or retracted relation with its own evidence and order. | That equal endpoints are duplicate claims. |
| `SourceNodeId` | One source occurrence in one document scope. | That an `xml:id` string is globally unique across documents. |

The source identity must include document/base scope. The same `xml:id` or
LIFT `id` can occur in different documents, while `guid`, `id`, and TEI
`xml:id` remain distinct source fields. A cross-entry reference therefore
needs a domain and scope, not only a rank. If resolution fails, retain the raw
target, display text, expected target domain, and resolution state:

```zig
pub const Link = union(enum) {
    entry: EntryId,
    resource: ResourceId,
    form: FormId,
    sense: SenseId,
    concept: LexicalConceptId,
    denotation: ExternalIri,
    quoted: TextRef,
    unresolved: struct {
        raw: []const u8,
        scope: SourceScope,
        expected: TargetDomain,
        display: ?TextRef,
    },
};
```

Unresolved is data, not `null` and not a failed build. An invalid local rank
domain is a build error; an unresolved external URI or source fragment is a
queryable link that an exporter can reproduce.

### Forms versus representations

`Form` means one grammatical realization. `Representation` means one string
under a representation scheme. Keep at least:

```zig
pub const RepresentationInput = struct {
    kind: RepresentationKind, // written, phonetic, transliteration, other
    value: TextInput,
    language: DeclaredLanguage,
    script: ?[]const u8,
    notation: ?[]const u8,
    features: ?FeatureStructureInput,
    origin: ?SourceAnchor,
};
```

The same form may have `colour@en-GB` and `color@en-US`, and may have two IPA
pronunciations. Conversely, singular and plural are separate forms, even if
their strings are related. Orthographic variants must not become separate
lexical entries merely because the hot key index contains both spellings.
Under an OntoLex profile, enforce one canonical form per lexical entry and
report a profile error if the source has more; under a TEI archival profile,
retain all source forms and map them explicitly.

Support multiword expressions and affixes as typed entries, with an ordered
component sequence (`position`, corresponding entry, and component-local
features). OntoLex's `decomp:subterm` alone does not state which realization
or position occurs in the compound; dropping the component sequence makes
phrase lookup and morphological interpretation impossible.

### Recursive senses and scoped constituents

`SenseInput.children` is recursive and ordered. Every sense level may own
definitions, glosses, examples, translation assertions, usage labels,
grammatical groups, notes, media, relations, and source anchors. A child sense
must not inherit the parent's definition merely because its interval is nested;
the query API needs both `sense.content()` and `sense.descendants()`.

Use a `n`/ordinal field as source metadata, not as identity. Preserve an
explicitly empty sense, a sense with only a note, and a definition attached to
an outer sense. TEI recommends using `sense` even for a single sense and allows
unbounded recursive sub-senses; see [TEI sense hierarchy](https://tei-c.org/release/doc/tei-p5-doc/en/html/DI.html#DITPSE).

Definitions and glosses are rich text values, not just byte strings. A
translation citation may have multiple quotes, target-language grammar, usage
labels, a definition, and nested example translations. Examples may be cited
from a bibliography, so the citation and the quoted text need separate
identities and evidence; see [TEI translation equivalents and examples](https://tei-c.org/release/doc/tei-p5-doc/en/html/DI.html#DITPTR)
and [TEI `cit`](https://tei-c.org/release/doc/tei-p5-doc/en/html/ref-cit.html).

Etymology is an ordered content/event sequence, not just one `derived_from`
edge. It can contain several direct ancestors, comparison forms outside the
descent line, language names, dates, glosses, prose commentary, and
cross-references. Preserve those items and their source anchors; see [TEI etymological information](https://tei-c.org/release/doc/tei-p5-doc/en/html/DI.html#DITPET).

Media is a first-class reference with URL/IRI, MIME type, dimensions, label or
caption, alt text, and provenance. The same media object can be mentioned by a
pronunciation and an illustration without merging the two occurrences. TEI's
`graphic` has media metadata and a resource URL; LIFT 0.13 puts media and labels
inside pronunciation/illustration content. See [TEI `graphic`](https://tei-c.org/release/doc/tei-p5-doc/en/html/ref-graphic.html)
and the [LIFT 0.13 schema](https://raw.githubusercontent.com/sillsdev/lift-standard/master/LIFTDotNet/LiftIO/Validation/lift-0.13.rng).

## Language and feature contract

### Language inheritance and reset

Store both the declaration and the effective value. A declaration has three
states: omitted/inherit, explicit non-empty tag, and explicit empty/reset
where the source profile permits it. Do not turn an empty declaration into
absence. Compute an effective language while walking the owning scope, but do
not overwrite the declaration.

Language belongs at the smallest supplied scope: entry, form, representation,
sense content, quote, example translation, and inline span can differ. A
translation's target language is not the language of its source sense. Keep
language tag spelling and canonical validation separately; OntoLex asks for
BCP-47-compatible tags, while TEI and LIFT have their own attribute locations.
Return both `declaredLanguage()` and `effectiveLanguage()` from a text view.

The minimum regression is an English entry whose definition contains a French
span and then a child span with `xml:lang=""`. The French span must be French;
the reset span must not silently inherit French; the omitted span after it must
follow the profile's declared parent scope. The source residual must retain
which declaration was omitted versus present-empty.

### User ranges and extensible feature structures

Ranges are data, not a finite enum. A `Range` needs an ID, optional external
URI, multilingual description/label/abbreviation, optional parent, optional
GUID, and ordered range elements. A range element needs its own ID, optional
parent/GUID, and the same multilingual labels. A missing parent or URI is an
unresolved reference with status, not a silently flattened string. Support a
standalone ranges document as well as a LIFT header range.

Feature structures need a recursive typed value graph:

```zig
pub const FeatureValue = union(enum) {
    binary: bool,
    integer: i64,
    symbol: QualifiedName,
    string: TextRef,
    structure: FeatureStructureId,
    collection: struct { organization: CollectionKind, members: []const FeatureValueId },
    alternative: []const FeatureValueId, // exclusive alternatives
    negation: FeatureValueId,
    default_marker,
    unknown,
    unspecified,
    reference: Link,
};
```

Preserve feature names, structure type, references/re-entrancy, and whether a
collection is a list, set, or bag. Preserve duplicates and order in lists and
bags, including an explicitly empty collection. Preserve exclusive
alternation, negation, default markers, unknown, and unspecified states even if
the reader does not evaluate them. TEI feature structures explicitly support
recursive values, library references, lists/sets/bags, alternation, negation,
and default/underspecified values; see [TEI Feature Structures](https://tei-c.org/release/doc/tei-p5-doc/en/html/FS.html).

LIFT `trait` (`name`/`value` plus annotations) and `field` (`type` plus
multilingual forms and extensible content) should lower to typed range/feature
values while retaining their original names and source occurrences. A closed
POS enum is a convenience projection, never the storage authority.

## Claims, evidence, and uncertainty

Use one explicit claim product for semantic links, with a role-labelled
participant sequence rather than forcing every n-ary event into a binary edge:

```zig
pub const ClaimInput = struct {
    id: ?SourceOrExternalId,
    predicate: QualifiedName,
    participants: []const ParticipantInput, // role + Link
    status: ClaimStatus,                    // asserted, inferred, disputed, retracted
    source: []const SourceAnchor,
    evidence: []const EvidenceInput,
    annotations: []const AnnotationInput,
    order: ?i64,
};
```

`TranslationAssertion`, `denotes`, `evokes`, synonymy, cross-entry relations,
etymological events, and source-to-packet alignments can use this product.
Simple unqualified binary claims may get a compact adjacency projection, but
the physical `ClaimId` and all qualifiers remain authoritative. Never merge
two equal-endpoint claims if their source, evidence, status, category, order,
or annotation differs. Do not infer symmetry, transitivity, or inverse
translation.

An annotation must name its target and locus. Its target may be an entry,
form, sense, field value, representation, claim, source node, or text span;
its locus may be name, start, end, location, value, or an extension-defined
locus. Preserve the declared value/alternative, degree or label, responsible
agent, time, source, and conditional `given` references. TEI `certainty` makes
the locus required and supports `assertedValue`, `degree`, and `given`; see
[TEI `certainty`](https://tei-c.org/release/doc/tei-p5-doc/en/html/ref-certainty.html).

Example: an uncertain `pos=verb` claim must not make the definition, IPA
pronunciation, or a different translation uncertain. An annotation on one
quote must not annotate the whole example citation. Query results should
return the claim/target and annotations together, not a single confidence
float on `SenseView`.

### Translation and semantic links

Keep the following paths distinct:

```text
entry --sense--> lexical sense --reference--> ontology denotation
entry --evokes--> lexical concept
sense --translation--> target sense (or quoted/unresolved lexicalization)
```

OntoLex defines `sense` + `reference` as the precise entry-to-ontology link,
while `evokes` points to a lexical concept; `denotes` is a shortcut/property
chain, not permission to discard the intermediate sense. `vartrans:Translation`
reifies a source/target relation and category. A TEI/LIFT translation quote can
remain an unresolved lexicalization even when an equivalent target entry exists
elsewhere. Preserve both the raw quote and any explicit resolution claim.

## Source/document contract

The source side is an ordered event stream or equivalent token tape. It must
retain, under the selected preservation mode:

- namespace-qualified element names and declarations;
- ordered child/text/comment/processing-instruction events;
- all attributes, including linking, normalized/original, sort, rendition,
  responsibility, source, and custom attributes;
- source IDs, base scopes, source locations, and unresolved fragments;
- mixed-content spans and stand-off anchors;
- `entryFree`/`dictScrap` and unknown namespaced extensions;
- explicit source order even when packet/key order differs.

Each packet item gets zero or more `OriginMap` rows and each source span may map
to zero or more packet items. An origin row stores source scope, half-open span,
operation (`copied`, `normalized`, `split`, `merged`, `derived`), and optional
claim/transform metadata. A single source definition may become a normalized
definition plus a gloss; two source labels may feed one feature value. A
single source anchor is insufficient.

Offer two named modes:

1. **Semantic preservation:** text, mixed-content order, namespaces, attributes,
   source IDs, references, and documented structure survive; serialization may
   choose different prefixes or quoting.
2. **Byte-exact preservation:** a complete lexical token residual also retains
   whitespace, entity spelling, attribute order, and other serialization details.

An opaque original-file archive is an explicit archival fallback and must be
counted as duplication; it cannot be used to claim the compact semantic packet
is itself byte-exact. Do not store a second independently copied DOM and packet
graph.

## Direct query and storage contract

The hot path should be visibly payload-cold:

1. The key index maps exact/prefix keys and the selected search profile directly
   to `EntryId` plus origin/form evidence.
2. Entry metadata, IDs, grammatical projections, claim endpoints, and packet
   directory rows are readable without rendering definitions/examples.
3. A `TextRef` or rich-content cursor decodes only the independently addressed
   bzip3 page(s) needed by `writeTo`/`snippet`; filters run before page reads.

Every bzip3 page record must carry enough information for another reader:
codec/API identity, decoder state-size or block-size class, logical and
compressed lengths, checked offsets, and checksum. Use real upstream libbz3
encoding/decoding; identity bytes must never be reported as compressed output.
Malformed or checksum-repaired compressed data may be discovered lazily, but
the first touched page must return a typed corruption error without a crash,
undefined bytes, or a leak. Invalid codec configuration is a build error;
raw fallback is allowed only under a declared expansion/resource policy.

Page and key indexes are implementation details, not semantic identity. The
artifact charges page directories, checksums, origin maps, and direct indexes
in its byte ledger. A packet may span pages, but its packet directory must map
every text range to the relevant page(s) without scanning the complete corpus.

## Suggested public Zig construction/query surface

The following is the smallest useful shape to exercise the contract. Names are
illustrative and should be changed only with equivalent ownership and scope
semantics.

### Build

```zig
const lex = @import("lexicon");

var compiler = try lex.Compiler.init(allocator, .{
    .source_profile = .tei_p5,
    .preservation = .semantic,
    .payload = .{ .codec = .bzip3, .page_bytes = 64 * 1024 },
});
defer compiler.deinit();

const bank = try compiler.addEntry(.{
    .id = .{ .source = .{ .document = "tei-main", .value = "bank.1" } },
    .content = &.{
        .{ .form = .{
            .kind = .canonical,
            .content = &.{
                .{ .representation = .{ .kind = .written, .value = "bank", .language = .tag("en") } },
                .{ .representation = .{ .kind = .phonetic, .value = "bæŋ", .language = .tag("en"), .notation = "ipa" } },
            },
        } },
        .{ .sense = .{
            .id = .{ .source = .{ .document = "tei-main", .value = "bank.1.s1" } },
            .content = &.{
                .{ .definition = .{ .text = "a financial institution" } },
                .{ .claim = .{
                    .predicate = "translation",
                    .participants = &.{
                        .{ .role = "source", .target = .{ .sense = .local(0) } },
                        .{ .role = "target", .target = .{ .quoted = .{ .text = "banque", .language = .tag("fr") } } },
                    },
                    .status = .asserted,
                } },
            },
            .children = &.{},
        } },
    },
});

try compiler.addSource(.{ .scope = "tei-main", .events = source_events });
try compiler.mapOrigin(.{
    .packet = bank,
    .source = .{ .scope = "tei-main", .start = 120, .end = 241 },
    .operation = .copied,
});

const snapshot = try compiler.finish();
defer snapshot.deinit();
```

The builder owns/copies caller input until `finish`; the resulting snapshot is
immutable. `addSource` and `mapOrigin` make it impossible to mistake the
normalized packet for the source XML. A real implementation should reject a
duplicate ID within a source scope, but retain an unresolved external target.

### Query and render

```zig
var book = try lex.Book.open(snapshot.bytes(), .{
    .verify = .hot_index_and_directories,
    .limits = .{ .max_page_decode_bytes = 1 << 20 },
});
defer book.deinit();

var hits = try book.lookup(.{ .exact = "bank", .language = .tag("en") });
defer hits.deinit();

while (try hits.next()) |hit| {
    // `lookup` touched only the direct key index and returns EntryId/origin.
    var entry = try book.entry(hit.entry);
    var senses = entry.senses();
    while (try senses.next()) |sense| {
        var translations = sense.translations(.{ .language = .tag("fr") });
        while (try translations.next()) |claim| {
            switch (claim.target()) {
                .resolved_sense => |target| useTarget(target),
                .quoted => |text| try text.writeTo(out.writer()),
                .unresolved => |link| reportUnresolved(link),
                else => {},
            }
        }

        var definitions = sense.definitions();
        while (try definitions.next()) |text| {
            // This is the first operation allowed to decode a bzip3 page.
            try text.writeTo(out.writer());
        }
    }
}
```

The important properties are the scopes, not the exact method names: lookup
returns identity-bearing hits; `entry.senses()` does not widen a nested-sense
selection to its enclosing entry; unresolved links remain visible; and text
rendering is an explicit caller-sink operation. Views borrow an immutable book
mapping; they do not retain pointers into movable temporary unions or allocate
an answer-sized list behind the caller's back.

## Representation versus conformance

| Claim | Representation evidence | Required additional evidence before using the claim |
|---|---|---|
| TEI-compatible lexical data | Typed packets plus an ordered source event forest can represent common `entry`/`sense`/`form` material. | A named TEI P5/customization profile, schema-aware importer, valid TEI exporter, ID/base resolution tests, and source/lexical origin-map round trips. `entryFree`/`dictScrap` and extensions must not be silently discarded. |
| OntoLex mapping | Entry/form/sense/concept/reference/translation identities can lower to RDF resources and properties. | RDF/Turtle/JSON-LD output using the OntoLex/synsem/decomp/vartrans IRIs, cardinality checks (at least one form, at most one canonical form per profile), and graph tests proving `reference`, `evokes`, and translation direction. |
| LIFT 0.13 interchange | Typed packets can hold the fields, multilingual forms, recursive senses, ranges, and annotations in the 0.13 schema. | Emit `version="0.13"`, validate with the pinned 0.13 Relax NG plus its Schematron assertions, retain `id`/`guid`/`order`/`lang`, and test a separate ranges document. Do not cite a 0.14/0.15 development schema. |
| Direct dictionary lookup | A hot key index can answer exact/prefix queries before packet text decode. | Measure touched bytes/page reads and prove the same answers with the index disabled. This is an implementation property, not TEI/OntoLex/LIFT conformance. |
| Lazy bzip3 pages | Page directory and `TextRef` can defer text decode. | Differential tests against the pinned libbz3 API, legal custom block sizes, repaired-checksum failures, allocation-failure cleanup, memory limits, and a byte ledger including all codec metadata. |

An importer may have strict, permissive, and archival modes. Strict mode rejects
nonconforming LIFT/TEI input with a source-located diagnostic; permissive mode
retains the data and marks the profile violation; archival mode retains the
raw source residual. None of these modes should silently repair order,
duplicate claims, IDs, or language declarations.

## Ten adversarial semantic fixtures

Each fixture must be constructible through the public builder, survive a
snapshot round trip, answer the listed query, and (where applicable) export
under the named standard profile. The fixtures are intentionally small enough
to run in Debug and with a failing allocator.

| ID | Input | Required observable result |
|---|---|---|
| F1 — homographs and wrappers | TEI entry with two `<hom>` children for `bank`, distinct POS/etymology and senses, plus one outer grouping entry. | Exact key returns two distinct entries and all source wrapper/child order. No wrapper is silently treated as a lexical sense; no equal spelling dedupes the entries. ([TEI dictionary hierarchy](https://tei-c.org/release/doc/tei-p5-doc/en/html/DI.html)) |
| F2 — form versus representation | OntoLex `color` has one canonical grammatical form with `colour@en-GB` and `color@en-US`, plus two phonetic representations; a companion `child` entry has separate singular/plural forms. | `color` has one form, four representation occurrences, and one canonical-form relation; `child` has separate form IDs for singular/plural. Search may hit both `color` spellings without merging their provenance. ([OntoLex forms](https://www.w3.org/2016/05/ontolex/)) |
| F3 — nested sense ownership | TEI `sense n="1"` contains a direct definition and child `sense n="a"`/`n="b"`, where one child has an example and translation. | `sense.content()` returns only the owner's items; `descendants()` returns `a,b` in order; child queries never inherit the outer definition or sibling translation. ([TEI `sense`](https://tei-c.org/release/doc/tei-p5-doc/en/html/ref-sense.html)) |
| F4 — language inheritance/reset | An English entry has a French inline span, then a nested explicit-empty language declaration, then an omitted declaration; a LIFT translation has an explicit target `lang`. | Each text returns declared and effective language; reset is not absence, translation target language is not source language, and source residual retains all three declaration states. |
| F5 — order, multiplicity, and empty | Repeated equal quotes, pronunciations, examples, and relation claims in source order; an explicitly empty feature collection and an absent feature field. Include a LIFT duplicate that violates its per-parent type/language Schematron rule. | Equal bytes can intern as values, but every occurrence and claim remains; list/bag duplicates and order survive; empty differs from absent; strict LIFT export diagnoses the invalid duplicate while permissive/archive import retains it. ([LIFT 0.13 schema](https://raw.githubusercontent.com/sillsdev/lift-standard/master/LIFTDotNet/LiftIO/Validation/lift-0.13.rng)) |
| F6 — concept versus denotation | Two English senses share a lexical concept but reference different ontology resources; a second language lexicalizes the same concept. | `conceptMembers`, `sense.reference`, and `entry.evokes` produce different answers. No concept is inferred merely from equal glosses; no external IRI is converted into a local concept ID. ([OntoLex lexical concepts](https://www.w3.org/2016/05/ontolex/)) |
| F7 — reified translation and unresolved target | `vartrans:Translation` from an English sense to a French sense has category/evidence; a second translation is a quoted `banque` with no resolvable entry and a disputed reverse claim. | Source/target direction, category, evidence, status, and raw quote are queryable. The unresolved target is not dropped, and no inverse/symmetric/transitive translation is invented. ([OntoLex vartrans](https://www.w3.org/2016/05/ontolex/)) |
| F8 — claim-scoped uncertainty | A TEI certainty annotation targets only a POS claim at `locus="value"`, supplies an alternative and degree, and is conditionally `given` another certainty; the definition is certain. | The POS claim exposes target/locus/alternative/degree/condition; definition and unrelated pronunciation remain certain. No entry-wide confidence field is synthesized. ([TEI `certainty`](https://tei-c.org/release/doc/tei-p5-doc/en/html/ref-certainty.html)) |
| F9 — user range and feature algebra | LIFT range `gram` has `noun` and child `proper`; custom traits/fields use those IDs. TEI features include nested structures, list/set/bag, empty collection, exclusive alternative, negation, default, unknown, unspecified, and a re-entrant reference. | Range hierarchy and multilingual labels survive; feature value kind/order/duplicates/references survive; unsupported evaluation returns a value, not a flattened string. ([LIFT ranges 0.13](https://raw.githubusercontent.com/sillsdev/lift-standard/master/LIFTDotNet/LiftIO/Validation/lift-ranges-0.13.rng), [TEI feature structures](https://tei-c.org/release/doc/tei-p5-doc/en/html/FS.html)) |
| F10 — source provenance, etymology, media, and local unresolved ID | Source contains an etymology with language/date/mentioned form/prose and a cross-reference to `#missing`, plus pronunciation media with URL/MIME/label. Physically sort packet keys differently from source order. | Etymology content and media metadata retain order and origin; `#missing` remains unresolved in the correct document scope with display text; packet order and source order are independently queryable. Rendering one definition touches only its bzip3 page and reports a repaired-checksum corruption without affecting other entries. ([TEI etymology](https://tei-c.org/release/doc/tei-p5-doc/en/html/DI.html#DITPET), [TEI `graphic`](https://tei-c.org/release/doc/tei-p5-doc/en/html/ref-graphic.html)) |

## Acceptance gates

Before calling the design rich or standard-interoperable, require:

1. F1–F10 through the same ordinary typed builder and immutable reader; no
   fixture-only serializer or universal property table.
2. Independent source and packet queries, with explicit origin-map joins and
   declared semantic versus byte-exact preservation mode.
3. Exact/prefix key queries that decode zero text pages, followed by filtered
   sense/claim queries and explicit `TextRef.writeTo` rendering.
4. LIFT 0.13 Relax NG/Schematron validation and a separate ranges document;
   TEI profile validation and TEI source-order/origin tests; RDF graph tests
   for OntoLex semantics. A model mapping alone is not conformance.
5. Failure tests for duplicate scoped IDs, ambiguous local fragments, absent
   versus empty values, wrong target domains, invalid feature values,
   unresolved external links, nested-sense leakage, language reset, bzip3
   state-size mismatch, repaired checksums, truncation, and every ownership
   transfer under a failing allocator.
6. A complete artifact ledger charging direct indexes, packet/page directories,
   origin mappings, checksums, and codec state metadata. A smaller key section
   is not evidence that the rich artifact is smaller.
