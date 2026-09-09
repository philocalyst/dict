const std = @import("std");
const automaton = @import("automaton.zig");
const schema = @import("schema.zig");
const forest = @import("forest.zig");

fn buildFixture(allocator: std.mem.Allocator) !void {
    var builder = forest.Builder.init(allocator);
    defer builder.deinit();
    const z = try builder.addRoot("zeta", .entry);
    const z_sense = try builder.addChild(z, .sense);
    _ = try builder.addChild(z_sense, .definition);
    const a = try builder.addRoot("alpha", .entry);
    const a_sense = try builder.addChild(a, .sense);
    _ = try builder.addChild(a_sense, .definition);
    var owned = try builder.build();
    owned.deinit();
}

fn sectionOffset(bytes: []const u8, index: usize) usize {
    return @intCast(std.mem.readInt(u64, bytes[32 + index * 16 ..][0..8], .little));
}

fn sectionLength(bytes: []const u8, index: usize) usize {
    return @intCast(std.mem.readInt(u64, bytes[32 + index * 16 + 8 ..][0..8], .little));
}

fn expectRankSelectOracle(view: *const forest.View) !void {
    inline for (@typeInfo(schema.Kind).@"enum".fields) |field| {
        const kind: schema.Kind = @enumFromInt(field.value);
        var expected: usize = 0;
        for (0..view.count + 1) |boundary| {
            const actual = try view.kindRankAt(kind, boundary);
            try std.testing.expectEqual(expected, @as(usize, @intFromEnum(actual)));
            if (boundary < view.count and try view.kind(@enumFromInt(boundary)) == kind) expected += 1;
        }
        try std.testing.expectEqual(expected, try view.kindCount(kind));
        var ordinal: usize = 0;
        for (0..view.count) |node_index| {
            const node: forest.Node = @enumFromInt(node_index);
            if (try view.kind(node) != kind) continue;
            const rank_value = try view.kindRank(kind, node);
            try std.testing.expectEqual(node_index, @intFromEnum(try view.selectKind(kind, rank_value)));
            ordinal += 1;
        }
        if (ordinal == 0) {
            const zero = try schema.Rank(kind).fromIndex(0);
            try std.testing.expectError(error.OutOfRange, view.selectKind(kind, zero));
        }
        try std.testing.expectError(error.InvalidRank, view.selectKind(kind, .none));
    }
}

fn buildNonzeroConstantWire(allocator: std.mem.Allocator) ![]u8 {
    const nodes = [_]forest.NodeRecord{
        .{ .kind = .entry, .subtree_size = 2, .parent = null },
        .{ .kind = .sense, .subtree_size = 1, .parent = @enumFromInt(0) },
        .{ .kind = .entry, .subtree_size = 2, .parent = null },
        .{ .kind = .form, .subtree_size = 1, .parent = @enumFromInt(2) },
        .{ .kind = .entry, .subtree_size = 2, .parent = null },
        .{ .kind = .sense, .subtree_size = 1, .parent = @enumFromInt(4) },
    };
    const roots = [_]forest.RootInput{
        .{ .start = @enumFromInt(0) },
        .{ .start = @enumFromInt(2) },
        .{ .start = @enumFromInt(4) },
    };
    var mixed = try forest.encode(allocator, &nodes, &roots);
    defer mixed.deinit();
    const data_end = sectionOffset(mixed.bytes, 1) + sectionLength(mixed.bytes, 1);
    const bytes = try allocator.alloc(u8, data_end);
    errdefer allocator.free(bytes);
    @memcpy(bytes, mixed.bytes[0..data_end]);
    std.mem.writeInt(u16, bytes[6..8], 1 << 2, .little); // derived constant summaries
    std.mem.writeInt(u32, bytes[8..12], 6, .little);
    std.mem.writeInt(u32, bytes[12..16], 3, .little);
    std.mem.writeInt(u32, bytes[16..20], 2, .little);
    std.mem.writeInt(u32, bytes[20..24], 1, .little);
    std.mem.writeInt(u32, bytes[24..28], 1, .little); // deliberately nonzero
    std.mem.writeInt(u32, bytes[28..32], 2, .little);
    var cursor: usize = 128;
    for ([_]usize{ sectionLength(mixed.bytes, 0), sectionLength(mixed.bytes, 1), 0, 0, 0, 0 }, 0..) |length, index| {
        std.mem.writeInt(u64, bytes[32 + index * 16 ..][0..8], @intCast(cursor), .little);
        std.mem.writeInt(u64, bytes[32 + index * 16 + 8 ..][0..8], @intCast(length), .little);
        cursor += length;
    }
    try std.testing.expectEqual(bytes.len, cursor);
    return bytes;
}

