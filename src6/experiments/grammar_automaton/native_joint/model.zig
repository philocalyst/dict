//! The static model: buckets, and rows of a finite-state transducer.
//!
//! Symbols `0..K` are buckets, symbol `K` is `DEF`, `K + 1` is `CUT`, and
//! the top `silent` symbols of the alphabet emit nothing: they only move to
//! another row, so one token may be spelled by several small decisions
//! (class, then tier). Bucket 0 is the 256 bytes. Buckets `1 ..= ring` are
//! not stored at all: they are windows on the stream's own past, the one of
//! width `w` reaching the tokens `2^w - 1 ... 2^(w+1) - 2` places back.
//!
//! A *plain* row carries no raw bits; the arity row (symbol = child count),
//! the cut row (symbol = bytes kept) and the name rows (symbol = bucket
//! joined) are plain. Every cell names the row that follows it, so context
//! modelling of any shape is a property of the tables. Each row has its own
//! table size (`logs`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const bits = @import("bits.zig");
const binary = @import("binary.zig");
const tans = @import("tans.zig");

/// The past is kept this many tokens deep, so `ring <= ring_log`.
pub const ring_log = 12;
pub const min_log = tans.min_log;
pub const byte_bucket = 0;

/// Every feature is known before the next payload token. The selector state
/// is reconstructed from prior decoded tokens, and resets at each payload
/// block. Feature choice and all sparse row keys are archive metadata.
pub const Feature = enum(u8) {
    none = 0,
    suffix1 = 1,
    suffix2 = 2,
    suffix3 = 3,
    suffix4 = 4,
    previous_kind = 5,
    previous_length_bin = 6,
    second_base_row = 7,
    two_kinds = 8,
    kind_length = 9,
    suffix1_kind = 10,
    suffix2_kind = 11,
    previous_first_symbol = 12,
    stream = 13,
};

pub const Context = struct {
    is_delta: bool = false,
    suffix: u32 = 0,
    suffix_len: u8 = 0,
    previous_kind: u8 = 255,
    second_kind: u8 = 255,
    previous_length_bin: u8 = 0,
    second_base_row: u16 = std.math.maxInt(u16),
    previous_first_symbol: u16 = std.math.maxInt(u16),

    pub fn key(c: Context, feature: Feature) ?u32 {
        return switch (feature) {
            .none => null,
            .suffix1 => if (c.suffix_len >= 1) c.suffix & 0xff else null,
            .suffix2 => if (c.suffix_len >= 2) c.suffix & 0xffff else null,
            .suffix3 => if (c.suffix_len >= 3) c.suffix & 0xffffff else null,
            .suffix4 => if (c.suffix_len >= 4) c.suffix else null,
            .previous_kind => if (c.previous_kind < 4) c.previous_kind else null,
            .previous_length_bin => if (c.previous_kind < 4) c.previous_length_bin else null,
            .second_base_row => if (c.second_base_row != std.math.maxInt(u16)) c.second_base_row else null,
            .two_kinds => if (c.second_kind < 4 and c.previous_kind < 4) @as(u32, c.second_kind) * 4 + c.previous_kind else null,
            .kind_length => if (c.previous_kind < 4) @as(u32, c.previous_kind) * 32 + c.previous_length_bin else null,
            .suffix1_kind => if (c.suffix_len >= 1 and c.previous_kind < 4) @as(u32, c.suffix & 0xff) * 4 + c.previous_kind else null,
            .suffix2_kind => if (c.suffix_len >= 2 and c.previous_kind < 4) @as(u32, c.suffix & 0xffff) * 4 + c.previous_kind else null,
            .previous_first_symbol => if (c.previous_first_symbol != std.math.maxInt(u16)) c.previous_first_symbol else null,
            .stream => @intFromBool(c.is_delta),
        };
    }

    pub fn push(c: *Context, token: []const u8, kind: u8, first_symbol: u16, base_row: u16) void {
        c.pushSummary(token[token.len -| 4 ..], token.len, kind, first_symbol, base_row);
    }

    pub fn pushSummary(c: *Context, tail: []const u8, token_len: usize, kind: u8, first_symbol: u16, base_row: u16) void {
        c.second_kind = c.previous_kind;
        c.previous_kind = kind;
        c.previous_length_bin = @intCast(@min(16, std.math.log2_int(usize, @max(1, token_len))));
        c.second_base_row = base_row;
        c.previous_first_symbol = first_symbol;
        if (token_len >= 4) {
            c.suffix = 0;
            c.suffix_len = 0;
        }
        for (tail) |b| {
            c.suffix = (c.suffix << 8) | b;
            c.suffix_len = @min(4, c.suffix_len + 1);
        }
    }
};

