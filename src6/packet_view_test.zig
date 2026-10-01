const std = @import("std");
const model = @import("model.zig");
const packet = @import("packet.zig");
const projection = @import("packet_view.zig");

fn multilingual() model.Entry {
    return .{
        .id = "lex-كتاب",
        .headword = "كتاب",
        .meta = .{ .language = .{ .tag = "ar" } },
        .keys = &.{ .{ .spelling = "كتاب" }, .{ .spelling = "الكتاب", .form = "ar-main" } },
        .content = &.{
            .{ .form = .{
                .meta = .{ .id = "ar-main" },
                .representations = &.{.{ .text = .{ .content = &.{.{ .text = "كتاب" }} }, .script = "Arab" }},
            } },
            .{ .sense = .{
                .label = "book",
                .content = &.{
                    .{ .definition = .{ .meta = .{ .language = .{ .tag = "ru" } }, .content = &.{.{ .text = "книга, письменное произведение" }} } },
                    .{ .translation = .{ .meta = .{ .language = .{ .tag = "ja" } }, .text = &.{.{ .content = &.{.{ .text = "本・書籍" }} }} } },
                    .{ .example = .{ .text = &.{.{ .content = &.{.{ .text = "Kitaplarımızı okuyorum." }} }} } },
                },
            } },
            .{ .analysis = .{
                .content = &.{.{ .segment = .{
                    .role = .{ .local = "root" },
                    .target = .{ .unresolved = .{ .identifier = "ك ت ب" } },
                } }},
            } },
        },
    };
}

fn onlyText(text_view: projection.View(model.Text)) ![]const u8 {
    var values = try (try text_view.field(.content)).values();
    const first = (try values.next()).?;
    try std.testing.expectEqual(model.Inline.text, try first.tag());
    try std.testing.expect(try values.next() == null);
    return (try first.payload(.text)).text();
}

test "typed multilingual form sense analysis and exact borrowed text use no allocation budget" {
    const a = std.testing.allocator;
    const bytes = try packet.encode(a, multilingual(), .{});
    defer a.free(bytes);
    const root = try projection.open(model.Entry, bytes, .{ .max_allocation_bytes = 0 });
    try std.testing.expect(root.scannedWork() > 0);
    try std.testing.expectEqualStrings("كتاب", try (try root.field("headword")).text());
    try std.testing.expectEqual(@FieldType(model.Entry, "kind").word, try (try root.field(.kind)).scalar());
    try std.testing.expect(try (try root.field(.homograph)).optional() == null);
    var sources = try (try root.field(.sources)).values();
    try std.testing.expect(try sources.next() == null);
    var content = try (try root.field(.content)).values();
    const form = try (try content.next()).?.payload(.form);
    var representations = try (try form.field(.representations)).values();
    const representation = (try representations.next()).?;
    try std.testing.expectEqualStrings("Arab", try ((try (try representation.field(.script)).optional()).?).text());
    const sense = try (try content.next()).?.payload(.sense);
    var sense_content = try (try sense.field(.content)).values();
    const russian = try onlyText(try (try sense_content.next()).?.payload(.definition));
    const index = std.mem.indexOf(u8, bytes, "книга, письменное произведение").?;
    try std.testing.expectEqual(bytes.ptr + index, russian.ptr);
    try std.testing.expectEqualStrings("книга, письменное произведение", russian);
    const translation = try (try sense_content.next()).?.payload(.translation);
    var translations = try (try translation.field(.text)).values();
    try std.testing.expectEqualStrings("本・書籍", try onlyText((try translations.next()).?));
    const example = try (try sense_content.next()).?.payload(.example);
    var examples = try (try example.field(.text)).values();
    try std.testing.expectEqualStrings("Kitaplarımızı okuyorum.", try onlyText((try examples.next()).?));
    const analysis = try (try content.next()).?.payload(.analysis);
    var segments = try (try analysis.field(.content)).values();
    const segment = try (try segments.next()).?.payload(.segment);
    const target = (try (try segment.field(.target)).optional()).?;
    const unresolved = try target.payload(.unresolved);
    try std.testing.expectEqualStrings("ك ت ب", try (try unresolved.field(.identifier)).text());
    try std.testing.expect(try content.next() == null);
}

