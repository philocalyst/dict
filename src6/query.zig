//! Allocation-free typed lexical selections and complete structural queries.
//! Fast Item/Inline cursors remain separate from the reflection-derived path
//! cursor used for all-node resolution and uncommon rich queries.
const std = @import("std");
const model = @import("model.zig");
const nodes = @import("nodes.zig");
const walk = @import("walk.zig");

pub const Scope = walk.Scope;
pub const StructuralLimits = nodes.Limits;
pub const NodeRef = nodes.NodeRef;
pub const Edge = nodes.Edge;

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

        pub fn child(self: @This(), comptime field: std.meta.FieldEnum(T)) Match(@FieldType(T, @tagName(field))) {
            if (@typeInfo(T) != .@"struct") @compileError("field projection requires a struct; switch on tagged values first");
            return contextual(&@field(self.value.*, @tagName(field)), self.language);
        }

        /// Byte strings intentionally do not satisfy this collection API; use
        /// `child` when the field itself is textual bytes.
        pub fn values(self: @This(), comptime field: std.meta.FieldEnum(T)) Values(sliceElement(T, field)) {
            return .{ .remaining = @field(self.value.*, @tagName(field)), .language = self.language };
        }

        pub fn descendants(self: @This(), comptime Node: type, limits: StructuralLimits) StructuralSelection(T, Node) {
            return .init(self.value, self.language, limits);
        }

        /// Stream exact surface bytes while retaining each inline language
        /// context. Coordinates follow RealizationSpan's UTF-8 byte contract.
        pub fn surface(self: @This(), start: u32, end: u32) SurfaceError!Surface {
            if (T != model.Representation) @compileError("surface ranges require Representation");
            if (start > end) return error.InvalidRealization;
            return .{
                .cursor = .init(self.value.text.content, self.language.at(&self.value.text), .{}),
                .start = start,
                .end = end,
            };
        }
    };
}

pub const SurfaceError = walk.Error || error{InvalidRealization};
pub const SurfaceFragment = struct { bytes: []const u8, language: walk.Language };

/// A bounded-stack surface range over rich inline structure. Fragments borrow
/// the representation, never flatten or normalize it, and omit markup bytes.
pub const Surface = struct {
    cursor: walk.Cursor(model.Inline),
    start: usize,
    end: usize,
    offset: usize = 0,
    finished: bool = false,
    failed: bool = false,

    pub fn next(self: *Surface) SurfaceError!?SurfaceFragment {
        if (self.failed) return error.InvalidRealization;
        if (self.finished) return null;
        while (try self.cursor.next()) |event| {
            if (event.node.* != .text) continue;
            const text = event.node.text;
            const prior = self.offset;
            self.offset = std.math.add(usize, prior, text.len) catch return self.fail();
            if (self.start > self.offset or self.end < prior) continue;
            const first = @max(self.start, prior) - prior;
            const last = @min(self.end, self.offset) - prior;
            if ((first < text.len and text[first] & 0xc0 == 0x80) or
                (last < text.len and text[last] & 0xc0 == 0x80)) return self.fail();
            if (self.end <= self.offset) self.finished = true;
            if (first == last and self.start != self.end) continue;
            return .{ .bytes = text[first..last], .language = event.language };
        }
        self.finished = true;
        if (self.end > self.offset) return self.fail();
        return null;
    }

    fn fail(self: *Surface) SurfaceError {
        self.failed = true;
        return error.InvalidRealization;
    }
};

fn sliceElement(comptime T: type, comptime field: std.meta.FieldEnum(T)) type {
    if (@typeInfo(T) != .@"struct") @compileError("field projection requires a struct; switch on tagged values first");
    const Field = @FieldType(T, @tagName(field));
    const info = @typeInfo(Field);
    if (info != .pointer or info.pointer.size != .slice)
        @compileError("values projection requires a slice field");
    if (info.pointer.child == u8)
        @compileError("values does not enumerate UTF-8 bytes; use child for a byte-string field");
    return info.pointer.child;
}

pub fn Values(comptime T: type) type {
    return struct {
        const Self = @This();
        remaining: []const T,
        language: walk.Language,

        pub fn next(self: *@This()) ?Match(T) {
            if (self.remaining.len == 0) return null;
            const value = &self.remaining[0];
            self.remaining = self.remaining[1..];
            return contextual(value, self.language);
        }

        pub fn filter(self: Self, context: anytype, comptime predicate: anytype) FilteredIterator(Self, @TypeOf(context), predicate) {
            return makeFilter(self, context, predicate);
        }
    };
}

