# Lexicon

Lexicon is a small Zig library for building and reading an immutable, in-memory snapshot of keyed records. A record has a caller-supplied `u64` ID, a non-empty UTF-8 key, and an arbitrary byte definition. The current code is a format and API prototype, not the completed lexical database described in [`plan.md`](plan.md).

The prototype currently provides:

- deterministic snapshots from `lex.Writer`;
- exact and byte-prefix lookup through `lex.Reader`;
- duplicate-key postings with unique record IDs;
- byte-exact interning of equal definitions;
- bounded independently addressable payload blocks, raw by default with optional per-block bzip3 compression;
- explicit little-endian decoding, section bounds checks, and FNV-1a-64 accidental-corruption checksums;
- tests for determinism, Unicode byte behavior, corruption, bounds errors, block boundaries, and a generated reference model.

Alongside the raw snapshot control, `lex.semantic` provides a separate, validated
in-memory semantic model. It keeps interned typed values separate from
identity-bearing entities and assertions; supports ordered, role-labelled n-ary
relations, evidence, certainty, temporal values, unresolved targets, and an
ordered mixed-content document forest. `lex.semantic_format` provides a checked
deterministic reference encoding, while `lex.query` provides bounded graph,
assertion, entity, document-axis, and attribute operations over that model.

The snapshot remains deliberately in-memory: it does not read or write files,
memory-map snapshots, or provide a command-line database tool. `Writer.build`
returns an allocated byte slice, and `Reader.open` borrows that slice. Payload
blocks can use raw bytes or bzip3 as described above. `lex.codec` provides
reusable independently addressable
raw and pinned-upstream-bzip3 block codecs. Snapshot minor version 3 now uses
that layer for independently addressable payload blocks while retaining raw as
the default and fallback representation.

The following plan stages are intentionally unimplemented: a stable C ABI;
RFC 2229/dictd serving; DICT, StarDict, slob, or TEI import/export; direct
semantic sections and indexes in the raw snapshot; textual LexQL parsing;
fielded/full-text/fuzzy/normalized search; and the transactional editor and
snapshot publisher. The current persisted-query operations remain literal
exact-key and literal byte-prefix lookup. The semantic oracle remains separate
from snapshot sections; payload blocks use the reusable codec layer. `src/main.zig`
is only a build smoke-test executable.

## Quick start

```zig
const lex = @import("lexicon");

var writer = lex.Writer.init(allocator);
defer writer.deinit();
try writer.add(.{ .id = 7, .key = "bank", .definition = "edge of a river" });

const snapshot = try writer.build();
defer allocator.free(snapshot);

var reader = try lex.Reader.open(snapshot);
var ids: [8]u64 = undefined;
const count = try reader.lookupExact("bank", ids[0..]);
```

`Writer.add` copies the key and definition, so its input slices may be reused after the call. `Writer.deinit` releases those copies. `Reader` does not copy its input; the snapshot bytes must remain alive and unchanged for the reader's entire lifetime. Lookup writes record IDs into the caller's output buffer and returns the number written. `Reader.definition` writes raw definition bytes into a caller-provided buffer. A too-small output buffer returns `error.BufferTooSmall`; missing IDs return `error.NotFound`.

Keys are compared as their original UTF-8 bytes. The library validates key UTF-8 but performs no normalization, case folding, locale collation, transliteration, tokenization, or fuzzy matching. Thus composed `é` and `e\u{301}` are different literal keys. Definitions are arbitrary bytes and are not required to be UTF-8.

Record IDs must be unique within one writer. They are stored as supplied and are the identity returned by postings and used to retrieve definitions. The format does not allocate IDs, maintain an external identity registry, or promise that an ID remains meaningful across separately built snapshots; applications that need stable identity must assign and preserve those IDs themselves. Adding records in a different order does not change the resulting snapshot bytes.

## Build and validation

The project requires Zig with the version-compatible standard library used by the checked-in `build.zig`.

```sh
zig build test
zig build
```

The test suite is in the source modules, including [`src/codec.zig`](src/codec.zig),
[`src/query.zig`](src/query.zig), and [`src/semantic_format.zig`](src/semantic_format.zig).
The raw format details are in [`docs/format-v0.1.md`](docs/format-v0.1.md),
the codec contract is in [`docs/codec-bzip3-v0.1.md`](docs/codec-bzip3-v0.1.md),
and API/semantic guarantees are in [`docs/semantic-contract-v0.1.md`](docs/semantic-contract-v0.1.md).
These are implementation prototypes and are not yet a final compatibility commitment.
