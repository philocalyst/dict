//! Lane F: shared B4SD reading + sequence/counting/quantisation/cost-model
//! utilities for the bucket-and-automaton oracle study. Pure Zig 0.16, std
//! only. This is an *estimate* study (see LANE_F.md): there is no real
//! bitstream here, only the cost formulas defined in PLAN's Lane F brief,
//! applied consistently everywhere. Reader is copied/simplified from
//! k_common.zig (Lane K) -- we only ever need `blocks` and `children` (as
//! entry-body sequences), never byte expansion, so `SymInfo`/`topoOrder`/
//! the range coder are dropped entirely.

const std = @import("std");

pub fn f(x: anytype) f64 {
    return @floatFromInt(x);
}
pub fn log2s(x: f64) f64 {
    return @log2(@max(x, 1e-12));
}

/// ceil(log2(n)) for n >= 1 (0 for n <= 1).
pub fn bitsFor(n: usize) f64 {
    if (n <= 1) return 0;
    return @ceil(@log2(f(n)));
}

pub const Timer = struct {
    io: std.Io,
    started: i96,
    pub fn start(io: std.Io) Timer {
        return .{ .io = io, .started = std.Io.Clock.awake.now(io).nanoseconds };
    }
    pub fn readMs(self: Timer) f64 {
        const value = std.Io.Clock.awake.now(self.io).nanoseconds - self.started;
        return @as(f64, @floatFromInt(@max(@as(i96, 0), value))) / 1e6;
    }
};

// -------------------------------------------------------------- B4SD I/O --

pub const Dump = struct {
    alloc: std.mem.Allocator,
    version: u32,
    children: [][]u32, // children[i] = child ids of rule i (symbol id 256+i)
    child_store: []u32,
    blocks: [][]u32,
    k: usize, // 256 + rule_count

    pub fn deinit(self: *Dump) void {
        self.alloc.free(self.blocks);
        self.alloc.free(self.children);
        self.alloc.free(self.child_store);
    }
};

fn readU32(bytes: []const u8, off: *usize) u32 {
    const v = std.mem.readInt(u32, bytes[off.*..][0..4], .little);
    off.* += 4;
    return v;
}

pub fn readDump(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !Dump {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 31));
    defer alloc.free(bytes);
    var off: usize = 0;
    const magic = readU32(bytes, &off);
    if (magic != 0x44533442) return error.BadMagic;
    const version = readU32(bytes, &off);
    if (version != 1 and version != 2) return error.BadVersion;
    const rule_count = readU32(bytes, &off);
    const block_count = readU32(bytes, &off);
    _ = readU32(bytes, &off); // block_bytes, unused (no expansion needed)
    _ = readU32(bytes, &off); // raw_len, unused

    const children = try alloc.alloc([]u32, rule_count);
    var total_arity: usize = 0;
    if (version == 1) {
        total_arity = @as(usize, rule_count) * 2;
    } else {
        var scan_off = off;
        var r: usize = 0;
        while (r < rule_count) : (r += 1) {
            const arity = readU32(bytes, &scan_off);
            if (arity < 2) return error.BadArity;
            total_arity += arity;
            scan_off += @as(usize, arity) * 4;
        }
    }
    const child_store = try alloc.alloc(u32, total_arity);
    var fill: usize = 0;
    var r: usize = 0;
    while (r < rule_count) : (r += 1) {
        var arity: usize = 2;
        if (version == 2) arity = readU32(bytes, &off);
        const slice = child_store[fill..][0..arity];
        fill += arity;
        for (slice) |*c| c.* = readU32(bytes, &off);
        children[r] = slice;
    }

    const blocks = try alloc.alloc([]u32, block_count);
    for (blocks) |*blk| {
        const root_count = readU32(bytes, &off);
        const syms = try alloc.alloc(u32, root_count);
        for (syms) |*s| s.* = readU32(bytes, &off);
        blk.* = syms;
    }
    if (off != bytes.len) return error.TrailingBytes;

    return .{
        .alloc = alloc,
        .version = version,
        .children = children,
        .child_store = child_store,
        .blocks = blocks,
        .k = 256 + rule_count,
    };
}

