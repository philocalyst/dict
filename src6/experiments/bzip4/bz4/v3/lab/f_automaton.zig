//! Lane F, Q4 -- automaton induction. Starting from Q2's best class-bigram
//! model, greedily split rows two ways:
//!
//!   (a) order-2: for a row r, condition further on the class two tokens
//!       back (a closed-form table lookup, no search -- see LANE_F.md Q4a
//!       for the exact charging rule for the resulting incoming-transition
//!       redirects).
//!   (b) sticky self-loop split: r becomes r_a/r_b; every OTHER row's
//!       transitions into r default to r_a; each of r's own self-loop
//!       buckets (the ones that keep you inside the family) gets a
//!       STAY/FLIP decision, hard-EM local search over that decision
//!       vector (a run-based simulation -- see below), accept only if the
//!       entropy gain beats the added table/exception cost.
//!
//! Splits from different candidate rows never interact (disjoint bucket
//! sets, disjoint run families), so their bit-savings are directly
//! additive -- this lab reports single-row splits, summed, rather than
//! building a fully general multi-round PDFA learner (out of budget; see
//! LANE_F.md's honest-limitations section).

const std = @import("std");
const fc = @import("f_common.zig");
const fb = @import("f_bigram.zig");

// ---------------------------------------------------------- (a) order-2 --

pub const Order2Split = struct {
    row: u32,
    n_ctx2_groups: usize,
    gain_bits: f64,
    added_table_bits: f64,
    net_bits: f64,
    accepted: bool,
};

/// For every row r, evaluate splitting it by the class two tokens back
/// (closed form: no hard-EM needed, this is a pure lookup/count exercise).
/// Charging rule (stated once, see LANE_F.md Q4a): each ctx2 group that gets
/// its own new row pays that row's own table cost, plus ONE redirect flag
/// per *source row* that must now point through it (not one per bucket --
/// the redirect is the same for every self-class bucket from a given
/// source row, so charging it once per source row is the honest unit, and
/// charging it per bucket would just inflate the same 1-bit decision many
/// times over).
pub fn tryOrder2Splits(alloc: std.mem.Allocator, seqs: *const fc.Sequences, m: *const fb.BestModel) ![]Order2Split {
    const C = m.C;
    const K = m.num_buckets;
    const L = m.L;

    // Full order-2 histogram: N2[(ctx2)*(C+1)*K + ctx1*K + bucket], ctx2 and
    // ctx1 both in 0..C (C == START).
    const N2 = try alloc.alloc(u64, (C + 1) * (C + 1) * K);
    defer alloc.free(N2);
    @memset(N2, 0);
    for (seqs.seqs) |s| {
        var ctx2: u32 = C;
        var ctx1: u32 = C;
        for (s) |t| {
            const b = m.bucket_of[t];
            N2[(ctx2 * (C + 1) + ctx1) * K + b] += 1;
            ctx2 = ctx1;
            ctx1 = m.row_of_bucket[b];
        }
    }
    // Order-1 baseline: N1[ctx1*K+bucket] = sum over ctx2 of N2.
    const N1 = try alloc.alloc(u64, (C + 1) * K);
    defer alloc.free(N1);
    @memset(N1, 0);
    for (0..C + 1) |ctx2| {
        for (0..C + 1) |ctx1| {
            const src = N2[(ctx2 * (C + 1) + ctx1) * K ..][0..K];
            const dst = N1[ctx1 * K ..][0..K];
            for (src, dst) |v, *d| d.* += v;
        }
    }

    var results: std.ArrayList(Order2Split) = .empty;
    var current_rows: usize = C + 1;

    var r: u32 = 0;
    while (r < C) : (r += 1) {
        const base = try fc.costFromCounts(alloc, N1[r * K ..][0..K], K, 1, L);
        var order2_entropy: f64 = 0;
        var order2_table: f64 = 0;
        var n_nonzero: usize = 0;
        for (0..C + 1) |ctx2| {
            const row = N2[(ctx2 * (C + 1) + r) * K ..][0..K];
            var total: u64 = 0;
            for (row) |v| total += v;
            if (total == 0) continue;
            n_nonzero += 1;
            const c = fc.costFromCounts(alloc, row, K, 1, L) catch continue;
            order2_entropy += c.entropy_bits;
            order2_table += c.table_bits;
        }
        if (n_nonzero == 0) continue;
        const gain = base.entropy_bits - order2_entropy;
        const new_rows = n_nonzero - 1; // one group keeps r's own row for free
        const redirect_bits = f_(new_rows) * fc.bitsFor(current_rows + new_rows);
        const added = (order2_table - base.table_bits) + redirect_bits;
        const net = gain - added;
        try results.append(alloc, .{
            .row = r,
            .n_ctx2_groups = n_nonzero,
            .gain_bits = gain,
            .added_table_bits = added,
            .net_bits = net,
            .accepted = net > 0,
        });
        if (net > 0) current_rows += new_rows;
    }
    return results.toOwnedSlice(alloc);
}
fn f_(x: anytype) f64 {
    return @floatFromInt(x);
}

