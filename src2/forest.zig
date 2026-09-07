//! Preorder forest storage and navigation.
//!
//! The wire section uses the same packed primitives exposed by `bits.zig`:
//! FOR frames for subtree sizes and parent deltas, Elias--Fano for roots, and
//! one Elias--Fano select list per kind. The latter makes `all(.sense)` an
//! index walk instead of a politely disguised node scan.

const std = @import("std");
const bits = @import("bits.zig");
const schema = @import("schema.zig");
const wire = @import("wire.zig");

pub const Node = schema.Node;
pub const Error = bits.Error || wire.Error || error{
    BadMagic,
    UnsupportedVersion,
    InvalidNode,
    InvalidForest,
    BufferTooSmall,
    LimitExceeded,
};

pub const frame_size: usize = 1024;
pub const rank_stride: usize = 256;
const rank_shift: u8 = 8;
const kind_count = @intFromEnum(schema.Kind.any);
const kind_width: u8 = std.math.log2_int_ceil(u8, kind_count);
const magic = "FST2";
const version: u16 = 2;

const Range = struct { offset: u32, length: u32 };
const Header = struct {
    magic: [4]u8,
    version: u16,
    header_size: u16,
    node_count: u32,
    root_count: u32,
    kinds: u16,
    kind_width: u8,
    rank_shift: u8,
    subtree: Range,
    parents: Range,
    roots: Range,
    kind_stream: Range,
    kind_ranks: Range,
    kind_directory: Range,
    kind_indexes: Range,
    reserved: u64,
};
const HeaderLayout = wire.Layout(Header);
const KindRecord = struct { offset: u32, length: u32, count: u32, reserved: u32 };
const KindRecordLayout = wire.Layout(KindRecord);

pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Encodes already-preordered structural columns. Parent values are positive
/// backward deltas; zero is reserved for roots and cannot collide with a real
/// parent.
pub fn encode(
    allocator: std.mem.Allocator,
    subtree: []const u32,
    parent_delta: []const u32,
    roots: []const u32,
    kinds: []const schema.Kind,
) Error!Owned {
    try validateLogical(subtree, parent_delta, roots, kinds);

    var subtree_bytes = try bits.encodeFor(allocator, subtree, frame_size);
    defer subtree_bytes.deinit();
    var parent_bytes = try bits.encodeFor(allocator, parent_delta, frame_size);
    defer parent_bytes.deinit();
    var root_bytes = try bits.encodeElias(allocator, roots, subtree.len);
    defer root_bytes.deinit();

    const kind_bits = try bitBytes(try wire.mul(kinds.len, kind_width));
    const checkpoints = kinds.len / rank_stride + 1;
    const ranks_len = try wire.mul(try wire.mul(checkpoints, kind_count), @sizeOf(u32));
    const directory_len = kind_count * KindRecordLayout.size;

    var by_kind: [kind_count]std.ArrayList(u32) = @splat(.empty);
    defer for (&by_kind) |*list| list.deinit(allocator);
    for (kinds, 0..) |kind, node| try by_kind[@intFromEnum(kind)].append(allocator, @intCast(node));

    var indexes: [kind_count]bits.OwnedBytes = undefined;
    var encoded_indexes: usize = 0;
    defer for (indexes[0..encoded_indexes]) |*item| item.deinit();
    var indexes_len: usize = 0;
    for (&by_kind, 0..) |*list, i| {
        indexes[i] = if (list.items.len == 0)
            .{ .allocator = allocator, .bytes = try allocator.alloc(u8, 0) }
        else
            try bits.encodeElias(allocator, list.items, subtree.len);
        encoded_indexes += 1;
        indexes_len = try wire.add(indexes_len, indexes[i].bytes.len);
    }

    var cursor = HeaderLayout.size;
    const subtree_range = try reserve(&cursor, subtree_bytes.bytes.len);
    const parent_range = try reserve(&cursor, parent_bytes.bytes.len);
    const root_range = try reserve(&cursor, root_bytes.bytes.len);
    const kinds_range = try reserve(&cursor, kind_bits);
    const ranks_range = try reserve(&cursor, ranks_len);
    const directory_range = try reserve(&cursor, directory_len);
    const indexes_range = try reserve(&cursor, indexes_len);
    const out = try allocator.alloc(u8, cursor);
    errdefer allocator.free(out);
    @memset(out, 0);

    try HeaderLayout.write(out, 0, .{
        .magic = magic.*,
        .version = version,
        .header_size = HeaderLayout.size,
        .node_count = @intCast(subtree.len),
        .root_count = @intCast(roots.len),
        .kinds = kind_count,
        .kind_width = kind_width,
        .rank_shift = rank_shift,
        .subtree = subtree_range,
        .parents = parent_range,
        .roots = root_range,
        .kind_stream = kinds_range,
        .kind_ranks = ranks_range,
        .kind_directory = directory_range,
        .kind_indexes = indexes_range,
        .reserved = 0,
    });
    copyRange(out, subtree_range, subtree_bytes.bytes);
    copyRange(out, parent_range, parent_bytes.bytes);
    copyRange(out, root_range, root_bytes.bytes);

    const kind_stream = mutRange(out, kinds_range);
    for (kinds, 0..) |kind, i| try bits.writeBits(kind_stream, i * kind_width, kind_width, @intFromEnum(kind));

    const rank_bytes = mutRange(out, ranks_range);
    var counts = [_]u32{0} ** kind_count;
    for (0..checkpoints) |checkpoint| {
        const row = checkpoint * kind_count * @sizeOf(u32);
        for (counts, 0..) |count, kind| try wire.writeInt(u32, rank_bytes, row + kind * 4, count);
        const start = checkpoint * rank_stride;
        for (kinds[start..@min(kinds.len, start + rank_stride)]) |kind| counts[@intFromEnum(kind)] += 1;
    }

    var index_cursor: usize = indexes_range.offset;
    for (&indexes, 0..) |*index, kind| {
        try KindRecordLayout.write(out, directory_range.offset + kind * KindRecordLayout.size, .{
            .offset = @intCast(index_cursor),
            .length = @intCast(index.bytes.len),
            .count = @intCast(by_kind[kind].items.len),
            .reserved = 0,
        });
        @memcpy(out[index_cursor..][0..index.bytes.len], index.bytes);
        index_cursor += index.bytes.len;
    }
    return .{ .allocator = allocator, .bytes = out };
}

