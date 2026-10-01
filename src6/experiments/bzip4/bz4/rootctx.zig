//! Lane X: soft-context modelling of root symbols, on top of a full pair
//! grammar (B4SD dump). See LANE_X.md for the write-up and PLAN.md for the
//! dump format and rules of evidence. Pure Zig 0.16, std only.
//!
//! THE QUESTION: after a full pair grammar every adjacent root pair is
//! (almost) unique, so exact-context modelling of root *ids* has nothing to
//! learn. But the *bytes* at root junctions are highly predictable (after a
//! root ending in a space comes a root starting with a letter; after "q"
//! comes "u"). This file builds and measures several ways to spend that
//! soft structure, all charged through the real shared range coder
//! (`rc.zig`) with a real decode verifying every block.
//!
//! Every symbol id 0..255 is a literal byte; id 256+i is rule i, and a
//! rule's children always have smaller ids than the rule itself, so one
//! forward pass over ids gives every symbol's first/last byte(s) and byte
//! length (`SymInfo`). The *shared* model — the grammar itself and the
//! global per-symbol root counts g[s] — is charged zero (Lane B's job);
//! only extra tables a variant stores on top of that are charged here.
//!
//! Variants (see `Variant`):
//!   x0   static order-0 P(s) = g[s]/M                          (reference)
//!   x1i  P(f|ctx) from a *stored* empirical 257x256 table       (i)
//!   x1ii P(f|ctx) from a *free* grammar-usage prior, static     (ii)
//!   x1iii same prior, adaptive within the block                 (iii)
//!   x2   richer ctx = (last byte, length bucket), adaptive
//!   x3   in-block recency/frequency boost, no context factoring
//!   x4   x1iii's context combined with x3's per-bucket boost
//!
//! ctx alphabet is 0..255 (real last byte of the previous root) plus the
//! sentinel 256 for "start of block". f is the first byte of a root's
//! expansion (0..255). P(s|f) is always g[s] restricted to the bucket of
//! symbols that share first byte f, coded with a Fenwick tree so buckets
//! with tens of thousands of members are still O(log n) per symbol.

const std = @import("std");
const rc = @import("rc.zig");

// ---------------------------------------------------------------- tuning --
// Same constants for every file (no per-corpus parameters).
const CTX_START: u32 = 256; // sentinel "beginning of block" byte context
const LEN_BUCKETS: u32 = 6; // length-bucket count for X2's richer context
const CTX_PRIOR_TARGET: u32 = 2048; // pseudo-count budget for adaptive rows
const CTX_BUMP: u32 = 64; // adaptive row increment per observed junction
const SMOOTH_EPS: u64 = 1; // flat additive smoothing per (ctx,f) grammar cell
const BOOST: i32 = 32; // in-block recency/frequency boost (X3/X4)

pub const Timer = struct {
    io: std.Io,
    started: i96,

    pub fn start(io: std.Io) Timer {
        return .{ .io = io, .started = std.Io.Clock.awake.now(io).nanoseconds };
    }
    pub fn read(self: Timer) u64 {
        const value = std.Io.Clock.awake.now(self.io).nanoseconds - self.started;
        return @intCast(@max(@as(i96, 0), value));
    }
};

fn u64c(x: u64) u32 {
    return @intCast(@min(x, @as(u64, std.math.maxInt(u32))));
}

inline fn lowbit(i: usize) usize {
    return i & (0 -% i);
}

// -------------------------------------------------------------- B4SD I/O --

pub const Rule = extern struct { a: u32, b: u32 };

pub const Dump = struct {
    alloc: std.mem.Allocator,
    rules: []Rule,
    blocks: [][]u32,
    block_bytes: u32,
    raw_len: u32,
    k: usize, // 256 + rules.len

    pub fn deinit(self: *Dump) void {
        for (self.blocks) |b| self.alloc.free(b);
        self.alloc.free(self.blocks);
        self.alloc.free(self.rules);
    }

    /// Raw byte length of block `b`, derivable from the frame header alone
    /// (block_bytes, raw_len): the decoder's real stop condition, so no
    /// per-block root count ever needs to be stored.
    pub fn blockRawLen(self: *const Dump, b: usize) u32 {
        const start: u64 = @as(u64, self.block_bytes) * @as(u64, b);
        const end: u64 = @min(@as(u64, self.raw_len), @as(u64, self.block_bytes) * @as(u64, b + 1));
        return @intCast(end - start);
    }
};

fn readU32(bytes: []const u8, off: *usize) u32 {
    const v = std.mem.readInt(u32, bytes[off.*..][0..4], .little);
    off.* += 4;
    return v;
}

