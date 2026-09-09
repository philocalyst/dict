//! Comptime-generated scalar tables.
//!
//! A table owns one compact column per nonzero scalar leaf in Row. Every
//! column uses one affine equation:
//!
//!     value(i) = base + step * i + packed_residual(i)
//!
//! Constant, identity, shifted identity, and ordinary packed columns are one
//! representation. The schema is generated from the row type; readers never
//! allocate and a top-level field accessor touches only that field's leaves.

const std = @import("std");
const wire = @import("wire.zig");

pub const magic = "L4TB";
pub const version: u16 = 1;
pub const header_size: usize = 16;
pub const descriptor_size: usize = 20;

pub const Error = wire.Error || error{
    InvalidSchema,
    InvalidEncoding,
    InvalidRow,
    IndexOutOfBounds,
    UnsupportedVersion,
};

const max_u32: u128 = std.math.maxInt(u32);
const min_i64: i128 = std.math.minInt(i64);
const max_i64: i128 = std.math.maxInt(i64);

fn validateSchema(comptime T: type) void {
    switch (@typeInfo(T)) {
        .bool => {},
        .int => |info| {
            if (info.signedness != .unsigned or info.bits > 32) @compileError("Table fields must be unsigned integers up to u32");
        },
        .@"enum" => |info| {
            const tag_info = @typeInfo(info.tag_type).int;
            if (tag_info.signedness != .unsigned or tag_info.bits > 32) @compileError("Table enum tags must be unsigned integers up to u32");
        },
        .optional => |info| {
            validateSchema(info.child);
        },
        .@"struct" => |info| {
            if (info.is_tuple) @compileError("Table rows cannot contain tuple structs");
            inline for (info.fields) |field| {
                if (field.is_comptime) @compileError("Table rows cannot contain comptime fields");
                validateSchema(field.type);
            }
        },
        else => @compileError("Table rows contain an unsupported field type"),
    }
}

fn leafCount(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            var count: usize = 0;
            inline for (info.fields) |field| count += leafCount(field.type);
            break :blk count;
        },
        .optional => |info| 1 + leafCount(info.child),
        else => 1,
    };
}

fn scalarValue(comptime T: type, value: T) u32 {
    return switch (@typeInfo(T)) {
        .bool => @intFromBool(value),
        .int => @intCast(value),
        .@"enum" => @intCast(@intFromEnum(value)),
        else => unreachable,
    };
}

fn scalarMax(comptime T: type) u32 {
    return switch (@typeInfo(T)) {
        .bool => 1,
        .int => @intCast(std.math.maxInt(T)),
        .@"enum" => |info| @intCast(std.math.maxInt(info.tag_type)),
        else => unreachable,
    };
}

fn leafValue(comptime T: type, value: *const T, comptime wanted: usize, start: usize) u32 {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.fields, 0..) |field, field_index| {
                const at = start + structFieldStart(T, field_index);
                const count = leafCount(field.type);
                if (wanted < at + count)
                    return leafValue(field.type, &@field(value.*, field.name), wanted, at);
            }
            unreachable;
        },
        .optional => |info| {
            if (wanted == start) return @intFromBool(value.* != null);
            if (value.*) |*present| return leafValue(info.child, present, wanted, start + 1);
            return 0;
        },
        else => {
            return scalarValue(T, value.*);
        },
    }
}

fn fieldStart(comptime T: type, comptime field: std.meta.FieldEnum(T)) usize {
    return structFieldStart(T, @intFromEnum(field));
}

fn structFieldStart(comptime T: type, comptime wanted: usize) usize {
    if (wanted == 0) return 0;
    const fields = @typeInfo(T).@"struct".fields;
    return structFieldStart(T, wanted - 1) + leafCount(fields[wanted - 1].type);
}

fn decodeScalar(comptime T: type, raw: u32) Error!T {
    switch (@typeInfo(T)) {
        .bool => {
            if (raw > 1) return error.InvalidValue;
            return raw != 0;
        },
        .int => {
            if (@as(u64, raw) > @as(u64, scalarMax(T))) return error.InvalidValue;
            return @intCast(raw);
        },
        .@"enum" => |info| {
            const tag = std.math.cast(info.tag_type, raw) orelse return error.InvalidValue;
            if (info.is_exhaustive) return std.enums.fromInt(T, tag) orelse return error.InvalidValue;
            return @enumFromInt(tag);
        },
        else => unreachable,
    }
}

