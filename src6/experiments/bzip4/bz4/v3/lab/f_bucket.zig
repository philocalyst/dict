//! Lane F, Q1 -- bucket quantisation at C=1 (a single row, no automaton
//! yet): how much does grouping tokens into power-of-two-sized "equiprobable
//! slot" buckets cost relative to exact order-0 entropy, and how few
//! buckets can get most of the way there? Two bucketing methods compared:
//!
//!   tier(b)  -- group by floor(log2 count) ("tiers"), then binary-decompose
//!               each tier's m members into at most b buckets (b in
//!               {1,2,3,unlimited}).
//!   dp       -- a DP over the count-sorted (descending) list that chooses
//!               its own group boundaries, power-of-two sizes only, with a
//!               per-bucket overhead charged inline (fixed-point on log2(K),
//!               see `dpBucketizeConverged`).
//!
//! See LANE_F.md Q1 for the writeup and the exact charging rule (shared with
//! every other question via f_common.evalStaticModel).

const std = @import("std");
const fc = @import("f_common.zig");

pub const Row1 = struct {
    method: []const u8,
    b: i32, // -1 for "dp" (not tier-parametrised), else the tier cap (b=64 stands for "unlimited")
    L: u32,
    num_buckets: usize,
    total_bits: f64,
    bits_per_token: f64,
    total_bytes: f64,
};

/// Binary-decompose `m` into at most `b` power-of-two bucket sizes (as
/// widths). If popcount(m) <= b, this is exact (zero waste); otherwise the
/// smallest bits are merged into one final, possibly-oversized bucket.
fn decomposeSizes(alloc: std.mem.Allocator, m: usize, b: usize) ![]u8 {
    if (m == 0) return alloc.alloc(u8, 0);
    var bits: std.ArrayList(u6) = .empty;
    defer bits.deinit(alloc);
    var mm = m;
    var bit: u6 = 0;
    while (mm > 0) : (bit += 1) {
        if (mm & 1 == 1) try bits.append(alloc, bit);
        mm >>= 1;
    }
    // bits is ascending; we want the largest bits kept exact.
    std.mem.reverse(u6, bits.items);
    if (bits.items.len <= b) {
        const out = try alloc.alloc(u8, bits.items.len);
        for (bits.items, 0..) |bt, i| out[i] = bt;
        return out;
    }
    const keep = b - 1;
    var covered: usize = 0;
    for (bits.items[0..keep]) |bt| covered += @as(usize, 1) << bt;
    const remainder = m - covered;
    const out = try alloc.alloc(u8, b);
    for (bits.items[0..keep], 0..) |bt, i| out[i] = bt;
    out[keep] = @intFromFloat(fc.bitsFor(remainder));
    return out;
}

fn tierBoundaries(alloc: std.mem.Allocator, counts_desc: []const u64) ![]usize {
    var bounds: std.ArrayList(usize) = .empty;
    try bounds.append(alloc, 0);
    var i: usize = 1;
    while (i < counts_desc.len) : (i += 1) {
        const t_prev = std.math.log2_int(u64, counts_desc[i - 1]);
        const t_cur = std.math.log2_int(u64, counts_desc[i]);
        if (t_cur != t_prev) try bounds.append(alloc, i);
    }
    try bounds.append(alloc, counts_desc.len);
    return bounds.toOwnedSlice(alloc);
}

