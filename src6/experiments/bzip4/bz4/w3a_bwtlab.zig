//! w3a_bwtlab: Lane W3a driver. Builds a DETERMINISM-GATED partial grammar
//! (w3a_gprobe.zig, idea 1), BWTs each block's root stream lexicographically
//! (symbwt.zig, unmodified from Lane W), codes it with w3a_symcm.zig's
//! TreeCM (idea 2's F-context/junction-byte/urn inputs available as
//! toggles), decodes, inverse-BWTs, expands roots back to bytes through the
//! grammar, verifies byte-exact equality with the raw input, and charges the
//! grammar for real using Lane B's `modelcodec.zig` (idea 3) instead of an
//! `est` bits/rule constant. Real encoder, real decoder, one run; see
//! LANE_W3A.md for the full experiment matrix.
//!
//! Sort-order/tree/run-shortcut/mix/SSE machinery is copied verbatim from
//! Lane W's `bwtlab.zig` (I may only READ that file, not import it, per the
//! lane's file-ownership rule — see PLAN.md/LANE_W3A.md prompt) since this
//! lane's contribution is upstream (grammar) and downstream (extra CM
//! inputs) of that machinery, not a replacement for it.
//!
//! usage: w3a_bwtlab FILE BLOCK_BYTES THETA_PERCENT C_MIN [FCTX] [FBYTES] [BOUNDARY] [URN]
//!   BLOCK_BYTES: 65536 | 1048576 | 0 (0 = whole file, one block)
//!   THETA_PERCENT, C_MIN: idea 1's determinism gate (see w3a_gprobe.zig)
//!   FCTX, FBYTES, BOUNDARY, URN: 1|0, idea 2's TreeCM toggles (default 0);
//!     silently unavailable (treated as 0, `idea2_available=false` in the
//!     report) whenever the frame has more than one block, since only a
//!     single-block frame's model g[] IS the block's exact histogram.

