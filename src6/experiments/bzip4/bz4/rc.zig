//! Shared 64-bit carryless range coder for every bz4 lab lane.
//!
//! One coder serves adaptive binary decisions (12-bit probabilities) and
//! multi-symbol frequency intervals with totals up to 2^32, so static codes
//! over very large phrase alphabets and tiny adaptive flags share a stream.
//! Pure Zig, no allocation in the decoder.

const std = @import("std");

const top: u64 = 1 << 56;
const bot: u64 = 1 << 48;

pub const prob_bits = 12;
pub const prob_one: u16 = 1 << prob_bits;
pub const prob_half: u16 = prob_one / 2;

/// Adaptive probability that the next bit is 0, in 1/4096 units.
pub const Bit = struct {
    p: u16 = prob_half,

    pub inline fn update(self: *Bit, bit: u1, comptime rate: u4) void {
        if (bit == 0) {
            self.p += (prob_one - self.p) >> rate;
        } else {
            self.p -= self.p >> rate;
        }
    }
};

pub const Encoder = struct {
    low: u64 = 0,
    range: u64 = std.math.maxInt(u64),
    out: std.ArrayList(u8) = .empty,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Encoder {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Encoder) void {
        self.out.deinit(self.alloc);
    }

    inline fn normalize(self: *Encoder) !void {
        while (true) {
            if ((self.low ^ (self.low +% self.range)) >= top) {
                if (self.range >= bot) break;
                self.range = (0 -% self.low) & (bot - 1);
            }
            try self.out.append(self.alloc, @truncate(self.low >> 56));
            self.low <<= 8;
            self.range <<= 8;
        }
    }

    /// Code the interval [cum, cum+freq) out of tot. Requires 0 < freq, cum+freq <= tot <= 2^32.
    pub fn encodeFreq(self: *Encoder, cum: u32, freq: u32, tot: u32) !void {
        std.debug.assert(freq != 0 and @as(u64, cum) + freq <= tot);
        self.range /= tot;
        self.low +%= @as(u64, cum) * self.range;
        self.range *= freq;
        try self.normalize();
    }

    /// Code one bit with a fixed probability p0 (of bit==0) in 1/4096 units, 0 < p0 < 4096.
    pub fn encodeBitProb(self: *Encoder, p0: u16, bit: u1) !void {
        const r = (self.range >> prob_bits) * p0;
        if (bit == 0) {
            self.range = r;
        } else {
            self.low +%= r;
            self.range -= r;
        }
        try self.normalize();
    }

    pub fn encodeBit(self: *Encoder, model: *Bit, bit: u1, comptime rate: u4) !void {
        try self.encodeBitProb(model.p, bit);
        model.update(bit, rate);
    }

    /// Code `count` raw bits (count <= 32), most significant first.
    pub fn encodeDirect(self: *Encoder, value: u32, count: u6) !void {
        var i: u6 = count;
        while (i > 0) {
            i -= 1;
            try self.encodeBitProb(prob_half, @truncate(value >> @intCast(i)));
        }
    }

    /// Flush and return the finished byte stream (owned by the encoder).
    pub fn finish(self: *Encoder) ![]const u8 {
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            try self.out.append(self.alloc, @truncate(self.low >> 56));
            self.low <<= 8;
        }
        return self.out.items;
    }
};

pub const Decoder = struct {
    low: u64 = 0,
    range: u64 = std.math.maxInt(u64),
    code: u64 = 0,
    in: []const u8,
    at: usize = 0,

    pub fn init(in: []const u8) Decoder {
        var self = Decoder{ .in = in };
        var i: usize = 0;
        while (i < 8) : (i += 1) self.code = (self.code << 8) | self.next();
        return self;
    }

    inline fn next(self: *Decoder) u64 {
        // Reading past the end yields zeros; callers validate lengths/CRCs.
        const byte: u64 = if (self.at < self.in.len) self.in[self.at] else 0;
        self.at += 1;
        return byte;
    }

    inline fn normalize(self: *Decoder) void {
        while (true) {
            if ((self.low ^ (self.low +% self.range)) >= top) {
                if (self.range >= bot) break;
                self.range = (0 -% self.low) & (bot - 1);
            }
            self.code = (self.code << 8) | self.next();
            self.low <<= 8;
            self.range <<= 8;
        }
    }

    /// Returns a value in [0, tot); find the symbol whose interval holds it, then call `consume`.
    pub fn decodeFreq(self: *Decoder, tot: u32) u32 {
        self.range /= tot;
        const v = (self.code -% self.low) / self.range;
        return @intCast(@min(v, @as(u64, tot) - 1));
    }

    pub fn consume(self: *Decoder, cum: u32, freq: u32) void {
        self.low +%= @as(u64, cum) * self.range;
        self.range *= freq;
        self.normalize();
    }

    pub fn decodeBitProb(self: *Decoder, p0: u16) u1 {
        const r = (self.range >> prob_bits) * p0;
        var bit: u1 = 0;
        if (self.code -% self.low < r) {
            self.range = r;
        } else {
            self.low +%= r;
            self.range -= r;
            bit = 1;
        }
        self.normalize();
        return bit;
    }

    pub fn decodeBit(self: *Decoder, model: *Bit, comptime rate: u4) u1 {
        const bit = self.decodeBitProb(model.p);
        model.update(bit, rate);
        return bit;
    }

    pub fn decodeDirect(self: *Decoder, count: u6) u32 {
        var value: u32 = 0;
        var i: u6 = 0;
        while (i < count) : (i += 1) value = (value << 1) | self.decodeBitProb(prob_half);
        return value;
    }
};

test "mixed binary/frequency roundtrip" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xB4);
    const rnd = prng.random();
    const n = 200_000;
    const kinds = try alloc.alloc(u8, n);
    defer alloc.free(kinds);
    const vals = try alloc.alloc(u32, n);
    defer alloc.free(vals);
    const tots = try alloc.alloc(u32, n);
    defer alloc.free(tots);

    var enc = Encoder.init(alloc);
    defer enc.deinit();
    var models = [_]Bit{.{}} ** 16;
    for (0..n) |i| {
        kinds[i] = rnd.uintLessThan(u8, 3);
        switch (kinds[i]) {
            0 => {
                vals[i] = @intFromBool(rnd.uintLessThan(u8, 10) == 0);
                try enc.encodeBit(&models[i & 15], @intCast(vals[i]), 5);
            },
            1 => {
                tots[i] = if (rnd.boolean()) rnd.intRangeAtMost(u32, 1, 4000) else rnd.intRangeAtMost(u32, 1 << 20, std.math.maxInt(u32));
                vals[i] = rnd.uintLessThan(u32, tots[i]);
                try enc.encodeFreq(vals[i], 1, tots[i]);
            },
            else => {
                vals[i] = rnd.int(u32) & 0x1FFFF;
                try enc.encodeDirect(vals[i], 17);
            },
        }
    }
    const bytes = try enc.finish();

    var dec = Decoder.init(bytes);
    var dmodels = [_]Bit{.{}} ** 16;
    for (0..n) |i| {
        switch (kinds[i]) {
            0 => try std.testing.expectEqual(vals[i], dec.decodeBit(&dmodels[i & 15], 5)),
            1 => {
                const v = dec.decodeFreq(tots[i]);
                try std.testing.expectEqual(vals[i], v);
                dec.consume(v, 1);
            },
            else => try std.testing.expectEqual(vals[i], dec.decodeDirect(17)),
        }
    }
    try std.testing.expect(dec.at <= bytes.len + 8);
}
