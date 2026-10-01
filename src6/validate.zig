//! Semantic admission for a lexical packet. The reflected walk owns shape;
//! the small type-specific rules below own meaning. Encoding has no authority
//! to declare an unresolved local reference or malformed XML name valid.
const std = @import("std");
const model = @import("model.zig");
const nodes = @import("nodes.zig");
const walk = @import("walk.zig");

pub const Limits = struct {
    max_depth: usize = 96,
    max_values: usize = 1_000_000,
    max_bytes: usize = 16 * 1024 * 1024,
};

pub const Error = std.mem.Allocator.Error || error{
    ResourceLimit,
    InvalidIdentity,
    DuplicateIdentity,
    UnresolvedLocal,
    InvalidAnchor,
    InvalidLanguage,
    InvalidName,
    InvalidUtf8,
    InvalidMarkup,
    InvalidValue,
    InvalidReferenceKind,
    InvalidRealization,
};

/// Build once for the library, then borrow during document admission. Keys are
/// borrowed and immutable: their storage must outlive the index and every
/// check using it. Mutating key bytes invalidates the hash-table contract.
pub const SourceIndex = struct {
    extents: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn deinit(self: *SourceIndex, allocator: std.mem.Allocator) void {
        self.extents.deinit(allocator);
        self.* = .{};
    }

    pub fn add(self: *SourceIndex, allocator: std.mem.Allocator, id: []const u8, byte_length: usize) Error!void {
        if (id.len == 0) return error.InvalidIdentity;
        try utf8(id);
        const slot = try self.extents.getOrPut(allocator, id);
        if (slot.found_existing) return error.DuplicateIdentity;
        slot.value_ptr.* = byte_length;
    }

    pub fn length(self: *const SourceIndex, id: []const u8) ?usize {
        return self.extents.get(id);
    }

    pub fn count(self: *const SourceIndex) usize {
        return self.extents.count();
    }
};

pub const Scope = struct {
    sources: *const SourceIndex = &.{},
    limits: Limits = .{},
};

/// Both document kinds share identity collection, bounds and semantic rules.
/// Only their roots differ; the public operation does not multiply with kinds.
pub fn check(allocator: std.mem.Allocator, value: anytype, scope: Scope) Error!void {
    const T = @TypeOf(value.*);
    if (T != model.Entry and T != model.Resource) @compileError("expected Entry or Resource");
    const identity = if (T == model.Entry) value.id else value.identity();
    if (identity.len == 0) return error.InvalidIdentity;
    try utf8(identity);
    if (T == model.Entry) try utf8(value.headword);
    if (scope.sources.count() > scope.limits.max_values) return error.ResourceLimit;
    var context = Context{ .allocator = allocator, .limits = scope.limits, .shared_sources = scope.sources };
    defer context.ids.deinit(allocator);
    defer context.local_sources.deinit(allocator);
    defer context.links.deinit(allocator);
    defer context.spans.deinit(allocator);
    if (T == model.Entry) {
        for (value.sources) |source| try context.addSource(source.id, source.bytes.len);
    } else if (value.* == .source) {
        if (scope.sources.length(value.source.id)) |length| {
            if (length != value.source.bytes.len) return error.InvalidAnchor;
        } else try context.addSource(value.source.id, value.source.bytes.len);
    }

    // Visit the model once. Only local-link obligations wait for the complete
    // identity table; a forward reference does not require a second tree walk.
    try context.scan(value);
    if (T == model.Entry) for (value.keys) |key| {
        try utf8(key.spelling);
        if (key.form) |id| {
            try context.require(id, .form);
        }
    };
    for (context.links.items) |link| try context.require(link.id, link.kind);
    for (context.spans.items) |span| try context.realization(span);
}

