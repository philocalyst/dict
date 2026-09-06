//! Paired semantic-format benchmark. The model is built once, then the
//! reference and compact encodings are measured over the same model and
//! workload. If a compact API is not present yet, the executable reports an
//! unavailable profile instead of treating a reference encoding as compact.

const std = @import("std");
const lexicon = @import("lexicon");
const format = lexicon.semantic_format;
const semantic = lexicon.semantic;

const default_records: usize = 16;
const default_repetitions: usize = 8;

const Config = struct {
    records: usize = default_records,
    repetitions: usize = default_repetitions,
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

const ProfileMetrics = struct {
    available: bool = false,
    bytes: usize = 0,
    encode_ns: u64 = 0,
    decode_ns: u64 = 0,
    checksum: u64 = 0,
    query_checksum: u64 = 0,
};

fn parseConfig(process_args: std.process.Args) !Config {
    var config = Config{};
    var args = std.process.Args.Iterator.init(process_args);
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--records=")) {
            config.records = try std.fmt.parseUnsigned(usize, arg[10..], 10);
        } else if (std.mem.startsWith(u8, arg, "--repetitions=")) {
            config.repetitions = try std.fmt.parseUnsigned(usize, arg[14..], 10);
        } else return error.InvalidArgument;
    }
    if (config.records == 0 or config.repetitions == 0) return error.InvalidArgument;
    return config;
}

fn addText(builder: *semantic.Builder, bytes: []const u8, language: []const u8, unique: bool, index: usize) !semantic.ValueId {
    var unique_bytes: [96]u8 = undefined;
    const text = if (unique)
        try std.fmt.bufPrint(&unique_bytes, "{s}-{d}", .{ bytes, index })
    else
        bytes;
    return builder.addValue(.{ .text = .{ .bytes = text, .language = language } });
}

