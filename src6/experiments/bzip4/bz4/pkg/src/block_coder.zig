//! The class-conditional block coder, behind a narrow interface (so the
//! coding mechanism -- currently an exact-arithmetic range coder -- can be
//! swapped for e.g. table-driven ANS later without touching `frame.zig`):
//!
//!   `encodeBlock(tokens) -> bytes`
//!   `decodeBlock(bytes, out) -> void`
//!
//! Codes `P(x_i | x_{i-1}) = T[class(x_{i-1})][class(x_i)] * g[x_i]/G[class(x_i)]`
//! with one row-lookup into the static `C x (C+1)` transition table to
//! pick the target class, then a within-class pick blending two disjoint
//! regions of one coding interval: `[0, G[c])`, split by each class member's
//! static (whole-file) weight as before, and an ADAPTIVE region
//! `[G[c], G[c] + B * N_blk[c])` split among only the symbols of class `c`
//! already seen earlier in this block, weighted by their in-block counts
//! (`N_blk[c]` = the sum of those counts; `B` a small fixed constant). A
//! symbol seen `n` times so far this block owns a static slot of size
//! `g[s]` AND, once `n>0`, an adaptive slot of size `B*n` -- two different
//! codewords for the same symbol, and the encoder always picks whichever
//! is larger (bigger slice of the interval = fewer bits); the decoder
//! just reads off whichever region the bits actually landed in, so there
//! is nothing for it to choose. `B=0` collapses the adaptive region to
//! size 0 for every class (so the static slot always wins) and `C=1`
//! still works unchanged (a single class's members get the same
//! within-block boost) -- both degenerate cases fall out of this same
//! code, not a branch. The per-class seen-list is reset between blocks by
//! bumping an epoch counter, not by clearing the (possibly large)
//! per-class arrays -- see `AdaptiveClass`.
//!
//! `decodeBlock` is allocation-free: symbol ids, output bounds and (via
//! `frame.zig`'s caller) the block CRC are all validated, and a corrupted
//! stream can only error, never panic, hang, or read/write out of bounds
//! -- every row-scan and interval lookup is bounded by construction
//! (`decodeFreq` never returns a value outside the interval's own real
//! total) and every class reached by the transition table is checked to
//! actually own a symbol bucket before use.
//!
//! Byte expansion: entries are memcpy'd out of a compact, descending-`g`-
//! ordered expansion arena built once at `Coder.build` time (a real
//! allocation, done up front, along with the per-class adaptive state --
//! see `frame.zig`'s "startup"); a literal byte (id < 256) is emitted
//! directly, no arena lookup needed. The arena's construction (materialise
//! every root-bearing entry via `model_codec.Expander`'s cycle-safe
//! memoised DFS, since a rank-renumbered lexicon is not topologically
//! ordered by id) lays hot expansions out contiguously for decode-time
//! cache locality.

const std = @import("std");
const rc = @import("range_coder.zig");
const coding = @import("coding.zig");
const lexicon = @import("lexicon.zig");
const model_codec = @import("model_codec.zig");
const ids = @import("ids.zig");
const Lexicon = lexicon.Lexicon;
const TokenId = ids.TokenId;

pub const BlockError = error{
    CorruptPayload,
    BlockOverrun,
    BlockUnderrun,
    SymbolOutOfRange,
};

// ------------------------------------------------------------------ arena

const Arena = struct {
    off: []u64, // rank-indexed (entry id - 256), valid only where len>0
    len: []u32,
    bytes: []u8,

    fn deinit(self: *Arena, alloc: std.mem.Allocator) void {
        alloc.free(self.off);
        alloc.free(self.len);
        alloc.free(self.bytes);
    }
};

fn buildArena(alloc: std.mem.Allocator, lex: *const Lexicon, g_by_id: []const u64) !Arena {
    const n = lex.numEntries();
    var exp = try model_codec.Expander.init(alloc, lex);
    defer exp.deinit(alloc);

    const order = try alloc.alloc(u32, n);
    defer alloc.free(order);
    var m: usize = 0;
    for (0..n) |r| {
        if (g_by_id[256 + r] > 0) {
            order[m] = @intCast(r);
            m += 1;
        }
    }
    const root_ranks = order[0..m];
    const GCtx = struct {
        g: []const u64,
        fn lessThan(self: @This(), a: u32, b: u32) bool {
            const ga = self.g[256 + a];
            const gb = self.g[256 + b];
            if (ga != gb) return ga > gb;
            return a < b;
        }
    };
    std.mem.sort(u32, root_ranks, GCtx{ .g = g_by_id }, GCtx.lessThan);

    const off = try alloc.alloc(u64, n);
    @memset(off, 0);
    const len = try alloc.alloc(u32, n);
    @memset(len, 0);

    var total: u64 = 0;
    for (root_ranks) |r| total += (try exp.expand(r)).len;
    const arena_bytes = try alloc.alloc(u8, total);

    var w: u64 = 0;
    for (root_ranks) |r| {
        const b = try exp.expand(r);
        @memcpy(arena_bytes[w..][0..b.len], b);
        off[r] = w;
        len[r] = @intCast(b.len);
        w += b.len;
    }

    return .{ .off = off, .len = len, .bytes = arena_bytes };
}

