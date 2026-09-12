const std = @import("std");
const bytes = @import("bytes.zig");
const columns = @import("columns.zig");

pub const Error = columns.Error || error{
    InvalidInput,
    InvalidGroup,
    IndexOutOfBounds,
    OutOfDomain,
    OutOfMemory,
};
pub const Multiplicity = enum(u8) { set, bag };
const header_size: usize = 4;
const ValueRow = struct { value: u32 };
const ValueStore = columns.Records(ValueRow);

pub fn Run(comptime Target: type) type {
    return struct {
        lo: Target,
        hi: Target,

        pub fn len(self: @This()) u32 {
            return @intFromEnum(self.hi) - @intFromEnum(self.lo);
        }
    };
}

pub fn Projection(comptime Target: type, comptime multiplicity: Multiplicity) type {
    comptime {
        if (@typeInfo(Target) != .@"enum") @compileError("Groups Target must be a typed enum coordinate");
    }
    return struct {
        pub const TargetType = Target;
        pub const law = multiplicity;

        pub const Owned = struct {
            allocator: std.mem.Allocator,
            bytes: []u8,

            pub fn deinit(self: *Owned) void {
                self.allocator.free(self.bytes);
                self.* = undefined;
            }
        };

        pub fn build(allocator: std.mem.Allocator, groups: []const []const Target) Error!Owned {
            if (groups.len > std.math.maxInt(u32)) return error.InvalidInput;
            var target_count: usize = 0;
            for (groups) |group| {
                var previous: ?u32 = null;
                for (group) |target| {
                    const value = @intFromEnum(target);
                    if (previous) |prior| if (value <= prior) return error.InvalidGroup;
                    previous = value;
                }
                target_count = std.math.add(usize, target_count, group.len) catch return error.Overflow;
            }
            if (target_count > std.math.maxInt(u32)) return error.InvalidInput;
            const ends_rows = try allocator.alloc(ValueRow, groups.len);
            defer allocator.free(ends_rows);
            const target_rows = try allocator.alloc(ValueRow, target_count);
            defer allocator.free(target_rows);
            var ordinal: usize = 0;
            for (groups, 0..) |group, group_index| {
                for (group) |target| {
                    target_rows[ordinal] = .{ .value = @intFromEnum(target) };
                    ordinal += 1;
                }
                ends_rows[group_index] = .{ .value = @intCast(ordinal) };
            }
            var ends_owned = try ValueStore.build(allocator, ends_rows);
            defer ends_owned.deinit();
            var targets_owned = try ValueStore.build(allocator, target_rows);
            defer targets_owned.deinit();
            var layout = bytes.Layout.init(header_size);
            const ends_extent = try layout.take(ends_owned.bytes.len, 1);
            const targets_extent = try layout.take(targets_owned.bytes.len, 1);
            const total = layout.cursor;
            if (total > std.math.maxInt(u32) or ends_extent.length > std.math.maxInt(u32)) return error.Overflow;
            var output = try allocator.alloc(u8, total);
            errdefer allocator.free(output);
            @memset(output, 0);
            try bytes.writeInt(u32, output, 0, @intCast(ends_extent.length));
            @memcpy(output[ends_extent.offset..][0..ends_owned.bytes.len], ends_owned.bytes);
            @memcpy(output[targets_extent.offset..][0..targets_owned.bytes.len], targets_owned.bytes);
            return .{ .allocator = allocator, .bytes = output };
        }

        pub fn ViewFor(comptime Source: type) type {
            return struct {
                source: Source,
                group_count: u32,
                target_count: u32,
                ends: ValueStore.ViewFor(bytes.Span(Source)),
                targets: ValueStore.ViewFor(bytes.Span(Source)),

                const Self = @This();
                pub const ReadError = Error || bytes.SourceError(Source);

                pub fn open(source: Source) ReadError!Self {
                    if (bytes.length(Source, &source) < header_size) return error.Truncated;
                    const header = try bytes.read(Source, &source, 0, header_size);
                    const ends_size = try bytes.readInt(u32, header, 0);
                    const total = bytes.length(Source, &source);
                    var layout = bytes.Layout.init(header_size);
                    const ends_extent = try layout.take(ends_size, 1);
                    if (total < layout.cursor) return error.InvalidFormat;
                    const targets_extent = try layout.take(total - layout.cursor, 1);
                    if (layout.cursor != total) return error.InvalidFormat;
                    if (total != bytes.length(Source, &source)) return error.InvalidFormat;
                    const ends = try ValueStore.ViewFor(bytes.Span(Source)).open(try bytes.Span(Source).init(source, ends_extent.offset, ends_extent.length));
                    const targets = try ValueStore.ViewFor(bytes.Span(Source)).open(try bytes.Span(Source).init(source, targets_extent.offset, targets_extent.length));
                    if (ends.row_count > std.math.maxInt(u32) or targets.row_count > std.math.maxInt(u32)) return error.InvalidFormat;
                    return .{
                        .source = source,
                        .group_count = @intCast(ends.row_count),
                        .target_count = @intCast(targets.row_count),
                        .ends = ends,
                        .targets = targets,
                    };
                }

                fn end(self: *const Self, group: u32) ReadError!u32 {
                    if (group >= self.group_count) return error.IndexOutOfBounds;
                    return self.ends.field(.value, group);
                }

                fn target(self: *const Self, ordinal: u32) ReadError!Target {
                    if (ordinal >= self.target_count) return error.IndexOutOfBounds;
                    return @enumFromInt(try self.targets.field(.value, ordinal));
                }

                pub fn cursor(self: *const Self, group: usize) ReadError!Cursor {
                    if (group >= self.group_count) return error.IndexOutOfBounds;
                    const group_u32: u32 = @intCast(group);
                    const start = if (group_u32 == 0) 0 else try self.end(group_u32 - 1);
                    const limit = try self.end(group_u32);
                    if (start > limit or limit > self.target_count) return error.InvalidGroup;
                    return .{ .view = self.*, .next = start, .limit = limit };
                }

                pub fn verify(self: *const Self, domain_count: usize) ReadError!void {
                    if (domain_count > std.math.maxInt(u32)) return error.OutOfDomain;
                    const ends_affine = self.ends.fieldAffine(.value);
                    const targets_affine = self.targets.fieldAffine(.value);
                    if (self.group_count == self.target_count and ends_affine != null and targets_affine != null and
                        ends_affine.?.base == 1 and ends_affine.?.slope == 1 and
                        targets_affine.?.base == 0 and targets_affine.?.slope == 1)
                    {
                        if (self.target_count > domain_count) return error.OutOfDomain;
                        return;
                    }
                    try self.ends.verify(.{});
                    try self.targets.verify(.{});
                    var previous_end: u32 = 0;
                    for (0..self.group_count) |group| {
                        const group_end = try self.end(@intCast(group));
                        if (group_end < previous_end or group_end > self.target_count) return error.InvalidGroup;
                        var previous_target: ?u32 = null;
                        for (previous_end..group_end) |ordinal| {
                            const value = @intFromEnum(try self.target(@intCast(ordinal)));
                            if (value >= domain_count) return error.OutOfDomain;
                            if (previous_target) |prior| if (value <= prior) return error.InvalidGroup;
                            previous_target = value;
                        }
                        previous_end = group_end;
                    }
                    if (previous_end != self.target_count) return error.InvalidGroup;
                }

                pub const Cursor = struct {
                    view: Self,
                    next: u32,
                    limit: u32,

                    pub fn nextRun(self: *@This()) ReadError!?Run(Target) {
                        if (self.next == self.limit) return null;
                        const first = @intFromEnum(try self.view.target(self.next));
                        var run_end = std.math.add(u32, first, 1) catch return error.OutOfDomain;
                        self.next += 1;
                        while (self.next < self.limit) {
                            const candidate = @intFromEnum(try self.view.target(self.next));
                            if (candidate != run_end) break;
                            run_end = std.math.add(u32, run_end, 1) catch return error.OutOfDomain;
                            self.next += 1;
                        }
                        return .{ .lo = @enumFromInt(first), .hi = @enumFromInt(run_end) };
                    }

                    pub fn contains(self: *const @This(), wanted: Target) ReadError!bool {
                        // Membership is a synchronous probe over an intentional
                        // copy; the caller's cursor position remains unchanged.
                        var copy = self.*;
                        const found = try copy.seek(wanted) orelse return false;
                        return found == wanted;
                    }

                    pub fn lowerBound(self: *const @This(), wanted: Target) ReadError!?Target {
                        // Seeking mutates only the local scan copy.
                        var copy = self.*;
                        return copy.seek(wanted);
                    }

                    pub fn seek(self: *@This(), wanted: Target) ReadError!?Target {
                        var lo = self.next;
                        var hi = self.limit;
                        while (lo < hi) {
                            const mid = lo + (hi - lo) / 2;
                            const candidate = try self.view.target(mid);
                            if (@intFromEnum(candidate) < @intFromEnum(wanted)) {
                                lo = mid + 1;
                            } else {
                                hi = mid;
                            }
                        }
                        self.next = lo;
                        if (lo == self.limit) return null;
                        return @as(?Target, try self.view.target(lo));
                    }
                };
            };
        }

        pub const View = ViewFor([]const u8);
    };
}

test "groups preserve empty groups and emit coalesced typed runs" {
    const Target = enum(u32) { _ };
    const Store = Projection(Target, .set);
    const first = [_]Target{ @enumFromInt(1), @enumFromInt(2), @enumFromInt(5) };
    const groups = [_][]const Target{ &.{}, &first, &.{} };
    var owned = try Store.build(std.testing.allocator, &groups);
    defer owned.deinit();
    const view = try Store.View.open(owned.bytes);
    try view.verify(6);
    var empty = try view.cursor(0);
    try std.testing.expect((try empty.nextRun()) == null);
    var cursor = try view.cursor(1);
    try std.testing.expectEqualDeep(Run(Target){ .lo = @enumFromInt(1), .hi = @enumFromInt(3) }, (try cursor.nextRun()).?);
    try std.testing.expectEqualDeep(Run(Target){ .lo = @enumFromInt(5), .hi = @enumFromInt(6) }, (try cursor.nextRun()).?);
    try std.testing.expect((try cursor.nextRun()) == null);
}
