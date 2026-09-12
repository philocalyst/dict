//! Actual src2 benchmark adapter.
//!
//! This file is intentionally owned by bench4.  It builds and reopens the
//! immutable src2 snapshot through src2.Builder/Compiled/Snapshot/Query; it
//! does not alter src2 or the LEX4 implementation.  A small authenticated
//! sidecar carries only durable source identities which src2 deliberately does
//! not put in physical Node IDs.  Graph answers are reconstructed from the
//! compiled assertion forest (and the src2 query/adjacency surfaces), never
//! from copied relation rows.

const std = @import("std");
const lex = @import("src2");
const schema = lex.schema;
const compile = lex.compile;
const keys = lex.keys;
const prose = lex.prose;
const snapshot_mod = lex.snapshot;
const query_mod = lex.query;

const protocol = "LEX4-BENCH/1";
const metadata_magic = "S2BM";
const metadata_version: u16 = 1;
const metadata_header_size: u16 = 92;
const semantic_schema_version: i64 = 1;
const semantic_seed: i64 = 0x4c45583400040001;
const max_input_bytes = 512 * 1024 * 1024;
const max_line_bytes = 4 * 1024 * 1024;
const sentinel: usize = std.math.maxInt(usize);

const Entry = struct {
    id: i64,
    key: []const u8,
    definition: []u8,
    language: []const u8,
};

const Sense = struct {
    id: i64,
    entry: i64,
    language: []const u8,
    concept: ?i64,
    definition: []u8,
};

const Concept = struct {
    id: i64,
    label: []const u8,
    members: []i64,
};

const Relation = struct {
    source: i64,
    predicate: []const u8,
    target: i64,
    asserted_by: []const u8,
    certainty: []const u8,
};

const Semantic = struct {
    fixture: []const u8,
    seed: i64,
    entries: []Entry,
    senses: []Sense,
    concepts: []Concept,
    relations: []Relation,
};

const MetaEntry = struct {
    id: i64,
    key_len: usize,
    definition_len: usize,
};

const MetaSense = struct {
    id: i64,
    entry_rank: usize,
    ordinal: usize,
    node: schema.Node = @enumFromInt(std.math.maxInt(u32)),
};

const Meta = struct {
    bytes: []const u8,
    entries: []MetaEntry,
    senses: []MetaSense,
    artifact_digest: [32]u8,
};

const Config = struct {
    mode: enum { build, verify, server } = .verify,
    fixture: ?[]const u8 = null,
    records: ?usize = null,
    corpus: ?[]const u8 = null,
    semantic_input: ?[]const u8 = null,
    output: ?[]const u8 = null,
    artifact: ?[]const u8 = null,
};

const RelationView = struct {
    source: i64,
    predicate: []const u8,
    target: i64,
    asserted_by: []const u8,
    certainty: []const u8,
};

const ConceptView = struct {
    id: i64,
    label: []const u8,
    members: []i64,
};

const Result = union(enum) {
    ids: []i64,
    interval: struct { lo: i64, hi: i64 },
    select: struct { id: i64, key: []const u8, rank: i64 },
    bytes: []u8,
    members: []i64,
    relations: []RelationView,
    checksum: []const u8,
};

const Store = struct {
    allocator: std.mem.Allocator,
    artifact: []u8,
    metadata_bytes: []u8,
    snapshot: snapshot_mod.Snapshot,
    meta: Meta,
    rank_ids: []i64,
    rank_keys: [][]const u8,
    root_rank_by_node: []usize,
    node_to_sense: []usize,
    entry_first_sense: []usize,
    sense_definitions: []schema.Node,
    sense_definition_nodes: []schema.Node,
    id_to_rank: std.AutoHashMap(i64, u32),
    sense_id_to_index: std.AutoHashMap(i64, u32),
    lookup_nodes: []schema.Node,
    rank_scratch: []schema.Node,
    result_ids: []i64,
    render_output: []u8,
    key_scratch: []u8,
    atom_scratch: []u8,
    decoder: prose.Decoder = .{},
    query_arena: std.heap.ArenaAllocator,

    fn deinit(self: *Store) void {
        self.decoder.deinit();
        self.query_arena.deinit();
    }
};

fn objectField(object: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return object.get(name) orelse error.MissingField;
}

fn integer(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |number| number,
        else => error.ExpectedInteger,
    };
}

fn string(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.ExpectedString,
    };
}

fn array(value: std.json.Value) ![]std.json.Value {
    return switch (value) {
        .array => |items| items.items,
        else => error.ExpectedArray,
    };
}

fn hexDigit(value: u8) ?u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => null,
    };
}

fn decodeHex(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    if (encoded.len % 2 != 0) return error.InvalidHex;
    const bytes = try allocator.alloc(u8, encoded.len / 2);
    errdefer allocator.free(bytes);
    for (bytes, 0..) |*out, index| {
        const hi = hexDigit(encoded[index * 2]) orelse return error.InvalidHex;
        const lo = hexDigit(encoded[index * 2 + 1]) orelse return error.InvalidHex;
        out.* = (hi << 4) | lo;
    }
    return bytes;
}

fn encodeHex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, bytes.len * 2);
    const digits = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        result[index * 2] = digits[byte >> 4];
        result[index * 2 + 1] = digits[byte & 0x0f];
    }
    return result;
}

fn parseSemantic(allocator: std.mem.Allocator, bytes: []const u8) !Semantic {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidInput,
    };
    if (try integer(try objectField(root, "schema")) != semantic_schema_version) return error.UnsupportedSemanticSchema;
    const fixture = try string(try objectField(root, "fixture"));
    const seed = try integer(try objectField(root, "seed"));

    const entry_values = try array(try objectField(root, "entries"));
    const entries = try allocator.alloc(Entry, entry_values.len);
    errdefer allocator.free(entries);
    for (entry_values, 0..) |value, index| {
        const object = switch (value) {
            .object => |item| item,
            else => return error.InvalidInput,
        };
        entries[index] = .{
            .id = try integer(try objectField(object, "id")),
            .key = try string(try objectField(object, "key")),
            .definition = try decodeHex(allocator, try string(try objectField(object, "definition_hex"))),
            .language = try string(try objectField(object, "language")),
        };
    }

    const sense_values = try array(try objectField(root, "senses"));
    const senses = try allocator.alloc(Sense, sense_values.len);
    errdefer allocator.free(senses);
    for (sense_values, 0..) |value, index| {
        const object = switch (value) {
            .object => |item| item,
            else => return error.InvalidInput,
        };
        const concept_value = try objectField(object, "concept");
        senses[index] = .{
            .id = try integer(try objectField(object, "id")),
            .entry = try integer(try objectField(object, "entry")),
            .language = try string(try objectField(object, "language")),
            .concept = if (concept_value == .null) null else try integer(concept_value),
            .definition = try decodeHex(allocator, try string(try objectField(object, "definition_hex"))),
        };
    }

    const concept_values = try array(try objectField(root, "concepts"));
    const concepts = try allocator.alloc(Concept, concept_values.len);
    errdefer allocator.free(concepts);
    for (concept_values, 0..) |value, index| {
        const object = switch (value) {
            .object => |item| item,
            else => return error.InvalidInput,
        };
        const member_values = try array(try objectField(object, "members"));
        const members = try allocator.alloc(i64, member_values.len);
        for (member_values, 0..) |member, member_index| members[member_index] = try integer(member);
        concepts[index] = .{
            .id = try integer(try objectField(object, "id")),
            .label = try string(try objectField(object, "label")),
            .members = members,
        };
    }

    const relation_values = try array(try objectField(root, "relations"));
    const relations = try allocator.alloc(Relation, relation_values.len);
    errdefer allocator.free(relations);
    for (relation_values, 0..) |value, index| {
        const object = switch (value) {
            .object => |item| item,
            else => return error.InvalidInput,
        };
        relations[index] = .{
            .source = try integer(try objectField(object, "source")),
            .predicate = try string(try objectField(object, "predicate")),
            .target = try integer(try objectField(object, "target")),
            .asserted_by = try string(try objectField(object, "asserted_by")),
            .certainty = try string(try objectField(object, "certainty")),
        };
    }
    for (entries, 0..) |entry, index| for (entries[0..index]) |prior| if (entry.id == prior.id) return error.DuplicateEntryId;
    return .{ .fixture = fixture, .seed = seed, .entries = entries, .senses = senses, .concepts = concepts, .relations = relations };
}

