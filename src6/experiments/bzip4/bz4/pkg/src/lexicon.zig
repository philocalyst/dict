//! The compositional MDL lexicon storage: an n-ary `Lexicon` (each entry a
//! sequence, arity >= 2, of bytes or other entries) plus a `Corpus` (the
//! per-block token sequence; entries never span a block barrier) and the
//! shared-population counting/cost functions the rest of the lexicon
//! engine (`propose.zig`, `parse.zig`, `delete.zig`, `learn.zig`) builds on.
//!
//! Ported from the lab's `m_lexicon.zig` (Lane M) per PLAN.md's
//! copy-and-reshape rule, split into one file per responsibility and
//! trimmed to what this package actually uses: seeding always starts from
//! raw bytes (the round-3 pipeline is "bytes -> lexicon learning", not
//! "seed from another lane's grammar dump"), so the B4SD-v1 reader Lane M
//! also carried is dropped here.

const std = @import("std");
const ids = @import("ids.zig");

/// Calibration for the lexicon-learning search's cost heuristics --
/// *estimates* used only to rank/score candidates during propose/delete
/// search (parse's DP uses the plain order-0 `bitsOfCount` below, since it
/// only ever compares candidates within one search, not against the real
/// model codec). The real accept/reject gate is always either a
/// recomputed exact `dlEstimate` (search-time self-validation) or a real
/// re-encode (`joint.zig`'s cross-stage gate, `root.zig`'s calibration
/// gate), so neither field here can bias the final answer, only the
/// search order and how many entries the learner is willing to create.
pub const Calib = struct {
    /// Estimated real bits to store one lexicon entry's own existence in
    /// whatever model codec is in use (its definition site: arity, and
    /// its own components' marginal reference cost, averaged over the
    /// whole lexicon). Different codecs charge very differently for this
    /// -- a DEF-tree codec with a recency cache makes a component that
    /// resolves to an already-defined entry cheap and nesting close to
    /// free, so this is measured from one real encode
    /// (`root.zig`'s calibration step) rather than hand-picked.
    entry_bits: f64 = 8.0,
    /// Estimated bits of count-table side info per live byte in the
    /// alphabet -- a much smaller, separate concern from `entry_bits`.
    byte_side_info_bits: f64 = 2.5,

    pub fn default() Calib {
        return .{};
    }
};

pub inline fn log2f(x: f64) f64 {
    return @log2(x);
}

/// f(c) = c*log2(c), f(0) = 0. Used via the identity
/// `sum_s -c_s*log2(c_s/M) = M*log2(M) - sum_s f(c_s)`, which makes moving
/// counts between symbols an O(1) update to evaluate exactly.
pub inline fn flog(c: u64) f64 {
    if (c == 0) return 0;
    const cf: f64 = @floatFromInt(c);
    return cf * log2f(cf);
}

/// Static order-0 code length (bits) for a symbol with count `count` out of
/// `m` total population slots.
pub inline fn bitsOfCount(count: u64, m: f64) f64 {
    if (count > 0) return -log2f(@as(f64, @floatFromInt(count)) / m);
    return -log2f(0.5 / m);
}

/// CSR-style entry storage: entry `i`'s components are
/// `comp_data[comp_off[i]..comp_off[i+1]]`. Symbol ids: 0..255 = bytes,
/// 256+i = entry i. `explen[i]` is entry i's fixed byte-expansion length
/// (invariant across re-parses: re-parsing changes *how* an entry is
/// spelled, never the bytes it spells, so every component's explen is
/// always strictly less than its parent's -- the property `parse.zig` and
/// `topology.zig` rely on for a safe materialisation/topological order).
pub const Lexicon = struct {
    comp_off: std.ArrayList(u32) = .empty,
    comp_data: std.ArrayList(u32) = .empty,
    explen: std.ArrayList(u32) = .empty,

    pub fn numEntries(self: *const Lexicon) usize {
        return self.explen.items.len;
    }
    pub fn comps(self: *const Lexicon, idx: usize) []const u32 {
        return self.comp_data.items[self.comp_off.items[idx]..self.comp_off.items[idx + 1]];
    }
    pub fn arity(self: *const Lexicon, idx: usize) usize {
        return self.comp_off.items[idx + 1] - self.comp_off.items[idx];
    }
    pub fn deinit(self: *Lexicon, alloc: std.mem.Allocator) void {
        self.comp_off.deinit(alloc);
        self.comp_data.deinit(alloc);
        self.explen.deinit(alloc);
    }
};

