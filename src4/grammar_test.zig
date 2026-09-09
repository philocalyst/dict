//! Focused smoke test for the sole canonical grammar implementation.
//! Hostile source validation, differential tests, and compactness/scaling
//! ledgers live in grammar_adversarial_test.zig.

const std = @import("std");
const grammar = @import("grammar.zig");

test "canonical grammar entrypoint round-trips a borrowed view" {
    const inputs = [_]grammar.ItemInput{
        .{ .text = "canonical prose" },
        .{ .text = "canonical prose" },
    };
    var owned = try grammar.build(std.testing.allocator, &inputs, .{});
    defer owned.deinit();

    var view = try grammar.View.open(owned.bytes, .{});
    try view.verify();
    var output: [32]u8 = undefined;
    const length = try view.extract(1, output[0..]);
    try std.testing.expectEqualSlices(u8, inputs[1].text, output[0..length]);
    try std.testing.expectEqual(@as(?usize, 0), (try view.item(1)).alias);
}
