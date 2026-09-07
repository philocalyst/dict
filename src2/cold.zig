//! Typed, lazily-touched metadata.
//!
//! Attribute bags and unresolved references matter for round-tripping, but
//! ordinary lookup should not parse them.  This section therefore has a tiny
//! sorted node directory and self-contained records.  `View.open` validates
//! the complete section only when `Snapshot.cold()` is requested.

const std = @import("std");
const wire = @import("wire.zig");

pub const Error = wire.Error || error{
    BadMagic,
    UnsupportedVersion,
    InvalidFormat,
    InvalidReference,
    InvalidUtf8,
    DuplicateAttribute,
    LimitExceeded,
};

pub const Status = enum(u8) {
    unresolved,
    dangling,
    external,
    _,
};

pub const Limits = struct {
    max_records: usize = 16 * 1024 * 1024,
    max_attributes_per_node: usize = 65_535,
    max_blob_bytes: usize = 64 * 1024 * 1024,
};

pub const AttributeInput = struct {
    name: []const u8,
    value: []const u8,
};

pub const UnresolvedInput = struct {
    bytes: []const u8,
    uri: ?[]const u8 = null,
    label: ?[]const u8 = null,
    status: Status = .unresolved,
};

pub const RecordInput = struct {
    node: u32,
    attributes: []const AttributeInput = &.{},
    unresolved: ?UnresolvedInput = null,
};

const magic = "CLD2";
const version: u16 = 2;
const Header = struct {
    magic: [4]u8,
    version: u16,
    header_size: u16,
    node_count: u32,
    record_count: u32,
    directory_offset: u32,
    data_offset: u32,
    reserved: u64,
};
const HeaderLayout = wire.Layout(Header);

const Record = struct {
    node: u32,
    flags: u8,
    status: Status,
    attribute_count: u16,
    attributes_offset: u32,
    attributes_length: u32,
    unresolved_offset: u32,
    unresolved_length: u32,
    reserved: u64,
};
const RecordLayout = wire.Layout(Record);

const attributes_flag: u8 = 1;
const unresolved_flag: u8 = 2;
const null_blob = std.math.maxInt(u32);

pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Records must already be in node order.  Requiring that at this boundary
/// keeps ordering bugs visible and makes byte output independent of sort
/// stability.  Attribute order is canonicalized because XML attribute order
/// is not semantically significant in this representation.
pub fn build(
    allocator: std.mem.Allocator,
    node_count: usize,
    records: []const RecordInput,
    limits: Limits,
) Error!Owned {
    if (node_count > std.math.maxInt(u32) or records.len > limits.max_records or records.len > std.math.maxInt(u32)) return error.LimitExceeded;

    const directory_bytes = try wire.mul(records.len, RecordLayout.size);
    const data_offset = try wire.add(HeaderLayout.size, directory_bytes);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);

    var encoded = try allocator.alloc(Record, records.len);
    defer allocator.free(encoded);
    var previous_node: ?u32 = null;

    for (records, 0..) |input, index| {
        if (input.node >= node_count or (previous_node != null and input.node <= previous_node.?)) return error.InvalidReference;
        previous_node = input.node;
        if (input.attributes.len > limits.max_attributes_per_node or input.attributes.len > std.math.maxInt(u16)) return error.LimitExceeded;

        const attributes_offset = data.items.len;
        if (input.attributes.len != 0) {
            const order = try allocator.alloc(usize, input.attributes.len);
            defer allocator.free(order);
            for (order, 0..) |*slot, i| slot.* = i;
            std.mem.sortUnstable(usize, order, input.attributes, struct {
                fn less(values: []const AttributeInput, a: usize, b: usize) bool {
                    return std.mem.lessThan(u8, values[a].name, values[b].name);
                }
            }.less);
            var previous_name: ?[]const u8 = null;
            for (order) |i| {
                const attribute = input.attributes[i];
                if (attribute.name.len == 0 or attribute.name.len > std.math.maxInt(u16) or
                    !std.unicode.utf8ValidateSlice(attribute.name) or !std.unicode.utf8ValidateSlice(attribute.value))
                    return error.InvalidUtf8;
                if (previous_name) |name| if (std.mem.eql(u8, name, attribute.name)) return error.DuplicateAttribute;
                previous_name = attribute.name;
                try appendBlob(u16, &data, allocator, attribute.name);
                try appendBlob(u32, &data, allocator, attribute.value);
            }
        }
        const attributes_length = data.items.len - attributes_offset;

        const unresolved_offset = data.items.len;
        if (input.unresolved) |target| {
            if (target.bytes.len > limits.max_blob_bytes) return error.LimitExceeded;
            if (target.uri) |uri| if (!std.unicode.utf8ValidateSlice(uri)) return error.InvalidUtf8;
            if (target.label) |label| if (!std.unicode.utf8ValidateSlice(label)) return error.InvalidUtf8;
            try appendBlob(u32, &data, allocator, target.bytes);
            try appendOptionalBlob(&data, allocator, target.uri);
            try appendOptionalBlob(&data, allocator, target.label);
        }
        const unresolved_length = data.items.len - unresolved_offset;
        if (data.items.len > limits.max_blob_bytes or data.items.len > std.math.maxInt(u32)) return error.LimitExceeded;

        encoded[index] = .{
            .node = input.node,
            .flags = (if (input.attributes.len != 0) attributes_flag else 0) |
                (if (input.unresolved != null) unresolved_flag else 0),
            .status = if (input.unresolved) |target| target.status else .unresolved,
            .attribute_count = @intCast(input.attributes.len),
            .attributes_offset = @intCast(attributes_offset),
            .attributes_length = @intCast(attributes_length),
            .unresolved_offset = @intCast(unresolved_offset),
            .unresolved_length = @intCast(unresolved_length),
            .reserved = 0,
        };
    }

    const total = try wire.add(data_offset, data.items.len);
    const bytes = try allocator.alloc(u8, total);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    try HeaderLayout.write(bytes, 0, .{
        .magic = magic.*,
        .version = version,
        .header_size = HeaderLayout.size,
        .node_count = @intCast(node_count),
        .record_count = @intCast(records.len),
        .directory_offset = HeaderLayout.size,
        .data_offset = @intCast(data_offset),
        .reserved = 0,
    });
    for (encoded, 0..) |record, i| try RecordLayout.write(bytes, HeaderLayout.size + i * RecordLayout.size, record);
    @memcpy(bytes[data_offset..], data.items);
    return .{ .allocator = allocator, .bytes = bytes };
}

pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

pub const AttributeIterator = struct {
    bytes: []const u8,
    remaining: usize,
    cursor: usize = 0,

    pub fn next(self: *AttributeIterator) Error!?Attribute {
        if (self.remaining == 0) {
            if (self.cursor != self.bytes.len) return error.InvalidFormat;
            return null;
        }
        const name = try readBlob(u16, self.bytes, &self.cursor);
        const value = try readBlob(u32, self.bytes, &self.cursor);
        self.remaining -= 1;
        return .{ .name = name, .value = value };
    }
};

pub const Unresolved = struct {
    bytes: []const u8,
    uri: ?[]const u8,
    label: ?[]const u8,
    status: Status,
};

pub const Metadata = struct {
    view: *const View,
    record: Record,

    pub fn attributes(self: Metadata) AttributeIterator {
        const bytes = self.view.data[self.record.attributes_offset..][0..self.record.attributes_length];
        return .{ .bytes = bytes, .remaining = self.record.attribute_count };
    }

    pub fn unresolved(self: Metadata) Error!?Unresolved {
        if (self.record.flags & unresolved_flag == 0) return null;
        const bytes = self.view.data[self.record.unresolved_offset..][0..self.record.unresolved_length];
        var cursor: usize = 0;
        const raw = try readBlob(u32, bytes, &cursor);
        const uri = try readOptionalBlob(bytes, &cursor);
        const label = try readOptionalBlob(bytes, &cursor);
        if (cursor != bytes.len) return error.InvalidFormat;
        return .{ .bytes = raw, .uri = uri, .label = label, .status = self.record.status };
    }
};

