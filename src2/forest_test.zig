const std = @import("std");
const schema = @import("schema.zig");
const forest_mod = @import("forest.zig");

test "forest navigation follows preorder ranges" {
    const subtree = [_]u64{ 4, 2, 1, 1, 2, 1 };
    const parent = [_]u64{ 0, 1, 1, 3, 0, 1 };
    const roots = [_]u64{ 0, 4 };
    var forest = try forest_mod.Forest.init(std.testing.allocator, subtree, parent, roots);
    defer forest.deinit();
    const root: schema.Node = @enumFromInt(0);
    try std.testing.expectEqual(@as(usize, 4), try forest.subtreeSize(root));
    try std.testing.expectEqual(@as(usize, 4), try forest.subtreeEnd(root));
    try std.testing.expectEqual(@as(?schema.Node, @enumFromInt(1)), try forest.firstChild(root));
    try std.testing.expectEqual(@as(?schema.Node, @enumFromInt(3)), try forest.nextSibling(@as(schema.Node, @enumFromInt(1))));
    try std.testing.expectEqual(@as(schema.Node, @enumFromInt(4)), try forest.root(@as(schema.Node, @enumFromInt(5))));
    try std.testing.expectEqual(@as(usize, 2), try forest.depth(@as(schema.Node, @enumFromInt(2))));
    try std.testing.expectEqual(@as(usize, 3), try forest.subtreeEnd(@as(schema.Node, @enumFromInt(1))));
    var children: [3]schema.Node = undefined;
    try std.testing.expectEqual(@as(usize, 2), try forest.childrenInto(root, &children));
    try std.testing.expectError(error.InvalidNode, forest.parent(@as(schema.Node, @enumFromInt(99))));
    try forest.validate();
}

test "forest rejects inconsistent columns and accepts deep valid trees" {
    const bad_subtree = [_]u64{ 2, 1 };
    const bad_parent = [_]u64{ 0, 0 };
    const bad_roots = [_]u64{ 0, 1 };
    try std.testing.expectError(error.InvalidForest, forest_mod.Forest.init(std.testing.allocator, bad_subtree, bad_parent, bad_roots));

    const count = 70;
    var subtree: [count]u64 = undefined;
    var parent: [count]u64 = undefined;
    for (0..count) |i| {
        subtree[i] = count - i;
        parent[i] = if (i == 0) 0 else 1;
    }
    const roots = [_]u64{0};
    var forest = try forest_mod.Forest.init(std.testing.allocator, subtree, parent, roots);
    defer forest.deinit();
    try std.testing.expectEqual(@as(usize, 69), try forest.depth(@as(schema.Node, @enumFromInt(69))));
}

test "forest rejects skipped ancestors and overflowing generic inputs" {
    const subtree = [_]u64{ 3, 2, 1 };
    const skipped_parent = [_]u64{ 0, 0, 0 };
    try std.testing.expectError(error.InvalidForest, forest_mod.Forest.init(std.testing.allocator, subtree, skipped_parent, [_]u64{0}));

    const negative = [_]i64{-1};
    try std.testing.expectError(error.InvalidForest, forest_mod.Forest.init(std.testing.allocator, negative, negative, [_]u64{}));
    const wide = [_]u128{std.math.maxInt(u128)};
    try std.testing.expectError(error.InvalidForest, forest_mod.Forest.init(std.testing.allocator, wide, wide, [_]u64{}));
}

test "wire forest uses packed columns and indexed kind ranks" {
    const subtree = [_]u32{ 4, 2, 1, 1, 2, 1 };
    const parents = [_]u32{ 0, 1, 1, 3, 0, 1 };
    const roots = [_]u32{ 0, 4 };
    const kinds = [_]schema.Kind{ .entry, .sense, .definition, .form, .entry, .sense };
    var owned = try forest_mod.encode(std.testing.allocator, &subtree, &parents, &roots, &kinds);
    defer owned.deinit();
    const view = try forest_mod.View.open(owned.bytes);

    // The two u32 structural columns alone would occupy 48 bytes; repeated
    // values within FOR frames remain compressed and directly readable.
    try std.testing.expect(view.subtree_column.bytes.len < 32 + subtree.len * 8);
    try std.testing.expectEqual(@as(usize, 2), try view.countKinds(schema.kinds(.{.sense})));
    try std.testing.expectEqual(@as(usize, 2), try view.kindRank(schema.kinds(.{ .entry, .sense }), @enumFromInt(3)));
    var senses = try view.nodes(.sense);
    try std.testing.expectEqual(@as(schema.Node, @enumFromInt(1)), (try senses.next()).?);
    try std.testing.expectEqual(@as(schema.Node, @enumFromInt(5)), (try senses.next()).?);
    try std.testing.expect((try senses.next()) == null);

    var corrupt = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(corrupt);
    corrupt[7] +%= 1;
    try std.testing.expectError(error.InvalidForest, forest_mod.View.open(corrupt));
}

test "kind directory rejects duplicate indexes and nonempty absent kinds" {
    const subtree = [_]u32{ 4, 2, 1, 1, 2, 1 };
    const parents = [_]u32{ 0, 1, 1, 3, 0, 1 };
    const roots = [_]u32{ 0, 4 };
    const kinds = [_]schema.Kind{ .entry, .sense, .definition, .form, .entry, .sense };
    var owned = try forest_mod.encode(std.testing.allocator, &subtree, &parents, &roots, &kinds);
    defer owned.deinit();

    // HeaderLayout is a packed wire layout: kind_directory is the seventh
    // u32 range (offset 60), and kind_indexes is the eighth (offset 68).
    const kind_directory = std.mem.readInt(u32, owned.bytes[60..64], .little);
    const kind_record_size = 16;
    const absent = @intFromEnum(schema.Kind.homograph);
    const present = @intFromEnum(schema.Kind.sense);
    const later_present = @intFromEnum(schema.Kind.definition);
    const absent_record = kind_directory + absent * kind_record_size;
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, owned.bytes[absent_record + 4 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, owned.bytes[absent_record + 8 ..][0..4], .little));

    const absent_corrupt = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(absent_corrupt);
    // An absent kind has no Elias payload. A nonzero length must not be
    // silently treated as a second/duplicate kind index.
    std.mem.writeInt(u32, absent_corrupt[absent_record + 4 ..][0..4], 1, .little);
    try std.testing.expectError(error.InvalidForest, forest_mod.View.open(absent_corrupt));

    const duplicate_corrupt = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(duplicate_corrupt);
    const present_record = kind_directory + present * kind_record_size;
    const later_record = kind_directory + later_present * kind_record_size;
    const present_offset = std.mem.readInt(u32, duplicate_corrupt[present_record..][0..4], .little);
    // Reusing an earlier kind's payload makes the directory non-contiguous;
    // View.open must reject the duplicate rather than count it twice.
    std.mem.writeInt(u32, duplicate_corrupt[later_record..][0..4], present_offset, .little);
    try std.testing.expectError(error.InvalidForest, forest_mod.View.open(duplicate_corrupt));
}
