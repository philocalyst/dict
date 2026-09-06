const std = @import("std");
const semantic = @import("semantic.zig");

/// Canonical, lossless semantic snapshot.  It is intentionally a reference
/// encoding: explicit little endian integers, checked lengths, and no native
/// struct or pointer casts.  Compact sections may be added in a later major
/// version after this representation is used as the semantic oracle.
pub const magic = "LEXSEM\x00\x01";
pub const format_major: u16 = 0;
pub const format_minor: u16 = 3;
pub const header_bytes: usize = 112;

pub const Error = error{
    InvalidMagic,
    InvalidHeader,
    UnsupportedVersion,
    UnsupportedFlags,
    Truncated,
    TrailingBytes,
    InvalidChecksum,
    InvalidLength,
    Overflow,
    InvalidTag,
    InvalidUtf8,
    InvalidUri,
    InvalidReference,
    InvalidCardinality,
    InvalidNamespace,
    InvalidName,
    InvalidExternalId,
    InvalidAssertion,
    InvalidStatementReference,
    InvalidDate,
    InvalidTemporalRange,
    InvalidDocument,
    DocumentCycle,
    DocumentMultipleParent,
    DuplicateRoot,
    DuplicateChild,
    ResourceLimit,
    OutOfMemory,
};

pub const DecodeOptions = struct {
    max_total_bytes: usize = 1 << 31,
    max_items: usize = 1 << 28,
    max_string_bytes: usize = 1 << 24,
    max_sequence_items: usize = 1 << 24,
    max_attributes: usize = 1 << 24,
    max_participants: usize = 1 << 24,
    max_evidence: usize = 1 << 24,
    max_children: usize = 1 << 24,
    max_document_depth: usize = 4096,
};
pub const DecodeLimits = DecodeOptions;

const Writer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    fn deinit(self: *Writer) void {
        self.bytes.deinit(self.allocator);
    }
    fn raw(self: *Writer, x: []const u8) Error!void {
        self.bytes.appendSlice(self.allocator, x) catch return Error.OutOfMemory;
    }
    fn putByte(self: *Writer, x: u8) Error!void {
        self.bytes.append(self.allocator, x) catch return Error.OutOfMemory;
    }
    fn putU32(self: *Writer, x: u32) Error!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, x, .little);
        try self.raw(&b);
    }
    fn putU64(self: *Writer, x: u64) Error!void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, x, .little);
        try self.raw(&b);
    }
    fn putI32(self: *Writer, x: i32) Error!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(i32, &b, x, .little);
        try self.raw(&b);
    }
    fn putI64(self: *Writer, x: i64) Error!void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(i64, &b, x, .little);
        try self.raw(&b);
    }
    fn count(self: *Writer, x: usize) Error!void {
        self.putU64(@intCast(x)) catch return Error.Overflow;
    }
    fn string(self: *Writer, x: []const u8) Error!void {
        try self.count(x.len);
        try self.raw(x);
    }
    fn optionalString(self: *Writer, x: ?[]const u8) Error!void {
        try self.putByte(if (x == null) 0 else 1);
        if (x) |s| try self.string(s);
    }
};

const Reader = struct {
    bytes: []const u8,
    at: usize,
    options: DecodeOptions,
    allocator: std.mem.Allocator,
    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (n > self.bytes.len -| self.at) return Error.Truncated;
        const x = self.bytes[self.at .. self.at + n];
        self.at += n;
        return x;
    }
    fn byte(self: *Reader) Error!u8 {
        return (try self.take(1))[0];
    }
    fn getU32(self: *Reader) Error!u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }
    fn getU64(self: *Reader) Error!u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .little);
    }
    fn getI32(self: *Reader) Error!i32 {
        return std.mem.readInt(i32, (try self.take(4))[0..4], .little);
    }
    fn getI64(self: *Reader) Error!i64 {
        return std.mem.readInt(i64, (try self.take(8))[0..8], .little);
    }
    fn id(self: *Reader) Error!u32 {
        return self.getU32();
    }
    fn count(self: *Reader, max: usize) Error!usize {
        const x = try self.getU64();
        if (x > max or x > std.math.maxInt(usize)) return Error.ResourceLimit;
        return @intCast(x);
    }
    fn slice(self: *Reader, raw: bool) Error![]const u8 {
        const x = try self.getU64();
        if (x > self.options.max_string_bytes or x > std.math.maxInt(usize)) return Error.ResourceLimit;
        const out = try self.take(@intCast(x));
        if (!raw and !std.unicode.utf8ValidateSlice(out)) return Error.InvalidUtf8;
        return out;
    }
    fn optionalSlice(self: *Reader, raw: bool) Error!?[]const u8 {
        return switch (try self.byte()) {
            0 => null,
            1 => try self.slice(raw),
            else => Error.InvalidTag,
        };
    }
};