pub const KindIterator = struct {
    sequence: ?bits.EliasView,
    position: usize = 0,

    pub fn next(self: *KindIterator) Error!?Node {
        const sequence = self.sequence orelse return null;
        if (self.position == sequence.count) return null;
        const raw = try sequence.get(self.position);
        self.position += 1;
        return @enumFromInt(@as(u32, @intCast(raw)));
    }
};

pub const View = struct {
    bytes: []const u8,
    subtree_column: bits.ForView,
    parent_column: bits.ForView,
    root_column: bits.EliasView,
    kinds: []const u8,
    ranks: []const u8,
    kind_directory: []const u8,
    count: usize,
    root_count: usize,
    indexes: [kind_count]?bits.EliasView = @splat(null),

    pub fn open(bytes: []const u8) Error!View {
        const header = HeaderLayout.read(bytes, 0) catch |err| return mapWire(err);
        if (!std.mem.eql(u8, &header.magic, magic)) return error.BadMagic;
        if (header.version != version) return error.UnsupportedVersion;
        if (header.header_size != HeaderLayout.size or header.reserved != 0 or header.kinds != kind_count or
            header.kind_width != kind_width or header.rank_shift != rank_shift or header.node_count == 0)
            return error.InvalidForest;
        const count: usize = header.node_count;
        const root_count: usize = header.root_count;
        if (root_count == 0 or root_count > count) return error.InvalidForest;

        var expected = HeaderLayout.size;
        inline for (.{ header.subtree, header.parents, header.roots, header.kind_stream, header.kind_ranks, header.kind_directory, header.kind_indexes }) |part| {
            if (part.offset != expected) return error.InvalidForest;
            expected = try wire.add(expected, part.length);
        }
        if (expected != bytes.len or header.kind_stream.length != try bitBytes(try wire.mul(count, kind_width))) return error.InvalidForest;
        const checkpoints = count / rank_stride + 1;
        if (header.kind_ranks.length != try wire.mul(try wire.mul(checkpoints, kind_count), 4) or
            header.kind_directory.length != kind_count * KindRecordLayout.size)
            return error.InvalidForest;

        const subtree = bits.ForView.open(constRange(bytes, header.subtree)) catch return error.InvalidForest;
        const parents = bits.ForView.open(constRange(bytes, header.parents)) catch return error.InvalidForest;
        const roots = bits.EliasView.open(constRange(bytes, header.roots)) catch return error.InvalidForest;
        if (subtree.count != count or parents.count != count or roots.count != root_count or roots.universe != count) return error.InvalidForest;

        var result = View{
            .bytes = bytes,
            .subtree_column = subtree,
            .parent_column = parents,
            .root_column = roots,
            .kinds = constRange(bytes, header.kind_stream),
            .ranks = constRange(bytes, header.kind_ranks),
            .kind_directory = constRange(bytes, header.kind_directory),
            .count = count,
            .root_count = root_count,
        };
        try result.validate(header.kind_indexes);
        return result;
    }

    fn validate(self: *View, indexes_range: Range) Error!void {
        var previous_index_end: usize = indexes_range.offset;
        var indexed_nodes: usize = 0;
        for (0..kind_count) |kind_ordinal| {
            const record = try KindRecordLayout.read(self.kind_directory, kind_ordinal * KindRecordLayout.size);
            if (record.reserved != 0 or record.offset != previous_index_end) return error.InvalidForest;
            const end = try wire.add(record.offset, record.length);
            if (end > self.bytes.len or end > indexes_range.offset + indexes_range.length) return error.InvalidForest;
            if (record.count == 0) {
                if (record.length != 0) return error.InvalidForest;
                continue;
            }
            const sequence = bits.EliasView.open(self.bytes[record.offset..end]) catch return error.InvalidForest;
            if (sequence.count != record.count or sequence.universe != self.count) return error.InvalidForest;
            var previous: ?usize = null;
            for (0..sequence.count) |i| {
                const node = std.math.cast(usize, try sequence.get(i)) orelse return error.InvalidForest;
                if (previous) |prior| if (node <= prior) return error.InvalidForest;
                previous = node;
                if (try self.kind(@enumFromInt(@as(u32, @intCast(node)))) != @as(schema.Kind, @enumFromInt(kind_ordinal))) return error.InvalidForest;
            }
            self.indexes[kind_ordinal] = sequence;
            indexed_nodes = try wire.add(indexed_nodes, sequence.count);
            previous_index_end = end;
        }
        if (previous_index_end != indexes_range.offset + indexes_range.length or indexed_nodes != self.count) return error.InvalidForest;

        var expected_roots: usize = 0;
        for (0..self.count) |i| {
            const size = try self.subtreeAt(i);
            const end = try wire.add(i, size);
            if (size == 0 or end > self.count) return error.InvalidForest;
            const delta = try self.parent_column.get(i);
            const expected_parent = if (i == 0) null else try self.parentBefore(i);
            if (delta == 0) {
                if (expected_parent != null or expected_roots >= self.root_count or try self.root_column.get(expected_roots) != i) return error.InvalidForest;
                expected_roots += 1;
            } else {
                if (delta > i or expected_parent == null or i - @as(usize, @intCast(delta)) != expected_parent.?) return error.InvalidForest;
                if (end > try self.endAt(expected_parent.?)) return error.InvalidForest;
            }
        }
        if (expected_roots != self.root_count) return error.InvalidForest;

        var counts = [_]u32{0} ** kind_count;
        const checkpoints = self.count / rank_stride + 1;
        for (0..checkpoints) |checkpoint| {
            const row = checkpoint * kind_count * 4;
            for (counts, 0..) |count, kind_ordinal| if (try wire.readInt(u32, self.ranks, row + kind_ordinal * 4) != count) return error.InvalidForest;
            const start = checkpoint * rank_stride;
            var i = start;
            while (i < @min(self.count, start + rank_stride)) : (i += 1) counts[@intFromEnum(try self.kindAt(i))] += 1;
        }
    }

    /// Finds the deepest open ancestor immediately before preorder position
    /// `index`; this detects skipped parents without allocating a validation
    /// stack from untrusted node counts.
    fn parentBefore(self: *const View, index: usize) Error!?usize {
        var candidate = index - 1;
        while (true) {
            const end = try self.endAt(candidate);
            if (end > index) return candidate;
            if (end != index) return error.InvalidForest;
            const delta = try self.parent_column.get(candidate);
            if (delta == 0) return null;
            if (delta > candidate) return error.InvalidForest;
            candidate -= @intCast(delta);
        }
    }

    fn kindAt(self: *const View, index: usize) Error!schema.Kind {
        if (index >= self.count) return error.InvalidNode;
        const raw = try bits.readBits(self.kinds, index * kind_width, kind_width);
        if (raw >= kind_count) return error.InvalidForest;
        return @enumFromInt(@as(u8, @intCast(raw)));
    }

    fn subtreeAt(self: *const View, index: usize) Error!usize {
        return std.math.cast(usize, try self.subtree_column.get(index)) orelse error.InvalidForest;
    }

    fn endAt(self: *const View, index: usize) Error!usize {
        const end = try wire.add(index, try self.subtreeAt(index));
        return if (end <= self.count) end else error.InvalidForest;
    }

    pub fn kind(self: *const View, node: Node) Error!schema.Kind {
        return self.kindAt(try nodeIndex(node, self.count));
    }

    pub fn subtreeSize(self: *const View, node: Node) Error!usize {
        return self.subtreeAt(try nodeIndex(node, self.count));
    }

    pub fn subtreeEnd(self: *const View, node: Node) Error!usize {
        return self.endAt(try nodeIndex(node, self.count));
    }

    pub fn parentOf(self: *const View, node: Node) Error!?Node {
        const index = try nodeIndex(node, self.count);
        const delta = try self.parent_column.get(index);
        if (delta == 0) return null;
        if (delta > index) return error.InvalidForest;
        return @enumFromInt(@as(u32, @intCast(index - @as(usize, @intCast(delta)))));
    }

    pub const parent = parentOf;

    pub fn firstChild(self: *const View, node: Node) Error!?Node {
        const index = try nodeIndex(node, self.count);
        return if (try self.subtreeAt(index) == 1) null else @enumFromInt(@as(u32, @intCast(index + 1)));
    }

    pub fn nextSibling(self: *const View, node: Node) Error!?Node {
        const parent_node = try self.parentOf(node) orelse return null;
        const next = try self.subtreeEnd(node);
        return if (next < try self.subtreeEnd(parent_node)) @enumFromInt(@as(u32, @intCast(next))) else null;
    }

    pub fn root(self: *const View, node: Node) Error!Node {
        const index = try nodeIndex(node, self.count);
        const upper = try self.root_column.upperBound(index);
        if (upper == 0) return error.InvalidForest;
        return @enumFromInt(@as(u32, @intCast(try self.root_column.get(upper - 1))));
    }

    /// Enumerate roots without leaking the packed Elias--Fano representation.
    pub fn rootAt(self: *const View, index: usize) Error!?Node {
        if (index >= self.root_count) return null;
        return @enumFromInt(@as(u32, @intCast(try self.root_column.get(index))));
    }

    pub fn depth(self: *const View, node: Node) Error!usize {
        var current = node;
        var result: usize = 0;
        while (try self.parentOf(current)) |parent_node| {
            current = parent_node;
            result = try wire.add(result, 1);
        }
        return result;
    }

    /// Returns the dense row for `node` in a column scoped over `set`.
    pub inline fn kindRank(self: *const View, set: schema.KindSet, node: Node) Error!usize {
        const index = try nodeIndex(node, self.count);
        const checkpoint = index / rank_stride;
        const row = checkpoint * kind_count * 4;
        var result: usize = 0;
        for (0..kind_count) |kind_ordinal| {
            if (set.has(@enumFromInt(kind_ordinal))) result += try wire.readInt(u32, self.ranks, row + kind_ordinal * 4);
        }
        var i = checkpoint * rank_stride;
        while (i < index) : (i += 1) {
            if (set.has(try self.kindAt(i))) result += 1;
        }
        return result;
    }

    pub fn countKinds(self: *const View, set: schema.KindSet) Error!usize {
        var total: usize = 0;
        for (0..kind_count) |kind_ordinal| {
            if (set.has(@enumFromInt(kind_ordinal))) {
                if (try self.kindIndex(@enumFromInt(kind_ordinal))) |sequence|
                    total = try wire.add(total, sequence.count);
            }
        }
        return total;
    }

    pub fn nodes(self: *const View, wanted: schema.Kind) Error!KindIterator {
        if (wanted == .any) return error.InvalidForest;
        return .{ .sequence = try self.kindIndex(wanted) };
    }

    fn kindIndex(self: *const View, wanted: schema.Kind) Error!?bits.EliasView {
        if (wanted == .any) return error.InvalidForest;
        return self.indexes[@intFromEnum(wanted)];
    }

    pub fn childrenInto(self: *const View, node: Node, out: []Node) Error!usize {
        const start = try nodeIndex(node, self.count);
        const limit = try self.endAt(start);
        var child = if (try self.subtreeAt(start) > 1) start + 1 else limit;
        var written: usize = 0;
        while (child < limit) {
            if (written == out.len) return error.BufferTooSmall;
            out[written] = @enumFromInt(@as(u32, @intCast(child)));
            written += 1;
            child = try self.endAt(child);
        }
        return written;
    }
};

