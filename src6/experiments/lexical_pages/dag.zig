//! Experimental exact typed DAG pages, derived entirely from the public model.
//! Scalars stay inline. Strings/composite values are hash-consed by canonical
//! typed payload, never by semantic equivalence. Ordered incoming edges retain
//! every occurrence, duplicate, declaration, and identity. The full flat frame
//! is an alternative, so adaptive encoding never increases raw frame bytes.
//! This is an isolated page experiment, not a production archive version.
const std = @import("std");
const lex = @import("lex6");
const packet = lex.packet;
const packet_view = lex.packet_view;
const model = lex.model;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const header_size = 64;
pub const Strategy = enum { flat, shared, adaptive };
pub const Mode = enum(u8) { flat = 0, shared = 1 };
pub const Limits = struct {
    max_page_bytes: usize = 64 * 1024,
    max_nodes: usize = 65_535,
    max_roots: usize = 4096,
    max_physical_work: usize = 16 * 1024 * 1024,
    max_expanded_work: usize = 64 * 1024 * 1024,
    max_expanded_allocation: usize = 64 * 1024 * 1024,
    packet: packet.Limits = .{},
};
pub const Error = packet.Error || lex.validate.Error || error{
    InvalidPage,
    InvalidSchema,
    DigestMismatch,
    TypeMismatch,
    InvalidNode,
    InvalidReference,
    DuplicateNode,
    UnreachableNode,
    ExpandedWorkLimit,
    ExpandedAllocationLimit,
    PageTooLarge,
    TooManyNodes,
    TooManyRoots,
    WrongUnionTag,
    SemanticAdmissionUnavailable,
};

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
fn typeOrdinal(comptime Root: type, comptime T: type) u32 {
    inline for (Schema(Root).types, 0..) |P, i| if (P == T) return @intCast(i);
    @compileError("child type is not reachable from this root schema");
}
fn Schema(comptime Root: type) type {
    return struct {
        const types = typesReachable(Root, &.{});
    };
}
const Fingerprint = struct {
    value: u64 = 14695981039346656037,
    fn bytes(self: *Fingerprint, text: []const u8) void {
        for (text) |byte| {
            self.value = (self.value ^ byte) *% 1099511628211;
        }
    }
    fn number(self: *Fingerprint, value: u64) void {
        var encoded: [8]u8 = undefined;
        std.mem.writeInt(u64, &encoded, value, .little);
        self.bytes(&encoded);
    }
};
fn fingerprintDefault(comptime T: type, comptime value: T, state: *Fingerprint) void {
    switch (@typeInfo(T)) {
        .void => {},
        .bool => state.number(@intFromBool(value)),
        .int => |i| if (i.signedness == .signed) {
            state.number(@bitCast(@as(i64, value)));
        } else {
            state.number(value);
        },
        .@"enum" => state.bytes(@tagName(value)),
        .optional => state.number(@intFromBool(value != null)),
        .pointer => state.number(value.len),
        .array => |a| for (value) |child| fingerprintDefault(a.child, child, state),
        .@"struct" => |s| inline for (s.fields) |f| fingerprintDefault(f.type, @field(value, f.name), state),
        .@"union" => switch (value) {
            inline else => |child, tag| {
                state.bytes(@tagName(tag));
                fingerprintDefault(@TypeOf(child), child, state);
            },
        },
        else => @compileError("unsupported allocation-free default"),
    }
}
/// Stable descriptor of graph topology, field/tag order, scalar widths and
/// elidable defaults; excludes compiler type names, pointers and memory layout.
pub fn schemaFingerprint(comptime Root: type) u64 {
    @setEvalBranchQuota(500_000);
    var state = Fingerprint{};
    state.bytes("LPD1/schema/1/LXP6/3");
    inline for (Schema(Root).types) |T| {
        switch (@typeInfo(T)) {
            .void => state.number(0),
            .bool => state.number(1),
            .int => |i| {
                state.number(2);
                state.number(i.bits);
                state.number(@intFromBool(i.signedness == .signed));
            },
            .@"enum" => |e| {
                state.number(3);
                state.number(e.fields.len);
                inline for (e.fields) |f| {
                    state.bytes(f.name);
                    state.number(0);
                    state.number(@bitCast(@as(i64, f.value)));
                }
            },
            .optional => |o| {
                state.number(4);
                state.number(typeOrdinal(Root, o.child));
            },
            .pointer => |p| {
                state.number(5);
                state.number(@intFromEnum(p.size));
                state.number(@intFromBool(p.is_const));
                state.number(typeOrdinal(Root, p.child));
            },
            .array => |a| {
                state.number(6);
                state.number(a.len);
                state.number(typeOrdinal(Root, a.child));
            },
            .@"struct" => |s| {
                state.number(7);
                state.number(s.fields.len);
                state.number(packet.defaultCount(T));
                inline for (s.fields) |f| {
                    state.bytes(f.name);
                    state.number(0);
                    state.number(typeOrdinal(Root, f.type));
                    state.number(@intFromBool(packet.elidable(f)));
                    if (comptime packet.elidable(f)) fingerprintDefault(f.type, packet.defaultValue(f), &state);
                }
            },
            .@"union" => |u| {
                state.number(8);
                state.number(u.fields.len);
                inline for (u.fields) |f| {
                    state.bytes(f.name);
                    state.number(0);
                    state.number(typeOrdinal(Root, f.type));
                }
            },
            else => @compileError("unsupported schema type"),
        }
    }
    return state.value;
}

