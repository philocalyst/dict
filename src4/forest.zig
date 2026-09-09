//! Key-ordered preorder forest and kind-rank projection.
//!
//! The automaton owns keys and their order. This module consequently stores no
//! key bytes, key offsets, or per-entry structural columns. A forest is a
//! sequence of roots in entry-rank order; equal preorder skeletons are stored
//! once and the root sequence is either implicit (constant) or bit-packed.
//!
//! `View.open` only checks the envelope and section bounds. Hosts that need a
//! trust decision call `verify`, which validates every distinct skeleton and
//! the root sequence in linear time without allocating.

const std = @import("std");
const schema = @import("schema.zig");
const rank = @import("rank.zig");

pub const Kind = schema.Kind;
pub const Node = schema.Node;
pub const Rank = schema.Rank;
pub const NodeSet = rank.NodeSet;
pub const Interval = rank.Interval;

pub const checkpoint_stride: usize = 256;
// Version 4 uses the former constant-skeleton slot for the exact active-kind
// mask. Constant identity is necessarily skeleton zero; mixed summary rows
// contain only active lanes in ascending kind order.
const version: u16 = 4;
const magic = "L4FR";
const base_header_size: usize = 32;
const range_count: usize = 6;
const header_size: usize = base_header_size + range_count * 16;
// Each distinct skeleton chooses the smallest 1/2/4-byte representation for
// its local subtree and parent deltas. The directory records those widths.
const directory_record_size: usize = 16;
const flag_packed_sequence: u16 = 1 << 0;
const flag_root_starts: u16 = 1 << 1;
const flag_derived_constant_summaries: u16 = 1 << 2;
const known_flags: u16 = flag_packed_sequence | flag_root_starts | flag_derived_constant_summaries;

pub const Error = rank.Error || std.mem.Allocator.Error || error{
    BadMagic,
    UnsupportedVersion,
    InvalidEncoding,
    InvalidNode,
    InvalidForest,
    InvalidRoot,
    InvalidKey,
    InvalidSkeleton,
    InvalidSequence,
    EntryCountMismatch,
    KeysNotStored,
};

pub const NodeRecord = struct {
    kind: Kind,
    subtree_size: u32,
    parent: ?Node,
};

/// `key` is a build-time ordering witness only. It is never copied to the
/// wire. Callers integrating with the automaton may leave it null because the
/// automaton has already established entry-rank order.
pub const RootInput = struct {
    start: Node,
    key: ?[]const u8 = null,
};

pub const NodeRange = struct {
    lo: usize,
    hi: usize,

    pub fn init(lo: usize, hi: usize) Error!NodeRange {
        if (hi < lo) return error.InvalidForest;
        return .{ .lo = lo, .hi = hi };
    }

    pub fn len(self: NodeRange) usize {
        return self.hi - self.lo;
    }
};

pub const RootRange = struct {
    first: usize,
    end: usize,

    pub fn init(first: usize, end: usize) Error!RootRange {
        if (end < first) return error.InvalidRoot;
        return .{ .first = first, .end = end };
    }

    pub fn len(self: RootRange) usize {
        return self.end - self.first;
    }
};

pub const ByteLedger = struct {
    header: usize,
    skeleton_directory: usize,
    skeleton_data: usize,
    skeleton_kind_counts: usize,
    root_sequence: usize,
    root_starts: usize,
    root_checkpoints: usize,

    pub fn total(self: ByteLedger) usize {
        return self.header + self.skeleton_directory + self.skeleton_data +
            self.skeleton_kind_counts + self.root_sequence + self.root_starts +
            self.root_checkpoints;
    }
};

const Section = struct {
    offset: u64,
    length: u64,
};

const DirectoryRecord = struct {
    offset: usize,
    length: usize,
    node_count: usize,
    subtree_width: u8,
    parent_width: u8,
};

const SkeletonNode = struct {
    kind: Kind,
    subtree_size: u32,
    parent_delta: u32,
};

fn checkedAdd(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.InvalidEncoding;
}

fn checkedMul(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch error.InvalidEncoding;
}

fn checkedU32(value: usize) Error!u32 {
    return std.math.cast(u32, value) orelse error.InvalidEncoding;
}

