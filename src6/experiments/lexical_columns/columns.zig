//! Reflected canonical packet skeletons with root byte-field and size lanes.
//! Every literal occurrence is stored once in original traversal order in its
//! lane. Root checkpoints permit skipping arbitrary subtrees by reading only
//! schema integers; skipping never reads the literal channels.
const std = @import("std");
const lex = @import("lex6");
const packet = lex.packet;
const dag = @import("dag");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const header_size = 64;
pub const Limits = struct {
    max_page_bytes: usize = 1024 * 1024,
    max_roots: usize = 4096,
    packet: packet.Limits = .{},
};
pub const Error = packet.Error || lex.validate.Error || error{
    InvalidPage,
    InvalidSchema,
    DigestMismatch,
    InvalidCheckpoint,
    WrongUnionTag,
    PageTooLarge,
    TooManyRoots,
    InvalidReference,
    SemanticAdmissionUnavailable,
    LaneNotLoaded,
};
fn isBytes(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child == u8,
        else => false,
    };
}
pub fn laneCount(comptime Root: type) usize {
    var count: usize = 2;
    switch (@typeInfo(Root)) {
        .@"struct" => |s| {
            inline for (s.fields) |f| {
                if (comptime isBytes(f.type)) count += 1;
            }
        },
        else => {},
    }
    return count;
}
fn rootFieldLane(comptime Root: type, comptime name: []const u8) ?usize {
    var lane: usize = 2;
    switch (@typeInfo(Root)) {
        .@"struct" => |s| {
            inline for (s.fields) |f| {
                if (comptime isBytes(f.type)) {
                    if (std.mem.eql(u8, f.name, name)) return lane;
                    lane += 1;
                }
            }
        },
        else => {},
    }
    return null;
}
fn fieldLane(comptime Root: type, comptime T: type, comptime field: std.builtin.Type.StructField, at_root: bool, threshold: u16) ?usize {
    if (at_root) {
        if (comptime rootFieldLane(Root, field.name)) |lane| return lane;
    }
    if (threshold == 65535) {
        if (comptime @typeInfo(field.type) == .optional and isBytes(@typeInfo(field.type).optional.child)) return 0;
    }
    _ = T;
    return null;
}
fn selectedLane(length: usize, root_lane: ?usize, threshold: u16) usize {
    return root_lane orelse if (threshold == 65535 or (threshold != 0 and length >= threshold)) @as(usize, 1) else 0;
}
fn get32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn put32(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, bytes[at..][0..4], @intCast(value), .little);
}
fn digest(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    var hash = Sha256.init(.{});
    hash.update(bytes[0..32]);
    hash.update(bytes[64..]);
    hash.final(&result);
    return result;
}