fn appendVarint(out: *std.ArrayList(u8), allocator: std.mem.Allocator, original: u64) Error!void {
    var value = original;
    while (value >= 128) {
        try out.append(allocator, @as(u8, @truncate(value)) | 128);
        value >>= 7;
    }
    try out.append(allocator, @intCast(value));
}
fn appendScalar(comptime T: type, out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: T) Error!void {
    switch (@typeInfo(T)) {
        .void => {},
        .bool => try out.append(allocator, @intFromBool(value)),
        .int => |i| {
            if (i.bits > 64) return error.UnsupportedType;
            const encoded: u64 = if (i.signedness == .signed) encoded: {
                const signed: i64 = value;
                break :encoded (@as(u64, @bitCast(signed)) << 1) ^ @as(u64, @bitCast(signed >> 63));
            } else value;
            try appendVarint(out, allocator, encoded);
        },
        .@"enum" => |e| inline for (e.fields, 0..) |f, i| {
            if (value == @field(T, f.name)) {
                try appendVarint(out, allocator, i);
                return;
            }
        },
        else => unreachable,
    }
}
const Cursor = struct {
    bytes: []const u8,
    at: usize = 0,
    fn byte(self: *Cursor) Error!u8 {
        if (self.at >= self.bytes.len) return error.Truncated;
        const result = self.bytes[self.at];
        self.at += 1;
        return result;
    }
    fn take(self: *Cursor, n: usize) Error![]const u8 {
        if (n > self.bytes.len - self.at) return error.Truncated;
        const result = self.bytes[self.at..][0..n];
        self.at += n;
        return result;
    }
    fn varint(self: *Cursor) Error!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        for (0..10) |i| {
            const b = try self.byte();
            if (i == 9 and b > 1) return error.IntegerOverflow;
            result |= @as(u64, b & 127) << shift;
            if (b & 128 == 0) {
                if (i != 0 and b == 0) return error.NonCanonicalVarint;
                return result;
            }
            if (i != 9) shift += 7;
        }
        return error.IntegerOverflow;
    }
    fn length(self: *Cursor, maximum: usize) Error!usize {
        const n = try self.varint();
        if (n > maximum) return error.SliceTooLong;
        return @intCast(n);
    }
};
fn scalar(comptime T: type, c: *Cursor) Error!T {
    return switch (@typeInfo(T)) {
        .void => {},
        .bool => switch (try c.byte()) {
            0 => false,
            1 => true,
            else => error.InvalidBoolean,
        },
        .int => |i| result: {
            if (i.bits > 64) return error.UnsupportedType;
            const value = try c.varint();
            const U = std.meta.Int(.unsigned, i.bits);
            if (value > std.math.maxInt(U)) return error.IntegerOverflow;
            const narrowed: U = @intCast(value);
            if (i.signedness == .signed) break :result @bitCast((narrowed >> 1) ^ (0 -% (narrowed & 1)));
            break :result @intCast(narrowed);
        },
        .@"enum" => |e| result: {
            const value = try c.varint();
            inline for (e.fields, 0..) |f, i| if (value == i) break :result @field(T, f.name);
            return error.InvalidEnum;
        },
        else => error.UnsupportedType,
    };
}

