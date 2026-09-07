//! Typed construction of an immutable proposal-v2 snapshot.
//!
//! Builder handles are deliberately *draft* identities. Compilation assigns
//! physical IDs by preorder, returns the translation, and derives every index
//! from the same canonical node stream. This avoids the seductive but broken
//! assumption that insertion order and wire order are always identical.

const std = @import("std");
const cold = @import("cold.zig");
const columns = @import("columns.zig");
const edges = @import("edges.zig");
const forest = @import("forest.zig");
const keys = @import("keys.zig");
const prose = @import("prose.zig");
const schema = @import("schema.zig");
const snapshot = @import("snapshot.zig");
const text = @import("text.zig");
const wire = @import("wire.zig");

pub const AssertionState = schema.AssertionState;
pub const Certainty = schema.Certainty;

pub const Error = error{
    EmptyForest,
    TooManyNodes,
    DepthLimitExceeded,
    InvalidReference,
    WrongKind,
    ColumnNotApplicable,
    DuplicateColumn,
    MissingRequiredColumn,
    DerivedColumn,
    DuplicateAttribute,
    InvalidAssertion,
    InvalidPredicateRole,
    InvalidUtf8,
    LimitExceeded,
    OutOfMemory,
    InvalidSpan,
    UnsupportedFeature,
};

pub const Options = struct {
    max_nodes: usize = std.math.maxInt(u32),
    max_depth: usize = 4_096,
    prose: prose.Options = .{},
    cold: cold.Limits = .{},
};

pub const Unresolved = struct {
    bytes: []const u8,
    uri: ?[]const u8 = null,
    label: ?[]const u8 = null,
    status: cold.Status = .unresolved,
};

pub const Target = union(enum) {
    node: schema.AnyRef,
    unresolved: Unresolved,
};

pub const Evidence = struct {
    quote: ?[]const u8 = null,
    source: ?schema.AnyRef = null,
    anchor: ?[]const u8 = null,
    certainty: ?schema.Certainty = null,
};

pub const AssertionOptions = struct {
    state: schema.AssertionState = .asserted,
    certainty: ?schema.Certainty = null,
    temporal: ?[]const u8 = null,
    context: ?[]const u8 = null,
    source: ?schema.AnyRef = null,
    evidence: []const Evidence = &.{},
};

/// Owns the bytes and the draft-to-physical translation produced by preorder.
pub const Compiled = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    logical_to_physical: []schema.Node,
    origin: u64,

    pub fn deinit(self: *Compiled) void {
        self.allocator.free(self.bytes);
        self.allocator.free(self.logical_to_physical);
        self.* = undefined;
    }

    /// Resolve a handle returned by Builder into the snapshot's physical ID.
    pub fn resolve(self: *const Compiled, draft: anytype) Error!schema.Node {
        const reference = asAny(draft);
        if (reference.origin != self.origin) return error.InvalidReference;
        const logical = @intFromEnum(reference.id);
        if (logical >= self.logical_to_physical.len) return error.InvalidReference;
        return self.logical_to_physical[logical];
    }
};

const DraftValue = union(schema.Repr) {
    atom: []const u8,
    key: []const u8,
    prose: []const u8,
    node: schema.AnyRef,
    enum_value: u8,
    span: schema.Span,
    bytes: []const u8,
    u64: u64,
    i64: i64,
};

const Cell = struct { id: schema.ColumnId, value: DraftValue };
const Attribute = struct { name: []const u8, value: []const u8 };
const NodeDraft = struct {
    kind: schema.Kind,
    parent: ?u32,
    children: std.ArrayList(u32) = .empty,
    cells: std.ArrayList(Cell) = .empty,
    attributes: std.ArrayList(Attribute) = .empty,
    unresolved: ?Unresolved = null,
};
const EdgeDraft = struct {
    predicate: schema.PredicateId,
    source: schema.AnyRef,
    target: schema.AnyRef,
    qualified: ?schema.AnyRef = null,
};

