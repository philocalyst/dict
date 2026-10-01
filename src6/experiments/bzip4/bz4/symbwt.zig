//! symbwt: Burrows-Wheeler transform over u32 symbol sequences, alphabet
//! size K up to ~2^20 (bz4 lab, Lane W).
//!
//! Suffix array by prefix doubling with two-pass stable counting sort
//! (O(m log m), m = n+1 including one appended virtual sentinel). The
//! sentinel is never emitted in the output: `bwt` returns the last column
//! `l` (length n, values in 0..k_alphabet-1, same alphabet as the input)
//! plus a `primary` index (0..n) that tells the inverse where the sentinel
//! row was. This is the standard "explicit sentinel, dropped from the
//! output" construction — equivalent in spirit to the classic bzip2
//! "virtual sentinel" trick, just derived via an ordinary (non-cyclic)
//! suffix array instead of hand-rolled cyclic rotation sorting.
//!
//! Pure Zig 0.16, std only, no allocation surprises: every allocation here
//! is freed before the call returns (or owned by the caller for `l`/output
//! of `ibwt`).

const std = @import("std");

pub const BwtResult = struct {
    l: []u32,
    primary: usize,
};

/// Stable counting sort: order_dst[k] = order_src sorted ascending by
/// key[order_src[i]]. `count` is scratch, must have length >= num_buckets.
fn countingSort(order_src: []const u32, key: []const u32, num_buckets: usize, order_dst: []u32, count: []u32) void {
    @memset(count[0..num_buckets], 0);
    for (order_src) |idx| count[key[idx]] += 1;
    var sum: u32 = 0;
    for (count[0..num_buckets]) |*c| {
        const t = c.*;
        c.* = sum;
        sum += t;
    }
    for (order_src) |idx| {
        const kk = key[idx];
        order_dst[count[kk]] = idx;
        count[kk] += 1;
    }
}

/// Suffix array of U (length m), values 0..alphabet_size inclusive, with
/// value 0 required to appear exactly once (the sentinel) so all suffixes
/// are distinct. Prefix doubling, O(m log m).
fn buildSuffixArray(alloc: std.mem.Allocator, u: []const u32, alphabet_size: usize) ![]u32 {
    const m = u.len;
    const sa = try alloc.alloc(u32, m);
    errdefer alloc.free(sa);
    var rank = try alloc.alloc(u32, m);
    defer alloc.free(rank);
    var tmp_rank = try alloc.alloc(u32, m);
    defer alloc.free(tmp_rank);
    const order2 = try alloc.alloc(u32, m);
    defer alloc.free(order2);
    const key2 = try alloc.alloc(u32, m);
    defer alloc.free(key2);
    const iota = try alloc.alloc(u32, m);
    defer alloc.free(iota);
    for (0..m) |i| iota[i] = @intCast(i);
    const count = try alloc.alloc(u32, @max(m, alphabet_size) + 2);
    defer alloc.free(count);

    // Initial sort by the single character value.
    countingSort(iota, u, alphabet_size + 1, sa, count[0 .. alphabet_size + 1]);
    rank[sa[0]] = 0;
    for (1..m) |i| {
        rank[sa[i]] = rank[sa[i - 1]] + @as(u32, if (u[sa[i]] != u[sa[i - 1]]) 1 else 0);
    }
    if (m <= 1) return sa;

    var k: usize = 1;
    while (true) {
        for (0..m) |i| key2[i] = if (i + k < m) rank[i + k] + 1 else 0;
        // Sort by secondary key (range 0..m), stable, then by primary key
        // (range 0..m-1), stable: two-pass LSD radix over the pair.
        countingSort(sa, key2, m + 1, order2, count[0 .. m + 1]);
        countingSort(order2, rank, m, sa, count[0..m]);

        tmp_rank[sa[0]] = 0;
        var all_distinct = true;
        for (1..m) |i| {
            const prev = sa[i - 1];
            const cur = sa[i];
            const same = rank[cur] == rank[prev] and key2[cur] == key2[prev];
            tmp_rank[cur] = tmp_rank[prev] + @as(u32, if (same) 0 else 1);
            if (same) all_distinct = false;
        }
        std.mem.swap([]u32, &rank, &tmp_rank);
        if (all_distinct or rank[sa[m - 1]] == m - 1) break;
        k *= 2;
        if (k >= m) break; // safety net; sentinel guarantees convergence before this
    }
    return sa;
}

