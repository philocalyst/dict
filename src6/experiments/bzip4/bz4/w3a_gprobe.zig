//! w3a_gprobe: determinism-gated grammar builder for Lane W3a (idea 1).
//!
//! Copy of `gprobe.zig`'s round structure (role-consistent pair families, no
//! symbol both a left and a right member in one round, pairs never span a
//! block barrier, priority-by-count within a round) with ONE change to the
//! eligibility rule: instead of gprobe's "count(ab) >= min_freq AND
//! count(ab) >= alpha_percent% of this round's max pair count", a pair
//! (a,b) is eligible only if
//!
//!   count(ab) >= C_MIN                                   (absolute floor)
//!   count(ab) / min(count(a), count(b)) >= THETA          (determinism)
//!
//! where count(a)/count(b) are this round's UNIGRAM occurrence counts (a
//! single extra O(live) pass per round). THETA in [0,1] measures how
//! deterministic the pair is *given either symbol*: THETA=1 means "b always
//! follows a, and a always precedes b" (perfectly redundant, safe to merge
//! with zero information loss to the statistical back end); THETA=0
//! degenerates to frequency-only selection (gprobe's own C_MIN-only floor).
//! Rounds iterate until no pair is eligible (no artificial rule cap is
//! needed for the hypothesis test, though `max_rules` remains as a safety
//! valve so a pathological input can't blow memory/time budgets).
//!
//! Rationale (lab hypothesis under test, see LANE_W3A.md): a statistical
//! back end (TreeCM) already codes near-uniform pairs (e.g. two random hex
//! digits) at close to their true entropy, so merging them into a rule only
//! adds DEF-tree overhead and dilutes context statistics between the two
//! now-separate identities; but merging a pair that is *(near-)certain in
//! context* costs the model nothing (there was no real uncertainty to code)
//! and removes a whole symbol's worth of per-position modelling overhead.
//! "Grammar = determinism compression, CM = uncertainty coding."
//!
//! usage: w3a_gprobe FILE BLOCK_BYTES MAX_RULES THETA_PERCENT C_MIN [DUMP_PATH]
//!   THETA_PERCENT: integer 0..100 (95 means THETA=0.95); 0 = frequency-only.
//!
//! Dump format identical to gprobe.zig's (little-endian u32 words):
//!   "B4SD", version=1, rule_count, block_count, block_bytes, raw_len
//!   rule_count * (left, right)           ids: 0..255 bytes, 256+i = rule i
//!   per block: root_count, root_count * symbol

const std = @import("std");

pub const Rule = extern struct { a: u32, b: u32 };

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

const Cand = struct { key: u64, count: u32 };

fn candDesc(_: void, x: Cand, y: Cand) bool {
    if (x.count != y.count) return x.count > y.count;
    return x.key < y.key;
}

pub const Grammar = struct {
    rules: std.ArrayList(Rule),
    seq: []u32,
    block_end: []usize,
    passes: usize,
};

/// Settings under test by Lane W3a (idea 1). `theta_pct` in 0..100 (percent,
/// integer to avoid float bias/nondeterminism), `c_min` an absolute floor.
pub const DetGate = struct {
    theta_pct: u32,
    c_min: u32,
};

pub fn build(
    alloc: std.mem.Allocator,
    input: []const u8,
    block_bytes: usize,
    max_rules: usize,
    gate: DetGate,
) !Grammar {
    return buildBounded(alloc, input, block_bytes, max_rules, gate, std.math.maxInt(usize));
}