test "skeleton equivalence, key order, rank projection, and no key storage" {
    var builder = forest.Builder.init(std.testing.allocator);
    defer builder.deinit();

    const zeta = try builder.addRoot("zeta", .entry);
    const zeta_sense = try builder.addChild(zeta, .sense);
    _ = try builder.addChild(zeta_sense, .definition);

    // Duplicate keys are legal for homograph-like roots. Structural ordering
    // makes their order independent of insertion order.
    const alpha_short = try builder.addRoot("alpha", .entry);
    _ = try builder.addChild(alpha_short, .sense);
    const alpha_long = try builder.addRoot("alpha", .entry);
    const alpha_sense = try builder.addChild(alpha_long, .sense);
    _ = try builder.addChild(alpha_sense, .definition);

    var owned = try builder.build();
    defer owned.deinit();
    try owned.view.verify();
    const view = &owned.view;

    try std.testing.expectEqual(@as(usize, 8), view.count);
    try std.testing.expectEqual(@as(usize, 3), view.root_count);
    try std.testing.expectEqual(@as(usize, 2), view.skeleton_count);
    try std.testing.expect(view.root_starts.len != 0); // variable skeleton sizes
    try std.testing.expectEqual(@as(usize, 128), view.byteLedger().header);

    // The wire has no key payload, even though the builder used keys to sort.
    try std.testing.expect(std.mem.indexOf(u8, owned.bytes, "alpha") == null);
    try std.testing.expectError(error.KeysNotStored, view.rootKey(0));

    // alpha-short, alpha-long, zeta: the builder's key order is visible only
    // through root ranges and the automaton rank that names each root.
    try std.testing.expectEqual(@as(usize, 2), (try view.rootRange(0, 1)).len());
    try std.testing.expectEqual(@as(usize, 3), (try view.rootRange(1, 2)).len());
    try std.testing.expectEqual(@as(usize, 3), (try view.rootRange(2, 3)).len());
    try std.testing.expectEqual(@as(usize, 0), @intFromEnum(try view.rootAt(0)));
    try std.testing.expectEqual(@as(usize, 2), @intFromEnum(try view.rootAt(1)));
    try std.testing.expectEqual(@as(usize, 5), @intFromEnum(try view.rootAt(2)));

    const expected_kinds = [_]schema.Kind{ .entry, .sense, .definition };
    const expected_sizes = [_]usize{ 3, 2, 1 };
    for ([_]usize{ 1, 2 }) |root_index| {
        const skeleton = try view.skeleton(root_index);
        try std.testing.expectEqual(expected_kinds.len, skeleton.len());
        for (expected_kinds, 0..) |expected_kind, local| {
            try std.testing.expectEqual(expected_kind, try skeleton.kindAt(local));
            try std.testing.expectEqual(expected_sizes[local], try skeleton.subtreeSizeAt(local));
            const expected_parent: ?usize = if (local == 0) null else local - 1;
            const actual_parent = try skeleton.parentAt(local);
            if (expected_parent) |parent| try std.testing.expectEqual(parent + skeleton.start, @intFromEnum(actual_parent.?)) else try std.testing.expect(actual_parent == null);
        }
    }
    const short = try view.skeleton(0);
    try std.testing.expectEqual(schema.Kind.entry, try short.kindAt(0));
    try std.testing.expectEqual(@as(usize, 2), try short.subtreeSizeAt(0));

    try std.testing.expectEqual(@as(usize, 3), try view.kindCount(.sense));
    try std.testing.expectEqual(@as(usize, 2), try view.kindCount(.definition));
    const senses = try view.projectRoots(.sense, try forest.RootRange.init(0, 2));
    try std.testing.expectEqual(@as(usize, 0), @intFromEnum(senses.lo));
    try std.testing.expectEqual(@as(usize, 2), @intFromEnum(senses.hi));
    const definitions = try view.nodeSet(.definition, try view.rootRange(1, 3));
    try std.testing.expectEqual(@as(usize, 2), definitions.len());

    var reversed = forest.Builder.init(std.testing.allocator);
    defer reversed.deinit();
    const r_long = try reversed.addRoot("alpha", .entry);
    const r_sense = try reversed.addChild(r_long, .sense);
    _ = try reversed.addChild(r_sense, .definition);
    const r_short = try reversed.addRoot("alpha", .entry);
    _ = try reversed.addChild(r_short, .sense);
    const r_zeta = try reversed.addRoot("zeta", .entry);
    const r_zeta_sense = try reversed.addChild(r_zeta, .sense);
    _ = try reversed.addChild(r_zeta_sense, .definition);
    var reversed_owned = try reversed.build();
    defer reversed_owned.deinit();
    try std.testing.expectEqualSlices(u8, owned.bytes, reversed_owned.bytes);
}

