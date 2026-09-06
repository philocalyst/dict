//! The deliberately boring codec used for tiny or latency-critical payloads.
//!
//! Raw blocks are still modeled as blocks with an explicit original size.  A
//! caller can therefore switch between `.raw` and `.bzip3` without changing
//! ownership, bounds, or semantic equality rules.

const std = @import("std");

pub const wire_version: u16 = 1;

pub const Error = error{
    InputTooLarge,
    OutputTooLarge,
    InvalidLimit,
    ResourceLimit,
    OutOfMemory,
    MalformedBlock,
};

pub const Options = struct {
    max_uncompressed_bytes: usize = std.math.maxInt(usize),
    max_compressed_bytes: usize = std.math.maxInt(usize),
    max_memory_bytes: usize = std.math.maxInt(usize),
};

pub const Block = struct {
    data: []const u8,
    original_size: usize,
    allocation: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Block) void {
        self.allocator.free(self.allocation);
        self.* = undefined;
    }

    pub fn compressedSize(self: Block) usize {
        return self.data.len;
    }
};

pub fn bound(input_size: usize) usize {
    return input_size;
}

pub fn encodeBlock(allocator: std.mem.Allocator, input: []const u8, options: Options) Error!Block {
    if (input.len > options.max_uncompressed_bytes) return Error.InputTooLarge;
    if (input.len > options.max_compressed_bytes or input.len > options.max_memory_bytes) {
        return Error.ResourceLimit;
    }
    const allocation = allocator.dupe(u8, input) catch return Error.OutOfMemory;
    return .{
        .data = allocation,
        .original_size = input.len,
        .allocation = allocation,
        .allocator = allocator,
    };
}

pub fn decodeBlock(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    original_size: usize,
    options: Options,
) Error!Block {
    if (original_size > options.max_uncompressed_bytes) return Error.InputTooLarge;
    if (compressed.len > options.max_compressed_bytes or compressed.len > options.max_memory_bytes) {
        return Error.ResourceLimit;
    }
    if (compressed.len != original_size) return Error.MalformedBlock;
    const allocation = allocator.dupe(u8, compressed) catch return Error.OutOfMemory;
    return .{
        .data = allocation,
        .original_size = original_size,
        .allocation = allocation,
        .allocator = allocator,
    };
}

test "raw blocks are exact and bounded" {
    const input = "raw fallback preserves every byte\x00\xff";
    var encoded = try encodeBlock(std.testing.allocator, input, .{});
    defer encoded.deinit();
    try std.testing.expectEqual(input.len, encoded.compressedSize());
    var decoded = try decodeBlock(std.testing.allocator, encoded.data, encoded.original_size, .{});
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u8, input, decoded.data);
    try std.testing.expectError(Error.MalformedBlock, decodeBlock(std.testing.allocator, encoded.data, input.len + 1, .{}));
    try std.testing.expectError(Error.ResourceLimit, encodeBlock(std.testing.allocator, input, .{ .max_memory_bytes = 1 }));
}
