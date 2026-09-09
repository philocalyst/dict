const std = @import("std");
const axes = @import("axes.zig");
const automaton = @import("automaton.zig");
const container = @import("container.zig");

fn rank(value: axes.EntryRank) u32 {
    return @intFromEnum(value);
}

fn buildReverse(allocator: std.mem.Allocator) !axes.Owned {
    var builder = axes.AxisBuilder(axes.Reverse).init(allocator);
    defer builder.deinit();
    _ = try builder.addEntry("cat", 2);
    _ = try builder.addEntry("dog", 1);
    try builder.addForm("cats", &[_]axes.EntryRank{ @enumFromInt(0), @enumFromInt(1) });
    return builder.finish();
}

test "empty duplicate and malformed axis inputs fail explicitly" {
    var empty = axes.AxisBuilder(axes.Reverse).init(std.testing.allocator);
    defer empty.deinit();
    try std.testing.expectError(error.EmptyInput, empty.finish());

    var duplicate = axes.AxisBuilder(axes.Reverse).init(std.testing.allocator);
    defer duplicate.deinit();
    _ = try duplicate.addEntry("same", 1);
    try std.testing.expectError(error.DuplicateKey, duplicate.addEntry("same", 1));

    var malformed = axes.AxisBuilder(axes.Reverse).init(std.testing.allocator);
    defer malformed.deinit();
    try std.testing.expectError(error.InvalidUtf8, malformed.addEntry("bad\xff", 1));
}

test "reversed axis is a typed, allocation-free suffix index" {
    var owned = try buildReverse(std.testing.allocator);
    defer owned.deinit();
    const view = try axes.ViewFor(axes.Reverse).open(owned.bytes);
    try view.verify(std.testing.allocator);
    var transform: [32]u8 = undefined;
    var key: [32]u8 = undefined;
    var frames: [32]automaton.Frame = undefined;
    const index = axes.Index(axes.Reverse).init(view);
    const exact = (try index.exact("cats", &transform)).?.targets;
    try std.testing.expectEqual(@as(u32, 2), exact.len());
    try std.testing.expectEqual(@as(u32, 0), rank(try exact.target(0)));
    try std.testing.expectEqual(@as(u32, 1), rank(try exact.target(1)));

    var iterator = try index.suffix("at", &transform, &key, &frames);
    var seen: usize = 0;
    while (try iterator.next()) |item| {
        try std.testing.expectEqualStrings("cat", item.key);
        try std.testing.expectEqual(@as(u32, 2), item.targets.len());
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), seen);
}

test "Unicode suffix restores scalar boundaries" {
    var builder = axes.AxisBuilder(axes.Reverse).init(std.testing.allocator);
    defer builder.deinit();
    _ = try builder.addEntry("café", 1);
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try axes.ViewFor(axes.Reverse).open(owned.bytes);
    var transform: [32]u8 = undefined;
    var key: [32]u8 = undefined;
    var frames: [32]automaton.Frame = undefined;
    var iterator = try axes.Index(axes.Reverse).init(view).suffix("fé", &transform, &key, &frames);
    const item = (try iterator.next()).?;
    try std.testing.expectEqualStrings("café", item.key);
    try std.testing.expect((try iterator.next()) == null);
}

