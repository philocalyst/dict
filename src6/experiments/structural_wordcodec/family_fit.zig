//! Complete-frame GEN and paid construction-family search over Lane A + M.
//! Each class trial has its own arena, so rejected models release their memory.
const std = @import("std");
const bz4 = @import("bz4");

pub const Fit = struct {
    bytes: []u8,
    classes: u16,
    gen: bool,
    gen_min_match: u8,
    families: bool,
    options: bz4.plan.Options,
};

pub fn fit(gpa: std.mem.Allocator, input: bz4.Parse, options: bz4.plan.Options) !Fit {
    var best: ?Fit = null;
    errdefer if (best) |winner| gpa.free(winner.bytes);
    // No-GEN is the first control; equal-size GEN candidates do not displace it.
    const modes = [_]struct { threshold: u8, families: bool }{
        .{ .threshold = 0, .families = false },
        .{ .threshold = 12, .families = false },
        .{ .threshold = 16, .families = false },
        .{ .threshold = 24, .families = false },
        .{ .threshold = 4, .families = true },
        .{ .threshold = 6, .families = true },
        .{ .threshold = 8, .families = true },
    };
    for (modes) |mode| {
        const threshold = mode.threshold;
        const enabled = threshold != 0;
        const tries: []const u16 = if (options.classes != 0) &.{options.classes} else &.{ 1, 4, 8, 16, 32, 64, 128 };
        for (tries) |class_count| {
            var trial_arena: std.heap.ArenaAllocator = .init(gpa);
            defer trial_arena.deinit();
            const scratch = trial_arena.allocator();
            var trial = options;
            trial.classes = class_count;
            trial.gen = enabled;
            trial.gen_min_match = threshold;
            trial.families = mode.families;
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
                    continue;
                }
                gpa.free(winner.bytes);
            }
            trial.bucket_uses = null;
            best = .{ .bytes = bytes, .classes = class_count, .gen = enabled, .gen_min_match = threshold, .families = mode.families, .options = trial };
        }
    }
    return best.?;
}
