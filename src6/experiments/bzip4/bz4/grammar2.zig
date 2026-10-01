//! grammar2.zig — Lane A grammar builder: baseline (A1, copied from gprobe's
//! algorithm) plus the improvements this lane measured: MDL deletion (A2),
//! saving-priority pair selection (A3), optimal DP re-parse (A4), structural
//! ("deftree") rule accounting (A5), and builder speed-ups (A6: flat 65536
//! first-pass counting + hash tables sized to distinct pairs).
//!
//! Pure Zig 0.16, std only. See LANE_A.md for the experiment notebook and
//! PLAN.md for the shared contract (dump format, objective function, rules
//! of evidence).

const std = @import("std");

pub const Rule = extern struct { a: u32, b: u32 };

pub const Priority = enum { freq, saving };

pub const BuildOpts = struct {
    max_rules: usize = 1_000_000,
    min_freq: u32 = 2,
    alpha_percent: u32 = 50,
    priority: Priority = .freq,
    /// A6: flat-array first pass + hash tables sized to distinct pairs.
    /// false reproduces gprobe's original always-hash-table behaviour.
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

    /// Deep copy (needed because several experiments mutate a grammar
    /// in place but we want to keep the original for comparison).
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

/// Static order-0 code length (bits) for a symbol with count `count` out of
/// `m` total roots. Symbols that currently have zero roots (structural
/// rules, or rules a re-parse might revive) get a small-probability
/// fallback so priority/benefit heuristics stay finite; the *reported*
/// objective always uses real post-hoc counts, never this fallback.
pub inline fn bitsOfCount(count: u64, m: f64) f64 {
    if (count > 0) return -log2f(@as(f64, @floatFromInt(count)) / m);
    return -log2f(0.5 / m);
}

/// f(c) = c*log2(c), with f(0) = 0. Useful because
/// sum_s -c_s*log2(c_s/M) == M*log2(M) - sum_s f(c_s), which makes the
/// effect of shifting counts between symbols (as A2's deletion does)
/// exact and cheap to evaluate without walking the whole distribution.
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
            // ---- A6: flat 65536-entry first pass, no hashing at all. ----
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
            // ---- hash-table path (all rounds when fast_count=false, or
            //      rounds 1+ when fast_count=true). ----
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
    return .{ .rules = rules, .seq = seq[0..live], .block_end = block_end, .block_bytes = block_bytes, .passes = passes };
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

/// cost(grammar) = sum over roots of -log2(g[s]/M)
///               + rule_bits * num_rules
///               + 2.5 bits * |{s : g[s]>0 or s is a rule}|
/// `trivial`, if given, is a per-rule mask of "single-parent, g=0"
/// structural rules that get charged 1.5 bits instead of `rule_bits`
/// (the est-deftree variant, A5).
pub fn objective(g: []const u64, m: u64, num_rules: usize, rule_bits: f64, trivial: ?[]const bool) Cost {
    const mf: f64 = @floatFromInt(m);
    var root_bits: f64 = 0;
    var side_syms: usize = 0;
    for (g, 0..) |c, s| {
        if (c == 0) continue;
        root_bits -= @as(f64, @floatFromInt(c)) * log2f(@as(f64, @floatFromInt(c)) / mf);
        if (s < 256) side_syms += 1;
    }
    side_syms += num_rules; // every rule needs a side-info slot regardless of g
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

/// A5: which rules are "single parent, never a root" structural filler.
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

/// Expand every block's roots and compare against the raw input, byte for
/// byte, with no rule spanning a block barrier. Must pass on every run.
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

pub var debug_delete: bool = false;

pub const DeleteStats = struct {
    deleted: usize = 0,
    rounds: usize = 0,
    before_bytes: f64 = 0,
    after_bytes: f64 = 0,
};

/// Repeatedly find rules that are nobody's child (safe to delete without
/// breaking the binary-DAG invariant) whose removal lowers the objective,
/// splice their root occurrences back to (a,b), and compact ids. Runs in
/// rounds because deleting a rule can make its own children newly
/// deletable (their parent count drops), and each round's benefit
/// estimate is recomputed from the *current* counts, per PLAN.
const DeleteCand = struct { idx: u32, benefit: f64 };

fn deleteCandDesc(_: void, x: DeleteCand, y: DeleteCand) bool {
    return x.benefit > y.benefit;
}

/// Recount the objective as if every rule index in `alive` marked false
/// were deleted (its root occurrences replaced by its two children).
/// Because a rule with parent_count 0 can never be the child of another
/// parent_count-0 rule (the reference itself would give it a nonzero
/// parent count), one level of substitution is always enough here — no
/// recursive/chained expansion needed for this single-round simulation.
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

pub fn mdlDelete(alloc: std.mem.Allocator, gm: *Grammar, rule_bits: f64, max_rounds: usize) !DeleteStats {
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

        // Score every structurally-safe rule (parent_count 0). A rule with
        // parent_count 0 is, by construction, only ever seen as a root, so
        // g[256+i] is its exact use count. Its children may currently have
        // zero root occurrences (purely structural symbols) — "their
        // current cost" is undefined then, so we score by the cost each
        // child would have AFTER this one isolated deletion: (g[child] +
        // extra) roots out of (M + uses). Exact in isolation; batches of
        // several deletions still interact, which the binary search below
        // guards against by checking the real objective.
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
                // No root occurrences to rewrite at all: pure win, no
                // interaction with anything else. Take it unconditionally.
                alive[i] = false;
                free_lunch += 1;
                continue;
            }
            // Exact isolated-deletion delta. root_bits = sum_s -c_s*log2(c_s/M)
            // = M*log2(M) - sum_s f(c_s) where f(c)=c*log2(c) (f(0)=0), so
            // shifting `uses` roots from R onto its children changes
            // root_bits by (M' log2 M' - M log2 M) - (children f-delta) +
            // f(uses). This is the piece the earlier "average bits" version
            // missed: M itself grows, which very slightly taxes EVERY other
            // root too, and summed over ~M of them that is not negligible.
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

        // Ranked candidates can interact (several can dump uses onto the
        // same child), so try the whole ranked prefix first and, if that
        // regresses, keep halving it until a prefix size actually lowers
        // the real objective (or nothing smaller than 1 does, in which
        // case we take none). Not guaranteed to find the largest such
        // prefix, but simple, fast (O(log n) simulations), and safe.
        var accepted: usize = 0;
        var m: usize = cand_list.items.len;
        while (m > 0) {
            for (cand_list.items[0..m]) |c| alive[c.idx] = false;
            const cost_try = try simulateDeleteCost(alloc, gm, alive, rule_bits);
            if (debug_delete) std.debug.print("      probe m={d} cost_try={d:.0} current={d:.0}\n", .{ m, cost_try, current_cost });
            if (cost_try < current_cost) {
                accepted = m;
                break;
            }
            for (cand_list.items[0..m]) |c| alive[c.idx] = true; // reset probe
            m /= 2;
        }

        const deleted_this_round = free_lunch + accepted;
        if (debug_delete) std.debug.print("    [mdl round {d}] parent0_rules={d} candidates_with_benefit={d} free_lunch={d}\n", .{ round, num_rules, cand_list.items.len, free_lunch });
        if (deleted_this_round == 0) break;
        if (debug_delete) std.debug.print("    [mdl round {d}] free_lunch={d} ranked_accepted={d}/{d}\n", .{ round, free_lunch, accepted, cand_list.items.len });

        // Splice every occurrence of a deleted rule back into its two
        // children (one level; see simulateDeleteCost for why that's enough).
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

        // Compact rule ids, preserving relative order (keeps child < parent).
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

        if (debug_delete) std.debug.print("    [mdl round {d}] cost {d:.0} -> {d:.0} ({s})\n", .{ round, current_cost, cost_new, if (cost_new < current_cost) "accept" else "reject" });
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
            break; // shouldn't happen (free_lunch alone can't regress) but stay safe
        }
    }

    stats.after_bytes = current_cost;
    return stats;
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

