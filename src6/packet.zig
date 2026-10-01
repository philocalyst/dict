//! Schema-specialized packets for the public lexical model.
//!
//! The wire format is deliberately small: a fixed schema marker followed by
//! recursive values. Strings and slices are length-prefixed, integers are
//! canonical varints (signed integers use zig-zag), enums and union tags use
//! their declaration ordinal, and structs encode fields in declaration order.
//! Decoded strings never borrow the packet bytes; `Decoded(T)` owns every
//! dynamic value in its arena and therefore survives the input buffer.
const std = @import("std");

pub const Limits = struct {
    max_input_bytes: usize = 16 * 1024 * 1024,
    /// Sum of requested decoded payload bytes. Arena chunk headers, alignment,
    /// and retained capacity are allocator overhead and are not included.
    max_allocation_bytes: usize = 32 * 1024 * 1024,
    max_slice_length: usize = 1_000_000,
    max_depth: usize = 128,
    max_work: usize = 8_000_000,
};

pub const Error = error{
    OutOfMemory,
    InputTooLarge,
    AllocationLimit,
    SliceTooLong,
    DepthLimit,
    WorkLimit,
    Truncated,
    TrailingBytes,
    InvalidMagic,
    UnsupportedVersion,
    NonCanonicalVarint,
    IntegerOverflow,
    InvalidBoolean,
    InvalidEnum,
    InvalidUnionTag,
    UnsupportedType,
};

const magic = "LXP6";
// The model is the schema. Version 2 adds named values and disjoint relation
// endpoints; version 1 packets must not be interpreted using these types.
pub const schema_version: u8 = 2;

pub fn Decoded(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

const Encoder = struct {
    allocator: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    limits: Limits,
    work: usize = 0,

    fn step(self: *Encoder, depth: usize) Error!void {
        if (depth > self.limits.max_depth) return error.DepthLimit;
        self.work = std.math.add(usize, self.work, 1) catch return error.WorkLimit;
        if (self.work > self.limits.max_work) return error.WorkLimit;
    }

    fn byte(self: *Encoder, value: u8) Error!void {
        if (self.out.items.len >= self.limits.max_input_bytes) return error.InputTooLarge;
        self.out.append(self.allocator, value) catch return error.OutOfMemory;
    }

    fn bytes(self: *Encoder, value: []const u8) Error!void {
        const end = std.math.add(usize, self.out.items.len, value.len) catch return error.InputTooLarge;
        if (end > self.limits.max_input_bytes) return error.InputTooLarge;
        self.out.appendSlice(self.allocator, value) catch return error.OutOfMemory;
    }

    fn varint(self: *Encoder, value: u64) Error!void {
        var remaining = value;
        while (remaining >= 0x80) {
            try self.byte(@as(u8, @truncate(remaining)) | 0x80);
            remaining >>= 7;
        }
        try self.byte(@intCast(remaining));
    }
};

const Decoder = struct {
    arena: std.mem.Allocator,
    bytes: []const u8,
    at: usize = 0,
    limits: Limits,
    work: usize = 0,
    allocated: usize = 0,

    fn step(self: *Decoder, depth: usize) Error!void {
        if (depth > self.limits.max_depth) return error.DepthLimit;
        self.work = std.math.add(usize, self.work, 1) catch return error.WorkLimit;
        if (self.work > self.limits.max_work) return error.WorkLimit;
    }

    fn byte(self: *Decoder) Error!u8 {
        if (self.at >= self.bytes.len) return error.Truncated;
        const result = self.bytes[self.at];
        self.at += 1;
        return result;
    }

    fn take(self: *Decoder, length: usize) Error![]const u8 {
        const end = std.math.add(usize, self.at, length) catch return error.Truncated;
        if (end > self.bytes.len) return error.Truncated;
        const result = self.bytes[self.at..end];
        self.at = end;
        return result;
    }

    fn reserveAllocation(self: *Decoder, length: usize) Error!void {
        const total = std.math.add(usize, self.allocated, length) catch return error.AllocationLimit;
        if (total > self.limits.max_allocation_bytes) return error.AllocationLimit;
        self.allocated = total;
    }

    fn varint(self: *Decoder) Error!u64 {
        var value: u64 = 0;
        var shift: u6 = 0;
        var count: usize = 0;
        while (count < 10) : (count += 1) {
            const part = try self.byte();
            if (count == 9 and part > 1) return error.IntegerOverflow;
            value |= @as(u64, part & 0x7f) << shift;
            if ((part & 0x80) == 0) {
                if (count > 0 and part == 0) return error.NonCanonicalVarint;
                return value;
            }
            if (count != 9) shift += 7;
        }
        return error.IntegerOverflow;
    }
};

pub fn encode(allocator: std.mem.Allocator, value: anytype, limits: Limits) Error![]u8 {
    var encoder = Encoder{ .allocator = allocator, .limits = limits };
    errdefer encoder.out.deinit(allocator);
    try encoder.bytes(magic);
    try encoder.byte(schema_version);
    try encodeValue(@TypeOf(value), &encoder, value, 0);
    return encoder.out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

pub fn decode(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) Error!Decoded(T) {
    if (bytes.len > limits.max_input_bytes) return error.InputTooLarge;
    if (bytes.len < magic.len + 1) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidMagic;
    if (bytes[magic.len] != schema_version) return error.UnsupportedVersion;

    var result = Decoded(T){
        .arena = std.heap.ArenaAllocator.init(allocator),
        .value = undefined,
    };
    errdefer result.arena.deinit();
    var decoder = Decoder{
        .arena = result.arena.allocator(),
        .bytes = bytes,
        .at = magic.len + 1,
        .limits = limits,
    };
    result.value = try decodeValue(T, &decoder, 0);
    if (decoder.at != bytes.len) return error.TrailingBytes;
    return result;
}

fn isByteSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.size == .slice and pointer.child == u8,
        else => false,
    };
}

