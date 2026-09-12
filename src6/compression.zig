//! Bounded, independently addressable raw and bzip3 blocks.
//!
//! The bzip3 path deliberately uses the low-level libbz3 API.  A block is
//! copied into caller-owned mutable storage, encoded or decoded in place, and
//! then shrunk to the exact number of bytes returned by libbz3.  The upstream
//! state itself is still allocated by C; the admission check accounts for it
//! before crossing that ABI.

const std = @import("std");

const c = @cImport({
    @cInclude("libbz3.h");
});

pub const Codec = enum(u8) {
    raw,
    bzip3,
};

pub const Mode = enum {
    raw,
    adaptive,
    bzip3,
};

pub const Limits = struct {
    max_block_bytes: usize = 1024 * 1024,
    max_memory_bytes: usize = 64 * 1024 * 1024,
};

pub const Error = error{
    InvalidLimit,
    InputTooLarge,
    CompressedTooLarge,
    OriginalSizeTooLarge,
    RawLengthMismatch,
    ResourceLimit,
    OutOfMemory,
    AllocationFailed,
    MalformedBlock,
    TruncatedBlock,
    CorruptBlock,
    BufferTooSmall,
    CodecFailure,
    OutputSizeMismatch,
};

pub const Block = struct {
    allocator: std.mem.Allocator,
    allocation: []u8,
    bytes: []const u8,
    codec: Codec,
    raw_len: usize,

    pub fn deinit(self: *Block) void {
        self.allocator.free(self.allocation);
        self.* = undefined;
    }
};

/// libbz3's state accepts blocks in this range. `Limits.max_block_bytes`
/// caps both the logical payload and the native state size, so callers using
/// bzip3 for short payloads still need a cap at least as large as this floor.
pub const min_native_block_bytes: usize = 65 * 1024;
pub const max_native_block_bytes: usize = 511 * 1024 * 1024;

/// This is a conservative allowance for temporary native allocations (and
/// their alignment slack) in the pinned single-thread libsais BWT/un-BWT
/// calls.  It is intentionally charged to the admission budget even though
/// those mallocs cannot use a Zig allocator.
pub const libsais_accounted_bytes: usize = 1024 * 1024;

const max_native_i32: usize = @intCast(std.math.maxInt(i32));

fn checkedAdd(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch Error.ResourceLimit;
}

/// Return the checked low-level block bound from the pinned upstream API.
pub fn bound(input_size: usize) Error!usize {
    if (input_size > max_native_block_bytes or input_size > max_native_i32) {
        return Error.InputTooLarge;
    }
    return checkedAdd(try checkedAdd(input_size, input_size / 50), 32);
}

fn stateBlockSize(raw_len: usize, limits: Limits) Error!usize {
    if (raw_len > limits.max_block_bytes or raw_len > max_native_block_bytes or raw_len > max_native_i32) {
        return Error.InputTooLarge;
    }

    const state_size = @max(raw_len, min_native_block_bytes);
    if (state_size > limits.max_block_bytes) return Error.ResourceLimit;
    if (state_size > max_native_block_bytes or state_size > max_native_i32) {
        return Error.InputTooLarge;
    }
    return state_size;
}

fn cStateMemory(state_size: usize) Error!usize {
    const result = c.bz3_min_memory_needed(@intCast(state_size));
    if (result == 0) return Error.AllocationFailed;
    return result;
}

fn checkMemoryBudget(state_size: usize, work_capacity: usize, limits: Limits) Error!void {
    var required = try checkedAdd(try cStateMemory(state_size), work_capacity);
    required = try checkedAdd(required, libsais_accounted_bytes);
    if (required > limits.max_memory_bytes) return Error.ResourceLimit;
}

fn mapNativeError(state: *c.struct_bz3_state) Error {
    return switch (c.bz3_last_error(state)) {
        c.BZ3_OK => Error.CodecFailure,
        c.BZ3_ERR_OUT_OF_BOUNDS => Error.MalformedBlock,
        c.BZ3_ERR_BWT => Error.CodecFailure,
        c.BZ3_ERR_CRC => Error.CorruptBlock,
        c.BZ3_ERR_MALFORMED_HEADER => Error.MalformedBlock,
        c.BZ3_ERR_TRUNCATED_DATA => Error.TruncatedBlock,
        c.BZ3_ERR_DATA_TOO_BIG => Error.InputTooLarge,
        c.BZ3_ERR_INIT => Error.AllocationFailed,
        c.BZ3_ERR_DATA_SIZE_TOO_SMALL => Error.BufferTooSmall,
        else => Error.CodecFailure,
    };
}

fn rawBlock(allocator: std.mem.Allocator, input: []const u8, limits: Limits) Error!Block {
    if (input.len > limits.max_block_bytes) return Error.InputTooLarge;
    if (input.len > limits.max_memory_bytes) return Error.ResourceLimit;

    const allocation = allocator.dupe(u8, input) catch return Error.OutOfMemory;
    return .{
        .allocator = allocator,
        .allocation = allocation,
        .bytes = allocation,
        .codec = .raw,
        .raw_len = input.len,
    };
}