/// Materialise expansion bytes for every symbol whose expansion length is
/// <= max_len (skipped symbols, and anything built from them, are simply
/// left out of the re-parse trie — a bounded approximation, not unsound).
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

/// A4: given the FINAL rule set, re-tokenise each block with a shortest
/// total-code-length DP over a trie of all (bounded-length) expansions,
/// then recount roots and repeat `iterations` times.
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
    const k = gm.numSymbols(); // reparse never changes the rule set, only tokens

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

            // Backtrack (dp.items[l] is always finite: single bytes always match).
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

        // The DP only minimises sum(bits[s]) under the OLD, now-stale
        // per-symbol code lengths; once we recount, the true objective
        // (self-referential: the code lengths depend on the very parse
        // being chosen) can end up worse, especially on the first
        // iteration or once it has converged. Verify and stop rather
        // than drift.
        const g_new = try alloc.alloc(u64, k);
        defer alloc.free(g_new);
        @memset(g_new, 0);
        for (new_seq.items) |s| g_new[s] += 1;
        const cost_new = objective(g_new, new_seq.items.len, num_rules, rule_bits, null).total_bytes;
        if (debug_delete) std.debug.print("    [reparse iter {d}] cost {d:.0} -> {d:.0} ({s})\n", .{ iter, current_cost, cost_new, if (cost_new < current_cost) "accept" else "reject" });

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
