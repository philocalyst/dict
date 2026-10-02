//! Native workloads for the experimental lexical page representation.
//!
//! `rich` is a synthetic linguistic stress workload, not a natural dictionary
//! compression claim. It reuses common feature bundles, senses, inline prose,
//! and analysis constituents while varying each entry's lexical structure.
//! `naturalBytes` preserves the established three-column hex projection; its
//! source payload is deliberately one exact definition, not parsed lexical XML.
const std = @import("std");
const lex = @import("lex6");
const model = lex.model;

pub const OwnedEntries = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const model.Entry,

    pub fn deinit(self: *OwnedEntries) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const Family = struct {
    language: []const u8,
    script: []const u8,
    surface: []const u8,
    phonetic: []const u8,
    definition: []const u8,
    example: []const u8,
    gloss: []const u8,
};

const families = [_]Family{
    .{ .language = "en", .script = "Latn", .surface = "reconsidered", .phonetic = "ˌriːkənˈsɪdəd", .definition = "to examine a previous judgement again", .example = "She reconsidered the proposal after the discussion.", .gloss = "think again" },
    .{ .language = "fr", .script = "Latn", .surface = "maisons", .phonetic = "mɛ.zɔ̃", .definition = "bâtiments destinés à l'habitation", .example = "Les maisons bordent la petite rue.", .gloss = "houses" },
    .{ .language = "tr", .script = "Latn", .surface = "evlerimizden", .phonetic = "evleɾimizden", .definition = "birden çok evimizden ayrılmayı belirten biçim", .example = "Evlerimizden birlikte çıktık.", .gloss = "from our houses" },
    .{ .language = "ar", .script = "Arab", .surface = "كَتَبَ", .phonetic = "kataba", .definition = "رسم حروفًا لإثبات كلام أو خبر", .example = "كَتَبَ الطالب رسالة قصيرة.", .gloss = "he wrote" },
    .{ .language = "ja", .script = "Jpan", .surface = "取り戻す", .phonetic = "toɾimodosɯ", .definition = "失った物や状態を再び得る", .example = "彼女は落ち着きを取り戻した。", .gloss = "regain" },
    .{ .language = "zh-Hans", .script = "Hans", .surface = "图书馆", .phonetic = "tʰu˧˥ ʂu˥ kwan˨˩˦", .definition = "收藏图书并供人阅读和借阅的机构", .example = "我们在图书馆查阅资料。", .gloss = "library" },
    .{ .language = "hi", .script = "Deva", .surface = "किताबें", .phonetic = "kɪt̪aːbẽː", .definition = "पढ़ने के लिए लिखी और बाँधी हुई पुस्तकें", .example = "मेज़ पर कई किताबें रखी हैं।", .gloss = "books" },
    .{ .language = "de", .script = "Latn", .surface = "nimmt heute teil", .phonetic = "nɪmt ˈhɔʏtə taɪl", .definition = "sich an einer gemeinsamen Tätigkeit beteiligen", .example = "Sie nimmt heute an der Besprechung teil.", .gloss = "takes part today" },
};

