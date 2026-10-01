//! Independently authored public-API audit retained verbatim from the parent
//! review, apart from this provenance comment and local module wiring.

const std = @import("std");
const candidate = @import("candidate");

test "independent public frame roundtrip and mutation safety" {
    const allocator = std.testing.allocator;
    var state: u32 = 0xa728910b;
    var input: [4096]u8 = undefined;
    const block_sizes = [_]usize{ 16, 257, 1024 };
    for (0..12) |trial| {
        for (&input, 0..) |*byte, index| {
            state = state *% 1664525 +% 1013904223;
            byte.* = switch (trial % 3) {
                0 => @truncate(state >> 16),
                1 => @intCast((state >> 24) % 7),
                else => @intCast(index % 5),
            };
        }
        const length = 2048 + trial * 97;
        const original = input[0..length];
        const block_size = block_sizes[trial % block_sizes.len];
        const model = try candidate.trainModel(allocator, input[3072..], block_size);
        var owned = try candidate.encodeFrame(allocator, original, model, block_size, .{});
        defer owned.deinit();
        const frame = try candidate.Frame.open(owned.bytes, .{});
        var decoded = try frame.decodeAll(allocator);
        defer decoded.deinit();
        try std.testing.expectEqualSlices(u8, original, decoded.bytes);
        for (0..frame.block_count) |block_index| {
            var block = try frame.decodeBlock(allocator, block_index);
            defer block.deinit();
            const start = block_index * block_size;
            try std.testing.expectEqualSlices(u8, original[start..][0..block.bytes.len], block.bytes);
        }
        const mutated = try allocator.dupe(u8, owned.bytes);
        defer allocator.free(mutated);
        for (0..64) |mutation| {
            const offset = (mutation * 7919 + trial * 101) % mutated.len;
            mutated[offset] ^= @as(u8, 1) << @intCast(mutation % 8);
            defer mutated[offset] ^= @as(u8, 1) << @intCast(mutation % 8);
            const hostile = candidate.Frame.open(mutated, .{}) catch continue;
            var result = hostile.decodeAll(allocator) catch continue;
            defer result.deinit();
            // A tolerated alternate encoding must not alter the admitted bytes.
            try std.testing.expectEqualSlices(u8, original, result.bytes);
        }
    }
}
