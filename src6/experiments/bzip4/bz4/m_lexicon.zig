//! Lane M — compositional MDL lexicon (de Marcken-style), n-ary entries.
//!
//! See PLAN.md "Round 3 - structural rethink", item 2, and LANE_M.md for the
//! lab notebook. This is the core engine: a Lexicon of n-ary entries (each
//! entry a sequence, arity >= 2, of other entries or bytes) plus a Corpus
//! (per-block token sequence, entries never span a block barrier), and the
//! propose / re-parse / recount / delete loop that iterates them to
//! convergence under one unigram code shared by corpus and lexicon spellings
//! ("the lexicon is just more text").
//!
//! Pure Zig 0.16, std only. No text-specific rule anywhere: proposal is
//! "adjacent pair/triple with negative estimated DL delta", re-parse is a
//! byte-level shortest-path DP over a flat-array trie (no hashmap, unlike
//! Lane A's A4 -- see `Trie` below), deletion is the same MDL benefit test
//! generalised from Lane A's A2 to n-ary/multi-parent entries.

const std = @import("std");

// ------------------------------------------------------------------- consts

/// Estimated real bits to record one entry's existence (arity code + a
/// count-table slot), used only as a *heuristic* in propose/delete scoring.
/// The real accept/reject decision for a batch is always the recomputed
/// exact `dlEstimate` (est, not the final codec bytes -- see m_codec.zig for
/// the real numbers) so the precise value of this constant cannot bias the
/// result, only the search order and the aggressiveness of the search.
pub const ARITY_COST_BITS: f64 = 3.0;
/// Estimated real bits for the count-table side info per live symbol
/// (matches Lane A's side-info constant, LANE_A.md, for continuity).
pub const SIDE_INFO_BITS: f64 = 2.5;

const NO_SYM: u32 = std.math.maxInt(u32);

pub inline fn log2f(x: f64) f64 {
    return @log2(x);
}

/// f(c) = c*log2(c), f(0) = 0. See LANE_A.md "what failed" #1 for why the
/// exact identity sum_s -c_s*log2(c_s/M) = M*log2(M) - sum_s f(c_s) matters:
/// it makes shifting counts between symbols exact and cheap to evaluate.
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

// ---------------------------------------------------------------- Lexicon

/// CSR-style storage: entry `i`'s components are
/// `comp_data[comp_off[i]..comp_off[i+1]]`. Symbol ids: 0..255 = bytes,
/// 256+i = entry i. `explen[i]` is entry i's fixed byte-expansion length
/// (invariant across re-parses: re-parsing changes *how* an entry is
/// spelled, never the bytes it spells).
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

const LexBuilder = struct {
    comp_off: std.ArrayList(u32) = .empty,
    comp_data: std.ArrayList(u32) = .empty,
    explen: std.ArrayList(u32) = .empty,

    fn init(alloc: std.mem.Allocator) !LexBuilder {
        var b = LexBuilder{};
        try b.comp_off.append(alloc, 0);
        return b;
    }
    fn addEntry(self: *LexBuilder, alloc: std.mem.Allocator, comps_slice: []const u32, explen_val: u32) !u32 {
        std.debug.assert(comps_slice.len >= 2);
        const idx: u32 = @intCast(self.explen.items.len);
        try self.comp_data.appendSlice(alloc, comps_slice);
        try self.comp_off.append(alloc, @intCast(self.comp_data.items.len));
        try self.explen.append(alloc, explen_val);
        return idx;
    }
    fn finish(self: *LexBuilder) Lexicon {
        return .{ .comp_off = self.comp_off, .comp_data = self.comp_data, .explen = self.explen };
    }
};

// ------------------------------------------------------------------ State

pub const State = struct {
    lex: Lexicon = .{},
    seq: []u32,
    block_end: []usize,
    block_bytes: usize,

    pub fn deinit(self: *State, alloc: std.mem.Allocator) void {
        self.lex.deinit(alloc);
        alloc.free(self.seq);
        alloc.free(self.block_end);
    }
};

pub fn seedBytes(alloc: std.mem.Allocator, raw: []const u8, block_bytes: usize) !State {
    const n = raw.len;
    const seq = try alloc.alloc(u32, n);
    for (raw, 0..) |byte, i| seq[i] = byte;
    const block_count = if (n == 0) 0 else (n + block_bytes - 1) / block_bytes;
    const block_end = try alloc.alloc(usize, block_count);
    for (0..block_count) |b| block_end[b] = @min(n, (b + 1) * block_bytes);
    return .{ .seq = seq, .block_end = block_end, .block_bytes = block_bytes };
}

// --------------------------------------------------------------- B4SD v1 IO

pub const V1Rule = struct { a: u32, b: u32 };

pub const V1Dump = struct {
    rules: []const V1Rule,
    block_bytes: usize,
    raw_len: usize,
    seq: []u32, // concatenated per-block root symbols
    block_end: []usize,
};

fn readU32(bytes: []const u8, off: *usize) u32 {
    const v = std.mem.readInt(u32, bytes[off.*..][0..4], .little);
    off.* += 4;
    return v;
}

