const std = @import("std");
const automaton = @import("automaton.zig");

fn rank(value: automaton.EntryRank) u32 {
    return @intFromEnum(value);
}

fn interleaved(allocator: std.mem.Allocator) !automaton.Owned {
    var builder = automaton.Builder.init(allocator);
    defer builder.deinit();
    try builder.addEntry("a", 1);
    try builder.addForm("b", &[_]u32{0});
    try builder.addEntry("c", 1);
    return builder.finish();
}

test "form-only accepts do not consume entry ranks" {
    var owned = try interleaved(std.testing.allocator);
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);
    try std.testing.expectEqual(@as(u32, 2), view.entry_count);
    try std.testing.expectEqual(@as(u32, 3), view.accepted_count);

    const a = (try view.exact("a")).?;
    try std.testing.expect(a.isEntry());
    try std.testing.expectEqual(@as(u32, 0), rank(a.entry_range.?.lo));
    try std.testing.expectEqual(@as(u32, 1), rank(a.entry_range.?.hi));
    const b = (try view.exact("b")).?;
    try std.testing.expect(b.isForm());
    try std.testing.expectEqual(@as(u32, 1), b.targets.len());
    try std.testing.expectEqual(@as(u32, 0), rank(try b.target(0)));
    const c = (try view.exact("c")).?;
    try std.testing.expectEqual(@as(u32, 1), rank(c.entry_range.?.lo));
    try std.testing.expectEqual(@as(u32, 2), rank(c.entry_range.?.hi));

    const all = (try view.prefixInterval("")).?;
    try std.testing.expectEqual(@as(u32, 0), rank(all.lo()));
    try std.testing.expectEqual(@as(u32, 2), rank(all.hi()));
    const only_form = (try view.prefixInterval("b")).?;
    try std.testing.expectEqual(@as(u32, 1), rank(only_form.lo()));
    try std.testing.expectEqual(@as(u32, 1), rank(only_form.hi()));

    var scratch: [8]u8 = undefined;
    try std.testing.expectEqualStrings("a", (try view.select(0, &scratch)).?.key);
    try std.testing.expectEqualStrings("c", (try view.select(1, &scratch)).?.key);
}

test "homograph multiplicity occupies consecutive ranks" {
    var builder = automaton.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.addEntry("cat", 2);
    try builder.addForm("cats", &[_]u32{ 0, 1 });
    try builder.addEntry("dog", 1);
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);
    const cat = (try view.exact("cat")).?;
    try std.testing.expectEqual(@as(u32, 0), rank(cat.entry_range.?.lo));
    try std.testing.expectEqual(@as(u32, 2), rank(cat.entry_range.?.hi));
    const form = (try view.exact("cats")).?;
    try std.testing.expectEqual(@as(u32, 2), form.targets.len());
    try std.testing.expectEqual(@as(u32, 1), rank(try form.target(1)));
    var scratch: [16]u8 = undefined;
    try std.testing.expectEqualStrings("cat", (try view.select(0, &scratch)).?.key);
    try std.testing.expectEqual(@as(u32, 1), (try view.select(1, &scratch)).?.identity_index);
    try std.testing.expectEqualStrings("dog", (try view.select(2, &scratch)).?.key);
}

test "empty and arbitrary byte keys are deterministic" {
    var first_builder = automaton.Builder.init(std.testing.allocator);
    defer first_builder.deinit();
    try first_builder.addEntry("", 1);
    try first_builder.addForm("\x00", &[_]u32{0});
    try first_builder.addEntry("\xff", 1);
    var first = try first_builder.finish();
    defer first.deinit();

    var second_builder = automaton.Builder.init(std.testing.allocator);
    defer second_builder.deinit();
    try second_builder.addEntry("", 1);
    try second_builder.addForm("\x00", &[_]u32{0});
    try second_builder.addEntry("\xff", 1);
    var second = try second_builder.finish();
    defer second.deinit();
    try std.testing.expectEqualSlices(u8, first.bytes, second.bytes);
    const view = try automaton.View.open(first.bytes);
    var scratch: [4]u8 = undefined;
    try std.testing.expectEqualStrings("", (try view.select(0, &scratch)).?.key);
    try std.testing.expect((try view.exact("\x00")) != null);
}