test "omitted defaults are typed static projections and owned decode stays independent" {
    const a = std.testing.allocator;
    const Box = struct { number: u8 = 7, language: model.Language = .inherit, optional: ?u16 = null, text: []const u8 = "", values: []const u32 = &.{}, pair: [2]u16 = .{ 3, 9 } };
    const bytes = try packet.encode(a, Box{}, .{});
    defer a.free(bytes);
    try std.testing.expectEqual(@as(usize, 6), bytes.len);
    const root = try projection.open(Box, bytes, .{ .max_allocation_bytes = 0, .max_work = 1, .max_depth = 0 });
    try std.testing.expectEqual(@as(u8, 7), try (try root.field(.number)).scalar());
    try std.testing.expectEqual(model.Language.inherit, try (try root.field(.language)).tag());
    try std.testing.expect(try (try root.field(.optional)).optional() == null);
    try std.testing.expectEqualStrings("", try (try root.field(.text)).text());
    var values = try (try root.field(.values)).values();
    try std.testing.expect(try values.next() == null);
    var pair = try (try root.field(.pair)).values();
    try std.testing.expectEqual(@as(u16, 3), try (try pair.next()).?.scalar());
    try std.testing.expectEqual(@as(u16, 9), try (try pair.next()).?.scalar());
    try std.testing.expect(try pair.next() == null);
    var owned = try (try root.field(.pair)).decodeOwned(a);
    defer owned.deinit();
    @memset(bytes, 0);
    try std.testing.expectEqualDeep([2]u16{ 3, 9 }, owned.value);
}

test "borrowed child can explicitly decode to independently owned strings" {
    const a = std.testing.allocator;
    const bytes = try packet.encode(a, model.Name{ .namespace = "urn:语言", .local = "意味", .prefix = "jp" }, .{});
    defer a.free(bytes);
    const root = try projection.open(model.Name, bytes, .{});
    var owned = try (try root.field(.local)).decodeOwned(a);
    defer owned.deinit();
    @memset(bytes, 0);
    try std.testing.expectEqualStrings("意味", owned.value);
}

test "whole admission rejects malformed unselected fields and canonical defaults" {
    const Box = struct { first: u8, hidden: bool };
    try std.testing.expectError(error.InvalidBoolean, projection.open(Box, "LXP6\x03\x01\x02", .{}));
    const Scalar = struct { value: u8 = 5 };
    try std.testing.expectError(error.InvalidDefaultMask, projection.open(Scalar, "LXP6\x03\x02", .{}));
    try std.testing.expectError(error.NonCanonicalDefault, projection.open(Scalar, "LXP6\x03\x01\x05", .{}));
    try std.testing.expectError(error.NonCanonicalVarint, projection.open(Scalar, "LXP6\x03\x80\x00", .{}));
    try std.testing.expectError(error.Truncated, projection.open(Scalar, "LXP6\x03\x01", .{}));
    try std.testing.expectError(error.NonCanonicalVarint, projection.open(u64, "LXP6\x03\x80\x00", .{}));
    try std.testing.expectError(error.IntegerOverflow, projection.open(u64, "LXP6\x03" ++ "\xff" ** 10, .{}));
    try std.testing.expectError(error.IntegerOverflow, projection.open(u8, "LXP6\x03\x80\x02", .{}));
    try std.testing.expectError(error.InvalidEnum, projection.open(enum { a, b }, "LXP6\x03\x02", .{}));
    try std.testing.expectError(error.InvalidUnionTag, projection.open(model.Language, "LXP6\x03\x03", .{}));
    try std.testing.expectError(error.InvalidBoolean, projection.open(?u8, "LXP6\x03\x02", .{}));
    try std.testing.expectError(error.TrailingBytes, projection.open(u8, "LXP6\x03\x00\x00", .{}));
    try std.testing.expectError(error.Truncated, projection.open(u8, "LXP6", .{}));
    try std.testing.expectError(error.InvalidMagic, projection.open(u8, "BAD!\x03\x00", .{}));
    try std.testing.expectError(error.UnsupportedVersion, projection.open(u8, "LXP6\x01\x00", .{}));
    try std.testing.expectError(error.UnsupportedType, projection.open(f32, "LXP6\x03\x00", .{}));
}