/// Arena-owned mutable semantic input. All slices passed to mutating methods
/// are copied, so callers may release their input immediately.
pub const Builder = struct {
    var generations = std.atomic.Value(u64).init(1);
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    options: Options,
    origin: u64,
    nodes: std.ArrayList(NodeDraft) = .empty,
    roots: std.ArrayList(u32) = .empty,
    edges: std.ArrayList(EdgeDraft) = .empty,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return initWithOptions(allocator, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, options: Options) Builder {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .options = options,
            .origin = generations.fetchAdd(1, .monotonic),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn root(self: *Builder, comptime kind: schema.Kind, init_value: anytype) !schema.Ref(kind) {
        const mark = self.checkpoint();
        errdefer self.rollback(mark);
        if (kind == .any) @compileError("Kind.any is not a storable node kind");
        const reference = try self.appendNode(kind, null);
        try self.applyInit(reference, init_value);
        return .{ .id = reference.id, .origin = self.origin };
    }

    pub fn child(self: *Builder, parent_value: anytype, comptime kind: schema.Kind, init_value: anytype) !schema.Ref(kind) {
        const mark = self.checkpoint();
        errdefer self.rollback(mark);
        if (kind == .any) @compileError("Kind.any is not a storable node kind");
        const parent = try self.checked(asAny(parent_value));
        const reference = try self.appendNode(kind, @intCast(@intFromEnum(parent.id)));
        try self.applyInit(reference, init_value);
        return .{ .id = reference.id, .origin = self.origin };
    }

    /// Set one schema descriptor. Derived search and shape columns are owned
    /// by the compiler so their profile cannot disagree with their key space.
    pub fn set(self: *Builder, node_value: anytype, comptime Column: type, value: Column.Input) !void {
        comptime assertColumn(Column);
        if (Column.Id == .normalized or Column.Id == .reversed or Column.Id == .shape)
            return error.DerivedColumn;
        try self.setAny(try self.checked(asAny(node_value)), Column, value);
    }

    /// Preserve an arbitrary extension attribute. Names and values are copied;
    /// canonical name ordering is imposed only when the cold section is built.
    pub fn attribute(self: *Builder, node_value: anytype, name: []const u8, value: []const u8) !void {
        const node = try self.checked(asAny(node_value));
        if (node.kind != .extension) return error.WrongKind;
        if (name.len == 0 or !std.unicode.utf8ValidateSlice(name) or !std.unicode.utf8ValidateSlice(value))
            return error.InvalidUtf8;
        const draft = &self.nodes.items[@intFromEnum(node.id)];
        for (draft.attributes.items) |existing| if (std.mem.eql(u8, existing.name, name)) return error.DuplicateAttribute;
        try draft.attributes.append(self.arena.allocator(), .{
            .name = try self.copy(name),
            .value = try self.copy(value),
        });
    }

    /// Attach a stable qualified identity `(source ordinal, local bytes)`.
    pub fn externalId(self: *Builder, node_value: anytype, source_ordinal: u32, local: []const u8) !void {
        const qualified = text.externalId(self.arena.allocator(), source_ordinal, local) catch |err| return mapText(err);
        try self.set(node_value, schema.columns.external_id, qualified);
    }

    /// Add an unqualified binary edge. Predicate roles are checked now; the
    /// compiler checks them again after preorder remapping at the wire boundary.
    pub fn link(self: *Builder, comptime predicate: schema.PredicateSpec, source_value: anytype, target_value: anytype) !void {
        comptime schema.assertPredicate(predicate);
        if (predicate.arity != .binary) return error.InvalidAssertion;
        const source = try self.checked(asAny(source_value));
        const target = try self.checked(asAny(target_value));
        try requireRoleKind(predicate, .source, source.kind);
        try requireRoleKind(predicate, .target, target.kind);
        try self.edges.append(self.arena.allocator(), .{
            .predicate = predicate.id,
            .source = source,
            .target = target,
        });
    }

    /// Create a qualified assertion under its owning root and materialize its
    /// source×target shadow edges. Participant order remains source order in
    /// the forest; edge order is canonicalized independently.
    pub fn assertion(
        self: *Builder,
        comptime predicate: schema.PredicateSpec,
        owner_value: anytype,
        participant_values: anytype,
        options: AssertionOptions,
    ) !schema.Ref(.assertion) {
        comptime schema.assertPredicate(predicate);
        const mark = self.checkpoint();
        errdefer self.rollback(mark);
        const owner = try self.checked(asAny(owner_value));
        if (predicate.owner != .any and owner.kind != predicate.owner) return error.WrongKind;
        const root_index = try self.rootOfDraft(@intCast(@intFromEnum(owner.id)));
        const assertion_ref = try self.child(self.anyAt(root_index), .assertion, .{});
        try self.set(assertion_ref, schema.columns.predicate, predicate.name);
        try self.set(assertion_ref, schema.columns.state, options.state);
        if (options.certainty) |value| try self.set(assertion_ref, schema.columns.certainty, value);
        if (options.temporal) |value| try self.set(assertion_ref, schema.columns.temporal, value);
        if (options.context) |value| try self.set(assertion_ref, schema.columns.context, value);
        if (options.source) |value| try self.set(assertion_ref, schema.columns.source, value);

        var role_counts = [_]usize{0} ** @typeInfo(schema.Role).@"enum".fields.len;
        inline for (participant_values) |input| {
            const role: schema.Role = input.role;
            const role_spec = findRole(predicate, role) orelse return error.InvalidPredicateRole;
            role_counts[@intFromEnum(role)] += 1;
            const participant_ref = try self.child(assertion_ref, .participant, .{});
            try self.set(participant_ref, schema.columns.role, @tagName(role));
            switch (input.target) {
                .node => |raw_target| {
                    const target = try self.checked(raw_target);
                    if (target.kind != role_spec.kind) return error.WrongKind;
                    try self.set(participant_ref, schema.columns.target, target);
                },
                .unresolved => |raw_target| {
                    const stored = try self.copyUnresolved(raw_target);
                    self.nodes.items[@intFromEnum(participant_ref.id)].unresolved = stored;
                },
            }
        }
        inline for (predicate.roles) |role| {
            const count = role_counts[@intFromEnum(role.role)];
            if (count == 0 or (role.cardinality == .one and count != 1)) return error.InvalidAssertion;
        }
        for (options.evidence) |input| {
            const evidence_ref = try self.child(assertion_ref, .evidence, .{});
            if (input.quote) |value| try self.set(evidence_ref, schema.columns.quote, value);
            if (input.source) |value| try self.set(evidence_ref, schema.columns.source, value);
            if (input.anchor) |value| try self.set(evidence_ref, schema.columns.anchor, value);
            if (input.certainty) |value| try self.set(evidence_ref, schema.columns.certainty, value);
        }
        return assertion_ref;
    }

    /// Runtime vocabulary uses the same assertion/participant representation.
    /// Roles are explicit strings, targets may be unresolved or point to other
    /// assertions (including cycles), and unary statements are first-class.
    /// Reserved built-in names must go through their checked descriptors.
    pub fn runtimeAssertion(self: *Builder, name: []const u8, owner_value: anytype, participants: anytype, options: AssertionOptions) !schema.Ref(.assertion) {
        const mark = self.checkpoint();
        errdefer self.rollback(mark);
        if (name.len == 0 or participants.len == 0) return error.InvalidAssertion;
        inline for (schema.predicateTypes()) |P| if (std.mem.eql(u8, name, P.name)) return error.InvalidAssertion;
        const owner = try self.checked(asAny(owner_value));
        const root_index = try self.rootOfDraft(@intFromEnum(owner.id));
        const statement = try self.child(self.anyAt(root_index), .assertion, .{ .predicate = name, .state = options.state });
        if (options.certainty) |value| try self.set(statement, schema.columns.certainty, value);
        if (options.temporal) |value| try self.set(statement, schema.columns.temporal, value);
        if (options.context) |value| try self.set(statement, schema.columns.context, value);
        if (options.source) |value| try self.set(statement, schema.columns.source, value);
        inline for (participants) |input| {
            const role: []const u8 = input.role;
            if (role.len == 0) return error.InvalidPredicateRole;
            const participant_ref = try self.child(statement, .participant, .{ .role = role });
            switch (input.target) {
                .node => |target| try self.set(participant_ref, schema.columns.target, target),
                .unresolved => |target| self.nodes.items[@intFromEnum(participant_ref.id)].unresolved = try self.copyUnresolved(target),
            }
        }
        for (options.evidence) |input| _ = try self.child(statement, .evidence, input);
        return statement;
    }

    /// Compile through a single canonical preorder and validate the finished
    /// snapshot before returning ownership to the caller.
    pub fn compile(self: *const Builder) !Compiled {
        if (self.nodes.items.len == 0 or self.roots.items.len == 0) return error.EmptyForest;
        if (self.nodes.items.len > self.options.max_nodes or self.nodes.items.len > std.math.maxInt(u32))
            return error.TooManyNodes;
        try self.validateDrafts();

        var work_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer work_arena.deinit();
        const work = work_arena.allocator();
        const order = try makePreorder(self, work);

        const subtree = try work.alloc(u32, order.new_to_old.len);
        const parent_delta = try work.alloc(u32, order.new_to_old.len);
        const node_kinds = try work.alloc(schema.Kind, order.new_to_old.len);
        const root_ids = try work.alloc(u32, self.roots.items.len);
        try fillForest(self, order, subtree, parent_delta, node_kinds, root_ids);
        const forest_owned = try forest.encode(work, subtree, parent_delta, root_ids, node_kinds);
        const forest_view = try forest.View.open(forest_owned.bytes);

        var spaces: [keySpaceCount()]Space = @splat(.{});
        try collectIndexes(self, work, order, node_kinds, &spaces);
        var key_owned: [keySpaceCount()]keys.Owned = undefined;
        var key_views: [keySpaceCount()]keys.View = undefined;
        inline for (schema.keySpaceTypes()) |spec| {
            const index = @intFromEnum(spec.id);
            key_owned[index] = try buildSpace(work, spec, forest_view.count, &spaces[index]);
            key_views[index] = try keys.View.open(key_owned[index].bytes);
        }

        const prose_ordinals = try assignProseOrdinals(self, work, order);
        const column_input = try buildColumns(self, work, order, node_kinds, &key_views, prose_ordinals, &spaces);
        const columns_owned = try columns.build(work, &forest_view, column_input);
        const edges_owned = try buildEdges(self, work, order);
        const prose_owned = try buildProse(self, work, order, subtree, root_ids);
        const cold_owned = try buildCold(self, work, order);
        const manifest = schema.manifest;

        var section_input: [13]snapshot.SectionInput = undefined;
        var section_count: usize = 0;
        appendSection(&section_input, &section_count, .{ .kind = .schema, .bytes = manifest, .items = schema.columnTypes().len });
        appendSection(&section_input, &section_count, .{ .kind = .forest, .bytes = forest_owned.bytes, .items = @intCast(order.new_to_old.len) });
        appendSection(&section_input, &section_count, .{ .kind = .columns, .bytes = columns_owned.bytes, .items = schema.columnTypes().len });
        inline for (schema.keySpaceTypes()) |spec| {
            const index = @intFromEnum(spec.id);
            appendSection(&section_input, &section_count, .{
                .kind = sectionForKeySpace(spec.id),
                .bytes = key_owned[index].bytes,
                .items = key_views[index].key_count,
                .flags = keyFlags(spec.id),
                .profile = if (spec.profile_bound) text.profile else 0,
            });
        }
        // Key-space enum order places atoms last, but container sections place
        // it first. Sort the tiny descriptor array, never the payload itself.
        std.mem.sortUnstable(snapshot.SectionInput, section_input[0..section_count], {}, lessSection);
        appendSection(&section_input, &section_count, .{ .kind = .edges, .bytes = edges_owned.bytes, .items = @intCast(self.edges.items.len) });
        appendSection(&section_input, &section_count, .{ .kind = .prose, .bytes = prose_owned.bytes, .items = @intCast(prose_ordinals.count), .flags = snapshot.required | snapshot.cold });
        appendSection(&section_input, &section_count, .{ .kind = .cold, .bytes = cold_owned.bytes, .items = @intCast(coldRecords(self)), .flags = snapshot.cold });
        std.mem.sortUnstable(snapshot.SectionInput, section_input[0..section_count], {}, lessSection);

        var owned = try snapshot.write(self.allocator, .{ .profile_id = text.profile_digest }, section_input[0..section_count]);
        errdefer owned.deinit();
        const physical = try self.allocator.alloc(schema.Node, order.old_to_new.len);
        errdefer self.allocator.free(physical);
        for (order.old_to_new, 0..) |id, i| physical[i] = @enumFromInt(id);

        const checked_snapshot = try snapshot.Snapshot.open(owned.bytes, .{ .profile_id = text.profile_digest });
        try checked_snapshot.validateDeep(self.allocator);
        return .{
            .allocator = self.allocator,
            .bytes = owned.bytes,
            .logical_to_physical = physical,
            .origin = self.origin,
        };
    }

    fn appendNode(self: *Builder, kind: schema.Kind, parent: ?u32) !schema.AnyRef {
        if (self.nodes.items.len >= self.options.max_nodes or self.nodes.items.len >= std.math.maxInt(u32))
            return error.TooManyNodes;
        if (!schema.legalParent(if (parent) |p| self.nodes.items[p].kind else null, kind)) return error.WrongKind;
        const index: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.arena.allocator(), .{ .kind = kind, .parent = parent });
        if (parent) |p| {
            if (p >= index) return error.InvalidReference;
            try self.nodes.items[p].children.append(self.arena.allocator(), index);
        } else try self.roots.append(self.arena.allocator(), index);
        return .{ .id = @enumFromInt(index), .kind = kind, .origin = self.origin };
    }

    fn applyInit(self: *Builder, reference: schema.AnyRef, init_value: anytype) !void {
        const T = @TypeOf(init_value);
        const info = @typeInfo(T);
        if (info != .@"struct") @compileError("node initializer must be a struct literal");
        inline for (info.@"struct".fields) |field| {
            const Column = schema.columnByName(field.name);
            const value = @field(init_value, field.name);
            switch (@typeInfo(field.type)) {
                .optional => if (value) |present| try self.set(reference, Column, present),
                else => try self.set(reference, Column, value),
            }
        }
    }

    fn setAny(self: *Builder, reference: schema.AnyRef, comptime Column: type, value: Column.Input) !void {
        if (!Column.over.has(reference.kind)) return error.ColumnNotApplicable;
        const node = &self.nodes.items[@intFromEnum(reference.id)];
        for (node.cells.items) |cell| if (cell.id == Column.Id) return error.DuplicateColumn;
        const stored: DraftValue = switch (Column.repr) {
            .atom => .{ .atom = try self.copyText(value) },
            .key => .{ .key = try self.copyText(value) },
            .prose => .{ .prose = try self.copyText(value) },
            .node => .{ .node = try self.checked(value) },
            .enum_value => .{ .enum_value = enumByte(value) },
            .span => .{ .span = value },
            .bytes => .{ .bytes = try self.copy(value) },
            .u64 => .{ .u64 = value },
            .i64 => .{ .i64 = value },
        };
        if (Column.repr == .span and stored.span.end < stored.span.start) return error.LimitExceeded;
        try node.cells.append(self.arena.allocator(), .{ .id = Column.Id, .value = stored });
    }

    fn checked(self: *const Builder, reference: schema.AnyRef) Error!schema.AnyRef {
        if (reference.origin != self.origin) return error.InvalidReference;
        const index = @intFromEnum(reference.id);
        if (index >= self.nodes.items.len) return error.InvalidReference;
        if (self.nodes.items[index].kind != reference.kind) return error.WrongKind;
        return reference;
    }

    const Checkpoint = struct { nodes: usize, roots: usize, edges: usize };

    fn checkpoint(self: *const Builder) Checkpoint {
        return .{ .nodes = self.nodes.items.len, .roots = self.roots.items.len, .edges = self.edges.items.len };
    }

    // Failed compound mutations are semantically atomic. Arena capacity may
    // remain reusable, but no partially initialized node is ever observable.
    fn rollback(self: *Builder, mark: Checkpoint) void {
        self.nodes.shrinkRetainingCapacity(mark.nodes);
        self.roots.shrinkRetainingCapacity(mark.roots);
        self.edges.shrinkRetainingCapacity(mark.edges);
        for (self.nodes.items) |*node| {
            while (node.children.items.len != 0 and node.children.items[node.children.items.len - 1] >= mark.nodes)
                _ = node.children.pop();
        }
    }

    fn anyAt(self: *const Builder, index: u32) schema.AnyRef {
        return .{ .id = @enumFromInt(index), .kind = self.nodes.items[index].kind, .origin = self.origin };
    }

    fn rootOfDraft(self: *const Builder, start: u32) Error!u32 {
        var node = start;
        var depth: usize = 0;
        while (self.nodes.items[node].parent) |parent| {
            depth += 1;
            if (depth > self.options.max_depth) return error.DepthLimitExceeded;
            node = parent;
        }
        return node;
    }

    fn copy(self: *Builder, bytes: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, bytes);
    }

    fn copyText(self: *Builder, bytes: []const u8) ![]const u8 {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        return self.copy(bytes);
    }

    fn copyUnresolved(self: *Builder, value: Unresolved) !Unresolved {
        if (!std.unicode.utf8ValidateSlice(value.bytes) or
            (value.uri != null and !std.unicode.utf8ValidateSlice(value.uri.?)) or
            (value.label != null and !std.unicode.utf8ValidateSlice(value.label.?))) return error.InvalidUtf8;
        return .{
            .bytes = try self.copy(value.bytes),
            .uri = if (value.uri) |v| try self.copy(v) else null,
            .label = if (value.label) |v| try self.copy(v) else null,
            .status = value.status,
        };
    }

    fn validateDrafts(self: *const Builder) !void {
        for (self.nodes.items) |draft| {
            if (!schema.legalParent(if (draft.parent) |p| self.nodes.items[p].kind else null, draft.kind)) return error.WrongKind;
            for (draft.cells.items) |cell| if (cell.value == .node) {
                _ = try self.checked(cell.value.node);
            };
            if (findCell(draft.cells.items, .span)) |cell| {
                var parent = draft.parent;
                var surface: ?[]const u8 = null;
                while (parent) |id| : (parent = self.nodes.items[id].parent) {
                    const owner = self.nodes.items[id];
                    if (owner.kind == .form or owner.kind == .variant or owner.kind == .inflection) {
                        surface = (findCell(owner.cells.items, .written) orelse return error.MissingRequiredColumn).value.key;
                        break;
                    }
                }
                const bytes = surface orelse return error.InvalidSpan;
                const span = cell.value.span;
                var length: u64 = 0;
                switch (span.unit) {
                    .byte => length = bytes.len,
                    .utf8_codepoint, .utf16_code_unit => {
                        var iterator = (try std.unicode.Utf8View.init(bytes)).iterator();
                        while (iterator.nextCodepoint()) |point| length += if (span.unit == .utf16_code_unit and point > 0xffff) @as(u64, 2) else 1;
                    },
                    .grapheme => return error.UnsupportedFeature,
                }
                if (span.end < span.start or span.end > length) return error.InvalidSpan;
            }
            if (draft.kind == .participant) {
                const target = findCell(draft.cells.items, .target);
                if ((target != null) == (draft.unresolved != null)) return error.InvalidAssertion;
            }
            if (draft.kind != .assertion) continue;
            const name = (findCell(draft.cells.items, .predicate) orelse return error.MissingRequiredColumn).value.atom;
            var known = false;
            inline for (schema.predicateTypes()) |P| if (std.mem.eql(u8, name, P.name)) {
                known = true;
                var counts = [_]usize{0} ** @typeInfo(schema.Role).@"enum".fields.len;
                for (draft.children.items) |child_id| {
                    const child_draft = self.nodes.items[child_id];
                    if (child_draft.kind != .participant) continue;
                    const role_name = (findCell(child_draft.cells.items, .role) orelse return error.MissingRequiredColumn).value.atom;
                    var matched = false;
                    for (P.roles) |role| if (std.mem.eql(u8, role_name, @tagName(role.role))) {
                        matched = true;
                        counts[@intFromEnum(role.role)] += 1;
                        if (findCell(child_draft.cells.items, .target)) |target|
                            if (target.value.node.kind != role.kind) return error.WrongKind;
                    };
                    if (!matched) return error.InvalidPredicateRole;
                }
                for (P.roles) |role| {
                    const count = counts[@intFromEnum(role.role)];
                    if (count == 0 or (role.cardinality == .one and count != 1)) return error.InvalidAssertion;
                }
            };
            if (!known) {
                if (name.len == 0) return error.InvalidAssertion;
                var participants: usize = 0;
                for (draft.children.items) |id| if (self.nodes.items[id].kind == .participant) {
                    participants += 1;
                };
                if (participants == 0) return error.InvalidAssertion;
            }
        }
    }
};

