const std = @import("std");
const terms = @import("terms.zig");
const container = @import("container.zig");

fn rank(value: u32) terms.EntryRank {
    return @enumFromInt(value);
}

fn buildFixture(allocator: std.mem.Allocator, options: terms.Options) !terms.Owned {
    var builder = terms.Builder.withOptions(allocator, 100, options);
    defer builder.deinit();
    var all: [100]terms.EntryRank = undefined;
    for (&all, 0..) |*item, index| item.* = rank(@intCast(index));
    try builder.add("all", &all);
    try builder.add("alternating", &[_]terms.EntryRank{ rank(0), rank(2), rank(4), rank(6), rank(8), rank(10), rank(12), rank(14), rank(16), rank(18), rank(20), rank(22), rank(24), rank(26), rank(28), rank(30), rank(32), rank(34), rank(36), rank(38), rank(40), rank(42), rank(44), rank(46), rank(48), rank(50), rank(52), rank(54), rank(56), rank(58), rank(60), rank(62), rank(64), rank(66), rank(68), rank(70), rank(72), rank(74), rank(76), rank(78), rank(80), rank(82), rank(84), rank(86), rank(88), rank(90), rank(92), rank(94), rank(96), rank(98) });
    try builder.add("sparse", &[_]terms.EntryRank{ rank(1), rank(17), rank(99) });
    try builder.add("tiny", &[_]terms.EntryRank{rank(7)});
    return builder.finish();
}

test "empty and duplicate term indexes fail explicitly" {
    var empty = terms.Builder.init(std.testing.allocator, 4);
    defer empty.deinit();
    try std.testing.expectError(error.InvalidDirectory, empty.finish());

    var duplicate = terms.Builder.init(std.testing.allocator, 4);
    defer duplicate.deinit();
    try duplicate.add("same", &[_]terms.EntryRank{rank(0)});
    try duplicate.add("same", &[_]terms.EntryRank{rank(1)});
    try std.testing.expectError(error.DuplicateTerm, duplicate.finish());
}

test "adaptive postings are exact and allocation-free to query" {
    var owned = try buildFixture(std.testing.allocator, .{});
    defer owned.deinit();
    const view = try terms.View.open(owned.bytes);
    try view.verify(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 100), view.entry_count);
    try std.testing.expectEqual(@as(u32, 4), view.term_count);

    const all = (try view.exact("all")).?;
    try std.testing.expectEqual(@as(u32, 100), all.postings.len());
    try std.testing.expectEqual(terms.PostingCodec.runs, all.postings.codec());
    try std.testing.expect(try all.postings.contains(rank(99)));
    try std.testing.expect(!(try all.postings.contains(rank(100))));
    var all_it = all.postings.iterator();
    for (0..100) |expected| try std.testing.expectEqual(@as(u32, @intCast(expected)), @intFromEnum((try all_it.next()).?));
    try std.testing.expect((try all_it.next()) == null);

    const sparse = (try view.exact("sparse")).?;
    try std.testing.expectEqual(terms.PostingCodec.gaps, sparse.postings.codec());
    try std.testing.expect(try sparse.postings.contains(rank(17)));
    try std.testing.expect(!(try sparse.postings.contains(rank(18))));
    var sparse_it = sparse.postings.iterator();
    for ([_]u32{ 1, 17, 99 }) |expected| try std.testing.expectEqual(expected, @intFromEnum((try sparse_it.next()).?));
    try std.testing.expect((try sparse_it.next()) == null);
    try std.testing.expectEqual(terms.PostingCodec.bitmap, (try view.exact("alternating")).?.postings.codec());

    const interval = (try view.prefix("a")).?;
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(interval.lo));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(interval.hi));
    var scratch: [32]u8 = undefined;
    try std.testing.expectEqualStrings("sparse", (try view.term(@enumFromInt(2), &scratch)).?);
}

test "term insertion order is canonical and cold codec claims stay honest" {
    var first = terms.Builder.init(std.testing.allocator, 32);
    defer first.deinit();
    try first.add("zeta", &[_]terms.EntryRank{rank(3)});
    try first.add("alpha", &[_]terms.EntryRank{rank(0)});
    var first_owned = try first.finish();
    defer first_owned.deinit();

    var second = terms.Builder.init(std.testing.allocator, 32);
    defer second.deinit();
    try second.add("alpha", &[_]terms.EntryRank{rank(0)});
    try second.add("zeta", &[_]terms.EntryRank{rank(3)});
    var second_owned = try second.finish();
    defer second_owned.deinit();
    try std.testing.expectEqualSlices(u8, first_owned.bytes, second_owned.bytes);
    const view = try terms.View.open(first_owned.bytes);
    const availability = view.codecAvailability();
    try std.testing.expectEqual(terms.Codec.raw, availability.requested);
    try std.testing.expectEqual(terms.CodecState.raw, availability.state);

    var unavailable = terms.Builder.withOptions(std.testing.allocator, 32, .{ .requested_cold_codec = .bzip3 });
    defer unavailable.deinit();
    try unavailable.add("alpha", &[_]terms.EntryRank{rank(0)});
    try std.testing.expectError(error.CodecUnavailable, unavailable.finish());
}