/// Read a version-1 B4SD dump (binary rules, ids 0..255 = bytes, 256+i =
/// rule i, children always < parent), keeping per-block root order intact
/// (unlike modelcodec's readDump, which only accumulates counts).
pub fn readB4SDv1(alloc: std.mem.Allocator, bytes: []const u8) !V1Dump {
    var off: usize = 0;
    const magic = readU32(bytes, &off);
    if (magic != 0x44533442) return error.BadMagic;
    const version = readU32(bytes, &off);
    if (version != 1) return error.BadVersion;
    const rule_count = readU32(bytes, &off);
    const block_count = readU32(bytes, &off);
    const block_bytes = readU32(bytes, &off);
    const raw_len = readU32(bytes, &off);

    const rules = try alloc.alloc(V1Rule, rule_count);
    for (0..rule_count) |i| {
        const a = readU32(bytes, &off);
        const b = readU32(bytes, &off);
        rules[i] = .{ .a = a, .b = b };
    }
    var seq: std.ArrayList(u32) = .empty;
    var block_end: std.ArrayList(usize) = .empty;
    for (0..block_count) |_| {
        const root_count = readU32(bytes, &off);
        for (0..root_count) |_| try seq.append(alloc, readU32(bytes, &off));
        try block_end.append(alloc, seq.items.len);
    }
    return .{
        .rules = rules,
        .block_bytes = block_bytes,
        .raw_len = raw_len,
        .seq = try seq.toOwnedSlice(alloc),
        .block_end = try block_end.toOwnedSlice(alloc),
    };
}

/// Seed a State by flattening a Lane A B4SD-v1 grammar into arity-2 entries
/// (PLAN's "faster" seed option): every rule becomes one entry, the dump's
/// per-block root stream becomes the initial corpus parse.
pub fn seedFromV1(alloc: std.mem.Allocator, dump: *const V1Dump) !State {
    var b = try LexBuilder.init(alloc);
    const explen = try alloc.alloc(u32, 256 + dump.rules.len);
    defer alloc.free(explen);
    for (0..256) |i| explen[i] = 1;
    for (dump.rules, 0..) |r, i| {
        explen[256 + i] = explen[r.a] + explen[r.b];
        _ = try b.addEntry(alloc, &.{ r.a, r.b }, explen[256 + i]);
    }
    const lex = b.finish();
    const seq = try alloc.dupe(u32, dump.seq);
    const block_end = try alloc.dupe(usize, dump.block_end);
    return .{ .lex = lex, .seq = seq, .block_end = block_end, .block_bytes = dump.block_bytes };
}

// ------------------------------------------------------------------ counts

pub const Counts = struct { n: []u64, m: u64 };

/// n(t) = uses of t in the corpus parse + uses of t inside every entry's
/// spelling. "The lexicon is just more text": one shared population.
pub fn recount(alloc: std.mem.Allocator, state: *const State) !Counts {
    const k = 256 + state.lex.numEntries();
    const n = try alloc.alloc(u64, k);
    @memset(n, 0);
    var m: u64 = 0;
    for (state.seq) |s| {
        n[s] += 1;
        m += 1;
    }
    for (0..state.lex.numEntries()) |i| {
        for (state.lex.comps(i)) |c| {
            n[c] += 1;
            m += 1;
        }
    }
    return .{ .n = n, .m = m };
}

/// DL estimate (bits): unigram token-bits over the shared population + a
/// per-entry arity cost + per-live-symbol side-info cost. Labelled `est`
/// everywhere it is reported -- the real number comes from m_codec.zig.
pub fn dlEstimate(n: []const u64, m: u64, num_entries: usize) f64 {
    if (m == 0) return 0;
    const mf: f64 = @floatFromInt(m);
    var sumf: f64 = 0;
    var side_bytes: usize = 0;
    for (n, 0..) |c, s| {
        sumf += flog(c);
        if (s < 256 and c > 0) side_bytes += 1;
    }
    const token_bits = mf * log2f(mf) - sumf;
    const side = SIDE_INFO_BITS * @as(f64, @floatFromInt(side_bytes + num_entries));
    const arity_bits = ARITY_COST_BITS * @as(f64, @floatFromInt(num_entries));
    return token_bits + side + arity_bits;
}

// -------------------------------------------------------------- sequence ops

fn substitutePairs(alloc: std.mem.Allocator, seq: []const u32, applied: *const std.AutoHashMap(u64, u32), out: *std.ArrayList(u32)) !void {
    var i: usize = 0;
    while (i < seq.len) {
        if (i + 1 < seq.len) {
            const key = (@as(u64, seq[i]) << 32) | seq[i + 1];
            if (applied.get(key)) |id| {
                try out.append(alloc, id);
                i += 2;
                continue;
            }
        }
        try out.append(alloc, seq[i]);
        i += 1;
    }
}

const Triple = struct { a: u32, b: u32, c: u32 };

fn substituteTriples(alloc: std.mem.Allocator, seq: []const u32, applied: *const std.AutoHashMap(Triple, u32), out: *std.ArrayList(u32)) !void {
    var i: usize = 0;
    while (i < seq.len) {
        if (i + 2 < seq.len) {
            const key = Triple{ .a = seq[i], .b = seq[i + 1], .c = seq[i + 2] };
            if (applied.get(key)) |id| {
                try out.append(alloc, id);
                i += 3;
                continue;
            }
        }
        try out.append(alloc, seq[i]);
        i += 1;
    }
}

// ------------------------------------------------------------------ propose

const PairCand = struct { key: u64, score: f64 };
fn pairCandDesc(_: void, x: PairCand, y: PairCand) bool {
    if (x.score != y.score) return x.score > y.score;
    return x.key < y.key;
}

