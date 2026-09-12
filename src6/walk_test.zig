const std = @import("std");
const model = @import("model.zig");
const walk = @import("walk.zig");
const query = @import("query.zig");
const render = @import("render.zig");
const t = std.testing;

test "chained lexical and inline queries retain the declaring language" {
    const article: model.Entry = .{
        .id = "context",
        .headword = "context",
        .meta = .{ .language = .{ .tag = "en" } },
        .content = &.{.{ .sense = .{
            .content = &.{.{ .definition = .{ .content = &.{
                .{ .text = "English" },
                .{ .element = .{
                    .name = .{ .local = "span" },
                    .language = .reset,
                    .content = &.{.{ .text = "unknown" }},
                } },
                .{ .element = .{
                    .name = .{ .local = "span" },
                    .language = .{ .tag = "fr" },
                    .content = &.{.{ .text = "français" }},
                } },
                .{ .text = "English again" },
            } } }},
        } }},
    };
    var senses = query.entry(&article).select(.sense, .children);
    const sense = (try senses.next()).?;
    var definitions = sense.select(.definition, .children);
    const definition = (try definitions.next()).?;
    try t.expectEqualStrings("en", definition.language.value.?);
    try t.expectEqual(&article.meta.language, definition.language.declaration.?);
    var inlines = definition.inlines();
    try t.expectEqualStrings("en", (try inlines.next()).?.language.value.?);
    const reset = (try inlines.next()).?;
    try t.expect(reset.language.value == null);
    try t.expect(reset.language.declaration.?.* == .reset);
    try t.expectEqual(reset.language.declaration, (try inlines.next()).?.language.declaration);
    try t.expectEqualStrings("fr", (try inlines.next()).?.language.value.?);
    try t.expectEqualStrings("fr", (try inlines.next()).?.language.value.?);
    try t.expectEqualStrings("en", (try inlines.next()).?.language.value.?);
    try t.expect((try inlines.next()) == null);
    try t.expect((try inlines.next()) == null);
}

test "enter leave pairs preserve empty nodes, sibling order and identity" {
    const tree = [_]model.Inline{
        .{ .element = .{ .name = .{ .local = "outer" }, .content = &.{
            .{ .text = "a" },
            .{ .element = .{ .name = .{ .local = "empty" } } },
        } } },
        .{ .text = "b" },
    };
    var cursor = walk.Cursor(model.Inline).init(&tree, .{}, .{ .leave_events = true });
    var stack: [8]*const model.Inline = undefined;
    var depth: usize = 0;
    var enters: usize = 0;
    var leaves: usize = 0;
    while (try cursor.next()) |event| switch (event.phase) {
        .enter => {
            stack[depth] = event.node;
            depth += 1;
            enters += 1;
        },
        .leave => {
            depth -= 1;
            try t.expectEqual(stack[depth], event.node);
            leaves += 1;
        },
    };
    try t.expectEqual(@as(usize, 4), enters);
    try t.expectEqual(enters, leaves);
    try t.expectEqual(@as(usize, 0), depth);

    var output: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try render.write(.{ .content = &tree }, &writer, .xml);
    try t.expectEqualStrings("<outer xmlns=\"\">a<empty xmlns=\"\"></empty></outer>b", writer.buffered());
}