fn appendEscapedField(out: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    for (bytes) |byte| switch (byte) {
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        else => try out.append(allocator, byte),
    };
}

fn validateCorpus(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8, semantic: Semantic) !void {
    const actual = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(max_input_bytes));
    var expected = std.ArrayList(u8).empty;
    try expected.appendSlice(allocator, "# fixture=");
    try expected.appendSlice(allocator, semantic.fixture);
    try expected.append(allocator, '\n');
    var seed_buffer: [32]u8 = undefined;
    const seed_text = try std.fmt.bufPrint(&seed_buffer, "{x:0>16}", .{@as(u64, @intCast(semantic.seed))});
    try expected.appendSlice(allocator, "# seed=");
    try expected.appendSlice(allocator, seed_text);
    try expected.append(allocator, '\n');
    var id_buffer: [32]u8 = undefined;
    for (semantic.entries) |entry| {
        const id_text = try std.fmt.bufPrint(&id_buffer, "{d}", .{entry.id});
        try expected.appendSlice(allocator, id_text);
        try expected.append(allocator, '\t');
        try appendEscapedField(&expected, allocator, entry.key);
        try expected.append(allocator, '\t');
        try appendEscapedField(&expected, allocator, entry.definition);
        try expected.append(allocator, '\n');
    }
    if (!std.mem.eql(u8, actual, expected.items)) return error.CorpusMismatch;
}

fn entryLess(_: void, left: Entry, right: Entry) bool {
    return switch (std.mem.order(u8, left.key, right.key)) {
        .lt => true,
        .gt => false,
        .eq => left.id < right.id,
    };
}

fn senseLess(_: void, left: Sense, right: Sense) bool {
    return left.id < right.id;
}

fn conceptLess(_: void, left: Concept, right: Concept) bool {
    return left.id < right.id;
}

fn relationLess(_: void, left: Relation, right: Relation) bool {
    if (left.source != right.source) return left.source < right.source;
    const order = std.mem.order(u8, left.predicate, right.predicate);
    if (order != .eq) return order == .lt;
    return left.target < right.target;
}

fn appendU16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn appendU32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn appendU64(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn appendI64(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i64) !void {
    try appendU64(out, allocator, @bitCast(value));
}

fn appendBlob(out: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try appendU16(out, allocator, std.math.cast(u16, bytes.len) orelse return error.MetadataOverflow);
    try out.appendSlice(allocator, bytes);
}

fn encodeMetadata(allocator: std.mem.Allocator, entries: []const Entry, senses: []const Sense, artifact: []const u8) ![]u8 {
    var entry_rank = std.AutoHashMap(i64, u32).init(allocator);
    defer entry_rank.deinit();
    for (entries, 0..) |entry, rank| try entry_rank.put(entry.id, @intCast(rank));
    var ordinal_by_entry = std.AutoHashMap(i64, u32).init(allocator);
    defer ordinal_by_entry.deinit();
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, metadata_magic);
    try appendU16(&out, allocator, metadata_version);
    try appendU16(&out, allocator, metadata_header_size);
    try appendU32(&out, allocator, std.math.cast(u32, entries.len) orelse return error.MetadataOverflow);
    try appendU32(&out, allocator, std.math.cast(u32, senses.len) orelse return error.MetadataOverflow);
    try appendU64(&out, allocator, 0);
    var artifact_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(artifact, &artifact_digest, .{});
    try out.appendSlice(allocator, &artifact_digest);
    // Bind the identity lane itself as well as binding it to the primary
    // snapshot. Without this second digest, changing a sparse source ID could
    // survive standalone verify even though an oracle-backed run would later
    // notice different answers.
    try out.appendNTimes(allocator, 0, 32);
    try appendU32(&out, allocator, 0);
    for (entries) |entry| {
        try appendI64(&out, allocator, entry.id);
        try appendU32(&out, allocator, std.math.cast(u32, entry.key.len) orelse return error.MetadataOverflow);
        try appendU32(&out, allocator, std.math.cast(u32, entry.definition.len) orelse return error.MetadataOverflow);
    }
    for (senses) |sense| {
        const rank = entry_rank.get(sense.entry) orelse return error.InvalidSense;
        const ordinal = ordinal_by_entry.get(sense.entry) orelse 0;
        try ordinal_by_entry.put(sense.entry, ordinal + 1);
        try appendI64(&out, allocator, sense.id);
        try appendU32(&out, allocator, rank);
        try appendU32(&out, allocator, ordinal);
    }
    if (out.items.len > std.math.maxInt(u64)) return error.MetadataOverflow;
    std.mem.writeInt(u64, out.items[16..24], out.items.len, .little);
    var metadata_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(out.items[metadata_header_size..], &metadata_digest, .{});
    @memcpy(out.items[56..88], &metadata_digest);
    return out.toOwnedSlice(allocator);
}

fn readU16(bytes: []const u8, cursor: *usize) !u16 {
    if (cursor.* > bytes.len or bytes.len - cursor.* < 2) return error.InvalidMetadata;
    const value = std.mem.readInt(u16, bytes[cursor.*..][0..2], .little);
    cursor.* += 2;
    return value;
}

fn readU32(bytes: []const u8, cursor: *usize) !u32 {
    if (cursor.* > bytes.len or bytes.len - cursor.* < 4) return error.InvalidMetadata;
    const value = std.mem.readInt(u32, bytes[cursor.*..][0..4], .little);
    cursor.* += 4;
    return value;
}

fn readU64(bytes: []const u8, cursor: *usize) !u64 {
    if (cursor.* > bytes.len or bytes.len - cursor.* < 8) return error.InvalidMetadata;
    const value = std.mem.readInt(u64, bytes[cursor.*..][0..8], .little);
    cursor.* += 8;
    return value;
}

fn readI64(bytes: []const u8, cursor: *usize) !i64 {
    return @bitCast(try readU64(bytes, cursor));
}

fn readBlob(bytes: []const u8, cursor: *usize) ![]const u8 {
    const len = try readU16(bytes, cursor);
    if (cursor.* > bytes.len or bytes.len - cursor.* < len) return error.InvalidMetadata;
    const value = bytes[cursor.*..][0..len];
    cursor.* += len;
    return value;
}