fn Source(comptime Root: type) type {
    return struct {
        allocator: std.mem.Allocator,
        input: []const u8 = &.{},
        at: usize = 0,
        skeleton: std.ArrayList(u8) = .empty,
        lanes: [laneCount(Root)]std.ArrayList(u8) = @splat(.empty),
        threshold: u16,
        fn take(self: *@This(), len: usize) Error![]const u8 {
            if (len > self.input.len - self.at) return error.Truncated;
            const b = self.input[self.at..][0..len];
            self.at += len;
            return b;
        }
        fn byte(self: *@This()) Error!u8 {
            return (try self.take(1))[0];
        }
        fn varint(self: *@This()) Error!u64 {
            const start = self.at;
            var v: u64 = 0;
            for (0..10) |i| {
                const b = try self.byte();
                if (i == 9 and b > 1) return error.IntegerOverflow;
                v |= @as(u64, b & 127) << @as(u6, @intCast(i * 7));
                if (b < 128) {
                    if (i != 0 and b == 0) return error.NonCanonicalVarint;
                    try self.skeleton.appendSlice(self.allocator, self.input[start..self.at]);
                    return v;
                }
            }
            return error.IntegerOverflow;
        }
        fn marker(self: *@This()) Error!u8 {
            const b = try self.byte();
            try self.skeleton.append(self.allocator, b);
            return b;
        }
    };
}
fn strip(comptime Root: type, comptime T: type, source: *Source(Root), root_lane: ?usize, depth: usize) Error!void {
    @setEvalBranchQuota(500_000);
    if (depth > 128) return error.DepthLimit;
    if (comptime isBytes(T)) {
        const length = try source.varint();
        try source.lanes[selectedLane(@intCast(length), root_lane, source.threshold)].appendSlice(source.allocator, try source.take(@intCast(length)));
        return;
    }
    switch (@typeInfo(T)) {
        .void => {},
        .bool => {
            _ = try source.marker();
        },
        .int, .@"enum" => {
            _ = try source.varint();
        },
        .optional => |o| {
            if (try source.marker() != 0) try strip(Root, o.child, source, root_lane, depth + 1);
        },
        .pointer => |p| {
            if (p.size == .one) return strip(Root, p.child, source, root_lane, depth + 1);
            if (p.size != .slice) return error.UnsupportedType;
            const count = try source.varint();
            for (0..@intCast(count)) |_| try strip(Root, p.child, source, root_lane, depth + 1);
        },
        .array => |a| for (0..a.len) |_| try strip(Root, a.child, source, root_lane, depth + 1),
        .@"struct" => |s| {
            const defaults = comptime packet.defaultCount(T);
            const mask = if (defaults != 0) try source.varint() else 0;
            comptime var bit = 0;
            inline for (s.fields) |f| {
                const present = if (comptime defaults != 0 and packet.elidable(f)) present: {
                    const result = mask & (@as(u64, 1) << bit) != 0;
                    bit += 1;
                    break :present result;
                } else true;
                if (present) try strip(Root, f.type, source, fieldLane(Root, T, f, depth == 0, source.threshold), depth + 1);
            }
        },
        .@"union" => |u| {
            const tag = try source.varint();
            inline for (u.fields, 0..) |f, ordinal| {
                if (tag == ordinal) {
                    try strip(Root, f.type, source, root_lane, depth + 1);
                    return;
                }
            }
            return error.InvalidUnionTag;
        },
        else => return error.UnsupportedType,
    }
}

/// Inputs are canonical v3 packets of Root, checked before any transformation.
pub fn encodePackets(comptime Root: type, allocator: std.mem.Allocator, packets: []const []const u8, threshold: u16, limits: Limits) Error![]u8 {
    if (packets.len > limits.max_roots) return error.TooManyRoots;
    const n = comptime laneCount(Root);
    var exact_size = std.math.mul(usize, packets.len + 1, (n + 1) * 4) catch return error.PageTooLarge;
    exact_size = std.math.add(usize, exact_size, header_size + n * 4) catch return error.PageTooLarge;
    for (packets) |bytes| {
        if (bytes.len < 5) return error.Truncated;
        exact_size = std.math.add(usize, exact_size, bytes.len - 5) catch return error.PageTooLarge;
    }
    if (exact_size > limits.max_page_bytes) return error.PageTooLarge;
    var source = Source(Root){ .allocator = allocator, .threshold = threshold };
    defer {
        source.skeleton.deinit(allocator);
        for (&source.lanes) |*lane| lane.deinit(allocator);
    }
    const offsets = try allocator.alloc(u32, packets.len + 1);
    defer allocator.free(offsets);
    const checkpoints = try allocator.alloc([n]u32, packets.len + 1);
    defer allocator.free(checkpoints);
    for (packets, 0..) |bytes, i| {
        _ = try lex.packet_view.open(Root, bytes, limits.packet);
        if (bytes[4] != 3) return error.UnsupportedVersion;
        offsets[i] = @intCast(source.skeleton.items.len);
        for (source.lanes, &checkpoints[i]) |lane, *checkpoint| checkpoint.* = @intCast(lane.items.len);
        source.input = bytes;
        source.at = 5;
        try strip(Root, Root, &source, null, 0);
        if (source.at != bytes.len) return error.TrailingBytes;
    }
    offsets[packets.len] = @intCast(source.skeleton.items.len);
    for (source.lanes, &checkpoints[packets.len]) |lane, *checkpoint| checkpoint.* = @intCast(lane.items.len);
    const structure_at = header_size + (packets.len + 1) * (n + 1) * 4 + n * 4;
    var total = structure_at + source.skeleton.items.len;
    for (source.lanes) |lane| total += lane.items.len;
    if (total > limits.max_page_bytes) return error.PageTooLarge;
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    @memset(out[0..structure_at], 0);
    @memcpy(out[0..4], "LPC1");
    out[4] = 1;
    out[5] = 3;
    std.mem.writeInt(u16, out[6..8], threshold, .little);
    put32(out, 8, packets.len);
    put32(out, 12, n);
    put32(out, 16, source.skeleton.items.len);
    put32(out, 20, total);
    std.mem.writeInt(u64, out[24..32], comptime dag.schemaFingerprint(Root), .little);
    for (offsets, 0..) |offset, i| put32(out, header_size + i * 4, offset);
    const cp_at = header_size + offsets.len * 4;
    for (checkpoints, 0..) |cp, i| {
        for (cp, 0..) |value, lane| put32(out, cp_at + (i * n + lane) * 4, value);
    }
    const lengths_at = cp_at + checkpoints.len * n * 4;
    for (source.lanes, 0..) |lane, i| put32(out, lengths_at + i * 4, lane.items.len);
    @memcpy(out[structure_at..][0..source.skeleton.items.len], source.skeleton.items);
    var at = structure_at + source.skeleton.items.len;
    for (source.lanes) |lane| {
        @memcpy(out[at..][0..lane.items.len], lane.items);
        at += lane.items.len;
    }
    @memcpy(out[32..64], &digest(out));
    return out;
}

