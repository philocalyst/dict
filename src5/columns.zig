const std = @import("std");
const bytes = @import("bytes.zig");
const model = @import("model.zig");

pub const Error = bytes.Error || error{
    InvalidType,
    InvalidValue,
    IndexOutOfBounds,
    OutputTooSmall,
    OutOfDomain,
    OutOfMemory,
    UnresolvedDomain,
};

const header_size: usize = 4;

pub const Limits = struct {
    max_rows: usize = 16 * 1024 * 1024,
    max_cells: usize = 64 * 1024 * 1024,
};

fn isReference(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"enum" => @hasDecl(T, "reference_domain"),
        else => false,
    };
}

pub fn Shape(comptime T: type) type {
    return struct {
        pub const width: usize = switch (@typeInfo(T)) {
            .int, .bool, .@"enum" => 1,
            .@"struct" => |info| total: {
                var count: usize = 0;
                for (info.fields) |field| count += Shape(field.type).width;
                break :total count;
            },
            .array => |info| info.len * Shape(info.child).width,
            .optional => |info| 1 + Shape(info.child).width,
            .@"union" => |info| total: {
                if (info.tag_type == null) @compileError("Records requires a tagged union");
                var payload_width: usize = 0;
                for (info.fields) |field| payload_width = @max(payload_width, Shape(field.type).width);
                break :total 1 + payload_width;
            },
            .void => 0,
            else => @compileError("unsupported Records field type: " ++ @typeName(T)),
        };

        pub fn fieldOffset(comptime wanted: std.meta.FieldEnum(T)) usize {
            var offset: usize = 0;
            inline for (@typeInfo(T).@"struct".fields, 0..) |field, index| {
                if (@intFromEnum(wanted) == index) return offset;
                offset += Shape(field.type).width;
            }
            unreachable;
        }
    };
}

fn encodeScalar(value: anytype) u64 {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .int => |info| integer: {
            if (info.bits == 0) break :integer 0;
            const U = std.meta.Int(.unsigned, info.bits);
            const raw: U = if (info.signedness == .signed) @bitCast(value) else value;
            const ordered = if (info.signedness == .signed) raw ^ (@as(U, 1) << (info.bits - 1)) else raw;
            break :integer @intCast(ordered);
        },
        .bool => @intFromBool(value),
        .@"enum" => |info| encodeScalar(@as(info.tag_type, @intFromEnum(value))),
        else => unreachable,
    };
}

fn decodeScalar(comptime T: type, raw: u64, domains: anytype) Error!T {
    const value: T = switch (@typeInfo(T)) {
        .int => |info| {
            if (info.bits == 0) {
                if (raw != 0) return error.InvalidValue;
                return 0;
            }
            const U = std.meta.Int(.unsigned, info.bits);
            if (raw > std.math.maxInt(U)) return error.InvalidValue;
            const ordered: U = @intCast(raw);
            const bits = if (info.signedness == .signed) ordered ^ (@as(U, 1) << (info.bits - 1)) else ordered;
            if (info.signedness == .signed) return @bitCast(bits);
            return @intCast(bits);
        },
        .bool => switch (raw) {
            0 => false,
            1 => true,
            else => return error.InvalidValue,
        },
        .@"enum" => |info| enumeration: {
            const tag_value = try decodeScalar(info.tag_type, raw, {});
            break :enumeration std.enums.fromInt(T, tag_value) orelse return error.InvalidValue;
        },
        else => unreachable,
    };
    if (comptime isReference(T) and @TypeOf(domains) != void) {
        const count = domains.countForVerify(T.reference_domain) catch |failure| switch (failure) {
            error.UnresolvedDomain => return error.UnresolvedDomain,
        };
        if (@intFromEnum(value) >= count) return error.OutOfDomain;
    }
    return value;
}

const TransferMode = enum { write, read, verify };

