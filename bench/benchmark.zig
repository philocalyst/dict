//! Reproducible measurements for the snapshot payload profiles.
//!
//! This file deliberately stays outside build.zig: it is an experiment driver,
//! not part of the library's public API.  Build it with the command in
//! docs/benchmark-methodology.md so the pinned libbz3 translation unit is
//! available when the optional codec measurements are enabled.

const std = @import("std");
const builtin = @import("builtin");
const lex = @import("lexicon");

const default_seed: u64 = 0x4c455849434f4e31;
const default_records: usize = 20_000;
const default_repetitions: usize = 20_000;
const default_warmup: usize = 2_000;
const max_key_bytes = 256;

const PayloadCodec = enum { raw, bzip3 };
const PostingEncoding = enum { raw, adaptive };

const Config = struct {
    records: usize = default_records,
    repetitions: usize = default_repetitions,
    warmup: usize = default_warmup,
    seed: u64 = default_seed,
    payload_codec: PayloadCodec = .raw,
    posting_encoding: PostingEncoding = .adaptive,
    low_level_codec: bool = true,
};

const Fixture = struct {
    allocator: std.mem.Allocator,
    keys: std.ArrayList([]u8) = .empty,
    definitions: std.ArrayList([]u8) = .empty,

    fn init(allocator: std.mem.Allocator, config: Config) !Fixture {
        var fixture = Fixture{ .allocator = allocator };
        errdefer fixture.deinit();

        try fixture.keys.ensureTotalCapacity(allocator, config.records);
        try fixture.definitions.ensureTotalCapacity(allocator, config.records);
        var random = Random.init(config.seed);
        for (0..config.records) |index| {
            const key = try makeKey(allocator, index, config.records);
            errdefer allocator.free(key);
            const definition = try makeDefinition(allocator, index, &random);
            errdefer allocator.free(definition);
            try fixture.keys.append(allocator, key);
            try fixture.definitions.append(allocator, definition);
        }
        return fixture;
    }

    fn deinit(self: *Fixture) void {
        for (self.keys.items) |key| self.allocator.free(key);
        for (self.definitions.items) |definition| self.allocator.free(definition);
        self.keys.deinit(self.allocator);
        self.definitions.deinit(self.allocator);
        self.* = undefined;
    }
};

const Random = struct {
    state: u64,

    fn init(seed: u64) Random {
        return .{ .state = if (seed == 0) default_seed else seed };
    }

    fn next(self: *Random) u64 {
        // xorshift64* is tiny, deterministic on every target, and sufficient
        // here because this is a workload generator rather than a PRNG API.
        var value = self.state;
        value ^= value >> 12;
        value ^= value << 25;
        value ^= value >> 27;
        self.state = value;
        return value *% 0x2545f4914f6cdd1d;
    }
};

const QueryKind = enum { exact_hit, exact_miss, prefix_hit, prefix_miss };

const Query = struct {
    kind: QueryKind,
    key: []const u8,
    expected: usize,
};

