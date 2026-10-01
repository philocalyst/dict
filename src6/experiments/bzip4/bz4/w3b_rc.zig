//! w3b_rc: a fast binary-only range coder for Lane W3b's speed work.
//!
//! `rc.zig` (shared, Lane W's own) is a 64-bit "carryless" (Subbotin-style)
//! range coder: every `encodeBitProb`/`decodeBitProb` call does a 64-bit XOR
//! + compare to detect the carry-free zone before it can renormalize, and
//! carries `low`/`range` as `u64` throughout. That is correct and simple but
//! is not the cheapest possible binary coder. This file is a from-scratch
//! reimplementation of the classic LZMA-style bit range coder (the public,
//! widely-implemented 7-Zip SDK algorithm: 32-bit `range`, `low` widened to
//! `u64` only to let `shiftLow` detect and propagate a carry into already-
//! emitted bytes via a byte cache): `bound = (range >> 12) * prob`, branch on
//! `code < bound` (decoder) / `bit` (encoder), no XOR/compare carry-detection
//! per call, no multi-symbol frequency API (this lane's coder is 100%
//! binary, so that API is dropped entirely). Kept 12-bit probabilities
//! (`prob_bits`) to match the rest of the lab's convention.
//!
//! Encoder and decoder are exact inverses of each other (see tests below);
//! `w3b_fastcm.zig` is the only intended caller.

const std = @import("std");

pub const prob_bits: u5 = 12;
pub const prob_one: u16 = 1 << prob_bits;
pub const prob_half: u16 = prob_one / 2;

const top_value: u32 = 1 << 24;

/// A single adaptive bit-probability counter (probability the bit is 0, in
/// 1/4096 units), same shape as `rc.Bit` so callers can port code directly.
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
    range: u32 = 0xFFFF_FFFF,
    cache: u8 = 0,
    cache_size: u64 = 1,
    out: std.ArrayList(u8) = .empty,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Encoder {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Encoder) void {
        self.out.deinit(self.alloc);
    }

    /// Classic LZMA `RangeEncoder::ShiftLow`: emits the pending cache byte
    /// (plus however many 0xFF "maybe" bytes have piled up) once the top
    /// byte of `low` is known not to be a still-pending carry target.
    inline fn shiftLow(self: *Encoder) !void {
        if (@as(u32, @intCast(self.low >> 32)) != 0 or self.low < 0xFF00_0000) {
            var temp = self.cache;
            const carry: u8 = @intCast(self.low >> 32);
            while (true) {
                try self.out.append(self.alloc, temp +% carry);
                temp = 0xFF;
                self.cache_size -= 1;
                if (self.cache_size == 0) break;
            }
            self.cache = @truncate(self.low >> 24);
        }
        self.cache_size += 1;
        self.low = (self.low << 8) & 0xFFFF_FFFF;
    }

    /// Code one bit with an externally-supplied, already-blended
    /// probability-of-zero `p0` (1/4096 units, not stored/updated here —
    /// mirrors `rc.zig`'s own `encodeBitProb`, used when the caller mixes
    /// several counters into one probability before coding).
    pub inline fn encodeBitProb(self: *Encoder, p0: u16, bit: u1) !void {
        const bound = (self.range >> prob_bits) * @as(u32, p0);
        if (bit == 0) {
            self.range = bound;
        } else {
            self.low +%= bound;
            self.range -= bound;
        }
        while (self.range < top_value) {
            self.range <<= 8;
            try self.shiftLow();
        }
    }

    /// Code one bit against a single adaptive counter (leaf-style use, e.g.
    /// the run-shortcut flag): updates `model` in place.
    pub inline fn encodeBit(self: *Encoder, model: *Bit, bit: u1, comptime rate: u4) !void {
        try self.encodeBitProb(model.p, bit);
        model.update(bit, rate);
    }

    pub fn encodeDirect(self: *Encoder, value: u32, count: u6) !void {
        var i: u6 = count;
        while (i > 0) {
            i -= 1;
            try self.encodeBitProb(prob_half, @truncate(value >> @intCast(i)));
        }
    }

    /// Flush the coder (5 bytes: worst case one pending cache byte plus a
    /// run of carry bytes) and hand back the finished stream, owned by the
    /// encoder (dupe before freeing, same convention as `rc.zig`).
    pub fn finish(self: *Encoder) ![]const u8 {
        var i: usize = 0;
        while (i < 5) : (i += 1) try self.shiftLow();
        return self.out.items;
    }
};

