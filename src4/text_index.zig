//! Text ownership is a typed projection into grammar-item ranks.
//!
//! A generated table stores zero-, one-, and many-item spans with the same
//! coordinate equation used by graph records. A rank permutation orders spans
//! for linear allocation-free verification; ordered ownership makes that
//! permutation an affine lane with no payload.

const std = @import("std");
const forest = @import("forest.zig");
const schema = @import("schema.zig");
const table = @import("table.zig");
const wire = @import("wire.zig");

pub const magic = "L4TX";
pub const version: u16 = 2;
pub const header_size: usize = 24;
pub const Span = struct { first: u32, count: u32 };
pub const DomainInput = struct { kind: schema.Kind, spans: []const Span };
pub const ContiguousDomainInput = struct { kind: schema.Kind, first: usize, count: usize };
const Row = struct { first: u32, count: u32, owner_order: u32 };
const Rows = table.Table(Row);
pub const Error = forest.Error || std.mem.Allocator.Error || error{
    InvalidFormat,
    UnsupportedVersion,
    Truncated,
    InvalidDomain,
    MissingDomain,
    DuplicateDomain,
    CrossSectionMismatch,
    RankOutOfRange,
    Overflow,
};
pub const ByteLedger = struct { header: usize, directory: usize, payload: usize, total: usize };
pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    ledger: ByteLedger,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

fn kindCount(view: *const forest.View, kind: schema.Kind) Error!usize {
    return switch (kind) {
        inline else => |known| view.kindCount(known),
    };
}
fn read(comptime T: type, bytes: []const u8, at: usize) Error!T {
    return wire.readInt(T, bytes, at) catch return error.Truncated;
}
fn write(comptime T: type, bytes: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .little);
}

pub fn build(allocator: std.mem.Allocator, structure: *const forest.View, prose_count: usize, domains: []const DomainInput) Error!Owned {
    if (prose_count > std.math.maxInt(u32)) return error.Overflow;
    var counts = [_]u32{0} ** schema.kind_count;
    var inputs = [_][]const Span{&.{}} ** schema.kind_count;
    var seen = schema.KindSet.initEmpty();
    var mask: u32 = 0;
    var total: usize = 0;
    for (domains) |domain| {
        const k = @intFromEnum(domain.kind);
        if (seen.isSet(k)) return error.DuplicateDomain;
        seen.set(k);
        if (!schema.spec(domain.kind).text and domain.spans.len != 0) return error.InvalidDomain;
        counts[k] = std.math.cast(u32, domain.spans.len) orelse return error.Overflow;
        inputs[k] = domain.spans;
    }
    for (0..schema.kind_count) |k| {
        const kind: schema.Kind = @enumFromInt(k);
        const expected = try kindCount(structure, kind);
        if (schema.spec(kind).text) {
            if (expected != 0 and !seen.isSet(k)) return error.MissingDomain;
            if (counts[k] != expected) return error.CrossSectionMismatch;
        }
        if (counts[k] != 0) mask |= @as(u32, 1) << @intCast(k);
        total = std.math.add(usize, total, counts[k]) catch return error.Overflow;
    }
    if (total > std.math.maxInt(u32)) return error.Overflow;
    const rows = try allocator.alloc(Row, total);
    defer allocator.free(rows);
    const order = try allocator.alloc(u32, total);
    defer allocator.free(order);
    var position: usize = 0;
    for (inputs) |spans| for (spans) |span| {
        if (span.first > prose_count or span.count > prose_count - span.first) return error.CrossSectionMismatch;
        rows[position] = .{ .first = span.first, .count = span.count, .owner_order = 0 };
        order[position] = @intCast(position);
        position += 1;
    };
    std.mem.sort(u32, order, rows, struct {
        fn less(values: []Row, a: u32, b: u32) bool {
            return values[a].first < values[b].first or (values[a].first == values[b].first and a < b);
        }
    }.less);
    for (order, 0..) |owner, index| rows[index].owner_order = owner;
    var encoded = Rows.build(allocator, rows) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidFormat;
    defer encoded.deinit();
    const directory_len = @as(usize, @popCount(mask)) * 4;
    const table_at = header_size + directory_len;
    const length = std.math.add(usize, table_at, encoded.bytes.len) catch return error.Overflow;
    if (length > std.math.maxInt(u32)) return error.Overflow;
    const bytes = try allocator.alloc(u8, length);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], magic);
    write(u16, bytes, 4, version);
    write(u16, bytes, 6, header_size);
    write(u32, bytes, 8, @intCast(prose_count));
    write(u32, bytes, 12, mask);
    write(u32, bytes, 16, @intCast(table_at));
    write(u32, bytes, 20, @intCast(length));
    position = header_size;
    for (counts) |count| if (count != 0) {
        write(u32, bytes, position, count);
        position += 4;
    };
    @memcpy(bytes[table_at..], encoded.bytes);
    const view = try View.open(bytes);
    try view.validate(structure, prose_count);
    return .{ .allocator = allocator, .bytes = bytes, .ledger = view.byteLedger() };
}