/// Compatibility owner used by focused structural tests and by callers that
/// build packed forests outside the snapshot compiler.
pub const Forest = struct {
    owned: Owned,
    view: View,

    pub fn init(allocator: std.mem.Allocator, subtree: anytype, parent_delta: anytype, roots: anytype) Error!Forest {
        const subtree32 = try castSlice(allocator, u32, subtree);
        defer allocator.free(subtree32);
        const parents32 = try castSlice(allocator, u32, parent_delta);
        defer allocator.free(parents32);
        const roots32 = try castSlice(allocator, u32, roots);
        defer allocator.free(roots32);
        const kinds = try allocator.alloc(schema.Kind, subtree32.len);
        defer allocator.free(kinds);
        @memset(kinds, .extension);
        var owned = try encode(allocator, subtree32, parents32, roots32, kinds);
        errdefer owned.deinit();
        return .{ .view = try View.open(owned.bytes), .owned = owned };
    }

    pub fn deinit(self: *Forest) void {
        self.owned.deinit();
        self.* = undefined;
    }

    pub fn validate(self: *const Forest) Error!void {
        _ = try View.open(self.owned.bytes);
    }
    pub fn subtreeSize(self: *const Forest, node: Node) Error!usize {
        return self.view.subtreeSize(node);
    }
    pub fn subtreeEnd(self: *const Forest, node: Node) Error!usize {
        return self.view.subtreeEnd(node);
    }
    pub fn parent(self: *const Forest, node: Node) Error!?Node {
        return self.view.parentOf(node);
    }
    pub fn firstChild(self: *const Forest, node: Node) Error!?Node {
        return self.view.firstChild(node);
    }
    pub fn nextSibling(self: *const Forest, node: Node) Error!?Node {
        return self.view.nextSibling(node);
    }
    pub fn root(self: *const Forest, node: Node) Error!Node {
        return self.view.root(node);
    }
    pub fn depth(self: *const Forest, node: Node) Error!usize {
        return self.view.depth(node);
    }
    pub fn childrenInto(self: *const Forest, node: Node, out: []Node) Error!usize {
        return self.view.childrenInto(node, out);
    }
};