fn transfer(comptime T: type, comptime mode: TransferMode, input: if (mode == .write) T else void, access: anytype, cursor: *usize) @TypeOf(access).TransferError!T {
    return switch (@typeInfo(T)) {
        .int, .bool, .@"enum" => scalar: {
            const value = if (mode == .write) input else try decodeScalar(T, try access.read(cursor.*), access.domains);
            if (mode == .write) try access.write(cursor.*, encodeScalar(value));
            cursor.* += 1;
            break :scalar value;
        },
        .@"struct" => |info| product: {
            var result: T = if (mode == .write) input else undefined;
            inline for (info.fields) |field| {
                @field(result, field.name) = try transfer(field.type, mode, if (mode == .write) @field(input, field.name) else {}, access, cursor);
            }
            break :product result;
        },
        .array => |info| sequence: {
            var result: T = if (mode == .write) input else undefined;
            for (&result, 0..) |*item, index| {
                item.* = try transfer(info.child, mode, if (mode == .write) input[index] else {}, access, cursor);
            }
            break :sequence result;
        },
        .optional => |info| optional: {
            const present = if (mode == .write) input != null else try transfer(bool, mode, {}, access, cursor);
            if (mode == .write) _ = try transfer(bool, mode, present, access, cursor);
            if (!present) {
                try access.padding(cursor.*, Shape(info.child).width);
                cursor.* += Shape(info.child).width;
                break :optional null;
            }
            break :optional try transfer(info.child, mode, if (mode == .write) input.? else {}, access, cursor);
        },
        .@"union" => |info| sum: {
            const Tag = info.tag_type.?;
            const payload_start = cursor.* + 1;
            const payload_width = Shape(T).width - 1;
            if (mode == .write) {
                const active = std.meta.activeTag(input);
                _ = try transfer(Tag, mode, active, access, cursor);
                switch (input) {
                    inline else => |payload| _ = try transfer(@TypeOf(payload), mode, payload, access, cursor),
                }
                try access.padding(cursor.*, payload_start + payload_width - cursor.*);
                cursor.* = payload_start + payload_width;
                break :sum input;
            }
            const active = try transfer(Tag, mode, {}, access, cursor);
            const result = switch (active) {
                inline else => |tag| result: {
                    const name = @tagName(tag);
                    const Payload = @FieldType(T, name);
                    break :result @unionInit(T, name, try transfer(Payload, mode, {}, access, cursor));
                },
            };
            try access.padding(cursor.*, payload_start + payload_width - cursor.*);
            cursor.* = payload_start + payload_width;
            break :sum result;
        },
        .void => {},
        else => unreachable,
    };
}

const Descriptor = struct {
    width: u8,
    offset: u32,
    base: u64,
    slope: i64,
};

/// Resolve a tuple of comptime field enums to one contiguous Shape range.
/// Optional and union values may be endpoints, but their runtime arms cannot
/// be crossed by a static projection path.
fn ProjectionInfo(comptime Root: type, comptime path: anytype) type {
    // Deep generated record products can make std.meta.FieldEnum exceed Zig's
    // small default comptime budget; this is bounded by the static Shape.
    @setEvalBranchQuota(100_000);
    var Current = Root;
    var offset: usize = 0;
    inline for (path) |part| {
        if (@typeInfo(Current) != .@"struct") {
            @compileError("projection path may descend only through structs; select an optional/union as its endpoint");
        }
        const name = @tagName(part);
        if (!@hasField(Current, name)) {
            @compileError("projection path names no field in " ++ @typeName(Current));
        }
        const field = @field(std.meta.FieldEnum(Current), name);
        offset += Shape(Current).fieldOffset(field);
        Current = @FieldType(Current, name);
    }
    const Value = Current;
    const first_lane = offset;
    const lane_count = Shape(Current).width;
    return struct {
        pub const value_type = Value;
        pub const first = first_lane;
        pub const width = lane_count;
    };
}

fn bitWidth(maximum: u64) u8 {
    return if (maximum == 0) 0 else @intCast(64 - @clz(maximum));
}

fn varLength(value: u64) usize {
    var remaining = value;
    var count: usize = 1;
    while (remaining >= 0x80) : (count += 1) remaining >>= 7;
    return count;
}

fn appendVar(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) Error!void {
    var remaining = value;
    while (remaining >= 0x80) {
        try output.append(allocator, @intCast((remaining & 0x7f) | 0x80));
        remaining >>= 7;
    }
    try output.append(allocator, @intCast(remaining));
}

