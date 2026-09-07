const std = @import("std");
const compile = @import("compile.zig");
const keys = @import("keys.zig");
const prose = @import("prose.zig");
const query = @import("query.zig");
const schema = @import("schema.zig");
const snapshot = @import("snapshot.zig");

fn readVar(bytes: []const u8, cursor: *usize) !u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (cursor.* >= bytes.len or shift > 63) return error.InvalidEncoding;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        value |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return value;
        shift += 7;
    }
}

test "key readers reject oversized suffixes and posting bit-count bounds" {
    var builder = keys.Builder.atoms(std.testing.allocator);
    defer builder.deinit();

    const long = try std.testing.allocator.alloc(u8, keys.max_key_bytes);
    defer std.testing.allocator.free(long);
    long[0] = 'a';
    @memset(long[1..], 'b');
    try builder.addBytes("a");
    try builder.addBytes(long);
    var encoded = try builder.encode();
    defer encoded.deinit();

    // The second record has shared=1 and suffix=max_key_bytes-1. Keep the
    // varint width unchanged while making its decoded key one byte too long.
    var cursor: usize = keys.header_bytes;
    _ = try readVar(encoded.bytes, &cursor);
    const first_suffix = try readVar(encoded.bytes, &cursor);
    cursor += @intCast(first_suffix);
    _ = try readVar(encoded.bytes, &cursor);
    const suffix_at = cursor;
    const suffix = try readVar(encoded.bytes, &cursor);
    try std.testing.expectEqual(@as(u64, keys.max_key_bytes - 1), suffix);
    const malformed = try std.testing.allocator.dupe(u8, encoded.bytes);
    defer std.testing.allocator.free(malformed);
    malformed[suffix_at] = 0xff;
    try std.testing.expectError(error.InvalidFormat, keys.View.open(malformed));

    var postings = keys.Builder.keys(std.testing.allocator);
    defer postings.deinit();
    try postings.addWithPostings("x", &[_]u64{ 0, std.math.maxInt(u64) });
    var posting_owned = try postings.encode();
    defer posting_owned.deinit();
    const bad_postings = try std.testing.allocator.dupe(u8, posting_owned.bytes);
    defer std.testing.allocator.free(bad_postings);
    // The packed reader must validate its bit-count arithmetic before it can
    // derive a slice. A huge logical posting count cannot fit this payload.
    std.mem.writeInt(u32, bad_postings[36..40], std.math.maxInt(u32), .little);
    try std.testing.expectError(error.InvalidFormat, keys.View.open(bad_postings));
}

test "key restart offsets and hit ranges cannot escape the encoded view" {
    var builder = keys.Builder.atoms(std.testing.allocator);
    defer builder.deinit();
    try builder.addBytes("alpha");
    var owned = try builder.encode();
    defer owned.deinit();

    const malformed = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(malformed);
    const table = std.mem.readInt(u32, malformed[24..28], .little);
    std.mem.writeInt(u32, malformed[table..][0..4], std.math.maxInt(u32), .little);
    try std.testing.expectError(error.InvalidFormat, keys.View.open(malformed));

    var posting_builder = keys.Builder.keys(std.testing.allocator);
    defer posting_builder.deinit();
    try posting_builder.addWithPostings("alpha", &[_]u64{0});
    var posting_owned = try posting_builder.encode();
    defer posting_owned.deinit();
    const view = try keys.View.open(posting_owned.bytes);
    try std.testing.expectError(error.InvalidFormat, view.postingIterator(.{
        .ordinal = 0,
        .key = "alpha",
        .posting_count = 1,
        .posting_offset = std.math.maxInt(u32),
    }));
}

