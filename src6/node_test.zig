const std = @import("std");
const model = @import("model.zig");
const nodes = @import("nodes.zig");
const query = @import("query.zig");
const validate = @import("validate.zig");

test "one structural cursor resolves every metadata owner and exposes ancestors" {
    const shared: model.SharedValue = .{
        .meta = .{ .id = "shared-number" },
        .value = .{ .symbol = .{ .local = "plural" } },
    };
    const entry: model.Entry = .{
        .id = "entry",
        .headword = "banks",
        .content = &.{.{ .form = .{
            .meta = .{ .id = "form" },
            .representations = &.{.{
                .meta = .{ .id = "representation" },
                .text = .{ .content = &.{.{ .text = "banks" }} },
                .features = &.{
                    .{ .meta = .{ .id = "feature" }, .name = .{ .local = "number" }, .value = .{ .shared = &shared } },
                    .{ .name = .{ .local = "agreement" }, .value = .{ .structure = .{
                        .meta = .{ .id = "structure" },
                        .fields = &.{.{ .name = .{ .local = "number" }, .value = .{ .reference = .{ .local = "shared-number" } } }},
                    } } },
                },
            }},
            .content = &.{.{ .sense = .{
                .meta = .{ .id = "sense" },
                .content = &.{.{ .definition = .{ .meta = .{ .id = "definition" } } }},
            } }},
        } }},
    };

    try validate.check(std.testing.allocator, &entry, .{});
    try std.testing.expect((try query.resolve(&entry, "representation")).?.as(model.Representation) != null);
    try std.testing.expect((try query.resolve(&entry, "feature")).?.as(model.Feature) != null);
    try std.testing.expect((try query.resolve(&entry, "structure")).?.as(model.Structure) != null);
    try std.testing.expect((try query.resolve(&entry, "shared-number")).?.as(model.SharedValue) != null);

    var definitions = query.entry(&entry).descendants(model.Text, .{});
    while (try definitions.next()) |definition| {
        if (!std.mem.eql(u8, definition.value.meta.id orelse "", "definition")) continue;
        var ancestors = definition.ancestors(model.Sense);
        try std.testing.expectEqualStrings("sense", ancestors.next().?.meta.id.?);
        break;
    } else return error.TestExpectedEqual;
}

test "structural work and depth failures are sticky" {
    const entry: model.Entry = .{ .id = "e", .headword = "e" };
    var no_depth = nodes.Cursor(model.Entry).init(&entry, .{}, .{ .max_depth = 0 });
    try std.testing.expectError(error.DepthLimit, no_depth.next());
    try std.testing.expectError(error.DepthLimit, no_depth.next());
    var cursor = nodes.Cursor(model.Entry).init(&entry, .{}, .{ .max_work = 2 });
    _ = try cursor.next();
    try std.testing.expectError(error.WorkLimit, cursor.next());
    try std.testing.expectError(error.WorkLimit, cursor.next());
}

fn expectResolved(value: anytype, id: []const u8, comptime T: type) !void {
    try std.testing.expect((try query.resolve(value, id)).?.as(T) != null);
}

