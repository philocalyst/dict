const std = @import("std");
const compression = @import("compression.zig");

fn expectBzip3RoundTrip(input: []const u8) !void {
    var encoded = try compression.encode(std.testing.allocator, input, .bzip3, .{});
    defer encoded.deinit();
    try std.testing.expectEqual(compression.Codec.bzip3, encoded.codec);
    try std.testing.expectEqual(encoded.bytes.len, encoded.allocation.len);
    try std.testing.expectEqual(input.len, encoded.raw_len);

    var decoded = try compression.decode(std.testing.allocator, .bzip3, encoded.bytes, input.len, .{});
    defer decoded.deinit();
    try std.testing.expectEqual(compression.Codec.bzip3, decoded.codec);
    try std.testing.expectEqual(decoded.bytes.len, decoded.allocation.len);
    try std.testing.expectEqual(input.len, decoded.raw_len);
    try std.testing.expectEqualSlices(u8, input, decoded.bytes);
}

test "real bzip3 round trips empty short Unicode and arbitrary bytes" {
    const arbitrary = [_]u8{ 0, 1, 2, 3, 0xff, 0, 0x80, 0x7f, 0, 0xff };
    try expectBzip3RoundTrip(&[_]u8{});
    try expectBzip3RoundTrip("short lexical block");
    try expectBzip3RoundTrip("Unicode — नदी — Ελληνικά — العربية — 日本語");
    try expectBzip3RoundTrip(arbitrary[0..]);
}

test "real bzip3 compresses repetitive data and adaptive mode keeps it" {
    var input: [120_000]u8 = undefined;
    for (&input, 0..) |*byte, index| {
        byte.* = if (index % 257 < 240) 'x' else @intCast(index & 0xff);
    }

    var encoded = try compression.encode(std.testing.allocator, input[0..], .bzip3, .{});
    defer encoded.deinit();
    try std.testing.expect(encoded.bytes.len < input.len);

    var adaptive = try compression.encode(std.testing.allocator, input[0..], .adaptive, .{});
    defer adaptive.deinit();
    try std.testing.expectEqual(compression.Codec.bzip3, adaptive.codec);
    try std.testing.expectEqualSlices(u8, encoded.bytes, adaptive.bytes);
    try expectBzip3RoundTrip(input[0..]);
}

test "adaptive mode prefers raw on incompressible short bytes" {
    var random_bytes: [63]u8 = undefined;
    var state: u32 = 0x9e37_79b9;
    for (&random_bytes) |*byte| {
        state = state *% 1_664_525 +% 1_013_904_223;
        byte.* = @truncate(state >> 7);
    }

    var encoded = try compression.encode(std.testing.allocator, random_bytes[0..], .adaptive, .{});
    defer encoded.deinit();
    try std.testing.expectEqual(compression.Codec.raw, encoded.codec);
    try std.testing.expectEqualSlices(u8, random_bytes[0..], encoded.bytes);
    try std.testing.expectEqual(encoded.bytes.len, encoded.allocation.len);

    var forced = try compression.encode(std.testing.allocator, random_bytes[0..], .bzip3, .{});
    defer forced.deinit();
    try std.testing.expectEqual(random_bytes.len + 8, forced.bytes.len);
}

test "raw mode and raw decode are exact copies" {
    const input = "raw payload with NUL\x00 and high byte\xff";
    var encoded = try compression.encode(std.testing.allocator, input, .raw, .{});
    defer encoded.deinit();
    try std.testing.expectEqual(compression.Codec.raw, encoded.codec);
    try std.testing.expectEqualSlices(u8, input, encoded.bytes);
    try std.testing.expectEqual(encoded.bytes.len, encoded.allocation.len);

    var decoded = try compression.decode(std.testing.allocator, .raw, encoded.bytes, input.len, .{});
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u8, input, decoded.bytes);
    try std.testing.expectEqual(decoded.bytes.len, decoded.allocation.len);
}

