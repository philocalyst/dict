//! Independent LEX6/LEX5 comparison harness.
//!
//! This file is a benchmark client, not production code.  It deliberately
//! generates one logical entry/headword/definition workload and lowers that
//! workload into both public models.  The LEX5 module is supplied by the
//! Python wrapper as an explicit frozen root; it is never copied or modified
//! by this program.
//!
//! The process has two modes of interest:
//!
//! * smoke/prepare: build, open, verify, query, load and render, but never
//!   call a clock;
//! * measure: call a monotonic clock only after the exact explicit gate
//!   ROOT-EXPLICIT-QUIET-GATE has been parsed.
//!
//! Expected answers are not input to either reader.  Lookup results are
//! enumerated and consumed into checksums, then compared with an independent
//! logical digest made from the generated input.

const std = @import("std");
const lex6 = @import("src6");
const new_model = lex6.model;
const new_archive = lex6.archive;
const new_query = lex6.query;
const new_render = lex6.render;
const Codec = @TypeOf((new_archive.Options{}).compression);

const lex5 = @import("src5");
const old_model = lex5.model;
const old_book = lex5.book;
const old_compiler = lex5.compiler;

const protocol = "LEX6-BENCH/1";
const quiet_gate = "ROOT-EXPLICIT-QUIET-GATE";
const max_records: usize = 100_000;
const max_definition_bytes: usize = 16 * 1024;

const Profile = enum { flat, rich };
const Distribution = enum { mixed, repetitive, prose };
const CodecChoice = enum { all, raw, adaptive, bzip3 };
const RunMode = enum { smoke, prepare, measure };

const Config = struct {
    mode: RunMode = .smoke,
    records: usize = 32,
    profile: Profile = .flat,
    distribution: Distribution = .mixed,
    codec: CodecChoice = .all,
    warmup: usize = 32,
    repetitions: usize = 128,
    output_dir: ?[]const u8 = null,
    gate: bool = false,
};

const Fixture = struct {
    allocator: std.mem.Allocator,
    profile: Profile,
    distribution: Distribution,
    count: usize,
    ids: []const []const u8,
    headwords: []const []const u8,
    definitions: []const []const u8,
    new_entries: []new_model.Entry,
    new_resources: []new_model.Resource,
    old_input: old_model.Input,

    fn deinit(_: *Fixture) void {}
};

const Query = struct {
    kind: enum { exact, prefix },
    key: []const u8,
};

const Digest = struct {
    state: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),

    fn field(self: *Digest, bytes: []const u8) void {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(bytes.len), .little);
        self.state.update(&length);
        self.state.update(bytes);
    }

    fn marker(self: *Digest, bytes: []const u8) void {
        self.state.update(bytes);
        const separator = [_]u8{0};
        self.state.update(&separator);
    }

    fn finish(self: *Digest) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
        var result: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        self.state.final(&result);
        return result;
    }
};

const Observed = struct {
    count: usize = 0,
    bytes: usize = 0,
    checksum: u64 = 0,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = [_]u8{0} ** std.crypto.hash.sha2.Sha256.digest_length,
};

const Timed = struct {
    samples: usize = 0,
    total_ns: u128 = 0,
    observed: Observed = .{},
};

fn usage() void {
    std.debug.print(
        "usage: runner [--mode smoke|prepare|measure] [--records N] " ++
            "[--profile flat|rich] [--distribution mixed|repetitive|prose] " ++
            "[--codec all|raw|adaptive|bzip3] [--warmup N] [--repetitions N] " ++
            "[--output-dir PATH] [--quiet-gate ROOT-EXPLICIT-QUIET-GATE]\n",
        .{},
    );
}

