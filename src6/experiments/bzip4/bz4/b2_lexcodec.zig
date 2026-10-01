//! Lane B2: a real, decodable codec for Lane M's n-ary word-like lexicon.
//! See PLAN.md ("Round 3", "B4SD version 2"), LANE_B.md (the pair-grammar
//! DEF-tree codec this generalises), LANE_M.md (the 27-69 bits/entry model
//! codec this replaces), and LANE_B2.md (this lane's notebook).
//!
//! ===================================================================
//! CLEAN INTEGRATOR API (read this and skip the rest of the file)
//! ===================================================================
//!
//!   const b2 = @import("b2_lexcodec.zig");
//!   var enc = try b2.encode(alloc, entries, g, .v8_gseed);  // best on 9/12 dumps, see LANE_B2.md
//!   defer enc.deinit();                                     // {bytes, old_to_new}
//!   var dec = try b2.decode(alloc, enc.bytes);              // {entries, g}
//!   defer dec.deinit();
//!
//! `.v8_gseed` (lex-order DEF-tree + 64-slot recency cache + REF-miss
//! first-byte factorisation + g-seeded REF frequencies + rich g-context)
//! is the best default across the required dumps; `.v6_flat` wins on OMW
//! specifically and `.v9_revlex_gseed` on macho -- LANE_B2.md has the full
//! per-dump table if you want to pick per-corpus rather than one default.
//!
//! `entries[i].children` holds ids: 0..255 = literal bytes, 256+j = entry j
//! (children may reference ANY other entry, forward or back, as long as the
//! whole set is acyclic -- exactly B4SD v2). `g[s]` is the number of times
//! symbol `s` occurs as a corpus/root token (0..255 = bytes, 256+i = entry
//! i), length `256 + entries.len`.
//!
//! `encode` returns the real range-coded MODEL bytes plus `old_to_new`
//! (length `entries.len`: old entry index -> new entry index, i.e. the
//! renumbering the decoder discovers implicitly by replaying the same walk,
//! never transmitted). `decode` is a genuinely separate function: it reads
//! *only* the byte slice (the variant tag lives in a small raw header
//! inside those bytes) and reconstructs a renumbered entry set + `g'`.
//!
//! The decoder is free to re-spell any entry (flatten it to a pure byte
//! run, or keep it compositional) as long as its BYTE EXPANSION is
//! unchanged -- only expansions and g need to survive. `verify()` checks
//! this from outside both functions, using only their public outputs.
//!
//! Pure Zig 0.16, std only. Imports only `rc.zig` (shared, read-only).

const std = @import("std");
const rc = @import("rc.zig");

pub const Entry = struct { children: []const u32 };

/// Set true (e.g. from b2_lab with a "-v" arg) to print cache/hit-rate
/// diagnostics to stderr during `encode`. Never affects the wire format.
pub var debug_stats: bool = false;

pub const EncodeResult = struct {
    bytes: []u8,
    old_to_new: []u32, // length entries.len; old index -> new index (both entry-space, 0-based)
    stats: EncodeStats,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *EncodeResult) void {
        self.alloc.free(self.bytes);
        self.alloc.free(self.old_to_new);
    }
};

pub const EncodeStats = struct {
    struct_bytes: usize,
    g_bytes: usize,
    total_bytes: usize,
    entry_count: usize,
};

pub const DecodeResult = struct {
    entries: []Entry, // new-id indexed (0-based); children reference bytes (0..255) or 256+new_id
    g: []u64, // length 256 + entries.len
    alloc: std.mem.Allocator,

    pub fn deinit(self: *DecodeResult) void {
        for (self.entries) |e| self.alloc.free(e.children);
        self.alloc.free(self.entries);
        self.alloc.free(self.g);
    }
};

/// Encode `entries`/`g` (see field docs above) with the chosen variant into
/// a real byte stream. `entries.len` must equal `g.len - 256`.
pub fn encode(alloc: std.mem.Allocator, entries: []const Entry, g: []const u64, variant: Variant) !EncodeResult {
    std.debug.assert(g.len == 256 + entries.len);
    if (variant == .v0_naive) return encodeNaive(alloc, entries, g);
    return encodeWalk(alloc, entries, g, variant);
}

/// Decode: sees ONLY `bytes`. Returns a fresh entry/g set (possibly
/// re-spelled/re-nested relative to the original -- callers that need the
/// old->new map should keep the one `encode` returned).
pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) !DecodeResult {
    const hdr = try Header.read(bytes);
    if (hdr.variant == .v0_naive) return decodeNaive(alloc, bytes, hdr);
    return decodeWalk(alloc, bytes, hdr);
}

// ===================================================================
// B4SD v2 dump I/O (see PLAN.md)
// ===================================================================

pub const Dump = struct {
    entry_count: u32,
    block_count: u32,
    block_bytes: u32,
    raw_len: u32,
    entries: []Entry, // owned; children slices owned
    g: []u64, // length 256 + entry_count
    alloc: std.mem.Allocator,

    pub fn deinit(self: *Dump) void {
        for (self.entries) |e| self.alloc.free(e.children);
        self.alloc.free(self.entries);
        self.alloc.free(self.g);
    }
};

fn readU32(bytes: []const u8, off: *usize) !u32 {
    if (off.* + 4 > bytes.len) return error.Truncated;
    const v = std.mem.readInt(u32, bytes[off.*..][0..4], .little);
    off.* += 4;
    return v;
}

pub fn readDump(alloc: std.mem.Allocator, bytes: []const u8) !Dump {
    var off: usize = 0;
    const magic = try readU32(bytes, &off);
    if (magic != 0x44533442) return error.BadMagic; // "B4SD"
    const version = try readU32(bytes, &off);
    if (version != 2) return error.BadVersion; // Lane B2 only speaks v2 (n-ary)
    const entry_count = try readU32(bytes, &off);
    const block_count = try readU32(bytes, &off);
    const block_bytes = try readU32(bytes, &off);
    const raw_len = try readU32(bytes, &off);

    const entries = try alloc.alloc(Entry, entry_count);
    errdefer alloc.free(entries);
    var built: usize = 0;
    errdefer for (entries[0..built]) |e| alloc.free(e.children);
    for (0..entry_count) |i| {
        const arity = try readU32(bytes, &off);
        if (arity < 2 or arity > (1 << 24)) return error.BadArity;
        const children = try alloc.alloc(u32, arity);
        errdefer alloc.free(children);
        for (children) |*c| {
            const v = try readU32(bytes, &off);
            if (v >= 256 + entry_count) return error.BadRef;
            c.* = v;
        }
        entries[i] = .{ .children = children };
        built = i + 1;
    }

    const total = 256 + @as(usize, entry_count);
    const g = try alloc.alloc(u64, total);
    errdefer alloc.free(g);
    @memset(g, 0);
    for (0..block_count) |_| {
        const tok_count = try readU32(bytes, &off);
        for (0..tok_count) |_| {
            const sym = try readU32(bytes, &off);
            if (sym >= total) return error.BadSymbol;
            g[sym] += 1;
        }
    }

    return .{
        .entry_count = entry_count,
        .block_count = block_count,
        .block_bytes = block_bytes,
        .raw_len = raw_len,
        .entries = entries,
        .g = g,
        .alloc = alloc,
    };
}

/// Convenience: read a dump and encode it in one call (what `b2_lab` uses).
pub fn encodeDump(alloc: std.mem.Allocator, dump: *const Dump, variant: Variant) !EncodeResult {
    return encode(alloc, dump.entries, dump.g, variant);
}

// ===================================================================
// Expansion utilities: memoised, cycle-safe, iterative (no native
// recursion, so depth is bounded only by available memory, not the call
// stack) -- shared by encoder heuristics and by `verify`.
// ===================================================================

/// Materialise the full byte expansion of every entry. `entries` may
/// contain forward references (B4SD v2 allows children with ids >= the
/// parent's own index) but must be acyclic; a cycle is reported, not
/// looped on.
pub fn materializeAll(alloc: std.mem.Allocator, entries: []const Entry) ![][]u8 {
    const n = entries.len;
    const result = try alloc.alloc([]u8, n);
    errdefer alloc.free(result);
    const color = try alloc.alloc(u8, n); // 0 white, 1 gray, 2 black
    defer alloc.free(color);
    @memset(color, 0);

    const Frame = struct { id: u32, next_child: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(alloc);

    for (0..n) |start_i| {
        if (color[start_i] == 2) continue;
        try stack.append(alloc, .{ .id = @intCast(start_i), .next_child = 0 });
        color[start_i] = 1;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const id = top.id;
            const children = entries[id].children;
            if (top.next_child < children.len) {
                const c = children[top.next_child];
                top.next_child += 1;
                if (c >= 256) {
                    const ci = c - 256;
                    if (ci >= n) return error.BadRef;
                    if (color[ci] == 1) return error.Cycle;
                    if (color[ci] == 0) {
                        color[ci] = 1;
                        try stack.append(alloc, .{ .id = @intCast(ci), .next_child = 0 });
                    }
                }
                continue;
            }
            var buf: std.ArrayList(u8) = .empty;
            for (children) |c| {
                if (c < 256) {
                    try buf.append(alloc, @intCast(c));
                } else {
                    try buf.appendSlice(alloc, result[c - 256]);
                }
            }
            result[id] = try buf.toOwnedSlice(alloc);
            color[id] = 2;
            stack.items.len -= 1;
        }
    }
    return result;
}

fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) i += 1;
    return i;
}

const LexCtx = struct {
    exp: []const []const u8,
    /// Suffix order: compare expansions byte-by-byte from the END rather
    /// than the start, per PLAN.md item 4 ("reverse-lex order"). Clusters
    /// entries by shared SUFFIX (e.g. "running"/"singing"/"walking") the
    /// way plain lex order clusters shared PREFIXES.
    suffix: bool = false,
    fn lt(self: @This(), x: u32, y: u32) bool {
        if (!self.suffix) {
            const cmp = std.mem.order(u8, self.exp[x], self.exp[y]);
            return switch (cmp) {
                .lt => true,
                .gt => false,
                .eq => x < y,
            };
        }
        const ex = self.exp[x];
        const ey = self.exp[y];
        const n = @min(ex.len, ey.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const a = ex[ex.len - 1 - i];
            const b = ey[ey.len - 1 - i];
            if (a != b) return a < b;
        }
        if (ex.len != ey.len) return ex.len < ey.len;
        return x < y;
    }
};

const DescGCtx = struct {
    g: []const u64, // 256+id indexed
    fn lt(self: @This(), x: u32, y: u32) bool {
        const gx = self.g[256 + x];
        const gy = self.g[256 + y];
        if (gx != gy) return gx > gy;
        return x < y;
    }
};

// ===================================================================
// Shared coding primitives (rc.zig-based). Independently written for
// this lane; not shared with modelcodec.zig/m_codec.zig by design (each
// lane owns its files, PLAN.md).
// ===================================================================

const RATE: u4 = 5;

/// Adaptive "zero flag + unary length prefix + raw mantissa" universal
/// code for a non-negative integer up to 2^32-1.
const VarCtx = struct {
    zero: rc.Bit = .{},
    len_bits: [33]rc.Bit = .{rc.Bit{}} ** 33,

    fn encode(self: *VarCtx, enc: *rc.Encoder, value: u64) !void {
        if (value == 0) {
            try enc.encodeBit(&self.zero, 1, RATE);
            return;
        }
        try enc.encodeBit(&self.zero, 0, RATE);
        std.debug.assert(value < (1 << 32));
        const nb: u6 = @intCast(64 - @clz(value));
        var i: u6 = 1;
        while (i < nb) : (i += 1) try enc.encodeBit(&self.len_bits[i], 0, RATE);
        try enc.encodeBit(&self.len_bits[nb], 1, RATE);
        if (nb > 1) {
            const mantissa: u32 = @intCast(value - (@as(u64, 1) << (nb - 1)));
            try enc.encodeDirect(mantissa, nb - 1);
        }
    }

    fn decode(self: *VarCtx, dec: *rc.Decoder) u64 {
        if (dec.decodeBit(&self.zero, RATE) == 1) return 0;
        var nb: u6 = 1;
        while (nb < 32 and dec.decodeBit(&self.len_bits[nb], RATE) == 0) nb += 1;
        const mantissa: u64 = if (nb > 1) dec.decodeDirect(nb - 1) else 0;
        return (@as(u64, 1) << (nb - 1)) | mantissa;
    }
};

/// Rough (not bit-exact) cost estimate for `VarCtx.encode(value)`, used
/// only to steer the flat-vs-composed heuristic in `v6_flat`; never used
/// for real coding, so imprecision cannot cause a mismatch.
fn varCostEstimate(value: u64) f64 {
    if (value == 0) return 0.3;
    const nb: f64 = @floatFromInt(64 - @clz(value | 1));
    return nb * 1.05 + 1.0;
}

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
                try enc.encodeBit(&self.ctx[node - 1], bit, RATE);
                node = node * 2 + bit;
            }
        }
        fn decode(self: *@This(), dec: *rc.Decoder) u32 {
            var node: usize = 1;
            var i: u6 = 0;
            while (i < nbits) : (i += 1) {
                const bit = dec.decodeBit(&self.ctx[node - 1], RATE);
                node = node * 2 + bit;
            }
            return @intCast(node - (1 << nbits));
        }
        fn peekBits(self: *const @This(), value: u32) f64 {
            var node: usize = 1;
            var bitpos: u6 = nbits;
            var bits: f64 = 0;
            while (bitpos > 0) {
                bitpos -= 1;
                const bit: u1 = @intCast((value >> @as(u5, @intCast(bitpos))) & 1);
                const p: f64 = @as(f64, @floatFromInt(self.ctx[node - 1].p)) / 4096.0;
                bits += -std.math.log2(if (bit == 0) @max(p, 1e-6) else @max(1.0 - p, 1e-6));
                node = node * 2 + bit;
            }
            return bits;
        }
    };
}
const BitTree8 = BitTree(8);
const CacheTree = BitTree(6);

/// Last two bytes emitted so far in the expansion currently being built;
/// missing history is padded with 0x00 (a deliberate simplification: a
/// real leading NUL byte will alias the "start of entry" context, but
/// both sides do this identically so it cannot cause a mismatch).
const RunCtx = struct {
    b0: u8 = 0,
    b1: u8 = 0,

    fn push(self: *RunCtx, b: u8) void {
        self.b0 = self.b1;
        self.b1 = b;
    }
    /// Update context from the last two bytes of an already-known
    /// expansion (entries always have length >= 2; defensive for length
    /// 0/1 too, so a corrupted decode can never underflow here).
    fn pushExpansion(self: *RunCtx, exp: []const u8) void {
        if (exp.len >= 2) {
            self.b0 = exp[exp.len - 2];
            self.b1 = exp[exp.len - 1];
        } else if (exp.len == 1) {
            self.push(exp[0]);
        }
    }
};

const ByteModelKind = enum { order0, order1, order2 };

fn ByteCMImpl(comptime order: u3) type {
    const n_ctx: usize = std.math.pow(usize, 256, order);
    return struct {
        trees: []BitTree8,

        fn init(alloc: std.mem.Allocator) !@This() {
            const trees = try alloc.alloc(BitTree8, n_ctx);
            for (trees) |*t| t.* = .{};
            return .{ .trees = trees };
        }
        fn idx(ctx: RunCtx) usize {
            return switch (order) {
                0 => 0,
                1 => @as(usize, ctx.b1),
                2 => @as(usize, ctx.b0) * 256 + @as(usize, ctx.b1),
                else => unreachable,
            };
        }
        fn encode(self: *@This(), enc: *rc.Encoder, ctx: RunCtx, byte: u8) !void {
            try self.trees[idx(ctx)].encode(enc, byte);
        }
        fn decode(self: *@This(), dec: *rc.Decoder, ctx: RunCtx) u8 {
            return @intCast(self.trees[idx(ctx)].decode(dec));
        }
        fn peekBits(self: *@This(), ctx: RunCtx, byte: u8) f64 {
            return self.trees[idx(ctx)].peekBits(byte);
        }
    };
}

const ByteCM = union(ByteModelKind) {
    order0: ByteCMImpl(0),
    order1: ByteCMImpl(1),
    order2: ByteCMImpl(2),

    fn init(alloc: std.mem.Allocator, kind: ByteModelKind) !ByteCM {
        return switch (kind) {
            .order0 => .{ .order0 = try ByteCMImpl(0).init(alloc) },
            .order1 => .{ .order1 = try ByteCMImpl(1).init(alloc) },
            .order2 => .{ .order2 = try ByteCMImpl(2).init(alloc) },
        };
    }
    fn encode(self: *ByteCM, enc: *rc.Encoder, ctx: RunCtx, byte: u8) !void {
        switch (self.*) {
            inline else => |*m| try m.encode(enc, ctx, byte),
        }
    }
    fn decode(self: *ByteCM, dec: *rc.Decoder, ctx: RunCtx) u8 {
        switch (self.*) {
            inline else => |*m| return m.decode(dec, ctx),
        }
    }
    fn peekBits(self: *ByteCM, ctx: RunCtx, byte: u8) f64 {
        switch (self.*) {
            inline else => |*m| return m.peekBits(ctx, byte),
        }
    }
};

// ---------------------------------------------------------------- Fenwick

fn lowbit(i: usize) usize {
    return i & (0 -% i);
}

