//! Reproducible cross-format benchmark driver.
//!
//! The executable owns one deterministic lexical fixture and runs the same
//! exact, prefix, open, and render workload through v1 and v2.  It prints
//! tab-separated observations; bench2/run.sh adds external baselines and
//! retains the raw stream before making JSON or summaries.

const std = @import("std");
const builtin = @import("builtin");
const v1 = @import("src/lexicon.zig");
const s = @import("src2/schema.zig");
const c = @import("src2/compile.zig");
const p = @import("src2/prose.zig");
const snap = @import("src2/snapshot.zig");
const q = @import("src2/query.zig");

const default_records: usize = 2_048;
const default_repetitions: usize = 1_000;
const default_warmup: usize = 200;
const default_seed: u64 = 0x4c455832_0002_0001;

const FixtureKind = enum { flat, prose_heavy, repeated, rich, pathological_prefix };
const Codec = enum { raw, bzip3 };
const Preset = enum { latency, balanced, compact };
const ExactClass = enum { hit, miss };
const PrefixClass = enum { zero, one, many, pathological };
const QueryMeasurement = struct { elapsed_ns: u64, count: usize };

const Record = struct {
    key: []u8,
    definition: []u8,
};

const Fixture = struct {
    allocator: std.mem.Allocator,
    kind: FixtureKind,
    seed: u64,
    records: []Record,
    root_ids: []usize,
    definition_ids: []usize,
    node_to_record: []usize,
    digest: u64,
    logical_prose_bytes: usize,

    fn init(allocator: std.mem.Allocator, kind: FixtureKind, records: usize, seed: u64) !Fixture {
        var result = Fixture{
            .allocator = allocator,
            .kind = kind,
            .seed = seed,
            .records = try allocator.alloc(Record, records),
            .root_ids = try allocator.alloc(usize, records),
            .definition_ids = try allocator.alloc(usize, records),
            .node_to_record = &.{},
            .digest = 0xcbf29ce484222325,
            .logical_prose_bytes = 0,
        };
        for (result.records) |*item| item.* = .{ .key = &.{}, .definition = &.{} };
        errdefer {
            for (result.records) |item| {
                if (item.key.len != 0) allocator.free(item.key);
                if (item.definition.len != 0) allocator.free(item.definition);
            }
            allocator.free(result.records);
            allocator.free(result.root_ids);
            allocator.free(result.definition_ids);
            if (result.node_to_record.len != 0) allocator.free(result.node_to_record);
        }
        var next_node: usize = 0;
        for (result.records, 0..) |*item, i| {
            result.root_ids[i] = next_node;
            result.definition_ids[i] = next_node + 3;
            item.key = try makeKey(allocator, kind, i);
            errdefer allocator.free(item.key);
            item.definition = try makeDefinition(allocator, kind, i, seed);
            result.logical_prose_bytes += item.definition.len;
            result.digest = hashBytes(result.digest, item.key);
            result.digest = hashBytes(result.digest, item.definition);
            next_node += if (kind == .rich and i != 0) 7 else 4;
        }
        result.node_to_record = try allocator.alloc(usize, next_node);
        @memset(result.node_to_record, std.math.maxInt(usize));
        for (result.root_ids, 0..) |root, i| {
            const end = if (i + 1 < result.root_ids.len) result.root_ids[i + 1] else next_node;
            for (result.node_to_record[root..end]) |*record| record.* = i;
        }
        return result;
    }

    fn deinit(self: *Fixture) void {
        for (self.records) |item| {
            self.allocator.free(item.key);
            self.allocator.free(item.definition);
        }
        self.allocator.free(self.root_ids);
        self.allocator.free(self.definition_ids);
        self.allocator.free(self.node_to_record);
        self.allocator.free(self.records);
        self.* = undefined;
    }
};

const Workload = struct {
    allocator: std.mem.Allocator,
    exact: []Probe,
    prefix: []Probe,
    render_ids: []usize,

    const Probe = struct {
        key: []u8,
        expected: usize,
        exact_class: ExactClass = .hit,
        prefix_class: PrefixClass = .many,
    };

    fn init(allocator: std.mem.Allocator, fixture: *const Fixture, count: usize) !Workload {
        const n = @max(@as(usize, 1), count);
        var result = Workload{
            .allocator = allocator,
            .exact = try allocator.alloc(Probe, n),
            .prefix = try allocator.alloc(Probe, n),
            .render_ids = try allocator.alloc(usize, n),
        };
        for (result.exact) |*probe| probe.* = .{ .key = &.{}, .expected = 0 };
        for (result.prefix) |*probe| probe.* = .{ .key = &.{}, .expected = 0 };
        @memset(result.render_ids, 0);
        errdefer result.deinit();
        for (0..n) |i| {
            const source = (i * 7919 + 17) % fixture.records.len;
            const exact_key = switch (i % 8) {
                0, 2, 4, 6 => fixture.records[source].key,
                1 => "missing-entry-key",
                3 => "",
                5 => "absent-ß-東京-!",
                else => fixture.records[0].key,
            };
            const exact_expected = expectedExact(fixture, exact_key);
            result.exact[i] = .{
                .key = try allocator.dupe(u8, exact_key),
                .expected = exact_expected,
                .exact_class = if (exact_expected == 0) .miss else .hit,
            };
            const key = fixture.records[source].key;
            const prefix = switch (i % 8) {
                0 => "zzzz-missing",
                1 => key,
                2 => "entry-",
                3 => key[0..@min(key.len, @as(usize, 6))],
                4 => "entry-00000000-",
                5 => "absent-ß-東京",
                6 => if (kindIsPathological(fixture.kind)) "pathological-prefix-" else "entry-",
                else => key[0..@min(key.len, @as(usize, 3))],
            };
            const prefix_expected = expectedPrefix(fixture, prefix);
            result.prefix[i] = .{
                .key = try allocator.dupe(u8, prefix),
                .expected = prefix_expected,
                .prefix_class = classifyPrefix(fixture.kind, prefix_expected, fixture.records.len),
            };
            result.render_ids[i] = source;
        }
        return result;
    }

    fn deinit(self: *Workload) void {
        for (self.exact) |probe| self.allocator.free(probe.key);
        for (self.prefix) |probe| self.allocator.free(probe.key);
        self.allocator.free(self.exact);
        self.allocator.free(self.prefix);
        self.allocator.free(self.render_ids);
        self.* = undefined;
    }
};