const Order = struct { old_to_new: []u32, new_to_old: []u32 };

fn makePreorder(builder: *const Builder, allocator: std.mem.Allocator) !Order {
    const count = builder.nodes.items.len;
    const old_to_new = try allocator.alloc(u32, count);
    @memset(old_to_new, std.math.maxInt(u32));
    const new_to_old = try allocator.alloc(u32, count);
    const Frame = struct { node: u32, next_child: usize = 0 };
    const stack = try allocator.alloc(Frame, if (builder.options.max_depth >= count) count else builder.options.max_depth + 1);
    var cursor: usize = 0;
    for (builder.roots.items) |root| {
        if (root >= count or builder.nodes.items[root].parent != null) return error.InvalidReference;
        stack[0] = .{ .node = root };
        var depth: usize = 1;
        while (depth != 0) {
            const frame = &stack[depth - 1];
            const node = builder.nodes.items[frame.node];
            if (frame.next_child == 0) {
                if (old_to_new[frame.node] != std.math.maxInt(u32)) return error.InvalidReference;
                old_to_new[frame.node] = @intCast(cursor);
                new_to_old[cursor] = frame.node;
                cursor += 1;
            }
            if (frame.next_child == node.children.items.len) {
                depth -= 1;
                continue;
            }
            const child = node.children.items[frame.next_child];
            frame.next_child += 1;
            if (child >= count or builder.nodes.items[child].parent != frame.node) return error.InvalidReference;
            if (depth == stack.len) return error.DepthLimitExceeded;
            stack[depth] = .{ .node = child };
            depth += 1;
        }
    }
    if (cursor != count) return error.InvalidReference;
    return .{ .old_to_new = old_to_new, .new_to_old = new_to_old };
}

