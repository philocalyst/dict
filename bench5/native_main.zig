//! Native LEX5 bridge for the bounded bench5 correctness pass.
//!
//! The bridge is deliberately an adapter, not a second storage/query
//! implementation.  It parses the canonical fixture input, lowers it to the
//! admitted model.Input, builds the real src5 archive, and serves operations
//! through Book.open/validate, Book.lookup(...).iterator(), Book.record,
//! Book.value, and Book.fact/claims projections.  No expected answers or
//! query schedule are accepted on the wire.

const std = @import("std");
const lex5 = @import("src5");
const model = lex5.model;

const protocol = "LEX5-BENCH/1";
const schema_version: i64 = 1;
const generated_predicate = "@lex5/sense_of";
const max_input_bytes = 512 * 1024 * 1024;
const max_line_bytes = 4 * 1024 * 1024;

const Entry = struct {
    id: i64,
    key: []const u8,
    definition: []u8,
    language: []const u8,
    senses: []i64,
    concepts: []i64,
    homograph: bool,
};

const Text = lex5.strings.TextFor(lex5.bytes.Span([]const u8));

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

const SemanticRelation = struct {
    source: i64,
    predicate: []const u8,
    target: i64,
    asserted_by: []const u8,
    certainty: []const u8,
};

const NativeRelation = struct {
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
    relations: []SemanticRelation,
};

const NativeInput = struct {
    input: model.Input,
    predicate_names: []const []const u8,
};

const Loaded = struct {
    artifact: []const u8,
    book: lex5.book.Book([]const u8),
};

const Scratch = struct {
    ids: []i64,
    relations: []NativeRelation,
    bytes: []u8,
    key: []u8,
    relation_text: []u8,
    relation_text_used: usize,

    fn init(book: *const lex5.book.Book([]const u8), allocator: std.mem.Allocator) !Scratch {
        const entry_count = try recordCount(book, .{ .record = .entry });
        const sense_count = try recordCount(book, .{ .record = .sense });
        const fact_count = try recordCount(book, .fact);
        const value_count = try recordCount(book, .value);
        const key_hit_capacity = try keyHitCapacity(book);
        const id_capacity = @max(@max(@max(entry_count, sense_count), @max(fact_count, key_hit_capacity)), 1);
        const relation_capacity = @max(fact_count, 1);
        var byte_capacity: usize = 1;
        // Value capacity is derived from the opened archive itself. Composite
        // values are not directly renderable, so only scalar atoms contribute
        // to the retained render/snippet buffer size.
        for (0..value_count) |index| {
            const value_id = model.ValueId.fromIndex(index) catch return error.InputTooLarge;
            const handle = book.value(value_id);
            const length = switch (try handle.atom()) {
                .string, .symbol, .decimal, .boolean, .integer, .default_marker, .unknown, .unspecified => try handle.byteLength(),
                else => 0,
            };
            byte_capacity = @max(byte_capacity, length);
        }
        var key_capacity: usize = 1;
        for (0..book.keys.rows.row_count) |index| {
            const row = try book.keys.select(index);
            key_capacity = @max(key_capacity, try book.string(row.key).byteLength());
        }
        const relation_text_capacity = try relationTextCapacity(book);
        return .{
            .ids = try allocator.alloc(i64, id_capacity),
            .relations = try allocator.alloc(NativeRelation, relation_capacity),
            .bytes = try allocator.alloc(u8, byte_capacity),
            .key = try allocator.alloc(u8, key_capacity),
            .relation_text = try allocator.alloc(u8, relation_text_capacity),
            .relation_text_used = 0,
        };
    }
};

const AuditMaps = struct {
    sense_entries: []?usize,
    sense_concepts: []?usize,
};

const Result = union(enum) {
    ids: []i64,
    prefix: struct { ids: []i64, lo: usize, hi: usize },
    interval: struct { lo: usize, hi: usize },
    select: struct { id: i64, key: []const u8, rank: i64 },
    bytes: []u8,
    members: []i64,
    relations: []NativeRelation,
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

fn boolean(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |flag| flag,
        else => error.ExpectedBoolean,
    };
}

fn array(value: std.json.Value) ![]std.json.Value {
    return switch (value) {
        .array => |items| items.items,
        else => error.ExpectedArray,
    };
}

fn rejectUnknown(object: std.json.ObjectMap, fields: []const []const u8) !void {
    for (object.keys()) |name| {
        var known = false;
        for (fields) |field| {
            if (std.mem.eql(u8, name, field)) known = true;
        }
        if (!known) return error.UnloweredField;
    }
}