const Context = struct {
    const Target = enum { any, form, concept, sense, representation };
    const Link = struct { id: []const u8, kind: Target };

    allocator: std.mem.Allocator,
    limits: Limits,
    ids: std.StringHashMapUnmanaged(nodes.NodeRef) = .empty,
    shared_sources: *const SourceIndex,
    local_sources: SourceIndex = .{},
    traversal_work: usize = 0,
    comparisons: usize = 0,
    // Borrowed identifiers only. No pending nodes or duplicate model objects.
    links: std.ArrayList(Link) = .empty,
    spans: std.ArrayList(*const model.RealizationSpan) = .empty,

    fn addSource(self: *Context, id: []const u8, length: usize) Error!void {
        if (self.shared_sources.length(id) != null) return error.DuplicateIdentity;
        if (self.local_sources.count() >= self.limits.max_values - self.shared_sources.count())
            return error.ResourceLimit;
        try self.local_sources.add(self.allocator, id, length);
    }

    fn scan(self: *Context, pointer: anytype) Error!void {
        const T = @TypeOf(pointer.*);
        var cursor = nodes.Cursor(T).init(pointer, .{}, .{
            .max_depth = self.limits.max_depth,
            .max_work = self.limits.max_values,
            .max_bytes = self.limits.max_bytes,
        });
        while (true) {
            cursor.limits.max_work = self.limits.max_values -| self.comparisons;
            const event = (cursor.next() catch return error.ResourceLimit) orelse break;
            self.traversal_work = cursor.work;
            if (event.node.identity()) |id| try self.addIdentity(id, event.node);
            try self.ruleNode(event.node);
        }
        self.traversal_work = cursor.work;
    }

    fn deferLink(self: *Context, id: []const u8, kind: Target) Error!void {
        try self.chargeComparison();
        try self.links.append(self.allocator, .{ .id = id, .kind = kind });
    }

    fn require(self: *Context, id: []const u8, kind: Target) Error!void {
        try self.chargeComparison();
        const target = self.ids.get(id) orelse return error.UnresolvedLocal;
        const matches = switch (kind) {
            .any => true,
            .form => target.as(model.Form) != null,
            .concept => target.as(model.Concept) != null,
            .sense => target.as(model.Sense) != null,
            .representation => target.as(model.Representation) != null,
        };
        if (!matches) return error.InvalidReferenceKind;
    }

    fn addIdentity(self: *Context, id: []const u8, owner: nodes.NodeRef) Error!void {
        if (id.len == 0) return error.InvalidIdentity;
        try utf8(id);
        const result = try self.ids.getOrPut(self.allocator, id);
        // A SharedValue definition is an ownership edge, not a graph alias in
        // the packet encoding. Define it once and reuse it via Value.reference.
        if (result.found_existing) return error.DuplicateIdentity;
        result.value_ptr.* = owner;
    }

    fn reference(self: *Context, value: model.Reference) Error!void {
        switch (value) {
            .local => |id| try self.deferLink(id, .any),
            .entry, .resource => |target| {
                if (target.id.len == 0 or (target.fragment != null and target.fragment.?.len == 0))
                    return error.InvalidIdentity;
            },
            .iri => |iri| if (iri.len == 0) return error.InvalidIdentity,
            .unresolved => |target| if (target.identifier.len == 0) return error.InvalidIdentity,
        }
    }

    fn ruleNode(self: *Context, value: nodes.NodeRef) Error!void {
        const semantic_types = .{
            model.Reference,       model.Anchor,     model.Name,        model.Language,
            model.Inline,          model.Metadata,   model.Value,       model.Relation,
            model.Certainty,       model.Denotation, model.SharedValue, model.Analysis,
            model.RealizationSpan,
        };
        inline for (semantic_types) |T| {
            if (value.as(T)) |pointer| return self.rule(pointer);
        }
    }

    fn rule(self: *Context, pointer: anytype) Error!void {
        const T = @TypeOf(pointer.*);
        if (T == model.Reference) try self.reference(pointer.*);
        if (T == model.Anchor) {
            const length = self.local_sources.length(pointer.source) orelse
                self.shared_sources.length(pointer.source) orelse return error.InvalidAnchor;
            if (pointer.start > pointer.end or pointer.end > length) return error.InvalidAnchor;
        }
        if (T == model.Name) {
            if (!xmlName(pointer.local) or (pointer.prefix.len != 0 and !xmlName(pointer.prefix)))
                return error.InvalidName;
            if (pointer.prefix.len != 0 and pointer.namespace.len == 0) return error.InvalidName;
            if (std.mem.eql(u8, pointer.prefix, "xmlns") or std.mem.eql(u8, pointer.namespace, "http://www.w3.org/2000/xmlns/"))
                return error.InvalidName;
            const is_xml = std.mem.eql(u8, pointer.prefix, "xml");
            if (is_xml != std.mem.eql(u8, pointer.namespace, "http://www.w3.org/XML/1998/namespace")) return error.InvalidName;
            try utf8(pointer.namespace);
        }
        if (T == model.Language) switch (pointer.*) {
            .tag => |tag| if (!try languageTag(self, tag)) return error.InvalidLanguage,
            else => {},
        };
        if (T == model.Inline) switch (pointer.*) {
            .text => |text| try xmlText(text),
            .comment => |text| {
                try xmlText(text);
                if (std.mem.indexOf(u8, text, "--") != null or std.mem.endsWith(u8, text, "-")) return error.InvalidMarkup;
            },
            .instruction => |instruction| {
                if (!xmlName(instruction.target) or std.ascii.eqlIgnoreCase(instruction.target, "xml"))
                    return error.InvalidMarkup;
                if (std.mem.indexOf(u8, instruction.data, "?>") != null) return error.InvalidMarkup;
                try xmlText(instruction.data);
            },
            .element => |element| {
                try self.attributes(element.attributes);
                for (element.attributes) |attribute| {
                    const name = attribute.name;
                    if (name.namespace.len != 0 and name.prefix.len == 0) return error.InvalidMarkup;
                    if (name.prefix.len != 0 and std.mem.eql(u8, name.prefix, element.name.prefix) and
                        !std.mem.eql(u8, name.namespace, element.name.namespace)) return error.InvalidMarkup;
                }
            },
        };
        if (T == model.Metadata) try self.attributes(pointer.attributes);
        if (T == model.Value) switch (pointer.*) {
            .decimal => |text| if (!decimal(text)) return error.InvalidValue,
            .alternative => |items| if (items.len < 2) return error.InvalidValue,
            .negation => |items| if (items.len != 1) return error.InvalidValue,
            .structure => |structure| {
                const fields = structure.fields;
                for (fields, 0..) |field, index| {
                    for (fields[0..index]) |previous| {
                        try self.chargeComparison();
                        if (sameName(field.name, previous.name)) return error.InvalidValue;
                    }
                }
            },
            // Sets retain declared semantics. Equality is validated using the
            // same bounded structural comparison; bags intentionally skip it.
            .set => |items| {
                for (items, 0..) |*item, index| {
                    for (items[0..index]) |*previous| {
                        if (try self.equal(item, previous, 0)) return error.InvalidValue;
                    }
                }
            },
            else => {},
        };
        if (T == model.Relation) {
            switch (pointer.endpoints) {
                .participants => |participants| if (participants.len < 2) return error.InvalidValue,
                .binary => {},
            }
            if (pointer.confidence) |confidence| {
                try probability(confidence);
            }
            if (pointer.endpoints == .binary and pointer.endpoints.binary == .local) {
                const expected: Target = switch (pointer.predicate) {
                    .evokes => .concept,
                    .lexicalized_sense => .sense,
                    else => .any,
                };
                if (expected != .any) try self.deferLink(pointer.endpoints.binary.local, expected);
            }
        }
        if (T == model.Certainty) {
            if (pointer.degree) |degree| try probability(degree);
        }
        if (T == model.Denotation and pointer.iri.len == 0) return error.InvalidIdentity;
        if (T == model.SharedValue and (pointer.meta.id == null or pointer.meta.id.?.len == 0))
            return error.InvalidIdentity;
        if (T == model.Analysis) {
            if (pointer.form) |reference_value| {
                if (reference_value == .local) try self.deferLink(reference_value.local, .form);
            }
        }
        if (T == model.RealizationSpan) {
            if (pointer.start > pointer.end) return error.InvalidRealization;
            switch (pointer.representation) {
                .local => |id| {
                    try self.deferLink(id, .representation);
                    try self.chargeComparison();
                    try self.spans.append(self.allocator, pointer);
                },
                .entry, .resource => |address| if (address.fragment == null) return error.InvalidReferenceKind,
                // External and source-unresolved representation addresses are
                // preserved. Their extents require resolving the other owner.
                .iri, .unresolved => {},
            }
        }
    }

    fn realization(self: *Context, span: *const model.RealizationSpan) Error!void {
        const owner = self.ids.get(span.representation.local) orelse return error.UnresolvedLocal;
        const representation = owner.as(model.Representation) orelse return error.InvalidReferenceKind;
        var cursor = walk.Cursor(model.Inline).init(representation.text.content, .{}, .{});
        var length: usize = 0;
        var start_boundary = span.start == 0;
        var end_boundary = span.end == 0;
        while (cursor.next() catch return error.ResourceLimit) |event| {
            try self.chargeComparison();
            if (event.node.* != .text) continue;
            const text = event.node.text;
            const end = std.math.add(usize, length, text.len) catch return error.ResourceLimit;
            if (span.start >= length and span.start <= end)
                start_boundary = scalarBoundary(text, span.start - length);
            if (span.end >= length and span.end <= end)
                end_boundary = scalarBoundary(text, span.end - length);
            length = end;
        }
        if (span.end > length or !start_boundary or !end_boundary) return error.InvalidRealization;
    }

    fn attributes(self: *Context, values: []const model.Attribute) Error!void {
        for (values, 0..) |attribute, index| {
            try xmlText(attribute.value);
            // Language has one authority. Accepting a second declaration in
            // raw attributes would let rendering and contextual queries disagree.
            if (std.mem.eql(u8, attribute.name.namespace, "http://www.w3.org/XML/1998/namespace") and
                std.mem.eql(u8, attribute.name.local, "lang")) return error.InvalidMarkup;
            for (values[0..index]) |previous| {
                try self.chargeComparison();
                if (sameName(attribute.name, previous.name)) return error.InvalidMarkup;
                if (attribute.name.prefix.len != 0 and std.mem.eql(u8, attribute.name.prefix, previous.name.prefix) and
                    !std.mem.eql(u8, attribute.name.namespace, previous.name.namespace)) return error.InvalidMarkup;
            }
        }
    }

    fn chargeComparison(self: *Context) Error!void {
        if (self.traversal_work >= self.limits.max_values -| self.comparisons)
            return error.ResourceLimit;
        self.comparisons += 1;
    }

    fn equal(self: *Context, left: anytype, right: @TypeOf(left), depth: usize) Error!bool {
        if (depth > self.limits.max_depth) return error.ResourceLimit;
        try self.chargeComparison();
        const T = @TypeOf(left.*);
        if (T == []const u8) return std.mem.eql(u8, left.*, right.*);
        return switch (@typeInfo(T)) {
            .@"struct" => |info| same: {
                inline for (info.fields) |field| {
                    if (!try self.equal(&@field(left.*, field.name), &@field(right.*, field.name), depth + 1)) break :same false;
                }
                break :same true;
            },
            .@"union" => same: {
                if (std.meta.activeTag(left.*) != std.meta.activeTag(right.*)) break :same false;
                break :same switch (left.*) {
                    inline else => |*payload, tag| try self.equal(payload, &@field(right.*, @tagName(tag)), depth + 1),
                };
            },
            .optional => if (left.*) |*payload| if (right.*) |*other| try self.equal(payload, other, depth + 1) else false else right.* == null,
            .array => same: {
                if (left.len != right.len) break :same false;
                for (left.*, right.*) |*a, *b| if (!try self.equal(a, b, depth + 1)) break :same false;
                break :same true;
            },
            .pointer => |info| same: {
                if (info.child == u8 and info.size == .slice)
                    break :same std.mem.eql(u8, left.*, right.*);
                switch (info.size) {
                    .slice => {
                        if (left.len != right.len) break :same false;
                        for (left.*, right.*) |*a, *b| if (!try self.equal(a, b, depth + 1)) break :same false;
                        break :same true;
                    },
                    .one => break :same try self.equal(left.*, right.*, depth + 1),
                    .many, .c => @compileError("unbounded pointers are not a supported lexical shape"),
                }
            },
            .void => true,
            else => left.* == right.*,
        };
    }
};

