//! Optional ordered, namespaced source occurrences.
//!
//! Decoded UTF-8 values are interned once in the canonical grammar. Generated
//! scalar tables hold cumulative span ends, names and event operands. Document
//! content is the leading span; each element owns the next span, eliminating
//! redundant owner columns while retaining exact mixed-content order.

const std = @import("std");
const grammar = @import("grammar.zig");
const schema = @import("schema.zig");
const table = @import("table.zig");
const wire = @import("wire.zig");

pub const Error = wire.Error || grammar.Error || table.Error || error{
    BadMagic,
    UnsupportedVersion,
    InvalidFormat,
    InvalidOccurrence,
    InvalidParent,
    InvalidContent,
    InvalidName,
    DuplicateSourceId,
    OutputTooSmall,
    DepthExceeded,
};
pub const OccurrenceId = enum(u32) { _ };
pub const StringId = enum(u32) { _ };
pub const ExpandedNameInput = struct { namespace_uri: []const u8, local_name: []const u8, prefix: ?[]const u8 = null };
pub const NamespaceInput = struct { prefix: ?[]const u8 = null, uri: []const u8 };
pub const AttributeInput = struct { name: ExpandedNameInput, value: []const u8 };
pub const SemanticBinding = schema.Reference;
pub const ContentInput = union(enum) {
    text: []const u8,
    child: OccurrenceId,
    comment: []const u8,
    processing_instruction: struct { target: []const u8, data: []const u8 },
};
pub const ElementInput = struct {
    parent: ?OccurrenceId,
    name: ExpandedNameInput,
    namespaces: []const NamespaceInput = &.{},
    attributes: []const AttributeInput = &.{},
    content: []const ContentInput = &.{},
    semantic: ?SemanticBinding = null,
};
pub const DocumentInput = struct { elements: []const ElementInput, content: []const ContentInput };

pub const Span = struct {
    start: u32,
    end: u32,
    pub fn len(self: Span) u32 {
        return self.end - self.start;
    }
};
pub const Name = struct { namespace_uri: StringId, local_name: StringId, prefix: ?StringId };
pub const Binding = schema.Reference;
pub const Element = struct {
    id: OccurrenceId,
    parent: ?OccurrenceId,
    name: Name,
    namespaces: Span,
    attributes: Span,
    content: Span,
    semantic: ?Binding,
};
pub const Attribute = struct { name: Name, value: StringId };
pub const Namespace = struct { prefix: StringId, uri: StringId };
pub const Content = union(enum) {
    text: StringId,
    child: OccurrenceId,
    comment: StringId,
    processing_instruction: struct { target: StringId, data: StringId },
};
/// Absent is `{null,null}`; an explicit empty xml:lang retains its value ID and owner.
pub const LanguageScope = struct { value: ?StringId, owner: ?OccurrenceId };

pub const xml_namespace = "http://www.w3.org/XML/1998/namespace";
const magic = "L4RC";
const version: u16 = 2;
const Header = struct {
    magic: [4]u8,
    version: u16,
    flags: u16,
    element_count: u32,
    attribute_count: u32,
    namespace_count: u32,
    content_count: u32,
    string_count: u32,
    document_content_end: u32,
    elements_at: u64,
    elements_len: u64,
    attributes_at: u64,
    attributes_len: u64,
    namespaces_at: u64,
    namespaces_len: u64,
    content_at: u64,
    content_len: u64,
    strings_at: u64,
    strings_len: u64,
    total_len: u64,
};
const HeaderWire = wire.Layout(Header);
pub const header_size = HeaderWire.size;
const NameRow = struct { namespace_uri: u32, local_name: u32, prefix: ?u32 };
const ElementRow = struct {
    parent: ?u32,
    name: NameRow,
    namespace_end: u32,
    attribute_end: u32,
    content_end: u32,
    subtree_end: u32,
    semantic: ?schema.Reference,
};
const AttributeRow = struct { name: NameRow, value: u32 };
const NamespaceRow = struct { prefix: u32, uri: u32 };
const ContentTag = enum(u8) { text, child, comment, processing_instruction };
const ContentRow = struct { tag: ContentTag, first: u32, second: ?u32 };
const ElementTable = table.Table(ElementRow);
const AttributeTable = table.Table(AttributeRow);
const NamespaceTable = table.Table(NamespaceRow);
const ContentTable = table.Table(ContentRow);

