const std = @import("std");
const model = @import("model.zig");
const archive = @import("archive.zig");

fn refreshRoot(bytes: []u8) void {
    const index_offset: usize = @intCast(std.mem.readInt(u64, bytes[32..40], .little));
    const directory_offset: usize = @intCast(std.mem.readInt(u64, bytes[48..56], .little));
    const pages_offset: usize = @intCast(std.mem.readInt(u64, bytes[64..72], .little));
    var state = std.crypto.hash.sha2.Sha256.init(.{});
    state.update(bytes[0..80]);
    state.update(bytes[index_offset..directory_offset]);
    state.update(bytes[directory_offset..pages_offset]);
    var digest: [32]u8 = undefined;
    state.final(&digest);
    @memcpy(bytes[80..112], &digest);
}

fn refreshFirstPageAndRoot(bytes: []u8) void {
    const directory_offset: usize = @intCast(std.mem.readInt(u64, bytes[48..56], .little));
    const pages_offset: usize = @intCast(std.mem.readInt(u64, bytes[64..72], .little));
    const page_relative: usize = @intCast(std.mem.readInt(u64, bytes[directory_offset..][0..8], .little));
    const page_length: usize = std.mem.readInt(u32, bytes[directory_offset + 8 ..][0..4], .little);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[pages_offset + page_relative ..][0..page_length], &digest, .{});
    @memcpy(bytes[directory_offset + 32 ..][0..32], &digest);
    refreshRoot(bytes);
}

const ordinary_content = [_]model.Item{
    .{ .form = .{ .meta = .{ .id = "form-1" } } },
    .{ .sense = .{
        .meta = .{ .id = "sense-1" },
        .content = &.{.{ .definition = .{ .content = &.{.{ .text = "owned prose" }} } }},
    } },
};

const repeated_prose = "lexical lexical lexical lexical lexical lexical lexical lexical " ** 300;
const compressed_content = [_]model.Item{
    .{ .form = .{ .meta = .{ .id = "form-1" } } },
    .{ .sense = .{
        .meta = .{ .id = "sense-1" },
        .content = &.{.{ .definition = .{ .content = &.{.{ .text = repeated_prose }} } }},
    } },
};

fn entry(id: []const u8, headword: []const u8, keys: []const model.SearchKey) model.Entry {
    return .{
        .id = id,
        .headword = headword,
        .keys = keys,
        .content = &ordinary_content,
    };
}

test "empty archive opens verifies and has no hits" {
    var owned = try archive.build(std.testing.allocator, .{ .entries = &.{} }, .{ .compression = .raw });
    defer owned.deinit();
    const view = try archive.Archive.open(owned.bytes, .{});
    var exact = try view.lookup("nothing");
    try std.testing.expect((try exact.next()) == null);
    var prefix = try view.prefix("");
    try std.testing.expect((try prefix.next()) == null);
    try view.verifyAll(std.testing.allocator);
}

test "hot lookup preserves duplicate claims form identity and physical order" {
    const entries = [_]model.Entry{
        entry("z-id", "zebra", &.{.{ .spelling = "shared", .form = "form-1" }}),
        entry("a-id", "alpha", &.{
            .{ .spelling = "shared" },
            .{ .spelling = "alpha", .form = "form-1" },
            .{ .spelling = "shared", .form = "form-1" },
        }),
    };
    var owned = try archive.build(std.testing.allocator, .{ .entries = &entries }, .{ .compression = .raw, .target_page_bytes = 256 });
    defer owned.deinit();
    const view = try archive.Archive.open(owned.bytes, .{});

    var shared = try view.lookup("shared");
    const first = (try shared.next()).?;
    const second = (try shared.next()).?;
    const third = (try shared.next()).?;
    try std.testing.expectEqual(@as(u32, 0), first.entry.value);
    try std.testing.expectEqualStrings("form-1", first.form.?);
    try std.testing.expectEqual(@as(u32, 1), second.entry.value);
    try std.testing.expect(second.form == null);
    try std.testing.expectEqual(@as(u32, 1), third.entry.value);
    try std.testing.expectEqualStrings("form-1", third.form.?);
    try std.testing.expect((try shared.next()) == null);

    var alpha = try view.lookup("alpha");
    try std.testing.expect((try alpha.next()).?.form == null);
    try std.testing.expectEqualStrings("form-1", (try alpha.next()).?.form.?);
    try std.testing.expect((try alpha.next()) == null);

    var all = try view.prefix("");
    var count: usize = 0;
    while (try all.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 6), count);

    var invalid_bytes = try view.prefix("\xff");
    try std.testing.expect((try invalid_bytes.next()) == null);
}