// -------------------------------------------------------------- sequences --
// "The symbol sequence to model is every block's token stream (context
// resets at block start) plus every entry body (treat each body as its own
// short sequence)" -- both draw from the same id space (256 bytes ..
// 256+rule_count), so we just concatenate `blocks` and `children` as a flat
// list of independent sequences.

pub const Sequences = struct {
    alloc: std.mem.Allocator,
    seqs: [][]const u32, // slices into either the Dump or `backing`
    total_tokens: usize,
    backing: ?[]u32 = null, // owned token storage, only set by `projectSequences`

    pub fn deinit(self: *Sequences) void {
        if (self.backing) |b| self.alloc.free(b);
        self.alloc.free(self.seqs);
    }
};

/// Build a derived sequence set over a *projected* alphabet (every token id
/// replaced by `map[id]`), same sequence boundaries. Used to reuse the
/// token-level exchange-clusterer (`learnClassesOneMap`) at bucket
/// granularity: project through `bucket_of` and cluster buckets into rows
/// exactly as if buckets were tokens (Q3's "coarser clustering of buckets").
pub fn projectSequences(alloc: std.mem.Allocator, seqs: *const Sequences, map: []const u32) !Sequences {
    const backing = try alloc.alloc(u32, seqs.total_tokens);
    const out_seqs = try alloc.alloc([]const u32, seqs.seqs.len);
    var off: usize = 0;
    for (seqs.seqs, 0..) |s, i| {
        const dst = backing[off..][0..s.len];
        for (s, 0..) |t, j| dst[j] = map[t];
        out_seqs[i] = dst;
        off += s.len;
    }
    return .{ .alloc = alloc, .seqs = out_seqs, .total_tokens = seqs.total_tokens, .backing = backing };
}

pub fn buildSequences(alloc: std.mem.Allocator, dump: *const Dump) !Sequences {
    const n = dump.blocks.len + dump.children.len;
    const seqs = try alloc.alloc([]const u32, n);
    var i: usize = 0;
    var total: usize = 0;
    for (dump.blocks) |b| {
        seqs[i] = b;
        total += b.len;
        i += 1;
    }
    for (dump.children) |c| {
        seqs[i] = c;
        total += c.len;
        i += 1;
    }
    return .{ .alloc = alloc, .seqs = seqs, .total_tokens = total };
}

pub fn computeG(alloc: std.mem.Allocator, k: usize, seqs: *const Sequences) ![]u64 {
    const g = try alloc.alloc(u64, k);
    @memset(g, 0);
    for (seqs.seqs) |s| for (s) |t| {
        g[t] += 1;
    };
    return g;
}

/// Exact order-0 entropy of the g[] distribution, in bits: -sum n_x log2(n_x/N).
pub fn exactH0Bits(g: []const u64, n_total: usize) f64 {
    const N = f(n_total);
    var bits: f64 = 0;
    for (g) |gx| {
        if (gx == 0) continue;
        bits -= f(gx) * log2s(f(gx) / N);
    }
    return bits;
}

// ------------------------------------------------------------ quantisation --
// tANS quantisation of a support set's raw counts to sum exactly 2^L, every
// nonzero entry gets >= 1 slot (largest-remainder / Hamilton apportionment,
// floored at 1). `raw` is dense size `n`; zero entries stay zero.

