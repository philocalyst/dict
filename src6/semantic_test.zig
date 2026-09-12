const std = @import("std");
const model = @import("model.zig");
const packet = @import("packet.zig");
const query = @import("query.zig");
const render = @import("render.zig");
const validate = @import("validate.zig");

const testing = std.testing;

/// This value intentionally puts forward references before their owners and
/// repeats the same source anchor in several origin rows. It is a semantic
/// fixture, not a standards serializer fixture.
const semantic_entry: model.Entry = .{
    .id = "semantic-en",
    .headword = "colour",
    .meta = .{
        .language = .{ .tag = "en-GB" },
        .origins = &.{
            .{ .anchor = .{ .source = "shared-source", .start = 4, .end = 11 }, .operation = .split },
            .{ .anchor = .{ .source = "shared-source", .start = 4, .end = 11 }, .role = .mention, .operation = .merged },
        },
        .certainty = &.{.{
            .target = .{ .local = "translation-claim" },
            .locus = .value,
            .degree = "1.000000000000000000000000000000000000",
            .asserted = .{ .decimal = "01.2300" },
            .given = &.{.{ .local = "support-claim" }},
            .evidence = &.{.{ .target = .{ .anchor = .{ .source = "shared-source", .start = 0, .end = 18 } } }},
        }},
        .annotations = &.{.{
            .name = .{ .namespace = "urn:review", .local = "checked" },
            .value = "yes",
            .target = .{ .local = "translation-claim" },
            .locus = .value,
            .content = &.{.{ .meta = .{ .language = .{ .tag = "en" } }, .content = &.{.{ .text = "editor note" }} }},
        }},
    },
    .keys = &.{
        .{ .spelling = "color", .form = "lemma" },
        .{ .spelling = "colours", .form = "plural" },
    },
    .content = &.{
        // Forward local references must be resolved after identity collection.
        .{ .relation = .{
            .meta = .{ .id = "translation-claim" },
            .predicate = .translation,
            .participants = &.{
                .{ .role = .{ .local = "source" }, .target = .{ .local = "sense-en" } },
                .{ .role = .{ .local = "target" }, .target = .{ .local = "sense-fr" } },
                .{ .role = .{ .local = "evidence" }, .target = .{ .unresolved = .{
                    .identifier = "#missing-source-claim",
                    .base = "https://example.test/tei.xml",
                    .expected = .{ .local = "claim" },
                    .display = "printed evidence",
                } } },
            },
            .category = .{ .namespace = "urn:vartrans", .local = "near-equivalent" },
            .state = .disputed,
            .confidence = "0.500000000000000000000000000000000000",
        } },
        .{ .relation = .{
            .meta = .{ .id = "support-claim" },
            .predicate = .evokes,
            .target = .{ .local = "lexical-concept" },
        } },
        .{ .form = .{
            .meta = .{ .id = "lemma" },
            .kind = .canonical,
            .representations = &.{
                .{
                    .meta = .{
                        .id = "representation-written",
                        .origins = &.{.{ .anchor = .{ .source = "shared-source", .start = 4, .end = 11 } }},
                    },
                    .kind = .written,
                    .text = .{
                        .meta = .{ .language = .{ .tag = "en-GB" } },
                        .content = &.{.{ .text = "colour" }},
                    },
                    .script = "Latn",
                    .scheme = "orthographic",
                    .features = &.{.{
                        .meta = .{ .id = "representation-feature" },
                        .name = .{ .namespace = "urn:lex", .local = "register" },
                        .value = .{ .structure = .{
                            .meta = .{ .id = "feature-structure" },
                            .type = .{ .namespace = "urn:tei", .local = "fs" },
                            .fields = &.{
                                .{ .meta = .{ .id = "feature-symbol" }, .name = .{ .local = "value" }, .value = .{ .symbol = .{ .local = "standard" } } },
                                .{ .meta = .{ .id = "feature-list" }, .name = .{ .local = "variants" }, .value = .{ .list = &.{ .{ .integer = 1 }, .{ .integer = 1 } } } },
                                .{ .meta = .{ .id = "feature-bag" }, .name = .{ .local = "sources" }, .value = .{ .bag = &.{ .{ .text = "a" }, .{ .text = "a" } } } },
                                .{ .meta = .{ .id = "feature-alternative" }, .name = .{ .local = "choice" }, .value = .{ .alternative = &.{ .{ .unknown = {} }, .{ .unspecified = {} } } } },
                                .{ .meta = .{ .id = "feature-negation" }, .name = .{ .local = "not" }, .value = .{ .negation = &.{.{ .boolean = true }} } },
                                .{ .meta = .{ .id = "feature-default" }, .name = .{ .local = "fallback" }, .value = .{ .default = {} } },
                            },
                        } },
                        .range = .{ .resource = .{ .id = "grammatical-number", .fragment = "register" } },
                    }},
                },
            },
            .content = &.{.{ .grammar = .{
                .name = .{ .local = "partOfSpeech" },
                .value = .{ .symbol = .{ .local = "noun" } },
            } }},
        } },
        .{ .form = .{
            .meta = .{ .id = "plural" },
            .kind = .inflected,
            .representations = &.{.{
                .meta = .{ .id = "representation-plural" },
                .text = .{ .meta = .{ .language = .{ .tag = "en-GB" } }, .content = &.{.{ .text = "colours" }} },
            }},
        } },
        .{ .sense = .{
            .meta = .{ .id = "sense-en" },
            .label = "English meaning",
            .denotations = &.{.{ .iri = "https://example.test/ontology/Colour" }},
            .content = &.{
                .{ .definition = .{ .content = &.{.{ .text = "the perceived hue" }} } },
                .{ .translation = .{
                    .meta = .{ .id = "translation-fr" },
                    .kind = .equivalent,
                    .text = &.{.{ .meta = .{ .language = .{ .tag = "fr" } }, .content = &.{.{ .text = "couleur" }} }},
                    .target = .{ .entry = .{ .id = "couleur-fr", .fragment = "sense-fr" } },
                    .category = .{ .namespace = "urn:vartrans", .local = "equivalent" },
                    .state = .asserted,
                    .content = &.{
                        .{ .grammar = .{ .name = .{ .local = "target-pos" }, .value = .{ .symbol = .{ .local = "noun" } } } },
                        .{ .note = .{ .content = &.{.{ .text = "translation note" }} } },
                    },
                } },
                .{ .media = .{
                    .uri = "https://example.test/audio/colour.ogg",
                    .media_type = "audio/ogg",
                    .caption = &.{.{ .content = &.{.{ .text = "pronunciation" }} }},
                    .alt = &.{.{ .content = &.{.{ .text = "spoken colour" }} }},
                    .width = 640,
                    .height = 480,
                } },
                .{ .sense = .{
                    .meta = .{ .id = "sense-fr" },
                    .label = "nested lexicalization",
                    .content = &.{.{ .gloss = .{ .meta = .{ .language = .{ .tag = "fr" } }, .content = &.{.{ .text = "teinte" }} } }},
                } },
            },
        } },
        .{ .concept = .{
            .meta = .{ .id = "lexical-concept" },
            .reference = .{ .iri = "https://example.test/concept/colour" },
        } },
        .{ .etymology = .{
            .process = .{ .local = "borrowing" },
            .source = .{ .unresolved = .{ .identifier = "#etymon", .display = "etymon" } },
            .content = &.{.{ .note = .{ .content = &.{.{ .text = "source commentary" }} } }},
        } },
        .{ .frame = .{
            .name = .{ .local = "copular" },
            .arguments = &.{.{ .role = .{ .local = "subject" }, .referent = .{ .local = "lexical-concept" }, .optional = true }},
        } },
        .{ .extension = .{
            .name = .{ .namespace = "urn:vendor", .local = "preserve" },
            .value = .{ .set = &.{ .{ .integer = 1 }, .{ .integer = 2 } } },
        } },
    },
    .sources = &.{.{
        .id = "embedded-source",
        .media_type = "application/octet-stream",
        .bytes = "raw\x00source\xff",
        .uri = "file:///tmp/source.bin",
    }},
    .residuals = &.{.{ .source = "shared-source", .start = 18, .end = 24 }},
};

