//! Table ANS over small alphabets. Every row shares one state of `log` bits
//! so the model may switch rows between any two symbols, yet each row has
//! its own table size `2^row_log`: a step uses the top `row_log` bits of the
//! state and carries the low `log - row_log` bits through untouched, which
//! costs nothing and keeps small distributions in small, cache-hot tables.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_log = 13;

/// One decode step. `width` raw bits follow the `nbits` state bits in the
/// stream, so a single 64-bit peek yields the next state and the slot index.
pub const Cell = packed struct(u64) {
    sym: u16,
    base: u13,
    nbits: u4,
    width: u5,
    /// Where the next row's cells start, in units of `1 << min_log` cells,
    /// and how many state bits that row carries through.
    next: Row = .{},
    _: u4 = 0,
};

pub const Row = packed struct(u22) { unit: u18 = 0, carry: u4 = 0 };

pub const min_log = 5;

/// Scales `counts` to sum to `2^log`, keeping every used symbol codable and
/// spending the rounding slack where it saves the most bits.
pub fn normalize(counts: []const u32, log: u8, norm: []u16) error{TooManySymbols}!void {
    const size: u32 = @as(u32, 1) << @intCast(log);
    var total: u64 = 0;
    var used: u32 = 0;
    for (counts) |c| {
        total += c;
        used += @intFromBool(c != 0);
    }
    @memset(norm, 0);
    if (used == 0) return;
    if (used > size) return error.TooManySymbols;

    var sum: u32 = 0;
    for (counts, norm) |c, *n| {
        if (c == 0) continue;
        n.* = @intCast(@max(1, @as(u64, c) * size / total));
        sum += n.*;
    }
    // Each unit moved is the one whose gain (or loss) in coded bits is best.
    while (sum != size) {
        const grow = sum < size;
        var best: usize = 0;
        var best_score = -std.math.inf(f64);
        for (counts, norm, 0..) |c, n, s| {
            if (c == 0 or (!grow and n == 1)) continue;
            const from: f64 = @floatFromInt(n);
            const to = if (grow) from + 1 else from - 1;
            const score = @as(f64, @floatFromInt(c)) * @log2(to / from);
            if (score > best_score) {
                best_score = score;
                best = s;
            }
        }
        if (grow) norm[best] += 1 else norm[best] -= 1;
        sum = if (grow) sum + 1 else sum - 1;
    }
}

/// Bits a symbol of normalised frequency `n` costs, to first order.
pub fn cost(n: u16, log: u8) f64 {
    return @as(f64, @floatFromInt(log)) - @log2(@as(f64, @floatFromInt(n)));
}

/// Visits table positions in the classic FSE stride order; `symbols[u]` is
/// the symbol decoded from state `u`.
fn spread(norm: []const u16, log: u8, symbols: []u16) void {
    const size = @as(usize, 1) << @intCast(log);
    const step = (size >> 1) + (size >> 3) + 3;
    var pos: usize = 0;
    for (norm, 0..) |n, s| for (0..n) |_| {
        symbols[pos] = @intCast(s);
        pos = (pos + step) & (size - 1);
    };
    std.debug.assert(pos == 0);
}

/// Fills one row of decode cells. `widths[s]` and `nexts[s]` are copied into
/// every cell of symbol `s`.
pub fn buildDecode(norm: []const u16, log: u8, widths: []const u8, nexts: []const Row, cells: []Cell, scratch: []u16) void {
    const size = @as(usize, 1) << @intCast(log);
    const symbols = scratch[0..size];
    const occurrence = scratch[size..][0..norm.len];
    spread(norm, log, symbols);
    @memcpy(occurrence, norm);
    for (cells[0..size], symbols) |*cell, s| {
        const x = occurrence[s];
        occurrence[s] += 1;
        const nbits = log - std.math.log2_int(u16, x);
        cell.* = .{
            .sym = s,
            .next = nexts[s],
            .base = @intCast((@as(usize, x) << @intCast(nbits)) - size),
            .nbits = @intCast(nbits),
            .width = @intCast(widths[s]),
        };
    }
}