pub const View = struct {
    bytes: []const u8,
    directory: []const u8,
    data: []const u8,
    node_count: usize,
    record_count: usize,

    pub fn open(bytes: []const u8, expected_nodes: usize, limits: Limits) Error!View {
        const header = HeaderLayout.read(bytes, 0) catch |err| return mapWire(err);
        if (!std.mem.eql(u8, &header.magic, magic)) return error.BadMagic;
        if (header.version != version) return error.UnsupportedVersion;
        if (header.header_size != HeaderLayout.size or header.reserved != 0 or header.node_count != expected_nodes) return error.InvalidFormat;
        if (header.record_count > limits.max_records or header.directory_offset != HeaderLayout.size) return error.LimitExceeded;
        const record_count: usize = header.record_count;
        const directory_len = try wire.mul(record_count, RecordLayout.size);
        const expected_data = try wire.add(header.directory_offset, directory_len);
        if (header.data_offset != expected_data or expected_data > bytes.len or bytes.len - expected_data > limits.max_blob_bytes) return error.InvalidFormat;
        const result = View{
            .bytes = bytes,
            .directory = bytes[header.directory_offset..expected_data],
            .data = bytes[expected_data..],
            .node_count = expected_nodes,
            .record_count = record_count,
        };
        try result.validate(limits);
        return result;
    }

    fn validate(self: *const View, limits: Limits) Error!void {
        var previous_node: ?u32 = null;
        var previous_attributes_end: usize = 0;
        var previous_unresolved_end: usize = 0;
        for (0..self.record_count) |i| {
            const entry = try self.recordAt(i);
            if (entry.node >= self.node_count or (previous_node != null and entry.node <= previous_node.?) or
                entry.flags & ~(attributes_flag | unresolved_flag) != 0 or entry.reserved != 0 or
                entry.attribute_count > limits.max_attributes_per_node)
                return error.InvalidFormat;
            previous_node = entry.node;
            const attributes_end = try boundedEnd(self.data, entry.attributes_offset, entry.attributes_length);
            const unresolved_end = try boundedEnd(self.data, entry.unresolved_offset, entry.unresolved_length);
            if (entry.attributes_offset != previous_unresolved_end or entry.attributes_offset < previous_attributes_end or entry.unresolved_offset != attributes_end or
                entry.unresolved_offset < previous_unresolved_end)
                return error.InvalidFormat;
            if ((entry.flags & attributes_flag == 0) != (entry.attribute_count == 0 and entry.attributes_length == 0)) return error.InvalidFormat;
            if ((entry.flags & unresolved_flag == 0) != (entry.unresolved_length == 0)) return error.InvalidFormat;
            previous_attributes_end = attributes_end;
            previous_unresolved_end = unresolved_end;

            var attributes = (Metadata{ .view = self, .record = entry }).attributes();
            var previous_name: ?[]const u8 = null;
            while (try attributes.next()) |attribute| {
                if (attribute.name.len == 0 or !std.unicode.utf8ValidateSlice(attribute.name) or !std.unicode.utf8ValidateSlice(attribute.value)) return error.InvalidUtf8;
                if (previous_name) |name| if (std.mem.order(u8, name, attribute.name) != .lt) return error.InvalidFormat;
                previous_name = attribute.name;
            }
            if ((try (Metadata{ .view = self, .record = entry }).unresolved())) |target| {
                if (target.bytes.len > limits.max_blob_bytes) return error.LimitExceeded;
                if (target.uri) |uri| if (!std.unicode.utf8ValidateSlice(uri)) return error.InvalidUtf8;
                if (target.label) |label| if (!std.unicode.utf8ValidateSlice(label)) return error.InvalidUtf8;
            }
        }
        if (self.record_count != 0 and previous_unresolved_end != self.data.len) return error.InvalidFormat;
        if (self.record_count == 0 and self.data.len != 0) return error.InvalidFormat;
    }

    fn recordAt(self: *const View, index: usize) Error!Record {
        if (index >= self.record_count) return error.InvalidReference;
        return RecordLayout.read(self.directory, index * RecordLayout.size) catch |err| mapWire(err);
    }

    pub fn get(self: *const View, node: u32) Error!?Metadata {
        if (node >= self.node_count) return error.InvalidReference;
        var low: usize = 0;
        var high = self.record_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const entry = try self.recordAt(middle);
            if (entry.node < node) low = middle + 1 else high = middle;
        }
        if (low == self.record_count) return null;
        const found = try self.recordAt(low);
        return if (found.node == node) .{ .view = self, .record = found } else null;
    }
};

