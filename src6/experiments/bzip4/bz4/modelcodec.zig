//! Lane B: how few bits per rule can a REAL, DECODABLE encoding of the pair
//! grammar reach? See PLAN.md and LANE_B.md.
//!
//! The MODEL = the rule DAG (a,b children for every rule, ids 0..255 bytes,
//! 256+i = rule i, children ids always < parent id) + g[s] (root occurrence
//! count) for every symbol 0..255+rule_count-1.
//!
//! encodeModel(dump, variant) -> bytes            (a real range-coded stream)
//! decodeModel(bytes) -> rules', g'               (sees ONLY the bytes)
//!
//! The decoder is free to renumber rules; encodeModel/decodeModel agree on
//! the renumbering implicitly (post-order DEF-tree numbering), so no
//! permutation is ever transmitted. verifyModel() checks, from the outside,
//! that there is a bijection old->new with identical byte expansions and
//! g'[new(s)] == g[s], using structural (Merkle) hashing over the whole rule
//! set plus a byte-level spot check on a sample of rules.
//!
//! Pure Zig 0.16, std only.

const std = @import("std");
const rc = @import("rc.zig");

pub const Rule = struct { a: u32, b: u32 };

/// Set true (e.g. from modellab with a "-v" arg) to print cache/hit-rate
/// diagnostics to stderr during encodeModel. Never affects the wire format.
pub var debug_stats: bool = false;

// ---------------------------------------------------------------- Dump I/O

pub const Dump = struct {
    rule_count: u32,
    block_count: u32,
    block_bytes: u32,
    raw_len: u32,
    rules: []Rule, // old-id indexed: rules[i] is rule (256+i)
    g: []u64, // length 256+rule_count; g[s] = # times s occurs as a root
    alloc: std.mem.Allocator,

    pub fn deinit(self: *Dump) void {
        self.alloc.free(self.rules);
        self.alloc.free(self.g);
    }

    pub fn total(self: *const Dump) usize {
        return 256 + self.rule_count;
    }
};

fn readU32(bytes: []const u8, off: *usize) u32 {
    const v = std.mem.readInt(u32, bytes[off.*..][0..4], .little);
    off.* += 4;
    return v;
}

pub fn readDump(alloc: std.mem.Allocator, bytes: []const u8) !Dump {
    var off: usize = 0;
    const magic = readU32(bytes, &off);
    if (magic != 0x44533442) return error.BadMagic; // "B4SD"
    const version = readU32(bytes, &off);
    if (version != 1) return error.BadVersion;
    const rule_count = readU32(bytes, &off);
    const block_count = readU32(bytes, &off);
    const block_bytes = readU32(bytes, &off);
    const raw_len = readU32(bytes, &off);

    const rules = try alloc.alloc(Rule, rule_count);
    errdefer alloc.free(rules);
    for (0..rule_count) |i| {
        const a = readU32(bytes, &off);
        const b = readU32(bytes, &off);
        std.debug.assert(a < 256 + i and b < 256 + i);
        rules[i] = .{ .a = a, .b = b };
    }

    const total = 256 + @as(usize, rule_count);
    const g = try alloc.alloc(u64, total);
    errdefer alloc.free(g);
    @memset(g, 0);
    for (0..block_count) |_| {
        const root_count = readU32(bytes, &off);
        for (0..root_count) |_| {
            const sym = readU32(bytes, &off);
            std.debug.assert(sym < total);
            g[sym] += 1;
        }
    }

    return .{
        .rule_count = rule_count,
        .block_count = block_count,
        .block_bytes = block_bytes,
        .raw_len = raw_len,
        .rules = rules,
        .g = g,
        .alloc = alloc,
    };
}

// ------------------------------------------------------------------ Variant

pub const Variant = enum(u8) {
    v0_naive = 0,
    v1_creation = 1,
    v2_lex_recency = 2,
    v3_urn = 3,
    v4_slotsplit = 4,
    v5_gctx = 5,
    v1x_urn_isolated = 6, // ablation: urn ref mode alone, same walk/order as v1 (no lex, no recency)
    v2x_gctx_on_freq = 7, // ablation: v2's lex+recency+freq, plus v5's rich g-context (no urn/slot-split overhead)
    v2y_leftchild_order = 8, // ablation: top-level walk ordered by left-child id instead of lex byte prefix

    pub fn name(self: Variant) []const u8 {
        return switch (self) {
            .v0_naive => "v0_naive",
            .v1_creation => "v1_creation",
            .v2_lex_recency => "v2_lex_recency",
            .v3_urn => "v3_urn",
            .v4_slotsplit => "v4_slotsplit",
            .v5_gctx => "v5_gctx",
            .v1x_urn_isolated => "v1x_urn_isolated",
            .v2x_gctx_on_freq => "v2x_gctx_on_freq",
            .v2y_leftchild_order => "v2y_leftchild_order",
        };
    }

    pub fn fromName(s: []const u8) ?Variant {
        inline for (std.meta.fields(Variant)) |f| {
            const v: Variant = @enumFromInt(f.value);
            if (std.mem.eql(u8, s, v.name())) return v;
        }
        return null;
    }
};

const RefMode = enum { freq, urn };
const TopOrder = enum { creation, lex, left_child };

const Config = struct {
    top_order: TopOrder,
    recency: bool,
    ref_mode: RefMode,
    slot_split: bool,
    gctx_rich: bool,
};

fn configFor(v: Variant) Config {
    return switch (v) {
        .v0_naive => .{ .top_order = .creation, .recency = false, .ref_mode = .freq, .slot_split = false, .gctx_rich = false }, // unused: naive has its own path
        .v1_creation => .{ .top_order = .creation, .recency = false, .ref_mode = .freq, .slot_split = false, .gctx_rich = false },
        .v2_lex_recency => .{ .top_order = .lex, .recency = true, .ref_mode = .freq, .slot_split = false, .gctx_rich = false },
        .v3_urn => .{ .top_order = .lex, .recency = true, .ref_mode = .urn, .slot_split = false, .gctx_rich = false },
        .v4_slotsplit => .{ .top_order = .lex, .recency = true, .ref_mode = .urn, .slot_split = true, .gctx_rich = false },
        .v5_gctx => .{ .top_order = .lex, .recency = true, .ref_mode = .urn, .slot_split = true, .gctx_rich = true },
        .v1x_urn_isolated => .{ .top_order = .creation, .recency = false, .ref_mode = .urn, .slot_split = false, .gctx_rich = false },
        .v2x_gctx_on_freq => .{ .top_order = .lex, .recency = true, .ref_mode = .freq, .slot_split = false, .gctx_rich = true },
        .v2y_leftchild_order => .{ .top_order = .left_child, .recency = true, .ref_mode = .freq, .slot_split = false, .gctx_rich = true },
    };
}

// ------------------------------------------------------------------ Fenwick

fn lowbit(i: usize) usize {
    return i & (0 -% i);
}