fn readU16(bytes: []const u8, at: usize) Error!u16 {
    if (at > bytes.len or bytes.len - at < 2) return error.InvalidEncoding;
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

fn readU32(bytes: []const u8, at: usize) Error!u32 {
    if (at > bytes.len or bytes.len - at < 4) return error.InvalidEncoding;
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn readU64(bytes: []const u8, at: usize) Error!u64 {
    if (at > bytes.len or bytes.len - at < 8) return error.InvalidEncoding;
    return std.mem.readInt(u64, bytes[at..][0..8], .little);
}

fn writeU16(bytes: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[at..][0..2], value, .little);
}

fn writeU32(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}

fn writeU64(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}

fn rangeToSection(bytes: []const u8, section: Section) Error![]const u8 {
    const start = std.math.cast(usize, section.offset) orelse return error.InvalidEncoding;
    const length = std.math.cast(usize, section.length) orelse return error.InvalidEncoding;
    const end = try checkedAdd(start, length);
    if (start > bytes.len or end > bytes.len) return error.InvalidEncoding;
    return bytes[start..end];
}

fn sectionAt(bytes: []const u8, index: usize) Error!Section {
    if (index >= range_count) return error.InvalidEncoding;
    const at = base_header_size + index * 16;
    return .{ .offset = try readU64(bytes, at), .length = try readU64(bytes, at + 8) };
}

fn sectionFor(cursor: *usize, length: usize) Error!Section {
    const offset = cursor.*;
    cursor.* = try checkedAdd(cursor.*, length);
    return .{
        .offset = std.math.cast(u64, offset) orelse return error.InvalidEncoding,
        .length = std.math.cast(u64, length) orelse return error.InvalidEncoding,
    };
}

fn rawNodeIndex(node: Node, count: usize) Error!usize {
    const raw = @intFromEnum(node);
    if (raw == std.math.maxInt(u32) or raw >= count) return error.InvalidNode;
    return raw;
}

fn rawNode(raw: u32, count: usize) Error!Node {
    if (raw == std.math.maxInt(u32) or raw >= count) return error.InvalidNode;
    return @enumFromInt(raw);
}

fn nodeFromIndex(index: usize) Error!Node {
    const raw = std.math.cast(u32, index) orelse return error.InvalidNode;
    if (raw == std.math.maxInt(u32)) return error.InvalidNode;
    return @enumFromInt(raw);
}

fn rawKind(raw: u8) Error!Kind {
    if (raw >= schema.kind_count) return error.InvalidSkeleton;
    return @enumFromInt(raw);
}

fn rootKeyLess(left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

/// Validate the input representation in O(nodes + edges). Child intervals are
/// recovered from subtree sizes; checking each parent's direct-child partition
/// avoids the old nearest-ancestor walk, which could rescan a deep comb-shaped
/// tree quadratically.
fn validateLogical(nodes: []const NodeRecord, roots: []const RootInput) Error!void {
    if ((nodes.len == 0) != (roots.len == 0)) return error.InvalidForest;
    if (nodes.len >= std.math.maxInt(u32) or roots.len >= std.math.maxInt(u32)) return error.InvalidForest;

    var any_keys = false;
    var all_keys = true;
    var previous_key: ?[]const u8 = null;
    for (roots) |root| {
        if (root.key) |key| {
            any_keys = true;
            if (previous_key) |prior| if (rootKeyLess(key, prior)) return error.InvalidKey;
            previous_key = key;
        } else {
            all_keys = false;
        }
    }
    if (any_keys and !all_keys) return error.InvalidKey;

    var previous_root_end: usize = 0;
    for (roots, 0..) |root, root_index| {
        const start = rawNodeIndex(root.start, nodes.len) catch return error.InvalidRoot;
        if (start != previous_root_end) return error.InvalidRoot;
        if (nodes[start].parent != null or !schema.spec(nodes[start].kind).root) return error.InvalidRoot;
        const end = checkedAdd(start, nodes[start].subtree_size) catch return error.InvalidForest;
        if (nodes[start].subtree_size == 0 or end > nodes.len) return error.InvalidForest;
        if (root_index + 1 < roots.len) {
            const next = rawNodeIndex(roots[root_index + 1].start, nodes.len) catch return error.InvalidRoot;
            if (next != end) return error.InvalidRoot;
        }
        previous_root_end = end;
    }
    if (previous_root_end != nodes.len) return error.InvalidForest;

    var root_cursor: usize = 0;
    for (nodes, 0..) |node, index| {
        if (node.subtree_size == 0) return error.InvalidForest;
        const end = checkedAdd(index, node.subtree_size) catch return error.InvalidForest;
        if (end > nodes.len) return error.InvalidForest;
        if (node.parent == null) {
            if (root_cursor >= roots.len or @intFromEnum(roots[root_cursor].start) != index) return error.InvalidRoot;
            root_cursor += 1;
        } else {
            const parent = rawNodeIndex(node.parent.?, nodes.len) catch return error.InvalidForest;
            if (parent >= index) return error.InvalidForest;
        }
    }
    if (root_cursor != roots.len) return error.InvalidRoot;

    for (nodes, 0..) |parent_node, parent_index| {
        const parent_end = checkedAdd(parent_index, parent_node.subtree_size) catch return error.InvalidForest;
        var child_index = try checkedAdd(parent_index, 1);
        while (child_index < parent_end) {
            const child_end = checkedAdd(child_index, nodes[child_index].subtree_size) catch return error.InvalidForest;
            if (nodes[child_index].subtree_size == 0 or child_end <= child_index or child_end > parent_end) return error.InvalidForest;
            if (nodes[child_index].parent == null or @intFromEnum(nodes[child_index].parent.?) != parent_index)
                return error.InvalidForest;
            if (!schema.legalParent(parent_node.kind, nodes[child_index].kind)) return error.InvalidForest;
            child_index = child_end;
        }
        if (child_index != parent_end) return error.InvalidForest;
    }
}

fn packedWidth(skeleton_count: usize) Error!u8 {
    if (skeleton_count <= 1) return 0;
    var value = skeleton_count - 1;
    var width: u8 = 0;
    while (value != 0) : (value >>= 1) width += 1;
    if (width == 0 or width > 32) return error.InvalidEncoding;
    return width;
}

fn packedLength(count: usize, width: u8) Error!usize {
    if (width == 0) return 0;
    const bits = try checkedMul(count, width);
    return (try checkedAdd(bits, 7)) / 8;
}

fn integerWidth(max_value: u32) u8 {
    if (max_value <= std.math.maxInt(u8)) return 1;
    if (max_value <= std.math.maxInt(u16)) return 2;
    return 4;
}

fn descriptorStride(subtree_width: u8, parent_width: u8) Error!usize {
    if ((subtree_width != 1 and subtree_width != 2 and subtree_width != 4) or
        (parent_width != 1 and parent_width != 2 and parent_width != 4)) return error.InvalidEncoding;
    return checkedAdd(1, try checkedAdd(subtree_width, parent_width));
}

fn readWidth(bytes: []const u8, at: usize, width: u8) Error!u32 {
    return switch (width) {
        1 => if (at >= bytes.len) error.InvalidEncoding else bytes[at],
        2 => @as(u32, try readU16(bytes, at)),
        4 => readU32(bytes, at),
        else => error.InvalidEncoding,
    };
}

fn writeWidth(bytes: []u8, at: usize, width: u8, value: u32) void {
    switch (width) {
        1 => bytes[at] = @intCast(value),
        2 => writeU16(bytes, at, @intCast(value)),
        4 => writeU32(bytes, at, value),
        else => unreachable,
    }
}

fn descriptorHash(nodes: []const SkeletonNode) u64 {
    var hash: u64 = 14_695_981_039_346_656_037;
    for (nodes) |node| {
        hash ^= @intFromEnum(node.kind);
        hash *%= 1_099_511_628_211;
        hash ^= node.subtree_size;
        hash *%= 1_099_511_628_211;
        hash ^= node.parent_delta;
        hash *%= 1_099_511_628_211;
    }
    return hash;
}

const RootDraft = struct {
    nodes: ?[]SkeletonNode,
    hash: u64,
    original: usize,
};

const BuildSkeleton = struct {
    nodes: []SkeletonNode,
    counts: [schema.kind_count]u32,
};

fn rootDraftLess(left: RootDraft, right: RootDraft) bool {
    if (left.hash != right.hash) return left.hash < right.hash;
    const a = left.nodes.?;
    const b = right.nodes.?;
    const common = @min(a.len, b.len);
    for (a[0..common], b[0..common]) |x, y| {
        if (@intFromEnum(x.kind) != @intFromEnum(y.kind)) return @intFromEnum(x.kind) < @intFromEnum(y.kind);
        if (x.subtree_size != y.subtree_size) return x.subtree_size < y.subtree_size;
        if (x.parent_delta != y.parent_delta) return x.parent_delta < y.parent_delta;
    }
    if (a.len != b.len) return a.len < b.len;
    return left.original < right.original;
}

fn sameSkeleton(a: []const SkeletonNode, b: []const SkeletonNode) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.kind != right.kind or left.subtree_size != right.subtree_size or left.parent_delta != right.parent_delta) return false;
    }
    return true;
}

fn makeSkeletons(allocator: std.mem.Allocator, nodes: []const NodeRecord, roots: []const RootInput) Error!struct {
    skeletons: std.ArrayList(BuildSkeleton),
    root_ids: []u32,
} {
    var drafts = std.ArrayList(RootDraft).empty;
    errdefer {
        for (drafts.items) |draft| if (draft.nodes) |owned| allocator.free(owned);
        drafts.deinit(allocator);
    }

    for (roots, 0..) |root, root_index| {
        const start = rawNodeIndex(root.start, nodes.len) catch return error.InvalidRoot;
        const end = if (root_index + 1 < roots.len)
            rawNodeIndex(roots[root_index + 1].start, nodes.len) catch return error.InvalidRoot
        else
            nodes.len;
        if (end < start) return error.InvalidRoot;
        const local = try allocator.alloc(SkeletonNode, end - start);
        errdefer allocator.free(local);
        for (local, 0..) |*out, offset| {
            const source = nodes[start + offset];
            out.* = .{
                .kind = source.kind,
                .subtree_size = source.subtree_size,
                .parent_delta = if (source.parent) |parent| @intCast(start + offset - (try rawNodeIndex(parent, nodes.len))) else 0,
            };
        }
        try drafts.append(allocator, .{ .nodes = local, .hash = descriptorHash(local), .original = root_index });
    }
    std.mem.sort(RootDraft, drafts.items, {}, struct {
        fn less(_: void, left: RootDraft, right: RootDraft) bool {
            return rootDraftLess(left, right);
        }
    }.less);

    var skeletons = std.ArrayList(BuildSkeleton).empty;
    errdefer {
        for (skeletons.items) |skeleton| allocator.free(skeleton.nodes);
        skeletons.deinit(allocator);
    }
    const root_ids = try allocator.alloc(u32, roots.len);
    errdefer allocator.free(root_ids);

    var previous_id: ?u32 = null;
    for (drafts.items) |*draft| {
        const draft_nodes = draft.nodes.?;
        if (previous_id == null or !sameSkeleton(skeletons.items[previous_id.?].nodes, draft_nodes)) {
            var counts = [_]u32{0} ** schema.kind_count;
            for (draft_nodes) |node| counts[@intFromEnum(node.kind)] += 1;
            const id = try checkedU32(skeletons.items.len);
            try skeletons.append(allocator, .{ .nodes = draft_nodes, .counts = counts });
            draft.nodes = null;
            previous_id = id;
        } else {
            allocator.free(draft_nodes);
        }
        root_ids[draft.original] = previous_id.?;
    }
    drafts.deinit(allocator);
    return .{ .skeletons = skeletons, .root_ids = root_ids };
}