test "typed semantic values roundtrip with origins, claims, structures and media" {
    var source_extents = validate.SourceIndex{};
    defer source_extents.deinit(testing.allocator);
    try source_extents.add(testing.allocator, "shared-source", 32);
    try validate.check(testing.allocator, &semantic_entry, .{ .sources = &source_extents });

    const encoded = try packet.encode(testing.allocator, semantic_entry, .{});
    defer testing.allocator.free(encoded);
    var decoded = try packet.decode(model.Entry, testing.allocator, encoded, .{});
    defer decoded.deinit();
    try testing.expectEqualDeep(semantic_entry, decoded.value);

    try testing.expectEqual(@as(usize, 2), decoded.value.meta.origins.len);
    try testing.expect(decoded.value.meta.origins[0].operation == .split);
    try testing.expect(decoded.value.meta.origins[1].operation == .merged);
    try testing.expectEqual(@as(usize, 3), decoded.value.content[0].relation.participants.len);
    try testing.expect(decoded.value.content[0].relation.target == null);
    try testing.expectEqualStrings("feature-structure", decoded.value.content[2].form.representations[0].features[0].value.structure.meta.id.?);
    try testing.expectEqualStrings("standard", decoded.value.content[2].form.representations[0].features[0].value.structure.fields[0].value.symbol.local);
    try testing.expectEqualStrings("01.2300", decoded.value.meta.certainty[0].asserted.?.decimal);
    const translation = decoded.value.content[4].sense.content[1].translation;
    try testing.expectEqual(@as(usize, 2), translation.content.len);
    try testing.expect(translation.content[0] == .grammar);
    try testing.expect(translation.content[1] == .note);
    try testing.expect(translation.target.? == .entry);
    try testing.expectEqualStrings("couleur-fr", translation.target.?.entry.id);
    try testing.expect(decoded.value.content[2].form.representations[0].features[0].range.? == .resource);
}