fn scalarBoundary(text: []const u8, offset: usize) bool {
    return offset == text.len or (text[offset] & 0xc0) != 0x80;
}

/// RFC 5646 structural grammar only. This deliberately does not claim IANA
/// registry membership or canonicalization, and preserves the original case.
fn languageTag(context: *Context, tag: []const u8) Error!bool {
    if (tag.len == 0 or tag[0] == '-' or tag[tag.len - 1] == '-') return false;
    for (tag) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-') return false;
    if (grandfathered(tag)) return true;

    var position: usize = 0;
    const language = nextSubtag(tag, &position) orelse return false;
    if (language.len == 1 and std.ascii.toLower(language[0]) == 'x')
        return privateUseTail(tag, &position);
    if (!alpha(language) or language.len < 2 or language.len > 8) return false;

    if (language.len <= 3) {
        var extlangs: usize = 0;
        while (extlangs < 3) : (extlangs += 1) {
            const saved = position;
            const candidate = nextSubtag(tag, &position) orelse break;
            if (candidate.len != 3 or !alpha(candidate)) {
                position = saved;
                break;
            }
        }
    }

    var saved = position;
    if (nextSubtag(tag, &position)) |script| {
        if (script.len != 4 or !alpha(script)) position = saved;
    }
    saved = position;
    if (nextSubtag(tag, &position)) |region| {
        if (!((region.len == 2 and alpha(region)) or (region.len == 3 and numeric(region))))
            position = saved;
    }

    const variants_start = position;
    while (true) {
        saved = position;
        const variant = nextSubtag(tag, &position) orelse return true;
        const valid = (variant.len >= 5 and variant.len <= 8 and alphanumeric(variant)) or
            (variant.len == 4 and std.ascii.isDigit(variant[0]) and alphanumeric(variant));
        if (!valid) {
            position = saved;
            break;
        }
        if (try duplicateBetween(context, tag, variants_start, saved, variant)) return false;
    }

    const extensions_start = position;
    while (true) {
        saved = position;
        const singleton = nextSubtag(tag, &position) orelse return true;
        if (singleton.len != 1 or !std.ascii.isAlphanumeric(singleton[0]) or
            std.ascii.toLower(singleton[0]) == 'x')
        {
            position = saved;
            break;
        }
        if (try duplicateBetween(context, tag, extensions_start, saved, singleton)) return false;
        var extension_count: usize = 0;
        while (true) {
            const extension_saved = position;
            const extension = nextSubtag(tag, &position) orelse break;
            if (extension.len < 2 or extension.len > 8 or !alphanumeric(extension)) {
                position = extension_saved;
                break;
            }
            extension_count += 1;
        }
        if (extension_count == 0) return false;
    }

    const private = nextSubtag(tag, &position) orelse return position == tag.len;
    if (private.len != 1 or std.ascii.toLower(private[0]) != 'x') return false;
    return privateUseTail(tag, &position);
}