const std = @import("std");
const w3a_gprobe = @import("w3a_gprobe.zig");
const symbwt = @import("symbwt.zig");
const w3a_symcm = @import("w3a_symcm.zig");
const modelcodec = @import("modelcodec.zig");

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn expandOne(alloc: std.mem.Allocator, rules: []const w3a_gprobe.Rule, sym: u32, out: *std.ArrayList(u8)) !void {
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
// Copied from Lane W's bwtlab.zig (read-only file; see module doc comment).
// Lexicographic prefix/suffix keys per symbol, built bottom-up in O(key_cap)
// per rule. `prefix` doubles here as idea 2a's "junction bytes" source (the
// first 1-2 bytes of a symbol's expansion).

const key_cap: u32 = 64;

const SymKey = struct {
    prefix: [key_cap]u8 = undefined,
    prefix_len: u32 = 0,
    suffix: [key_cap]u8 = undefined,
    suffix_len: u32 = 0,
    full_len: u32 = 0,
};

fn buildSymKeys(alloc: std.mem.Allocator, rules: []const w3a_gprobe.Rule, k_alphabet: usize) ![]SymKey {
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

// ------------------------------------------------------------ idea 2a: F --
//
// The BWT's F column is the sorted array of the block's (sentinel-appended)
// symbol multiset -- a pure function of the exact histogram, needing no
// knowledge of L at all (the classic "F is just counting sort" fact). Row i
// (0-indexed among the m=n+1 sorted suffixes) has F(i) = the value at
// cumulative-count rank i. `symbwt.bwt`'s compacted output array `l` (which
// is what this lane's CM actually codes) drops exactly one row -- the one
// whose L happens to be the sentinel (`primary`) -- so l[]-index j relates
// to the SA-row index i via i=j for j<primary, i=j+1 for j>=primary.
// Separately (and independent of where `primary` is), row i=0 ALWAYS has
// F=sentinel: the sentinel is the unique global minimum, so its own suffix
// sorts first. Since `primary` is never 0 for n>=1 (the row whose L is the
// sentinel is the suffix starting at position 0, a different suffix than
// the sentinel's own, whenever n>=1), l[]-index j=0 always maps to i=0,
// i.e. fctx_sym[0] is ALWAYS the block-end sentinel (`w3a_symcm.f_end`) --
// exactly the intuition that "the first BWT output byte is the text's last
// byte, which is followed by nothing" for a single, complete block.
//
// `cnt[v]` = this block's exact count of fwd_rank value v (v in 0..k-1).
// `order_fwd[v]` = the ORIGINAL symbol id at fwd_rank v (so results are in
// the domain the CM actually codes, matching `l_orig` elsewhere in this
// file). Only valid/charged for single-block (whole-file) frames, per the
// lab's own histogram-honesty rule -- see module doc comment.
fn deriveFctx(alloc: std.mem.Allocator, n: usize, primary: usize, cnt: []const u32, order_fwd: []const u32) ![]u32 {
    const k = cnt.len;
    // bucket_start[bkt], bkt=0..k+1: bkt=0 is the sentinel (size 1),
    // bkt=1+v is fwd_rank value v (size cnt[v]).
    const bs = try alloc.alloc(usize, k + 2);
    defer alloc.free(bs);
    bs[0] = 0;
    bs[1] = 1;
    for (0..k) |v| bs[2 + v] = bs[1 + v] + cnt[v];
    std.debug.assert(bs[k + 1] == n + 1);

    const fctx = try alloc.alloc(u32, n);
    errdefer alloc.free(fctx);
    var bkt: usize = 0;
    for (0..n) |j| {
        const i: usize = if (j < primary) j else j + 1;
        while (bs[bkt + 1] <= i) bkt += 1;
        fctx[j] = if (bkt == 0) w3a_symcm.f_end else order_fwd[bkt - 1];
    }
    return fctx;
}

// --------------------------------------------------------------- config --

pub const Idea2Config = struct {
    use_fctx: bool = false,
    use_fctx_bytes: bool = false,
    use_boundary_ctx: bool = false,
    use_urn: bool = false,

    fn any(self: Idea2Config) bool {
        return self.use_fctx or self.use_fctx_bytes or self.use_boundary_ctx or self.use_urn;
    }

    fn toTreeCfg(self: Idea2Config, base: w3a_symcm.TreeCMConfig) w3a_symcm.TreeCMConfig {
        var c = base;
        c.use_fctx = self.use_fctx;
        c.use_fctx_bytes = self.use_fctx_bytes;
        c.use_boundary_ctx = self.use_boundary_ctx;
        c.use_urn = self.use_urn;
        return c;
    }
};

pub const W3aConfig = struct {
    gate: w3a_gprobe.DetGate,
    max_rules: usize = 100_000_000,
    // Safety valve for pathologically slow convergence at loose gates on
    // high-entropy data (see w3a_gprobe.buildBounded's doc comment and
    // LANE_W3A.md's "grammar-build wall-clock" finding). A run that hits
    // this cap reports `grammar_capped=true` and is a REAL partial grammar,
    // not an estimate.
    max_passes: usize = 300,
    tree_base: w3a_symcm.TreeCMConfig = .{},
    idea2: Idea2Config = .{},
    model_variant: modelcodec.Variant = .v2y_leftchild_order,
};

pub const Report = struct {
    file: []const u8,
    block_bytes: usize,
    theta_pct: u32,
    c_min: u32,
    rule_count: usize,
    block_count: usize,
    root_count: usize,
    payload_bytes: usize,
    model_bytes: usize,
    total_bytes: usize, // payload + model + per-block directory (16B/block + 32B header, bz4's own frame-accounting protocol)
    decisions: u64,
    decisions_per_byte: f64,
    idea2_requested: bool,
    idea2_available: bool, // false whenever block_count > 1 (no exact per-block histogram)
    grammar_passes: usize,
    grammar_capped: bool, // hit max_passes before the determinism gate naturally converged
    encode_ms: f64,
    decode_ms: f64,
    grammar_ms: f64,
    model_encode_ms: f64,
    raw_len: usize,
};

const per_block_overhead_bytes: usize = 16;
const header_bytes: usize = 32;

/// Runs the whole Lane W3a pipeline once (one grammar gate, one block size,
/// one TreeCM config). Returns an error on any roundtrip mismatch.
pub fn run(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    input: []const u8,
    block_bytes_arg: usize,
    cfg: W3aConfig,
) !Report {
    const n = input.len;
    const effective_block_bytes = if (block_bytes_arg == 0) @max(@as(usize, 1), n) else block_bytes_arg;

    const t_g0 = nowNs(io);
    var g = try w3a_gprobe.buildBounded(alloc, input, effective_block_bytes, cfg.max_rules, cfg.gate, cfg.max_passes);
    const t_g1 = nowNs(io);
    const grammar_capped = g.passes >= cfg.max_passes;
    defer {
        g.rules.deinit(alloc);
        alloc.free(g.seq.ptr[0..n]);
        alloc.free(g.block_end);
    }

    const k_alphabet = 256 + g.rules.items.len;
    const block_count = (n + effective_block_bytes - 1) / effective_block_bytes;
    const idea2_requested = cfg.idea2.any();
    const idea2_available = idea2_requested and block_count == 1;

    // Global per-symbol root counts. For a single-block frame this IS the
    // block's exact histogram (idea 2's precondition); for multi-block
    // frames it's the sum across blocks, same as Lane W's own `g[]`/weight
    // basis for the tree's prime probabilities either way.
    const freq = try alloc.alloc(u64, k_alphabet);
    defer alloc.free(freq);
    @memset(freq, 0);
    for (g.seq) |s| freq[s] += 1;

    const order_fwd = try alloc.alloc(u32, k_alphabet);
    defer alloc.free(order_fwd);
    const fwd_rank = try alloc.alloc(u32, k_alphabet);
    defer alloc.free(fwd_rank);
    for (order_fwd, 0..) |*o, i| o.* = @intCast(i);
    for (fwd_rank, 0..) |*r, i| r.* = @intCast(i);

    var rev_order: []u32 = &.{};
    var rev_rank: []u32 = &.{};
    var tree: ?w3a_symcm.AlphaTree = null;
    var sym_byte01: []([2]u16) = &.{};
    defer if (rev_order.len > 0) alloc.free(rev_order);
    defer if (rev_rank.len > 0) alloc.free(rev_rank);
    defer if (tree) |*t| t.deinit();
    defer if (sym_byte01.len > 0) alloc.free(sym_byte01);

    // Round 2's defaults (lex sort, tree CM) always apply here -- Lane W3a
    // builds on that result, not the round-1 baseline. Always build the
    // tree, even for k_alphabet==256 (the determinism gate found nothing to
    // merge): a weight-balanced alphabetic tree over exactly the 256 raw
    // bytes is a perfectly valid (if unspecialized) TreeCM instance, and
    // reusing one code path here avoids a second, ByteCM-shaped fallback
    // that idea 2's F-context/urn inputs would need plumbing into as well.
    {
        const keys = try buildSymKeys(alloc, g.rules.items, k_alphabet);
        defer alloc.free(keys);
        std.mem.sort(u32, order_fwd, KeyCtx{ .keys = keys }, KeyCtx.lessPrefix);
        for (order_fwd, 0..) |sym, r| fwd_rank[sym] = @intCast(r);

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
        tree = try w3a_symcm.buildAlphaTree(alloc, rev_order, weight);

        // Idea 2a junction bytes: first two expansion bytes per ORIGINAL
        // symbol id, widened to u16 with 256 = "no such byte" (expansion
        // shorter than 2 bytes -- true for every raw byte symbol's second
        // byte, and for length-1 rules if any existed, which gprobe never
        // creates, but kept general).
        sym_byte01 = try alloc.alloc([2]u16, k_alphabet);
        for (sym_byte01, 0..) |*b, s| {
            const kk = keys[s];
            b.*[0] = if (kk.prefix_len >= 1) kk.prefix[0] else 256;
            b.*[1] = if (kk.prefix_len >= 2) kk.prefix[1] else 256;
        }
    }

    var total_payload: usize = 0;
    var total_encode_ns: u64 = 0;
    var total_decode_ns: u64 = 0;
    var total_decisions: u64 = 0;

    var sym_start: usize = 0;
    var byte_start: usize = 0;
    for (g.block_end) |sym_end| {
        const byte_end = @min(n, byte_start + effective_block_bytes);
        const root_slice = g.seq[sym_start..sym_end];

        const remapped = try alloc.alloc(u32, root_slice.len);
        defer alloc.free(remapped);
        for (root_slice, 0..) |sym, i| remapped[i] = fwd_rank[sym];

        const t_e0 = nowNs(io);
        const bw = try symbwt.bwt(alloc, remapped, k_alphabet);
        defer alloc.free(bw.l);
        const l_orig = try alloc.alloc(u32, bw.l.len);
        defer alloc.free(l_orig);
        for (bw.l, 0..) |v, i| l_orig[i] = order_fwd[v];

        // Idea 2 contexts (single-block frames only -- see module doc).
        var fctx: []u32 = &.{};
        defer if (fctx.len > 0) alloc.free(fctx);
        var urn_counts: []u32 = &.{};
        defer if (urn_counts.len > 0) alloc.free(urn_counts);
        if (idea2_available) {
            const cnt = try alloc.alloc(u32, k_alphabet);
            defer alloc.free(cnt);
            @memset(cnt, 0);
            for (remapped) |v| cnt[v] += 1;
            fctx = try deriveFctx(alloc, root_slice.len, bw.primary, cnt, order_fwd);

            if (cfg.idea2.use_urn) {
                urn_counts = try alloc.alloc(u32, k_alphabet);
                @memset(urn_counts, 0);
                for (root_slice) |sym| urn_counts[rev_rank[sym]] += 1;
            }
        }
        const tree_cfg = cfg.idea2.toTreeCfg(cfg.tree_base);
        const byte01_arg: []const [2]u16 = if (cfg.idea2.use_fctx_bytes and idea2_available) sym_byte01 else &.{};

        const enc = try w3a_symcm.encodeSymbolsTree(alloc, l_orig, &tree.?, rev_order, rev_rank, tree_cfg, fctx, byte01_arg, urn_counts);
        defer alloc.free(enc.bytes);
        const t_e1 = nowNs(io);
        total_encode_ns += @intCast(t_e1 - t_e0);
        total_payload += enc.bytes.len;
        total_decisions += enc.decisions;

        const t_d0 = nowNs(io);
        const dec = try w3a_symcm.decodeSymbolsTree(alloc, enc.bytes, root_slice.len, &tree.?, rev_order, rev_rank, tree_cfg, fctx, byte01_arg, urn_counts);
        defer alloc.free(dec.syms);
        if (!std.mem.eql(u32, l_orig, dec.syms)) return error.CmRoundtripMismatch;
        if (enc.decisions != dec.decisions) return error.DecisionCountMismatch;

        const l_fwd2 = try alloc.alloc(u32, dec.syms.len);
        defer alloc.free(l_fwd2);
        for (dec.syms, 0..) |sym, i| l_fwd2[i] = fwd_rank[sym];
        const seq2_fwd = try symbwt.ibwt(alloc, l_fwd2, bw.primary, k_alphabet);
        defer alloc.free(seq2_fwd);
        const seq2 = try alloc.alloc(u32, seq2_fwd.len);
        defer alloc.free(seq2);
        for (seq2_fwd, 0..) |v, i| seq2[i] = order_fwd[v];
        const t_d1 = nowNs(io);
        total_decode_ns += @intCast(t_d1 - t_d0);
        if (!std.mem.eql(u32, root_slice, seq2)) return error.BwtRoundtripMismatch;

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try out.ensureTotalCapacity(alloc, byte_end - byte_start);
        for (seq2) |sym| try expandOne(alloc, g.rules.items, sym, &out);
        if (!std.mem.eql(u8, input[byte_start..byte_end], out.items)) return error.ExpansionMismatch;

        sym_start = sym_end;
        byte_start = byte_end;
    }
    std.debug.assert(sym_start == g.seq.len);

    // Idea 3: charge the grammar for real via Lane B's modelcodec, instead
    // of an `est` bits/rule constant.
    const codec_rules = try alloc.alloc(modelcodec.Rule, g.rules.items.len);
    defer alloc.free(codec_rules);
    for (g.rules.items, 0..) |r, i| codec_rules[i] = .{ .a = r.a, .b = r.b };
    var dump: modelcodec.Dump = .{
        .rule_count = @intCast(g.rules.items.len),
        .block_count = @intCast(block_count),
        .block_bytes = @intCast(effective_block_bytes),
        .raw_len = @intCast(n),
        .rules = codec_rules,
        .g = freq,
        .alloc = alloc,
    };
    const t_m0 = nowNs(io);
    var model_bytes: modelcodec.ModelBytes = try modelcodec.encodeModel(alloc, &dump, cfg.model_variant);
    defer model_bytes.deinit();
    const t_m1 = nowNs(io);
    var decoded_model = try modelcodec.decodeModel(alloc, model_bytes.bytes);
    defer decoded_model.deinit();
    const vr = try modelcodec.verifyModel(alloc, &dump, &decoded_model);
    if (!vr.ok) return error.ModelVerifyFailed;
    // dump.rules/dump.g are borrowed (codec_rules/freq); do not double-free.
    dump.rules = &.{};
    dump.g = &.{};

    const total_bytes = total_payload + model_bytes.bytes.len + per_block_overhead_bytes * block_count + header_bytes;

    return .{
        .file = path,
        .block_bytes = block_bytes_arg,
        .theta_pct = cfg.gate.theta_pct,
        .c_min = cfg.gate.c_min,
        .rule_count = g.rules.items.len,
        .block_count = block_count,
        .root_count = g.seq.len,
        .payload_bytes = total_payload,
        .model_bytes = model_bytes.bytes.len,
        .total_bytes = total_bytes,
        .decisions = total_decisions,
        .decisions_per_byte = if (n == 0) 0 else @as(f64, @floatFromInt(total_decisions)) / @as(f64, @floatFromInt(n)),
        .idea2_requested = idea2_requested,
        .idea2_available = idea2_available,
        .grammar_passes = g.passes,
        .grammar_capped = grammar_capped,
        .encode_ms = @as(f64, @floatFromInt(total_encode_ns)) / 1e6,
        .decode_ms = @as(f64, @floatFromInt(total_decode_ns)) / 1e6,
        .grammar_ms = @as(f64, @floatFromInt(t_g1 - t_g0)) / 1e6,
        .model_encode_ms = @as(f64, @floatFromInt(t_m1 - t_m0)) / 1e6,
        .raw_len = n,
    };
}

const header = "file\tblock_bytes\ttheta_pct\tc_min\trules\tblocks\troots\tpayload_B\tmodel_B\ttotal_B\tdecisions\tdecisions_per_byte\tidea2_avail\tpasses\tcapped\tencode_ms\tdecode_ms\tgrammar_ms\tmodel_ms\traw_len";

fn printReport(r: Report) void {
    std.debug.print("{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d:.3}\t{}\t{d}\t{}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.2}\t{d}\n", .{
        r.file,            r.block_bytes,   r.theta_pct,      r.c_min,
        r.rule_count,      r.block_count,   r.root_count,     r.payload_bytes,
        r.model_bytes,     r.total_bytes,   r.decisions,      r.decisions_per_byte,
        r.idea2_available, r.grammar_passes, r.grammar_capped, r.encode_ms,     r.decode_ms,      r.grammar_ms,
        r.model_encode_ms, r.raw_len,
    });
}

fn parseBool01(s: []const u8) !bool {
    if (std.mem.eql(u8, s, "1")) return true;
    if (std.mem.eql(u8, s, "0")) return false;
    return error.Usage;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const path = it.next() orelse return error.Usage;
    const block_bytes = try std.fmt.parseUnsigned(usize, it.next() orelse return error.Usage, 10);
    const theta_pct = try std.fmt.parseUnsigned(u32, it.next() orelse return error.Usage, 10);
    const c_min = try std.fmt.parseUnsigned(u32, it.next() orelse return error.Usage, 10);
    const cfg = W3aConfig{
        .gate = .{ .theta_pct = theta_pct, .c_min = c_min },
        .idea2 = .{
            .use_fctx = try parseBool01(it.next() orelse "0"),
            .use_fctx_bytes = try parseBool01(it.next() orelse "0"),
            .use_boundary_ctx = try parseBool01(it.next() orelse "0"),
            .use_urn = try parseBool01(it.next() orelse "0"),
        },
    };

    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, path, alloc, .limited(1 << 30));
    defer alloc.free(input);

    std.debug.print("{s}\n", .{header});
    const r = try run(alloc, init.io, path, input, block_bytes, cfg);
    printReport(r);
}

// ---------------------------------------------------------------- tests --

test "deriveFctx matches a brute-force rotation sort (F follows L in the cyclic text)" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xFEED);
    const rnd = prng.random();
    for (0..30) |trial| {
        const n = 1 + rnd.uintLessThan(usize, 50);
        const k: usize = 1 + rnd.uintLessThan(usize, 6);
        const seq = try alloc.alloc(u32, n);
        defer alloc.free(seq);
        for (seq) |*s| s.* = rnd.uintLessThan(u32, @intCast(k));

        const bw = try symbwt.bwt(alloc, seq, k);
        defer alloc.free(bw.l);

        var cnt = try alloc.alloc(u32, k);
        defer alloc.free(cnt);
        @memset(cnt, 0);
        for (seq) |s| cnt[s] += 1;
        const order_fwd = try alloc.alloc(u32, k);
        defer alloc.free(order_fwd);
        for (order_fwd, 0..) |*o, i| o.* = @intCast(i); // identity: test works directly in value domain

        const fctx = try deriveFctx(alloc, n, bw.primary, cnt, order_fwd);
        defer alloc.free(fctx);

        // Brute-force reference: build u = [seq+1..., 0], sort all m
        // rotations, and for each SA-row read off F(i)=u[SA[i]] directly.
        const m = n + 1;
        const u = try alloc.alloc(u32, m);
        defer alloc.free(u);
        for (seq, 0..) |s, i| u[i] = s + 1;
        u[n] = 0;
        const idx = try alloc.alloc(usize, m);
        defer alloc.free(idx);
        for (0..m) |i| idx[i] = i;
        const Ctx = struct {
            u: []const u32,
            m: usize,
            fn less(self: @This(), a: usize, b: usize) bool {
                var i: usize = 0;
                while (i < self.m) : (i += 1) {
                    const av = self.u[(a + i) % self.m];
                    const bv = self.u[(b + i) % self.m];
                    if (av != bv) return av < bv;
                }
                return false;
            }
        };
        std.mem.sort(usize, idx, Ctx{ .u = u, .m = m }, Ctx.less);

        // Confirm this trial's `primary` (row whose L is the sentinel)
        // agrees with symbwt's, then check every j against the brute force.
        var primary_ref: usize = std.math.maxInt(usize);
        for (idx, 0..) |s, i| {
            const src = (s + m - 1) % m;
            if (u[src] == 0) primary_ref = i;
        }
        try std.testing.expectEqual(bw.primary, primary_ref);

        for (0..n) |j| {
            const i: usize = if (j < bw.primary) j else j + 1;
            const f_u = u[idx[i]];
            const expected: u32 = if (f_u == 0) w3a_symcm.f_end else f_u - 1;
            std.testing.expectEqual(expected, fctx[j]) catch |e| {
                std.debug.print("trial {d} failed at j={d} (n={d} k={d})\n", .{ trial, j, n, k });
                return e;
            };
        }
    }
}

