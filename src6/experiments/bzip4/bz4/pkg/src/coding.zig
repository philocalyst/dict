//! Small, general range-coder building blocks shared by the model codec and
//! the class-conditional block coder: an adaptive adaptive-length integer
//! code ("zeros/small values cheap"), an order-statistics Fenwick tree, a
//! symbol table bucketed by an arbitrary small key (used to code "which
//! symbol, given its class" the same way the round-1 lanes coded "which
//! symbol, given its first byte"), and `bitsFor` for fixed-width fields.
//!
//! Copied and generalised from `k_common.zig` (Lane K) and `m_codec.zig`
//! (Lane M) per PLAN.md's copy-and-reshape rule -- the B4SD file-format and
//! grammar-topology pieces of those files are dropped (this package never
//! reads a B4SD dump; `topology.zig` builds the same information directly
//! from a `Lexicon`), leaving just the reusable coding primitives.

const std = @import("std");
const rc = @import("range_coder.zig");

pub fn u64c(x: u64) u32 {
    return @intCast(@min(x, @as(u64, std.math.maxInt(u32))));
}

inline fn lowbit(i: usize) usize {
    return i & (0 -% i);
}

/// Number of raw bits needed to store a value in 0..n-1 (n >= 1): ceil(log2(n)).
pub fn bitsFor(n: u32) u6 {
    if (n <= 1) return 0;
    return @intCast(32 - @clz(n - 1));
}

// --------------------------------------------------------- adaptive var --

/// Adaptive "unary length-prefix + raw mantissa" code for a non-negative
/// integer < 2^32, with a dedicated zero flag (counts/deltas/arities are
/// overwhelmingly 0 or small). Same spirit as Lane B's `GammaCtx` and Lane
/// M's `VarCtx`; used by the model codec for entry counts/deltas/arities.
pub const VarCtx = struct {
    zero: rc.Bit = .{},
    len_bits: [33]rc.Bit = [_]rc.Bit{.{}} ** 33,
};

pub fn encodeVar(enc: *rc.Encoder, ctx: *VarCtx, value: u64) !void {
    if (value == 0) {
        try enc.encodeBit(&ctx.zero, 1, 5);
        return;
    }
    try enc.encodeBit(&ctx.zero, 0, 5);
    std.debug.assert(value < (1 << 32));
    const nb: u6 = @intCast(64 - @clz(value));
    var i: u6 = 1;
    while (i < nb) : (i += 1) try enc.encodeBit(&ctx.len_bits[i], 0, 5);
    try enc.encodeBit(&ctx.len_bits[nb], 1, 5);
    if (nb > 1) {
        const mantissa: u32 = @intCast(value - (@as(u64, 1) << (nb - 1)));
        try enc.encodeDirect(mantissa, nb - 1);
    }
}

/// `encodeVar` never emits a length prefix past 32 (its contract is
/// `value < 2^32`); a corrupted stream can ask for more, so the length
/// search is bounded here rather than trusting the wire -- an unbounded
/// version would eventually index `len_bits` out of range (a safety-
/// checked panic in Debug/ReleaseSafe, undefined behaviour without it).
pub fn decodeVar(dec: *rc.Decoder, ctx: *VarCtx) !u64 {
    if (dec.decodeBit(&ctx.zero, 5) == 1) return 0;
    var nb: u6 = 1;
    while (true) {
        if (nb > 32) return error.CorruptStream;
        if (dec.decodeBit(&ctx.len_bits[nb], 5) == 1) break;
        nb += 1;
    }
    const mantissa: u64 = if (nb > 1) dec.decodeDirect(nb - 1) else 0;
    return (@as(u64, 1) << (nb - 1)) | mantissa;
}

// ------------------------------------------------------ adaptive gamma --

/// Adaptive Elias-gamma-style coder: the bit-length of (v+1) is coded with
/// an adaptive unary "continue" prefix (so v=0 is nearly free once the
/// model adapts), then the mantissa bits raw. Used for override-list gaps
/// and the dense-but-mostly-small C x (C+1) transition-count table.
pub const GAMMA_MAX_BITS: u6 = 32;

pub const GammaCtx = struct {
    cont: [GAMMA_MAX_BITS]rc.Bit = [_]rc.Bit{.{}} ** GAMMA_MAX_BITS,
};

