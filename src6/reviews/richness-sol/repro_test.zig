const std = @import("std");
const lex = @import("lex6");

const t = std.testing;

test "resolved cross-document addresses are admitted when targets do not exist" {
    const entry: lex.model.Entry = .{
        .id = "source",
        .headword = "source",
        .content = &.{
            .{ .relation = .{ .predicate = .synonym, .target = .{ .entry = .{
                .id = "missing-entry",
                .fragment = "missing-sense",
            } } } },
            .{ .grammar = .{
                .name = .{ .local = "partOfSpeech" },
                .value = .{ .symbol = .{ .local = "noun" } },
                .range = .{ .resource = .{ .id = "missing-range", .fragment = "noun" } },
            } },
        },
    };

    // Both addresses claim a resolved domain, even though the library is empty.
    try lex.validate.check(t.allocator, &entry, .{});
    var owned = try lex.archive.build(t.allocator, .{ .entries = &.{entry} }, .{ .compression = .raw });
    defer owned.deinit();
    const archive = try lex.archive.Archive.open(owned.bytes, .{});
    try archive.verifyAll(t.allocator);
    try t.expect((try archive.resource("missing-range")) == null);
}

test "a validated local feature-structure reference has no public resolution path" {
    const entry: lex.model.Entry = .{
        .id = "agreement",
        .headword = "agreement",
        .content = &.{.{ .grammar = .{
            .name = .{ .local = "analysis" },
            .value = .{ .structure = .{
                .meta = .{ .id = "shared-number" },
                .fields = &.{.{
                    .name = .{ .local = "copy" },
                    .value = .{ .reference = .{ .local = "shared-number" } },
                }},
            } },
        } }},
    };

    try lex.validate.check(t.allocator, &entry, .{});
    try t.expect((try lex.query.resolve(&entry, "shared-number")) == null);
}

test "one relation can carry contradictory binary and participant targets" {
    const entry: lex.model.Entry = .{
        .id = "ambiguous",
        .headword = "ambiguous",
        .content = &.{
            .{ .relation = .{
                .predicate = .translation,
                .target = .{ .local = "sense-b" },
                .participants = &.{
                    .{ .role = .{ .local = "source" }, .target = .{ .local = "sense-a" } },
                    .{ .role = .{ .local = "target" }, .target = .{ .local = "sense-c" } },
                },
            } },
            .{ .sense = .{ .meta = .{ .id = "sense-a" } } },
            .{ .sense = .{ .meta = .{ .id = "sense-b" } } },
            .{ .sense = .{ .meta = .{ .id = "sense-c" } } },
        },
    };

    try lex.validate.check(t.allocator, &entry, .{});
    const relation = entry.content[0].relation;
    try t.expectEqualStrings("sense-b", relation.target.?.local);
    try t.expectEqualStrings("sense-c", relation.participants[1].target.local);
}

test "language admission accepts strings that are not BCP 47 tags" {
    const entry: lex.model.Entry = .{
        .id = "language",
        .headword = "language",
        .meta = .{ .language = .{ .tag = "-not--a-tag-" } },
    };
    try lex.validate.check(t.allocator, &entry, .{});
    const match = lex.query.entry(&entry);
    try t.expectEqualStrings("-not--a-tag-", match.language.value.?);
}

test "feature-structure identities are entry-wide rather than structure-scoped" {
    const entry: lex.model.Entry = .{
        .id = "two-analyses",
        .headword = "two-analyses",
        .content = &.{
            .{ .grammar = .{
                .name = .{ .local = "analysis-one" },
                .value = .{ .structure = .{ .meta = .{ .id = "L1" } } },
            } },
            .{ .grammar = .{
                .name = .{ .local = "analysis-two" },
                .value = .{ .structure = .{ .meta = .{ .id = "L1" } } },
            } },
        },
    };

    // Independent feature structures cannot reuse a local label.
    try t.expectError(error.DuplicateIdentity, lex.validate.check(t.allocator, &entry, .{}));
}

test "values accepts scalar byte-string fields as byte collections" {
    const entry: lex.model.Entry = .{ .id = "entry", .headword = "cat" };
    var bytes = lex.query.entry(&entry).values(.headword);
    try t.expectEqual(@as(u8, 'c'), bytes.next().?.value.*);
    try t.expectEqual(@as(u8, 'a'), bytes.next().?.value.*);
    try t.expectEqual(@as(u8, 't'), bytes.next().?.value.*);
    try t.expect(bytes.next() == null);
}
