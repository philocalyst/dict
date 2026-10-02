const std = @import("std");
const lex = @import("lex6");
const shape = @import("shape.zig");
const workloads = @import("workloads.zig");

fn reseal(bytes: []u8) void {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(bytes[0..32]);
    hash.update(bytes[64..]);
    hash.final(bytes[32..64]);
}

fn maliciousTreeFrame(records: []const []const u8, root_id: u32, leaf_count: u32) ![]u8 {
    const root_bytes = 20;
    const offsets_bytes = (records.len + 1) * 4;
    var actual_shapes: usize = 0;
    for (records) |r| actual_shapes += r.len;
    const size = shape.header_size + offsets_bytes + root_bytes + actual_shapes;
    const bytes = try std.testing.allocator.alloc(u8, size);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "LPS1");
    bytes[4] = 1;
    std.mem.writeInt(u32, bytes[8..12], 1, .little);
    std.mem.writeInt(u32, bytes[12..16], @intCast(records.len), .little);
    std.mem.writeInt(u32, bytes[16..20], @intCast(actual_shapes), .little);
    std.mem.writeInt(u32, bytes[20..24], 0, .little);
    std.mem.writeInt(u64, bytes[24..32], comptime @import("dag.zig").schemaFingerprint(Tree), .little);
    const roots_at = shape.header_size + offsets_bytes;
    std.mem.writeInt(u32, bytes[roots_at..][0..4], root_id, .little);
    std.mem.writeInt(u32, bytes[roots_at + 16 ..][0..4], leaf_count, .little);
    const shapes_at = roots_at + root_bytes;
    var at: usize = 0;
    for (records, 0..) |record, i| {
        std.mem.writeInt(u32, bytes[shape.header_size + i * 4 ..][0..4], @intCast(at), .little);
        @memcpy(bytes[shapes_at + at ..][0..record.len], record);
        at += record.len;
    }
    std.mem.writeInt(u32, bytes[shape.header_size + records.len * 4 ..][0..4], @intCast(at), .little);
    reseal(bytes);
    return bytes;
}

const Tree = struct { kids: []const @This() };

test "reflected shape templates preserve varied native entries and literals" {
    var source = try workloads.rich(std.testing.allocator, 8);
    defer source.deinit();
    const bytes = try shape.encodePage(lex.model.Entry, std.testing.allocator, source.entries, .{ .max_page_bytes = 1024 * 1024 });
    defer std.testing.allocator.free(bytes);
    const page = try shape.open(lex.model.Entry, std.testing.allocator, bytes, .{ .max_page_bytes = 1024 * 1024 });
    try std.testing.expectEqual(source.entries.len, page.count);
    try page.prepare(std.testing.allocator, .{});
    for (source.entries, 0..) |entry, i| {
        var decoded = try page.decode(std.testing.allocator, i);
        defer decoded.deinit();
        try std.testing.expect(workloads.nativeEqual(lex.model.Entry, entry, decoded.value));
    }
}

test "identical control shapes share while ordered unique leaves remain distinct" {
    const entries = [_]lex.model.Entry{
        .{ .id = "one", .headword = "猫", .content = &.{.{ .definition = .{ .content = &.{.{ .text = "ねこ" }} } }} },
        .{ .id = "two", .headword = "犬", .content = &.{.{ .definition = .{ .content = &.{.{ .text = "いぬ" }} } }} },
    };
    const bytes = try shape.encodePage(lex.model.Entry, std.testing.allocator, &entries, .{});
    defer std.testing.allocator.free(bytes);
    const page = try shape.open(lex.model.Entry, std.testing.allocator, bytes, .{});
    try std.testing.expectEqual(try page.rootShape(0), try page.rootShape(1));
    for (entries, 0..) |entry, i| {
        var decoded = try page.decode(std.testing.allocator, i);
        defer decoded.deinit();
        try std.testing.expect(workloads.nativeEqual(lex.model.Entry, entry, decoded.value));
        const cp = try page.literalCheckpoint(i, 0);
        try std.testing.expect(cp.len > 0);
    }
}

