const std = @import("std");
const schema = @import("schema.zig");
const rank = @import("rank.zig");

test "typed ranks and checked arithmetic keep domains distinct" {
    const entry = try schema.Rank(.entry).fromIndex(3);
    const sense = try schema.Rank(.sense).fromIndex(3);
    try std.testing.expect(@TypeOf(entry) != @TypeOf(sense));
    try std.testing.expectEqual(@as(usize, 3), entry.index().?);
    try std.testing.expect((schema.Rank(.entry).none.index()) == null);
    try std.testing.expectError(error.Overflow, rank.rankAdd(.entry, entry, std.math.maxInt(usize)));
    try std.testing.expectEqual(@as(usize, 4), (try rank.rankAdd(.entry, entry, 1)).index().?);
    try std.testing.expectError(error.OutOfRange, rank.rankBefore(.entry, try schema.Rank(.entry).fromIndex(0)));
}

test "intervals are half-open and empty without allocation" {
    const R = schema.Rank(.sense);
    const I = rank.Interval(.sense);
    const range = try I.init(try R.fromIndex(2), try R.fromIndex(6));
    try std.testing.expectEqual(@as(usize, 4), range.len());
    try std.testing.expect(range.contains(try R.fromIndex(5)));
    try std.testing.expect(!range.contains(try R.fromIndex(6)));
    try std.testing.expectEqual(@as(usize, 2), range.take(2).len());
    try std.testing.expectEqual(@as(usize, 2), range.after(2).len());
    try std.testing.expectEqual(@as(usize, 0), I.empty().len());

    const set = rank.NodeSet(.sense).fromInterval(range);
    try std.testing.expectEqual(@as(usize, 4), set.len());
    try std.testing.expectEqual(@as(usize, 2), @intFromEnum((try set.at(0))));
    try std.testing.expectEqual(@as(usize, 0), rank.NodeSet(.sense).empty().len());

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var owned = try rank.clone(.sense, failing.allocator(), set);
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 4), owned.borrow().len());
}

test "materialised lists reject unsorted and duplicate ranks" {
    const R = schema.Rank(.definition);
    const values = [_]R{ try R.fromIndex(1), try R.fromIndex(3), try R.fromIndex(7) };
    const set = try rank.NodeSet(.definition).fromList(&values);
    try std.testing.expectEqual(@as(usize, 3), set.len());
    try std.testing.expect(set.contains(try R.fromIndex(3)));
    try std.testing.expect(!set.contains(try R.fromIndex(2)));

    const duplicate = [_]R{ try R.fromIndex(1), try R.fromIndex(1) };
    try std.testing.expectError(error.Duplicate, rank.NodeSet(.definition).fromList(&duplicate));
    const unsorted = [_]R{ try R.fromIndex(2), try R.fromIndex(1) };
    try std.testing.expectError(error.Unsorted, rank.NodeSet(.definition).fromList(&unsorted));
}

test "closed interval union and non-closed set algebra have explicit allocation" {
    const R = schema.Rank(.sense);
    const I = rank.Interval(.sense);
    const left = rank.NodeSet(.sense).fromInterval(try I.init(try R.fromIndex(0), try R.fromIndex(2)));
    const right = rank.NodeSet(.sense).fromInterval(try I.init(try R.fromIndex(2), try R.fromIndex(5)));

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var joined = try rank.unionSet(.sense, failing.allocator(), left, right);
    defer joined.deinit();
    try std.testing.expectEqual(@as(usize, 5), joined.borrow().len());
    try std.testing.expect(joined.borrow() == .interval);

    const disjoint = rank.NodeSet(.sense).fromInterval(try I.init(try R.fromIndex(8), try R.fromIndex(9)));
    try std.testing.expectError(error.OutOfMemory, rank.unionSet(.sense, failing.allocator(), left, disjoint));

    const list_a_values = [_]R{ try R.fromIndex(0), try R.fromIndex(2), try R.fromIndex(4) };
    const list_b_values = [_]R{ try R.fromIndex(2), try R.fromIndex(3), try R.fromIndex(4) };
    const list_a = try rank.NodeSet(.sense).fromList(&list_a_values);
    const list_b = try rank.NodeSet(.sense).fromList(&list_b_values);
    var common = try rank.intersectSet(.sense, std.testing.allocator, list_a, list_b);
    defer common.deinit();
    try std.testing.expectEqual(@as(usize, 2), common.borrow().len());
    try std.testing.expectEqual(@as(usize, 2), @intFromEnum((try common.borrow().at(0))));
}

