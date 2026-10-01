//! An alternative lexicon source: a binary (Re-Pair-style) phrase grammar,
//! built greedily by repeatedly merging the highest-scoring adjacent
//! symbol pair, in one shot (no iterative re-parsing or class modelling --
//! those come from the rest of the package once `toCorpus` below hands
//! this off as an ordinary `Corpus`).
//!
//! On data with little word-like structure (binaries, source code,
//! anything where byte-pair frequency is a better signal than "looks like
//! a word"), this frequently makes a better starting lexicon than the
//! compositional MDL engine in `propose.zig`/`parse.zig`/`delete.zig` --
//! `root.zig`'s compress tournament builds both and keeps whichever real
//! frame is smallest. A binary rule is just an arity-2 `Lexicon` entry, so
//! this needs no format change: `toCorpus` is a direct, lossless
//! conversion.
//!
//! `priority = .saving` scores a candidate pair by its estimated MDL delta
//! (occurrences saved minus the new rule's own estimated storage cost)
//! rather than raw frequency, and `selectRoles` accepts a role-consistent
//! batch per round (no symbol is both a left and right member of two
//! different accepted pairs), both real levers on top of plain frequency-
//! ranked Re-Pair.
//!
//! Pure Zig 0.16, std only.

const std = @import("std");
const lexicon = @import("lexicon.zig");

pub const Rule = extern struct { a: u32, b: u32 };

pub const Priority = enum { freq, saving };

pub const BuildOpts = struct {
    max_rules: usize = 1_000_000,
    min_freq: u32 = 2,
    alpha_percent: u32 = 50,
    priority: Priority = .freq,
    fast_count: bool = true,
};

pub const Grammar = struct {
    rules: std.ArrayList(Rule) = .empty,
    seq: []u32,
    block_end: []usize,
    block_bytes: usize,
    passes: usize = 0,

    pub fn numSymbols(self: *const Grammar) usize {
        return 256 + self.rules.items.len;
    }

    pub fn deinit(self: *Grammar, alloc: std.mem.Allocator) void {
        self.rules.deinit(alloc);
        alloc.free(self.seq);
        alloc.free(self.block_end);
    }

    pub fn clone(self: *const Grammar, alloc: std.mem.Allocator) !Grammar {
        var rules: std.ArrayList(Rule) = .empty;
        try rules.appendSlice(alloc, self.rules.items);
        const seq = try alloc.dupe(u32, self.seq);
        const block_end = try alloc.dupe(usize, self.block_end);
        return .{ .rules = rules, .seq = seq, .block_end = block_end, .block_bytes = self.block_bytes, .passes = self.passes };
    }
};

pub inline fn log2f(x: f64) f64 {
    return @log2(x);
}

pub inline fn bitsOfCount(count: u64, m: f64) f64 {
    if (count > 0) return -log2f(@as(f64, @floatFromInt(count)) / m);
    return -log2f(0.5 / m);
}

pub inline fn flog(c: u64) f64 {
    if (c == 0) return 0;
    const cf: f64 = @floatFromInt(c);
    return cf * log2f(cf);
}

// ---------------------------------------------------------------- PairTable

const empty_key: u64 = std.math.maxInt(u64);

const PairTable = struct {
    keys: []u64,
    vals: []u32,
    mask: usize,
    used: usize = 0,

    fn init(alloc: std.mem.Allocator, log2_cap: u6) !PairTable {
        const cap = @as(usize, 1) << log2_cap;
        const keys = try alloc.alloc(u64, cap);
        @memset(keys, empty_key);
        const vals = try alloc.alloc(u32, cap);
        @memset(vals, 0);
        return .{ .keys = keys, .vals = vals, .mask = cap - 1 };
    }

    fn deinit(self: *PairTable, alloc: std.mem.Allocator) void {
        alloc.free(self.keys);
        alloc.free(self.vals);
    }

    inline fn slot(self: *const PairTable, key: u64) usize {
        var h = key *% 0x9E3779B97F4A7C15;
        h ^= h >> 29;
        var i = @as(usize, @truncate(h)) & self.mask;
        while (self.keys[i] != empty_key and self.keys[i] != key) i = (i + 1) & self.mask;
        return i;
    }

    inline fn bump(self: *PairTable, key: u64) void {
        const i = self.slot(key);
        if (self.keys[i] == empty_key) {
            self.keys[i] = key;
            self.used += 1;
        }
        self.vals[i] += 1;
    }
};

