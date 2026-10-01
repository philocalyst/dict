//! Lane F, Q3 -- direct bucket induction. Instead of (class, tier), cluster
//! tokens straight into K buckets under the real objective
//! P(x | r) = Pq(bucket(x) | r) / 2^w(bucket(x)), so frequency homogeneity
//! (width waste) and syntactic role (row fit) trade off in one objective.
//! Rows = a coarser exchange-clustering of the K buckets themselves (reusing
//! f_common.learnClassesOneMap at bucket granularity via `projectSequences`
//! -- literally "cluster the buckets as if they were tokens").
//!
//! Pipeline per (K, R): seed K buckets by count (Q1's DP, targeted to K),
//! cluster those buckets into R rows, then alternate a bounded hard-EM
//! local search over individual tokens' bucket membership (given the
//! current rows) with one more row-reclustering pass. See LANE_F.md Q3.

const std = @import("std");
const fc = @import("f_common.zig");

const DEBUG = false;
const OUTER_ROUNDS = 2;
const REFINE_SWEEPS = 3;
const CANDIDATE_CAP = 4000;
const SMOOTH: f64 = 0.5;
const START_SENTINEL: u32 = std.math.maxInt(u32);

fn widthsFromMembership(alloc: std.mem.Allocator, k: usize, bucket_of: []const u32, num_buckets: usize) ![]u8 {
    const counts = try alloc.alloc(usize, num_buckets);
    defer alloc.free(counts);
    @memset(counts, 0);
    for (0..k) |x| counts[bucket_of[x]] += 1;
    const widths = try alloc.alloc(u8, num_buckets);
    for (widths, 0..) |*w, b| w.* = @intFromFloat(fc.bitsFor(counts[b]));
    return widths;
}

