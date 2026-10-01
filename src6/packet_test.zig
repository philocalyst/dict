const std = @import("std");
const model = @import("model.zig");
const packet = @import("packet.zig");

fn richEntry() model.Entry {
    const nested = model.Item{ .sense = .{
        .label = "inner",
        .content = &.{.{ .definition = .{ .content = &.{.{ .text = "a recursively nested meaning" }} } }},
    } };
    return .{
        .id = "entry-1",
        .headword = "colour",
        .meta = .{
            .language = .{ .tag = "en-GB" },
            .annotations = &.{.{
                .name = .{ .namespace = "urn:test", .local = "reviewed", .prefix = "t" },
                .value = "yes",
                .agent = .{ .iri = "https://example.test/editor" },
                .when = "2026-09-12",
            }},
        },
        .kind = .word,
        .homograph = 2,
        .keys = &.{
            .{ .spelling = "colour", .form = "main" },
            .{ .spelling = "color" },
            .{ .spelling = "colour", .form = "regional" },
        },
        .content = &.{
            .{ .form = .{
                .meta = .{ .id = "main" },
                .representations = &.{.{
                    .text = .{ .content = &.{
                        .{ .text = "col" },
                        .{ .element = .{
                            .name = .{ .local = "em" },
                            .content = &.{.{ .text = "our" }},
                        } },
                    } },
                    .script = "Latn",
                }},
            } },
            .{ .sense = .{
                .label = "appearance",
                .content = &.{
                    .{ .definition = .{ .content = &.{.{ .text = "visual quality" }} } },
                    nested,
                    .{ .grammar = .{
                        .name = .{ .local = "countability" },
                        .value = .{ .alternative = &.{ .{ .symbol = .{ .local = "count" } }, .{ .unknown = {} } } },
                    } },
                    .{ .relation = .{
                        .predicate = .synonym,
                        .endpoints = .{ .binary = .{ .entry = .{ .id = "hue", .fragment = "sense-1" } } },
                        .state = .inferred,
                        .confidence = "0.875",
                    } },
                },
            } },
        },
        .sources = &.{.{
            .id = "source-a",
            .media_type = "application/xml",
            .bytes = "<entry>colour</entry>",
            .uri = "file:///dictionary.xml",
        }},
    };
}

test "rich recursive model roundtrips and owns all strings" {
    const allocator = std.testing.allocator;
    const encoded = try packet.encode(allocator, richEntry(), .{});
    const mutable = encoded;
    defer allocator.free(mutable);

    var decoded = try packet.decode(model.Entry, allocator, mutable, .{});
    defer decoded.deinit();
    try std.testing.expectEqualDeep(richEntry(), decoded.value);

    @memset(mutable, 0);
    try std.testing.expectEqualStrings("colour", decoded.value.headword);
    try std.testing.expectEqualStrings("a recursively nested meaning", decoded.value.content[1].sense.content[1].sense.content[0].definition.content[0].text);
}

test "canonical scalar codec rejects malformed values" {
    const allocator = std.testing.allocator;
    const BoolBox = struct { value: bool };
    const EnumBox = struct { value: enum { zero, one } };
    const UnionBox = struct { value: union(enum) { none, number: u8 } };

    var bool_bytes = try packet.encode(allocator, BoolBox{ .value = true }, .{});
    defer allocator.free(bool_bytes);
    bool_bytes[5] = 2;
    try std.testing.expectError(error.InvalidBoolean, packet.decode(BoolBox, allocator, bool_bytes, .{}));

    var enum_bytes = try packet.encode(allocator, EnumBox{ .value = .one }, .{});
    defer allocator.free(enum_bytes);
    enum_bytes[5] = 9;
    try std.testing.expectError(error.InvalidEnum, packet.decode(EnumBox, allocator, enum_bytes, .{}));

    var union_bytes = try packet.encode(allocator, UnionBox{ .value = .none }, .{});
    defer allocator.free(union_bytes);
    union_bytes[5] = 9;
    try std.testing.expectError(error.InvalidUnionTag, packet.decode(UnionBox, allocator, union_bytes, .{}));

    const noncanonical = "LXP6\x02\x80\x00";
    try std.testing.expectError(error.NonCanonicalVarint, packet.decode(u64, allocator, noncanonical, .{}));
    try std.testing.expectError(error.Truncated, packet.decode(u64, allocator, "LXP6\x02\x80", .{}));
    try std.testing.expectError(error.TrailingBytes, packet.decode(u8, allocator, "LXP6\x02\x00\x00", .{}));
}