const Cand = struct { key: u64, score: f64, id: u32 = 0 };

fn candDesc(_: void, x: Cand, y: Cand) bool {
    if (x.score != y.score) return x.score > y.score;
    return x.key < y.key;
}

fn selectRoles(alloc: std.mem.Allocator, cands: []Cand, roles: *std.ArrayList(u8), rules: *std.ArrayList(Rule), max_rules: usize) !usize {
    std.mem.sort(Cand, cands, {}, candDesc);
    @memset(roles.items, 0);
    var selected: usize = 0;
    for (cands) |*cand| {
        if (rules.items.len >= max_rules) continue;
        const a: u32 = @intCast(cand.key >> 32);
        const b: u32 = @truncate(cand.key);
        if (a == b) {
            if (roles.items[a] != 0) continue;
            roles.items[a] = 3;
        } else {
            if (roles.items[a] & 2 != 0 or roles.items[b] & 1 != 0) continue;
            roles.items[a] |= 1;
            roles.items[b] |= 2;
        }
        const id: u32 = @intCast(256 + rules.items.len);
        try rules.append(alloc, .{ .a = a, .b = b });
        try roles.append(alloc, 0);
        cand.id = id;
        selected += 1;
    }
    return selected;
}

// -------------------------------------------------------------------- build