pub fn quantizeDense(alloc: std.mem.Allocator, raw: []const u64, L: u32) ![]u32 {
    const target: u64 = @as(u64, 1) << @intCast(L);
    var total: u64 = 0;
    var support: usize = 0;
    for (raw) |c| {
        if (c > 0) {
            total += c;
            support += 1;
        }
    }
    const q = try alloc.alloc(u32, raw.len);
    @memset(q, 0);
    if (support == 0) return q;
    if (support > target) return error.TooManySymbolsForL;
    if (total == 0) return q;

    const Item = struct { idx: usize, rem: f64 };
    var items = try std.ArrayList(Item).initCapacity(alloc, support);
    defer items.deinit(alloc);
    var used: u64 = 0;
    for (raw, 0..) |c, i| {
        if (c == 0) continue;
        const ideal = f(c) * f(target) / f(total);
        var base = @floor(ideal);
        if (base < 1) base = 1;
        q[i] = @intFromFloat(base);
        used += q[i];
        items.appendAssumeCapacity(.{ .idx = i, .rem = ideal - base });
    }
    if (used < target) {
        // Distribute leftover slots to the largest fractional remainders.
        std.mem.sort(Item, items.items, {}, struct {
            fn lt(_: void, a: Item, b: Item) bool {
                return a.rem > b.rem;
            }
        }.lt);
        var leftover = target - used;
        var i: usize = 0;
        while (leftover > 0) : (i += 1) {
            if (i >= items.items.len) i = 0;
            q[items.items[i].idx] += 1;
            leftover -= 1;
        }
    } else if (used > target) {
        // Take back from the smallest fractional remainders (largest base
        // first), never below 1.
        std.mem.sort(Item, items.items, {}, struct {
            fn lt(_: void, a: Item, b: Item) bool {
                return a.rem < b.rem;
            }
        }.lt);
        var excess = used - target;
        var i: usize = 0;
        while (excess > 0) : (i = (i + 1) % items.items.len) {
            const idx = items.items[i].idx;
            if (q[idx] > 1) {
                q[idx] -= 1;
                excess -= 1;
            }
        }
    }
    return q;
}

// --------------------------------------------------------------- cost model --
// See LANE_F.md "Cost model" for the exact charging rule this implements.
// cost(token x | row r) = -log2(Pq(bucket(x)|r)) + width(bucket(x))
// table cost = K*6 (flat, per bucket) + sum_r |S_r|*(log2(K) + L/2)
//              + next-row exceptions (0 unless the automaton explicitly
//              diverges from the "next_row is a pure function of the
//              current bucket" default -- see f_automaton.zig).

pub const BUCKET_FLAT_BITS: f64 = 6.0;

pub const ModelCost = struct {
    entropy_bits: f64 = 0,
    raw_bits: f64 = 0,
    table_bits: f64 = 0,
    exception_bits: f64 = 0,
    total_bits: f64 = 0,
    tokens: usize = 0,
    num_buckets: usize = 0,
    num_rows: usize = 0,

    pub fn bitsPerToken(self: ModelCost) f64 {
        if (self.tokens == 0) return 0;
        return self.total_bits / f(self.tokens);
    }
    pub fn totalBytes(self: ModelCost) f64 {
        return self.total_bits / 8.0;
    }
};

/// N[row * num_buckets + bucket] bigram counts by replaying every sequence
/// through the (bucket_of, row_of_bucket, start_row) automaton -- shared by
/// `evalStaticModel` and by Q4's automaton experiments, which need the raw
/// counts (to build order-2 tables, or to re-derive them after a row split)
/// rather than just a final cost number. `n_states` = num_rows + 1 (the
/// extra row at index `num_rows` is only ever populated if `start_row ==
/// num_rows`, i.e. a dedicated START state distinct from every real row).
pub fn buildBigramCounts(alloc: std.mem.Allocator, seqs: *const Sequences, bucket_of: []const u32, row_of_bucket: []const u32, num_buckets: usize, num_rows: usize, start_row: u32) ![]u64 {
    const n_states = num_rows + 1;
    const N = try alloc.alloc(u64, n_states * num_buckets);
    @memset(N, 0);
    for (seqs.seqs) |s| {
        var ctx: u32 = start_row;
        for (s) |t| {
            const b = bucket_of[t];
            N[@as(usize, ctx) * num_buckets + b] += 1;
            ctx = row_of_bucket[b];
        }
    }
    return N;
}