test "enum and union tags use declaration ordinal rather than numeric tag value" {
    const allocator = std.testing.allocator;
    const Sparse = enum(i16) { negative = -40, high = 900 };
    const SparseUnion = union(enum(i8)) { empty = -9, text: []const u8 = 71 };
    const value = struct { enumeration: Sparse, sum: SparseUnion }{
        .enumeration = .high,
        .sum = .{ .text = "ordinal" },
    };
    const encoded = try packet.encode(allocator, value, .{});
    defer allocator.free(encoded);
    // Both selected alternatives are the second declaration and encode as 1.
    try std.testing.expectEqual(@as(u8, 1), encoded[5]);
    try std.testing.expectEqual(@as(u8, 1), encoded[6]);
    var decoded = try packet.decode(@TypeOf(value), allocator, encoded, .{});
    defer decoded.deinit();
    try std.testing.expectEqual(Sparse.high, decoded.value.enumeration);
    try std.testing.expectEqualStrings("ordinal", decoded.value.sum.text);
}

test "decode enforces depth work slice input and allocation limits" {
    const allocator = std.testing.allocator;
    const value = [_][]const u8{ "one", "two", "three" };
    const encoded = try packet.encode(allocator, value, .{});
    defer allocator.free(encoded);

    try std.testing.expectError(error.DepthLimit, packet.decode(@TypeOf(value), allocator, encoded, .{ .max_depth = 0 }));
    try std.testing.expectError(error.WorkLimit, packet.decode(@TypeOf(value), allocator, encoded, .{ .max_work = 2 }));
    try std.testing.expectError(error.SliceTooLong, packet.decode(@TypeOf(value), allocator, encoded, .{ .max_slice_length = 2 }));
    try std.testing.expectError(error.AllocationLimit, packet.decode(@TypeOf(value), allocator, encoded, .{ .max_allocation_bytes = 4 }));
    try std.testing.expectError(error.InputTooLarge, packet.decode(@TypeOf(value), allocator, encoded, .{ .max_input_bytes = 4 }));
}

test "string work accounting is symmetric at the exact boundary" {
    const allocator = std.testing.allocator;
    const bytes = try packet.encode(allocator, @as([]const u8, "abc"), .{ .max_work = 4 });
    defer allocator.free(bytes);
    try std.testing.expectError(error.WorkLimit, packet.encode(allocator, @as([]const u8, "abc"), .{ .max_work = 3 }));
    var decoded = try packet.decode([]const u8, allocator, bytes, .{ .max_work = 4 });
    defer decoded.deinit();
    try std.testing.expectEqualStrings("abc", decoded.value);
    try std.testing.expectError(error.WorkLimit, packet.decode([]const u8, allocator, bytes, .{ .max_work = 3 }));
}

test "large zero-sized slice is rejected by work before arena allocation" {
    // Canonical varint for 1,048,576, with no elements following because the
    // element type is void. The logical work bound rejects it immediately.
    const bytes = "LXP6\x02\x80\x80\x40";
    try std.testing.expectError(error.WorkLimit, packet.decode([]const void, std.testing.allocator, bytes, .{
        .max_slice_length = 2_000_000,
        .max_work = 32,
    }));
}

test "packet encode and decode are allocation-failure safe" {
    const allocator = std.testing.allocator;
    try std.testing.checkAllAllocationFailures(allocator, struct {
        fn run(failing: std.mem.Allocator) !void {
            const bytes = try packet.encode(failing, richEntry(), .{});
            defer failing.free(bytes);
            var decoded = try packet.decode(model.Entry, failing, bytes, .{});
            defer decoded.deinit();
            try std.testing.expectEqualStrings("colour", decoded.value.headword);
        }
    }.run, .{});
}

test "sparse declared defaults shrink packets without changing lexical values" {
    const allocator = std.testing.allocator;
    const entry = model.Entry{ .id = "a", .headword = "a" };
    const encoded = try packet.encode(allocator, entry, .{});
    defer allocator.free(encoded);
    try std.testing.expectEqual(@as(usize, 10), encoded.len);
    try std.testing.expectEqual(@as(u8, 3), encoded[4]);
    var decoded = try packet.decode(model.Entry, allocator, encoded, .{});
    defer decoded.deinit();
    try std.testing.expectEqualDeep(entry, decoded.value);

    // The compatible v2 schema writes the complete metadata and all six
    // default entry fields. Old archives remain readable after v3 promotion.
    const legacy = "LXP6\x02\x01a\x01a" ++ "\x00" ** 13;
    var old = try packet.decode(model.Entry, allocator, legacy, .{});
    defer old.deinit();
    try std.testing.expectEqualDeep(entry, old.value);
}

