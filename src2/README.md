# LEX2: compile once, validate once, borrow everywhere

The implementation has one semantic model: an ordered forest with typed
columns and predicate adjacency. Construction handles belong to a builder
generation; compilation assigns preorder IDs and returns their translation.
The serialized bytes are the reader's data structures, rather than input to
a second heap object graph.

`Snapshot.open` accepts the complete canonical schema/profile manifest and
validates structural sections and their cross-references once. Its cached
views borrow immutable input bytes. `openContainer` only inspects the transport
envelope and deliberately cannot initialize a usable query. `validateDeep`
additionally decodes every prose item; the compiler runs it before returning.

## Construction

```zig
var builder = lex.Builder.init(allocator);
defer builder.deinit();

const entry = try builder.root(.entry, .{ .headword = "bank", .lang = "en" });
const sense = try builder.child(entry, .sense, .{});
_ = try builder.child(sense, .definition, .{ .text = "the edge of a river" });
const form = try builder.child(entry, .form, .{ .written = "banks" });
_ = try builder.child(form, .part, .{
    .written = "bank", .role = "stem",
    .span = lex.Span{ .unit = .byte, .start = 0, .end = 4 },
});

var compiled = try builder.compile();
defer compiled.deinit();
const snapshot = try lex.Snapshot.open(compiled.bytes, .{});
const physical_sense = try compiled.resolve(sense);
```

Failed compound construction rolls back its nodes and links. All inputs are
copied into the builder arena. Required values, target kinds, role
cardinalities, participant target presence, hierarchy and span bounds are
checked before lowering. Assertion shadow edges are derived from the final
participant forest, including incrementally assembled statements.

Built-in predicate descriptors are canonical comptime values; column
descriptors are canonical types. Forged ID/representation combinations are
compile errors. Runtime vocabulary instead uses `runtimeAssertion`, explicit
role strings and the same node/unresolved target representation. Unary and
n-ary runtime statements are legal; resolved `source` × `target` roles produce
qualified shadow edges. `followNamed` selects the runtime predicate by name.

## Queries and ownership

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
var query = lex.Query.init(&snapshot, &arena, .{
    .max_visited = 100_000, .max_blocks = 4, .allow_scan = false,
});
defer query.deinit();

const hits = try query.key(.headword, "bank", .exact)
    .descendants().kind(.sense).lang("en").take(20).run();
```

A pipeline has one seed. Empty pipelines, navigation before a seed and
reseeding are rejected before execution. Set operations use explicit nested
queries. Results are sorted unique physical IDs; prose is only touched by
`materialize`. A `Rows` value owns its explicit block pins and must be
deinitialized. Atom/key strings borrow the query arena; decoded prose borrows
the rows' pins. Raw prose pins borrow the snapshot bytes directly. Deinitializing
a query releases its reusable codec state without invalidating existing pins.

For a server's repeated indexed requests, the same public query object has an
allocation-free entry point:

```zig
var spelling: [lex.keys.max_key_bytes]u8 = undefined;
var nodes: [1024]lex.Node = undefined;
const matches = try query.lookup(.headword, "ban", .prefix, &spelling, &nodes);
```

`matches` borrows `nodes` until the next write. Buffer exhaustion and work
exhaustion are errors, never truncated successes. Key work counts include
restart probes, front-coded records and decoded postings. This is the public
path used by the benchmark harness; fixture projection happens explicitly
after it returns.

## Storage decisions

- Front-coded words have eight-byte restart records. Packed posting lanes
  permit arithmetic skipping: searching a word never decodes the posting
  lists of other words. Exact lookup retains its final decoded candidate.
- Scalar columns use the minimum bit width of their domain. Empty/full
  optional domains have implicit presence; only mixed domains store a ranked
  bitmap. Kind indexes with zero cardinality have no payload.
- One bounded little-endian bit window serves scalar columns and postings.
  FOR and Elias–Fano encode directly into their final owned byte buffer and
  have one borrowed decoder each.
- Qualified edges use a dense presence bitmap plus only present assertion
  IDs. Cached forward/reverse adjacency shares one implementation. Validation
  checks both directions and the complete assertion shadow relation.
- Prose blocks have generated 48-byte metadata records. Inside a block,
  eight-byte `(node, cumulative_end)` records make item overlap and gaps
  unrepresentable. Empty roots terminate a block plan; oversized roots may
  continue across blocks. Planning is linear.
- Extension attribute shapes are canonical length-prefixed name streams,
  including embedded-NUL names, so delimiter collisions cannot merge shapes.

The format revisions are intentionally incompatible with the prior prototype.
Measurements belong to the retained final-source artifacts in `bench2/results`;
there is no a priori claim that this representation wins every size or latency
metric against a flat dictionary format.

## Explicit limits

The search profile validates Unicode and reverses Unicode scalars, but only
folds ASCII case. Fuzzy distance is a bounded byte-distance scan; it is not a
Unicode grapheme edit distance or an indexed automaton. Grapheme spans are
rejected until a versioned segmentation profile exists. Byte, codepoint and
UTF-16 span bounds are implemented.

LexQL, regex/phrase search, TEI import/export and residual tapes, a DICT server,
language-analysis packs, prose alias interning, a shared eviction cache,
parallel codec scheduling and cold-section compression are deferred. Runtime
profile IDs are preserved metadata, not an installed language-analysis pack.
Open validates complete indexed sections and reads their digests; it is not
a constant-time, few-page mmap operation. Build-time deep validation costs are
included in build measurements. There is no line-count ceiling or compressed
source-code scoring rule.
