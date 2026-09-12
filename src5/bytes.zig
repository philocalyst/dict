const std = @import("std");

pub const Error = error{ Truncated, Overflow, InvalidFormat, UnsupportedVersion };

pub const Slice = struct {
    data: []const u8,
    pub fn len(self: *const Slice) usize {
        return self.data.len;
    }
    pub fn bytes(self: *const Slice, offset: usize, size: usize) Error![]const u8 {
        return at(self.data, offset, size);
    }
};

fn DeclSource(comptime Source: type) type {
    return switch (@typeInfo(Source)) {
        .pointer => |pointer| pointer.child,
        else => Source,
    };
}

pub fn SourceError(comptime Source: type) type {
    if (Source == []const u8 or Source == []u8) return Error;
    const S = DeclSource(Source);
    const access = if (@hasDecl(S, "bytes")) S.bytes else @compileError("Source must provide bytes");
    const result = @typeInfo(@TypeOf(access)).@"fn".return_type orelse unreachable;
    return @typeInfo(result).error_union.error_set || Error;
}

pub fn length(comptime Source: type, source: *const Source) usize {
    if (Source == []const u8 or Source == []u8) return source.*.len;
    if (@typeInfo(Source) == .pointer) return source.*.len();
    return source.len();
}

pub fn read(comptime Source: type, source: *const Source, offset: usize, size: usize) SourceError(Source)![]const u8 {
    if (Source == []const u8 or Source == []u8) return at(source.*, offset, size);
    if (@typeInfo(Source) == .pointer) return source.*.bytes(offset, size);
    return source.bytes(offset, size);
}

fn isOwnSpan(comptime Candidate: type) bool {
    return switch (@typeInfo(Candidate)) {
        .@"struct" => if (@hasDecl(Candidate, "BaseSource")) blk: {
            const Base = @field(Candidate, "BaseSource");
            if (@TypeOf(Base) != type) break :blk false;
            break :blk Candidate == FlatSpan(Base);
        } else false,
        .@"enum", .@"union", .@"opaque" => false,
        else => false,
    };
}

/// A bounded source capability in its normal form: the original Source value,
/// one checked absolute base, and one size. Exact generated type identity is
/// the only authority for flattening nested spans.
fn FlatSpan(comptime Source: type) type {
    return struct {
        pub const BaseSource = Source;

        source: Source,
        base: usize,
        size: usize,

        pub fn init(source: anytype, relative_base: usize, size: usize) Error!@This() {
            const Input = @TypeOf(source);
            if (comptime isOwnSpan(Input)) {
                const parent_length = length(Input, &source);
                if (relative_base > parent_length or size > parent_length - relative_base) return error.Truncated;
                if (!@hasDecl(Input, "BaseSource") or @field(Input, "BaseSource") != Source) {
                    @compileError("nested source base type mismatch");
                }
                const absolute = std.math.add(usize, @field(source, "base"), relative_base) catch return error.Overflow;
                return .{ .source = @field(source, "source"), .base = absolute, .size = size };
            }
            if (comptime @typeInfo(Input) == .array) {
                @compileError("pass fixed arrays by pointer or slice; an anytype array value would not retain caller lifetime");
            }
            const base_source: Source = source;
            const parent_length = length(Source, &base_source);
            if (relative_base > parent_length or size > parent_length - relative_base) return error.Truncated;
            return .{ .source = base_source, .base = relative_base, .size = size };
        }

        pub fn len(self: *const @This()) usize {
            return self.size;
        }

        /// Coordinate subtraction assumes `parent` and this span originate in
        /// the same source value; it is a bounds helper, not authentication.
        pub fn offsetFrom(self: *const @This(), parent: anytype) Error!usize {
            const Parent = @TypeOf(parent);
            if (comptime isOwnSpan(Parent)) {
                if (!@hasDecl(Parent, "BaseSource") or @field(Parent, "BaseSource") != Source) {
                    @compileError("parent span base type mismatch");
                }
                if (self.base < @field(parent, "base")) return error.Truncated;
                const relative = self.base - @field(parent, "base");
                if (relative > @field(parent, "size") or self.size > @field(parent, "size") - relative) return error.Truncated;
                return relative;
            }
            if (Parent != Source) @compileError("parent source type mismatch");
            const parent_length = length(Source, &parent);
            if (self.base > parent_length or self.size > parent_length - self.base) return error.Truncated;
            return self.base;
        }

        pub fn bytes(self: *const @This(), offset: usize, size: usize) SourceError(Source)![]const u8 {
            if (offset > self.size or size > self.size - offset) return error.Truncated;
            const absolute = std.math.add(usize, self.base, offset) catch return error.Overflow;
            return read(Source, &self.source, absolute, size);
        }
    };
}