test "w3a_bwtlab pipeline roundtrips on small synthetic input, every idea1/idea2 combo" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x9A9A);
    const rnd = prng.random();
    const n = 6000;
    const input = try alloc.alloc(u8, n);
    defer alloc.free(input);
    const words = [_][]const u8{ "the ", "quick ", "brown ", "fox ", "jumps ", "over ", "lazy ", "dog ", "abcdef ", "zz ", "1234567890" };
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

    const gates = [_]w3a_gprobe.DetGate{
        .{ .theta_pct = 95, .c_min = 4 },
        .{ .theta_pct = 60, .c_min = 4 },
        .{ .theta_pct = 0, .c_min = 4 },
    };
    const idea2s = [_]Idea2Config{
        .{},
        .{ .use_fctx = true },
        .{ .use_fctx_bytes = true },
        .{ .use_boundary_ctx = true },
        .{ .use_urn = true },
        .{ .use_fctx = true, .use_fctx_bytes = true, .use_boundary_ctx = true, .use_urn = true },
    };
    for (gates) |gate| {
        for ([_]usize{ 0, 512, 4096 }) |block_bytes| {
            for (idea2s) |idea2| {
                const cfg = W3aConfig{ .gate = gate, .idea2 = idea2 };
                const r = try run(alloc, io, "synthetic", input, block_bytes, cfg);
                try std.testing.expect(r.total_bytes > 0);
                // idea2 is only ever "available" for the single, whole-file
                // block, and only when actually requested.
                if (block_bytes != 0 or !idea2.any()) {
                    try std.testing.expect(!r.idea2_available);
                } else {
                    try std.testing.expect(r.idea2_available);
                }
            }
        }
    }
}