test "loaded entry has independent byte lifetime" {
    const source = entry("independent", "durable", &.{});
    var owned = try archive.build(std.testing.allocator, .{ .entries = &.{source} }, .{ .compression = .raw });
    var view = try archive.Archive.open(owned.bytes, .{});
    var loaded = try view.load(std.testing.allocator, archive.EntryId{ .value = 0 });
    defer loaded.deinit();
    owned.deinit();
    view = undefined;
    try std.testing.expectEqualStrings("durable", loaded.value.headword);
    try std.testing.expectEqualStrings("owned prose", loaded.value.content[1].sense.content[0].definition.content[0].text);
}

test "metadata and page corruption fail at their intended boundaries" {
    const source = entry("digest", "digest", &.{});
    var owned = try archive.build(std.testing.allocator, .{ .entries = &.{source} }, .{ .compression = .raw });
    defer owned.deinit();

    const metadata_copy = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(metadata_copy);
    metadata_copy[112] ^= 1;
    try std.testing.expectError(error.MetadataDigestMismatch, archive.Archive.open(metadata_copy, .{}));

    const page_copy = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(page_copy);
    const page_offset: usize = @intCast(std.mem.readInt(u64, page_copy[64..72], .little));
    page_copy[page_offset] ^= 1;
    const view = try archive.Archive.open(page_copy, .{});
    var hit = try view.lookup("digest");
    try std.testing.expect((try hit.next()) != null);
    try std.testing.expectError(error.PageDigestMismatch, view.load(std.testing.allocator, archive.EntryId{ .value = 0 }));
    try std.testing.expectError(error.PageDigestMismatch, view.verifyAll(std.testing.allocator));
}

test "recomputed metadata root cannot hide gaps or nonzero reserved bytes" {
    const source = entry("metadata", "metadata", &.{});
    var owned = try archive.build(std.testing.allocator, .{ .entries = &.{source} }, .{ .compression = .raw });
    defer owned.deinit();

    const index_gap = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(index_gap);
    const index_offset: usize = @intCast(std.mem.readInt(u64, index_gap[32..40], .little));
    const first_block_offset_at = index_offset + 8 + 4;
    const first_block_offset = std.mem.readInt(u32, index_gap[first_block_offset_at..][0..4], .little);
    std.mem.writeInt(u32, index_gap[first_block_offset_at..][0..4], first_block_offset + 1, .little);
    refreshRoot(index_gap);
    try std.testing.expectError(error.InvalidIndex, archive.Archive.open(index_gap, .{}));

    const reserved = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(reserved);
    const directory_offset: usize = @intCast(std.mem.readInt(u64, reserved[48..56], .little));
    reserved[directory_offset + 25] = 1;
    refreshRoot(reserved);
    try std.testing.expectError(error.InvalidDirectory, archive.Archive.open(reserved, .{}));

    const resources = [_]model.Resource{.{ .source = .{ .id = "catalog", .media_type = "text/plain", .bytes = "x" } }};
    var resource_owned = try archive.build(std.testing.allocator, .{ .entries = &.{}, .resources = &resources }, .{ .compression = .raw });
    defer resource_owned.deinit();
    const catalog_gap = resource_owned.bytes;
    const resource_index_offset: usize = @intCast(std.mem.readInt(u64, catalog_gap[32..40], .little));
    const lexical_length: usize = std.mem.readInt(u32, catalog_gap[resource_index_offset..][0..4], .little);
    const catalog_offset = resource_index_offset + 8 + lexical_length;
    const first_record = std.mem.readInt(u32, catalog_gap[catalog_offset..][0..4], .little);
    std.mem.writeInt(u32, catalog_gap[catalog_offset..][0..4], first_record + 1, .little);
    refreshRoot(catalog_gap);
    try std.testing.expectError(error.InvalidCatalog, archive.Archive.open(catalog_gap, .{}));
}

