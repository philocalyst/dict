const std = @import("std");
const bitvector = @import("bitvector.zig");

const AuthSource = struct {
    data: []const u8,
    header_reads: usize = 0,
    full_reads: usize = 0,

    pub fn len(self: *const AuthSource) usize {
        return self.data.len;
    }

    pub fn bytes(self: *AuthSource, offset: usize, length: usize) bitvector.Error![]const u8 {
        if (offset > self.data.len or length > self.data.len - offset) return error.Truncated;
        if (offset == 0 and length == bitvector.header_size) self.header_reads += 1;
        if (offset == 0 and length == self.data.len) self.full_reads += 1;
        return self.data[offset..][0..length];
    }
};

fn exercise(comptime density: bitvector.Density, bits: []const bool) !void {
    var vector = try bitvector.Bitvector(density).init(std.testing.allocator, bits);
    defer vector.deinit();

    var expected_rank: usize = 0;
    var expected_positions: [2048]usize = undefined;
    var expected_count: usize = 0;
    for (bits, 0..) |set, i| {
        try std.testing.expectEqual(expected_rank, try vector.rank1(i));
        try std.testing.expectEqual(set, try vector.get(i));
        if (set) {
            expected_positions[expected_count] = i;
            expected_count += 1;
            expected_rank += 1;
        }
    }
    try std.testing.expectEqual(bits.len, vector.len());
    try std.testing.expectEqual(expected_count, vector.count());
    try std.testing.expectEqual(expected_rank, try vector.rank1(bits.len));
    try std.testing.expectEqual(expected_rank, try vector.rank1(bits.len));
    if (bits.len != 0) {
        try std.testing.expectEqual(expected_rank, try vector.rank1Inclusive(bits.len - 1));
    }

    for (expected_positions[0..expected_count], 0..) |position, rank| {
        try std.testing.expectEqual(position, try vector.select1(rank));
        try std.testing.expectEqual(position, try vector.select1(rank));
    }
    try std.testing.expectError(error.OutOfBounds, vector.get(bits.len));
    try std.testing.expectError(error.OutOfBounds, vector.rank1(bits.len + 1));
    try std.testing.expectError(error.OutOfBounds, vector.select1(expected_count));
}

test "all bitvector densities agree across word and checkpoint boundaries" {
    var bits: [1025]bool = undefined;
    for (&bits, 0..) |*set, i| set.* = (i % 3 == 0) or (i % 97 == 11) or i == 511 or i == 1024;
    inline for (.{ bitvector.Density.dense, bitvector.Density.sparse, bitvector.Density.very_sparse }) |density| {
        try exercise(density, &bits);
    }
}

test "empty and single-bit vectors have canonical boundary behavior" {
    const empty = [_]bool{};
    inline for (.{ bitvector.Density.dense, bitvector.Density.sparse, bitvector.Density.very_sparse }) |density| {
        var vector = try bitvector.Bitvector(density).init(std.testing.allocator, &empty);
        defer vector.deinit();
        try std.testing.expectEqual(@as(usize, 0), try vector.rank1(0));
        try std.testing.expectError(error.OutOfBounds, vector.get(0));
        try std.testing.expectError(error.OutOfBounds, vector.select1(0));
    }

    const single = [_]bool{false} ** 65;
    var one = single;
    one[64] = true;
    inline for (.{ bitvector.Density.dense, bitvector.Density.sparse, bitvector.Density.very_sparse }) |density| {
        try exercise(density, &one);
    }
}

test "sparse construction from sorted positions validates its input" {
    const positions = [_]usize{ 0, 7, 64, 511, 512, 1024 };
    var vector = try bitvector.Bitvector(.sparse).initFromPositions(std.testing.allocator, 1025, &positions);
    defer vector.deinit();
    for (positions, 0..) |position, rank| try std.testing.expectEqual(position, try vector.select1(rank));

    try std.testing.expectError(error.InvalidArgument, bitvector.Bitvector(.sparse).initFromPositions(std.testing.allocator, 10, &[_]usize{ 3, 3 }));
    try std.testing.expectError(error.InvalidArgument, bitvector.Bitvector(.sparse).initFromPositions(std.testing.allocator, 10, &[_]usize{10}));
}