const Fenwick = struct {
    tree: []i64,
    n: usize,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator, n: usize) !Fenwick {
        const tree = try alloc.alloc(i64, n);
        @memset(tree, 0);
        return .{ .tree = tree, .n = n, .alloc = alloc };
    }

    fn deinit(self: *Fenwick) void {
        self.alloc.free(self.tree);
    }

    fn add(self: *Fenwick, pos0: usize, delta: i64) void {
        if (delta == 0) return;
        var i = pos0 + 1;
        while (i <= self.n) : (i += lowbit(i)) {
            self.tree[i - 1] += delta;
        }
    }

    fn prefixSum(self: *const Fenwick, pos0: usize) i64 {
        var i = pos0;
        var s: i64 = 0;
        while (i > 0) : (i -= lowbit(i)) {
            s += self.tree[i - 1];
        }
        return s;
    }

    fn get(self: *const Fenwick, pos0: usize) i64 {
        return self.prefixSum(pos0 + 1) - self.prefixSum(pos0);
    }

    fn total(self: *const Fenwick) i64 {
        return self.prefixSum(self.n);
    }

    fn highestPow2(n: usize) usize {
        var p: usize = 1;
        while (p * 2 <= n) p *= 2;
        return p;
    }

    /// Smallest index idx (0-based) such that prefixSum(idx+1) > target.
    fn find(self: *const Fenwick, target: i64) usize {
        var idx: usize = 0;
        var rem = target;
        var mask: usize = highestPow2(self.n);
        while (mask != 0) : (mask >>= 1) {
            const next = idx + mask;
            if (next <= self.n and self.tree[next - 1] <= rem) {
                idx = next;
                rem -= self.tree[next - 1];
            }
        }
        return idx;
    }

    /// Rescale all (nonzero) leaf counts by ~1/2, floor 1, to bound totals.
    fn rescale(self: *Fenwick) !void {
        const tmp = try self.alloc.alloc(i64, self.n);
        defer self.alloc.free(tmp);
        for (0..self.n) |i| {
            const v = self.get(i);
            tmp[i] = if (v > 0) @max(@as(i64, 1), @divTrunc(v, 2)) else 0;
        }
        @memcpy(self.tree, tmp);
        var i: usize = 1;
        while (i <= self.n) : (i += 1) {
            const j = i + lowbit(i);
            if (j <= self.n) self.tree[j - 1] += self.tree[i - 1];
        }
    }
};

// ------------------------------------------------------------- RefModel

/// A Fenwick-backed sampler shared by the adaptive-frequency (V1/V2) and
/// urn (V3+) REF models: both are "sample from current counts", they just
/// differ in what `addNew`/`consumeUsage` do to those counts.
const RefModel = struct {
    fw: Fenwick,
    mode: RefMode,
    increment: i64 = 24,
    rescale_at: i64 = 1 << 20,

    fn init(alloc: std.mem.Allocator, n: usize, mode: RefMode) !RefModel {
        return .{ .fw = try Fenwick.init(alloc, n), .mode = mode };
    }
    fn deinit(self: *RefModel) void {
        self.fw.deinit();
    }

    /// Register a symbol becoming available with an initial count.
    /// freq mode: initial_count is ignored, always enters with weight 1.
    fn addNew(self: *RefModel, nid: u32, initial_count: u32) void {
        const w: i64 = switch (self.mode) {
            .freq => 1,
            .urn => @intCast(initial_count),
        };
        self.fw.add(nid, w);
    }

    fn encodeSymbol(self: *const RefModel, enc: *rc.Encoder, nid: u32) !void {
        const cum = self.fw.prefixSum(nid);
        const f = self.fw.get(nid);
        const tot = self.fw.total();
        std.debug.assert(f > 0 and tot > 0);
        try enc.encodeFreq(@intCast(cum), @intCast(f), @intCast(tot));
    }

    /// Returns error.CorruptModel instead of asserting when the Fenwick
    /// pool is empty/negative -- can only happen on corrupted/malformed
    /// input, never on a genuine encoder's own output.
    fn decodeSymbol(self: *const RefModel, dec: *rc.Decoder) !u32 {
        const tot = self.fw.total();
        if (tot <= 0 or tot > std.math.maxInt(u32)) return error.CorruptModel;
        const v = dec.decodeFreq(@intCast(tot));
        const idx = self.fw.find(v);
        const cum = self.fw.prefixSum(idx);
        const f = self.fw.get(idx);
        // f<=0 shouldn't happen given tot>0 and find()'s own invariants, but
        // corrupted cl/cr/c transmissions can drive a urn entry negative
        // (more consumeUsage(-1) calls than the declared count implied);
        // cum is bounded by tot above only when every entry is genuinely
        // non-negative, which corruption need not respect either.
        if (f <= 0 or f > std.math.maxInt(u32)) return error.CorruptModel;
        if (cum < 0 or cum > std.math.maxInt(u32)) return error.CorruptModel;
        dec.consume(@intCast(cum), @intCast(f));
        return @intCast(idx);
    }

    /// Called exactly once for every actual REF use of `nid`, regardless of
    /// whether that use was coded via the recency cache or via this model.
    fn consumeUsage(self: *RefModel, nid: u32) !void {
        switch (self.mode) {
            .freq => {
                self.fw.add(nid, self.increment);
                if (self.fw.total() > self.rescale_at) try self.fw.rescale();
            },
            .urn => {
                self.fw.add(nid, -1);
            },
        }
    }
};

// --------------------------------------------------------------- GammaCtx

/// Adaptive unary-length-prefix + raw-mantissa universal code for u32.
const GammaCtx = struct {
    len_ctx: [33]rc.Bit = .{rc.Bit{}} ** 33,

    fn encode(self: *GammaCtx, enc: *rc.Encoder, v: u32) !void {
        const w = v + 1;
        const nb: u6 = @intCast(32 - @clz(w));
        var pos: u6 = 0;
        while (pos < nb - 1) : (pos += 1) {
            try enc.encodeBit(&self.len_ctx[pos], 1, 5);
        }
        try enc.encodeBit(&self.len_ctx[nb - 1], 0, 5);
        if (nb > 1) {
            const mantissa: u32 = w - (@as(u32, 1) << @intCast(nb - 1));
            try enc.encodeDirect(mantissa, @intCast(nb - 1));
        }
    }

    fn decode(self: *GammaCtx, dec: *rc.Decoder) u32 {
        // A genuine encode never needs nb>32 (v:u32 => w=v+1 fits 32 bits),
        // so cap pos at 31 (nb=pos+1<=32): both to keep corrupted input from
        // walking the unary prefix out of len_ctx, and because nb-1 must fit
        // a u5 shift/direct-bit-count amount (max 31) a few lines below.
        const max_nb: u6 = 32;
        var pos: u6 = 0;
        while (pos < max_nb - 1 and dec.decodeBit(&self.len_ctx[pos], 5) == 1) : (pos += 1) {}
        const nb = pos + 1; // in [1, 32]
        var w: u32 = @as(u32, 1) << @intCast(nb - 1); // nb-1 in [0,31]: fits u5
        if (nb > 1) w += dec.decodeDirect(@intCast(nb - 1));
        return w - 1;
    }
};

