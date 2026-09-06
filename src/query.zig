const std = @import("std");
const semantic = @import("semantic.zig");

/// Errors raised by the reference evaluator.  BudgetExceeded is deliberately
/// separate from InvalidReference: a caller can retry a valid query with a
/// larger budget, and can never mistake a partial answer for a complete one.
pub const Error = error{
    InvalidReference,
    InvalidStatementReference,
    InvalidArgument,
    BudgetExceeded,
    OutOfMemory,
};

pub const QueryOptions = struct {
    /// Every result is finite even when the caller does not add a per-query
    /// limit.  Callers can raise these values explicitly for larger snapshots.
    max_results: usize = 100_000,
    max_visited_edges: usize = 1_000_000,
    max_scan_items: usize = 1_000_000,
    max_depth: u32 = 64,
    max_result_bytes: usize = 64 * 1024 * 1024,
    /// Temporary membership bitmaps used by source-node semijoins.
    max_temporary_bytes: usize = 8 * 1024 * 1024,
};

pub const Options = QueryOptions;

pub const TargetFilter = union(enum) {
    entity: semantic.EntityId,
    value: semantic.ValueId,
    unresolved_status: semantic.ResolutionStatus,
};

pub const ParticipantFilter = struct {
    role: []const u8,
    target: TargetFilter,
};

pub const AssertionFilter = struct {
    predicate: ?semantic.EntityId = null,
    state: ?semantic.AssertionState = null,
    certainty: ?semantic.Certainty = null,
    participant: ?ParticipantFilter = null,
    context: ?semantic.GraphContext = null,
    source: ?semantic.SourceId = null,
    source_node: ?semantic.DocumentNodeId = null,
};

pub const EntityFilter = struct {
    kind: ?semantic.EntityKind = null,
    source: ?semantic.SourceId = null,
    source_node: ?semantic.DocumentNodeId = null,
};

pub const AnchorFilter = struct {
    source: ?semantic.SourceId = null,
    source_node: ?semantic.DocumentNodeId = null,
};

/// A graph edge is derived from an assertion occurrence, so parallel
/// assertions remain distinguishable in traversal output even when their
/// destination node is the same.
pub const GraphHit = struct {
    entity: semantic.EntityId,
    depth: u32,
    /// Null only for a depth-zero seed result; every discovered node keeps the
    /// exact assertion occurrence that produced it.
    via_assertion: ?semantic.AssertionId,
};

pub const GraphQuery = struct {
    predicate: semantic.EntityId,
    seed: semantic.EntityId,
    min_depth: u32 = 1,
    max_depth: u32 = 1,
    /// Null means any entity-valued participant can be the source.  When a
    /// source role is supplied, only participants with that exact role are
    /// eligible as sources.
    source_role: ?[]const u8 = null,
    /// Null means every other entity-valued participant is a destination.
    target_role: ?[]const u8 = null,
    /// Unique-node traversal is the default.  False returns path occurrences;
    /// finite depth and the edge/result budgets still bound the walk.
    unique_nodes: bool = true,
};

pub const EntityResult = struct {
    allocator: std.mem.Allocator,
    ids: []semantic.EntityId,

    pub fn deinit(self: *EntityResult) void {
        self.allocator.free(self.ids);
        self.* = undefined;
    }
};

pub const AssertionResult = struct {
    allocator: std.mem.Allocator,
    ids: []semantic.AssertionId,

    pub fn deinit(self: *AssertionResult) void {
        self.allocator.free(self.ids);
        self.* = undefined;
    }
};

pub const GraphResult = struct {
    allocator: std.mem.Allocator,
    hits: []GraphHit,

    pub fn deinit(self: *GraphResult) void {
        self.allocator.free(self.hits);
        self.* = undefined;
    }

    pub fn ids(self: GraphResult) []const GraphHit {
        return self.hits;
    }
};

