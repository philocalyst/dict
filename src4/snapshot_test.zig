const std = @import("std");
const automaton = @import("automaton.zig");
const container = @import("container.zig");
const forest = @import("forest.zig");
const grammar = @import("grammar.zig");
const cold = @import("cold.zig");
const snapshot = @import("snapshot.zig");
const text_index = @import("text_index.zig");
const wire = @import("wire.zig");

const Fixture = struct {
    automaton: automaton.Owned,
    forest: forest.Owned,
    prose: grammar.Owned,
    text_index: ?text_index.Owned,
    bytes: []u8,
    trust: [1]u64 = .{0},

    fn deinit(self: *Fixture) void {
        self.allocator().free(self.bytes);
        self.prose.deinit();
        if (self.text_index) |*mapping| mapping.deinit();
        self.forest.deinit();
        self.automaton.deinit();
        self.* = undefined;
    }

    fn allocator(self: *const Fixture) std.mem.Allocator {
        return self.automaton.allocator;
    }
};

fn makeFixture(allocator: std.mem.Allocator, root_count: usize, prose_items: []const grammar.ItemInput) !Fixture {
    var automaton_builder = automaton.Builder.init(allocator);
    defer automaton_builder.deinit();
    try automaton_builder.addEntry("cat", 1);
    try automaton_builder.addForm("cats", &.{0});
    try automaton_builder.addEntry("dog", 1);
    var automaton_owned = try automaton_builder.finish();
    errdefer automaton_owned.deinit();

    var forest_builder = forest.Builder.init(allocator);
    defer forest_builder.deinit();
    if (root_count == 2 and prose_items.len == 3) {
        const first_root = try forest_builder.addRoot("cat", .entry);
        const first_sense = try forest_builder.addChild(first_root, .sense);
        _ = try forest_builder.addChild(first_sense, .definition);
        const second_root = try forest_builder.addRoot("dog", .entry);
        const second_sense = try forest_builder.addChild(second_root, .sense);
        _ = try forest_builder.addChild(second_sense, .definition);
        _ = try forest_builder.addChild(second_sense, .example);
    } else for (0..root_count) |_| _ = try forest_builder.addRoot("root", .entry);
    var forest_owned = try forest_builder.build();
    errdefer forest_owned.deinit();

    var prose_owned = try grammar.build(allocator, prose_items, .{});
    errdefer prose_owned.deinit();
    var mapping: ?text_index.Owned = null;
    errdefer if (mapping) |*owned| owned.deinit();
    var inputs: [4]container.Input = undefined;
    var input_count: usize = 0;
    inputs[input_count] = .{ .tag = .automaton, .bytes = automaton_owned.bytes };
    input_count += 1;
    if (root_count == 2 and prose_items.len == 3) {
        const forest_view = try forest.View.open(forest_owned.bytes);
        const definition_spans = [_]text_index.Span{ .{ .first = 0, .count = 1 }, .{ .first = 1, .count = 1 } };
        const example_spans = [_]text_index.Span{.{ .first = 2, .count = 1 }};
        mapping = try text_index.build(allocator, &forest_view, prose_items.len, &.{
            .{ .kind = .definition, .spans = &definition_spans },
            .{ .kind = .example, .spans = &example_spans },
        });
        inputs[input_count] = .{ .tag = .columns, .bytes = mapping.?.bytes };
        input_count += 1;
    }
    inputs[input_count] = .{ .tag = .forest, .bytes = forest_owned.bytes };
    input_count += 1;
    inputs[input_count] = .{ .tag = .prose, .bytes = prose_owned.bytes };
    input_count += 1;
    const bytes = try container.build(allocator, @import("schema.zig").digest(), inputs[0..input_count]);
    errdefer allocator.free(bytes);
    return .{ .automaton = automaton_owned, .forest = forest_owned, .prose = prose_owned, .text_index = mapping, .bytes = bytes };
}

fn descriptor(bytes: []const u8, index: usize) !container.Descriptor {
    const DescriptorWire = wire.Layout(container.Descriptor);
    return DescriptorWire.read(bytes, container.header_size + index * container.descriptor_size);
}