const Config = struct {
    records: usize = default_records,
    repetitions: usize = default_repetitions,
    warmup: usize = default_warmup,
    seed: u64 = default_seed,
    fixture: ?FixtureKind = null,
    presets: [3]Preset = .{ .latency, .balanced, .compact },
    preset_count: usize = 3,
    emit_corpus: ?[]const u8 = null,
    artifact_dir: ?[]const u8 = null,
};

const Samples = struct {
    allocator: std.mem.Allocator,
    values: []u64,

    fn init(allocator: std.mem.Allocator, count: usize) !Samples {
        return .{ .allocator = allocator, .values = try allocator.alloc(u64, count) };
    }
    fn deinit(self: *Samples) void {
        self.allocator.free(self.values);
        self.* = undefined;
    }
    fn percentiles(self: *Samples) [3]u64 {
        std.mem.sort(u64, self.values, {}, std.sort.asc(u64));
        return .{
            self.values[(self.values.len * 50) / 100],
            self.values[(self.values.len * 95) / 100],
            self.values[(self.values.len * 99) / 100],
        };
    }
};

const V2Artifact = struct {
    owned: snap.Owned,
    view: snap.Snapshot,
    prose_store: p.Store,
    preset: Preset,
    codec: Codec,
    build_ns: u64,

    fn deinit(self: *V2Artifact) void {
        self.owned.deinit();
        self.* = undefined;
    }
};

const V1Artifact = struct {
    bytes: []u8,
    reader: v1.Reader,
    codec: Codec,
    build_ns: u64,
    allocator: std.mem.Allocator,

    fn deinit(self: *V1Artifact) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn hashBytes(start: u64, bytes: []const u8) u64 {
    var value = start;
    for (bytes) |byte| value = (value ^ byte) *% 0x100000001b3;
    return value;
}

fn hashU64(start: u64, value: u64) u64 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    return hashBytes(start, &bytes);
}

fn makeKey(allocator: std.mem.Allocator, kind: FixtureKind, index: usize) ![]u8 {
    return switch (kind) {
        .pathological_prefix => std.fmt.allocPrint(allocator, "pathological-prefix-shared-{d:0>8}", .{index}),
        .repeated => if (index % 4 < 2)
            std.fmt.allocPrint(allocator, "repeat-{d:0>6}-é-東京", .{index / 2})
        else if (index % 37 == 1)
            std.fmt.allocPrint(allocator, "entry-{d:0>8}-special.%_!?", .{index})
        else
            std.fmt.allocPrint(allocator, "entry-{d:0>8}", .{index}),
        .flat, .prose_heavy, .rich => if (index % 29 == 0)
            std.fmt.allocPrint(allocator, "entry-{d:0>8}-é-東京", .{index})
        else if (index % 37 == 1)
            std.fmt.allocPrint(allocator, "entry-{d:0>8}-special.%_!?", .{index})
        else
            std.fmt.allocPrint(allocator, "entry-{d:0>8}", .{index}),
    };
}

fn makeDefinition(allocator: std.mem.Allocator, kind: FixtureKind, index: usize, seed: u64) ![]u8 {
    const common = "A deterministic lexical definition with usage, evidence, and a stable " ++
        "repeated phrase; it is intentionally ordinary prose rather than a synthetic byte stream. ";
    switch (kind) {
        .flat, .rich, .pathological_prefix => return std.fmt.allocPrint(allocator, "{s}record {d} seed {x}.", .{ common, index, seed }),
        .repeated => {
            const templates = [_][]const u8{
                "financial institution and money-management context.",
                "river edge, bank, and geographic sense context.",
                "to rely upon, trust, or depend on a person.",
                "a long lexical example with multilingual 東京 and banque.",
            };
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ common, templates[index % templates.len] });
        },
        .prose_heavy => {
            const repeats: usize = 32;
            const out = try allocator.alloc(u8, common.len * repeats + 96);
            var at: usize = 0;
            for (0..repeats) |_| {
                @memcpy(out[at .. at + common.len], common);
                at += common.len;
            }
            const suffix = try std.fmt.bufPrint(out[at..], "record {d} seed {x}; end.", .{ index, seed });
            return out[0 .. at + suffix.len];
        },
    }
}

fn kindIsPathological(kind: FixtureKind) bool {
    return kind == .pathological_prefix;
}

fn classifyPrefix(kind: FixtureKind, count: usize, records: usize) PrefixClass {
    if (count == 0) return .zero;
    if (count == 1) return .one;
    if (kindIsPathological(kind) and count >= @max(@as(usize, 2), records * 3 / 4)) return .pathological;
    return .many;
}

fn parseFixture(value: []const u8) !?FixtureKind {
    if (std.mem.eql(u8, value, "all")) return null;
    inline for (@typeInfo(FixtureKind).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return error.InvalidArgument;
}

fn parsePresetList(config: *Config, value: []const u8) !void {
    config.preset_count = 0;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const preset: Preset = if (std.mem.eql(u8, part, "latency"))
            .latency
        else if (std.mem.eql(u8, part, "balanced"))
            .balanced
        else if (std.mem.eql(u8, part, "compact"))
            .compact
        else
            return error.InvalidArgument;
        if (config.preset_count == config.presets.len) return error.InvalidArgument;
        config.presets[config.preset_count] = preset;
        config.preset_count += 1;
    }
    if (config.preset_count == 0) return error.InvalidArgument;
}

