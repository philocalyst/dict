const std = @import("std");
const bytes = @import("bytes.zig");
const columns = @import("columns.zig");
const model = @import("model.zig");
const stored = @import("stored.zig");
const strings = @import("strings.zig");

pub const Predicate = stored.Type(model.PredicateInput);
pub const ExternalScope = stored.Type(model.ExternalScope);
pub const ExternalKey = stored.Type(model.Identity);
pub const ExternalIdentityDomain = struct {
    name: model.StringId,
    key_policy: model.ExternalKeyPolicy,
    allowed_scopes: model.ScopeKinds,
    has_scopes: bool,
    has_keys: bool,
    scope_end: u32,
    key_end: u32,
};
pub const ExternalRank = model.ExternalRankInput;
const Predicates = columns.Records(Predicate);
const ExternalIdentities = columns.Records(ExternalIdentityDomain);
const ExternalScopes = columns.Records(ExternalScope);
const ExternalKeys = columns.Records(ExternalKey);
const ExternalRanks = columns.Records(ExternalRank);
const Parts = struct { predicates: void, identities: void, scopes: void, keys: void, ranks: void };

pub const Error = columns.Error || strings.Error || error{ ConflictingDomain, InvalidExternalDomain, InvalidPredicate };
pub const Owned = bytes.Owned;

pub fn build(allocator: std.mem.Allocator, pool: *strings.Builder, predicates: []const model.PredicateInput, identities: []const model.ExternalIdentityDomainInput, ranks: []const model.ExternalRankInput) Error!Owned {
    const predicate_rows = try allocator.alloc(Predicate, predicates.len);
    defer allocator.free(predicate_rows);
    for (predicates, 0..) |predicate, index| predicate_rows[index] = try stored.lower(pool, predicate);

    const identity_rows = try allocator.alloc(ExternalIdentityDomain, identities.len);
    defer allocator.free(identity_rows);
    var scope_rows: std.ArrayList(ExternalScope) = .empty;
    defer scope_rows.deinit(allocator);
    var key_rows: std.ArrayList(ExternalKey) = .empty;
    defer key_rows.deinit(allocator);
    for (identities, 0..) |identity, index| {
        if (identity.scopes) |scopes| for (scopes) |scope| try scope_rows.append(allocator, try stored.lower(pool, scope));
        if (identity.keys) |keys| for (keys) |key| try key_rows.append(allocator, try stored.lower(pool, key));
        if (scope_rows.items.len > std.math.maxInt(u32) or key_rows.items.len > std.math.maxInt(u32)) return error.InvalidExternalDomain;
        identity_rows[index] = .{
            .name = try pool.intern(identity.name),
            .key_policy = identity.key_policy,
            .allowed_scopes = identity.allowed_scopes,
            .has_scopes = identity.scopes != null,
            .has_keys = identity.keys != null,
            .scope_end = @intCast(scope_rows.items.len),
            .key_end = @intCast(key_rows.items.len),
        };
    }
    var predicate_store = try Predicates.build(allocator, predicate_rows);
    defer predicate_store.deinit();
    var identity_store = try ExternalIdentities.build(allocator, identity_rows);
    defer identity_store.deinit();
    var scope_store = try ExternalScopes.build(allocator, scope_rows.items);
    defer scope_store.deinit();
    var key_store = try ExternalKeys.build(allocator, key_rows.items);
    defer key_store.deinit();
    var rank_store = try ExternalRanks.build(allocator, ranks);
    defer rank_store.deinit();
    return bytes.Bundle(Parts).build(allocator, .{
        .predicates = predicate_store.bytes,
        .identities = identity_store.bytes,
        .scopes = scope_store.bytes,
        .keys = key_store.bytes,
        .ranks = rank_store.bytes,
    });
}

