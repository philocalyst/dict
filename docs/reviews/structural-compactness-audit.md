# Structural compactness and fidelity audit

Audit target: `plan.md`, the current semantic model and reference encoding, the
raw snapshot prototype, and the in-progress v0.4 shared-atom/varint branch.
This review is deliberately adversarial. A feature is marked implemented only
when its representation, validation, query semantics, and round-trip evidence
exist together. A fixture that happens to contain one form or one language is
not evidence of complete lexical coverage, and no fixture can justify “all
relations”, “10x”, or “maximally compact”.

## Findings, ranked

### P0: v0.4 is now present, but its reader is not yet hostile-input complete

The transient integration failure (the v0.4 writer dispatched to a missing
`decodeCompact`) is resolved at the current revision: `zig test
src/semantic_format.zig` passes 17 tests and the compact round-trip tests cover
the current model fields. This must remain a CI gate; it was a real release
blocker while the branch was live, but is not a current finding.

The remaining reader contract is weaker than the passing fixture suggests.
`decodeCompact` checks the header, checksum, pool references, canonical varints,
section exhaustion, and calls `Builder.build` (`src/semantic_format.zig:631-705`),
but allocation-failure tests after malformed nested records and a semantic
digest differential harness are still absent. Existing parser tests do cover
noncanonical varints, out-of-range atom references, and atom budgets; those are
not equivalent to proving every ownership path. The same issue remains in the legacy reader: `readValue`, `readDocument`, and
`readAssertion` allocate nested slices before ownership reaches the builder
(`src/semantic_format.zig:1141-1166`, `1216-1271`).

The acceptance condition is a failing-allocator matrix for both codecs, plus a
semantic-digest differential test. It must check the compact flag, all nine
header counts, pool count/length/UTF-8 use, every reference domain, minimal
varints, section exhaustion, and cleanup of partially decoded pool atoms,
values, documents, participants, evidence and attributes. Byte equality of the
current model does not prove this.

### P1: legacy reader and compact malformed paths still need ownership proof

These are distinct from the fixed builder leaks. The compact path now guards
the processing-instruction target with a local `errdefer` and
`freeCompactChildren` (`src/semantic_format.zig:749-775`), and its 17-test
leak is resolved. The legacy path still has the same shape at `readDocument`
lines 1223-1235: if `r.id()` for PI data fails after the target copy, the
target has not entered `children` and `errdefer children.deinit` does not free
it.

In the legacy path, `readValue` creates text bytes, language, script and
notation in one initializer (`src/semantic_format.zig:1141-1144`), and sequence
IDs are allocated without an `errdefer` (`1156-1161`). A failure in a later
field or ID leaves earlier allocations live. `readAttributes` similarly
allocates the entire array and fills names without a partial-record cleanup
guard (`1208-1214`). `readAssertion` has the same participant/evidence pattern
(`1237-1271`). The compact helpers generally add guards, so this finding is
primarily a legacy compatibility and adversarial decoder issue, but it still
matters because `encodeReference` and minor-3 inputs remain public.

`readDocument` also has no guard for the already-owned `name` or `attrs` when a
later child fails (`src/semantic_format.zig:1218-1237`), and `readNameOwned`
can lose `local` if the prefix duplication fails (`1170-1172`). These are
independent failure points and need to be included in the cleanup matrix.

The compact entity loop has a corresponding malformed-input hole: it allocates
`external` and then reads `label` and `source` before installing the entity
(`src/semantic_format.zig:679-686`). If either ID read fails, `external` has
no local guard and leaks. Add a failing malformed-entity regression, not only
the valid-stream failing-allocator loop.

There is also an allocation transfer bug in the legacy namespace loop:
`readLegacy` duplicates `p`, then returns directly if `b.namespaces.append`
fails (`src/semantic_format.zig:261-268`), leaking `p`; the compact loop frees
its prefix on this path (`656-659`). Add a test that fails the append after both
name copies and assert zero outstanding allocations.

