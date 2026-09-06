const std = @import("std");

/// The semantic layer is an immutable, in-memory model. A Builder owns and
/// validates the input, then transfers ownership of its canonical arrays to
/// Model; semantic_format provides the checked deterministic wire encoding.
pub const Error = error{
    InvalidReference,
    InvalidNamespace,
    InvalidName,
    InvalidUtf8,
    InvalidUri,
    InvalidExternalId,
    InvalidDate,
    InvalidTemporalRange,
    InvalidStatementReference,
    DocumentDepthExceeded,
    InvalidCardinality,
    InvalidAssertion,
    InvalidDocument,
    DocumentCycle,
    DocumentMultipleParent,
    DuplicateRoot,
    DuplicateChild,
    OutOfMemory,
};

pub const ValueId = struct { index: u32 };
pub const EntityId = struct { index: u32 };
pub const AssertionId = struct { index: u32 };
pub const DocumentNodeId = struct { index: u32 };
pub const NamespaceId = struct { index: u32 };
pub const SourceId = struct { index: u32 };

pub const EntityKind = enum {
    lexicon,
    lexeme,
    entry,
    scope,
    sense,
    form,
    pronunciation,
    example,
    citation,
    translation_assertion,
    etymology_event,
    usage,
    feature_bundle,
    source,
    agent,
    media,
    document_node,
    annotation,
    other,
};

pub const AssertionState = enum { asserted, inferred, retracted, disputed };
pub const Certainty = enum { unknown, possible, probable, certain };
pub const ResolutionStatus = enum { unresolved, ambiguous, resolved_external, rejected };
pub const TemporalPrecision = enum { exact, day, month, year, approximate, unknown };

pub const Namespace = struct {
    uri: []const u8,
    prefix: []const u8,
};

/// A source identity is deliberately separate from every external identifier
/// stored on a lexical entity.  Two source records may carry the same
/// external_id and remain distinct SourceIds, which keeps joins source-scoped
/// and preserves occurrence identity.
pub const Source = struct {
    external_id: ?[]const u8 = null,
    base_uri: ?[]const u8 = null,
};

pub const SourceSpanUnit = enum {
    byte,
    utf8_codepoint,
    utf16_code_unit,
    grapheme,
};

pub const SourceSpan = struct {
    unit: SourceSpanUnit,
    start: u64,
    end: u64,
};

/// A typed source location.  `source` is carried on the anchor itself rather
/// than inferred from a document ancestor; `node` identifies the retained
/// source node and the optional span preserves a precise source range.
pub const SourceAnchor = struct {
    source: SourceId,
    node: DocumentNodeId,
    span: ?SourceSpan = null,
};

pub const EntityAnchor = struct {
    entity: EntityId,
    anchor: SourceAnchor,
};

pub const AssertionAnchor = struct {
    assertion: AssertionId,
    anchor: SourceAnchor,
};

/// A qualified name keeps the source prefix in addition to the namespace URI.
/// Prefixes are not semantic identity, but preserving them is useful for
/// semantic export and makes source locations maximally faithful.
pub const QualifiedName = struct {
    namespace: NamespaceId,
    local: []const u8,
    prefix: []const u8 = "",
};

pub const Text = struct {
    bytes: []const u8,
    language: ?[]const u8 = null,
    script: ?[]const u8 = null,
    notation: ?[]const u8 = null,
};

pub const Decimal = struct {
    coefficient: i64,
    scale: i32,
};

pub const Unknown = struct { reason: ?[]const u8 = null };
pub const Uncertain = struct {
    value: ValueId,
    certainty: Certainty,
};

pub const Value = union(enum) {
    text: Text,
    /// Opaque bytes are intentionally distinct from UTF-8 text.  They may
    /// contain arbitrary octets and are copied byte-for-byte by Builder.
    bytes: []const u8,
    boolean: bool,
    signed_integer: i64,
    unsigned_integer: u64,
    decimal: Decimal,
    uri: []const u8,
    qualified_name: QualifiedName,
    entity: EntityId,
    sequence: []const ValueId,
    unknown: Unknown,
    /// A present value whose source explicitly says that no value exists.
    /// This is distinct from an unknown value and from an omitted field.
    absent,
    uncertain: Uncertain,
};

pub const Attribute = struct {
    name: QualifiedName,
    value: ValueId,
};

pub const Entity = struct {
    kind: EntityKind,
    external_id: ?[]const u8 = null,
    label: ?ValueId = null,
    source: ?SourceId = null,
};

pub const UnresolvedTarget = struct {
    bytes: []const u8,
    uri: ?[]const u8 = null,
    label: ?[]const u8 = null,
    status: ResolutionStatus = .unresolved,
};

pub const Target = union(enum) {
    entity: EntityId,
    value: ValueId,
    /// A statement term is an identity-bearing reference to an earlier
    /// assertion.  References are deliberately backward-only: this keeps a
    /// builder's graph acyclic in the statement identity domain and makes
    /// malformed forward/dangling terms impossible to interpret ambiguously.
    statement: AssertionId,
    unresolved: UnresolvedTarget,
};

/// A graph/source context is separate from assertion attributes because it is
/// part of assertion identity and query semantics.  Anonymous contexts carry
/// a stable source-local number; the optional source scope may be an entity or
/// a source document node.  `.default` is distinct from every named or
/// anonymous context, including an anonymous context with id zero.
pub const ContextSource = union(enum) {
    entity: EntityId,
    document: DocumentNodeId,
};

pub const GraphContext = union(enum) {
    default,
    named: EntityId,
    anonymous: struct {
        source: ?ContextSource = null,
        id: u64,
    },
};

pub const Participant = struct {
    role: []const u8,
    target: Target,
};

pub const Date = struct {
    year: i32,
    month: ?u8 = null,
    day: ?u8 = null,
};

pub const Temporal = struct {
    start: ?Date = null,
    end: ?Date = null,
    precision: ?TemporalPrecision = null,
};

pub const Evidence = struct {
    source: ?EntityId = null,
    document: ?DocumentNodeId = null,
    quote: ?ValueId = null,
    provenance: ?ValueId = null,
    attributes: []const Attribute = &.{},
};

pub const Assertion = struct {
    predicate: EntityId,
    participants: []const Participant,
    attributes: []const Attribute,
    evidence: []const Evidence,
    state: AssertionState,
    certainty: Certainty,
    temporal: ?Temporal = null,
    context: GraphContext = .default,
    source: ?SourceId = null,
};

pub const ProcessingInstruction = struct {
    target: []const u8,
    data: ValueId,
};

/// A child item is ordered with text, comments, processing instructions and
/// element nodes in one sequence.  This is the part that preserves mixed TEI
/// content without making a second DOM-shaped copy of it.
pub const DocumentChild = union(enum) {
    node: DocumentNodeId,
    text: ValueId,
    comment: ValueId,
    processing_instruction: ProcessingInstruction,
};