const Pool = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(u32),
    items: std.ArrayList(grammar.ItemInput),
    fn init(allocator: std.mem.Allocator) Pool {
        return .{ .allocator = allocator, .map = .init(allocator), .items = .empty };
    }
    fn deinit(self: *Pool) void {
        self.map.deinit();
        self.items.deinit(self.allocator);
    }
    fn intern(self: *Pool, value: []const u8) Error!u32 {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidFormat;
        if (self.map.get(value)) |id| return id;
        const id = std.math.cast(u32, self.items.items.len) orelse return error.Overflow;
        self.items.append(self.allocator, .{ .text = value }) catch return error.OutOfMemory;
        self.map.put(value, id) catch return error.OutOfMemory;
        return id;
    }
    fn name(self: *Pool, input: ExpandedNameInput) Error!NameRow {
        if (input.local_name.len == 0) return error.InvalidName;
        return .{ .namespace_uri = try self.intern(input.namespace_uri), .local_name = try self.intern(input.local_name), .prefix = if (input.prefix) |prefix| try self.intern(prefix) else null };
    }
};

pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
    pub fn view(self: *const Owned, limits: grammar.Limits) Error!View {
        return View.open(self.bytes, limits);
    }
};

fn addEvent(pool: *Pool, rows: *std.ArrayList(ContentRow), allocator: std.mem.Allocator, input: ContentInput) Error!void {
    const row: ContentRow = switch (input) {
        .text => |value| .{ .tag = .text, .first = try pool.intern(value), .second = null },
        .comment => |value| .{ .tag = .comment, .first = try pool.intern(value), .second = null },
        .child => |id| .{ .tag = .child, .first = @intFromEnum(id), .second = null },
        .processing_instruction => |pi| .{ .tag = .processing_instruction, .first = try pool.intern(pi.target), .second = try pool.intern(pi.data) },
    };
    rows.append(allocator, row) catch return error.OutOfMemory;
}