pub fn ViewFor(comptime Source: type) type {
    const Span = bytes.Span(Source);
    return struct {
        predicates: Predicates.ViewFor(Span),
        identities: ExternalIdentities.ViewFor(Span),
        scopes: ExternalScopes.ViewFor(Span),
        keys: ExternalKeys.ViewFor(Span),
        ranks: ExternalRanks.ViewFor(Span),
        const Self = @This();
        pub const ReadError = Error || bytes.SourceError(Source);

        pub fn open(source: Source) ReadError!Self {
            const bundle = try bytes.Bundle(Parts).ViewFor(Source).open(source);
            return .{
                .predicates = try Predicates.ViewFor(Span).open(bundle.part(.predicates)),
                .identities = try ExternalIdentities.ViewFor(Span).open(bundle.part(.identities)),
                .scopes = try ExternalScopes.ViewFor(Span).open(bundle.part(.scopes)),
                .keys = try ExternalKeys.ViewFor(Span).open(bundle.part(.keys)),
                .ranks = try ExternalRanks.ViewFor(Span).open(bundle.part(.ranks)),
            };
        }

        pub fn declare(self: *const Self, domains: *model.DomainCatalogue) ReadError!void {
            try domains.setOwned(.predicate, @intCast(self.predicates.row_count));
            try domains.setOwned(.external_domain, @intCast(self.identities.row_count));
            for (0..self.ranks.row_count) |index| {
                const rank = try self.ranks.row(index);
                try domains.declareExternal(rank.kind, rank.count);
            }
        }

        pub fn verify(self: *const Self, domains: model.DomainCatalogue) ReadError!void {
            try self.predicates.verify(domains);
            try self.identities.verify(domains);
            try self.scopes.verify(domains);
            try self.keys.verify(domains);
            try self.ranks.verify(domains);
            var scope_start: u32 = 0;
            var key_start: u32 = 0;
            for (0..self.identities.row_count) |index| {
                const domain = try self.identities.row(index);
                if (domain.scope_end < scope_start or domain.scope_end > self.scopes.row_count or
                    domain.key_end < key_start or domain.key_end > self.keys.row_count)
                    return error.InvalidExternalDomain;
                if (!domain.has_scopes and domain.scope_end != scope_start) return error.InvalidExternalDomain;
                if (!domain.has_keys and domain.key_end != key_start) return error.InvalidExternalDomain;
                for (0..index) |prior| if ((try self.identities.field(.name, prior)) == domain.name) return error.InvalidExternalDomain;
                for (scope_start..domain.scope_end) |left| {
                    const scope = try self.scopes.row(left);
                    if (!domain.allowed_scopes.contains(scopeKind(scope))) return error.InvalidExternalDomain;
                    for (scope_start..left) |right| if (std.meta.eql(scope, try self.scopes.row(right))) return error.InvalidExternalDomain;
                }
                for (key_start..domain.key_end) |left| {
                    const key = try self.keys.row(left);
                    if (!keyAllowed(domain.key_policy, key)) return error.InvalidExternalDomain;
                    for (key_start..left) |right| if (std.meta.eql(key, try self.keys.row(right))) return error.InvalidExternalDomain;
                }
                scope_start = domain.scope_end;
                key_start = domain.key_end;
            }
            if (scope_start != self.scopes.row_count or key_start != self.keys.row_count) return error.InvalidExternalDomain;
        }

        pub fn predicate(self: *const Self, id: model.PredicateId) ReadError!Predicate {
            return self.predicates.row(@intFromEnum(id));
        }

        pub fn externalDomain(self: *const Self, id: model.ExternalDomainId) ReadError!ExternalIdentityDomain {
            return self.identities.row(@intFromEnum(id));
        }

        pub fn externalScopes(self: *const Self, id: model.ExternalDomainId) ReadError!ScopeCursor {
            const index = @intFromEnum(id);
            const domain = try self.externalDomain(id);
            const start = if (index == 0) 0 else try self.identities.field(.scope_end, index - 1);
            return .{ .view = self.*, .next = start, .end = domain.scope_end };
        }

        pub fn externalKeys(self: *const Self, id: model.ExternalDomainId) ReadError!KeyCursor {
            const index = @intFromEnum(id);
            const domain = try self.externalDomain(id);
            const start = if (index == 0) 0 else try self.identities.field(.key_end, index - 1);
            return .{ .view = self.*, .next = start, .end = domain.key_end };
        }

        pub const ScopeCursor = struct {
            view: Self,
            next: u32,
            end: u32,
            pub fn nextScope(self: *@This()) ReadError!?ExternalScope {
                if (self.next > self.end) return error.InvalidExternalDomain;
                if (self.next == self.end) return null;
                const result = try self.view.scopes.row(self.next);
                self.next = std.math.add(u32, self.next, 1) catch return error.Overflow;
                return result;
            }
        };

        pub const KeyCursor = struct {
            view: Self,
            next: u32,
            end: u32,
            pub fn nextKey(self: *@This()) ReadError!?ExternalKey {
                if (self.next > self.end) return error.InvalidExternalDomain;
                if (self.next == self.end) return null;
                const result = try self.view.keys.row(self.next);
                self.next = std.math.add(u32, self.next, 1) catch return error.Overflow;
                return result;
            }
        };

        pub fn validateExternal(self: *const Self, reference: stored.Type(model.ExternalReference)) ReadError!void {
            const domain = try self.externalDomain(reference.domain);
            if (!keyAllowed(domain.key_policy, reference.key) or !domain.allowed_scopes.contains(scopeKind(reference.scope))) return error.InvalidExternalDomain;
            const index = @intFromEnum(reference.domain);
            const scope_start = if (index == 0) 0 else try self.identities.field(.scope_end, index - 1);
            const key_start = if (index == 0) 0 else try self.identities.field(.key_end, index - 1);
            if (domain.has_scopes) {
                var found = false;
                for (scope_start..domain.scope_end) |position| if (std.meta.eql(reference.scope, try self.scopes.row(position))) {
                    found = true;
                    break;
                };
                if (!found) return error.InvalidExternalDomain;
            }
            if (domain.has_keys) {
                var found = false;
                for (key_start..domain.key_end) |position| if (std.meta.eql(reference.key, try self.keys.row(position))) {
                    found = true;
                    break;
                };
                if (!found) return error.InvalidExternalDomain;
            }
        }

        pub fn matches(self: *const Self, constraint: model.EndpointConstraint, target: anytype) ReadError!bool {
            _ = self;
            return switch (constraint) {
                .any => true,
                .record => |kind| target == .record and (kind == null or std.meta.activeTag(target.record) == kind.?),
                .value => target == .value,
                .fact => target == .fact,
                .occurrence => target == .occurrence,
                .span => target == .span,
                .external => |domain| target == .external and (domain == null or target.external.domain == domain.?),
            };
        }

        fn keyAllowed(policy: model.ExternalKeyPolicy, key: stored.Type(model.Identity)) bool {
            return switch (policy) {
                .numeric => key == .numeric,
                .text => key == .text,
                .either => true,
            };
        }

        fn scopeKind(scope: stored.Type(model.ExternalScope)) model.ScopeKind {
            return switch (scope) {
                .global => .global,
                .document => .document,
                .source => .source,
            };
        }
    };
}

