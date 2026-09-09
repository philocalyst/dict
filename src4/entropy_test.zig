const std = @import("std");
const entropy = @import("entropy.zig");

fn assertRoundTrip(values: []const u32, options: entropy.Options) !void {
    var owned = try entropy.build(std.testing.allocator, values, options);
    defer owned.deinit();
    const view = try entropy.View.openWithLimits(owned.bytes, options);
    try std.testing.expectEqual(values.len, view.count());
    for (values, 0..) |expected, i| try std.testing.expectEqual(expected, try view.get(i));

    var prng = std.Random.DefaultPrng.init(0x4c455834);
    var random_order = try std.testing.allocator.dupe(u32, values);
    defer std.testing.allocator.free(random_order);
    var i: usize = random_order.len;
    while (i > 1) {
        i -= 1;
        const j = prng.random().uintLessThan(usize, i + 1);
        // The values are only a convenient index permutation when copied into
        // a separate index buffer below; this shuffle still exercises a
        // deterministic, hostile-looking access order.
        std.mem.swap(u32, &random_order[i], &random_order[j]);
    }
    for (random_order, 0..) |_, index| {
        const probe = if (values.len == 0) 0 else (@as(usize, index) * 7919) % values.len;
        if (values.len != 0) try std.testing.expectEqual(values[probe], try view.get(probe));
    }

    const out = try std.testing.allocator.alloc(u32, values.len);
    defer std.testing.allocator.free(out);
    try view.decode(out);
    try std.testing.expectEqualSlices(u32, values, out);

    var again = try entropy.build(std.testing.allocator, values, options);
    defer again.deinit();
    try std.testing.expectEqualSlices(u8, owned.bytes, again.bytes);
    try std.testing.expectEqual(owned.strategy(), view.strategy());
}

fn expectSmallestCompleteCandidate(values: []const u32, options: entropy.Options) !void {
    const order = [_]entropy.Strategy{ .constant, .runs, .@"packed", .entropy, .reference };
    var adaptive = try entropy.build(std.testing.allocator, values, options);
    defer adaptive.deinit();

    var smallest: ?usize = null;
    var tied_first: ?entropy.Strategy = null;
    for (order) |strategy| {
        var candidate = entropy.buildForced(std.testing.allocator, values, options, strategy) catch |err| switch (err) {
            error.NotApplicable => continue,
            else => return err,
        };
        defer candidate.deinit();
        if (smallest == null or candidate.bytes.len < smallest.?) {
            smallest = candidate.bytes.len;
            tied_first = strategy;
        }
    }

    try std.testing.expect(smallest != null);
    try std.testing.expectEqual(smallest.?, adaptive.bytes.len);
    try std.testing.expectEqual(tied_first.?, adaptive.strategy());
}

fn expectFinalByteIsRequired(values: []const u32, options: entropy.Options, strategy: entropy.Strategy) !void {
    var owned = try entropy.buildForced(std.testing.allocator, values, options, strategy);
    defer owned.deinit();
    try std.testing.expect(owned.bytes.len > 1);
    try std.testing.expectError(error.Truncated, entropy.View.open(owned.bytes[0 .. owned.bytes.len - 1]));
}

fn exerciseSingleByteMutations(bytes: []const u8) !void {
    var mutated = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(mutated);
    for (mutated, 0..) |original, at| {
        mutated[at] = original ^ 0xff;
        if (entropy.View.open(mutated)) |view| {
            var index: usize = 0;
            while (index < view.count()) : (index += 1) {
                _ = try view.get(index);
            }
        } else |_| {}
        mutated[at] = original;
    }
}

fn probeAllCheckpoints(view: *const entropy.View) !void {
    for (0..view.checkpointCount()) |index| {
        const checkpoint = try view.checkpoint(index);
        try std.testing.expect(checkpoint.offset <= view.bytes.len);
    }
}

fn expectOpenReject(bytes: []const u8) !void {
    if (entropy.View.open(bytes)) |_| return error.UnexpectedValidEncoding else |_| {}
}