test "nested overriding defaults compare exactly without constructing model values" {
    const Inner = struct { number: u8 = 5 };
    const Middle = struct { value: Inner = .{ .number = 7 } };
    const Outer = struct { value: Middle = .{ .value = .{ .number = 8 } } };
    // Explicit outer default is noncanonical, even when it differs from both
    // nested declared defaults and requires three sparse masks to represent.
    try std.testing.expectError(error.NonCanonicalDefault, projection.open(Outer, "LXP6\x03\x01\x01\x01\x08", .{}));
    const root = try projection.open(Outer, "LXP6\x03\x01\x01\x01\x09", .{});
    const middle = try root.field(.value);
    const inner = try middle.field(.value);
    try std.testing.expectEqual(@as(u8, 9), try (try inner.field(.number)).scalar());
}

test "legacy version two fields retain defaults and reject appended lexical tags" {
    const entry = try projection.open(model.Entry, "LXP6\x02\x01a\x01a" ++ "\x00" ** 13, .{});
    try std.testing.expectEqualStrings("a", try (try entry.field(.headword)).text());
    try std.testing.expectEqual(@FieldType(model.Entry, "kind").word, try (try entry.field(.kind)).scalar());
    try std.testing.expectError(error.InvalidUnionTag, projection.open(model.Item, "LXP6\x02\x10", .{}));
    try std.testing.expectError(error.InvalidUnionTag, projection.open(model.Item, "LXP6\x02\x11", .{}));
    const new = try projection.open(model.Item, "LXP6\x03\x10\x00", .{});
    try std.testing.expectEqual(model.Item.analysis, try new.tag());
    try std.testing.expectError(error.WrongUnionTag, new.payload(.segment));
}

test "depth work input and slice limits cover all encoded fields" {
    const a = std.testing.allocator;
    const bytes = try packet.encode(a, multilingual(), .{});
    defer a.free(bytes);
    try std.testing.expectError(error.InputTooLarge, projection.open(model.Entry, bytes, .{ .max_input_bytes = bytes.len - 1 }));
    try std.testing.expectError(error.DepthLimit, projection.open(model.Entry, bytes, .{ .max_depth = 3 }));
    try std.testing.expectError(error.WorkLimit, projection.open(model.Entry, bytes, .{ .max_work = 4 }));
    try std.testing.expectError(error.SliceTooLong, projection.open(model.Entry, bytes, .{ .max_slice_length = 2 }));
    const exact = try projection.open([]const u8, "LXP6\x03\x03abc", .{ .max_work = 4 });
    try std.testing.expectEqual(@as(usize, 4), exact.scannedWork());
    try std.testing.expectError(error.WorkLimit, projection.open([]const u8, "LXP6\x03\x03abc", .{ .max_work = 3 }));
    try std.testing.expectError(error.WorkLimit, projection.open([]const void, "LXP6\x03\x80\x80\x40", .{ .max_slice_length = 2_000_000, .max_work = 32 }));
}

test "ownership pointers preserve exact typed projections without pointer allocation" {
    const a = std.testing.allocator;
    const value = model.Value{ .shared = &.{ .meta = .{}, .value = .{ .text = "shared-日本語" } } };
    const bytes = try packet.encode(a, value, .{});
    defer a.free(bytes);
    const root = try projection.open(model.Value, bytes, .{ .max_allocation_bytes = 0 });
    const shared = try (try root.payload(.shared)).pointee();
    const contents = try (try shared.field(.value)).payload(.text);
    try std.testing.expectEqualStrings("shared-日本語", try contents.text());
}

