//! Experimental reflected shape templates with an occurrence-local literal lane.
//! Each composite template contains only structural controls (default masks,
//! option presence, union tags, collection lengths and child template IDs).
//! Scalar and byte-string leaves stay in exact preorder lanes. This is a cost
//! oracle; it reconstructs the public native type before semantic admission.
const std = @import("std");
const lex = @import("lex6");
const packet = lex.packet;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const header_size: usize = 64;
pub const checkpoint_stride: usize = 32;
pub const Limits = struct {
    max_page_bytes: usize = 64 * 1024,
    max_nodes: usize = 65_535,
    max_roots: usize = 4096,
    max_work: usize = 16 * 1024 * 1024,
    max_expanded_allocation: usize = 64 * 1024 * 1024,
    packet: packet.Limits = .{},
};
pub const Error = packet.Error || lex.validate.Error || error{
    InvalidPage,
    InvalidSchema,
    DigestMismatch,
    InvalidNode,
    InvalidReference,
    TypeMismatch,
    DuplicateNode,
    UnreachableNode,
    InvalidCheckpoint,
    ExpandedWorkLimit,
    ExpandedAllocationLimit,
    PageTooLarge,
    TooManyNodes,
    TooManyRoots,
    NonCanonicalDefault,
    SemanticAdmissionUnavailable,
};
const DecodeBudget = struct { work: usize = 0, allocated: usize = 0, leaves: usize = 0, limits: Limits, root: RootRec };

fn inlineType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .void, .bool, .int, .@"enum" => true,
        else => false,
    };
}
fn bytesType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child == u8,
        else => false,
    };
}
fn typesReachable(comptime T: type, comptime prior: []const type) []const type {
    @setEvalBranchQuota(500_000);
    for (prior) |P| if (P == T) return prior;
    comptime var result: []const type = prior ++ .{T};
    switch (@typeInfo(T)) {
        .optional => |p| result = typesReachable(p.child, result),
        .pointer => |p| result = typesReachable(p.child, result),
        .array => |a| result = typesReachable(a.child, result),
        .@"struct" => |s| inline for (s.fields) |f| {
            result = typesReachable(f.type, result);
        },
        .@"union" => |u| inline for (u.fields) |f| {
            result = typesReachable(f.type, result);
        },
        else => {},
    }
    return result;
}
fn Schema(comptime Root: type) type {
    return struct {
        const types = typesReachable(Root, &.{});
    };
}
fn typeOrdinal(comptime Root: type, comptime T: type) u32 {
    inline for (Schema(Root).types, 0..) |P, i| if (P == T) return @intCast(i);
    @compileError("type is not reachable from root schema");
}
fn checkpointCount(leaves: usize) usize {
    return leaves / checkpoint_stride + @intFromBool(leaves % checkpoint_stride != 0);
}

fn fingerprint(comptime Root: type) u64 {
    // Reuse the already-reviewed public-model schema descriptor from the exact
    // DAG experiment, so shape and DAG frames cannot disagree on type identity.
    return @import("dag.zig").schemaFingerprint(Root);
}
fn putU32(b: []u8, at: usize, n: usize) void {
    std.mem.writeInt(u32, b[at..][0..4], @intCast(n), .little);
}
fn getU32(b: []const u8, at: usize) usize {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}
fn appendVarint(out: *std.ArrayList(u8), a: std.mem.Allocator, input: u64) Error!void {
    var value = input;
    while (value >= 128) {
        try out.append(a, @as(u8, @truncate(value)) | 128);
        value >>= 7;
    }
    try out.append(a, @intCast(value));
}
const Cursor = struct {
    bytes: []const u8,
    at: usize = 0,
    fn byte(self: *Cursor) Error!u8 {
        if (self.at >= self.bytes.len) return error.Truncated;
        const b = self.bytes[self.at];
        self.at += 1;
        return b;
    }
    fn take(self: *Cursor, n: usize) Error![]const u8 {
        if (n > self.bytes.len - self.at) return error.Truncated;
        const b = self.bytes[self.at..][0..n];
        self.at += n;
        return b;
    }
    fn varint(self: *Cursor) Error!u64 {
        var out: u64 = 0;
        var shift: u6 = 0;
        for (0..10) |i| {
            const b = try self.byte();
            if (i == 9 and b > 1) return error.IntegerOverflow;
            out |= @as(u64, b & 127) << shift;
            if (b & 128 == 0) {
                if (i != 0 and b == 0) return error.NonCanonicalVarint;
                return out;
            }
            if (i != 9) shift += 7;
        }
        return error.IntegerOverflow;
    }
    fn length(self: *Cursor, limit: usize) Error!usize {
        const n = try self.varint();
        if (n > limit or n > std.math.maxInt(usize)) return error.SliceTooLong;
        return @intCast(n);
    }
};
fn encodeScalar(comptime T: type, out: *std.ArrayList(u8), a: std.mem.Allocator, value: T) Error!void {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(a);
    switch (@typeInfo(T)) {
        .void => {},
        .bool => try raw.append(a, @intFromBool(value)),
        .int => |i| {
            if (i.bits > 64) return error.UnsupportedType;
            const encoded: u64 = if (i.signedness == .signed) encoded: {
                const x: i64 = value;
                break :encoded (@as(u64, @bitCast(x)) << 1) ^ @as(u64, @bitCast(x >> 63));
            } else value;
            try appendVarint(&raw, a, encoded);
        },
        .@"enum" => |e| {
            inline for (e.fields, 0..) |f, ordinal| if (value == @field(T, f.name)) try appendVarint(&raw, a, ordinal);
        },
        else => return error.UnsupportedType,
    }
    try appendVarint(out, a, raw.items.len);
    try out.appendSlice(a, raw.items);
}

