//! Shared test/benchmark fixtures, not part of the public library export.
const model = @import("model.zig");

pub const rich: model.Entry = .{
    .id = "bank.en",
    .headword = "bank",
    .meta = .{ .language = .{ .tag = "en" } },
    .keys = &.{.{ .spelling = "banks", .form = "plural" }},
    .sources = &.{.{
        .id = "tei",
        .media_type = "application/tei+xml",
        .bytes = "<entry><form>bank</form><sense>financial institution</sense></entry>",
    }},
    .content = &.{
        .{ .form = .{
            .meta = .{ .id = "lemma" },
            .representations = &.{
                .{ .text = .{ .content = &.{.{ .text = "bank" }} }, .script = "Latn" },
                .{ .kind = .phonetic, .text = .{ .content = &.{.{ .text = "bæŋk" }} }, .scheme = "IPA" },
            },
            .content = &.{.{ .grammar = .{ .name = .{ .local = "partOfSpeech" }, .value = .{ .symbol = .{ .local = "noun" } } } }},
        } },
        .{ .form = .{
            .meta = .{ .id = "plural" },
            .kind = .inflected,
            .representations = &.{.{ .text = .{ .content = &.{.{ .text = "banks" }} } }},
            .content = &.{.{ .grammar = .{ .name = .{ .local = "number" }, .value = .{ .text = "plural" } } }},
        } },
        .{ .sense = .{
            .meta = .{
                .id = "finance",
                .evidence = &.{.{ .target = .{ .anchor = .{ .source = "tei", .start = 23, .end = 58 } } }},
            },
            .label = "1",
            .content = &.{
                .{ .definition = .{ .content = &.{
                    .{ .text = "A " },
                    .{ .element = .{ .name = .{ .namespace = "http://www.tei-c.org/ns/1.0", .local = "hi" }, .content = &.{.{ .text = "financial" }} } },
                    .{ .text = " institution & its offices." },
                } } },
                .{ .gloss = .{ .meta = .{ .language = .{ .tag = "fr" } }, .content = &.{.{ .text = "banque" }} } },
                .{ .example = .{
                    .text = &.{.{ .content = &.{.{ .text = "She went to the bank." }} }},
                    .content = &.{.{ .translation = .{
                        .text = &.{.{ .meta = .{ .language = .{ .tag = "fr" } }, .content = &.{.{ .text = "Elle est allée à la banque." }} }},
                        .kind = .free,
                    } }},
                } },
                .{ .relation = .{
                    .meta = .{ .id = "claim1", .annotations = &.{.{ .name = .{ .local = "review" }, .value = "checked" }} },
                    .predicate = .evokes,
                    .endpoints = .{ .binary = .{ .local = "concept1" } },
                    .confidence = "0.95",
                } },
                .{ .relation = .{ .predicate = .denotes, .endpoints = .{ .binary = .{ .iri = "https://example.org/ontology/FinancialInstitution" } } } },
                .{ .sense = .{
                    .meta = .{ .id = "building", .language = .reset },
                    .label = "1a",
                    .content = &.{.{ .definition = .{ .content = &.{.{ .text = "The building itself." }} } }},
                } },
            },
        } },
        .{ .concept = .{ .meta = .{ .id = "concept1" }, .reference = .{ .iri = "https://example.org/concepts/banking" } } },
        .{ .etymology = .{
            .process = .{ .local = "borrowing" },
            .source = .{ .iri = "https://example.org/etymology/banca" },
            .content = &.{.{ .note = .{ .meta = .{ .language = .{ .tag = "it" } }, .content = &.{.{ .text = "banca" }} } }},
        } },
        .{ .frame = .{
            .name = .{ .local = "transitive" },
            .arguments = &.{.{ .role = .{ .local = "subject" }, .referent = .{ .local = "concept1" } }},
        } },
        .{ .extension = .{
            .name = .{ .namespace = "https://example.org/project", .local = "dialectSurvey" },
            .value = .{ .bag = &.{ .{ .integer = 7 }, .{ .integer = 7 } } },
        } },
    },
};
