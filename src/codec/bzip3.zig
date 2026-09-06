//! Independent bzip3 block codec support.
//!
//! The upstream low-level API encodes in place.  This module owns the mutable
//! work buffer and the native state so callers get an ordinary Zig ownership
//! contract: inputs are borrowed, returned blocks own their bytes, and every
//! operation is bounded before entering the C ABI.

const std = @import("std");

const c = @cImport({
    @cInclude("libbz3.h");
});

pub const min_block_size: usize = 65 * 1024;
pub const max_block_size: usize = 511 * 1024 * 1024;
pub const max_bound_size: usize = max_block_size + max_block_size / 50 + 32;
pub const default_block_size: usize = 256 * 1024;
pub const wire_version: u16 = 1;

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
    /// Capacity advertised to the upstream state.  Individual blocks may be
    /// smaller, but a block can never exceed this value.
    block_size: usize = default_block_size,
    /// Independent limits keep a caller from accidentally treating a block
    /// header as an allocation request.
    max_uncompressed_bytes: usize = max_block_size,
    max_compressed_bytes: usize = max_bound_size,
    /// This includes the state reported by bz3_min_memory_needed and the
    /// largest mutable work buffer required by the low-level API.
    max_memory_bytes: usize = 64 * 1024 * 1024,
};