test "incremental minimisation and deterministic enumeration" {
    var builder = automaton.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.addEntry("a", 1);
    try builder.addEntry("ab", 1);
    try builder.addForm("ac", &[_]u32{0});
    try builder.addEntry("b", 1);
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);
    try std.testing.expect(view.state_count < 6);
    var key: [16]u8 = undefined;
    var frames: [8]automaton.Frame = undefined;
    var iterator = try view.prefix("a", &key, &frames);
    const expected = [_][]const u8{ "a", "ab", "ac" };
    var index: usize = 0;
    while (try iterator.next()) |item| {
        try std.testing.expect(index < expected.len);
        try std.testing.expectEqualStrings(expected[index], item.key);
        index += 1;
    }
    try std.testing.expectEqual(expected.len, index);
}

test "forward form targets preserve later headword rank" {
    var builder = automaton.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.addEntry("ant", 1);
    try builder.addForm("antler", &[_]u32{1});
    try builder.addEntry("bat", 1);
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);
    try view.verify();
    const form = (try view.exact("antler")).?;
    try std.testing.expect(form.isForm());
    try std.testing.expectEqual(@as(u32, 1), rank(try form.target(0)));
    try std.testing.expectEqual(@as(u32, 1), rank((try view.exact("bat")).?.entry_range.?.lo));
}

test "prefix walks report form targets, homograph ranges, and ordinary misses uniformly" {
    var builder = automaton.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.addEntry("cat", 2);
    try builder.addEntry("cater", 1);
    try builder.addForm("cats", &.{ 0, 1 });
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);

    var key = [_]u8{0} ** 32;
    var frames = [_]automaton.Frame{.{}} ** 32;
    var iterator = try view.prefix("ca", &key, &frames);
    const first = (try iterator.next()).?;
    try std.testing.expect(first.isEntry());
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(first.entry_range.lo));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(first.entry_range.hi));
    try std.testing.expectEqual(@as(u32, 0), first.targets.len());

    const second = (try iterator.next()).?;
    try std.testing.expect(second.isEntry());
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(second.entry_range.lo));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(second.entry_range.hi));

    const third = (try iterator.next()).?;
    try std.testing.expect(third.isForm());
    try std.testing.expect(third.entries() == null);
    try std.testing.expectEqual(@as(u32, 2), third.targets.len());
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(try third.targets.target(0)));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(try third.targets.target(1)));
    try std.testing.expect((try iterator.next()) == null);

    var miss = try view.prefix("zzz", &key, &frames);
    try std.testing.expect((try miss.next()) == null);
    try std.testing.expect((try view.prefixInterval("zzz")) == null);
    try std.testing.expect((try view.exact("zzz")) == null);

    // Lower bounds remain in primary-entry rank space: the form is accepted
    // but contributes no identity, and homograph multiplicity does.
    try std.testing.expectEqual(@as(u32, 0), rank(try view.lowerBound("")));
    try std.testing.expectEqual(@as(u32, 0), rank(try view.lowerBound("b")));
    try std.testing.expectEqual(@as(u32, 0), rank(try view.lowerBound("cat")));
    try std.testing.expectEqual(@as(u32, 2), rank(try view.lowerBound("catd")));
    try std.testing.expectEqual(@as(u32, 3), rank(try view.lowerBound("cats")));
    try std.testing.expectEqual(@as(u32, 3), rank(try view.lowerBound("zzz")));
}

