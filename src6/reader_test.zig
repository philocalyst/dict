const std = @import("std");
const model = @import("model.zig");
const archive = @import("archive.zig");
const packet = @import("packet.zig");
const testing = std.testing;

const entries = [_]model.Entry{
    .{ .id = "english", .headword = "bank", .content = &.{.{ .sense = .{
        .meta = .{ .id = "finance", .language = .{ .tag = "en" } },
        .content = &.{.{ .definition = .{ .content = &.{.{ .text = "A financial institution." }} } }},
    } }} },
    .{ .id = "french", .headword = "banque", .content = &.{.{ .sense = .{
        .meta = .{ .id = "finance", .language = .{ .tag = "fr" } },
        .content = &.{.{ .definition = .{ .content = &.{.{ .text = "Un établissement financier." }} } }},
    } }} },
    .{ .id = "large", .headword = "large", .content = &.{.{ .definition = .{
        .content = &.{.{ .text = "A long independently owned lexical example. " ** 300 }},
    } }} },
};

test "reader decodes one page once and loaded documents survive eviction" {
    var owned = try archive.build(testing.allocator, .{ .entries = &entries }, .{ .target_page_bytes = 4096 });
    const view = try archive.Archive.open(owned.bytes, .{});
    var reader = try archive.Reader.init(testing.allocator, &view, .{});
    var first = try reader.load(archive.EntryId{ .value = 0 });
    defer first.deinit();
    var second = try reader.load(archive.EntryId{ .value = 1 });
    defer second.deinit();
    try testing.expectEqual(@as(usize, 1), reader.stats.page_loads);
    try testing.expectEqual(@as(usize, 1), reader.stats.bzip3_decodes);
    try testing.expectEqual(@as(usize, 1), reader.stats.cache_hits);
    var last = try reader.load(archive.EntryId{ .value = 2 });
    defer last.deinit();
    try testing.expectEqual(@as(usize, 2), reader.stats.page_loads);
    var again = try reader.load(archive.EntryId{ .value = 0 });
    defer again.deinit();
    try testing.expectEqual(@as(usize, 3), reader.stats.page_loads);
    reader.deinit();
    owned.deinit();
    try testing.expectEqualStrings("english", first.value.id);
    try testing.expectEqualStrings("french", second.value.id);
    try testing.expectEqualStrings("large", last.value.id);
}

test "logical link preparation is explicit and targets resolve in owned documents" {
    var owned = try archive.build(testing.allocator, .{ .entries = &entries }, .{ .compression = .raw });
    defer owned.deinit();
    const view = try archive.Archive.open(owned.bytes, .{});
    var reader = try archive.Reader.init(testing.allocator, &view, .{});
    defer reader.deinit();
    const target: model.Reference = .{ .entry = .{ .id = "french", .fragment = "finance" } };
    try testing.expectError(error.DocumentCatalogRequired, reader.follow(target));
    try reader.prepareLinks();
    const loads = reader.stats.page_loads;
    try reader.prepareLinks();
    try testing.expectEqual(loads, reader.stats.page_loads);
    var followed = try reader.follow(target);
    defer followed.found.deinit();
    const node = (try followed.found.locate()).?;
    try testing.expect(node.as(model.Sense) != null);
    try testing.expectEqualStrings("fr", node.language.value.?);
    try testing.expectEqualStrings("french", followed.found.document.value.entry.id);
    var root = try reader.follow(.{ .entry = .{ .id = "english" } });
    defer root.found.deinit();
    try testing.expect((try root.found.locate()).?.as(model.Entry) != null);
    try testing.expect((try reader.follow(.{ .entry = .{ .id = "missing" } })) == .unavailable);
    try testing.expect((try reader.follow(.{ .entry = .{ .id = "french", .fragment = "absent" } })) == .unavailable);
    try testing.expect((try reader.follow(.{ .iri = "urn:external" })) == .unavailable);
    try testing.expect((try reader.follow(.{ .unresolved = .{ .identifier = "printed-link" } })) == .unresolved);
    try testing.expectError(error.LocalReferenceRequiresDocument, reader.follow(.{ .local = "finance" }));
}

test "shared atomic values and independent value libraries roundtrip through real pages" {
    const shared = model.SharedValue{ .meta = .{ .id = "number" }, .value = .{ .symbol = .{ .local = "plural" } } };
    const article = model.Entry{ .id = "forms", .headword = "banks", .content = &.{
        .{ .grammar = .{ .name = .{ .local = "number" }, .value = .{ .shared = &shared } } },
        .{ .grammar = .{ .name = .{ .local = "agreement" }, .value = .{ .reference = .{ .local = "number" } } } },
    } };
    const resources = [_]model.Resource{.{ .values = .{ .id = "features", .values = &.{shared} } }};
    var owned = try archive.build(testing.allocator, .{ .entries = &.{article}, .resources = &resources }, .{});
    defer owned.deinit();
    const view = try archive.Archive.open(owned.bytes, .{});
    try view.verifyAll(testing.allocator);
    var reader = try archive.Reader.init(testing.allocator, &view, .{});
    defer reader.deinit();
    var loaded = try reader.load(archive.EntryId{ .value = 0 });
    defer loaded.deinit();
    const binding = loaded.value.content[0].grammar.value.shared;
    try testing.expect(binding != &shared);
    try testing.expectEqualStrings("plural", binding.value.symbol.local);
    var target = try reader.follow(.{ .resource = .{ .id = "features", .fragment = "number" } });
    defer target.found.deinit();
    try testing.expect((try target.found.locate()).?.as(model.SharedValue) != null);
}

