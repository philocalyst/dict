const std = @import("std");
const bz4 = @import("root.zig");

/// "abracadabra"-like text parsed by hand: entry 0 = "ab", 1 = [0]"ra",
/// 2 = [1]"cad", 3 = "abrac" + "k" as a cut of entry 2.
const cut = bz4.Parse.cut;
const body_off = [_]u32{ 0, 2, 5, 9, 12 };
const kids = [_]u32{ 'a', 'b', 256, 'r', 'a', 257, 'c', 'a', 'd', 258, cut + 5, 'k' };
const block_off = [_]u32{ 0, 7, 12 };
const toks = [_]u32{ 258, 257, ' ', 258, 256, '!', 259, 257, 257, '?', 256, 259 };
const text = "abracadabra abracadab!abrack" ++ "abraabra?ababrack";
const parse: bz4.Parse = .{ .body_off = &body_off, .kids = &kids, .block_off = &block_off, .toks = &toks };

fn roundTrip(options: bz4.plan.Options) !void {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var plan = try bz4.plan.baseline(arena.allocator(), parse, options);
    const frame = try bz4.encode(gpa, &plan, null);
    defer gpa.free(frame);
    const fitted = try bz4.plan.fit(arena.allocator(), gpa, parse, options);
    defer gpa.free(fitted.bytes);
    try std.testing.expect(fitted.bytes.len <= frame.len or options.classes != 0);
    const out = try bz4.decodeAll(gpa, frame, 2);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(text, out);
}

test "round trip: streaming, flat, hoisted" {
    try roundTrip(.{});
    try roundTrip(.{ .classes = 32 });
    try roundTrip(.{ .ring = 0 });
    try roundTrip(.{ .hoist = true, .log = 7 });
    try roundTrip(.{ .alias = false, .classes = 1 });
    try roundTrip(.{ .classes = 3 });
}

test "corrupt frames fail cleanly" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var plan = try bz4.plan.baseline(arena.allocator(), parse, .{ .classes = 4 });
    const frame = try bz4.encode(gpa, &plan, null);
    defer gpa.free(frame);
    const bad = try gpa.dupe(u8, frame);
    defer gpa.free(bad);

    var prng: std.Random.DefaultPrng = .init(3);
    for (0..4000) |_| {
        @memcpy(bad, frame);
        for (0..prng.random().intRangeAtMost(usize, 1, 3)) |_| bad[prng.random().uintLessThan(usize, bad.len)] ^= prng.random().int(u8) | 1;
        const len = prng.random().intRangeAtMost(usize, 0, bad.len);
        if (bz4.decodeAll(gpa, bad[0..len], 1)) |out| gpa.free(out) else |_| {}
    }
}

test "bytes in, bytes out" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(7);
    var prose: std.ArrayList(u8) = .empty;
    defer prose.deinit(gpa);
    const words = [_][]const u8{ "abandon", "abandoned", "abandonment", "abase", "abash", "the", "of", "a", "lexical", "automaton", "42", "2026" };
    for (0..3000) |i| {
        try prose.appendSlice(gpa, words[prng.random().uintLessThan(usize, words.len)]);
        try prose.appendSlice(gpa, if (i % 11 == 10) ".\n" else " ");
    }
    for ([_][]const u8{ "", "a", "ab ab ab", "\x00\xff\x00\xff", prose.items }) |input| {
        const frame = try bz4.compress(gpa, input, .{ .learn = .{ .block = 4096 } });
        defer gpa.free(frame);
        const out = try bz4.decompress(gpa, frame, 3);
        defer gpa.free(out);
        try std.testing.expectEqualSlices(u8, input, out);
    }
}