const noun_features: []const model.Feature = &.{
    .{ .name = .{ .namespace = "urn:linguistics:ud", .local = "UPOS" }, .value = .{ .symbol = .{ .namespace = "urn:linguistics:ud", .local = "NOUN" } } },
    .{ .name = .{ .namespace = "urn:linguistics:ud", .local = "Number" }, .value = .{ .symbol = .{ .namespace = "urn:linguistics:ud", .local = "Plur" } } },
};
const verb_features: []const model.Feature = &.{
    .{ .name = .{ .namespace = "urn:linguistics:ud", .local = "UPOS" }, .value = .{ .symbol = .{ .namespace = "urn:linguistics:ud", .local = "VERB" } } },
    .{ .name = .{ .namespace = "urn:linguistics:ud", .local = "VerbForm" }, .value = .{ .symbol = .{ .namespace = "urn:linguistics:ud", .local = "Fin" } } },
};
fn ud(comptime name: []const u8, comptime value_: []const u8) model.Feature {
    return .{ .name = .{ .namespace = "urn:linguistics:ud", .local = name }, .value = .{ .symbol = .{ .namespace = "urn:linguistics:ud", .local = value_ } } };
}
const family_features = [_][]const model.Feature{
    &.{ verb_features[0], verb_features[1], ud("Tense", "Past") },
    &.{ noun_features[0], noun_features[1], ud("Gender", "Fem") },
    &.{ noun_features[0], noun_features[1], ud("Case", "Abl"), .{ .name = .{ .namespace = "urn:linguistics:ud:possessor", .local = "Person" }, .value = .{ .integer = 1 } }, .{ .name = .{ .namespace = "urn:linguistics:ud:possessor", .local = "Number" }, .value = .{ .symbol = .{ .namespace = "urn:linguistics:ud", .local = "Plur" } } } },
    &.{ verb_features[0], verb_features[1], ud("Tense", "Past"), .{ .name = .{ .namespace = "urn:linguistics:ud", .local = "Person" }, .value = .{ .integer = 3 } }, ud("Gender", "Masc"), ud("Number", "Sing") },
    &.{ verb_features[0], ud("VerbForm", "Inf") },
    &.{noun_features[0]},
    &.{ noun_features[0], noun_features[1], ud("Gender", "Fem") },
    &.{ verb_features[0], verb_features[1], ud("Tense", "Pres"), .{ .name = .{ .namespace = "urn:linguistics:ud", .local = "Person" }, .value = .{ .integer = 3 } }, ud("Number", "Sing") },
};
const plural: model.Item = .{ .grammar = noun_features[1] };
const repeated_note: model.Item = .{ .note = .{ .content = &.{.{ .text = "The evidence supports this occurrence; alternative readings remain separate." }} } };
const registers = [_][]const u8{ "neutral", "formal", "colloquial", "literary", "technical", "regional" };
const domains = [_][]const u8{ "daily life", "education", "history", "literature", "administration", "craft", "science", "trade", "conversation", "law", "music", "medicine", "travel" };
const qualifiers = [_][]const u8{ "a concrete occurrence", "an extended reading", "a conventional expression", "a historical use", "a context-sensitive reading", "an independently attested sense", "a metonymic reading" };

fn copy(comptime T: type, allocator: std.mem.Allocator, values: []const T) ![]T {
    return allocator.dupe(T, values);
}

fn plain(allocator: std.mem.Allocator, bytes: []const u8) !model.Text {
    return .{ .content = try copy(model.Inline, allocator, &.{.{ .text = bytes }}) };
}

fn span(start: usize, end: usize) model.RealizationSpan {
    return .{ .representation = .{ .local = "surface" }, .start = @intCast(start), .end = @intCast(end) };
}

fn segment(allocator: std.mem.Allocator, role: []const u8, spans: []const model.RealizationSpan, grammar: []const model.Item) !model.Item {
    return .{ .segment = .{
        .role = .{ .namespace = "urn:linguistics:morphology", .local = role },
        .realizations = try copy(model.RealizationSpan, allocator, spans),
        .content = grammar,
    } };
}