fn decodeHex(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    if (encoded.len % 2 != 0) return error.InvalidHex;
    const result = try allocator.alloc(u8, encoded.len / 2);
    for (result, 0..) |*out, index| {
        const high = hexDigit(encoded[index * 2]) orelse return error.InvalidHex;
        const low = hexDigit(encoded[index * 2 + 1]) orelse return error.InvalidHex;
        out.* = (high << 4) | low;
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

fn encodeHex(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, input.len * 2);
    const digits = "0123456789abcdef";
    for (input, 0..) |byte, index| {
        result[index * 2] = digits[byte >> 4];
        result[index * 2 + 1] = digits[byte & 0x0f];
    }
    return result;
}

fn optionalInteger(value: std.json.Value) !?i64 {
    return switch (value) {
        .null => null,
        else => try integer(value),
    };
}

fn parseSemantic(allocator: std.mem.Allocator, input: []const u8) !Semantic {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidInput,
    };
    try rejectUnknown(root, &.{ "schema", "fixture", "seed", "entries", "senses", "concepts", "relations", "metadata" });
    if (try integer(try objectField(root, "schema")) != schema_version) return error.UnsupportedSemanticSchema;
    const fixture = try string(try objectField(root, "fixture"));
    const seed = try integer(try objectField(root, "seed"));
    _ = try objectField(root, "metadata");

    const entry_values = try array(try objectField(root, "entries"));
    const entries = try allocator.alloc(Entry, entry_values.len);
    for (entry_values, 0..) |value, index| {
        const object = switch (value) {
            .object => |item| item,
            else => return error.InvalidInput,
        };
        try rejectUnknown(object, &.{ "id", "key", "definition_hex", "language", "senses", "concepts", "homograph" });
        const sense_values = try array(try objectField(object, "senses"));
        const senses = try allocator.alloc(i64, sense_values.len);
        for (sense_values, 0..) |sense, sense_index| senses[sense_index] = try integer(sense);
        const concept_values = try array(try objectField(object, "concepts"));
        const concepts = try allocator.alloc(i64, concept_values.len);
        for (concept_values, 0..) |concept, concept_index| concepts[concept_index] = try integer(concept);
        entries[index] = .{
            .id = try integer(try objectField(object, "id")),
            .key = try string(try objectField(object, "key")),
            .definition = try decodeHex(allocator, try string(try objectField(object, "definition_hex"))),
            .language = try string(try objectField(object, "language")),
            .senses = senses,
            .concepts = concepts,
            .homograph = try boolean(try objectField(object, "homograph")),
        };
    }

    const sense_values = try array(try objectField(root, "senses"));
    const senses = try allocator.alloc(Sense, sense_values.len);
    for (sense_values, 0..) |value, index| {
        const object = switch (value) {
            .object => |item| item,
            else => return error.InvalidInput,
        };
        try rejectUnknown(object, &.{ "id", "entry", "language", "concept", "definition_hex" });
        senses[index] = .{
            .id = try integer(try objectField(object, "id")),
            .entry = try integer(try objectField(object, "entry")),
            .language = try string(try objectField(object, "language")),
            .concept = try optionalInteger(try objectField(object, "concept")),
            .definition = try decodeHex(allocator, try string(try objectField(object, "definition_hex"))),
        };
    }

    const concept_values = try array(try objectField(root, "concepts"));
    const concepts = try allocator.alloc(Concept, concept_values.len);
    for (concept_values, 0..) |value, index| {
        const object = switch (value) {
            .object => |item| item,
            else => return error.InvalidInput,
        };
        try rejectUnknown(object, &.{ "id", "label", "members" });
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
    const relation_rows = try allocator.alloc(SemanticRelation, relation_values.len);
    for (relation_values, 0..) |value, index| {
        const object = switch (value) {
            .object => |item| item,
            else => return error.InvalidInput,
        };
        try rejectUnknown(object, &.{ "source", "predicate", "target", "asserted_by", "certainty" });
        relation_rows[index] = .{
            .source = try integer(try objectField(object, "source")),
            .predicate = try string(try objectField(object, "predicate")),
            .target = try integer(try objectField(object, "target")),
            .asserted_by = try string(try objectField(object, "asserted_by")),
            .certainty = try string(try objectField(object, "certainty")),
        };
    }
    const semantic = Semantic{ .fixture = fixture, .seed = seed, .entries = entries, .senses = senses, .concepts = concepts, .relations = relation_rows };
    try validateSemantic(semantic);
    return semantic;
}

fn findEntry(semantic: Semantic, id: i64) ?usize {
    for (semantic.entries, 0..) |entry, index| if (entry.id == id) return index;
    return null;
}

fn findSense(semantic: Semantic, id: i64) ?usize {
    for (semantic.senses, 0..) |sense, index| if (sense.id == id) return index;
    return null;
}

fn findConcept(semantic: Semantic, id: i64) ?usize {
    for (semantic.concepts, 0..) |concept, index| if (concept.id == id) return index;
    return null;
}

fn sameIds(left: []const i64, right: []const i64) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}

fn validateSemantic(semantic: Semantic) !void {
    for (semantic.entries, 0..) |entry, index| {
        for (semantic.entries[0..index]) |prior| if (entry.id == prior.id) return error.DuplicateEntryId;
    }
    for (semantic.senses, 0..) |sense, index| {
        for (semantic.senses[0..index]) |prior| if (sense.id == prior.id) return error.DuplicateSenseId;
        if (findEntry(semantic, sense.entry) == null) return error.MissingEntry;
        if (sense.concept) |concept| if (findConcept(semantic, concept) == null) return error.MissingConcept;
    }
    for (semantic.concepts, 0..) |concept, index| {
        for (semantic.concepts[0..index]) |prior| if (concept.id == prior.id) return error.DuplicateConceptId;
        for (concept.members, 0..) |member, member_index| {
            if (findSense(semantic, member) == null) return error.MissingSense;
            for (concept.members[0..member_index]) |prior| if (member == prior) return error.DuplicateMembership;
        }
    }
    for (semantic.entries) |entry| {
        var listed_senses = std.ArrayList(i64).empty;
        defer listed_senses.deinit(std.heap.page_allocator);
        var listed_concepts = std.ArrayList(i64).empty;
        defer listed_concepts.deinit(std.heap.page_allocator);
        for (semantic.senses) |sense| if (sense.entry == entry.id) {
            try listed_senses.append(std.heap.page_allocator, sense.id);
            if (sense.concept) |concept| try listed_concepts.append(std.heap.page_allocator, concept);
        };
        if (!sameIds(entry.senses, listed_senses.items) or !sameIds(entry.concepts, listed_concepts.items)) return error.InverseMismatch;
    }
    for (semantic.concepts) |concept| {
        var listed = std.ArrayList(i64).empty;
        defer listed.deinit(std.heap.page_allocator);
        for (semantic.senses) |sense| if (sense.concept) |sense_concept| if (sense_concept == concept.id) try listed.append(std.heap.page_allocator, sense.id);
        if (!sameIds(concept.members, listed.items)) return error.InverseMismatch;
    }
    for (semantic.relations) |relation| {
        if (findSense(semantic, relation.source) == null or findSense(semantic, relation.target) == null) return error.MissingSense;
        if (std.mem.eql(u8, relation.predicate, generated_predicate)) return error.ReservedPredicate;
    }
}

fn valueId(index: usize) !model.ValueId {
    return model.ValueId.fromIndex(index) catch error.InputTooLarge;
}

fn appendValue(values: *std.ArrayList(model.ValueInput), allocator: std.mem.Allocator, value: model.ValueInput) !model.ValueId {
    const id = try valueId(values.items.len);
    try values.append(allocator, value);
    return id;
}

fn appendProduct(values: *std.ArrayList(model.ValueInput), allocator: std.mem.Allocator, label: []const u8, names: []const []const u8, ids: []const model.ValueId) !model.ValueId {
    if (names.len != ids.len) return error.InputShape;
    const fields = try allocator.alloc(model.ValueFieldInput, names.len);
    for (fields, names, ids) |*field, name, id| field.* = .{ .name = name, .value = id };
    return appendValue(values, allocator, .{ .product = .{ .type_label = label, .fields = fields } });
}

fn ref(comptime kind: model.Kind, index: usize) !model.Ref(kind) {
    const rank = std.math.cast(u32, index) orelse return error.InputTooLarge;
    return @enumFromInt(rank);
}

fn anyRef(comptime kind: model.Kind, index: usize) !model.AnyRef {
    return @unionInit(model.AnyRef, @tagName(kind), try ref(kind, index));
}

fn targetRef(comptime kind: model.Kind, index: usize) !model.TargetInput {
    return .{ .record = try anyRef(kind, index) };
}

fn predicateIndex(names: []const []const u8, wanted: []const u8) ?usize {
    for (names, 0..) |name, index| if (std.mem.eql(u8, name, wanted)) return index;
    return null;
}

