const std = @import("std");
const compile = @import("compile.zig");
const query = @import("query.zig");
const schema = @import("schema.zig");
const snapshot = @import("snapshot.zig");

const Fixture = struct {
    compiled: compile.Compiled,
    view: snapshot.Snapshot,
    entry_cat: schema.Node,
    form_cat: schema.Node,
    sense_cat: schema.Node,
    definition_cat: schema.Node,
    entry_dog: schema.Node,
    sense_dog: schema.Node,
    definition_dog: schema.Node,
    assertion: schema.Node,

    fn deinit(self: *Fixture) void {
        self.compiled.deinit();
        self.* = undefined;
    }
};

fn fixture(allocator: std.mem.Allocator) !Fixture {
    var builder = compile.Builder.initWithOptions(allocator, .{
        // One item per block makes pin budgets observable without relying on
        // compression ratios or machine-specific codec behavior.
        .prose = .{ .codec = .raw, .max_items_per_block = 1 },
    });
    defer builder.deinit();

    const entry_cat = try builder.root(.entry, .{});
    try builder.set(entry_cat, schema.columns.headword, "cat");
    try builder.set(entry_cat, schema.columns.lang, "en");
    const form_cat = try builder.child(entry_cat, .form, .{});
    try builder.set(form_cat, schema.columns.written, "cat");
    const sense_cat = try builder.child(entry_cat, .sense, .{});
    const definition_cat = try builder.child(sense_cat, .definition, .{});
    try builder.set(definition_cat, schema.columns.text, "first river animal");

    const entry_dog = try builder.root(.entry, .{});
    try builder.set(entry_dog, schema.columns.headword, "dog");
    try builder.set(entry_dog, schema.columns.lang, "fr");
    const form_dog = try builder.child(entry_dog, .form, .{});
    try builder.set(form_dog, schema.columns.written, "dog");
    const sense_dog = try builder.child(entry_dog, .sense, .{});
    const definition_dog = try builder.child(sense_dog, .definition, .{});
    try builder.set(definition_dog, schema.columns.text, "second river canine");

    const assertion = try builder.assertion(schema.predicates.translation, sense_cat, .{
        .{ .role = .source, .target = compile.Target{ .node = sense_cat.any() } },
        .{ .role = .target, .target = compile.Target{ .node = sense_dog.any() } },
    }, .{ .evidence = &.{.{ .quote = "attested translation" }} });

    var compiled = try builder.compile();
    errdefer compiled.deinit();
    return .{
        .view = try snapshot.Snapshot.open(compiled.bytes, .{}),
        .entry_cat = try compiled.resolve(entry_cat),
        .form_cat = try compiled.resolve(form_cat),
        .sense_cat = try compiled.resolve(sense_cat),
        .definition_cat = try compiled.resolve(definition_cat),
        .entry_dog = try compiled.resolve(entry_dog),
        .sense_dog = try compiled.resolve(sense_dog),
        .definition_dog = try compiled.resolve(definition_dog),
        .assertion = try compiled.resolve(assertion),
        .compiled = compiled,
    };
}

test "indexed navigation, both graph directions, assertions and budgets" {
    var data = try fixture(std.testing.allocator);
    defer data.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lookup = query.Query.init(&data.view, &arena, .{});
    defer lookup.deinit();
    const senses = try lookup.key(.headword, "cat", .exact).descendants().kind(.sense).lang("en").run();
    try std.testing.expectEqualSlices(schema.Node, &.{data.sense_cat}, senses.items);

    var forward = query.Query.init(&data.view, &arena, .{});
    defer forward.deinit();
    try std.testing.expectEqualSlices(schema.Node, &.{data.sense_dog}, (try forward.ids(&.{data.sense_cat}).follow(.translation).run()).items);
    var reverse = query.Query.init(&data.view, &arena, .{ .allow_scan = false });
    defer reverse.deinit();
    try std.testing.expectEqualSlices(schema.Node, &.{data.sense_cat}, (try reverse.ids(&.{data.sense_dog}).back(.translation).run()).items);
    try std.testing.expect(!reverse.explain().scan);

    var qualified = query.Query.init(&data.view, &arena, .{});
    defer qualified.deinit();
    const assertions = try qualified.ids(&.{data.sense_cat}).assertionsOf(.translation).run();
    try std.testing.expectEqualSlices(schema.Node, &.{data.assertion}, assertions.items);
    var participants = query.Query.init(&data.view, &arena, .{});
    defer participants.deinit();
    const sources = try participants.ids(assertions.items).participants("source").run();
    try std.testing.expectEqual(@as(usize, 1), sources.len());

    var limited = query.Query.init(&data.view, &arena, .{ .max_visited = 1 });
    defer limited.deinit();
    try std.testing.expectError(error.BudgetExceeded, limited.all(.entry).run());
    var denied = query.Query.init(&data.view, &arena, .{ .allow_scan = false });
    defer denied.deinit();
    try std.testing.expectError(error.ScanDisallowed, denied.fuzzy(.headword, "cot", 1).run());
}

test "derived suffix and full-text term indexes never touch prose" {
    var data = try fixture(std.testing.allocator);
    defer data.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var suffix = query.Query.init(&data.view, &arena, .{ .allow_scan = false });
    defer suffix.deinit();
    const cat = try suffix.suffix("AT").distinct(.root).run();
    try std.testing.expectEqualSlices(schema.Node, &.{data.entry_cat}, cat.items);
    try std.testing.expectEqual(@as(usize, 0), suffix.explain().blocks);

    var all_terms = query.Query.init(&data.view, &arena, .{ .allow_scan = false });
    defer all_terms.deinit();
    const dog_definition = try all_terms.terms(&.{ "RIVER", "canine" }, .all).run();
    try std.testing.expectEqualSlices(schema.Node, &.{data.definition_dog}, dog_definition.items);
    try std.testing.expectEqual(@as(usize, 0), all_terms.explain().blocks);

    var any_terms = query.Query.init(&data.view, &arena, .{});
    defer any_terms.deinit();
    const both_definitions = try any_terms.terms(&.{ "animal", "canine" }, .any).run();
    try std.testing.expectEqualSlices(schema.Node, &.{ data.definition_cat, data.definition_dog }, both_definitions.items);
}