fn Encoder(comptime Root: type) type {
    return struct {
        allocator: std.mem.Allocator,
        limits: Limits,
        nodes: std.ArrayList([]const u8) = .empty,
        intern: std.StringHashMapUnmanaged(u32) = .empty,
        work: usize = 0,
        const Self = @This();
        fn edge(self: *Self, comptime T: type, value: T, out: *std.ArrayList(u8), depth: usize) Error!void {
            if (depth > self.limits.packet.max_depth) return error.DepthLimit;
            self.work += 1;
            if (self.work > self.limits.max_expanded_work) return error.ExpandedWorkLimit;
            if (comptime inlineType(T)) return appendScalar(T, out, self.allocator, value);
            try appendVarint(out, self.allocator, try self.node(T, value, depth));
        }
        fn node(self: *Self, comptime T: type, value: T, depth: usize) Error!u32 {
            @setEvalBranchQuota(500_000);
            var payload: std.ArrayList(u8) = .empty;
            try appendVarint(&payload, self.allocator, typeOrdinal(Root, T));
            if (comptime bytesType(T)) {
                try appendVarint(&payload, self.allocator, value.len);
                try payload.appendSlice(self.allocator, value);
            } else switch (@typeInfo(T)) {
                .optional => |o| {
                    try payload.append(self.allocator, @intFromBool(value != null));
                    if (value) |v| try self.edge(o.child, v, &payload, depth + 1);
                },
                .pointer => |p| if (p.size == .one) {
                    try self.edge(p.child, value.*, &payload, depth + 1);
                } else if (p.size == .slice) {
                    try appendVarint(&payload, self.allocator, value.len);
                    for (value) |v| try self.edge(p.child, v, &payload, depth + 1);
                } else return error.UnsupportedType,
                .array => |a| for (value) |v| try self.edge(a.child, v, &payload, depth + 1),
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
                        if (present) try self.edge(f.type, @field(value, f.name), &payload, depth + 1);
                    }
                },
                .@"union" => |u| {
                    if (u.tag_type == null) return error.UnsupportedType;
                    switch (value) {
                        inline else => |v, tag| {
                            inline for (u.fields, 0..) |f, i| if (comptime std.mem.eql(u8, f.name, @tagName(tag))) {
                                try appendVarint(&payload, self.allocator, i);
                            };
                            try self.edge(@TypeOf(v), v, &payload, depth + 1);
                        },
                    }
                },
                else => return error.UnsupportedType,
            }
            if (self.intern.get(payload.items)) |existing| {
                payload.deinit(self.allocator);
                return existing;
            }
            if (self.nodes.items.len >= self.limits.max_nodes or self.nodes.items.len >= std.math.maxInt(u32)) return error.TooManyNodes;
            const bytes = try payload.toOwnedSlice(self.allocator);
            const id: u32 = @intCast(self.nodes.items.len);
            try self.nodes.append(self.allocator, bytes);
            try self.intern.put(self.allocator, bytes, id);
            return id;
        }
    };
}
fn putU32(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, bytes[at..][0..4], @intCast(value), .little);
}
fn getU32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn seal(bytes: []u8) void {
    var state = Sha256.init(.{});
    state.update(bytes[0..32]);
    state.update(bytes[64..]);
    state.final(bytes[32..64]);
}
fn frame(comptime Root: type, allocator: std.mem.Allocator, mode: Mode, records: []const []const u8, roots: []const u32, limits: Limits) Error![]u8 {
    var payload_size: usize = 0;
    for (records) |r| payload_size = std.math.add(usize, payload_size, r.len) catch return error.PageTooLarge;
    const root_bytes = if (mode == .shared) roots.len * 4 else 0;
    const size = header_size + (records.len + 1) * 4 + root_bytes + payload_size;
    if (size > limits.max_page_bytes or size > std.math.maxInt(u32)) return error.PageTooLarge;
    const out = try allocator.alloc(u8, size);
    @memset(out, 0);
    @memcpy(out[0..4], "LPD1");
    out[4] = 1;
    out[5] = @intFromEnum(mode);
    putU32(out, 8, if (mode == .shared) roots.len else records.len);
    putU32(out, 12, records.len);
    putU32(out, 16, payload_size);
    std.mem.writeInt(u64, out[24..32], comptime schemaFingerprint(Root), .little);
    const payload_at = header_size + (records.len + 1) * 4 + root_bytes;
    var at: usize = 0;
    for (records, 0..) |r, i| {
        putU32(out, header_size + i * 4, at);
        @memcpy(out[payload_at + at ..][0..r.len], r);
        at += r.len;
    }
    putU32(out, header_size + records.len * 4, at);
    if (mode == .shared) for (roots, 0..) |root, i| putU32(out, header_size + (records.len + 1) * 4 + i * 4, root);
    seal(out);
    return out;
}
pub fn encodePage(comptime Root: type, allocator: std.mem.Allocator, values: []const Root, limits: Limits, strategy: Strategy) Error![]u8 {
    if (values.len > limits.max_roots) return error.TooManyRoots;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const flat_records = try scratch.alloc([]const u8, values.len);
    for (values, 0..) |value, i| flat_records[i] = try packet.encode(scratch, value, limits.packet);
    if (strategy == .flat) return frame(Root, allocator, .flat, flat_records, &.{}, limits);
    var encoder = Encoder(Root){ .allocator = scratch, .limits = limits };
    const roots = try scratch.alloc(u32, values.len);
    for (values, 0..) |value, i| {
        if (comptime inlineType(Root)) return error.UnsupportedType;
        encoder.work += 1;
        roots[i] = try encoder.node(Root, value, 0);
    }
    if (strategy == .shared) return frame(Root, allocator, .shared, encoder.nodes.items, roots, limits);
    const flat = try frame(Root, allocator, .flat, flat_records, &.{}, limits);
    errdefer allocator.free(flat);
    const shared = frame(Root, allocator, .shared, encoder.nodes.items, roots, limits) catch |err| {
        if (err == error.PageTooLarge) return flat;
        return err;
    };
    if (shared.len < flat.len) {
        allocator.free(flat);
        return shared;
    }
    allocator.free(shared);
    return flat;
}

const Cost = struct {
    work: usize = 1,
    allocation: usize = 0,
    depth: usize = 0,
    wire_bytes: usize = 0,
    fn add(self: *Cost, child: Cost, limits: Limits) Error!void {
        self.work = std.math.add(usize, self.work, child.work) catch return error.ExpandedWorkLimit;
        self.allocation = std.math.add(usize, self.allocation, child.allocation) catch return error.ExpandedAllocationLimit;
        self.wire_bytes = std.math.add(usize, self.wire_bytes, child.wire_bytes) catch return error.InputTooLarge;
        self.depth = @max(self.depth, child.depth + 1);
        if (self.work > limits.max_expanded_work) return error.ExpandedWorkLimit;
        if (self.allocation > limits.max_expanded_allocation) return error.ExpandedAllocationLimit;
        if (self.depth > limits.packet.max_depth) return error.DepthLimit;
    }
};

