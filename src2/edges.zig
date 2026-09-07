//! Compressed predicate adjacency, including qualified shadow edges.
//!
//! Sources and cumulative degrees are monotone and use Elias--Fano. Targets
//! and optional assertion back-pointers use FOR frames. Materialized reverse
//! records have exactly the same representation, so query traversal never
//! needs a second code path or a hidden forest scan.

const std = @import("std");
const bits = @import("bits.zig");
const schema = @import("schema.zig");
const wire = @import("wire.zig");

pub const Error = bits.Error || wire.Error || error{
    BadMagic,
    UnsupportedVersion,
    InvalidFormat,
    InvalidReference,
    ReverseUnavailable,
    BufferTooSmall,
    LimitExceeded,
};

pub const Direction = enum(u8) { forward, reverse };
pub const Input = struct {
    predicate: schema.PredicateId,
    source: u32,
    target: u32,
    qualified: ?u32 = null,
};
pub const Edge = struct { target: schema.Node, qualified: ?schema.Node };

const magic = "EDG2";
const version: u16 = 2;
const Range = struct { offset: u32, length: u32 };
const Header = struct {
    magic: [4]u8,
    version: u16,
    header_size: u16,
    node_count: u32,
    record_count: u16,
    record_size: u16,
    directory_offset: u32,
    payload_offset: u32,
    reserved: u64,
};
const HeaderLayout = wire.Layout(Header);
const Record = struct {
    predicate: schema.PredicateId,
    direction: Direction,
    flags: u8,
    source_count: u32,
    edge_count: u32,
    sources: Range,
    offsets: Range,
    targets: Range,
    qualifiers: Range,
    reserved: u32,
};
const RecordLayout = wire.Layout(Record);
const no_qualifier: u64 = std.math.maxInt(u32);

pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

const Directional = struct {
    predicate: schema.PredicateId,
    direction: Direction,
    edges: std.ArrayList(Input) = .empty,
};

pub fn build(allocator: std.mem.Allocator, node_count: usize, input: []const Input) Error!Owned {
    if (node_count == 0 or node_count > std.math.maxInt(u32)) return error.LimitExceeded;
    const predicate_count = @typeInfo(schema.PredicateId).@"enum".fields.len;
    var reverse_count: usize = 0;
    inline for (schema.predicateTypes()) |predicate| if (predicate.reverse == .materialized) {
        reverse_count += 1;
    };
    const record_count = predicate_count + reverse_count;
    var records = try allocator.alloc(Directional, record_count);
    defer allocator.free(records);
    var initialized: usize = 0;
    defer for (records[0..initialized]) |*record| record.edges.deinit(allocator);

    for (0..predicate_count) |raw| {
        records[initialized] = .{ .predicate = @enumFromInt(raw), .direction = .forward };
        initialized += 1;
        if (schema.reversePolicy(@enumFromInt(raw)) == .materialized) {
            records[initialized] = .{ .predicate = @enumFromInt(raw), .direction = .reverse };
            initialized += 1;
        }
    }
    std.debug.assert(initialized == record_count);

    for (input) |edge| {
        if (edge.source >= node_count or edge.target >= node_count or (edge.qualified != null and edge.qualified.? >= node_count)) return error.InvalidReference;
        try records[recordIndex(records, edge.predicate, .forward).?].edges.append(allocator, edge);
        if (schema.reversePolicy(edge.predicate) == .materialized) {
            try records[recordIndex(records, edge.predicate, .reverse).?].edges.append(allocator, .{
                .predicate = edge.predicate,
                .source = edge.target,
                .target = edge.source,
                .qualified = edge.qualified,
            });
        }
    }
    for (records) |*record| {
        std.mem.sortUnstable(Input, record.edges.items, {}, lessEdge);
        record.edges.shrinkRetainingCapacity(deduplicate(record.edges.items));
    }

    const directory_bytes = try wire.mul(record_count, RecordLayout.size);
    var payload_at = try wire.add(HeaderLayout.size, directory_bytes);
    var encoded = try allocator.alloc(EncodedRecord, record_count);
    defer allocator.free(encoded);
    var encoded_count: usize = 0;
    defer for (encoded[0..encoded_count]) |*item| item.deinit();
    for (records, 0..) |*record, i| {
        encoded[i] = try encodeRecord(allocator, node_count, record.edges.items);
        encoded_count += 1;
        payload_at = try wire.add(payload_at, encoded[i].byteLen());
    }
    if (payload_at > std.math.maxInt(u32)) return error.LimitExceeded;

    const out = try allocator.alloc(u8, payload_at);
    errdefer allocator.free(out);
    @memset(out, 0);
    try HeaderLayout.write(out, 0, .{
        .magic = magic.*,
        .version = version,
        .header_size = HeaderLayout.size,
        .node_count = @intCast(node_count),
        .record_count = @intCast(record_count),
        .record_size = RecordLayout.size,
        .directory_offset = HeaderLayout.size,
        .payload_offset = @intCast(HeaderLayout.size + directory_bytes),
        .reserved = 0,
    });
    var cursor = HeaderLayout.size + directory_bytes;
    for (records, encoded, 0..) |record, *item, i| {
        const sources = try place(out, &cursor, item.sources.bytes);
        const offsets = try place(out, &cursor, item.offsets.bytes);
        const targets = try place(out, &cursor, item.targets.bytes);
        const qualifiers = try place(out, &cursor, item.qualifiers.bytes);
        try RecordLayout.write(out, HeaderLayout.size + i * RecordLayout.size, .{
            .predicate = record.predicate,
            .direction = record.direction,
            .flags = 0,
            .source_count = item.source_count,
            .edge_count = @intCast(record.edges.items.len),
            .sources = sources,
            .offsets = offsets,
            .targets = targets,
            .qualifiers = qualifiers,
            .reserved = 0,
        });
    }
    return .{ .allocator = allocator, .bytes = out };
}