/// A count that is very often zero gets a dedicated cheap flag.
const CountCtx = struct {
    zero: rc.Bit = .{},
    gamma: GammaCtx = .{},

    fn encode(self: *CountCtx, enc: *rc.Encoder, v: u32) !void {
        if (v == 0) {
            try enc.encodeBit(&self.zero, 0, 5);
        } else {
            try enc.encodeBit(&self.zero, 1, 5);
            try self.gamma.encode(enc, v - 1);
        }
    }
    fn decode(self: *CountCtx, dec: *rc.Decoder) u32 {
        if (dec.decodeBit(&self.zero, 5) == 0) return 0;
        return self.gamma.decode(dec) + 1;
    }
};

// --------------------------------------------------------------- BitTree

/// Binarize a value in [0, 2^nbits) via an adaptive bit tree.
fn BitTree(comptime nbits: u6) type {
    const size = (1 << nbits) - 1;
    return struct {
        ctx: [size]rc.Bit = .{rc.Bit{}} ** size,

        fn encode(self: *@This(), enc: *rc.Encoder, value: u32) !void {
            var node: usize = 1;
            var bitpos: u6 = nbits;
            while (bitpos > 0) {
                bitpos -= 1;
                const bit: u1 = @intCast((value >> @as(u5, @intCast(bitpos))) & 1);
                try enc.encodeBit(&self.ctx[node - 1], bit, 5);
                node = node * 2 + bit;
            }
        }
        fn decode(self: *@This(), dec: *rc.Decoder) u32 {
            var node: usize = 1;
            var i: u6 = 0;
            while (i < nbits) : (i += 1) {
                const bit = dec.decodeBit(&self.ctx[node - 1], 5);
                node = node * 2 + bit;
            }
            return @intCast(node - (1 << nbits));
        }
    };
}

// ----------------------------------------------------------- RecencyCache

fn RecencyCache(comptime N: usize) type {
    return struct {
        list: [N]u32 = undefined,
        len: usize = 0,

        fn find(self: *const @This(), id: u32) ?usize {
            for (0..self.len) |i| if (self.list[i] == id) return i;
            return null;
        }
        fn touch(self: *@This(), idx: usize) void {
            const id = self.list[idx];
            var i = idx;
            while (i > 0) : (i -= 1) self.list[i] = self.list[i - 1];
            self.list[0] = id;
        }
        fn insertFront(self: *@This(), id: u32) void {
            if (self.find(id)) |idx| {
                self.touch(idx);
                return;
            }
            const n = @min(self.len + 1, N);
            var i = n;
            while (i > 1) : (i -= 1) self.list[i - 1] = self.list[i - 2];
            self.list[0] = id;
            self.len = n;
        }
    };
}

const cache_slots = 64;
const CacheSlotTree = BitTree(6); // log2(64)

// ------------------------------------------------------------ shared state

/// Everything needed to walk the DEF-tree, shared shape for encode/decode.
/// `slot`: 0 = left child, 1 = right child.
const Walker = struct {
    n_total: usize,
    cfg: Config,

    // structure-side models
    flag_ctx: [32]rc.Bit = .{rc.Bit{}} ** 32,
    hit_ctx: [4]rc.Bit = .{rc.Bit{}} ** 4, // ctx = slot
    slot_tree: [2]CacheSlotTree = .{ .{}, .{} },
    cache: [2]RecencyCache(cache_slots) = .{ .{}, .{} }, // index 0 used when !slot_split; both used when slot_split
    ref: [2]RefModel, // index 0 used when !slot_split; both used when slot_split
    c_ctx: CountCtx = .{}, // non-split total c[s]-1 (only for internal defs, always >=1) -- gamma only, no zero flag needed
    c_gamma_internal: GammaCtx = .{},
    cl_ctx: CountCtx = .{}, // slot-split cL[s]
    cr_ctx: CountCtx = .{}, // slot-split cR[s]
    byte_cl_ctx: CountCtx = .{},
    byte_cr_ctx: CountCtx = .{},
    byte_c_ctx: CountCtx = .{},

    // g-side models
    byte_g_ctx: CountCtx = .{},
    g_ctx: [64]CountCtx = .{CountCtx{}} ** 64,

    // per-run bookkeeping (old-id or new-id indexed, filled progressively)
    defined: []bool, // old-id indexed (rules only; bytes implicitly defined)
    newid: []u32, // old-id indexed
    next_new_id: u32 = 256,
    g_known: []u64, // new-id indexed, root counts as they become known
    len_known: []u32, // new-id indexed, expansion length (bytes=1)

    // encoder-only: precomputed whole-grammar usage counts, old-id indexed.
    c_all: []const u32 = &.{},
    cl_all: []const u32 = &.{},
    cr_all: []const u32 = &.{},

    // diagnostics only (stderr report in encodeModel), not part of the wire format.
    stat_refs: u64 = 0,
    stat_hits: u64 = 0,
    stat_byte_refs: u64 = 0,

    fn gCtxIndex(cfg: Config, is_top_level: bool, c_total: u32, left_g_nonzero: bool, len_bucket: bool) usize {
        if (!cfg.gctx_rich) return 0;
        const cbucket: usize = if (c_total == 0) 0 else if (c_total == 1) 1 else if (c_total <= 3) 2 else 3;
        var idx: usize = if (is_top_level) 1 else 0;
        idx = idx * 4 + cbucket;
        idx = idx * 2 + @as(usize, if (left_g_nonzero) 1 else 0);
        idx = idx * 2 + @as(usize, if (len_bucket) 1 else 0);
        return idx;
    }
};

fn leftChildG(w: *const Walker, a: u32) u64 {
    if (a < 256) return w.g_known[a];
    return w.g_known[w.newid[a]];
}
fn leftChildLen(w: *const Walker, a: u32) u32 {
    if (a < 256) return 1;
    return w.len_known[w.newid[a]];
}

// ------------------------------------------------------------------ Header

const Header = struct {
    variant: Variant,
    rule_count: u32,
    struct_len: u32,
    g_len: u32,

    const size = 4 + 1 + 1 + 2 + 4 + 4 + 4;

    fn write(self: Header, buf: []u8) void {
        buf[0] = 'M';
        buf[1] = 'D';
        buf[2] = 'L';
        buf[3] = 'B';
        buf[4] = 1; // format version
        buf[5] = @intFromEnum(self.variant);
        buf[6] = 0;
        buf[7] = 0;
        std.mem.writeInt(u32, buf[8..12], self.rule_count, .little);
        std.mem.writeInt(u32, buf[12..16], self.struct_len, .little);
        std.mem.writeInt(u32, buf[16..20], self.g_len, .little);
    }

    fn read(buf: []const u8) !Header {
        if (buf.len < size) return error.Truncated;
        if (!(buf[0] == 'M' and buf[1] == 'D' and buf[2] == 'L' and buf[3] == 'B')) return error.BadMagic;
        if (buf[4] != 1) return error.BadVersion;
        const variant: Variant = @enumFromInt(buf[5]);
        const rule_count = std.mem.readInt(u32, buf[8..12], .little);
        const struct_len = std.mem.readInt(u32, buf[12..16], .little);
        const g_len = std.mem.readInt(u32, buf[16..20], .little);
        return .{ .variant = variant, .rule_count = rule_count, .struct_len = struct_len, .g_len = g_len };
    }
};

// -------------------------------------------------------------- Model out

pub const ModelBytes = struct {
    bytes: []u8,
    struct_len: u32,
    g_len: u32,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *ModelBytes) void {
        self.alloc.free(self.bytes);
    }
};

