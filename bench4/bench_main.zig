//! Native LEX4 benchmark adapter.
//!
//! This executable is deliberately kept under bench4/ so the benchmark
//! campaign can review the native boundary without changing src4 production
//! or build4.zig.  The build path consumes only the semantic fixture and its
//! corpus projection, emits the real LEX4 authenticated hot sections through
//! compiler.buildWithProseMap, and stores only compact identity/rank metadata
//! in an authenticated side section.  The server opens and verifies a
//! Snapshot before serving JSONL operations.  It never receives an expected
//! answer or a query schedule.

const std = @import("std");
const lex4 = @import("src4");
// compiler.buildWithProseMap currently authenticates the canonical public
// section writers below.  Keep the benchmark on that same Snapshot wire
// contract; compact experimental writers are not silently mislabeled as the
// artifact reader's native format.
const automaton = lex4.automaton;
const forest = lex4.forest;
const grammar = lex4.grammar;
const axes = lex4.axes;
const terms_index = lex4.terms;
const compiler = lex4.compiler;
const schema = lex4.schema;
const concept_index = lex4.concepts;
const relation_index = lex4.relations;
const compact_metadata = @import("metadata.zig");

const protocol = "LEX4-BENCH/1";
const semantic_schema_version: i64 = 1;
const semantic_seed: i64 = 0x4c45583400040001;
const max_input_bytes = 512 * 1024 * 1024;
const max_line_bytes = 4 * 1024 * 1024;

const Entry = struct {
    id: i64,
    key: []const u8,
    definition: []u8,
};

const Sense = struct {
    id: i64,
    entry: i64,
    language: []const u8,
    concept: ?i64,
    entry_rank: usize = 0,
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

const MetaSense = struct {
    id: i64,
    entry_rank: usize,
    language: u16,
    concept: ?i64,
};
const Meta = struct {
    bytes: []const u8,
    entry_ids: []i64,
    senses: []MetaSense,
    languages: [][]const u8,
    sources: [][]const u8,
    concepts: []compact_metadata.Concept,
    max_key_bytes: usize,
    max_definition_bytes: usize,
};

const Store = struct {
    allocator: std.mem.Allocator,
    artifact: []u8,
    // Snapshot caches borrow pointers back to the Snapshot itself.  Keep it
    // allocator-stable instead of returning a value whose cached views would
    // point into loadStore's stack frame.
    snapshot: *lex4.snapshot.Snapshot,
    meta: Meta,
    rank_ids: []i64,
    id_to_rank: std.AutoHashMap(i64, u32),
    exact_ids: []i64,
    sense_rank_ids: []i64,
    max_key_bytes: usize,
    max_definition_bytes: usize,
    key_output: []u8,
    render_output: []u8,
    render_frames: []lex4.snapshot.RenderFrame,
    query_arena: std.heap.ArenaAllocator,

    fn queryAllocator(self: *Store) std.mem.Allocator {
        return self.query_arena.allocator();
    }

    fn deinit(self: *Store) void {
        // All server allocations live in the caller's arena.  The method is
        // retained as an explicit lifecycle seam for future mmap ownership.
        self.query_arena.deinit();
    }
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

const Result = union(enum) {
    ids: []i64,
    interval: struct { lo: i64, hi: i64 },
    select: struct { id: i64, key: []const u8, rank: i64 },
    bytes: []u8,
    members: []i64,
    relations: []Relation,
    checksum: []const u8,
};

fn invalidInput() anyerror {
    return error.InvalidInput;
}

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

fn hexDigit(value: u8) ?u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => null,
    };
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
    const relation_rows = try allocator.alloc(Relation, relation_values.len);
    errdefer allocator.free(relation_rows);
    for (relation_values, 0..) |value, index| {
        const object = switch (value) {
            .object => |item| item,
            else => return error.InvalidInput,
        };
        relation_rows[index] = .{
            .source = try integer(try objectField(object, "source")),
            .predicate = try string(try objectField(object, "predicate")),
            .target = try integer(try objectField(object, "target")),
            .asserted_by = try string(try objectField(object, "asserted_by")),
            .certainty = try string(try objectField(object, "certainty")),
        };
    }

    // A source ID is durable identity.  Reject duplicate IDs rather than
    // silently letting graph or render lookups choose one occurrence.
    for (entries, 0..) |entry, index| for (entries[0..index]) |prior| if (entry.id == prior.id) return error.DuplicateEntryId;
    return .{ .fixture = fixture, .seed = seed, .entries = entries, .senses = senses, .concepts = concepts, .relations = relation_rows };
}

fn languageNames(allocator: std.mem.Allocator, senses: []const Sense) ![][]const u8 {
    var names = std.ArrayList([]const u8).empty;
    errdefer names.deinit(allocator);
    for (senses) |sense| {
        var found = false;
        for (names.items) |name| {
            if (std.mem.eql(u8, name, sense.language)) found = true;
        }
        if (!found) try names.append(allocator, sense.language);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.less);
    return names.toOwnedSlice(allocator);
}

fn languageIndex(names: []const []const u8, value: []const u8) !u16 {
    for (names, 0..) |name, index| if (std.mem.eql(u8, name, value)) return std.math.cast(u16, index) orelse error.MetadataOverflow;
    return error.InvalidLanguage;
}

fn sourceNames(allocator: std.mem.Allocator, relation_rows: []const Relation) ![][]const u8 {
    var names = std.ArrayList([]const u8).empty;
    errdefer names.deinit(allocator);
    for (relation_rows) |relation| {
        var found = false;
        for (names.items) |name| {
            if (std.mem.eql(u8, name, relation.asserted_by)) found = true;
        }
        if (!found) try names.append(allocator, relation.asserted_by);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.less);
    return names.toOwnedSlice(allocator);
}

fn sourceIndex(names: []const []const u8, value: []const u8) !u16 {
    for (names, 0..) |name, index| if (std.mem.eql(u8, name, value)) return std.math.cast(u16, index) orelse error.MetadataOverflow;
    return error.InvalidSource;
}

