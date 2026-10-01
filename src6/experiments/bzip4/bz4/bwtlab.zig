//! bwtlab: Lane W driver. Builds a partial grammar of k rules (barriers at
//! block boundaries, via gprobe.zig's `build`), BWTs each block's root
//! stream (symbwt.zig), codes it with an adaptive CM (symcm.zig), decodes,
//! inverse-BWTs, expands roots back to bytes through the grammar, and
//! verifies byte-exact equality with the raw input. Real encoder, real
//! decoder, one run.
//!
//! usage: bwtlab FILE BLOCK_BYTES MAX_RULES [MIN_FREQ] [ALPHA] [SORT] [CM] [RUNSC] [MIX] [SSE]
//!   BLOCK_BYTES: 65536 | 1048576 | 0 (0 = whole file, one block)
//!   MAX_RULES:   0 | 1024 | 8192 | 65536 | 1000000 (k, "full"); pass a huge
//!                cap (e.g. 100000000) with a real MIN_FREQ to get the
//!                round-2 "grammar by frequency, unlimited rules" mode
//!   MIN_FREQ, ALPHA default to 2, 50 (gprobe's own "full" preset)
//!   SORT: lex | orig   (round-2 default: lex — BWT sorts by each symbol's
//!         lexicographic byte-expansion rank, not gprobe's creation-order id)
//!   CM:   tree | generic (round-2 default: tree — the weight-balanced
//!         alphabetic coding tree with hashed order-1/2 + mix + SSE; falls
//!         back to `GenericCM` for the round-1 ablation baseline)
//!   RUNSC, MIX, SSE: 1|0, logistic|fixed, 1|0 — TreeCM sub-toggles, ignored
//!         when CM=generic. Defaults: 1, logistic, 1.
//!
//! Prints one TSV report line to stdout (see `header` below) with real
//! payload bytes, an `est` grammar cost at 12 bits/rule (round 2; Lane I
//! measured ~9.6 bits/rule in-band — see LANE_W.md), the resulting
//! `total_est`, the static order-0 root cost `est` for comparison, real
//! binary-decision counts, and indicative encode/decode ms. Pure Zig 0.16,
//! std only.

const std = @import("std");
const gprobe = @import("gprobe.zig");
const symbwt = @import("symbwt.zig");
const symcm = @import("symcm.zig");

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn expandOne(alloc: std.mem.Allocator, rules: []const gprobe.Rule, sym: u32, out: *std.ArrayList(u8)) !void {
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(alloc);
    try stack.append(alloc, sym);
    while (stack.pop()) |s| {
        if (s < 256) {
            try out.append(alloc, @intCast(s));
        } else {
            const r = rules[s - 256];
            try stack.append(alloc, r.b);
            try stack.append(alloc, r.a);
        }
    }
}

// ---------------------------------------------------------- rank keys --
//
// Round 2 (lead's diagnosis #1): gprobe assigns rule ids in creation
// order, which has nothing to do with lexicographic content — "the",
// "the ", "there" land in unrelated places in a creation-order BWT sort,
// so their predecessor statistics can't be shared the way a byte BWT's
// can. Fix: sort symbols for the BWT by the lexicographic order of their
// *expansions* (fwd_rank), and separately sort them by the lexicographic
// order of their *reversed* expansions for the coding tree's leaf order
// (rev_rank, so symbols ending alike become tree neighbours). Both are
// pure functions of the grammar the decoder already has — zero bytes.
//
// Expansions aren't materialised in full (a pathological rule chain could
// make that O(n log n) or worse); each symbol's key is capped to the
// first/last `key_cap` bytes, built bottom-up in O(key_cap) per rule since
// children always have smaller ids. `key_cap` bytes is far more than the
// typical grammar-rule length (a few bytes to a few dozen), so the
// "shorter genuinely-complete prefix sorts first" tie-break — the same
// rule real lexicographic string order uses — almost never falls back to
// the length/id tie-break below it.

