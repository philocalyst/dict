const std = @import("std");
const model = @import("model.zig");
const query = @import("query.zig");
const validate = @import("validate.zig");

fn namedFeature(name: []const u8, match: anytype) bool {
    return std.mem.eql(u8, match.value.name.local, name);
}

fn atLeastDepth(minimum: usize, match: anytype) bool {
    return match.depth >= minimum;
}

fn itemKind(kind: model.Kind, match: anytype) bool {
    return std.meta.activeTag(match.value.*) == kind;
}

fn itemIdentity(id: []const u8, match: anytype) bool {
    return std.mem.eql(u8, match.value.metadata().id orelse "", id);
}

fn matchIdentity(id: []const u8, match: anytype) bool {
    return std.mem.eql(u8, match.value.meta.id orelse "", id);
}

test "exclusive relation modes and allocation-free filtering" {
    const entry: model.Entry = .{
        .id = "e",
        .headword = "e",
        .content = &.{
            .{ .sense = .{ .meta = .{ .id = "a" }, .content = &.{.{ .grammar = .{
                .name = .{ .local = "number" },
                .value = .{ .symbol = .{ .local = "plural" } },
            } }} } },
            .{ .sense = .{ .meta = .{ .id = "b" } } },
            .{ .relation = .{
                .predicate = .synonym,
                .endpoints = .{ .participants = &.{
                    .{ .role = .{ .local = "left-hand" }, .target = .{ .local = "a" } },
                    .{ .role = .{ .local = "right-hand" }, .target = .{ .local = "b" } },
                } },
            } },
        },
    };
    try validate.check(std.testing.allocator, &entry, .{});
    var features = query.entry(&entry).descendants(model.Feature, .{})
        .filter("number", namedFeature).filter(@as(usize, 2), atLeastDepth);
    const feature = (try features.next()).?;
    var ancestors = feature.ancestors(model.Sense);
    try std.testing.expectEqualStrings("a", ancestors.next().?.meta.id.?);
    try std.testing.expect((try features.next()) == null);

    var values = query.entry(&entry).values(.content)
        .filter(model.Kind.sense, itemKind).filter("a", itemIdentity);
    try std.testing.expectEqualStrings("a", values.next().?.value.sense.meta.id.?);
    try std.testing.expect(values.next() == null);

    var fast = query.entry(&entry).select(.sense, .descendants)
        .filter("a", matchIdentity).filter("a", matchIdentity);
    try std.testing.expectEqualStrings("a", (try fast.next()).?.value.meta.id.?);
    try std.testing.expect((try fast.next()) == null);
}

test "structural language reset and ancestors survive filter-wrapper moves" {
    const entry_value: model.Entry = .{
        .id = "language",
        .headword = "language",
        .meta = .{ .language = .{ .tag = "en" } },
        .content = &.{.{ .sense = .{
            .meta = .{ .id = "sense" },
            .content = &.{.{ .definition = .{
                .meta = .{ .id = "reset", .language = .reset },
                .content = &.{.{ .element = .{
                    .name = .{ .local = "foreign" },
                    .language = .{ .tag = "fr" },
                } }},
            } }},
        } }},
    };
    try validate.check(std.testing.allocator, &entry_value, .{});
    var reset = query.entry(&entry_value).descendants(model.Text, .{})
        .filter("reset", matchIdentity).filter(@as(usize, 2), atLeastDepth);
    const definition = (try reset.next()).?;
    try std.testing.expect(definition.language.value == null);
    try std.testing.expect(definition.language.declaration.?.* == .reset);
    var ancestors = definition.ancestors(model.Sense);
    try std.testing.expectEqualStrings("sense", ancestors.next().?.meta.id.?);

    var inlines = query.entry(&entry_value).descendants(model.Inline, .{});
    while (try inlines.next()) |inline_match| {
        if (inline_match.value.* != .element) continue;
        try std.testing.expectEqualStrings("fr", inline_match.language.value.?);
        break;
    } else return error.TestExpectedEqual;
}

test "memory library follow distinguishes found unavailable unresolved and hop limit" {
    const entries = [_]model.Entry{
        .{ .id = "one", .headword = "one" },
        .{ .id = "two", .headword = "two", .content = &.{.{ .sense = .{ .meta = .{ .id = "sense" } } }} },
    };
    const library: model.Library = .{ .entries = &entries };
    var session = query.FollowSession.init(&library, 3);
    const origin: query.DocumentRef = .{ .entry = &entries[0] };
    const found = try session.followFrom(origin, .{ .entry = .{ .id = "two", .fragment = "sense" } });
    try std.testing.expect(found.found.location.as(model.Sense) != null);
    const unavailable = try session.followFrom(origin, .{ .entry = .{ .id = "two", .fragment = "missing" } });
    try std.testing.expect(unavailable == .unavailable);
    const unresolved = try session.followFrom(origin, .{ .unresolved = .{ .identifier = "source-label" } });
    try std.testing.expect(unresolved == .unresolved);
    try std.testing.expectError(error.HopLimit, session.followFrom(origin, .{ .iri = "urn:x" }));
}
