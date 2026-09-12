const std = @import("std");

pub const Kind = enum(u8) {
    form,
    variant,
    inflection,
    part,
    pronunciation,
    analysis,
    entry,
    lexeme,
    homograph,
    sense,
    subsense,
    definition,
    gloss,
    example,
    usage,
    citation,
    concept,
    interlingual,
    source,
    assertion,
    participant,
    evidence,
    annotation,
};

pub const Domain = union(enum) {
    record: Kind,
    document,
    local_occurrence,
    occurrence,
    fact,
    binding,
    source_order,
    predicate,
    string,
    text,
    value,
    external_domain,
};

pub fn Id(comptime reference_domain_value: Domain) type {
    return enum(u32) {
        _,
        pub const reference_domain = reference_domain_value;

        pub fn fromIndex(position: usize) error{RankOverflow}!@This() {
            if (position >= std.math.maxInt(u32)) return error.RankOverflow;
            return @enumFromInt(@as(u32, @intCast(position)));
        }

        pub fn index(self: @This()) usize {
            return @intFromEnum(self);
        }
    };
}

pub const DocumentId = Id(.document);
pub const LocalOccurrenceId = Id(.local_occurrence);
pub const OccurrenceId = Id(.occurrence);
pub const ScopedOccurrence = struct { document: DocumentId, occurrence: LocalOccurrenceId };
pub const FactId = Id(.fact);
pub const BindingId = Id(.binding);
pub const SourceOrderId = Id(.source_order);
pub const PredicateId = Id(.predicate);
pub const StringId = Id(.string);
pub const TextId = Id(.text);
pub const ValueId = Id(.value);
pub const ExternalDomainId = Id(.external_domain);
pub const kind_count = @typeInfo(Kind).@"enum".fields.len;
pub const DomainOwner = enum { occurrence_record, concept, interlingual, external };

pub fn domainOwner(kind: Kind) DomainOwner {
    return switch (kind) {
        .concept => .concept,
        .interlingual => .interlingual,
        .source => .external,
        else => .occurrence_record,
    };
}

pub fn Ref(comptime kind: Kind) type {
    return Id(.{ .record = kind });
}

fn AnyRefType() type {
    const kinds = @typeInfo(Kind).@"enum".fields;
    var names: [kinds.len][]const u8 = undefined;
    var types: [kinds.len]type = undefined;
    inline for (kinds, 0..) |field, index| {
        const kind: Kind = @enumFromInt(field.value);
        names[index] = field.name;
        types[index] = Ref(kind);
    }
    return @Union(.auto, Kind, &names, &types, &@splat(.{}));
}

pub const AnyRef = AnyRefType();

pub fn anyRefRank(reference: AnyRef) u32 {
    return switch (reference) {
        inline else => |rank| @intFromEnum(rank),
    };
}

pub const ExpandedName = struct {
    namespace_uri: []const u8,
    local_name: []const u8,
    prefix: ?[]const u8 = null,
};
pub const NamespaceInput = struct { prefix: ?[]const u8 = null, uri: []const u8 };
pub const AttributeInput = struct { name: ExpandedName, value: []const u8 };
pub const EventInput = union(enum) {
    text: []const u8,
    child: LocalOccurrenceId,
    comment: []const u8,
    processing_instruction: struct { target: []const u8, data: []const u8 },
};
pub const OccurrenceInput = struct {
    name: ?ExpandedName = null,
    namespaces: []const NamespaceInput = &.{},
    attributes: []const AttributeInput = &.{},
    content: []const EventInput = &.{},
};
pub const DocumentInput = struct {
    scope: []const u8,
    occurrences: []const OccurrenceInput,
    content: []const EventInput = &.{},
};
pub const Identity = union(enum) { numeric: i64, text: []const u8 };
pub const RecordProperties = struct {
    written: ?[]const u8 = null,
    label: ?[]const u8 = null,
    language: ?[]const u8 = null,
    part_of_speech: ?[]const u8 = null,
    features: ?ValueId = null,
    type_label: ?ValueId = null,
    external_id: ?Identity = null,
};

