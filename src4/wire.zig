//! Canonical wire building blocks shared by every LEX4 section.
//!
//! Host layout is never serialized. `Layout(T)` recursively lowers a record
//! to fixed-width little-endian fields and rejects invalid exhaustive enums.

const std = @import("std");

pub const Error = error{
    Truncated,
    Overflow,
    InvalidValue,
    InvalidAlignment,
    TrailingBytes,
    OutOfMemory,
};

/// The exact byte window intersecting one little-endian packed lane.
///
/// `offset` is relative to the caller's byte slice.  A zero-width lane has
/// no touched bytes and therefore returns a zero-length range.
pub const PackedRange = struct {
    offset: usize,
    length: usize,
};

pub fn add(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.Overflow;
}

pub fn mul(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch error.Overflow;
}

pub fn cast(comptime T: type, value: anytype) Error!T {
    return std.math.cast(T, value) orelse error.Overflow;
}

pub fn bytesAt(bytes: []const u8, offset: usize, len: usize) Error![]const u8 {
    if (offset > bytes.len or len > bytes.len - offset) return error.Truncated;
    return bytes[offset..][0..len];
}

pub fn bytesAtMut(bytes: []u8, offset: usize, len: usize) Error![]u8 {
    if (offset > bytes.len or len > bytes.len - offset) return error.Truncated;
    return bytes[offset..][0..len];
}

/// Stable checked byte capability. Raw slices are a comptime specialization;
/// mapped/authenticated sources expose `len()` and `bytes(offset, length)`.
pub const Slice = struct {
    data: []const u8,

    pub fn len(self: *const Slice) usize {
        return self.data.len;
    }
    pub fn bytes(self: *const Slice, offset: usize, length: usize) Error![]const u8 {
        return bytesAt(self.data, offset, length);
    }
};

pub fn SourceError(comptime Source: type) type {
    if (Source == []const u8 or Source == []u8) return Error;
    const DeclSource = switch (@typeInfo(Source)) {
        .pointer => |pointer| pointer.child,
        else => Source,
    };
    const access = if (@hasDecl(DeclSource, "bytes")) DeclSource.bytes else if (@hasDecl(DeclSource, "read")) DeclSource.read else @compileError("source must provide bytes(offset,length) or read(offset,length)");
    const info = @typeInfo(@TypeOf(access)).@"fn";
    const result = info.return_type orelse @compileError("source bytes must return an error union");
    return @typeInfo(result).error_union.error_set || Error;
}

pub inline fn sourceLen(comptime Source: type, source: *const Source) usize {
    if (comptime Source == []const u8 or Source == []u8) return source.*.len;
    if (comptime @typeInfo(Source) == .pointer) return source.*.len();
    return source.len();
}

pub inline fn sourceBytes(comptime Source: type, source: *const Source, offset: usize, length: usize) SourceError(Source)![]const u8 {
    if (comptime Source == []const u8 or Source == []u8) return bytesAt(source.*, offset, length);
    if (comptime @typeInfo(Source) == .pointer) {
        const DeclSource = @typeInfo(Source).pointer.child;
        if (comptime @hasDecl(DeclSource, "bytes")) return source.*.bytes(offset, length);
        return source.*.read(offset, length);
    }
    if (comptime @hasDecl(Source, "bytes")) return source.bytes(offset, length);
    return source.read(offset, length);
}

pub fn Span(comptime Source: type) type {
    return struct {
        source: Source,
        base: usize,
        length: usize,

        pub fn init(source: Source, base: usize, length: usize) Error!@This() {
            const source_len = sourceLen(Source, &source);
            if (base > source_len or length > source_len - base) return error.Truncated;
            return .{ .source = source, .base = base, .length = length };
        }
        pub fn len(self: *const @This()) usize {
            return self.length;
        }
        pub fn bytes(self: *const @This(), offset: usize, length: usize) SourceError(Source)![]const u8 {
            if (offset > self.length or length > self.length - offset) return error.Truncated;
            return sourceBytes(Source, &self.source, try add(self.base, offset), length);
        }
        pub fn subspan(self: *const @This(), offset: usize, length: usize) Error!@This() {
            if (offset > self.length or length > self.length - offset) return error.Truncated;
            return .{ .source = self.source, .base = try add(self.base, offset), .length = length };
        }
    };
}

