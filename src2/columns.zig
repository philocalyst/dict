//! Schema-generated, kind-ranked columns.
//!
//! A physical node ID is never used as a column row. The forest maps it to a
//! dense rank among the kinds named by the descriptor. Optional columns add a
//! rankable presence bitmap over that domain and store values only for set
//! bits. Required columns therefore pay no presence overhead at all.

const std = @import("std");
const bits = @import("bits.zig");
const forest = @import("forest.zig");
const schema = @import("schema.zig");
const wire = @import("wire.zig");

pub const Error = bits.Error || forest.Error || wire.Error || error{
    BadMagic,
    UnsupportedVersion,
    InvalidFormat,
    InvalidColumn,
    InvalidReference,
    MissingRequiredValue,
    DuplicateValue,
    LimitExceeded,
    BudgetExceeded,
};

pub const ReadWork = struct {
    visited: *usize,
    indexed: *usize,
    limit: usize,

    fn consume(self: ReadWork) Error!void {
        if (self.visited.* >= self.limit) return error.BudgetExceeded;
        self.visited.* += 1;
        self.indexed.* += 1;
    }
};

pub const Value = union(schema.Repr) {
    atom: u32,
    key: u32,
    prose: u32,
    node: u32,
    enum_value: u8,
    span: schema.Span,
    bytes: []const u8,
    u64: u64,
    i64: i64,
};

pub const Input = struct {
    node: u32,
    id: schema.ColumnId,
    value: Value,
};

const magic = "COL2";
const version: u16 = 2;
const Range = struct { offset: u32, length: u32 };
const Header = struct {
    magic: [4]u8,
    version: u16,
    header_size: u16,
    node_count: u32,
    column_count: u16,
    record_size: u16,
    directory_offset: u32,
    payload_offset: u32,
    reserved: u64,
};
const HeaderLayout = wire.Layout(Header);
const Record = struct {
    id: schema.ColumnId,
    repr: schema.Repr,
    presence: schema.Presence,
    value_width: u8,
    domain_count: u32,
    value_count: u32,
    present: Range,
    data: Range,
    reserved: u64,
};
const RecordLayout = wire.Layout(Record);
const SpanLayout = wire.Layout(schema.Span);

pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

const Encoded = struct {
    presence: ?bits.OwnedBytes,
    data: []u8,
    allocator: std.mem.Allocator,
    domain_count: u32,
    value_count: u32,
    width: u8,

    fn deinit(self: *Encoded) void {
        if (self.presence) |*presence| presence.deinit();
        self.allocator.free(self.data);
        self.* = undefined;
    }
};

pub fn build(allocator: std.mem.Allocator, f: *const forest.View, input: []const Input) Error!Owned {
    try validateInputOrder(input, f.count);
    const column_types = schema.columnTypes();
    var encoded: [column_types.len]Encoded = undefined;
    var encoded_count: usize = 0;
    defer for (encoded[0..encoded_count]) |*column| column.deinit();

    var cursor: usize = 0;
    inline for (column_types, 0..) |Column, i| {
        const start = cursor;
        while (cursor < input.len and input[cursor].id == Column.Id) : (cursor += 1) {}
        encoded[i] = try encodeColumn(Column, allocator, f, input[start..cursor]);
        encoded_count += 1;
    }
    if (cursor != input.len) return error.InvalidColumn;

    const directory_len = try wire.mul(column_types.len, RecordLayout.size);
    var total = try wire.add(HeaderLayout.size, directory_len);
    for (&encoded) |*column| {
        if (column.presence) |presence| total = try wire.add(total, presence.bytes.len);
        total = try wire.add(total, column.data.len);
    }
    if (total > std.math.maxInt(u32)) return error.LimitExceeded;
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    @memset(out, 0);
    try HeaderLayout.write(out, 0, .{
        .magic = magic.*,
        .version = version,
        .header_size = HeaderLayout.size,
        .node_count = @intCast(f.count),
        .column_count = column_types.len,
        .record_size = RecordLayout.size,
        .directory_offset = HeaderLayout.size,
        .payload_offset = @intCast(HeaderLayout.size + directory_len),
        .reserved = 0,
    });
    var payload_at = HeaderLayout.size + directory_len;
    inline for (column_types, &encoded, 0..) |Column, *column, i| {
        const present = if (column.presence) |presence| try place(out, &payload_at, presence.bytes) else Range{ .offset = @intCast(payload_at), .length = 0 };
        const data = try place(out, &payload_at, column.data);
        try RecordLayout.write(out, HeaderLayout.size + i * RecordLayout.size, .{
            .id = Column.Id,
            .repr = Column.repr,
            .presence = Column.presence,
            .value_width = column.width,
            .domain_count = column.domain_count,
            .value_count = column.value_count,
            .present = present,
            .data = data,
            .reserved = 0,
        });
    }
    return .{ .allocator = allocator, .bytes = out };
}