const Fenwick = struct {
    tree: []i64,
    n: usize,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator, n: usize) !Fenwick {
        const cap = @max(n, 1);
        const tree = try alloc.alloc(i64, cap);
        @memset(tree, 0);
        return .{ .tree = tree, .n = cap, .alloc = alloc };
    }
    fn add(self: *Fenwick, pos0: usize, delta: i64) void {
        if (delta == 0 or pos0 >= self.n) return;
        var i = pos0 + 1;
        while (i <= self.n) : (i += lowbit(i)) self.tree[i - 1] += delta;
    }
    fn prefixSum(self: *const Fenwick, pos0: usize) i64 {
        var i = @min(pos0, self.n);
        var s: i64 = 0;
        while (i > 0) : (i -= lowbit(i)) s += self.tree[i - 1];
        return s;
    }
    fn get(self: *const Fenwick, pos0: usize) i64 {
        if (pos0 >= self.n) return 0;
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

/// Adaptive-frequency REF model over entry ranks (0..entry_count-1).
/// Bytes never pass through here -- they get their own ByteCM.
const RefFreqModel = struct {
    fw: Fenwick,
    increment: i64 = 24,
    rescale_at: i64 = 1 << 20,

    fn init(alloc: std.mem.Allocator, n: usize) !RefFreqModel {
        return .{ .fw = try Fenwick.init(alloc, n) };
    }
    fn addNew(self: *RefFreqModel, rank: u32, weight: i64) void {
        self.fw.add(rank, weight);
    }
    fn encodeSymbol(self: *const RefFreqModel, enc: *rc.Encoder, rank: u32) !void {
        const cum = self.fw.prefixSum(rank);
        const f = self.fw.get(rank);
        const tot = self.fw.total();
        std.debug.assert(f > 0 and tot > 0);
        try enc.encodeFreq(@intCast(cum), @intCast(f), @intCast(tot));
    }
    fn decodeSymbol(self: *const RefFreqModel, dec: *rc.Decoder) !u32 {
        const tot = self.fw.total();
        if (tot <= 0 or tot > std.math.maxInt(u32)) return error.CorruptModel;
        const v = dec.decodeFreq(@intCast(tot));
        const idx = self.fw.find(v);
        if (idx >= self.fw.n) return error.CorruptModel;
        const cum = self.fw.prefixSum(idx);
        const f = self.fw.get(idx);
        if (f <= 0) return error.CorruptModel;
        dec.consume(@intCast(cum), @intCast(f));
        return @intCast(idx);
    }
    fn peekBits(self: *const RefFreqModel, rank: u32) f64 {
        const f = self.fw.get(rank);
        const tot = self.fw.total();
        if (f <= 0 or tot <= 0) return 24; // never used for real coding; generous fallback
        return -std.math.log2(@as(f64, @floatFromInt(f)) / @as(f64, @floatFromInt(tot)));
    }
    fn consumeUsage(self: *RefFreqModel, rank: u32) !void {
        self.fw.add(rank, self.increment);
        if (self.fw.total() > self.rescale_at) try self.fw.rescale();
    }
};

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

/// A count that is very often zero gets a dedicated cheap flag; richer
/// contexts multiplex several of these (N5).
const CountCtx = struct {
    zero: rc.Bit = .{},
    v: VarCtx = .{},
    fn encode(self: *CountCtx, enc: *rc.Encoder, value: u64) !void {
        if (value == 0) {
            try enc.encodeBit(&self.zero, 0, RATE);
        } else {
            try enc.encodeBit(&self.zero, 1, RATE);
            try self.v.encode(enc, value - 1);
        }
    }
    fn decode(self: *CountCtx, dec: *rc.Decoder) u64 {
        if (dec.decodeBit(&self.zero, RATE) == 0) return 0;
        return self.v.decode(dec) + 1;
    }
};

// ===================================================================
// Variants
// ===================================================================

pub const Variant = enum(u8) {
    v0_naive = 0,
    v1_creation = 1,
    v2_lex_mru = 2,
    v3_cm1 = 3,
    v4_cm2 = 4,
    v5_gctx = 5,
    v6_flat = 6,
    v6_nofront = 7,
    v2b_creation_cm2 = 8,
    v7_fb = 9,
    v7_fb_cm2 = 10,
    v7_fb_nocache = 11,
    v8_gseed = 12,
    v8_gseed_nofb = 13,
    v9_revlex_gseed = 14,
    v9_descg_gseed = 15,

    pub fn name(self: Variant) []const u8 {
        return switch (self) {
            .v0_naive => "v0_naive",
            .v1_creation => "v1_creation",
            .v2_lex_mru => "v2_lex_mru",
            .v3_cm1 => "v3_cm1",
            .v4_cm2 => "v4_cm2",
            .v5_gctx => "v5_gctx",
            .v6_flat => "v6_flat",
            .v6_nofront => "v6_nofront",
            .v2b_creation_cm2 => "v2b_creation_cm2",
            .v7_fb => "v7_fb",
            .v7_fb_cm2 => "v7_fb_cm2",
            .v7_fb_nocache => "v7_fb_nocache",
            .v8_gseed => "v8_gseed",
            .v8_gseed_nofb => "v8_gseed_nofb",
            .v9_revlex_gseed => "v9_revlex_gseed",
            .v9_descg_gseed => "v9_descg_gseed",
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

const TopOrder = enum { creation, lex, rev_lex, desc_g };
const SpellMode = enum { composed_only, adaptive_flat };

const Config = struct {
    top_order: TopOrder,
    ref_cache: bool,
    byte_model: ByteModelKind,
    spell_mode: SpellMode,
    front_code: bool,
    gctx_rich: bool,
    ref_first_byte: bool = false,
    ref_weight_by_g: bool = false,
};

fn configFor(v: Variant) Config {
    return switch (v) {
        .v0_naive => .{ .top_order = .creation, .ref_cache = false, .byte_model = .order0, .spell_mode = .composed_only, .front_code = false, .gctx_rich = false }, // unused: naive has its own path
        .v1_creation => .{ .top_order = .creation, .ref_cache = false, .byte_model = .order0, .spell_mode = .composed_only, .front_code = false, .gctx_rich = false },
        .v2_lex_mru => .{ .top_order = .lex, .ref_cache = true, .byte_model = .order0, .spell_mode = .composed_only, .front_code = false, .gctx_rich = false },
        .v3_cm1 => .{ .top_order = .lex, .ref_cache = true, .byte_model = .order1, .spell_mode = .composed_only, .front_code = false, .gctx_rich = false },
        .v4_cm2 => .{ .top_order = .lex, .ref_cache = true, .byte_model = .order2, .spell_mode = .composed_only, .front_code = false, .gctx_rich = false },
        .v5_gctx => .{ .top_order = .lex, .ref_cache = true, .byte_model = .order2, .spell_mode = .composed_only, .front_code = false, .gctx_rich = true },
        .v6_flat => .{ .top_order = .lex, .ref_cache = true, .byte_model = .order2, .spell_mode = .adaptive_flat, .front_code = true, .gctx_rich = true },
        .v6_nofront => .{ .top_order = .lex, .ref_cache = true, .byte_model = .order2, .spell_mode = .adaptive_flat, .front_code = false, .gctx_rich = true },
        .v2b_creation_cm2 => .{ .top_order = .creation, .ref_cache = true, .byte_model = .order2, .spell_mode = .composed_only, .front_code = false, .gctx_rich = false },
        .v7_fb => .{ .top_order = .lex, .ref_cache = true, .byte_model = .order0, .spell_mode = .composed_only, .front_code = false, .gctx_rich = true, .ref_first_byte = true },
        .v7_fb_cm2 => .{ .top_order = .lex, .ref_cache = true, .byte_model = .order2, .spell_mode = .composed_only, .front_code = false, .gctx_rich = true, .ref_first_byte = true },
        .v7_fb_nocache => .{ .top_order = .lex, .ref_cache = false, .byte_model = .order0, .spell_mode = .composed_only, .front_code = false, .gctx_rich = true, .ref_first_byte = true },
        .v8_gseed => .{ .top_order = .lex, .ref_cache = true, .byte_model = .order0, .spell_mode = .composed_only, .front_code = false, .gctx_rich = true, .ref_first_byte = true, .ref_weight_by_g = true },
        .v8_gseed_nofb => .{ .top_order = .lex, .ref_cache = true, .byte_model = .order0, .spell_mode = .composed_only, .front_code = false, .gctx_rich = true, .ref_first_byte = false, .ref_weight_by_g = true },
        .v9_revlex_gseed => .{ .top_order = .rev_lex, .ref_cache = true, .byte_model = .order0, .spell_mode = .composed_only, .front_code = false, .gctx_rich = true, .ref_first_byte = true, .ref_weight_by_g = true },
        .v9_descg_gseed => .{ .top_order = .desc_g, .ref_cache = true, .byte_model = .order0, .spell_mode = .composed_only, .front_code = false, .gctx_rich = true, .ref_first_byte = true, .ref_weight_by_g = true },
    };
}

// ===================================================================
// Header
// ===================================================================

const Header = struct {
    variant: Variant,
    entry_count: u32,
    struct_len: u32,
    g_len: u32,

    const size = 4 + 1 + 1 + 2 + 4 + 4 + 4;

    fn write(self: Header, buf: []u8) void {
        buf[0] = 'B';
        buf[1] = '2';
        buf[2] = 'L';
        buf[3] = 'X';
        buf[4] = 1; // format version
        buf[5] = @intFromEnum(self.variant);
        buf[6] = 0;
        buf[7] = 0;
        std.mem.writeInt(u32, buf[8..12], self.entry_count, .little);
        std.mem.writeInt(u32, buf[12..16], self.struct_len, .little);
        std.mem.writeInt(u32, buf[16..20], self.g_len, .little);
    }
    fn read(buf: []const u8) !Header {
        if (buf.len < size) return error.Truncated;
        if (!(buf[0] == 'B' and buf[1] == '2' and buf[2] == 'L' and buf[3] == 'X')) return error.BadMagic;
        if (buf[4] != 1) return error.BadVersion;
        const variant_tag = buf[5];
        if (variant_tag > @intFromEnum(Variant.v9_descg_gseed)) return error.BadVariant;
        const variant: Variant = @enumFromInt(variant_tag);
        const entry_count = std.mem.readInt(u32, buf[8..12], .little);
        const struct_len = std.mem.readInt(u32, buf[12..16], .little);
        const g_len = std.mem.readInt(u32, buf[16..20], .little);
        return .{ .variant = variant, .entry_count = entry_count, .struct_len = struct_len, .g_len = g_len };
    }
};

// Safety caps applied only on the DECODE side (untrusted bytes). Genuine
// encoder output never comes close to any of these.
const MAX_ENTRY_COUNT: u32 = 20_000_000;
const MAX_ARITY: u64 = 1 << 20;
const MAX_LEN_PER_ENTRY: u64 = 1 << 24; // 16M bytes for one entry's expansion
const MAX_TOTAL_EXPANSION: u64 = 1 << 29; // 512 MiB budget across all entries
const MAX_DEPTH_ABSOLUTE: u32 = 5000;

fn slotBucket(slot: u32) usize {
    return @min(slot, 7);
}
fn depthBucket(depth: u32) usize {
    return @min(depth, 7);
}
fn explenBucket(len: usize) usize {
    if (len < 4) return 0;
    if (len < 8) return 1;
    if (len < 16) return 2;
    return 3;
}
fn gCtxIndex(rich: bool, arity_bucket: usize, explen_bucket: usize, is_top: bool, first_g_nonzero: bool) usize {
    if (!rich) return 0;
    var idx: usize = arity_bucket; // 0..7
    idx = idx * 4 + explen_bucket; // 0..3
    idx = idx * 2 + @as(usize, if (is_top) 1 else 0);
    idx = idx * 2 + @as(usize, if (first_g_nonzero) 1 else 0);
    return idx;
}
const G_CTX_SIZE = 8 * 4 * 2 * 2;

fn avgDefCostEstimate(next_rank: u32) f64 {
    return 3.0 + std.math.log2(@as(f64, @floatFromInt(next_rank + 2)));
}

// ===================================================================
// ENCODE (compositional / adaptive-flat DEF-tree walk)
// ===================================================================

const EncWalker = struct {
    cfg: Config,

    known_ctx: [64]rc.Bit = .{rc.Bit{}} ** 64,
    isbyte_ctx: [64]rc.Bit = .{rc.Bit{}} ** 64,
    hit_ctx: [8]rc.Bit = .{rc.Bit{}} ** 8,
    mode_ctx: [8]rc.Bit = .{rc.Bit{}} ** 8,
    cache_tree: CacheTree = .{},
    cache: RecencyCache(cache_slots) = .{},
    ref: RefFreqModel,
    byte_model: ByteCM,
    arity_ctx: VarCtx = .{},
    shared_ctx: VarCtx = .{},
    suffix_ctx: VarCtx = .{},
    g_ctx: [G_CTX_SIZE]CountCtx = .{CountCtx{}} ** G_CTX_SIZE,

    defined: []bool, // old-entry-index indexed
    newrank: []u32, // old-entry-index indexed -> new rank (0-based)
    g_known_byte: [256]u64 = .{0} ** 256,
    g_known_entry: []u64, // rank indexed
    next_rank: u32 = 0,
    prev_top_expansion: []const u8 = &.{},

    // N4: REF-miss first-byte factorisation (only used when cfg.ref_first_byte).
    // A miss codes the referenced entry's first expansion byte through the
    // SAME byte_model already predicting "what comes next" (context =
    // whatever precedes it in the parent's own spelling), then picks the
    // specific entry among those sharing that first byte via a small
    // per-bucket adaptive-frequency model.
    bucket_ref: []RefFreqModel = &.{}, // len 256 when active
    bucket_next_local: [256]u32 = .{0} ** 256,
    bucket_of_rank: []u8 = &.{}, // rank indexed
    local_rank_of_rank: []u32 = &.{}, // rank indexed

    // diagnostics only (stderr report via debug_stats), never affects the
    // wire format.
    stat_byte: u64 = 0,
    stat_ref_hit: u64 = 0,
    stat_ref_miss: u64 = 0,
    stat_def_inline: u64 = 0,
    stat_flat: u64 = 0,
    stat_composed: u64 = 0,

    fn gValByte(self: *const EncWalker, b: u32) u64 {
        return self.g_known_byte[b];
    }
    fn gValEntry(self: *const EncWalker, oldId: u32) u64 {
        return self.g_known_entry[self.newrank[oldId]];
    }
};

fn encodeWalk(alloc: std.mem.Allocator, entries: []const Entry, g: []const u64, variant: Variant) !EncodeResult {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = configFor(variant);
    const n = entries.len;

    const expansions = try materializeAll(arena, entries);

    var struct_enc = rc.Encoder.init(alloc);
    defer struct_enc.deinit();
    var g_enc = rc.Encoder.init(alloc);
    defer g_enc.deinit();

    var w: EncWalker = .{
        .cfg = cfg,
        .ref = try RefFreqModel.init(arena, n),
        .byte_model = try ByteCM.init(arena, cfg.byte_model),
        .defined = try arena.alloc(bool, n),
        .newrank = try arena.alloc(u32, n),
        .g_known_entry = try arena.alloc(u64, n),
    };
    @memset(w.defined, false);
    @memset(w.newrank, 0);
    @memset(w.g_known_entry, 0);
    for (0..256) |b| w.g_known_byte[b] = g[b];
    if (cfg.ref_first_byte) {
        const buckets = try arena.alloc(RefFreqModel, 256);
        for (buckets) |*b| b.* = try RefFreqModel.init(arena, n);
        w.bucket_ref = buckets;
        w.bucket_of_rank = try arena.alloc(u8, n);
        w.local_rank_of_rank = try arena.alloc(u32, n);
    }

    var byte_g_ctx: CountCtx = .{};
    for (0..256) |b| try byte_g_ctx.encode(&g_enc, g[b]);

    const order = try arena.alloc(u32, n);
    for (0..n) |i| order[i] = @intCast(i);
    switch (cfg.top_order) {
        .creation => {},
        .lex => std.mem.sort(u32, order, LexCtx{ .exp = expansions }, LexCtx.lt),
        .rev_lex => std.mem.sort(u32, order, LexCtx{ .exp = expansions, .suffix = true }, LexCtx.lt),
        .desc_g => std.mem.sort(u32, order, DescGCtx{ .g = g }, DescGCtx.lt),
    }

    for (order) |id| {
        if (w.defined[id]) continue;
        try encEmitDef(&w, &struct_enc, &g_enc, entries, expansions, g, id, true, 0);
    }

    if (debug_stats) {
        const refs = w.stat_ref_hit + w.stat_ref_miss;
        const hit_rate = if (refs > 0) @as(f64, @floatFromInt(w.stat_ref_hit)) / @as(f64, @floatFromInt(refs)) else 0;
        std.debug.print(
            "  [diag {s}] entries={d} bytes={d} ref_hit={d} ref_miss={d} hit_rate={d:.3} def_inline={d} flat={d} composed={d}\n",
            .{ variant.name(), n, w.stat_byte, w.stat_ref_hit, w.stat_ref_miss, hit_rate, w.stat_def_inline, w.stat_flat, w.stat_composed },
        );
    }

    const struct_bytes = try struct_enc.finish();
    const g_bytes = try g_enc.finish();

    var hdr: [Header.size]u8 = undefined;
    Header.write(.{ .variant = variant, .entry_count = @intCast(n), .struct_len = @intCast(struct_bytes.len), .g_len = @intCast(g_bytes.len) }, &hdr);

    const out = try alloc.alloc(u8, Header.size + struct_bytes.len + g_bytes.len);
    @memcpy(out[0..Header.size], &hdr);
    @memcpy(out[Header.size..][0..struct_bytes.len], struct_bytes);
    @memcpy(out[Header.size + struct_bytes.len ..][0..g_bytes.len], g_bytes);

    const old_to_new = try alloc.alloc(u32, n);
    for (0..n) |i| old_to_new[i] = w.newrank[i];

    return .{
        .bytes = out,
        .old_to_new = old_to_new,
        .stats = .{
            .struct_bytes = struct_bytes.len,
            .g_bytes = g_bytes.len,
            .total_bytes = out.len,
            .entry_count = n,
        },
        .alloc = alloc,
    };
}

fn estimateComposedBits(w: *EncWalker, expansions: [][]u8, children: []const u32) f64 {
    var bits: f64 = 0;
    const known_p: f64 = @as(f64, @floatFromInt(w.known_ctx[0].p)) / 4096.0;
    const isbyte_p: f64 = @as(f64, @floatFromInt(w.isbyte_ctx[0].p)) / 4096.0;
    var ctx = RunCtx{};
    for (children) |c| {
        if (c < 256) {
            bits += -std.math.log2(@max(known_p, 1e-6));
            bits += -std.math.log2(@max(isbyte_p, 1e-6));
            bits += w.byte_model.peekBits(ctx, @intCast(c));
            ctx.push(@intCast(c));
        } else {
            const oid = c - 256;
            if (w.defined[oid]) {
                bits += -std.math.log2(@max(known_p, 1e-6));
                bits += -std.math.log2(@max(1.0 - isbyte_p, 1e-6));
                const rank = w.newrank[oid];
                bits += 2.0 + w.ref.peekBits(rank); // +2 as a rough hit/miss-flag stand-in
                ctx.pushExpansion(expansions[oid]);
            } else {
                bits += -std.math.log2(@max(1.0 - known_p, 1e-6));
                bits += avgDefCostEstimate(w.next_rank);
                // ctx unknown for a not-yet-defined child; leave as-is (heuristic only).
            }
        }
    }
    return bits;
}

fn estimateFlatBits(w: *EncWalker, expansion: []const u8, prev_top: []const u8, front_code: bool) f64 {
    const shared: usize = if (front_code) commonPrefixLen(expansion, prev_top) else 0;
    var bits: f64 = varCostEstimate(shared) + varCostEstimate(expansion.len - shared);
    var ctx = RunCtx{};
    ctx.pushExpansion(expansion[0..shared]);
    for (expansion[shared..]) |byte| {
        bits += w.byte_model.peekBits(ctx, byte);
        ctx.push(byte);
    }
    return bits;
}

const EncErr = std.mem.Allocator.Error;

fn encEmitComponent(w: *EncWalker, senc: *rc.Encoder, genc: *rc.Encoder, entries: []const Entry, expansions: [][]u8, g: []const u64, c: u32, slot: u32, depth: u32, ctx: *RunCtx) EncErr!void {
    const kctx = slotBucket(slot) * 8 + depthBucket(depth);
    if (c < 256) {
        try senc.encodeBit(&w.known_ctx[kctx], 0, RATE); // 0 = known (byte/ref), 1 = needs fresh DEF
        try senc.encodeBit(&w.isbyte_ctx[kctx], 0, RATE); // 0 = byte, 1 = entry ref
        try w.byte_model.encode(senc, ctx.*, @intCast(c));
        ctx.push(@intCast(c));
        w.stat_byte += 1;
        return;
    }
    const oid = c - 256;
    if (w.defined[oid]) {
        try senc.encodeBit(&w.known_ctx[kctx], 0, RATE);
        try senc.encodeBit(&w.isbyte_ctx[kctx], 1, RATE);
        const rank = w.newrank[oid];
        var hit = false;
        if (w.cfg.ref_cache) {
            if (w.cache.find(rank)) |pos| {
                try senc.encodeBit(&w.hit_ctx[depthBucket(depth)], 1, RATE);
                try w.cache_tree.encode(senc, @intCast(pos));
                w.cache.touch(pos);
                w.stat_ref_hit += 1;
                hit = true;
            } else {
                try senc.encodeBit(&w.hit_ctx[depthBucket(depth)], 0, RATE);
            }
        }
        if (!hit) {
            if (w.cfg.ref_first_byte) {
                // N4: code the referenced entry's first expansion byte
                // through the SAME byte_model that predicts "what comes
                // next" in the parent's own spelling (context = whatever
                // precedes this component), then pick the specific entry
                // among those sharing that first byte via a small
                // per-bucket adaptive-frequency model.
                const fb = w.bucket_of_rank[rank];
                try w.byte_model.encode(senc, ctx.*, fb);
                try w.bucket_ref[fb].encodeSymbol(senc, w.local_rank_of_rank[rank]);
            } else {
                try w.ref.encodeSymbol(senc, rank);
            }
            if (w.cfg.ref_cache) w.cache.insertFront(rank);
            w.stat_ref_miss += 1;
        }
        // Consume usage regardless of hit/miss so the underlying frequency
        // model (global or per-bucket) tracks true popularity, not just
        // the subset of references that happened to miss the cache.
        if (w.cfg.ref_first_byte) {
            try w.bucket_ref[w.bucket_of_rank[rank]].consumeUsage(w.local_rank_of_rank[rank]);
        } else {
            try w.ref.consumeUsage(rank);
        }
        ctx.pushExpansion(expansions[oid]);
        return;
    }
    try senc.encodeBit(&w.known_ctx[kctx], 1, RATE);
    w.stat_def_inline += 1;
    try encEmitDef(w, senc, genc, entries, expansions, g, oid, false, depth + 1);
    ctx.pushExpansion(expansions[oid]);
}

fn encFlatBody(w: *EncWalker, senc: *rc.Encoder, expansion: []const u8, is_top_level: bool) !void {
    var shared: usize = 0;
    if (w.cfg.front_code and is_top_level) shared = commonPrefixLen(expansion, w.prev_top_expansion);
    try w.shared_ctx.encode(senc, shared);
    try w.suffix_ctx.encode(senc, expansion.len - shared);
    var ctx = RunCtx{};
    ctx.pushExpansion(expansion[0..shared]);
    for (expansion[shared..]) |byte| {
        try w.byte_model.encode(senc, ctx, byte);
        ctx.push(byte);
    }
}

fn encEmitDef(w: *EncWalker, senc: *rc.Encoder, genc: *rc.Encoder, entries: []const Entry, expansions: [][]u8, g: []const u64, id: u32, is_top_level: bool, depth: u32) EncErr!void {
    const children = entries[id].children;
    const expansion = expansions[id];
    var flat = false;
    if (w.cfg.spell_mode == .adaptive_flat) {
        const composed_est = estimateComposedBits(w, expansions, children);
        const flat_est = estimateFlatBits(w, expansion, if (is_top_level) w.prev_top_expansion else &.{}, w.cfg.front_code and is_top_level);
        flat = flat_est < composed_est;
        try senc.encodeBit(&w.mode_ctx[depthBucket(depth)], if (flat) 1 else 0, RATE);
    }

    var first_g_nonzero = false;
    var arity_for_ctx: usize = 0;
    if (flat) {
        w.stat_flat += 1;
        try encFlatBody(w, senc, expansion, is_top_level);
        arity_for_ctx = expansion.len;
    } else {
        w.stat_composed += 1;
        try w.arity_ctx.encode(senc, @as(u64, children.len) - 2);
        var ctx = RunCtx{};
        for (children, 0..) |c, slot| {
            try encEmitComponent(w, senc, genc, entries, expansions, g, c, @intCast(slot), depth, &ctx);
        }
        arity_for_ctx = children.len;
        if (children.len > 0) {
            const c0 = children[0];
            first_g_nonzero = if (c0 < 256) w.gValByte(c0) != 0 else w.gValEntry(c0 - 256) != 0;
        }
    }

    const rank = w.next_rank;
    w.next_rank += 1;
    const gval = g[256 + id];
    const gidx = gCtxIndex(w.cfg.gctx_rich, @min(arity_for_ctx, 7), explenBucket(expansion.len), is_top_level, first_g_nonzero);
    try w.g_ctx[gidx].encode(genc, gval);

    w.newrank[id] = rank;
    w.defined[id] = true;
    w.g_known_entry[rank] = gval;
    // N: seed the REF model's initial weight from g[s] -- unlike Lane B's
    // "urn" trick (LANE_B.md, a net loss there), this costs nothing extra
    // to transmit: g[s] is decoded/known the instant s is defined, well
    // before any later entry can reference it, so both sides can use it
    // as a free, informative prior instead of starting every entry at a
    // uniform weight of 1.
    const seed_weight: i64 = if (w.cfg.ref_weight_by_g) 1 + @as(i64, @intCast(@min(gval, 1 << 24))) else 1;
    w.ref.addNew(rank, seed_weight);
    if (w.cfg.ref_first_byte) {
        const fb = expansion[0];
        const local = w.bucket_next_local[fb];
        w.bucket_next_local[fb] += 1;
        w.bucket_ref[fb].addNew(local, seed_weight);
        w.bucket_of_rank[rank] = fb;
        w.local_rank_of_rank[rank] = local;
    }
    if (w.cfg.ref_cache) w.cache.insertFront(rank);
    if (is_top_level) w.prev_top_expansion = expansion;
}

// ===================================================================
// DECODE -- sees ONLY `bytes`.
// ===================================================================

const DecWalker = struct {
    cfg: Config,
    entry_count: usize,

    known_ctx: [64]rc.Bit = .{rc.Bit{}} ** 64,
    isbyte_ctx: [64]rc.Bit = .{rc.Bit{}} ** 64,
    hit_ctx: [8]rc.Bit = .{rc.Bit{}} ** 8,
    mode_ctx: [8]rc.Bit = .{rc.Bit{}} ** 8,
    cache_tree: CacheTree = .{},
    cache: RecencyCache(cache_slots) = .{},
    ref: RefFreqModel,
    byte_model: ByteCM,
    arity_ctx: VarCtx = .{},
    shared_ctx: VarCtx = .{},
    suffix_ctx: VarCtx = .{},
    g_ctx: [G_CTX_SIZE]CountCtx = .{CountCtx{}} ** G_CTX_SIZE,

    g_known_byte: [256]u64 = .{0} ** 256,
    g_known_entry: []u64,
    expansions: [][]u8, // rank indexed, owned by `alloc`
    children_out: [][]u32, // rank indexed, owned by `alloc`
    next_rank: u32 = 0,
    total_expansion_bytes: u64 = 0,
    prev_top_expansion: []const u8 = &.{},
    alloc: std.mem.Allocator,
    arena: std.mem.Allocator = undefined, // for bucket_members growth (N4)

    // N4 mirror of EncWalker's bucket state (see there for the scheme).
    bucket_ref: []RefFreqModel = &.{},
    bucket_members: []std.ArrayList(u32) = &.{}, // per first-byte value: global ranks in local-rank order
    bucket_next_local: [256]u32 = .{0} ** 256,
    bucket_of_rank: []u8 = &.{}, // rank indexed
    local_rank_of_rank: []u32 = &.{}, // rank indexed
};

fn decodeWalk(alloc: std.mem.Allocator, bytes: []const u8, hdr: Header) !DecodeResult {
    if (hdr.entry_count > MAX_ENTRY_COUNT) return error.CorruptModel;
    const n: usize = hdr.entry_count;
    if (Header.size + @as(usize, hdr.struct_len) + @as(usize, hdr.g_len) > bytes.len) return error.Truncated;
    const struct_bytes = bytes[Header.size..][0..hdr.struct_len];
    const g_bytes = bytes[Header.size + hdr.struct_len ..][0..hdr.g_len];
    var sdec = rc.Decoder.init(struct_bytes);
    var gdec = rc.Decoder.init(g_bytes);

    const cfg = configFor(hdr.variant);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const expansions = try alloc.alloc([]u8, n);
    var expansions_ok = false;
    errdefer if (!expansions_ok) alloc.free(expansions);
    const children_out = try alloc.alloc([]u32, n);
    var children_out_ok = false;
    errdefer if (!children_out_ok) alloc.free(children_out);
    @memset(expansions, &.{});
    @memset(children_out, &.{});

    var dw: DecWalker = .{
        .cfg = cfg,
        .entry_count = n,
        .ref = try RefFreqModel.init(arena, n),
        .byte_model = try ByteCM.init(arena, cfg.byte_model),
        .g_known_entry = try arena.alloc(u64, n),
        .expansions = expansions,
        .children_out = children_out,
        .alloc = alloc,
        .arena = arena,
    };
    @memset(dw.g_known_entry, 0);
    if (cfg.ref_first_byte) {
        const buckets = try arena.alloc(RefFreqModel, 256);
        for (buckets) |*b| b.* = try RefFreqModel.init(arena, n);
        dw.bucket_ref = buckets;
        const members = try arena.alloc(std.ArrayList(u32), 256);
        for (members) |*m| m.* = .empty;
        dw.bucket_members = members;
        dw.bucket_of_rank = try arena.alloc(u8, n);
        dw.local_rank_of_rank = try arena.alloc(u32, n);
    }
    errdefer {
        for (dw.expansions[0..dw.next_rank]) |e| alloc.free(e);
        for (dw.children_out[0..dw.next_rank]) |c| alloc.free(c);
    }

    var byte_g_ctx: CountCtx = .{};
    for (0..256) |b| dw.g_known_byte[b] = byte_g_ctx.decode(&gdec);

    var defined_count: u32 = 0;
    while (defined_count < n) {
        try decEmitDef(&dw, &sdec, &gdec, true, 0, &defined_count);
    }

    expansions_ok = true;
    children_out_ok = true;
    const entries_out = try alloc.alloc(Entry, n);
    for (0..n) |r| entries_out[r] = .{ .children = children_out[r] };
    alloc.free(children_out); // spine only; inner slices now owned by entries_out

    const g_out = try alloc.alloc(u64, 256 + n);
    for (0..256) |b| g_out[b] = dw.g_known_byte[b];
    for (0..n) |r| g_out[256 + r] = dw.g_known_entry[r];

    for (expansions) |e| alloc.free(e);
    alloc.free(expansions);

    return .{ .entries = entries_out, .g = g_out, .alloc = alloc };
}

const DecErr = error{ CorruptModel, Oversize } || std.mem.Allocator.Error;

fn decEmitComponent(dw: *DecWalker, sdec: *rc.Decoder, gdec: *rc.Decoder, slot: u32, depth: u32, ctx: *RunCtx, defined_count: *u32) DecErr!u32 {
    const kctx = slotBucket(slot) * 8 + depthBucket(depth);
    const need_def = sdec.decodeBit(&dw.known_ctx[kctx], RATE);
    if (need_def == 1) {
        const nid = try decEmitDefInner(dw, sdec, gdec, false, depth + 1, defined_count);
        ctx.pushExpansion(dw.expansions[nid]);
        return 256 + nid;
    }
    const is_byte = sdec.decodeBit(&dw.isbyte_ctx[kctx], RATE);
    if (is_byte == 0) {
        const b = dw.byte_model.decode(sdec, ctx.*);
        ctx.push(b);
        return b;
    }
    var rank: u32 = undefined;
    var hit = false;
    if (dw.cfg.ref_cache) {
        const h = sdec.decodeBit(&dw.hit_ctx[depthBucket(depth)], RATE);
        if (h == 1) {
            const pos = dw.cache_tree.decode(sdec);
            if (pos >= dw.cache.len) return error.CorruptModel;
            rank = dw.cache.list[pos];
            dw.cache.touch(pos);
            hit = true;
        }
    }
    if (!hit) {
        if (dw.cfg.ref_first_byte) {
            const fb = dw.byte_model.decode(sdec, ctx.*);
            const local = try dw.bucket_ref[fb].decodeSymbol(sdec);
            if (local >= dw.bucket_members[fb].items.len) return error.CorruptModel;
            rank = dw.bucket_members[fb].items[local];
        } else {
            rank = try dw.ref.decodeSymbol(sdec);
        }
        if (rank >= dw.next_rank) return error.CorruptModel;
        if (dw.cfg.ref_cache) dw.cache.insertFront(rank);
    }
    if (rank >= dw.next_rank) return error.CorruptModel;
    if (dw.cfg.ref_first_byte) {
        try dw.bucket_ref[dw.bucket_of_rank[rank]].consumeUsage(dw.local_rank_of_rank[rank]);
    } else {
        try dw.ref.consumeUsage(rank);
    }
    ctx.pushExpansion(dw.expansions[rank]);
    return 256 + rank;
}

fn decEmitDef(dw: *DecWalker, sdec: *rc.Decoder, gdec: *rc.Decoder, is_top_level: bool, depth: u32, defined_count: *u32) DecErr!void {
    _ = try decEmitDefInner(dw, sdec, gdec, is_top_level, depth, defined_count);
}

fn decEmitDefInner(dw: *DecWalker, sdec: *rc.Decoder, gdec: *rc.Decoder, is_top_level: bool, depth: u32, defined_count: *u32) DecErr!u32 {
    // Two guards, deliberately at two different points (mirrors LANE_B.md's
    // own hard-won fix for the identical bug class in the pair-grammar
    // codec): `defined_count`/`depth` here catch runaway recursion early,
    // but several recursive calls can be simultaneously "in flight" (each
    // waiting on a child) before any of them completes, so a check here
    // against `dw.next_rank` can be stale -- nested calls may consume many
    // ranks between this check and the point where THIS call finally claims
    // its own rank. The real, non-stale guard is right before `rank :=
    // next_rank` below, at the exact point of consumption.
    if (depth >= @min(@as(u32, @intCast(@min(dw.entry_count + 1, std.math.maxInt(u32)))), MAX_DEPTH_ABSOLUTE)) return error.CorruptModel;
    if (defined_count.* >= dw.entry_count) return error.CorruptModel;

    var flat = false;
    if (dw.cfg.spell_mode == .adaptive_flat) {
        flat = sdec.decodeBit(&dw.mode_ctx[depthBucket(depth)], RATE) == 1;
    }

    var expansion: []u8 = undefined;
    var children_ids: []u32 = undefined;
    var first_g_nonzero = false;
    var arity_for_ctx: usize = 0;

    if (flat) {
        const shared: usize = @intCast(dw.shared_ctx.decode(sdec));
        const suffix: usize = @intCast(dw.suffix_ctx.decode(sdec));
        if (shared > MAX_LEN_PER_ENTRY or suffix > MAX_LEN_PER_ENTRY) return error.CorruptModel;
        if (shared > dw.prev_top_expansion.len) return error.CorruptModel;
        const total_len = shared + suffix;
        if (total_len < 2 or @as(u64, total_len) > MAX_LEN_PER_ENTRY) return error.CorruptModel;
        dw.total_expansion_bytes += total_len;
        if (dw.total_expansion_bytes > MAX_TOTAL_EXPANSION) return error.Oversize;
        const buf = try dw.alloc.alloc(u8, total_len);
        errdefer dw.alloc.free(buf);
        @memcpy(buf[0..shared], dw.prev_top_expansion[0..shared]);
        var ctx = RunCtx{};
        ctx.pushExpansion(buf[0..shared]);
        for (buf[shared..]) |*slot| {
            const byte = dw.byte_model.decode(sdec, ctx);
            slot.* = byte;
            ctx.push(byte);
        }
        expansion = buf;
        children_ids = try dw.alloc.alloc(u32, total_len);
        for (children_ids, 0..) |*c, i| c.* = expansion[i];
        arity_for_ctx = total_len;
    } else {
        const arity: u64 = dw.arity_ctx.decode(sdec) + 2;
        if (arity < 2 or arity > MAX_ARITY) return error.CorruptModel;
        const arity_u: usize = @intCast(arity);
        arity_for_ctx = arity_u;
        children_ids = try dw.alloc.alloc(u32, arity_u);
        errdefer dw.alloc.free(children_ids);
        var ctx = RunCtx{};
        var total_len: u64 = 0;
        for (children_ids, 0..) |*c, slot| {
            const cid = try decEmitComponent(dw, sdec, gdec, @intCast(slot), depth, &ctx, defined_count);
            c.* = cid;
            total_len += if (cid < 256) 1 else dw.expansions[cid - 256].len;
            if (total_len > MAX_LEN_PER_ENTRY) return error.Oversize;
        }
        dw.total_expansion_bytes += total_len;
        if (dw.total_expansion_bytes > MAX_TOTAL_EXPANSION) return error.Oversize;
        const buf = try dw.alloc.alloc(u8, @intCast(total_len));
        errdefer dw.alloc.free(buf);
        var off: usize = 0;
        for (children_ids) |cid| {
            if (cid < 256) {
                buf[off] = @intCast(cid);
                off += 1;
            } else {
                const sub = dw.expansions[cid - 256];
                @memcpy(buf[off..][0..sub.len], sub);
                off += sub.len;
            }
        }
        expansion = buf;
        if (children_ids.len > 0) {
            const c0 = children_ids[0];
            first_g_nonzero = if (c0 < 256) dw.g_known_byte[c0] != 0 else dw.g_known_entry[c0 - 256] != 0;
        }
    }

    // Non-stale guard: this is the exact point of consumption of the one
    // shared `next_rank` counter, so it reflects every id actually handed
    // out so far, unlike the entry checks above. NOTE: `expansion` and
    // `children_ids` were allocated inside the (now-exited) if/flat else
    // block above, so their `errdefer`s are no longer active here (Zig
    // scopes errdefer to its enclosing block, not the whole function) --
    // free them explicitly on this path instead of relying on unwind.
    if (dw.next_rank >= dw.entry_count) {
        dw.alloc.free(expansion);
        dw.alloc.free(children_ids);
        return error.CorruptModel;
    }
    const rank = dw.next_rank;
    dw.next_rank += 1;
    const gidx = gCtxIndex(dw.cfg.gctx_rich, @min(arity_for_ctx, 7), explenBucket(expansion.len), is_top_level, first_g_nonzero);
    const gval = dw.g_ctx[gidx].decode(gdec);

    dw.g_known_entry[rank] = gval;
    dw.expansions[rank] = expansion;
    dw.children_out[rank] = children_ids;
    const seed_weight: i64 = if (dw.cfg.ref_weight_by_g) 1 + @as(i64, @intCast(@min(gval, 1 << 24))) else 1;
    dw.ref.addNew(rank, seed_weight);
    if (dw.cfg.ref_first_byte) {
        const fb = expansion[0];
        const local = dw.bucket_next_local[fb];
        dw.bucket_next_local[fb] += 1;
        dw.bucket_ref[fb].addNew(local, seed_weight);
        try dw.bucket_members[fb].append(dw.arena, rank);
        dw.bucket_of_rank[rank] = fb;
        dw.local_rank_of_rank[rank] = local;
    }
    if (dw.cfg.ref_cache) dw.cache.insertFront(rank);
    if (is_top_level) dw.prev_top_expansion = expansion;
    defined_count.* += 1;
    return rank;
}

// ===================================================================
// V0 naive baseline (n-ary): fixed-width arity + fixed-width child ids,
// fixed-width g. The "throw everything away" reference point.
// ===================================================================

fn bitsFor(range: u32) u6 {
    if (range <= 1) return 0;
    return @intCast(32 - @clz(range - 1));
}

fn encodeNaive(alloc: std.mem.Allocator, entries: []const Entry, g: []const u64) !EncodeResult {
    const n = entries.len;
    var max_arity: u32 = 2;
    for (entries) |e| max_arity = @max(max_arity, @as(u32, @intCast(e.children.len)));
    const arity_bits = bitsFor(max_arity + 1);
    // Fixed width over the WHOLE id alphabet (0..256+n-1): unlike Lane B's
    // v1 format, B4SD v2 allows forward references (a child id >= the
    // parent's own index), so a per-entry "growing range" width (valid
    // only when children are always numerically smaller) would silently
    // truncate a forward-referencing child id.
    const id_bits = bitsFor(@intCast(256 + n));

    var senc = rc.Encoder.init(alloc);
    defer senc.deinit();
    var genc = rc.Encoder.init(alloc);
    defer genc.deinit();

    try senc.encodeDirect(arity_bits, 6);
    try senc.encodeDirect(max_arity, 32);
    for (entries) |e| {
        try senc.encodeDirect(@intCast(e.children.len), arity_bits);
        for (e.children) |c| {
            if (id_bits > 0) try senc.encodeDirect(c, id_bits);
        }
    }

    var max_g: u64 = 0;
    for (g) |gv| max_g = @max(max_g, gv);
    const range_g: u32 = @intCast(@min(max_g + 1, @as(u64, std.math.maxInt(u32))));
    const gbits = bitsFor(range_g);
    try genc.encodeDirect(gbits, 6);
    for (g) |gv| try genc.encodeDirect(@intCast(gv), gbits);

    const sbytes = try senc.finish();
    const gbytes = try genc.finish();
    var hdr: [Header.size]u8 = undefined;
    Header.write(.{ .variant = .v0_naive, .entry_count = @intCast(n), .struct_len = @intCast(sbytes.len), .g_len = @intCast(gbytes.len) }, &hdr);
    const out = try alloc.alloc(u8, Header.size + sbytes.len + gbytes.len);
    @memcpy(out[0..Header.size], &hdr);
    @memcpy(out[Header.size..][0..sbytes.len], sbytes);
    @memcpy(out[Header.size + sbytes.len ..][0..gbytes.len], gbytes);

    const old_to_new = try alloc.alloc(u32, n);
    for (0..n) |i| old_to_new[i] = @intCast(i); // naive: identity renumbering

    return .{
        .bytes = out,
        .old_to_new = old_to_new,
        .stats = .{ .struct_bytes = sbytes.len, .g_bytes = gbytes.len, .total_bytes = out.len, .entry_count = n },
        .alloc = alloc,
    };
}

fn decodeNaive(alloc: std.mem.Allocator, bytes: []const u8, hdr: Header) !DecodeResult {
    if (hdr.entry_count > MAX_ENTRY_COUNT) return error.CorruptModel;
    const n: usize = hdr.entry_count;
    if (Header.size + @as(usize, hdr.struct_len) + @as(usize, hdr.g_len) > bytes.len) return error.Truncated;
    const sbytes = bytes[Header.size..][0..hdr.struct_len];
    const gbytes = bytes[Header.size + hdr.struct_len ..][0..hdr.g_len];
    var sdec = rc.Decoder.init(sbytes);
    var gdec = rc.Decoder.init(gbytes);

    const arity_bits: u6 = @intCast(sdec.decodeDirect(6));
    if (arity_bits > 32) return error.CorruptModel;
    const max_arity = sdec.decodeDirect(32);
    if (max_arity > MAX_ARITY) return error.CorruptModel;
    const id_bits = bitsFor(@intCast(256 + n));

    const entries_out = try alloc.alloc(Entry, n);
    var built: usize = 0;
    errdefer {
        for (entries_out[0..built]) |e| alloc.free(e.children);
        alloc.free(entries_out);
    }
    for (0..n) |i| {
        const arity = sdec.decodeDirect(arity_bits);
        if (arity < 2 or arity > MAX_ARITY) return error.CorruptModel;
        const children = try alloc.alloc(u32, arity);
        for (children) |*c| {
            c.* = if (id_bits > 0) sdec.decodeDirect(id_bits) else 0;
            if (c.* >= 256 + n) return error.CorruptModel;
        }
        entries_out[i] = .{ .children = children };
        built = i + 1;
    }

    const gbits: u6 = @intCast(gdec.decodeDirect(6));
    if (gbits > 32) return error.CorruptModel;
    const g_out = try alloc.alloc(u64, 256 + n);
    for (0..256 + n) |i| g_out[i] = gdec.decodeDirect(gbits);

    return .{ .entries = entries_out, .g = g_out, .alloc = alloc };
}

// ===================================================================
// verify: bijection old->new by FLATTENED BYTE EXPANSION (not structural
// hash -- the decoder is explicitly allowed to re-nest/flatten), plus
// g'[new(s)] == g[s], plus a byte-exact spot check on a sample.
// ===================================================================

pub const VerifyResult = struct {
    ok: bool,
    entry_count: usize,
    matched: usize,
    unmatched_old: usize,
    unmatched_new: usize,
    g_mismatches: usize,
    spot_checked: usize,
    spot_mismatches: usize,
};

fn flatHash(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0xB2B2B2B2B2B2B2B2, bytes);
}

pub fn verify(alloc: std.mem.Allocator, orig_entries: []const Entry, orig_g: []const u64, dec_entries: []const Entry, dec_g: []const u64) !VerifyResult {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (dec_entries.len != orig_entries.len) {
        return .{ .ok = false, .entry_count = orig_entries.len, .matched = 0, .unmatched_old = orig_entries.len, .unmatched_new = dec_entries.len, .g_mismatches = 0, .spot_checked = 0, .spot_mismatches = 0 };
    }
    const n = orig_entries.len;
    const orig_exp = try materializeAll(arena, orig_entries);
    const dec_exp = try materializeAll(arena, dec_entries);

    var g_mismatches: usize = 0;
    for (0..256) |b| {
        if (orig_g[b] != dec_g[b]) g_mismatches += 1;
    }

    var buckets = std.AutoHashMap(u64, std.ArrayList(u32)).init(arena);
    for (0..n) |i| {
        const h = flatHash(orig_exp[i]);
        const res = try buckets.getOrPut(h);
        if (!res.found_existing) res.value_ptr.* = .empty;
        try res.value_ptr.append(arena, @intCast(i));
    }

    const old_to_new = try arena.alloc(?u32, n);
    @memset(old_to_new, null);
    var matched: usize = 0;
    var unmatched_new: usize = 0;

    for (0..n) |new_id| {
        const h = flatHash(dec_exp[new_id]);
        var found = false;
        if (buckets.getPtr(h)) |list| {
            var found_idx: ?usize = null;
            for (list.items, 0..) |old_id, k| {
                if (std.mem.eql(u8, orig_exp[old_id], dec_exp[new_id])) {
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
                if (orig_g[256 + old_id] != dec_g[256 + new_id]) g_mismatches += 1;
            }
        }
        if (!found) unmatched_new += 1;
    }

    var unmatched_old: usize = 0;
    var it = buckets.valueIterator();
    while (it.next()) |list| unmatched_old += list.items.len;

    // Spot check: byte-compare the 32 longest old entries via the
    // discovered bijection (guards against hash collisions).
    const order = try arena.alloc(u32, n);
    for (0..n) |i| order[i] = @intCast(i);
    std.mem.sort(u32, order, orig_exp, struct {
        fn lt(exp: [][]u8, a: u32, b: u32) bool {
            return exp[a].len > exp[b].len;
        }
    }.lt);
    var spot_checked: usize = 0;
    var spot_mismatches: usize = 0;
    for (order[0..@min(order.len, 32)]) |old_id| {
        const nid = old_to_new[old_id] orelse continue;
        spot_checked += 1;
        if (!std.mem.eql(u8, orig_exp[old_id], dec_exp[nid])) spot_mismatches += 1;
    }

    const ok = (unmatched_old == 0) and (unmatched_new == 0) and (g_mismatches == 0) and (spot_mismatches == 0);
    return .{ .ok = ok, .entry_count = n, .matched = matched, .unmatched_old = unmatched_old, .unmatched_new = unmatched_new, .g_mismatches = g_mismatches, .spot_checked = spot_checked, .spot_mismatches = spot_mismatches };
}

// ===================================================================
// Tests
// ===================================================================

fn freeEntries(alloc: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| alloc.free(e.children);
    alloc.free(entries);
}

/// A small synthetic n-ary lexicon (no file I/O): bytes -> small entries ->
/// bigger entries, with reuse and one forward reference, mirroring B4SD v2.
fn synthEntries(alloc: std.mem.Allocator) ![]Entry {
    // e0 = "ab"        (a,b)                     used by e1, e3, e5
    // e1 = "abc"       (e0, 'c')                 top-level
    // e2 = "aa"        (a,a)                     used by e4
    // e3 = "abab"      (e0, e5)                  top-level; forward ref to e5!
    // e4 = "aac"       (e2, 'c')                 top-level
    // e5 = "ab"        (e0, ) -- arity>=2, so e5 = (e0) alone is invalid;
    //                  make e5 an independent 2-byte entry instead.
    const a: u32 = 'a';
    const b: u32 = 'b';
    const c: u32 = 'c';
    const entries = try alloc.alloc(Entry, 6);
    entries[0] = .{ .children = try alloc.dupe(u32, &.{ a, b }) }; // e0 "ab"
    entries[1] = .{ .children = try alloc.dupe(u32, &.{ 256 + 0, c }) }; // e1 "abc"
    entries[2] = .{ .children = try alloc.dupe(u32, &.{ a, a }) }; // e2 "aa"
    entries[3] = .{ .children = try alloc.dupe(u32, &.{ 256 + 0, 256 + 5 }) }; // e3 "abab" (forward ref)
    entries[4] = .{ .children = try alloc.dupe(u32, &.{ 256 + 2, c }) }; // e4 "aac"
    entries[5] = .{ .children = try alloc.dupe(u32, &.{ a, b }) }; // e5 "ab" (independent)
    return entries;
}

fn synthG(alloc: std.mem.Allocator, n: usize) ![]u64 {
    const g = try alloc.alloc(u64, 256 + n);
    @memset(g, 0);
    g['a'] = 5;
    g['c'] = 2;
    g[256 + 1] = 3; // e1
    g[256 + 3] = 1; // e3
    g[256 + 4] = 4; // e4
    return g;
}

test "synthetic n-ary lexicon roundtrips and verifies for every variant" {
    const alloc = std.testing.allocator;
    const entries = try synthEntries(alloc);
    defer freeEntries(alloc, entries);
    const g = try synthG(alloc, entries.len);
    defer alloc.free(g);

    inline for (std.meta.fields(Variant)) |f| {
        const v: Variant = @enumFromInt(f.value);
        var enc = try encode(alloc, entries, g, v);
        defer enc.deinit();
        var dec = try decode(alloc, enc.bytes);
        defer dec.deinit();
        const vr = try verify(alloc, entries, g, dec.entries, dec.g);
        errdefer std.debug.print("variant {s} failed: {}\n", .{ v.name(), vr });
        try std.testing.expect(vr.ok);
        try std.testing.expectEqual(entries.len, dec.entries.len);
    }
}

/// A longer chained lexicon (deeper reuse, real cache/REF/CM traffic, some
/// forward refs) for the corruption-fuzz test below.
fn synthEntriesBig(alloc: std.mem.Allocator, n: usize) ![]Entry {
    const total = n + 4;
    const entries = try alloc.alloc(Entry, total);
    var prev: u32 = 'a';
    for (0..n) |i| {
        const byte: u32 = 'b' + @as(u32, @intCast(i % 20));
        entries[i] = .{ .children = try alloc.dupe(u32, &.{ prev, byte }) };
        prev = @intCast(256 + i);
    }
    entries[n] = .{ .children = try alloc.dupe(u32, &.{ 256 + 0, 256 + 0, 'z' }) }; // reuse + 3-ary
    entries[n + 1] = .{ .children = try alloc.dupe(u32, &.{ @as(u32, @intCast(256 + (n / 2))), 'q' }) };
    entries[n + 2] = .{ .children = try alloc.dupe(u32, &.{ prev, 'a', @as(u32, @intCast(256 + (n + 3))) }) }; // forward ref
    entries[n + 3] = .{ .children = try alloc.dupe(u32, &.{ 'x', 'y' }) };
    return entries;
}

test "corrupted model bytes are caught, not silently accepted (n-ary, all variants, 1000+ trials)" {
    const alloc = std.testing.allocator;
    const entries = try synthEntriesBig(alloc, 40);
    defer freeEntries(alloc, entries);
    const g = try alloc.alloc(u64, 256 + entries.len);
    defer alloc.free(g);
    @memset(g, 0);
    g['a'] = 3;
    g[256 + 40] = 2;
    g[256 + 41] = 1;
    g[256 + 42] = 5;
    g[256 + 43] = 7;

    const variants = [_]Variant{ .v1_creation, .v2_lex_mru, .v4_cm2, .v5_gctx, .v6_flat, .v7_fb, .v7_fb_cm2, .v7_fb_nocache, .v8_gseed, .v8_gseed_nofb, .v9_revlex_gseed, .v9_descg_gseed };
    var total_trials: usize = 0;
    for (variants) |v| {
        var enc = try encode(alloc, entries, g, v);
        defer enc.deinit();

        var prng = std.Random.DefaultPrng.init(0xB2FA55 ^ @as(u64, @intFromEnum(v)));
        const rnd = prng.random();
        var trials: usize = 0;
        while (trials < 200) : (trials += 1) {
            total_trials += 1;
            const corrupted = try alloc.dupe(u8, enc.bytes);
            defer alloc.free(corrupted);
            if (corrupted.len > Header.size + 1) {
                const nflips = 1 + rnd.uintLessThan(u32, 4);
                for (0..nflips) |_| {
                    const byte_i = Header.size + rnd.uintLessThan(usize, corrupted.len - Header.size);
                    const bit_i: u3 = @intCast(rnd.uintLessThan(u8, 8));
                    corrupted[byte_i] ^= (@as(u8, 1) << bit_i);
                }
            }
            const result = decode(alloc, corrupted);
            if (result) |decoded_const| {
                var decoded = decoded_const;
                defer decoded.deinit();
                for (decoded.entries) |e| try std.testing.expect(e.children.len <= MAX_ARITY);
            } else |_| {}
        }

        // Truncation trials: cut the stream at random points.
        var t: usize = 0;
        while (t < 50) : (t += 1) {
            total_trials += 1;
            const cut = rnd.uintLessThan(usize, enc.bytes.len + 1);
            if (decode(alloc, enc.bytes[0..cut])) |decoded_const| {
                var decoded = decoded_const;
                decoded.deinit();
            } else |_| {}
        }
    }
    try std.testing.expect(total_trials >= 1000);
}

test "decode rejects an entry_count that would overflow allocation" {
    const alloc = std.testing.allocator;
    var buf: [Header.size]u8 = undefined;
    Header.write(.{ .variant = .v1_creation, .entry_count = std.math.maxInt(u32), .struct_len = 0, .g_len = 0 }, &buf);
    try std.testing.expectError(error.CorruptModel, decode(alloc, &buf));
}
