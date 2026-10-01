//! bz4_grammar.zig — Lane V's copy of Lane A's grammar builder (grammar2.zig),
//! extended with the closed-loop MDL deletion pass this lane's brief asks
//! for: a per-rule cost approximation that mirrors the REAL model codec
//! (bz4_model.zig) instead of a flat RULE_BITS constant, calibrated against
//! real measured bits after each pruning round.
//!
//! `build()`, `mdlDeleteFlat()` (renamed copy of grammar2's `mdlDelete`,
//! kept verbatim as the "Lane A's plain a2" comparison candidate),
//! `optimalReparse()` (A4, used only at effort=1), `objective`/`costOf`,
//! `computeExplen`/`parentCounts`/`rootCounts`, and `verifyExact` are
//! line-for-line copies of grammar2.zig (see LANE_A.md) — PLAN.md requires
//! copying rather than importing another lane's owned file when this lane
//! needs to add functionality (`mdlDeleteCalibrated` below) alongside it.
//!
//! Pure Zig 0.16, std only.

const std = @import("std");

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
    // NOTE (bug fixed vs. grammar2.zig's copy of this function): the
    // original returned `seq[0..live]`, a re-sliced VIEW into the
    // originally-`n`-sized allocation. That is only safe to `free()` later
    // under an arena allocator (whose `free()` is a no-op) -- Lane A's own
    // gramlab.zig always builds with an arena, so it never hit this. Any
    // caller that frees with a real allocator (this lane's bz4.zig does)
    // hits `std.heap.DebugAllocator`'s "Invalid free" panic, because
    // `free()`'s size-class lookup is keyed on the SLICE LENGTH passed in,
    // and a shorter length than the original allocation resolves to the
    // wrong bucket. `alloc.realloc` shrinks (or frees, if live==0) the
    // allocation properly so the returned slice is what the allocator
    // actually thinks it owns.
    const seq_final = try alloc.realloc(seq, live);
    return .{ .rules = rules, .seq = seq_final, .block_end = block_end, .block_bytes = block_bytes, .passes = passes };
}

// --------------------------------------------------------------- structure

pub fn computeExplen(alloc: std.mem.Allocator, rules: []const Rule) ![]u32 {
    const k = 256 + rules.len;
    const explen = try alloc.alloc(u32, k);
    for (0..256) |b| explen[b] = 1;
    for (rules, 0..) |r, i| explen[256 + i] = explen[r.a] + explen[r.b];
    return explen;
}

pub fn parentCounts(alloc: std.mem.Allocator, rules: []const Rule) ![]u32 {
    const parent = try alloc.alloc(u32, rules.len);
    @memset(parent, 0);
    for (rules) |r| {
        if (r.a >= 256) parent[r.a - 256] += 1;
        if (r.b >= 256) parent[r.b - 256] += 1;
    }
    return parent;
}

pub const RootCounts = struct { g: []u64, m: u64 };

pub fn rootCounts(alloc: std.mem.Allocator, gm: *const Grammar) !RootCounts {
    const k = gm.numSymbols();
    const g = try alloc.alloc(u64, k);
    @memset(g, 0);
    for (gm.seq) |s| g[s] += 1;
    return .{ .g = g, .m = gm.seq.len };
}

// --------------------------------------------------------------- objective

pub const Cost = struct {
    root_bits: f64,
    rule_bits_total: f64,
    side_info_bits: f64,
    total_bits: f64,
    total_bytes: f64,
};

pub fn objective(g: []const u64, m: u64, num_rules: usize, rule_bits: f64, trivial: ?[]const bool) Cost {
    const mf: f64 = @floatFromInt(m);
    var root_bits: f64 = 0;
    var side_syms: usize = 0;
    for (g, 0..) |c, s| {
        if (c == 0) continue;
        root_bits -= @as(f64, @floatFromInt(c)) * log2f(@as(f64, @floatFromInt(c)) / mf);
        if (s < 256) side_syms += 1;
    }
    side_syms += num_rules;
    var rule_cost: f64 = 0;
    if (trivial) |tv| {
        for (tv) |is_trivial| rule_cost += if (is_trivial) 1.5 else rule_bits;
    } else {
        rule_cost = rule_bits * @as(f64, @floatFromInt(num_rules));
    }
    const side_info_bits = 2.5 * @as(f64, @floatFromInt(side_syms));
    const total_bits = root_bits + rule_cost + side_info_bits;
    return .{ .root_bits = root_bits, .rule_bits_total = rule_cost, .side_info_bits = side_info_bits, .total_bits = total_bits, .total_bytes = total_bits / 8 };
}

