//! Focused tests for the retained component-ablation evidence producer.
//!
//! These tests deliberately exercise canonical entropy.View operations after
//! envelope reopening and make hostile byte mutation a safety property: a
//! malformed candidate may be rejected at open, verify, or get, but must not
//! cause an unchecked read or panic.

const std = @import("std");
const src4 = @import("src4");
const entropy = src4.entropy;
const ablation = @import("component_ablations.zig");

fn exerciseMutations(bytes: []const u8) !void {
    var mutated = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(mutated);
    const candidate_offsets = [_]usize{ 0, 1, 4, 6, 8, 12, 20, 24, 36, 44, 52, 60, 64 };
    for (candidate_offsets) |index| {
        if (index >= bytes.len) continue;
        const original = bytes[index];
        mutated[index] = original ^ 0xff;
        if (entropy.View.open(mutated)) |view| {
            var mutable_view = view;
            mutable_view.verify() catch {};
            if (view.count() != 0) {
                _ = view.get(0) catch {};
                _ = view.get(view.count() / 2) catch {};
                _ = view.get(view.count() - 1) catch {};
            }
        } else |_| {}
        mutated[index] = original;
    }
    for ([_]usize{ bytes.len / 2, bytes.len - 1 }) |index| {
        if (index >= bytes.len) continue;
        const original = bytes[index];
        mutated[index] = original ^ 0x5a;
        if (entropy.View.open(mutated)) |view| {
            _ = view.get(0) catch {};
        } else |_| {}
        mutated[index] = original;
    }
}

test "entropy-vs-packed retains complete canonical wires and equal semantics" {
    for ([_]ablation.Lane{ .low, .medium, .high }) |lane| {
        const results = try ablation.runLane(std.testing.allocator, lane, 4096, 8, std.testing.io, null);
        try std.testing.expectEqual(entropy.Strategy.entropy, results[0].representation);
        try std.testing.expectEqual(entropy.Strategy.@"packed", results[1].representation);
        try std.testing.expect(results[0].semantic_equal);
        try std.testing.expect(results[1].semantic_equal);
        try std.testing.expect(results[0].reopen_verified);
        try std.testing.expect(results[1].reopen_verified);
        try std.testing.expectEqual(results[0].value_digest, results[1].value_digest);
        try std.testing.expectEqual(results[0].serialized.serialized_bytes, results[0].serialized.header_bytes +
            results[0].serialized.checkpoint_index_bytes + results[0].serialized.alignment_bytes +
            results[0].serialized.payload_bytes);
        try std.testing.expectEqual(results[1].serialized.serialized_bytes, results[1].serialized.header_bytes +
            results[1].serialized.checkpoint_index_bytes + results[1].serialized.alignment_bytes +
            results[1].serialized.payload_bytes);
        try std.testing.expect(results[0].raw_observation_count > 0);
        try std.testing.expect(results[1].raw_observation_count > 0);
    }
}

test "the retained-wire digest and size ledger are deterministic" {
    var generated = try ablation.makeLane(std.testing.allocator, .medium, 1024);
    defer generated.deinit();
    var first = try entropy.buildForced(std.testing.allocator, generated.values, .{ .checkpoint_stride = 64 }, .entropy);
    defer first.deinit();
    var second = try entropy.buildForced(std.testing.allocator, generated.values, .{ .checkpoint_stride = 64 }, .entropy);
    defer second.deinit();
    try std.testing.expectEqualSlices(u8, first.bytes, second.bytes);
    const measured = try ablation.measureWire(first.bytes);
    try std.testing.expectEqual(first.bytes.len, measured.serialized_bytes);
    try std.testing.expectEqual(@as(usize, 64), measured.header_bytes);
    try std.testing.expectEqual(@as(usize, 64), measured.checkpoint_stride);

    // A fresh mapped/reopened slice is what the executable uses for timing;
    // this prevents a test from accidentally validating only Owned.bytes.
    const remapped = try std.testing.allocator.dupe(u8, first.bytes);
    defer std.testing.allocator.free(remapped);
    var view = try entropy.View.openEnvelope(remapped);
    try view.verify();
    const decoded = try std.testing.allocator.alloc(u32, generated.values.len);
    defer std.testing.allocator.free(decoded);
    try view.decode(decoded);
    try std.testing.expectEqualSlices(u32, generated.values, decoded);
}

test "hostile entropy corruption is rejected or remains safe to probe" {
    var generated = try ablation.makeLane(std.testing.allocator, .high, 4096);
    defer generated.deinit();
    var entropy_owned = try entropy.buildForced(std.testing.allocator, generated.values, .{ .checkpoint_stride = 64 }, .entropy);
    defer entropy_owned.deinit();
    try exerciseMutations(entropy_owned.bytes);
    try std.testing.expectError(error.Truncated, entropy.View.open(entropy_owned.bytes[0 .. entropy_owned.bytes.len - 1]));

    var packed_owned = try entropy.buildForced(std.testing.allocator, generated.values, .{ .checkpoint_stride = 64 }, .@"packed");
    defer packed_owned.deinit();
    try exerciseMutations(packed_owned.bytes);
    try std.testing.expectError(error.Truncated, entropy.View.open(packed_owned.bytes[0 .. packed_owned.bytes.len - 1]));
}
