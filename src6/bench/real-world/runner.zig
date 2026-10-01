//! Independent real-corpus LEX6 builder and correctness smoke reader.
//!
//! Input is the three-column hex projection emitted by prepare.py:
//! `row_id_hex<TAB>comma-separated-key_hex<TAB>content_hex`.  This process
//! does not receive expected query answers.  Smoke output is an observation
//! digest; the Python oracle compares that digest and every individual result
//! with the independently parsed projection.
//!
//! The optional timing mode is explicitly gate-controlled so a non-gated smoke
//! run cannot accidentally become a benchmark.  The Python driver owns the
//! schedule and this binary only reports in-process LEX6 phases.

const std = @import("std");
const lex6 = @import("lex6");
const model = lex6.model;
const packet = lex6.packet;
const archive_api = lex6.archive;
const compression = lex6.compression;

const max_projection_bytes: usize = 512 * 1024 * 1024;
const max_entries: usize = 1_000_000;
const quiet_gate = "ROOT-EXPLICIT-QUIET-GATE";

const Mode = enum { build, smoke, diagnose, whole_bzip3, measure };

const Config = struct {
    mode: Mode = .build,
    input: ?[]const u8 = null,
    artifact: ?[]const u8 = null,
    queries: ?[]const u8 = null,
    rows: ?[]const u8 = null,
    compression: compression.Mode = .adaptive,
    target_page_bytes: usize = 64 * 1024,
    max_page_bytes: usize = 1024 * 1024,
    max_document_bytes: usize = 1024 * 1024,
    quiet_gate_seen: bool = false,
};

fn usage() void {
    std.debug.print(
        "usage: real-lex6 --mode build|smoke|diagnose|whole_bzip3|measure --input PROJECTION.tsv --artifact FILE " ++
            "[--compression raw|adaptive|bzip3] [--target-page-bytes N] " ++
            "[--max-page-bytes N] [--max-document-bytes N] [--queries FILE] [--rows FILE] " ++
            "[--quiet-gate ROOT-EXPLICIT-QUIET-GATE]\n",
        .{},
    );
}

fn parseMode(value: []const u8) !Mode {
    if (std.mem.eql(u8, value, "build")) return .build;
    if (std.mem.eql(u8, value, "smoke")) return .smoke;
    if (std.mem.eql(u8, value, "diagnose")) return .diagnose;
    if (std.mem.eql(u8, value, "whole_bzip3")) return .whole_bzip3;
    if (std.mem.eql(u8, value, "measure")) return .measure;
    return error.InvalidArgument;
}

fn parseCompression(value: []const u8) !compression.Mode {
    if (std.mem.eql(u8, value, "raw")) return .raw;
    if (std.mem.eql(u8, value, "adaptive")) return .adaptive;
    if (std.mem.eql(u8, value, "bzip3")) return .bzip3;
    return error.InvalidArgument;
}

fn parseConfig(args: std.process.Args) !Config {
    var result = Config{};
    var iterator = std.process.Args.Iterator.init(args);
    _ = iterator.next();
    while (iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "--mode")) {
            result.mode = try parseMode(iterator.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--input")) {
            result.input = iterator.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--artifact")) {
            result.artifact = iterator.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--queries")) {
            result.queries = iterator.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--rows")) {
            result.rows = iterator.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--compression")) {
            result.compression = try parseCompression(iterator.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--target-page-bytes")) {
            result.target_page_bytes = try std.fmt.parseUnsigned(usize, iterator.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--max-page-bytes")) {
            result.max_page_bytes = try std.fmt.parseUnsigned(usize, iterator.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--max-document-bytes")) {
            result.max_document_bytes = try std.fmt.parseUnsigned(usize, iterator.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--quiet-gate")) {
            const value = iterator.next() orelse return error.MissingValue;
            if (!std.mem.eql(u8, value, quiet_gate)) return error.QuietGateMismatch;
            result.quiet_gate_seen = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            usage();
            return error.HelpRequested;
        } else {
            return error.InvalidArgument;
        }
    }
    if (result.quiet_gate_seen and result.mode != .measure) return error.TimingGateNotApplicable;
    if (result.mode == .measure and !result.quiet_gate_seen) return error.TimingGateRequired;
    if (result.mode == .diagnose and result.artifact == null) return error.MissingArgument;
    if (result.mode == .whole_bzip3 and result.input == null) return error.MissingArgument;
    if ((result.mode == .build or result.mode == .smoke) and (result.artifact == null or result.input == null)) return error.MissingArgument;
    if (result.mode == .measure and (result.artifact == null or result.input == null)) return error.MissingArgument;
    if (result.target_page_bytes == 0 or result.target_page_bytes > result.max_page_bytes) return error.InvalidPageTarget;
    if (result.max_page_bytes < compression.min_native_block_bytes) return error.InvalidCompressionLimit;
    if (result.max_document_bytes == 0 or result.max_document_bytes > result.max_page_bytes) return error.InvalidDocumentLimit;
    return result;
}

fn hexDigit(value: u8) ?u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => null,
    };
}

fn decodeHex(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len % 2 != 0) return error.InvalidHex;
    var result = try allocator.alloc(u8, text.len / 2);
    errdefer allocator.free(result);
    for (0..result.len) |index| {
        const high = hexDigit(text[index * 2]) orelse return error.InvalidHex;
        const low = hexDigit(text[index * 2 + 1]) orelse return error.InvalidHex;
        result[index] = (high << 4) | low;
    }
    return result;
}