pub const View = struct {
    bytes: []const u8,
    prose_item_count: usize,
    payload_offset: usize,
    counts: [schema.kind_count]u32,
    starts: [schema.kind_count]u32,
    rows: Rows.View,

    pub fn open(bytes: []const u8) Error!View {
        if (bytes.len < header_size) return error.Truncated;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.InvalidFormat;
        if (try read(u16, bytes, 4) != version) return error.UnsupportedVersion;
        if (try read(u16, bytes, 6) != header_size or try read(u32, bytes, 20) != bytes.len) return error.InvalidFormat;
        const mask = try read(u32, bytes, 12);
        if (mask >> schema.kind_count != 0) return error.InvalidDomain;
        const payload_offset = header_size + @as(usize, @popCount(mask)) * 4;
        if (try read(u32, bytes, 16) != payload_offset or payload_offset > bytes.len) return error.InvalidFormat;
        var counts = [_]u32{0} ** schema.kind_count;
        var starts: [schema.kind_count]u32 = undefined;
        var total: u32 = 0;
        var at = header_size;
        for (0..schema.kind_count) |k| {
            starts[k] = total;
            if (mask & (@as(u32, 1) << @intCast(k)) == 0) continue;
            if (!schema.spec(@enumFromInt(k)).text) return error.InvalidDomain;
            counts[k] = try read(u32, bytes, at);
            if (counts[k] == 0) return error.InvalidFormat;
            total = std.math.add(u32, total, counts[k]) catch return error.Overflow;
            at += 4;
        }
        const rows = Rows.View.open(bytes[payload_offset..]) catch return error.InvalidFormat;
        if (rows.len() != total) return error.CrossSectionMismatch;
        return .{ .bytes = bytes, .prose_item_count = try read(u32, bytes, 8), .payload_offset = payload_offset, .counts = counts, .starts = starts, .rows = rows };
    }

    pub fn byteLedger(self: *const View) ByteLedger {
        return .{ .header = header_size, .directory = self.payload_offset - header_size, .payload = self.bytes.len - self.payload_offset, .total = self.bytes.len };
    }

    fn spanAt(self: *const View, index: usize) Error!Span {
        const first = self.rows.field(index, .first) catch return error.InvalidFormat;
        const count = self.rows.field(index, .count) catch return error.InvalidFormat;
        if (first > self.prose_item_count or count > self.prose_item_count - first) return error.CrossSectionMismatch;
        return .{ .first = first, .count = count };
    }

    pub fn span(self: *const View, comptime kind: schema.Kind, rank: schema.Rank(kind)) Error!Span {
        comptime if (!schema.spec(kind).text) @compileError("text ownership requires a text-bearing kind");
        const index = rank.index() orelse return error.RankOutOfRange;
        const k = @intFromEnum(kind);
        if (index >= self.counts[k]) return error.RankOutOfRange;
        return self.spanAt(self.starts[k] + index);
    }

    pub fn validate(self: *const View, structure: *const forest.View, prose_count: usize) Error!void {
        if (self.prose_item_count != prose_count) return error.CrossSectionMismatch;
        self.rows.verify() catch return error.InvalidFormat;
        for (0..schema.kind_count) |k| {
            const kind: schema.Kind = @enumFromInt(k);
            if (schema.spec(kind).text and self.counts[k] != try kindCount(structure, kind)) return error.CrossSectionMismatch;
        }
        var end: usize = 0;
        var previous: ?struct { first: u32, owner: u32 } = null;
        for (0..self.rows.len()) |index| {
            const owner = self.rows.field(index, .owner_order) catch return error.InvalidFormat;
            if (owner >= self.rows.len()) return error.InvalidDomain;
            const value = try self.spanAt(owner);
            if (previous) |prior| {
                if (value.first < prior.first or (value.first == prior.first and owner <= prior.owner)) return error.InvalidDomain;
            }
            previous = .{ .first = value.first, .owner = owner };
            // Empty owners may occur inside another owner's span. Nonempty
            // owners must partition the complete prose domain exactly once.
            if (value.count == 0) continue;
            if (value.first != end) return error.InvalidDomain;
            end += value.count;
        }
        if (end != prose_count) return error.InvalidDomain;
    }
};

