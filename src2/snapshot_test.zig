const std = @import("std");
const compile = @import("compile.zig");
const schema = @import("schema.zig");
const snap = @import("snapshot.zig");
const text = @import("text.zig");

fn repairRoot(bytes: []u8) void {
    const directory_offset: usize = @intCast(std.mem.readInt(u64, bytes[24..32], .little));
    const directory_length: usize = @intCast(std.mem.readInt(u64, bytes[32..40], .little));
    var hash = std.hash.XxHash3.init(0);
    hash.update(bytes[0..40]);
    hash.update(&[_]u8{0} ** 8);
    hash.update(bytes[48..snap.header_bytes]);
    hash.update(bytes[directory_offset..][0..directory_length]);
    std.mem.writeInt(u64, bytes[40..48], hash.final(), .little);
}

fn tinyContainer(allocator: std.mem.Allocator) !snap.Owned {
    return snap.write(allocator, .{ .profile_id = 77 }, &.{
        .{ .kind = .forest, .bytes = "forest" },
        .{ .kind = .columns, .bytes = "columns" },
    });
}

fn compiledFixture(allocator: std.mem.Allocator) !compile.Compiled {
    var builder = compile.Builder.init(allocator);
    defer builder.deinit();
    const entry = try builder.root(.entry, .{ .headword = "bank", .lang = "en" });
    const form = try builder.child(entry, .form, .{ .written = "bank" });
    _ = form;
    const sense = try builder.child(entry, .sense, .{});
    const definition = try builder.child(sense, .definition, .{ .text = "a river edge" });
    _ = definition;
    return builder.compile();
}

test "writer and borrowed open preserve the exact routing ledger" {
    var owned = try tinyContainer(std.testing.allocator);
    defer owned.deinit();
    const view = try snap.Snapshot.openContainer(owned.bytes, .{ .profile_id = 77 });
    try std.testing.expectEqual(@as(u64, 2 * snap.directory_bytes), view.header.directory_length);
    try std.testing.expectEqual(owned.bytes.ptr, view.bytes.ptr);
    try std.testing.expectEqual(@as(usize, 2), view.count);
    try std.testing.expectEqualStrings("forest", (try view.require(.forest)).bytes);
    try std.testing.expectError(error.ProfileMismatch, snap.Snapshot.openContainer(owned.bytes, .{ .profile_id = 78 }));
}

test "compiled typed surfaces inherit and validate without allocation" {
    var owned = try compiledFixture(std.testing.allocator);
    defer owned.deinit();
    const view = try snap.Snapshot.open(owned.bytes, .{ .profile_id = text.profile_digest });
    try view.validate();
    const f = try view.forest();
    var definitions = try f.nodes(.definition);
    const definition = (try definitions.next()).?;
    const lang = (try view.get(schema.columns.lang, definition)).?;
    const atoms = try view.keySpace(.atoms);
    var scratch: [32]u8 = undefined;
    try std.testing.expectEqual((try atoms.exact("en", &scratch)).?.ordinal, @intFromEnum(lang));
    const terms = try view.keySpaceForProfile(.terms, text.profile);
    try std.testing.expect((try terms.exact("river", &scratch)) != null);
    try std.testing.expectError(error.ProfileMismatch, view.keySpaceForProfile(.terms, text.profile + 1));
}

test "open rejects truncation, overlap, and hot payload damage" {
    var owned = try tinyContainer(std.testing.allocator);
    defer owned.deinit();
    try std.testing.expectError(error.InvalidFormat, snap.Snapshot.openContainer(owned.bytes[0 .. owned.bytes.len - 1], .{}));

    const before = try snap.Snapshot.openContainer(owned.bytes, .{});
    const directory_offset: usize = @intCast(before.header.directory_offset);
    const first_offset = before.directory[0].offset;
    var second = std.mem.readInt(u128, owned.bytes[directory_offset + snap.directory_bytes ..][0..16], .little);
    const offset_mask = ((@as(u128, 1) << 40) - 1) << 48;
    second = (second & ~offset_mask) | (@as(u128, first_offset) << 48);
    std.mem.writeInt(u128, owned.bytes[directory_offset + snap.directory_bytes ..][0..16], second, .little);
    repairRoot(owned.bytes);
    try std.testing.expectError(error.Overlap, snap.Snapshot.openContainer(owned.bytes, .{}));

    var clean = try tinyContainer(std.testing.allocator);
    defer clean.deinit();
    const clean_view = try snap.Snapshot.openContainer(clean.bytes, .{});
    clean.bytes[@intCast(clean_view.directory[0].offset)] ^= 1;
    try std.testing.expectError(error.CorruptChecksum, snap.Snapshot.openContainer(clean.bytes, .{}));
}

test "cold payload integrity is deferred exactly until first touch" {
    var owned = try snap.write(std.testing.allocator, .{}, &.{.{
        .kind = .cold,
        .bytes = "typed cold payload",
        .flags = snap.cold,
    }});
    defer owned.deinit();
    const clean = try snap.Snapshot.openContainer(owned.bytes, .{});
    owned.bytes[@intCast(clean.directory[0].offset)] ^= 0x80;
    const lazily_opened = try snap.Snapshot.openContainer(owned.bytes, .{});
    try std.testing.expectError(error.CorruptChecksum, lazily_opened.require(.cold));
}

test "directory metadata is authenticated and unknown required sections fail" {
    var owned = try snap.write(std.testing.allocator, .{}, &.{.{
        .kind = .cold,
        .bytes = "x",
        .flags = snap.required,
    }});
    defer owned.deinit();
    const directory_offset: usize = @intCast(std.mem.readInt(u64, owned.bytes[24..32], .little));

    // An unauthenticated directory edit is detected by the root digest.
    owned.bytes[directory_offset] = 200;
    try std.testing.expectError(error.CorruptChecksum, snap.Snapshot.openContainer(owned.bytes, .{}));

    // Once correctly authenticated, the semantic validation is still strict.
    repairRoot(owned.bytes);
    try std.testing.expectError(error.UnsupportedFeature, snap.Snapshot.openContainer(owned.bytes, .{}));
}
