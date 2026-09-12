//! Auditable, component-level LEX4 ablations.
//!
//! This executable deliberately uses the public production writers and
//! readers from src4.  A row's byte count is the complete canonical wire
//! string (envelope, directory/checkpoint index, alignment, and payload), not
//! a payload-only estimate.  The entropy rows use forced canonical candidates
//! so that entropy-vs-packed is a controlled comparison of one representation
//! at a time; they do not claim that either candidate is the adaptive winner.
//!
//! Membership-vs-pairwise is intentionally absent: the current public APIs do
//! not expose two encodings with the same query contract, so presenting their
//! differently-normalized answers as a controlled ablation would be false.

const std = @import("std");
const builtin = @import("builtin");
const src4 = @import("src4");
const entropy = src4.entropy;

pub const protocol = "LEX4-COMPONENT-ABLATION/1";
pub const default_records: usize = 8192;
pub const default_repetitions: usize = 256;
pub const max_raw_observations: usize = 64;

pub const Lane = enum { low, medium, high };

pub const Options = struct {
    records: usize = default_records,
    repetitions: usize = default_repetitions,
    output_dir: ?[]const u8 = null,
};

pub const LaneValues = struct {
    allocator: std.mem.Allocator,
    values: []u32,

    pub fn deinit(self: *LaneValues) void {
        self.allocator.free(self.values);
        self.* = undefined;
    }
};

pub const WireMeasure = struct {
    serialized_bytes: usize,
    header_bytes: usize,
    checkpoint_index_bytes: usize,
    payload_bytes: usize,
    alignment_bytes: usize,
    checkpoint_count: usize,
    checkpoint_stride: usize,
};

pub const Timing = struct {
    query_elapsed_ns: u64,
    query_operations: usize,
    query_ns_per_operation: f64,
    decode_elapsed_ns: u64,
    decode_operations: usize,
    decode_ns_per_value: f64,
    reader_p50_ns: u64,
    sink: u64,
};

pub const RawObservation = struct {
    operation: []const u8,
    elapsed_ns: u64,
    operations: usize,
};

pub const LaneResult = struct {
    lane: Lane,
    representation: entropy.Strategy,
    values: usize,
    alphabet: usize,
    value_digest: u64,
    artifact_path: []const u8,
    artifact_sha256: [64]u8,
    build_ns: u64,
    open_ns: u64,
    verify_ns: u64,
    serialized: WireMeasure,
    semantic_equal: bool,
    reopen_verified: bool,
    timing: Timing,
    raw_observations: [max_raw_observations]RawObservation,
    raw_observation_count: usize,
};

var timing_sink: u64 = 0;

fn laneName(lane: Lane) []const u8 {
    return @tagName(lane);
}

fn strategyName(strategy: entropy.Strategy) []const u8 {
    return @tagName(strategy);
}

fn optimizationName() []const u8 {
    return @tagName(builtin.mode);
}

/// Deterministic low/medium/high lanes.  The high lane is a permutation of a
/// 4096-symbol alphabet, so its empirical alphabet is intentionally bounded by
/// the canonical rANS limit while still exercising the high-entropy path.
pub fn makeLane(allocator: std.mem.Allocator, lane: Lane, count: usize) !LaneValues {
    const values = try allocator.alloc(u32, count);
    errdefer allocator.free(values);
    for (values, 0..) |*value, index| {
        value.* = switch (lane) {
            .low => if (index % 17 == 0) 1 else if (index % 113 == 0) 2 else 0,
            .medium => blk: {
                // A deterministic 32-symbol stream with a non-uniform head.
                const mixed = (@as(u64, index) *% 6364136223846793005 +% 1442695040888963407) >> 32;
                const symbol = @as(u32, @intCast(mixed % 32));
                break :blk if (index % 5 == 0) 0 else symbol;
            },
            .high => blk: {
                // 2654435761 is coprime to 2^12; over 4096 values this is a
                // full permutation and keeps each symbol's count deterministic.
                const symbol = (@as(u64, index) *% 2654435761 +% 1013904223) % 4096;
                break :blk @intCast(symbol);
            },
        };
    }
    return .{ .allocator = allocator, .values = values };
}