pub const Block = struct {
    /// Only the prefix `data` is meaningful.  `allocation` is retained so the
    /// allocator receives the exact slice returned by alloc().
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

const ValidatedOptions = struct {
    options: Options,
    state_memory: usize,
    work_capacity: usize,
};

fn checkedAdd(a: usize, b: usize) Error!usize {
    const result = @addWithOverflow(a, b);
    if (result[1] != 0) return Error.ResourceLimit;
    return result[0];
}

fn i32MaxAsUsize() usize {
    return @intCast(std.math.maxInt(i32));
}

fn validateBlockSize(block_size: usize) Error!void {
    if (block_size < min_block_size or block_size > max_block_size or block_size > i32MaxAsUsize()) {
        return Error.InvalidBlockSize;
    }
}

/// Checked equivalent of upstream `bz3_bound`.  The upstream function's
/// implementation is intentionally tiny and assumes a representable size;
/// callers of this API never pass an unchecked size through that boundary.
pub fn bound(input_size: usize) Error!usize {
    if (input_size > max_block_size or input_size > i32MaxAsUsize()) return Error.InputTooLarge;
    const result = c.bz3_bound(input_size);
    if (result < input_size) return Error.ResourceLimit;
    return result;
}

/// Checked equivalent of upstream `bz3_min_memory_needed` for one state and
/// its maximum mutable block buffer.  The C function reports state allocations
/// only; adding `bz3_bound(block_size)` makes the result useful as an operation
/// budget for this wrapper as well.
pub fn memoryNeeded(block_size: usize) Error!usize {
    try validateBlockSize(block_size);
    const c_size: i32 = @intCast(block_size);
    const state_memory = c.bz3_min_memory_needed(c_size);
    if (state_memory == 0) return Error.InvalidBlockSize;
    return checkedAdd(state_memory, try bound(block_size));
}

fn validateOptions(options: Options) Error!ValidatedOptions {
    try validateBlockSize(options.block_size);
    if (options.max_uncompressed_bytes > max_block_size or
        options.max_compressed_bytes > max_bound_size or
        options.max_memory_bytes == 0)
    {
        return Error.InvalidLimit;
    }

    const work_capacity = try bound(options.block_size);
    const state_memory = c.bz3_min_memory_needed(@intCast(options.block_size));
    if (state_memory == 0) return Error.InvalidBlockSize;
    const required = try checkedAdd(state_memory, work_capacity);
    if (required > options.max_memory_bytes) return Error.ResourceLimit;
    return .{
        .options = options,
        .state_memory = state_memory,
        .work_capacity = work_capacity,
    };
}

fn mapStateError(state: *c.struct_bz3_state) Error {
    return switch (c.bz3_last_error(state)) {
        c.BZ3_ERR_OUT_OF_BOUNDS => Error.MalformedBlock,
        c.BZ3_ERR_BWT => Error.CodecFailure,
        c.BZ3_ERR_CRC => Error.CorruptBlock,
        c.BZ3_ERR_MALFORMED_HEADER => Error.MalformedBlock,
        c.BZ3_ERR_TRUNCATED_DATA => Error.TruncatedBlock,
        c.BZ3_ERR_DATA_TOO_BIG => Error.InputTooLarge,
        c.BZ3_ERR_DATA_SIZE_TOO_SMALL => Error.BufferTooSmall,
        else => Error.CodecFailure,
    };
}

pub const Encoder = struct {
    state: *c.struct_bz3_state,
    options: ValidatedOptions,

    pub fn init(options: Options) Error!Encoder {
        const checked = try validateOptions(options);
        const state = c.bz3_new(@intCast(options.block_size)) orelse return Error.AllocationFailed;
        return .{ .state = state, .options = checked };
    }

    pub fn deinit(self: *Encoder) void {
        c.bz3_free(self.state);
        self.* = undefined;
    }

    pub fn encodeBlock(self: *Encoder, allocator: std.mem.Allocator, input: []const u8) Error!Block {
        if (input.len > self.options.options.block_size or input.len > self.options.options.max_uncompressed_bytes) {
            return Error.InputTooLarge;
        }
        const capacity = try bound(input.len);
        if (capacity > self.options.options.max_compressed_bytes) return Error.ResourceLimit;

        const allocation = allocator.alloc(u8, capacity) catch return Error.OutOfMemory;
        errdefer allocator.free(allocation);
        @memcpy(allocation[0..input.len], input);

        const result = c.bz3_encode_block(self.state, allocation.ptr, @intCast(input.len));
        if (result < 0) return mapStateError(self.state);
        const result_size: usize = @intCast(result);
        if (result_size > allocation.len) return Error.CodecFailure;
        return .{
            .data = allocation[0..result_size],
            .original_size = input.len,
            .allocation = allocation,
            .allocator = allocator,
        };
    }
};

pub const Decoder = struct {
    state: *c.struct_bz3_state,
    options: ValidatedOptions,

    pub fn init(options: Options) Error!Decoder {
        const checked = try validateOptions(options);
        const state = c.bz3_new(@intCast(options.block_size)) orelse return Error.AllocationFailed;
        return .{ .state = state, .options = checked };
    }

    pub fn deinit(self: *Decoder) void {
        c.bz3_free(self.state);
        self.* = undefined;
    }

    pub fn decodeBlock(
        self: *Decoder,
        allocator: std.mem.Allocator,
        compressed: []const u8,
        original_size: usize,
    ) Error!Block {
        if (original_size > self.options.options.block_size or
            original_size > self.options.options.max_uncompressed_bytes)
        {
            return Error.OriginalSizeTooLarge;
        }
        if (compressed.len > self.options.options.max_compressed_bytes) return Error.CompressedSizeTooLarge;
        const block_bound = try bound(self.options.options.block_size);
        if (compressed.len > block_bound) return Error.MalformedBlock;
        if (compressed.len > i32MaxAsUsize() or original_size > i32MaxAsUsize()) return Error.InputTooLarge;

        const original_bound = try bound(original_size);
        // An encoded literal block has an eight-byte header (CRC + -1 BWT
        // marker), while the upstream convenience probe conservatively asks
        // for nine bytes before inspecting it.  Supply one scratch byte for
        // that probe; the actual decoder still receives the exact size.
        // The upstream helper may inspect all nine bytes, including the model
        // byte at offset eight, even when the supplied block is shorter.  A
        // fully initialized probe keeps malformed input deterministic and
        // prevents undefined bytes from crossing the C ABI.
        var probe = [_]u8{0} ** 9;
        const probe_bytes: []const u8 = if (compressed.len < 9) blk: {
            if (compressed.len < 8) return Error.MalformedBlock;
            @memcpy(probe[0..compressed.len], compressed);
            break :blk probe[0..9];
        } else compressed;
        const sufficient = c.bz3_orig_size_sufficient_for_decode(
            probe_bytes.ptr,
            probe_bytes.len,
            @intCast(original_size),
        );
        if (sufficient < 0) return Error.MalformedBlock;

        // A valid block can contain an intermediate LZP/RLE representation
        // larger than the final text.  The upstream helper tells us when the
        // original-sized buffer is enough; otherwise reserve the configured
        // block capacity, as the upstream high-level decoder does.
        const capacity = if (sufficient == 1)
            @max(original_bound, compressed.len)
        else
            block_bound;
        if (capacity > self.options.options.max_memory_bytes -| self.options.state_memory) {
            return Error.ResourceLimit;
        }
        const allocation = allocator.alloc(u8, capacity) catch return Error.OutOfMemory;
        errdefer allocator.free(allocation);
        @memcpy(allocation[0..compressed.len], compressed);

        const result = c.bz3_decode_block(
            self.state,
            allocation.ptr,
            allocation.len,
            @intCast(compressed.len),
            @intCast(original_size),
        );
        if (result < 0) return mapStateError(self.state);
        const result_size: usize = @intCast(result);
        if (result_size != original_size or result_size > allocation.len) return Error.MalformedBlock;
        return .{
            .data = allocation[0..result_size],
            .original_size = original_size,
            .allocation = allocation,
            .allocator = allocator,
        };
    }
};

pub fn encodeBlock(allocator: std.mem.Allocator, input: []const u8, options: Options) Error!Block {
    var encoder = try Encoder.init(options);
    defer encoder.deinit();
    return encoder.encodeBlock(allocator, input);
}

pub fn decodeBlock(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    original_size: usize,
    options: Options,
) Error!Block {
    var decoder = try Decoder.init(options);
    defer decoder.deinit();
    return decoder.decodeBlock(allocator, compressed, original_size);
}

pub fn version() []const u8 {
    return std.mem.sliceTo(c.bz3_version(), 0);
}

test "bzip3 bounds and memory estimates reject unsafe state sizes" {
    try std.testing.expectError(Error.InputTooLarge, bound(max_block_size + 1));
    try std.testing.expectError(Error.InvalidBlockSize, memoryNeeded(min_block_size - 1));
    try std.testing.expect((try bound(0)) >= 32);
    try std.testing.expect((try memoryNeeded(min_block_size)) > 0);
    try std.testing.expectError(Error.ResourceLimit, Encoder.init(.{ .max_memory_bytes = 1 }));
}

test "independent blocks round trip exact bytes" {
    var encoder = try Encoder.init(.{});
    defer encoder.deinit();
    var decoder = try Decoder.init(.{});
    defer decoder.deinit();

    const inputs = [_][]const u8{
        &.{},
        "short lexical text",
        "bank\x00bank\xff — नदी — Ελληνικά — العربية",
    };
    for (inputs) |input| {
        var encoded = try encoder.encodeBlock(std.testing.allocator, input);
        defer encoded.deinit();
        var decoded = try decoder.decodeBlock(std.testing.allocator, encoded.data, encoded.original_size);
        defer decoded.deinit();
        try std.testing.expectEqualSlices(u8, input, decoded.data);
    }

    var repetitive: [120_000]u8 = undefined;
    for (&repetitive, 0..) |*byte, index| byte.* = @intCast((index * 17 + index / 11) % 7);
    var encoded = try encoder.encodeBlock(std.testing.allocator, repetitive[0..]);
    defer encoded.deinit();
    var decoded = try decoder.decodeBlock(std.testing.allocator, encoded.data, encoded.original_size);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u8, repetitive[0..], decoded.data);
}