const key_cap: u32 = 64;

const SymKey = struct {
    prefix: [key_cap]u8 = undefined,
    prefix_len: u32 = 0,
    suffix: [key_cap]u8 = undefined,
    suffix_len: u32 = 0,
    full_len: u32 = 0,
};

fn buildSymKeys(alloc: std.mem.Allocator, rules: []const gprobe.Rule, k_alphabet: usize) ![]SymKey {
    const keys = try alloc.alloc(SymKey, k_alphabet);
    for (0..@min(256, k_alphabet)) |b| {
        var k: SymKey = .{};
        k.prefix[0] = @intCast(b);
        k.prefix_len = 1;
        k.suffix[0] = @intCast(b);
        k.suffix_len = 1;
        k.full_len = 1;
        keys[b] = k;
    }
    for (rules, 0..) |r, i| {
        const s = 256 + i;
        const ka = keys[r.a];
        const kb = keys[r.b];
        var out: SymKey = .{};
        out.full_len = ka.full_len + kb.full_len;

        var n: u32 = @min(ka.prefix_len, key_cap);
        @memcpy(out.prefix[0..n], ka.prefix[0..n]);
        if (n < key_cap and ka.full_len <= key_cap) {
            const remaining = key_cap - n;
            const take_b: u32 = @min(kb.prefix_len, remaining);
            @memcpy(out.prefix[n .. n + take_b], kb.prefix[0..take_b]);
            n += take_b;
        }
        out.prefix_len = n;

        if (kb.full_len >= key_cap) {
            out.suffix = kb.suffix;
            out.suffix_len = kb.suffix_len;
        } else {
            const need_from_a: u32 = key_cap - kb.full_len;
            const take_a: u32 = @min(ka.suffix_len, need_from_a);
            const a_start = ka.suffix_len - take_a;
            @memcpy(out.suffix[0..take_a], ka.suffix[a_start .. a_start + take_a]);
            @memcpy(out.suffix[take_a .. take_a + kb.suffix_len], kb.suffix[0..kb.suffix_len]);
            out.suffix_len = take_a + kb.suffix_len;
        }
        keys[s] = out;
    }
    return keys;
}

const KeyCtx = struct {
    keys: []const SymKey,

    fn lessPrefix(self: KeyCtx, a: u32, b: u32) bool {
        const ka = self.keys[a];
        const kb = self.keys[b];
        const n = @min(ka.prefix_len, kb.prefix_len);
        switch (std.mem.order(u8, ka.prefix[0..n], kb.prefix[0..n])) {
            .lt => return true,
            .gt => return false,
            .eq => {
                if (ka.prefix_len != kb.prefix_len) return ka.prefix_len < kb.prefix_len;
                if (ka.full_len != kb.full_len) return ka.full_len < kb.full_len;
                return a < b;
            },
        }
    }

    fn lessSuffix(self: KeyCtx, a: u32, b: u32) bool {
        const ka = self.keys[a];
        const kb = self.keys[b];
        const na = ka.suffix_len;
        const nb = kb.suffix_len;
        const n = @min(na, nb);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const ca = ka.suffix[na - 1 - i];
            const cb = kb.suffix[nb - 1 - i];
            if (ca != cb) return ca < cb;
        }
        if (na != nb) return na < nb;
        if (ka.full_len != kb.full_len) return ka.full_len < kb.full_len;
        return a < b;
    }
};

// --------------------------------------------------------------- config --

pub const SortMode = enum { creation_order, lex };
pub const CmMode = enum { generic, tree };

pub const LaneWConfig = struct {
    sort_mode: SortMode = .lex,
    cm_mode: CmMode = .tree,
    tree_cfg: symcm.TreeCMConfig = .{},
};

