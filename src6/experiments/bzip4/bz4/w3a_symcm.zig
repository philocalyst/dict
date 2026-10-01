//! w3a_symcm: Lane W3a's copy of Lane W's `symcm.zig`, extended with idea 2
//! ("contexts that only a symbol-level block sorter can have", see
//! LANE_W3A.md): TreeCM gains two new hashed mixer inputs derived from the
//! BWT's F column (idea 2a: hashed (node, F[i]) and hashed (node, first two
//! bytes of F[i]'s expansion)), a boundary flag `F[i] != F[i-1]` folded into
//! the mixer/SSE context (also 2a), and an exact "urn" order-0 input, the
//! zero-learning-cost remaining_right/remaining_total ratio from decrementing
//! the block's exact symbol histogram as symbols are consumed (idea 2b). All
//! four are OFF by default (`TreeCMConfig` flags default false) and, when
//! off or when the caller passes empty context arrays (no exact per-block
//! histogram/F column available -- true for every multi-block frame in this
//! lab; see LANE_W3A.md), TreeCM behaves byte-for-byte like `symcm.zig`'s.
//! ByteCM/GenericCM/AlphaTree/buildAlphaTree are unchanged copies.
//!
//! bz4 lab, Lane W3a (building on Lane W).
//!
//! Two coder families, dispatched on alphabet size:
//!
//!  - `ByteCM` (K == 256, i.e. k=0 in the lab: a pure-byte block, the
//!    fairest possible comparison against bzip3): a direct port of
//!    bzip3's entropy coder structure (libbz3.c `encode_bytes` /
//!    `decode_bytes`, read at ~lines 331-494) — an 8-bit context tree per
//!    byte, order-0 prediction C0[ctx] mixed with two order-1 predictions
//!    C1[prev][ctx] and C1[prev2][ctx] (weights 7:7:2 as in bzip3), then an
//!    SSE/APM stage C2[2*ctx+run_flag][16 buckets] recalibrating the
//!    mixed probability, blended 3:1 against the raw mix. Same adaptation
//!    rates (2, 4, 6, 6) as bzip3. Reimplemented against rc.zig's raw
//!    `encodeBitProb`/`decodeBitProb` (12-bit probabilities) rather than
//!    bzip3's own coder, so the numbers plug into the shared bz4 range
//!    coder like every other lane's.
//!
//!  - `GenericCM` (K > 256, the partial-grammar root alphabet, up to
//!    ~2^20): a recency cache (MTF array, N=16) with hit/miss coded as an
//!    adaptive bit under context (last 3 hit/miss outcomes, whether the
//!    previous symbol resolved to rank 0), rank-on-hit coded by a 4-bit
//!    tree under context of the previous rank bucket, and miss symbols
//!    coded by a Fenwick-tree adaptive frequency model over all K symbols
//!    (uniform prior of 1, no exclusion, additive increment on every
//!    symbol whether it was a hit or a miss — see LANE_W.md for why).
//!
//! Both are real, symmetric encoders/decoders: `encode` produces the byte
//! stream `decode` consumes, verified via roundtrip tests here and via
//! byte-exact full-pipeline checks in bwtlab.zig.

const std = @import("std");
const rc = @import("rc.zig");

// ============================================================ ByteCM ===

pub const ByteCM = struct {
    c0: [256]u16 = undefined,
    c1: []u16, // [prevByte*256 + ctx], 256*256
    c2: []u16, // [(2*ctx+run_flag)*17 + bucket], 512*17
    prev1: u8 = 0,
    prev2: u8 = 0,
    run: u32 = 0,
    decisions: u64 = 0,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !ByteCM {
        var self: ByteCM = .{
            .alloc = alloc,
            .c1 = try alloc.alloc(u16, 256 * 256),
            .c2 = try alloc.alloc(u16, 512 * 17),
        };
        @memset(&self.c0, 1 << 15);
        @memset(self.c1, 1 << 15);
        for (0..512) |j| {
            for (0..17) |k| {
                const v: i32 = @as(i32, @intCast(k)) << 12;
                self.c2[j * 17 + k] = @intCast(v - @as(i32, if (k == 16) 1 else 0));
            }
        }
        return self;
    }

    pub fn deinit(self: *ByteCM) void {
        self.alloc.free(self.c1);
        self.alloc.free(self.c2);
    }

    inline fn upd0(p: *u16, comptime rate: u4) void {
        p.* = p.* - (p.* >> rate);
    }
    inline fn upd1(p: *u16, comptime rate: u4) void {
        p.* = p.* +% ((p.* ^ 0xFFFF) >> rate);
    }

    const Mix = struct { node0: *u16, node1a: *u16, node1b: *u16, x1: *u16, x2: *u16, p0_of_one: u16 };

    /// Compute the mixed+SSE probability that the current bit is 1 (16-bit
    /// scale), and hand back pointers to every counter so the caller can
    /// update them once the true bit is known.
    inline fn predict(self: *ByteCM, ctx: usize) Mix {
        const p0 = self.c0[ctx];
        const p1 = self.c1[@as(usize, self.prev1) * 256 + ctx];
        const p2 = self.c1[@as(usize, self.prev2) * 256 + ctx];
        const mix: u32 = (@as(u32, p0) + p1) * 7 + @as(u32, p2) * 2;
        const pf: u16 = @intCast(mix >> 4);
        const f: u1 = @intFromBool(self.run > 2);
        const base_idx = (@as(usize, 2) * ctx + f) * 17;
        const j = pf >> 12;
        const x1p = &self.c2[base_idx + j];
        const x2p = &self.c2[base_idx + j + 1];
        const x1: i32 = x1p.*;
        const x2: i32 = x2p.*;
        // Signed interpolation: bzip3 uses plain (possibly negative) `int`
        // arithmetic here since adjacent SSE buckets need not be monotone.
        const delta: i32 = x2 - x1;
        const ssep: i32 = x1 + ((delta * @as(i32, pf & 4095)) >> 12);
        const blended_signed: i32 = (ssep * 3 + @as(i32, pf)) >> 2; // rescale 18-bit weight to 16-bit prob
        const blended: u32 = @intCast(std.math.clamp(blended_signed, 0, 65535));
        return .{
            .node0 = &self.c0[ctx],
            .node1a = &self.c1[@as(usize, self.prev1) * 256 + ctx],
            .node1b = &self.c1[@as(usize, self.prev2) * 256 + ctx],
            .x1 = x1p,
            .x2 = x2p,
            .p0_of_one = @intCast(@min(blended, 65535)),
        };
    }

    inline fn update(m: Mix, bit: u1) void {
        if (bit == 1) {
            upd1(m.node0, 2);
            upd1(m.node1a, 4);
            upd1(m.node1b, 4);
            upd1(m.x1, 6);
            upd1(m.x2, 6);
        } else {
            upd0(m.node0, 2);
            upd0(m.node1a, 4);
            upd0(m.node1b, 4);
            upd0(m.x1, 6);
            upd0(m.x2, 6);
        }
    }

    inline fn toP0(p_of_one: u16) u16 {
        const p0_16: u32 = 65536 - @as(u32, p_of_one);
        var p12: u32 = p0_16 >> 4;
        if (p12 < 1) p12 = 1;
        if (p12 > 4095) p12 = 4095;
        return @intCast(p12);
    }

    pub fn encodeByte(self: *ByteCM, enc: *rc.Encoder, c: u8) !void {
        if (self.prev1 == self.prev2) self.run += 1 else self.run = 0;
        var ctx: usize = 1;
        var shift: u3 = 7;
        while (true) {
            const bit: u1 = @intCast((c >> shift) & 1);
            const m = self.predict(ctx);
            try enc.encodeBitProb(toP0(m.p0_of_one), bit);
            update(m, bit);
            self.decisions += 1;
            ctx = ctx * 2 + bit;
            if (shift == 0) break;
            shift -= 1;
        }
        self.prev2 = self.prev1;
        self.prev1 = c;
    }

    pub fn decodeByte(self: *ByteCM, dec: *rc.Decoder) u8 {
        if (self.prev1 == self.prev2) self.run += 1 else self.run = 0;
        var ctx: usize = 1;
        while (ctx < 256) {
            const m = self.predict(ctx);
            const bit = dec.decodeBitProb(toP0(m.p0_of_one));
            update(m, bit);
            self.decisions += 1;
            ctx = ctx * 2 + bit;
        }
        const c: u8 = @intCast(ctx & 255);
        self.prev2 = self.prev1;
        self.prev1 = c;
        return c;
    }
};