fn Cursor(comptime Root: type) type {
    return struct {
        skeleton: []const u8,
        at: usize = 0,
        lane_at: [laneCount(Root)]usize,
        work: usize = 0,
        limits: packet.Limits,
        threshold: u16,
        fn step(self: *@This(), depth: usize) Error!void {
            if (depth > self.limits.max_depth) return error.DepthLimit;
            if (self.work >= self.limits.max_work) return error.WorkLimit;
            self.work += 1;
        }
        fn take(self: *@This(), count: usize) Error![]const u8 {
            if (count > self.skeleton.len - self.at) return error.Truncated;
            const result = self.skeleton[self.at..][0..count];
            self.at += count;
            return result;
        }
        fn byte(self: *@This()) Error!u8 {
            return (try self.take(1))[0];
        }
        fn varint(self: *@This()) Error!u64 {
            var v: u64 = 0;
            for (0..10) |i| {
                const b = try self.byte();
                if (i == 9 and b > 1) return error.IntegerOverflow;
                v |= @as(u64, b & 127) << @as(u6, @intCast(i * 7));
                if (b < 128) {
                    if (i != 0 and b == 0) return error.NonCanonicalVarint;
                    return v;
                }
            }
            return error.IntegerOverflow;
        }
        fn length(self: *@This()) Error!usize {
            const v = try self.varint();
            if (v > self.limits.max_slice_length) return error.SliceTooLong;
            return @intCast(v);
        }
    };
}
fn walk(comptime Root: type, comptime T: type, page: Page(Root), cursor: *Cursor(Root), root_lane: ?usize, depth: usize, output: ?*std.ArrayList(u8), allocator: std.mem.Allocator) Error!void {
    @setEvalBranchQuota(500_000);
    try cursor.step(depth);
    const start = cursor.at;
    if (comptime isBytes(T)) {
        const length = try cursor.length();
        const lane = selectedLane(length, root_lane, page.threshold);
        const position = cursor.lane_at[lane];
        if (position > page.lane_lengths[lane] or length > page.lane_lengths[lane] - position) return error.InvalidCheckpoint;
        cursor.lane_at[lane] += length;
        if (output) |out| {
            if (!page.resident[lane]) return error.LaneNotLoaded;
            try out.appendSlice(allocator, cursor.skeleton[start..cursor.at]);
            try out.appendSlice(allocator, page.lanes[lane][position..][0..length]);
        }
        return;
    }
    switch (@typeInfo(T)) {
        .void => {},
        .bool => {
            if (try cursor.byte() > 1) return error.InvalidBoolean;
        },
        .int => |i| {
            if (i.bits > 64) return error.UnsupportedType;
            const v = try cursor.varint();
            if (v > std.math.maxInt(std.meta.Int(.unsigned, i.bits))) return error.IntegerOverflow;
        },
        .@"enum" => |e| {
            if (try cursor.varint() >= e.fields.len) return error.InvalidEnum;
        },
        .optional => |o| {
            const present = try cursor.byte();
            if (present > 1) return error.InvalidBoolean;
            if (output) |out| try out.appendSlice(allocator, cursor.skeleton[start..cursor.at]);
            if (present != 0) try walk(Root, o.child, page, cursor, root_lane, depth + 1, output, allocator);
            return;
        },
        .pointer => |p| {
            if (p.size == .one) return walk(Root, p.child, page, cursor, root_lane, depth + 1, output, allocator);
            if (p.size != .slice) return error.UnsupportedType;
            const count = try cursor.length();
            if (count > cursor.limits.max_work - cursor.work) return error.WorkLimit;
            if (output) |out| try out.appendSlice(allocator, cursor.skeleton[start..cursor.at]);
            for (0..count) |_| try walk(Root, p.child, page, cursor, root_lane, depth + 1, output, allocator);
            return;
        },
        .array => |a| {
            for (0..a.len) |_| try walk(Root, a.child, page, cursor, root_lane, depth + 1, output, allocator);
            return;
        },
        .@"struct" => |s| {
            const defaults = comptime packet.defaultCount(T);
            const mask = if (defaults != 0) try cursor.varint() else 0;
            if (defaults < 64 and mask >> @as(u6, @intCast(defaults)) != 0) return error.InvalidDefaultMask;
            if (output) |out| try out.appendSlice(allocator, cursor.skeleton[start..cursor.at]);
            comptime var bit = 0;
            inline for (s.fields) |f| {
                const present = if (comptime defaults != 0 and packet.elidable(f)) present: {
                    const p = mask & (@as(u64, 1) << bit) != 0;
                    bit += 1;
                    break :present p;
                } else true;
                if (present) try walk(Root, f.type, page, cursor, fieldLane(Root, T, f, depth == 0, page.threshold), depth + 1, output, allocator);
            }
            return;
        },
        .@"union" => |u| {
            const tag = try cursor.varint();
            if (output) |out| try out.appendSlice(allocator, cursor.skeleton[start..cursor.at]);
            inline for (u.fields, 0..) |f, ordinal| {
                if (tag == ordinal) {
                    try walk(Root, f.type, page, cursor, root_lane, depth + 1, output, allocator);
                    return;
                }
            }
            return error.InvalidUnionTag;
        },
        else => return error.UnsupportedType,
    }
    if (output) |out| try out.appendSlice(allocator, cursor.skeleton[start..cursor.at]);
}