test "snapshot exposes typed allocation-free queries and separate prose domain" {
    var fixture = try makeFixture(std.testing.allocator, 2, &.{
        .{ .text = "a small feline" },
        .{ .text = "a domesticated animal" },
        .{ .text = "an extra sense" },
    });
    defer fixture.deinit();

    var view = try snapshot.Snapshot.open(fixture.bytes, &fixture.trust, .{});
    try std.testing.expectEqual(@as(u64, 0), fixture.trust[0]);
    var query = try view.query();
    try std.testing.expectEqual(@as(usize, 2), try view.entryCount());
    try std.testing.expectEqual(@as(usize, 2), try view.rootCount());
    try std.testing.expectEqual(@as(usize, 3), try view.proseItemCount());

    const form_hit = (try query.exact("cats")).?;
    try std.testing.expect(!form_hit.isEntry());
    try std.testing.expectEqual(@as(u32, 1), form_hit.targets.len());
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(try form_hit.targets.target(0)));
    const stable_view = @intFromPtr(form_hit.targets.view);
    _ = try query.exact("cat");
    try std.testing.expectEqual(stable_view, @intFromPtr(form_hit.targets.view));

    const roots = try query.prefixInterval("c");
    try std.testing.expectEqual(@as(usize, 1), roots.len());
    const entry_set = try query.nodesForPrefix(.entry, "c");
    try std.testing.expectEqual(@as(usize, 1), entry_set.len());
    const miss = try query.prefixInterval("cow");
    try std.testing.expectEqual(@as(usize, 0), miss.len());
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(miss.lo));

    var key = [_]u8{0} ** 16;
    var frames = [_]automaton.Frame{.{}} ** 16;
    var prefix = try query.prefix("c", key[0..], frames[0..]);
    const first = (try prefix.next()).?;
    try std.testing.expectEqualSlices(u8, "cat", first.bytes);

    var all_prefix = try query.prefix("", key[0..], frames[0..]);
    const accepted_cat = (try all_prefix.next()).?;
    try std.testing.expect(accepted_cat.isEntry());
    try std.testing.expectEqual(@as(u32, 0), accepted_cat.targets.len());
    const accepted_form = (try all_prefix.next()).?;
    try std.testing.expect(accepted_form.isForm());
    try std.testing.expect(accepted_form.entries == null);
    try std.testing.expectEqual(@as(u32, 1), accepted_form.targets.len());
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(try accepted_form.targets.target(0)));

    const entry = (try query.entry(@enumFromInt(1), key[0..])).?;
    try std.testing.expectEqualSlices(u8, "dog", entry.headword());
    const projected = try entry.project(.entry);
    try std.testing.expectEqual(@as(usize, 1), projected.len());

    var output = [_]u8{0} ** 64;
    var dfs: [256]snapshot.RenderFrame = undefined;
    var entry_texts = try entry.texts(.definition);
    const first_text = (try entry_texts.next()).?;
    const written = try first_text.render(output[0..], dfs[0..]);
    try std.testing.expectEqualStrings("a domesticated animal", output[0..written]);
    var direct_text = try query.texts(.definition, @enumFromInt(1));
    try std.testing.expect((try direct_text.next()) != null);
    try std.testing.expect((try direct_text.next()) == null);
    var ranked_text = try query.textsForEntry(@enumFromInt(1), .definition);
    try std.testing.expect((try ranked_text.next()) != null);
    var examples = try entry.texts(.example);
    const example = (try examples.next()).?;
    const example_written = try example.render(output[0..], dfs[0..]);
    try std.testing.expectEqualStrings("an extra sense", output[0..example_written]);

    // Query methods above accept no allocator and render uses only the caller's
    // key/output/DFS storage. The trust bitmap records the two hot pages while
    // The mapping and prose pages are touched only by the typed text iterator.
    try std.testing.expect((fixture.trust[0] & 0b1111) == 0b1111);
}