fn encodeValue(comptime T: type, encoder: *Encoder, value: T, depth: usize) Error!void {
    @setEvalBranchQuota(200_000);
    try encoder.step(depth);
    if (comptime isByteSlice(T)) {
        if (value.len > encoder.limits.max_slice_length) return error.SliceTooLong;
        if (value.len > encoder.limits.max_work - encoder.work) return error.WorkLimit;
        encoder.work += value.len;
        try encoder.varint(@intCast(value.len));
        try encoder.bytes(value);
        return;
    }

    switch (@typeInfo(T)) {
        .void => {},
        .bool => try encoder.byte(if (value) 1 else 0),
        .int => |info| {
            if (info.bits > 64) return error.UnsupportedType;
            const U = std.meta.Int(.unsigned, info.bits);
            const narrowed: U = if (info.signedness == .signed) zigzag: {
                const raw: U = @bitCast(value);
                break :zigzag (raw << 1) ^ (0 -% (raw >> (info.bits - 1)));
            } else @intCast(value);
            try encoder.varint(@intCast(narrowed));
        },
        .@"enum" => |enum_info| {
            inline for (enum_info.fields, 0..) |field, ordinal| {
                if (value == @field(T, field.name)) {
                    try encoder.varint(ordinal);
                    return;
                }
            }
            unreachable;
        },
        .optional => |optional| {
            if (value) |payload| {
                try encoder.byte(1);
                try encodeValue(optional.child, encoder, payload, depth + 1);
            } else try encoder.byte(0);
        },
        .pointer => |pointer| {
            if (pointer.size == .one) {
                // A pointer is an ownership edge, not a stored machine address.
                // References between lexical identities remain Reference values.
                return encodeValue(pointer.child, encoder, value.*, depth + 1);
            }
            if (pointer.size != .slice) return error.UnsupportedType;
            if (value.len > encoder.limits.max_slice_length) return error.SliceTooLong;
            try encoder.varint(@intCast(value.len));
            for (value) |item| try encodeValue(pointer.child, encoder, item, depth + 1);
        },
        .array => |array| for (value) |item| try encodeValue(array.child, encoder, item, depth + 1),
        .@"struct" => |structure| {
            inline for (structure.fields) |field| {
                try encodeValue(field.type, encoder, @field(value, field.name), depth + 1);
            }
        },
        .@"union" => |union_info| {
            if (union_info.tag_type == null) return error.UnsupportedType;
            switch (value) {
                inline else => |payload, tag| {
                    inline for (union_info.fields, 0..) |field, ordinal| {
                        if (std.mem.eql(u8, field.name, @tagName(tag))) {
                            try encoder.varint(ordinal);
                            break;
                        }
                    }
                    try encodeValue(@TypeOf(payload), encoder, payload, depth + 1);
                },
            }
        },
        else => return error.UnsupportedType,
    }
}

