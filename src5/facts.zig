const std = @import("std");
const bytes = @import("bytes.zig");
const columns = @import("columns.zig");
const model = @import("model.zig");
const sets = @import("sets.zig");
const stored = @import("stored.zig");
const strings = @import("strings.zig");
const topology = @import("topology.zig");
const targets = @import("targets.zig");

pub const StoredQualifiers = stored.Type(model.Qualifiers);
pub const Fact = union(enum) {
    relation: struct { subject: targets.Target, predicate: model.PredicateId, object: targets.Target, qualifiers: StoredQualifiers },
    membership: struct { member: model.AnyRef, target: model.MembershipTarget, qualifiers: StoredQualifiers },
};
pub const Row = struct { value: Fact };
const Rows = columns.Records(Row);
const Adjacency = sets.Projection(model.FactId, .bag);
const Parts = struct { rows: void, outgoing: void, incoming: void };

pub const Error = columns.Error || sets.Error || strings.Error || topology.Error || error{ InvalidFact, InvalidPredicate, ConflictingDomain, InvalidExternalDomain };
pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

fn membershipTarget(reference: model.MembershipTarget) model.AnyRef {
    return switch (reference) {
        .concept => |id| .{ .concept = id },
        .interlingual => |id| .{ .interlingual = id },
    };
}

pub fn build(allocator: std.mem.Allocator, pool: *strings.Builder, source: *const topology.Owned, documents: []const model.DocumentInput, records: []const model.RecordInput, external: []const model.ExternalRankInput, input: []const model.FactInput) Error!Owned {
    const space = try model.RecordSpace.fromInputs(records, external);
    const rows = try allocator.alloc(Row, input.len);
    defer allocator.free(rows);
    const outgoing = try allocator.alloc(std.ArrayList(model.FactId), space.total(.addressable));
    defer allocator.free(outgoing);
    for (outgoing) |*group| group.* = .empty;
    defer for (outgoing) |*group| group.deinit(allocator);
    const incoming = try allocator.alloc(std.ArrayList(model.FactId), space.total(.addressable));
    defer allocator.free(incoming);
    for (incoming) |*group| group.* = .empty;
    defer for (incoming) |*group| group.deinit(allocator);
    for (input, 0..) |fact, index| {
        const id = model.FactId.fromIndex(index) catch return error.InvalidFact;
        rows[index] = .{ .value = switch (fact) {
            .relation => |relation| relation_value: {
                const subject = try targets.lower(pool, source, documents, relation.subject);
                if (subject == .record) try outgoing[try space.coordinate(subject.record, .addressable)].append(allocator, id);
                const object = try targets.lower(pool, source, documents, relation.object);
                if (object == .record) try incoming[try space.coordinate(object.record, .addressable)].append(allocator, id);
                break :relation_value .{ .relation = .{
                    .subject = subject,
                    .predicate = relation.predicate,
                    .object = object,
                    .qualifiers = try stored.lower(pool, relation.qualifiers),
                } };
            },
            .membership => |membership| membership_value: {
                try outgoing[try space.coordinate(membership.member, .addressable)].append(allocator, id);
                try incoming[try space.coordinate(membershipTarget(membership.target), .addressable)].append(allocator, id);
                break :membership_value .{ .membership = .{
                    .member = membership.member,
                    .target = membership.target,
                    .qualifiers = try stored.lower(pool, membership.qualifiers),
                } };
            },
        } };
    }
    const outgoing_slices = try allocator.alloc([]const model.FactId, outgoing.len);
    defer allocator.free(outgoing_slices);
    for (outgoing, 0..) |group, index| outgoing_slices[index] = group.items;
    const incoming_slices = try allocator.alloc([]const model.FactId, incoming.len);
    defer allocator.free(incoming_slices);
    for (incoming, 0..) |group, index| incoming_slices[index] = group.items;
    var row_store = try Rows.build(allocator, rows);
    defer row_store.deinit();
    var outgoing_store = try Adjacency.build(allocator, outgoing_slices);
    defer outgoing_store.deinit();
    var incoming_store = try Adjacency.build(allocator, incoming_slices);
    defer incoming_store.deinit();
    const output = try bytes.Bundle(Parts).build(allocator, .{
        .rows = row_store.bytes,
        .outgoing = outgoing_store.bytes,
        .incoming = incoming_store.bytes,
    });
    return .{ .allocator = allocator, .bytes = output.bytes };
}

