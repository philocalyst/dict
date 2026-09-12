//! Typed selections borrow ordinary lexical values and their inherited context.
//! Storage addresses do not leak into sense, form, or definition navigation.
const std = @import("std");
const model = @import("model.zig");
const walk = @import("walk.zig");

pub const Scope = walk.Scope;

/// A result keeps its effective language, including the declaration that set or
/// reset it. Chaining selections therefore cannot silently lose parent context.
pub fn Match(comptime T: type) type {
    return struct {
        value: *const T,
        language: walk.Language,

        pub fn select(self: @This(), comptime kind: model.Kind, scope: Scope) Selection(kind) {
            comptime {
                if (!@hasField(T, "content") or @FieldType(T, "content") != []const model.Item)
                    @compileError("lexical selection requires a lexical container");
            }
            return .{ .cursor = .init(self.value.content, self.language, .{ .scope = scope }) };
        }

        pub fn inlines(self: @This()) walk.Cursor(model.Inline) {
            if (T != model.Text) @compileError("inline selection requires Text");
            return .init(self.value.content, self.language, .{});
        }

        /// Follow an actual single-valued field while retaining its context.
        /// The compiler derives field names and payload types from the model.
        pub fn child(self: @This(), comptime field: std.meta.FieldEnum(T)) Match(@FieldType(T, @tagName(field))) {
            if (@typeInfo(T) != .@"struct") @compileError("field projection requires a struct; switch on tagged values first");
            return contextual(&@field(self.value.*, @tagName(field)), self.language);
        }

        /// Forms' representations, examples' quotes, features and annotations
        /// use one typed slice projection, not one API façade per relationship.
        pub fn values(self: @This(), comptime field: std.meta.FieldEnum(T)) Values(std.meta.Child(@FieldType(T, @tagName(field)))) {
            if (@typeInfo(T) != .@"struct") @compileError("field projection requires a struct; switch on tagged values first");
            return .{ .remaining = @field(self.value.*, @tagName(field)), .language = self.language };
        }
    };
}

pub fn Values(comptime T: type) type {
    return struct {
        remaining: []const T,
        language: walk.Language,

        pub fn next(self: *@This()) ?Match(T) {
            if (self.remaining.len == 0) return null;
            const value = &self.remaining[0];
            self.remaining = self.remaining[1..];
            return contextual(value, self.language);
        }
    };
}

fn contextual(value: anytype, parent: walk.Language) Match(@TypeOf(value.*)) {
    return .{ .value = value, .language = parent.at(value) };
}

/// Source order and multiplicity survive filtering. The union declaration is
/// the only list of payload kinds; no parallel set of per-kind façades exists.
pub fn Selection(comptime kind: model.Kind) type {
    return struct {
        cursor: walk.Cursor(model.Item),
        pub const Payload = @FieldType(model.Item, @tagName(kind));

        pub fn next(self: *@This()) walk.Error!?Match(Payload) {
            while (try self.cursor.next()) |event| {
                if (event.node.* == kind) return .{
                    .value = &@field(event.node.*, @tagName(kind)),
                    .language = event.language,
                };
            }
            return null;
        }
    };
}

pub fn entry(value: *const model.Entry) Match(model.Entry) {
    return contextual(value, .{});
}

pub const Located = struct { item: *const model.Item, language: walk.Language };

/// Resolve entry-local lexical items, not external IRIs or physical addresses.
/// Metadata identities on representations/features remain inspectable in their
/// owning typed value; they are not silently presented as lexical Item nodes.
pub fn resolve(value: *const model.Entry, id: []const u8) walk.Error!?Located {
    var cursor = walk.Cursor(model.Item).init(value.content, entry(value).language, .{});
    while (try cursor.next()) |event| {
        const candidate = event.node.metadata().id orelse continue;
        if (std.mem.eql(u8, id, candidate)) return .{ .item = event.node, .language = event.language };
    }
    return null;
}
