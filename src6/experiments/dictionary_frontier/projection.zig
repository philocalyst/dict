//! Common frozen/candidate client for natural dictionary projection access.
//! These archives contain the independently preserved source projection as one
//! definition with one Inline.text per entry. This is deliberately narrower
//! than the native-rich control: no semantic graph or markup rendering claim.
//! Full semantic verification is charged as setup. All source text and the
//! headword are consumed freshly through each measured path; no answer table
//! is passed to a reader. RAM is warm; application page caches start empty.
const std = @import("std");
const lex = @import("lex6");
const archive = lex.archive;

const Timer = struct {
    io: std.Io,
    start: i96,
    fn init(io: std.Io) Timer {
        return .{ .io = io, .start = std.Io.Clock.awake.now(io).nanoseconds };
    }
    fn elapsed(self: Timer) u64 {
        return @intCast(@max(@as(i96, 0), std.Io.Clock.awake.now(self.io).nanoseconds - self.start));
    }
};

const Observation = struct {
    checksum: u64 = 0,
    consumed_bytes: u64 = 0,
    fn add(self: *Observation, other: Observation) void {
        self.checksum +%= other.checksum;
        self.consumed_bytes += other.consumed_bytes;
    }
};

fn consumeFields(headword: []const u8, definition: []const u8) Observation {
    var hash = std.hash.Wyhash.init(0x6e61747572616c36);
    // Length prefixes prevent ambiguity between a headword suffix and prose.
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, headword.len, .little);
    hash.update(&length);
    hash.update(headword);
    std.mem.writeInt(u64, &length, definition.len, .little);
    hash.update(&length);
    hash.update(definition);
    return .{ .checksum = hash.final(), .consumed_bytes = headword.len + definition.len };
}

fn shape(value: *const lex.model.Entry) !void {
    if (value.content.len != 1 or value.content[0] != .definition) return error.InvalidProjectionShape;
    const definition = value.content[0].definition;
    if (definition.content.len != 1 or definition.content[0] != .text) return error.InvalidProjectionShape;
}

fn consumeNative(value: *const lex.model.Entry) !Observation {
    var definitions = lex.query.entry(value).select(.definition, .children);
    const definition = (try definitions.next()) orelse return error.MissingDefinition;
    // The untimed all-entry gate establishes that this is exactly the bytes
    // plain rendering writes, rather than a shortcut for arbitrary rich text.
    const bytes = switch (definition.value.content[0]) {
        .text => |text| text,
        else => return error.InvalidProjectionShape,
    };
    return consumeFields(value.headword, bytes);
}

fn consumeWire(value: anytype) !Observation {
    const headword = try (try value.field(.headword)).text();
    var items = try (try value.field(.content)).values();
    const item = (try items.next()) orelse return error.MissingDefinition;
    const definition = try item.payload(.definition);
    var inlines = try (try definition.field(.content)).values();
    const inline_ = (try inlines.next()) orelse return error.InvalidProjectionShape;
    const bytes = try (try inline_.payload(.text)).text();
    return consumeFields(headword, bytes);
}

fn phase(writer: *std.Io.Writer, name: []const u8, ns: u64, observed: Observation, operations: usize, page_loads: usize) !void {
    try writer.print("{{\"phase\":\"{s}\",\"ns\":{d},\"checksum\":{d},\"consumed_bytes\":{d},\"operations\":{d},\"page_loads\":{d}}}\n", .{ name, ns, observed.checksum, observed.consumed_bytes, operations, page_loads });
}

fn ordinal(entries: usize, operations: usize, index: usize, mixed: bool) u32 {
    if (!mixed or operations == 1) return 0;
    return @intCast(@as(u64, index) * @as(u64, entries - 1) / @as(u64, operations - 1));
}

fn same(expected: Observation, actual: Observation) !void {
    if (expected.checksum != actual.checksum or expected.consumed_bytes != actual.consumed_bytes) return error.IncorrectObservation;
}

fn nativeBatch(io: std.Io, writer: *std.Io.Writer, allocator: std.mem.Allocator, view: *const archive.Archive, operations: usize, mixed: bool) !Observation {
    const init_timer = Timer.init(io);
    var reader = try archive.Reader.init(allocator, view, .{});
    defer reader.deinit();
    try phase(writer, if (mixed) "native_mixed_reader_init" else "native_samepage_reader_init", init_timer.elapsed(), .{}, 0, reader.stats.page_loads);
    const previous_pages = reader.stats.page_loads;
    const timer = Timer.init(io);
    var observed = Observation{};
    for (0..operations) |index| {
        var decoded = try reader.load(archive.EntryId{ .value = ordinal(view.entry_count, operations, index, mixed) });
        defer decoded.deinit();
        observed.add(try consumeNative(&decoded.value));
    }
    try phase(writer, if (mixed) "native_mixed_access" else "native_samepage_access", timer.elapsed(), observed, operations, reader.stats.page_loads - previous_pages);
    return observed;
}