// --------------------------------------------------- (b) sticky splits --

const Run = struct {
    start: usize, // index into `flat_buckets`
    len: usize, // number of class-r tokens in the run
    has_tail: bool,
    tail_bucket: u32,
};

pub const StickySplit = struct {
    row: u32,
    population: u64,
    n_self_buckets: usize,
    gain_bits: f64,
    added_bits: f64,
    net_bits: f64,
    accepted: bool,
    decision: []u8 = &.{}, // owned; STAY(0)/FLIP(1) per self-bucket local index
    // Example tokens with high P(x|r_a) vs P(x|r_b), filled only if accepted.
    example_a: [5]u32 = .{ 0, 0, 0, 0, 0 },
    example_b: [5]u32 = .{ 0, 0, 0, 0, 0 },
    n_example_a: usize = 0,
    n_example_b: usize = 0,
};

pub fn freeStickySplits(alloc: std.mem.Allocator, splits: []StickySplit) void {
    for (splits) |*s| alloc.free(s.decision);
    alloc.free(splits);
}

/// Simulate the STAY/FLIP decision vector over every maximal run of
/// class-r tokens, producing (N_a, N_b) bucket histograms for rows r_a/r_b.
/// `decision[i]` (indexed by *position in `self_buckets`*, i.e. the bucket's
/// local index, not its global id) is 0 = STAY, 1 = FLIP.
///
/// A run's first token t[0] is coded using the *external* (pre-run) row --
/// entering the family from outside always lands on r_a, unconditionally,
/// because only r_a/r_b's *own* transition tables carry a STAY/FLIP
/// decision; every other row's transition into the family is a fixed
/// constant. So t[0]'s own decision (if it has one) is never consulted by
/// this run at all: r_a is used to code t[1], t[1]'s decision (now that we
/// really are inside the family) picks the row that codes t[2], and so on;
/// the last token's decision picks the row for the token right after the
/// run (the "tail"), if the run doesn't end the sequence. Two earlier
/// versions of this function got this wrong in different ways -- one
/// attributed t[i] before applying its own decision (shifting everything
/// one early), the other (this fix's predecessor) additionally applied
/// t[0]'s decision as if entry were decision-gated -- both caught by a
/// full-corpus re-simulation coming out worse than a real baseline despite
/// a predicted gain; see LANE_F.md Q4b for the numbers.
fn simulate(runs: []const Run, flat_buckets: []const u32, self_local: []const i32, decision: []const u8, na: []u64, nb: []u64) void {
    @memset(na, 0);
    @memset(nb, 0);
    for (runs) |run| {
        var state: u1 = 0; // 0 = a, 1 = b; entry from outside is always r_a
        var i: usize = 1; // t[0]'s coding event belongs to the external row
        while (i < run.len) : (i += 1) {
            const bkt = flat_buckets[run.start + i];
            if (state == 0) na[bkt] += 1 else nb[bkt] += 1;
            const li = self_local[bkt];
            std.debug.assert(li >= 0);
            if (decision[@intCast(li)] == 1) state ^= 1; // FLIP, picks the row for the *next* token
        }
        if (run.has_tail) {
            if (state == 0) na[run.tail_bucket] += 1 else nb[run.tail_bucket] += 1;
        }
    }
}