const Report = struct {
    file: []const u8,
    block_bytes: usize,
    max_rules: usize,
    min_freq: u32,
    sort_mode: SortMode,
    cm_mode: CmMode,
    rule_count: usize,
    block_count: usize,
    root_count: usize,
    payload_bytes: usize,
    grammar_est_bytes: f64,
    total_est_bytes: f64,
    static_h0_bytes: f64,
    total_est_static0_bytes: f64,
    decisions: u64,
    encode_ms: f64,
    decode_ms: f64,
    grammar_ms: f64,
    raw_len: usize,
};

fn log2f(x: f64) f64 {
    return @log2(x);
}

/// Runs the whole Lane W pipeline once. Returns a filled-in Report; returns
/// an error on any roundtrip mismatch, since a silent wrong answer is worse
/// than a crash in a measurement lab.
pub fn run(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    input: []const u8,
    block_bytes_arg: usize,
    max_rules: usize,
    min_freq: u32,
    alpha_percent: u32,
    cfg: LaneWConfig,
) !Report {
    const n = input.len;
    const effective_block_bytes = if (block_bytes_arg == 0) @max(@as(usize, 1), n) else block_bytes_arg;

    const t_g0 = nowNs(io);
    var g = try gprobe.build(alloc, input, effective_block_bytes, max_rules, min_freq, alpha_percent);
    const t_g1 = nowNs(io);
    // gprobe.build's `seq` field is a truncated view (seq[0..live]) of an
    // n-element allocation; free the original extent, not the sub-slice
    // (a size-mismatched free trips the debug allocator).
    defer {
        g.rules.deinit(alloc);
        alloc.free(g.seq.ptr[0..n]);
        alloc.free(g.block_end);
    }

    const k_alphabet = 256 + g.rules.items.len;
    const block_count = (n + effective_block_bytes - 1) / effective_block_bytes;

    // Global order-0 stats over the full root stream (same basis as
    // gprobe's own "static_H0" print), for the static-vs-BWT+CM comparison,
    // and (per the plan's own MODEL-segment design) the tree's weights.
    const freq = try alloc.alloc(u64, k_alphabet);
    defer alloc.free(freq);
    @memset(freq, 0);
    for (g.seq) |s| freq[s] += 1;
    const m: f64 = @floatFromInt(g.seq.len);
    var h0_bits: f64 = 0;
    for (freq) |f| if (f != 0) {
        h0_bits -= @as(f64, @floatFromInt(f)) * log2f(@as(f64, @floatFromInt(f)) / m);
    };

    // fwd_rank/order_fwd: identity unless sort_mode==lex (and there's an
    // actual grammar — a byte alphabet is already numerically sorted).
    const order_fwd = try alloc.alloc(u32, k_alphabet);
    defer alloc.free(order_fwd);
    const fwd_rank = try alloc.alloc(u32, k_alphabet);
    defer alloc.free(fwd_rank);
    for (order_fwd, 0..) |*o, i| o.* = @intCast(i);
    for (fwd_rank, 0..) |*r, i| r.* = @intCast(i);

    var rev_order: []u32 = &.{};
    var rev_rank: []u32 = &.{};
    var tree: ?symcm.AlphaTree = null;
    defer if (rev_order.len > 0) alloc.free(rev_order);
    defer if (rev_rank.len > 0) alloc.free(rev_rank);
    defer if (tree) |*t| t.deinit();

    const need_lex = cfg.sort_mode == .lex and k_alphabet > 256;
    const need_tree = cfg.cm_mode == .tree and k_alphabet > 256;
    if (need_lex or need_tree) {
        const keys = try buildSymKeys(alloc, g.rules.items, k_alphabet);
        defer alloc.free(keys);
        if (need_lex) {
            std.mem.sort(u32, order_fwd, KeyCtx{ .keys = keys }, KeyCtx.lessPrefix);
            for (order_fwd, 0..) |sym, r| fwd_rank[sym] = @intCast(r);
        }
        if (need_tree) {
            rev_order = try alloc.alloc(u32, k_alphabet);
            for (rev_order, 0..) |*o, i| o.* = @intCast(i);
            std.mem.sort(u32, rev_order, KeyCtx{ .keys = keys }, KeyCtx.lessSuffix);
            rev_rank = try alloc.alloc(u32, k_alphabet);
            for (rev_order, 0..) |sym, r| rev_rank[sym] = @intCast(r);
            const weight = try alloc.alloc(u32, k_alphabet);
            defer alloc.free(weight);
            for (weight, 0..) |*w, i| {
                const capped: u64 = @min(freq[i], @as(u64, std.math.maxInt(u32) - 1));
                w.* = @as(u32, @intCast(capped)) + 1; // plan's g[s]+1
            }
            tree = try symcm.buildAlphaTree(alloc, rev_order, weight);
        }
    }

    var total_payload: usize = 0;
    var total_encode_ns: u64 = 0;
    var total_decode_ns: u64 = 0;
    var total_roots: usize = 0;
    var total_decisions: u64 = 0;

    var sym_start: usize = 0;
    var byte_start: usize = 0;
    for (g.block_end) |sym_end| {
        const byte_end = @min(n, byte_start + effective_block_bytes);
        const root_slice = g.seq[sym_start..sym_end];
        total_roots += root_slice.len;

        const remapped = try alloc.alloc(u32, root_slice.len);
        defer alloc.free(remapped);
        for (root_slice, 0..) |sym, i| remapped[i] = fwd_rank[sym];

        const t_e0 = nowNs(io);
        const bw = try symbwt.bwt(alloc, remapped, k_alphabet);
        defer alloc.free(bw.l);
        // Convert the BWT's last column back to the ORIGINAL symbol-id
        // domain so the CM (and its rev_rank-keyed tree, if any) always
        // codes the same domain regardless of which sort order was used.
        const l_orig = try alloc.alloc(u32, bw.l.len);
        defer alloc.free(l_orig);
        for (bw.l, 0..) |v, i| l_orig[i] = order_fwd[v];

        const use_tree = cfg.cm_mode == .tree and tree != null;
        var enc_bytes: []const u8 = undefined;
        var enc_decisions: u64 = undefined;
        if (use_tree) {
            const enc = try symcm.encodeSymbolsTree(alloc, l_orig, &tree.?, rev_order, rev_rank, cfg.tree_cfg);
            enc_bytes = enc.bytes;
            enc_decisions = enc.decisions;
        } else {
            const enc = try symcm.encodeSymbolsCounted(alloc, l_orig, k_alphabet);
            enc_bytes = enc.bytes;
            enc_decisions = enc.decisions;
        }
        defer alloc.free(enc_bytes);
        const t_e1 = nowNs(io);
        total_encode_ns += @intCast(t_e1 - t_e0);
        total_payload += enc_bytes.len;
        total_decisions += enc_decisions;

        const t_d0 = nowNs(io);
        var l_orig2: []u32 = undefined;
        var dec_decisions: u64 = undefined;
        if (use_tree) {
            const dec = try symcm.decodeSymbolsTree(alloc, enc_bytes, root_slice.len, &tree.?, rev_order, rev_rank, cfg.tree_cfg);
            l_orig2 = dec.syms;
            dec_decisions = dec.decisions;
        } else {
            const dec = try symcm.decodeSymbolsCounted(alloc, enc_bytes, root_slice.len, k_alphabet);
            l_orig2 = dec.syms;
            dec_decisions = dec.decisions;
        }
        defer alloc.free(l_orig2);
        if (!std.mem.eql(u32, l_orig, l_orig2)) return error.CmRoundtripMismatch;
        if (enc_decisions != dec_decisions) return error.DecisionCountMismatch;

        const l_fwd2 = try alloc.alloc(u32, l_orig2.len);
        defer alloc.free(l_fwd2);
        for (l_orig2, 0..) |sym, i| l_fwd2[i] = fwd_rank[sym];
        const seq2_fwd = try symbwt.ibwt(alloc, l_fwd2, bw.primary, k_alphabet);
        defer alloc.free(seq2_fwd);
        const seq2 = try alloc.alloc(u32, seq2_fwd.len);
        defer alloc.free(seq2);
        for (seq2_fwd, 0..) |v, i| seq2[i] = order_fwd[v];
        const t_d1 = nowNs(io);
        total_decode_ns += @intCast(t_d1 - t_d0);
        if (!std.mem.eql(u32, root_slice, seq2)) return error.BwtRoundtripMismatch;

        // Expand roots back to raw bytes and check byte-exact equality.
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try out.ensureTotalCapacity(alloc, byte_end - byte_start);
        for (seq2) |sym| try expandOne(alloc, g.rules.items, sym, &out);
        if (!std.mem.eql(u8, input[byte_start..byte_end], out.items)) return error.ExpansionMismatch;

        sym_start = sym_end;
        byte_start = byte_end;
    }
    std.debug.assert(total_roots == g.seq.len);

    // Round 2: grammar cost at 12 bits/rule (Lane I measured ~9.6 bits/rule
    // in-band for a real DEF-tree code; 12 is this lane's still-conservative
    // `est`, down from round 1's 14 — see LANE_W.md).
    const grammar_est_bytes: f64 = @as(f64, @floatFromInt(g.rules.items.len)) * 12.0 / 8.0;
    const per_block_overhead: f64 = 16.0 * @as(f64, @floatFromInt(block_count)) + 32.0;
    const total_est_bytes = @as(f64, @floatFromInt(total_payload)) + grammar_est_bytes + per_block_overhead;
    const static_h0_bytes = h0_bits / 8.0;
    const total_est_static0_bytes = static_h0_bytes + grammar_est_bytes + per_block_overhead;

    return .{
        .file = path,
        .block_bytes = block_bytes_arg,
        .max_rules = max_rules,
        .min_freq = min_freq,
        .sort_mode = cfg.sort_mode,
        .cm_mode = cfg.cm_mode,
        .rule_count = g.rules.items.len,
        .block_count = block_count,
        .root_count = g.seq.len,
        .payload_bytes = total_payload,
        .grammar_est_bytes = grammar_est_bytes,
        .total_est_bytes = total_est_bytes,
        .static_h0_bytes = static_h0_bytes,
        .total_est_static0_bytes = total_est_static0_bytes,
        .decisions = total_decisions,
        .encode_ms = @as(f64, @floatFromInt(total_encode_ns)) / 1e6,
        .decode_ms = @as(f64, @floatFromInt(total_decode_ns)) / 1e6,
        .grammar_ms = @as(f64, @floatFromInt(t_g1 - t_g0)) / 1e6,
        .raw_len = n,
    };
}