fn wireBatch(io: std.Io, writer: *std.Io.Writer, allocator: std.mem.Allocator, proof: anytype, entries: usize, operations: usize, mixed: bool, expected: Observation) !void {
    const init_timer = Timer.init(io);
    var reader = try archive.VerifiedReader.init(allocator, proof);
    defer reader.deinit();
    try phase(writer, if (mixed) "wire_mixed_reader_init" else "wire_samepage_reader_init", init_timer.elapsed(), .{}, 0, reader.stats.page_loads);
    const previous_pages = reader.stats.page_loads;
    const timer = Timer.init(io);
    var observed = Observation{};
    for (0..operations) |index| {
        observed.add(try consumeWire(try reader.view(archive.EntryId{ .value = ordinal(entries, operations, index, mixed) })));
    }
    const elapsed = timer.elapsed();
    try same(expected, observed);
    try phase(writer, if (mixed) "wire_mixed_access" else "wire_samepage_access", elapsed, observed, operations, reader.stats.page_loads - previous_pages);
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const path = args.next() orelse return error.MissingArchive;
    const operations = if (args.next()) |text| try std.fmt.parseUnsigned(usize, text, 10) else 1024;
    if (operations == 0 or operations > 1_000_000 or args.next() != null) return error.InvalidOperations;
    const allocator = std.heap.c_allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(512 * 1024 * 1024));
    defer allocator.free(bytes);
    var output: [32 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &output);
    const writer = &stdout.interface;
    const open_timer = Timer.init(init.io);
    const view = try archive.Archive.open(bytes, .{});
    const open_ns = open_timer.elapsed();
    if (view.entry_count == 0) return error.EmptyArchive;
    try std.json.Stringify.value(.{
        .protocol = "LEX6-NATURAL-PROJECTION/1",
        .archive = path,
        .archive_bytes = bytes.len,
        .entries = view.entry_count,
        .pages = view.page_count,
        .operations = operations,
        .workload = "natural source projection: headword plus complete single-definition Inline.text",
        .shape_gate = "all entries; exactly one definition containing exactly one Inline.text",
        .cold = "fresh application page cache; memory-resident previously touched bytes",
        .allocation_accounting = "none; this client reports time, page loads, consumed bytes, and checksum",
    }, .{}, writer);
    try writer.writeByte('\n');
    try phase(writer, "open", open_ns, .{ .checksum = view.entry_count }, 0, 0);

    const verification_timer = Timer.init(init.io);
    const verified = if (comptime @hasDecl(archive, "VerifiedArchive") and @hasDecl(archive.Archive, "verify"))
        try view.verify(allocator)
    else proof: {
        try view.verifyAll(allocator);
        break :proof {};
    };
    try phase(writer, "full_semantic_verification", verification_timer.elapsed(), .{ .checksum = view.entry_count }, view.entry_count, view.page_count);

    // Shape and complete native traversal are outside access timers. They
    // validate every record, not just the later sampled ordinals, while
    // retaining only a checksum and no precomputed query answers.
    var gate_reader = try archive.Reader.init(allocator, &view, .{});
    defer gate_reader.deinit();
    var all = Observation{};
    var first = Observation{};
    for (0..view.entry_count) |index| {
        var decoded = try gate_reader.load(archive.EntryId{ .value = @intCast(index) });
        defer decoded.deinit();
        try shape(&decoded.value);
        const observed = try consumeNative(&decoded.value);
        all.add(observed);
        if (index == 0) first = observed;
    }
    try writer.print("{{\"gate\":\"all_entries_validated\",\"entries\":{d},\"checksum\":{d},\"consumed_bytes\":{d}}}\n", .{ view.entry_count, all.checksum, all.consumed_bytes });

    const samepage = try nativeBatch(init.io, writer, allocator, &view, operations, false);
    try same(.{ .checksum = first.checksum *% operations, .consumed_bytes = first.consumed_bytes * operations }, samepage);
    const mixed = try nativeBatch(init.io, writer, allocator, &view, operations, true);
    if (comptime @hasDecl(archive, "VerifiedReader")) {
        try wireBatch(init.io, writer, allocator, verified, view.entry_count, operations, false, samepage);
        try wireBatch(init.io, writer, allocator, verified, view.entry_count, operations, true, mixed);
    }
    try writer.flush();
}
