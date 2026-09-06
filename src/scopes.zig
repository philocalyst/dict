const std = @import("std");
const semantic = @import("semantic.zig");

/// Errors returned by the schema-driven scoped-field view.  The view is a
/// reader over Model: it never builds a second edge or value graph.
pub const Error = error{
    InvalidReference,
    InvalidSchema,
    InvalidSchemaRow,
    InvalidScope,
    InvalidField,
    InvalidTarget,
    InvalidSourceBoundary,
    Ambiguous,
    ParentAmbiguous,
    ParentCycle,
    BudgetExceeded,
    OutOfMemory,
};

pub const Inheritance = enum {
    none,
    nearest,
};

pub const Cardinality = enum {
    one,
    many,
};

/// `ordered` means that callers may rely on assertion storage order.  Even
/// for `unordered`, this view leaves rows in storage order; it never sorts or
/// deduplicates a result and therefore never throws away occurrence identity.
pub const Ordering = enum {
    ordered,
    unordered,
};

pub const SourceBoundary = enum {
    /// Known source IDs on the assertion and its endpoint scopes must agree.
    /// A null source is an intentional global scope and is compatible with a
    /// known source.  This makes lexicon-wide defaults usable by entries while
    /// preventing an explicitly source-A relation from joining source B.
    same_known,
    allow_cross,
};

pub const ValueKind = enum {
    any,
    text,
    bytes,
    boolean,
    signed_integer,
    unsigned_integer,
    decimal,
    uri,
    qualified_name,
    sequence,
    unknown,
    absent,
    uncertain,
};

/// A relation whose child scope inherits fields from its parent scope.  Both
/// roles are named by the caller; no participant position or conventional
/// predicate is inferred.
pub const ParentSchema = struct {
    predicate: semantic.EntityId,
    child_role: []const u8,
    parent_role: []const u8,
};

/// A field is one predicate plus two explicitly named participant roles.  A
/// field value is a semantic.ValueId, so text language/script/notation and
/// unknown/absent/uncertain tags remain exactly those in Model.
pub const FieldSchema = struct {
    predicate: semantic.EntityId,
    owner_role: []const u8,
    value_role: []const u8,
    inheritance: Inheritance = .none,
    cardinality: Cardinality = .many,
    ordering: Ordering = .ordered,
    value_kind: ValueKind = .any,
};

pub const Limits = struct {
    /// Maximum assertions inspected by schema validation and one lookup.
    max_work_items: usize = 1 << 24,
    max_parent_depth: usize = 4096,
    max_results: usize = 1 << 20,
    max_result_bytes: usize = 64 << 20,
};

/// The schema is deliberately explicit.  `scope_kinds` must list every kind
/// which may participate as an entry, homograph/scope, sense, or lexicon
/// scope.  An empty list is rejected rather than treated as "all kinds".
pub const Schema = struct {
    scope_kinds: []const semantic.EntityKind,
    parent: ?ParentSchema = null,
    fields: []const FieldSchema,
    source_boundary: SourceBoundary = .same_known,
};

pub const ResolvedValue = struct {
    /// The scope where the assertion was found.  This is the requested scope
    /// for a local value and an ancestor for an inherited value.
    origin_scope: semantic.EntityId,
    assertion: semantic.AssertionId,
    value: semantic.ValueId,
};