fn parseMetadata(allocator: std.mem.Allocator, bytes: []u8) !Meta {
    if (bytes.len < metadata_header_size or !std.mem.eql(u8, bytes[0..4], metadata_magic)) return error.InvalidMetadata;
    var cursor: usize = 4;
    if (try readU16(bytes, &cursor) != metadata_version or try readU16(bytes, &cursor) != metadata_header_size) return error.InvalidMetadata;
    const entry_count = try readU32(bytes, &cursor);
    const sense_count = try readU32(bytes, &cursor);
    const total_length = try readU64(bytes, &cursor);
    if (total_length != bytes.len or bytes.len - cursor < 32) return error.InvalidMetadata;
    const artifact_digest_slice = bytes[cursor..][0..32];
    var artifact_digest: [32]u8 = undefined;
    @memcpy(&artifact_digest, artifact_digest_slice);
    cursor += 32;
    if (bytes.len - cursor < 32) return error.InvalidMetadata;
    const expected_metadata_digest = bytes[cursor..][0..32];
    cursor += 32;
    if (try readU32(bytes, &cursor) != 0) return error.InvalidMetadata;
    var actual_metadata_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[metadata_header_size..], &actual_metadata_digest, .{});
    if (!std.mem.eql(u8, expected_metadata_digest, &actual_metadata_digest)) return error.InvalidMetadataDigest;
    const entries = try allocator.alloc(MetaEntry, entry_count);
    errdefer allocator.free(entries);
    for (entries) |*entry| {
        entry.* = .{ .id = try readI64(bytes, &cursor), .key_len = try readU32(bytes, &cursor), .definition_len = try readU32(bytes, &cursor) };
    }
    const senses = try allocator.alloc(MetaSense, sense_count);
    errdefer allocator.free(senses);
    for (senses) |*sense| {
        const id = try readI64(bytes, &cursor);
        const entry_rank = try readU32(bytes, &cursor);
        const ordinal = try readU32(bytes, &cursor);
        if (entry_rank >= entry_count) return error.InvalidMetadata;
        sense.* = .{ .id = id, .entry_rank = entry_rank, .ordinal = ordinal };
    }
    if (cursor != bytes.len) return error.InvalidMetadata;
    return .{ .bytes = bytes, .entries = entries, .senses = senses, .artifact_digest = artifact_digest };
}

fn rankOfEntry(entries: []const Entry, id: i64) ?usize {
    for (entries, 0..) |entry, rank| if (entry.id == id) return rank;
    return null;
}

fn writeAtomic(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    var file = try std.Io.Dir.cwd().createFile(init.io, temporary, .{ .truncate = true, .exclusive = true });
    defer file.close(init.io);
    var buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try std.Io.Dir.rename(.cwd(), temporary, .cwd(), path, init.io);
}

fn sidecarPath(allocator: std.mem.Allocator, artifact: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.src2meta", .{artifact});
}

fn findSenseIndex(senses: []const Sense, id: i64) ?usize {
    for (senses, 0..) |sense, index| if (sense.id == id) return index;
    return null;
}

fn certaintyState(value: []const u8) struct { state: schema.AssertionState, certainty: ?schema.Certainty } {
    if (std.mem.eql(u8, value, "disputed")) return .{ .state = .disputed, .certainty = null };
    if (std.mem.eql(u8, value, "candidate")) return .{ .state = .asserted, .certainty = .possible };
    if (std.mem.eql(u8, value, "probable")) return .{ .state = .asserted, .certainty = .probable };
    if (std.mem.eql(u8, value, "certain")) return .{ .state = .asserted, .certainty = .certain };
    return .{ .state = .asserted, .certainty = null };
}

fn addAssertion(
    allocator: std.mem.Allocator,
    builder: *compile.Builder,
    relation: Relation,
    source_sense: schema.Ref(.sense),
    target_sense: schema.Ref(.sense),
    source_entry: schema.Ref(.entry),
    target_entry: schema.Ref(.entry),
    source_node: schema.Ref(.extension),
) !void {
    const state = certaintyState(relation.certainty);
    const options = compile.AssertionOptions{ .state = state.state, .certainty = state.certainty, .source = source_node.any() };
    if (std.mem.eql(u8, relation.predicate, "translation")) {
        _ = try builder.assertion(schema.predicates.translation, source_sense, .{
            .{ .role = .source, .target = compile.Target{ .node = source_sense.any() } },
            .{ .role = .target, .target = compile.Target{ .node = target_sense.any() } },
        }, options);
    } else {
        // Keep fixture predicates in the extension namespace.  In particular,
        // src2's checked see_also predicate is entry-shaped while the fixture
        // relation IDs are sense-shaped; a prefixed runtime predicate avoids
        // silently coercing one kind policy into the other.
        _ = source_entry;
        _ = target_entry;
        const runtime_name = try std.fmt.allocPrint(allocator, "relation:{s}", .{relation.predicate});
        defer allocator.free(runtime_name);
        _ = try builder.runtimeAssertion(runtime_name, source_sense, .{
            .{ .role = "source", .target = compile.Target{ .node = source_sense.any() } },
            .{ .role = "target", .target = compile.Target{ .node = target_sense.any() } },
        }, options);
    }
}

fn buildArtifact(init: std.process.Init, allocator: std.mem.Allocator, config: Config) !void {
    const fixture_name = config.fixture orelse return error.MissingFixture;
    const semantic_path = config.semantic_input orelse return error.MissingSemanticInput;
    const output_path = config.output orelse return error.MissingOutput;
    const semantic_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, semantic_path, allocator, .limited(max_input_bytes));
    const semantic = try parseSemantic(allocator, semantic_bytes);
    if (!std.mem.eql(u8, fixture_name, semantic.fixture)) return error.FixtureMismatch;
    if (semantic.seed != semantic_seed) return error.SeedMismatch;
    if (config.records) |records| if (records != semantic.entries.len) return error.RecordCountMismatch;
    try validateCorpus(init, allocator, config.corpus orelse return error.MissingCorpus, semantic);
    std.mem.sort(Entry, semantic.entries, {}, entryLess);
    std.mem.sort(Sense, semantic.senses, {}, senseLess);
    std.mem.sort(Concept, semantic.concepts, {}, conceptLess);
    std.mem.sort(Relation, semantic.relations, {}, relationLess);

    var builder = compile.Builder.init(allocator);
    defer builder.deinit();
    var entry_refs = try allocator.alloc(schema.Ref(.entry), semantic.entries.len);
    var entry_ref_by_id = std.AutoHashMap(i64, schema.Ref(.entry)).init(allocator);
    var sense_ref_by_id = std.AutoHashMap(i64, schema.Ref(.sense)).init(allocator);
    var sense_entry_by_id = std.AutoHashMap(i64, i64).init(allocator);
    for (semantic.entries, 0..) |entry, rank| {
        const entry_ref = try builder.root(.entry, .{ .headword = entry.key, .lang = entry.language });
        entry_refs[rank] = entry_ref;
        try entry_ref_by_id.put(entry.id, entry_ref);
        var found = false;
        for (semantic.senses) |sense| if (sense.entry == entry.id) {
            found = true;
            const sense_ref = try builder.child(entry_ref, .sense, .{ .lang = sense.language });
            const definition = try builder.child(sense_ref, .definition, .{ .text = sense.definition });
            _ = definition;
            try sense_ref_by_id.put(sense.id, sense_ref);
            try sense_entry_by_id.put(sense.id, entry.id);
        };
        if (!found) {
            const sense_ref = try builder.child(entry_ref, .sense, .{ .lang = entry.language });
            _ = try builder.child(sense_ref, .definition, .{ .text = entry.definition });
        }
    }

    var source_names = std.ArrayList([]const u8).empty;
    for (semantic.relations) |relation| {
        var found = false;
        for (source_names.items) |name| {
            if (std.mem.eql(u8, name, relation.asserted_by)) found = true;
        }
        if (!found) try source_names.append(allocator, relation.asserted_by);
    }
    var source_refs = std.StringHashMap(schema.Ref(.extension)).init(allocator);
    for (source_names.items) |name| {
        const qname = try std.fmt.allocPrint(allocator, "source:{s}", .{name});
        try source_refs.put(name, try builder.root(.extension, .{ .qname = qname }));
    }
    var concept_refs = std.AutoHashMap(i64, schema.Ref(.extension)).init(allocator);
    for (semantic.concepts) |concept| {
        const qname = try std.fmt.allocPrint(allocator, "concept:{d}:{s}", .{ concept.id, concept.label });
        try concept_refs.put(concept.id, try builder.root(.extension, .{ .qname = qname }));
    }
    for (semantic.concepts) |concept| for (concept.members) |member_id| {
        const member = sense_ref_by_id.get(member_id) orelse return error.InvalidConcept;
        const target = concept_refs.get(concept.id) orelse return error.InvalidConcept;
        _ = try builder.runtimeAssertion("concept_membership", member, .{
            .{ .role = "source", .target = compile.Target{ .node = member.any() } },
            .{ .role = "target", .target = compile.Target{ .node = target.any() } },
        }, .{});
    };
    for (semantic.relations) |relation| {
        const source_sense = sense_ref_by_id.get(relation.source) orelse return error.InvalidRelation;
        const target_sense = sense_ref_by_id.get(relation.target) orelse return error.InvalidRelation;
        const source_entry_id = sense_entry_by_id.get(relation.source) orelse return error.InvalidRelation;
        const target_entry_id = sense_entry_by_id.get(relation.target) orelse return error.InvalidRelation;
        const source_entry = entry_ref_by_id.get(source_entry_id) orelse return error.InvalidRelation;
        const target_entry = entry_ref_by_id.get(target_entry_id) orelse return error.InvalidRelation;
        const source_node = source_refs.get(relation.asserted_by) orelse return error.InvalidRelation;
        try addAssertion(allocator, &builder, relation, source_sense, target_sense, source_entry, target_entry, source_node);
    }
    var compiled = try builder.compile();
    defer compiled.deinit();
    if (compiled.bytes.len == 0) return error.EmptyArtifact;
    const metadata = try encodeMetadata(allocator, semantic.entries, semantic.senses, compiled.bytes);
    const metadata_file = try sidecarPath(allocator, output_path);
    try writeAtomic(init, allocator, output_path, compiled.bytes);
    try writeAtomic(init, allocator, metadata_file, metadata);
}