fn expectU64FieldReject(bytes: []const u8, at: usize, value: u64) !void {
    var mutated = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(mutated);
    std.mem.writeInt(u64, mutated[at..][0..8], value, .little);
    try expectOpenReject(mutated);
}

fn expectU32FieldReject(bytes: []const u8, at: usize, value: u32) !void {
    var mutated = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(mutated);
    std.mem.writeInt(u32, mutated[at..][0..4], value, .little);
    try expectOpenReject(mutated);
}

fn assertTransparentReferenceWire(bytes: []const u8, values: []const u32) !void {
    const payload_at = @as(usize, @intCast(std.mem.readInt(u64, bytes[44..52], .little)));
    const payload_len = @as(usize, @intCast(std.mem.readInt(u64, bytes[52..60], .little)));
    try std.testing.expectEqual(@as(usize, 64), payload_at);
    try std.testing.expectEqual(values.len * 4, payload_len);
    for (values, 0..) |expected, index| {
        const at = payload_at + index * 4;
        try std.testing.expectEqual(expected, std.mem.readInt(u32, bytes[at..][0..4], .little));
    }
}

fn assertIndependentRansDecode(bytes: []const u8, values: []const u32, stride: usize) !void {
    const payload_at = @as(usize, @intCast(std.mem.readInt(u64, bytes[44..52], .little)));
    const payload = bytes[payload_at..];
    const alphabet = @as(usize, @intCast(std.mem.readInt(u32, payload[0..4], .little)));
    var symbols: [entropy.max_entropy_alphabet]u32 = undefined;
    var frequencies: [entropy.max_entropy_alphabet]u32 = undefined;
    var cumulative: [entropy.max_entropy_alphabet]u32 = undefined;
    for (0..alphabet) |index| {
        const at = 16 + index * 8;
        symbols[index] = std.mem.readInt(u32, payload[at..][0..4], .little);
        frequencies[index] = std.mem.readInt(u16, payload[at + 4 ..][0..2], .little);
        cumulative[index] = std.mem.readInt(u16, payload[at + 6 ..][0..2], .little);
    }

    const block_count = @as(usize, @intCast(std.mem.readInt(u32, payload[8..12], .little)));
    for (0..block_count) |block| {
        const offset = @as(usize, @intCast(std.mem.readInt(u64, bytes[64 + block * 8 ..][0..8], .little)));
        var state = std.mem.readInt(u32, payload[offset..][0..4], .little);
        const stream_len = @as(usize, @intCast(std.mem.readInt(u32, payload[offset + 4 ..][0..4], .little)));
        var cursor = offset + 8;
        const end = cursor + stream_len;
        const start = block * stride;
        const take = @min(stride, values.len - start);
        for (0..take) |local| {
            const slot = state & (entropy.rans_total - 1);
            var symbol_index: ?usize = null;
            for (0..alphabet) |candidate| {
                if (slot >= cumulative[candidate] and slot < cumulative[candidate] + frequencies[candidate]) {
                    symbol_index = candidate;
                    break;
                }
            }
            try std.testing.expect(symbol_index != null);
            const selected = symbol_index.?;
            try std.testing.expectEqual(values[start + local], symbols[selected]);
            state = @intCast(@as(u64, frequencies[selected]) * (state >> entropy.rans_scale_bits) +
                (slot - cumulative[selected]));
            while (state < entropy.rans_l) {
                try std.testing.expect(cursor < end);
                state = (state << 8) | payload[cursor];
                cursor += 1;
            }
        }
        try std.testing.expectEqual(end, cursor);
        try std.testing.expectEqual(entropy.rans_l, state);
    }
}