test "byte slices and integer arrays use their different wire iteration rules" {
    const byte_view = try projection.open([]const u8, "LXP6\x03\x03\x00\x80\xff", .{});
    var bytes = try byte_view.values();
    for ([_]u8{ 0, 128, 255 }) |expected| try std.testing.expectEqual(expected, try (try bytes.next()).?.scalar());
    try std.testing.expect(try bytes.next() == null);
    const array_view = try projection.open([3]u8, "LXP6\x03\x00\x80\x01\xff\x01", .{});
    var array = try array_view.values();
    for ([_]u8{ 0, 128, 255 }) |expected| try std.testing.expectEqual(expected, try (try array.next()).?.scalar());
    try std.testing.expect(try array.next() == null);
}

fn expectParity(comptime T: type, bytes: []const u8) !void {
    const owned = packet.decode(T, std.testing.allocator, bytes, .{});
    const viewed = projection.open(T, bytes, .{});
    if (owned) |result| {
        var value = result;
        defer value.deinit();
        _ = try viewed;
    } else |expected| {
        try std.testing.expectError(expected, viewed);
    }
}

test "scanner agrees with owning decoder on every truncation and byte mutation" {
    const a = std.testing.allocator;
    const bytes = try packet.encode(a, multilingual(), .{});
    defer a.free(bytes);
    for (0..bytes.len) |end| {
        try std.testing.expectError(error.Truncated, projection.open(model.Entry, bytes[0..end], .{}));
        try expectParity(model.Entry, bytes[0..end]);
    }
    for (0..bytes.len) |index| {
        const original = bytes[index];
        for ([_]u8{ 0, 1, 0x80, 0xff }) |mutated| {
            bytes[index] = mutated;
            try expectParity(model.Entry, bytes);
        }
        bytes[index] = original;
    }
}

test "numeric declaration ordinals and signed scalars preserve native values" {
    const a = std.testing.allocator;
    const Sparse = enum(i16) { negative = -40, high = 900 };
    const SparseUnion = union(enum(i8)) { empty = -9, text: []const u8 = 71 };
    const Box = struct { enumeration: Sparse, sum: SparseUnion, smallest: i64, largest: u64, absent: void };
    const value = Box{ .enumeration = .high, .sum = .{ .text = "ordinal-語" }, .smallest = std.math.minInt(i64), .largest = std.math.maxInt(u64), .absent = {} };
    const bytes = try packet.encode(a, value, .{});
    defer a.free(bytes);
    const root = try projection.open(Box, bytes, .{});
    try std.testing.expectEqual(Sparse.high, try (try root.field(.enumeration)).scalar());
    const sum = try root.field(.sum);
    try std.testing.expectEqual(std.meta.Tag(SparseUnion).text, try sum.tag());
    try std.testing.expectEqualStrings("ordinal-語", try (try sum.payload(.text)).text());
    try std.testing.expectEqual(std.math.minInt(i64), try (try root.field(.smallest)).scalar());
    try std.testing.expectEqual(std.math.maxInt(u64), try (try root.field(.largest)).scalar());
    try std.testing.expectEqual({}, try (try root.field(.absent)).scalar());
}

