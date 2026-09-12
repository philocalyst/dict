//! Compact, self-describing identity metadata for the native benchmark adapter.
//!
//! The snapshot already owns keys, prose, and concept membership.  This wire
//! therefore records only facts which cannot be recovered from those verified
//! sections.  Integer columns are tiny representation programs selected by
//! their final byte length; labels may be an exact `prefix ++ decimal(id)`
//! transducer.  Every adaptive encoding has a literal fallback.

const std = @import("std");

pub const Error = error{
    InvalidMetadata,
    MetadataOverflow,
    OutOfMemory,
};

const magic = "L4MD";
const version: u16 = 4;
const header_bytes: u16 = 48;
pub const Limits = struct {
    max_entries: usize = 4 * 1024 * 1024,
    max_senses: usize = 4 * 1024 * 1024,
    max_concepts: usize = 4 * 1024 * 1024,
    max_decoded_bytes: usize = 256 * 1024 * 1024,
    max_synthesized_label_bytes: usize = 256 * 1024 * 1024,
    max_key_bytes: usize = 4 * 1024 * 1024,
    max_definition_bytes: usize = 4 * 1024 * 1024,
};

const LaneKind = enum(u8) {
    raw = 0,
    constant = 1,
    affine = 2,
    delta_varint = 3,
    delta_dictionary = 4,
    dictionary = 5,
};

pub const Sense = struct {
    id: i64,
    entry_rank: u32,
    language: u16,
};

pub const Concept = struct {
    id: i64,
    label: []const u8,
};

pub const Input = struct {
    entry_ids: []const i64,
    senses: []const Sense,
    concepts: []const Concept,
    languages: []const []const u8,
    sources: []const []const u8,
    max_key_bytes: u32,
    max_definition_bytes: u32,
};

pub const Decoded = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    entry_ids: []i64,
    senses: []Sense,
    concepts: []Concept,
    languages: [][]const u8,
    sources: [][]const u8,
    max_key_bytes: u32,
    max_definition_bytes: u32,
    owns_concept_labels: bool,

    pub fn deinit(self: *Decoded) void {
        self.allocator.free(self.entry_ids);
        self.allocator.free(self.senses);
        if (self.owns_concept_labels) for (self.concepts) |concept| self.allocator.free(concept.label);
        self.allocator.free(self.concepts);
        self.allocator.free(self.languages);
        self.allocator.free(self.sources);
        self.* = undefined;
    }
};

fn appendInt(comptime T: type, out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: T) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    try out.appendSlice(allocator, &buffer);
}

fn readInt(comptime T: type, bytes: []const u8, cursor: *usize) Error!T {
    if (cursor.* > bytes.len or bytes.len - cursor.* < @sizeOf(T)) return error.InvalidMetadata;
    const value = std.mem.readInt(T, bytes[cursor.*..][0..@sizeOf(T)], .little);
    cursor.* += @sizeOf(T);
    return value;
}

fn appendI64(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i64) !void {
    try appendInt(u64, out, allocator, @bitCast(value));
}

fn readI64(bytes: []const u8, cursor: *usize) Error!i64 {
    return @bitCast(try readInt(u64, bytes, cursor));
}

fn zigzag(value: i64) u64 {
    return (@as(u64, @bitCast(value)) << 1) ^ @as(u64, @bitCast(value >> 63));
}

fn unzigzag(value: u64) i64 {
    return @bitCast((value >> 1) ^ (0 -% (value & 1)));
}

fn appendVarint(out: *std.ArrayList(u8), allocator: std.mem.Allocator, initial: u64) !void {
    var value = initial;
    while (value >= 0x80) : (value >>= 7)
        try out.append(allocator, @intCast((value & 0x7f) | 0x80));
    try out.append(allocator, @intCast(value));
}

fn readVarint(bytes: []const u8, cursor: *usize, end: usize) Error!u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    var used: usize = 0;
    while (true) {
        if (cursor.* >= end or used == 10) return error.InvalidMetadata;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        used += 1;
        if (used == 10 and byte > 1) return error.InvalidMetadata;
        value |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) {
            if (used > 1 and value < (@as(u64, 1) << @intCast(7 * (used - 1)))) return error.InvalidMetadata;
            return value;
        }
        if (used == 10) return error.InvalidMetadata;
        shift += 7;
    }
}

