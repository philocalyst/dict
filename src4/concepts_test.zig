const std = @import("std");
const concepts = @import("concepts.zig");
const container = @import("container.zig");

const Sense = concepts.SenseRank;

fn rank(value: usize) Sense {
    return @enumFromInt(@as(u32, @intCast(value)));
}

test "randomized concept membership differential preserves both projections" {
    const Record = concepts.ConceptMembership;
    var prng = std.Random.DefaultPrng.init(0x4c455834_636f6e63);
    const random = prng.random();
    var records: [64]Record = undefined;
    var expected_concept: [64]?usize = [_]?usize{null} ** 64;
    var expected_confidence: [64]?concepts.Confidence = [_]?concepts.Confidence{null} ** 64;

    var iteration: usize = 0;
    while (iteration < 40) : (iteration += 1) {
        const sense_count = 1 + random.uintLessThan(usize, 64);
        const concept_count = random.uintLessThan(usize, 9);
        var record_count: usize = 0;
        expected_concept = [_]?usize{null} ** 64;
        expected_confidence = [_]?concepts.Confidence{null} ** 64;
        for (0..sense_count) |sense| {
            if (concept_count == 0 or !random.boolean()) continue;
            const concept = random.uintLessThan(usize, concept_count);
            const confidence: ?concepts.Confidence = if (random.boolean())
                @enumFromInt(@as(u2, @intCast(random.uintLessThan(usize, 4))))
            else
                null;
            records[record_count] = .{
                .sense = rank(sense),
                .concept = @enumFromInt(@as(u32, @intCast(concept))),
                .confidence = confidence,
            };
            record_count += 1;
            expected_concept[sense] = concept;
            expected_confidence[sense] = confidence;
        }

        // Reverse ordering is intentionally unrelated to the input order.
        var shuffled: [64]Record = undefined;
        for (records[0..record_count], 0..) |record, index| shuffled[index] = record;
        var index = record_count;
        while (index > 1) : (index -= 1) {
            const swap_index = random.uintLessThan(usize, index);
            std.mem.swap(Record, &shuffled[index - 1], &shuffled[swap_index]);
        }

        var owned = try concepts.build(.concept, std.testing.allocator, sense_count, concept_count, shuffled[0..record_count]);
        defer owned.deinit();
        var view = try owned.view();
        for (0..sense_count) |sense| {
            const got = try view.conceptOf(rank(sense));
            if (expected_concept[sense]) |expected| {
                try std.testing.expectEqual(expected, @as(usize, @intFromEnum(got.?)));
                try std.testing.expectEqual(expected_confidence[sense], try view.confidence(rank(sense)));
            } else {
                try std.testing.expect(got == null);
                try std.testing.expectEqual(@as(?concepts.Confidence, null), try view.confidence(rank(sense)));
            }
        }
        for (0..concept_count) |concept| {
            var expected_members: [64]usize = undefined;
            var expected_len: usize = 0;
            for (0..sense_count) |sense| {
                if (expected_concept[sense] == concept) {
                    expected_members[expected_len] = sense;
                    expected_len += 1;
                }
            }
            var members = try view.members(@enumFromInt(@as(u32, @intCast(concept))));
            for (expected_members[0..expected_len]) |expected| {
                try std.testing.expectEqual(expected, @as(usize, @intFromEnum((try members.next()).?)));
            }
            try std.testing.expect((try members.next()) == null);
        }
    }
}

test "interlingual differential applies borrowed language filtering" {
    const Record = concepts.InterlingualMembership;
    const records = [_]Record{
        .{ .sense = rank(0), .concept = @enumFromInt(0) },
        .{ .sense = rank(1), .concept = @enumFromInt(0) },
        .{ .sense = rank(2), .concept = @enumFromInt(0) },
        .{ .sense = rank(3), .concept = @enumFromInt(0) },
        .{ .sense = rank(4), .concept = @enumFromInt(1) },
    };
    var owned = try concepts.build(.interlingual, std.testing.allocator, 6, 2, &records);
    defer owned.deinit();
    var view = try owned.view();
    const languages = [_]concepts.LanguageTag{
        .{ .language = 1 }, .{ .language = 2 }, .{ .language = 3 },
        .{ .language = 2 }, .{ .language = 2 }, .{ .language = 1 },
    };
    var iterator = try view.translations(rank(0), .{ .language = 2 }, &languages);
    try std.testing.expectEqual(@as(usize, 1), @intFromEnum((try iterator.next()).?));
    try std.testing.expectEqual(@as(usize, 3), @intFromEnum((try iterator.next()).?));
    try std.testing.expect((try iterator.next()) == null);
}