test "64 default bits and wider full structs preserve the wire boundary" {
    const Wide64 = struct {
        f00: u8 = 0,
        f01: u8 = 0,
        f02: u8 = 0,
        f03: u8 = 0,
        f04: u8 = 0,
        f05: u8 = 0,
        f06: u8 = 0,
        f07: u8 = 0,
        f08: u8 = 0,
        f09: u8 = 0,
        f10: u8 = 0,
        f11: u8 = 0,
        f12: u8 = 0,
        f13: u8 = 0,
        f14: u8 = 0,
        f15: u8 = 0,
        f16: u8 = 0,
        f17: u8 = 0,
        f18: u8 = 0,
        f19: u8 = 0,
        f20: u8 = 0,
        f21: u8 = 0,
        f22: u8 = 0,
        f23: u8 = 0,
        f24: u8 = 0,
        f25: u8 = 0,
        f26: u8 = 0,
        f27: u8 = 0,
        f28: u8 = 0,
        f29: u8 = 0,
        f30: u8 = 0,
        f31: u8 = 0,
        f32: u8 = 0,
        f33: u8 = 0,
        f34: u8 = 0,
        f35: u8 = 0,
        f36: u8 = 0,
        f37: u8 = 0,
        f38: u8 = 0,
        f39: u8 = 0,
        f40: u8 = 0,
        f41: u8 = 0,
        f42: u8 = 0,
        f43: u8 = 0,
        f44: u8 = 0,
        f45: u8 = 0,
        f46: u8 = 0,
        f47: u8 = 0,
        f48: u8 = 0,
        f49: u8 = 0,
        f50: u8 = 0,
        f51: u8 = 0,
        f52: u8 = 0,
        f53: u8 = 0,
        f54: u8 = 0,
        f55: u8 = 0,
        f56: u8 = 0,
        f57: u8 = 0,
        f58: u8 = 0,
        f59: u8 = 0,
        f60: u8 = 0,
        f61: u8 = 0,
        f62: u8 = 0,
        f63: u8 = 0,
    };
    const root = try projection.open(Wide64, "LXP6\x03" ++ "\x80" ** 9 ++ "\x01\x09", .{ .max_work = 2 });
    try std.testing.expectEqual(@as(u8, 9), try (try root.field(.f63)).scalar());
    try std.testing.expectEqual(@as(u8, 0), try (try root.field(.f00)).scalar());
    try std.testing.expectError(error.NonCanonicalDefault, projection.open(Wide64, "LXP6\x03" ++ "\x80" ** 9 ++ "\x01\x00", .{}));
    const Wide65 = struct {
        f00: u8 = 0,
        f01: u8 = 0,
        f02: u8 = 0,
        f03: u8 = 0,
        f04: u8 = 0,
        f05: u8 = 0,
        f06: u8 = 0,
        f07: u8 = 0,
        f08: u8 = 0,
        f09: u8 = 0,
        f10: u8 = 0,
        f11: u8 = 0,
        f12: u8 = 0,
        f13: u8 = 0,
        f14: u8 = 0,
        f15: u8 = 0,
        f16: u8 = 0,
        f17: u8 = 0,
        f18: u8 = 0,
        f19: u8 = 0,
        f20: u8 = 0,
        f21: u8 = 0,
        f22: u8 = 0,
        f23: u8 = 0,
        f24: u8 = 0,
        f25: u8 = 0,
        f26: u8 = 0,
        f27: u8 = 0,
        f28: u8 = 0,
        f29: u8 = 0,
        f30: u8 = 0,
        f31: u8 = 0,
        f32: u8 = 0,
        f33: u8 = 0,
        f34: u8 = 0,
        f35: u8 = 0,
        f36: u8 = 0,
        f37: u8 = 0,
        f38: u8 = 0,
        f39: u8 = 0,
        f40: u8 = 0,
        f41: u8 = 0,
        f42: u8 = 0,
        f43: u8 = 0,
        f44: u8 = 0,
        f45: u8 = 0,
        f46: u8 = 0,
        f47: u8 = 0,
        f48: u8 = 0,
        f49: u8 = 0,
        f50: u8 = 0,
        f51: u8 = 0,
        f52: u8 = 0,
        f53: u8 = 0,
        f54: u8 = 0,
        f55: u8 = 0,
        f56: u8 = 0,
        f57: u8 = 0,
        f58: u8 = 0,
        f59: u8 = 0,
        f60: u8 = 0,
        f61: u8 = 0,
        f62: u8 = 0,
        f63: u8 = 0,
        f64: u8 = 0,
    };
    const full = try projection.open(Wide65, "LXP6\x03" ++ "\x00" ** 65, .{ .max_work = 66 });
    try std.testing.expectEqual(@as(u8, 0), try (try full.field(.f64)).scalar());
    try std.testing.expectError(error.WorkLimit, projection.open(Wide65, "LXP6\x03" ++ "\x00" ** 65, .{ .max_work = 65 }));
}