fn bitsNeeded(value: usize) u8 {
    return if (value == 0) 0 else @intCast(@bitSizeOf(usize) - @clz(value));
}

fn packedLength(count: usize, width: u8) Error!usize {
    const bits = std.math.mul(usize, count, width) catch return error.MetadataOverflow;
    return std.math.divCeil(usize, bits, 8) catch return error.MetadataOverflow;
}

fn appendPacked(out: *std.ArrayList(u8), allocator: std.mem.Allocator, values: []const usize, width: u8) !void {
    const length = try packedLength(values.len, width);
    const start = out.items.len;
    try out.appendNTimes(allocator, 0, length);
    for (values, 0..) |value, index| {
        if (width < @bitSizeOf(usize) and value >= (@as(usize, 1) << @intCast(width))) return error.MetadataOverflow;
        for (0..width) |bit| {
            if ((value >> @intCast(bit)) & 1 == 0) continue;
            const position = std.math.add(usize, std.math.mul(usize, index, width) catch return error.MetadataOverflow, bit) catch return error.MetadataOverflow;
            out.items[start + position / 8] |= @as(u8, 1) << @intCast(position % 8);
        }
    }
}

fn packedAt(bytes: []const u8, count: usize, width: u8, index: usize) Error!usize {
    if (index >= count or bytes.len != try packedLength(count, width)) return error.InvalidMetadata;
    var value: usize = 0;
    for (0..width) |bit| {
        const position = std.math.add(usize, std.math.mul(usize, index, width) catch return error.InvalidMetadata, bit) catch return error.InvalidMetadata;
        value |= @as(usize, (bytes[position / 8] >> @intCast(position % 8)) & 1) << @intCast(bit);
    }
    return value;
}

fn validatePackedTail(bytes: []const u8, count: usize, width: u8) Error!void {
    const used = std.math.mul(usize, count, width) catch return error.InvalidMetadata;
    if (used == 0 or used % 8 == 0) return;
    const mask: u8 = @as(u8, 0xff) << @intCast(used % 8);
    if (bytes[bytes.len - 1] & mask != 0) return error.InvalidMetadata;
}

const Candidate = struct { kind: LaneKind, payload: []u8 };

fn rawCandidate(allocator: std.mem.Allocator, values: []const i64) !Candidate {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (values) |value| try appendI64(&out, allocator, value);
    return .{ .kind = .raw, .payload = try out.toOwnedSlice(allocator) };
}

fn constantCandidate(allocator: std.mem.Allocator, values: []const i64) !?Candidate {
    if (values.len == 0) return null;
    for (values[1..]) |value| if (value != values[0]) return null;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendI64(&out, allocator, values[0]);
    return .{ .kind = .constant, .payload = try out.toOwnedSlice(allocator) };
}

fn affineCandidate(allocator: std.mem.Allocator, values: []const i64) !?Candidate {
    if (values.len < 2) return null;
    const step = @subWithOverflow(values[1], values[0]);
    if (step[1] != 0) return null;
    for (values, 0..) |value, index| {
        const product = @mulWithOverflow(step[0], std.math.cast(i64, index) orelse return null);
        if (product[1] != 0) return null;
        const expected = @addWithOverflow(values[0], product[0]);
        if (expected[1] != 0 or expected[0] != value) return null;
    }
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendI64(&out, allocator, values[0]);
    try appendI64(&out, allocator, step[0]);
    return .{ .kind = .affine, .payload = try out.toOwnedSlice(allocator) };
}

fn deltaCandidate(allocator: std.mem.Allocator, values: []const i64) !?Candidate {
    if (values.len == 0) return null;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendI64(&out, allocator, values[0]);
    for (values[1..], values[0 .. values.len - 1]) |value, previous| {
        const delta = @subWithOverflow(value, previous);
        if (delta[1] != 0) return null;
        try appendVarint(&out, allocator, zigzag(delta[0]));
    }
    return .{ .kind = .delta_varint, .payload = try out.toOwnedSlice(allocator) };
}