test "bzip3 corruption and truncation return errors" {
    const input = "corruption must be detected after real bzip3 encoding " ** 8;
    var encoded = try compression.encode(std.testing.allocator, input, .bzip3, .{});
    defer encoded.deinit();

    const corrupted = try std.testing.allocator.dupe(u8, encoded.bytes);
    defer std.testing.allocator.free(corrupted);
    corrupted[0] ^= 1;
    if (compression.decode(std.testing.allocator, .bzip3, corrupted, input.len, .{})) |block| {
        var owned = block;
        owned.deinit();
        return error.UnexpectedSuccess;
    } else |_| {}

    const negative_bwt = try std.testing.allocator.dupe(u8, encoded.bytes);
    defer std.testing.allocator.free(negative_bwt);
    @memcpy(negative_bwt[4..8], &[_]u8{ 0xfe, 0xff, 0xff, 0xff });
    try std.testing.expectError(
        error.MalformedBlock,
        compression.decode(std.testing.allocator, .bzip3, negative_bwt, input.len, .{}),
    );

    var length: usize = 0;
    while (length < encoded.bytes.len) : (length += 1) {
        if (compression.decode(std.testing.allocator, .bzip3, encoded.bytes[0..length], input.len, .{})) |block| {
            var owned = block;
            owned.deinit();
            return error.UnexpectedTruncationSuccess;
        } else |_| {}
    }

    if (compression.decode(std.testing.allocator, .bzip3, encoded.bytes, input.len + 1, .{})) |block| {
        var owned = block;
        owned.deinit();
        return error.UnexpectedWrongLengthSuccess;
    } else |_| {}
}

test "limits are checked before native work and adaptive can retain raw" {
    const input = "bounded resource policy";
    try std.testing.expectError(
        error.InputTooLarge,
        compression.encode(std.testing.allocator, input, .bzip3, .{ .max_block_bytes = input.len - 1 }),
    );

    const small_cap = compression.Limits{ .max_block_bytes = input.len, .max_memory_bytes = input.len };
    try std.testing.expectError(error.ResourceLimit, compression.encode(std.testing.allocator, input, .bzip3, small_cap));

    var adaptive = try compression.encode(std.testing.allocator, input, .adaptive, small_cap);
    defer adaptive.deinit();
    try std.testing.expectEqual(compression.Codec.raw, adaptive.codec);
    try std.testing.expectEqualSlices(u8, input, adaptive.bytes);

    try std.testing.expectError(
        error.ResourceLimit,
        compression.decode(std.testing.allocator, .raw, input, input.len, .{ .max_memory_bytes = input.len - 1 }),
    );
    try std.testing.expectError(
        error.RawLengthMismatch,
        compression.decode(std.testing.allocator, .raw, input[0 .. input.len - 1], input.len, .{}),
    );
}

test "Zig allocator failures release owned work buffers" {
    var failing_encode = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        compression.encode(failing_encode.allocator(), "allocator failure", .raw, .{}),
    );
    try std.testing.expectEqual(@as(usize, 0), failing_encode.allocations);
    try std.testing.expectEqual(@as(usize, 0), failing_encode.deallocations);

    const input = "allocator failure through bzip3" ** 8;
    var encoded = try compression.encode(std.testing.allocator, input, .bzip3, .{});
    defer encoded.deinit();

    var failing_decode = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        compression.decode(failing_decode.allocator(), .bzip3, encoded.bytes, input.len, .{}),
    );
    try std.testing.expectEqual(@as(usize, 0), failing_decode.allocations);
    try std.testing.expectEqual(@as(usize, 0), failing_decode.deallocations);

    var failing_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 1,
        .resize_fail_index = 0,
    });
    try std.testing.expectError(
        error.OutOfMemory,
        compression.encode(failing_resize.allocator(), input, .bzip3, .{}),
    );
    try std.testing.expectEqual(failing_resize.allocations, failing_resize.deallocations);
}