/// Return the byte window intersecting `width` bits beginning at
/// `bit_offset`, after an optional byte `base_offset` in the containing wire.
/// The helper deliberately performs no slice access; callers can use the
/// result to authenticate exactly the bytes needed by `readPacked`.
pub fn packedRange(base_offset: usize, bit_offset: usize, width: u8) Error!PackedRange {
    if (width > 64) return error.InvalidValue;
    const byte_offset = bit_offset / 8;
    const offset = try add(base_offset, byte_offset);
    if (width == 0) return .{ .offset = offset, .length = 0 };
    const edge_bits = try add(bit_offset % 8, @as(usize, width));
    const rounded = try add(edge_bits, 7);
    const length = rounded / 8;
    _ = try add(offset, length); // the half-open byte range must be representable
    return .{ .offset = offset, .length = length };
}

fn packedMask(width: u8) u64 {
    if (width == 0) return 0;
    if (width == 64) return std.math.maxInt(u64);
    return (@as(u64, 1) << @as(u6, @intCast(width))) - 1;
}

/// Read one unsigned little-endian packed lane.
///
/// The range is checked before any access.  A lane may start at any bit and
/// may span nine bytes (an unaligned 64-bit value); the final byte is read
/// only when the requested width reaches it.  Short tails are assembled from
/// the exact available bytes, so a mapped page beyond `bytes` is never
/// touched accidentally.
pub fn readPacked(bytes: []const u8, bit_offset: usize, width: u8) Error!u64 {
    if (width > 64) return error.InvalidValue;
    if (width == 0) return 0;
    const end = std.math.add(usize, bit_offset, @as(usize, width)) catch return error.Overflow;
    if (bytes.len > std.math.maxInt(usize) / 8 or end > bytes.len * 8) return error.Truncated;

    const byte_offset = bit_offset / 8;
    const shift: u6 = @intCast(bit_offset % 8);
    const touched = (bit_offset % 8 + @as(usize, width) + 7) / 8;
    // Lower each exact byte window to a fixed-width load. A byte-at-a-time
    // accumulator puts every byte behind the preceding OR; these independent
    // narrow loads let the backend use its native short-word instructions.
    // The odd-width cases are intentional: widening them would cross an
    // authenticated range or a mapped page boundary at the final field.
    const low_word: u64 = switch (touched) {
        inline 1, 2, 3, 4, 5, 6, 7 => |length| std.mem.readInt(
            std.meta.Int(.unsigned, length * 8),
            bytes[byte_offset..][0..length],
            .little,
        ),
        8, 9 => std.mem.readInt(u64, bytes[byte_offset..][0..8], .little),
        else => unreachable, // positive width <= 64 and shift < 8
    };

    const low = low_word >> shift;
    const low_width: u8 = 64 - @as(u8, shift);
    if (width <= low_width) return low & packedMask(width);

    // An unaligned 64-bit lane can need only seven bits from byte nine.
    const high_width = width - low_width;
    const ninth = bytes[byte_offset + 8] & @as(u8, @intCast(packedMask(high_width)));
    return low | (@as(u64, ninth) << @as(u6, @intCast(low_width)));
}

/// Write one unsigned little-endian packed lane without touching neighboring
/// bits.  The destination must already have its canonical padding bits clear;
/// callers receive `InvalidValue` when `value` does not fit the lane.
pub fn writePacked(bytes: []u8, bit_offset: usize, width: u8, value: u64) Error!void {
    if (width > 64) return error.InvalidValue;
    if (width == 0) return if (value == 0) {} else error.InvalidValue;
    const mask = packedMask(width);
    if (value & ~mask != 0) return error.InvalidValue;
    const end = std.math.add(usize, bit_offset, @as(usize, width)) catch return error.Overflow;
    if (bytes.len > std.math.maxInt(usize) / 8 or end > bytes.len * 8) return error.Truncated;
    var i: usize = 0;
    while (i < width) : (i += 1) {
        const bit = bit_offset + i;
        const byte = bit / 8;
        const mask8 = @as(u8, 1) << @as(u3, @intCast(bit % 8));
        if ((value & (@as(u64, 1) << @as(u6, @intCast(i)))) != 0) {
            bytes[byte] |= mask8;
        } else {
            bytes[byte] &= ~mask8;
        }
    }
}