test "RRR blocks round-trip every combinatorial class" {
    var bits: [64 * 17]bool = [_]bool{false} ** (64 * 17);
    for (0..64) |i| bits[i] = true;
    for (0..64) |i| bits[64 + i] = i % 2 == 0;
    for (0..64) |i| bits[128 + i] = i == 63;
    for (0..64) |i| bits[192 + i] = i == 0 or i == 63;
    for (0..64) |i| bits[256 + i] = true;
    for (0..bits.len) |i| {
        if (i >= 320) bits[i] = (i * 17) % 101 < 3;
    }
    try exercise(.very_sparse, &bits);
}

fn exerciseWire(bits: []const bool) !void {
    var owned = try bitvector.build(std.testing.allocator, bits);
    defer owned.deinit();
    const view = try bitvector.View.open(owned.bytes);
    _ = try bitvector.open(owned.bytes);
    _ = try owned.view();
    try std.testing.expectEqual(owned.chosen, view.representation());
    try std.testing.expectEqual(bits.len, view.len());

    var positions: [4096]usize = undefined;
    var count: usize = 0;
    var expected_rank: usize = 0;
    for (bits, 0..) |set, index| {
        try std.testing.expectEqual(expected_rank, try view.rank1(index));
        try std.testing.expectEqual(set, try view.get(index));
        if (set) {
            if (count == positions.len) return error.TestExpectedEqual;
            positions[count] = index;
            count += 1;
            expected_rank += 1;
        }
    }
    try std.testing.expectEqual(count, view.count());
    try std.testing.expectEqual(expected_rank, try view.rank1(bits.len));
    if (bits.len != 0) try std.testing.expectEqual(expected_rank, try view.rank1Inclusive(bits.len - 1));
    for (positions[0..count], 0..) |position, rank| {
        try std.testing.expectEqual(position, try view.select1(rank));
        try std.testing.expectEqual(position, try view.select1(rank));
    }
    try std.testing.expectError(error.OutOfBounds, view.get(bits.len));
    try std.testing.expectError(error.OutOfBounds, view.rank1(bits.len + 1));
    try std.testing.expectError(error.OutOfBounds, view.select1(count));
}

test "wire view round-trips empty, boundaries, and every adaptive representation" {
    const empty = [_]bool{};
    try exerciseWire(&empty);

    var boundary: [1025]bool = [_]bool{false} ** 1025;
    for (&boundary, 0..) |*set, index| set.* = index % 97 == 0 or index == 511 or index == 512 or index == 1024;
    try exerciseWire(&boundary);

    var all: [1025]bool = [_]bool{true} ** 1025;
    try exerciseWire(&all);

    const sparse_positions = [_]usize{ 0, 7, 64, 511, 512, 1024 };
    var sparse_bits: [1025]bool = [_]bool{false} ** 1025;
    for (sparse_positions) |position| sparse_bits[position] = true;
    try exerciseWire(&sparse_bits);

    var alternating: [1025]bool = undefined;
    for (&alternating, 0..) |*set, index| set.* = index % 2 == 0;
    try exerciseWire(&alternating);
}