The compact valid-stream allocation test (`semantic_format.zig:1785-1819`)
does not exercise errors after a nested allocation, so the malformed compact
entity case and all legacy cases still need isolated failing-allocator
regressions. Do not infer coverage from the builder's PI test: it exercises
`Builder.appendChild`, not decoder-local ownership.

### P0: the proposed model still cannot represent complex word parts

`EntityKind` has `form` but no word-part/morpheme/component identity
(`src/semantic.zig:34-54`). `Text` only has bytes, language, script and
notation (`src/semantic.zig:114-119`). There is no native relation from a
form occurrence to an ordered decomposition, no component occurrence ID, no
surface/normalized realization pair, no boundary/span, no allomorph or
feature scope, and no distinction between linear order, source markup order,
and morphological order.

Encoding a decomposition as generic assertions is insufficient. Assertions
have role strings and ordered participants (`src/semantic.zig:203-237`), but
no schema-declared cardinality, ownership, sequence axis, boundary units,
feature alternatives/negation, or form restriction. A value target preserves
text but loses component occurrence identity; an entity target preserves
identity but does not say which form, variant, language, or feature bundle it
realizes. Repeated parts such as `re-re-read`, shared components, empty
boundaries, and nested decompositions cannot be reconstructed reliably from a
set of edges.

Required representation before claiming rich morphology:

* a `FormOccurrence` view over a source node and a `PartSequence` occurrence;
* ordered `PartItem` records with component identity, role, source span,
  surface realization, normalized realization, and optional nested sequence;
* explicit relation identity for `has_part`, `realizes`, `variant_of`, and
  form restrictions, with evidence and source anchors;
* feature bundles as typed alternatives and negated constraints, not strings;
* a declared order policy (source order, rendered order, morphological order)
  and duplicate-preserving sequence semantics.