/// BWT of `seq` (values 0..k_alphabet-1). Returns `l` (owned by caller,
/// length seq.len) and `primary`. O(n log n) time, O(n) extra space.
pub fn bwt(alloc: std.mem.Allocator, seq: []const u32, k_alphabet: usize) !BwtResult {
    const n = seq.len;
    const m = n + 1;
    const u = try alloc.alloc(u32, m);
    defer alloc.free(u);
    for (seq, 0..) |s, i| u[i] = s + 1;
    u[n] = 0;

    const sa = try buildSuffixArray(alloc, u, k_alphabet);
    defer alloc.free(sa);

    const l = try alloc.alloc(u32, n);
    errdefer alloc.free(l);
    var primary: usize = 0;
    var out_i: usize = 0;
    for (sa, 0..) |s, i| {
        const src = (@as(usize, s) + m - 1) % m;
        const val = u[src];
        if (val == 0) {
            primary = i;
        } else {
            l[out_i] = val - 1;
            out_i += 1;
        }
    }
    std.debug.assert(out_i == n);
    return .{ .l = l, .primary = primary };
}

/// Inverse BWT: reconstructs the original sequence (length l.len) from the
/// last column `l` and the primary index produced by `bwt`.
pub fn ibwt(alloc: std.mem.Allocator, l: []const u32, primary: usize, k_alphabet: usize) ![]u32 {
    const n = l.len;
    const m = n + 1;
    const full = try alloc.alloc(u32, m);
    defer alloc.free(full);
    {
        var src_i: usize = 0;
        for (0..m) |i| {
            if (i == primary) {
                full[i] = 0;
            } else {
                full[i] = l[src_i] + 1;
                src_i += 1;
            }
        }
    }

    const count = try alloc.alloc(u32, k_alphabet + 1);
    defer alloc.free(count);
    @memset(count, 0);
    for (full) |v| count[v] += 1;
    const base = try alloc.alloc(u32, k_alphabet + 1);
    defer alloc.free(base);
    {
        var sum: u32 = 0;
        for (0..k_alphabet + 1) |c| {
            base[c] = sum;
            sum += count[c];
        }
    }
    const next = try alloc.alloc(u32, m);
    defer alloc.free(next);
    {
        const occ = try alloc.alloc(u32, k_alphabet + 1);
        defer alloc.free(occ);
        @memset(occ, 0);
        for (0..m) |i| {
            const v = full[i];
            next[i] = base[v] + occ[v];
            occ[v] += 1;
        }
    }
    const prev = try alloc.alloc(u32, m);
    defer alloc.free(prev);
    for (0..m) |i| prev[next[i]] = @intCast(i);

    const out = try alloc.alloc(u32, n);
    errdefer alloc.free(out);
    var row = primary;
    for (0..n) |p| {
        const i = prev[row];
        const val = full[i];
        std.debug.assert(val != 0);
        out[p] = val - 1;
        row = i;
    }
    return out;
}

// ---------------------------------------------------------------- tests --

fn naiveBwt(alloc: std.mem.Allocator, seq: []const u32) !BwtResult {
    const n = seq.len;
    const m = n + 1;
    const u = try alloc.alloc(u32, m);
    defer alloc.free(u);
    for (seq, 0..) |s, i| u[i] = s + 1;
    u[n] = 0;

    const idx = try alloc.alloc(usize, m);
    defer alloc.free(idx);
    for (0..m) |i| idx[i] = i;

    const Ctx = struct {
        u: []const u32,
        m: usize,
        fn less(self: @This(), a: usize, b: usize) bool {
            var i: usize = 0;
            while (i < self.m) : (i += 1) {
                const av = self.u[(a + i) % self.m];
                const bv = self.u[(b + i) % self.m];
                if (av != bv) return av < bv;
            }
            return false;
        }
    };
    std.mem.sort(usize, idx, Ctx{ .u = u, .m = m }, Ctx.less);

    const l = try alloc.alloc(u32, n);
    var primary: usize = 0;
    var out_i: usize = 0;
    for (idx, 0..) |s, i| {
        const src = (s + m - 1) % m;
        const val = u[src];
        if (val == 0) {
            primary = i;
        } else {
            l[out_i] = val - 1;
            out_i += 1;
        }
    }
    std.debug.assert(out_i == n);
    return .{ .l = l, .primary = primary };
}