fn predicateId(index: usize) !model.PredicateId {
    return model.PredicateId.fromIndex(index) catch error.InputTooLarge;
}

fn buildInput(allocator: std.mem.Allocator, semantic: Semantic) !NativeInput {
    var values = std.ArrayList(model.ValueInput).empty;
    var records = std.ArrayList(model.RecordInput).empty;
    var keys = std.ArrayList(model.KeyInput).empty;
    var predicates = std.ArrayList(model.PredicateInput).empty;
    var predicate_names = std.ArrayList([]const u8).empty;
    var facts = std.ArrayList(model.FactInput).empty;

    try predicate_names.append(allocator, generated_predicate);
    try predicates.append(allocator, .{ .name = generated_predicate });
    for (semantic.relations) |relation| {
        if (std.mem.eql(u8, relation.predicate, generated_predicate)) return error.ReservedPredicate;
        if (predicateIndex(predicate_names.items, relation.predicate) == null) {
            try predicate_names.append(allocator, relation.predicate);
            try predicates.append(allocator, .{ .name = relation.predicate });
        }
    }

    for (semantic.entries) |entry| {
        const definition = try appendValue(&values, allocator, .{ .string = entry.definition });
        const homograph = try appendValue(&values, allocator, .{ .boolean = entry.homograph });
        const feature = try appendProduct(&values, allocator, "entry", &.{ "definition", "homograph" }, &.{ definition, homograph });
        try records.append(allocator, .{ .entry = .{
            .language = entry.language,
            .features = feature,
            .external_id = .{ .numeric = entry.id },
        } });
    }
    for (semantic.senses) |sense| {
        const definition = try appendValue(&values, allocator, .{ .string = sense.definition });
        const feature = try appendProduct(&values, allocator, "sense", &.{"definition"}, &.{definition});
        try records.append(allocator, .{ .sense = .{
            .language = sense.language,
            .features = feature,
            .external_id = .{ .numeric = sense.id },
        } });
    }
    for (semantic.concepts) |concept| try records.append(allocator, .{ .concept = .{
        .label = concept.label,
        .external_id = .{ .numeric = concept.id },
    } });

    for (semantic.entries, 0..) |entry, index| try keys.append(allocator, .{ .headword = .{ .key = entry.key, .entry = try ref(.entry, index) } });

    for (semantic.senses, 0..) |sense, index| {
        const entry_index = findEntry(semantic, sense.entry) orelse return error.MissingEntry;
        try facts.append(allocator, .{ .relation = .{
            .subject = try targetRef(.sense, index),
            .predicate = @enumFromInt(0),
            .object = try targetRef(.entry, entry_index),
        } });
    }
    for (semantic.senses, 0..) |sense, index| if (sense.concept) |concept_id| {
        const concept_index = findConcept(semantic, concept_id) orelse return error.MissingConcept;
        try facts.append(allocator, .{ .membership = .{
            .member = try anyRef(.sense, index),
            .target = .{ .concept = try ref(.concept, concept_index) },
        } });
    };
    for (semantic.relations) |relation| {
        const source = findSense(semantic, relation.source) orelse return error.MissingSense;
        const target = findSense(semantic, relation.target) orelse return error.MissingSense;
        const predicate = predicateIndex(predicate_names.items, relation.predicate) orelse return error.MissingPredicate;
        const asserted_by = try appendValue(&values, allocator, .{ .symbol = relation.asserted_by });
        const certainty = try appendValue(&values, allocator, .{ .symbol = relation.certainty });
        const properties = try appendProduct(&values, allocator, "claim", &.{ "asserted_by", "certainty_token" }, &.{ asserted_by, certainty });
        try facts.append(allocator, .{ .relation = .{
            .subject = try targetRef(.sense, source),
            .predicate = try predicateId(predicate),
            .object = try targetRef(.sense, target),
            .qualifiers = .{ .properties = properties },
        } });
    }

    return .{
        .input = .{
            .documents = &.{},
            .records = try records.toOwnedSlice(allocator),
            .keys = try keys.toOwnedSlice(allocator),
            .facts = try facts.toOwnedSlice(allocator),
            .predicates = try predicates.toOwnedSlice(allocator),
            .values = try values.toOwnedSlice(allocator),
        },
        .predicate_names = try predicate_names.toOwnedSlice(allocator),
    };
}

fn writeArtifact(init: std.process.Init, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(init.io, path, .{ .truncate = true });
    defer file.close(init.io);
    var buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn readFile(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(max_input_bytes));
}

fn loadBook(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8) !Loaded {
    const artifact: []const u8 = try readFile(init, allocator, path);
    const opened = try lex5.book.open(artifact);
    const book = try opened.validate(allocator);
    return .{ .artifact = artifact, .book = book };
}

fn recordCount(book: *const lex5.book.Book([]const u8), domain: model.Domain) !usize {
    return std.math.cast(usize, try book.domains.countForVerify(domain)) orelse return error.InputTooLarge;
}

fn addCapacity(value: *usize, addition: usize) !void {
    value.* = std.math.add(usize, value.*, addition) catch return error.InputTooLarge;
}

fn keyHitCapacity(book: *const lex5.book.Book([]const u8)) !usize {
    var capacity: usize = 0;
    for (0..book.keys.rows.row_count) |index| {
        const row = try book.keys.select(index);
        switch (row.origin) {
            .headword => try addCapacity(&capacity, 1),
            .form => {
                var targets = try book.keys.targets.cursor(index);
                while (try targets.nextRun()) |run| {
                    try addCapacity(&capacity, @intFromEnum(run.hi) - @intFromEnum(run.lo));
                }
            },
        }
    }
    return capacity;
}

fn relationTextCapacity(book: *const lex5.book.Book([]const u8)) !usize {
    var capacity: usize = 1;
    const fact_count = try recordCount(book, .fact);
    for (0..fact_count) |fact_index| {
        const fact = try book.fact(@enumFromInt(@as(u32, @intCast(fact_index))));
        const relation = switch (fact) {
            .relation => |value| value,
            .membership => continue,
        };
        if (@intFromEnum(relation.predicate) == 0) continue;
        const predicate = try relationPredicate(book, relation.predicate);
        try addCapacity(&capacity, try predicate.byteLength());
        const properties = relation.qualifiers.properties orelse return error.MissingProperty;
        const asserted_by = try propertyText(book, properties, "asserted_by");
        const certainty = try propertyText(book, properties, "certainty_token");
        try addCapacity(&capacity, try asserted_by.byteLength());
        try addCapacity(&capacity, try certainty.byteLength());
    }
    return capacity;
}

fn entryRankForId(book: *const lex5.book.Book([]const u8), id: i64) !usize {
    const rank = (try book.recordByIdentity(.entry, .{ .numeric = id })) orelse return error.UnknownEntry;
    return @intFromEnum(rank);
}