fn rootRank(store: *const Store, node: schema.Node) ?usize {
    const index = @intFromEnum(node);
    if (index >= store.root_rank_by_node.len) return null;
    return if (store.root_rank_by_node[index] == sentinel) null else store.root_rank_by_node[index];
}

fn rankForId(store: *const Store, id: i64) ?usize {
    return if (store.id_to_rank.get(id)) |rank| @intCast(rank) else null;
}

fn senseIndexForId(store: *const Store, id: i64) ?usize {
    return if (store.sense_id_to_index.get(id)) |index| @intCast(index) else null;
}

fn senseIdForNode(store: *const Store, node: schema.Node) ?i64 {
    const index = @intFromEnum(node);
    if (index < store.node_to_sense.len and store.node_to_sense[index] != sentinel)
        return store.meta.senses[store.node_to_sense[index]].id;
    const rank = rootRank(store, node) orelse return null;
    if (rank >= store.entry_first_sense.len or store.entry_first_sense[rank] == sentinel) return null;
    return store.meta.senses[store.entry_first_sense[rank]].id;
}

fn senseNodeForId(store: *const Store, id: i64) ?schema.Node {
    const index = senseIndexForId(store, id) orelse return null;
    return store.meta.senses[index].node;
}

fn entryIdForNode(store: *const Store, node: schema.Node) ?i64 {
    const rank = rootRank(store, node) orelse return null;
    return if (rank < store.rank_ids.len) store.rank_ids[rank] else null;
}

fn atomText(store: *Store, atom: schema.Atom) ![]const u8 {
    const atoms = try store.snapshot.keySpace(.atoms);
    const hit = (try atoms.ordinal(@intFromEnum(atom), store.atom_scratch)) orelse return error.InvalidAtom;
    // `keys.View` borrows the caller's scratch buffer. Copy spellings before
    // retaining them in an operation result, otherwise later atom lookups
    // overwrite relation predicates and source names.
    return store.query_arena.allocator().dupe(u8, hit.key);
}

fn assertionPredicate(store: *Store, assertion: schema.Node) ![]const u8 {
    const atom = (try store.snapshot.get(schema.columns.predicate, assertion)) orelse return error.InvalidAssertion;
    return atomText(store, atom);
}

fn publicPredicate(store: *Store, assertion: schema.Node) ![]const u8 {
    const raw = try assertionPredicate(store, assertion);
    return if (std.mem.startsWith(u8, raw, "relation:")) raw["relation:".len..] else raw;
}

const Participants = struct { source: ?schema.Node = null, target: ?schema.Node = null };

fn assertionParticipants(store: *Store, assertion: schema.Node) !Participants {
    const forest = try store.snapshot.forest();
    var result = Participants{};
    var child = try forest.firstChild(assertion);
    while (child) |participant| : (child = try forest.nextSibling(participant)) {
        if (try forest.kind(participant) != .participant) continue;
        const role_atom = (try store.snapshot.get(schema.columns.role, participant)) orelse continue;
        const role = try atomText(store, role_atom);
        const target = (try store.snapshot.get(schema.columns.target, participant)) orelse continue;
        if (std.mem.eql(u8, role, "source")) result.source = target else if (std.mem.eql(u8, role, "target")) result.target = target;
    }
    return result;
}

fn qnameText(store: *Store, node: schema.Node) ![]const u8 {
    const atom = (try store.snapshot.get(schema.columns.qname, node)) orelse return error.InvalidQName;
    return atomText(store, atom);
}

fn languageForSense(store: *Store, node: schema.Node) ![]const u8 {
    const atom = (try store.snapshot.get(schema.columns.lang, node)) orelse return error.InvalidSense;
    return atomText(store, atom);
}

fn conceptFromNode(store: *Store, node: schema.Node) !struct { id: i64, label: []const u8 } {
    const text = try qnameText(store, node);
    if (!std.mem.startsWith(u8, text, "concept:")) return error.InvalidConcept;
    const rest = text["concept:".len..];
    const split = std.mem.indexOfScalar(u8, rest, ':') orelse return error.InvalidConcept;
    return .{ .id = try std.fmt.parseInt(i64, rest[0..split], 10), .label = rest[split + 1 ..] };
}

fn conceptForSense(store: *Store, sense_node: schema.Node) !?i64 {
    const assertions = try allAssertions(store);
    for (assertions) |assertion| {
        if (!std.mem.eql(u8, try assertionPredicate(store, assertion), "concept_membership")) continue;
        const participants = try assertionParticipants(store, assertion);
        if (participants.source orelse continue != sense_node) continue;
        const target = participants.target orelse continue;
        return (try conceptFromNode(store, target)).id;
    }
    return null;
}

fn allAssertions(store: *Store) ![]const schema.Node {
    var query = query_mod.Query.init(&store.snapshot, &store.query_arena, .{ .max_visited = 10_000_000, .max_blocks = 16, .allow_scan = true });
    defer query.deinit();
    return (try query.all(.assertion).run()).items;
}

fn idsForNodes(store: *Store, nodes: []const schema.Node) ![]i64 {
    var count: usize = 0;
    for (nodes) |node| {
        if (rootRank(store, node) != null) count += 1;
    }
    if (count > store.result_ids.len) return error.BufferTooSmall;
    var ranks = store.rank_scratch[0..count];
    var cursor: usize = 0;
    for (nodes) |node| if (rootRank(store, node)) |rank| {
        ranks[cursor] = @enumFromInt(@as(u32, @intCast(rank)));
        cursor += 1;
    };
    std.mem.sort(schema.Node, ranks, {}, struct {
        fn less(_: void, left: schema.Node, right: schema.Node) bool {
            return @intFromEnum(left) < @intFromEnum(right);
        }
    }.less);
    var written: usize = 0;
    var previous: ?schema.Node = null;
    for (ranks) |rank_node| {
        if (previous != null and previous.? == rank_node) continue;
        previous = rank_node;
        const rank = @intFromEnum(rank_node);
        store.result_ids[written] = store.rank_ids[rank];
        written += 1;
    }
    return store.result_ids[0..written];
}