pub const DocumentNode = struct {
    name: QualifiedName,
    source: ?SourceId,
    parent: ?DocumentNodeId,
    children: []const DocumentChild,
    attributes: []const Attribute,
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    namespaces: std.ArrayList(Namespace) = .empty,
    sources: std.ArrayList(Source) = .empty,
    values: std.ArrayList(Value) = .empty,
    entities: std.ArrayList(Entity) = .empty,
    assertions: std.ArrayList(Assertion) = .empty,
    documents: std.ArrayList(DocumentNodeOwned) = .empty,
    roots: std.ArrayList(DocumentNodeId) = .empty,
    entity_anchors: std.ArrayList(EntityAnchor) = .empty,
    assertion_anchors: std.ArrayList(AssertionAnchor) = .empty,
    /// Maximum inclusive document nesting depth accepted by cycle checks and
    /// final validation.  Traversal is iterative, so this is also an explicit
    /// decompression/stack budget rather than a native call-stack assumption.
    document_depth_budget: usize = 4096,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn setDocumentDepthBudget(self: *Builder, budget: usize) void {
        self.document_depth_budget = budget;
    }

    pub fn deinit(self: *Builder) void {
        freeNamespaces(self.allocator, self.namespaces.items);
        freeSources(self.allocator, self.sources.items);
        freeValues(self.allocator, self.values.items);
        freeEntities(self.allocator, self.entities.items);
        freeAssertions(self.allocator, self.assertions.items);
        freeDocuments(self.allocator, self.documents.items);
        self.namespaces.deinit(self.allocator);
        self.sources.deinit(self.allocator);
        self.values.deinit(self.allocator);
        self.entities.deinit(self.allocator);
        self.assertions.deinit(self.allocator);
        self.documents.deinit(self.allocator);
        self.roots.deinit(self.allocator);
        self.entity_anchors.deinit(self.allocator);
        self.assertion_anchors.deinit(self.allocator);
        self.* = undefined;
    }

    /// Namespaces are interned by exact URI/prefix.  They are metadata, not
    /// lexical occurrences, so this does not merge any entities or assertions.
    pub fn addNamespace(self: *Builder, uri: []const u8, prefix: []const u8) !NamespaceId {
        if (!std.unicode.utf8ValidateSlice(uri) or !std.unicode.utf8ValidateSlice(prefix)) return Error.InvalidUtf8;
        for (self.namespaces.items, 0..) |old, i| {
            if (std.mem.eql(u8, old.uri, uri) and std.mem.eql(u8, old.prefix, prefix)) return .{ .index = @intCast(i) };
        }
        const owned_uri = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(owned_uri);
        const owned_prefix = try self.allocator.dupe(u8, prefix);
        errdefer self.allocator.free(owned_prefix);
        try self.namespaces.append(self.allocator, .{ .uri = owned_uri, .prefix = owned_prefix });
        return .{ .index = @intCast(self.namespaces.items.len - 1) };
    }

    /// Sources are occurrence identities, so this method never interns or
    /// deduplicates records even when their external IDs are equal.
    pub fn addSource(self: *Builder, input: Source) !SourceId {
        if (input.external_id) |id| {
            if (id.len == 0 or !std.unicode.utf8ValidateSlice(id)) return Error.InvalidExternalId;
        }
        if (input.base_uri) |uri| try validateUri(uri);
        const external_id = try dupeOptional(self.allocator, input.external_id);
        errdefer if (external_id) |id| self.allocator.free(id);
        const base_uri = try dupeOptional(self.allocator, input.base_uri);
        errdefer if (base_uri) |uri| self.allocator.free(uri);
        try self.sources.append(self.allocator, .{ .external_id = external_id, .base_uri = base_uri });
        return .{ .index = @intCast(self.sources.items.len - 1) };
    }

    /// Adds an exact typed value.  Only values whose complete tag and payload
    /// match are interned; equal text does not merge entities or occurrences.
    pub fn addValue(self: *Builder, input: Value) !ValueId {
        try self.validateValueInput(input);
        for (self.values.items, 0..) |old, i| {
            if (valueEqual(old, input)) return .{ .index = @intCast(i) };
        }
        const owned = try self.copyValue(input);
        errdefer freeValue(self.allocator, owned);
        try self.values.append(self.allocator, owned);
        return .{ .index = @intCast(self.values.items.len - 1) };
    }

    /// Appends a value without interning it.  This is intentionally separate
    /// from addValue: snapshot decoders must preserve every encoded index and
    /// are therefore not allowed to collapse equal values during import.
    pub fn addValueExact(self: *Builder, input: Value) !ValueId {
        try self.validateValueInput(input);
        const owned = try self.copyValue(input);
        errdefer freeValue(self.allocator, owned);
        try self.values.append(self.allocator, owned);
        return .{ .index = @intCast(self.values.items.len - 1) };
    }

    pub fn internValue(self: *Builder, input: Value) !ValueId {
        return self.addValue(input);
    }

    pub fn addEntity(self: *Builder, input: Entity) !EntityId {
        if (input.external_id) |external_id| {
            if (external_id.len == 0 or !std.unicode.utf8ValidateSlice(external_id)) return Error.InvalidExternalId;
        }
        if (input.label) |label| try self.requireValue(label);
        if (input.source) |source| try self.requireSource(source);
        const external_id = try dupeOptional(self.allocator, input.external_id);
        var external_id_transferred = false;
        errdefer if (!external_id_transferred) if (external_id) |id| self.allocator.free(id);
        try self.entities.append(self.allocator, .{
            .kind = input.kind,
            .external_id = external_id,
            .label = input.label,
            .source = input.source,
        });
        external_id_transferred = true;
        return .{ .index = @intCast(self.entities.items.len - 1) };
    }

    pub fn addAssertion(self: *Builder, input: Assertion) !AssertionId {
        try self.requireEntity(input.predicate);
        if (input.source) |source| try self.requireSource(source);
        if (input.participants.len < 2) return Error.InvalidCardinality;
        const participants = try self.copyParticipants(input.participants, self.assertions.items.len);
        errdefer freeParticipants(self.allocator, participants);
        const attributes = try self.copyAttributes(input.attributes);
        errdefer freeAttributes(self.allocator, attributes);
        const evidence = try self.copyEvidence(input.evidence);
        errdefer freeEvidence(self.allocator, evidence);
        if (input.temporal) |temporal| try validateTemporal(temporal);
        try self.validateContext(input.context);
        try self.assertions.append(self.allocator, .{
            .predicate = input.predicate,
            .participants = participants,
            .attributes = attributes,
            .evidence = evidence,
            .state = input.state,
            .certainty = input.certainty,
            .temporal = input.temporal,
            .context = input.context,
            .source = input.source,
        });
        return .{ .index = @intCast(self.assertions.items.len - 1) };
    }

    pub fn addDocumentNode(self: *Builder, input: DocumentNodeInput) !DocumentNodeId {
        try self.validateQualifiedName(input.name);
        if (input.parent) |parent| try self.requireDocument(parent);
        if (input.source) |source| try self.requireSource(source);
        if (input.parent) |parent| if (input.source != null and self.documents.items[parent.index].source != null and input.source.?.index != self.documents.items[parent.index].source.?.index) return Error.InvalidDocument;
        const attributes = try self.copyAttributes(input.attributes);
        var attributes_transferred = false;
        errdefer if (!attributes_transferred) freeAttributes(self.allocator, attributes);
        const name = try self.copyQualifiedName(input.name);
        var name_transferred = false;
        errdefer if (!name_transferred) freeQualifiedName(self.allocator, name);
        try self.documents.append(self.allocator, .{
            .name = name,
            .source = input.source,
            .parent = null,
            .children = .empty,
            .attributes = attributes,
        });
        // Once the node is appended, its attributes belong to the builder.
        attributes_transferred = true;
        name_transferred = true;
        const id = DocumentNodeId{ .index = @intCast(self.documents.items.len - 1) };
        if (input.parent) |parent| {
            self.appendChild(parent, .{ .node = id }) catch |err| {
                const removed = self.documents.pop().?;
                freeDocumentNode(self.allocator, removed);
                return err;
            };
        }
        return id;
    }

    pub fn appendChild(self: *Builder, parent: DocumentNodeId, child: DocumentChild) !void {
        const parent_node = try self.documentPtr(parent);
        switch (child) {
            .node => |child_id| {
                if (!validDocumentId(self.documents.items, child_id)) return Error.InvalidReference;
                if (child_id.index == parent.index) return Error.DocumentCycle;
                const child_node = &self.documents.items[child_id.index];
                if (child_node.parent) |old_parent| {
                    if (old_parent.index != parent.index) return Error.DocumentMultipleParent;
                    return Error.DuplicateChild;
                }
                if (try self.reaches(child_id, parent)) return Error.DocumentCycle;
            },
            .text => |value| try self.requireValue(value),
            .comment => |value| try self.requireValue(value),
            .processing_instruction => |pi| {
                if (pi.target.len == 0 or !std.unicode.utf8ValidateSlice(pi.target)) return Error.InvalidName;
                try self.requireValue(pi.data);
            },
        }
        const owned = try self.copyChild(child);
        try parent_node.children.append(self.allocator, owned);
        if (child == .node) self.documents.items[child.node.index].parent = parent;
    }

    pub fn addDocumentRoot(self: *Builder, id: DocumentNodeId) !void {
        const node = try self.documentPtr(id);
        if (node.parent != null) return Error.InvalidDocument;
        for (self.roots.items) |old| if (old.index == id.index) return Error.DuplicateRoot;
        try self.roots.append(self.allocator, id);
    }

    pub fn addEntityAnchor(self: *Builder, entity: EntityId, anchor: SourceAnchor) !void {
        try self.requireEntity(entity);
        try self.validateAnchor(anchor);
        try self.entity_anchors.append(self.allocator, .{ .entity = entity, .anchor = anchor });
    }

    pub fn addAssertionAnchor(self: *Builder, assertion: AssertionId, anchor: SourceAnchor) !void {
        if (assertion.index >= self.assertions.items.len) return Error.InvalidReference;
        try self.validateAnchor(anchor);
        try self.assertion_anchors.append(self.allocator, .{ .assertion = assertion, .anchor = anchor });
    }

    /// Checks the entire graph and transfers all owned storage into Model.
    /// Model.deinit must be called exactly once by its owner.
    pub fn build(self: *Builder) !Model {
        try self.validateAll();
        const namespaces = try self.namespaces.toOwnedSlice(self.allocator);
        errdefer {
            freeNamespaces(self.allocator, namespaces);
            self.allocator.free(namespaces);
        }
        const sources = try self.sources.toOwnedSlice(self.allocator);
        errdefer {
            freeSources(self.allocator, sources);
            self.allocator.free(sources);
        }
        const values = try self.values.toOwnedSlice(self.allocator);
        errdefer {
            freeValues(self.allocator, values);
            self.allocator.free(values);
        }
        const entities = try self.entities.toOwnedSlice(self.allocator);
        errdefer {
            freeEntities(self.allocator, entities);
            self.allocator.free(entities);
        }
        const assertions = try self.assertions.toOwnedSlice(self.allocator);
        errdefer {
            freeAssertions(self.allocator, assertions);
            self.allocator.free(assertions);
        }
        const documents = try self.documents.toOwnedSlice(self.allocator);
        errdefer {
            freeDocuments(self.allocator, documents);
            self.allocator.free(documents);
        }
        const roots = try self.roots.toOwnedSlice(self.allocator);
        const entity_anchors = try self.entity_anchors.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(entity_anchors);
        const assertion_anchors = try self.assertion_anchors.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(assertion_anchors);
        self.namespaces = .empty;
        self.sources = .empty;
        self.values = .empty;
        self.entities = .empty;
        self.assertions = .empty;
        self.documents = .empty;
        self.roots = .empty;
        self.entity_anchors = .empty;
        self.assertion_anchors = .empty;
        return .{
            .allocator = self.allocator,
            .namespaces = namespaces,
            .sources = sources,
            .values = values,
            .entities = entities,
            .assertions = assertions,
            .documents = documents,
            .roots = roots,
            .entity_anchors = entity_anchors,
            .assertion_anchors = assertion_anchors,
        };
    }

    fn validateValueInput(self: *const Builder, input: Value) !void {
        switch (input) {
            .text => |text| {
                if (!std.unicode.utf8ValidateSlice(text.bytes)) return Error.InvalidUtf8;
                if (text.language) |language| if (!std.unicode.utf8ValidateSlice(language)) return Error.InvalidUtf8;
                if (text.script) |script| if (!std.unicode.utf8ValidateSlice(script)) return Error.InvalidUtf8;
                if (text.notation) |notation| if (!std.unicode.utf8ValidateSlice(notation)) return Error.InvalidUtf8;
            },
            .uri => |uri| try validateUri(uri),
            .qualified_name => |name| try self.validateQualifiedName(name),
            .entity => |id| try self.requireEntity(id),
            .sequence => |ids| for (ids) |id| try self.requireValue(id),
            .unknown => |unknown| if (unknown.reason) |reason| if (!std.unicode.utf8ValidateSlice(reason)) return Error.InvalidUtf8,
            .uncertain => |u| try self.requireValue(u.value),
            else => {},
        }
    }

    fn copyValue(self: *Builder, input: Value) !Value {
        return switch (input) {
            .text => |text| blk: {
                const bytes = try self.allocator.dupe(u8, text.bytes);
                errdefer self.allocator.free(bytes);
                const language = try dupeOptional(self.allocator, text.language);
                errdefer if (language) |value| self.allocator.free(value);
                const script = try dupeOptional(self.allocator, text.script);
                errdefer if (script) |value| self.allocator.free(value);
                const notation = try dupeOptional(self.allocator, text.notation);
                break :blk .{ .text = .{ .bytes = bytes, .language = language, .script = script, .notation = notation } };
            },
            .bytes => |bytes| .{ .bytes = try self.allocator.dupe(u8, bytes) },
            .uri => |uri| .{ .uri = try self.allocator.dupe(u8, uri) },
            .qualified_name => |name| .{ .qualified_name = try self.copyQualifiedName(name) },
            .sequence => |ids| .{ .sequence = try self.allocator.dupe(ValueId, ids) },
            .unknown => |unknown| .{ .unknown = .{ .reason = try dupeOptional(self.allocator, unknown.reason) } },
            else => input,
        };
    }

    fn copyQualifiedName(self: *Builder, name: QualifiedName) !QualifiedName {
        const local = try self.allocator.dupe(u8, name.local);
        errdefer self.allocator.free(local);
        const prefix = try self.allocator.dupe(u8, name.prefix);
        return .{
            .namespace = name.namespace,
            .local = local,
            .prefix = prefix,
        };
    }

    fn copyParticipants(self: *Builder, input: []const Participant, assertion_limit: usize) ![]Participant {
        const out = try self.allocator.alloc(Participant, input.len);
        var copied: usize = 0;
        errdefer {
            freeParticipantItems(self.allocator, out[0..copied]);
            self.allocator.free(out);
        }
        for (input, 0..) |participant, i| {
            if (participant.role.len == 0 or !std.unicode.utf8ValidateSlice(participant.role)) return Error.InvalidName;
            try self.validateTarget(participant.target, assertion_limit);
            const role = try self.allocator.dupe(u8, participant.role);
            const target = self.copyTarget(participant.target) catch |err| {
                self.allocator.free(role);
                return err;
            };
            out[i] = .{ .role = role, .target = target };
            copied += 1;
        }
        return out;
    }

    fn copyTarget(self: *Builder, target: Target) !Target {
        return switch (target) {
            .unresolved => |u| blk: {
                const bytes = try self.allocator.dupe(u8, u.bytes);
                errdefer self.allocator.free(bytes);
                const uri = try dupeOptional(self.allocator, u.uri);
                errdefer if (uri) |value| self.allocator.free(value);
                const label = try dupeOptional(self.allocator, u.label);
                break :blk .{ .unresolved = .{ .bytes = bytes, .uri = uri, .label = label, .status = u.status } };
            },
            else => target,
        };
    }

    fn copyAttributes(self: *Builder, input: []const Attribute) ![]Attribute {
        const out = try self.allocator.alloc(Attribute, input.len);
        var copied: usize = 0;
        errdefer {
            freeAttributeItems(self.allocator, out[0..copied]);
            self.allocator.free(out);
        }
        for (input, 0..) |attribute, i| {
            try self.requireValue(attribute.value);
            out[i] = .{ .name = try self.copyQualifiedName(attribute.name), .value = attribute.value };
            copied += 1;
        }
        return out;
    }

    fn copyEvidence(self: *Builder, input: []const Evidence) ![]Evidence {
        const out = try self.allocator.alloc(Evidence, input.len);
        var copied: usize = 0;
        errdefer {
            freeEvidenceItems(self.allocator, out[0..copied]);
            self.allocator.free(out);
        }
        for (input, 0..) |evidence, i| {
            if (evidence.source) |id| try self.requireEntity(id);
            if (evidence.document) |id| try self.requireDocument(id);
            if (evidence.quote) |id| try self.requireValue(id);
            if (evidence.provenance) |id| try self.requireValue(id);
            const attributes = try self.copyAttributes(evidence.attributes);
            out[i] = .{
                .source = evidence.source,
                .document = evidence.document,
                .quote = evidence.quote,
                .provenance = evidence.provenance,
                .attributes = attributes,
            };
            copied += 1;
        }
        return out;
    }

    fn copyChild(self: *Builder, child: DocumentChild) !DocumentChild {
        return switch (child) {
            .processing_instruction => |pi| .{ .processing_instruction = .{
                .target = try self.allocator.dupe(u8, pi.target),
                .data = pi.data,
            } },
            else => child,
        };
    }

    fn validateTarget(self: *const Builder, target: Target, assertion_limit: usize) !void {
        switch (target) {
            .entity => |id| try self.requireEntity(id),
            .value => |id| try self.requireValue(id),
            .statement => |id| if (id.index >= assertion_limit) return Error.InvalidStatementReference,
            .unresolved => |u| {
                if (u.bytes.len == 0 and u.uri == null and u.label == null) return Error.InvalidAssertion;
                if (!std.unicode.utf8ValidateSlice(u.bytes)) return Error.InvalidUtf8;
                if (u.uri) |uri| try validateUri(uri);
                if (u.label) |label| if (!std.unicode.utf8ValidateSlice(label)) return Error.InvalidUtf8;
            },
        }
    }

    fn validateContext(self: *const Builder, context: GraphContext) !void {
        switch (context) {
            .default => {},
            .named => |id| try self.requireEntity(id),
            .anonymous => |anonymous| if (anonymous.source) |source| switch (source) {
                .entity => |id| try self.requireEntity(id),
                .document => |id| try self.requireDocument(id),
            },
        }
    }

    fn validateAnchor(self: *const Builder, anchor: SourceAnchor) !void {
        try self.requireSource(anchor.source);
        try self.requireDocument(anchor.node);
        if (self.documents.items[anchor.node.index].source) |node_source| {
            if (node_source.index != anchor.source.index) return Error.InvalidDocument;
        }
        if (anchor.span) |span| if (span.start > span.end) return Error.InvalidDocument;
    }

    fn validateQualifiedName(self: *const Builder, name: QualifiedName) !void {
        if (!validNamespaceId(self.namespaces.items, name.namespace)) return Error.InvalidNamespace;
        if (name.local.len == 0 or !std.unicode.utf8ValidateSlice(name.local) or !std.unicode.utf8ValidateSlice(name.prefix)) return Error.InvalidName;
    }

    fn validateAll(self: *const Builder) !void {
        for (self.sources.items) |source| {
            if (source.external_id) |id| {
                if (id.len == 0 or !std.unicode.utf8ValidateSlice(id)) return Error.InvalidExternalId;
            }
            if (source.base_uri) |uri| try validateUri(uri);
        }
        for (self.values.items) |value| try self.validateValueInput(value);
        for (self.entities.items) |entity| {
            if (entity.label) |id| try self.requireValue(id);
            if (entity.source) |source| try self.requireSource(source);
        }
        for (self.assertions.items, 0..) |assertion, assertion_index| {
            try self.requireEntity(assertion.predicate);
            if (assertion.participants.len < 2) return Error.InvalidCardinality;
            for (assertion.participants) |participant| try self.validateTarget(participant.target, assertion_index);
            for (assertion.attributes) |attribute| {
                try self.validateQualifiedName(attribute.name);
                try self.requireValue(attribute.value);
            }
            for (assertion.evidence) |evidence| {
                if (evidence.source) |id| try self.requireEntity(id);
                if (evidence.document) |id| try self.requireDocument(id);
                if (evidence.quote) |id| try self.requireValue(id);
                if (evidence.provenance) |id| try self.requireValue(id);
            }
            if (assertion.temporal) |temporal| try validateTemporal(temporal);
            try self.validateContext(assertion.context);
            if (assertion.source) |source| try self.requireSource(source);
        }
        try self.validateDocuments();
        for (self.entity_anchors.items) |mapping| {
            try self.requireEntity(mapping.entity);
            try self.validateAnchor(mapping.anchor);
        }
        for (self.assertion_anchors.items) |mapping| {
            if (mapping.assertion.index >= self.assertions.items.len) return Error.InvalidReference;
            try self.validateAnchor(mapping.anchor);
        }
    }

    fn validateDocuments(self: *const Builder) !void {
        var seen_roots = try self.allocator.alloc(bool, self.documents.items.len);
        defer self.allocator.free(seen_roots);
        @memset(seen_roots, false);
        for (self.roots.items) |root| {
            try self.requireDocument(root);
            if (seen_roots[root.index]) return Error.DuplicateRoot;
            seen_roots[root.index] = true;
            if (self.documents.items[root.index].parent != null) return Error.InvalidDocument;
        }
        for (self.documents.items, 0..) |document, i| {
            try self.validateQualifiedName(document.name);
            if (document.source) |source| try self.requireSource(source);
            for (document.attributes) |attribute| {
                try self.validateQualifiedName(attribute.name);
                try self.requireValue(attribute.value);
            }
            if (document.parent) |parent| {
                try self.requireDocument(parent);
                if (seen_roots[i]) return Error.InvalidDocument;
                if (!hasNodeChild(documentId(i), self.documents.items[parent.index].children.items)) return Error.InvalidDocument;
            } else if (!seen_roots[i]) return Error.InvalidDocument;
            for (document.children.items) |child| switch (child) {
                .node => |id| {
                    try self.requireDocument(id);
                    if (id.index == i or self.documents.items[id.index].parent == null or self.documents.items[id.index].parent.?.index != i) return Error.InvalidDocument;
                },
                .text, .comment => |id| try self.requireValue(id),
                .processing_instruction => |pi| {
                    if (pi.target.len == 0 or !std.unicode.utf8ValidateSlice(pi.target)) return Error.InvalidName;
                    try self.requireValue(pi.data);
                },
            };
        }
        const colors = try self.allocator.alloc(u8, self.documents.items.len);
        defer self.allocator.free(colors);
        @memset(colors, 0);
        try self.visitDocumentsIterative(colors);
        for (colors) |color| if (color == 0) return Error.InvalidDocument;
    }

    fn visitDocumentsIterative(self: *const Builder, colors: []u8) !void {
        const Frame = struct { id: DocumentNodeId, next_child: usize };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(self.allocator);

        for (self.roots.items) |root| {
            if (colors[root.index] == 2) continue;
            if (colors[root.index] == 1) return Error.DocumentCycle;
            colors[root.index] = 1;
            try stack.append(self.allocator, .{ .id = root, .next_child = 0 });
            while (stack.items.len != 0) {
                const frame_index = stack.items.len - 1;
                if (stack.items[frame_index].next_child >= self.documents.items[stack.items[frame_index].id.index].children.items.len) {
                    colors[stack.items[frame_index].id.index] = 2;
                    _ = stack.pop();
                    continue;
                }
                const child_index = stack.items[frame_index].next_child;
                stack.items[frame_index].next_child += 1;
                const child = self.documents.items[stack.items[frame_index].id.index].children.items[child_index];
                if (child != .node) continue;
                const child_id = child.node;
                if (stack.items.len > self.document_depth_budget) return Error.DocumentDepthExceeded;
                if (colors[child_id.index] == 1) return Error.DocumentCycle;
                if (colors[child_id.index] == 2) continue;
                colors[child_id.index] = 1;
                try stack.append(self.allocator, .{ .id = child_id, .next_child = 0 });
            }
        }
    }

    fn reaches(self: *const Builder, from: DocumentNodeId, target: DocumentNodeId) !bool {
        if (from.index >= self.documents.items.len) return false;
        const Work = struct { id: DocumentNodeId, depth: usize };
        var stack: std.ArrayList(Work) = .empty;
        defer stack.deinit(self.allocator);
        var seen = try self.allocator.alloc(bool, self.documents.items.len);
        defer self.allocator.free(seen);
        @memset(seen, false);
        try stack.append(self.allocator, .{ .id = from, .depth = 0 });
        while (stack.items.len != 0) {
            const work = stack.pop().?;
            if (work.depth > self.document_depth_budget) return Error.DocumentDepthExceeded;
            if (work.id.index == target.index) return true;
            if (seen[work.id.index]) continue;
            seen[work.id.index] = true;
            for (self.documents.items[work.id.index].children.items) |child| {
                if (child != .node) continue;
                if (child.node.index >= self.documents.items.len) continue;
                try stack.append(self.allocator, .{ .id = child.node, .depth = work.depth + 1 });
            }
        }
        return false;
    }

    fn documentPtr(self: *Builder, id: DocumentNodeId) !*DocumentNodeOwned {
        if (!validDocumentId(self.documents.items, id)) return Error.InvalidReference;
        return &self.documents.items[id.index];
    }
    fn requireDocument(self: *const Builder, id: DocumentNodeId) !void {
        if (!validDocumentId(self.documents.items, id)) return Error.InvalidReference;
    }
    fn requireEntity(self: *const Builder, id: EntityId) !void {
        if (!validEntityId(self.entities.items, id)) return Error.InvalidReference;
    }
    fn requireValue(self: *const Builder, id: ValueId) !void {
        if (!validValueId(self.values.items, id)) return Error.InvalidReference;
    }
    fn requireSource(self: *const Builder, id: SourceId) !void {
        if (!validSourceId(self.sources.items, id)) return Error.InvalidReference;
    }
};

