const std = @import("std");
const automaton = @import("automaton.zig");
const forest = @import("forest.zig");

fn adversarialValue(value: u32) u32 {
    var mixed = value;
    mixed ^= mixed >> 7;
    mixed *%= 0x9e37_79b1;
    mixed ^= mixed >> 13;
    mixed *%= 0x85eb_ca6b;
    mixed ^= mixed >> 16;
    return mixed;
}

const Less = struct {
    fn less(_: void, a: u32, b: u32) bool {
        return a < b;
    }
};

test "compact automaton and key-ordered forest share the entry-rank ledger" {
    const entry_count: usize = 2300;
    var values: [entry_count]u32 = undefined;
    for (0..entry_count) |index| values[index] = adversarialValue(@intCast(index));
    std.sort.heap(u32, &values, {}, Less.less);

    var automaton_builder = automaton.Builder.init(std.testing.allocator);
    defer automaton_builder.deinit();
    const nodes = try std.testing.allocator.alloc(forest.NodeRecord, entry_count);
    defer std.testing.allocator.free(nodes);
    const roots = try std.testing.allocator.alloc(forest.RootInput, entry_count);
    defer std.testing.allocator.free(roots);

    for (values, 0..) |value, index| {
        const key = [_]u8{
            @truncate(value >> 24),
            @truncate(value >> 16),
            @truncate(value >> 8),
            @truncate(value),
        };
        try automaton_builder.addEntry(&key, 1);
        nodes[index] = .{ .kind = .entry, .subtree_size = 1, .parent = null };
        roots[index] = .{ .start = @enumFromInt(@as(u32, @intCast(index))) };
    }

    var automaton_owned = try automaton_builder.finish();
    defer automaton_owned.deinit();
    const automaton_view = try automaton.View.open(automaton_owned.bytes);
    try automaton_view.verifyWithAllocator(std.testing.allocator);

    var forest_owned = try forest.encodeForAutomaton(std.testing.allocator, automaton_view, nodes, roots);
    defer forest_owned.deinit();
    try forest_owned.view.verify();
    try std.testing.expectEqual(automaton_view.entry_count, @as(u32, @intCast(forest_owned.view.root_count)));

    const total = automaton_owned.bytes.len + forest_owned.bytes.len;
    std.debug.print("LEX4_COMBINED_LEDGER automaton={} forest={} total={} entries={} roots={}\n", .{
        automaton_owned.bytes.len,
        forest_owned.bytes.len,
        total,
        automaton_view.entry_count,
        forest_owned.view.root_count,
    });
    try std.testing.expect(automaton_owned.bytes.len <= 40 * 1024);
    try std.testing.expect(total <= 40 * 1024);
}