fn fillForest(
    builder: *const Builder,
    order: Order,
    subtree: []u32,
    parents: []u32,
    kinds: []schema.Kind,
    roots: []u32,
) !void {
    for (order.new_to_old, 0..) |old, physical| {
        const draft = builder.nodes.items[old];
        kinds[physical] = draft.kind;
        parents[physical] = if (draft.parent) |parent| blk: {
            const mapped = order.old_to_new[parent];
            if (mapped >= physical) return error.InvalidReference;
            break :blk @intCast(physical - mapped);
        } else 0;
        subtree[physical] = 1;
    }
    var reverse = order.new_to_old.len;
    while (reverse != 0) {
        reverse -= 1;
        if (parents[reverse] != 0) {
            const parent = reverse - parents[reverse];
            subtree[parent] = std.math.add(u32, subtree[parent], subtree[reverse]) catch return error.LimitExceeded;
        }
    }
    for (builder.roots.items, 0..) |root, i| roots[i] = order.old_to_new[root];
}

const Occurrence = struct { key: []const u8, node: u32 };
const Space = struct { values: std.ArrayList(Occurrence) = .empty };

fn collectIndexes(
    builder: *const Builder,
    allocator: std.mem.Allocator,
    order: Order,
    kinds: []const schema.Kind,
    spaces: *[keySpaceCount()]Space,
) !void {
    for (order.new_to_old, 0..) |old, physical| {
        const draft = builder.nodes.items[old];
        for (draft.cells.items) |cell| switch (cell.value) {
            .atom => |value| try addOccurrence(allocator, spaces, .atoms, value, @intCast(physical)),
            .key => |value| {
                var maybe_space: ?schema.KeySpaceId = null;
                inline for (schema.columnTypes()) |Column| if (cell.id == Column.Id) {
                    maybe_space = Column.keySpace();
                };
                const space = maybe_space orelse return error.InvalidReference;
                try addOccurrence(allocator, spaces, space, value, @intCast(physical));
                if (cell.id == .headword or cell.id == .written) {
                    const normalized = text.normalize(allocator, value) catch |err| return mapText(err);
                    const reversed = text.reverseScalars(allocator, normalized) catch |err| return mapText(err);
                    try addOccurrence(allocator, spaces, .normalized, normalized, @intCast(physical));
                    try addOccurrence(allocator, spaces, .reversed, reversed, @intCast(physical));
                }
            },
            .prose => |value| {
                var terms = text.terms(value) catch |err| return mapText(err);
                while (terms.next()) |term| {
                    const normalized = text.normalize(allocator, term) catch |err| return mapText(err);
                    try addOccurrence(allocator, spaces, .terms, normalized, @intCast(physical));
                }
            },
            else => {},
        };
        for (draft.attributes.items) |attribute| try addOccurrence(allocator, spaces, .atoms, attribute.name, @intCast(physical));
        if (draft.kind == .extension and draft.attributes.items.len != 0) {
            const shape = try makeShape(allocator, draft.attributes.items);
            try addOccurrence(allocator, spaces, .shapes, shape, @intCast(physical));
        }
    }
    // Validate key-space kind domains before any bytes are emitted.
    inline for (schema.keySpaceTypes()) |spec| if (spec.postings) {
        for (spaces[@intFromEnum(spec.id)].values.items) |item|
            if (!spec.targets.has(kinds[item.node])) return error.WrongKind;
    };
}