/// Entropy + table cost (see `ModelCost`) of an already-built N[row][bucket]
/// table, `n_states` rows x `num_buckets` columns.
pub fn costFromCounts(alloc: std.mem.Allocator, N: []const u64, num_buckets: usize, n_states: usize, L: u32) !struct { entropy_bits: f64, table_bits: f64 } {
    var entropy_bits: f64 = 0;
    var table_bits: f64 = 0;
    const logK = @log2(@max(f(num_buckets), 1.0));
    var r: usize = 0;
    while (r < n_states) : (r += 1) {
        const row = N[r * num_buckets ..][0..num_buckets];
        var total: u64 = 0;
        for (row) |c| total += c;
        if (total == 0) continue;
        const q = try quantizeDense(alloc, row, L);
        defer alloc.free(q);
        var support: usize = 0;
        for (row, 0..) |c, bi| {
            if (c == 0) continue;
            support += 1;
            entropy_bits += f(c) * (f(L) - @log2(f(q[bi])));
        }
        table_bits += f(support) * (logK + f(L) / 2.0);
    }
    return .{ .entropy_bits = entropy_bits, .table_bits = table_bits };
}

/// Static (memoryless-transition) bucket/row model: `bucket_of[token]` (size
/// k) assigns every token a bucket in 0..num_buckets-1; `row_of_bucket[b]`
/// (size num_buckets) assigns every bucket a row in 0..num_rows-1, used as
/// the *context* for whatever follows it (this is exactly "next_row is a
/// pure function of the current bucket", i.e. the un-split automaton -- see
/// DESIGN.md's `next_row` cell). `start_row` is the context at the start of
/// every sequence (may or may not coincide with a real row; pass num_rows
/// for a dedicated START state, as Lane K does with its `C` sentinel).
pub fn evalStaticModel(
    alloc: std.mem.Allocator,
    seqs: *const Sequences,
    bucket_of: []const u32,
    width_of: []const u8,
    row_of_bucket: []const u32,
    num_buckets: usize,
    num_rows: usize,
    start_row: u32,
    g: []const u64,
    L: u32,
) !ModelCost {
    const n_states = num_rows + 1; // + START, at index num_rows (may equal start_row)
    const N = try buildBigramCounts(alloc, seqs, bucket_of, row_of_bucket, num_buckets, num_rows, start_row);
    defer alloc.free(N);

    const c = try costFromCounts(alloc, N, num_buckets, n_states, L);
    const entropy_bits = c.entropy_bits;
    const table_bits_extra = c.table_bits;
    const table_bits: f64 = f(num_buckets) * BUCKET_FLAT_BITS + table_bits_extra;

    var raw_bits: f64 = 0;
    for (g, 0..) |gx, x| {
        if (gx == 0) continue;
        raw_bits += f(gx) * f(width_of[bucket_of[x]]);
    }

    var total_tokens: usize = 0;
    for (g) |gx| total_tokens += gx;

    return .{
        .entropy_bits = entropy_bits,
        .raw_bits = raw_bits,
        .table_bits = table_bits,
        .exception_bits = 0,
        .total_bits = entropy_bits + raw_bits + table_bits,
        .tokens = total_tokens,
        .num_buckets = num_buckets,
        .num_rows = num_rows,
    };
}

// -------------------------------------------------------- DP bucketizer --
// Q1's answer to "group by count tiers vs DP over the count-sorted list with
// power-of-two sizes": given counts already sorted (caller's chosen order --
// we always use descending, most-frequent first, so a lone very-frequent
// token gets its own tiny bucket and the DP naturally grows bucket size
// toward the rare tail), choose contiguous groups whose sizes are powers of
// two (the last group of a run may be short, i.e. the bucket's slots are
// left partially empty -- DESIGN.md's "planner may leave slots empty").
// `overhead_bits` is the caller's current estimate of one bucket's own table
// cost (6 + L/2 + log2(K)); see f_bucket.zig for the fixed-point loop that
// converges log2(K) against the actual result.

pub const BucketAssignment = struct {
    bucket_id: []u32, // size n (position in the sorted-descending input) -> bucket id
    widths: []u8, // size num_buckets
    num_buckets: usize,
};

