const std = @import("std");
const lex = @import("lex6");
const dag = @import("dag.zig");
const workloads = @import("workloads.zig");

test "exact typed sharing preserves varied multilingual models and field projections" {
    var source = try workloads.rich(std.testing.allocator, 12);
    defer source.deinit();
    inline for (.{ dag.Strategy.flat, dag.Strategy.shared, dag.Strategy.adaptive }) |strategy| {
        const bytes = try dag.encodePage(lex.model.Entry, std.testing.allocator, source.entries, .{ .max_page_bytes = 1024 * 1024 }, strategy);
        defer std.testing.allocator.free(bytes);
        const page = try dag.open(lex.model.Entry, std.testing.allocator, bytes, .{ .max_page_bytes = 1024 * 1024 });
        const prepared = try page.prepare(std.testing.allocator, .{});
        for (source.entries, 0..) |entry, i| {
            var value = try page.decode(std.testing.allocator, i);
            defer value.deinit();
            try std.testing.expect(workloads.nativeEqual(lex.model.Entry, entry, value.value));
            const view = try prepared.view(i);
            try std.testing.expectEqualStrings(entry.headword, try (try view.field(.headword)).text());
            var contents = try (try view.field(.content)).values();
            var item_index: usize = 0;
            while (try contents.next()) |item| {
                try std.testing.expectEqual(std.meta.activeTag(entry.content[item_index]), try item.tag());
                var native = try item.decodeOwned(std.testing.allocator);
                defer native.deinit();
                try std.testing.expect(workloads.nativeEqual(lex.model.Item, entry.content[item_index], native.value));
                item_index += 1;
            }
            try std.testing.expectEqual(entry.content.len, item_index);
        }
    }
}

test "flat fallback charges complete offsets header and checksum" {
    const entries = [_]lex.model.Entry{.{ .id = "one", .headword = "猫" }};
    const flat = try dag.encodePage(lex.model.Entry, std.testing.allocator, &entries, .{}, .flat);
    defer std.testing.allocator.free(flat);
    const adaptive = try dag.encodePage(lex.model.Entry, std.testing.allocator, &entries, .{}, .adaptive);
    defer std.testing.allocator.free(adaptive);
    try std.testing.expect(adaptive.len <= flat.len);
    _ = try dag.open(lex.model.Entry, std.testing.allocator, adaptive, .{});
}

test "all truncated frames fail and schema mismatch is explicit" {
    const Entry = lex.model.Entry;
    const entries = [_]Entry{.{ .id = "one", .headword = "كَتَبَ" }};
    const bytes = try dag.encodePage(Entry, std.testing.allocator, &entries, .{}, .shared);
    defer std.testing.allocator.free(bytes);
    for (0..bytes.len) |n| {
        const result = dag.open(Entry, std.testing.allocator, bytes[0..n], .{});
        if (result) |_| return error.AcceptedTruncation else |_| {}
    }
    try std.testing.expectError(error.InvalidSchema, dag.open(lex.model.Resource, std.testing.allocator, bytes, .{}));
}

fn maliciousFrame(comptime Root: type, records: []const []const u8, roots: []const u32) ![]u8 {
    var payload_size: usize = 0;
    for (records) |record| payload_size += record.len;
    const payload_at = dag.header_size + (records.len + 1) * 4 + roots.len * 4;
    const bytes = try std.testing.allocator.alloc(u8, payload_at + payload_size);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "LPD1");
    bytes[4] = 1;
    bytes[5] = 1;
    std.mem.writeInt(u32, bytes[8..12], @intCast(roots.len), .little);
    std.mem.writeInt(u32, bytes[12..16], @intCast(records.len), .little);
    std.mem.writeInt(u32, bytes[16..20], @intCast(payload_size), .little);
    std.mem.writeInt(u64, bytes[24..32], comptime dag.schemaFingerprint(Root), .little);
    var at: usize = 0;
    for (records, 0..) |record, i| {
        std.mem.writeInt(u32, bytes[dag.header_size + i * 4 ..][0..4], @intCast(at), .little);
        @memcpy(bytes[payload_at + at ..][0..record.len], record);
        at += record.len;
    }
    std.mem.writeInt(u32, bytes[dag.header_size + records.len * 4 ..][0..4], @intCast(at), .little);
    for (roots, 0..) |root, i| std.mem.writeInt(u32, bytes[dag.header_size + (records.len + 1) * 4 + i * 4 ..][0..4], root, .little);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(bytes[0..32]);
    hash.update(bytes[64..]);
    hash.final(bytes[32..64]);
    return bytes;
}

