//! w3b_speedlab: Lane W3b's measurement harness.
//!
//! usage: w3b_speedlab FILE BLOCK_BYTES K [REPEATS]
//!   BLOCK_BYTES: 0 (whole file) | a byte count (e.g. 1048576)
//!   K:           gprobe rule cap (MIN_FREQ=2, ALPHA=50 fixed, per the lane
//!                brief); grammar is shared across all blocks of the file
//!                (gprobe.build's own barrier-respecting design already
//!                does this — one call, one grammar, many blocks)
//!   REPEATS:     default 5
//!
//! Pipeline (mirrors `bwtlab.zig`'s default "lex sort, tree CM, run
//! shortcut, logistic mix, SSE" cell, since that's Lane W's own best
//! setting and the size floor this lane must stay within ~1-1.5% of):
//! gprobe grammar -> lexicographic fwd_rank + reversed-expansion rev_rank
//! (copied from `bwtlab.zig` per PLAN.md's "copy a shared pattern into your
//! own file" rule — those helpers are private to `bwtlab.zig`, so they
//! can't be imported) -> per block: symbwt.bwt (Lane W's own, imported
//! read-only; forward-BWT speed is not this lane's target) -> encode with
//! `w3b_fastcm.FastTreeCM` -> [timed] decode with `FastTreeCM` + fused
//! inverse-BWT/expansion (`w3b_fastcm.inverseBwtExpandFused`).
//!
//! Prints one TSV report line per run to stdout (see `header`), plus one
//! diagnostic PHASE line to stderr breaking decode down into cm_init
//! (per-block table allocation+clear) / decode_core (entropy decode) /
//! ibwt_expand (fused inverse-BWT + grammar expansion) for the median
//! repeat, and one SETUP line to stderr for the one-time grammar/sort/tree/
//! expansion-arena/encode cost. `bzip3_decode_MBps` is read straight out of
//! `baselines.tsv` (Lane D's real numbers) for the same file + block_bytes.
//! `size_delta_pct` compares this lane's real payload against a real run of
//! Lane W's own `symcm.TreeCM` (imported read-only for comparison only, per
//! the lane brief's explicit allowance — "run bin/bwtlab or import symcm to
//! get it") at its default (best) config, same grammar/blocks/sort/tree.
//!
//! Every number is from a real encoder whose output a real decoder turned
//! back into the exact input bytes, checked in an untimed pass before any
//! timing is trusted (rules of evidence: verification never happens inside
//! the clock).

const std = @import("std");
const gprobe = @import("gprobe.zig");
const symbwt = @import("symbwt.zig");
const symcm = @import("symcm.zig"); // Lane W's own — comparison only, per lane brief
const fastcm = @import("w3b_fastcm.zig");

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

// ---------------------------------------------------------- rank keys --
// Copied from `bwtlab.zig` (Lane W, round 2) — those helpers are `fn`
// (private) there, not `pub`, so this lane's own file needs its own copy
// per PLAN.md's "copy a shared pattern into your own file" rule. Unmodified
// except for cosmetic renames; see `bwtlab.zig` for the original commentary
// on why prefix/suffix keys are capped rather than materialising full
// expansions (pathological rule-chain blowup risk).

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

// --------------------------------------------------------------- misc --

fn median(vals: []f64) f64 {
    std.mem.sort(f64, vals, {}, std.sort.asc(f64));
    const n = vals.len;
    if (n % 2 == 1) return vals[n / 2];
    return (vals[n / 2 - 1] + vals[n / 2]) / 2.0;
}

fn minOf(vals: []const f64) f64 {
    var m = vals[0];
    for (vals[1..]) |v| m = @min(m, v);
    return m;
}

fn basename(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) : (i -= 1) if (path[i - 1] == '/') return path[i..];
    return path;
}