test "representation identity and feature structure preserve multiplicity and type" {
    const form = semantic_entry.content[2].form;
    try testing.expectEqualStrings("lemma", form.meta.id.?);
    try testing.expectEqual(@as(usize, 1), form.representations.len);
    const representation = form.representations[0];
    try testing.expectEqualStrings("representation-written", representation.meta.id.?);
    try testing.expectEqualStrings("Latn", representation.script.?);
    try testing.expectEqual(@as(usize, 1), representation.features.len);

    const structure = representation.features[0].value.structure;
    try testing.expectEqualStrings("fs", structure.type.?.local);
    try testing.expectEqual(@as(usize, 6), structure.fields.len);
    try testing.expect(std.meta.activeTag(structure.fields[1].value) == .list);
    try testing.expectEqual(@as(usize, 2), structure.fields[1].value.list.len);
    try testing.expect(std.meta.activeTag(structure.fields[2].value) == .bag);
    try testing.expect(std.meta.activeTag(structure.fields[3].value) == .alternative);
    try testing.expect(std.meta.activeTag(structure.fields[4].value) == .negation);
    try testing.expect(std.meta.activeTag(structure.fields[5].value) == .default);
}

test "certainty uses scoped targets and exact probability boundaries" {
    var extents = validate.SourceIndex{};
    defer extents.deinit(testing.allocator);
    try extents.add(testing.allocator, "doc", 16);
    const good: model.Entry = .{
        .id = "certainty-good",
        .headword = "good",
        .meta = .{ .certainty = &.{
            .{ .target = .{ .local = "claim" }, .locus = .value, .degree = "1.000000000000000000000000000000000000", .given = &.{.{ .unresolved = .{ .identifier = "#prior" } }}, .evidence = &.{.{ .target = .{ .anchor = .{ .source = "doc", .start = 0, .end = 16 } } }} },
            .{ .target = .{ .local = "claim" }, .locus = .{ .source = .{ .source = "doc", .start = 0, .end = 16 } }, .degree = "0.999999999999999999999999999999999999" },
        } },
        .content = &.{.{ .relation = .{ .meta = .{ .id = "claim" }, .predicate = .synonym, .target = .{ .unresolved = .{ .identifier = "target" } } } }},
    };
    try validate.check(testing.allocator, &good, .{ .sources = &extents });

    var over = good;
    over.meta.certainty = &.{.{ .degree = "1.000000000000000000000000000000000001" }};
    try testing.expectError(error.InvalidValue, validate.check(testing.allocator, &over, .{ .sources = &extents }));

    var under = good;
    under.meta.certainty = &.{.{ .degree = "-0.000000000000000000000000000000000001" }};
    try testing.expectError(error.InvalidValue, validate.check(testing.allocator, &under, .{ .sources = &extents }));

    var asserted_alternative = good;
    asserted_alternative.meta.certainty = &.{.{ .asserted = .{ .alternative = &.{ .{ .text = "verb" }, .{ .text = "noun" } } } }};
    try validate.check(testing.allocator, &asserted_alternative, .{ .sources = &extents });
}

