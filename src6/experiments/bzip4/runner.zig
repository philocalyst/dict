//! Reproducible experiment runner.  Timing is disabled unless the explicit
//! quiet gate is supplied; ordinary smoke runs still verify every roundtrip.

const std = @import("std");
const codec = @import("codec.zig");
const bwt = @import("bwt_codec.zig");
const bzip3 = @import("production_bzip3");
const c = @cImport({
    @cInclude("libbz3.h");
});

const gate = "BZIP4-EXPERIMENT-QUIET-GATE";

const InputFormat = enum { raw, projection_content };
const Candidate = enum { shared_lz, bwt };

const Config = struct {
    input: ?[]const u8 = null,
    input_format: InputFormat = .raw,
    candidate: Candidate = .shared_lz,
    training_bytes: usize = 1024 * 1024,
    block_bytes: usize = 16 * 1024,
    dictionary_bytes: usize = 32 * 1024,
    max_eval_bytes: usize = 8 * 1024 * 1024,
    measure: bool = false,
    run_bzip3_controls: bool = true,
    use_arithmetic: bool = true,
};

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

const Control = struct {
    payload_bytes: usize,
    total_bytes: usize,
    setup_ns: u64 = 0,
    encode_ns: u64,
    decode_ns: u64,
    max_encoded_block: usize,
};

fn bzip3RetainedControl(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: []const u8,
    block_bytes: usize,
    measure: bool,
) !Control {
    const block_count = if (input.len == 0) 0 else (input.len - 1) / block_bytes + 1;
    const state_size = @max(block_bytes, bzip3.min_native_block_bytes);
    const work_capacity = try bzip3.bound(state_size);
    const setup_timer = Timer.start(io);
    const encode_state = c.bz3_new(@intCast(state_size)) orelse return error.Bzip3SetupFailed;
    defer c.bz3_free(encode_state);
    const decode_state = c.bz3_new(@intCast(state_size)) orelse return error.Bzip3SetupFailed;
    defer c.bz3_free(decode_state);
    const work = try allocator.alloc(u8, work_capacity);
    defer allocator.free(work);
    const setup_ns = if (measure) setup_timer.read() else 0;

    var blocks: std.ArrayList([]u8) = .empty;
    defer {
        for (blocks.items) |bytes| allocator.free(bytes);
        blocks.deinit(allocator);
    }
    const encode_timer = Timer.start(io);
    var payload_bytes: usize = 0;
    var max_encoded_block: usize = 0;
    for (0..block_count) |block_index| {
        const start = block_index * block_bytes;
        const raw = input[start..][0..@min(input.len - start, block_bytes)];
        @memcpy(work[0..raw.len], raw);
        const result = c.bz3_encode_block(encode_state, work.ptr, @intCast(raw.len));
        if (result < 0 or c.bz3_last_error(encode_state) != c.BZ3_OK) return error.Bzip3CodecFailure;
        const encoded_len: usize = @intCast(result);
        const owned = try allocator.dupe(u8, work[0..encoded_len]);
        errdefer allocator.free(owned);
        try blocks.append(allocator, owned);
        payload_bytes += encoded_len;
        max_encoded_block = @max(max_encoded_block, encoded_len);
    }
    const encode_ns = if (measure) encode_timer.read() else 0;

    const decode_timer = Timer.start(io);
    for (blocks.items, 0..) |encoded, block_index| {
        const start = block_index * block_bytes;
        const raw = input[start..][0..@min(input.len - start, block_bytes)];
        @memcpy(work[0..encoded.len], encoded);
        const result = c.bz3_decode_block(
            decode_state,
            work.ptr,
            work.len,
            @intCast(encoded.len),
            @intCast(raw.len),
        );
        if (result < 0 or c.bz3_last_error(decode_state) != c.BZ3_OK) return error.Bzip3CodecFailure;
        if (@as(usize, @intCast(result)) != raw.len or !std.mem.eql(u8, raw, work[0..raw.len])) return error.RoundtripMismatch;
    }
    const decode_ns = if (measure) decode_timer.read() else 0;
    return .{
        .payload_bytes = payload_bytes,
        .total_bytes = 32 + block_count * codec.directory_record_size + payload_bytes,
        .setup_ns = setup_ns,
        .encode_ns = encode_ns,
        .decode_ns = decode_ns,
        .max_encoded_block = max_encoded_block,
    };
}