fn lookup(store: *Store, key: []const u8, mode: query_mod.Mode) ![]i64 {
    var query = query_mod.Query.init(&store.snapshot, &store.query_arena, .{ .max_visited = 10_000_000, .allow_scan = false });
    defer query.deinit();
    const set = try query.lookup(.headword, key, mode, store.key_scratch, store.lookup_nodes);
    return idsForNodes(store, set.items);
}

fn compareKey(left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

fn prefixUpper(allocator: std.mem.Allocator, prefix: []const u8) !?[]u8 {
    if (prefix.len == 0) return null;
    const value = try allocator.dupe(u8, prefix);
    var index = value.len;
    while (index != 0 and value[index - 1] == 0xff) : (index -= 1) {}
    if (index == 0) return null;
    value[index - 1] += 1;
    return value[0..index];
}

fn lowerBoundKeys(store: *const Store, needle: []const u8) usize {
    var low: usize = 0;
    var high = store.rank_keys.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (compareKey(store.rank_keys[middle], needle) == .lt) low = middle + 1 else high = middle;
    }
    return low;
}

fn prefixInterval(store: *Store, prefix: []const u8) !Result {
    // Ask the actual src2 prefix index for the matching physical roots, then
    // project those roots back to canonical entry ranks.  The rank-key bounds
    // are only used to validate contiguity; they are not the source of the
    // answer.
    var query = query_mod.Query.init(&store.snapshot, &store.query_arena, .{ .max_visited = 10_000_000, .allow_scan = false });
    defer query.deinit();
    const set = try query.lookup(.headword, prefix, .prefix, store.key_scratch, store.lookup_nodes);
    var lo = store.rank_keys.len;
    var hi: usize = 0;
    var count: usize = 0;
    for (set.items) |node| if (rootRank(store, node)) |rank| {
        lo = @min(lo, rank);
        hi = @max(hi, rank + 1);
        count += 1;
    };
    if (count == 0) {
        const insertion = lowerBoundKeys(store, prefix);
        return .{ .interval = .{ .lo = @intCast(insertion), .hi = @intCast(insertion) } };
    }
    if (hi - lo != count) return error.NonContiguousPrefix;
    for (store.rank_keys[lo..hi]) |key| if (!std.mem.startsWith(u8, key, prefix)) return error.InvalidPrefixIndex;
    return .{ .interval = .{ .lo = @intCast(lo), .hi = @intCast(hi) } };
}

fn select(store: *Store, rank: usize) !Result {
    if (rank >= store.rank_ids.len) return error.RankOutOfRange;
    return .{ .select = .{ .id = store.rank_ids[rank], .key = store.rank_keys[rank], .rank = @intCast(rank) } };
}

fn renderNode(store: *Store, node: schema.Node, limit: ?usize) ![]u8 {
    var text_store = try store.snapshot.prose(.{});
    const block = text_store.blockForNode(@intFromEnum(node)) orelse return error.MissingDefinition;
    var pin = try text_store.pinUsing(store.query_arena.allocator(), block, &store.decoder);
    defer pin.deinit();
    const item = (try pin.itemForNode(@intFromEnum(node))) orelse return error.MissingDefinition;
    const requested = if (limit) |value| @min(value, item.text.len) else item.text.len;
    if (requested > store.render_output.len) return error.BufferTooSmall;
    @memcpy(store.render_output[0..requested], item.text[0..requested]);
    return store.render_output[0..requested];
}

fn renderAt(store: *Store, id: i64, limit: ?usize) !Result {
    const rank = rankForId(store, id) orelse return error.UnknownEntry;
    return .{ .bytes = try renderNode(store, store.sense_definitions[rank], limit) };
}

fn relationCertainty(store: *Store, assertion: schema.Node) ![]const u8 {
    const state = (try store.snapshot.get(schema.columns.state, assertion)) orelse .asserted;
    switch (state) {
        .disputed => return "disputed",
        .inferred => return "inferred",
        .retracted => return "retracted",
        .asserted => {},
    }
    const certainty = (try store.snapshot.get(schema.columns.certainty, assertion)) orelse .unknown;
    return switch (certainty) {
        .possible => "candidate",
        .probable => "probable",
        .certain => "certain",
        .unknown => "asserted",
    };
}

fn relationSource(store: *Store, assertion: schema.Node) ![]const u8 {
    const source = (try store.snapshot.get(schema.columns.source, assertion)) orelse return "fixture-source";
    const qname = try qnameText(store, source);
    if (std.mem.startsWith(u8, qname, "source:")) return qname["source:".len..];
    return qname;
}

fn relationRows(store: *Store, source_id: ?i64, wanted: []const u8) ![]RelationView {
    const assertions = try allAssertions(store);
    var rows = std.ArrayList(RelationView).empty;
    const request_allocator = store.query_arena.allocator();
    for (assertions) |assertion| {
        const predicate = try publicPredicate(store, assertion);
        if (std.mem.eql(u8, predicate, "concept_membership") or (wanted.len != 0 and !std.mem.eql(u8, predicate, wanted))) continue;
        const participants = try assertionParticipants(store, assertion);
        const source_node = participants.source orelse continue;
        const target_node = participants.target orelse continue;
        const source = senseIdForNode(store, source_node) orelse continue;
        const target = senseIdForNode(store, target_node) orelse continue;
        if (source_id) |wanted_source| if (source != wanted_source) continue;
        try rows.append(request_allocator, .{ .source = source, .predicate = predicate, .target = target, .asserted_by = try relationSource(store, assertion), .certainty = try relationCertainty(store, assertion) });
    }
    std.mem.sort(RelationView, rows.items, {}, struct {
        fn less(_: void, left: RelationView, right: RelationView) bool {
            if (left.source != right.source) return left.source < right.source;
            const order = std.mem.order(u8, left.predicate, right.predicate);
            if (order != .eq) return order == .lt;
            return left.target < right.target;
        }
    }.less);
    return rows.toOwnedSlice(request_allocator);
}

fn conceptMembers(store: *Store, id: i64) ![]i64 {
    const assertions = try allAssertions(store);
    var values = std.ArrayList(i64).empty;
    const request_allocator = store.query_arena.allocator();
    for (assertions) |assertion| {
        if (!std.mem.eql(u8, try assertionPredicate(store, assertion), "concept_membership")) continue;
        const participants = try assertionParticipants(store, assertion);
        const source = participants.source orelse continue;
        const target = participants.target orelse continue;
        const concept = conceptFromNode(store, target) catch continue;
        if (concept.id != id) continue;
        if (senseIdForNode(store, source)) |sense_id| try values.append(request_allocator, sense_id);
    }
    std.mem.sort(i64, values.items, {}, std.sort.asc(i64));
    return values.toOwnedSlice(request_allocator);
}