fn nextSubtag(tag: []const u8, position: *usize) ?[]const u8 {
    if (position.* == tag.len) return null;
    const start = position.*;
    const end = std.mem.indexOfScalarPos(u8, tag, start, '-') orelse tag.len;
    position.* = if (end == tag.len) end else end + 1;
    return tag[start..end];
}

fn privateUseTail(tag: []const u8, position: *usize) bool {
    var count: usize = 0;
    while (nextSubtag(tag, position)) |part| {
        if (part.len < 1 or part.len > 8 or !alphanumeric(part)) return false;
        count += 1;
    }
    return count != 0;
}

fn duplicateBetween(context: *Context, tag: []const u8, start: usize, end: usize, needle: []const u8) Error!bool {
    var position: usize = start;
    while (position < end) {
        const part = nextSubtag(tag[0..end], &position) orelse break;
        try context.chargeComparison();
        if (std.ascii.eqlIgnoreCase(part, needle)) return true;
    }
    return false;
}

fn alpha(value: []const u8) bool {
    for (value) |byte| if (!std.ascii.isAlphabetic(byte)) return false;
    return true;
}

fn numeric(value: []const u8) bool {
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn alphanumeric(value: []const u8) bool {
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte)) return false;
    return true;
}

fn grandfathered(tag: []const u8) bool {
    const values = [_][]const u8{
        "en-GB-oed",   "i-ami",    "i-bnn",     "i-default", "i-enochian", "i-hak",
        "i-klingon",   "i-lux",    "i-mingo",   "i-navajo",  "i-pwn",      "i-tao",
        "i-tay",       "i-tsu",    "sgn-BE-FR", "sgn-BE-NL", "sgn-CH-DE",  "art-lojban",
        "cel-gaulish", "no-bok",   "no-nyn",    "zh-guoyu",  "zh-hakka",   "zh-min",
        "zh-min-nan",  "zh-xiang",
    };
    for (values) |value| if (std.ascii.eqlIgnoreCase(value, tag)) return true;
    return false;
}