fn slopeCode(value: i64) u64 {
    const wide: i128 = value;
    return @intCast(if (wide < 0) -wide * 2 - 1 else wide * 2);
}

fn decodeSlope(value: u64) Error!i64 {
    const magnitude = value >> 1;
    if (magnitude > std.math.maxInt(i64)) return error.InvalidValue;
    const signed: i128 = if (value & 1 == 0) magnitude else -@as(i128, magnitude) - 1;
    if (signed < std.math.minInt(i64) or signed > std.math.maxInt(i64)) return error.InvalidValue;
    return @intCast(signed);
}

fn readVar(comptime Source: type, source: *const Source, cursor: *usize) (Error || bytes.SourceError(Source))!u64 {
    var value: u64 = 0;
    var shift: usize = 0;
    var groups: usize = 0;
    while (groups < 10) : (groups += 1) {
        const input = try bytes.read(Source, source, cursor.*, 1);
        cursor.* = std.math.add(usize, cursor.*, 1) catch return error.Overflow;
        const payload = input[0] & 0x7f;
        if (shift == 63 and payload > 1) return error.InvalidValue;
        value |= @as(u64, payload) << @intCast(shift);
        if (input[0] & 0x80 == 0) {
            if (groups != 0 and payload == 0) return error.InvalidFormat;
            return value;
        }
        shift += 7;
    }
    return error.InvalidFormat;
}

fn packedBytes(count: usize, width: u8) Error!usize {
    if (width == 0) return 0;
    const bits = std.math.mul(usize, count, width) catch return error.Overflow;
    return std.math.divCeil(usize, bits, 8) catch return error.Overflow;
}

const PackedWindow = struct {
    bit_start: usize,
    byte_start: usize,
    byte_count: usize,
};

fn packedWindow(count: usize, width: u8, row_index: usize) Error!PackedWindow {
    if (width == 0) return .{ .bit_start = 0, .byte_start = 0, .byte_count = 0 };
    if (row_index >= count) return error.IndexOutOfBounds;
    const bit_start = std.math.mul(usize, row_index, @as(usize, width)) catch return error.Overflow;
    const shifted_width = std.math.add(usize, bit_start & 7, width) catch return error.Overflow;
    const byte_count = std.math.divCeil(usize, shifted_width, 8) catch return error.Overflow;
    const byte_start = bit_start / 8;
    const byte_end = std.math.add(usize, byte_start, byte_count) catch return error.Overflow;
    if (byte_end > try packedBytes(count, width)) return error.InvalidFormat;
    return .{ .bit_start = bit_start, .byte_start = byte_start, .byte_count = byte_count };
}

fn readScalar(comptime Source: type, source: *const Source, source_row_count: usize, descriptor: Descriptor, absolute_row: usize) (Error || bytes.SourceError(Source))!u64 {
    if (absolute_row >= source_row_count) return error.IndexOutOfBounds;
    const predicted = @as(i128, descriptor.base) + @as(i128, descriptor.slope) * @as(i128, @intCast(absolute_row));
    if (predicted < 0 or predicted > std.math.maxInt(u64)) return error.InvalidValue;
    if (descriptor.width == 0) return @intCast(predicted);
    const window = try packedWindow(source_row_count, descriptor.width, absolute_row);
    const offset = std.math.add(usize, descriptor.offset, window.byte_start) catch return error.Overflow;
    const data = try bytes.read(Source, source, offset, window.byte_count);
    const residual = std.mem.readVarPackedInt(u64, data, window.bit_start & 7, descriptor.width, .little, .unsigned);
    return std.math.add(u64, @intCast(predicted), residual) catch return error.InvalidValue;
}

/// Call-bounded scalar access shared by whole rows and retained projections.
/// Descriptor storage is borrowed only for this synchronous transfer.
fn CallAccess(comptime Source: type, comptime mode: TransferMode, comptime Domains: type) type {
    return struct {
        source: *const Source,
        source_row_count: usize,
        descriptors: []const Descriptor,
        absolute_row: usize,
        domains: Domains,

        pub const TransferError = Error || bytes.SourceError(Source);

        fn read(self: @This(), lane: usize) TransferError!u64 {
            if (lane >= self.descriptors.len) return error.IndexOutOfBounds;
            return readScalar(Source, self.source, self.source_row_count, self.descriptors[lane], self.absolute_row);
        }

        fn padding(self: @This(), start: usize, count: usize) TransferError!void {
            if (mode == .verify) for (start..start + count) |lane| {
                if (try self.read(lane) != 0) return error.InvalidValue;
            };
        }
    };
}