fn parseKeys(allocator: std.mem.Allocator, text: []const u8) ![]model.SearchKey {
    // An empty key is represented by one empty hex component.  There is no
    // zero-key lexical record in the canonical projection.
    var values: std.ArrayList(model.SearchKey) = .empty;
    var pieces = std.mem.splitScalar(u8, text, ',');
    while (pieces.next()) |piece| {
        const spelling = try decodeHex(allocator, piece);
        values.append(allocator, .{ .spelling = spelling }) catch return error.OutOfMemory;
    }
    if (values.items.len == 0) return error.InvalidKeyList;
    return values.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

const Pending = struct {
    id: []const u8,
    keys: []const model.SearchKey,
    content: []const u8,
};

const Projection = struct {
    allocator: std.mem.Allocator,
    entries: []model.Entry,
    items: []model.Item,
    inlines: []model.Inline,

    fn deinit(_: *Projection) void {}
};

fn readProjection(allocator: std.mem.Allocator, bytes: []const u8) !Projection {
    var pending: std.ArrayList(Pending) = .empty;
    // Permit exactly the normal final LF (or CRLF), but reject an empty row
    // anywhere else.  Silently skipping blank lines would make a malformed
    // projection appear to have fewer source records than the independent
    // oracle.
    var body = bytes;
    if (body.len != 0 and body[body.len - 1] == '\n') body = body[0 .. body.len - 1];
    if (body.len != 0 and body[body.len - 1] == '\r') body = body[0 .. body.len - 1];
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        var line = raw_line;
        if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) {
            return error.MalformedProjection;
        }
        if (pending.items.len >= max_entries) return error.TooManyEntries;
        var columns = std.mem.splitScalar(u8, line, '\t');
        const id_hex = columns.next() orelse return error.MalformedProjection;
        const key_hex = columns.next() orelse return error.MalformedProjection;
        const content_hex = columns.next() orelse return error.MalformedProjection;
        if (columns.next() != null) return error.MalformedProjection;
        const id = try decodeHex(allocator, id_hex);
        if (id.len == 0 or !std.unicode.utf8ValidateSlice(id)) return error.InvalidIdentity;
        const keys = try parseKeys(allocator, key_hex);
        for (keys) |key| if (!std.unicode.utf8ValidateSlice(key.spelling)) return error.InvalidUtf8;
        const content = try decodeHex(allocator, content_hex);
        if (!std.unicode.utf8ValidateSlice(content)) return error.InvalidUtf8;
        try pending.append(allocator, .{ .id = id, .keys = keys, .content = content });
    }
    if (pending.items.len == 0) return error.EmptyProjection;

    const entries = try allocator.alloc(model.Entry, pending.items.len);
    const items = try allocator.alloc(model.Item, pending.items.len);
    const inlines = try allocator.alloc(model.Inline, pending.items.len);
    for (pending.items, 0..) |record, index| {
        inlines[index] = .{ .text = record.content };
        items[index] = .{ .definition = .{ .content = inlines[index .. index + 1] } };
        entries[index] = .{
            .id = record.id,
            .headword = record.keys[0].spelling,
            // `Entry.headword` is itself an indexed spelling.  The canonical
            // keys[] field includes that first spelling for every external
            // format; expose only aliases here so it is not indexed twice.
            .keys = if (record.keys.len > 1) record.keys[1..] else &.{},
            .content = items[index .. index + 1],
        };
    }
    return .{ .allocator = allocator, .entries = entries, .items = items, .inlines = inlines };
}

fn readFile(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(max_projection_bytes));
}

fn writeFile(init: std.process.Init, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(init.io, path, .{ .truncate = true });
    defer file.close(init.io);
    var buffer: [32 * 1024]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

const Digest = struct {
    state: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),

    fn field(self: *Digest, value: []const u8) void {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(value.len), .little);
        self.state.update(&length);
        self.state.update(value);
    }

    fn marker(self: *Digest, value: []const u8) void {
        self.state.update(value);
        self.state.update(&[_]u8{0});
    }

    fn finish(self: *Digest) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
        var output: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        self.state.final(&output);
        return output;
    }
};

const Timer = struct {
    io: std.Io,
    start_ns: i96,

    fn start(io: std.Io) Timer {
        return .{ .io = io, .start_ns = std.Io.Clock.awake.now(io).nanoseconds };
    }

    fn read(self: *const Timer) u64 {
        const elapsed = std.Io.Clock.awake.now(self.io).nanoseconds - self.start_ns;
        return @intCast(@max(@as(i96, 0), elapsed));
    }
};

const TimedQueryMode = enum { exact, prefix };

const TimedQuery = struct {
    label: []const u8,
    mode: TimedQueryMode,
    key: []u8,
};

const TimedRow = struct {
    label: []const u8,
    entry: usize,
};

fn readTimedQueries(allocator: std.mem.Allocator, bytes: []const u8) ![]TimedQuery {
    var result: std.ArrayList(TimedQuery) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        if (raw_line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, raw_line, '\t');
        const label = fields.next() orelse return error.MalformedQueryFile;
        const mode_text = fields.next() orelse return error.MalformedQueryFile;
        const key_text = fields.next() orelse return error.MalformedQueryFile;
        if (fields.next() != null) return error.MalformedQueryFile;
        const mode = if (std.mem.eql(u8, mode_text, "exact")) TimedQueryMode.exact else if (std.mem.eql(u8, mode_text, "prefix")) TimedQueryMode.prefix else return error.InvalidQueryMode;
        const key = try decodeHex(allocator, key_text);
        try result.append(allocator, .{ .label = label, .mode = mode, .key = key });
    }
    if (result.items.len == 0) return error.EmptyQueryFile;
    return result.toOwnedSlice(allocator);
}

fn readTimedRows(allocator: std.mem.Allocator, bytes: []const u8) ![]TimedRow {
    var result: std.ArrayList(TimedRow) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        if (raw_line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, raw_line, '\t');
        const label = fields.next() orelse return error.MalformedRowsFile;
        const row_text = fields.next() orelse return error.MalformedRowsFile;
        if (fields.next() != null) return error.MalformedRowsFile;
        const entry = try std.fmt.parseUnsigned(usize, row_text, 10);
        try result.append(allocator, .{ .label = label, .entry = entry });
    }
    if (result.items.len == 0) return error.EmptyRowsFile;
    return result.toOwnedSlice(allocator);
}

const QueryStats = struct {
    digest: Digest = .{},
    operations: usize = 0,
    hits: usize = 0,
    key_bytes: usize = 0,

    fn init() QueryStats {
        var result = QueryStats{};
        result.digest.marker("measure-query-hits-v1");
        return result;
    }
};

