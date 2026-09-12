# LEX5: occurrences, columns, projections

Root design, 9 September 2026. This is an implementation contract, not a claim
that a new format has already met its correctness or performance gates.

The user has redirected the work to a fresh `src5/`. Preserve `src4/`, including
its interrupted rewrite, without further edits. The measured control remains
the immutable `experiments/frontier/unification-20260908/final/source`, not an
arbitrary intermediate checkout. Existing `build4.zig`, `bench4/`, `src/`,
`src2/`, and the Nix files remain untouched.

## Current evidence and next structural decision

The Foundation-16 implementation passes its focused correctness gates but is
**not performance-admitted**. Its five native artifacts total 679,052 bytes
versus the accepted old implementation's 270,184 bytes, and the independently
audited native campaign still loses startup/query/rendering cells. Reduced
implementation size is not a substitute for those missing gates.

The next design removes ownership and lowering artifacts rather than adding
feature-specific codecs: one stable reader owner with borrowed coordinates;
typed inhabited populations instead of padded values plus global child edges;
and a shared spelling authority for keys and other strings. Precise current
wire, query, adapter and experiment briefs are retained under
`experiments/frontier/lex5-20260909/`. These are hypotheses under hostile
review, not integrated capabilities. The first path-language experiment lost
query latency despite smaller sections. Its projected-coordinate successor
now has an independently audited, balanced-workload 50-invocation campaign:
all five fixtures improve exact/prefix and rendering operations against the
separate Foundation-15 string/key bodies, while rich verification is 3.6%
slower. Combined sections shrink from 35,895–71,811 B to 26,823–31,545 B.
See `reviews/path-projected-timing-root-decision.md` in the experiment root.
This makes one shared spelling language the preferred integration candidate;
it does not prove full-artifact or accepted-old-format parity.

Natural lexical transfer adds a material caveat: source-discovery string order
produces 173,042 B in the projected body versus 168,046 B in the control. The
sorted-oracle win relied on a nearly free identity permutation. The complete
evidence is retained in `reviews/natural-lexical-root-decision.md`; integration
remains gated. Root is testing incremental graph construction for build memory
and an explicit canonical artifact-local string-coordinate contract, not
hiding the original-order regression or renumbering physical semantic rows.

All semantic requirements below remain binding. Experiments may change the
representation and ownership model, not reduce the rich model or alter the
old benchmark workload. The requested Sol production rewrite follows root's
source review and measured decisions, not an untested proposal.

The isolated final rewrite is now authorized under
`experiments/frontier/lex5-20260909/rewrite-candidate/`; live `src5/` remains
the frozen-comparable Foundation-16 until the candidate passes review. The
implementation contract is `FINAL-REWRITE-DISPATCH.md` in that experiment root.
The owner-reader preflight has independently matched 40,000 queries. Typed
population adapters have produced real whole-section reductions, alongside
a small ordinary-entity regression. Neither result is an integrated-format
performance claim. The first owner timing attempt failed before any query
because its harness rejected the additional ownership fields in Ready; that
failure remains retained. The corrected, pinned campaign completed on
12 September with all 230,000 observations independently audited. Against
Foundation-16, median paired reader-time ratios were 0.856–0.891 for exact
queries and 0.704–0.856 for prefix intervals. Enumeration ranged from
0.823 to 1.000; rendering and snippets were effectively unchanged or slightly
slower. Fresh-process, warm-filesystem startup ranged from 0.977 to 1.110,
and rich translations regressed to 1.048. These results support small borrowed
handles, not a blanket performance claim or parity with the accepted old
format. The complete audit is retained as
`reviews/checked-owner-timing-root-audit.json` under the experiment root.

## What must actually change

The last attempt shared some parsing functions but retained nearly every
feature-shaped subsystem. Its independent accounting still showed only about
2% fewer production tokens after the rich-content work. That is not the
structural result requested. Starting another directory is not itself a fix.

LEX5 organizes around three authorities:

1. An **occurrence** is a position in an ordered document. Its expanded name,
   attributes, content and scoped source identity describe that occurrence.
   Semantic roles belong to explicit record bindings. A lexical tree and a
   rich-content tree must not separately assert its parentage.
2. A **record** is a typed product of values and references. Zig types define
   its columns, optionality and reference domains. A claim is a record, not a
   separate hand-written serialization subsystem.
