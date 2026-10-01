//! Compare frozen and candidate cores on identical native-rich documents.
//! Build/verification/setup and cold/warm access remain separate phases.
const std = @import("std");
const lex = @import("lex6");
const fixture = @import("fixture.zig");
const archive = lex.archive;
const packet = lex.packet;

const Meter = struct {
    child: std.mem.Allocator,
    calls: usize = 0,
    allocated: usize = 0,
    live: usize = 0,
    peak: usize = 0,
    start_live: usize = 0,

    fn reset(self: *Meter) void {
        self.calls = 0;
        self.allocated = 0;
        self.start_live = self.live;
        self.peak = self.live;
    }

    fn allocator(self: *Meter) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn account(self: *Meter, before: usize, after: usize) void {
        if (after > before) {
            self.live += after - before;
            self.allocated += after - before;
        } else self.live -= before - after;
        self.peak = @max(self.peak, self.live);
    }

    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *Meter = @ptrCast(@alignCast(context));
        const result = self.child.rawAlloc(length, alignment, address) orelse return null;
        self.calls += 1;
        self.account(0, length);
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, length: usize, address: usize) bool {
        const self: *Meter = @ptrCast(@alignCast(context));
        if (!self.child.rawResize(memory, alignment, length, address)) return false;
        self.account(memory.len, length);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, length: usize, address: usize) ?[*]u8 {
        const self: *Meter = @ptrCast(@alignCast(context));
        const result = self.child.rawRemap(memory, alignment, length, address) orelse return null;
        self.account(memory.len, length);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *Meter = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, address);
        self.account(memory.len, 0);
    }
};

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

fn phase(writer: *std.Io.Writer, name: []const u8, elapsed: u64, meter: *const Meter, checksum: u64, pages: usize) !void {
    try writer.print(
        "{{\"phase\":\"{s}\",\"ns\":{d},\"alloc_calls\":{d},\"allocated_bytes\":{d},\"peak_delta_bytes\":{d},\"checksum\":{d},\"page_loads\":{d}}}\n",
        .{ name, elapsed, meter.calls, meter.allocated, meter.peak - meter.start_live, checksum, pages },
    );
}

fn assertChecksum(expected: u64, actual: u64) !void {
    if (expected != actual) return error.IncorrectObservation;
}

fn consumeWire(value: anytype) !u64 {
    const headword = try (try value.field(.headword)).text();
    var items = try (try value.field(.content)).values();
    while (try items.next()) |item| {
        if (try item.tag() != .sense) continue;
        const sense = try item.payload(.sense);
        const label = (try (try sense.field(.label)).optional()).?;
        return fixture.consumeFields(headword, try label.text());
    }
    return error.MissingSense;
}