fn decodeValues(comptime T: type, out: *T, values: []const u32, comptime start: usize) Error!void {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.fields, 0..) |field, index| {
                try decodeValues(field.type, &@field(out.*, field.name), values, start + structFieldStart(T, index));
            }
        },
        .optional => |info| {
            const present = values[start];
            if (present > 1) return error.InvalidValue;
            if (present == 0) {
                for (values[start + 1 .. start + 1 + leafCount(info.child)]) |raw| if (raw != 0) return error.InvalidValue;
                out.* = null;
            } else {
                var child: info.child = undefined;
                try decodeValues(info.child, &child, values, start + 1);
                out.* = child;
            }
        },
        else => out.* = try decodeScalar(T, values[start]),
    }
}

fn floorDiv(a: i128, b: i128) i128 {
    const q = @divTrunc(a, b);
    const r = @rem(a, b);
    if (r != 0 and ((r < 0) != (b < 0))) return q - 1;
    return q;
}

fn ceilDiv(a: i128, b: i128) i128 {
    return -floorDiv(-a, b);
}

fn bitsFor(value: u128) u8 {
    if (value == 0) return 0;
    var bits: u8 = 0;
    var remaining = value;
    while (remaining != 0) : (bits += 1) remaining >>= 1;
    return bits;
}

fn packedBytes(count: usize, width: u8) Error!usize {
    if (width > 64) return error.InvalidValue;
    const bits = std.math.mul(usize, count, width) catch return error.Overflow;
    if (bits == 0) return 0;
    return (std.math.add(usize, bits, 7) catch return error.Overflow) / 8;
}

const Candidate = struct {
    base: i64,
    step: i64,
    width: u8,
    payload_bytes: usize,
};

fn candidateForRows(comptime Row: type, rows: []const Row, comptime id: usize, step: i128) Error!?Candidate {
    if (step < min_i64 or step > max_i64) return null;
    if (rows.len == 0) return null;
    var base: i128 = std.math.maxInt(i128);
    for (rows, 0..) |row, index| {
        const value: i128 = leafValue(Row, &row, id, 0);
        const prediction = value - step * @as(i128, @intCast(index));
        base = @min(base, prediction);
    }
    if (base < min_i64 or base > max_i64) return null;
    var maximum: u128 = 0;
    for (rows, 0..) |row, index| {
        const value: i128 = leafValue(Row, &row, id, 0);
        const residual = value - base - step * @as(i128, @intCast(index));
        if (residual < 0 or residual > max_u32) return null;
        maximum = @max(maximum, @as(u128, @intCast(residual)));
    }
    const width = bitsFor(maximum);
    return .{ .base = @intCast(base), .step = @intCast(step), .width = width, .payload_bytes = try packedBytes(rows.len, width) };
}

fn betterCandidate(candidate: Candidate, best: Candidate) bool {
    if (candidate.payload_bytes != best.payload_bytes) return candidate.payload_bytes < best.payload_bytes;
    if ((candidate.step == 0) != (best.step == 0)) return candidate.step == 0;
    return false;
}

fn chooseCandidate(comptime Row: type, rows: []const Row, comptime id: usize) Error!?Candidate {
    if (rows.len == 0) return null;
    var nonzero = false;
    for (rows) |row| {
        if (leafValue(Row, &row, id, 0) != 0) nonzero = true;
    }
    if (!nonzero) return null;
    var best = (try candidateForRows(Row, rows, id, 0)) orelse return error.InvalidValue;
    if (rows.len > 1) {
        const first: i128 = leafValue(Row, &rows[0], id, 0);
        const last: i128 = leafValue(Row, &rows[rows.len - 1], id, 0);
        const denominator: i128 = @intCast(rows.len - 1);
        const slope_floor = floorDiv(last - first, denominator);
        const slope_ceil = ceilDiv(last - first, denominator);
        for ([_]i128{ slope_floor, slope_ceil }) |slope| {
            if (try candidateForRows(Row, rows, id, slope)) |candidate| {
                if (betterCandidate(candidate, best)) best = candidate;
            }
        }
    }
    return best;
}

fn validateAffineEnvelope(base: i64, step: i64, row_count: usize, width: u8) Error!void {
    if (width > 32) return error.InvalidEncoding;
    if (row_count == 0) return;
    const last_index: i128 = @intCast(row_count - 1);
    const product = @as(i128, step) * last_index;
    if (product < min_i64 or product > max_i64) return error.Overflow;
    const first = @as(i128, base);
    const last = first + product;
    if (last < min_i64 or last > max_i64) return error.Overflow;
    const residual_max: i128 = if (width == 0) 0 else (@as(i128, 1) << @as(u7, @intCast(width))) - 1;
    const affine_min = @min(first, last);
    const affine_max = @max(first, last);
    if (affine_min < min_i64 or affine_max > max_i64 - residual_max)
        return error.Overflow;
}