fn EntityInputType() type {
    const kinds = @typeInfo(Kind).@"enum".fields;
    var names: [kinds.len][]const u8 = undefined;
    var types: [kinds.len]type = undefined;
    inline for (kinds, 0..) |field, index| {
        names[index] = field.name;
        types[index] = RecordProperties;
    }
    return @Union(.auto, Kind, &names, &types, &@splat(.{}));
}

pub const EntityInput = EntityInputType();
pub const RecordInput = EntityInput;
pub const KeyInput = union(enum) {
    headword: struct { key: []const u8, entry: Ref(.entry) },
    form: struct { key: []const u8, form: Ref(.form), targets: []const Ref(.entry) },
};
pub const SourceSpan = struct { owner: ScopedOccurrence, start: u32, end: u32 };
pub const Anchor = union(enum) { occurrence: ScopedOccurrence, span: SourceSpan };
pub const SourceEventSpan = struct { owner: OccurrenceId, start: u32, end: u32 };
pub const SourceHandle = union(enum) { occurrence: OccurrenceId, span: SourceEventSpan };
pub const BindingRole = enum(u8) { realization, mention, evidence, annotation };
pub const BindingInput = struct { record: AnyRef, source: Anchor, role: BindingRole = .realization };
pub const ExternalRankInput = struct { kind: Kind, count: u32 };
pub const ScopeKind = enum { global, document, source };
pub const ScopeKinds = std.EnumSet(ScopeKind);
pub const ExternalKeyPolicy = enum { numeric, text, either };
pub const ExternalIdentityDomainInput = struct {
    name: []const u8,
    key_policy: ExternalKeyPolicy = .either,
    allowed_scopes: ScopeKinds = ScopeKinds.initFull(),
    scopes: ?[]const ExternalScope = null,
    keys: ?[]const Identity = null,
};
pub const AssertionState = enum(u8) { asserted, inferred, disputed, deprecated };
pub const ExternalResolution = union(enum) { unresolved, resolved: AnyRef };
pub const ExternalScope = union(enum) { global, document: DocumentId, source: []const u8 };
pub const ExternalReference = struct {
    domain: ExternalDomainId,
    scope: ExternalScope = .global,
    key: Identity,
    resolution: ExternalResolution = .unresolved,
};
pub const TargetInput = union(enum) {
    record: AnyRef,
    occurrence: ScopedOccurrence,
    span: SourceSpan,
    value: ValueId,
    fact: FactId,
    external: ExternalReference,
};
pub const ValueFieldInput = struct { name: []const u8, value: ValueId };
pub const ValueInput = union(enum) {
    string: []const u8,
    symbol: []const u8,
    boolean: bool,
    integer: i64,
    decimal: []const u8,
    reference: TargetInput,
    external_reference: ExternalReference,
    product: struct { type_label: ?[]const u8 = null, fields: []const ValueFieldInput },
    list: []const ValueId,
    set: []const ValueId,
    bag: []const ValueId,
    alternative: []const ValueId,
    negation: ValueId,
    default_marker,
    unknown,
    unspecified,
};
pub const CertaintyInput = struct {
    locus: ?ValueId = null,
    degree: ?ValueId = null,
    asserted: ?ValueId = null,
    given: ?ValueId = null,
};
pub const Qualifiers = struct {
    source: ?Ref(.source) = null,
    asserted_by: ?Ref(.source) = null,
    language: ?[]const u8 = null,
    state: ?AssertionState = null,
    certainty: ?CertaintyInput = null,
    temporal: ?[]const u8 = null,
    register: ?[]const u8 = null,
    usage: ?[]const u8 = null,
    properties: ?ValueId = null,
};
pub const FactTarget = TargetInput;
pub const MembershipTarget = union(enum) { concept: Ref(.concept), interlingual: Ref(.interlingual) };
pub const FactInput = union(enum) {
    relation: struct { subject: TargetInput, predicate: PredicateId, object: FactTarget, qualifiers: Qualifiers = .{} },
    membership: struct { member: AnyRef, target: MembershipTarget, qualifiers: Qualifiers = .{} },
};
pub const Input = struct {
    documents: []const DocumentInput,
    records: []const RecordInput,
    keys: []const KeyInput,
    bindings: []const BindingInput = &.{},
    facts: []const FactInput = &.{},
    predicates: []const PredicateInput = &.{},
    values: []const ValueInput = &.{},
    external_ranks: []const ExternalRankInput = &.{},
    external_identity_domains: []const ExternalIdentityDomainInput = &.{},
};