fn addOccurrence(allocator: std.mem.Allocator, spaces: *[keySpaceCount()]Space, id: schema.KeySpaceId, value: []const u8, node: u32) !void {
    try spaces[@intFromEnum(id)].values.append(allocator, .{ .key = value, .node = node });
}

fn makeShape(allocator: std.mem.Allocator, attributes: []const Attribute) ![]const u8 {
    const order = try allocator.alloc(usize, attributes.len);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sortUnstable(usize, order, attributes, struct {
        fn less(values: []const Attribute, a: usize, b: usize) bool {
            return std.mem.lessThan(u8, values[a].name, values[b].name);
        }
    }.less);
    var size: usize = 0;
    for (order) |i| {
        var buffer: [32]u8 = undefined;
        const length = try std.fmt.bufPrint(&buffer, "{d}:", .{attributes[i].name.len});
        size = try wire.add(size, try wire.add(attributes[i].name.len, length.len));
    }
    const result = try allocator.alloc(u8, size);
    var at: usize = 0;
    for (order) |i| {
        const name = attributes[i].name;
        const length = try std.fmt.bufPrint(result[at..], "{d}:", .{name.len});
        at += length.len;
        @memcpy(result[at..][0..name.len], name);
        at += name.len;
    }
    return result;
}

fn buildSpace(allocator: std.mem.Allocator, spec: schema.KeySpaceSpec, universe: usize, space: *Space) !keys.Owned {
    std.mem.sortUnstable(Occurrence, space.values.items, {}, lessOccurrence);
    var builder = if (spec.postings)
        try keys.Builder.keysWithUniverse(allocator, universe)
    else
        keys.Builder.atoms(allocator);
    defer builder.deinit();
    var cursor: usize = 0;
    while (cursor < space.values.items.len) {
        const start = cursor;
        const key = space.values.items[cursor].key;
        while (cursor < space.values.items.len and std.mem.eql(u8, key, space.values.items[cursor].key)) : (cursor += 1) {}
        if (spec.postings) {
            const postings = try allocator.alloc(u64, cursor - start);
            for (space.values.items[start..cursor], 0..) |item, i| postings[i] = item.node;
            try builder.addWithPostings(key, postings);
        } else try builder.addBytes(key);
    }
    return builder.encode();
}