pub fn encode(allocator: std.mem.Allocator, model: *const semantic.Model) Error![]u8 {
    try validateModel(model);
    var w = Writer{ .allocator = allocator };
    errdefer w.deinit();
    w.bytes.appendNTimes(allocator, 0, header_bytes) catch return Error.OutOfMemory;
    try writeNamespaces(&w, model.namespaces);
    try writeSources(&w, model.sources);
    try writeValues(&w, model.values);
    try writeEntities(&w, model.entities);
    try writeDocuments(&w, model.documents);
    try writeRoots(&w, model.roots);
    try writeAssertions(&w, model.assertions);
    try writeEntityAnchors(&w, model.entity_anchors);
    try writeAssertionAnchors(&w, model.assertion_anchors);
    const total = std.math.cast(u64, w.bytes.items.len) orelse return Error.Overflow;
    @memcpy(w.bytes.items[0..magic.len], magic);
    std.mem.writeInt(u16, w.bytes.items[8..10], format_major, .little);
    std.mem.writeInt(u16, w.bytes.items[10..12], format_minor, .little);
    std.mem.writeInt(u32, w.bytes.items[12..16], 0, .little);
    std.mem.writeInt(u32, w.bytes.items[16..20], header_bytes, .little);
    std.mem.writeInt(u64, w.bytes.items[20..28], total, .little);
    std.mem.writeInt(u64, w.bytes.items[28..36], checksum(w.bytes.items[header_bytes..]), .little);
    const counts = [_]u64{ @intCast(model.namespaces.len), @intCast(model.values.len), @intCast(model.entities.len), @intCast(model.assertions.len), @intCast(model.documents.len), @intCast(model.roots.len), @intCast(model.sources.len), @intCast(model.entity_anchors.len), @intCast(model.assertion_anchors.len) };
    var at: usize = 36;
    for (counts) |x| {
        std.mem.writeInt(u64, w.bytes.items[at..][0..8], x, .little);
        at += 8;
    }
    return w.bytes.toOwnedSlice(allocator) catch return Error.OutOfMemory;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, options: DecodeOptions) Error!semantic.Model {
    if (bytes.len > options.max_total_bytes) return Error.ResourceLimit;
    if (bytes.len < header_bytes) return Error.Truncated;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return Error.InvalidMagic;
    // v0.2 has no source manifest or anchor sections. Since those old sections
    // are not self-describing, accepting v0.2 here would silently reinterpret
    // bytes. Require the explicitly versioned v0.3 encoding instead of
    // guessing.
    if (std.mem.readInt(u16, bytes[8..10], .little) != format_major or std.mem.readInt(u16, bytes[10..12], .little) != format_minor) return Error.UnsupportedVersion;
    if (std.mem.readInt(u32, bytes[12..16], .little) != 0) return Error.UnsupportedFlags;
    if (std.mem.readInt(u32, bytes[16..20], .little) != header_bytes) return Error.InvalidHeader;
    const declared_length = std.mem.readInt(u64, bytes[20..28], .little);
    if (declared_length > bytes.len) return Error.Truncated;
    if (declared_length < bytes.len) return Error.InvalidLength;
    if (std.mem.readInt(u64, bytes[28..36], .little) != checksum(bytes[header_bytes..])) return Error.InvalidChecksum;
    if (std.mem.readInt(u32, bytes[108..112], .little) != 0) return Error.InvalidHeader;
    const header_counts = [9]u64{
        std.mem.readInt(u64, bytes[36..44], .little),
        std.mem.readInt(u64, bytes[44..52], .little),
        std.mem.readInt(u64, bytes[52..60], .little),
        std.mem.readInt(u64, bytes[60..68], .little),
        std.mem.readInt(u64, bytes[68..76], .little),
        std.mem.readInt(u64, bytes[76..84], .little),
        std.mem.readInt(u64, bytes[84..92], .little),
        std.mem.readInt(u64, bytes[92..100], .little),
        std.mem.readInt(u64, bytes[100..108], .little),
    };
    for (header_counts) |x| if (x > options.max_items or x > std.math.maxInt(usize)) return Error.ResourceLimit;
    var r = Reader{ .bytes = bytes, .at = header_bytes, .options = options, .allocator = allocator };
    var b = semantic.Builder.init(allocator);
    b.setDocumentDepthBudget(options.max_document_depth);
    errdefer b.deinit();
    const ns_count = try r.count(options.max_items);
    if (ns_count != header_counts[0]) return Error.InvalidLength;
    var i: usize = 0;
    while (i < ns_count) : (i += 1) {
        const uri = try r.slice(false);
        const prefix = try r.slice(false);
        const u = allocator.dupe(u8, uri) catch return Error.OutOfMemory;
        errdefer allocator.free(u);
        const p = allocator.dupe(u8, prefix) catch return Error.OutOfMemory;
        b.namespaces.append(allocator, .{ .uri = u, .prefix = p }) catch return Error.OutOfMemory;
    }
    const source_count = try r.count(options.max_items);
    if (source_count != header_counts[6]) return Error.InvalidLength;
    i = 0;
    while (i < source_count) : (i += 1) {
        const external_id = try optionalOwned(&r, allocator, false);
        const base_uri = optionalOwned(&r, allocator, false) catch |err| {
            if (external_id) |id| allocator.free(id);
            return err;
        };
        const source = semantic.Source{ .external_id = external_id, .base_uri = base_uri };
        b.sources.append(allocator, source) catch {
            freeSourceOwned(allocator, source);
            return Error.OutOfMemory;
        };
    }
    const value_count = try r.count(options.max_items);
    if (value_count != header_counts[1]) return Error.InvalidLength;
    i = 0;
    while (i < value_count) : (i += 1) {
        const value = try readValue(&r, allocator);
        b.values.append(allocator, value) catch return Error.OutOfMemory;
    }
    const entity_count = try r.count(options.max_items);
    if (entity_count != header_counts[2]) return Error.InvalidLength;
    i = 0;
    while (i < entity_count) : (i += 1) {
        const kind = try enumValue(semantic.EntityKind, try r.byte());
        const external = try optionalOwned(&r, allocator, false);
        const label = try optionalValue(&r, value_count);
        const source = try optionalSource(&r, source_count);
        b.entities.append(allocator, .{ .kind = kind, .external_id = external, .label = label, .source = source }) catch return Error.OutOfMemory;
    }
    const doc_count = try r.count(options.max_items);
    if (doc_count != header_counts[4]) return Error.InvalidLength;
    i = 0;
    while (i < doc_count) : (i += 1) {
        const node = try readDocument(&r, allocator, options, source_count);
        b.documents.append(allocator, node) catch return Error.OutOfMemory;
    }
    const root_count = try r.count(options.max_items);
    if (root_count != header_counts[5]) return Error.InvalidLength;
    i = 0;
    while (i < root_count) : (i += 1) {
        const id = try r.id();
        if (id >= doc_count) return Error.InvalidReference;
        b.roots.append(allocator, .{ .index = id }) catch return Error.OutOfMemory;
    }
    const assertion_count = try r.count(options.max_items);
    if (assertion_count != header_counts[3]) return Error.InvalidLength;
    i = 0;
    while (i < assertion_count) : (i += 1) {
        const x = try readAssertion(&r, allocator, entity_count, value_count, doc_count, source_count, assertion_count, i, options);
        b.assertions.append(allocator, x) catch return Error.OutOfMemory;
    }
    const entity_anchor_count = try r.count(options.max_items);
    if (entity_anchor_count != header_counts[7]) return Error.InvalidLength;
    i = 0;
    while (i < entity_anchor_count) : (i += 1) {
        b.entity_anchors.append(allocator, .{ .entity = .{ .index = try r.id() }, .anchor = try readAnchor(&r, source_count, doc_count) }) catch return Error.OutOfMemory;
    }
    const assertion_anchor_count = try r.count(options.max_items);
    if (assertion_anchor_count != header_counts[8]) return Error.InvalidLength;
    i = 0;
    while (i < assertion_anchor_count) : (i += 1) {
        b.assertion_anchors.append(allocator, .{ .assertion = .{ .index = try r.id() }, .anchor = try readAnchor(&r, source_count, doc_count) }) catch return Error.OutOfMemory;
    }
    if (r.at != bytes.len) return Error.TrailingBytes;
    return b.build() catch |e| return mapSemantic(e);
}
pub fn decodeWithLimits(allocator: std.mem.Allocator, bytes: []const u8, options: DecodeOptions) Error!semantic.Model {
    return decode(allocator, bytes, options);
}