fn decodeAccess(comptime T: type, comptime mode: TransferMode, access: anytype) @TypeOf(access).TransferError!T {
    var cursor: usize = 0;
    return transfer(T, mode, {}, access, &cursor);
}

fn verifyTails(comptime Source: type, source: *const Source, source_row_count: usize, descriptors: []const Descriptor) (Error || bytes.SourceError(Source))!void {
    for (descriptors) |descriptor| {
        const length = try packedBytes(source_row_count, descriptor.width);
        if (descriptor.width == 0 or length == 0) continue;
        const used_bits = std.math.mul(usize, source_row_count, descriptor.width) catch return error.Overflow;
        const tail_bits = used_bits & 7;
        if (tail_bits == 0) continue;
        const tail = try bytes.read(Source, source, @as(usize, descriptor.offset) + length - 1, 1);
        const allowed = (@as(u8, 1) << @intCast(tail_bits)) - 1;
        if (tail[0] & ~allowed != 0) return error.InvalidFormat;
    }
}

fn affine(values: []const u64) ?struct { base: u64, slope: i64 } {
    if (values.len == 0) return .{ .base = 0, .slope = 0 };
    if (values.len == 1) return .{ .base = values[0], .slope = 0 };
    const difference = @as(i128, values[1]) - @as(i128, values[0]);
    if (difference < std.math.minInt(i64) or difference > std.math.maxInt(i64)) return null;
    for (values, 0..) |value, index| {
        if (@as(i128, values[0]) + difference * @as(i128, @intCast(index)) != value) return null;
    }
    return .{ .base = values[0], .slope = @intCast(difference) };
}

fn predictor(values: []const u64) struct { base: u64, slope: i64, width: u8 } {
    if (affine(values)) |exact| return .{ .base = exact.base, .slope = exact.slope, .width = 0 };
    var minimum: u64 = std.math.maxInt(u64);
    var maximum_residual: u64 = 0;
    for (values) |value| minimum = @min(minimum, value);
    if (values.len == 0) minimum = 0;
    for (values) |value| maximum_residual = @max(maximum_residual, value - minimum);
    return .{ .base = minimum, .slope = 0, .width = bitWidth(maximum_residual) };
}

