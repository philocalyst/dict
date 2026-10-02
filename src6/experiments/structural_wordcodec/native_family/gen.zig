//! Paid exact first-use surface construction operands for the private GEN wire.
//! A GEN constructs literal prefix + a recent token's exact span + literal tail.
const std = @import("std");
const binary = @import("binary.zig");

pub const Event = struct { distance: u32, start: u32, copy_len: u32, donor_len: u32, lead: []const u8, tail: []const u8 };

/// A paid family constructor: lead + donor[start:len-delete_tail] + tail.
pub const Template = struct {
    start: u8,
    delete_tail: u8,
    lead: []const u8,
    tail: []const u8,

    pub fn applies(t: Template, event: Event) bool {
        return t.start == event.start and t.delete_tail == event.donor_len - event.start - event.copy_len and
            std.mem.eql(u8, t.lead, event.lead) and std.mem.eql(u8, t.tail, event.tail);
    }
};

const Keyed = struct { key: u32, entry: u32 };

fn keyOrder(_: void, a: Keyed, b: Keyed) bool {
    return if (a.key != b.key) a.key < b.key else a.entry < b.entry;
}

fn formShape(s: []const u8) bool {
    if (s.len < 4 or s.len > 96) return false;
    for (s) |b| if (!(std.ascii.isAlphanumeric(b) or b >= 128 or b == '-' or b == '_' or b == '\'')) return false;
    return true;
}

fn scalarBoundary(s: []const u8, at: usize) bool {
    return at == s.len or s[at] & 0xc0 != 0x80;
}

fn addAlignment(arena: std.mem.Allocator, out: *std.ArrayList(Event), donor: []const u8, target: []const u8, suffix: bool) !void {
    var copied: usize = 0;
    if (suffix) {
        while (copied < @min(donor.len, target.len) and donor[donor.len - 1 - copied] == target[target.len - 1 - copied]) copied += 1;
        while (copied != 0 and (!scalarBoundary(donor, donor.len - copied) or !scalarBoundary(target, target.len - copied))) copied -= 1;
        if (copied < 4 or donor.len - copied > 12 or target.len - copied > 12) return;
        try out.append(arena, .{ .distance = 0, .start = @intCast(donor.len - copied), .copy_len = @intCast(copied), .donor_len = @intCast(donor.len), .lead = target[0 .. target.len - copied], .tail = "" });
    } else {
        while (copied < @min(donor.len, target.len) and donor[copied] == target[copied]) copied += 1;
        while (copied != 0 and (!scalarBoundary(donor, copied) or !scalarBoundary(target, copied))) copied -= 1;
        if (copied < 4 or donor.len - copied > 12 or target.len - copied > 12) return;
        try out.append(arena, .{ .distance = 0, .start = 0, .copy_len = @intCast(copied), .donor_len = @intCast(donor.len), .lead = "", .tail = target[copied..] });
    }
}

/// Seed family hypotheses across exact materialized lexical surfaces, before
/// any GEN is selected. Eight graph-neighbors per four-byte edge keep work
/// bounded without a language-specific analyzer or suffix inventory.
pub fn seedFamilies(arena: std.mem.Allocator, surfaces: []const []const u8) ![]Event {
    var prefix: std.ArrayList(Keyed) = .empty;
    var suffix: std.ArrayList(Keyed) = .empty;
    for (surfaces, 0..) |s, entry| {
        if (!formShape(s)) continue;
        try prefix.append(arena, .{ .key = std.mem.readInt(u32, s[0..4], .little), .entry = @intCast(entry) });
        try suffix.append(arena, .{ .key = std.mem.readInt(u32, s[s.len - 4 ..][0..4], .little), .entry = @intCast(entry) });
    }
    std.mem.sort(Keyed, prefix.items, {}, keyOrder);
    std.mem.sort(Keyed, suffix.items, {}, keyOrder);
    var out: std.ArrayList(Event) = .empty;
    for ([_]struct { items: []const Keyed, suffix: bool }{ .{ .items = prefix.items, .suffix = false }, .{ .items = suffix.items, .suffix = true } }) |group| {
        for (group.items, 0..) |a, i| {
            var j = i + 1;
            while (j < group.items.len and j - i <= 8 and group.items[j].key == a.key) : (j += 1) {
                const donor = surfaces[a.entry];
                const target = surfaces[group.items[j].entry];
                try addAlignment(arena, &out, donor, target, group.suffix);
                try addAlignment(arena, &out, target, donor, group.suffix);
            }
        }
    }
    return out.items;
}

const Candidate = struct { key: []const u8, count: u32, gain: i64 };

