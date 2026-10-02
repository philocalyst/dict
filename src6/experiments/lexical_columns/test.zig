const std = @import("std");
const lex = @import("lex6");
const col = @import("columns.zig");
const workloads = @import("workloads");

test "varied native roots restore exact canonical packets and hot projections" {
    var source = try workloads.rich(std.testing.allocator, 12);
    defer source.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const packets = try a.alloc([]const u8, source.entries.len);
    for (source.entries, packets) |entry, *bytes| bytes.* = try lex.packet.encode(a, entry, .{});
    inline for (.{ @as(u16, 0), @as(u16, 256), @as(u16, 1) }) |threshold| {
        const bytes = try col.encodePackets(lex.model.Entry, a, packets, threshold, .{});
        const page = try col.open(lex.model.Entry, bytes, .{});
        const prepared = try page.prepare(a, .{});
        for (source.entries, packets, 0..) |entry, original, i| {
            const restored = try page.restorePacket(a, i);
            try std.testing.expectEqualSlices(u8, original, restored);
            var decoded = try page.decode(std.testing.allocator, i);
            defer decoded.deinit();
            try std.testing.expect(workloads.nativeEqual(lex.model.Entry, entry, decoded.value));
            try std.testing.expectEqualDeep(try workloads.observe(&entry), try workloads.observe(&decoded.value));
            const view = try prepared.view(i);
            try std.testing.expectEqualStrings(entry.headword, try (try view.field(.headword)).text());
            var items = try (try view.field(.content)).values();
            var ordinal: usize = 0;
            while (try items.next()) |item| {
                try std.testing.expectEqual(std.meta.activeTag(entry.content[ordinal]), try item.tag());
                ordinal += 1;
            }
            try std.testing.expectEqual(entry.content.len, ordinal);
        }
    }
}
test "truncation schema and repaired checkpoint corruption reject" {
    const a = std.testing.allocator;
    const entry = lex.model.Entry{ .id = "one", .headword = "猫", .content = &.{.{ .definition = .{ .content = &.{.{ .text = "several bytes" }} } }} };
    const original = try lex.packet.encode(a, entry, .{});
    defer a.free(original);
    const bytes = try col.encodePackets(lex.model.Entry, a, &.{original}, 8, .{});
    defer a.free(bytes);
    for (0..bytes.len) |n| {
        if (col.open(lex.model.Entry, bytes[0..n], .{})) |_| return error.AcceptedTruncation else |_| {}
    }
    try std.testing.expectError(error.InvalidSchema, col.open(lex.model.Resource, bytes, .{}));
}

