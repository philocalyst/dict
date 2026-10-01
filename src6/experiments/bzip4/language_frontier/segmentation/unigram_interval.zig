//! Bounded, deterministic unigram + interval segmentation prototype.
//!
//! This file intentionally lives outside bz4/v3/src.  It emits the existing
//! bz4.Parse shape and prices it with the existing static codec.  The learner
//! has no language tables, Unicode library, or external tokenizer: input is
//! bytes, and the only atom fences are the same byte-kind runs used by
//! learn.zig.  `lex` is a candidate unigram inventory re-estimated by
//! Viterbi; `phrase` is a weighted interval parse over repeated atom n-grams;
//! `both` composes both stages.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bz4 = @import("bz4");
const Parse = bz4.Parse;

const inf: f64 = 1.0e300;
const no_piece: u32 = std.math.maxInt(u32);

const Options = struct {
    mode: Mode = .both,
    block: usize = 1 << 16,
    max_piece: usize = 12,
    max_phrase: usize = 6,
    min_piece_occ: u32 = 3,
    min_phrase_occ: u32 = 3,
    max_pieces: usize = 16_384,
    max_phrases: usize = 8_192,
    rounds: usize = 5,
    /// Approximate charged v4 definition/model cost used only while choosing
    /// a parse.  Final selection is always the complete encoded frame.
    piece_tax: f64 = 28.0,
    phrase_tax: f64 = 30.0,
    spelling_bit: f64 = 4.0,
    verbose: bool = true,
};

const Mode = enum { raw, lex, phrase, both };

const Kind = enum { letter, digit, other };

fn kind(byte: u8) Kind {
    // Match v4 exactly.  In particular, every byte >= 0x80 is data in a
    // letter run; this does not validate, normalize, or decode UTF-8.
    return if (std.ascii.isAlphabetic(byte) or byte >= 0x80) .letter else if (std.ascii.isDigit(byte)) .digit else .other;
}

fn atomEnd(data: []const u8, at: usize) usize {
    var end = at + 1;
    if (kind(data[at]) != .other) while (end < data.len and kind(data[end]) == kind(data[at])) : (end += 1) {};
    return end;
}

const Seg = struct {
    piece: u32 = no_piece,
    byte: u8 = 0,
};

const Candidate = struct {
    text: []const u8,
    occurrences: u32 = 0,
    selected: u32 = 0,
    active: bool = false,
};

const NKey = struct {
    len: u8 = 0,
    ids: [8]u32 = @splat(0),
};

const PhraseCandidate = struct {
    key: NKey,
    occurrences: u32 = 0,
    selected: u32 = 0,
};

const StartRef = struct { first: u32, candidate: u32 };

const Atoms = struct {
    types: std.StringArrayHashMapUnmanaged(void) = .empty,
    stream: std.ArrayList(u32) = .empty,
    starts: std.ArrayList(u32) = .empty,
    frequencies: std.ArrayList(u32) = .empty,

    fn build(arena: Allocator, data: []const u8) !Atoms {
        var out: Atoms = .{};
        var at: usize = 0;
        while (at < data.len) {
            const end = atomEnd(data, at);
            const slot = try out.types.getOrPut(arena, data[at..end]);
            if (slot.found_existing) {
                out.frequencies.items[slot.index] += 1;
            } else {
                try out.frequencies.append(arena, 1);
            }
            try out.stream.append(arena, @intCast(slot.index));
            try out.starts.append(arena, @intCast(at));
            at = end;
        }
        return out;
    }

    fn text(a: *const Atoms, t: usize) []const u8 {
        return a.types.keys()[t];
    }
};