fn consumeQuery(archive: *const archive_api.Archive, allocator: std.mem.Allocator, query: TimedQuery, stats: *QueryStats) !void {
    var hits = if (query.mode == .exact) try archive.lookup(query.key) else try archive.prefix(query.key);
    stats.digest.field(query.key);
    while (try hits.next()) |hit| {
        var entry_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &entry_bytes, hit.entry.value, .little);
        stats.digest.field(&entry_bytes);
        var key_buffer: [64 * 1024]u8 = undefined;
        var key_writer = std.Io.Writer.fixed(&key_buffer);
        try hit.spelling.writeTo(&key_writer);
        stats.digest.field(key_writer.buffered());
        if (hit.form) |form| stats.digest.field(form) else stats.digest.marker("form:null");
        stats.hits += 1;
        stats.key_bytes += key_writer.buffered().len;
    }
    _ = allocator;
    stats.operations += 1;
}

const RenderStats = struct {
    digest: Digest = .{},
    operations: usize = 0,
    output_bytes: usize = 0,

    fn init(label: []const u8) RenderStats {
        var result = RenderStats{};
        result.digest.marker(label);
        return result;
    }
};

fn consumeRender(archive: *const archive_api.Archive, allocator: std.mem.Allocator, row: TimedRow, snippet: bool, stats: *RenderStats) !void {
    var decoded = try archive.load(allocator, archive_api.EntryId{ .value = @intCast(row.entry) });
    defer decoded.deinit();
    var output: [256 * 1024]u8 = undefined;
    var rendered_writer = std.Io.Writer.fixed(&output);
    var selected = false;
    for (decoded.value.content) |item| switch (item) {
        .definition => |definition| {
            selected = true;
            try lex6.render.write(definition, &rendered_writer, .plain);
        },
        else => {},
    };
    if (!selected) return error.MissingProjectionDefinition;
    const rendered = rendered_writer.buffered();
    const selected_bytes = if (snippet) rendered[0..@min(rendered.len, 256)] else rendered;
    stats.digest.field(selected_bytes);
    stats.output_bytes += selected_bytes.len;
    stats.operations += 1;
}

fn consumeRenderSession(reader: *archive_api.Reader, row: TimedRow, snippet: bool, stats: *RenderStats) !void {
    var decoded = try reader.load(archive_api.EntryId{ .value = @intCast(row.entry) });
    defer decoded.deinit();
    var output: [256 * 1024]u8 = undefined;
    var rendered_writer = std.Io.Writer.fixed(&output);
    var selected = false;
    for (decoded.value.content) |item| switch (item) {
        .definition => |definition| {
            selected = true;
            try lex6.render.write(definition, &rendered_writer, .plain);
        },
        else => {},
    };
    if (!selected) return error.MissingProjectionDefinition;
    const rendered = rendered_writer.buffered();
    const selected_bytes = if (snippet) rendered[0..@min(rendered.len, 256)] else rendered;
    stats.digest.field(selected_bytes);
    stats.output_bytes += selected_bytes.len;
    stats.operations += 1;
}

fn writeQueryStats(writer: *std.Io.Writer, label: []const u8, elapsed_ns: u64, stats: QueryStats) !void {
    var digest_hex: [64]u8 = undefined;
    var digest = stats.digest;
    try writer.print("{s}\toperations\t{d}\tns\t{d}\thits\t{d}\tkey_bytes\t{d}\tdigest\t{s}\n", .{
        label,
        stats.operations,
        elapsed_ns,
        stats.hits,
        stats.key_bytes,
        digestHex(digest.finish(), &digest_hex),
    });
}

fn writeRenderStats(writer: *std.Io.Writer, label: []const u8, elapsed_ns: u64, stats: RenderStats) !void {
    var digest_hex: [64]u8 = undefined;
    var digest = stats.digest;
    try writer.print("{s}\toperations\t{d}\tns\t{d}\toutput_bytes\t{d}\tdigest\t{s}\n", .{
        label,
        stats.operations,
        elapsed_ns,
        stats.output_bytes,
        digestHex(digest.finish(), &digest_hex),
    });
}

fn writeSessionFirst(
    writer: *std.Io.Writer,
    row: TimedRow,
    elapsed_ns: u64,
    stats: RenderStats,
    delta: archive_api.Reader.Stats,
) !void {
    var digest_hex: [64]u8 = undefined;
    var digest = stats.digest;
    try writer.print("session_first_cold\tlabel\t{s}\toperations\t{d}\tns\t{d}\toutput_bytes\t{d}\tpage_loads\t{d}\tbzip3_decodes\t{d}\tdecoded_bytes\t{d}\tcache_hits\t{d}\tdigest\t{s}\n", .{
        row.label,
        stats.operations,
        elapsed_ns,
        stats.output_bytes,
        delta.page_loads,
        delta.bzip3_decodes,
        delta.decoded_bytes,
        delta.cache_hits,
        digestHex(digest.finish(), &digest_hex),
    });
}

fn writeSessionStats(
    writer: *std.Io.Writer,
    label: []const u8,
    elapsed_ns: u64,
    stats: RenderStats,
    delta: archive_api.Reader.Stats,
) !void {
    var digest_hex: [64]u8 = undefined;
    var digest = stats.digest;
    try writer.print("{s}\toperations\t{d}\tns\t{d}\toutput_bytes\t{d}\tpage_loads\t{d}\tbzip3_decodes\t{d}\tdecoded_bytes\t{d}\tcache_hits\t{d}\tdigest\t{s}\n", .{
        label,
        stats.operations,
        elapsed_ns,
        stats.output_bytes,
        delta.page_loads,
        delta.bzip3_decodes,
        delta.decoded_bytes,
        delta.cache_hits,
        digestHex(digest.finish(), &digest_hex),
    });
}

fn readerStatsDelta(before: archive_api.Reader.Stats, after: archive_api.Reader.Stats) archive_api.Reader.Stats {
    return .{
        .page_loads = after.page_loads - before.page_loads,
        .bzip3_decodes = after.bzip3_decodes - before.bzip3_decodes,
        .decoded_bytes = after.decoded_bytes - before.decoded_bytes,
        .cache_hits = after.cache_hits - before.cache_hits,
    };
}

fn digestHex(digest: [std.crypto.hash.sha2.Sha256.digest_length]u8, output: *[64]u8) []const u8 {
    const digits = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        output[index * 2] = digits[byte >> 4];
        output[index * 2 + 1] = digits[byte & 15];
    }
    return output;
}