fn writeDescriptor(bytes: []u8, at: usize, node: SkeletonNode, subtree_width: u8, parent_width: u8) void {
    bytes[at] = @intCast(@intFromEnum(node.kind));
    writeWidth(bytes, at + 1, subtree_width, node.subtree_size);
    writeWidth(bytes, at + 1 + subtree_width, parent_width, node.parent_delta);
}

fn writePacked(bytes: []u8, index: usize, width: u8, value: u32) void {
    const bit = index * width;
    const byte = bit / 8;
    const shift: u6 = @intCast(bit % 8);
    var word: u64 = 0;
    for (0..5) |offset| {
        if (byte + offset < bytes.len) word |= @as(u64, bytes[byte + offset]) << @intCast(offset * 8);
    }
    const mask = (@as(u64, 1) << @intCast(width)) - 1;
    word = (word & ~(mask << shift)) | (@as(u64, value) << shift);
    for (0..5) |offset| {
        if (byte + offset < bytes.len) bytes[byte + offset] = @intCast(word >> @intCast(offset * 8));
    }
}

fn encodeSkeletons(allocator: std.mem.Allocator, node_count: usize, root_ids: []const u32, skeletons: []const BuildSkeleton) Error!Owned {
    if (node_count >= std.math.maxInt(u32) or root_ids.len >= std.math.maxInt(u32) or skeletons.len >= std.math.maxInt(u32)) return error.InvalidEncoding;
    if (root_ids.len == 0 and (node_count != 0 or skeletons.len != 0)) return error.InvalidForest;

    const width_for_count = try packedWidth(skeletons.len);
    var constant_sequence = root_ids.len != 0;
    if (root_ids.len != 0) {
        for (root_ids[1..]) |id| if (id != root_ids[0]) {
            constant_sequence = false;
            break;
        };
    }
    if (constant_sequence and (skeletons.len != 1 or root_ids[0] != 0)) return error.InvalidSequence;
    const is_packed = !constant_sequence and root_ids.len != 0;
    const derives_constant_summaries = constant_sequence;
    const stores_summaries = root_ids.len != 0 and !derives_constant_summaries;
    const width = if (is_packed) width_for_count else 0;
    const sequence_len = try packedLength(root_ids.len, width);

    var uniform = true;
    const uniform_size: u32 = if (root_ids.len == 0) 0 else @intCast(skeletons[root_ids[0]].nodes.len);
    for (root_ids) |id| {
        if (skeletons[id].nodes.len != uniform_size) uniform = false;
    }
    const root_starts_len = if (uniform) 0 else try checkedMul(root_ids.len, 4);
    const checkpoint_count = try checkedAdd(root_ids.len / checkpoint_stride, 1);
    const directory_len = try checkedMul(skeletons.len, directory_record_size);
    var skeleton_data_len: usize = 0;
    for (skeletons) |skeleton| {
        var max_subtree: u32 = 0;
        var max_parent: u32 = 0;
        for (skeleton.nodes) |node| {
            max_subtree = @max(max_subtree, node.subtree_size);
            max_parent = @max(max_parent, node.parent_delta);
        }
        const stride = try descriptorStride(integerWidth(max_subtree), integerWidth(max_parent));
        skeleton_data_len = try checkedAdd(skeleton_data_len, try checkedMul(skeleton.nodes.len, stride));
    }
    var active_mask: u32 = 0;
    for (skeletons) |skeleton| {
        for (skeleton.counts, 0..) |count, kind_index| {
            if (count != 0) active_mask |= @as(u32, 1) << @intCast(kind_index);
        }
    }
    const active_count: usize = @popCount(active_mask);
    const counts_len = if (stores_summaries) try checkedMul(try checkedMul(skeletons.len, active_count), 4) else 0;
    const checkpoints_len = if (stores_summaries) try checkedMul(try checkedMul(checkpoint_count, active_count), 4) else 0;

    var cursor = header_size;
    const sections = [_]Section{
        try sectionFor(&cursor, directory_len),
        try sectionFor(&cursor, skeleton_data_len),
        try sectionFor(&cursor, counts_len),
        try sectionFor(&cursor, sequence_len),
        try sectionFor(&cursor, root_starts_len),
        try sectionFor(&cursor, checkpoints_len),
    };
    const bytes = try allocator.alloc(u8, cursor);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], magic);
    writeU16(bytes, 4, version);
    writeU16(bytes, 6, (if (is_packed) flag_packed_sequence else 0) |
        (if (uniform) 0 else flag_root_starts) |
        (if (derives_constant_summaries) flag_derived_constant_summaries else 0));
    writeU32(bytes, 8, @intCast(node_count));
    writeU32(bytes, 12, @intCast(root_ids.len));
    writeU32(bytes, 16, @intCast(skeletons.len));
    writeU32(bytes, 20, @intCast(checkpoint_count));
    writeU32(bytes, 24, active_mask);
    writeU32(bytes, 28, if (uniform) uniform_size else 0);
    for (sections, 0..) |section, index| {
        writeU64(bytes, base_header_size + index * 16, section.offset);
        writeU64(bytes, base_header_size + index * 16 + 8, section.length);
    }

    const directory = bytes[std.math.cast(usize, sections[0].offset).?..][0..directory_len];
    const skeleton_data = bytes[std.math.cast(usize, sections[1].offset).?..][0..skeleton_data_len];
    const counts = bytes[std.math.cast(usize, sections[2].offset).?..][0..counts_len];
    const sequence = bytes[std.math.cast(usize, sections[3].offset).?..][0..sequence_len];
    const root_starts = bytes[std.math.cast(usize, sections[4].offset).?..][0..root_starts_len];
    const checkpoints = bytes[std.math.cast(usize, sections[5].offset).?..][0..checkpoints_len];

    var data_cursor: usize = 0;
    for (skeletons, 0..) |skeleton, id| {
        var max_subtree: u32 = 0;
        var max_parent: u32 = 0;
        for (skeleton.nodes) |node| {
            max_subtree = @max(max_subtree, node.subtree_size);
            max_parent = @max(max_parent, node.parent_delta);
        }
        const subtree_width = integerWidth(max_subtree);
        const parent_width = integerWidth(max_parent);
        const stride = try descriptorStride(subtree_width, parent_width);
        const descriptor_length = try checkedMul(skeleton.nodes.len, stride);
        const directory_at = id * directory_record_size;
        writeU32(directory, directory_at, try checkedU32(data_cursor));
        writeU32(directory, directory_at + 4, try checkedU32(descriptor_length));
        writeU32(directory, directory_at + 8, try checkedU32(skeleton.nodes.len));
        directory[directory_at + 12] = subtree_width;
        directory[directory_at + 13] = parent_width;
        for (skeleton.nodes) |node| {
            writeDescriptor(skeleton_data, data_cursor, node, subtree_width, parent_width);
            data_cursor += stride;
        }
        if (stores_summaries) {
            var lane: usize = 0;
            for (skeleton.counts, 0..) |count, kind_index| if (active_mask & (@as(u32, 1) << @intCast(kind_index)) != 0) {
                writeU32(counts, (id * active_count + lane) * 4, count);
                lane += 1;
            };
        }
    }
    if (data_cursor != skeleton_data_len) return error.InvalidEncoding;

    if (is_packed) for (root_ids, 0..) |id, index| writePacked(sequence, index, width, id);
    var cumulative = [_]u32{0} ** schema.kind_count;
    var node_cursor: usize = 0;
    for (root_ids, 0..) |id, root_index| {
        if (!uniform) writeU32(root_starts, root_index * 4, @intCast(node_cursor));
        if (stores_summaries and root_index % checkpoint_stride == 0) {
            const row = (root_index / checkpoint_stride) * active_count * 4;
            var lane: usize = 0;
            for (cumulative, 0..) |count, kind_index| if (active_mask & (@as(u32, 1) << @intCast(kind_index)) != 0) {
                writeU32(checkpoints, row + lane * 4, count);
                lane += 1;
            };
        }
        node_cursor = try checkedAdd(node_cursor, skeletons[id].nodes.len);
        for (skeletons[id].counts, 0..) |count, kind_index| cumulative[kind_index] = std.math.add(u32, cumulative[kind_index], count) catch return error.InvalidForest;
    }
    if (stores_summaries and root_ids.len % checkpoint_stride == 0) {
        const final_row = (root_ids.len / checkpoint_stride) * active_count * 4;
        var lane: usize = 0;
        for (cumulative, 0..) |count, kind_index| if (active_mask & (@as(u32, 1) << @intCast(kind_index)) != 0) {
            writeU32(checkpoints, final_row + lane * 4, count);
            lane += 1;
        };
    }
    if (node_cursor != node_count) return error.InvalidForest;

    const view = try View.open(bytes);
    try view.verify();
    return .{ .allocator = allocator, .bytes = bytes, .view = view };
}