test "caller-driven link cycles obey the session hop budget" {
    var owned = try archive.build(testing.allocator, .{ .entries = &entries }, .{ .compression = .raw });
    defer owned.deinit();
    const view = try archive.Archive.open(owned.bytes, .{});
    var reader = try archive.Reader.init(testing.allocator, &view, .{ .max_link_hops = 1 });
    defer reader.deinit();
    try reader.prepareLinks();
    var result = try reader.follow(.{ .entry = .{ .id = "english" } });
    defer result.found.deinit();
    try testing.expectError(error.HopLimit, reader.follow(.{ .entry = .{ .id = "english" } }));
}

test "cached page admission checks every frame and rejects corrupt replacement" {
    var owned = try archive.build(testing.allocator, .{ .entries = &entries }, .{ .target_page_bytes = 4096 });
    defer owned.deinit();
    const directory: usize = @intCast(std.mem.readInt(u64, owned.bytes[48..56], .little));
    const pages: usize = @intCast(std.mem.readInt(u64, owned.bytes[64..72], .little));
    const second: usize = @intCast(std.mem.readInt(u64, owned.bytes[directory + 64 ..][0..8], .little));
    owned.bytes[pages + second] ^= 1;
    const view = try archive.Archive.open(owned.bytes, .{});
    var reader = try archive.Reader.init(testing.allocator, &view, .{});
    defer reader.deinit();
    var first = try reader.load(archive.EntryId{ .value = 0 });
    defer first.deinit();
    try testing.expectError(error.PageDigestMismatch, reader.load(archive.EntryId{ .value = 2 }));
    try testing.expectEqualStrings("english", first.value.id);
    var recovered = try reader.load(archive.EntryId{ .value = 1 });
    defer recovered.deinit();
    try testing.expectEqualStrings("french", recovered.value.id);
}

fn allocationHarness(allocator: std.mem.Allocator, bytes: []const u8) !void {
    const view = try archive.Archive.open(bytes, .{});
    var reader = try archive.Reader.init(allocator, &view, .{});
    defer reader.deinit();
    try reader.prepareLinks();
    var result = try reader.follow(.{ .entry = .{ .id = "english", .fragment = "finance" } });
    defer result.found.deinit();
    _ = try result.found.locate();
}

test "page cache and derived link catalog clean up every allocation failure" {
    var owned = try archive.build(testing.allocator, .{ .entries = entries[0..2] }, .{ .compression = .raw });
    defer owned.deinit();
    try testing.checkAllAllocationFailures(testing.allocator, allocationHarness, .{owned.bytes});
}

test "schema evolution rejects old packets and bounds cyclic ownership edges" {
    try testing.expectError(error.UnsupportedVersion, packet.decode(u8, testing.allocator, "LXP6\x01\x00", .{}));
    const Recursive = struct { next: ?*const @This() };
    var cycle = Recursive{ .next = null };
    cycle.next = &cycle;
    try testing.expectError(error.DepthLimit, packet.encode(testing.allocator, cycle, .{ .max_depth = 8 }));
    const shared = model.SharedValue{ .meta = .{ .id = "one" }, .value = .{ .integer = 1 } };
    const bytes = try packet.encode(testing.allocator, model.Value{ .shared = &shared }, .{});
    defer testing.allocator.free(bytes);
    try testing.expectError(error.AllocationLimit, packet.decode(model.Value, testing.allocator, bytes, .{ .max_allocation_bytes = 0 }));
}

test "cached framing rejects a malformed later packet even when digests are recomputed" {
    var owned = try archive.build(testing.allocator, .{ .entries = entries[0..2] }, .{ .compression = .raw });
    defer owned.deinit();
    const directory: usize = @intCast(std.mem.readInt(u64, owned.bytes[48..56], .little));
    const pages: usize = @intCast(std.mem.readInt(u64, owned.bytes[64..72], .little));
    const first_size: usize = std.mem.readInt(u32, owned.bytes[pages..][0..4], .little);
    std.mem.writeInt(u32, owned.bytes[pages + 4 + first_size ..][0..4], std.math.maxInt(u32), .little);
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var digest: [32]u8 = undefined;
    Sha256.hash(owned.bytes[pages..], &digest, .{});
    @memcpy(owned.bytes[directory + 32 ..][0..32], &digest);
    var root = Sha256.init(.{});
    root.update(owned.bytes[0..80]);
    root.update(owned.bytes[112..pages]);
    root.final(&digest);
    @memcpy(owned.bytes[80..112], &digest);

    const view = try archive.Archive.open(owned.bytes, .{});
    var reader = try archive.Reader.init(testing.allocator, &view, .{});
    defer reader.deinit();
    // The first packet is intact; admitting its page must still reject the
    // malformed second frame before publishing any cached boundary table.
    try testing.expectError(error.InvalidPage, reader.load(archive.EntryId{ .value = 0 }));
    try testing.expectEqual(@as(usize, 0), reader.stats.page_loads);
    std.mem.writeInt(u16, owned.bytes[8..10], 1, .little);
    try testing.expectError(error.UnsupportedVersion, archive.Archive.open(owned.bytes, .{}));
}

fn pointerAllocationHarness(allocator: std.mem.Allocator) !void {
    const value: model.Value = .{ .shared = &.{ .meta = .{ .id = "shared" }, .value = .{ .text = "owned payload" } } };
    const bytes = try packet.encode(allocator, value, .{});
    defer allocator.free(bytes);
    var decoded = try packet.decode(model.Value, allocator, bytes, .{});
    defer decoded.deinit();
    try testing.expectEqualStrings("owned payload", decoded.value.shared.value.text);
}

test "single-item packet ownership edges clean up all allocation failures" {
    try testing.checkAllAllocationFailures(testing.allocator, pointerAllocationHarness, .{});
}