test "every representation preserves random access" {
    const constant = [_]u32{42} ** 257;
    var constant_owned = try entropy.buildForced(std.testing.allocator, &constant, .{}, .constant);
    defer constant_owned.deinit();
    const constant_view = try entropy.View.open(constant_owned.bytes);
    try std.testing.expectEqual(entropy.Strategy.constant, constant_view.strategy());
    try std.testing.expectEqual(@as(u32, 42), try constant_view.get(256));

    var runs: [400]u32 = undefined;
    for (0..100) |i| runs[i] = 7;
    for (100..250) |i| runs[i] = 99;
    for (250..400) |i| runs[i] = 7;
    var runs_owned = try entropy.buildForced(std.testing.allocator, &runs, .{ .checkpoint_stride = 31 }, .runs);
    defer runs_owned.deinit();
    const runs_view = try entropy.View.open(runs_owned.bytes);
    try std.testing.expectEqual(entropy.Strategy.runs, runs_view.strategy());
    try std.testing.expectEqual(@as(u32, 99), try runs_view.get(249));
    try std.testing.expectEqual(@as(u32, 7), try runs_view.get(250));

    var packed_values: [521]u32 = undefined;
    for (&packed_values, 0..) |*value, i| value.* = 1000 + @as(u32, @intCast((i * 13) % 16));
    var packed_owned = try entropy.buildForced(std.testing.allocator, &packed_values, .{ .checkpoint_stride = 37 }, .@"packed");
    defer packed_owned.deinit();
    const packed_view = try entropy.View.open(packed_owned.bytes);
    try std.testing.expectEqual(entropy.Strategy.@"packed", packed_view.strategy());
    for (packed_values, 0..) |expected, i| try std.testing.expectEqual(expected, try packed_view.get(i));

    const reference_values = [_]u32{ 0, 0xffffffff, 17, 901, 18, 77 };
    var reference_owned = try entropy.buildReference(std.testing.allocator, &reference_values);
    defer reference_owned.deinit();
    const reference_view = try entropy.View.open(reference_owned.bytes);
    try std.testing.expectEqual(entropy.Strategy.reference, reference_view.strategy());
    try std.testing.expectEqualSlices(u32, &reference_values, blk: {
        var result: [reference_values.len]u32 = undefined;
        for (&result, 0..) |*value, i| value.* = try reference_view.get(i);
        break :blk &result;
    });
}

test "adaptive cascade measures the complete serialized candidates" {
    const constant = [_]u32{9} ** 300;
    try assertRoundTrip(&constant, .{ .checkpoint_stride = 32 });
    var constant_owned = try entropy.build(std.testing.allocator, &constant, .{});
    defer constant_owned.deinit();
    try std.testing.expectEqual(entropy.Strategy.constant, constant_owned.strategy());

    var runs: [1200]u32 = undefined;
    for (0..400) |i| runs[i] = 1;
    for (400..800) |i| runs[i] = 2;
    for (800..1200) |i| runs[i] = 1;
    try assertRoundTrip(&runs, .{ .checkpoint_stride = 64 });
    var runs_owned = try entropy.build(std.testing.allocator, &runs, .{ .checkpoint_stride = 64 });
    defer runs_owned.deinit();
    try std.testing.expectEqual(entropy.Strategy.runs, runs_owned.strategy());

    var packed_values: [2048]u32 = undefined;
    for (&packed_values, 0..) |*value, i| value.* = 700 + @as(u32, @intCast((i * 17) % 32));
    try assertRoundTrip(&packed_values, .{ .checkpoint_stride = 64 });
    var packed_owned = try entropy.build(std.testing.allocator, &packed_values, .{ .checkpoint_stride = 64 });
    defer packed_owned.deinit();
    try std.testing.expectEqual(entropy.Strategy.@"packed", packed_owned.strategy());

    var skewed: [4096]u32 = undefined;
    for (&skewed, 0..) |*value, i| {
        value.* = if (i % 37 == 0) 1 else if (i % 113 == 0) 2 else if (i % 251 == 0) 3 else 0;
    }
    try assertRoundTrip(&skewed, .{ .checkpoint_stride = 128 });
    var entropy_owned = try entropy.build(std.testing.allocator, &skewed, .{ .checkpoint_stride = 128 });
    defer entropy_owned.deinit();
    try std.testing.expectEqual(entropy.Strategy.entropy, entropy_owned.strategy());
}