test "frontier rank oracle covers byte keys, forms, multiplicity, prefix, and select" {
    const count = 512;
    var keys: [count][2]u8 = undefined;
    var is_form: [count]bool = undefined;
    var multiplicity: [count]u32 = undefined;
    var entry_lo: [count]u32 = undefined;
    var entry_count: u32 = 0;

    var builder = automaton.Builder.init(std.testing.allocator);
    defer builder.deinit();
    for (0..count) |index| {
        keys[index] = .{ @intCast(index >> 8), @truncate(index) };
        is_form[index] = index != 0 and index % 5 == 0;
        if (is_form[index]) {
            multiplicity[index] = 0;
            try builder.addForm(&keys[index], &[_]u32{0});
        } else {
            multiplicity[index] = @intCast(index % 3 + 1);
            entry_lo[index] = entry_count;
            entry_count += multiplicity[index];
            try builder.addEntry(&keys[index], multiplicity[index]);
        }
    }
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);
    try view.verify();
    try std.testing.expectEqual(entry_count, view.entry_count);

    for (keys, 0..) |key, index| {
        const hit = (try view.exact(&key)).?;
        if (is_form[index]) {
            try std.testing.expect(hit.isForm());
            try std.testing.expectEqual(@as(u32, 1), hit.targets.len());
            try std.testing.expectEqual(@as(u32, 0), rank(try hit.target(0)));
            var targets = hit.targets.iterator();
            try std.testing.expectEqual(@as(u32, 0), rank((try targets.next()).?));
            try std.testing.expect((try targets.next()) == null);
        } else {
            try std.testing.expect(hit.isEntry());
            try std.testing.expectEqual(entry_lo[index], rank(hit.entry_range.?.lo));
            try std.testing.expectEqual(entry_lo[index] + multiplicity[index], rank(hit.entry_range.?.hi));
        }
    }

    var scratch: [2]u8 = undefined;
    var wanted: u32 = 0;
    for (keys, 0..) |key, index| {
        if (is_form[index]) continue;
        for (0..multiplicity[index]) |identity| {
            const selected = (try view.select(wanted, &scratch)).?;
            try std.testing.expectEqualSlices(u8, &key, selected.key);
            try std.testing.expectEqual(wanted, rank(selected.rank));
            try std.testing.expectEqual(@as(u32, @intCast(identity)), selected.identity_index);
            wanted += 1;
        }
    }

    for ([_]u8{ 0, 1 }) |prefix_byte| {
        var first: ?u32 = null;
        var end: u32 = 0;
        for (keys, 0..) |_, index| {
            if (keys[index][0] != prefix_byte or is_form[index]) continue;
            if (first == null) first = entry_lo[index];
            end = entry_lo[index] + multiplicity[index];
        }
        const interval = (try view.prefixInterval(&[_]u8{prefix_byte})).?;
        try std.testing.expectEqual(first.?, rank(interval.lo()));
        try std.testing.expectEqual(end, rank(interval.hi()));
    }

    var second_builder = automaton.Builder.init(std.testing.allocator);
    defer second_builder.deinit();
    for (keys, 0..) |key, index| {
        if (is_form[index]) try second_builder.addForm(&key, &[_]u32{0}) else try second_builder.addEntry(&key, multiplicity[index]);
    }
    var second = try second_builder.finish();
    defer second.deinit();
    try std.testing.expectEqualSlices(u8, owned.bytes, second.bytes);
}

test "repeated suffixes beat a reference trie" {
    var builder = automaton.Builder.init(std.testing.allocator);
    defer builder.deinit();
    const keys = [_][]const u8{ "ab", "ac", "db", "dc" };
    for (keys) |key| try builder.addEntry(key, 1);
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);
    try view.verify();
    // A byte trie for these four keys has six nodes (root, a, d, b, c and
    // one terminal distinction per branch); the minimal DAG shares suffixes.
    try std.testing.expect(view.state_count < 6);
    for (keys, 0..) |key, expected| {
        try std.testing.expectEqual(@as(u32, @intCast(expected)), rank((try view.exact(key)).?.entry_range.?.lo));
    }
}

test "empty builder and Step A flat-like size gate" {
    var empty_builder = automaton.Builder.init(std.testing.allocator);
    defer empty_builder.deinit();
    var empty = try empty_builder.finish();
    defer empty.deinit();
    const empty_view = try automaton.View.open(empty.bytes);
    try std.testing.expectEqual(@as(u32, 0), empty_view.entry_count);
    try std.testing.expect((try empty_view.exact("x")) == null);

    var builder = automaton.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.addEntry("entry-00000000-é-東京", 1);
    for (1..2048) |i| {
        var key: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&key, "entry-{d:0>8}", .{i});
        try builder.addEntry(text, 1);
    }
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);
    try view.verify();
    std.debug.print("LEX4_STEP_A_LEDGER states={} bytes={} entries={} accepted={}\n", .{ view.state_count, owned.bytes.len, view.entry_count, view.accepted_count });
    try std.testing.expect(owned.bytes.len < 40 * 1024);
    try std.testing.expectEqual(@as(u32, 2048), view.entry_count);
}