pub fn dpBucketize(alloc: std.mem.Allocator, counts_desc: []const u64, overhead_bits: f64) !BucketAssignment {
    const n = counts_desc.len;
    const prefix = try alloc.alloc(u64, n + 1);
    defer alloc.free(prefix);
    prefix[0] = 0;
    for (counts_desc, 0..) |c, i| prefix[i + 1] = prefix[i] + c;
    const total = prefix[n];

    var max_w: u6 = 0;
    while ((@as(usize, 1) << max_w) < n and max_w < 40) max_w += 1;

    const dp = try alloc.alloc(f64, n + 1);
    defer alloc.free(dp);
    const parent = try alloc.alloc(usize, n + 1);
    defer alloc.free(parent);
    const parent_w = try alloc.alloc(u6, n + 1);
    defer alloc.free(parent_w);
    @memset(dp, std.math.inf(f64));
    dp[0] = 0;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (!std.math.isFinite(dp[i])) continue;
        var w: u6 = 0;
        while (w <= max_w) : (w += 1) {
            const cap: usize = @as(usize, 1) << w;
            const s = @min(cap, n - i);
            if (s == 0) break;
            const nb = prefix[i + s] - prefix[i];
            var group_cost: f64 = 0;
            if (nb > 0) group_cost = f(nb) * (log2s(f(total) / f(nb)) + f(w));
            const cost = dp[i] + group_cost + overhead_bits;
            if (cost < dp[i + s]) {
                dp[i + s] = cost;
                parent[i + s] = i;
                parent_w[i + s] = w;
            }
            if (s < cap) break; // reached n early with a short final group
        }
    }

    // Reconstruct boundaries.
    var bounds: std.ArrayList(usize) = .empty;
    defer bounds.deinit(alloc);
    var widths_rev: std.ArrayList(u8) = .empty;
    defer widths_rev.deinit(alloc);
    var pos = n;
    try bounds.append(alloc, pos);
    while (pos > 0) {
        const p = parent[pos];
        const w = parent_w[pos];
        try widths_rev.append(alloc, w);
        pos = p;
        try bounds.append(alloc, pos);
    }
    std.mem.reverse(usize, bounds.items);
    std.mem.reverse(u8, widths_rev.items);
    const num_buckets = widths_rev.items.len;

    const bucket_id = try alloc.alloc(u32, n);
    for (0..num_buckets) |bidx| {
        const lo = bounds.items[bidx];
        const hi = bounds.items[bidx + 1];
        for (lo..hi) |pi| bucket_id[pi] = @intCast(bidx);
    }
    const widths = try alloc.alloc(u8, num_buckets);
    @memcpy(widths, widths_rev.items);

    return .{ .bucket_id = bucket_id, .widths = widths, .num_buckets = num_buckets };
}

/// DP bucketizer with a fixed-point loop on log2(K): the per-bucket
/// "identify within the row" cost depends on the final bucket count K, which
/// the DP itself determines, so we iterate a few rounds to converge (K
/// changes very little after round 1 in practice). Shared by every question
/// that needs "bucketize this population by count" (Q1 directly, Q2 per
/// class, Q3's initial bucket seed).
pub fn dpBucketizeConverged(alloc: std.mem.Allocator, counts_desc: []const u64, L: u32) !BucketAssignment {
    var log2k_guess: f64 = @log2(@max(f(counts_desc.len), 2.0)) / 2.0;
    var asg: BucketAssignment = .{ .bucket_id = &.{}, .widths = &.{}, .num_buckets = 0 };
    var round: usize = 0;
    while (round < 4) : (round += 1) {
        const overhead = BUCKET_FLAT_BITS + f(L) / 2.0 + log2k_guess;
        if (round > 0) {
            alloc.free(asg.bucket_id);
            alloc.free(asg.widths);
        }
        asg = try dpBucketize(alloc, counts_desc, overhead);
        log2k_guess = @log2(@max(f(asg.num_buckets), 1.0));
    }
    return asg;
}

/// Bisect the per-bucket overhead so `dpBucketize` lands close to
/// `target_buckets` (monotone: higher overhead -> fewer buckets). Used by
/// Q3 to seed a direct K-bucket induction at a specific K.
pub fn dpBucketizeForTarget(alloc: std.mem.Allocator, counts_desc: []const u64, target_buckets: usize) !BucketAssignment {
    var lo: f64 = -1.0e6;
    var hi: f64 = 4096.0;
    var best: ?BucketAssignment = null;
    var best_diff: usize = std.math.maxInt(usize);
    var iter: usize = 0;
    while (iter < 60) : (iter += 1) {
        const mid = (lo + hi) / 2.0;
        const asg = try dpBucketize(alloc, counts_desc, mid);
        const diff = if (asg.num_buckets > target_buckets) asg.num_buckets - target_buckets else target_buckets - asg.num_buckets;
        if (diff < best_diff) {
            best_diff = diff;
            if (best) |b| {
                alloc.free(b.bucket_id);
                alloc.free(b.widths);
            }
            best = asg;
        } else {
            alloc.free(asg.bucket_id);
            alloc.free(asg.widths);
        }
        if (asg.num_buckets > target_buckets) lo = mid else hi = mid;
    }
    return best.?;
}