const EncodedRecord = struct {
    sources: bits.OwnedBytes,
    offsets: bits.OwnedBytes,
    targets: bits.OwnedBytes,
    qualifiers: bits.OwnedBytes,
    source_count: u32,

    fn deinit(self: *EncodedRecord) void {
        self.sources.deinit();
        self.offsets.deinit();
        self.targets.deinit();
        self.qualifiers.deinit();
        self.* = undefined;
    }

    fn byteLen(self: *const EncodedRecord) usize {
        return self.sources.bytes.len + self.offsets.bytes.len + self.targets.bytes.len + self.qualifiers.bytes.len;
    }
};

fn encodeRecord(allocator: std.mem.Allocator, node_count: usize, input: []const Input) Error!EncodedRecord {
    var sources: std.ArrayList(u32) = .empty;
    defer sources.deinit(allocator);
    var offsets: std.ArrayList(u32) = .empty;
    defer offsets.deinit(allocator);
    var targets: std.ArrayList(u64) = .empty;
    defer targets.deinit(allocator);
    var qualifiers: std.ArrayList(u64) = .empty;
    defer qualifiers.deinit(allocator);
    const present = try allocator.alloc(bool, input.len);
    defer allocator.free(present);
    try offsets.append(allocator, 0);
    var i: usize = 0;
    while (i < input.len) {
        const source = input[i].source;
        try sources.append(allocator, source);
        while (i < input.len and input[i].source == source) : (i += 1) {
            try targets.append(allocator, input[i].target);
            present[i] = input[i].qualified != null;
            if (input[i].qualified) |node| try qualifiers.append(allocator, node);
        }
        try offsets.append(allocator, @intCast(i));
    }
    var source_bytes = try bits.encodeElias(allocator, sources.items, node_count);
    errdefer source_bytes.deinit();
    var offset_bytes = try bits.encodeElias(allocator, offsets.items, input.len + 1);
    errdefer offset_bytes.deinit();
    var target_bytes = try bits.encodeFor(allocator, targets.items, 256);
    errdefer target_bytes.deinit();
    var qualifier_bytes = try encodeQualifiers(allocator, present, qualifiers.items);
    errdefer qualifier_bytes.deinit();
    return .{
        .sources = source_bytes,
        .offsets = offset_bytes,
        .targets = target_bytes,
        .qualifiers = qualifier_bytes,
        .source_count = @intCast(sources.items.len),
    };
}