pub const DocumentNodeInput = struct {
    name: QualifiedName,
    source: ?SourceId = null,
    parent: ?DocumentNodeId = null,
    attributes: []const Attribute = &.{},
};

pub const DocumentNodeOwned = struct {
    name: QualifiedName,
    source: ?SourceId,
    parent: ?DocumentNodeId,
    children: std.ArrayList(DocumentChild),
    attributes: []const Attribute,
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    namespaces: []const Namespace,
    sources: []const Source,
    values: []const Value,
    entities: []const Entity,
    assertions: []const Assertion,
    documents: []const DocumentNodeOwned,
    roots: []const DocumentNodeId,
    entity_anchors: []const EntityAnchor,
    assertion_anchors: []const AssertionAnchor,

    pub fn deinit(self: *Model) void {
        freeNamespaces(self.allocator, self.namespaces);
        freeSources(self.allocator, self.sources);
        freeValues(self.allocator, self.values);
        freeEntities(self.allocator, self.entities);
        freeAssertions(self.allocator, self.assertions);
        freeDocuments(self.allocator, self.documents);
        self.allocator.free(self.namespaces);
        self.allocator.free(self.sources);
        self.allocator.free(self.values);
        self.allocator.free(self.entities);
        self.allocator.free(self.assertions);
        self.allocator.free(self.documents);
        self.allocator.free(self.roots);
        self.allocator.free(self.entity_anchors);
        self.allocator.free(self.assertion_anchors);
        self.* = undefined;
    }

    pub fn value(self: *const Model, id: ValueId) !Value {
        if (!validValueId(self.values, id)) return Error.InvalidReference;
        return self.values[id.index];
    }
    pub fn entity(self: *const Model, id: EntityId) !Entity {
        if (!validEntityId(self.entities, id)) return Error.InvalidReference;
        return self.entities[id.index];
    }
    pub fn assertion(self: *const Model, id: AssertionId) !Assertion {
        if (id.index >= self.assertions.len) return Error.InvalidReference;
        return self.assertions[id.index];
    }
    pub fn document(self: *const Model, id: DocumentNodeId) !DocumentNode {
        if (id.index >= self.documents.len) return Error.InvalidReference;
        const source = self.documents[id.index];
        return .{ .name = source.name, .source = source.source, .parent = source.parent, .children = source.children.items, .attributes = source.attributes };
    }
};