fn writeNamespaces(w: *Writer, xs: []const semantic.Namespace) Error!void {
    try w.count(xs.len);
    for (xs) |x| {
        try w.string(x.uri);
        try w.string(x.prefix);
    }
}
fn writeSources(w: *Writer, xs: []const semantic.Source) Error!void {
    try w.count(xs.len);
    for (xs) |x| {
        try w.optionalString(x.external_id);
        try w.optionalString(x.base_uri);
    }
}
fn writeValues(w: *Writer, xs: []const semantic.Value) Error!void {
    try w.count(xs.len);
    for (xs) |x| switch (x) {
        .text => |v| {
            try w.putByte(0);
            try w.string(v.bytes);
            try w.optionalString(v.language);
            try w.optionalString(v.script);
            try w.optionalString(v.notation);
        },
        .bytes => |v| {
            try w.putByte(1);
            try w.string(v);
        },
        .boolean => |v| {
            try w.putByte(2);
            try w.putByte(if (v) 1 else 0);
        },
        .signed_integer => |v| {
            try w.putByte(3);
            try w.putI64(v);
        },
        .unsigned_integer => |v| {
            try w.putByte(4);
            try w.putU64(v);
        },
        .decimal => |v| {
            try w.putByte(5);
            try w.putI64(v.coefficient);
            try w.putI32(v.scale);
        },
        .uri => |v| {
            try w.putByte(6);
            try w.string(v);
        },
        .qualified_name => |v| {
            try w.putByte(7);
            try writeName(w, v);
        },
        .entity => |v| {
            try w.putByte(8);
            try w.putU32(v.index);
        },
        .sequence => |v| {
            try w.putByte(9);
            try w.count(v.len);
            for (v) |id| try w.putU32(id.index);
        },
        .unknown => |v| {
            try w.putByte(10);
            try w.optionalString(v.reason);
        },
        .absent => try w.putByte(11),
        .uncertain => |v| {
            try w.putByte(12);
            try w.putU32(v.value.index);
            try w.putByte(@intFromEnum(v.certainty));
        },
    };
}
fn writeEntities(w: *Writer, xs: []const semantic.Entity) Error!void {
    try w.count(xs.len);
    for (xs) |x| {
        try w.putByte(@intFromEnum(x.kind));
        try w.optionalString(x.external_id);
        try optionalValueWrite(w, x.label);
        try optionalSourceWrite(w, x.source);
    }
}
fn writeDocuments(w: *Writer, xs: []const semantic.DocumentNodeOwned) Error!void {
    try w.count(xs.len);
    for (xs) |x| {
        try writeName(w, x.name);
        try optionalSourceWrite(w, x.source);
        try optionalDocumentWrite(w, x.parent);
        try writeAttributes(w, x.attributes);
        try w.count(x.children.items.len);
        for (x.children.items) |c| switch (c) {
            .node => |id| {
                try w.putByte(0);
                try w.putU32(id.index);
            },
            .text => |id| {
                try w.putByte(1);
                try w.putU32(id.index);
            },
            .comment => |id| {
                try w.putByte(2);
                try w.putU32(id.index);
            },
            .processing_instruction => |pi| {
                try w.putByte(3);
                try w.string(pi.target);
                try w.putU32(pi.data.index);
            },
        };
    }
}
fn writeRoots(w: *Writer, xs: []const semantic.DocumentNodeId) Error!void {
    try w.count(xs.len);
    for (xs) |x| try w.putU32(x.index);
}
fn writeAssertions(w: *Writer, xs: []const semantic.Assertion) Error!void {
    try w.count(xs.len);
    for (xs) |x| {
        try w.putU32(x.predicate.index);
        try optionalSourceWrite(w, x.source);
        try w.count(x.participants.len);
        for (x.participants) |p| {
            try w.string(p.role);
            try writeTarget(w, p.target);
        }
        try writeAttributes(w, x.attributes);
        try w.count(x.evidence.len);
        for (x.evidence) |e| {
            try optionalEntityWrite(w, e.source);
            try optionalDocumentWrite(w, e.document);
            try optionalValueWrite(w, e.quote);
            try optionalValueWrite(w, e.provenance);
            try writeAttributes(w, e.attributes);
        }
        try w.putByte(@intFromEnum(x.state));
        try w.putByte(@intFromEnum(x.certainty));
        try writeTemporal(w, x.temporal);
        try writeContext(w, x.context);
    }
}
fn writeEntityAnchors(w: *Writer, xs: []const semantic.EntityAnchor) Error!void {
    try w.count(xs.len);
    for (xs) |x| {
        try w.putU32(x.entity.index);
        try writeAnchor(w, x.anchor);
    }
}
fn writeAssertionAnchors(w: *Writer, xs: []const semantic.AssertionAnchor) Error!void {
    try w.count(xs.len);
    for (xs) |x| {
        try w.putU32(x.assertion.index);
        try writeAnchor(w, x.anchor);
    }
}
fn writeAnchor(w: *Writer, x: semantic.SourceAnchor) Error!void {
    try w.putU32(x.source.index);
    try w.putU32(x.node.index);
    try w.putByte(if (x.span == null) 0 else 1);
    if (x.span) |span| {
        try w.putByte(@intFromEnum(span.unit));
        try w.putU64(span.start);
        try w.putU64(span.end);
    }
}
fn writeName(w: *Writer, x: semantic.QualifiedName) Error!void {
    try w.putU32(x.namespace.index);
    try w.string(x.local);
    try w.string(x.prefix);
}
fn writeAttributes(w: *Writer, xs: []const semantic.Attribute) Error!void {
    try w.count(xs.len);
    for (xs) |x| {
        try writeName(w, x.name);
        try w.putU32(x.value.index);
    }
}
fn writeTarget(w: *Writer, x: semantic.Target) Error!void {
    switch (x) {
        .entity => |id| {
            try w.putByte(0);
            try w.putU32(id.index);
        },
        .value => |id| {
            try w.putByte(1);
            try w.putU32(id.index);
        },
        .statement => |id| {
            try w.putByte(3);
            try w.putU32(id.index);
        },
        .unresolved => |u| {
            try w.putByte(2);
            try w.string(u.bytes);
            try w.optionalString(u.uri);
            try w.optionalString(u.label);
            try w.putByte(@intFromEnum(u.status));
        },
    }
}
fn writeContext(w: *Writer, x: semantic.GraphContext) Error!void {
    switch (x) {
        .default => try w.putByte(0),
        .named => |id| {
            try w.putByte(1);
            try w.putU32(id.index);
        },
        .anonymous => |anonymous| {
            try w.putByte(2);
            try w.putByte(if (anonymous.source == null) 0 else 1);
            if (anonymous.source) |source| switch (source) {
                .entity => |id| {
                    try w.putByte(0);
                    try w.putU32(id.index);
                },
                .document => |id| {
                    try w.putByte(1);
                    try w.putU32(id.index);
                },
            };
            try w.putU64(anonymous.id);
        },
    }
}
fn writeTemporal(w: *Writer, x: ?semantic.Temporal) Error!void {
    try w.putByte(if (x == null) 0 else 1);
    if (x) |t| {
        try writeDate(w, t.start);
        try writeDate(w, t.end);
        try w.putByte(if (t.precision == null) 0 else 1);
        if (t.precision) |p| try w.putByte(@intFromEnum(p));
    }
}
fn writeDate(w: *Writer, x: ?semantic.Date) Error!void {
    try w.putByte(if (x == null) 0 else 1);
    if (x) |d| {
        try w.putI32(d.year);
        try w.putByte(if (d.month == null) 0 else 1);
        if (d.month) |m| try w.putByte(m);
        try w.putByte(if (d.day == null) 0 else 1);
        if (d.day) |day| try w.putByte(day);
    }
}
fn optionalValueWrite(w: *Writer, x: ?semantic.ValueId) Error!void {
    try w.putByte(if (x == null) 0 else 1);
    if (x) |id| try w.putU32(id.index);
}
fn optionalEntityWrite(w: *Writer, x: ?semantic.EntityId) Error!void {
    try w.putByte(if (x == null) 0 else 1);
    if (x) |id| try w.putU32(id.index);
}
fn optionalDocumentWrite(w: *Writer, x: ?semantic.DocumentNodeId) Error!void {
    try w.putByte(if (x == null) 0 else 1);
    if (x) |id| try w.putU32(id.index);
}
fn optionalSourceWrite(w: *Writer, x: ?semantic.SourceId) Error!void {
    try w.putByte(if (x == null) 0 else 1);
    if (x) |id| try w.putU32(id.index);
}