pub fn costOf(alloc: std.mem.Allocator, gm: *const Grammar, rule_bits: f64) !Cost {
    const rc = try rootCounts(alloc, gm);
    defer alloc.free(rc.g);
    return objective(rc.g, rc.m, gm.rules.items.len, rule_bits, null);
}

/// Exact root-side static order-0 cost in bytes, via the same
/// M*log2(M) - sum(f(c)) identity used throughout this lane -- this is the
/// part of the closed-loop objective that is essentially exact (Lane S
/// showed real Huffman payload lands within ~0.5% of this).
pub fn rootBitsExact(g: []const u64, m: u64) f64 {
    if (m == 0) return 0;
    const mf: f64 = @floatFromInt(m);
    var sum_f: f64 = 0;
    for (g) |c| sum_f += flog(c);
    return mf * log2f(mf) - sum_f;
}

pub fn trivialMask(alloc: std.mem.Allocator, parent: []const u32, g: []const u64) ![]bool {
    const tv = try alloc.alloc(bool, parent.len);
    for (parent, 0..) |p, i| tv[i] = (p == 1 and g[256 + i] == 0);
    return tv;
}

// ------------------------------------------------------------------ verify

fn expandRec(rules: []const Rule, sym: u32, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    if (sym < 256) {
        try out.append(alloc, @intCast(sym));
        return;
    }
    const r = rules[sym - 256];
    try expandRec(rules, r.a, out, alloc);
    try expandRec(rules, r.b, out, alloc);
}

pub fn verifyExact(alloc: std.mem.Allocator, raw: []const u8, gm: *const Grammar) !bool {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var seq_start: usize = 0;
    var raw_start: usize = 0;
    for (gm.block_end) |seq_end| {
        const raw_end = @min(raw.len, raw_start + gm.block_bytes);
        out.clearRetainingCapacity();
        for (gm.seq[seq_start..seq_end]) |s| try expandRec(gm.rules.items, s, &out, alloc);
        if (!std.mem.eql(u8, out.items, raw[raw_start..raw_end])) return false;
        seq_start = seq_end;
        raw_start = raw_end;
    }
    return seq_start == gm.seq.len and raw_start == raw.len;
}

// -------------------------------------------------------------- A2: delete
// (renamed mdlDeleteFlat: kept as the "Lane A plain a2" comparison candidate)

pub var debug_delete: bool = false;

pub const DeleteStats = struct {
    deleted: usize = 0,
    rounds: usize = 0,
    before_bytes: f64 = 0,
    after_bytes: f64 = 0,
};

const DeleteCand = struct { idx: u32, benefit: f64 };

fn deleteCandDesc(_: void, x: DeleteCand, y: DeleteCand) bool {
    return x.benefit > y.benefit;
}

fn simulateDeleteCost(alloc: std.mem.Allocator, gm: *const Grammar, alive: []const bool, rule_bits: f64) !f64 {
    const k = gm.numSymbols();
    const g_new = try alloc.alloc(u64, k);
    defer alloc.free(g_new);
    @memset(g_new, 0);
    var total: u64 = 0;
    for (gm.seq) |s| {
        if (s < 256 or alive[s - 256]) {
            g_new[s] += 1;
            total += 1;
        } else {
            const r = gm.rules.items[s - 256];
            g_new[r.a] += 1;
            g_new[r.b] += 1;
            total += 2;
        }
    }
    var num_alive: usize = 0;
    for (alive) |a| {
        if (a) num_alive += 1;
    }
    return objective(g_new, total, num_alive, rule_bits, null).total_bytes;
}

