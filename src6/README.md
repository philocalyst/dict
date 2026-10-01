# LEX6

An experimental dictionary library for Zig 0.16. The public lexical types are
the stored schema. There is no second record model to reconstruct before an
application can ask for a sense or render a definition.

```zig
var file = try lex.archive.build(gpa, .{ .entries = entries, .resources = resources }, .{});
defer file.deinit();
const dictionary = try lex.archive.Archive.open(file.bytes, .{});
var reader = try lex.archive.Reader.init(gpa, &dictionary, .{});
defer reader.deinit();

var matches = try dictionary.lookup("bank");
while (try matches.next()) |hit| {
    var loaded = try reader.load(hit.entry);
    defer loaded.deinit();
    var senses = lex.query.entry(&loaded.value).select(.sense, .children);
    while (try senses.next()) |sense| {
        var definitions = sense.select(.definition, .children);
        while (try definitions.next()) |definition| {
            try lex.render.write(definition.value.*, writer, .plain);
        }
    }
}
```

The independent [example](example.zig) compiles and exercises this API. Run:

```text
zig build --build-file build6.zig test test-example
zig build --build-file build6.zig example
zig build --build-file build6.zig test test-example -Doptimize=ReleaseSafe
zig build --build-file build6.zig test test-example -Doptimize=ReleaseFast
```

`build6` links the real vendored bzip3 implementation. It does not need a host
codec hook or modify any prior build. The compiler used here comes from the
existing Nix environment. If Zig reports a stale C-import cache entry, a fresh
`--cache-dir` can isolate it without deleting another task's cache.

The review-resolution work adds all-node resolution, composable predicates,
typed shared values, language-tag syntax admission, and bounded reader sessions.
Its verification and remaining limits are recorded in
[review resolution](reviews/resolution.md). Compile-failure contracts reject
unchecked union access, byte-string enumeration, and scalar collection misuse.
These are implementation gates, not standards-conformance tests.

**Format revision:** packet and archive versions are now 2. Version 1 artifacts
must be rebuilt; they are rejected rather than interpreted as the changed model.
Retained version 1 measurements below remain historical baseline evidence.

## Measured result, with boundaries

On the matched synthetic 2,048-entry flat/mixed projection, the complete LEX6
bzip3 archive is **29,848 B**, versus **92,103 B** for frozen LEX5 (67.6% smaller).
The raw LEX6 archive is larger, at 356,912 B; compression is a real dependency
of this storage result, not omitted work.

The source-scope refactor changed no archive bytes: all twelve retained
before/after artifact pairs compare byte-for-byte equal. On the separate rich
resource fixture, raw build changed from 212.26 ms to 2.89 ms and full verify
from 169.05 ms to 3.28 ms. With adaptive bzip3, those observations were
227.68 → 23.45 ms and 177.43 → 13.25 ms. These are single-run observations,
supported by a separate 256/512/1,024/2,048-entry scaling check, not statistical
speed guarantees.

Cold compressed entry loading still costs roughly a millisecond in these
runs. The old narrow source-render control does different work and is much
faster; universal latency parity is **not** established. Full raw logs,
artifact hashes, matched-subset definitions and limitations are in the
[benchmark report](reviews/benchmark.md).

## Ownership and query behavior

- Archive bytes are borrowed **and immutable** for the view's lifetime. Hits
  borrow both spelling fragments from that mapping. A query iterator also
  borrows its search string; keep it alive until enumeration ends.
- `EntryId` and `ResourceId` are distinct physical address types. Logical IDs
  stay in the model; external and unresolved links are not physical ordinals.
- A loaded value owns its allocations independently of archive bytes. All
  typed selections and inline events borrow that loaded value.
- `.children` means immediate lexical children. `.descendants` means ordered
  depth-first lexical traversal. Repeated items and independent claims remain
  repeated. Rich inline elements are not mistaken for lexical children.
- A selection returns both the actual payload pointer and effective language.
  The declaring field is retained, including an explicit reset. Chaining
  selections does not discard context.
- `.values(.representations)` and `.child(.text)` follow ordinary model fields
  with the same context, without per-kind query façades. Language declarations
  use the typed language field; a competing raw `xml:lang` attribute is rejected.
- Field projection accepts struct fields, not unchecked union payloads. Use
  typed selection or an exhaustive `switch` before inspecting a tagged value;
  negative compilation tests enforce this boundary.