const reader = @import("reader.zig");
fn rawContainer(allocator: std.mem.Allocator, frame: []const u8) ![]u8 {
    const n = comptime col.laneCount(lex.model.Entry);
    const roots = std.mem.readInt(u32, frame[8..12], .little);
    const metadata_bytes = (@as(usize, roots) + 1) * (n + 1) * 4 + n * 4 + std.mem.readInt(u32, frame[16..20], .little);
    const page = try col.open(lex.model.Entry, frame, .{});
    const hot_len = metadata_bytes + page.lanes[0].len + page.lanes[2].len + page.lanes[3].len;
    const cold_len = page.lanes[1].len;
    const result = try allocator.alloc(u8, 112 + hot_len + cold_len);
    @memset(result[0..112], 0);
    @memcpy(result[0..8], "LCC1\x01\x01\x00\x00");
    std.mem.writeInt(u32, result[8..12], 2, .little);
    std.mem.writeInt(u32, result[12..16], @intCast(frame.len), .little);
    @memcpy(result[16..80], frame[0..64]);
    std.mem.writeInt(u32, result[80..84], @intCast(hot_len), .little);
    std.mem.writeInt(u32, result[84..88], @intCast(hot_len), .little);
    std.mem.writeInt(u32, result[88..92], 112, .little);
    std.mem.writeInt(u32, result[96..100], @intCast(cold_len), .little);
    std.mem.writeInt(u32, result[100..104], @intCast(cold_len), .little);
    std.mem.writeInt(u32, result[104..108], @intCast(112 + hot_len), .little);
    @memcpy(result[112..][0..metadata_bytes], frame[64..][0..metadata_bytes]);
    var at: usize = 112 + metadata_bytes;
    inline for (.{ @as(usize, 0), @as(usize, 2), @as(usize, 3) }) |lane| {
        @memcpy(result[at..][0..page.lanes[lane].len], page.lanes[lane]);
        at += page.lanes[lane].len;
    }
    @memcpy(result[at..], page.lanes[1]);
    return result;
}
test "admitted sparse optional lanes project labels with all required literal payload absent" {
    var source = try workloads.rich(std.testing.allocator, 3);
    defer source.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const packets = try a.alloc([]const u8, source.entries.len);
    for (source.entries, packets) |entry, *packet| packet.* = try lex.packet.encode(a, entry, .{});
    const frame = try col.encodePackets(lex.model.Entry, a, packets, 65535, .{});
    const compressed = try rawContainer(a, frame);
    const admitted = try reader.open(lex.model.Entry, std.testing.allocator, compressed, .{}, .{});
    var loaded = try admitted.load(std.testing.allocator, false);
    defer loaded.deinit();
    try std.testing.expect(loaded.prepared.page.lanes[1].len == 0);
    try std.testing.expect(loaded.decodedBytes() < frame.len / 2);
    for (source.entries, 0..) |entry, i| {
        const view = try loaded.view(i);
        try std.testing.expectEqualStrings(entry.headword, try (try view.field(.headword)).text());
        var items = try (try view.field(.content)).values();
        var ordinal: usize = 0;
        while (try items.next()) |item| {
            const original = entry.content[ordinal];
            ordinal += 1;
            if (try item.tag() == .sense) {
                const label = (try (try (try item.payload(.sense)).field(.label)).optional()).?;
                try std.testing.expectEqualStrings(original.sense.label.?, try label.text());
                var contents = try (try (try item.payload(.sense)).field(.content)).values();
                const definition = (try contents.next()).?;
                var prose = try (try (try definition.payload(.definition)).field(.content)).values();
                const text = try (try prose.next()).?.payload(.text);
                try std.testing.expectError(error.LaneNotLoaded, text.text());
            }
        }
    }
    var full = try admitted.load(std.testing.allocator, true);
    defer full.deinit();
    for (packets, 0..) |packet, i| {
        const restored = try full.prepared.page.restorePacket(a, i);
        try std.testing.expectEqualSlices(u8, packet, restored);
    }
    for (0..compressed.len) |size| {
        if (reader.open(lex.model.Entry, std.testing.allocator, compressed[0..size], .{}, .{})) |_| return error.AcceptedContainerTruncation else |_| {}
    }
}

fn repairDigest(bytes: []u8) void {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(bytes[0..32]);
    hash.update(bytes[64..]);
    hash.final(bytes[32..64]);
}
test "repaired hostile offsets and lane checkpoints reject before slicing" {
    const a = std.testing.allocator;
    const packet = try lex.packet.encode(a, lex.model.Entry{ .id = "one", .headword = "猫" }, .{});
    defer a.free(packet);
    const frame = try col.encodePackets(lex.model.Entry, a, &.{packet}, 256, .{});
    defer a.free(frame);
    const mutated = try a.dupe(u8, frame);
    defer a.free(mutated);
    std.mem.writeInt(u32, mutated[68..72], 100000, .little);
    repairDigest(mutated);
    try std.testing.expectError(error.InvalidPage, col.open(lex.model.Entry, mutated, .{}));
    @memcpy(mutated, frame);
    const cp_at: usize = 72;
    std.mem.writeInt(u32, mutated[cp_at + 4 * 4 + 3 * 4 ..][0..4], 100000, .little);
    repairDigest(mutated);
    try std.testing.expectError(error.InvalidCheckpoint, col.open(lex.model.Entry, mutated, .{}));
    try std.testing.expectError(error.PageTooLarge, col.encodePackets(lex.model.Entry, a, &.{packet}, 256, .{ .max_page_bytes = 80 }));
    try std.testing.expectError(error.TooManyRoots, col.encodePackets(lex.model.Entry, a, &.{ packet, packet }, 256, .{ .max_roots = 1 }));
    const page = try col.open(lex.model.Entry, frame, .{});
    var limited = page;
    limited.limits.packet.max_input_bytes = 5;
    try std.testing.expectError(error.InputTooLarge, limited.restorePacket(a, 0));
    limited = page;
    limited.limits.packet.max_work = 1;
    try std.testing.expectError(error.WorkLimit, limited.restorePacket(a, 0));
}
test "native arbitrary source bytes duplicate collections and exact Unicode survive" {
    const a = std.testing.allocator;
    const raw = [_]u8{ 0, 255, 128, 10, 0x61 };
    const entry = lex.model.Entry{ .id = "𐀀-é-é", .headword = "猫\x00é é", .sources = &.{.{ .id = "raw", .media_type = "application/octet-stream", .bytes = &raw }}, .content = &.{.{ .note = .{ .content = &.{ .{ .text = "two" }, .{ .text = "two" } } } }} };
    try lex.validate.check(a, &entry, .{});
    const packet = try lex.packet.encode(a, entry, .{});
    defer a.free(packet);
    const frame = try col.encodePackets(lex.model.Entry, a, &.{packet}, 65535, .{});
    defer a.free(frame);
    const page = try col.open(lex.model.Entry, frame, .{});
    const prepared = try page.prepare(a, .{});
    var decoded = try page.decode(a, 0);
    defer decoded.deinit();
    try std.testing.expect(workloads.nativeEqual(lex.model.Entry, entry, decoded.value));
    const view = try prepared.view(0);
    try std.testing.expectEqual(@as(@FieldType(lex.model.Entry, "kind"), .word), try (try view.field(.kind)).scalar());
    var contents = try (try view.field(.content)).values();
    var item = try (try contents.next()).?.decodeOwned(a);
    defer item.deinit();
    try std.testing.expect(workloads.nativeEqual(lex.model.Item, entry.content[0], item.value));
}
fn allocationFailures(allocator: std.mem.Allocator) !void {
    const entry = lex.model.Entry{ .id = "one", .headword = "猫", .content = &.{.{ .sense = .{ .label = "a label", .content = &.{.{ .definition = .{ .content = &.{.{ .text = "a full definition" }} } }} } }} };
    const packet = try lex.packet.encode(allocator, entry, .{});
    defer allocator.free(packet);
    const frame = try col.encodePackets(lex.model.Entry, allocator, &.{packet}, 65535, .{});
    defer allocator.free(frame);
    const compressed = try rawContainer(allocator, frame);
    defer allocator.free(compressed);
    const admitted = try reader.open(lex.model.Entry, allocator, compressed, .{}, .{});
    var loaded = try admitted.load(allocator, false);
    defer loaded.deinit();
    const view = try loaded.view(0);
    try std.testing.expectEqualStrings(entry.headword, try (try view.field(.headword)).text());
}
test "encoder admission and selective reader clean up every allocator failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{});
}

