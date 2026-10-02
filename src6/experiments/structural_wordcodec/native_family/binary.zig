//! Adaptive binary range coder, used only for the frame header: the model
//! tables are small, read once, and worth squeezing.

const std = @import("std");
const Allocator = std.mem.Allocator;

const prob_bits = 11;
const rate = 4;
const top: u32 = 1 << 24;

/// Probability that the next bit is 0, out of `1 << prob_bits`.
pub const Bit = struct {
    p: u16 = 1 << (prob_bits - 1),

    inline fn update(b: *Bit, bit: u1) void {
        if (bit == 0) b.p += ((1 << prob_bits) - b.p) >> rate else b.p -= b.p >> rate;
    }
};

/// A non-negative integer as an adaptive unary exponent plus raw mantissa.
pub const Number = struct {
    exponent: [33]Bit = @splat(.{}),
    top_bit: [33]Bit = @splat(.{}),
};

pub const Encoder = struct {
    gpa: Allocator,
    out: std.ArrayList(u8) = .empty,
    low: u64 = 0,
    range: u32 = std.math.maxInt(u32),
    cache: u8 = 0,
    pending: u64 = 1,

    pub fn deinit(e: *Encoder) void {
        e.out.deinit(e.gpa);
    }

    pub fn bit(e: *Encoder, model: *Bit, value: u1) !void {
        const bound = (e.range >> prob_bits) * model.p;
        if (value == 0) e.range = bound else {
            e.low += bound;
            e.range -= bound;
        }
        model.update(value);
        while (e.range < top) : (e.range <<= 8) try e.shiftLow();
    }

    pub fn raw(e: *Encoder, value: u32, count: u8) !void {
        var i = count;
        while (i > 0) {
            i -= 1;
            e.range >>= 1;
            if ((value >> @intCast(i)) & 1 != 0) e.low += e.range;
            while (e.range < top) : (e.range <<= 8) try e.shiftLow();
        }
    }

    pub fn number(e: *Encoder, model: *Number, value: u32) !void {
        const v = @as(u64, value) + 1;
        const exponent: u8 = std.math.log2_int(u64, v);
        for (0..exponent) |i| try e.bit(&model.exponent[i], 1);
        try e.bit(&model.exponent[exponent], 0);
        if (exponent == 0) return;
        try e.bit(&model.top_bit[exponent], @truncate(v >> @intCast(exponent - 1)));
        try e.raw(@truncate(v & ((@as(u64, 1) << @intCast(exponent - 1)) - 1)), exponent - 1);
    }

    fn shiftLow(e: *Encoder) !void {
        if (e.low < 0xFF00_0000 or e.low > std.math.maxInt(u32)) {
            const carry: u8 = @truncate(e.low >> 32);
            var first = true;
            while (e.pending != 0) : (e.pending -= 1) {
                try e.out.append(e.gpa, (if (first) e.cache else 0xFF) +% carry);
                first = false;
            }
            e.cache = @truncate(e.low >> 24);
        }
        e.pending += 1;
        e.low = (e.low & 0x00FF_FFFF) << 8;
    }

    pub fn finish(e: *Encoder) ![]const u8 {
        for (0..5) |_| try e.shiftLow();
        return e.out.items;
    }
};

pub const Decoder = struct {
    bytes: []const u8,
    pos: usize = 0,
    range: u32 = std.math.maxInt(u32),
    code: u32 = 0,

    pub fn init(bytes: []const u8) Decoder {
        var d: Decoder = .{ .bytes = bytes };
        for (0..5) |_| d.code = d.code << 8 | d.next();
        return d;
    }

    fn next(d: *Decoder) u32 {
        defer d.pos += 1;
        return if (d.pos < d.bytes.len) d.bytes[d.pos] else 0;
    }

    pub fn bit(d: *Decoder, model: *Bit) u1 {
        const bound = (d.range >> prob_bits) * model.p;
        const value: u1 = @intFromBool(d.code >= bound);
        if (value == 0) d.range = bound else {
            d.code -= bound;
            d.range -= bound;
        }
        model.update(value);
        while (d.range < top) : (d.range <<= 8) d.code = d.code << 8 | d.next();
        return value;
    }

    pub fn raw(d: *Decoder, count: u8) u32 {
        var value: u32 = 0;
        for (0..count) |_| {
            d.range >>= 1;
            const one = d.code >= d.range;
            if (one) d.code -= d.range;
            value = value << 1 | @intFromBool(one);
            while (d.range < top) : (d.range <<= 8) d.code = d.code << 8 | d.next();
        }
        return value;
    }

    pub fn number(d: *Decoder, model: *Number) error{Corrupt}!u32 {
        var exponent: u8 = 0;
        while (d.bit(&model.exponent[exponent]) == 1) : (exponent += 1) if (exponent == 32) return error.Corrupt;
        if (exponent == 0) return 0;
        const head: u64 = 2 | @as(u64, d.bit(&model.top_bit[exponent]));
        const v = head << @intCast(exponent - 1) | d.raw(exponent - 1);
        return std.math.cast(u32, v - 1) orelse error.Corrupt;
    }
};

test "numbers and bits round-trip" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(9);
    const rnd = prng.random();
    var values: [5000]u32 = undefined;
    for (&values) |*v| v.* = switch (rnd.uintLessThan(u8, 4)) {
        0 => 0,
        1 => rnd.uintLessThan(u32, 20),
        2 => rnd.uintLessThan(u32, 5000),
        else => rnd.int(u32),
    };

    var enc: Encoder = .{ .gpa = gpa };
    defer enc.deinit();
    var models: [4]Number = @splat(.{});
    for (values, 0..) |v, i| try enc.number(&models[i & 3], v);
    const bytes = try enc.finish();

    var dec: Decoder = .init(bytes);
    models = @splat(.{});
    for (values, 0..) |v, i| try std.testing.expectEqual(v, try dec.number(&models[i & 3]));
}