// ------------------------------------------------------- tier-based seed --
// A frequency-homogeneous bucket seed for an arbitrary target bucket count:
// group by floor(log2 count) tiers (as Q1's "tier" method does), then
// binary-decompose each tier into a number of sub-buckets proportional to
// its population, so bigger tiers (which need finer within-tier resolution
// to stay homogeneous) get more of the budget. Every bucket stays entirely
// within one tier (so within-bucket counts differ by at most 2x), unlike a
// plain equal-rank-count seed which can lump very different frequencies
// into one bucket at the high-frequency end -- see LANE_F.md Q3 for why
// that matters (it was tried first and measurably worse).

/// Decompose `m` items into (as close as achievable to) `target_b`
/// power-of-two-sized groups, zero waste in both directions:
///   target_b <= popcount(m):  merge the smallest bits into one bucket
///                             (Q1's "binary decomposition into at most b
///                             buckets", b < unlimited).
///   target_b >  popcount(m):  start from the exact (popcount(m)-bucket)
///                             decomposition and greedily split the
///                             largest bucket in half (2^w -> 2x 2^(w-1),
///                             always exact, never introduces waste) until
///                             `target_b` is reached or every bucket is a
///                             singleton (the finest possible, m buckets).
fn decomposeSizesInto(alloc: std.mem.Allocator, m: usize, target_b: usize) ![]u8 {
    if (m == 0) return alloc.alloc(u8, 0);
    var bits: std.ArrayList(u6) = .empty;
    defer bits.deinit(alloc);
    var mm = m;
    var bit: u6 = 0;
    while (mm > 0) : (bit += 1) {
        if (mm & 1 == 1) try bits.append(alloc, bit);
        mm >>= 1;
    }
    std.mem.reverse(u6, bits.items); // descending
    if (bits.items.len >= target_b) {
        if (bits.items.len == target_b or target_b == 0) {
            const out = try alloc.alloc(u8, bits.items.len);
            for (bits.items, 0..) |bt, i| out[i] = bt;
            return out;
        }
        const keep = target_b - 1;
        var covered: usize = 0;
        for (bits.items[0..keep]) |bt| covered += @as(usize, 1) << bt;
        const remainder = m - covered;
        const out = try alloc.alloc(u8, target_b);
        for (bits.items[0..keep], 0..) |bt, i| out[i] = bt;
        out[keep] = @intFromFloat(bitsFor(remainder));
        return out;
    }
    // Refine: repeatedly split the current largest bucket in half.
    var list = try std.ArrayList(u6).initCapacity(alloc, target_b);
    defer list.deinit(alloc);
    for (bits.items) |bt| list.appendAssumeCapacity(bt);
    while (list.items.len < target_b) {
        var max_i: usize = 0;
        for (list.items, 0..) |w, i| {
            if (w > list.items[max_i]) max_i = i;
        }
        if (list.items[max_i] == 0) break; // fully singleton, can't refine further
        const w = list.items[max_i] - 1;
        list.items[max_i] = w;
        try list.append(alloc, w);
    }
    const out = try alloc.alloc(u8, list.items.len);
    for (list.items, 0..) |w, i| out[i] = w;
    return out;
}