test "ids reject invalid nodes and absent prose fields do not consume blocks" {
    var data = try fixture(std.testing.allocator);
    defer data.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var invalid = query.Query.init(&data.view, &arena, .{});
    defer invalid.deinit();
    const out_of_range: schema.Node = @enumFromInt(std.math.maxInt(u32));
    try std.testing.expectError(error.InvalidReference, invalid.ids(&.{out_of_range}).run());

    // The selected form has neither text nor quote prose. Even with a zero
    // block budget, asking for those absent fields must produce null values
    // without opening or decoding any prose block.
    var absent = query.Query.init(&data.view, &arena, .{ .max_blocks = 0 });
    defer absent.deinit();
    const set = try absent.ids(&.{data.form_cat}).run();
    var rows = try absent.materialize(set, &.{ .text, .quote });
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 0), absent.explain().blocks);
    const row = (rows.next()).?;
    try std.testing.expect(row.get(.text) == null);
    try std.testing.expect(row.get(.quote) == null);
}

test "column algebra and generic materialization preserve pin lifetimes" {
    var data = try fixture(std.testing.allocator);
    defer data.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var not_english = query.Query.init(&data.view, &arena, .{});
    defer not_english.deinit();
    const filtered = try not_english.ids(&.{ data.sense_cat, data.sense_dog }).column(.lang, .ne, .{ .atom = "en" }).run();
    try std.testing.expectEqualSlices(schema.Node, &.{data.sense_dog}, filtered.items);
    var present = query.Query.init(&data.view, &arena, .{});
    defer present.deinit();
    try std.testing.expectEqualSlices(schema.Node, &.{data.form_cat}, (try present.ids(&.{ data.form_cat, data.sense_cat }).columnPresent(.written).run()).items);

    var render = query.Query.init(&data.view, &arena, .{ .max_blocks = 2 });
    defer render.deinit();
    const nodes = try render.ids(&.{ data.definition_cat, data.form_cat, data.definition_dog }).run();
    var rows = try render.materialize(nodes, &.{ .written, .lang, .text });
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 2), render.explain().blocks);
    while (rows.next()) |row| {
        if (row.node == data.form_cat) {
            try std.testing.expectEqualStrings("cat", row.get(.written).?);
            try std.testing.expectEqualStrings("en", row.get(.lang).?);
        } else if (row.node == data.definition_cat) {
            try std.testing.expectEqualStrings("en", row.get(.lang).?);
            try std.testing.expectEqualStrings("first river animal", row.get(.text).?);
        } else if (row.node == data.definition_dog) {
            try std.testing.expectEqualStrings("fr", row.get(.lang).?);
            try std.testing.expectEqualStrings("second river canine", row.get(.text).?);
        } else return error.TestUnexpectedResult;
    }

    var too_many_blocks = query.Query.init(&data.view, &arena, .{ .max_blocks = 1 });
    defer too_many_blocks.deinit();
    const prose_nodes = try too_many_blocks.ids(&.{ data.definition_cat, data.definition_dog }).run();
    try std.testing.expectError(error.BudgetExceeded, too_many_blocks.materialize(prose_nodes, &.{.text}));
}

test "compressed prose pins outlive query decoder teardown" {
    var builder = compile.Builder.initWithOptions(std.testing.allocator, .{ .prose = .{ .codec = .bzip3 } });
    defer builder.deinit();
    const entry = try builder.root(.entry, .{ .headword = "compressed" });
    const sense = try builder.child(entry, .sense, .{});
    const definition = try builder.child(sense, .definition, .{ .text = "codec-owned materialized text" });
    var compiled = try builder.compile();
    defer compiled.deinit();
    var view = try snapshot.Snapshot.open(compiled.bytes, .{});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var q = query.Query.init(&view, &arena, .{});
    var query_live = true;
    defer if (query_live) q.deinit();
    const node = try compiled.resolve(definition);
    const set = try q.ids(&.{node}).run();
    var rows = try q.materialize(set, &.{.text});
    // The decoder owns C codec state, while a compressed Pin owns its decoded
    // bytes. Releasing the former must not invalidate the latter.
    q.deinit();
    query_live = false;
    defer rows.deinit();
    try std.testing.expectEqualStrings("codec-owned materialized text", (rows.next() orelse return error.TestUnexpectedResult).get(.text).?);
}

test "sets remain sorted and pagination is keyset based" {
    var data = try fixture(std.testing.allocator);
    defer data.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((query.NodeSet{ .items = &.{} }).isSorted());

    var left = query.Query.init(&data.view, &arena, .{});
    defer left.deinit();
    _ = left.ids(&.{ data.entry_cat, data.entry_dog });
    var right = query.Query.init(&data.view, &arena, .{});
    defer right.deinit();
    _ = right.ids(&.{data.entry_dog});
    var outer = query.Query.init(&data.view, &arena, .{});
    defer outer.deinit();
    const page = try outer.ids(&.{data.entry_cat}).either(&left).except(&right).after(data.entry_cat).take(4).run();
    try std.testing.expect(page.isSorted());
    try std.testing.expectEqual(@as(usize, 0), page.len());
}