test "repeated skeletons use a constant sequence and the whole artifact is small" {
    const root_count = 2048;
    const nodes = try std.testing.allocator.alloc(forest.NodeRecord, root_count * 3);
    defer std.testing.allocator.free(nodes);
    const roots = try std.testing.allocator.alloc(forest.RootInput, root_count);
    defer std.testing.allocator.free(roots);
    for (0..root_count) |root_index| {
        const start = root_index * 3;
        nodes[start] = .{ .kind = .entry, .subtree_size = 3, .parent = null };
        nodes[start + 1] = .{ .kind = .sense, .subtree_size = 2, .parent = @enumFromInt(start) };
        nodes[start + 2] = .{ .kind = .definition, .subtree_size = 1, .parent = @enumFromInt(start + 1) };
        roots[root_index] = .{ .start = @enumFromInt(start) };
    }
    var owned = try forest.encode(std.testing.allocator, nodes, roots);
    defer owned.deinit();
    try owned.view.verify();
    try std.testing.expectEqual(@as(usize, 1), owned.view.skeleton_count);
    try std.testing.expect(!owned.view.packed_sequence);
    try std.testing.expectEqual(@as(usize, 0), owned.view.root_sequence.len);
    try std.testing.expectEqual(@as(usize, 0), owned.view.root_starts.len);
    const ledger = owned.view.byteLedger();
    try std.testing.expectEqual(@as(usize, 128), ledger.header);
    try std.testing.expectEqual(@as(usize, 16), ledger.skeleton_directory);
    try std.testing.expectEqual(@as(usize, 9), ledger.skeleton_data);
    try std.testing.expectEqual(@as(usize, 0), ledger.skeleton_kind_counts);
    try std.testing.expectEqual(@as(usize, 0), ledger.root_sequence);
    try std.testing.expectEqual(@as(usize, 0), ledger.root_starts);
    try std.testing.expectEqual(@as(usize, 0), ledger.root_checkpoints);
    try std.testing.expectEqual(ledger.total(), owned.bytes.len);
    try std.testing.expectEqual(@as(usize, 153), ledger.total());
    try std.testing.expect(ledger.total() <= 40 * 1024);
    try std.testing.expectEqual(@as(usize, 3), (try owned.view.rootRange(root_count - 1, root_count)).len());
    try std.testing.expectEqual(@as(usize, root_count), try owned.view.kindCount(.entry));
}