const header = "file\tblock_bytes\tmax_rules\tmin_freq\tsort\tcm\trules\tblocks\troots\tpayload_B\tgrammar_est_B\ttotal_est_B\tstatic_h0_B\ttotal_est_static0_B\tdecisions\tdecisions_per_byte\tencode_ms\tdecode_ms\tgrammar_ms\traw_len";

fn printReport(r: Report) void {
    const dpb: f64 = if (r.raw_len == 0) 0 else @as(f64, @floatFromInt(r.decisions)) / @as(f64, @floatFromInt(r.raw_len));
    std.debug.print("{s}\t{d}\t{d}\t{d}\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d:.1}\t{d:.1}\t{d:.1}\t{d:.1}\t{d}\t{d:.3}\t{d:.2}\t{d:.2}\t{d:.2}\t{d}\n", .{
        r.file,                       r.block_bytes,     r.max_rules,   r.min_freq,        @tagName(r.sort_mode),
        @tagName(r.cm_mode),          r.rule_count,      r.block_count, r.root_count,      r.payload_bytes,
        r.grammar_est_bytes,          r.total_est_bytes, r.static_h0_bytes, r.total_est_static0_bytes, r.decisions,
        dpb,                          r.encode_ms,       r.decode_ms,   r.grammar_ms,      r.raw_len,
    });
}