fn usage() void {
    std.debug.print(
        "usage: bzip4-experiment --input PATH [--candidate shared_lz|bwt] [--block-bytes N] [--dictionary-bytes N] " ++
            "[--input-format raw|projection_content] [--training-bytes N] [--max-eval-bytes N] " ++
            "[--skip-bzip3] [--no-arithmetic] [--measure --quiet-gate " ++ gate ++ "]\n",
        .{},
    );
}

fn parse(args: std.process.Args) !Config {
    var config = Config{};
    var iterator = std.process.Args.Iterator.init(args);
    _ = iterator.next();
    var supplied_gate = false;
    while (iterator.next()) |argument| {
        if (std.mem.eql(u8, argument, "--input")) {
            config.input = iterator.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, argument, "--input-format")) {
            const value = iterator.next() orelse return error.MissingValue;
            config.input_format = std.meta.stringToEnum(InputFormat, value) orelse return error.InvalidArgument;
        } else if (std.mem.eql(u8, argument, "--candidate")) {
            const value = iterator.next() orelse return error.MissingValue;
            config.candidate = std.meta.stringToEnum(Candidate, value) orelse return error.InvalidArgument;
        } else if (std.mem.eql(u8, argument, "--training-bytes")) {
            config.training_bytes = try std.fmt.parseUnsigned(usize, iterator.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, argument, "--block-bytes")) {
            config.block_bytes = try std.fmt.parseUnsigned(usize, iterator.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, argument, "--dictionary-bytes")) {
            config.dictionary_bytes = try std.fmt.parseUnsigned(usize, iterator.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, argument, "--max-eval-bytes")) {
            config.max_eval_bytes = try std.fmt.parseUnsigned(usize, iterator.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, argument, "--measure")) {
            config.measure = true;
        } else if (std.mem.eql(u8, argument, "--skip-bzip3")) {
            config.run_bzip3_controls = false;
        } else if (std.mem.eql(u8, argument, "--no-arithmetic")) {
            config.use_arithmetic = false;
        } else if (std.mem.eql(u8, argument, "--quiet-gate")) {
            supplied_gate = std.mem.eql(u8, iterator.next() orelse return error.MissingValue, gate);
            if (!supplied_gate) return error.InvalidGate;
        } else if (std.mem.eql(u8, argument, "--help")) {
            usage();
            return error.Help;
        } else return error.InvalidArgument;
    }
    if (config.input == null or config.block_bytes == 0 or config.training_bytes == 0 or config.max_eval_bytes == 0) return error.InvalidArgument;
    if (config.dictionary_bytes > codec.max_dictionary_bytes) return error.InvalidArgument;
    if (config.measure != supplied_gate) return error.GateRequired;
    return config;
}

fn readInput(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(1024 * 1024 * 1024));
}

fn hexNibble(byte: u8) !u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => error.InvalidProjection,
    };
}