test "2300-state repeated-prefix ledger stays under 40 KiB" {
    var builder = automaton.Builder.init(std.testing.allocator);
    defer builder.deinit();
    var values: [1900]u32 = undefined;
    for (0..values.len) |value| {
        var mixed: u32 = @intCast(value);
        mixed ^= mixed >> 7;
        mixed *%= 0x9e37_79b1;
        mixed ^= mixed >> 13;
        mixed *%= 0x85eb_ca6b;
        mixed ^= mixed >> 16;
        values[value] = mixed;
    }
    const Less = struct {
        fn less(_: void, a: u32, b: u32) bool {
            return a < b;
        }
    };
    std.sort.heap(u32, &values, {}, Less.less);
    for (values) |n| {
        const key = [_]u8{ @truncate(n >> 24), @truncate(n >> 16), @truncate(n >> 8), @truncate(n), 's', 'u', 'f' };
        try builder.addEntry(&key, 1);
    }
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);
    try view.verify();
    std.debug.print("LEX4_STEP_A_2300 states={} bytes={} entries={} accepted={}\n", .{ view.state_count, owned.bytes.len, view.entry_count, view.accepted_count });
    try std.testing.expect(view.state_count >= 2000);
    try std.testing.expect(owned.bytes.len <= 40 * 1024);
}

test "2300-state repeated-prefix ReleaseFast timings" {
    var builder = automaton.Builder.init(std.testing.allocator);
    defer builder.deinit();
    var values: [1900]u32 = undefined;
    var keys: [1900][7]u8 = undefined;
    for (0..values.len) |value| {
        var mixed: u32 = @intCast(value);
        mixed ^= mixed >> 7;
        mixed *%= 0x9e37_79b1;
        mixed ^= mixed >> 13;
        mixed *%= 0x85eb_ca6b;
        mixed ^= mixed >> 16;
        values[value] = mixed;
    }
    const Less = struct {
        fn less(_: void, a: u32, b: u32) bool {
            return a < b;
        }
    };
    std.sort.heap(u32, &values, {}, Less.less);
    for (values, 0..) |value, index| {
        keys[index] = .{ @truncate(value >> 24), @truncate(value >> 16), @truncate(value >> 8), @truncate(value), 's', 'u', 'f' };
        try builder.addEntry(&keys[index], 1);
    }
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);
    try view.verify();
    try std.testing.expect(owned.bytes.len <= 40 * 1024);

    const repetitions: usize = 20_000;
    var scratch: [7]u8 = undefined;
    var sink: u32 = 0;
    var start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    for (0..repetitions) |i| sink ^= @intFromEnum((try view.exact(&keys[i % keys.len])).?.entry_range.?.lo);
    const exact_ns = @as(u64, @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds - start));
    start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    for (0..repetitions) |i| sink ^= @intFromEnum((try view.prefixInterval(keys[i % keys.len][0..2])).?.range.lo);
    const prefix_ns = @as(u64, @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds - start));
    start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    for (0..repetitions) |i| sink ^= @intFromEnum((try view.select(@as(u32, @intCast(i % values.len)), &scratch)).?.rank);
    const select_ns = @as(u64, @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds - start));
    std.mem.doNotOptimizeAway(sink);
    std.debug.print("LEX4_STEP_A_2300_RELEASEFAST bytes={} exact_ns_op={} prefix_ns_op={} select_ns_op={} sink={}\n", .{ owned.bytes.len, exact_ns / repetitions, prefix_ns / repetitions, select_ns / repetitions, sink });
}