fn validateLogical(subtree: []const u32, parents: []const u32, roots: []const u32, kinds: []const schema.Kind) Error!void {
    if (subtree.len == 0 or subtree.len != parents.len or subtree.len != kinds.len or subtree.len > std.math.maxInt(u32) or roots.len == 0) return error.InvalidForest;
    var expected_root: usize = 0;
    var previous_root_end: usize = 0;
    for (subtree, 0..) |size, i| {
        if (size == 0 or size > subtree.len - i or kinds[i] == .any) return error.InvalidForest;
        const delta = parents[i];
        if (delta == 0) {
            if (expected_root >= roots.len or roots[expected_root] != i or i != previous_root_end) return error.InvalidForest;
            previous_root_end = i + size;
            expected_root += 1;
        } else {
            if (delta > i) return error.InvalidForest;
            const parent = i - delta;
            if (i + size > parent + subtree[parent]) return error.InvalidForest;
            var candidate = i - 1;
            while (candidate + subtree[candidate] == i) {
                if (parents[candidate] == 0) return error.InvalidForest;
                candidate -= parents[candidate];
            }
            if (candidate + subtree[candidate] <= i or candidate != parent) return error.InvalidForest;
        }
    }
    if (expected_root != roots.len or previous_root_end != subtree.len) return error.InvalidForest;
}