pub fn tierSeedBuckets(alloc: std.mem.Allocator, counts_desc: []const u64, target_total_buckets: usize) !BucketAssignment {
    var bounds: std.ArrayList(usize) = .empty;
    defer bounds.deinit(alloc);
    try bounds.append(alloc, 0);
    var i: usize = 1;
    while (i < counts_desc.len) : (i += 1) {
        if (std.math.log2_int(u64, counts_desc[i]) != std.math.log2_int(u64, counts_desc[i - 1])) try bounds.append(alloc, i);
    }
    try bounds.append(alloc, counts_desc.len);
    const n = counts_desc.len;
    const bucket_id = try alloc.alloc(u32, n);
    var widths: std.ArrayList(u8) = .empty;
    var next_bucket: u32 = 0;
    for (0..bounds.items.len - 1) |ti| {
        const lo = bounds.items[ti];
        const hi = bounds.items[ti + 1];
        const m = hi - lo;
        const b_i = @max(1, (target_total_buckets * m + n / 2) / n);
        const sizes = try decomposeSizesInto(alloc, m, b_i);
        defer alloc.free(sizes);
        var order = try alloc.alloc(usize, sizes.len);
        defer alloc.free(order);
        for (0..sizes.len) |oi| order[oi] = oi;
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

// ------------------------------------------------------ sort-by-count utils --

// ------------------------------------------------- exchange-clustering --
// Generic "part-of-speech" class induction, reused (adapted, one-map only,
// no DAG inheritance -- Lane F's vocabulary is already a flat lexicon, not
// a rule DAG) from Lane K's `k_classes.zig` `learnClasses`/`evalCost`. Used
// directly for Q2's token classes and for Q3's coarser row-clustering of
// buckets (call it with the bucket ids as if they were "tokens").

const SMOOTH: f64 = 0.5;
const START_SENTINEL: u32 = std.math.maxInt(u32);

fn evalClassCost(C: u32, logT: []const f64, G: []const u64, pred_hist: []const u64, succ_hist: []const u64, self_count: u64, g_x: u64, cur: u32, c: u32) f64 {
    var cost: f64 = 0;
    for (0..C + 1) |p| {
        const w = pred_hist[p];
        if (w == 0) continue;
        cost -= f(w) * logT[p * C + c];
    }
    for (0..C) |s| {
        const w = succ_hist[s];
        if (w == 0) continue;
        cost -= f(w) * logT[c * C + s];
    }
    if (self_count > 0) cost -= f(self_count) * logT[c * C + c];
    const extra: f64 = if (c != cur) f(g_x) else 0.0;
    cost += f(g_x) * log2s(f(G[c]) + extra + SMOOTH);
    return cost;
}

pub const ClassLearn = struct {
    C: u32,
    sweeps: u32 = 8,
    candidate_cap: usize = 8000,
};

/// One-map exchange-clustering class induction over an arbitrary sequence
/// set. `k` = vocabulary size, `g` = occurrence counts (size k). Returns
/// `cls[]` (size k, values in 0..C-1) for every symbol -- symbols beyond the
/// frequency-ranked `candidate_cap` keep their frequency-rank initial class
/// (this is Lane K's "rarer tokens follow a cheap default" idea, minus the
/// DAG inheritance machinery Lane F's flat vocabulary doesn't need).
pub fn learnClassesOneMap(alloc: std.mem.Allocator, seqs: *const Sequences, k: usize, g: []const u64, params: ClassLearn) ![]u32 {
    const C = params.C;
    const ids_desc = try sortDescByCount(alloc, k, g);
    defer alloc.free(ids_desc);

    const cls = try alloc.alloc(u32, k);
    @memset(cls, 0);
    for (ids_desc, 0..) |id, rank| {
        const bucket: u32 = @intCast((rank * C) / @max(ids_desc.len, 1));
        cls[id] = @min(bucket, C - 1);
    }

    const n_cand = @min(ids_desc.len, params.candidate_cap);
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

    const N = try alloc.alloc(u64, (C + 1) * C);
    defer alloc.free(N);
    const G = try alloc.alloc(u64, C);
    defer alloc.free(G);
    const logT = try alloc.alloc(f64, (C + 1) * C);
    defer alloc.free(logT);
    const pred_hist = try alloc.alloc(u64, C + 1);
    defer alloc.free(pred_hist);
    const succ_hist = try alloc.alloc(u64, C);
    defer alloc.free(succ_hist);
    const next_cls = try alloc.alloc(u32, n_cand);
    defer alloc.free(next_cls);

    var sweep: u32 = 0;
    while (sweep < params.sweeps) : (sweep += 1) {
        @memset(N, 0);
        for (seqs.seqs) |s| {
            var ctx: u32 = C; // START row
            for (s) |x| {
                N[ctx * C + cls[x]] += 1;
                ctx = cls[x];
            }
        }
        @memset(G, 0);
        for (0..k) |x| G[cls[x]] += g[x];
        for (0..C + 1) |a| {
            var rowsum: f64 = 0;
            for (0..C) |c| rowsum += f(N[a * C + c]);
            const denom = rowsum + SMOOTH * f(C);
            for (0..C) |c| logT[a * C + c] = log2s((f(N[a * C + c]) + SMOOTH) / denom);
        }

        for (refine_list, 0..) |x, idx| {
            @memset(pred_hist, 0);
            @memset(succ_hist, 0);
            var it_p = pred_maps[idx].iterator();
            while (it_p.next()) |e| pred_hist[cls[e.key_ptr.*]] += e.value_ptr.*;
            var it_s = succ_maps[idx].iterator();
            while (it_s.next()) |e| succ_hist[cls[e.key_ptr.*]] += e.value_ptr.*;
            const cur = cls[x];
            const gx = g[x];

            var best_c = cur;
            var best_cost = evalClassCost(C, logT, G, pred_hist, succ_hist, self_count[idx], gx, cur, cur);
            for (0..C) |cc| {
                const c: u32 = @intCast(cc);
                if (c == cur) continue;
                const cost = evalClassCost(C, logT, G, pred_hist, succ_hist, self_count[idx], gx, cur, c);
                if (cost < best_cost) {
                    best_cost = cost;
                    best_c = c;
                }
            }
            next_cls[idx] = best_c;
        }
        for (refine_list, 0..) |x, idx| cls[x] = next_cls[idx];
    }

    return cls;
}

// ------------------------------------------------------- text (display) --
// Only used for the qualitative "are the sticky states meaningful" listing
// in LANE_F.md Q4b -- never in any cost computation. Copied/adapted from
// k_common.zig.

pub fn expandTruncated(alloc: std.mem.Allocator, dump: *const Dump, sym: u32, out: *std.ArrayList(u8), max_len: usize) !void {
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(alloc);
    try stack.append(alloc, sym);
    while (stack.items.len > 0 and out.items.len < max_len) {
        const top = stack.items[stack.items.len - 1];
        stack.items.len -= 1;
        if (top < 256) {
            try out.append(alloc, @intCast(top));
        } else {
            const kids = dump.children[top - 256];
            var i = kids.len;
            while (i > 0) {
                i -= 1;
                try stack.append(alloc, kids[i]);
            }
        }
    }
}

pub fn escapeForPrint(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (bytes) |b| {
        if (b == '\n') {
            try out.appendSlice(alloc, "\\n");
        } else if (b == '\t') {
            try out.appendSlice(alloc, "\\t");
        } else if (b == '\r') {
            try out.appendSlice(alloc, "\\r");
        } else if (b == '\\') {
            try out.appendSlice(alloc, "\\\\");
        } else if (b == '|') {
            try out.appendSlice(alloc, "\\|");
        } else if (b >= 0x20 and b <= 0x7e) {
            try out.append(alloc, b);
        } else {
            const hex = "0123456789abcdef";
            try out.appendSlice(alloc, "\\x");
            try out.append(alloc, hex[b >> 4]);
            try out.append(alloc, hex[b & 0xf]);
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn sortDescByCount(alloc: std.mem.Allocator, k: usize, g: []const u64) ![]u32 {
    var ids: std.ArrayList(u32) = .empty;
    for (0..k) |i| {
        if (g[i] > 0) try ids.append(alloc, @intCast(i));
    }
    const Ctx = struct {
        g: []const u64,
        fn lt(self: @This(), a: u32, b: u32) bool {
            if (self.g[a] != self.g[b]) return self.g[a] > self.g[b];
            return a < b;
        }
    };
    std.mem.sort(u32, ids.items, Ctx{ .g = g }, Ctx.lt);
    return ids.toOwnedSlice(alloc);
}
