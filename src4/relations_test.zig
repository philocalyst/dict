const std = @import("std");
const rel = @import("relations.zig");
const container = @import("container.zig");

test "endpoint streams stop at the first different key and stay exhausted" {
    const a = try rel.Endpoint.fromRank(.sense, try rel.Rank(.sense).fromIndex(1));
    const b = try rel.Endpoint.fromRank(.sense, try rel.Rank(.sense).fromIndex(3));
    const target = try rel.Endpoint.fromRank(.sense, try rel.Rank(.sense).fromIndex(7));
    const group_a = try rel.Endpoint.fromRank(.concept, try rel.Rank(.concept).fromIndex(1));
    const group_b = try rel.Endpoint.fromRank(.concept, try rel.Rank(.concept).fromIndex(3));
    var owned = try rel.build(std.testing.allocator, .{
        .edges = &.{
            .{ .relation = .entails, .source = a, .target = target },
            .{ .relation = .entails, .source = b, .target = target },
        },
        .memberships = &.{
            .{ .group = group_a, .member = a },
            .{ .group = group_a, .member = target },
            .{ .group = group_b, .member = b },
        },
    }, .{});
    defer owned.deinit();

    // Misses before, between, and after groups must not consume a neighbor.
    for (0..9) |ordinal| {
        const sense = try rel.Endpoint.fromRank(.sense, try rel.Rank(.sense).fromIndex(ordinal));
        var claims = try owned.view.relationsExplicit(sense, .entails);
        var count: usize = 0;
        while (try claims.next()) |edge| {
            try std.testing.expect(edge.source.eql(sense));
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, if (ordinal == 1 or ordinal == 3) 1 else 0), count);
        try std.testing.expectEqual(null, try claims.next());

        const concept = try rel.Endpoint.fromRank(.concept, try rel.Rank(.concept).fromIndex(ordinal));
        var members = try owned.view.members(concept);
        count = 0;
        while (try members.next()) |member| {
            try std.testing.expect(member.group.eql(concept));
            count += 1;
        }
        const expected: usize = if (ordinal == 1) 2 else if (ordinal == 3) 1 else 0;
        try std.testing.expectEqual(expected, count);
        try std.testing.expectEqual(null, try members.next());
    }
}

const Expected = struct {
    relation: rel.RelationId,
    source: rel.Endpoint,
    target: rel.Endpoint,
    state: rel.AssertionState,
    certainty: rel.Certainty,

    fn eql(self: @This(), edge: rel.Edge) bool {
        return self.relation == edge.relation and self.source.eql(edge.source) and
            self.target.eql(edge.target) and self.state == edge.state and self.certainty == edge.certainty;
    }
};

fn addExpected(expected: *[256]Expected, length: *usize, value: Expected) !void {
    for (expected[0..length.*]) |candidate| if (candidate.eql(.{
        .relation = value.relation,
        .source = value.source,
        .target = value.target,
        .state = value.state,
        .certainty = value.certainty,
        .asserted_by = null,
        .explicit = true,
        .physical_index = 0,
    })) return;
    if (length.* == expected.len) return error.TestExpectedEqual;
    expected[length.*] = value;
    length.* += 1;
}

test "randomized relation queries match a direct-edge oracle" {
    var seed: u64 = 0x4c455834_72656c61;
    var inputs: [96]rel.EdgeInput = undefined;
    var input_len: usize = 0;
    var expected: [256]Expected = undefined;
    var expected_len: usize = 0;

    while (input_len < inputs.len) : (input_len += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const source_index = @as(usize, @intCast(seed % 12));
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const target_index = @as(usize, @intCast(seed % 12));
        const source_rank = try rel.Rank(.sense).fromIndex(source_index);
        const target_rank = try rel.Rank(.sense).fromIndex(target_index);
        const source = try rel.Endpoint.fromRank(.sense, source_rank);
        const target = try rel.Endpoint.fromRank(.sense, target_rank);
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const relation: rel.RelationId = switch (seed % 3) {
            0 => .see_also,
            1 => .entails,
            else => .near_translation,
        };
        const state: rel.AssertionState = if (relation == .near_translation and seed & 1 == 1) .disputed else .asserted;
        const certainty: rel.Certainty = if (relation == .near_translation) .possible else .unknown;
        inputs[input_len] = .{ .relation = relation, .source = source, .target = target, .state = state, .certainty = certainty };

        try addExpected(&expected, &expected_len, .{ .relation = relation, .source = source, .target = target, .state = state, .certainty = certainty });
        if (relation == .see_also and !source.eql(target)) {
            try addExpected(&expected, &expected_len, .{ .relation = relation, .source = target, .target = source, .state = state, .certainty = certainty });
        }
    }

    var owned = try rel.build(std.testing.allocator, .{ .edges = inputs[0..] }, .{});
    defer owned.deinit();

    for (0..12) |source_index| {
        const source_rank = try rel.Rank(.sense).fromIndex(source_index);
        const source = try rel.Endpoint.fromRank(.sense, source_rank);
        var iterator = try owned.view.relations(source, null);
        var count: usize = 0;
        while (try iterator.next()) |edge| {
            var matched = false;
            for (expected[0..expected_len]) |candidate| {
                if (candidate.eql(edge)) {
                    matched = true;
                    break;
                }
            }
            try std.testing.expect(matched);
            count += 1;
        }
        var expected_count: usize = 0;
        for (expected[0..expected_len]) |candidate| {
            if (candidate.source.eql(source)) expected_count += 1;
        }
        try std.testing.expectEqual(expected_count, count);
    }

    // Direct queries never manufacture the transitive a→c result from a→b→c.
    const a = try rel.Rank(.sense).fromIndex(0);
    const b = try rel.Rank(.sense).fromIndex(1);
    const c = try rel.Rank(.sense).fromIndex(2);
    const chain = [_]rel.EdgeInput{
        try rel.typedEdge(.entails, .sense, .sense, a, b, .{}),
        try rel.typedEdge(.entails, .sense, .sense, b, c, .{}),
    };
    var chain_owned = try rel.build(std.testing.allocator, .{ .edges = &chain }, .{});
    defer chain_owned.deinit();
    var direct = try chain_owned.view.relations(try rel.Endpoint.fromRank(.sense, a), .entails);
    try std.testing.expect((try direct.next()) != null);
    try std.testing.expect((try direct.next()) == null);
}

