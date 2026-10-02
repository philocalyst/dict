//! Bit I/O. Streams are read forward, least significant bit first.
//!
//! tANS encodes last-symbol-first, so the encoder pushes fields onto a
//! `Stack` and drains it in reverse into a `Writer`; the decoder then meets
//! every field in natural order with a plain forward `Reader`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub inline fn low(v: u64, n: u8) u64 {
    return v & ((@as(u64, 1) << @intCast(n)) - 1);
}

pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,
    acc: u64 = 0,
    cnt: u6 = 0,

    pub fn init(bytes: []const u8) Reader {
        var r: Reader = .{ .bytes = bytes };
        r.refill();
        return r;
    }

    /// Tops `acc` up to at least 56 valid bits. Past the end the stream is
    /// zeros, so a corrupt stream decodes to garbage, never out of bounds.
    pub inline fn refill(r: *Reader) void {
        if (r.pos + 8 <= r.bytes.len) {
            r.acc |= std.mem.readInt(u64, r.bytes[r.pos..][0..8], .little) << r.cnt;
            r.pos += (63 - r.cnt) >> 3;
            r.cnt |= 56;
        } else r.refillTail();
    }

    fn refillTail(r: *Reader) void {
        @branchHint(.cold);
        while (r.cnt < 56) : (r.cnt += 8) {
            const byte: u64 = if (r.pos < r.bytes.len) r.bytes[r.pos] else 0;
            r.acc |= byte << r.cnt;
            r.pos += 1;
        }
    }

    pub inline fn consume(r: *Reader, n: u8) void {
        r.acc >>= @intCast(n);
        r.cnt -= @intCast(n);
    }

    /// Reads `n <= 32` bits.
    pub fn take(r: *Reader, n: u8) u32 {
        const v = low(r.acc, n);
        r.consume(n);
        r.refill();
        return @intCast(v);
    }
};

pub const Writer = struct {
    out: std.ArrayList(u8) = .empty,
    acc: u64 = 0,
    cnt: u8 = 0,

    pub fn deinit(w: *Writer, gpa: Allocator) void {
        w.out.deinit(gpa);
    }

    /// Writes the low `n <= 32` bits of `v`.
    pub fn put(w: *Writer, gpa: Allocator, v: u32, n: u8) !void {
        std.debug.assert(n <= 32 and low(v, n) == v);
        w.acc |= @as(u64, v) << @intCast(w.cnt);
        w.cnt += n;
        while (w.cnt >= 8) : (w.cnt -= 8) {
            try w.out.append(gpa, @truncate(w.acc));
            w.acc >>= 8;
        }
    }

    /// Pads to a byte boundary and returns the bytes (owned by the writer).
    pub fn finish(w: *Writer, gpa: Allocator) ![]const u8 {
        if (w.cnt != 0) try w.out.append(gpa, @truncate(w.acc));
        w.acc = 0;
        w.cnt = 0;
        return w.out.items;
    }
};

/// Fields pushed here come back out of a `Reader` last-pushed-first.
pub const Stack = struct {
    fields: std.ArrayList(Field) = .empty,

    const Field = packed struct(u32) { n: u5, v: u27 };
    pub const max_bits = 27;

    pub fn deinit(s: *Stack, gpa: Allocator) void {
        s.fields.deinit(gpa);
    }

    pub fn push(s: *Stack, gpa: Allocator, v: u32, n: u8) !void {
        if (n != 0) try s.fields.append(gpa, .{ .n = @intCast(n), .v = @intCast(v) });
    }

    pub fn drain(s: *Stack, gpa: Allocator, w: *Writer) !void {
        var i = s.fields.items.len;
        while (i > 0) {
            i -= 1;
            try w.put(gpa, s.fields.items[i].v, s.fields.items[i].n);
        }
        s.fields.clearRetainingCapacity();
    }
};

test "stack reverses" {
    const gpa = std.testing.allocator;
    var stack: Stack = .{};
    defer stack.deinit(gpa);
    var w: Writer = .{};
    defer w.deinit(gpa);

    for (0..1000) |i| try stack.push(gpa, @intCast(i * 7919 % (1 << 20)), 20);
    try stack.drain(gpa, &w);

    var r: Reader = .init(try w.finish(gpa));
    var i: usize = 1000;
    while (i > 0) {
        i -= 1;
        try std.testing.expectEqual(@as(u32, @intCast(i * 7919 % (1 << 20))), r.take(20));
    }
}