/// A self-contained bounded view over one contiguous Shape range. Projections
/// copy only their selected descriptors and Source capability, so they remain
/// valid after the parent view moves.
fn ProjectedViewFor(comptime Source: type, comptime Value: type, comptime width: usize) type {
    return struct {
        source: Source,
        source_row_count: usize,
        base_row: usize,
        row_count: usize,
        descriptors: [width]Descriptor,

        const Self = @This();
        pub const ValueType = Value;
        pub const ReadError = Error || bytes.SourceError(Source);

        fn decode(self: *const Self, comptime mode: TransferMode, index: usize, comptime T: type, domains: anytype) ReadError!T {
            if (index >= self.row_count) return error.IndexOutOfBounds;
            const absolute_row = std.math.add(usize, self.base_row, index) catch return error.Overflow;
            const Access = CallAccess(Source, mode, @TypeOf(domains));
            return decodeAccess(T, mode, Access{
                .source = &self.source,
                .source_row_count = self.source_row_count,
                .descriptors = &self.descriptors,
                .absolute_row = absolute_row,
                .domains = domains,
            });
        }

        pub fn at(self: *const Self, index: usize) ReadError!Value {
            return self.decode(.read, index, Value, {});
        }

        pub fn slice(self: *const Self, start: usize, end: usize) ReadError!Self {
            if (start > end or end > self.row_count) return error.IndexOutOfBounds;
            return .{
                .source = self.source,
                .source_row_count = self.source_row_count,
                .base_row = std.math.add(usize, self.base_row, start) catch return error.Overflow,
                .row_count = end - start,
                .descriptors = self.descriptors,
            };
        }

        pub fn ProjectionFor(comptime path: anytype) type {
            const Info = ProjectionInfo(Value, path);
            return ProjectedViewFor(Source, Info.value_type, Info.width);
        }

        pub fn project(self: *const Self, comptime path: anytype) ProjectionFor(path) {
            const Info = ProjectionInfo(Value, path);
            var result: ProjectionFor(path) = undefined;
            result.source = self.source;
            result.source_row_count = self.source_row_count;
            result.base_row = self.base_row;
            result.row_count = self.row_count;
            inline for (0..Info.width) |index| {
                result.descriptors[index] = self.descriptors[Info.first + index];
            }
            return result;
        }

        pub fn verify(self: *const Self, domains: anytype) ReadError!void {
            try verifyTails(Source, &self.source, self.source_row_count, &self.descriptors);
            for (0..self.row_count) |index| {
                _ = try self.decode(.verify, index, Value, domains);
            }
        }

        /// Fill one scalar endpoint through one exact authenticated packed
        /// extent. No decoded values or source slices are retained.
        pub fn fill(self: *const Self, start: usize, end: usize, output: []Value) ReadError!void {
            if (comptime Shape(Value).width != 1 or switch (@typeInfo(Value)) {
                .optional, .@"struct", .array, .@"union" => true,
                else => false,
            }) @compileError("fill requires a non-optional scalar projection endpoint");
            if (start > end or end > self.row_count) return error.IndexOutOfBounds;
            const count = end - start;
            if (output.len < count) return error.OutputTooSmall;
            if (count == 0) return;
            const first = std.math.add(usize, self.base_row, start) catch return error.Overflow;
            const last = std.math.add(usize, self.base_row, end) catch return error.Overflow;
            if (last > self.source_row_count) return error.IndexOutOfBounds;
            const descriptor = self.descriptors[0];
            if (descriptor.width == 0) {
                for (0..count) |index| {
                    const absolute = first + index;
                    const predicted = @as(i128, descriptor.base) + @as(i128, descriptor.slope) * @as(i128, @intCast(absolute));
                    if (predicted < 0 or predicted > std.math.maxInt(u64)) return error.InvalidValue;
                    output[index] = try decodeScalar(Value, @intCast(predicted), {});
                }
                return;
            }
            const first_bit = std.math.mul(usize, first, @as(usize, descriptor.width)) catch return error.Overflow;
            const last_bit = std.math.mul(usize, last, @as(usize, descriptor.width)) catch return error.Overflow;
            const byte_start = first_bit / 8;
            const byte_end = std.math.divCeil(usize, last_bit, 8) catch return error.Overflow;
            if (byte_end > try packedBytes(self.source_row_count, descriptor.width)) return error.InvalidFormat;
            const offset = std.math.add(usize, descriptor.offset, byte_start) catch return error.Overflow;
            const data = try bytes.read(Source, &self.source, offset, byte_end - byte_start);
            for (0..count) |index| {
                const absolute = first + index;
                const bit = std.math.mul(usize, absolute, @as(usize, descriptor.width)) catch return error.Overflow;
                const local_bit = bit - byte_start * 8;
                const local_byte = local_bit / 8;
                if (local_byte >= data.len) return error.Truncated;
                const residual = std.mem.readVarPackedInt(u64, data[local_byte..], local_bit & 7, descriptor.width, .little, .unsigned);
                const predicted = @as(i128, descriptor.base) + @as(i128, descriptor.slope) * @as(i128, @intCast(absolute));
                if (predicted < 0 or predicted > std.math.maxInt(u64)) return error.InvalidValue;
                const raw = std.math.add(u64, @intCast(predicted), residual) catch return error.InvalidValue;
                output[index] = try decodeScalar(Value, raw, {});
            }
        }
    };
}