fn senseRankForId(book: *const lex5.book.Book([]const u8), id: i64) !usize {
    const rank = (try book.recordByIdentity(.sense, .{ .numeric = id })) orelse return error.UnknownSense;
    return @intFromEnum(rank);
}

fn conceptRankForId(book: *const lex5.book.Book([]const u8), id: i64) !usize {
    const rank = (try book.recordByIdentity(.concept, .{ .numeric = id })) orelse return error.UnknownConcept;
    return @intFromEnum(rank);
}

fn projectedEntryId(identities: anytype, origin: lex5.keys.Origin) !i64 {
    const identity = switch (origin) {
        .headword => |rank| (try identities.at(rank)) orelse return error.MissingExternalId,
        .form => return error.UnsupportedKeyOrigin,
    };
    return switch (identity) {
        .numeric => |id| id,
        .text => error.ExpectedNumericId,
    };
}

fn exact(book: *const lex5.book.Book([]const u8), scratch: *Scratch, key: []const u8) !Result {
    const selection = try book.lookup(.{ .exact = key });
    const entries = try book.records(.entry);
    const identities = entries.project(.{.external_id});
    const origins = try selection.project(.{.origin});
    var count: usize = 0;
    while (count < origins.row_count) : (count += 1) {
        if (count >= scratch.ids.len) return error.OutputTooSmall;
        scratch.ids[count] = try projectedEntryId(&identities, try origins.at(count));
    }
    return .{ .ids = scratch.ids[0..count] };
}

fn prefixInterval(book: *const lex5.book.Book([]const u8), key: []const u8) !Result {
    const selection = try book.lookup(.{ .prefix = key });
    const range = selection.lookup.range;
    return .{ .interval = .{ .lo = range.next, .hi = range.end } };
}

fn prefixEnumerate(book: *const lex5.book.Book([]const u8), scratch: *Scratch, key: []const u8) !Result {
    const selection = try book.lookup(.{ .prefix = key });
    const lo = selection.lookup.range.next;
    const hi = selection.lookup.range.end;
    const entries = try book.records(.entry);
    const identities = entries.project(.{.external_id});
    const origins = try selection.project(.{.origin});
    var count: usize = 0;
    while (count < origins.row_count) : (count += 1) {
        if (count >= scratch.ids.len) return error.OutputTooSmall;
        scratch.ids[count] = try projectedEntryId(&identities, try origins.at(count));
    }
    if (count != hi - lo) return error.LookupRangeMismatch;
    return .{ .prefix = .{ .ids = scratch.ids[0..count], .lo = lo, .hi = hi } };
}

fn select(book: *const lex5.book.Book([]const u8), scratch: *Scratch, rank: usize) !Result {
    const row = try book.keys.select(rank);
    const entry_rank = switch (row.origin) {
        .headword => |entry| @intFromEnum(entry),
        .form => return error.UnsupportedKeyOrigin,
    };
    const key = try book.string(row.key).render(scratch.key);
    return .{ .select = .{ .id = try recordExternalId(book, .entry, entry_rank), .key = key, .rank = @intCast(rank) } };
}

fn renderValue(output: []u8, handle: anytype) ![]u8 {
    return @constCast(try handle.render(output));
}

fn recordDefinition(book: *const lex5.book.Book([]const u8), comptime kind: model.Kind, rank: usize, output: []u8) ![]u8 {
    const record = try book.record(kind, try ref(kind, rank));
    const features = record.features orelse return error.MissingDefinition;
    const definition = (try book.value(features).field("definition")) orelse return error.MissingDefinition;
    return renderValue(output, definition);
}

fn entryDefinition(book: *const lex5.book.Book([]const u8), id: i64, output: []u8) ![]u8 {
    const rank = try entryRankForId(book, id);
    return recordDefinition(book, .entry, rank, output);
}

fn entrySnippet(book: *const lex5.book.Book([]const u8), id: i64, limit: usize, output: []u8) ![]u8 {
    const rank = try entryRankForId(book, id);
    const record = try book.record(.entry, try ref(.entry, rank));
    const features = record.features orelse return error.MissingDefinition;
    const definition = (try book.value(features).field("definition")) orelse return error.MissingDefinition;
    return @constCast(try definition.snippet(output[0..@min(limit, output.len)]));
}

fn recordLanguage(book: *const lex5.book.Book([]const u8), comptime kind: model.Kind, rank: usize) !Text {
    const record = try book.record(kind, try ref(kind, rank));
    return book.string(record.language orelse return error.MissingLanguage);
}

fn recordExternalId(book: *const lex5.book.Book([]const u8), comptime kind: model.Kind, rank: usize) !i64 {
    const record = try book.record(kind, try ref(kind, rank));
    return switch (record.external_id orelse return error.MissingExternalId) {
        .numeric => |id| id,
        .text => error.ExpectedNumericId,
    };
}

fn entryHomograph(book: *const lex5.book.Book([]const u8), rank: usize, allocator: std.mem.Allocator) !bool {
    _ = allocator;
    const record = try book.record(.entry, try ref(.entry, rank));
    const features = record.features orelse return error.MissingFeatures;
    const value = (try book.value(features).field("homograph")) orelse return error.MissingHomograph;
    return switch (try value.atom()) {
        .boolean => |result| result,
        else => error.InvalidBoolean,
    };
}

fn senseDefinition(book: *const lex5.book.Book([]const u8), rank: usize, output: []u8) ![]u8 {
    return recordDefinition(book, .sense, rank, output);
}

fn memberExternalId(book: *const lex5.book.Book([]const u8), member: model.AnyRef) !i64 {
    return switch (member) {
        .sense => |rank| recordExternalId(book, .sense, @intFromEnum(rank)),
        else => error.InvalidMembership,
    };
}

fn relationPredicate(book: *const lex5.book.Book([]const u8), id: model.PredicateId) !Text {
    return book.predicateName(id);
}

fn propertyText(book: *const lex5.book.Book([]const u8), properties: model.ValueId, name: []const u8) !Text {
    const field = (try book.value(properties).field(name)) orelse return error.MissingProperty;
    return try field.text();
}

fn renderTextAlloc(allocator: std.mem.Allocator, text: Text) ![]u8 {
    const output = try allocator.alloc(u8, try text.byteLength());
    return @constCast(try text.render(output));
}

fn renderRelationText(scratch: *Scratch, text: Text) ![]const u8 {
    const length = try text.byteLength();
    const end = std.math.add(usize, scratch.relation_text_used, length) catch return error.OutputTooSmall;
    if (end > scratch.relation_text.len) return error.OutputTooSmall;
    const output = scratch.relation_text[scratch.relation_text_used..end];
    const rendered = try text.render(output);
    scratch.relation_text_used = end;
    return rendered;
}