test "truncated key, prose, and snapshot envelopes fail closed at every cut" {
    var key_builder = keys.Builder.keys(std.testing.allocator);
    defer key_builder.deinit();
    try key_builder.addWithPostings("alpha", &[_]u64{ 0, 2 });
    try key_builder.addWithPostings("beta", &[_]u64{1});
    var key_owned = try key_builder.encode();
    defer key_owned.deinit();
    for (0..key_owned.bytes.len) |cut| {
        if (keys.View.open(key_owned.bytes[0..cut])) |_| {
            return error.TestUnexpectedSuccess;
        } else |_| {}
    }
    _ = try keys.View.open(key_owned.bytes);

    const items = [_]prose.ItemInput{.{ .node = 1, .text = "truncation" }};
    const roots = [_]prose.RootInput{.{ .root = 0, .items = &items }};
    var prose_owned = try prose.build(std.testing.allocator, &roots, .{ .codec = .raw });
    defer prose_owned.deinit();
    for (0..prose_owned.bytes.len) |cut| {
        if (prose.Store.open(prose_owned.bytes[0..cut], .{ .codec = .raw })) |_| {
            return error.TestUnexpectedSuccess;
        } else |_| {}
    }
    _ = try prose.Store.open(prose_owned.bytes, .{ .codec = .raw });

    var envelope = try snapshot.write(std.testing.allocator, .{}, &.{
        .{ .kind = .schema, .bytes = "schema" },
        .{ .kind = .forest, .bytes = "forest" },
    });
    defer envelope.deinit();
    for (0..envelope.bytes.len) |cut| {
        if (snapshot.Snapshot.openContainer(envelope.bytes[0..cut], .{})) |_| {
            return error.TestUnexpectedSuccess;
        } else |_| {}
    }
    _ = try snapshot.Snapshot.openContainer(envelope.bytes, .{});
}

test "prose routes populated, empty, and populated roots without numeric gaps" {
    const first_items = [_]prose.ItemInput{.{ .node = 11, .text = "first" }};
    const empty_items = [_]prose.ItemInput{};
    const last_items = [_]prose.ItemInput{.{ .node = 31, .text = "last" }};
    const roots = [_]prose.RootInput{
        .{ .root = 10, .items = &first_items },
        .{ .root = 20, .items = &empty_items },
        .{ .root = 30, .items = &last_items },
    };
    var owned = try prose.build(std.testing.allocator, &roots, .{
        .codec = .raw,
        .max_items_per_block = 1,
        .max_uncompressed_block = 128,
    });
    defer owned.deinit();
    var store = try prose.Store.open(owned.bytes, .{ .codec = .raw, .max_items_per_block = 1, .max_uncompressed_block = 128 });
    try std.testing.expectEqual(@as(usize, 2), store.block_count);
    try std.testing.expectEqual(@as(?usize, 0), store.blockForRoot(10));
    try std.testing.expectEqual(@as(?usize, null), store.blockForRoot(20));
    try std.testing.expectEqual(@as(?usize, 1), store.blockForRoot(30));
    try std.testing.expectEqual(@as(?usize, 0), store.blockForNode(11));
    try std.testing.expectEqual(@as(?usize, 1), store.blockForNode(31));

    var first_pin = try store.pin(std.testing.allocator, 0);
    defer first_pin.deinit();
    try std.testing.expectEqualStrings("first", (try first_pin.itemForNode(11)).?.text);
    var last_pin = try store.pin(std.testing.allocator, 1);
    defer last_pin.deinit();
    try std.testing.expectEqualStrings("last", (try last_pin.itemForNode(31)).?.text);
}

test "prose metadata, raw compressed limits, and payload limits fail closed" {
    const items = [_]prose.ItemInput{.{ .node = 1, .text = "bounded" }};
    const roots = [_]prose.RootInput{.{ .root = 0, .items = &items }};
    var owned = try prose.build(std.testing.allocator, &roots, .{ .codec = .raw });
    defer owned.deinit();

    try std.testing.expectError(prose.Error.LimitExceeded, prose.Store.open(owned.bytes, .{ .codec = .raw, .max_compressed_block = prose.payload_header_size }));

    const mismatch = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(mismatch);
    // The directory says two items, but the raw payload still contains one.
    // v3 Record.item_count is the u32 at byte 32; byte 48 is outside the
    // 48-byte record and would corrupt the root table instead.
    std.mem.writeInt(u32, mismatch[prose.header_size + 32 ..][0..4], 2, .little);
    var mismatched_store = try prose.Store.open(mismatch, .{ .codec = .raw });
    try std.testing.expectError(prose.Error.Malformed, mismatched_store.pin(std.testing.allocator, 0));

    const too_small = prose.Options{ .codec = .raw, .max_compressed_block = prose.payload_header_size };
    if (prose.build(std.testing.allocator, &roots, too_small)) |unexpected| {
        var cleanup = unexpected;
        cleanup.deinit();
        return error.TestUnexpectedSuccess;
    } else |err| try std.testing.expectEqual(prose.Error.LimitExceeded, err);
}