const Tree = struct { children: []const @This() };

test "typed topological edges reject cycles mismatches unreachable and duplicate nodes" {
    const cases = .{
        .{ &.{ &.{ 1, 0 }, &.{ 0, 1 } }, &.{1}, error.InvalidReference },
        .{ &.{ &.{ 1, 0 }, &.{ 0, 0 }, &.{ 0, 1 } }, &.{2}, error.TypeMismatch },
        .{ &.{ &.{ 1, 0 }, &.{ 0, 0 } }, &.{0}, error.TypeMismatch },
        .{ &.{ &.{ 1, 0 }, &.{ 0, 0 }, &.{ 1, 1, 1 } }, &.{1}, error.UnreachableNode },
        .{ &.{ &.{ 1, 0 }, &.{ 1, 0 }, &.{ 0, 0 } }, &.{2}, error.DuplicateNode },
        .{ &.{&.{ 0x81, 0 }}, &.{0}, error.NonCanonicalVarint },
    };
    inline for (cases) |case| {
        const bytes = try maliciousFrame(Tree, case[0], case[1]);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectError(case[2], dag.open(Tree, std.testing.allocator, bytes, .{}));
    }
}

test "physical tiny DAG cannot hide exponential expanded work or allocations" {
    var storage: [44][4]u8 = undefined;
    var records: [44][]const u8 = undefined;
    storage[0] = .{ 1, 0, 0, 0 };
    records[0] = storage[0][0..2];
    storage[1] = .{ 0, 0, 0, 0 };
    records[1] = storage[1][0..2];
    for (1..22) |level| {
        const id = level * 2;
        storage[id] = .{ 1, 2, @intCast(id - 1), @intCast(id - 1) };
        records[id] = &storage[id];
        storage[id + 1] = .{ 0, @intCast(id), 0, 0 };
        records[id + 1] = storage[id + 1][0..2];
    }
    const bytes = try maliciousFrame(Tree, &records, &.{43});
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(bytes.len < 500);
    try std.testing.expectError(error.ExpandedWorkLimit, dag.open(Tree, std.testing.allocator, bytes, .{ .max_expanded_work = 4096 }));
    try std.testing.expectError(error.ExpandedAllocationLimit, dag.open(Tree, std.testing.allocator, bytes, .{ .max_expanded_work = 100_000_000, .max_expanded_allocation = 1024 }));
    try std.testing.expectError(error.DepthLimit, dag.open(Tree, std.testing.allocator, bytes, .{ .max_expanded_work = 100_000_000, .max_expanded_allocation = 100_000_000, .packet = .{ .max_depth = 16 } }));
}

test "structural sharing never suppresses occurrence-sensitive semantic duplicates" {
    const entries = [_]lex.model.Entry{.{ .id = "one", .headword = "word", .content = &.{ .{ .sense = .{ .meta = .{ .id = "duplicate" } } }, .{ .sense = .{ .meta = .{ .id = "duplicate" } } } } }};
    const bytes = try dag.encodePage(lex.model.Entry, std.testing.allocator, &entries, .{}, .shared);
    defer std.testing.allocator.free(bytes);
    const page = try dag.open(lex.model.Entry, std.testing.allocator, bytes, .{});
    try std.testing.expectError(error.DuplicateIdentity, page.prepare(std.testing.allocator, .{}));
}

