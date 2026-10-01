const std = @import("std");
const model = @import("model.zig");
const archive = @import("archive.zig");
const query = @import("query.zig");
const validate = @import("validate.zig");
const testing = std.testing;

fn span(comptime start: u32, comptime end: u32) model.RealizationSpan {
    return .{ .representation = .{ .local = "surface" }, .start = start, .end = end };
}

fn example(comptime surface: []const u8, comptime language: []const u8, comptime kind: @FieldType(model.Analysis, "kind"), comptime segments: []const model.Item) model.Entry {
    return .{
        .id = language,
        .headword = surface,
        .meta = .{ .language = .{ .tag = language } },
        .kind = if (kind == .multiword) .multiword else .word,
        .content = &.{
            .{ .form = .{
                .meta = .{ .id = "form" },
                .representations = &.{.{
                    .meta = .{ .id = "surface" },
                    .text = .{ .content = &.{.{ .element = .{
                        .name = .{ .local = "surface" },
                        .content = &.{ .{ .text = surface }, .{ .comment = "no surface bytes" } },
                    } }} },
                }},
            } },
            .{ .analysis = .{
                .meta = .{ .id = "analysis-1" },
                .kind = kind,
                .form = .{ .local = "form" },
                .content = segments,
            } },
            .{ .analysis = .{
                .meta = .{ .id = "analysis-2", .language = .reset },
                .kind = kind,
                .form = .{ .local = "form" },
                .content = segments,
            } },
        },
    };
}

const turkish = example("evlerimizden", "tr", .morphology, &.{
    .{ .segment = .{ .role = .{ .local = "root" }, .target = .{ .entry = .{ .id = "ev" } }, .realizations = &.{span(0, 2)} } },
    .{ .segment = .{
        .role = .{ .local = "suffix" },
        .realizations = &.{span(2, 5)},
        .content = &.{.{ .grammar = .{ .name = .{ .local = "number" }, .value = .{ .symbol = .{ .local = "plural" } } } }},
    } },
    .{ .segment = .{ .role = .{ .local = "possessive" }, .realizations = &.{span(5, 9)} } },
    .{ .segment = .{ .role = .{ .local = "ablative" }, .realizations = &.{span(9, 12)} } },
});

// Root consonants and vocalic pattern share the exact Arabic representation.
// Neither a byte prefix/suffix assumption nor whitespace tokenization applies.
const arabic = example("كَتَبَ", "ar", .morphology, &.{
    .{ .segment = .{ .role = .{ .local = "root" }, .realizations = &.{ span(0, 2), span(4, 6), span(8, 10) } } },
    .{ .segment = .{ .role = .{ .local = "pattern" }, .realizations = &.{ span(2, 4), span(6, 8), span(10, 12) } } },
    .{ .segment = .{ .role = .{ .local = "zero-ending" }, .realizations = &.{span(12, 12)} } },
});

const japanese = example("取り戻す", "ja", .orthography, &.{
    .{ .segment = .{ .kind = .grapheme, .realizations = &.{span(0, 3)} } },
    .{ .segment = .{ .kind = .grapheme, .realizations = &.{span(3, 6)} } },
    .{ .segment = .{ .kind = .grapheme, .realizations = &.{span(6, 9)} } },
    .{ .segment = .{ .kind = .grapheme, .realizations = &.{span(9, 12)} } },
});

const german = example("nimmt heute teil", "de", .multiword, &.{
    .{ .segment = .{
        .kind = .word,
        .target = .{ .entry = .{ .id = "teilnehmen" } },
        .realizations = &.{ span(0, 5), span(12, 16) },
    } },
    .{ .segment = .{ .kind = .slot, .role = .{ .local = "adverbial-slot" }, .realizations = &.{span(6, 11)} } },
});