const Workload = struct {
    allocator: std.mem.Allocator,
    queries: std.ArrayList(Query) = .empty,
    query_storage: std.ArrayList([]u8) = .empty,
    definition_ids: std.ArrayList(u64) = .empty,

    fn init(allocator: std.mem.Allocator, fixture: *const Fixture, config: Config) !Workload {
        var workload = Workload{ .allocator = allocator };
        errdefer workload.deinit();
        try workload.queries.ensureTotalCapacity(allocator, config.repetitions);
        try workload.definition_ids.ensureTotalCapacity(allocator, config.repetitions);

        var random = Random.init(config.seed ^ 0x9e3779b97f4a7c15);
        for (0..config.repetitions) |ordinal| {
            const source = @as(usize, @intCast(random.next() % fixture.keys.items.len));
            const selector = ordinal % 4;
            var query_key: []u8 = undefined;
            var kind: QueryKind = undefined;
            var expected: usize = 0;
            switch (selector) {
                0 => {
                    query_key = try allocator.dupe(u8, fixture.keys.items[source]);
                    kind = .exact_hit;
                    expected = exactCount(fixture.keys.items, query_key);
                },
                1 => {
                    query_key = try std.fmt.allocPrint(allocator, "missing-{x:0>16}", .{random.next()});
                    kind = .exact_miss;
                },
                2 => {
                    const key = fixture.keys.items[source];
                    const length = @max(@as(usize, 1), key.len / 2);
                    query_key = try allocator.dupe(u8, key[0..length]);
                    kind = .prefix_hit;
                    expected = prefixCount(fixture.keys.items, query_key);
                },
                3 => {
                    query_key = try std.fmt.allocPrint(allocator, "zz-missing-{x:0>16}", .{random.next()});
                    kind = .prefix_miss;
                },
                else => unreachable,
            }
            try workload.query_storage.append(allocator, query_key);
            try workload.queries.append(allocator, .{ .kind = kind, .key = query_key, .expected = expected });
            try workload.definition_ids.append(allocator, @as(u64, @intCast(source)));
        }
        return workload;
    }

    fn deinit(self: *Workload) void {
        for (self.query_storage.items) |key| self.allocator.free(key);
        self.query_storage.deinit(self.allocator);
        self.queries.deinit(self.allocator);
        self.definition_ids.deinit(self.allocator);
        self.* = undefined;
    }
};

const Metrics = struct {
    operations: u64 = 0,
    elapsed_ns: u64 = 0,
    outputs: u64 = 0,
    key_records_examined: u64 = 0,
    payload_reads: u64 = 0,
    checksum: u64 = 0,

    fn perOperation(self: Metrics, value: u64) f64 {
        if (self.operations == 0) return 0;
        return @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(self.operations));
    }

    fn nsPerOperation(self: Metrics) f64 {
        return self.perOperation(self.elapsed_ns);
    }

    fn throughput(self: Metrics) f64 {
        if (self.elapsed_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.operations)) * @as(f64, @floatFromInt(std.time.ns_per_s)) /
            @as(f64, @floatFromInt(self.elapsed_ns));
    }
};

const Timer = struct {
    io: std.Io,
    start_ns: i96,

    fn start(io: std.Io) Timer {
        return .{ .io = io, .start_ns = std.Io.Clock.awake.now(io).nanoseconds };
    }

    fn read(self: *Timer) u64 {
        const elapsed = std.Io.Clock.awake.now(self.io).nanoseconds - self.start_ns;
        return @intCast(@max(@as(i96, 0), elapsed));
    }
};

fn makeKey(allocator: std.mem.Allocator, index: usize, record_count: usize) ![]u8 {
    // Repeated stems create realistic postings and exercise the front-coded
    // key path.  Every 17th key carries a multilingual suffix so the fixture
    // is not accidentally English-only or ASCII-only.
    const stem = index % @max(@as(usize, 1), record_count / 128);
    if (index % 17 == 0) {
        return std.fmt.allocPrint(allocator, "entry-{d:0>6}-é-東京", .{stem});
    }
    return std.fmt.allocPrint(allocator, "entry-{d:0>6}", .{stem});
}

fn makeDefinition(allocator: std.mem.Allocator, index: usize, random: *Random) ![]u8 {
    const variant = random.next() & 3;
    return std.fmt.allocPrint(allocator, "entry {d} definition variant {d}: a deterministic lexical explanation with " ++
        "evidence, usage, and a stable repeated phrase for compression measurements.", .{ index, variant });
}

fn prefixCount(keys: []const []u8, prefix: []const u8) usize {
    var count: usize = 0;
    for (keys) |key| {
        if (std.mem.startsWith(u8, key, prefix)) count += 1;
    }
    return count;
}

fn exactCount(keys: []const []u8, needle: []const u8) usize {
    var count: usize = 0;
    for (keys) |key| {
        if (std.mem.eql(u8, key, needle)) count += 1;
    }
    return count;
}

fn fixtureDigest(fixture: *const Fixture) u64 {
    var digest: u64 = 0xcbf29ce484222325;
    for (fixture.keys.items, fixture.definitions.items) |key, definition| {
        digest = hashBytes(digest, key);
        digest = hashBytes(digest, definition);
    }
    return digest;
}

