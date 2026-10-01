//! bz3base: the authoritative bzip3 control for the bz4 lab (Lane D).
//!
//! Splits FILE into independent blocks of BLOCK_BYTES (last block shorter;
//! BLOCK_BYTES=0 means the whole file as one block), encodes every block
//! with bz3_encode_block using ONE retained encoder state, keeps the
//! encoded blocks in memory, verifies a full decode roundtrip with ONE
//! retained decoder state, then times REPEATS additional full-decode
//! passes (memcpy of the encoded block into the work buffer included,
//! verification excluded from the clock) and reports the min and median.
//!
//! usage: bz3base FILE BLOCK_BYTES [REPEATS]
//!
//! Prints one TSV line (no header):
//!   file  block_bytes  block_count  payload_bytes  total_bytes
//!   encode_ms  decode_min_ms  decode_median_ms  decode_MBps
//!
//! total_bytes = 32 + 16*block_count + payload_bytes, the frozen bz4
//! frame-accounting protocol (32-byte header + one 16-byte directory
//! record per block + the encoded payload).
//!
//! This is the ONLY file in the bz4 lab allowed to touch C: it links the
//! vendored libbz3.c directly as the control bzip3 is measured against,
//! not as a codec any bz4 lane may depend on.

const std = @import("std");

const c = @cImport({
    @cInclude("libbz3.h");
});

/// libbz3 accepts state/block sizes only in [65 KiB, 511 MiB]. See
/// src6/compression.zig `min_native_block_bytes` (the production code's own
/// name for this same floor) and libbz3.h `bz3_new`.
const min_native_block_bytes: usize = 65 * 1024;

const directory_record_bytes: usize = 16;
const header_bytes: usize = 32;

const Timer = struct {
    io: std.Io,
    started: i96,

    fn start(io: std.Io) Timer {
        return .{ .io = io, .started = std.Io.Clock.awake.now(io).nanoseconds };
    }

    fn read(self: Timer) u64 {
        const value = std.Io.Clock.awake.now(self.io).nanoseconds - self.started;
        return @intCast(@max(@as(i96, 0), value));
    }
};

fn usage() void {
    std.debug.print("usage: bz3base FILE BLOCK_BYTES [REPEATS]\n", .{});
}

/// Byte range [start, start+len) of block `index` under a fixed nominal
/// block size. The final block is shorter when the file does not divide
/// evenly; BLOCK_BYTES=0 is handled by the caller passing
/// nominal_block_bytes == input.len (a single block spanning the file).
fn blockRange(input_len: usize, nominal_block_bytes: usize, index: usize) struct { start: usize, len: usize } {
    const start = index * nominal_block_bytes;
    const len = @min(input_len - start, nominal_block_bytes);
    return .{ .start = start, .len = len };
}

fn medianU64(sorted_ascending: []const u64) f64 {
    const n = sorted_ascending.len;
    if (n % 2 == 1) return @floatFromInt(sorted_ascending[n / 2]);
    const lo: f64 = @floatFromInt(sorted_ascending[n / 2 - 1]);
    const hi: f64 = @floatFromInt(sorted_ascending[n / 2]);
    return (lo + hi) / 2.0;
}