test "unique iterator deduplicates one entry reached through two axis keys" {
    var builder = axes.AxisBuilder(axes.Reverse).init(std.testing.allocator);
    defer builder.deinit();
    _ = try builder.addEntry("cat", 1);
    try builder.addForm("act", &[_]axes.EntryRank{@enumFromInt(0)});
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try axes.ViewFor(axes.Reverse).open(owned.bytes);
    var key: [16]u8 = undefined;
    var frames: [16]automaton.Frame = undefined;
    const iterator = try view.prefix("", &key, &frames);
    var seen: [1]u64 = .{0};
    var unique = try axes.UniqueIterator(axes.Reverse).init(iterator, &seen);
    var count: usize = 0;
    while (try unique.next()) |value| {
        try std.testing.expectEqual(@as(u32, 0), rank(value));
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "axis output groups dedup targets and keep phonetic collisions separate" {
    var builder = axes.AxisBuilder(axes.Phonetic).init(std.testing.allocator);
    defer builder.deinit();
    _ = try builder.addEntry("Robert", 1);
    _ = try builder.addEntry("Rupert", 1);
    try builder.addForm("robert", &[_]axes.EntryRank{ @enumFromInt(0), @enumFromInt(0), @enumFromInt(1) });
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try axes.ViewFor(axes.Phonetic).open(owned.bytes);
    try view.verify(std.testing.allocator);
    var scratch: [16]u8 = undefined;
    const hit = (try axes.Index(axes.Phonetic).init(view).exact("ROBERT", &scratch)).?.targets;
    try std.testing.expectEqual(@as(u32, 2), hit.len());
    try std.testing.expectEqual(@as(u32, 0), rank(try hit.target(0)));
    try std.testing.expectEqual(@as(u32, 1), rank(try hit.target(1)));
}

test "packed permutation mode preserves homograph boundaries through raw and source views" {
    var builder = axes.AxisBuilder(axes.Reverse).init(std.testing.allocator);
    defer builder.deinit();
    _ = try builder.addEntry("cat", 2);
    _ = try builder.addEntry("dog", 1);
    var owned = try builder.finish();
    defer owned.deinit();

    const view = try axes.ViewFor(axes.Reverse).open(owned.bytes);
    try std.testing.expectEqual(@as(u8, 3), view.ledger().mode);
    try view.verify(std.testing.allocator);
    const raw = (try view.exact("tac")).?.targets;
    try std.testing.expectEqual(@as(u32, 2), raw.len());
    try std.testing.expectEqual(@as(u32, 0), rank(try raw.target(0)));
    try std.testing.expectEqual(@as(u32, 1), rank(try raw.target(1)));

    const Source = struct {
        data: []const u8,
        pub fn len(self: @This()) usize {
            return self.data.len;
        }
        pub fn bytes(self: @This(), offset: usize, length: usize) ![]const u8 {
            if (offset > self.data.len or length > self.data.len - offset) return error.Truncated;
            return self.data[offset..][0..length];
        }
    };
    const source_view = try axes.openSource(axes.Reverse, Source, .{ .data = owned.bytes });
    try source_view.verifyWithAllocator(std.testing.allocator);
    const sourced = (try source_view.exact("tac")).?.targets;
    try std.testing.expectEqual(@as(u32, 2), sourced.len());
    try std.testing.expectEqual(@as(u32, 0), rank(try sourced.target(0)));
    try std.testing.expectEqual(@as(u32, 1), rank(try sourced.target(1)));

    const index_off = std.mem.readInt(u32, owned.bytes[24..28], .little);
    const index_len = std.mem.readInt(u32, owned.bytes[28..32], .little);
    const payload_off = std.mem.readInt(u32, owned.bytes[32..36], .little);
    try std.testing.expect(index_len >= 5);

    var bad_directory = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_directory);
    // The second cumulative boundary checkpoint must equal the number of
    // groups.  Corrupting it must not merely shift a later query boundary.
    bad_directory[index_off + 3] +%= 1;
    const bad_directory_view = try axes.ViewFor(axes.Reverse).open(bad_directory);
    try std.testing.expectError(error.InvalidOutput, bad_directory_view.verify(std.testing.allocator));

    var bad_tail = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_tail);
    // Three two-bit ranks occupy six bits; canonical padding is zero.
    bad_tail[payload_off] |= 0b1100_0000;
    const bad_tail_view = try axes.ViewFor(axes.Reverse).open(bad_tail);
    try std.testing.expectError(error.InvalidOutput, bad_tail_view.verify(std.testing.allocator));

    var duplicate_target = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(duplicate_target);
    // Replace the third rank with the second.  Local ordering alone cannot
    // prove a permutation, so full verification must reject the duplicate.
    const second_target = (duplicate_target[payload_off] >> 2) & 0b11;
    duplicate_target[payload_off] = (duplicate_target[payload_off] & 0b1100_1111) | (second_target << 4);
    const duplicate_view = try axes.ViewFor(axes.Reverse).open(duplicate_target);
    try std.testing.expectError(error.InvalidTarget, duplicate_view.verify(std.testing.allocator));
}

test "normalized overlay elides identity axes" {
    var builder = axes.AxisBuilder(axes.Normalized).init(std.testing.allocator);
    defer builder.deinit();
    _ = try builder.addEntry("cat", 1);
    _ = try builder.addEntry("dog", 1);
    const result = try builder.finishOverlay();
    var overlay = result;
    defer overlay.deinit();
    try std.testing.expect(switch (overlay) {
        .identity => true,
        .materialized => false,
    });
}