// -------------------------------------------------------------- adaptive

/// One fixed constant for every file and every class: how many "adaptive
/// weight units" one in-block occurrence of a symbol is worth, relative to
/// its static (whole-file) weight. Chosen by a block-size sweep on the
/// eval8 corpora (see the notebook); `0` exactly reproduces the pre-
/// adaptive coder (see this file's own doc comment).
pub const IN_BLOCK_BOOST: u32 = 48;

/// Per-class in-block seen-list: which symbols of this class have
/// occurred so far in the current block, and how many times, in
/// first-seen order (the order the adaptive region's sub-intervals are
/// enumerated in, so encoder and decoder agree on it for free). Reset
/// between blocks by bumping `epoch`, which is O(1); the (possibly
/// large, one-per-class-member) `count`/`epoch_of` arrays are allocated
/// once at `Coder.build` time and never cleared.
const AdaptiveClass = struct {
    count: []u32, // local-index sized (this class's own bucket)
    epoch_of: []u32,
    touched: []u32, // local indices touched this epoch, first-seen order
    touched_count: usize = 0,
    epoch: u32 = 0,
    total: u64 = 0, // sum of `count` over touched entries this epoch (== N_blk[c])

    fn init(alloc: std.mem.Allocator, n: usize) !AdaptiveClass {
        const count = try alloc.alloc(u32, n);
        @memset(count, 0);
        const epoch_of = try alloc.alloc(u32, n);
        @memset(epoch_of, 0);
        const touched = try alloc.alloc(u32, n);
        return .{ .count = count, .epoch_of = epoch_of, .touched = touched };
    }
    fn deinit(self: *AdaptiveClass, alloc: std.mem.Allocator) void {
        alloc.free(self.count);
        alloc.free(self.epoch_of);
        alloc.free(self.touched);
    }
    fn resetBlock(self: *AdaptiveClass) void {
        self.epoch +%= 1;
        self.touched_count = 0;
        self.total = 0;
    }
    fn countOf(self: *const AdaptiveClass, local: u32) u32 {
        return if (self.epoch_of[local] == self.epoch) self.count[local] else 0;
    }
    /// `B * (cumulative in-block count over touched entries strictly
    /// before `local`)`, i.e. `local`'s adaptive sub-interval's offset
    /// from the start of the adaptive region.
    fn prefixScaled(self: *const AdaptiveClass, local: u32) u64 {
        var cum: u64 = 0;
        for (self.touched[0..self.touched_count]) |t| {
            if (t == local) break;
            cum += self.count[t];
        }
        return cum * IN_BLOCK_BOOST;
    }
    /// Find which touched entry's scaled slot contains offset `v`
    /// (0 <= v < IN_BLOCK_BOOST*self.total, guaranteed by the caller
    /// having sized the coded interval that way); returns (local index,
    /// that slot's own scaled cum/freq).
    fn find(self: *const AdaptiveClass, v: u64) !struct { local: u32, cum: u64, freq: u32 } {
        var cum: u64 = 0;
        for (self.touched[0..self.touched_count]) |t| {
            const freq: u64 = @as(u64, self.count[t]) * IN_BLOCK_BOOST;
            if (v < cum + freq) return .{ .local = t, .cum = cum, .freq = @intCast(freq) };
            cum += freq;
        }
        return BlockError.CorruptPayload;
    }
    fn bump(self: *AdaptiveClass, local: u32) void {
        if (self.epoch_of[local] != self.epoch) {
            self.epoch_of[local] = self.epoch;
            self.count[local] = 0;
            self.touched[self.touched_count] = local;
            self.touched_count += 1;
        }
        self.count[local] += 1;
        self.total += 1;
    }
};

// ------------------------------------------------------------------ Coder