fn validateTail(bytes: []const u8, bit_count: usize) Error!void {
    if (bit_count == 0) return;
    const remainder = bit_count % 8;
    if (remainder == 0) return;
    const mask = @as(u8, @intCast((@as(u16, 1) << @as(u4, @intCast(remainder))) - 1));
    if ((bytes[bytes.len - 1] & ~mask) != 0) return error.InvalidEncoding;
}

pub fn Table(comptime Row: type) type {
    comptime {
        if (@typeInfo(Row) != .@"struct") @compileError("Table(Row) requires a struct row type");
        validateSchema(Row);
        if (leafCount(Row) > std.math.maxInt(u16)) @compileError("Table row schema has too many scalar leaves");
    }

    const schema_leaf_count = leafCount(Row);

    return struct {
        const Self = @This();

        pub const Owned = struct {
            allocator: std.mem.Allocator,
            bytes: []u8,
            row_count: usize,

            pub fn deinit(self: *Owned) void {
                self.allocator.free(self.bytes);
                self.* = undefined;
            }
        };

        const Lane = struct {
            active: bool,
            width: u8,
            base: i64,
            step: i64,
            payload: []const u8,
        };

        pub const View = struct {
            pub const bytes_magic = magic;
            bytes: []const u8,
            row_count: usize,
            descriptor_count: usize,
            payload_offset: usize,
            lanes: [schema_leaf_count]Lane,

            const ViewSelf = @This();

            fn laneValue(lane: Lane, index: usize, residual: u64) Error!u32 {
                // `open` proves both affine endpoints plus the maximum
                // residual fit i64. Public row/field reads prove
                // `index < row_count`, so this straight-line reconstruction
                // cannot overflow; only the final domain cast remains
                // untrusted data validation.
                const affine = lane.base + lane.step * @as(i64, @intCast(index));
                const value = affine + @as(i64, @intCast(residual));
                return std.math.cast(u32, value) orelse error.InvalidValue;
            }

            fn readLane(lane: Lane, index: usize) Error!u32 {
                const bit = try wire.mul(index, lane.width);
                return laneValue(lane, index, try wire.readPacked(lane.payload, bit, lane.width));
            }

            fn readLeaf(self: *const ViewSelf, index: usize, comptime id: usize) Error!u32 {
                const lane = self.lanes[id];
                if (!lane.active) return 0;
                return readLane(lane, index);
            }

            fn readAll(self: *const ViewSelf, index: usize, values: *[schema_leaf_count]u32, residuals: ?*[schema_leaf_count]u32) Error!void {
                @memset(values, 0);
                if (residuals) |out| @memset(out, 0);
                inline for (0..schema_leaf_count) |id| {
                    const lane = self.lanes[id];
                    if (lane.active) {
                        const residual = try wire.readPacked(lane.payload, try wire.mul(index, lane.width), lane.width);
                        values[id] = try laneValue(lane, index, residual);
                        if (residuals) |out| out.*[id] = std.math.cast(u32, residual) orelse return error.Overflow;
                    }
                }
            }

            fn decodeField(self: *const ViewSelf, index: usize, comptime T: type, out: *T, comptime start: usize) Error!void {
                switch (@typeInfo(T)) {
                    .@"struct" => |info| {
                        inline for (info.fields, 0..) |field_info, field_index| {
                            try self.decodeField(index, field_info.type, &@field(out.*, field_info.name), start + structFieldStart(T, field_index));
                        }
                    },
                    .optional => |info| {
                        const present = try self.readLeaf(index, start);
                        if (present > 1) return error.InvalidValue;
                        if (present == 0) {
                            inline for (0..comptime leafCount(info.child)) |offset| if (try self.readLeaf(index, start + 1 + offset) != 0) return error.InvalidValue;
                            out.* = null;
                        } else {
                            var child: info.child = undefined;
                            try self.decodeField(index, info.child, &child, start + 1);
                            out.* = child;
                        }
                    },
                    else => out.* = try decodeScalar(T, try self.readLeaf(index, start)),
                }
            }

            pub fn open(bytes: []const u8) Error!ViewSelf {
                if (bytes.len < header_size) return error.Truncated;
                if (!std.mem.eql(u8, bytes[0..4], magic)) return error.InvalidEncoding;
                if (try wire.readInt(u16, bytes, 4) != version) return error.UnsupportedVersion;
                const descriptor_count = @as(usize, try wire.readInt(u16, bytes, 6));
                const row_count = @as(usize, try wire.readInt(u32, bytes, 8));
                if (try wire.readInt(u32, bytes, 12) != 0) return error.InvalidEncoding;
                if (descriptor_count > schema_leaf_count) return error.InvalidEncoding;
                if (row_count == 0 and descriptor_count != 0) return error.InvalidEncoding;

                const descriptor_end = try wire.add(header_size, try wire.mul(descriptor_count, descriptor_size));
                if (descriptor_end > bytes.len) return error.Truncated;
                var payload_at = descriptor_end;
                var previous_id: ?u16 = null;
                var lanes: [schema_leaf_count]Lane = undefined;
                for (&lanes) |*lane| lane.* = .{ .active = false, .width = 0, .base = 0, .step = 0, .payload = &.{} };
                for (0..descriptor_count) |index| {
                    const descriptor_at = try wire.add(header_size, try wire.mul(index, descriptor_size));
                    const id = try wire.readInt(u16, bytes, descriptor_at);
                    const width = bytes[descriptor_at + 2];
                    if (bytes[descriptor_at + 3] != 0) return error.InvalidEncoding;
                    if (id >= schema_leaf_count or (previous_id != null and id <= previous_id.?)) return error.InvalidEncoding;
                    previous_id = id;
                    const base = try wire.readInt(i64, bytes, descriptor_at + 4);
                    const step = try wire.readInt(i64, bytes, descriptor_at + 12);
                    try validateAffineEnvelope(base, step, row_count, width);
                    const payload_len = try packedBytes(row_count, width);
                    const payload = try wire.bytesAt(bytes, payload_at, payload_len);
                    try validateTail(payload, try wire.mul(row_count, width));
                    const lane_index: usize = id;
                    lanes[lane_index] = .{ .active = true, .width = width, .base = base, .step = step, .payload = payload };
                    payload_at = try wire.add(payload_at, payload_len);
                }
                if (payload_at != bytes.len) return error.TrailingBytes;
                return .{ .bytes = bytes, .row_count = row_count, .descriptor_count = descriptor_count, .payload_offset = descriptor_end, .lanes = lanes };
            }

            pub fn len(self: *const ViewSelf) usize {
                return self.row_count;
            }

            pub fn row(self: *const ViewSelf, index: usize) Error!Row {
                if (index >= self.row_count) return error.IndexOutOfBounds;
                var result: Row = undefined;
                // A row is the root field of the same generated projection.
                // Decode directly into its result instead of materializing a
                // scalar array and walking the schema a second time.
                try self.decodeField(index, Row, &result, 0);
                return result;
            }

            pub fn field(self: *const ViewSelf, index: usize, comptime field_name: std.meta.FieldEnum(Row)) Error!std.meta.fields(Row)[@intFromEnum(field_name)].type {
                if (index >= self.row_count) return error.IndexOutOfBounds;
                const FieldType = std.meta.fields(Row)[@intFromEnum(field_name)].type;
                var result: FieldType = undefined;
                try self.decodeField(index, FieldType, &result, fieldStart(Row, field_name));
                return result;
            }

            pub fn verify(self: *const ViewSelf) Error!void {
                var nonzero: [schema_leaf_count]bool = undefined;
                var minimum: [schema_leaf_count]u32 = undefined;
                var maximum: [schema_leaf_count]u32 = undefined;
                @memset(&nonzero, false);
                for (&minimum) |*value| value.* = std.math.maxInt(u32);
                @memset(&maximum, 0);
                for (0..self.row_count) |index| {
                    var values: [schema_leaf_count]u32 = undefined;
                    var residuals: [schema_leaf_count]u32 = undefined;
                    try self.readAll(index, &values, &residuals);
                    var result: Row = undefined;
                    try decodeValues(Row, &result, &values, 0);
                    inline for (0..schema_leaf_count) |id| {
                        if (self.lanes[id].active) {
                            if (values[id] != 0) nonzero[id] = true;
                            minimum[id] = @min(minimum[id], residuals[id]);
                            maximum[id] = @max(maximum[id], residuals[id]);
                        }
                    }
                }
                inline for (0..schema_leaf_count) |id| {
                    if (self.lanes[id].active) {
                        if (!nonzero[id]) return error.InvalidEncoding;
                        if (minimum[id] != 0) return error.InvalidEncoding;
                        if (bitsFor(maximum[id]) != self.lanes[id].width) return error.InvalidEncoding;
                    }
                }
            }
        };

        pub fn build(allocator: std.mem.Allocator, rows: []const Row) Error!Owned {
            if (rows.len > std.math.maxInt(u32)) return error.Overflow;
            var candidates = allocator.alloc(?Candidate, schema_leaf_count) catch return error.OutOfMemory;
            defer allocator.free(candidates);
            @memset(candidates, null);

            var active: usize = 0;
            inline for (0..schema_leaf_count) |id| {
                candidates[id] = try chooseCandidate(Row, rows, id);
                if (candidates[id] != null) active += 1;
            }
            const descriptor_bytes = try wire.mul(active, descriptor_size);
            var total = try wire.add(header_size, descriptor_bytes);
            for (candidates) |candidate| {
                if (candidate) |value| total = try wire.add(total, value.payload_bytes);
            }

            var bytes = allocator.alloc(u8, total) catch return error.OutOfMemory;
            errdefer allocator.free(bytes);
            @memset(bytes, 0);
            @memcpy(bytes[0..4], magic);
            try wire.writeInt(u16, bytes, 4, version);
            try wire.writeInt(u16, bytes, 6, @intCast(active));
            try wire.writeInt(u32, bytes, 8, @intCast(rows.len));
            try wire.writeInt(u32, bytes, 12, 0);

            var descriptor_index: usize = 0;
            var payload_at = try wire.add(header_size, descriptor_bytes);
            inline for (0..schema_leaf_count) |id| {
                if (candidates[id]) |value| {
                    const descriptor_at = try wire.add(header_size, try wire.mul(descriptor_index, descriptor_size));
                    try wire.writeInt(u16, bytes, descriptor_at, @intCast(id));
                    bytes[descriptor_at + 2] = value.width;
                    bytes[descriptor_at + 3] = 0;
                    try wire.writeInt(i64, bytes, descriptor_at + 4, value.base);
                    try wire.writeInt(i64, bytes, descriptor_at + 12, value.step);
                    for (rows, 0..) |row, row_index| {
                        const raw: i128 = leafValue(Row, &row, id, 0);
                        const residual = raw - @as(i128, value.base) - @as(i128, value.step) * @as(i128, @intCast(row_index));
                        if (residual < 0 or residual > max_u32) return error.InvalidValue;
                        try wire.writePacked(bytes[payload_at .. payload_at + value.payload_bytes], try wire.mul(row_index, value.width), value.width, @intCast(residual));
                    }
                    payload_at = try wire.add(payload_at, value.payload_bytes);
                    descriptor_index += 1;
                }
            }
            return .{ .allocator = allocator, .bytes = bytes, .row_count = rows.len };
        }
    };
}