test "constant affine measure and inverse selection cover every kind boundary" {
    var builder = forest.Builder.init(std.testing.allocator);
    defer builder.deinit();
    const first = try builder.addRoot("first", .entry);
    const first_sense = try builder.addChild(first, .sense);
    _ = try builder.addChild(first_sense, .definition);
    const second = try builder.addRoot("second", .entry);
    const second_sense = try builder.addChild(second, .sense);
    _ = try builder.addChild(second_sense, .definition);
    var owned = try builder.build();
    defer owned.deinit();
    try owned.view.verify();
    try std.testing.expect(owned.view.derived_constant_summaries);
    try std.testing.expectEqual(@as(usize, 153), owned.bytes.len);
    try expectRankSelectOracle(&owned.view);
}

test "mixed affine fallback and irregular zero-or-many text domains use one oracle" {
    var builder = forest.Builder.init(std.testing.allocator);
    defer builder.deinit();
    const first = try builder.addRoot("a", .entry);
    const first_sense = try builder.addChild(first, .sense);
    _ = try builder.addChild(first_sense, .definition);
    _ = try builder.addChild(first_sense, .usage);
    _ = try builder.addChild(first_sense, .usage);
    const second = try builder.addRoot("b", .entry);
    _ = try builder.addChild(second, .form);
    const third = try builder.addRoot("c", .entry);
    const third_sense = try builder.addChild(third, .sense);
    const third_subsense = try builder.addChild(third_sense, .subsense);
    _ = try builder.addChild(third_subsense, .example);
    const fourth = try builder.addRoot("d", .concept);
    _ = try builder.addChild(fourth, .annotation);
    var owned = try builder.build();
    defer owned.deinit();
    try owned.view.verify();
    try std.testing.expect(!owned.view.derived_constant_summaries);
    try std.testing.expect(owned.view.packed_sequence);
    try expectRankSelectOracle(&owned.view);

    var empty = try forest.encode(std.testing.allocator, &.{}, &.{});
    defer empty.deinit();
    try empty.view.verify();
    try expectRankSelectOracle(&empty.view);
}

test "mixed checkpoint select crosses zero-kind blocks and final boundaries" {
    const root_count = 513;
    const nodes = try std.testing.allocator.alloc(forest.NodeRecord, root_count * 3);
    defer std.testing.allocator.free(nodes);
    const roots = try std.testing.allocator.alloc(forest.RootInput, root_count);
    defer std.testing.allocator.free(roots);
    var cursor: usize = 0;
    for (0..root_count) |root_index| {
        const start = cursor;
        nodes[cursor] = .{ .kind = .entry, .subtree_size = if (root_index % 2 == 0) 3 else 1, .parent = null };
        cursor += 1;
        if (root_index % 2 == 0) {
            nodes[cursor] = .{ .kind = .sense, .subtree_size = 2, .parent = @enumFromInt(start) };
            cursor += 1;
            nodes[cursor] = .{ .kind = .definition, .subtree_size = 1, .parent = @enumFromInt(start + 1) };
            cursor += 1;
        }
        roots[root_index] = .{ .start = @enumFromInt(start) };
    }
    var owned = try forest.encode(std.testing.allocator, nodes[0..cursor], roots);
    defer owned.deinit();
    try owned.view.verify();
    try std.testing.expect(owned.view.packed_sequence);
    try std.testing.expect(owned.view.checkpoint_count >= 3);
    try expectRankSelectOracle(&owned.view);
}

