//! Codec selection for independently addressable payload blocks.
//!
//! `.raw` is the default so a caller never pays compression latency or
//! dependency costs by accident.  Builders that have measured a win can opt
//! into `.bzip3`; both variants carry the same original-size contract.

const std = @import("std");
pub const bzip3 = @import("codec/bzip3.zig");
pub const raw = @import("codec/raw.zig");

pub const Kind = enum(u8) {
    raw = 0,
    bzip3 = 1,
};

pub const Error = error{
    InvalidBlockSize,
    InvalidLimit,
    InputTooLarge,
    OriginalSizeTooLarge,
    CompressedSizeTooLarge,
    OutputTooLarge,
    ResourceLimit,
    OutOfMemory,
    AllocationFailed,
    MalformedBlock,
    TruncatedBlock,
    CorruptBlock,
    BufferTooSmall,
    CodecFailure,
};

pub const Options = struct {
    kind: Kind = .raw,
    block_size: usize = bzip3.default_block_size,
    max_uncompressed_bytes: usize = bzip3.max_block_size,
    max_compressed_bytes: usize = bzip3.max_bound_size,
    max_memory_bytes: usize = 64 * 1024 * 1024,

    fn bzip3Options(self: Options) bzip3.Options {
        return .{
            .block_size = self.block_size,
            .max_uncompressed_bytes = self.max_uncompressed_bytes,
            .max_compressed_bytes = self.max_compressed_bytes,
            .max_memory_bytes = self.max_memory_bytes,
        };
    }

    fn rawOptions(self: Options) raw.Options {
        return .{
            .max_uncompressed_bytes = self.max_uncompressed_bytes,
            .max_compressed_bytes = self.max_compressed_bytes,
            .max_memory_bytes = self.max_memory_bytes,
        };
    }
};

pub const OwnedBlock = union(Kind) {
    raw: raw.Block,
    bzip3: bzip3.Block,

    pub fn deinit(self: *OwnedBlock) void {
        switch (self.*) {
            inline else => |*block| block.deinit(),
        }
        self.* = undefined;
    }

    pub fn bytes(self: OwnedBlock) []const u8 {
        return switch (self) {
            inline else => |block| block.data,
        };
    }

    pub fn originalSize(self: OwnedBlock) usize {
        return switch (self) {
            inline else => |block| block.original_size,
        };
    }
};

fn mapBzip3Error(err: bzip3.Error) Error {
    return switch (err) {
        error.InvalidBlockSize => Error.InvalidBlockSize,
        error.InvalidLimit => Error.InvalidLimit,
        error.InputTooLarge => Error.InputTooLarge,
        error.OriginalSizeTooLarge => Error.OriginalSizeTooLarge,
        error.CompressedSizeTooLarge => Error.CompressedSizeTooLarge,
        error.OutputTooLarge => Error.OutputTooLarge,
        error.ResourceLimit => Error.ResourceLimit,
        error.OutOfMemory => Error.OutOfMemory,
        error.AllocationFailed => Error.AllocationFailed,
        error.MalformedBlock => Error.MalformedBlock,
        error.TruncatedBlock => Error.TruncatedBlock,
        error.CorruptBlock => Error.CorruptBlock,
        error.BufferTooSmall => Error.BufferTooSmall,
        error.CodecFailure => Error.CodecFailure,
    };
}

fn mapRawError(err: raw.Error) Error {
    return switch (err) {
        error.InputTooLarge => Error.InputTooLarge,
        error.OutputTooLarge => Error.OutputTooLarge,
        error.InvalidLimit => Error.InvalidLimit,
        error.ResourceLimit => Error.ResourceLimit,
        error.OutOfMemory => Error.OutOfMemory,
        error.MalformedBlock => Error.MalformedBlock,
    };
}

pub fn encodeBlock(allocator: std.mem.Allocator, input: []const u8, options: Options) Error!OwnedBlock {
    return switch (options.kind) {
        .raw => .{ .raw = raw.encodeBlock(allocator, input, options.rawOptions()) catch |err| return mapRawError(err) },
        .bzip3 => .{ .bzip3 = bzip3.encodeBlock(allocator, input, options.bzip3Options()) catch |err| return mapBzip3Error(err) },
    };
}

pub fn decodeBlock(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    original_size: usize,
    options: Options,
) Error!OwnedBlock {
    return switch (options.kind) {
        .raw => .{ .raw = raw.decodeBlock(allocator, encoded, original_size, options.rawOptions()) catch |err| return mapRawError(err) },
        .bzip3 => .{ .bzip3 = bzip3.decodeBlock(allocator, encoded, original_size, options.bzip3Options()) catch |err| return mapBzip3Error(err) },
    };
}

test "raw and bzip3 preserve identical semantic payloads" {
    var input: [140_000]u8 = undefined;
    for (&input, 0..) |*byte, index| {
        byte.* = if (index % 13 < 9) 'e' else @intCast((index * 73 + 19) & 0xff);
    }

    var raw_block = try encodeBlock(std.testing.allocator, input[0..], .{});
    defer raw_block.deinit();
    var bzip_block = try encodeBlock(std.testing.allocator, input[0..], .{ .kind = .bzip3 });
    defer bzip_block.deinit();

    var raw_decoded = try decodeBlock(std.testing.allocator, raw_block.bytes(), raw_block.originalSize(), .{});
    defer raw_decoded.deinit();
    var bzip_decoded = try decodeBlock(std.testing.allocator, bzip_block.bytes(), bzip_block.originalSize(), .{ .kind = .bzip3 });
    defer bzip_decoded.deinit();
    try std.testing.expectEqualSlices(u8, input[0..], raw_decoded.bytes());
    try std.testing.expectEqualSlices(u8, input[0..], bzip_decoded.bytes());
}

test "the default codec is an explicit raw fallback" {
    const block = try encodeBlock(std.testing.allocator, "fallback", .{});
    var owned = block;
    defer owned.deinit();
    try std.testing.expectEqual(@as(Kind, .raw), std.meta.activeTag(owned));
    try std.testing.expectEqualSlices(u8, "fallback", owned.bytes());
}