pub const DecodedModel = struct {
    variant: Variant,
    rule_count: u32,
    rules: []Rule, // new-id indexed
    g: []u64, // new-id indexed, length 256+rule_count
    alloc: std.mem.Allocator,

    pub fn deinit(self: *DecodedModel) void {
        self.alloc.free(self.rules);
        self.alloc.free(self.g);
    }
};

// ==================================================================
// encodeModel
// ==================================================================

pub fn encodeModel(alloc: std.mem.Allocator, dump: *const Dump, variant: Variant) !ModelBytes {
    if (variant == .v0_naive) return encodeNaive(alloc, dump);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = configFor(variant);
    const n_total = dump.total();
    const r = dump.rule_count;

    var struct_enc = rc.Encoder.init(alloc);
    defer struct_enc.deinit();
    var g_enc = rc.Encoder.init(alloc);
    defer g_enc.deinit();

    var w: Walker = .{
        .n_total = n_total,
        .cfg = cfg,
        .ref = .{
            try RefModel.init(arena, n_total, cfg.ref_mode),
            try RefModel.init(arena, n_total, cfg.ref_mode),
        },
        .defined = try arena.alloc(bool, n_total),
        .newid = try arena.alloc(u32, n_total),
        .g_known = try arena.alloc(u64, n_total),
        .len_known = try arena.alloc(u32, n_total),
    };
    @memset(w.defined, false);
    @memset(w.newid, 0);
    @memset(w.g_known, 0);
    @memset(w.len_known, 0);

    // Compute c[]/cl[]/cr[] (old-id indexed, over the WHOLE grammar) up front.
    var c_all = try arena.alloc(u32, n_total);
    var cl_all = try arena.alloc(u32, n_total);
    var cr_all = try arena.alloc(u32, n_total);
    @memset(c_all, 0);
    @memset(cl_all, 0);
    @memset(cr_all, 0);
    for (dump.rules) |rule| {
        c_all[rule.a] += 1;
        c_all[rule.b] += 1;
        cl_all[rule.a] += 1;
        cr_all[rule.b] += 1;
    }
    w.c_all = c_all;
    w.cl_all = cl_all;
    w.cr_all = cr_all;

    // is_child[] to find the top-level (root) set.
    var is_child = try arena.alloc(bool, n_total);
    @memset(is_child, false);
    for (dump.rules) |rule| {
        is_child[rule.a] = true;
        is_child[rule.b] = true;
    }

    // Bytes: set up g_known/len_known and, for urn modes, transmit c/cl/cr
    // and prime the byte-level ref models before anything else.
    for (0..256) |b| {
        w.newid[b] = @intCast(b);
        w.g_known[b] = dump.g[b];
        w.len_known[b] = 1;
    }
    if (cfg.ref_mode == .urn) {
        if (cfg.slot_split) {
            for (0..256) |b| {
                try w.byte_cl_ctx.encode(&struct_enc, cl_all[b]);
                try w.byte_cr_ctx.encode(&struct_enc, cr_all[b]);
                w.ref[0].addNew(@intCast(b), cl_all[b]);
                w.ref[1].addNew(@intCast(b), cr_all[b]);
            }
        } else {
            for (0..256) |b| {
                try w.byte_c_ctx.encode(&struct_enc, c_all[b]);
                w.ref[0].addNew(@intCast(b), c_all[b]);
            }
        }
    } else {
        for (0..256) |b| w.ref[0].addNew(@intCast(b), 1);
    }
    // Byte root counts, always (own dedicated context).
    for (0..256) |b| try w.byte_g_ctx.encode(&g_enc, @intCast(dump.g[b]));

    // Top-level walk order.
    var top_ids: std.ArrayList(u32) = .empty;
    for (0..r) |i| {
        const id: u32 = @intCast(256 + i);
        if (!is_child[id]) try top_ids.append(arena, id);
    }
    switch (cfg.top_order) {
        .creation => {},
        .lex => std.mem.sort(u32, top_ids.items, dump.rules, lexLessThan),
        .left_child => std.mem.sort(u32, top_ids.items, dump.rules, leftChildLessThan),
    }

    // Walk.
    for (top_ids.items) |id| {
        try encEmitDef(&w, &struct_enc, &g_enc, dump, id, true, 0);
    }

    if (debug_stats) {
        const hit_rate = if (w.stat_refs > 0) @as(f64, @floatFromInt(w.stat_hits)) / @as(f64, @floatFromInt(w.stat_refs)) else 0;
        const byte_rate = if (w.stat_refs > 0) @as(f64, @floatFromInt(w.stat_byte_refs)) / @as(f64, @floatFromInt(w.stat_refs)) else 0;
        std.debug.print("  [diag {s}] top_level={d} refs={d} cache_hit_rate={d:.3} byte_ref_rate={d:.3}\n", .{ variant.name(), top_ids.items.len, w.stat_refs, hit_rate, byte_rate });
    }

    const struct_bytes = try struct_enc.finish();
    const g_bytes = try g_enc.finish();

    var hdr: [Header.size]u8 = undefined;
    Header.write(.{ .variant = variant, .rule_count = r, .struct_len = @intCast(struct_bytes.len), .g_len = @intCast(g_bytes.len) }, &hdr);

    var out = try alloc.alloc(u8, Header.size + struct_bytes.len + g_bytes.len);
    @memcpy(out[0..Header.size], &hdr);
    @memcpy(out[Header.size..][0..struct_bytes.len], struct_bytes);
    @memcpy(out[Header.size + struct_bytes.len ..][0..g_bytes.len], g_bytes);

    return .{ .bytes = out, .struct_len = @intCast(Header.size + struct_bytes.len), .g_len = @intCast(g_bytes.len), .alloc = alloc };
}

/// Extract up to buf.len leading bytes of symbol `s`'s expansion (iterative,
/// stack bound by grammar nesting depth, not size).
fn expansionPrefix(rules: []const Rule, s: u32, buf: []u8) usize {
    var st: [256]u32 = undefined;
    var sp: usize = 0;
    st[sp] = s;
    sp += 1;
    var n: usize = 0;
    while (sp > 0 and n < buf.len) {
        sp -= 1;
        const top = st[sp];
        if (top < 256) {
            buf[n] = @intCast(top);
            n += 1;
        } else if (sp + 2 <= st.len) {
            const rule = rules[top - 256];
            st[sp] = rule.b;
            sp += 1;
            st[sp] = rule.a;
            sp += 1;
        }
    }
    return n;
}

fn lexLessThan(rules: []const Rule, x: u32, y: u32) bool {
    var bx: [16]u8 = undefined;
    var by: [16]u8 = undefined;
    const nx = expansionPrefix(rules, x, &bx);
    const ny = expansionPrefix(rules, y, &by);
    const n = @min(nx, ny);
    const cmp = std.mem.order(u8, bx[0..n], by[0..n]);
    return switch (cmp) {
        .lt => true,
        .gt => false,
        .eq => if (nx != ny) nx < ny else x < y,
    };
}