/// Add one nominal row coordinate to any projected table without introducing
/// another decoding authority.
pub fn Indexed(comptime Index: type, comptime View: type) type {
    return struct {
        inner: View,
        lower: Index,

        const Self = @This();
        pub const ValueType = View.ValueType;
        pub const ReadError = View.ReadError;

        pub fn count(self: *const Self) usize {
            return self.inner.row_count;
        }

        pub fn at(self: *const Self, index: Index) ReadError!ValueType {
            const raw = @intFromEnum(index);
            const first = @intFromEnum(self.lower);
            if (raw < first) return error.IndexOutOfBounds;
            return self.inner.at(raw - first);
        }

        pub fn ProjectionFor(comptime path: anytype) type {
            return Indexed(Index, View.ProjectionFor(path));
        }

        pub fn project(self: *const Self, comptime path: anytype) ProjectionFor(path) {
            return .{ .inner = self.inner.project(path), .lower = self.lower };
        }

        pub fn slice(self: *const Self, start: Index, end: Index) ReadError!Self {
            const first = @intFromEnum(self.lower);
            const start_raw = @intFromEnum(start);
            const end_raw = @intFromEnum(end);
            if (start_raw < first or end_raw < start_raw) return error.IndexOutOfBounds;
            return .{
                .inner = try self.inner.slice(start_raw - first, end_raw - first),
                .lower = start,
            };
        }

        pub fn verify(self: *const Self, domains: anytype) ReadError!void {
            return self.inner.verify(domains);
        }
    };
}