/// Encode roots whose order is already the automaton's entry-rank order.
/// `RootInput.key` is used only to reject an explicitly unsorted build input;
/// it does not affect the wire image.
pub fn encode(allocator: std.mem.Allocator, nodes: []const NodeRecord, roots: []const RootInput) Error!Owned {
    try validateLogical(nodes, roots);
    var made = try makeSkeletons(allocator, nodes, roots);
    defer {
        for (made.skeletons.items) |skeleton| allocator.free(skeleton.nodes);
        made.skeletons.deinit(allocator);
        allocator.free(made.root_ids);
    }
    return encodeSkeletons(allocator, nodes.len, made.root_ids, made.skeletons.items);
}

pub fn encodeWithEntryCount(allocator: std.mem.Allocator, entry_count: usize, nodes: []const NodeRecord, roots: []const RootInput) Error!Owned {
    if (roots.len != entry_count) return error.EntryCountMismatch;
    return encode(allocator, nodes, roots);
}

/// Integration boundary for `automaton.View` (or a compatible view exposing
/// `entry_count`). The count check happens before any forest allocation.
pub fn encodeForAutomaton(allocator: std.mem.Allocator, automaton_view: anytype, nodes: []const NodeRecord, roots: []const RootInput) Error!Owned {
    return encodeWithEntryCount(allocator, @intCast(automaton_view.entry_count), nodes, roots);
}

pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    view: View,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Ephemeral coordinates found by typed selection. Carrying them into a
/// scoped projection avoids converting to a global node and locating the same
/// root and skeleton again. No decoded answer is retained by the View.
pub const Location = struct {
    root_index: usize,
    root_start: usize,
    skeleton_id: u32,
    local: usize,
};

