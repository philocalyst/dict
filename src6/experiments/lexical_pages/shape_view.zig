//! Direct typed field access to a fully admitted immutable shape/literal page.
//! Composite navigation follows shape references and stored hole counts; leaf
//! lookup uses one 32-leaf checkpoint and skips at most 31 length headers.
//! No descendant reconstruction, allocator, normalization or lexical schema.
const std = @import("std");
const lex = @import("lex6");
const shape = @import("shape.zig");
const packet = lex.packet;
pub const Error = shape.Error || error{WrongUnionTag};

fn leafType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .void, .bool, .int, .@"enum" => true,
        .pointer => |p| p.size == .slice and p.child == u8,
        else => false,
    };
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
        var value: u64 = 0;
        var shift: u6 = 0;
        for (0..10) |i| {
            const part = try self.byte();
            if (i == 9 and part > 1) return error.IntegerOverflow;
            value |= @as(u64, part & 127) << shift;
            if (part & 128 == 0) {
                if (i != 0 and part == 0) return error.NonCanonicalVarint;
                return value;
            }
            if (i != 9) shift += 7;
        }
        return error.IntegerOverflow;
    }
    fn length(self: *Cursor) Error!usize {
        const n = try self.varint();
        if (n > std.math.maxInt(usize)) return error.IntegerOverflow;
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
            const ordinal = try c.varint();
            inline for (e.fields, 0..) |f, i| if (ordinal == i) break :result @field(T, f.name);
            return error.InvalidEnum;
        },
        else => error.UnsupportedType,
    };
}
fn nameOf(comptime name: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(name))) {
        .enum_literal, .@"enum" => @tagName(name),
        else => name,
    };
}
fn fieldType(comptime T: type, comptime name: anytype) type {
    return @FieldType(T, nameOf(name));
}
fn elementType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        .array => |a| a.child,
        else => @compileError("values requires a collection"),
    };
}

/// PRECONDITION: this exact immutable page has passed open's complete bounds
/// and canonical checks plus Page.prepare's occurrence-sensitive native lexical
/// admission under the same Root and limits. It is a caller contract, not an
/// unforgeable token. The backing page must outlive every derived view/string.
pub fn fromAdmittedPage(comptime Root: type, page: shape.Page(Root), index: usize) Error!View(Root, Root) {
    return .{ .page = page, .root_index = index, .backing = .{ .node = try page.rootShape(index) } };
}