test "snapshot writer and reader enforce section limits and duplicate kinds" {
    try std.testing.expectError(error.InvalidFormat, snapshot.write(std.testing.allocator, .{}, &.{}));
    var too_many: [snapshot.max_sections + 1]snapshot.SectionInput = undefined;
    for (&too_many) |*section| section.* = .{ .kind = .schema, .bytes = "x" };
    try std.testing.expectError(error.InvalidFormat, snapshot.write(std.testing.allocator, .{}, &too_many));
    try std.testing.expectError(error.DuplicateSection, snapshot.write(std.testing.allocator, .{}, &.{
        .{ .kind = .schema, .bytes = "a" },
        .{ .kind = .schema, .bytes = "b" },
    }));

    var owned = try snapshot.write(std.testing.allocator, .{}, &.{
        .{ .kind = .schema, .bytes = "schema" },
        .{ .kind = .forest, .bytes = "forest" },
    });
    defer owned.deinit();
    try std.testing.expectError(error.LimitExceeded, snapshot.Snapshot.openContainer(owned.bytes, .{ .max_file_bytes = owned.bytes.len - 1 }));
    try std.testing.expectError(error.LimitExceeded, snapshot.Snapshot.openContainer(owned.bytes, .{ .max_section_bytes = 1 }));
}

test "allocation-free query lookup matches fluent keys and enforces work buffers" {
    var builder = compile.Builder.initWithOptions(std.testing.allocator, .{ .prose = .{ .codec = .raw } });
    defer builder.deinit();
    const cat = try builder.root(.entry, .{ .headword = "cat" });
    _ = try builder.child(cat, .form, .{ .written = "cat" });
    const car = try builder.root(.entry, .{ .headword = "car" });
    _ = try builder.child(car, .form, .{ .written = "car" });
    var compiled = try builder.compile();
    defer compiled.deinit();
    var view = try snapshot.Snapshot.open(compiled.bytes, .{});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fluent_exact = query.Query.init(&view, &arena, .{});
    defer fluent_exact.deinit();
    const expected_exact = try fluent_exact.key(.headword, "cat", .exact).run();
    var fluent_prefix = query.Query.init(&view, &arena, .{});
    defer fluent_prefix.deinit();
    const expected_prefix = try fluent_prefix.key(.headword, "ca", .prefix).run();

    var key_scratch: [16]u8 = undefined;
    var output: [8]schema.Node = undefined;
    var direct = query.Query.init(&view, &arena, .{});
    defer direct.deinit();
    const actual_exact = try direct.lookup(.headword, "cat", .exact, &key_scratch, &output);
    try std.testing.expectEqualSlices(schema.Node, expected_exact.items, actual_exact.items);
    const actual_prefix = try direct.lookup(.headword, "ca", .prefix, &key_scratch, &output);
    try std.testing.expectEqualSlices(schema.Node, expected_prefix.items, actual_prefix.items);
    try std.testing.expect(actual_prefix.isSorted());
    try std.testing.expect(direct.explain().visited >= direct.explain().indexed);

    var tiny_key: [2]u8 = undefined;
    try std.testing.expectError(error.ScratchTooSmall, direct.lookup(.headword, "cat", .exact, &tiny_key, &output));
    var tiny_output: [1]schema.Node = undefined;
    try std.testing.expectError(error.BufferTooSmall, direct.lookup(.headword, "cat", .exact, &key_scratch, &tiny_output));

    var exhausted = query.Query.init(&view, &arena, .{ .max_visited = 0 });
    defer exhausted.deinit();
    try std.testing.expectError(error.BudgetExceeded, exhausted.lookup(.headword, "cat", .exact, &key_scratch, &output));
}

