const std = @import("std");
const automaton = @import("automaton.zig");
const compiler = @import("compiler.zig");
const forest = @import("forest.zig");
const grammar = @import("grammar.zig");
const schema = @import("schema.zig");
const snapshot = @import("snapshot.zig");

fn fixture(allocator: std.mem.Allocator) !struct { auto: automaton.Owned, tree: forest.Owned, prose: grammar.Owned } {
    var keys = automaton.Builder.init(allocator);
    defer keys.deinit();
    try keys.addForm("alp", &.{0});
    try keys.addEntry("alpha", 1);
    try keys.addEntry("alpine", 1);
    const auto = try keys.finish();

    var trees = forest.Builder.init(allocator);
    defer trees.deinit();
    const first = try trees.addRoot("alpha", .entry);
    const first_sense = try trees.addChild(first, .sense);
    _ = try trees.addChild(first_sense, .definition);
    const second = try trees.addRoot("alpine", .entry);
    const second_sense = try trees.addChild(second, .sense);
    _ = try trees.addChild(second_sense, .definition);
    const tree = try trees.build();

    const prose = try grammar.build(allocator, &.{ .{ .text = "first" }, .{ .text = "second" } }, .{});
    return .{ .auto = auto, .tree = tree, .prose = prose };
}

test "compiler publishes a queryable authenticated snapshot" {
    var parts = try fixture(std.testing.allocator);
    defer parts.auto.deinit();
    defer parts.tree.deinit();
    defer parts.prose.deinit();

    var published = try compiler.buildWithProseMap(
        std.testing.allocator,
        .{ .automaton = parts.auto.bytes, .forest = parts.tree.bytes, .prose = parts.prose.bytes },
        &.{.{ .kind = .definition, .first = 0, .count = 2 }},
        &.{},
        .{ .prose_alignment = .one_per_entry },
    );
    defer published.deinit();
    var trust = [_]u64{0} ** 64;
    var view = try snapshot.Snapshot.open(published.bytes, &trust, .{});
    var query = try view.query();
    const hit = (try query.exact("alp")).?;
    try std.testing.expect(hit.entry_range == null);
    try std.testing.expectEqual(@as(u32, 1), hit.targets.len());
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(try hit.targets.target(0)));

    var key = [_]u8{0} ** 32;
    const entry = (try query.entry(@enumFromInt(1), key[0..])).?;
    try std.testing.expectEqualStrings("alpine", entry.headword());
    var text = [_]u8{0} ** 16;
    var dfs: [256]grammar.Frame = undefined;
    var definitions = try query.texts(.definition, @enumFromInt(1));
    const definition = (try definitions.next()).?;
    const n = try definition.render(text[0..], dfs[0..]);
    try std.testing.expectEqualStrings("second", text[0..n]);
    try std.testing.expect(!view.isVerified());
    try view.verify(std.testing.allocator);
    try std.testing.expect(view.isVerified());
}

test "compiler rejects a mismatched prose cardinality before writing" {
    var parts = try fixture(std.testing.allocator);
    defer parts.auto.deinit();
    defer parts.tree.deinit();
    defer parts.prose.deinit();
    var bad_prose = try grammar.build(std.testing.allocator, &.{.{ .text = "only" }}, .{});
    defer bad_prose.deinit();
    const sections = [_]compiler.Section{
        .{ .tag = .automaton, .bytes = parts.auto.bytes },
        .{ .tag = .forest, .bytes = parts.tree.bytes },
        .{ .tag = .prose, .bytes = bad_prose.bytes },
    };
    try std.testing.expectError(error.CrossSectionMismatch, compiler.compile(std.testing.allocator, .{ .sections = &sections }, .{ .prose_alignment = .one_per_entry }));
}

test "compiler output is independent of optional section input order" {
    var parts = try fixture(std.testing.allocator);
    defer parts.auto.deinit();
    defer parts.tree.deinit();
    defer parts.prose.deinit();
    const a = [_]compiler.Section{
        .{ .tag = .prose, .bytes = parts.prose.bytes },
        .{ .tag = .forest, .bytes = parts.tree.bytes },
        .{ .tag = .automaton, .bytes = parts.auto.bytes },
    };
    const b = [_]compiler.Section{
        .{ .tag = .automaton, .bytes = parts.auto.bytes },
        .{ .tag = .forest, .bytes = parts.tree.bytes },
        .{ .tag = .prose, .bytes = parts.prose.bytes },
    };
    var first = try compiler.compile(std.testing.allocator, .{ .sections = &a }, .{ .prose_alignment = .one_per_entry });
    defer first.deinit();
    var second = try compiler.compile(std.testing.allocator, .{ .sections = &b }, .{ .prose_alignment = .one_per_entry });
    defer second.deinit();
    try std.testing.expectEqualSlices(u8, first.bytes, second.bytes);
    try std.testing.expectEqual(schema.digest(), (try snapshot.Snapshot.openUncached(first.bytes, .{})).schemaDigest());
}