/// Looks up (file, block_bytes) in baselines.tsv, returns decode_MBps or
/// null if the exact cell wasn't measured there.
fn lookupBzip3MBps(alloc: std.mem.Allocator, io: std.Io, file: []const u8, block_bytes: usize) !?f64 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "baselines.tsv", alloc, .limited(1 << 20)) catch return null;
    defer alloc.free(bytes);
    const fname = basename(file);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    _ = lines.next(); // header
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const f = cols.next() orelse continue;
        const bb_s = cols.next() orelse continue;
        if (!std.mem.eql(u8, f, fname)) continue;
        const bb = std.fmt.parseUnsigned(usize, bb_s, 10) catch continue;
        if (bb != block_bytes) continue;
        // block_count, payload_bytes, total_bytes, encode_ms, decode_min_ms, decode_median_ms, decode_MBps
        _ = cols.next(); // block_count
        _ = cols.next(); // payload_bytes
        _ = cols.next(); // total_bytes
        _ = cols.next(); // encode_ms
        _ = cols.next(); // decode_min_ms
        _ = cols.next(); // decode_median_ms
        const mbps_s = cols.next() orelse continue;
        return std.fmt.parseFloat(f64, std.mem.trim(u8, mbps_s, " \r\n")) catch null;
    }
    return null;
}

// ------------------------------------------------------------- blocks --