test "builder rejects cross-instance handles and rolls back compound mutations" {
    var first = compile.Builder.initWithOptions(std.testing.allocator, .{ .prose = .{ .codec = .raw } });
    defer first.deinit();
    const first_entry = try first.root(.entry, .{ .headword = "first" });

    var second = compile.Builder.init(std.testing.allocator);
    defer second.deinit();
    try std.testing.expectError(error.InvalidReference, second.child(first_entry, .sense, .{}));
    try std.testing.expectError(error.InvalidReference, second.set(first_entry, schema.columns.headword, "forged"));

    const invalid_utf8 = [_]u8{0xff};
    try std.testing.expectError(error.InvalidUtf8, first.child(first_entry, .form, .{ .written = invalid_utf8[0..] }));
    const form = try first.child(first_entry, .form, .{ .written = "valid" });
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(form.id));
    const sense = try first.child(first_entry, .sense, .{});

    const failed_assertion = first.assertion(schema.predicates.translation, sense, .{
        .{ .role = .source, .target = compile.Target{ .node = sense.any() } },
    }, .{});
    try std.testing.expectError(error.InvalidAssertion, failed_assertion);
    const valid_assertion = try first.assertion(schema.predicates.translation, sense, .{
        .{ .role = .source, .target = compile.Target{ .node = sense.any() } },
        .{ .role = .target, .target = compile.Target{ .node = sense.any() } },
    }, .{});
    _ = valid_assertion;
    // A failed child/compound assertion must not leave a phantom node behind.
    var compiled = try first.compile();
    defer compiled.deinit();
    const view = try snapshot.Snapshot.open(compiled.bytes, .{});
    const forest = try view.forest();
    try std.testing.expectEqual(@as(usize, 6), forest.count);
    try std.testing.expectError(error.InvalidReference, compiled.resolve(try second.root(.entry, .{ .headword = "other" })));
}

