//! Fixed native-rich control shared by baseline and candidate benchmarks.
//! This synthetic fixture exercises semantic ownership, not natural-corpus
//! compression. Every timing phase consumes the same observable fields.
const std = @import("std");
const lex = @import("lex6");
const model = lex.model;

pub const content: []const model.Item = &.{
    .{ .form = .{
        .meta = .{ .id = "canonical" },
        .representations = &.{
            .{ .text = .{ .content = &.{.{ .text = "語・é・كتاب・evlerimizden" }} }, .script = "Zyyy" },
            .{ .kind = .phonetic, .text = .{ .content = &.{.{ .text = "ɡoː" }} }, .scheme = "IPA" },
        },
        .content = &.{.{ .grammar = .{ .name = .{ .local = "partOfSpeech" }, .value = .{ .symbol = .{ .local = "noun" } } } }},
    } },
    .{ .sense = .{
        .meta = .{
            .id = "sense-primary",
            .evidence = &.{.{ .target = .{ .anchor = .{ .source = "shared-source", .start = 0, .end = 12 } } }},
            .annotations = &.{.{ .name = .{ .local = "status" }, .value = "reviewed" }},
        },
        .label = "primary",
        .content = &.{
            .{ .definition = .{ .content = &.{
                .{ .text = "A lexical " },
                .{ .element = .{ .name = .{ .namespace = "urn:lexical:content", .local = "em" }, .content = &.{.{ .text = "meaning" }} } },
                .{ .text = " with independently qualified evidence." },
            } } },
            .{ .gloss = .{ .meta = .{ .language = .{ .tag = "ja" } }, .content = &.{.{ .text = "語の意味" }} } },
            .{ .example = .{
                .text = &.{.{ .content = &.{.{ .text = "她读了这本书。" }} }},
                .content = &.{.{ .translation = .{
                    .meta = .{ .language = .{ .tag = "tr" } },
                    .text = &.{.{ .content = &.{.{ .text = "O bu kitabı okudu." }} }},
                    .target = .{ .unresolved = .{ .identifier = "quoted-equivalent", .display = "an unresolved occurrence" } },
                    .state = .disputed,
                } }},
            } },
            .{ .relation = .{
                .meta = .{ .id = "claim", .certainty = &.{.{ .degree = "0.7500", .locus = .value }} },
                .predicate = .evokes,
                .endpoints = .{ .binary = .{ .local = "concept" } },
                .confidence = "0.875",
            } },
            .{ .sense = .{
                .meta = .{ .id = "sub-sense", .language = .reset },
                .label = "nested",
                .content = &.{.{ .definition = .{ .content = &.{.{ .text = "A subordinate meaning retains its own scope." }} } }},
            } },
        },
    } },
    .{ .concept = .{ .meta = .{ .id = "concept" }, .reference = .{ .iri = "https://example.test/concept/lexical" } } },
    .{ .frame = .{
        .name = .{ .local = "transitive" },
        .arguments = &.{.{ .role = .{ .local = "subject" }, .realization = .{ .local = "canonical" }, .referent = .{ .local = "concept" } }},
    } },
    .{ .extension = .{
        .name = .{ .namespace = "urn:research", .local = "feature-algebra" },
        .value = .{ .bag = &.{ .{ .integer = 7 }, .{ .integer = 7 }, .{ .decimal = "01.2300" }, .unknown, .unspecified, .default } },
    } },
};

pub const resources: []const model.Resource = &.{.{ .source = .{
    .id = "shared-source",
    .media_type = "text/plain",
    .bytes = "A source for lexical evidence. Exact source bytes survive.",
} }};

pub fn make(allocator: std.mem.Allocator, count: usize) !model.Library {
    const entries = try allocator.alloc(model.Entry, count);
    for (entries, 0..) |*entry, ordinal| entry.* = .{
        .id = try std.fmt.allocPrint(allocator, "entry-{d:0>8}", .{ordinal}),
        .headword = try std.fmt.allocPrint(allocator, "lexeme-{d:0>8}", .{ordinal}),
        .meta = .{ .language = .{ .tag = "en" } },
        .keys = &.{.{ .spelling = "multilingual", .form = "canonical" }},
        .content = content,
    };
    return .{ .entries = entries, .resources = resources };
}

pub fn consume(value: *const model.Entry) !u64 {
    var senses = lex.query.entry(value).select(.sense, .children);
    const primary = (try senses.next()).?;
    return consumeFields(value.headword, primary.value.label.?);
}

pub fn consumeFields(headword: []const u8, label: []const u8) u64 {
    var hash = std.hash.Wyhash.init(0x6c657836);
    hash.update(headword);
    hash.update(label);
    return hash.final();
}