const prefix = @import("prefix.zig");
fn prefixRawContainer(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const page = try prefix.open(lex.model.Entry, raw, .{});
    const hot_len = page.offsets.len + page.hot.len;
    const cold_len = page.cold.len;
    const out = try allocator.alloc(u8, 112 + hot_len + cold_len);
    @memset(out[0..112], 0);
    @memcpy(out[0..8], "LCP1\x01\x00\x00\x00");
    std.mem.writeInt(u32, out[8..12], 2, .little);
    std.mem.writeInt(u32, out[12..16], @intCast(raw.len), .little);
    @memcpy(out[16..80], raw[0..64]);
    std.mem.writeInt(u32, out[80..84], @intCast(hot_len), .little);
    std.mem.writeInt(u32, out[84..88], @intCast(hot_len), .little);
    std.mem.writeInt(u32, out[88..92], 112, .little);
    std.mem.writeInt(u32, out[96..100], @intCast(cold_len), .little);
    std.mem.writeInt(u32, out[100..104], @intCast(cold_len), .little);
    std.mem.writeInt(u32, out[104..108], @intCast(112 + hot_len), .little);
    @memcpy(out[112..], raw[64..]);
    return out;
}
test "reflected construction prefix cuts preserve all native rich packets and admit hot-only headwords" {
    var source = try workloads.rich(std.testing.allocator, 5);
    defer source.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const packets = try a.alloc([]const u8, source.entries.len);
    for (source.entries, packets) |entry, *bytes| bytes.* = try lex.packet.encode(a, entry, .{});
    const raw = try prefix.encodePackets(lex.model.Entry, a, packets, .{});
    const page = try prefix.open(lex.model.Entry, raw, .{});
    try std.testing.expectEqual(2, comptime prefix.cutFields(lex.model.Entry));
    for (source.entries, packets, 0..) |entry, packet, i| {
        const restored = try page.restorePacket(a, i);
        try std.testing.expectEqualSlices(u8, packet, restored);
        var native = try page.decode(std.testing.allocator, i);
        defer native.deinit();
        try std.testing.expect(workloads.nativeEqual(lex.model.Entry, entry, native.value));
    }
    const compressed = try prefixRawContainer(a, raw);
    const admitted = try prefix.admit(lex.model.Entry, std.testing.allocator, compressed, .{}, .{});
    var loaded = try admitted.loadHot(std.testing.allocator);
    defer loaded.deinit();
    try std.testing.expect(loaded.hot.raw_len < raw.len / 10);
    for (source.entries, 0..) |entry, i| {
        try std.testing.expectEqualStrings(entry.id, try loaded.field(i, .id));
        try std.testing.expectEqualStrings(entry.headword, try loaded.field(i, .headword));
    }
    for (0..compressed.len) |size| {
        if (prefix.admit(lex.model.Entry, std.testing.allocator, compressed[0..size], .{}, .{})) |_| return error.AcceptedPrefixContainerTruncation else |_| {}
    }
    const hostile = try a.dupe(u8, raw);
    std.mem.writeInt(u32, hostile[72..76], 100000, .little);
    repairDigest(hostile);
    try std.testing.expectError(error.InvalidCheckpoint, prefix.open(lex.model.Entry, hostile, .{}));
}