fn parseSortMode(s: []const u8) !SortMode {
    if (std.mem.eql(u8, s, "lex")) return .lex;
    if (std.mem.eql(u8, s, "orig")) return .creation_order;
    return error.Usage;
}
fn parseCmMode(s: []const u8) !CmMode {
    if (std.mem.eql(u8, s, "tree")) return .tree;
    if (std.mem.eql(u8, s, "generic")) return .generic;
    return error.Usage;
}
fn parseBool01(s: []const u8) !bool {
    if (std.mem.eql(u8, s, "1")) return true;
    if (std.mem.eql(u8, s, "0")) return false;
    return error.Usage;
}
fn parseMix(s: []const u8) !bool {
    if (std.mem.eql(u8, s, "logistic")) return true;
    if (std.mem.eql(u8, s, "fixed")) return false;
    return error.Usage;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const path = it.next() orelse return error.Usage;
    const block_bytes = try std.fmt.parseUnsigned(usize, it.next() orelse return error.Usage, 10);
    const max_rules = try std.fmt.parseUnsigned(usize, it.next() orelse return error.Usage, 10);
    const min_freq = try std.fmt.parseUnsigned(u32, it.next() orelse "2", 10);
    const alpha = try std.fmt.parseUnsigned(u32, it.next() orelse "50", 10);
    const cfg = LaneWConfig{
        .sort_mode = try parseSortMode(it.next() orelse "lex"),
        .cm_mode = try parseCmMode(it.next() orelse "tree"),
        .tree_cfg = .{
            .use_run_shortcut = try parseBool01(it.next() orelse "1"),
            .use_logistic = try parseMix(it.next() orelse "logistic"),
            .use_sse = try parseBool01(it.next() orelse "1"),
        },
    };

    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, path, alloc, .limited(1 << 30));
    defer alloc.free(input);

    std.debug.print("{s}\n", .{header});
    const r = try run(alloc, init.io, path, input, block_bytes, max_rules, min_freq, alpha, cfg);
    printReport(r);
}