const Learner = struct {
    arena: Allocator,
    data: []const u8,
    atoms: Atoms,
    options: Options,
    candidates: std.ArrayList(Candidate) = .empty,
    // Flattened Viterbi paths, one span array per atom type.
    path_off: std.ArrayList(u32) = .empty,
    paths: std.ArrayList(Seg) = .empty,
    chosen_active: []bool = &.{},

    fn init(arena: Allocator, data: []const u8, options: Options) !Learner {
        return .{ .arena = arena, .data = data, .atoms = try Atoms.build(arena, data), .options = options };
    }

    fn isEligible(a: *const Atoms, t: usize) bool {
        const text = a.text(t);
        return text.len >= 2 and kind(text[0]) != .other;
    }

    fn gatherCandidates(l: *Learner) !void {
        var map: std.StringArrayHashMapUnmanaged(u32) = .empty;
        for (l.atoms.types.keys(), 0..) |text, t| {
            if (!isEligible(&l.atoms, t)) continue;
            const max_len = @min(l.options.max_piece, text.len);
            for (0..text.len) |start| {
                const last = @min(text.len, start + max_len);
                var end = start + 2;
                while (end <= last) : (end += 1) {
                    const piece = text[start..end];
                    const slot = try map.getOrPut(l.arena, piece);
                    var c: *Candidate = undefined;
                    if (slot.found_existing) {
                        c = &l.candidates.items[slot.value_ptr.*];
                    } else {
                        const index: u32 = @intCast(l.candidates.items.len);
                        slot.value_ptr.* = index;
                        try l.candidates.append(l.arena, .{ .text = piece });
                        c = &l.candidates.items[index];
                    }
                    // Occurrences are weighted by occurrences of the atom
                    // type in the stream.  This is the unigram evidence; it
                    // does not inspect a language or Unicode category.
                    c.occurrences +|= l.atoms.frequencies.items[t];
                }
            }
        }

        // One fixed policy bounds the candidate forest.  The score rewards a
        // reusable byte span but penalizes long pieces; ties are first-seen.
        std.mem.sort(Candidate, l.candidates.items, {}, struct {
            fn lessThan(_: void, a: Candidate, b: Candidate) bool {
                const ag = @as(u64, a.occurrences) * @as(u64, a.text.len -| 1);
                const bg = @as(u64, b.occurrences) * @as(u64, b.text.len -| 1);
                if (ag != bg) return ag > bg;
                if (a.text.len != b.text.len) return a.text.len > b.text.len;
                return std.mem.order(u8, a.text, b.text) == .lt;
            }
        }.lessThan);
        var kept: usize = 0;
        for (l.candidates.items) |*c| {
            if (c.occurrences < l.options.min_piece_occ or kept >= l.options.max_pieces) {
                c.active = false;
                continue;
            }
            c.active = true;
            kept += 1;
        }
        l.candidates.items.len = @min(l.candidates.items.len, kept);
        if (l.options.verbose) std.debug.print("unigram candidates={d} active={d}\n", .{ l.candidates.items.len, kept });
    }

    fn pieceCost(l: *const Learner, index: usize, total: f64, active_count: f64) f64 {
        const c = l.candidates.items[index];
        // Add-alpha unigram code plus a small fixed per-piece coding tax.  A
        // final frame never trusts this estimate; plan.fit is authoritative.
        return @log2((total + 0.5 * active_count) / (@as(f64, @floatFromInt(c.occurrences)) + 0.5)) + 1.0;
    }

    fn resetPaths(l: *Learner) !void {
        l.path_off.clearRetainingCapacity();
        try l.path_off.append(l.arena, 0);
        l.paths.clearRetainingCapacity();
    }

    fn viterbiType(l: *Learner, text: []const u8, total: f64, active_count: f64) !void {
        const n = text.len;
        const cost = try l.arena.alloc(f64, n + 1);
        const prev = try l.arena.alloc(usize, n + 1);
        const prev_piece = try l.arena.alloc(u32, n + 1);
        @memset(cost, inf);
        @memset(prev, 0);
        @memset(prev_piece, no_piece);
        cost[0] = 0;

        // Candidate IDs are sorted by first byte once per pass.  A linear
        // scan is intentional here: max_pieces is bounded and this screen is
        // capped at 256 KiB; no hash map is used in the hot DP loop.
        for (0..n) |at| {
            if (cost[at] >= inf) continue;
            if (cost[at] + 8.0 < cost[at + 1]) {
                cost[at + 1] = cost[at] + 8.0;
                prev[at + 1] = at;
                prev_piece[at + 1] = no_piece;
            }
            for (l.candidates.items, 0..) |candidate, ci| {
                if (!candidate.active or candidate.text[0] != text[at]) continue;
                if (candidate.text.len > n - at) continue;
                if (!std.mem.eql(u8, candidate.text, text[at..][0..candidate.text.len])) continue;
                const end = at + candidate.text.len;
                const next = cost[at] + l.pieceCost(ci, total, active_count);
                if (next + 1.0e-9 < cost[end]) {
                    cost[end] = next;
                    prev[end] = at;
                    prev_piece[end] = @intCast(ci);
                }
            }
        }
        var rev: std.ArrayList(Seg) = .empty;
        var at = n;
        while (at != 0) {
            const from = prev[at];
            if (from == at) return error.InternalPath;
            try rev.append(l.arena, .{ .piece = prev_piece[at], .byte = text[from] });
            at = from;
        }
        var i = rev.items.len;
        while (i != 0) {
            i -= 1;
            try l.paths.append(l.arena, rev.items[i]);
        }
        try l.path_off.append(l.arena, @intCast(l.paths.items.len));
    }

    fn countPathUsage(l: *Learner) ![]u32 {
        const count = try l.arena.alloc(u32, l.candidates.items.len);
        @memset(count, 0);
        for (0..l.atoms.types.count()) |t| {
            const freq = l.atoms.frequencies.items[t];
            for (l.paths.items[l.path_off.items[t]..l.path_off.items[t + 1]]) |seg| if (seg.piece != no_piece) {
                count[seg.piece] +|= freq;
            };
        }
        return count;
    }

    fn objective(l: *const Learner, counts: []const u32) f64 {
        var value: f64 = 0;
        var active_count: usize = 0;
        for (l.candidates.items) |c| {
            active_count += @intFromBool(c.active);
        }
        const total: f64 = @floatFromInt(@max(l.atoms.stream.items.len, 1));
        for (0..l.atoms.types.count()) |t| {
            const freq: f64 = @floatFromInt(l.atoms.frequencies.items[t]);
            for (l.paths.items[l.path_off.items[t]..l.path_off.items[t + 1]]) |seg| {
                value += freq * if (seg.piece == no_piece) 8.0 else l.pieceCost(seg.piece, total, @floatFromInt(active_count));
            }
        }
        for (l.candidates.items, counts) |c, used| if (c.active and used != 0) {
            value += l.options.piece_tax + @as(f64, @floatFromInt(c.text.len)) * l.options.spelling_bit;
        };
        return value;
    }

    fn learn(l: *Learner) !void {
        if (l.options.mode == .raw or l.options.mode == .phrase) return;
        try l.gatherCandidates();
        if (l.candidates.items.len == 0) return;

        var best_obj = inf;
        const best_active = try l.arena.alloc(bool, l.candidates.items.len);
        @memset(best_active, false);
        var total_occ: f64 = @floatFromInt(@max(l.atoms.stream.items.len, 1));
        for (0..l.options.rounds) |_| {
            var active_count: usize = 0;
            for (l.candidates.items) |c| active_count += @intFromBool(c.active);
            try l.resetPaths();
            for (l.atoms.types.keys()) |text| try l.viterbiType(text, total_occ, @floatFromInt(active_count));
            const counts = try l.countPathUsage();
            const score = l.objective(counts);
            if (score < best_obj) {
                best_obj = score;
                for (best_active, l.candidates.items) |*dst, c| dst.* = c.active;
                // `paths` for the best state are regenerated after the loop.
            }
            var next_active: usize = 0;
            for (l.candidates.items, counts) |*c, used| {
                c.selected = used;
                c.active = used >= 2;
                next_active += @intFromBool(c.active);
            }
            if (next_active == 0) break;
            total_occ = 0;
            for (counts) |used| total_occ += @floatFromInt(used);
            if (total_occ < 1) total_occ = 1;
        }
        for (l.candidates.items, best_active) |*c, active| c.active = active;
        var active_count: usize = 0;
        for (l.candidates.items) |c| {
            active_count += @intFromBool(c.active);
        }
        try l.resetPaths();
        for (l.atoms.types.keys()) |text| try l.viterbiType(text, total_occ, @floatFromInt(active_count));
        _ = try l.countPathUsage();
        if (l.options.verbose) std.debug.print("unigram objective={d:.1} active={d}\n", .{ best_obj, active_count });
    }
};