fn dictionaryCandidate(allocator: std.mem.Allocator, values: []const i64, deltas: bool) !?Candidate {
    if (values.len == 0 or (deltas and values.len < 2)) return null;
    const count = if (deltas) values.len - 1 else values.len;
    var unique = std.ArrayList(i64).empty;
    defer unique.deinit(allocator);
    var ordinals = std.AutoHashMap(i64, u8).init(allocator);
    defer ordinals.deinit();
    try ordinals.ensureTotalCapacity(@intCast(@min(count, 255)));
    for (0..count) |index| {
        const value = if (deltas) blk: {
            const pair = @subWithOverflow(values[index + 1], values[index]);
            if (pair[1] != 0) return null;
            break :blk pair[0];
        } else values[index];
        const result = try ordinals.getOrPut(value);
        if (!result.found_existing) {
            if (unique.items.len == 255) return null;
            result.value_ptr.* = 0;
            try unique.append(allocator, value);
        }
    }
    std.mem.sort(i64, unique.items, {}, comptime std.sort.asc(i64));
    for (unique.items, 0..) |value, ordinal| ordinals.getPtr(value).?.* = @intCast(ordinal);
    const width = bitsNeeded(unique.items.len - 1);
    var selectors = try allocator.alloc(usize, count);
    defer allocator.free(selectors);
    for (0..count) |index| {
        const value = if (deltas) values[index + 1] - values[index] else values[index];
        selectors[index] = ordinals.get(value).?;
    }
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    if (deltas) try appendI64(&out, allocator, values[0]);
    try out.append(allocator, @intCast(unique.items.len));
    try out.append(allocator, width);
    for (unique.items) |value| try appendVarint(&out, allocator, zigzag(value));
    try appendPacked(&out, allocator, selectors, width);
    return .{ .kind = if (deltas) .delta_dictionary else .dictionary, .payload = try out.toOwnedSlice(allocator) };
}

fn chooseLane(allocator: std.mem.Allocator, values: []const i64) !Candidate {
    var winner = try rawCandidate(allocator, values);
    errdefer allocator.free(winner.payload);
    const Consider = struct {
        fn one(a: std.mem.Allocator, best: *Candidate, candidate_optional: ?Candidate) void {
            if (candidate_optional) |candidate| {
                if (candidate.payload.len < best.payload.len or
                    (candidate.payload.len == best.payload.len and @intFromEnum(candidate.kind) < @intFromEnum(best.kind)))
                {
                    a.free(best.payload);
                    best.* = candidate;
                } else a.free(candidate.payload);
            }
        }
    };
    Consider.one(allocator, &winner, try constantCandidate(allocator, values));
    Consider.one(allocator, &winner, try affineCandidate(allocator, values));
    Consider.one(allocator, &winner, try deltaCandidate(allocator, values));
    Consider.one(allocator, &winner, try dictionaryCandidate(allocator, values, true));
    Consider.one(allocator, &winner, try dictionaryCandidate(allocator, values, false));
    return winner;
}

fn appendLane(out: *std.ArrayList(u8), allocator: std.mem.Allocator, values: []const i64) !void {
    const candidate = try chooseLane(allocator, values);
    defer allocator.free(candidate.payload);
    try out.append(allocator, @intFromEnum(candidate.kind));
    try out.append(allocator, 0);
    try appendInt(u16, out, allocator, 0);
    try appendInt(u32, out, allocator, std.math.cast(u32, values.len) orelse return error.MetadataOverflow);
    try appendInt(u32, out, allocator, std.math.cast(u32, candidate.payload.len) orelse return error.MetadataOverflow);
    try out.appendSlice(allocator, candidate.payload);
}