test "verifyAll rejects forged duplicate semantic IDs with valid digests" {
    const entries = [_]model.Entry{
        entry("dup-a", "alpha", &.{}),
        entry("dup-b", "bravo", &.{}),
    };
    var owned = try archive.build(std.testing.allocator, .{ .entries = &entries }, .{ .compression = .raw });
    defer owned.deinit();
    const pages_offset: usize = @intCast(std.mem.readInt(u64, owned.bytes[64..72], .little));
    const position = std.mem.indexOfPos(u8, owned.bytes, pages_offset, "dup-b") orelse return error.TestUnexpectedResult;
    @memcpy(owned.bytes[position..][0..5], "dup-a");
    refreshFirstPageAndRoot(owned.bytes);
    const view = try archive.Archive.open(owned.bytes, .{});
    try std.testing.expectError(error.DuplicateEntryId, view.verifyAll(std.testing.allocator));
}

test "all document readers reject a resealed resource catalog mismatch" {
    const resources = [_]model.Resource{.{ .values = .{ .id = "authority-a" } }};
    var owned = try archive.build(std.testing.allocator, .{ .entries = &.{}, .resources = &resources }, .{ .compression = .raw });
    defer owned.deinit();
    const pages_offset: usize = @intCast(std.mem.readInt(u64, owned.bytes[64..72], .little));
    const position = std.mem.indexOfPos(u8, owned.bytes, pages_offset, "authority-a") orelse return error.TestUnexpectedResult;
    @memcpy(owned.bytes[position..][0..11], "authority-b");
    refreshFirstPageAndRoot(owned.bytes);
    const view = try archive.Archive.open(owned.bytes, .{});
    const address = (try view.resource("authority-a")).?.resource;
    try std.testing.expectError(error.CatalogMismatch, view.load(std.testing.allocator, address));
    try std.testing.expectError(error.CatalogMismatch, view.verifyAll(std.testing.allocator));
    var reader = try archive.Reader.init(std.testing.allocator, &view, .{});
    defer reader.deinit();
    try std.testing.expectError(error.CatalogMismatch, reader.load(address));
    // Reusing an already decoded page must not bypass document admission.
    try std.testing.expectError(error.CatalogMismatch, reader.load(address));
    try std.testing.expectEqual(@as(usize, 1), reader.stats.page_loads);
}

test "forced bzip3 pages roundtrip and multiple pages remain independent" {
    var entries = [_]model.Entry{
        entry("one", "compressible-one", &.{}),
        entry("two", "compressible-two", &.{}),
        entry("three", "compressible-three", &.{}),
    };
    for (&entries) |*value| value.content = &compressed_content;
    var owned = try archive.build(std.testing.allocator, .{ .entries = &entries }, .{
        .compression = .bzip3,
        .target_page_bytes = 1024,
        .max_page_bytes = 64 * 1024,
        .compression_limits = .{ .max_block_bytes = 128 * 1024 },
    });
    defer owned.deinit();
    const view = try archive.Archive.open(owned.bytes, .{
        .max_page_bytes = 64 * 1024,
        .compression_limits = .{ .max_block_bytes = 128 * 1024 },
    });
    try view.verifyAll(std.testing.allocator);
    var loaded = try view.load(std.testing.allocator, archive.EntryId{ .value = 2 });
    defer loaded.deinit();
    try std.testing.expectEqualStrings("compressible-three", loaded.value.headword);
}