pub fn Span(comptime Source: type) type {
    if (isOwnSpan(Source)) return Source;
    return FlatSpan(Source);
}

pub fn at(data: []const u8, offset: usize, size: usize) Error![]const u8 {
    if (offset > data.len or size > data.len - offset) return error.Truncated;
    return data[offset..][0..size];
}

pub const Extent = struct { offset: usize, length: usize };
pub const Layout = struct {
    cursor: usize,

    pub fn init(start: usize) Layout {
        return .{ .cursor = start };
    }

    pub fn take(self: *Layout, size: usize, alignment: u29) Error!Extent {
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidFormat;
        const remainder = self.cursor & (@as(usize, alignment) - 1);
        const padding = if (remainder == 0) 0 else @as(usize, alignment) - remainder;
        const start = std.math.add(usize, self.cursor, padding) catch return error.Overflow;
        const end = std.math.add(usize, start, size) catch return error.Overflow;
        self.cursor = end;
        return .{ .offset = start, .length = size };
    }
};

pub fn readInt(comptime T: type, data: []const u8, offset: usize) Error!T {
    return std.mem.readInt(T, (try at(data, offset, @sizeOf(T)))[0..@sizeOf(T)], .little);
}

pub fn writeInt(comptime T: type, data: []u8, offset: usize, value: T) Error!void {
    if (offset > data.len or @sizeOf(T) > data.len - offset) return error.Truncated;
    std.mem.writeInt(T, data[offset..][0..@sizeOf(T)], value, .little);
}

pub const SectionInput = struct { tag: u32, data: []const u8 };
const archive_magic = "L5AR";
const archive_version: u16 = 1;
const archive_header: usize = 16;
const archive_record: usize = 16;

pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub fn Bundle(comptime Schema: type) type {
    const fields = @typeInfo(Schema).@"struct".fields;
    if (fields.len == 0) @compileError("a bundle requires at least one body");
    return struct {
        pub const Part = std.meta.FieldEnum(Schema);
        pub const Input = input: {
            var names: [fields.len][]const u8 = undefined;
            var types: [fields.len]type = undefined;
            for (fields, 0..) |field, index| {
                names[index] = field.name;
                types[index] = []const u8;
            }
            break :input @Struct(.auto, null, &names, &types, &@splat(.{}));
        };

        pub fn build(allocator: std.mem.Allocator, parts: Input) (Error || std.mem.Allocator.Error)!Owned {
            const header_size = (fields.len - 1) * @sizeOf(u32);
            var layout = Layout.init(header_size);
            var extents: [fields.len]Extent = undefined;
            inline for (fields, 0..) |field, index| extents[index] = try layout.take(@field(parts, field.name).len, 1);
            var output = try allocator.alloc(u8, layout.cursor);
            errdefer allocator.free(output);
            inline for (fields, 0..) |field, index| {
                const body = @field(parts, field.name);
                if (index + 1 < fields.len) try writeInt(u32, output, index * 4, std.math.cast(u32, body.len) orelse return error.Overflow);
                @memcpy(output[extents[index].offset..][0..body.len], body);
            }
            return .{ .allocator = allocator, .bytes = output };
        }

        pub fn ViewFor(comptime Source: type) type {
            return struct {
                spans: [fields.len]Span(Source),
                const Self = @This();
                pub const ReadError = Error || SourceError(Source);

                pub fn open(source: Source) ReadError!Self {
                    const header_size = (fields.len - 1) * @sizeOf(u32);
                    if (length(Source, &source) < header_size) return error.Truncated;
                    const header = try read(Source, &source, 0, header_size);
                    var layout = Layout.init(header_size);
                    var result: Self = undefined;
                    inline for (fields, 0..) |_, index| {
                        if (layout.cursor > length(Source, &source)) return error.InvalidFormat;
                        const body_length = if (index + 1 < fields.len)
                            try readInt(u32, header, index * 4)
                        else
                            length(Source, &source) - layout.cursor;
                        const extent = try layout.take(body_length, 1);
                        result.spans[index] = try Span(Source).init(source, extent.offset, extent.length);
                    }
                    if (layout.cursor != length(Source, &source)) return error.InvalidFormat;
                    return result;
                }

                pub fn part(self: *const Self, comptime name: Part) Span(Source) {
                    inline for (fields, 0..) |field, index| if (std.mem.eql(u8, field.name, @tagName(name))) return self.spans[index];
                    unreachable;
                }
            };
        }
    };
}