pub fn encodeBytes(alloc: std.mem.Allocator, syms: []const u32) ![]const u8 {
    var cm = try ByteCM.init(alloc);
    defer cm.deinit();
    var enc = rc.Encoder.init(alloc);
    defer enc.deinit();
    for (syms) |s| try cm.encodeByte(&enc, @intCast(s));
    // finish() returns a slice borrowed from enc's ArrayList (len <=
    // capacity); dupe to an exactly-sized allocation the caller can own
    // and free independently of `enc`.
    return alloc.dupe(u8, try enc.finish());
}

pub fn decodeBytes(alloc: std.mem.Allocator, bytes: []const u8, n: usize) ![]u32 {
    var cm = try ByteCM.init(alloc);
    defer cm.deinit();
    var dec = rc.Decoder.init(bytes);
    const out = try alloc.alloc(u32, n);
    errdefer alloc.free(out);
    for (out) |*s| s.* = cm.decodeByte(&dec);
    return out;
}

pub const Counted = struct { bytes: []const u8, decisions: u64 };
pub const CountedSyms = struct { syms: []u32, decisions: u64 };

/// Same as `encodeBytes`, but also reports the number of binary
/// range-coder decisions made (always exactly 8 per byte for `ByteCM`;
/// exposed for a uniform "decisions per byte" column across coders).
pub fn encodeBytesCounted(alloc: std.mem.Allocator, syms: []const u32) !Counted {
    var cm = try ByteCM.init(alloc);
    defer cm.deinit();
    var enc = rc.Encoder.init(alloc);
    defer enc.deinit();
    for (syms) |s| try cm.encodeByte(&enc, @intCast(s));
    return .{ .bytes = try alloc.dupe(u8, try enc.finish()), .decisions = cm.decisions };
}

pub fn decodeBytesCounted(alloc: std.mem.Allocator, bytes: []const u8, n: usize) !CountedSyms {
    var cm = try ByteCM.init(alloc);
    defer cm.deinit();
    var dec = rc.Decoder.init(bytes);
    const out = try alloc.alloc(u32, n);
    errdefer alloc.free(out);
    for (out) |*s| s.* = cm.decodeByte(&dec);
    return .{ .syms = out, .decisions = cm.decisions };
}

// ========================================================= GenericCM ===

const cache_size = 16; // fits exactly in a 4-bit rank tree
const rank_bits = 4;
const rank_buckets = 6; // rank 0,1,2,3,4+ , and "previous was a miss"
const miss_bucket = 5;
const fenwick_increment: u32 = 24;

const Fenwick = struct {
    tree: []u32,
    n: usize,
    total: u64 = 0,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator, n: usize) !Fenwick {
        const tree = try alloc.alloc(u32, n + 1);
        @memset(tree, 0);
        var self = Fenwick{ .tree = tree, .n = n, .alloc = alloc };
        for (0..n) |i| self.add(i, 1);
        return self;
    }

    fn deinit(self: *Fenwick) void {
        self.alloc.free(self.tree);
    }

    fn add(self: *Fenwick, six: usize, delta: u32) void {
        self.total += delta;
        var idx = six + 1;
        while (idx <= self.n) : (idx += idx & (~idx +% 1)) {
            self.tree[idx] += delta;
        }
    }

    /// Sum of freq[0..six] inclusive.
    fn prefixSum(self: *const Fenwick, six: usize) u32 {
        var idx = six + 1;
        var s: u32 = 0;
        while (idx > 0) : (idx -= idx & (~idx +% 1)) s += self.tree[idx];
        return s;
    }

    fn cumBelow(self: *const Fenwick, six: usize) u32 {
        if (six == 0) return 0;
        return self.prefixSum(six - 1);
    }

    fn freqAt(self: *const Fenwick, six: usize) u32 {
        return self.prefixSum(six) - self.cumBelow(six);
    }

    /// Smallest index six such that cumBelow(six+1) > target, i.e. the symbol
    /// whose half-open [cum,cum+freq) interval contains `target`.
    fn findByCum(self: *const Fenwick, target: u32) usize {
        var idx: usize = 0;
        var rem = target;
        var pw: usize = 1;
        while (pw << 1 <= self.n) pw <<= 1;
        while (pw > 0) : (pw >>= 1) {
            const nxt = idx + pw;
            if (nxt <= self.n and self.tree[nxt] <= rem) {
                idx = nxt;
                rem -= self.tree[nxt];
            }
        }
        return idx; // 0-indexed symbol
    }
};

const Recency = struct {
    items: [cache_size]u32 = [_]u32{std.math.maxInt(u32)} ** cache_size,
    len: u8 = 0,

    fn rankOf(self: *const Recency, sym: u32) ?u8 {
        for (self.items[0..self.len], 0..) |v, i| {
            if (v == sym) return @intCast(i);
        }
        return null;
    }

    fn touch(self: *Recency, rank: u8) void {
        const v = self.items[rank];
        var i = rank;
        while (i > 0) : (i -= 1) self.items[i] = self.items[i - 1];
        self.items[0] = v;
    }

    fn insertNew(self: *Recency, sym: u32) void {
        const top: u8 = if (self.len < cache_size) self.len else cache_size - 1;
        var i = top;
        while (i > 0) : (i -= 1) self.items[i] = self.items[i - 1];
        self.items[0] = sym;
        if (self.len < cache_size) self.len += 1;
    }
};

fn encodeTree(enc: *rc.Encoder, models: []rc.Bit, value: u32, comptime nbits: u5) !void {
    var node: u32 = 1;
    var i: u5 = nbits;
    while (i > 0) {
        i -= 1;
        const bit: u1 = @intCast((value >> i) & 1);
        try enc.encodeBit(&models[node], bit, 5);
        node = node * 2 + bit;
    }
}

fn decodeTree(dec: *rc.Decoder, models: []rc.Bit, comptime nbits: u5) u32 {
    var node: u32 = 1;
    var i: u5 = 0;
    while (i < nbits) : (i += 1) {
        const bit = dec.decodeBit(&models[node], 5);
        node = node * 2 + bit;
    }
    return node - (@as(u32, 1) << nbits);
}