fn digestValues(values: []const u32) u64 {
    var hash: u64 = 14695981039346656037;
    for (values) |value| {
        hash ^= value;
        hash *%= 1099511628211;
    }
    return hash;
}

fn digestBytesHex(bytes: []const u8) [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var encoded: [64]u8 = undefined;
    const digits = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        encoded[index * 2] = digits[byte >> 4];
        encoded[index * 2 + 1] = digits[byte & 0x0f];
    }
    return encoded;
}

fn alphabetSize(values: []const u32) usize {
    var seen: [entropy.max_entropy_alphabet]bool = [_]bool{false} ** entropy.max_entropy_alphabet;
    var count: usize = 0;
    for (values) |value| {
        if (value >= entropy.max_entropy_alphabet) continue;
        const index = @as(usize, @intCast(value));
        if (!seen[index]) {
            seen[index] = true;
            count += 1;
        }
    }
    return count;
}

fn readU64(bytes: []const u8, offset: usize) !u64 {
    if (offset > bytes.len or bytes.len - offset < 8) return error.Truncated;
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

/// Read only the canonical envelope fields, including the full checkpoint
/// index and payload accounting.  This is intentionally independent of the
/// representation-specific decoder while still checking the whole wire size.
pub fn measureWire(bytes: []const u8) !WireMeasure {
    if (bytes.len < entropy.header_size) return error.Truncated;
    const index_len = std.math.cast(usize, try readU64(bytes, 36)) orelse return error.Overflow;
    const payload_at = std.math.cast(usize, try readU64(bytes, 44)) orelse return error.Overflow;
    const payload_len = std.math.cast(usize, try readU64(bytes, 52)) orelse return error.Overflow;
    const checkpoint_count = std.math.cast(usize, std.mem.readInt(u32, bytes[24..28], .little)) orelse return error.Overflow;
    const stride = std.math.cast(usize, std.mem.readInt(u32, bytes[20..24], .little)) orelse return error.Overflow;
    if (entropy.header_size + index_len > payload_at or payload_at > bytes.len or payload_len > bytes.len - payload_at)
        return error.InvalidEncoding;
    if (payload_at + payload_len != bytes.len) return error.InvalidEncoding;
    return .{
        .serialized_bytes = bytes.len,
        .header_bytes = entropy.header_size,
        .checkpoint_index_bytes = index_len,
        .payload_bytes = payload_len,
        .alignment_bytes = payload_at - entropy.header_size - index_len,
        .checkpoint_count = checkpoint_count,
        .checkpoint_stride = stride,
    };
}

fn checkCheckpointIndex(view: *const entropy.View) !void {
    var previous: u64 = 0;
    for (0..view.checkpointCount()) |index| {
        const checkpoint = try view.checkpoint(index);
        if (index != 0 and checkpoint.offset < previous) return error.InvalidEncoding;
        previous = checkpoint.offset;
    }
}

fn percentile50(samples: []const u64) u64 {
    if (samples.len == 0) return 0;
    var ordered: [max_raw_observations]u64 = [_]u64{0} ** max_raw_observations;
    const count = @min(samples.len, max_raw_observations);
    @memcpy(ordered[0..count], samples[0..count]);
    std.sort.heap(u64, ordered[0..count], {}, std.sort.asc(u64));
    return ordered[count / 2];
}

fn queryTiming(
    view: *const entropy.View,
    values: []const u32,
    repetitions: usize,
    io: std.Io,
    observations: *[max_raw_observations]RawObservation,
) !Timing {
    const reps = if (repetitions == 0) @as(usize, 1) else repetitions;
    const sample_count = if (reps < max_raw_observations / 2) reps else max_raw_observations / 2;
    var sample_ns: [max_raw_observations / 2]u64 = [_]u64{0} ** (max_raw_observations / 2);
    var observation_count: usize = 0;
    var query_sink: u64 = 0;
    const query_start = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..reps) |iteration| {
        const index = if (values.len == 0) 0 else (iteration *% 7919 +% 17) % values.len;
        if (iteration < sample_count) {
            const started = std.Io.Clock.awake.now(io).nanoseconds;
            query_sink +%= try view.get(index);
            const finished = std.Io.Clock.awake.now(io).nanoseconds;
            const measured: u64 = @intCast(@max(finished - started, 0));
            sample_ns[iteration] = measured;
            observations[observation_count] = .{ .operation = "query_get", .elapsed_ns = measured, .operations = 1 };
            observation_count += 1;
        } else {
            query_sink +%= try view.get(index);
        }
    }
    const query_end = std.Io.Clock.awake.now(io).nanoseconds;

    const decoded = try std.heap.page_allocator.alloc(u32, values.len);
    defer std.heap.page_allocator.free(decoded);
    var decode_sink: u64 = 0;
    const decode_start = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..reps) |iteration| {
        const started = if (iteration < sample_count) std.Io.Clock.awake.now(io).nanoseconds else 0;
        try view.decode(decoded);
        const finished = if (iteration < sample_count) std.Io.Clock.awake.now(io).nanoseconds else 0;
        if (iteration < sample_count) {
            const measured: u64 = @intCast(@max(finished - started, 0));
            observations[observation_count] = .{ .operation = "decode", .elapsed_ns = measured, .operations = values.len };
            observation_count += 1;
        }
        if (decoded.len != 0) decode_sink +%= decoded[(decode_sink +% 13) % decoded.len];
    }
    const decode_end = std.Io.Clock.awake.now(io).nanoseconds;

    const query_elapsed: u64 = @intCast(@max(query_end - query_start, 0));
    const decode_elapsed: u64 = @intCast(@max(decode_end - decode_start, 0));
    const decode_operations = std.math.mul(usize, reps, values.len) catch return error.Overflow;
    timing_sink ^= query_sink ^ (decode_sink *% 0x9e3779b97f4a7c15);
    return .{
        .query_elapsed_ns = query_elapsed,
        .query_operations = reps,
        .query_ns_per_operation = @as(f64, @floatFromInt(query_elapsed)) / @as(f64, @floatFromInt(reps)),
        .decode_elapsed_ns = decode_elapsed,
        .decode_operations = decode_operations,
        .decode_ns_per_value = if (decode_operations == 0) 0 else @as(f64, @floatFromInt(decode_elapsed)) / @as(f64, @floatFromInt(decode_operations)),
        .reader_p50_ns = percentile50(sample_ns[0..sample_count]),
        .sink = query_sink ^ decode_sink,
    };
}

