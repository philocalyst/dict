const std = @import("std");
const semantic = @import("semantic.zig");

/// Typed, bounded projections over the semantic graph.  This module deliberately
/// owns no lexical storage: IDs and slices in returned records refer to the
/// caller's pinned semantic.Model.  A caller supplies predicate and role names
/// because TEI profiles and OntoLex vocabularies do not share one universal
/// predicate vocabulary.
pub const Error = error{
    InvalidReference,
    InvalidSchema,
    InvalidRole,
    InvalidCardinality,
    InvalidEntityKind,
    InvalidSurfaceValue,
    MissingSurface,
    MissingSourceAnchor,
    InvalidSpan,
    SpanOutOfBounds,
    UnsupportedSpanUnit,
    DecompositionCycle,
    BudgetExceeded,
    OutOfMemory,
};

pub const Cardinality = enum { one, one_or_more };

/// One assertion shape.  `source_role` must occur exactly once and the target
/// role is either exactly once or one-or-more times.  Participant order is
/// retained in RelationEdge.target_participant and is never reconstructed from
/// entity IDs.
pub const RelationSpec = struct {
    predicate: semantic.EntityId,
    source_role: []const u8,
    target_role: []const u8,
    target_cardinality: Cardinality = .one_or_more,
    source_kind: ?semantic.EntityKind = null,
    target_kind: ?semantic.EntityKind = null,
};

pub const SurfaceSpec = struct {
    relation: RelationSpec,
    require_anchor: bool = false,
    require_text: bool = true,
};

pub const Options = struct {
    max_results: usize = 100_000,
    max_result_bytes: usize = 64 * 1024 * 1024,
    max_scan_items: usize = 1_000_000,
    max_nodes: usize = 100_000,
    max_depth: u32 = 64,
    max_surface_occurrences: usize = 100_000,
    /// Grapheme segmentation is language/profile dependent and is not
    /// approximated by scalar count.  Set this only when the caller accepts an
    /// unvalidated grapheme span (the span is still retained exactly).
    allow_unvalidated_grapheme: bool = false,
};

pub const Scope = struct {
    entity_source: ?semantic.SourceId,
    assertion_source: ?semantic.SourceId,
};

pub const RelationEdge = struct {
    assertion: semantic.AssertionId,
    source: semantic.EntityId,
    target: semantic.EntityId,
    source_participant: u32,
    target_participant: u32,
    /// The target's ordinal among target-role participants, not a global
    /// ordinal.  This is useful when an assertion has qualifiers interleaved.
    order: u32,
    scope: Scope,
};

