//! Native selective compressed read gate and explicit quiet-only timing client.
const std = @import("std");
const lex = @import("lex6");
const col = @import("columns.zig");
const reader = @import("reader.zig");
const Entry = lex.model.Entry;
const Query = enum { headword, label, source };
const Group = struct { first: usize, count: usize, flat: []const u8, baseline: lex.compression.Block, admitted: reader.Admitted(Entry) };
const Observation = struct {
    hash: u64 = 0,
    bytes: usize = 0,
    fn text(self: *Observation, bytes: []const u8) void {
        self.hash +%= std.hash.Wyhash.hash(@intCast(bytes.len), bytes);
        self.bytes += bytes.len;
    }
    fn add(self: *Observation, other: Observation) void {
        self.hash +%= other.hash;
        self.bytes += other.bytes;
    }
};
fn project(view: anytype, query: Query) !Observation {
    var out = Observation{};
    out.text(try (try view.field(.headword)).text());
    if (query == .headword) return out;
    var items = try (try view.field(.content)).values();
    while (try items.next()) |item| {
        const tag = try item.tag();
        if (query == .label and tag == .sense) {
            if (try (try (try item.payload(.sense)).field(.label)).optional()) |label| out.text(try label.text());
            return out;
        }
        if (query == .source and tag == .definition) {
            var inlines = try (try (try item.payload(.definition)).field(.content)).values();
            while (try inlines.next()) |inline_| {
                if (try inline_.tag() == .text) out.text(try (try inline_.payload(.text)).text());
            }
            return out;
        }
    }
    return out;
}
fn get32(bytes: []const u8, at: usize) usize {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn flatView(frame: []const u8, root: usize) !lex.packet_view.View(Entry) {
    const roots = get32(frame, 8);
    const payload_at = 64 + (roots + 1) * 4;
    const start = get32(frame, 64 + root * 4);
    const end = get32(frame, 64 + (root + 1) * 4);
    return lex.packet_view.fromVerifiedDocument(Entry, frame[payload_at + start .. payload_at + end], .{});
}
fn groupFor(groups: []const Group, ordinal: usize) usize {
    for (groups, 0..) |g, i| {
        if (ordinal < g.first + g.count) return i;
    }
    unreachable;
}
fn selected(total: usize, index: usize, mixed: bool) usize {
    return if (mixed) ((index *% 0x9e3779b1) +% 0x1234567) % total else total / 2;
}
fn timer(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}
fn elapsed(io: std.Io, start: i96) u64 {
    return @intCast(@max(@as(i96, 0), timer(io) - start));
}
pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const flat_path = args.next() orelse return error.MissingFlatBundle;
    const lane_directory = args.next() orelse return error.MissingLaneDirectory;
    const operations = try std.fmt.parseUnsigned(usize, args.next() orelse "512", 10);
    if (operations == 0 or operations > 1_000_000) return error.InvalidOperations;
    var quiet = false;
    if (args.next()) |arg| {
        if (!std.mem.eql(u8, arg, "--quiet-gate") or !std.mem.eql(u8, args.next() orelse "", "ROOT-EXPLICIT-QUIET-GATE")) return error.InvalidQuietGate;
        quiet = true;
    }
    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bundle = try std.Io.Dir.cwd().readFileAlloc(init.io, flat_path, a, .limited(512 * 1024 * 1024));
    if (bundle.len < 64 or !std.mem.eql(u8, bundle[0..5], "LPB1\x02")) return error.InvalidBundle;
    const page_count = get32(bundle, 8);
    const root_count = get32(bundle, 12);
    if (page_count > (bundle.len - 64) / 24) return error.InvalidBundle;
    const groups = try a.alloc(Group, page_count);
    var baseline_total: usize = 64 + 24 * page_count;
    var column_total: usize = baseline_total;
    const codec_limits = lex.compression.Limits{ .max_block_bytes = 1024 * 1024 };
    var offset: usize = 64 + 24 * page_count;
    var next_root: usize = 0;
    for (groups, 0..) |*group, i| {
        const directory = 64 + i * 24;
        const start = get32(bundle, directory);
        const count = get32(bundle, directory + 4);
        const raw = get32(bundle, directory + 8);
        const stored = get32(bundle, directory + 12);
        if (start != next_root or get32(bundle, directory + 16) != offset or raw != stored or stored > bundle.len - offset or bundle[directory + 20] != 0) return error.InvalidBundle;
        const flat = bundle[offset..][0..stored];
        offset += stored;
        next_root += count;
        const path = try std.fmt.allocPrint(a, "{s}/hot_cold.bzip3.{d:0>5}.lcc", .{ lane_directory, i });
        const lcc = try std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .limited(2 * 1024 * 1024));
        const admitted = try reader.open(Entry, allocator, lcc, .{}, .{});
        if (admitted.count != count) return error.RootCountMismatch;
        const baseline = try lex.compression.encode(allocator, flat, .bzip3, codec_limits);
        const decoded = try lex.compression.decode(allocator, baseline.codec, baseline.bytes, baseline.raw_len, codec_limits);
        defer {
            var owned = decoded;
            owned.deinit();
        }
        try std.testing.expectEqualSlices(u8, flat, decoded.bytes);
        group.* = .{ .first = start, .count = count, .flat = flat, .baseline = baseline, .admitted = admitted };
        baseline_total += baseline.bytes.len;
        column_total += lcc.len;
        inline for (.{ Query.headword, Query.label, Query.source }) |query| {
            var loaded = try admitted.load(allocator, query == .source);
            defer loaded.deinit();
            for (0..count) |root| {
                const expected = try project(try flatView(flat, root), query);
                const actual = try project(try loaded.view(root), query);
                try std.testing.expectEqualDeep(expected, actual);
            }
        }
    }
    defer {
        for (groups) |*group| group.baseline.deinit();
    }
    if (offset != bundle.len or next_root != root_count) return error.InvalidBundle;
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &stdout.interface;
    try std.json.Stringify.value(.{ .protocol = "LEXICAL-COLUMNS-ACCESS/1", .flat = flat_path, .lane_directory = lane_directory, .pages = page_count, .roots = root_count, .baseline_complete_bytes = baseline_total, .columns_complete_bytes = column_total, .gate = "full native admission of every compressed lane page; every canonical source frame exact; all headword/first-sense-label/first-definition projections equal for every root", .quiet_gate = quiet, .timing_scope = "resident immutable compressed pages; freshly decompress required blocks on every operation; no page cache; admission and full source oracle outside timing; one retained native Entry query model", .compression_allocation_scope = "Zig payload and per-call pinned libbz3 native state; malloc/RSS not individually metered" }, .{}, writer);
    try writer.writeByte('\n');
    try writer.flush();
    if (!quiet) return;
    inline for (.{ Query.headword, Query.label, Query.source }) |query| {
        inline for (.{ false, true }) |mixed| {
            var expected = Observation{};
            for (0..operations) |i| {
                const ordinal = selected(root_count, i, mixed);
                const group = groups[groupFor(groups, ordinal)];
                expected.add(try project(try flatView(group.flat, ordinal - group.first), query));
            }
            var baseline_result = Observation{};
            var baseline_decoded: usize = 0;
            const baseline_start = timer(init.io);
            for (0..operations) |i| {
                const ordinal = selected(root_count, i, mixed);
                const group = groups[groupFor(groups, ordinal)];
                var decoded = try lex.compression.decode(allocator, group.baseline.codec, group.baseline.bytes, group.baseline.raw_len, codec_limits);
                defer decoded.deinit();
                baseline_result.add(try project(try flatView(decoded.bytes, ordinal - group.first), query));
                baseline_decoded += decoded.raw_len;
            }
            const baseline_ns = elapsed(init.io, baseline_start);
            try std.testing.expectEqualDeep(expected, baseline_result);
            var columns_result = Observation{};
            var columns_decoded: usize = 0;
            const columns_start = timer(init.io);
            for (0..operations) |i| {
                const ordinal = selected(root_count, i, mixed);
                const group = groups[groupFor(groups, ordinal)];
                var loaded = try group.admitted.load(allocator, query == .source);
                defer loaded.deinit();
                columns_result.add(try project(try loaded.view(ordinal - group.first), query));
                columns_decoded += loaded.decodedBytes();
            }
            const columns_ns = elapsed(init.io, columns_start);
            try std.testing.expectEqualDeep(expected, columns_result);
            try std.json.Stringify.value(.{ .query = @tagName(query), .access = if (mixed) "mixed_root" else "same_root", .operations = operations, .baseline_ns = baseline_ns, .columns_ns = columns_ns, .speedup = @as(f64, @floatFromInt(baseline_ns)) / @as(f64, @floatFromInt(columns_ns)), .baseline_decoded_bytes = baseline_decoded, .columns_decoded_bytes = columns_decoded, .decoded_byte_reduction = @as(f64, @floatFromInt(baseline_decoded)) / @as(f64, @floatFromInt(columns_decoded)), .query_hash = expected.hash, .query_bytes = expected.bytes }, .{}, writer);
            try writer.writeByte('\n');
            try writer.flush();
        }
    }
}