pub fn ViewFor(comptime Source: type) type {
    return struct {
        rows: Rows.ViewFor(bytes.Span(Source)),
        outgoing: Adjacency.ViewFor(bytes.Span(Source)),
        incoming: Adjacency.ViewFor(bytes.Span(Source)),
        const Self = @This();
        pub const ReadError = Error || bytes.SourceError(Source);
        pub const ClaimCursor = Adjacency.ViewFor(bytes.Span(Source)).Cursor;

        pub fn open(source: Source) ReadError!Self {
            const bundle = try bytes.Bundle(Parts).ViewFor(Source).open(source);
            const Span = bytes.Span(Source);
            return .{
                .rows = try Rows.ViewFor(Span).open(bundle.part(.rows)),
                .outgoing = try Adjacency.ViewFor(Span).open(bundle.part(.outgoing)),
                .incoming = try Adjacency.ViewFor(Span).open(bundle.part(.incoming)),
            };
        }

        pub fn verify(self: *const Self, domains: model.DomainCatalogue, space: model.RecordSpace, source: anytype, declarations: anytype) ReadError!void {
            try self.rows.verify(domains);
            try self.outgoing.verify(self.rows.row_count);
            try self.incoming.verify(self.rows.row_count);
            try self.verifyProjection(self.outgoing, space, .outgoing);
            try self.verifyProjection(self.incoming, space, .incoming);
            for (0..self.rows.row_count) |fact_index| switch ((try self.rows.row(fact_index)).value) {
                .relation => |relation| {
                    try targets.validate(relation.subject, source, declarations);
                    try targets.validate(relation.object, source, declarations);
                    const predicate = try declarations.predicate(relation.predicate);
                    if (!try declarations.matches(predicate.subject, relation.subject) or
                        !try declarations.matches(predicate.object, relation.object))
                        return error.InvalidPredicate;
                },
                .membership => {},
            };
        }

        const Direction = enum { outgoing, incoming };

        fn endpoint(fact: Fact, direction: Direction) ?model.AnyRef {
            return switch (fact) {
                .relation => |relation| switch (direction) {
                    .outgoing => if (relation.subject == .record) relation.subject.record else null,
                    .incoming => if (relation.object == .record) relation.object.record else null,
                },
                .membership => |membership| switch (direction) {
                    .outgoing => membership.member,
                    .incoming => membershipTarget(membership.target),
                },
            };
        }

        fn verifyProjection(self: *const Self, projection: Adjacency.ViewFor(bytes.Span(Source)), space: model.RecordSpace, direction: Direction) ReadError!void {
            if (projection.group_count != space.total(.addressable)) return error.InvalidFact;
            var seen: usize = 0;
            for (0..projection.group_count) |group_index| {
                var cursor = try projection.cursor(group_index);
                while (try cursor.nextRun()) |run| {
                    for (@intFromEnum(run.lo)..@intFromEnum(run.hi)) |fact_index| {
                        const fact = (try self.rows.row(fact_index)).value;
                        const reference = endpoint(fact, direction) orelse return error.InvalidFact;
                        if (try space.coordinate(reference, .addressable) != group_index) return error.InvalidFact;
                        seen += 1;
                    }
                }
            }
            var eligible: usize = 0;
            for (0..self.rows.row_count) |fact_index| if (endpoint((try self.rows.row(fact_index)).value, direction) != null) {
                eligible += 1;
            };
            if (seen != eligible) return error.InvalidFact;
        }

        pub fn claimsFrom(self: *const Self, reference: model.AnyRef, space: model.RecordSpace) ReadError!ClaimCursor {
            return self.outgoing.cursor(try space.coordinate(reference, .addressable));
        }

        pub fn claimsTo(self: *const Self, reference: model.AnyRef, space: model.RecordSpace) ReadError!ClaimCursor {
            return self.incoming.cursor(try space.coordinate(reference, .addressable));
        }

        pub fn claimsMatching(self: *const Self, subject: targets.Target) ClaimScan {
            return .{ .view = self.*, .target = subject, .direction = .outgoing };
        }

        pub fn claimsTargeting(self: *const Self, target: targets.Target) ClaimScan {
            return .{ .view = self.*, .target = target, .direction = .incoming };
        }

        pub const ClaimScan = struct {
            view: Self,
            target: targets.Target,
            direction: Direction,
            next: usize = 0,

            pub fn nextFact(self: *@This()) ReadError!?model.FactId {
                while (self.next < self.view.rows.row_count) {
                    const index = self.next;
                    self.next += 1;
                    const fact = (try self.view.rows.row(index)).value;
                    const matches = switch (self.direction) {
                        .outgoing => switch (fact) {
                            .relation => |relation| std.meta.eql(relation.subject, self.target),
                            .membership => |membership| self.target == .record and std.meta.eql(self.target.record, membership.member),
                        },
                        .incoming => switch (fact) {
                            .relation => |relation| std.meta.eql(relation.object, self.target),
                            .membership => |membership| self.target == .record and std.meta.eql(self.target.record, membershipTarget(membership.target)),
                        },
                    };
                    if (matches) return @enumFromInt(index);
                }
                return null;
            }
        };
    };
}

pub const View = ViewFor([]const u8);