fn freeSourceOwned(allocator: std.mem.Allocator, source: semantic.Source) void {
    if (source.external_id) |id| allocator.free(id);
    if (source.base_uri) |uri| allocator.free(uri);
}

fn readValue(r: *Reader, a: std.mem.Allocator) Error!semantic.Value {
    return switch (try r.byte()) {
        0 => .{ .text = .{ .bytes = try a.dupe(u8, try r.slice(false)), .language = try optionalOwned(r, a, false), .script = try optionalOwned(r, a, false), .notation = try optionalOwned(r, a, false) } },
        1 => .{ .bytes = try a.dupe(u8, try r.slice(true)) },
        2 => switch (try r.byte()) {
            0 => .{ .boolean = false },
            1 => .{ .boolean = true },
            else => return Error.InvalidTag,
        },
        3 => .{ .signed_integer = try r.getI64() },
        4 => .{ .unsigned_integer = try r.getU64() },
        5 => .{ .decimal = .{ .coefficient = try r.getI64(), .scale = try r.getI32() } },
        6 => .{ .uri = try a.dupe(u8, try r.slice(false)) },
        7 => .{ .qualified_name = try readNameOwned(r, a) },
        8 => .{ .entity = .{ .index = try r.id() } },
        9 => blk: {
            const n = try r.count(r.options.max_sequence_items);
            const ids = a.alloc(semantic.ValueId, n) catch return Error.OutOfMemory;
            for (ids) |*id| id.* = .{ .index = try r.id() };
            break :blk .{ .sequence = ids };
        },
        10 => .{ .unknown = .{ .reason = try optionalOwned(r, a, false) } },
        11 => .absent,
        12 => .{ .uncertain = .{ .value = .{ .index = try r.id() }, .certainty = try enumValue(semantic.Certainty, try r.byte()) } },
        else => Error.InvalidTag,
    };
}
fn readNameOwned(r: *Reader, a: std.mem.Allocator) Error!semantic.QualifiedName {
    return .{ .namespace = .{ .index = try r.id() }, .local = try a.dupe(u8, try r.slice(false)), .prefix = try a.dupe(u8, try r.slice(false)) };
}
fn optionalOwned(r: *Reader, a: std.mem.Allocator, raw: bool) Error!?[]const u8 {
    const x = try r.optionalSlice(raw);
    return if (x) |s| a.dupe(u8, s) catch Error.OutOfMemory else null;
}
fn optionalValue(r: *Reader, n: usize) Error!?semantic.ValueId {
    return switch (try r.byte()) {
        0 => null,
        1 => blk: {
            const id = try r.id();
            if (id >= n) return Error.InvalidReference;
            break :blk .{ .index = id };
        },
        else => Error.InvalidTag,
    };
}
fn optionalDocument(r: *Reader, n: usize) Error!?semantic.DocumentNodeId {
    return switch (try r.byte()) {
        0 => null,
        1 => blk: {
            const id = try r.id();
            if (id >= n) return Error.InvalidReference;
            break :blk .{ .index = id };
        },
        else => Error.InvalidTag,
    };
}
fn optionalSource(r: *Reader, n: usize) Error!?semantic.SourceId {
    return switch (try r.byte()) {
        0 => null,
        1 => blk: {
            const id = try r.id();
            if (id >= n) return Error.InvalidReference;
            break :blk .{ .index = id };
        },
        else => Error.InvalidTag,
    };
}
fn readAttributes(r: *Reader, a: std.mem.Allocator, n: usize) Error![]semantic.Attribute {
    const xs = a.alloc(semantic.Attribute, try r.count(r.options.max_attributes)) catch return Error.OutOfMemory;
    for (xs) |*x| {
        x.* = .{ .name = try readNameOwned(r, a), .value = .{ .index = try r.id() } };
        if (x.value.index >= n) return Error.InvalidReference;
    }
    return xs;
}
fn readDocument(r: *Reader, a: std.mem.Allocator, options: DecodeOptions, sources: usize) Error!semantic.DocumentNodeOwned {
    const name = try readNameOwned(r, a);
    const source = try optionalSource(r, sources);
    const parent = try optionalDocument(r, std.math.maxInt(usize));
    const attrs = try readAttributes(r, a, std.math.maxInt(usize));
    var children: std.ArrayList(semantic.DocumentChild) = .empty;
    errdefer children.deinit(a);
    const n = try r.count(options.max_children);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const child: semantic.DocumentChild = switch (try r.byte()) {
            0 => .{ .node = .{ .index = try r.id() } },
            1 => .{ .text = .{ .index = try r.id() } },
            2 => .{ .comment = .{ .index = try r.id() } },
            3 => .{ .processing_instruction = .{ .target = try a.dupe(u8, try r.slice(false)), .data = .{ .index = try r.id() } } },
            else => return Error.InvalidTag,
        };
        children.append(a, child) catch return Error.OutOfMemory;
    }
    return .{ .name = name, .source = source, .parent = parent, .children = children, .attributes = attrs };
}
fn readAssertion(r: *Reader, a: std.mem.Allocator, entities: usize, values: usize, documents: usize, sources: usize, assertions: usize, assertion_index: usize, options: DecodeOptions) Error!semantic.Assertion {
    const predicate = try r.id();
    if (predicate >= entities) return Error.InvalidReference;
    const source = try optionalSource(r, sources);
    const ps = a.alloc(semantic.Participant, try r.count(options.max_participants)) catch return Error.OutOfMemory;
    if (ps.len < 2) return Error.InvalidCardinality;
    for (ps) |*p| {
        p.* = .{ .role = try a.dupe(u8, try r.slice(false)), .target = switch (try r.byte()) {
            0 => blk: {
                const id = try r.id();
                if (id >= entities) return Error.InvalidReference;
                break :blk .{ .entity = .{ .index = id } };
            },
            1 => blk: {
                const id = try r.id();
                if (id >= values) return Error.InvalidReference;
                break :blk .{ .value = .{ .index = id } };
            },
            3 => blk: {
                const id = try r.id();
                if (id >= assertions or id >= assertion_index) return Error.InvalidStatementReference;
                break :blk .{ .statement = .{ .index = id } };
            },
            2 => .{ .unresolved = .{ .bytes = try a.dupe(u8, try r.slice(true)), .uri = try optionalOwned(r, a, false), .label = try optionalOwned(r, a, false), .status = try enumValue(semantic.ResolutionStatus, try r.byte()) } },
            else => return Error.InvalidTag,
        } };
    }
    const attrs = try readAttributes(r, a, values);
    const evidence = a.alloc(semantic.Evidence, try r.count(options.max_evidence)) catch return Error.OutOfMemory;
    for (evidence) |*e| e.* = .{ .source = try optionalEntity(r, entities), .document = try optionalDocument(r, documents), .quote = try optionalValue(r, values), .provenance = try optionalValue(r, values), .attributes = try readAttributes(r, a, values) };
    const state = try enumValue(semantic.AssertionState, try r.byte());
    const certainty = try enumValue(semantic.Certainty, try r.byte());
    const temporal = try readTemporal(r);
    const context = try readContext(r, entities, documents);
    return .{ .predicate = .{ .index = predicate }, .participants = ps, .attributes = attrs, .evidence = evidence, .state = state, .certainty = certainty, .temporal = temporal, .context = context, .source = source };
}
fn readAnchor(r: *Reader, sources: usize, documents: usize) Error!semantic.SourceAnchor {
    const source = try r.id();
    if (source >= sources) return Error.InvalidReference;
    const node = try r.id();
    if (node >= documents) return Error.InvalidReference;
    const span: ?semantic.SourceSpan = switch (try r.byte()) {
        0 => null,
        1 => .{ .unit = try enumValue(semantic.SourceSpanUnit, try r.byte()), .start = try r.getU64(), .end = try r.getU64() },
        else => return Error.InvalidTag,
    };
    if (span) |x| if (x.start > x.end) return Error.InvalidDocument;
    return .{ .source = .{ .index = source }, .node = .{ .index = node }, .span = span };
}
fn readContext(r: *Reader, entities: usize, documents: usize) Error!semantic.GraphContext {
    return switch (try r.byte()) {
        0 => .default,
        1 => blk: {
            const id = try r.id();
            if (id >= entities) return Error.InvalidReference;
            break :blk .{ .named = .{ .index = id } };
        },
        2 => blk: {
            const has_source = switch (try r.byte()) {
                0 => false,
                1 => true,
                else => return Error.InvalidTag,
            };
            const source: ?semantic.ContextSource = if (has_source) switch (try r.byte()) {
                0 => blk2: {
                    const id = try r.id();
                    if (id >= entities) return Error.InvalidReference;
                    break :blk2 .{ .entity = .{ .index = id } };
                },
                1 => blk2: {
                    const id = try r.id();
                    if (id >= documents) return Error.InvalidReference;
                    break :blk2 .{ .document = .{ .index = id } };
                },
                else => return Error.InvalidTag,
            } else null;
            break :blk .{ .anonymous = .{ .source = source, .id = try r.getU64() } };
        },
        else => Error.InvalidTag,
    };
}
fn optionalEntity(r: *Reader, n: usize) Error!?semantic.EntityId {
    return switch (try r.byte()) {
        0 => null,
        1 => blk: {
            const x = try r.id();
            if (x >= n) return Error.InvalidReference;
            break :blk .{ .index = x };
        },
        else => Error.InvalidTag,
    };
}
fn readTemporal(r: *Reader) Error!?semantic.Temporal {
    return switch (try r.byte()) {
        0 => null,
        1 => .{ .start = try readDate(r), .end = try readDate(r), .precision = switch (try r.byte()) {
            0 => null,
            1 => try enumValue(semantic.TemporalPrecision, try r.byte()),
            else => return Error.InvalidTag,
        } },
        else => Error.InvalidTag,
    };
}
fn readDate(r: *Reader) Error!?semantic.Date {
    return switch (try r.byte()) {
        0 => null,
        1 => blk: {
            const year = try r.getI32();
            const month = switch (try r.byte()) {
                0 => null,
                1 => try r.byte(),
                else => return Error.InvalidTag,
            };
            const day = switch (try r.byte()) {
                0 => null,
                1 => try r.byte(),
                else => return Error.InvalidTag,
            };
            break :blk .{ .year = year, .month = month, .day = day };
        },
        else => Error.InvalidTag,
    };
}
fn enumValue(comptime E: type, x: u8) Error!E {
    return std.enums.fromInt(E, x) orelse Error.InvalidTag;
}