fn moreGain(_: void, a: Candidate, b: Candidate) bool {
    return if (a.gain != b.gain) a.gain > b.gain else std.mem.order(u8, a.key, b.key) == .lt;
}

/// Cheap proposal filter. Complete frame selection pays/rejects every proposal.
pub fn learnTemplates(arena: std.mem.Allocator, gens: []const Event, dgens: []const Event) ![]Template {
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    var candidates: std.ArrayList(Candidate) = .empty;
    for ([_][]const Event{ gens, dgens }) |events| for (events) |event| {
        if (event.start + event.copy_len > event.donor_len or event.start > 96 or event.donor_len - event.start - event.copy_len > 96 or event.lead.len > 96 or event.tail.len > 96) continue;
        const key_len = 4 + event.lead.len + event.tail.len;
        if (key_len > 32) continue;
        var buffer: [32]u8 = undefined;
        buffer[0] = @intCast(event.start);
        buffer[1] = @intCast(event.donor_len - event.start - event.copy_len);
        buffer[2] = @intCast(event.lead.len);
        buffer[3] = @intCast(event.tail.len);
        @memcpy(buffer[4..][0..event.lead.len], event.lead);
        @memcpy(buffer[4 + event.lead.len ..][0..event.tail.len], event.tail);
        if (index.get(buffer[0..key_len])) |at| {
            candidates.items[at].count += 1;
        } else {
            const owned = try arena.dupe(u8, buffer[0..key_len]);
            const at = candidates.items.len;
            try candidates.append(arena, .{ .key = owned, .count = 1, .gain = 0 });
            try index.put(arena, owned, at);
        }
    };
    for (candidates.items) |*c| c.gain = @as(i64, c.count) * (@as(i64, @intCast(c.key.len)) - 1) - @as(i64, @intCast(c.key.len)) - 3;
    std.mem.sort(Candidate, candidates.items, {}, moreGain);
    var out: std.ArrayList(Template) = .empty;
    for (candidates.items) |c| {
        if (c.count < 2 or c.gain <= 0 or out.items.len == 64) break;
        const lead_len = c.key[2];
        out.append(arena, .{ .start = c.key[0], .delete_tail = c.key[1], .lead = c.key[4..][0..lead_len], .tail = c.key[4 + lead_len ..] }) catch return error.OutOfMemory;
    }
    return out.items;
}

pub fn writeTemplates(gpa: std.mem.Allocator, templates: []const Template) ![]u8 {
    if (templates.len == 0) return gpa.alloc(u8, 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, @intCast(templates.len));
    for (templates) |t| {
        try out.appendSlice(gpa, &.{ t.start, t.delete_tail, @intCast(t.lead.len), @intCast(t.tail.len) });
        try out.appendSlice(gpa, t.lead);
        try out.appendSlice(gpa, t.tail);
    }
    return out.toOwnedSlice(gpa);
}

pub fn readTemplates(arena: std.mem.Allocator, bytes: []const u8) ![]Template {
    if (bytes.len == 0) return &.{};
    const count = bytes[0];
    if (count == 0 or count > 64) return error.Corrupt;
    const out = try arena.alloc(Template, count);
    var at: usize = 1;
    for (out) |*t| {
        if (bytes.len - at < 4) return error.Corrupt;
        const start = bytes[at];
        const delete_tail = bytes[at + 1];
        const lead_len = bytes[at + 2];
        const tail_len = bytes[at + 3];
        at += 4;
        if (start > 96 or delete_tail > 96 or lead_len > 96 or tail_len > 96 or @as(usize, lead_len) + tail_len > bytes.len - at) return error.Corrupt;
        t.* = .{ .start = start, .delete_tail = delete_tail, .lead = bytes[at..][0..lead_len], .tail = bytes[at + lead_len ..][0..tail_len] };
        at += lead_len + tail_len;
    }
    if (at != bytes.len) return error.Corrupt;
    return out;
}