fn encodeColumn(comptime Column: type, allocator: std.mem.Allocator, f: *const forest.View, input: []const Input) Error!Encoded {
    const domain_count = try f.countKinds(Column.over);
    if (domain_count > std.math.maxInt(u32)) return error.LimitExceeded;
    var present = try allocator.alloc(bool, domain_count);
    defer allocator.free(present);
    @memset(present, false);
    var values: std.ArrayList(Value) = .empty;
    defer values.deinit(allocator);

    var input_index: usize = 0;
    var domain_index: usize = 0;
    for (0..f.count) |node| {
        if (!Column.over.has(try f.kind(@enumFromInt(@as(u32, @intCast(node)))))) continue;
        if (input_index < input.len and input[input_index].node < node) return error.InvalidColumn;
        if (input_index < input.len and input[input_index].node == node) {
            if (std.meta.activeTag(input[input_index].value) != Column.repr) return error.InvalidColumn;
            present[domain_index] = true;
            try values.append(allocator, input[input_index].value);
            input_index += 1;
        } else if (Column.presence == .required) return error.MissingRequiredValue;
        domain_index += 1;
    }
    if (input_index != input.len or domain_index != domain_count) return error.InvalidColumn;

    var presence: ?bits.OwnedBytes = null;
    // Empty and total domains carry their own presence proof in the counts.
    // Only mixed domains need a bitmap; an absent column costs no payload.
    if (Column.presence != .required and values.items.len != 0 and values.items.len != domain_count)
        presence = try bits.encodePresence(allocator, present);
    errdefer if (presence) |*bitmap| bitmap.deinit();
    const width = laneWidth(Column.repr, values.items);
    return .{
        .presence = presence,
        .data = try encodeValues(allocator, Column.repr, values.items, width),
        .allocator = allocator,
        .domain_count = @intCast(domain_count),
        .value_count = @intCast(values.items.len),
        .width = width,
    };
}

fn encodeValues(allocator: std.mem.Allocator, repr: schema.Repr, values: []const Value, width: u8) Error![]u8 {
    if (values.len == 0) return allocator.alloc(u8, 0);
    if (isScalar(repr)) {
        const length = (try wire.add(try wire.mul(values.len, width), 7)) / 8;
        const out = try allocator.alloc(u8, length);
        errdefer allocator.free(out);
        @memset(out, 0);
        for (values, 0..) |value, i| try bits.writeBits(out, i * width, width, scalar(value));
        return out;
    }
    if (repr == .bytes) {
        var data_len: usize = 0;
        for (values) |value| data_len = try wire.add(data_len, value.bytes.len);
        const table_len = try wire.mul(values.len + 1, @sizeOf(u32));
        const out = try allocator.alloc(u8, try wire.add(table_len, data_len));
        errdefer allocator.free(out);
        @memset(out, 0);
        var at: usize = 0;
        for (values, 0..) |value, i| {
            try wire.writeInt(u32, out, i * 4, @intCast(at));
            @memcpy(out[table_len + at ..][0..value.bytes.len], value.bytes);
            at = try wire.add(at, value.bytes.len);
            if (at > std.math.maxInt(u32)) return error.LimitExceeded;
        }
        try wire.writeInt(u32, out, values.len * 4, @intCast(at));
        return out;
    }
    const out = try allocator.alloc(u8, try wire.mul(values.len, width));
    errdefer allocator.free(out);
    @memset(out, 0);
    for (values, 0..) |value, i| try SpanLayout.write(out, i * width, value.span);
    return out;
}