const ParseBuild = struct {
    arena: Allocator,
    learner: *Learner,
    options: Options,
    body_off: std.ArrayList(u32) = .empty,
    kids: std.ArrayList(u32) = .empty,
    unit_ids: []u32 = &.{},
    base_tokens: std.ArrayList(u32) = .empty,
    raw_block_off: std.ArrayList(u32) = .empty,
    phrases: std.ArrayList(PhraseCandidate) = .empty,
    phrase_ids: []u32 = &.{},
    picks: []u32 = &.{},

    fn addBody(p: *ParseBuild, body: []const u32) !u32 {
        const id: u32 = @intCast(256 + p.body_off.items.len - 1);
        try p.kids.appendSlice(p.arena, body);
        try p.body_off.append(p.arena, @intCast(p.kids.items.len));
        return id;
    }

    fn init(p: *ParseBuild) !void {
        try p.body_off.append(p.arena, 0);
        const ntypes = p.learner.atoms.types.count();
        p.unit_ids = try p.arena.alloc(u32, ntypes);
        @memset(p.unit_ids, 0);
        // Lexical pieces are the first entries.  Only pieces that are active
        // in the final Viterbi state become model entries; unused candidates
        // are not free vocabulary.
        if (p.options.mode == .lex or p.options.mode == .both) {
            for (p.learner.candidates.items) |c| if (c.active) {
                const body = try p.arena.alloc(u32, c.text.len);
                for (body, c.text) |*dst, byte| dst.* = byte;
                _ = try p.addBody(body);
            };
        }
        const piece_base: u32 = 256;
        // Candidate -> Parse entry id.  Candidate IDs are stable after
        // gather/sort; active candidates are compacted here.
        const piece_ids = try p.arena.alloc(u32, p.learner.candidates.items.len);
        @memset(piece_ids, no_piece);
        var next_piece: u32 = piece_base;
        if (p.options.mode == .lex or p.options.mode == .both) for (p.learner.candidates.items, 0..) |c, ci| if (c.active) {
            piece_ids[ci] = next_piece;
            next_piece += 1;
        };

        // Build one lexical entry per multi-byte atom type.  A singleton
        // byte stays a byte token, and a one-piece path may point directly to
        // the piece entry (avoids an uncharged alias).
        for (p.learner.atoms.types.keys(), 0..) |text, t| {
            var body: std.ArrayList(u32) = .empty;
            if (p.options.mode == .lex or p.options.mode == .both) {
                const path = p.learner.paths.items[p.learner.path_off.items[t]..p.learner.path_off.items[t + 1]];
                for (path) |seg| {
                    if (seg.piece == no_piece) {
                        try body.append(p.arena, seg.byte);
                    } else {
                        const id = piece_ids[seg.piece];
                        if (id == no_piece) return error.MissingPiece;
                        try body.append(p.arena, id);
                    }
                }
            } else {
                for (text) |byte| try body.append(p.arena, byte);
            }
            if (body.items.len == 1) {
                p.unit_ids[t] = body.items[0];
            } else {
                p.unit_ids[t] = try p.addBody(body.items);
            }
        }

        for (p.learner.atoms.stream.items) |t| {
            try p.base_tokens.append(p.arena, p.unit_ids[t]);
        }
        // Exact block fences are based on original byte starts, not token
        // counts.  Empty blocks are allowed, matching v4's learner.
        p.raw_block_off.clearRetainingCapacity();
        try p.raw_block_off.append(p.arena, 0);
        var next_cut = p.options.block;
        for (p.learner.atoms.starts.items, 0..) |start, i| {
            while (start >= next_cut) {
                try p.raw_block_off.append(p.arena, @intCast(i));
                next_cut += p.options.block;
            }
        }
        try p.raw_block_off.append(p.arena, @intCast(p.base_tokens.items.len));
    }

    fn tokenCounts(p: *ParseBuild) ![]u32 {
        const max_id = 256 + p.body_off.items.len;
        const counts = try p.arena.alloc(u32, max_id);
        @memset(counts, 0);
        for (p.base_tokens.items) |tok| {
            if (tok < max_id) counts[tok] +|= 1;
        }
        return counts;
    }

    fn phraseGather(p: *ParseBuild) !void {
        if (p.options.mode != .phrase and p.options.mode != .both) return;
        var map: std.AutoHashMapUnmanaged(NKey, u32) = .empty;
        for (0..p.raw_block_off.items.len - 1) |b| {
            const from = p.raw_block_off.items[b];
            const to = p.raw_block_off.items[b + 1];
            for (from..to) |i| {
                var key: NKey = .{};
                for (2..@min(p.options.max_phrase, to - i) + 1) |n| {
                    key.len = @intCast(n);
                    key.ids[n - 1] = p.base_tokens.items[i + n - 1];
                    const slot = try map.getOrPut(p.arena, key);
                    var c: *PhraseCandidate = undefined;
                    if (slot.found_existing) c = &p.phrases.items[slot.value_ptr.*] else {
                        const idx: u32 = @intCast(p.phrases.items.len);
                        slot.value_ptr.* = idx;
                        try p.phrases.append(p.arena, .{ .key = key });
                        c = &p.phrases.items[idx];
                    }
                    c.occurrences +|= 1;
                }
            }
        }
        std.mem.sort(PhraseCandidate, p.phrases.items, {}, struct {
            fn lessThan(_: void, a: PhraseCandidate, b: PhraseCandidate) bool {
                const ag = @as(u64, a.occurrences) * @as(u64, a.key.len -| 1);
                const bg = @as(u64, b.occurrences) * @as(u64, b.key.len -| 1);
                if (ag != bg) return ag > bg;
                if (a.key.len != b.key.len) return a.key.len > b.key.len;
                return std.mem.lessThan(u32, a.key.ids[0..a.key.len], b.key.ids[0..b.key.len]);
            }
        }.lessThan);
        var kept: usize = 0;
        for (p.phrases.items) |c| {
            if (c.occurrences >= p.options.min_phrase_occ and kept < p.options.max_phrases) kept += 1 else break;
        }
        p.phrases.items.len = kept;
        if (p.options.verbose) std.debug.print("phrase candidates={d}\n", .{kept});
    }

    fn lowerBound(refs: []const StartRef, needle: u32) usize {
        var lo: usize = 0;
        var hi: usize = refs.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (refs[mid].first < needle) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    fn choosePhrases(p: *ParseBuild) !void {
        if (p.phrases.items.len == 0) return;
        const counts = try p.tokenCounts();
        const total: f64 = @floatFromInt(@max(p.base_tokens.items.len, 1));
        const refs = try p.arena.alloc(StartRef, p.phrases.items.len);
        for (refs, p.phrases.items, 0..) |*ref, c, ci| ref.* = .{ .first = c.key.ids[0], .candidate = @intCast(ci) };
        std.mem.sort(StartRef, refs, {}, struct {
            fn lessThan(_: void, a: StartRef, b: StartRef) bool {
                return if (a.first != b.first) a.first < b.first else a.candidate < b.candidate;
            }
        }.lessThan);
        p.picks = try p.arena.alloc(u32, p.base_tokens.items.len);
        @memset(p.picks, no_piece);
        for (0..p.raw_block_off.items.len - 1) |b| {
            const from = p.raw_block_off.items[b];
            const to = p.raw_block_off.items[b + 1];
            const n = to - from;
            const dp = try p.arena.alloc(f64, n + 1);
            const choice = try p.arena.alloc(u32, n);
            @memset(dp, 0);
            @memset(choice, no_piece);
            var i = n;
            while (i != 0) {
                i -= 1;
                dp[i] = dp[i + 1];
                const token = p.base_tokens.items[from + i];
                var r = lowerBound(refs, token);
                while (r < refs.len and refs[r].first == token) : (r += 1) {
                    const ci = refs[r].candidate;
                    const c = p.phrases.items[ci];
                    const len = @as(usize, c.key.len);
                    if (i + len > n) continue;
                    var component: f64 = 0;
                    for (c.key.ids[0..len]) |id| {
                        const freq = if (id < counts.len) counts[id] else 1;
                        component += @log2(total / (@as(f64, @floatFromInt(freq)) + 0.5));
                    }
                    const phrase_cost = @log2((total + 0.5 * @as(f64, @floatFromInt(p.phrases.items.len))) / (@as(f64, @floatFromInt(c.occurrences)) + 0.5)) + p.options.phrase_tax;
                    const gain = component - phrase_cost;
                    if (gain > 0 and gain + dp[i + len] > dp[i] + 1.0e-9) {
                        dp[i] = gain + dp[i + len];
                        choice[i] = @intCast(ci);
                    }
                }
            }
            i = 0;
            while (i < n) {
                if (choice[i] == no_piece) {
                    i += 1;
                } else {
                    const ci = choice[i];
                    const len = p.phrases.items[ci].key.len;
                    p.picks[from + i] = ci;
                    p.phrases.items[ci].selected += 1;
                    i += len;
                }
            }
        }
        for (p.phrases.items) |*c| {
            if (c.selected < 2) c.selected = 0;
        }
    }

    fn finish(p: *ParseBuild) !Parse {
        try p.init();
        try p.phraseGather();
        try p.choosePhrases();
        p.phrase_ids = try p.arena.alloc(u32, p.phrases.items.len);
        @memset(p.phrase_ids, no_piece);
        for (p.phrases.items, 0..) |c, ci| if (c.selected >= 2) {
            const body = try p.arena.alloc(u32, c.key.len);
            @memcpy(body, c.key.ids[0..c.key.len]);
            p.phrase_ids[ci] = try p.addBody(body);
        };
        var block_off: std.ArrayList(u32) = .empty;
        var toks: std.ArrayList(u32) = .empty;
        try block_off.append(p.arena, 0);
        for (0..p.raw_block_off.items.len - 1) |b| {
            const from = p.raw_block_off.items[b];
            const to = p.raw_block_off.items[b + 1];
            var i = from;
            while (i < to) {
                const picked = if (p.picks.len == 0) no_piece else p.picks[i];
                const id = if (picked != no_piece and p.phrase_ids[picked] != no_piece) p.phrase_ids[picked] else no_piece;
                if (id != no_piece) {
                    try toks.append(p.arena, id);
                    i += p.phrases.items[picked].key.len;
                } else {
                    try toks.append(p.arena, p.base_tokens.items[i]);
                    i += 1;
                }
            }
            try block_off.append(p.arena, @intCast(toks.items.len));
        }
        if (p.options.verbose) {
            var used_phrases: usize = 0;
            for (p.phrases.items) |c| used_phrases += @intFromBool(c.selected >= 2);
            std.debug.print("parse entries={d} pieces={d} phrases={d} blocks={d}\n", .{ p.body_off.items.len - 1, p.body_off.items.len - 1 - p.learner.atoms.types.count(), used_phrases, block_off.items.len - 1 });
        }
        return .{ .body_off = p.body_off.items, .kids = p.kids.items, .block_off = block_off.items, .toks = toks.items };
    }
};

fn parseMode(arg: []const u8) !Mode {
    if (std.mem.eql(u8, arg, "raw")) return .raw;
    if (std.mem.eql(u8, arg, "lex")) return .lex;
    if (std.mem.eql(u8, arg, "phrase")) return .phrase;
    if (std.mem.eql(u8, arg, "both")) return .both;
    return error.Usage;
}

fn usage() error{Usage} {
    std.debug.print("usage: unigram_interval DATA [mode raw|lex|phrase|both] [block]\n", .{});
    return error.Usage;
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const path = args.next() orelse return usage();
    const mode = if (args.next()) |arg| try parseMode(arg) else .both;
    const block = if (args.next()) |arg| try std.fmt.parseUnsigned(usize, arg, 10) else 1 << 16;
    const cwd = std.Io.Dir.cwd();
    const input = try cwd.readFileAlloc(init.io, path, init.gpa, .limited(1 << 28));
    defer init.gpa.free(input);

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const options: Options = .{ .mode = mode, .block = block };
    var learner = try Learner.init(arena_state.allocator(), input, options);
    const bytes = if (mode == .raw) blk: {
        break :blk try bz4.compress(init.gpa, input, .{ .learn = .{ .block = block } });
    } else blk: {
        try learner.learn();
        var builder: ParseBuild = .{ .arena = arena_state.allocator(), .learner = &learner, .options = options };
        const parse = try builder.finish();
        break :blk (try bz4.plan.fit(arena_state.allocator(), init.gpa, parse, .{ .classes = 0 })).bytes;
    };
    defer init.gpa.free(bytes);
    const decoded = try bz4.decompress(init.gpa, bytes, 1);
    defer init.gpa.free(decoded);
    if (!std.mem.eql(u8, input, decoded)) return error.RoundTripMismatch;
    std.debug.print("mode={s} input={d} frame={d} ratio={d:.4}\n", .{ @tagName(mode), input.len, bytes.len, @as(f64, @floatFromInt(bytes.len)) / @as(f64, @floatFromInt(@max(input.len, 1))) });
}