fn encodeQualifiers(allocator: std.mem.Allocator, present: []const bool, values: []const u64) Error!bits.OwnedBytes {
    if (values.len == 0) return .{ .allocator = allocator, .bytes = try allocator.alloc(u8, 0) };
    var bitmap = try bits.encodePresence(allocator, present);
    defer bitmap.deinit();
    var lane = try bits.encodeFor(allocator, values, 256);
    defer lane.deinit();
    const out = try allocator.alloc(u8, try wire.add(4, try wire.add(bitmap.bytes.len, lane.bytes.len)));
    errdefer allocator.free(out);
    try wire.writeInt(u32, out, 0, try wire.cast(u32, bitmap.bytes.len));
    @memcpy(out[4..][0..bitmap.bytes.len], bitmap.bytes);
    @memcpy(out[4 + bitmap.bytes.len ..], lane.bytes);
    return .{ .allocator = allocator, .bytes = out };
}

pub const EdgeIterator = struct {
    adjacency: *const Adjacency,
    index: usize,
    end: usize,

    pub fn next(self: *EdgeIterator) Error!?Edge {
        if (self.index == self.end) return null;
        const target = try self.adjacency.targets_column.get(self.index);
        const qualifier = try self.adjacency.qualifierAt(self.index);
        self.index += 1;
        if (target >= self.adjacency.node_count or qualifier > no_qualifier) return error.InvalidFormat;
        return .{
            .target = @enumFromInt(@as(u32, @intCast(target))),
            .qualified = if (qualifier == no_qualifier) null else @enumFromInt(@as(u32, @intCast(qualifier))),
        };
    }
};

pub const Adjacency = struct {
    sources: bits.EliasView,
    offsets: bits.EliasView,
    targets_column: bits.ForView,
    qualifier_presence: ?bits.PresenceView,
    qualifiers_column: ?bits.ForView,
    source_count: usize,
    edge_count: usize,
    node_count: usize,
    direction: Direction,

    fn qualifierAt(self: *const Adjacency, index: usize) Error!u64 {
        const presence = self.qualifier_presence orelse return no_qualifier;
        if (!try presence.isSet(index)) return no_qualifier;
        return self.qualifiers_column.?.get(try presence.rank(index));
    }

    pub fn edges(self: *const Adjacency, source: schema.Node) Error!EdgeIterator {
        const wanted = @intFromEnum(source);
        if (wanted >= self.node_count) return error.InvalidReference;
        var low: usize = 0;
        var high = self.source_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (try self.sources.get(middle) < wanted) low = middle + 1 else high = middle;
        }
        if (low == self.source_count or try self.sources.get(low) != wanted) return .{ .adjacency = self, .index = 0, .end = 0 };
        return .{
            .adjacency = self,
            .index = @intCast(try self.offsets.get(low)),
            .end = @intCast(try self.offsets.get(low + 1)),
        };
    }

    pub fn targets(self: *const Adjacency, source: schema.Node, out: []schema.Node) Error!usize {
        var iterator = try self.edges(source);
        var written: usize = 0;
        while (try iterator.next()) |edge| {
            if (written == out.len) return error.BufferTooSmall;
            out[written] = edge.target;
            written += 1;
        }
        return written;
    }

    pub fn contains(self: *const Adjacency, source: schema.Node, target: schema.Node, qualifier: ?schema.Node) Error!bool {
        const span = try self.edges(source);
        var low = span.index;
        var high = span.end;
        const wanted_target = @intFromEnum(target);
        const wanted_qualifier: u64 = if (qualifier) |q| @intFromEnum(q) else no_qualifier;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const t = try self.targets_column.get(mid);
            const q = try self.qualifierAt(mid);
            if (t < wanted_target or (t == wanted_target and q < wanted_qualifier)) low = mid + 1 else high = mid;
        }
        return low < span.end and try self.targets_column.get(low) == wanted_target and try self.qualifierAt(low) == wanted_qualifier;
    }
};