fn assertInteger(comptime T: type) void {
    if (@typeInfo(T) != .int) @compileError("wire integer expected, found " ++ @typeName(T));
}

pub fn readInt(comptime T: type, bytes: []const u8, offset: usize) Error!T {
    comptime assertInteger(T);
    const field = try bytesAt(bytes, offset, @sizeOf(T));
    return std.mem.readInt(T, field[0..@sizeOf(T)], .little);
}

pub fn writeInt(comptime T: type, bytes: []u8, offset: usize, value: T) Error!void {
    comptime assertInteger(T);
    const field = try bytesAtMut(bytes, offset, @sizeOf(T));
    std.mem.writeInt(T, field[0..@sizeOf(T)], value, .little);
}

fn encodedSize(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .int, .float => @sizeOf(T),
        .bool => 1,
        .@"enum" => |info| @sizeOf(info.tag_type),
        .array => |info| info.len * encodedSize(info.child),
        .@"struct" => |info| blk: {
            var total: usize = 0;
            for (info.fields) |field| total += encodedSize(field.type);
            break :blk total;
        },
        else => @compileError("unsupported wire field " ++ @typeName(T)),
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
            const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
            break :blk @bitCast(try decode(Bits, bytes, cursor));
        },
        .bool => blk: {
            const value = try decode(u8, bytes, cursor);
            if (value > 1) return error.InvalidValue;
            break :blk value != 0;
        },
        .@"enum" => |info| blk: {
            const Stored = std.meta.Int(.unsigned, @sizeOf(info.tag_type) * 8);
            const stored = try decode(Stored, bytes, cursor);
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
            const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
            try encode(Bits, bytes, cursor, @bitCast(value));
        },
        .bool => try encode(u8, bytes, cursor, @intFromBool(value)),
        .@"enum" => |info| {
            const Stored = std.meta.Int(.unsigned, @sizeOf(info.tag_type) * 8);
            try encode(Stored, bytes, cursor, @intFromEnum(value));
        },
        .array => |info| for (value) |item| try encode(info.child, bytes, cursor, item),
        .@"struct" => |info| inline for (info.fields) |field| try encode(field.type, bytes, cursor, @field(value, field.name)),
        else => comptime unreachable,
    }
}

pub fn Layout(comptime T: type) type {
    return struct {
        pub const Value = T;
        pub const size = encodedSize(T);

        pub fn read(bytes: []const u8, offset: usize) Error!T {
            _ = try bytesAt(bytes, offset, size);
            var cursor = offset;
            return decode(T, bytes, &cursor);
        }

        pub fn write(bytes: []u8, offset: usize, value: T) Error!void {
            _ = try bytesAtMut(bytes, offset, size);
            var cursor = offset;
            try encode(T, bytes, &cursor, value);
        }

        pub fn append(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: T) Error!usize {
            const offset = out.items.len;
            try out.appendNTimes(allocator, 0, size);
            try write(out.items, offset, value);
            return offset;
        }
    };
}

pub fn alignForward(value: usize, alignment: usize) Error!usize {
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidAlignment;
    const mask = alignment - 1;
    return (try add(value, mask)) & ~mask;
}

pub fn padTo(out: *std.ArrayList(u8), allocator: std.mem.Allocator, alignment: usize) Error!void {
    const end = try alignForward(out.items.len, alignment);
    try out.appendNTimes(allocator, 0, end - out.items.len);
}

test "layout is padding-free and endian-stable" {
    const Record = struct { magic: [4]u8, version: u16, enabled: bool, length: u64 };
    const Codec = Layout(Record);
    try std.testing.expectEqual(@as(usize, 15), Codec.size);
    var bytes: [Codec.size]u8 = undefined;
    const record = Record{ .magic = "LEX4".*, .version = 0x102, .enabled = true, .length = 0x0102_0304_0506_0708 };
    try Codec.write(&bytes, 0, record);
    try std.testing.expectEqualSlices(u8, &.{ 0x4c, 0x45, 0x58, 0x34, 0x02, 0x01, 1 }, bytes[0..7]);
    try std.testing.expectEqual(record, try Codec.read(&bytes, 0));
    try std.testing.expectError(error.Truncated, Codec.read(bytes[0 .. bytes.len - 1], 0));
}