fn validValueId(values: anytype, id: ValueId) bool {
    return id.index < values.len;
}
fn validEntityId(entities: anytype, id: EntityId) bool {
    return id.index < entities.len;
}
fn validDocumentId(documents: anytype, id: DocumentNodeId) bool {
    return id.index < documents.len;
}
fn validNamespaceId(namespaces: anytype, id: NamespaceId) bool {
    return id.index < namespaces.len;
}
fn validSourceId(sources: anytype, id: SourceId) bool {
    return id.index < sources.len;
}
fn documentId(index: usize) DocumentNodeId {
    return .{ .index = @intCast(index) };
}

fn hasNodeChild(id: DocumentNodeId, children: []const DocumentChild) bool {
    for (children) |child| if (child == .node and child.node.index == id.index) return true;
    return false;
}

fn valueEqual(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .text => |x| textEqual(x, b.text),
        .bytes => |x| std.mem.eql(u8, x, b.bytes),
        .boolean => |x| x == b.boolean,
        .signed_integer => |x| x == b.signed_integer,
        .unsigned_integer => |x| x == b.unsigned_integer,
        .decimal => |x| x.coefficient == b.decimal.coefficient and x.scale == b.decimal.scale,
        .uri => |x| std.mem.eql(u8, x, b.uri),
        .qualified_name => |x| qualifiedNameEqual(x, b.qualified_name),
        .entity => |x| x.index == b.entity.index,
        .sequence => |x| idsEqual(x, b.sequence),
        .unknown => |x| optionalBytesEqual(x.reason, b.unknown.reason),
        .absent => true,
        .uncertain => |x| x.value.index == b.uncertain.value.index and x.certainty == b.uncertain.certainty,
    };
}

