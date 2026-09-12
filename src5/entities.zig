const std = @import("std");
const bytes = @import("bytes.zig");
const columns = @import("columns.zig");
const model = @import("model.zig");
const stored = @import("stored.zig");
const strings = @import("strings.zig");

pub const StoredProperties = stored.Type(model.RecordProperties);
pub const StoredIdentity = stored.Type(model.Identity);
pub const Row = struct { value: StoredProperties };
const EndRow = struct { end: u32 };
const IdentityRow = struct { kind: model.Kind, identity: StoredIdentity, rank: u32 };
const Rows = columns.Records(Row);
const Ends = columns.Records(EndRow);
const Identities = columns.Records(IdentityRow);
const Parts = struct { rows: void, ends: void, identities: void };
pub const Error = columns.Error || strings.Error || error{ ConflictingDomain, InvalidIdentity };

pub const Owned = bytes.Owned;

pub fn build(allocator: std.mem.Allocator, pool: *strings.Builder, input: []const model.RecordInput) Error!Owned {
    const rows = try allocator.alloc(Row, input.len);
    defer allocator.free(rows);
    if (input.len > std.math.maxInt(u32)) return error.Overflow;
    var counts = [_]u32{0} ** model.kind_count;
    for (input) |entity| {
        const slot = &counts[@intFromEnum(std.meta.activeTag(entity))];
        slot.* = std.math.add(u32, slot.*, 1) catch return error.Overflow;
    }
    var ends: [model.kind_count]EndRow = undefined;
    var next = [_]u32{0} ** model.kind_count;
    var cumulative: u32 = 0;
    for (counts, 0..) |count, index| {
        next[index] = cumulative;
        cumulative = std.math.add(u32, cumulative, count) catch return error.Overflow;
        ends[index] = .{ .end = cumulative };
    }
    const IdentityBuild = struct { kind: model.Kind, identity: model.Identity, rank: u32 };
    var identities: std.ArrayList(IdentityBuild) = .empty;
    defer identities.deinit(allocator);
    for (input) |entity| {
        const kind_index = @intFromEnum(std.meta.activeTag(entity));
        const properties: model.RecordProperties = switch (entity) {
            inline else => |value| value,
        };
        const rank = next[kind_index] - (if (kind_index == 0) 0 else ends[kind_index - 1].end);
        rows[next[kind_index]] = .{ .value = try stored.lower(pool, properties) };
        next[kind_index] += 1;
        if (properties.external_id) |identity| try identities.append(allocator, .{
            .kind = @enumFromInt(kind_index),
            .identity = identity,
            .rank = rank,
        });
    }
    std.mem.sort(IdentityBuild, identities.items, {}, struct {
        fn lessThan(_: void, left: IdentityBuild, right: IdentityBuild) bool {
            if (left.kind != right.kind) return @intFromEnum(left.kind) < @intFromEnum(right.kind);
            const left_tag = std.meta.activeTag(left.identity);
            const right_tag = std.meta.activeTag(right.identity);
            if (left_tag != right_tag) return @intFromEnum(left_tag) < @intFromEnum(right_tag);
            return switch (left.identity) {
                .numeric => |value| value < right.identity.numeric,
                .text => |value| std.mem.order(u8, value, right.identity.text) == .lt,
            };
        }
    }.lessThan);
    const identity_rows = try allocator.alloc(IdentityRow, identities.items.len);
    defer allocator.free(identity_rows);
    for (identities.items, 0..) |identity, index| {
        if (index != 0 and identity.kind == identities.items[index - 1].kind and inputIdentityEqual(identity.identity, identities.items[index - 1].identity)) return error.InvalidIdentity;
        identity_rows[index] = .{
            .kind = identity.kind,
            .identity = try stored.lower(pool, identity.identity),
            .rank = identity.rank,
        };
    }
    var row_store = try Rows.build(allocator, rows);
    defer row_store.deinit();
    var end_store = try Ends.build(allocator, &ends);
    defer end_store.deinit();
    var identity_store = try Identities.build(allocator, identity_rows);
    defer identity_store.deinit();
    return bytes.Bundle(Parts).build(allocator, .{
        .rows = row_store.bytes,
        .ends = end_store.bytes,
        .identities = identity_store.bytes,
    });
}