test "table round-trips affine, nested, optional, enum, and bool leaves" {
    const State = enum(u8) { cold, hot };
    const Endpoint = struct { kind: u8, rank: u32 };
    const Row = struct { endpoint: Endpoint, optional_rank: ?u32, state: State, enabled: bool };
    const rows = [_]Row{
        .{ .endpoint = .{ .kind = 1, .rank = 0xffff_ffff }, .optional_rank = null, .state = .cold, .enabled = false },
        .{ .endpoint = .{ .kind = 2, .rank = 0xffff_fffe }, .optional_rank = 7, .state = .hot, .enabled = true },
        .{ .endpoint = .{ .kind = 3, .rank = 0xffff_fffd }, .optional_rank = 0, .state = .hot, .enabled = false },
    };
    var owned = try Table(Row).build(std.testing.allocator, &rows);
    defer owned.deinit();
    var view = try Table(Row).View.open(owned.bytes);
    try std.testing.expectEqual(rows.len, view.len());
    // Field and row reads remain checked and allocation-free before the
    // caller elects to run the semantic pass.
    try std.testing.expectEqual(rows[0], try view.row(0));
    try std.testing.expectEqual(@as(?u32, null), try view.field(0, .optional_rank));
    try view.verify();
    for (rows, 0..) |expected, index| try std.testing.expectEqual(expected, try view.row(index));
    try std.testing.expectEqual(@as(?u32, 7), try view.field(1, .optional_rank));
    try std.testing.expectEqual(@as(u32, 0xffff_fffd), (try view.field(2, .endpoint)).rank);
}