pub fn trySickySplits(alloc: std.mem.Allocator, seqs: *const fc.Sequences, m: *const fb.BestModel, g: []const u64, top_n: usize) ![]StickySplit {
    const C = m.C;
    const K = m.num_buckets;
    const L = m.L;

    // Population per row (occurrence-weighted), pick the top_n busiest.
    const pop = try alloc.alloc(u64, C);
    defer alloc.free(pop);
    @memset(pop, 0);
    for (0..m.bucket_of.len) |x| pop[m.row_of_bucket[m.bucket_of[x]]] += g[x];

    const combined = try alloc.alloc(u64, K);
    defer alloc.free(combined);

    var order = try alloc.alloc(u32, C);
    defer alloc.free(order);
    for (0..C) |c| order[c] = @intCast(c);
    std.mem.sort(u32, order, pop, struct {
        fn lt(p: []const u64, a: u32, b: u32) bool {
            return p[a] > p[b];
        }
    }.lt);

    var results: std.ArrayList(StickySplit) = .empty;
    const n_try = @min(top_n, C);

    for (order[0..n_try]) |r| {
        // Self buckets: those whose class == r.
        const self_local = try alloc.alloc(i32, K);
        defer alloc.free(self_local);
        @memset(self_local, -1);
        var n_self: usize = 0;
        for (0..K) |b| {
            if (m.row_of_bucket[b] == r) {
                self_local[b] = @intCast(n_self);
                n_self += 1;
            }
        }
        if (n_self == 0) continue;

        // Gather maximal runs of class-r tokens across every sequence.
        var flat_buckets: std.ArrayList(u32) = .empty;
        defer flat_buckets.deinit(alloc);
        var runs: std.ArrayList(Run) = .empty;
        defer runs.deinit(alloc);
        for (seqs.seqs) |s| {
            var i: usize = 0;
            while (i < s.len) {
                const b0 = m.bucket_of[s[i]];
                if (m.row_of_bucket[b0] != r) {
                    i += 1;
                    continue;
                }
                const run_start = flat_buckets.items.len;
                var j = i;
                while (j < s.len and m.row_of_bucket[m.bucket_of[s[j]]] == r) : (j += 1) {
                    try flat_buckets.append(alloc, m.bucket_of[s[j]]);
                }
                const has_tail = j < s.len;
                try runs.append(alloc, .{
                    .start = run_start,
                    .len = j - i,
                    .has_tail = has_tail,
                    .tail_bucket = if (has_tail) m.bucket_of[s[j]] else 0,
                });
                i = j;
            }
        }

        const decision = try alloc.alloc(u8, n_self);
        defer alloc.free(decision);
        @memset(decision, 0); // all-STAY baseline

        const na = try alloc.alloc(u64, K);
        defer alloc.free(na);
        const nb = try alloc.alloc(u64, K);
        defer alloc.free(nb);

        simulate(runs.items, flat_buckets.items, self_local, decision, na, nb);
        var cur_cost = blk: {
            const ca = try fc.costFromCounts(alloc, na, K, 1, L);
            const cb = try fc.costFromCounts(alloc, nb, K, 1, L);
            break :blk ca.entropy_bits + cb.entropy_bits;
        };

        // Hill-climb: 2 sweeps over every self-bucket, greedy accept.
        var sweep: usize = 0;
        while (sweep < 2) : (sweep += 1) {
            var changed = false;
            var li: usize = 0;
            while (li < n_self) : (li += 1) {
                decision[li] ^= 1;
                simulate(runs.items, flat_buckets.items, self_local, decision, na, nb);
                const ca = try fc.costFromCounts(alloc, na, K, 1, L);
                const cb = try fc.costFromCounts(alloc, nb, K, 1, L);
                const cost = ca.entropy_bits + cb.entropy_bits;
                if (cost < cur_cost) {
                    cur_cost = cost;
                    changed = true;
                } else {
                    decision[li] ^= 1; // revert
                }
            }
            if (!changed) break;
        }

        // Final counts/costs for the best decision[] found. na+nb always
        // sums, bucket by bucket, to row r's original (pre-split) counts --
        // STAY/FLIP only repartitions which branch each event lands in, it
        // never changes the total -- so the pre-split baseline cost can be
        // read straight off (na+nb) with no separate bookkeeping.
        simulate(runs.items, flat_buckets.items, self_local, decision, na, nb);
        const ca = try fc.costFromCounts(alloc, na, K, 1, L);
        const cb = try fc.costFromCounts(alloc, nb, K, 1, L);
        for (combined, na, nb) |*d, x, y| d.* = x + y;
        const base_row = try fc.costFromCounts(alloc, combined, K, 1, L);
        const gain = base_row.entropy_bits - (ca.entropy_bits + cb.entropy_bits);
        const table_added = (ca.table_bits + cb.table_bits) - base_row.table_bits;
        const exception_bits = f_(n_self) * fc.bitsFor(C + 2); // one flag per self bucket (see file doc comment)
        const added = table_added + exception_bits;
        const net = gain - added;

        var split: StickySplit = .{
            .row = r,
            .population = pop[r],
            .n_self_buckets = n_self,
            .gain_bits = gain,
            .added_bits = added,
            .net_bits = net,
            .accepted = net > 0,
            .decision = try alloc.dupe(u8, decision),
        };
        if (split.accepted) {
            // Example tokens: highest g among tokens whose bucket ended up
            // mostly-a vs mostly-b (by which side has more mass). Includes
            // *every* bucket na/nb ever attributed a count to, not just the
            // self-loop ones -- a "tail" bucket (whatever follows an exit
            // from r_a vs r_b) is exactly the kind of thing a real regime
            // split should show up in, and restricting to self-loop buckets
            // only found "b" examples on nothing (see LANE_F.md Q4b).
            var a_bkts: std.ArrayList(u32) = .empty;
            defer a_bkts.deinit(alloc);
            var b_bkts: std.ArrayList(u32) = .empty;
            defer b_bkts.deinit(alloc);
            for (0..K) |b| {
                if (na[b] == 0 and nb[b] == 0) continue;
                if (na[b] >= nb[b]) try a_bkts.append(alloc, @intCast(b)) else try b_bkts.append(alloc, @intCast(b));
            }
            fillExamples(m.bucket_of, g, a_bkts.items, &split.example_a, &split.n_example_a);
            fillExamples(m.bucket_of, g, b_bkts.items, &split.example_b, &split.n_example_b);
        }
        try results.append(alloc, split);
    }
    return results.toOwnedSlice(alloc);
}