fn writeDigest(writer: *std.Io.Writer, label: []const u8, digest: [32]u8) !void {
    var hex: [64]u8 = undefined;
    try writer.print("{s}\t{s}\n", .{ label, digestHex(digest, &hex) });
}

fn readU32(bytes: []const u8, offset: usize) !u32 {
    if (offset + 4 > bytes.len) return error.TruncatedArtifact;
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn readU64(bytes: []const u8, offset: usize) !u64 {
    if (offset + 8 > bytes.len) return error.TruncatedArtifact;
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

fn observeDiagnostic(init: std.process.Init, allocator: std.mem.Allocator, artifact: []const u8, max_page_bytes: usize) !void {
    const header_size: usize = 112;
    const directory_record_size: usize = 64;
    if (artifact.len < header_size or !std.mem.eql(u8, artifact[0..8], "LEX6AR01")) return error.InvalidArchive;
    // The sweep is a storage diagnostic, but each artifact still receives a
    // complete independent open/verify pass before page-level decomposition.
    // This keeps a malformed packet/index from being reported as a valid page
    // size or bzip3 result.
    var archive = try archive_api.Archive.open(artifact, .{
        .max_archive_bytes = max_projection_bytes,
        .max_page_bytes = max_page_bytes,
        .compression_limits = .{ .max_block_bytes = max_page_bytes },
    });
    try archive.verifyAll(allocator);
    const page_count = try readU32(artifact, 20);
    const directory_offset = std.math.cast(usize, try readU64(artifact, 48)) orelse return error.ArchiveTooLarge;
    const pages_offset = std.math.cast(usize, try readU64(artifact, 64)) orelse return error.ArchiveTooLarge;
    const pages_length = std.math.cast(usize, try readU64(artifact, 72)) orelse return error.ArchiveTooLarge;
    if (directory_offset + @as(usize, page_count) * directory_record_size > artifact.len or
        pages_offset + pages_length != artifact.len) return error.InvalidArchive;
    var raw_total: usize = 0;
    var encoded_total: usize = 0;
    var bzip_pages: usize = 0;
    var raw_pages: usize = 0;
    var smaller_pages: usize = 0;
    var not_smaller_pages: usize = 0;
    var resource_fallback_pages: usize = 0;
    var probe_errors: usize = 0;
    var out_buffer: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &out_buffer);
    for (0..page_count) |page_index| {
        const record = directory_offset + page_index * directory_record_size;
        const offset = std.math.cast(usize, try readU64(artifact, record)) orelse return error.ArchiveTooLarge;
        const encoded_length = try readU32(artifact, record + 8);
        const raw_length = try readU32(artifact, record + 12);
        const codec_tag = artifact[record + 24];
        if (offset + encoded_length > pages_length or raw_length > max_page_bytes) return error.InvalidArchive;
        const encoded = artifact[pages_offset + offset ..][0..encoded_length];
        raw_total += raw_length;
        encoded_total += encoded_length;
        var raw_block: ?compression.Block = null;
        const raw_bytes: []const u8 = switch (codec_tag) {
            @intFromEnum(compression.Codec.raw) => blk: {
                raw_pages += 1;
                if (encoded_length != raw_length) return error.InvalidArchive;
                break :blk encoded;
            },
            @intFromEnum(compression.Codec.bzip3) => blk: {
                bzip_pages += 1;
                raw_block = try compression.decode(allocator, .bzip3, encoded, raw_length, .{ .max_block_bytes = max_page_bytes });
                break :blk raw_block.?.bytes;
            },
            else => return error.InvalidCodec,
        };
        const probe = compression.encode(allocator, raw_bytes, .bzip3, .{ .max_block_bytes = max_page_bytes }) catch |err| blk: {
            probe_errors += 1;
            if (err == error.ResourceLimit) resource_fallback_pages += 1;
            break :blk null;
        };
        if (probe) |compressed_value| {
            var compressed = compressed_value;
            defer compressed.deinit();
            if (compressed.bytes.len < raw_bytes.len) smaller_pages += 1 else not_smaller_pages += 1;
            try writer.interface.print("diag\tpage\t{d}\traw\t{d}\tencoded\t{d}\tcodec\t{s}\tprobe\t{d}\tprobe_relation\t{s}\n", .{
                page_index,
                raw_length,
                encoded_length,
                if (codec_tag == @intFromEnum(compression.Codec.raw)) "raw" else "bzip3",
                compressed.bytes.len,
                if (compressed.bytes.len < raw_bytes.len) "smaller" else "not-smaller",
            });
        } else {
            try writer.interface.print("diag\tpage\t{d}\traw\t{d}\tencoded\t{d}\tcodec\t{s}\tprobe\terror\n", .{
                page_index,
                raw_length,
                encoded_length,
                if (codec_tag == @intFromEnum(compression.Codec.raw)) "raw" else "bzip3",
            });
        }
        if (raw_block) |*block| block.deinit();
    }
    try writer.interface.print("diag_summary\tpages\t{d}\traw_pages\t{d}\tbzip3_pages\t{d}\traw_bytes\t{d}\tencoded_bytes\t{d}\tprobe_smaller\t{d}\tprobe_not_smaller\t{d}\tprobe_errors\t{d}\tresource_limit_fallbacks\t{d}\n", .{
        page_count,
        raw_pages,
        bzip_pages,
        raw_total,
        encoded_total,
        smaller_pages,
        not_smaller_pages,
        probe_errors,
        resource_fallback_pages,
    });
    try writer.interface.flush();
}

fn observeQueries(writer: *std.Io.Writer, archive: *const archive_api.Archive, allocator: std.mem.Allocator, bytes: []const u8) !void {
    var key_buffer: [64 * 1024]u8 = undefined;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        var line = raw_line;
        if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const mode = fields.next() orelse return error.MalformedQueryFile;
        const key_text = fields.next() orelse return error.MalformedQueryFile;
        if (fields.next() != null) return error.MalformedQueryFile;
        const key = try decodeHex(allocator, key_text);
        var digest = Digest{};
        digest.marker("query-hits-v1");
        digest.field(key);
        var count: usize = 0;
        var hits = if (std.mem.eql(u8, mode, "exact"))
            try archive.lookup(key)
        else if (std.mem.eql(u8, mode, "prefix"))
            try archive.prefix(key)
        else
            return error.InvalidQueryMode;
        while (try hits.next()) |hit| {
            var entry_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &entry_bytes, hit.entry.value, .little);
            digest.field(&entry_bytes);
            var key_writer = std.Io.Writer.fixed(&key_buffer);
            try hit.spelling.writeTo(&key_writer);
            digest.field(key_writer.buffered());
            if (hit.form) |form| digest.field(form) else digest.marker("form:null");
            count += 1;
        }
        var key_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(key, &key_digest, .{});
        var key_hex: [64]u8 = undefined;
        var result_hex: [64]u8 = undefined;
        try writer.print("query\t{s}\t{s}\t{d}\t{s}\n", .{ mode, digestHex(key_digest, &key_hex), count, digestHex(digest.finish(), &result_hex) });
    }
}