const Block = struct {
    payload: []const u8,
    primary: usize,
    root_count: usize,
    byte_start: usize,
    byte_end: usize,
    decisions: u64,
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const path = it.next() orelse return error.Usage;
    const block_bytes_arg = try std.fmt.parseUnsigned(usize, it.next() orelse return error.Usage, 10);
    const max_rules = try std.fmt.parseUnsigned(usize, it.next() orelse return error.Usage, 10);
    const repeats = try std.fmt.parseUnsigned(usize, it.next() orelse "5", 10);
    // Optional ablation tag (default "default"): selects this lane's own
    // FastTreeCMConfig for the before/after log in LANE_W3B.md. Never
    // affects the Lane W comparison coder, the grammar, or the sort/tree.
    const ablation = it.next() orelse "default";
    const my_cfg: fastcm.FastTreeCMConfig = if (std.mem.eql(u8, ablation, "default"))
        .{}
    else if (std.mem.eql(u8, ablation, "legacy_hash"))
        .{ .legacy_hash = true }
    else if (std.mem.eql(u8, ablation, "fixed_mix"))
        .{ .use_mixer = false }
    else if (std.mem.eql(u8, ablation, "no_sse"))
        .{ .use_sse = false }
    else if (std.mem.eql(u8, ablation, "no_run"))
        .{ .use_run_shortcut = false }
    else if (std.mem.eql(u8, ablation, "legacy_hash_fixed_mix"))
        .{ .legacy_hash = true, .use_mixer = false }
    else
        return error.Usage;
    const min_freq: u32 = 2;
    const alpha_percent: u32 = 50;

    const input = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 30));
    defer alloc.free(input);
    const n = input.len;
    const effective_block_bytes = if (block_bytes_arg == 0) @max(@as(usize, 1), n) else block_bytes_arg;

    const t_setup0 = nowNs(io);

    var g = try gprobe.build(alloc, input, effective_block_bytes, max_rules, min_freq, alpha_percent);
    defer {
        g.rules.deinit(alloc);
        alloc.free(g.seq.ptr[0..n]);
        alloc.free(g.block_end);
    }
    const k_alphabet = 256 + g.rules.items.len;
    const block_count = (n + effective_block_bytes - 1) / effective_block_bytes;

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
    var tree: ?fastcm.AlphaTree = null;
    var tree_w: ?symcm.AlphaTree = null; // Lane W's own (16-bit) tree, comparison only
    defer if (rev_order.len > 0) alloc.free(rev_order);
    defer if (rev_rank.len > 0) alloc.free(rev_rank);
    defer if (tree) |*t| t.deinit();
    defer if (tree_w) |*t| t.deinit();

    // Lane W's own bwtlab only builds the tree/lex-sort machinery when a
    // real grammar exists (`k_alphabet > 256`); at k=0 it falls back to
    // plain `ByteCM` (see `bwtlab.zig`'s `need_tree`/`need_lex`). This
    // lane's own coder does *not* need that special case — `FastTreeCM`
    // handles a 256-leaf tree fine via its direct-indexed (no hash) small-
    // alphabet path, which is exactly the "same algorithm, different table
    // layout" the brief allows for the k=0 case — so the tree/rank/weight
    // machinery below always runs. `has_grammar` is kept only to choose
    // which of *Lane W's* coders (TreeCM vs ByteCM) is the fair comparison
    // target for `size_delta_pct`, matching what `bwtlab` actually emits.
    const has_grammar = k_alphabet > 256;
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
            w.* = @as(u32, @intCast(capped)) + 1;
        }
        tree = try fastcm.buildAlphaTree(alloc, rev_order, weight);
        if (has_grammar) tree_w = try symcm.buildAlphaTree(alloc, rev_order, weight);
    }

    // Grammar expansion arena (offset,len), point 7. Works uniformly at
    // k=0 too (0 rules -> just the 256 identity byte entries).
    var exp_mut = try fastcm.buildExpansion(alloc, g.rules.items);
    defer exp_mut.deinit();

    // Encode every block once (untimed setup): both this lane's fast coder
    // and Lane W's own TreeCM (for the real size-delta comparison).
    var blocks = try alloc.alloc(Block, block_count);
    defer {
        for (blocks) |b| alloc.free(b.payload);
        alloc.free(blocks);
    }
    var laneW_payload_total: usize = 0;
    var max_root_count: usize = 0;
    var sym_start: usize = 0;
    var byte_start: usize = 0;
    var bi: usize = 0;
    while (bi < block_count) : (bi += 1) {
        const sym_end = g.block_end[bi];
        const byte_end = @min(n, byte_start + effective_block_bytes);
        const root_slice = g.seq[sym_start..sym_end];
        max_root_count = @max(max_root_count, root_slice.len);

        const remapped = try alloc.alloc(u32, root_slice.len);
        defer alloc.free(remapped);
        for (root_slice, 0..) |sym, i| remapped[i] = fwd_rank[sym];

        const bw = try symbwt.bwt(alloc, remapped, k_alphabet);
        defer alloc.free(bw.l);
        const l_orig = try alloc.alloc(u32, bw.l.len);
        defer alloc.free(l_orig);
        for (bw.l, 0..) |v, i| l_orig[i] = order_fwd[v];

        const enc = try fastcm.encodeSymbols(alloc, l_orig, &tree.?, rev_order, rev_rank, my_cfg);
        const enc_bytes = enc.bytes;
        const enc_decisions = enc.decisions;

        blocks[bi] = .{
            .payload = enc_bytes,
            .primary = bw.primary,
            .root_count = root_slice.len,
            .byte_start = byte_start,
            .byte_end = byte_end,
            .decisions = enc_decisions,
        };

        // Lane W's own real payload at its default best setting, same
        // grammar/sort/tree/blocks — for the size_delta_pct comparison.
        if (has_grammar) {
            const encw = try symcm.encodeSymbolsTree(alloc, l_orig, &tree_w.?, rev_order, rev_rank, .{});
            defer alloc.free(encw.bytes);
            laneW_payload_total += encw.bytes.len;
        } else {
            const encw = try symcm.encodeSymbolsCounted(alloc, l_orig, k_alphabet);
            defer alloc.free(encw.bytes);
            laneW_payload_total += encw.bytes.len;
        }

        sym_start = sym_end;
        byte_start = byte_end;
    }

    const t_setup1 = nowNs(io);
    const setup_ms = @as(f64, @floatFromInt(t_setup1 - t_setup0)) / 1e6;

    // ---------------------------------------------------- verify (untimed) --
    var scratch = try fastcm.BwtScratch.init(alloc, max_root_count + 1, k_alphabet);
    defer scratch.deinit();
    const out = try alloc.alloc(u8, n);
    defer alloc.free(out);

    var total_decisions: u64 = 0;
    var total_payload: usize = 0;
    for (blocks) |b| {
        var cm = try fastcm.FastTreeCM.init(alloc, &tree.?, rev_order, my_cfg);
        defer cm.deinit();
        var dec = @import("w3b_rc.zig").Decoder.init(b.payload);
        const l_fwd = try alloc.alloc(u32, b.root_count);
        defer alloc.free(l_fwd);
        for (l_fwd) |*s| {
            const sym = cm.decodeSymbol(&dec);
            s.* = fwd_rank[sym];
        }
        if (cm.decisions != b.decisions) return error.DecisionCountMismatch;
        const written = fastcm.inverseBwtExpandFused(&scratch, l_fwd, b.primary, k_alphabet, order_fwd, &exp_mut, out[b.byte_start..b.byte_end]);
        if (written != b.byte_end - b.byte_start) return error.ShortExpansion;
        total_decisions += b.decisions;
        total_payload += b.payload.len;
    }
    if (!std.mem.eql(u8, input, out)) return error.RoundtripMismatch;

    // ------------------------------------------------------- timed decode --
    // Each repeat: for every block, init a fresh FastTreeCM (per-block
    // table alloc+clear, the real cost of an independently-decodable-blocks
    // design — point 2's "clearing large tables per block" charged here,
    // not hidden), decode all symbols, then the fused inverse-BWT+expand.
    // Phase totals (summed over all blocks) are kept for repeat 0 only, as
    // a representative breakdown (see the PHASE stderr line).
    var repeat_ms = try alloc.alloc(f64, repeats);
    defer alloc.free(repeat_ms);
    var phase_cm_init_ns: u64 = 0;
    var phase_decode_core_ns: u64 = 0;
    var phase_ibwt_expand_ns: u64 = 0;

    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        const t0 = nowNs(io);
        for (blocks) |b| {
            const t_a = nowNs(io);
            var cm = try fastcm.FastTreeCM.init(alloc, &tree.?, rev_order, my_cfg);
            const t_b = nowNs(io);
            var dec = @import("w3b_rc.zig").Decoder.init(b.payload);
            const l_fwd = try alloc.alloc(u32, b.root_count);
            for (l_fwd) |*s| {
                const sym = cm.decodeSymbol(&dec);
                s.* = fwd_rank[sym];
            }
            const t_c = nowNs(io);
            _ = fastcm.inverseBwtExpandFused(&scratch, l_fwd, b.primary, k_alphabet, order_fwd, &exp_mut, out[b.byte_start..b.byte_end]);
            const t_d = nowNs(io);
            alloc.free(l_fwd);
            cm.deinit();
            if (rep == 0) {
                phase_cm_init_ns += @intCast(t_b - t_a);
                phase_decode_core_ns += @intCast(t_c - t_b);
                phase_ibwt_expand_ns += @intCast(t_d - t_c);
            }
        }
        const t1 = nowNs(io);
        repeat_ms[rep] = @as(f64, @floatFromInt(t1 - t0)) / 1e6;
    }

    const decode_ms_min = minOf(repeat_ms);
    const decode_ms_median = median(repeat_ms);
    const ns_per_decision = decode_ms_median * 1e6 / @as(f64, @floatFromInt(total_decisions));
    const decode_MBps = (@as(f64, @floatFromInt(n)) / 1e6) / (decode_ms_median / 1000.0);
    const bzip3_MBps = (try lookupBzip3MBps(alloc, io, path, block_bytes_arg)) orelse 0;
    const speedup = if (bzip3_MBps > 0) decode_MBps / bzip3_MBps else 0;
    const size_delta_pct = if (laneW_payload_total > 0)
        (@as(f64, @floatFromInt(total_payload)) - @as(f64, @floatFromInt(laneW_payload_total))) / @as(f64, @floatFromInt(laneW_payload_total)) * 100.0
    else
        0;

    std.debug.print(
        "SETUP file={s} block={d} k={d} rules={d} setup_ms={d:.2} laneW_payload_B={d}\n",
        .{ basename(path), block_bytes_arg, max_rules, g.rules.items.len, setup_ms, laneW_payload_total },
    );
    std.debug.print(
        "PHASE file={s} block={d} k={d} cm_init_ms={d:.2} decode_core_ms={d:.2} ibwt_expand_ms={d:.2}\n",
        .{
            basename(path), block_bytes_arg, max_rules,
            @as(f64, @floatFromInt(phase_cm_init_ns)) / 1e6,
            @as(f64, @floatFromInt(phase_decode_core_ns)) / 1e6,
            @as(f64, @floatFromInt(phase_ibwt_expand_ns)) / 1e6,
        },
    );

    const header = "file\tblock_bytes\tk\trules\troots\tpayload_B\tdecisions\tdecisions_per_byte\tdecode_ms_min\tdecode_ms_median\tsetup_ms\tns_per_decision\tdecode_MBps\tbzip3_decode_MBps\tspeedup\tsize_delta_pct";
    std.debug.print("{s}\n", .{header});
    const dpb: f64 = if (n == 0) 0 else @as(f64, @floatFromInt(total_decisions)) / @as(f64, @floatFromInt(n));
    std.debug.print("{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d:.3}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.2}\n", .{
        basename(path),  block_bytes_arg, max_rules,       g.rules.items.len, g.seq.len,
        total_payload,   total_decisions, dpb,             decode_ms_min,     decode_ms_median,
        setup_ms,        ns_per_decision, decode_MBps,     bzip3_MBps,        speedup,
        size_delta_pct,
    });
}