test "wire bytes are deterministic and adaptive choice equals measured minimum" {
    var bits: [777]bool = undefined;
    for (&bits, 0..) |*set, index| set.* = (index % 19 == 0) or (index % 53 == 7);

    var first = try bitvector.build(std.testing.allocator, &bits);
    defer first.deinit();
    var second = try bitvector.build(std.testing.allocator, &bits);
    defer second.deinit();
    try std.testing.expectEqualSlices(u8, first.bytes, second.bytes);

    const representations = [_]bitvector.Representation{ .constant, .dense, .sparse, .very_sparse };
    var minimum: usize = std.math.maxInt(usize);
    var minimum_representation: ?bitvector.Representation = null;
    for (representations) |representation| {
        const candidate = bitvector.buildForced(std.testing.allocator, &bits, representation) catch |err| switch (err) {
            error.NotApplicable => continue,
            else => return err,
        };
        defer {
            var owned = candidate;
            owned.deinit();
        }
        try std.testing.expectEqual(try bitvector.measuredSize(&bits, representation), candidate.bytes.len);
        if (candidate.bytes.len < minimum) {
            minimum = candidate.bytes.len;
            minimum_representation = representation;
        }
    }
    try std.testing.expectEqual(minimum, first.bytes.len);
    try std.testing.expectEqual(minimum_representation.?, first.chosen);
}

test "wire open rejects malformed envelope, directories, and payload metadata" {
    var bits: [513]bool = [_]bool{false} ** 513;
    bits[0] = true;
    bits[512] = true;
    var owned = try bitvector.buildForced(std.testing.allocator, &bits, .dense);
    defer owned.deinit();

    try std.testing.expectError(error.Truncated, bitvector.View.open(owned.bytes[0 .. owned.bytes.len - 1]));

    const bad_magic = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_magic);
    bad_magic[0] ^= 1;
    try std.testing.expectError(error.BadMagic, bitvector.View.open(bad_magic));

    const bad_version = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_version);
    std.mem.writeInt(u16, bad_version[4..6], 99, .little);
    try std.testing.expectError(error.UnsupportedVersion, bitvector.View.open(bad_version));

    const bad_representation = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_representation);
    bad_representation[8] = 99;
    try std.testing.expectError(error.UnsupportedRepresentation, bitvector.View.open(bad_representation));

    const bad_header = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_header);
    std.mem.writeInt(u16, bad_header[6..8], 95, .little);
    try std.testing.expectError(error.InvalidEncoding, bitvector.View.open(bad_header));

    const bad_count = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_count);
    std.mem.writeInt(u64, bad_count[24..32], 514, .little);
    try std.testing.expectError(error.InvalidEncoding, bitvector.View.open(bad_count));

    const bad_directory_offset = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_directory_offset);
    std.mem.writeInt(u64, bad_directory_offset[48..56], 104, .little);
    try std.testing.expectError(error.InvalidEncoding, bitvector.View.open(bad_directory_offset));

    const bad_directory_length = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_directory_length);
    std.mem.writeInt(u64, bad_directory_length[56..64], 16, .little);
    try std.testing.expectError(error.InvalidEncoding, bitvector.View.open(bad_directory_length));

    const bad_payload_offset = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_payload_offset);
    std.mem.writeInt(u64, bad_payload_offset[64..72], 177, .little);
    try std.testing.expectError(error.InvalidEncoding, bitvector.View.open(bad_payload_offset));

    const bad_directory = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_directory);
    std.mem.writeInt(u64, bad_directory[header_sizeForTest()..][0..8], 1, .little);
    try std.testing.expectError(error.InvalidEncoding, bitvector.View.open(bad_directory));

    const bad_dense_payload = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_dense_payload);
    const payload_at = std.mem.readInt(u64, bad_dense_payload[64..72], .little);
    std.mem.writeInt(u64, bad_dense_payload[payload_at..][0..8], 99, .little);
    try std.testing.expectError(error.InvalidEncoding, bitvector.View.open(bad_dense_payload));
}

fn header_sizeForTest() usize {
    return bitvector.header_size;
}