fn constituents(allocator: std.mem.Allocator, family: usize) ![]const model.Item {
    return switch (family) {
        0 => try copy(model.Item, allocator, &.{
            try segment(allocator, "prefix", &.{span(0, 2)}, &.{}),
            try segment(allocator, "root", &.{span(2, 10)}, &.{}),
            try segment(allocator, "past", &.{span(10, 12)}, &.{}),
        }),
        1 => try copy(model.Item, allocator, &.{
            try segment(allocator, "root", &.{span(0, 6)}, &.{}),
            try segment(allocator, "plural", &.{span(6, 7)}, &.{plural}),
        }),
        2 => try copy(model.Item, allocator, &.{
            try segment(allocator, "root", &.{span(0, 2)}, &.{}),
            try segment(allocator, "plural", &.{span(2, 5)}, &.{plural}),
            try segment(allocator, "possessive", &.{span(5, 9)}, &.{}),
            try segment(allocator, "ablative", &.{span(9, 12)}, &.{}),
        }),
        3 => try copy(model.Item, allocator, &.{
            try segment(allocator, "root", &.{ span(0, 2), span(4, 6), span(8, 10) }, &.{}),
            try segment(allocator, "vocalic-pattern", &.{ span(2, 4), span(6, 8), span(10, 12) }, &.{}),
            try segment(allocator, "zero-ending", &.{span(12, 12)}, &.{}),
        }),
        4 => try copy(model.Item, allocator, &.{
            try segment(allocator, "verbal-stem", &.{span(0, 6)}, &.{}),
            try segment(allocator, "compound-stem", &.{span(6, 9)}, &.{}),
            try segment(allocator, "dictionary-ending", &.{span(9, 12)}, &.{}),
        }),
        5 => try copy(model.Item, allocator, &.{
            try segment(allocator, "compound-root", &.{span(0, 6)}, &.{}),
            try segment(allocator, "institution-head", &.{span(6, 9)}, &.{}),
        }),
        6 => hindi: {
            // Scalar coordinates are computed, rather than assuming that an
            // orthographic suffix is a fixed number of UTF-8 bytes.
            const bytes = families[6].surface;
            const boundary = "किताब".len;
            break :hindi try copy(model.Item, allocator, &.{
                try segment(allocator, "stem", &.{span(0, boundary)}, &.{}),
                try segment(allocator, "plural", &.{span(boundary, bytes.len)}, &.{plural}),
            });
        },
        7 => try copy(model.Item, allocator, &.{
            .{ .segment = .{
                .kind = .word,
                .role = .{ .namespace = "urn:linguistics:mwe", .local = "discontinuous-verb" },
                .target = .{ .unresolved = .{ .identifier = "teilnehmen", .expected = .{ .local = "entry" } } },
                .realizations = try copy(model.RealizationSpan, allocator, &.{ span(0, 5), span(12, 16) }),
            } },
            .{ .segment = .{
                .kind = .slot,
                .role = .{ .namespace = "urn:linguistics:mwe", .local = "adverbial-slot" },
                .realizations = try copy(model.RealizationSpan, allocator, &.{span(6, 11)}),
            } },
        }),
        else => unreachable,
    };
}