test "n-ary role-labelled relations allow a targetless claim and preserve order" {
    const value: model.Entry = .{
        .id = "nary",
        .headword = "nary",
        .content = &.{
            .{ .relation = .{
                .meta = .{ .id = "claim" },
                .predicate = .{ .custom = .{ .namespace = "urn:test", .local = "attestedBy" } },
                .participants = &.{
                    .{ .role = .{ .local = "source" }, .target = .{ .local = "sense" } },
                    .{ .role = .{ .local = "target" }, .target = .{ .unresolved = .{ .identifier = "urn:target" } } },
                    .{ .role = .{ .local = "witness" }, .target = .{ .iri = "https://example.test/witness" } },
                },
                .category = .{ .local = "historical" },
                .state = .disputed,
                .confidence = "0.000000000000000000000000000000000001",
            } },
            .{ .sense = .{ .meta = .{ .id = "sense" } } },
        },
    };
    try validate.check(testing.allocator, &value, .{});
    const relation = value.content[0].relation;
    try testing.expect(relation.target == null);
    try testing.expectEqual(@as(usize, 3), relation.participants.len);
    try testing.expectEqual(model.ClaimState.disputed, relation.state);
    try testing.expectEqualStrings("witness", relation.participants[2].role.local);
}

test "forward IDs resolve, wrong relation target kind and missing locals fail" {
    const forward: model.Entry = .{
        .id = "forward",
        .headword = "forward",
        .content = &.{
            .{ .relation = .{ .predicate = .evokes, .target = .{ .local = "concept-later" } } },
            .{ .concept = .{ .meta = .{ .id = "concept-later" }, .reference = .{ .iri = "urn:concept" } } },
        },
    };
    try validate.check(testing.allocator, &forward, .{});

    const wrong_kind: model.Entry = .{
        .id = "wrong-kind",
        .headword = "wrong-kind",
        .content = &.{
            .{ .relation = .{ .predicate = .evokes, .target = .{ .local = "form" } } },
            .{ .form = .{ .meta = .{ .id = "form" } } },
        },
    };
    try testing.expectError(error.InvalidReferenceKind, validate.check(testing.allocator, &wrong_kind, .{}));

    const missing: model.Entry = .{
        .id = "missing",
        .headword = "missing",
        .content = &.{.{ .relation = .{ .predicate = .synonym, .target = .{ .local = "not-here" } } }},
    };
    try testing.expectError(error.UnresolvedLocal, validate.check(testing.allocator, &missing, .{}));

    const bad_unresolved: model.Entry = .{
        .id = "bad-unresolved",
        .headword = "bad-unresolved",
        .content = &.{.{ .relation = .{ .predicate = .synonym, .target = .{ .unresolved = .{ .identifier = "" } } } }},
    };
    try testing.expectError(error.InvalidIdentity, validate.check(testing.allocator, &bad_unresolved, .{}));
}