pub const View = ViewFor([]const u8);

test "declarations retain endpoint constraints and absent differs from empty catalogues" {
    var pool = strings.Builder.init(std.testing.allocator);
    defer pool.deinit();
    const predicates = [_]model.PredicateInput{.{
        .name = "translation",
        .subject = .{ .record = .sense },
        .object = .{ .external = @enumFromInt(1) },
    }};
    const identities = [_]model.ExternalIdentityDomainInput{
        .{ .name = "open", .key_policy = .text },
        .{ .name = "closed", .key_policy = .text, .scopes = &.{}, .keys = &.{} },
    };
    var owned = try build(std.testing.allocator, &pool, &predicates, &identities, &.{});
    defer owned.deinit();
    const open_reference = try stored.lower(&pool, model.ExternalReference{
        .domain = @enumFromInt(0),
        .key = .{ .text = "anything" },
    });
    const closed_reference = try stored.lower(&pool, model.ExternalReference{
        .domain = @enumFromInt(1),
        .key = .{ .text = "anything" },
    });
    var pool_owned = try pool.build(std.testing.allocator);
    defer pool_owned.deinit();
    const pool_view = try strings.View.open(pool_owned.bytes);
    try pool_view.verify(std.testing.allocator);
    const view = try View.open(owned.bytes);
    var domains: model.DomainCatalogue = .{};
    try domains.setOwned(.string, @intCast(pool_view.count()));
    try domains.setOwned(.document, 0);
    try view.declare(&domains);
    try view.verify(domains);
    try view.validateExternal(open_reference);
    try std.testing.expectError(error.InvalidExternalDomain, view.validateExternal(closed_reference));
    const predicate = try view.predicate(@enumFromInt(0));
    try std.testing.expect(predicate.subject.record.? == .sense);
    try std.testing.expectEqual(@as(model.ExternalDomainId, @enumFromInt(1)), predicate.object.external.?);
}