pub const View = struct {
    bytes: []const u8,
    directory: []const u8,
    node_count: usize,
    column_count: usize,
    records: [schema.columnTypes().len]Record = undefined,
    presences: [schema.columnTypes().len]?bits.PresenceView = @splat(null),

    pub fn open(bytes: []const u8, expected_nodes: usize, f: *const forest.View) Error!View {
        const header = HeaderLayout.read(bytes, 0) catch |err| return mapWire(err);
        if (!std.mem.eql(u8, &header.magic, magic)) return error.BadMagic;
        if (header.version != version) return error.UnsupportedVersion;
        const directory_len = try wire.mul(header.column_count, RecordLayout.size);
        const payload_offset = try wire.add(HeaderLayout.size, directory_len);
        if (header.header_size != HeaderLayout.size or header.record_size != RecordLayout.size or header.reserved != 0 or
            header.node_count != expected_nodes or expected_nodes != f.count or header.column_count != schema.columnTypes().len or
            header.directory_offset != HeaderLayout.size or header.payload_offset != payload_offset or payload_offset > bytes.len)
            return error.InvalidFormat;
        var result = View{
            .bytes = bytes,
            .directory = bytes[HeaderLayout.size..payload_offset],
            .node_count = expected_nodes,
            .column_count = header.column_count,
        };
        try result.validate(f, payload_offset);
        return result;
    }

    fn validate(self: *View, f: *const forest.View, payload_offset: usize) Error!void {
        var cursor = payload_offset;
        inline for (schema.columnTypes(), 0..) |Column, i| {
            const record = try RecordLayout.read(self.directory, i * RecordLayout.size);
            self.records[i] = record;
            const expected_domain = try f.countKinds(Column.over);
            if (record.id != Column.Id or record.repr != Column.repr or record.presence != Column.presence or
                (if (isScalar(Column.repr)) record.value_width > 64 else record.value_width != fixedWidth(Column.repr)) or record.domain_count != expected_domain or
                record.value_count > record.domain_count or record.reserved != 0 or record.present.offset != cursor)
                return error.InvalidFormat;
            if (Column.presence == .required) {
                if (record.present.length != 0 or record.value_count != record.domain_count) return error.InvalidFormat;
            } else if (record.present.length == 0) {
                if (record.value_count != 0 and record.value_count != record.domain_count) return error.InvalidFormat;
            } else {
                const present_end = try wire.add(cursor, record.present.length);
                if (present_end > self.bytes.len) return error.InvalidFormat;
                const presence = bits.PresenceView.open(range(self.bytes, record.present)) catch return error.InvalidFormat;
                self.presences[i] = presence;
                if (presence.count != record.domain_count or try presence.rank(presence.count) != record.value_count) return error.InvalidFormat;
            }
            cursor = try wire.add(cursor, record.present.length);
            if (record.data.offset != cursor) return error.InvalidFormat;
            cursor = try wire.add(cursor, record.data.length);
            if (cursor > self.bytes.len) return error.InvalidFormat;
            try validateData(range(self.bytes, record.data), Column.repr, record.value_count, record.value_width, f);
        }
        if (cursor != self.bytes.len) return error.InvalidFormat;
    }

    pub fn get(self: *const View, comptime Column: type, node: schema.Node, f: *const forest.View) Error!?Column.Value {
        return self.getMetered(Column, node, f, null);
    }

    pub fn getMetered(self: *const View, comptime Column: type, node: schema.Node, f: *const forest.View, work: ?ReadWork) Error!?Column.Value {
        comptime assertColumn(Column);
        // Inherited descriptors may be requested on any descendant even when
        // that descendant has no physical row in the kind-ranked domain.
        if (Column.presence != .optional_inherited and !Column.over.has(try f.kind(node))) return null;
        var current = node;
        while (true) {
            if (work) |meter| try meter.consume();
            if (Column.over.has(try f.kind(current))) {
                const domain_index = try f.kindRank(Column.over, current);
                const record = try self.recordAt(@intFromEnum(Column.Id));
                const value_index = if (Column.presence == .required) domain_index else blk: {
                    if (record.value_count == record.domain_count) break :blk domain_index;
                    if (self.presences[@intFromEnum(Column.Id)]) |presence|
                        if (try presence.isSet(domain_index)) break :blk try presence.rank(domain_index);
                    if (Column.presence != .optional_inherited) return null;
                    break :blk std.math.maxInt(usize);
                };
                if (value_index != std.math.maxInt(usize)) return try readValue(Column, range(self.bytes, record.data), value_index, record.value_count, record.value_width, f);
            }
            if (Column.presence != .optional_inherited) return null;
            current = (try f.parentOf(current)) orelse return null;
        }
    }

    fn recordAt(self: *const View, index: usize) Error!Record {
        if (index >= self.column_count) return error.InvalidColumn;
        return self.records[index];
    }
};