fn sameName(a: model.Name, b: model.Name) bool {
    return std.mem.eql(u8, a.namespace, b.namespace) and std.mem.eql(u8, a.local, b.local);
}

fn probability(text: []const u8) Error!void {
    if (!decimal(text)) return error.InvalidValue;
    // Compare decimal digits, not a rounded float (1.000...001 is not 1).
    var digits = text;
    if (digits[0] == '-') return error.InvalidValue;
    if (digits[0] == '+') digits = digits[1..];
    const dot = std.mem.indexOfScalar(u8, digits, '.') orelse digits.len;
    var integer = digits[0..dot];
    while (integer.len > 1 and integer[0] == '0') integer = integer[1..];
    if (integer.len != 1 or integer[0] > '1') return error.InvalidValue;
    if (integer[0] == '1' and dot != digits.len) {
        for (digits[dot + 1 ..]) |digit| if (digit != '0') return error.InvalidValue;
    }
}

fn utf8(text: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
}

fn xmlText(text: []const u8) Error!void {
    const view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |point| {
        if (!(point == 9 or point == 10 or point == 13 or
            (point >= 0x20 and point <= 0xd7ff) or
            (point >= 0xe000 and point <= 0xfffd) or
            (point >= 0x10000 and point <= 0x10ffff))) return error.InvalidMarkup;
    }
}