pub const Args = struct {
    distance: u32,
    mode: u3,
    start: u32,
    copy_len: u32,
    lead_len: usize,
    tail_len: usize,

    pub fn resolve(a: Args, donor_len: usize) ?struct { start: usize, copy_len: usize } {
        if (donor_len == 0 or donor_len > 96) return null;
        const start: usize = if (a.mode == 0 or a.mode == 1) 0 else a.start;
        if (start >= donor_len) return null;
        const copied: usize = if (a.mode == 0 or a.mode == 2) donor_len - start else if (a.mode == 4) blk: {
            if (a.copy_len >= donor_len - start) return null;
            break :blk donor_len - start - a.copy_len;
        } else a.copy_len;
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
    template_ref: binary.Bit = .{},
    template_index: binary.Number = .{},
    lead_len: binary.Number = .{},
    tail_len: binary.Number = .{},
    bytes: [16][8]binary.Bit = @splat(@splat(.{})),
    previous: u8 = 0,

    pub fn write(c: *Codec, e: *binary.Encoder, event: Event, templates: []const Template) !void {
        try e.number(&c.distance, event.distance);
        if (templates.len != 0) {
            var match: ?usize = null;
            for (templates, 0..) |t, at| if (t.applies(event)) {
                match = at;
                break;
            };
            try e.bit(&c.template_ref, @intFromBool(match != null));
            if (match) |at| {
                try e.number(&c.template_index, @intCast(at));
                return;
            }
        }
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

    pub fn read(c: *Codec, d: *binary.Decoder, literal: []u8, templates: []const Template) !Args {
        const distance = try d.number(&c.distance);
        if (templates.len != 0 and d.bit(&c.template_ref) == 1) {
            const at = try d.number(&c.template_index);
            if (at >= templates.len) return error.Corrupt;
            const t = templates[at];
            if (t.lead.len + t.tail.len > literal.len) return error.Corrupt;
            @memcpy(literal[0..t.lead.len], t.lead);
            @memcpy(literal[t.lead.len..][0..t.tail.len], t.tail);
            return .{ .distance = distance, .mode = 4, .start = t.start, .copy_len = t.delete_tail, .lead_len = t.lead.len, .tail_len = t.tail.len };
        }
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

pub fn pack(gpa: std.mem.Allocator, events: []const Event, templates: []const Template) ![]u8 {
    if (events.len == 0) return gpa.alloc(u8, 0);
    var coder: binary.Encoder = .{ .gpa = gpa };
    defer coder.deinit();
    var model: Codec = .{};
    for (events) |event| try model.write(&coder, event, templates);
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
    const bytes = try pack(gpa, &events, &.{});
    defer gpa.free(bytes);
    var decoder: binary.Decoder = .init(bytes);
    var codec: Codec = .{};
    for (events, 0..) |original, index| {
        var literal: [96]u8 = undefined;
        const decoded = try codec.read(&decoder, &literal, &.{});
        const span = decoded.resolve(original.donor_len) orelse return error.Corrupt;
        try std.testing.expectEqual(index, @as(usize, decoded.distance));
        try std.testing.expectEqual(@as(usize, original.start), span.start);
        try std.testing.expectEqual(@as(usize, original.copy_len), span.copy_len);
        try std.testing.expectEqualSlices(u8, original.lead, literal[0..decoded.lead_len]);
        try std.testing.expectEqualSlices(u8, original.tail, literal[decoded.lead_len..][0..decoded.tail_len]);
    }
}

test "shared paid family constructs distinct donor surfaces" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const events = [_]Event{
        .{ .distance = 0, .start = 0, .copy_len = 10, .donor_len = 12, .lead = "", .tail = "ed" },
        .{ .distance = 1, .start = 0, .copy_len = 14, .donor_len = 16, .lead = "", .tail = "ed" },
        .{ .distance = 2, .start = 0, .copy_len = 8, .donor_len = 10, .lead = "", .tail = "ed" },
    };
    const templates = try learnTemplates(a, &events, &.{});
    try std.testing.expectEqual(@as(usize, 1), templates.len);
    const table_bytes = try writeTemplates(gpa, templates);
    defer gpa.free(table_bytes);
    const restored = try readTemplates(a, table_bytes);
    const bytes = try pack(gpa, &events, restored);
    defer gpa.free(bytes);
    var decoder: binary.Decoder = .init(bytes);
    var codec: Codec = .{};
    for (events) |original| {
        var literal: [96]u8 = undefined;
        const decoded = try codec.read(&decoder, &literal, restored);
        const span = decoded.resolve(original.donor_len) orelse return error.Corrupt;
        try std.testing.expectEqual(@as(u3, 4), decoded.mode);
        try std.testing.expectEqual(@as(usize, original.copy_len), span.copy_len);
        try std.testing.expectEqualSlices(u8, "ed", literal[decoded.lead_len..][0..decoded.tail_len]);
    }
}

test "lexical graph seeds a productive short-stem family before GEN" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const surfaces: []const []const u8 = &.{ "walk", "walking", "talk", "talking", "unrelated" };
    const pairs = try seedFamilies(a, surfaces);
    const templates = try learnTemplates(a, pairs, &.{});
    var found = false;
    for (templates) |t| if (t.start == 0 and t.delete_tail == 0 and t.lead.len == 0 and std.mem.eql(u8, t.tail, "ing")) {
        found = true;
    };
    try std.testing.expect(found);
}
