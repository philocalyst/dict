//! Lane L -- the word learner, rewritten for the right objective.
//!
//! Lane M (`../m_lexicon.zig`, `LANE_M.md`) built a compositional MDL
//! lexicon but costed every occurrence of a symbol -- including its very
//! first -- against the *same* per-symbol static frequency. That charges a
//! twice-used entry for two expensive "rare symbol" events instead of one
//! shared, cheap DEF marker plus one ordinary USE, so the search
//! systematically undervalues definitions and Lane M's own model codec
//! ended up costing 1.5-3.5x more bits/entry than a DEF-tree would
//! (LANE_M.md "Biggest remaining inefficiency").
//!
//! This file targets the actual v3 stream (`../DESIGN.md`): an entry is
//! *defined at its first use* -- one shared `DEF` event kind, whichever
//! entry it is -- and every later occurrence is a `USE(x)` event specific
//! to that token. Bytes are pre-defined (bucket 0) and never DEF. A
//! definition additionally pays an empirical-entropy code for its arity and
//! for `tier(x) = floor(log2(uses(x)+1))` (its "name" -- which size class of
//! bucket it will live in). See `LANE_L.md` for the full write-up, the
//! measured tables, and the honest list of approximations below.
//!
//! Pure Zig 0.16, std only. No hashmap in any loop that scales with the
//! number of *tokens* (only over the number of *candidates*, which is
//! output-sized): pair/triple tallying is sort + run-length count over a
//! flat key array, the byte/entry trie is a small sorted-edge-list (no
//! hashing), substitution during propose looks candidates up by binary
//! search over a sorted key array.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================ numeric core

pub inline fn log2f(x: f64) f64 {
    return @log2(x);
}

/// f(c) = c*log2(c), f(0) = 0. Sum identity used throughout:
/// `sum_k -n_k*log2(n_k/N) = N*log2(N) - sum_k f(n_k)`.
pub inline fn flog(c: u64) f64 {
    if (c == 0) return 0;
    const cf: f64 = @floatFromInt(c);
    return cf * log2f(cf);
}

/// floor(log2(x)), x >= 1.
pub inline fn log2Floor(x: u64) u32 {
    std.debug.assert(x >= 1);
    return 63 - @clz(x);
}

// ================================================================ Lexicon

