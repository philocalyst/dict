const std = @import("std");
const bz4 = @import("bz4");
const Budget = @import("decoder_budget.zig").Budget;

// A 12-byte arithmetic-coded native header declares log=13,
// buckets=2046, rows=32768, alphabet=2048. It passes v4's scalar limits,
// and old Model.init immediately requests norm+next tables totaling 256 MiB.
// No payload block is needed to reach those requests.
const wide_header_frame = "bz4\x03\x0c" ++
    "\x00\xdf\xfd\xff\x68\xfa\x47\xd7\xc0\x00\x00\x00" ++ "\x00";

test "wide native header returns OutOfMemory and frees every request" {
    var budget: Budget = .{ .parent = std.testing.allocator, .limit = 64 * 1024 * 1024 };
    try std.testing.expectError(error.OutOfMemory,
        bz4.Decoder.init(budget.allocator(), wide_header_frame));
    try std.testing.expectEqual(@as(usize, 0), budget.live);
    try std.testing.expect(budget.peak < budget.limit);
}