const LeafWriter = struct {
    allocator: std.mem.Allocator,
    max_bytes: usize,
    bytes: std.ArrayList(u8) = .empty,
    checkpoints: std.ArrayList(u32) = .empty,
    leaves: usize = 0,
    fn add(self: *LeafWriter, raw: []const u8) Error!void {
        const prefix_bytes = varintSize(raw.len);
        const next = std.math.add(usize, self.bytes.items.len, prefix_bytes) catch return error.PageTooLarge;
        const end = std.math.add(usize, next, raw.len) catch return error.PageTooLarge;
        if (end > self.max_bytes) return error.PageTooLarge;
        if (self.leaves % checkpoint_stride == 0) {
            if (self.bytes.items.len > std.math.maxInt(u32)) return error.InputTooLarge;
            try self.checkpoints.append(self.allocator, @intCast(self.bytes.items.len));
        }
        try appendVarint(&self.bytes, self.allocator, raw.len);
        try self.bytes.appendSlice(self.allocator, raw);
        self.leaves += 1;
    }
    fn scalar(self: *LeafWriter, comptime T: type, value: T) Error!void {
        var framed: std.ArrayList(u8) = .empty;
        defer framed.deinit(self.allocator);
        try encodeScalar(T, &framed, self.allocator, value); // contains leaf length too; unwrap below
        var c = Cursor{ .bytes = framed.items };
        const n = try c.length(framed.items.len);
        try self.add(try c.take(n));
    }
    fn string(self: *LeafWriter, value: []const u8) Error!void {
        try self.add(value);
    }
};
fn varintSize(value: usize) usize {
    var n = value;
    var size: usize = 1;
    while (n >= 128) : (size += 1) n >>= 7;
    return size;
}