fn encodeMetadata(allocator: std.mem.Allocator, semantic: *const Semantic) ![]u8 {
    const names = try languageNames(allocator, semantic.senses);
    defer allocator.free(names);
    const sources = try sourceNames(allocator, semantic.relations);
    defer allocator.free(sources);
    const entry_ids = try allocator.alloc(i64, semantic.entries.len);
    defer allocator.free(entry_ids);
    const senses = try allocator.alloc(compact_metadata.Sense, semantic.senses.len);
    defer allocator.free(senses);
    const concepts = try allocator.alloc(compact_metadata.Concept, semantic.concepts.len);
    defer allocator.free(concepts);
    var max_key_bytes: u32 = 0;
    var max_definition_bytes: u32 = 0;
    for (semantic.entries, 0..) |entry, index| {
        entry_ids[index] = entry.id;
        max_key_bytes = @max(max_key_bytes, std.math.cast(u32, entry.key.len) orelse return error.MetadataOverflow);
        max_definition_bytes = @max(max_definition_bytes, std.math.cast(u32, entry.definition.len) orelse return error.MetadataOverflow);
    }
    for (semantic.senses, 0..) |sense, index| senses[index] = .{
        .id = sense.id,
        .entry_rank = std.math.cast(u32, rankOfEntry(semantic.entries, sense.entry) orelse return error.InvalidSense) orelse return error.MetadataOverflow,
        .language = try languageIndex(names, sense.language),
    };
    for (semantic.concepts, 0..) |concept, index| concepts[index] = .{ .id = concept.id, .label = concept.label };
    return compact_metadata.encode(allocator, .{
        .entry_ids = entry_ids,
        .senses = senses,
        .concepts = concepts,
        .languages = names,
        .sources = sources,
        .max_key_bytes = max_key_bytes,
        .max_definition_bytes = max_definition_bytes,
    });
}

fn parseMetadata(allocator: std.mem.Allocator, bytes: []const u8) !Meta {
    const decoded = try compact_metadata.decode(allocator, bytes);
    const senses = try allocator.alloc(MetaSense, decoded.senses.len);
    for (decoded.senses, 0..) |sense, index| senses[index] = .{
        .id = sense.id,
        .entry_rank = sense.entry_rank,
        .language = sense.language,
        .concept = null,
    };
    return .{
        .bytes = bytes,
        .entry_ids = decoded.entry_ids,
        .senses = senses,
        .languages = decoded.languages,
        .sources = decoded.sources,
        .concepts = decoded.concepts,
        .max_key_bytes = decoded.max_key_bytes,
        .max_definition_bytes = decoded.max_definition_bytes,
    };
}

fn entryLess(_: void, left: Entry, right: Entry) bool {
    return switch (std.mem.order(u8, left.key, right.key)) {
        .lt => true,
        .gt => false,
        .eq => left.id < right.id,
    };
}

fn senseLess(_: void, left: Sense, right: Sense) bool {
    if (left.entry_rank != right.entry_rank) return left.entry_rank < right.entry_rank;
    return left.id < right.id;
}

fn conceptLess(_: void, left: Concept, right: Concept) bool {
    return left.id < right.id;
}

fn relationLess(_: void, left: Relation, right: Relation) bool {
    if (left.source != right.source) return left.source < right.source;
    const predicate_order = std.mem.order(u8, left.predicate, right.predicate);
    if (predicate_order != .eq) return predicate_order == .lt;
    return left.target < right.target;
}

const TermOccurrence = struct {
    term: []u8,
    rank: u32,
};

fn isAsciiTermByte(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= '0' and byte <= '9') or byte == '_';
}

fn termOccurrenceLess(_: void, left: TermOccurrence, right: TermOccurrence) bool {
    const order = std.mem.order(u8, left.term, right.term);
    if (order != .eq) return order == .lt;
    return left.rank < right.rank;
}

fn freeTermOccurrences(allocator: std.mem.Allocator, occurrences: *std.ArrayList(TermOccurrence)) void {
    for (occurrences.items) |occurrence| allocator.free(occurrence.term);
    occurrences.deinit(allocator);
}

/// Tokenization is intentionally narrow and reproducible: ASCII letters,
/// digits, and underscore form a term; ASCII letters are folded to lower case.
/// Every non-ASCII UTF-8 byte is a separator.  The term section is therefore
/// a deterministic projection of authenticated definition bytes, not a
/// second semantic source.
fn buildTerms(allocator: std.mem.Allocator, entries: []const Entry) !terms_index.Owned {
    var occurrences = std.ArrayList(TermOccurrence).empty;
    defer freeTermOccurrences(allocator, &occurrences);
    for (entries, 0..) |entry, rank| {
        var start: ?usize = null;
        for (entry.definition, 0..) |byte, index| {
            if (isAsciiTermByte(byte)) {
                if (start == null) start = index;
                continue;
            }
            if (start) |begin| {
                const term = try allocator.dupe(u8, entry.definition[begin..index]);
                for (term) |*character| {
                    if (character.* >= 'A' and character.* <= 'Z') character.* += 'a' - 'A';
                }
                try occurrences.append(allocator, .{ .term = term, .rank = @intCast(rank) });
                start = null;
            }
        }
        if (start) |begin| {
            const term = try allocator.dupe(u8, entry.definition[begin..]);
            for (term) |*character| {
                if (character.* >= 'A' and character.* <= 'Z') character.* += 'a' - 'A';
            }
            try occurrences.append(allocator, .{ .term = term, .rank = @intCast(rank) });
        }
    }
    if (occurrences.items.len == 0) return error.EmptyTermIndex;
    std.mem.sort(TermOccurrence, occurrences.items, {}, termOccurrenceLess);

    var builder = terms_index.Builder.init(allocator, std.math.cast(u32, entries.len) orelse return error.MetadataOverflow);
    defer builder.deinit();
    var index: usize = 0;
    while (index < occurrences.items.len) {
        const term = occurrences.items[index].term;
        var postings = std.ArrayList(terms_index.EntryRank).empty;
        defer postings.deinit(allocator);
        while (index < occurrences.items.len and std.mem.eql(u8, term, occurrences.items[index].term)) : (index += 1) {
            const rank = occurrences.items[index].rank;
            if (postings.items.len == 0 or @intFromEnum(postings.items[postings.items.len - 1]) != rank)
                try postings.append(allocator, @enumFromInt(rank));
        }
        try builder.add(term, postings.items);
    }
    return builder.finish();
}