test "nonempty defaults remain wire values and null differs from present empty text" {
    const a = std.testing.allocator;
    const Box = struct { text: []const u8 = "static", values: []const u16 = &.{ 7, 9 }, optional: ?[]const u8 = null, category: model.Value };
    const original = Box{ .optional = "", .category = .{ .bag = &.{} } };
    const bytes = try packet.encode(a, original, .{});
    defer a.free(bytes);
    const root = try projection.open(Box, bytes, .{ .max_allocation_bytes = 0 });
    const text = try (try root.field(.text)).text();
    try std.testing.expectEqualStrings("static", text);
    try std.testing.expectEqual(bytes.ptr + std.mem.indexOf(u8, bytes, "static").?, text.ptr);
    try std.testing.expect(text.ptr != original.text.ptr);
    var values = try (try root.field(.values)).values();
    try std.testing.expectEqual(@as(u16, 7), try (try values.next()).?.scalar());
    try std.testing.expectEqual(@as(u16, 9), try (try values.next()).?.scalar());
    try std.testing.expect(try values.next() == null);
    const optional = (try (try root.field(.optional)).optional()).?;
    try std.testing.expectEqualStrings("", try optional.text());
    const category = try root.field(.category);
    try std.testing.expectEqual(model.Value.bag, try category.tag());
    var bag = try (try category.payload(.bag)).values();
    try std.testing.expect(try bag.next() == null);
}

test "structural packet views deliberately do not grant lexical semantic admission" {
    const a = std.testing.allocator;
    // Empty identity/headword are structurally canonical yet inadmissible as
    // lexical data. Archive.verify supplies the separate semantic proof.
    const bytes = try packet.encode(a, model.Entry{ .id = "", .headword = "" }, .{});
    defer a.free(bytes);
    const root = try projection.open(model.Entry, bytes, .{});
    try std.testing.expectEqualStrings("", try (try root.field(.id)).text());
    try std.testing.expectEqualStrings("", try (try root.field(.headword)).text());
}

test "validated final extents skip redundant deep traversal with exact child boundaries" {
    const a = std.testing.allocator;
    const bytes = try packet.encode(a, multilingual(), .{});
    defer a.free(bytes);
    const root = try projection.open(model.Entry, bytes, .{});
    const content = try root.field(.content);
    // All subsequent Entry fields are omitted. Projection locates the start
    // by scanning only small preceding fields and reuses the admitted end.
    try std.testing.expect(content.scannedWork() < root.scannedWork() / 2);
    var items = try content.values();
    const initial_work = items.scannedWork();
    _ = try items.next();
    try std.testing.expectEqual(initial_work, items.scannedWork());
    _ = try items.next();
    const previous_work = items.scannedWork();
    const last = (try items.next()).?;
    // Advancing charges the previous sense's scan, but the final returned
    // analysis itself needs no traversal to establish its exact end.
    try std.testing.expect(items.scannedWork() > previous_work);
    var owned = try last.decodeOwned(a);
    defer owned.deinit();
    try std.testing.expectEqualDeep(multilingual().content[2], owned.value);
    try std.testing.expect(try items.next() == null);
}

test "final extent proof never absorbs present trailing struct fields" {
    const a = std.testing.allocator;
    var original = multilingual();
    original.sources = &.{.{ .id = "raw", .media_type = "text/plain", .bytes = "source-保留" }};
    const bytes = try packet.encode(a, original, .{});
    defer a.free(bytes);
    const root = try projection.open(model.Entry, bytes, .{});
    const content = try root.field(.content);
    var owned = try content.decodeOwned(a);
    defer owned.deinit();
    try std.testing.expectEqualDeep(original.content, owned.value);
    var sources = try (try root.field(.sources)).values();
    const source = (try sources.next()).?;
    try std.testing.expectEqualStrings("source-保留", try (try source.field(.bytes)).text());
    var source_owned = try source.decodeOwned(a);
    defer source_owned.deinit();
    try std.testing.expectEqualDeep(original.sources[0], source_owned.value);
}