/// Several keys may share one learned row. `target` is an offset from
/// `base_rows`; its cost is serialized for every selector.
pub const Selector = struct { base_row: u16, key: u32, target: u16 = 0 };

pub const Model = struct {
    log: u8,
    widths: []u8,
    /// Buckets `1 ..= ring` look into the past.
    ring: u8 = 0,
    rows: u16,
    alphabet: u16,
    silent: u16 = 0,
    /// Table size of each row, `min_log ... log`.
    logs: []u8,
    /// `norm[row * alphabet + sym]`, likewise `next`.
    norm: []u16,
    next: []u16,
    plain: []bool,
    /// For the row a body ends in: the row its name is coded in. For the row
    /// a name leads to: the row that follows the definition's first use in
    /// the payload (inside a body it is followed by that row itself).
    name_row: []u16,
    first_row: []u16,
    arity_row: u16,
    cut_row: u16 = 0,
    start_row: u16,
    /// Rows [base_rows .. rows) are sparse definition or payload context clones.
    /// Selectors are ordered; multiple keys may point to one clone row.
    base_rows: u16,
    feature: Feature = .none,
    selectors: []const Selector = &.{},

    pub fn select(m: Model, base_row: u16, context: Context) u16 {
        const key = context.key(m.feature) orelse return base_row;
        const wanted = (@as(u64, base_row) << 32) | @as(u64, key);
        var lo: usize = 0;
        var hi: usize = m.selectors.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const selector = m.selectors[mid];
            const actual = (@as(u64, selector.base_row) << 32) | @as(u64, selector.key);
            if (actual < wanted) lo = mid + 1 else hi = mid;
        }
        if (lo < m.selectors.len) {
            const selector = m.selectors[lo];
            if (selector.base_row == base_row and selector.key == key)
                return m.base_rows + selector.target;
        }
        return base_row;
    }

    pub fn def(m: Model) u16 {
        return @intCast(m.widths.len);
    }

    /// `CUT n`: keep only the first `n` bytes of the child before it.
    pub fn cut(m: Model) u16 {
        return m.def() + 1;
    }

    pub fn isPast(m: Model, sym: u16) bool {
        return sym -% 1 < m.ring;
    }

    /// Symbols from here up are silent.
    pub fn hush(m: Model) u16 {
        return m.alphabet - m.silent;
    }

    /// Where each row's cells start, and the state bits it carries through.
    pub fn layout(m: Model, gpa: Allocator) ![]tans.Row {
        const at = try gpa.alloc(tans.Row, m.rows);
        var unit: usize = 0;
        for (at, m.logs) |*row, row_log| {
            row.* = .{ .unit = std.math.cast(u18, unit) orelse return error.Corrupt, .carry = @intCast(m.log - row_log) };
            unit += @as(usize, 1) << @intCast(row_log - tans.min_log);
        }
        return at;
    }

    pub fn cell(m: Model, row: u16, sym: u16) usize {
        return @as(usize, row) * m.alphabet + sym;
    }

    /// Raw bits that follow `sym` when it is decoded from `row`.
    pub fn width(m: Model, row: u16, sym: u16) u8 {
        return if (m.plain[row] or sym >= m.widths.len) 0 else m.widths[sym];
    }

    pub fn init(gpa: Allocator, log: u8, buckets: usize, rows: u16, alphabet: u16) !Model {
        std.debug.assert(alphabet > buckets + 1);
        const cells = @as(usize, rows) * alphabet;
        var m: Model = .{
            .log = log,
            .rows = rows,
            .alphabet = alphabet,
            .arity_row = 0,
            .start_row = 0,
            .base_rows = rows,
            .widths = &.{},
            .norm = &.{},
            .next = &.{},
            .plain = &.{},
            .name_row = &.{},
            .first_row = &.{},
            .logs = &.{},
        };
        errdefer m.deinit(gpa);
        m.widths = try gpa.alloc(u8, buckets);
        m.norm = try gpa.alloc(u16, cells);
        m.next = try gpa.alloc(u16, cells);
        m.plain = try gpa.alloc(bool, rows);
        m.name_row = try gpa.alloc(u16, rows);
        m.first_row = try gpa.alloc(u16, rows);
        m.logs = try gpa.alloc(u8, rows);
        @memset(m.logs, log);
        @memset(m.widths, 0);
        @memset(m.norm, 0);
        @memset(m.next, 0);
        @memset(m.plain, false);
        @memset(m.name_row, 0);
        @memset(m.first_row, 0);
        m.widths[byte_bucket] = 8;
        return m;
    }

    pub fn deinit(m: *Model, gpa: Allocator) void {
        gpa.free(m.widths);
        gpa.free(m.norm);
        gpa.free(m.next);
        gpa.free(m.plain);
        gpa.free(m.name_row);
        gpa.free(m.first_row);
        gpa.free(m.logs);
        if (m.selectors.len != 0) gpa.free(m.selectors);
        m.* = undefined;
    }

    /// The decoder's whole model: every row's cells, back to back.
    pub fn buildCells(m: Model, gpa: Allocator, at: []const tans.Row) ![]tans.Cell {
        var total: usize = 0;
        for (m.logs) |row_log| total += @as(usize, 1) << @intCast(row_log);
        const cells = try gpa.alloc(tans.Cell, total);
        errdefer gpa.free(cells);
        @memset(cells, @bitCast(@as(u64, 0)));
        const scratch = try gpa.alloc(u16, (@as(usize, 1) << @intCast(m.log)) + m.alphabet);
        defer gpa.free(scratch);
        const widths = try gpa.alloc(u8, @as(usize, m.alphabet) * 2);
        defer gpa.free(widths);
        @memset(widths, 0);
        @memcpy(widths[0..m.widths.len], m.widths);
        const nexts = try gpa.alloc(tans.Row, m.alphabet);
        defer gpa.free(nexts);

        for (0..m.rows) |r| {
            const norm = m.norm[r * m.alphabet ..][0..m.alphabet];
            if (std.mem.allEqual(u16, norm, 0)) continue;
            for (nexts, m.next[r * m.alphabet ..][0..m.alphabet]) |*to, row| to.* = at[row];
            const w = if (m.plain[r]) widths[m.alphabet..] else widths[0..m.alphabet];
            tans.buildDecode(norm, m.logs[r], w, nexts, cells[@as(usize, at[r].unit) << tans.min_log ..], scratch);
        }
        return cells;
    }

    /// The most common successor row of each symbol; rows whose cells all
    /// agree with it say so in one bit.
    fn homes(m: Model, gpa: Allocator) ![]u16 {
        const home = try gpa.alloc(u16, m.alphabet);
        errdefer gpa.free(home);
        const votes = try gpa.alloc(u32, m.rows);
        defer gpa.free(votes);
        for (home, 0..) |*h, s| {
            @memset(votes, 0);
            for (0..m.rows) |r| {
                const c = m.cell(@intCast(r), @intCast(s));
                if (m.norm[c] != 0) votes[m.next[c]] += 1;
            }
            h.* = @intCast(std.mem.indexOfMax(u32, votes));
        }
        return home;
    }

    /// Adaptive contexts shared by `write` and `read`, which walk the header
    /// in the same order through `Codec`.
    const Header = struct {
        scalar: binary.Number = .{},
        width: binary.Number = .{},
        home: binary.Number = .{},
        home_same: binary.Bit = .{},
        row_log: binary.Number = .{},
        linked: [2]binary.Number = @splat(.{}),
        plain: binary.Bit = .{},
        homely: binary.Bit = .{},
        strays: binary.Bit = .{},
        /// By row kind, how many earlier rows of that kind used the symbol
        /// (capped), and whether the previous symbol in this row was used.
        used: [2][4][2]binary.Bit = @splat(@splat(@splat(.{}))),
        /// By row kind and the magnitude of the symbol's mean frequency in
        /// earlier rows of that kind.
        freq: [2][tans.max_log + 2]binary.Number = @splat(@splat(.{})),
    };

    /// One walk over the header, for both directions: `Codec(.write)` sends
    /// the model's fields, `Codec(.read)` fills them in.
    fn Codec(comptime dir: enum { write, read }) type {
        return struct {
            coder: if (dir == .write) *binary.Encoder else *binary.Decoder,
            h: Header = .{},

            const Self = @This();

            fn number(c: *Self, model: *binary.Number, value: *u32) !void {
                if (dir == .write) try c.coder.number(model, value.*) else value.* = try c.coder.number(model);
            }

            fn flag(c: *Self, model: *binary.Bit, value: *bool) !void {
                if (dir == .write) try c.coder.bit(model, @intFromBool(value.*)) else value.* = c.coder.bit(model) == 1;
            }

            fn field(c: *Self, model: *binary.Number, ptr: anytype, limit: usize) !void {
                var v: u32 = if (dir == .write) ptr.* else 0;
                try c.number(model, &v);
                if (v >= limit) return error.Corrupt;
                ptr.* = @intCast(v);
            }

            fn tables(c: *Self, m: *Model, home: []u16, gpa: Allocator) !void {
                for (m.widths[1..][0..m.ring], 0..) |*w, tier| w.* = @intCast(tier);
                for (m.widths[1 + m.ring ..]) |*w| try c.field(&c.h.width, w, bits.Stack.max_bits + 1);
                var last: u16 = 0;
                for (home) |*to| {
                    var same = to.* == last;
                    try c.flag(&c.h.home_same, &same);
                    if (same) to.* = last else try c.field(&c.h.home, to, m.rows);
                    last = to.*;
                }

                const seen = try gpa.alloc([2]u32, @as(usize, m.alphabet) * 2);
                defer gpa.free(seen);
                @memset(seen, .{ 0, 0 });
                for (0..m.rows) |r| {
                    try c.field(&c.h.row_log, &m.logs[r], m.log + 1);
                    if (m.logs[r] < tans.min_log) return error.Corrupt;
                    try c.flag(&c.h.plain, &m.plain[r]);
                    // Both usually run in step with the row number.
                    if (!m.plain[r]) for ([_][]u16{ m.name_row, m.first_row }, &c.h.linked) |linked, *model| {
                        const expected = if (r == 0) 0 else (linked[r - 1] + 1) % m.rows;
                        var off: u16 = (linked[r] + m.rows - expected) % m.rows;
                        try c.field(model, &off, m.rows);
                        linked[r] = (expected + off) % m.rows;
                    };
                    const norm = m.norm[r * m.alphabet ..][0..m.alphabet];
                    const next = m.next[r * m.alphabet ..][0..m.alphabet];
                    var homely = true;
                    if (dir == .write) for (norm, next, home) |n, to, h| {
                        if (n != 0 and to != h) homely = false;
                    };
                    try c.flag(&c.h.homely, &homely);

                    const size = @as(u32, 1) << @intCast(m.logs[r]);
                    const kind = @intFromBool(m.plain[r]);
                    var prev_used = false;
                    var sum: u32 = 0;
                    for (norm, next, home, seen[kind * m.alphabet ..][0..m.alphabet]) |*n, *to, h, *column| {
                        var used = n.* != 0;
                        try c.flag(&c.h.used[kind][@min(column[0], 3)][@intFromBool(prev_used)], &used);
                        prev_used = used;
                        if (dir == .read) to.* = h;
                        if (!used) continue;
                        const mean = if (column[0] == 0) 0 else column[1] / column[0];
                        var v: u32 = if (dir == .write) n.* - 1 else 0;
                        try c.number(&c.h.freq[kind][std.math.log2_int(u32, mean + 1)], &v);
                        if (v >= size - sum) return error.Corrupt;
                        n.* = @intCast(v + 1);
                        sum += n.*;
                        column[0] += 1;
                        column[1] += n.*;
                        if (!homely) {
                            var stray = to.* != h;
                            try c.flag(&c.h.strays, &stray);
                            if (stray) try c.field(&c.h.scalar, to, m.rows);
                        }
                    }
                    if (sum != 0 and sum != size) return error.Corrupt;
                }
            }
        };
    }

    fn validateTransitions(m: Model) !void {
        if (m.base_rows == 0 or m.base_rows > m.rows) return error.Corrupt;
        if (m.rows == m.base_rows and m.selectors.len != 0) return error.Corrupt;
        if (@as(usize, m.rows - m.base_rows) > m.selectors.len) return error.Corrupt;
        if ((m.feature == .none) != (m.selectors.len == 0)) return error.Corrupt;
        for (0..m.base_rows) |r| {
            const norm = m.norm[r * m.alphabet ..][0..m.alphabet];
            const next = m.next[r * m.alphabet ..][0..m.alphabet];
            // Original class/tier transitions are a directed acyclic chain.
            for (norm[m.hush()..], next[m.hush()..]) |n, to| {
                if (n != 0 and (to <= r or to >= m.base_rows)) return error.Corrupt;
            }
        }
        for (m.selectors, 0..) |selector, i| {
            if (selector.base_row >= m.base_rows) return error.Corrupt;
            if (selector.target >= m.rows - m.base_rows) return error.Corrupt;
            if (i > 0) {
                const previous = m.selectors[i - 1];
                if (previous.base_row > selector.base_row or
                    (previous.base_row == selector.base_row and previous.key >= selector.key)) return error.Corrupt;
            }
            const clone = m.base_rows + selector.target;
            if (m.plain[clone] != m.plain[selector.base_row]) return error.Corrupt;
            if (m.name_row[clone] >= m.base_rows or m.first_row[clone] >= m.base_rows) return error.Corrupt;
            const norm = m.norm[m.cell(clone, 0)..][0..m.alphabet];
            const next = m.next[m.cell(clone, 0)..][0..m.alphabet];
            // Only used transitions survive the entropy header. They must
            // rejoin the acyclic original rows after the clone's first event.
            for (norm, next) |frequency, target| {
                if (frequency != 0 and target >= m.base_rows) return error.Corrupt;
            }
            for (m.selectors[0..i]) |earlier| {
                if (earlier.target == selector.target and earlier.base_row != selector.base_row)
                    return error.Corrupt;
            }
        }
        for (0..m.rows - m.base_rows) |target| {
            var found = false;
            for (m.selectors) |selector| if (@as(usize, selector.target) == target) {
                found = true;
                break;
            };
            if (!found) return error.Corrupt;
        }
    }

    pub fn write(m: *Model, gpa: Allocator, coder: *binary.Encoder) !void {
        const home = try m.homes(gpa);
        defer gpa.free(home);
        var c: Codec(.write) = .{ .coder = coder };
        try coder.raw(m.log, 4);
        for ([_]u32{ @intCast(m.widths.len - 1), m.rows - 1, m.alphabet - m.cut() - 1, m.arity_row, m.start_row, m.silent, m.ring, m.cut_row }) |scalar| {
            try coder.number(&c.h.scalar, scalar);
        }
        try c.tables(m, home, gpa);
        try m.validateTransitions();
        try coder.number(&c.h.scalar, @intFromEnum(m.feature));
        try coder.number(&c.h.scalar, m.base_rows);
        try coder.number(&c.h.scalar, @intCast(m.selectors.len));
        for (m.selectors) |selector| {
            try coder.number(&c.h.scalar, selector.base_row);
            try coder.number(&c.h.scalar, selector.key);
            try coder.number(&c.h.scalar, selector.target);
        }
    }

    pub fn read(gpa: Allocator, coder: *binary.Decoder) !Model {
        var c: Codec(.read) = .{ .coder = coder };
        const log: u8 = @intCast(coder.raw(4));
        var scalars: [8]usize = undefined;
        for (&scalars) |*scalar| scalar.* = try coder.number(&c.h.scalar);
        const buckets = scalars[0] + 1;
        const rows = scalars[1] + 1;
        const alphabet = buckets + 2 + scalars[2];
        if (log < min_log or log > tans.max_log) return error.Corrupt;
        if (rows > 1 << 15 or alphabet > 1 << 15 or rows * alphabet > 1 << 26) return error.Corrupt;
        if (scalars[3] >= rows or scalars[4] >= rows or scalars[5] > scalars[2]) return error.Corrupt;
        if (scalars[6] > ring_log or scalars[6] >= buckets or scalars[7] >= rows) return error.Corrupt;

        var m: Model = try .init(gpa, log, buckets, @intCast(rows), @intCast(alphabet));
        errdefer m.deinit(gpa);
        m.arity_row = @intCast(scalars[3]);
        m.start_row = @intCast(scalars[4]);
        m.silent = @intCast(scalars[5]);
        m.ring = @intCast(scalars[6]);
        m.cut_row = @intCast(scalars[7]);
        const home = try gpa.alloc(u16, alphabet);
        defer gpa.free(home);
        @memset(home, 0);
        try c.tables(&m, home, gpa);
        const feature_raw = try coder.number(&c.h.scalar);
        if (feature_raw > @intFromEnum(Feature.stream)) return error.Corrupt;
        m.feature = @enumFromInt(@as(u8, @intCast(feature_raw)));
        m.base_rows = std.math.cast(u16, try coder.number(&c.h.scalar)) orelse return error.Corrupt;
        const selector_count = try coder.number(&c.h.scalar);
        if (selector_count > 1024 or selector_count > m.rows) return error.Corrupt;
        const selectors = try gpa.alloc(Selector, selector_count);
        for (selectors) |*selector| {
            selector.base_row = std.math.cast(u16, try coder.number(&c.h.scalar)) orelse return error.Corrupt;
            selector.key = try coder.number(&c.h.scalar);
            selector.target = std.math.cast(u16, try coder.number(&c.h.scalar)) orelse return error.Corrupt;
        }
        m.selectors = selectors;
        try m.validateTransitions();
        return m;
    }
};