test "empty interval identities do not allocate" {
    const R = schema.Rank(.sense);
    const I = rank.Interval(.sense);
    const empty = rank.NodeSet(.sense).fromInterval(I.empty());
    const range = rank.NodeSet(.sense).fromInterval(try I.init(try R.fromIndex(4), try R.fromIndex(7)));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    var joined = try rank.unionSet(.sense, failing.allocator(), empty, range);
    defer joined.deinit();
    try std.testing.expectEqual(@as(usize, 3), joined.borrow().len());
    try std.testing.expect(joined.borrow() == .interval);

    var common = try rank.intersectSet(.sense, failing.allocator(), empty, range);
    defer common.deinit();
    try std.testing.expect(common.borrow().isEmpty());
}

test "interval/list intersection borrows the already materialised slice" {
    const R = schema.Rank(.sense);
    const values = [_]R{
        try R.fromIndex(1),
        try R.fromIndex(3),
        try R.fromIndex(5),
        try R.fromIndex(7),
    };
    const list = try rank.NodeSet(.sense).fromList(&values);
    const interval = try rank.Interval(.sense).init(try R.fromIndex(2), try R.fromIndex(7));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var result = try rank.intersectSet(.sense, failing.allocator(), list, .{ .interval = interval });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.borrow().len());
    try std.testing.expectEqual(@as(usize, 3), @intFromEnum(try result.borrow().at(0)));
    try std.testing.expectEqual(@as(usize, 5), @intFromEnum(try result.borrow().at(1)));
}

test "typed Set planner marks interval operators and checks projection domains" {
    const EntryToSense = struct {
        pub const input_kind = schema.Kind.entry;
        pub const output_kind = schema.Kind.sense;

        pub fn apply(_: @This(), source: rank.Interval(.entry)) rank.Error!rank.Interval(.sense) {
            const lo: schema.Rank(.sense) = @enumFromInt(@intFromEnum(source.lo));
            const hi: schema.Rank(.sense) = @enumFromInt(@intFromEnum(source.hi));
            return rank.Interval(.sense).init(lo, hi);
        }
    };

    const entry_range = try rank.Interval(.entry).init(
        try schema.Rank(.entry).fromIndex(2),
        try schema.Rank(.entry).fromIndex(6),
    );
    const entries = rank.Set(.entry).fromInterval(entry_range);
    const projected = try entries.projectMonotoneInterval(.sense, EntryToSense{});
    try std.testing.expectEqual(@as(usize, 4), projected.len());
    try std.testing.expect(@TypeOf(entries) != @TypeOf(projected));

    comptime {
        if (rank.Set(.entry).plan(.take).allocation != .never) @compileError("take must remain borrowed");
        if (!rank.Set(.entry).plan(.take).preserves_interval) @compileError("take must preserve intervals");
        if (rank.Set(.entry).plan(.union_set).allocation != .conditional) @compileError("union must expose its allocation boundary");
        if (!rank.Set(.entry).plan(.monotone_projection).preserves_interval) @compileError("projection must preserve intervals");
    }

    const values = [_]schema.Rank(.entry){
        try schema.Rank(.entry).fromIndex(2),
        try schema.Rank(.entry).fromIndex(4),
    };
    const list = rank.Set(.entry).from(try rank.NodeSet(.entry).fromList(&values));
    try std.testing.expectError(error.RequiresMaterialization, list.projectMonotoneInterval(.sense, EntryToSense{}));
}