pub fn mdlDeleteFlat(alloc: std.mem.Allocator, gm: *Grammar, rule_bits: f64, max_rounds: usize) !DeleteStats {
    const before = try costOf(alloc, gm, rule_bits);
    var stats = DeleteStats{ .before_bytes = before.total_bytes };
    var current_cost = before.total_bytes;

    var round: usize = 0;
    while (round < max_rounds) : (round += 1) {
        const num_rules = gm.rules.items.len;
        if (num_rules == 0) break;

        const parent = try parentCounts(alloc, gm.rules.items);
        defer alloc.free(parent);

        const k = 256 + num_rules;
        const g = try alloc.alloc(u64, k);
        defer alloc.free(g);
        @memset(g, 0);
        for (gm.seq) |s| g[s] += 1;
        const mf: f64 = @floatFromInt(gm.seq.len);

        var alive: []bool = try alloc.alloc(bool, num_rules);
        defer alloc.free(alive);
        @memset(alive, true);
        var cand_list: std.ArrayList(DeleteCand) = .empty;
        defer cand_list.deinit(alloc);
        var free_lunch: usize = 0;
        for (0..num_rules) |i| {
            if (parent[i] != 0) continue;
            const r = gm.rules.items[i];
            const rid: u32 = @intCast(256 + i);
            const uses = g[rid];
            if (uses == 0) {
                alive[i] = false;
                free_lunch += 1;
                continue;
            }
            const uses_f: f64 = @floatFromInt(uses);
            const m_after = mf + uses_f;
            const delta_mlogm = m_after * log2f(m_after) - mf * log2f(mf);
            var delta_children: f64 = undefined;
            if (r.a == r.b) {
                delta_children = flog(g[r.a] + 2 * uses) - flog(g[r.a]);
            } else {
                delta_children = (flog(g[r.a] + uses) - flog(g[r.a])) + (flog(g[r.b] + uses) - flog(g[r.b]));
            }
            const removed_r_term = flog(uses);
            const benefit = -delta_mlogm + delta_children - removed_r_term + rule_bits + 2.5;
            if (benefit > 0) try cand_list.append(alloc, .{ .idx = @intCast(i), .benefit = benefit });
        }
        std.mem.sort(DeleteCand, cand_list.items, {}, deleteCandDesc);

        var accepted: usize = 0;
        var m: usize = cand_list.items.len;
        while (m > 0) {
            for (cand_list.items[0..m]) |c| alive[c.idx] = false;
            const cost_try = try simulateDeleteCost(alloc, gm, alive, rule_bits);
            if (cost_try < current_cost) {
                accepted = m;
                break;
            }
            for (cand_list.items[0..m]) |c| alive[c.idx] = true;
            m /= 2;
        }

        const deleted_this_round = free_lunch + accepted;
        if (deleted_this_round == 0) break;

        var new_seq: std.ArrayList(u32) = .empty;
        defer new_seq.deinit(alloc);
        var new_block_end: std.ArrayList(usize) = .empty;
        defer new_block_end.deinit(alloc);

        var start: usize = 0;
        for (gm.block_end) |end| {
            for (gm.seq[start..end]) |sym| {
                if (sym < 256 or alive[sym - 256]) {
                    try new_seq.append(alloc, sym);
                } else {
                    const r = gm.rules.items[sym - 256];
                    try new_seq.append(alloc, r.a);
                    try new_seq.append(alloc, r.b);
                }
            }
            try new_block_end.append(alloc, new_seq.items.len);
            start = end;
        }

        const remap = try alloc.alloc(u32, k);
        defer alloc.free(remap);
        var new_rules: std.ArrayList(Rule) = .empty;
        for (0..256) |b| remap[b] = @intCast(b);
        for (0..num_rules) |ri| {
            if (!alive[ri]) continue;
            const r = gm.rules.items[ri];
            const new_id: u32 = @intCast(256 + new_rules.items.len);
            try new_rules.append(alloc, .{ .a = remap[r.a], .b = remap[r.b] });
            remap[256 + ri] = new_id;
        }
        for (new_seq.items) |*s| s.* = remap[s.*];

        const g_new = try alloc.alloc(u64, 256 + new_rules.items.len);
        defer alloc.free(g_new);
        @memset(g_new, 0);
        for (new_seq.items) |s| g_new[s] += 1;
        const cost_new = objective(g_new, new_seq.items.len, new_rules.items.len, rule_bits, null).total_bytes;

        if (cost_new < current_cost) {
            stats.deleted += deleted_this_round;
            stats.rounds += 1;
            current_cost = cost_new;
            gm.rules.deinit(alloc);
            gm.rules = new_rules;
            alloc.free(gm.seq);
            gm.seq = try new_seq.toOwnedSlice(alloc);
            alloc.free(gm.block_end);
            gm.block_end = try new_block_end.toOwnedSlice(alloc);
        } else {
            new_rules.deinit(alloc);
            break;
        }
    }

    stats.after_bytes = current_cost;
    return stats;
}

