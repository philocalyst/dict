//! DELETE: an entry may be deleted wherever it's referenced -- corpus *or*
//! any other entry's spelling (n-ary storage makes this a strict
//! generalisation of a fixed-arity grammar's "nobody's child" restriction).
//! `buildResolved`/`spliceMarked` are the reusable splice mechanics (an
//! arbitrary `marked` set of entries gets inlined back to their own
//! spelling, everywhere they're used, and the survivors are renumbered);
//! `deletePass` is Lane M's original order-0-MDL-benefit policy that
//! decides which entries to mark. `joint.zig` reuses `buildResolved`/
//! `spliceMarked` with a *different* ranking (class-conditional benefit)
//! but the same splice mechanics -- one mechanism, two policies.
//!
//! Ported from `m_lexicon.zig` (Lane M) per PLAN.md's copy-and-reshape
//! rule.

const std = @import("std");
const lexicon = @import("lexicon.zig");
const Corpus = lexicon.Corpus;
const Lexicon = lexicon.Lexicon;
const LexBuilder = lexicon.LexBuilder;
const flog = lexicon.flog;
const log2f = lexicon.log2f;
const dlEstimate = lexicon.dlEstimate;
const Calib = lexicon.Calib;
const Opts = @import("propose.zig").Opts;

/// For every marked entry, its own spelling with every marked component
/// recursively spliced in too (so a marked entry that itself contains
/// another marked entry resolves fully in one lookup). Entries are
/// resolved in explen-ascending order (always a valid dependency order).
pub fn buildResolved(alloc: std.mem.Allocator, lex: *const Lexicon, marked: []const bool) ![]?[]u32 {
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

pub fn emitResolveAll(alloc: std.mem.Allocator, out: *std.ArrayList(u32), items: []const u32, marked: []const bool, resolved: []const ?[]u32) !void {
    for (items) |t| {
        if (t >= 256 and marked[t - 256]) {
            try out.appendSlice(alloc, resolved[t - 256].?);
        } else {
            try out.append(alloc, t);
        }
    }
}

/// Splice every marked entry out of the lexicon and the corpus (inlining
/// its spelling everywhere it was used) and renumber the survivors. This
/// is the mechanical half of deletion; `deletePass`/`joint.zig` supply the
/// policy that decides `marked`.
pub fn spliceMarked(alloc: std.mem.Allocator, corpus: *Corpus, marked: []const bool) !void {
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

fn simulateDelete(alloc: std.mem.Allocator, corpus: *const Corpus, marked: []const bool, calib: Calib) !f64 {
    const resolved = try buildResolved(alloc, &corpus.lex, marked);
    const k = 256 + corpus.lex.numEntries();
    const n = try alloc.alloc(u64, k);
    @memset(n, 0);
    var m: u64 = 0;
    tallyResolved(corpus.seq, marked, resolved, n, &m);
    for (0..corpus.lex.numEntries()) |i| {
        if (marked[i]) continue;
        tallyResolved(corpus.lex.comps(i), marked, resolved, n, &m);
    }
    var num_alive: usize = 0;
    for (marked) |mk| {
        if (!mk) num_alive += 1;
    }
    return dlEstimate(n, m, num_alive, calib);
}

const DelCand = struct { idx: u32, benefit: f64 };
fn delCandDesc(_: void, x: DelCand, y: DelCand) bool {
    return x.benefit > y.benefit;
}

/// The exact DL delta (bits) of splicing every use of one entry (`comps`,
/// used `u` times) back to its own spelling, against a shared population
/// `n`/`m` (`M*log2(M) - sum f(c)`'s exact-identity trick makes this an
/// O(arity) update, not a full recount). Positive = deleting it pays.
/// Exposed so `joint.zig` can reuse the identical order-0 formula, scoped
/// to the *lexicon's own* (spelling-only) population, as one half of its
/// class-conditional benefit estimate -- see that file's doc comment.
pub fn order0Benefit(alloc: std.mem.Allocator, comps: []const u32, n: []const u64, m: u64, u: u64, calib: Calib) !f64 {
    const mf: f64 = @floatFromInt(m);
    const r: f64 = @floatFromInt(comps.len);
    const uf: f64 = @floatFromInt(u);
    const m_after = mf + r * uf - r - uf;
    if (m_after <= 0) return -std.math.inf(f64);
    const delta_mlogm = m_after * log2f(m_after) - mf * log2f(mf);

    const tmp = try alloc.dupe(u32, comps);
    defer alloc.free(tmp);
    std.mem.sort(u32, tmp, {}, std.sort.asc(u32));
    var delta_children: f64 = 0;
    var idx: usize = 0;
    while (idx < tmp.len) {
        var j = idx + 1;
        while (j < tmp.len and tmp[j] == tmp[idx]) j += 1;
        const v = tmp[idx];
        const mult: f64 = @floatFromInt(j - idx);
        const nv: u64 = n[v];
        const nvf: f64 = @floatFromInt(nv);
        const add = mult * (uf - 1);
        const nv_new = @max(0, nvf + add);
        delta_children += flog(@intFromFloat(@round(nv_new))) - flog(nv);
        idx = j;
    }
    return delta_children - delta_mlogm - flog(u) + calib.entry_bits;
}

/// Order-0 MDL deletion (Lane M's original policy): benefit is the exact
/// DL delta of splicing every use of the entry back to its own spelling,
/// for the unified corpus+spelling population. Batched with a rank +
/// halving safety net (never accepts a batch whose real-recomputed DL
/// isn't actually smaller).
pub fn deletePass(alloc: std.mem.Allocator, corpus: *Corpus, opts: Opts) !usize {
    const rc = try lexicon.recount(alloc, corpus);
    const num_entries = corpus.lex.numEntries();
    if (num_entries == 0) return 0;
    const current_dl = dlEstimate(rc.n, rc.m, num_entries, opts.calib);

    var cands: std.ArrayList(DelCand) = .empty;
    for (0..num_entries) |i| {
        const sym: u32 = @intCast(256 + i);
        const u: u64 = rc.n[sym];
        const benefit = try order0Benefit(alloc, corpus.lex.comps(i), rc.n, rc.m, u, opts.calib);
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
        const trial = try simulateDelete(alloc, corpus, marked, opts.calib);
        if (trial < current_dl) {
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

test "deletePass removes entries that stop paying and stays byte-exact" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const raw = "abababababab xyxyxyxyxyxy abab";
    var corpus = try lexicon.seedBytes(a, raw, 4096);
    const propose = @import("propose.zig");
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        _ = try propose.proposePairs(a, &corpus, .{});
    }
    const before = corpus.lex.numEntries();
    _ = try deletePass(a, &corpus, .{});
    try std.testing.expect(corpus.lex.numEntries() <= before);
    try std.testing.expect(try lexicon.verifyExact(a, raw, &corpus));
}
