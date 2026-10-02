//! The learner: from bytes to a word-aligned parse.
//!
//! The input is cut into atoms the data delimits itself: maximal runs of
//! letters (bytes >= 0x80 count as letters, so any script works; cutting
//! scripts without spaces into single characters was tried and lost),
//! maximal runs of digits, and every other byte alone. Two grammars are
//! then grown with the same pair-merging loop:
//!
//!   spelling  over the distinct atoms, each spelled once: pairs of bytes
//!             and morphs that recur across word types become morphs;
//!   phrases   over the atom stream: pairs of whole atoms and phrases.
//!
//! A payload token is therefore always a whole number of words; sub-word
//! structure exists only inside definitions. A new word that starts like one
//! of the last few new words is spelled as a cut of it plus a suffix, which
//! in a sorted word list is front coding.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Parse = @import("encode.zig").Parse;

pub const Options = struct {
    /// Occurrences a pair needs to become a phrase, or a morph.
    phrase: u32 = 4,
    morph: u32 = 3,
    /// How many new word types back a shared prefix is looked for.
    share: usize = 32,
    /// Spell a word that occurs once where it stands, rather than define
    /// it: no ARITY and NAME, but its morphs then sit among the words.
    /// `compress` tries both.
    once_in_place: bool = true,
    block: usize = 1 << 16,
};

const Kind = enum { letter, digit, other };

fn kind(byte: u8) Kind {
    return if (std.ascii.isAlphabetic(byte) or byte >= 0x80) .letter else if (std.ascii.isDigit(byte)) .digit else .other;
}

/// The end of the atom that starts at `at`.
fn atomEnd(data: []const u8, at: usize) usize {
    var end = at + 1;
    if (kind(data[at]) != .other) while (end < data.len and kind(data[end]) == kind(data[at])) : (end += 1) {};
    return end;
}

/// Sequence symbols from here up are fences: they never merge.
const fence = 0x8000_0000;

/// Every entry's body, in order of creation; entry `e` has id `256 + e`.
const Lexicon = struct {
    off: std.ArrayList(u32) = .empty,
    kids: std.ArrayList(u32) = .empty,

    fn add(lex: *Lexicon, gpa: Allocator, children: []const u32) !u32 {
        if (lex.off.items.len == 0) try lex.off.append(gpa, 0);
        try lex.kids.appendSlice(gpa, children);
        try lex.off.append(gpa, @intCast(lex.kids.items.len));
        return @intCast(256 + lex.off.items.len - 2);
    }

    fn count(lex: *const Lexicon) usize {
        return lex.off.items.len -| 1;
    }

    fn body(lex: *const Lexicon, e: usize) []const u32 {
        return lex.kids.items[lex.off.items[e]..lex.off.items[e + 1]];
    }
};

/// Merges adjacent pairs of `seq` that occur at least `least` times, the
/// most frequent first, until none is left; rewrites `seq` in place.
fn grow(gpa: Allocator, seq: *std.ArrayList(u32), lex: *Lexicon, least: u32) !void {
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
            try chosen.put(gpa, kv.key_ptr.*, try lex.add(gpa, &.{ @intCast(kv.key_ptr.* >> 32), @truncate(kv.key_ptr.*) }));
        };
        var out: usize = 0;
        i = 0;
        while (i < items.len) : (out += 1) {
            const merged = if (i + 1 < items.len) chosen.get(@as(u64, items[i]) << 32 | items[i + 1]) else null;
            items[out] = merged orelse items[i];
            i += if (merged == null) 1 else 2;
        }
        seq.items.len = out;
    }
}