/// Tier method: returns per-position (in counts_desc order) bucket id + the
/// widths array, exactly like f_common.BucketAssignment.
fn tierBucketize(alloc: std.mem.Allocator, counts_desc: []const u64, b_cap: usize) !fc.BucketAssignment {
    const bounds = try tierBoundaries(alloc, counts_desc);
    defer alloc.free(bounds);
    const n = counts_desc.len;
    var bucket_id = try alloc.alloc(u32, n);
    var widths: std.ArrayList(u8) = .empty;
    var next_bucket: u32 = 0;
    for (0..bounds.len - 1) |ti| {
        const lo = bounds[ti];
        const hi = bounds[ti + 1];
        const m = hi - lo;
        const sizes = try decomposeSizes(alloc, m, b_cap);
        defer alloc.free(sizes);
        // Smallest bucket absorbs the highest-count (front) members of the tier.
        var order = try alloc.alloc(usize, sizes.len);
        defer alloc.free(order);
        for (0..sizes.len) |i| order[i] = i;
        std.mem.sort(usize, order, sizes, struct {
            fn lt(ws: []const u8, a: usize, bb: usize) bool {
                return ws[a] < ws[bb];
            }
        }.lt);
        var pos = lo;
        for (order) |oi| {
            const w = sizes[oi];
            const cap = @as(usize, 1) << @intCast(w);
            const take = @min(cap, hi - pos);
            for (pos..pos + take) |p| bucket_id[p] = next_bucket;
            try widths.append(alloc, w);
            next_bucket += 1;
            pos += take;
        }
    }
    return .{ .bucket_id = bucket_id, .widths = try widths.toOwnedSlice(alloc), .num_buckets = next_bucket };
}

fn evalAssignment(alloc: std.mem.Allocator, seqs: *const fc.Sequences, k: usize, ids_desc: []const u32, asg: fc.BucketAssignment, g: []const u64, L: u32) !fc.ModelCost {
    const bucket_of = try alloc.alloc(u32, k);
    defer alloc.free(bucket_of);
    @memset(bucket_of, 0);
    for (ids_desc, 0..) |tok, i| bucket_of[tok] = asg.bucket_id[i];
    const row_of_bucket = try alloc.alloc(u32, asg.num_buckets);
    defer alloc.free(row_of_bucket);
    @memset(row_of_bucket, 0); // C=1: every bucket routes to the single row
    return fc.evalStaticModel(alloc, seqs, bucket_of, asg.widths, row_of_bucket, asg.num_buckets, 1, 0, g, L);
}

pub const Q1Report = struct {
    exact_h0_bits: f64,
    exact_h0_bytes: f64,
    tokens: usize,
    rows: []Row1,
};

const Ls = [_]u32{ 10, 11, 12 };
const Bs = [_]usize{ 1, 2, 3, 64 }; // 64 == "unlimited" for our vocab sizes

pub fn run(alloc: std.mem.Allocator, seqs: *const fc.Sequences, k: usize, g: []const u64) !Q1Report {
    const ids_desc = try fc.sortDescByCount(alloc, k, g);
    defer alloc.free(ids_desc);
    const counts_desc = try alloc.alloc(u64, ids_desc.len);
    defer alloc.free(counts_desc);
    for (ids_desc, 0..) |id, i| counts_desc[i] = g[id];

    const h0 = fc.exactH0Bits(g, seqs.total_tokens);

    var rows: std.ArrayList(Row1) = .empty;

    for (Ls) |L| {
        for (Bs) |b| {
            const asg = try tierBucketize(alloc, counts_desc, b);
            defer alloc.free(asg.bucket_id);
            defer alloc.free(asg.widths);
            const mc = try evalAssignment(alloc, seqs, k, ids_desc, asg, g, L);
            try rows.append(alloc, .{
                .method = "tier",
                .b = @intCast(b),
                .L = L,
                .num_buckets = asg.num_buckets,
                .total_bits = mc.total_bits,
                .bits_per_token = mc.bitsPerToken(),
                .total_bytes = mc.totalBytes(),
            });
        }
        const dp_asg = try fc.dpBucketizeConverged(alloc, counts_desc, L);
        defer alloc.free(dp_asg.bucket_id);
        defer alloc.free(dp_asg.widths);
        const dp_mc = try evalAssignment(alloc, seqs, k, ids_desc, dp_asg, g, L);
        try rows.append(alloc, .{
            .method = "dp",
            .b = -1,
            .L = L,
            .num_buckets = dp_asg.num_buckets,
            .total_bits = dp_mc.total_bits,
            .bits_per_token = dp_mc.bitsPerToken(),
            .total_bytes = dp_mc.totalBytes(),
        });
    }

    return .{
        .exact_h0_bits = h0,
        .exact_h0_bytes = h0 / 8.0,
        .tokens = seqs.total_tokens,
        .rows = try rows.toOwnedSlice(alloc),
    };
}