fn sense(allocator: std.mem.Allocator, family: Family, ordinal: usize, sense_index: usize) !model.Item {
    var content: std.ArrayList(model.Item) = .empty;
    const domain = domains[(ordinal * 5 + sense_index * 3) % domains.len];
    const qualifier = qualifiers[(ordinal + sense_index * 2) % qualifiers.len];
    const prose = try std.fmt.allocPrint(allocator, "{s}; {s} in {s} (reading {d}).", .{ family.definition, qualifier, domain, ordinal * 7 + sense_index });
    const label = try std.fmt.allocPrint(allocator, "sense-{d}-{s}", .{ sense_index + 1, domain });
    const inlines = try copy(model.Inline, allocator, &.{
        .{ .text = prose },
        .{ .element = .{
            .name = .{ .namespace = "urn:lexical:prose", .local = "em", .prefix = "p" },
            .attributes = &.{.{ .name = .{ .local = "scope" }, .value = "usage" }},
            .language = if ((ordinal + sense_index) % 3 == 0) .reset else .inherit,
            .content = &.{ .{ .text = " Usage depends on the surrounding utterance." }, .{ .comment = "retained source comment" } },
        } },
        .{ .instruction = .{ .target = "lexical-review", .data = "keep alternatives" } },
    });
    try content.append(allocator, .{ .definition = .{ .content = inlines } });
    try content.append(allocator, .{ .gloss = .{
        .meta = .{ .language = .{ .tag = "en" } },
        .content = try copy(model.Inline, allocator, &.{.{ .text = family.gloss }}),
    } });
    try content.append(allocator, .{ .usage = .{
        .kind = .register,
        .value = .{ .symbol = .{ .namespace = "urn:lexical:register", .local = registers[(ordinal + sense_index) % registers.len] } },
    } });
    if ((ordinal + sense_index) % 4 != 0) try content.append(allocator, .{ .example = .{
        .text = try copy(model.Text, allocator, &.{try plain(allocator, family.example)}),
        .content = try copy(model.Item, allocator, &.{.{ .translation = .{
            .meta = .{ .language = .{ .tag = "en" } },
            .kind = if (sense_index % 2 == 0) .equivalent else .literal,
            .text = try copy(model.Text, allocator, &.{try plain(allocator, "The quoted occurrence illustrates the attested reading.")}),
            .target = .{ .unresolved = .{ .identifier = "source-equivalent", .display = family.gloss } },
            .state = if (ordinal % 11 == 0) .disputed else .asserted,
        } }}),
    } });
    // Equal claims remain two ordered occurrences. Their evidence and exact
    // confidence spellings are data even when the lexical endpoint is equal.
    const relation: model.Relation = .{
        .meta = .{
            .evidence = &.{
                .{ .target = .{ .anchor = .{ .source = "evidence", .start = 0, .end = 12 } } },
                .{ .target = .{ .anchor = .{ .source = "evidence", .start = 0, .end = 12 } } },
            },
            .certainty = &.{.{ .degree = "0.7500", .locus = .value }},
        },
        .predicate = .evokes,
        .endpoints = .{ .binary = .{ .local = "concept" } },
        .confidence = "0.8750",
    };
    try content.append(allocator, .{ .relation = relation });
    if (ordinal % 3 == 0 or sense_index == 1) try content.append(allocator, .{ .relation = relation });
    if ((ordinal + sense_index) % 5 == 0) try content.append(allocator, .{ .sense = .{
        .meta = .{ .language = .reset },
        .label = "figurative",
        .content = &.{ .{ .definition = .{ .content = &.{.{ .text = "An extended interpretation is attested in a separate context." }} } }, repeated_note },
    } });
    if ((ordinal + sense_index) % 7 == 0) try content.append(allocator, repeated_note);
    return .{ .sense = .{
        .meta = .{
            .id = try std.fmt.allocPrint(allocator, "sense-{d}", .{sense_index}),
            .annotations = &.{.{ .name = .{ .namespace = "urn:lexical:review", .local = "status" }, .value = "checked" }},
        },
        .label = label,
        .content = try content.toOwnedSlice(allocator),
        .denotations = try copy(model.Denotation, allocator, &.{.{
            .iri = try std.fmt.allocPrint(allocator, "https://example.test/ontology/{s}/{d}", .{ domain, (ordinal + sense_index) % 97 }),
        }}),
    } };
}

