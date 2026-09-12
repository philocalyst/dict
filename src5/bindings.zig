const std = @import("std");
const bytes = @import("bytes.zig");
const columns = @import("columns.zig");
const model = @import("model.zig");
const sets = @import("sets.zig");
const topology = @import("topology.zig");

pub const Row = struct {
    record: model.AnyRef,
    source: model.SourceHandle,
    role: model.BindingRole,
};
const Store = columns.Records(Row);
const OrderRow = struct { binding: model.BindingId, start: u32 };
const Order = columns.Records(OrderRow);
const RecordRoles = sets.Projection(model.SourceOrderId, .set);
const Parts = struct { records: void, source_order: void, record_roles: void };
pub const Error = columns.Error || sets.Error || topology.Error || error{ InvalidBinding, ConflictingDomain, InvalidExternalDomain };
pub const Owned = bytes.Owned;
pub const ScopeMode = enum { attached, within };

pub fn Match(comptime kind: model.Kind) type {
    return struct {
        binding_id: model.BindingId,
        record: model.Ref(kind),
        anchor: model.SourceHandle,
    };
}

pub fn build(allocator: std.mem.Allocator, source: *const topology.Owned, documents: []const model.DocumentInput, records_input: []const model.RecordInput, input: []const model.BindingInput) Error!Owned {
    const space = try model.RecordSpace.fromInputs(records_input, &.{});
    const rows = try allocator.alloc(Row, input.len);
    defer allocator.free(rows);
    for (input, 0..) |binding, index| rows[index] = .{
        .record = binding.record,
        .source = try source.resolveAnchor(documents, binding.source),
        .role = binding.role,
    };
    const SortEntry = struct {
        binding: model.BindingId,
        start: u32,
        owner: u32,
        end: u32,
        tag: u8,
    };
    const topology_view = try topology.View.open(source.bytes, .{});
    const order = try allocator.alloc(SortEntry, rows.len);
    defer allocator.free(order);
    for (rows, 0..) |row, index| {
        order[index] = switch (row.source) {
            .occurrence => |id| occurrence: {
                const occurrence_row = try topology_view.occurrence(id);
                break :occurrence .{
                    .binding = model.BindingId.fromIndex(index) catch return error.InvalidBinding,
                    .start = occurrence_row.event_open,
                    .owner = @intFromEnum(id),
                    .end = std.math.add(u32, occurrence_row.event_close, 1) catch return error.InvalidBinding,
                    .tag = 0,
                };
            },
            .span => |span| .{
                .binding = model.BindingId.fromIndex(index) catch return error.InvalidBinding,
                .start = span.start,
                .owner = @intFromEnum(span.owner),
                .end = span.end,
                .tag = 1,
            },
        };
    }
    std.mem.sort(SortEntry, order, {}, struct {
        fn lessThan(_: void, left: SortEntry, right: SortEntry) bool {
            if (left.start != right.start) return left.start < right.start;
            if (left.owner != right.owner) return left.owner < right.owner;
            if (left.tag != right.tag) return left.tag < right.tag;
            if (left.end != right.end) return left.end < right.end;
            return @intFromEnum(left.binding) < @intFromEnum(right.binding);
        }
    }.lessThan);
    const ordered_rows = try allocator.alloc(OrderRow, order.len);
    defer allocator.free(ordered_rows);
    const role_count = @typeInfo(model.BindingRole).@"enum".fields.len;
    const group_count = std.math.mul(usize, space.total(.owned), role_count) catch return error.Overflow;
    const groups = try allocator.alloc(std.ArrayList(model.SourceOrderId), group_count);
    defer allocator.free(groups);
    for (groups) |*group| group.* = .empty;
    defer for (groups) |*group| group.deinit(allocator);
    for (order, 0..) |entry, index| {
        ordered_rows[index] = .{ .binding = entry.binding, .start = entry.start };
        const binding = rows[@intFromEnum(entry.binding)];
        const group = try space.groupedCoordinate(binding.record, .owned, role_count, @intFromEnum(binding.role));
        try groups[group].append(allocator, model.SourceOrderId.fromIndex(index) catch return error.InvalidBinding);
    }
    const group_slices = try allocator.alloc([]const model.SourceOrderId, groups.len);
    defer allocator.free(group_slices);
    for (groups, 0..) |group, index| group_slices[index] = group.items;
    var records = try Store.build(allocator, rows);
    defer records.deinit();
    var source_order = try Order.build(allocator, ordered_rows);
    defer source_order.deinit();
    var record_roles = try RecordRoles.build(allocator, group_slices);
    defer record_roles.deinit();
    return bytes.Bundle(Parts).build(allocator, .{
        .records = records.bytes,
        .source_order = source_order.bytes,
        .record_roles = record_roles.bytes,
    });
}