fn mapSemantic(e: anyerror) Error {
    return switch (e) {
        error.InvalidReference => Error.InvalidReference,
        error.InvalidNamespace => Error.InvalidNamespace,
        error.InvalidName => Error.InvalidName,
        error.InvalidUtf8 => Error.InvalidUtf8,
        error.InvalidUri => Error.InvalidUri,
        error.InvalidExternalId => Error.InvalidExternalId,
        error.InvalidDate => Error.InvalidDate,
        error.InvalidTemporalRange => Error.InvalidTemporalRange,
        error.DocumentDepthExceeded => Error.ResourceLimit,
        error.InvalidCardinality => Error.InvalidCardinality,
        error.InvalidAssertion => Error.InvalidAssertion,
        error.InvalidStatementReference => Error.InvalidStatementReference,
        error.InvalidDocument => Error.InvalidDocument,
        error.DocumentCycle => Error.DocumentCycle,
        error.DocumentMultipleParent => Error.DocumentMultipleParent,
        error.DuplicateRoot => Error.DuplicateRoot,
        error.DuplicateChild => Error.DuplicateChild,
        error.OutOfMemory => Error.OutOfMemory,
        else => Error.InvalidLength,
    };
}
fn checksum(xs: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (xs) |x| {
        h ^= x;
        h *%= 0x100000001b3;
    }
    return h;
}