/// All entries are independently valid native lexical documents. IDs and
/// reading prose vary; common constituents recur independently of whole-entry
/// equality. Equal collection members, order and pointer definitions survive.
pub fn rich(allocator: std.mem.Allocator, count: usize) !OwnedEntries {
    if (count == 0 or count > 1_000_000) return error.InvalidEntryCount;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const entries = try a.alloc(model.Entry, count);
    for (entries, 0..) |*entry, ordinal| {
        const family_index = (ordinal * 5 + ordinal / families.len) % families.len;
        const family = families[family_index];
        const features = family_features[family_index];
        var content: std.ArrayList(model.Item) = .empty;
        const surface_inlines = try copy(model.Inline, a, &.{
            .{ .element = .{
                .name = .{ .namespace = "urn:lexical:prose", .local = "orth", .prefix = "p" },
                .content = try copy(model.Inline, a, &.{ .{ .text = family.surface }, .{ .comment = "coordinates ignore markup" } }),
            } },
        });
        const representations = try copy(model.Representation, a, &.{
            .{ .meta = .{ .id = "surface" }, .text = .{ .content = surface_inlines }, .script = family.script, .features = features },
            .{ .meta = .{ .id = "pronunciation" }, .kind = .phonetic, .text = try plain(a, family.phonetic), .scheme = "IPA" },
        });
        var grammar = try a.alloc(model.Item, features.len);
        for (features, 0..) |feature, index| grammar[index] = .{ .grammar = feature };
        try content.append(a, .{ .form = .{
            .meta = .{ .id = "canonical" },
            .representations = representations,
            .content = grammar,
        } });
        if (ordinal % 4 == 0) try content.append(a, .{ .form = .{
            .meta = .{ .id = "variant" },
            .kind = .variant,
            .representations = try copy(model.Representation, a, &.{.{
                .text = try plain(a, family.surface),
                .script = family.script,
                .features = features,
            }}),
        } });
        const parts = try constituents(a, family_index);
        const analysis: model.Analysis = .{
            .meta = .{ .id = "analysis" },
            .kind = if (family_index == 7) .multiword else .morphology,
            .form = .{ .local = "canonical" },
            .process = .{ .namespace = "urn:linguistics:analysis", .local = if (family_index == 7) "discontinuous-expression" else "surface-realization" },
            .content = parts,
        };
        try content.append(a, .{ .analysis = analysis });
        if (ordinal % 5 == 0) {
            var alternative = analysis;
            alternative.meta = .{ .id = "alternative-analysis", .language = .reset };
            alternative.process = .{ .namespace = "urn:linguistics:analysis", .local = "competing-analysis" };
            // Structural equality of constituents does not merge the analysis
            // occurrences or the explicitly reset language on the alternative.
            try content.append(a, .{ .analysis = alternative });
        }
        const senses = 1 + (ordinal * 7 + ordinal / 11) % 4;
        for (0..senses) |sense_index| try content.append(a, try sense(a, family, ordinal, sense_index));
        try content.append(a, .{ .concept = .{
            .meta = .{ .id = "concept" },
            .reference = .{ .iri = try std.fmt.allocPrint(a, "https://example.test/concept/{d}", .{ordinal % 257}) },
        } });
        if (ordinal % 3 != 0) try content.append(a, .{ .frame = .{
            .name = .{ .namespace = "urn:linguistics:frame", .local = if (ordinal % 2 == 0) "transitive" else "intransitive" },
            .arguments = &.{
                .{ .role = .{ .local = "subject" }, .realization = .{ .local = "canonical" }, .referent = .{ .local = "concept" } },
                .{ .role = .{ .local = "adjunct" }, .optional = true, .features = noun_features },
            },
        } });
        const shared = try a.create(model.SharedValue);
        shared.* = .{ .meta = .{ .id = "feature-bundle" }, .value = .{ .structure = .{
            .type = .{ .namespace = "urn:linguistics:ud", .local = "morphosyntax" },
            .fields = features,
        } } };
        try content.append(a, .{ .extension = .{
            .name = .{ .namespace = "urn:lexical:values", .local = "shared-features" },
            .value = .{ .shared = shared },
        } });
        try content.append(a, .{ .extension = .{
            .name = .{ .namespace = "urn:lexical:values", .local = "exact-alternatives" },
            .value = .{ .bag = try copy(model.Value, a, &.{
                .{ .integer = @intCast(ordinal % 17) },
                .{ .integer = @intCast(ordinal % 17) },
                .{ .decimal = if (ordinal % 2 == 0) "01.2300" else "+1.230" },
                .{ .reference = .{ .local = "feature-bundle" } },
                .{ .alternative = &.{ .unknown, .unspecified, .default } },
                .{ .list = &.{ .{ .text = "first" }, .{ .text = "second" }, .{ .text = "first" } } },
            }) },
        } });
        entry.* = .{
            .id = try std.fmt.allocPrint(a, "rich-{s}-{d:0>8}", .{ family.language, ordinal }),
            .headword = family.surface,
            .meta = .{ .language = .{ .tag = family.language }, .attributes = &.{.{ .name = .{ .local = "fixture" }, .value = "varied-native-rich" }} },
            .kind = if (family_index == 7) .multiword else .word,
            .keys = try copy(model.SearchKey, a, &.{
                .{ .spelling = family.surface, .form = "canonical" },
                .{ .spelling = family.gloss },
            }),
            .content = try content.toOwnedSlice(a),
            .sources = try copy(model.Source, a, &.{.{
                .id = "evidence",
                .media_type = "text/plain",
                .bytes = try std.fmt.allocPrint(a, "Source witness {d}: {s}\nPreserved lexical context and unused material.\x00", .{ ordinal, family.example }),
            }}),
            .residuals = &.{.{ .source = "evidence", .start = 12, .end = 20 }},
        };
    }
    return .{ .arena = arena, .entries = entries };
}