pub const View = struct {
    bytes: []const u8,
    directory: []const u8,
    skeleton_data: []const u8,
    skeleton_counts: []const u8,
    root_sequence: []const u8,
    root_starts: []const u8,
    checkpoints: []const u8,
    count: usize,
    root_count: usize,
    skeleton_count: usize,
    checkpoint_count: usize,
    active_mask: u32,
    active_count: usize,
    sequence_width: u8,
    packed_sequence: bool,
    derived_constant_summaries: bool,
    uniform_size: usize,

    pub fn open(bytes: []const u8) Error!View {
        if (bytes.len < header_size) return error.InvalidEncoding;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
        if (try readU16(bytes, 4) != version) return error.UnsupportedVersion;
        const flags = try readU16(bytes, 6);
        if (flags & ~known_flags != 0) return error.InvalidEncoding;
        const count = @as(usize, try readU32(bytes, 8));
        const root_count = @as(usize, try readU32(bytes, 12));
        const skeleton_count = @as(usize, try readU32(bytes, 16));
        const checkpoint_count = @as(usize, try readU32(bytes, 20));
        const active_mask = try readU32(bytes, 24);
        const valid_kind_mask = (@as(u32, 1) << @intCast(schema.kind_count)) - 1;
        if (active_mask & ~valid_kind_mask != 0) return error.InvalidEncoding;
        const active_count: usize = @popCount(active_mask);
        if (count >= std.math.maxInt(u32) or root_count >= std.math.maxInt(u32) or skeleton_count >= std.math.maxInt(u32)) return error.InvalidEncoding;
        if ((root_count == 0) != (skeleton_count == 0) or checkpoint_count != root_count / checkpoint_stride + 1) return error.InvalidForest;

        const is_packed = flags & flag_packed_sequence != 0;
        const derives_constant_summaries = flags & flag_derived_constant_summaries != 0;
        const has_root_starts = flags & flag_root_starts != 0;
        if (derives_constant_summaries != (root_count != 0 and !is_packed)) return error.InvalidSequence;
        if (derives_constant_summaries and has_root_starts) return error.InvalidSequence;
        if (derives_constant_summaries and skeleton_count != 1) return error.InvalidSequence;
        if (root_count == 0 and (has_root_starts or active_mask != 0 or try readU32(bytes, 28) != 0)) return error.InvalidForest;
        const width = if (is_packed) try packedWidth(skeleton_count) else 0;
        if (is_packed) {
            if (skeleton_count <= 1) return error.InvalidSequence;
        }
        const sequence_len = try packedLength(root_count, if (is_packed) width else 0);
        const root_starts_len = if (has_root_starts) try checkedMul(root_count, 4) else 0;
        const directory_len = try checkedMul(skeleton_count, directory_record_size);
        const stores_summaries = root_count != 0 and !derives_constant_summaries;
        const counts_len = if (stores_summaries) try checkedMul(try checkedMul(skeleton_count, active_count), 4) else 0;
        const checkpoints_len = if (stores_summaries) try checkedMul(try checkedMul(checkpoint_count, active_count), 4) else 0;

        var sections: [range_count]Section = undefined;
        var expected = header_size;
        for (&sections, 0..) |*section, index| {
            section.* = try sectionAt(bytes, index);
            const start = std.math.cast(usize, section.offset) orelse return error.InvalidEncoding;
            const length = std.math.cast(usize, section.length) orelse return error.InvalidEncoding;
            if (start != expected) return error.InvalidEncoding;
            expected = try checkedAdd(start, length);
        }
        if (expected != bytes.len) return error.InvalidEncoding;
        const expected_lengths = [_]usize{ directory_len, 0, counts_len, sequence_len, root_starts_len, checkpoints_len };
        for (sections, 0..) |section, index| {
            const length = std.math.cast(usize, section.length) orelse return error.InvalidEncoding;
            if (index != 1 and length != expected_lengths[index]) return error.InvalidEncoding;
        }

        const uniform_size = @as(usize, try readU32(bytes, 28));
        if (!has_root_starts and root_count != 0 and uniform_size == 0) return error.InvalidForest;
        const result = View{
            .bytes = bytes,
            .directory = try rangeToSection(bytes, sections[0]),
            .skeleton_data = try rangeToSection(bytes, sections[1]),
            .skeleton_counts = try rangeToSection(bytes, sections[2]),
            .root_sequence = try rangeToSection(bytes, sections[3]),
            .root_starts = try rangeToSection(bytes, sections[4]),
            .checkpoints = try rangeToSection(bytes, sections[5]),
            .count = count,
            .root_count = root_count,
            .skeleton_count = skeleton_count,
            .checkpoint_count = checkpoint_count,
            .active_mask = active_mask,
            .active_count = active_count,
            .sequence_width = width,
            .packed_sequence = is_packed,
            .derived_constant_summaries = derives_constant_summaries,
            .uniform_size = uniform_size,
        };
        // Envelope-only open deliberately avoids walking directory records or
        // the root sequence. Those linear checks belong to verify(); mapped
        // readers can reject malformed content without making open itself
        // proportional to an attacker-controlled root/state count.
        return result;
    }

    pub fn openForEntryCount(bytes: []const u8, entry_count: usize) Error!View {
        const view = try open(bytes);
        if (view.root_count != entry_count) return error.EntryCountMismatch;
        return view;
    }

    pub fn openForAutomaton(bytes: []const u8, automaton_view: anytype) Error!View {
        return openForEntryCount(bytes, @intCast(automaton_view.entry_count));
    }

    fn directoryRecord(self: *const View, id: usize) Error!DirectoryRecord {
        if (id >= self.skeleton_count) return error.InvalidSkeleton;
        const at = id * directory_record_size;
        return .{
            .offset = @as(usize, try readU32(self.directory, at)),
            .length = @as(usize, try readU32(self.directory, at + 4)),
            .node_count = @as(usize, try readU32(self.directory, at + 8)),
            .subtree_width = self.directory[at + 12],
            .parent_width = self.directory[at + 13],
        };
    }

    fn descriptorAt(self: *const View, id: usize, local: usize) Error!SkeletonNode {
        const record = try self.directoryRecord(id);
        if (local >= record.node_count) return error.InvalidNode;
        const stride = try descriptorStride(record.subtree_width, record.parent_width);
        const at = try checkedAdd(record.offset, try checkedMul(local, stride));
        if (try checkedAdd(at, stride) > self.skeleton_data.len) return error.InvalidEncoding;
        return .{ .kind = try rawKind(self.skeleton_data[at]), .subtree_size = try readWidth(self.skeleton_data, at + 1, record.subtree_width), .parent_delta = try readWidth(self.skeleton_data, at + 1 + record.subtree_width, record.parent_width) };
    }

    fn verifyDirectory(self: *const View) Error!void {
        var expected_offset: usize = 0;
        for (0..self.skeleton_count) |id| {
            const at = id * directory_record_size;
            const record = try self.directoryRecord(id);
            if (self.directory[at + 14] != 0 or self.directory[at + 15] != 0) return error.InvalidEncoding;
            const stride = try descriptorStride(record.subtree_width, record.parent_width);
            const expected_length = try checkedMul(record.node_count, stride);
            if (record.offset != expected_offset or record.length != expected_length) return error.InvalidEncoding;
            expected_offset = try checkedAdd(record.offset, record.length);
            if (expected_offset > self.skeleton_data.len) return error.InvalidEncoding;
        }
        if (expected_offset != self.skeleton_data.len) return error.InvalidEncoding;
    }

    fn skeletonNodeCount(self: *const View, id: usize) Error!usize {
        return (try self.directoryRecord(id)).node_count;
    }

    inline fn kindLane(self: *const View, wanted: Kind) ?usize {
        const bit = @as(u32, 1) << @intCast(@intFromEnum(wanted));
        if (self.active_mask & bit == 0) return null;
        return @popCount(self.active_mask & (bit - 1));
    }

    const KindColumn = struct { lane: ?usize };

    inline fn kindColumn(self: *const View, wanted: Kind) KindColumn {
        return .{ .lane = self.kindLane(wanted) };
    }

    fn skeletonColumnCount(self: *const View, id: usize, column: KindColumn) Error!usize {
        const lane = column.lane orelse return 0;
        if (self.skeleton_counts.len == 0) return error.InvalidEncoding;
        const at = try checkedAdd(try checkedMul(id, self.active_count), lane);
        return @as(usize, try readU32(self.skeleton_counts, try checkedMul(at, 4)));
    }

    fn checkpointColumn(self: *const View, row: usize, column: KindColumn) Error!usize {
        const lane = column.lane orelse return 0;
        const scalar = try checkedAdd(try checkedMul(row, self.active_count), lane);
        return @as(usize, try readU32(self.checkpoints, try checkedMul(scalar, 4)));
    }

    fn checkpointKind(self: *const View, row: usize, wanted: Kind) Error!usize {
        return self.checkpointColumn(row, self.kindColumn(wanted));
    }

    fn skeletonKindCount(self: *const View, id: usize, wanted: Kind) Error!usize {
        if (!self.derived_constant_summaries) {
            return self.skeletonColumnCount(id, self.kindColumn(wanted));
        }

        // A constant sequence has no stored summary lanes.  The descriptor
        // is the canonical source of kind counts for the selected skeleton;
        // this is intentionally the same checked measure used by projection
        // and inverse selection rather than a second count implementation.
        const node_count = try self.skeletonNodeCount(id);
        var result: usize = 0;
        for (0..node_count) |local| {
            if ((try self.descriptorAt(id, local)).kind == wanted)
                result = std.math.add(usize, result, 1) catch return error.InvalidForest;
        }
        return result;
    }

    fn skeletonKindPrefix(self: *const View, id: usize, wanted: Kind, local_end: usize) Error!usize {
        const node_count = try self.skeletonNodeCount(id);
        if (local_end > node_count) return error.InvalidNode;
        var result: usize = 0;
        for (0..local_end) |local| {
            if ((try self.descriptorAt(id, local)).kind == wanted)
                result = std.math.add(usize, result, 1) catch return error.InvalidForest;
        }
        return result;
    }

    fn rootIdAt(self: *const View, index: usize) Error!u32 {
        if (index >= self.root_count) return error.InvalidRoot;
        if (!self.packed_sequence) return 0;
        const bit = try checkedMul(index, self.sequence_width);
        const byte = bit / 8;
        const shift: u6 = @intCast(bit % 8);
        if (byte >= self.root_sequence.len) return error.InvalidSequence;
        var word: u64 = 0;
        const available = @min(5, self.root_sequence.len - byte);
        for (0..available) |offset| word |= @as(u64, self.root_sequence[byte + offset]) << @intCast(offset * 8);
        const mask = (@as(u64, 1) << @intCast(self.sequence_width)) - 1;
        const id: u32 = @intCast((word >> shift) & mask);
        if (id >= self.skeleton_count) return error.InvalidSequence;
        return id;
    }

    fn rootStart(self: *const View, index: usize) Error!usize {
        if (index >= self.root_count) return error.InvalidRoot;
        if (self.root_starts.len != 0) return @as(usize, try readU32(self.root_starts, index * 4));
        return try checkedMul(index, self.uniform_size);
    }

    fn rootEnd(self: *const View, index: usize) Error!usize {
        if (index >= self.root_count) return error.InvalidRoot;
        return if (index + 1 == self.root_count) self.count else self.rootStart(index + 1);
    }

    fn rootIndex(self: *const View, node_index: usize) Error!usize {
        if (node_index >= self.count or self.root_count == 0) return error.InvalidNode;
        if (self.root_starts.len == 0) {
            if (self.uniform_size == 0) return error.InvalidForest;
            return @min(node_index / self.uniform_size, self.root_count - 1);
        }
        var lo: usize = 0;
        var hi: usize = self.root_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (try self.rootStart(mid) <= node_index) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return error.InvalidRoot;
        return lo - 1;
    }

    fn rootAtBoundary(self: *const View, index: usize) Error!usize {
        if (index > self.count) return error.InvalidNode;
        if (index == self.count) return self.root_count;
        return self.rootIndex(index);
    }

    fn kindAtIndex(self: *const View, index: usize) Error!Kind {
        if (index >= self.count) return error.InvalidNode;
        const root_index = try self.rootIndex(index);
        const start = try self.rootStart(root_index);
        return (try self.descriptorAt(try self.rootIdAt(root_index), index - start)).kind;
    }

    fn descriptorAtNode(self: *const View, index: usize) Error!struct { descriptor: SkeletonNode, root_start: usize, root_index: usize, local: usize } {
        if (index >= self.count) return error.InvalidNode;
        const root_index = try self.rootIndex(index);
        const start = try self.rootStart(root_index);
        return .{ .descriptor = try self.descriptorAt(try self.rootIdAt(root_index), index - start), .root_start = start, .root_index = root_index, .local = index - start };
    }

    /// Cheap envelope validation is deliberately separate from this full
    /// linear structural check.
    pub fn verify(self: *const View) Error!void {
        try self.verifyDirectory();
        var actual_mask: u32 = 0;
        for (0..self.skeleton_count) |id| {
            const node_count = try self.skeletonNodeCount(id);
            if (node_count == 0) return error.InvalidSkeleton;
            const first = try self.descriptorAt(id, 0);
            if (first.parent_delta != 0 or first.subtree_size != node_count or !schema.spec(first.kind).root) return error.InvalidSkeleton;

            var seen = [_]u32{0} ** schema.kind_count;
            for (0..node_count) |local| {
                const node = try self.descriptorAt(id, local);
                if (node.subtree_size == 0 or try checkedAdd(local, node.subtree_size) > node_count) return error.InvalidSkeleton;
                if (local != 0 and (node.parent_delta == 0 or node.parent_delta > local)) return error.InvalidSkeleton;
                seen[@intFromEnum(node.kind)] = std.math.add(u32, seen[@intFromEnum(node.kind)], 1) catch return error.InvalidSkeleton;
            }

            // Subtree intervals partition each parent's child region. Every
            // direct edge is visited once, so this remains linear overall.
            for (0..node_count) |parent_local| {
                const parent_descriptor = try self.descriptorAt(id, parent_local);
                const parent_end = try checkedAdd(parent_local, parent_descriptor.subtree_size);
                var child_local = parent_local + 1;
                while (child_local < parent_end) {
                    const child = try self.descriptorAt(id, child_local);
                    const child_end = try checkedAdd(child_local, child.subtree_size);
                    if (child_end <= child_local or child_end > parent_end or child.parent_delta != child_local - parent_local) return error.InvalidSkeleton;
                    if (!schema.legalParent(parent_descriptor.kind, child.kind)) return error.InvalidSkeleton;
                    child_local = child_end;
                }
                if (child_local != parent_end) return error.InvalidSkeleton;
            }
            if (!self.derived_constant_summaries)
                for (seen, 0..) |value, kind_index| if (value != try self.skeletonKindCount(id, @enumFromInt(kind_index))) return error.InvalidSkeleton;
            var seen_mask: u32 = 0;
            for (seen, 0..) |value, kind_index| {
                if (value != 0) seen_mask |= @as(u32, 1) << @intCast(kind_index);
            }
            actual_mask |= seen_mask;
        }
        if (actual_mask != self.active_mask) return error.InvalidSkeleton;

        if (self.root_count == 0) {
            if (self.count != 0 or self.root_starts.len != 0) return error.InvalidForest;
        } else {
            var uniform = true;
            const first_id = try self.rootIdAt(0);
            const expected_uniform_size = try self.skeletonNodeCount(first_id);
            var node_cursor: usize = 0;
            var cumulative = [_]u32{0} ** schema.kind_count;
            var root_index: usize = 0;
            while (root_index <= self.root_count) : (root_index += 1) {
                if (!self.derived_constant_summaries and root_index % checkpoint_stride == 0) {
                    const row = root_index / checkpoint_stride;
                    for (cumulative, 0..) |value, kind_index| if (value != try self.checkpointKind(row, @enumFromInt(kind_index))) return error.InvalidForest;
                }
                if (root_index == self.root_count) break;
                const id = try self.rootIdAt(root_index);
                const size = try self.skeletonNodeCount(id);
                if (size != expected_uniform_size) uniform = false;
                if (self.root_starts.len != 0 and @as(usize, try readU32(self.root_starts, root_index * 4)) != node_cursor) return error.InvalidRoot;
                node_cursor = try checkedAdd(node_cursor, size);
                if (!self.derived_constant_summaries) {
                    for (0..schema.kind_count) |kind_index| {
                        cumulative[kind_index] = std.math.add(u32, cumulative[kind_index], @as(u32, @intCast(try self.skeletonKindCount(id, @enumFromInt(kind_index))))) catch return error.InvalidForest;
                    }
                }
            }
            if (node_cursor != self.count) return error.InvalidForest;
            if (uniform != (self.root_starts.len == 0)) return error.InvalidRoot;
            if (uniform and self.uniform_size != expected_uniform_size) return error.InvalidRoot;
            if (!uniform and self.uniform_size != 0) return error.InvalidRoot;
        }

        if (self.packed_sequence and self.root_sequence.len != 0) {
            const used_bits = (self.root_count * self.sequence_width) % 8;
            if (used_bits != 0) {
                const used_mask: u16 = (@as(u16, 1) << @as(u4, @intCast(used_bits))) - 1;
                const mask: u8 = @intCast((~used_mask) & 0xff);
                if ((self.root_sequence[self.root_sequence.len - 1] & mask) != 0) return error.InvalidSequence;
            }
        }
    }

    pub fn validate(self: *const View) Error!void {
        return self.verify();
    }

    pub fn kind(self: *const View, node: Node) Error!Kind {
        return self.kindAtIndex(try rawNodeIndex(node, self.count));
    }

    pub fn subtreeSize(self: *const View, node: Node) Error!usize {
        return (try self.descriptorAtNode(try rawNodeIndex(node, self.count))).descriptor.subtree_size;
    }

    pub fn subtreeEnd(self: *const View, node: Node) Error!usize {
        const index = try rawNodeIndex(node, self.count);
        const info = try self.descriptorAtNode(index);
        const local_end = try checkedAdd(info.local, info.descriptor.subtree_size);
        if (local_end > try self.skeletonNodeCount(try self.rootIdAt(info.root_index))) return error.InvalidForest;
        return try checkedAdd(info.root_start, local_end);
    }

    pub fn parent(self: *const View, node: Node) Error!?Node {
        const info = try self.descriptorAtNode(try rawNodeIndex(node, self.count));
        if (info.descriptor.parent_delta == 0) return null;
        const local_parent = info.local - info.descriptor.parent_delta;
        return @as(?Node, try nodeFromIndex(try checkedAdd(info.root_start, local_parent)));
    }

    pub fn root(self: *const View, node: Node) Error!Node {
        const root_index = try self.rootIndex(try rawNodeIndex(node, self.count));
        return self.rootAt(root_index);
    }

    pub fn rootAt(self: *const View, index: usize) Error!Node {
        return nodeFromIndex(try self.rootStart(index));
    }

    pub fn rootCount(self: *const View) usize {
        return self.root_count;
    }

    pub fn skeletonId(self: *const View, root_index: usize) Error!u32 {
        return self.rootIdAt(root_index);
    }

    /// Keys intentionally do not exist in this view; use the automaton's
    /// select operation with the corresponding entry rank.
    pub fn rootKey(self: *const View, index: usize) Error![]const u8 {
        if (index >= self.root_count) return error.InvalidRoot;
        return error.KeysNotStored;
    }

    pub fn rootRange(self: *const View, first: usize, end: usize) Error!NodeRange {
        if (first > end or end > self.root_count) return error.InvalidRoot;
        const lo = if (first == self.root_count) self.count else try self.rootStart(first);
        const hi = if (end == self.root_count) self.count else try self.rootStart(end);
        return .{ .lo = lo, .hi = hi };
    }

    pub fn kindCount(self: *const View, comptime wanted: Kind) Error!usize {
        return (try self.kindRankAt(wanted, self.count)).index() orelse error.InvalidRank;
    }

    fn constantKindRankAt(self: *const View, comptime wanted: Kind, index: usize) Error!usize {
        if (self.root_count == 0) return 0;
        if (self.uniform_size == 0) return error.InvalidForest;

        const id = try self.rootIdAt(0);
        const skeleton_size = try self.skeletonNodeCount(id);
        if (skeleton_size != self.uniform_size) return error.InvalidForest;
        const per_root = try self.skeletonKindCount(id, wanted);
        const total_nodes = try checkedMul(self.root_count, self.uniform_size);
        if (total_nodes != self.count) return error.InvalidForest;

        if (index == self.count)
            return checkedMul(self.root_count, per_root);
        if (index > self.count) return error.InvalidNode;

        const root_index = index / self.uniform_size;
        if (root_index >= self.root_count) return error.InvalidNode;
        const local = index % self.uniform_size;
        const base = try checkedMul(root_index, per_root);
        return checkedAdd(base, try self.skeletonKindPrefix(id, wanted, local));
    }

    fn mixedKindRankAt(self: *const View, comptime wanted: Kind, index: usize) Error!usize {
        if (index > self.count) return error.InvalidNode;
        if (self.root_count == 0) return 0;
        if (self.kindLane(wanted) == null) return 0;
        const root_index = try self.rootAtBoundary(index);
        const checkpoint = root_index / checkpoint_stride;
        var result = try self.checkpointKind(checkpoint, wanted);
        var cursor = try checkedMul(checkpoint, checkpoint_stride);
        while (cursor < root_index) : (cursor += 1) result = std.math.add(usize, result, try self.skeletonKindCount(try self.rootIdAt(cursor), wanted)) catch return error.InvalidForest;
        if (root_index < self.root_count) {
            const start = try self.rootStart(root_index);
            const local = index - start;
            const id = try self.rootIdAt(root_index);
            result = try checkedAdd(result, try self.skeletonKindPrefix(id, wanted, local));
        }
        return result;
    }

    /// Return the rank of `wanted` immediately before preorder boundary
    /// `index`. Constant root sequences use a checked affine measure derived
    /// from their canonical descriptor; mixed sequences use stored checkpoint
    /// measures and the same local prefix operation. Neither path allocates.
    fn kindMeasureAt(self: *const View, comptime wanted: Kind, index: usize) Error!usize {
        return if (self.derived_constant_summaries)
            self.constantKindRankAt(wanted, index)
        else
            self.mixedKindRankAt(wanted, index);
    }

    pub fn kindRankAt(self: *const View, comptime wanted: Kind, index: usize) Error!Rank(wanted) {
        return Rank(wanted).fromIndex(try self.kindMeasureAt(wanted, index)) catch error.OutOfRange;
    }

    pub fn kindRank(self: *const View, comptime wanted: Kind, node: Node) Error!Rank(wanted) {
        return self.kindRankAt(wanted, try rawNodeIndex(node, self.count));
    }

    pub fn project(self: *const View, comptime wanted: Kind, range: NodeRange) Error!Interval(wanted) {
        if (range.lo > range.hi or range.hi > self.count) return error.InvalidNode;
        return Interval(wanted).init(try self.kindRankAt(wanted, range.lo), try self.kindRankAt(wanted, range.hi));
    }

    pub fn projectRoots(self: *const View, comptime wanted: Kind, range: RootRange) Error!Interval(wanted) {
        if (range.first > range.end or range.end > self.root_count) return error.InvalidRoot;
        return self.project(wanted, try self.rootRange(range.first, range.end));
    }

    pub fn nodeSet(self: *const View, comptime wanted: Kind, range: NodeRange) Error!NodeSet(wanted) {
        return .{ .interval = try self.project(wanted, range) };
    }

    fn selectLocal(self: *const View, id: usize, comptime wanted: Kind, ordinal: usize) Error!usize {
        const node_count = try self.skeletonNodeCount(id);
        var seen: usize = 0;
        for (0..node_count) |local| {
            if ((try self.descriptorAt(id, local)).kind != wanted) continue;
            if (seen == ordinal) return local;
            seen = std.math.add(usize, seen, 1) catch return error.InvalidForest;
        }
        return error.OutOfRange;
    }

    fn selectLocationConstant(self: *const View, comptime wanted: Kind, ordinal: usize) Error!Location {
        if (self.root_count == 0) return error.OutOfRange;
        if (self.uniform_size == 0) return error.InvalidForest;
        const id = try self.rootIdAt(0);
        const skeleton_size = try self.skeletonNodeCount(id);
        if (skeleton_size != self.uniform_size) return error.InvalidForest;
        const per_root = try self.skeletonKindCount(id, wanted);
        if (per_root == 0) return error.OutOfRange;
        if (try checkedMul(self.root_count, self.uniform_size) != self.count) return error.InvalidForest;
        const total = try checkedMul(self.root_count, per_root);
        if (ordinal >= total) return error.OutOfRange;
        const root_index = ordinal / per_root;
        const local_ordinal = ordinal % per_root;
        const start = try checkedMul(root_index, self.uniform_size);
        return .{ .root_index = root_index, .root_start = start, .skeleton_id = @intCast(id), .local = try self.selectLocal(id, wanted, local_ordinal) };
    }

    fn selectLocationMixed(self: *const View, comptime wanted: Kind, ordinal: usize) Error!Location {
        const column = self.kindColumn(wanted);
        if (column.lane == null) return error.OutOfRange;
        const total = try self.kindMeasureAt(wanted, self.count);
        if (ordinal >= total) return error.OutOfRange;

        // Find the last checkpoint whose cumulative measure does not exceed
        // the requested rank. Equal checkpoint values are intentionally
        // skipped, so zero-occurrence blocks do not strand the search.
        var lo: usize = 0;
        var hi: usize = self.checkpoint_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const value = try self.checkpointColumn(mid, column);
            if (value <= ordinal) lo = try checkedAdd(mid, 1) else hi = mid;
        }
        const checkpoint = if (lo == 0) 0 else lo - 1;
        var root_index = try checkedMul(checkpoint, checkpoint_stride);
        var base = try self.checkpointColumn(checkpoint, column);
        const end = @min(self.root_count, try checkedAdd(root_index, checkpoint_stride));
        while (root_index < end) : (root_index += 1) {
            const id = try self.rootIdAt(root_index);
            const per_root = try self.skeletonColumnCount(id, column);
            const next = try checkedAdd(base, per_root);
            if (ordinal < next) {
                const start = try self.rootStart(root_index);
                const local = self.selectLocal(id, wanted, ordinal - base) catch |err| switch (err) {
                    error.OutOfRange => return error.InvalidForest,
                    else => |other| return other,
                };
                return .{ .root_index = root_index, .root_start = start, .skeleton_id = @intCast(id), .local = local };
            }
            base = next;
        }
        return error.InvalidForest;
    }

    pub fn selectLocation(self: *const View, comptime wanted: Kind, value: Rank(wanted)) Error!Location {
        const ordinal = value.index() orelse return error.InvalidRank;
        return if (self.derived_constant_summaries)
            self.selectLocationConstant(wanted, ordinal)
        else
            self.selectLocationMixed(wanted, ordinal);
    }

    fn kindMeasureBeforeRoot(self: *const View, comptime wanted: Kind, root_index: usize) Error!usize {
        if (root_index > self.root_count) return error.InvalidRoot;
        if (self.derived_constant_summaries) {
            if (root_index == self.root_count) return self.constantKindRankAt(wanted, self.count);
            return checkedMul(root_index, try self.skeletonKindCount(0, wanted));
        }
        const column = self.kindColumn(wanted);
        const checkpoint = root_index / checkpoint_stride;
        var result = try self.checkpointColumn(checkpoint, column);
        var cursor = try checkedMul(checkpoint, checkpoint_stride);
        while (cursor < root_index) : (cursor += 1)
            result = try checkedAdd(result, try self.skeletonColumnCount(try self.rootIdAt(cursor), column));
        return result;
    }

    pub fn projectLocation(self: *const View, comptime wanted: Kind, location: Location) Error!Interval(wanted) {
        if (location.root_index >= self.root_count or
            try self.rootStart(location.root_index) != location.root_start or
            try self.rootIdAt(location.root_index) != location.skeleton_id) return error.InvalidForest;
        const node_count = try self.skeletonNodeCount(location.skeleton_id);
        if (location.local >= node_count) return error.InvalidNode;
        const subtree = (try self.descriptorAt(location.skeleton_id, location.local)).subtree_size;
        const local_start = try checkedAdd(location.local, 1);
        const local_end = try checkedAdd(location.local, subtree);
        if (local_end > node_count) return error.InvalidForest;
        const base = try self.kindMeasureBeforeRoot(wanted, location.root_index);
        var before: usize = 0;
        var through: usize = 0;
        for (0..local_end) |local| {
            if ((try self.descriptorAt(location.skeleton_id, local)).kind != wanted) continue;
            through = try checkedAdd(through, 1);
            if (local < local_start) before = try checkedAdd(before, 1);
        }
        const lo = Rank(wanted).fromIndex(try checkedAdd(base, before)) catch return error.OutOfRange;
        const hi = Rank(wanted).fromIndex(try checkedAdd(base, through)) catch return error.OutOfRange;
        return Interval(wanted).init(lo, hi);
    }

    /// Inverse of `kindRankAt`: return the preorder node carrying `wanted`
    /// rank `value`.  Constant sequences use quotient/remainder over one
    /// descriptor; mixed sequences binary-search stored checkpoint measures,
    /// then scan only one checkpoint block and one local skeleton. A rank
    /// outside this kind's domain returns `OutOfRange`; `.none` is invalid.
    pub fn selectKind(self: *const View, comptime wanted: Kind, value: Rank(wanted)) Error!Node {
        const location = try self.selectLocation(wanted, value);
        return nodeFromIndex(try checkedAdd(location.root_start, location.local));
    }

    pub const Skeleton = struct {
        view: *const View,
        id: u32,
        start: usize,
        end: usize,

        pub fn len(self: Skeleton) usize {
            return self.end - self.start;
        }

        pub fn nodeAt(self: Skeleton, local: usize) Error!Node {
            if (local >= self.len()) return error.InvalidNode;
            return nodeFromIndex(try checkedAdd(self.start, local));
        }

        pub fn kindAt(self: Skeleton, local: usize) Error!Kind {
            return (try self.view.descriptorAt(self.id, local)).kind;
        }

        pub fn subtreeSizeAt(self: Skeleton, local: usize) Error!usize {
            return (try self.view.descriptorAt(self.id, local)).subtree_size;
        }

        pub fn parentAt(self: Skeleton, local: usize) Error!?Node {
            const descriptor = try self.view.descriptorAt(self.id, local);
            if (descriptor.parent_delta == 0) return null;
            return @as(?Node, try nodeFromIndex(self.start + local - descriptor.parent_delta));
        }
    };

    pub fn skeleton(self: *const View, root_index: usize) Error!Skeleton {
        const start = try self.rootStart(root_index);
        return .{ .view = self, .id = try self.rootIdAt(root_index), .start = start, .end = try self.rootEnd(root_index) };
    }

    pub fn byteLedger(self: *const View) ByteLedger {
        return .{
            .header = header_size,
            .skeleton_directory = self.directory.len,
            .skeleton_data = self.skeleton_data.len,
            .skeleton_kind_counts = self.skeleton_counts.len,
            .root_sequence = self.root_sequence.len,
            .root_starts = self.root_starts.len,
            .root_checkpoints = self.checkpoints.len,
        };
    }
};