pub const View = struct {
    bytes: []const u8,
    node_count: usize,
    record_count: usize,
    directory: []const u8,
    indexes: [@typeInfo(schema.PredicateId).@"enum".fields.len * 2]?Adjacency = @splat(null),

    pub fn open(bytes: []const u8, expected_nodes: usize) Error!View {
        const header = HeaderLayout.read(bytes, 0) catch |err| return mapWire(err);
        if (!std.mem.eql(u8, &header.magic, magic)) return error.BadMagic;
        if (header.version != version) return error.UnsupportedVersion;
        const directory_len = try wire.mul(header.record_count, RecordLayout.size);
        const payload_offset = try wire.add(HeaderLayout.size, directory_len);
        if (header.header_size != HeaderLayout.size or header.record_size != RecordLayout.size or header.reserved != 0 or
            header.node_count != expected_nodes or header.directory_offset != HeaderLayout.size or
            header.payload_offset != payload_offset or payload_offset > bytes.len)
            return error.InvalidFormat;
        var result = View{
            .bytes = bytes,
            .node_count = expected_nodes,
            .record_count = header.record_count,
            .directory = bytes[HeaderLayout.size..payload_offset],
        };
        try result.validate(payload_offset);
        return result;
    }

    fn validate(self: *View, payload_offset: usize) Error!void {
        var cursor = payload_offset;
        var previous_key: ?u32 = null;
        for (0..self.record_count) |i| {
            const record = try self.recordAt(i);
            const key = @as(u32, @intFromEnum(record.predicate)) * 2 + @intFromEnum(record.direction);
            if (previous_key != null and key <= previous_key.? or record.flags != 0 or record.reserved != 0) return error.InvalidFormat;
            previous_key = key;
            inline for (.{ record.sources, record.offsets, record.targets, record.qualifiers }) |part| {
                if (part.offset != cursor) return error.InvalidFormat;
                cursor = try wire.add(cursor, part.length);
                if (cursor > self.bytes.len) return error.InvalidFormat;
            }
            const index = try adjacencyFrom(self, record);
            self.indexes[key] = index;
            if (index.source_count != record.source_count or index.edge_count != record.edge_count or
                index.sources.universe != self.node_count or index.offsets.universe != index.edge_count + 1 or
                index.offsets.count != index.source_count + 1 or index.targets_column.count != index.edge_count or
                try index.offsets.get(0) != 0 or
                try index.offsets.get(index.source_count) != index.edge_count)
                return error.InvalidFormat;
            if (index.qualifier_presence) |presence| {
                if (presence.count != index.edge_count or try presence.rank(presence.count) != index.qualifiers_column.?.count) return error.InvalidFormat;
            }
            var previous_source: ?u64 = null;
            for (0..index.source_count) |source_index| {
                const source = try index.sources.get(source_index);
                if (source >= self.node_count or (previous_source != null and source <= previous_source.?)) return error.InvalidFormat;
                previous_source = source;
                const begin: usize = @intCast(try index.offsets.get(source_index));
                const end: usize = @intCast(try index.offsets.get(source_index + 1));
                if (begin >= end or end > index.edge_count) return error.InvalidFormat;
                var previous_edge: ?struct { target: u64, qualifier: u64 } = null;
                for (begin..end) |edge_index| {
                    const target = try index.targets_column.get(edge_index);
                    const qualifier = try index.qualifierAt(edge_index);
                    if (target >= self.node_count or (qualifier != no_qualifier and qualifier >= self.node_count)) return error.InvalidFormat;
                    if (previous_edge) |prior| if (target < prior.target or target == prior.target and qualifier <= prior.qualifier) return error.InvalidFormat;
                    previous_edge = .{ .target = target, .qualifier = qualifier };
                }
            }
        }
        if (cursor != self.bytes.len) return error.InvalidFormat;
        inline for (@typeInfo(schema.PredicateId).@"enum".fields) |field| {
            const id: schema.PredicateId = @enumFromInt(field.value);
            if (self.indexes[field.value * 2] == null or
                (self.indexes[field.value * 2 + 1] != null) != (schema.reversePolicy(id) == .materialized)) return error.InvalidFormat;
        }
    }

    pub fn adjacency(self: *const View, predicate: schema.PredicateId, direction: Direction) Error!Adjacency {
        const wanted = @as(u32, @intFromEnum(predicate)) * 2 + @intFromEnum(direction);
        return self.indexes[wanted] orelse if (direction == .reverse) error.ReverseUnavailable else error.InvalidFormat;
    }

    fn recordAt(self: *const View, index: usize) Error!Record {
        if (index >= self.record_count) return error.InvalidFormat;
        return RecordLayout.read(self.directory, index * RecordLayout.size) catch |err| mapWire(err);
    }
};