/// Attribute names and their value IDs are copied into the result.  The
/// values themselves remain in the pinned model and are read with
/// `Evaluator.value`; this keeps a result small while making the array and
/// qualified-name storage independently owned and safely releasable.
pub const AttributeResult = struct {
    allocator: std.mem.Allocator,
    items: []semantic.Attribute,

    pub fn deinit(self: *AttributeResult) void {
        for (self.items) |attribute| {
            self.allocator.free(attribute.name.local);
            self.allocator.free(attribute.name.prefix);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const DocumentResult = struct {
    allocator: std.mem.Allocator,
    ids: []semantic.DocumentNodeId,

    pub fn deinit(self: *DocumentResult) void {
        self.allocator.free(self.ids);
        self.* = undefined;
    }
};

pub const EntityAnchorResult = struct {
    allocator: std.mem.Allocator,
    items: []semantic.EntityAnchor,

    pub fn deinit(self: *EntityAnchorResult) void {
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const AssertionAnchorResult = struct {
    allocator: std.mem.Allocator,
    items: []semantic.AssertionAnchor,

    pub fn deinit(self: *AssertionAnchorResult) void {
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

/// A deterministic, scan-based reference evaluator.  It intentionally has no
/// indexes yet: every operation scans model arrays in insertion order and
/// therefore provides the semantic oracle for future indexed implementations.
pub const Evaluator = struct {
    model: *const semantic.Model,
    allocator: std.mem.Allocator,
    options: QueryOptions,

    pub fn init(model: *const semantic.Model, allocator: std.mem.Allocator, options: QueryOptions) Error!Evaluator {
        return .{ .model = model, .allocator = allocator, .options = options };
    }

    pub fn selectEntities(self: *const Evaluator, kind: semantic.EntityKind) Error!EntityResult {
        return self.filterEntities(.{ .kind = kind });
    }

    pub fn filterEntities(self: *const Evaluator, filter: EntityFilter) Error!EntityResult {
        if (filter.source) |source| try self.requireSource(source);
        if (filter.source_node) |node| try self.validateNodeFilter(filter.source, node);
        try self.ensureScan(self.model.entities.len);
        var node_matches = if (filter.source_node) |node| try self.anchorMembership(.entity, node, filter.source) else null;
        defer if (node_matches) |*bits| bits.deinit(self.allocator);
        var ids: std.ArrayList(semantic.EntityId) = .empty;
        errdefer ids.deinit(self.allocator);
        for (self.model.entities, 0..) |entity, index| {
            if (entity.source) |source| try self.requireSource(source);
            if (filter.kind) |kind| if (entity.kind != kind) continue;
            if (filter.source) |source| if (entity.source == null or entity.source.?.index != source.index) continue;
            if (node_matches) |bits| if (!bits.isSet(index)) continue;
            try self.appendBounded(semantic.EntityId, &ids, .{ .index = @intCast(index) });
        }
        return .{ .allocator = self.allocator, .ids = try ids.toOwnedSlice(self.allocator) };
    }

    pub fn filterAssertions(self: *const Evaluator, filter: AssertionFilter) Error!AssertionResult {
        if (filter.predicate) |predicate| try self.requireEntity(predicate);
        if (filter.source) |source| try self.requireSource(source);
        if (filter.source_node) |node| try self.validateNodeFilter(filter.source, node);
        if (filter.participant) |participant| switch (participant.target) {
            .entity => |id| try self.requireEntity(id),
            .value => |id| try self.requireValue(id),
            .unresolved_status => {},
        };
        if (filter.context) |context| try self.validateContext(context);
        try self.ensureScan(self.model.assertions.len);
        var node_matches = if (filter.source_node) |node| try self.anchorMembership(.assertion, node, filter.source) else null;
        defer if (node_matches) |*bits| bits.deinit(self.allocator);
        var ids: std.ArrayList(semantic.AssertionId) = .empty;
        errdefer ids.deinit(self.allocator);
        for (self.model.assertions, 0..) |assertion_value, index| {
            try self.validateAssertion(assertion_value, index);
            if (filter.predicate) |predicate| if (assertion_value.predicate.index != predicate.index) continue;
            if (filter.state) |state| if (assertion_value.state != state) continue;
            if (filter.certainty) |certainty| if (assertion_value.certainty != certainty) continue;
            if (filter.participant) |participant| if (!hasParticipant(assertion_value, participant)) continue;
            if (filter.context) |context| if (!contextEqual(assertion_value.context, context)) continue;
            if (filter.source) |source| if (assertion_value.source == null or assertion_value.source.?.index != source.index) continue;
            if (node_matches) |bits| if (!bits.isSet(index)) continue;
            try self.appendBounded(semantic.AssertionId, &ids, .{ .index = @intCast(index) });
        }
        return .{ .allocator = self.allocator, .ids = try ids.toOwnedSlice(self.allocator) };
    }

    /// Returns every typed entity-to-source occurrence in insertion order.
    /// Equal entity IDs are intentionally retained when they have multiple
    /// anchors: these records represent occurrences, not a set.
    pub fn entityAnchors(self: *const Evaluator, filter: AnchorFilter) Error!EntityAnchorResult {
        try self.validateAnchorFilter(filter);
        try self.ensureScan(self.model.entity_anchors.len);
        var items: std.ArrayList(semantic.EntityAnchor) = .empty;
        errdefer items.deinit(self.allocator);
        for (self.model.entity_anchors) |item| {
            try self.validateEntityAnchor(item);
            if (!anchorMatches(item.anchor, filter)) continue;
            try self.appendBounded(semantic.EntityAnchor, &items, item);
        }
        return .{ .allocator = self.allocator, .items = try items.toOwnedSlice(self.allocator) };
    }

    /// Returns assertion occurrence anchors without collapsing parallel
    /// assertions or repeated mappings.
    pub fn assertionAnchors(self: *const Evaluator, filter: AnchorFilter) Error!AssertionAnchorResult {
        try self.validateAnchorFilter(filter);
        try self.ensureScan(self.model.assertion_anchors.len);
        var items: std.ArrayList(semantic.AssertionAnchor) = .empty;
        errdefer items.deinit(self.allocator);
        for (self.model.assertion_anchors) |item| {
            try self.validateAssertionAnchor(item);
            if (!anchorMatches(item.anchor, filter)) continue;
            try self.appendBounded(semantic.AssertionAnchor, &items, item);
        }
        return .{ .allocator = self.allocator, .items = try items.toOwnedSlice(self.allocator) };
    }

    /// Traverses assertion edges in breadth-first, assertion-storage order.
    /// For each matching assertion, the source participant is paired with each
    /// destination participant.  A role-aware query can express ordinary
    /// binary edges; the role-free form also handles n-ary assertions without
    /// throwing away entity-valued participants.
    pub fn traverse(self: *const Evaluator, query: GraphQuery) Error!GraphResult {
        try self.requireEntity(query.predicate);
        try self.requireEntity(query.seed);
        if (query.min_depth > query.max_depth or query.max_depth > self.options.max_depth) return Error.InvalidArgument;

        var hits: std.ArrayList(GraphHit) = .empty;
        errdefer hits.deinit(self.allocator);
        var queue: std.ArrayList(QueueItem) = .empty;
        defer queue.deinit(self.allocator);

        var visited: []bool = &.{};
        defer if (query.unique_nodes and visited.len != 0) self.allocator.free(visited);
        if (query.unique_nodes) {
            try self.ensureScan(self.model.entities.len);
            visited = try self.allocator.alloc(bool, self.model.entities.len);
            @memset(visited, false);
            visited[query.seed.index] = true;
        }
        try queue.append(self.allocator, .{ .entity = query.seed, .depth = 0 });
        if (query.min_depth == 0) try self.appendBounded(GraphHit, &hits, .{ .entity = query.seed, .depth = 0, .via_assertion = null });

        var queue_index: usize = 0;
        var visited_edges: usize = 0;
        var scanned: usize = 0;
        while (queue_index < queue.items.len) : (queue_index += 1) {
            const current = queue.items[queue_index];
            if (current.depth >= query.max_depth) continue;
            for (self.model.assertions, 0..) |assertion_value, assertion_index| {
                scanned = try checkedBudgetIncrement(scanned, self.options.max_scan_items);
                try self.validateAssertion(assertion_value, assertion_index);
                if (assertion_value.predicate.index != query.predicate.index) continue;
                for (assertion_value.participants, 0..) |source, source_index| {
                    if (source.target != .entity or source.target.entity.index != current.entity.index) continue;
                    if (query.source_role) |role| if (!std.mem.eql(u8, source.role, role)) continue;
                    for (assertion_value.participants, 0..) |destination, destination_index| {
                        if (source_index == destination_index) continue;
                        if (destination.target != .entity) continue;
                        if (query.target_role) |role| if (!std.mem.eql(u8, destination.role, role)) continue;
                        visited_edges = try checkedBudgetIncrement(visited_edges, self.options.max_visited_edges);
                        const next = destination.target.entity;
                        if (next.index >= self.model.entities.len) return Error.InvalidReference;
                        const next_depth = current.depth + 1;
                        if (query.unique_nodes) {
                            if (visited[next.index]) continue;
                            visited[next.index] = true;
                        }
                        if (next_depth >= query.min_depth) try self.appendBounded(GraphHit, &hits, .{ .entity = next, .depth = next_depth, .via_assertion = .{ .index = @intCast(assertion_index) } });
                        try queue.append(self.allocator, .{ .entity = next, .depth = next_depth });
                    }
                }
            }
        }
        return .{ .allocator = self.allocator, .hits = try hits.toOwnedSlice(self.allocator) };
    }

    pub fn children(self: *const Evaluator, node: semantic.DocumentNodeId) Error!DocumentResult {
        const document_node = try self.document(node);
        var ids: std.ArrayList(semantic.DocumentNodeId) = .empty;
        errdefer ids.deinit(self.allocator);
        for (document_node.children) |child| if (child == .node) try self.appendBounded(semantic.DocumentNodeId, &ids, child.node);
        return .{ .allocator = self.allocator, .ids = try ids.toOwnedSlice(self.allocator) };
    }

    pub fn parent(self: *const Evaluator, node: semantic.DocumentNodeId) Error!?semantic.DocumentNodeId {
        return (try self.document(node)).parent;
    }

    pub fn documentAttributes(self: *const Evaluator, node: semantic.DocumentNodeId) Error!AttributeResult {
        const source = try self.document(node);
        try self.validateAttributes(source.attributes);
        return self.copyAttributes(source.attributes);
    }

    pub fn assertionAttributes(self: *const Evaluator, assertion_id: semantic.AssertionId) Error!AttributeResult {
        const source = try self.assertion(assertion_id);
        try self.validateAssertion(source, assertion_id.index);
        return self.copyAttributes(source.attributes);
    }

    pub fn assertionContext(self: *const Evaluator, assertion_id: semantic.AssertionId) Error!semantic.GraphContext {
        const source = try self.assertion(assertion_id);
        try self.validateAssertion(source, assertion_id.index);
        return source.context;
    }

    pub fn value(self: *const Evaluator, id: semantic.ValueId) Error!semantic.Value {
        return try self.valueAt(id);
    }

    fn document(self: *const Evaluator, id: semantic.DocumentNodeId) Error!semantic.DocumentNode {
        if (id.index >= self.model.documents.len) return Error.InvalidReference;
        return self.model.document(id) catch Error.InvalidReference;
    }

    fn assertion(self: *const Evaluator, id: semantic.AssertionId) Error!semantic.Assertion {
        if (id.index >= self.model.assertions.len) return Error.InvalidReference;
        return self.model.assertions[id.index];
    }

    fn valueAt(self: *const Evaluator, id: semantic.ValueId) Error!semantic.Value {
        if (id.index >= self.model.values.len) return Error.InvalidReference;
        return self.model.values[id.index];
    }

    fn requireEntity(self: *const Evaluator, id: semantic.EntityId) Error!void {
        if (id.index >= self.model.entities.len) return Error.InvalidReference;
    }

    fn requireValue(self: *const Evaluator, id: semantic.ValueId) Error!void {
        if (id.index >= self.model.values.len) return Error.InvalidReference;
    }

    fn requireDocument(self: *const Evaluator, id: semantic.DocumentNodeId) Error!void {
        if (id.index >= self.model.documents.len) return Error.InvalidReference;
    }

    fn requireNamespace(self: *const Evaluator, id: semantic.NamespaceId) Error!void {
        if (id.index >= self.model.namespaces.len) return Error.InvalidReference;
    }

    fn requireSource(self: *const Evaluator, id: semantic.SourceId) Error!void {
        if (id.index >= self.model.sources.len) return Error.InvalidReference;
    }

    fn validateNodeFilter(self: *const Evaluator, source: ?semantic.SourceId, node: semantic.DocumentNodeId) Error!void {
        try self.requireDocument(node);
        if (source) |source_id| if (self.model.documents[node.index].source) |node_source| if (node_source.index != source_id.index) return Error.InvalidArgument;
    }

    /// One anchor scan and one bit per candidate replace a nested scan. The
    /// bitmap is query-local; no reverse graph is persisted or occurrences
    /// deduplicated. The enclosing semijoin returns each candidate once.
    fn anchorMembership(self: *const Evaluator, comptime domain: enum { entity, assertion }, node: semantic.DocumentNodeId, source: ?semantic.SourceId) Error!std.DynamicBitSetUnmanaged {
        const anchors = if (domain == .entity) self.model.entity_anchors else self.model.assertion_anchors;
        const count = if (domain == .entity) self.model.entities.len else self.model.assertions.len;
        const scan_count = std.math.add(usize, count, anchors.len) catch return Error.BudgetExceeded;
        try self.ensureScan(scan_count);
        const words = count / @bitSizeOf(usize) + @intFromBool(count % @bitSizeOf(usize) != 0);
        const storage_bytes = if (count == 0) 0 else std.math.mul(usize, words + 1, @sizeOf(usize)) catch return Error.BudgetExceeded;
        if (storage_bytes > self.options.max_temporary_bytes) return Error.BudgetExceeded;
        var bits = try std.DynamicBitSetUnmanaged.initEmpty(self.allocator, count);
        errdefer bits.deinit(self.allocator);
        for (anchors) |item| {
            if (domain == .entity) try self.validateEntityAnchor(item) else try self.validateAssertionAnchor(item);
            if (item.anchor.node.index != node.index) continue;
            if (source) |id| if (item.anchor.source.index != id.index) continue;
            const id = @field(item, if (domain == .entity) "entity" else "assertion");
            bits.set(id.index);
        }
        return bits;
    }

    fn validateAnchorFilter(self: *const Evaluator, filter: AnchorFilter) Error!void {
        if (filter.source) |source| try self.requireSource(source);
        if (filter.source_node) |node| try self.validateNodeFilter(filter.source, node);
    }

    fn validateEntityAnchor(self: *const Evaluator, item: semantic.EntityAnchor) Error!void {
        try self.requireEntity(item.entity);
        try self.validateAnchor(item.anchor);
    }

    fn validateAssertionAnchor(self: *const Evaluator, item: semantic.AssertionAnchor) Error!void {
        if (item.assertion.index >= self.model.assertions.len) return Error.InvalidReference;
        try self.validateAnchor(item.anchor);
    }

    fn validateAnchor(self: *const Evaluator, anchor: semantic.SourceAnchor) Error!void {
        try self.requireSource(anchor.source);
        try self.requireDocument(anchor.node);
        if (self.model.documents[anchor.node.index].source) |source| if (source.index != anchor.source.index) return Error.InvalidArgument;
        if (anchor.span) |span| if (span.start > span.end) return Error.InvalidArgument;
    }

    fn validateAttributes(self: *const Evaluator, attributes: []const semantic.Attribute) Error!void {
        for (attributes) |attribute| {
            try self.requireNamespace(attribute.name.namespace);
            try self.requireValue(attribute.value);
        }
    }

    /// Models are public value aggregates and may come from a decoder or an
    /// unsafe adapter rather than Builder.  Every query path that consumes an
    /// assertion validates its references before matching or traversing it;
    /// this keeps malformed snapshots from becoming out-of-bounds reads or
    /// silently absent results.
    fn validateAssertion(self: *const Evaluator, assertion_value: semantic.Assertion, assertion_index: usize) Error!void {
        try self.requireEntity(assertion_value.predicate);
        if (assertion_value.participants.len < 2) return Error.InvalidArgument;
        for (assertion_value.participants) |participant| switch (participant.target) {
            .entity => |id| try self.requireEntity(id),
            .value => |id| try self.requireValue(id),
            .statement => |id| if (id.index >= assertion_index or id.index >= self.model.assertions.len) return Error.InvalidStatementReference,
            .unresolved => {},
        };
        try self.validateAttributes(assertion_value.attributes);
        if (assertion_value.source) |source| try self.requireSource(source);
        for (assertion_value.evidence) |evidence| {
            if (evidence.source) |id| try self.requireEntity(id);
            if (evidence.document) |id| try self.requireDocument(id);
            if (evidence.quote) |id| try self.requireValue(id);
            if (evidence.provenance) |id| try self.requireValue(id);
            try self.validateAttributes(evidence.attributes);
        }
        try self.validateContext(assertion_value.context);
    }

    fn validateContext(self: *const Evaluator, context: semantic.GraphContext) Error!void {
        switch (context) {
            .default => {},
            .named => |id| try self.requireEntity(id),
            .anonymous => |anonymous| if (anonymous.source) |source| switch (source) {
                .entity => |id| try self.requireEntity(id),
                .document => |id| try self.requireDocument(id),
            },
        }
    }

    fn ensureScan(self: *const Evaluator, count: usize) Error!void {
        if (count > self.options.max_scan_items) return Error.BudgetExceeded;
    }

    fn appendBounded(self: *const Evaluator, comptime T: type, list: *std.ArrayList(T), item: T) Error!void {
        if (list.items.len >= self.options.max_results) return Error.BudgetExceeded;
        const next_len = list.items.len + 1;
        const bytes = @mulWithOverflow(next_len, @sizeOf(T));
        if (bytes[1] != 0 or bytes[0] > self.options.max_result_bytes) return Error.BudgetExceeded;
        try list.append(self.allocator, item);
    }

    fn copyAttributes(self: *const Evaluator, source: []const semantic.Attribute) Error!AttributeResult {
        if (source.len > self.options.max_results) return Error.BudgetExceeded;
        var required_bytes = std.math.mul(usize, source.len, @sizeOf(semantic.Attribute)) catch return Error.BudgetExceeded;
        for (source) |attribute| {
            required_bytes = checkedByteSum(required_bytes, attribute.name.local.len) catch return Error.BudgetExceeded;
            required_bytes = checkedByteSum(required_bytes, attribute.name.prefix.len) catch return Error.BudgetExceeded;
        }
        if (required_bytes > self.options.max_result_bytes) return Error.BudgetExceeded;
        const items = try self.allocator.alloc(semantic.Attribute, source.len);
        var copied: usize = 0;
        errdefer {
            for (items[0..copied]) |attribute| {
                self.allocator.free(attribute.name.local);
                self.allocator.free(attribute.name.prefix);
            }
            self.allocator.free(items);
        }
        for (source, 0..) |attribute, index| {
            const local = try self.allocator.dupe(u8, attribute.name.local);
            errdefer self.allocator.free(local);
            const prefix = try self.allocator.dupe(u8, attribute.name.prefix);
            errdefer self.allocator.free(prefix);
            items[index] = .{
                .name = .{
                    .namespace = attribute.name.namespace,
                    .local = local,
                    .prefix = prefix,
                },
                .value = attribute.value,
            };
            copied += 1;
        }
        return .{ .allocator = self.allocator, .items = items };
    }

    const QueueItem = struct { entity: semantic.EntityId, depth: u32 };
};

pub const Query = Evaluator;

fn checkedBudgetIncrement(current: usize, limit: usize) Error!usize {
    if (current >= limit) return Error.BudgetExceeded;
    return current + 1;
}

fn checkedByteSum(count: usize, width: usize) !usize {
    const result = @addWithOverflow(count, width);
    if (result[1] != 0) return error.Overflow;
    return result[0];
}

fn hasParticipant(assertion: semantic.Assertion, filter: ParticipantFilter) bool {
    for (assertion.participants) |participant| {
        if (!std.mem.eql(u8, participant.role, filter.role)) continue;
        switch (filter.target) {
            .entity => |id| if (participant.target == .entity and participant.target.entity.index == id.index) return true,
            .value => |id| if (participant.target == .value and participant.target.value.index == id.index) return true,
            .unresolved_status => |status| if (participant.target == .unresolved and participant.target.unresolved.status == status) return true,
        }
    }
    return false;
}

fn anchorMatches(anchor: semantic.SourceAnchor, filter: AnchorFilter) bool {
    if (filter.source) |source| if (anchor.source.index != source.index) return false;
    if (filter.source_node) |node| if (anchor.node.index != node.index) return false;
    return true;
}

fn contextEqual(a: semantic.GraphContext, b: semantic.GraphContext) bool {
    return switch (a) {
        .default => b == .default,
        .named => |a_id| b == .named and b.named.index == a_id.index,
        .anonymous => |a_value| switch (b) {
            .anonymous => |b_value| a_value.id == b_value.id and contextSourceEqual(a_value.source, b_value.source),
            else => false,
        },
    };
}

fn contextSourceEqual(a: ?semantic.ContextSource, b: ?semantic.ContextSource) bool {
    if (a == null or b == null) return a == null and b == null;
    return switch (a.?) {
        .entity => |a_id| b.? == .entity and b.?.entity.index == a_id.index,
        .document => |a_id| b.? == .document and b.?.document.index == a_id.index,
    };
}

test "typed scans preserve entity and assertion occurrence order" {
    var model = try fixture();
    defer model.deinit();
    var evaluator = try Evaluator.init(&model, std.testing.allocator, .{});

    var entities = try evaluator.selectEntities(.sense);
    defer entities.deinit();
    try std.testing.expectEqual(@as(usize, 2), entities.ids.len);
    try std.testing.expectEqual(@as(u32, 2), entities.ids[0].index);
    try std.testing.expectEqual(@as(u32, 3), entities.ids[1].index);

    var assertions = try evaluator.filterAssertions(.{
        .predicate = .{ .index = 5 },
        .participant = .{ .role = "target", .target = .{ .unresolved_status = .unresolved } },
    });
    defer assertions.deinit();
    try std.testing.expectEqual(@as(usize, 1), assertions.ids.len);
    try std.testing.expectEqual(@as(u32, 0), assertions.ids[0].index);
}

test "parallel assertions remain visible and retracted state is queryable" {
    var model = try fixture();
    defer model.deinit();
    var evaluator = try Evaluator.init(&model, std.testing.allocator, .{});
    var result = try evaluator.filterAssertions(.{ .predicate = .{ .index = 5 } });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.ids.len);
    try std.testing.expectEqual(@as(u32, 0), result.ids[0].index);
    try std.testing.expectEqual(@as(u32, 1), result.ids[1].index);

    var retracted = try evaluator.filterAssertions(.{ .state = .retracted, .certainty = .possible });
    defer retracted.deinit();
    try std.testing.expectEqual(@as(usize, 1), retracted.ids.len);
    try std.testing.expectEqual(@as(u32, 1), retracted.ids[0].index);
}

test "assertion context is queryable without attribute conventions" {
    var model = try fixture();
    defer model.deinit();
    var evaluator = try Evaluator.init(&model, std.testing.allocator, .{});
    var named = try evaluator.filterAssertions(.{ .context = .{ .named = .{ .index = 1 } } });
    defer named.deinit();
    try std.testing.expectEqual(@as(usize, 1), named.ids.len);
    try std.testing.expectEqual(@as(u32, 1), named.ids[0].index);
    const context = try evaluator.assertionContext(named.ids[0]);
    try std.testing.expect(context == .named);
    try std.testing.expectEqual(@as(u32, 1), context.named.index);
}

test "cycle traversal uses unique nodes and returns explicit budget errors" {
    var model = try fixture();
    defer model.deinit();
    var evaluator = try Evaluator.init(&model, std.testing.allocator, .{});
    var graph = try evaluator.traverse(.{ .predicate = .{ .index = 6 }, .seed = .{ .index = 2 }, .max_depth = 8, .source_role = "source", .target_role = "target" });
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), graph.hits.len);
    try std.testing.expectEqual(@as(u32, 3), graph.hits[0].entity.index);
    try std.testing.expectEqual(@as(u32, 2), graph.hits[0].via_assertion.?.index);

    var limited = try Evaluator.init(&model, std.testing.allocator, .{ .max_visited_edges = 1 });
    try std.testing.expectError(Error.BudgetExceeded, limited.traverse(.{ .predicate = .{ .index = 6 }, .seed = .{ .index = 2 }, .max_depth = 8, .source_role = "source", .target_role = "target" }));
}

test "document axes and attributes preserve mixed content" {
    var model = try fixture();
    defer model.deinit();
    var evaluator = try Evaluator.init(&model, std.testing.allocator, .{});
    var children = try evaluator.children(.{ .index = 0 });
    defer children.deinit();
    try std.testing.expectEqual(@as(usize, 1), children.ids.len);
    try std.testing.expectEqual(@as(u32, 1), children.ids[0].index);
    try std.testing.expectEqual(@as(?semantic.DocumentNodeId, .{ .index = 0 }), try evaluator.parent(.{ .index = 1 }));

    var attributes = try evaluator.documentAttributes(.{ .index = 0 });
    defer attributes.deinit();
    try std.testing.expectEqual(@as(usize, 1), attributes.items.len);
    try std.testing.expectEqualStrings("type", attributes.items[0].name.local);
}

test "a result limit never silently truncates" {
    var model = try fixture();
    defer model.deinit();
    var evaluator = try Evaluator.init(&model, std.testing.allocator, .{ .max_results = 1 });
    try std.testing.expectError(Error.BudgetExceeded, evaluator.filterAssertions(.{ .predicate = .{ .index = 5 } }));
}

test "query validation rejects malformed public model references" {
    const malformed = semantic.Model{
        .allocator = std.testing.allocator,
        .namespaces = &.{},
        .sources = &.{},
        .values = &.{},
        .entities = &.{.{ .kind = .sense }},
        .assertions = &.{.{
            .predicate = .{ .index = 0 },
            .participants = &.{
                .{ .role = "source", .target = .{ .entity = .{ .index = 99 } } },
                .{ .role = "target", .target = .{ .value = .{ .index = 88 } } },
            },
            .attributes = &.{},
            .evidence = &.{},
            .state = .asserted,
            .certainty = .certain,
        }},
        .documents = &.{},
        .roots = &.{},
        .entity_anchors = &.{},
        .assertion_anchors = &.{},
    };
    var evaluator = try Evaluator.init(&malformed, std.testing.allocator, .{});
    try std.testing.expectError(Error.InvalidReference, evaluator.filterAssertions(.{}));
    try std.testing.expectError(Error.InvalidReference, evaluator.traverse(.{ .predicate = .{ .index = 0 }, .seed = .{ .index = 0 } }));
}

test "attribute result budget includes copied qualified name bytes" {
    var model = try fixture();
    defer model.deinit();
    const attribute = model.documents[0].attributes[0];
    const structural = @sizeOf(semantic.Attribute);
    const names = attribute.name.local.len + attribute.name.prefix.len;
    var evaluator = try Evaluator.init(&model, std.testing.allocator, .{ .max_result_bytes = structural + names - 1 });
    try std.testing.expectError(Error.BudgetExceeded, evaluator.documentAttributes(.{ .index = 0 }));
}

test "source scope and anchors are bounded query dimensions" {
    var b = semantic.Builder.init(std.testing.allocator);
    defer b.deinit();
    const ns = try b.addNamespace("urn:tei", "tei");
    const source_a = try b.addSource(.{ .external_id = "same.xml", .base_uri = "https://example.test/a/" });
    const source_b = try b.addSource(.{ .external_id = "same.xml", .base_uri = "https://example.test/b/" });
    const predicate = try b.addEntity(.{ .kind = .other });
    const entry_a = try b.addEntity(.{ .kind = .entry, .external_id = "entry", .source = source_a });
    const entry_b = try b.addEntity(.{ .kind = .entry, .external_id = "entry", .source = source_b });
    const root_a = try b.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "entry" }, .source = source_a });
    const root_b = try b.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "entry" }, .source = source_b });
    try b.addDocumentRoot(root_a);
    try b.addDocumentRoot(root_b);
    try b.addEntityAnchor(entry_a, .{ .source = source_a, .node = root_a, .span = .{ .unit = .byte, .start = 1, .end = 2 } });
    try b.addEntityAnchor(entry_b, .{ .source = source_b, .node = root_b, .span = .{ .unit = .byte, .start = 3, .end = 4 } });
    const assertion_a = try b.addAssertion(.{ .predicate = predicate, .participants = &.{ .{ .role = "entry", .target = .{ .entity = entry_a } }, .{ .role = "entry", .target = .{ .entity = entry_a } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain, .source = source_a });
    const assertion_b = try b.addAssertion(.{ .predicate = predicate, .participants = &.{ .{ .role = "entry", .target = .{ .entity = entry_b } }, .{ .role = "entry", .target = .{ .entity = entry_b } } }, .attributes = &.{}, .evidence = &.{}, .state = .asserted, .certainty = .certain, .source = source_b });
    try b.addAssertionAnchor(assertion_a, .{ .source = source_a, .node = root_a });
    try b.addAssertionAnchor(assertion_b, .{ .source = source_b, .node = root_b });
    var model = try b.build();
    defer model.deinit();
    var evaluator = try Evaluator.init(&model, std.testing.allocator, .{ .max_results = 4 });
    var entities = try evaluator.filterEntities(.{ .kind = .entry, .source = source_b });
    defer entities.deinit();
    try std.testing.expectEqual(@as(usize, 1), entities.ids.len);
    try std.testing.expectEqual(entry_b.index, entities.ids[0].index);
    var by_node = try evaluator.filterEntities(.{ .source_node = root_a });
    defer by_node.deinit();
    try std.testing.expectEqual(@as(usize, 1), by_node.ids.len);
    try std.testing.expectEqual(entry_a.index, by_node.ids[0].index);
    var entity_anchors = try evaluator.entityAnchors(.{ .source = source_a });
    defer entity_anchors.deinit();
    try std.testing.expectEqual(@as(usize, 1), entity_anchors.items.len);
    var assertion_anchors = try evaluator.assertionAnchors(.{ .source_node = root_b });
    defer assertion_anchors.deinit();
    try std.testing.expectEqual(@as(usize, 1), assertion_anchors.items.len);
    try std.testing.expectEqual(assertion_b.index, assertion_anchors.items[0].assertion.index);
    try std.testing.expectError(Error.BudgetExceeded, (try Evaluator.init(&model, std.testing.allocator, .{ .max_results = 0 })).entityAnchors(.{}));
}

test "source-node semijoin charges aggregate scan work and temporary bits" {
    var b = semantic.Builder.init(std.testing.allocator);
    defer b.deinit();
    const ns = try b.addNamespace("urn:test", "");
    const source = try b.addSource(.{});
    const entity = try b.addEntity(.{ .kind = .entry, .source = source });
    const root = try b.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "entry" }, .source = source });
    try b.addDocumentRoot(root);
    try b.addEntityAnchor(entity, .{ .source = source, .node = root });
    var model = try b.build();
    defer model.deinit();

    // One candidate plus one anchor is two units of work. Checking each array
    // against the limit separately used to admit this query at a limit of one.
    const scan_limited = try Evaluator.init(&model, std.testing.allocator, .{ .max_scan_items = 1 });
    try std.testing.expectError(Error.BudgetExceeded, scan_limited.filterEntities(.{ .source_node = root }));

    // The membership bitmap is explicit query memory and obeys its own cap.
    const memory_limited = try Evaluator.init(&model, std.testing.allocator, .{ .max_scan_items = 2, .max_temporary_bytes = 0 });
    try std.testing.expectError(Error.BudgetExceeded, memory_limited.filterEntities(.{ .source_node = root }));

    var result = try (try Evaluator.init(&model, std.testing.allocator, .{ .max_scan_items = 2 })).filterEntities(.{ .source_node = root });
    defer result.deinit();
    try std.testing.expectEqualSlices(semantic.EntityId, &.{entity}, result.ids);
}

