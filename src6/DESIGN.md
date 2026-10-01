# LEX6: lexical packets, not a database wearing a dictionary API

The previous architecture made every lexical kind the same record and then
reconstructed articles through population, value, fact, source and key joins.
Its clever scalar machinery was compensating for that decision. LEX6 changes
the ownership boundary, not the spelling of those joins.

## One model, three responsibilities

* **An entry is an ordered, typed lexical document.** Forms, senses, examples,
  grammatical features and semantic relations have different payloads. A
  tagged `Item` preserves interleaving and multiplicity. Nested senses are
  actual nested values. Common metadata describes identity, language,
  provenance and annotation; it does not replace the typed payload.
* **A packet is an admission and lifetime boundary.** The same Zig model is
  encoded and decoded by a schema-specialized codec. There is no mirrored
  stored model, global string-ID graph or runtime population plan. A loaded
  entry owns its decoded allocations; normal field access is normal Zig.
* **An index is a projection, not the semantic authority.** Sorted key hits
  point directly to entry packets. Lookup and prefix enumeration do not
  decompress prose. Entry pages use real vendored bzip3, chosen against raw
  by actual bytes. Blocks are bounded and their digests checked before decoding.
  These checks detect corruption; they are not signatures or proof of origin.

Shared source documents, controlled ranges and concepts live in resource
packets, not repeated in every entry. `Library` compiles both document kinds
through the same codec and page engine. A compact hot resource catalog supplies
source extents for anchor checking without loading source bodies. A full verify
checks catalog projections against their actual packets.

The source-bound index belongs to the library, not to each document check.
Build and full verification construct it once; entry admission borrows it and
owns only local identities and embedded-source bounds. This removes the
entry-count × source-count setup cost without changing the stored format.

## Shared traversal, distinct semantics

`walk.Cursor(Node)` owns ordered traversal, bounded stack state and inherited
language for both lexical items and inline content. Typed selections filter its
enter events; XML rendering consumes paired enter/leave events; snippets consume
text events. There is one ordering and depth-failure implementation, not three
recursive walkers. It does not conflate lexical containment with inline markup.
Each type supplies its real children. Contextual query results carry the
language declaration, so chained selections distinguish inheritance, explicit
reset and missing context without mutating the document.
Direct field projections use that same context operation, including for tagged
lexical and inline values; choosing a different query surface cannot change a
language declaration.

Rich structural queries and admission additionally share `nodes.Cursor(Root)`.
It derives child traversal from actual fields, active union payloads, slices,
optionals, and single-item ownership pointers. One derived metadata-owner rule
serves both identity collection and public resolution: admitting a Feature or
Representation identity cannot omit it from the resolver. Structural ancestry
borrows an iterator; resolved pointers borrow only the document. The smaller
Item/Inline cursor remains the fast path for rendering and ordinary senses.

Relations select binary or n-ary endpoints with a tagged union. Value identity
is expressed by a named `SharedValue`, independent of equality; define it once
and use Reference to reuse it. Pointer edges are ownership edges encoded by
value, never persisted process addresses or implicit graph aliases. Packet
version 2 makes these changed semantics explicit.

The optional Reader session owns a single decoded page, derived packet offsets,
and shared source bounds. It does not own returned documents. Logical entry
links use an explicitly prepared in-memory catalog, leaving the on-disk hot
spelling index unchanged. This chooses transparent preparation cost over hidden
first-follow scans or another always-stored identity table; it is not a claim
that link readiness is cheap. A workload needing instant link readiness may
justify a separately measured persisted catalog later.

This is deliberately not a promise that entry-local data always beats columns.
Batch analytics may prefer columns; cold decompression has a real first-read
cost. Both storage and cold/warm query costs must be measured independently.

## Lexical commitments

TEI distinguishes the printed/source view from lexical interpretation and
permits recursive senses and freer entry composition. Preserve both rather
than calling an opaque XML blob semantic support.
[TEI Dictionaries](https://tei-c.org/release/doc/tei-p5-doc/en/html/DI.html).

Use LIFT's multilingual content, examples with translations, extensible
traits/ranges, annotations and lexical identities as requirements. Published
0.13 and the repository's development schema must not be conflated.
[LIFT project and published specification](https://github.com/sillsdev/lift-standard).

Keep lexical entries, their forms, senses, lexical concepts and ontology
referents distinct. Relations may be qualified statements, not just strings
attached to a sense.
[OntoLex community report](https://www.w3.org/2016/05/ontolex/).

Our model is an implementation design informed by these sources, not an
assertion of complete XML/RDF importer or exporter conformance.

## Implementation rubric

1. Public examples first: headword → hit → owned entry → typed senses → rich
   definition/render. No manual rank domains, binding joins or `.field().read()`.
2. Derive wire operations from actual Zig types with `@typeInfo`,
   `std.meta.FieldEnum`, tagged unions and explicit error sets. Do not generate
   a parallel set of nominal schema declarations.
3. Ordered collections are bags unless explicitly constrained; duplicate
   evidence and relations cannot disappear under a uniqueness optimization.
4. Immutable archive bytes outlive archive views; loaded entry owners have
   independent lifetimes. Successful reads must have the requested extent.
5. Resource limits precede allocation, recursion and native-code entry. Failed
   decode releases everything. No partially admitted lexical object escapes.
6. Real bzip3 is part of build6, not an identity hook or an unavailable promise.
   Account native allocations separately from Zig allocator measurements.
7. Keep source bytes/provenance, unknown qualified markup, exact decimals,
   local/cross-entry/unresolved identities and language reset semantics.
8. Test all optimization modes, hostile inputs, allocation failure, semantic
   multiplicity, direct lookup without page decoding, and full roundtrip.
9. Report complete artifact bytes and cold/warm timings. Do not transplant
   src5 benchmark numbers or compare reduced semantic fixtures as equivalents.
10. Clarity outranks a line cap. Remove unnecessary states and reconciliations,
    not useful type names, comments, validation, whitespace or rich semantics.

## Scope discipline

Only src6, its new build6 wiring and new benchmark/review artifacts are in
scope. Existing implementations and their benchmark evidence remain intact.
This version is not promoted as a replacement until its complete performance
and native semantic-capability comparisons are evidenced. XML/RDF interchange
conformance is a separate concern, not the definition of native richness.