fn hashBytes(start: u64, bytes: []const u8) u64 {
    var digest = start;
    for (bytes) |byte| digest = (digest ^ byte) *% 0x100000001b3;
    return digest;
}

fn warmExact(reader: *lex.Reader, workload: *const Workload, warmup: usize, ids: []u64) !void {
    for (0..warmup) |index| {
        const query = workload.queries.items[index % workload.queries.items.len];
        if (query.kind != .exact_hit and query.kind != .exact_miss) continue;
        const count = try reader.lookupExact(query.key, ids);
        if (count != query.expected) return error.WorkloadMismatch;
    }
}

fn measureExact(io: std.Io, reader: *lex.Reader, workload: *const Workload, config: Config, ids: []u64) !Metrics {
    var metrics = Metrics{};
    var timer = Timer.start(io);
    for (0..config.repetitions) |index| {
        const query = workload.queries.items[index % workload.queries.items.len];
        if (query.kind != .exact_hit and query.kind != .exact_miss) continue;
        const count = try reader.lookupExact(query.key, ids);
        if (count != query.expected) return error.WorkloadMismatch;
        metrics.operations += 1;
        metrics.outputs += count;
        metrics.checksum = hashIds(metrics.checksum, ids[0..count]);
    }
    metrics.elapsed_ns = timer.read();
    metrics.key_records_examined = reader.keyRecordsExamined();
    return metrics;
}

fn warmPrefix(reader: *lex.Reader, workload: *const Workload, warmup: usize, ids: []u64) !void {
    for (0..warmup) |index| {
        const query = workload.queries.items[index % workload.queries.items.len];
        if (query.kind != .prefix_hit and query.kind != .prefix_miss) continue;
        const count = try reader.lookupPrefix(query.key, ids);
        if (count != query.expected) return error.WorkloadMismatch;
    }
}

fn measurePrefix(io: std.Io, reader: *lex.Reader, workload: *const Workload, config: Config, ids: []u64) !Metrics {
    var metrics = Metrics{};
    var timer = Timer.start(io);
    for (0..config.repetitions) |index| {
        const query = workload.queries.items[index % workload.queries.items.len];
        if (query.kind != .prefix_hit and query.kind != .prefix_miss) continue;
        const count = try reader.lookupPrefix(query.key, ids);
        if (count != query.expected) return error.WorkloadMismatch;
        metrics.operations += 1;
        metrics.outputs += count;
        metrics.checksum = hashIds(metrics.checksum, ids[0..count]);
    }
    metrics.elapsed_ns = timer.read();
    metrics.key_records_examined = reader.keyRecordsExamined();
    return metrics;
}

fn measureDefinitions(io: std.Io, reader: *lex.Reader, workload: *const Workload, config: Config, buffer: []u8) !Metrics {
    var metrics = Metrics{};
    var timer = Timer.start(io);
    for (0..config.repetitions) |index| {
        const id = workload.definition_ids.items[index % workload.definition_ids.items.len];
        const length = try reader.definition(id, buffer);
        metrics.operations += 1;
        metrics.outputs += length;
        metrics.payload_reads = reader.payloadReadCount();
        metrics.checksum = hashBytes(metrics.checksum, buffer[0..length]);
    }
    metrics.elapsed_ns = timer.read();
    return metrics;
}

fn hashIds(start: u64, ids: []const u64) u64 {
    var digest = start;
    for (ids) |id| digest = (digest ^ id) *% 0x100000001b3;
    return digest;
}

fn printMetric(name: []const u8, value: anytype) void {
    std.debug.print("metric\t{s}\t{any}\n", .{ name, value });
}