test "constant summaries derive skeleton zero and authenticate the exact active mask" {
    const nodes = [_]forest.NodeRecord{
        .{ .kind = .entry, .subtree_size = 2, .parent = null },
        .{ .kind = .sense, .subtree_size = 1, .parent = @enumFromInt(0) },
        .{ .kind = .entry, .subtree_size = 2, .parent = null },
        .{ .kind = .sense, .subtree_size = 1, .parent = @enumFromInt(2) },
    };
    var owned = try forest.encode(std.testing.allocator, &nodes, &.{ .{ .start = @enumFromInt(0) }, .{ .start = @enumFromInt(2) } });
    defer owned.deinit();
    try owned.view.verify();
    try std.testing.expect(owned.view.derived_constant_summaries);
    try std.testing.expectEqual(@as(u32, 0), try owned.view.skeletonId(0));
    try expectRankSelectOracle(&owned.view);

    var bad_mask = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_mask);
    std.mem.writeInt(u32, bad_mask[24..28], std.mem.readInt(u32, bad_mask[24..28], .little) | (@as(u32, 1) << @intFromEnum(schema.Kind.definition)), .little);
    const bad_mask_view = try forest.View.open(bad_mask);
    try std.testing.expectError(error.InvalidSkeleton, bad_mask_view.verify());

    var bad_uniform = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_uniform);
    std.mem.writeInt(u32, bad_uniform[28..32], 1, .little);
    const bad_uniform_view = try forest.View.open(bad_uniform);
    try std.testing.expectError(error.InvalidRoot, bad_uniform_view.verify());
    try std.testing.expectError(error.InvalidForest, bad_uniform_view.kindRankAt(.sense, 0));

    var bad_count = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_count);
    std.mem.writeInt(u32, bad_count[8..12], 5, .little);
    const bad_count_view = try forest.View.open(bad_count);
    try std.testing.expectError(error.InvalidForest, bad_count_view.verify());
    try std.testing.expectError(error.InvalidForest, bad_count_view.kindRankAt(.sense, 0));

    var bad_summary_flag = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_summary_flag);
    std.mem.writeInt(u16, bad_summary_flag[6..8], 0, .little);
    try std.testing.expectError(error.InvalidSequence, forest.View.open(bad_summary_flag));
}

test "variable skeletons use packed root IDs and derived root starts" {
    const nodes = [_]forest.NodeRecord{
        .{ .kind = .entry, .subtree_size = 1, .parent = null },
        .{ .kind = .entry, .subtree_size = 2, .parent = null },
        .{ .kind = .sense, .subtree_size = 1, .parent = @enumFromInt(1) },
        .{ .kind = .entry, .subtree_size = 1, .parent = null },
        .{ .kind = .entry, .subtree_size = 2, .parent = null },
        .{ .kind = .sense, .subtree_size = 1, .parent = @enumFromInt(4) },
    };
    const roots = [_]forest.RootInput{
        .{ .start = @enumFromInt(0) },
        .{ .start = @enumFromInt(1) },
        .{ .start = @enumFromInt(3) },
        .{ .start = @enumFromInt(4) },
    };
    var owned = try forest.encode(std.testing.allocator, &nodes, &roots);
    defer owned.deinit();
    try owned.view.verify();
    try std.testing.expect(owned.view.packed_sequence);
    try std.testing.expectEqual(@as(u8, 1), owned.view.sequence_width);
    try std.testing.expect(owned.view.root_starts.len != 0);
    const first_id = try owned.view.skeletonId(0);
    const second_id = try owned.view.skeletonId(1);
    try std.testing.expect(first_id != second_id);
    try std.testing.expectEqual(first_id, try owned.view.skeletonId(2));
    try std.testing.expectEqual(second_id, try owned.view.skeletonId(3));
    try std.testing.expectEqual(@as(usize, 3), (try owned.view.rootRange(1, 3)).len());
    try std.testing.expectEqual(@as(usize, 2), try owned.view.subtreeSize(try owned.view.rootAt(1)));
    try std.testing.expectEqual(@as(usize, 3), try owned.view.subtreeEnd(try owned.view.rootAt(1)));
}