test "table round-trips varied generated rows" {
    const Row = struct { small: u8, full: u32, enabled: bool, maybe: ?u16 };
    var rows: [47]Row = undefined;
    var state: u32 = 0x9e37_79b9;
    for (&rows) |*row| {
        state = state *% 1_664_525 +% 1_013_904_223;
        row.* = .{
            .small = @truncate(state),
            .full = state ^ (state >> 7),
            .enabled = (state & 1) != 0,
            .maybe = if ((state & 4) != 0) @truncate(state >> 8) else null,
        };
    }
    var owned = try Table(Row).build(std.testing.allocator, &rows);
    defer owned.deinit();
    var view = try Table(Row).View.open(owned.bytes);
    try view.verify();
    for (rows, 0..) |expected, index| {
        try std.testing.expectEqual(expected, try view.row(index));
        try std.testing.expectEqual(expected.full, try view.field(index, .full));
    }
}

test "table charges representative five-leaf metadata" {
    const Row = struct { a: u32, b: u32, c: u32, d: bool, e: u32 };
    const rows = [_]Row{
        .{ .a = 1, .b = 7, .c = 11, .d = false, .e = 4 },
        .{ .a = 3, .b = 8, .c = 13, .d = true, .e = 5 },
        .{ .a = 2, .b = 10, .c = 12, .d = false, .e = 7 },
    };
    var owned = try Table(Row).build(std.testing.allocator, &rows);
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 121), owned.bytes.len);
    try std.testing.expectEqual(@as(usize, 240), @sizeOf(Table(Row).View));
}