fn ShapeEncoder(comptime Root: type) type {
    return struct {
        allocator: std.mem.Allocator,
        limits: Limits,
        nodes: std.ArrayList([]const u8) = .empty,
        intern: std.StringHashMapUnmanaged(u32) = .empty,
        work: usize = 0,
        shape_size: usize = 0,
        const Self = @This();
        fn edge(self: *Self, comptime T: type, value: T, leaves: *LeafWriter, out: *std.ArrayList(u8), depth: usize) Error!void {
            if (depth > self.limits.packet.max_depth) return error.DepthLimit;
            self.work = std.math.add(usize, self.work, 1) catch return error.ExpandedWorkLimit;
            if (self.work > self.limits.max_work or self.work > self.limits.packet.max_work) return error.ExpandedWorkLimit;
            if (comptime T == void) return;
            if (comptime inlineType(T)) return leaves.scalar(T, value);
            if (comptime bytesType(T)) {
                if (value.len > self.limits.packet.max_slice_length) return error.SliceTooLong;
                self.work = std.math.add(usize, self.work, value.len) catch return error.WorkLimit;
                if (self.work > self.limits.max_work or self.work > self.limits.packet.max_work) return error.WorkLimit;
                return leaves.string(value);
            }
            const id = try self.node(T, value, leaves, depth);
            try appendVarint(out, self.allocator, id);
            if (out.items.len > self.limits.max_page_bytes) return error.PageTooLarge;
        }
        fn node(self: *Self, comptime T: type, value: T, leaves: *LeafWriter, depth: usize) Error!u32 {
            @setEvalBranchQuota(500_000);
            if (depth > self.limits.packet.max_depth) return error.DepthLimit;
            self.work = std.math.add(usize, self.work, 1) catch return error.WorkLimit;
            if (self.work > self.limits.max_work or self.work > self.limits.packet.max_work) return error.WorkLimit;
            var payload: std.ArrayList(u8) = .empty;
            const leaves_start = leaves.leaves;
            try appendVarint(&payload, self.allocator, typeOrdinal(Root, T));
            switch (@typeInfo(T)) {
                .optional => |o| {
                    try payload.append(self.allocator, @intFromBool(value != null));
                    if (value) |v| try self.edge(o.child, v, leaves, &payload, depth + 1);
                },
                .pointer => |p| if (p.size == .one) {
                    try self.edge(p.child, value.*, leaves, &payload, depth + 1);
                } else if (p.size == .slice) {
                    try appendVarint(&payload, self.allocator, value.len);
                    for (value) |v| try self.edge(p.child, v, leaves, &payload, depth + 1);
                } else return error.UnsupportedType,
                .array => |a| for (value) |v| try self.edge(a.child, v, leaves, &payload, depth + 1),
                .@"struct" => |s| {
                    const defaults = comptime packet.defaultCount(T);
                    var mask: u64 = 0;
                    comptime var bit = 0;
                    if (defaults != 0) {
                        inline for (s.fields) |f| if (comptime packet.elidable(f)) {
                            if (!packet.equalsDefault(f.type, @field(value, f.name), packet.defaultValue(f))) mask |= @as(u64, 1) << bit;
                            bit += 1;
                        };
                        try appendVarint(&payload, self.allocator, mask);
                    }
                    bit = 0;
                    inline for (s.fields) |f| {
                        const present = if (comptime defaults != 0 and packet.elidable(f)) present: {
                            const p = mask & (@as(u64, 1) << bit) != 0;
                            bit += 1;
                            break :present p;
                        } else true;
                        if (present) try self.edge(f.type, @field(value, f.name), leaves, &payload, depth + 1);
                    }
                },
                .@"union" => |u| {
                    switch (value) {
                        inline else => |v, tag| {
                            inline for (u.fields, 0..) |f, i| if (comptime std.mem.eql(u8, f.name, @tagName(tag))) try appendVarint(&payload, self.allocator, i);
                            try self.edge(@TypeOf(v), v, leaves, &payload, depth + 1);
                        },
                    }
                },
                else => return error.UnsupportedType,
            }
            try appendVarint(&payload, self.allocator, leaves.leaves - leaves_start);
            if (payload.items.len > self.limits.max_page_bytes) return error.PageTooLarge;
            if (self.intern.get(payload.items)) |old| {
                payload.deinit(self.allocator);
                return old;
            }
            if (self.nodes.items.len >= self.limits.max_nodes) return error.TooManyNodes;
            if (self.nodes.items.len >= self.limits.max_page_bytes / 8) return error.PageTooLarge;
            self.shape_size = std.math.add(usize, self.shape_size, payload.items.len) catch return error.PageTooLarge;
            if (self.shape_size > self.limits.max_page_bytes) return error.PageTooLarge;
            const owned = try payload.toOwnedSlice(self.allocator);
            const id: u32 = @intCast(self.nodes.items.len);
            try self.nodes.append(self.allocator, owned);
            try self.intern.put(self.allocator, owned, id);
            return id;
        }
    };
}

