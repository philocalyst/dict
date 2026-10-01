//! gprobe: quick grammar probe + symbol-stream dumper for the bz4 lab.
//!
//! Builds a pair grammar with rounds of role-consistent pair families (no
//! symbol is both a left and a right member in one round), never letting a
//! pair span a block barrier, then reports root counts and idealised costs
//! and optionally dumps rules + per-block root streams for the entropy lab.
//!
//! usage: gprobe FILE BLOCK_BYTES MAX_RULES MIN_FREQ ALPHA_PERCENT [DUMP_PATH]
//!
//! Dump format (little-endian u32 words):
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

pub fn build(
    alloc: std.mem.Allocator,
    input: []const u8,
    block_bytes: usize,
    max_rules: usize,
    min_freq: u32,
    alpha_percent: u32,
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

    var passes: usize = 0;
    var live = n;
    while (rules.items.len < max_rules) : (passes += 1) {
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
        if (max_count < min_freq) break;
        const thr = @max(min_freq, @as(u32, @intCast((@as(u64, max_count) * alpha_percent + 99) / 100)));

        cands.clearRetainingCapacity();
        for (table.keys, table.vals) |k, v| {
            if (k != empty_key and v >= thr) try cands.append(alloc, .{ .key = k, .count = v });
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
    const block_bytes = try std.fmt.parseUnsigned(usize, it.next() orelse return error.Usage, 10);
    const max_rules = try std.fmt.parseUnsigned(usize, it.next() orelse return error.Usage, 10);
    const min_freq = try std.fmt.parseUnsigned(u32, it.next() orelse return error.Usage, 10);
    const alpha = try std.fmt.parseUnsigned(u32, it.next() orelse return error.Usage, 10);
    const dump_path = it.next();

    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, path, alloc, .limited(1 << 30));
    const t0 = std.Io.Clock.awake.now(init.io).nanoseconds;
    var g = try build(alloc, input, block_bytes, max_rules, min_freq, alpha);
    const t1 = std.Io.Clock.awake.now(init.io).nanoseconds;

    const k = 256 + g.rules.items.len;
    const freq = try alloc.alloc(u64, k);
    @memset(freq, 0);
    for (g.seq) |s| freq[s] += 1;
    const m: f64 = @floatFromInt(g.seq.len);
    var h0_bits: f64 = 0;
    var used_syms: usize = 0;
    for (freq) |f| if (f != 0) {
        used_syms += 1;
        h0_bits -= @as(f64, @floatFromInt(f)) * log2f(@as(f64, @floatFromInt(f)) / m);
    };
    // Children stream order-0 entropy: a crude proxy for explicit grammar cost.
    const cfreq = try alloc.alloc(u64, k);
    @memset(cfreq, 0);
    for (g.rules.items) |r| {
        cfreq[r.a] += 1;
        cfreq[r.b] += 1;
    }
    var child_bits: f64 = 0;
    const cm: f64 = @floatFromInt(2 * g.rules.items.len);
    for (cfreq) |f| if (f != 0) {
        child_bits -= @as(f64, @floatFromInt(f)) * log2f(@as(f64, @floatFromInt(f)) / cm);
    };
    // Per-block distinct counts (sparsity indicator).
    var distinct_total: usize = 0;
    {
        const seen = try alloc.alloc(u32, k);
        @memset(seen, std.math.maxInt(u32));
        var start: usize = 0;
        for (g.block_end, 0..) |end, b| {
            for (g.seq[start..end]) |s| {
                if (seen[s] != b) {
                    seen[s] = @intCast(b);
                    distinct_total += 1;
                }
            }
            start = end;
        }
    }
    var unused_rules: usize = 0;
    for (freq[256..]) |f| if (f == 0) {
        unused_rules += 1;
    };

    std.debug.print(
        "file={s} block={d} max_rules={d} min_freq={d} alpha={d}\n" ++
            "  build_ms={d:.1} passes={d} rules={d} (root-unused {d}) roots={d} bytes/root={d:.2} used_syms={d}\n" ++
            "  static_H0={d:.0} B ({d:.2} bits/root)  children_H0={d:.0} B ({d:.2} bits/rule)  sum={d:.0} B\n" ++
            "  blocks={d} avg_roots/block={d:.0} avg_distinct/block={d:.0}\n",
        .{
            path,                                                       block_bytes,                                max_rules,                                                   min_freq,                                       alpha,
            @as(f64, @floatFromInt(t1 - t0)) / 1e6,                     g.passes,                                   g.rules.items.len,                                           unused_rules,                                   g.seq.len,
            @as(f64, @floatFromInt(input.len)) / m,                     used_syms,                                  h0_bits / 8,                                                 h0_bits / m,                                    child_bits / 8,
            if (g.rules.items.len == 0) 0 else child_bits / (cm / 2), (h0_bits + child_bits) / 8,                 g.block_end.len,                                             m / @as(f64, @floatFromInt(g.block_end.len)),
            @as(f64, @floatFromInt(distinct_total)) / @as(f64, @floatFromInt(g.block_end.len)),
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