test "original packet budgets bound expanded canonical bytes and owned allocation" {
    const entries = [_]lex.model.Entry{.{ .id = "one", .headword = "猫" }};
    const bytes = try dag.encodePage(lex.model.Entry, std.testing.allocator, &entries, .{}, .shared);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(error.AllocationLimit, dag.open(lex.model.Entry, std.testing.allocator, bytes, .{ .packet = .{ .max_allocation_bytes = 0 } }));
    try std.testing.expectError(error.InputTooLarge, dag.open(lex.model.Entry, std.testing.allocator, bytes, .{ .packet = .{ .max_input_bytes = 5 } }));
    try std.testing.expectError(error.WorkLimit, dag.open(lex.model.Entry, std.testing.allocator, bytes, .{ .packet = .{ .max_work = 1 } }));
}

test "canonical sparse defaults and 64-bit masks are checked at typed nodes" {
    const Default = struct { count: u8 = 0 };
    const bytes = try maliciousFrame(Default, &.{&.{ 0, 1, 0 }}, &.{0});
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(error.NonCanonicalDefault, dag.open(Default, std.testing.allocator, bytes, .{}));
    const bad_mask = try maliciousFrame(Default, &.{&.{ 0, 2 }}, &.{0});
    defer std.testing.allocator.free(bad_mask);
    try std.testing.expectError(error.InvalidDefaultMask, dag.open(Default, std.testing.allocator, bad_mask, .{}));
    const Signed = struct { number: i64, truth: bool, tag: enum(u8) { a = 20, b = 99 } };
    const values = [_]Signed{ .{ .number = std.math.minInt(i64), .truth = true, .tag = .b }, .{ .number = std.math.maxInt(i64), .truth = false, .tag = .a } };
    const valid = try dag.encodePage(Signed, std.testing.allocator, &values, .{}, .shared);
    defer std.testing.allocator.free(valid);
    const page = try dag.open(Signed, std.testing.allocator, valid, .{});
    for (values, 0..) |original, i| {
        var decoded = try page.decode(std.testing.allocator, i);
        defer decoded.deinit();
        try std.testing.expect(workloads.nativeEqual(Signed, original, decoded.value));
    }
    try std.testing.expectEqual(values[0].number, try (try (try page.view(0)).field(.number)).scalarValue());
}

test "immutable atom identity does not become native pointer aliasing" {
    const T = struct { const_text: []const u8, mutable_text: []u8, pointer: *const u32 };
    var text = [_]u8{ 'a', 'b' };
    const integer: u32 = 37;
    const values = [_]T{ .{ .const_text = &text, .mutable_text = &text, .pointer = &integer }, .{ .const_text = &text, .mutable_text = &text, .pointer = &integer } };
    const bytes = try dag.encodePage(T, std.testing.allocator, &values, .{}, .shared);
    defer std.testing.allocator.free(bytes);
    const page = try dag.open(T, std.testing.allocator, bytes, .{});
    var first = try page.decode(std.testing.allocator, 0);
    defer first.deinit();
    var second = try page.decode(std.testing.allocator, 1);
    defer second.deinit();
    first.value.mutable_text[0] = 'x';
    try std.testing.expectEqualStrings("ab", second.value.mutable_text);
    try std.testing.expectEqualStrings("ab", first.value.const_text);
    try std.testing.expect(first.value.pointer != second.value.pointer);
    const pointer_view = try (try (try page.view(1)).field(.pointer)).pointee();
    try std.testing.expectEqual(@as(u32, 37), try pointer_view.scalarValue());
}

fn allocationFailures(allocator: std.mem.Allocator) !void {
    const values = [_]lex.model.Entry{.{ .id = "one", .headword = "猫", .content = &.{.{ .definition = .{ .content = &.{.{ .text = "a varied definition" }} } }} }};
    const bytes = try dag.encodePage(lex.model.Entry, allocator, &values, .{}, .adaptive);
    defer allocator.free(bytes);
    const page = try dag.open(lex.model.Entry, allocator, bytes, .{});
    _ = try page.prepare(allocator, .{});
    var decoded = try page.decode(allocator, 0);
    defer decoded.deinit();
}
test "transactional encode admission and native decode survive allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{});
}