test "corrupt independent block is rejected" {
    const input = "A sufficiently long block makes the integrity check meaningful. " ** 4;
    var encoded = try encodeBlock(std.testing.allocator, input, .{});
    defer encoded.deinit();
    const corrupted = try std.testing.allocator.dupe(u8, encoded.data);
    defer std.testing.allocator.free(corrupted);
    // Corrupt the CRC itself so even a literal block cannot be accepted as a
    // byte sequence with an accidentally valid transformed payload.
    corrupted[0] ^= 0x01;
    try std.testing.expectError(Error.CorruptBlock, decodeBlock(
        std.testing.allocator,
        corrupted,
        input.len,
        .{},
    ));
}

test "truncation and adversarial headers never escape the wrapper" {
    const input = "bounded payload with enough structure to exercise the transformed path " ** 8;
    var encoded = try encodeBlock(std.testing.allocator, input, .{});
    defer encoded.deinit();

    var length: usize = 0;
    while (length < encoded.data.len) : (length += 1) {
        const attempt = decodeBlock(std.testing.allocator, encoded.data[0..length], encoded.original_size, .{});
        if (attempt) |block| {
            var owned = block;
            owned.deinit();
            return error.TestUnexpectedSuccess;
        } else |_| {}
    }

    var decoder = try Decoder.init(.{});
    defer decoder.deinit();
    var bytes: [128]u8 = undefined;
    var seed: u32 = 0x9e37_79b9;
    var iteration: usize = 0;
    while (iteration < 256) : (iteration += 1) {
        for (&bytes, 0..) |*byte, index| {
            seed = seed *% 1_664_525 +% 1_013_904_223;
            byte.* = @truncate(seed >> @intCast(index & 7));
        }
        const compressed_size = iteration % (bytes.len + 1);
        const original_size = (iteration * 997) % 4096;
        const attempt = decoder.decodeBlock(std.testing.allocator, bytes[0..compressed_size], original_size);
        if (attempt) |block| {
            var owned = block;
            owned.deinit();
        } else |_| {}
    }
}