/// Sort top-level rules by their left child's id (ties by right child, then
/// id): a direct structural clustering signal -- rules sharing the exact
/// same left-child rule (e.g. a common stem) land adjacent, so the shared
/// child is a hot recency-cache entry for the whole run, independent of
/// whether the two expansions happen to agree lexicographically.
fn leftChildLessThan(rules: []const Rule, x: u32, y: u32) bool {
    const rx = rules[x - 256];
    const ry = rules[y - 256];
    if (rx.a != ry.a) return rx.a < ry.a;
    if (rx.b != ry.b) return rx.b < ry.b;
    return x < y;
}

fn refIdx(w: *const Walker, slot: u1) usize {
    return if (w.cfg.slot_split) slot else 0;
}

/// Encode symbol `s` (old id) appearing in the given `slot` of some parent.
/// Returns whether this occurrence was a DEF (true) or a REF (false).
fn encEmit(w: *Walker, senc: *rc.Encoder, genc: *rc.Encoder, dump: *const Dump, s: u32, slot: u1, depth: u32, sibling_was_def: bool) anyerror!bool {
    const is_ref = s < 256 or w.defined[s];
    const dbucket: u32 = @min(depth, 7);
    const fctx = (@as(usize, slot) * 16) + (@as(usize, dbucket) * 2) + @as(usize, if (sibling_was_def) 1 else 0);
    try senc.encodeBit(&w.flag_ctx[fctx], if (is_ref) @as(u1, 0) else 1, 5);

    if (is_ref) {
        const nid = w.newid[s];
        const ri = refIdx(w, slot);
        w.stat_refs += 1;
        if (s < 256) w.stat_byte_refs += 1;
        if (w.cfg.recency) {
            const hctx = slot;
            if (w.cache[ri].find(nid)) |pos| {
                try senc.encodeBit(&w.hit_ctx[hctx], 1, 5);
                try w.slot_tree[ri].encode(senc, @intCast(pos));
                w.cache[ri].touch(pos);
                w.stat_hits += 1;
            } else {
                try senc.encodeBit(&w.hit_ctx[hctx], 0, 5);
                try w.ref[ri].encodeSymbol(senc, nid);
                w.cache[ri].insertFront(nid);
            }
        } else {
            try w.ref[ri].encodeSymbol(senc, nid);
        }
        try w.ref[ri].consumeUsage(nid);
        return false;
    } else {
        try encEmitDef(w, senc, genc, dump, s, false, depth);
        return true;
    }
}

fn encEmitDef(w: *Walker, senc: *rc.Encoder, genc: *rc.Encoder, dump: *const Dump, old_id: u32, is_top_level: bool, depth: u32) anyerror!void {
    const rule = dump.rules[old_id - 256];
    const left_was_def = try encEmit(w, senc, genc, dump, rule.a, 0, depth + 1, false);
    _ = try encEmit(w, senc, genc, dump, rule.b, 1, depth + 1, left_was_def);

    var c_total: u32 = 0;
    var cl: u32 = 0;
    var cr: u32 = 0;
    if (w.cfg.ref_mode == .urn) {
        if (w.cfg.slot_split) {
            cl = w.cl_all[old_id];
            cr = w.cr_all[old_id];
            if (!is_top_level) {
                try w.cl_ctx.encode(senc, cl);
                try w.cr_ctx.encode(senc, cr);
            }
        } else {
            c_total = w.c_all[old_id];
            if (!is_top_level) {
                std.debug.assert(c_total >= 1);
                try w.c_gamma_internal.encode(senc, c_total - 1);
            }
        }
    }

    const gval = dump.g[old_id];
    const nid = w.next_new_id;
    w.next_new_id += 1;
    const cbucket_total: u32 = if (w.cfg.slot_split) cl + cr else c_total;
    const left_g_nonzero = leftChildG(w, rule.a) != 0;
    const len = leftChildLen(w, rule.a) + leftChildLen(w, rule.b);
    const len_bucket = len >= 8;
    const gidx = Walker.gCtxIndex(w.cfg, is_top_level, cbucket_total, left_g_nonzero, len_bucket);
    try w.g_ctx[gidx].encode(genc, @intCast(gval));

    w.newid[old_id] = nid;
    w.defined[old_id] = true;
    w.g_known[nid] = gval;
    w.len_known[nid] = len;

    if (w.cfg.ref_mode == .urn) {
        if (w.cfg.slot_split) {
            w.ref[0].addNew(nid, cl);
            w.ref[1].addNew(nid, cr);
        } else {
            w.ref[0].addNew(nid, c_total);
        }
    } else {
        w.ref[0].addNew(nid, 1);
    }
    if (w.cfg.recency) {
        // A freshly defined symbol is a prime candidate for imminent reuse
        // (e.g. a shared prefix rule about to be referenced by several
        // sibling top-level words); seed the cache(s) now rather than
        // waiting for a first miss to do it.
        w.cache[0].insertFront(nid);
        if (w.cfg.slot_split) w.cache[1].insertFront(nid);
    }
}

// ==================================================================
// decodeModel -- sees ONLY `bytes`.
// ==================================================================

pub fn decodeModel(alloc: std.mem.Allocator, bytes: []const u8) !DecodedModel {
    const hdr = try Header.read(bytes);
    if (hdr.variant == .v0_naive) return decodeNaive(alloc, bytes);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = configFor(hdr.variant);
    const r = hdr.rule_count;
    const n_total = 256 + @as(usize, r);

    const struct_bytes = bytes[Header.size..][0..hdr.struct_len];
    const g_bytes = bytes[Header.size + hdr.struct_len ..][0..hdr.g_len];
    var sdec = rc.Decoder.init(struct_bytes);
    var gdec = rc.Decoder.init(g_bytes);

    var w: Walker = .{
        .n_total = n_total,
        .cfg = cfg,
        .ref = .{
            try RefModel.init(arena, n_total, cfg.ref_mode),
            try RefModel.init(arena, n_total, cfg.ref_mode),
        },
        .defined = try arena.alloc(bool, n_total),
        .newid = try arena.alloc(u32, n_total),
        .g_known = try arena.alloc(u64, n_total),
        .len_known = try arena.alloc(u32, n_total),
    };
    @memset(w.defined, false);
    @memset(w.newid, 0);
    @memset(w.g_known, 0);
    @memset(w.len_known, 0);

    const rules_out = try alloc.alloc(Rule, r);
    errdefer alloc.free(rules_out);
    const g_out = try alloc.alloc(u64, n_total);
    errdefer alloc.free(g_out);
    @memset(g_out, 0);

    for (0..256) |b| {
        w.newid[b] = @intCast(b);
        w.len_known[b] = 1;
    }
    if (cfg.ref_mode == .urn) {
        if (cfg.slot_split) {
            for (0..256) |b| {
                const cl = w.byte_cl_ctx.decode(&sdec);
                const cr = w.byte_cr_ctx.decode(&sdec);
                w.ref[0].addNew(@intCast(b), cl);
                w.ref[1].addNew(@intCast(b), cr);
            }
        } else {
            for (0..256) |b| {
                const c = w.byte_c_ctx.decode(&sdec);
                w.ref[0].addNew(@intCast(b), c);
            }
        }
    } else {
        for (0..256) |b| w.ref[0].addNew(@intCast(b), 1);
    }
    for (0..256) |b| {
        const gv = w.byte_g_ctx.decode(&gdec);
        w.g_known[b] = gv;
        g_out[b] = gv;
    }

    var defined_count: u32 = 0;
    while (defined_count < r) {
        try decEmitDef(&w, &sdec, &gdec, rules_out, g_out, true, 0, &defined_count);
    }

    return .{ .variant = hdr.variant, .rule_count = r, .rules = rules_out, .g = g_out, .alloc = alloc };
}