test "distinct skeletons choose checked local widths for deep trees" {
    const depth = 300;
    const nodes = try std.testing.allocator.alloc(forest.NodeRecord, depth);
    defer std.testing.allocator.free(nodes);
    nodes[0] = .{ .kind = .entry, .subtree_size = depth, .parent = null };
    nodes[1] = .{ .kind = .sense, .subtree_size = depth - 1, .parent = @enumFromInt(0) };
    for (2..depth) |index| nodes[index] = .{ .kind = .subsense, .subtree_size = @intCast(depth - index), .parent = @enumFromInt(index - 1) };
    const roots = [_]forest.RootInput{.{ .start = @enumFromInt(0) }};
    var owned = try forest.encode(std.testing.allocator, nodes, &roots);
    defer owned.deinit();
    try owned.view.verify();
    const skeleton = try owned.view.skeleton(0);
    try std.testing.expectEqual(@as(usize, depth), skeleton.len());
    try std.testing.expectEqual(@as(usize, depth), try owned.view.subtreeSize(try owned.view.rootAt(0)));
    try std.testing.expectEqual(@as(usize, depth - 2), @intFromEnum((try owned.view.parent(@enumFromInt(depth - 1))).?));
}

test "empty, duplicate, unsorted, and automaton-count boundaries" {
    var empty = try forest.encode(std.testing.allocator, &.{}, &.{});
    defer empty.deinit();
    try empty.view.verify();
    try std.testing.expectEqual(@as(usize, 0), empty.view.count);
    try std.testing.expectEqual(@as(usize, 128), empty.bytes.len);
    try std.testing.expectEqual(@as(usize, 0), empty.view.byteLedger().skeleton_kind_counts);
    try std.testing.expectEqual(@as(usize, 0), empty.view.byteLedger().root_checkpoints);
    try std.testing.expectEqual(@as(usize, 0), try empty.view.kindCount(.sense));
    try std.testing.expectEqual(@as(usize, 0), (try empty.view.rootRange(0, 0)).len());

    const duplicate_nodes = [_]forest.NodeRecord{
        .{ .kind = .entry, .subtree_size = 1, .parent = null },
        .{ .kind = .entry, .subtree_size = 1, .parent = null },
    };
    const duplicate_roots = [_]forest.RootInput{
        .{ .key = "same", .start = @enumFromInt(0) },
        .{ .key = "same", .start = @enumFromInt(1) },
    };
    var duplicate = try forest.encode(std.testing.allocator, &duplicate_nodes, &duplicate_roots);
    defer duplicate.deinit();
    try std.testing.expectEqual(@as(usize, 1), duplicate.view.skeleton_count);
    try std.testing.expectError(error.EntryCountMismatch, forest.encodeWithEntryCount(std.testing.allocator, 3, &duplicate_nodes, &duplicate_roots));
    try std.testing.expectError(error.EntryCountMismatch, forest.encodeForAutomaton(std.testing.allocator, .{ .entry_count = @as(usize, 3) }, &duplicate_nodes, &duplicate_roots));
    var matched = try forest.encodeForAutomaton(std.testing.allocator, .{ .entry_count = @as(usize, 2) }, &duplicate_nodes, &duplicate_roots);
    defer matched.deinit();

    const unsorted_roots = [_]forest.RootInput{
        .{ .key = "z", .start = @enumFromInt(0) },
        .{ .key = "a", .start = @enumFromInt(1) },
    };
    try std.testing.expectError(error.InvalidKey, forest.encode(std.testing.allocator, &duplicate_nodes, &unsorted_roots));
}

