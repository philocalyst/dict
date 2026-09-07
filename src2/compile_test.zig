const std = @import("std");
const c = @import("compile.zig");
const s = @import("schema.zig");
const snap = @import("snapshot.zig");

test "builder output opens through every hot snapshot surface" {
    var builder = c.Builder.init(std.testing.allocator);
    defer builder.deinit();
    const entry = try builder.root(.entry, .{});
    try builder.set(entry, s.columns.headword, "bank");
    try builder.set(entry, s.columns.lang, "en");
    const form = try builder.child(entry, .form, .{});
    try builder.set(form, s.columns.written, "bank");
    const sense = try builder.child(entry, .sense, .{});
    const definition = try builder.child(sense, .definition, .{});
    try builder.set(definition, s.columns.text, "a financial institution");
    const entry2 = try builder.root(.entry, .{});
    try builder.set(entry2, s.columns.headword, "band");
    const form2 = try builder.child(entry2, .form, .{});
    try builder.set(form2, s.columns.written, "band");
    const sense2 = try builder.child(entry2, .sense, .{});
    const assertion = try builder.assertion(s.predicates.translation, sense, .{
        .{ .role = .source, .target = c.Target{ .node = sense.any() } },
        .{ .role = .target, .target = c.Target{ .node = sense2.any() } },
    }, .{ .evidence = &.{.{ .quote = "attested" }} });
    try builder.link(s.predicates.see_also, entry, entry2);

    var one = try builder.compile();
    defer one.deinit();
    var two = try builder.compile();
    defer two.deinit();
    try std.testing.expectEqualSlices(u8, one.bytes, two.bytes);
    var snapshot = try snap.Snapshot.open(one.bytes, .{});
    const forest = try snapshot.forest();
    try std.testing.expectEqual(s.Kind.entry, try forest.kind(@enumFromInt(0)));
    const assertion_node = try one.resolve(assertion);
    try std.testing.expectEqual(s.Kind.assertion, try forest.kind(assertion_node));
    const inherited = try snapshot.get(s.columns.lang, try one.resolve(sense));
    const atoms = try snapshot.keySpace(.atoms);
    var atom_scratch: [64]u8 = undefined;
    const en = (try atoms.exact("en", &atom_scratch)).?;
    try std.testing.expectEqual(en.ordinal, @intFromEnum(inherited.?));

    const headwords = try snapshot.keySpace(.headword);
    var key_scratch: [128]u8 = undefined;
    const exact = (try headwords.exact("bank", &key_scratch)).?;
    var postings = try headwords.postingIterator(exact);
    try std.testing.expectEqual(@as(u64, @intFromEnum(try one.resolve(entry))), (try postings.next()).?);
    try std.testing.expectEqual(@as(u64, @intFromEnum(try one.resolve(form))), (try postings.next()).?);
    try std.testing.expect((try postings.next()) == null);
    var prefix = try headwords.prefix("ba", &key_scratch);
    var prefix_count: usize = 0;
    while (try prefix.next()) |_| prefix_count += 1;
    try std.testing.expectEqual(@as(usize, 2), prefix_count);

    const forward = try snapshot.adjacency(.see_also);
    var targets: [2]s.Node = undefined;
    try std.testing.expectEqual(@as(usize, 1), try forward.targets(try one.resolve(entry), &targets));
    try std.testing.expectEqual(try one.resolve(entry2), targets[0]);
    const qualified = try snapshot.adjacency(.translation);
    try std.testing.expectEqual(@as(usize, 1), try qualified.targets(try one.resolve(sense), &targets));
    try std.testing.expectEqual(try one.resolve(sense2), targets[0]);

    var prose = try snapshot.prose(.{});
    const block = (prose.blockForRoot(@intFromEnum(try one.resolve(entry)))).?;
    var pin = try prose.pin(std.testing.allocator, block);
    defer pin.deinit();
    try std.testing.expectEqualStrings("a financial institution", (try pin.itemForNode(@intFromEnum(try one.resolve(definition)))).?.text);
}

test "typed direction, profiles, evidence and cold metadata use public descriptors" {
    var builder = c.Builder.init(std.testing.allocator);
    defer builder.deinit();
    const entry = try builder.root(.entry, .{});
    try builder.set(entry, s.columns.headword, "word");
    try builder.set(entry, s.columns.direction, .rtl);
    try builder.set(entry, s.columns.profile, @enumFromInt(7));
    const sense = try builder.child(entry, .sense, .{});
    const extension = try builder.child(entry, .extension, .{});
    try builder.set(extension, s.columns.qname, "tei:foreign");
    try builder.attribute(extension, "xml:id", "x1");
    try builder.externalId(extension, 3, "x1");
    _ = try builder.assertion(s.predicates.translation, sense, .{
        .{ .role = .source, .target = c.Target{ .node = sense.any() } },
        .{ .role = .target, .target = c.Target{ .unresolved = .{ .bytes = "urn:missing", .uri = "urn:missing", .label = "missing" } } },
    }, .{ .evidence = &.{.{ .quote = "source quote", .anchor = "p3" }} });
    var owned = try builder.compile();
    defer owned.deinit();
    var snapshot = try snap.Snapshot.open(owned.bytes, .{});
    try std.testing.expectEqual(s.Direction.rtl, (try snapshot.get(s.columns.direction, try owned.resolve(entry))).?);
    try std.testing.expectEqual(@as(s.Profile, @enumFromInt(7)), (try snapshot.get(s.columns.profile, try owned.resolve(entry))).?);
    const cold = try snapshot.coldMetadata(.{});
    const metadata = (try cold.get(@intFromEnum(try owned.resolve(extension)))).?;
    var attributes = metadata.attributes();
    const attribute = (try attributes.next()).?;
    try std.testing.expectEqualStrings("xml:id", attribute.name);
    try std.testing.expectEqualStrings("x1", attribute.value);
    const shapes = try snapshot.keySpace(.shapes);
    var scratch: [128]u8 = undefined;
    try std.testing.expect((try shapes.exact("6:xml:id", &scratch)) != null);
    const external = try snapshot.keySpace(.external_ids);
    try std.testing.expect((try external.exact("00000003:x1", &scratch)) != null);
}

test "shape keys length-prefix embedded NUL names without collisions" {
    var builder = c.Builder.initWithOptions(std.testing.allocator, .{ .prose = .{ .codec = .raw } });
    defer builder.deinit();
    const entry = try builder.root(.entry, .{ .headword = "shape" });
    const nul_name = try builder.child(entry, .extension, .{ .qname = "nul" });
    try builder.attribute(nul_name, "a\x00b", "one");
    const comma_name = try builder.child(entry, .extension, .{ .qname = "comma" });
    try builder.attribute(comma_name, "a,b", "two");

    var owned = try builder.compile();
    defer owned.deinit();
    const view = try snap.Snapshot.open(owned.bytes, .{});
    const shapes = try view.keySpace(.shapes);
    var scratch: [128]u8 = undefined;
    const nul_shape = (try shapes.exact("3:a\x00b", &scratch)).?;
    var nul_postings = try shapes.postingIterator(nul_shape);
    try std.testing.expectEqual(@as(u64, @intFromEnum(try owned.resolve(nul_name))), (try nul_postings.next()).?);
    try std.testing.expect((try nul_postings.next()) == null);
    const comma_shape = (try shapes.exact("3:a,b", &scratch)).?;
    var comma_postings = try shapes.postingIterator(comma_shape);
    try std.testing.expectEqual(@as(u64, @intFromEnum(try owned.resolve(comma_name))), (try comma_postings.next()).?);
    try std.testing.expect((try comma_postings.next()) == null);
}