fn decEmit(w: *Walker, sdec: *rc.Decoder, gdec: *rc.Decoder, rules_out: []Rule, g_out: []u64, slot: u1, depth: u32, sibling_was_def: bool, defined_count: *u32) anyerror!struct { nid: u32, was_def: bool } {
    const dbucket: u32 = @min(depth, 7);
    const fctx = (@as(usize, slot) * 16) + (@as(usize, dbucket) * 2) + @as(usize, if (sibling_was_def) 1 else 0);
    const flag = sdec.decodeBit(&w.flag_ctx[fctx], 5);

    if (flag == 0) {
        // REF
        const ri = refIdx(w, slot);
        var nid: u32 = undefined;
        if (w.cfg.recency) {
            const hctx = slot;
            const hit = sdec.decodeBit(&w.hit_ctx[hctx], 5);
            if (hit == 1) {
                const pos = w.slot_tree[ri].decode(sdec);
                if (pos >= w.cache[ri].len) return error.CorruptModel; // only [0,len) are real entries
                nid = w.cache[ri].list[pos];
                w.cache[ri].touch(pos);
            } else {
                nid = try w.ref[ri].decodeSymbol(sdec);
                w.cache[ri].insertFront(nid);
            }
        } else {
            nid = try w.ref[ri].decodeSymbol(sdec);
        }
        try w.ref[ri].consumeUsage(nid);
        return .{ .nid = nid, .was_def = false };
    } else {
        const nid = try decEmitDefInner(w, sdec, gdec, rules_out, g_out, false, depth, defined_count);
        return .{ .nid = nid, .was_def = true };
    }
}

fn decEmitDef(w: *Walker, sdec: *rc.Decoder, gdec: *rc.Decoder, rules_out: []Rule, g_out: []u64, is_top_level: bool, depth: u32, defined_count: *u32) anyerror!void {
    _ = try decEmitDefInner(w, sdec, gdec, rules_out, g_out, is_top_level, depth, defined_count);
}

fn decEmitDefInner(w: *Walker, sdec: *rc.Decoder, gdec: *rc.Decoder, rules_out: []Rule, g_out: []u64, is_top_level: bool, depth: u32, defined_count: *u32) anyerror!u32 {
    // Every level of DEF-tree nesting consumes a would-be rule id (the
    // caller's own DEF isn't finished, and hence doesn't increment
    // `defined_count`, until this whole subtree resolves), so a genuine
    // encoder's own walk can never need depth greater than rules_out.len
    // (that bound is tight: a single fully-linear reuse chain touching
    // every rule realizes it exactly, as covered by the "big" synthetic
    // grammar test below). On corrupted input, a run of spurious "this is
    // a DEF" flags down a fabricated left spine would otherwise recurse
    // toward a native stack overflow that no `try`/`catch` could
    // intercept -- note a *fixed* depth ceiling isn't enough by itself:
    // for a small dump a corrupted stream can overflow `rules_out` (via
    // `next_new_id`, which -- like `defined_count` -- only advances on
    // completion) long before hitting any generous constant, so the bound
    // must scale with this specific decode's own rule count.
    if (depth >= rules_out.len) return error.CorruptModel;
    // A genuine encoder never asks for more than rules_out.len DEFs total;
    // this catches the (rarer) case of excess *completed* defs without deep
    // nesting, e.g. a wide rather than deep divergence.
    if (defined_count.* >= rules_out.len) return error.CorruptModel;

    const left = try decEmit(w, sdec, gdec, rules_out, g_out, 0, depth + 1, false, defined_count);
    const right = try decEmit(w, sdec, gdec, rules_out, g_out, 1, depth + 1, left.was_def, defined_count);

    var c_total: u32 = 0;
    var cl: u32 = 0;
    var cr: u32 = 0;
    if (w.cfg.ref_mode == .urn) {
        if (w.cfg.slot_split) {
            if (!is_top_level) {
                cl = w.cl_ctx.decode(sdec);
                cr = w.cr_ctx.decode(sdec);
            }
        } else {
            if (!is_top_level) {
                c_total = w.c_gamma_internal.decode(sdec) + 1;
            }
        }
    }

    // The real, non-stale guard: next_new_id is the single shared source of
    // truth and this is the exact point of consumption, so -- unlike the
    // defined_count/depth checks above, which can each be satisfied by
    // several calls still suspended mid-recursion (waiting on a child)
    // before any of them completes -- this always reflects every id
    // actually handed out so far. A corrupted stream where both children
    // routinely look undefined grows the DEF-tree as a full binary tree
    // (up to 2^depth nodes), which can exhaust rules_out at a depth far
    // short of the depth bound above; this is what actually stops it.
    if (w.next_new_id - 256 >= rules_out.len) return error.CorruptModel;
    const nid = w.next_new_id;
    w.next_new_id += 1;
    const cbucket_total: u32 = if (w.cfg.slot_split) cl + cr else c_total;
    const left_g_nonzero = w.g_known[left.nid] != 0;
    const len = w.len_known[left.nid] + w.len_known[right.nid];
    const len_bucket = len >= 8;
    const gidx = Walker.gCtxIndex(w.cfg, is_top_level, cbucket_total, left_g_nonzero, len_bucket);
    const gval = w.g_ctx[gidx].decode(gdec);

    rules_out[nid - 256] = .{ .a = left.nid, .b = right.nid };
    g_out[nid] = gval;
    w.g_known[nid] = gval;
    w.len_known[nid] = len;
    defined_count.* += 1;

    if (w.cfg.ref_mode == .urn) {
        if (w.cfg.slot_split) {
            w.ref[0].addNew(nid, cl);
            w.ref[1].addNew(nid, cr);
        } else {
            w.ref[0].addNew(nid, c_total);
        }
    } else {
        w.ref[0].addNew(nid, 1);
    }
    if (w.cfg.recency) {
        w.cache[0].insertFront(nid);
        if (w.cfg.slot_split) w.cache[1].insertFront(nid);
    }
    return nid;
}

// ==================================================================
// V0 naive baseline: two raw ids per rule, fixed-width g. This is the
// "20-30 bits/rule" reference point the PLAN calls out; every other
// variant should beat it by a wide margin.
// ==================================================================

fn bitsFor(range: u32) u6 {
    if (range <= 1) return 0;
    return @intCast(32 - @clz(range - 1));
}