pub fn readDump(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !Dump {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 30));
    defer alloc.free(bytes);
    var off: usize = 0;
    const magic = readU32(bytes, &off);
    if (magic != 0x44533442) return error.BadMagic;
    const version = readU32(bytes, &off);
    if (version != 1) return error.BadVersion;
    const rule_count = readU32(bytes, &off);
    const block_count = readU32(bytes, &off);
    const block_bytes = readU32(bytes, &off);
    const raw_len = readU32(bytes, &off);

    const rules = try alloc.alloc(Rule, rule_count);
    errdefer alloc.free(rules);
    for (rules) |*r| {
        r.a = readU32(bytes, &off);
        r.b = readU32(bytes, &off);
    }

    const blocks = try alloc.alloc([]u32, block_count);
    errdefer alloc.free(blocks);
    var built: usize = 0;
    errdefer for (blocks[0..built]) |b| alloc.free(b);
    for (blocks) |*blk| {
        const root_count = readU32(bytes, &off);
        const syms = try alloc.alloc(u32, root_count);
        for (syms) |*s| s.* = readU32(bytes, &off);
        blk.* = syms;
        built += 1;
    }
    if (off != bytes.len) return error.TrailingBytes;

    return .{
        .alloc = alloc,
        .rules = rules,
        .blocks = blocks,
        .block_bytes = block_bytes,
        .raw_len = raw_len,
        .k = 256 + rule_count,
    };
}

// ---------------------------------------------------------- symbol table --

pub const SymInfo = struct {
    first1: u8,
    first2: u8, // second byte of the expansion (falls back to first1 if len==1)
    last1: u8,
    last2: u8, // second-to-last byte (falls back to last1 if len==1)
    len: u32,
};

/// One forward pass, ids 0..k-1: children always have smaller ids than
/// their parent, so this is well-defined without recursion.
pub fn buildSymInfo(alloc: std.mem.Allocator, dump: *const Dump) ![]SymInfo {
    const info = try alloc.alloc(SymInfo, dump.k);
    for (0..256) |i| {
        const b: u8 = @intCast(i);
        info[i] = .{ .first1 = b, .first2 = b, .last1 = b, .last2 = b, .len = 1 };
    }
    for (dump.rules, 0..) |r, i| {
        const id = 256 + i;
        const a = info[r.a];
        const bb = info[r.b];
        info[id] = .{
            .first1 = a.first1,
            .first2 = if (a.len >= 2) a.first2 else bb.first1,
            .last1 = bb.last1,
            .last2 = if (bb.len >= 2) bb.last2 else a.last1,
            .len = a.len + bb.len,
        };
    }
    return info;
}

pub fn computeG(alloc: std.mem.Allocator, dump: *const Dump) ![]u64 {
    const g = try alloc.alloc(u64, dump.k);
    @memset(g, 0);
    for (dump.blocks) |blk| for (blk) |s| {
        g[s] += 1;
    };
    return g;
}

/// u[s] = total number of times s's expansion is instantiated anywhere in
/// the fully expanded byte stream: as a root (g[s]) plus once for every
/// instantiation of every rule that has s as a child. Since child ids are
/// always < parent id, processing rules from the highest id down leaves
/// u[parent] finalised before it is propagated to its children — the
/// decoder can compute this top-down from the rule table alone, so it is
/// exactly as "free" as the grammar itself.
pub fn computeUsage(alloc: std.mem.Allocator, dump: *const Dump, g: []const u64) ![]u64 {
    const u = try alloc.dupe(u64, g);
    var i = dump.rules.len;
    while (i > 0) {
        i -= 1;
        const id = 256 + i;
        const r = dump.rules[i];
        u[r.a] += u[id];
        u[r.b] += u[id];
    }
    return u;
}

fn lenBucket(len: u32) u32 {
    if (len <= 1) return 0;
    if (len == 2) return 1;
    if (len <= 4) return 2;
    if (len <= 8) return 3;
    if (len <= 16) return 4;
    return 5;
}

fn ctx2Index(ctx_byte: u32, bucket: u32) u32 {
    return ctx_byte * LEN_BUCKETS + bucket;
}

/// Free grammar prior for the single-byte-context table (257 rows): for
/// every rule (A,B), the junction "last byte of A, first byte of B" occurs
/// u[rule] times in the fully expanded text — whether or not that specific
/// junction ever survives to a root boundary. Row 256 (block start) has no
/// grammar-given "previous byte", so it falls back to the marginal
/// distribution of first bytes, weighted by g (also free).
fn buildFreePriorSingle(alloc: std.mem.Allocator, dump: *const Dump, info: []const SymInfo, u: []const u64, g: []const u64) ![]u64 {
    const rows: usize = 257;
    const t = try alloc.alloc(u64, rows * 256);
    @memset(t, SMOOTH_EPS);
    for (dump.rules, 0..) |r, i| {
        const id = 256 + i;
        const w = u[id];
        if (w == 0) continue;
        const ctx = info[r.a].last1;
        const f = info[r.b].first1;
        t[@as(usize, ctx) * 256 + f] += w;
    }
    var marg: [256]u64 = [_]u64{0} ** 256;
    for (0..dump.k) |s| marg[info[s].first1] += g[s];
    for (0..256) |f| t[CTX_START * 256 + f] += marg[f];
    return t;
}