pub const GenericCM = struct {
    fen: Fenwick,
    cache: Recency = .{},
    hitmiss: [16]rc.Bit = [_]rc.Bit{.{}} ** 16,
    rank_models: [rank_buckets][1 << rank_bits]rc.Bit = [_][1 << rank_bits]rc.Bit{[_]rc.Bit{.{}} ** (1 << rank_bits)} ** rank_buckets,
    hist: u3 = 0,
    prev_bucket: u3 = miss_bucket,
    decisions: u64 = 0, // 1 (hit/miss) + rank_bits on hit; 1 (hit/miss) + 1 (the single encodeFreq call) on miss

    pub fn init(alloc: std.mem.Allocator, k: usize) !GenericCM {
        return .{ .fen = try Fenwick.init(alloc, k) };
    }

    pub fn deinit(self: *GenericCM) void {
        self.fen.deinit();
    }

    inline fn hitmissCtx(self: *const GenericCM) usize {
        return (@as(usize, self.hist) << 1) | @intFromBool(self.prev_bucket == 0);
    }

    pub fn encodeSymbol(self: *GenericCM, enc: *rc.Encoder, sym: u32) !void {
        const ctx = self.hitmissCtx();
        const rank_opt = self.cache.rankOf(sym);
        self.decisions += 1;
        if (rank_opt) |rank| {
            try enc.encodeBit(&self.hitmiss[ctx], 0, 5);
            try encodeTree(enc, &self.rank_models[self.prev_bucket], rank, rank_bits);
            self.decisions += rank_bits;
            self.cache.touch(rank);
            self.hist = (self.hist << 1) | 1;
            self.prev_bucket = @min(rank, 4);
        } else {
            try enc.encodeBit(&self.hitmiss[ctx], 1, 5);
            const cum = self.fen.cumBelow(sym);
            const f = self.fen.freqAt(sym);
            try enc.encodeFreq(cum, f, @intCast(self.fen.total));
            self.decisions += 1;
            self.cache.insertNew(sym);
            self.hist = (self.hist << 1);
            self.prev_bucket = miss_bucket;
        }
        self.fen.add(sym, fenwick_increment);
    }

    pub fn decodeSymbol(self: *GenericCM, dec: *rc.Decoder) u32 {
        const ctx = self.hitmissCtx();
        const bit = dec.decodeBit(&self.hitmiss[ctx], 5);
        self.decisions += 1;
        var sym: u32 = undefined;
        if (bit == 0) {
            const rank = decodeTree(dec, &self.rank_models[self.prev_bucket], rank_bits);
            self.decisions += rank_bits;
            sym = self.cache.items[rank];
            self.cache.touch(@intCast(rank));
            self.hist = (self.hist << 1) | 1;
            self.prev_bucket = @intCast(@min(rank, 4));
        } else {
            const target = dec.decodeFreq(@intCast(self.fen.total));
            sym = @intCast(self.fen.findByCum(target));
            const cum = self.fen.cumBelow(sym);
            const f = self.fen.freqAt(sym);
            dec.consume(cum, f);
            self.decisions += 1;
            self.cache.insertNew(sym);
            self.hist = (self.hist << 1);
            self.prev_bucket = miss_bucket;
        }
        self.fen.add(sym, fenwick_increment);
        return sym;
    }
};

pub fn encodeSymbols(alloc: std.mem.Allocator, syms: []const u32, k_alphabet: usize) ![]const u8 {
    if (k_alphabet == 256) return encodeBytes(alloc, syms);
    var cm = try GenericCM.init(alloc, k_alphabet);
    defer cm.deinit();
    var enc = rc.Encoder.init(alloc);
    defer enc.deinit();
    for (syms) |s| try cm.encodeSymbol(&enc, s);
    return alloc.dupe(u8, try enc.finish());
}

pub fn decodeSymbols(alloc: std.mem.Allocator, bytes: []const u8, n: usize, k_alphabet: usize) ![]u32 {
    if (k_alphabet == 256) return decodeBytes(alloc, bytes, n);
    var cm = try GenericCM.init(alloc, k_alphabet);
    defer cm.deinit();
    var dec = rc.Decoder.init(bytes);
    const out = try alloc.alloc(u32, n);
    errdefer alloc.free(out);
    for (out) |*s| s.* = cm.decodeSymbol(&dec);
    return out;
}

/// Same as `encodeSymbols`/`decodeSymbols` but also reports the number of
/// binary range-coder decisions made (see `GenericCM.decisions` for what
/// counts as one — it undercounts misses relative to a true bit-tree, since
/// a miss is coded as a single multi-symbol `encodeFreq` call, not several
/// binary ones; still a real, comparable "decoder steps taken" count).
pub fn encodeSymbolsCounted(alloc: std.mem.Allocator, syms: []const u32, k_alphabet: usize) !Counted {
    if (k_alphabet == 256) return encodeBytesCounted(alloc, syms);
    var cm = try GenericCM.init(alloc, k_alphabet);
    defer cm.deinit();
    var enc = rc.Encoder.init(alloc);
    defer enc.deinit();
    for (syms) |s| try cm.encodeSymbol(&enc, s);
    return .{ .bytes = try alloc.dupe(u8, try enc.finish()), .decisions = cm.decisions };
}

pub fn decodeSymbolsCounted(alloc: std.mem.Allocator, bytes: []const u8, n: usize, k_alphabet: usize) !CountedSyms {
    if (k_alphabet == 256) return decodeBytesCounted(alloc, bytes, n);
    var cm = try GenericCM.init(alloc, k_alphabet);
    defer cm.deinit();
    var dec = rc.Decoder.init(bytes);
    const out = try alloc.alloc(u32, n);
    errdefer alloc.free(out);
    for (out) |*s| s.* = cm.decodeSymbol(&dec);
    return .{ .syms = out, .decisions = cm.decisions };
}

// ============================================================ TreeCM ===
// Round 2 (lead's diagnosis): GenericCM shares no statistics between
// related symbols and has no hierarchical order-1/2/SSE modelling the way
// ByteCM does for bytes. TreeCM fixes that by building a weight-balanced
// *alphabetic* binary tree over the symbols — leaves appear left-to-right
// in a fixed external order (rev_rank, computed by the caller from each
// symbol's *reversed* byte expansion, so symbols ending in the same bytes
// become tree neighbours) — then generalises the ByteCM machinery
// (order-0 + two hashed order-1 contexts, fixed or logistic mixing, SSE)
// to run at every internal node of that tree instead of the fixed 255-node
// byte tree. A symbol costs ~depth (≈ -log2 p + O(1) for a weight-balanced
// alphabetic tree) binary decisions instead of ByteCM's fixed 8.

/// One internal node of the alphabetic tree. `left`/`right` are tagged:
/// a value < `k_leaves` is a leaf at that rank position (symbol =
/// order[value]); a value >= `k_leaves` is another internal node at index
/// (value - k_leaves). `mid` is the absolute rank-position split point
/// (ranks in [lo,mid) go left, [mid,hi) go right) — storing the absolute
/// threshold means traversal never needs the node's own [lo,hi) range.
pub const TreeNode = struct { mid: u32, left: u32, right: u32 };

pub const AlphaTree = struct {
    nodes: []TreeNode, // K-1 internal nodes (empty if k_leaves <= 1)
    prime: []u16, // parallel to nodes: P(bit=1) implied by the split's weights, 16-bit
    root: u32, // tag: internal (>= k_leaves) unless k_leaves <= 1
    k_leaves: u32,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *AlphaTree) void {
        self.alloc.free(self.nodes);
        self.alloc.free(self.prime);
    }
};

fn buildTreeRange(
    alloc: std.mem.Allocator,
    cum: []const u64,
    nodes: *std.ArrayList(TreeNode),
    prime: *std.ArrayList(u16),
    k_leaves: u32,
    lo: u32,
    hi: u32,
) !u32 {
    if (hi - lo == 1) return lo; // leaf tag: always < k_leaves
    const target = cum[lo] + (cum[hi] - cum[lo]) / 2;
    var left: u32 = lo + 1;
    var right: u32 = hi; // search m in [lo+1, hi-1], lower_bound style
    while (left < right) {
        const mid = left + (right - left) / 2;
        if (cum[mid] < target) left = mid + 1 else right = mid;
    }
    var m = left;
    if (m < lo + 1) m = lo + 1;
    if (m > hi - 1) m = hi - 1;
    const left_id = try buildTreeRange(alloc, cum, nodes, prime, k_leaves, lo, m);
    const right_id = try buildTreeRange(alloc, cum, nodes, prime, k_leaves, m, hi);
    const total_w = cum[hi] - cum[lo];
    const right_w = cum[hi] - cum[m];
    const p_right: u64 = if (total_w == 0) 32768 else (right_w * 65536) / total_w;
    const idx: u32 = @intCast(nodes.items.len);
    try nodes.append(alloc, .{ .mid = m, .left = left_id, .right = right_id });
    try prime.append(alloc, @intCast(std.math.clamp(p_right, 1, 65535)));
    return k_leaves + idx; // internal tag: always >= k_leaves
}

