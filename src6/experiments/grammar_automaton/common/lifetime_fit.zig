//! Private native-v4 fit with one arena per class trial.
//! The frozen bz4 planner and encoder make all decisions; only the lifetime
//! of their temporary plans changes. The returned frame belongs to `gpa`.
const std = @import("std");
const bz4 = @import("bz4");

pub const Fit = struct {
    bytes: []u8,
    classes: u16,
};

pub fn fit(gpa: std.mem.Allocator, input: bz4.Parse, options: bz4.plan.Options) !Fit {
    var best: ?Fit = null;
    errdefer if (best) |winner| gpa.free(winner.bytes);
    const tries: []const u16 = if (options.classes != 0) &.{options.classes} else &.{ 1, 4, 8, 16, 32, 64, 128 };
    for (tries) |class_count| {
        var trial_arena: std.heap.ArenaAllocator = .init(gpa);
        defer trial_arena.deinit();
        const scratch = trial_arena.allocator();

        var trial = options;
        trial.classes = class_count;
        trial.bucket_uses = null;
        var first = try bz4.plan.baseline(scratch, input, trial);
        var measured: bz4.Stats = .{
            .entry_bits = try scratch.alloc(f64, first.parse.entries()),
            .entry_uses = try scratch.alloc(u32, first.parse.entries()),
        };
        @memset(measured.entry_bits.?, 0);
        @memset(measured.entry_uses.?, 0);
        gpa.free(try bz4.encode(gpa, &first, &measured));

        trial.bucket_uses = measured.entry_uses;
        var second = try bz4.plan.baseline(scratch, input, trial);
        const bytes = try bz4.encode(gpa, &second, null);
        if (best) |winner| {
            if (bytes.len >= winner.bytes.len) {
                gpa.free(bytes);
                break;
            }
            gpa.free(winner.bytes);
        }
        best = .{ .bytes = bytes, .classes = class_count };
    }
    return best.?;
}

test "class trial lifetimes preserve exact native frames and chosen class" {
    // Entry 0 refers forward to entry 1, as the historical M learner does.
    const body_off = [_]u32{ 0, 2, 4 };
    const kids = [_]u32{ 257, 257, 'a', 'b' };
    const block_off = [_]u32{ 0, 6, 12 };
    const toks = [_]u32{ 256, 257, 256, ' ', 256, '!', 256, 257, 256, ' ', 256, '?' };
    const input: bz4.Parse = .{ .body_off = &body_off, .kids = &kids, .block_off = &block_off, .toks = &toks };
    const raw = "ababababab abab!" ++ "ababababab abab?";
    const gpa = std.testing.allocator;
    for ([_]bz4.plan.Options{ .{}, .{ .hoist = true }, .{ .classes = 8, .ring = 0 } }) |options| {
        var old_arena: std.heap.ArenaAllocator = .init(gpa);
        defer old_arena.deinit();
        const original = try bz4.plan.fit(old_arena.allocator(), gpa, input, options);
        defer gpa.free(original.bytes);
        const bounded = try fit(gpa, input, options);
        defer gpa.free(bounded.bytes);
        try std.testing.expectEqual(original.options.classes, bounded.classes);
        try std.testing.expectEqualSlices(u8, original.bytes, bounded.bytes);
        const decoded = try bz4.decompress(gpa, bounded.bytes, 1);
        defer gpa.free(decoded);
        try std.testing.expectEqualStrings(raw, decoded);
    }
}