pub fn buildContiguous(allocator: std.mem.Allocator, structure: *const forest.View, prose_count: usize, declarations: []const ContiguousDomainInput) Error!Owned {
    if (prose_count > std.math.maxInt(u32)) return error.Overflow;
    var total: usize = 0;
    for (declarations) |declaration| total = std.math.add(usize, total, declaration.count) catch return error.Overflow;
    const spans = try allocator.alloc(Span, total);
    defer allocator.free(spans);
    const inputs = try allocator.alloc(DomainInput, declarations.len);
    defer allocator.free(inputs);
    var cursor: usize = 0;
    for (declarations, 0..) |declaration, index| {
        if (declaration.first > prose_count or declaration.count > prose_count - declaration.first) return error.CrossSectionMismatch;
        for (0..declaration.count) |offset| spans[cursor + offset] = .{ .first = @intCast(declaration.first + offset), .count = 1 };
        inputs[index] = .{ .kind = declaration.kind, .spans = spans[cursor..][0..declaration.count] };
        cursor += declaration.count;
    }
    return build(allocator, structure, prose_count, inputs);
}

test "one generated table handles irregular and zero-many text ownership" {
    const allocator = std.testing.allocator;
    var builder = forest.Builder.init(allocator);
    defer builder.deinit();
    const root = try builder.addRoot("entry", .entry);
    const sense = try builder.addChild(root, .sense);
    for (0..3) |_| _ = try builder.addChild(sense, .definition);
    _ = try builder.addChild(sense, .example);
    var structure = try builder.build();
    defer structure.deinit();
    const definitions = [_]Span{ .{ .first = 2, .count = 1 }, .{ .first = 0, .count = 2 }, .{ .first = 1, .count = 0 } };
    var owned = try build(allocator, &structure.view, 4, &.{
        .{ .kind = .definition, .spans = &definitions },
        .{ .kind = .example, .spans = &.{.{ .first = 3, .count = 1 }} },
    });
    defer owned.deinit();
    const view = try View.open(owned.bytes);
    try view.validate(&structure.view, 4);
    for (definitions, 0..) |expected, index|
        try std.testing.expectEqualDeep(expected, try view.span(.definition, @enumFromInt(index)));
    try std.testing.expectEqual(@as(u32, 3), (try view.span(.example, @enumFromInt(0))).first);
    try std.testing.expectEqual(owned.bytes.len, view.byteLedger().total);
    try std.testing.expect(owned.bytes.len < 408);
    try std.testing.expectError(error.InvalidDomain, build(allocator, &structure.view, 5, &.{
        .{ .kind = .definition, .spans = &definitions },
        .{ .kind = .example, .spans = &.{.{ .first = 3, .count = 1 }} },
    }));
    try std.testing.expectError(error.InvalidDomain, build(allocator, &structure.view, 4, &.{
        .{ .kind = .definition, .spans = &definitions },
        .{ .kind = .example, .spans = &.{.{ .first = 2, .count = 1 }} },
    }));
    const malformed = try allocator.dupe(u8, owned.bytes);
    defer allocator.free(malformed);
    write(u32, malformed, 16, @intCast(view.payload_offset + 1));
    try std.testing.expectError(error.InvalidFormat, View.open(malformed));
    write(u32, malformed, 16, @intCast(view.payload_offset));
    write(u32, malformed, 12, (@as(u32, 1) << @intFromEnum(schema.Kind.entry)) | (@as(u32, 1) << @intFromEnum(schema.Kind.example)));
    try std.testing.expectError(error.InvalidDomain, View.open(malformed));
}