pub fn main(init: std.process.Init) !void {
    var arguments = std.process.Args.Iterator.init(init.minimal.args);
    _ = arguments.next();
    const count = if (arguments.next()) |text| try std.fmt.parseUnsigned(usize, text, 10) else 4096;
    if (count == 0 or count > 65_536) return error.InvalidCount;
    const mode_text = arguments.next() orelse "raw";
    const mode: lex.compression.Mode = if (std.mem.eql(u8, mode_text, "raw")) .raw else if (std.mem.eql(u8, mode_text, "adaptive")) .adaptive else return error.InvalidMode;

    var source_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer source_arena.deinit();
    const library = try fixture.make(source_arena.allocator(), count);
    var meter = Meter{ .child = std.heap.c_allocator };
    const allocator = meter.allocator();
    var output: [32 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &output);
    const writer = &stdout.interface;
    try writer.print("{{\"protocol\":\"LEX6-RICH-FRONTIER/1\",\"entries\":{d},\"mode\":\"{s}\",\"fixture\":\"fixed native rich multilingual control\",\"allocator_accounting\":\"Zig allocations; bzip3 C state excluded\"}}\n", .{ count, mode_text });

    meter.reset();
    var timer = Timer.init(init.io);
    const packet_bytes = try packet.encode(allocator, library.entries[0], .{});
    defer allocator.free(packet_bytes);
    try phase(writer, "packet_encode", timer.elapsed(), &meter, packet_bytes.len, 0);
    const single = try fixture.consume(&library.entries[0]);
    meter.reset();
    timer = .init(init.io);
    var checksum: u64 = 0;
    for (0..count) |_| {
        var decoded = try packet.decode(lex.model.Entry, allocator, packet_bytes, .{});
        defer decoded.deinit();
        checksum +%= try fixture.consume(&decoded.value);
    }
    try assertChecksum(single *% count, checksum);
    try phase(writer, "packet_owned_decode", timer.elapsed(), &meter, checksum, 0);
    if (comptime @hasDecl(packet, "decodeBorrowed")) {
        meter.reset();
        timer = .init(init.io);
        checksum = 0;
        for (0..count) |_| {
            var decoded = try packet.decodeBorrowed(lex.model.Entry, allocator, packet_bytes, .{});
            defer decoded.deinit();
            checksum +%= try fixture.consume(&decoded.value);
        }
        try assertChecksum(single *% count, checksum);
        try phase(writer, "packet_borrowed_decode", timer.elapsed(), &meter, checksum, 0);
    }

    var options = archive.Options{ .compression = mode };
    meter.reset();
    timer = .init(init.io);
    var plain = try archive.build(allocator, library, options);
    defer plain.deinit();
    try phase(writer, "build_plain", timer.elapsed(), &meter, plain.bytes.len, 0);
    var indexed: ?archive.Owned = null;
    defer if (indexed) |*owned| owned.deinit();
    if (comptime @hasField(archive.Options, "index_entry_ids")) {
        options.index_entry_ids = true;
        meter.reset();
        timer = .init(init.io);
        indexed = try archive.build(allocator, library, options);
        try phase(writer, "build_indexed", timer.elapsed(), &meter, indexed.?.bytes.len, 0);
    }
    const bytes = if (indexed) |owned| owned.bytes else plain.bytes;
    meter.reset();
    timer = .init(init.io);
    const view = try archive.Archive.open(bytes, .{});
    try phase(writer, "open", timer.elapsed(), &meter, view.entry_count, 0);
    meter.reset();
    timer = .init(init.io);
    var reader = try archive.Reader.init(allocator, &view, .{});
    defer reader.deinit();
    try phase(writer, "reader_init", timer.elapsed(), &meter, 0, 0);
    meter.reset();
    timer = .init(init.io);
    try reader.prepareLinks();
    try phase(writer, "prepare_links", timer.elapsed(), &meter, count, reader.stats.page_loads);
    var target = try reader.follow(.{ .entry = .{ .id = library.entries[count - 1].id, .fragment = "sense-primary" } });
    defer target.found.deinit();
    try std.testing.expectEqualDeep(library.entries[count - 1], target.found.document.value.entry);
    var expected: u64 = 0;
    for (library.entries) |*entry| expected +%= try fixture.consume(entry);

    // Complete native equality is a correctness gate outside every timer.
    for (library.entries, 0..) |entry, ordinal| {
        var decoded = try reader.load(archive.EntryId{ .value = @intCast(ordinal) });
        defer decoded.deinit();
        try std.testing.expectEqualDeep(entry, decoded.value);
    }
    meter.reset();
    timer = .init(init.io);
    checksum = 0;
    for (0..count) |ordinal| {
        var decoded = try view.load(allocator, archive.EntryId{ .value = @intCast(ordinal) });
        defer decoded.deinit();
        checksum +%= try fixture.consume(&decoded.value);
    }
    try assertChecksum(expected, checksum);
    try phase(writer, "cold_admitted_load", timer.elapsed(), &meter, checksum, count);
    if (comptime @hasDecl(archive.Archive, "inspect")) {
        meter.reset();
        timer = .init(init.io);
        checksum = 0;
        for (0..count) |ordinal| {
            var decoded = try view.inspect(allocator, archive.EntryId{ .value = @intCast(ordinal) });
            defer decoded.deinit();
            checksum +%= try fixture.consume(&decoded.value);
        }
        try assertChecksum(expected, checksum);
        try phase(writer, "cold_admitted_inspection", timer.elapsed(), &meter, checksum, count);
    }
    meter.reset();
    timer = .init(init.io);
    checksum = 0;
    const before_pages = reader.stats.page_loads;
    for (0..count) |ordinal| {
        var decoded = try reader.load(archive.EntryId{ .value = @intCast(ordinal) });
        defer decoded.deinit();
        checksum +%= try fixture.consume(&decoded.value);
    }
    try assertChecksum(expected, checksum);
    try phase(writer, "cached_admitted_load", timer.elapsed(), &meter, checksum, reader.stats.page_loads - before_pages);

    if (comptime @hasDecl(archive, "VerifiedArchive") and @hasDecl(archive.VerifiedArchive, "view")) {
        meter.reset();
        timer = .init(init.io);
        const verified = try view.verify(allocator);
        try phase(writer, "full_semantic_verification", timer.elapsed(), &meter, count, view.page_count);
        meter.reset();
        timer = .init(init.io);
        checksum = 0;
        for (0..count) |ordinal| {
            var projected = try verified.view(allocator, archive.EntryId{ .value = @intCast(ordinal) });
            defer projected.deinit();
            checksum +%= try consumeWire(projected.value);
        }
        try assertChecksum(expected, checksum);
        try phase(writer, "prepared_uncached_wire_projection", timer.elapsed(), &meter, checksum, if (mode == .raw) 0 else count);
        if (comptime @hasDecl(archive, "VerifiedReader")) {
            meter.reset();
            timer = .init(init.io);
            var projected_reader = try archive.VerifiedReader.init(allocator, verified);
            defer projected_reader.deinit();
            try phase(writer, "verified_reader_init", timer.elapsed(), &meter, 0, 0);
            meter.reset();
            timer = .init(init.io);
            checksum = 0;
            for (0..count) |ordinal| checksum +%= try consumeWire(try projected_reader.view(archive.EntryId{ .value = @intCast(ordinal) }));
            try assertChecksum(expected, checksum);
            try phase(writer, "prepared_cached_wire_projection", timer.elapsed(), &meter, checksum, projected_reader.stats.page_loads);
            const warm = try projected_reader.view(archive.EntryId{ .value = 0 });
            meter.reset();
            timer = .init(init.io);
            checksum = 0;
            for (0..count) |_| checksum +%= try consumeWire(warm);
            try assertChecksum(single *% count, checksum);
            try phase(writer, "retained_wire_field_projection", timer.elapsed(), &meter, checksum, 0);
        }
    } else {
        meter.reset();
        timer = .init(init.io);
        try view.verifyAll(allocator);
        try phase(writer, "full_semantic_verification", timer.elapsed(), &meter, count, view.page_count);
    }
    try writer.flush();
}