fn validateModel(m: *const semantic.Model) Error!void {
    for (m.namespaces) |x| {
        try validUtf8(x.uri);
        try validUtf8(x.prefix);
    }
    for (m.sources) |x| {
        if (x.external_id) |id| {
            if (id.len == 0) return Error.InvalidExternalId;
            try validUtf8(id);
        }
        if (x.base_uri) |uri| try validUri(uri);
    }
    for (m.values) |x| switch (x) {
        .text => |v| {
            try validUtf8(v.bytes);
            if (v.language) |s| try validUtf8(s);
            if (v.script) |s| try validUtf8(s);
            if (v.notation) |s| try validUtf8(s);
        },
        .bytes, .boolean, .signed_integer, .unsigned_integer, .decimal, .absent => {},
        .uri => |s| try validUri(s),
        .qualified_name => |qn| try validName(m, qn),
        .entity => |id| try validEntity(m, id),
        .sequence => |ids| for (ids) |id| try validValue(m, id),
        .unknown => |v| if (v.reason) |s| try validUtf8(s),
        .uncertain => |v| try validValue(m, v.value),
    };
    for (m.entities) |x| {
        if (x.external_id) |s| {
            if (s.len == 0) return Error.InvalidLength;
            try validUtf8(s);
        }
        if (x.label) |id| try validValue(m, id);
        if (x.source) |source| try validSource(m, source);
    }
    for (m.documents) |x| {
        try validName(m, x.name);
        if (x.source) |source| try validSource(m, source);
        if (x.parent) |id| try validDocument(m, id);
        try validAttributes(m, x.attributes);
        for (x.children.items) |c| switch (c) {
            .node => |id| try validDocument(m, id),
            .text, .comment => |id| try validValue(m, id),
            .processing_instruction => |pi| {
                try validUtf8(pi.target);
                try validValue(m, pi.data);
            },
        };
    }
    for (m.assertions, 0..) |x, assertion_index| {
        try validEntity(m, x.predicate);
        if (x.participants.len < 2) return Error.InvalidCardinality;
        for (x.participants) |p| {
            try validUtf8(p.role);
            switch (p.target) {
                .entity => |id| try validEntity(m, id),
                .value => |id| try validValue(m, id),
                .statement => |id| if (id.index >= assertion_index) return Error.InvalidStatementReference,
                .unresolved => |u| {
                    if (u.uri) |s| try validUri(s);
                    if (u.label) |s| try validUtf8(s);
                },
            }
        }
        try validAttributes(m, x.attributes);
        for (x.evidence) |e| {
            if (e.source) |id| try validEntity(m, id);
            if (e.document) |id| try validDocument(m, id);
            if (e.quote) |id| try validValue(m, id);
            if (e.provenance) |id| try validValue(m, id);
            try validAttributes(m, e.attributes);
        }
        if (x.temporal) |temporal| try validTemporal(temporal);
        try validContext(m, x.context);
        if (x.source) |source| try validSource(m, source);
    }
    for (m.entity_anchors) |mapping| {
        try validEntity(m, mapping.entity);
        try validAnchor(m, mapping.anchor);
    }
    for (m.assertion_anchors) |mapping| {
        if (mapping.assertion.index >= m.assertions.len) return Error.InvalidReference;
        try validAnchor(m, mapping.anchor);
    }
    for (m.roots) |id| try validDocument(m, id);
}
fn validContext(m: *const semantic.Model, context: semantic.GraphContext) Error!void {
    switch (context) {
        .default => {},
        .named => |id| try validEntity(m, id),
        .anonymous => |anonymous| if (anonymous.source) |source| switch (source) {
            .entity => |id| try validEntity(m, id),
            .document => |id| try validDocument(m, id),
        },
    }
}
fn validUtf8(x: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(x)) return Error.InvalidUtf8;
}
fn validUri(x: []const u8) Error!void {
    try validUtf8(x);
    if (x.len == 0) return Error.InvalidUri;
    for (x, 0..) |b, i| if (b < 0x20 or b == 0x7f or b == ' ' or b == '\t' or b == '\n' or b == '\r' or (b == '%' and (i + 2 >= x.len or hexDigit(x[i + 1]) == null or hexDigit(x[i + 2]) == null))) return Error.InvalidUri;
}
fn hexDigit(x: u8) ?u8 {
    return switch (x) {
        '0'...'9' => x - '0',
        'a'...'f' => x - 'a' + 10,
        'A'...'F' => x - 'A' + 10,
        else => null,
    };
}
fn validName(m: *const semantic.Model, x: semantic.QualifiedName) Error!void {
    if (x.namespace.index >= m.namespaces.len or x.local.len == 0) return Error.InvalidReference;
    try validUtf8(x.local);
    try validUtf8(x.prefix);
}
fn validAttributes(m: *const semantic.Model, xs: []const semantic.Attribute) Error!void {
    for (xs) |x| {
        try validName(m, x.name);
        try validValue(m, x.value);
    }
}
fn validValue(m: *const semantic.Model, id: semantic.ValueId) Error!void {
    if (id.index >= m.values.len) return Error.InvalidReference;
}
fn validEntity(m: *const semantic.Model, id: semantic.EntityId) Error!void {
    if (id.index >= m.entities.len) return Error.InvalidReference;
}
fn validSource(m: *const semantic.Model, id: semantic.SourceId) Error!void {
    if (id.index >= m.sources.len) return Error.InvalidReference;
}
fn validDocument(m: *const semantic.Model, id: semantic.DocumentNodeId) Error!void {
    if (id.index >= m.documents.len) return Error.InvalidReference;
}
fn validAnchor(m: *const semantic.Model, anchor: semantic.SourceAnchor) Error!void {
    try validSource(m, anchor.source);
    try validDocument(m, anchor.node);
    if (m.documents[anchor.node.index].source) |source| if (source.index != anchor.source.index) return Error.InvalidDocument;
    if (anchor.span) |span| if (span.start > span.end) return Error.InvalidDocument;
}