const SmokeEntry = struct {
    id: []const u8,
    headword: []const u8,
    content: []const u8,
};

/// Retained only as a compatibility helper for old generated binaries; the
/// live smoke path below uses the public stateful Reader instead.
const SmokePacketCursor = struct {
    bytes: []const u8,
    at: usize = 0,

    fn byte(self: *SmokePacketCursor) !u8 {
        if (self.at >= self.bytes.len) return error.TruncatedPacket;
        const value = self.bytes[self.at];
        self.at += 1;
        return value;
    }

    fn varint(self: *SmokePacketCursor) !u64 {
        var value: u64 = 0;
        var shift: u6 = 0;
        for (0..10) |index| {
            const part = try self.byte();
            if (index == 9 and part > 1) return error.IntegerOverflow;
            value |= @as(u64, part & 0x7f) << shift;
            if ((part & 0x80) == 0) {
                if (index > 0 and part == 0) return error.NonCanonicalVarint;
                return value;
            }
            if (index != 9) shift += 7;
        }
        return error.IntegerOverflow;
    }

    fn length(self: *SmokePacketCursor) !usize {
        return std.math.cast(usize, try self.varint()) orelse error.IntegerOverflow;
    }

    fn slice(self: *SmokePacketCursor) ![]const u8 {
        const count = try self.length();
        const end = std.math.add(usize, self.at, count) catch return error.TruncatedPacket;
        if (end > self.bytes.len) return error.TruncatedPacket;
        const result = self.bytes[self.at..end];
        self.at = end;
        return result;
    }

    fn expectLength(self: *SmokePacketCursor, expected: usize) !void {
        if (try self.length() != expected) return error.InvalidPacketShape;
    }

    fn expectEnum(self: *SmokePacketCursor, expected: u64) !void {
        if (try self.varint() != expected) return error.InvalidPacketShape;
    }

    fn expectAbsent(self: *SmokePacketCursor) !void {
        if (try self.byte() != 0) return error.InvalidPacketShape;
    }

    fn expectDefaultMetadata(self: *SmokePacketCursor) !void {
        // Metadata fields on the harness-produced entries are all defaults.
        try self.expectAbsent(); // id
        try self.expectEnum(0); // Language.inherit
        try self.expectLength(0); // evidence
        try self.expectLength(0); // origins
        try self.expectLength(0); // certainty
        try self.expectLength(0); // annotations
        try self.expectLength(0); // attributes
    }

    fn decodeEntry(self: *SmokePacketCursor) !SmokeEntry {
        if (self.bytes.len < 5 or !std.mem.eql(u8, self.bytes[0..4], "LXP6") or self.bytes[4] != packet.schema_version)
            return error.InvalidPacketShape;
        self.at = 5;
        try self.expectEnum(0); // Document.entry union arm
        const id = try self.slice();
        const headword = try self.slice();
        try self.expectDefaultMetadata();
        try self.expectEnum(0); // Entry.kind.word
        try self.expectAbsent(); // homograph
        const key_count = try self.length();
        for (0..key_count) |_| {
            _ = try self.slice(); // SearchKey.spelling
            try self.expectAbsent(); // SearchKey.form
        }
        try self.expectLength(1); // one matched definition item
        try self.expectEnum(2); // Item.definition
        try self.expectDefaultMetadata(); // Text.meta
        try self.expectLength(1); // one Inline child
        try self.expectEnum(0); // Inline.text
        const content = try self.slice();
        try self.expectLength(0); // Entry.sources
        try self.expectLength(0); // Entry.residuals
        if (self.at != self.bytes.len) return error.TrailingPacketBytes;
        return .{ .id = id, .headword = headword, .content = content };
    }
};

fn decodeSmokeEntry(bytes: []const u8) !SmokeEntry {
    var cursor = SmokePacketCursor{ .bytes = bytes };
    return cursor.decodeEntry();
}

fn buildArchive(allocator: std.mem.Allocator, projection: *const Projection, config: Config) !archive_api.Owned {
    return archive_api.build(allocator, .{ .entries = projection.entries }, .{
        .target_page_bytes = config.target_page_bytes,
        .max_page_bytes = config.max_page_bytes,
        .max_document_bytes = config.max_document_bytes,
        .compression = config.compression,
        .compression_limits = .{ .max_block_bytes = config.max_page_bytes },
    });
}

fn observeWholeBzip3(init: std.process.Init, allocator: std.mem.Allocator, projection: *const Projection) !void {
    // This is deliberately a storage-only control: concatenate the matched
    // content payloads, compress once with the real libbz3 API, and report the
    // result separately from page-addressable LEX6 artifacts.  Index/header
    // metadata and random-access query semantics are not part of this stream.
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    for (projection.inlines) |inline_value| switch (inline_value) {
        .text => |text| try raw.appendSlice(allocator, text),
        else => return error.InvalidProjection,
    };
    const limits = compression.Limits{
        .max_block_bytes = @max(compression.min_native_block_bytes, raw.items.len),
        .max_memory_bytes = 2 * 1024 * 1024 * 1024,
    };
    var compressed = compression.encode(allocator, raw.items, .bzip3, limits) catch |err| {
        var out_buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stdout().writer(init.io, &out_buffer);
        try writer.interface.print("whole_bzip3\tstatus\terror\traw_bytes\t{d}\terror\t{s}\n", .{ raw.items.len, @errorName(err) });
        try writer.interface.flush();
        return err;
    };
    defer compressed.deinit();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(compressed.bytes, &digest, .{});
    var digest_hex: [64]u8 = undefined;
    var out_buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &out_buffer);
    try writer.interface.print("whole_bzip3\tstatus\tok\traw_bytes\t{d}\tencoded_bytes\t{d}\n", .{ raw.items.len, compressed.bytes.len });
    try writeDigest(&writer.interface, "whole_bzip3_sha256", digest);
    _ = digestHex(digest, &digest_hex);
    try writer.interface.flush();
}