/// Extract exactly the third, normalized-content column. Concatenation is the
/// same whole-stream diagnostic used by the retained real-world report; row
/// boundaries are intentionally outside this byte-compression experiment.
fn decodeProjectionContent(allocator: std.mem.Allocator, projection: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var lines = std.mem.splitScalar(u8, projection, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var columns = std.mem.splitScalar(u8, line, '\t');
        _ = columns.next() orelse return error.InvalidProjection;
        _ = columns.next() orelse return error.InvalidProjection;
        const content = columns.next() orelse return error.InvalidProjection;
        if (columns.next() != null or content.len % 2 != 0) return error.InvalidProjection;
        output.ensureUnusedCapacity(allocator, content.len / 2) catch return error.OutOfMemory;
        var at: usize = 0;
        while (at < content.len) : (at += 2) {
            output.appendAssumeCapacity((try hexNibble(content[at])) << 4 | try hexNibble(content[at + 1]));
        }
    }
    if (output.items.len == 0) return error.InvalidProjection;
    return output.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn bzip3Control(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: []const u8,
    block_bytes: usize,
    measure: bool,
) !Control {
    var encoded_blocks: std.ArrayList(bzip3.Block) = .empty;
    defer {
        for (encoded_blocks.items) |*block| block.deinit();
        encoded_blocks.deinit(allocator);
    }
    const block_count = if (input.len == 0) 0 else (input.len - 1) / block_bytes + 1;
    const limits = bzip3.Limits{
        .max_block_bytes = @max(block_bytes, bzip3.min_native_block_bytes),
        .max_memory_bytes = 64 * 1024 * 1024,
    };
    const encode_timer = Timer.start(io);
    var payload_bytes: usize = 0;
    var max_encoded_block: usize = 0;
    for (0..block_count) |block_index| {
        const start = block_index * block_bytes;
        const raw = input[start..@min(input.len, start + block_bytes)];
        const block = try bzip3.encode(allocator, raw, .bzip3, limits);
        payload_bytes += block.bytes.len;
        max_encoded_block = @max(max_encoded_block, block.bytes.len);
        try encoded_blocks.append(allocator, block);
    }
    const encode_ns = if (measure) encode_timer.read() else 0;

    const decode_timer = Timer.start(io);
    var decoded_bytes: usize = 0;
    for (encoded_blocks.items, 0..) |block, block_index| {
        const start = block_index * block_bytes;
        const raw = input[start..@min(input.len, start + block_bytes)];
        var decoded = try bzip3.decode(allocator, .bzip3, block.bytes, raw.len, limits);
        defer decoded.deinit();
        if (!std.mem.eql(u8, raw, decoded.bytes)) return error.RoundtripMismatch;
        decoded_bytes += decoded.bytes.len;
    }
    const decode_ns = if (measure) decode_timer.read() else 0;
    if (decoded_bytes != input.len) return error.RoundtripMismatch;
    const framing = 32 + block_count * codec.directory_record_size;
    return .{
        .payload_bytes = payload_bytes,
        .total_bytes = framing + payload_bytes,
        .encode_ns = encode_ns,
        .decode_ns = decode_ns,
        .max_encoded_block = max_encoded_block,
    };
}

pub fn main(init: std.process.Init) !void {
    const config = parse(init.minimal.args) catch |err| {
        if (err == error.Help) return;
        usage();
        return err;
    };
    const source = try readInput(init, init.gpa, config.input.?);
    defer init.gpa.free(source);
    const input = switch (config.input_format) {
        .raw => source,
        .projection_content => try decodeProjectionContent(init.gpa, source),
    };
    defer if (config.input_format == .projection_content) init.gpa.free(input);
    if (input.len <= config.training_bytes) return error.InputTooSmall;

    // Fixed, contiguous, disjoint split. Training bytes can never enter the
    // held-out evaluation region.
    const training_len = config.training_bytes;
    const held_out = input[training_len..];
    const evaluation = held_out[0..@min(held_out.len, config.max_eval_bytes)];

    var dictionary: ?codec.TrainedDictionary = null;
    defer if (dictionary) |*owned| owned.deinit();
    var bwt_model: ?bwt.Model = null;
    const train_timer = Timer.start(init.io);
    switch (config.candidate) {
        .shared_lz => dictionary = try codec.trainDictionary(init.gpa, input[0..training_len], config.dictionary_bytes),
        .bwt => bwt_model = try bwt.trainModel(init.gpa, input[0..training_len], config.block_bytes),
    }
    const train_ns = if (config.measure) train_timer.read() else 0;

    const encode_timer = Timer.start(init.io);
    var encoded = switch (config.candidate) {
        .shared_lz => try codec.encodeFrameWithOptions(
            init.gpa,
            evaluation,
            dictionary.?.bytes,
            config.block_bytes,
            .{},
            .{ .use_arithmetic = config.use_arithmetic },
        ),
        .bwt => try bwt.encodeFrame(init.gpa, evaluation, bwt_model.?, config.block_bytes, .{}),
    };
    defer encoded.deinit();
    const encode_ns = if (config.measure) encode_timer.read() else 0;

    const CandidateMetrics = struct {
        block_count: usize,
        header_bytes: usize,
        model_bytes: usize,
        dictionary_bytes: usize,
        directory_bytes: usize,
        payload_bytes: usize,
        first_raw: usize,
        first_encoded: usize,
        max_encoded: usize,
        random_access_accounted: usize,
        decode_all_accounted: usize,
    };
    const decode_timer = Timer.start(init.io);
    const metrics: CandidateMetrics = switch (config.candidate) {
        .shared_lz => shared_metrics: {
            const frame = try codec.Frame.open(encoded.bytes, .{});
            var decoded = try frame.decodeAll(init.gpa);
            defer decoded.deinit();
            if (!std.mem.eql(u8, evaluation, decoded.bytes)) return error.RoundtripMismatch;
            var max_encoded: usize = 0;
            for (0..frame.block_count) |index| max_encoded = @max(max_encoded, try frame.blockEncodedLength(index));
            const token_bound = config.block_bytes + (config.block_bytes / 8 + @intFromBool(config.block_bytes % 8 != 0)) + 1;
            break :shared_metrics .{
                .block_count = frame.block_count,
                .header_bytes = codec.header_size,
                .model_bytes = 0,
                .dictionary_bytes = dictionary.?.bytes.len,
                .directory_bytes = frame.block_count * codec.directory_record_size,
                .payload_bytes = encoded.bytes.len - codec.header_size - dictionary.?.bytes.len - frame.block_count * codec.directory_record_size,
                .first_raw = if (frame.block_count == 0) 0 else try frame.blockRawLength(0),
                .first_encoded = if (frame.block_count == 0) 0 else try frame.blockEncodedLength(0),
                .max_encoded = max_encoded,
                .random_access_accounted = dictionary.?.bytes.len + config.block_bytes + token_bound + max_encoded + codec.predictor_working_bytes,
                .decode_all_accounted = evaluation.len + token_bound + max_encoded + codec.predictor_working_bytes,
            };
        },
        .bwt => bwt_metrics: {
            const frame = try bwt.Frame.open(encoded.bytes, .{});
            var decoded = try frame.decodeAll(init.gpa);
            defer decoded.deinit();
            if (!std.mem.eql(u8, evaluation, decoded.bytes)) return error.RoundtripMismatch;
            var max_encoded: usize = 0;
            for (0..frame.block_count) |index| max_encoded = @max(max_encoded, try frame.blockEncodedLength(index));
            const token_bound = config.block_bytes * 2 + 4;
            const temporary = token_bound + config.block_bytes + config.block_bytes * 4 + bwt.decode_fixed_table_bytes;
            break :bwt_metrics .{
                .block_count = frame.block_count,
                .header_bytes = bwt.header_size,
                .model_bytes = bwt.model_bytes,
                .dictionary_bytes = 0,
                .directory_bytes = frame.block_count * bwt.directory_record_size,
                .payload_bytes = encoded.bytes.len - bwt.header_size - bwt.model_bytes - frame.block_count * bwt.directory_record_size,
                .first_raw = if (frame.block_count == 0) 0 else try frame.blockRawLength(0),
                .first_encoded = if (frame.block_count == 0) 0 else try frame.blockEncodedLength(0),
                .max_encoded = max_encoded,
                .random_access_accounted = bwt.model_bytes + config.block_bytes + temporary,
                .decode_all_accounted = evaluation.len + temporary,
            };
        },
    };
    const decode_ns = if (config.measure) decode_timer.read() else 0;

    const empty_control = Control{ .payload_bytes = 0, .total_bytes = 0, .encode_ns = 0, .decode_ns = 0, .max_encoded_block = 0 };
    const matched = if (config.run_bzip3_controls)
        try bzip3Control(init.gpa, init.io, evaluation, config.block_bytes, config.measure)
    else
        empty_control;
    const matched_retained = if (config.run_bzip3_controls)
        try bzip3RetainedControl(init.gpa, init.io, evaluation, config.block_bytes, config.measure)
    else
        empty_control;
    const current = if (config.run_bzip3_controls)
        try bzip3Control(init.gpa, init.io, evaluation, 64 * 1024, config.measure)
    else
        empty_control;
    if (config.run_bzip3_controls and matched_retained.total_bytes != matched.total_bytes) return error.ControlMismatch;
    const block_count = metrics.block_count;
    const raw_total = metrics.header_bytes + metrics.model_bytes + metrics.dictionary_bytes + metrics.directory_bytes + evaluation.len + block_count;

    // Production bzip3 explicitly charges native state, block buffer, and a
    // conservative 1 MiB libsais allowance.  Report the same accounting.
    const native_state: usize = @intCast(c.bz3_min_memory_needed(@intCast(@max(config.block_bytes, bzip3.min_native_block_bytes))));
    const bzip3_scratch = native_state + try bzip3.bound(config.block_bytes) + bzip3.libsais_accounted_bytes;

    var output_buffer: [8192]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    try writer.interface.print(
        "schema\tbzip4-experiment-1\n" ++
            "timing\t{s}\n" ++
            "candidate\t{s}\n" ++
            "input_format\t{s}\n" ++
            "source_file_bytes\t{d}\n" ++
            "input_bytes\t{d}\n" ++
            "training_partition_bytes\t{d}\n" ++
            "held_out_available_bytes\t{d}\n" ++
            "held_out_evaluated_bytes\t{d}\n" ++
            "block_bytes\t{d}\n" ++
            "block_count\t{d}\n" ++
            "dictionary_bytes\t{d}\n" ++
            "stored_model_bytes\t{d}\n" ++
            "arithmetic_predictor\t{s}\n" ++
            "header_bytes\t{d}\n" ++
            "directory_restart_bytes\t{d}\n" ++
            "bzip4_payload_bytes\t{d}\n" ++
            "bzip4_total_bytes\t{d}\n" ++
            "raw_framed_total_bytes\t{d}\n",
        .{
            if (config.measure) "gated-provisional" else "disabled-smoke",
            @tagName(config.candidate),
            @tagName(config.input_format),
            source.len,
            input.len,
            training_len,
            held_out.len,
            evaluation.len,
            config.block_bytes,
            block_count,
            metrics.dictionary_bytes,
            metrics.model_bytes,
            if (config.candidate == .bwt) "not-applicable" else if (config.use_arithmetic) "enabled" else "disabled",
            metrics.header_bytes,
            metrics.directory_bytes,
            metrics.payload_bytes,
            encoded.bytes.len,
            raw_total,
        },
    );
    try writer.interface.print(
        "bzip3_controls\t{s}\n" ++
            "bzip3_matched_payload_bytes\t{d}\n" ++
            "bzip3_matched_total_bytes\t{d}\n" ++
            "bzip3_64k_payload_bytes\t{d}\n" ++
            "bzip3_64k_total_bytes\t{d}\n" ++
            "train_ns\t{d}\n" ++
            "bzip4_encode_ns\t{d}\n" ++
            "bzip4_decode_all_ns\t{d}\n" ++
            "bzip3_matched_encode_ns\t{d}\n" ++
            "bzip3_matched_decode_all_ns\t{d}\n" ++
            "bzip3_retained_setup_ns\t{d}\n" ++
            "bzip3_retained_encode_ns\t{d}\n" ++
            "bzip3_retained_decode_all_ns\t{d}\n" ++
            "bzip3_64k_encode_ns\t{d}\n" ++
            "bzip3_64k_decode_all_ns\t{d}\n",
        .{
            if (config.run_bzip3_controls) "run" else "skipped",
            matched.payload_bytes,
            matched.total_bytes,
            current.payload_bytes,
            current.total_bytes,
            train_ns,
            encode_ns,
            decode_ns,
            matched.encode_ns,
            matched.decode_ns,
            matched_retained.setup_ns,
            matched_retained.encode_ns,
            matched_retained.decode_ns,
            current.encode_ns,
            current.decode_ns,
        },
    );
    try writer.interface.print("bzip4_random_access_conservative_accounted_bytes\t{d}\n" ++
        "bzip4_decode_all_conservative_accounted_bytes\t{d}\n" ++
        "bzip3_accounted_scratch_budget\t{d}\n" ++
        "first_block_raw_bytes\t{d}\n" ++
        "first_block_encoded_bytes\t{d}\n" ++
        "first_block_warm_access_amplification_milli\t{d}\n" ++
        "first_block_cold_dictionary_access_amplification_milli\t{d}\n" ++
        "roundtrip\tok\n", .{
        metrics.random_access_accounted,
        metrics.decode_all_accounted,
        bzip3_scratch,
        metrics.first_raw,
        metrics.first_encoded,
        if (metrics.first_raw == 0) 0 else metrics.first_encoded * 1000 / metrics.first_raw,
        if (metrics.first_raw == 0) 0 else (metrics.model_bytes + metrics.dictionary_bytes + metrics.first_encoded) * 1000 / metrics.first_raw,
    });
    try writer.interface.flush();
}