pub fn Page(comptime Root: type) type {
    return struct {
        bytes: []const u8,
        count: usize,
        offsets: []const u8,
        checkpoints: []const u8,
        skeleton: []const u8,
        lanes: [laneCount(Root)][]const u8,
        lane_lengths: [laneCount(Root)]usize,
        resident: [laneCount(Root)]bool = @splat(true),
        threshold: u16,
        limits: Limits,
        const Self = @This();
        fn rootCursor(self: Self, index: usize) Error!Cursor(Root) {
            if (index >= self.count) return error.InvalidReference;
            var cp: [laneCount(Root)]usize = undefined;
            for (&cp, 0..) |*value, lane| value.* = get32(self.checkpoints, (index * cp.len + lane) * 4);
            return .{ .skeleton = self.skeleton[get32(self.offsets, index * 4)..get32(self.offsets, (index + 1) * 4)], .lane_at = cp, .limits = self.limits.packet, .threshold = self.threshold };
        }
        pub fn restorePacket(self: Self, allocator: std.mem.Allocator, index: usize) Error![]u8 {
            var cursor = try self.rootCursor(index);
            var expected_size = cursor.skeleton.len + 5;
            for (cursor.lane_at, 0..) |position, lane| expected_size += get32(self.checkpoints, ((index + 1) * laneCount(Root) + lane) * 4) - position;
            if (expected_size > self.limits.packet.max_input_bytes) return error.InputTooLarge;
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            try out.ensureTotalCapacity(allocator, expected_size);
            try out.appendSlice(allocator, "LXP6\x03");
            try walk(Root, Root, self, &cursor, null, 0, &out, allocator);
            if (cursor.at != cursor.skeleton.len) return error.TrailingBytes;
            return out.toOwnedSlice(allocator);
        }
        pub fn decode(self: Self, allocator: std.mem.Allocator, index: usize) Error!packet.Decoded(Root) {
            const bytes = try self.restorePacket(allocator, index);
            defer allocator.free(bytes);
            return packet.decode(Root, allocator, bytes, self.limits.packet);
        }
        pub fn prepare(self: Self, allocator: std.mem.Allocator, scope: lex.validate.Scope) Error!PreparedPage(Root) {
            if (comptime Root != lex.model.Entry) return error.SemanticAdmissionUnavailable;
            for (0..self.count) |i| {
                var value = try self.decode(allocator, i);
                defer value.deinit();
                try lex.validate.check(allocator, &value.value, scope);
            }
            return .{ .page = self };
        }
        fn view(self: Self, index: usize) Error!View(Root, Root) {
            return .{ .page = self, .backing = .{ .cursor = try self.rootCursor(index) }, .depth = 0 };
        }
    };
}
pub fn PreparedPage(comptime Root: type) type {
    return struct {
        page: Page(Root),
        pub fn view(self: @This(), index: usize) Error!View(Root, Root) {
            return self.page.view(index);
        }
    };
}