/// All memory of the result, and all scratch memory, comes from `arena`.
pub fn learn(arena: Allocator, data: []const u8, options: Options) !Parse {
    // Atoms, and the distinct ones in order of first appearance.
    var types: std.StringArrayHashMapUnmanaged(void) = .empty;
    var stream: std.ArrayList(u32) = .empty;
    var starts: std.ArrayList(u32) = .empty;
    var at: usize = 0;
    while (at < data.len) {
        const end = atomEnd(data, at);
        try stream.append(arena, @intCast((try types.getOrPut(arena, data[at..end])).index));
        try starts.append(arena, @intCast(at));
        at = end;
    }
    const texts = types.keys();

    // A new word may start as a recent new word does. Sharing saves about
    // four bits a byte and costs a cut plus a look back, which is dearer the
    // further back the source is: the previous word pays from three bytes
    // on, one twenty words back from six.
    const Shared = struct { source: u32 = 0, keep: u32 = 0 };
    const shared = try arena.alloc(Shared, texts.len);
    @memset(shared, .{});
    for (texts, shared, 0..) |text, *sh, t| {
        if (text.len < 2) continue;
        var best: f32 = 0;
        for (1..@min(options.share, t) + 1) |back| {
            const other = texts[t - back];
            const common = @min(255, std.mem.indexOfDiff(u8, text, other) orelse @min(text.len, other.len));
            const gain = 4 * @as(f32, @floatFromInt(common)) - 5 - 2 * @log2(@as(f32, @floatFromInt(1 + 4 * back)));
            if (other.len >= 2 and gain > best) {
                best = gain;
                sh.* = .{ .source = @intCast(t - back), .keep = @intCast(common) };
            }
        }
    }

    // The spelling grammar, over what is left of each word type.
    var lex: Lexicon = .{};
    var spelling: std.ArrayList(u32) = .empty;
    for (texts, shared, 0..) |text, sh, t| {
        for (text[sh.keep..]) |byte| try spelling.append(arena, byte);
        try spelling.append(arena, fence + @as(u32, @intCast(t)));
    }
    try grow(arena, &spelling, &lex, options.morph);

    // Every atom is now a byte, a morph, or a word made of those.
    const atom = try arena.alloc(u32, texts.len);
    var word: std.ArrayList(u32) = .empty;
    var from: usize = 0;
    for (spelling.items, 0..) |sym, i| if (sym >= fence) {
        const t = sym - fence;
        word.clearRetainingCapacity();
        if (shared[t].keep != 0) {
            try word.append(arena, atom[shared[t].source]);
            if (shared[t].keep != texts[shared[t].source].len) try word.append(arena, Parse.cut + shared[t].keep);
        }
        try word.appendSlice(arena, spelling.items[from..i]);
        atom[t] = if (word.items.len == 1) word.items[0] else try lex.add(arena, word.items);
        from = i + 1;
    };

    // The phrase grammar, over the atom stream fenced at block boundaries.
    var seq: std.ArrayList(u32) = .empty;
    var fences: u32 = 0;
    for (stream.items, starts.items) |t, start| {
        if (start >= (fences + 1) * options.block) {
            try seq.append(arena, fence + fences);
            fences += 1;
        }
        try seq.append(arena, atom[t]);
    }
    try grow(arena, &seq, &lex, options.phrase);

    // An entry referenced once dissolves into whatever refers to it: a
    // word seen once is spelled where it stands. A body with a cut stays
    // whole (the payload has no cuts), and so does the source of a cut.
    const n = lex.count();
    const refs = try arena.alloc(u32, n);
    const keep = try arena.alloc(bool, n);
    @memset(refs, 0);
    for (lex.kids.items) |kid| if (kid >= 256 and kid < Parse.cut) {
        refs[kid - 256] += 1;
    };
    for (seq.items) |tok| if (tok >= 256 and tok < fence) {
        refs[tok - 256] += if (options.once_in_place) 1 else 2;
    };
    for (refs, keep) |r, *k| k.* = r >= 2;
    for (0..n) |e| for (lex.body(e), 0..) |kid, i| if (kid >= Parse.cut) {
        keep[e] = true;
        if (lex.body(e)[i - 1] >= 256) keep[lex.body(e)[i - 1] - 256] = true;
    };
    const id = try arena.alloc(u32, n);
    var kept: u32 = 0;
    for (keep, id) |k, *to| {
        to.* = 256 + kept;
        kept += @intFromBool(k);
    }
    const Flat = struct {
        arena: Allocator,
        lex: *const Lexicon,
        keep: []const bool,
        id: []const u32,
        fn expand(f: @This(), sym: u32, into: *std.ArrayList(u32)) !void {
            if (sym < 256 or sym >= Parse.cut) return into.append(f.arena, sym);
            if (f.keep[sym - 256]) return into.append(f.arena, f.id[sym - 256]);
            for (f.lex.body(sym - 256)) |kid| try f.expand(kid, into);
        }
    };
    const flat: Flat = .{ .arena = arena, .lex = &lex, .keep = keep, .id = id };

    var kids: std.ArrayList(u32) = .empty;
    var body_off: std.ArrayList(u32) = .empty;
    try body_off.append(arena, 0);
    for (0..n) |e| if (keep[e]) {
        for (lex.body(e)) |kid| try flat.expand(kid, &kids);
        try body_off.append(arena, @intCast(kids.items.len));
    };
    var toks: std.ArrayList(u32) = .empty;
    var block_off: std.ArrayList(u32) = .empty;
    try block_off.append(arena, 0);
    for (seq.items) |tok| {
        if (tok >= fence) try block_off.append(arena, @intCast(toks.items.len)) else try flat.expand(tok, &toks);
    }
    try block_off.append(arena, @intCast(toks.items.len));
    return .{ .body_off = body_off.items, .kids = kids.items, .block_off = block_off.items, .toks = toks.items };
}