fn encodeBzip3(allocator: std.mem.Allocator, input: []const u8, limits: Limits) Error!Block {
    const state_size = try stateBlockSize(input.len, limits);
    const work_capacity = try bound(input.len);
    try checkMemoryBudget(state_size, work_capacity, limits);

    var allocation = allocator.alloc(u8, work_capacity) catch return Error.OutOfMemory;
    errdefer allocator.free(allocation);
    @memcpy(allocation[0..input.len], input);

    const state = c.bz3_new(@intCast(state_size)) orelse return Error.AllocationFailed;
    defer c.bz3_free(state);

    const result = c.bz3_encode_block(state, allocation.ptr, @intCast(input.len));
    if (result < 0) return mapNativeError(state);
    if (c.bz3_last_error(state) != c.BZ3_OK) return mapNativeError(state);

    const encoded_len: usize = @intCast(result);
    if (encoded_len < 8 or encoded_len > work_capacity) return Error.CodecFailure;

    allocation = allocator.realloc(allocation, encoded_len) catch return Error.OutOfMemory;
    return .{
        .allocator = allocator,
        .allocation = allocation,
        .bytes = allocation,
        .codec = .bzip3,
        .raw_len = input.len,
    };
}

fn readI32Little(bytes: []const u8) i32 {
    return @bitCast(std.mem.readInt(u32, bytes[0..4], .little));
}

fn decodeBzip3(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    raw_len: usize,
    limits: Limits,
) Error!Block {
    const state_size = try stateBlockSize(raw_len, limits);
    if (compressed.len < 8) return Error.TruncatedBlock;

    // A valid low-level block is bounded by the original block's bound.  This
    // check also prevents a hostile compressed length from selecting a large
    // temporary allocation before libbz3 sees the header.
    const raw_bound = try bound(raw_len);
    if (compressed.len > raw_bound) return Error.CompressedTooLarge;

    // The low-level C decoder reads the model byte at offset eight.  An
    // eight-byte block can only be the literal form (CRC + -1 BWT index); do
    // not let C inspect a byte that was not supplied by the caller.
    if (compressed.len == 8 and readI32Little(compressed[4..8]) != -1) {
        return Error.TruncatedBlock;
    }

    const state_bound = try bound(state_size);
    var work_capacity = raw_bound;
    if (compressed.len >= 9) {
        // Literal blocks have no model byte: their payload starts at offset
        // eight.  Only transformed blocks carry the model/reserved bits.
        const bwt_index = readI32Little(compressed[4..8]);
        if (bwt_index < -1) return Error.MalformedBlock;
        if (bwt_index != -1 and (compressed[8] & ~@as(u8, 6)) != 0) {
            return Error.MalformedBlock;
        }

        // This upstream helper is safe only after its documented minimum
        // header has arrived.  A negative result is a malformed/truncated
        // header, not permission to pass uninitialized padding to C.
        const sufficient = c.bz3_orig_size_sufficient_for_decode(
            compressed.ptr,
            compressed.len,
            @intCast(raw_len),
        );
        if (sufficient < 0) return Error.MalformedBlock;
        if (sufficient == 0) work_capacity = state_bound;
    }

    if (work_capacity < compressed.len or work_capacity < 9) return Error.BufferTooSmall;
    try checkMemoryBudget(state_size, work_capacity, limits);

    var allocation = allocator.alloc(u8, work_capacity) catch return Error.OutOfMemory;
    errdefer allocator.free(allocation);
    @memcpy(allocation[0..compressed.len], compressed);
    // Keep the byte past an eight-byte literal initialized even though the
    // validated BWT marker means the C decoder will not consume it.
    if (compressed.len == 8) allocation[8] = 0;

    const state = c.bz3_new(@intCast(state_size)) orelse return Error.AllocationFailed;
    defer c.bz3_free(state);

    const result = c.bz3_decode_block(
        state,
        allocation.ptr,
        allocation.len,
        @intCast(compressed.len),
        @intCast(raw_len),
    );
    if (result < 0) return mapNativeError(state);
    if (c.bz3_last_error(state) != c.BZ3_OK) return mapNativeError(state);

    const decoded_len: usize = @intCast(result);
    if (decoded_len > allocation.len) return Error.CodecFailure;
    if (decoded_len != raw_len) return Error.OutputSizeMismatch;

    allocation = allocator.realloc(allocation, raw_len) catch return Error.OutOfMemory;
    return .{
        .allocator = allocator,
        .allocation = allocation,
        .bytes = allocation,
        .codec = .bzip3,
        .raw_len = raw_len,
    };
}

pub fn encode(
    allocator: std.mem.Allocator,
    input: []const u8,
    mode: Mode,
    limits: Limits,
) Error!Block {
    return switch (mode) {
        .raw => rawBlock(allocator, input, limits),
        .bzip3 => encodeBzip3(allocator, input, limits),
        .adaptive => blk: {
            const compressed = encodeBzip3(allocator, input, limits) catch |err| switch (err) {
                // A caller-declared resource ceiling is an allowed reason for
                // adaptive mode to retain the raw bytes.  Invalid data,
                // allocator failure, and native codec failures remain errors.
                error.ResourceLimit => break :blk rawBlock(allocator, input, limits),
                else => return err,
            };
            if (compressed.bytes.len >= input.len) {
                var discarded = compressed;
                discarded.deinit();
                break :blk rawBlock(allocator, input, limits);
            }
            break :blk compressed;
        },
    };
}

pub fn decode(
    allocator: std.mem.Allocator,
    codec: Codec,
    input: []const u8,
    raw_len: usize,
    limits: Limits,
) Error!Block {
    return switch (codec) {
        .raw => blk: {
            if (input.len != raw_len) break :blk Error.RawLengthMismatch;
            break :blk rawBlock(allocator, input, limits);
        },
        .bzip3 => decodeBzip3(allocator, input, raw_len, limits),
    };
}