test "shared source extents validate origins and residuals without embedding a duplicate source" {
    const bytes = "01234567890123456789012345678901";
    var extents = validate.SourceIndex{};
    defer extents.deinit(testing.allocator);
    try extents.add(testing.allocator, "shared", bytes.len);
    const entry: model.Entry = .{
        .id = "anchored",
        .headword = "anchored",
        .meta = .{ .origins = &.{.{ .anchor = .{ .source = "shared", .start = 0, .end = 6 } }} },
        .residuals = &.{.{ .source = "shared", .start = 6, .end = @intCast(bytes.len) }},
    };
    try validate.check(testing.allocator, &entry, .{ .sources = &extents });

    const resource: model.Resource = .{ .source = .{
        .id = "shared",
        .media_type = "text/plain",
        .bytes = bytes,
    } };
    try validate.check(testing.allocator, &resource, .{ .sources = &extents });

    var reversed = entry;
    reversed.residuals = &.{.{ .source = "shared", .start = 9, .end = 8 }};
    try testing.expectError(error.InvalidAnchor, validate.check(testing.allocator, &reversed, .{ .sources = &extents }));

    var out_of_bounds = entry;
    out_of_bounds.residuals = &.{.{ .source = "shared", .start = 0, .end = @intCast(bytes.len + 1) }};
    try testing.expectError(error.InvalidAnchor, validate.check(testing.allocator, &out_of_bounds, .{ .sources = &extents }));

    const wrong_source: model.Resource = .{ .source = .{
        .id = "shared",
        .media_type = "text/plain",
        .bytes = "short",
    } };
    try testing.expectError(error.InvalidAnchor, validate.check(testing.allocator, &wrong_source, .{ .sources = &extents }));
}

test "standalone ranges retain IDs, labels, parentage and unresolved external references" {
    const range: model.Resource = .{
        .range = .{
            .id = "grammatical-number",
            .external = .{ .unresolved = .{
                .identifier = "urn:range:grammatical-number",
                .expected = .{ .namespace = "urn:lift", .local = "range" },
                .display = "grammatical number",
            } },
            .labels = &.{.{ .meta = .{ .language = .{ .tag = "en" } }, .content = &.{.{ .text = "Number" }} }},
            .elements = &.{
                // The parent is forward-referenced to prove collection is not source-order dependent.
                .{ .meta = .{ .id = "plural" }, .value = .{ .symbol = .{ .local = "plural" } }, .parent = .{ .local = "singular" }, .labels = &.{.{ .content = &.{.{ .text = "plural" }} }} },
                .{ .meta = .{ .id = "singular" }, .value = .{ .symbol = .{ .local = "singular" } }, .labels = &.{.{ .content = &.{.{ .text = "singular" }} }}, .abbreviations = &.{.{ .content = &.{.{ .text = "sg" }} }}, .description = &.{.{ .content = &.{.{ .text = "one" }} }} },
            },
        },
    };
    try validate.check(testing.allocator, &range, .{});

    const encoded = try packet.encode(testing.allocator, range, .{});
    defer testing.allocator.free(encoded);
    var decoded = try packet.decode(model.Resource, testing.allocator, encoded, .{});
    defer decoded.deinit();
    try testing.expectEqualDeep(range, decoded.value);
    try testing.expectEqualStrings("plural", decoded.value.range.elements[0].meta.id.?);
    try testing.expectEqualStrings("singular", decoded.value.range.elements[0].parent.?.local);
}