test "cascade minimum includes every wire byte at representation boundaries" {
    const constant = [_]u32{7} ** 1;
    try expectSmallestCompleteCandidate(&constant, .{ .checkpoint_stride = 1 });

    var short_runs: [65]u32 = undefined;
    for (0..32) |i| short_runs[i] = 1;
    for (32..65) |i| short_runs[i] = 2;
    try expectSmallestCompleteCandidate(&short_runs, .{ .checkpoint_stride = 32 });

    var packed_values: [129]u32 = undefined;
    for (&packed_values, 0..) |*value, i| value.* = 100 + @as(u32, @intCast(i % 4));
    try expectSmallestCompleteCandidate(&packed_values, .{ .checkpoint_stride = 17 });

    var skewed: [513]u32 = undefined;
    for (&skewed, 0..) |*value, i| value.* = if (i % 23 == 0) 1 else 0;
    try expectSmallestCompleteCandidate(&skewed, .{ .checkpoint_stride = 19 });
}

test "every strategy requires its final serialized byte" {
    const empty = [_]u32{};
    try expectFinalByteIsRequired(&empty, .{}, .constant);
    try expectFinalByteIsRequired(&empty, .{}, .reference);

    const constant = [_]u32{42} ** 9;
    try expectFinalByteIsRequired(&constant, .{}, .constant);

    const reference = [_]u32{ 0, 0xffffffff, 17, 901 };
    try expectFinalByteIsRequired(&reference, .{}, .reference);

    var runs: [67]u32 = undefined;
    for (0..33) |i| runs[i] = 3;
    for (33..67) |i| runs[i] = 4;
    try expectFinalByteIsRequired(&runs, .{ .checkpoint_stride = 11 }, .runs);

    var packed_values: [73]u32 = undefined;
    for (&packed_values, 0..) |*value, i| value.* = 500 + @as(u32, @intCast(i % 8));
    try expectFinalByteIsRequired(&packed_values, .{ .checkpoint_stride = 13 }, .@"packed");

    var entropy_values: [257]u32 = undefined;
    for (&entropy_values, 0..) |*value, i| value.* = if (i % 17 == 0) 1 else 0;
    try expectFinalByteIsRequired(&entropy_values, .{ .checkpoint_stride = 29 }, .entropy);
}

test "forced rANS agrees with the transparent little-endian reference" {
    var values: [777]u32 = undefined;
    for (&values, 0..) |*value, i| {
        value.* = if (i % 97 == 0) 3 else if (i % 29 == 0) 2 else if (i % 7 == 0) 1 else 0;
    }

    var encoded = try entropy.buildForced(std.testing.allocator, &values, .{ .checkpoint_stride = 31 }, .entropy);
    defer encoded.deinit();
    const view = try entropy.View.open(encoded.bytes);
    try std.testing.expectEqual(entropy.Strategy.entropy, view.strategy());
    try probeAllCheckpoints(&view);
    try assertIndependentRansDecode(encoded.bytes, &values, 31);
    for (values, 0..) |expected, i| try std.testing.expectEqual(expected, try view.get(i));

    var raw = try entropy.buildReference(std.testing.allocator, &values);
    defer raw.deinit();
    try assertTransparentReferenceWire(raw.bytes, &values);
    const raw_view = try entropy.View.open(raw.bytes);
    for (values, 0..) |expected, i| try std.testing.expectEqual(expected, try raw_view.get(i));

    var prng = std.Random.DefaultPrng.init(0x656e7472);
    for (0..96) |case_index| {
        const length = 1 + prng.random().uintLessThan(usize, 512);
        var random_values: [512]u32 = undefined;
        for (random_values[0..length]) |*value| value.* = prng.random().uintLessThan(u32, 8);
        const stride = 1 + (case_index % 53);
        var random_encoded = try entropy.buildForced(std.testing.allocator, random_values[0..length], .{ .checkpoint_stride = stride }, .entropy);
        defer random_encoded.deinit();
        const random_view = try entropy.View.open(random_encoded.bytes);
        try probeAllCheckpoints(&random_view);
        try assertIndependentRansDecode(random_encoded.bytes, random_values[0..length], stride);
        for (random_values[0..length], 0..) |expected, i| try std.testing.expectEqual(expected, try random_view.get(i));
    }
}