const DraftNode = enum(u32) { none = std.math.maxInt(u32), _ };
const Draft = struct {
    kind: Kind,
    parent: ?DraftNode,
    children: std.ArrayList(DraftNode) = .empty,
};
const DraftRoot = struct { key: []u8, node: DraftNode };

/// Mutable construction API. Roots are ordered by key before emission;
/// callers that already have automaton order can still use the same API.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Draft) = .empty,
    roots: std.ArrayList(DraftRoot) = .empty,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        for (self.roots.items) |root| self.allocator.free(root.key);
        for (self.nodes.items) |*node| node.children.deinit(self.allocator);
        self.roots.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    fn checkedDraft(self: *const Builder, node: DraftNode) Error!usize {
        const raw = @intFromEnum(node);
        if (raw == std.math.maxInt(u32) or raw >= self.nodes.items.len) return error.InvalidNode;
        return raw;
    }

    pub fn addRoot(self: *Builder, key: []const u8, kind: Kind) Error!DraftNode {
        if (key.len == 0 or !schema.spec(kind).root) return error.InvalidRoot;
        const copied = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(copied);
        const raw = std.math.cast(u32, self.nodes.items.len) orelse return error.InvalidForest;
        if (raw == std.math.maxInt(u32)) return error.InvalidForest;
        try self.nodes.append(self.allocator, .{ .kind = kind, .parent = null });
        errdefer _ = self.nodes.pop();
        try self.roots.append(self.allocator, .{ .key = copied, .node = @enumFromInt(raw) });
        return @enumFromInt(raw);
    }

    pub fn addChild(self: *Builder, parent: DraftNode, kind: Kind) Error!DraftNode {
        const parent_index = try self.checkedDraft(parent);
        if (!schema.legalParent(self.nodes.items[parent_index].kind, kind)) return error.InvalidForest;
        const raw = std.math.cast(u32, self.nodes.items.len) orelse return error.InvalidForest;
        if (raw == std.math.maxInt(u32)) return error.InvalidForest;
        try self.nodes.append(self.allocator, .{ .kind = kind, .parent = parent });
        errdefer _ = self.nodes.pop();
        self.nodes.items[parent_index].children.append(self.allocator, @enumFromInt(raw)) catch |err| return err;
        return @enumFromInt(raw);
    }

    fn compareTree(self: *const Builder, left: DraftNode, right: DraftNode) std.math.Order {
        const a = self.nodes.items[@intFromEnum(left)];
        const b = self.nodes.items[@intFromEnum(right)];
        if (@intFromEnum(a.kind) < @intFromEnum(b.kind)) return .lt;
        if (@intFromEnum(a.kind) > @intFromEnum(b.kind)) return .gt;
        if (a.children.items.len < b.children.items.len) return .lt;
        if (a.children.items.len > b.children.items.len) return .gt;
        for (a.children.items, b.children.items) |child_a, child_b| {
            const order = self.compareTree(child_a, child_b);
            if (order != .eq) return order;
        }
        return .eq;
    }

    fn rootLess(self: *const Builder, left: usize, right: usize) bool {
        const a = self.roots.items[left];
        const b = self.roots.items[right];
        const key_order = std.mem.order(u8, a.key, b.key);
        if (key_order == .lt) return true;
        if (key_order == .gt) return false;
        return self.compareTree(a.node, b.node) == .lt;
    }

    fn emit(self: *const Builder, draft: DraftNode, parent: ?Node, records: []NodeRecord, cursor: *usize) Error!usize {
        const draft_index = try self.checkedDraft(draft);
        if (cursor.* >= records.len) return error.InvalidForest;
        const start = cursor.*;
        const emitted_node = nodeFromIndex(start) catch return error.InvalidForest;
        records[start] = .{ .kind = self.nodes.items[draft_index].kind, .subtree_size = 0, .parent = parent };
        cursor.* += 1;
        for (self.nodes.items[draft_index].children.items) |child| _ = try self.emit(child, emitted_node, records, cursor);
        records[start].subtree_size = std.math.cast(u32, cursor.* - start) orelse return error.InvalidForest;
        return start;
    }

    fn buildInternal(self: *Builder, entry_count: ?usize) Error!Owned {
        if (entry_count) |expected| if (self.roots.items.len != expected) return error.EntryCountMismatch;
        if (self.nodes.items.len == 0 or self.roots.items.len == 0) {
            if (self.nodes.items.len != 0 or self.roots.items.len != 0) return error.InvalidForest;
            return encode(self.allocator, &.{}, &.{});
        }
        if (self.nodes.items.len >= std.math.maxInt(u32) or self.roots.items.len >= std.math.maxInt(u32)) return error.InvalidForest;

        const sorted = try self.allocator.alloc(usize, self.roots.items.len);
        defer self.allocator.free(sorted);
        for (sorted, 0..) |*value, index| value.* = index;
        std.mem.sortUnstable(usize, sorted, self, struct {
            fn less(context: *Builder, left: usize, right: usize) bool {
                return context.rootLess(left, right);
            }
        }.less);

        const records = try self.allocator.alloc(NodeRecord, self.nodes.items.len);
        defer self.allocator.free(records);
        const roots = try self.allocator.alloc(RootInput, self.roots.items.len);
        defer self.allocator.free(roots);
        var cursor: usize = 0;
        for (sorted, 0..) |root_order, root_index| {
            const start = cursor;
            _ = try self.emit(self.roots.items[root_order].node, null, records, &cursor);
            roots[root_index] = .{ .key = self.roots.items[root_order].key, .start = nodeFromIndex(start) catch return error.InvalidForest };
        }
        if (cursor != self.nodes.items.len) return error.InvalidForest;
        if (entry_count) |expected| return encodeWithEntryCount(self.allocator, expected, records, roots);
        return encode(self.allocator, records, roots);
    }

    pub fn build(self: *Builder) Error!Owned {
        return self.buildInternal(null);
    }

    pub fn buildForEntryCount(self: *Builder, entry_count: usize) Error!Owned {
        return self.buildInternal(entry_count);
    }

    pub fn buildForAutomaton(self: *Builder, automaton_view: anytype) Error!Owned {
        return self.buildInternal(@intCast(automaton_view.entry_count));
    }
};