fn rowTotal(T: []const u32, C: u32, row: u32) u32 {
    var s: u32 = 0;
    for (0..C) |c| s += T[row * C + c];
    return s;
}
fn rowEncode(T: []const u32, C: u32, row: u32, enc: *rc.Encoder, target: u32) !void {
    var cum: u32 = 0;
    for (0..target) |c| cum += T[row * C + c];
    try enc.encodeFreq(cum, T[row * C + target], rowTotal(T, C, row));
}
fn rowDecode(T: []const u32, C: u32, row: u32, dec: *rc.Decoder, tot: u32) u32 {
    const v = dec.decodeFreq(tot);
    var cum: u32 = 0;
    var i: usize = 0;
    while (true) : (i += 1) {
        const cc = T[row * C + i];
        if (v < cum + cc) break;
        cum += cc;
    }
    dec.consume(cum, T[row * C + i]);
    return @intCast(i);
}

/// Everything needed to code/decode blocks for one converged model: owns
/// its own copies of the transition table and resolved classes (so a
/// `Frame` can hold one `Coder` with a single, simple lifetime), the
/// expansion arena, and one `AdaptiveClass` per class for the in-block
/// boost.
pub const Coder = struct {
    C: u32,
    T: []u32, // owned copy, (C+1)*C
    resolved_b: []u32, // owned copy, size k
    resolved_a: []u32, // owned copy, size k
    buckets: coding.BucketSet,
    arena: Arena,
    adaptive: []AdaptiveClass, // owned, size C

    pub fn build(alloc: std.mem.Allocator, C: u32, T: []const u32, resolved_b: []const u32, resolved_a: []const u32, g_by_id: []const u64, lex: *const Lexicon) !Coder {
        const k = 256 + lex.numEntries();
        std.debug.assert(resolved_b.len == k and resolved_a.len == k and g_by_id.len == k);
        var buckets = try coding.buildBuckets(alloc, C, k, resolved_b, g_by_id);
        errdefer buckets.deinit();
        const arena = try buildArena(alloc, lex, g_by_id);
        const adaptive = try alloc.alloc(AdaptiveClass, C);
        for (adaptive, 0..) |*ac, c| ac.* = try AdaptiveClass.init(alloc, buckets.sym_of[c].len);
        return .{
            .C = C,
            .T = try alloc.dupe(u32, T),
            .resolved_b = try alloc.dupe(u32, resolved_b),
            .resolved_a = try alloc.dupe(u32, resolved_a),
            .buckets = buckets,
            .arena = arena,
            .adaptive = adaptive,
        };
    }

    pub fn deinit(self: *Coder, alloc: std.mem.Allocator) void {
        alloc.free(self.T);
        alloc.free(self.resolved_b);
        alloc.free(self.resolved_a);
        self.buckets.deinit();
        self.arena.deinit(alloc);
        for (self.adaptive) |*ac| ac.deinit(alloc);
        alloc.free(self.adaptive);
    }

    fn resetBlockState(self: *Coder) void {
        for (self.adaptive) |*ac| ac.resetBlock();
    }

    /// Encode one independently-decodable block's token stream.
    pub fn encodeBlock(self: *Coder, alloc: std.mem.Allocator, tokens: []const TokenId) ![]u8 {
        self.resetBlockState();
        var enc = rc.Encoder.init(alloc);
        var ctx: u32 = self.C; // START row
        for (tokens) |t| {
            const s = t.raw();
            const target = self.resolved_b[s];
            try rowEncode(self.T, self.C, ctx, &enc, target);

            const fw = &self.buckets.fenwicks[target].?;
            const local = self.buckets.local_idx[s];
            const static_freq = fw.counts[local];
            const static_total = fw.total();
            const ac = &self.adaptive[target];
            const adaptive_freq = IN_BLOCK_BOOST * ac.countOf(local);
            const total = coding.u64c(static_total + @as(u64, IN_BLOCK_BOOST) * ac.total);

            if (adaptive_freq > static_freq) {
                const cum = static_total + ac.prefixScaled(local);
                try enc.encodeFreq(coding.u64c(cum), adaptive_freq, total);
            } else {
                try enc.encodeFreq(coding.u64c(fw.prefix(local)), static_freq, total);
            }
            ac.bump(local);

            ctx = self.resolved_a[s];
        }
        const finished = try enc.finish();
        const owned = try alloc.dupe(u8, finished);
        enc.deinit();
        return owned;
    }

    /// Decode a block into `out` (exactly the block's raw length).
    /// Allocation-free; never trusts `bytes`.
    pub fn decodeBlock(self: *Coder, bytes: []const u8, out: []u8) !void {
        self.resetBlockState();
        var dec = rc.Decoder.init(bytes);
        var ctx: u32 = self.C;
        var pos: usize = 0;
        while (pos < out.len) {
            const row_tot = rowTotal(self.T, self.C, ctx);
            if (row_tot == 0) return BlockError.CorruptPayload;
            const cls = rowDecode(self.T, self.C, ctx, &dec, row_tot);
            if (cls >= self.C or self.buckets.fenwicks[cls] == null) return BlockError.CorruptPayload;

            const fw = &self.buckets.fenwicks[cls].?;
            const static_total = fw.total();
            const ac = &self.adaptive[cls];
            const total = coding.u64c(static_total + @as(u64, IN_BLOCK_BOOST) * ac.total);
            if (total == 0) return BlockError.CorruptPayload;
            const v = dec.decodeFreq(total);

            var s: u32 = undefined;
            var local: u32 = undefined;
            if (v < coding.u64c(static_total)) {
                local = @intCast(fw.find(v));
                const freq = fw.counts[local];
                dec.consume(coding.u64c(fw.prefix(local)), freq);
                s = self.buckets.sym_of[cls][local];
            } else {
                const found = try ac.find(@as(u64, v) - static_total);
                dec.consume(coding.u64c(static_total + found.cum), found.freq);
                local = found.local;
                s = self.buckets.sym_of[cls][local];
            }
            ac.bump(local);

            if (s < 256) {
                out[pos] = @intCast(s);
                pos += 1;
            } else {
                const r = s - 256;
                if (r >= self.arena.len.len) return BlockError.SymbolOutOfRange;
                const l = self.arena.len[r];
                if (l == 0) return BlockError.SymbolOutOfRange;
                if (pos + l > out.len) return BlockError.BlockOverrun;
                @memcpy(out[pos..][0..l], self.arena.bytes[self.arena.off[r]..][0..l]);
                pos += l;
            }
            if (s >= self.resolved_a.len) return BlockError.SymbolOutOfRange;
            ctx = self.resolved_a[s];
        }
        if (pos != out.len) return BlockError.BlockUnderrun;
    }
};

