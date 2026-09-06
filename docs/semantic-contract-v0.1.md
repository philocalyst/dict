# Semantic and API contract v0.1

This contract describes the behavior implemented by the current raw snapshot prototype. It is intentionally narrower than [`plan.md`](../plan.md), which remains a future design proposal.

## Ownership and lifetime

`Writer.init(allocator)` stores the allocator. `Writer.add(record)` validates and copies the key and definition into writer-owned memory. The caller may reuse or release both input slices immediately after `add` returns. `Writer.deinit()` frees every copied key and definition and releases the record list; it must be called once for an initialized writer.

`Writer.build()` returns a newly allocated snapshot byte slice owned by the caller through the writer's allocator. The caller must free it with that allocator. Building sorts the writer's records in place, so later additions are allowed but the writer's internal order is an implementation detail. A build is deterministic for the same set of `(id, key, definition)` triples regardless of insertion order.

`Reader.open(bytes)` validates the complete snapshot and returns a reader borrowing `bytes`. It does not allocate a copy. The caller must keep the backing bytes alive and immutable until the reader is no longer used. A reader is a value containing borrowed slices; it is not a synchronization or ownership boundary. `payloadReadCount()` reports successful definition-block reads performed through that reader.

`Reader.openWithOptions(bytes, options)` additionally stores the caller-selected
`options.decode_allocator`. The default is `std.heap.page_allocator`, preserving
the behavior of `Reader.open`. Only a lazy bzip3 definition read uses this
allocator; raw definition reads copy directly from the borrowed snapshot and
perform no decode allocation. Bzip3 output is temporary and is freed before
`definition` returns, including validation and codec-error paths. The allocator's
context must remain alive while the reader is used. A reader does not make an
allocator thread-safe: concurrent definition calls require an allocator that
supports that concurrency, or separate readers/allocator instances. The
configured `max_decode_memory_bytes` limit is enforced independently of the
allocator's own capacity, and allocation failure is reported as
`Error.OutOfMemory`.

Lookup methods write into caller-provided output buffers. `definition(id, out)` copies raw definition bytes into `out` and returns the number of bytes copied. It does not return a borrowed definition slice. Empty definitions return `0` with no output bytes. The reader never allocates a result list for these operations.

## Record identity and ordering

Record IDs are caller-assigned `u64` values and must be unique within a writer. Duplicate IDs are rejected by `Writer.add`. The same ID identifies the record's posting and payload atom in one snapshot. The library does not generate IDs, reconcile IDs across snapshots, or preserve identity when an application changes the assigned IDs. Stable cross-build identity is therefore an application responsibility.

Multiple records may have the same key. Exact lookup returns all matching IDs in ascending numeric order. Prefix lookup returns postings in key byte order and then ascending ID order. Definitions with equal bytes are interned physically, but their record IDs and postings remain distinct. Interning definition bytes never merges records or keys.

## Literal text behavior

Keys must be non-empty, no longer than 65,535 bytes, and valid UTF-8 when added. Reader lookup also rejects invalid UTF-8 needles. Matching compares the original UTF-8 byte sequences literally:

- exact lookup uses byte equality;
- prefix lookup uses byte `startsWith`;
- there is no Unicode normalization or canonical-equivalence matching;
- there is no case folding, locale behavior, transliteration, tokenization, morphology, grapheme handling, fuzzy distance, suffix, substring, or full-text search.

For example, composed `é` and decomposed `e\u{301}` are distinct keys. Definitions are arbitrary byte strings: the writer does not validate them as UTF-8, and `definition` returns those bytes unchanged.

## Validation and errors

`Reader.open` validates the magic, supported versions and feature flags, file and directory bounds, alignment, section overlap, required sections, section lengths and counts, key ordering/front-coding, posting coverage and uniqueness, payload atom ordering, atom/block bounds, and all FNV-1a checksums. Malformed input produces a specific format error such as `InvalidFormat`, `Truncated`, `Overflow`, `UnsupportedVersion`, `UnsupportedFeature`, `CorruptSection`, or `CorruptChecksum`.

The FNV-1a-64 checksums detect accidental corruption. They are non-cryptographic and provide no authenticity, anti-tamper guarantee, or trust decision. Authentication must be supplied by a higher-level signature or secure transport.

Writer and query failures include `EmptyKey`, `KeyTooLong`, `InvalidUtf8`, `DuplicateId`, `BufferTooSmall`, and `NotFound` as appropriate. Output buffers are bounded explicitly; callers must size them for the expected result count or definition length.

## Implemented surface and deliberate limits

The public implementation surface is `Writer`, `Reader`, `Record`, the format constants, and the error set in `src/lexicon.zig`. The implemented data model is one key and one raw definition per record.

`lex.semantic` is a separate in-memory model, not a section of this v0.1 raw
snapshot. It validates exact typed-value interning, occurrence-bearing entities,
role-labelled n-ary assertions, evidence, uncertainty, temporal metadata,
unresolved references, backward-only statement targets, explicit default/named
or source-scoped anonymous graph contexts, and ordered mixed-content document
nodes. Its values, entities, assertions, and document nodes preserve distinct
identities and order. `lex.query` validates statement references and can filter
or return assertion context without treating context as a generic attribute.
`lex.semantic_format` provides a deterministic checked reference encoding for
that model, and `lex.query` provides bounded scans, assertion filters, graph
traversal, document axes, and attribute access over the in-memory model. These
remain separate from the raw snapshot sections.

The following are not hidden features and must not be inferred from the raw format:

- semantic sections beyond the raw snapshot's minor-2 payload codec records
  (the reusable codec API is documented separately);
- a C ABI or ABI stability promise;
- DICT/RFC 2229 serving or a network protocol;
- TEI, Kirrkirr, StarDict, slob, XML, or any importer/exporter;
- compact semantic sections and direct indexes in the raw snapshot;
- textual LexQL parsing, fielded/full-text/fuzzy/normalized search, and query
  planning beyond the bounded semantic reference evaluator;
- normalization profiles, language packs, collation, morphology, transliteration, or fuzzy search;
- transactional editing, multi-snapshot history, crash publication, or snapshot files.

## Semantic model prototype

`src/semantic.zig` adds a separate in-memory semantic model exposed as
`lexicon.semantic` (with `SemanticBuilder` and `SemanticModel` aliases). It
preserves typed values, entity occurrences, n-ary assertions, nested statement
targets, graph contexts, evidence, unresolved targets, and ordered mixed-content
document forests. `Builder` owns
and copies caller input, validates references and document containment, interns
only exact typed values, and transfers ownership to an immutable `Model`.

The semantic layer is intentionally not part of the raw snapshot bytes, and no
snapshot reader should infer semantic records from the raw key/definition
prototype. Call `Model.deinit` once after `Builder.build` succeeds. The checked
reference encoding is suitable as a semantic oracle; compact immutable sections
remain a later storage integration.

## Validation commands

Run the repository checks with:

```sh
zig build test
zig build
```

The tests exercise deterministic output, exact/prefix lookup, shared definitions, Unicode byte distinction, malformed snapshots, bounded buffers, empty and oversized definitions, and a generated reference model. These tests describe the current contract; they do not establish the broader performance or feature claims in `plan.md`.