/// One bounded hard-EM local search over token->bucket membership, holding
/// `row_of_bucket` fixed. Mutates `bucket_of` in place.
fn refineBuckets(alloc: std.mem.Allocator, seqs: *const fc.Sequences, k: usize, g: []const u64, bucket_of: []u32, row_of_bucket: []const u32, num_buckets: usize, R: u32, L: u32) !void {
    const ids_desc = try fc.sortDescByCount(alloc, k, g);
    defer alloc.free(ids_desc);
    const n_cand = @min(ids_desc.len, CANDIDATE_CAP);
    const refine_list = ids_desc[0..n_cand];
    const refine_idx = try alloc.alloc(i32, k);
    defer alloc.free(refine_idx);
    @memset(refine_idx, -1);
    for (refine_list, 0..) |id, i| refine_idx[id] = @intCast(i);

    const pred_maps = try alloc.alloc(std.AutoHashMapUnmanaged(u32, u32), n_cand);
    const succ_maps = try alloc.alloc(std.AutoHashMapUnmanaged(u32, u32), n_cand);
    for (pred_maps) |*m| m.* = .{};
    for (succ_maps) |*m| m.* = .{};
    defer {
        for (pred_maps) |*m| m.deinit(alloc);
        for (succ_maps) |*m| m.deinit(alloc);
        alloc.free(pred_maps);
        alloc.free(succ_maps);
    }
    const self_count = try alloc.alloc(u64, n_cand);
    defer alloc.free(self_count);
    @memset(self_count, 0);

    for (seqs.seqs) |s| {
        var prev: u32 = START_SENTINEL;
        for (s) |x| {
            if (prev != START_SENTINEL) {
                if (prev == x) {
                    if (refine_idx[x] >= 0) self_count[@intCast(refine_idx[x])] += 1;
                } else {
                    if (refine_idx[x] >= 0) {
                        const idx: usize = @intCast(refine_idx[x]);
                        const gop = try pred_maps[idx].getOrPut(alloc, prev);
                        if (!gop.found_existing) gop.value_ptr.* = 0;
                        gop.value_ptr.* += 1;
                    }
                    if (refine_idx[prev] >= 0) {
                        const idx: usize = @intCast(refine_idx[prev]);
                        const gop = try succ_maps[idx].getOrPut(alloc, x);
                        if (!gop.found_existing) gop.value_ptr.* = 0;
                        gop.value_ptr.* += 1;
                    }
                }
            }
            prev = x;
        }
    }

    const n_states = R + 1;
    const N = try alloc.alloc(u64, n_states * num_buckets);
    defer alloc.free(N);
    const q = try alloc.alloc(u32, n_states * num_buckets);
    defer alloc.free(q);
    const widths = try widthsFromMembership(alloc, k, bucket_of, num_buckets);
    defer alloc.free(widths);

    const pred_row_hist = try alloc.alloc(u64, n_states);
    defer alloc.free(pred_row_hist);
    const succ_bkt_hist = try alloc.alloc(u64, num_buckets);
    defer alloc.free(succ_bkt_hist);
    const succ_cost_given_row = try alloc.alloc(f64, n_states);
    defer alloc.free(succ_cost_given_row);
    const member_count = try alloc.alloc(usize, num_buckets);
    defer alloc.free(member_count);
    @memset(member_count, 0);
    for (0..k) |x| member_count[bucket_of[x]] += 1;

    const snapshot = try alloc.alloc(u32, k);
    defer alloc.free(snapshot);
    var best_cost_so_far: f64 = std.math.inf(f64);

    var sweep: u32 = 0;
    while (sweep < REFINE_SWEEPS) : (sweep += 1) {
        {
            const before = fc.evalStaticModel(alloc, seqs, bucket_of, widths, row_of_bucket, num_buckets, R, R, g, L) catch fc.ModelCost{ .total_bits = std.math.inf(f64) };
            if (before.total_bits < best_cost_so_far) {
                best_cost_so_far = before.total_bits;
                @memcpy(snapshot, bucket_of);
            }
        }
        @memset(N, 0);
        for (seqs.seqs) |s| {
            var ctx: u32 = R; // START
            for (s) |x| {
                const b = bucket_of[x];
                N[@as(usize, ctx) * num_buckets + b] += 1;
                ctx = row_of_bucket[b];
            }
        }
        for (0..n_states) |r| {
            const row = N[r * num_buckets ..][0..num_buckets];
            const qrow = q[r * num_buckets ..][0..num_buckets];
            @memset(qrow, 0);
            const quantized = fc.quantizeDense(alloc, row, L) catch continue;
            defer alloc.free(quantized);
            @memcpy(qrow, quantized);
        }

        for (refine_list, 0..) |x, idx| {
            @memset(pred_row_hist, 0);
            @memset(succ_bkt_hist, 0);
            var it_p = pred_maps[idx].iterator();
            while (it_p.next()) |e| {
                const row = row_of_bucket[bucket_of[e.key_ptr.*]];
                pred_row_hist[row] += e.value_ptr.*;
            }
            var it_s = succ_maps[idx].iterator();
            while (it_s.next()) |e| succ_bkt_hist[bucket_of[e.key_ptr.*]] += e.value_ptr.*;
            const cur_b = bucket_of[x];
            pred_row_hist[row_of_bucket[cur_b]] += self_count[idx];
            succ_bkt_hist[cur_b] += self_count[idx];
            const gx = g[x];

            // succ_cost_given_row[r] = sum over succ_bkt_hist support of
            // hist[bkt] * -log2(q[r][bkt]/2^L), computed once per candidate
            // (not per trial bucket) since many trial buckets share a row.
            for (0..n_states) |r| {
                var c: f64 = 0;
                for (succ_bkt_hist, 0..) |w, bkt| {
                    if (w == 0) continue;
                    const qv = q[r * num_buckets + bkt];
                    if (qv == 0) continue;
                    c += f64_(w) * (f64_(L) - @log2(f64_(qv)));
                }
                succ_cost_given_row[r] = c;
            }

            var best_b = cur_b;
            var best_cost = std.math.inf(f64);
            var b: u32 = 0;
            while (b < num_buckets) : (b += 1) {
                const r = row_of_bucket[b];
                var cost: f64 = succ_cost_given_row[r] + f64_(gx) * f64_(widths[b]);
                for (pred_row_hist, 0..) |w, pr| {
                    if (w == 0) continue;
                    const qv = q[pr * num_buckets + b];
                    const term = if (qv == 0) 1e9 else f64_(L) - @log2(f64_(qv));
                    cost += f64_(w) * term;
                }
                if (cost < best_cost) {
                    best_cost = cost;
                    best_b = b;
                }
            }
            // Apply immediately (not batched to end-of-sweep): moving a
            // token changes its old and new bucket's *width* (a function of
            // membership count), and evaluating every candidate against a
            // stale snapshot let many candidates simultaneously "discover"
            // the same cheap-looking bucket and pile into it, blowing its
            // real post-sweep width up far past what any single decision
            // assumed -- a real regression this lab measured directly (see
            // LANE_F.md Q3) before switching to this incremental form.
            if (best_b != cur_b) {
                bucket_of[x] = best_b;
                member_count[cur_b] -= 1;
                member_count[best_b] += 1;
                widths[cur_b] = @intFromFloat(fc.bitsFor(member_count[cur_b]));
                widths[best_b] = @intFromFloat(fc.bitsFor(member_count[best_b]));
            }
        }
    }

    // The per-candidate move rule is a local, separable approximation (it
    // does not account for a move's side effect on the *other* members of
    // its target bucket's width) and can regress real total cost even with
    // the incremental width updates above -- confirmed by direct
    // measurement (see LANE_F.md Q3). Never return worse than the best
    // real cost seen across sweeps (Lane M's "self-validating" pattern).
    {
        const final = fc.evalStaticModel(alloc, seqs, bucket_of, widths, row_of_bucket, num_buckets, R, R, g, L) catch fc.ModelCost{ .total_bits = std.math.inf(f64) };
        if (final.total_bits > best_cost_so_far) {
            @memcpy(bucket_of, snapshot);
        }
    }
}
fn f64_(x: anytype) f64 {
    return @floatFromInt(x);
}