pub fn ViewFor(comptime Source: type) type {
    return struct {
        records: Store.ViewFor(bytes.Span(Source)),
        source_order: Order.ViewFor(bytes.Span(Source)),
        record_roles: RecordRoles.ViewFor(bytes.Span(Source)),
        const Self = @This();
        const OrderedEntry = struct { binding: model.BindingId, interval: Interval, tag: u8 };
        pub const ReadError = Error || bytes.SourceError(Source);
        pub const PositionCursor = RecordRoles.ViewFor(bytes.Span(Source)).Cursor;

        pub fn open(source: Source) ReadError!Self {
            const bundle = try bytes.Bundle(Parts).ViewFor(Source).open(source);
            return .{
                .records = try Store.ViewFor(bytes.Span(Source)).open(bundle.part(.records)),
                .source_order = try Order.ViewFor(bytes.Span(Source)).open(bundle.part(.source_order)),
                .record_roles = try RecordRoles.ViewFor(bytes.Span(Source)).open(bundle.part(.record_roles)),
            };
        }

        pub fn verify(self: *const Self, domains: model.DomainCatalogue, space: model.RecordSpace, source: anytype) ReadError!void {
            try self.records.verify(domains);
            try self.source_order.verify(domains);
            try self.record_roles.verify(self.source_order.row_count);
            if (self.source_order.row_count != self.records.row_count) return error.InvalidBinding;
            var previous: ?OrderedEntry = null;
            for (0..self.records.row_count) |index| try source.validateHandle(try self.records.field(.source, index));
            for (0..self.source_order.row_count) |index| {
                const binding = try self.source_order.field(.binding, index);
                const stored_start = try self.source_order.field(.start, index);
                const handle = try self.records.field(.source, @intFromEnum(binding));
                const current: OrderedEntry = .{
                    .binding = binding,
                    .interval = try anchorInterval(source, handle),
                    .tag = @intFromEnum(std.meta.activeTag(handle)),
                };
                if (stored_start != current.interval.start) return error.InvalidBinding;
                if (previous) |prior| if (!orderedBefore(prior, current)) return error.InvalidBinding;
                previous = current;
            }
            const role_count = @typeInfo(model.BindingRole).@"enum".fields.len;
            const expected_groups = std.math.mul(u32, space.total(.owned), role_count) catch return error.Overflow;
            if (self.record_roles.group_count != expected_groups) return error.InvalidBinding;
            var seen: usize = 0;
            for (0..self.record_roles.group_count) |group| {
                var cursor = try self.record_roles.cursor(group);
                while (try cursor.nextRun()) |run| for (@intFromEnum(run.lo)..@intFromEnum(run.hi)) |position| {
                    const binding = try self.source_order.field(.binding, position);
                    const row = try self.records.row(@intFromEnum(binding));
                    const coordinate = try space.groupedCoordinate(row.record, .owned, role_count, @intFromEnum(row.role));
                    if (coordinate != group) return error.InvalidBinding;
                    seen += 1;
                };
            }
            if (seen != self.records.row_count) return error.InvalidBinding;
        }

        pub fn sourcePosition(self: *const Self, position: model.SourceOrderId) ReadError!OrderRow {
            return self.source_order.row(@intFromEnum(position));
        }

        pub fn lowerBoundStart(self: *const Self, wanted: u32) ReadError!?model.SourceOrderId {
            var lo: usize = 0;
            var hi = self.source_order.row_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (try self.source_order.field(.start, mid) < wanted) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            if (lo == self.source_order.row_count) return null;
            return model.SourceOrderId.fromIndex(lo) catch return error.InvalidBinding;
        }

        pub fn bindingAtPosition(self: *const Self, position: model.SourceOrderId) ReadError!struct { id: model.BindingId, row: Row, start: u32 } {
            const ordered = try self.sourcePosition(position);
            return .{
                .id = ordered.binding,
                .row = try self.records.row(@intFromEnum(ordered.binding)),
                .start = ordered.start,
            };
        }

        pub fn positions(self: *const Self, reference: model.AnyRef, role: model.BindingRole, space: model.RecordSpace) ReadError!PositionCursor {
            const role_count = @typeInfo(model.BindingRole).@"enum".fields.len;
            const coordinate = try space.groupedCoordinate(reference, .owned, role_count, @intFromEnum(role));
            return self.record_roles.cursor(coordinate);
        }

        fn orderedBefore(left: anytype, right: @TypeOf(left)) bool {
            if (left.interval.start != right.interval.start) return left.interval.start < right.interval.start;
            if (left.interval.owner != right.interval.owner) return @intFromEnum(left.interval.owner) < @intFromEnum(right.interval.owner);
            if (left.tag != right.tag) return left.tag < right.tag;
            if (left.interval.end != right.interval.end) return left.interval.end < right.interval.end;
            return @intFromEnum(left.binding) < @intFromEnum(right.binding);
        }

        pub fn matches(comptime mode: ScopeMode, source: anytype, selected: model.SourceHandle, candidate: model.SourceHandle) ReadError!bool {
            return if (mode == .attached) std.meta.eql(selected, candidate) else contains(source, selected, candidate);
        }

        pub fn searchBounds(comptime mode: ScopeMode, source: anytype, selected: model.SourceHandle) ReadError!struct { lo: u32, hi: u32 } {
            const exact = try anchorInterval(source, selected);
            if (mode == .attached) return .{ .lo = exact.start, .hi = exact.start };
            const scope = try scopeInterval(source, selected);
            return .{ .lo = @min(exact.start, scope.start), .hi = @max(exact.start, scope.end) };
        }

        const Interval = struct { owner: model.OccurrenceId, start: u32, end: u32 };

        fn anchorInterval(source: anytype, handle: model.SourceHandle) ReadError!Interval {
            return switch (handle) {
                .occurrence => |id| value: {
                    const row = try source.occurrence(id);
                    break :value .{
                        .owner = id,
                        .start = row.event_open,
                        .end = std.math.add(u32, row.event_close, 1) catch return error.InvalidBinding,
                    };
                },
                .span => |span| .{ .owner = span.owner, .start = span.start, .end = span.end },
            };
        }

        fn scopeInterval(source: anytype, handle: model.SourceHandle) ReadError!Interval {
            return switch (handle) {
                .occurrence => |id| value: {
                    const row = try source.occurrence(id);
                    break :value .{
                        .owner = id,
                        .start = std.math.add(u32, row.event_open, 1) catch return error.InvalidBinding,
                        .end = row.event_close,
                    };
                },
                .span => |span| .{ .owner = span.owner, .start = span.start, .end = span.end },
            };
        }

        fn contains(source: anytype, selected: model.SourceHandle, candidate: model.SourceHandle) ReadError!bool {
            if (std.meta.eql(selected, candidate)) return true;
            const outer = try scopeInterval(source, selected);
            const inner = try anchorInterval(source, candidate);
            if (candidate == .span) {
                if (inner.owner != outer.owner) {
                    const owner_block = try anchorInterval(source, .{ .occurrence = inner.owner });
                    if (owner_block.start < outer.start or owner_block.end > outer.end) return false;
                }
                if (inner.start == inner.end) return inner.start >= outer.start and inner.start <= outer.end;
            }
            return inner.start >= outer.start and inner.end <= outer.end;
        }
    };
}

pub const View = ViewFor([]const u8);
