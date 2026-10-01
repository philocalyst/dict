//! Lane F, Q2 -- class bigram rows. Buckets = (class, tier): induce C
//! classes by exchange clustering (reusing Lane K's method verbatim, see
//! f_common.learnClassesOneMap), then within each class independently
//! bucketize its members by count (Q1's winner: the DP method) under a
//! total symbol/bucket-count budget. Row = class of the previous token.
//! See LANE_F.md Q2.

const std = @import("std");
const fc = @import("f_common.zig");

pub const Row2 = struct {
    C: u32,
    L: u32,
    bucket_budget: usize,
    num_buckets: usize,
    total_bits: f64,
    bits_per_token: f64,
    total_bytes: f64,
};

const BuiltBuckets = struct {
    bucket_of: []u32,
    widths: []u8,
    class_of_bucket: []u32,
    num_buckets: usize,

    fn deinit(self: *BuiltBuckets, alloc: std.mem.Allocator) void {
        alloc.free(self.bucket_of);
        alloc.free(self.widths);
        alloc.free(self.class_of_bucket);
    }
};

/// Every class's members independently DP-bucketized (Q1's winning method)
/// at a single shared `overhead_bits` per-bucket cost. Higher overhead ->
/// fewer, bigger buckets overall (monotone), which is what the caller uses
/// to bisect toward a target total bucket count.
fn buildAtOverhead(alloc: std.mem.Allocator, k: usize, g: []const u64, members: []const std.ArrayList(u32), C: u32, overhead_bits: f64) !BuiltBuckets {
    const bucket_of = try alloc.alloc(u32, k);
    @memset(bucket_of, 0);
    var widths: std.ArrayList(u8) = .empty;
    var class_of_bucket: std.ArrayList(u32) = .empty;
    var total_buckets: usize = 0;

    for (0..C) |c| {
        const list = members[c].items;
        if (list.len == 0) continue;
        const ids = try alloc.dupe(u32, list);
        defer alloc.free(ids);
        const Ctx = struct {
            g: []const u64,
            fn lt(self: @This(), a: u32, b: u32) bool {
                if (self.g[a] != self.g[b]) return self.g[a] > self.g[b];
                return a < b;
            }
        };
        std.mem.sort(u32, ids, Ctx{ .g = g }, Ctx.lt);
        const counts = try alloc.alloc(u64, ids.len);
        defer alloc.free(counts);
        for (ids, 0..) |id, i| counts[i] = g[id];
        const asg = try fc.dpBucketize(alloc, counts, overhead_bits);
        defer alloc.free(asg.bucket_id);
        defer alloc.free(asg.widths);
        const base: u32 = @intCast(total_buckets);
        for (ids, 0..) |id, i| bucket_of[id] = base + asg.bucket_id[i];
        for (asg.widths) |w| {
            try widths.append(alloc, w);
            try class_of_bucket.append(alloc, @intCast(c));
        }
        total_buckets += asg.num_buckets;
    }

    return .{
        .bucket_of = bucket_of,
        .widths = try widths.toOwnedSlice(alloc),
        .class_of_bucket = try class_of_bucket.toOwnedSlice(alloc),
        .num_buckets = total_buckets,
    };
}

pub const Q2Report = struct {
    rows: []Row2, // every (C, overhead, L) point tried
    best: []Row2, // the empirical minimum per C (over overhead and L)
};

const Cs = [_]u32{ 16, 64, 128 };
const Ls = [_]u32{ 11, 12 };
// Direct grid search over the per-bucket overhead constant (not a bisected
// target): each point's *true* cost is evaluated by evalStaticModel, so the
// empirical minimum over this grid is a real answer to "what total symbol
// count is best", independent of whether dpBucketize's own internal
// (unquantized, single-class-at-a-time) proxy objective agrees exactly.
const Overheads = [_]f64{ 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048 };