test "normalized overlay materializes only when needed" {
    var builder = axes.AxisBuilder(axes.Normalized).init(std.testing.allocator);
    defer builder.deinit();
    _ = try builder.addEntry("Cat", 1);
    const result = try builder.finishOverlay();
    var overlay = result;
    defer overlay.deinit();
    switch (overlay) {
        .identity => return error.TestUnexpectedResult,
        .materialized => |*owned| {
            const view = try axes.ViewFor(axes.Normalized).open(owned.bytes);
            var scratch: [8]u8 = undefined;
            const hit = (try axes.Index(axes.Normalized).init(view).exact("CAT", &scratch)).?.targets;
            try std.testing.expectEqual(@as(u32, 1), hit.len());
        },
    }
}

test "source adapter accepts authenticated-style read source" {
    var owned = try buildReverse(std.testing.allocator);
    defer owned.deinit();
    const ReadSource = struct {
        data: []const u8,
        pub fn len(self: @This()) usize {
            return self.data.len;
        }
        pub fn read(self: @This(), offset: usize, length: usize) ![]const u8 {
            const end = try std.math.add(usize, offset, length);
            if (end > self.data.len) return error.Truncated;
            return self.data[offset..end];
        }
    };
    const checked = try axes.openSource(axes.Reverse, ReadSource, .{ .data = owned.bytes });
    try checked.verify();
}

test "axis source open and exact stay range-lazy" {
    var owned = try buildReverse(std.testing.allocator);
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
    const checked = try axes.openSource(axes.Reverse, Counting, source);
    try std.testing.expect(calls <= 2); // axis and inner envelopes only
    try std.testing.expect(largest < owned.bytes.len);
    const hit = (try checked.exact("tac")).?;
    try std.testing.expectEqual(@as(u32, 2), hit.targets.len());
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(try hit.targets.target(0)));
    try std.testing.expect(calls > 2);
    try std.testing.expect(largest < owned.bytes.len);
}

test "source and slice readers share missing-prefix and automaton-summary laws" {
    var owned = try buildReverse(std.testing.allocator);
    defer owned.deinit();
    const source = automaton.SliceSource{ .data = owned.bytes };
    const checked = try axes.openSource(axes.Reverse, automaton.SliceSource, source);
    var key: [16]u8 = undefined;
    var frames: [16]automaton.Frame = undefined;
    var missing = try checked.prefix("absent", &key, &frames);
    try std.testing.expect((try missing.next()) == null);

    const damaged = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(damaged);
    const inner = std.mem.readInt(u32, damaged[16..20], .little);
    const accepted_at = @as(usize, inner) + 16;
    std.mem.writeInt(u32, damaged[accepted_at..][0..4], std.mem.readInt(u32, damaged[accepted_at..][0..4], .little) + 1, .little);
    try std.testing.expectError(error.InvalidFormat, axes.ViewFor(axes.Reverse).open(damaged));
    try std.testing.expectError(error.InvalidFormat, axes.openSource(axes.Reverse, automaton.SliceSource, .{ .data = damaged }));
}

test "source singleton checkpoint target is range checked" {
    var builder = axes.AxisBuilder(axes.Normalized).init(std.testing.allocator);
    defer builder.deinit();
    var key: [16]u8 = undefined;
    for (0..65) |index| {
        const value = try std.fmt.bufPrint(&key, "k-{d:0>3}", .{index});
        _ = try builder.addEntry(value, 1);
    }
    try builder.addForm("extra", &.{@enumFromInt(0)});
    var owned = try builder.finish();
    defer owned.deinit();
    try std.testing.expectEqual(@as(u8, 2), owned.bytes[7] & 3);
    const index_at = std.mem.readInt(u32, owned.bytes[24..28], .little);
    std.mem.writeInt(u32, owned.bytes[@as(usize, index_at) + 8 ..][0..4], 65, .little);
    const source = try axes.openSource(axes.Normalized, automaton.SliceSource, .{ .data = owned.bytes });
    try std.testing.expectError(error.InvalidTarget, source.verify());
}