test "final iterator boundaries remain exact for legacy full structs and void elements" {
    const a = std.testing.allocator;
    const Box = struct { first: []const u8, second: []const u8 = "" };
    const root = try projection.open(Box, "LXP6\x02\x01a\x01b", .{});
    var first = try (try root.field(.first)).decodeOwned(a);
    defer first.deinit();
    var second = try (try root.field(.second)).decodeOwned(a);
    defer second.deinit();
    try std.testing.expectEqualStrings("a", first.value);
    try std.testing.expectEqualStrings("b", second.value);
    const voids = try projection.open([]const void, "LXP6\x03\x02", .{});
    var values = try voids.values();
    _ = try (try values.next()).?.scalar();
    _ = try (try values.next()).?.scalar();
    try std.testing.expect(try values.next() == null);
}

test "prepared factory consumes prior full admission and keeps typed exact spans" {
    const a = std.testing.allocator;
    const bytes = try packet.encode(a, multilingual(), .{});
    defer a.free(bytes);
    const limits = projection.Limits{};
    const admitted = try projection.open(model.Entry, bytes, limits);
    const original = multilingual();
    try @import("validate.zig").check(a, &original, .{});
    const prepared = try projection.fromVerifiedDocument(model.Entry, bytes, limits);
    try std.testing.expectEqual(@as(usize, 0), prepared.scannedWork());
    try std.testing.expectEqualStrings(try (try admitted.field(.headword)).text(), try (try prepared.field(.headword)).text());
    var items = try (try prepared.field(.content)).values();
    _ = try items.next();
    const sense = try (try items.next()).?.payload(.sense);
    var children = try (try sense.field(.content)).values();
    const definition = try (try children.next()).?.payload(.definition);
    try std.testing.expectEqualStrings("книга, письменное произведение", try onlyText(definition));
    try std.testing.expectError(error.InputTooLarge, projection.fromVerifiedDocument(model.Entry, bytes, .{ .max_input_bytes = 4 }));
    try std.testing.expectError(error.Truncated, projection.fromVerifiedDocument(model.Entry, "LXP6", limits));
    try std.testing.expectError(error.InvalidMagic, projection.fromVerifiedDocument(model.Entry, "bad!\x03", limits));
    try std.testing.expectError(error.UnsupportedVersion, projection.fromVerifiedDocument(model.Entry, "LXP6\x01", limits));
}

test "lazy prefix projection materializes every field and item to exact source values" {
    const a = std.testing.allocator;
    var original = multilingual();
    original.sources = &.{.{ .id = "source", .media_type = "text/plain", .bytes = "followed-by-another-field" }};
    original.residuals = &.{.{ .source = "source", .start = 1, .end = 3 }};
    const bytes = try packet.encode(a, original, .{});
    defer a.free(bytes);
    const root = try projection.open(model.Entry, bytes, .{});
    inline for (@typeInfo(model.Entry).@"struct".fields) |field_| {
        const child = try root.field(field_.name);
        var owned = try child.decodeOwned(a);
        defer owned.deinit();
        try std.testing.expectEqualDeep(@field(original, field_.name), owned.value);
    }
    var items = try (try root.field(.content)).values();
    for (original.content) |expected| {
        const item = (try items.next()).?;
        var owned = try item.decodeOwned(a);
        defer owned.deinit();
        try std.testing.expectEqualDeep(expected, owned.value);
    }
    try std.testing.expect(try items.next() == null);
}

test "lazy selected sense label avoids visiting its descendant content" {
    const a = std.testing.allocator;
    const original = multilingual();
    const bytes = try packet.encode(a, original, .{});
    defer a.free(bytes);
    const root = try projection.open(model.Entry, bytes, .{});
    var items = try (try root.field(.content)).values();
    _ = try items.next();
    const sense_item = (try items.next()).?;
    const cursor_work = items.scannedWork();
    const sense = try sense_item.payload(.sense);
    const label = (try (try sense.field(.label)).optional()).?;
    try std.testing.expectEqualStrings("book", try label.text());
    // Reading the requested prefix never advances the iterator or scans the
    // definitions, translations, examples, or following analysis subtree.
    try std.testing.expectEqual(cursor_work, items.scannedWork());
    try std.testing.expect(cursor_work < root.scannedWork() / 2);
    try std.testing.expect((try sense.field(.label)).scannedWork() < 10);
}