pub fn build(allocator: std.mem.Allocator, document: DocumentInput, options: grammar.Options) Error!Owned {
    if (document.elements.len == 0 or document.elements.len > std.math.maxInt(u32)) return error.InvalidOccurrence;
    var pool = Pool.init(allocator);
    defer pool.deinit();
    if (try pool.intern("") != 0) unreachable;
    var elements = std.ArrayList(ElementRow).empty;
    defer elements.deinit(allocator);
    var attributes = std.ArrayList(AttributeRow).empty;
    defer attributes.deinit(allocator);
    var namespaces = std.ArrayList(NamespaceRow).empty;
    defer namespaces.deinit(allocator);
    var content = std.ArrayList(ContentRow).empty;
    defer content.deinit(allocator);
    for (document.content) |event| try addEvent(&pool, &content, allocator, event);
    const document_end = std.math.cast(u32, content.items.len) orelse return error.Overflow;
    const subtree_ends = allocator.alloc(u32, document.elements.len) catch return error.OutOfMemory;
    defer allocator.free(subtree_ends);
    for (subtree_ends, 0..) |*end, index| end.* = @intCast(index + 1);
    var reverse = document.elements.len;
    while (reverse != 0) {
        reverse -= 1;
        if (document.elements[reverse].parent) |parent_id| {
            const parent = @intFromEnum(parent_id);
            if (parent >= reverse) return error.InvalidParent;
            subtree_ends[parent] = @max(subtree_ends[parent], subtree_ends[reverse]);
        }
    }
    for (document.elements, 0..) |element, index| {
        if (element.semantic) |binding| binding.validate() catch return error.InvalidOccurrence;
        const parent = if (element.parent) |id| @intFromEnum(id) else null;
        if (parent) |id| if (id >= index) return error.InvalidParent;
        for (element.namespaces) |namespace| namespaces.append(allocator, .{
            .prefix = if (namespace.prefix) |prefix| try pool.intern(prefix) else 0,
            .uri = try pool.intern(namespace.uri),
        }) catch return error.OutOfMemory;
        for (element.attributes) |attribute| attributes.append(allocator, .{
            .name = try pool.name(attribute.name),
            .value = try pool.intern(attribute.value),
        }) catch return error.OutOfMemory;
        for (element.content) |event| try addEvent(&pool, &content, allocator, event);
        elements.append(allocator, .{
            .parent = parent,
            .name = try pool.name(element.name),
            .namespace_end = std.math.cast(u32, namespaces.items.len) orelse return error.Overflow,
            .attribute_end = std.math.cast(u32, attributes.items.len) orelse return error.Overflow,
            .content_end = std.math.cast(u32, content.items.len) orelse return error.Overflow,
            .subtree_end = subtree_ends[index],
            .semantic = element.semantic,
        }) catch return error.OutOfMemory;
    }
    var element_table = try ElementTable.build(allocator, elements.items);
    defer element_table.deinit();
    var attribute_table = try AttributeTable.build(allocator, attributes.items);
    defer attribute_table.deinit();
    var namespace_table = try NamespaceTable.build(allocator, namespaces.items);
    defer namespace_table.deinit();
    var content_table = try ContentTable.build(allocator, content.items);
    defer content_table.deinit();
    var string_owner = try grammar.build(allocator, pool.items.items, options);
    defer string_owner.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendNTimes(allocator, 0, header_size);
    const elements_at = out.items.len;
    try out.appendSlice(allocator, element_table.bytes);
    const attributes_at = out.items.len;
    try out.appendSlice(allocator, attribute_table.bytes);
    const namespaces_at = out.items.len;
    try out.appendSlice(allocator, namespace_table.bytes);
    const content_at = out.items.len;
    try out.appendSlice(allocator, content_table.bytes);
    const strings_at = out.items.len;
    try out.appendSlice(allocator, string_owner.bytes);
    try HeaderWire.write(out.items, 0, .{
        .magic = magic.*,
        .version = version,
        .flags = 0,
        .element_count = @intCast(elements.items.len),
        .attribute_count = @intCast(attributes.items.len),
        .namespace_count = @intCast(namespaces.items.len),
        .content_count = @intCast(content.items.len),
        .string_count = @intCast(pool.items.items.len),
        .document_content_end = document_end,
        .elements_at = elements_at,
        .elements_len = element_table.bytes.len,
        .attributes_at = attributes_at,
        .attributes_len = attribute_table.bytes.len,
        .namespaces_at = namespaces_at,
        .namespaces_len = namespace_table.bytes.len,
        .content_at = content_at,
        .content_len = content_table.bytes.len,
        .strings_at = strings_at,
        .strings_len = string_owner.bytes.len,
        .total_len = out.items.len,
    });
    const bytes = out.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer allocator.free(bytes);
    var view = try View.open(bytes, .{
        .max_items = options.max_items,
        .max_rules = options.max_rules,
        .max_symbols = options.max_symbols,
        .max_output_bytes = options.max_output_bytes,
        .max_item_output_bytes = options.max_item_output_bytes,
        .max_total_output_bytes = options.max_total_output_bytes,
        .max_rule_expansion_bytes = options.max_rule_expansion_bytes,
        .max_expansion_steps = options.max_expansion_steps,
    });
    try view.verify(allocator);
    return .{ .allocator = allocator, .bytes = bytes };
}

fn stringId(raw: u32, count: u32) Error!StringId {
    if (raw >= count) return error.InvalidContent;
    return @enumFromInt(raw);
}
fn nameValue(raw: NameRow, count: u32) Error!Name {
    return .{ .namespace_uri = try stringId(raw.namespace_uri, count), .local_name = try stringId(raw.local_name, count), .prefix = if (raw.prefix) |prefix| try stringId(prefix, count) else null };
}