test "builtin assertions derive incremental shadow edges and runtime arities" {
    var builder = compile.Builder.initWithOptions(std.testing.allocator, .{ .prose = .{ .codec = .raw } });
    defer builder.deinit();
    const entry = try builder.root(.entry, .{ .headword = "forms" });
    const lexeme = try builder.child(entry, .lexeme, .{ .headword = "lemma" });
    const form = try builder.child(entry, .form, .{ .written = "forms" });
    const sense = try builder.child(entry, .sense, .{});
    const part = try builder.child(form, .part, .{ .written = "form", .role = "stem" });

    // Add canonical assertions one at a time. buildEdges must derive every
    // shadow edge from the final participant tree, including earlier
    // assertions after later nodes have been appended.
    const form_assertion = try builder.assertion(schema.predicates.form_of, entry, .{
        .{ .role = .source, .target = compile.Target{ .node = form.any() } },
        .{ .role = .target, .target = compile.Target{ .node = lexeme.any() } },
    }, .{});
    const sense_assertion = try builder.assertion(schema.predicates.sense_of, entry, .{
        .{ .role = .source, .target = compile.Target{ .node = sense.any() } },
        .{ .role = .target, .target = compile.Target{ .node = lexeme.any() } },
    }, .{});
    const realizes_assertion = try builder.assertion(schema.predicates.realizes, entry, .{
        .{ .role = .source, .target = compile.Target{ .node = part.any() } },
        .{ .role = .target, .target = compile.Target{ .node = lexeme.any() } },
    }, .{});

    const unary = try builder.runtimeAssertion("registers", entry, .{
        .{ .role = "subject", .target = compile.Target{ .node = sense.any() } },
    }, .{});
    const nary = try builder.runtimeAssertion("maps", entry, .{
        .{ .role = "source", .target = compile.Target{ .node = form.any() } },
        .{ .role = "target", .target = compile.Target{ .node = lexeme.any() } },
        .{ .role = "context", .target = compile.Target{ .unresolved = .{ .bytes = "urn:context" } } },
    }, .{});
    try std.testing.expectError(error.InvalidAssertion, builder.runtimeAssertion("form_of", entry, .{
        .{ .role = "source", .target = compile.Target{ .node = form.any() } },
    }, .{}));

    var compiled = try builder.compile();
    defer compiled.deinit();
    const view = try snapshot.Snapshot.open(compiled.bytes, .{});
    const entry_node = try compiled.resolve(entry);
    const lexeme_node = try compiled.resolve(lexeme);
    const form_node = try compiled.resolve(form);
    const sense_node = try compiled.resolve(sense);
    const part_node = try compiled.resolve(part);
    try std.testing.expectEqual(schema.Kind.assertion, try (try view.forest()).kind(try compiled.resolve(form_assertion)));
    try std.testing.expectEqual(schema.Kind.assertion, try (try view.forest()).kind(try compiled.resolve(sense_assertion)));
    try std.testing.expectEqual(schema.Kind.assertion, try (try view.forest()).kind(try compiled.resolve(realizes_assertion)));
    try std.testing.expectEqual(schema.Kind.assertion, try (try view.forest()).kind(try compiled.resolve(unary)));
    try std.testing.expectEqual(schema.Kind.assertion, try (try view.forest()).kind(try compiled.resolve(nary)));

    var targets: [2]schema.Node = undefined;
    var form_edges = try view.adjacency(.form_of);
    try std.testing.expectEqual(@as(usize, 1), try form_edges.targets(form_node, &targets));
    try std.testing.expectEqual(lexeme_node, targets[0]);
    var sense_edges = try view.adjacency(.sense_of);
    try std.testing.expectEqual(@as(usize, 1), try sense_edges.targets(sense_node, &targets));
    try std.testing.expectEqual(lexeme_node, targets[0]);
    var realizes_edges = try view.adjacency(.realizes);
    try std.testing.expectEqual(@as(usize, 1), try realizes_edges.targets(part_node, &targets));
    try std.testing.expectEqual(lexeme_node, targets[0]);

    // Runtime source/target roles derive an extension edge; the unary
    // `subject` role intentionally has no source×target shadow.
    var extension_edges = try view.adjacency(.extension);
    try std.testing.expectEqual(@as(usize, 1), try extension_edges.targets(form_node, &targets));
    try std.testing.expectEqual(lexeme_node, targets[0]);
    try std.testing.expectEqual(@as(usize, 0), try extension_edges.targets(entry_node, &targets));
}

test "builder compound mutations are leak-free at every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildAfterFailedMutation, .{});
}

fn buildAfterFailedMutation(allocator: std.mem.Allocator) !void {
    var builder = compile.Builder.initWithOptions(allocator, .{ .prose = .{ .codec = .raw } });
    defer builder.deinit();
    const entry = try builder.root(.entry, .{ .headword = "root" });
    const invalid_utf8 = [_]u8{0xff};
    if (builder.child(entry, .form, .{ .written = invalid_utf8[0..] })) |_| {
        return error.TestUnexpectedSuccess;
    } else |err| switch (err) {
        error.InvalidUtf8, error.OutOfMemory => {},
        else => return err,
    }
    _ = try builder.child(entry, .form, .{ .written = "ok" });
    var owned = try builder.compile();
    defer owned.deinit();
}

test "rich compile and post-compile materialization survive allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileRichFixture, .{});
}