test "typed plans fuse proven paths and preserve disjoint and nested rich scopes" {
    const allocator = std.testing.allocator;
    var keys = automaton.Builder.init(allocator);
    defer keys.deinit();
    try keys.addEntry("cat", 1);
    try keys.addEntry("dog", 1);
    var key_bytes = try keys.finish();
    defer key_bytes.deinit();
    var tree = forest.Builder.init(allocator);
    defer tree.deinit();
    const cat = try tree.addRoot("cat", .entry);
    const first = try tree.addChild(cat, .sense);
    _ = try tree.addChild(first, .definition);
    const example = try tree.addChild(first, .example);
    _ = try tree.addChild(example, .citation);
    const nested = try tree.addChild(first, .subsense);
    _ = try tree.addChild(nested, .definition);
    const deeper = try tree.addChild(nested, .subsense);
    _ = try tree.addChild(deeper, .definition);
    const excluded_sibling = try tree.addChild(cat, .sense);
    _ = try tree.addChild(excluded_sibling, .definition);
    const dog = try tree.addRoot("dog", .entry);
    const last = try tree.addChild(dog, .sense);
    _ = try tree.addChild(last, .definition);
    var tree_bytes = try tree.build();
    defer tree_bytes.deinit();
    const structure = try forest.View.open(tree_bytes.bytes);
    var prose = try grammar.build(allocator, &.{
        .{ .text = "first-a" },  .{ .text = "first-b" },
        .{ .text = "nested" },   .{ .text = "excluded" },
        .{ .text = "last" },     .{ .text = "example" },
        .{ .text = "citation" },
    }, .{});
    defer prose.deinit();
    var mapping = try text_index.build(allocator, &structure, 7, &.{
        .{ .kind = .definition, .spans = &.{
            .{ .first = 0, .count = 2 }, .{ .first = 2, .count = 0 },
            .{ .first = 2, .count = 1 }, .{ .first = 3, .count = 1 },
            .{ .first = 4, .count = 1 },
        } },
        .{ .kind = .example, .spans = &.{.{ .first = 5, .count = 1 }} },
        .{ .kind = .citation, .spans = &.{.{ .first = 6, .count = 1 }} },
    });
    defer mapping.deinit();
    var memberships = try @import("concepts.zig").build(.concept, allocator, 3, 2, &.{
        .{ .sense = @enumFromInt(0), .concept = @enumFromInt(0) },
        .{ .sense = @enumFromInt(1), .concept = @enumFromInt(1) },
        .{ .sense = @enumFromInt(2), .concept = @enumFromInt(0) },
    });
    defer memberships.deinit();
    const bytes = try container.build(allocator, @import("schema.zig").digest(), &.{
        .{ .tag = .automaton, .bytes = key_bytes.bytes },
        .{ .tag = .columns, .bytes = mapping.bytes },
        .{ .tag = .concepts, .bytes = memberships.bytes },
        .{ .tag = .forest, .bytes = tree_bytes.bytes },
        .{ .tag = .prose, .bytes = prose.bytes },
    });
    defer allocator.free(bytes);
    var book = try snapshot.Snapshot.openUncached(bytes, .{});
    try book.verify(allocator);
    var query = try book.query();
    const entries = try query.entries("");
    const direct = entries.descendants(.definition);
    const composed = entries.descendants(.sense).descendants(.definition);
    // The schema proves that every legal entry-to-definition path contains
    // a sense. The intermediate plan is erased, not just skipped at runtime.
    try std.testing.expect(@TypeOf(direct) == @TypeOf(composed));
    var direct_ranks = direct.iterator();
    var composed_ranks = composed.iterator();
    for (0..5) |index| {
        try std.testing.expectEqual(index, @intFromEnum((try direct_ranks.next()).?));
        try std.testing.expectEqual(index, @intFromEnum((try composed_ranks.next()).?));
    }
    try std.testing.expect((try direct_ranks.next()) == null);
    try std.testing.expect((try composed_ranks.next()) == null);

    const selected_senses = [_]snapshot.Rank(.sense){ @enumFromInt(0), @enumFromInt(2) };
    const selected = try query.select(.sense, .{ .list = &selected_senses });
    var selected_ranks = selected.descendants(.definition).iterator();
    for ([_]usize{ 0, 1, 2, 4 }) |index|
        try std.testing.expectEqual(index, @intFromEnum((try selected_ranks.next()).?));
    try std.testing.expect((try selected_ranks.next()) == null);
    var output: [32]u8 = undefined;
    var stack: [64]snapshot.RenderFrame = undefined;
    var selected_text = selected.descendants(.definition).texts();
    const members = try query.members(@enumFromInt(0));
    var member_text = members.descendants(.definition).texts();
    for ([_][]const u8{ "first-a", "first-b", "nested", "last" }) |expected_text| {
        const item = (try selected_text.next()).?;
        const length = try item.render(&output, &stack);
        try std.testing.expectEqualStrings(expected_text, output[0..length]);
        const attached = (try member_text.next()).?;
        const attached_length = try attached.render(&output, &stack);
        try std.testing.expectEqualStrings(expected_text, output[0..attached_length]);
    }
    try std.testing.expect((try selected_text.next()) == null);
    try std.testing.expect((try member_text.next()) == null);

    const subsenses = try query.select(.subsense, .{ .interval = try snapshot.Interval(.subsense).init(@enumFromInt(0), @enumFromInt(2)) });
    var nested_ranks = subsenses.descendants(.definition).iterator();
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum((try nested_ranks.next()).?));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum((try nested_ranks.next()).?));
    try std.testing.expect((try nested_ranks.next()) == null);
    // Subsense does not dominate definition below sense. Keeping this stage
    // prevents the outer sense's own definition from entering the result.
    const nested_only = entries.descendants(.sense).descendants(.subsense).descendants(.definition);
    try std.testing.expect(@TypeOf(nested_only) != @TypeOf(direct));
    var nested_only_ranks = nested_only.iterator();
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum((try nested_only_ranks.next()).?));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum((try nested_only_ranks.next()).?));
    try std.testing.expect((try nested_only_ranks.next()) == null);
    const empty = try query.entries("missing");
    var empty_text = empty.descendants(.definition).texts();
    try std.testing.expect((try empty_text.next()) == null);
    try std.testing.expectError(error.InvalidRank, query.select(.sense, .{ .list = &.{@enumFromInt(3)} }));
}