/// CSR-style n-ary entry storage: entry `i`'s components are
/// `comp_data[comp_off[i]..comp_off[i+1]]`. Symbol ids: 0..255 = bytes,
/// 256+i = entry i. `explen[i]` is entry i's fixed byte-expansion length,
/// invariant across re-parses (re-parsing changes *how* an entry is
/// spelled, never the bytes it spells) and always strictly less than any
/// parent that contains it -- the property that gives a safe
/// materialisation/topological order without needing entry ids to be
/// ordered.
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
    pub fn deinit(self: *Lexicon, alloc: Allocator) void {
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

    pub fn init(alloc: Allocator) !LexBuilder {
        var b: LexBuilder = .{};
        try b.comp_off.append(alloc, 0);
        return b;
    }
    pub fn addEntry(self: *LexBuilder, alloc: Allocator, comps_slice: []const u32, explen_val: u32) !u32 {
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

fn dupeList(alloc: Allocator, src: *const std.ArrayList(u32)) !std.ArrayList(u32) {
    var out: std.ArrayList(u32) = .empty;
    try out.appendSlice(alloc, src.items);
    return out;
}

fn dupeLexicon(alloc: Allocator, lex: *const Lexicon) !Lexicon {
    return .{
        .comp_off = try dupeList(alloc, &lex.comp_off),
        .comp_data = try dupeList(alloc, &lex.comp_data),
        .explen = try dupeList(alloc, &lex.explen),
    };
}

// ================================================================= Corpus

/// The per-block token sequence over `lex`'s alphabet; no entry's
/// occurrence in `seq` ever crosses a block boundary.
pub const Corpus = struct {
    lex: Lexicon = .{},
    seq: []u32,
    block_end: []usize,
    block_bytes: usize,

    pub fn deinit(self: *Corpus, alloc: Allocator) void {
        self.lex.deinit(alloc);
        alloc.free(self.seq);
        alloc.free(self.block_end);
    }
};

pub fn seedBytes(alloc: Allocator, raw: []const u8, block_bytes: usize) !Corpus {
    const n = raw.len;
    const seq = try alloc.alloc(u32, n);
    for (raw, 0..) |byte, i| seq[i] = byte;
    const block_count = if (n == 0) 0 else (n + block_bytes - 1) / block_bytes;
    const block_end = try alloc.alloc(usize, block_count);
    for (0..block_count) |b| block_end[b] = @min(n, (b + 1) * block_bytes);
    return .{ .seq = seq, .block_end = block_end, .block_bytes = block_bytes };
}

// ------------------------------------------------------------- population

/// n(t) = uses of t in the corpus parse + uses of t inside every surviving
/// entry's own spelling ("the lexicon is just more text", LANE_M.md): one
/// shared population, sized 256+numEntries.
pub fn population(alloc: Allocator, corpus: *const Corpus) ![]u64 {
    const k = 256 + corpus.lex.numEntries();
    const n = try alloc.alloc(u64, k);
    @memset(n, 0);
    for (corpus.seq) |s| n[s] += 1;
    for (0..corpus.lex.numEntries()) |i| {
        for (corpus.lex.comps(i)) |c| n[c] += 1;
    }
    return n;
}

fn expandOneInto(alloc: Allocator, lex: *const Lexicon, tok: u32, out: *std.ArrayList(u8), stack: *std.ArrayList(u32)) !void {
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

pub fn expandEntryBytes(alloc: Allocator, lex: *const Lexicon, sym: u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(alloc);
    try expandOneInto(alloc, lex, sym, &out, &stack);
    return out.toOwnedSlice(alloc);
}

/// Expand every block and compare against the raw input, byte for byte,
/// with no token spanning a block barrier.
pub fn verifyExact(alloc: Allocator, raw: []const u8, corpus: *const Corpus) !bool {
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

// ============================================================ cost model
//
// This is the "one small interface" DESIGN.md/PLAN.md ask to keep behind a
// clean seam: everything above and below `Cost` only ever calls into it for
// bit costs, so a future swap to real encoded bytes (once `../src/`'s
// codec is stable) only touches this namespace and its two call sites
// (reparse's accept/reject gate, delete's batch gate).
pub const Cost = struct {
    pub const EventBreakdown = struct { def_bits: f64, use_bits: f64, n_def: u64, total_events: u64 };

    /// Bits for the DEF/USE event stream given final population counts.
    /// Every entry with pop>0 contributes exactly one DEF event (shared
    /// kind, wherever its first use lands) and pop-1 USE(x) events; bytes
    /// contribute pop USE(x) events and never a DEF (bucket 0 exists before
    /// anything is defined, DESIGN.md).
    pub fn eventBreakdown(pop: []const u64, num_entries: usize) EventBreakdown {
        var sum_use: f64 = 0;
        var total: u64 = 0;
        for (pop[0..256]) |c| {
            sum_use += flog(c);
            total += c;
        }
        var n_def: u64 = 0;
        for (0..num_entries) |i| {
            const c = pop[256 + i];
            if (c == 0) continue;
            n_def += 1;
            const uses = c - 1;
            sum_use += flog(uses);
            total += uses;
        }
        const grand = total + n_def;
        if (grand == 0) return .{ .def_bits = 0, .use_bits = 0, .n_def = 0, .total_events = 0 };
        const gf: f64 = @floatFromInt(grand);
        const all_bits = gf * log2f(gf) - sum_use - flog(n_def);
        const def_bits = if (n_def == 0) 0 else -@as(f64, @floatFromInt(n_def)) * log2f(@as(f64, @floatFromInt(n_def)) / gf);
        return .{ .def_bits = def_bits, .use_bits = all_bits - def_bits, .n_def = n_def, .total_events = grand };
    }

    pub fn eventBits(pop: []const u64, num_entries: usize) f64 {
        const eb = eventBreakdown(pop, num_entries);
        return eb.def_bits + eb.use_bits;
    }

    const MAX_ARITY_BUCKET: usize = 4096;

    /// Empirical-entropy code for each definition's arity, over entries
    /// with pop>0 (a dead entry was never defined so pays nothing).
    /// `arity_of` may be `lex`'s own arities, or a simulated post-splice
    /// arity array (delete's exact gate needs the latter, since inlining a
    /// deleted child grows its parent's arity).
    pub fn arityBits(arity_of: []const u32, pop: []const u64, num_entries: usize) f64 {
        var hist: [MAX_ARITY_BUCKET]u64 = @splat(0);
        var count: u64 = 0;
        for (0..num_entries) |i| {
            if (pop[256 + i] == 0) continue;
            const bucket = @min(arity_of[i], MAX_ARITY_BUCKET - 1);
            hist[bucket] += 1;
            count += 1;
        }
        if (count == 0) return 0;
        var sum_f: f64 = 0;
        for (hist) |h| sum_f += flog(h);
        const cf: f64 = @floatFromInt(count);
        return cf * log2f(cf) - sum_f;
    }

    const MAX_TIER: usize = 48;

    inline fn tierOf(uses: u64) usize {
        return @min(log2Floor(uses + 1), MAX_TIER - 1);
    }

    /// Empirical-entropy code for `tier(x) = floor(log2(uses(x)+1))`, the
    /// entry's "name" (DESIGN.md: which bucket-size class it joins).
    pub fn nameBits(pop: []const u64, num_entries: usize) f64 {
        var hist: [MAX_TIER]u64 = @splat(0);
        var count: u64 = 0;
        for (0..num_entries) |i| {
            const c = pop[256 + i];
            if (c == 0) continue;
            hist[tierOf(c)] += 1;
            count += 1;
        }
        if (count == 0) return 0;
        var sum_f: f64 = 0;
        for (hist) |h| sum_f += flog(h);
        const cf: f64 = @floatFromInt(count);
        return cf * log2f(cf) - sum_f;
    }

    /// Total est bits for a lexicon with population `pop` (milestone 1:
    /// global scope only). This is the exact accept/reject criterion for
    /// reparse and delete below.
    pub fn totalBits(alloc: Allocator, lex: *const Lexicon, pop: []const u64) !f64 {
        const n = lex.numEntries();
        const arities = try alloc.alloc(u32, n);
        defer alloc.free(arities);
        for (0..n) |i| arities[i] = @intCast(lex.arity(i));
        return eventBits(pop, n) + arityBits(arities, pop, n) + nameBits(pop, n);
    }

    /// Average real bits one *new* definition is estimated to cost (its
    /// share of the DEF pool + its arity code + its name code), measured
    /// from the *current* lexicon rather than hand-picked -- self
    /// calibrating, used only to rank/score candidates in propose/delete
    /// (never in the exact gates above).
    pub fn avgOverhead(alloc: Allocator, lex: *const Lexicon, pop: []const u64) !f64 {
        const n = lex.numEntries();
        if (n == 0) return 10.0; // bootstrap guess before any entry exists
        const eb = eventBreakdown(pop, n);
        if (eb.n_def == 0) return 10.0;
        const arr = try alloc.alloc(u32, n);
        defer alloc.free(arr);
        for (0..n) |i| arr[i] = @intCast(lex.arity(i));
        const ab = arityBits(arr, pop, n);
        const nb = nameBits(pop, n);
        return (eb.def_bits + ab + nb) / @as(f64, @floatFromInt(eb.n_def));
    }
};

/// Per-occurrence marginal bit cost, used only to rank DP/propose/delete
/// search choices: the cost of *one more* use of `x`, given the current
/// population. A byte's marginal cost is its plain USE rate; an entry's is
/// the rate of its (pop-1) *reuse* events (its first occurrence is a
/// one-time DEF, priced separately by `Cost.avgOverhead`, not per
/// occurrence -- see LANE_L.md "why the DP doesn't see DEF cost").
pub const DPBits = struct { bits: []f64, total_events: u64 };

pub fn dpMarginalBits(alloc: Allocator, pop: []const u64, num_entries: usize) !DPBits {
    const k = 256 + num_entries;
    const use = try alloc.alloc(f64, k);
    var n_def: u64 = 0;
    var total: u64 = 0;
    for (0..256) |b| {
        use[b] = @floatFromInt(pop[b]);
        total += pop[b];
    }
    for (0..num_entries) |i| {
        const c = pop[256 + i];
        if (c > 0) n_def += 1;
        const u: f64 = if (c >= 2) @floatFromInt(c - 1) else 0.5;
        use[256 + i] = u;
        total += if (c >= 2) c - 1 else 0;
    }
    const grand: f64 = @floatFromInt(total + n_def);
    const bits = try alloc.alloc(f64, k);
    for (0..k) |i| {
        const c = if (use[i] > 0) use[i] else 0.5;
        bits[i] = -log2f(c / grand);
    }
    alloc.free(use);
    return .{ .bits = bits, .total_events = total + n_def };
}

// ============================================================== options

pub const Opts = struct {
    max_iters: usize = 10,
    converge_frac: f64 = 0.001,
    max_material_len: u32 = 256,
    triples: bool = true,
    /// Score deletion candidates by min(global, scoped) per-use cost so a
    /// bursty word (heavy reuse confined to a few blocks) isn't deleted for
    /// looking globally rare -- milestone 2's "let the parser know local
    /// costs" (see `scopeReport` below).
    scope_aware_delete: bool = true,
};

pub const IterLog = struct {
    iter: usize,
    entries: usize,
    tokens: usize,
    est_bits: f64,
    proposed_pairs: usize,
    proposed_triples: usize,
    deleted: usize,
};

// ==================================================================== trie
//
// Mechanical (cost-model-agnostic): a small sorted-edge-list byte trie, no
// hashmap anywhere, ported from Lane M's `parse.zig` almost verbatim -- see
// that file's doc comment for why (Lane A's hashmap trie took seconds per
// parse; this one doesn't).

const NO_SYM: u32 = std.math.maxInt(u32);
const TrieEdge = struct { byte: u8, child: u32 };
const TrieNode = struct { edges: std.ArrayList(TrieEdge) = .empty, accept: u32 = NO_SYM };

pub const Trie = struct {
    nodes: std.ArrayList(TrieNode) = .empty,

    fn init(alloc: Allocator) !Trie {
        var t: Trie = .{};
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
    fn insertSorted(self: *Trie, alloc: Allocator, bytes: []const u8, sym: u32, prev: []const u8) !void {
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

/// Materialise byte expansions for every entry whose expansion is
/// <= max_len (a bounded approximation: longer entries are simply left
/// unreparsed/unmatchable, same policy Lane A/M shipped with).
pub fn materializeAll(alloc: Allocator, lex: *const Lexicon, max_len: u32) ![]?[]u8 {
    const n = lex.numEntries();
    const k = 256 + n;
    const bytes = try alloc.alloc(?[]u8, k);
    for (0..256) |b| {
        const buf = try alloc.alloc(u8, 1);
        buf[0] = @intCast(b);
        bytes[b] = buf;
    }
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

pub fn buildTrie(alloc: Allocator, matbytes: []const ?[]u8) !Trie {
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
/// `bits` (the DP marginal proxy above). If `explen_limit` is set, a
/// candidate symbol is only usable when its expansion is strictly shorter
/// -- keeps the entry DAG acyclic when re-parsing an entry's own spelling.
pub fn dpParse(
    alloc: Allocator,
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

/// RE-PARSE: rebuild the trie from the current lexicon, re-tokenise every
/// corpus block (against `raw`) and every entry's own spelling, and keep
/// the result only if the honestly-recomputed `Cost.totalBits` improved.
pub fn reparseRound(alloc: Allocator, corpus: *Corpus, raw: []const u8, max_material_len: u32) !bool {
    const pop0 = try population(alloc, corpus);
    const bits_before = try Cost.totalBits(alloc, &corpus.lex, pop0);
    const dp0 = try dpMarginalBits(alloc, pop0, corpus.lex.numEntries());

    const matbytes = try materializeAll(alloc, &corpus.lex, max_material_len);
    const trie = try buildTrie(alloc, matbytes);

    var new_seq: std.ArrayList(u32) = .empty;
    var new_block_end: std.ArrayList(usize) = .empty;
    var raw_start: usize = 0;
    for (corpus.block_end) |_| {
        const raw_end = @min(raw.len, raw_start + corpus.block_bytes);
        try dpParse(alloc, &trie, raw[raw_start..raw_end], dp0.bits, corpus.lex.explen.items, null, &new_seq);
        try new_block_end.append(alloc, new_seq.items.len);
        raw_start = raw_end;
    }

    var builder = try LexBuilder.init(alloc);
    for (0..corpus.lex.numEntries()) |i| {
        const sym = 256 + i;
        const el = corpus.lex.explen.items[i];
        if (matbytes[sym]) |mb| {
            var toks: std.ArrayList(u32) = .empty;
            try dpParse(alloc, &trie, mb, dp0.bits, corpus.lex.explen.items, el, &toks);
            _ = try builder.addEntry(alloc, toks.items, el);
        } else {
            _ = try builder.addEntry(alloc, corpus.lex.comps(i), el);
        }
    }
    var new_lex = builder.finish();

    var candidate = Corpus{ .lex = new_lex, .seq = try new_seq.toOwnedSlice(alloc), .block_end = try new_block_end.toOwnedSlice(alloc), .block_bytes = corpus.block_bytes };
    const pop1 = try population(alloc, &candidate);
    const bits_after = try Cost.totalBits(alloc, &candidate.lex, pop1);

    if (bits_after < bits_before) {
        corpus.* = candidate;
        return true;
    }
    new_lex.deinit(alloc);
    return false;
}

// =============================================================== propose
//
// PROPOSE: tally adjacent w-grams (w=2 pairs, w=3 triples) over the current
// parse *and* every entry's own spelling, score by estimated marginal
// bit-delta (`dpMarginalBits` + the self-calibrated `Cost.avgOverhead`),
// keep a role-consistent batch (no symbol doubles as a member of two
// different accepted candidates this round -- generalised from Lane A's
// builder trick), and rewrite the corpus and every spelling in one pass.
// Sort + run-length count + binary search throughout, no hashmap.

fn Key(comptime w: usize) type {
    return [w]u32;
}

fn keyLess(comptime w: usize, _: void, a: Key(w), b: Key(w)) bool {
    return std.mem.order(u32, &a, &b) == .lt;
}

// Tallying is the one place a hashmap wins over a sorted array: it scales
// with the *token* count (millions, on the early high-volume rounds), not
// the candidate count. An earlier version collected every window into a
// flat array and sorted it (matching the "sorted arrays over hashmaps"
// idiom used everywhere else in this file); measured on gcide.eval8, that
// sort alone cost multiple seconds per round on the first few rounds
// (~8M tokens) and was the dominant cost in the whole learner -- a
// documented negative result, see LANE_L.md. `std.AutoHashMap` (Lane M's
// own choice here) is a clear win at this scale; every *other* hashmap in
// this file was still avoidable and stayed a sorted array/trie.
fn tallyWindows(comptime w: usize, alloc: Allocator, corpus: *const Corpus) !std.AutoHashMap(Key(w), u64) {
    var tally = std.AutoHashMap(Key(w), u64).init(alloc);
    var start: usize = 0;
    for (corpus.block_end) |end| {
        try tallyFrom(w, &tally, corpus.seq[start..end]);
        start = end;
    }
    for (0..corpus.lex.numEntries()) |i| {
        try tallyFrom(w, &tally, corpus.lex.comps(i));
    }
    return tally;
}

fn tallyFrom(comptime w: usize, tally: *std.AutoHashMap(Key(w), u64), seq: []const u32) !void {
    if (seq.len < w) return;
    var i: usize = 0;
    // For pairs only: skip every other window inside a run of identical
    // symbols so "aaaa" doesn't get double-counted as overlapping "aa"s
    // (Lane M's trick; not applied to triples, matching Lane M's own
    // simpler -- "adequate, never regressed" -- triple handling).
    var skip_at: usize = std.math.maxInt(usize);
    while (i + w <= seq.len) : (i += 1) {
        if (w == 2 and seq[i] == seq[i + 1]) {
            if (skip_at == i) continue;
            skip_at = i + 1;
        }
        var k: Key(w) = undefined;
        for (0..w) |j| k[j] = seq[i + j];
        const gop = try tally.getOrPut(k);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
}

fn existingArityW(comptime w: usize, alloc: Allocator, lex: *const Lexicon) ![]Key(w) {
    var keys: std.ArrayList(Key(w)) = .empty;
    for (0..lex.numEntries()) |i| {
        const cs = lex.comps(i);
        if (cs.len != w) continue;
        var k: Key(w) = undefined;
        @memcpy(&k, cs[0..w]);
        try keys.append(alloc, k);
    }
    const Ctx = struct {
        fn lt(_: void, a: Key(w), b: Key(w)) bool {
            return keyLess(w, {}, a, b);
        }
    };
    std.mem.sort(Key(w), keys.items, {}, Ctx.lt);
    return keys.toOwnedSlice(alloc);
}

fn sortedContains(comptime w: usize, hay: []const Key(w), needle: Key(w)) bool {
    return std.sort.binarySearch(Key(w), hay, needle, struct {
        fn cmp(ctx: Key(w), item: Key(w)) std.math.Order {
            return std.mem.order(u32, &ctx, &item);
        }
    }.cmp) != null;
}

const Cand = struct { key_idx: u32, count: u64, score: f64 };
fn candDesc(_: void, x: Cand, y: Cand) bool {
    if (x.score != y.score) return x.score > y.score;
    return x.key_idx < y.key_idx;
}

fn substituteWindows(comptime w: usize, alloc: Allocator, seq: []const u32, sorted_keys: []const Key(w), sorted_ids: []const u32, out: *std.ArrayList(u32)) !void {
    const Cmp = struct {
        fn cmp(ctx: Key(w), item: Key(w)) std.math.Order {
            return std.mem.order(u32, &ctx, &item);
        }
    };
    var i: usize = 0;
    while (i < seq.len) {
        if (i + w <= seq.len) {
            var k: Key(w) = undefined;
            for (0..w) |j| k[j] = seq[i + j];
            if (std.sort.binarySearch(Key(w), sorted_keys, k, Cmp.cmp)) |pos| {
                try out.append(alloc, sorted_ids[pos]);
                i += w;
                continue;
            }
        }
        try out.append(alloc, seq[i]);
        i += 1;
    }
}

/// Returns the number of new w-ary entries accepted this round.
pub fn proposeNGram(comptime w: usize, alloc: Allocator, corpus: *Corpus, dpbits: []const f64, avg_overhead: f64, max_material_len: u32) !usize {
    _ = max_material_len;
    var tally = try tallyWindows(w, alloc, corpus);
    if (tally.count() == 0) return 0;

    const existing = try existingArityW(w, alloc, &corpus.lex);

    var uniq: std.ArrayList(Key(w)) = .empty;
    var counts: std.ArrayList(u64) = .empty;
    var it = tally.iterator();
    while (it.next()) |e| {
        try uniq.append(alloc, e.key_ptr.*);
        try counts.append(alloc, e.value_ptr.*);
    }

    var cands: std.ArrayList(Cand) = .empty;
    for (uniq.items, 0..) |k, idx| {
        const c = counts.items[idx];
        if (c < 2 or sortedContains(w, existing, k)) continue;
        var old_bits: f64 = 0;
        for (k) |s| old_bits += dpbits[s];
        const cf: f64 = @floatFromInt(c);
        // old cost = c*old_bits (spelling each occurrence with its w parts);
        // new cost = (c-1)*bits_new_est + avg_overhead (one shared DEF,
        // c-1 ordinary reuses at a fresh entry's own estimated rate).
        const bits_new_est = -log2f(@max(cf - 1, 0.5) / @as(f64, @floatFromInt(corpus.seq.len + 1)));
        const score = cf * old_bits - (cf - 1) * bits_new_est - avg_overhead;
        if (score > 0) try cands.append(alloc, .{ .key_idx = @intCast(idx), .count = c, .score = score });
    }
    if (cands.items.len == 0) return 0;
    std.mem.sort(Cand, cands.items, {}, candDesc);

    const old_num_entries = corpus.lex.numEntries();
    const k_alpha = 256 + old_num_entries;

    var accepted_keys: std.ArrayList(Key(w)) = .empty;
    var accepted_ids: std.ArrayList(u32) = .empty;
    var accepted_explen: std.ArrayList(u32) = .empty;
    var next_id: u32 = @intCast(256 + old_num_entries);

    if (w == 2) {
        // Asymmetric left/right role consistency (Lane A's builder trick,
        // LANE_M.md): a symbol may be the left member of one accepted pair
        // *and* the right member of a different one in the same round --
        // only a genuine left/right collision on the *same* symbol is
        // forbidden. Substitution scans left to right, so no ambiguity
        // ever reaches the corpus even when e.g. "ab" and "bc" are both
        // accepted. This roughly doubles the merges accepted per round
        // versus the simpler "claim once, exclude everywhere" rule below,
        // which is why only *triples* use that simpler rule.
        const roles = try alloc.alloc(u8, k_alpha);
        @memset(roles, 0);
        for (cands.items) |cand| {
            const key = uniq.items[cand.key_idx];
            const sa = key[0];
            const sb = key[1];
            if (sa == sb) {
                if (roles[sa] != 0) continue;
                roles[sa] = 3;
            } else {
                if (roles[sa] & 2 != 0 or roles[sb] & 1 != 0) continue;
                roles[sa] |= 1;
                roles[sb] |= 2;
            }
            var el: u32 = 0;
            for (key) |s| el += explenOf(&corpus.lex, s);
            try accepted_keys.append(alloc, key);
            try accepted_ids.append(alloc, next_id);
            try accepted_explen.append(alloc, el);
            next_id += 1;
        }
    } else {
        const used = try alloc.alloc(bool, k_alpha);
        @memset(used, false);
        for (cands.items) |cand| {
            const key = uniq.items[cand.key_idx];
            var clash = false;
            for (key) |s| {
                if (used[s]) {
                    clash = true;
                    break;
                }
            }
            if (clash) continue;
            for (key) |s| used[s] = true;
            var el: u32 = 0;
            for (key) |s| el += explenOf(&corpus.lex, s);
            try accepted_keys.append(alloc, key);
            try accepted_ids.append(alloc, next_id);
            try accepted_explen.append(alloc, el);
            next_id += 1;
        }
    }
    if (accepted_keys.items.len == 0) return 0;

    // Sort the accepted set by key for substitution's binary search.
    const order = try alloc.alloc(u32, accepted_keys.items.len);
    for (0..order.len) |ii| order[ii] = @intCast(ii);
    const OCtx = struct {
        keys: []const Key(w),
        fn lt(self: @This(), a: u32, b: u32) bool {
            return keyLess(w, {}, self.keys[a], self.keys[b]);
        }
    };
    std.mem.sort(u32, order, OCtx{ .keys = accepted_keys.items }, OCtx.lt);
    const sorted_keys = try alloc.alloc(Key(w), order.len);
    const sorted_ids = try alloc.alloc(u32, order.len);
    for (order, 0..) |oi, pos| {
        sorted_keys[pos] = accepted_keys.items[oi];
        sorted_ids[pos] = accepted_ids.items[oi];
    }

    var builder = try LexBuilder.init(alloc);
    for (0..old_num_entries) |ei| {
        var newcomps: std.ArrayList(u32) = .empty;
        try substituteWindows(w, alloc, corpus.lex.comps(ei), sorted_keys, sorted_ids, &newcomps);
        _ = try builder.addEntry(alloc, newcomps.items, corpus.lex.explen.items[ei]);
    }
    for (accepted_keys.items, 0..) |key, idx| {
        _ = try builder.addEntry(alloc, &key, accepted_explen.items[idx]);
    }

    var new_seq: std.ArrayList(u32) = .empty;
    var new_block_end: std.ArrayList(usize) = .empty;
    var start: usize = 0;
    for (corpus.block_end) |end| {
        try substituteWindows(w, alloc, corpus.seq[start..end], sorted_keys, sorted_ids, &new_seq);
        try new_block_end.append(alloc, new_seq.items.len);
        start = end;
    }

    corpus.lex = builder.finish();
    corpus.seq = try new_seq.toOwnedSlice(alloc);
    corpus.block_end = try new_block_end.toOwnedSlice(alloc);
    return accepted_keys.items.len;
}

// ==================================================================== delete
//
// DELETE: an entry may be deleted wherever it's referenced (corpus, or any
// other entry's spelling); splicing mechanics ported from Lane M's
// `delete.zig` (cost-model agnostic -- they only move population around),
// re-scored under the DEF/USE objective. Ranking is a cheap per-candidate
// heuristic (search order only); the actual accept/reject is a batch-level
// exact recompute of `Cost.totalBits` with a halving safety net, so the
// heuristic's imprecision can never make a round measurably worse.

pub fn buildResolved(alloc: Allocator, lex: *const Lexicon, marked: []const bool) ![]?[]u32 {
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

fn emitResolveAll(alloc: Allocator, out: *std.ArrayList(u32), items: []const u32, marked: []const bool, resolved: []const ?[]u32) !void {
    for (items) |t| {
        if (t >= 256 and marked[t - 256]) {
            try out.appendSlice(alloc, resolved[t - 256].?);
        } else {
            try out.append(alloc, t);
        }
    }
}

pub fn spliceMarked(alloc: Allocator, corpus: *Corpus, marked: []const bool) !void {
    const num_entries = corpus.lex.numEntries();
    const resolved = try buildResolved(alloc, &corpus.lex, marked);

    var new_seq: std.ArrayList(u32) = .empty;
    var new_block_end: std.ArrayList(usize) = .empty;
    var start: usize = 0;
    for (corpus.block_end) |end| {
        try emitResolveAll(alloc, &new_seq, corpus.seq[start..end], marked, resolved);
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
        try emitResolveAll(alloc, &spliced, corpus.lex.comps(i), marked, resolved);
        for (spliced.items) |*t| t.* = remap[t.*];
        _ = try builder.addEntry(alloc, spliced.items, corpus.lex.explen.items[i]);
    }
    for (new_seq.items) |*t| t.* = remap[t.*];

    corpus.lex = builder.finish();
    corpus.seq = try new_seq.toOwnedSlice(alloc);
    corpus.block_end = try new_block_end.toOwnedSlice(alloc);
}

/// Tally `items` into `n`/`m`, resolving marked entries to their spelling;
/// returns the (post-splice) length of `items` itself, which doubles as the
/// new arity of the entry `items` belongs to (if any) for the exact gate.
fn tallyAndLen(items: []const u32, marked: []const bool, resolved: []const ?[]u32, n: []u64) usize {
    var len: usize = 0;
    for (items) |t| {
        if (t >= 256 and marked[t - 256]) {
            const r = resolved[t - 256].?;
            for (r) |x| n[x] += 1;
            len += r.len;
        } else {
            n[t] += 1;
            len += 1;
        }
    }
    return len;
}

/// Exact recomputation of `Cost.totalBits` for a simulated splice of
/// `marked`, including the second-order effect Lane M's flat model never
/// had to worry about: inlining a deleted child grows its (surviving)
/// parent's arity, which can shift that parent's own arity/tier bucket.
fn simulateDeleteBits(alloc: Allocator, corpus: *const Corpus, marked: []const bool) !f64 {
    const resolved = try buildResolved(alloc, &corpus.lex, marked);
    const num_entries = corpus.lex.numEntries();
    const k = 256 + num_entries;
    const pop = try alloc.alloc(u64, k);
    @memset(pop, 0);
    _ = tallyAndLen(corpus.seq, marked, resolved, pop);
    const arity_of = try alloc.alloc(u32, num_entries);
    @memset(arity_of, 0);
    var num_alive: usize = 0;
    for (0..num_entries) |i| {
        if (marked[i]) continue;
        arity_of[i] = @intCast(tallyAndLen(corpus.lex.comps(i), marked, resolved, pop));
        num_alive += 1;
    }
    return Cost.eventBits(pop, num_entries) + Cost.arityBits(arity_of, pop, num_entries) + Cost.nameBits(pop, num_entries);
}

const DelCand = struct { idx: u32, benefit: f64 };
fn delCandDesc(_: void, x: DelCand, y: DelCand) bool {
    return x.benefit > y.benefit;
}

/// Set true to print a short per-round trace of the delete search (used
/// during development to confirm the halving safety net and the scope-
/// aware ranking behave as intended; harmless, off by default).
pub var debug_delete: bool = false;

pub fn deletePass(alloc: Allocator, corpus: *Corpus, opts: Opts) !usize {
    const pop = try population(alloc, corpus);
    const num_entries = corpus.lex.numEntries();
    if (num_entries == 0) return 0;
    const current_bits = try Cost.totalBits(alloc, &corpus.lex, pop);

    const dp = try dpMarginalBits(alloc, pop, num_entries);
    const avg_overhead = try Cost.avgOverhead(alloc, &corpus.lex, pop);
    // `keep_cost[i]` is the *total* estimated bits this entry's existence
    // costs (every DEF/local-DEF plus every USE/local-use it's charged
    // for). Without scope-awareness that's just the plain global total;
    // with it, whichever of {global, scoped} is cheaper -- see
    // `ScopeReport`'s doc comment for why this must stay a total, not a
    // per-use rate, to avoid double-charging the definition overhead.
    var keep_cost: []f64 = undefined;
    if (opts.scope_aware_delete) {
        const scoped = try scopeReport(alloc, corpus, pop, dp.bits, avg_overhead, dp.total_events);
        keep_cost = scoped.effective_total_bits;
    } else {
        keep_cost = try alloc.alloc(f64, num_entries);
        for (0..num_entries) |i| {
            const p = pop[256 + i];
            keep_cost[i] = avg_overhead + @as(f64, @floatFromInt(if (p >= 2) p - 1 else 0)) * dp.bits[256 + i];
        }
    }

    var cands: std.ArrayList(DelCand) = .empty;
    var best_benefit: f64 = -std.math.inf(f64);
    for (0..num_entries) |i| {
        const u: f64 = @floatFromInt(pop[256 + i]);
        if (u == 0) continue;
        var comp_bits: f64 = 0;
        for (corpus.lex.comps(i)) |c| comp_bits += dp.bits[c];
        const benefit = keep_cost[i] - u * comp_bits;
        if (benefit > best_benefit) best_benefit = benefit;
        if (benefit > 0) try cands.append(alloc, .{ .idx = @intCast(i), .benefit = benefit });
    }
    if (debug_delete) std.debug.print("  [delete] num_entries={d} positive_cands={d} best_benefit={d:.2} avg_overhead={d:.2}\n", .{ num_entries, cands.items.len, best_benefit, avg_overhead });
    if (cands.items.len == 0) return 0;
    std.mem.sort(DelCand, cands.items, {}, delCandDesc);
    if (debug_delete) std.debug.print("  [delete] cands={d} top_benefit={d:.2} current_bits={d:.0}\n", .{ cands.items.len, cands.items[0].benefit, current_bits });

    const marked = try alloc.alloc(bool, num_entries);
    @memset(marked, false);
    var accepted: usize = 0;
    var mcount = cands.items.len;
    while (mcount > 0) {
        @memset(marked, false);
        for (cands.items[0..mcount]) |c| marked[c.idx] = true;
        const trial = try simulateDeleteBits(alloc, corpus, marked);
        if (debug_delete) std.debug.print("  [delete] mcount={d} trial_bits={d:.0}\n", .{ mcount, trial });
        if (trial < current_bits) {
            accepted = mcount;
            break;
        }
        mcount /= 2;
    }
    if (accepted == 0) return 0;
    @memset(marked, false);
    for (cands.items[0..accepted]) |c| marked[c.idx] = true;

    try spliceMarked(alloc, corpus, marked);
    return accepted;
}

// ============================================================ scope (milestone 2)
//
// A bursty entry -- e.g. a dictionary headword repeated inside its own
// entry -- can be globally rare (so a pure per-symbol USE rate looks
// expensive) while being *locally* cheap: DESIGN.md's bucket lifetimes let
// a block-confined entry be redefined in each block it recurs in and
// addressed by rank among that block's other locally-reused entries,
// `-log2(n_LOCAL_j/N) + j` raw bits with `j = floor(log2(rank+1))`.
//
// Simplification (documented in LANE_L.md): we do not physically rewrite
// singleton-block occurrences back to raw components (an entry that
// already exists, because it repeats *somewhere*, is never more expensive
// to reference again than to respell, so there is no byte-exact reason to
// special-case that single occurrence). Scope is therefore purely a
// *cost-accounting* choice per entry -- global or local, whichever is
// cheaper -- that (a) protects bursty-but-globally-rare entries from
// `deletePass`, and (b) is reported as a second, milestone-2 total
// alongside the milestone-1 global-only total. The real encoder
// (`../src/plan.zig`, `Options.scoped`) already buckets confined-to-one-
// block entries with a short-lived bucket automatically at encode time;
// this estimate is what tells the *learner* not to throw such entries away
// before the encoder gets a chance to.
pub const ScopeReport = struct {
    /// Per entry, as *totals* (not per-use rates -- see LANE_L.md "a
    /// double-counting bug" for why the delete heuristic needs the total,
    /// not an amortised-per-use figure that already bakes in a share of
    /// the definition overhead `deletePass` adds again separately):
    /// min(global total cost, scoped total cost) for keeping this entry
    /// alive at all (its DEF/local-DEFs + every USE/local-USE it costs).
    effective_total_bits: []f64,
    is_local: []bool,
    num_local: usize,
    est_bits_global_only: f64,
    est_bits_with_scope: f64,
    local_raw_bits: f64,
    local_entropy_bits: f64,
};

pub fn scopeReport(alloc: Allocator, corpus: *const Corpus, pop: []const u64, dpbits: []const f64, avg_overhead: f64, total_events: u64) !ScopeReport {
    const num_entries = corpus.lex.numEntries();
    const blocks_multi = try alloc.alloc(u32, num_entries);
    const blocks_single = try alloc.alloc(u32, num_entries);
    @memset(blocks_multi, 0);
    @memset(blocks_single, 0);

    const Rec = struct { idx: u32, tier: u32, events: u32 };
    var records: std.ArrayList(Rec) = .empty;
    var tier_hist: [Cost.MAX_TIER]u64 = @splat(0);

    const cnt = try alloc.alloc(u32, num_entries);
    @memset(cnt, 0);
    var touched: std.ArrayList(u32) = .empty;
    const BlockCount = struct { idx: u32, c: u32 };
    var multi_this_block: std.ArrayList(BlockCount) = .empty;

    var start: usize = 0;
    for (corpus.block_end) |end| {
        touched.clearRetainingCapacity();
        multi_this_block.clearRetainingCapacity();
        for (corpus.seq[start..end]) |s| {
            if (s < 256) continue;
            const idx = s - 256;
            if (cnt[idx] == 0) try touched.append(alloc, idx);
            cnt[idx] += 1;
        }
        for (touched.items) |idx| {
            const c = cnt[idx];
            if (c == 1) {
                blocks_single[idx] += 1;
            } else {
                try multi_this_block.append(alloc, .{ .idx = idx, .c = c });
            }
            cnt[idx] = 0;
        }
        std.mem.sort(BlockCount, multi_this_block.items, {}, struct {
            fn lt(_: void, a: BlockCount, b: BlockCount) bool {
                return a.c > b.c;
            }
        }.lt);
        for (multi_this_block.items, 0..) |e, rank| {
            blocks_multi[e.idx] += 1;
            const tier = log2Floor(@as(u64, rank) + 1);
            const tt = @min(tier, Cost.MAX_TIER - 1);
            const events = e.c - 1;
            tier_hist[tt] += events;
            try records.append(alloc, .{ .idx = e.idx, .tier = tt, .events = events });
        }
        start = end;
    }

    var n_local_events: u64 = 0;
    for (tier_hist) |h| n_local_events += h;
    const local_pool_n: f64 = @floatFromInt(@max(total_events, 1));

    const entry_local_cost = try alloc.alloc(f64, num_entries);
    @memset(entry_local_cost, 0);
    var local_raw_bits: f64 = 0;
    var local_entropy_bits: f64 = 0;
    for (records.items) |r| {
        const h = tier_hist[r.tier];
        const p = @as(f64, @floatFromInt(h)) / local_pool_n;
        const per_event = -log2f(p) + @as(f64, @floatFromInt(r.tier));
        const ev: f64 = @floatFromInt(r.events);
        entry_local_cost[r.idx] += ev * per_event;
        local_raw_bits += ev * @as(f64, @floatFromInt(r.tier));
        local_entropy_bits += ev * -log2f(p);
    }

    const effective = try alloc.alloc(f64, num_entries);
    const is_local = try alloc.alloc(bool, num_entries);
    var num_local: usize = 0;
    var global_only: f64 = 0;
    var with_scope: f64 = 0;
    for (0..256) |b| {
        global_only += @as(f64, @floatFromInt(pop[b])) * dpbits[b];
    }
    with_scope = global_only;
    for (0..num_entries) |i| {
        const p = pop[256 + i];
        const global_cost = avg_overhead + @as(f64, @floatFromInt(if (p >= 2) p - 1 else 0)) * dpbits[256 + i];
        var scoped_cost = global_cost;
        if (blocks_multi[i] > 0 or blocks_single[i] > 0) {
            var comp_bits: f64 = 0;
            for (corpus.lex.comps(i)) |c| comp_bits += dpbits[c];
            scoped_cost = @as(f64, @floatFromInt(blocks_multi[i])) * avg_overhead +
                entry_local_cost[i] +
                @as(f64, @floatFromInt(blocks_single[i])) * comp_bits;
        }
        effective[i] = @min(global_cost, scoped_cost);
        is_local[i] = scoped_cost < global_cost and p > 0;
        if (is_local[i]) num_local += 1;
        global_only += global_cost;
        with_scope += effective[i];
    }

    return .{
        .effective_total_bits = effective,
        .is_local = is_local,
        .num_local = num_local,
        .est_bits_global_only = global_only,
        .est_bits_with_scope = with_scope,
        .local_raw_bits = local_raw_bits,
        .local_entropy_bits = local_entropy_bits,
    };
}

// ==================================================================== learn

pub const Scope = enum(u8) { global, local };

pub const Stats = struct {
    iterations: usize,
    seed_entries: usize,
    num_entries: usize,
    num_tokens: usize,
    def_bits: f64,
    use_bits: f64,
    arity_bits: f64,
    name_bits: f64,
    total_bits_global: f64,
    num_local_entries: usize,
    total_bits_scoped: f64,
    local_raw_bits: f64,
    local_entropy_bits: f64,
};

pub const Parse = struct {
    corpus: Corpus,
    scope: []Scope,
    stats: Stats,
    log: []IterLog,

    pub fn deinit(self: *Parse, alloc: Allocator) void {
        self.corpus.deinit(alloc);
        alloc.free(self.scope);
        alloc.free(self.log);
    }
};

/// Converge a byte-seeded corpus to a compositional MDL lexicon under the
/// DEF/USE objective, then run the scope pass. `gpa` need not be an arena:
/// all iteration scratch lives in an internal arena and only the final
/// result is duplicated into `gpa`.
pub fn learn(gpa: Allocator, input: []const u8, block_bytes: usize, opts: Opts) !Parse {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var corpus = try seedBytes(a, input, block_bytes);
    var log: std.ArrayList(IterLog) = .empty;

    var prev_bits: f64 = std.math.inf(f64);
    var iter: usize = 0;
    while (iter < opts.max_iters) : (iter += 1) {
        const snapshot = corpus;

        const pop0 = try population(a, &corpus);
        const dp0 = try dpMarginalBits(a, pop0, corpus.lex.numEntries());
        const avg_overhead = try Cost.avgOverhead(a, &corpus.lex, pop0);
        const p2 = try proposeNGram(2, a, &corpus, dp0.bits, avg_overhead, opts.max_material_len);
        var p3: usize = 0;
        if (opts.triples) {
            const pop1 = try population(a, &corpus);
            const dp1 = try dpMarginalBits(a, pop1, corpus.lex.numEntries());
            const avg_overhead1 = try Cost.avgOverhead(a, &corpus.lex, pop1);
            p3 = try proposeNGram(3, a, &corpus, dp1.bits, avg_overhead1, opts.max_material_len);
        }
        const changed = try reparseRound(a, &corpus, input, opts.max_material_len);
        const deleted = try deletePass(a, &corpus, opts);

        const pop_f = try population(a, &corpus);
        const bits = try Cost.totalBits(a, &corpus.lex, pop_f);
        try log.append(a, .{ .iter = iter, .entries = corpus.lex.numEntries(), .tokens = corpus.seq.len, .est_bits = bits / 8.0, .proposed_pairs = p2, .proposed_triples = p3, .deleted = deleted });

        if (bits > prev_bits) {
            corpus = snapshot;
            break;
        }
        if (p2 == 0 and p3 == 0 and deleted == 0 and !changed) break;
        if (iter > 0) {
            const improvement = (prev_bits - bits) / prev_bits;
            if (improvement < opts.converge_frac) break;
        }
        prev_bits = bits;
    }

    const pop_final = try population(a, &corpus);
    const eb = Cost.eventBreakdown(pop_final, corpus.lex.numEntries());
    const n = corpus.lex.numEntries();
    const arities = try a.alloc(u32, n);
    for (0..n) |i| arities[i] = @intCast(corpus.lex.arity(i));
    const arity_bits = Cost.arityBits(arities, pop_final, n);
    const name_bits = Cost.nameBits(pop_final, n);
    const dpf = try dpMarginalBits(a, pop_final, n);
    const avg_overhead_f = try Cost.avgOverhead(a, &corpus.lex, pop_final);
    const scoped = try scopeReport(a, &corpus, pop_final, dpf.bits, avg_overhead_f, dpf.total_events);

    const stats = Stats{
        .iterations = log.items.len,
        .seed_entries = 0,
        .num_entries = n,
        .num_tokens = corpus.seq.len,
        .def_bits = eb.def_bits,
        .use_bits = eb.use_bits,
        .arity_bits = arity_bits,
        .name_bits = name_bits,
        .total_bits_global = eb.def_bits + eb.use_bits + arity_bits + name_bits,
        .num_local_entries = scoped.num_local,
        .total_bits_scoped = scoped.est_bits_with_scope,
        .local_raw_bits = scoped.local_raw_bits,
        .local_entropy_bits = scoped.local_entropy_bits,
    };

    const out_scope = try gpa.alloc(Scope, n);
    for (0..n) |i| out_scope[i] = if (scoped.is_local[i]) .local else .global;

    const out_corpus = Corpus{
        .lex = try dupeLexicon(gpa, &corpus.lex),
        .seq = try gpa.dupe(u32, corpus.seq),
        .block_end = try gpa.dupe(usize, corpus.block_end),
        .block_bytes = corpus.block_bytes,
    };
    const out_log = try gpa.dupe(IterLog, log.items);

    return .{ .corpus = out_corpus, .scope = out_scope, .stats = stats, .log = out_log };
}

// ======================================================================= tests

test "seedBytes covers the whole input in blocks" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const raw = "hello, world! hello again.";
    var corpus = try seedBytes(a, raw, 8);
    try std.testing.expect(try verifyExact(a, raw, &corpus));
    try std.testing.expectEqual(@as(usize, 4), corpus.block_end.len);
}

test "flog identity matches direct sum" {
    const counts = [_]u64{ 5, 3, 0, 12, 1 };
    var m: u64 = 0;
    for (counts) |c| m += c;
    const mf: f64 = @floatFromInt(m);
    var direct: f64 = 0;
    for (counts) |c| {
        if (c == 0) continue;
        const cf: f64 = @floatFromInt(c);
        direct += -cf * log2f(cf / mf);
    }
    var viaFlog: f64 = 0;
    for (counts) |c| viaFlog += flog(c);
    const identity = mf * log2f(mf) - viaFlog;
    try std.testing.expect(@abs(direct - identity) < 1e-6);
}

test "a twice-used entry costs one shared DEF plus one USE, not two rare events" {
    // Population: one entry used twice (pop=2), nothing else referencing it.
    var pop = [_]u64{0} ** 258;
    pop[256] = 2;
    // Also give the alphabet some byte traffic so the DEF pool isn't trivial.
    for (0..256) |b| pop[b] = 10;
    const eb = Cost.eventBreakdown(&pop, 1);
    // n_def = 1 (one entry, one DEF event); use pool = 1 (its second use) + 2560 byte uses.
    try std.testing.expectEqual(@as(u64, 1), eb.n_def);
}

test "learn round-trips exactly on repetitive text" {
    const alloc = std.testing.allocator;
    const raw = "the quick brown fox jumps over the lazy dog. " ** 30;
    var parse = try learn(alloc, raw, 4096, .{ .max_iters = 6 });
    defer parse.deinit(alloc);
    try std.testing.expect(try verifyExact(alloc, raw, &parse.corpus));
    try std.testing.expect(parse.corpus.lex.numEntries() > 0);
    try std.testing.expect(parse.stats.total_bits_global > 0);
}

test "learn handles a single tiny block without crashing" {
    const alloc = std.testing.allocator;
    const raw = "ab";
    var parse = try learn(alloc, raw, 4096, .{});
    defer parse.deinit(alloc);
    try std.testing.expect(try verifyExact(alloc, raw, &parse.corpus));
}

test "scope pass keeps a burst-in-one-block word without deleting it" {
    const alloc = std.testing.allocator;
    // "xenon" repeated many times inside ONE block, never elsewhere.
    const burst = "xenon xenon xenon xenon xenon xenon xenon xenon. " ** 3;
    const filler = "abcdefghijklmnopqrstuvwxyz " ** 20;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, filler);
    try buf.appendSlice(alloc, burst);
    try buf.appendSlice(alloc, filler);
    var parse = try learn(alloc, buf.items, buf.items.len, .{ .max_iters = 8 });
    defer parse.deinit(alloc);
    try std.testing.expect(try verifyExact(alloc, buf.items, &parse.corpus));
}