// ---------------------------------------------------- closed-loop MDL (V1)
//
// The flat RULE_BITS=13 charge above is wrong per LANE_A/LANE_B/this lane's
// brief: a real DEF-tree rule costs anywhere from ~0 bits (defined in place,
// single parent, never a root) to ~30+ bits (a top-level rule whose two
// children are both REFs into a ~50k-symbol pool). `Calib` holds the
// per-component multipliers this lane recalibrates from real
// bz4_model.zig measurements after every pruning round (see bz4.zig's
// closed loop driver).

pub const Calib = struct {
    /// Combined cost (bits) of the two child-slot DEF/REF flags for one
    /// rule's own definition.
    flag_bits: f64 = 1.2,
    /// Cost (bits) of naming a byte child via REF (skewed alphabet + cache).
    byte_bits: f64 = 5.5,
    /// Multiplies log2(live_rules) for a REF to a shared (non-inlineable)
    /// rule child -- calibrated down from the raw uniform bound to account
    /// for the 64-slot recency cache's real hit rate.
    ref_log_coeff: f64 = 0.55,
    /// Elias-gamma-style raw bit-length scale for gcount encoding.
    g_scale: f64 = 1.0,
    /// Fixed cost (bits) of the CountCtx zero-flag.
    g_zero_bits: f64 = 0.35,

    pub fn default() Calib {
        return .{};
    }
};

fn gammaRawBits(v: u64) f64 {
    // Elias-gamma-style raw bit length for GammaCtx.encode(v): w=v+1,
    // nb=bitlen(w), cost = 2*nb-1 raw bits (before adaptive scaling).
    const w = v + 1;
    const nb: f64 = @floatFromInt(64 - @clz(w));
    return 2.0 * nb - 1.0;
}

fn gcountBitsApprox(g: u64, calib: Calib) f64 {
    if (g == 0) return calib.g_zero_bits;
    return calib.g_zero_bits + calib.g_scale * gammaRawBits(g - 1);
}

/// Approximate total model cost (structural + g bits, in BYTES) of the
/// grammar under the current calibration -- mirrors bz4_model.zig's
/// v2y_leftchild_order/v2x_gctx_on_freq wire cost per PLAN's brief:
/// cost(rule) = flag_bits + gcount_bits(g[rule])
///            + sum over children of { byte: byte_bits;
///                                      rule, parent_count<=1 and g=0: 0;
///                                      rule, otherwise: ref_log_coeff*log2(live) }
/// Total = sum over all live rules of cost(rule) + sum over the 256 byte
/// symbols of gcount_bits(g[byte]) (bytes always exist and always cost a
/// g-count, whether or not they're ever referenced as children).
pub const ModelBitsSplit = struct { struct_bits: f64, g_bits: f64 };