fn lessThanU64(_: void, a: u64, b: u64) bool {
    return a < b;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const path = it.next() orelse {
        usage();
        return error.Usage;
    };
    const block_bytes_arg = std.fmt.parseUnsigned(usize, it.next() orelse {
        usage();
        return error.Usage;
    }, 10) catch {
        usage();
        return error.Usage;
    };
    const repeats_arg = it.next();
    const repeats: usize = if (repeats_arg) |r| try std.fmt.parseUnsigned(usize, r, 10) else 5;
    if (repeats == 0) return error.Usage;

    const input = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 30));
    defer alloc.free(input);
    if (input.len == 0) return error.EmptyInput;

    // BLOCK_BYTES=0 means "the whole file is one block": the nominal block
    // size that drives both the split and bz3_new's state size is then
    // simply the file length.
    const nominal_block_bytes: usize = if (block_bytes_arg == 0) input.len else block_bytes_arg;
    const block_count: usize = (input.len - 1) / nominal_block_bytes + 1;
    const state_size: usize = @max(nominal_block_bytes, min_native_block_bytes);
    // Mirrors upstream bz3_bound (libbz3.c): input_size + input_size/50 + 32.
    const work_capacity: usize = state_size + state_size / 50 + 32;

    const encode_state = c.bz3_new(@intCast(state_size)) orelse return error.Bzip3SetupFailed;
    defer c.bz3_free(encode_state);
    const decode_state = c.bz3_new(@intCast(state_size)) orelse return error.Bzip3SetupFailed;
    defer c.bz3_free(decode_state);
    const work = try alloc.alloc(u8, work_capacity);
    defer alloc.free(work);

    // --- Encode every block once, with one retained encoder state. ---
    var blocks: std.ArrayList([]u8) = .empty;
    defer {
        for (blocks.items) |bytes| alloc.free(bytes);
        blocks.deinit(alloc);
    }
    const encode_timer = Timer.start(io);
    var payload_bytes: usize = 0;
    for (0..block_count) |index| {
        const range = blockRange(input.len, nominal_block_bytes, index);
        const raw = input[range.start..][0..range.len];
        @memcpy(work[0..raw.len], raw);
        const result = c.bz3_encode_block(encode_state, work.ptr, @intCast(raw.len));
        if (result < 0 or c.bz3_last_error(encode_state) != c.BZ3_OK) return error.Bzip3EncodeFailed;
        const encoded_len: usize = @intCast(result);
        const owned = try alloc.dupe(u8, work[0..encoded_len]);
        errdefer alloc.free(owned);
        try blocks.append(alloc, owned);
        payload_bytes += encoded_len;
    }
    const encode_ns = encode_timer.read();

    // --- One untimed verification pass: every block must decode back to
    //     the exact original bytes before any number is trusted. ---
    for (blocks.items, 0..) |encoded, index| {
        const range = blockRange(input.len, nominal_block_bytes, index);
        const raw = input[range.start..][0..range.len];
        @memcpy(work[0..encoded.len], encoded);
        const result = c.bz3_decode_block(decode_state, work.ptr, work.len, @intCast(encoded.len), @intCast(raw.len));
        if (result < 0 or c.bz3_last_error(decode_state) != c.BZ3_OK) return error.Bzip3DecodeFailed;
        const decoded_len: usize = @intCast(result);
        if (decoded_len != raw.len or !std.mem.eql(u8, raw, work[0..decoded_len])) return error.RoundtripMismatch;
    }

    // --- REPEATS timed full-decode passes, same retained decoder state.
    //     Verification already happened above and is not repeated here, so
    //     the clock covers exactly "memcpy into the work buffer, then
    //     bz3_decode_block", once per block, for the whole file. ---
    const pass_ns = try alloc.alloc(u64, repeats);
    defer alloc.free(pass_ns);
    for (pass_ns) |*slot| {
        const pass_timer = Timer.start(io);
        for (blocks.items, 0..) |encoded, index| {
            const range = blockRange(input.len, nominal_block_bytes, index);
            @memcpy(work[0..encoded.len], encoded);
            const result = c.bz3_decode_block(decode_state, work.ptr, work.len, @intCast(encoded.len), @intCast(range.len));
            if (result < 0 or c.bz3_last_error(decode_state) != c.BZ3_OK) return error.Bzip3DecodeFailed;
        }
        slot.* = pass_timer.read();
    }
    std.mem.sort(u64, pass_ns, {}, lessThanU64);
    const decode_min_ns = pass_ns[0];
    const decode_median_ns = medianU64(pass_ns);

    const total_bytes = header_bytes + directory_record_bytes * block_count + payload_bytes;
    const encode_ms = @as(f64, @floatFromInt(encode_ns)) / 1.0e6;
    const decode_min_ms = @as(f64, @floatFromInt(decode_min_ns)) / 1.0e6;
    const decode_median_ms = decode_median_ns / 1.0e6;
    const decode_mbps = (@as(f64, @floatFromInt(input.len)) / 1.0e6) / (decode_median_ns / 1.0e9);

    // NOTE: `File.writer()` defaults to *positional* writes (pwrite at an
    // internally tracked offset starting from 0), which silently ignores
    // O_APPEND when stdout is redirected to a regular file with `>>` --
    // each process would overwrite from byte 0 instead of appending, and a
    // driver script chaining many invocations into one baselines.tsv would
    // corrupt it. `writerStreaming()` uses plain write() and honours
    // whatever append/seek semantics the fd already has, which is what a
    // CLI tool's stdout must do.
    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &output_buffer);
    try writer.interface.print(
        "{s}\t{d}\t{d}\t{d}\t{d}\t{d:.3}\t{d:.3}\t{d:.3}\t{d:.2}\n",
        .{
            std.fs.path.basename(path),
            block_bytes_arg,
            block_count,
            payload_bytes,
            total_bytes,
            encode_ms,
            decode_min_ms,
            decode_median_ms,
            decode_mbps,
        },
    );
    try writer.interface.flush();
}