fn compileRichFixture(allocator: std.mem.Allocator) !void {
    var builder = compile.Builder.initWithOptions(allocator, .{ .prose = .{ .codec = .raw, .max_items_per_block = 2 } });
    defer builder.deinit();

    const entry = try builder.root(.entry, .{ .headword = "rich", .lang = "en" });
    try builder.externalId(entry, 9, "rich-1");
    const lexeme = try builder.child(entry, .lexeme, .{ .headword = "rich" });
    const form = try builder.child(entry, .form, .{ .written = "richer" });
    const part = try builder.child(form, .part, .{ .written = "rich", .role = "stem" });
    _ = part;
    const sense = try builder.child(entry, .sense, .{});
    const definition = try builder.child(sense, .definition, .{ .text = "having abundant detail" });
    _ = try builder.child(sense, .example, .{ .text = "a rich example" });
    const extension = try builder.child(entry, .extension, .{ .qname = "tei:entry" });
    try builder.attribute(extension, "a\x00b", "one");
    try builder.attribute(extension, "xml:id", "rich-1");

    _ = try builder.assertion(schema.predicates.form_of, entry, .{
        .{ .role = .source, .target = compile.Target{ .node = form.any() } },
        .{ .role = .target, .target = compile.Target{ .node = lexeme.any() } },
    }, .{ .evidence = &.{.{ .quote = "attested" }} });
    _ = try builder.assertion(schema.predicates.sense_of, entry, .{
        .{ .role = .source, .target = compile.Target{ .node = sense.any() } },
        .{ .role = .target, .target = compile.Target{ .node = lexeme.any() } },
    }, .{});
    _ = try builder.runtimeAssertion("registers", entry, .{
        .{ .role = "subject", .target = compile.Target{ .node = sense.any() } },
        .{ .role = "context", .target = compile.Target{ .unresolved = .{ .bytes = "urn:rich" } } },
    }, .{ .certainty = .certain });

    var compiled = try builder.compile();
    defer compiled.deinit();
    const view = try snapshot.Snapshot.open(compiled.bytes, .{});
    try view.validateDeep(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var q = query.Query.init(&view, &arena, .{});
    var query_live = true;
    defer if (query_live) q.deinit();
    const definition_node = try compiled.resolve(definition);
    const set = try q.ids(&.{definition_node}).run();
    var rows = try q.materialize(set, &.{.text});
    // A raw Pin borrows the immutable snapshot bytes.  Releasing the Query's
    // reusable decoder before Rows.deinit must leave the row view valid.
    q.deinit();
    query_live = false;
    defer rows.deinit();
    const row = rows.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("having abundant detail", row.get(.text).?);
}

test "canonical descriptor checks are compile-time and query seeds are explicit" {
    // The negative forged-descriptor case is intentionally not instantiated:
    // Builder.set/link call schema.assertColumn/assertPredicate, whose
    // contract is a compile error. A compile-fail harness can exercise that
    // rejection without making this passing test module uncompilable.
    comptime {
        schema.assertColumn(schema.columns.headword);
        schema.assertColumn(schema.columns.text);
        schema.assertPredicate(schema.predicates.translation);
        if (@TypeOf(schema.columns.headword) != @TypeOf(schema.columnById(.headword))) @compileError("canonical column type drift");
    }

    var builder = compile.Builder.initWithOptions(std.testing.allocator, .{ .prose = .{ .codec = .raw } });
    defer builder.deinit();
    const entry = try builder.root(.entry, .{ .headword = "seed" });
    _ = try builder.child(entry, .form, .{ .written = "seed" });
    var compiled = try builder.compile();
    defer compiled.deinit();
    var view = try snapshot.Snapshot.open(compiled.bytes, .{});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var unseeded = query.Query.init(&view, &arena, .{});
    defer unseeded.deinit();
    try std.testing.expectError(error.InvalidOperation, unseeded.descendants().run());
    var unseeded_follow = query.Query.init(&view, &arena, .{});
    defer unseeded_follow.deinit();
    try std.testing.expectError(error.InvalidOperation, unseeded_follow.follow(.see_also).run());
    var reseeded = query.Query.init(&view, &arena, .{});
    defer reseeded.deinit();
    try std.testing.expectError(error.InvalidOperation, reseeded.ids(&.{@as(schema.Node, @enumFromInt(0))}).roots().run());
    var reseeded_key = query.Query.init(&view, &arena, .{});
    defer reseeded_key.deinit();
    try std.testing.expectError(error.InvalidOperation, reseeded_key.key(.headword, "seed", .exact).all(.entry).run());
}