/// Same estimate as `approxModelBitsCalibrated`, but split into the
/// structural (flag+ref) component and the gcount component -- needed to
/// recalibrate `Calib.g_scale`/`g_zero_bits` independently of the
/// flag/byte/ref-coefficients from a real bz4_model.zig measurement
/// (which reports struct_len/g_len separately too).
pub fn approxModelBitsSplit(alloc: std.mem.Allocator, gm: *const Grammar, calib: Calib) !ModelBitsSplit {
    const num_rules = gm.rules.items.len;
    const k = gm.numSymbols();
    const g = try alloc.alloc(u64, k);
    defer alloc.free(g);
    @memset(g, 0);
    for (gm.seq) |s| g[s] += 1;
    const parent = try parentCounts(alloc, gm.rules.items);
    defer alloc.free(parent);

    const live_f: f64 = @floatFromInt(@max(num_rules, 1));
    const log_live = log2f(@max(live_f, 2.0));

    var struct_bits: f64 = 0;
    var g_bits: f64 = 0;
    for (0..256) |b| g_bits += gcountBitsApprox(g[b], calib);

    for (0..num_rules) |i| {
        const r = gm.rules.items[i];
        const rid = 256 + i;
        struct_bits += calib.flag_bits;
        g_bits += gcountBitsApprox(g[rid], calib);
        inline for ([_]u32{ r.a, r.b }) |child| {
            if (child < 256) {
                struct_bits += calib.byte_bits;
            } else {
                const ci = child - 256;
                if (parent[ci] <= 1 and g[child] == 0) {
                    // defined in place: charged on its own index, 0 here.
                } else {
                    struct_bits += calib.ref_log_coeff * log_live;
                }
            }
        }
    }
    return .{ .struct_bits = struct_bits, .g_bits = g_bits };
}

pub fn approxModelBitsCalibrated(alloc: std.mem.Allocator, gm: *const Grammar, calib: Calib) !f64 {
    const split = try approxModelBitsSplit(alloc, gm, calib);
    return split.struct_bits + split.g_bits;
}

/// Full approximate frame cost in bytes: root_bits (exact H0 identity,
/// Lane S showed real Huffman lands within ~0.5% of this) + approximate
/// model bits, under `calib`.
pub fn approxTotalBytes(alloc: std.mem.Allocator, gm: *const Grammar, calib: Calib) !f64 {
    const rc = try rootCounts(alloc, gm);
    defer alloc.free(rc.g);
    const root_bits = rootBitsExact(rc.g, rc.m);
    const model_bits = try approxModelBitsCalibrated(alloc, gm, calib);
    return (root_bits + model_bits) / 8.0;
}