test "singleton rank deltas are selected only when the complete stream wins" {
    var builder = terms.Builder.init(std.testing.allocator, 1024);
    defer builder.deinit();
    try builder.add("a", &[_]terms.EntryRank{rank(0)});
    try builder.add("b", &[_]terms.EntryRank{rank(1000)});
    try builder.add("c", &[_]terms.EntryRank{rank(1001)});
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try terms.View.open(owned.bytes);
    try view.verify(std.testing.allocator);
    for ([_][]const u8{ "a", "b", "c" }, [_]u32{ 0, 1000, 1001 }) |key, expected| {
        const hit = (try view.exact(key)).?;
        try std.testing.expectEqual(terms.PostingCodec.signed_single, hit.postings.codec());
        try std.testing.expect(try hit.postings.contains(rank(expected)));
    }
}

test "Elias-Fano is selected by complete serialized bytes and round-trips" {
    var builder = terms.Builder.init(std.testing.allocator, 4096);
    defer builder.deinit();
    var postings: [128]terms.EntryRank = undefined;
    for (&postings, 0..) |*item, index| item.* = rank(@intCast(index * 32));
    try builder.add("ef", &postings);
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try terms.View.open(owned.bytes);
    try view.verify(std.testing.allocator);
    const hit = (try view.exact("ef")).?;
    try std.testing.expectEqual(terms.PostingCodec.ef, hit.postings.codec());
    try std.testing.expect(try hit.postings.contains(rank(0)));
    try std.testing.expect(try hit.postings.contains(rank(4064)));
    try std.testing.expect(!(try hit.postings.contains(rank(4065))));
    var iterator = hit.postings.iterator();
    for (&postings) |expected| try std.testing.expectEqual(expected, (try iterator.next()).?);
    try std.testing.expect((try iterator.next()) == null);

    var corrupt = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(corrupt);
    const payload = std.mem.readInt(u32, corrupt[32..36], .little);
    const payload_len = std.mem.readInt(u32, corrupt[36..40], .little);
    corrupt[payload + payload_len - 1] |= 0x80;
    try std.testing.expectError(error.InvalidContainer, (try terms.View.open(corrupt)).verify(std.testing.allocator));
}

test "adaptive posting iterator differentially round-trips pseudo-random ranks" {
    var raw: [257]u32 = undefined;
    for (&raw, 0..) |*value, index| value.* = @intCast((index * 7919) % 10_000);
    std.mem.sort(u32, &raw, {}, std.sort.asc(u32));
    var postings: [257]terms.EntryRank = undefined;
    for (&postings, 0..) |*value, index| value.* = rank(raw[index]);

    var builder = terms.Builder.init(std.testing.allocator, 10_000);
    defer builder.deinit();
    try builder.add("random", &postings);
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try terms.View.open(owned.bytes);
    try view.verify(std.testing.allocator);
    const hit = (try view.exact("random")).?;
    var iterator = hit.postings.iterator();
    for (postings) |expected| try std.testing.expectEqual(expected, (try iterator.next()).?);
    try std.testing.expect((try iterator.next()) == null);
}

test "malformed directory and postings are rejected by verify" {
    var owned = try buildFixture(std.testing.allocator, .{});
    defer owned.deinit();
    var bytes = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bytes);
    const view = try terms.View.open(bytes);
    // The first checkpoint's metadata cursor must agree with the stream.
    const directory = std.mem.readInt(u32, bytes[24..28], .little);
    std.mem.writeInt(u32, bytes[directory + 4 ..][0..4], std.math.maxInt(u32), .little);
    const malformed = try terms.View.open(bytes);
    try std.testing.expectError(error.InvalidDirectory, malformed.verify(std.testing.allocator));
    _ = view;

    var corrupt = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(corrupt);
    const payload = std.mem.readInt(u32, corrupt[32..36], .little);
    corrupt[payload] = 0x80;
    const corrupt_view = try terms.View.open(corrupt);
    try std.testing.expectError(error.InvalidContainer, corrupt_view.verify(std.testing.allocator));
}