test "table chooses the complete three-slope minimum" {
    const Row = struct { value: u32 };
    // This deliberately independent oracle works on the leaf values rather
    // than Table's schema walker.  It checks the complete encoded payload
    // size for zero, endpoint-floor, and endpoint-ceil slopes, including the
    // step-zero tie rule.
    const Oracle = struct {
        const OracleCandidate = struct { base: i64, step: i64, width: u8, payload_bytes: usize };

        fn oracleFloorDiv(a: i128, b: i128) i128 {
            const q = @divTrunc(a, b);
            const r = @rem(a, b);
            if (r != 0 and ((r < 0) != (b < 0))) return q - 1;
            return q;
        }

        fn oracleCeilDiv(a: i128, b: i128) i128 {
            return -oracleFloorDiv(-a, b);
        }

        fn candidate(values: []const u32, step: i128) ?OracleCandidate {
            if (values.len == 0 or step < std.math.minInt(i64) or step > std.math.maxInt(i64)) return null;
            var base: i128 = std.math.maxInt(i128);
            for (values, 0..) |raw, index| {
                const prediction = @as(i128, raw) - step * @as(i128, @intCast(index));
                base = @min(base, prediction);
            }
            if (base < std.math.minInt(i64) or base > std.math.maxInt(i64)) return null;
            var maximum: u128 = 0;
            for (values, 0..) |raw, index| {
                const residual = @as(i128, raw) - base - step * @as(i128, @intCast(index));
                if (residual < 0 or residual > std.math.maxInt(u32)) return null;
                maximum = @max(maximum, @as(u128, @intCast(residual)));
            }
            var width: u8 = 0;
            var remaining = maximum;
            while (remaining != 0) : (width += 1) remaining >>= 1;
            return .{
                .base = @intCast(base),
                .step = @intCast(step),
                .width = width,
                .payload_bytes = (values.len * width + 7) / 8,
            };
        }

        fn better(candidate_value: OracleCandidate, best: OracleCandidate) bool {
            if (candidate_value.payload_bytes != best.payload_bytes)
                return candidate_value.payload_bytes < best.payload_bytes;
            if ((candidate_value.step == 0) != (best.step == 0)) return candidate_value.step == 0;
            return false;
        }

        fn choose(values: []const u32) OracleCandidate {
            var best = candidate(values, 0).?;
            if (values.len > 1) {
                const denominator: i128 = @intCast(values.len - 1);
                const delta: i128 = @as(i128, values[values.len - 1]) - values[0];
                const floor = oracleFloorDiv(delta, denominator);
                const ceil = oracleCeilDiv(delta, denominator);
                for ([_]i128{ floor, ceil }) |step| {
                    if (candidate(values, step)) |current| {
                        if (better(current, best)) best = current;
                    }
                }
            }
            return best;
        }
    };
    const Check = struct {
        fn run(values: []const u32) !void {
            var rows: [64]Row = undefined;
            try std.testing.expect(values.len <= rows.len);
            for (values, 0..) |value, index| rows[index] = .{ .value = value };
            var owned = try Table(Row).build(std.testing.allocator, rows[0..values.len]);
            defer owned.deinit();
            var view = try Table(Row).View.open(owned.bytes);
            const expected = Oracle.choose(values);
            const lane = view.lanes[0];
            try std.testing.expectEqual(expected.base, lane.base);
            try std.testing.expectEqual(expected.step, lane.step);
            try std.testing.expectEqual(expected.width, lane.width);
            try std.testing.expectEqual(expected.payload_bytes, lane.payload.len);
            try view.verify();
            for (values, 0..) |value, index| try std.testing.expectEqual(Row{ .value = value }, try view.row(index));
        }
    };
    const cases = [_][]const u32{
        &[_]u32{ 0, 0, 3, 8 },
        &[_]u32{ 0, 0, 0, 4 },
        &[_]u32{ 5, 7, 6 },
        &[_]u32{ 0xffff_ffff, 0xffff_fffe, 0xffff_fffd, 0xffff_fffc },
        &[_]u32{ 0xffff_ffff, 1, 0xffff_fffe, 7, 0 },
    };
    for (cases) |values| try Check.run(values);

    var random: [37]u32 = undefined;
    var state: u32 = 0x243f_6a88;
    for (&random, 0..) |*value, index| {
        state = state *% 1_664_525 +% 1_013_904_223;
        value.* = state ^ (state >> 11);
        if (index % 7 == 0) value.* = std.math.maxInt(u32) - @as(u32, @intCast(index));
    }
    try Check.run(&random);
}