/// Closed-loop MDL deletion: same round/candidate/simulate-and-halve
/// structure as `mdlDeleteFlat`, but each rule's "cost saved by deleting
/// it" comes from the calibrated per-rule model above instead of a flat
/// constant, and the accept/reject check compares the calibrated
/// approximate TOTAL byte cost (root + model), not just the flat root+13*n
/// objective.
pub fn mdlDeleteCalibrated(alloc: std.mem.Allocator, gm: *Grammar, calib: Calib, max_rounds: usize) !DeleteStats {
    var stats = DeleteStats{ .before_bytes = try approxTotalBytes(alloc, gm, calib) };
    var current_cost = stats.before_bytes;

    var round: usize = 0;
    while (round < max_rounds) : (round += 1) {
        const num_rules = gm.rules.items.len;
        if (num_rules == 0) break;

        const parent = try parentCounts(alloc, gm.rules.items);
        defer alloc.free(parent);
        const k = 256 + num_rules;
        const g = try alloc.alloc(u64, k);
        defer alloc.free(g);
        @memset(g, 0);
        for (gm.seq) |s| g[s] += 1;
        const mf: f64 = @floatFromInt(gm.seq.len);
        const live_f: f64 = @floatFromInt(@max(num_rules, 1));
        const log_live = log2f(@max(live_f, 2.0));

        var alive: []bool = try alloc.alloc(bool, num_rules);
        defer alloc.free(alive);
        @memset(alive, true);
        var cand_list: std.ArrayList(DeleteCand) = .empty;
        defer cand_list.deinit(alloc);
        var free_lunch: usize = 0;

        for (0..num_rules) |i| {
            if (parent[i] != 0) continue; // only top-level rules are safe to delete
            const r = gm.rules.items[i];
            const rid: u32 = @intCast(256 + i);
            const uses = g[rid];

            // Model-side saving: we no longer need to encode this rule's
            // own DEF (flag+gcount) or its own children's REF cost.
            var child_cost: f64 = 0;
            inline for ([_]u32{ r.a, r.b }) |child| {
                if (child < 256) {
                    child_cost += calib.byte_bits;
                } else {
                    const ci = child - 256;
                    if (parent[ci] <= 1 and g[child] == 0) {
                        // Was defined in place under this rule; deleting
                        // this rule doesn't remove that child's own DEF
                        // (still needed somewhere -- it becomes a fresh
                        // top-level DEF instead), just its inlining. We
                        // conservatively treat this as cost-neutral: 0.
                    } else {
                        child_cost += calib.ref_log_coeff * log_live;
                    }
                }
            }
            const model_saving = calib.flag_bits + gcountBitsApprox(uses, calib) + child_cost;

            if (uses == 0) {
                alive[i] = false;
                free_lunch += 1;
                continue;
            }

            // Root-side loss: exact M*log2(M) - sum(f(c)) identity, same
            // as mdlDeleteFlat.
            const uses_f: f64 = @floatFromInt(uses);
            const m_after = mf + uses_f;
            const delta_mlogm = m_after * log2f(m_after) - mf * log2f(mf);
            var delta_children: f64 = undefined;
            if (r.a == r.b) {
                delta_children = flog(g[r.a] + 2 * uses) - flog(g[r.a]);
            } else {
                delta_children = (flog(g[r.a] + uses) - flog(g[r.a])) + (flog(g[r.b] + uses) - flog(g[r.b]));
            }
            const removed_r_term = flog(uses);
            const root_loss_bits = delta_mlogm - delta_children + removed_r_term;
            const benefit = model_saving - root_loss_bits / 1.0; // both in bits
            if (benefit > 0) try cand_list.append(alloc, .{ .idx = @intCast(i), .benefit = benefit });
        }
        std.mem.sort(DeleteCand, cand_list.items, {}, deleteCandDesc);

        var accepted: usize = 0;
        var m: usize = cand_list.items.len;
        while (m > 0) {
            for (cand_list.items[0..m]) |c| alive[c.idx] = false;
            const cost_try = try simulateDeleteCostCalibrated(alloc, gm, alive, calib);
            if (cost_try < current_cost) {
                accepted = m;
                break;
            }
            for (cand_list.items[0..m]) |c| alive[c.idx] = true;
            m /= 2;
        }

        const deleted_this_round = free_lunch + accepted;
        if (deleted_this_round == 0) break;

        try applyDeletion(alloc, gm, alive);
        const new_cost = try approxTotalBytes(alloc, gm, calib);
        stats.deleted += deleted_this_round;
        stats.rounds += 1;
        current_cost = new_cost;
    }

    stats.after_bytes = current_cost;
    return stats;
}

fn simulateDeleteCostCalibrated(alloc: std.mem.Allocator, gm: *const Grammar, alive: []const bool, calib: Calib) !f64 {
    var tmp = try gm.clone(alloc);
    defer tmp.deinit(alloc);
    try applyDeletion(alloc, &tmp, alive);
    return approxTotalBytes(alloc, &tmp, calib);
}

/// Splice deleted rules' root occurrences back to their two children and
/// compact ids, preserving child-before-parent order. Shared by both
/// deletion passes' "commit" step (grammar2.mdlDelete inlined this; here
/// it's factored out so mdlDeleteCalibrated's real-application and
/// simulateDeleteCostCalibrated's what-if probe share one implementation).
fn applyDeletion(alloc: std.mem.Allocator, gm: *Grammar, alive: []const bool) !void {
    const num_rules = gm.rules.items.len;
    const k = 256 + num_rules;
    var new_seq: std.ArrayList(u32) = .empty;
    defer new_seq.deinit(alloc);
    var new_block_end: std.ArrayList(usize) = .empty;
    defer new_block_end.deinit(alloc);

    var start: usize = 0;
    for (gm.block_end) |end| {
        for (gm.seq[start..end]) |sym| {
            if (sym < 256 or alive[sym - 256]) {
                try new_seq.append(alloc, sym);
            } else {
                const r = gm.rules.items[sym - 256];
                try new_seq.append(alloc, r.a);
                try new_seq.append(alloc, r.b);
            }
        }
        try new_block_end.append(alloc, new_seq.items.len);
        start = end;
    }

    const remap = try alloc.alloc(u32, k);
    defer alloc.free(remap);
    var new_rules: std.ArrayList(Rule) = .empty;
    for (0..256) |b| remap[b] = @intCast(b);
    for (0..num_rules) |ri| {
        if (!alive[ri]) continue;
        const r = gm.rules.items[ri];
        const new_id: u32 = @intCast(256 + new_rules.items.len);
        try new_rules.append(alloc, .{ .a = remap[r.a], .b = remap[r.b] });
        remap[256 + ri] = new_id;
    }
    for (new_seq.items) |*s| s.* = remap[s.*];

    gm.rules.deinit(alloc);
    gm.rules = new_rules;
    alloc.free(gm.seq);
    gm.seq = try new_seq.toOwnedSlice(alloc);
    alloc.free(gm.block_end);
    gm.block_end = try new_block_end.toOwnedSlice(alloc);
}