fn relationId(name: []const u8) ?schema.RelationId {
    if (std.mem.eql(u8, name, "translation")) return .near_translation;
    if (std.mem.eql(u8, name, "near_synonym")) return .similar_to;
    if (std.mem.eql(u8, name, "see_also")) return .see_also;
    if (std.mem.eql(u8, name, "hypernym")) return .hypernym;
    if (std.mem.eql(u8, name, "hyponym")) return .hyponym;
    if (std.mem.eql(u8, name, "synonym")) return .synonym;
    if (std.mem.eql(u8, name, "antonym")) return .antonym;
    if (std.mem.eql(u8, name, "similar_to")) return .similar_to;
    return null;
}

fn certainty(value: []const u8) schema.Certainty {
    if (std.mem.eql(u8, value, "possible") or std.mem.eql(u8, value, "candidate")) return .possible;
    if (std.mem.eql(u8, value, "probable")) return .probable;
    if (std.mem.eql(u8, value, "certain")) return .certain;
    return .unknown;
}

fn assertionState(value: []const u8) relation_index.AssertionState {
    if (std.mem.eql(u8, value, "disputed")) return .disputed;
    if (std.mem.eql(u8, value, "inferred")) return .inferred;
    if (std.mem.eql(u8, value, "retracted")) return .retracted;
    return .asserted;
}

fn rankOfEntry(entries: []const Entry, id: i64) ?usize {
    for (entries, 0..) |entry, rank| if (entry.id == id) return rank;
    return null;
}

fn rankOfSense(senses: []const Sense, _: []const Entry, id: i64) ?usize {
    for (senses, 0..) |sense, rank| if (sense.id == id) return rank;
    return null;
}

fn copyAndSort(allocator: std.mem.Allocator, comptime T: type, source: []const T, less: fn (void, T, T) bool) ![]T {
    const copy = try allocator.dupe(T, source);
    std.mem.sort(T, copy, {}, less);
    return copy;
}

fn validateCorpus(init: std.process.Init, path: []const u8, semantic: *const Semantic) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(max_input_bytes));
    defer init.gpa.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const id_text = fields.next() orelse return error.InvalidCorpus;
        const key_text = fields.next() orelse return error.InvalidCorpus;
        const definition_text = fields.next() orelse return error.InvalidCorpus;
        if (fields.next() != null) return error.InvalidCorpus;
        const id = std.fmt.parseInt(i64, id_text, 10) catch return error.InvalidCorpus;
        const key = try decodeCorpusField(init.gpa, key_text);
        defer init.gpa.free(key);
        const definition = try decodeCorpusField(init.gpa, definition_text);
        defer init.gpa.free(definition);
        var matched = false;
        for (semantic.entries) |entry| {
            if (entry.id != id) continue;
            if (!std.mem.eql(u8, entry.key, key) or !std.mem.eql(u8, entry.definition, definition)) return error.CorpusSourceMismatch;
            matched = true;
            break;
        }
        if (!matched) return error.CorpusSourceMismatch;
        count += 1;
    }
    if (count != semantic.entries.len) return error.CorpusCardinalityMismatch;
}

/// The benchmark projection has one semantic sense per lexical entry. Its
/// sense coordinate must be the forest's kind rank, not an independent sort
/// of source IDs. Reject unsupported cardinalities instead of assigning the
/// same Rank(.sense) type to unrelated coordinate systems.
fn alignSemanticDomains(allocator: std.mem.Allocator, semantic: *const Semantic) !void {
    var entries = std.AutoHashMap(i64, usize).init(allocator);
    defer entries.deinit();
    for (semantic.entries, 0..) |entry, rank| {
        const found = try entries.getOrPut(entry.id);
        if (found.found_existing) return error.DuplicateEntry;
        found.value_ptr.* = rank;
    }
    if (semantic.senses.len == 0 and semantic.concepts.len == 0 and semantic.relations.len == 0) return;
    if (semantic.senses.len != semantic.entries.len) return error.UnsupportedSenseProjection;
    const seen_entries = try allocator.alloc(bool, semantic.entries.len);
    defer allocator.free(seen_entries);
    @memset(seen_entries, false);
    var senses = std.AutoHashMap(i64, usize).init(allocator);
    defer senses.deinit();
    for (semantic.senses, 0..) |*sense, index| {
        const rank = entries.get(sense.entry) orelse return error.InvalidSense;
        if (seen_entries[rank]) return error.UnsupportedSenseProjection;
        seen_entries[rank] = true;
        sense.entry_rank = rank;
        const found = try senses.getOrPut(sense.id);
        if (found.found_existing) return error.DuplicateSense;
        found.value_ptr.* = index;
    }
    var concepts = std.AutoHashMap(i64, void).init(allocator);
    defer concepts.deinit();
    const listed = try allocator.alloc(bool, semantic.senses.len);
    defer allocator.free(listed);
    @memset(listed, false);
    for (semantic.concepts) |concept| {
        if ((try concepts.getOrPut(concept.id)).found_existing) return error.DuplicateConcept;
        for (concept.members) |id| {
            const index = senses.get(id) orelse return error.InvalidConcept;
            if (listed[index] or semantic.senses[index].concept == null or semantic.senses[index].concept.? != concept.id)
                return error.ConceptMembershipMismatch;
            listed[index] = true;
        }
    }
    // Both source projections must agree, but only one is stored. Neither
    // dropping an inverse member nor forging a member can pass silently.
    for (semantic.senses, listed) |sense, present| {
        if ((sense.concept != null) != present) return error.ConceptMembershipMismatch;
    }
}