fn observeSmoke(init: std.process.Init, allocator: std.mem.Allocator, artifact: []const u8, expected_entries: usize, query_bytes: ?[]const u8) !void {
    var archive = try archive_api.Archive.open(artifact, .{
        .max_archive_bytes = max_projection_bytes,
        .max_page_bytes = 1024 * 1024,
        .compression_limits = .{ .max_block_bytes = 1024 * 1024 },
    });

    var hit_digest = Digest{};
    hit_digest.marker("all-index-hits-v1");
    var hit_count: usize = 0;
    var key_bytes: usize = 0;
    var key_buffer: [64 * 1024]u8 = undefined;
    var hits = try archive.prefix("");
    while (try hits.next()) |hit| {
        var entry_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &entry_bytes, hit.entry.value, .little);
        hit_digest.field(&entry_bytes);
        var key_writer = std.Io.Writer.fixed(&key_buffer);
        try hit.spelling.writeTo(&key_writer);
        hit_digest.field(key_writer.buffered());
        if (hit.form) |form| hit_digest.field(form) else hit_digest.marker("form:null");
        hit_count += 1;
        key_bytes += hit.spelling.prefix.len + hit.spelling.suffix.len;
    }

    var content_digest = Digest{};
    content_digest.marker("loaded-entry-content-v1");
    var loaded_entries: usize = 0;
    var content_bytes: usize = 0;
    var output: [256 * 1024]u8 = undefined;
    if (expected_entries == 0) return error.EmptyProjection;

    // Use the public stateful Reader for the full content/render check.  It
    // validates every decoded document, reuses one decoded page, and leaves
    // the archive framing/packet semantics under the production API.  This
    // is a correctness smoke pass, not a timing lane.
    var reader = try archive_api.Reader.init(allocator, &archive, .{});
    defer reader.deinit();
    for (0..expected_entries) |document_id| {
        var decoded = try reader.load(archive_api.EntryId{ .value = @intCast(document_id) });
        defer decoded.deinit();
        content_digest.field(decoded.value.id);
        content_digest.field(decoded.value.headword);
        var render_writer = std.Io.Writer.fixed(&output);
        var selected = false;
        for (decoded.value.content) |item| switch (item) {
            .definition => |definition| {
                selected = true;
                try lex6.render.write(definition, &render_writer, .plain);
            },
            else => {},
        };
        if (!selected) return error.MissingProjectionDefinition;
        const rendered = render_writer.buffered();
        content_digest.field(rendered);
        content_bytes += rendered.len;
        loaded_entries += 1;
    }
    if (loaded_entries != expected_entries) return error.EntryCountMismatch;

    var out_buffer: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &out_buffer);
    try writer.interface.print("status\tsmoke-ok\nentries\t{d}\nhits\t{d}\tkey_bytes\t{d}\tcontent_bytes\t{d}\n", .{
        expected_entries,
        hit_count,
        key_bytes,
        content_bytes,
    });
    try writeDigest(&writer.interface, "all_hit_digest", hit_digest.finish());
    try writeDigest(&writer.interface, "loaded_content_digest", content_digest.finish());
    try writer.interface.print("loaded_entries\t{d}\n", .{loaded_entries});
    if (query_bytes) |queries| try observeQueries(&writer.interface, &archive, allocator, queries);
    try writer.interface.flush();
}

fn emitFirstQuery(writer: *std.Io.Writer, query: TimedQuery, elapsed_ns: u64, stats: QueryStats) !void {
    var digest_hex: [64]u8 = undefined;
    var digest = stats.digest;
    try writer.print("first_exact\tlabel\t{s}\tns\t{d}\thits\t{d}\tkey_bytes\t{d}\tdigest\t{s}\n", .{
        query.label,
        elapsed_ns,
        stats.hits,
        stats.key_bytes,
        digestHex(digest.finish(), &digest_hex),
    });
}