test "snapshot authenticates lazily and rejects a damaged page" {
    var fixture = try makeFixture(std.testing.allocator, 2, &.{.{ .text = "one" }});
    defer fixture.deinit();
    var view = try snapshot.Snapshot.open(fixture.bytes, &fixture.trust, .{});
    try std.testing.expectEqual(@as(usize, 2), try view.entryCount());
    try std.testing.expect((fixture.trust[0] & 1) != 0);
    try std.testing.expect((fixture.trust[0] & 2) == 0);
    try std.testing.expect((fixture.trust[0] & 4) == 0);
    try std.testing.expectEqual(@as(usize, 2), try view.rootCount());

    var damaged = try std.testing.allocator.dupe(u8, fixture.bytes);
    defer std.testing.allocator.free(damaged);
    const forest_descriptor = try descriptor(damaged, 1);
    damaged[@intCast(forest_descriptor.offset)] ^= 1;
    var damaged_view = try snapshot.Snapshot.open(damaged, &.{}, .{});
    try std.testing.expectError(error.IntegrityFailure, damaged_view.rootCount());
}

test "snapshot rejects envelope bounds, schema mismatch, and cross-section mismatch" {
    var fixture = try makeFixture(std.testing.allocator, 1, &.{.{ .text = "one" }});
    defer fixture.deinit();
    var mismatched = try snapshot.Snapshot.open(fixture.bytes, &.{}, .{});
    try std.testing.expectError(error.CrossSectionMismatch, mismatched.query());
    try std.testing.expectError(error.LengthMismatch, snapshot.Snapshot.open(fixture.bytes[0 .. fixture.bytes.len - 1], &.{}, .{}));
    try std.testing.expectError(error.SchemaMismatch, snapshot.Snapshot.open(fixture.bytes, &.{}, .{ .expected_schema = [_]u8{0} ** container.digest_size }));
}

test "structural plans prove topology and present text maps cannot evade verification" {
    const allocator = std.testing.allocator;
    var fixture = try makeFixture(allocator, 2, &.{ .{ .text = "one" }, .{ .text = "two" }, .{ .text = "three" } });
    defer fixture.deinit();
    const digest = @import("schema.zig").digest();
    const bad_columns = try container.build(allocator, digest, &.{
        .{ .tag = .automaton, .bytes = fixture.automaton.bytes },
        .{ .tag = .columns, .bytes = "BAD!" },
        .{ .tag = .forest, .bytes = fixture.forest.bytes },
        .{ .tag = .prose, .bytes = fixture.prose.bytes },
    });
    defer allocator.free(bad_columns);
    var invalid_columns = try snapshot.Snapshot.openUncached(bad_columns, .{});
    try std.testing.expectError(error.MissingTextMap, invalid_columns.verify(allocator));
    try std.testing.expect(!invalid_columns.isVerified());

    const no_columns = try container.build(allocator, digest, &.{
        .{ .tag = .automaton, .bytes = fixture.automaton.bytes },
        .{ .tag = .forest, .bytes = fixture.forest.bytes },
        .{ .tag = .prose, .bytes = fixture.prose.bytes },
    });
    defer allocator.free(no_columns);
    var absent = try snapshot.Snapshot.openUncached(no_columns, .{});
    var query = try absent.query();
    var texts = try query.texts(.definition, @enumFromInt(0));
    try std.testing.expectError(error.MissingTextMap, texts.next());

    const damaged = try allocator.dupe(u8, fixture.forest.bytes);
    defer allocator.free(damaged);
    const forest_view = try forest.View.open(damaged);
    // Small descriptors occupy kind/subtree/parent bytes. Turn the first
    // sense into a definition: entry->definition bypasses the dominating
    // sense required by the schema. Re-sign the container to test semantics,
    // not an outer digest failure.
    const data_at = @intFromPtr(forest_view.skeleton_data.ptr) - @intFromPtr(damaged.ptr);
    damaged[data_at + 3] = @intFromEnum(snapshot.Kind.definition);
    const illegal = try container.build(allocator, digest, &.{
        .{ .tag = .automaton, .bytes = fixture.automaton.bytes },
        .{ .tag = .forest, .bytes = damaged },
        .{ .tag = .prose, .bytes = fixture.prose.bytes },
    });
    defer allocator.free(illegal);
    var hostile = try snapshot.Snapshot.openUncached(illegal, .{});
    var lazy_query = try hostile.query();
    _ = try lazy_query.exact("cat"); // Key lookup does not need a topology walk.
    if (lazy_query.entries("cat")) |_| return error.TestExpectedError else |_| {}
    try std.testing.expect(!hostile.forest_verified);
}