/// `order[r]` = symbol at rank r (the tree's fixed leaf order, e.g. by
/// reversed-expansion lexicographic order); `weight_by_symbol[s]` = that
/// symbol's weight (the plan's g[s]+1). Both must be known to the decoder
/// without any extra bytes (derived from the shared grammar + counts).
pub fn buildAlphaTree(alloc: std.mem.Allocator, order: []const u32, weight_by_symbol: []const u32) !AlphaTree {
    const k_leaves: u32 = @intCast(order.len);
    if (k_leaves <= 1) {
        return .{ .nodes = try alloc.alloc(TreeNode, 0), .prime = try alloc.alloc(u16, 0), .root = 0, .k_leaves = k_leaves, .alloc = alloc };
    }
    const cum = try alloc.alloc(u64, k_leaves + 1);
    defer alloc.free(cum);
    cum[0] = 0;
    for (order, 0..) |sym, i| cum[i + 1] = cum[i] + weight_by_symbol[sym];

    var nodes: std.ArrayList(TreeNode) = .empty;
    var prime: std.ArrayList(u16) = .empty;
    const root = try buildTreeRange(alloc, cum, &nodes, &prime, k_leaves, 0, k_leaves);
    return .{ .nodes = try nodes.toOwnedSlice(alloc), .prime = try prime.toOwnedSlice(alloc), .root = root, .k_leaves = k_leaves, .alloc = alloc };
}

pub const TreeCMConfig = struct {
    use_run_shortcut: bool = true,
    use_logistic: bool = true,
    use_sse: bool = true,
    hash_bits: u5 = 20,
    // Idea 2a: hashed (node, F[i]) input, keyed on the BWT's F column (the
    // symbol that FOLLOWS L[i] in the text -- known exactly, before L is
    // decoded, whenever the block's exact symbol histogram is known; see
    // `deriveFctx` in w3a_bwtlab.zig). No-op unless the caller also passes
    // a non-empty `fctx_sym` to `init`.
    use_fctx: bool = false,
    // Idea 2a: hashed (node, first two bytes of F[i]'s expansion) input --
    // shares statistics between different following phrases that start
    // alike. No-op unless `fctx_sym`/`sym_byte01` are both non-empty.
    use_fctx_bytes: bool = false,
    // Idea 2a: fold the known context boundary "F[i] != F[i-1]" into the
    // mixer-weight-set / SSE selector (doubles both). No-op unless
    // `fctx_sym` is non-empty.
    use_boundary_ctx: bool = false,
    // Idea 2b: exact "urn" order-0 input -- remaining_right/remaining_total
    // from decrementing the block's exact symbol histogram as symbols are
    // consumed; zero learning cost since it needs no adaptation, only the
    // mixer weight on it adapts. No-op unless `urn_init_counts` is non-empty.
    use_urn: bool = false,
};

/// Sentinel F-value meaning "this row's F is the BWT's virtual sentinel",
/// i.e. this L position is the true end of the block (see w3a_bwtlab.zig's
/// `deriveFctx` doc comment for the derivation). Never a valid symbol id
/// (k_alphabet is always far below this in every corpus in this lab).
pub const f_end: u32 = std.math.maxInt(u32);

const debug_trace = false; // flip for local debugging of a TreeCM desync
const n_depth_buckets = 16;
// depth bucket x run flag x boundary flag (boundary bit is forced 0, i.e.
// only the first half of this dimension is ever touched, when disabled or
// unavailable -- kept as a fixed comptime size so enabling it costs no
// restructuring, only some always-idle table rows).
const mix_ctx_count = n_depth_buckets * 2 * 2;
const n_inputs = 6; // p0 (primed order-0), p1, p2 (hashed order-1/2),
// p3 (idea 2a: hashed node+F), p4 (idea 2a: hashed node+F-expansion-bytes),
// p5 (idea 2b: exact urn, no adaptive state of its own)

fn stretchU16(p: u16) f32 {
    var pf: f32 = @as(f32, @floatFromInt(p)) / 65536.0;
    if (pf < 0.0001) pf = 0.0001;
    if (pf > 0.9999) pf = 0.9999;
    return @log(pf / (1.0 - pf));
}

fn squashToU16(x: f32) u16 {
    const xc = std.math.clamp(x, -30.0, 30.0);
    const p = 1.0 / (1.0 + @exp(-xc));
    const v: i32 = @intFromFloat(p * 65536.0);
    return @intCast(std.math.clamp(v, 1, 65535));
}

fn hashCtx(v: u32, ctx: u32) u32 {
    const h = (@as(u64, v) *% 0x9E3779B97F4A7C15) ^ (@as(u64, ctx +% 1) *% 0xC2B2AE3D27D4EB4F);
    return @truncate(h >> 32);
}

/// Minimal Fenwick/BIT over the leaf-RANK domain (same domain as the
/// AlphaTree's `mid` thresholds), i64-valued so point decrements are exact
/// with no wraparound subtleties. Used only for idea 2b's exact urn: seeded
/// once from the block's real histogram (in rank order), then decremented
/// by 1 at the consumed symbol's rank after every encode/decodeSymbol call
/// (on every path, including the run-shortcut, so encoder and decoder never
/// diverge on "remaining counts").
const UrnBit = struct {
    tree: []i64,
    n: usize,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator, n: usize) !UrnBit {
        const tree = try alloc.alloc(i64, n);
        @memset(tree, 0);
        return .{ .tree = tree, .n = n, .alloc = alloc };
    }

    fn deinit(self: *UrnBit) void {
        self.alloc.free(self.tree);
    }

    fn add(self: *UrnBit, pos0: usize, delta: i64) void {
        if (delta == 0) return;
        var i = pos0 + 1;
        while (i <= self.n) : (i += i & (~i +% 1)) self.tree[i - 1] += delta;
    }

    /// Sum of elements in [0, pos0) (exclusive of pos0).
    fn prefixSum(self: *const UrnBit, pos0: usize) i64 {
        var i = pos0;
        var s: i64 = 0;
        while (i > 0) : (i -= i & (~i +% 1)) s += self.tree[i - 1];
        return s;
    }

    fn buildFromCounts(alloc: std.mem.Allocator, counts: []const u32) !UrnBit {
        var self = try UrnBit.init(alloc, counts.len);
        for (counts, 0..) |c, i| {
            if (c != 0) self.add(i, @intCast(c));
        }
        return self;
    }
};