pub const View = struct {
    bytes: []const u8,
    element_count: u32,
    attribute_count: u32,
    namespace_count: u32,
    content_count: u32,
    string_count: u32,
    document_content_end: u32,
    elements: ElementTable.View,
    attributes: AttributeTable.View,
    namespace_rows: NamespaceTable.View,
    content_rows: ContentTable.View,
    strings: grammar.View,
    verified: bool = false,

    fn take(bytes: []const u8, cursor: *usize, raw_at: u64, raw_len: u64) Error![]const u8 {
        const at = try wire.cast(usize, raw_at);
        const len = try wire.cast(usize, raw_len);
        if (at != cursor.*) return error.InvalidFormat;
        const result = try wire.bytesAt(bytes, at, len);
        cursor.* = try wire.add(at, len);
        return result;
    }
    pub fn open(bytes: []const u8, limits: grammar.Limits) Error!View {
        const header = try HeaderWire.read(bytes, 0);
        if (!std.mem.eql(u8, &header.magic, magic)) return error.BadMagic;
        if (header.version != version) return error.UnsupportedVersion;
        if (header.flags != 0 or header.element_count == 0 or header.total_len != bytes.len or header.document_content_end > header.content_count) return error.InvalidFormat;
        var cursor: usize = header_size;
        const element_bytes = try take(bytes, &cursor, header.elements_at, header.elements_len);
        const attribute_bytes = try take(bytes, &cursor, header.attributes_at, header.attributes_len);
        const namespace_bytes = try take(bytes, &cursor, header.namespaces_at, header.namespaces_len);
        const content_bytes = try take(bytes, &cursor, header.content_at, header.content_len);
        const string_bytes = try take(bytes, &cursor, header.strings_at, header.strings_len);
        if (cursor != bytes.len) return error.InvalidFormat;
        const elements = try ElementTable.View.open(element_bytes);
        const attributes = try AttributeTable.View.open(attribute_bytes);
        const namespace_rows = try NamespaceTable.View.open(namespace_bytes);
        const content_rows = try ContentTable.View.open(content_bytes);
        const strings = try grammar.View.open(string_bytes, limits);
        if (elements.len() != header.element_count or attributes.len() != header.attribute_count or namespace_rows.len() != header.namespace_count or
            content_rows.len() != header.content_count or strings.item_count != header.string_count) return error.InvalidFormat;
        return .{ .bytes = bytes, .element_count = header.element_count, .attribute_count = header.attribute_count, .namespace_count = header.namespace_count, .content_count = header.content_count, .string_count = header.string_count, .document_content_end = header.document_content_end, .elements = elements, .attributes = attributes, .namespace_rows = namespace_rows, .content_rows = content_rows, .strings = strings };
    }
    fn starts(self: *const View, index: u32) Error!struct { namespace: u32, attribute: u32, content: u32 } {
        if (index >= self.element_count) return error.InvalidOccurrence;
        if (index == 0) return .{ .namespace = 0, .attribute = 0, .content = self.document_content_end };
        const prior = try self.elements.row(index - 1);
        return .{ .namespace = prior.namespace_end, .attribute = prior.attribute_end, .content = prior.content_end };
    }
    pub fn element(self: *const View, id: OccurrenceId) Error!Element {
        const index = @intFromEnum(id);
        if (index >= self.element_count) return error.InvalidOccurrence;
        const row = try self.elements.row(index);
        const start = try self.starts(index);
        if ((row.semantic != null and row.semantic.?.rank == std.math.maxInt(u32)) or
            row.subtree_end <= index or row.subtree_end > self.element_count or
            row.namespace_end < start.namespace or row.namespace_end > self.namespace_count or
            row.attribute_end < start.attribute or row.attribute_end > self.attribute_count or
            row.content_end < start.content or row.content_end > self.content_count) return error.InvalidFormat;
        if (row.parent) |parent| if (parent >= index) return error.InvalidParent;
        return .{ .id = id, .parent = if (row.parent) |parent| @enumFromInt(parent) else null, .name = try nameValue(row.name, self.string_count), .namespaces = .{ .start = start.namespace, .end = row.namespace_end }, .attributes = .{ .start = start.attribute, .end = row.attribute_end }, .content = .{ .start = start.content, .end = row.content_end }, .semantic = row.semantic };
    }
    pub fn documentContent(self: *const View) Span {
        return .{ .start = 0, .end = self.document_content_end };
    }
    pub fn namespace(self: *const View, index: u32) Error!Namespace {
        if (index >= self.namespace_count) return error.InvalidContent;
        const row = try self.namespace_rows.row(index);
        return .{ .prefix = try stringId(row.prefix, self.string_count), .uri = try stringId(row.uri, self.string_count) };
    }
    pub fn attribute(self: *const View, index: u32) Error!Attribute {
        if (index >= self.attribute_count) return error.InvalidContent;
        const row = try self.attributes.row(index);
        return .{ .name = try nameValue(row.name, self.string_count), .value = try stringId(row.value, self.string_count) };
    }
    pub fn content(self: *const View, index: u32) Error!Content {
        if (index >= self.content_count) return error.InvalidContent;
        const row = try self.content_rows.row(index);
        return switch (row.tag) {
            .text => if (row.second == null) .{ .text = try stringId(row.first, self.string_count) } else error.InvalidContent,
            .comment => if (row.second == null) .{ .comment = try stringId(row.first, self.string_count) } else error.InvalidContent,
            .child => if (row.first < self.element_count and row.second == null) .{ .child = @enumFromInt(row.first) } else error.InvalidContent,
            .processing_instruction => if (row.second) |second| .{ .processing_instruction = .{ .target = try stringId(row.first, self.string_count), .data = try stringId(second, self.string_count) } } else error.InvalidContent,
        };
    }
    pub fn string(self: *const View, id: StringId) Error!grammar.Item {
        return self.strings.item(@intFromEnum(id));
    }
    pub fn renderString(self: *const View, id: StringId, out: []u8, stack: []grammar.Frame) Error![]const u8 {
        const len = try wire.cast(usize, (try self.string(id)).output_len);
        if (len > out.len) return error.OutputTooSmall;
        const written = try self.strings.snippetWithStack(@intFromEnum(id), len, out, stack);
        if (written != len) return error.InvalidContent;
        return out[0..written];
    }
    fn stringEqual(self: *const View, id: StringId, value: []const u8, scratch: []u8, stack: []grammar.Frame) Error!bool {
        if ((try self.string(id)).output_len != value.len) return false;
        if (value.len > scratch.len) return error.OutputTooSmall;
        return std.mem.eql(u8, value, try self.renderString(id, scratch[0..value.len], stack));
    }
    pub fn nameEqual(self: *const View, name: Name, namespace_uri: []const u8, local_name: []const u8, scratch: []u8, stack: []grammar.Frame) Error!bool {
        return try self.stringEqual(name.namespace_uri, namespace_uri, scratch, stack) and try self.stringEqual(name.local_name, local_name, scratch, stack);
    }
    pub fn attributeByName(self: *const View, owner: OccurrenceId, namespace_uri: []const u8, local_name: []const u8, scratch: []u8, stack: []grammar.Frame) Error!?Attribute {
        const span = (try self.element(owner)).attributes;
        for (span.start..span.end) |index| {
            const value = try self.attribute(@intCast(index));
            if (try self.nameEqual(value.name, namespace_uri, local_name, scratch, stack)) return value;
        }
        return null;
    }
    pub fn xmlId(self: *const View, owner: OccurrenceId, scratch: []u8, stack: []grammar.Frame) Error!?StringId {
        return if (try self.attributeByName(owner, xml_namespace, "id", scratch, stack)) |value| value.value else null;
    }
    pub fn lookupXmlId(self: *const View, value: []const u8, scratch: []u8, stack: []grammar.Frame) Error!?OccurrenceId {
        for (0..self.element_count) |index| {
            const id: OccurrenceId = @enumFromInt(index);
            if (try self.xmlId(id, scratch, stack)) |candidate| if (try self.stringEqual(candidate, value, scratch, stack)) return id;
        }
        return null;
    }
    pub fn effectiveLanguage(self: *const View, start: OccurrenceId, scratch: []u8, stack: []grammar.Frame) Error!LanguageScope {
        var current: ?OccurrenceId = start;
        var remaining = self.element_count;
        while (current) |id| {
            if (remaining == 0) return error.InvalidParent;
            remaining -= 1;
            if (try self.attributeByName(id, xml_namespace, "lang", scratch, stack)) |value| return .{ .value = value.value, .owner = id };
            current = (try self.element(id)).parent;
        }
        return .{ .value = null, .owner = null };
    }
    pub const Descendants = struct {
        view: *const View,
        namespace_uri: []const u8,
        local_name: []const u8,
        scratch: []u8,
        stack: []grammar.Frame,
        next_index: u32,
        end: u32,
        pub fn next(self: *Descendants) Error!?OccurrenceId {
            while (self.next_index < self.end) {
                const id: OccurrenceId = @enumFromInt(self.next_index);
                self.next_index += 1;
                if (try self.view.nameEqual((try self.view.element(id)).name, self.namespace_uri, self.local_name, self.scratch, self.stack)) return id;
            }
            return null;
        }
    };
    pub fn descendants(self: *const View, scope: ?OccurrenceId, namespace_uri: []const u8, local_name: []const u8, scratch: []u8, stack: []grammar.Frame) Error!Descendants {
        if (!self.verified) return error.InvalidFormat;
        const root_index: ?u32 = if (scope) |root| blk: {
            _ = try self.element(root);
            break :blk @intFromEnum(root);
        } else null;
        const start: u32 = if (root_index) |root| std.math.add(u32, root, 1) catch return error.InvalidOccurrence else 0;
        const end: u32 = if (root_index) |root| (try self.elements.row(root)).subtree_end else self.element_count;
        if (start > end or end > self.element_count) return error.InvalidOccurrence;
        return .{ .view = self, .namespace_uri = namespace_uri, .local_name = local_name, .scratch = scratch, .stack = stack, .next_index = start, .end = end };
    }
    pub const ContentIterator = struct {
        view: *const View,
        next_index: u32,
        end: u32,
        pub fn next(self: *ContentIterator) Error!?Content {
            if (self.next_index == self.end) return null;
            const value = try self.view.content(self.next_index);
            self.next_index += 1;
            return value;
        }
    };
    pub fn events(self: *const View, scope: ?OccurrenceId) Error!ContentIterator {
        const span = if (scope) |id| (try self.element(id)).content else self.documentContent();
        return .{ .view = self, .next_index = span.start, .end = span.end };
    }
    pub const PlainFrame = struct { next: u32, end: u32 };
    pub const PlainText = struct { bytes: []const u8, complete: bool };
    /// Raw UTF-8 byte prefix; a requested bound may split a codepoint.
    pub fn plainText(self: *const View, scope: ?OccurrenceId, out: []u8, grammar_stack: []grammar.Frame, occurrence_stack: []PlainFrame) Error!PlainText {
        if (!self.verified) return error.InvalidFormat;
        var iterator = try self.events(scope);
        var depth: usize = 0;
        var written: usize = 0;
        while (true) {
            if (iterator.next_index == iterator.end) {
                if (depth == 0) return .{ .bytes = out[0..written], .complete = true };
                depth -= 1;
                const frame = occurrence_stack[depth];
                iterator.next_index = frame.next;
                iterator.end = frame.end;
                continue;
            }
            switch ((try iterator.next()).?) {
                .text => |id| {
                    const len = try wire.cast(usize, (try self.string(id)).output_len);
                    const wanted = @min(len, out.len - written);
                    const actual = try self.strings.snippetWithStack(@intFromEnum(id), wanted, out[written .. written + wanted], grammar_stack);
                    written += actual;
                    if (actual != wanted) return error.InvalidContent;
                    if (wanted != len) return .{ .bytes = out[0..written], .complete = false };
                },
                .child => |child| {
                    if (depth == occurrence_stack.len) return error.DepthExceeded;
                    occurrence_stack[depth] = .{ .next = iterator.next_index, .end = iterator.end };
                    depth += 1;
                    iterator = try self.events(child);
                },
                .comment, .processing_instruction => {},
            }
        }
    }
    pub fn verify(self: *View, allocator: std.mem.Allocator) Error!void {
        try self.elements.verify();
        try self.attributes.verify();
        try self.namespace_rows.verify();
        try self.content_rows.verify();
        try self.strings.verify();
        var ne: u32 = 0;
        var ae: u32 = 0;
        var ce = self.document_content_end;
        const stack = allocator.alloc(grammar.Frame, @max(@as(usize, 1), self.strings.rule_count + 1)) catch return error.OutOfMemory;
        defer allocator.free(stack);
        const decoded = allocator.alloc([]u8, self.string_count) catch return error.OutOfMemory;
        defer allocator.free(decoded);
        for (decoded) |*item| item.* = &.{};
        defer for (decoded) |item| if (item.len != 0) allocator.free(item);
        var unique_strings = std.StringHashMap(void).init(allocator);
        defer unique_strings.deinit();
        for (decoded, 0..) |*item, index| {
            const len = try wire.cast(usize, (try self.strings.item(index)).output_len);
            item.* = allocator.alloc(u8, len) catch return error.OutOfMemory;
            _ = try self.renderString(@enumFromInt(index), item.*, stack);
            if (!std.unicode.utf8ValidateSlice(item.*)) return error.InvalidFormat;
            const result = unique_strings.getOrPut(item.*) catch return error.OutOfMemory;
            if (result.found_existing) return error.InvalidFormat;
        }
        var ids = std.StringHashMap(void).init(allocator);
        defer ids.deinit();
        var scratch: [xml_namespace.len]u8 = undefined;
        var document_cursor: u32 = 0;
        var document = try self.events(null);
        while (try document.next()) |event| if (event == .child) {
            const child = event.child;
            if (@intFromEnum(child) != document_cursor or (try self.element(child)).parent != null) return error.InvalidContent;
            document_cursor = (try self.elements.row(@intFromEnum(child))).subtree_end;
        };
        if (document_cursor != self.element_count) return error.InvalidContent;
        for (0..self.element_count) |index| {
            const id: OccurrenceId = @enumFromInt(index);
            const element_value = try self.element(id);
            if (element_value.namespaces.start != ne or element_value.attributes.start != ae or element_value.content.start != ce) return error.InvalidContent;
            ne = element_value.namespaces.end;
            ae = element_value.attributes.end;
            ce = element_value.content.end;
            var attribute_names = std.AutoHashMap(u64, void).init(allocator);
            defer attribute_names.deinit();
            for (element_value.attributes.start..element_value.attributes.end) |at| {
                const attribute_value = try self.attribute(@intCast(at));
                const key = (@as(u64, @intFromEnum(attribute_value.name.namespace_uri)) << 32) | @intFromEnum(attribute_value.name.local_name);
                const result = attribute_names.getOrPut(key) catch return error.OutOfMemory;
                if (result.found_existing) return error.InvalidName;
            }
            var namespace_prefixes = std.AutoHashMap(u32, void).init(allocator);
            defer namespace_prefixes.deinit();
            for (element_value.namespaces.start..element_value.namespaces.end) |at| {
                const declaration = try self.namespace(@intCast(at));
                const result = namespace_prefixes.getOrPut(@intFromEnum(declaration.prefix)) catch return error.OutOfMemory;
                if (result.found_existing) return error.InvalidName;
            }
            var child_cursor: u32 = @intCast(index + 1);
            var children = try self.events(id);
            while (try children.next()) |event| if (event == .child) {
                const child = event.child;
                if (@intFromEnum(child) != child_cursor or (try self.element(child)).parent != id) return error.InvalidContent;
                child_cursor = (try self.elements.row(@intFromEnum(child))).subtree_end;
            };
            if (child_cursor != (try self.elements.row(index)).subtree_end) return error.InvalidContent;
            if (try self.xmlId(id, &scratch, stack)) |source_id| {
                const result = ids.getOrPut(decoded[@intFromEnum(source_id)]) catch return error.OutOfMemory;
                if (result.found_existing) return error.DuplicateSourceId;
            }
        }
        if (ne != self.namespace_count or ae != self.attribute_count or ce != self.content_count) return error.InvalidContent;
        self.verified = true;
    }
};