fn readValue(comptime Column: type, data: []const u8, index: usize, count: usize, width: u8, f: *const forest.View) Error!Column.Value {
    if (index >= count) return error.InvalidFormat;
    const at = try wire.mul(index, fixedWidth(Column.repr));
    const raw = if (comptime isScalar(Column.repr)) try bits.readBits(data, try wire.mul(index, width), width) else 0;
    return switch (Column.repr) {
        .atom => enumId(schema.Atom, try wire.cast(u32, raw)),
        .key => enumId(schema.Key, try wire.cast(u32, raw)),
        .prose => enumId(schema.Prose, try wire.cast(u32, raw)),
        .node => blk: {
            if (raw >= f.count) return error.InvalidReference;
            break :blk @enumFromInt(@as(u32, @intCast(raw)));
        },
        .enum_value => typedEnum(Column.Value, try wire.cast(u8, raw)),
        .span => blk: {
            const span = try SpanLayout.read(data, at);
            if (span.end < span.start) return error.InvalidFormat;
            break :blk span;
        },
        .bytes => blk: {
            const table_len = try wire.mul(count + 1, 4);
            const start = try wire.readInt(u32, data, index * 4);
            const end = try wire.readInt(u32, data, (index + 1) * 4);
            if (end < start or end > data.len - table_len) return error.InvalidFormat;
            break :blk data[table_len + start .. table_len + end];
        },
        .u64 => raw,
        .i64 => @bitCast(raw),
    };
}

fn typedEnum(comptime T: type, raw: u8) Error!T {
    return switch (@typeInfo(T)) {
        .@"enum" => |info| if (info.is_exhaustive)
            std.enums.fromInt(T, raw) orelse error.InvalidFormat
        else
            @enumFromInt(raw),
        .int => std.math.cast(T, raw) orelse error.InvalidFormat,
        else => comptime unreachable,
    };
}

fn enumId(comptime T: type, raw: u32) Error!T {
    if (raw == std.math.maxInt(u32)) return error.InvalidReference;
    return @enumFromInt(raw);
}