fn decodeCorpusField(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < encoded.len) : (index += 1) {
        if (encoded[index] != '\\') {
            try output.append(allocator, encoded[index]);
            continue;
        }
        index += 1;
        if (index >= encoded.len) return error.InvalidCorpus;
        try output.append(allocator, switch (encoded[index]) {
            't' => '\t',
            'n' => '\n',
            '\\' => '\\',
            else => return error.InvalidCorpus,
        });
    }
    return output.toOwnedSlice(allocator);
}

fn writeAtomic(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temporary);
    var file = try std.Io.Dir.cwd().createFile(init.io, temporary, .{ .truncate = true, .exclusive = true });
    defer file.close(init.io);
    var buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try std.Io.Dir.rename(.cwd(), temporary, .cwd(), path, init.io);
}

fn buildArtifact(init: std.process.Init, allocator: std.mem.Allocator, config: Config) !void {
    const fixture_name = config.fixture orelse return error.MissingFixture;
    const corpus_path = config.corpus orelse return error.MissingCorpus;
    const semantic_path = config.semantic_input orelse return error.MissingSemanticInput;
    const output_path = config.output orelse return error.MissingOutput;
    const semantic_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, semantic_path, allocator, .limited(max_input_bytes));
    const semantic = try parseSemantic(allocator, semantic_bytes);
    if (!std.mem.eql(u8, fixture_name, semantic.fixture)) return error.FixtureMismatch;
    if (semantic.seed != semantic_seed) return error.SeedMismatch;
    if (config.records) |records| if (records != semantic.entries.len) return error.RecordCountMismatch;
    try validateCorpus(init, corpus_path, &semantic);

    std.mem.sort(Entry, semantic.entries, {}, entryLess);
    try alignSemanticDomains(allocator, &semantic);
    std.mem.sort(Sense, semantic.senses, {}, senseLess);
    std.mem.sort(Concept, semantic.concepts, {}, conceptLess);
    std.mem.sort(Relation, semantic.relations, {}, relationLess);
    var automaton_builder = automaton.Builder.init(allocator);
    defer automaton_builder.deinit();
    var rank_ids = std.ArrayList(i64).empty;
    defer rank_ids.deinit(allocator);
    var index: usize = 0;
    while (index < semantic.entries.len) {
        const key = semantic.entries[index].key;
        var end = index + 1;
        while (end < semantic.entries.len and std.mem.eql(u8, key, semantic.entries[end].key)) : (end += 1) {}
        const multiplicity = std.math.cast(u32, end - index) orelse return error.TooManyEntries;
        try automaton_builder.addEntry(key, multiplicity);
        for (semantic.entries[index..end]) |entry| try rank_ids.append(allocator, entry.id);
        index = end;
    }
    var automaton_owned = try automaton_builder.finish();
    defer automaton_owned.deinit();

    var forest_builder = forest.Builder.init(allocator);
    defer forest_builder.deinit();
    for (semantic.entries) |entry| {
        const root = try forest_builder.addRoot(entry.key, .entry);
        const sense = try forest_builder.addChild(root, .sense);
        _ = try forest_builder.addChild(sense, .definition);
    }
    var forest_owned = try forest_builder.build();
    defer forest_owned.deinit();

    const prose_inputs = try allocator.alloc(grammar.ItemInput, semantic.entries.len);
    defer allocator.free(prose_inputs);
    for (semantic.entries, 0..) |entry, entry_index| prose_inputs[entry_index] = .{ .text = entry.definition };
    var prose_owned = try grammar.build(allocator, prose_inputs, .{});
    defer prose_owned.deinit();

    // Every native artifact carries the same derived-axis and term-index
    // ledger.  Both are built from the canonical, sorted entry projection:
    // reversed keys retain homograph multiplicity, while term postings are
    // sorted unique entry ranks and are derived only from definition bytes.
    var reversed_builder = axes.AxisBuilder(axes.Reverse).init(allocator);
    defer reversed_builder.deinit();
    index = 0;
    while (index < semantic.entries.len) {
        const key = semantic.entries[index].key;
        var end = index + 1;
        while (end < semantic.entries.len and std.mem.eql(u8, key, semantic.entries[end].key)) : (end += 1) {}
        _ = try reversed_builder.addEntry(key, std.math.cast(u32, end - index) orelse return error.TooManyEntries);
        index = end;
    }
    var reversed_owned = try reversed_builder.finish();
    defer reversed_owned.deinit();
    var terms_owned = try buildTerms(allocator, semantic.entries);
    defer terms_owned.deinit();

    var concept_owned: ?concept_index.ConceptOwned = null;
    defer if (concept_owned) |*owned| owned.deinit();
    var relation_owned: ?relation_index.Owned = null;
    defer if (relation_owned) |*owned| owned.deinit();

    if (semantic.concepts.len != 0) {
        var records = try allocator.alloc(concept_index.ConceptMembership, semantic.senses.len);
        defer allocator.free(records);
        var record_count: usize = 0;
        for (semantic.senses) |sense| {
            const concept_id = sense.concept orelse continue;
            const sense_rank = rankOfSense(semantic.senses, semantic.entries, sense.id) orelse return error.InvalidSense;
            var concept_rank: ?usize = null;
            for (semantic.concepts, 0..) |concept, concept_ordinal| {
                if (concept.id == concept_id) concept_rank = concept_ordinal;
            }
            const c_rank = concept_rank orelse return error.InvalidConcept;
            records[record_count] = .{
                .sense = @enumFromInt(@as(u32, @intCast(sense_rank))),
                .concept = @enumFromInt(@as(u32, @intCast(c_rank))),
            };
            record_count += 1;
        }
        concept_owned = try concept_index.build(.concept, allocator, semantic.senses.len, semantic.concepts.len, records[0..record_count]);
    }

    if (semantic.relations.len != 0) {
        const sources = try sourceNames(allocator, semantic.relations);
        defer allocator.free(sources);
        var graph = relation_index.Builder.init(allocator, .{});
        defer graph.deinit();
        // The source model has one unqualified concept assignment per sense.
        // The concepts section owns that fact and both lookup directions;
        // emitting it again as qualified graph membership would duplicate it.
        for (semantic.relations) |relation| {
            const relation_kind = relationId(relation.predicate) orelse return error.InvalidRelation;
            const source_rank = rankOfSense(semantic.senses, semantic.entries, relation.source) orelse return error.InvalidSense;
            const target_rank = rankOfSense(semantic.senses, semantic.entries, relation.target) orelse return error.InvalidSense;
            try graph.add(.{
                .relation = relation_kind,
                .source = .{ .kind = .sense, .rank = @enumFromInt(@as(u32, @intCast(source_rank))) },
                .target = .{ .kind = .sense, .rank = @enumFromInt(@as(u32, @intCast(target_rank))) },
                .state = assertionState(relation.certainty),
                .certainty = certainty(relation.certainty),
                .asserted_by = @enumFromInt(try sourceIndex(sources, relation.asserted_by)),
            });
        }
        relation_owned = try graph.build();
    }

    const metadata = try encodeMetadata(allocator, &semantic);
    const domains = [_]compiler.ProseDomain{.{ .kind = .definition, .first = 0, .count = semantic.entries.len }};
    var extras: [5]compiler.Section = undefined;
    var extra_count: usize = 0;
    extras[extra_count] = .{ .tag = .reversed, .bytes = reversed_owned.bytes };
    extra_count += 1;
    extras[extra_count] = .{ .tag = .terms, .bytes = terms_owned.bytes };
    extra_count += 1;
    if (concept_owned) |owned| {
        extras[extra_count] = .{ .tag = .concepts, .bytes = owned.bytes };
        extra_count += 1;
    }
    if (relation_owned) |owned| {
        extras[extra_count] = .{ .tag = .relations, .bytes = owned.bytes };
        extra_count += 1;
    }
    extras[extra_count] = .{ .tag = .metadata, .bytes = metadata };
    extra_count += 1;
    var compiled = try compiler.buildWithProseMap(
        allocator,
        .{ .automaton = automaton_owned.bytes, .forest = forest_owned.bytes, .prose = prose_owned.bytes },
        &domains,
        extras[0..extra_count],
        .{ .prose_alignment = .one_per_entry },
    );
    defer compiled.deinit();
    if (compiled.entry_count != rank_ids.items.len) return error.CrossSectionMismatch;
    const derived_bytes = reversed_owned.bytes.len + terms_owned.bytes.len;
    if (compiled.ledger.section_bytes < derived_bytes) return error.LengthMismatch;
    std.debug.print("LEX4_BENCH_SECTION_LEDGER bytes={} sections={} reversed={} terms={}\n", .{
        compiled.ledger.total_bytes,
        compiled.ledger.section_bytes,
        reversed_owned.bytes.len,
        terms_owned.bytes.len,
    });
    try writeAtomic(init, allocator, output_path, compiled.bytes);
}