fn nodeIndex(node: Node, count: usize) Error!usize {
    const raw = @intFromEnum(node);
    return if (raw < count) raw else error.InvalidNode;
}

fn reserve(cursor: *usize, length: usize) Error!Range {
    const start = cursor.*;
    cursor.* = try wire.add(start, length);
    if (cursor.* > std.math.maxInt(u32)) return error.LimitExceeded;
    return .{ .offset = @intCast(start), .length = @intCast(length) };
}

fn constRange(bytes: []const u8, range: Range) []const u8 {
    return bytes[range.offset..][0..range.length];
}

fn mutRange(bytes: []u8, range: Range) []u8 {
    return bytes[range.offset..][0..range.length];
}

fn copyRange(out: []u8, range: Range, bytes: []const u8) void {
    @memcpy(mutRange(out, range), bytes);
}

fn bitBytes(bit_count: usize) Error!usize {
    return (try wire.add(bit_count, 7)) / 8;
}

fn mapWire(err: wire.Error) Error {
    return switch (err) {
        error.Truncated, error.TrailingBytes, error.InvalidValue => error.InvalidForest,
        else => err,
    };
}

fn castSlice(allocator: std.mem.Allocator, comptime T: type, values: anytype) Error![]T {
    const out = try allocator.alloc(T, values.len);
    errdefer allocator.free(out);
    for (values, 0..) |value, i| out[i] = std.math.cast(T, value) orelse return error.InvalidForest;
    return out;
}