test "the real automaton entry count is the forest integration boundary" {
    var automaton_builder = automaton.Builder.init(std.testing.allocator);
    defer automaton_builder.deinit();
    try automaton_builder.addEntry("alpha", 1);
    try automaton_builder.addEntry("zeta", 1);
    var automaton_owned = try automaton_builder.finish();
    defer automaton_owned.deinit();
    const automaton_view = try automaton.View.open(automaton_owned.bytes);

    const nodes = [_]forest.NodeRecord{
        .{ .kind = .entry, .subtree_size = 1, .parent = null },
        .{ .kind = .entry, .subtree_size = 1, .parent = null },
    };
    const roots = [_]forest.RootInput{ .{ .start = @enumFromInt(0) }, .{ .start = @enumFromInt(1) } };
    var owned = try forest.encodeForAutomaton(std.testing.allocator, automaton_view, &nodes, &roots);
    defer owned.deinit();
    try std.testing.expectEqual(automaton_view.entry_count, @as(u32, @intCast(owned.view.root_count)));
    const checked = try forest.View.openForAutomaton(owned.bytes, automaton_view);
    try checked.verify();
    try std.testing.expectError(error.EntryCountMismatch, forest.View.openForEntryCount(owned.bytes, 3));
}

test "measured complete Step-A automaton plus forest artifact stays under 40 KiB" {
    const entry_count = 2048;
    var automaton_builder = automaton.Builder.init(std.testing.allocator);
    defer automaton_builder.deinit();
    const nodes = try std.testing.allocator.alloc(forest.NodeRecord, entry_count);
    defer std.testing.allocator.free(nodes);
    const roots = try std.testing.allocator.alloc(forest.RootInput, entry_count);
    defer std.testing.allocator.free(roots);
    var key: [16]u8 = undefined;
    for (0..entry_count) |index| {
        const text = try std.fmt.bufPrint(&key, "entry-{d:0>4}", .{index});
        try automaton_builder.addEntry(text, 1);
        nodes[index] = .{ .kind = .entry, .subtree_size = 1, .parent = null };
        roots[index] = .{ .start = @enumFromInt(index) };
    }
    var automaton_owned = try automaton_builder.finish();
    defer automaton_owned.deinit();
    const automaton_view = try automaton.View.open(automaton_owned.bytes);
    var forest_owned = try forest.encodeForAutomaton(std.testing.allocator, automaton_view, nodes, roots);
    defer forest_owned.deinit();
    const total = automaton_owned.bytes.len + forest_owned.bytes.len;
    std.debug.print("LEX4_STEP_A_TOTAL automaton={} forest={} total={}\n", .{ automaton_owned.bytes.len, forest_owned.bytes.len, total });
    try std.testing.expectEqual(@as(usize, entry_count), forest_owned.view.root_count);
    try std.testing.expect(total <= 40 * 1024);
}