3. A **projection** indexes records or occurrences in another order. Keys,
   terms, memberships and adjacency differ in their declared laws, not in
   their ownership, range, source, cursor or validation machinery.

Four workloads remain genuinely different: byte-key automata, ordered rank
sets, measured repeated shapes, and byte-emitting grammars. The tested shared
measured-program walkers, including the explicit-inline follow-up, were
rejected by their measurements; they are not integrated. A future shared
abstraction must be judged by the model's clarity, flexibility and invariant
ownership, then full-system measurements; a selective function line count is
not an architectural argument. Compressors are finite physical alternatives,
not public feature architectures. Do not introduce a universal runtime
interpreter merely to give different workloads the same name.

## 1. The occurrence model replaces two trees and text-owner machinery

One ordered expanded source-event sequence owns parentage and child order;
preorder occurrence ranks and subtree ends are derived measures. Open/close
events delimit occurrences; text, comments and processing instructions are
atoms, and an input child event expands to its entire balanced subtree.
Occurrences can be named or anonymous. Named unknown extensions are first-class
occurrences; the finite lexical `Kind` enum is an accelerator category, not the
universe of XML tags.

Repeated **shapes** intern the structural part of source subtrees and the shape
of their field spans. Verified binding projections may add kind measures.
Variable values live
in columns. A flat lexical entry must therefore still pay for one repeated
shape, not three uncompressed records per entry. Rich names, attributes,
namespace declarations and ordered text/comment/PI events use the same record
and span machinery; empty/default columns occupy no payload.

There must be no second rich parent column independent of the shape parent.
An occurrence is NOT necessarily one lexical entity. Entities are typed
records; repeatable bindings connect zero/many occurrences or content subspans
to a record, and several records may be grounded by the same occurrence.
Unanchored normalized records and external sources are not invented tree nodes.
The common one-to-one ordered binding can derive typed ranks from shape prefix
measures only after that correspondence is proved. It is an optimized
projection, never the general semantic authority.

Use **cumulative ends** for zero/one/many ownership. A constant one-item span
is the affine sequence `end(i) = i + 1`, with no per-owner payload. This must
serve text items, attributes, namespace declarations, children and grouped
targets. Do not add special text-map records with both first and count, or an
owner column when ordering already determines the owner. Stored auxiliary
subtree ends or checkpoints are justified indexes, not semantic authorities.

Construction receives one coherent document/record input and derives ordering
and all projections. Do not require callers to manufacture matching forward
and inverse tables. A low-level assembly API, if retained, must use the same
declarative validation as normal construction.

In particular, document/element **child events alone** define containment.
Do not accept an independently supplied `parent` next to those events. The
compiler derives parents, preorder and subtree summaries, rejecting reused
children, cycles and unreachable occurrences. Similarly, do not accept a
separate `TextInput` array beside rich content. A plain definition owns one
ordinary text event; zero/many text events and inline children use that same
content stream. This deletes two source inconsistencies rather than adding
another consistency verifier for each.

Physical key order is not source document order. If entry blocks are physically
sorted for faster lexical queries, preserve document order as an explicit
ordered projection and charge its bytes. The identity case can be implicit;
an arbitrary source permutation is real information, not removable overhead.
The semantic audit in
`experiments/frontier/lex5-20260909/semantic-audit/REPORT.md` supplies five
concrete counterexamples and is incorporated below.

### Semantic boundaries that the single tree must not erase

- A wrapper named `entry` need not denote a lexical entry. A related lexical
  entry may occur inside it. Raw source parentage does not automatically imply
  a semantic `hasSense`/`partOf` fact or satisfy the lexical parent graph.
- Source descendants operate on source scopes. Semantic relation traversal
  operates on typed records and claims. Both use the shared projection/cursor
  machinery; neither may silently stand in for the other. Any shorthand that
  fuses them requires an explicit proved correspondence.
- Bindings use a reusable target: an occurrence or a half-open span of its
  content events. Overlapping stand-off spans remain distinct. Do not invent
  synthetic XML children to represent annotations or a separate parent tree
  for semantic records.
- A document/source scope plus its `xml:id` value identifies a named source
  occurrence. Same-scope duplicates reject; the same value in different
  document scopes is legal. Anonymous or equal-valued occurrences retain
  distinct ordinal identities. Source-ID lookup must include scope or report
  ambiguity, not select an arbitrary document.