fn contextual(value: anytype, parent: walk.Language) Match(@TypeOf(value.*)) {
    return .{ .value = value, .language = parent.at(value) };
}

pub fn Selection(comptime kind: model.Kind) type {
    return struct {
        const Self = @This();
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

        pub fn filter(self: Self, context: anytype, comptime predicate: anytype) FilteredIterator(Self, @TypeOf(context), predicate) {
            return makeFilter(self, context, predicate);
        }
    };
}

pub fn entry(value: *const model.Entry) Match(model.Entry) {
    return contextual(value, .{});
}

pub fn resource(value: *const model.Resource) Match(model.Resource) {
    return contextual(value, .{});
}

/// Stable after the resolving cursor is gone: no cursor-borrowed path escapes.
pub const Located = struct {
    node: nodes.NodeRef,
    language: walk.Language,

    pub fn as(self: Located, comptime T: type) ?*const T {
        return self.node.as(T);
    }
};

/// The pointed-to owner must already be at its stable final address.
pub fn located(pointer: anytype) Located {
    return .{ .node = nodes.reference(pointer), .language = walk.Language.at(.{}, pointer) };
}

pub fn documentRoot(value: *const model.Document) Located {
    return switch (value.*) {
        .entry => |*document| located(document),
        .resource => |*document| located(document),
    };
}

/// All metadata-bearing owners in Entry and Resource use this same cursor as
/// admission; declaration order and forward references are immaterial.
pub fn resolve(value: anytype, id: []const u8) nodes.Error!?Located {
    const T = @TypeOf(value.*);
    if (T != model.Entry and T != model.Resource) @compileError("resolve expects Entry or Resource");
    var cursor = nodes.Cursor(T).init(value, .{}, .{});
    while (try cursor.next()) |event| {
        const candidate = event.node.identity() orelse continue;
        if (std.mem.eql(u8, id, candidate)) return .{ .node = event.node, .language = event.language };
    }
    return null;
}

/// The ancestry iterator borrows its selection cursor and expires on the next
/// selection call. Stable node/parent pointers continue to borrow the document.
pub fn StructuralMatch(comptime Root: type, comptime T: type) type {
    const CursorType = nodes.Cursor(Root);
    return struct {
        value: *const T,
        node: nodes.NodeRef,
        parent: ?nodes.NodeRef,
        edge: nodes.Edge,
        depth: usize,
        language: walk.Language,
        _event: CursorType.Event,

        pub fn parentAs(self: @This(), comptime Parent: type) ?*const Parent {
            return if (self.parent) |candidate| candidate.as(Parent) else null;
        }

        pub fn ancestors(self: @This(), comptime Ancestor: type) TypedAncestors(CursorType, Ancestor) {
            return .{ .inner = self._event.ancestors() };
        }
    };
}

fn TypedAncestors(comptime CursorType: type, comptime T: type) type {
    return struct {
        inner: CursorType.Ancestors,

        pub fn next(self: *@This()) ?*const T {
            while (self.inner.next()) |candidate| {
                if (candidate.as(T)) |typed| return typed;
            }
            return null;
        }
    };
}

pub fn StructuralSelection(comptime Root: type, comptime T: type) type {
    return struct {
        const Self = @This();
        cursor: nodes.Cursor(Root),
        skipped_root: bool = false,

        pub fn init(root: *const Root, language: walk.Language, limits: StructuralLimits) Self {
            return .{ .cursor = .init(root, language, limits) };
        }

        pub fn next(self: *Self) nodes.Error!?StructuralMatch(Root, T) {
            while (try self.cursor.next()) |event| {
                if (!self.skipped_root) {
                    self.skipped_root = true;
                    continue;
                }
                if (event.node.as(T)) |typed| return .{
                    .value = typed,
                    .node = event.node,
                    .parent = event.parent,
                    .edge = event.edge,
                    .depth = event.depth,
                    .language = event.language,
                    ._event = event,
                };
            }
            return null;
        }

        pub fn filter(self: Self, context: anytype, comptime predicate: anytype) FilteredIterator(Self, @TypeOf(context), predicate) {
            return makeFilter(self, context, predicate);
        }
    };
}