test "document spans preserve outer events IDs and inherited language" {
    const elements = [_]ElementInput{
        .{ .parent = null, .name = .{ .namespace_uri = "urn:tei", .local_name = "entry" }, .attributes = &.{
            .{ .name = .{ .namespace_uri = xml_namespace, .local_name = "id" }, .value = "e1" },
            .{ .name = .{ .namespace_uri = xml_namespace, .local_name = "lang" }, .value = "pt" },
        }, .content = &.{ .{ .text = "before" }, .{ .child = @enumFromInt(1) }, .{ .text = "after" } } },
        .{ .parent = @enumFromInt(0), .name = .{ .namespace_uri = "urn:tei", .local_name = "form" }, .content = &.{.{ .text = "inside" }} },
    };
    var owned = try build(std.testing.allocator, .{ .elements = &elements, .content = &.{ .{ .comment = "outer" }, .{ .child = @enumFromInt(0) } } }, .{});
    defer owned.deinit();
    var view = try owned.view(.{});
    try view.verify(std.testing.allocator);
    var scratch: [xml_namespace.len]u8 = undefined;
    var stack: [32]grammar.Frame = undefined;
    try std.testing.expectEqual(@as(?OccurrenceId, @enumFromInt(0)), try view.lookupXmlId("e1", &scratch, &stack));
    try std.testing.expectEqual(@as(?OccurrenceId, @enumFromInt(0)), (try view.effectiveLanguage(@enumFromInt(1), &scratch, &stack)).owner);
    var out: [7]u8 = undefined;
    var frames: [4]View.PlainFrame = undefined;
    const plain = try view.plainText(@enumFromInt(0), &out, &stack, &frames);
    try std.testing.expectEqualStrings("beforei", plain.bytes);
    try std.testing.expect(!plain.complete);
}
