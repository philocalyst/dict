//! Prepared-reader comparison for the unchanged legacy bz4 v4 decoder.
//! Existing payload jobs are immutable after all dictionary deltas are read.
//! This is a benchmark client for verified frames, not a new public decoder.
const std = @import("std");
const bz4 = @import("bz4");

const Span = struct { start: usize, job: bz4.Job };
const Range = struct { bytes: []u8, jobs: usize };

fn clock(io: std.Io, enabled: bool) i96 {
    return if (enabled) std.Io.Clock.awake.now(io).nanoseconds else 0;
}

fn readRange(allocator: std.mem.Allocator, decoder: *const bz4.Decoder, spans: []const Span, start: usize, length: usize) !Range {
    const output = try allocator.alloc(u8, length);
    errdefer allocator.free(output);
    var lo: usize = 0;
    var hi = spans.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (spans[mid].start <= start) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return error.RangeOutOfBounds;
    var index = lo - 1;
    var copied: usize = 0;
    var jobs: usize = 0;
    while (copied < length) : (index += 1) {
        if (index >= spans.len) return error.RangeOutOfBounds;
        const span = spans[index];
        const block = try allocator.alloc(u8, span.job.raw_len);
        defer allocator.free(block);
        try decoder.run(span.job, block);
        const local = start + copied - span.start;
        if (local >= block.len) return error.RangeOutOfBounds;
        const amount = @min(length - copied, block.len - local);
        @memcpy(output[copied..][0..amount], block[local..][0..amount]);
        copied += amount;
        jobs += 1;
    }
    return .{ .bytes = output, .jobs = jobs };
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const operation = args.next() orelse return error.Usage;
    const input_path = args.next() orelse return error.Usage;
    const output_path = args.next() orelse return error.Usage;
    var measured = false;
    var quiet = false;
    var index: ?usize = null;
    var target: usize = 65536;
    while (args.next()) |arg| {
        const value = args.next() orelse return error.Usage;
        if (std.mem.eql(u8, arg, "--measure")) {
            if (!std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "1")) return error.Usage;
            measured = std.mem.eql(u8, value, "1");
        } else if (std.mem.eql(u8, arg, "--quiet-gate")) {
            quiet = std.mem.eql(u8, value, "WORDZIP-READER-QUIET");
        } else if (std.mem.eql(u8, arg, "--index")) {
            index = try std.fmt.parseUnsigned(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--block")) {
            target = try std.fmt.parseUnsigned(usize, value, 10);
        } else return error.Usage;
    }
    if ((measured and !quiet) or target == 0 or target > 65536) return error.QuietOrBlock;
    const preparation_start = clock(init.io, measured);
    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, input_path, init.gpa, .limited(512 * 1024 * 1024));
    defer init.gpa.free(input);
    const source_read_ns = clock(init.io, measured) - preparation_start;
    var decoder = try bz4.Decoder.init(init.gpa, input);
    defer decoder.deinit();
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(init.gpa);
    var raw_bytes: usize = 0;
    while (try decoder.next()) |job| {
        if (job.items != 0) {
            if (job.raw_len == 0 or job.raw_len > 64 * 1024 * 1024 or raw_bytes > 512 * 1024 * 1024 - job.raw_len) return error.FrameLimit;
            try spans.append(init.gpa, .{ .start = raw_bytes, .job = job });
            raw_bytes += job.raw_len;
        }
    }
    if (decoder.pos != input.len) return error.FrameTail;
    const preparation_ns = clock(init.io, measured) - preparation_start;
    const arena_bytes = decoder.arena.queryCapacity();
    const directory_capacity_bytes = spans.capacity * @sizeOf(Span);
    const logical_blocks = (raw_bytes + target - 1) / target;
    if (std.mem.eql(u8, operation, "decode")) {
        const start = if (index) |i| std.math.mul(usize, i, target) catch return error.RangeOutOfBounds else 0;
        if (start >= raw_bytes and raw_bytes != 0) return error.RangeOutOfBounds;
        const length = if (index != null) @min(target, raw_bytes - start) else raw_bytes;
        const result: Range = if (length == 0) .{ .bytes = try init.gpa.alloc(u8, 0), .jobs = 0 } else try readRange(init.gpa, &decoder, spans.items, start, length);
        defer init.gpa.free(result.bytes);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = result.bytes });
        return;
    }
    if (!std.mem.eql(u8, operation, "bench-reader") or logical_blocks == 0) return error.Usage;
    var decode_ns: i96 = 0;
    var checksum: u64 = 1469598103934665603;
    var decoded_bytes: usize = 0;
    var decoded_jobs: usize = 0;
    for (0..256) |access| {
        const block = switch (access % 3) {
            0 => @as(usize, 0),
            1 => logical_blocks / 2,
            else => logical_blocks - 1,
        };
        const start = block * target;
        const length = @min(target, raw_bytes - start);
        const begin = clock(init.io, measured);
        const result = try readRange(init.gpa, &decoder, spans.items, start, length);
        const queried_crc = std.hash.crc.Crc32.hash(result.bytes);
        decode_ns += clock(init.io, measured) - begin;
        defer init.gpa.free(result.bytes);
        decoded_bytes += result.bytes.len;
        decoded_jobs += result.jobs;
        checksum = (checksum ^ @as(u64, queried_crc)) *% 1099511628211;
    }
    var rendered: std.Io.Writer.Allocating = .init(init.gpa);
    defer rendered.deinit();
    try rendered.writer.print("{f}\n", .{std.json.fmt(.{
        .protocol = "LEGACY-BZ4-PREPARED-RANGE/1",
        .timing_enabled = measured,
        .prepare_ns = preparation_ns,
        .source_read_ns = source_read_ns,
        .decode_256_ns = decode_ns,
        .access_count = @as(usize, 256),
        .decoded_bytes = decoded_bytes,
        .checksum = checksum,
        .frame_bytes = input.len,
        .raw_bytes = raw_bytes,
        .logical_block_bytes = target,
        .logical_blocks = logical_blocks,
        .payload_jobs = spans.items.len,
        .decoded_jobs = decoded_jobs,
        .decoder_arena_reserved_bytes = arena_bytes,
        .prepared_job_directory_capacity_bytes = directory_capacity_bytes,
        .retained_source_copy_bytes = input.len,
        .accounting = "preparation includes whole-file read/copy, all deltas, entropy model, and job snapshots; per-query time includes output/block scratch allocation and CRC of exact queried bytes",
        .safety = "unchanged legacy decoder, benchmark frames independently source-verified; no new hostile-frame admission guarantee",
    }, .{})});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = rendered.written() });
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.writeAll(rendered.written());
    try stdout.interface.flush();
}