fn parseConfig(args: std.process.Args) !Config {
    var config = Config{};
    var it = std.process.Args.Iterator.init(args);
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--records=")) {
            config.records = try std.fmt.parseUnsigned(usize, arg["--records=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--repetitions=")) {
            config.repetitions = try std.fmt.parseUnsigned(usize, arg["--repetitions=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--warmup=")) {
            config.warmup = try std.fmt.parseUnsigned(usize, arg["--warmup=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            config.seed = try std.fmt.parseUnsigned(u64, arg["--seed=".len..], 0);
        } else if (std.mem.startsWith(u8, arg, "--fixture=")) {
            config.fixture = try parseFixture(arg["--fixture=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--presets=")) {
            try parsePresetList(&config, arg["--presets=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--emit-corpus=")) {
            config.emit_corpus = arg["--emit-corpus=".len..];
        } else if (std.mem.startsWith(u8, arg, "--artifact-dir=")) {
            config.artifact_dir = arg["--artifact-dir=".len..];
        } else return error.InvalidArgument;
    }
    if (config.records == 0 or config.repetitions == 0 or config.warmup > config.repetitions) return error.InvalidArgument;
    return config;
}

fn presetValue(preset: Preset) p.Preset {
    return switch (preset) {
        .latency => .latency,
        .balanced => .balanced,
        .compact => .compact,
    };
}

fn codecValue(codec: Codec) p.CodecMode {
    return switch (codec) {
        .raw => .raw,
        .bzip3 => .bzip3,
    };
}

fn buildV1(allocator: std.mem.Allocator, fixture: *const Fixture, codec: Codec, io: std.Io) !V1Artifact {
    const started = nowNs(io);
    var writer = v1.Writer.initWithOptions(allocator, .{
        .payload_codec = if (codec == .raw) .raw else .bzip3,
        .posting_encoding = .adaptive,
    });
    defer writer.deinit();
    for (fixture.records, 0..) |item, i| try writer.add(.{ .id = i, .key = item.key, .definition = item.definition });
    const bytes = try writer.build();
    errdefer allocator.free(bytes);
    const reader = try v1.Reader.open(bytes);
    return .{ .bytes = bytes, .reader = reader, .codec = codec, .build_ns = nowNs(io) - started, .allocator = allocator };
}

fn addV2Rows(builder: *c.Builder, fixture: *const Fixture, senses: []s.AnyRef) !void {
    for (fixture.records, 0..) |item, i| {
        const entry = try builder.root(.entry, .{});
        try builder.set(entry, s.columns.headword, item.key);
        const form = try builder.child(entry, .form, .{});
        try builder.set(form, s.columns.written, item.key);
        const sense = try builder.child(entry, .sense, .{});
        senses[i] = sense.any();
        const definition = try builder.child(sense, .definition, .{});
        try builder.set(definition, s.columns.text, item.definition);
        if (fixture.kind == .rich and i != 0) {
            _ = try builder.assertion(s.predicates.translation, sense, .{
                .{ .role = .source, .target = c.Target{ .node = sense.any() } },
                .{ .role = .target, .target = c.Target{ .node = senses[i - 1] } },
            }, .{});
        }
    }
}

fn buildV2(
    allocator: std.mem.Allocator,
    fixture: *const Fixture,
    codec: Codec,
    preset: Preset,
    io: std.Io,
) !V2Artifact {
    const started = nowNs(io);
    var builder = c.Builder.initWithOptions(allocator, .{
        .prose = .{
            .preset = presetValue(preset),
            .codec = codecValue(codec),
        },
    });
    defer builder.deinit();
    const senses = try allocator.alloc(s.AnyRef, fixture.records.len);
    defer allocator.free(senses);
    try addV2Rows(&builder, fixture, senses);
    var compiled = try builder.compile();
    // Compilation already emits the requested prose section. Transfer only
    // its snapshot bytes; the draft-to-physical map is benchmark build
    // scratch and must not survive into the artifact.
    const bytes = compiled.bytes;
    allocator.free(compiled.logical_to_physical);
    compiled.logical_to_physical = &.{};
    compiled.bytes = &.{};
    var owned = snap.Owned{ .allocator = allocator, .bytes = bytes };
    errdefer owned.deinit();
    const view = try snap.Snapshot.open(bytes, .{});
    const store = try view.prose(.{
        .preset = presetValue(preset),
        .codec = codecValue(codec),
    });
    return .{
        .owned = owned,
        .view = view,
        .prose_store = store,
        .preset = preset,
        .codec = codec,
        .build_ns = nowNs(io) - started,
    };
}

fn expectedExact(fixture: *const Fixture, key: []const u8) usize {
    var count: usize = 0;
    for (fixture.records) |item| {
        if (std.mem.eql(u8, item.key, key)) count += 1;
    }
    return count;
}

fn expectedPrefix(fixture: *const Fixture, prefix: []const u8) usize {
    var count: usize = 0;
    for (fixture.records) |item| {
        if (std.mem.startsWith(u8, item.key, prefix)) count += 1;
    }
    return count;
}

fn emitMetric(fixture: []const u8, format: []const u8, variant: []const u8, metric: []const u8, value: anytype) void {
    std.debug.print("result\t{s}\t{s}\t{s}\t{s}\t{any}\n", .{ fixture, format, variant, metric, value });
}

fn emitMetricText(fixture: []const u8, format: []const u8, variant: []const u8, metric: []const u8, value: []const u8) void {
    std.debug.print("result\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{ fixture, format, variant, metric, value });
}

fn emitMeta(fixture: []const u8, name: []const u8, value: anytype) void {
    std.debug.print("meta\t{s}\t{s}\t{any}\n", .{ fixture, name, value });
}

fn percentile(values: []u64, pctl: usize) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[(values.len * pctl) / 100];
}

fn emitRawSamples(fixture: []const u8, format: []const u8, variant: []const u8, name: []const u8, values: []const u64) void {
    for (values, 0..) |value, index| {
        std.debug.print("sample\t{s}\t{s}\t{s}\t{s}\t{}\t{}\n", .{ fixture, format, variant, name, index, value });
    }
}

fn emitSamples(fixture: []const u8, format: []const u8, variant: []const u8, name: []const u8, samples: *Samples) void {
    emitRawSamples(fixture, format, variant, name, samples.values);
    const p50 = percentile(samples.values, 50);
    const p95 = percentile(samples.values, 95);
    const p99 = percentile(samples.values, 99);
    var metric: [64]u8 = undefined;
    emitMetric(fixture, format, variant, std.fmt.bufPrint(&metric, "{s}.p50_ns", .{name}) catch "percentile", p50);
    emitMetric(fixture, format, variant, std.fmt.bufPrint(&metric, "{s}.p95_ns", .{name}) catch "percentile", p95);
    emitMetric(fixture, format, variant, std.fmt.bufPrint(&metric, "{s}.p99_ns", .{name}) catch "percentile", p99);
}

fn emitCategorySamples(
    fixture: []const u8,
    format: []const u8,
    variant: []const u8,
    name: []const u8,
    class_name: []const u8,
    values: []u64,
    count: usize,
) void {
    var metric: [96]u8 = undefined;
    for ([_]usize{ 50, 95, 99 }) |pctl| {
        const label = std.fmt.bufPrint(&metric, "{s}.{s}.p{d}_ns", .{ name, class_name, pctl }) catch "percentile";
        if (count == 0) {
            emitMetricText(fixture, format, variant, label, "-");
        } else {
            const answer: u64 = percentile(values[0..count], pctl);
            emitMetric(fixture, format, variant, label, answer);
        }
    }
}

fn expectedRecordIds(fixture: *const Fixture, key: []const u8, prefix: bool, out: []usize) usize {
    var count: usize = 0;
    for (fixture.records, 0..) |item, index| {
        const matches = if (prefix) std.mem.startsWith(u8, item.key, key) else std.mem.eql(u8, item.key, key);
        if (matches) {
            if (count < out.len) out[count] = index;
            count += 1;
        }
    }
    return count;
}

fn compareRecordIds(actual: []const u64, expected: []const usize) !void {
    if (actual.len != expected.len) return error.WorkloadMismatch;
    for (actual, expected) |id, record| {
        const mapped = std.math.cast(usize, id) orelse return error.WorkloadMismatch;
        if (mapped != record) return error.WorkloadMismatch;
    }
}

fn compareNodeIds(fixture: *const Fixture, actual: []const usize, expected: []const usize) !void {
    if (actual.len != expected.len) return error.WorkloadMismatch;
    for (actual, expected) |record, wanted| {
        if (record >= fixture.records.len or record != wanted) return error.WorkloadMismatch;
    }
}

fn childOfKind(forest: *const snap.ForestView, parent: s.Node, wanted: s.Kind) !s.Node {
    var child = try forest.firstChild(parent);
    while (child) |node| {
        if (try forest.kind(node) == wanted) return node;
        child = try forest.nextSibling(node);
    }
    return error.WorkloadMismatch;
}

fn validateRichGraph(fixture: *const Fixture, artifact: *const V2Artifact) !void {
    if (fixture.kind != .rich) return;
    const forest = try artifact.view.forest();
    const translation = try artifact.view.adjacency(.translation);
    const expected_edges = fixture.records.len -| 1;
    if (translation.edge_count != expected_edges) return error.WorkloadMismatch;
    for (1..fixture.records.len) |i| {
        const source: s.Node = @enumFromInt(@as(u32, @intCast(fixture.root_ids[i] + 2)));
        const target: s.Node = @enumFromInt(@as(u32, @intCast(fixture.root_ids[i - 1] + 2)));
        if (try forest.kind(source) != .sense or try forest.kind(target) != .sense) return error.WorkloadMismatch;
        const assertion = try childOfKind(&forest, @enumFromInt(@as(u32, @intCast(fixture.root_ids[i]))), .assertion);
        if (!(try translation.contains(source, target, assertion))) return error.WorkloadMismatch;
    }
}

fn runV2Query(
    io: std.Io,
    query: *q.Query,
    fixture: *const Fixture,
    key: []const u8,
    mode: q.Mode,
    key_buffer: []u8,
    nodes: []q.Node,
    out: []usize,
) !QueryMeasurement {
    const started = nowNs(io);
    const set = try query.lookup(.headword, key, mode, key_buffer, nodes);
    if (set.items.len > nodes.len) return error.WorkloadMismatch;
    var count: usize = 0;
    for (set.items) |node| {
        const raw = @intFromEnum(node);
        if (raw >= fixture.node_to_record.len) return error.WorkloadMismatch;
        const record = fixture.node_to_record[raw];
        if (record == std.math.maxInt(usize)) return error.WorkloadMismatch;
        // The headword key space also contains required `written` forms in
        // this fixture.  The v1 contract is entry-level, so collapse all
        // nodes belonging to one preorder root while retaining the public
        // Query.lookup execution path above.
        if (count == 0 or out[count - 1] != record) {
            out[count] = record;
            count += 1;
        }
    }
    return .{ .elapsed_ns = nowNs(io) - started, .count = count };
}

fn warmV1(reader: *v1.Reader, fixture: *const Fixture, workload: *const Workload, warmup: usize, ids: []u64, expected: []usize) !void {
    for (0..warmup) |i| {
        const probe = workload.exact[i % workload.exact.len];
        const count = try reader.lookupExact(probe.key, ids);
        const expected_count = expectedRecordIds(fixture, probe.key, false, expected);
        if (count != expected_count) return error.WorkloadMismatch;
        try compareRecordIds(ids[0..count], expected[0..expected_count]);
        const prefix_probe = workload.prefix[i % workload.prefix.len];
        const prefix_count = try reader.lookupPrefix(prefix_probe.key, ids);
        const prefix_expected = expectedRecordIds(fixture, prefix_probe.key, true, expected);
        if (prefix_expected != prefix_probe.expected or prefix_count != prefix_expected) return error.WorkloadMismatch;
        std.mem.sort(u64, ids[0..prefix_count], {}, std.sort.asc(u64));
        try compareRecordIds(ids[0..prefix_count], expected[0..prefix_expected]);
    }
}

fn measureV1(
    allocator: std.mem.Allocator,
    io: std.Io,
    fixture: *const Fixture,
    workload: *const Workload,
    artifact: *V1Artifact,
    repetitions: usize,
    warmup: usize,
    fixture_name: []const u8,
) !void {
    var ids = try allocator.alloc(u64, fixture.records.len + 8);
    defer allocator.free(ids);
    var expected = try allocator.alloc(usize, fixture.records.len + 8);
    defer allocator.free(expected);
    var buffer = try allocator.alloc(u8, @max(@as(usize, 8192), maxDefinition(fixture)));
    defer allocator.free(buffer);
    try warmV1(&artifact.reader, fixture, workload, warmup, ids, expected);
    for (0..warmup) |i| {
        const id = workload.render_ids[i % workload.render_ids.len];
        const length = try artifact.reader.definition(id, buffer);
        if (!std.mem.eql(u8, buffer[0..length], fixture.records[id].definition)) return error.WorkloadMismatch;
    }

    var exact = try Samples.init(allocator, repetitions);
    defer exact.deinit();
    var prefix = try Samples.init(allocator, repetitions);
    defer prefix.deinit();
    var render = try Samples.init(allocator, repetitions);
    defer render.deinit();
    var exact_classes = [2][]u64{
        try allocator.alloc(u64, repetitions),
        try allocator.alloc(u64, repetitions),
    };
    defer allocator.free(exact_classes[0]);
    defer allocator.free(exact_classes[1]);
    var exact_class_counts = [_]usize{ 0, 0 };
    var prefix_classes = [4][]u64{
        try allocator.alloc(u64, repetitions),
        try allocator.alloc(u64, repetitions),
        try allocator.alloc(u64, repetitions),
        try allocator.alloc(u64, repetitions),
    };
    defer allocator.free(prefix_classes[0]);
    defer allocator.free(prefix_classes[1]);
    defer allocator.free(prefix_classes[2]);
    defer allocator.free(prefix_classes[3]);
    var prefix_class_counts = [_]usize{ 0, 0, 0, 0 };
    var checksum: u64 = 0;
    var output_count: u64 = 0;
    var open_samples = try measureV1Open(allocator, io, artifact.bytes, repetitions / 10 + 1);
    defer open_samples.deinit();
    for (0..repetitions) |i| {
        const probe = workload.exact[i % workload.exact.len];
        const started = nowNs(io);
        const count = try artifact.reader.lookupExact(probe.key, ids);
        exact.values[i] = nowNs(io) - started;
        const expected_count = expectedRecordIds(fixture, probe.key, false, expected);
        if (expected_count != probe.expected or count != expected_count) return error.WorkloadMismatch;
        std.mem.sort(u64, ids[0..count], {}, std.sort.asc(u64));
        try compareRecordIds(ids[0..count], expected[0..expected_count]);
        const class = @intFromEnum(probe.exact_class);
        exact_classes[class][exact_class_counts[class]] = exact.values[i];
        exact_class_counts[class] += 1;
        output_count += count;
        for (ids[0..count]) |id| checksum = hashU64(checksum, id);
    }
    for (0..repetitions) |i| {
        const probe = workload.prefix[i % workload.prefix.len];
        const started = nowNs(io);
        const count = try artifact.reader.lookupPrefix(probe.key, ids);
        prefix.values[i] = nowNs(io) - started;
        const expected_count = expectedRecordIds(fixture, probe.key, true, expected);
        if (expected_count != probe.expected or count != expected_count) return error.WorkloadMismatch;
        std.mem.sort(u64, ids[0..count], {}, std.sort.asc(u64));
        try compareRecordIds(ids[0..count], expected[0..expected_count]);
        const class = @intFromEnum(probe.prefix_class);
        prefix_classes[class][prefix_class_counts[class]] = prefix.values[i];
        prefix_class_counts[class] += 1;
        output_count += count;
        for (ids[0..count]) |id| checksum = hashU64(checksum, id);
    }
    for (0..repetitions) |i| {
        const id = workload.render_ids[i % workload.render_ids.len];
        const started = nowNs(io);
        const length = try artifact.reader.definition(id, buffer);
        render.values[i] = nowNs(io) - started;
        if (!std.mem.eql(u8, buffer[0..length], fixture.records[id].definition)) return error.WorkloadMismatch;
        checksum = hashBytes(checksum, buffer[0..length]);
    }
    const variant = if (artifact.codec == .raw) "raw" else "bzip3";
    emitMetric(fixture_name, "v1", variant, "artifact_bytes", artifact.bytes.len);
    emitMetric(fixture_name, "v1", variant, "build_ns", artifact.build_ns);
    emitSamples(fixture_name, "v1", variant, "open", &open_samples);
    emitMetric(fixture_name, "v1", variant, "open_ns", open_samples.values[(open_samples.values.len * 50) / 100]);
    emitMetric(fixture_name, "v1", variant, "semantic_digest", fixture.digest);
    emitMetric(fixture_name, "v1", variant, "query_checksum", checksum);
    emitMetric(fixture_name, "v1", variant, "outputs", output_count);
    emitSamples(fixture_name, "v1", variant, "exact", &exact);
    emitSamples(fixture_name, "v1", variant, "prefix", &prefix);
    emitSamples(fixture_name, "v1", variant, "render", &render);
    emitCategorySamples(fixture_name, "v1", variant, "exact", "hit", exact_classes[0], exact_class_counts[0]);
    emitCategorySamples(fixture_name, "v1", variant, "exact", "miss", exact_classes[1], exact_class_counts[1]);
    emitCategorySamples(fixture_name, "v1", variant, "prefix", "zero", prefix_classes[0], prefix_class_counts[0]);
    emitCategorySamples(fixture_name, "v1", variant, "prefix", "one", prefix_classes[1], prefix_class_counts[1]);
    emitCategorySamples(fixture_name, "v1", variant, "prefix", "many", prefix_classes[2], prefix_class_counts[2]);
    emitCategorySamples(fixture_name, "v1", variant, "prefix", "pathological", prefix_classes[3], prefix_class_counts[3]);
}

fn measureV1Open(allocator: std.mem.Allocator, io: std.Io, bytes: []const u8, repeats: usize) !Samples {
    var samples = try Samples.init(allocator, repeats);
    errdefer samples.deinit();
    for (0..repeats) |i| {
        const started = nowNs(io);
        _ = try v1.Reader.open(bytes);
        samples.values[i] = nowNs(io) - started;
    }
    return samples;
}

fn maxDefinition(fixture: *const Fixture) usize {
    var max: usize = 0;
    for (fixture.records) |item| max = @max(max, item.definition.len);
    return max;
}

fn validateV1Artifact(allocator: std.mem.Allocator, io: std.Io, fixture: *const Fixture, artifact: *V1Artifact) !void {
    var actual = try allocator.alloc(u64, fixture.records.len + 8);
    defer allocator.free(actual);
    var expected = try allocator.alloc(usize, fixture.records.len + 8);
    defer allocator.free(expected);
    var buffer = try allocator.alloc(u8, @max(@as(usize, 8192), maxDefinition(fixture)));
    defer allocator.free(buffer);
    for (fixture.records, 0..) |item, i| {
        const count = try artifact.reader.lookupExact(item.key, actual);
        const expected_count = expectedRecordIds(fixture, item.key, false, expected);
        if (count != expected_count) return error.WorkloadMismatch;
        std.mem.sort(u64, actual[0..count], {}, std.sort.asc(u64));
        try compareRecordIds(actual[0..count], expected[0..expected_count]);
        const length = try artifact.reader.definition(i, buffer);
        if (!std.mem.eql(u8, buffer[0..length], item.definition)) return error.WorkloadMismatch;
    }
    const special_prefixes = [_][]const u8{
        "",
        "entry-",
        "repeat-",
        "pathological-prefix-",
        "entry-00000000-",
        "absent-ß-東京",
    };
    for (special_prefixes) |prefix| {
        const count = try artifact.reader.lookupPrefix(prefix, actual);
        const expected_count = expectedRecordIds(fixture, prefix, true, expected);
        if (count != expected_count) return error.WorkloadMismatch;
        std.mem.sort(u64, actual[0..count], {}, std.sort.asc(u64));
        try compareRecordIds(actual[0..count], expected[0..expected_count]);
    }
    _ = io;
}

fn validateV2Artifact(allocator: std.mem.Allocator, io: std.Io, fixture: *const Fixture, artifact: *const V2Artifact) !void {
    try artifact.view.validate();
    try validateRichGraph(fixture, artifact);
    var actual = try allocator.alloc(usize, fixture.records.len + 8);
    defer allocator.free(actual);
    var expected = try allocator.alloc(usize, fixture.records.len + 8);
    defer allocator.free(expected);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var query = q.Query.init(&artifact.view, &arena, .{
        .max_visited = @max(@as(usize, 1_000_000), fixture.records.len * 16),
        .max_blocks = 64,
        .allow_scan = false,
    });
    defer query.deinit();
    var key_buffer: [4096]u8 = undefined;
    const nodes = try allocator.alloc(q.Node, fixture.records.len * 4 + 8);
    defer allocator.free(nodes);
    for (fixture.records) |item| {
        const measurement = try runV2Query(io, &query, fixture, item.key, .exact, &key_buffer, nodes, actual);
        const expected_count = expectedRecordIds(fixture, item.key, false, expected);
        if (measurement.count != expected_count) return error.WorkloadMismatch;
        try compareNodeIds(fixture, actual[0..expected_count], expected[0..expected_count]);
    }
    const special_prefixes = [_][]const u8{
        "",
        "entry-",
        "repeat-",
        "pathological-prefix-",
        "entry-00000000-",
        "absent-ß-東京",
    };
    for (special_prefixes) |prefix| {
        const measurement = try runV2Query(io, &query, fixture, prefix, .prefix, &key_buffer, nodes, actual);
        const expected_count = expectedRecordIds(fixture, prefix, true, expected);
        if (measurement.count != expected_count) return error.WorkloadMismatch;
        try compareNodeIds(fixture, actual[0..expected_count], expected[0..expected_count]);
    }
    var buffer = try allocator.alloc(u8, @max(@as(usize, 8192), maxDefinition(fixture)));
    defer allocator.free(buffer);
    for (fixture.records, 0..) |item, i| {
        const block = artifact.prose_store.blockForRoot(fixture.root_ids[i]) orelse return error.WorkloadMismatch;
        var pin = try artifact.prose_store.pin(allocator, block);
        defer pin.deinit();
        const text = (try pin.itemForNode(fixture.definition_ids[i])) orelse return error.WorkloadMismatch;
        if (text.text.len > buffer.len or !std.mem.eql(u8, text.text, item.definition)) return error.WorkloadMismatch;
        @memcpy(buffer[0..text.text.len], text.text);
    }
}

fn warmV2(io: std.Io, allocator: std.mem.Allocator, workload: *const Workload, warmup: usize, fixture: *const Fixture, query: *q.Query, key_buffer: []u8, nodes: []q.Node) !void {
    const actual = try allocator.alloc(usize, fixture.records.len + 8);
    defer allocator.free(actual);
    const expected = try allocator.alloc(usize, fixture.records.len + 8);
    defer allocator.free(expected);
    for (0..warmup) |i| {
        const probe = workload.exact[i % workload.exact.len];
        const measurement = try runV2Query(io, query, fixture, probe.key, .exact, key_buffer, nodes, actual);
        const expected_count = expectedRecordIds(fixture, probe.key, false, expected);
        if (expected_count != probe.expected) return error.WorkloadMismatch;
        if (measurement.count != expected_count) return error.WorkloadMismatch;
        try compareNodeIds(fixture, actual[0..expected_count], expected[0..expected_count]);
        const prefix_probe = workload.prefix[i % workload.prefix.len];
        const prefix_measurement = try runV2Query(io, query, fixture, prefix_probe.key, .prefix, key_buffer, nodes, actual);
        const prefix_expected = expectedRecordIds(fixture, prefix_probe.key, true, expected);
        if (prefix_expected != prefix_probe.expected) return error.WorkloadMismatch;
        if (prefix_measurement.count != prefix_expected) return error.WorkloadMismatch;
        try compareNodeIds(fixture, actual[0..prefix_expected], expected[0..prefix_expected]);
    }
}

fn measureV2(
    allocator: std.mem.Allocator,
    io: std.Io,
    fixture: *const Fixture,
    workload: *const Workload,
    artifact: *V2Artifact,
    repetitions: usize,
    warmup: usize,
    fixture_name: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var query = q.Query.init(&artifact.view, &arena, .{
        .max_visited = @max(@as(usize, 1_000_000), fixture.records.len * 16),
        .max_blocks = 64,
        .allow_scan = false,
    });
    defer query.deinit();
    var key_buffer: [4096]u8 = undefined;
    const nodes = try allocator.alloc(q.Node, fixture.records.len * 4 + 8);
    defer allocator.free(nodes);
    try warmV2(io, allocator, workload, warmup, fixture, &query, &key_buffer, nodes);
    var warm_render = try allocator.alloc(u8, @max(@as(usize, 8192), maxDefinition(fixture)));
    defer allocator.free(warm_render);
    for (0..warmup) |i| {
        const id = workload.render_ids[i % workload.render_ids.len];
        const block = artifact.prose_store.blockForRoot(fixture.root_ids[id]) orelse return error.WorkloadMismatch;
        {
            var pin = try artifact.prose_store.pin(allocator, block);
            defer pin.deinit();
            const item = (try pin.itemForNode(fixture.definition_ids[id])) orelse return error.WorkloadMismatch;
            if (!std.mem.eql(u8, item.text, fixture.records[id].definition)) return error.WorkloadMismatch;
            if (item.text.len > warm_render.len) return error.WorkloadMismatch;
            @memcpy(warm_render[0..item.text.len], item.text);
        }
    }
    const actual = try allocator.alloc(usize, fixture.records.len + 8);
    defer allocator.free(actual);
    const expected = try allocator.alloc(usize, fixture.records.len + 8);
    defer allocator.free(expected);
    var exact = try Samples.init(allocator, repetitions);
    defer exact.deinit();
    var prefix = try Samples.init(allocator, repetitions);
    defer prefix.deinit();
    var render = try Samples.init(allocator, repetitions);
    defer render.deinit();
    var exact_classes = [2][]u64{
        try allocator.alloc(u64, repetitions),
        try allocator.alloc(u64, repetitions),
    };
    defer allocator.free(exact_classes[0]);
    defer allocator.free(exact_classes[1]);
    var exact_class_counts = [_]usize{ 0, 0 };
    var prefix_classes = [4][]u64{
        try allocator.alloc(u64, repetitions),
        try allocator.alloc(u64, repetitions),
        try allocator.alloc(u64, repetitions),
        try allocator.alloc(u64, repetitions),
    };
    defer allocator.free(prefix_classes[0]);
    defer allocator.free(prefix_classes[1]);
    defer allocator.free(prefix_classes[2]);
    defer allocator.free(prefix_classes[3]);
    var prefix_class_counts = [_]usize{ 0, 0, 0, 0 };
    var checksum: u64 = 0;
    var outputs: u64 = 0;
    var open_samples = try measureV2Open(allocator, io, artifact.owned.bytes, repetitions / 10 + 1);
    defer open_samples.deinit();

    for (0..repetitions) |i| {
        const probe = workload.exact[i % workload.exact.len];
        const exact_measurement = try runV2Query(io, &query, fixture, probe.key, .exact, &key_buffer, nodes, actual);
        exact.values[i] = exact_measurement.elapsed_ns;
        const expected_count = expectedRecordIds(fixture, probe.key, false, expected);
        if (expected_count != probe.expected) return error.WorkloadMismatch;
        if (exact_measurement.count != expected_count) return error.WorkloadMismatch;
        try compareNodeIds(fixture, actual[0..expected_count], expected[0..expected_count]);
        const class = @intFromEnum(probe.exact_class);
        exact_classes[class][exact_class_counts[class]] = exact.values[i];
        exact_class_counts[class] += 1;
        outputs += expected_count;
        for (actual[0..expected_count]) |id| checksum = hashU64(checksum, id);
    }
    for (0..repetitions) |i| {
        const probe = workload.prefix[i % workload.prefix.len];
        const prefix_measurement = try runV2Query(io, &query, fixture, probe.key, .prefix, &key_buffer, nodes, actual);
        prefix.values[i] = prefix_measurement.elapsed_ns;
        const expected_count = expectedRecordIds(fixture, probe.key, true, expected);
        if (expected_count != probe.expected) return error.WorkloadMismatch;
        if (prefix_measurement.count != expected_count) return error.WorkloadMismatch;
        try compareNodeIds(fixture, actual[0..expected_count], expected[0..expected_count]);
        const class = @intFromEnum(probe.prefix_class);
        prefix_classes[class][prefix_class_counts[class]] = prefix.values[i];
        prefix_class_counts[class] += 1;
        outputs += expected_count;
        for (actual[0..expected_count]) |id| checksum = hashU64(checksum, id);
    }
    for (0..repetitions) |i| {
        const id = workload.render_ids[i % workload.render_ids.len];
        const root = fixture.root_ids[id];
        const node = fixture.definition_ids[id];
        const block = artifact.prose_store.blockForRoot(root) orelse return error.WorkloadMismatch;
        const started = nowNs(io);
        var pin = try artifact.prose_store.pin(allocator, block);
        const item = (try pin.itemForNode(node)) orelse return error.WorkloadMismatch;
        render.values[i] = nowNs(io) - started;
        if (!std.mem.eql(u8, item.text, fixture.records[id].definition)) return error.WorkloadMismatch;
        checksum = hashBytes(checksum, item.text);
        pin.deinit();
    }
    const variant = if (artifact.codec == .raw) "raw" else "bzip3";
    const preset_name = @tagName(artifact.preset);
    var variant_buf: [32]u8 = undefined;
    const variant_name = std.fmt.bufPrint(&variant_buf, "{s}.{s}", .{ variant, preset_name }) catch "v2";
    emitMetric(fixture_name, "v2", variant_name, "artifact_bytes", artifact.owned.bytes.len);
    emitMetric(fixture_name, "v2", variant_name, "build_ns", artifact.build_ns);
    emitSamples(fixture_name, "v2", variant_name, "open", &open_samples);
    emitMetric(fixture_name, "v2", variant_name, "open_ns", open_samples.values[(open_samples.values.len * 50) / 100]);
    emitMetric(fixture_name, "v2", variant_name, "semantic_digest", fixture.digest);
    emitMetric(fixture_name, "v2", variant_name, "query_checksum", checksum);
    emitMetric(fixture_name, "v2", variant_name, "outputs", outputs);
    emitMetric(fixture_name, "v2", variant_name, "logical_prose_bytes", fixture.logical_prose_bytes);
    emitSamples(fixture_name, "v2", variant_name, "exact", &exact);
    emitSamples(fixture_name, "v2", variant_name, "prefix", &prefix);
    emitSamples(fixture_name, "v2", variant_name, "render", &render);
    emitCategorySamples(fixture_name, "v2", variant_name, "exact", "hit", exact_classes[0], exact_class_counts[0]);
    emitCategorySamples(fixture_name, "v2", variant_name, "exact", "miss", exact_classes[1], exact_class_counts[1]);
    emitCategorySamples(fixture_name, "v2", variant_name, "prefix", "zero", prefix_classes[0], prefix_class_counts[0]);
    emitCategorySamples(fixture_name, "v2", variant_name, "prefix", "one", prefix_classes[1], prefix_class_counts[1]);
    emitCategorySamples(fixture_name, "v2", variant_name, "prefix", "many", prefix_classes[2], prefix_class_counts[2]);
    emitCategorySamples(fixture_name, "v2", variant_name, "prefix", "pathological", prefix_classes[3], prefix_class_counts[3]);
}

fn measureV2Open(allocator: std.mem.Allocator, io: std.Io, bytes: []const u8, repeats: usize) !Samples {
    var samples = try Samples.init(allocator, repeats);
    errdefer samples.deinit();
    for (0..repeats) |i| {
        const started = nowNs(io);
        _ = try snap.Snapshot.open(bytes, .{});
        samples.values[i] = nowNs(io) - started;
    }
    return samples;
}

fn emitCorpus(io: std.Io, path: []const u8, fixture_name: []const u8, fixture: *const Fixture) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.print("# fixture={s}\n", .{fixture_name});
    for (fixture.records, 0..) |item, i| try writer.interface.print("{}\t{s}\t{s}\n", .{ i, item.key, item.definition });
    try writer.interface.flush();
}

fn emitArtifact(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, name: []const u8, bytes: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, name });
    defer allocator.free(path);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn emitNamedArtifact(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: ?[]const u8,
    fixture_name: []const u8,
    format: []const u8,
    variant: []const u8,
    bytes: []const u8,
) !void {
    if (directory) |path| {
        const name = try std.fmt.allocPrint(allocator, "{s}-{s}.bin", .{ format, variant });
        defer allocator.free(name);
        const scoped = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ fixture_name, name });
        defer allocator.free(scoped);
        try emitArtifact(allocator, io, path, scoped, bytes);
    }
}