// ------------------------------------------------------------- A4: reparse

const NO_SYM: u32 = std.math.maxInt(u32);

const Trie = struct {
    edge: std.AutoHashMap(u64, u32),
    accept: std.ArrayList(u32),
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) Trie {
        var t = Trie{ .edge = std.AutoHashMap(u64, u32).init(alloc), .accept = .empty, .alloc = alloc };
        t.accept.append(alloc, NO_SYM) catch @panic("oom");
        return t;
    }

    fn deinit(self: *Trie) void {
        self.edge.deinit();
        self.accept.deinit(self.alloc);
    }

    fn insert(self: *Trie, bytes: []const u8, sym: u32) !void {
        var node: u32 = 0;
        for (bytes) |byte| {
            const key = (@as(u64, node) << 8) | byte;
            const got = try self.edge.getOrPut(key);
            if (!got.found_existing) {
                const newnode: u32 = @intCast(self.accept.items.len);
                try self.accept.append(self.alloc, NO_SYM);
                got.value_ptr.* = newnode;
            }
            node = got.value_ptr.*;
        }
        if (self.accept.items[node] == NO_SYM) self.accept.items[node] = sym;
    }
};

fn materialize(alloc: std.mem.Allocator, rules: []const Rule, explen: []const u32, max_len: u32) ![]?[]u8 {
    const k = 256 + rules.len;
    const bytes = try alloc.alloc(?[]u8, k);
    for (0..256) |b| {
        const buf = try alloc.alloc(u8, 1);
        buf[0] = @intCast(b);
        bytes[b] = buf;
    }
    for (rules, 0..) |r, i| {
        const sym = 256 + i;
        if (explen[sym] > max_len or bytes[r.a] == null or bytes[r.b] == null) {
            bytes[sym] = null;
            continue;
        }
        const buf = try alloc.alloc(u8, explen[sym]);
        const abytes = bytes[r.a].?;
        const bbytes = bytes[r.b].?;
        @memcpy(buf[0..abytes.len], abytes);
        @memcpy(buf[abytes.len..], bbytes);
        bytes[sym] = buf;
    }
    return bytes;
}

pub const ReparseStats = struct {
    iterations: usize = 0,
    trie_symbols: usize = 0,
    before_bytes: f64 = 0,
    after_bytes: f64 = 0,
};