pub fn Records(comptime Row: type) type {
    @setEvalBranchQuota(100_000);
    const lanes = Shape(Row).width;
    return struct {
        pub const Field = std.meta.FieldEnum(Row);
        pub fn leafCountValue() usize {
            return lanes;
        }
        pub const leafCount = leafCountValue;
        pub const RecordShape = Shape(Row);

        pub const Owned = struct {
            allocator: std.mem.Allocator,
            bytes: []u8,
            pub fn deinit(self: *Owned) void {
                self.allocator.free(self.bytes);
                self.* = undefined;
            }
        };

        pub fn build(allocator: std.mem.Allocator, rows: []const Row) Error!Owned {
            if (rows.len > std.math.maxInt(u32) or lanes > std.math.maxInt(u16)) return error.InvalidValue;
            const cells = std.math.mul(usize, rows.len, lanes) catch return error.Overflow;
            const matrix = try allocator.alloc(u64, cells);
            defer allocator.free(matrix);
            for (rows, 0..) |row_value, row_index| {
                var cursor: usize = 0;
                const WriteAccess = struct {
                    matrix: []u64,
                    row_count: usize,
                    row_index: usize,
                    pub const TransferError = Error;
                    const domains = {};
                    fn write(self: @This(), lane: usize, raw: u64) Error!void {
                        self.matrix[lane * self.row_count + self.row_index] = raw;
                    }
                    fn padding(self: @This(), start: usize, count: usize) Error!void {
                        for (start..start + count) |lane| self.matrix[lane * self.row_count + self.row_index] = 0;
                    }
                };
                _ = try transfer(Row, .write, row_value, WriteAccess{ .matrix = matrix, .row_count = rows.len, .row_index = row_index }, &cursor);
            }
            var descriptors: [lanes]Descriptor = undefined;
            var controls: std.ArrayList(u8) = .empty;
            defer controls.deinit(allocator);
            for (&descriptors, 0..) |*descriptor, lane| {
                const values = matrix[lane * rows.len ..][0..rows.len];
                const prediction = predictor(values);
                try controls.append(allocator, prediction.width);
                try appendVar(&controls, allocator, prediction.base);
                try appendVar(&controls, allocator, slopeCode(prediction.slope));
                descriptor.* = .{
                    .width = prediction.width,
                    .offset = 0,
                    .base = prediction.base,
                    .slope = prediction.slope,
                };
            }
            var layout = bytes.Layout.init(header_size + controls.items.len);
            for (&descriptors) |*descriptor| {
                const extent = try layout.take(try packedBytes(rows.len, descriptor.width), 1);
                if (extent.offset > std.math.maxInt(u32)) return error.Overflow;
                descriptor.offset = @intCast(extent.offset);
            }
            if (layout.cursor > std.math.maxInt(u32)) return error.Overflow;
            var output = try allocator.alloc(u8, layout.cursor);
            errdefer allocator.free(output);
            @memset(output, 0);
            try bytes.writeInt(u32, output, 0, @intCast(rows.len));
            @memcpy(output[header_size..][0..controls.items.len], controls.items);
            for (descriptors, 0..) |descriptor, lane| {
                if (descriptor.width != 0) for (matrix[lane * rows.len ..][0..rows.len], 0..) |value, row_index| {
                    const predicted = @as(i128, descriptor.base) + @as(i128, descriptor.slope) * @as(i128, @intCast(row_index));
                    if (predicted < 0 or predicted > value) return error.InvalidValue;
                    const residual: u64 = value - @as(u64, @intCast(predicted));
                    const window = try packedWindow(rows.len, descriptor.width, row_index);
                    const length = try packedBytes(rows.len, descriptor.width);
                    const column = output[@as(usize, descriptor.offset)..][0..length];
                    std.mem.writeVarPackedInt(column, window.bit_start, descriptor.width, residual, .little);
                };
            }
            return .{ .allocator = allocator, .bytes = output };
        }

        pub fn ViewFor(comptime Source: type) type {
            return struct {
                source: Source,
                row_count: usize,
                descriptors: [lanes]Descriptor,
                const Self = @This();
                pub const ReadError = Error || bytes.SourceError(Source);

                pub fn open(source: Source) ReadError!Self {
                    return openWithLimits(source, .{});
                }

                pub fn openWithLimits(source: Source, limits: Limits) ReadError!Self {
                    if (bytes.length(Source, &source) < header_size) return error.Truncated;
                    const count_bytes = try bytes.read(Source, &source, 0, header_size);
                    const count = try bytes.readInt(u32, count_bytes, 0);
                    if (count > limits.max_rows) return error.InvalidValue;
                    const cells = std.math.mul(usize, count, lanes) catch return error.Overflow;
                    if (cells > limits.max_cells) return error.InvalidValue;
                    var descriptors: [lanes]Descriptor = undefined;
                    var cursor: usize = header_size;
                    for (&descriptors) |*descriptor| {
                        const control = try bytes.read(Source, &source, cursor, 1);
                        cursor = std.math.add(usize, cursor, 1) catch return error.Overflow;
                        const width = control[0];
                        if (width > 64) return error.InvalidFormat;
                        const base = try readVar(Source, &source, &cursor);
                        const slope = try decodeSlope(try readVar(Source, &source, &cursor));
                        descriptor.* = .{ .width = width, .offset = 0, .base = base, .slope = slope };
                    }
                    var layout = bytes.Layout.init(cursor);
                    for (&descriptors) |*descriptor| {
                        const extent = try layout.take(try packedBytes(count, descriptor.width), 1);
                        if (extent.offset > std.math.maxInt(u32)) return error.Overflow;
                        descriptor.offset = @intCast(extent.offset);
                    }
                    if (layout.cursor != bytes.length(Source, &source)) return error.InvalidFormat;
                    return .{ .source = source, .row_count = count, .descriptors = descriptors };
                }

                pub fn ProjectionFor(comptime path: anytype) type {
                    const Info = ProjectionInfo(Row, path);
                    return ProjectedViewFor(Source, Info.value_type, Info.width);
                }

                pub fn project(self: *const Self, comptime path: anytype) ProjectionFor(path) {
                    const Info = ProjectionInfo(Row, path);
                    var result: ProjectionFor(path) = undefined;
                    result.source = self.source;
                    result.source_row_count = self.row_count;
                    result.base_row = 0;
                    result.row_count = self.row_count;
                    inline for (0..Info.width) |index| {
                        result.descriptors[index] = self.descriptors[Info.first + index];
                    }
                    return result;
                }

                fn decodeBorrowed(self: *const Self, comptime T: type, comptime mode: TransferMode, index: usize, first_lane: usize, domains: anytype) ReadError!T {
                    if (index >= self.row_count) return error.IndexOutOfBounds;
                    const width = Shape(T).width;
                    const last_lane = std.math.add(usize, first_lane, width) catch return error.Overflow;
                    if (last_lane > lanes) return error.IndexOutOfBounds;
                    const Access = CallAccess(Source, mode, @TypeOf(domains));
                    return decodeAccess(T, mode, Access{
                        .source = &self.source,
                        .source_row_count = self.row_count,
                        .descriptors = self.descriptors[first_lane..last_lane],
                        .absolute_row = index,
                        .domains = domains,
                    });
                }

                pub fn row(self: *const Self, index: usize) ReadError!Row {
                    return self.decodeBorrowed(Row, .read, index, 0, {});
                }

                pub fn field(self: *const Self, comptime field_name: Field, index: usize) ReadError!@FieldType(Row, @tagName(field_name)) {
                    const T = @FieldType(Row, @tagName(field_name));
                    return self.decodeBorrowed(T, .read, index, Shape(Row).fieldOffset(field_name), {});
                }

                pub fn fieldAffine(self: *const Self, comptime field_name: Field) ?struct { base: u64, slope: i64 } {
                    const T = @FieldType(Row, @tagName(field_name));
                    if (comptime Shape(T).width != 1) @compileError("fieldAffine requires one scalar lane");
                    const descriptor = self.descriptors[Shape(Row).fieldOffset(field_name)];
                    if (descriptor.width != 0) return null;
                    return .{ .base = descriptor.base, .slope = descriptor.slope };
                }

                pub fn verify(self: *const Self, domains: anytype) ReadError!void {
                    try verifyTails(Source, &self.source, self.row_count, &self.descriptors);
                    for (0..self.row_count) |index| {
                        _ = try self.decodeBorrowed(Row, .verify, index, 0, domains);
                    }
                }
            };
        }
        pub const View = ViewFor([]const u8);
    };
}