pub const TreeCM = struct {
    tree: *const AlphaTree, // borrowed, shared across all blocks
    order: []const u32, // borrowed: rank -> symbol (== tree leaf order)
    rev_rank: []const u32, // borrowed: symbol -> rank

    p0: []u16, // owned copy of tree.prime, adapts per block
    p1_table: []u16,
    p2_table: []u16,
    p3_table: []u16, // idea 2a: hashed (node, F[i])
    p4_table: []u16, // idea 2a: hashed (node, F[i] first two expansion bytes)
    hash_mask: u32,
    sse: []u16, // [mix_ctx][17]
    mixw: [mix_ctx_count][n_inputs]f32,
    run_bit: [16]rc.Bit = [_]rc.Bit{.{}} ** 16,

    // Idea 2a inputs (borrowed; empty slices mean "unavailable", e.g. every
    // multi-block frame in this lab -- see w3a_bwtlab.zig). `fctx_sym` is
    // position-indexed (aligned to the order encodeSymbol/decodeSymbol are
    // called in, i.e. the block's L/root order), values are original symbol
    // ids or `f_end`. `sym_byte01` is ORIGINAL-symbol-id indexed, holding
    // that symbol's first two expansion bytes widened to u16 with 256
    // meaning "no such byte" (expansion shorter than 2 bytes).
    fctx_sym: []const u32 = &.{},
    sym_byte01: []const [2]u16 = &.{},
    pos: usize = 0,

    // Idea 2b: exact urn, seeded from the block's real histogram in rank
    // order; null when unavailable/disabled.
    urn: ?UrnBit = null,

    prev1: u32,
    prev2: u32,
    run_len: u32 = 0,
    prev_hit: bool = false,
    decisions: u64 = 0,

    cfg: TreeCMConfig,
    alloc: std.mem.Allocator,

    pub fn init(
        alloc: std.mem.Allocator,
        tree: *const AlphaTree,
        order: []const u32,
        rev_rank: []const u32,
        cfg: TreeCMConfig,
        fctx_sym: []const u32,
        sym_byte01: []const [2]u16,
        urn_init_counts: []const u32,
    ) !TreeCM {
        const hash_size: usize = @as(usize, 1) << cfg.hash_bits;
        var self: TreeCM = .{
            .tree = tree,
            .order = order,
            .rev_rank = rev_rank,
            .p0 = try alloc.dupe(u16, tree.prime),
            .p1_table = try alloc.alloc(u16, hash_size),
            .p2_table = try alloc.alloc(u16, hash_size),
            .p3_table = try alloc.alloc(u16, hash_size),
            .p4_table = try alloc.alloc(u16, hash_size),
            .hash_mask = @intCast(hash_size - 1),
            .sse = try alloc.alloc(u16, mix_ctx_count * 17),
            .mixw = [_][n_inputs]f32{.{ 0.35, 0.35, 0.15, 0.0, 0.0, 0.0 }} ** mix_ctx_count,
            .fctx_sym = fctx_sym,
            .sym_byte01 = sym_byte01,
            .urn = if (cfg.use_urn and urn_init_counts.len != 0) try UrnBit.buildFromCounts(alloc, urn_init_counts) else null,
            .prev1 = tree.k_leaves, // sentinel: out of valid symbol range
            .prev2 = tree.k_leaves,
            .cfg = cfg,
            .alloc = alloc,
        };
        @memset(self.p1_table, 1 << 15);
        @memset(self.p2_table, 1 << 15);
        @memset(self.p3_table, 1 << 15);
        @memset(self.p4_table, 1 << 15);
        for (0..mix_ctx_count) |j| {
            for (0..17) |kk| {
                const v: i32 = @as(i32, @intCast(kk)) << 12;
                self.sse[j * 17 + kk] = @intCast(v - @as(i32, if (kk == 16) 1 else 0));
            }
        }
        return self;
    }

    pub fn deinit(self: *TreeCM) void {
        self.alloc.free(self.p0);
        self.alloc.free(self.p1_table);
        self.alloc.free(self.p2_table);
        self.alloc.free(self.p3_table);
        self.alloc.free(self.p4_table);
        self.alloc.free(self.sse);
        if (self.urn) |*u| u.deinit();
    }

    inline fn runCtx(self: *const TreeCM) usize {
        const bucket: usize = @min(self.run_len, 7);
        return bucket * 2 + @intFromBool(self.prev_hit);
    }

    /// This symbol's F-derived quantities, constant across every node
    /// visited while coding it (only `node_idx` varies per node). Computed
    /// once per encode/decodeSymbol call. `have_f` is false whenever no
    /// F column was supplied (empty `fctx_sym`) -- the common case for
    /// every multi-block frame in this lab.
    const FInfo = struct {
        have_f: bool,
        f_key: u32,
        byte_key: u32,
        boundary: bool,
    };

    fn fInfoAt(self: *const TreeCM) FInfo {
        if (self.fctx_sym.len == 0) return .{ .have_f = false, .f_key = 0, .byte_key = 0, .boundary = false };
        const f = self.fctx_sym[self.pos];
        const b0: u32 = if (f == f_end or self.sym_byte01.len == 0) 256 else self.sym_byte01[f][0];
        const b1: u32 = if (f == f_end or self.sym_byte01.len == 0) 256 else self.sym_byte01[f][1];
        const byte_key = b0 * 257 + b1;
        const boundary = self.pos == 0 or f != self.fctx_sym[self.pos - 1];
        return .{ .have_f = true, .f_key = f, .byte_key = byte_key, .boundary = boundary };
    }

    const NodePred = struct {
        node_idx: u32,
        slots: [n_inputs]?*u16, // null where there is no adaptive table (p0 uses self.p0 directly; urn has none)
        mix_ctx: usize,
        st: [n_inputs]f32,
        pre_sse_of_one: u16,
        sse_x1: ?*u16,
        sse_x2: ?*u16,
        p_final_of_one: u16,
    };

    fn predictNode(self: *TreeCM, node_idx: u32, depth: u32, lo: u32, hi: u32, finfo: FInfo) NodePred {
        const p0v = self.p0[node_idx];
        const h1 = hashCtx(node_idx, self.prev1) & self.hash_mask;
        const h2 = hashCtx(node_idx, self.prev2) & self.hash_mask;
        const p1_slot = &self.p1_table[h1];
        const p2_slot = &self.p2_table[h2];
        const p1v = p1_slot.*;
        const p2v = p2_slot.*;

        const use_f3 = self.cfg.use_fctx and finfo.have_f;
        const use_f4 = self.cfg.use_fctx_bytes and finfo.have_f;
        var p3_slot: ?*u16 = null;
        var p4_slot: ?*u16 = null;
        var p3v: u16 = 1 << 15;
        var p4v: u16 = 1 << 15;
        if (use_f3) {
            const h3 = hashCtx(node_idx, finfo.f_key) & self.hash_mask;
            p3_slot = &self.p3_table[h3];
            p3v = p3_slot.?.*;
        }
        if (use_f4) {
            const h4 = hashCtx(node_idx, finfo.byte_key) & self.hash_mask;
            p4_slot = &self.p4_table[h4];
            p4v = p4_slot.?.*;
        }

        const use_urn = self.cfg.use_urn and self.urn != null;
        var st_urn: f32 = 0;
        if (use_urn) {
            const u = &self.urn.?;
            const mid = self.tree.nodes[node_idx].mid;
            const left_remaining = u.prefixSum(mid) - u.prefixSum(lo);
            const right_remaining = u.prefixSum(hi) - u.prefixSum(mid);
            const total = left_remaining + right_remaining;
            if (total > 0) {
                const p_right: u64 = @intCast(@divTrunc(right_remaining * 65536, total));
                st_urn = stretchU16(@intCast(std.math.clamp(p_right, 1, 65535)));
            }
        }

        const db: usize = @min(depth, n_depth_buckets - 1);
        const rf: usize = @intFromBool(self.run_len > 2);
        const bf: usize = @intFromBool(self.cfg.use_boundary_ctx and finfo.have_f and finfo.boundary);
        const mix_ctx = (db * 2 + rf) * 2 + bf;

        var pre_sse: u16 = undefined;
        var st: [n_inputs]f32 = .{ 0, 0, 0, 0, 0, 0 };
        if (self.cfg.use_logistic) {
            st[0] = stretchU16(p0v);
            st[1] = stretchU16(p1v);
            st[2] = stretchU16(p2v);
            st[3] = if (use_f3) stretchU16(p3v) else 0;
            st[4] = if (use_f4) stretchU16(p4v) else 0;
            st[5] = st_urn;
            const w = self.mixw[mix_ctx];
            var acc: f32 = 0;
            inline for (0..n_inputs) |ii| acc += w[ii] * st[ii];
            pre_sse = squashToU16(acc);
        } else {
            const mix: u32 = (@as(u32, p0v) + p1v) * 7 + @as(u32, p2v) * 2;
            pre_sse = @intCast(mix >> 4);
        }

        var sse_x1: ?*u16 = null;
        var sse_x2: ?*u16 = null;
        var p_final = pre_sse;
        if (self.cfg.use_sse) {
            const base = mix_ctx * 17;
            const j = p_final >> 12;
            const x1p = &self.sse[base + j];
            const x2p = &self.sse[base + j + 1];
            sse_x1 = x1p;
            sse_x2 = x2p;
            const x1: i32 = x1p.*;
            const x2: i32 = x2p.*;
            const delta: i32 = x2 - x1;
            const ssep: i32 = x1 + ((delta * @as(i32, p_final & 4095)) >> 12);
            const blended: i32 = (ssep * 3 + @as(i32, p_final)) >> 2;
            p_final = @intCast(std.math.clamp(blended, 0, 65535));
        }

        return .{
            .node_idx = node_idx,
            .slots = .{ null, p1_slot, p2_slot, p3_slot, p4_slot, null },
            .mix_ctx = mix_ctx,
            .st = st,
            .pre_sse_of_one = pre_sse,
            .sse_x1 = sse_x1,
            .sse_x2 = sse_x2,
            .p_final_of_one = p_final,
        };
    }

    fn updateNode(self: *TreeCM, pred: NodePred, bit: u1) void {
        if (bit == 1) {
            ByteCM.upd1(&self.p0[pred.node_idx], 2);
        } else {
            ByteCM.upd0(&self.p0[pred.node_idx], 2);
        }
        inline for (.{ 1, 2, 3, 4 }) |ii| {
            if (pred.slots[ii]) |slot| {
                if (bit == 1) ByteCM.upd1(slot, 4) else ByteCM.upd0(slot, 4);
            }
        }
        if (self.cfg.use_sse) {
            if (bit == 1) {
                ByteCM.upd1(pred.sse_x1.?, 6);
                ByteCM.upd1(pred.sse_x2.?, 6);
            } else {
                ByteCM.upd0(pred.sse_x1.?, 6);
                ByteCM.upd0(pred.sse_x2.?, 6);
            }
        }
        if (self.cfg.use_logistic) {
            const target: f32 = if (bit == 1) 1.0 else 0.0;
            const p_mix: f32 = @as(f32, @floatFromInt(pred.pre_sse_of_one)) / 65536.0;
            const err = target - p_mix;
            const lr: f32 = 0.005;
            var w = &self.mixw[pred.mix_ctx];
            inline for (0..n_inputs) |ii| {
                w[ii] = std.math.clamp(w[ii] + lr * err * pred.st[ii], -8.0, 8.0);
            }
        }
    }

    /// Decrement the urn at `sym`'s rank by 1 -- called unconditionally at
    /// the end of every encode/decodeSymbol (both the run-shortcut path and
    /// the tree-walk path), so encoder and decoder never diverge on
    /// "remaining counts" regardless of which path a given symbol took.
    inline fn urnConsume(self: *TreeCM, sym: u32) void {
        if (self.urn) |*u| u.add(self.rev_rank[sym], -1);
    }

    pub fn encodeSymbol(self: *TreeCM, enc: *rc.Encoder, sym: u32) !void {
        const was_same = sym == self.prev1;
        const finfo = self.fInfoAt();
        if (self.cfg.use_run_shortcut) {
            const ctx = self.runCtx();
            try enc.encodeBit(&self.run_bit[ctx], @intFromBool(was_same), 5);
            self.decisions += 1;
        }
        if (!(self.cfg.use_run_shortcut and was_same)) {
            const target_rank = self.rev_rank[sym];
            var cur = self.tree.root;
            var depth: u32 = 0;
            var lo: u32 = 0;
            var hi: u32 = self.tree.k_leaves;
            while (cur >= self.tree.k_leaves) {
                const node_idx = cur - self.tree.k_leaves;
                const node = self.tree.nodes[node_idx];
                const bit: u1 = if (target_rank < node.mid) 0 else 1;
                const pred = self.predictNode(node_idx, depth, lo, hi, finfo);
                if (debug_trace) std.debug.print("E dec={d} node={d} run_len={d} rf... pre_sse={d} p_final={d} bit={d}\n", .{ self.decisions, node_idx, self.run_len, pred.pre_sse_of_one, pred.p_final_of_one, bit });
                try enc.encodeBitProb(ByteCM.toP0(pred.p_final_of_one), bit);
                self.updateNode(pred, bit);
                self.decisions += 1;
                if (bit == 0) {
                    hi = node.mid;
                    cur = node.left;
                } else {
                    lo = node.mid;
                    cur = node.right;
                }
                depth += 1;
            }
        }
        self.urnConsume(sym);
        self.pos += 1;
        if (was_same) {
            self.run_len += 1;
            self.prev_hit = true;
        } else {
            self.run_len = 0;
            self.prev_hit = false;
        }
        self.prev2 = self.prev1;
        self.prev1 = sym;
    }

    pub fn decodeSymbol(self: *TreeCM, dec: *rc.Decoder) u32 {
        var sym: u32 = undefined;
        var shortcut_hit = false;
        const finfo = self.fInfoAt();
        if (self.cfg.use_run_shortcut) {
            const ctx = self.runCtx();
            const bit = dec.decodeBit(&self.run_bit[ctx], 5);
            self.decisions += 1;
            if (bit == 1) {
                sym = self.prev1;
                shortcut_hit = true;
            }
        }
        if (!shortcut_hit) {
            var cur = self.tree.root;
            var depth: u32 = 0;
            var lo: u32 = 0;
            var hi: u32 = self.tree.k_leaves;
            while (cur >= self.tree.k_leaves) {
                const node_idx = cur - self.tree.k_leaves;
                const node = self.tree.nodes[node_idx];
                const pred = self.predictNode(node_idx, depth, lo, hi, finfo);
                const bit = dec.decodeBitProb(ByteCM.toP0(pred.p_final_of_one));
                if (debug_trace) std.debug.print("D dec={d} node={d} run_len={d} rf... pre_sse={d} p_final={d} bit={d}\n", .{ self.decisions, node_idx, self.run_len, pred.pre_sse_of_one, pred.p_final_of_one, bit });
                self.updateNode(pred, bit);
                self.decisions += 1;
                if (bit == 0) {
                    hi = node.mid;
                    cur = node.left;
                } else {
                    lo = node.mid;
                    cur = node.right;
                }
                depth += 1;
            }
            sym = self.order[cur];
        }
        self.urnConsume(sym);
        self.pos += 1;
        // Bookkeeping (run length, mixer/SSE run-flag context, prev1/prev2)
        // must reflect whether the *actual decoded symbol* repeats the
        // previous one, not just whether the shortcut path was taken —
        // when the shortcut is disabled (or missed), the tree walk can
        // still land on the same symbol, and the decoder only learns that
        // after decoding it, same as it would have to.
        const is_repeat = sym == self.prev1;
        if (is_repeat) {
            self.run_len += 1;
            self.prev_hit = true;
        } else {
            self.run_len = 0;
            self.prev_hit = false;
        }
        self.prev2 = self.prev1;
        self.prev1 = sym;
        return sym;
    }
};