pub const EndpointConstraint = union(enum) {
    any,
    record: ?Kind,
    value,
    fact,
    occurrence,
    span,
    external: ?ExternalDomainId,
};
pub const PredicateInput = struct {
    name: []const u8,
    external_id: ?Identity = null,
    subject: EndpointConstraint = .any,
    object: EndpointConstraint = .any,
};

pub const DomainStatus = union(enum) { unresolved, owned: u32, external: u32 };
pub const RecordAddress = enum { owned, addressable };
pub const RecordSpace = struct {
    owned_ends: [kind_count + 1]u32 = [_]u32{0} ** (kind_count + 1),
    addressable_ends: [kind_count + 1]u32 = [_]u32{0} ** (kind_count + 1),

    pub fn fromCatalogue(catalogue: DomainCatalogue) error{ UnresolvedDomain, Overflow }!RecordSpace {
        var result: RecordSpace = .{};
        const Counts = struct { owned: u32, addressable: u32 };
        inline for (@typeInfo(Kind).@"enum".fields) |field| {
            const kind: Kind = @enumFromInt(field.value);
            const index = @intFromEnum(kind);
            const counts: Counts = switch (catalogue.statusFor(.{ .record = kind })) {
                .unresolved => return error.UnresolvedDomain,
                .owned => |count| .{ .owned = count, .addressable = count },
                .external => |count| .{ .owned = @as(u32, 0), .addressable = count },
            };
            result.owned_ends[index + 1] = std.math.add(u32, result.owned_ends[index], counts.owned) catch return error.Overflow;
            result.addressable_ends[index + 1] = std.math.add(u32, result.addressable_ends[index], counts.addressable) catch return error.Overflow;
        }
        return result;
    }

    pub fn fromInputs(records: []const RecordInput, declarations: []const ExternalRankInput) error{ ConflictingDomain, InvalidExternalDomain, Overflow }!RecordSpace {
        var owned = [_]u32{0} ** kind_count;
        var external = [_]?u32{null} ** kind_count;
        for (records) |record| {
            const slot = &owned[@intFromEnum(std.meta.activeTag(record))];
            slot.* = std.math.add(u32, slot.*, 1) catch return error.Overflow;
        }
        for (declarations) |declaration| {
            if (domainOwner(declaration.kind) != .external) return error.InvalidExternalDomain;
            const index = @intFromEnum(declaration.kind);
            if (owned[index] != 0) return error.ConflictingDomain;
            if (external[index]) |known| {
                if (known != declaration.count) return error.ConflictingDomain;
            } else {
                external[index] = declaration.count;
            }
        }
        var result: RecordSpace = .{};
        for (owned, 0..) |owned_count, index| {
            const addressable_count = external[index] orelse owned_count;
            result.owned_ends[index + 1] = std.math.add(u32, result.owned_ends[index], owned_count) catch return error.Overflow;
            result.addressable_ends[index + 1] = std.math.add(u32, result.addressable_ends[index], addressable_count) catch return error.Overflow;
        }
        return result;
    }

    pub fn total(self: RecordSpace, comptime address: RecordAddress) u32 {
        return switch (address) {
            .owned => self.owned_ends[kind_count],
            .addressable => self.addressable_ends[kind_count],
        };
    }

    pub fn coordinate(self: RecordSpace, reference: AnyRef, comptime address: RecordAddress) error{ OutOfDomain, Overflow }!u32 {
        const ends = switch (address) {
            .owned => self.owned_ends,
            .addressable => self.addressable_ends,
        };
        const kind = @intFromEnum(std.meta.activeTag(reference));
        const rank = anyRefRank(reference);
        const count = std.math.sub(u32, ends[kind + 1], ends[kind]) catch return error.OutOfDomain;
        if (rank >= count) return error.OutOfDomain;
        return std.math.add(u32, ends[kind], rank) catch return error.Overflow;
    }

    pub fn groupedCoordinate(self: RecordSpace, reference: AnyRef, comptime address: RecordAddress, groups_per_record: u32, group: u32) error{ OutOfDomain, Overflow }!u32 {
        if (group >= groups_per_record) return error.OutOfDomain;
        const base = std.math.mul(u32, try self.coordinate(reference, address), groups_per_record) catch return error.Overflow;
        return std.math.add(u32, base, group) catch return error.Overflow;
    }
};