fn semanticCheck(view: *const entropy.View, values: []const u32) !bool {
    const decoded = try std.heap.page_allocator.alloc(u32, values.len);
    defer std.heap.page_allocator.free(decoded);
    try view.decode(decoded);
    if (!std.mem.eql(u32, values, decoded)) return false;
    if (values.len != 0) {
        const probes = [_]usize{ 0, values.len / 3, values.len / 2, values.len - 1 };
        for (probes) |index| if (try view.get(index) != values[index]) return false;
    }
    return true;
}

fn writeRetainedArtifact(allocator: std.mem.Allocator, io: std.Io, output_dir: []const u8, lane: Lane, strategy: entropy.Strategy, bytes: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.ens4", .{ output_dir, laneName(lane), strategyName(strategy) });
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [16 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    try file_writer.interface.writeAll(bytes);
    try file_writer.interface.flush();
    const retained = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024 * 1024));
    if (retained.len != bytes.len or !std.mem.eql(u8, retained, bytes)) return error.RetainedArtifactMismatch;
    allocator.free(retained);
    return path;
}

fn laneResult(allocator: std.mem.Allocator, lane: Lane, values: []const u32, strategy: entropy.Strategy, repetitions: usize, io: std.Io, output_dir: ?[]const u8) !LaneResult {
    const build_start = std.Io.Clock.awake.now(io).nanoseconds;
    var owned = try entropy.buildForced(allocator, values, .{ .checkpoint_stride = 64 }, strategy);
    const build_ns = elapsed(io, build_start);
    defer owned.deinit();

    const artifact_path = if (output_dir) |directory|
        try writeRetainedArtifact(allocator, io, directory, lane, strategy, owned.bytes)
    else
        "memory://lex4/component_ablations/ENS4";
    const retained = if (output_dir != null)
        try std.Io.Dir.cwd().readFileAlloc(io, artifact_path, allocator, .limited(1024 * 1024 * 1024))
    else
        owned.bytes;
    defer if (output_dir != null) allocator.free(retained);
    const artifact_bytes = retained;

    // Open the bounded canonical envelope first, then measure the explicit
    // linear verification pass.  This keeps the ledger's timing boundaries
    // honest even though View.open is the safe convenience API.
    const open_start = std.Io.Clock.awake.now(io).nanoseconds;
    var view = try entropy.View.openEnvelope(artifact_bytes);
    const open_ns = elapsed(io, open_start);
    const verify_start = std.Io.Clock.awake.now(io).nanoseconds;
    try view.verify();
    const verify_ns = elapsed(io, verify_start);
    try checkCheckpointIndex(&view);
    const measure = try measureWire(artifact_bytes);
    const equal = try semanticCheck(&view, values);
    var observations: [max_raw_observations]RawObservation = undefined;
    const timing = try queryTiming(&view, values, repetitions, io, &observations);
    const observation_samples = if (repetitions < 1) @as(usize, 1) else repetitions;
    const observation_half = if (observation_samples < max_raw_observations / 2) observation_samples else max_raw_observations / 2;
    const observation_count = observation_half + observation_half;
    return .{
        .lane = lane,
        .representation = view.strategy(),
        .values = values.len,
        .alphabet = alphabetSize(values),
        .value_digest = digestValues(values),
        .artifact_sha256 = digestBytesHex(artifact_bytes),
        .artifact_path = artifact_path,
        .build_ns = build_ns,
        .open_ns = open_ns,
        .verify_ns = verify_ns,
        .serialized = measure,
        .semantic_equal = equal,
        .reopen_verified = true,
        .timing = timing,
        .raw_observations = observations,
        .raw_observation_count = observation_count,
    };
}