test "records canonicalize nested optionals and share union payload lanes" {
    const Tag = enum(u8) { number, pair };
    const Value = union(Tag) { number: u32, pair: struct { left: u16, right: u16 } };
    const Row = struct { enabled: bool, optional: ?struct { value: u32 }, value: Value };
    const Store = Records(Row);
    try std.testing.expectEqual(@as(usize, 6), Store.leafCount());
    const rows = [_]Row{
        .{ .enabled = true, .optional = null, .value = .{ .number = 7 } },
        .{ .enabled = false, .optional = .{ .value = 9 }, .value = .{ .pair = .{ .left = 2, .right = 3 } } },
    };
    var owned = try Store.build(std.testing.allocator, &rows);
    defer owned.deinit();
    const view = try Store.View.open(owned.bytes);
    try view.verify({});
    try std.testing.expectEqualDeep(rows[0], try view.row(0));
    try std.testing.expectEqualDeep(rows[1], try view.row(1));
    try std.testing.expectEqual(false, try view.field(.enabled, 1));
}

test "projected views compose and typed slices preserve logical coordinates" {
    const Row = struct {
        prefix: u16,
        nested: struct { number: i64, maybe: ?u8 },
    };
    const Rank = enum(u32) { _ };
    const rows = [_]Row{
        .{ .prefix = 1, .nested = .{ .number = -4, .maybe = null } },
        .{ .prefix = 2, .nested = .{ .number = -3, .maybe = 9 } },
        .{ .prefix = 3, .nested = .{ .number = -2, .maybe = 8 } },
        .{ .prefix = 4, .nested = .{ .number = -1, .maybe = null } },
    };
    const Store = Records(Row);
    var owned = try Store.build(std.testing.allocator, &rows);
    defer owned.deinit();
    const view = try Store.View.open(owned.bytes);

    const nested = view.project(.{.nested});
    const numbers = nested.project(.{.number});
    try std.testing.expectEqual(@as(i64, -2), try numbers.at(2));
    var output: [2]i64 = undefined;
    try numbers.fill(1, 3, &output);
    try std.testing.expectEqualSlices(i64, &.{ -3, -2 }, &output);

    const window = try nested.slice(1, 4);
    const indexed = Indexed(Rank, @TypeOf(window)){
        .inner = window,
        .lower = @enumFromInt(1),
    };
    try std.testing.expectEqualDeep(rows[1].nested, try indexed.at(@enumFromInt(1)));
    try std.testing.expectError(error.IndexOutOfBounds, indexed.at(@enumFromInt(0)));
    const inner = try indexed.slice(@enumFromInt(2), @enumFromInt(4));
    const maybe = inner.project(.{.maybe});
    try std.testing.expectEqual(@as(?u8, 8), try maybe.at(@enumFromInt(2)));
    try std.testing.expectError(error.IndexOutOfBounds, maybe.at(@enumFromInt(1)));
}
