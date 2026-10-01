//! w_parse DATA OUT [--phrase N] [--morph N] [--block BYTES]
//!
//! A word-aligned parse. The input is cut into atoms the data delimits
//! itself: maximal runs of letters (bytes >= 0x80 count as letters), maximal
//! runs of digits, and every other byte alone. Two grammars are then grown
//! with the same pair-merging loop:
//!
//!   spelling  over the distinct atoms, each spelled once: pairs of bytes
//!             and morphs that recur across word types become morphs;
//!   phrases   over the atom stream: pairs of whole atoms and phrases.
//!
//! A payload token is therefore always a whole number of words; sub-word
//! structure exists only inside definitions. A new word that starts like one
//! of the last few new words is spelled as a cut of it plus a suffix (front
//! coding falls out of this for sorted word lists). Writes a B4SD v2 dump.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Kind = enum { letter, digit, other };

fn kind(byte: u8) Kind {
    return if (std.ascii.isAlphabetic(byte) or byte >= 0x80) .letter else if (std.ascii.isDigit(byte)) .digit else .other;
}

const Rule = struct { left: u32, right: u32 };
const fence = 0x8000_0000; // ids from here up never merge

/// Grows `rules` by merging adjacent pairs of `seq` that occur at least
/// `least` times, most frequent first, and rewrites `seq` in place.
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

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const data_path = args.next() orelse return error.Usage;
    const out_path = args.next() orelse return error.Usage;
    var phrase_least: u32 = 4;
    var morph_least: u32 = 4;
    var block_bytes: usize = 65536;
    var inline_hapax = false;
    var share: usize = 32;
    var least_shared: usize = 3;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--phrase")) phrase_least = try std.fmt.parseUnsigned(u32, args.next() orelse return error.Usage, 10);
        if (std.mem.eql(u8, arg, "--morph")) morph_least = try std.fmt.parseUnsigned(u32, args.next() orelse return error.Usage, 10);
        if (std.mem.eql(u8, arg, "--block")) block_bytes = try std.fmt.parseUnsigned(usize, args.next() orelse return error.Usage, 10);
        if (std.mem.eql(u8, arg, "--inline-hapax")) inline_hapax = true;
        if (std.mem.eql(u8, arg, "--share")) share = try std.fmt.parseUnsigned(usize, args.next() orelse return error.Usage, 10);
        if (std.mem.eql(u8, arg, "--lcp")) least_shared = try std.fmt.parseUnsigned(usize, args.next() orelse return error.Usage, 10);
    }
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
    // prefix among the last `share` word types, if it is long enough.
    const cut: u32 = 0xffff_ff00;
    const Shared = struct { source: u32 = 0, keep: u32 = 0 };
    const shared = try gpa.alloc(Shared, types.count());
    @memset(shared, .{});
    var cuts: usize = 0;
    var saved: usize = 0;
    if (share != 0) for (types.keys(), 0..) |text, t| {
        if (text.len < 2) continue;
        var back: usize = 1;
        while (back <= @min(share, t)) : (back += 1) {
            const other = types.keys()[t - back];
            if (other.len < 2) continue;
            const common = std.mem.indexOfDiff(u8, text, other) orelse @min(text.len, other.len);
            if (common >= least_shared and common > shared[t].keep) shared[t] = .{ .source = @intCast(t - back), .keep = @intCast(@min(common, 255)) };
        }
        cuts += @intFromBool(shared[t].keep != 0);
        saved += shared[t].keep;
    };

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
    var bodies: std.ArrayList(Body) = .empty; // of words and, later, flattened rules
    var kids: std.ArrayList(u32) = .empty;
    const atom_id = try gpa.alloc(u32, types.count());
    {
        var from: usize = 0;
        var t: usize = 0;
        for (spelling.items, 0..) |sym, i| if (sym >= fence) {
            const body = spelling.items[from..i];
            if (body.len == 1 and shared[t].keep == 0) atom_id[t] = body[0] else {
                atom_id[t] = fence - 1 - @as(u32, @intCast(bodies.items.len)); // word ids count down for now
                const off = kids.items.len;
                if (shared[t].keep != 0) {
                    // The source's id is patched in below, once words have theirs.
                    try kids.append(gpa, fence + shared[t].source);
                    if (shared[t].keep != types.keys()[shared[t].source].len) try kids.append(gpa, cut + shared[t].keep);
                }
                try kids.appendSlice(gpa, body);
                try bodies.append(gpa, .{ .off = @intCast(off), .len = @intCast(kids.items.len - off) });
            }
            from = i + 1;
            t += 1;
        };
    }
    const words = bodies.items.len;
    // Final ids: 256.. morph rules, then words, then phrase rules.
    const word_base: u32 = @intCast(256 + morphs);
    for (atom_id) |*id| if (id.* >= 256 + morphs and id.* < fence) {
        id.* = word_base + (fence - 1 - id.*);
    };
    for (kids.items) |*kid| if (kid.* >= fence and kid.* < cut) {
        kid.* = atom_id[kid.* - fence];
    };

    // Phrase grammar over the atom stream, fenced at block boundaries.
    var seq: std.ArrayList(u32) = .empty;
    var next_cut = block_bytes;
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

    // One table of entries: morph rules, words, phrase rules. Flatten: an
    // entry that is referenced exactly once, from a body, dissolves into it.
    const total = morphs + words + phrase_rules.items.len;
    const refs = try gpa.alloc(u32, total);
    const top_refs = try gpa.alloc(u32, total);
    @memset(refs, 0);
    @memset(top_refs, 0);
    const Entry = struct {
        fn body(e: usize, m: usize, w: usize, r: []const Rule, pr: []const Rule, b: []const Body, k: []const u32, pair: *[2]u32) []const u32 {
            if (e < m) {
                pair.* = .{ r[e].left, r[e].right };
                return pair;
            }
            if (e < m + w) return k[b[e - m].off..][0..b[e - m].len];
            pair.* = .{ pr[e - m - w].left, pr[e - m - w].right };
            return pair;
        }
    };
    var pair: [2]u32 = undefined;
    for (0..total) |e| for (Entry.body(e, morphs, words, rules.items, phrase_rules.items, bodies.items, kids.items, &pair)) |kid| {
        if (kid >= 256 and kid < cut) refs[kid - 256] += 1;
    };
    for (seq.items) |tok| if (tok >= 256 and tok < fence) {
        top_refs[tok - 256] += 1;
    };

    // Expand bodies depth-first, dissolving single-use children.
    const keep = try gpa.alloc(bool, total);
    for (keep, refs, top_refs) |*k, r, t| k.* = r + t >= 2 or (t == 1 and r == 0 and !inline_hapax);
    // The source of a cut must stay one token.
    for (kids.items[1..], kids.items[0 .. kids.items.len - 1]) |kid, before| {
        if (kid >= cut and before >= 256) keep[before - 256] = true;
    }
    const new_id = try gpa.alloc(u32, total);
    var kept: u32 = 0;
    for (keep, new_id) |k, *id| if (k) {
        id.* = 256 + kept;
        kept += 1;
    };
    var out: std.ArrayList(u32) = .empty;
    try out.appendSlice(gpa, &.{ 0x44533442, 2, kept, 0, @intCast(block_bytes), @intCast(data.len) });
    const Flat = struct {
        gpa: Allocator,
        morphs: usize,
        words: usize,
        rules: []const Rule,
        phrase_rules: []const Rule,
        bodies: []const Body,
        kids: []const u32,
        keep: []const bool,
        new_id: []const u32,
        fn expand(f: @This(), sym: u32, into: *std.ArrayList(u32)) !void {
            if (sym < 256 or sym >= 0xffff_ff00) return into.append(f.gpa, sym);
            if (f.keep[sym - 256]) return into.append(f.gpa, f.new_id[sym - 256]);
            var p: [2]u32 = undefined;
            for (Entry.body(sym - 256, f.morphs, f.words, f.rules, f.phrase_rules, f.bodies, f.kids, &p)) |kid| try f.expand(kid, into);
        }
    };
    const flat: Flat = .{ .gpa = gpa, .morphs = morphs, .words = words, .rules = rules.items, .phrase_rules = phrase_rules.items, .bodies = bodies.items, .kids = kids.items, .keep = keep, .new_id = new_id };
    var body: std.ArrayList(u32) = .empty;
    var arity_sum: usize = 0;
    for (0..total) |e| if (keep[e]) {
        body.clearRetainingCapacity();
        for (Entry.body(e, morphs, words, rules.items, phrase_rules.items, bodies.items, kids.items, &pair)) |kid| try flat.expand(kid, &body);
        try out.append(gpa, @intCast(body.items.len));
        try out.appendSlice(gpa, body.items);
        arity_sum += body.items.len;
    };

    // Blocks: the fences cut the stream.
    var blocks: u32 = 0;
    var tokens: usize = 0;
    var count_at = out.items.len;
    try out.append(gpa, 0);
    blocks += 1;
    for (seq.items) |tok| {
        if (tok >= fence) {
            count_at = out.items.len;
            try out.append(gpa, 0);
            blocks += 1;
            continue;
        }
        const before = out.items.len;
        try flat.expand(tok, &out);
        out.items[count_at] += @intCast(out.items.len - before);
        tokens += out.items.len - before;
    }
    out.items[3] = blocks;
    try cwd.writeFile(init.io, .{ .sub_path = out_path, .data = std.mem.sliceAsBytes(out.items) });
    std.debug.print("cuts={d} bytes_shared={d} ", .{ cuts, saved });
    std.debug.print("{s}: atoms={d} types={d} morphs={d} words={d} phrases={d} entries={d} (mean arity {d:.2}) tokens={d} ({d:.2} bytes/token) blocks={d}\n", .{
        data_path, stream.items.len, types.count(), morphs, words, phrase_rules.items.len, kept,
        @as(f64, @floatFromInt(arity_sum)) / @as(f64, @floatFromInt(@max(kept, 1))),
        tokens, @as(f64, @floatFromInt(data.len)) / @as(f64, @floatFromInt(tokens)), blocks,
    });
}