fn adjacencyFrom(view: *const View, record: Record) Error!Adjacency {
    const sources = bits.EliasView.open(range(view.bytes, record.sources)) catch return error.InvalidFormat;
    const offsets = bits.EliasView.open(range(view.bytes, record.offsets)) catch return error.InvalidFormat;
    const targets = bits.ForView.open(range(view.bytes, record.targets)) catch return error.InvalidFormat;
    const qualifier_bytes = range(view.bytes, record.qualifiers);
    var presence: ?bits.PresenceView = null;
    var qualifiers: ?bits.ForView = null;
    if (qualifier_bytes.len != 0) {
        const bitmap_len = try wire.readInt(u32, qualifier_bytes, 0);
        presence = bits.PresenceView.open(try wire.slice(qualifier_bytes, 4, bitmap_len)) catch return error.InvalidFormat;
        qualifiers = bits.ForView.open(qualifier_bytes[try wire.add(4, bitmap_len)..]) catch return error.InvalidFormat;
    }
    return .{
        .sources = sources,
        .offsets = offsets,
        .targets_column = targets,
        .qualifiers_column = qualifiers,
        .qualifier_presence = presence,
        .source_count = record.source_count,
        .edge_count = record.edge_count,
        .node_count = view.node_count,
        .direction = record.direction,
    };
}

fn range(bytes: []const u8, part: Range) []const u8 {
    return bytes[part.offset..][0..part.length];
}

fn place(out: []u8, cursor: *usize, bytes: []const u8) Error!Range {
    const start = cursor.*;
    cursor.* = try wire.add(start, bytes.len);
    if (cursor.* > out.len or cursor.* > std.math.maxInt(u32)) return error.LimitExceeded;
    @memcpy(out[start..cursor.*], bytes);
    return .{ .offset = @intCast(start), .length = @intCast(bytes.len) };
}

fn recordIndex(records: []const Directional, predicate: schema.PredicateId, direction: Direction) ?usize {
    for (records, 0..) |record, i| if (record.predicate == predicate and record.direction == direction) return i;
    return null;
}

fn lessEdge(_: void, a: Input, b: Input) bool {
    if (a.source != b.source) return a.source < b.source;
    if (a.target != b.target) return a.target < b.target;
    return qualifierValue(a.qualified) < qualifierValue(b.qualified);
}

fn qualifierValue(value: ?u32) u64 {
    return if (value) |node| node else no_qualifier;
}

fn deduplicate(values: []Input) usize {
    var length: usize = 0;
    for (values) |value| {
        if (length == 0 or values[length - 1].source != value.source or values[length - 1].target != value.target or
            values[length - 1].qualified != value.qualified)
        {
            values[length] = value;
            length += 1;
        }
    }
    return length;
}

fn mapWire(err: wire.Error) Error {
    return switch (err) {
        error.Truncated, error.TrailingBytes, error.InvalidValue => error.InvalidFormat,
        else => err,
    };
}

test "materialized reverse edges preserve assertion qualifiers" {
    const input = [_]Input{
        .{ .predicate = .translation, .source = 1, .target = 4, .qualified = 2 },
        .{ .predicate = .translation, .source = 1, .target = 5 },
    };
    var owned = try build(std.testing.allocator, 6, &input);
    defer owned.deinit();
    const view = try View.open(owned.bytes, 6);
    const reverse = try view.adjacency(.translation, .reverse);
    var iterator = try reverse.edges(@enumFromInt(4));
    const edge = (try iterator.next()).?;
    try std.testing.expectEqual(@as(schema.Node, @enumFromInt(1)), edge.target);
    try std.testing.expectEqual(@as(?schema.Node, @enumFromInt(2)), edge.qualified);
    try std.testing.expect((try iterator.next()) == null);
    try std.testing.expectError(error.ReverseUnavailable, view.adjacency(.see_also, .reverse));
}