fn validateData(data: []const u8, repr: schema.Repr, count: usize, width: u8, f: *const forest.View) Error!void {
    if (count == 0) return if (data.len == 0) {} else error.InvalidFormat;
    if (isScalar(repr)) {
        const used = try wire.mul(count, width);
        if (data.len != (try wire.add(used, 7)) / 8) return error.InvalidFormat;
        if (used % 8 != 0 and data[data.len - 1] >> @as(u3, @intCast(used % 8)) != 0) return error.InvalidFormat;
        var maximum: u64 = 0;
        for (0..count) |i| {
            const raw = try bits.readBits(data, i * width, width);
            maximum = @max(maximum, raw);
            switch (repr) {
                .atom, .key, .prose => if (raw >= std.math.maxInt(u32)) return error.InvalidReference,
                .node => if (raw >= f.count) return error.InvalidReference,
                .enum_value => if (raw > std.math.maxInt(u8)) return error.InvalidFormat,
                else => {},
            }
        }
        if (width != (if (maximum == 0) @as(u8, 0) else @as(u8, @intCast(64 - @clz(maximum))))) return error.InvalidFormat;
        return;
    }
    if (repr == .bytes) {
        const table_len = try wire.mul(count + 1, 4);
        if (table_len > data.len or try wire.readInt(u32, data, 0) != 0) return error.InvalidFormat;
        var previous: u32 = 0;
        for (1..count + 1) |i| {
            const offset = try wire.readInt(u32, data, i * 4);
            if (offset < previous or offset > data.len - table_len) return error.InvalidFormat;
            previous = offset;
        }
        if (previous != data.len - table_len) return error.InvalidFormat;
        return;
    }
    if (data.len != try wire.mul(count, fixedWidth(repr))) return error.InvalidFormat;
    if (repr == .node) for (0..count) |i| if (try wire.readInt(u32, data, i * 4) >= f.count) return error.InvalidReference;
    if (repr == .span) for (0..count) |i| {
        const span = try SpanLayout.read(data, i * SpanLayout.size);
        if (span.end < span.start) return error.InvalidFormat;
    };
}

fn isScalar(repr: schema.Repr) bool {
    return repr != .bytes and repr != .span;
}

fn scalar(value: Value) u64 {
    return switch (value) {
        .atom, .key, .prose, .node => |v| v,
        .enum_value => |v| v,
        .u64 => |v| v,
        .i64 => |v| @bitCast(v),
        else => unreachable,
    };
}

fn laneWidth(repr: schema.Repr, values: []const Value) u8 {
    if (!isScalar(repr)) return fixedWidth(repr);
    var maximum: u64 = 0;
    for (values) |value| maximum = @max(maximum, scalar(value));
    return if (maximum == 0) 0 else @intCast(64 - @clz(maximum));
}

fn fixedWidth(repr: schema.Repr) u8 {
    return switch (repr) {
        .atom, .key, .prose, .node => 4,
        .enum_value => 1,
        .span => SpanLayout.size,
        .bytes => 0,
        .u64, .i64 => 8,
    };
}

fn validateInputOrder(input: []const Input, node_count: usize) Error!void {
    var previous: ?Input = null;
    for (input) |value| {
        if (value.node >= node_count) return error.InvalidReference;
        if (previous) |prior| {
            if (@intFromEnum(value.id) < @intFromEnum(prior.id) or
                value.id == prior.id and value.node < prior.node)
                return error.InvalidColumn;
            if (value.id == prior.id and value.node == prior.node) return error.DuplicateValue;
        }
        previous = value;
    }
}

fn assertColumn(comptime Column: type) void {
    schema.assertColumn(Column);
}

fn place(out: []u8, cursor: *usize, bytes: []const u8) Error!Range {
    const start = cursor.*;
    cursor.* = try wire.add(start, bytes.len);
    if (cursor.* > out.len or cursor.* > std.math.maxInt(u32)) return error.LimitExceeded;
    @memcpy(out[start..cursor.*], bytes);
    return .{ .offset = @intCast(start), .length = @intCast(bytes.len) };
}

fn range(bytes: []const u8, part: Range) []const u8 {
    return bytes[part.offset..][0..part.length];
}

fn mapWire(err: wire.Error) Error {
    return switch (err) {
        error.Truncated, error.TrailingBytes, error.InvalidValue => error.InvalidFormat,
        else => err,
    };
}