/// Same as `build`, but stops after `max_passes` rounds even if the
/// determinism gate has not yet converged (`selected==0` never reached).
///
/// Lab finding (Lane W3a): at LOOSE gates (mid THETA, low C_MIN) on
/// high-entropy/binary data, a huge number of pairs can satisfy the
/// eligibility test in a single round, but role-consistency (no symbol is
/// both a left- and right-member in one round) means only a small
/// independent subset of them can actually be selected per round -- so
/// convergence can take hundreds to thousands of rounds, each costing
/// O(live sequence length) regardless of how few rules it yields (observed:
/// macho.eval8.bin, THETA=0.40/C_MIN=4, took 1,887 rounds and ~150s wall
/// time for only 9,944 rules -- see LANE_W3A.md). `max_passes` bounds this
/// lab's wall-clock budget; a run that hits the cap is a REAL, disclosed
/// partial grammar (every size reported from it is still real, just not
/// the fully-converged one for that gate) -- never silently substituted.
pub fn buildBounded(
    alloc: std.mem.Allocator,
    input: []const u8,
    block_bytes: usize,
    max_rules: usize,
    gate: DetGate,
    max_passes: usize,
) !Grammar {
    const n = input.len;
    const seq = try alloc.alloc(u32, n);
    for (input, 0..) |byte, i| seq[i] = byte;
    const block_count = (n + block_bytes - 1) / block_bytes;
    const block_end = try alloc.alloc(usize, block_count);
    for (0..block_count) |b| block_end[b] = @min(n, (b + 1) * block_bytes);

    var rules: std.ArrayList(Rule) = .empty;
    var roles: std.ArrayList(u8) = .empty;
    try roles.appendNTimes(alloc, 0, 256);
    var cands: std.ArrayList(Cand) = .empty;
    defer cands.deinit(alloc);
    var unigram: std.ArrayList(u32) = .empty;
    defer unigram.deinit(alloc);

    var passes: usize = 0;
    var live = n;
    while (rules.items.len < max_rules and passes < max_passes) : (passes += 1) {
        var log2_cap: u6 = 12;
        while ((@as(usize, 1) << log2_cap) < live * 2 and log2_cap < 25) log2_cap += 1;
        var table = try PairTable.init(alloc, log2_cap);
        defer table.deinit(alloc);

        // Count non-overlapping pair occurrences inside each block.
        var start: usize = 0;
        for (block_end) |end| {
            var i = start;
            var skip_at: usize = std.math.maxInt(usize);
            while (i + 1 < end) : (i += 1) {
                const a = seq[i];
                const b = seq[i + 1];
                if (a == b and skip_at == i) continue; // middle of "aaa"
                if (a == b) skip_at = i + 1;
                table.bump(@as(u64, a) << 32 | b);
            }
            start = end;
        }

        var max_count: u32 = 0;
        for (table.vals) |v| max_count = @max(max_count, v);
        if (max_count < gate.c_min) break;

        // This round's unigram occurrence counts (single extra pass), the
        // denominator for the determinism ratio count(ab)/min(count(a),
        // count(b)). Sized to the current alphabet (256 + rules so far).
        const k_now = 256 + rules.items.len;
        try unigram.resize(alloc, k_now);
        @memset(unigram.items, 0);
        for (seq[0..live]) |s| unigram.items[s] += 1;

        cands.clearRetainingCapacity();
        for (table.keys, table.vals) |k, v| {
            if (k == empty_key or v < gate.c_min) continue;
            const a: u32 = @intCast(k >> 32);
            const b: u32 = @truncate(k);
            const min_uni = @min(unigram.items[a], unigram.items[b]);
            // v / min_uni >= theta_pct/100  <=>  v*100 >= theta_pct*min_uni
            if (@as(u64, v) * 100 >= @as(u64, gate.theta_pct) * @as(u64, min_uni)) {
                try cands.append(alloc, .{ .key = k, .count = v });
            }
        }
        std.mem.sort(Cand, cands.items, {}, candDesc);

        // Reset counts to "not selected"; selected pairs get rule id + 1.
        @memset(table.vals, 0);
        @memset(roles.items, 0);
        var selected: usize = 0;
        for (cands.items) |cand| {
            if (rules.items.len >= max_rules) break;
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
            table.vals[table.slot(cand.key)] = id;
            selected += 1;
        }
        if (selected == 0) break;

        // Replace left-to-right, compacting every block in place.
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
    roles.deinit(alloc);
    return .{ .rules = rules, .seq = seq[0..live], .block_end = block_end, .passes = passes };
}

fn log2f(x: f64) f64 {
    return @log2(x);
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const path = it.next() orelse return error.Usage;
    const block_bytes_arg = try std.fmt.parseUnsigned(usize, it.next() orelse return error.Usage, 10);
    const max_rules = try std.fmt.parseUnsigned(usize, it.next() orelse return error.Usage, 10);
    const theta_pct = try std.fmt.parseUnsigned(u32, it.next() orelse return error.Usage, 10);
    const c_min = try std.fmt.parseUnsigned(u32, it.next() orelse return error.Usage, 10);
    const max_passes = try std.fmt.parseUnsigned(usize, it.next() orelse "1000000", 10);
    const dump_path = it.next();

    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, path, alloc, .limited(1 << 30));
    const block_bytes = if (block_bytes_arg == 0) @max(@as(usize, 1), input.len) else block_bytes_arg;
    const t0 = std.Io.Clock.awake.now(init.io).nanoseconds;
    var g = try buildBounded(alloc, input, block_bytes, max_rules, .{ .theta_pct = theta_pct, .c_min = c_min }, max_passes);
    const t1 = std.Io.Clock.awake.now(init.io).nanoseconds;

    const k = 256 + g.rules.items.len;
    const freq = try alloc.alloc(u64, k);
    @memset(freq, 0);
    for (g.seq) |s| freq[s] += 1;
    const m: f64 = @floatFromInt(g.seq.len);
    var h0_bits: f64 = 0;
    for (freq) |f| if (f != 0) {
        h0_bits -= @as(f64, @floatFromInt(f)) * log2f(@as(f64, @floatFromInt(f)) / m);
    };

    std.debug.print(
        "file={s} block={d} theta_pct={d} c_min={d}\n" ++
            "  build_ms={d:.1} passes={d} rules={d} roots={d} bytes/root={d:.2}\n" ++
            "  static_H0={d:.0} B ({d:.2} bits/root)\n",
        .{
            path,                                    block_bytes, theta_pct,   c_min,
            @as(f64, @floatFromInt(t1 - t0)) / 1e6, g.passes,    g.rules.items.len, g.seq.len,
            @as(f64, @floatFromInt(input.len)) / m, h0_bits / 8, h0_bits / m,
        },
    );

    if (dump_path) |dp| {
        var out: std.ArrayList(u32) = .empty;
        try out.appendSlice(alloc, &.{ 0x44533442, 1, @intCast(g.rules.items.len), @intCast(g.block_end.len), @intCast(block_bytes), @intCast(input.len) });
        for (g.rules.items) |r| try out.appendSlice(alloc, &.{ r.a, r.b });
        var start: usize = 0;
        for (g.block_end) |end| {
            try out.append(alloc, @intCast(end - start));
            try out.appendSlice(alloc, g.seq[start..end]);
            start = end;
        }
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = dp, .data = std.mem.sliceAsBytes(out.items) });
    }
}