fn hexDigit(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn decodeHex(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (text.len % 2 != 0) return error.InvalidHex;
    const bytes = try allocator.alloc(u8, text.len / 2);
    for (bytes, 0..) |*byte, index| byte.* = ((hexDigit(text[index * 2]) orelse return error.InvalidHex) << 4) |
        (hexDigit(text[index * 2 + 1]) orelse return error.InvalidHex);
    return bytes;
}

/// Decode all rows or an explicit leading prefix. `max_entries` limits the
/// native workload; a nonzero limit does not claim to admit later unused rows.
/// Empty alias spellings are retained. Blank rows and extra fields are errors.
pub fn naturalBytes(allocator: std.mem.Allocator, bytes: []const u8, max_entries: usize) !OwnedEntries {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var entries: std.ArrayList(model.Entry) = .empty;
    var body = bytes;
    if (std.mem.endsWith(u8, body, "\n")) body = body[0 .. body.len - 1];
    if (std.mem.endsWith(u8, body, "\r")) body = body[0 .. body.len - 1];
    if (body.len == 0) return error.EmptyProjection;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        if (max_entries != 0 and entries.items.len == max_entries) break;
        const line = if (std.mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
        if (line.len == 0) return error.MalformedProjection;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const id = try decodeHex(a, fields.next() orelse return error.MalformedProjection);
        const key_hex = fields.next() orelse return error.MalformedProjection;
        const prose = try decodeHex(a, fields.next() orelse return error.MalformedProjection);
        if (fields.next() != null) return error.MalformedProjection;
        if (id.len == 0 or !std.unicode.utf8ValidateSlice(id)) return error.InvalidIdentity;
        if (!std.unicode.utf8ValidateSlice(prose)) return error.InvalidUtf8;
        var keys: std.ArrayList(model.SearchKey) = .empty;
        var key_fields = std.mem.splitScalar(u8, key_hex, ',');
        while (key_fields.next()) |key_field| {
            const spelling = try decodeHex(a, key_field);
            if (!std.unicode.utf8ValidateSlice(spelling)) return error.InvalidUtf8;
            try keys.append(a, .{ .spelling = spelling });
        }
        const owned_keys = try keys.toOwnedSlice(a);
        try entries.append(a, .{
            .id = id,
            .headword = owned_keys[0].spelling,
            .keys = owned_keys[1..],
            .content = try copy(model.Item, a, &.{.{ .definition = try plain(a, prose) }}),
        });
    }
    return .{ .arena = arena, .entries = try entries.toOwnedSlice(a) };
}

pub fn natural(allocator: std.mem.Allocator, io: std.Io, path: []const u8, max_entries: usize) !OwnedEntries {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024 * 1024));
    defer allocator.free(bytes);
    return naturalBytes(allocator, bytes, max_entries);
}