fn textEqual(a: Text, b: Text) bool {
    return std.mem.eql(u8, a.bytes, b.bytes) and optionalBytesEqual(a.language, b.language) and optionalBytesEqual(a.script, b.script) and optionalBytesEqual(a.notation, b.notation);
}
fn qualifiedNameEqual(a: QualifiedName, b: QualifiedName) bool {
    return a.namespace.index == b.namespace.index and std.mem.eql(u8, a.local, b.local) and std.mem.eql(u8, a.prefix, b.prefix);
}
fn idsEqual(a: []const ValueId, b: []const ValueId) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (left.index != right.index) return false;
    return true;
}
fn optionalBytesEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn validateTemporal(temporal: Temporal) !void {
    if (temporal.start) |date| try validateDate(date);
    if (temporal.end) |date| try validateDate(date);
    if (temporal.start != null and temporal.end != null and compareDate(temporal.start.?, temporal.end.?) == .gt) return Error.InvalidTemporalRange;
    if (temporal.precision) |precision| {
        if (temporal.start == null and temporal.end == null) return Error.InvalidDate;
        for ([_]?Date{ temporal.start, temporal.end }) |maybe_date| {
            if (maybe_date) |date| switch (precision) {
                .exact, .day => if (date.month == null or date.day == null) return Error.InvalidDate,
                .month => if (date.month == null or date.day != null) return Error.InvalidDate,
                .year => if (date.month != null or date.day != null) return Error.InvalidDate,
                .approximate, .unknown => {},
            };
        }
    }
}
fn validateDate(date: Date) !void {
    if (date.month) |month| if (month == 0 or month > 12) return Error.InvalidDate;
    if (date.day) |day| {
        const month = date.month orelse return Error.InvalidDate;
        if (day == 0 or day > daysInMonth(date.year, month)) return Error.InvalidDate;
    }
}