fn translations(store: *Store, id: i64, language: []const u8) ![]i64 {
    const request_allocator = store.query_arena.allocator();
    const source_index = senseIndexForId(store, id) orelse return request_allocator.alloc(i64, 0);
    const source_node = store.meta.senses[source_index].node;
    const assertions = try allAssertions(store);
    var concepts = std.ArrayList(i64).empty;
    for (assertions) |assertion| {
        if (!std.mem.eql(u8, try assertionPredicate(store, assertion), "concept_membership")) continue;
        const participants = try assertionParticipants(store, assertion);
        if (participants.source orelse continue != source_node) continue;
        const concept = conceptFromNode(store, participants.target orelse continue) catch continue;
        try concepts.append(request_allocator, concept.id);
    }
    var values = std.ArrayList(i64).empty;
    for (assertions) |assertion| {
        if (!std.mem.eql(u8, try assertionPredicate(store, assertion), "concept_membership")) continue;
        const participants = try assertionParticipants(store, assertion);
        const member = participants.source orelse continue;
        const concept = conceptFromNode(store, participants.target orelse continue) catch continue;
        var wanted = false;
        for (concepts.items) |candidate| {
            if (candidate == concept.id) wanted = true;
        }
        if (!wanted) continue;
        const member_id = senseIdForNode(store, member) orelse continue;
        if (member_id == id) continue;
        const member_node = senseNodeForId(store, member_id) orelse continue;
        const member_language = try languageForSense(store, member_node);
        if (language.len == 0 or std.mem.eql(u8, member_language, language)) try values.append(request_allocator, member_id);
    }
    std.mem.sort(i64, values.items, {}, std.sort.asc(i64));
    return values.toOwnedSlice(request_allocator);
}