/// Encoder view of one row: for symbol `s`, `states[first[s] + j]` is the
/// table position of its `j`-th cell.
pub const EncodeRow = struct {
    norm: []const u16,
    first: []u32,
    states: []u16,

    pub fn init(gpa: Allocator, norm: []const u16, log: u8) !EncodeRow {
        const size = @as(usize, 1) << @intCast(log);
        const first = try gpa.alloc(u32, norm.len + 1);
        errdefer gpa.free(first);
        const states = try gpa.alloc(u16, size);
        errdefer gpa.free(states);
        const symbols = try gpa.alloc(u16, size);
        defer gpa.free(symbols);

        spread(norm, log, symbols);
        first[0] = 0;
        for (norm, 0..) |n, s| first[s + 1] = first[s] + n;
        const cursor = try gpa.dupe(u32, first[0..norm.len]);
        defer gpa.free(cursor);
        for (symbols, 0..) |s, u| {
            states[cursor[s]] = @intCast(u);
            cursor[s] += 1;
        }
        return .{ .norm = norm, .first = first, .states = states };
    }

    pub fn deinit(row: *EncodeRow, gpa: Allocator) void {
        gpa.free(row.first);
        gpa.free(row.states);
    }

    pub const Step = struct { state: u16, bits: u16, nbits: u8 };

    /// From decoder state `state` (the one that will follow this symbol),
    /// returns the state that decodes `sym` and the bits that lead back.
    pub fn encode(row: EncodeRow, state: u16, sym: u16, log: u8) Step {
        const n: u32 = row.norm[sym];
        std.debug.assert(n != 0);
        const x = @as(u32, state) + (@as(u32, 1) << @intCast(log));
        var nbits: u8 = log - std.math.log2_int(u32, n);
        if (x >> @intCast(nbits) < n) nbits -= 1;
        return .{
            .state = row.states[row.first[sym] + (x >> @intCast(nbits)) - n],
            .bits = @intCast(x & ((@as(u32, 1) << @intCast(nbits)) - 1)),
            .nbits = nbits,
        };
    }
};

test "rows share a state" {
    const gpa = std.testing.allocator;
    const log = 9;
    const counts = [2][5]u32{ .{ 900, 1, 40, 0, 7 }, .{ 3, 3, 3, 500, 0 } };
    var norm: [2][5]u16 = undefined;
    var rows: [2]EncodeRow = undefined;
    var cells: [2 << log]Cell = undefined;
    var scratch: [(1 << log) + 5]u16 = undefined;
    for (0..2) |r| {
        try normalize(&counts[r], log, &norm[r]);
        rows[r] = try .init(gpa, &norm[r], log);
        buildDecode(&norm[r], log, &.{ 0, 0, 0, 0, 0 }, &.{ .{}, .{ .unit = 1 }, .{}, .{ .unit = 1 }, .{ .unit = 1 } }, cells[r << log ..], &scratch);
    }
    defer for (&rows) |*row| row.deinit(gpa);

    // Symbol i is drawn from the row its predecessor selected.
    var prng: std.Random.DefaultPrng = .init(4);
    var syms: [4000]u16 = undefined;
    var which: [4000]u1 = undefined;
    var row: u1 = 0;
    for (&syms, &which) |*s, *w| {
        w.* = row;
        s.* = while (true) {
            const c = prng.random().uintLessThan(u16, 5);
            if (counts[row][c] != 0) break c;
        };
        row = @intFromBool(s.* == 1 or s.* >= 3);
    }

    var stack: @import("bits.zig").Stack = .{};
    defer stack.deinit(gpa);
    var state: u16 = 0;
    var i: usize = syms.len;
    while (i > 0) {
        i -= 1;
        const step = rows[which[i]].encode(state, syms[i], log);
        try stack.push(gpa, step.bits, step.nbits);
        state = step.state;
    }
    try stack.push(gpa, state, log);
    var w: @import("bits.zig").Writer = .{};
    defer w.deinit(gpa);
    try stack.drain(gpa, &w);

    var r: @import("bits.zig").Reader = .init(try w.finish(gpa));
    var s: usize = r.take(log);
    var at: usize = 0;
    for (syms) |want| {
        const cell = cells[(at << log) + s];
        try std.testing.expectEqual(want, cell.sym);
        s = cell.base + r.take(cell.nbits);
        at = cell.next.unit;
    }
}