test "source adapter is the authenticated read boundary" {
    var owned = try buildFixture(std.testing.allocator, .{});
    defer owned.deinit();
    const source = terms.SliceSource{ .data = owned.bytes };
    var checked = try terms.openSource(terms.SliceSource, source);
    try checked.verify(std.testing.allocator);
    try std.testing.expect(try (try checked.exact("tiny")).?.postings.contains(rank(7)));

    const wrapped = try container.build(std.testing.allocator, [_]u8{0} ** container.digest_size, &.{.{ .tag = .cold, .bytes = owned.bytes }});
    defer std.testing.allocator.free(wrapped);
    var trust = [_]u64{0};
    var snapshot = try container.Container.open(wrapped, &trust);
    var authenticated = try terms.openSource(container.SectionSource, .{ .section = try snapshot.find(.cold) });
    try authenticated.verify(std.testing.allocator);
    try std.testing.expect((try authenticated.exact("tiny")) != null);

    var corrupted = try std.testing.allocator.dupe(u8, wrapped);
    defer std.testing.allocator.free(corrupted);
    var corrupt_container = try container.Container.open(corrupted, &.{});
    const corrupt_section = try corrupt_container.find(.cold);
    corrupted[@as(usize, @intCast(corrupt_section.descriptor.offset)) + 64] ^= 1;
    var corrupt_container_after = try container.Container.open(corrupted, &.{});
    try std.testing.expectError(error.IntegrityFailure, terms.openSource(container.SectionSource, .{ .section = try corrupt_container_after.find(.cold) }));
}

test "term source open and exact touch only bounded ranges" {
    var owned = try buildFixture(std.testing.allocator, .{});
    defer owned.deinit();
    const Counting = struct {
        data: []const u8,
        calls: *usize,
        largest: *usize,

        pub fn len(self: *const @This()) usize {
            return self.data.len;
        }
        pub fn bytes(self: *const @This(), offset: usize, length: usize) ![]const u8 {
            if (offset > self.data.len or length > self.data.len - offset) return error.Truncated;
            self.calls.* += 1;
            self.largest.* = @max(self.largest.*, length);
            return self.data[offset..][0..length];
        }
    };
    var calls: usize = 0;
    var largest: usize = 0;
    const source = Counting{ .data = owned.bytes, .calls = &calls, .largest = &largest };
    const checked = try terms.openSource(Counting, source);
    try std.testing.expectEqual(@as(usize, 2), calls); // terms and dictionary envelopes
    try std.testing.expect(largest < owned.bytes.len);
    const hit = (try checked.exact("tiny")).?;
    try std.testing.expect(try hit.postings.contains(rank(7)));
    try std.testing.expect(calls > 2);
    try std.testing.expect(largest < owned.bytes.len);
}

test "builder validates posting identity and allocation failures" {
    var builder = terms.Builder.init(std.testing.allocator, 4);
    defer builder.deinit();
    try std.testing.expectError(error.InvalidPostingOrder, builder.add("x", &[_]terms.EntryRank{ rank(2), rank(1) }));
    try std.testing.expectError(error.PostingOutOfRange, builder.add("x", &[_]terms.EntryRank{rank(4)}));
    try std.testing.expectError(error.EmptyTerm, builder.add("", &[_]terms.EntryRank{rank(1)}));

    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var local = terms.Builder.init(allocator, 8);
            defer local.deinit();
            try local.add("a", &[_]terms.EntryRank{ rank(0), rank(2), rank(7) });
            var owned = try local.finish();
            owned.deinit();
        }
    }.run, .{});
}

test "2048-term ledger and exact latency ablation" {
    var builder = terms.Builder.init(std.testing.allocator, 2048);
    defer builder.deinit();
    var term_buf: [32]u8 = undefined;
    for (0..2048) |index| {
        const term = try std.fmt.bufPrint(&term_buf, "term-{d:0>4}", .{index});
        try builder.add(term, &[_]terms.EntryRank{rank(@intCast(index))});
    }
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try terms.View.open(owned.bytes);
    try view.verify(std.testing.allocator);
    const ledger = view.ledger();
    const repetitions: usize = 10_000;
    var sink: u32 = 0;
    const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    for (0..repetitions) |iteration| {
        const query = try std.fmt.bufPrint(&term_buf, "term-{d:0>4}", .{iteration % 2048});
        const hit = (try view.exact(query)).?;
        var iterator = hit.postings.iterator();
        sink ^= @intFromEnum((try iterator.next()).?);
    }
    const elapsed = @as(u64, @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds - start));
    std.mem.doNotOptimizeAway(sink);
    std.debug.print("LEX4_TERMS entries={} terms={} bytes={} header={} dictionary={} checkpoint={} metadata={} payload={} exact_ns_op={} sink={}\n", .{ view.entry_count, view.term_count, ledger.total, ledger.header, ledger.dictionary, ledger.checkpoint, ledger.metadata, ledger.payload, elapsed / repetitions, sink });
    const accounted = ledger.header + ledger.dictionary + ledger.checkpoint + ledger.metadata + ledger.payload;
    try std.testing.expect(ledger.total >= accounted);
}