fn loadStore(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8) !Store {
    const artifact = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(max_input_bytes));
    // Verification precedes every measured query. Retain authenticated-page
    // state exactly as a mapped production reader would; an empty trust slice
    // deliberately requests stateless rehashing and would charge one 64 KiB
    // digest per grammar-symbol access after verification.
    const upper_page_count = artifact.len / lex4.container.page_size + 64;
    const trust_words = (upper_page_count + 63) / 64;
    const trust = try allocator.alloc(u64, trust_words);
    const snapshot = try allocator.create(lex4.snapshot.Snapshot);
    snapshot.* = try lex4.snapshot.Snapshot.open(artifact, trust, .{});
    try snapshot.verify(allocator);
    const metadata_section = try snapshot.section(.metadata);
    const meta = try parseMetadata(allocator, metadata_section.bytes);
    const rank_ids = try allocator.alloc(i64, meta.entry_ids.len);
    var id_to_rank = std.AutoHashMap(i64, u32).init(allocator);
    try id_to_rank.ensureTotalCapacity(@intCast(meta.entry_ids.len));
    const sense_rank_ids = try allocator.alloc(i64, meta.senses.len);
    const result_capacity = @max(@as(usize, 1), @max(meta.entry_ids.len, meta.senses.len));
    const exact_ids = try allocator.alloc(i64, result_capacity);
    var max_key_bytes: usize = meta.max_key_bytes;
    var max_definition_bytes: usize = meta.max_definition_bytes;
    for (meta.entry_ids, 0..) |id, rank| {
        rank_ids[rank] = id;
        const result = try id_to_rank.getOrPut(id);
        if (result.found_existing) return error.InvalidMetadata;
        result.value_ptr.* = @intCast(rank);
    }
    if (meta.senses.len != 0 and meta.senses.len != meta.entry_ids.len) return error.CrossSectionMismatch;
    for (meta.senses, 0..) |sense, sense_rank| {
        if (sense.entry_rank != sense_rank) return error.CrossSectionMismatch;
        sense_rank_ids[sense_rank] = sense.id;
    }
    if (rank_ids.len != try snapshot.entryCount()) return error.CrossSectionMismatch;
    if (!snapshot.directory().contains(.reversed) or !snapshot.directory().contains(.terms))
        return error.CrossSectionMismatch;
    _ = try snapshot.axis(axes.Reverse);
    _ = try snapshot.terms();
    if (max_key_bytes == 0) max_key_bytes = 1;
    if (max_definition_bytes == 0) max_definition_bytes = 1;
    const key_output = try allocator.alloc(u8, max_key_bytes);
    const render_output = try allocator.alloc(u8, max_definition_bytes);
    const render_frames = try allocator.alloc(lex4.snapshot.RenderFrame, 512);
    const has_concepts = snapshot.directory().contains(.concepts);
    if (has_concepts != (meta.concepts.len != 0)) return error.CrossSectionMismatch;
    if (has_concepts) {
        const view = try snapshot.concepts();
        if (view.conceptCount() != meta.concepts.len or view.senseCount() != meta.senses.len) return error.CrossSectionMismatch;
        for (meta.senses, 0..) |*sense, sense_rank| {
            if (try view.conceptOf(@enumFromInt(@as(u32, @intCast(sense_rank))))) |concept_rank| {
                const rank = @as(usize, @intFromEnum(concept_rank));
                if (rank >= meta.concepts.len) return error.CrossSectionMismatch;
                sense.concept = meta.concepts[rank].id;
            }
        }
    }
    // The graph is optional for flat fixtures.  Relation claims are never
    // duplicated in metadata; if present, the verified graph is authoritative.
    if (snapshot.directory().contains(.relations)) {
        _ = try snapshot.relations();
    }
    return .{
        .allocator = allocator,
        .artifact = artifact,
        .snapshot = snapshot,
        .meta = meta,
        .rank_ids = rank_ids,
        .id_to_rank = id_to_rank,
        .exact_ids = exact_ids,
        .sense_rank_ids = sense_rank_ids,
        .max_key_bytes = max_key_bytes,
        .max_definition_bytes = max_definition_bytes,
        .key_output = key_output,
        .render_output = render_output,
        .render_frames = render_frames,
        .query_arena = std.heap.ArenaAllocator.init(allocator),
    };
}