/// Same idea, richer context: (last byte of A, length bucket of A).
fn buildFreePriorRich(alloc: std.mem.Allocator, dump: *const Dump, info: []const SymInfo, u: []const u64, g: []const u64) ![]u64 {
    const rows: usize = 257 * LEN_BUCKETS;
    const t = try alloc.alloc(u64, rows * 256);
    @memset(t, SMOOTH_EPS);
    for (dump.rules, 0..) |r, i| {
        const id = 256 + i;
        const w = u[id];
        if (w == 0) continue;
        const a = info[r.a];
        const ctx_idx = ctx2Index(a.last1, lenBucket(a.len));
        const f = info[r.b].first1;
        t[@as(usize, ctx_idx) * 256 + f] += w;
    }
    var marg: [256]u64 = [_]u64{0} ** 256;
    for (0..dump.k) |s| marg[info[s].first1] += g[s];
    const sentinel_row = ctx2Index(CTX_START, 0);
    for (0..256) |f| t[@as(usize, sentinel_row) * 256 + f] += marg[f];
    return t;
}

/// Real empirical junction counts, measured directly from the actual root
/// sequences (used by X1i, the "pay for a stored table" variant).
fn measureEmpiricalTable(alloc: std.mem.Allocator, dump: *const Dump, info: []const SymInfo) ![]u64 {
    const t = try alloc.alloc(u64, 257 * 256);
    @memset(t, 0);
    for (dump.blocks) |blk| {
        var ctx: u32 = CTX_START;
        for (blk) |s| {
            const f = info[s].first1;
            t[@as(usize, ctx) * 256 + f] += 1;
            ctx = info[s].last1;
        }
    }
    return t;
}

/// Compact real encoding of a 257x256 sparse count table: per row, a 9-bit
/// entry count, then (8-bit column, 8-bit row-scaled-to-byte count) pairs.
/// Not maximally compact (no entropy coding of the entries themselves) but
/// real, lossless-enough-to-drive-the-model, and cheap to reason about.
fn encodeEmpiricalTable(alloc: std.mem.Allocator, t: []const u64) ![]const u8 {
    var enc = rc.Encoder.init(alloc);
    defer enc.deinit();
    var row: usize = 0;
    while (row < 257) : (row += 1) {
        const base = row * 256;
        var maxv: u64 = 0;
        var cnt: u32 = 0;
        for (0..256) |f| {
            if (t[base + f] > 0) {
                cnt += 1;
                maxv = @max(maxv, t[base + f]);
            }
        }
        try enc.encodeDirect(cnt, 9);
        if (cnt == 0) continue;
        for (0..256) |f| {
            const v = t[base + f];
            if (v == 0) continue;
            const scaled: u32 = if (maxv <= 255) @intCast(v) else @intCast(@max(@as(u64, 1), (v * 255) / maxv));
            try enc.encodeDirect(@intCast(f), 8);
            try enc.encodeDirect(scaled, 8);
        }
    }
    const bytes = try enc.finish();
    return try alloc.dupe(u8, bytes);
}

fn decodeEmpiricalTable(alloc: std.mem.Allocator, bytes: []const u8) ![]u32 {
    var dec = rc.Decoder.init(bytes);
    const out = try alloc.alloc(u32, 257 * 256);
    @memset(out, 0);
    var row: usize = 0;
    while (row < 257) : (row += 1) {
        const cnt = dec.decodeDirect(9);
        var i: u32 = 0;
        while (i < cnt) : (i += 1) {
            const f = dec.decodeDirect(8);
            const scaled = dec.decodeDirect(8);
            out[row * 256 + @as(usize, f)] = scaled;
        }
    }
    return out;
}

// ------------------------------------------------------------- Fenwick --