const TokCount = struct { tok: u32, g: u64 };
fn tokCountLt(_: void, a: TokCount, b: TokCount) bool {
    return a.g > b.g;
}

fn fillExamples(bucket_of: []const u32, g: []const u64, bkts: []const u32, out: *[5]u32, n_out: *usize) void {
    var best: [5]TokCount = [_]TokCount{.{ .tok = 0, .g = 0 }} ** 5;
    var n: usize = 0;
    for (bucket_of, 0..) |b, x| {
        if (g[x] == 0) continue;
        var found = false;
        for (bkts) |bb| {
            if (bb == b) {
                found = true;
                break;
            }
        }
        if (!found) continue;
        if (n < 5) {
            best[n] = .{ .tok = @intCast(x), .g = g[x] };
            n += 1;
            std.mem.sort(TokCount, best[0..n], {}, tokCountLt);
        } else if (g[x] > best[4].g) {
            best[4] = .{ .tok = @intCast(x), .g = g[x] };
            std.mem.sort(TokCount, &best, {}, tokCountLt);
        }
    }
    for (0..n) |i| out[i] = best[i].tok;
    n_out.* = n;
}

// ------------------------------------------------------------------- test --
// Regression coverage for the off-by-one this file's `simulate` had (see
// LANE_F.md Q4b): a synthetic 1-run scenario, hand-traced, no file I/O
// needed. One run of 4 class-r tokens (buckets 0,1,0,1) followed by a tail
// (bucket 2); self-loop buckets are {0,1} (local indices 0,1).

test "simulate: all-STAY keeps every event in branch a, entry token excluded" {
    const self_local = [_]i32{ 0, 1, -1 };
    const flat_buckets = [_]u32{ 0, 1, 0, 1 };
    const runs = [_]Run{.{ .start = 0, .len = 4, .has_tail = true, .tail_bucket = 2 }};
    var na = [_]u64{0} ** 3;
    var nb = [_]u64{0} ** 3;
    const decision = [_]u8{ 0, 0 }; // STAY, STAY
    simulate(&runs, &flat_buckets, &self_local, &decision, &na, &nb);
    // t[0] (bucket 0) is the run's entry token: excluded, never attributed.
    // t[1..3] and the tail (4 events total) all land in 'a' since nothing
    // ever flips.
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 1 }, &na);
    try std.testing.expectEqualSlices(u64, &.{ 0, 0, 0 }, &nb);
}

test "simulate: a FLIP decision only affects the token *after* it" {
    const self_local = [_]i32{ 0, 1, -1 };
    const flat_buckets = [_]u32{ 0, 1, 0, 1 };
    const runs = [_]Run{.{ .start = 0, .len = 4, .has_tail = true, .tail_bucket = 2 }};
    var na = [_]u64{0} ** 3;
    var nb = [_]u64{0} ** 3;
    const decision = [_]u8{ 0, 1 }; // bucket 0: STAY, bucket 1: FLIP
    simulate(&runs, &flat_buckets, &self_local, &decision, &na, &nb);
    // Trace: entry a. t[0]=bkt0 STAY -> still a; attribute t[1]=bkt1 to a.
    // t[1]=bkt1 FLIP -> b; attribute t[2]=bkt0 to b. t[2]=bkt0 STAY -> still
    // b; attribute t[3]=bkt1 to b. t[3]=bkt1 FLIP -> a; attribute tail
    // (bkt2) to a.
    try std.testing.expectEqualSlices(u64, &.{ 0, 1, 1 }, &na);
    try std.testing.expectEqualSlices(u64, &.{ 1, 1, 0 }, &nb);
    // Invariant that must hold for ANY decision vector: na+nb reproduces
    // exactly what a single unsplit row r would have counted (4 events:
    // t[1],t[2],t[3],tail), never more, never less.
    var total: u64 = 0;
    for (na, nb) |a, b| total += a + b;
    try std.testing.expectEqual(@as(u64, 4), total);
}
