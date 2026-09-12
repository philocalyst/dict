//! Semantic admission for a lexical packet. The reflected walk owns shape;
//! the small type-specific rules below own meaning. Encoding has no authority
//! to declare an unresolved local reference or malformed XML name valid.
const std = @import("std");
const model = @import("model.zig");

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
    if (T == model.Entry) {
        for (value.sources) |source| try context.addSource(source.id, source.bytes.len);
    } else if (value.* == .source) {
        if (scope.sources.length(value.source.id)) |length| {
            if (length != value.source.bytes.len) return error.InvalidAnchor;
        } else try context.addSource(value.source.id, value.source.bytes.len);
    }

    // Local references may point forward, including to a qualified relation.
    // A collection pass avoids making source order an accidental restriction.
    context.collecting = true;
    try context.visit(value, 0);
    context.collecting = false;
    context.visited = 0;
    context.bytes = 0;
    try context.visit(value, 0);
    if (T == model.Entry) for (value.keys) |key| {
        try utf8(key.spelling);
        if (key.form) |id| {
            const target = context.ids.get(id) orelse return error.UnresolvedLocal;
            if (target != .form) return error.InvalidReferenceKind;
        }
    };
}

const Context = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    ids: std.StringHashMapUnmanaged(?model.Kind) = .empty,
    shared_sources: *const SourceIndex,
    local_sources: SourceIndex = .{},
    collecting: bool = true,
    visited: usize = 0,
    bytes: usize = 0,

    fn addSource(self: *Context, id: []const u8, length: usize) Error!void {
        if (self.shared_sources.length(id) != null) return error.DuplicateIdentity;
        if (self.local_sources.count() >= self.limits.max_values - self.shared_sources.count())
            return error.ResourceLimit;
        try self.local_sources.add(self.allocator, id, length);
    }

    fn visit(self: *Context, pointer: anytype, depth: usize) Error!void {
        const T = @TypeOf(pointer.*);
        if (depth > self.limits.max_depth or self.visited >= self.limits.max_values)
            return error.ResourceLimit;
        self.visited += 1;

        if (comptime T == []const u8) {
            if (pointer.len > self.limits.max_bytes -| self.bytes) return error.ResourceLimit;
            self.bytes += pointer.len;
            return;
        }
        if (comptime T == model.Metadata) {
            if (self.collecting) {
                if (pointer.id) |id| try self.addIdentity(id, null);
            }
        }
        if (!self.collecting) try self.rule(pointer);
        switch (@typeInfo(T)) {
            .@"struct" => |info| inline for (info.fields) |field| {
                try self.visit(&@field(pointer.*, field.name), depth + 1);
            },
            .@"union" => switch (pointer.*) {
                inline else => |*payload| try self.visit(payload, depth + 1),
            },
            .optional => if (pointer.*) |*payload| try self.visit(payload, depth + 1),
            .array, .pointer => for (pointer.*) |*item| try self.visit(item, depth + 1),
            .int, .bool, .@"enum", .void => {},
            else => @compileError("unsupported lexical shape: " ++ @typeName(T)),
        }
        if (comptime T == model.Item) {
            if (self.collecting) {
                if (pointer.metadata().id) |id| self.ids.getPtr(id).?.* = std.meta.activeTag(pointer.*);
            }
        }
    }

    fn addIdentity(self: *Context, id: []const u8, kind: ?model.Kind) Error!void {
        if (id.len == 0) return error.InvalidIdentity;
        const result = try self.ids.getOrPut(self.allocator, id);
        if (result.found_existing) return error.DuplicateIdentity;
        result.value_ptr.* = kind;
    }

    fn reference(self: *Context, value: model.Reference) Error!void {
        switch (value) {
            .local => |id| if (!self.ids.contains(id)) return error.UnresolvedLocal,
            .entry, .resource => |target| {
                if (target.id.len == 0 or (target.fragment != null and target.fragment.?.len == 0))
                    return error.InvalidIdentity;
            },
            .iri => |iri| if (iri.len == 0) return error.InvalidIdentity,
            .unresolved => |target| if (target.identifier.len == 0) return error.InvalidIdentity,
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
            .tag => |tag| {
                if (tag.len == 0) return error.InvalidLanguage;
                for (tag) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-') return error.InvalidLanguage;
            },
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
            if (pointer.target == null and pointer.participants.len < 2) return error.InvalidValue;
            if (pointer.confidence) |confidence| {
                try probability(confidence);
            }
            if (pointer.target != null and pointer.target.? == .local) {
                const actual = self.ids.get(pointer.target.?.local) orelse return error.UnresolvedLocal;
                const expected: ?model.Kind = switch (pointer.predicate) {
                    .evokes => .concept,
                    .lexicalized_sense => .sense,
                    else => null,
                };
                if (expected != null and expected != actual) return error.InvalidReferenceKind;
            }
        }
        if (T == model.Certainty) {
            if (pointer.degree) |degree| try probability(degree);
        }
        if (T == model.Denotation and pointer.iri.len == 0) return error.InvalidIdentity;
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
        if (self.visited >= self.limits.max_values) return error.ResourceLimit;
        self.visited += 1;
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
            .array, .pointer => same: {
                if (left.len != right.len) break :same false;
                for (left.*, right.*) |*a, *b| if (!try self.equal(a, b, depth + 1)) break :same false;
                break :same true;
            },
            .void => true,
            else => left.* == right.*,
        };
    }
};

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