/// `fctx_sym`/`sym_byte01`/`urn_init_counts` are the idea-2 contexts (see
/// TreeCM doc comments); pass empty slices (`&.{}`) when unavailable (every
/// multi-block frame in this lab) or simply not wanted (cfg flags off).
pub fn encodeSymbolsTree(
    alloc: std.mem.Allocator,
    syms: []const u32,
    tree: *const AlphaTree,
    order: []const u32,
    rev_rank: []const u32,
    cfg: TreeCMConfig,
    fctx_sym: []const u32,
    sym_byte01: []const [2]u16,
    urn_init_counts: []const u32,
) !Counted {
    var cm = try TreeCM.init(alloc, tree, order, rev_rank, cfg, fctx_sym, sym_byte01, urn_init_counts);
    defer cm.deinit();
    var enc = rc.Encoder.init(alloc);
    defer enc.deinit();
    for (syms) |s| try cm.encodeSymbol(&enc, s);
    return .{ .bytes = try alloc.dupe(u8, try enc.finish()), .decisions = cm.decisions };
}

pub fn decodeSymbolsTree(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    n: usize,
    tree: *const AlphaTree,
    order: []const u32,
    rev_rank: []const u32,
    cfg: TreeCMConfig,
    fctx_sym: []const u32,
    sym_byte01: []const [2]u16,
    urn_init_counts: []const u32,
) !CountedSyms {
    var cm = try TreeCM.init(alloc, tree, order, rev_rank, cfg, fctx_sym, sym_byte01, urn_init_counts);
    defer cm.deinit();
    var dec = rc.Decoder.init(bytes);
    const out = try alloc.alloc(u32, n);
    errdefer alloc.free(out);
    for (out) |*s| s.* = cm.decodeSymbol(&dec);
    return .{ .syms = out, .decisions = cm.decisions };
}