test "text ownership has constant size for affine coordinates" {
    const allocator = std.testing.allocator;
    var builder = forest.Builder.init(allocator);
    defer builder.deinit();
    for (0..2048) |_| {
        const root = try builder.addRoot("entry", .entry);
        const sense = try builder.addChild(root, .sense);
        _ = try builder.addChild(sense, .definition);
    }
    var structure = try builder.build();
    defer structure.deinit();
    var owned = try buildContiguous(allocator, &structure.view, 2048, &.{.{ .kind = .definition, .first = 0, .count = 2048 }});
    defer owned.deinit();
    try std.testing.expect(owned.bytes.len <= 128);
    const view = try View.open(owned.bytes);
    try view.validate(&structure.view, 2048);
    for (0..2048) |index| try std.testing.expectEqualDeep(Span{ .first = @intCast(index), .count = 1 }, try view.span(.definition, @enumFromInt(index)));
}

test "arbitrary ownership is differential, deterministic, and allocation-safe" {
    const allocator = std.testing.allocator;
    var builder = forest.Builder.init(allocator);
    defer builder.deinit();
    const root = try builder.addRoot("entry", .entry);
    const sense = try builder.addChild(root, .sense);
    for (0..32) |_| _ = try builder.addChild(sense, .definition);
    var structure = try builder.build();
    defer structure.deinit();
    var random = std.Random.DefaultPrng.init(0x7ec70);
    var spans: [32]Span = undefined;
    for (0..32) |_| {
        var total: u32 = 0;
        for (&spans) |*span| {
            const count = random.random().uintLessThan(u32, 5);
            span.* = .{ .first = total, .count = count };
            total += count;
        }
        random.random().shuffle(Span, &spans);
        var owned = try build(allocator, &structure.view, total, &.{.{ .kind = .definition, .spans = &spans }});
        defer owned.deinit();
        var again = try build(allocator, &structure.view, total, &.{.{ .kind = .definition, .spans = &spans }});
        defer again.deinit();
        try std.testing.expectEqualSlices(u8, owned.bytes, again.bytes);
        const view = try View.open(owned.bytes);
        try view.validate(&structure.view, total);
        for (spans, 0..) |expected, index|
            try std.testing.expectEqualDeep(expected, try view.span(.definition, @enumFromInt(index)));
        try std.testing.expectError(error.RankOutOfRange, view.span(.definition, @enumFromInt(32)));
    }
    const Probe = struct {
        fn run(alloc: std.mem.Allocator, tree: *const forest.View) !void {
            var owned = try buildContiguous(alloc, tree, 32, &.{.{ .kind = .definition, .first = 0, .count = 32 }});
            defer owned.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Probe.run, .{&structure.view});
    try std.testing.expectError(error.MissingDomain, build(allocator, &structure.view, 0, &.{}));
    try std.testing.expectError(error.DuplicateDomain, build(allocator, &structure.view, 0, &.{
        .{ .kind = .definition, .spans = &.{} }, .{ .kind = .definition, .spans = &.{} },
    }));
}

test "ownership verifier rejects duplicate permutation rows independently of scalar validity" {
    const allocator = std.testing.allocator;
    var builder = forest.Builder.init(allocator);
    defer builder.deinit();
    const root = try builder.addRoot("entry", .entry);
    const sense = try builder.addChild(root, .sense);
    for (0..3) |_| _ = try builder.addChild(sense, .definition);
    var structure = try builder.build();
    defer structure.deinit();
    var owned = try buildContiguous(allocator, &structure.view, 3, &.{.{ .kind = .definition, .first = 0, .count = 3 }});
    defer owned.deinit();
    var bad_rows = try Rows.build(allocator, &.{
        .{ .first = 0, .count = 1, .owner_order = 0 },
        .{ .first = 1, .count = 1, .owner_order = 0 },
        .{ .first = 2, .count = 1, .owner_order = 2 },
    });
    defer bad_rows.deinit();
    const prefix = header_size + 4;
    const malformed = try allocator.alloc(u8, prefix + bad_rows.bytes.len);
    defer allocator.free(malformed);
    @memcpy(malformed[0..prefix], owned.bytes[0..prefix]);
    @memcpy(malformed[prefix..], bad_rows.bytes);
    write(u32, malformed, 20, @intCast(malformed.len));
    const view = try View.open(malformed);
    try view.rows.verify(); // The field codec is valid; the ownership proof is not.
    try std.testing.expectError(error.InvalidDomain, view.validate(&structure.view, 3));
    for (0..owned.bytes.len) |end| {
        if (View.open(owned.bytes[0..end])) |_| return error.TestExpectedError else |_| {}
    }
}