/// Complete native-value observation, independent of every candidate encoding.
/// It includes identities, all strings, exact decimals, ordered duplicate
/// members, language resets, source bytes, and recursively embedded pointers.
pub const Observation = struct {
    hash: u64,
    nodes: usize,
    strings: usize,
    string_bytes: usize,
};

const Observer = struct {
    hash: std.hash.Wyhash = std.hash.Wyhash.init(0x6c65787061676573),
    nodes: usize = 0,
    strings: usize = 0,
    string_bytes: usize = 0,

    fn number(self: *Observer, number_: u64) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, number_, .little);
        self.hash.update(&bytes);
    }

    fn value(self: *Observer, pointer: anytype, depth: usize) error{ObservationDepthExceeded}!void {
        if (depth > 256) return error.ObservationDepthExceeded;
        const T = @TypeOf(pointer.*);
        self.nodes += 1;
        self.number(@intFromEnum(@typeInfo(T)));
        switch (@typeInfo(T)) {
            .@"struct" => |info| inline for (info.fields) |field| try self.value(&@field(pointer.*, field.name), depth + 1),
            .@"union" => {
                self.number(@intFromEnum(std.meta.activeTag(pointer.*)));
                switch (pointer.*) {
                    inline else => |*payload| try self.value(payload, depth + 1),
                }
            },
            .optional => {
                self.number(@intFromBool(pointer.* != null));
                if (pointer.*) |*payload| try self.value(payload, depth + 1);
            },
            .array => {
                self.number(pointer.len);
                for (pointer.*) |*item| try self.value(item, depth + 1);
            },
            .pointer => |info| switch (info.size) {
                .slice => {
                    self.number(pointer.len);
                    if (info.child == u8) {
                        self.strings += 1;
                        self.string_bytes += pointer.len;
                        self.hash.update(pointer.*);
                    } else for (pointer.*) |*item| try self.value(item, depth + 1);
                },
                .one => try self.value(pointer.*, depth + 1),
                else => @compileError("unbounded native pointers cannot be observed"),
            },
            .int => |info| {
                const U = std.meta.Int(.unsigned, info.bits);
                self.number(@as(U, @bitCast(pointer.*)));
            },
            .@"enum" => self.number(@intFromEnum(pointer.*)),
            .bool => self.number(@intFromBool(pointer.*)),
            .void => {},
            else => @compileError("unsupported lexical value in native observer"),
        }
    }
};

pub fn observe(entry: *const model.Entry) !Observation {
    var observer = Observer{};
    try observer.value(entry, 0);
    return .{ .hash = observer.hash.final(), .nodes = observer.nodes, .strings = observer.strings, .string_bytes = observer.string_bytes };
}

/// Exact structural equality ignores allocator addresses, never collection
/// order or duplicate multiplicity. Use this all-field gate before timings.
pub fn nativeEqual(comptime T: type, left: T, right: T) bool {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.fields) |field| if (!nativeEqual(field.type, @field(left, field.name), @field(right, field.name))) return false;
            return true;
        },
        .@"union" => {
            if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
            return switch (left) {
                inline else => |payload, tag| nativeEqual(@TypeOf(payload), payload, @field(right, @tagName(tag))),
            };
        },
        .optional => |info| {
            if (left) |payload| return if (right) |other| nativeEqual(info.child, payload, other) else false;
            return right == null;
        },
        .array => |info| {
            for (left, right) |a, b| if (!nativeEqual(info.child, a, b)) return false;
            return true;
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                if (left.len != right.len) return false;
                if (info.child == u8) return std.mem.eql(u8, left, right);
                for (left, right) |a, b| if (!nativeEqual(info.child, a, b)) return false;
                return true;
            },
            .one => return nativeEqual(info.child, left.*, right.*),
            else => @compileError("unbounded native pointers cannot be compared"),
        },
        .void => return true,
        else => return left == right,
    }
}