test "encode/decode round-trip at C=1 (order-0) and C=8" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const topology = @import("topology.zig");
    const classes = @import("classes.zig");
    const learn = @import("learn.zig");

    const raw = "the cat sat on the mat. the dog sat on the log. the cat ran and the dog ran. " ** 15;
    var corpus = try lexicon.seedBytes(a, raw, 4096);
    var log: std.ArrayList(learn.IterLog) = .empty;
    try learn.iterate(a, &corpus, raw, .{ .max_iters = 6 }, &log);

    const g = try lexicon.recountRootsOnly(a, &corpus);
    var em = try model_codec.encode(a, &corpus.lex, g, model_codec.default_variant, null);

    // Remap the corpus tokens and root counts through the model's id_map so
    // classes/block-coder operate in the same (final) id space `em.renumbered`
    // and the eventual decoder use.
    const k = 256 + em.renumbered.numEntries();
    const remapped_g = try a.alloc(u64, k);
    for (g, 0..) |v, old| remapped_g[em.id_map[old].raw()] = v;
    const remapped_seq = try a.alloc(u32, corpus.seq.len);
    for (corpus.seq, 0..) |t, i| remapped_seq[i] = em.id_map[t].raw();
    const remapped_corpus = lexicon.Corpus{ .lex = em.renumbered, .seq = remapped_seq, .block_end = corpus.block_end, .block_bytes = corpus.block_bytes };

    inline for (.{ 1, 8 }) |C| {
        const order = try topology.topoOrder(a, &remapped_corpus.lex);
        const info = try topology.buildSymInfo(a, &remapped_corpus.lex, order);
        const built = try classes.learnAndBuild(a, &remapped_corpus, order, info, remapped_g, .{ .C = C, .g_min = 2 });

        var coder = try Coder.build(a, built.model.C, built.model.T, built.model.resolved_b, built.model.resolved_a, remapped_g, &remapped_corpus.lex);

        var start: usize = 0;
        for (remapped_corpus.block_end) |end| {
            const tokens: []const TokenId = @ptrCast(remapped_corpus.seq[start..end]);
            const encoded = try coder.encodeBlock(a, tokens);
            const raw_start = start; // block_bytes-based alignment matches seedBytes' own blocking
            _ = raw_start;
            const raw_len = blk: {
                var total_len: usize = 0;
                for (remapped_corpus.seq[start..end]) |tok| {
                    if (tok < 256) {
                        total_len += 1;
                    } else {
                        total_len += remapped_corpus.lex.explen.items[tok - 256];
                    }
                }
                break :blk total_len;
            };
            const out = try a.alloc(u8, raw_len);
            try coder.decodeBlock(encoded, out);

            var want: std.ArrayList(u8) = .empty;
            for (remapped_corpus.seq[start..end]) |tok| {
                const bytes = try lexicon.expandEntryBytes(a, &remapped_corpus.lex, tok);
                try want.appendSlice(a, bytes);
            }
            try std.testing.expectEqualSlices(u8, want.items, out);
            start = end;
        }
    }
}