fn encodeNaive(alloc: std.mem.Allocator, dump: *const Dump) !ModelBytes {
    const r = dump.rule_count;
    var senc = rc.Encoder.init(alloc);
    defer senc.deinit();
    var genc = rc.Encoder.init(alloc);
    defer genc.deinit();

    for (dump.rules, 0..) |rule, i| {
        const range: u32 = @intCast(256 + i);
        const bits = bitsFor(range);
        if (bits > 0) {
            try senc.encodeDirect(rule.a, bits);
            try senc.encodeDirect(rule.b, bits);
        }
    }

    var max_g: u64 = 0;
    for (dump.g) |gv| max_g = @max(max_g, gv);
    const range_g: u32 = @intCast(@min(max_g + 1, @as(u64, std.math.maxInt(u32))));
    const gbits = bitsFor(range_g);
    try genc.encodeDirect(gbits, 6);
    for (dump.g) |gv| try genc.encodeDirect(@intCast(gv), gbits);

    const sbytes = try senc.finish();
    const gbytes = try genc.finish();
    var hdr: [Header.size]u8 = undefined;
    Header.write(.{ .variant = .v0_naive, .rule_count = r, .struct_len = @intCast(sbytes.len), .g_len = @intCast(gbytes.len) }, &hdr);
    const out = try alloc.alloc(u8, Header.size + sbytes.len + gbytes.len);
    @memcpy(out[0..Header.size], &hdr);
    @memcpy(out[Header.size..][0..sbytes.len], sbytes);
    @memcpy(out[Header.size + sbytes.len ..][0..gbytes.len], gbytes);
    return .{ .bytes = out, .struct_len = @intCast(Header.size + sbytes.len), .g_len = @intCast(gbytes.len), .alloc = alloc };
}

fn decodeNaive(alloc: std.mem.Allocator, bytes: []const u8) !DecodedModel {
    const hdr = try Header.read(bytes);
    const r = hdr.rule_count;
    const sbytes = bytes[Header.size..][0..hdr.struct_len];
    const gbytes = bytes[Header.size + hdr.struct_len ..][0..hdr.g_len];
    var sdec = rc.Decoder.init(sbytes);
    var gdec = rc.Decoder.init(gbytes);

    const rules_out = try alloc.alloc(Rule, r);
    errdefer alloc.free(rules_out);
    for (0..r) |i| {
        const range: u32 = @intCast(256 + i);
        const bits = bitsFor(range);
        var a: u32 = 0;
        var b: u32 = 0;
        if (bits > 0) {
            a = sdec.decodeDirect(bits);
            b = sdec.decodeDirect(bits);
        }
        rules_out[i] = .{ .a = a, .b = b };
    }
    const n_total = 256 + @as(usize, r);
    const g_out = try alloc.alloc(u64, n_total);
    errdefer alloc.free(g_out);
    const gbits: u6 = @intCast(gdec.decodeDirect(6));
    for (0..n_total) |i| g_out[i] = gdec.decodeDirect(gbits);

    return .{ .variant = .v0_naive, .rule_count = r, .rules = rules_out, .g = g_out, .alloc = alloc };
}

// ==================================================================
// Verification: a bijection old->new such that every rule's byte
// expansion is identical and g'[new(s)] == g[s], checked from OUTSIDE
// both encoder and decoder using only their public outputs (dump.rules/
// dump.g and decoded.rules/decoded.g). Uses structural (Merkle) hashing
// over every rule plus a byte-level spot check on a sample, per the
// "hash or compare" rule of evidence.
// ==================================================================

fn leafHash(b: u32) u64 {
    const buf = [1]u8{@intCast(b)};
    return std.hash.Wyhash.hash(0xB4B4B4B4B4B4B4B4, &buf);
}

fn nodeHash(lh: u64, ll: u32, rh: u64, rl: u32) u64 {
    var buf: [24]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], lh, .little);
    std.mem.writeInt(u32, buf[8..12], ll, .little);
    std.mem.writeInt(u64, buf[12..20], rh, .little);
    std.mem.writeInt(u32, buf[20..24], rl, .little);
    return std.hash.Wyhash.hash(0xC0FFEEC0FFEE, &buf);
}

const HashLen = struct { hash: []u64, len: []u32 };

fn computeHashes(alloc: std.mem.Allocator, rules: []const Rule) !HashLen {
    const n = 256 + rules.len;
    const h = try alloc.alloc(u64, n);
    const l = try alloc.alloc(u32, n);
    for (0..256) |b| {
        h[b] = leafHash(@intCast(b));
        l[b] = 1;
    }
    for (rules, 0..) |rule, i| {
        const id = 256 + i;
        h[id] = nodeHash(h[rule.a], l[rule.a], h[rule.b], l[rule.b]);
        l[id] = l[rule.a] + l[rule.b];
    }
    return .{ .hash = h, .len = l };
}

fn expandFull(alloc: std.mem.Allocator, rules: []const Rule, s: u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(alloc);
    try stack.append(alloc, s);
    while (stack.items.len > 0) {
        const top = stack.items[stack.items.len - 1];
        stack.items.len -= 1;
        if (top < 256) {
            try out.append(alloc, @intCast(top));
        } else {
            const rule = rules[top - 256];
            try stack.append(alloc, rule.b);
            try stack.append(alloc, rule.a);
        }
    }
    return out.toOwnedSlice(alloc);
}

pub const VerifyResult = struct {
    ok: bool,
    rule_count: u32,
    matched: usize,
    unmatched_old: usize,
    unmatched_new: usize,
    g_mismatches: usize,
    spot_checked: usize,
    spot_mismatches: usize,
};

pub fn verifyModel(alloc: std.mem.Allocator, dump: *const Dump, decoded: *const DecodedModel) !VerifyResult {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (decoded.rule_count != dump.rule_count) {
        return .{ .ok = false, .rule_count = dump.rule_count, .matched = 0, .unmatched_old = dump.rule_count, .unmatched_new = decoded.rule_count, .g_mismatches = 0, .spot_checked = 0, .spot_mismatches = 0 };
    }
    const n_total = dump.total();
    const old_hl = try computeHashes(arena, dump.rules);
    const new_hl = try computeHashes(arena, decoded.rules);

    var buckets = std.AutoHashMap(u64, std.ArrayList(u32)).init(arena);
    for (256..n_total) |old_id| {
        const h = old_hl.hash[old_id];
        const res = try buckets.getOrPut(h);
        if (!res.found_existing) res.value_ptr.* = .empty;
        try res.value_ptr.append(arena, @intCast(old_id));
    }

    const old_to_new = try arena.alloc(?u32, n_total);
    @memset(old_to_new, null);
    var matched: usize = 0;
    var g_mismatches: usize = 0;
    var unmatched_new: usize = 0;

    // Bytes: trivially identity-mapped and always structurally equal.
    for (0..256) |b| {
        old_to_new[b] = @intCast(b);
        if (dump.g[b] != decoded.g[b]) g_mismatches += 1;
    }

    for (256..n_total) |new_id| {
        const h = new_hl.hash[new_id];
        const len = new_hl.len[new_id];
        var found = false;
        if (buckets.getPtr(h)) |list| {
            var found_idx: ?usize = null;
            for (list.items, 0..) |old_id, k| {
                if (old_hl.len[old_id] == len) {
                    found_idx = k;
                    break;
                }
            }
            if (found_idx) |k| {
                const old_id = list.items[k];
                _ = list.swapRemove(k);
                old_to_new[old_id] = @intCast(new_id);
                found = true;
                matched += 1;
                if (dump.g[old_id] != decoded.g[new_id]) g_mismatches += 1;
            }
        }
        if (!found) unmatched_new += 1;
    }

    var unmatched_old: usize = 0;
    var it = buckets.valueIterator();
    while (it.next()) |list| unmatched_old += list.items.len;

    // Spot check: fully expand the 32 largest old rules on both sides via
    // the discovered bijection and compare bytes exactly (guards against
    // hash collisions and logic bugs the hash alone couldn't catch).
    const order = try arena.alloc(u32, dump.rule_count);
    for (0..dump.rule_count) |i| order[i] = @intCast(256 + i);
    std.mem.sort(u32, order, @as([]const u32, old_hl.len), struct {
        fn lt(lens: []const u32, a: u32, b: u32) bool {
            return lens[a] > lens[b];
        }
    }.lt);
    var spot_checked: usize = 0;
    var spot_mismatches: usize = 0;
    const sample_n = @min(order.len, 32);
    for (order[0..sample_n]) |old_id| {
        const nid = old_to_new[old_id] orelse continue;
        const old_bytes = try expandFull(arena, dump.rules, old_id);
        const new_bytes = try expandFull(arena, decoded.rules, nid);
        spot_checked += 1;
        if (!std.mem.eql(u8, old_bytes, new_bytes)) spot_mismatches += 1;
    }

    const ok = (unmatched_old == 0) and (unmatched_new == 0) and (g_mismatches == 0) and (spot_mismatches == 0);
    return .{ .ok = ok, .rule_count = dump.rule_count, .matched = matched, .unmatched_old = unmatched_old, .unmatched_new = unmatched_new, .g_mismatches = g_mismatches, .spot_checked = spot_checked, .spot_mismatches = spot_mismatches };
}