pub const RelationResult = struct {
    allocator: std.mem.Allocator,
    items: []RelationEdge,

    pub fn deinit(self: *RelationResult) void {
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const FormView = struct {
    owner: semantic.EntityId,
    form: semantic.EntityId,
    edge: RelationEdge,
};

pub const FormResult = struct {
    allocator: std.mem.Allocator,
    items: []FormView,

    pub fn deinit(self: *FormResult) void {
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const SenseView = struct {
    owner: semantic.EntityId,
    sense: semantic.EntityId,
    edge: RelationEdge,
};

pub const SenseResult = struct {
    allocator: std.mem.Allocator,
    items: []SenseView,

    pub fn deinit(self: *SenseResult) void {
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const SurfaceOccurrence = struct {
    assertion: semantic.AssertionId,
    owner: semantic.EntityId,
    value: semantic.ValueId,
    scope: Scope,
    /// This is an occurrence anchor, not an inferred source location.  Null
    /// means the surface assertion has no retained anchor.
    anchor: ?semantic.SourceAnchor,
};

pub const SurfaceResult = struct {
    allocator: std.mem.Allocator,
    items: []SurfaceOccurrence,

    pub fn deinit(self: *SurfaceResult) void {
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const WordPartView = struct {
    occurrence: u32,
    parent: ?u32,
    entity: semantic.EntityId,
    depth: u32,
    decomposition_assertion: ?semantic.AssertionId,
    target_participant: ?u32,
    order: ?u32,
    scope: Scope,
    /// A cycle edge is retained as an occurrence but is not expanded.  This
    /// makes malformed/cyclic source analyses finite and inspectable.
    cycle: bool,
};

pub const AnalysisSurface = struct {
    occurrence: u32,
    surface: SurfaceOccurrence,
};

pub const AnalysisResult = struct {
    allocator: std.mem.Allocator,
    parts: []WordPartView,
    surfaces: []AnalysisSurface,

    pub fn deinit(self: *AnalysisResult) void {
        self.allocator.free(self.parts);
        self.allocator.free(self.surfaces);
        self.* = undefined;
    }

    pub fn surfacesFor(self: *const AnalysisResult, occurrence: u32) []const AnalysisSurface {
        var first: usize = 0;
        while (first < self.surfaces.len and self.surfaces[first].occurrence != occurrence) : (first += 1) {}
        var end = first;
        while (end < self.surfaces.len and self.surfaces[end].occurrence == occurrence) : (end += 1) {}
        return self.surfaces[first..end];
    }
};

pub const Evaluator = struct {
    model: *const semantic.Model,
    allocator: std.mem.Allocator,
    options: Options,
    scanned: usize = 0,
    surface_count: usize = 0,

    pub fn init(model: *const semantic.Model, allocator: std.mem.Allocator, options: Options) Error!Evaluator {
        return .{ .model = model, .allocator = allocator, .options = options };
    }

    /// Return entity-valued edges for a caller-supplied predicate/role shape.
    /// Translation assertions, word-formation assertions and form ownership
    /// all use this same primitive without accidental inverse traversal.
    pub fn related(self: *Evaluator, source: semantic.EntityId, spec: RelationSpec) Error!RelationResult {
        self.resetQuery();
        try self.validateRelationSpec(spec);
        try self.requireEntity(source);
        var out: std.ArrayList(RelationEdge) = .empty;
        errdefer out.deinit(self.allocator);
        try self.collectEdges(source, spec, null, &out);
        return .{ .allocator = self.allocator, .items = try out.toOwnedSlice(self.allocator) };
    }

    /// Typed lexical ownership view.  The relation remains caller-defined,
    /// while the target is required to be a `form` entity.
    pub fn formsOf(self: *Evaluator, owner: semantic.EntityId, spec: RelationSpec) Error!FormResult {
        self.resetQuery();
        if (spec.target_kind) |kind| if (kind != .form) return Error.InvalidSchema;
        var relation = spec;
        relation.target_kind = .form;
        try self.validateRelationSpec(relation);
        try self.requireEntity(owner);
        var out: std.ArrayList(FormView) = .empty;
        errdefer out.deinit(self.allocator);
        var edges: std.ArrayList(RelationEdge) = .empty;
        defer edges.deinit(self.allocator);
        try self.collectEdges(owner, relation, null, &edges);
        for (edges.items) |edge| try self.appendResult(FormView, &out, .{ .owner = owner, .form = edge.target, .edge = edge });
        return .{ .allocator = self.allocator, .items = try out.toOwnedSlice(self.allocator) };
    }

    /// Typed sense view.  This does not infer senses from forms or translate
    /// between languages; only assertions matching the supplied shape count.
    pub fn sensesOf(self: *Evaluator, owner: semantic.EntityId, spec: RelationSpec) Error!SenseResult {
        self.resetQuery();
        if (spec.target_kind) |kind| if (kind != .sense) return Error.InvalidSchema;
        var relation = spec;
        relation.target_kind = .sense;
        try self.validateRelationSpec(relation);
        try self.requireEntity(owner);
        var out: std.ArrayList(SenseView) = .empty;
        errdefer out.deinit(self.allocator);
        var edges: std.ArrayList(RelationEdge) = .empty;
        defer edges.deinit(self.allocator);
        try self.collectEdges(owner, relation, null, &edges);
        for (edges.items) |edge| try self.appendResult(SenseView, &out, .{ .owner = owner, .sense = edge.target, .edge = edge });
        return .{ .allocator = self.allocator, .items = try out.toOwnedSlice(self.allocator) };
    }

    /// Resolve explicit `entity -> ValueId` surface assertions and retained
    /// assertion anchors.  Every returned item contains the ValueId; the
    /// source text is never reconstructed or copied into this view.
    pub fn surfacesOf(self: *Evaluator, owner: semantic.EntityId, spec: SurfaceSpec) Error!SurfaceResult {
        self.resetQuery();
        if (spec.relation.target_cardinality != .one) return Error.InvalidSchema;
        if (spec.relation.target_kind != null) return Error.InvalidSchema;
        try self.validateRelationSpec(spec.relation);
        try self.requireEntity(owner);
        var out: std.ArrayList(SurfaceOccurrence) = .empty;
        errdefer out.deinit(self.allocator);
        try self.collectSurfaces(owner, spec, &out);
        return .{ .allocator = self.allocator, .items = try out.toOwnedSlice(self.allocator) };
    }

    /// Recursively enumerate ordered word-part occurrences.  Each matching
    /// decomposition assertion is an alternative occurrence; no entity-level
    /// deduplication is performed.  Participant order, parallel assertions,
    /// overlap and discontinuous anchors therefore remain observable.
    pub fn decompose(self: *Evaluator, root: semantic.EntityId, relation: RelationSpec, surface: ?SurfaceSpec, options: Options) Error!AnalysisResult {
        self.options = options;
        self.resetQuery();
        try self.validateRelationSpec(relation);
        try self.requireEntity(root);
        if (surface) |surface_spec| {
            if (surface_spec.relation.target_cardinality != .one) return Error.InvalidSchema;
            if (surface_spec.relation.target_kind != null) return Error.InvalidSchema;
            try self.validateRelationSpec(surface_spec.relation);
        }
        var parts: std.ArrayList(WordPartView) = .empty;
        errdefer parts.deinit(self.allocator);
        var surfaces: std.ArrayList(AnalysisSurface) = .empty;
        errdefer surfaces.deinit(self.allocator);
        try appendPart(self, &parts, .{
            .occurrence = 0,
            .parent = null,
            .entity = root,
            .depth = 0,
            .decomposition_assertion = null,
            .target_participant = null,
            .order = null,
            .scope = entityScope(self.model, root),
            .cycle = false,
        }, options);
        if (surface) |surface_spec| try self.appendNodeSurfaces(&surfaces, 0, root, surface_spec);

        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, 0);
        while (stack.items.len != 0) {
            const parent_index = stack.pop().?;
            const parent = parts.items[parent_index];
            if (parent.depth >= options.max_depth) continue;
            var edges: std.ArrayList(RelationEdge) = .empty;
            defer edges.deinit(self.allocator);
            try self.collectEdges(parent.entity, relation, null, &edges);
            for (edges.items) |edge| {
                const occurrence: u32 = @intCast(parts.items.len);
                const cycle = ancestorContains(parts.items, parent_index, edge.target);
                try appendPart(self, &parts, .{
                    .occurrence = occurrence,
                    .parent = parent_index,
                    .entity = edge.target,
                    .depth = parent.depth + 1,
                    .decomposition_assertion = edge.assertion,
                    .target_participant = edge.target_participant,
                    .order = edge.order,
                    .scope = entityScope(self.model, edge.target),
                    .cycle = cycle,
                }, options);
                if (surface) |surface_spec| try self.appendNodeSurfaces(&surfaces, occurrence, edge.target, surface_spec);
                if (!cycle and parent.depth + 1 < options.max_depth) try stack.append(self.allocator, occurrence);
            }
        }
        return .{ .allocator = self.allocator, .parts = try parts.toOwnedSlice(self.allocator), .surfaces = try surfaces.toOwnedSlice(self.allocator) };
    }

    fn validateRelationSpec(self: *const Evaluator, spec: RelationSpec) Error!void {
        try self.requireEntity(spec.predicate);
        if (spec.source_role.len == 0 or spec.target_role.len == 0 or !std.unicode.utf8ValidateSlice(spec.source_role) or !std.unicode.utf8ValidateSlice(spec.target_role)) return Error.InvalidRole;
        if (std.mem.eql(u8, spec.source_role, spec.target_role)) return Error.InvalidSchema;
    }

    fn collectEdges(self: *Evaluator, source: semantic.EntityId, spec: RelationSpec, target_override: ?semantic.EntityKind, out: *std.ArrayList(RelationEdge)) Error!void {
        try self.ensureScan(self.model.assertions.len);
        for (self.model.assertions, 0..) |assertion, assertion_index| {
            try self.bumpScan();
            if (assertion.predicate.index != spec.predicate.index) continue;
            try self.validateAssertionRefs(assertion, assertion_index);
            var source_index: ?usize = null;
            var source_count: usize = 0;
            var target_count: usize = 0;
            for (assertion.participants, 0..) |participant, i| {
                if (std.mem.eql(u8, participant.role, spec.source_role)) {
                    source_count += 1;
                    if (participant.target != .entity) return Error.InvalidCardinality;
                    if (participant.target.entity.index == source.index) source_index = i;
                }
                if (std.mem.eql(u8, participant.role, spec.target_role)) target_count += 1;
            }
            if (source_count != 1) return Error.InvalidCardinality;
            if (source_index == null) continue;
            if (target_count == 0 or (spec.target_cardinality == .one and target_count != 1)) return Error.InvalidCardinality;
            const source_entity = assertion.participants[source_index.?].target.entity;
            if (!kindMatches(self.model, source_entity, spec.source_kind)) return Error.InvalidEntityKind;
            var order: u32 = 0;
            for (assertion.participants, 0..) |participant, i| {
                if (!std.mem.eql(u8, participant.role, spec.target_role)) continue;
                if (participant.target != .entity) return Error.InvalidCardinality;
                const target = participant.target.entity;
                if (!kindMatches(self.model, target, target_override orelse spec.target_kind)) return Error.InvalidEntityKind;
                try self.appendResult(RelationEdge, out, .{
                    .assertion = .{ .index = @intCast(assertion_index) },
                    .source = source_entity,
                    .target = target,
                    .source_participant = @intCast(source_index.?),
                    .target_participant = @intCast(i),
                    .order = order,
                    .scope = .{ .entity_source = self.model.entities[source_entity.index].source, .assertion_source = assertion.source },
                });
                order += 1;
            }
        }
    }

    fn collectSurfaces(self: *Evaluator, owner: semantic.EntityId, spec: SurfaceSpec, out: *std.ArrayList(SurfaceOccurrence)) Error!void {
        try self.ensureScan(self.model.assertions.len);
        for (self.model.assertions, 0..) |assertion, assertion_index| {
            try self.bumpScan();
            if (assertion.predicate.index != spec.relation.predicate.index) continue;
            try self.validateAssertionRefs(assertion, assertion_index);
            var source_index: ?usize = null;
            var source_count: usize = 0;
            var value_index: ?usize = null;
            var value_count: usize = 0;
            for (assertion.participants, 0..) |participant, i| {
                if (std.mem.eql(u8, participant.role, spec.relation.source_role)) {
                    source_count += 1;
                    if (participant.target != .entity) return Error.InvalidCardinality;
                    if (participant.target.entity.index == owner.index) source_index = i;
                }
                if (std.mem.eql(u8, participant.role, spec.relation.target_role)) {
                    value_count += 1;
                    if (participant.target != .value) return Error.InvalidSurfaceValue;
                    value_index = participant.target.value.index;
                }
            }
            if (source_count != 1) return Error.InvalidCardinality;
            if (source_index == null) continue;
            if (value_count != 1 or value_index == null) return Error.InvalidCardinality;
            if (!kindMatches(self.model, owner, spec.relation.source_kind)) return Error.InvalidEntityKind;
            const value_id = semantic.ValueId{ .index = @intCast(value_index.?) };
            if (spec.require_text) switch (self.model.values[value_id.index]) {
                .text => {},
                else => return Error.InvalidSurfaceValue,
            };
            var anchor_count: usize = 0;
            for (self.model.assertion_anchors) |item| {
                if (item.assertion.index != assertion_index) continue;
                anchor_count += 1;
                try self.validateAnchor(item.anchor, value_id, self.options);
                try self.appendSurface(out, .{ .assertion = .{ .index = @intCast(assertion_index) }, .owner = owner, .value = value_id, .scope = .{ .entity_source = self.model.entities[owner.index].source, .assertion_source = assertion.source }, .anchor = item.anchor });
            }
            if (anchor_count == 0) {
                if (spec.require_anchor) return Error.MissingSourceAnchor;
                try self.appendSurface(out, .{ .assertion = .{ .index = @intCast(assertion_index) }, .owner = owner, .value = value_id, .scope = .{ .entity_source = self.model.entities[owner.index].source, .assertion_source = assertion.source }, .anchor = null });
            }
        }
    }

    fn appendNodeSurfaces(self: *Evaluator, out: *std.ArrayList(AnalysisSurface), occurrence: u32, owner: semantic.EntityId, spec: SurfaceSpec) Error!void {
        var values: std.ArrayList(SurfaceOccurrence) = .empty;
        defer values.deinit(self.allocator);
        try self.collectSurfaces(owner, spec, &values);
        for (values.items) |surface_value| {
            if (out.items.len >= self.options.max_results or (bytesFor(out.items.len + 1, @sizeOf(AnalysisSurface)) catch return Error.BudgetExceeded) > self.options.max_result_bytes) return Error.BudgetExceeded;
            try out.append(self.allocator, .{ .occurrence = occurrence, .surface = surface_value });
        }
    }

    fn validateAnchor(self: *const Evaluator, anchor: semantic.SourceAnchor, value: semantic.ValueId, options: Options) Error!void {
        if (anchor.source.index >= self.model.sources.len or anchor.node.index >= self.model.documents.len) return Error.InvalidReference;
        if (self.model.documents[anchor.node.index].source) |source| if (source.index != anchor.source.index) return Error.InvalidReference;
        const span = anchor.span orelse return;
        if (span.start > span.end) return Error.InvalidSpan;
        const bytes = switch (self.model.values[value.index]) {
            .text => |text| text.bytes,
            else => return Error.InvalidSurfaceValue,
        };
        switch (span.unit) {
            .byte => {
                if (span.end > bytes.len or !utf8Boundary(bytes, span.start) or !utf8Boundary(bytes, span.end)) return Error.SpanOutOfBounds;
            },
            .utf8_codepoint => if (span.end > try utf8Count(bytes)) return Error.SpanOutOfBounds,
            .utf16_code_unit => {
                const units = try utf16Count(bytes);
                const start_boundary = try utf16Boundary(bytes, span.start);
                const end_boundary = try utf16Boundary(bytes, span.end);
                if (span.end > units or !start_boundary or !end_boundary) return Error.SpanOutOfBounds;
            },
            .grapheme => if (!options.allow_unvalidated_grapheme) return Error.UnsupportedSpanUnit,
        }
    }

    fn validateAssertionRefs(self: *const Evaluator, assertion: semantic.Assertion, assertion_index: usize) Error!void {
        if (assertion.predicate.index >= self.model.entities.len or assertion.participants.len < 2) return Error.InvalidReference;
        for (assertion.participants) |participant| switch (participant.target) {
            .entity => |id| try self.requireEntity(id),
            .value => |id| try self.requireValue(id),
            .statement => |id| if (id.index >= assertion_index or id.index >= self.model.assertions.len) return Error.InvalidReference,
            .unresolved => {},
        };
    }

    fn appendSurface(self: *Evaluator, out: *std.ArrayList(SurfaceOccurrence), item: SurfaceOccurrence) Error!void {
        if (self.surface_count >= self.options.max_surface_occurrences) return Error.BudgetExceeded;
        if ((bytesFor(out.items.len + 1, @sizeOf(SurfaceOccurrence)) catch return Error.BudgetExceeded) > self.options.max_result_bytes) return Error.BudgetExceeded;
        self.surface_count += 1;
        try out.append(self.allocator, item);
    }

    fn appendResult(self: *Evaluator, comptime T: type, out: *std.ArrayList(T), item: T) Error!void {
        if (out.items.len >= self.options.max_results) return Error.BudgetExceeded;
        if ((bytesFor(out.items.len + 1, @sizeOf(T)) catch return Error.BudgetExceeded) > self.options.max_result_bytes) return Error.BudgetExceeded;
        try out.append(self.allocator, item);
    }

    fn bumpScan(self: *Evaluator) Error!void {
        if (self.scanned >= self.options.max_scan_items) return Error.BudgetExceeded;
        self.scanned += 1;
    }

    fn resetQuery(self: *Evaluator) void {
        self.scanned = 0;
        self.surface_count = 0;
    }

    fn ensureScan(self: *const Evaluator, count: usize) Error!void {
        if (count > self.options.max_scan_items) return Error.BudgetExceeded;
    }

    fn requireEntity(self: *const Evaluator, id: semantic.EntityId) Error!void {
        if (id.index >= self.model.entities.len) return Error.InvalidReference;
    }

    fn requireValue(self: *const Evaluator, id: semantic.ValueId) Error!void {
        if (id.index >= self.model.values.len) return Error.InvalidReference;
    }
};

fn appendPart(self: *Evaluator, out: *std.ArrayList(WordPartView), item: WordPartView, options: Options) Error!void {
    if (out.items.len >= options.max_nodes or out.items.len >= self.options.max_results) return Error.BudgetExceeded;
    if ((bytesFor(out.items.len + 1, @sizeOf(WordPartView)) catch return Error.BudgetExceeded) > self.options.max_result_bytes) return Error.BudgetExceeded;
    try out.append(self.allocator, item);
}

fn bytesFor(count: usize, width: usize) !usize {
    const product = @mulWithOverflow(count, width);
    if (product[1] != 0) return error.Overflow;
    return product[0];
}

fn entityScope(model: *const semantic.Model, id: semantic.EntityId) Scope {
    return .{ .entity_source = model.entities[id.index].source, .assertion_source = null };
}

fn kindMatches(model: *const semantic.Model, id: semantic.EntityId, expected: ?semantic.EntityKind) bool {
    return expected == null or model.entities[id.index].kind == expected.?;
}

fn ancestorContains(parts: []const WordPartView, parent: u32, entity: semantic.EntityId) bool {
    var cursor: ?u32 = parent;
    while (cursor) |index| {
        if (parts[index].entity.index == entity.index) return true;
        cursor = parts[index].parent;
    }
    return false;
}

fn utf8Boundary(bytes: []const u8, offset: u64) bool {
    if (offset > bytes.len) return false;
    if (offset == 0 or offset == bytes.len) return true;
    return (bytes[@intCast(offset)] & 0xc0) != 0x80;
}

fn decodeScalar(bytes: []const u8, at: usize) Error!struct { value: u32, len: usize } {
    if (at >= bytes.len) return Error.SpanOutOfBounds;
    const first = bytes[at];
    const len: usize = if (first < 0x80) 1 else if ((first & 0xe0) == 0xc0) 2 else if ((first & 0xf0) == 0xe0) 3 else if ((first & 0xf8) == 0xf0) 4 else return Error.InvalidSurfaceValue;
    if (at + len > bytes.len) return Error.InvalidSurfaceValue;
    var value: u32 = switch (len) {
        1 => first,
        2 => first & 0x1f,
        3 => first & 0x0f,
        4 => first & 0x07,
        else => unreachable,
    };
    var i: usize = 1;
    while (i < len) : (i += 1) {
        if ((bytes[at + i] & 0xc0) != 0x80) return Error.InvalidSurfaceValue;
        value = (value << 6) | (bytes[at + i] & 0x3f);
    }
    if ((len == 2 and value < 0x80) or (len == 3 and value < 0x800) or (len == 4 and value < 0x10000) or value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) return Error.InvalidSurfaceValue;
    return .{ .value = value, .len = len };
}

fn utf8Count(bytes: []const u8) Error!u64 {
    var count: u64 = 0;
    var at: usize = 0;
    while (at < bytes.len) {
        const scalar = try decodeScalar(bytes, at);
        at += scalar.len;
        count += 1;
    }
    return count;
}

fn utf16Count(bytes: []const u8) Error!u64 {
    var count: u64 = 0;
    var at: usize = 0;
    while (at < bytes.len) {
        const scalar = try decodeScalar(bytes, at);
        at += scalar.len;
        count += if (scalar.value > 0xffff) 2 else 1;
    }
    return count;
}

fn utf16Boundary(bytes: []const u8, offset: u64) Error!bool {
    var count: u64 = 0;
    if (offset == 0) return true;
    var at: usize = 0;
    while (at < bytes.len) {
        const scalar = try decodeScalar(bytes, at);
        at += scalar.len;
        count += if (scalar.value > 0xffff) 2 else 1;
        if (count == offset) return true;
        if (count > offset) return false;
    }
    return count == offset;
}

test "typed forms and senses preserve assertion occurrence and source scope" {
    var builder = semantic.Builder.init(std.testing.allocator);
    defer builder.deinit();
    const source_a = try builder.addSource(.{ .external_id = "a" });
    const source_b = try builder.addSource(.{ .external_id = "b" });
    const predicate = try builder.addEntity(.{ .kind = .other, .external_id = "has-form" });
    const sense_predicate = try builder.addEntity(.{ .kind = .other, .external_id = "has-sense" });
    const lexeme = try builder.addEntity(.{ .kind = .lexeme, .source = source_a });
    const form = try builder.addEntity(.{ .kind = .form, .source = source_b });
    const sense = try builder.addEntity(.{ .kind = .sense, .source = source_a });
    _ = try builder.addAssertion(.{ .predicate = predicate, .participants = &.{ .{ .role = "owner", .target = .{ .entity = lexeme } }, .{ .role = "form", .target = .{ .entity = form } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain, .source = source_a });
    _ = try builder.addAssertion(.{ .predicate = sense_predicate, .participants = &.{ .{ .role = "owner", .target = .{ .entity = lexeme } }, .{ .role = "sense", .target = .{ .entity = sense } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain, .source = source_b });
    var model = try builder.build();
    defer model.deinit();
    var evaluator = try Evaluator.init(&model, std.testing.allocator, .{});
    var forms = try evaluator.formsOf(lexeme, .{ .predicate = predicate, .source_role = "owner", .target_role = "form", .target_cardinality = .one });
    defer forms.deinit();
    try std.testing.expectEqual(@as(usize, 1), forms.items.len);
    try std.testing.expectEqual(source_a.index, forms.items[0].edge.scope.entity_source.?.index);
    try std.testing.expectEqual(source_a.index, forms.items[0].edge.scope.assertion_source.?.index);
    var senses = try evaluator.sensesOf(lexeme, .{ .predicate = sense_predicate, .source_role = "owner", .target_role = "sense", .target_cardinality = .one });
    defer senses.deinit();
    try std.testing.expectEqual(@as(usize, 1), senses.items.len);
    try std.testing.expectEqual(source_b.index, senses.items[0].edge.scope.assertion_source.?.index);
}

test "ordered alternatives, overlapping and discontinuous anchors are retained" {
    var builder = semantic.Builder.init(std.testing.allocator);
    defer builder.deinit();
    const source = try builder.addSource(.{ .external_id = "ar" });
    const ns = try builder.addNamespace("urn:test", "t");
    const root_node = try builder.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "form" }, .source = source });
    try builder.addDocumentRoot(root_node);
    const decomposition = try builder.addEntity(.{ .kind = .other, .external_id = "decomp" });
    const surface = try builder.addEntity(.{ .kind = .other, .external_id = "surface" });
    const root = try builder.addEntity(.{ .kind = .form, .external_id = "root", .source = source });
    const part_a = try builder.addEntity(.{ .kind = .other, .external_id = "prefix", .source = source });
    const part_b = try builder.addEntity(.{ .kind = .other, .external_id = "stem", .source = source });
    const part_c = try builder.addEntity(.{ .kind = .other, .external_id = "suffix", .source = source });
    const part_d = try builder.addEntity(.{ .kind = .other, .external_id = "zero", .source = source });
    const whole = try builder.addValue(.{ .text = .{ .bytes = "يكتبون", .language = "ar" } });
    const d0 = try builder.addAssertion(.{ .predicate = decomposition, .participants = &.{ .{ .role = "whole", .target = .{ .entity = root } }, .{ .role = "part", .target = .{ .entity = part_a } }, .{ .role = "part", .target = .{ .entity = part_b } }, .{ .role = "part", .target = .{ .entity = part_d } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain, .source = source });
    const d1 = try builder.addAssertion(.{ .predicate = decomposition, .participants = &.{ .{ .role = "whole", .target = .{ .entity = root } }, .{ .role = "part", .target = .{ .entity = part_c } }, .{ .role = "part", .target = .{ .entity = part_b } } }, .attributes = &.{}, .evidence = &.{}, .state = .inferred, .certainty = .possible, .source = source });
    const sa = try builder.addAssertion(.{ .predicate = surface, .participants = &.{ .{ .role = "part", .target = .{ .entity = part_a } }, .{ .role = "surface", .target = .{ .value = whole } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain, .source = source });
    const sb = try builder.addAssertion(.{ .predicate = surface, .participants = &.{ .{ .role = "part", .target = .{ .entity = part_b } }, .{ .role = "surface", .target = .{ .value = whole } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain, .source = source });
    const sc = try builder.addAssertion(.{ .predicate = surface, .participants = &.{ .{ .role = "part", .target = .{ .entity = part_c } }, .{ .role = "surface", .target = .{ .value = whole } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain, .source = source });
    try builder.addAssertionAnchor(sa, .{ .source = source, .node = root_node, .span = .{ .unit = .utf8_codepoint, .start = 0, .end = 1 } });
    try builder.addAssertionAnchor(sb, .{ .source = source, .node = root_node, .span = .{ .unit = .utf8_codepoint, .start = 1, .end = 4 } });
    try builder.addAssertionAnchor(sb, .{ .source = source, .node = root_node, .span = .{ .unit = .utf8_codepoint, .start = 3, .end = 5 } });
    try builder.addAssertionAnchor(sc, .{ .source = source, .node = root_node, .span = .{ .unit = .utf8_codepoint, .start = 4, .end = 6 } });
    var model = try builder.build();
    defer model.deinit();
    var evaluator = try Evaluator.init(&model, std.testing.allocator, .{});
    const relation = RelationSpec{ .predicate = decomposition, .source_role = "whole", .target_role = "part" };
    const surface_spec = SurfaceSpec{ .relation = .{ .predicate = surface, .source_role = "part", .target_role = "surface", .target_cardinality = .one }, .require_anchor = true };
    var analysis = try evaluator.decompose(root, relation, surface_spec, .{ .max_depth = 1 });
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 6), analysis.parts.len);
    try std.testing.expectEqual(@as(usize, 6), analysis.surfaces.len);
    try std.testing.expectEqual(@as(u32, 0), analysis.parts[1].order.?);
    try std.testing.expectEqual(@as(u32, 1), analysis.parts[2].order.?);
    try std.testing.expectEqual(d0.index, analysis.parts[1].decomposition_assertion.?.index);
    try std.testing.expectEqual(d1.index, analysis.parts[4].decomposition_assertion.?.index);
    try std.testing.expectEqual(@as(usize, 0), analysis.surfacesFor(3).len);
    try std.testing.expectEqual(@as(usize, 2), analysis.surfacesFor(2).len);
}

test "combining marks use scalar spans and grapheme spans are never guessed" {
    var builder = semantic.Builder.init(std.testing.allocator);
    defer builder.deinit();
    const source = try builder.addSource(.{});
    const ns = try builder.addNamespace("urn:test", "t");
    const node = try builder.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "orth" }, .source = source });
    try builder.addDocumentRoot(node);
    const predicate = try builder.addEntity(.{ .kind = .other });
    const owner = try builder.addEntity(.{ .kind = .form, .source = source });
    const text = try builder.addValue(.{ .text = .{ .bytes = "a\xCC\x81", .language = "und" } });
    const assertion = try builder.addAssertion(.{ .predicate = predicate, .participants = &.{ .{ .role = "form", .target = .{ .entity = owner } }, .{ .role = "surface", .target = .{ .value = text } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain, .source = source });
    try builder.addAssertionAnchor(assertion, .{ .source = source, .node = node, .span = .{ .unit = .utf8_codepoint, .start = 0, .end = 2 } });
    var model = try builder.build();
    defer model.deinit();
    var evaluator = try Evaluator.init(&model, std.testing.allocator, .{});
    var result = try evaluator.surfacesOf(owner, .{ .relation = .{ .predicate = predicate, .source_role = "form", .target_role = "surface", .target_cardinality = .one }, .require_anchor = true });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    // The same scalar text can carry a grapheme span, but this core layer
    // refuses to pretend that a grapheme is one scalar without a profile.
    var grapheme_builder = semantic.Builder.init(std.testing.allocator);
    defer grapheme_builder.deinit();
    const grapheme_source = try grapheme_builder.addSource(.{});
    const grapheme_ns = try grapheme_builder.addNamespace("urn:test", "t");
    const grapheme_node = try grapheme_builder.addDocumentNode(.{ .name = .{ .namespace = grapheme_ns, .local = "orth" }, .source = grapheme_source });
    try grapheme_builder.addDocumentRoot(grapheme_node);
    const grapheme_predicate = try grapheme_builder.addEntity(.{ .kind = .other });
    const grapheme_owner = try grapheme_builder.addEntity(.{ .kind = .form, .source = grapheme_source });
    const grapheme_text = try grapheme_builder.addValue(.{ .text = .{ .bytes = "a\xCC\x81" } });
    const grapheme_assertion = try grapheme_builder.addAssertion(.{ .predicate = grapheme_predicate, .participants = &.{ .{ .role = "form", .target = .{ .entity = grapheme_owner } }, .{ .role = "surface", .target = .{ .value = grapheme_text } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain, .source = grapheme_source });
    try grapheme_builder.addAssertionAnchor(grapheme_assertion, .{ .source = grapheme_source, .node = grapheme_node, .span = .{ .unit = .grapheme, .start = 0, .end = 1 } });
    var grapheme_model = try grapheme_builder.build();
    defer grapheme_model.deinit();
    var grapheme_evaluator = try Evaluator.init(&grapheme_model, std.testing.allocator, .{});
    try std.testing.expectError(Error.UnsupportedSpanUnit, grapheme_evaluator.surfacesOf(grapheme_owner, .{ .relation = .{ .predicate = grapheme_predicate, .source_role = "form", .target_role = "surface", .target_cardinality = .one }, .require_anchor = true }));
}

test "invalid references, spans and budgets fail closed" {
    var builder = semantic.Builder.init(std.testing.allocator);
    defer builder.deinit();
    const source = try builder.addSource(.{});
    const ns = try builder.addNamespace("urn:test", "t");
    const node = try builder.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "orth" }, .source = source });
    try builder.addDocumentRoot(node);
    const predicate = try builder.addEntity(.{ .kind = .other });
    const owner = try builder.addEntity(.{ .kind = .form, .source = source });
    const text = try builder.addValue(.{ .text = .{ .bytes = "é" } });
    const assertion = try builder.addAssertion(.{ .predicate = predicate, .participants = &.{ .{ .role = "form", .target = .{ .entity = owner } }, .{ .role = "surface", .target = .{ .value = text } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain, .source = source });
    try builder.addAssertionAnchor(assertion, .{ .source = source, .node = node, .span = .{ .unit = .byte, .start = 1, .end = 2 } });
    var model = try builder.build();
    defer model.deinit();
    var evaluator = try Evaluator.init(&model, std.testing.allocator, .{ .max_scan_items = 0 });
    try std.testing.expectError(Error.BudgetExceeded, evaluator.surfacesOf(owner, .{ .relation = .{ .predicate = predicate, .source_role = "form", .target_role = "surface", .target_cardinality = .one }, .require_anchor = true }));
    var normal = try Evaluator.init(&model, std.testing.allocator, .{});
    try std.testing.expectError(Error.SpanOutOfBounds, normal.surfacesOf(owner, .{ .relation = .{ .predicate = predicate, .source_role = "form", .target_role = "surface", .target_cardinality = .one }, .require_anchor = true }));
    try std.testing.expectError(Error.InvalidReference, normal.related(.{ .index = 99 }, .{ .predicate = predicate, .source_role = "x", .target_role = "y" }));
}

test "German compounds, Hebrew marks, and Japanese forms stay native values" {
    var builder = semantic.Builder.init(std.testing.allocator);
    defer builder.deinit();
    const source = try builder.addSource(.{ .external_id = "multi" });
    const ns = try builder.addNamespace("urn:test", "t");
    const node = try builder.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "forms" }, .source = source });
    try builder.addDocumentRoot(node);
    const surface = try builder.addEntity(.{ .kind = .other, .external_id = "surface" });
    const german = try builder.addEntity(.{ .kind = .form, .external_id = "de", .source = source });
    const japanese = try builder.addEntity(.{ .kind = .form, .external_id = "ja", .source = source });
    const hebrew = try builder.addEntity(.{ .kind = .form, .external_id = "he", .source = source });
    const de_value = try builder.addValue(.{ .text = .{ .bytes = "Donaudampfschiff", .language = "de" } });
    const ja_value = try builder.addValue(.{ .text = .{ .bytes = "食べました", .language = "ja" } });
    const he_value = try builder.addValue(.{ .text = .{ .bytes = "מַלְכָּה", .language = "he" } });
    const de_assertion = try builder.addAssertion(.{ .predicate = surface, .participants = &.{ .{ .role = "form", .target = .{ .entity = german } }, .{ .role = "surface", .target = .{ .value = de_value } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain, .source = source });
    const ja_assertion = try builder.addAssertion(.{ .predicate = surface, .participants = &.{ .{ .role = "form", .target = .{ .entity = japanese } }, .{ .role = "surface", .target = .{ .value = ja_value } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain, .source = source });
    const he_assertion = try builder.addAssertion(.{ .predicate = surface, .participants = &.{ .{ .role = "form", .target = .{ .entity = hebrew } }, .{ .role = "surface", .target = .{ .value = he_value } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain, .source = source });
    try builder.addAssertionAnchor(de_assertion, .{ .source = source, .node = node, .span = .{ .unit = .utf8_codepoint, .start = 0, .end = 16 } });
    try builder.addAssertionAnchor(ja_assertion, .{ .source = source, .node = node, .span = .{ .unit = .utf8_codepoint, .start = 0, .end = 5 } });
    try builder.addAssertionAnchor(he_assertion, .{ .source = source, .node = node, .span = .{ .unit = .utf8_codepoint, .start = 0, .end = 7 } });
    var model = try builder.build();
    defer model.deinit();
    var evaluator = try Evaluator.init(&model, std.testing.allocator, .{});
    const spec = SurfaceSpec{ .relation = .{ .predicate = surface, .source_role = "form", .target_role = "surface", .target_cardinality = .one }, .require_anchor = true };
    var de_result = try evaluator.surfacesOf(german, spec);
    defer de_result.deinit();
    var ja_result = try evaluator.surfacesOf(japanese, spec);
    defer ja_result.deinit();
    var he_result = try evaluator.surfacesOf(hebrew, spec);
    defer he_result.deinit();
    try std.testing.expectEqual(de_value.index, de_result.items[0].value.index);
    try std.testing.expectEqual(ja_value.index, ja_result.items[0].value.index);
    try std.testing.expectEqual(he_value.index, he_result.items[0].value.index);
}