test "alignment rejects impossible requests and detects overflow" {
    try std.testing.expectEqual(@as(usize, 16), try alignForward(9, 8));
    try std.testing.expectError(error.InvalidAlignment, alignForward(9, 3));
    try std.testing.expectError(error.Overflow, alignForward(std.math.maxInt(usize), 8));
}

test "packed lanes are exhaustive across widths, offsets, tails, and overflow" {
    var storage: [16]u8 = undefined;
    for (&storage, 0..) |*byte, index| byte.* = @intCast((index * 73 + 19) % 251);
    for (0..storage.len + 1) |length| {
        const bytes = storage[0..length];
        for (0..length * 8 + 2) |offset| {
            for (0..65) |width_usize| {
                const width: u8 = @intCast(width_usize);
                if (width > 64) {
                    try std.testing.expectError(error.InvalidValue, readPacked(bytes, offset, width));
                    continue;
                }
                if (width == 0) {
                    try std.testing.expectEqual(@as(u64, 0), try readPacked(bytes, offset, width));
                    const expected_zero: PackedRange = .{ .offset = offset / 8, .length = 0 };
                    try std.testing.expectEqual(expected_zero, try packedRange(0, offset, width));
                    continue;
                }
                const end = std.math.add(usize, offset, width_usize) catch {
                    try std.testing.expectError(error.Overflow, readPacked(bytes, offset, width));
                    continue;
                };
                if (end > bytes.len * 8) {
                    try std.testing.expectError(error.Truncated, readPacked(bytes, offset, width));
                    continue;
                }
                var reference: u64 = 0;
                for (0..width_usize) |bit| {
                    if ((bytes[(offset + bit) / 8] & (@as(u8, 1) << @as(u3, @intCast((offset + bit) % 8)))) != 0)
                        reference |= @as(u64, 1) << @as(u6, @intCast(bit));
                }
                try std.testing.expectEqual(reference, try readPacked(bytes, offset, width));
                const expected_range: PackedRange = .{ .offset = offset / 8, .length = (offset % 8 + width_usize + 7) / 8 };
                try std.testing.expectEqual(expected_range, try packedRange(0, offset, width));
            }
        }
    }
    try std.testing.expectError(error.Overflow, readPacked(&storage, std.math.maxInt(usize) - 1, 2));
    try std.testing.expectError(error.Overflow, packedRange(std.math.maxInt(usize), 8, 1));
    try std.testing.expectError(error.Overflow, packedRange(std.math.maxInt(usize), 0, 1));
    try std.testing.expectEqual(@as(usize, 0), (try packedRange(4, 7, 0)).length);
}

test "packed writes preserve neighboring bits and canonical tails" {
    var bytes = [_]u8{0xff} ** 10;
    try writePacked(&bytes, 3, 17, 0x1aaaa);
    try std.testing.expectEqual(@as(u64, 0x1aaaa), try readPacked(&bytes, 3, 17));
    try std.testing.expectEqual(@as(u8, 7), bytes[0] & 7);
    try std.testing.expectEqual(@as(u8, 0xf0), bytes[2] & 0xf0);
    try std.testing.expect(std.mem.allEqual(u8, bytes[3..], 0xff));
    try writePacked(&bytes, 3, 17, 0);
    try std.testing.expectEqual(@as(u64, 0), try readPacked(&bytes, 3, 17));
    try std.testing.expectEqual(@as(u8, 7), bytes[0] & 7);
    try std.testing.expectEqual(@as(u8, 0xf0), bytes[2] & 0xf0);
    try std.testing.expect(std.mem.allEqual(u8, bytes[3..], 0xff));
    try std.testing.expectError(error.InvalidValue, writePacked(&bytes, 0, 3, 8));
    try std.testing.expectError(error.InvalidValue, writePacked(&bytes, 0, 0, 1));
    try std.testing.expectError(error.InvalidValue, writePacked(&bytes, 0, 65, 0));
    try std.testing.expectError(error.Truncated, writePacked(&bytes, bytes.len * 8 - 1, 2, 0));
    try std.testing.expectError(error.Overflow, writePacked(&bytes, std.math.maxInt(usize) - 1, 2, 0));
    try std.testing.expectError(error.InvalidValue, packedRange(0, 0, 65));
}