pub const Decoder = struct {
    range: u32 = 0xFFFF_FFFF,
    code: u32 = 0,
    in: []const u8,
    at: usize = 0,

    /// The encoder's very first `shiftLow` always emits one redundant byte
    /// (the initial `cache = 0`, before any real data has shifted through
    /// `low`) — standard LZMA convention. Skip it, then prime `code` with
    /// the next 4 bytes.
    pub fn init(in: []const u8) Decoder {
        var self = Decoder{ .in = in, .at = 1 };
        var i: usize = 0;
        while (i < 4) : (i += 1) self.code = (self.code << 8) | self.next();
        return self;
    }

    inline fn next(self: *Decoder) u32 {
        const byte: u32 = if (self.at < self.in.len) self.in[self.at] else 0;
        self.at += 1;
        return byte;
    }

    pub inline fn decodeBitProb(self: *Decoder, p0: u16) u1 {
        const bound = (self.range >> prob_bits) * @as(u32, p0);
        var bit: u1 = 0;
        if (self.code < bound) {
            self.range = bound;
        } else {
            self.code -= bound;
            self.range -= bound;
            bit = 1;
        }
        while (self.range < top_value) {
            self.range <<= 8;
            self.code = (self.code << 8) | self.next();
        }
        return bit;
    }

    pub inline fn decodeBit(self: *Decoder, model: *Bit, comptime rate: u4) u1 {
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

// ---------------------------------------------------------------- tests --

test "encodeBitProb/decodeBitProb roundtrip, fixed skewed probability" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC0DE);
    const rnd = prng.random();
    const n = 100_000;
    const bits = try alloc.alloc(u1, n);
    defer alloc.free(bits);
    for (bits) |*b| b.* = @intFromBool(rnd.uintLessThan(u8, 10) == 0); // skewed toward 0

    var enc = Encoder.init(alloc);
    defer enc.deinit();
    for (bits) |b| try enc.encodeBitProb(3700, b); // p(bit==0) high
    const bytes = try alloc.dupe(u8, try enc.finish());
    defer alloc.free(bytes);

    var dec = Decoder.init(bytes);
    for (bits) |b| try std.testing.expectEqual(b, dec.decodeBitProb(3700));

    // Skewed data at a matching probability must actually compress.
    try std.testing.expect(bytes.len < n / 4);
}

test "adaptive Bit roundtrip matches rc.zig's semantics" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xFEED);
    const rnd = prng.random();
    const n = 50_000;
    const bits = try alloc.alloc(u1, n);
    defer alloc.free(bits);
    for (bits, 0..) |*b, i| b.* = @intFromBool((i / 7) % 3 == 0 or rnd.uintLessThan(u8, 20) == 0);

    var enc = Encoder.init(alloc);
    defer enc.deinit();
    var emodel = Bit{};
    for (bits) |b| try enc.encodeBit(&emodel, b, 5);
    const bytes = try alloc.dupe(u8, try enc.finish());
    defer alloc.free(bytes);

    var dec = Decoder.init(bytes);
    var dmodel = Bit{};
    for (bits) |b| try std.testing.expectEqual(b, dec.decodeBit(&dmodel, 5));
}

test "encodeDirect/decodeDirect roundtrip" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(1);
    const rnd = prng.random();
    const n = 20_000;
    const vals = try alloc.alloc(u32, n);
    defer alloc.free(vals);
    for (vals) |*v| v.* = rnd.int(u32) & 0x1FFFF;

    var enc = Encoder.init(alloc);
    defer enc.deinit();
    for (vals) |v| try enc.encodeDirect(v, 17);
    const bytes = try alloc.dupe(u8, try enc.finish());
    defer alloc.free(bytes);

    var dec = Decoder.init(bytes);
    for (vals) |v| try std.testing.expectEqual(v, dec.decodeDirect(17));
}

test "empty stream roundtrips (flush-only)" {
    const alloc = std.testing.allocator;
    var enc = Encoder.init(alloc);
    defer enc.deinit();
    const bytes = try alloc.dupe(u8, try enc.finish());
    defer alloc.free(bytes);
    var dec = Decoder.init(bytes);
    _ = &dec; // nothing to decode; just must not crash on init
}

test "many carry propagations (long run of near-1.0 probabilities)" {
    // Forces `low` to climb near 0xFFFFFFFF repeatedly, exercising shiftLow's
    // carry-into-cached-0xFF-run path.
    const alloc = std.testing.allocator;
    const n = 5000;
    var enc = Encoder.init(alloc);
    defer enc.deinit();
    var bits: [n]u1 = undefined;
    var prng = std.Random.DefaultPrng.init(77);
    const rnd = prng.random();
    for (&bits) |*b| b.* = @intFromBool(rnd.uintLessThan(u16, 4096) != 0); // p(bit=1) ~= 4095/4096
    for (bits) |b| try enc.encodeBitProb(1, b); // p0=1: bit is almost always 1
    const bytes = try alloc.dupe(u8, try enc.finish());
    defer alloc.free(bytes);
    var dec = Decoder.init(bytes);
    for (bits) |b| try std.testing.expectEqual(b, dec.decodeBitProb(1));
}