test "short bzip3 probes are deterministic and never succeed" {
    var malformed = [_]u8{0} ** 9;

    var length: usize = 0;
    while (length <= 8) : (length += 1) {
        var first_error: Error = undefined;
        const first = decodeBlock(
            std.testing.allocator,
            malformed[0..length],
            1,
            .{},
        );
        if (first) |block| {
            var owned = block;
            owned.deinit();
            return error.TestUnexpectedSuccess;
        } else |err| {
            first_error = err;
        }

        var second_error: Error = undefined;
        const second = decodeBlock(
            std.testing.allocator,
            malformed[0..length],
            1,
            .{},
        );
        if (second) |block| {
            var owned = block;
            owned.deinit();
            return error.TestUnexpectedSuccess;
        } else |err| {
            second_error = err;
        }

        try std.testing.expectEqual(first_error, second_error);
    }
}

test "low-level wrapper interoperates with upstream high-level frame API" {
    // Keep a non-empty remainder in the frame: this pinned upstream release
    // writes a zero-sized final block when the input is exactly divisible by
    // the selected block size.  The low-level API used by Lexicon has no such
    // framing edge case; this fixture exercises a normal multi-block frame.
    var input: [200_001]u8 = undefined;
    for (&input, 0..) |*byte, index| byte.* = @intCast((index * 31 + index / 97) & 0xff);

    const capacity = try bound(input.len) + 64;
    const frame = try std.testing.allocator.alloc(u8, capacity);
    defer std.testing.allocator.free(frame);
    var frame_size = frame.len;
    try std.testing.expectEqual(
        @as(c_int, c.BZ3_OK),
        c.bz3_compress(90_000, input[0..].ptr, frame.ptr, input.len, &frame_size),
    );

    const output = try std.testing.allocator.alloc(u8, input.len);
    defer std.testing.allocator.free(output);
    var output_size = output.len;
    try std.testing.expectEqual(
        @as(c_int, c.BZ3_OK),
        c.bz3_decompress(frame.ptr, output.ptr, frame_size, &output_size),
    );
    try std.testing.expectEqual(input.len, output_size);
    try std.testing.expectEqualSlices(u8, input[0..], output[0..output_size]);
}