- `hit.spelling` is a borrowed two-slice `KeyView`. Use `eql`, `startsWith`, or
  `writeTo`; recovering a contiguous temporary string is not required.
- `descendants(T, limits)` traverses all structural model nodes, including
  feature structures and form representations. `.filter(context, predicate)`
  composes over structural selections, fast lexical selections, and field
  collections. The callback receives the typed match and caller context.
- Structural matches expose typed ancestors. That ancestry view expires when
  its iterator advances; the node pointer itself borrows the document.
  `query.resolve` returns a stable typed node and language, never a pointer
  into a destroyed traversal stack.
- `Reader` retains at most one decoded page and reuses source bounds. Returned
  documents still own independent arenas. Use `Archive.load` for an explicitly
  uncached operation. Reader statistics expose actual decodes and cache hits.
- `Reader.prepareLinks()` explicitly scans entry documents once to build a
  derived logical-ID catalog. `follow` distinguishes found, unavailable and
  unresolved links, with a caller-selected hop limit. Missing external targets
  are not silently relabelled as malformed archives. Resource links use the
  existing hot catalog; local links resolve against an already loaded document.

## What is represented

Forms have independent written/phonetic/transliterated representations and
their own features and metadata. Senses are recursive. Definitions and glosses
retain mixed markup. Examples and translation citations contain qualified
content. Feature structures preserve exact decimals, alternatives, negation,
ordered lists, bags, sets, unknown and unspecified values.

Relations carry their own identity, state, evidence, annotations and role-labelled
participants. Their `endpoints` union selects binary or n-ary form; both cannot
coexist. A named `SharedValue` defines an atomic or structured value once, with
reuse through references. Independent value libraries use resource packets.
Lexical concepts and ontology denotations remain different
values. Shared concepts, LIFT-style ranges and source documents are independently
addressable resources. Source spans, many-to-many realization mappings,
residual material and scoped certainty are explicit data.

These are representation and validation capabilities, **not a claim of complete
TEI/LIFT XML or OntoLex RDF import/export conformance**. No such importer is
silently substituted with an opaque source blob. Unknown namespaced markup and
source bytes remain preservable; source export and semantic XML reconstruction
are different operations. See [the design](DESIGN.md) and
[the semantic review](reviews/lexical-contract.md).

## Costs and trust

Opening checks the metadata digest and validates the complete hot index,
resource catalog and page directory. It does not decompress pages, but its
work is linear in metadata size—it is not advertised as constant-time startup.
Loading verifies and decodes the relevant page, then admits the selected typed
document. `verifyAll` additionally reconciles every packet with the hot index
and resource catalog. SHA-256 detects corruption; it does not authenticate an
archive's publisher.

Shared source bounds are indexed once for a build or full verification and
borrowed by document admission. A standalone load currently constructs its own
source index; the explicit `Reader` session reuses that index across loads.

Default pages target 64 KiB. Raw and real bzip3 share the same directory
framing. Adaptive mode compares complete encoded block bytes with raw bytes;
ties choose raw. Cold decode costs are real and reported separately from warm
typed query/render costs. Reader caching is explicit, bounded and observable;
it does not change metadata-only opening. Very large source documents require raised explicit document/page
limits; streaming source fragmentation is not yet implemented.

In the benchmark, “cold load” means a fresh decoded entry/codec state over
already memory-resident archive bytes—not a cold disk or operating-system cache.
The old control's metadata-open step is not yet query-ready until verification;
the new hot-index open and full packet verification also have different scopes.
Comparing isolated step names does not establish application startup parity.

Bounds cover input bytes, decoded value allocation requests, recursive work,
depth, pages and keys. Arena slack and allocator bookkeeping are not included
in the decoded-value byte counter. Native bzip3 admission includes a conservative
allowance for its internal C allocations; Zig allocation-failure tests do not
pretend to inject failures into C `malloc`.

The format is still experimental: the schema version must change before
shipping a changed declaration order or incompatible model. Existing `src5`
and older formats remain untouched. [Benchmark evidence](reviews/benchmark.md)
must be read with its explicit semantic projection and cold/warm boundaries;
there is no universal old-format or SLOB victory claim.

The [post-review structural follow-up](reviews/frontier-followup.md) records
single-pass admission, shared language-context rules and the unified archive
admission contract, together with the matched real-corpus results and regressions.
The isolated [`bzip4` experiments](experiments/bzip4/README.md) are research
candidates, not additional production codecs or promises of improved compression.