const ProseOrdinals = struct { by_node: []u32, count: usize };

fn assignProseOrdinals(builder: *const Builder, allocator: std.mem.Allocator, order: Order) !ProseOrdinals {
    const by_node = try allocator.alloc(u32, order.new_to_old.len);
    @memset(by_node, std.math.maxInt(u32));
    var count: usize = 0;
    for (order.new_to_old, 0..) |old, physical| for (builder.nodes.items[old].cells.items) |cell| if (cell.value == .prose) {
        by_node[physical] = @intCast(count);
        count += 1;
    };
    return .{ .by_node = by_node, .count = count };
}

fn buildColumns(
    builder: *const Builder,
    allocator: std.mem.Allocator,
    order: Order,
    kinds: []const schema.Kind,
    key_views: *const [keySpaceCount()]keys.View,
    prose_ordinals: ProseOrdinals,
    spaces: *const [keySpaceCount()]Space,
) ![]columns.Input {
    var result: std.ArrayList(columns.Input) = .empty;
    var scratch: [keys.max_key_bytes]u8 = undefined;
    inline for (schema.columnTypes()) |Column| {
        for (order.new_to_old, 0..) |old, physical| {
            if (!Column.over.has(kinds[physical])) continue;
            const draft = builder.nodes.items[old];
            if (findCell(draft.cells.items, Column.Id)) |cell| {
                try result.append(allocator, .{
                    .node = @intCast(physical),
                    .id = Column.Id,
                    .value = try lowerValue(Column, cell.value, order, key_views, prose_ordinals.by_node[physical], &scratch),
                });
                continue;
            }
            if (Column.Id == .normalized or Column.Id == .reversed) {
                const source = findCell(draft.cells.items, if (kinds[physical] == .entry or kinds[physical] == .lexeme) .headword else .written);
                if (source) |cell| {
                    const normalized = text.normalize(allocator, cell.value.key) catch |err| return mapText(err);
                    const derived = if (Column.Id == .normalized) normalized else text.reverseScalars(allocator, normalized) catch |err| return mapText(err);
                    const space: schema.KeySpaceId = if (Column.Id == .normalized) .normalized else .reversed;
                    const hit = (try key_views[@intFromEnum(space)].exact(derived, &scratch)) orelse return error.InvalidReference;
                    try result.append(allocator, .{ .node = @intCast(physical), .id = Column.Id, .value = .{ .key = hit.ordinal } });
                }
                continue;
            }
            if (Column.Id == .shape and draft.attributes.items.len != 0) {
                const shape = try makeShape(allocator, draft.attributes.items);
                const hit = (try key_views[@intFromEnum(schema.KeySpaceId.shapes)].exact(shape, &scratch)) orelse return error.InvalidReference;
                try result.append(allocator, .{ .node = @intCast(physical), .id = Column.Id, .value = .{ .key = hit.ordinal } });
                continue;
            }
            if (Column.presence == .required) return error.MissingRequiredColumn;
        }
    }
    _ = spaces;
    return result.toOwnedSlice(allocator);
}