// ---------------------------------------------------------------- tests --

test "ByteCM roundtrip on skewed random bytes" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x1234);
    const rnd = prng.random();
    const n = 20_000;
    const syms = try alloc.alloc(u32, n);
    defer alloc.free(syms);
    for (syms) |*s| {
        // Skewed distribution + runs, like a BWT'd text block.
        if (rnd.uintLessThan(u8, 4) == 0) {
            s.* = rnd.uintLessThan(u32, 256);
        } else {
            s.* = if (rnd.uintLessThan(u8, 3) == 0) 'e' else 'a';
        }
    }
    const enc = try encodeSymbols(alloc, syms, 256);
    defer alloc.free(enc);
    const dec = try decodeSymbols(alloc, enc, n, 256);
    defer alloc.free(dec);
    try std.testing.expectEqualSlices(u32, syms, dec);
    try std.testing.expect(enc.len < n); // must actually compress skewed data
}

test "ByteCM empty and length 1" {
    const alloc = std.testing.allocator;
    {
        const enc = try encodeSymbols(alloc, &.{}, 256);
        defer alloc.free(enc);
        const dec = try decodeSymbols(alloc, enc, 0, 256);
        defer alloc.free(dec);
        try std.testing.expectEqual(@as(usize, 0), dec.len);
    }
    {
        const enc = try encodeSymbols(alloc, &.{42}, 256);
        defer alloc.free(enc);
        const dec = try decodeSymbols(alloc, enc, 1, 256);
        defer alloc.free(dec);
        try std.testing.expectEqualSlices(u32, &.{42}, dec);
    }
}

test "GenericCM roundtrip, moderate K, Zipfy distribution" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x9876);
    const rnd = prng.random();
    const k: usize = 5000;
    const n = 30_000;
    const syms = try alloc.alloc(u32, n);
    defer alloc.free(syms);
    for (syms) |*s| {
        const r = rnd.float(f64);
        // crude zipf-ish: mostly low ids, occasional high
        const v: f64 = @as(f64, @floatFromInt(k)) * r * r * r;
        s.* = @min(@as(u32, @intFromFloat(v)), @as(u32, @intCast(k - 1)));
    }
    const enc = try encodeSymbols(alloc, syms, k);
    defer alloc.free(enc);
    const dec = try decodeSymbols(alloc, enc, n, k);
    defer alloc.free(dec);
    try std.testing.expectEqualSlices(u32, syms, dec);
    try std.testing.expect(enc.len < n * 2); // sanity: not wildly worse than 16 bits/sym
}

test "GenericCM roundtrip with runs (recency cache exercised)" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x4242);
    const rnd = prng.random();
    const k: usize = 2000;
    var syms: std.ArrayList(u32) = .empty;
    defer syms.deinit(alloc);
    while (syms.items.len < 20_000) {
        const sym = rnd.uintLessThan(u32, @intCast(k));
        const run = 1 + rnd.uintLessThan(u32, 20);
        for (0..run) |_| try syms.append(alloc, sym);
    }
    const enc = try encodeSymbols(alloc, syms.items, k);
    defer alloc.free(enc);
    const dec = try decodeSymbols(alloc, enc, syms.items.len, k);
    defer alloc.free(dec);
    try std.testing.expectEqualSlices(u32, syms.items, dec);
    try std.testing.expect(enc.len < syms.items.len / 2); // runs must compress hard
}

test "GenericCM large K, sparse" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xABCD);
    const rnd = prng.random();
    const k: usize = 1 << 20;
    const n = 5000;
    const syms = try alloc.alloc(u32, n);
    defer alloc.free(syms);
    for (syms) |*s| s.* = rnd.uintLessThan(u32, @intCast(k));
    const enc = try encodeSymbols(alloc, syms, k);
    defer alloc.free(enc);
    const dec = try decodeSymbols(alloc, enc, n, k);
    defer alloc.free(dec);
    try std.testing.expectEqualSlices(u32, syms, dec);
}

test "Fenwick sanity" {
    const alloc = std.testing.allocator;
    var f = try Fenwick.init(alloc, 100);
    defer f.deinit();
    // uniform prior: cumBelow(i) == i
    for (0..100) |i| try std.testing.expectEqual(@as(u32, @intCast(i)), f.cumBelow(i));
    f.add(50, 1000);
    try std.testing.expectEqual(@as(u32, 1001), f.freqAt(50));
    try std.testing.expectEqual(@as(u32, 50), f.cumBelow(50));
    try std.testing.expectEqual(@as(u32, 1051), f.cumBelow(51));
    // findByCum should invert cumBelow/freqAt
    var prng = std.Random.DefaultPrng.init(1);
    const rnd = prng.random();
    for (0..1000) |_| {
        const target = rnd.uintLessThan(u32, @intCast(f.total));
        const sym = f.findByCum(target);
        try std.testing.expect(target >= f.cumBelow(sym) and target < f.cumBelow(sym) + f.freqAt(sym));
    }
}

fn treeLeafDepth(tree: *const AlphaTree, target_rank: u32) u32 {
    if (tree.k_leaves <= 1) return 0;
    var cur = tree.root;
    var depth: u32 = 0;
    while (cur >= tree.k_leaves) {
        const node = tree.nodes[cur - tree.k_leaves];
        cur = if (target_rank < node.mid) node.left else node.right;
        depth += 1;
    }
    std.debug.assert(cur == target_rank);
    return depth;
}