fn inputIdentityEqual(left: model.Identity, right: model.Identity) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .numeric => |value| value == right.numeric,
        .text => |value| std.mem.eql(u8, value, right.text),
    };
}

pub fn ViewFor(comptime Source: type) type {
    return struct {
        records: Rows.ViewFor(bytes.Span(Source)),
        ends: Ends.ViewFor(bytes.Span(Source)),
        identities: Identities.ViewFor(bytes.Span(Source)),
        const Self = @This();
        pub const ReadError = Error || bytes.SourceError(Source);

        pub fn open(source: Source) ReadError!Self {
            const bundle = try bytes.Bundle(Parts).ViewFor(Source).open(source);
            const Span = bytes.Span(Source);
            return .{
                .records = try Rows.ViewFor(Span).open(bundle.part(.rows)),
                .ends = try Ends.ViewFor(Span).open(bundle.part(.ends)),
                .identities = try Identities.ViewFor(Span).open(bundle.part(.identities)),
            };
        }

        pub fn deriveDomains(self: *const Self, catalogue: *model.DomainCatalogue) ReadError!void {
            if (self.ends.row_count != model.kind_count) return error.ConflictingDomain;
            var start: u32 = 0;
            inline for (@typeInfo(model.Kind).@"enum".fields) |field| {
                const kind: model.Kind = @enumFromInt(field.value);
                const end = try self.ends.field(.end, @intFromEnum(kind));
                if (end < start or end > self.records.row_count) return error.ConflictingDomain;
                const count = end - start;
                if (count != 0) {
                    try catalogue.setOwned(model.Domain{ .record = kind }, count);
                } else {
                    _ = catalogue.countForVerify(model.Domain{ .record = kind }) catch try catalogue.setOwned(model.Domain{ .record = kind }, 0);
                }
                start = end;
            }
            if (start != self.records.row_count) return error.ConflictingDomain;
        }

        pub fn verify(self: *const Self, domains: model.DomainCatalogue, pool: anytype) !void {
            try self.records.verify(domains);
            try self.ends.verify(.{});
            try self.identities.verify(domains);
            if (self.ends.row_count != model.kind_count) return error.ConflictingDomain;
            var start: u32 = 0;
            inline for (@typeInfo(model.Kind).@"enum".fields) |field| {
                const kind: model.Kind = @enumFromInt(field.value);
                const end = try self.ends.field(.end, @intFromEnum(kind));
                if (end < start or end > self.records.row_count) return error.ConflictingDomain;
                const physical_count = end - start;
                switch (domains.statusFor(.{ .record = kind })) {
                    .unresolved => return error.UnresolvedDomain,
                    .owned => |count| if (physical_count != count) return error.ConflictingDomain,
                    .external => if (physical_count != 0) return error.ConflictingDomain,
                }
                start = end;
            }
            if (start != self.records.row_count) return error.ConflictingDomain;
            const external_ids = self.records.project(.{ .value, .external_id });
            var physical_identity_count: usize = 0;
            for (0..self.records.row_count) |index| if ((try external_ids.at(index)) != null) {
                physical_identity_count += 1;
            };
            if (physical_identity_count != self.identities.row_count) return error.InvalidIdentity;
            var previous: ?IdentityRow = null;
            for (0..self.identities.row_count) |index| {
                const identity = try self.identities.row(index);
                const count_start = if (@intFromEnum(identity.kind) == 0) 0 else try self.ends.field(.end, @intFromEnum(identity.kind) - 1);
                const count_end = try self.ends.field(.end, @intFromEnum(identity.kind));
                if (count_start > count_end or identity.rank >= count_end - count_start) return error.InvalidIdentity;
                const coordinate = std.math.add(u32, count_start, identity.rank) catch return error.Overflow;
                const owned_identity = (try external_ids.at(coordinate)) orelse return error.InvalidIdentity;
                if (!try identityEqual(owned_identity, identity.identity, pool)) return error.InvalidIdentity;
                if (previous) |prior| if ((try compareIdentity(prior.kind, prior.identity, identity.kind, identity.identity, pool)) != .lt) return error.InvalidIdentity;
                previous = identity;
            }
        }

        pub fn TableFor(comptime kind: model.Kind) type {
            const Projection = Rows.ViewFor(bytes.Span(Source)).ProjectionFor(.{.value});
            return columns.Indexed(model.Ref(kind), Projection);
        }

        /// Resolve the physical partition once. Record coordinates remain
        /// their original kind-local ranks in this bounded table.
        pub fn table(self: *const Self, comptime kind: model.Kind) ReadError!TableFor(kind) {
            const kind_index = @intFromEnum(kind);
            if (kind_index >= self.ends.row_count) return error.ConflictingDomain;
            const base = if (kind_index == 0) 0 else try self.ends.field(.end, kind_index - 1);
            const end = try self.ends.field(.end, kind_index);
            if (base > end or end > self.records.row_count) return error.ConflictingDomain;
            const values = self.records.project(.{.value});
            return .{
                .inner = try values.slice(base, end),
                .lower = @enumFromInt(0),
            };
        }

        pub fn record(self: *const Self, comptime kind: model.Kind, id: model.Ref(kind)) ReadError!StoredProperties {
            const records = try self.table(kind);
            return records.at(id);
        }

        pub fn recordByIdentity(self: *const Self, comptime kind: model.Kind, identity: model.Identity, pool: anytype) !?model.Ref(kind) {
            var lo: usize = 0;
            var hi = self.identities.row_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const row = try self.identities.row(mid);
                switch (try compareInputIdentity(row.kind, row.identity, kind, identity, pool)) {
                    .lt => lo = mid + 1,
                    .gt => hi = mid,
                    .eq => return @enumFromInt(row.rank),
                }
            }
            return null;
        }

        fn identityEqual(left: StoredIdentity, right: StoredIdentity, pool: anytype) !bool {
            if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
            return switch (left) {
                .numeric => |value| value == right.numeric,
                .text => |value| try pool.order(value, right.text) == .eq,
            };
        }

        fn compareIdentity(left_kind: model.Kind, left: StoredIdentity, right_kind: model.Kind, right: StoredIdentity, pool: anytype) !std.math.Order {
            if (left_kind != right_kind) return std.math.order(@intFromEnum(left_kind), @intFromEnum(right_kind));
            const left_tag = std.meta.activeTag(left);
            const right_tag = std.meta.activeTag(right);
            if (left_tag != right_tag) return std.math.order(@intFromEnum(left_tag), @intFromEnum(right_tag));
            return switch (left) {
                .numeric => |value| std.math.order(value, right.numeric),
                .text => |value| pool.order(value, right.text),
            };
        }

        fn compareInputIdentity(left_kind: model.Kind, left: StoredIdentity, right_kind: model.Kind, right: model.Identity, pool: anytype) !std.math.Order {
            if (left_kind != right_kind) return std.math.order(@intFromEnum(left_kind), @intFromEnum(right_kind));
            const left_tag = std.meta.activeTag(left);
            const right_tag = std.meta.activeTag(right);
            if (left_tag != right_tag) return std.math.order(@intFromEnum(left_tag), @intFromEnum(right_tag));
            return switch (left) {
                .numeric => |value| std.math.order(value, right.numeric),
                .text => |value| pool.orderBytes(value, right.text),
            };
        }
    };
}

pub const View = ViewFor([]const u8);

test "external ranks do not occupy local record coordinates" {
    const input = [_]model.RecordInput{.{ .annotation = .{ .label = "local" } }};
    var pool = strings.Builder.init(std.testing.allocator);
    defer pool.deinit();
    var owned = try build(std.testing.allocator, &pool, &input);
    defer owned.deinit();
    var string_owned = try pool.build(std.testing.allocator);
    defer string_owned.deinit();
    const string_view = try strings.View.open(string_owned.bytes);
    const view = try View.open(owned.bytes);
    var domains: model.DomainCatalogue = .{};
    try domains.declareExternal(.source, 7);
    try domains.setOwned(.string, 1);
    try domains.setOwned(.value, 0);
    try view.deriveDomains(&domains);
    try view.verify(domains, string_view);
    const annotation = try view.record(.annotation, @enumFromInt(0));
    try std.testing.expect(annotation.label != null);
    try std.testing.expectError(error.IndexOutOfBounds, view.record(.source, @enumFromInt(0)));
}