test "section source authenticates an axis before open" {
    var owned = try buildReverse(std.testing.allocator);
    defer owned.deinit();
    const wrapped = try container.build(std.testing.allocator, [_]u8{0} ** container.digest_size, &.{.{ .tag = .reversed, .bytes = owned.bytes }});
    defer std.testing.allocator.free(wrapped);
    var trust = [_]u64{0};
    var snapshot = try container.Container.open(wrapped, &trust);
    const section = try snapshot.find(.reversed);
    const source = container.SectionSource{ .section = section };
    const checked = try axes.openSource(axes.Reverse, container.SectionSource, source);
    try checked.verify();

    trust[0] = 0;
    wrapped[@intCast(section.descriptor.offset)] ^= 1;
    try std.testing.expectError(error.IntegrityFailure, axes.openSource(axes.Reverse, container.SectionSource, source));
}

test "malformed axis envelopes fail at open and graph corruption fails at verify" {
    var owned = try buildReverse(std.testing.allocator);
    defer owned.deinit();
    const truncated_error = axes.ViewFor(axes.Reverse).open(owned.bytes[0 .. owned.bytes.len - 1]);
    try std.testing.expect(truncated_error == error.Truncated or truncated_error == error.InvalidFormat);
    const bad = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad);
    std.mem.writeInt(u32, bad[12..16], 1, .little); // wrong key count/index width
    const view = axes.ViewFor(axes.Reverse).open(bad) catch |err| {
        try std.testing.expect(err == error.InvalidFormat or err == error.Truncated);
        return;
    };
    try std.testing.expectError(error.InvalidFormat, view.verify(std.testing.allocator));
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    var builder = axes.AxisBuilder(axes.Reverse).init(allocator);
    defer builder.deinit();
    _ = try builder.addEntry("alpha", 1);
    _ = try builder.addEntry("beta", 1);
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try axes.ViewFor(axes.Reverse).open(owned.bytes);
    try view.verify(allocator);
}

test "builder and verifier clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}

test "2048-entry axis ledger and output-directory ablation" {
    var builder = axes.AxisBuilder(axes.Reverse).init(std.testing.allocator);
    defer builder.deinit();
    var input: [64]u8 = undefined;
    for (0..2048) |i| {
        const key = try std.fmt.bufPrint(&input, "entry-{d:0>8}", .{i});
        _ = try builder.addEntry(key, 1);
    }
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try axes.ViewFor(axes.Reverse).open(owned.bytes);
    try view.verify(std.testing.allocator);
    const ledger = view.ledger();
    const generic_directory = @as(usize, view.key_count) * 2; // generic mode's u16 offsets
    const directory_savings = generic_directory - ledger.output_index;
    const index = axes.Index(axes.Reverse).init(view);
    var transform: [64]u8 = undefined;
    var key_scratch: [64]u8 = undefined;
    var frames: [64]automaton.Frame = undefined;
    var sink: u32 = 0;
    const repetitions: usize = 10_000;
    const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    for (0..repetitions) |i| {
        const query = try std.fmt.bufPrint(&input, "{d:0>4}", .{i % 2048});
        var iterator = index.suffix(query, &transform, &key_scratch, &frames) catch |err| {
            if (err == error.InvalidState) continue;
            return err;
        };
        if ((try iterator.next())) |item| sink ^= @intFromEnum((try item.targets.target(0)));
    }
    const elapsed = @as(u64, @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds - start));
    std.mem.doNotOptimizeAway(sink);
    std.debug.print("LEX4_AXIS_REVERSE entries={} keys={} bytes={} header={} index={} targets={} automaton={} mode={} suffix_ns_op={} sink={} ablation_generic_index={} savings={}\n", .{ view.entry_count, view.key_count, ledger.total, ledger.header, ledger.output_index, ledger.output_payload, ledger.automaton, ledger.mode, elapsed / repetitions, sink, generic_directory, directory_savings });
    try std.testing.expectEqual(ledger.total, ledger.header + ledger.output_index + ledger.output_payload + ledger.automaton);
    try std.testing.expectEqual(@as(u8, 3), ledger.mode);
    try std.testing.expectEqual(@as(usize, 274), ledger.output_index);
    try std.testing.expect(view.entry_count == 2048);
    try std.testing.expect(owned.bytes.len < 64 * 1024);
}
