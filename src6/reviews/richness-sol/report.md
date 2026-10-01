# Adversarial richness and query review of src6

Review date: 2026-09-12. Reviewed tree: repository commit
`a361a8bfe2b1b6ba673e6907e58c0e67943c8fca`, plus the uncommitted `src6`
tree presented for review. This is a read-only production review: the only new
code is the isolated reproduction package beside this report.

## Verdict

src6 is already a credible **typed lexical document model**, not a disguised
property bag. Its recursive ordered `Item` tree, independent form
representations, rich `Text`, exact feature values, qualified relations,
resources, source spans, certainty, and language context cover a useful portion
of the union of TEI dictionaries, LIFT 0.13, and OntoLex-Lemon.

It is not yet a sufficiently unified or composable native union model. The
largest problems are internal, not missing importers:

1. admission recognizes more local identity-bearing node kinds than the public
   resolver can return, and the query layer cannot compose predicates, paths,
   parents, or cross-document follows;
2. `Relation` has two simultaneous endpoint encodings with undefined
   authority, while neighboring `Denotation` and citation `Translation` shapes
   lack documented bridges where their semantics do coincide;
3. atomic feature-value sharing/re-entrancy has no faithful typed node. Whole
   structures can be referenced, but sharing one atomic value cannot be stated
   without changing its type or relying on an undocumented convention.

There is no demonstrated P0 corruption, memory-safety, ownership, or invalid-
archive failure in the reviewed surface. The P1s below are explicitly **native
design/query gaps**, not proven violations of a documented integrity contract.
P2 observations should be resolved or documented before freezing the API.

## Standards and tooling baseline (version-pinned)