fn observeMeasure(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    artifact: []const u8,
    query_bytes: []const u8,
    row_bytes: []const u8,
    input_read_ns: u64,
    input_parse_ns: u64,
    artifact_read_ns: u64,
) !void {
    const plan_timer = Timer.start(init.io);
    const queries = try readTimedQueries(allocator, query_bytes);
    const rows = try readTimedRows(allocator, row_bytes);
    const plan_ns = plan_timer.read();

    const open_timer = Timer.start(init.io);
    var archive = try archive_api.Archive.open(artifact, .{
        .max_archive_bytes = max_projection_bytes,
        .max_page_bytes = 1024 * 1024,
        .compression_limits = .{ .max_block_bytes = 1024 * 1024 },
    });
    const open_ns = open_timer.read();

    // Reader.init builds the reusable SourceIndex and establishes the explicit
    // session lifetime.  Its cost is reported independently of both metadata
    // open and eager verification; prepareLinks is intentionally not called
    // for the plain-text projection lane.
    const reader_init_timer = Timer.start(init.io);
    var reader = try archive_api.Reader.init(init.gpa, &archive, .{});
    defer reader.deinit();
    const reader_init_ns = reader_init_timer.read();

    var out_buffer: [32 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &out_buffer);
    try writer.interface.print("measure_status\tok\ninput_read_ns\t{d}\ninput_parse_ns\t{d}\nartifact_read_ns\t{d}\nquery_plan_parse_ns\t{d}\nmetadata_open_ns\t{d}\nreader_init_ns\t{d}\n", .{
        input_read_ns,
        input_parse_ns,
        artifact_read_ns,
        plan_ns,
        open_ns,
        reader_init_ns,
    });

    var exact_count: usize = 0;
    var prefix_count: usize = 0;
    for (queries) |query| {
        if (query.mode == .exact) exact_count += 1 else prefix_count += 1;
    }
    if (exact_count == 0 or prefix_count == 0) return error.InvalidMeasurePlan;

    // A first/cold-in-process exact observation is taken immediately after
    // open+verify.  Each exact class, including missing and high-multiplicity,
    // is represented by its own first operation.
    for (queries) |query| {
        if (query.mode != .exact) continue;
        var stats = QueryStats.init();
        const timer = Timer.start(init.io);
        try consumeQuery(&archive, allocator, query, &stats);
        try emitFirstQuery(&writer.interface, query, timer.read(), stats);
    }

    // One fixed warmup batch is consumed but not reported.  It has the same
    // operation order and checksum work as the measured batch.
    var warmup = QueryStats.init();
    for (0..256) |index| {
        const wanted = index % exact_count;
        var ordinal: usize = 0;
        for (queries) |query| {
            if (query.mode != .exact) continue;
            if (ordinal == wanted) try consumeQuery(&archive, allocator, query, &warmup);
            ordinal += 1;
        }
    }
    _ = warmup.digest.finish();

    var exact_stats = QueryStats.init();
    const exact_timer = Timer.start(init.io);
    for (0..256) |index| {
        var ordinal: usize = 0;
        for (queries) |query| {
            if (query.mode != .exact) continue;
            if (ordinal == index % exact_count) try consumeQuery(&archive, allocator, query, &exact_stats);
            ordinal += 1;
        }
    }
    try writeQueryStats(&writer.interface, "exact_batch", exact_timer.read(), exact_stats);

    // Prefix timing is intentionally a smaller, explicit batch.  The empty
    // prefix all-hit correctness pass was already completed by smoke.py; this
    // phase measures the fixed non-empty short/missing prefix plan three
    // times, reporting hit work for each batch.
    for (0..3) |batch_index| {
        var prefix_stats = QueryStats.init();
        const prefix_timer = Timer.start(init.io);
        for (queries) |query| if (query.mode == .prefix) try consumeQuery(&archive, allocator, query, &prefix_stats);
        var digest_hex: [64]u8 = undefined;
        var digest = prefix_stats.digest;
        try writer.interface.print("prefix_batch\tbatch\t{d}\toperations\t{d}\tns\t{d}\thits\t{d}\tkey_bytes\t{d}\tdigest\t{s}\n", .{
            batch_index,
            prefix_stats.operations,
            prefix_timer.read(),
            prefix_stats.hits,
            prefix_stats.key_bytes,
            digestHex(digest.finish(), &digest_hex),
        });
    }

    var render_count: usize = 0;
    var snippet_count: usize = 0;
    for (rows) |row| {
        if (std.mem.startsWith(u8, row.label, "render")) render_count += 1;
        if (std.mem.startsWith(u8, row.label, "snippet")) snippet_count += 1;
    }
    if (render_count == 0 or snippet_count == 0) return error.InvalidMeasurePlan;

    // First/cold and warm render/snippet observations use the same selected
    // rows as the repeated batches.  Render is full plain output; snippet is
    // the first 256 rendered bytes, so the work boundary is explicit.
    for (rows) |row| {
        const is_render = std.mem.startsWith(u8, row.label, "render");
        const is_snippet = std.mem.startsWith(u8, row.label, "snippet");
        if (!is_render and !is_snippet) continue;
        var stats = RenderStats.init(if (is_render) "measure-render-v1" else "measure-snippet-v1");
        const timer = Timer.start(init.io);
        try consumeRender(&archive, allocator, row, is_snippet, &stats);
        var digest_hex: [64]u8 = undefined;
        try writer.interface.print("first_{s}\tlabel\t{s}\tns\t{d}\toutput_bytes\t{d}\tdigest\t{s}\n", .{
            if (is_render) "render" else "snippet",
            row.label,
            timer.read(),
            stats.output_bytes,
            digestHex(stats.digest.finish(), &digest_hex),
        });
    }

    var render_warmup = RenderStats.init("measure-render-warmup-v1");
    var snippet_warmup = RenderStats.init("measure-snippet-warmup-v1");
    for (0..256) |index| {
        const wanted_render = index % render_count;
        const wanted_snippet = index % snippet_count;
        var render_ordinal: usize = 0;
        var snippet_ordinal: usize = 0;
        for (rows) |row| {
            if (std.mem.startsWith(u8, row.label, "render") and render_ordinal == wanted_render)
                try consumeRender(&archive, allocator, row, false, &render_warmup);
            if (std.mem.startsWith(u8, row.label, "render")) render_ordinal += 1;
            if (std.mem.startsWith(u8, row.label, "snippet") and snippet_ordinal == wanted_snippet)
                try consumeRender(&archive, allocator, row, true, &snippet_warmup);
            if (std.mem.startsWith(u8, row.label, "snippet")) snippet_ordinal += 1;
        }
    }
    _ = render_warmup.digest.finish();
    _ = snippet_warmup.digest.finish();

    var render_stats = RenderStats.init("measure-render-v1");
    const render_timer = Timer.start(init.io);
    for (0..256) |index| {
        var ordinal: usize = 0;
        for (rows) |row| {
            if (!std.mem.startsWith(u8, row.label, "render")) continue;
            if (ordinal == index % render_count) try consumeRender(&archive, allocator, row, false, &render_stats);
            ordinal += 1;
        }
    }
    try writeRenderStats(&writer.interface, "uncached_render_batch", render_timer.read(), render_stats);

    var snippet_stats = RenderStats.init("measure-snippet-v1");
    const snippet_timer = Timer.start(init.io);
    for (0..256) |index| {
        var ordinal: usize = 0;
        for (rows) |row| {
            if (!std.mem.startsWith(u8, row.label, "snippet")) continue;
            if (ordinal == index % snippet_count) try consumeRender(&archive, allocator, row, true, &snippet_stats);
            ordinal += 1;
        }
    }
    try writeRenderStats(&writer.interface, "uncached_snippet_batch", snippet_timer.read(), snippet_stats);

    // Stateful Reader lanes.  The first operation starts from an empty
    // session and therefore exposes cold first decode/page framing.  The
    // same-page batch then repeats that row to expose cache hits without
    // pretending the first decode was free.  The mixed-page batch cycles the
    // fixed source-order/large-row render plan, forcing real page changes;
    // page-load/decode/cache-hit deltas are emitted with each batch.
    var first_render_row: ?TimedRow = null;
    var first_snippet_row: ?TimedRow = null;
    for (rows) |row| {
        if (first_render_row == null and std.mem.startsWith(u8, row.label, "render")) first_render_row = row;
        if (first_snippet_row == null and std.mem.startsWith(u8, row.label, "snippet")) first_snippet_row = row;
    }
    const cold_row = first_render_row orelse return error.InvalidMeasurePlan;
    const cold_before = reader.stats;
    var cold_stats = RenderStats.init("measure-session-first-cold-v1");
    const cold_timer = Timer.start(init.io);
    try consumeRenderSession(&reader, cold_row, false, &cold_stats);
    try writeSessionFirst(&writer.interface, cold_row, cold_timer.read(), cold_stats, readerStatsDelta(cold_before, reader.stats));

    const same_before = reader.stats;
    var same_stats = RenderStats.init("measure-session-same-page-v1");
    const same_timer = Timer.start(init.io);
    for (0..256) |_| try consumeRenderSession(&reader, cold_row, false, &same_stats);
    try writeSessionStats(&writer.interface, "session_same_page_render", same_timer.read(), same_stats, readerStatsDelta(same_before, reader.stats));

    const mixed_before = reader.stats;
    var mixed_stats = RenderStats.init("measure-session-mixed-page-v1");
    const mixed_timer = Timer.start(init.io);
    for (0..256) |index| {
        var ordinal: usize = 0;
        for (rows) |row| {
            if (!std.mem.startsWith(u8, row.label, "render")) continue;
            if (ordinal == index % render_count) try consumeRenderSession(&reader, row, false, &mixed_stats);
            ordinal += 1;
        }
    }
    try writeSessionStats(&writer.interface, "session_mixed_page_render", mixed_timer.read(), mixed_stats, readerStatsDelta(mixed_before, reader.stats));

    if (first_snippet_row == null) return error.InvalidMeasurePlan;
    const mixed_snippet_before = reader.stats;
    var mixed_snippet_stats = RenderStats.init("measure-session-mixed-page-snippet-v1");
    const mixed_snippet_timer = Timer.start(init.io);
    for (0..256) |index| {
        var ordinal: usize = 0;
        for (rows) |row| {
            if (!std.mem.startsWith(u8, row.label, "snippet")) continue;
            if (ordinal == index % snippet_count) try consumeRenderSession(&reader, row, true, &mixed_snippet_stats);
            ordinal += 1;
        }
    }
    try writeSessionStats(&writer.interface, "session_mixed_page_snippet", mixed_snippet_timer.read(), mixed_snippet_stats, readerStatsDelta(mixed_snippet_before, reader.stats));

    // Full archive verification is a correctness control deliberately placed
    // after all measured query/load/render phases.  It must not warm the page
    // cache or masquerade as a cold first operation/startup cost.
    const verify_timer = Timer.start(init.io);
    try archive.verifyAll(allocator);
    try writer.interface.print("post_verify_all_ns\t{d}\n", .{verify_timer.read()});
    try writer.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    const config = parseConfig(init.minimal.args) catch |err| {
        if (err == error.HelpRequested) return;
        usage();
        return err;
    };
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    if (config.mode == .build) {
        const input_bytes = try readFile(init, allocator, config.input.?);
        const projection = try readProjection(allocator, input_bytes);
        var owned = try buildArchive(init.gpa, &projection, config);
        defer owned.deinit();
        try writeFile(init, config.artifact.?, owned.bytes);
        var output_buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stdout().writer(init.io, &output_buffer);
        try writer.interface.print("status\tbuilt\nentries\t{d}\tpage_target\t{d}\tcompression\t{s}\tbytes\t{d}\n", .{
            projection.entries.len,
            config.target_page_bytes,
            @tagName(config.compression),
            owned.bytes.len,
        });
        try writer.interface.flush();
    } else if (config.mode == .smoke) {
        // Input is deliberately required in smoke mode too: the independent
        // caller may use it for its own oracle comparison, while this reader
        // does not inspect expected values.
        const input_bytes = try readFile(init, allocator, config.input.?);
        const projection = try readProjection(allocator, input_bytes);
        const artifact_bytes = try readFile(init, allocator, config.artifact.?);
        const query_bytes = if (config.queries) |path| try readFile(init, allocator, path) else null;
        try observeSmoke(init, init.gpa, artifact_bytes, projection.entries.len, query_bytes);
    } else if (config.mode == .whole_bzip3) {
        const input_bytes = try readFile(init, allocator, config.input.?);
        const projection = try readProjection(allocator, input_bytes);
        try observeWholeBzip3(init, init.gpa, &projection);
    } else if (config.mode == .measure) {
        const input_timer = Timer.start(init.io);
        const input_bytes = try readFile(init, allocator, config.input.?);
        const input_read_ns = input_timer.read();
        const input_parse_timer = Timer.start(init.io);
        // The input parser is part of fresh-process startup.  It validates
        // the full projection shape but supplies no expected query answers.
        _ = try readProjection(allocator, input_bytes);
        const input_parse_ns = input_parse_timer.read();
        const artifact_timer = Timer.start(init.io);
        const artifact_bytes = try readFile(init, allocator, config.artifact.?);
        const artifact_read_ns = artifact_timer.read();
        const query_bytes = try readFile(init, allocator, config.queries orelse return error.MissingArgument);
        const row_bytes = try readFile(init, allocator, config.rows orelse return error.MissingArgument);
        try observeMeasure(init, init.gpa, artifact_bytes, query_bytes, row_bytes, input_read_ns, input_parse_ns, artifact_read_ns);
    } else {
        const artifact_bytes = try readFile(init, allocator, config.artifact.?);
        try observeDiagnostic(init, init.gpa, artifact_bytes, config.max_page_bytes);
    }
}