fn structureChecksum(store: *Store) ![]const u8 {
    const request_allocator = store.query_arena.allocator();
    var output: std.Io.Writer.Allocating = .init(request_allocator);
    var json = std.json.Stringify{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("concepts");
    try json.beginArray();
    const assertions = try allAssertions(store);
    var concepts = std.ArrayList(ConceptView).empty;
    for (assertions) |assertion| {
        if (!std.mem.eql(u8, try assertionPredicate(store, assertion), "concept_membership")) continue;
        const target = (try assertionParticipants(store, assertion)).target orelse continue;
        const concept = conceptFromNode(store, target) catch continue;
        var found = false;
        for (concepts.items) |item| {
            if (item.id == concept.id) found = true;
        }
        if (!found) try concepts.append(request_allocator, .{ .id = concept.id, .label = concept.label, .members = try conceptMembers(store, concept.id) });
    }
    std.mem.sort(ConceptView, concepts.items, {}, struct {
        fn less(_: void, left: ConceptView, right: ConceptView) bool {
            return left.id < right.id;
        }
    }.less);
    for (concepts.items) |concept| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(concept.id);
        try json.objectField("label");
        try json.write(concept.label);
        try json.objectField("members");
        try json.write(concept.members);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("ranked");
    try json.beginArray();
    for (store.rank_ids, 0..) |id, rank| {
        try json.beginArray();
        try json.write(id);
        try json.write(store.rank_keys[rank]);
        try json.endArray();
    }
    try json.endArray();
    try json.objectField("relations");
    try json.beginArray();
    const relations = try relationRows(store, null, "");
    for (relations) |relation| {
        try json.beginObject();
        try json.objectField("asserted_by");
        try json.write(relation.asserted_by);
        try json.objectField("certainty");
        try json.write(relation.certainty);
        try json.objectField("predicate");
        try json.write(relation.predicate);
        try json.objectField("source");
        try json.write(relation.source);
        try json.objectField("target");
        try json.write(relation.target);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("senses");
    try json.beginArray();
    const senses = try request_allocator.alloc(MetaSense, store.meta.senses.len);
    @memcpy(senses, store.meta.senses);
    std.mem.sort(MetaSense, senses, {}, struct {
        fn less(_: void, left: MetaSense, right: MetaSense) bool {
            return left.id < right.id;
        }
    }.less);
    for (senses) |sense| {
        const metadata_index = for (store.meta.senses, 0..) |candidate, index| {
            if (candidate.id == sense.id) break index;
        } else return error.InvalidSense;
        const sense_node = store.sense_definition_nodes[metadata_index];
        const rendered = try renderNode(store, sense_node, null);
        const encoded = try encodeHex(request_allocator, rendered);
        const concept = try conceptForSense(store, sense.node);
        const language = try languageForSense(store, sense.node);
        try json.beginObject();
        try json.objectField("concept");
        if (concept) |value| try json.write(value) else try json.write(null);
        try json.objectField("definition_hex");
        try json.write(encoded);
        try json.objectField("entry");
        try json.write(store.rank_ids[sense.entry_rank]);
        try json.objectField("id");
        try json.write(sense.id);
        try json.objectField("language");
        try json.write(language);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try output.writer.writeByte('\n');
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(output.written(), &digest, .{});
    return encodeHex(request_allocator, &digest);
}

fn loadStore(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8) !Store {
    const artifact = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(max_input_bytes));
    const metadata_file = try sidecarPath(allocator, path);
    const metadata_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, metadata_file, allocator, .limited(max_input_bytes));
    const metadata = try parseMetadata(allocator, metadata_bytes);
    var artifact_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(artifact, &artifact_digest, .{});
    if (!std.mem.eql(u8, &artifact_digest, &metadata.artifact_digest)) return error.MetadataArtifactMismatch;
    const snapshot = try snapshot_mod.Snapshot.open(artifact, .{});
    try snapshot.validateDeep(allocator);
    const forest = try snapshot.forest();
    if (try forest.countKinds(schema.kinds(.{.entry})) != metadata.entries.len) return error.CrossSectionMismatch;
    var rank_ids = try allocator.alloc(i64, metadata.entries.len);
    var id_to_rank = std.AutoHashMap(i64, u32).init(allocator);
    for (metadata.entries, 0..) |entry, rank| {
        rank_ids[rank] = entry.id;
        try id_to_rank.put(entry.id, @intCast(rank));
    }
    var root_rank_by_node = try allocator.alloc(usize, forest.count);
    @memset(root_rank_by_node, sentinel);
    var entry_first_sense = try allocator.alloc(usize, metadata.entries.len);
    @memset(entry_first_sense, sentinel);
    var sense_definitions = try allocator.alloc(schema.Node, metadata.entries.len);
    var sense_definition_nodes = try allocator.alloc(schema.Node, metadata.senses.len);
    @memset(sense_definition_nodes, @enumFromInt(std.math.maxInt(u32)));
    var node_to_sense = try allocator.alloc(usize, forest.count);
    @memset(node_to_sense, sentinel);
    var sense_id_to_index = std.AutoHashMap(i64, u32).init(allocator);
    for (metadata.entries, 0..) |_, rank| {
        const root = (try forest.rootAt(rank)) orelse return error.CrossSectionMismatch;
        if (try forest.kind(root) != .entry) return error.CrossSectionMismatch;
        root_rank_by_node[@intFromEnum(root)] = rank;
        var child = try forest.firstChild(root);
        var first_def: ?schema.Node = null;
        var ordinal: usize = 0;
        while (child) |candidate| : (child = try forest.nextSibling(candidate)) {
            if (try forest.kind(candidate) != .sense) continue;
            var sense_match: ?usize = null;
            for (metadata.senses, 0..) |*sense, index| if (sense.entry_rank == rank and sense.ordinal == ordinal) {
                sense.node = candidate;
                sense_match = index;
                node_to_sense[@intFromEnum(candidate)] = index;
                try sense_id_to_index.put(sense.id, @intCast(index));
            };
            var definition = try forest.firstChild(candidate);
            while (definition) |def| : (definition = try forest.nextSibling(def)) if (try forest.kind(def) == .definition) {
                if (sense_match) |index| {
                    sense_definitions[rank] = def;
                    sense_definition_nodes[index] = def;
                    if (entry_first_sense[rank] == sentinel) entry_first_sense[rank] = index;
                }
                if (first_def == null) first_def = def;
                break;
            };
            ordinal += 1;
        }
        if (first_def == null) return error.MissingDefinition;
        if (entry_first_sense[rank] == sentinel) {
            entry_first_sense[rank] = sentinel;
            sense_definitions[rank] = first_def.?;
        }
    }
    for (metadata.senses) |sense| if (sense.node == @as(schema.Node, @enumFromInt(std.math.maxInt(u32)))) return error.CrossSectionMismatch;
    for (sense_definition_nodes) |node| if (node == @as(schema.Node, @enumFromInt(std.math.maxInt(u32)))) return error.CrossSectionMismatch;
    const key_scratch = try allocator.alloc(u8, keys.max_key_bytes);
    const atom_scratch = try allocator.alloc(u8, keys.max_key_bytes);
    var rank_keys = try allocator.alloc([]const u8, metadata.entries.len);
    for (rank_keys) |*key| key.* = &.{};
    const headwords = try snapshot.keySpace(.headword);
    var headword_iterator = headwords.all(key_scratch);
    while (try headword_iterator.next()) |hit| {
        var postings = try headwords.postingIterator(hit);
        while (try postings.next()) |raw_node| {
            const physical = std.math.cast(usize, raw_node) orelse return error.CrossSectionMismatch;
            if (physical >= root_rank_by_node.len or root_rank_by_node[physical] == sentinel) return error.CrossSectionMismatch;
            const rank = root_rank_by_node[physical];
            if (rank >= rank_keys.len or rank_keys[rank].len != 0) return error.CrossSectionMismatch;
            rank_keys[rank] = try allocator.dupe(u8, hit.key);
            if (rank_keys[rank].len != metadata.entries[rank].key_len) return error.CrossSectionMismatch;
        }
    }
    for (rank_keys) |key| if (key.len == 0 and metadata.entries.len != 0) return error.CrossSectionMismatch;
    const lookup_nodes = try allocator.alloc(schema.Node, @max(@as(usize, 1), forest.count));
    const rank_scratch = try allocator.alloc(schema.Node, @max(@as(usize, 1), metadata.entries.len));
    const result_ids = try allocator.alloc(i64, @max(@as(usize, 1), metadata.entries.len));
    var max_definition: usize = 1;
    for (metadata.entries) |entry| max_definition = @max(max_definition, entry.definition_len);
    for (metadata.senses) |sense| {
        const entry = metadata.entries[sense.entry_rank];
        max_definition = @max(max_definition, entry.definition_len);
    }
    const render_output = try allocator.alloc(u8, max_definition);
    const query_arena = std.heap.ArenaAllocator.init(allocator);
    return .{
        .allocator = allocator,
        .artifact = artifact,
        .metadata_bytes = metadata_bytes,
        .snapshot = snapshot,
        .meta = metadata,
        .rank_ids = rank_ids,
        .rank_keys = rank_keys,
        .root_rank_by_node = root_rank_by_node,
        .node_to_sense = node_to_sense,
        .entry_first_sense = entry_first_sense,
        .sense_definitions = sense_definitions,
        .sense_definition_nodes = sense_definition_nodes,
        .id_to_rank = id_to_rank,
        .sense_id_to_index = sense_id_to_index,
        .lookup_nodes = lookup_nodes,
        .rank_scratch = rank_scratch,
        .result_ids = result_ids,
        .render_output = render_output,
        .key_scratch = key_scratch,
        .atom_scratch = atom_scratch,
        .query_arena = query_arena,
    };
}

fn writeResult(json: *std.json.Stringify, allocator: std.mem.Allocator, result: Result) !void {
    switch (result) {
        .ids => |ids| {
            try json.beginObject();
            try json.objectField("ids");
            try json.write(ids);
            try json.endObject();
        },
        .interval => |value| {
            try json.beginObject();
            try json.objectField("lo");
            try json.write(value.lo);
            try json.objectField("hi");
            try json.write(value.hi);
            try json.endObject();
        },
        .select => |value| {
            try json.beginObject();
            try json.objectField("id");
            try json.write(value.id);
            try json.objectField("key");
            try json.write(value.key);
            try json.objectField("rank");
            try json.write(value.rank);
            try json.endObject();
        },
        .bytes => |bytes| {
            try json.beginObject();
            try json.objectField("bytes_hex");
            try json.write(try encodeHex(allocator, bytes));
            try json.endObject();
        },
        .members => |members| {
            try json.beginObject();
            try json.objectField("members");
            try json.write(members);
            try json.endObject();
        },
        .relations => |relations| {
            try json.beginObject();
            try json.objectField("relations");
            try json.beginArray();
            for (relations) |relation| {
                try json.beginObject();
                try json.objectField("asserted_by");
                try json.write(relation.asserted_by);
                try json.objectField("certainty");
                try json.write(relation.certainty);
                try json.objectField("predicate");
                try json.write(relation.predicate);
                try json.objectField("source");
                try json.write(relation.source);
                try json.objectField("target");
                try json.write(relation.target);
                try json.endObject();
            }
            try json.endArray();
            try json.endObject();
        },
        .checksum => |checksum| {
            try json.beginObject();
            try json.objectField("sha256");
            try json.write(checksum);
            try json.endObject();
        },
    }
}

fn writeResponse(init: std.process.Init, writer: *std.Io.Writer, allocator: std.mem.Allocator, request_id: i64, sample: i64, result: Result, timed: bool, elapsed_ns: u64) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    var json = std.json.Stringify{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("protocol");
    try json.write(protocol);
    try json.objectField("request_id");
    try json.write(request_id);
    try json.objectField("sample");
    try json.write(sample);
    try json.objectField("ok");
    try json.write(true);
    if (timed) {
        try json.objectField("timing_mode");
        try json.write("reader_self");
        try json.objectField("reader_elapsed_ns");
        try json.write(elapsed_ns);
    }
    try json.objectField("result");
    try writeResult(&json, allocator, result);
    try json.endObject();
    try output.writer.writeByte('\n');
    try writer.writeAll(output.written());
    try writer.flush();
    _ = init;
}

fn writeErrorResponse(allocator: std.mem.Allocator, writer: *std.Io.Writer, request_id: i64, sample: i64, err: anyerror) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    var json = std.json.Stringify{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("protocol");
    try json.write(protocol);
    try json.objectField("request_id");
    try json.write(request_id);
    try json.objectField("sample");
    try json.write(sample);
    try json.objectField("ok");
    try json.write(false);
    try json.objectField("error");
    try json.write(@errorName(err));
    try json.endObject();
    try output.writer.writeByte('\n');
    try writer.writeAll(output.written());
    try writer.flush();
}

fn writeReady(allocator: std.mem.Allocator, writer: *std.Io.Writer, artifact_bytes: usize) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    var json = std.json.Stringify{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("protocol");
    try json.write(protocol);
    try json.objectField("event");
    try json.write("ready");
    try json.objectField("artifact_bytes");
    try json.write(artifact_bytes);
    try json.endObject();
    try output.writer.writeByte('\n');
    try writer.writeAll(output.written());
    try writer.flush();
}

fn requestField(object: std.json.ObjectMap, name: []const u8) ?std.json.Value {
    return object.get(name);
}
fn requestString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return string(requestField(object, name) orelse return error.MissingField);
}
fn requestInt(object: std.json.ObjectMap, name: []const u8) !i64 {
    return integer(requestField(object, name) orelse return error.MissingField);
}

fn rejectAnswerLeak(object: std.json.ObjectMap) !void {
    for ([_][]const u8{ "expected", "oracle", "answers", "query_checksum", "schedule", "workload" }) |name| if (object.get(name) != null) return error.ExpectedAnswerOnWire;
}

