const std = @import("std");
const bits = @import("bits.zig");

test "checked bits and FOR handle boundaries and short final frames" {
    var raw = [_]u8{ 0, 0, 0 };
    try bits.writeBits(&raw, 3, 13, 0x1a2);
    try std.testing.expectEqual(@as(u64, 0x1a2), try bits.readBits(&raw, 3, 13));
    try std.testing.expectError(error.ValueOverflow, bits.writeBits(&raw, 3, 5, 32));
    try std.testing.expectError(error.OutOfBounds, bits.readBits(&raw, 24, 1));
    try std.testing.expectError(error.InvalidWidth, bits.readBits(&raw, 0, 65));

    const values = [_]u64{ 10, 10, 11, 1000, 1001, 1001, 9000 };
    var encoded = try bits.encodeFor(std.testing.allocator, &values, 3);
    defer encoded.deinit();
    const view = try bits.ForView.open(encoded.bytes);
    for (values, 0..) |value, i| try std.testing.expectEqual(value, try view.get(i));
    try std.testing.expectEqual(@as(u64, 9000), try view.get(6));
    try std.testing.expectError(error.OutOfBounds, view.get(values.len));
    try std.testing.expectError(error.InvalidEncoding, bits.ForView.open(encoded.bytes[0 .. encoded.bytes.len - 1]));
    try std.testing.expectError(error.BadMagic, bits.ForView.open("not-a-for"));

    var malformed = try std.testing.allocator.dupe(u8, encoded.bytes);
    defer std.testing.allocator.free(malformed);
    // The first frame starts after the 32-byte header and one 8-byte offset;
    // a width above 64 is rejected without allocating or decoding values.
    const first_frame = std.mem.readInt(u64, malformed[32..40], .little);
    malformed[first_frame + 8] = 65;
    try std.testing.expectError(error.InvalidEncoding, bits.ForView.open(malformed));
    try std.testing.expectError(error.ValueOverflow, bits.encodeFor(std.testing.allocator, [_]i64{-1}, 1));
}

test "presence rank and Elias-Fano reject malformed encodings" {
    var present_bytes = try std.testing.allocator.alloc(bool, 1030);
    defer std.testing.allocator.free(present_bytes);
    @memset(present_bytes, false);
    present_bytes[0] = true;
    present_bytes[511] = true;
    present_bytes[1029] = true;
    var encoded_present = try bits.encodePresence(std.testing.allocator, present_bytes);
    defer encoded_present.deinit();
    const present = try bits.PresenceView.open(encoded_present.bytes);
    try std.testing.expectEqual(@as(usize, 2), try present.rank(1029));
    try std.testing.expect(try present.isSet(1029));
    try std.testing.expectError(error.OutOfBounds, present.rank(1031));
    try std.testing.expectError(error.InvalidEncoding, bits.PresenceView.open(encoded_present.bytes[0 .. encoded_present.bytes.len - 1]));

    const roots = [_]u64{ 0, 7, 20, 100 };
    var encoded_sequence = try bits.encodeElias(std.testing.allocator, &roots, 120);
    defer encoded_sequence.deinit();
    const sequence = try bits.EliasView.open(encoded_sequence.bytes);
    for (roots, 0..) |value, i| try std.testing.expectEqual(value, try sequence.get(i));
    try std.testing.expectEqual(@as(usize, 3), try sequence.upperBound(99));
    try std.testing.expectEqual(@as(u64, 100), try sequence.get(3));
    try std.testing.expectError(error.InvalidEncoding, bits.EliasView.open(encoded_sequence.bytes[0 .. encoded_sequence.bytes.len - 1]));

    var extra = try std.testing.allocator.dupe(u8, encoded_sequence.bytes);
    defer std.testing.allocator.free(extra);
    extra[7] = 3;
    try std.testing.expectError(error.InvalidEncoding, bits.EliasView.open(extra));
    var tail = try std.testing.allocator.dupe(u8, encoded_sequence.bytes);
    defer std.testing.allocator.free(tail);
    tail[tail.len - 1] |= 0x80;
    try std.testing.expectError(error.InvalidEncoding, bits.EliasView.open(tail));

    var values: [128]u64 = undefined;
    for (0..values.len) |i| values[i] = i * 3;
    var long_bytes = try bits.encodeElias(std.testing.allocator, &values, 512);
    defer long_bytes.deinit();
    const long = try bits.EliasView.open(long_bytes.bytes);
    for (values, 0..) |value, i| try std.testing.expectEqual(value, try long.get(i));
}

test "borrowed wire views are allocation-free and canonical" {
    const values = [_]u64{ 7, 7, 8, 300, 301, 9000 };
    var encoded_vector = try bits.encodeFor(std.testing.allocator, &values, 3);
    defer encoded_vector.deinit();
    const vector = try bits.ForView.open(encoded_vector.bytes);
    for (values, 0..) |expected, i| try std.testing.expectEqual(expected, try vector.get(i));

    const flags = [_]bool{ true, false, true, false, false, true };
    var bitmap = try bits.encodePresence(std.testing.allocator, &flags);
    defer bitmap.deinit();
    const presence = try bits.PresenceView.open(bitmap.bytes);
    try std.testing.expect(try presence.isSet(2));
    try std.testing.expectEqual(@as(usize, 2), try presence.rank(5));

    const roots = [_]u64{ 0, 4, 17, 99 };
    var monotone = try bits.encodeElias(std.testing.allocator, &roots, 120);
    defer monotone.deinit();
    const sequence = try bits.EliasView.open(monotone.bytes);
    for (roots, 0..) |expected, i| try std.testing.expectEqual(expected, try sequence.get(i));
    try std.testing.expectEqual(@as(usize, 3), try sequence.upperBound(17));

    var corrupt = try std.testing.allocator.dupe(u8, bitmap.bytes);
    defer std.testing.allocator.free(corrupt);
    corrupt[16] = 1;
    try std.testing.expectError(error.InvalidEncoding, bits.PresenceView.open(corrupt));
}