test "sparse masks are canonical and distinguish nondefault empty values" {
    const allocator = std.testing.allocator;
    const Box = struct {
        marker: u8 = 5,
        language: model.Language = .inherit,
        optional: ?[]const u8 = null,
        items: []const model.Value = &.{},
    };
    const value = Box{
        .marker = 0,
        .language = .reset,
        .optional = "",
        .items = &.{ .unknown, .unspecified, .default, .{ .bag = &.{} }, .{ .list = &.{} } },
    };
    const bytes = try packet.encode(allocator, value, .{});
    defer allocator.free(bytes);
    var decoded = try packet.decode(Box, allocator, bytes, .{});
    defer decoded.deinit();
    try std.testing.expectEqualDeep(value, decoded.value);

    const Scalar = struct { value: u8 = 5 };
    try std.testing.expectError(error.InvalidDefaultMask, packet.decode(Scalar, allocator, "LXP6\x03\x02", .{}));
    try std.testing.expectError(error.NonCanonicalDefault, packet.decode(Scalar, allocator, "LXP6\x03\x01\x05", .{}));
    try std.testing.expectError(error.NonCanonicalVarint, packet.decode(Scalar, allocator, "LXP6\x03\x80\x00", .{}));
    try std.testing.expectError(error.Truncated, packet.decode(Scalar, allocator, "LXP6\x03\x01", .{}));
}

test "nonempty declared defaults remain encoded and independently owned" {
    const allocator = std.testing.allocator;
    const Box = struct { text: []const u8 = "static", values: []const u16 = &.{ 7, 9 } };
    const bytes = try packet.encode(allocator, Box{}, .{});
    defer allocator.free(bytes);
    var decoded = try packet.decode(Box, allocator, bytes, .{});
    defer decoded.deinit();
    @memset(bytes, 0);
    try std.testing.expectEqualStrings("static", decoded.value.text);
    try std.testing.expectEqualSlices(u16, &.{ 7, 9 }, decoded.value.values);
    try std.testing.expect(decoded.value.text.ptr != (Box{}).text.ptr);
}

test "borrowed packet strings avoid payload allocations without losing rich values" {
    const allocator = std.testing.allocator;
    const value = richEntry();
    const bytes = try packet.encode(allocator, value, .{});
    defer allocator.free(bytes);
    var decoded = try packet.decodeBorrowed(model.Entry, allocator, bytes, .{});
    defer decoded.deinit();
    try std.testing.expectEqualDeep(value, decoded.value);
    const pointer = @intFromPtr(decoded.value.headword.ptr);
    try std.testing.expect(pointer >= @intFromPtr(bytes.ptr) and pointer + decoded.value.headword.len <= @intFromPtr(bytes.ptr) + bytes.len);

    const scalar = try packet.encode(allocator, @as([]const u8, "lexical bytes"), .{});
    defer allocator.free(scalar);
    var refusing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var borrowed = try packet.decodeBorrowed([]const u8, refusing.allocator(), scalar, .{ .max_allocation_bytes = 0 });
    defer borrowed.deinit();
    try std.testing.expectEqualStrings("lexical bytes", borrowed.value);
    try std.testing.expectEqual(@as(usize, 0), refusing.alloc_index);
    try std.testing.expectError(error.AllocationLimit, packet.decode([]const u8, allocator, scalar, .{ .max_allocation_bytes = 0 }));
    try std.testing.expectError(error.WorkLimit, packet.decodeBorrowed([]const u8, allocator, scalar, .{ .max_work = 2 }));
}

test "borrowed decoding still copies mutable byte slices" {
    const allocator = std.testing.allocator;
    const bytes = try packet.encode(allocator, @as([]const u8, "mutable"), .{});
    defer allocator.free(bytes);
    var decoded = try packet.decodeBorrowed([]u8, allocator, bytes, .{});
    defer decoded.deinit();
    decoded.value[0] = 'M';
    try std.testing.expectEqualStrings("Mutable", decoded.value);
    try std.testing.expectEqualStrings("mutable", bytes[6..]);
}

test "declared ownership-pointer defaults are encoded and newly owned" {
    const allocator = std.testing.allocator;
    const constant: u16 = 77;
    const Box = struct { value: *const u16 = &constant };
    const bytes = try packet.encode(allocator, Box{}, .{});
    defer allocator.free(bytes);
    var decoded = try packet.decode(Box, allocator, bytes, .{});
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u16, 77), decoded.value.value.*);
    try std.testing.expect(decoded.value.value != &constant);
}

test "new analysis alternatives are excluded from legacy Item packets" {
    try std.testing.expectError(error.InvalidUnionTag, packet.decode(model.Item, std.testing.allocator, "LXP6\x02\x10", .{}));
    try std.testing.expectError(error.InvalidUnionTag, packet.decode(model.Item, std.testing.allocator, "LXP6\x02\x11", .{}));
}
