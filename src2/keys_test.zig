const std = @import("std");
const keys = @import("keys.zig");

test "empty and maximum-sized UTF-8 keys round trip" {
    var builder = keys.Builder.atoms(std.testing.allocator);
    defer builder.deinit();
    try builder.addBytes("");
    const long_key = try std.testing.allocator.alloc(u8, keys.max_key_bytes);
    defer std.testing.allocator.free(long_key);
    @memset(long_key, 'a');
    try builder.addBytes(long_key);

    var owned = try builder.encode();
    defer owned.deinit();
    const view = try keys.View.open(owned.bytes);
    const scratch = try std.testing.allocator.alloc(u8, keys.max_key_bytes);
    defer std.testing.allocator.free(scratch);
    try std.testing.expect((try view.exact("", scratch)) != null);
    const hit = (try view.exact(long_key, scratch)).?;
    try std.testing.expectEqualSlices(u8, long_key, hit.key);
}

test "atoms and posting spaces round trip" {
    var b = keys.Builder.keys(std.testing.allocator);
    defer b.deinit();
    try b.addWithPostings("cat", &[_]u32{ 9, 2, 9 });
    try b.addWithPostings("car", &[_]u64{7});
    try b.addWithPostings("cat", &[_]u64{4});
    var owned = try b.encode();
    defer owned.deinit();
    var v = try keys.View.open(owned.bytes);
    var scratch: [32]u8 = undefined;
    const h = (try v.exact("cat", &scratch)).?;
    try std.testing.expectEqual(@as(u32, 3), h.posting_count);
    var it = try v.postingIterator(h);
    try std.testing.expectEqual(@as(u64, 2), (try it.next()).?);
    try std.testing.expectEqual(@as(u64, 4), (try it.next()).?);
    try std.testing.expectEqual(@as(u64, 9), (try it.next()).?);
    try std.testing.expect((try it.next()) == null);
    var prefix = try v.prefix("ca", &scratch);
    var seen: usize = 0;
    while (try prefix.next()) |_| seen += 1;
    try std.testing.expectEqual(@as(usize, 2), seen);
}

test "bounded postings reject IDs outside the node universe and ordinal is direct" {
    var b = try keys.Builder.keysWithUniverse(std.testing.allocator, 10);
    defer b.deinit();
    try std.testing.expectError(error.PostingOutOfRange, b.addWithPostings("bad", &[_]u64{10}));
    try b.addWithPostings("alpha", &[_]u64{2});
    try b.addWithPostings("beta", &[_]u64{9});
    var owned = try b.encode();
    defer owned.deinit();
    const view = try keys.View.open(owned.bytes);
    var scratch: [64]u8 = undefined;
    try std.testing.expectEqual(@as(?u32, 0), (try view.ordinal(0, &scratch)).?.ordinal);
    try std.testing.expectEqualStrings("beta", (try view.ordinal(1, &scratch)).?.key);
    try std.testing.expect((try view.ordinal(2, &scratch)) == null);
}

test "posting universe changes reject incompatible IDs without rebinding" {
    var b = keys.Builder.keys(std.testing.allocator);
    defer b.deinit();
    try b.addWithPostings("four", &[_]u64{4});
    try b.setPostingUniverse(6);
    try std.testing.expectError(error.PostingOutOfRange, b.setPostingUniverse(4));

    // The failed narrowing must not replace the existing bound: id 5 is
    // accepted under the previous universe of six, while id 6 is rejected.
    try b.addWithPostings("five", &[_]u64{5});
    try std.testing.expectError(error.PostingOutOfRange, b.addWithPostings("six", &[_]u64{6}));
    var owned = try b.encode();
    defer owned.deinit();
    const view = try keys.View.open(owned.bytes);
    var scratch: [16]u8 = undefined;
    try std.testing.expect((try view.exact("five", &scratch)) != null);
}

test "restart records are canonical and open performs no heap work" {
    var b = keys.Builder.atoms(std.testing.allocator);
    defer b.deinit();
    for (0..keys.restart_interval + 1) |i| {
        var key: [8]u8 = undefined;
        const text = try std.fmt.bufPrint(&key, "k{d:0>3}", .{i});
        try b.addBytes(text);
    }
    var owned = try b.encode();
    defer owned.deinit();
    const view = try keys.View.open(owned.bytes);
    try std.testing.expectEqual(@as(u32, keys.restart_interval + 1), view.key_count);
    const bad = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad);
    // The fourth u32 in every restart record is reserved and must remain zero.
    const restart_table = std.mem.readInt(u32, bad[24..][0..4], .little);
    std.mem.writeInt(u32, bad[restart_table + 12 ..][0..4], 1, .little);
    try std.testing.expectError(error.InvalidFormat, keys.View.open(bad));
}

test "open rejects truncation and fuzzy budget is explicit" {
    var b = keys.Builder.atoms(std.testing.allocator);
    defer b.deinit();
    try b.addBytes("alpha");
    try b.addBytes("alpine");
    var owned = try b.encode();
    defer owned.deinit();
    const bad = owned.bytes[0 .. owned.bytes.len - 1];
    try std.testing.expectError(error.Truncated, keys.View.open(bad));
    var v = try keys.View.open(owned.bytes);
    var key: [16]u8 = undefined;
    var row: [16]u16 = undefined;
    var f = try v.fuzzy("alpha", 0, 1, &key, &row);
    _ = try f.next();
    try std.testing.expectError(error.BudgetExceeded, f.next());
}