fn decodeLane(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize, expected_count: usize) Error![]i64 {
    const kind: LaneKind = switch (try readInt(u8, bytes, cursor)) {
        0 => .raw,
        1 => .constant,
        2 => .affine,
        3 => .delta_varint,
        4 => .delta_dictionary,
        5 => .dictionary,
        else => return error.InvalidMetadata,
    };
    if (try readInt(u8, bytes, cursor) != 0 or try readInt(u16, bytes, cursor) != 0) return error.InvalidMetadata;
    const count: usize = try readInt(u32, bytes, cursor);
    const payload_length: usize = try readInt(u32, bytes, cursor);
    if (count != expected_count or cursor.* > bytes.len or bytes.len - cursor.* < payload_length) return error.InvalidMetadata;
    const payload = bytes[cursor.*..][0..payload_length];
    cursor.* += payload_length;
    const values = allocator.alloc(i64, count) catch return error.OutOfMemory;
    errdefer allocator.free(values);
    var at: usize = 0;
    switch (kind) {
        .raw => {
            if (payload.len != std.math.mul(usize, count, 8) catch return error.InvalidMetadata) return error.InvalidMetadata;
            for (values) |*value| value.* = try readI64(payload, &at);
        },
        .constant => {
            if (count == 0 or payload.len != 8) return error.InvalidMetadata;
            @memset(values, try readI64(payload, &at));
        },
        .affine => {
            if (count < 2 or payload.len != 16) return error.InvalidMetadata;
            const base = try readI64(payload, &at);
            const step = try readI64(payload, &at);
            for (values, 0..) |*value, index| {
                const product = @mulWithOverflow(step, std.math.cast(i64, index) orelse return error.InvalidMetadata);
                if (product[1] != 0) return error.InvalidMetadata;
                const result = @addWithOverflow(base, product[0]);
                if (result[1] != 0) return error.InvalidMetadata;
                value.* = result[0];
            }
        },
        .delta_varint => {
            if (count == 0 or payload.len < 8) return error.InvalidMetadata;
            values[0] = try readI64(payload, &at);
            for (values[1..], values[0 .. count - 1]) |*value, previous| {
                const result = @addWithOverflow(previous, unzigzag(try readVarint(payload, &at, payload.len)));
                if (result[1] != 0) return error.InvalidMetadata;
                value.* = result[0];
            }
            if (at != payload.len) return error.InvalidMetadata;
        },
        .delta_dictionary, .dictionary => {
            const delta = kind == .delta_dictionary;
            if (delta) {
                if (count < 2 or payload.len < 10) return error.InvalidMetadata;
                values[0] = try readI64(payload, &at);
            } else if (count == 0) return error.InvalidMetadata;
            const dictionary_count = try readInt(u8, payload, &at);
            const width = try readInt(u8, payload, &at);
            if (dictionary_count == 0 or width != bitsNeeded(dictionary_count - 1)) return error.InvalidMetadata;
            var dictionary: [255]i64 = undefined;
            for (dictionary[0..dictionary_count], 0..) |*value, index| {
                value.* = unzigzag(try readVarint(payload, &at, payload.len));
                if (index != 0 and value.* <= dictionary[index - 1]) return error.InvalidMetadata;
            }
            const selector_count = if (delta) count - 1 else count;
            const selector_length = try packedLength(selector_count, width);
            if (at > payload.len or payload.len - at != selector_length) return error.InvalidMetadata;
            const selectors = payload[at..];
            try validatePackedTail(selectors, selector_count, width);
            for (0..selector_count) |index| {
                const ordinal = try packedAt(selectors, selector_count, width, index);
                if (ordinal >= dictionary_count) return error.InvalidMetadata;
                if (delta) {
                    const result = @addWithOverflow(values[index], dictionary[ordinal]);
                    if (result[1] != 0) return error.InvalidMetadata;
                    values[index + 1] = result[0];
                } else values[index] = dictionary[ordinal];
            }
        },
    }
    return values;
}

fn appendStringTable(out: *std.ArrayList(u8), allocator: std.mem.Allocator, strings: []const []const u8) !void {
    const header_at = out.items.len;
    try appendInt(u32, out, allocator, std.math.cast(u32, strings.len) orelse return error.MetadataOverflow);
    try appendInt(u32, out, allocator, 0);
    for (strings) |string| {
        try appendInt(u16, out, allocator, std.math.cast(u16, string.len) orelse return error.MetadataOverflow);
        try out.appendSlice(allocator, string);
    }
    std.mem.writeInt(u32, out.items[header_at + 4 ..][0..4], std.math.cast(u32, out.items.len - header_at) orelse return error.MetadataOverflow, .little);
}

fn decodeStringTable(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize, expected_count: usize) Error![][]const u8 {
    const start = cursor.*;
    const count: usize = try readInt(u32, bytes, cursor);
    const length: usize = try readInt(u32, bytes, cursor);
    if (count != expected_count or length < 8 or start > bytes.len or bytes.len - start < length) return error.InvalidMetadata;
    const end = start + length;
    const strings = allocator.alloc([]const u8, count) catch return error.OutOfMemory;
    errdefer allocator.free(strings);
    for (strings) |*string| {
        const string_length: usize = try readInt(u16, bytes[0..end], cursor);
        if (cursor.* > end or end - cursor.* < string_length) return error.InvalidMetadata;
        string.* = bytes[cursor.*..][0..string_length];
        cursor.* += string_length;
    }
    if (cursor.* != end) return error.InvalidMetadata;
    return strings;
}