fn relationFromFact(book: *const lex5.book.Book([]const u8), scratch: *Scratch, fact: lex5.facts.Fact) !NativeRelation {
    const relation = switch (fact) {
        .relation => |value| value,
        .membership => return error.ExpectedRelation,
    };
    const source = switch (relation.subject) {
        .record => |reference| switch (reference) {
            .sense => |rank| try recordExternalId(book, .sense, @intFromEnum(rank)),
            else => return error.InvalidRelationEndpoint,
        },
        else => return error.InvalidRelationEndpoint,
    };
    const target = switch (relation.object) {
        .record => |reference| switch (reference) {
            .sense => |rank| try recordExternalId(book, .sense, @intFromEnum(rank)),
            else => return error.InvalidRelationEndpoint,
        },
        else => return error.InvalidRelationEndpoint,
    };
    const properties = relation.qualifiers.properties orelse return error.MissingProperty;
    return .{
        .source = source,
        .predicate = try renderRelationText(scratch, try relationPredicate(book, relation.predicate)),
        .target = target,
        .asserted_by = try renderRelationText(scratch, try propertyText(book, properties, "asserted_by")),
        .certainty = try renderRelationText(scratch, try propertyText(book, properties, "certainty_token")),
    };
}

fn collectAuditMaps(book: *const lex5.book.Book([]const u8), allocator: std.mem.Allocator) !AuditMaps {
    const sense_count = try recordCount(book, .{ .record = .sense });
    const concept_count = try recordCount(book, .{ .record = .concept });
    const entry_count = try recordCount(book, .{ .record = .entry });
    const sense_entries = try allocator.alloc(?usize, sense_count);
    const sense_concepts = try allocator.alloc(?usize, sense_count);
    @memset(sense_entries, null);
    @memset(sense_concepts, null);
    const fact_count = try recordCount(book, .fact);
    for (0..fact_count) |fact_index| {
        const fact = try book.fact(@enumFromInt(@as(u32, @intCast(fact_index))));
        switch (fact) {
            .relation => |relation| {
                if (@intFromEnum(relation.predicate) != 0) continue;
                const sense_rank = switch (relation.subject) {
                    .record => |reference| switch (reference) {
                        .sense => |rank| @intFromEnum(rank),
                        else => return error.InvalidSenseEntryFact,
                    },
                    else => return error.InvalidSenseEntryFact,
                };
                const entry_rank = switch (relation.object) {
                    .record => |reference| switch (reference) {
                        .entry => |rank| @intFromEnum(rank),
                        else => return error.InvalidSenseEntryFact,
                    },
                    else => return error.InvalidSenseEntryFact,
                };
                if (sense_rank >= sense_entries.len or entry_rank >= entry_count or sense_entries[sense_rank] != null) return error.InvalidSenseEntryFact;
                sense_entries[sense_rank] = entry_rank;
            },
            .membership => |membership| {
                const sense_rank = switch (membership.member) {
                    .sense => |rank| @intFromEnum(rank),
                    else => return error.InvalidMembership,
                };
                const concept_rank = switch (membership.target) {
                    .concept => |rank| @intFromEnum(rank),
                    .interlingual => return error.InvalidMembership,
                };
                if (sense_rank >= sense_concepts.len or concept_rank >= concept_count or sense_concepts[sense_rank] != null) return error.InvalidMembership;
                sense_concepts[sense_rank] = concept_rank;
            },
        }
    }
    for (sense_entries) |entry| if (entry == null) return error.MissingSenseEntryFact;
    return .{ .sense_entries = sense_entries, .sense_concepts = sense_concepts };
}

fn nativeKeysByEntry(book: *const lex5.book.Book([]const u8), allocator: std.mem.Allocator) ![][]const u8 {
    const count = try recordCount(book, .{ .record = .entry });
    const keys = try allocator.alloc([]const u8, count);
    @memset(keys, &.{});
    const selection = try book.lookup(.{ .prefix = "" });
    var iterator = selection.iterator();
    while (try iterator.next()) |hit| switch (hit.targets) {
        .headword => |rank| {
            const index = @intFromEnum(rank);
            if (index >= keys.len or keys[index].len != 0) return error.DuplicateKeyTarget;
            keys[index] = try renderTextAlloc(allocator, hit.key);
        },
        .form => return error.UnsupportedKeyOrigin,
    };
    for (keys) |key| if (key.len == 0) return error.MissingKey;
    return keys;
}

fn nativeConceptMembers(book: *const lex5.book.Book([]const u8), scratch: *Scratch, concept_rank: usize) ![]i64 {
    var cursor = try book.claimsTo(.{ .concept = try ref(.concept, concept_rank) });
    var count: usize = 0;
    while (try cursor.nextRun()) |run| for (@intFromEnum(run.lo)..@intFromEnum(run.hi)) |fact_index| {
        const fact = try book.fact(@enumFromInt(@as(u32, @intCast(fact_index))));
        switch (fact) {
            .membership => |membership| {
                if (count >= scratch.ids.len) return error.OutputTooSmall;
                scratch.ids[count] = try memberExternalId(book, membership.member);
                count += 1;
            },
            .relation => return error.InvalidMembership,
        }
    };
    return scratch.ids[0..count];
}