pub fn run(alloc: std.mem.Allocator, seqs: *const fc.Sequences, k: usize, g: []const u64) !Q2Report {
    var rows: std.ArrayList(Row2) = .empty;
    var best: std.ArrayList(Row2) = .empty;

    for (Cs) |C| {
        const cls = try fc.learnClassesOneMap(alloc, seqs, k, g, .{ .C = C, .sweeps = 8, .candidate_cap = 8000 });
        defer alloc.free(cls);

        var members = try alloc.alloc(std.ArrayList(u32), C);
        defer alloc.free(members);
        for (members) |*m| m.* = .empty;
        defer for (members) |*m| m.deinit(alloc);
        for (0..k) |x| {
            if (g[x] == 0) continue;
            try members[cls[x]].append(alloc, @intCast(x));
        }

        var best_row: ?Row2 = null;
        for (Overheads) |oh| {
            var built = try buildAtOverhead(alloc, k, g, members, C, oh);
            defer built.deinit(alloc);
            for (Ls) |L| {
                const mc = fc.evalStaticModel(alloc, seqs, built.bucket_of, built.widths, built.class_of_bucket, built.num_buckets, C, C, g, L) catch continue;
                const row: Row2 = .{
                    .C = C,
                    .L = L,
                    .bucket_budget = @intFromFloat(oh),
                    .num_buckets = built.num_buckets,
                    .total_bits = mc.total_bits,
                    .bits_per_token = mc.bitsPerToken(),
                    .total_bytes = mc.totalBytes(),
                };
                try rows.append(alloc, row);
                if (best_row == null or row.total_bits < best_row.?.total_bits) best_row = row;
            }
        }
        try best.append(alloc, best_row.?);
    }

    return .{ .rows = try rows.toOwnedSlice(alloc), .best = try best.toOwnedSlice(alloc) };
}

/// Q4 needs an actual class-bigram model to start from ("start from the
/// best bigram model"), not just its stats -- re-run the same grid search
/// as `run()` but keep the winning arrays alive (caller frees via
/// `deinit`) instead of discarding them each iteration.
pub const BestModel = struct {
    C: u32,
    L: u32,
    bucket_of: []u32, // token -> bucket, size k
    widths: []u8, // bucket -> width
    row_of_bucket: []u32, // bucket -> class, size num_buckets
    num_buckets: usize,
    total_bits: f64,

    pub fn deinit(self: *BestModel, alloc: std.mem.Allocator) void {
        alloc.free(self.bucket_of);
        alloc.free(self.widths);
        alloc.free(self.row_of_bucket);
    }
};

pub fn findBest(alloc: std.mem.Allocator, seqs: *const fc.Sequences, k: usize, g: []const u64) !BestModel {
    var best: ?BestModel = null;

    for (Cs) |C| {
        const cls = try fc.learnClassesOneMap(alloc, seqs, k, g, .{ .C = C, .sweeps = 8, .candidate_cap = 8000 });
        defer alloc.free(cls);

        var members = try alloc.alloc(std.ArrayList(u32), C);
        defer alloc.free(members);
        for (members) |*m| m.* = .empty;
        defer for (members) |*m| m.deinit(alloc);
        for (0..k) |x| {
            if (g[x] == 0) continue;
            try members[cls[x]].append(alloc, @intCast(x));
        }

        for (Overheads) |oh| {
            var built = try buildAtOverhead(alloc, k, g, members, C, oh);
            for (Ls) |L| {
                const mc = fc.evalStaticModel(alloc, seqs, built.bucket_of, built.widths, built.class_of_bucket, built.num_buckets, C, C, g, L) catch continue;
                if (best == null or mc.total_bits < best.?.total_bits) {
                    if (best) |*b| b.deinit(alloc);
                    best = .{
                        .C = C,
                        .L = L,
                        .bucket_of = try alloc.dupe(u32, built.bucket_of),
                        .widths = try alloc.dupe(u8, built.widths),
                        .row_of_bucket = try alloc.dupe(u32, built.class_of_bucket),
                        .num_buckets = built.num_buckets,
                        .total_bits = mc.total_bits,
                    };
                }
            }
            built.deinit(alloc);
        }
    }
    return best.?;
}