test "table accepts an empty zero-descriptor table" {
    const Row = struct { value: u32 };
    const rows: []const Row = &.{};
    var owned = try Table(Row).build(std.testing.allocator, rows);
    defer owned.deinit();
    var view = try Table(Row).View.open(owned.bytes);
    try std.testing.expectEqual(@as(usize, 0), view.len());
    try view.verify();
    try std.testing.expectError(error.IndexOutOfBounds, view.row(0));
    try std.testing.expectError(error.IndexOutOfBounds, view.field(0, .value));
}

test "table field reads only the requested lowered lane" {
    const Row = struct { first: u32, second: u32 };
    const rows = [_]Row{ .{ .first = 7, .second = 0 }, .{ .first = 8, .second = 1 } };
    var owned = try Table(Row).build(std.testing.allocator, &rows);
    defer owned.deinit();
    var view = try Table(Row).View.open(owned.bytes);
    // Make the unrelated second lane fail its checked u32 cast after open.
    // A first-field query must not touch it; querying second still reports the
    // malformed scalar.
    view.lanes[1].base = @as(i64, std.math.maxInt(u32)) + 1;
    try std.testing.expectEqual(@as(u32, 7), try view.field(0, .first));
    try std.testing.expectError(error.InvalidValue, view.field(0, .second));
}

test "table rejects hostile affine envelopes before reading payloads" {
    const Row = struct { value: u32 };
    const Make = struct {
        fn bytes(row_count: u32, width: u8, base: i64, step: i64) [header_size + descriptor_size]u8 {
            var result = [_]u8{0} ** (header_size + descriptor_size);
            @memcpy(result[0..4], magic);
            wire.writeInt(u16, &result, 4, version) catch unreachable;
            wire.writeInt(u16, &result, 6, 1) catch unreachable;
            wire.writeInt(u32, &result, 8, row_count) catch unreachable;
            wire.writeInt(u32, &result, 12, 0) catch unreachable;
            wire.writeInt(u16, &result, header_size, 0) catch unreachable;
            result[header_size + 2] = width;
            wire.writeInt(i64, &result, header_size + 4, base) catch unreachable;
            wire.writeInt(i64, &result, header_size + 12, step) catch unreachable;
            return result;
        }
    };
    const huge_product = Make.bytes(std.math.maxInt(u32), 0, 0, std.math.maxInt(i64));
    try std.testing.expectError(error.Overflow, Table(Row).View.open(&huge_product));
    const positive_edge = Make.bytes(2, 1, std.math.maxInt(i64), 1);
    try std.testing.expectError(error.Overflow, Table(Row).View.open(&positive_edge));
    const negative_edge = Make.bytes(2, 0, std.math.minInt(i64), -1);
    try std.testing.expectError(error.Overflow, Table(Row).View.open(&negative_edge));
}