fn lowerValue(
    comptime Column: type,
    value: DraftValue,
    order: Order,
    key_views: *const [keySpaceCount()]keys.View,
    prose_ordinal: u32,
    scratch: []u8,
) !columns.Value {
    return switch (Column.repr) {
        .atom => blk: {
            const hit = (try key_views[@intFromEnum(schema.KeySpaceId.atoms)].exact(value.atom, scratch)) orelse return error.InvalidReference;
            break :blk .{ .atom = hit.ordinal };
        },
        .key => blk: {
            const space = Column.keySpace() orelse return error.InvalidReference;
            const hit = (try key_views[@intFromEnum(space)].exact(value.key, scratch)) orelse return error.InvalidReference;
            break :blk .{ .key = hit.ordinal };
        },
        .prose => if (prose_ordinal == std.math.maxInt(u32)) error.InvalidReference else .{ .prose = prose_ordinal },
        .node => blk: {
            const old = @intFromEnum(value.node.id);
            if (old >= order.old_to_new.len) return error.InvalidReference;
            break :blk .{ .node = order.old_to_new[old] };
        },
        .enum_value => .{ .enum_value = value.enum_value },
        .span => .{ .span = value.span },
        .bytes => .{ .bytes = value.bytes },
        .u64 => .{ .u64 = value.u64 },
        .i64 => .{ .i64 = value.i64 },
    };
}

fn buildEdges(builder: *const Builder, allocator: std.mem.Allocator, order: Order) !edges.Owned {
    var input: std.ArrayList(edges.Input) = .empty;
    for (builder.edges.items) |edge| try input.append(allocator, .{
        .predicate = edge.predicate,
        .source = try remap(order, edge.source),
        .target = try remap(order, edge.target),
        .qualified = if (edge.qualified) |value| try remap(order, value) else null,
    });
    // Shadows are derived from canonical assertions, including ones assembled
    // incrementally with forward references. There is no second mutable graph
    // whose bookkeeping the caller must somehow remember to update.
    for (builder.nodes.items, 0..) |statement, old| {
        if (statement.kind != .assertion) continue;
        const name = (findCell(statement.cells.items, .predicate) orelse return error.InvalidAssertion).value.atom;
        var predicate: schema.PredicateId = .extension;
        inline for (schema.predicateTypes()) |P| if (std.mem.eql(u8, name, P.name)) {
            predicate = P.id;
        };
        for (statement.children.items) |source_id| {
            const source = builder.nodes.items[source_id];
            const source_role = findCell(source.cells.items, .role) orelse continue;
            if (!std.mem.eql(u8, source_role.value.atom, "source")) continue;
            const source_target = findCell(source.cells.items, .target) orelse continue;
            for (statement.children.items) |target_id| {
                const target = builder.nodes.items[target_id];
                const target_role = findCell(target.cells.items, .role) orelse continue;
                if (!std.mem.eql(u8, target_role.value.atom, "target")) continue;
                const target_target = findCell(target.cells.items, .target) orelse continue;
                try input.append(allocator, .{ .predicate = predicate, .source = try remap(order, source_target.value.node), .target = try remap(order, target_target.value.node), .qualified = order.old_to_new[old] });
            }
        }
    }
    return edges.build(allocator, order.new_to_old.len, input.items);
}