// ==================================================================
// Tests: a hand-built synthetic grammar (no file I/O), so these run with
// plain `zig test modelcodec.zig` anywhere.
// ==================================================================

fn synthDump(alloc: std.mem.Allocator) !Dump {
    // 'a'=97 'b'=98 'c'=99
    //   r0(256) = a b            "ab"     (child of r1, r3)
    //   r1(257) = r0 c           "abc"    (top-level)
    //   r2(258) = a a            "aa"     (child of r4)
    //   r3(259) = r0 r0          "abab"   (top-level)
    //   r4(260) = r2 c           "aac"    (top-level)
    const rules = try alloc.alloc(Rule, 5);
    rules[0] = .{ .a = 97, .b = 98 };
    rules[1] = .{ .a = 256, .b = 99 };
    rules[2] = .{ .a = 97, .b = 97 };
    rules[3] = .{ .a = 256, .b = 256 };
    rules[4] = .{ .a = 258, .b = 99 };
    const n_total = 256 + 5;
    const g = try alloc.alloc(u64, n_total);
    @memset(g, 0);
    g[97] = 5;
    g[99] = 2;
    g[257] = 3;
    g[259] = 1;
    g[260] = 4;
    return .{ .rule_count = 5, .block_count = 1, .block_bytes = 64, .raw_len = 20, .rules = rules, .g = g, .alloc = alloc };
}

test "synthetic grammar roundtrips and verifies for every variant" {
    const alloc = std.testing.allocator;
    var dump = try synthDump(alloc);
    defer dump.deinit();

    inline for (std.meta.fields(Variant)) |f| {
        const v: Variant = @enumFromInt(f.value);
        var model = try encodeModel(alloc, &dump, v);
        defer model.deinit();
        var decoded = try decodeModel(alloc, model.bytes);
        defer decoded.deinit();
        const vr = try verifyModel(alloc, &dump, &decoded);
        errdefer std.debug.print("variant {s} failed: {}\n", .{ v.name(), vr });
        try std.testing.expect(vr.ok);
        try std.testing.expectEqual(dump.rule_count, decoded.rule_count);
    }
}

/// A longer chained grammar (deeper recursion, real cache/REF traffic)
/// so the corruption test below has enough interior bytes to sample,
/// clear of each independent rc sub-stream's trailing flush.
fn synthDumpBig(alloc: std.mem.Allocator, n: usize) !Dump {
    const total_rules = n + 3;
    const rules = try alloc.alloc(Rule, total_rules);
    var prev: u32 = 97; // 'a'
    for (0..n) |i| {
        const byte: u32 = 98 + @as(u32, @intCast(i % 20));
        rules[i] = .{ .a = prev, .b = byte };
        prev = @intCast(256 + i);
    }
    rules[n] = .{ .a = 256, .b = 256 }; // reuse rule 0 twice (top-level)
    rules[n + 1] = .{ .a = @intCast(256 + n / 2), .b = 99 }; // reuse a mid-chain rule (top-level)
    rules[n + 2] = .{ .a = prev, .b = 97 }; // extend the chain once more (top-level)

    const n_total = 256 + total_rules;
    const g = try alloc.alloc(u64, n_total);
    @memset(g, 0);
    g[97] = 3;
    g[256 + n] = 2;
    g[256 + n + 1] = 1;
    g[256 + n + 2] = 5;
    return .{ .rule_count = @intCast(total_rules), .block_count = 1, .block_bytes = 256, .raw_len = 100, .rules = rules, .g = g, .alloc = alloc };
}

test "corrupted model bytes are caught, not silently accepted" {
    const alloc = std.testing.allocator;
    var dump = try synthDumpBig(alloc, 30);
    defer dump.deinit();

    var model = try encodeModel(alloc, &dump, .v2_lex_recency);
    defer model.deinit();

    // Each of the two independent rc sub-streams (structure, g-counts)
    // ends with an 8-byte flush (see rc.Encoder.finish) that carries no
    // information a real decode ever reads -- corrupting it is legitimately
    // a no-op, not a missed detection, so we sample interior bytes only.
    const flush_slack = 8;
    const struct_end = model.struct_len;
    const g_end = model.struct_len + model.g_len;

    var checked: usize = 0;
    var caught: usize = 0;
    var i: usize = Header.size;
    while (i < model.bytes.len) : (i += 1) {
        if (i >= struct_end -| flush_slack and i < struct_end) continue;
        if (i >= g_end -| flush_slack and i < g_end) continue;

        const corrupted = try alloc.dupe(u8, model.bytes);
        defer alloc.free(corrupted);
        corrupted[i] ^= 0xFF;
        checked += 1;

        const decoded_or_err = decodeModel(alloc, corrupted);
        if (decoded_or_err) |decoded_const| {
            var decoded = decoded_const;
            defer decoded.deinit();
            var shape_ok = decoded.rule_count == dump.rule_count;
            if (shape_ok) {
                const vr = try verifyModel(alloc, &dump, &decoded);
                shape_ok = vr.ok;
            }
            if (!shape_ok) caught += 1;
        } else |_| {
            caught += 1; // decode itself rejected the corrupted stream
        }
    }

    try std.testing.expect(checked > 0);
    // Almost every interior byte flip should be caught; a rare one might
    // only perturb an adaptive probability without crossing the interval
    // boundary it lands in, so require the large majority rather than all.
    const rate = @as(f64, @floatFromInt(caught)) / @as(f64, @floatFromInt(checked));
    if (rate < 0.9) std.debug.print("corruption catch rate {d:.3} ({d}/{d} caught)\n", .{ rate, caught, checked });
    try std.testing.expect(rate >= 0.9);
}