fn runFixture(init: std.process.Init, allocator: std.mem.Allocator, config: Config, kind: FixtureKind) !void {
    const fixture_name = @tagName(kind);
    var fixture = try Fixture.init(allocator, kind, config.records, config.seed);
    defer fixture.deinit();
    var workload = try Workload.init(allocator, &fixture, config.repetitions);
    defer workload.deinit();
    emitMeta(fixture_name, "records", config.records);
    emitMeta(fixture_name, "repetitions", config.repetitions);
    emitMeta(fixture_name, "warmup", config.warmup);
    emitMeta(fixture_name, "seed", config.seed);
    emitMeta(fixture_name, "semantic_digest", fixture.digest);
    emitMeta(fixture_name, "logical_prose_bytes", fixture.logical_prose_bytes);
    if (config.emit_corpus) |path| try emitCorpus(init.io, path, fixture_name, &fixture);

    emitMeta(fixture_name, "exact_hit_probes", countClass(workload.exact, .hit));
    emitMeta(fixture_name, "exact_miss_probes", countClass(workload.exact, .miss));
    emitMeta(fixture_name, "prefix_zero_probes", countPrefixClass(workload.prefix, .zero));
    emitMeta(fixture_name, "prefix_one_probes", countPrefixClass(workload.prefix, .one));
    emitMeta(fixture_name, "prefix_many_probes", countPrefixClass(workload.prefix, .many));
    emitMeta(fixture_name, "prefix_pathological_probes", countPrefixClass(workload.prefix, .pathological));

    for ([_]Codec{ .raw, .bzip3 }) |codec| {
        var artifact = try buildV1(allocator, &fixture, codec, init.io);
        defer artifact.deinit();
        try validateV1Artifact(allocator, init.io, &fixture, &artifact);
        try measureV1(allocator, init.io, &fixture, &workload, &artifact, config.repetitions, config.warmup, fixture_name);
        try emitNamedArtifact(allocator, init.io, config.artifact_dir, fixture_name, "v1", @tagName(codec), artifact.bytes);
    }
    for (config.presets[0..config.preset_count]) |preset| for ([_]Codec{ .raw, .bzip3 }) |codec| {
        var artifact = try buildV2(allocator, &fixture, codec, preset, init.io);
        defer artifact.deinit();
        try validateV2Artifact(allocator, init.io, &fixture, &artifact);
        try measureV2(allocator, init.io, &fixture, &workload, &artifact, config.repetitions, config.warmup, fixture_name);
        var variant: [32]u8 = undefined;
        const variant_name = try std.fmt.bufPrint(&variant, "{s}-{s}", .{ @tagName(preset), @tagName(codec) });
        try emitNamedArtifact(allocator, init.io, config.artifact_dir, fixture_name, "v2", variant_name, artifact.owned.bytes);
    };
}