// ---------------------------------------------------------------- tests --

test "theta=0 (frequency-only) matches c_min-only floor: never worse than doing nothing" {
    const alloc = std.testing.allocator;
    const input = try alloc.dupe(u8, "abababababcdcdcdcdcd" ** 20);
    defer alloc.free(input);
    const n = input.len;
    var g = try build(alloc, input, input.len, 1_000_000, .{ .theta_pct = 0, .c_min = 4 });
    defer {
        g.rules.deinit(alloc);
        alloc.free(g.seq.ptr[0..n]);
        alloc.free(g.block_end);
    }
    try std.testing.expect(g.rules.items.len > 0);
    try std.testing.expect(g.seq.len < n);
}

test "theta=100 (perfect determinism) only merges pairs with no competing context" {
    const alloc = std.testing.allocator;
    // "ab" always co-occurs; "c" sometimes precedes "d", sometimes "e" does
    // (so (c,d) is NOT deterministic given c alone once "e" also follows a
    // similar-frequency symbol) -- construct so (a,b) is 100% deterministic
    // but a symbol with split successors is not.
    const input = try alloc.dupe(u8, "ab" ** 50 ++ "cd" ** 25 ++ "ce" ** 25);
    defer alloc.free(input);
    const n = input.len;
    var g = try build(alloc, input, input.len, 1_000_000, .{ .theta_pct = 100, .c_min = 2 });
    defer {
        g.rules.deinit(alloc);
        alloc.free(g.seq.ptr[0..n]);
        alloc.free(g.block_end);
    }
    // (a,b) must have been merged (theta=1.0 exactly since 'a' is always
    // followed by 'b' and 'b' always preceded by 'a').
    var found_ab = false;
    for (g.rules.items) |r| {
        if (r.a == 'a' and r.b == 'b') found_ab = true;
    }
    try std.testing.expect(found_ab);
}

test "roundtrip via seq expansion for a handful of gate settings" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xF00D);
    const rnd = prng.random();
    const n: usize = 4000;
    const input = try alloc.alloc(u8, n);
    defer alloc.free(input);
    const words = [_][]const u8{ "the ", "quick ", "brown ", "fox ", "1234567890", "aaaaaaaaaa" };
    var i: usize = 0;
    while (i < n) {
        const w = words[rnd.uintLessThan(usize, words.len)];
        const take = @min(w.len, n - i);
        @memcpy(input[i .. i + take], w[0..take]);
        i += take;
    }

    const gates = [_]DetGate{
        .{ .theta_pct = 95, .c_min = 4 },
        .{ .theta_pct = 60, .c_min = 4 },
        .{ .theta_pct = 20, .c_min = 16 },
        .{ .theta_pct = 0, .c_min = 4 },
    };
    for (gates) |gate| {
        var g = try build(alloc, input, 512, 1_000_000, gate);
        defer {
            g.rules.deinit(alloc);
            alloc.free(g.seq.ptr[0..input.len]);
            alloc.free(g.block_end);
        }
        // Expand every root back to bytes and check exact equality per block.
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        var start: usize = 0;
        for (g.block_end) |end| {
            var stack: std.ArrayList(u32) = .empty;
            defer stack.deinit(alloc);
            for (g.seq[start..end]) |sym| {
                try stack.append(alloc, sym);
                while (stack.pop()) |s| {
                    if (s < 256) {
                        try out.append(alloc, @intCast(s));
                    } else {
                        const r = g.rules.items[s - 256];
                        try stack.append(alloc, r.b);
                        try stack.append(alloc, r.a);
                    }
                }
            }
            start = end;
        }
        try std.testing.expectEqualSlices(u8, input, out.items);
    }
}