fn buildModel(allocator: std.mem.Allocator, records: usize, unique: bool) !semantic.Model {
    var builder = semantic.Builder.init(allocator);
    errdefer builder.deinit();
    const tei = try builder.addNamespace("http://www.tei-c.org/ns/1.0", "tei");
    const ontolex = try builder.addNamespace("http://www.w3.org/ns/lemon/ontolex#", "ontolex");
    const source_a = try builder.addSource(.{ .external_id = "tei-main", .base_uri = "https://example.test/tei/" });
    const source_b = try builder.addSource(.{ .external_id = "tei-main", .base_uri = "https://example.test/tei/" });

    const surface_en = try addText(&builder, "bank", "en", unique, 0);
    const surface_fr = try addText(&builder, "banque", "fr", unique, 1);
    const surface_ja = try addText(&builder, "銀行", "ja", unique, 2);
    const relation_label = try builder.addValue(.{ .text = .{ .bytes = "translation", .language = "en" } });
    const comment_value = try builder.addValue(.{ .text = .{ .bytes = "editorial note", .language = "en" } });
    const missing = try builder.addValue(.absent);

    const predicate = try builder.addEntity(.{ .kind = .other, .external_id = "translation", .label = relation_label, .source = source_a });
    const entry_predicate = try builder.addEntity(.{ .kind = .other, .external_id = "entry-relation", .source = source_b });
    _ = entry_predicate;

    var previous_assertion: ?semantic.AssertionId = null;
    for (0..records) |index| {
        const surface = switch (index % 3) {
            0 => surface_en,
            1 => surface_fr,
            else => surface_ja,
        };
        const gloss = try addText(&builder, switch (index % 3) {
            0 => "financial institution",
            1 => "institution financière",
            else => "金融機関",
        }, switch (index % 3) {
            0 => "en",
            1 => "fr",
            else => "ja",
        }, unique, index + 10);
        const entry_id = try builder.addEntity(.{ .kind = .entry, .external_id = if (index % 2 == 0) "entry-shared" else "entry-alt", .label = surface, .source = if (index % 2 == 0) source_a else source_b });
        const sense_id = try builder.addEntity(.{ .kind = .sense, .external_id = if (index % 2 == 0) "sense-finance" else "sense-river", .label = gloss, .source = if (index % 2 == 0) source_a else source_b });
        const form_id = try builder.addEntity(.{ .kind = .form, .label = surface });

        const document_source = if (index % 2 == 0) source_a else source_b;
        const root = try builder.addDocumentNode(.{ .name = .{ .namespace = tei, .local = "entry", .prefix = "tei" }, .source = document_source, .attributes = &.{.{ .name = .{ .namespace = tei, .local = "xml:lang", .prefix = "xml" }, .value = surface }} });
        const form_node = try builder.addDocumentNode(.{ .name = .{ .namespace = ontolex, .local = "Form", .prefix = "ontolex" }, .parent = root, .source = document_source });
        try builder.appendChild(root, .{ .text = surface });
        try builder.appendChild(root, .{ .comment = comment_value });
        try builder.appendChild(root, .{ .processing_instruction = .{ .target = "xml-model", .data = missing } });
        try builder.appendChild(form_node, .{ .text = surface });
        try builder.addDocumentRoot(root);

        const assertion = try builder.addAssertion(.{
            .predicate = predicate,
            .participants = &[_]semantic.Participant{
                .{ .role = "source", .target = .{ .entity = sense_id } },
                .{ .role = "target", .target = .{ .value = surface } },
                .{ .role = "form", .target = .{ .entity = form_id } },
            },
            .attributes = &[_]semantic.Attribute{.{ .name = .{ .namespace = tei, .local = "type", .prefix = "tei" }, .value = gloss }},
            .evidence = &[_]semantic.Evidence{.{ .source = entry_id, .document = root, .quote = gloss, .provenance = surface }},
            .state = if (index % 5 == 0) .inferred else .asserted,
            .certainty = if (index % 4 == 0) .probable else .certain,
            .temporal = .{ .start = .{ .year = 1900 + @as(i32, @intCast(index)), .month = 1 }, .precision = .year },
            .context = if (previous_assertion) |quoted| .{ .anonymous = .{ .source = .{ .document = root }, .id = quoted.index } } else .default,
            .source = if (index % 2 == 0) source_a else source_b,
        });
        previous_assertion = assertion;
        try builder.addEntityAnchor(entry_id, .{ .source = document_source, .node = root, .span = .{ .unit = .utf8_codepoint, .start = 0, .end = 4 } });
        try builder.addAssertionAnchor(assertion, .{ .source = document_source, .node = root });
    }
    return builder.build();
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

fn modelDigest(model: *const semantic.Model) u64 {
    var digest: u64 = 0xcbf29ce484222325;
    digest = hashU64(digest, @intCast(model.namespaces.len));
    digest = hashU64(digest, @intCast(model.values.len));
    digest = hashU64(digest, @intCast(model.entities.len));
    digest = hashU64(digest, @intCast(model.assertions.len));
    digest = hashU64(digest, @intCast(model.documents.len));
    for (model.values) |item| switch (item) {
        .text => |text| {
            digest = hashBytes(digest, text.bytes);
            if (text.language) |language| digest = hashBytes(digest, language);
        },
        .bytes => |bytes| digest = hashBytes(digest, bytes),
        .boolean => |flag| digest = (digest ^ @intFromBool(flag)) *% 0x100000001b3,
        .signed_integer => |value| digest = (digest ^ @as(u64, @bitCast(value))) *% 0x100000001b3,
        .unsigned_integer => |value| digest = (digest ^ value) *% 0x100000001b3,
        .decimal => |value| digest = (digest ^ @as(u64, @bitCast(value.coefficient))) *% 0x100000001b3,
        .uri => |value| digest = hashBytes(digest, value),
        .qualified_name => |value| digest = hashBytes(digest, value.local),
        .entity => |value| digest = (digest ^ value.index) *% 0x100000001b3,
        .sequence => |values| {
            for (values) |value| digest = (digest ^ value.index) *% 0x100000001b3;
        },
        .unknown => |value| {
            if (value.reason) |reason| digest = hashBytes(digest, reason);
        },
        .absent => digest = (digest ^ 0xa5) *% 0x100000001b3,
        .uncertain => |value| digest = (digest ^ value.value.index) *% 0x100000001b3,
    };
    for (model.entities) |entity| {
        if (entity.external_id) |id| digest = hashBytes(digest, id);
    }
    for (model.assertions) |assertion| {
        digest = (digest ^ assertion.predicate.index) *% 0x100000001b3;
        for (assertion.participants) |participant| {
            digest = hashBytes(digest, participant.role);
            switch (participant.target) {
                .entity => |id| digest = (digest ^ id.index) *% 0x100000001b3,
                .value => |id| digest = (digest ^ id.index) *% 0x100000001b3,
                .statement => |id| digest = (digest ^ id.index) *% 0x100000001b3,
                .unresolved => |target| digest = hashBytes(digest, target.bytes),
            }
        }
    }
    return digest;
}

fn encodeProfile(allocator: std.mem.Allocator, model: *const semantic.Model, compact: bool) anyerror![]u8 {
    if (compact) {
        if (comptime @hasDecl(format, "encode")) return @field(format, "encode")(allocator, model);
        if (comptime @hasDecl(format, "encodeCompact")) return @field(format, "encodeCompact")(allocator, model);
    } else {
        if (comptime @hasDecl(format, "encodeReference")) return @field(format, "encodeReference")(allocator, model);
    }
    return error.SemanticFormatUnavailable;
}

fn decodeProfile(allocator: std.mem.Allocator, bytes: []const u8, compact: bool) anyerror!semantic.Model {
    if (compact) {
        if (comptime @hasDecl(format, "decode")) return @field(format, "decode")(allocator, bytes, .{});
        if (comptime @hasDecl(format, "decodeCompact")) return @field(format, "decodeCompact")(allocator, bytes, .{});
    } else {
        if (comptime @hasDecl(format, "decodeReference")) return @field(format, "decodeReference")(allocator, bytes, .{});
    }
    return error.SemanticFormatUnavailable;
}

fn measureProfile(io: std.Io, allocator: std.mem.Allocator, model: *const semantic.Model, repetitions: usize, compact: bool) !ProfileMetrics {
    var result = ProfileMetrics{};
    const first = encodeProfile(allocator, model, compact) catch |err| switch (err) {
        error.SemanticFormatUnavailable => return result,
        else => return err,
    };
    defer allocator.free(first);
    result.available = true;
    result.bytes = first.len;
    var encode_timer = Timer.start(io);
    for (0..repetitions) |_| {
        const encoded = try encodeProfile(allocator, model, compact);
        defer allocator.free(encoded);
        result.checksum = hashBytes(result.checksum, encoded);
    }
    result.encode_ns = encode_timer.read();
    var decode_timer = Timer.start(io);
    for (0..repetitions) |iteration| {
        var decoded = try decodeProfile(allocator, first, compact);
        defer decoded.deinit();
        result.query_checksum = hashU64(result.query_checksum, modelDigest(&decoded) ^ iteration);
    }
    result.decode_ns = decode_timer.read();
    return result;
}

fn printProfile(fixture: []const u8, profile: []const u8, metrics: ProfileMetrics, repetitions: usize) void {
    std.debug.print("metric\tsemantic.{s}.{s}.available\t{}\n", .{ fixture, profile, metrics.available });
    if (!metrics.available) return;
    std.debug.print("metric\tsemantic.{s}.{s}.snapshot_bytes\t{}\n", .{ fixture, profile, metrics.bytes });
    std.debug.print("metric\tsemantic.{s}.{s}.encode_ns\t{}\n", .{ fixture, profile, metrics.encode_ns });
    std.debug.print("metric\tsemantic.{s}.{s}.encode_ns_per_operation\t{d}\n", .{ fixture, profile, @as(f64, @floatFromInt(metrics.encode_ns)) / @as(f64, @floatFromInt(repetitions)) });
    std.debug.print("metric\tsemantic.{s}.{s}.decode_ns\t{}\n", .{ fixture, profile, metrics.decode_ns });
    std.debug.print("metric\tsemantic.{s}.{s}.decode_ns_per_operation\t{d}\n", .{ fixture, profile, @as(f64, @floatFromInt(metrics.decode_ns)) / @as(f64, @floatFromInt(repetitions)) });
    std.debug.print("metric\tsemantic.{s}.{s}.checksum\t{}\n", .{ fixture, profile, metrics.checksum });
    std.debug.print("metric\tsemantic.{s}.{s}.query_checksum\t{}\n", .{ fixture, profile, metrics.query_checksum });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const config = try parseConfig(init.minimal.args);
    std.debug.print("metric\tconfig.records\t{}\n", .{config.records});
    std.debug.print("metric\tconfig.repetitions\t{}\n", .{config.repetitions});
    for ([_]bool{ false, true }) |unique| {
        var model = try buildModel(allocator, config.records, unique);
        defer model.deinit();
        const name = if (unique) "unique_strings" else "repeated_strings";
        std.debug.print("metric\tfixture.{s}.model_digest\t{}\n", .{ name, modelDigest(&model) });
        const reference = try measureProfile(init.io, allocator, &model, config.repetitions, false);
        const compact = try measureProfile(init.io, allocator, &model, config.repetitions, true);
        printProfile(name, "reference", reference, config.repetitions);
        printProfile(name, "compact", compact, config.repetitions);
        if (reference.available and compact.available) {
            std.debug.print("metric\tsemantic.{s}.query_equivalent\t{}\n", .{ name, reference.query_checksum == compact.query_checksum });
        }
    }
}

test "semantic benchmark fixture retains multilingual identity and mixed content" {
    var model = try buildModel(std.testing.allocator, 4, false);
    defer model.deinit();
    try std.testing.expect(model.namespaces.len >= 2);
    try std.testing.expect(model.entities.len >= 12);
    try std.testing.expect(model.assertions.len == 4);
    try std.testing.expect(model.documents.len == 8);
}