test "bwtlab pipeline roundtrips on small synthetic input, every config" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x777);
    const rnd = prng.random();
    const n = 5000;
    const input = try alloc.alloc(u8, n);
    defer alloc.free(input);
    // Text-like: repeated short "words" from a tiny vocabulary, so the
    // grammar actually finds structure.
    const words = [_][]const u8{ "the ", "quick ", "brown ", "fox ", "jumps ", "over ", "lazy ", "dog ", "abcdef ", "zz " };
    var i: usize = 0;
    while (i < n) {
        const w = words[rnd.uintLessThan(usize, words.len)];
        const take = @min(w.len, n - i);
        @memcpy(input[i .. i + take], w[0..take]);
        i += take;
    }

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const configs = [_]LaneWConfig{
        .{ .sort_mode = .creation_order, .cm_mode = .generic },
        .{ .sort_mode = .lex, .cm_mode = .generic },
        .{ .sort_mode = .creation_order, .cm_mode = .tree },
        .{ .sort_mode = .lex, .cm_mode = .tree, .tree_cfg = .{ .use_run_shortcut = false } },
        .{ .sort_mode = .lex, .cm_mode = .tree, .tree_cfg = .{ .use_logistic = false } },
        .{ .sort_mode = .lex, .cm_mode = .tree, .tree_cfg = .{ .use_sse = false } },
        .{ .sort_mode = .lex, .cm_mode = .tree },
    };
    for (configs) |cfg| {
        for ([_]usize{ 0, 512, 4096 }) |block_bytes| {
            for ([_]usize{ 0, 4, 200 }) |max_rules| {
                const r = try run(alloc, io, "synthetic", input, block_bytes, max_rules, 2, 50, cfg);
                try std.testing.expect(r.payload_bytes > 0 or n == 0);
            }
        }
    }
}