pub inline fn explenOf(lex: *const Lexicon, s: u32) u32 {
    return if (s < 256) 1 else lex.explen.items[s - 256];
}

pub const LexBuilder = struct {
    comp_off: std.ArrayList(u32) = .empty,
    comp_data: std.ArrayList(u32) = .empty,
    explen: std.ArrayList(u32) = .empty,

    pub fn init(alloc: std.mem.Allocator) !LexBuilder {
        var b = LexBuilder{};
        try b.comp_off.append(alloc, 0);
        return b;
    }
    pub fn addEntry(self: *LexBuilder, alloc: std.mem.Allocator, comps_slice: []const u32, explen_val: u32) !u32 {
        std.debug.assert(comps_slice.len >= 2);
        const idx: u32 = @intCast(self.explen.items.len);
        try self.comp_data.appendSlice(alloc, comps_slice);
        try self.comp_off.append(alloc, @intCast(self.comp_data.items.len));
        try self.explen.append(alloc, explen_val);
        return idx;
    }
    pub fn finish(self: *LexBuilder) Lexicon {
        return .{ .comp_off = self.comp_off, .comp_data = self.comp_data, .explen = self.explen };
    }
};

/// The corpus: a flat token sequence over `lex`'s alphabet, split into
/// independently-parsed blocks (`block_end[b]` is the exclusive end index
/// of block b in `seq`; no entry's occurrence in `seq` ever crosses a
/// block boundary because every proposal/re-parse step operates block by
/// block).
pub const Corpus = struct {
    lex: Lexicon = .{},
    seq: []u32,
    block_end: []usize,
    block_bytes: usize,

    pub fn deinit(self: *Corpus, alloc: std.mem.Allocator) void {
        self.lex.deinit(alloc);
        alloc.free(self.seq);
        alloc.free(self.block_end);
    }
};

pub fn seedBytes(alloc: std.mem.Allocator, raw: []const u8, block_bytes: usize) !Corpus {
    const n = raw.len;
    const seq = try alloc.alloc(u32, n);
    for (raw, 0..) |byte, i| seq[i] = byte;
    const block_count = if (n == 0) 0 else (n + block_bytes - 1) / block_bytes;
    const block_end = try alloc.alloc(usize, block_count);
    for (0..block_count) |b| block_end[b] = @min(n, (b + 1) * block_bytes);
    return .{ .seq = seq, .block_end = block_end, .block_bytes = block_bytes };
}

// ------------------------------------------------------------------ counts

pub const Counts = struct { n: []u64, m: u64 };

/// n(t) = uses of t in the corpus parse + uses of t inside every entry's
/// own spelling: "the lexicon is just more text", one shared population
/// for the lexicon's *internal* order-0 code (the model codec). Corpus
/// tokens are coded separately, by the class-conditional block coder --
/// see `computeRootCounts` in `classes.zig` for that population.
pub fn recount(alloc: std.mem.Allocator, corpus: *const Corpus) !Counts {
    const k = 256 + corpus.lex.numEntries();
    const n = try alloc.alloc(u64, k);
    @memset(n, 0);
    var m: u64 = 0;
    for (corpus.seq) |s| {
        n[s] += 1;
        m += 1;
    }
    for (0..corpus.lex.numEntries()) |i| {
        for (corpus.lex.comps(i)) |c| {
            n[c] += 1;
            m += 1;
        }
    }
    return .{ .n = n, .m = m };
}

/// Population restricted to spelling-internal uses only (an entry that is
/// never itself the component of another entry's spelling needs no
/// reference-code slot at all -- see `model_codec.zig`).
pub fn recountSpellingOnly(alloc: std.mem.Allocator, lex: *const Lexicon) !Counts {
    const k = 256 + lex.numEntries();
    const n = try alloc.alloc(u64, k);
    @memset(n, 0);
    var m: u64 = 0;
    for (0..lex.numEntries()) |i| {
        for (lex.comps(i)) |c| {
            n[c] += 1;
            m += 1;
        }
    }
    return .{ .n = n, .m = m };
}