test "exact adversarial 2300-key corpus remains compact" {
    var values: [2300]u32 = undefined;
    for (0..values.len) |value| {
        var mixed: u32 = @intCast(value);
        mixed ^= mixed >> 7;
        mixed *%= 0x9e37_79b1;
        mixed ^= mixed >> 13;
        mixed *%= 0x85eb_ca6b;
        mixed ^= mixed >> 16;
        values[value] = mixed;
    }
    const Less = struct {
        fn less(_: void, a: u32, b: u32) bool {
            return a < b;
        }
    };
    std.sort.heap(u32, &values, {}, Less.less);
    var builder = automaton.Builder.init(std.testing.allocator);
    defer builder.deinit();
    for (values) |value| {
        const key = [_]u8{ @truncate(value >> 24), @truncate(value >> 16), @truncate(value >> 8), @truncate(value) };
        try builder.addEntry(&key, 1);
    }
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);
    try view.verify();
    var scratch: [8]u8 = undefined;
    const repetitions: usize = 10_000;
    var sink: u32 = 0;
    var hits: usize = 0;
    var start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    for (0..repetitions) |iteration| {
        const value = values[iteration % values.len];
        const key = [_]u8{ @truncate(value >> 24), @truncate(value >> 16), @truncate(value >> 8), @truncate(value) };
        if ((try view.exact(&key)) != null) hits += 1;
    }
    const exact_ns = @as(u64, @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds - start));
    start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    for (0..repetitions) |iteration| {
        const value = values[iteration % values.len];
        const key = [_]u8{ @truncate(value >> 24), @truncate(value >> 16), @truncate(value >> 8), @truncate(value) };
        _ = try view.prefixInterval(key[0..2]);
    }
    const prefix_ns = @as(u64, @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds - start));
    start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    for (0..repetitions) |iteration| sink ^= @intFromEnum((try view.select(@as(u32, @intCast(iteration % values.len)), &scratch)).?.rank);
    const select_ns = @as(u64, @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds - start));
    std.mem.doNotOptimizeAway(sink);
    std.debug.print("LEX4_STEP_A_ADVERSARIAL states={} bytes={} exact_ns_op={} prefix_ns_op={} select_ns_op={} hits={} sink={}\n", .{ view.state_count, owned.bytes.len, exact_ns / repetitions, prefix_ns / repetitions, select_ns / repetitions, hits, sink });
    try std.testing.expectEqual(values.len, @as(usize, view.entry_count));
    try std.testing.expect(owned.bytes.len <= 40 * 1024);
}

test "larger corpus keeps checkpoint directory budget-safe" {
    var values: [4096]u32 = undefined;
    for (0..values.len) |value| {
        var mixed: u32 = @intCast(value);
        mixed ^= mixed >> 7;
        mixed *%= 0x9e37_79b1;
        mixed ^= mixed >> 13;
        mixed *%= 0x85eb_ca6b;
        mixed ^= mixed >> 16;
        values[value] = mixed;
    }
    const Less = struct {
        fn less(_: void, a: u32, b: u32) bool {
            return a < b;
        }
    };
    std.sort.heap(u32, &values, {}, Less.less);
    var builder = automaton.Builder.init(std.testing.allocator);
    defer builder.deinit();
    for (values) |value| {
        const key = [_]u8{ @truncate(value >> 24), @truncate(value >> 16), @truncate(value >> 8), @truncate(value) };
        try builder.addEntry(&key, 1);
    }
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);
    try view.verify();
    std.debug.print("LEX4_STEP_A_LARGE states={} entries={} bytes={} checkpoint_stride={}\n", .{ view.state_count, view.entry_count, owned.bytes.len, view.checkpoint_stride });
    try std.testing.expect(owned.bytes.len <= 40 * 1024);
    try std.testing.expectEqual(@as(u32, 32), view.checkpoint_stride);
}

test "duplicate and sorted-input policy is explicit" {
    var builder = automaton.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.addEntry("b", 1);
    try std.testing.expectError(error.InputOutOfOrder, builder.addEntry("a", 1));
    try std.testing.expectError(error.DuplicateKey, builder.addEntry("b", 1));
    try std.testing.expectError(error.InvalidMultiplicity, builder.addEntry("c", 0));
    try std.testing.expectError(error.InvalidTargets, builder.addForm("c", &[_]u32{}));
    try std.testing.expectError(error.InvalidTargets, builder.addForm("c", &[_]u32{ 1, 1 }));
}