pub fn open(comptime Root: type, bytes: []const u8, limits: Limits) Error!Page(Root) {
    const n = comptime laneCount(Root);
    if (bytes.len > limits.max_page_bytes) return error.PageTooLarge;
    if (bytes.len < header_size or !std.mem.eql(u8, bytes[0..4], "LPC1") or bytes[4] != 1 or bytes[5] != 3 or get32(bytes, 20) != bytes.len) return error.InvalidPage;
    if (std.mem.readInt(u64, bytes[24..32], .little) != comptime dag.schemaFingerprint(Root)) return error.InvalidSchema;
    if (get32(bytes, 12) != n) return error.InvalidPage;
    if (!std.crypto.timing_safe.eql([32]u8, digest(bytes), bytes[32..64].*)) return error.DigestMismatch;
    const count = get32(bytes, 8);
    if (count > limits.max_roots) return error.TooManyRoots;
    const cp_at = header_size + (@as(usize, count) + 1) * 4;
    const len_at = cp_at + (@as(usize, count) + 1) * n * 4;
    const structure_at = len_at + n * 4;
    if (structure_at > bytes.len or get32(bytes, 16) > bytes.len - structure_at) return error.InvalidPage;
    const structure_end = structure_at + get32(bytes, 16);
    var page = Page(Root){ .bytes = bytes, .count = count, .offsets = bytes[header_size..cp_at], .checkpoints = bytes[cp_at..len_at], .skeleton = bytes[structure_at..structure_end], .lanes = undefined, .lane_lengths = undefined, .threshold = std.mem.readInt(u16, bytes[6..8], .little), .limits = limits };
    var at = structure_end;
    for (&page.lanes, 0..) |*lane, i| {
        const len = get32(bytes, len_at + i * 4);
        if (len > bytes.len - at) return error.InvalidPage;
        lane.* = bytes[at..][0..len];
        page.lane_lengths[i] = len;
        at += len;
    }
    if (at != bytes.len or get32(page.offsets, 0) != 0 or get32(page.offsets, count * 4) != page.skeleton.len) return error.InvalidPage;
    for (page.lanes, 0..) |lane, i| {
        if (get32(page.checkpoints, i * 4) != 0 or get32(page.checkpoints, (count * n + i) * 4) != lane.len) return error.InvalidCheckpoint;
    }
    for (0..count) |i| {
        if (get32(page.offsets, (i + 1) * 4) > page.skeleton.len or get32(page.offsets, i * 4) > get32(page.offsets, (i + 1) * 4)) return error.InvalidCheckpoint;
        var cursor = try page.rootCursor(i);
        try walk(Root, Root, page, &cursor, null, 0, null, undefined);
        if (cursor.at != cursor.skeleton.len) return error.TrailingBytes;
        for (cursor.lane_at, 0..) |position, lane| {
            if (position != get32(page.checkpoints, ((i + 1) * n + lane) * 4)) return error.InvalidCheckpoint;
        }
    }
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
        backing: union(enum) { cursor: Cursor(Root), native: *const T },
        root_lane: ?usize = null,
        depth: usize,
        const Self = @This();
        pub fn field(self: Self, comptime name: anytype) Error!View(Root, fieldType(T, name)) {
            const selected = comptime if (@typeInfo(@TypeOf(name)) == .enum_literal) @tagName(name) else name;
            if (self.backing == .native) return .{ .page = self.page, .backing = .{ .native = &@field(self.backing.native.*, selected) }, .depth = self.depth + 1 };
            var cursor = self.backing.cursor;
            const defaults = comptime packet.defaultCount(T);
            const mask = if (defaults != 0) try cursor.varint() else 0;
            comptime var bit = 0;
            inline for (@typeInfo(T).@"struct".fields) |f| {
                const present = if (comptime defaults != 0 and packet.elidable(f)) present: {
                    const p = mask & (@as(u64, 1) << bit) != 0;
                    bit += 1;
                    break :present p;
                } else true;
                const lane = fieldLane(Root, T, f, self.depth == 0, self.page.threshold);
                if (comptime std.mem.eql(u8, f.name, selected)) {
                    return .{ .page = self.page, .backing = if (present) .{ .cursor = cursor } else .{ .native = @ptrCast(@alignCast(f.default_value_ptr.?)) }, .root_lane = lane, .depth = self.depth + 1 };
                }
                if (present) try walk(Root, f.type, self.page, &cursor, lane, self.depth + 1, null, undefined);
            }
            unreachable;
        }
        pub fn text(self: Self) Error![]const u8 {
            if (comptime !isBytes(T)) @compileError("text requires bytes");
            if (self.backing == .native) return self.backing.native.*;
            var cursor = self.backing.cursor;
            const length = try cursor.length();
            const lane = selectedLane(length, self.root_lane, self.page.threshold);
            if (!self.page.resident[lane]) return error.LaneNotLoaded;
            return self.page.lanes[lane][cursor.lane_at[lane]..][0..length];
        }
        pub fn tag(self: Self) Error!std.meta.Tag(T) {
            if (self.backing == .native) return std.meta.activeTag(self.backing.native.*);
            var cursor = self.backing.cursor;
            const ordinal = try cursor.varint();
            inline for (@typeInfo(T).@"union".fields, 0..) |f, i| {
                if (ordinal == i) return @field(std.meta.Tag(T), f.name);
            }
            return error.InvalidUnionTag;
        }
        pub fn payload(self: Self, comptime selected: std.meta.Tag(T)) Error!View(Root, @FieldType(T, @tagName(selected))) {
            if (try self.tag() != selected) return error.WrongUnionTag;
            if (self.backing == .native) return .{ .page = self.page, .backing = .{ .native = &@field(self.backing.native.*, @tagName(selected)) }, .depth = self.depth + 1 };
            var cursor = self.backing.cursor;
            _ = try cursor.varint();
            return .{ .page = self.page, .backing = .{ .cursor = cursor }, .root_lane = self.root_lane, .depth = self.depth + 1 };
        }
        pub fn optional(self: Self) Error!?View(Root, @typeInfo(T).optional.child) {
            if (self.backing == .native) {
                if (self.backing.native.*) |*value| return .{ .page = self.page, .backing = .{ .native = value }, .depth = self.depth + 1 };
                return null;
            }
            var cursor = self.backing.cursor;
            if (try cursor.byte() == 0) return null;
            return .{ .page = self.page, .backing = .{ .cursor = cursor }, .root_lane = self.root_lane, .depth = self.depth + 1 };
        }
        pub fn scalar(self: Self) Error!T {
            if (self.backing == .native) return self.backing.native.*;
            var cursor = self.backing.cursor;
            return switch (@typeInfo(T)) {
                .void => {},
                .bool => (try cursor.byte()) != 0,
                .int => |i| integer: {
                    const U = std.meta.Int(.unsigned, i.bits);
                    const narrowed: U = @intCast(try cursor.varint());
                    if (i.signedness == .signed) break :integer @bitCast((narrowed >> 1) ^ (0 -% (narrowed & 1)));
                    break :integer @intCast(narrowed);
                },
                .@"enum" => |e| enumeration: {
                    const ordinal = try cursor.varint();
                    inline for (e.fields, 0..) |f, i| {
                        if (ordinal == i) break :enumeration @field(T, f.name);
                    }
                    return error.InvalidEnum;
                },
                else => @compileError("scalar requires an integer, boolean, enum or void"),
            };
        }
        pub fn pointee(self: Self) Error!View(Root, @typeInfo(T).pointer.child) {
            if (comptime @typeInfo(T).pointer.size != .one) @compileError("pointee requires a single ownership pointer");
            return .{ .page = self.page, .backing = if (self.backing == .native) .{ .native = self.backing.native.* } else .{ .cursor = self.backing.cursor }, .root_lane = self.root_lane, .depth = self.depth + 1 };
        }
        pub fn decodeOwned(self: Self, allocator: std.mem.Allocator) Error!packet.Decoded(T) {
            if (self.backing == .native) {
                const bytes = try packet.encode(allocator, self.backing.native.*, self.page.limits.packet);
                defer allocator.free(bytes);
                return packet.decode(T, allocator, bytes, self.page.limits.packet);
            }
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(allocator);
            try out.appendSlice(allocator, "LXP6\x03");
            var cursor = self.backing.cursor;
            try walk(Root, T, self.page, &cursor, self.root_lane, self.depth, &out, allocator);
            return packet.decode(T, allocator, out.items, self.page.limits.packet);
        }
        pub fn values(self: Self) Error!Iterator(Root, T) {
            if (self.backing == .native) return .{ .page = self.page, .native = self.backing.native.*, .count = self.backing.native.len, .depth = self.depth + 1 };
            var cursor = self.backing.cursor;
            const count = switch (@typeInfo(T)) {
                .pointer => try cursor.length(),
                .array => |a| a.len,
                else => @compileError("values requires collection"),
            };
            return .{ .page = self.page, .cursor = cursor, .count = count, .root_lane = self.root_lane, .depth = self.depth + 1 };
        }
    };
}
pub fn Iterator(comptime Root: type, comptime T: type) type {
    return struct {
        page: Page(Root),
        cursor: ?Cursor(Root) = null,
        native: ?T = null,
        count: usize,
        index: usize = 0,
        root_lane: ?usize = null,
        depth: usize,
        pub fn next(self: *@This()) Error!?View(Root, elementType(T)) {
            if (self.index == self.count) return null;
            defer self.index += 1;
            if (self.native) |slice| return .{ .page = self.page, .backing = .{ .native = &slice[self.index] }, .depth = self.depth };
            const result = View(Root, elementType(T)){ .page = self.page, .backing = .{ .cursor = self.cursor.? }, .root_lane = self.root_lane, .depth = self.depth };
            try walk(Root, elementType(T), self.page, &self.cursor.?, self.root_lane, self.depth, null, undefined);
            return result;
        }
    };
}
