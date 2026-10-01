const std = @import("std");
const model = @import("model.zig");
const validate = @import("validate.zig");
const query = @import("query.zig");
const walk = @import("walk.zig");
const nodes = @import("nodes.zig");

test "typed projections and both traversals share one language authority" {
    const Element = @FieldType(model.Inline, "element");
    const Container = struct { elements: []const Element };
    const container: Container = .{ .elements = &.{
        .{ .name = .{ .local = "span" }, .language = .{ .tag = "fr" }, .content = &.{.{ .text = "bonjour" }} },
        .{ .name = .{ .local = "span" }, .language = .reset, .content = &.{.{ .text = "reset" }} },
        .{ .name = .{ .local = "span" }, .content = &.{.{ .text = "inherit" }} },
    } };
    const inherited: walk.Language = .{ .value = "en" };
    const root: query.Match(Container) = .{ .value = &container, .language = inherited };
    var projected = root.values(.elements);
    var structural = nodes.Cursor(Container).init(&container, inherited, .{});
    const expected = [_]?[]const u8{ "fr", null, "en" };
    for (container.elements, expected) |element, language| {
        const projection = projected.next().?;
        try std.testing.expectEqualDeep(language, projection.language.value);
        const inline_node = [_]model.Inline{.{ .element = element }};
        var fast = walk.Cursor(model.Inline).init(&inline_node, inherited, .{});
        const fast_event = (try fast.next()).?;
        try std.testing.expectEqualDeep(language, fast_event.language.value);
        while (try structural.next()) |event| {
            if (event.node.as(Element) == null) continue;
            try std.testing.expectEqualDeep(projection.language, event.language);
            break;
        } else return error.TestExpectedEqual;
        // A direct field projection must retain reset as a declaration,
        // rather than silently restoring the inherited language.
        try std.testing.expectEqualDeep(projection.language, projection.child(.content).language);
    }
    try std.testing.expect(projected.next() == null);
}

fn entryWithLanguage(tag: []const u8) model.Entry {
    return .{
        .id = "e",
        .headword = "e",
        .meta = .{ .language = .{ .tag = tag } },
    };
}

test "RFC 5646 structural forms preserve spelling" {
    const valid = [_][]const u8{
        "en",                 "zh-cmn-Hans-CN", "sl-rozaj-biske-1994", "de-CH-1901",
        "en-US-u-ca-gregory", "x-private-Tag",  "en-GB-oed",           "sgn-BE-FR",
        "abcde-abcde",        "de-1901-a-1901", "de-x-1901-1901",
    };
    for (valid) |tag| {
        const value = entryWithLanguage(tag);
        try validate.check(std.testing.allocator, &value, .{});
        try std.testing.expectEqualStrings(tag, value.meta.language.tag);
    }
}

test "RFC 5646 malformed and duplicate subtags are rejected case-insensitively" {
    const invalid = [_][]const u8{
        "-en",          "en-",            "e",              "en--US",      "en-a", "en-x", "en-12",
        "de-1901-1901", "sl-rozaj-ROZAJ", "en-a-foo-A-bar", "not--a-tag-",
    };
    for (invalid) |tag| {
        const value = entryWithLanguage(tag);
        validate.check(std.testing.allocator, &value, .{}) catch |failure| {
            try std.testing.expectEqual(error.InvalidLanguage, failure);
            continue;
        };
        std.debug.print("unexpectedly accepted language tag: {s}\n", .{tag});
        return error.TestExpectedError;
    }
}