test "shape frames bind the schema and reject checksum changes and truncated input" {
    const entries = [_]lex.model.Entry{.{ .id = "one", .headword = "كَتَبَ" }};
    const bytes = try shape.encodePage(lex.model.Entry, std.testing.allocator, &entries, .{});
    defer std.testing.allocator.free(bytes);
    for (0..bytes.len) |n| {
        if (shape.open(lex.model.Entry, std.testing.allocator, bytes[0..n], .{})) |_| return error.AcceptedTruncation else |_| {}
    }
    var corrupt = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupt);
    corrupt[corrupt.len - 1] ^= 1;
    try std.testing.expectError(error.DigestMismatch, shape.open(lex.model.Entry, std.testing.allocator, corrupt, .{}));
    try std.testing.expectError(error.InvalidSchema, shape.open(lex.model.Resource, std.testing.allocator, bytes, .{}));
}

test "literal checkpoints land on exact every-thirty-second leaf boundaries" {
    const Many = struct { values: []const u32 };
    var values: [70]u32 = undefined;
    for (&values, 0..) |*value, i| value.* = @intCast(i);
    const many = [_]Many{.{ .values = &values }};
    const bytes = try shape.encodePage(Many, std.testing.allocator, &many, .{});
    defer std.testing.allocator.free(bytes);
    const page = try shape.open(Many, std.testing.allocator, bytes, .{});
    try std.testing.expect((try page.literalCheckpoint(0, 0)).len > (try page.literalCheckpoint(0, 1)).len);
    const offsets_bytes = (page.node_count + 1) * 4;
    const roots_at = shape.header_size + offsets_bytes;
    const cp_at = roots_at + page.count * 20;
    var corrupt = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupt);
    const cp = std.mem.readInt(u32, corrupt[cp_at + 4 ..][0..4], .little);
    std.mem.writeInt(u32, corrupt[cp_at + 4 ..][0..4], cp + 1, .little);
    reseal(corrupt);
    try std.testing.expectError(error.InvalidCheckpoint, shape.open(Many, std.testing.allocator, corrupt, .{}));
}

test "topological child references reject cycles and expected-type mismatch" {
    const records = [_][]const u8{ &.{ 1, 0, 0 }, &.{ 0, 0, 0 }, &.{ 1, 1, 1, 0 }, &.{ 0, 2, 0 } };
    // Node 3 is Tree -> a singleton []Tree node 2 -> Tree node 1. Replace
    // node 3's []Tree reference with itself (cycle) or a Tree (wrong type).
    var cycle = try maliciousTreeFrame(&records, 3, 0);
    defer std.testing.allocator.free(cycle);
    const shapes_at = shape.header_size + (records.len + 1) * 4 + 20;
    cycle[shapes_at + records[0].len + records[1].len + records[2].len + 1] = 3;
    reseal(cycle);
    try std.testing.expectError(error.InvalidReference, shape.open(Tree, std.testing.allocator, cycle, .{}));
    var mismatch = try maliciousTreeFrame(&records, 3, 0);
    defer std.testing.allocator.free(mismatch);
    mismatch[shapes_at + records[0].len + records[1].len + records[2].len + 1] = 1;
    reseal(mismatch);
    try std.testing.expectError(error.TypeMismatch, shape.open(Tree, std.testing.allocator, mismatch, .{}));
}

test "expanded recursive shape multiplicity is bounded despite compact controls" {
    var storage: [42][5]u8 = undefined;
    var records: [42][]const u8 = undefined;
    storage[0] = .{ 1, 0, 0, 0, 0 };
    records[0] = storage[0][0..3]; // []Tree length 0, zero holes
    storage[1] = .{ 0, 0, 0, 0, 0 };
    records[1] = storage[1][0..3]; // Tree -> node 0, zero holes
    for (1..21) |level| {
        const id = level * 2;
        storage[id] = .{ 1, 2, @intCast(id - 1), @intCast(id - 1), 0 };
        records[id] = &storage[id];
        storage[id + 1] = .{ 0, @intCast(id), 0, 0, 0 };
        records[id + 1] = storage[id + 1][0..3];
    }
    const bytes = try maliciousTreeFrame(&records, 41, 0);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(bytes.len < 600);
    try std.testing.expectError(error.ExpandedWorkLimit, shape.open(Tree, std.testing.allocator, bytes, .{ .max_work = 1024 }));
}

test "native allocation is refused before materializing literals" {
    const entries = [_]lex.model.Entry{.{ .id = "id", .headword = "longer" }};
    const bytes = try shape.encodePage(lex.model.Entry, std.testing.allocator, &entries, .{});
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(error.AllocationLimit, shape.open(lex.model.Entry, std.testing.allocator, bytes, .{ .max_expanded_allocation = 0 }));
}