test "empty, unassigned, and large clusters remain compact" {
    const empty = [_]concepts.ConceptMembership{};
    var no_domain = try concepts.build(.concept, std.testing.allocator, 0, 0, &empty);
    defer no_domain.deinit();
    var no_domain_view = try no_domain.view();
    try std.testing.expectEqual(@as(usize, 0), no_domain_view.senseCount());
    try std.testing.expectEqual(@as(usize, 0), no_domain_view.conceptCount());

    var unassigned = try concepts.build(.concept, std.testing.allocator, 4096, 1, &empty);
    defer unassigned.deinit();
    var unassigned_view = try unassigned.view();
    try std.testing.expect((try unassigned_view.conceptOf(rank(4095))) == null);

    var records: [1024]concepts.ConceptMembership = undefined;
    for (&records, 0..) |*record, index| record.* = .{ .sense = rank(index), .concept = @enumFromInt(0) };
    for ([_]usize{ 0, 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024 }) |member_count| {
        // Pairwise baseline charges the same complete edge envelope: one
        // 32-byte physical claim plus one 16-byte adjacency record per
        // directed edge.  The membership length below includes every nested
        // bitvector header, directory, and payload byte.
        const baseline_at_k = try concepts.pairwiseBaseline(member_count, 112, 48);
        const expected_edges = if (member_count < 2) 0 else member_count * (member_count - 1);
        try std.testing.expectEqual(expected_edges, baseline_at_k.directed_edge_count);
        if (member_count >= 8) {
            var measured = try concepts.build(.concept, std.testing.allocator, member_count, 1, records[0..member_count]);
            defer measured.deinit();
            try std.testing.expect(measured.bytes.len < baseline_at_k.total_bytes);
            if (member_count >= 16)
                try std.testing.expect(measured.bytes.len * member_count <= baseline_at_k.total_bytes);
        }
    }
    var large = try concepts.build(.concept, std.testing.allocator, records.len, 1, &records);
    defer large.deinit();
    var large_view = try large.view();
    try std.testing.expectEqual(records.len, (try large_view.range(@enumFromInt(0))).len());
    try std.testing.expectEqual(@as(usize, 777), @intFromEnum(try large_view.select(@enumFromInt(0), 777)));

    const baseline = try concepts.pairwiseBaseline(records.len, 112, 48);
    try std.testing.expectEqual(records.len * (records.len - 1), baseline.directed_edge_count);
    // The ratio comparison includes both format envelopes; it does not use
    // the misleading payload-only k(k-1) denominator.
    try std.testing.expect(large.bytes.len < baseline.total_bytes);
}

test "open is lazy for an authenticated-style borrowed source" {
    const records = [_]concepts.ConceptMembership{
        .{ .sense = rank(0), .concept = @enumFromInt(0) },
        .{ .sense = rank(7), .concept = @enumFromInt(0) },
    };
    var owned = try concepts.build(.concept, std.testing.allocator, 8192, 1, &records);
    defer owned.deinit();

    const CountingSource = struct {
        bytes_: []const u8,
        read_bytes: *usize,

        pub fn len(self: *const @This()) usize {
            return self.bytes_.len;
        }

        pub fn bytes(self: *@This(), offset: usize, length: usize) ![]const u8 {
            if (offset > self.bytes_.len or length > self.bytes_.len - offset) return error.Truncated;
            self.read_bytes.* += length;
            return self.bytes_[offset..][0..length];
        }
    };

    var read_bytes: usize = 0;
    const source = CountingSource{ .bytes_ = owned.bytes, .read_bytes = &read_bytes };
    var view = try concepts.SourceViewFor(.concept, CountingSource).open(source);
    try std.testing.expect(!view.isVerified());
    const opened_bytes = read_bytes;
    try std.testing.expect(opened_bytes < owned.bytes.len);
    try view.verify();
    try std.testing.expect(view.isVerified());
    try std.testing.expect(read_bytes >= opened_bytes + owned.bytes.len);
    try std.testing.expectEqual(@as(usize, 0), @intFromEnum((try view.conceptOf(rank(0))).?));
}

test "malformed headers and limits fail checked, without indexing payload" {
    const records = [_]concepts.ConceptMembership{
        .{ .sense = rank(0), .concept = @enumFromInt(0) },
    };
    var owned = try concepts.build(.concept, std.testing.allocator, 4, 1, &records);
    defer owned.deinit();

    var bad_total = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_total);
    std.mem.writeInt(u64, bad_total[128..136], std.math.maxInt(u64), .little);
    try std.testing.expectError(error.InvalidEncoding, concepts.open(.concept, bad_total));

    var bad_section = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_section);
    std.mem.writeInt(u64, bad_section[48..56], std.math.maxInt(u64), .little);
    try std.testing.expectError(error.InvalidEncoding, concepts.open(.concept, bad_section));

    try std.testing.expectError(error.LimitExceeded, concepts.openWithLimits(.concept, owned.bytes, .{ .max_bytes = owned.bytes.len - 1 }));
    try std.testing.expectError(error.LimitExceeded, concepts.openWithLimits(.concept, owned.bytes, .{ .max_senses = 0 }));
}

test "authenticated container source reports integrity before packed reads" {
    const records = [_]concepts.ConceptMembership{
        .{ .sense = rank(0), .concept = @enumFromInt(0) },
    };
    var membership = try concepts.build(.concept, std.testing.allocator, 4, 1, &records);
    defer membership.deinit();
    const snapshot = try container.build(std.testing.allocator, [_]u8{0} ** container.digest_size, &.{
        .{ .tag = .columns, .bytes = membership.bytes },
    });
    defer std.testing.allocator.free(snapshot);
    var trust = [_]u64{0};
    var mapped = try container.Container.open(snapshot, &trust);
    const section = try mapped.find(.columns);
    var view = try concepts.SourceViewFor(.concept, container.Section).open(section);
    try view.verify();
    try std.testing.expectEqual(@as(usize, 0), @intFromEnum((try view.conceptOf(rank(0))).?));
}
