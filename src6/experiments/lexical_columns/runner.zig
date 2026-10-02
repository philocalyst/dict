//! Transform the already locked native-equal flat LPB1 groups, retain all roots.
const std = @import("std");
const lex = @import("lex6");
const col = @import("columns.zig");
const workloads = @import("workloads");
const Entry = lex.model.Entry;
const Sha256 = std.crypto.hash.sha2.Sha256;
fn get32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn put32(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, bytes[at..][0..4], @intCast(value), .little);
}
fn digest(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    var h = Sha256.init(.{});
    h.update(bytes[0..32]);
    h.update(bytes[64..]);
    h.final(&out);
    return out;
}
fn projection(view: col.View(Entry, Entry), entry: Entry) !void {
    try std.testing.expectEqualStrings(entry.headword, try (try view.field(.headword)).text());
    var items = try (try view.field(.content)).values();
    var ordinal: usize = 0;
    while (try items.next()) |item| {
        const native = entry.content[ordinal];
        ordinal += 1;
        try std.testing.expectEqual(std.meta.activeTag(native), try item.tag());
        if (try item.tag() == .sense) {
            const label = try (try (try item.payload(.sense)).field(.label)).optional();
            if (native.sense.label) |text| try std.testing.expectEqualStrings(text, try label.?.text()) else try std.testing.expect(label == null);
        }
        if (try item.tag() == .definition) {
            var inlines = try (try (try item.payload(.definition)).field(.content)).values();
            var index: usize = 0;
            while (try inlines.next()) |inline_| {
                const original = native.definition.content[index];
                index += 1;
                try std.testing.expectEqual(std.meta.activeTag(original), try inline_.tag());
                if (try inline_.tag() == .text) try std.testing.expectEqualStrings(original.text, try (try inline_.payload(.text)).text());
            }
        }
    }
    try std.testing.expectEqual(entry.content.len, ordinal);
}
pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const input = args.next() orelse return error.MissingInput;
    const output = args.next() orelse return error.MissingOutput;
    const threshold = try std.fmt.parseUnsigned(u16, args.next() orelse "256", 10);
    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, input, a, .limited(512 * 1024 * 1024));
    if (bytes.len < 64 or !std.mem.eql(u8, bytes[0..5], "LPB1\x02") or get32(bytes, 16) != 24 or !std.mem.eql(u8, &digest(bytes), bytes[32..64])) return error.InvalidInputBundle;
    const pages = get32(bytes, 8);
    const roots = get32(bytes, 12);
    if (pages > (bytes.len - 64) / 24) return error.InvalidInputBundle;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, bytes[0 .. 64 + @as(usize, pages) * 24]);
    var identities: std.StringHashMap(void) = .init(a);
    var source_observation: u64 = 0;
    var max_page: usize = 0;
    var exceptional_pages: usize = 0;
    var at: usize = 64 + @as(usize, pages) * 24;
    var next_root: usize = 0;
    var raw_total: usize = 0;
    var structure_bytes: usize = 0;
    var literal_bytes: usize = 0;
    for (0..pages) |i| {
        const directory = 64 + i * 24;
        const first = get32(bytes, directory);
        const count = get32(bytes, directory + 4);
        const raw = get32(bytes, directory + 8);
        const stored = get32(bytes, directory + 12);
        const offset = get32(bytes, directory + 16);
        if (first != next_root or offset != at or raw != stored or bytes[directory + 20] != 0 or stored > bytes.len - at) return error.InvalidInputBundle;
        const frame = bytes[at..][0..stored];
        at += stored;
        next_root += count;
        if (frame.len < 64 or !std.mem.eql(u8, frame[0..6], "LPD1\x01\x00") or get32(frame, 8) != count or get32(frame, 12) != count or !std.mem.eql(u8, &digest(frame), frame[32..64])) return error.InvalidInputFrame;
        const offsets_end = 64 + (@as(usize, count) + 1) * 4;
        if (offsets_end > frame.len or get32(frame, 64) != 0 or get32(frame, offsets_end - 4) != frame.len - offsets_end) return error.InvalidInputFrame;
        const packets = try a.alloc([]const u8, count);
        const entries = try a.alloc(Entry, count);
        for (packets, entries, 0..) |*wire, *entry, root| {
            const start = get32(frame, 64 + root * 4);
            const end = get32(frame, 64 + (root + 1) * 4);
            if (end < start or end > frame.len - offsets_end) return error.InvalidInputFrame;
            wire.* = frame[offsets_end + start .. offsets_end + end];
            const decoded = try lex.packet.decode(Entry, a, wire.*, .{});
            entry.* = decoded.value;
            try lex.validate.check(a, entry, .{});
            const result = try identities.getOrPut(entry.id);
            if (result.found_existing) return error.DuplicateIdentity;
            source_observation +%= (try workloads.observe(entry)).hash;
        }
        const transformed = try col.encodePackets(Entry, a, packets, threshold, .{});
        const page = try col.open(Entry, transformed, .{});
        const prepared = try page.prepare(a, .{});
        for (packets, entries, 0..) |original, entry, root| {
            const restored = try page.restorePacket(a, root);
            try std.testing.expectEqualSlices(u8, original, restored);
            var decoded = try page.decode(allocator, root);
            defer decoded.deinit();
            try std.testing.expect(workloads.nativeEqual(Entry, entry, decoded.value));
            try std.testing.expectEqualDeep(try workloads.observe(&entry), try workloads.observe(&decoded.value));
            try projection(try prepared.view(root), entry);
        }
        put32(out.items, directory + 8, transformed.len);
        put32(out.items, directory + 12, transformed.len);
        put32(out.items, directory + 16, out.items.len);
        try out.appendSlice(a, transformed);
        raw_total += transformed.len;
        structure_bytes += page.skeleton.len;
        for (page.lanes) |lane| literal_bytes += lane.len;
        max_page = @max(max_page, transformed.len);
        if (transformed.len > 65536) exceptional_pages += 1;
    }
    if (next_root != roots or at != bytes.len) return error.InvalidInputBundle;
    std.mem.writeInt(u64, out.items[24..32], raw_total, .little);
    @memcpy(out.items[32..64], &digest(out.items));
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output, .data = out.items });
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try std.json.Stringify.value(.{ .protocol = "LEXICAL-COLUMNS/1", .input = input, .output = output, .threshold = threshold, .pages = pages, .roots = roots, .complete_raw_bytes = out.items.len, .structure_bytes = structure_bytes, .literal_bytes = literal_bytes, .max_raw_page_bytes = max_page, .pages_over_64KiB = exceptional_pages, .all_native_observation_checksum = source_observation, .gate = "all original roots globally unique; canonical packets exact; complete native equality/independent observation; full native semantic admission; headword/sense-label/definition typed projections exact", .timing = false }, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}