fn decodeValue(comptime T: type, decoder: *Decoder, depth: usize) Error!T {
    @setEvalBranchQuota(200_000);
    try decoder.step(depth);
    if (comptime isByteSlice(T)) {
        const length = try decodeLength(decoder);
        if (length > decoder.limits.max_work - decoder.work) return error.WorkLimit;
        decoder.work += length;
        try decoder.reserveAllocation(length);
        const source = try decoder.take(length);
        const owned = decoder.arena.alloc(u8, length) catch return error.OutOfMemory;
        @memcpy(owned, source);
        return owned;
    }

    return switch (@typeInfo(T)) {
        .void => {},
        .bool => switch (try decoder.byte()) {
            0 => false,
            1 => true,
            else => error.InvalidBoolean,
        },
        .int => |info| integer: {
            if (info.bits > 64) return error.UnsupportedType;
            const encoded = try decoder.varint();
            const U = std.meta.Int(.unsigned, info.bits);
            if (encoded > std.math.maxInt(U)) return error.IntegerOverflow;
            const narrowed: U = @intCast(encoded);
            if (info.signedness == .signed) {
                const raw: U = (narrowed >> 1) ^ (0 -% (narrowed & 1));
                break :integer @bitCast(raw);
            }
            break :integer @intCast(narrowed);
        },
        .@"enum" => |enum_info| enumeration: {
            const encoded = try decoder.varint();
            inline for (enum_info.fields, 0..) |field, ordinal| {
                if (encoded == ordinal) break :enumeration @field(T, field.name);
            }
            return error.InvalidEnum;
        },
        .optional => |optional| optional_value: {
            const present = try decoder.byte();
            if (present == 0) break :optional_value null;
            if (present != 1) return error.InvalidBoolean;
            break :optional_value try decodeValue(optional.child, decoder, depth + 1);
        },
        .pointer => |pointer| slice: {
            if (pointer.size == .one) {
                try decoder.reserveAllocation(@sizeOf(pointer.child));
                const owned = decoder.arena.create(pointer.child) catch return error.OutOfMemory;
                owned.* = try decodeValue(pointer.child, decoder, depth + 1);
                break :slice owned;
            }
            if (pointer.size != .slice) return error.UnsupportedType;
            const length = try decodeLength(decoder);
            if (length > decoder.limits.max_work - decoder.work) return error.WorkLimit;
            const allocation = std.math.mul(usize, length, @sizeOf(pointer.child)) catch return error.AllocationLimit;
            try decoder.reserveAllocation(allocation);
            const owned = decoder.arena.alloc(pointer.child, length) catch return error.OutOfMemory;
            for (owned) |*item| item.* = try decodeValue(pointer.child, decoder, depth + 1);
            break :slice owned;
        },
        .array => |array| fixed: {
            var result: T = undefined;
            for (&result) |*item| item.* = try decodeValue(array.child, decoder, depth + 1);
            break :fixed result;
        },
        .@"struct" => |structure| structure_value: {
            var result: T = undefined;
            inline for (structure.fields) |field| {
                @field(result, field.name) = try decodeValue(field.type, decoder, depth + 1);
            }
            break :structure_value result;
        },
        .@"union" => |union_info| union_value: {
            if (union_info.tag_type == null) return error.UnsupportedType;
            const encoded = try decoder.varint();
            inline for (union_info.fields, 0..) |field, ordinal| {
                if (encoded == ordinal) {
                    const payload = try decodeValue(field.type, decoder, depth + 1);
                    break :union_value @unionInit(T, field.name, payload);
                }
            }
            return error.InvalidUnionTag;
        },
        else => error.UnsupportedType,
    };
}

fn decodeLength(decoder: *Decoder) Error!usize {
    const encoded = try decoder.varint();
    if (encoded > std.math.maxInt(usize)) return error.IntegerOverflow;
    const length: usize = @intCast(encoded);
    if (length > decoder.limits.max_slice_length) return error.SliceTooLong;
    return length;
}