pub const Row3 = struct {
    K: usize,
    R: u32,
    L: u32,
    num_buckets: usize,
    total_bits: f64,
    bits_per_token: f64,
    total_bytes: f64,
};

const Ks = [_]usize{ 64, 128, 256, 512 };
const Rs = [_]u32{ 16, 64, 128 };
const Ls = [_]u32{ 11, 12 };

pub const Q3Report = struct {
    rows: []Row3,
};

pub fn run(alloc: std.mem.Allocator, seqs: *const fc.Sequences, k: usize, g: []const u64) !Q3Report {
    const ids_desc = try fc.sortDescByCount(alloc, k, g);
    defer alloc.free(ids_desc);
    const counts_desc = try alloc.alloc(u64, ids_desc.len);
    defer alloc.free(counts_desc);
    for (ids_desc, 0..) |id, i| counts_desc[i] = g[id];

    var rows: std.ArrayList(Row3) = .empty;

    for (Ks) |K| {
        // Seed: tier-proportional binary decomposition targeting K total
        // buckets (every bucket stays within one floor-log2(count) tier, so
        // it starts frequency-homogeneous -- see LANE_F.md Q3). A plain
        // equal-rank-count seed was tried first and was measurably worse:
        // it lumps very different frequencies into one bucket at the
        // high-frequency end, which the candidate-capped refinement below
        // cannot fully repair on large vocabularies. An entropy-driven DP
        // seed (Q1's method, aimed at a target K by search) was also tried
        // and rejected: its K(overhead) curve is wildly discontinuous near
        // the relevant range, so it cannot be reliably aimed at a specific
        // K at all.
        const seed = try fc.tierSeedBuckets(alloc, counts_desc, K);
        defer alloc.free(seed.bucket_id);
        defer alloc.free(seed.widths);
        const num_buckets = seed.num_buckets;
        var bucket_of = try alloc.alloc(u32, k);
        defer alloc.free(bucket_of);
        @memset(bucket_of, 0);
        for (ids_desc, 0..) |id, i| bucket_of[id] = seed.bucket_id[i];

        for (Rs) |R| {
            const bo = try alloc.dupe(u32, bucket_of);
            defer alloc.free(bo);

            const row_of_bucket = try alloc.alloc(u32, num_buckets);
            defer alloc.free(row_of_bucket);
            @memset(row_of_bucket, 0);

            var round: usize = 0;
            while (round < OUTER_ROUNDS) : (round += 1) {
                // Cluster the current K buckets into R rows (reuse the
                // generic exchange-clusterer at bucket granularity).
                const g_bucket = try alloc.alloc(u64, num_buckets);
                defer alloc.free(g_bucket);
                @memset(g_bucket, 0);
                for (0..k) |x| g_bucket[bo[x]] += g[x];
                var proj = try fc.projectSequences(alloc, seqs, bo);
                defer proj.deinit();
                const new_row_of_bucket = try fc.learnClassesOneMap(alloc, &proj, num_buckets, g_bucket, .{ .C = R, .sweeps = 6, .candidate_cap = num_buckets });
                @memcpy(row_of_bucket, new_row_of_bucket);
                alloc.free(new_row_of_bucket);

                if (DEBUG) {
                    const w0 = try widthsFromMembership(alloc, k, bo, num_buckets);
                    defer alloc.free(w0);
                    const before = try fc.evalStaticModel(alloc, seqs, bo, w0, row_of_bucket, num_buckets, R, R, g, 12);
                    std.debug.print("  [debug] K={d} R={d} round={d} pre-refine bpt={d:.4}\n", .{ K, R, round, before.bitsPerToken() });
                }
                // Refine token->bucket membership given these rows.
                try refineBuckets(alloc, seqs, k, g, bo, row_of_bucket, num_buckets, R, 12);
                if (DEBUG) {
                    const w1 = try widthsFromMembership(alloc, k, bo, num_buckets);
                    defer alloc.free(w1);
                    const after = try fc.evalStaticModel(alloc, seqs, bo, w1, row_of_bucket, num_buckets, R, R, g, 12);
                    std.debug.print("  [debug] K={d} R={d} round={d} post-refine bpt={d:.4}\n", .{ K, R, round, after.bitsPerToken() });
                }
            }

            const widths = try widthsFromMembership(alloc, k, bo, num_buckets);
            defer alloc.free(widths);

            for (Ls) |L| {
                const mc = fc.evalStaticModel(alloc, seqs, bo, widths, row_of_bucket, num_buckets, R, R, g, L) catch continue;
                try rows.append(alloc, .{
                    .K = K,
                    .R = R,
                    .L = L,
                    .num_buckets = num_buckets,
                    .total_bits = mc.total_bits,
                    .bits_per_token = mc.bitsPerToken(),
                    .total_bytes = mc.totalBytes(),
                });
            }
        }
    }

    return .{ .rows = try rows.toOwnedSlice(alloc) };
}