test "wire sparse and RRR validators reject internal offsets and checkpoint records" {
    var bits: [1300]bool = [_]bool{false} ** 1300;
    bits[1] = true;
    bits[777] = true;
    bits[1299] = true;

    var sparse = try bitvector.buildForced(std.testing.allocator, &bits, .sparse);
    defer sparse.deinit();
    const bad_sparse = try std.testing.allocator.dupe(u8, sparse.bytes);
    defer std.testing.allocator.free(bad_sparse);
    const sparse_payload_at = std.mem.readInt(u64, bad_sparse[64..72], .little);
    std.mem.writeInt(u64, bad_sparse[sparse_payload_at + 16 ..][0..8], 72, .little);
    try std.testing.expectError(error.InvalidEncoding, bitvector.View.open(bad_sparse));

    var rrr = try bitvector.buildForced(std.testing.allocator, &bits, .very_sparse);
    defer rrr.deinit();
    const bad_rrr = try std.testing.allocator.dupe(u8, rrr.bytes);
    defer std.testing.allocator.free(bad_rrr);
    const rrr_payload_at = std.mem.readInt(u64, bad_rrr[64..72], .little);
    const offset_bits = std.mem.readInt(u64, bad_rrr[rrr_payload_at + 24 ..][0..8], .little);
    std.mem.writeInt(u64, bad_rrr[rrr_payload_at + 24 ..][0..8], offset_bits + 1, .little);
    try std.testing.expectError(error.InvalidEncoding, bitvector.View.open(bad_rrr));
}

test "wire randomized differential against bool oracle" {
    var bits: [4097]bool = undefined;
    var state: u64 = 0x9e3779b97f4a7c15;
    for (&bits) |*set| {
        state ^= state << 7;
        state ^= state >> 9;
        state ^= state << 8;
        set.* = (state & 7) == 0;
    }
    try exerciseWire(&bits);
}

fn wireAllocationFailure(allocator: std.mem.Allocator) !void {
    var bits: [1300]bool = undefined;
    for (&bits, 0..) |*set, index| set.* = index % 17 == 0 or index == 1299;
    var owned = try bitvector.build(allocator, &bits);
    defer owned.deinit();
    _ = try bitvector.View.open(owned.bytes);
}

fn wireBuilderAllocationFailure(allocator: std.mem.Allocator) !void {
    var bits: [1300]bool = undefined;
    for (&bits, 0..) |*set, index| set.* = index % 23 == 0;
    var builder = bitvector.Builder.init(allocator);
    defer builder.deinit();
    try builder.appendSlice(&bits);
    var owned = try builder.finish();
    defer owned.deinit();
}

test "wire builders release every allocation on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, wireAllocationFailure, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, wireBuilderAllocationFailure, .{});
}

test "generic borrowed source keeps envelope verification separate" {
    const bits = [_]bool{ false, true, false, false, true, true };
    var owned = try bitvector.build(std.testing.allocator, &bits);
    defer owned.deinit();

    var mapped = try bitvector.ViewFor(bitvector.SliceSource).openEnvelope(bitvector.SliceSource.init(owned.bytes));
    try std.testing.expect(!mapped.isVerified());
    try std.testing.expectError(error.Unverified, mapped.get(1));
    try mapped.verify();
    try std.testing.expect(mapped.isVerified());
    try std.testing.expectEqual(@as(usize, 3), mapped.count());
    try std.testing.expectEqual(@as(usize, 3), try mapped.rank1(mapped.len()));
    try std.testing.expectEqual(@as(usize, 4), try mapped.select1(1));

    const raw = try bitvector.ViewFor([]const u8).open(owned.bytes);
    try std.testing.expect(try raw.get(5));
}

test "generic source authenticates the full mapped wire before queries" {
    const bits = [_]bool{ true, false, true, false, false, true };
    var owned = try bitvector.build(std.testing.allocator, &bits);
    defer owned.deinit();

    var source_view = try bitvector.ViewFor(AuthSource).openEnvelope(.{ .data = owned.bytes });
    try std.testing.expectEqual(@as(usize, 1), source_view.source.header_reads);
    try std.testing.expectEqual(@as(usize, 0), source_view.source.full_reads);
    try std.testing.expectError(error.Unverified, source_view.rank1(3));
    try source_view.verify();
    try std.testing.expectEqual(@as(usize, 1), source_view.source.full_reads);
    try std.testing.expectEqual(@as(usize, 3), try source_view.rank1(source_view.len()));
    try std.testing.expectEqual(@as(usize, 5), try source_view.select1(2));
}
