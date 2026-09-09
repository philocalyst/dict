const std = @import("std");
const axes = @import("axes.zig");
const automaton = @import("automaton.zig");
const compiler = @import("compiler.zig");
const concepts = @import("concepts.zig");
const forest = @import("forest.zig");
const grammar = @import("grammar.zig");
const relations = @import("relations.zig");
const schema = @import("schema.zig");
const snapshot = @import("snapshot.zig");
const terms = @import("terms.zig");

test "snapshot discovers and verifies canonical axes terms concepts and relations" {
    const allocator = std.testing.allocator;

    var keys = automaton.Builder.init(allocator);
    defer keys.deinit();
    try keys.addEntry("cat", 1);
    try keys.addEntry("dog", 1);
    var auto = try keys.finish();
    defer auto.deinit();

    var trees = forest.Builder.init(allocator);
    defer trees.deinit();
    _ = try trees.addRoot("cat", .entry);
    _ = try trees.addRoot("dog", .entry);
    var tree = try trees.build();
    defer tree.deinit();

    var prose = try grammar.build(allocator, &.{.{ .text = "definition" }}, .{});
    defer prose.deinit();

    var axis_builder = axes.AxisBuilder(axes.Normalized).init(allocator);
    defer axis_builder.deinit();
    _ = try axis_builder.addEntry("cat", 1);
    _ = try axis_builder.addEntry("dog", 1);
    var normalized = try axis_builder.finish();
    defer normalized.deinit();

    var term_builder = terms.Builder.init(allocator, 2);
    defer term_builder.deinit();
    try term_builder.add("cat", &.{@enumFromInt(0)});
    var term_index = try term_builder.finish();
    defer term_index.deinit();

    var concept_builder = concepts.ConceptBuilder.init(allocator, 1, 1);
    defer concept_builder.deinit();
    try concept_builder.put(@enumFromInt(0), @enumFromInt(0));
    var concept_index = try concept_builder.finish();
    defer concept_index.deinit();

    var relation_builder = relations.Builder.init(allocator, .{});
    defer relation_builder.deinit();
    try relation_builder.addTyped(.see_also, .entry, .entry, @enumFromInt(0), @enumFromInt(1), .{});
    var relation_index = try relation_builder.finish();
    defer relation_index.deinit();

    const extras = [_]compiler.Section{
        .{ .tag = .relations, .bytes = relation_index.bytes },
        .{ .tag = .concepts, .bytes = concept_index.bytes },
        .{ .tag = .terms, .bytes = term_index.bytes },
        .{ .tag = .normalized, .bytes = normalized.bytes },
    };
    var published = try compiler.buildWithExtras(
        allocator,
        .{ .automaton = auto.bytes, .forest = tree.bytes, .prose = prose.bytes },
        &extras,
        .{},
    );
    defer published.deinit();

    var trust = [_]u64{0} ** 64;
    var view = try snapshot.Snapshot.open(published.bytes, &trust, .{});
    try std.testing.expect(!view.isVerified());

    // Optional access is envelope/open-only and requires no allocator.  The
    // first semantic verifier is the explicit Snapshot.verify call below.
    const normalized_view = try view.axis(axes.Normalized);
    var transform_buffer: [16]u8 = undefined;
    const transformed = try axes.Normalized.apply("CAT", &transform_buffer);
    const normalized_hit = (try normalized_view.exact(transformed)).?;
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(try normalized_hit.targets.target(0)));
    const term_view = try view.terms();
    const term_hit = (try term_view.exact("cat")).?;
    var postings = term_hit.postings.iterator();
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum((try postings.next()).?));

    try view.verify(allocator);
    try std.testing.expect(view.isVerified());

    const concept_view = try view.concepts();
    var members = try concept_view.members(@enumFromInt(0));
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum((try members.next()).?));
    try std.testing.expectEqual(@as(?concepts.SenseRank, null), try members.next());
    // This fixture intentionally owns a nonstructural sense domain. It is
    // usable as an independent index, but cannot masquerade as tree ranks.
    var query = try view.query();
    try std.testing.expectError(error.CrossSectionMismatch, query.members(@enumFromInt(0)));

    const relation_view = try view.relations();
    var relations_for_entry = try relation_view.relations(
        try relations.Endpoint.fromRank(.entry, @enumFromInt(0)),
        .see_also,
    );
    const edge = (try relations_for_entry.next()).?;
    try std.testing.expectEqual(schema.RelationId.see_also, edge.relation);
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(edge.target.rank));
}