fn printMetrics(prefix: []const u8, metrics: Metrics) void {
    std.debug.print("metric\t{s}.operations\t{any}\n", .{ prefix, metrics.operations });
    std.debug.print("metric\t{s}.elapsed_ns\t{any}\n", .{ prefix, metrics.elapsed_ns });
    std.debug.print("metric\t{s}.ns_per_operation\t{any}\n", .{ prefix, metrics.nsPerOperation() });
    std.debug.print("metric\t{s}.operations_per_second\t{any}\n", .{ prefix, metrics.throughput() });
    std.debug.print("metric\t{s}.outputs_per_operation\t{any}\n", .{ prefix, metrics.perOperation(metrics.outputs) });
    std.debug.print("metric\t{s}.key_records_examined_per_operation\t{any}\n", .{ prefix, metrics.perOperation(metrics.key_records_examined) });
    std.debug.print("metric\t{s}.payload_reads_per_operation\t{any}\n", .{ prefix, metrics.perOperation(metrics.payload_reads) });
    std.debug.print("metric\t{s}.checksum\t{any}\n", .{ prefix, metrics.checksum });
}

fn printSnapshotLedger(snapshot: []const u8) void {
    if (snapshot.len < 64) return;
    const directory_offset: usize = @intCast(std.mem.readInt(u64, snapshot[24..32], .little));
    const directory_length: usize = @intCast(std.mem.readInt(u64, snapshot[32..40], .little));
    printMetric("fixture.snapshot.header_bytes", @as(usize, 64));
    printMetric("fixture.snapshot.directory_bytes", directory_length);
    if (directory_offset > snapshot.len or directory_length > snapshot.len - directory_offset) return;
    var at = directory_offset;
    const end = directory_offset + directory_length;
    while (at + 48 <= end) : (at += 48) {
        const kind = std.mem.readInt(u32, snapshot[at..][0..4], .little);
        const offset: usize = @intCast(std.mem.readInt(u64, snapshot[at + 8 ..][0..8], .little));
        const length: usize = @intCast(std.mem.readInt(u64, snapshot[at + 16 ..][0..8], .little));
        const name = switch (kind) {
            1 => "keys",
            2 => "postings",
            3 => "payload",
            else => "unknown",
        };
        std.debug.print("metric\tfixture.snapshot.section_{s}_bytes\t{}\n", .{ name, length });
        _ = offset;
    }
}

fn runCodecBenchmark(io: std.Io, allocator: std.mem.Allocator, fixture: *const Fixture, config: Config) !void {
    if (!@hasDecl(lex, "Codec")) {
        std.debug.print("metric\tcodec.status\tunavailable\n", .{});
        return;
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);
    for (fixture.definitions.items) |definition| try bytes.appendSlice(allocator, definition);
    const block_size = 65 * 1024;

    var raw_total: usize = 0;
    var bzip_total: usize = 0;
    var raw_encode_ns: u64 = 0;
    var bzip_encode_ns: u64 = 0;
    var raw_decode_ns: u64 = 0;
    var bzip_decode_ns: u64 = 0;
    var block_count: usize = 0;
    var offset: usize = 0;
    while (offset < bytes.items.len) : (offset += @min(block_size, bytes.items.len - offset)) {
        const input = bytes.items[offset .. offset + @min(block_size, bytes.items.len - offset)];
        block_count += 1;
        var timer = Timer.start(io);
        var raw = try lex.Codec.encodeBlock(allocator, input, .{ .kind = .raw });
        raw_encode_ns += timer.read();
        defer raw.deinit();
        raw_total += raw.bytes().len;

        timer = Timer.start(io);
        var bzip = try lex.Codec.encodeBlock(allocator, input, .{ .kind = .bzip3, .block_size = block_size });
        bzip_encode_ns += timer.read();
        defer bzip.deinit();
        bzip_total += bzip.bytes().len;

        timer = Timer.start(io);
        var raw_decoded = try lex.Codec.decodeBlock(allocator, raw.bytes(), raw.originalSize(), .{ .kind = .raw });
        raw_decode_ns += timer.read();
        defer raw_decoded.deinit();
        if (!std.mem.eql(u8, input, raw_decoded.bytes())) return error.CodecMismatch;

        timer = Timer.start(io);
        var bzip_decoded = try lex.Codec.decodeBlock(allocator, bzip.bytes(), bzip.originalSize(), .{ .kind = .bzip3, .block_size = block_size });
        bzip_decode_ns += timer.read();
        defer bzip_decoded.deinit();
        if (!std.mem.eql(u8, input, bzip_decoded.bytes())) return error.CodecMismatch;
    }
    _ = config;
    std.debug.print("metric\tcodec.status\tmeasured\n", .{});
    printMetric("lowlevel_codec.block_size", block_size);
    printMetric("lowlevel_codec.blocks", block_count);
    printMetric("lowlevel_codec.input_bytes", bytes.items.len);
    printMetric("lowlevel_codec.raw_bytes", raw_total);
    printMetric("lowlevel_codec.bzip3_bytes", bzip_total);
    printMetric("lowlevel_codec.bzip3_ratio", @as(f64, @floatFromInt(bzip_total)) / @as(f64, @floatFromInt(bytes.items.len)));
    printMetric("lowlevel_codec.raw_encode_ns", raw_encode_ns);
    printMetric("lowlevel_codec.bzip3_encode_ns", bzip_encode_ns);
    printMetric("lowlevel_codec.raw_decode_ns", raw_decode_ns);
    printMetric("lowlevel_codec.bzip3_decode_ns", bzip_decode_ns);
}