fn xmlName(text: []const u8) bool {
    const view = std.unicode.Utf8View.init(text) catch return false;
    var iterator = view.iterator();
    const first = iterator.nextCodepoint() orelse return false;
    if (!nameStart(first)) return false;
    while (iterator.nextCodepoint()) |point| {
        if (!(nameStart(point) or (point >= '0' and point <= '9') or
            point == '-' or point == '.' or point == 0xb7 or
            (point >= 0x300 and point <= 0x36f) or (point >= 0x203f and point <= 0x2040))) return false;
    }
    return true;
}

fn nameStart(point: u21) bool {
    return point == '_' or (point >= 'A' and point <= 'Z') or (point >= 'a' and point <= 'z') or
        (point >= 0xc0 and point <= 0xd6) or (point >= 0xd8 and point <= 0xf6) or
        (point >= 0xf8 and point <= 0x2ff) or (point >= 0x370 and point <= 0x37d) or
        (point >= 0x37f and point <= 0x1fff) or (point >= 0x200c and point <= 0x200d) or
        (point >= 0x2070 and point <= 0x218f) or (point >= 0x2c00 and point <= 0x2fef) or
        (point >= 0x3001 and point <= 0xd7ff) or (point >= 0xf900 and point <= 0xfdcf) or
        (point >= 0xfdf0 and point <= 0xfffd) or (point >= 0x10000 and point <= 0xeffff);
}

/// Exact finite decimal lexemes, deliberately without exponent notation.
pub fn decimal(text: []const u8) bool {
    if (text.len == 0) return false;
    var position: usize = @intFromBool(text[0] == '-' or text[0] == '+');
    const start = position;
    while (position < text.len and std.ascii.isDigit(text[position])) : (position += 1) {}
    if (position == start) return false;
    if (position == text.len) return true;
    if (text[position] != '.') return false;
    position += 1;
    const fraction = position;
    while (position < text.len and std.ascii.isDigit(text[position])) : (position += 1) {}
    return position > fraction and position == text.len;
}