fn readVar(bytes: []const u8, cursor: *usize) u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        const byte = bytes[cursor.*];
        cursor.* += 1;
        result |= @as(u32, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        shift += 7;
    }
}

test "wire validation rejects truncation, checkpoint, and graph corruption" {
    var builder = automaton.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.addEntry("a", 1);
    try builder.addForm("b", &[_]u32{0});
    try builder.addEntry("c", 1);
    var owned = try builder.finish();
    defer owned.deinit();
    try std.testing.expectError(error.Truncated, automaton.View.open(owned.bytes[0 .. owned.bytes.len - 1]));

    const bad_offset = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_offset);
    std.mem.writeInt(u32, bad_offset[44..48], std.math.maxInt(u32), .little);
    try std.testing.expectError(error.Truncated, automaton.View.open(bad_offset));

    const bad_checkpoint = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_checkpoint);
    const checkpoint_offset = std.mem.readInt(u32, bad_checkpoint[32..36], .little);
    std.mem.writeInt(u32, bad_checkpoint[checkpoint_offset..][0..4], std.math.maxInt(u32), .little);
    const bad_checkpoint_view = try automaton.View.open(bad_checkpoint);
    try std.testing.expectError(error.InvalidFormat, bad_checkpoint_view.verify());

    const bad_graph = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_graph);
    const stream_offset = std.mem.readInt(u32, bad_graph[36..40], .little);
    bad_graph[stream_offset + 1] = 0x7f;
    const bad_graph_view = try automaton.View.open(bad_graph);
    try std.testing.expectError(error.InvalidFormat, bad_graph_view.verify());
}

test "reader is allocation-free and builder handles allocation failures" {
    var owned = try interleaved(std.testing.allocator);
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);
    var key: [8]u8 = undefined;
    var frames: [8]automaton.Frame = undefined;
    var iterator = try view.prefix("", &key, &frames);
    while (try iterator.next()) |_| {}
    _ = try view.exact("a");
    _ = try view.prefixInterval("a");
    _ = try view.select(0, &key);
}

test "opaque product cursor exposes checked arcs and terminal counts" {
    var owned = try interleaved(std.testing.allocator);
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);
    const root = try view.rootCursor();
    try std.testing.expectEqual(@as(u32, 2), root.primaryCount());
    try std.testing.expect(!root.hasEntry());
    try std.testing.expect(!root.hasForm());

    var arcs = try view.rootCursor();
    var count: usize = 0;
    while (try arcs.nextArc()) |arc| {
        try std.testing.expect(count < 3);
        if (count == 0) try std.testing.expectEqual(@as(u8, 'a'), arc.label);
        if (count == 1) try std.testing.expectEqual(@as(u8, 'b'), arc.label);
        if (count == 2) try std.testing.expectEqual(@as(u8, 'c'), arc.label);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);

    const a_arc = (try view.step(root.stateId(), 'a')).?;
    const a = try view.stateCursor(a_arc.target);
    try std.testing.expectEqual(@as(u32, 1), a.entryMultiplicity());
    try std.testing.expectEqual(@as(u32, 1), a.primaryCount());

    const b_arc = (try view.step(root.stateId(), 'b')).?;
    const b = try view.stateCursor(b_arc.target);
    try std.testing.expect(!b.hasEntry());
    try std.testing.expect(b.hasForm());
    try std.testing.expectEqual(@as(u32, 1), b.formTargets().len());
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(try b.formTargets().target(0)));
    try std.testing.expectError(error.InvalidState, view.stateCursor(.none));
}

fn allocationFailureBuild(allocator: std.mem.Allocator) !void {
    var builder = automaton.Builder.init(allocator);
    defer builder.deinit();
    try builder.addEntry("alpha", 1);
    try builder.addForm("alpine", &[_]u32{0});
    try builder.addEntry("beta", 1);
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);
    try view.verifyWithAllocator(allocator);
}

test "builder cleans up at every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureBuild, .{});
}