test "bounded cursor failure is sticky for both specialized node kinds" {
    var nodes: [walk.max_depth + 1]model.Item = undefined;
    for (&nodes, 0..) |*node, index| node.* = .{ .sense = .{
        .content = if (index + 1 == nodes.len) &.{} else nodes[index + 1 ..][0..1],
    } };
    var cursor = walk.Cursor(model.Item).init(nodes[0..1], .{}, .{});
    for (0..walk.max_depth - 1) |_| try t.expect((try cursor.next()) != null);
    try t.expectError(error.DepthLimit, cursor.next());
    try t.expectError(error.DepthLimit, cursor.next());
    var children = walk.Cursor(model.Item).init(nodes[0..1], .{}, .{ .scope = .children });
    try t.expect((try children.next()) != null);
    try t.expect((try children.next()) == null);

    var inlines: [walk.max_depth + 1]model.Inline = undefined;
    for (&inlines, 0..) |*node, index| node.* = .{ .element = .{
        .name = .{ .local = "n" },
        .content = if (index + 1 == inlines.len) &.{} else inlines[index + 1 ..][0..1],
    } };
    var inline_cursor = walk.Cursor(model.Inline).init(inlines[0..1], .{}, .{});
    for (0..walk.max_depth - 1) |_| try t.expect((try inline_cursor.next()) != null);
    try t.expectError(error.DepthLimit, inline_cursor.next());
    try t.expectError(error.DepthLimit, inline_cursor.next());
}

test "XML escaping preserves attribute whitespace and namespace resets" {
    const text: model.Text = .{ .content = &.{.{ .element = .{
        .name = .{ .namespace = "urn:test", .local = "n" },
        .attributes = &.{.{ .name = .{ .local = "label" }, .value = "\t\r\n\"&<>" }},
        .content = &.{ .{ .text = "\r" }, .{ .element = .{ .name = .{ .local = "plain" } } } },
    } }} };
    var output: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try render.write(text, &writer, .xml);
    try t.expectEqualStrings("<n xmlns=\"urn:test\" label=\"&#x9;&#xD;&#xA;&quot;&amp;&lt;&gt;\">&#xD;<plain xmlns=\"\"></plain></n>", writer.buffered());
}

test "ordinary typed field projections retain representation and text context" {
    const article: model.Entry = .{
        .id = "forms",
        .headword = "colour",
        .meta = .{ .language = .{ .tag = "en" } },
        .content = &.{.{ .form = .{ .representations = &.{
            .{ .meta = .{ .language = .{ .tag = "en-GB" } }, .text = .{ .content = &.{.{ .text = "colour" }} } },
            .{ .meta = .{ .language = .reset }, .text = .{ .content = &.{.{ .text = "color" }} } },
            .{ .text = .{ .meta = .{ .language = .{ .tag = "fr" } }, .content = &.{.{ .text = "couleur" }} } },
        } } }},
    };
    var forms = query.entry(&article).select(.form, .children);
    var representations = (try forms.next()).?.values(.representations);
    const british = representations.next().?.child(.text);
    try t.expectEqualStrings("en-GB", british.language.value.?);
    var inlines = british.inlines();
    try t.expectEqualStrings("en-GB", (try inlines.next()).?.language.value.?);
    const reset = representations.next().?.child(.text);
    try t.expect(reset.language.value == null);
    try t.expect(reset.language.declaration.?.* == .reset);
    try t.expectEqualStrings("fr", representations.next().?.child(.text).language.value.?);
    try t.expect(representations.next() == null);
}

test "field projection and traversal agree on tagged-node context" {
    const article: model.Entry = .{
        .id = "projection",
        .headword = "projection",
        .meta = .{ .language = .{ .tag = "en" } },
        .content = &.{.{ .definition = .{
            .meta = .{ .language = .reset },
            .content = &.{.{ .element = .{
                .name = .{ .local = "span" },
                .language = .{ .tag = "fr" },
                .content = &.{.{ .text = "français" }},
            } }},
        } }},
    };
    var fields = query.entry(&article).values(.content);
    const field = fields.next().?;
    var selected = query.entry(&article).select(.definition, .children);
    const definition = (try selected.next()).?;
    try t.expectEqual(definition.language.declaration, field.language.declaration);
    try t.expect(field.language.value == null);

    var inline_fields = definition.values(.content);
    var inline_walk = definition.inlines();
    const projected = inline_fields.next().?;
    try t.expectEqual((try inline_walk.next()).?.language.declaration, projected.language.declaration);
    try t.expectEqualStrings("fr", projected.language.value.?);
}