const register = @import("register.zig");
fn registerContainer(allocator: std.mem.Allocator, raw: []const u8, stage: []const u8, mode: u8) ![]u8 {
    const page = try prefix.open(lex.model.Entry, raw, .{});
    const hot = raw[64 .. raw.len - page.cold.len];
    var compressed = try lex.compression.encode(allocator, stage, .bzip3, .{});
    defer compressed.deinit();
    const result = try allocator.alloc(u8, 112 + hot.len + 4 + compressed.bytes.len);
    @memset(result[0..112], 0);
    @memcpy(result[0..8], &[_]u8{ 'L', 'C', 'P', '2', 1, mode, 1, 0 });
    std.mem.writeInt(u32, result[8..12], 2, .little);
    std.mem.writeInt(u32, result[12..16], @intCast(raw.len), .little);
    @memcpy(result[16..80], raw[0..64]);
    std.mem.writeInt(u32, result[80..84], @intCast(hot.len), .little);
    std.mem.writeInt(u32, result[84..88], @intCast(hot.len), .little);
    std.mem.writeInt(u32, result[88..92], 112, .little);
    std.mem.writeInt(u32, result[96..100], @intCast(page.cold.len), .little);
    std.mem.writeInt(u32, result[100..104], @intCast(4 + compressed.bytes.len), .little);
    std.mem.writeInt(u32, result[104..108], @intCast(112 + hot.len), .little);
    result[108] = 129;
    @memcpy(result[112..][0..hot.len], hot);
    std.mem.writeInt(u32, result[112 + hot.len ..][0..4], @intCast(stage.len), .little);
    @memcpy(result[116 + hot.len ..], compressed.bytes);
    return result;
}
test "native register inverse restores arbitrary packet controls and every original inline byte before admission" {
    const original = "<tag id=\"prefixABCtail\" words=\"prefixONEtail prefixTWOtail prefixTHREEtail\"/>";
    const transformed = "<tag id=\"prefixABCtail\" words=\"\x00\x01\x00\x06\x04ONE TWO THREE\"/>";
    const entry = lex.model.Entry{ .id = "one", .headword = "猫", .content = &.{.{ .definition = .{ .content = &.{.{ .text = original }} } }} };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const packet = try lex.packet.encode(a, entry, .{});
    const raw = try prefix.encodePackets(lex.model.Entry, a, &.{packet}, .{});
    const page = try prefix.open(lex.model.Entry, raw, .{});
    var escaped: std.ArrayList(u8) = .empty;
    for (page.cold) |byte| {
        try escaped.append(a, byte);
        if (byte == 0) try escaped.append(a, 0);
    }
    const position = std.mem.indexOf(u8, escaped.items, original).?;
    var stage: std.ArrayList(u8) = .empty;
    try stage.appendSlice(a, escaped.items[0..position]);
    try stage.appendSlice(a, transformed);
    try stage.appendSlice(a, escaped.items[position + original.len ..]);
    const compressed = try registerContainer(a, raw, stage.items, 1);
    const admitted = try register.admit(lex.model.Entry, std.testing.allocator, compressed, .{}, .{});
    const restored = try admitted.restorePage(a);
    try std.testing.expectEqualSlices(u8, raw, restored);
    var hot = try admitted.loadHot(std.testing.allocator);
    defer hot.deinit();
    try std.testing.expectEqualStrings(entry.headword, try hot.field(0, .headword));
    const hostile = try a.dupe(u8, compressed);
    const cold_offset = std.mem.readInt(u32, hostile[104..108], .little);
    std.mem.writeInt(u32, hostile[cold_offset..][0..4], 131073, .little);
    try std.testing.expectError(error.ConstructorLimit, register.admit(lex.model.Entry, std.testing.allocator, hostile, .{}, .{}));
    @memcpy(hostile, compressed);
    hostile[5] = 0;
    try std.testing.expectError(error.UnsupportedConstruction, register.admit(lex.model.Entry, std.testing.allocator, hostile, .{}, .{}));
    for (0..compressed.len) |len| {
        if (register.admit(lex.model.Entry, std.testing.allocator, compressed[0..len], .{}, .{})) |_| return error.AcceptedRegisterTruncation else |_| {}
    }
}