pub fn gammaEncode(enc: *rc.Encoder, ctx: *GammaCtx, v: u32) !void {
    const n: u64 = @as(u64, v) + 1;
    const nbits: u6 = @intCast(64 - @clz(n));
    var i: u6 = 0;
    while (i < nbits - 1) : (i += 1) {
        const idx = if (i < GAMMA_MAX_BITS) i else GAMMA_MAX_BITS - 1;
        try enc.encodeBit(&ctx.cont[idx], 1, 5);
    }
    const stop_idx = if (nbits - 1 < GAMMA_MAX_BITS) nbits - 1 else GAMMA_MAX_BITS - 1;
    try enc.encodeBit(&ctx.cont[stop_idx], 0, 5);
    if (nbits > 1) {
        const mant: u32 = @intCast(n - (@as(u64, 1) << (nbits - 1)));
        try enc.encodeDirect(mant, nbits - 1);
    }
}

/// `gammaEncode`'s largest legitimate length is 33 bits (`v == u32::max`
/// gives `n = v+1 == 2^32`); a corrupted stream can ask to keep going
/// past that, so both the search and the final range are checked
/// explicitly rather than trusting the wire (see `decodeVar`'s doc
/// comment for why: an unbounded version risks a safety-checked panic on
/// the final narrowing cast, not just a slow loop).
pub fn gammaDecode(dec: *rc.Decoder, ctx: *GammaCtx) !u32 {
    var nbits: u6 = 1;
    while (true) {
        if (nbits > 33) return error.CorruptStream;
        const idx = if (nbits - 1 < GAMMA_MAX_BITS) nbits - 1 else GAMMA_MAX_BITS - 1;
        const bit = dec.decodeBit(&ctx.cont[idx], 5);
        if (bit == 0) break;
        nbits += 1;
    }
    var n: u64 = 1;
    if (nbits > 1) {
        const mant = dec.decodeDirect(nbits - 1);
        n = (@as(u64, 1) << (nbits - 1)) | mant;
    }
    if (n - 1 > std.math.maxInt(u32)) return error.CorruptStream;
    return @intCast(n - 1);
}

// ------------------------------------------------------------- Fenwick --

/// Order-statistics Fenwick tree over non-negative u32 counts: prefix sum
/// and "find index for cumulative value" both in O(log n).
pub const Fenwick = struct {
    counts: []u32,
    tree: []u64,
    n: usize,
    top_pow: usize,

    pub fn init(alloc: std.mem.Allocator, n: usize) !Fenwick {
        const counts = try alloc.alloc(u32, n);
        @memset(counts, 0);
        const tree = try alloc.alloc(u64, n + 1);
        @memset(tree, 0);
        var top: usize = 0;
        if (n > 0) {
            top = 1;
            while (top * 2 <= n) top *= 2;
        }
        return .{ .counts = counts, .tree = tree, .n = n, .top_pow = top };
    }

    pub fn deinit(self: *Fenwick, alloc: std.mem.Allocator) void {
        alloc.free(self.counts);
        alloc.free(self.tree);
    }

    pub fn build(self: *Fenwick, vals: []const u32) void {
        @memcpy(self.counts, vals);
        @memset(self.tree, 0);
        for (0..self.n) |i| self.tree[i + 1] = vals[i];
        var i: usize = 1;
        while (i <= self.n) : (i += 1) {
            const j = i + lowbit(i);
            if (j <= self.n) self.tree[j] += self.tree[i];
        }
    }

    pub fn prefix(self: *const Fenwick, idx0: usize) u64 {
        var i = idx0;
        var s: u64 = 0;
        while (i > 0) : (i -= lowbit(i)) s += self.tree[i];
        return s;
    }

    pub fn total(self: *const Fenwick) u64 {
        return self.prefix(self.n);
    }

    /// Smallest 0-indexed idx such that prefix(idx+1) > target.
    pub fn find(self: *const Fenwick, target: u64) usize {
        var idx: usize = 0;
        var rem = target;
        var pw = self.top_pow;
        while (pw > 0) : (pw >>= 1) {
            const next = idx + pw;
            if (next <= self.n and self.tree[next] <= rem) {
                idx = next;
                rem -= self.tree[next];
            }
        }
        return idx;
    }
};