pub fn runLane(allocator: std.mem.Allocator, lane: Lane, count: usize, repetitions: usize, io: std.Io, output_dir: ?[]const u8) ![2]LaneResult {
    var generated = try makeLane(allocator, lane, count);
    defer generated.deinit();
    return .{
        try laneResult(allocator, lane, generated.values, .entropy, repetitions, io, output_dir),
        try laneResult(allocator, lane, generated.values, .@"packed", repetitions, io, output_dir),
    };
}

fn elapsed(io: std.Io, start: i128) u64 {
    const end = std.Io.Clock.awake.now(io).nanoseconds;
    return @intCast(@max(end - start, 0));
}

fn u64Hex(value: u64) [16]u8 {
    var encoded: [16]u8 = undefined;
    const digits = "0123456789abcdef";
    for (0..16) |index| {
        const shift: u6 = @intCast(60 - index * 4);
        encoded[index] = digits[@as(usize, @intCast((value >> shift) & 0xf))];
    }
    return encoded;
}

fn writeLaneVariant(json: *std.json.Stringify, result: LaneResult) !void {
    const oracle = u64Hex(result.value_digest);
    try json.beginObject();
    try json.objectField("artifact");
    try json.write(result.artifact_path);
    try json.objectField("artifact_sha256");
    try json.write(result.artifact_sha256[0..]);
    try json.objectField("artifact_bytes");
    try json.write(result.serialized.serialized_bytes);
    try json.objectField("build_ns");
    try json.write(result.build_ns);
    try json.objectField("open_ns");
    try json.write(result.open_ns);
    try json.objectField("verify_ns");
    try json.write(result.verify_ns);
    try json.objectField("verified");
    try json.write(result.reopen_verified and result.semantic_equal);
    try json.objectField("oracle_digest");
    try json.write(oracle[0..]);
    try json.objectField("timing_boundary");
    try json.write("canonical entropy.View reader operation; JSONL, allocation, and I/O excluded");
    try json.objectField("reader_p50_ns");
    try json.write(result.timing.reader_p50_ns);
    try json.objectField("raw_observation_count");
    try json.write(result.raw_observation_count);
    try json.objectField("raw_observations");
    try json.beginArray();
    for (result.raw_observations[0..result.raw_observation_count]) |observation| {
        try json.beginObject();
        try json.objectField("operation");
        try json.write(observation.operation);
        try json.objectField("elapsed_ns");
        try json.write(observation.elapsed_ns);
        try json.objectField("operations");
        try json.write(observation.operations);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("value_count");
    try json.write(result.values);
    try json.objectField("alphabet");
    try json.write(result.alphabet);
    try json.objectField("value_digest_u64");
    try json.write(result.value_digest);
    try json.objectField("header_bytes");
    try json.write(result.serialized.header_bytes);
    try json.objectField("checkpoint_index_bytes");
    try json.write(result.serialized.checkpoint_index_bytes);
    try json.objectField("payload_bytes");
    try json.write(result.serialized.payload_bytes);
    try json.objectField("alignment_bytes");
    try json.write(result.serialized.alignment_bytes);
    try json.objectField("checkpoint_count");
    try json.write(result.serialized.checkpoint_count);
    try json.objectField("checkpoint_stride");
    try json.write(result.serialized.checkpoint_stride);
    try json.objectField("semantic_equal");
    try json.write(result.semantic_equal);
    try json.objectField("query_elapsed_ns");
    try json.write(result.timing.query_elapsed_ns);
    try json.objectField("query_operations");
    try json.write(result.timing.query_operations);
    try json.objectField("query_ns_per_operation");
    try json.write(result.timing.query_ns_per_operation);
    try json.objectField("decode_elapsed_ns");
    try json.write(result.timing.decode_elapsed_ns);
    try json.objectField("decode_operations");
    try json.write(result.timing.decode_operations);
    try json.objectField("decode_ns_per_value");
    try json.write(result.timing.decode_ns_per_value);
    try json.objectField("timing_sink_u64");
    try json.write(result.timing.sink);
    try json.endObject();
}

fn writeLaneResult(allocator: std.mem.Allocator, writer: *std.Io.Writer, mirror: ?*std.Io.Writer, evidence_dir: ?[]const u8, results: [2]LaneResult) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    var json = std.json.Stringify{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("protocol");
    try json.write(protocol);
    try json.objectField("record");
    try json.write("entropy-vs-packed");
    try json.objectField("entropy_vs_packed");
    try json.beginObject();
    try json.objectField("status");
    try json.write(if (results[0].semantic_equal and results[1].semantic_equal and results[0].reopen_verified and results[1].reopen_verified) "measured" else "fail");
    try json.objectField("lane");
    try json.write(laneName(results[0].lane));
    try json.objectField("optimization");
    try json.write(optimizationName());
    const oracle = u64Hex(results[0].value_digest);
    try json.objectField("oracle_digest");
    try json.write(oracle[0..]);
    try json.objectField("variants");
    try json.beginObject();
    try json.objectField("entropy");
    try writeLaneVariant(&json, results[0]);
    try json.objectField("packed");
    try writeLaneVariant(&json, results[1]);
    try json.endObject();
    try json.objectField("evidence_paths");
    try json.beginArray();
    try json.write(results[0].artifact_path);
    try json.write(results[1].artifact_path);
    if (evidence_dir) |directory| {
        const ledger_path = try std.fmt.allocPrint(allocator, "{s}/ledger.jsonl", .{directory});
        const raw_path = try std.fmt.allocPrint(allocator, "{s}/raw_observations.jsonl", .{directory});
        try json.write(ledger_path);
        try json.write(raw_path);
    }
    try json.endArray();
    try json.endObject();
    try json.endObject();
    try output.writer.writeByte('\n');
    try writer.writeAll(output.written());
    if (mirror) |copy| try copy.writeAll(output.written());
}

fn writeRawObservation(allocator: std.mem.Allocator, writer: *std.Io.Writer, result: LaneResult, observation: RawObservation) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    var json = std.json.Stringify{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("protocol");
    try json.write(protocol);
    try json.objectField("record");
    try json.write("raw-observation");
    try json.objectField("optimization");
    try json.write(optimizationName());
    try json.objectField("lane");
    try json.write(laneName(result.lane));
    try json.objectField("representation");
    try json.write(strategyName(result.representation));
    try json.objectField("artifact");
    try json.write(result.artifact_path);
    try json.objectField("operation");
    try json.write(observation.operation);
    try json.objectField("elapsed_ns");
    try json.write(observation.elapsed_ns);
    try json.objectField("operations");
    try json.write(observation.operations);
    try json.objectField("timing_boundary");
    try json.write("canonical entropy.View reader operation; JSONL, allocation, and I/O excluded");
    try json.endObject();
    try output.writer.writeByte('\n');
    try writer.writeAll(output.written());
}

fn writeRegularFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [16 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    try file_writer.interface.writeAll(bytes);
    try file_writer.interface.flush();
}

pub fn writeLedger(allocator: std.mem.Allocator, writer: *std.Io.Writer, options: Options, io: std.Io) !void {
    if (options.records == 0) return error.InvalidInput;
    if (options.output_dir) |directory| try std.Io.Dir.cwd().createDirPath(io, directory);
    var ledger_capture: std.Io.Writer.Allocating = .init(allocator);
    var raw_capture: std.Io.Writer.Allocating = .init(allocator);
    for ([_]Lane{ .low, .medium, .high }) |lane| {
        const results = try runLane(allocator, lane, options.records, options.repetitions, io, options.output_dir);
        try writeLaneResult(allocator, writer, &ledger_capture.writer, options.output_dir, results);
        for (results) |result| for (result.raw_observations[0..result.raw_observation_count]) |observation|
            try writeRawObservation(allocator, &raw_capture.writer, result, observation);
    }
    if (options.output_dir) |directory| {
        try ledger_capture.writer.flush();
        try raw_capture.writer.flush();
        const ledger_path = try std.fmt.allocPrint(allocator, "{s}/ledger.jsonl", .{directory});
        const raw_path = try std.fmt.allocPrint(allocator, "{s}/raw_observations.jsonl", .{directory});
        try writeRegularFile(io, ledger_path, ledger_capture.written());
        try writeRegularFile(io, raw_path, raw_capture.written());
    }
    try writer.flush();
}

fn parseOptions(args: std.process.Args) !Options {
    var options = Options{};
    var iterator = std.process.Args.Iterator.init(args);
    _ = iterator.next();
    while (iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "--records")) {
            options.records = try std.fmt.parseUnsigned(usize, iterator.next() orelse return error.MissingRecords, 10);
        } else if (std.mem.eql(u8, arg, "--repetitions")) {
            options.repetitions = try std.fmt.parseUnsigned(usize, iterator.next() orelse return error.MissingRepetitions, 10);
        } else if (std.mem.eql(u8, arg, "--output-dir")) {
            options.output_dir = iterator.next() orelse return error.MissingOutputDir;
        } else if (std.mem.eql(u8, arg, "--help")) {
            return error.Help;
        } else return error.InvalidArgument;
    }
    return options;
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const options = parseOptions(init.minimal.args) catch |err| {
        if (err == error.Help) {
            std.debug.print("usage: component_ablations [--records N] [--repetitions N] [--output-dir DIR]\n", .{});
            return;
        }
        return err;
    };
    var output_buffer: [64 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    try writeLedger(allocator, &writer.interface, options, init.io);
}

test "lane builders produce deterministic values" {
    for ([_]Lane{ .low, .medium, .high }) |lane| {
        var first = try makeLane(std.testing.allocator, lane, 257);
        defer first.deinit();
        var second = try makeLane(std.testing.allocator, lane, 257);
        defer second.deinit();
        try std.testing.expectEqualSlices(u32, first.values, second.values);
    }
}