const RootRec = struct { shape: u32, lane_at: u32, lane_len: u32, checkpoint_at: u32, leaves: u32 };
fn seal(out: []u8) void {
    var h = Sha256.init(.{});
    h.update(out[0..32]);
    h.update(out[64..]);
    h.final(out[32..64]);
}
fn frame(comptime Root: type, allocator: std.mem.Allocator, records: []const []const u8, roots: []const RootRec, lane: []const u8, checkpoints: []const u32, limits: Limits) Error![]u8 {
    var shape_size: usize = 0;
    for (records) |r| shape_size = std.math.add(usize, shape_size, r.len) catch return error.PageTooLarge;
    const offsets_bytes = (records.len + 1) * 4;
    const roots_bytes = roots.len * 20;
    const checkpoints_bytes = checkpoints.len * 4;
    const directory_size = std.math.add(usize, header_size, offsets_bytes) catch return error.PageTooLarge;
    const with_roots = std.math.add(usize, directory_size, roots_bytes) catch return error.PageTooLarge;
    const with_checkpoints = std.math.add(usize, with_roots, checkpoints_bytes) catch return error.PageTooLarge;
    const body_size = std.math.add(usize, shape_size, lane.len) catch return error.PageTooLarge;
    const total = std.math.add(usize, with_checkpoints, body_size) catch return error.PageTooLarge;
    if (total > limits.max_page_bytes or total > std.math.maxInt(u32)) return error.PageTooLarge;
    const out = try allocator.alloc(u8, total);
    @memset(out, 0);
    @memcpy(out[0..4], "LPS1");
    out[4] = 1;
    putU32(out, 8, roots.len);
    putU32(out, 12, records.len);
    putU32(out, 16, shape_size);
    putU32(out, 20, lane.len);
    std.mem.writeInt(u64, out[24..32], comptime fingerprint(Root), .little);
    const offsets_at = header_size;
    const roots_at = offsets_at + offsets_bytes;
    const checkpoints_at = roots_at + roots_bytes;
    const shape_at = checkpoints_at + checkpoints_bytes;
    const lane_at = shape_at + shape_size;
    var p: usize = 0;
    for (records, 0..) |r, i| {
        putU32(out, offsets_at + i * 4, p);
        @memcpy(out[shape_at + p ..][0..r.len], r);
        p += r.len;
    }
    putU32(out, offsets_at + records.len * 4, p);
    for (roots, 0..) |r, i| {
        const at = roots_at + i * 20;
        putU32(out, at, r.shape);
        putU32(out, at + 4, r.lane_at);
        putU32(out, at + 8, r.lane_len);
        putU32(out, at + 12, r.checkpoint_at);
        putU32(out, at + 16, r.leaves);
    }
    for (checkpoints, 0..) |c, i| putU32(out, checkpoints_at + i * 4, c);
    @memcpy(out[lane_at..], lane);
    seal(out);
    return out;
}

pub fn encodePage(comptime Root: type, allocator: std.mem.Allocator, values: []const Root, limits: Limits) Error![]u8 {
    if (values.len > limits.max_roots) return error.TooManyRoots;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var enc = ShapeEncoder(Root){ .allocator = a, .limits = limits };
    var lane: std.ArrayList(u8) = .empty;
    var checkpoints: std.ArrayList(u32) = .empty;
    var roots: std.ArrayList(RootRec) = .empty;
    for (values) |value| {
        const lane_start = lane.items.len;
        const cp_start = checkpoints.items.len;
        var leaves = LeafWriter{ .allocator = a, .max_bytes = limits.max_page_bytes };
        const root_id = try enc.node(Root, value, &leaves, 0);
        if (lane.items.len > std.math.maxInt(u32) or leaves.bytes.items.len > std.math.maxInt(u32)) return error.InputTooLarge;
        for (leaves.checkpoints.items) |cp| try checkpoints.append(a, @intCast(@as(usize, @intCast(cp)) + lane_start));
        const lane_end = std.math.add(usize, lane.items.len, leaves.bytes.items.len) catch return error.PageTooLarge;
        if (lane_end > limits.max_page_bytes) return error.PageTooLarge;
        try lane.appendSlice(a, leaves.bytes.items);
        try roots.append(a, .{ .shape = root_id, .lane_at = @intCast(lane_start), .lane_len = @intCast(leaves.bytes.items.len), .checkpoint_at = @intCast(cp_start), .leaves = @intCast(leaves.leaves) });
    }
    return frame(Root, allocator, enc.nodes.items, roots.items, lane.items, checkpoints.items, limits);
}

