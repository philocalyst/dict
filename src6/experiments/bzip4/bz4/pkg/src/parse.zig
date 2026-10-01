//! RE-PARSE: rebuild a flat-array byte trie from the current lexicon, then
//! re-tokenise every corpus block *and* every entry's own byte expansion
//! with a shortest-code-length DP. Self-validating: the caller only keeps
//! the re-parse if the honestly-recomputed DL actually improved (a DP that
//! is optimal for stale per-symbol costs can regress once costs are
//! recounted against the new parse).
//!
//! Ported from `m_lexicon.zig` (Lane M) per PLAN.md's copy-and-reshape
//! rule. No hashmap anywhere in the trie (a small sorted per-node edge
//! list, binary-searched) -- Lane A's own notebook found a hashmap trie
//! took seconds per parse; this one doesn't.

const std = @import("std");
const lexicon = @import("lexicon.zig");
const Corpus = lexicon.Corpus;
const Lexicon = lexicon.Lexicon;
const LexBuilder = lexicon.LexBuilder;
const bitsOfCount = lexicon.bitsOfCount;
const dlEstimate = lexicon.dlEstimate;
const Opts = @import("propose.zig").Opts;

const NO_SYM: u32 = std.math.maxInt(u32);

const TrieEdge = struct { byte: u8, child: u32 };
const TrieNode = struct {
    edges: std.ArrayList(TrieEdge) = .empty,
    accept: u32 = NO_SYM,
};
pub const Trie = struct {
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
    /// insertion order; `prev` is the previously inserted item's bytes (or
    /// &.{} for the first) so the shared prefix is located by walking
    /// existing edges instead of hashing.
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

/// Materialise byte expansions for bytes (trivial) and every entry whose
/// expansion is <= max_len (a bounded approximation: longer entries are
/// simply left unreparsed/unmatchable, same policy the lab's Lane A/M
/// shipped with).
pub fn materializeAll(alloc: std.mem.Allocator, lex: *const Lexicon, max_len: u32) ![]?[]u8 {
    const n = lex.numEntries();
    const k = 256 + n;
    const bytes = try alloc.alloc(?[]u8, k);
    for (0..256) |b| {
        const buf = try alloc.alloc(u8, 1);
        buf[0] = @intCast(b);
        bytes[b] = buf;
    }
    // Components are only guaranteed to have a strictly smaller *explen*
    // than their parent (not a smaller id -- re-parsing may rewrite an
    // entry to reference a higher-numbered but shorter entry), so
    // materialise in explen-ascending order, the actual dependency order.
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

pub fn buildTrie(alloc: std.mem.Allocator, matbytes: []const ?[]u8) !Trie {
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
/// its expansion length is strictly less than it -- keeps the entry DAG
/// acyclic when re-parsing an entry's own spelling.
pub fn dpParse(
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
/// every corpus block (against `raw`) and every entry's own spelling via
/// the DP above. Returns true if the re-parse changed anything and the
/// honestly-recomputed DL improved (and was therefore kept).
pub fn reparseRound(alloc: std.mem.Allocator, corpus: *Corpus, raw: []const u8, opts: Opts) !bool {
    const rc0 = try lexicon.recount(alloc, corpus);
    const dl_before = dlEstimate(rc0.n, rc0.m, corpus.lex.numEntries(), opts.calib);
    const k = 256 + corpus.lex.numEntries();
    const bits = try alloc.alloc(f64, k);
    for (0..k) |s| bits[s] = bitsOfCount(rc0.n[s], @floatFromInt(rc0.m));

    const matbytes = try materializeAll(alloc, &corpus.lex, opts.max_material_len);
    const trie = try buildTrie(alloc, matbytes);

    var new_seq: std.ArrayList(u32) = .empty;
    var new_block_end: std.ArrayList(usize) = .empty;
    var raw_start: usize = 0;
    for (corpus.block_end) |_| {
        const raw_end = @min(raw.len, raw_start + corpus.block_bytes);
        try dpParse(alloc, &trie, raw[raw_start..raw_end], bits, corpus.lex.explen.items, null, &new_seq);
        try new_block_end.append(alloc, new_seq.items.len);
        raw_start = raw_end;
    }

    var builder = try LexBuilder.init(alloc);
    for (0..corpus.lex.numEntries()) |i| {
        const sym = 256 + i;
        const el = corpus.lex.explen.items[i];
        if (matbytes[sym]) |mb| {
            var toks: std.ArrayList(u32) = .empty;
            try dpParse(alloc, &trie, mb, bits, corpus.lex.explen.items, el, &toks);
            _ = try builder.addEntry(alloc, toks.items, el);
        } else {
            _ = try builder.addEntry(alloc, corpus.lex.comps(i), el);
        }
    }
    var new_lex = builder.finish();

    var candidate = Corpus{ .lex = new_lex, .seq = try new_seq.toOwnedSlice(alloc), .block_end = try new_block_end.toOwnedSlice(alloc), .block_bytes = corpus.block_bytes };
    const rc1 = try lexicon.recount(alloc, &candidate);
    const dl_after = dlEstimate(rc1.n, rc1.m, candidate.lex.numEntries(), opts.calib);

    if (dl_after < dl_before) {
        corpus.* = candidate;
        return true;
    } else {
        new_lex.deinit(alloc);
        return false;
    }
}

test "reparseRound keeps the corpus byte-exact" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const raw = "the cat sat on the mat, the cat ran";
    var corpus = try lexicon.seedBytes(a, raw, 4096);
    const propose = @import("propose.zig");
    _ = try propose.proposePairs(a, &corpus, .{});
    _ = try reparseRound(a, &corpus, raw, .{});
    try std.testing.expect(try lexicon.verifyExact(a, raw, &corpus));
}