pub fn build(
    alloc: std.mem.Allocator,
    input: []const u8,
    block_bytes: usize,
    opts: BuildOpts,
) !Grammar {
    const n = input.len;
    const seq = try alloc.alloc(u32, n);
    for (input, 0..) |byte, i| seq[i] = byte;
    const block_count = if (n == 0) 0 else (n + block_bytes - 1) / block_bytes;
    const block_end = try alloc.alloc(usize, block_count);
    for (0..block_count) |b| block_end[b] = @min(n, (b + 1) * block_bytes);

    var rules: std.ArrayList(Rule) = .empty;
    var roles: std.ArrayList(u8) = .empty;
    try roles.appendNTimes(alloc, 0, 256);

    var passes: usize = 0;
    var live: usize = n;
    var prev_used: usize = 0;

    while (rules.items.len < opts.max_rules) : (passes += 1) {
        var cands: std.ArrayList(Cand) = .empty;
        defer cands.deinit(alloc);

        if (passes == 0 and opts.fast_count) {
            const flat = try alloc.alloc(u32, 65536);
            defer alloc.free(flat);
            @memset(flat, 0);
            var start: usize = 0;
            for (block_end) |end| {
                var i = start;
                var skip_at: usize = std.math.maxInt(usize);
                while (i + 1 < end) : (i += 1) {
                    const a = seq[i];
                    const b = seq[i + 1];
                    if (a == b and skip_at == i) continue;
                    if (a == b) skip_at = i + 1;
                    flat[(a << 8) | b] += 1;
                }
                start = end;
            }
            var max_count: u32 = 0;
            var seen: usize = 0;
            for (flat) |v| {
                max_count = @max(max_count, v);
                if (v != 0) seen += 1;
            }
            prev_used = seen;
            if (max_count < opts.min_freq) break;
            const thr = @max(opts.min_freq, @as(u32, @intCast((@as(u64, max_count) * opts.alpha_percent + 99) / 100)));

            var freq_tally: []u64 = &.{};
            if (opts.priority == .saving) {
                freq_tally = try alloc.alloc(u64, 256);
                @memset(freq_tally, 0);
                for (seq[0..live]) |s| freq_tally[s] += 1;
            }
            defer if (opts.priority == .saving) alloc.free(freq_tally);
            const mf: f64 = @floatFromInt(live);

            for (flat, 0..) |v, key| {
                if (v < thr) continue;
                const a: u32 = @intCast(key >> 8);
                const b: u32 = @intCast(key & 0xFF);
                var score: f64 = @floatFromInt(v);
                if (opts.priority == .saving) {
                    const bits_a = bitsOfCount(freq_tally[a], mf);
                    const bits_b = bitsOfCount(freq_tally[b], mf);
                    const bits_new = bitsOfCount(v, mf);
                    score = @as(f64, @floatFromInt(v)) * (bits_a + bits_b - bits_new) - 13.0;
                }
                try cands.append(alloc, .{ .key = @as(u64, a) << 32 | b, .score = score });
            }
            const selected = try selectRoles(alloc, cands.items, &roles, &rules, opts.max_rules);
            if (selected == 0) break;

            @memset(flat, 0);
            for (cands.items) |c| {
                if (c.id == 0) continue;
                const a: usize = @intCast(c.key >> 32);
                const b: usize = @intCast(c.key & 0xFF);
                flat[(a << 8) | b] = c.id;
            }

            var read: usize = 0;
            var write: usize = 0;
            for (block_end) |*end_ptr| {
                const end = end_ptr.*;
                while (read < end) {
                    if (read + 1 < end) {
                        const a = seq[read];
                        const b = seq[read + 1];
                        const idx = (a << 8) | b;
                        const id = flat[idx];
                        if (id != 0) {
                            seq[write] = id;
                            write += 1;
                            read += 2;
                            continue;
                        }
                    }
                    seq[write] = seq[read];
                    write += 1;
                    read += 1;
                }
                end_ptr.* = write;
            }
            live = write;
        } else {
            var log2_cap: u6 = 12;
            if (opts.fast_count and prev_used > 0) {
                const target = @max(prev_used * 4, @as(usize, 4096));
                while ((@as(usize, 1) << log2_cap) < target and log2_cap < 25) log2_cap += 1;
            } else {
                while ((@as(usize, 1) << log2_cap) < live * 2 and log2_cap < 25) log2_cap += 1;
            }
            var table = try PairTable.init(alloc, log2_cap);
            defer table.deinit(alloc);

            var start: usize = 0;
            for (block_end) |end| {
                var i = start;
                var skip_at: usize = std.math.maxInt(usize);
                while (i + 1 < end) : (i += 1) {
                    const a = seq[i];
                    const b = seq[i + 1];
                    if (a == b and skip_at == i) continue;
                    if (a == b) skip_at = i + 1;
                    table.bump(@as(u64, a) << 32 | b);
                }
                start = end;
            }

            var max_count: u32 = 0;
            for (table.vals) |v| max_count = @max(max_count, v);
            prev_used = table.used;
            if (max_count < opts.min_freq) break;
            const thr = @max(opts.min_freq, @as(u32, @intCast((@as(u64, max_count) * opts.alpha_percent + 99) / 100)));

            var freq_tally: []u64 = &.{};
            const k_now = 256 + rules.items.len;
            if (opts.priority == .saving) {
                freq_tally = try alloc.alloc(u64, k_now);
                @memset(freq_tally, 0);
                for (seq[0..live]) |s| freq_tally[s] += 1;
            }
            defer if (opts.priority == .saving) alloc.free(freq_tally);
            const mf: f64 = @floatFromInt(live);

            for (table.keys, table.vals) |k, v| {
                if (k == empty_key or v < thr) continue;
                var score: f64 = @floatFromInt(v);
                if (opts.priority == .saving) {
                    const a: u32 = @intCast(k >> 32);
                    const b: u32 = @truncate(k);
                    const bits_a = bitsOfCount(freq_tally[a], mf);
                    const bits_b = bitsOfCount(freq_tally[b], mf);
                    const bits_new = bitsOfCount(v, mf);
                    score = @as(f64, @floatFromInt(v)) * (bits_a + bits_b - bits_new) - 13.0;
                }
                try cands.append(alloc, .{ .key = k, .score = score });
            }
            const selected = try selectRoles(alloc, cands.items, &roles, &rules, opts.max_rules);
            if (selected == 0) break;

            @memset(table.vals, 0);
            for (cands.items) |c| {
                if (c.id == 0) continue;
                table.vals[table.slot(c.key)] = c.id;
            }

            var read: usize = 0;
            var write: usize = 0;
            for (block_end) |*end_ptr| {
                const end = end_ptr.*;
                while (read < end) {
                    if (read + 1 < end) {
                        const key = @as(u64, seq[read]) << 32 | seq[read + 1];
                        const s = table.slot(key);
                        if (table.keys[s] == key and table.vals[s] != 0) {
                            seq[write] = table.vals[s];
                            write += 1;
                            read += 2;
                            continue;
                        }
                    }
                    seq[write] = seq[read];
                    write += 1;
                    read += 1;
                }
                end_ptr.* = write;
            }
            live = write;
        }
    }
    roles.deinit(alloc);
    // Return a properly shrunk allocation, not a re-sliced VIEW into the
    // original `n`-sized one: freeing a shorter slice than what a real
    // allocator actually handed out resolves to the wrong size class (an
    // "invalid free" panic under `std.heap.DebugAllocator`) unless the
    // caller happens to be using an arena, whose `free()` is a no-op.
    // `alloc.realloc` shrinks (or frees, if live==0) the allocation
    // properly so the returned slice is what the allocator actually
    // thinks it owns.
    const seq_final = try alloc.realloc(seq, live);
    return .{ .rules = rules, .seq = seq_final, .block_end = block_end, .block_bytes = block_bytes, .passes = passes };
}