pub fn buildArchive(allocator: std.mem.Allocator, sections: []const SectionInput) (Error || std.mem.Allocator.Error)!Owned {
    if (sections.len > 32) return error.InvalidFormat;
    var layout = Layout.init(archive_header + sections.len * archive_record);
    var extents: [32]Extent = undefined;
    var previous: ?u32 = null;
    for (sections, 0..) |section, index| {
        if (previous) |tag| if (section.tag <= tag) return error.InvalidFormat;
        previous = section.tag;
        extents[index] = try layout.take(section.data.len, 8);
    }
    if (layout.cursor > std.math.maxInt(u32)) return error.Overflow;
    var output = try allocator.alloc(u8, layout.cursor);
    errdefer allocator.free(output);
    @memset(output, 0);
    @memcpy(output[0..4], archive_magic);
    try writeInt(u16, output, 4, archive_version);
    try writeInt(u16, output, 6, @intCast(sections.len));
    try writeInt(u32, output, 8, @intCast(layout.cursor));
    for (sections, 0..) |section, index| {
        const record = archive_header + index * archive_record;
        try writeInt(u32, output, record, section.tag);
        try writeInt(u64, output, record + 8, section.data.len);
        @memcpy(output[extents[index].offset..][0..section.data.len], section.data);
    }
    return .{ .allocator = allocator, .bytes = output };
}

pub fn ArchiveFor(comptime Source: type) type {
    return struct {
        source: Source,
        count: usize,
        tags: [32]u32,
        extents: [32]Extent,
        const Self = @This();
        pub const ReadError = Error || SourceError(Source);

        pub fn open(source: Source) ReadError!Self {
            if (length(Source, &source) < archive_header) return error.Truncated;
            const header = try read(Source, &source, 0, archive_header);
            if (!std.mem.eql(u8, header[0..4], archive_magic)) return error.InvalidFormat;
            if (try readInt(u16, header, 4) != archive_version) return error.UnsupportedVersion;
            const count = try readInt(u16, header, 6);
            if (count > 32 or try readInt(u32, header, 8) != length(Source, &source) or try readInt(u32, header, 12) != 0) return error.InvalidFormat;
            const directory_size = std.math.mul(usize, count, archive_record) catch return error.Overflow;
            const directory = try read(Source, &source, archive_header, directory_size);
            var result = Self{ .source = source, .count = count, .tags = undefined, .extents = undefined };
            var layout = Layout.init(archive_header + directory_size);
            var previous: ?u32 = null;
            for (0..count) |index| {
                const record = index * archive_record;
                const tag = try readInt(u32, directory, record);
                if (previous) |prior| if (tag <= prior) return error.InvalidFormat;
                if (try readInt(u32, directory, record + 4) != 0) return error.InvalidFormat;
                const size = std.math.cast(usize, try readInt(u64, directory, record + 8)) orelse return error.Overflow;
                result.tags[index] = tag;
                result.extents[index] = try layout.take(size, 8);
                previous = tag;
            }
            if (layout.cursor != length(Source, &source)) return error.InvalidFormat;
            return result;
        }

        pub fn section(self: *const Self, tag: u32) ReadError!?Span(Source) {
            for (self.tags[0..self.count], 0..) |candidate, index| {
                if (candidate == tag) {
                    const extent = self.extents[index];
                    return @as(?Span(Source), try Span(Source).init(self.source, extent.offset, extent.length));
                }
                if (candidate > tag) break;
            }
            return null;
        }
    };
}

test "layout derives aligned extents with checked arithmetic" {
    var layout = Layout.init(7);
    try std.testing.expectEqual(Extent{ .offset = 8, .length = 3 }, try layout.take(3, 4));
    try std.testing.expectEqual(Extent{ .offset = 16, .length = 2 }, try layout.take(2, 8));
    try std.testing.expectError(error.InvalidFormat, layout.take(1, 3));
    var hostile = Layout.init(std.math.maxInt(usize));
    try std.testing.expectError(error.Overflow, hostile.take(1, 8));
    try std.testing.expectEqual(std.math.maxInt(usize), hostile.cursor);
}