pub const ResolvedField = struct {
    allocator: std.mem.Allocator,
    field_index: usize,
    /// Null means the field is omitted at every visited scope.  An explicit
    /// `semantic.Value.absent` is instead an ordinary item in `items`.
    items: []ResolvedValue,

    pub fn deinit(self: *ResolvedField) void {
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const View = struct {
    model: *const semantic.Model,
    schema: Schema,
    allocator: std.mem.Allocator,
    limits: Limits,

    /// Constructing a view validates every row for the selected predicates.
    /// That front-loads malformed public Model data, so a successful lookup
    /// can never return a partial result before discovering a bad row.
    pub fn init(model: *const semantic.Model, schema: Schema, allocator: std.mem.Allocator, limits: Limits) Error!View {
        var view = View{ .model = model, .schema = schema, .allocator = allocator, .limits = limits };
        try view.validateSchema();
        try view.validateRows();
        return view;
    }

    pub fn fieldCount(self: *const View) usize {
        return self.schema.fields.len;
    }

    /// Resolve one field.  The returned slice owns only its compact triples;
    /// all IDs point directly into the immutable Model and no text is copied.
    pub fn lookup(self: *const View, scope: semantic.EntityId, field_index: usize) Error!?ResolvedField {
        try self.requireScope(scope);
        if (field_index >= self.schema.fields.len) return Error.InvalidField;
        const field = self.schema.fields[field_index];

        var values: std.ArrayList(ResolvedValue) = .empty;
        defer values.deinit(self.allocator);
        var visited: std.ArrayList(semantic.EntityId) = .empty;
        defer visited.deinit(self.allocator);

        var current = scope;
        var depth: usize = 0;
        var work: usize = 0;
        while (true) {
            if (depth > self.limits.max_parent_depth) return Error.BudgetExceeded;
            for (visited.items) |seen| if (seen.index == current.index) return Error.ParentCycle;
            try visited.append(self.allocator, current);

            values.clearRetainingCapacity();
            try self.collectField(current, field, &values, &work);
            if (values.items.len != 0) {
                if (field.cardinality == .one and values.items.len != 1) return Error.Ambiguous;
                return .{ .allocator = self.allocator, .field_index = field_index, .items = try values.toOwnedSlice(self.allocator) };
            }
            if (field.inheritance == .none) return null;
            const parent = try self.findParent(current, &work);
            if (parent == null) return null;
            current = parent.?;
            depth += 1;
        }
    }

    fn validateSchema(self: *const View) Error!void {
        if (self.schema.scope_kinds.len == 0 or self.schema.fields.len == 0) return Error.InvalidSchema;
        if (self.schema.parent == null) {
            for (self.schema.fields) |field| if (field.inheritance == .nearest) return Error.InvalidSchema;
        }
        if (self.schema.parent) |parent| {
            try self.requireEntity(parent.predicate);
            if (parent.child_role.len == 0 or parent.parent_role.len == 0 or std.mem.eql(u8, parent.child_role, parent.parent_role)) return Error.InvalidSchema;
        }
        for (self.schema.fields, 0..) |field, index| {
            try self.requireEntity(field.predicate);
            if (field.owner_role.len == 0 or field.value_role.len == 0 or std.mem.eql(u8, field.owner_role, field.value_role)) return Error.InvalidSchema;
            for (self.schema.fields[0..index]) |prior| {
                if (prior.predicate.index == field.predicate.index and std.mem.eql(u8, prior.owner_role, field.owner_role) and std.mem.eql(u8, prior.value_role, field.value_role)) return Error.InvalidSchema;
            }
        }
    }

    fn validateRows(self: *const View) Error!void {
        var work: usize = 0;
        for (self.model.assertions) |assertion| {
            if (self.schema.parent) |parent| {
                if (assertion.predicate.index == parent.predicate.index) {
                    try accountChecked(&work, self.limits.max_work_items, 1);
                    _ = try self.parentParticipants(assertion);
                }
            }
            for (self.schema.fields) |field| {
                if (assertion.predicate.index != field.predicate.index) continue;
                try accountChecked(&work, self.limits.max_work_items, 1);
                _ = try self.fieldParticipants(assertion, field);
            }
        }
    }

    fn collectField(self: *const View, scope: semantic.EntityId, field: FieldSchema, out: *std.ArrayList(ResolvedValue), work: *usize) Error!void {
        for (self.model.assertions, 0..) |assertion, index| {
            if (assertion.predicate.index != field.predicate.index) continue;
            try accountChecked(work, self.limits.max_work_items, 1);
            const participants = try self.fieldParticipants(assertion, field);
            if (participants.owner.index != scope.index) continue;
            if (out.items.len >= self.limits.max_results) return Error.BudgetExceeded;
            const bytes = @mulWithOverflow(out.items.len + 1, @sizeOf(ResolvedValue));
            if (bytes[1] != 0 or bytes[0] > self.limits.max_result_bytes) return Error.BudgetExceeded;
            try out.append(self.allocator, .{ .origin_scope = scope, .assertion = .{ .index = @intCast(index) }, .value = participants.value });
        }
    }

    const FieldParticipants = struct { owner: semantic.EntityId, value: semantic.ValueId };

    fn fieldParticipants(self: *const View, assertion: semantic.Assertion, field: FieldSchema) Error!FieldParticipants {
        if (assertion.participants.len < 2) return Error.InvalidSchemaRow;
        const owner_target = try uniqueRole(assertion, field.owner_role);
        const value_target = try uniqueRole(assertion, field.value_role);
        const owner = switch (owner_target) {
            .entity => |id| id,
            else => return Error.InvalidTarget,
        };
        const value = switch (value_target) {
            .value => |id| id,
            else => return Error.InvalidTarget,
        };
        try self.requireScope(owner);
        try self.requireValue(value);
        if (!valueKindMatches(self.model.values[value.index], field.value_kind)) return Error.InvalidTarget;
        if (self.schema.source_boundary == .same_known) try self.checkAssertionSource(assertion, owner);
        return .{ .owner = owner, .value = value };
    }

    const ParentParticipants = struct { child: semantic.EntityId, parent: semantic.EntityId };

    fn parentParticipants(self: *const View, assertion: semantic.Assertion) Error!ParentParticipants {
        const parent_schema = self.schema.parent orelse return Error.InvalidSchema;
        if (assertion.participants.len < 2) return Error.InvalidSchemaRow;
        const child_target = try uniqueRole(assertion, parent_schema.child_role);
        const parent_target = try uniqueRole(assertion, parent_schema.parent_role);
        const child = switch (child_target) {
            .entity => |id| id,
            else => return Error.InvalidTarget,
        };
        const parent = switch (parent_target) {
            .entity => |id| id,
            else => return Error.InvalidTarget,
        };
        try self.requireScope(child);
        try self.requireScope(parent);
        if (self.schema.source_boundary == .same_known) {
            try self.checkEntitySource(child, parent);
            try self.checkAssertionSource(assertion, child);
            try self.checkAssertionSource(assertion, parent);
        }
        return .{ .child = child, .parent = parent };
    }

    fn findParent(self: *const View, child: semantic.EntityId, work: *usize) Error!?semantic.EntityId {
        const parent_schema = self.schema.parent orelse return null;
        var found: ?semantic.EntityId = null;
        for (self.model.assertions) |assertion| {
            if (assertion.predicate.index != parent_schema.predicate.index) continue;
            try accountChecked(work, self.limits.max_work_items, 1);
            const participants = try self.parentParticipants(assertion);
            if (participants.child.index != child.index) continue;
            if (found != null) return Error.ParentAmbiguous;
            found = participants.parent;
        }
        return found;
    }

    fn uniqueRole(assertion: semantic.Assertion, role: []const u8) Error!semantic.Target {
        var found: ?semantic.Target = null;
        for (assertion.participants) |participant| {
            if (!std.mem.eql(u8, participant.role, role)) continue;
            if (found != null) return Error.InvalidSchemaRow;
            found = participant.target;
        }
        return found orelse Error.InvalidSchemaRow;
    }

    fn requireScope(self: *const View, id: semantic.EntityId) Error!void {
        try self.requireEntity(id);
        if (!kindAllowed(self.model.entities[id.index].kind, self.schema.scope_kinds)) return Error.InvalidScope;
    }

    fn requireEntity(self: *const View, id: semantic.EntityId) Error!void {
        if (id.index >= self.model.entities.len) return Error.InvalidReference;
    }

    fn requireValue(self: *const View, id: semantic.ValueId) Error!void {
        if (id.index >= self.model.values.len) return Error.InvalidReference;
    }

    fn checkEntitySource(self: *const View, left: semantic.EntityId, right: semantic.EntityId) Error!void {
        const a = self.model.entities[left.index].source;
        const b = self.model.entities[right.index].source;
        if (a != null and b != null and a.?.index != b.?.index) return Error.InvalidSourceBoundary;
    }

    fn checkAssertionSource(self: *const View, assertion: semantic.Assertion, endpoint: semantic.EntityId) Error!void {
        if (assertion.source) |source| if (self.model.entities[endpoint.index].source) |endpoint_source| if (source.index != endpoint_source.index) return Error.InvalidSourceBoundary;
    }

};

fn accountChecked(total: *usize, limit: usize, amount: usize) Error!void {
    const result = @addWithOverflow(total.*, amount);
    if (result[1] != 0 or result[0] > limit) return Error.BudgetExceeded;
    total.* = result[0];
}

fn kindAllowed(kind: semantic.EntityKind, allowed: []const semantic.EntityKind) bool {
    for (allowed) |candidate| if (candidate == kind) return true;
    return false;
}

fn valueKindMatches(value: semantic.Value, kind: ValueKind) bool {
    return switch (kind) {
        .any => true,
        .text => value == .text,
        .bytes => value == .bytes,
        .boolean => value == .boolean,
        .signed_integer => value == .signed_integer,
        .unsigned_integer => value == .unsigned_integer,
        .decimal => value == .decimal,
        .uri => value == .uri,
        .qualified_name => value == .qualified_name,
        .sequence => value == .sequence,
        .unknown => value == .unknown,
        .absent => value == .absent,
        .uncertain => value == .uncertain,
    };
}

test "scoped defaults share values and nearest explicit absent stops fallback" {
    var b = semantic.Builder.init(std.testing.allocator);
    defer b.deinit();
    const predicate_parent = try b.addEntity(.{ .kind = .other });
    const predicate_field = try b.addEntity(.{ .kind = .other });
    const lexicon = try b.addEntity(.{ .kind = .lexicon });
    const entry = try b.addEntity(.{ .kind = .entry });
    const sense = try b.addEntity(.{ .kind = .sense });
    const sense_inherited = try b.addEntity(.{ .kind = .sense });
    const fr = try b.addValue(.{ .text = .{ .bytes = "fr", .language = "fr" } });
    const en = try b.addValue(.{ .text = .{ .bytes = "en", .language = "en" } });
    const absent = try b.addValue(.absent);
    _ = try b.addAssertion(.{ .predicate = predicate_parent, .participants = &.{ .{ .role = "child", .target = .{ .entity = entry } }, .{ .role = "parent", .target = .{ .entity = lexicon } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain });
    _ = try b.addAssertion(.{ .predicate = predicate_parent, .participants = &.{ .{ .role = "child", .target = .{ .entity = sense } }, .{ .role = "parent", .target = .{ .entity = entry } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain });
    _ = try b.addAssertion(.{ .predicate = predicate_parent, .participants = &.{ .{ .role = "child", .target = .{ .entity = sense_inherited } }, .{ .role = "parent", .target = .{ .entity = entry } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain });
    _ = try b.addAssertion(.{ .predicate = predicate_field, .participants = &.{ .{ .role = "owner", .target = .{ .entity = lexicon } }, .{ .role = "value", .target = .{ .value = fr } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain });
    _ = try b.addAssertion(.{ .predicate = predicate_field, .participants = &.{ .{ .role = "owner", .target = .{ .entity = sense } }, .{ .role = "value", .target = .{ .value = absent } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain });
    _ = try b.addAssertion(.{ .predicate = predicate_field, .participants = &.{ .{ .role = "owner", .target = .{ .entity = entry } }, .{ .role = "value", .target = .{ .value = en } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain });
    var model = try b.build();
    defer model.deinit();
    const view = try View.init(&model, .{ .scope_kinds = &.{ .lexicon, .entry, .sense }, .parent = .{ .predicate = predicate_parent, .child_role = "child", .parent_role = "parent" }, .fields = &.{.{ .predicate = predicate_field, .owner_role = "owner", .value_role = "value", .inheritance = .nearest, .cardinality = .one, .value_kind = .any } } }, std.testing.allocator, .{});
    var result = (try view.lookup(sense, 0)).?;
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expectEqual(absent.index, result.items[0].value.index);
    try std.testing.expectEqual(sense.index, result.items[0].origin_scope.index);
    var inherited = (try view.lookup(sense_inherited, 0)).?;
    defer inherited.deinit();
    try std.testing.expectEqual(en.index, inherited.items[0].value.index);
    try std.testing.expectEqual(entry.index, inherited.items[0].origin_scope.index);
}

test "ordered many fields preserve duplicate values and conflicting one is explicit" {
    var b = semantic.Builder.init(std.testing.allocator);
    defer b.deinit();
    const predicate = try b.addEntity(.{ .kind = .other });
    const scope = try b.addEntity(.{ .kind = .entry });
    const a = try b.addValue(.{ .text = .{ .bytes = "a", .language = "en" } });
    const bval = try b.addValue(.{ .text = .{ .bytes = "b", .language = "en" } });
    for ([_]semantic.ValueId{ a, bval, a }) |value| _ = try b.addAssertion(.{ .predicate = predicate, .participants = &.{ .{ .role = "owner", .target = .{ .entity = scope } }, .{ .role = "value", .target = .{ .value = value } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain });
    var model = try b.build();
    defer model.deinit();
    const fields = &[_]FieldSchema{.{ .predicate = predicate, .owner_role = "owner", .value_role = "value", .cardinality = .many }};
    const view = try View.init(&model, .{ .scope_kinds = &.{.entry}, .fields = fields }, std.testing.allocator, .{});
    var result = (try view.lookup(scope, 0)).?;
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.items.len);
    try std.testing.expectEqual(a.index, result.items[2].value.index);
    const one_fields = &[_]FieldSchema{.{ .predicate = predicate, .owner_role = "owner", .value_role = "value", .cardinality = .one }};
    const one_view = try View.init(&model, .{ .scope_kinds = &.{.entry}, .fields = one_fields }, std.testing.allocator, .{});
    try std.testing.expectError(Error.Ambiguous, one_view.lookup(scope, 0));
}

test "parent conflicts and cycles are never silently resolved" {
    var b = semantic.Builder.init(std.testing.allocator);
    defer b.deinit();
    const parent_pred = try b.addEntity(.{ .kind = .other });
    const field_pred = try b.addEntity(.{ .kind = .other });
    const a = try b.addEntity(.{ .kind = .entry });
    const b_scope = try b.addEntity(.{ .kind = .entry });
    const v = try b.addValue(.{ .text = .{ .bytes = "x" } });
    _ = try b.addAssertion(.{ .predicate = parent_pred, .participants = &.{ .{ .role = "child", .target = .{ .entity = a } }, .{ .role = "parent", .target = .{ .entity = b_scope } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain });
    _ = try b.addAssertion(.{ .predicate = parent_pred, .participants = &.{ .{ .role = "child", .target = .{ .entity = a } }, .{ .role = "parent", .target = .{ .entity = a } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain });
    _ = try b.addAssertion(.{ .predicate = field_pred, .participants = &.{ .{ .role = "owner", .target = .{ .entity = b_scope } }, .{ .role = "value", .target = .{ .value = v } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain });
    var model = try b.build();
    defer model.deinit();
    const view = try View.init(&model, .{ .scope_kinds = &.{.entry}, .parent = .{ .predicate = parent_pred, .child_role = "child", .parent_role = "parent" }, .fields = &.{.{ .predicate = field_pred, .owner_role = "owner", .value_role = "value", .inheritance = .nearest }} }, std.testing.allocator, .{});
    try std.testing.expectError(Error.ParentAmbiguous, view.lookup(a, 0));
}

test "nearest lookup detects a parent cycle on the traversed path" {
    var b = semantic.Builder.init(std.testing.allocator);
    defer b.deinit();
    const parent_pred = try b.addEntity(.{ .kind = .other });
    const field_pred = try b.addEntity(.{ .kind = .other });
    const a = try b.addEntity(.{ .kind = .entry });
    const b_scope = try b.addEntity(.{ .kind = .sense });
    _ = try b.addAssertion(.{ .predicate = parent_pred, .participants = &.{ .{ .role = "child", .target = .{ .entity = a } }, .{ .role = "parent", .target = .{ .entity = b_scope } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain });
    _ = try b.addAssertion(.{ .predicate = parent_pred, .participants = &.{ .{ .role = "child", .target = .{ .entity = b_scope } }, .{ .role = "parent", .target = .{ .entity = a } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain });
    var model = try b.build();
    defer model.deinit();
    const view = try View.init(&model, .{ .scope_kinds = &.{ .entry, .sense }, .parent = .{ .predicate = parent_pred, .child_role = "child", .parent_role = "parent" }, .fields = &.{.{ .predicate = field_pred, .owner_role = "owner", .value_role = "value", .inheritance = .nearest }} }, std.testing.allocator, .{});
    try std.testing.expectError(Error.ParentCycle, view.lookup(a, 0));
}

test "known source boundaries reject cross-source parent rows" {
    var b = semantic.Builder.init(std.testing.allocator);
    defer b.deinit();
    const parent_pred = try b.addEntity(.{ .kind = .other });
    const field_pred = try b.addEntity(.{ .kind = .other });
    const source_a = try b.addSource(.{ .external_id = "a" });
    const source_b = try b.addSource(.{ .external_id = "b" });
    const child = try b.addEntity(.{ .kind = .entry, .source = source_a });
    const parent = try b.addEntity(.{ .kind = .lexicon, .source = source_b });
    _ = try b.addAssertion(.{ .predicate = parent_pred, .participants = &.{ .{ .role = "child", .target = .{ .entity = child } }, .{ .role = "parent", .target = .{ .entity = parent } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain });
    var model = try b.build();
    defer model.deinit();
    try std.testing.expectError(Error.InvalidSourceBoundary, View.init(&model, .{ .scope_kinds = &.{ .lexicon, .entry }, .parent = .{ .predicate = parent_pred, .child_role = "child", .parent_role = "parent" }, .fields = &.{.{ .predicate = field_pred, .owner_role = "owner", .value_role = "value", .inheritance = .nearest }} }, std.testing.allocator, .{}));
}

test "lookup propagates a result allocation failure without partial output" {
    var b = semantic.Builder.init(std.testing.allocator);
    defer b.deinit();
    const predicate = try b.addEntity(.{ .kind = .other });
    const scope = try b.addEntity(.{ .kind = .entry });
    const value = try b.addValue(.{ .text = .{ .bytes = "en", .language = "en" } });
    _ = try b.addAssertion(.{ .predicate = predicate, .participants = &.{ .{ .role = "owner", .target = .{ .entity = scope } }, .{ .role = "value", .target = .{ .value = value } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain });
    var model = try b.build();
    defer model.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const view = try View.init(&model, .{ .scope_kinds = &.{.entry}, .fields = &.{.{ .predicate = predicate, .owner_role = "owner", .value_role = "value" }} }, failing.allocator(), .{});
    try std.testing.expectError(Error.OutOfMemory, view.lookup(scope, 0));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(usize, 0), failing.deallocations);
}