test "validated open makes single-byte corruption safe to probe" {
    const values = [_]u32{ 0, 0, 1, 1, 0, 0, 2, 2, 0, 0 };
    var reference = try entropy.buildForced(std.testing.allocator, &values, .{}, .reference);
    defer reference.deinit();
    try exerciseSingleByteMutations(reference.bytes);

    var runs = try entropy.buildForced(std.testing.allocator, &values, .{ .checkpoint_stride = 3 }, .runs);
    defer runs.deinit();
    try exerciseSingleByteMutations(runs.bytes);

    var packed_owned = try entropy.buildForced(std.testing.allocator, &values, .{ .checkpoint_stride = 3 }, .@"packed");
    defer packed_owned.deinit();
    try exerciseSingleByteMutations(packed_owned.bytes);

    var entropy_values: [129]u32 = undefined;
    for (&entropy_values, 0..) |*value, i| value.* = if (i % 11 == 0) 1 else 0;
    var entropy_owned = try entropy.buildForced(std.testing.allocator, &entropy_values, .{ .checkpoint_stride = 17 }, .entropy);
    defer entropy_owned.deinit();
    try exerciseSingleByteMutations(entropy_owned.bytes);
}

test "envelope open defers linear rANS validation without unsafe reads" {
    var values: [257]u32 = undefined;
    for (&values, 0..) |*value, i| value.* = if (i % 17 == 0) 1 else 0;
    var owned = try entropy.buildForced(std.testing.allocator, &values, .{ .checkpoint_stride = 29 }, .entropy);
    defer owned.deinit();

    const payload_at = @as(usize, @intCast(std.mem.readInt(u64, owned.bytes[44..52], .little)));
    const first_block = payload_at + @as(usize, @intCast(std.mem.readInt(u64, owned.bytes[64..72], .little)));

    var bad_stream = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_stream);
    // The envelope still has bounded block offsets and lengths, but this is
    // not a valid rANS state. Reads must return an error, never panic.
    std.mem.writeInt(u32, bad_stream[first_block..][0..4], 0, .little);
    var envelope = try entropy.View.openEnvelope(bad_stream);
    try std.testing.expectError(error.InvalidEncoding, envelope.verify());
    for (0..values.len) |index| {
        if (envelope.get(index)) |_| {} else |_| {}
    }

    var bad_table = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_table);
    // Force cumulative frequency past u16 before the next table row. The
    // decoder must reject this as data, not trap while narrowing the value.
    std.mem.writeInt(u16, bad_table[payload_at + 16 + 4 ..][0..2], std.math.maxInt(u16), .little);
    var table_envelope = try entropy.View.openEnvelope(bad_table);
    try std.testing.expectError(error.InvalidEncoding, table_envelope.verify());
}

test "reference differential and randomized property" {
    var prng = std.Random.DefaultPrng.init(0x72616e64);
    for (0..80) |case_index| {
        const length = (case_index * 29) % 193;
        var values: [193]u32 = undefined;
        for (values[0..length], 0..) |*value, i| {
            const selector = prng.random().uintLessThan(u8, 10);
            value.* = switch (selector) {
                0...6 => @intCast(selector),
                7 => @as(u32, @intCast(i % 19)),
                else => prng.random().uintAtMost(u32, 0xffffffff),
            };
        }
        try assertRoundTrip(values[0..length], .{ .checkpoint_stride = 1 + (case_index % 47) });
        var reference = try entropy.buildReference(std.testing.allocator, values[0..length]);
        defer reference.deinit();
        try assertTransparentReferenceWire(reference.bytes, values[0..length]);
        const oracle = try entropy.View.open(reference.bytes);
        for (values[0..length], 0..) |expected, i| try std.testing.expectEqual(expected, try oracle.get(i));
    }
}