fn parseConfig(allocator: std.mem.Allocator, process_args: std.process.Args) !Config {
    var config = Config{};
    var args = std.process.Args.Iterator.init(process_args);
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--no-codec")) {
            config.low_level_codec = false;
        } else if (std.mem.startsWith(u8, arg, "--payload-codec=")) {
            const value = arg["--payload-codec=".len..];
            if (std.mem.eql(u8, value, "raw")) {
                config.payload_codec = .raw;
            } else if (std.mem.eql(u8, value, "bzip3")) {
                config.payload_codec = .bzip3;
            } else {
                return error.InvalidArgument;
            }
        } else if (std.mem.startsWith(u8, arg, "--posting-encoding=")) {
            const value = arg["--posting-encoding=".len..];
            if (std.mem.eql(u8, value, "raw")) {
                config.posting_encoding = .raw;
            } else if (std.mem.eql(u8, value, "adaptive")) {
                config.posting_encoding = .adaptive;
            } else {
                return error.InvalidArgument;
            }
        } else if (std.mem.startsWith(u8, arg, "--records=")) {
            config.records = try std.fmt.parseUnsigned(usize, arg[10..], 10);
        } else if (std.mem.startsWith(u8, arg, "--repetitions=")) {
            config.repetitions = try std.fmt.parseUnsigned(usize, arg[14..], 10);
        } else if (std.mem.startsWith(u8, arg, "--warmup=")) {
            config.warmup = try std.fmt.parseUnsigned(usize, arg[9..], 10);
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            config.seed = try std.fmt.parseUnsigned(u64, arg[7..], 0);
        } else {
            std.debug.print("unknown option: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }
    if (config.records == 0 or config.repetitions == 0) return error.InvalidArgument;
    _ = allocator;
    return config;
}

fn initWriter(allocator: std.mem.Allocator, payload_codec: PayloadCodec, posting_encoding: PostingEncoding) anyerror!lex.Writer {
    if (comptime @hasField(lex.Writer.Options, "posting_encoding")) {
        return lex.Writer.initWithOptions(allocator, .{
            .payload_codec = if (payload_codec == .raw) .raw else .bzip3,
            .posting_encoding = if (posting_encoding == .raw) .raw else .adaptive,
        });
    }
    return switch (payload_codec) {
        .raw => lex.Writer.init(allocator),
        .bzip3 => if (comptime @hasDecl(lex.Writer, "initWithOptions"))
            lex.Writer.initWithOptions(allocator, .{ .payload_codec = .bzip3 })
        else
            error.PayloadCodecUnavailable,
    };
}

fn buildSnapshot(allocator: std.mem.Allocator, fixture: *const Fixture, payload_codec: PayloadCodec, posting_encoding: PostingEncoding) anyerror![]u8 {
    var writer = try initWriter(allocator, payload_codec, posting_encoding);
    defer writer.deinit();
    for (fixture.keys.items, fixture.definitions.items, 0..) |key, definition, index| {
        try writer.add(.{ .id = @intCast(index), .key = key, .definition = definition });
    }
    return writer.build();
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const config = try parseConfig(allocator, init.minimal.args);
    var fixture = try Fixture.init(allocator, config);
    defer fixture.deinit();
    var workload = try Workload.init(allocator, &fixture, config);
    defer workload.deinit();

    var timer = Timer.start(init.io);
    const snapshot = buildSnapshot(allocator, &fixture, config.payload_codec, config.posting_encoding) catch |err| switch (err) {
        error.PayloadCodecUnavailable => {
            std.debug.print("metric\tconfig.payload_codec\t{s}\n", .{@tagName(config.payload_codec)});
            std.debug.print("metric\tpayload_profile.status\tunavailable\n", .{});
            return;
        },
        else => return err,
    };
    const build_ns = timer.read();
    defer allocator.free(snapshot);
    var reader = try lex.Reader.open(snapshot);

    const ids = try allocator.alloc(u64, fixture.keys.items.len + 8);
    defer allocator.free(ids);
    const definition_buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(definition_buffer);

    const digest = fixtureDigest(&fixture);
    std.debug.print("metric\tmetadata.zig_version\t{s}\n", .{builtin.zig_version_string});
    std.debug.print("metric\tmetadata.target\t{s}\n", .{@tagName(builtin.target.os.tag)});
    std.debug.print("metric\tmetadata.arch\t{s}\n", .{@tagName(builtin.target.cpu.arch)});
    printMetric("config.records", config.records);
    printMetric("config.repetitions", config.repetitions);
    printMetric("config.warmup", config.warmup);
    printMetric("config.seed", config.seed);
    std.debug.print("metric\tconfig.payload_codec\t{s}\n", .{@tagName(config.payload_codec)});
    std.debug.print("metric\tconfig.posting_encoding\t{s}\n", .{@tagName(config.posting_encoding)});
    std.debug.print("metric\tposting.status\t{s}\n", .{if (comptime @hasField(lex.Writer.Options, "posting_encoding")) "measured" else "unavailable"});
    printMetric("fixture.digest", digest);
    printMetric("fixture.snapshot_bytes", snapshot.len);
    printMetric("fixture.build_ns", build_ns);
    printSnapshotLedger(snapshot);

    reader.resetLookupMetrics();
    try warmExact(&reader, &workload, config.warmup, ids);
    reader.resetLookupMetrics();
    const exact = try measureExact(init.io, &reader, &workload, config, ids);
    printMetrics("exact", exact);

    reader.resetLookupMetrics();
    try warmPrefix(&reader, &workload, config.warmup, ids);
    reader.resetLookupMetrics();
    const prefix = try measurePrefix(init.io, &reader, &workload, config, ids);
    printMetrics("prefix", prefix);

    reader.resetLookupMetrics();
    const definitions = try measureDefinitions(init.io, &reader, &workload, config, definition_buffer);
    printMetrics("definition", definitions);

    if (config.low_level_codec) try runCodecBenchmark(init.io, allocator, &fixture, config);
}

test "fixture generation is deterministic" {
    const config = Config{ .records = 128, .repetitions = 64 };
    var first = try Fixture.init(std.testing.allocator, config);
    defer first.deinit();
    var second = try Fixture.init(std.testing.allocator, config);
    defer second.deinit();
    try std.testing.expectEqual(fixtureDigest(&first), fixtureDigest(&second));
    try std.testing.expectEqualSlices(u8, first.keys.items[17], second.keys.items[17]);
    try std.testing.expectEqualSlices(u8, first.definitions.items[127], second.definitions.items[127]);
}

test "workload generation preserves expected hit classes" {
    const config = Config{ .records = 64, .repetitions = 100, .warmup = 2 };
    var fixture = try Fixture.init(std.testing.allocator, config);
    defer fixture.deinit();
    var workload = try Workload.init(std.testing.allocator, &fixture, config);
    defer workload.deinit();
    for (workload.queries.items) |query| {
        switch (query.kind) {
            .exact_hit => try std.testing.expect(query.expected > 0),
            .exact_miss, .prefix_miss => try std.testing.expectEqual(@as(usize, 0), query.expected),
            .prefix_hit => try std.testing.expect(query.expected > 0),
        }
    }
}

test "raw and bzip3 payload profiles preserve lookup answers" {
    if (comptime !@hasDecl(lex.Writer, "initWithOptions")) return error.SkipZigTest;
    const config = Config{ .records = 128, .repetitions = 32 };
    var fixture = try Fixture.init(std.testing.allocator, config);
    defer fixture.deinit();

    const raw_snapshot = try buildSnapshot(std.testing.allocator, &fixture, .raw, .adaptive);
    defer std.testing.allocator.free(raw_snapshot);
    const bzip_snapshot = try buildSnapshot(std.testing.allocator, &fixture, .bzip3, .adaptive);
    defer std.testing.allocator.free(bzip_snapshot);
    var raw_reader = try lex.Reader.open(raw_snapshot);
    var bzip_reader = try lex.Reader.open(bzip_snapshot);

    var raw_ids: [128]u64 = undefined;
    var bzip_ids: [128]u64 = undefined;
    for ([_][]const u8{ fixture.keys.items[0], fixture.keys.items[17], "missing-key" }) |key| {
        const expected = exactCount(fixture.keys.items, key);
        const raw_count = try raw_reader.lookupExact(key, raw_ids[0..]);
        const bzip_count = try bzip_reader.lookupExact(key, bzip_ids[0..]);
        try std.testing.expectEqual(expected, raw_count);
        try std.testing.expectEqual(raw_count, bzip_count);
        try std.testing.expectEqualSlices(u64, raw_ids[0..raw_count], bzip_ids[0..bzip_count]);
    }

    var raw_definition: [4096]u8 = undefined;
    var bzip_definition: [4096]u8 = undefined;
    for ([_]u64{ 0, 17, 127 }) |id| {
        const raw_length = try raw_reader.definition(id, raw_definition[0..]);
        const bzip_length = try bzip_reader.definition(id, bzip_definition[0..]);
        try std.testing.expectEqual(raw_length, bzip_length);
        try std.testing.expectEqualSlices(u8, raw_definition[0..raw_length], bzip_definition[0..bzip_length]);
    }
    try std.testing.expect(raw_snapshot.len != 0);
    try std.testing.expect(bzip_snapshot.len != 0);
}

test "posting profiles preserve answers under the same payload codec" {
    if (comptime !@hasField(lex.Writer.Options, "posting_encoding")) return error.SkipZigTest;
    const config = Config{ .records = 64, .repetitions = 16 };
    var fixture = try Fixture.init(std.testing.allocator, config);
    defer fixture.deinit();
    const raw_postings = try buildSnapshot(std.testing.allocator, &fixture, .raw, .raw);
    defer std.testing.allocator.free(raw_postings);
    const adaptive_postings = try buildSnapshot(std.testing.allocator, &fixture, .raw, .adaptive);
    defer std.testing.allocator.free(adaptive_postings);
    var raw_reader = try lex.Reader.open(raw_postings);
    var adaptive_reader = try lex.Reader.open(adaptive_postings);
    var raw_ids: [64]u64 = undefined;
    var adaptive_ids: [64]u64 = undefined;
    const key = fixture.keys.items[11];
    const raw_count = try raw_reader.lookupPrefix(key[0..@max(@as(usize, 1), key.len / 2)], raw_ids[0..]);
    const adaptive_count = try adaptive_reader.lookupPrefix(key[0..@max(@as(usize, 1), key.len / 2)], adaptive_ids[0..]);
    try std.testing.expectEqual(raw_count, adaptive_count);
    try std.testing.expectEqualSlices(u64, raw_ids[0..raw_count], adaptive_ids[0..adaptive_count]);
}

test "metrics report only completed operations" {
    var metrics = Metrics{ .operations = 4, .elapsed_ns = 20, .outputs = 8 };
    try std.testing.expectEqual(@as(f64, 5), metrics.nsPerOperation());
    try std.testing.expectEqual(@as(f64, 2), metrics.perOperation(metrics.outputs));
    try std.testing.expect(metrics.throughput() > 0);
    metrics = .{};
    try std.testing.expectEqual(@as(f64, 0), metrics.nsPerOperation());
    try std.testing.expectEqual(@as(f64, 0), metrics.throughput());
}