/// Symbols bucketed by an arbitrary small key in 0..num_buckets-1 (here:
/// the induced class id) -- generalises the round-1 lanes' "bucket by
/// first byte" (256 buckets) to "bucket by class" (C buckets, typically
/// <=256). `local_idx` is a single id-space-sized array shared across
/// every bucket.
pub const BucketSet = struct {
    fenwicks: []?Fenwick,
    sym_of: [][]u32,
    local_idx: []u32,
    alloc: std.mem.Allocator,
    num_buckets: usize,

    pub fn deinit(self: *BucketSet) void {
        for (0..self.num_buckets) |f| {
            self.alloc.free(self.sym_of[f]);
            if (self.fenwicks[f]) |*fw| fw.deinit(self.alloc);
        }
        self.alloc.free(self.sym_of);
        self.alloc.free(self.fenwicks);
        self.alloc.free(self.local_idx);
    }
};

/// Build buckets keyed by `key_of[s]` (must be < num_buckets), weighted by
/// `weight[s]` (only symbols with weight > 0 participate -- they are the
/// only ones ever coded).
pub fn buildBuckets(alloc: std.mem.Allocator, num_buckets: usize, k: usize, key_of: []const u32, weight: []const u64) !BucketSet {
    const counts = try alloc.alloc(usize, num_buckets);
    defer alloc.free(counts);
    @memset(counts, 0);
    for (0..k) |s| {
        if (weight[s] > 0) counts[key_of[s]] += 1;
    }
    const sym_of = try alloc.alloc([]u32, num_buckets);
    for (0..num_buckets) |f| sym_of[f] = try alloc.alloc(u32, counts[f]);
    const fill = try alloc.alloc(usize, num_buckets);
    defer alloc.free(fill);
    @memset(fill, 0);
    const local_idx = try alloc.alloc(u32, k);
    @memset(local_idx, 0);
    for (0..k) |s| {
        if (weight[s] > 0) {
            const f = key_of[s];
            const idx = fill[f];
            fill[f] += 1;
            sym_of[f][idx] = @intCast(s);
            local_idx[s] = @intCast(idx);
        }
    }
    const fenwicks = try alloc.alloc(?Fenwick, num_buckets);
    @memset(fenwicks, null);
    for (0..num_buckets) |f| {
        if (counts[f] == 0) continue;
        const vals = try alloc.alloc(u32, counts[f]);
        defer alloc.free(vals);
        for (sym_of[f], 0..) |s, i| vals[i] = u64c(weight[s]);
        var fw = try Fenwick.init(alloc, counts[f]);
        fw.build(vals);
        fenwicks[f] = fw;
    }
    return .{ .fenwicks = fenwicks, .sym_of = sym_of, .local_idx = local_idx, .alloc = alloc, .num_buckets = num_buckets };
}

pub fn bsEncodeSym(bs: *BucketSet, enc: *rc.Encoder, f: u32, s: u32) !void {
    const fw = &bs.fenwicks[f].?;
    const local = bs.local_idx[s];
    const freq = fw.counts[local];
    const cum = fw.prefix(local);
    const tot = fw.total();
    try enc.encodeFreq(u64c(cum), freq, u64c(tot));
}

pub fn bsDecodeSym(bs: *BucketSet, dec: *rc.Decoder, f: u32) u32 {
    const fw = &bs.fenwicks[f].?;
    const tot = fw.total();
    const v = dec.decodeFreq(u64c(tot));
    const local = fw.find(v);
    const freq = fw.counts[local];
    const cum = fw.prefix(local);
    dec.consume(u64c(cum), freq);
    return bs.sym_of[f][local];
}

test "gamma code round-trips small and large values" {
    const alloc = std.testing.allocator;
    const vals = [_]u32{ 0, 1, 2, 3, 7, 8, 255, 256, 65535, 1 << 20, std.math.maxInt(u32) };
    var enc = rc.Encoder.init(alloc);
    defer enc.deinit();
    var ctx: GammaCtx = .{};
    for (vals) |v| try gammaEncode(&enc, &ctx, v);
    const bytes = try enc.finish();

    var dec = rc.Decoder.init(bytes);
    var dctx: GammaCtx = .{};
    for (vals) |v| try std.testing.expectEqual(v, try gammaDecode(&dec, &dctx));
}

test "Fenwick prefix/find agree with a linear scan" {
    const alloc = std.testing.allocator;
    const vals = [_]u32{ 3, 0, 7, 1, 0, 5, 2 };
    var fw = try Fenwick.init(alloc, vals.len);
    defer fw.deinit(alloc);
    fw.build(&vals);
    try std.testing.expectEqual(@as(u64, 18), fw.total());
    var cum: u64 = 0;
    for (vals, 0..) |v, i| {
        try std.testing.expectEqual(cum, fw.prefix(i));
        cum += v;
        if (v > 0) try std.testing.expectEqual(i, fw.find(fw.prefix(i)));
    }
}