fn boundedEnd(bytes: []const u8, offset: u32, length: u32) Error!usize {
    const start: usize = offset;
    const end = try wire.add(start, length);
    if (end > bytes.len) return error.InvalidFormat;
    return end;
}

fn appendBlob(comptime Length: type, out: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) Error!void {
    const length = std.math.cast(Length, bytes.len) orelse return error.LimitExceeded;
    try wire.append(Length, out, allocator, length);
    try out.appendSlice(allocator, bytes);
}

fn appendOptionalBlob(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: ?[]const u8) Error!void {
    if (value) |bytes| {
        if (bytes.len >= null_blob) return error.LimitExceeded;
        try appendBlob(u32, out, allocator, bytes);
    } else try wire.append(u32, out, allocator, null_blob);
}

fn readBlob(comptime Length: type, bytes: []const u8, cursor: *usize) Error![]const u8 {
    const length = wire.readInt(Length, bytes, cursor.*) catch |err| return mapWire(err);
    cursor.* = try wire.add(cursor.*, @sizeOf(Length));
    const result = wire.slice(bytes, cursor.*, length) catch |err| return mapWire(err);
    cursor.* = try wire.add(cursor.*, length);
    return result;
}

fn readOptionalBlob(bytes: []const u8, cursor: *usize) Error!?[]const u8 {
    const length = wire.readInt(u32, bytes, cursor.*) catch |err| return mapWire(err);
    cursor.* = try wire.add(cursor.*, @sizeOf(u32));
    if (length == null_blob) return null;
    const result = wire.slice(bytes, cursor.*, length) catch |err| return mapWire(err);
    cursor.* = try wire.add(cursor.*, length);
    return result;
}

fn mapWire(err: wire.Error) Error {
    return switch (err) {
        error.Truncated => error.InvalidFormat,
        else => err,
    };
}

test "typed metadata is canonical and directly addressable" {
    const records = [_]RecordInput{.{
        .node = 2,
        .attributes = &.{
            .{ .name = "z", .value = "last" },
            .{ .name = "a", .value = "first" },
        },
        .unresolved = .{ .bytes = "tei:missing", .uri = "urn:tei:missing", .status = .external },
    }};
    var owned = try build(std.testing.allocator, 4, &records, .{});
    defer owned.deinit();
    const view = try View.open(owned.bytes, 4, .{});
    const metadata = (try view.get(2)).?;
    var attributes = metadata.attributes();
    try std.testing.expectEqualStrings("a", (try attributes.next()).?.name);
    try std.testing.expectEqualStrings("z", (try attributes.next()).?.name);
    try std.testing.expect((try attributes.next()) == null);
    const target = (try metadata.unresolved()).?;
    try std.testing.expectEqualStrings("tei:missing", target.bytes);
    try std.testing.expectEqual(Status.external, target.status);
}
