//! Paid exact first-use surface construction operands for the private GEN wire.
//! A GEN constructs literal prefix + a recent token's exact span + literal tail.
const std = @import("std");
const binary = @import("binary.zig");

pub const Event = struct { distance: u32, start: u32, copy_len: u32, donor_len: u32, lead: []const u8, tail: []const u8 };

pub const Args = struct {
    distance: u32,
    mode: u2,
    start: u32,
    copy_len: u32,
    lead_len: usize,
    tail_len: usize,

    pub fn resolve(a: Args, donor_len: usize) ?struct { start: usize, copy_len: usize } {
        if (donor_len == 0 or donor_len > 96) return null;
        const start: usize = if (a.mode == 0 or a.mode == 1) 0 else a.start;
        if (start >= donor_len) return null;
        const copied: usize = if (a.mode == 0 or a.mode == 2) donor_len - start else a.copy_len;
        if (copied == 0 or copied > donor_len - start or a.lead_len + copied + a.tail_len > 96) return null;
        return .{ .start = start, .copy_len = copied };
    }
};

pub const Codec = struct {
    distance: binary.Number = .{},
    start: binary.Number = .{},
    copy_len: binary.Number = .{},
    full: binary.Bit = .{},
    edge: binary.Bit = .{},
    prefix: binary.Bit = .{},
    lead_len: binary.Number = .{},
    tail_len: binary.Number = .{},
    bytes: [16][8]binary.Bit = @splat(@splat(.{})),
    previous: u8 = 0,

    pub fn write(c: *Codec, e: *binary.Encoder, event: Event) !void {
        try e.number(&c.distance, event.distance);
        const mode: u2 = if (event.start == 0 and event.copy_len == event.donor_len) 0 else if (event.start == 0) 1 else if (event.start + event.copy_len == event.donor_len) 2 else 3;
        try e.bit(&c.full, @intFromBool(mode != 0));
        if (mode != 0) {
            try e.bit(&c.edge, @intFromBool(mode != 1));
            if (mode >= 2) try e.bit(&c.prefix, @intFromBool(mode == 3));
        }
        if (mode >= 2) try e.number(&c.start, event.start);
        if (mode == 1 or mode == 3) try e.number(&c.copy_len, event.copy_len);
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

    pub fn read(c: *Codec, d: *binary.Decoder, literal: []u8) !Args {
        const distance = try d.number(&c.distance);
        const mode: u2 = if (d.bit(&c.full) == 0) 0 else if (d.bit(&c.edge) == 0) 1 else if (d.bit(&c.prefix) == 0) 2 else 3;
        const start: u32 = if (mode >= 2) try d.number(&c.start) else 0;
        const copy_len: u32 = if (mode == 1 or mode == 3) try d.number(&c.copy_len) else 0;
        const lead_len = try d.number(&c.lead_len);
        const tail_len = try d.number(&c.tail_len);
        if (lead_len > literal.len or tail_len > literal.len - lead_len) return error.Corrupt;
        for (literal[0 .. lead_len + tail_len]) |*byte| {
            byte.* = 0;
            for (0..8) |bit| byte.* = (byte.* << 1) | d.bit(&c.bytes[c.previous >> 4][bit]);
            c.previous = byte.*;
        }
        return .{ .distance = distance, .mode = mode, .start = start, .copy_len = copy_len, .lead_len = lead_len, .tail_len = tail_len };
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

test "typed span operands preserve full prefix suffix and middle constructions" {
    const gpa = std.testing.allocator;
    const events = [_]Event{
        .{ .distance = 0, .start = 0, .copy_len = 12, .donor_len = 12, .lead = "", .tail = "ed" },
        .{ .distance = 1, .start = 0, .copy_len = 9, .donor_len = 12, .lead = "un", .tail = "" },
        .{ .distance = 2, .start = 3, .copy_len = 9, .donor_len = 12, .lead = "", .tail = "ing" },
        .{ .distance = 3, .start = 2, .copy_len = 8, .donor_len = 12, .lead = "re", .tail = "s" },
    };
    const bytes = try pack(gpa, &events);
    defer gpa.free(bytes);
    var decoder: binary.Decoder = .init(bytes);
    var codec: Codec = .{};
    for (events, 0..) |original, index| {
        var literal: [96]u8 = undefined;
        const decoded = try codec.read(&decoder, &literal);
        const span = decoded.resolve(original.donor_len) orelse return error.Corrupt;
        try std.testing.expectEqual(index, @as(usize, decoded.distance));
        try std.testing.expectEqual(@as(usize, original.start), span.start);
        try std.testing.expectEqual(@as(usize, original.copy_len), span.copy_len);
        try std.testing.expectEqualSlices(u8, original.lead, literal[0..decoded.lead_len]);
        try std.testing.expectEqualSlices(u8, original.tail, literal[decoded.lead_len..][0..decoded.tail_len]);
    }
}