test "chained selections retain language declaration and inline reset context" {
    var forms = query.entry(&semantic_entry).select(.form, .children);
    const lemma = (try forms.next()).?;
    var representations = lemma.values(.representations);
    const representation = representations.next().?;
    const representation_text = representation.child(.text);
    try testing.expectEqualStrings("en-GB", representation_text.language.value.?);

    const entry: model.Entry = .{
        .id = "language-context",
        .headword = "context",
        .meta = .{ .language = .{ .tag = "en" } },
        .content = &.{.{ .sense = .{
            .meta = .{ .id = "sense" },
            .content = &.{.{ .definition = .{ .content = &.{
                .{ .text = "A " },
                .{ .element = .{ .name = .{ .local = "foreign" }, .language = .{ .tag = "fr" }, .content = &.{.{ .text = "bonjour" }} } },
                .{ .element = .{ .name = .{ .local = "reset" }, .language = .reset, .content = &.{
                    .{ .text = "unknown" },
                    .{ .element = .{ .name = .{ .local = "omitted" }, .content = &.{.{ .text = "after-reset" }} } },
                } } },
            } } }},
        } }},
    };

    var senses = query.entry(&entry).select(.sense, .descendants);
    const sense = (try senses.next()).?;
    try testing.expectEqualStrings("en", sense.language.value.?);
    try testing.expect(sense.language.declaration.?.* == .tag);
    try testing.expect((try senses.next()) == null);

    var definitions = sense.select(.definition, .children);
    const definition = (try definitions.next()).?;
    try testing.expectEqualStrings("en", definition.language.value.?);

    var inlines = definition.inlines();
    var text_count: usize = 0;
    var saw_french = false;
    var saw_reset = false;
    var saw_nested_reset = false;
    while (try inlines.next()) |event| {
        if (event.node.* != .text) continue;
        text_count += 1;
        if (std.mem.eql(u8, event.node.text, "bonjour")) {
            saw_french = true;
            try testing.expectEqualStrings("fr", event.language.value.?);
            try testing.expect(event.language.declaration.?.* == .tag);
        } else if (std.mem.eql(u8, event.node.text, "unknown")) {
            saw_reset = true;
            try testing.expect(event.language.value == null);
            try testing.expect(event.language.declaration.?.* == .reset);
        } else if (std.mem.eql(u8, event.node.text, "after-reset")) {
            saw_nested_reset = true;
            try testing.expect(event.language.value == null);
            try testing.expect(event.language.declaration.?.* == .reset);
        }
    }
    try testing.expectEqual(@as(usize, 4), text_count);
    try testing.expect(saw_french and saw_reset and saw_nested_reset);
}

test "inline and source hostility return typed errors" {
    const invalid_utf8: model.Entry = .{
        .id = "invalid-utf8",
        .headword = "invalid-utf8",
        .content = &.{.{ .definition = .{ .content = &.{.{ .text = "\xff" }} } }},
    };
    try testing.expectError(error.InvalidUtf8, validate.check(testing.allocator, &invalid_utf8, .{}));

    const invalid_source: model.Entry = .{
        .id = "invalid-source",
        .headword = "invalid-source",
        .content = &.{.{ .definition = .{ .meta = .{ .evidence = &.{.{ .target = .{ .anchor = .{ .source = "missing", .start = 0, .end = 1 } } }} } } }},
    };
    try testing.expectError(error.InvalidAnchor, validate.check(testing.allocator, &invalid_source, .{}));

    var extents = validate.SourceIndex{};
    defer extents.deinit(testing.allocator);
    try extents.add(testing.allocator, "same", 1);
    try testing.expectError(error.DuplicateIdentity, extents.add(testing.allocator, "same", 2));
    try testing.expectEqual(@as(?usize, 1), extents.length("same"));
}

test "rendering the selected rich definition preserves plain and XML text" {
    var definitions = query.entry(&semantic_entry).select(.definition, .descendants);
    const definition = (try definitions.next()).?;
    var output: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try render.write(definition.value.*, &writer, .plain);
    try testing.expectEqualStrings("the perceived hue", writer.buffered());
}
