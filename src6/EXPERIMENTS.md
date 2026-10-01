# Experiments and next questions

The objective is less machinery for a richer usable model, not a lower line
counter. An experiment earns promotion by preserving semantics, bounded failure
behavior and complete-byte accounting—not by moving difficult work outside a
timed region without saying so.

## Decisions made in this rewrite

1. **Actual types instead of relational reconstruction.** Entry-local typed
   documents replace per-kind reconstruction through population/scalar joins.
   Shared authorities remain separate resource packets. This simplifies the
   public model and field access; first-load decode remains a measurable cost.
2. **One ordered cursor, multiple consumers.** Lexical selection, inline
   inspection, rendering and snippets share traversal state and inherited
   language. Each retains its own payload semantics. Depth/error/order tests
   exercise both comptime specializations.
3. **Borrowed common-prefix key blocks.** A hit is two stable mapped slices,
   not a scratch-buffer reconstruction chained through preceding keys.
   Posting extents permit skipping a key's unrelated claims without decoding
   them. The extra extent bytes are charged to the complete artifact.
4. **Standard-library JSON versus a binary packet.** The independent
   [bounded JSON experiment](experiments/json_packet_report.md) tests the same
   complete rich model through `std.json`, including binary source bytes and
   integer extremes. Binary is retained: JSON did not remove the need for
   resource admission, and its measured repetitive-fixture encoding was larger
   before and after real bzip3. This is not a natural-corpus compression result.
5. **Library-owned source admission.** The first rich-resource measurements
   exposed an accidental quadratic setup: every document rebuilt the complete
   source map. One shared `SourceIndex` now serves a build/full verification;
   documents own only their local additions. A refusing-allocator test proves
   anchor-only admission does not copy the shared index. All twelve N=2,048
   before/after archive pairs compare byte-for-byte equal. Rich/raw build was
   212.26 → 2.89 ms and full verification 169.05 → 3.28 ms; adaptive bzip3 was
   227.68 → 23.45 ms and 177.43 → 13.25 ms. These are single observations,
   with a separate four-size scaling check, not statistical speed guarantees.
   Both versions' raw evidence is retained in the [ledger](reviews/benchmark.md).
6. **One context operation for every query surface.** Tagged field projections
   and cursor traversal now resolve language through `Language.at`. This closes
   a correctness gap in the general field API without adding per-kind façades.

## Experiments still worth doing

### Implemented: typed reader sessions with one bounded page cache

`Reader.load` uses the same typed addresses and independent packet ownership,
but shares source bounds and retains one decoded page with checked packet
offsets. Tests check actual decode counts, eviction, errors and independently
owned results. Measurement must still separate first load, same-page next
entry, page changes and already-loaded rendering; a warmed session is not cold.

### Choose page size on a measured storage/latency frontier

Sweep small versus large independently compressed pages on natural dictionaries,
including incompressible prose and multi-megabyte sources. Charge the directory,
digests, native state and first-read decode. Test raw and compressed choices
under the same public policy. Do not select sizes using the benchmark's future
query schedule.

### Per-block verified index navigation

Startup currently scans the whole hot index. A checked block directory with
lazy digest verification could reduce first-query work, but introduces integrity
state and additional metadata. Require denied/short/overlong touched-range tests
and measure both first and repeated lookup; reject it if that machinery costs
more than it saves on realistic dictionary sizes.

### Source fragmentation as a general packet composition

Large source documents should not require one enormous decode just to inspect a
small span. Test a common measured-fragment representation for binary sources,
ordered text and rich trees, while keeping stable source byte coordinates and
exact source reconstruction. This is more promising than another source-only
compression exception, but it is not implemented or counted as a current win.

### Native graph-level queries and optional interchange

Build real TEI, published LIFT 0.13 and OntoLex adapter fixtures with explicit
loss accounting. Test identity scope, many-to-many source mappings, relation
qualification, language reset, ranges and residual material through import,
storage, query and export—not merely through raw source preservation. Profile
rules (such as OntoLex canonical forms) should remain separate from permissive
archival representation. Cross-entry inverse relations and resource-fragment
resolution now use explicit, hop-bounded follow operations. Typed all-node
resolution and runtime predicate filters are implemented; reverse indexes,
general graph paths, grouping and a query planner remain experiments, not
claims of XPath/XQuery/SPARQL completeness. Interchange remains optional and
separate from preserving native semantic richness.

### Repeated-fragment factoring before entropy coding

Explore schema-default elision and shared typed subtrees only on the *same*
model. Bzip3 already captures much repetition; another dictionary may simply
add indirection. Preserve occurrence identity and evidence even when physical
payloads are shared. Count the full dictionary, tags, pointers and verification
work, and compare against the simple packet control before promotion.