fn isLeapYear(year: i32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        2 => if (isLeapYear(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}
fn compareDate(a: Date, b: Date) std.math.Order {
    if (a.year != b.year) return if (a.year < b.year) .lt else .gt;
    const am = a.month orelse 0;
    const bm = b.month orelse 0;
    if (am != bm) return if (am < bm) .lt else .gt;
    const ad = a.day orelse 0;
    const bd = b.day orelse 0;
    if (ad != bd) return if (ad < bd) .lt else .gt;
    return .eq;
}

fn dupeOptional(allocator: std.mem.Allocator, bytes: ?[]const u8) !?[]const u8 {
    return if (bytes) |slice| try allocator.dupe(u8, slice) else null;
}

/// A deliberately small URI validator.  It accepts absolute and relative
/// references, rejects empty/control/whitespace input, validates percent
/// escapes, and checks the RFC 3986 scheme shape when a scheme is present.
/// Full IRI policy belongs to an import profile; this prevents accidental
/// acceptance of clearly malformed identifiers without rewriting source text.
fn validateUri(uri: []const u8) !void {
    if (uri.len == 0 or !std.unicode.utf8ValidateSlice(uri)) return Error.InvalidUri;
    for (uri, 0..) |byte, index| {
        if (byte < 0x20 or byte == 0x7f or byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r') return Error.InvalidUri;
        if (byte == '%') {
            if (index + 2 >= uri.len or hexValue(uri[index + 1]) == null or hexValue(uri[index + 2]) == null) return Error.InvalidUri;
        }
    }
    if (std.mem.indexOfScalar(u8, uri, ':')) |colon| {
        if (colon == 0 or !isAsciiAlpha(uri[0])) return Error.InvalidUri;
        for (uri[1..colon]) |byte| {
            if (!isAsciiAlpha(byte) and !std.ascii.isDigit(byte) and byte != '+' and byte != '-' and byte != '.') return Error.InvalidUri;
        }
    }
}

fn isAsciiAlpha(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z');
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn freeNamespaces(allocator: std.mem.Allocator, values: []const Namespace) void {
    for (values) |value| {
        allocator.free(value.uri);
        allocator.free(value.prefix);
    }
}
fn freeSources(allocator: std.mem.Allocator, values: []const Source) void {
    for (values) |value| {
        if (value.external_id) |id| allocator.free(id);
        if (value.base_uri) |uri| allocator.free(uri);
    }
}
fn freeValue(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .text => |text| {
            allocator.free(text.bytes);
            if (text.language) |x| allocator.free(x);
            if (text.script) |x| allocator.free(x);
            if (text.notation) |x| allocator.free(x);
        },
        .bytes => |bytes| allocator.free(bytes),
        .uri => |uri| allocator.free(uri),
        .qualified_name => |name| {
            allocator.free(name.local);
            allocator.free(name.prefix);
        },
        .sequence => |sequence| allocator.free(sequence),
        .unknown => |unknown| if (unknown.reason) |reason| allocator.free(reason),
        else => {},
    }
}
fn freeValues(allocator: std.mem.Allocator, values: []const Value) void {
    for (values) |value| freeValue(allocator, value);
}
fn freeEntities(allocator: std.mem.Allocator, values: []const Entity) void {
    for (values) |value| if (value.external_id) |id| allocator.free(id);
}
fn freeQualifiedName(allocator: std.mem.Allocator, name: QualifiedName) void {
    allocator.free(name.local);
    allocator.free(name.prefix);
}
fn freeAttributeItems(allocator: std.mem.Allocator, values: []const Attribute) void {
    for (values) |value| freeQualifiedName(allocator, value.name);
}
fn freeAttributes(allocator: std.mem.Allocator, values: []const Attribute) void {
    freeAttributeItems(allocator, values);
    allocator.free(values);
}
fn freeParticipantItems(allocator: std.mem.Allocator, values: []const Participant) void {
    for (values) |value| {
        allocator.free(value.role);
        if (value.target == .unresolved) {
            const target = value.target.unresolved;
            allocator.free(target.bytes);
            if (target.uri) |x| allocator.free(x);
            if (target.label) |x| allocator.free(x);
        }
    }
}
fn freeParticipants(allocator: std.mem.Allocator, values: []const Participant) void {
    freeParticipantItems(allocator, values);
    allocator.free(values);
}
fn freeEvidenceItems(allocator: std.mem.Allocator, values: []const Evidence) void {
    for (values) |value| freeAttributes(allocator, value.attributes);
}
fn freeEvidence(allocator: std.mem.Allocator, values: []const Evidence) void {
    freeEvidenceItems(allocator, values);
    allocator.free(values);
}
fn freeAssertions(allocator: std.mem.Allocator, values: []const Assertion) void {
    for (values) |value| {
        freeParticipants(allocator, value.participants);
        freeAttributes(allocator, value.attributes);
        freeEvidence(allocator, value.evidence);
    }
}
fn freeChild(allocator: std.mem.Allocator, child: DocumentChild) void {
    if (child == .processing_instruction) allocator.free(child.processing_instruction.target);
}
fn freeDocumentNode(allocator: std.mem.Allocator, value: DocumentNodeOwned) void {
    freeQualifiedName(allocator, value.name);
    for (value.children.items) |child| freeChild(allocator, child);
    @constCast(&value.children).deinit(allocator);
    freeAttributes(allocator, value.attributes);
}
fn freeDocuments(allocator: std.mem.Allocator, values: []const DocumentNodeOwned) void {
    for (values) |value| freeDocumentNode(allocator, value);
}

test "value interning is exact and does not merge entities" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();
    const ns = try builder.addNamespace("urn:test", "t");
    const first = try builder.addValue(.{ .text = .{ .bytes = "bank", .language = "en" } });
    const same = try builder.addValue(.{ .text = .{ .bytes = "bank", .language = "en" } });
    const different = try builder.addValue(.{ .text = .{ .bytes = "bank", .language = "fr" } });
    try std.testing.expectEqual(first.index, same.index);
    try std.testing.expect(first.index != different.index);
    const a = try builder.addEntity(.{ .kind = .sense, .external_id = "a", .label = first });
    const b = try builder.addEntity(.{ .kind = .sense, .external_id = "b", .label = first });
    try std.testing.expect(a.index != b.index);
    _ = ns;
}

test "source identities and anchors preserve scope and reject invalid spans" {
    var b = Builder.init(std.testing.allocator);
    defer b.deinit();
    const ns = try b.addNamespace("urn:test", "t");
    const first = try b.addSource(.{ .external_id = "same.xml", .base_uri = "https://example.test/a" });
    const second = try b.addSource(.{ .external_id = "same.xml", .base_uri = "https://example.test/b" });
    try std.testing.expect(first.index != second.index);
    try std.testing.expectError(Error.InvalidUri, b.addSource(.{ .base_uri = "bad uri" }));
    const entity = try b.addEntity(.{ .kind = .entry, .external_id = "entry", .source = first });
    const root = try b.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "entry" }, .source = first });
    try b.addDocumentRoot(root);
    try std.testing.expectError(Error.InvalidDocument, b.addEntityAnchor(entity, .{ .source = first, .node = root, .span = .{ .unit = .byte, .start = 4, .end = 3 } }));
    try std.testing.expectError(Error.InvalidDocument, b.addEntityAnchor(entity, .{ .source = second, .node = root }));
    try b.addEntityAnchor(entity, .{ .source = first, .node = root, .span = .{ .unit = .utf8_codepoint, .start = 0, .end = 5 } });
    var model = try b.build();
    defer model.deinit();
    try std.testing.expectEqual(@as(usize, 2), model.sources.len);
    try std.testing.expectEqual(@as(usize, 1), model.entity_anchors.len);
}