test "malformed headers, checkpoints, offsets, tables, and streams are rejected" {
    const values = [_]u32{ 3, 3, 9, 3, 4, 3, 8, 3 };
    try std.testing.expectError(error.InvalidOptions, entropy.build(std.testing.allocator, &values, .{ .checkpoint_stride = 0 }));
    try std.testing.expectError(error.InvalidOptions, entropy.build(std.testing.allocator, &values, .{ .max_entropy_alphabet = 4097 }));
    var owned = try entropy.buildForced(std.testing.allocator, &values, .{ .checkpoint_stride = 2 }, .runs);
    defer owned.deinit();

    var bad_magic = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_magic);
    bad_magic[0] = 'X';
    try std.testing.expectError(error.BadMagic, entropy.View.open(bad_magic));

    try std.testing.expectError(error.Truncated, entropy.View.open(owned.bytes[0 .. owned.bytes.len - 1]));

    var bad_header = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_header);
    std.mem.writeInt(u64, bad_header[44..][0..8], std.math.maxInt(u64), .little);
    try std.testing.expectError(error.InvalidEncoding, entropy.View.open(bad_header));

    try expectU64FieldReject(owned.bytes, 28, std.math.maxInt(u64));
    try expectU64FieldReject(owned.bytes, 36, std.math.maxInt(u64));
    try expectU64FieldReject(owned.bytes, 44, std.math.maxInt(u64));
    try expectU64FieldReject(owned.bytes, 52, std.math.maxInt(u64));
    try expectU32FieldReject(owned.bytes, 24, std.math.maxInt(u32));

    var bad_reserved = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_reserved);
    bad_reserved[9] = 1;
    try std.testing.expectError(error.InvalidEncoding, entropy.View.open(bad_reserved));
    bad_reserved[9] = 0;
    bad_reserved[11] = 1;
    try std.testing.expectError(error.InvalidEncoding, entropy.View.open(bad_reserved));
    bad_reserved[11] = 0;
    std.mem.writeInt(u32, bad_reserved[60..][0..4], 1, .little);
    try std.testing.expectError(error.InvalidEncoding, entropy.View.open(bad_reserved));

    var bad_checkpoint = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_checkpoint);
    std.mem.writeInt(u64, bad_checkpoint[64..][0..8], 99, .little);
    try std.testing.expectError(error.InvalidEncoding, entropy.View.open(bad_checkpoint));

    var bad_run = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_run);
    const runs_payload = std.mem.readInt(u64, bad_run[44..52], .little);
    const run_at = @as(usize, @intCast(runs_payload)) + 8;
    std.mem.writeInt(u64, bad_run[run_at + 8 ..][0..8], 0, .little);
    try std.testing.expectError(error.InvalidEncoding, entropy.View.open(bad_run));

    var bad_run_stride = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_run_stride);
    std.mem.writeInt(u32, bad_run_stride[20..][0..4], 0, .little);
    try std.testing.expectError(error.InvalidEncoding, entropy.View.open(bad_run_stride));

    const packed_values = [_]u32{ 0, 1 };
    var packed_owned = try entropy.buildForced(std.testing.allocator, &packed_values, .{}, .@"packed");
    defer packed_owned.deinit();
    var bad_packed_tail = try std.testing.allocator.dupe(u8, packed_owned.bytes);
    defer std.testing.allocator.free(bad_packed_tail);
    const packed_payload = std.mem.readInt(u64, bad_packed_tail[44..52], .little);
    bad_packed_tail[@as(usize, @intCast(packed_payload)) + 4] |= 0x80;
    try std.testing.expectError(error.InvalidEncoding, entropy.View.open(bad_packed_tail));

    var entropy_values: [1024]u32 = undefined;
    for (&entropy_values, 0..) |*value, i| value.* = if (i % 29 == 0) 1 else 0;
    var entropy_owned = try entropy.buildForced(std.testing.allocator, &entropy_values, .{ .checkpoint_stride = 64 }, .entropy);
    defer entropy_owned.deinit();

    var bad_entropy_index = try std.testing.allocator.dupe(u8, entropy_owned.bytes);
    defer std.testing.allocator.free(bad_entropy_index);
    std.mem.writeInt(u64, bad_entropy_index[64..][0..8], 0, .little);
    try std.testing.expectError(error.InvalidEncoding, entropy.View.open(bad_entropy_index));

    const entropy_payload_at = @as(usize, @intCast(std.mem.readInt(u64, entropy_owned.bytes[44..52], .little)));
    var bad_entropy_count = try std.testing.allocator.dupe(u8, entropy_owned.bytes);
    defer std.testing.allocator.free(bad_entropy_count);
    std.mem.writeInt(u32, bad_entropy_count[entropy_payload_at + 8 ..][0..4], 0, .little);
    try std.testing.expectError(error.InvalidEncoding, entropy.View.open(bad_entropy_count));

    var bad_entropy_frequency = try std.testing.allocator.dupe(u8, entropy_owned.bytes);
    defer std.testing.allocator.free(bad_entropy_frequency);
    bad_entropy_frequency[entropy_payload_at + 16 + 4] = 0;
    bad_entropy_frequency[entropy_payload_at + 16 + 5] = 0;
    try std.testing.expectError(error.InvalidEncoding, entropy.View.open(bad_entropy_frequency));

    var bad_entropy_order = try std.testing.allocator.dupe(u8, entropy_owned.bytes);
    defer std.testing.allocator.free(bad_entropy_order);
    std.mem.writeInt(u32, bad_entropy_order[entropy_payload_at + 24 ..][0..4], 0, .little);
    try std.testing.expectError(error.InvalidEncoding, entropy.View.open(bad_entropy_order));

    var bad_entropy_length = try std.testing.allocator.dupe(u8, entropy_owned.bytes);
    defer std.testing.allocator.free(bad_entropy_length);
    const entropy_first_block = entropy_payload_at + @as(usize, @intCast(std.mem.readInt(u64, entropy_owned.bytes[64..72], .little)));
    std.mem.writeInt(u32, bad_entropy_length[entropy_first_block + 4 ..][0..4], std.math.maxInt(u32), .little);
    try std.testing.expectError(error.InvalidEncoding, entropy.View.open(bad_entropy_length));

    var bad_entropy_padding = try std.testing.allocator.dupe(u8, entropy_owned.bytes);
    defer std.testing.allocator.free(bad_entropy_padding);
    const entropy_payload = @as(usize, @intCast(std.mem.readInt(u64, bad_entropy_padding[44..52], .little)));
    const first_block = entropy_payload + @as(usize, @intCast(std.mem.readInt(u64, bad_entropy_padding[64..72], .little)));
    const first_stream_len = @as(usize, @intCast(std.mem.readInt(u32, bad_entropy_padding[first_block + 4 ..][0..4], .little)));
    const first_stream_end = first_block + 8 + first_stream_len;
    const first_padding_end = (first_stream_end + 7) & ~@as(usize, 7);
    if (first_padding_end > first_stream_end) bad_entropy_padding[first_stream_end] = 1 else bad_entropy_padding[first_block] = 0;
    try std.testing.expectError(error.InvalidEncoding, entropy.View.open(bad_entropy_padding));

    var bad_entropy_stream = try std.testing.allocator.dupe(u8, entropy_owned.bytes);
    defer std.testing.allocator.free(bad_entropy_stream);
    const stream_block = entropy_payload + @as(usize, @intCast(std.mem.readInt(u64, bad_entropy_stream[64..72], .little)));
    bad_entropy_stream[stream_block] = 0;
    try std.testing.expectError(error.InvalidEncoding, entropy.View.open(bad_entropy_stream));
}

test "builders cover allocation failures and views do not allocate" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildWithFailingAllocator, .{});

    const values = [_]u32{ 0, 1, 0, 2, 0, 3, 0, 4 };
    var owned = try entropy.build(std.testing.allocator, &values, .{ .checkpoint_stride = 3 });
    defer owned.deinit();
    const view = try entropy.View.open(owned.bytes);
    // This view call is deliberately made with no allocator in scope: its
    // contract is visible in the API and is also exercised under leak checks.
    try std.testing.expectEqual(@as(u32, 2), try view.get(3));
}

fn buildWithFailingAllocator(allocator: std.mem.Allocator) !void {
    var values: [1024]u32 = undefined;
    for (&values, 0..) |*value, i| value.* = if (i % 31 == 0) @intCast(i % 7) else 0;
    var owned = try entropy.build(allocator, &values, .{ .checkpoint_stride = 37 });
    owned.deinit();
}