fn rankForId(store: *const Store, id: i64) ?usize {
    return if (store.id_to_rank.get(id)) |rank| @intCast(rank) else null;
}

fn senseRankForId(store: *const Store, id: i64) ?usize {
    for (store.sense_rank_ids, 0..) |candidate, rank| if (candidate == id) return rank;
    return null;
}

fn conceptRankForId(store: *const Store, id: i64) ?usize {
    for (store.meta.concepts, 0..) |concept, rank| if (concept.id == id) return rank;
    return null;
}

fn relationName(relation: schema.RelationId) []const u8 {
    return switch (relation) {
        .near_translation => "translation",
        .similar_to => "near_synonym",
        .also_see => "see_also",
        else => schema.relations.get(relation).name,
    };
}

fn relationCertainty(edge: relation_index.Edge) []const u8 {
    return switch (edge.state) {
        .disputed => "disputed",
        .inferred => "inferred",
        .retracted => "retracted",
        .asserted => switch (edge.certainty) {
            .possible => "candidate",
            .probable => "probable",
            .certain => "certain",
            .unknown => "asserted",
        },
    };
}

fn relationSource(store: *const Store, edge: relation_index.Edge) ![]const u8 {
    const rank = edge.asserted_by orelse return error.InvalidMetadata;
    const index = @as(usize, @intFromEnum(rank));
    if (index >= store.meta.sources.len) return error.InvalidMetadata;
    return store.meta.sources[index];
}

fn exact(store: *Store, key: []const u8) !Result {
    var query = try store.snapshot.query();
    const hit = (try query.exact(key)) orelse return .{ .ids = store.exact_ids[0..0] };
    const range = hit.entry_range orelse return .{ .ids = store.exact_ids[0..0] };
    const lo = @intFromEnum(range.lo);
    const hi = @intFromEnum(range.hi);
    const ids = store.exact_ids[0 .. hi - lo];
    for (ids, 0..) |*id, index| id.* = store.rank_ids[lo + index];
    return .{ .ids = ids };
}

fn prefixInterval(store: *Store, prefix: []const u8) !Result {
    var query = try store.snapshot.query();
    const range = try query.prefixInterval(prefix);
    return .{ .interval = .{ .lo = @intCast(@intFromEnum(range.lo)), .hi = @intCast(@intFromEnum(range.hi)) } };
}

fn prefixEnumerate(store: *Store, prefix: []const u8) !Result {
    var query = try store.snapshot.query();
    const interval = try query.prefixInterval(prefix);
    const lo = @intFromEnum(interval.lo);
    const hi = @intFromEnum(interval.hi);
    const ids = store.exact_ids[0 .. hi - lo];
    @memcpy(ids, store.rank_ids[lo..hi]);
    return .{ .ids = ids };
}

fn select(store: *Store, rank_value: usize) !Result {
    if (rank_value >= store.rank_ids.len) return error.RankOutOfRange;
    var query = try store.snapshot.query();
    const rank: lex4.snapshot.EntryRank = @enumFromInt(@as(u32, @intCast(rank_value)));
    const entry = (try query.entry(rank, store.key_output)) orelse return error.RankOutOfRange;
    return .{ .select = .{ .id = store.rank_ids[rank_value], .key = entry.headword(), .rank = @intCast(rank_value) } };
}

fn renderAt(store: *Store, id: i64, limit: ?usize) !Result {
    const rank_value = rankForId(store, id) orelse return error.UnknownEntry;
    var query = try store.snapshot.query();
    const rank: lex4.snapshot.EntryRank = @enumFromInt(@as(u32, @intCast(rank_value)));
    var texts = try query.textsForEntry(rank, .definition);
    const text = (try texts.next()) orelse return error.MissingDefinition;
    const output_limit = if (limit) |value| @min(value, store.max_definition_bytes) else store.max_definition_bytes;
    const output = store.render_output[0..output_limit];
    const written = if (limit) |value| try text.snippet(value, output, store.render_frames) else try text.render(output, store.render_frames);
    return .{ .bytes = output[0..written] };
}

fn conceptMembers(store: *Store, id: i64) !Result {
    const concept_rank = conceptRankForId(store, id) orelse return .{ .members = store.exact_ids[0..0] };
    var query = try store.snapshot.query();
    const selected = try query.members(@enumFromInt(@as(u32, @intCast(concept_rank))));
    var iterator = selected.iterator();
    var count: usize = 0;
    while (try iterator.next()) |sense| {
        const rank = @as(usize, @intFromEnum(sense));
        if (rank >= store.sense_rank_ids.len) return error.InvalidMetadata;
        if (count >= store.exact_ids.len) return error.InvalidMetadata;
        store.exact_ids[count] = store.sense_rank_ids[rank];
        count += 1;
    }
    const members = store.exact_ids[0..count];
    std.mem.sort(i64, members, {}, std.sort.asc(i64));
    return .{ .members = members };
}

