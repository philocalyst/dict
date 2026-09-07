const std = @import("std");
const prose = @import("prose.zig");

test "root ordered blocks round trip and deterministic codec" {
    const first = [_]prose.ItemInput{ .{ .node = 11, .text = "definition one" }, .{ .node = 13, .text = "example one" } };
    const second = [_]prose.ItemInput{.{ .node = 27, .text = "definition two" }};
    const roots = [_]prose.RootInput{ .{ .root = 10, .items = &first }, .{ .root = 11, .items = &second } };
    var one = try prose.build(std.testing.allocator, &roots, .{ .preset = .latency });
    defer one.deinit();
    var two = try prose.build(std.testing.allocator, &roots, .{ .preset = .latency });
    defer two.deinit();
    try std.testing.expectEqualSlices(u8, one.bytes, two.bytes);
    var store = try prose.Store.open(one.bytes, .{ .preset = .latency });
    try std.testing.expectEqual(@as(?usize, 0), store.blockForRoot(10));
    try std.testing.expectEqual(@as(?usize, 0), store.blockForRoot(11));
    var pin = try store.pin(std.testing.allocator, 0);
    defer pin.deinit();
    try std.testing.expectEqualStrings("definition one", (try pin.item(0)).text);
    try std.testing.expect((try pin.itemForNode(27)).?.text.len > 0);
    try std.testing.expectEqual(prose.Codec.bzip3, (try store.block(0)).codec);
}

test "forced bzip3 round trip preserves binary prose" {
    var text: [90 * 1024]u8 = undefined;
    for (&text, 0..) |*byte, index| byte.* = @intCast((index / 17) % 5);
    const items = [_]prose.ItemInput{.{ .node = 101, .text = text[0..] }};
    const roots = [_]prose.RootInput{.{ .root = 100, .items = &items }};
    var owned = try prose.build(std.testing.allocator, &roots, .{ .preset = .balanced, .codec = .bzip3 });
    defer owned.deinit();
    var store = try prose.Store.open(owned.bytes, .{ .preset = .balanced, .max_decode_bytes = 512 * 1024 });
    const meta = try store.block(0);
    try std.testing.expectEqual(prose.Codec.bzip3, meta.codec);
    var pin = try store.pin(std.testing.allocator, 0);
    defer pin.deinit();
    try std.testing.expectEqualSlices(u8, text[0..], (try pin.item(0)).text);
}

test "open and pin reject hostile metadata and compressed bytes" {
    const items = [_]prose.ItemInput{.{ .node = 1, .text = "safe" }};
    const roots = [_]prose.RootInput{.{ .root = 1, .items = &items }};
    var owned = try prose.build(std.testing.allocator, &roots, .{ .codec = .bzip3 });
    defer owned.deinit();
    const bad_count = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_count);
    std.mem.writeInt(u32, bad_count[8..][0..4], 0xffff_ffff, .little);
    if (prose.Store.open(bad_count, .{})) |_| return error.TestUnexpectedSuccess else |_| {}
    const bad_offset = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_offset);
    // v3 Record.stored_offset is the u64 at byte 24.  Keep this mutation
    // aimed at the offset field rather than the root-index field that v2
    // placed at this location.
    std.mem.writeInt(u64, bad_offset[prose.header_size + 24 ..][0..8], std.math.maxInt(u64), .little);
    if (prose.Store.open(bad_offset, .{})) |_| return error.TestUnexpectedSuccess else |_| {}
    const bad_payload = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_payload);
    const store = try prose.Store.open(bad_payload, .{});
    const meta = try store.block(0);
    bad_payload[meta.stored_offset + meta.stored_size / 2] ^= 0x80;
    if (store.pin(std.testing.allocator, 0)) |pin| {
        var owned_pin = pin;
        owned_pin.deinit();
        return error.TestUnexpectedSuccess;
    } else |err| try std.testing.expect(err != prose.Error.OutOfMemory);

    // Opening the directory does not decompress payloads.  This specifically
    // changes the v3 node_first metadata and must be rejected by pin after it
    // reads the payload's node id; a generic compressed-byte corruption test
    // would not distinguish that invariant.
    const bad_node_metadata = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_node_metadata);
    // Keep node_first <= node_last so Store.open succeeds; pin must then
    // reject the disagreement with the payload's actual first node.
    std.mem.writeInt(u32, bad_node_metadata[prose.header_size + 8 ..][0..4], 0, .little);
    var metadata_store = try prose.Store.open(bad_node_metadata, .{});
    if (metadata_store.pin(std.testing.allocator, 0)) |pin| {
        var owned_pin = pin;
        owned_pin.deinit();
        return error.TestUnexpectedSuccess;
    } else |err| try std.testing.expectEqual(prose.Error.Malformed, err);
}