test "table rejects noncanonical tails" {
    const Row = struct { flag: bool, optional_value: ?u8 };
    const rows = [_]Row{
        .{ .flag = true, .optional_value = null },
        .{ .flag = false, .optional_value = 4 },
        .{ .flag = true, .optional_value = 5 },
    };
    var owned = try Table(Row).build(std.testing.allocator, &rows);
    defer owned.deinit();
    var bad_tail = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_tail);
    bad_tail[bad_tail.len - 1] |= 0x80;
    try std.testing.expectError(error.InvalidEncoding, Table(Row).View.open(bad_tail));
}

test "table verify rejects invalid exhaustive enums and absent optional values" {
    const State = enum(u8) { first = 3, second = 9 };
    const Row = struct { state: State, optional_state: ?State };
    const rows = [_]Row{
        .{ .state = .first, .optional_state = null },
        .{ .state = .second, .optional_state = .first },
        .{ .state = .first, .optional_state = null },
    };
    var enum_owned = try Table(Row).build(std.testing.allocator, &rows);
    defer enum_owned.deinit();
    var enum_view = try Table(Row).View.open(enum_owned.bytes);
    try std.testing.expectEqual(rows[0], try enum_view.row(0));
    try std.testing.expectEqual(@as(?State, .first), try enum_view.field(1, .optional_state));
    try wire.writePacked(@constCast(enum_view.lanes[0].payload), 0, enum_view.lanes[0].width, 1);
    try std.testing.expectError(error.InvalidValue, enum_view.verify());

    const zero_bytes = try std.testing.allocator.dupe(u8, enum_owned.bytes);
    defer std.testing.allocator.free(zero_bytes);
    try wire.writeInt(i64, zero_bytes, header_size + 4, 0);
    var zero_view = try Table(Row).View.open(zero_bytes);
    try std.testing.expectError(error.InvalidValue, zero_view.verify());

    var optional_owned = try Table(Row).build(std.testing.allocator, &rows);
    defer optional_owned.deinit();
    var optional_view = try Table(Row).View.open(optional_owned.bytes);
    // The optional value lane starts at leaf 2.  Row zero is absent, so a
    // nonzero residual must be rejected even though it is a valid enum tag
    // in the present case.
    try wire.writePacked(@constCast(optional_view.lanes[2].payload), 0, optional_view.lanes[2].width, 1);
    try std.testing.expectError(error.InvalidValue, optional_view.verify());

    const OpenState = enum(u8) { named = 4, _ };
    const OpenRow = struct { state: OpenState };
    const open_rows = [_]OpenRow{ .{ .state = .named }, .{ .state = @enumFromInt(200) } };
    var open_owned = try Table(OpenRow).build(std.testing.allocator, &open_rows);
    defer open_owned.deinit();
    var open_view = try Table(OpenRow).View.open(open_owned.bytes);
    try open_view.verify();
    try std.testing.expectEqual(open_rows[1], try open_view.row(1));
}

test "table verify rejects a non-lower-envelope base" {
    const Row = struct { value: u32 };
    // The step-zero candidate wins the payload-size tie with the endpoint
    // candidate, producing residuals [0, 2, 1] at base=5 and width=2.
    const rows = [_]Row{ .{ .value = 5 }, .{ .value = 7 }, .{ .value = 6 } };
    var owned = try Table(Row).build(std.testing.allocator, &rows);
    defer owned.deinit();
    const bad = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad);
    const descriptor_at = header_size;
    try wire.writeInt(i64, bad, descriptor_at + 4, 4);
    var view = try Table(Row).View.open(bad);
    // Rebase the lane by -1 and keep the same two-bit width.  The decoded
    // values remain in-domain, but every residual is now positive.
    try wire.writePacked(@constCast(view.lanes[0].payload), 0, view.lanes[0].width, 1);
    try wire.writePacked(@constCast(view.lanes[0].payload), 2, view.lanes[0].width, 3);
    try wire.writePacked(@constCast(view.lanes[0].payload), 4, view.lanes[0].width, 2);
    try std.testing.expectError(error.InvalidEncoding, view.verify());
}

test "table allocation failures clean up" {
    const Row = struct { left: u32, right: ?u16 };
    const rows = [_]Row{ .{ .left = 1, .right = null }, .{ .left = 2, .right = 3 } };
    const Build = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var owned = try Table(Row).build(allocator, &rows);
            owned.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Build.run, .{});
}