test "attribute byte budget charges every result structure" {
    var b = semantic.Builder.init(std.testing.allocator);
    defer b.deinit();
    const ns = try b.addNamespace("urn:test", "");
    const value = try b.addValue(.{ .text = .{ .bytes = "v" } });
    const root = try b.addDocumentNode(.{
        .name = .{ .namespace = ns, .local = "entry" },
        .attributes = &.{
            .{ .name = .{ .namespace = ns, .local = "a" }, .value = value },
            .{ .name = .{ .namespace = ns, .local = "b" }, .value = value },
        },
    });
    try b.addDocumentRoot(root);
    var model = try b.build();
    defer model.deinit();

    const exact_bytes = 2 * @sizeOf(semantic.Attribute) + 2;
    const too_small = try Evaluator.init(&model, std.testing.allocator, .{ .max_result_bytes = exact_bytes - 1 });
    try std.testing.expectError(Error.BudgetExceeded, too_small.documentAttributes(root));
    var exact = try (try Evaluator.init(&model, std.testing.allocator, .{ .max_result_bytes = exact_bytes })).documentAttributes(root);
    defer exact.deinit();
    try std.testing.expectEqual(@as(usize, 2), exact.items.len);
}

fn fixture() !semantic.Model {
    var builder = semantic.Builder.init(std.testing.allocator);
    defer builder.deinit();
    const ns = try builder.addNamespace("urn:tei", "tei");
    const bank = try builder.addValue(.{ .text = .{ .bytes = "bank", .language = "en" } });
    const banque = try builder.addValue(.{ .text = .{ .bytes = "banque", .language = "fr" } });
    const source = try builder.addEntity(.{ .kind = .source, .external_id = "source-a" });
    const source_b = try builder.addEntity(.{ .kind = .source, .external_id = "source-b" });
    const financial = try builder.addEntity(.{ .kind = .sense, .external_id = "financial", .label = bank });
    const river = try builder.addEntity(.{ .kind = .sense, .external_id = "river", .label = bank });
    _ = try builder.addEntity(.{ .kind = .other, .external_id = "unused" });
    const translation = try builder.addEntity(.{ .kind = .other, .external_id = "translation" });
    const related = try builder.addEntity(.{ .kind = .other, .external_id = "related" });
    _ = try builder.addAssertion(.{
        .predicate = translation,
        .participants = &.{
            .{ .role = "source", .target = .{ .entity = financial } },
            .{ .role = "target", .target = .{ .unresolved = .{ .bytes = "banque", .label = "banque", .status = .unresolved } } },
        },
        .attributes = &.{},
        .evidence = &.{.{ .source = source, .quote = banque }},
        .state = .asserted,
        .certainty = .certain,
    });
    _ = try builder.addAssertion(.{
        .predicate = translation,
        .participants = &.{
            .{ .role = "source", .target = .{ .entity = financial } },
            .{ .role = "target", .target = .{ .value = banque } },
        },
        .attributes = &.{},
        .evidence = &.{.{ .source = source_b, .quote = banque }},
        .state = .retracted,
        .certainty = .possible,
        .context = .{ .named = source_b },
    });
    _ = try builder.addAssertion(.{
        .predicate = related,
        .participants = &.{
            .{ .role = "source", .target = .{ .entity = financial } },
            .{ .role = "target", .target = .{ .entity = river } },
        },
        .attributes = &.{},
        .evidence = &.{},
        .state = .asserted,
        .certainty = .certain,
    });
    _ = try builder.addAssertion(.{
        .predicate = related,
        .participants = &.{
            .{ .role = "source", .target = .{ .entity = river } },
            .{ .role = "target", .target = .{ .entity = financial } },
        },
        .attributes = &.{},
        .evidence = &.{},
        .state = .asserted,
        .certainty = .certain,
    });
    const attr_value = try builder.addValue(.{ .text = .{ .bytes = "translation" } });
    const root = try builder.addDocumentNode(.{
        .name = .{ .namespace = ns, .local = "entry", .prefix = "tei" },
        .attributes = &.{.{ .name = .{ .namespace = ns, .local = "type", .prefix = "tei" }, .value = attr_value }},
    });
    const child = try builder.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "form", .prefix = "tei" } });
    const comment = try builder.addValue(.{ .text = .{ .bytes = "editorial" } });
    const pi_data = try builder.addValue(.{ .text = .{ .bytes = "preserve" } });
    try builder.appendChild(root, .{ .text = bank });
    try builder.appendChild(root, .{ .comment = comment });
    try builder.appendChild(root, .{ .node = child });
    try builder.appendChild(root, .{ .processing_instruction = .{ .target = "rend", .data = pi_data } });
    try builder.addDocumentRoot(root);
    return builder.build();
}