pub const DomainCatalogue = struct {
    domains: [kind_count]DomainStatus = [_]DomainStatus{.unresolved} ** kind_count,
    document: DomainStatus = .unresolved,
    local_occurrence: DomainStatus = .unresolved,
    occurrence: DomainStatus = .unresolved,
    fact: DomainStatus = .unresolved,
    binding: DomainStatus = .unresolved,
    source_order: DomainStatus = .unresolved,
    predicate: DomainStatus = .unresolved,
    string: DomainStatus = .unresolved,
    text: DomainStatus = .unresolved,
    value: DomainStatus = .unresolved,
    external_domain: DomainStatus = .unresolved,

    fn slot(self: *DomainCatalogue, domain: Domain) *DomainStatus {
        return switch (domain) {
            .record => |kind| &self.domains[@intFromEnum(kind)],
            .document => &self.document,
            .local_occurrence => &self.local_occurrence,
            .occurrence => &self.occurrence,
            .fact => &self.fact,
            .binding => &self.binding,
            .source_order => &self.source_order,
            .predicate => &self.predicate,
            .string => &self.string,
            .text => &self.text,
            .value => &self.value,
            .external_domain => &self.external_domain,
        };
    }

    pub fn setOwned(self: *DomainCatalogue, domain: Domain, count_value: u32) error{ConflictingDomain}!void {
        const status = self.slot(domain);
        switch (status.*) {
            .unresolved => status.* = .{ .owned = count_value },
            .owned => |known| if (known != count_value) return error.ConflictingDomain,
            .external => return error.ConflictingDomain,
        }
    }

    pub fn declareExternal(self: *DomainCatalogue, kind: Kind, count_value: u32) error{ InvalidExternalDomain, ConflictingDomain }!void {
        if (domainOwner(kind) != .external) return error.InvalidExternalDomain;
        const status = &self.domains[@intFromEnum(kind)];
        switch (status.*) {
            .unresolved => status.* = .{ .external = count_value },
            .external => |known| if (known != count_value) return error.ConflictingDomain,
            .owned => return error.ConflictingDomain,
        }
    }

    pub fn countForVerify(self: DomainCatalogue, domain: Domain) error{UnresolvedDomain}!u32 {
        var copy = self;
        return switch (copy.slot(domain).*) {
            .unresolved => error.UnresolvedDomain,
            .owned, .external => |count_value| count_value,
        };
    }

    pub fn statusFor(self: DomainCatalogue, domain: Domain) DomainStatus {
        var copy = self;
        return copy.slot(domain).*;
    }
};

test "typed ranks and runtime references retain their domains" {
    const entry = try Ref(.entry).fromIndex(3);
    const reference = AnyRef{ .entry = entry };
    try std.testing.expectEqual(Kind.entry, std.meta.activeTag(reference));
    try std.testing.expectEqual(@as(u32, 3), anyRefRank(reference));
}

test "record space rejects forged extents and grouped coordinate overflow" {
    var descending: RecordSpace = .{};
    descending.owned_ends[@intFromEnum(Kind.entry)] = 4;
    descending.owned_ends[@intFromEnum(Kind.entry) + 1] = 3;
    try std.testing.expectError(error.OutOfDomain, descending.coordinate(.{ .entry = @enumFromInt(0) }, .owned));

    var overflowing: RecordSpace = .{};
    overflowing.owned_ends[@intFromEnum(Kind.entry) + 1] = std.math.maxInt(u32);
    try std.testing.expectError(error.Overflow, overflowing.groupedCoordinate(.{ .entry = @enumFromInt(std.math.maxInt(u32) - 1) }, .owned, 2, 1));
    try std.testing.expectError(error.OutOfDomain, overflowing.groupedCoordinate(.{ .entry = @enumFromInt(0) }, .owned, 1, 1));

    try std.testing.expectError(error.InvalidExternalDomain, RecordSpace.fromInputs(&.{}, &.{.{ .kind = .entry, .count = 1 }}));
}
