const std = @import("std");
const model = @import("model.zig");
const query = @import("query.zig");
const render = @import("render.zig");
const validate = @import("validate.zig");
const fixtures = @import("fixtures.zig");
const testing = std.testing;

test "rich lexical values preserve scope, nested senses and actual payload types" {
    try validate.check(testing.allocator, &fixtures.rich, .{});
    var senses = query.entry(&fixtures.rich).select(.sense, .descendants);
    const finance = (try senses.next()).?;
    try testing.expectEqual(@as(?[]const u8, "finance"), finance.value.meta.id);
    try testing.expectEqualStrings("building", (try senses.next()).?.value.meta.id.?);
    try testing.expect((try senses.next()) == null);

    var immediate = query.entry(&fixtures.rich).select(.sense, .children);
    _ = try immediate.next();
    try testing.expect((try immediate.next()) == null);
    const building = (try query.resolve(&fixtures.rich, "building")).?;
    try testing.expectEqual(@as(?[]const u8, null), building.language.value);
    try testing.expect(building.language.declaration.?.* == .reset);
    const sense = (try query.resolve(&fixtures.rich, "finance")).?;
    try testing.expectEqualStrings("en", sense.language.value.?);
}

test "plain rendering and UTF-8 snippets do not discard mixed content" {
    var definitions = query.entry(&fixtures.rich).select(.definition, .descendants);
    const definition = (try definitions.next()).?;
    var output: [200]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try render.write(definition.value.*, &writer, .plain);
    try testing.expectEqualStrings("A financial institution & its offices.", writer.buffered());
    writer = std.Io.Writer.fixed(&output);
    try render.write(definition.value.*, &writer, .xml);
    try testing.expectEqualStrings("A <hi xmlns=\"http://www.tei-c.org/ns/1.0\">financial</hi> institution &amp; its offices.", writer.buffered());

    const unicode: model.Text = .{ .content = &.{ .{ .text = "é" }, .{ .text = "水!" } } };
    for (0..7) |length| {
        const result = try render.snippet(unicode, output[0..length]);
        try testing.expect(std.unicode.utf8ValidateSlice(result));
        try testing.expectEqualStrings(switch (length) {
            0, 1 => "",
            2, 3, 4 => "é",
            5 => "é水",
            else => "é水!",
        }, result);
    }
    var tiny: [1]u8 = undefined;
    writer = std.Io.Writer.fixed(&tiny);
    try testing.expectError(error.WriteFailed, render.write(definition.value.*, &writer, .plain));
}

test "local semantic links cannot point to missing or wrongly typed nodes" {
    var value: model.Entry = .{ .id = "x", .headword = "x", .content = &.{.{ .relation = .{ .predicate = .evokes, .target = .{ .local = "missing" } } }} };
    try testing.expectError(error.UnresolvedLocal, validate.check(testing.allocator, &value, .{}));
    value.content = &.{
        .{ .form = .{ .meta = .{ .id = "form" } } },
        .{ .relation = .{ .predicate = .evokes, .target = .{ .local = "form" } } },
    };
    try testing.expectError(error.InvalidReferenceKind, validate.check(testing.allocator, &value, .{}));
    value.content = &.{ .{ .sense = .{ .meta = .{ .id = "same" } } }, .{ .sense = .{ .meta = .{ .id = "same" } } } };
    try testing.expectError(error.DuplicateIdentity, validate.check(testing.allocator, &value, .{}));
}

test "ordered bags are not sets, malformed lexical values fail admission" {
    var value: model.Entry = .{ .id = "x", .headword = "x", .content = &.{.{ .grammar = .{ .name = .{ .local = "n" }, .value = .{ .set = &.{ .{ .integer = 1 }, .{ .integer = 1 } } } } }} };
    try testing.expectError(error.InvalidValue, validate.check(testing.allocator, &value, .{}));
    value.content = &.{.{ .grammar = .{ .name = .{ .local = "n" }, .value = .{ .bag = &.{ .{ .integer = 1 }, .{ .integer = 1 } } } } }};
    try validate.check(testing.allocator, &value, .{});
    value.content = &.{.{ .definition = .{ .content = &.{.{ .comment = "bad--comment" }} } }};
    try testing.expectError(error.InvalidMarkup, validate.check(testing.allocator, &value, .{}));
    value.content = &.{.{ .definition = .{ .meta = .{ .evidence = &.{.{ .target = .{ .anchor = .{ .source = "absent", .start = 0, .end = 1 } } }} } } }};
    try testing.expectError(error.InvalidAnchor, validate.check(testing.allocator, &value, .{}));
    try testing.expectError(error.ResourceLimit, validate.check(testing.allocator, &fixtures.rich, .{ .limits = .{ .max_values = 4 } }));
    try testing.expectError(error.ResourceLimit, validate.check(testing.allocator, &fixtures.rich, .{ .limits = .{ .max_bytes = 4 } }));
}

fn allocationHarness(allocator: std.mem.Allocator) !void {
    try validate.check(allocator, &fixtures.rich, .{});
}

test "semantic admission frees temporary indexes at every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationHarness, .{});
}

test "language cannot have a competing raw attribute authority" {
    const value: model.Entry = .{
        .id = "language",
        .headword = "language",
        .content = &.{.{ .definition = .{ .content = &.{.{ .element = .{
            .name = .{ .local = "foreign" },
            .attributes = &.{.{
                .name = .{ .namespace = "http://www.w3.org/XML/1998/namespace", .prefix = "xml", .local = "lang" },
                .value = "fr",
            }},
        } }} } }},
    };
    try testing.expectError(error.InvalidMarkup, validate.check(testing.allocator, &value, .{}));
}

test "library source scope is borrowed, not rebuilt for each document" {
    var sources = validate.SourceIndex{};
    defer sources.deinit(testing.allocator);
    try sources.add(testing.allocator, "shared", 12);
    try testing.expectError(error.InvalidIdentity, sources.add(testing.allocator, "", 0));
    try testing.expectError(error.InvalidUtf8, sources.add(testing.allocator, "\xff", 0));

    const scope: validate.Scope = .{ .sources = &sources };
    var entry: model.Entry = .{
        .id = "first",
        .headword = "first",
        .meta = .{ .origins = &.{.{ .anchor = .{ .source = "shared", .start = 0, .end = 12 } }} },
    };
    // With no local identities or embedded sources, admission needs no heap.
    // A future accidental copy of the shared index fails this deterministic gate.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try validate.check(failing.allocator(), &entry, scope);
    entry.id = "second";
    try validate.check(failing.allocator(), &entry, scope);
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try testing.expectEqual(@as(usize, 1), sources.count());

    entry.sources = &.{.{ .id = "shared", .media_type = "text/plain", .bytes = "same" }};
    try testing.expectError(error.DuplicateIdentity, validate.check(testing.allocator, &entry, scope));
    try testing.expectError(error.ResourceLimit, validate.check(testing.allocator, &entry, .{
        .sources = &sources,
        .limits = .{ .max_values = 0 },
    }));
}
