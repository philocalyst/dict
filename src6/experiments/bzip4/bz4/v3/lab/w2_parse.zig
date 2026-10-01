//! w2_parse DATA OUT
//!
//! A word-aligned parse learner, priced by the real codec instead of a raw
//! merge-count threshold. The input is cut into atoms the data delimits
//! itself (`w_parse.zig`'s scheme, unchanged: maximal letter runs with bytes
//! >= 0x80 counted as letters, maximal digit runs, every other byte alone),
//! a new word may start as a recent one does (front coding), and two greedy
//! pair-grammars grow over that: a spelling grammar (BPE over the distinct
//! atoms) and a phrase grammar (Re-Pair over the atom stream, fenced at
//! block boundaries). None of this is text-specific and none of it is the
//! part this file adds.
//!
//! What this file adds is real-price pruning: bytes, morphs, words and
//! phrases all become entries of one `bz4.Parse`, planned and encoded with
//! the same baseline planner and class model the real codec scores with,
//! and every entry whose *measured* bucket cost does not pay for its
//! definition is dissolved back into its body (`bz4.plan.prune`) and the
//! parse is re-priced. Greedy count thresholds only decide what is
//! *proposed*; real bits decide what survives. This is what LANE_O.md and
//! LANE_L.md both found missing from a pure order-0 or count-threshold
//! learner: under a class model, over-merging fragments the statistics a
//! deeper lexicon needs, and only real prices see that.
//!
//! One hazard this file works around rather than special-cases: an entry
//! that some other entry's body cuts (`[..., ref, CUT n, ...]`) must never
//! be dissolved, because splicing its own children in ref's place would
//! change what "the first n bytes of the child before" means (the child
//! before a spliced-in CUT is no longer the same span). Entries are
//! protected from `plan.prune` by reporting zero uses for them; entries
//! that contain a CUT of their own are already protected by `plan.prune`
//! itself (it never prices a body it cannot fully price).
//!
//! Separator placement (a space glued to the word before it, after it, or
//! standing alone) is not special-cased either: the phrase grammar is free
//! to merge a word with an adjacent space like any other pair, and pruning
//! keeps the merge only where it actually pays. Whichever placement wins
//! falls out of the same generic loop.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bz4 = @import("bz4");

const Kind = enum { letter, digit, other };

fn kind(byte: u8) Kind {
    return if (std.ascii.isAlphabetic(byte) or byte >= 0x80) .letter else if (std.ascii.isDigit(byte)) .digit else .other;
}

const Rule = struct { left: u32, right: u32 };
const fence = 0x8000_0000; // ids from here up never merge

/// Grows `rules` by merging adjacent pairs of `seq` that occur at least
/// `least` times, most frequent first, and rewrites `seq` in place. Generic
/// over what `seq` holds (raw atom bytes for the spelling grammar, whole
/// atoms for the phrase grammar): merging is just "pairs that recur", never
/// text-specific.
fn grow(gpa: Allocator, seq: *std.ArrayList(u32), rules: *std.ArrayList(Rule), first_id: u32, least: u32) !void {
    var counts: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer counts.deinit(gpa);
    var chosen: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer chosen.deinit(gpa);
    while (true) {
        counts.clearRetainingCapacity();
        const items = seq.items;
        var most: u32 = 0;
        var i: usize = 0;
        while (i + 1 < items.len) : (i += 1) {
            if (items[i] >= fence or items[i + 1] >= fence) continue;
            const slot = try counts.getOrPutValue(gpa, @as(u64, items[i]) << 32 | items[i + 1], 0);
            slot.value_ptr.* += 1;
            most = @max(most, slot.value_ptr.*);
            // A run "aaa" holds one pair, not two.
            if (items[i] == items[i + 1] and i + 2 < items.len and items[i + 2] == items[i]) i += 1;
        }
        if (most < least) return;

        // Everything within a factor of two of the best pair merges this round.
        const bar = @max(least, most / 2 + 1);
        chosen.clearRetainingCapacity();
        var it = counts.iterator();
        while (it.next()) |kv| if (kv.value_ptr.* >= bar) {
            try chosen.put(gpa, kv.key_ptr.*, first_id + @as(u32, @intCast(rules.items.len)));
            try rules.append(gpa, .{ .left = @intCast(kv.key_ptr.* >> 32), .right = @truncate(kv.key_ptr.*) });
        };
        var out: usize = 0;
        i = 0;
        while (i < items.len) {
            if (i + 1 < items.len) if (chosen.get(@as(u64, items[i]) << 32 | items[i + 1])) |id| {
                items[out] = id;
                out += 1;
                i += 2;
                continue;
            };
            items[out] = items[i];
            out += 1;
            i += 1;
        }
        seq.items.len = out;
    }
}

// Proposal thresholds: how generous the greedy grammars are allowed to be
// before real prices get a say. Kept a little more generous than a
// count-threshold-only learner would dare, because over-proposing and
// pruning at real prices beats under-proposing (LANE_L.md, LANE_O.md).
const morph_least = 3;
const phrase_least = 4;
const share_window = 32; // recent new word types considered as a CUT source
const least_shared = 6; // minimum shared prefix worth a CUT
const block_bytes = 65536;
const price_classes = 64; // must match the score the parse is judged by
const prune_rounds = 40;
const prune_overhead = 10; // bits a definition adds to its body (DEF+ARITY+NAME, ~)