pub fn View(comptime Root: type, comptime T: type) type {
    return struct {
        page: shape.Page(Root),
        root_index: usize,
        hole: usize = 0,
        backing: union(enum) { node: u32, literal: void, native: *const T },
        const Self = @This();
        pub const Value = T;
        fn cursor(self: Self) Error!Cursor {
            if (self.backing != .node) return error.UnsupportedType;
            return .{ .bytes = try self.page.templateBytes(self.backing.node, T) };
        }
        fn literal(self: Self) Error![]const u8 {
            var c = Cursor{ .bytes = try self.page.literalCheckpoint(self.root_index, self.hole / shape.checkpoint_stride) };
            for (0..self.hole % shape.checkpoint_stride) |_| _ = try c.take(try c.length());
            return c.take(try c.length());
        }
        fn edge(self: Self, comptime C: type, c: *Cursor, hole: usize) Error!View(Root, C) {
            if (comptime leafType(C)) return .{ .page = self.page, .root_index = self.root_index, .hole = hole, .backing = .literal };
            const id = try c.varint();
            if (id > std.math.maxInt(u32)) return error.InvalidReference;
            return .{ .page = self.page, .root_index = self.root_index, .hole = hole, .backing = .{ .node = @intCast(id) } };
        }
        fn skip(self: Self, comptime C: type, c: *Cursor) Error!usize {
            if (comptime C == void) return 0;
            if (comptime leafType(C)) return 1;
            const id = try c.varint();
            if (id > std.math.maxInt(u32)) return error.InvalidReference;
            return self.page.templateHoles(@intCast(id));
        }
        pub fn field(self: Self, comptime selected: anytype) Error!View(Root, fieldType(T, selected)) {
            const C = fieldType(T, selected);
            const name = comptime nameOf(selected);
            if (self.backing == .native) return .{ .page = self.page, .root_index = self.root_index, .backing = .{ .native = &@field(self.backing.native.*, name) } };
            var c = try self.cursor();
            const defaults = comptime packet.defaultCount(T);
            const mask = if (defaults != 0) try c.varint() else 0;
            comptime var bit = 0;
            var hole = self.hole;
            inline for (@typeInfo(T).@"struct".fields) |f| {
                const present = if (comptime defaults != 0 and packet.elidable(f)) present: {
                    const set = mask & (@as(u64, 1) << bit) != 0;
                    bit += 1;
                    break :present set;
                } else true;
                if (comptime std.mem.eql(u8, f.name, name)) {
                    if (!present) return .{ .page = self.page, .root_index = self.root_index, .backing = .{ .native = @ptrCast(@alignCast(f.default_value_ptr.?)) } };
                    return self.edge(C, &c, hole);
                }
                if (present) hole = std.math.add(usize, hole, try self.skip(f.type, &c)) catch return error.ExpandedWorkLimit;
            }
            unreachable;
        }
        pub fn text(self: Self) Error![]const u8 {
            if (self.backing == .native) return self.backing.native.*;
            return self.literal();
        }
        pub fn scalarValue(self: Self) Error!T {
            if (self.backing == .native) return self.backing.native.*;
            if (comptime T == void) return {};
            var c = Cursor{ .bytes = try self.literal() };
            const value = try scalar(T, &c);
            if (c.at != c.bytes.len) return error.TrailingBytes;
            return value;
        }
        pub fn tag(self: Self) Error!std.meta.Tag(T) {
            if (self.backing == .native) return std.meta.activeTag(self.backing.native.*);
            var c = try self.cursor();
            const ordinal = try c.varint();
            inline for (@typeInfo(T).@"union".fields, 0..) |f, i| if (ordinal == i) return @field(std.meta.Tag(T), f.name);
            return error.InvalidUnionTag;
        }
        pub fn payload(self: Self, comptime selected: std.meta.Tag(T)) Error!View(Root, @FieldType(T, @tagName(selected))) {
            const C = @FieldType(T, @tagName(selected));
            if (self.backing == .native) {
                if (std.meta.activeTag(self.backing.native.*) != selected) return error.WrongUnionTag;
                return .{ .page = self.page, .root_index = self.root_index, .backing = .{ .native = &@field(self.backing.native.*, @tagName(selected)) } };
            }
            var c = try self.cursor();
            const ordinal = try c.varint();
            inline for (@typeInfo(T).@"union".fields, 0..) |f, i| if (comptime std.mem.eql(u8, f.name, @tagName(selected))) {
                if (ordinal != i) return error.WrongUnionTag;
                return self.edge(C, &c, self.hole);
            };
            unreachable;
        }
        pub fn optional(self: Self) Error!?View(Root, @typeInfo(T).optional.child) {
            const C = @typeInfo(T).optional.child;
            if (self.backing == .native) {
                if (self.backing.native.*) |*value| return .{ .page = self.page, .root_index = self.root_index, .backing = .{ .native = value } };
                return null;
            }
            var c = try self.cursor();
            if (try c.byte() == 0) return null;
            return try self.edge(C, &c, self.hole);
        }
        pub fn pointee(self: Self) Error!View(Root, @typeInfo(T).pointer.child) {
            const C = @typeInfo(T).pointer.child;
            if (self.backing == .native) return .{ .page = self.page, .root_index = self.root_index, .backing = .{ .native = self.backing.native.* } };
            var c = try self.cursor();
            return self.edge(C, &c, self.hole);
        }
        pub fn values(self: Self) Error!Iterator(Root, T) {
            if (self.backing == .native) return .{ .view = self, .backing = .{ .native = self.backing.native } };
            var c = try self.cursor();
            const count = switch (@typeInfo(T)) {
                .pointer => try c.length(),
                .array => |a| a.len,
                else => @compileError("values requires a collection"),
            };
            return .{ .view = self, .backing = .{ .wire = .{ .cursor = c, .remaining = count, .hole = self.hole } } };
        }
    };
}
pub fn Iterator(comptime Root: type, comptime T: type) type {
    return struct {
        view: View(Root, T),
        backing: union(enum) { native: *const T, wire: struct { cursor: Cursor, remaining: usize, hole: usize } },
        index: usize = 0,
        pub const Element = elementType(T);
        pub fn next(self: *@This()) Error!?View(Root, Element) {
            switch (self.backing) {
                .native => |p| {
                    if (self.index >= p.len) return null;
                    const result = &p.*[self.index];
                    self.index += 1;
                    return .{ .page = self.view.page, .root_index = self.view.root_index, .backing = .{ .native = result } };
                },
                .wire => |*w| {
                    if (w.remaining == 0) return null;
                    w.remaining -= 1;
                    const start = w.cursor;
                    const result = try self.view.edge(Element, &w.cursor, w.hole);
                    var count_cursor = start;
                    w.hole = std.math.add(usize, w.hole, try self.view.skip(Element, &count_cursor)) catch return error.ExpandedWorkLimit;
                    return result;
                },
            }
        }
    };
}
