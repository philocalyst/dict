//! Frame layout shared by encoder and decoder.
//!
//!     frame := magic header_len:varint header block* 0x00
//!     block := kind:u8 [defs delta_bytes delta_len]:varint [raw_len items payload_len]:varint delta payload
//!
//! `kind` bit 0 says the block has a delta, bit 1 a payload. A block with a
//! delta and no payload is a shared dictionary; one with only a payload
//! depends on nothing but earlier deltas.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const magic = "sgn\x02";

pub const Block = struct {
    defs: u32 = 0,
    delta_bytes: u32 = 0,
    delta: []const u8 = &.{},
    dgens: u32 = 0,
    dgen: []const u8 = &.{},
    raw_len: u32 = 0,
    items: u32 = 0,
    payload: []const u8 = &.{},
    gens: u32 = 0,
    gen: []const u8 = &.{},

    pub fn write(b: Block, gpa: Allocator, out: *std.ArrayList(u8)) !void {
        const kind = @as(u8, @intFromBool(b.defs != 0)) | @as(u8, @intFromBool(b.items != 0)) << 1;
        std.debug.assert(kind != 0);
        try out.append(gpa, kind);
        if (b.defs != 0) for ([_]usize{ b.defs, b.delta_bytes, b.delta.len, b.dgens, b.dgen.len }) |v| try putVarint(gpa, out, v);
        if (b.items != 0) for ([_]usize{ b.raw_len, b.items, b.payload.len, b.gens, b.gen.len }) |v| try putVarint(gpa, out, v);
        try out.appendSlice(gpa, b.delta);
        try out.appendSlice(gpa, b.dgen);
        try out.appendSlice(gpa, b.payload);
        try out.appendSlice(gpa, b.gen);
    }

    /// Returns null at the end-of-frame marker.
    pub fn read(bytes: []const u8, pos: *usize) error{Corrupt}!?Block {
        if (pos.* >= bytes.len) return error.Corrupt;
        const kind = bytes[pos.*];
        pos.* += 1;
        if (kind == 0) return null;
        if (kind > 3) return error.Corrupt;
        var b: Block = .{};
        var delta_len: u32 = 0;
        var dgen_len: u32 = 0;
        var payload_len: u32 = 0;
        var gen_len: u32 = 0;
        if (kind & 1 != 0) for ([_]*u32{ &b.defs, &b.delta_bytes, &delta_len, &b.dgens, &dgen_len }) |field| {
            field.* = try takeVarint(bytes, pos);
        };
        if (kind & 2 != 0) for ([_]*u32{ &b.raw_len, &b.items, &payload_len, &b.gens, &gen_len }) |field| {
            field.* = try takeVarint(bytes, pos);
        };
        if (@as(u64, delta_len) + dgen_len + payload_len + gen_len > bytes.len - pos.* or b.gens > b.items or (b.gens == 0 and gen_len != 0) or (b.dgens == 0 and dgen_len != 0)) return error.Corrupt;
        b.delta = bytes[pos.*..][0..delta_len];
        b.dgen = bytes[pos.* + delta_len ..][0..dgen_len];
        b.payload = bytes[pos.* + delta_len + dgen_len ..][0..payload_len];
        b.gen = bytes[pos.* + delta_len + dgen_len + payload_len ..][0..gen_len];
        pos.* += delta_len + dgen_len + payload_len + gen_len;
        return b;
    }
};

pub fn putVarint(gpa: Allocator, out: *std.ArrayList(u8), value: usize) !void {
    var v = value;
    while (v >= 0x80) : (v >>= 7) try out.append(gpa, @as(u8, @truncate(v)) | 0x80);
    try out.append(gpa, @intCast(v));
}

pub fn takeVarint(bytes: []const u8, pos: *usize) error{Corrupt}!u32 {
    var v: u32 = 0;
    for (0..5) |i| {
        if (pos.* >= bytes.len) return error.Corrupt;
        const byte = bytes[pos.*];
        pos.* += 1;
        v |= std.math.shl(u32, byte & 0x7f, 7 * i);
        if (byte < 0x80) return v;
    }
    return error.Corrupt;
}