// ------------------------------------------------------------ conversion

/// A binary rule IS an arity-2 `Lexicon` entry: this is a direct,
/// lossless conversion, not a re-derivation. Rule children are always
/// numerically smaller than the rule's own id (every merge only ever
/// combines symbols that already exist), so `explen` is computable in a
/// single forward pass with no topological sort needed.
pub fn toCorpus(alloc: std.mem.Allocator, gm: *const Grammar) !lexicon.Corpus {
    const num_rules = gm.rules.items.len;
    var builder = try lexicon.LexBuilder.init(alloc);
    const explen = try alloc.alloc(u32, 256 + num_rules);
    defer alloc.free(explen);
    for (0..256) |i| explen[i] = 1;
    for (gm.rules.items, 0..) |r, i| {
        explen[256 + i] = explen[r.a] + explen[r.b];
        _ = try builder.addEntry(alloc, &.{ r.a, r.b }, explen[256 + i]);
    }
    return .{
        .lex = builder.finish(),
        .seq = try alloc.dupe(u32, gm.seq),
        .block_end = try alloc.dupe(usize, gm.block_end),
        .block_bytes = gm.block_bytes,
    };
}

test "build + toCorpus roundtrips byte-exact" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const raw = "abcabcabcabc abcabcabc xyzxyzxyz abcabc" ** 20;

    var gm = try build(a, raw, 4096, .{ .priority = .saving, .fast_count = true });
    var corpus = try toCorpus(a, &gm);
    try std.testing.expect(try lexicon.verifyExact(a, raw, &corpus));
    try std.testing.expect(corpus.lex.numEntries() > 0);
}

test "build on empty and tiny input never crashes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_][]const u8{ "", "x", "xy", "xyz" }) |raw| {
        var gm = try build(a, raw, 4096, .{ .priority = .saving });
        var corpus = try toCorpus(a, &gm);
        try std.testing.expect(try lexicon.verifyExact(a, raw, &corpus));
    }
}