- **TEI P5 4.12.0**, revision `113e933e2`, 28 July 2026. The current
  [dictionary chapter](https://www.tei-c.org/release/doc/tei-p5-doc/en/html/DI.html)
  makes senses recursively nestable and permits dictionary constituents at
  multiple hierarchical levels. It also distinguishes typographic, editorial,
  and lexical views. The [feature-structure chapter](https://www.tei-c.org/release/doc/tei-p5-doc/en/html/FS.html)
  defines libraries, `fVal`, scoped `vLabel` sharing/re-entrancy, list/set/bag,
  alternation, negation, defaults, unknown and underspecified values. The
  [`certainty` element](https://www.tei-c.org/release/doc/tei-p5-doc/en/html/ref-certainty.html)
  has required locus semantics and scoped alternative/degree information; the
  [`standOff` container](https://www.tei-c.org/release/doc/tei-p5-doc/en/html/ref-standOff.html)
  hosts linked annotations and feature libraries.
- **LIFT 0.13**, pinned here to upstream commit
  [`d4db1277f34c8bc8376575f0425b8091e13f5b33`](https://github.com/sillsdev/lift-standard/tree/d4db1277f34c8bc8376575f0425b8091e13f5b33).
  The pinned [main Relax NG/Schematron grammar](https://raw.githubusercontent.com/sillsdev/lift-standard/d4db1277f34c8bc8376575f0425b8091e13f5b33/LIFTDotNet/LiftIO/Validation/lift-0.13.rng)
  includes RFC 4646 language-bearing multilingual forms, nested spans,
  annotations, fields, traits, pronunciation/media, relations, recursive
  subsenses, IDs/GUIDs/order, and range definitions. The pinned
  [standalone ranges grammar](https://raw.githubusercontent.com/sillsdev/lift-standard/d4db1277f34c8bc8376575f0425b8091e13f5b33/LIFTDotNet/LiftIO/Validation/lift-ranges-0.13.rng)
  preserves range/element IDs, GUIDs, parentage, labels, abbreviations, and
  descriptions. This review does not turn the absence of a LIFT importer into a
  defect.
- **OntoLex-Lemon Community Draft, 29 April 2016**, including
  [core, synsem, decomp, and vartrans](https://www.w3.org/2016/04/ontolex/).
  It separates lexical entries, grammatical forms, written/phonetic
  representations, lexical senses, lexical concepts, and ontology references;
  defines syntactic frames/arguments and ontology mappings; models components
  and `correspondsTo`; and gives source/target/category semantics to reified
  lexico-semantic relations. It explicitly requires BCP 47 language tags.
- **Query comparison.** The fixed [XPath 3.1 Recommendation](https://www.w3.org/TR/2017/REC-xpath-31-20170321/)
  supplies child, parent, ancestor, descendant, sibling and predicate
  navigation; the fixed [XQuery 3.1 Recommendation](https://www.w3.org/TR/2017/REC-xquery-31-20170321/)
  adds FLWOR filters, joins across documents, grouping and ordering. The fixed
  [SPARQL 1.1 Recommendation](https://www.w3.org/TR/2013/REC-sparql11-query-20130321/)
  supplies graph-pattern joins, `FILTER`, alternatives, negation, datasets,
  subqueries and arbitrary-length property paths. In deployed linguistic
  tooling, the official [FieldWorks lexicon documentation](https://software.sil.org/fieldworks/features/orientation-to-fieldworks/lexicon/)
  documents many built-in/custom fields and bulk operations over selected
  entries, while its [release history](https://software.sil.org/fieldworks/help/release-history/)
  documents filters over list-reference and phonological-feature fields and
  complex concordance criteria. ANNIS 3.4.3's official
  [AQL user guide](https://corpus-tools.org/annis/resources/ANNIS_User_Guide_3.4.3.pdf)
  documents annotation predicates, direct/indirect dominance and labelled
  edges. These are capability baselines, not a demand that src6 embed any one
  language.

## What src6 does well

- `model.Item` is a real tagged union and its `content` fields preserve lexical
  order and multiplicity. `Sense.content` recursively owns subsenses rather than
  flattening them (`model.zig:151-157`, `296-338`).
- A grammatical `Form` is distinct from its repeated written, phonetic, and
  transliterated `Representation` occurrences. Each representation retains its
  own metadata, language-bearing rich text, script, scheme, and features
  (`model.zig:135-149`). This handles multilingual IPA occurrences such as the
  OntoLex `privacy` example without merging them.
- `Text`/`Inline` is an ordered mixed-content tree with qualified names,
  attributes, comments, processing instructions, explicit language reset, and
  bounded enter/leave traversal (`model.zig:100-133`, `walk.zig:43-107`).
- `Value` distinguishes exact decimal spelling, structures, ordered lists,
  sets, bags, alternatives, negation, unknown, unspecified, and defaults
  (`model.zig:179-210`). The set/bag distinction is validated rather than
  flattened.
- Relations are addressable items with state, confidence, annotations,
  evidence, category, content, and ordered role-labelled participants
  (`model.zig:225-249`). Source origins are many-to-many occurrence rows, and
  residual spans prevent silent source loss (`model.zig:46-56`, `348-359`).
- `walk.Language` correctly retains both an effective language and the
  declaration pointer; reset survives chained lexical and inline traversal
  (`walk.zig:10-35`). The reviewed tests cover this well.
- Packet ownership, archive-byte borrowing, loaded-value ownership, bounded
  traversal, allocation cleanup, digests, and raw/bzip3 page admission are
  explicit and substantially tested. I found no new ownership defect.

## P1 findings

### P1-1 — Admitted identity kinds cannot be resolved or composed uniformly

**Production sites:** `src6/model.zig:90-98`, `src6/validate.zig:115-160`,
`src6/query.zig:63-98`, `src6/archive.zig:370-419`.

**Lexical example:** a POS analysis stores a reusable `Structure` identified as
`shared-number`, and another feature stores `Value.reference(.local =
"shared-number")`. A translation points to a logical entry and sense.

**Observed:** admission resolves the structure reference against the generic
metadata-ID map, but `query.resolve(entry, "shared-number")` returns null because
its result type and traversal cover `Item` only. There is likewise no logical
entry-ID lookup/follow operation. Predicate/feature conditions, parent or
ancestor paths, and cross-entry/resource joins must be rebuilt as application
loops rather than composed over the shipped cursor.

**Expected for the requested query-rich native model:** every identity kind
that admission treats as locally resolved has a typed public resolution result,
and the same borrowed iterator contract can compose node/field/value predicates,
ancestor/descendant paths, and reference follows. Initial execution may scan;
this does not require an index per predicate.

**Executable reproduction:** `repro_test.zig`, test `a validated local
feature-structure reference has no public resolution path`. The broader query
matrix below is API inspection, not a failed runtime assertion.

**Severity:** P1 query-capability/design gap. The typed data often remains
manually searchable, so this is not blanket information loss or a performance
finding; the concrete absence is a public typed resolver/path composition
surface comparable to the tools in the baseline.

**Smallest direction:** generalize the reflection-derived walk to return a
typed `NodeRef`/path for Item, Representation, Feature, Structure, RangeElement,
and shared-value nodes. Layer allocation-free `filter`, `ancestors`, and
`follow` iterators over it, backed by one derived logical document/node catalog
rather than parallel authoritative tables.

### P1-2 — Relation endpoint modes are undefined; related views lack bridges

**Production sites:** `src6/model.zig:225-249`, `src6/model.zig:151-170`,
`src6/validate.zig:242-255`.

**Lexical example:** one relation sets binary `target = sense-b` but also has
participants whose open `Name` roles are spelled `source = sense-a` and `target
= sense-c`.

**Observed:** admission succeeds and preserves both encodings. Because
`Participant.role` is an open qualified `Name`, the model does not document
`source` or `target` as reserved semantics; the reproduction therefore does
**not** prove logically contradictory standardized endpoints. It does prove
that no contract says whether scalar `target` and participants are exclusive,
equivalent, or independent.

`Sense.denotations`, citation-like `Translation` occurrences, and
`Relation(.denotes / .translation)` can sometimes describe related facts, but
they are not automatically duplicates: quoted translation content is not the
same assertion as a reified relation between two senses, and a denotation's
implicit subject may differ from an owner-level relation. The actual gap is the
absence of documented subject/authority rules and typed query bridges for the
cases that do coincide.

**Expected for a less-redundant union model:** make relation endpoint modes an
explicit sum (binary target *or* participant relation), or document precisely
how simultaneous fields compose. Preserve dedicated translation citation and
compact denotation data where they carry distinct semantics. Where an occurrence
also asserts the same relation, expose one explicit link or normalized query
view rather than silently storing two facts.

**Executable reproduction:** `repro_test.zig`, test
`one relation can carry contradictory binary and participant targets`.

**Severity:** P1 pure design gap: undefined endpoint composition and missing
bridges between related native views. The reproduction is an ambiguity probe,
not proof that the open role names carry OntoLex source/target semantics or that
all claim-like shapes are duplicates.

**Smallest direction:** change only `Relation` endpoints to a tagged binary/n-ary
sum with typed convenience accessors. Retain `Translation` as a qualified
citation occurrence and `Denotation` as a sense-owned compact value. Add an
optional relation link or query adapter when either intentionally realizes the
same claim; do not force all three through a universal claim table.

### P1-3 — Atomic feature-value sharing has no faithful typed representation

**Production sites:** `src6/model.zig:90-98`, `src6/model.zig:179-210`,
`src6/validate.zig:115-160`.

**Lexical example:** nominal and verbal agreement features share one atomic
number value. The distinction is graph identity—one value occurrence referenced
twice—not merely two equal copies.

**Observed:** a complete `Structure` can carry `Metadata.id`, and
`Value.reference` can point to it, so whole-structure/library sharing is
compositionally representable. But `Value` itself has no metadata/identity and
there is no sharing-point node. Pointing at a `Feature` ID does not state whether
the feature node or only its value is shared; wrapping an atomic symbol in a
one-field `Structure` changes its native type. Thus atomic identity sharing
depends on an undocumented convention or loses the distinction.

The reproduction with two `Structure.meta.id = "L1"` values shows only that
generic metadata IDs are entry-wide. It does **not** prove semantic loss by
itself: independent local labels can be alpha-renamed while preserving their
graph. TEI's exact label scoping is interoperability syntax, outside this
review's finding. The public resolver mismatch is separately covered by P1-1.

**Expected:** the native value algebra can distinguish “these positions share
one value” from “these positions contain equal copies,” for atomic as well as
structured values, without relying on source-label spelling.

**Executable observation:** `feature-structure identities are entry-wide rather
than structure-scoped` in `repro_test.zig`; the absence of a value-sharing node
is established by model inspection, not by that rejection alone.

**Severity:** P1 pure native representation gap. Shared identity is a semantic
distinction from copied equality, independent of TEI serialization.

**Smallest direction:** add a recursive `Value.shared { id, value? }` (or
equivalent typed node/reference pair) and typed feature/value-library resources.
Use owner/library scope for collision avoidance, but do not preserve source
labels merely for their spelling. Resolution then uses the generalized typed
node path from P1-1.

## P2 findings

### P2-1 — Language validation is not BCP 47 validation

**Production sites:** `src6/model.zig:8-9`, `src6/validate.zig:188-194`,
`src6/walk.zig:16-35`.

`-not--a-tag-` is admitted and propagated as the effective language. The check
only permits ASCII alphanumerics/hyphens; it does not validate subtag placement,
length, grandfathered/private-use structure, or canonical equivalence. This is
an observed validation defect, not a `Language.at` propagation defect:
`Language.at` preserves exactly what admission accepted.

Reproduction: `language admission accepts strings that are not BCP 47 tags`.
Direction: validate against a pinned BCP 47 syntax/registry policy while
preserving original spelling separately from an optional normalized search key.

### P2-2 — Generic byte-slice projection is an ergonomic footgun

**Production site:** `src6/query.zig:29-41`.

`query.entry(&entry).values(.headword)` compiles and yields the bytes `c`, `a`,
`t`; non-slice fields fail indirectly through `std.meta.Child`. The method is
documented as a typed slice projection, so this is not a semantic or type-safety
violation: `[]const u8` really is a slice and the element type remains visible.
It is nevertheless a surprising footgun for an API presented through semantic
examples. Reproduction: `values accepts scalar byte-string fields as byte
collections`.

Direction: either document that strings intentionally enumerate bytes, or
exclude `u8` slices and provide an explicit bytes projection. Give non-slice
misuse a library-owned diagnostic. Existing inactive-union rejection is good
and should remain.

### P2-3 — Cross-document resolution and source-identity policy is undefined

**Production sites:** `src6/model.zig:21-56`, `src6/model.zig:90-98`,
`src6/model.zig:348-359`, `src6/validate.zig:101-160`.

An entry can cite multiple named source documents, yet a metadata identity is
only a byte string in one entry-wide map. `Address` is documented as a “stable
external identity”; the contract does not say that `.entry`/`.resource` must
name a document in the same archive. Therefore the reproduction where
`archive.build` and `verifyAll` accept absent targets proves **no integrity bug**.
It exposes an unresolved policy question: whether these variants mean
same-library resolved links, externally resolvable logical addresses, or either.
The `.unresolved` alternative makes the distinction worth specifying.

Likewise, identical source-local labels can be alpha-renamed without semantic
loss when references are rewritten. Scope becomes a native richness issue only
when callers need distinct source/native identity domains or resolution without
rewriting. LIFT GUID fields and source IDs currently have no dedicated typed
identity variants; attributes/extensions can preserve their bytes but not their
join semantics.

Direction: document address resolution policy. If `.entry`/`.resource` mean
same-library targets, reconcile them against one derived catalog; if external
logical targets are allowed, encode resolution state/scope explicitly and let
`follow` report unavailable targets without calling the archive invalid. Keep
native snapshot IDs, source IDs, GUIDs, and IRIs as distinct variants only where
their different equality/join semantics matter.

## Representation matrix

“Queryable” means through the shipped public query/archive API without writing
a new recursive scan or corpus join. “Manual” means the typed data is present
and ordinary Zig code can inspect it; that is a convenience/performance gap,
not information loss. “Lossy” means only a generic extension/attribute or a
less-specific shape can carry the bytes. “Absent” means the semantic distinction
cannot be stated faithfully.

| Capability / lexical example | Native representation | Shipped query | Assessment |
|---|---|---|---|
| Recursive `bank` sense `1 > 1a`; direct versus all descendants | Recursive `Sense.content` | `.select(.sense, .children/.descendants)` | Representable and queryable; strong |
| Ordered mixed definition `A <hi>financial</hi> institution` | `Text.content: []Inline` with names/attributes/comments/PI | `inlines()` and renderer | Representable and queryable; strong |
| One form with `privacy` IPA in `en-US-fonipa` and `en-GB-fonipa` | repeated `Representation(kind=.phonetic)` | manual `values(.representations)` plus kind/language tests | Representable; filter convenience absent |
| Multiword `credit card` with ordered components and component grammar | ordered `Component` items; grammar can live in component content | kind selection, then manual targets; no follow | Representable; cross-entry navigation/manual join gap |
| Qualified binary/n-ary translation with evidence and certainty | `Relation.meta` + participants/category/state/content | select relation, then manual predicate/roles | Rich, but ambiguous dual endpoint authority (P1-2) |
| Sense-owned denotation IRI | compact `Sense.denotations` preserves its implicit owner | direct field access | Representable; legitimate compact typed view |
| The same denotation occurrence with claim-specific evidence | `Denotation{iri}` has no occurrence metadata; a sense-owned `Relation(.denotes)` may express it but equivalence is undocumented | two related paths without a bridge | Qualifier-loss or manual alternate encoding (P1-2) |
| TEI certainty on only the value of one POS assertion | metadata certainty target/locus/asserted/given/evidence | manual metadata access; target resolver partial | Representable; target/locus domain validation weak |
| Exact decimal, nested FS, list/set/bag, alt/not/default/unknown/unspecified | typed `Value` union | manual exhaustive switches | Representable; strong storage, no feature predicate API |
| Shared complete structure | `Structure.meta.id` + `Value.reference` | resolver ignores Structure identities | Representable; public resolution absent (P1-1) |
| Shared atomic feature value | no identity-bearing `Value`/sharing node | no resolver | Genuinely absent without an undocumented convention (P1-3) |
| LIFT range hierarchy with multilingual labels | `Resource.range`, elements, parent refs, Text labels | archive exact resource lookup then manual traversal | Mostly representable; GUID/source identity is lossy |
| Entry/resource logical address | typed `Reference.entry/resource` | resource exact lookup only; entry scan required | Representable; external-vs-same-library resolution policy undefined (P2-3) |
| Same local label in separate feature scopes | scalar `Metadata.id` | one entry-wide map | Alpha-renaming preserves graph; syntactic scope convenience only |
| Language inheritance, explicit reset, declaration provenance | `Language` + contextual `walk.Language` | carried by matches | Representable/queryable; syntax validation defective |

## Query capability matrix

| Question | src6 answer | Classification |
|---|---|---|
| Exact/prefix headword? | hot archive `lookup`/`prefix` | Native and efficient |
| Immediate/recursive items of a known kind? | `select(kind, children/descendants)` | Native and composable one step |
| Relations where predicate is translation and confidence ≥ 0.8? | select all relations, hand-write switches/decimal comparison | Possible manual scan; no predicate/filter combinator |
| Features named POS whose value is noun, anywhere below a sense? | select grammar, then hand-write `Name` and `Value` matching | Possible manual scan; no feature/value predicate |
| Parent/ancestor sense of a matched definition? | match carries no parent, depth, edge kind, or path | Requires a new traversal/stack; public query gap |
| Descendant inline element with qualified name and inherited language? | cursor exposes nodes/language, caller filters | Possible manual scan |
| Join forms to search keys by form identity? | hit carries form bytes; `resolve` can find Form Items | Possible per-entry manual join |
| Follow translation to another logical entry/sense? | no logical-entry catalog/follow; scan every physical entry | Information present but no direct join; target-availability policy undefined |
| Find all entries using a range element/resource? | enumerate/load all entries and inspect generic refs | Corpus-wide manual scan; no reverse/reference index |
| Resolve a Representation/Feature/Structure/RangeElement ID? | validator accepts IDs, `query.resolve` returns Item only | Genuinely absent public resolution path |
| Arbitrary ancestor/descendant/join/path expression? | no expression algebra; fixed kind cursor only | Not comparable to XPath/XQuery/SPARQL/AQL |

The absence of indexes for every predicate is not itself a correctness defect:
an application can scan typed packets. The substantive gap is that filters,
paths, and joins cannot be composed through one public iterator contract, and
some joins have no authoritative resolution operation at all.

## Smallest coherent redesign

One change set can address most demonstrated gaps without a generic property
bag or mirrored records:

1. **Typed references with an explicit availability policy.** Make identity
   `{domain, scope?, value}` where domains really have different equality/join
   semantics. Specify whether entry/resource links are same-library or external;
   expose `follow` as found/unavailable/unresolved accordingly. Build one derived
   document/node catalog from the typed model for lookup and, only for
   same-library links, validation.
2. **One endpoint mode per relation, explicit bridges between distinct views.**
   Make a `Relation` choose binary target or ordered participants, preserving
   typed predicates and qualifiers. Keep sense-owned denotations and translation
   citations as useful typed occurrence data; add links/adapters only when they
   intentionally realize the same relation.
3. **Typed value sharing.** Add a feature-value sharing node/reference with
   owning-structure/library scope. Let the same typed node resolver cover all
   metadata-bearing model values through derived paths.
4. **Composable borrowed queries.** Generalize the existing bounded cursor to
   return `{node, path/parent, edge_kind, language}` and layer allocation-free
   `filter`, `whereField`, `whereFeature`, `ancestors`, `descendants`, and
   `follow` iterators on it. Archive-wide execution may initially scan; derived
   indexes can accelerate the same semantics later.

This keeps the good architecture—typed Zig values as authority, packets as
ownership boundaries, indexes as projections—while removing multiple semantic
authorities and making the represented richness usable.

## Reproduction and verification

From the repository root:

```sh
cache_dir=$(mktemp -d /tmp/lex6-richness-cache.XXXXXX)
zig build --build-file src6/reviews/richness-sol/build.zig test \
  --cache-dir "$cache_dir/local" --global-cache-dir "$cache_dir/global"
```

The reproduction suite uses only public `lex6` exports. All six tests passed in
Debug, ReleaseSafe, and ReleaseFast during this review. A passing suite confirms
the raw observations only. As qualified above, absent cross-document targets,
open participant-role names, entry-wide labels, and byte enumeration are not by
themselves violations of a documented contract.