fn checkRoundtrip(alloc: std.mem.Allocator, seq: []const u32, k: usize) !void {
    const r = try bwt(alloc, seq, k);
    defer alloc.free(r.l);
    const back = try ibwt(alloc, r.l, r.primary, k);
    defer alloc.free(back);
    try std.testing.expectEqualSlices(u32, seq, back);
}

fn checkAgainstNaive(alloc: std.mem.Allocator, seq: []const u32, k: usize) !void {
    const fast = try bwt(alloc, seq, k);
    defer alloc.free(fast.l);
    const naive = try naiveBwt(alloc, seq);
    defer alloc.free(naive.l);
    try std.testing.expectEqual(naive.primary, fast.primary);
    try std.testing.expectEqualSlices(u32, naive.l, fast.l);
    const back = try ibwt(alloc, fast.l, fast.primary, k);
    defer alloc.free(back);
    try std.testing.expectEqualSlices(u32, seq, back);
}

test "empty and tiny lengths" {
    const alloc = std.testing.allocator;
    try checkAgainstNaive(alloc, &.{}, 4);
    try checkAgainstNaive(alloc, &.{0}, 4);
    try checkAgainstNaive(alloc, &.{3}, 4);
    try checkAgainstNaive(alloc, &.{ 0, 0 }, 4);
    try checkAgainstNaive(alloc, &.{ 0, 1 }, 4);
    try checkAgainstNaive(alloc, &.{ 1, 0 }, 4);
    try checkAgainstNaive(alloc, &.{ 2, 2, 2 }, 4);
}

test "tiny alphabet, all one symbol" {
    const alloc = std.testing.allocator;
    const seq = try alloc.alloc(u32, 500);
    defer alloc.free(seq);
    @memset(seq, 0);
    try checkAgainstNaive(alloc, seq, 1);
}

test "periodic input" {
    const alloc = std.testing.allocator;
    const seq = try alloc.alloc(u32, 731);
    defer alloc.free(seq);
    for (seq, 0..) |*s, i| s.* = @intCast(i % 5);
    try checkAgainstNaive(alloc, seq, 5);
}

test "random small alphabets against naive" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xBEEF);
    const rnd = prng.random();
    for (0..40) |trial| {
        const n = rnd.uintLessThan(usize, 60);
        const k = 1 + rnd.uintLessThan(usize, 6);
        const seq = try alloc.alloc(u32, n);
        defer alloc.free(seq);
        for (seq) |*s| s.* = rnd.uintLessThan(u32, @intCast(k));
        checkAgainstNaive(alloc, seq, k) catch |e| {
            std.debug.print("trial {d} failed n={d} k={d}\n", .{ trial, n, k });
            return e;
        };
    }
}

test "random larger inputs roundtrip (no naive cross-check, too slow)" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();
    for (0..10) |_| {
        const n = 200 + rnd.uintLessThan(usize, 4000);
        const k = 1 + rnd.uintLessThan(usize, 1 << 16);
        const seq = try alloc.alloc(u32, n);
        defer alloc.free(seq);
        for (seq) |*s| s.* = rnd.uintLessThan(u32, @intCast(k));
        try checkRoundtrip(alloc, seq, k);
    }
}

test "large alphabet, sparse symbols" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rnd = prng.random();
    const n = 5000;
    const k: usize = 1 << 20;
    const seq = try alloc.alloc(u32, n);
    defer alloc.free(seq);
    for (seq) |*s| s.* = rnd.uintLessThan(u32, @intCast(k));
    try checkRoundtrip(alloc, seq, k);
}