test "restart index crosses blocks and returns borrowed two-slice spellings" {
    const names = [_][]const u8{
        "common-00", "common-01", "common-02", "common-03", "common-04", "common-05",
        "common-06", "common-07", "common-08", "common-09", "common-10", "common-11",
        "common-12", "common-13", "common-14", "common-15", "common-16", "common-17",
    };
    var entries: [names.len]model.Entry = undefined;
    for (&entries, names) |*value, name| value.* = entry(name, name, &.{});
    var owned = try archive.build(std.testing.allocator, .{ .entries = &entries }, .{ .compression = .raw });
    defer owned.deinit();
    const view = try archive.Archive.open(owned.bytes, .{});
    var hits = try view.prefix("common-1");
    var expected: usize = 10;
    while (try hits.next()) |hit| : (expected += 1) {
        try std.testing.expect(hit.spelling.prefix.len != 0);
        try std.testing.expect(hit.spelling.eql(names[expected]));
    }
    try std.testing.expectEqual(@as(usize, 18), expected);
}

test "lookup skips a high-multiplicity posting extent" {
    var names: [256][12]u8 = undefined;
    var entries: [256]model.Entry = undefined;
    for (&entries, 0..) |*value, index| {
        const id = try std.fmt.bufPrint(&names[index], "id-{d:0>3}", .{index});
        value.* = entry(id, if (index == entries.len - 1) "target" else "homograph", &.{});
    }
    var owned = try archive.build(std.testing.allocator, .{ .entries = &entries }, .{ .compression = .raw });
    defer owned.deinit();
    const view = try archive.Archive.open(owned.bytes, .{});
    var hits = try view.lookup("target");
    const hit = (try hits.next()).?;
    try std.testing.expectEqual(@as(u32, 255), hit.entry.value);
    try std.testing.expect((try hits.next()) == null);
}

test "shared source resource supplies hot extents and loads independently" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, sharedResourceHarness, .{});
}

fn sharedResourceHarness(allocator: std.mem.Allocator) !void {
    const resources = [_]model.Resource{.{ .source = .{
        .id = "shared-source",
        .media_type = "text/plain",
        .bytes = "source bytes",
    } }};
    const entries = [_]model.Entry{.{
        .id = "anchored",
        .headword = "anchored",
        .residuals = &.{.{ .source = "shared-source", .start = 0, .end = 6 }},
    }};
    var owned = try archive.build(allocator, .{ .entries = &entries, .resources = &resources }, .{ .compression = .raw });
    defer owned.deinit();
    const view = try archive.Archive.open(owned.bytes, .{});
    const catalog = (try view.resource("shared-source")).?;
    try std.testing.expectEqual(archive.ResourceKind.source, catalog.kind);
    try std.testing.expectEqual(@as(?usize, 12), catalog.source_length);
    try std.testing.expectEqual(@as(u32, 1), catalog.resource.value);
    var loaded_entry = try view.load(allocator, archive.EntryId{ .value = 0 });
    defer loaded_entry.deinit();
    var loaded_source = try view.load(allocator, catalog.resource);
    defer loaded_source.deinit();
    try std.testing.expectEqualStrings("source bytes", loaded_source.value.source.bytes);
    try view.verifyAll(allocator);
}

test "admission rejects duplicate IDs and declared size limits" {
    const duplicate = [_]model.Entry{
        entry("same", "one", &.{}),
        entry("same", "two", &.{}),
    };
    try std.testing.expectError(error.DuplicateEntryId, archive.build(std.testing.allocator, .{ .entries = &duplicate }, .{ .compression = .raw }));
    try std.testing.expectError(error.KeyTooLong, archive.build(std.testing.allocator, .{ .entries = &.{entry("id", "oversize", &.{})} }, .{
        .compression = .raw,
        .max_key_bytes = 3,
    }));
    try std.testing.expectError(error.DocumentTooLarge, archive.build(std.testing.allocator, .{ .entries = &.{entry("id", "word", &.{})} }, .{
        .compression = .raw,
        .max_document_bytes = 8,
    }));
}

test "raw archive build and load are allocation-failure safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(failing: std.mem.Allocator) !void {
            const source = entry("allocation", "allocation", &.{});
            var owned = try archive.build(failing, .{ .entries = &.{source} }, .{ .compression = .raw });
            defer owned.deinit();
            const view = try archive.Archive.open(owned.bytes, .{});
            var loaded = try view.load(failing, archive.EntryId{ .value = 0 });
            defer loaded.deinit();
            try std.testing.expectEqualStrings("allocation", loaded.value.headword);
            try view.verifyAll(failing);
        }
    }.run, .{});
}