fn validTemporal(t: semantic.Temporal) Error!void {
    if (t.start) |d| try validDate(d);
    if (t.end) |d| try validDate(d);
    if (t.start != null and t.end != null) {
        const a = t.start.?;
        const b = t.end.?;
        if (a.year > b.year or (a.year == b.year and (a.month orelse 0) > (b.month orelse 0)) or (a.year == b.year and (a.month orelse 0) == (b.month orelse 0) and (a.day orelse 0) > (b.day orelse 0))) return Error.InvalidTemporalRange;
    }
    if (t.precision) |precision| {
        if (t.start == null and t.end == null) return Error.InvalidDate;
        for ([_]?semantic.Date{ t.start, t.end }) |maybe| if (maybe) |d| switch (precision) {
            .exact, .day => if (d.month == null or d.day == null) return Error.InvalidDate,
            .month => if (d.month == null or d.day != null) return Error.InvalidDate,
            .year => if (d.month != null or d.day != null) return Error.InvalidDate,
            .approximate, .unknown => {},
        };
    }
}

fn validDate(d: semantic.Date) Error!void {
    if (d.month) |m| if (m == 0 or m > 12) return Error.InvalidDate;
    if (d.day) |day| {
        const month = d.month orelse return Error.InvalidDate;
        const leap = @mod(d.year, 4) == 0 and (@mod(d.year, 100) != 0 or @mod(d.year, 400) == 0);
        const limit: u8 = switch (month) {
            2 => if (leap) 29 else 28,
            4, 6, 9, 11 => 30,
            else => 31,
        };
        if (day == 0 or day > limit) return Error.InvalidDate;
    }
}

test "semantic snapshot is deterministic and round trips documents, evidence, raw bytes and absent" {
    var b = semantic.Builder.init(std.testing.allocator);
    defer b.deinit();
    const ns = try b.addNamespace("urn:tei", "tei");
    const linked = try b.addEntity(.{ .kind = .other });
    const text = try b.addValue(.{ .text = .{ .bytes = "bank", .language = "en" } });
    const raw = try b.addValue(.{ .bytes = &.{ 0, 0xff, 1 } });
    const absent = try b.addValue(.absent);
    const unknown = try b.addValue(.{ .unknown = .{ .reason = "withheld" } });
    const boolean = try b.addValue(.{ .boolean = true });
    const signed = try b.addValue(.{ .signed_integer = -42 });
    const unsigned = try b.addValue(.{ .unsigned_integer = 42 });
    const decimal = try b.addValue(.{ .decimal = .{ .coefficient = 12345, .scale = 3 } });
    const uri_value = try b.addValue(.{ .uri = "urn:value" });
    const qualified = try b.addValue(.{ .qualified_name = .{ .namespace = ns, .local = "term", .prefix = "tei" } });
    const sequence = try b.addValue(.{ .sequence = &.{ text, boolean, signed } });
    const uncertain = try b.addValue(.{ .uncertain = .{ .value = boolean, .certainty = .probable } });
    const entity_value = try b.addValue(.{ .entity = linked });
    _ = unsigned;
    _ = decimal;
    _ = uri_value;
    _ = qualified;
    _ = sequence;
    _ = uncertain;
    _ = entity_value;
    const source = try b.addEntity(.{ .kind = .source });
    const pred = try b.addEntity(.{ .kind = .other });
    const left = try b.addEntity(.{ .kind = .sense });
    const root = try b.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "entry" } });
    const child = try b.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "form" } });
    try b.appendChild(root, .{ .text = text });
    try b.appendChild(root, .{ .comment = unknown });
    try b.appendChild(root, .{ .node = child });
    try b.appendChild(root, .{ .processing_instruction = .{ .target = "xml", .data = absent } });
    try b.addDocumentRoot(root);
    _ = try b.addAssertion(.{ .predicate = pred, .participants = &.{ .{ .role = "source", .target = .{ .entity = left } }, .{ .role = "target", .target = .{ .unresolved = .{ .bytes = "banque" } } } }, .attributes = &.{.{ .name = .{ .namespace = ns, .local = "x" }, .value = absent }}, .evidence = &.{.{ .source = source, .document = root, .quote = text }}, .state = .asserted, .certainty = .certain });
    _ = try b.addAssertion(.{ .predicate = pred, .participants = &.{ .{ .role = "source", .target = .{ .entity = left } }, .{ .role = "target", .target = .{ .value = text } } }, .attributes = &.{}, .evidence = &.{}, .state = .retracted, .certainty = .possible });
    var m = try b.build();
    defer m.deinit();
    const a = try encode(std.testing.allocator, &m);
    defer std.testing.allocator.free(a);
    const c = try encode(std.testing.allocator, &m);
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualSlices(u8, a, c);
    var d = try decode(std.testing.allocator, a, .{});
    defer d.deinit();
    try std.testing.expectEqual(m.documents.len, d.documents.len);
    try std.testing.expectEqual(m.assertions.len, d.assertions.len);
    try std.testing.expectEqualSlices(u8, m.values[raw.index].bytes, d.values[raw.index].bytes);
    try std.testing.expect(d.values[absent.index] == .absent);
    try std.testing.expectEqual(@as(usize, 4), d.documents[0].children.items.len);
    try std.testing.expectEqual(@as(usize, 1), d.assertions[0].evidence.len);
    try std.testing.expectEqual(@as(usize, 2), d.assertions.len);
    try std.testing.expect(d.values[unknown.index] == .unknown);
    const roundtrip = try encode(std.testing.allocator, &d);
    defer std.testing.allocator.free(roundtrip);
    try std.testing.expectEqualSlices(u8, a, roundtrip);
}

test "semantic snapshot distinguishes truncation, corruption, and resource budget" {
    var b = semantic.Builder.init(std.testing.allocator);
    defer b.deinit();
    _ = try b.addValue(.{ .text = .{ .bytes = "x" } });
    var m = try b.build();
    defer m.deinit();
    const bytes = try encode(std.testing.allocator, &m);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(Error.Truncated, decode(std.testing.allocator, bytes[0 .. bytes.len - 1], .{}));
    var bad = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(bad);
    bad[header_bytes] ^= 1;
    try std.testing.expectError(Error.InvalidChecksum, decode(std.testing.allocator, bad, .{}));
    var invalid_tag = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(invalid_tag);
    // Empty namespace/source sections (8 bytes each), value count (8 bytes), then value tag.
    invalid_tag[136] = 0xff;
    std.mem.writeInt(u64, invalid_tag[28..36], checksum(invalid_tag[header_bytes..]), .little);
    try std.testing.expectError(Error.InvalidTag, decode(std.testing.allocator, invalid_tag, .{}));
    try std.testing.expectError(Error.ResourceLimit, decode(std.testing.allocator, bytes, .{ .max_total_bytes = bytes.len - 1 }));
    var old_version = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(old_version);
    std.mem.writeInt(u16, old_version[10..12], 1, .little);
    try std.testing.expectError(Error.UnsupportedVersion, decode(std.testing.allocator, old_version, .{}));
}

