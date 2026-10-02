//! File adapter for measuring the existing bz4 v3 complete archive.

const std = @import("std");
const bz4 = @import("bz4");

const Summary = struct {
    header_bytes: usize,
    directory_bytes: usize,
    model_dictionary_bytes: usize,
    payload_bytes: usize,
    frame_bytes: usize,
    raw_bytes: usize,
    blocks: usize,
    block_raw_lengths: std.ArrayList(usize),
};

fn summarize(allocator: std.mem.Allocator, bytes: []const u8) !Summary {
    const magic = bz4.frame.magic;
    if (!std.mem.startsWith(u8, bytes, magic)) return error.CorruptFrame;
    var pos = magic.len;
    const header_len = try bz4.frame.takeVarint(bytes, &pos);
    if (header_len > bytes.len - pos) return error.CorruptFrame;
    const header_bytes = pos;
    pos += header_len;
    var model_dictionary_bytes: usize = header_len;
    var payload_bytes: usize = 0;
    var raw_bytes: usize = 0;
    var data_blocks: usize = 0;
    var raw_lengths: std.ArrayList(usize) = .empty;
    errdefer raw_lengths.deinit(allocator);
    while (true) {
        const before = pos;
        const block = try bz4.frame.Block.read(bytes, &pos) orelse break;
        model_dictionary_bytes += block.delta.len;
        payload_bytes += block.payload.len;
        if (block.items != 0) {
            raw_bytes += block.raw_len;
            data_blocks += 1;
            try raw_lengths.append(allocator, block.raw_len);
        }
        if (pos <= before) return error.CorruptFrame;
    }
    if (pos != bytes.len) return error.CorruptFrame;
    const directory_bytes = bytes.len - header_bytes - model_dictionary_bytes - payload_bytes;
    return .{
        .header_bytes = header_bytes,
        .directory_bytes = directory_bytes,
        .model_dictionary_bytes = model_dictionary_bytes,
        .payload_bytes = payload_bytes,
        .frame_bytes = bytes.len,
        .raw_bytes = raw_bytes,
        .blocks = data_blocks,
        .block_raw_lengths = raw_lengths,
    };
}

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn readFile(init: std.process.Init, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(512 * 1024 * 1024));
}

fn writeJson(init: std.process.Init, fields: anytype) !void {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.print("{f}\n", .{std.json.fmt(fields, .{})});
    try writer.interface.flush();
}

fn parseUsize(text: []const u8) !usize {
    return std.fmt.parseUnsigned(usize, text, 10);
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const operation = args.next() orelse return error.Usage;
    const input_path = args.next() orelse return error.Usage;
    const output_path = args.next() orelse return error.Usage;
    var block_bytes: usize = 64 * 1024;
    var block_index: usize = 0;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--block")) {
            block_bytes = try parseUsize(args.next() orelse return error.Usage);
        } else if (std.mem.eql(u8, arg, "--index")) {
            block_index = try parseUsize(args.next() orelse return error.Usage);
        } else return error.Usage;
    }
    if (block_bytes == 0 or block_bytes > 64 * 1024) return error.InvalidBlock;
    const input = try readFile(init, input_path);
    defer init.gpa.free(input);
    const cwd = std.Io.Dir.cwd();

    if (std.mem.eql(u8, operation, "encode")) {
        const started = now(init.io);
        const frame = try bz4.compress(init.gpa, input, .{ .learn = .{ .block = block_bytes } });
        defer init.gpa.free(frame);
        const duration = now(init.io) - started;
        var stats = try summarize(init.gpa, frame);
        defer stats.block_raw_lengths.deinit(init.gpa);
        try cwd.writeFile(init.io, .{ .sub_path = output_path, .data = frame });
        try writeJson(init, .{
            .codec_ns = duration,
            .input_bytes = input.len,
            .output_bytes = frame.len,
            .header_bytes = stats.header_bytes,
            .directory_bytes = stats.directory_bytes,
            .model_dictionary_bytes = stats.model_dictionary_bytes,
            .payload_bytes = stats.payload_bytes,
            .blocks = stats.blocks,
            .block_raw_lengths = stats.block_raw_lengths.items,
        });
    } else if (std.mem.eql(u8, operation, "decode")) {
        var stats = try summarize(init.gpa, input);
        defer stats.block_raw_lengths.deinit(init.gpa);
        const started = now(init.io);
        const decoded = try bz4.decompress(init.gpa, input, 1);
        defer init.gpa.free(decoded);
        const duration = now(init.io) - started;
        try cwd.writeFile(init.io, .{ .sub_path = output_path, .data = decoded });
        try writeJson(init, .{ .codec_ns = duration, .input_bytes = input.len, .output_bytes = decoded.len,
            .header_bytes = stats.header_bytes, .directory_bytes = stats.directory_bytes,
            .model_dictionary_bytes = stats.model_dictionary_bytes, .payload_bytes = stats.payload_bytes,
            .blocks = stats.blocks, .block_raw_lengths = stats.block_raw_lengths.items });
    } else if (std.mem.eql(u8, operation, "extract")) {
        var stats = try summarize(init.gpa, input);
        defer stats.block_raw_lengths.deinit(init.gpa);
        var decoder = try bz4.Decoder.init(init.gpa, input);
        defer decoder.deinit();
        const started = now(init.io);
        var current: usize = 0;
        var parsed: usize = 0;
        var selected: ?bz4.Job = null;
        while (try decoder.next()) |job| {
            parsed += 1;
            if (job.items != 0) {
                if (current == block_index) {
                    selected = job;
                    break;
                }
                current += 1;
            }
        }
        const job = selected orelse return error.BlockOutOfRange;
        const decoded = try init.gpa.alloc(u8, job.raw_len);
        defer init.gpa.free(decoded);
        try decoder.run(job, decoded);
        const duration = now(init.io) - started;
        try cwd.writeFile(init.io, .{ .sub_path = output_path, .data = decoded });
        try writeJson(init, .{ .codec_ns = duration, .access_mode = "replay_dictionary_deltas_then_decode_block",
            .block_index = block_index, .blocks_parsed = parsed, .raw_bytes = decoded.len,
            .archive_raw_bytes = stats.raw_bytes, .frame_bytes = stats.frame_bytes });
    } else return error.Usage;
}