test "all metadata owner families admitted by validation use public resolution" {
    const shared: model.SharedValue = .{ .meta = .{ .id = "shared" }, .value = .{ .integer = 1 } };
    const entry_value: model.Entry = .{
        .id = "owners",
        .headword = "owners",
        .content = &.{
            .{ .form = .{ .meta = .{ .id = "form" }, .representations = &.{.{
                .meta = .{ .id = "representation" },
                .text = .{ .meta = .{ .id = "representation-text" } },
            }} } },
            .{ .sense = .{
                .meta = .{ .id = "sense" },
                .denotations = &.{.{ .meta = .{ .id = "denotation" }, .iri = "urn:thing" }},
            } },
            .{ .definition = .{ .meta = .{ .id = "definition" } } },
            .{ .example = .{ .meta = .{ .id = "example" } } },
            .{ .translation = .{ .meta = .{ .id = "translation" } } },
            .{ .grammar = .{
                .meta = .{ .id = "feature" },
                .name = .{ .local = "number" },
                .value = .{ .structure = .{
                    .meta = .{ .id = "structure" },
                    .fields = &.{.{ .name = .{ .local = "binding" }, .value = .{ .shared = &shared } }},
                } },
            } },
            .{ .usage = .{ .meta = .{ .id = "usage" }, .kind = .domain, .value = .unknown } },
            .{ .etymology = .{ .meta = .{ .id = "etymology" } } },
            .{ .relation = .{
                .meta = .{ .id = "relation" },
                .predicate = .synonym,
                .endpoints = .{ .binary = .{ .unresolved = .{ .identifier = "elsewhere" } } },
            } },
            .{ .concept = .{
                .meta = .{ .id = "concept" },
                .reference = .{ .unresolved = .{ .identifier = "concept" } },
            } },
            .{ .note = .{ .meta = .{ .id = "note" } } },
            .{ .media = .{ .meta = .{ .id = "media" }, .uri = "urn:media", .media_type = "text/plain" } },
            .{ .frame = .{ .meta = .{ .id = "frame" }, .name = .{ .local = "frame" } } },
            .{ .component = .{
                .meta = .{ .id = "component" },
                .target = .{ .unresolved = .{ .identifier = "component" } },
            } },
            .{ .extension = .{ .meta = .{ .id = "extension" }, .name = .{ .local = "extra" } } },
        },
    };
    try validate.check(std.testing.allocator, &entry_value, .{});
    try expectResolved(&entry_value, "form", model.Form);
    try expectResolved(&entry_value, "representation", model.Representation);
    try expectResolved(&entry_value, "representation-text", model.Text);
    try expectResolved(&entry_value, "sense", model.Sense);
    try expectResolved(&entry_value, "denotation", model.Denotation);
    try expectResolved(&entry_value, "definition", model.Text);
    try expectResolved(&entry_value, "example", model.Example);
    try expectResolved(&entry_value, "translation", model.Translation);
    try expectResolved(&entry_value, "feature", model.Feature);
    try expectResolved(&entry_value, "structure", model.Structure);
    try expectResolved(&entry_value, "shared", model.SharedValue);
    try expectResolved(&entry_value, "usage", model.Usage);
    try expectResolved(&entry_value, "etymology", model.Etymology);
    try expectResolved(&entry_value, "relation", model.Relation);
    try expectResolved(&entry_value, "concept", model.Concept);
    try expectResolved(&entry_value, "note", model.Text);
    try expectResolved(&entry_value, "media", model.Media);
    try expectResolved(&entry_value, "frame", model.Frame);
    try expectResolved(&entry_value, "component", model.Component);
    try expectResolved(&entry_value, "extension", model.Extension);

    const range: model.Resource = .{ .range = .{
        .id = "range-resource",
        .meta = .{ .id = "range" },
        .elements = &.{.{
            .meta = .{ .id = "range-element" },
            .value = .{ .symbol = .{ .local = "noun" } },
            .labels = &.{.{ .meta = .{ .id = "range-label" } }},
        }},
    } };
    try validate.check(std.testing.allocator, &range, .{});
    try expectResolved(&range, "range", model.Range);
    try expectResolved(&range, "range-element", model.RangeElement);
    try expectResolved(&range, "range-label", model.Text);

    const library: model.Resource = .{ .values = .{
        .id = "value-resource",
        .meta = .{ .id = "value-library" },
        .values = &.{.{ .meta = .{ .id = "library-value" }, .value = .unspecified }},
    } };
    try validate.check(std.testing.allocator, &library, .{});
    try expectResolved(&library, "value-library", model.ValueLibrary);
    try expectResolved(&library, "library-value", model.SharedValue);
}

test "duplicate shared definitions and comparison work are bounded consistently" {
    const shared: model.SharedValue = .{ .meta = .{ .id = "shared" }, .value = .{ .integer = 1 } };
    const duplicate: model.Entry = .{
        .id = "duplicate",
        .headword = "duplicate",
        .content = &.{
            .{ .grammar = .{ .name = .{ .local = "one" }, .value = .{ .shared = &shared } } },
            .{ .grammar = .{ .name = .{ .local = "two" }, .value = .{ .shared = &shared } } },
        },
    };
    try std.testing.expectError(error.DuplicateIdentity, validate.check(std.testing.allocator, &duplicate, .{}));

    const compared: model.Entry = .{
        .id = "compared",
        .headword = "compared",
        .meta = .{ .attributes = &.{
            .{ .name = .{ .local = "one" }, .value = "1" },
            .{ .name = .{ .local = "two" }, .value = "2" },
        } },
    };
    var cursor = nodes.Cursor(model.Entry).init(&compared, .{}, .{});
    while (try cursor.next()) |_| {}
    try std.testing.expectError(error.ResourceLimit, validate.check(std.testing.allocator, &compared, .{
        .limits = .{ .max_values = cursor.work },
    }));
}

const forward_links: model.Entry = .{
    .id = "forward",
    .headword = "forward",
    .keys = &.{.{ .spelling = "alias", .form = "form" }},
    .content = &.{
        .{ .relation = .{ .predicate = .evokes, .endpoints = .{ .binary = .{ .local = "concept" } } } },
        .{ .relation = .{ .predicate = .lexicalized_sense, .endpoints = .{ .binary = .{ .local = "sense" } } } },
        .{ .concept = .{ .meta = .{ .id = "concept" }, .reference = .{ .local = "sense" } } },
        .{ .sense = .{ .meta = .{ .id = "sense" } } },
        .{ .form = .{ .meta = .{ .id = "form" } } },
    },
};

fn admitForwardLinks(allocator: std.mem.Allocator) !void {
    try validate.check(allocator, &forward_links, .{});
}

test "single-pass admission retains bounded typed forward-link obligations" {
    try admitForwardLinks(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, admitForwardLinks, .{});
    var cursor = nodes.Cursor(model.Entry).init(&forward_links, .{}, .{});
    while (try cursor.next()) |_| {}
    // A traversal-only allowance cannot pay for binding local references.
    try std.testing.expectError(error.ResourceLimit, validate.check(std.testing.allocator, &forward_links, .{
        .limits = .{ .max_values = cursor.work },
    }));
}
