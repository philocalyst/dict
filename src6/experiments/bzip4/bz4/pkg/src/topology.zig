//! Topology helpers over a `Lexicon`'s entry DAG: a real post-order (an
//! entry's components always precede it) and each symbol's first/last byte
//! -- the two things `classes.zig`'s DAG inheritance needs (target class
//! from the leftmost component's class, context class from the rightmost
//! component's class, recursively to explicit byte classes).
//!
//! A `Lexicon`'s entry ids are NOT guaranteed to be in dependency order:
//! `parse.zig`'s re-parse is free to rewrite an entry to reference a
//! higher-numbered but shorter entry (PLAN.md's B4SD-v2 "forward references
//! allowed, DAG must stay acyclic" rule generalises the same way here), and
//! `model_codec.zig` renumbers entries by descending count, which has
//! nothing to do with topology either. So this is a real iterative
//! (non-recursive, to bound stack depth on adversarial input) post-order
//! DFS with cycle detection, generalised from `k_common.zig`'s
//! `topoOrder`/`buildSymInfo` (Lane K) from a fixed-arity B4SD dump to an
//! n-ary in-memory `Lexicon`.

const std = @import("std");
const lexicon = @import("lexicon.zig");
const Lexicon = lexicon.Lexicon;

/// A full symbol-id order (0..k-1) such that every entry's components
/// appear before the entry itself.
pub fn topoOrder(alloc: std.mem.Allocator, lex: *const Lexicon) ![]u32 {
    const n = lex.numEntries();
    const k = 256 + n;
    var order = try std.ArrayList(u32).initCapacity(alloc, k);
    errdefer order.deinit(alloc);
    for (0..256) |i| order.appendAssumeCapacity(@intCast(i));

    const state = try alloc.alloc(u8, k); // 0 unvisited, 1 on-stack, 2 done
    defer alloc.free(state);
    @memset(state[0..256], 2);
    @memset(state[256..], 0);

    const Frame = struct { id: u32, next: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(alloc);

    var root_id: u32 = 256;
    while (root_id < k) : (root_id += 1) {
        if (state[root_id] == 2) continue;
        try stack.append(alloc, .{ .id = root_id, .next = 0 });
        state[root_id] = 1;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const kids = lex.comps(top.id - 256);
            if (top.next < kids.len) {
                const child = kids[top.next];
                top.next += 1;
                if (state[child] == 0) {
                    state[child] = 1;
                    try stack.append(alloc, .{ .id = child, .next = 0 });
                } else if (state[child] == 1) {
                    return error.CycleDetected;
                }
            } else {
                state[top.id] = 2;
                try order.append(alloc, top.id);
                stack.items.len -= 1;
            }
        }
    }
    std.debug.assert(order.items.len == k);
    return order.toOwnedSlice(alloc);
}

pub const SymInfo = struct { first1: u8, last1: u8 };

/// Every symbol's first/last literal byte, computed in one pass over
/// `order` (children before parents).
pub fn buildSymInfo(alloc: std.mem.Allocator, lex: *const Lexicon, order: []const u32) ![]SymInfo {
    const k = 256 + lex.numEntries();
    const info = try alloc.alloc(SymInfo, k);
    for (0..256) |i| {
        const b: u8 = @intCast(i);
        info[i] = .{ .first1 = b, .last1 = b };
    }
    for (order) |id| {
        if (id < 256) continue;
        const kids = lex.comps(id - 256);
        info[id] = .{ .first1 = info[kids[0]].first1, .last1 = info[kids[kids.len - 1]].last1 };
    }
    return info;
}

test "topoOrder puts every component before its parent" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var b = try lexicon.LexBuilder.init(a);
    _ = try b.addEntry(a, &.{ 'a', 'b' }, 2); // entry 0 -> id 256
    _ = try b.addEntry(a, &.{ 256, 'c' }, 3); // entry 1 -> id 257, references 256
    var lex = b.finish();

    const order = try topoOrder(a, &lex);
    var pos: [258]usize = undefined;
    for (order, 0..) |id, i| pos[id] = i;
    try std.testing.expect(pos[256] < pos[257]);
    try std.testing.expect(pos['a'] < pos[256]);
    try std.testing.expect(pos['b'] < pos[256]);

    const info = try buildSymInfo(a, &lex, order);
    try std.testing.expectEqual(@as(u8, 'a'), info[256].first1);
    try std.testing.expectEqual(@as(u8, 'b'), info[256].last1);
    try std.testing.expectEqual(@as(u8, 'a'), info[257].first1);
    try std.testing.expectEqual(@as(u8, 'c'), info[257].last1);
}

test "topoOrder rejects a cycle" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Hand-build a 1-entry lexicon whose only component is itself: illegal,
    // but the function must reject it rather than infinite-loop or panic.
    var lex = Lexicon{};
    try lex.comp_off.append(a, 0);
    try lex.comp_data.appendSlice(a, &.{ 256, 256 });
    try lex.comp_off.append(a, 2);
    try lex.explen.append(a, 999);

    try std.testing.expectError(error.CycleDetected, topoOrder(a, &lex));
}