pub fn Page(comptime Root: type) type {
    return struct {
        bytes: []const u8,
        count: usize,
        node_count: usize,
        offsets: []const u8,
        roots: []const u8,
        checkpoints: []const u8,
        shape_bytes: []const u8,
        lane: []const u8,
        limits: Limits,
        expanded_work: usize = 0,
        expanded_allocation: usize = 0,
        const Self = @This();
        fn record(self: Self, id: usize) Error![]const u8 {
            if (id >= self.node_count) return error.InvalidNode;
            return self.shape_bytes[getU32(self.offsets, id * 4)..getU32(self.offsets, (id + 1) * 4)];
        }
        fn root(self: Self, i: usize) Error!RootRec {
            if (i >= self.count) return error.InvalidReference;
            const at = i * 20;
            return .{ .shape = @intCast(getU32(self.roots, at)), .lane_at = @intCast(getU32(self.roots, at + 4)), .lane_len = @intCast(getU32(self.roots, at + 8)), .checkpoint_at = @intCast(getU32(self.roots, at + 12)), .leaves = @intCast(getU32(self.roots, at + 16)) };
        }
        fn body(self: Self, id: u32, comptime T: type) Error![]const u8 {
            var c = Cursor{ .bytes = try self.record(id) };
            if (try c.varint() != typeOrdinal(Root, T)) return error.TypeMismatch;
            return c.bytes[c.at..];
        }
        pub fn templateBytes(self: Self, id: u32, comptime T: type) Error![]const u8 {
            return self.body(id, T);
        }
        pub fn templateHoles(self: Self, id: u32) Error!usize {
            const raw_record = try self.record(id);
            var prefix = Cursor{ .bytes = raw_record };
            _ = try prefix.varint();
            const body_bytes = raw_record[prefix.at..];
            if (body_bytes.len == 0) return error.InvalidNode;
            var start = body_bytes.len - 1;
            while (start > 0 and body_bytes[start - 1] & 0x80 != 0) start -= 1;
            var tail = Cursor{ .bytes = body_bytes[start..] };
            const holes = try tail.varint();
            if (tail.at != tail.bytes.len or holes > std.math.maxInt(usize)) return error.InvalidNode;
            return @intCast(holes);
        }
        pub fn rootShape(self: Self, i: usize) Error!u32 {
            return (try self.root(i)).shape;
        }
        pub fn literalCheckpoint(self: Self, i: usize, checkpoint: usize) Error![]const u8 {
            const r = try self.root(i);
            const count = checkpointCount(r.leaves);
            if (checkpoint >= count) return error.InvalidCheckpoint;
            const cp = getU32(self.checkpoints, (@as(usize, r.checkpoint_at) + checkpoint) * 4);
            const end = @as(usize, r.lane_at) + r.lane_len;
            if (cp > end or cp < r.lane_at) return error.InvalidCheckpoint;
            return self.lane[cp..end];
        }
        fn readLeaf(c: *Cursor, maximum: usize) Error![]const u8 {
            const n = try c.length(maximum);
            return c.take(n);
        }
        fn readOccurrenceLeaf(self: Self, c: *Cursor, budget: *DecodeBudget) Error![]const u8 {
            if (budget.leaves % checkpoint_stride == 0) {
                const cp_index = std.math.add(usize, budget.root.checkpoint_at, budget.leaves / checkpoint_stride) catch return error.InvalidCheckpoint;
                const cp_byte = std.math.mul(usize, cp_index, 4) catch return error.InvalidCheckpoint;
                const cp_end = std.math.add(usize, cp_byte, 4) catch return error.InvalidCheckpoint;
                const actual = std.math.add(usize, budget.root.lane_at, c.at) catch return error.InvalidCheckpoint;
                if (cp_end > self.checkpoints.len or getU32(self.checkpoints, cp_byte) != actual) return error.InvalidCheckpoint;
            }
            budget.leaves += 1;
            const maximum = std.math.add(usize, self.limits.packet.max_slice_length, 10) catch std.math.maxInt(usize);
            const raw = try readLeaf(c, maximum);
            budget.work = std.math.add(usize, budget.work, raw.len) catch return error.WorkLimit;
            if (budget.work > self.limits.max_work or budget.work > self.limits.packet.max_work) return error.WorkLimit;
            return raw;
        }
        fn decodeScalar(comptime T: type, c: *Cursor) Error!T {
            var x = c.*;
            const value: T = switch (@typeInfo(T)) {
                .void => {},
                .bool => switch (try x.byte()) {
                    0 => false,
                    1 => true,
                    else => return error.InvalidBoolean,
                },
                .int => |i| result: {
                    if (i.bits > 64) return error.UnsupportedType;
                    const n = try x.varint();
                    const U = std.meta.Int(.unsigned, i.bits);
                    if (n > std.math.maxInt(U)) return error.IntegerOverflow;
                    const narrowed: U = @intCast(n);
                    if (i.signedness == .signed) break :result @bitCast((narrowed >> 1) ^ (0 -% (narrowed & 1)));
                    break :result @intCast(narrowed);
                },
                .@"enum" => |e| result: {
                    const n = try x.varint();
                    inline for (e.fields, 0..) |f, ordinal| if (n == ordinal) break :result @field(T, f.name);
                    return error.InvalidEnum;
                },
                else => return error.UnsupportedType,
            };
            if (x.at != x.bytes.len) return error.TrailingBytes;
            c.* = x;
            return value;
        }
        fn edge(self: Self, comptime T: type, id: u32, c: *Cursor, leaves: *Cursor, a: std.mem.Allocator, budget: *DecodeBudget, depth: usize, seen: ?[]bool) Error!T {
            if (depth + 1 > self.limits.packet.max_depth) return error.DepthLimit;
            budget.work += 1;
            if (budget.work > self.limits.max_work or budget.work > self.limits.packet.max_work) return error.ExpandedWorkLimit;
            if (comptime T == void) return {};
            if (comptime inlineType(T)) {
                const raw = try self.readOccurrenceLeaf(leaves, budget);
                var scalar_cursor = Cursor{ .bytes = raw };
                return decodeScalar(T, &scalar_cursor);
            }
            if (comptime bytesType(T)) {
                const raw = try self.readOccurrenceLeaf(leaves, budget);
                if (raw.len > self.limits.packet.max_slice_length) return error.SliceTooLong;
                budget.allocated = std.math.add(usize, budget.allocated, raw.len) catch return error.AllocationLimit;
                if (budget.allocated > self.limits.packet.max_allocation_bytes or budget.allocated > self.limits.max_expanded_allocation) return error.AllocationLimit;
                return a.dupe(u8, raw) catch error.OutOfMemory;
            }
            const raw_child = try c.varint();
            if (raw_child >= id) return error.InvalidReference;
            const child: u32 = @intCast(raw_child);
            return self.decodeNode(T, child, leaves, a, budget, depth + 1, seen);
        }
        fn decodeNode(self: Self, comptime T: type, id: u32, leaves: *Cursor, a: std.mem.Allocator, budget: *DecodeBudget, depth: usize, seen: ?[]bool) Error!T {
            @setEvalBranchQuota(500_000);
            if (depth > self.limits.packet.max_depth) return error.DepthLimit;
            budget.work += 1;
            if (budget.work > self.limits.max_work or budget.work > self.limits.packet.max_work) return error.ExpandedWorkLimit;
            const leaves_start = budget.leaves;
            var c = Cursor{ .bytes = try self.body(id, T) };
            if (seen) |visited| visited[id] = true;
            const result: T = switch (@typeInfo(T)) {
                .optional => |o| result: {
                    const p = try c.byte();
                    if (p > 1) return error.InvalidBoolean;
                    if (p == 0) break :result null;
                    break :result try self.edge(o.child, id, &c, leaves, a, budget, depth, seen);
                },
                .pointer => |p| result: {
                    if (p.size == .one) {
                        budget.allocated = std.math.add(usize, budget.allocated, @sizeOf(p.child)) catch return error.AllocationLimit;
                        if (budget.allocated > self.limits.packet.max_allocation_bytes or budget.allocated > self.limits.max_expanded_allocation) return error.AllocationLimit;
                        const ptr = a.create(p.child) catch return error.OutOfMemory;
                        ptr.* = try self.edge(p.child, id, &c, leaves, a, budget, depth, seen);
                        break :result ptr;
                    }
                    if (p.size != .slice) return error.UnsupportedType;
                    const n = try c.length(self.limits.packet.max_slice_length);
                    budget.allocated = std.math.add(usize, budget.allocated, std.math.mul(usize, n, @sizeOf(p.child)) catch return error.AllocationLimit) catch return error.AllocationLimit;
                    if (budget.allocated > self.limits.packet.max_allocation_bytes or budget.allocated > self.limits.max_expanded_allocation) return error.AllocationLimit;
                    if (n > self.limits.max_work -| budget.work) return error.ExpandedWorkLimit;
                    const vals = a.alloc(p.child, n) catch return error.OutOfMemory;
                    for (vals) |*v| v.* = try self.edge(p.child, id, &c, leaves, a, budget, depth, seen);
                    break :result vals;
                },
                .array => result: {
                    var vals: T = undefined;
                    for (&vals) |*v| v.* = try self.edge(@typeInfo(T).array.child, id, &c, leaves, a, budget, depth, seen);
                    break :result vals;
                },
                .@"struct" => |s| result: {
                    var value: T = undefined;
                    const defaults = comptime packet.defaultCount(T);
                    const mask = if (defaults != 0) try c.varint() else 0;
                    if (defaults < 64 and mask >> @as(u6, @intCast(defaults)) != 0) return error.InvalidDefaultMask;
                    comptime var bit = 0;
                    inline for (s.fields) |f| {
                        const present = if (comptime defaults != 0 and packet.elidable(f)) present: {
                            const yes = mask & (@as(u64, 1) << bit) != 0;
                            bit += 1;
                            break :present yes;
                        } else true;
                        if (!present) @field(value, f.name) = packet.defaultValue(f) else {
                            @field(value, f.name) = try self.edge(f.type, id, &c, leaves, a, budget, depth, seen);
                            if (comptime defaults != 0 and packet.elidable(f)) if (packet.equalsDefault(f.type, @field(value, f.name), packet.defaultValue(f))) return error.NonCanonicalDefault;
                        }
                    }
                    break :result value;
                },
                .@"union" => |u| result: {
                    const tag = try c.varint();
                    inline for (u.fields, 0..) |f, ordinal| if (tag == ordinal) break :result @unionInit(T, f.name, try self.edge(f.type, id, &c, leaves, a, budget, depth, seen));
                    return error.InvalidUnionTag;
                },
                else => return error.UnsupportedType,
            };
            const declared_holes = try c.varint();
            if (declared_holes != budget.leaves - leaves_start) return error.InvalidNode;
            if (c.at != c.bytes.len) return error.TrailingBytes;
            return result;
        }
        pub fn decode(self: Self, allocator: std.mem.Allocator, i: usize) Error!packet.Decoded(Root) {
            return self.decodeSeen(allocator, i, null, null);
        }
        fn decodeSeen(self: Self, allocator: std.mem.Allocator, i: usize, seen: ?[]bool, report: ?*DecodeBudget) Error!packet.Decoded(Root) {
            const r = try self.root(i);
            var result = packet.Decoded(Root){ .arena = std.heap.ArenaAllocator.init(allocator), .value = undefined };
            errdefer result.arena.deinit();
            var leaves = Cursor{ .bytes = self.lane[@as(usize, r.lane_at)..][0..r.lane_len] };
            var budget = DecodeBudget{ .limits = self.limits, .root = r };
            result.value = try self.decodeNode(Root, r.shape, &leaves, result.arena.allocator(), &budget, 0, seen);
            if (leaves.at != leaves.bytes.len) return error.TrailingBytes;
            if (budget.leaves != r.leaves) return error.InvalidCheckpoint;
            if (report) |out| out.* = budget;
            return result;
        }
        pub fn prepare(self: Self, allocator: std.mem.Allocator, scope: lex.validate.Scope) Error!void {
            if (Root != lex.model.Entry and Root != lex.model.Resource) return error.SemanticAdmissionUnavailable;
            var identities: std.StringHashMapUnmanaged(void) = .empty;
            defer {
                var iter = identities.keyIterator();
                while (iter.next()) |key| allocator.free(key.*);
                identities.deinit(allocator);
            }
            for (0..self.count) |i| {
                var decoded = try self.decode(allocator, i);
                defer decoded.deinit();
                try lex.validate.check(allocator, &decoded.value, scope);
                const identity = if (Root == lex.model.Entry) decoded.value.id else decoded.value.identity();
                const owned = try allocator.dupe(u8, identity);
                const slot = identities.getOrPut(allocator, owned) catch |err| {
                    allocator.free(owned);
                    return err;
                };
                if (slot.found_existing) {
                    allocator.free(owned);
                    return error.DuplicateIdentity;
                }
            }
        }
        pub fn encodedShapeBytes(self: Self) usize {
            return self.shape_bytes.len;
        }
        pub fn encodedLiteralBytes(self: Self) usize {
            return self.lane.len;
        }
        pub fn shapeCount(self: Self) usize {
            return self.node_count;
        }
    };
}