fn translations(store: *Store, id: i64, language: []const u8) !Result {
    const sense_rank = senseRankForId(store, id) orelse return .{ .members = store.exact_ids[0..0] };
    if (!store.snapshot.directory().contains(.concepts)) return .{ .members = store.exact_ids[0..0] };
    const concepts = try store.snapshot.concepts();
    var wanted: ?usize = null;
    if (language.len != 0) {
        var found_language = false;
        for (store.meta.languages, 0..) |name, index| if (std.mem.eql(u8, name, language)) {
            wanted = index;
            found_language = true;
            break;
        };
        if (!found_language) return .{ .members = store.exact_ids[0..0] };
    }
    var iterator = try concepts.synonyms(@enumFromInt(@as(u32, @intCast(sense_rank))));
    var count: usize = 0;
    while (try iterator.next()) |member| {
        const rank = @as(usize, @intFromEnum(member));
        if (rank >= store.sense_rank_ids.len) return error.InvalidMetadata;
        if (wanted) |language_id| if (store.meta.senses[rank].language != language_id) continue;
        if (count >= store.exact_ids.len) return error.InvalidMetadata;
        store.exact_ids[count] = store.sense_rank_ids[rank];
        count += 1;
    }
    const members = store.exact_ids[0..count];
    std.mem.sort(i64, members, {}, std.sort.asc(i64));
    return .{ .members = members };
}

fn relations(store: *Store, id: i64, predicate: []const u8) !Result {
    var values = std.ArrayList(Relation).empty;
    const allocator = store.queryAllocator();
    const source_rank = senseRankForId(store, id) orelse return .{ .relations = try values.toOwnedSlice(allocator) };
    const graph = store.snapshot.relations() catch return .{ .relations = try values.toOwnedSlice(allocator) };
    const source = relation_index.Endpoint{ .kind = .sense, .rank = @enumFromInt(@as(u32, @intCast(source_rank))) };
    const wanted = if (predicate.len == 0) null else relationId(predicate) orelse return error.InvalidRelation;
    var iterator = try graph.relationsExplicit(source, wanted);
    while (try iterator.next()) |edge| {
        const target_rank = @as(usize, @intFromEnum(edge.target.rank));
        if (target_rank >= store.sense_rank_ids.len) return error.InvalidMetadata;
        try values.append(allocator, .{
            .source = id,
            .predicate = relationName(edge.relation),
            .target = store.sense_rank_ids[target_rank],
            .asserted_by = try relationSource(store, edge),
            .certainty = relationCertainty(edge),
        });
    }
    std.mem.sort(Relation, values.items, {}, relationLess);
    return .{ .relations = try values.toOwnedSlice(allocator) };
}