TEI explicitly groups orthography, pronunciation, hyphenation, syllabification,
and variants under `<form>` and permits dictionary sublevels and mixed content;
the current shape cannot provide those fields natively. The TEI Guidelines
describe these entry levels and the `<entryFree>` model in the
[dictionary chapter](https://tei-c.org/release/doc/tei-p5-doc/en/Guidelines.pdf).
OntoLex's lexicography examples likewise attach multiple `Form` instances and
form restrictions to a lexical sense in the
[Lexicography module](https://ontolex.github.io/lexicog/).

### P0: multilingual semantics are payload strings, not native language data

`Text.language`, `Text.script`, and `Text.notation` are unconstrained UTF-8
strings (`src/semantic.zig:114-119`, validated only as UTF-8 at
`src/semantic.zig:529-534`). There is no BCP 47 validation/canonical form,
variant/dialect identity, direction (`ltr`/`rtl`), language scope, inherited
effective value, or language-profile/version identity. `DocumentNode` has no
language or direction field (`src/semantic.zig:255-261`), and `Source` has no
import profile/default language (`src/semantic.zig:70-73`).

Generic `xml:lang` attributes can retain source bytes, but that does not make
effective-language queries correct: a node with no local attribute needs the
nearest applicable default, while `xml:lang=""` and an explicitly unknown
language must remain distinguishable from omission. The same issue applies to
`xml:base`, direction, notation, responsibility, and field-specific defaults.
No blanket inheritance rule is safe; the profile must declare inheritance per
field and reset behavior.

RDF 1.2 makes the missing distinctions normative: language tags are BCP 47,
case-insensitive for term equality, and directional language-tagged strings
carry `ltr`/`rtl` direction. It also requires datatype IRI and original lexical
form distinctions for literals. See the primary
[RDF 1.2 Concepts](https://www.w3.org/TR/rdf12-concepts/#section-Datatypes)
specification. Store `(original_tag, canonical_tag_id, direction, profile)`;
do not replace the original spelling with the canonical ID.

The language parser agent should therefore produce profile records, not merely
canonical strings: Unicode version, normalization, case policy, segmentation,
collation, transliteration and morphology-pack digests. Generated forms must
carry analysis provenance and be distinguishable from direct source forms.

The new `src/language.zig` is a useful bounded syntax view, and its seven tests
pass, but it is not native multilingual storage. `TextProfile.fromText`
(`src/language.zig:134-140`) parses borrowed fields and returns a temporary
profile; `semantic.Text` still serializes only the three arbitrary strings and
has no direction, profile ID, registry version, or effective-scope slot. The
compact writer consequently cannot preserve the profile that a caller derived.
This remains P0 for a multilingual format claim and P1 for the current
source-oriented model: the missing integration is a representation gap, not a
parser bug. Add a compact `LanguageProfileId`/direction field (with original
tag residual) to the value or a typed side table, then test encode/decode and
inheritance/reset semantics through the same API.

### P0: statement references and graph terms are artificially acyclic

`Target.statement` is restricted to an earlier assertion in
`src/semantic.zig:173-181` and validated with `id.index >= assertion_limit` at
`src/semantic.zig:690-699`. This is convenient for a streaming decoder, but it
is not a general graph representation. Record order is physical layout and
must not change graph meaning. Forward references require a topological sort;
quoted statement terms can be nested and the plan itself promises cycles for
ordinary semantic relations. RDF 1.2 now includes quoted triples as RDF terms
([abstract data model](https://www.w3.org/TR/rdf12-concepts/)), so a compact
format claiming RDF-like richness needs a separate statement-term table with
arbitrary validated IDs, or an explicit DAG/SCC encoding. Do not silently
reject valid data merely because its assertion happened to be emitted first.

The current model also restricts every assertion to at least two participants
(`src/semantic.zig:371-374`, `src/semantic.zig:690-695`). Unary lexical facts
and annotations are common. Cardinality belongs in a schema/profile, with
zero/one/many allowed where declared; a hard global minimum loses information.

### P1: lexical surfaces validate the wrong coordinate space

The lexical view correctly preserves assertion and anchor occurrence IDs, but
`Evaluator.validateAnchor` bounds byte, scalar and UTF-16 spans against the
surface `Value.text.bytes` (`src/lexical.zig:416-437`). A
`semantic.SourceAnchor` points to a source document node and its span; the
semantic model does not define that span as an offset into the derived surface
value. Markup, entities, normalization, a multiword form, or a source node
with no copied text makes the coordinate spaces differ. A valid source span can
therefore be rejected whenever `span.end > text.bytes.len`, while an equally
long surface can make an unrelated source span appear valid.

Reproducer shape: create a source document node for `<orth>bank</orth>` with a
surface value `bank`, then attach a byte anchor covering the source node's
markup (for example 0..16). `surfacesOf` returns `SpanOutOfBounds` even though
the source anchor is within its declared document coordinate system. The
current tests accidentally make the two spaces identical by using a bare node
and the same six-scalar value (`src/lexical.zig:620-629`). The view needs either
an explicit source-text tape/profile that can validate document coordinates, or
an alignment relation declaring that an anchor is a surface-value span; it must
not silently use the value as a document substitute.

### P1: global atom pooling is not always more compact

The v0.4 encoder interns every byte string into one pool
(`src/semantic_format.zig:400-447`) and emits a pool ID for every use
(`src/semantic_format.zig:449-456`). This is semantically safe only because
the surrounding value/field tag is retained, but it is not size-optimal for
low-repetition data. A unique short string pays both an atom length and a
reference; an inline length and bytes would be cheaper. Empty strings are a
particularly clear counterexample: every occurrence pays a pool reference
even though the payload has zero bytes.

For a string used once, with one-byte lengths and IDs, inline storage is
`1 + n`; pooled storage is approximately `1(pool length) + n + 1(reference)`
plus pool/metadata overhead, i.e. at least one byte larger per occurrence.
For two uses, pooling wins only after the second inline length and payload
copy exceed one additional reference. The crossover varies by string length,
ID width, and whether an atom offset index is stored. Build reports must show
the per-domain crossover and support a hybrid: inline atoms below a measured
reuse/length threshold, pooled atoms for repeated values, and separate pools
for text, opaque bytes, language tags and names when that improves validation
or locality.

The pool is also not directly addressable. It stores varint lengths followed
by bytes, but no offset directory or restart checkpoints. Randomly resolving
atom `i` requires scanning all prior atom lengths unless the decoder
materializes an offset array, which reintroduces memory and access cost. Add a
checkpoint every 32–128 atoms (measured) or a compact monotone offset index;
account for checkpoint bytes and binary-search probes in the byte ledger.

### P1: canonical varints are a scalar packing change, not a structural layout

The new helpers (`src/semantic_format.zig:100-117`, `168-188`) reduce fixed
64-bit counts and IDs, but all IDs remain absolute and all collections remain
arrays of individually tagged records. In a million-record relation, a
3-byte absolute ID plus tag/role reference is still several bytes per edge;
the same sorted target list can use delta coding or Elias–Fano. The plan's
“shared atom pool + canonical varints” should therefore not be described as
maximal compactness. It is a baseline to measure.

The highest-return next layout is a typed column-group directory with
owner-local adjacency: `(owner_start, owner_count)` boundaries, predicate and
role dictionaries, delta-packed sorted target IDs where order is not
semantic, and a separate permutation/order stream where order is semantic.
For `E = 1,000,000` edges and IDs below `2^20`, fixed `u32` targets cost
4,000,000 bytes. Four-byte absolute varints have the same cost; delta values
with an average gap below 128 can approach 1,000,000 bytes plus a sparse
exception stream. A 32-bit owner boundary array for 100,000 owners costs
400,004 bytes; Elias–Fano is only attractive after counting its select/rank
directory and access cost. Forward access remains O(1) per target with a
boundary lookup; reverse access needs a measured posting/select index. This is
the first structural experiment to run, with actual role/order/fanout corpora.

Do not delta-code a semantically ordered sequence without retaining its order.
Participant order is currently meaningful (`src/semantic.zig:203-207`), and
parallel assertions/evidence occurrences must never be sorted into equality.

### P1: pooling does not provide direct queryability or lazy integrity

The compact body is one sequential stream after a 112-byte header
(`src/semantic_format.zig:337-374`). Header counts are fixed-width, but there
are no section offsets/lengths for values, entities, documents, assertions or
the pool. A reader cannot seek directly to a sense, form-part sequence, or
relation column without parsing all preceding records. The plan requires
directly addressable searchable structure and bounded payload work. Use a
small section directory (offsets inferred from the next section where
possible), then keep per-section counts and optional restart maps. The added
directory bytes are negligible for large snapshots and buy lazy open, page
fault locality, corruption isolation, and parallel decoding.

Likewise, the single body checksum forces a whole-body verification before
safe lazy use. Section digests allow a key lookup or relation query to verify
only the pages it touches, while a root digest/signature remains available for
full authentication. Report both integrity modes and their bytes.

### P1: schema and extension identity are still fixed-enum/opaque

`EntityKind` is a closed enum with `other` (`src/semantic.zig:34-54`). A
user-defined TEI/OntoLex class or predicate cannot be represented as a typed
kind without being demoted to generic assertions/attributes. A compact format
can use a schema dictionary: built-ins are small local opcodes; extensions are
QName/schema IDs with declared cardinality, target domains, inheritance and
ordering. Unknown extensions must retain their generic source node and
extension envelope so a newer reader can reinterpret them without a second
semantic copy.

### P1: names and values conflate lexical and semantic identity

`QualifiedName` retains a source prefix, but `qualifiedNameEqual` compares the
prefix as part of value identity (`src/semantic.zig:107-112`,
`src/semantic.zig:1040-1048`). Prefixes are aliases, not expanded-name
identity. Conversely, a language tag's original spelling may be important for
provenance while canonical matching is case-insensitive. The model needs dual
identity: canonical expanded QName/language IDs for joins and a lexical
residual for source reconstruction. Do not force the compact atom pool to
choose between deduplication and fidelity.

`Value` also has only an ordered `sequence` (`src/semantic.zig:134-151`): set,
bag, null-like extension values, RDF datatypes, direction, original numeric
lexical forms, and time/calendar values remain absent. The fidelity audit
already lists these as P0/P1 gaps; compacting the current union does not close
them.

### P2: query validation and model invariants still need adversarial closure

The graph traversal revalidates every assertion for every queued source node
(`src/query.zig:293-304`), adding repeated CPU cost on a fan-out graph. More
seriously, malformed public models can pass query validation for unresolved
targets and attribute names because `validateAssertion`/`validateAttributes`
do not validate unresolved URI/UTF-8 or QName local-name rules at
`src/query.zig:432-465`. If the model is a trusted post-builder object this
can be documented; if it is a decoder boundary, reject the same malformed
states as the builder.

The formerly identified nested source-node anchor scan is resolved in the
current query implementation: `anchorMembership` builds one query-local bitset
and charges the aggregate entity/assertion plus-anchor scan and temporary bytes
(`src/query.zig:398-418`). The regression `source-node semijoin charges
aggregate scan work and temporary bits` passes in `zig test src/query.zig`.
Keep this as a permanent budget test when an indexed implementation replaces
the reference scan; the limit must cover both CPU work and private bitmap
memory.

The new lexical and scoped views have a related accounting hole. Their scan
counters charge one unit per assertion (`lexical.collectEdges` and
`collectSurfaces`, `src/lexical.zig:320-399`; `scopes.collectField` and
`findParent`, `src/scopes.zig:214-285`), but each matching assertion then scans
every participant in `uniqueRole`/the role loops. A public model can contain a
very large participant slice while `max_scan_items` is one, so the advertised
CPU bound is not a bound on actual comparisons. `decompose` repeats this work
for each occurrence. Charge participant visits (and role-byte comparisons if
the limit is intended to be CPU rather than row based), or build a validated
role-position index and charge index construction/reads. Add a fixture with a
single assertion containing many unrelated participants and a budget below
that participant count; otherwise the bounded-query claim is overstated.

`Builder.validateDocuments` also checks only that a parent has *some* matching
child (`src/semantic.zig:790-805`); it does not reject duplicate occurrences
of the same child in a manually decoded/public model. `appendChild` prevents
this through the normal API, but a decoder that appends raw arrays and any
caller-constructed `Model` can bypass that invariant. A duplicate child is
semantically meaningful only if the model explicitly declares repeated child
occurrences; for document-node children it should either be rejected or
represented as an occurrence list with the declared multiplicity. Add a
duplicate-child check in final validation and a malformed-model query test.

This is reproducible without unsafe pointer tricks: create a child with
`parent = root`, append the same `.node = child` twice directly to
`builder.documents[root].children` (the normal constructor already contributes
one link), then call `build()`. It succeeds and retains three links because
the color walk skips a node already marked `2`; a final validator must either
reject the duplicate or make occurrence multiplicity an explicit schema fact.

## Word-part and multilingual acceptance matrix

Before compactness tuning, pin a fixture with the following independent
dimensions. The fixture must compare a semantic digest and query results, not
just byte equality of the current model:

| Dimension | Required adversarial cases | Required result |
|---|---|---|
| Parts | repeated component, empty component, nested part, shared component, multiword form, affix, clitic, allomorph | occurrence identity, sequence order, boundaries and owner survive |
| Form fields | orth, pron, hyph, syll, variant, oRef/pRef, notation | each field has typed owner and source anchor; no flattening |
| Features | alternatives, negation, inherited default, local exception, feature restriction to one form | effective query result plus original scope survive |
| Languages | `sr-Latn`, `sr-Cyrl`, `tr`, `de-CH`, private-use/extension tags, invalid tag, mixed-language definition, Arabic RTL | original spelling, canonical ID, script/region/variant, direction and scope survive |
| Unicode | NFC/NFD pair, combining marks, grapheme clusters, bidi isolates, supplementary-plane characters | source bytes remain distinct; profile-specific search keys are explicit |
| References | forward statement, nested quoted statement, cycle, unresolved URI/label, duplicate external IDs in two sources | identity, status, source scope and order survive |

An acceptance fixture containing only one `form` node or one language does not
establish support for this matrix.

## Highest-ROI structural next step

Implement the compact reader and semantic-digest differential harness first,
then benchmark a hybrid `atom-or-inline` pool plus owner-local relation columns
against the current v0.4 stream. Keep the pool for repeated long strings,
inline unique short strings, add pool checkpoints, and encode relation IDs as
delta streams only where order semantics permit. Record total bytes including
pool references, checkpoints, section directory, exception streams, and
reverse access structures. Record forward/reverse CPU, bytes touched, and
decoder memory. Reject the change if it saves payload bytes but makes random
form-part or relation access scan an unbounded prefix of the snapshot.

This experiment has a falsifiable byte/access objective and directly addresses
the largest remaining structural waste. It does not justify an order-of-
magnitude claim until the full corpus matrix, equal semantics, cache regime,
and baseline accounting in `docs/fidelity-and-performance-gates.md` pass.

## Regression and redundancy ledger

The caught defects need a named regression, not a nearby success case. The
current root fixes are covered as follows; all listed builder/query fixes pass
in the current Debug test runs, while decoder-local ownership remains open.

| Defect and former trigger | Regression currently present | Status |
| --- | --- | --- |
| Processing-instruction target leaked when child-vector append failed | `semantic builder survives every injected allocation failure`; the fixture appends 40 PI children after allocating each target (`src/semantic.zig:1341-1373`) | Passing builder regression; does not cover decoder PI construction |
| Transferred roots/anchor slices leaked on later model-build failure | The same failing-allocator fixture transfers roots plus entity and assertion anchors before `build` | Passing builder regression |
| Evidence QName with namespace 99 reached final validation | `evidence rejects invalid qualified attribute names at insertion` (`src/semantic.zig:1375-1392`) | Passing |
| Existing source-B document could be linked below source-A parent | `appending an existing document cannot bypass source ownership validation` (`src/semantic.zig:1394-1405`) | Passing |
| Source-node filter charged N and M but performed N*M anchor comparisons | `source-node semijoin charges aggregate scan work and temporary bits` (`src/query.zig:751-775`) | Passing bitset/work/temporary-memory regression |
| Attribute result budget used `count + sizeof` rather than `count * sizeof` | `attribute byte budget charges every result structure` (`src/query.zig:777-799`) uses two attributes and a threshold just below exact copied structure plus QName bytes | Passing |

The full list is mirrored in
[`regression-matrix.md`](regression-matrix.md). The compactness ledger in
`docs/compactness-research.md` correctly keeps published bytes, build memory,
and query-private memory separate, including the semijoin bitmap. It must also
add decoder-private allocations and atom-offset/checkpoint memory before any
published-size ratio is reported. The open PI decoder, legacy namespace-prefix,
legacy value/sequence, and legacy attribute paths above currently have no
dedicated regression; they are not allowed into a “no leaks” claim.

## Unimplemented checklist

* v0.4 compact decoder allocation-failure and malformed-pool suite, plus legacy nested cleanup regressions;
* hybrid inline/pool policy with measured crossover and pool offset checkpoints;
* typed lexical views for form/part/feature ownership and restrictions;
* native language/profile side table integrated with values, source/profile manifest, and declared per-field inheritance/reset rules;
* validated, source-preserving BCP 47 tags, script/region/variant and direction in the compact model;
* RDF datatype/original lexical forms, set/bag semantics, and arbitrary statement terms;
* extension schema dictionary with unknown-envelope preservation;
* section directory and lazy per-section integrity/access contract;
* source-tape versus surface-value anchor coordinate contract;
* held-out multilingual/morphology corpus and byte ledger including every index,
  restart/select directory, reverse relation map and temporary memory;
* explicit failure of claims (“all relations”, “10x”, “max compact”) when any
  semantic or corpus cell is unsupported.
