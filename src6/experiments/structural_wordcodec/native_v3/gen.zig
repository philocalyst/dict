//! Paid exact first-use surface construction operands for the private GEN wire.
//! A GEN constructs literal prefix + a recent token's exact span + literal tail.
const std = @import("std");
const binary = @import("binary.zig");

pub const Event = struct { distance: u32, start: u32, copy_len: u32, lead: []const u8, tail: []const u8 };

pub const Codec = struct {
    distance: binary.Number = .{},
    start: binary.Number = .{},
    copy_len: binary.Number = .{},
    lead_len: binary.Number = .{},
    tail_len: binary.Number = .{},
    bytes: [16][8]binary.Bit = @splat(@splat(.{})),
    previous: u8 = 0,

    pub fn write(c: *Codec, e: *binary.Encoder, event: Event) !void {
        try e.number(&c.distance, event.distance);
        try e.number(&c.start, event.start);
        try e.number(&c.copy_len, event.copy_len);
        try e.number(&c.lead_len, @intCast(event.lead.len));
        try e.number(&c.tail_len, @intCast(event.tail.len));
        for (event.lead) |byte| {
            for (0..8) |bit| try e.bit(&c.bytes[c.previous >> 4][bit], @intCast((byte >> @intCast(7 - bit)) & 1));
            c.previous = byte;
        }
        for (event.tail) |byte| {
            for (0..8) |bit| try e.bit(&c.bytes[c.previous >> 4][bit], @intCast((byte >> @intCast(7 - bit)) & 1));
            c.previous = byte;
        }
    }

    pub fn read(c: *Codec, d: *binary.Decoder, literal: []u8) !struct { distance: u32, start: u32, copy_len: u32, lead_len: usize, tail_len: usize } {
        const distance = try d.number(&c.distance);
        const start = try d.number(&c.start);
        const copy_len = try d.number(&c.copy_len);
        const lead_len = try d.number(&c.lead_len);
        const tail_len = try d.number(&c.tail_len);
        if (lead_len > literal.len or tail_len > literal.len - lead_len or copy_len == 0 or copy_len > 96 - lead_len - tail_len) return error.Corrupt;
        for (literal[0 .. lead_len + tail_len]) |*byte| {
            byte.* = 0;
            for (0..8) |bit| byte.* = (byte.* << 1) | d.bit(&c.bytes[c.previous >> 4][bit]);
            c.previous = byte.*;
        }
        return .{ .distance = distance, .start = start, .copy_len = copy_len, .lead_len = lead_len, .tail_len = tail_len };
    }
};

pub fn pack(gpa: std.mem.Allocator, events: []const Event) ![]u8 {
    if (events.len == 0) return gpa.alloc(u8, 0);
    var coder: binary.Encoder = .{ .gpa = gpa };
    defer coder.deinit();
    var model: Codec = .{};
    for (events) |event| try model.write(&coder, event);
    return gpa.dupe(u8, try coder.finish());
}