test "decode limits are enforced before allocation" {
    const items = [_]prose.ItemInput{.{ .node = 1, .text = "bounded" }};
    const roots = [_]prose.RootInput{.{ .root = 1, .items = &items }};
    var owned = try prose.build(std.testing.allocator, &roots, .{ .codec = .raw });
    defer owned.deinit();
    var store = try prose.Store.open(owned.bytes, .{ .max_decode_bytes = prose.payload_header_size });
    try std.testing.expectError(prose.Error.LimitExceeded, store.pin(std.testing.allocator, 0));
}

test "root directory does not claim numeric gaps" {
    const a = [_]prose.ItemInput{.{ .node = 1, .text = "a" }};
    const b = [_]prose.ItemInput{.{ .node = 4, .text = "b" }};
    const roots = [_]prose.RootInput{ .{ .root = 0, .items = &a }, .{ .root = 3, .items = &b } };
    var owned = try prose.build(std.testing.allocator, &roots, .{ .codec = .raw });
    defer owned.deinit();
    const store = try prose.Store.open(owned.bytes, .{ .codec = .raw });
    try std.testing.expectEqual(@as(?usize, null), store.blockForRoot(1));
    try std.testing.expectEqual(@as(?usize, 0), store.blockForRoot(0));
    try std.testing.expectEqual(@as(?usize, 0), store.blockForRoot(3));

    const bad = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad);
    // v3 Record.root_count is the u32 at byte 36.
    std.mem.writeInt(u32, bad[prose.header_size + 36 ..][0..4], 3, .little);
    try std.testing.expectError(prose.Error.Malformed, prose.Store.open(bad, .{ .codec = .raw }));
}

test "raw blocks are not constrained by the bzip state target" {
    const text = try std.testing.allocator.alloc(u8, 70 * 1024);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');
    const items = [_]prose.ItemInput{.{ .node = 1, .text = text }};
    const roots = [_]prose.RootInput{.{ .root = 1, .items = &items }};
    var owned = try prose.build(std.testing.allocator, &roots, .{ .preset = .latency, .codec = .raw, .max_uncompressed_block = 128 * 1024 });
    defer owned.deinit();
    const store = try prose.Store.open(owned.bytes, .{ .preset = .latency });
    var pin = try store.pin(std.testing.allocator, 0);
    defer pin.deinit();
    try std.testing.expectEqualSlices(u8, text, (try pin.item(0)).text);
}

test "joining valid roots never crosses uncompressed decode or stored limits" {
    const first_text = "12345678901234567890";
    const second_text = "abcdefghijklmnopqrst";
    const first = [_]prose.ItemInput{.{ .node = 1, .text = first_text }};
    const second = [_]prose.ItemInput{.{ .node = 3, .text = second_text }};
    const roots = [_]prose.RootInput{
        .{ .root = 0, .items = &first },
        .{ .root = 2, .items = &second },
    };

    const options = [_]prose.Options{
        .{ .preset = .latency, .codec = .raw, .max_items_per_block = 2, .max_uncompressed_block = 64, .max_decode_bytes = 1024, .max_compressed_block = 1024 },
        .{ .preset = .latency, .codec = .raw, .max_items_per_block = 2, .max_uncompressed_block = 1024, .max_decode_bytes = 64, .max_compressed_block = 1024 },
        .{ .preset = .latency, .codec = .raw, .max_items_per_block = 2, .max_uncompressed_block = 1024, .max_decode_bytes = 1024, .max_compressed_block = 64 },
    };
    for (options) |limits| {
        var owned = try prose.build(std.testing.allocator, &roots, limits);
        defer owned.deinit();
        var store = try prose.Store.open(owned.bytes, limits);
        try std.testing.expectEqual(@as(usize, 2), store.block_count);
        var first_pin = try store.pin(std.testing.allocator, 0);
        defer first_pin.deinit();
        var second_pin = try store.pin(std.testing.allocator, 1);
        defer second_pin.deinit();
        try std.testing.expectEqualStrings(first_text, (try first_pin.item(0)).text);
        try std.testing.expectEqualStrings(second_text, (try second_pin.item(0)).text);
    }
}

test "oversized roots continue across bounded blocks" {
    const items = [_]prose.ItemInput{
        .{ .node = 10, .text = "a" },
        .{ .node = 11, .text = "bb" },
        .{ .node = 12, .text = "ccc" },
    };
    const roots = [_]prose.RootInput{.{ .root = 7, .items = &items }};
    var owned = try prose.build(std.testing.allocator, &roots, .{
        .codec = .raw,
        .max_items_per_block = 1,
        .max_uncompressed_block = 64,
    });
    defer owned.deinit();
    var store = try prose.Store.open(owned.bytes, .{ .codec = .raw, .max_items_per_block = 1, .max_uncompressed_block = 64 });
    try std.testing.expectEqual(@as(usize, 3), store.block_count);
    try std.testing.expectEqual(@as(?usize, 0), store.blockForRoot(7));
    try std.testing.expectEqual(@as(?usize, 2), store.blockForNode(12));
    for (0..3) |i| {
        var pin = try store.pin(std.testing.allocator, i);
        defer pin.deinit();
        try std.testing.expectEqual(i + 1, (try pin.item(0)).text.len);
    }
}