test "relations preserve cycles, parallel assertions, evidence and unresolved target" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();
    const source = try builder.addEntity(.{ .kind = .source, .external_id = "s" });
    const predicate = try builder.addEntity(.{ .kind = .other, .external_id = "related" });
    const a = try builder.addEntity(.{ .kind = .sense, .external_id = "a" });
    const b = try builder.addEntity(.{ .kind = .sense, .external_id = "b" });
    const quote = try builder.addValue(.{ .text = .{ .bytes = "banque", .language = "fr" } });
    const first = try builder.addAssertion(.{
        .predicate = predicate,
        .participants = &.{ .{ .role = "source", .target = .{ .entity = a } }, .{ .role = "target", .target = .{ .entity = b } } },
        .attributes = &.{},
        .evidence = &.{.{ .source = source, .quote = quote }},
        .state = .asserted,
        .certainty = .certain,
    });
    const second = try builder.addAssertion(.{
        .predicate = predicate,
        .participants = &.{ .{ .role = "source", .target = .{ .entity = b } }, .{ .role = "target", .target = .{ .unresolved = .{ .bytes = "banque", .label = "banque", .status = .unresolved } } } },
        .attributes = &.{},
        .evidence = &.{},
        .state = .inferred,
        .certainty = .possible,
    });
    try std.testing.expect(first.index != second.index);
    const model = try builder.build();
    var owned = model;
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 2), owned.assertions.len);
}

