//! c_cm DATA OUT — est: what a strong adaptive byte-level context mixer pays
//! per input byte (lpaq-like: orders 1-4 and 6, a word context, a match
//! model, one logistic mixer, one APM). Reference only: this is the kind of
//! model bz4 has to beat without doing any of this work at decode time.
//! Writes one f32 (bits) per input byte to OUT.

const std = @import("std");

fn squash(x: f32) f32 {
    return 1.0 / (1.0 + @exp(-x));
}
fn stretch(p: f32) f32 {
    return @log(p / (1.0 - p));
}

const table_bits = 25;

/// Adaptive probability with a count: fast at first, slower later.
const Slot = packed struct(u32) { p: u22 = 1 << 21, n: u10 = 0 };

const Input = struct {
    table: []Slot,
    base: usize = 0,
    slot: *Slot = undefined,

    fn select(in: *Input, ctx: u64, partial: u32) f32 {
        const h = (ctx +% partial) *% 0x9e37_79b9_7f4a_7c15;
        in.slot = &in.table[@intCast(h >> (64 - table_bits))];
        return stretch(std.math.clamp(@as(f32, @floatFromInt(in.slot.p)) / (1 << 22), 1e-6, 1 - 1e-6));
    }

    fn update(in: *Input, bit: u1, limit: u10) void {
        const s = in.slot;
        const target: i64 = @as(i64, bit) << 22;
        const p: i64 = s.p;
        const next = p + @divTrunc(target - p, @as(i64, s.n) + 2);
        s.p = @intCast(std.math.clamp(next, 1, (1 << 22) - 1));
        if (s.n < limit) s.n += 1;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const data_path = args.next() orelse return error.Usage;
    const out_path = args.next() orelse return error.Usage;
    const cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAlloc(init.io, data_path, gpa, .limited(1 << 30));

    const n_inputs = 8;
    var inputs: [n_inputs]Input = undefined;
    for (&inputs) |*in| {
        in.* = .{ .table = try gpa.alloc(Slot, 1 << table_bits) };
        @memset(in.table, .{});
    }
    const weights = try gpa.alloc(f32, 256 * 256 * n_inputs / 256 * 1); // selected by partial byte
    @memset(weights, 0.3);
    const apm = try gpa.alloc(Slot, 256 * 256 * 33);
    for (apm, 0..) |*s, i| s.* = .{ .p = @intFromFloat(squash((@as(f32, @floatFromInt(i % 33)) - 16) * 0.75) * ((1 << 22) - 1)) };

    const match_table = try gpa.alloc(u32, 1 << 20);
    @memset(match_table, 0);
    var match_at: usize = 0;
    var match_len: u32 = 0;

    const per_byte = try gpa.alloc(f32, data.len);
    var total: f64 = 0;
    var word: u64 = 0;
    var prev_word: u64 = 0;
    for (data, 0..) |byte, i| {
        var h: [n_inputs]u64 = undefined;
        var ctx: u64 = 0;
        for (1..7) |k| {
            ctx = (ctx << 8 | (if (i >= k) data[i - k] else 0)) *% 0x2545_f491_4f6c_dd1d +% k;
            if (k <= 4) h[k - 1] = ctx else if (k == 6) h[4] = ctx;
        }
        h[5] = word *% 31 +% 0x77;
        h[6] = (word *% 0x9e37 +% prev_word) *% 0x51_7cc1 +% 0x99;
        const predicted: ?u8 = if (match_len > 0 and match_at < i) data[match_at] else null;
        h[7] = if (predicted) |b| @as(u64, @min(match_len, 31)) << 8 | b else 0;

        var bits: f32 = 0;
        var partial: u32 = 1;
        var bit_index: u4 = 8;
        while (bit_index > 0) {
            bit_index -= 1;
            const bit: u1 = @truncate(byte >> @intCast(bit_index));
            var st: [n_inputs]f32 = undefined;
            for (&inputs, &st, h, 0..) |*in, *s, hash, k| {
                s.* = in.select(hash *% 0x1_0000_01b3 +% k, partial);
            }
            // The match input only speaks while the predicted byte still agrees.
            if (predicted) |b| {
                const expect = (@as(u32, b) | 0x100) >> bit_index;
                if (expect >> 1 != partial) st[7] = 0;
            } else st[7] = 0;

            const w = weights[partial * n_inputs ..][0..n_inputs];
            var dot: f32 = 0;
            for (w, st) |wi, si| dot += wi * si;
            const p_mix = std.math.clamp(squash(dot), 1e-6, 1 - 1e-6);

            // APM on order 1: interpolate between 33 stretch buckets.
            const c1: usize = if (i > 0) data[i - 1] else 0;
            const pos = std.math.clamp((stretch(p_mix) + 12) * (32.0 / 24.0), 0, 31.999);
            const lo: usize = @intFromFloat(pos);
            const frac = pos - @as(f32, @floatFromInt(lo));
            const cell = apm[(c1 * 256 + partial) * 33 ..];
            const p_apm = (@as(f32, @floatFromInt(cell[lo].p)) * (1 - frac) + @as(f32, @floatFromInt(cell[lo + 1].p)) * frac) / (1 << 22);
            const p = std.math.clamp((p_mix + 3 * p_apm) / 4, 1e-6, 1 - 1e-6);

            bits += -@log2(if (bit == 1) p else 1 - p);

            const err = @as(f32, @floatFromInt(bit)) - p_mix;
            for (w, st) |*wi, si| wi.* += 0.004 * err * si;
            for (&inputs, 0..) |*in, k| if (!(k == 7 and st[7] == 0)) in.update(bit, if (k == 7) 1023 else 1023);
            for ([_]usize{ lo, lo + 1 }) |j| {
                const target: i64 = @as(i64, bit) << 22;
                const old: i64 = cell[j].p;
                cell[j].p = @intCast(std.math.clamp(old + ((target - old) >> 6), 1, (1 << 22) - 1));
            }
            partial = partial << 1 | bit;
        }
        per_byte[i] = bits;
        total += bits;

        // Match model: follow the last occurrence of the previous six bytes.
        if (match_len > 0 and match_at < i and data[match_at] == byte) {
            match_len += 1;
            match_at += 1;
        } else match_len = 0;
        if (i >= 5) {
            const key = (std.mem.readInt(u64, data[i - 5 ..][0..8].*[0..8], .little) & 0xffff_ffff_ffff) *% 0x9e37_79b9_7f4a_7c15 >> 44;
            if (match_len == 0 and match_table[key] != 0) {
                match_at = match_table[key];
                match_len = 1;
            }
            match_table[key] = @intCast(i + 1);
        }
        const letter = std.ascii.isAlphabetic(byte) or byte >= 0x80;
        if (letter) word = word *% 0x2f0b + byte else if (word != 0) {
            prev_word = word;
            word = 0;
        }
    }
    std.debug.print("{s}: cm est {d:.0} bytes ({d:.3} bpc)\n", .{ data_path, total / 8, total / @as(f64, @floatFromInt(data.len)) });
    try cwd.writeFile(init.io, .{ .sub_path = out_path, .data = std.mem.sliceAsBytes(per_byte) });
}
