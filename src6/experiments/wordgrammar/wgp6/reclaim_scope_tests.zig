const std = @import("std");
const Scope = @import("reclaim_scope.zig").Scope;
const Budget = @import("budget_reclaim.zig").Budget;

test "shortened output view can be reallocated without leaking its full owner" {
    var scope: Scope = .{ .parent = std.testing.allocator };
    defer scope.deinit();
    const alloc = scope.allocator();
    var seq = try alloc.alloc(u32, 4096);
    for (seq[0..100], 0..) |*item, i| item.* = @intCast(i);
    seq = seq[0..100]; // grammar2.build returns a shortened seq view.
    seq = try alloc.realloc(seq, 512);
    try std.testing.expectEqual(@as(usize, 512), seq.len);
    for (seq[0..100], 0..) |item, i| try std.testing.expectEqual(@as(u32, @intCast(i)), item);
    try std.testing.expectEqual(@as(usize, 1), scope.owned.count());
    alloc.free(seq);
    try std.testing.expectEqual(@as(usize, 0), scope.owned.count());
}

test "scope accepts retained candidate output and reclaims temporary hash buffers" {
    var scope: Scope = .{ .parent = std.testing.allocator };
    defer scope.deinit();
    const alloc = scope.allocator();
    const temporary = try alloc.alloc(u8, 8 * 1024 * 1024);
    const result = try alloc.dupe(u8, "exact-candidate");
    alloc.free(temporary);
    try std.testing.expectEqual(@as(usize, 1), scope.owned.count());
    try std.testing.expectEqualStrings("exact-candidate", result);
}

test "shortened view and retained output return every byte to parent budget" {
    var budget: Budget = .{ .parent = std.testing.allocator, .limit = 32 * 1024 * 1024 };
    var scope: Scope = .{ .parent = budget.allocator() };
    const alloc = scope.allocator();
    const seq = try alloc.alloc(u32, 4096);
    const table = try alloc.alloc(u8, 8 * 1024 * 1024);
    const result = try alloc.dupe(u8, "candidate");
    const shortened: []u32 = seq[0..100];
    alloc.free(shortened);
    alloc.free(table);
    try std.testing.expectEqualStrings("candidate", result);
    try std.testing.expect(budget.live > 0);
    scope.deinit();
    try std.testing.expectEqual(@as(usize, 0), budget.live);
}