/// The one filter adapter works over infallible Values and both fallible cursor
/// families. Context is stored by value (usually a pointer or small scalar), so
/// predicates can use runtime names/values without allocation or globals.
pub fn filter(iterator: anytype, context: anytype, comptime predicate: anytype) FilteredIterator(@TypeOf(iterator), @TypeOf(context), predicate) {
    return makeFilter(iterator, context, predicate);
}

fn makeFilter(iterator: anytype, context: anytype, comptime predicate: anytype) FilteredIterator(@TypeOf(iterator), @TypeOf(context), predicate) {
    return .{ .inner = iterator, .context = context };
}

pub fn FilteredIterator(comptime Base: type, comptime Context: type, comptime predicate: anytype) type {
    return struct {
        const Self = @This();
        inner: Base,
        context: Context,

        const Return = @typeInfo(@TypeOf(Base.next)).@"fn".return_type.?;

        pub fn next(self: *Self) Return {
            return switch (@typeInfo(Return)) {
                .optional => infallible: {
                    while (self.inner.next()) |match| {
                        if (predicate(self.context, match)) break :infallible match;
                    }
                    break :infallible null;
                },
                .error_union => fallible: {
                    while (try self.inner.next()) |match| {
                        if (predicate(self.context, match)) break :fallible match;
                    }
                    break :fallible null;
                },
                else => @compileError("filter requires an iterator returning ?T or E!?T"),
            };
        }

        pub fn filter(self: Self, next_context: anytype, comptime next_predicate: anytype) FilteredIterator(Self, @TypeOf(next_context), next_predicate) {
            return makeFilter(self, next_context, next_predicate);
        }
    };
}

pub const DocumentRef = union(enum) {
    entry: *const model.Entry,
    resource: *const model.Resource,
};

pub const FollowTarget = struct { document: DocumentRef, location: Located };
pub const Unresolved = @FieldType(model.Reference, "unresolved");
pub const FollowResult = union(enum) {
    found: FollowTarget,
    unavailable: model.Reference,
    unresolved: Unresolved,
};

pub const FollowSession = struct {
    library: *const model.Library,
    hops_remaining: usize,

    pub const Error = nodes.Error || error{HopLimit};

    pub fn init(library: *const model.Library, max_hops: usize) FollowSession {
        return .{ .library = library, .hops_remaining = max_hops };
    }

    /// Exactly one caller-driven hop; graph cycles consume the explicit budget.
    pub fn followFrom(self: *FollowSession, origin: DocumentRef, reference: model.Reference) Error!FollowResult {
        if (self.hops_remaining == 0) return error.HopLimit;
        self.hops_remaining -= 1;
        return switch (reference) {
            .local => |id| self.local(origin, id, reference),
            .entry => |address| self.entryAddress(address, reference),
            .resource => |address| self.resourceAddress(address, reference),
            .iri => .{ .unavailable = reference },
            .unresolved => |value| .{ .unresolved = value },
        };
    }

    fn local(self: *FollowSession, origin: DocumentRef, id: []const u8, original: model.Reference) Error!FollowResult {
        _ = self;
        const location = switch (origin) {
            .entry => |document| try resolve(document, id),
            .resource => |document| try resolve(document, id),
        } orelse return .{ .unavailable = original };
        return .{ .found = .{ .document = origin, .location = location } };
    }

    fn entryAddress(self: *FollowSession, address: model.Address, original: model.Reference) Error!FollowResult {
        for (self.library.entries) |*document| {
            if (!std.mem.eql(u8, document.id, address.id)) continue;
            const location = if (address.fragment) |fragment|
                (try resolve(document, fragment)) orelse return .{ .unavailable = original }
            else
                located(document);
            return .{ .found = .{ .document = .{ .entry = document }, .location = location } };
        }
        return .{ .unavailable = original };
    }

    fn resourceAddress(self: *FollowSession, address: model.Address, original: model.Reference) Error!FollowResult {
        for (self.library.resources) |*document| {
            if (!std.mem.eql(u8, document.identity(), address.id)) continue;
            const location = if (address.fragment) |fragment|
                (try resolve(document, fragment)) orelse return .{ .unavailable = original }
            else
                located(document);
            return .{ .found = .{ .document = .{ .resource = document }, .location = location } };
        }
        return .{ .unavailable = original };
    }
};
