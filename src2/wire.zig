//! Small, boring primitives for the parts of the format that must never be
//! clever at run time.
//!
//! `Layout(T)` is the one place where fixed records acquire a byte layout.  A
//! record is encoded field-by-field in declaration order, so host padding and
//! endianness can never leak onto disk.  Keeping that rule here lets the rest
//! of the reader talk in named records instead of offset arithmetic.

const std = @import("std");

pub const Error = error{ Truncated, Overflow, InvalidValue, TrailingBytes, OutOfMemory };

pub fn add(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.Overflow;
}

pub fn mul(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch error.Overflow;
}

pub fn cast(comptime T: type, value: anytype) Error!T {
    return std.math.cast(T, value) orelse error.Overflow;
}

pub fn slice(bytes: []const u8, at: usize, len: usize) Error![]const u8 {
    if (at > bytes.len or len > bytes.len - at) return error.Truncated;
    return bytes[at..][0..len];
}

pub fn sliceMut(bytes: []u8, at: usize, len: usize) Error![]u8 {
    if (at > bytes.len or len > bytes.len - at) return error.Truncated;
    return bytes[at..][0..len];
}

pub fn readInt(comptime T: type, bytes: []const u8, at: usize) Error!T {
    comptime assertInt(T);
    const field = try slice(bytes, at, @sizeOf(T));
    return std.mem.readInt(T, field[0..@sizeOf(T)], .little);
}

pub fn writeInt(comptime T: type, bytes: []u8, at: usize, value: T) Error!void {
    comptime assertInt(T);
    const field = try sliceMut(bytes, at, @sizeOf(T));
    std.mem.writeInt(T, field[0..@sizeOf(T)], value, .little);
}

fn assertInt(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int => {},
        else => @compileError("wire integer must be an integer type, got " ++ @typeName(T)),
    }
}

fn encodedSize(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .int, .float => @sizeOf(T),
        .bool => 1,
        .@"enum" => |info| @sizeOf(info.tag_type),
        .array => |info| info.len * encodedSize(info.child),
        .@"struct" => |info| blk: {
            var size: usize = 0;
            for (info.fields) |field| size += encodedSize(field.type);
            break :blk size;
        },
        else => @compileError("unsupported wire field type " ++ @typeName(T)),
    };
}

fn decode(comptime T: type, bytes: []const u8, cursor: *usize) Error!T {
    return switch (@typeInfo(T)) {
        .int => blk: {
            const value = try readInt(T, bytes, cursor.*);
            cursor.* = try add(cursor.*, @sizeOf(T));
            break :blk value;
        },
        .float => blk: {
            const Int = std.meta.Int(.unsigned, @bitSizeOf(T));
            break :blk @bitCast(try decode(Int, bytes, cursor));
        },
        .bool => blk: {
            const value = try decode(u8, bytes, cursor);
            if (value > 1) return error.InvalidValue;
            break :blk value != 0;
        },
        .@"enum" => |info| blk: {
            const Storage = std.meta.Int(.unsigned, @sizeOf(info.tag_type) * 8);
            const stored = try decode(Storage, bytes, cursor);
            const raw = std.math.cast(info.tag_type, stored) orelse return error.InvalidValue;
            if (!info.is_exhaustive) break :blk @enumFromInt(raw);
            break :blk std.enums.fromInt(T, raw) orelse return error.InvalidValue;
        },
        .array => |info| blk: {
            var result: T = undefined;
            for (&result) |*item| item.* = try decode(info.child, bytes, cursor);
            break :blk result;
        },
        .@"struct" => |info| blk: {
            var result: T = undefined;
            inline for (info.fields) |field| @field(result, field.name) = try decode(field.type, bytes, cursor);
            break :blk result;
        },
        else => comptime unreachable,
    };
}

fn encode(comptime T: type, bytes: []u8, cursor: *usize, value: T) Error!void {
    switch (@typeInfo(T)) {
        .int => {
            try writeInt(T, bytes, cursor.*, value);
            cursor.* = try add(cursor.*, @sizeOf(T));
        },
        .float => {
            const Int = std.meta.Int(.unsigned, @bitSizeOf(T));
            try encode(Int, bytes, cursor, @bitCast(value));
        },
        .bool => try encode(u8, bytes, cursor, @intFromBool(value)),
        .@"enum" => |info| {
            const Storage = std.meta.Int(.unsigned, @sizeOf(info.tag_type) * 8);
            try encode(Storage, bytes, cursor, @intFromEnum(value));
        },
        .array => |info| for (value) |item| try encode(info.child, bytes, cursor, item),
        .@"struct" => |info| inline for (info.fields) |field| try encode(field.type, bytes, cursor, @field(value, field.name)),
        else => comptime unreachable,
    }
}

/// Generates a canonical little-endian codec for a fixed record type.
pub fn Layout(comptime T: type) type {
    const size_value = encodedSize(T);
    return struct {
        pub const Value = T;
        pub const size = size_value;

        pub fn read(bytes: []const u8, at: usize) Error!T {
            _ = try slice(bytes, at, size);
            var cursor = at;
            return decode(T, bytes, &cursor);
        }

        pub fn write(bytes: []u8, at: usize, value: T) Error!void {
            _ = try sliceMut(bytes, at, size);
            var cursor = at;
            try encode(T, bytes, &cursor, value);
        }
    };
}

/// Appends fixed records without exposing the byte representation to callers.
pub fn append(comptime T: type, out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: T) Error!void {
    const at = out.items.len;
    try out.appendNTimes(allocator, 0, Layout(T).size);
    try Layout(T).write(out.items, at, value);
}

test "generated layouts ignore host padding and reject short records" {
    const Header = struct {
        magic: [4]u8,
        version: u16,
        flags: u8,
        length: u64,
    };
    const Codec = Layout(Header);
    try std.testing.expectEqual(@as(usize, 15), Codec.size);
    var bytes: [Codec.size]u8 = undefined;
    const expected = Header{ .magic = "TEST".*, .version = 0x102, .flags = 3, .length = 0x0102_0304_0506_0708 };
    try Codec.write(&bytes, 0, expected);
    try std.testing.expectEqual(expected, try Codec.read(&bytes, 0));
    try std.testing.expectError(error.Truncated, Codec.read(bytes[0 .. bytes.len - 1], 0));
}