/// PROPOSE (pairs): tally adjacent-pair counts over the current optimal
/// parse of the corpus AND every entry's own spelling, score by estimated
/// DL delta, keep negative-delta (i.e. net-saving) candidates, select a
/// role-consistent subset (no symbol is both a left and right member of two
/// different accepted pairs in the same round, matching Lane A's builder),
/// and apply: existing entries + corpus get the pair substituted in place,
/// brand-new entries (comps=[a,b], untouched this round) are appended.
pub fn proposePairs(alloc: std.mem.Allocator, state: *State, opts: Opts) !usize {
    _ = opts;
    const rc = try recount(alloc, state);
    const mf: f64 = @floatFromInt(rc.m);

    var tally = std.AutoHashMap(u64, u64).init(alloc);
    {
        var start: usize = 0;
        for (state.block_end) |end| {
            var i = start;
            var skip_at: usize = std.math.maxInt(usize);
            while (i + 1 < end) : (i += 1) {
                const a = state.seq[i];
                const b = state.seq[i + 1];
                if (a == b and skip_at == i) continue;
                if (a == b) skip_at = i + 1;
                const key = (@as(u64, a) << 32) | b;
                const gop = try tally.getOrPut(key);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
            start = end;
        }
        for (0..state.lex.numEntries()) |i| {
            const cs = state.lex.comps(i);
            if (cs.len < 2) continue;
            var j: usize = 0;
            var skip_at: usize = std.math.maxInt(usize);
            while (j + 1 < cs.len) : (j += 1) {
                const a = cs[j];
                const b = cs[j + 1];
                if (a == b and skip_at == j) continue;
                if (a == b) skip_at = j + 1;
                const key = (@as(u64, a) << 32) | b;
                const gop = try tally.getOrPut(key);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }
    }

    var existing = std.AutoHashMap(u64, void).init(alloc);
    for (0..state.lex.numEntries()) |i| {
        const cs = state.lex.comps(i);
        if (cs.len == 2) try existing.put((@as(u64, cs[0]) << 32) | cs[1], {});
    }

    var cands: std.ArrayList(PairCand) = .empty;
    var it = tally.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        const c = e.value_ptr.*;
        if (c < 2 or existing.contains(key)) continue;
        const a: u32 = @intCast(key >> 32);
        const b: u32 = @truncate(key);
        const bits_a = bitsOfCount(rc.n[a], mf);
        const bits_b = bitsOfCount(rc.n[b], mf);
        const cf: f64 = @floatFromInt(c);
        const bits_new = bitsOfCount(c, mf);
        const score = cf * (bits_a + bits_b - bits_new) - (bits_a + bits_b + ARITY_COST_BITS + SIDE_INFO_BITS);
        if (score > 0) try cands.append(alloc, .{ .key = key, .score = score });
    }
    std.mem.sort(PairCand, cands.items, {}, pairCandDesc);

    const old_num_entries = state.lex.numEntries();
    const k = 256 + old_num_entries;
    const roles = try alloc.alloc(u8, k);
    @memset(roles, 0);

    var applied = std.AutoHashMap(u64, u32).init(alloc);
    var explen_new_list: std.ArrayList(u32) = .empty; // parallel to accepted candidates, in order
    var accepted_keys: std.ArrayList(u64) = .empty;
    var next_id: u32 = @intCast(256 + old_num_entries);
    for (cands.items) |cand| {
        const a: u32 = @intCast(cand.key >> 32);
        const b: u32 = @truncate(cand.key);
        if (a == b) {
            if (roles[a] != 0) continue;
            roles[a] = 3;
        } else {
            if (roles[a] & 2 != 0 or roles[b] & 1 != 0) continue;
            roles[a] |= 1;
            roles[b] |= 2;
        }
        try applied.put(cand.key, next_id);
        try accepted_keys.append(alloc, cand.key);
        try explen_new_list.append(alloc, explenOf(&state.lex, a) + explenOf(&state.lex, b));
        next_id += 1;
    }
    if (accepted_keys.items.len == 0) return 0;

    var builder = try LexBuilder.init(alloc);
    for (0..old_num_entries) |i| {
        var newcomps: std.ArrayList(u32) = .empty;
        try substitutePairs(alloc, state.lex.comps(i), &applied, &newcomps);
        _ = try builder.addEntry(alloc, newcomps.items, state.lex.explen.items[i]);
    }
    for (accepted_keys.items, 0..) |key, idx| {
        const a: u32 = @intCast(key >> 32);
        const b: u32 = @truncate(key);
        _ = try builder.addEntry(alloc, &.{ a, b }, explen_new_list.items[idx]);
    }

    var new_seq: std.ArrayList(u32) = .empty;
    var new_block_end: std.ArrayList(usize) = .empty;
    var start: usize = 0;
    for (state.block_end) |end| {
        try substitutePairs(alloc, state.seq[start..end], &applied, &new_seq);
        try new_block_end.append(alloc, new_seq.items.len);
        start = end;
    }

    state.lex = builder.finish();
    state.seq = try new_seq.toOwnedSlice(alloc);
    state.block_end = try new_block_end.toOwnedSlice(alloc);
    return accepted_keys.items.len;
}

const TripleCand = struct { key: Triple, score: f64 };
fn tripleCandDesc(_: void, x: TripleCand, y: TripleCand) bool {
    return x.score > y.score;
}

/// PROPOSE (triples): same idea as `proposePairs` but over 3-wide windows.
/// Simpler role-consistency (a symbol used by any accepted triple this
/// round is fully excluded from any other accepted candidate).
pub fn proposeTriples(alloc: std.mem.Allocator, state: *State, opts: Opts) !usize {
    _ = opts;
    const rc = try recount(alloc, state);
    const mf: f64 = @floatFromInt(rc.m);

    var tally = std.AutoHashMap(Triple, u64).init(alloc);
    {
        var start: usize = 0;
        for (state.block_end) |end| {
            var i = start;
            while (i + 2 < end) : (i += 1) {
                const key = Triple{ .a = state.seq[i], .b = state.seq[i + 1], .c = state.seq[i + 2] };
                const gop = try tally.getOrPut(key);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
            start = end;
        }
        for (0..state.lex.numEntries()) |ei| {
            const cs = state.lex.comps(ei);
            if (cs.len < 3) continue;
            var j: usize = 0;
            while (j + 2 < cs.len) : (j += 1) {
                const key = Triple{ .a = cs[j], .b = cs[j + 1], .c = cs[j + 2] };
                const gop = try tally.getOrPut(key);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }
    }

    var existing = std.AutoHashMap(Triple, void).init(alloc);
    for (0..state.lex.numEntries()) |i| {
        const cs = state.lex.comps(i);
        if (cs.len == 3) try existing.put(.{ .a = cs[0], .b = cs[1], .c = cs[2] }, {});
    }

    var cands: std.ArrayList(TripleCand) = .empty;
    var it = tally.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        const c = e.value_ptr.*;
        if (c < 2 or existing.contains(key)) continue;
        const bits_a = bitsOfCount(rc.n[key.a], mf);
        const bits_b = bitsOfCount(rc.n[key.b], mf);
        const bits_c = bitsOfCount(rc.n[key.c], mf);
        const cf: f64 = @floatFromInt(c);
        const bits_new = bitsOfCount(c, mf);
        const score = cf * (bits_a + bits_b + bits_c - bits_new) - (bits_a + bits_b + bits_c + ARITY_COST_BITS + SIDE_INFO_BITS);
        if (score > 0) try cands.append(alloc, .{ .key = key, .score = score });
    }
    std.mem.sort(TripleCand, cands.items, {}, tripleCandDesc);

    const old_num_entries = state.lex.numEntries();
    const k = 256 + old_num_entries;
    const used = try alloc.alloc(bool, k);
    @memset(used, false);

    var applied = std.AutoHashMap(Triple, u32).init(alloc);
    var accepted: std.ArrayList(Triple) = .empty;
    var explen_new_list: std.ArrayList(u32) = .empty;
    var next_id: u32 = @intCast(256 + old_num_entries);
    for (cands.items) |cand| {
        const key = cand.key;
        if (used[key.a] or used[key.b] or used[key.c]) continue;
        used[key.a] = true;
        used[key.b] = true;
        used[key.c] = true;
        try applied.put(key, next_id);
        try accepted.append(alloc, key);
        try explen_new_list.append(alloc, explenOf(&state.lex, key.a) + explenOf(&state.lex, key.b) + explenOf(&state.lex, key.c));
        next_id += 1;
    }
    if (accepted.items.len == 0) return 0;

    var builder = try LexBuilder.init(alloc);
    for (0..old_num_entries) |i| {
        var newcomps: std.ArrayList(u32) = .empty;
        try substituteTriples(alloc, state.lex.comps(i), &applied, &newcomps);
        _ = try builder.addEntry(alloc, newcomps.items, state.lex.explen.items[i]);
    }
    for (accepted.items, 0..) |key, idx| {
        _ = try builder.addEntry(alloc, &.{ key.a, key.b, key.c }, explen_new_list.items[idx]);
    }

    var new_seq: std.ArrayList(u32) = .empty;
    var new_block_end: std.ArrayList(usize) = .empty;
    var start: usize = 0;
    for (state.block_end) |end| {
        try substituteTriples(alloc, state.seq[start..end], &applied, &new_seq);
        try new_block_end.append(alloc, new_seq.items.len);
        start = end;
    }

    state.lex = builder.finish();
    state.seq = try new_seq.toOwnedSlice(alloc);
    state.block_end = try new_block_end.toOwnedSlice(alloc);
    return accepted.items.len;
}

// --------------------------------------------------------------------- Trie

/// Flat-array byte trie: each node's children are a small edge list
/// (byte, child-node) kept in nondecreasing byte order (see `buildTrie`),
/// searched by binary search. No hashmap anywhere, unlike Lane A's A4
/// (LANE_A.md: "hashmap trie took 2-12s per parse").
const TrieEdge = struct { byte: u8, child: u32 };
const TrieNode = struct {
    edges: std.ArrayList(TrieEdge) = .empty,
    accept: u32 = NO_SYM,
};
const Trie = struct {
    nodes: std.ArrayList(TrieNode) = .empty,

    fn init(alloc: std.mem.Allocator) !Trie {
        var t = Trie{};
        try t.nodes.append(alloc, .{});
        return t;
    }
    fn findChild(self: *const Trie, node: u32, byte: u8) ?u32 {
        const edges = self.nodes.items[node].edges.items;
        var lo: usize = 0;
        var hi: usize = edges.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (edges[mid].byte == byte) return edges[mid].child;
            if (edges[mid].byte < byte) lo = mid + 1 else hi = mid;
        }
        return null;
    }
    /// Insert one (bytes,sym) pair. Requires globally sorted-by-bytes
    /// insertion order; `prev` is the previously inserted item's bytes
    /// (or &.{} for the first) so the shared prefix can be located by
    /// walking existing edges instead of hashing.
    fn insertSorted(self: *Trie, alloc: std.mem.Allocator, bytes: []const u8, sym: u32, prev: []const u8) !void {
        var lcp: usize = 0;
        const maxlcp = @min(bytes.len, prev.len);
        while (lcp < maxlcp and bytes[lcp] == prev[lcp]) lcp += 1;
        var node: u32 = 0;
        var k: usize = 0;
        while (k < lcp) : (k += 1) node = self.findChild(node, bytes[k]).?;
        while (k < bytes.len) : (k += 1) {
            const newnode: u32 = @intCast(self.nodes.items.len);
            try self.nodes.append(alloc, .{});
            try self.nodes.items[node].edges.append(alloc, .{ .byte = bytes[k], .child = newnode });
            node = newnode;
        }
        if (self.nodes.items[node].accept == NO_SYM) self.nodes.items[node].accept = sym;
    }
};

/// Materialise byte expansions for bytes (trivial) + every entry whose
/// expansion is <= max_len (skip longer ones: a bounded approximation,
/// same policy as Lane A's A4 -- LANE_A.md).
fn materializeAll(alloc: std.mem.Allocator, lex: *const Lexicon, max_len: u32) ![]?[]u8 {
    const n = lex.numEntries();
    const k = 256 + n;
    const bytes = try alloc.alloc(?[]u8, k);
    for (0..256) |b| {
        const buf = try alloc.alloc(u8, 1);
        buf[0] = @intCast(b);
        bytes[b] = buf;
    }
    // Component ids are only guaranteed to have strictly smaller *explen*
    // than their parent (not a smaller id -- reparseRound can rewrite an
    // entry's spelling to reference an entry created later, per PLAN's
    // acyclicity rule), so materialise in explen order, not id order.
    const order = try alloc.alloc(u32, n);
    for (0..n) |i| order[i] = @intCast(i);
    const Ctx = struct {
        lex: *const Lexicon,
        fn lt(self: @This(), a: u32, b: u32) bool {
            return self.lex.explen.items[a] < self.lex.explen.items[b];
        }
    };
    std.mem.sort(u32, order, Ctx{ .lex = lex }, Ctx.lt);
    for (order) |i| {
        const sym = 256 + i;
        const el = lex.explen.items[i];
        if (el > max_len) {
            bytes[sym] = null;
            continue;
        }
        const cs = lex.comps(i);
        var ok = true;
        for (cs) |c| {
            if (bytes[c] == null) {
                ok = false;
                break;
            }
        }
        if (!ok) {
            bytes[sym] = null;
            continue;
        }
        const buf = try alloc.alloc(u8, el);
        var pos: usize = 0;
        for (cs) |c| {
            const cb = bytes[c].?;
            @memcpy(buf[pos .. pos + cb.len], cb);
            pos += cb.len;
        }
        bytes[sym] = buf;
    }
    return bytes;
}

const MatItem = struct { bytes: []const u8, sym: u32 };
fn matItemLess(_: void, x: MatItem, y: MatItem) bool {
    return std.mem.order(u8, x.bytes, y.bytes) == .lt;
}

fn buildTrie(alloc: std.mem.Allocator, matbytes: []const ?[]u8) !Trie {
    var items: std.ArrayList(MatItem) = .empty;
    for (matbytes, 0..) |mb, sym| {
        if (mb) |b| try items.append(alloc, .{ .bytes = b, .sym = @intCast(sym) });
    }
    std.mem.sort(MatItem, items.items, {}, matItemLess);
    var trie = try Trie.init(alloc);
    var prev: []const u8 = &.{};
    for (items.items) |it| {
        try trie.insertSorted(alloc, it.bytes, it.sym, prev);
        prev = it.bytes;
    }
    return trie;
}

/// Shortest-total-code-length DP over `block` using `trie` + per-symbol
/// `bits`. If `explen_limit` is set, a candidate symbol is only usable when
/// its expansion length is strictly less than it (this is what keeps the
/// entry-DAG acyclic when re-parsing an entry's own spelling -- PLAN's
/// "only allow components whose byte expansion is strictly shorter").
fn dpParse(
    alloc: std.mem.Allocator,
    trie: *const Trie,
    block: []const u8,
    bits: []const f64,
    lex_explen: []const u32,
    explen_limit: ?u32,
    out_tokens: *std.ArrayList(u32),
) !void {
    const l = block.len;
    const dp = try alloc.alloc(f64, l + 1);
    defer alloc.free(dp);
    const from_sym = try alloc.alloc(u32, l + 1);
    defer alloc.free(from_sym);
    const from_pos = try alloc.alloc(u32, l + 1);
    defer alloc.free(from_pos);
    @memset(dp, std.math.inf(f64));
    dp[0] = 0;

    var i: usize = 0;
    while (i < l) : (i += 1) {
        if (!std.math.isFinite(dp[i])) continue;
        var node: u32 = 0;
        var j = i;
        while (j < l) {
            const nxt = trie.findChild(node, block[j]) orelse break;
            node = nxt;
            j += 1;
            const sym = trie.nodes.items[node].accept;
            if (sym != NO_SYM) {
                var ok = true;
                if (explen_limit) |lim| {
                    const el: u32 = if (sym < 256) 1 else lex_explen[sym - 256];
                    if (el >= lim) ok = false;
                }
                if (ok) {
                    const cand = dp[i] + bits[sym];
                    if (cand < dp[j]) {
                        dp[j] = cand;
                        from_sym[j] = sym;
                        from_pos[j] = @intCast(i);
                    }
                }
            }
        }
    }

    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(alloc);
    var pos: usize = l;
    while (pos > 0) {
        std.debug.assert(std.math.isFinite(dp[pos]));
        try stack.append(alloc, from_sym[pos]);
        pos = from_pos[pos];
    }
    var idx = stack.items.len;
    while (idx > 0) {
        idx -= 1;
        try out_tokens.append(alloc, stack.items[idx]);
    }
}

/// RE-PARSE: rebuild the trie from the current lexicon, then re-tokenise
/// every corpus block (against `raw`) and every entry's own spelling
/// (against its materialised bytes, filtered by explen) via the DP above.
/// Self-validating: computes the real recomputed DL before/after and keeps
/// whichever is smaller (Lane A's "what failed" #3: a DP that's optimal for
/// stale per-symbol costs can regress once costs are honestly recounted).
/// Returns true if the re-parse changed anything and was kept.
pub fn reparseRound(alloc: std.mem.Allocator, state: *State, raw: []const u8, opts: Opts) !bool {
    const rc0 = try recount(alloc, state);
    const dl_before = dlEstimate(rc0.n, rc0.m, state.lex.numEntries());
    const k = 256 + state.lex.numEntries();
    const bits = try alloc.alloc(f64, k);
    for (0..k) |s| bits[s] = bitsOfCount(rc0.n[s], @floatFromInt(rc0.m));

    const matbytes = try materializeAll(alloc, &state.lex, opts.max_material_len);
    const trie = try buildTrie(alloc, matbytes);

    // Corpus blocks, against the raw bytes.
    var new_seq: std.ArrayList(u32) = .empty;
    var new_block_end: std.ArrayList(usize) = .empty;
    var raw_start: usize = 0;
    for (state.block_end) |_| {
        const raw_end = @min(raw.len, raw_start + state.block_bytes);
        try dpParse(alloc, &trie, raw[raw_start..raw_end], bits, state.lex.explen.items, null, &new_seq);
        try new_block_end.append(alloc, new_seq.items.len);
        raw_start = raw_end;
    }

    // Every entry's own spelling, against its materialised bytes (skip
    // entries too long to have been materialised: bounded approximation).
    var builder = try LexBuilder.init(alloc);
    for (0..state.lex.numEntries()) |i| {
        const sym = 256 + i;
        const el = state.lex.explen.items[i];
        if (matbytes[sym]) |mb| {
            var toks: std.ArrayList(u32) = .empty;
            try dpParse(alloc, &trie, mb, bits, state.lex.explen.items, el, &toks);
            _ = try builder.addEntry(alloc, toks.items, el);
        } else {
            _ = try builder.addEntry(alloc, state.lex.comps(i), el);
        }
    }
    var new_lex = builder.finish();

    var candidate = State{ .lex = new_lex, .seq = try new_seq.toOwnedSlice(alloc), .block_end = try new_block_end.toOwnedSlice(alloc), .block_bytes = state.block_bytes };
    const rc1 = try recount(alloc, &candidate);
    const dl_after = dlEstimate(rc1.n, rc1.m, candidate.lex.numEntries());

    if (dl_after < dl_before) {
        state.* = candidate;
        return true;
    } else {
        new_lex.deinit(alloc);
        return false;
    }
}

// ------------------------------------------------------------------- delete

fn buildResolved(alloc: std.mem.Allocator, lex: *const Lexicon, marked: []const bool) ![]?[]u32 {
    const n = lex.numEntries();
    const resolved = try alloc.alloc(?[]u32, n);
    @memset(resolved, null);
    const order = try alloc.alloc(u32, n);
    for (0..n) |i| order[i] = @intCast(i);
    const Ctx = struct {
        lex: *const Lexicon,
        fn lt(self: @This(), a: u32, b: u32) bool {
            return self.lex.explen.items[a] < self.lex.explen.items[b];
        }
    };
    std.mem.sort(u32, order, Ctx{ .lex = lex }, Ctx.lt);
    for (order) |i| {
        if (!marked[i]) continue;
        var buf: std.ArrayList(u32) = .empty;
        for (lex.comps(i)) |c| {
            if (c >= 256 and marked[c - 256]) {
                try buf.appendSlice(alloc, resolved[c - 256].?);
            } else {
                try buf.append(alloc, c);
            }
        }
        resolved[i] = try buf.toOwnedSlice(alloc);
    }
    return resolved;
}

fn emitResolveAll(alloc: std.mem.Allocator, out: *std.ArrayList(u32), items: []const u32, marked: []const bool, resolved: []const ?[]u32) !void {
    for (items) |t| {
        if (t >= 256 and marked[t - 256]) {
            try out.appendSlice(alloc, resolved[t - 256].?);
        } else {
            try out.append(alloc, t);
        }
    }
}

fn tallyResolved(seq: []const u32, marked: []const bool, resolved: []const ?[]u32, n: []u64, m: *u64) void {
    for (seq) |t| {
        if (t >= 256 and marked[t - 256]) {
            for (resolved[t - 256].?) |r| {
                n[r] += 1;
                m.* += 1;
            }
        } else {
            n[t] += 1;
            m.* += 1;
        }
    }
}

fn simulateDelete(alloc: std.mem.Allocator, state: *const State, marked: []const bool) !f64 {
    const resolved = try buildResolved(alloc, &state.lex, marked);
    const k = 256 + state.lex.numEntries();
    const n = try alloc.alloc(u64, k);
    @memset(n, 0);
    var m: u64 = 0;
    tallyResolved(state.seq, marked, resolved, n, &m);
    for (0..state.lex.numEntries()) |i| {
        if (marked[i]) continue;
        tallyResolved(state.lex.comps(i), marked, resolved, n, &m);
    }
    var num_alive: usize = 0;
    for (marked) |mk| {
        if (!mk) num_alive += 1;
    }
    return dlEstimate(n, m, num_alive);
}

const DelCand = struct { idx: u32, benefit: f64 };
fn delCandDesc(_: void, x: DelCand, y: DelCand) bool {
    return x.benefit > y.benefit;
}

/// DELETE: an entry may be deleted wherever it's referenced (corpus OR any
/// other entry's spelling -- n-ary storage makes this a strict
/// generalisation of Lane A's A2, which could only delete "nobody's child"
/// rules because its binary representation couldn't hold an inlined
/// arity>2 parent). Benefit is the exact DL delta of splicing every use of
/// the entry back to its own spelling, re-derived for the unified
/// corpus+spelling token population (NOT Lane A's formula, which only
/// charged for root occurrences). Batched with the same rank + halving
/// safety net as Lane A's A2 (LANE_A.md "what failed" #2).
pub fn deletePass(alloc: std.mem.Allocator, state: *State, opts: Opts) !usize {
    _ = opts;
    const rc = try recount(alloc, state);
    const mf: f64 = @floatFromInt(rc.m);
    const num_entries = state.lex.numEntries();
    if (num_entries == 0) return 0;
    const current_dl = dlEstimate(rc.n, rc.m, num_entries);

    var cands: std.ArrayList(DelCand) = .empty;
    for (0..num_entries) |i| {
        const sym: u32 = @intCast(256 + i);
        const u: u64 = rc.n[sym];
        const cs = state.lex.comps(i);
        const r: f64 = @floatFromInt(cs.len);
        const uf: f64 = @floatFromInt(u);
        const m_after = mf + r * uf - r - uf;
        if (m_after <= 0) continue;
        const delta_mlogm = m_after * log2f(m_after) - mf * log2f(mf);

        const tmp = try alloc.dupe(u32, cs);
        std.mem.sort(u32, tmp, {}, std.sort.asc(u32));
        var delta_children: f64 = 0;
        var idx: usize = 0;
        while (idx < tmp.len) {
            var j = idx + 1;
            while (j < tmp.len and tmp[j] == tmp[idx]) j += 1;
            const v = tmp[idx];
            const mult: f64 = @floatFromInt(j - idx);
            const nv: u64 = rc.n[v];
            const nvf: f64 = @floatFromInt(nv);
            const add = mult * (uf - 1);
            const nv_new = @max(0, nvf + add);
            delta_children += flog(@intFromFloat(@round(nv_new))) - flog(nv);
            idx = j;
        }
        alloc.free(tmp);

        const benefit = delta_children - delta_mlogm - flog(u) + ARITY_COST_BITS + SIDE_INFO_BITS;
        if (benefit > 0) try cands.append(alloc, .{ .idx = @intCast(i), .benefit = benefit });
    }
    if (cands.items.len == 0) return 0;
    std.mem.sort(DelCand, cands.items, {}, delCandDesc);

    const marked = try alloc.alloc(bool, num_entries);
    @memset(marked, false);
    var accepted: usize = 0;
    var mcount = cands.items.len;
    while (mcount > 0) {
        @memset(marked, false);
        for (cands.items[0..mcount]) |c| marked[c.idx] = true;
        const trial = try simulateDelete(alloc, state, marked);
        if (trial < current_dl) {
            accepted = mcount;
            break;
        }
        mcount /= 2;
    }
    if (accepted == 0) return 0;
    @memset(marked, false);
    for (cands.items[0..accepted]) |c| marked[c.idx] = true;

    const resolved = try buildResolved(alloc, &state.lex, marked);

    var new_seq: std.ArrayList(u32) = .empty;
    var new_block_end: std.ArrayList(usize) = .empty;
    var start: usize = 0;
    for (state.block_end) |end| {
        try emitResolveAll(alloc, &new_seq, state.seq[start..end], marked, resolved);
        try new_block_end.append(alloc, new_seq.items.len);
        start = end;
    }

    const remap = try alloc.alloc(u32, 256 + num_entries);
    for (0..256) |b| remap[b] = @intCast(b);
    var next_id: u32 = 256;
    for (0..num_entries) |i| {
        if (!marked[i]) {
            remap[256 + i] = next_id;
            next_id += 1;
        }
    }

    var builder = try LexBuilder.init(alloc);
    for (0..num_entries) |i| {
        if (marked[i]) continue;
        var spliced: std.ArrayList(u32) = .empty;
        try emitResolveAll(alloc, &spliced, state.lex.comps(i), marked, resolved);
        for (spliced.items) |*t| t.* = remap[t.*];
        _ = try builder.addEntry(alloc, spliced.items, state.lex.explen.items[i]);
    }
    for (new_seq.items) |*t| t.* = remap[t.*];

    state.lex = builder.finish();
    state.seq = try new_seq.toOwnedSlice(alloc);
    state.block_end = try new_block_end.toOwnedSlice(alloc);
    return accepted;
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
/// byte, with no token spanning a block barrier. Must pass on every run
/// (PLAN's rules of evidence).
pub fn verifyExact(alloc: std.mem.Allocator, raw: []const u8, state: *const State) !bool {
    var out: std.ArrayList(u8) = .empty;
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(alloc);
    var seq_start: usize = 0;
    var raw_start: usize = 0;
    for (state.block_end) |seq_end| {
        const raw_end = @min(raw.len, raw_start + state.block_bytes);
        out.clearRetainingCapacity();
        for (state.seq[seq_start..seq_end]) |s| try expandOneInto(alloc, &state.lex, s, &out, &stack);
        if (!std.mem.eql(u8, out.items, raw[raw_start..raw_end])) return false;
        seq_start = seq_end;
        raw_start = raw_end;
    }
    return seq_start == state.seq.len and raw_start == raw.len;
}

// -------------------------------------------------------------------- iterate

pub const Opts = struct {
    max_iters: usize = 20,
    converge_frac: f64 = 0.0005,
    max_material_len: u32 = 256,
    triples: bool = false,
};

pub const IterLog = struct {
    iter: usize,
    num_entries: usize,
    tokens: usize,
    dl_bytes: f64,
    proposed_pairs: usize,
    proposed_triples: usize,
    deleted: usize,
    ms: f64,
};

fn nowMs(io: std.Io) f64 {
    return @as(f64, @floatFromInt(std.Io.Clock.awake.now(io).nanoseconds)) / 1e6;
}

/// The main loop: PROPOSE (pairs [+ triples]) -> RE-PARSE (corpus + every
/// entry's spelling) -> RECOUNT -> DELETE, until DL improves by less than
/// `opts.converge_frac` or `opts.max_iters` iterations, or a round changes
/// nothing at all.
pub fn iterate(alloc: std.mem.Allocator, io: std.Io, state: *State, raw: []const u8, opts: Opts, log: *std.ArrayList(IterLog)) !void {
    var prev_dl: f64 = std.math.inf(f64);
    var iter: usize = 0;
    while (iter < opts.max_iters) : (iter += 1) {
        // PROPOSE does not self-validate (it accepts by heuristic estimate,
        // in batches, same as Lane A's builder); snapshot so a whole
        // iteration that nets out worse than where we started (rare, but
        // possible when propose overshoots and delete can't fully recover
        // in one round) can be rolled back rather than reported as if it
        // were an improvement. Cheap: State is just slice headers, and
        // everything here runs under an arena, so the old data stays valid.
        const snapshot = state.*;
        const t0 = nowMs(io);
        const pp = try proposePairs(alloc, state, opts);
        const pt: usize = if (opts.triples) try proposeTriples(alloc, state, opts) else 0;
        const changed = try reparseRound(alloc, state, raw, opts);
        const del = try deletePass(alloc, state, opts);
        const t1 = nowMs(io);

        const rc = try recount(alloc, state);
        const dl = dlEstimate(rc.n, rc.m, state.lex.numEntries());
        alloc.free(rc.n);

        try log.append(alloc, .{
            .iter = iter,
            .num_entries = state.lex.numEntries(),
            .tokens = state.seq.len,
            .dl_bytes = dl / 8.0,
            .proposed_pairs = pp,
            .proposed_triples = pt,
            .deleted = del,
            .ms = t1 - t0,
        });

        if (dl > prev_dl) {
            state.* = snapshot; // whole iteration regressed: roll back and stop
            break;
        }
        if (pp == 0 and pt == 0 and del == 0 and !changed) break;
        if (iter > 0) {
            const improvement = (prev_dl - dl) / prev_dl;
            if (improvement < opts.converge_frac) break;
        }
        prev_dl = dl;
    }
}

// ---------------------------------------------------------------------- test

test "smoke: propose/reparse/delete round-trip on a tiny corpus" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const A = arena_state.allocator();
    const raw = "abcabcabcabc abcabcabc xyzxyzxyz abcabc";
    var state = try seedBytes(A, raw, 4096);
    try std.testing.expect(try verifyExact(A, raw, &state));

    const opts = Opts{};
    var iter: usize = 0;
    while (iter < 5) : (iter += 1) {
        _ = try proposePairs(A, &state, opts);
        _ = try reparseRound(A, &state, raw, opts);
        _ = try deletePass(A, &state, opts);
        try std.testing.expect(try verifyExact(A, raw, &state));
    }
}

test "smoke: seedFromV1 flattens a tiny binary grammar" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const A = arena_state.allocator();
    // rule 256 = 'a'+'b', one block, root stream [256, 'c'] spelling "abc".
    const rules = [_]V1Rule{.{ .a = 'a', .b = 'b' }};
    var seq = [_]u32{ 256, 'c' };
    var block_end = [_]usize{2};
    var dump = V1Dump{ .rules = &rules, .block_bytes = 4096, .raw_len = 3, .seq = &seq, .block_end = &block_end };
    var state = try seedFromV1(A, &dump);
    try std.testing.expect(try verifyExact(A, "abc", &state));
    try std.testing.expectEqual(@as(usize, 1), state.lex.numEntries());
}