test "snapshot semantic verification reports allocator failure" {
    var fixture = try makeFixture(std.testing.allocator, 2, &.{.{ .text = "one" }});
    defer fixture.deinit();
    var view = try snapshot.Snapshot.open(fixture.bytes, &.{}, .{});
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, view.verify(failing.allocator()));
    try std.testing.expect(!view.isVerified());
}

test "snapshot caches publish only after limits and parsing succeed" {
    var fixture = try makeFixture(std.testing.allocator, 2, &.{.{ .text = "one" }});
    defer fixture.deinit();
    var view = try snapshot.Snapshot.open(fixture.bytes, &.{}, .{ .limits = .{ .max_entries = 1 } });
    try std.testing.expectError(error.LimitExceeded, view.entryCount());
    try std.testing.expect(view.automaton_view == null);
    view.limits.max_entries = 2;
    try std.testing.expectEqual(@as(usize, 2), try view.entryCount());
    try std.testing.expect(view.automaton_view != null);

    view.limits.max_entries = 1;
    try std.testing.expectError(error.LimitExceeded, view.rootCount());
    try std.testing.expect(view.forest_view == null);
    view.limits.max_entries = 2;
    try std.testing.expectEqual(@as(usize, 2), try view.rootCount());
    try std.testing.expect(view.forest_view != null);

    try std.testing.expectError(error.Overflow, snapshot.ProseRank.fromIndex(std.math.maxInt(u32)));
}

test "snapshot verifies encoded cold payload without decoding it" {
    var automaton_builder = automaton.Builder.init(std.testing.allocator);
    defer automaton_builder.deinit();
    try automaton_builder.addEntry("cat", 1);
    var automaton_owned = try automaton_builder.finish();
    defer automaton_owned.deinit();
    var forest_builder = forest.Builder.init(std.testing.allocator);
    defer forest_builder.deinit();
    _ = try forest_builder.addRoot("cat", .entry);
    var forest_owned = try forest_builder.build();
    defer forest_owned.deinit();
    var prose_owned = try grammar.build(std.testing.allocator, &.{.{ .text = "definition" }}, .{});
    defer prose_owned.deinit();
    var cold_builder = cold.Builder.init(std.testing.allocator, .{ .codec_kind = .raw });
    var cold_owned = try cold_builder.finish("cold payload");
    defer cold_owned.deinit();
    const bytes = try container.build(std.testing.allocator, @import("schema.zig").digest(), &.{
        .{ .tag = .automaton, .bytes = automaton_owned.bytes },
        .{ .tag = .cold, .bytes = cold_owned.bytes },
        .{ .tag = .forest, .bytes = forest_owned.bytes },
        .{ .tag = .prose, .bytes = prose_owned.bytes },
    });
    defer std.testing.allocator.free(bytes);
    var view = try snapshot.Snapshot.open(bytes, &.{}, .{});
    try view.verify(std.testing.allocator);
    try std.testing.expect(view.isVerified());
    try std.testing.expect(view.cold_view != null);
}

test "snapshot applies prose-rank limits before walking a zero-byte identity map" {
    var fixture = try makeFixture(std.testing.allocator, 2, &.{
        .{ .text = "first" },
        .{ .text = "second" },
        .{ .text = "third" },
    });
    defer fixture.deinit();
    var view = try snapshot.Snapshot.open(fixture.bytes, &.{}, .{ .limits = .{ .max_prose_items = 0 } });
    try std.testing.expectError(error.LimitExceeded, view.verify(std.testing.allocator));
}