fn requestFieldAllowed(op: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, name, "protocol") or std.mem.eql(u8, name, "request_id") or std.mem.eql(u8, name, "sample") or std.mem.eql(u8, name, "op") or std.mem.eql(u8, name, "timing_mode")) return true;
    if (std.mem.eql(u8, op, "exact") or std.mem.eql(u8, op, "prefix_interval") or std.mem.eql(u8, op, "prefix_enumerate")) return std.mem.eql(u8, name, "key");
    if (std.mem.eql(u8, op, "select") or std.mem.eql(u8, op, "render") or std.mem.eql(u8, op, "concept_members")) return std.mem.eql(u8, name, "id");
    if (std.mem.eql(u8, op, "snippet")) return std.mem.eql(u8, name, "id") or std.mem.eql(u8, name, "limit");
    if (std.mem.eql(u8, op, "translations")) return std.mem.eql(u8, name, "id") or std.mem.eql(u8, name, "language");
    if (std.mem.eql(u8, op, "relations")) return std.mem.eql(u8, name, "id") or std.mem.eql(u8, name, "predicate");
    return false;
}

fn rejectUnexpectedFields(object: std.json.ObjectMap, op: []const u8) !void {
    for (object.keys()) |name| if (!requestFieldAllowed(op, name)) return error.UnexpectedRequestField;
}

fn handleRequest(store: *Store, object: std.json.ObjectMap) !struct { result: Result, timed: bool, elapsed_ns: u64, request_id: i64, sample: i64 } {
    try rejectAnswerLeak(object);
    if (!std.mem.eql(u8, try requestString(object, "protocol"), protocol)) return error.InvalidProtocol;
    const request_id = try requestInt(object, "request_id");
    const sample = try requestInt(object, "sample");
    const op = try requestString(object, "op");
    try rejectUnexpectedFields(object, op);
    const timing_mode = requestField(object, "timing_mode");
    const timed = if (timing_mode) |value| blk: {
        if (!std.mem.eql(u8, try string(value), "reader_self")) return error.InvalidTimingMode;
        break :blk true;
    } else false;
    const key = if (std.mem.eql(u8, op, "exact") or std.mem.eql(u8, op, "prefix_interval") or std.mem.eql(u8, op, "prefix_enumerate")) try requestString(object, "key") else "";
    const raw_id = if (std.mem.eql(u8, op, "select") or std.mem.eql(u8, op, "render") or std.mem.eql(u8, op, "snippet") or std.mem.eql(u8, op, "concept_members") or std.mem.eql(u8, op, "translations") or std.mem.eql(u8, op, "relations")) try requestInt(object, "id") else 0;
    const select_rank = if (std.mem.eql(u8, op, "select")) std.math.cast(usize, raw_id) orelse return error.InvalidInput else 0;
    const limit = if (std.mem.eql(u8, op, "snippet")) std.math.cast(usize, try requestInt(object, "limit")) orelse return error.InvalidInput else 0;
    const language = if (std.mem.eql(u8, op, "translations")) try requestString(object, "language") else "";
    const predicate = if (std.mem.eql(u8, op, "relations")) try requestString(object, "predicate") else "";
    const started = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
    const result = if (std.mem.eql(u8, op, "exact")) Result{ .ids = try lookup(store, key, .exact) } else if (std.mem.eql(u8, op, "prefix_interval")) try prefixInterval(store, key) else if (std.mem.eql(u8, op, "prefix_enumerate")) Result{ .ids = try lookup(store, key, .prefix) } else if (std.mem.eql(u8, op, "select")) try select(store, select_rank) else if (std.mem.eql(u8, op, "render")) try renderAt(store, raw_id, null) else if (std.mem.eql(u8, op, "snippet")) try renderAt(store, raw_id, limit) else if (std.mem.eql(u8, op, "concept_members")) Result{ .members = try conceptMembers(store, raw_id) } else if (std.mem.eql(u8, op, "translations")) Result{ .members = try translations(store, raw_id, language) } else if (std.mem.eql(u8, op, "relations")) Result{ .relations = try relationRows(store, raw_id, predicate) } else if (std.mem.eql(u8, op, "structure_checksum")) Result{ .checksum = try structureChecksum(store) } else return error.UnknownOperation;
    const finished = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
    return .{ .result = result, .timed = timed, .elapsed_ns = if (finished >= started) @intCast(finished - started) else 0, .request_id = request_id, .sample = sample };
}

fn runServer(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8) !void {
    var store = try loadStore(init, allocator, path);
    defer store.deinit();
    var input_buffer: [64 * 1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(init.io, &input_buffer);
    var output_buffer: [64 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    try writeReady(allocator, &writer.interface, store.artifact.len);
    while (try reader.interface.takeDelimiter('\n')) |line| {
        _ = store.query_arena.reset(.retain_capacity);
        const request_allocator = store.query_arena.allocator();
        if (line.len == 0) continue;
        if (line.len > max_line_bytes) return error.RequestTooLarge;
        const parsed = try std.json.parseFromSlice(std.json.Value, request_allocator, line, .{});
        const object = switch (parsed.value) {
            .object => |value| value,
            else => return error.InvalidRequest,
        };
        const response = handleRequest(&store, object) catch |err| {
            const request_id = if (object.get("request_id")) |value| integer(value) catch -1 else -1;
            const sample = if (object.get("sample")) |value| integer(value) catch -1 else -1;
            try writeErrorResponse(request_allocator, &writer.interface, request_id, sample, err);
            _ = store.query_arena.reset(.retain_capacity);
            continue;
        };
        try writeResponse(init, &writer.interface, request_allocator, response.request_id, response.sample, response.result, response.timed, response.elapsed_ns);
        _ = store.query_arena.reset(.retain_capacity);
    }
}

fn verifyArtifact(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8) !void {
    var store = try loadStore(init, allocator, path);
    defer store.deinit();
}

fn parseConfig(args: std.process.Args) !Config {
    var config = Config{};
    var iterator = std.process.Args.Iterator.init(args);
    _ = iterator.next();
    var selected: usize = 0;
    while (iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bench4-build")) {
            config.mode = .build;
            selected += 1;
        } else if (std.mem.eql(u8, arg, "--bench4-verify")) {
            config.mode = .verify;
            selected += 1;
        } else if (std.mem.eql(u8, arg, "--bench4-server")) {
            config.mode = .server;
            selected += 1;
        } else if (std.mem.eql(u8, arg, "--fixture")) config.fixture = iterator.next() orelse return error.MissingFixture else if (std.mem.eql(u8, arg, "--records")) config.records = try std.fmt.parseUnsigned(usize, iterator.next() orelse return error.MissingRecords, 10) else if (std.mem.eql(u8, arg, "--corpus")) config.corpus = iterator.next() orelse return error.MissingCorpus else if (std.mem.eql(u8, arg, "--semantic-input")) config.semantic_input = iterator.next() orelse return error.MissingSemanticInput else if (std.mem.eql(u8, arg, "--output")) config.output = iterator.next() orelse return error.MissingOutput else if (std.mem.eql(u8, arg, "--artifact")) config.artifact = iterator.next() orelse return error.MissingArtifact else return error.InvalidArgument;
    }
    if (selected != 1) return error.InvalidArgument;
    return config;
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config = try parseConfig(init.minimal.args);
    switch (config.mode) {
        .build => try buildArtifact(init, allocator, config),
        .verify => try verifyArtifact(init, allocator, config.artifact orelse return error.MissingArtifact),
        .server => try runServer(init, allocator, config.artifact orelse return error.MissingArtifact),
    }
}

test "identity metadata rejects a payload mutation before publishing IDs" {
    var definition = [_]u8{'d'};
    const entries = [_]Entry{.{
        .id = 17,
        .key = "word",
        .definition = &definition,
        .language = "en",
    }};
    const encoded = try encodeMetadata(std.testing.allocator, &entries, &.{}, "snapshot");
    defer std.testing.allocator.free(encoded);
    encoded[metadata_header_size] ^= 1;
    try std.testing.expectError(
        error.InvalidMetadataDigest,
        parseMetadata(std.testing.allocator, encoded),
    );
}