pub fn open(comptime Root: type, allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) Error!Page(Root) {
    if (bytes.len > limits.max_page_bytes) return error.PageTooLarge;
    if (bytes.len < header_size or !std.mem.eql(u8, bytes[0..4], "LPS1") or bytes[4] != 1) return error.InvalidPage;
    if (bytes[5] != 0 or bytes[6] != 0 or bytes[7] != 0) return error.InvalidPage;
    if (std.mem.readInt(u64, bytes[24..32], .little) != comptime fingerprint(Root)) return error.InvalidSchema;
    var digest: [32]u8 = undefined;
    var hash = Sha256.init(.{});
    hash.update(bytes[0..32]);
    hash.update(bytes[64..]);
    hash.final(&digest);
    if (!std.crypto.timing_safe.eql([32]u8, digest, bytes[32..64].*)) return error.DigestMismatch;
    const count = getU32(bytes, 8);
    const nodes = getU32(bytes, 12);
    const shape_size = getU32(bytes, 16);
    const lane_size = getU32(bytes, 20);
    if (count > limits.max_roots) return error.TooManyRoots;
    if (nodes > limits.max_nodes) return error.TooManyNodes;
    const offsets_at = header_size;
    const offsets_size = std.math.mul(usize, nodes + 1, 4) catch return error.InvalidPage;
    const roots_at = std.math.add(usize, offsets_at, offsets_size) catch return error.InvalidPage;
    const roots_size = std.math.mul(usize, count, 20) catch return error.InvalidPage;
    const cp_at = std.math.add(usize, roots_at, roots_size) catch return error.InvalidPage;
    if (cp_at > bytes.len) return error.InvalidPage;
    var cp_count: usize = 0;
    for (0..count) |i| {
        const leaves: usize = getU32(bytes, roots_at + i * 20 + 16);
        cp_count = std.math.add(usize, cp_count, checkpointCount(leaves)) catch return error.InvalidPage;
    }
    const checkpoints_size = std.math.mul(usize, cp_count, 4) catch return error.InvalidPage;
    const shape_at = std.math.add(usize, cp_at, checkpoints_size) catch return error.InvalidPage;
    const lane_at = std.math.add(usize, shape_at, shape_size) catch return error.InvalidPage;
    if (lane_at > bytes.len or lane_size != bytes.len - lane_at) return error.InvalidPage;
    var page = Page(Root){ .bytes = bytes, .count = count, .node_count = nodes, .offsets = bytes[offsets_at..roots_at], .roots = bytes[roots_at..cp_at], .checkpoints = bytes[cp_at..shape_at], .shape_bytes = bytes[shape_at..lane_at], .lane = bytes[lane_at..], .limits = limits };
    if (getU32(page.offsets, 0) != 0 or getU32(page.offsets, nodes * 4) != shape_size) return error.InvalidPage;
    for (0..nodes) |i| if (getU32(page.offsets, i * 4) >= getU32(page.offsets, (i + 1) * 4)) return error.InvalidPage;
    // Validate exact lane partitions, checkpoint count and offsets. Full typed
    // controls and expected types are validated by decode below at admission.
    var last_lane: usize = 0;
    var last_cp: usize = 0;
    for (0..count) |i| {
        const r = try page.root(i);
        const ncp = checkpointCount(r.leaves);
        const lane_end = std.math.add(usize, r.lane_at, r.lane_len) catch return error.InvalidPage;
        const cp_end = std.math.add(usize, r.checkpoint_at, ncp) catch return error.InvalidPage;
        if (r.lane_at != last_lane or r.checkpoint_at != last_cp or lane_end > lane_size or cp_end > cp_count) return error.InvalidPage;
        for (0..ncp) |j| {
            const cp = getU32(page.checkpoints, (r.checkpoint_at + j) * 4);
            if (cp < r.lane_at or cp > lane_end or (j == 0 and cp != r.lane_at)) return error.InvalidCheckpoint;
        }
        last_lane = lane_end;
        last_cp = cp_end;
    }
    if (last_lane != lane_size or last_cp != cp_count) return error.InvalidPage;
    // Every record is a unique exact template. Root expansion validates its
    // controls, expected-type references and multiplicity; rejecting unused
    // records also prevents hidden unvalidated payloads.
    var unique: std.StringHashMapUnmanaged(void) = .empty;
    defer unique.deinit(allocator);
    for (0..nodes) |i| {
        const record = try page.record(i);
        if (record.len == 0) return error.InvalidNode;
        var cursor = Cursor{ .bytes = record };
        const type_id = try cursor.varint();
        var found = false;
        inline for (Schema(Root).types, 0..) |T, ordinal| if (comptime !inlineType(T) and !bytesType(T)) {
            if (type_id == ordinal) found = true;
        };
        if (!found) return error.TypeMismatch;
        const slot = try unique.getOrPut(allocator, record);
        if (slot.found_existing) return error.DuplicateNode;
    }
    const seen = try allocator.alloc(bool, nodes);
    defer allocator.free(seen);
    @memset(seen, false);
    var total_work: usize = 0;
    var total_allocated: usize = 0;
    for (0..count) |i| {
        var budget = DecodeBudget{ .limits = limits, .root = try page.root(i) };
        var decoded = try page.decodeSeen(allocator, i, seen, &budget);
        defer decoded.deinit();
        const packet_bytes = try packet.encode(allocator, decoded.value, limits.packet);
        defer allocator.free(packet_bytes);
        total_work = std.math.add(usize, total_work, budget.work) catch return error.ExpandedWorkLimit;
        total_allocated = std.math.add(usize, total_allocated, budget.allocated) catch return error.AllocationLimit;
        if (total_work > limits.max_work) return error.ExpandedWorkLimit;
        if (total_allocated > limits.max_expanded_allocation) return error.ExpandedAllocationLimit;
    }
    for (seen) |visited| if (!visited) return error.UnreachableNode;
    page.expanded_work = total_work;
    page.expanded_allocation = total_allocated;
    return page;
}