test "authenticated container source remains borrowed through traversal" {
    const a = try rel.Rank(.sense).fromIndex(0);
    const b = try rel.Rank(.sense).fromIndex(1);
    const claims = [_]rel.EdgeInput{try rel.typedEdge(.entails, .sense, .sense, a, b, .{})};
    var owned = try rel.build(std.testing.allocator, .{ .edges = &claims }, .{});
    defer owned.deinit();

    const snapshot = try container.build(std.testing.allocator, [_]u8{0} ** container.digest_size, &.{
        .{ .tag = .relations, .bytes = owned.bytes },
    });
    defer std.testing.allocator.free(snapshot);
    var trust = [_]u64{0};
    var mapped = try container.Container.open(snapshot, &trust);
    const section = try mapped.find(.relations);
    const Borrowed = rel.ViewFor(container.Section);
    var view = try Borrowed.open(section);
    try std.testing.expect(!view.isVerified());
    try view.verify();

    var queue: [4]rel.Endpoint = undefined;
    var visited: [4]rel.Endpoint = undefined;
    var walk = try view.traverse(.entails, try rel.Endpoint.fromRank(.sense, a), &queue, &visited, .{});
    try std.testing.expect((try walk.next()) != null);
    try std.testing.expect((try walk.next()) == null);
}

test "explicit native claims survive canonical inverse and symmetric storage" {
    const form = try rel.Rank(.form).fromIndex(3);
    const entry = try rel.Rank(.entry).fromIndex(4);
    const sense_a = try rel.Rank(.sense).fromIndex(7);
    const sense_b = try rel.Rank(.sense).fromIndex(8);
    const inverse_claims = [_]rel.EdgeInput{
        try rel.typedEdge(.form_of, .form, .entry, form, entry, .{}),
        try rel.typedEdge(.has_form, .entry, .form, entry, form, .{}),
    };
    var inverse_owned = try rel.build(std.testing.allocator, .{ .edges = &inverse_claims }, .{});
    defer inverse_owned.deinit();
    try std.testing.expectEqual(@as(usize, 1), inverse_owned.view.physicalEdgeCount());
    const form_endpoint = try rel.Endpoint.fromRank(.form, form);
    const entry_endpoint = try rel.Endpoint.fromRank(.entry, entry);
    var form_arcs = try inverse_owned.view.relationsExplicit(form_endpoint, .form_of);
    try std.testing.expect((try form_arcs.next()).?.explicit);
    try std.testing.expect((try form_arcs.next()) == null);
    var entry_arcs = try inverse_owned.view.relationsExplicit(entry_endpoint, .has_form);
    try std.testing.expect((try entry_arcs.next()).?.explicit);
    try std.testing.expect((try entry_arcs.next()) == null);

    const symmetric_claims = [_]rel.EdgeInput{
        try rel.typedEdge(.see_also, .sense, .sense, sense_a, sense_b, .{}),
    };
    var symmetric_owned = try rel.build(std.testing.allocator, .{ .edges = &symmetric_claims }, .{});
    defer symmetric_owned.deinit();
    var inferred = try symmetric_owned.view.relations(
        try rel.Endpoint.fromRank(.sense, sense_b),
        .see_also,
    );
    try std.testing.expect(!(try inferred.next()).?.explicit);
    var filtered = try symmetric_owned.view.relationsExplicit(
        try rel.Endpoint.fromRank(.sense, sense_b),
        .see_also,
    );
    try std.testing.expect((try filtered.next()) == null);
}

test "generated graph tables beat the fixed-layout ablation on repeated memberships" {
    const group = try rel.Rank(.concept).fromIndex(0);
    var memberships: [64]rel.MembershipInput = undefined;
    for (&memberships, 0..) |*membership, index| {
        const sense = try rel.Rank(.sense).fromIndex(index);
        membership.* = try rel.typedMembership(.concept, .sense, group, sense, @enumFromInt(1), .certain, null);
    }
    var owned = try rel.build(std.testing.allocator, .{ .memberships = &memberships }, .{});
    defer owned.deinit();
    const fixed = try rel.rawFixedLayoutSize(0, 0, owned.view.membershipCount(), owned.view.membershipArcCount());
    try std.testing.expect(owned.bytes.len < fixed);
}