fn decimalLength(value: i64) usize {
    var buffer: [32]u8 = undefined;
    return (std.fmt.bufPrint(&buffer, "{}", .{value}) catch unreachable).len;
}

fn labelTemplate(concepts: []const Concept) ?[]const u8 {
    if (concepts.len == 0) return null;
    const first = concepts[0];
    const digits = decimalLength(first.id);
    if (digits > first.label.len) return null;
    const prefix = first.label[0 .. first.label.len - digits];
    var buffer: [32]u8 = undefined;
    for (concepts) |concept| {
        const number = std.fmt.bufPrint(&buffer, "{}", .{concept.id}) catch return null;
        if (concept.label.len != prefix.len + number.len or
            !std.mem.eql(u8, concept.label[0..prefix.len], prefix) or
            !std.mem.eql(u8, concept.label[prefix.len..], number)) return null;
    }
    return prefix;
}

fn appendLabels(out: *std.ArrayList(u8), allocator: std.mem.Allocator, concepts: []const Concept) !void {
    if (labelTemplate(concepts)) |prefix| {
        try out.append(allocator, 1);
        try out.append(allocator, 0);
        try appendInt(u16, out, allocator, std.math.cast(u16, prefix.len) orelse return error.MetadataOverflow);
        try appendInt(u32, out, allocator, std.math.cast(u32, concepts.len) orelse return error.MetadataOverflow);
        try out.appendSlice(allocator, prefix);
        return;
    }
    try out.append(allocator, 0);
    try out.append(allocator, 0);
    try appendInt(u16, out, allocator, 0);
    try appendInt(u32, out, allocator, std.math.cast(u32, concepts.len) orelse return error.MetadataOverflow);
    const labels = try allocator.alloc([]const u8, concepts.len);
    defer allocator.free(labels);
    for (concepts, 0..) |concept, index| labels[index] = concept.label;
    try appendStringTable(out, allocator, labels);
}

fn decodeLabels(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize, ids: []const i64, limits: Limits) Error![]Concept {
    const mode = try readInt(u8, bytes, cursor);
    if (try readInt(u8, bytes, cursor) != 0) return error.InvalidMetadata;
    const prefix_length: usize = try readInt(u16, bytes, cursor);
    const count: usize = try readInt(u32, bytes, cursor);
    if (count != ids.len) return error.InvalidMetadata;
    const concepts = allocator.alloc(Concept, count) catch return error.OutOfMemory;
    errdefer allocator.free(concepts);
    if (mode == 1) {
        if (cursor.* > bytes.len or bytes.len - cursor.* < prefix_length) return error.InvalidMetadata;
        const prefix = bytes[cursor.*..][0..prefix_length];
        cursor.* += prefix_length;
        var total_label_bytes: usize = 0;
        for (ids) |id| {
            const length = std.math.add(usize, prefix.len, decimalLength(id)) catch return error.MetadataOverflow;
            total_label_bytes = std.math.add(usize, total_label_bytes, length) catch return error.MetadataOverflow;
            if (total_label_bytes > limits.max_synthesized_label_bytes) return error.InvalidMetadata;
        }
        var initialized: usize = 0;
        errdefer for (concepts[0..initialized]) |concept| allocator.free(concept.label);
        for (concepts, ids) |*concept, id| {
            const length = std.math.add(usize, prefix.len, decimalLength(id)) catch return error.MetadataOverflow;
            const label = allocator.alloc(u8, length) catch return error.OutOfMemory;
            var stream = std.Io.Writer.fixed(label);
            stream.print("{s}{}", .{ prefix, id }) catch return error.InvalidMetadata;
            concept.* = .{ .id = id, .label = label };
            initialized += 1;
        }
    } else if (mode == 0) {
        if (prefix_length != 0) return error.InvalidMetadata;
        const labels = try decodeStringTable(allocator, bytes, cursor, count);
        defer allocator.free(labels);
        for (concepts, ids, labels) |*concept, id, label| concept.* = .{ .id = id, .label = label };
    } else return error.InvalidMetadata;
    return concepts;
}

fn namesAreCanonical(names: []const []const u8) bool {
    if (names.len < 2) return true;
    for (names[1..], names[0 .. names.len - 1]) |name, previous|
        if (std.mem.order(u8, previous, name) != .lt) return false;
    return true;
}