test "AlphaTree: degenerate k_leaves 0/1/2" {
    const alloc = std.testing.allocator;
    {
        var t = try buildAlphaTree(alloc, &.{}, &.{});
        defer t.deinit();
        try std.testing.expectEqual(@as(u32, 0), t.k_leaves);
    }
    {
        var t = try buildAlphaTree(alloc, &.{7}, &.{ 0, 0, 0, 0, 0, 0, 0, 5 });
        defer t.deinit();
        try std.testing.expectEqual(@as(u32, 1), t.k_leaves);
        try std.testing.expectEqual(@as(u32, 0), treeLeafDepth(&t, 0));
    }
    {
        // two leaves, heavily skewed weight: still exactly 1 decision each
        // (a 2-leaf alphabetic tree has no other shape available).
        const order = [_]u32{ 3, 9 };
        const w = [_]u32{ 0, 0, 0, 1, 0, 0, 0, 0, 0, 1000 };
        var t = try buildAlphaTree(alloc, &order, &w);
        defer t.deinit();
        try std.testing.expectEqual(@as(u32, 1), treeLeafDepth(&t, 0));
        try std.testing.expectEqual(@as(u32, 1), treeLeafDepth(&t, 1));
    }
}

test "AlphaTree: frequent symbols get shorter paths than rare ones" {
    const alloc = std.testing.allocator;
    const k: u32 = 300;
    const order = try alloc.alloc(u32, k);
    defer alloc.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const w = try alloc.alloc(u32, k);
    defer alloc.free(w);
    @memset(w, 1);
    w[150] = 1_000_000; // one very frequent symbol in the middle of the order
    var t = try buildAlphaTree(alloc, order, w);
    defer t.deinit();
    const freq_depth = treeLeafDepth(&t, 150);
    const rare_depth = treeLeafDepth(&t, 0);
    try std.testing.expect(freq_depth < rare_depth);
    // every leaf must be reachable and land on the right symbol
    for (0..k) |r| _ = treeLeafDepth(&t, @intCast(r));
}

test "TreeCM roundtrip, all config combinations, Zipf-ish K=4000" {
    const alloc = std.testing.allocator;
    const k: u32 = 4000;
    const order = try alloc.alloc(u32, k);
    defer alloc.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const rev_rank = try alloc.alloc(u32, k);
    defer alloc.free(rev_rank);
    for (order, 0..) |sym, r| rev_rank[sym] = @intCast(r);
    const w = try alloc.alloc(u32, k);
    defer alloc.free(w);
    for (w, 0..) |*wi, i| wi.* = @intCast(1 + (k - i) * (k - i) / k); // decreasing-ish weight

    var tree = try buildAlphaTree(alloc, order, w);
    defer tree.deinit();

    var prng = std.Random.DefaultPrng.init(0x7E7);
    const rnd = prng.random();
    var syms: std.ArrayList(u32) = .empty;
    defer syms.deinit(alloc);
    while (syms.items.len < 15_000) {
        const r = rnd.float(f64);
        const v: f64 = @as(f64, @floatFromInt(k)) * r * r;
        const sym: u32 = @min(@as(u32, @intFromFloat(v)), k - 1);
        const run: u32 = 1 + rnd.uintLessThan(u32, 8);
        for (0..run) |_| try syms.append(alloc, sym);
    }

    // Synthetic F-context: position i's "following symbol" is just the next
    // symbol in the stream (a plausible stand-in for a real BWT F column,
    // good enough to exercise the hashing/boundary code paths), with the
    // very last position marked as the block-end sentinel.
    const fctx = try alloc.alloc(u32, syms.items.len);
    defer alloc.free(fctx);
    for (fctx, 0..) |*f, i| f.* = if (i + 1 < syms.items.len) syms.items[i + 1] else f_end;
    const sym_byte01 = try alloc.alloc([2]u16, k);
    defer alloc.free(sym_byte01);
    for (sym_byte01, 0..) |*b, i| b.* = .{ @intCast(i % 251), @intCast((i / 251) % 251) };
    const urn_counts = try alloc.alloc(u32, k);
    defer alloc.free(urn_counts);
    @memset(urn_counts, 0);
    for (syms.items) |s| urn_counts[rev_rank[s]] += 1;

    const configs = [_]TreeCMConfig{
        .{ .use_run_shortcut = false, .use_logistic = false, .use_sse = false },
        .{ .use_run_shortcut = true, .use_logistic = false, .use_sse = false },
        .{ .use_run_shortcut = false, .use_logistic = false, .use_sse = true },
        .{ .use_run_shortcut = false, .use_logistic = true, .use_sse = false },
        .{ .use_run_shortcut = true, .use_logistic = true, .use_sse = true },
        .{ .use_fctx = true },
        .{ .use_fctx_bytes = true },
        .{ .use_boundary_ctx = true },
        .{ .use_urn = true },
        .{ .use_fctx = true, .use_fctx_bytes = true, .use_boundary_ctx = true, .use_urn = true },
    };
    for (configs, 0..) |cfg, i| {
        const needs_f = cfg.use_fctx or cfg.use_fctx_bytes or cfg.use_boundary_ctx;
        const f_arg: []const u32 = if (needs_f) fctx else &.{};
        const b_arg: []const [2]u16 = if (cfg.use_fctx_bytes) sym_byte01 else &.{};
        const u_arg: []const u32 = if (cfg.use_urn) urn_counts else &.{};
        const enc = try encodeSymbolsTree(alloc, syms.items, &tree, order, rev_rank, cfg, f_arg, b_arg, u_arg);
        defer alloc.free(enc.bytes);
        const dec = try decodeSymbolsTree(alloc, enc.bytes, syms.items.len, &tree, order, rev_rank, cfg, f_arg, b_arg, u_arg);
        defer alloc.free(dec.syms);
        try std.testing.expectEqualSlices(u32, syms.items, dec.syms);
        try std.testing.expectEqual(enc.decisions, dec.decisions);
        if (i == 4) try std.testing.expect(enc.bytes.len < syms.items.len); // strongest round-2 config must compress this run-heavy input
    }
}

test "TreeCM roundtrip, tiny K (1 and 2)" {
    const alloc = std.testing.allocator;
    {
        const order = [_]u32{5};
        const w = [_]u32{ 0, 0, 0, 0, 0, 9 };
        var tree = try buildAlphaTree(alloc, &order, &w);
        defer tree.deinit();
        var rev_rank = [_]u32{0} ** 6;
        rev_rank[5] = 0;
        const syms = [_]u32{ 5, 5, 5, 5 };
        const enc = try encodeSymbolsTree(alloc, &syms, &tree, &order, &rev_rank, .{}, &.{}, &.{}, &.{});
        defer alloc.free(enc.bytes);
        const dec = try decodeSymbolsTree(alloc, enc.bytes, syms.len, &tree, &order, &rev_rank, .{}, &.{}, &.{}, &.{});
        defer alloc.free(dec.syms);
        try std.testing.expectEqualSlices(u32, &syms, dec.syms);
    }
    {
        const order = [_]u32{ 1, 0 };
        const w = [_]u32{ 5, 1 };
        var tree = try buildAlphaTree(alloc, &order, &w);
        defer tree.deinit();
        var rev_rank = [_]u32{ 0, 0 };
        for (order, 0..) |sym, r| rev_rank[sym] = @intCast(r);
        var prng = std.Random.DefaultPrng.init(3);
        const rnd = prng.random();
        const syms = try alloc.alloc(u32, 500);
        defer alloc.free(syms);
        for (syms) |*s| s.* = rnd.uintLessThan(u32, 2);
        const enc = try encodeSymbolsTree(alloc, syms, &tree, &order, &rev_rank, .{}, &.{}, &.{}, &.{});
        defer alloc.free(enc.bytes);
        const dec = try decodeSymbolsTree(alloc, enc.bytes, syms.len, &tree, &order, &rev_rank, .{}, &.{}, &.{}, &.{});
        defer alloc.free(dec.syms);
        try std.testing.expectEqualSlices(u32, syms, dec.syms);
    }
}
