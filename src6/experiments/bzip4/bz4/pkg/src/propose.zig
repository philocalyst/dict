//! PROPOSE: tally adjacent pairs/triples over the current parse of the
//! corpus *and* every entry's own spelling, score each by an estimated MDL
//! delta, keep only net-saving candidates, select a role-consistent subset
//! (no symbol is both a left and right member of two different accepted
//! pairs in the same round -- Lane A's builder trick, generalised to n-ary
//! storage), and rewrite the corpus and every entry's spelling in one pass.
//!
//! Ported from `m_lexicon.zig` (Lane M) per PLAN.md's copy-and-reshape
//! rule.

const std = @import("std");
const lexicon = @import("lexicon.zig");
const Corpus = lexicon.Corpus;
const LexBuilder = lexicon.LexBuilder;
const bitsOfCount = lexicon.bitsOfCount;
const explenOf = lexicon.explenOf;
const Calib = lexicon.Calib;

pub const Opts = struct {
    max_material_len: u32 = 256,
    calib: Calib = .{},
};

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

const PairCand = struct { key: u64, score: f64 };
fn pairCandDesc(_: void, x: PairCand, y: PairCand) bool {
    if (x.score != y.score) return x.score > y.score;
    return x.key < y.key;
}

/// Returns the number of new pair-entries accepted this round.
pub fn proposePairs(alloc: std.mem.Allocator, corpus: *Corpus, opts: Opts) !usize {
    const rc = try lexicon.recount(alloc, corpus);
    const mf: f64 = @floatFromInt(rc.m);

    var tally = std.AutoHashMap(u64, u64).init(alloc);
    {
        var start: usize = 0;
        for (corpus.block_end) |end| {
            var i = start;
            var skip_at: usize = std.math.maxInt(usize);
            while (i + 1 < end) : (i += 1) {
                const a = corpus.seq[i];
                const b = corpus.seq[i + 1];
                if (a == b and skip_at == i) continue;
                if (a == b) skip_at = i + 1;
                const key = (@as(u64, a) << 32) | b;
                const gop = try tally.getOrPut(key);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
            start = end;
        }
        for (0..corpus.lex.numEntries()) |i| {
            const cs = corpus.lex.comps(i);
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
    for (0..corpus.lex.numEntries()) |i| {
        const cs = corpus.lex.comps(i);
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
        const score = cf * (bits_a + bits_b - bits_new) - (bits_a + bits_b + opts.calib.entry_bits);
        if (score > 0) try cands.append(alloc, .{ .key = key, .score = score });
    }
    std.mem.sort(PairCand, cands.items, {}, pairCandDesc);

    const old_num_entries = corpus.lex.numEntries();
    const k = 256 + old_num_entries;
    const roles = try alloc.alloc(u8, k);
    @memset(roles, 0);

    var applied = std.AutoHashMap(u64, u32).init(alloc);
    var explen_new_list: std.ArrayList(u32) = .empty;
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
        try explen_new_list.append(alloc, explenOf(&corpus.lex, a) + explenOf(&corpus.lex, b));
        next_id += 1;
    }
    if (accepted_keys.items.len == 0) return 0;

    var builder = try LexBuilder.init(alloc);
    for (0..old_num_entries) |i| {
        var newcomps: std.ArrayList(u32) = .empty;
        try substitutePairs(alloc, corpus.lex.comps(i), &applied, &newcomps);
        _ = try builder.addEntry(alloc, newcomps.items, corpus.lex.explen.items[i]);
    }
    for (accepted_keys.items, 0..) |key, idx| {
        const a: u32 = @intCast(key >> 32);
        const b: u32 = @truncate(key);
        _ = try builder.addEntry(alloc, &.{ a, b }, explen_new_list.items[idx]);
    }

    var new_seq: std.ArrayList(u32) = .empty;
    var new_block_end: std.ArrayList(usize) = .empty;
    var start: usize = 0;
    for (corpus.block_end) |end| {
        try substitutePairs(alloc, corpus.seq[start..end], &applied, &new_seq);
        try new_block_end.append(alloc, new_seq.items.len);
        start = end;
    }

    corpus.lex = builder.finish();
    corpus.seq = try new_seq.toOwnedSlice(alloc);
    corpus.block_end = try new_block_end.toOwnedSlice(alloc);
    return accepted_keys.items.len;
}

const TripleCand = struct { key: Triple, score: f64 };
fn tripleCandDesc(_: void, x: TripleCand, y: TripleCand) bool {
    return x.score > y.score;
}

/// Same idea as `proposePairs` but over 3-wide windows; role-consistency is
/// simpler here (any symbol used by an accepted triple this round is fully
/// excluded from every other candidate this round).
pub fn proposeTriples(alloc: std.mem.Allocator, corpus: *Corpus, opts: Opts) !usize {
    const rc = try lexicon.recount(alloc, corpus);
    const mf: f64 = @floatFromInt(rc.m);

    var tally = std.AutoHashMap(Triple, u64).init(alloc);
    {
        var start: usize = 0;
        for (corpus.block_end) |end| {
            var i = start;
            while (i + 2 < end) : (i += 1) {
                const key = Triple{ .a = corpus.seq[i], .b = corpus.seq[i + 1], .c = corpus.seq[i + 2] };
                const gop = try tally.getOrPut(key);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
            start = end;
        }
        for (0..corpus.lex.numEntries()) |ei| {
            const cs = corpus.lex.comps(ei);
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
    for (0..corpus.lex.numEntries()) |i| {
        const cs = corpus.lex.comps(i);
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
        const score = cf * (bits_a + bits_b + bits_c - bits_new) - (bits_a + bits_b + bits_c + opts.calib.entry_bits);
        if (score > 0) try cands.append(alloc, .{ .key = key, .score = score });
    }
    std.mem.sort(TripleCand, cands.items, {}, tripleCandDesc);

    const old_num_entries = corpus.lex.numEntries();
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
        try explen_new_list.append(alloc, explenOf(&corpus.lex, key.a) + explenOf(&corpus.lex, key.b) + explenOf(&corpus.lex, key.c));
        next_id += 1;
    }
    if (accepted.items.len == 0) return 0;

    var builder = try LexBuilder.init(alloc);
    for (0..old_num_entries) |i| {
        var newcomps: std.ArrayList(u32) = .empty;
        try substituteTriples(alloc, corpus.lex.comps(i), &applied, &newcomps);
        _ = try builder.addEntry(alloc, newcomps.items, corpus.lex.explen.items[i]);
    }
    for (accepted.items, 0..) |key, idx| {
        _ = try builder.addEntry(alloc, &.{ key.a, key.b, key.c }, explen_new_list.items[idx]);
    }

    var new_seq: std.ArrayList(u32) = .empty;
    var new_block_end: std.ArrayList(usize) = .empty;
    var start: usize = 0;
    for (corpus.block_end) |end| {
        try substituteTriples(alloc, corpus.seq[start..end], &applied, &new_seq);
        try new_block_end.append(alloc, new_seq.items.len);
        start = end;
    }

    corpus.lex = builder.finish();
    corpus.seq = try new_seq.toOwnedSlice(alloc);
    corpus.block_end = try new_block_end.toOwnedSlice(alloc);
    return accepted.items.len;
}

test "proposePairs merges a clearly-repeated pair" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const raw = "abcabcabcabc abcabcabc xyzxyzxyz abcabc";
    var corpus = try lexicon.seedBytes(a, raw, 4096);
    const n = try proposePairs(a, &corpus, .{});
    try std.testing.expect(n > 0);
    try std.testing.expect(try lexicon.verifyExact(a, raw, &corpus));
}