const TestAuthSource = struct {
    data: []const u8,
    denied: *bool,
    calls: *usize,

    pub fn len(self: *const @This()) usize {
        return self.data.len;
    }

    pub fn bytes(self: *const @This(), offset: usize, size: usize) (Error || error{Denied})![]const u8 {
        self.calls.* += 1;
        if (self.denied.*) return error.Denied;
        return at(self.data, offset, size);
    }
};

const CounterfeitSpan = struct {
    pub const BaseSource = []const u8;
    source: []const u8,
    base: usize,
    size: usize,
    denied: *bool,

    pub fn len(self: *const @This()) usize {
        return self.size;
    }

    pub fn bytes(self: *const @This(), offset: usize, size: usize) (Error || error{Denied})![]const u8 {
        if (self.denied.*) return error.Denied;
        return at(self.source, self.base + offset, size);
    }
};

const SelfReferentialSource = struct {
    pub const BaseSource = @This();
    data: []const u8,
    denied: *bool,

    pub fn len(self: *const @This()) usize {
        return self.data.len;
    }

    pub fn bytes(self: *const @This(), offset: usize, size: usize) (Error || error{Denied})![]const u8 {
        if (self.denied.*) return error.Denied;
        return at(self.data, offset, size);
    }
};

test "nested spans have one flat type and checked absolute coordinates" {
    const data: []const u8 = "0123456789abcdef";
    const Flat = Span([]const u8);
    const Nested = Span(Flat);
    const Deep = Span(Nested);
    comptime if (Flat != Nested or Flat != Deep) @compileError("nested Span changed concrete type");

    const first = try Flat.init(data, 2, 10);
    const second = try Nested.init(first, 3, 5);
    const third = try Deep.init(second, 1, 2);
    try std.testing.expectEqual(@as(usize, 6), third.base);
    try std.testing.expectEqual(@as(usize, 1), try third.offsetFrom(second));
    try std.testing.expectEqualStrings("67", try third.bytes(0, 2));
    try std.testing.expectError(error.Truncated, third.bytes(2, 1));
    try std.testing.expectError(error.Truncated, Flat.init(first, first.size, 1));

    const forged = Flat{ .source = data, .base = std.math.maxInt(usize), .size = 2 };
    try std.testing.expectError(error.Overflow, Flat.init(forged, 1, 1));
    const empty = try Flat.init(data, data.len, 0);
    try std.testing.expectEqual(@as(usize, 0), (try empty.bytes(0, 0)).len);

    const array = [4]u8{ 'a', 'b', 'c', 'd' };
    const borrowed = try Flat.init(&array, 1, 2);
    try std.testing.expectEqualStrings("bc", try borrowed.bytes(0, 2));
}

test "flat spans preserve authentication and never peel counterfeit sources" {
    var denied = false;
    var calls: usize = 0;
    var source = TestAuthSource{ .data = "authenticated", .denied = &denied, .calls = &calls };
    const AuthSpan = Span(*TestAuthSource);
    const first = try AuthSpan.init(&source, 2, 8);
    const second = try Span(AuthSpan).init(first, 2, 4);
    try std.testing.expectEqualStrings("enti", try second.bytes(0, 4));
    try std.testing.expectEqual(@as(usize, 1), calls);
    denied = true;
    try std.testing.expectError(error.Denied, second.bytes(0, 1));
    try std.testing.expectEqual(@as(usize, 2), calls);

    denied = false;
    const fake = CounterfeitSpan{ .source = "wrapper", .base = 1, .size = 4, .denied = &denied };
    const FakeSpan = Span(CounterfeitSpan);
    comptime if (@typeInfo(FakeSpan).@"struct".fields[0].type != CounterfeitSpan) {
        @compileError("counterfeit source was peeled");
    };
    const nested_fake = try FakeSpan.init(fake, 1, 2);
    try std.testing.expectEqualStrings("ap", try nested_fake.bytes(0, 2));
    denied = true;
    try std.testing.expectError(error.Denied, nested_fake.bytes(0, 1));

    denied = false;
    const self_source = SelfReferentialSource{ .data = "opaque", .denied = &denied };
    const SelfSpan = Span(SelfReferentialSource);
    const self_span = try SelfSpan.init(self_source, 1, 3);
    try std.testing.expectEqualStrings("paq", try self_span.bytes(0, 3));
    denied = true;
    try std.testing.expectError(error.Denied, self_span.bytes(0, 1));
}