fn structureChecksum(store: *Store) ![]const u8 {
    const allocator = store.queryAllocator();
    var ranked_writer: std.Io.Writer.Allocating = .init(allocator);
    var json = std.json.Stringify{ .writer = &ranked_writer.writer };
    try json.beginObject();

    try json.objectField("concepts");
    try json.beginArray();
    for (store.meta.concepts) |concept| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(concept.id);
        try json.objectField("label");
        try json.write(concept.label);
        try json.objectField("members");
        // Wire rank order is structural; canonical source identity order is
        // an output concern. The public reader performs this projection too.
        try json.write((try conceptMembers(store, concept.id)).members);
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("ranked");
    try json.beginArray();
    var query = try store.snapshot.query();
    const key_buffer = try allocator.alloc(u8, store.max_key_bytes);
    for (store.rank_ids, 0..) |id, rank_value| {
        const entry = (try query.entry(@enumFromInt(@as(u32, @intCast(rank_value))), key_buffer)) orelse return error.InvalidMetadata;
        try json.beginArray();
        try json.write(id);
        try json.write(entry.headword());
        try json.endArray();
    }
    try json.endArray();

    var relation_values = std.ArrayList(Relation).empty;
    if (store.snapshot.directory().contains(.relations)) {
        const graph = try store.snapshot.relations();
        // Enumerate only explicitly asserted logical arcs.  The graph may
        // expose inferred inverse/symmetric arcs for traversal, but those
        // must not enter the canonical fixture structure digest.
        for (0..store.sense_rank_ids.len) |source_rank| {
            const source = relation_index.Endpoint{ .kind = .sense, .rank = @enumFromInt(@as(u32, @intCast(source_rank))) };
            var iterator = try graph.relationsExplicit(source, null);
            while (try iterator.next()) |edge| {
                const target_rank = @as(usize, @intFromEnum(edge.target.rank));
                if (target_rank >= store.sense_rank_ids.len) return error.InvalidMetadata;
                try relation_values.append(allocator, .{
                    .source = store.sense_rank_ids[source_rank],
                    .predicate = relationName(edge.relation),
                    .target = store.sense_rank_ids[target_rank],
                    .asserted_by = try relationSource(store, edge),
                    .certainty = relationCertainty(edge),
                });
            }
        }
    }
    std.mem.sort(Relation, relation_values.items, {}, relationLess);
    try json.objectField("relations");
    try json.beginArray();
    for (relation_values.items) |relation| {
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
    const ordered_senses = try copyAndSort(allocator, MetaSense, store.meta.senses, struct {
        fn less(_: void, a: MetaSense, b: MetaSense) bool {
            return a.id < b.id;
        }
    }.less);
    for (ordered_senses) |sense| {
        if (sense.entry_rank >= store.rank_ids.len) return error.InvalidMetadata;
        // Exercise the shared sense coordinate, not an entry-ID detour that
        // could conceal a graph/forest rank-order disagreement.
        const selected = try query.select(.sense, .{ .list = &.{@enumFromInt(@as(u32, @intCast(sense.entry_rank)))} });
        var texts = selected.descendants(.definition).texts();
        const text = (try texts.next()) orelse return error.MissingDefinition;
        const n = try text.render(store.render_output, store.render_frames);
        const definition = store.render_output[0..n];
        try json.beginObject();
        try json.objectField("concept");
        if (sense.concept) |concept| try json.write(concept) else try json.write(null);
        try json.objectField("definition_hex");
        const encoded = try encodeHex(allocator, definition);
        try json.write(encoded);
        try json.objectField("entry");
        try json.write(store.rank_ids[sense.entry_rank]);
        try json.objectField("id");
        try json.write(sense.id);
        try json.objectField("language");
        try json.write(store.meta.languages[sense.language]);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try ranked_writer.writer.writeByte('\n');
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(ranked_writer.written(), &digest, .{});
    const result = try encodeHex(allocator, &digest);
    return result;
}

fn jsonValueLine(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
}

fn writeResult(json: *std.json.Stringify, allocator: std.mem.Allocator, result: Result) !void {
    switch (result) {
        .ids => |ids| {
            try json.beginObject();
            try json.objectField("ids");
            try json.write(ids);
            try json.endObject();
        },
        .interval => |interval| {
            try json.beginObject();
            try json.objectField("lo");
            try json.write(interval.lo);
            try json.objectField("hi");
            try json.write(interval.hi);
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
            const encoded = try encodeHex(allocator, bytes);
            try json.write(encoded);
            try json.endObject();
        },
        .members => |members| {
            try json.beginObject();
            try json.objectField("members");
            try json.write(members);
            try json.endObject();
        },
        .relations => |values| {
            try json.beginObject();
            try json.objectField("relations");
            try json.beginArray();
            for (values) |relation| {
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

fn writeResponse(
    init: std.process.Init,
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    request_id: i64,
    sample: i64,
    result: Result,
    timed: bool,
    elapsed_ns: u64,
) !void {
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
    for ([_][]const u8{ "expected", "oracle", "answers", "query_checksum", "schedule", "workload" }) |name| {
        if (object.get(name) != null) return error.ExpectedAnswerOnWire;
    }
}

fn requestFieldAllowed(op: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, name, "protocol") or std.mem.eql(u8, name, "request_id") or
        std.mem.eql(u8, name, "sample") or std.mem.eql(u8, name, "op") or
        std.mem.eql(u8, name, "timing_mode")) return true;
    if (std.mem.eql(u8, op, "exact") or std.mem.eql(u8, op, "prefix_interval") or
        std.mem.eql(u8, op, "prefix_enumerate")) return std.mem.eql(u8, name, "key");
    if (std.mem.eql(u8, op, "select") or std.mem.eql(u8, op, "render") or
        std.mem.eql(u8, op, "concept_members")) return std.mem.eql(u8, name, "id");
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
        const mode = try string(value);
        if (!std.mem.eql(u8, mode, "reader_self")) return error.InvalidTimingMode;
        break :blk true;
    } else false;
    // Decode and validate the request envelope before the reader clock starts.
    // The measured region begins at the operation dispatch, never at JSON
    // field lookup or integer conversion.
    const key = if (std.mem.eql(u8, op, "exact") or
        std.mem.eql(u8, op, "prefix_interval") or
        std.mem.eql(u8, op, "prefix_enumerate")) try requestString(object, "key") else "";
    const raw_id = if (std.mem.eql(u8, op, "select") or
        std.mem.eql(u8, op, "render") or
        std.mem.eql(u8, op, "snippet") or
        std.mem.eql(u8, op, "concept_members") or
        std.mem.eql(u8, op, "translations") or
        std.mem.eql(u8, op, "relations")) try requestInt(object, "id") else 0;
    const select_rank = if (std.mem.eql(u8, op, "select"))
        std.math.cast(usize, raw_id) orelse return error.InvalidInput
    else
        0;
    const limit = if (std.mem.eql(u8, op, "snippet"))
        std.math.cast(usize, try requestInt(object, "limit")) orelse return error.InvalidInput
    else
        0;
    const language = if (std.mem.eql(u8, op, "translations")) try requestString(object, "language") else "";
    const predicate = if (std.mem.eql(u8, op, "relations")) try requestString(object, "predicate") else "";
    const started = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
    const result = if (std.mem.eql(u8, op, "exact"))
        try exact(store, key)
    else if (std.mem.eql(u8, op, "prefix_interval"))
        try prefixInterval(store, key)
    else if (std.mem.eql(u8, op, "prefix_enumerate"))
        try prefixEnumerate(store, key)
    else if (std.mem.eql(u8, op, "select"))
        try select(store, select_rank)
    else if (std.mem.eql(u8, op, "render"))
        try renderAt(store, raw_id, null)
    else if (std.mem.eql(u8, op, "snippet"))
        try renderAt(store, raw_id, limit)
    else if (std.mem.eql(u8, op, "concept_members"))
        try conceptMembers(store, raw_id)
    else if (std.mem.eql(u8, op, "translations"))
        try translations(store, raw_id, language)
    else if (std.mem.eql(u8, op, "relations"))
        try relations(store, raw_id, predicate)
    else if (std.mem.eql(u8, op, "structure_checksum"))
        Result{ .checksum = try structureChecksum(store) }
    else
        return error.UnknownOperation;
    const finished = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
    const elapsed = if (finished >= started) @as(u64, @intCast(finished - started)) else 0;
    return .{ .result = result, .timed = timed, .elapsed_ns = elapsed, .request_id = request_id, .sample = sample };
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
        const request_allocator = store.queryAllocator();
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
            return err;
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
        } else if (std.mem.eql(u8, arg, "--fixture")) {
            config.fixture = iterator.next() orelse return error.MissingFixture;
        } else if (std.mem.eql(u8, arg, "--records")) {
            config.records = try std.fmt.parseUnsigned(usize, iterator.next() orelse return error.MissingRecords, 10);
        } else if (std.mem.eql(u8, arg, "--corpus")) {
            config.corpus = iterator.next() orelse return error.MissingCorpus;
        } else if (std.mem.eql(u8, arg, "--semantic-input")) {
            config.semantic_input = iterator.next() orelse return error.MissingSemanticInput;
        } else if (std.mem.eql(u8, arg, "--output")) {
            config.output = iterator.next() orelse return error.MissingOutput;
        } else if (std.mem.eql(u8, arg, "--artifact")) {
            config.artifact = iterator.next() orelse return error.MissingArtifact;
        } else return error.InvalidArgument;
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
