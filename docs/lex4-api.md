# LEX4 API

LEX4 has one durable identity rule: a value is identified by its typed rank,
never by an offset or an application ID. The public reader follows that rule
all the way through. Opening is envelope-only, verification is explicit, hot
queries do not allocate, and every operation that may need memory accepts
caller-owned storage.

```zig
const std = @import("std");
const lex = @import("src4");

fn definitionFor(
    allocator: std.mem.Allocator,
    snapshot_bytes: []const u8,
    headword: []const u8,
    output: []u8,
    render_stack: []lex.snapshot.RenderFrame,
) !?[]const u8 {
    // Keep this value at a stable address while any query, entry, or iterator
    // borrowed from it is alive.
    var book = try lex.Snapshot.openUncached(snapshot_bytes, .{
        .limits = .{
            .max_file_bytes = 64 * 1024 * 1024,
            .max_section_bytes = 32 * 1024 * 1024,
            .max_entries = 2_000_000,
        },
    });
    try book.verify(allocator);

    var query = try book.query();
    const roots = try query.entriesForHeadword(headword) orelse return null;
    const first = try query.entry(roots.lo, output) orelse return null;

    var definitions = try first.texts(.definition);
    const definition = try definitions.next() orelse return null;
    const written = try definition.render(output, render_stack);
    return output[0..written];
}
```

The comptime kind is part of each rank and result type. A definition rank
cannot be passed to an example query, and projecting an entry to `.sense`
returns an `Interval(.sense)` rather than two untyped integers:

```zig
const senses = try entry.project(.sense);
const definitions = try query.nodesForPrefix(.definition, "ban");
```

For composed navigation, keep a typed selection until you choose to iterate:

```zig
const entries = try query.entries("ban");
var definitions = entries.descendants(.sense).descendants(.definition).texts();
while (try definitions.next()) |text| {
    const written = try text.render(&output, &render_stack);
    useText(output[0..written]);
}

const selected = try query.select(.sense, .{ .list = &sense_ranks });
var examples = selected.descendants(.example).texts();

const members = try query.members(concept_rank);
var related_definitions = members.descendants(.definition).texts();
```

Selections are immutable plans; each iterator owns its position. Rank lists
are borrowed, sorted, and duplicate-free, and must remain unchanged during
iteration. Disjoint or nested selected senses retain their exact subtree
scope. Text iteration preserves zero/many prose items per text node and emits
each item once. The schema's legal-parent graph proves when an intermediate
kind is redundant: entry→sense→definition compiles to entry→definition,
but sense→subsense→definition does not include the outer sense's definition.
No query-time allocation or materialized intermediate rank array is needed.
Structural selection first verifies the forest's semantic topology (once,
without allocation), so compile-time path proofs cannot be applied to an
illegally nested authenticated tree. Key-only queries need not do that walk.
`members` checks that the concept index's sense domain has the forest's
cardinality. Its compiler must also assign those ranks in forest kind order;
source IDs are identities, not an alternate rank ordering. Independent
concept domains remain accessible through `book.concepts()`, but are not
automatically valid structural selections.

Headwords and forms deliberately have different results. `exact` exposes an
entry interval for a headword and an explicit target list for a form. Prefix
enumeration retains that distinction:

```zig
var key_bytes: [256]u8 = undefined;
var frames: [64]lex.automaton.Frame = undefined;
var matches = try query.prefix("walk", &key_bytes, &frames);
while (try matches.next()) |match| switch (match.kind) {
    .entry => useHomographs(match.entries.?),
    .form => useTargets(match.targets.iterator()),
};
```

Derived axes are selected at comptime, so reversal, normalization, and
phonetic lookup share one implementation without a runtime strategy object:

```zig
const suffix_index = try book.axis(lex.axes.Reverse);
const normalized_index = try book.axis(lex.axes.Normalized);
```

Concept and relation sections have short, direct entry points:

```zig
const concept_index = try book.concepts();
const graph = try book.relations();
```

For mapped files, pass `Snapshot.open` a caller-owned writable trust bitmap.
It memoizes authenticated pages without hiding allocation in a query. The
snapshot bytes, trust bitmap, and stable `Snapshot` address must outlive all
borrowed views and iterators. `openUncached` is convenient for small or
short-lived snapshots and authenticates touched pages without memoization.

The writer mirrors the reader. Independent section builders produce canonical
bytes; `compiler.prepare` proves their cross-section invariants; and the
prepared value's `emit` method publishes the authenticated container. This
keeps expensive offline construction separate from the tiny runtime surface.

The prose builder uses a deterministic, bounded-sample Re-Pair heuristic. In
each round it counts at most `grammar.Options.max_pair_occurrences` adjacent
symbols rather than claiming an exact corpus-wide pair census. Raising that
cap may improve compression at the cost of compiler memory and time; the wire
format and allocation-free query API are unchanged. Mapped prose readers use
`grammar.ViewFor(Source)`, which routes rule, sequence, item-boundary, alias
bit, alias-rank, and alias-target reads through `Source.bytes`. For standalone
buffers, `grammar.ViewFor([]const u8)` is the zero-wrapper specialization.
All source contracts share the same expansion and validation engines. Render
scratch is an array of opaque four-byte `RenderFrame` slots: leave it
uninitialized and let the renderer use it. Sequence state is not stored in
each stack frame.

`lex.table.Table(Row)` is the shared record codec behind graph records and
text ownership. It derives scalar leaves from nested Zig structs (unsigned
integers up to 32 bits, booleans, unsigned enums, and optional scalars).
Every nonzero leaf uses
`base + step * row + packed_residual`; constant and affine fields have no
residual payload. `View.open` lowers the descriptors once into fixed borrowed
lanes, `verify` checks all scalar values, and `field(row, .name)` reads only
the named field. Full row reads and binary-search key reads use the same
schema, not separate serializers. The input bytes must remain immutable for
the view's lifetime.