/// Root/corpus-only occurrence counts (an entry used only inside other
/// entries' spellings has g=0 here): this is the population the
/// class-conditional block coder's g[x]/G[class] term is built from.
pub fn recountRootsOnly(alloc: std.mem.Allocator, corpus: *const Corpus) ![]u64 {
    const k = 256 + corpus.lex.numEntries();
    const g = try alloc.alloc(u64, k);
    @memset(g, 0);
    for (corpus.seq) |s| g[s] += 1;
    return g;
}

/// DL estimate (bits): unigram token-bits over the shared population, plus
/// a per-entry model-overhead cost (`calib.entry_bits`) and per-live-byte
/// side-info cost. Always labelled `est` in reports -- the real number
/// comes from `model_codec.zig` + `block_coder.zig`.
pub fn dlEstimate(n: []const u64, m: u64, num_entries: usize, calib: Calib) f64 {
    if (m == 0) return 0;
    const mf: f64 = @floatFromInt(m);
    var sumf: f64 = 0;
    var side_bytes: usize = 0;
    for (n, 0..) |c, s| {
        sumf += flog(c);
        if (s < 256 and c > 0) side_bytes += 1;
    }
    const token_bits = mf * log2f(mf) - sumf;
    const side = calib.byte_side_info_bits * @as(f64, @floatFromInt(side_bytes));
    const entry_overhead = calib.entry_bits * @as(f64, @floatFromInt(num_entries));
    return token_bits + side + entry_overhead;
}

// ------------------------------------------------------------------- verify

fn expandOneInto(alloc: std.mem.Allocator, lex: *const Lexicon, tok: u32, out: *std.ArrayList(u8), stack: *std.ArrayList(u32)) !void {
    stack.clearRetainingCapacity();
    try stack.append(alloc, tok);
    while (stack.pop()) |s| {
        if (s < 256) {
            try out.append(alloc, @intCast(s));
            continue;
        }
        const cs = lex.comps(s - 256);
        var j = cs.len;
        while (j > 0) {
            j -= 1;
            try stack.append(alloc, cs[j]);
        }
    }
}

pub fn expandEntryBytes(alloc: std.mem.Allocator, lex: *const Lexicon, sym: u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(alloc);
    try expandOneInto(alloc, lex, sym, &out, &stack);
    return out.toOwnedSlice(alloc);
}

/// Expand every block's tokens and compare against the raw input, byte for
/// byte, with no token spanning a block barrier.
pub fn verifyExact(alloc: std.mem.Allocator, raw: []const u8, corpus: *const Corpus) !bool {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(alloc);
    var seq_start: usize = 0;
    var raw_start: usize = 0;
    for (corpus.block_end) |seq_end| {
        const raw_end = @min(raw.len, raw_start + corpus.block_bytes);
        out.clearRetainingCapacity();
        for (corpus.seq[seq_start..seq_end]) |s| try expandOneInto(alloc, &corpus.lex, s, &out, &stack);
        if (!std.mem.eql(u8, out.items, raw[raw_start..raw_end])) return false;
        seq_start = seq_end;
        raw_start = raw_end;
    }
    return seq_start == corpus.seq.len and raw_start == raw.len;
}

test "seedBytes covers the whole input in blocks" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const raw = "hello, world! hello again.";
    var corpus = try seedBytes(a, raw, 8);
    try std.testing.expect(try verifyExact(a, raw, &corpus));
    try std.testing.expectEqual(@as(usize, 4), corpus.block_end.len);
    _ = ids;
}

test "recount matches a hand count on a tiny lexicon" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // entry 256 = 'a'+'b'; corpus = [256, 256, 'c']
    var b = try LexBuilder.init(a);
    _ = try b.addEntry(a, &.{ 'a', 'b' }, 2);
    var corpus = Corpus{ .lex = b.finish(), .seq = try a.dupe(u32, &.{ 256, 256, 'c' }), .block_end = try a.dupe(usize, &.{3}), .block_bytes = 64 };
    const rc = try recount(a, &corpus);
    try std.testing.expectEqual(@as(u64, 1), rc.n['a']); // once, from entry 256's own spelling
    try std.testing.expectEqual(@as(u64, 1), rc.n['b']);
    try std.testing.expectEqual(@as(u64, 2), rc.n[256]); // twice in corpus
    try std.testing.expectEqual(@as(u64, 1), rc.n['c']);
    try std.testing.expectEqual(@as(u64, 5), rc.m); // 3 corpus tokens + 2 spelling components
}