fn writeAudit(init: std.process.Init, allocator: std.mem.Allocator, loaded: *const Loaded) !void {
    const maps = try collectAuditMaps(&loaded.book, allocator);
    const keys = try nativeKeysByEntry(&loaded.book, allocator);
    var scratch = try Scratch.init(&loaded.book, allocator);
    var output: std.Io.Writer.Allocating = .init(allocator);
    var json = std.json.Stringify{ .writer = &output.writer };
    try json.beginObject();

    try json.objectField("entries");
    try json.beginArray();
    const entry_count = try recordCount(&loaded.book, .{ .record = .entry });
    for (0..entry_count) |rank| {
        const definition = try recordDefinition(&loaded.book, .entry, rank, scratch.bytes);
        const definition_hex = try encodeHex(allocator, definition);
        try json.beginObject();
        try json.objectField("id");
        try json.write(try recordExternalId(&loaded.book, .entry, rank));
        try json.objectField("key");
        try json.write(keys[rank]);
        try json.objectField("definition_hex");
        try json.write(definition_hex);
        try json.objectField("language");
        try json.write(try renderTextAlloc(allocator, try recordLanguage(&loaded.book, .entry, rank)));
        try json.objectField("homograph");
        try json.write(try entryHomograph(&loaded.book, rank, allocator));
        try json.objectField("senses");
        try json.beginArray();
        for (maps.sense_entries, 0..) |sense_entry, sense_rank| if (sense_entry) |entry_rank| if (entry_rank == rank) try json.write(try recordExternalId(&loaded.book, .sense, sense_rank));
        try json.endArray();
        try json.objectField("concepts");
        try json.beginArray();
        for (maps.sense_entries, maps.sense_concepts) |sense_entry, sense_concept| if (sense_entry) |entry_rank| if (entry_rank == rank) if (sense_concept) |concept_rank| try json.write(try recordExternalId(&loaded.book, .concept, concept_rank));
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("senses");
    try json.beginArray();
    const sense_count = try recordCount(&loaded.book, .{ .record = .sense });
    for (0..sense_count) |rank| {
        const definition = try senseDefinition(&loaded.book, rank, scratch.bytes);
        const definition_hex = try encodeHex(allocator, definition);
        try json.beginObject();
        try json.objectField("id");
        try json.write(try recordExternalId(&loaded.book, .sense, rank));
        try json.objectField("entry");
        try json.write(try recordExternalId(&loaded.book, .entry, maps.sense_entries[rank] orelse return error.MissingSenseEntryFact));
        try json.objectField("language");
        try json.write(try renderTextAlloc(allocator, try recordLanguage(&loaded.book, .sense, rank)));
        try json.objectField("concept");
        if (maps.sense_concepts[rank]) |concept_rank| try json.write(try recordExternalId(&loaded.book, .concept, concept_rank)) else try json.write(null);
        try json.objectField("definition_hex");
        try json.write(definition_hex);
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("concepts");
    try json.beginArray();
    const concept_count = try recordCount(&loaded.book, .{ .record = .concept });
    for (0..concept_count) |rank| {
        const record = try loaded.book.record(.concept, try ref(.concept, rank));
        try json.beginObject();
        try json.objectField("id");
        try json.write(try recordExternalId(&loaded.book, .concept, rank));
        try json.objectField("label");
        try json.write(try renderTextAlloc(allocator, loaded.book.string(record.label orelse return error.MissingConceptLabel)));
        try json.objectField("members");
        try json.write(try nativeConceptMembers(&loaded.book, &scratch, rank));
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("relations");
    try json.beginArray();
    const fact_count = try recordCount(&loaded.book, .fact);
    for (0..fact_count) |fact_index| {
        const fact = try loaded.book.fact(@enumFromInt(@as(u32, @intCast(fact_index))));
        switch (fact) {
            .relation => |relation| if (@intFromEnum(relation.predicate) != 0) {
                const decoded = try relationFromFact(&loaded.book, &scratch, fact);
                try json.beginObject();
                try json.objectField("source");
                try json.write(decoded.source);
                try json.objectField("predicate");
                try json.write(decoded.predicate);
                try json.objectField("target");
                try json.write(decoded.target);
                try json.objectField("asserted_by");
                try json.write(decoded.asserted_by);
                try json.objectField("certainty");
                try json.write(decoded.certainty);
                try json.endObject();
            },
            .membership => {},
        }
    }
    try json.endArray();
    try json.endObject();
    try output.writer.writeByte('\n');
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout.interface.writeAll(output.written());
    try stdout.interface.flush();
}
fn conceptMembers(book: *const lex5.book.Book([]const u8), scratch: *Scratch, id: i64) !Result {
    const concept_rank = conceptRankForId(book, id) catch |err| switch (err) {
        error.UnknownConcept => return .{ .members = scratch.ids[0..0] },
        else => return err,
    };
    return .{ .members = try nativeConceptMembers(book, scratch, concept_rank) };
}

fn translations(book: *const lex5.book.Book([]const u8), scratch: *Scratch, id: i64, language: []const u8) !Result {
    const sense_rank = senseRankForId(book, id) catch |err| switch (err) {
        error.UnknownSense => return .{ .members = scratch.ids[0..0] },
        else => return err,
    };
    var concept_rank: ?usize = null;
    var from = try book.claimsFrom(.{ .sense = try ref(.sense, sense_rank) });
    while (try from.nextRun()) |run| for (@intFromEnum(run.lo)..@intFromEnum(run.hi)) |fact_index| {
        const fact = try book.fact(@enumFromInt(@as(u32, @intCast(fact_index))));
        switch (fact) {
            .membership => |membership| switch (membership.target) {
                .concept => |rank| {
                    if (concept_rank != null) return error.DuplicateConceptMembership;
                    concept_rank = @intFromEnum(rank);
                },
                .interlingual => {},
            },
            .relation => {},
        }
    };
    const concept = concept_rank orelse return .{ .members = scratch.ids[0..0] };
    var to = try book.claimsTo(.{ .concept = try ref(.concept, concept) });
    var count: usize = 0;
    while (try to.nextRun()) |run| for (@intFromEnum(run.lo)..@intFromEnum(run.hi)) |fact_index| {
        const fact = try book.fact(@enumFromInt(@as(u32, @intCast(fact_index))));
        const member = switch (fact) {
            .membership => |membership| membership.member,
            .relation => return error.InvalidMembership,
        };
        const member_rank = switch (member) {
            .sense => |rank| @intFromEnum(rank),
            else => return error.InvalidMembership,
        };
        const member_id = try recordExternalId(book, .sense, member_rank);
        if (member_id == id) continue;
        const member_language = try recordLanguage(book, .sense, member_rank);
        if (language.len != 0 and !(try member_language.eqlBytes(language))) continue;
        if (count >= scratch.ids.len) return error.OutputTooSmall;
        scratch.ids[count] = member_id;
        count += 1;
    };
    return .{ .members = scratch.ids[0..count] };
}

fn relations(book: *const lex5.book.Book([]const u8), scratch: *Scratch, id: i64, wanted: []const u8) !Result {
    const sense_rank = senseRankForId(book, id) catch |err| switch (err) {
        error.UnknownSense => return .{ .relations = scratch.relations[0..0] },
        else => return err,
    };
    scratch.relation_text_used = 0;
    var cursor = try book.claimsFrom(.{ .sense = try ref(.sense, sense_rank) });
    var count: usize = 0;
    while (try cursor.nextRun()) |run| for (@intFromEnum(run.lo)..@intFromEnum(run.hi)) |fact_index| {
        const fact = try book.fact(@enumFromInt(@as(u32, @intCast(fact_index))));
        const relation = switch (fact) {
            .relation => |value| value,
            .membership => continue,
        };
        const predicate = try relationPredicate(book, relation.predicate);
        if (try predicate.eqlBytes(generated_predicate)) continue;
        if (wanted.len != 0 and !(try predicate.eqlBytes(wanted))) continue;
        if (count >= scratch.relations.len) return error.OutputTooSmall;
        scratch.relations[count] = try relationFromFact(book, scratch, fact);
        count += 1;
    };
    return .{ .relations = scratch.relations[0..count] };
}

fn writeResult(json: *std.json.Stringify, allocator: std.mem.Allocator, result: Result) !void {
    switch (result) {
        .ids => |ids| {
            try json.beginObject();
            try json.objectField("ids");
            try json.write(ids);
            try json.objectField("cardinality");
            try json.write(ids.len);
            try json.endObject();
        },
        .prefix => |prefix| {
            try json.beginObject();
            try json.objectField("ids");
            try json.write(prefix.ids);
            try json.objectField("lo");
            try json.write(prefix.lo);
            try json.objectField("hi");
            try json.write(prefix.hi);
            try json.objectField("cardinality");
            try json.write(prefix.hi - prefix.lo);
            try json.endObject();
        },
        .interval => |interval| {
            try json.beginObject();
            try json.objectField("lo");
            try json.write(interval.lo);
            try json.objectField("hi");
            try json.write(interval.hi);
            try json.objectField("cardinality");
            try json.write(interval.hi - interval.lo);
            try json.endObject();
        },
        .select => |selection| {
            try json.beginObject();
            try json.objectField("id");
            try json.write(selection.id);
            try json.objectField("key");
            try json.write(selection.key);
            try json.objectField("rank");
            try json.write(selection.rank);
            try json.endObject();
        },
        .bytes => |bytes| {
            try json.beginObject();
            try json.objectField("bytes_hex");
            try json.write(try encodeHex(allocator, bytes));
            try json.objectField("bytes");
            try json.write(bytes.len);
            try json.endObject();
        },
        .members => |members| {
            try json.beginObject();
            try json.objectField("members");
            try json.write(members);
            try json.objectField("cardinality");
            try json.write(members.len);
            try json.endObject();
        },
        .relations => |relations_value| {
            try json.beginObject();
            try json.objectField("relations");
            try json.beginArray();
            for (relations_value) |relation| {
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
            try json.objectField("cardinality");
            try json.write(relations_value.len);
            try json.endObject();
        },
    }
}

fn writeEnvelope(
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

fn writeError(init: std.process.Init, writer: *std.Io.Writer, allocator: std.mem.Allocator, request_id: i64, sample: i64, error_value: anyerror) !void {
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
    try json.write(@errorName(error_value));
    try json.endObject();
    try output.writer.writeByte('\n');
    try writer.writeAll(output.written());
    try writer.flush();
    _ = init;
}

fn writeReady(init: std.process.Init, writer: *std.Io.Writer, allocator: std.mem.Allocator, artifact_bytes: usize, book_bytes: usize, scratch: *const Scratch) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    var json = std.json.Stringify{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("protocol");
    try json.write(protocol);
    try json.objectField("event");
    try json.write("ready");
    try json.objectField("artifact_bytes");
    try json.write(artifact_bytes);
    try json.objectField("book_bytes");
    try json.write(book_bytes);
    try json.objectField("scratch_ids");
    try json.write(scratch.ids.len);
    try json.objectField("scratch_relations");
    try json.write(scratch.relations.len);
    try json.objectField("scratch_bytes");
    try json.write(scratch.bytes.len);
    try json.objectField("scratch_key");
    try json.write(scratch.key.len);
    try json.objectField("scratch_relation_text");
    try json.write(scratch.relation_text.len);
    try json.endObject();
    try output.writer.writeByte('\n');
    try writer.writeAll(output.written());
    try writer.flush();
    _ = init;
}

fn requestString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.MissingField;
    return string(value);
}

fn requestInt(object: std.json.ObjectMap, name: []const u8) !i64 {
    const value = object.get(name) orelse return error.MissingField;
    return integer(value);
}

fn rejectAnswerLeak(object: std.json.ObjectMap) !void {
    const forbidden = [_][]const u8{ "expected", "oracle", "answers", "query_checksum", "schedule", "workload", "category" };
    for (forbidden) |name| {
        if (object.get(name) != null) return error.ExpectedAnswerOnWire;
    }
}

fn requestFieldAllowed(operation: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, name, "protocol") or std.mem.eql(u8, name, "request_id") or
        std.mem.eql(u8, name, "sample") or std.mem.eql(u8, name, "op") or
        std.mem.eql(u8, name, "timing_mode")) return true;
    if (std.mem.eql(u8, operation, "exact") or std.mem.eql(u8, operation, "prefix_interval") or
        std.mem.eql(u8, operation, "prefix_enumerate")) return std.mem.eql(u8, name, "key");
    if (std.mem.eql(u8, operation, "select") or std.mem.eql(u8, operation, "render") or
        std.mem.eql(u8, operation, "concept_members")) return std.mem.eql(u8, name, "id");
    if (std.mem.eql(u8, operation, "snippet")) return std.mem.eql(u8, name, "id") or std.mem.eql(u8, name, "limit");
    if (std.mem.eql(u8, operation, "translations")) return std.mem.eql(u8, name, "id") or std.mem.eql(u8, name, "language");
    if (std.mem.eql(u8, operation, "relations")) return std.mem.eql(u8, name, "id") or std.mem.eql(u8, name, "predicate");
    return false;
}

fn rejectUnexpectedFields(object: std.json.ObjectMap, operation: []const u8) !void {
    for (object.keys()) |name| if (!requestFieldAllowed(operation, name)) return error.UnexpectedRequestField;
}

const HandledRequest = struct {
    result: Result,
    timed: bool,
    elapsed_ns: u64,
    request_id: i64,
    sample: i64,
};

fn handleRequest(loaded: *const Loaded, scratch: *Scratch, object: std.json.ObjectMap) !HandledRequest {
    try rejectAnswerLeak(object);
    if (!std.mem.eql(u8, try requestString(object, "protocol"), protocol)) return error.InvalidProtocol;
    const operation = try requestString(object, "op");
    try rejectUnexpectedFields(object, operation);
    const request_id = try requestInt(object, "request_id");
    const sample = try requestInt(object, "sample");
    const timed = if (object.get("timing_mode")) |value| blk: {
        if (!std.mem.eql(u8, try string(value), "reader_self")) return error.InvalidTimingMode;
        break :blk true;
    } else false;
    const key = if (std.mem.eql(u8, operation, "exact") or
        std.mem.eql(u8, operation, "prefix_interval") or
        std.mem.eql(u8, operation, "prefix_enumerate")) try requestString(object, "key") else "";
    const raw_id = if (std.mem.eql(u8, operation, "select") or
        std.mem.eql(u8, operation, "render") or
        std.mem.eql(u8, operation, "snippet") or
        std.mem.eql(u8, operation, "concept_members") or
        std.mem.eql(u8, operation, "translations") or
        std.mem.eql(u8, operation, "relations")) try requestInt(object, "id") else 0;
    const select_rank = if (std.mem.eql(u8, operation, "select"))
        std.math.cast(usize, raw_id) orelse return error.InvalidInput
    else
        0;
    const limit = if (std.mem.eql(u8, operation, "snippet"))
        std.math.cast(usize, try requestInt(object, "limit")) orelse return error.InvalidInput
    else
        0;
    const language = if (std.mem.eql(u8, operation, "translations")) try requestString(object, "language") else "";
    const predicate = if (std.mem.eql(u8, operation, "relations")) try requestString(object, "predicate") else "";
    const started = if (timed) std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds else 0;
    const result = blk: {
        if (std.mem.eql(u8, operation, "exact")) break :blk try exact(&loaded.book, scratch, key);
        if (std.mem.eql(u8, operation, "prefix_interval")) break :blk try prefixInterval(&loaded.book, key);
        if (std.mem.eql(u8, operation, "prefix_enumerate")) break :blk try prefixEnumerate(&loaded.book, scratch, key);
        if (std.mem.eql(u8, operation, "select")) break :blk try select(&loaded.book, scratch, select_rank);
        if (std.mem.eql(u8, operation, "render") or std.mem.eql(u8, operation, "snippet")) {
            const rendered = if (std.mem.eql(u8, operation, "snippet"))
                try entrySnippet(&loaded.book, raw_id, limit, scratch.bytes)
            else
                try entryDefinition(&loaded.book, raw_id, scratch.bytes);
            break :blk Result{ .bytes = rendered };
        }
        if (std.mem.eql(u8, operation, "concept_members")) break :blk try conceptMembers(&loaded.book, scratch, raw_id);
        if (std.mem.eql(u8, operation, "translations")) break :blk try translations(&loaded.book, scratch, raw_id, language);
        if (std.mem.eql(u8, operation, "relations")) break :blk try relations(&loaded.book, scratch, raw_id, predicate);
        return error.UnknownOperation;
    };
    const elapsed_ns = if (timed) blk: {
        const finished = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
        break :blk if (finished >= started) @as(u64, @intCast(finished - started)) else 0;
    } else 0;
    return .{ .result = result, .timed = timed, .elapsed_ns = elapsed_ns, .request_id = request_id, .sample = sample };
}

fn runServer(init: std.process.Init, allocator: std.mem.Allocator, artifact_path: []const u8) !void {
    const loaded = try loadBook(init, allocator, artifact_path);
    var scratch = try Scratch.init(&loaded.book, allocator);
    var request_arena = std.heap.ArenaAllocator.init(allocator);
    defer request_arena.deinit();
    var input_buffer: [64 * 1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(init.io, &input_buffer);
    var output_buffer: [64 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    try writeReady(init, &writer.interface, allocator, loaded.artifact.len, @sizeOf(@TypeOf(loaded.book)), &scratch);
    while (try reader.interface.takeDelimiter('\n')) |line| {
        _ = request_arena.reset(.retain_capacity);
        if (line.len == 0) continue;
        if (line.len > max_line_bytes) return error.RequestTooLarge;
        const request_allocator = request_arena.allocator();
        const parsed = try std.json.parseFromSlice(std.json.Value, request_allocator, line, .{});
        const object = switch (parsed.value) {
            .object => |value| value,
            else => return error.InvalidRequest,
        };
        const request_id = if (object.get("request_id")) |value| integer(value) catch -1 else -1;
        const sample = if (object.get("sample")) |value| integer(value) catch -1 else -1;
        const response = handleRequest(&loaded, &scratch, object) catch |err| {
            try writeError(init, &writer.interface, request_allocator, request_id, sample, err);
            _ = request_arena.reset(.retain_capacity);
            continue;
        };
        try writeEnvelope(
            init,
            &writer.interface,
            request_allocator,
            response.request_id,
            response.sample,
            response.result,
            response.timed,
            response.elapsed_ns,
        );
        _ = request_arena.reset(.retain_capacity);
    }
}

fn buildArtifact(init: std.process.Init, allocator: std.mem.Allocator, semantic_path: []const u8, output_path: []const u8) !void {
    const semantic_bytes = try readFile(init, allocator, semantic_path);
    const semantic = try parseSemantic(allocator, semantic_bytes);
    const native_input = try buildInput(allocator, semantic);
    var owned = try lex5.book.build(allocator, native_input.input);
    defer owned.deinit();
    try writeArtifact(init, output_path, owned.bytes);
}

fn verifyArtifact(init: std.process.Init, allocator: std.mem.Allocator, artifact_path: []const u8) !void {
    _ = try loadBook(init, allocator, artifact_path);
}

const Config = struct {
    mode: enum { build, verify, server, audit } = .verify,
    semantic: ?[]const u8 = null,
    artifact: ?[]const u8 = null,
    output: ?[]const u8 = null,
};

fn parseConfig(args: std.process.Args) !Config {
    var config = Config{};
    var selected: usize = 0;
    var iterator = std.process.Args.Iterator.init(args);
    _ = iterator.next();
    while (iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bench5-build")) {
            config.mode = .build;
            selected += 1;
        } else if (std.mem.eql(u8, arg, "--bench5-verify")) {
            config.mode = .verify;
            selected += 1;
        } else if (std.mem.eql(u8, arg, "--bench5-server")) {
            config.mode = .server;
            selected += 1;
        } else if (std.mem.eql(u8, arg, "--bench5-audit")) {
            config.mode = .audit;
            selected += 1;
        } else if (std.mem.eql(u8, arg, "--semantic-input")) {
            config.semantic = iterator.next() orelse return error.MissingSemanticInput;
        } else if (std.mem.eql(u8, arg, "--artifact")) {
            config.artifact = iterator.next() orelse return error.MissingArtifact;
        } else if (std.mem.eql(u8, arg, "--output")) {
            config.output = iterator.next() orelse return error.MissingOutput;
        } else return error.InvalidArgument;
    }
    if (selected != 1) return error.InvalidArgument;
    switch (config.mode) {
        .build => {
            if (config.semantic == null or config.output == null or config.artifact != null) return error.InvalidArgument;
        },
        .verify, .server, .audit => {
            if (config.artifact == null or config.semantic != null or config.output != null) return error.InvalidArgument;
        },
    }
    return config;
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config = try parseConfig(init.minimal.args);
    switch (config.mode) {
        .build => try buildArtifact(init, allocator, config.semantic orelse return error.MissingSemanticInput, config.output orelse return error.MissingOutput),
        .verify => _ = try loadBook(init, allocator, config.artifact orelse return error.MissingArtifact),
        .server => try runServer(init, allocator, config.artifact orelse return error.MissingArtifact),
        .audit => {
            const loaded = try loadBook(init, allocator, config.artifact orelse return error.MissingArtifact);
            try writeAudit(init, allocator, &loaded);
        },
    }
}