/// Order-statistics Fenwick tree over non-negative u32 counts: prefix sum
/// and "find the index whose interval contains cumulative value v" both in
/// O(log n), point updates in O(log n). Used for every P(s|f) bucket
/// (which can hold tens of thousands of symbols) so the coder never scans
/// more than log2(bucket size) entries.
const Fenwick = struct {
    counts: []u32,
    tree: []u64,
    n: usize,
    top_pow: usize,

    fn init(alloc: std.mem.Allocator, n: usize) !Fenwick {
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

    fn deinit(self: *Fenwick, alloc: std.mem.Allocator) void {
        alloc.free(self.counts);
        alloc.free(self.tree);
    }

    fn build(self: *Fenwick, vals: []const u32) void {
        @memcpy(self.counts, vals);
        @memset(self.tree, 0);
        for (0..self.n) |i| self.tree[i + 1] = vals[i];
        var i: usize = 1;
        while (i <= self.n) : (i += 1) {
            const j = i + lowbit(i);
            if (j <= self.n) self.tree[j] += self.tree[i];
        }
    }

    fn add(self: *Fenwick, idx0: usize, delta: i32) void {
        const newv: i64 = @as(i64, self.counts[idx0]) + delta;
        self.counts[idx0] = @intCast(newv);
        var i = idx0 + 1;
        while (i <= self.n) : (i += lowbit(i)) {
            const nv: i64 = @as(i64, @bitCast(self.tree[i])) + delta;
            self.tree[i] = @bitCast(nv);
        }
    }

    /// Sum of counts[0..idx0).
    fn prefix(self: *const Fenwick, idx0: usize) u64 {
        var i = idx0;
        var s: u64 = 0;
        while (i > 0) : (i -= lowbit(i)) s += self.tree[i];
        return s;
    }

    fn total(self: *const Fenwick) u64 {
        return self.prefix(self.n);
    }

    /// Smallest 0-indexed idx such that prefix(idx+1) > target.
    fn find(self: *const Fenwick, target: u64) usize {
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

/// Symbols bucketed by first byte (or all in bucket 0 for X0/X3's
/// unfactored order-0 model). `local_idx` is a single K-sized array shared
/// across all buckets (each symbol belongs to exactly one bucket).
const BucketSet = struct {
    fenwicks: [256]?Fenwick,
    sym_of: [256][]u32,
    local_idx: []u32,
    alloc: std.mem.Allocator,

    fn deinit(self: *BucketSet) void {
        for (0..256) |f| {
            self.alloc.free(self.sym_of[f]);
            if (self.fenwicks[f]) |*fw| fw.deinit(self.alloc);
        }
        self.alloc.free(self.local_idx);
    }
};

fn buildBucketsByFirstByte(alloc: std.mem.Allocator, info: []const SymInfo, weight: []const u64) !BucketSet {
    const k = info.len;
    var counts: [256]usize = [_]usize{0} ** 256;
    for (0..k) |s| {
        if (weight[s] > 0) counts[info[s].first1] += 1;
    }
    var sym_of: [256][]u32 = undefined;
    for (0..256) |f| sym_of[f] = try alloc.alloc(u32, counts[f]);
    var fill: [256]usize = [_]usize{0} ** 256;
    const local_idx = try alloc.alloc(u32, k);
    @memset(local_idx, 0);
    for (0..k) |s| {
        if (weight[s] > 0) {
            const f = info[s].first1;
            const idx = fill[f];
            fill[f] += 1;
            sym_of[f][idx] = @intCast(s);
            local_idx[s] = @intCast(idx);
        }
    }
    var fenwicks: [256]?Fenwick = [_]?Fenwick{null} ** 256;
    for (0..256) |f| {
        if (counts[f] == 0) continue;
        const vals = try alloc.alloc(u32, counts[f]);
        defer alloc.free(vals);
        for (sym_of[f], 0..) |s, i| vals[i] = u64c(weight[s]);
        var fw = try Fenwick.init(alloc, counts[f]);
        fw.build(vals);
        fenwicks[f] = fw;
    }
    return .{ .fenwicks = fenwicks, .sym_of = sym_of, .local_idx = local_idx, .alloc = alloc };
}

fn buildSingleBucket(alloc: std.mem.Allocator, k: usize, weight: []const u64) !BucketSet {
    var count: usize = 0;
    for (0..k) |s| {
        if (weight[s] > 0) count += 1;
    }
    var sym_of: [256][]u32 = undefined;
    for (0..256) |f| sym_of[f] = try alloc.alloc(u32, if (f == 0) count else 0);
    const local_idx = try alloc.alloc(u32, k);
    @memset(local_idx, 0);
    var idx: usize = 0;
    for (0..k) |s| {
        if (weight[s] > 0) {
            sym_of[0][idx] = @intCast(s);
            local_idx[s] = @intCast(idx);
            idx += 1;
        }
    }
    var fenwicks: [256]?Fenwick = [_]?Fenwick{null} ** 256;
    const vals = try alloc.alloc(u32, count);
    defer alloc.free(vals);
    for (sym_of[0], 0..) |s, i| vals[i] = u64c(weight[s]);
    var fw = try Fenwick.init(alloc, count);
    fw.build(vals);
    fenwicks[0] = fw;
    return .{ .fenwicks = fenwicks, .sym_of = sym_of, .local_idx = local_idx, .alloc = alloc };
}

fn bsEncodeSym(bs: *BucketSet, enc: *rc.Encoder, f: u8, s: u32) !void {
    const fw = &bs.fenwicks[f].?;
    const local = bs.local_idx[s];
    const freq = fw.counts[local];
    const cum = fw.prefix(local);
    const tot = fw.total();
    try enc.encodeFreq(u64c(cum), freq, u64c(tot));
}

fn bsDecodeSym(bs: *BucketSet, dec: *rc.Decoder, f: u8) u32 {
    const fw = &bs.fenwicks[f].?;
    const tot = fw.total();
    const v = dec.decodeFreq(u64c(tot));
    const local = fw.find(v);
    const freq = fw.counts[local];
    const cum = fw.prefix(local);
    dec.consume(u64c(cum), freq);
    return bs.sym_of[f][local];
}

fn bsBoost(bs: *BucketSet, f: u8, s: u32, delta: i32) void {
    const fw = &bs.fenwicks[f].?;
    const local = bs.local_idx[s];
    fw.add(local, delta);
}

// ------------------------------------------------------- P(f|ctx) rows --

const Row = struct {
    counts: [256]u32 = [_]u32{0} ** 256,
    tot: u32 = 0,
};

fn rowStaticFromFlat(flat: []const u64, row_idx: usize) Row {
    var row: Row = .{};
    const base = row_idx * 256;
    var tot: u64 = 0;
    for (0..256) |f| {
        row.counts[f] = u64c(flat[base + f]);
        tot += flat[base + f];
    }
    row.tot = u64c(tot);
    return row;
}

fn rowFromU32Flat(flat: []const u32, row_idx: usize) Row {
    var row: Row = .{};
    const base = row_idx * 256;
    var tot: u32 = 0;
    for (0..256) |f| {
        row.counts[f] = flat[base + f];
        tot += flat[base + f];
    }
    row.tot = tot;
    return row;
}

/// Rescale a grammar-prior row down to a small pseudo-count budget so that
/// a handful of in-block observations (CTX_BUMP each) can meaningfully
/// shift the adaptive distribution, per PLAN's (iii): "counts scaled so
/// the prior has a sensible weight; adaptive increments."
fn rowPriorFromFlat(flat: []const u64, row_idx: usize, target: u32) Row {
    const base = row_idx * 256;
    var sum: u64 = 0;
    for (0..256) |f| sum += flat[base + f];
    var row: Row = .{};
    var tot: u32 = 0;
    for (0..256) |f| {
        const v = flat[base + f];
        const c: u32 = @intCast(@max(@as(u64, 1), (v * target) / sum));
        row.counts[f] = c;
        tot += c;
    }
    row.tot = tot;
    return row;
}

fn rowEncodeF(row: *const Row, enc: *rc.Encoder, f: u8) !void {
    var cum: u32 = 0;
    for (0..f) |i| cum += row.counts[i];
    try enc.encodeFreq(cum, row.counts[f], row.tot);
}

fn rowDecodeF(row: *const Row, dec: *rc.Decoder) u8 {
    const v = dec.decodeFreq(row.tot);
    var cum: u32 = 0;
    var i: usize = 0;
    while (true) : (i += 1) {
        const c = row.counts[i];
        if (v < cum + c) break;
        cum += c;
    }
    dec.consume(cum, row.counts[i]);
    return @intCast(i);
}

fn rowBump(row: *Row, f: u8, amount: u32) void {
    row.counts[f] += amount;
    row.tot += amount;
}

/// Per-block adaptive context state, lazily copied from a static prior and
/// reset to nothing (i.e. back to the prior) at the start of every block —
/// "fresh adaptive state per block, initialised from a shared prior."
const AdaptiveCtx = struct {
    prior: []const Row,
    active: std.AutoHashMapUnmanaged(u32, Row) = .{},
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator, prior: []const Row) AdaptiveCtx {
        return .{ .prior = prior, .alloc = alloc };
    }
    fn deinit(self: *AdaptiveCtx) void {
        self.active.deinit(self.alloc);
    }
    fn resetBlock(self: *AdaptiveCtx) void {
        self.active.clearRetainingCapacity();
    }
    fn getRow(self: *AdaptiveCtx, ctx: u32) !*Row {
        const gop = try self.active.getOrPut(self.alloc, ctx);
        if (!gop.found_existing) gop.value_ptr.* = self.prior[ctx];
        return gop.value_ptr;
    }
};

// ------------------------------------------------------------ variants --

pub const Variant = enum {
    x0,
    x1i,
    x1ii,
    x1iii,
    x2,
    x3,
    x4,

    pub fn parse(s: []const u8) ?Variant {
        inline for (std.meta.fields(Variant)) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

pub const Report = struct {
    payload_bytes: usize = 0,
    table_bytes: usize = 0,
    roots_total: usize = 0,
    blocks: usize = 0,
    decode_ns: u64 = 0,
};

pub fn run(alloc: std.mem.Allocator, io: std.Io, dump: *const Dump, info: []const SymInfo, g: []const u64, u: []const u64, variant: Variant) !Report {
    return switch (variant) {
        .x0 => runX0(alloc, io, dump, info, g),
        .x1i => runX1i(alloc, io, dump, info, g),
        .x1ii => runX1ii(alloc, io, dump, info, g, u),
        .x1iii => runX1iii(alloc, io, dump, info, g, u),
        .x2 => runX2(alloc, io, dump, info, g, u),
        .x3 => runX3(alloc, io, dump, info, g),
        .x4 => runX4(alloc, io, dump, info, g, u),
    };
}

/// X0: static order-0, P(s) = g[s]/M. Single bucket ("bucket 0" holds every
/// used symbol), no context, no adaptation. This is the reference every
/// other variant is measured against.
fn runX0(alloc: std.mem.Allocator, io: std.Io, dump: *const Dump, info: []const SymInfo, g: []const u64) !Report {
    var bs = try buildSingleBucket(alloc, dump.k, g);
    defer bs.deinit();

    var rep: Report = .{ .blocks = dump.blocks.len };
    for (dump.blocks, 0..) |blk, bidx| {
        var enc = rc.Encoder.init(alloc);
        for (blk) |s| try bsEncodeSym(&bs, &enc, 0, s);
        const bytes = try enc.finish();
        const owned = try alloc.dupe(u8, bytes);
        enc.deinit();
        defer alloc.free(owned);
        rep.payload_bytes += owned.len;
        rep.roots_total += blk.len;

        const timer = Timer.start(io);
        var dec = rc.Decoder.init(owned);
        var acc: u64 = 0;
        const target = dump.blockRawLen(bidx);
        var i: usize = 0;
        while (acc < target) : (i += 1) {
            const s = bsDecodeSym(&bs, &dec, 0);
            if (s != blk[i]) return error.RootMismatch;
            acc += info[s].len;
        }
        rep.decode_ns += timer.read();
        if (acc != target or i != blk.len) return error.LengthMismatch;
    }
    return rep;
}

/// X1i: P(f|ctx) from a stored, quantised, real-encoded 257x256 empirical
/// junction table (measured from the actual root sequences). Its bytes are
/// charged once per frame (`table_bytes`), separate from block payloads.
fn runX1i(alloc: std.mem.Allocator, io: std.Io, dump: *const Dump, info: []const SymInfo, g: []const u64) !Report {
    const emp = try measureEmpiricalTable(alloc, dump, info);
    defer alloc.free(emp);
    const table_bytes = try encodeEmpiricalTable(alloc, emp);
    defer alloc.free(table_bytes);
    const recon = try decodeEmpiricalTable(alloc, table_bytes);
    defer alloc.free(recon);

    const rows = try alloc.alloc(Row, 257);
    defer alloc.free(rows);
    for (0..257) |r| rows[r] = rowFromU32Flat(recon, r);

    var bs = try buildBucketsByFirstByte(alloc, info, g);
    defer bs.deinit();

    var rep: Report = .{ .blocks = dump.blocks.len, .table_bytes = table_bytes.len };
    for (dump.blocks, 0..) |blk, bidx| {
        var enc = rc.Encoder.init(alloc);
        var ctx: u32 = CTX_START;
        for (blk) |s| {
            const f = info[s].first1;
            try rowEncodeF(&rows[ctx], &enc, f);
            try bsEncodeSym(&bs, &enc, f, s);
            ctx = info[s].last1;
        }
        const bytes = try enc.finish();
        const owned = try alloc.dupe(u8, bytes);
        enc.deinit();
        defer alloc.free(owned);
        rep.payload_bytes += owned.len;
        rep.roots_total += blk.len;

        const timer = Timer.start(io);
        var dec = rc.Decoder.init(owned);
        var acc: u64 = 0;
        const target = dump.blockRawLen(bidx);
        var ctxd: u32 = CTX_START;
        var i: usize = 0;
        while (acc < target) : (i += 1) {
            const f = rowDecodeF(&rows[ctxd], &dec);
            const s = bsDecodeSym(&bs, &dec, f);
            if (s != blk[i]) return error.RootMismatch;
            acc += info[s].len;
            ctxd = info[s].last1;
        }
        rep.decode_ns += timer.read();
        if (acc != target or i != blk.len) return error.LengthMismatch;
    }
    return rep;
}

/// X1ii: same factorisation, but P(f|ctx) comes from the free grammar-usage
/// prior — zero stored bytes, static for the whole run.
fn runX1ii(alloc: std.mem.Allocator, io: std.Io, dump: *const Dump, info: []const SymInfo, g: []const u64, u: []const u64) !Report {
    const flat = try buildFreePriorSingle(alloc, dump, info, u, g);
    defer alloc.free(flat);
    const rows = try alloc.alloc(Row, 257);
    defer alloc.free(rows);
    for (0..257) |r| rows[r] = rowStaticFromFlat(flat, r);

    var bs = try buildBucketsByFirstByte(alloc, info, g);
    defer bs.deinit();

    var rep: Report = .{ .blocks = dump.blocks.len };
    for (dump.blocks, 0..) |blk, bidx| {
        var enc = rc.Encoder.init(alloc);
        var ctx: u32 = CTX_START;
        for (blk) |s| {
            const f = info[s].first1;
            try rowEncodeF(&rows[ctx], &enc, f);
            try bsEncodeSym(&bs, &enc, f, s);
            ctx = info[s].last1;
        }
        const bytes = try enc.finish();
        const owned = try alloc.dupe(u8, bytes);
        enc.deinit();
        defer alloc.free(owned);
        rep.payload_bytes += owned.len;
        rep.roots_total += blk.len;

        const timer = Timer.start(io);
        var dec = rc.Decoder.init(owned);
        var acc: u64 = 0;
        const target = dump.blockRawLen(bidx);
        var ctxd: u32 = CTX_START;
        var i: usize = 0;
        while (acc < target) : (i += 1) {
            const f = rowDecodeF(&rows[ctxd], &dec);
            const s = bsDecodeSym(&bs, &dec, f);
            if (s != blk[i]) return error.RootMismatch;
            acc += info[s].len;
            ctxd = info[s].last1;
        }
        rep.decode_ns += timer.read();
        if (acc != target or i != blk.len) return error.LengthMismatch;
    }
    return rep;
}

/// X1iii: the free prior again, but rescaled to a small pseudo-count budget
/// and adapted within each block (reset to the prior at every block start).
fn runX1iii(alloc: std.mem.Allocator, io: std.Io, dump: *const Dump, info: []const SymInfo, g: []const u64, u: []const u64) !Report {
    const flat = try buildFreePriorSingle(alloc, dump, info, u, g);
    defer alloc.free(flat);
    const prior_rows = try alloc.alloc(Row, 257);
    defer alloc.free(prior_rows);
    for (0..257) |r| prior_rows[r] = rowPriorFromFlat(flat, r, CTX_PRIOR_TARGET);

    var actx = AdaptiveCtx.init(alloc, prior_rows);
    defer actx.deinit();
    var bs = try buildBucketsByFirstByte(alloc, info, g);
    defer bs.deinit();

    var rep: Report = .{ .blocks = dump.blocks.len };
    for (dump.blocks, 0..) |blk, bidx| {
        actx.resetBlock();
        var enc = rc.Encoder.init(alloc);
        var ctx: u32 = CTX_START;
        for (blk) |s| {
            const f = info[s].first1;
            const row = try actx.getRow(ctx);
            try rowEncodeF(row, &enc, f);
            rowBump(row, f, CTX_BUMP);
            try bsEncodeSym(&bs, &enc, f, s);
            ctx = info[s].last1;
        }
        const bytes = try enc.finish();
        const owned = try alloc.dupe(u8, bytes);
        enc.deinit();
        defer alloc.free(owned);
        rep.payload_bytes += owned.len;
        rep.roots_total += blk.len;

        actx.resetBlock();
        const timer = Timer.start(io);
        var dec = rc.Decoder.init(owned);
        var acc: u64 = 0;
        const target = dump.blockRawLen(bidx);
        var ctxd: u32 = CTX_START;
        var i: usize = 0;
        while (acc < target) : (i += 1) {
            const row = try actx.getRow(ctxd);
            const f = rowDecodeF(row, &dec);
            rowBump(row, f, CTX_BUMP);
            const s = bsDecodeSym(&bs, &dec, f);
            if (s != blk[i]) return error.RootMismatch;
            acc += info[s].len;
            ctxd = info[s].last1;
        }
        rep.decode_ns += timer.read();
        if (acc != target or i != blk.len) return error.LengthMismatch;
    }
    return rep;
}

/// X2: richer context = (last byte, length bucket of the previous root),
/// same free-prior + adaptive machinery as X1iii but a bigger context
/// alphabet (257*6 rows instead of 257) — watches for dilution.
fn runX2(alloc: std.mem.Allocator, io: std.Io, dump: *const Dump, info: []const SymInfo, g: []const u64, u: []const u64) !Report {
    const flat = try buildFreePriorRich(alloc, dump, info, u, g);
    defer alloc.free(flat);
    const num_ctx: usize = 257 * LEN_BUCKETS;
    const prior_rows = try alloc.alloc(Row, num_ctx);
    defer alloc.free(prior_rows);
    for (0..num_ctx) |r| prior_rows[r] = rowPriorFromFlat(flat, r, CTX_PRIOR_TARGET);

    var actx = AdaptiveCtx.init(alloc, prior_rows);
    defer actx.deinit();
    var bs = try buildBucketsByFirstByte(alloc, info, g);
    defer bs.deinit();

    const start_ctx = ctx2Index(CTX_START, 0);

    var rep: Report = .{ .blocks = dump.blocks.len };
    for (dump.blocks, 0..) |blk, bidx| {
        actx.resetBlock();
        var enc = rc.Encoder.init(alloc);
        var ctx: u32 = start_ctx;
        for (blk) |s| {
            const f = info[s].first1;
            const row = try actx.getRow(ctx);
            try rowEncodeF(row, &enc, f);
            rowBump(row, f, CTX_BUMP);
            try bsEncodeSym(&bs, &enc, f, s);
            ctx = ctx2Index(info[s].last1, lenBucket(info[s].len));
        }
        const bytes = try enc.finish();
        const owned = try alloc.dupe(u8, bytes);
        enc.deinit();
        defer alloc.free(owned);
        rep.payload_bytes += owned.len;
        rep.roots_total += blk.len;

        actx.resetBlock();
        const timer = Timer.start(io);
        var dec = rc.Decoder.init(owned);
        var acc: u64 = 0;
        const target = dump.blockRawLen(bidx);
        var ctxd: u32 = start_ctx;
        var i: usize = 0;
        while (acc < target) : (i += 1) {
            const row = try actx.getRow(ctxd);
            const f = rowDecodeF(row, &dec);
            rowBump(row, f, CTX_BUMP);
            const s = bsDecodeSym(&bs, &dec, f);
            if (s != blk[i]) return error.RootMismatch;
            acc += info[s].len;
            ctxd = ctx2Index(info[s].last1, lenBucket(info[s].len));
        }
        rep.decode_ns += timer.read();
        if (acc != target or i != blk.len) return error.LengthMismatch;
    }
    return rep;
}

/// X3: no context factorisation at all; a single global order-0 model
/// whose weights are boosted in-block (P ~ g[s] + n_block[s]*BOOST) to
/// capture local repetition, then the boosts are undone at block end so
/// blocks stay independently decodable.
fn runX3(alloc: std.mem.Allocator, io: std.Io, dump: *const Dump, info: []const SymInfo, g: []const u64) !Report {
    var bs = try buildSingleBucket(alloc, dump.k, g);
    defer bs.deinit();
    var touches: std.ArrayList(u32) = .empty;
    defer touches.deinit(alloc);

    var rep: Report = .{ .blocks = dump.blocks.len };
    for (dump.blocks, 0..) |blk, bidx| {
        touches.clearRetainingCapacity();
        var enc = rc.Encoder.init(alloc);
        for (blk) |s| {
            try bsEncodeSym(&bs, &enc, 0, s);
            bsBoost(&bs, 0, s, BOOST);
            try touches.append(alloc, s);
        }
        for (touches.items) |s| bsBoost(&bs, 0, s, -BOOST);
        const bytes = try enc.finish();
        const owned = try alloc.dupe(u8, bytes);
        enc.deinit();
        defer alloc.free(owned);
        rep.payload_bytes += owned.len;
        rep.roots_total += blk.len;

        touches.clearRetainingCapacity();
        const timer = Timer.start(io);
        var dec = rc.Decoder.init(owned);
        var acc: u64 = 0;
        const target = dump.blockRawLen(bidx);
        var i: usize = 0;
        while (acc < target) : (i += 1) {
            const s = bsDecodeSym(&bs, &dec, 0);
            if (s != blk[i]) return error.RootMismatch;
            bsBoost(&bs, 0, s, BOOST);
            try touches.append(alloc, s);
            acc += info[s].len;
        }
        rep.decode_ns += timer.read();
        for (touches.items) |s| bsBoost(&bs, 0, s, -BOOST);
        if (acc != target or i != blk.len) return error.LengthMismatch;
    }
    return rep;
}

/// X4: X1iii's adaptive single-byte context for P(f|ctx) combined with
/// X3's in-block boost applied to P(s|f) within each bucket.
fn runX4(alloc: std.mem.Allocator, io: std.Io, dump: *const Dump, info: []const SymInfo, g: []const u64, u: []const u64) !Report {
    const flat = try buildFreePriorSingle(alloc, dump, info, u, g);
    defer alloc.free(flat);
    const prior_rows = try alloc.alloc(Row, 257);
    defer alloc.free(prior_rows);
    for (0..257) |r| prior_rows[r] = rowPriorFromFlat(flat, r, CTX_PRIOR_TARGET);

    var actx = AdaptiveCtx.init(alloc, prior_rows);
    defer actx.deinit();
    var bs = try buildBucketsByFirstByte(alloc, info, g);
    defer bs.deinit();

    const Touch = struct { f: u8, s: u32 };
    var touches: std.ArrayList(Touch) = .empty;
    defer touches.deinit(alloc);

    var rep: Report = .{ .blocks = dump.blocks.len };
    for (dump.blocks, 0..) |blk, bidx| {
        actx.resetBlock();
        touches.clearRetainingCapacity();
        var enc = rc.Encoder.init(alloc);
        var ctx: u32 = CTX_START;
        for (blk) |s| {
            const f = info[s].first1;
            const row = try actx.getRow(ctx);
            try rowEncodeF(row, &enc, f);
            rowBump(row, f, CTX_BUMP);
            try bsEncodeSym(&bs, &enc, f, s);
            bsBoost(&bs, f, s, BOOST);
            try touches.append(alloc, .{ .f = f, .s = s });
            ctx = info[s].last1;
        }
        for (touches.items) |t| bsBoost(&bs, t.f, t.s, -BOOST);
        const bytes = try enc.finish();
        const owned = try alloc.dupe(u8, bytes);
        enc.deinit();
        defer alloc.free(owned);
        rep.payload_bytes += owned.len;
        rep.roots_total += blk.len;

        actx.resetBlock();
        touches.clearRetainingCapacity();
        const timer = Timer.start(io);
        var dec = rc.Decoder.init(owned);
        var acc: u64 = 0;
        const target = dump.blockRawLen(bidx);
        var ctxd: u32 = CTX_START;
        var i: usize = 0;
        while (acc < target) : (i += 1) {
            const row = try actx.getRow(ctxd);
            const f = rowDecodeF(row, &dec);
            rowBump(row, f, CTX_BUMP);
            const s = bsDecodeSym(&bs, &dec, f);
            if (s != blk[i]) return error.RootMismatch;
            bsBoost(&bs, f, s, BOOST);
            try touches.append(alloc, .{ .f = f, .s = s });
            acc += info[s].len;
            ctxd = info[s].last1;
        }
        rep.decode_ns += timer.read();
        for (touches.items) |t| bsBoost(&bs, t.f, t.s, -BOOST);
        if (acc != target or i != blk.len) return error.LengthMismatch;
    }
    return rep;
}