test "multilingual analyses preserve ambiguity discontinuity zero realization and local grammar" {
    const entries = [_]model.Entry{ turkish, arabic, japanese, german };
    var owned = try archive.build(testing.allocator, .{ .entries = &entries }, .{ .index_entry_ids = true });
    defer owned.deinit();
    const view = try archive.Archive.open(owned.bytes, .{});
    try view.verifyAll(testing.allocator);
    for (entries, 0..) |original, ordinal| {
        var decoded = try view.load(testing.allocator, archive.EntryId{ .value = @intCast(ordinal) });
        defer decoded.deinit();
        try testing.expectEqualDeep(original, decoded.value);
        var analyses = query.entry(&decoded.value).select(.analysis, .children);
        const first = (try analyses.next()).?;
        const second = (try analyses.next()).?;
        try testing.expectEqualStrings(original.meta.language.tag, first.language.value.?);
        try testing.expect(second.language.value == null);
        try testing.expect((try analyses.next()) == null);
        var segments = first.select(.segment, .children);
        var count: usize = 0;
        while (try segments.next()) |segment| {
            var realizations = segment.values(.realizations);
            while (realizations.next()) |realization| try testing.expect(realization.value.end >= realization.value.start);
            count += 1;
        }
        try testing.expectEqual(original.content[1].analysis.content.len, count);
        try testing.expect((try query.resolve(&decoded.value, "analysis-1")).?.as(model.Analysis) != null);
    }
}

test "realization extents require representation identity and UTF8 scalar boundaries" {
    const base = example("é水", "fr", .morphology, &.{});
    var spans = [_]model.RealizationSpan{span(0, 5)};
    var segments = [_]model.Item{.{ .segment = .{ .realizations = &spans } }};
    const content = [_]model.Item{ base.content[0], .{ .analysis = .{ .content = &segments } } };
    var entry = base;
    entry.content = &content;
    try validate.check(testing.allocator, &entry, .{});
    const invalid = [_][2]u32{ .{ 1, 2 }, .{ 2, 3 }, .{ 5, 6 }, .{ 5, 2 } };
    for (invalid) |bounds| {
        spans[0].start = bounds[0];
        spans[0].end = bounds[1];
        try testing.expectError(error.InvalidRealization, validate.check(testing.allocator, &entry, .{}));
    }
    spans[0] = span(5, 5);
    try validate.check(testing.allocator, &entry, .{});
    spans[0].representation = .{ .local = "missing" };
    try testing.expectError(error.UnresolvedLocal, validate.check(testing.allocator, &entry, .{}));
    spans[0].representation = .{ .local = "form" };
    try testing.expectError(error.InvalidReferenceKind, validate.check(testing.allocator, &entry, .{}));
    spans[0].representation = .{ .entry = .{ .id = "external" } };
    try testing.expectError(error.InvalidReferenceKind, validate.check(testing.allocator, &entry, .{}));
    spans[0].representation = .{ .entry = .{ .id = "external", .fragment = "surface" } };
    try validate.check(testing.allocator, &entry, .{});
    spans[0].representation = .{ .unresolved = .{ .identifier = "unknown-surface" } };
    try validate.check(testing.allocator, &entry, .{});
}

test "morphological admission releases every pending span and identity on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            try validate.check(allocator, &arabic, .{});
        }
    }.run, .{});
}

test "surface range queries stream exact discontinuous Arabic realizations" {
    const location = (try query.resolve(&arabic, "surface")).?;
    const representation = query.Match(model.Representation){ .value = location.as(model.Representation).?, .language = location.language };
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    for (arabic.content[1].analysis.content[0].segment.realizations) |realization| {
        var range = try representation.surface(realization.start, realization.end);
        while (try range.next()) |fragment| {
            try testing.expectEqualStrings("ar", fragment.language.value.?);
            try writer.writeAll(fragment.bytes);
        }
    }
    try testing.expectEqualStrings("كتب", writer.buffered());
    var zero = try representation.surface(12, 12);
    try testing.expectEqualStrings("", (try zero.next()).?.bytes);
    try testing.expect((try zero.next()) == null);
    var invalid = try representation.surface(1, 2);
    try testing.expectError(error.InvalidRealization, invalid.next());
    var overlong = try representation.surface(12, 14);
    try testing.expectError(error.InvalidRealization, overlong.next());
}