fn parseEnum(comptime T: type, value: []const u8) !T {
    inline for (@typeInfo(T).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return error.InvalidArgument;
}

fn parseConfig(args: std.process.Args) !Config {
    var result = Config{};
    var iterator = std.process.Args.Iterator.init(args);
    _ = iterator.next();
    while (iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "--mode")) {
            result.mode = try parseEnum(RunMode, iterator.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--records")) {
            result.records = try std.fmt.parseUnsigned(usize, iterator.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--profile")) {
            result.profile = try parseEnum(Profile, iterator.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--distribution")) {
            result.distribution = try parseEnum(Distribution, iterator.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--codec")) {
            result.codec = try parseEnum(CodecChoice, iterator.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            result.warmup = try std.fmt.parseUnsigned(usize, iterator.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--repetitions")) {
            result.repetitions = try std.fmt.parseUnsigned(usize, iterator.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--output-dir")) {
            result.output_dir = iterator.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--quiet-gate")) {
            const value = iterator.next() orelse return error.MissingValue;
            if (!std.mem.eql(u8, value, quiet_gate)) return error.QuietGateMismatch;
            result.gate = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            usage();
            return error.HelpRequested;
        } else {
            return error.InvalidArgument;
        }
    }
    if (result.records == 0 or result.records > max_records) return error.InvalidRecordCount;
    if (result.mode == .measure and !result.gate) return error.QuietGateRequired;
    if (result.mode != .measure and result.gate) return error.QuietGateUnexpected;
    return result;
}

fn allocString(allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(allocator, format, args);
}

fn makeDefinition(allocator: std.mem.Allocator, index: usize, distribution: Distribution) ![]const u8 {
    const repetitive = "A lexical definition repeats a stable phrase for bounded archive measurements.";
    const repetitive_variant = "A lexical definition repeats a stable phrase for bounded archive measurements; class={d}.";
    const prose = "This ordinary prose definition describes a deterministic lexical item in context {d}. " ++
        "It keeps punctuation and word order stable while changing the entry-specific observation.";
    return switch (distribution) {
        .repetitive => if (index % 8 == 0)
            allocString(allocator, repetitive_variant, .{index % 1000})
        else
            allocString(allocator, "{s}", .{repetitive}),
        .prose => allocString(allocator, prose, .{index}),
        .mixed => if (index % 4 == 0)
            allocString(allocator, prose, .{index})
        else if (index % 8 == 1)
            allocString(allocator, repetitive_variant, .{index % 1000})
        else
            allocString(allocator, "{s}", .{repetitive}),
    };
}

fn makeFixture(allocator: std.mem.Allocator, count: usize, profile: Profile, distribution: Distribution) !Fixture {
    const ids = try allocator.alloc([]const u8, count);
    const headwords = try allocator.alloc([]const u8, count);
    const definitions = try allocator.alloc([]const u8, count);
    const entries = try allocator.alloc(new_model.Entry, count);
    const new_items = try allocator.alloc(new_model.Item, count);
    const resources = try allocator.alloc(new_model.Resource, if (profile == .rich) count else 0);
    const source_ids = try allocator.alloc([]const u8, if (profile == .rich) count else 0);
    const source_bytes = try allocator.alloc([]const u8, if (profile == .rich) count else 0);
    const origins = try allocator.alloc(new_model.Origin, if (profile == .rich) count else 0);

    const rich_inline_count: usize = if (profile == .rich) 3 else 1;
    const inline_items = try allocator.alloc(new_model.Inline, count * rich_inline_count);
    const inline_children = if (profile == .rich)
        try allocator.alloc(new_model.Inline, count)
    else
        @as([]new_model.Inline, &.{});

    for (0..count) |index| {
        ids[index] = try allocString(allocator, "entry-{d:0>7}", .{index});
        headwords[index] = try allocString(allocator, "term-{d:0>7}", .{index});
        definitions[index] = try makeDefinition(allocator, index, distribution);

        if (profile == .rich) {
            source_ids[index] = try allocString(allocator, "tei-source-{d:0>7}", .{index});
            source_bytes[index] = try allocString(allocator, "<entry><definition>{s}</definition></entry>", .{definitions[index]});
            resources[index] = .{ .source = .{
                .id = source_ids[index],
                .media_type = "application/tei+xml",
                .bytes = source_bytes[index],
            } };
            origins[index] = .{ .anchor = .{
                .source = source_ids[index],
                .start = 0,
                .end = @intCast(source_bytes[index].len),
            } };
            // Split one canonical definition into three inline pieces.  The
            // concatenation is byte-identical to the flat definition.
            const definition = definitions[index];
            const first = definition.len / 3;
            const second = first + (definition.len - first) / 2;
            inline_children[index] = .{ .text = definition[first..second] };
            inline_items[index * 3] = .{ .text = definition[0..first] };
            inline_items[index * 3 + 1] = .{ .element = .{
                .name = .{ .local = "hi" },
                .content = inline_children[index .. index + 1],
            } };
            inline_items[index * 3 + 2] = .{ .text = definition[second..] };
        } else {
            inline_items[index] = .{ .text = definitions[index] };
        }

        new_items[index] = .{ .definition = .{
            .content = inline_items[index * rich_inline_count .. (index + 1) * rich_inline_count],
        } };
        entries[index] = .{
            .id = ids[index],
            .headword = headwords[index],
            .meta = if (profile == .rich) .{ .origins = origins[index .. index + 1] } else .{},
            .content = new_items[index .. index + 1],
        };
    }

    const old_input = try makeOldInput(allocator, ids, headwords, definitions, source_ids, profile);
    return .{
        .allocator = allocator,
        .profile = profile,
        .distribution = distribution,
        .count = count,
        .ids = ids,
        .headwords = headwords,
        .definitions = definitions,
        .new_entries = entries,
        .new_resources = resources,
        .old_input = old_input,
    };
}

fn makeOldInput(
    allocator: std.mem.Allocator,
    ids: []const []const u8,
    headwords: []const []const u8,
    definitions: []const []const u8,
    source_ids: []const []const u8,
    profile: Profile,
) !old_model.Input {
    const count = ids.len;
    const records = try allocator.alloc(old_model.RecordInput, count * 2);
    const keys = try allocator.alloc(old_model.KeyInput, count);
    const documents = try allocator.alloc(old_model.DocumentInput, count);
    const bindings = try allocator.alloc(old_model.BindingInput, count * 2);
    const facts = try allocator.alloc(old_model.FactInput, count);
    const predicates = try allocator.alloc(old_model.PredicateInput, 1);

    const occurrence_count: usize = if (profile == .rich) 3 else 2;
    const occurrences = try allocator.alloc(old_model.OccurrenceInput, count * occurrence_count);
    const document_events = try allocator.alloc(old_model.EventInput, count);
    const entry_events = try allocator.alloc(old_model.EventInput, count);
    const definition_events = if (profile == .rich)
        try allocator.alloc(old_model.EventInput, count * 3)
    else
        try allocator.alloc(old_model.EventInput, count);
    const inline_events = if (profile == .rich)
        try allocator.alloc(old_model.EventInput, count)
    else
        @as([]old_model.EventInput, &.{});

    predicates[0] = .{
        .name = "definition",
        .subject = .{ .record = .entry },
        .object = .{ .record = .definition },
    };

    for (0..count) |index| {
        const entry_record: old_model.Ref(.entry) = @enumFromInt(@as(u32, @intCast(index)));
        const definition_record: old_model.Ref(.definition) = @enumFromInt(@as(u32, @intCast(index)));
        records[index] = .{ .entry = .{
            .written = headwords[index],
            .external_id = .{ .text = ids[index] },
        } };
        records[count + index] = .{ .definition = .{ .written = definitions[index] } };
        keys[index] = .{ .headword = .{ .key = headwords[index], .entry = entry_record } };

        const occurrence_base = index * occurrence_count;
        entry_events[index] = .{ .child = @enumFromInt(@as(u32, 1)) };
        document_events[index] = .{ .child = @enumFromInt(@as(u32, 0)) };
        occurrences[occurrence_base] = .{
            .name = .{ .namespace_uri = "", .local_name = "entry" },
            .content = entry_events[index .. index + 1],
        };
        if (profile == .rich) {
            const event_base = index * 3;
            definition_events[event_base] = .{ .text = definitions[index][0 .. definitions[index].len / 3] };
            definition_events[event_base + 1] = .{ .child = @enumFromInt(@as(u32, 2)) };
            const first = definitions[index].len / 3;
            const second = first + (definitions[index].len - first) / 2;
            definition_events[event_base + 2] = .{ .text = definitions[index][second..] };
            inline_events[index] = .{ .text = definitions[index][first..second] };
            occurrences[occurrence_base + 1] = .{
                .name = .{ .namespace_uri = "", .local_name = "definition" },
                .content = definition_events[event_base .. event_base + 3],
            };
            occurrences[occurrence_base + 2] = .{
                .name = .{ .namespace_uri = "", .local_name = "hi" },
                .content = inline_events[index .. index + 1],
            };
        } else {
            definition_events[index] = .{ .text = definitions[index] };
            occurrences[occurrence_base + 1] = .{
                .name = .{ .namespace_uri = "", .local_name = "definition" },
                .content = definition_events[index .. index + 1],
            };
        }
        documents[index] = .{
            .scope = if (profile == .rich) source_ids[index] else "lex6-bench",
            .occurrences = occurrences[occurrence_base .. occurrence_base + occurrence_count],
            .content = document_events[index .. index + 1],
        };

        bindings[index * 2] = .{
            .record = .{ .entry = entry_record },
            .source = .{ .occurrence = .{
                .document = @enumFromInt(@as(u32, @intCast(index))),
                .occurrence = @enumFromInt(@as(u32, 0)),
            } },
        };
        bindings[index * 2 + 1] = .{
            .record = .{ .definition = definition_record },
            .source = .{ .occurrence = .{
                .document = @enumFromInt(@as(u32, @intCast(index))),
                .occurrence = @enumFromInt(@as(u32, 1)),
            } },
        };
        facts[index] = .{ .relation = .{
            .subject = .{ .record = .{ .entry = entry_record } },
            .predicate = @enumFromInt(0),
            .object = .{ .record = .{ .definition = definition_record } },
        } };
    }

    return .{
        .documents = documents,
        .records = records,
        .keys = keys,
        .bindings = bindings,
        .facts = facts,
        .predicates = predicates,
    };
}

fn expectedLogicalDigest(fixture: *const Fixture) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var digest = Digest{};
    digest.marker("logical-entry-headword-definition/1");
    for (fixture.ids, fixture.headwords, fixture.definitions) |id, headword, definition| {
        digest.field(id);
        digest.field(headword);
        digest.field(definition);
    }
    return digest.finish();
}

fn expectedQueryDigest(fixture: *const Fixture, query: Query) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var digest = Digest{};
    digest.marker(if (query.kind == .exact) "exact/1" else "prefix/1");
    digest.field(query.key);
    for (fixture.ids, fixture.headwords) |id, headword| {
        const matches = if (query.kind == .exact)
            std.mem.eql(u8, headword, query.key)
        else
            std.mem.startsWith(u8, headword, query.key);
        if (!matches) continue;
        digest.field(id);
        digest.field(headword);
        digest.marker("form:null");
    }
    return digest.finish();
}

fn expectedRenderedDigest(fixture: *const Fixture) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var digest = Digest{};
    digest.marker("rendered-definition/1");
    for (fixture.ids, fixture.definitions) |id, definition| {
        digest.field(id);
        digest.field(definition);
    }
    return digest.finish();
}

fn hexDigest(digest: [std.crypto.hash.sha2.Sha256.digest_length]u8, output: *[std.crypto.hash.sha2.Sha256.digest_length * 2]u8) []const u8 {
    const digits = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        output[index * 2] = digits[byte >> 4];
        output[index * 2 + 1] = digits[byte & 0x0f];
    }
    return output;
}

fn hashBytes(bytes: []const u8) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var result: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn printDigest(writer: *std.Io.Writer, name: []const u8, digest: [std.crypto.hash.sha2.Sha256.digest_length]u8) !void {
    var buffer: [std.crypto.hash.sha2.Sha256.digest_length * 2]u8 = undefined;
    try writer.print("{s}\t{s}\t{s}\n", .{ name, "sha256", hexDigest(digest, &buffer) });
}

fn writeArtifact(init: std.process.Init, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(init.io, path, .{ .truncate = true });
    defer file.close(init.io);
    var buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn appendPath(allocator: std.mem.Allocator, directory: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, name });
}

fn outputArtifact(init: std.process.Init, allocator: std.mem.Allocator, directory: ?[]const u8, name: []const u8, bytes: []const u8) !void {
    if (directory) |dir| {
        const path = try appendPath(allocator, dir, name);
        defer allocator.free(path);
        try writeArtifact(init, path, bytes);
    }
}

fn newBuild(allocator: std.mem.Allocator, fixture: *const Fixture, mode: Codec) !new_archive.Owned {
    const options = new_archive.Options{ .compression = mode };
    return new_archive.build(allocator, .{ .entries = fixture.new_entries, .resources = fixture.new_resources }, options);
}

fn oldBuild(allocator: std.mem.Allocator, fixture: *const Fixture) !old_compiler.Owned {
    return old_compiler.build(allocator, fixture.old_input);
}

fn newDefinition(entry: *const new_model.Entry, output: []u8) ![]const u8 {
    var selection = new_query.entry(entry).select(.definition, .descendants);
    const match = (try selection.next()) orelse return error.MissingDefinition;
    var writer = std.Io.Writer.fixed(output);
    try new_render.write(match.value.*, &writer, .plain);
    return writer.buffered();
}

fn newSnippet(entry: *const new_model.Entry, output: []u8) ![]const u8 {
    var selection = new_query.entry(entry).select(.definition, .descendants);
    const match = (try selection.next()) orelse return error.MissingDefinition;
    return try new_render.snippet(match.value.*, output);
}

fn expectedSnippet(input: []const u8, limit: usize, output: []u8) ![]const u8 {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidFixtureUtf8;
    const wanted = @min(input.len, limit);
    var take = wanted;
    if (take < input.len) {
        while (take != 0 and input[take] & 0xc0 == 0x80) take -= 1;
    }
    if (take > output.len) return error.SnippetOutputTooSmall;
    @memcpy(output[0..take], input[0..take]);
    return output[0..take];
}

fn oldDefinition(book: *const old_book.Book, rank: usize, output: []u8) ![]const u8 {
    var source_selection = try book.sources(.entry, @enumFromInt(@as(u32, @intCast(rank))), .realization);
    var source_hits = try source_selection.iterator();
    const source_hit = (try source_hits.next()) orelse return error.MissingDefinition;
    var descendants = source_hit.source.descendants(.definition);
    var texts = try descendants.texts().iterator();
    var written: usize = 0;
    var found = false;
    while (try texts.next()) |hit| {
        found = true;
        const part = try hit.value.render(output[written..]);
        written += part.len;
    }
    if (!found) return error.MissingDefinition;
    return output[0..written];
}

fn oldSnippet(book: *const old_book.Book, rank: usize, output: []u8) ![]const u8 {
    var source_selection = try book.sources(.entry, @enumFromInt(@as(u32, @intCast(rank))), .realization);
    var source_hits = try source_selection.iterator();
    const source_hit = (try source_hits.next()) orelse return error.MissingDefinition;
    var descendants = source_hit.source.descendants(.definition);
    var texts = try descendants.texts().iterator();
    var written: usize = 0;
    var found = false;
    while (written < output.len) {
        const hit = (try texts.next()) orelse break;
        found = true;
        const part = try hit.value.snippet(output[written..]);
        written += part.len;
    }
    if (!found) return error.MissingDefinition;
    return output[0..written];
}

fn updateFnv(checksum: *u64, bytes: []const u8) void {
    var hash = std.hash.Fnv1a_64.init();
    hash.update(bytes);
    checksum.* ^= hash.final();
}

fn materializeKey(key: new_archive.KeyView, output: []u8) ![]const u8 {
    if (key.prefix.len > output.len or key.suffix.len > output.len - key.prefix.len) return error.KeyTooLong;
    var writer = std.Io.Writer.fixed(output);
    try key.writeTo(&writer);
    return writer.buffered();
}

fn consumeNewHits(archive: *const new_archive.Archive, fixture: *const Fixture, query: Query, key_buffer: []u8) !Observed {
    var result = Observed{};
    var digest = Digest{};
    digest.marker(if (query.kind == .exact) "exact/1" else "prefix/1");
    digest.field(query.key);
    var hits = if (query.kind == .exact)
        try archive.lookup(query.key)
    else
        try archive.prefix(query.key);
    while (try hits.next()) |hit| {
        const index: usize = hit.entry.value;
        if (index >= fixture.count) return error.InvalidHit;
        digest.field(fixture.ids[index]);
        const spelling = try materializeKey(hit.spelling, key_buffer);
        digest.field(spelling);
        if (hit.form) |form| digest.field(form) else digest.marker("form:null");
        result.count += 1;
        result.bytes += spelling.len;
        updateFnv(&result.checksum, spelling);
    }
    result.digest = digest.finish();
    return result;
}

fn consumeOldHits(book: *const old_book.Book, fixture: *const Fixture, query: Query, key_buffer: []u8) !Observed {
    var result = Observed{};
    var digest = Digest{};
    digest.marker(if (query.kind == .exact) "exact/1" else "prefix/1");
    digest.field(query.key);
    var selection = if (query.kind == .exact)
        try book.lookup(query.key)
    else
        try book.prefix(query.key);
    var iterator = selection.iterator();
    while (try iterator.next()) |hit| {
        const spelling = try (try book.text(try hit.key())).render(key_buffer);
        const rank: usize = switch (try (try hit.claim()).choice()) {
            .headword => |headword| @intFromEnum(try headword.field(.entry).read()),
            .form => return error.UnexpectedFormHit,
        };
        if (rank >= fixture.count) return error.InvalidHit;
        digest.field(fixture.ids[rank]);
        digest.field(spelling);
        digest.marker("form:null");
        result.count += 1;
        result.bytes += spelling.len;
        updateFnv(&result.checksum, spelling);
    }
    result.digest = digest.finish();
    return result;
}

fn checkQueries(
    writer: *std.Io.Writer,
    archive: *const new_archive.Archive,
    book: *const old_book.Book,
    fixture: *const Fixture,
    allocator: std.mem.Allocator,
) !void {
    const all_key = "term-";
    const partial_key = "term-000";
    const missing_key = "absent-";
    const queries = [_]Query{
        .{ .kind = .exact, .key = fixture.headwords[0] },
        .{ .kind = .exact, .key = fixture.headwords[fixture.count - 1] },
        .{ .kind = .exact, .key = missing_key },
        .{ .kind = .prefix, .key = partial_key },
        .{ .kind = .prefix, .key = all_key },
        .{ .kind = .prefix, .key = missing_key },
    };
    const key_buffer = try allocator.alloc(u8, max_definition_bytes);
    defer allocator.free(key_buffer);
    for (queries, 0..) |query, ordinal| {
        const expected = expectedQueryDigest(fixture, query);
        const new_observed = try consumeNewHits(archive, fixture, query, key_buffer);
        const old_observed = try consumeOldHits(book, fixture, query, key_buffer);
        if (new_observed.count != old_observed.count) return error.QueryCountMismatch;
        if (new_observed.bytes != old_observed.bytes) return error.QueryByteMismatch;
        const expected_count = expectedHitCount(fixture, query);
        if (new_observed.count != expected_count) return error.ExpectedHitCountMismatch;
        if (!std.mem.eql(u8, &new_observed.digest, &old_observed.digest)) return error.QueryDigestMismatch;
        if (!std.mem.eql(u8, &new_observed.digest, &expected)) return error.ExpectedDigestMismatch;
        var expected_hex: [64]u8 = undefined;
        try writer.print("query\t{d}\t{s}\tcount\t{d}\told_count\t{d}\n", .{
            ordinal,
            if (query.kind == .exact) "exact" else "prefix",
            new_observed.count,
            old_observed.count,
        });
        try writer.print("query\t{d}\tdigest\t{s}\n", .{ ordinal, hexDigest(new_observed.digest, &expected_hex) });
    }
}

fn expectedHitCount(fixture: *const Fixture, query: Query) usize {
    var count: usize = 0;
    for (fixture.headwords) |headword| {
        if (if (query.kind == .exact) std.mem.eql(u8, headword, query.key) else std.mem.startsWith(u8, headword, query.key)) count += 1;
    }
    return count;
}

fn checkNewEntries(
    writer: *std.Io.Writer,
    archive: *const new_archive.Archive,
    fixture: *const Fixture,
    allocator: std.mem.Allocator,
) !void {
    const output = try allocator.alloc(u8, max_definition_bytes);
    defer allocator.free(output);
    const snippet_output = try allocator.alloc(u8, 128);
    defer allocator.free(snippet_output);
    var digest = Digest{};
    digest.marker("rendered-definition/1");
    for (fixture.ids, fixture.headwords, fixture.definitions, 0..) |id, headword, definition, index| {
        var loaded = try archive.load(allocator, new_archive.EntryId{ .value = @intCast(index) });
        defer loaded.deinit();
        if (!std.mem.eql(u8, loaded.value.id, id) or !std.mem.eql(u8, loaded.value.headword, headword)) return error.EntryIdentityMismatch;
        const rendered = try newDefinition(&loaded.value, output);
        if (!std.mem.eql(u8, rendered, definition)) return error.RenderMismatch;
        const snippet_limit = @min(definition.len, 17 + index % 31);
        const snippet = try newSnippet(&loaded.value, snippet_output[0..snippet_limit]);
        var expected_snippet_buffer: [128]u8 = undefined;
        const expected_snippet = try expectedSnippet(definition, snippet_limit, &expected_snippet_buffer);
        if (!std.mem.eql(u8, snippet, expected_snippet)) return error.SnippetMismatch;
        digest.field(id);
        digest.field(rendered);
    }
    try printDigest(writer, "new_rendered_digest", digest.finish());
}

fn checkOldEntries(
    writer: *std.Io.Writer,
    book: *const old_book.Book,
    fixture: *const Fixture,
    allocator: std.mem.Allocator,
) !void {
    const output = try allocator.alloc(u8, max_definition_bytes);
    defer allocator.free(output);
    const snippet_output = try allocator.alloc(u8, 128);
    defer allocator.free(snippet_output);
    var digest = Digest{};
    digest.marker("rendered-definition/1");
    for (fixture.ids, fixture.definitions, 0..) |id, definition, index| {
        const rendered = try oldDefinition(book, index, output);
        if (!std.mem.eql(u8, rendered, definition)) return error.RenderMismatch;
        const snippet_limit = @min(definition.len, 17 + index % 31);
        const snippet = try oldSnippet(book, index, snippet_output[0..snippet_limit]);
        var expected_snippet_buffer: [128]u8 = undefined;
        const expected_snippet = try expectedSnippet(definition, snippet_limit, &expected_snippet_buffer);
        if (!std.mem.eql(u8, snippet, expected_snippet)) return error.SnippetMismatch;
        digest.field(id);
        digest.field(rendered);
    }
    try printDigest(writer, "old_rendered_digest", digest.finish());
}

fn checkNewResources(
    writer: *std.Io.Writer,
    archive: *const new_archive.Archive,
    fixture: *const Fixture,
    allocator: std.mem.Allocator,
) !void {
    if (fixture.profile != .rich) return;
    var digest = Digest{};
    digest.marker("resource-source/1");
    for (fixture.new_resources) |resource| {
        switch (resource) {
            .source => |source| {
                const catalog_hit = (try archive.resource(source.id)) orelse return error.MissingResource;
                if (catalog_hit.kind != .source or catalog_hit.source_length != source.bytes.len)
                    return error.ResourceCatalogMismatch;
                var loaded = try archive.load(allocator, catalog_hit.resource);
                defer loaded.deinit();
                switch (loaded.value) {
                    .source => |loaded_source| {
                        if (!std.mem.eql(u8, loaded_source.id, source.id) or
                            !std.mem.eql(u8, loaded_source.bytes, source.bytes)) return error.ResourceContentMismatch;
                    },
                    else => return error.ResourceKindMismatch,
                }
                digest.field(source.id);
                digest.field(source.bytes);
            },
            else => return error.UnexpectedResourceKind,
        }
    }
    try printDigest(writer, "new_resource_digest", digest.finish());
}

fn checkOldIdentities(book: *const old_book.Book, fixture: *const Fixture, allocator: std.mem.Allocator) !void {
    // Looking up each external identity through the actual Book API confirms
    // that the old bridge did not merely preserve a rank in the key table.
    for (fixture.ids, 0..) |id, index| {
        const found = try book.recordByIdentity(.entry, .{ .text = id });
        if (found == null or @intFromEnum(found.?) != index) return error.OldIdentityMismatch;
    }
    _ = allocator;
}

fn printArtifact(
    writer: *std.Io.Writer,
    lane: []const u8,
    codec: []const u8,
    bytes: []const u8,
) !void {
    const digest = hashBytes(bytes);
    try writer.print("artifact\t{s}\t{s}\tbytes\t{d}\n", .{ lane, codec, bytes.len });
    var hex: [64]u8 = undefined;
    try writer.print("artifact\t{s}\t{s}\tsha256\t{s}\n", .{ lane, codec, hexDigest(digest, &hex) });
}

fn modeName(mode: Codec) []const u8 {
    return @tagName(mode);
}

fn selectedModes(choice: CodecChoice) []const Codec {
    return switch (choice) {
        .all => &.{ .raw, .adaptive, .bzip3 },
        .raw => &.{.raw},
        .adaptive => &.{.adaptive},
        .bzip3 => &.{.bzip3},
    };
}

fn observeTimed(result: *Timed, elapsed: u128, observed: Observed) void {
    result.samples += 1;
    result.total_ns += elapsed;
    result.observed.count += observed.count;
    result.observed.bytes += observed.bytes;
    result.observed.checksum ^= observed.checksum;
}

fn nowNs() u128 {
    const value = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
    return @intCast(value);
}

fn printTimed(writer: *std.Io.Writer, lane: []const u8, codec: []const u8, phase: []const u8, timed: Timed) !void {
    try writer.print("timing\t{s}\t{s}\t{s}\tsamples\t{d}\ttotal_ns\t{d}\tcount\t{d}\tbytes\t{d}\tchecksum\t{d}\n", .{
        lane,
        codec,
        phase,
        timed.samples,
        timed.total_ns,
        timed.observed.count,
        timed.observed.bytes,
        timed.observed.checksum,
    });
}

fn queryPhase(query: Query, ordinal: usize, output: *[256]u8) []const u8 {
    const kind = if (query.kind == .exact) "lookup_exact" else "lookup_prefix";
    return std.fmt.bufPrint(output, "{s}[{d}]={s}", .{ kind, ordinal, query.key }) catch
        std.fmt.bufPrint(output, "{s}[{d}]/key-too-long", .{ kind, ordinal }) catch unreachable;
}

fn measureNew(
    writer: *std.Io.Writer,
    init: std.process.Init,
    allocator: std.mem.Allocator,
    fixture: *const Fixture,
    codec: Codec,
    output_dir: ?[]const u8,
    config: Config,
) !void {
    var build_timed = Timed{};
    std.mem.doNotOptimizeAway(fixture);
    const build_start = nowNs();
    var owned = try newBuild(allocator, fixture, codec);
    std.mem.doNotOptimizeAway(&owned.bytes);
    const build_end = nowNs();
    observeTimed(&build_timed, build_end - build_start, .{ .bytes = owned.bytes.len });
    defer owned.deinit();
    const artifact_name = try std.fmt.allocPrint(allocator, "new-{s}.lex6", .{modeName(codec)});
    defer allocator.free(artifact_name);
    try outputArtifact(init, allocator, output_dir, artifact_name, owned.bytes);
    try printArtifact(writer, "new", modeName(codec), owned.bytes);
    try printTimed(writer, "new", modeName(codec), "build", build_timed);

    var open_timed = Timed{};
    std.mem.doNotOptimizeAway(&owned.bytes);
    const open_start = nowNs();
    var archive = try new_archive.Archive.open(owned.bytes, .{});
    std.mem.doNotOptimizeAway(&archive);
    const open_end = nowNs();
    observeTimed(&open_timed, open_end - open_start, .{});
    try printTimed(writer, "new", modeName(codec), "open", open_timed);

    var verify_timed = Timed{};
    std.mem.doNotOptimizeAway(&archive);
    const verify_start = nowNs();
    try archive.verifyAll(allocator);
    std.mem.doNotOptimizeAway(&archive);
    const verify_end = nowNs();
    observeTimed(&verify_timed, verify_end - verify_start, .{});
    try printTimed(writer, "new", modeName(codec), "verify_all", verify_timed);

    const queries = [_]Query{
        .{ .kind = .exact, .key = fixture.headwords[0] },
        .{ .kind = .prefix, .key = "term-000" },
        .{ .kind = .prefix, .key = "term-" },
        .{ .kind = .prefix, .key = "absent-" },
    };
    const key_buffer = try allocator.alloc(u8, max_definition_bytes);
    defer allocator.free(key_buffer);
    for (queries, 0..) |query, ordinal| {
        var warm_count: usize = 0;
        var warm_checksum: u64 = 0;
        for (0..config.warmup) |_| {
            const observed = try consumeNewHits(&archive, fixture, query, key_buffer);
            warm_count += observed.count;
            warm_checksum ^= observed.checksum;
        }
        std.mem.doNotOptimizeAway(warm_count);
        std.mem.doNotOptimizeAway(warm_checksum);
        var query_timed = Timed{};
        for (0..config.repetitions) |_| {
            std.mem.doNotOptimizeAway(archive);
            std.mem.doNotOptimizeAway(fixture);
            std.mem.doNotOptimizeAway(&query);
            const start = nowNs();
            const observed = try consumeNewHits(&archive, fixture, query, key_buffer);
            std.mem.doNotOptimizeAway(&observed);
            const end = nowNs();
            observeTimed(&query_timed, end - start, observed);
        }
        var phase: [256]u8 = undefined;
        try printTimed(writer, "new", modeName(codec), queryPhase(query, ordinal, &phase), query_timed);
    }

    const loaded_index: usize = fixture.count / 2;
    var loaded = try archive.load(allocator, new_archive.EntryId{ .value = @intCast(loaded_index) });
    defer loaded.deinit();
    const output = try allocator.alloc(u8, max_definition_bytes);
    defer allocator.free(output);
    var warm_render_count: usize = 0;
    var warm_render_checksum: u64 = 0;
    for (0..config.warmup) |_| {
        const rendered = try newDefinition(&loaded.value, output);
        warm_render_count += rendered.len;
        updateFnv(&warm_render_checksum, rendered);
    }
    std.mem.doNotOptimizeAway(warm_render_count);
    std.mem.doNotOptimizeAway(warm_render_checksum);
    var warm_timed = Timed{};
    for (0..config.repetitions) |_| {
        std.mem.doNotOptimizeAway(&loaded.value);
        const start = nowNs();
        const rendered = try newDefinition(&loaded.value, output);
        std.mem.doNotOptimizeAway(&rendered);
        const end = nowNs();
        observeTimed(&warm_timed, end - start, .{ .bytes = rendered.len });
        updateFnv(&warm_timed.observed.checksum, rendered);
    }
    try printTimed(writer, "new", modeName(codec), "warm_typed_select_render", warm_timed);

    var warm_snippet_count: usize = 0;
    var warm_snippet_checksum: u64 = 0;
    const snippet_output = try allocator.alloc(u8, 128);
    defer allocator.free(snippet_output);
    for (0..config.warmup) |_| {
        const snippet = try newSnippet(&loaded.value, snippet_output);
        warm_snippet_count += snippet.len;
        updateFnv(&warm_snippet_checksum, snippet);
    }
    std.mem.doNotOptimizeAway(warm_snippet_count);
    std.mem.doNotOptimizeAway(warm_snippet_checksum);
    var snippet_timed = Timed{};
    for (0..config.repetitions) |_| {
        std.mem.doNotOptimizeAway(&loaded.value);
        const start = nowNs();
        const snippet = try newSnippet(&loaded.value, snippet_output);
        std.mem.doNotOptimizeAway(&snippet);
        const end = nowNs();
        observeTimed(&snippet_timed, end - start, .{ .bytes = snippet.len });
        updateFnv(&snippet_timed.observed.checksum, snippet);
    }
    try printTimed(writer, "new", modeName(codec), "warm_typed_select_snippet", snippet_timed);

    var warm_cold_count: usize = 0;
    var warm_cold_checksum: u64 = 0;
    for (0..config.warmup) |_| {
        var cold = try archive.load(allocator, new_archive.EntryId{ .value = @intCast(loaded_index) });
        warm_cold_count += cold.value.id.len;
        updateFnv(&warm_cold_checksum, cold.value.id);
        cold.deinit();
    }
    std.mem.doNotOptimizeAway(warm_cold_count);
    std.mem.doNotOptimizeAway(warm_cold_checksum);
    var cold_timed = Timed{};
    for (0..config.repetitions) |_| {
        std.mem.doNotOptimizeAway(archive);
        const start = nowNs();
        var cold = try archive.load(allocator, new_archive.EntryId{ .value = @intCast(loaded_index) });
        std.mem.doNotOptimizeAway(&cold.value);
        const end = nowNs();
        observeTimed(&cold_timed, end - start, .{ .bytes = cold.value.id.len });
        cold.deinit();
    }
    try printTimed(writer, "new", modeName(codec), "cold_load_decode_validate", cold_timed);
}

fn measureOld(
    writer: *std.Io.Writer,
    init: std.process.Init,
    allocator: std.mem.Allocator,
    fixture: *const Fixture,
    output_dir: ?[]const u8,
    config: Config,
) !void {
    var build_timed = Timed{};
    std.mem.doNotOptimizeAway(fixture);
    const build_start = nowNs();
    var owned = try oldBuild(allocator, fixture);
    std.mem.doNotOptimizeAway(&owned.bytes);
    const build_end = nowNs();
    observeTimed(&build_timed, build_end - build_start, .{ .bytes = owned.bytes.len });
    defer owned.deinit();
    try outputArtifact(init, allocator, output_dir, "old-borrowed-core.lex5", owned.bytes);
    try printArtifact(writer, "old_borrowed_core", "native", owned.bytes);
    try printTimed(writer, "old_borrowed_core", "native", "build", build_timed);

    std.mem.doNotOptimizeAway(&owned.bytes);
    const open_start = nowNs();
    var pending = try old_book.open(allocator, @as([]const u8, owned.bytes));
    std.mem.doNotOptimizeAway(&pending);
    const open_end = nowNs();
    var open_timed = Timed{};
    observeTimed(&open_timed, open_end - open_start, .{});
    try printTimed(writer, "old_borrowed_core", "native", "open_metadata", open_timed);

    std.mem.doNotOptimizeAway(&pending);
    const validate_start = nowNs();
    var book = try pending.verify();
    defer book.close();
    std.mem.doNotOptimizeAway(&book);
    const validate_end = nowNs();
    var validate_timed = Timed{};
    observeTimed(&validate_timed, validate_end - validate_start, .{});
    try printTimed(writer, "old_borrowed_core", "native", "verify_all", validate_timed);

    const key_buffer = try allocator.alloc(u8, max_definition_bytes);
    defer allocator.free(key_buffer);
    const queries = [_]Query{
        .{ .kind = .exact, .key = fixture.headwords[0] },
        .{ .kind = .prefix, .key = "term-000" },
        .{ .kind = .prefix, .key = "term-" },
        .{ .kind = .prefix, .key = "absent-" },
    };
    for (queries, 0..) |query, ordinal| {
        var warm_count: usize = 0;
        var warm_checksum: u64 = 0;
        for (0..config.warmup) |_| {
            const observed = try consumeOldHits(&book, fixture, query, key_buffer);
            warm_count += observed.count;
            warm_checksum ^= observed.checksum;
        }
        std.mem.doNotOptimizeAway(warm_count);
        std.mem.doNotOptimizeAway(warm_checksum);
        var query_timed = Timed{};
        for (0..config.repetitions) |_| {
            std.mem.doNotOptimizeAway(&book);
            std.mem.doNotOptimizeAway(fixture);
            std.mem.doNotOptimizeAway(&query);
            const start = nowNs();
            const observed = try consumeOldHits(&book, fixture, query, key_buffer);
            std.mem.doNotOptimizeAway(&observed);
            const end = nowNs();
            observeTimed(&query_timed, end - start, observed);
        }
        var phase: [256]u8 = undefined;
        try printTimed(writer, "old_borrowed_core", "native", queryPhase(query, ordinal, &phase), query_timed);
    }

    const loaded_index = fixture.count / 2;
    const output = try allocator.alloc(u8, max_definition_bytes);
    defer allocator.free(output);
    var warm_render_count: usize = 0;
    var warm_render_checksum: u64 = 0;
    for (0..config.warmup) |_| {
        const rendered = try oldDefinition(&book, loaded_index, output);
        warm_render_count += rendered.len;
        updateFnv(&warm_render_checksum, rendered);
    }
    std.mem.doNotOptimizeAway(warm_render_count);
    std.mem.doNotOptimizeAway(warm_render_checksum);
    var warm_timed = Timed{};
    for (0..config.repetitions) |_| {
        std.mem.doNotOptimizeAway(&book);
        const start = nowNs();
        const rendered = try oldDefinition(&book, loaded_index, output);
        std.mem.doNotOptimizeAway(&rendered);
        const end = nowNs();
        observeTimed(&warm_timed, end - start, .{ .bytes = rendered.len });
        updateFnv(&warm_timed.observed.checksum, rendered);
    }
    try printTimed(writer, "old_borrowed_core", "native", "warm_source_lookup_render", warm_timed);

    var warm_snippet_count: usize = 0;
    var warm_snippet_checksum: u64 = 0;
    const snippet_output = try allocator.alloc(u8, 128);
    defer allocator.free(snippet_output);
    for (0..config.warmup) |_| {
        const snippet = try oldSnippet(&book, loaded_index, snippet_output);
        warm_snippet_count += snippet.len;
        updateFnv(&warm_snippet_checksum, snippet);
    }
    std.mem.doNotOptimizeAway(warm_snippet_count);
    std.mem.doNotOptimizeAway(warm_snippet_checksum);
    var snippet_timed = Timed{};
    for (0..config.repetitions) |_| {
        std.mem.doNotOptimizeAway(&book);
        const start = nowNs();
        const snippet = try oldSnippet(&book, loaded_index, snippet_output);
        std.mem.doNotOptimizeAway(&snippet);
        const end = nowNs();
        observeTimed(&snippet_timed, end - start, .{ .bytes = snippet.len });
        updateFnv(&snippet_timed.observed.checksum, snippet);
    }
    try printTimed(writer, "old_borrowed_core", "native", "source_lookup_snippet", snippet_timed);

    var warm_cold_count: usize = 0;
    var warm_cold_checksum: u64 = 0;
    for (0..config.warmup) |_| {
        const rendered = try oldDefinition(&book, loaded_index, output);
        warm_cold_count += rendered.len;
        updateFnv(&warm_cold_checksum, rendered);
    }
    std.mem.doNotOptimizeAway(warm_cold_count);
    std.mem.doNotOptimizeAway(warm_cold_checksum);
    var cold_timed = Timed{};
    for (0..config.repetitions) |_| {
        std.mem.doNotOptimizeAway(&book);
        const start = nowNs();
        const rendered = try oldDefinition(&book, loaded_index, output);
        std.mem.doNotOptimizeAway(&rendered);
        const end = nowNs();
        observeTimed(&cold_timed, end - start, .{ .bytes = rendered.len });
        updateFnv(&cold_timed.observed.checksum, rendered);
    }
    try printTimed(writer, "old_borrowed_core", "native", "source_read_render_control", cold_timed);
}

fn runNoClock(
    writer: *std.Io.Writer,
    init: std.process.Init,
    allocator: std.mem.Allocator,
    fixture: *const Fixture,
    config: Config,
) !void {
    try writer.print("{s}\tstatus\tprepared_no_clock\n", .{protocol});
    try writer.print("config\trecords\t{d}\n", .{fixture.count});
    try writer.print("config\tprofile\t{s}\n", .{@tagName(fixture.profile)});
    try writer.print("config\tdistribution\t{s}\n", .{@tagName(fixture.distribution)});
    try printDigest(writer, "logical_digest", expectedLogicalDigest(fixture));
    try printDigest(writer, "expected_rendered_digest", expectedRenderedDigest(fixture));

    var old_owned = try oldBuild(allocator, fixture);
    defer old_owned.deinit();
    try outputArtifact(init, allocator, config.output_dir, "old-borrowed-core.lex5", old_owned.bytes);
    try printArtifact(writer, "old_borrowed_core", "native", old_owned.bytes);
    var pending = try old_book.open(allocator, @as([]const u8, old_owned.bytes));
    var book = try pending.verify();
    defer book.close();
    try checkOldIdentities(&book, fixture, allocator);
    try checkOldEntries(writer, &book, fixture, allocator);

    for (selectedModes(config.codec)) |codec| {
        var new_owned = try newBuild(allocator, fixture, codec);
        defer new_owned.deinit();
        const artifact_name = try std.fmt.allocPrint(allocator, "new-{s}.lex6", .{modeName(codec)});
        defer allocator.free(artifact_name);
        try outputArtifact(init, allocator, config.output_dir, artifact_name, new_owned.bytes);
        try printArtifact(writer, "new", modeName(codec), new_owned.bytes);
        var archive = try new_archive.Archive.open(new_owned.bytes, .{});
        try archive.verifyAll(allocator);
        try checkNewResources(writer, &archive, fixture, allocator);
        try checkNewEntries(writer, &archive, fixture, allocator);
        try checkQueries(writer, &archive, &book, fixture, allocator);
    }
    try writer.print("timing\tstatus\tunauthorized\n", .{});
}

fn runMeasured(
    writer: *std.Io.Writer,
    init: std.process.Init,
    allocator: std.mem.Allocator,
    fixture: *const Fixture,
    config: Config,
) !void {
    if (!config.gate) return error.QuietGateRequired;
    try writer.print("{s}\tstatus\tmeasured_after_explicit_gate\n", .{protocol});
    try writer.print("config\trecords\t{d}\n", .{fixture.count});
    try writer.print("config\tprofile\t{s}\n", .{@tagName(fixture.profile)});
    try writer.print("config\tdistribution\t{s}\n", .{@tagName(fixture.distribution)});

    // Correctness is intentionally repeated in the measured process before
    // collecting timings.  It is outside all clocked regions.
    var old_owned = try oldBuild(allocator, fixture);
    defer old_owned.deinit();
    var pending = try old_book.open(allocator, @as([]const u8, old_owned.bytes));
    var book = try pending.verify();
    defer book.close();
    try checkOldIdentities(&book, fixture, allocator);
    try checkOldEntries(writer, &book, fixture, allocator);
    for (selectedModes(config.codec)) |codec| {
        var new_owned = try newBuild(allocator, fixture, codec);
        defer new_owned.deinit();
        var archive = try new_archive.Archive.open(new_owned.bytes, .{});
        try archive.verifyAll(allocator);
        try checkNewResources(writer, &archive, fixture, allocator);
        try checkNewEntries(writer, &archive, fixture, allocator);
        try checkQueries(writer, &archive, &book, fixture, allocator);
    }
    // Rebuild once for the actual timed lane; the correctness pass above is
    // not used to supply a timing answer or a precomputed reader result.
    try measureOld(writer, init, allocator, fixture, config.output_dir, config);
    for (selectedModes(config.codec)) |codec| try measureNew(writer, init, allocator, fixture, codec, config.output_dir, config);
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const fixture_allocator = arena.allocator();
    // Fixture strings and pointer graphs have one arena lifetime.  Archive,
    // old-book, decode, validation, and reader work use the normal process
    // allocator so every deallocation and temporary allocation is real.
    const runtime_allocator = init.gpa;
    const config = parseConfig(init.minimal.args) catch |err| {
        if (err == error.HelpRequested) return;
        usage();
        return err;
    };
    const fixture_count = if (config.mode == .smoke) @min(config.records, 32) else config.records;
    var fixture = try makeFixture(fixture_allocator, fixture_count, config.profile, config.distribution);
    defer fixture.deinit();
    var output_buffer: [64 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    if (config.mode == .measure) {
        try runMeasured(&writer.interface, init, runtime_allocator, &fixture, config);
    } else {
        try runNoClock(&writer.interface, init, runtime_allocator, &fixture, config);
    }
    try writer.interface.flush();
}