fn validateInput(allocator: std.mem.Allocator, input: Input, limits: Limits) !void {
    if (input.entry_ids.len > limits.max_entries or input.senses.len > limits.max_senses or
        input.concepts.len > limits.max_concepts or input.max_key_bytes > limits.max_key_bytes or
        input.max_definition_bytes > limits.max_definition_bytes or
        !namesAreCanonical(input.languages) or !namesAreCanonical(input.sources)) return error.InvalidMetadata;
    var identities = std.AutoHashMap(i64, void).init(allocator);
    defer identities.deinit();
    try identities.ensureTotalCapacity(@intCast(@max(input.entry_ids.len, @max(input.senses.len, input.concepts.len))));
    for (input.entry_ids) |id| if ((try identities.getOrPut(id)).found_existing) return error.InvalidMetadata;
    identities.clearRetainingCapacity();
    for (input.senses) |sense| {
        if ((try identities.getOrPut(sense.id)).found_existing or sense.entry_rank >= input.entry_ids.len or sense.language >= input.languages.len)
            return error.InvalidMetadata;
    }
    identities.clearRetainingCapacity();
    for (input.concepts) |concept| if ((try identities.getOrPut(concept.id)).found_existing) return error.InvalidMetadata;
}

pub fn encodeWithLimits(allocator: std.mem.Allocator, input: Input, limits: Limits) ![]u8 {
    try validateInput(allocator, input, limits);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, magic);
    try appendInt(u16, &out, allocator, version);
    try appendInt(u16, &out, allocator, header_bytes);
    try appendInt(u64, &out, allocator, 0);
    try appendInt(u32, &out, allocator, std.math.cast(u32, input.entry_ids.len) orelse return error.MetadataOverflow);
    try appendInt(u32, &out, allocator, std.math.cast(u32, input.senses.len) orelse return error.MetadataOverflow);
    try appendInt(u32, &out, allocator, std.math.cast(u32, input.concepts.len) orelse return error.MetadataOverflow);
    try appendInt(u16, &out, allocator, std.math.cast(u16, input.languages.len) orelse return error.MetadataOverflow);
    try appendInt(u16, &out, allocator, std.math.cast(u16, input.sources.len) orelse return error.MetadataOverflow);
    try appendInt(u32, &out, allocator, input.max_key_bytes);
    try appendInt(u32, &out, allocator, input.max_definition_bytes);
    try appendInt(u64, &out, allocator, 0);
    var sense_ids = try allocator.alloc(i64, input.senses.len);
    defer allocator.free(sense_ids);
    var sense_entries = try allocator.alloc(i64, input.senses.len);
    defer allocator.free(sense_entries);
    var sense_languages = try allocator.alloc(i64, input.senses.len);
    defer allocator.free(sense_languages);
    var concept_ids = try allocator.alloc(i64, input.concepts.len);
    defer allocator.free(concept_ids);
    for (input.senses, 0..) |sense, index| {
        sense_ids[index] = sense.id;
        sense_entries[index] = sense.entry_rank;
        sense_languages[index] = sense.language;
    }
    for (input.concepts, 0..) |concept, index| concept_ids[index] = concept.id;
    try appendLane(&out, allocator, input.entry_ids);
    try appendLane(&out, allocator, sense_ids);
    try appendLane(&out, allocator, sense_entries);
    try appendLane(&out, allocator, sense_languages);
    try appendLane(&out, allocator, concept_ids);
    try appendStringTable(&out, allocator, input.languages);
    try appendStringTable(&out, allocator, input.sources);
    try appendLabels(&out, allocator, input.concepts);
    std.mem.writeInt(u64, out.items[8..16], std.math.cast(u64, out.items.len) orelse return error.MetadataOverflow, .little);
    return out.toOwnedSlice(allocator);
}

pub fn encode(allocator: std.mem.Allocator, input: Input) ![]u8 {
    return encodeWithLimits(allocator, input, .{});
}