/// Marks every entry that some body cuts (`[..., e, CUT n, ...]`): these
/// must survive pruning intact, or the CUT's "first n bytes of the child
/// before" would start meaning something else. Scanned per body, not over
/// the flat kid array, so a body boundary can never look like an adjacency.
fn protectCutSources(gpa: Allocator, parse: bz4.Parse) ![]bool {
    const protect = try gpa.alloc(bool, parse.entries());
    @memset(protect, false);
    for (0..parse.entries()) |e| {
        const body = parse.body(e);
        if (body.len < 2) continue;
        for (body[1..], body[0 .. body.len - 1]) |kid, before| {
            if (kid >= bz4.Parse.cut and before >= 256 and before < bz4.Parse.cut) protect[before - 256] = true;
        }
    }
    return protect;
}

/// Prices every entry with a real plan+encode (class model included, byte
/// aliasing off so entry ids line up with `parse`) and dissolves whatever
/// does not pay, repeating while the real encoded size keeps shrinking.
/// `bz4.plan.prune`'s own gate is a *local* per-entry estimate (its body's
/// static price versus its measured bucket cost), which is not exactly the
/// same objective as the class-modelled total; LANE_L/LANE_O both found
/// local proxies overshoot, and it is confirmed here too (entry count keeps
/// falling for dozens of rounds, but real bytes stop falling and then climb
/// well before the count does) — so the real, measured size after each
/// round's prune is the stopping rule, not "entries stopped changing".
fn pricePrune(gpa: Allocator, start: bz4.Parse) !bz4.Parse {
    var parse = start;
    var best = start;
    var best_bytes: usize = std.math.maxInt(usize);
    for (0..prune_rounds) |_| {
        const pricing: bz4.plan.Options = .{ .classes = price_classes, .alias = false };
        var trial = try bz4.plan.baseline(gpa, parse, pricing);
        const entry_bits = try gpa.alloc(f64, trial.parse.entries());
        const entry_uses = try gpa.alloc(u32, trial.parse.entries());
        @memset(entry_bits, 0);
        @memset(entry_uses, 0);
        var stats: bz4.Stats = .{ .entry_bits = entry_bits, .entry_uses = entry_uses };
        const encoded = try bz4.encode(gpa, &trial, &stats);
        if (encoded.len >= best_bytes) break;
        best_bytes = encoded.len;
        best = parse;

        const protect = try protectCutSources(gpa, parse);
        for (protect, 0..) |p, e| if (p) {
            entry_uses[e] = 0;
        };

        const before = parse.entries();
        parse = try bz4.plan.prune(gpa, parse, entry_bits, entry_uses, prune_overhead);
        if (parse.entries() == before) break;
    }
    return best;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const data_path = args.next() orelse return error.Usage;
    const out_path = args.next() orelse return error.Usage;
    const cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAlloc(init.io, data_path, gpa, .limited(1 << 30));

    // Atoms, and the distinct ones in order of first appearance.
    var types: std.StringArrayHashMapUnmanaged(void) = .empty;
    var stream: std.ArrayList(u32) = .empty; // atom type index per atom
    var starts: std.ArrayList(u32) = .empty;
    var at: usize = 0;
    while (at < data.len) {
        var end = at + 1;
        if (kind(data[at]) != .other) while (end < data.len and kind(data[end]) == kind(data[at])) : (end += 1) {};
        const slot = try types.getOrPut(gpa, data[at..end]);
        try stream.append(gpa, @intCast(slot.index));
        try starts.append(gpa, @intCast(at));
        at = end;
    }

    // A new word may start as a recent new word does: the longest shared
    // prefix among the last `share_window` word types, if long enough.
    const cut: u32 = bz4.Parse.cut;
    const Shared = struct { source: u32 = 0, keep: u32 = 0 };
    const shared = try gpa.alloc(Shared, types.count());
    @memset(shared, .{});
    for (types.keys(), 0..) |text, t| {
        if (text.len < 2) continue;
        var back: usize = 1;
        while (back <= @min(share_window, t)) : (back += 1) {
            const other = types.keys()[t - back];
            if (other.len < 2) continue;
            const common = std.mem.indexOfDiff(u8, text, other) orelse @min(text.len, other.len);
            if (common >= least_shared and common > shared[t].keep) shared[t] = .{ .source = @intCast(t - back), .keep = @intCast(@min(common, 255)) };
        }
    }

    // Spelling grammar over what is left of the distinct atoms.
    var rules: std.ArrayList(Rule) = .empty;
    var spelling: std.ArrayList(u32) = .empty;
    for (types.keys(), shared, 0..) |text, sh, t| {
        for (text[sh.keep..]) |byte| try spelling.append(gpa, byte);
        try spelling.append(gpa, fence + @as(u32, @intCast(t)));
    }
    try grow(gpa, &spelling, &rules, 256, morph_least);
    const morphs = rules.items.len;

    // Every atom is now a byte, a morph, or a word made of those.
    const Body = struct { off: u32, len: u32 };
    var bodies: std.ArrayList(Body) = .empty;
    var word_kids: std.ArrayList(u32) = .empty;
    const atom_id = try gpa.alloc(u32, types.count());
    {
        var from: usize = 0;
        var t: usize = 0;
        for (spelling.items, 0..) |sym, i| if (sym >= fence) {
            const body = spelling.items[from..i];
            if (body.len == 1 and shared[t].keep == 0) atom_id[t] = body[0] else {
                atom_id[t] = fence - 1 - @as(u32, @intCast(bodies.items.len)); // word ids count down for now
                const off = word_kids.items.len;
                if (shared[t].keep != 0) {
                    // The source's id is patched in below, once words have theirs.
                    try word_kids.append(gpa, fence + shared[t].source);
                    if (shared[t].keep != types.keys()[shared[t].source].len) try word_kids.append(gpa, cut + shared[t].keep);
                }
                try word_kids.appendSlice(gpa, body);
                try bodies.append(gpa, .{ .off = @intCast(off), .len = @intCast(word_kids.items.len - off) });
            }
            from = i + 1;
            t += 1;
        };
    }
    const words = bodies.items.len;
    const word_base: u32 = @intCast(256 + morphs);
    for (atom_id) |*id| if (id.* >= 256 + morphs and id.* < fence) {
        id.* = word_base + (fence - 1 - id.*);
    };
    for (word_kids.items) |*kid| if (kid.* >= fence and kid.* < cut) {
        kid.* = atom_id[kid.* - fence];
    };

    // Phrase grammar over the atom stream, fenced at block boundaries.
    var seq: std.ArrayList(u32) = .empty;
    var next_cut: usize = block_bytes;
    var fences: u32 = 0;
    for (stream.items, starts.items) |t, start| {
        if (start >= next_cut) {
            try seq.append(gpa, fence + fences);
            fences += 1;
            next_cut += block_bytes;
        }
        try seq.append(gpa, atom_id[t]);
    }
    const phrase_base: u32 = @intCast(256 + morphs + words);
    var phrase_rules: std.ArrayList(Rule) = .empty;
    try grow(gpa, &seq, &phrase_rules, phrase_base, phrase_least);

    // One `bz4.Parse`: morph rules, then words, then phrase rules, in id order.
    var all_kids: std.ArrayList(u32) = .empty;
    var all_body_off: std.ArrayList(u32) = .empty;
    try all_body_off.append(gpa, 0);
    for (rules.items) |r| {
        try all_kids.appendSlice(gpa, &.{ r.left, r.right });
        try all_body_off.append(gpa, @intCast(all_kids.items.len));
    }
    for (bodies.items) |b| {
        try all_kids.appendSlice(gpa, word_kids.items[b.off..][0..b.len]);
        try all_body_off.append(gpa, @intCast(all_kids.items.len));
    }
    for (phrase_rules.items) |r| {
        try all_kids.appendSlice(gpa, &.{ r.left, r.right });
        try all_body_off.append(gpa, @intCast(all_kids.items.len));
    }

    var toks: std.ArrayList(u32) = .empty;
    var block_off: std.ArrayList(u32) = .empty;
    try block_off.append(gpa, 0);
    for (seq.items) |tok| {
        if (tok >= fence) {
            try block_off.append(gpa, @intCast(toks.items.len));
            continue;
        }
        try toks.append(gpa, tok);
    }
    try block_off.append(gpa, @intCast(toks.items.len));

    const built: bz4.Parse = .{ .body_off = all_body_off.items, .kids = all_kids.items, .block_off = block_off.items, .toks = toks.items };
    const entries_before = built.entries();
    const parse = try pricePrune(gpa, built);

    // Write the B4SD v2 dump.
    var out: std.ArrayList(u32) = .empty;
    try out.appendSlice(gpa, &.{ 0x44533442, 2, @intCast(parse.entries()), @intCast(parse.blocks()), block_bytes, @intCast(data.len) });
    for (0..parse.entries()) |e| {
        const body = parse.body(e);
        try out.append(gpa, @intCast(body.len));
        try out.appendSlice(gpa, body);
    }
    for (0..parse.blocks()) |b| {
        const blk = parse.block(b);
        try out.append(gpa, @intCast(blk.len));
        try out.appendSlice(gpa, blk);
    }
    try cwd.writeFile(init.io, .{ .sub_path = out_path, .data = std.mem.sliceAsBytes(out.items) });

    var tokens: usize = 0;
    for (0..parse.blocks()) |b| tokens += parse.block(b).len;
    std.debug.print("{s}: atoms={d} types={d} morphs={d} words={d} phrases={d} entries={d}->{d} tokens={d} ({d:.2} bytes/token) blocks={d}\n", .{
        data_path, stream.items.len,                                                             types.count(),  morphs, words, phrase_rules.items.len, entries_before, parse.entries(),
        tokens,    @as(f64, @floatFromInt(data.len)) / @as(f64, @floatFromInt(@max(tokens, 1))), parse.blocks(),
    });
}