pub fn optimalReparse(alloc: std.mem.Allocator, gm: *Grammar, raw: []const u8, rule_bits: f64, max_len: u32, iterations: usize) !ReparseStats {
    const before = try costOf(alloc, gm, rule_bits);
    var stats = ReparseStats{ .before_bytes = before.total_bytes };

    const explen = try computeExplen(alloc, gm.rules.items);
    defer alloc.free(explen);
    const matbytes = try materialize(alloc, gm.rules.items, explen, max_len);
    defer {
        for (matbytes) |mb| if (mb) |b| alloc.free(b);
        alloc.free(matbytes);
    }
    var trie = Trie.init(alloc);
    defer trie.deinit();
    var trie_symbols: usize = 0;
    for (matbytes, 0..) |mb, sym| {
        if (mb) |b| {
            try trie.insert(b, @intCast(sym));
            trie_symbols += 1;
        }
    }
    stats.trie_symbols = trie_symbols;
    var current_cost = before.total_bytes;
    const num_rules = gm.rules.items.len;
    const k = gm.numSymbols();

    var iter: usize = 0;
    while (iter < iterations) : (iter += 1) {
        const g = try alloc.alloc(u64, k);
        defer alloc.free(g);
        @memset(g, 0);
        for (gm.seq) |s| g[s] += 1;
        const mf: f64 = @floatFromInt(gm.seq.len);
        const bits = try alloc.alloc(f64, k);
        defer alloc.free(bits);
        for (0..k) |s| bits[s] = bitsOfCount(g[s], mf);

        var new_seq: std.ArrayList(u32) = .empty;
        var new_block_end: std.ArrayList(usize) = .empty;
        var raw_start: usize = 0;
        var dp: std.ArrayList(f64) = .empty;
        defer dp.deinit(alloc);
        var from_sym: std.ArrayList(u32) = .empty;
        defer from_sym.deinit(alloc);
        var from_pos: std.ArrayList(u32) = .empty;
        defer from_pos.deinit(alloc);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(alloc);

        while (raw_start < raw.len) {
            const raw_end = @min(raw.len, raw_start + gm.block_bytes);
            const block = raw[raw_start..raw_end];
            const l = block.len;

            dp.clearRetainingCapacity();
            try dp.appendNTimes(alloc, std.math.inf(f64), l + 1);
            from_sym.clearRetainingCapacity();
            try from_sym.appendNTimes(alloc, 0, l + 1);
            from_pos.clearRetainingCapacity();
            try from_pos.appendNTimes(alloc, 0, l + 1);
            dp.items[0] = 0;

            var i: usize = 0;
            while (i < l) : (i += 1) {
                if (!std.math.isFinite(dp.items[i])) continue;
                var node: u32 = 0;
                var j = i;
                while (j < l) {
                    const key = (@as(u64, node) << 8) | block[j];
                    const nxt = trie.edge.get(key) orelse break;
                    node = nxt;
                    j += 1;
                    const sym = trie.accept.items[node];
                    if (sym != NO_SYM) {
                        const cand = dp.items[i] + bits[sym];
                        if (cand < dp.items[j]) {
                            dp.items[j] = cand;
                            from_sym.items[j] = sym;
                            from_pos.items[j] = @intCast(i);
                        }
                    }
                }
            }

            stack.clearRetainingCapacity();
            var pos: usize = l;
            while (pos > 0) {
                try stack.append(alloc, from_sym.items[pos]);
                pos = from_pos.items[pos];
            }
            var idx = stack.items.len;
            while (idx > 0) {
                idx -= 1;
                try new_seq.append(alloc, stack.items[idx]);
            }
            try new_block_end.append(alloc, new_seq.items.len);
            raw_start = raw_end;
        }

        const g_new = try alloc.alloc(u64, k);
        defer alloc.free(g_new);
        @memset(g_new, 0);
        for (new_seq.items) |s| g_new[s] += 1;
        const cost_new = objective(g_new, new_seq.items.len, num_rules, rule_bits, null).total_bytes;

        if (cost_new < current_cost) {
            current_cost = cost_new;
            alloc.free(gm.seq);
            gm.seq = try new_seq.toOwnedSlice(alloc);
            alloc.free(gm.block_end);
            gm.block_end = try new_block_end.toOwnedSlice(alloc);
        } else {
            new_seq.deinit(alloc);
            new_block_end.deinit(alloc);
            break;
        }
    }

    stats.iterations = iterations;
    stats.after_bytes = current_cost;
    return stats;
}

test "build + verifyExact on tiny input" {
    const alloc = std.testing.allocator;
    const input = "abababab abababab";
    var gm = try build(alloc, input, 8, .{ .priority = .saving });
    defer gm.deinit(alloc);
    try std.testing.expect(try verifyExact(alloc, input, &gm));
}

test "mdlDeleteCalibrated preserves exactness" {
    const alloc = std.testing.allocator;
    const input = "the quick brown fox jumps over the lazy dog. the quick brown fox jumps over the lazy dog again and again.";
    var gm = try build(alloc, input, 32, .{ .priority = .saving });
    defer gm.deinit(alloc);
    _ = try mdlDeleteCalibrated(alloc, &gm, Calib.default(), 8);
    try std.testing.expect(try verifyExact(alloc, input, &gm));
}