fn countClass(probes: []const Workload.Probe, wanted: ExactClass) usize {
    var count: usize = 0;
    for (probes) |probe| {
        if (probe.exact_class == wanted) count += 1;
    }
    return count;
}

fn countPrefixClass(probes: []const Workload.Probe, wanted: PrefixClass) usize {
    var count: usize = 0;
    for (probes) |probe| {
        if (probe.prefix_class == wanted) count += 1;
    }
    return count;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const config = try parseConfig(init.minimal.args);
    std.debug.print("meta\tglobal\tzig_version\t{s}\n", .{builtin.zig_version_string});
    std.debug.print("meta\tglobal\ttarget\t{s}-{s}\n", .{ @tagName(builtin.target.os.tag), @tagName(builtin.target.cpu.arch) });
    std.debug.print("meta\tglobal\tseed\t{}\n", .{config.seed});
    if (config.fixture) |kind| {
        try runFixture(init, allocator, config, kind);
    } else {
        inline for (@typeInfo(FixtureKind).@"enum".fields) |field| try runFixture(init, allocator, config, @enumFromInt(field.value));
    }
}

test "fixture and workload are deterministic" {
    var first = try Fixture.init(std.testing.allocator, .repeated, 64, default_seed);
    defer first.deinit();
    var second = try Fixture.init(std.testing.allocator, .repeated, 64, default_seed);
    defer second.deinit();
    try std.testing.expectEqual(first.digest, second.digest);
    try std.testing.expectEqualSlices(u8, first.records[17].definition, second.records[17].definition);
    var workload = try Workload.init(std.testing.allocator, &first, 32);
    defer workload.deinit();
    try std.testing.expectEqualSlices(u8, workload.exact[0].key, first.records[17].key);
}

test "semantic contract fixtures cover duplicate unicode and pathological prefixes" {
    var repeated = try Fixture.init(std.testing.allocator, .repeated, 32, default_seed);
    defer repeated.deinit();
    try std.testing.expect(expectedExact(&repeated, repeated.records[0].key) >= 2);
    try std.testing.expect(expectedExact(&repeated, "repeat-000000-é-東京") >= 2);
    try std.testing.expect(expectedPrefix(&repeated, "repeat-") >= 2);

    var pathological = try Fixture.init(std.testing.allocator, .pathological_prefix, 32, default_seed);
    defer pathological.deinit();
    try std.testing.expectEqual(@as(usize, 32), expectedPrefix(&pathological, "pathological-prefix-"));
    var workload = try Workload.init(std.testing.allocator, &pathological, 32);
    defer workload.deinit();
    try std.testing.expect(countPrefixClass(workload.prefix, .pathological) > 0);
    try std.testing.expect(countClass(workload.exact, .hit) > 0);
    try std.testing.expect(countClass(workload.exact, .miss) > 0);
}