pub fn decodeWithLimits(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) Error!Decoded {
    if (bytes.len < header_bytes or !std.mem.eql(u8, bytes[0..4], magic)) return error.InvalidMetadata;
    var cursor: usize = 4;
    if (try readInt(u16, bytes, &cursor) != version or try readInt(u16, bytes, &cursor) != header_bytes) return error.InvalidMetadata;
    if (try readInt(u64, bytes, &cursor) != bytes.len) return error.InvalidMetadata;
    const entry_count: usize = try readInt(u32, bytes, &cursor);
    const sense_count: usize = try readInt(u32, bytes, &cursor);
    const concept_count: usize = try readInt(u32, bytes, &cursor);
    const language_count: usize = try readInt(u16, bytes, &cursor);
    const source_count: usize = try readInt(u16, bytes, &cursor);
    const max_key_bytes = try readInt(u32, bytes, &cursor);
    const max_definition_bytes = try readInt(u32, bytes, &cursor);
    if (try readInt(u64, bytes, &cursor) != 0) return error.InvalidMetadata;
    const decoded_bytes = std.math.add(
        usize,
        std.math.mul(usize, entry_count, 8) catch return error.InvalidMetadata,
        std.math.add(
            usize,
            std.math.mul(usize, sense_count, 40) catch return error.InvalidMetadata,
            std.math.mul(usize, concept_count, 24) catch return error.InvalidMetadata,
        ) catch return error.InvalidMetadata,
    ) catch return error.InvalidMetadata;
    if (entry_count > limits.max_entries or sense_count > limits.max_senses or concept_count > limits.max_concepts or
        decoded_bytes > limits.max_decoded_bytes or max_key_bytes > limits.max_key_bytes or
        max_definition_bytes > limits.max_definition_bytes)
        return error.InvalidMetadata;
    const entry_ids = try decodeLane(allocator, bytes, &cursor, entry_count);
    errdefer allocator.free(entry_ids);
    const sense_ids = try decodeLane(allocator, bytes, &cursor, sense_count);
    defer allocator.free(sense_ids);
    const sense_entries = try decodeLane(allocator, bytes, &cursor, sense_count);
    defer allocator.free(sense_entries);
    const sense_languages = try decodeLane(allocator, bytes, &cursor, sense_count);
    defer allocator.free(sense_languages);
    const concept_ids = try decodeLane(allocator, bytes, &cursor, concept_count);
    defer allocator.free(concept_ids);
    const languages = try decodeStringTable(allocator, bytes, &cursor, language_count);
    errdefer allocator.free(languages);
    const sources = try decodeStringTable(allocator, bytes, &cursor, source_count);
    errdefer allocator.free(sources);
    const labels_at = cursor;
    const concepts = try decodeLabels(allocator, bytes, &cursor, concept_ids, limits);
    const owns_concept_labels = bytes[labels_at] == 1;
    errdefer {
        if (owns_concept_labels) for (concepts) |concept| allocator.free(concept.label);
        allocator.free(concepts);
    }
    if (cursor != bytes.len) return error.InvalidMetadata;
    const senses = allocator.alloc(Sense, sense_count) catch return error.OutOfMemory;
    errdefer allocator.free(senses);
    for (senses, sense_ids, sense_entries, sense_languages) |*sense, id, entry_rank, language| {
        if (entry_rank < 0 or entry_rank >= entry_count or language < 0 or language >= language_count) return error.InvalidMetadata;
        sense.* = .{ .id = id, .entry_rank = @intCast(entry_rank), .language = @intCast(language) };
    }
    if (!namesAreCanonical(languages) or !namesAreCanonical(sources)) return error.InvalidMetadata;
    var identities = std.AutoHashMap(i64, void).init(allocator);
    defer identities.deinit();
    identities.ensureTotalCapacity(@intCast(@max(entry_ids.len, @max(senses.len, concepts.len)))) catch return error.OutOfMemory;
    for (entry_ids) |id| if ((identities.getOrPut(id) catch return error.OutOfMemory).found_existing) return error.InvalidMetadata;
    identities.clearRetainingCapacity();
    for (senses) |sense| if ((identities.getOrPut(sense.id) catch return error.OutOfMemory).found_existing) return error.InvalidMetadata;
    identities.clearRetainingCapacity();
    for (concepts) |concept| if ((identities.getOrPut(concept.id) catch return error.OutOfMemory).found_existing) return error.InvalidMetadata;
    return .{
        .allocator = allocator,
        .bytes = bytes,
        .entry_ids = entry_ids,
        .senses = senses,
        .concepts = concepts,
        .languages = languages,
        .sources = sources,
        .max_key_bytes = max_key_bytes,
        .max_definition_bytes = max_definition_bytes,
        .owns_concept_labels = owns_concept_labels,
    };
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!Decoded {
    return decodeWithLimits(allocator, bytes, .{});
}

test "adaptive metadata round trips sparse identities and template labels" {
    const a = std.testing.allocator;
    const input: Input = .{
        .entry_ids = &.{ 7, 8, 10, -4000, 11 },
        .senses = &.{
            .{ .id = 0, .entry_rank = 0, .language = 0 },
            .{ .id = 107, .entry_rank = 2, .language = 1 },
        },
        .concepts = &.{
            .{ .id = 500, .label = "concept-500" },
            .{ .id = 501, .label = "concept-501" },
        },
        .languages = &.{ "en", "fr" },
        .sources = &.{"fixture"},
        .max_key_bytes = 31,
        .max_definition_bytes = 4097,
    };
    const encoded = try encode(a, input);
    defer a.free(encoded);
    var decoded = try decode(a, encoded);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(i64, input.entry_ids, decoded.entry_ids);
    try std.testing.expectEqual(input.max_definition_bytes, decoded.max_definition_bytes);
    try std.testing.expectEqualStrings("concept-501", decoded.concepts[1].label);
}

test "metadata rejects non-canonical packed tails and corrupt totals" {
    const a = std.testing.allocator;
    const encoded = try encode(a, .{
        .entry_ids = &.{ 1, 2, 4, 5 },
        .senses = &.{},
        .concepts = &.{},
        .languages = &.{},
        .sources = &.{},
        .max_key_bytes = 1,
        .max_definition_bytes = 1,
    });
    defer a.free(encoded);
    var corrupt = try a.dupe(u8, encoded);
    defer a.free(corrupt);
    corrupt[8] +%= 1;
    try std.testing.expectError(error.InvalidMetadata, decode(a, corrupt));

    const packed_wire = try encode(a, .{
        .entry_ids = &.{ 1, 2, 4 },
        .senses = &.{},
        .concepts = &.{},
        .languages = &.{},
        .sources = &.{},
        .max_key_bytes = 1,
        .max_definition_bytes = 1,
    });
    defer a.free(packed_wire);
    var bad_tail = try a.dupe(u8, packed_wire);
    defer a.free(bad_tail);
    // Header + lane header + base/dictionary prelude leaves the selector as
    // the last byte of this first lane.  Only its low two bits are live.
    bad_tail[72] |= 0x80;
    try std.testing.expectError(error.InvalidMetadata, decode(a, bad_tail));
}

test "adaptive lanes differentially round trip hostile integer shapes" {
    const a = std.testing.allocator;
    var random = std.Random.DefaultPrng.init(0x4c344d4450524f50);
    for (0..64) |_| {
        const count = random.random().intRangeAtMost(usize, 1, 300);
        const ids = try a.alloc(i64, count);
        defer a.free(ids);
        var value = random.random().intRangeAtMost(i64, -1_000_000_000, 1_000_000_000);
        for (ids, 0..) |*id, index| {
            if (index != 0) value += random.random().intRangeAtMost(i64, 1, 4096);
            id.* = value;
        }
        const encoded = try encode(a, .{
            .entry_ids = ids,
            .senses = &.{},
            .concepts = &.{},
            .languages = &.{},
            .sources = &.{},
            .max_key_bytes = 1,
            .max_definition_bytes = 1,
        });
        defer a.free(encoded);
        var decoded = try decode(a, encoded);
        defer decoded.deinit();
        try std.testing.expectEqualSlices(i64, ids, decoded.entry_ids);
    }
}

fn allocationFailureRoundTrip(allocator: std.mem.Allocator) !void {
    const encoded = try encode(allocator, .{
        .entry_ids = &.{ 10, 11, 13, -9000, 14 },
        .senses = &.{.{ .id = 70, .entry_rank = 2, .language = 0 }},
        .concepts = &.{.{ .id = 4, .label = "node-4" }},
        .languages = &.{"en"},
        .sources = &.{"fixture"},
        .max_key_bytes = 9,
        .max_definition_bytes = 99,
    });
    defer allocator.free(encoded);
    var decoded = try decode(allocator, encoded);
    defer decoded.deinit();
}

test "metadata encoding and decoding clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureRoundTrip, .{});
}