fn buildProse(builder: *const Builder, allocator: std.mem.Allocator, order: Order, subtree: []const u32, roots: []const u32) !prose.OwnedStore {
    var all_items: std.ArrayList(prose.ItemInput) = .empty;
    for (order.new_to_old, 0..) |old, physical| for (builder.nodes.items[old].cells.items) |cell| if (cell.value == .prose)
        try all_items.append(allocator, .{ .node = physical, .text = cell.value.prose });
    const root_input = try allocator.alloc(prose.RootInput, roots.len);
    var cursor: usize = 0;
    for (roots, 0..) |root, i| {
        const end = @as(usize, root) + subtree[root];
        const start = cursor;
        while (cursor < all_items.items.len and all_items.items[cursor].node < end) : (cursor += 1) {}
        root_input[i] = .{ .root = root, .items = all_items.items[start..cursor] };
    }
    if (cursor != all_items.items.len) return error.InvalidReference;
    return prose.build(allocator, root_input, builder.options.prose);
}

fn buildCold(builder: *const Builder, allocator: std.mem.Allocator, order: Order) !cold.Owned {
    const records = try allocator.alloc(cold.RecordInput, coldRecords(builder));
    var cursor: usize = 0;
    for (order.new_to_old, 0..) |old, physical| {
        const draft = builder.nodes.items[old];
        if (draft.attributes.items.len == 0 and draft.unresolved == null) continue;
        const attributes = try allocator.alloc(cold.AttributeInput, draft.attributes.items.len);
        for (draft.attributes.items, 0..) |attribute, i| attributes[i] = .{ .name = attribute.name, .value = attribute.value };
        records[cursor] = .{
            .node = @intCast(physical),
            .attributes = attributes,
            .unresolved = if (draft.unresolved) |target| .{
                .bytes = target.bytes,
                .uri = target.uri,
                .label = target.label,
                .status = target.status,
            } else null,
        };
        cursor += 1;
    }
    return cold.build(allocator, order.new_to_old.len, records, builder.options.cold);
}

fn coldRecords(builder: *const Builder) usize {
    var count: usize = 0;
    for (builder.nodes.items) |node| if (node.attributes.items.len != 0 or node.unresolved != null) {
        count += 1;
    };
    return count;
}

fn remap(order: Order, reference: schema.AnyRef) Error!u32 {
    const old = @intFromEnum(reference.id);
    if (old >= order.old_to_new.len) return error.InvalidReference;
    return order.old_to_new[old];
}

fn findCell(cells: []const Cell, id: schema.ColumnId) ?Cell {
    for (cells) |cell| if (cell.id == id) return cell;
    return null;
}

fn findRole(comptime predicate: schema.PredicateSpec, wanted: schema.Role) ?schema.RoleSpec {
    inline for (predicate.roles) |role| if (role.role == wanted) return role;
    return null;
}

fn requireRoleKind(comptime predicate: schema.PredicateSpec, role: schema.Role, kind: schema.Kind) Error!void {
    const spec = findRole(predicate, role) orelse return error.InvalidPredicateRole;
    if (spec.kind != kind) return error.WrongKind;
}

fn asAny(value: anytype) schema.AnyRef {
    const T = @TypeOf(value);
    if (T == schema.AnyRef) return value;
    if (@hasDecl(T, "Kind") and @hasDecl(T, "any")) return value.any();
    @compileError("expected schema.AnyRef or a typed schema.Ref(kind)");
}

fn enumByte(value: anytype) u8 {
    return switch (@typeInfo(@TypeOf(value))) {
        .@"enum" => @intCast(@intFromEnum(value)),
        .int, .comptime_int => @intCast(value),
        else => @compileError("enum-backed column expects an enum or integer"),
    };
}

fn keySpaceCount() comptime_int {
    return @typeInfo(schema.KeySpaceId).@"enum".fields.len;
}

fn sectionForKeySpace(id: schema.KeySpaceId) snapshot.SectionKind {
    return switch (id) {
        .atoms => .atoms,
        .headword => .key_headword,
        .normalized => .key_normalized,
        .reversed => .key_reversed,
        .external_ids => .key_external,
        .terms => .key_terms,
        .shapes => .key_shapes,
    };
}

fn keyFlags(id: schema.KeySpaceId) u4 {
    return snapshot.required | switch (id) {
        .external_ids, .terms, .shapes => snapshot.cold,
        else => 0,
    };
}

fn appendSection(out: []snapshot.SectionInput, count: *usize, value: snapshot.SectionInput) void {
    out[count.*] = value;
    count.* += 1;
}

fn lessSection(_: void, a: snapshot.SectionInput, b: snapshot.SectionInput) bool {
    return @intFromEnum(a.kind) < @intFromEnum(b.kind);
}

fn lessOccurrence(_: void, a: Occurrence, b: Occurrence) bool {
    return switch (std.mem.order(u8, a.key, b.key)) {
        .lt => true,
        .gt => false,
        .eq => a.node < b.node,
    };
}

fn assertColumn(comptime Column: type) void {
    schema.assertColumn(Column);
}

fn mapText(err: text.Error) Error {
    return switch (err) {
        error.InvalidUtf8 => error.InvalidUtf8,
        error.OutOfMemory => error.OutOfMemory,
        error.Overflow => error.LimitExceeded,
    };
}