test "statement targets are backward-only and contexts retain graph identity" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();
    const predicate = try builder.addEntity(.{ .kind = .other, .external_id = "predicate" });
    const source = try builder.addEntity(.{ .kind = .source, .external_id = "source" });
    const subject = try builder.addEntity(.{ .kind = .sense, .external_id = "subject" });
    const object = try builder.addEntity(.{ .kind = .sense, .external_id = "object" });

    try std.testing.expectError(Error.InvalidStatementReference, builder.addAssertion(.{
        .predicate = predicate,
        .participants = &.{
            .{ .role = "subject", .target = .{ .statement = .{ .index = 0 } } },
            .{ .role = "object", .target = .{ .entity = object } },
        },
        .attributes = &.{},
        .evidence = &.{},
        .state = .asserted,
        .certainty = .certain,
    }));
    const base = try builder.addAssertion(.{
        .predicate = predicate,
        .participants = &.{
            .{ .role = "subject", .target = .{ .entity = subject } },
            .{ .role = "object", .target = .{ .entity = object } },
        },
        .attributes = &.{},
        .evidence = &.{},
        .state = .asserted,
        .certainty = .certain,
    });
    const quoted = try builder.addAssertion(.{
        .predicate = predicate,
        .participants = &.{
            .{ .role = "subject", .target = .{ .statement = base } },
            .{ .role = "object", .target = .{ .entity = object } },
        },
        .attributes = &.{},
        .evidence = &.{},
        .state = .asserted,
        .certainty = .probable,
        .context = .{ .named = source },
    });
    _ = try builder.addAssertion(.{
        .predicate = predicate,
        .participants = &.{
            .{ .role = "subject", .target = .{ .statement = quoted } },
            .{ .role = "object", .target = .{ .entity = object } },
        },
        .attributes = &.{},
        .evidence = &.{},
        .state = .retracted,
        .certainty = .certain,
        .context = .{ .anonymous = .{ .source = .{ .entity = source }, .id = 17 } },
    });
    var model = try builder.build();
    defer model.deinit();
    try std.testing.expectEqual(@as(usize, 3), model.assertions.len);
    try std.testing.expect(model.assertions[1].participants[0].target == .statement);
    try std.testing.expectEqual(base.index, model.assertions[1].participants[0].target.statement.index);
    try std.testing.expect(model.assertions[2].participants[0].target == .statement);
    try std.testing.expectEqual(quoted.index, model.assertions[2].participants[0].target.statement.index);
    try std.testing.expect(model.assertions[0].context == .default);
    try std.testing.expect(model.assertions[1].context == .named);
    try std.testing.expect(model.assertions[2].context == .anonymous);
}

test "document forest preserves mixed order and rejects invalid references" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();
    const ns = try builder.addNamespace("urn:tei", "tei");
    const text = try builder.addValue(.{ .text = .{ .bytes = "bank" } });
    const root = try builder.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "entry" } });
    const child = try builder.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "form" } });
    try builder.appendChild(root, .{ .text = text });
    try builder.appendChild(root, .{ .node = child });
    try builder.addDocumentRoot(root);
    const model = try builder.build();
    var owned = model;
    defer owned.deinit();
    const node = try owned.document(root);
    try std.testing.expectEqual(@as(usize, 2), node.children.len);
    try std.testing.expectError(Error.InvalidReference, builder.appendChild(root, .{ .text = .{ .index = 99 } }));
}

test "semantic builder survives every injected allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureFixture, .{});
}

fn allocationFailureFixture(allocator: std.mem.Allocator) !void {
    var builder = Builder.init(allocator);
    defer builder.deinit();
    const ns = try builder.addNamespace("urn:test", "t");
    const value = try builder.addValue(.{ .text = .{ .bytes = "value" } });
    const predicate = try builder.addEntity(.{ .kind = .other, .external_id = "predicate" });
    const source = try builder.addEntity(.{ .kind = .source, .external_id = "source" });
    _ = try builder.addAssertion(.{
        .predicate = predicate,
        .participants = &.{
            .{ .role = "subject", .target = .{ .value = value } },
            .{ .role = "object", .target = .{ .unresolved = .{ .bytes = "target", .uri = "urn:target" } } },
        },
        .attributes = &.{.{ .name = .{ .namespace = ns, .local = "kind" }, .value = value }},
        .evidence = &.{.{ .source = source, .attributes = &.{.{ .name = .{ .namespace = ns, .local = "where" }, .value = value }} }},
        .state = .asserted,
        .certainty = .certain,
    });
    const root = try builder.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "root" }, .attributes = &.{.{ .name = .{ .namespace = ns, .local = "kind" }, .value = value }} });
    _ = try builder.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "child" }, .parent = root });
    try builder.addDocumentRoot(root);
    var model = try builder.build();
    defer model.deinit();
}

test "typed values preserve bytes, text, and explicit absence" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();
    const bytes = try builder.addValue(.{ .bytes = &.{ 0, 0xff, 0 } });
    const absent = try builder.addValue(.absent);
    const unknown = try builder.addValue(.{ .unknown = .{} });
    try std.testing.expectEqual(@as(u8, 0xff), builder.values.items[bytes.index].bytes[1]);
    try std.testing.expect(absent.index != unknown.index);
    try std.testing.expectError(Error.InvalidUtf8, builder.addValue(.{ .text = .{ .bytes = &.{0xff} } }));
}

test "URI and calendar validation reject malformed or impossible values" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();
    _ = try builder.addValue(.{ .uri = "https://example.test/a%20b" });
    try std.testing.expectError(Error.InvalidUri, builder.addValue(.{ .uri = "" }));
    try std.testing.expectError(Error.InvalidUri, builder.addValue(.{ .uri = "https://example.test/%zz" }));
    const predicate = try builder.addEntity(.{ .kind = .other });
    _ = try builder.addAssertion(.{
        .predicate = predicate,
        .participants = &.{ .{ .role = "a", .target = .{ .entity = predicate } }, .{ .role = "b", .target = .{ .entity = predicate } } },
        .attributes = &.{},
        .evidence = &.{},
        .state = .asserted,
        .certainty = .certain,
        .temporal = .{ .start = .{ .year = 2024, .month = 2, .day = 29 }, .precision = .exact },
    });
    try std.testing.expectError(Error.InvalidDate, builder.addAssertion(.{
        .predicate = predicate,
        .participants = &.{ .{ .role = "a", .target = .{ .entity = predicate } }, .{ .role = "b", .target = .{ .entity = predicate } } },
        .attributes = &.{},
        .evidence = &.{},
        .state = .asserted,
        .certainty = .certain,
        .temporal = .{ .start = .{ .year = 2023, .month = 2, .day = 29 }, .precision = .exact },
    }));
    try std.testing.expectError(Error.InvalidDate, builder.addAssertion(.{
        .predicate = predicate,
        .participants = &.{ .{ .role = "a", .target = .{ .entity = predicate } }, .{ .role = "b", .target = .{ .entity = predicate } } },
        .attributes = &.{},
        .evidence = &.{},
        .state = .asserted,
        .certainty = .certain,
        .temporal = .{ .start = .{ .year = 2024 }, .precision = .day },
    }));
}

test "document validation uses the explicit depth budget" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();
    builder.setDocumentDepthBudget(1);
    const ns = try builder.addNamespace("urn:test", "t");
    const root = try builder.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "root" } });
    const child = try builder.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "child" }, .parent = root });
    _ = try builder.addDocumentNode(.{ .name = .{ .namespace = ns, .local = "grandchild" }, .parent = child });
    try builder.addDocumentRoot(root);
    try std.testing.expectError(Error.DocumentDepthExceeded, builder.build());
}