- Language results preserve both decoded value and declaring owner. Explicit
  empty `xml:lang` is a reset, not absence. The namespaced attribute is the
  authority; any effective-language column is a checked projection.

### Rich semantics are an independent acceptance gate

Event preservation alone is not a sufficiently rich lexical model. TEI's
dictionary guidance distinguishes source presentation from lexical information
and allows grammatical and other constituents at several entry/sense levels.
The format must preserve their relationship without making source parentage
the authority for normalized semantic records.
See [TEI Dictionaries](https://www.tei-c.org/release/doc/tei-p5-doc/en/html/DI.html).

The semantic layer must expose structured feature values, shared references,
and the distinction between ordered lists, sets and bags. Alternatives,
negation and unspecified/default values must remain distinguishable; a
`features: ?[]const u8` field is not a substitute for typed access. Representation
and querying do not imply implementing a complete feature-unification engine.
These requirements are grounded in [TEI Feature Structures](https://www.tei-c.org/release/doc/tei-p5-doc/en/html/FS.html).

Likewise, uncertainty may qualify a particular aspect of a target, not just
assign a small confidence enum to an entire record. Preserve the target,
locus, declared value/degree and conditional reference when present; do not
silently coerce unsupported labels into a supported category.
See [TEI certainty](https://www.tei-c.org/release/doc/tei-p5-doc/en/html/ref-certainty.html).

Use the generated product/sum codec, typed reference catalogue, ordered spans
and physical claim identities to express these capabilities. Do not append a
serializer family for every TEI element or hide unhandled structure in JSON.
The semantic audit maintains executable distinctions and separates source
losslessness, typed semantic access, reference resolution and inference. The
old five benchmark fixtures stay unchanged; additional richness tests do not
replace them or make their workload larger to disguise a regression.

Concretely, one `ValueId`-referenced tagged value graph represents atomic
strings/symbols/booleans/integers/exact decimal lexemes, named products, ordered
list/set/bag members, alternatives, negation, defaults, unknown and unspecified
states. Shared references retain identity. Ordered member rows preserve bag
duplicates; an ordered set of physical claim IDs is not a semantic value bag.
There is no requirement to evaluate feature unification or probability models.
The context-dependent default marker need not point at a resolved value;
default declarations remain separate structured data. Do not fabricate an
operand for a source `<default/>` marker.
See [TEI default values, §19.9](https://www.tei-c.org/release/doc/tei-p5-doc/en/html/FS.html).

One physical `FactId` path relates records, values, claims and source targets.
Declared predicates and typed products can describe uncertainty, citations and
ordered analyses without a new serializer for each construct. External keys
have a declared named identity domain, local-document or named external scope,
and a numeric/text key. Resolution is explicitly resolved or unresolved.
An unresolved external key is queryable data; an unknown local rank domain is
a verification error. External identity namespaces are not limited to the
finite lexical `Kind` enum and do not require fabricated document occurrences.

Both relation endpoints use the same target algebra. A certainty statement can
therefore target an actual `FactId`, without inventing an assertion entity to
stand in for a claim. Common typed qualifiers may retain compact hot columns;
one optional properties-product supplies open metadata such as ordered stages
and provenance spans. This is the existing value graph, not another serializer.
An alternative value denotes exclusive alternatives and requires at least two
members; the tag carries that law without a redundant exclusivity boolean.

Predicate declarations must constrain both ends of a relation, not merely
store its spelling. One endpoint constraint algebra (`any`, a specific or any
record kind, value, fact, occurrence, span, or external domain) is matched
against the existing typed Target. Both endpoints use the same matcher; a
certainty fact does not receive a separate validation engine. An omitted
constraint explicitly means unconstrained, not an inferred restriction from
the first observed fact. Preserve declarations in the artifact even when a
predicate has no uses.

External identity domains likewise declare key type and allowed scope policy.
Explicit finite scope/key declarations must survive storage and be queryable;
absence of a finite declaration is distinct from an explicitly empty one.
Use generated rows and the shared grouped-coordinate machinery for variable
declaration members, not custom per-domain wire formats. An unresolved key may
be valid in an open domain; it is not permission to violate the domain's key
type or scope. Numeric `42` and text `"42"` are distinct identities.

The exact-decimal contract is `[+-]?(0|[1-9][0-9]*)(\.[0-9]+)?` with the
original lexeme retained, including trailing zeroes. Validate it without a
floating-point roundtrip. Named products expose one value per field name;
reject duplicate names rather than silently choosing the first. Structured
lists/bags remain available when repeated named entries are actually intended.
These are native validation gates, not claims already established by positive
roundtrip tests. The M1–M4 source/value probes do not by themselves prove them.

Normalized records need not have a source realization. The old five benchmark
fixtures supply definition fields but no source documents: their adapter's
synthetic lexical forest must not be presented as real XML. Definition text and
the explicit homograph flag lower to typed record properties, not fabricated
source nodes. Inverse sense/concept arrays are checked projections of their
coherent facts. Real TEI source queries are tested separately on real events.

### Record kinds are coordinates, not codec families

All lexical records share one extensible property shape. `written` and `label`
remain distinct optional fields; language, grammatical category, typed features,
type label and external identity are available to every kind. A bibliographic
source or concept must not lose structured metadata because its original
implementation happened to have a smaller struct. Additional semantics belong
in the same typed value graph, not an expanding collection of payload codecs.

The tagged construction input assigns each record its typed coordinate. The
compiler stably partitions records by kind, preserving each kind's input ordinal,
then stores one property table and cumulative kind ends. `record(kind, id)`
addresses `kind_start + id` directly. No per-row kind tag or per-kind reader
descriptor is needed: the partition supplies that information. The complete
directory is charged to the artifact and checked against row counts and declared
domains. This is a representation invariant, not a cache or a benchmark-only
shortcut; source occurrence order remains a separate authority.

Readers expose that partition as `book.records(comptime kind)`. The returned
table accepts only `Ref(kind)` coordinates and resolves its checked physical
bounds once. Projecting a field preserves the typed coordinate. Typed slices
also preserve logical identity: slicing `[ref5, ref10)` keeps `at(ref5)` valid
and rejects `at(ref0)`; it does not silently rebase record ranks. Empty owned
kinds and external-only rank domains return no fabricated physical rows.

## 2. A generated product codec, not handwritten wire structs

`Records(Row)` lowers a Zig struct into scalar leaves at comptime. Supported
forms must include signed and unsigned integers, booleans, exhaustive and non-exhaustive
enums, nested structs, fixed arrays, optional records, and typed references.
Add tagged unions by deriving the tag and variant leaves; inactive leaves must
be canonical zero. Do not represent a tagged union as independent optional
fields at public boundaries.

Union payload columns are **overlaid compatible slots**, not the concatenation
of every variant's leaves. In particular, the generated heterogeneous reference
union has a tag and one rank lane, not 23 optional rank columns. The active tag
determines semantic reconstruction and reference validation; unused payload
slots are canonical zero. Derive the payload shape and variant-to-slot map at
comptime. This shares physical storage without erasing the semantic Zig types.

The input-to-stored type transform preserves nominal identity whenever none of
the children changes. An `AnyRef` already contains stored typed coordinates;
rebuilding it as an anonymous union would needlessly create an incompatible
type and discard declarations. Derive transformed child types once, returning
the original parent type if all are unchanged. The lowering operation then
returns such values directly. This is also the rule for unchanged structs,
arrays and optionals, not a growing list of reference-specific exceptions.

The same generated traversal must drive scalar extraction, row reconstruction,
named-field access, canonical validation and reference visiting. Avoid five
independently recursive interpretations of `@typeInfo`. A small compile-time
leaf descriptor with field paths is preferable when it genuinely removes
those recursions. Use `std.meta.FieldEnum`, `std.enums.EnumArray/EnumSet`,
`std.meta.fields`, `std.meta.activeTag`, `std.MultiArrayList`, and standard
maps where appropriate, not custom lookalikes. Keep the resulting source
readable: no anonymous metaprogramming puzzle to save twenty lines.

Each scalar column uses one descriptor and measured physical alternatives.
An affine predictor plus residuals covers absent/constant/identity/packed
values without separate public types. Runs and genuine checkpointed rANS
remain available when their **complete descriptor + table + checkpoints +
payload** beats the packed alternative. Sequential decoding and verification
advance the same cursor; do not seek afresh for every value. Special monotone
or boolean measures may use the rank-set kernel below.

Ordinary signed identifiers must not require an application wrapper. Flipping
the sign bit of their fixed-width unsigned representation gives an order-
preserving unsigned coordinate, so the same affine/residual machinery can
encode signed and unsigned integer fields. This is a compile-time scalar
conversion, not a second column codec; zero-bit types require their trivial
specialization. Charge any descriptor cost in candidate selection.

The schema knows which fields are references. `Ref(.sense)` cannot accept an
entry rank. Runtime heterogeneous references use a proper tagged value, and
`?Ref` is one optional value. No sentinel rank in an otherwise valid public
reference, no separate presence flags at the API. Verification visits these
references once against the schema's domain catalogue.

### One type traversal owns the active shape

The initial compiling scaffold had separate shape counting, leaf-plan,
variant-plan, flattening and reconstruction walks. Foundation07 replaces them
with the shared shape/transfer mechanism below. A flat variant descriptor with only one selector is
insufficient for nested sums: an inner selector has meaning only under its
outer variant and optional-presence guards.

Use a comptime `Shape(T)` to own physical width and field offsets, and one
direction-specialized transfer over that shape. Products and arrays advance
one lane coordinate; an optional visits its payload only when present; a sum
visits only its selected payload. Both finish at the statically known payload
end. The access policy writes zero padding, checks canonical padding during
verification, or skips already-verified inactive lanes during querying.
Scalar encode/decode are genuine inverse operations and may remain separate
small functions. Repeating the entire recursive type interpretation is not.

Field reading starts the same transfer at the field's derived offset. Reading
should fetch active scalar lanes on demand, not first load every union overlay
slot into an intermediate array. Reference verification belongs to that same
active scalar operation. This naturally carries all enclosing guards and
prevents a metadata plan from disagreeing with the actual decoded variant.
Do not keep unused flat-schema introspection machinery merely to claim that a
schema exists. Preserve signed tags, non-exhaustive enums, zero-bit integers,
null payload canonicality, nested optional unions and source-error tests.

## 3. One grouped-rank kernel and one projection combinator

`Groups(Target)` represents a sequence of ordered target sets, including empty
sets. The shared cumulative-end mechanism locates a group; one cursor implements
membership/lower-bound/iteration with codec specialization. Compact alternatives
include intervals, gaps, runs, bitmap and Elias–Fano, selected from actual full
wire costs. Preserve the useful signed-singleton-stream optimization as a
general group-stream predictor if it still wins; it is not a terms-only class.
Dense/sparse/RRR bit rank/select must reuse this ordered-coordinate machinery
where the algorithm is the same, not create another owned in-memory family.

A string projection is a key automaton plus Groups. A rank projection is a
sorted coordinate key plus Groups. If the declared mapping is the identity,
targets are implicit. If every group has one target, that follows from data
and a proven law, not a headword/term/concept-specific format flag. Homographs
and forms must retain their distinct semantics; no assumption that key rank
always equals entry rank.

Do not repeat the rejected GRP1 experiment: ordinary fixed per-group headers or
generic affine tables for every posting list regressed all five full artifacts.
Share the kernel and compact streaming directory, not that rejected wire.

Facts retain their physical record identity. Their adjacency projections index
record ranks, so two qualified claims with equal endpoints remain distinct.
Functional membership is a **proven projection property**, not a separate
membership authority that silently rejects or loses richer claims. Generate
incidences from the relation declaration once for build and validation.
Symmetric self-loops have one incidence; inverse pairs have their exact two
orientations; explicitly asserted versus inferred directions remain distinct.
Strict injectivity + admissibility + exact cardinality proves completeness;
do not add a binary search for every expected incidence.

## 4. One query protocol, with proofs in types

The decisive boundary is **records → sources**, not another kind-rank wrapper.
One sense can have realizations under unrelated entries A and B. If a query
through A collapses its selected source to a sense ID, its next descendant hop
can accidentally re-expand B. Keeping entity IDs plus hidden witnesses through
every operator is avoidable complexity. Therefore `lookup` returns typed record
hits with origin, `.sources(role)` explicitly selects their source anchors, and
all subsequent structural descent remains in source coordinates. Relations
between entities remain record/fact projections.

Whole-occurrence anchors contribute their content intervals in the expanded
event coordinate. Owner-local direct-content spans map to exact intervals in
the same coordinate: a selected child event contributes its whole subtree,
not all of the owner. These are balanced forest intervals, so traversal can
skip measured fragments without cutting an unselected child's structure.

Normalize sorted disjoint **coverage runs** inside the traversal core. Keep
matched occurrence/span handles as actual results, including empty elements:
an empty content interval is not absence of an occurrence. A descendant
operator turns each preceding handle into its exact content scope; a span seed
provides its exact expanded interval. A small generic handle producer plus one
shared scope-range adapter is preferable to forcing every semantic result into
a run of record IDs. Binding projection is explicit, never an implicit
conversion that re-expands unrelated record realizations.

`descendants(.sense)` matches whole-occurrence realization
bindings and returns source occurrences. Stand-off spans do not pretend to be
XML descendants. One projection exposes both kinds of evidence:
`source.bindings(.sense, .attached)` selects physical bindings on exact matched
handles; `source.bindings(.sense, .within)` includes those and contained whole
or span anchors. Both return `{ record, anchor, binding_id }`. The latter uses
exact event containment, with an eligible owner equal to the selected owner or
wholly inside its source scope. Empty spans use closed boundary containment
while retaining owner identity. Selecting an ancestor and child emits a given
physical binding once; equal anchors with different binding IDs remain distinct.
Binding projection order is source-coordinate order, not input binding-row
order: event start, owner, occurrence-before-span tag, event end, then physical
BindingId. This is the same canonical order used to select source handles;
it does not change the BindingIds themselves. Fact adjacency remains ordered
by physical FactId. Tests must assert these declared orders rather than the
incidental order of a provisional table scan.
`uniqueRecords` is the explicit deduplicating terminal. Do not keep provisional
`records`/span-only `anchors` forwarding APIs beside this one projection.

Grouped record sets still use typed `nextRun`; physical claims and source
handles use their appropriate identity-preserving cursor. Materialization is
explicit with caller storage. Do not reproduce `NodeSet`, `Set`, `Ranked`,
`StoredRanks`, `Below`, and nearly identical iterators. Shared mechanics should
follow genuine laws, not erase the distinction between set coverage and a
physical occurrence or claim. No query-sized answer cache.

The schema's one lexical parent declaration derives reachability and dominance
at comptime, but applies only to a verified lexical structural projection. It
must not reject arbitrary raw XML wrappers or justify a shortcut across them.
Only verified correspondence and topology permit path erasure. A sparse
selection of nested senses must not expand to the bounding entry interval.
Chained source entry→sense→definition may simplify only when those laws prove
it; sense→subsense→definition must not include the outer definition. Internal
kind measures accelerate source navigation, but do not change the public
coordinate or invent semantic parentage.

An occurrence can realize records of several kinds. Its navigation classification
is therefore a set of realized kinds, not one exclusive `Kind` tag. Count an
occurrence once for each qualifying kind, even if several physical realization
bindings of that kind point to it. The physical bindings remain distinct in
binding projections. Any compressed shape measure must be checked against this
derived classification and the actual source events; a single-kind experimental
fixture does not establish the general correspondence law.

Runs are half-open `[lo, hi)`. `next` below yields text occurrences; source
handles and claims preserve their respective identities.
Descendants are strict: they exclude their own selected parent, but selecting
an ancestor and its child still includes that child when it is a descendant
of the ancestor. Every chained operator restricts to the immediately preceding
selection's scopes. Distinct Book mappings must not silently compose as one
selection merely because their rank values happen to be equal.

Headword versus form origin remains observable on lookup hits. A single target
per group proves a physical singleton, not a semantic identity mapping. The
identity case additionally proves coverage and correspondence to actual entry
identities; homographs may share a headword and retain distinct entry records.

A key selection may project its physical rows through the same bounded table
mechanism. For example, `selection.project(.{.origin})` reads only the typed
origin column. Its projected row zero is relative to the selection, while the
selection's existing half-open hit range retains the absolute physical bounds.
Whole rich hits remain available when callers need key Text or form targets;
an origin-only consumer does not construct them eagerly.

Preferred public shape (exact names can be adjusted once before test adapters):

```zig
var opened = try lex.open(mapping, .{ .trust = trust_bits, .limits = limits });
const book = try opened.validate(allocator);
const definitions = (try book.lookup(.{ .prefix = "ban" }))
    .sources(.realization)
    .descendants(.sense)
    .descendants(.definition)
    .texts();
var iterator = definitions.iterator();
while (try iterator.next()) |text| {
    const bytes = try text.render(output, frames);
    use(bytes);
}
```

Selections are reusable immutable plans; `iterator()` creates the consuming
cursor. Do not put `next` or `nextHandle` on the selection as well. A caller may
inspect lookup hits and still project the original selection to source anchors
without silently losing the inspected entries. Low-level column/group cursors
remain conventional stateful iterators. Plans and cursors have different jobs,
not duplicated aliases for the same state.

Ordinary handles borrow the mapping capability by value. Do not force a stable
address for a giant self-referential Snapshot. A caller must keep mapped bytes
and any trust bitmap alive and immutable as documented; moving the book value
must not invalidate its handles. Lazy proof state must have explicit ownership,
not point into a movable optional union arm.

The producer chain holds its read context once, at its root. A descendant or
text adapter owns only its parent producer and its own small cursor state;
it obtains the context through that parent when called. It must not embed a
fresh copy of the topology, string and binding descriptor arrays at every hop.
One source-selection wrapper defines the public combinators, while concrete
producers implement their distinct traversal. This shares real control-flow
and lifetime laws without storing pointers into movable selections. Measure
the complete multi-hop value footprint and generated hot paths as well as
source complexity.

Normalize selection geometry before filtering. A validated direct-content span
denotes a contiguous preorder occurrence interval: use the monotone event-open
coordinates (or the shape program's checked occurrence measure) to seek its
first and final candidate. Do not rescan every occurrence in the dictionary
for each span. An occurrence's descendant interval is already available from
its preorder rank and subtree end. These are two inputs to one bounded range,
not two independent filtering engines. Empty spans must produce an empty
descendant interval while their exact source handles remain representable.

A kind filter is a classification SET induced by realization bindings, not a
single enum on an occurrence. If a derived kind-to-occurrence projection is
needed for latency, build and verify it with the existing ordered projection
law, deduplicate occurrences there, and intersect its ranks with the bounded
source range. Keep physical BindingIds separately. Charge the projection in
the whole artifact; do not add it merely to avoid a short loop. This remains
a query optimization gate, not a claim about the current scaffold.

## 5. Derive framing; retain useful query measures

One checked layout builder allocates consecutive extents from independent
counts and sizes. Use it for writing and opening. Do not serialize offset,
length and end when counts and the preceding extent already determine them.
The completed grammar experiment removed 56 bytes of dependent header fields;
its result must be checked before admission, but the layout law is general.
An outer archive directory describes heterogeneous extents once; inner column
tables must not each pay another magic/version/total/directory unnecessarily.

This is not a mandate to delete useful indexes. A grammar expansion length,
automaton acceptance count or shape prefix checkpoint saves real work and
needs a checked recurrence. Addresses derivable by a few adds are different
from answers requiring a corpus walk.

One `Source` capability provides stable bounded borrowed reads. Raw slices and
authenticated mappings specialize the SAME decoder at comptime. Source errors
are preserved as `ParseError || SourceError(Source)`, not erased to `anyerror`
or translated into an empty result. No full-section authentication hidden in
an exact lookup. Generated envelope opening is bounded by metadata; explicit
verification checks the semantic payload. Unverified accesses remain bounded
and topology-dependent operations require proof.

Separate `Opened` and validated `Book` surfaces where practical, without
pretending Zig gives private struct construction. A forged field must not turn
unchecked arithmetic into a safety trap. All publicly accessible paths retain
checked coordinate/budget boundaries.

## 6. Builder and module boundaries

### Byte content is a value, not a promise of contiguous storage

The raw string-pool scaffold assumes every logical string is an immediately
borrowable slice. Keeping that API while adding compression would force full
decodes, hidden caches or duplicated text. Replace the assumption with a lazy
text value: checked byte length, explicit caller-output rendering/snippets,
and borrowed chunks where storage permits. A contiguous fast path may return
an optional slice; it must not claim that compressed text is contiguous.
Byte equality and ordering consume this same value interface. Numeric atom
formatting stays a small standard-library operation, not a second text codec.

The byte grammar may then serve written forms, values and rich source text
under one physical representation with a literal fast path. Names and tiny
strings need not pay expansion work when they are stored literally. Exact and
prefix key lookup must navigate its key index, not repeatedly expand a binary
search's candidate strings. No accepted claim yet: the compact wire, tiny
string costs, borrowed lifetime, touched-range failures, source-event rendering
and all five full-artifact measurements must survive this API change together.

This does not reinstate the rejected shared tree/text cursor. Sharing the byte
value and rendering contract is useful independently of whether the separate
shape-navigation machine can share its traversal implementation.

Reader and offline compiler are visibly separate. The compiler can allocate,
intern values with `std.StringHashMap`/`AutoHashMap`, and compact grammar work
sequences in place. The reader never owns a hidden allocator. Deterministic
Re-Pair remains a bounded sampled heuristic with explicit work and expansion
limits. Literal-pair emission stays inside the one renderer, not a parallel
fast-path parser. Cold bzip3 remains a real host adapter, never identity
compression reported as a size result.

Suggested production layout, organized by reusable responsibility:

- `root.zig`: deliberately small application surface;
- `model.zig`: semantic declarations, reference types, occurrence/fact inputs;
- `bytes.zig`: capability, checked coordinates, generated layout, archive;
- `columns.zig`: generated products and finite scalar codecs;
- `sets.zig`: grouped rank stream and rank/select codecs;
- `keys.zig`: the single key automaton and bounded search products;
- `shapes.zig`: one occurrence topology and co-measured rank navigation;
- `text.zig`: byte grammar construction and direct expansion;
- `index.zig`: projection declarations and shared incidence laws;
- `book.zig`: assembly, validation and typed run queries;
- `compile.zig`: offline coherent construction.

This is a responsibility map, not a file-count trick. Split a genuinely large
codec into a clearly named file if it improves reading; count every dependency.
Do not import `src4`, copy entire old modules, preserve an old API façade, hide
algorithms in benchmark adapters, or trade clear code for dense one-liners.
Port a proven algorithm by re-expressing it under these boundaries, preserving
its hostile tests and recording what it replaced.

## Acceptance and order of work

One Sol/medium implementation owner writes `src5/`, a new `build5.zig`, and an
implementation ledger in the new experiment directory. Root owns this design,
independent tests, benchmark adapters, architecture decisions and admission.
Luna/max agents receive bounded adversarial/test/measurement work, not an
invitation to add feature modules independently. No further `src4` edits.

1. Publish concrete input and query types plus a compiling vertical slice:
   build → archive → open → validate → exact/prefix → descendants → render.
   It must already use the one occurrence model, generated product codec and
   grouped projection. Then expand the same mechanisms, not graft old owners.
2. Exercise real public calls at compile time and runtime. All-mode hostile
   source parity, malformed arithmetic, allocation-failure cleanup, proof and
   borrowed-lifetime tests are mandatory. Never infer correctness from a lazy
   generic declaration that has no consumer.
3. Migrate the prior query/TEI regressions as independent tests against the new
   public model. Include noncontiguous/nested scopes, homographs/forms, multiple
   memberships and qualifiers, mismatched actual/declarative rank domains,
   exact-checkpoint corruption, grammar bombs/cycles/tails, dirty search scratch,
   touched-range authentication failure, and optional-union canonicality.
4. Round-trip the pinned independent TEI event oracle: real 4,402 events and
   16,500 queries; synthetic 95 and 346. Preserve order, namespaces, attributes,
   repeated/empty occurrences, comments/PIs, source IDs, language inheritance
   including explicit empty reset, and unresolved targets. Native XML parsing
   and byte-for-byte XML reserialization are not implied by this gate.
5. Compare full artifacts on the SAME five fixtures against the immutable
   accepted control: 64,848 / 36,104 / 35,240 / 59,080 / 74,912 bytes. Preserve
   fields; charge all metadata, page digests and indexes. Record build, opening,
   verification, dependent/independent exact/prefix, full rendering and short
   snippets separately with the correct optimization on every Zig module.
   A smaller or faster primitive is not a full-system result.
6. Count every shipped non-test token/function/decision, including generic
   helpers, adapters and dependencies. Baseline: 153,523 production tokens,
   1,217 function bodies, 3,168 decision keywords. Aim for a major reduction
   (roughly one third or more), not cosmetic line changes. A roughly 8–10k-line
   readable implementation is a design pressure, not permission to omit work.
   Favor a clearer, more flexible structural abstraction even when one local
   function grows. Reject metric gaming, selective function comparisons and
   reduced semantic capability; source reduction should follow shared laws.
7. Freeze one final candidate and run full Debug/ReleaseSafe/ReleaseFast, the
   independent event/query oracle, native paired measurements and real external
   format comparisons through Nix. Document rejected experiments and unexplored
   hypotheses. No broad victory claim when even one required gate is pending.