test "v0.2 preserves nested quoted statements and graph contexts exactly" {
    var b = semantic.Builder.init(std.testing.allocator);
    defer b.deinit();
    const predicate = try b.addEntity(.{ .kind = .other, .external_id = "predicate" });
    const source = try b.addEntity(.{ .kind = .source, .external_id = "source" });
    const left = try b.addEntity(.{ .kind = .sense, .external_id = "left" });
    const right = try b.addEntity(.{ .kind = .sense, .external_id = "right" });
    const base = try b.addAssertion(.{ .predicate = predicate, .participants = &.{ .{ .role = "subject", .target = .{ .entity = left } }, .{ .role = "object", .target = .{ .entity = right } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain });
    const quoted = try b.addAssertion(.{ .predicate = predicate, .participants = &.{ .{ .role = "subject", .target = .{ .statement = base } }, .{ .role = "object", .target = .{ .entity = right } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .probable, .context = .{ .named = source } });
    _ = try b.addAssertion(.{ .predicate = predicate, .participants = &.{ .{ .role = "subject", .target = .{ .statement = quoted } }, .{ .role = "object", .target = .{ .entity = right } } }, .attributes = &.{}, .evidence = &.{}, .state = .retracted, .certainty = .certain, .context = .{ .anonymous = .{ .source = .{ .entity = source }, .id = 42 } } });
    var model = try b.build();
    defer model.deinit();
    const encoded = try encode(std.testing.allocator, &model);
    defer std.testing.allocator.free(encoded);
    var decoded = try decode(std.testing.allocator, encoded, .{});
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 3), decoded.assertions.len);
    try std.testing.expectEqual(@as(u32, 0), decoded.assertions[1].participants[0].target.statement.index);
    try std.testing.expectEqual(@as(u32, 1), decoded.assertions[2].participants[0].target.statement.index);
    try std.testing.expect(decoded.assertions[0].context == .default);
    try std.testing.expect(decoded.assertions[1].context == .named);
    try std.testing.expect(decoded.assertions[2].context == .anonymous);
    try std.testing.expectEqual(@as(u64, 42), decoded.assertions[2].context.anonymous.id);
    const reencoded = try encode(std.testing.allocator, &decoded);
    defer std.testing.allocator.free(reencoded);
    try std.testing.expectEqualSlices(u8, encoded, reencoded);
}

test "v0.3 preserves source scoped identities and typed occurrence anchors" {
    var b = semantic.Builder.init(std.testing.allocator);
    defer b.deinit();
    const ns = try b.addNamespace("urn:tei", "tei");
    const source_a = try b.addSource(.{ .external_id = "same.xml", .base_uri = "https://example.test/a/" });
    const source_b = try b.addSource(.{ .external_id = "same.xml", .base_uri = "https://example.test/b/" });
    try std.testing.expect(source_a.index != source_b.index);
    const same_form = try b.addValue(.{ .text = .{ .bytes = "bank", .language = "en" } });
    const predicate = try b.addEntity(.{ .kind = .other, .external_id = "lexicalizes" });
    const entry_a = try b.addEntity(.{ .kind = .entry, .external_id = "entry", .source = source_a });
    const entry_b = try b.addEntity(.{ .kind = .entry, .external_id = "entry", .source = source_b });
    const sense_a = try b.addEntity(.{ .kind = .sense, .external_id = "sense", .source = source_a, .label = same_form });
    const form_b = try b.addEntity(.{ .kind = .form, .external_id = "form", .source = source_b, .label = same_form });
    const root_a = try b.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "entry", .prefix = "tei" }, .source = source_a });
    const node_a = try b.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "sense", .prefix = "tei" }, .source = source_a, .parent = root_a });
    const root_b = try b.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "entry", .prefix = "tei" }, .source = source_b });
    const node_b = try b.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "form", .prefix = "tei" }, .source = source_b, .parent = root_b });
    try b.addDocumentRoot(root_a);
    try b.addDocumentRoot(root_b);
    try b.addEntityAnchor(entry_a, .{ .source = source_a, .node = root_a, .span = .{ .unit = .byte, .start = 4, .end = 9 } });
    try b.addEntityAnchor(sense_a, .{ .source = source_a, .node = node_a, .span = .{ .unit = .utf8_codepoint, .start = 12, .end = 16 } });
    try b.addEntityAnchor(form_b, .{ .source = source_b, .node = node_b, .span = .{ .unit = .grapheme, .start = 0, .end = 1 } });
    const assertion_a = try b.addAssertion(.{
        .predicate = predicate,
        .participants = &.{ .{ .role = "entry", .target = .{ .entity = entry_a } }, .{ .role = "sense", .target = .{ .entity = sense_a } } },
        .attributes = &.{},
        .evidence = &.{.{ .source = entry_a, .document = node_a, .quote = same_form }},
        .state = .asserted,
        .certainty = .certain,
        .source = source_a,
    });
    const assertion_b = try b.addAssertion(.{
        .predicate = predicate,
        .participants = &.{ .{ .role = "entry", .target = .{ .entity = entry_b } }, .{ .role = "form", .target = .{ .entity = form_b } } },
        .attributes = &.{},
        .evidence = &.{.{ .source = entry_b, .document = node_b, .quote = same_form }},
        .state = .asserted,
        .certainty = .certain,
        .source = source_b,
    });
    try b.addAssertionAnchor(assertion_a, .{ .source = source_a, .node = node_a, .span = .{ .unit = .utf16_code_unit, .start = 20, .end = 25 } });
    try b.addAssertionAnchor(assertion_b, .{ .source = source_b, .node = node_b, .span = .{ .unit = .byte, .start = 30, .end = 35 } });
    var model = try b.build();
    defer model.deinit();
    const encoded = try encode(std.testing.allocator, &model);
    defer std.testing.allocator.free(encoded);
    var decoded = try decode(std.testing.allocator, encoded, .{});
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 2), decoded.sources.len);
    try std.testing.expectEqualStrings("same.xml", decoded.sources[0].external_id.?);
    try std.testing.expectEqualStrings("https://example.test/b/", decoded.sources[1].base_uri.?);
    try std.testing.expectEqual(@as(usize, 3), decoded.entity_anchors.len);
    try std.testing.expectEqual(@as(usize, 2), decoded.assertion_anchors.len);
    try std.testing.expectEqual(@as(u32, source_a.index), decoded.entities[entry_a.index].source.?.index);
    try std.testing.expectEqual(@as(u32, source_b.index), decoded.entities[entry_b.index].source.?.index);
    try std.testing.expectEqual(semantic.SourceSpanUnit.utf16_code_unit, decoded.assertion_anchors[0].anchor.span.?.unit);
    const reencoded = try encode(std.testing.allocator, &decoded);
    defer std.testing.allocator.free(reencoded);
    try std.testing.expectEqualSlices(u8, encoded, reencoded);
}
