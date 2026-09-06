# Compactness decisions — 6 September 2026

This note separates implemented changes, experiments, and research. Byte savings
are meaningful only when occurrence identity, original Unicode, evidence, order,
and the complete materialized query answers agree.

## Remove structural repetition first

The reference semantic stream repeats byte strings in namespace names, qualified
names, participant roles, language/script/notation fields, and source identifiers.
Interning exact bytes across those fields does not imply semantic equality: a raw
byte value and a text value can point at the same bytes while retaining different
tags. Two assertions with identical participants remain two assertions. No Unicode
normalization belongs in this interning key.

Canonical bounded varints reduce small IDs and counts. They belong in the current
materialized semantic stream, where opening already decodes rows; they are not a
replacement for directly addressable columns. Any future mapped semantic reader
must count its row offsets/restarts and the cost of random access.

For postings, frame-of-reference packing stores a base and `ceil(log2(range+1))`
bits per ID, with width zero for a constant sequence. It retains arbitrary external
`u64` IDs. Random access decodes one field without walking earlier integers. The
writer must count the descriptor and choose raw storage when packing expands it.
Small magnitudes alone do not justify globally renumbering external identities.

## Research worth testing next

| Primary source | Applicable idea | Experiment required here |
| --- | --- | --- |
| [OptFSST, v3, 26 August 2026](https://arxiv.org/abs/2607.11271v3) | Dynamic programming improves encoding under a fixed symbol table; construction prunes conflicting symbols. Individual strings remain independently decodable. | Compare short atom pools with raw and bzip3, including symbol tables, offsets, build memory/time, and random-string latency. |
| [OnPair, 4 August 2025](https://arxiv.org/abs/2508.02280v1) | Sample-based substring dictionaries and independent string coding; a bounded-symbol variant targets fast parsing. | Test inflection-rich and multilingual labels, plus held-out and unique-string controls; charge dictionary and escape bytes. |
| [FSST, VLDB 2020](https://vldb.org/pvldb/vol13/p2649-boncz.pdf) | Static symbol tables reduce strings without forcing neighboring strings to decode. | Establish a small, reproducible random-access string baseline before adding another decoder. |
| [FastLanes research overview, CWI, January 2026](https://www.cwi.nl/en/news/fastlanes-redesigning-data-files-for-faster-analytics/) | Compression layout can support efficient parallel decoding; optimizing stored bytes alone misses execution costs. | Compare packed scalar reference access against batch decoding on supported CPUs. Do not require speculative out-of-bounds SIMD loads. |

Those publications report results on their own workloads. None establishes a
Lexicon speedup. A new codec must beat a declared baseline after metadata and
dependency costs, with the same content and access requirements.

## The next structural step

After atom sharing and postings packing, measure semantic columns grouped by
predicate and target kind. A group can imply the predicate, role schema, target
tag, and common state once. Sparse exception columns retain unusual states,
evidence and source context. A logical assertion-ID permutation preserves original
order when physical grouping changes it. That permutation is part of the cost.

For example, eliminating a four-byte predicate and one-byte tag from 100,000
rows saves 500,000 bytes before group descriptors. A four-byte identity
permutation already costs 400,000 bytes; claiming the full 500,000-byte win would
be wrong. Bit-packed permutations, natural grouping, or an index serving a second
purpose may improve the tradeoff, but each needs measurements.

Scope defaults are another structural improvement: one language/grammar fact
plus explicit exceptions can replace thousands of repeated facts. This is legal
only for fields whose schema declares inheritance, and only when effective-value
queries preserve origin, explicit absence, ambiguity and source boundaries.

Recursive morphology should use identity-bearing analyses with ordered part
occurrences and explicit spans. Discontinuous and overlapping parts, zero surface
realizations, competing analyses, and nonconcatenative roots invalidate a flat
list of substring offsets as a universal representation. Shared strings or feature
values can still be interned without merging those occurrences.

## Acceptance

- Compare complete snapshots, including directories, atom pools, maps and padding.
- Include repeated-structure, unique-string, multilingual, and tiny controls.
- Compare exact reference serialization after decoding, not rendered prose alone.
- Keep raw and compressed variants in one harness with matching queries and IDs.
- Report encode/decode and lookup latency separately; include structural work counts.
- Reject noncanonical integers, malformed pool IDs, impossible widths, nonzero tail
  bits, invalid Unicode where text is required, and resource-limit violations.
- Require allocation-failure cleanup and safety-enabled builds before acceptance.
- A fixture-specific improvement is not an order-of-magnitude product claim.

## Memory and redundancy ledger

Compactness reports must keep three scopes separate:

1. **Published bytes** include the complete snapshot, atom and restart
   directories, codec state parameters, checksums, alignment, and every index.
2. **Build memory** includes the owned reference model, exact-byte atom map,
   sort permutations, uncompressed codec candidates, and codec state. Peak
   resident memory matters even when temporary arrays never reach the file.
3. **Query memory** includes the caller's output, decoded block and scratch
   buffers, pinned cache blocks, traversal queues, visited sets, and temporary
   semijoin bitmaps. Concurrent queries multiply private state; shared immutable
   mappings and cache blocks are counted once plus their pin metadata.

The semantic `Builder` currently owns copies of strings and nested arrays before
encoding. The compact atom pool removes repeated bytes from the published stream;
it does not remove that build-time duplication. Likewise, a source-node query now
uses a transient membership bitmap to avoid repeated anchor scans. That trades
approximately one bit per candidate (plus allocator bookkeeping and word padding)
for linear work, is bounded by `max_temporary_bytes`, and is never presented as a
snapshot-size saving.

Shared values save authoritative payload bytes while occurrence arrays remain.
The following are necessary representation, not redundant copies: assertion IDs,
source anchors, ordering/permutation data, search keys derived under a named
profile, integrity data, and caller-selected reverse indexes. Reports must expose
each separately rather than subtracting them from a headline ratio.