test "open is cheap while verify rejects malformed, cyclic, skipped, and out-of-range data" {
    const nodes = [_]forest.NodeRecord{
        .{ .kind = .entry, .subtree_size = 3, .parent = null },
        .{ .kind = .sense, .subtree_size = 2, .parent = @enumFromInt(0) },
        .{ .kind = .definition, .subtree_size = 1, .parent = @enumFromInt(1) },
    };
    const roots = [_]forest.RootInput{.{ .key = "word", .start = @enumFromInt(0) }};
    var owned = try forest.encode(std.testing.allocator, &nodes, &roots);
    defer owned.deinit();

    var bad_magic = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_magic);
    bad_magic[0] = 'X';
    try std.testing.expectError(error.BadMagic, forest.View.open(bad_magic));

    var bad_kind = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_kind);
    bad_kind[sectionOffset(bad_kind, 1)] = 255;
    const bad_kind_view = try forest.View.open(bad_kind);
    try std.testing.expectError(error.InvalidSkeleton, bad_kind_view.verify());

    var bad_parent = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_parent);
    const data = sectionOffset(bad_parent, 1);
    bad_parent[data + 3 + 1 + 1] = 0;
    const bad_parent_view = try forest.View.open(bad_parent);
    try std.testing.expectError(error.InvalidSkeleton, bad_parent_view.verify());

    const variable_nodes = [_]forest.NodeRecord{
        .{ .kind = .entry, .subtree_size = 1, .parent = null },
        .{ .kind = .entry, .subtree_size = 2, .parent = null },
        .{ .kind = .sense, .subtree_size = 1, .parent = @enumFromInt(1) },
    };
    const variable_roots = [_]forest.RootInput{
        .{ .start = @enumFromInt(0) },
        .{ .start = @enumFromInt(1) },
    };
    var variable = try forest.encode(std.testing.allocator, &variable_nodes, &variable_roots);
    defer variable.deinit();
    var bad_start = try std.testing.allocator.dupe(u8, variable.bytes);
    defer std.testing.allocator.free(bad_start);
    const starts = sectionOffset(bad_start, 4);
    std.mem.writeInt(u32, bad_start[starts + 4 ..][0..4], 0, .little);
    const bad_start_view = try forest.View.open(bad_start);
    try std.testing.expectError(error.InvalidRoot, bad_start_view.verify());

    var bad_sequence = try std.testing.allocator.dupe(u8, variable.bytes);
    defer std.testing.allocator.free(bad_sequence);
    const sequence = sectionOffset(bad_sequence, 3);
    bad_sequence[sequence] |= 4; // non-zero padding bits are malformed
    const bad_sequence_view = try forest.View.open(bad_sequence);
    try std.testing.expectError(error.InvalidSequence, bad_sequence_view.verify());

    const cyclic = [_]forest.NodeRecord{.{ .kind = .entry, .subtree_size = 1, .parent = @enumFromInt(0) }};
    try std.testing.expectError(error.InvalidRoot, forest.encode(std.testing.allocator, &cyclic, &roots));
    const skipped = [_]forest.NodeRecord{
        .{ .kind = .entry, .subtree_size = 3, .parent = null },
        .{ .kind = .sense, .subtree_size = 2, .parent = @enumFromInt(0) },
        .{ .kind = .definition, .subtree_size = 1, .parent = @enumFromInt(0) },
    };
    try std.testing.expectError(error.InvalidForest, forest.encode(std.testing.allocator, &skipped, &roots));
    const out_of_range = [_]forest.RootInput{.{ .key = "word", .start = @enumFromInt(99) }};
    try std.testing.expectError(error.InvalidRoot, forest.encode(std.testing.allocator, &nodes, &out_of_range));
}

test "verify rejects overlapping, truncated, and reserved skeleton directory records" {
    const nodes = [_]forest.NodeRecord{
        .{ .kind = .entry, .subtree_size = 1, .parent = null },
        .{ .kind = .entry, .subtree_size = 2, .parent = null },
        .{ .kind = .sense, .subtree_size = 1, .parent = @enumFromInt(1) },
    };
    const roots = [_]forest.RootInput{
        .{ .start = @enumFromInt(0) },
        .{ .start = @enumFromInt(1) },
    };
    var owned = try forest.encode(std.testing.allocator, &nodes, &roots);
    defer owned.deinit();

    const directory = sectionOffset(owned.bytes, 0);
    const first_length = std.mem.readInt(u32, owned.bytes[directory + 4 ..][0..4], .little);

    var overlap = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(overlap);
    std.mem.writeInt(u32, overlap[directory + 16 ..][0..4], 0, .little);
    const overlap_view = try forest.View.open(overlap);
    try std.testing.expectError(error.InvalidEncoding, overlap_view.verify());

    var truncated = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(truncated);
    std.mem.writeInt(u32, truncated[directory + 4 ..][0..4], first_length - 1, .little);
    const truncated_view = try forest.View.open(truncated);
    try std.testing.expectError(error.InvalidEncoding, truncated_view.verify());

    var reserved = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(reserved);
    reserved[directory + 14] = 1;
    const reserved_view = try forest.View.open(reserved);
    try std.testing.expectError(error.InvalidEncoding, reserved_view.verify());
}

test "builder and compact encoder are leak-free at every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildFixture, .{});
}