pub fn Page(comptime Root: type) type {
    return struct {
        bytes: []const u8,
        mode: Mode,
        count: usize,
        node_count: usize,
        offsets: []const u8,
        roots: []const u8,
        payload: []const u8,
        limits: Limits,
        expanded_work: usize = 0,
        expanded_allocation: usize = 0,
        const Self = @This();
        fn record(self: Self, id: usize) Error![]const u8 {
            if (id >= self.node_count) return error.InvalidNode;
            return self.payload[getU32(self.offsets, id * 4)..getU32(self.offsets, (id + 1) * 4)];
        }
        fn body(self: Self, id: u32, comptime T: type) Error![]const u8 {
            var c = Cursor{ .bytes = try self.record(id) };
            if (try c.varint() != typeOrdinal(Root, T)) return error.TypeMismatch;
            return c.bytes[c.at..];
        }
        pub fn rootId(self: Self, index: usize) Error!u32 {
            if (index >= self.count) return error.InvalidReference;
            return if (self.mode == .shared) getU32(self.roots, index * 4) else @intCast(index);
        }
        pub fn decode(self: Self, allocator: std.mem.Allocator, index: usize) Error!packet.Decoded(Root) {
            return self.decodeImpl(allocator, index, false);
        }
        fn decodeImpl(self: Self, allocator: std.mem.Allocator, index: usize, borrow: bool) Error!packet.Decoded(Root) {
            const id = try self.rootId(index);
            if (self.mode == .flat) {
                if (borrow) {
                    const result = try packet.decodeBorrowed(Root, allocator, try self.record(id), self.limits.packet);
                    return .{ .arena = result.arena, .value = result.value };
                }
                return packet.decode(Root, allocator, try self.record(id), self.limits.packet);
            }
            var result = packet.Decoded(Root){ .arena = std.heap.ArenaAllocator.init(allocator), .value = undefined };
            errdefer result.arena.deinit();
            result.value = try self.decodeNode(Root, id, result.arena.allocator(), borrow);
            return result;
        }
        fn decodeEdge(self: Self, comptime T: type, c: *Cursor, allocator: std.mem.Allocator, borrow: bool) Error!T {
            if (comptime inlineType(T)) return scalar(T, c);
            return self.decodeNode(T, @intCast(try c.varint()), allocator, borrow);
        }
        fn decodeNode(self: Self, comptime T: type, id: u32, allocator: std.mem.Allocator, borrow: bool) Error!T {
            @setEvalBranchQuota(500_000);
            var c = Cursor{ .bytes = try self.body(id, T) };
            if (comptime bytesType(T)) {
                const bytes = try c.take(try c.length(self.limits.packet.max_slice_length));
                if (comptime @typeInfo(T).pointer.is_const) {
                    if (borrow) return bytes;
                }
                return allocator.dupe(u8, bytes);
            }
            return switch (@typeInfo(T)) {
                .optional => |o| if (try c.byte() == 0) null else try self.decodeEdge(o.child, &c, allocator, borrow),
                .pointer => |p| result: {
                    if (p.size == .one) {
                        const value = try allocator.create(p.child);
                        value.* = try self.decodeEdge(p.child, &c, allocator, borrow);
                        break :result value;
                    }
                    if (p.size != .slice) return error.UnsupportedType;
                    const values = try allocator.alloc(p.child, try c.length(self.limits.packet.max_slice_length));
                    for (values) |*value| value.* = try self.decodeEdge(p.child, &c, allocator, borrow);
                    break :result values;
                },
                .array => result: {
                    var values: T = undefined;
                    for (&values) |*value| value.* = try self.decodeEdge(@typeInfo(T).array.child, &c, allocator, borrow);
                    break :result values;
                },
                .@"struct" => |s| result: {
                    var value: T = undefined;
                    const defaults = comptime packet.defaultCount(T);
                    const mask = if (defaults != 0) try c.varint() else 0;
                    comptime var bit = 0;
                    inline for (s.fields) |f| {
                        const present = if (comptime defaults != 0 and packet.elidable(f)) present: {
                            const p = mask & (@as(u64, 1) << bit) != 0;
                            bit += 1;
                            break :present p;
                        } else true;
                        @field(value, f.name) = if (present) try self.decodeEdge(f.type, &c, allocator, borrow) else packet.defaultValue(f);
                    }
                    break :result value;
                },
                .@"union" => |u| result: {
                    const ordinal = try c.varint();
                    inline for (u.fields, 0..) |f, i| if (ordinal == i) break :result @unionInit(T, f.name, try self.decodeEdge(f.type, &c, allocator, borrow));
                    return error.InvalidUnionTag;
                },
                else => error.UnsupportedType,
            };
        }
        /// Complete structural scan already bounds multiplicity, depth and
        /// allocations. Semantic admission expands every occurrence, so sharing
        /// never hides duplicate identities or language/evidence declarations.
        pub fn prepare(self: Self, allocator: std.mem.Allocator, scope: lex.validate.Scope) Error!PreparedPage(Root) {
            var identities: std.StringHashMapUnmanaged(void) = .empty;
            defer {
                var it = identities.keyIterator();
                while (it.next()) |key| allocator.free(key.*);
                identities.deinit(allocator);
            }
            for (0..self.count) |i| {
                var value = try self.decodeImpl(allocator, i, true);
                defer value.deinit();
                const identity = if (Root == model.Entry) value.value.id else if (Root == model.Resource) value.value.identity() else return error.SemanticAdmissionUnavailable;
                try lex.validate.check(allocator, &value.value, scope);
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
            return .{ .page = self };
        }
        /// Structural view only; this does not assert lexical semantic validity.
        pub fn view(self: Self, index: usize) Error!View(Root, Root) {
            return self.viewImpl(index, false);
        }
        fn viewImpl(self: Self, index: usize, prepared: bool) Error!View(Root, Root) {
            const id = try self.rootId(index);
            return .{ .page = self, .backing = if (self.mode == .shared) .{ .node = id } else .{ .flat = if (prepared) try packet_view.fromVerifiedDocument(Root, try self.record(id), self.limits.packet) else try packet_view.open(Root, try self.record(id), self.limits.packet) } };
        }
    };
}
pub fn PreparedPage(comptime Root: type) type {
    return struct {
        /// A non-owning immutable-byte contract, not an unforgeable proof token.
        page: Page(Root),
        pub fn view(self: @This(), index: usize) Error!View(Root, Root) {
            return self.page.viewImpl(index, true);
        }
    };
}

fn Validator(comptime Root: type) type {
    return struct {
        page: Page(Root),
        costs: []Cost,
        incoming: []u32,
        physical_work: usize = 0,
        const Self = @This();
        fn charge(self: *Self, n: usize) Error!void {
            self.physical_work = std.math.add(usize, self.physical_work, n) catch return error.WorkLimit;
            if (self.physical_work > self.page.limits.max_physical_work) return error.WorkLimit;
        }
        fn edge(self: *Self, comptime T: type, c: *Cursor, parent: u32) Error!Cost {
            try self.charge(1);
            if (comptime inlineType(T)) {
                const start = c.at;
                _ = try scalar(T, c);
                return .{ .wire_bytes = c.at - start };
            }
            const id = try c.varint();
            if (id >= parent) return error.InvalidReference;
            _ = try self.page.body(@intCast(id), T);
            self.incoming[@intCast(id)] = std.math.add(u32, self.incoming[@intCast(id)], 1) catch return error.WorkLimit;
            return self.costs[@intCast(id)];
        }
        fn equalEdge(self: *Self, comptime T: type, c: *Cursor, comptime expected: T) Error!bool {
            try self.charge(1);
            if (comptime inlineType(T)) return packet.equalsDefault(T, try scalar(T, c), expected);
            const id = try c.varint();
            var child = Cursor{ .bytes = try self.page.body(@intCast(id), T) };
            return self.equalNode(T, &child, expected);
        }
        fn equalNode(self: *Self, comptime T: type, c: *Cursor, comptime expected: T) Error!bool {
            try self.charge(1);
            if (comptime bytesType(T)) {
                const n = try c.length(self.page.limits.packet.max_slice_length);
                _ = try c.take(n);
                return n == 0;
            }
            return switch (@typeInfo(T)) {
                .optional => try c.byte() == 0,
                .pointer => |p| if (p.size == .slice) try c.length(self.page.limits.packet.max_slice_length) == 0 else false,
                .array => |a| result: {
                    inline for (0..a.len) |i| if (!try self.equalEdge(a.child, c, expected[i])) break :result false;
                    break :result true;
                },
                .@"struct" => |s| result: {
                    const defaults = comptime packet.defaultCount(T);
                    const mask = if (defaults != 0) try c.varint() else 0;
                    comptime var bit = 0;
                    inline for (s.fields) |f| {
                        const present = if (comptime defaults != 0 and packet.elidable(f)) present: {
                            const p = mask & (@as(u64, 1) << bit) != 0;
                            bit += 1;
                            break :present p;
                        } else true;
                        if (!present) {
                            if (comptime !packet.equalsDefault(f.type, packet.defaultValue(f), @field(expected, f.name))) break :result false;
                        } else if (!try self.equalEdge(f.type, c, @field(expected, f.name))) break :result false;
                    }
                    break :result true;
                },
                .@"union" => |u| result: {
                    const ordinal = try c.varint();
                    inline for (u.fields, 0..) |f, i| {
                        if (ordinal == i) {
                            if (comptime std.mem.eql(u8, f.name, @tagName(std.meta.activeTag(expected)))) break :result try self.equalEdge(f.type, c, @field(expected, f.name));
                            break :result false;
                        }
                    }
                    return error.InvalidUnionTag;
                },
                else => false,
            };
        }
        fn node(self: *Self, comptime T: type, id: u32) Error!Cost {
            @setEvalBranchQuota(500_000);
            try self.charge(1);
            var cost = Cost{};
            var c = Cursor{ .bytes = try self.page.body(id, T) };
            if (comptime bytesType(T)) {
                const n = try c.length(self.page.limits.packet.max_slice_length);
                _ = try c.take(n);
                try self.charge(n);
                cost.work += n;
                cost.allocation = n;
                cost.wire_bytes = c.at;
            } else switch (@typeInfo(T)) {
                .optional => |o| {
                    const present = try c.byte();
                    cost.wire_bytes = 1;
                    if (present > 1) return error.InvalidBoolean;
                    if (present == 1) try cost.add(try self.edge(o.child, &c, id), self.page.limits);
                },
                .pointer => |p| if (p.size == .one) {
                    cost.allocation = @sizeOf(p.child);
                    try cost.add(try self.edge(p.child, &c, id), self.page.limits);
                } else if (p.size == .slice) {
                    const n = try c.length(self.page.limits.packet.max_slice_length);
                    cost.wire_bytes = c.at;
                    if (n > self.page.limits.max_physical_work - self.physical_work) return error.WorkLimit;
                    cost.allocation = std.math.mul(usize, n, @sizeOf(p.child)) catch return error.ExpandedAllocationLimit;
                    for (0..n) |_| try cost.add(try self.edge(p.child, &c, id), self.page.limits);
                } else return error.UnsupportedType,
                .array => |a| for (0..a.len) |_| try cost.add(try self.edge(a.child, &c, id), self.page.limits),
                .@"struct" => |s| {
                    const defaults = comptime packet.defaultCount(T);
                    const mask = if (defaults != 0) try c.varint() else 0;
                    cost.wire_bytes = c.at;
                    if (defaults < 64 and mask >> @as(u6, @intCast(defaults)) != 0) return error.InvalidDefaultMask;
                    comptime var bit = 0;
                    inline for (s.fields) |f| {
                        const present = if (comptime defaults != 0 and packet.elidable(f)) present: {
                            const p = mask & (@as(u64, 1) << bit) != 0;
                            bit += 1;
                            break :present p;
                        } else true;
                        if (present) {
                            const start = c.at;
                            try cost.add(try self.edge(f.type, &c, id), self.page.limits);
                            if (comptime defaults != 0 and packet.elidable(f)) {
                                var comparison = Cursor{ .bytes = c.bytes, .at = start };
                                if (try self.equalEdge(f.type, &comparison, packet.defaultValue(f))) return error.NonCanonicalDefault;
                            }
                        }
                    }
                },
                .@"union" => |u| {
                    const ordinal = try c.varint();
                    cost.wire_bytes = c.at;
                    if (ordinal >= u.fields.len) return error.InvalidUnionTag;
                    inline for (u.fields, 0..) |f, i| if (ordinal == i) {
                        try cost.add(try self.edge(f.type, &c, id), self.page.limits);
                    };
                },
                else => return error.UnsupportedType,
            }
            if (c.at != c.bytes.len) return error.TrailingBytes;
            if (cost.work > self.page.limits.max_expanded_work) return error.ExpandedWorkLimit;
            if (cost.allocation > self.page.limits.max_expanded_allocation) return error.ExpandedAllocationLimit;
            return cost;
        }
    };
}
pub fn open(comptime Root: type, allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) Error!Page(Root) {
    @setEvalBranchQuota(500_000);
    if (bytes.len > limits.max_page_bytes) return error.PageTooLarge;
    if (bytes.len < header_size or !std.mem.eql(u8, bytes[0..4], "LPD1") or bytes[4] != 1) return error.InvalidPage;
    const mode = std.enums.fromInt(Mode, bytes[5]) orelse return error.InvalidPage;
    if (!std.mem.eql(u8, bytes[6..8], &.{ 0, 0 }) or getU32(bytes, 20) != 0) return error.InvalidPage;
    if (std.mem.readInt(u64, bytes[24..32], .little) != comptime schemaFingerprint(Root)) return error.InvalidSchema;
    var digest: [32]u8 = undefined;
    var hash = Sha256.init(.{});
    hash.update(bytes[0..32]);
    hash.update(bytes[64..]);
    hash.final(&digest);
    if (!std.crypto.timing_safe.eql([32]u8, digest, bytes[32..64].*)) return error.DigestMismatch;
    const count: usize = getU32(bytes, 8);
    const node_count: usize = getU32(bytes, 12);
    const payload_size: usize = getU32(bytes, 16);
    if (count > limits.max_roots) return error.TooManyRoots;
    if (node_count > limits.max_nodes) return error.TooManyNodes;
    if (node_count >= (bytes.len - header_size) / 4) return error.InvalidPage;
    const offsets_end = header_size + (node_count + 1) * 4;
    if (mode == .shared and count > (bytes.len - offsets_end) / 4) return error.InvalidPage;
    const roots_end = offsets_end + if (mode == .shared) count * 4 else @as(usize, 0);
    if (roots_end > bytes.len or payload_size != bytes.len - roots_end or (mode == .flat and node_count != count)) return error.InvalidPage;
    var page = Page(Root){ .bytes = bytes, .mode = mode, .count = count, .node_count = node_count, .offsets = bytes[header_size..offsets_end], .roots = bytes[offsets_end..roots_end], .payload = bytes[roots_end..], .limits = limits };
    if (getU32(page.offsets, 0) != 0 or getU32(page.offsets, node_count * 4) != payload_size) return error.InvalidPage;
    for (0..node_count) |i| if (getU32(page.offsets, i * 4) >= getU32(page.offsets, (i + 1) * 4)) return error.InvalidPage;
    if (mode == .flat) {
        for (0..count) |i| {
            const view = try packet_view.open(Root, try page.record(i), limits.packet);
            page.expanded_work = std.math.add(usize, page.expanded_work, view.scannedWork()) catch return error.ExpandedWorkLimit;
            if (page.expanded_work > limits.max_expanded_work) return error.ExpandedWorkLimit;
        }
        return page;
    }
    const costs = try allocator.alloc(Cost, node_count);
    defer allocator.free(costs);
    const incoming = try allocator.alloc(u32, node_count);
    defer allocator.free(incoming);
    @memset(incoming, 0);
    var unique: std.StringHashMapUnmanaged(void) = .empty;
    defer unique.deinit(allocator);
    var validator = Validator(Root){ .page = page, .costs = costs, .incoming = incoming };
    for (0..node_count) |i| {
        const record = try page.record(i);
        var c = Cursor{ .bytes = record };
        const type_id = try c.varint();
        var found = false;
        inline for (Schema(Root).types, 0..) |T, ordinal| if (comptime !inlineType(T)) {
            if (type_id == ordinal) {
                costs[i] = try validator.node(T, @intCast(i));
                found = true;
            }
        };
        if (!found) return error.TypeMismatch;
        const slot = try unique.getOrPut(allocator, record);
        if (slot.found_existing) return error.DuplicateNode;
    }
    var total = Cost{ .work = 0 };
    for (0..count) |i| {
        const root = try page.rootId(i);
        _ = try page.body(root, Root);
        incoming[root] = std.math.add(u32, incoming[root], 1) catch return error.WorkLimit;
        const cost = costs[root];
        if (cost.work > limits.packet.max_work) return error.WorkLimit;
        if (cost.allocation > limits.packet.max_allocation_bytes) return error.AllocationLimit;
        if (cost.wire_bytes > limits.packet.max_input_bytes or limits.packet.max_input_bytes - cost.wire_bytes < 5) return error.InputTooLarge;
        total.work = std.math.add(usize, total.work, cost.work) catch return error.ExpandedWorkLimit;
        total.allocation = std.math.add(usize, total.allocation, cost.allocation) catch return error.ExpandedAllocationLimit;
        if (total.work > limits.max_expanded_work) return error.ExpandedWorkLimit;
        if (total.allocation > limits.max_expanded_allocation) return error.ExpandedAllocationLimit;
    }
    for (incoming) |n| if (n == 0) return error.UnreachableNode;
    page.expanded_work = total.work;
    page.expanded_allocation = total.allocation;
    return page;
}

fn fieldType(comptime T: type, comptime name: anytype) type {
    return @FieldType(T, if (@typeInfo(@TypeOf(name)) == .enum_literal) @tagName(name) else name);
}
fn elementType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        .array => |a| a.child,
        else => @compileError("values requires a collection"),
    };
}
pub fn View(comptime Root: type, comptime T: type) type {
    return struct {
        page: Page(Root),
        backing: union(enum) { node: u32, inline_bytes: []const u8, native: *const T, flat: packet_view.View(T) },
        const Self = @This();
        pub const Value = T;
        fn cursor(self: Self) Error!Cursor {
            return switch (self.backing) {
                .node => |id| .{ .bytes = try self.page.body(id, T) },
                .inline_bytes => |b| .{ .bytes = b },
                else => error.UnsupportedType,
            };
        }
        fn edge(self: Self, comptime C: type, c: *Cursor) Error!View(Root, C) {
            if (comptime inlineType(C)) {
                const start = c.at;
                _ = try scalar(C, c);
                return .{ .page = self.page, .backing = .{ .inline_bytes = c.bytes[start..c.at] } };
            }
            return .{ .page = self.page, .backing = .{ .node = @intCast(try c.varint()) } };
        }
        fn skip(comptime C: type, c: *Cursor) Error!void {
            if (comptime inlineType(C)) {
                _ = try scalar(C, c);
            } else {
                _ = try c.varint();
            }
        }
        pub fn field(self: Self, comptime name: anytype) Error!View(Root, fieldType(T, name)) {
            const selected = comptime if (@typeInfo(@TypeOf(name)) == .enum_literal) @tagName(name) else name;
            const C = fieldType(T, name);
            switch (self.backing) {
                .native => |p| return .{ .page = self.page, .backing = .{ .native = &@field(p.*, selected) } },
                .flat => |f| return .{ .page = self.page, .backing = .{ .flat = try f.field(name) } },
                else => {},
            }
            var c = try self.cursor();
            const defaults = comptime packet.defaultCount(T);
            const mask = if (defaults != 0) try c.varint() else 0;
            comptime var bit = 0;
            inline for (@typeInfo(T).@"struct".fields) |f| {
                const present = if (comptime defaults != 0 and packet.elidable(f)) present: {
                    const p = mask & (@as(u64, 1) << bit) != 0;
                    bit += 1;
                    break :present p;
                } else true;
                if (comptime std.mem.eql(u8, selected, f.name)) {
                    if (!present) return .{ .page = self.page, .backing = .{ .native = @ptrCast(@alignCast(f.default_value_ptr.?)) } };
                    return self.edge(C, &c);
                }
                if (present) try skip(f.type, &c);
            }
            unreachable;
        }
        pub fn text(self: Self) Error![]const u8 {
            if (comptime !bytesType(T)) @compileError("text requires byte slices");
            switch (self.backing) {
                .native => |p| return p.*,
                .flat => |f| return f.text(),
                else => {},
            }
            var c = try self.cursor();
            return c.take(try c.length(self.page.limits.packet.max_slice_length));
        }
        pub fn scalarValue(self: Self) Error!T {
            switch (self.backing) {
                .native => |p| return p.*,
                .flat => |f| return f.scalar(),
                else => {},
            }
            var c = try self.cursor();
            return scalar(T, &c);
        }
        pub fn tag(self: Self) Error!std.meta.Tag(T) {
            switch (self.backing) {
                .native => |p| return std.meta.activeTag(p.*),
                .flat => |f| return f.tag(),
                else => {},
            }
            var c = try self.cursor();
            const n = try c.varint();
            inline for (@typeInfo(T).@"union".fields, 0..) |f, i| if (n == i) return @field(std.meta.Tag(T), f.name);
            return error.InvalidUnionTag;
        }
        pub fn payload(self: Self, comptime selected: std.meta.Tag(T)) Error!View(Root, @FieldType(T, @tagName(selected))) {
            const C = @FieldType(T, @tagName(selected));
            switch (self.backing) {
                .native => |p| {
                    if (std.meta.activeTag(p.*) != selected) return error.WrongUnionTag;
                    return .{ .page = self.page, .backing = .{ .native = &@field(p.*, @tagName(selected)) } };
                },
                .flat => |f| return .{ .page = self.page, .backing = .{ .flat = try f.payload(selected) } },
                else => {},
            }
            var c = try self.cursor();
            const n = try c.varint();
            inline for (@typeInfo(T).@"union".fields, 0..) |f, i| if (comptime std.mem.eql(u8, f.name, @tagName(selected))) {
                if (n != i) return error.WrongUnionTag;
                return self.edge(C, &c);
            };
            unreachable;
        }
        pub fn optional(self: Self) Error!?View(Root, @typeInfo(T).optional.child) {
            const C = @typeInfo(T).optional.child;
            switch (self.backing) {
                .native => |p| {
                    if (p.*) |*v| return .{ .page = self.page, .backing = .{ .native = v } };
                    return null;
                },
                .flat => |f| {
                    if (try f.optional()) |v| return .{ .page = self.page, .backing = .{ .flat = v } };
                    return null;
                },
                else => {},
            }
            var c = try self.cursor();
            if (try c.byte() == 0) return null;
            return try self.edge(C, &c);
        }
        pub fn pointee(self: Self) Error!View(Root, @typeInfo(T).pointer.child) {
            const C = @typeInfo(T).pointer.child;
            switch (self.backing) {
                .native => |p| return .{ .page = self.page, .backing = .{ .native = p.* } },
                .flat => |f| return .{ .page = self.page, .backing = .{ .flat = try f.pointee() } },
                else => {},
            }
            var c = try self.cursor();
            return self.edge(C, &c);
        }
        pub fn values(self: Self) Error!Iterator(Root, T) {
            if (comptime bytesType(T)) @compileError("use text for byte strings");
            switch (self.backing) {
                .native => |p| return .{ .view = self, .backing = .{ .native = p } },
                .flat => |f| return .{ .view = self, .backing = .{ .flat = try f.values() } },
                else => {},
            }
            var c = try self.cursor();
            const n = switch (@typeInfo(T)) {
                .pointer => try c.length(self.page.limits.packet.max_slice_length),
                .array => |a| a.len,
                else => @compileError("values requires a collection"),
            };
            return .{ .view = self, .backing = .{ .wire = .{ .cursor = c, .remaining = n } } };
        }
        pub fn decodeOwned(self: Self, allocator: std.mem.Allocator) Error!packet.Decoded(T) {
            if (self.backing == .flat) return self.backing.flat.decodeOwned(allocator);
            if (self.backing == .native) {
                const bytes = try packet.encode(allocator, self.backing.native.*, self.page.limits.packet);
                defer allocator.free(bytes);
                return packet.decode(T, allocator, bytes, self.page.limits.packet);
            }
            var result = packet.Decoded(T){ .arena = std.heap.ArenaAllocator.init(allocator), .value = undefined };
            errdefer result.arena.deinit();
            if (self.backing == .node) result.value = try self.page.decodeNode(T, self.backing.node, result.arena.allocator(), false) else {
                var c = try self.cursor();
                result.value = try scalar(T, &c);
            }
            return result;
        }
    };
}
pub fn Iterator(comptime Root: type, comptime T: type) type {
    return struct {
        view: View(Root, T),
        backing: union(enum) { native: *const T, flat: packet_view.Iterator(T), wire: struct { cursor: Cursor, remaining: usize } },
        index: usize = 0,
        pub const Element = elementType(T);
        pub fn next(self: *@This()) Error!?View(Root, Element) {
            switch (self.backing) {
                .native => |p| {
                    if (self.index >= p.len) return null;
                    const value = &p.*[self.index];
                    self.index += 1;
                    return .{ .page = self.view.page, .backing = .{ .native = value } };
                },
                .flat => |*f| {
                    if (try f.next()) |v| return .{ .page = self.view.page, .backing = .{ .flat = v } };
                    return null;
                },
                .wire => |*w| {
                    if (w.remaining == 0) return null;
                    w.remaining -= 1;
                    return try self.view.edge(Element, &w.cursor);
                },
            }
        }
    };
}
