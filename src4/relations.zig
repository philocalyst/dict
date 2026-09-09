//! LEX4 asserted relations and concept memberships.
//!
//! The wire section deliberately separates physical claims from adjacency
//! references.  A symmetric claim has one physical record and two references;
//! an inverse pair has one physical record in the lower relation's orientation
//! and two references with the two logical predicates.  The physical record's
//! two-bit asserted-direction mask distinguishes source claims from inferred
//! reverse arcs.  No transitive closure is materialised.  `View.traverse` is
//! the explicit, caller-budgeted closure operation.

const std = @import("std");
const schema = @import("schema.zig");
const table = @import("table.zig");
const wire = @import("wire.zig");

pub const Kind = schema.Kind;
pub const RelationId = schema.RelationId;
pub const Rank = schema.Rank;
pub const AssertionState = schema.AssertionState;
pub const Certainty = schema.Certainty;

/// Runtime-erased ranks and interned language-table identifiers remain typed
/// at public boundaries.  The wire layer converts them to fixed-width u32
/// only while encoding/decoding.
pub const EndpointRank = enum(u32) {
    _,

    pub fn fromIndex(value: usize) error{Overflow}!@This() {
        if (value >= std.math.maxInt(u32)) return error.Overflow;
        return @enumFromInt(@as(u32, @intCast(value)));
    }

    pub fn index(self: @This()) usize {
        return @intFromEnum(self);
    }
};

pub const LanguageId = enum(u32) {
    _,

    pub fn fromIndex(value: usize) error{Overflow}!@This() {
        if (value >= std.math.maxInt(u32)) return error.Overflow;
        return @enumFromInt(@as(u32, @intCast(value)));
    }

    pub fn index(self: @This()) usize {
        return @intFromEnum(self);
    }
};

pub const magic = "L4RL";
// v2 gave canonical physical edges an asserted-direction mask. v1 treated
// every materialised reverse arc as equally asserted, which was lossy for
// inverse and symmetric relations. v3 changes only the section payloads to
// generated scalar tables; no legacy decoder is retained for this unpublished
// format.
pub const version: u16 = 3;
pub const header_size: usize = 112;
pub const endpoint_size: usize = 8;
/// Legacy fixed-layout sizes retained only for the raw-layout ablation.  The
/// published v3 section stores generated scalar tables, so these constants
/// are never used to locate or size a live table.
pub const edge_record_size: usize = 32;
pub const arc_record_size: usize = 16;
pub const membership_record_size: usize = 32;
pub const membership_arc_record_size: usize = 16;

pub const Error = std.mem.Allocator.Error || error{
    BadMagic,
    UnsupportedVersion,
    InvalidEncoding,
    Truncated,
    Overflow,
    InvalidKind,
    InvalidRank,
    InvalidRelation,
    InvalidEndpoint,
    DomainMismatch,
    RangeMismatch,
    InvalidAssertion,
    InvalidMembership,
    DuplicateEdge,
    DuplicateMembership,
    Unsorted,
    OutOfRange,
    Unverified,
    UnsupportedTraversal,
    TraversalBudgetExceeded,
    TraversalBufferTooSmall,
    InputLimitExceeded,
};

/// A runtime endpoint is intentionally a small erased value.  Construction
/// from `Rank(kind)` is typed, while wire input is checked before this value is
/// exposed to callers.
pub const Endpoint = struct {
    kind: Kind,
    rank: EndpointRank,

    pub fn fromRank(comptime kind: Kind, value: Rank(kind)) Error!Endpoint {
        const index = value.index() orelse return error.InvalidRank;
        return .{ .kind = kind, .rank = EndpointRank.fromIndex(index) catch return error.Overflow };
    }

    pub fn typed(comptime kind: Kind, value: Rank(kind)) Error!Endpoint {
        return fromRank(kind, value);
    }

    pub fn isValid(self: Endpoint) bool {
        return @intFromEnum(self.kind) < schema.kind_count and @intFromEnum(self.rank) != std.math.maxInt(u32);
    }

    pub fn eql(self: Endpoint, other: Endpoint) bool {
        return self.kind == other.kind and self.rank == other.rank;
    }
};

pub const AssertionOptions = struct {
    state: AssertionState = .asserted,
    certainty: Certainty = .unknown,
    asserted_by: ?Rank(.source) = null,
};

/// Input for one asserted pairwise claim.  This type is also useful for
/// explicitly asserted near/disputed claims; the builder never expands a
/// membership into pairwise synonym or translation edges.
pub const EdgeInput = struct {
    relation: RelationId,
    source: Endpoint,
    target: Endpoint,
    state: AssertionState = .asserted,
    certainty: Certainty = .unknown,
    asserted_by: ?Rank(.source) = null,
};

pub const AssertionInput = EdgeInput;

/// A concept or interlingual membership.  `language` is an interned language
/// value supplied by the snapshot's language table; zero is a valid caller
/// convention for "not projected" and is never used to create edges.
pub const MembershipInput = struct {
    group: Endpoint,
    member: Endpoint,
    language: LanguageId = @enumFromInt(0),
    confidence: Certainty = .unknown,
    asserted_by: ?Rank(.source) = null,
};

pub const Membership = struct {
    group: Endpoint,
    member: Endpoint,
    language: LanguageId,
    confidence: Certainty,
    asserted_by: ?Rank(.source),
    physical_index: usize,
};

pub const Edge = struct {
    relation: RelationId,
    source: Endpoint,
    target: Endpoint,
    state: AssertionState,
    certainty: Certainty,
    asserted_by: ?Rank(.source),
    /// True when this logical direction was present in the input claims.
    /// Reverse arcs for inverse/symmetric families remain queryable but are
    /// marked false unless the source explicitly asserted that direction.
    explicit: bool,
    physical_index: usize,
};

pub const ResolvedEdge = Edge;

pub const BuildInput = struct {
    edges: []const EdgeInput = &.{},
    memberships: []const MembershipInput = &.{},
};

pub const Options = struct {
    max_edges: usize = 16 * 1024 * 1024,
    max_memberships: usize = 16 * 1024 * 1024,
};

pub const Limits = struct {
    max_edges: usize = 16 * 1024 * 1024,
    max_arcs: usize = 32 * 1024 * 1024,
    max_memberships: usize = 16 * 1024 * 1024,
    max_membership_arcs: usize = 32 * 1024 * 1024,
};

pub const ReadRange = struct {
    offset: usize,
    length: usize,
};

pub const SectionKind = enum {
    edges,
    arcs,
    memberships,
    membership_arcs,
};

/// Size of the superseded fixed-layout graph for an identical row count.
/// This is an ablation/reporting helper only; no reader or writer uses it.
/// Keeping it here makes the comparison charge the same header and alignment
/// policy as the generated-table section rather than comparing payloads alone.
pub fn rawFixedLayoutSize(edge_count: usize, arc_count: usize, membership_count: usize, membership_arc_count: usize) Error!usize {
    var total = try align8(header_size);
    const lengths = [_]usize{
        try checkedMul(edge_count, edge_record_size),
        try checkedMul(arc_count, arc_record_size),
        try checkedMul(membership_count, membership_record_size),
        try checkedMul(membership_arc_count, membership_arc_record_size),
    };
    for (lengths, 0..) |length, index| {
        total = try checkedAdd(total, length);
        if (index + 1 < lengths.len) total = try align8(total);
    }
    return total;
}

const Envelope = struct {
    edge_count: usize,
    arc_count: usize,
    membership_count: usize,
    membership_arc_count: usize,
    ranges: [4]ReadRange,
    total_len: usize,
};

/// One canonical physical claim.  `explicit_mask` is deliberately kept out of
/// `EdgeInput`: it is aggregate provenance created while canonicalising input
/// claims, not a second durable identity or caller-controlled rank.
pub const PhysicalEdge = struct {
    relation: RelationId,
    source: Endpoint,
    target: Endpoint,
    state: AssertionState,
    certainty: Certainty,
    asserted_by: ?Rank(.source),
    explicit_mask: u8,
};

/// Build-time arc witness. `target` is needed for sorting and canonical
/// direction checks, but it is derived from the physical edge and is not a
/// stored table field.
const ArcInput = struct {
    source: Endpoint,
    target: Endpoint,
    relation: RelationId,
    edge_index: u32,
    direction: u8,
};

pub const ArcWire = struct {
    source: Endpoint,
    edge_index: u32,
    relation: RelationId,
    direction: u8,
};

pub const MembershipArcWire = struct {
    key: Endpoint,
    membership_index: u32,
    direction: u8,
};

const EdgeTable = table.Table(PhysicalEdge);
const ArcTable = table.Table(ArcWire);
const MembershipTable = table.Table(MembershipInput);
const MembershipArcTable = table.Table(MembershipArcWire);

const MembershipArcInput = MembershipArcWire;

fn mapTableBuildError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Overflow => error.Overflow,
        else => error.InvalidEncoding,
    };
}

fn relationIndex(relation: RelationId) usize {
    return @intFromEnum(relation);
}

fn kindAllowed(comptime set: schema.KindSet, comptime kind: Kind) bool {
    const mask: std.meta.Int(.unsigned, schema.kind_count) = @bitCast(set);
    return (mask & (@as(@TypeOf(mask), 1) << @intFromEnum(kind))) != 0;
}

fn validRelation(raw: u8) Error!RelationId {
    if (raw >= @typeInfo(RelationId).@"enum".fields.len) return error.InvalidRelation;
    return @enumFromInt(raw);
}

fn validateRelation(relation: RelationId) Error!void {
    if (@intFromEnum(relation) >= @typeInfo(RelationId).@"enum".fields.len)
        return error.InvalidRelation;
}

fn validKind(raw: u8) Error!Kind {
    if (raw >= schema.kind_count) return error.InvalidKind;
    return @enumFromInt(raw);
}

fn validState(raw: u8) Error!AssertionState {
    if (raw >= @typeInfo(AssertionState).@"enum".fields.len) return error.InvalidAssertion;
    return @enumFromInt(raw);
}

fn validCertainty(raw: u8) Error!Certainty {
    if (raw >= @typeInfo(Certainty).@"enum".fields.len) return error.InvalidAssertion;
    return @enumFromInt(raw);
}

fn rawEndpoint(kind: Kind, rank: u32) Error!Endpoint {
    if (rank == std.math.maxInt(u32)) return error.InvalidRank;
    return .{ .kind = kind, .rank = @enumFromInt(rank) };
}

fn endpointCompare(left: Endpoint, right: Endpoint) std.math.Order {
    const left_kind = @intFromEnum(left.kind);
    const right_kind = @intFromEnum(right.kind);
    const left_rank = @intFromEnum(left.rank);
    const right_rank = @intFromEnum(right.rank);
    if (left_kind < right_kind) return .lt;
    if (left_kind > right_kind) return .gt;
    if (left_rank < right_rank) return .lt;
    if (left_rank > right_rank) return .gt;
    return .eq;
}

fn endpointLess(left: Endpoint, right: Endpoint) bool {
    return endpointCompare(left, right) == .lt;
}

fn canonicalRelation(relation: RelationId) RelationId {
    const spec = schema.relations.get(relation);
    if (spec.inverse) |inverse| {
        return if (relationIndex(relation) < relationIndex(inverse)) relation else inverse;
    }
    return relation;
}

pub fn relationSpec(relation: RelationId) schema.RelationSpec {
    return schema.relations.get(relation);
}

pub fn isSymmetric(relation: RelationId) bool {
    return relationSpec(relation).symmetric;
}

pub fn isTransitive(relation: RelationId) bool {
    return relationSpec(relation).transitive;
}

pub fn physicalRelation(relation: RelationId) RelationId {
    return canonicalRelation(relation);
}

fn validateEndpointValue(value: Endpoint) Error!void {
    if (@intFromEnum(value.kind) >= schema.kind_count) return error.InvalidKind;
    if (@intFromEnum(value.rank) == std.math.maxInt(u32)) return error.InvalidRank;
}

fn validateAssertionOptions(state: AssertionState, certainty: Certainty, asserted_by: ?Rank(.source)) Error!void {
    if (@intFromEnum(state) >= @typeInfo(AssertionState).@"enum".fields.len or
        @intFromEnum(certainty) >= @typeInfo(Certainty).@"enum".fields.len) return error.InvalidAssertion;
    if (asserted_by) |source| if (source.index() == null) return error.InvalidRank;
}

fn validateEdge(input: EdgeInput) Error!void {
    try validateRelation(input.relation);
    try validateEndpointValue(input.source);
    try validateEndpointValue(input.target);
    try validateAssertionOptions(input.state, input.certainty, input.asserted_by);
    const spec = schema.relations.get(input.relation);
    if (!spec.domain.isSet(@intFromEnum(input.source.kind))) return error.DomainMismatch;
    if (!spec.range.isSet(@intFromEnum(input.target.kind))) return error.RangeMismatch;
}

fn normalizeEdge(input: EdgeInput) Error!PhysicalEdge {
    try validateEdge(input);
    var result = PhysicalEdge{
        .relation = input.relation,
        .source = input.source,
        .target = input.target,
        .state = input.state,
        .certainty = input.certainty,
        .asserted_by = input.asserted_by,
        .explicit_mask = 1,
    };
    const family = canonicalRelation(input.relation);
    result.relation = family;
    if (input.relation != family) {
        std.mem.swap(Endpoint, &result.source, &result.target);
        result.explicit_mask = 2;
    }
    if (schema.relations.get(family).symmetric and endpointCompare(result.target, result.source) == .lt) {
        std.mem.swap(Endpoint, &result.source, &result.target);
        result.explicit_mask = 2;
    }
    return result;
}

fn asEdgeInput(physical: PhysicalEdge) EdgeInput {
    return .{
        .relation = physical.relation,
        .source = physical.source,
        .target = physical.target,
        .state = physical.state,
        .certainty = physical.certainty,
        .asserted_by = physical.asserted_by,
    };
}

fn samePhysicalFields(left: PhysicalEdge, right: PhysicalEdge) bool {
    const left_source = left.asserted_by orelse Rank(.source).none;
    const right_source = right.asserted_by orelse Rank(.source).none;
    return left.relation == right.relation and left.source.eql(right.source) and
        left.target.eql(right.target) and left.state == right.state and
        left.certainty == right.certainty and @intFromEnum(left_source) == @intFromEnum(right_source);
}

fn validExplicitMask(physical: PhysicalEdge) Error!void {
    if (physical.explicit_mask == 0 or physical.explicit_mask > 3) return error.InvalidEncoding;
    const spec = schema.relations.get(physical.relation);
    // A non-symmetric relation without an inverse has only its stored
    // orientation.  A symmetric self-loop also has one logical arc.
    if (spec.inverse == null and !spec.symmetric and physical.explicit_mask != 1)
        return error.InvalidEncoding;
    if (spec.symmetric and physical.source.eql(physical.target) and physical.explicit_mask != 1)
        return error.InvalidEncoding;
}

fn validateMembership(input: MembershipInput) Error!void {
    try validateEndpointValue(input.group);
    try validateEndpointValue(input.member);
    if (input.group.kind != .concept and input.group.kind != .interlingual)
        return error.InvalidMembership;
    if (input.member.kind != .sense and input.member.kind != .subsense)
        return error.InvalidMembership;
    if (@intFromEnum(input.confidence) >= @typeInfo(Certainty).@"enum".fields.len)
        return error.InvalidAssertion;
    if (input.asserted_by) |source| if (source.index() == null) return error.InvalidRank;
}

fn physicalEqual(left: PhysicalEdge, right: PhysicalEdge) bool {
    return samePhysicalFields(left, right);
}

fn physicalLess(_: void, left: PhysicalEdge, right: PhysicalEdge) bool {
    if (relationIndex(left.relation) != relationIndex(right.relation))
        return relationIndex(left.relation) < relationIndex(right.relation);
    if (endpointCompare(left.source, right.source) != .eq)
        return endpointLess(left.source, right.source);
    if (endpointCompare(left.target, right.target) != .eq)
        return endpointLess(left.target, right.target);
    if (@intFromEnum(left.state) != @intFromEnum(right.state))
        return @intFromEnum(left.state) < @intFromEnum(right.state);
    if (@intFromEnum(left.certainty) != @intFromEnum(right.certainty))
        return @intFromEnum(left.certainty) < @intFromEnum(right.certainty);
    const left_source = left.asserted_by orelse Rank(.source).none;
    const right_source = right.asserted_by orelse Rank(.source).none;
    return @intFromEnum(left_source) < @intFromEnum(right_source);
}

fn arcLess(_: void, left: ArcInput, right: ArcInput) bool {
    if (endpointCompare(left.source, right.source) != .eq)
        return endpointLess(left.source, right.source);
    if (relationIndex(left.relation) != relationIndex(right.relation))
        return relationIndex(left.relation) < relationIndex(right.relation);
    if (endpointCompare(left.target, right.target) != .eq)
        return endpointLess(left.target, right.target);
    if (left.edge_index != right.edge_index) return left.edge_index < right.edge_index;
    return left.direction < right.direction;
}

fn membershipLess(_: void, left: MembershipInput, right: MembershipInput) bool {
    if (endpointCompare(left.group, right.group) != .eq)
        return endpointLess(left.group, right.group);
    if (endpointCompare(left.member, right.member) != .eq)
        return endpointLess(left.member, right.member);
    if (left.language != right.language) return @intFromEnum(left.language) < @intFromEnum(right.language);
    if (@intFromEnum(left.confidence) != @intFromEnum(right.confidence))
        return @intFromEnum(left.confidence) < @intFromEnum(right.confidence);
    const left_source = left.asserted_by orelse Rank(.source).none;
    const right_source = right.asserted_by orelse Rank(.source).none;
    return @intFromEnum(left_source) < @intFromEnum(right_source);
}

fn membershipArcLess(_: void, left: MembershipArcWire, right: MembershipArcWire) bool {
    if (endpointCompare(left.key, right.key) != .eq) return endpointLess(left.key, right.key);
    if (left.direction != right.direction) return left.direction < right.direction;
    if (left.membership_index != right.membership_index) return left.membership_index < right.membership_index;
    return false;
}

fn checkedAdd(left: usize, right: usize) Error!usize {
    return std.math.add(usize, left, right) catch error.Overflow;
}

fn checkedMul(left: usize, right: usize) Error!usize {
    return std.math.mul(usize, left, right) catch error.Overflow;
}

fn castU32(value: usize) Error!u32 {
    return std.math.cast(u32, value) orelse error.Overflow;
}

fn castUsize(value: u64) Error!usize {
    return std.math.cast(usize, value) orelse error.Overflow;
}

fn align8(value: usize) Error!usize {
    const rounded = try checkedAdd(value, 7);
    return rounded & ~@as(usize, 7);
}

// Header integers are container metadata, not graph rows.  Keep this tiny
// adapter so malformed-header errors remain in the relation error namespace;
// all row serialization is generated by table.Table(Row).
fn readInt(comptime T: type, bytes: []const u8, at: usize) Error!T {
    return wire.readInt(T, bytes, at) catch |err| switch (err) {
        error.Truncated => error.Truncated,
        error.Overflow => error.Overflow,
        error.InvalidValue => error.InvalidEncoding,
        else => error.InvalidEncoding,
    };
}

fn writeInt(comptime T: type, bytes: []u8, at: usize, value: T) void {
    wire.writeInt(T, bytes, at, value) catch unreachable;
}

fn sourceLen(comptime Source: type, source: *const Source) usize {
    if (Source == []const u8 or Source == []u8) return source.*.len;
    return source.len();
}

fn sourceBytes(comptime Source: type, source: *Source, offset: usize, length: usize) anyerror![]const u8 {
    if (Source == []const u8 or Source == []u8) {
        if (offset > source.*.len or length > source.*.len - offset) return error.Truncated;
        return source.*[offset..][0..length];
    }
    return source.bytes(offset, length);
}

fn parseEnvelope(comptime Source: type, source: *Source, limits: Limits) anyerror!Envelope {
    const length = sourceLen(Source, source);
    if (length < header_size) return error.Truncated;
    const header = try sourceBytes(Source, source, 0, header_size);
    if (!std.mem.eql(u8, header[0..4], magic)) return error.BadMagic;
    if (try readInt(u16, header, 4) != version) return error.UnsupportedVersion;
    if (try readInt(u16, header, 6) != header_size or try readInt(u32, header, 8) != 0 or try readInt(u32, header, 12) != 0)
        return error.InvalidEncoding;

    const counts = [_]usize{
        try castUsize(try readInt(u64, header, 16)),
        try castUsize(try readInt(u64, header, 24)),
        try castUsize(try readInt(u64, header, 32)),
        try castUsize(try readInt(u64, header, 40)),
    };
    if (counts[0] > limits.max_edges or counts[1] > limits.max_arcs or
        counts[2] > limits.max_memberships or counts[3] > limits.max_membership_arcs)
        return error.InputLimitExceeded;
    if (counts[0] > std.math.maxInt(u32) or counts[2] > std.math.maxInt(u32)) return error.Overflow;

    var ranges: [4]ReadRange = undefined;
    var expected: usize = header_size;
    for (&ranges, 0..) |*range, index| {
        const offset = try castUsize(try readInt(u64, header, 48 + index * 16));
        const section_len = try castUsize(try readInt(u64, header, 56 + index * 16));
        if (offset != expected or offset % 8 != 0) return error.InvalidEncoding;
        // Each range contains a self-describing generated table.  Its
        // descriptor and residual lanes are part of the section length, so
        // no fixed record-size multiplication is valid here.
        if (section_len == 0) return error.InvalidEncoding;
        const section_end = try checkedAdd(offset, section_len);
        expected = if (index + 1 < ranges.len) try align8(section_end) else section_end;
        range.* = .{ .offset = offset, .length = section_len };
    }
    if (expected != length) return error.InvalidEncoding;
    return .{
        .edge_count = counts[0],
        .arc_count = counts[1],
        .membership_count = counts[2],
        .membership_arc_count = counts[3],
        .ranges = ranges,
        .total_len = length,
    };
}

/// A generic source lets a mapped container `Section` authenticate pages
/// before relation bytes are consumed.  `open` only checks this envelope;
/// `verify` performs semantic validation and reads the four sections once.
pub fn ViewFor(comptime Source: type) type {
    return struct {
        const Self = @This();

        source: Source,
        envelope: Envelope,
        edge_bytes: []const u8 = &.{},
        arc_bytes: []const u8 = &.{},
        membership_bytes: []const u8 = &.{},
        membership_arc_bytes: []const u8 = &.{},
        edge_table: EdgeTable.View = undefined,
        arc_table: ArcTable.View = undefined,
        membership_table: MembershipTable.View = undefined,
        membership_arc_table: MembershipArcTable.View = undefined,
        verified: bool = false,

        pub const RelationIterator = struct {
            view: *const Self,
            index: usize,
            end: usize,
            source: Endpoint,
            predicate: ?RelationId,
            explicit_only: bool = false,

            pub fn next(self: *RelationIterator) anyerror!?Edge {
                while (self.index < self.end) {
                    const ordinal = self.index;
                    self.index += 1;
                    const arc = self.view.arc_table.row(ordinal) catch return error.InvalidEncoding;
                    // Verification proves source order. A cursor needs only
                    // the lower bound; the first different key is its end,
                    // not a second binary search before the first result.
                    if (!arc.source.eql(self.source)) {
                        self.index = self.end;
                        return null;
                    }
                    if (self.predicate) |wanted| if (arc.relation != wanted) continue;
                    if (@as(usize, arc.edge_index) >= self.view.envelope.edge_count) return error.OutOfRange;
                    const physical = self.view.edge_table.row(@as(usize, arc.edge_index)) catch return error.InvalidEncoding;
                    const resolved = try self.view.resolveArc(physical, arc, @as(usize, arc.edge_index));
                    if (self.explicit_only and !resolved.explicit) continue;
                    return resolved;
                }
                return null;
            }
        };

        pub const MembershipIterator = struct {
            view: *const Self,
            index: usize,
            end: usize,
            key: Endpoint,
            direction: u8,
            language: ?LanguageId = null,

            pub fn next(self: *MembershipIterator) anyerror!?Membership {
                while (self.index < self.end) {
                    const ordinal = self.index;
                    self.index += 1;
                    const arc = self.view.membership_arc_table.row(ordinal) catch return error.InvalidEncoding;
                    if (!arc.key.eql(self.key)) {
                        self.index = self.end;
                        return null;
                    }
                    if (arc.direction != self.direction) continue;
                    if (@as(usize, arc.membership_index) >= self.view.envelope.membership_count) return error.OutOfRange;
                    const membership = self.view.membership_table.row(@as(usize, arc.membership_index)) catch return error.InvalidEncoding;
                    if (self.language) |wanted| if (membership.language != wanted) continue;
                    return .{
                        .group = membership.group,
                        .member = membership.member,
                        .language = membership.language,
                        .confidence = membership.confidence,
                        .asserted_by = membership.asserted_by,
                        .physical_index = arc.membership_index,
                    };
                }
                return null;
            }
        };

        pub const TranslationIterator = struct {
            view: *const Self,
            groups: MembershipIterator,
            members: ?MembershipIterator = null,
            original: Endpoint,
            language: ?LanguageId,

            pub fn next(self: *TranslationIterator) anyerror!?Membership {
                while (true) {
                    if (self.members) |*member_iterator| {
                        while (try member_iterator.next()) |candidate| {
                            if (candidate.member.eql(self.original)) continue;
                            if (self.language) |wanted| if (candidate.language != wanted) continue;
                            return candidate;
                        }
                        self.members = null;
                    }
                    const group_membership = (try self.groups.next()) orelse return null;
                    self.members = try self.view.members(group_membership.group);
                }
            }
        };

        pub fn open(source: Source) anyerror!Self {
            return openWithLimits(source, .{});
        }

        pub fn openWithLimits(source: Source, limits: Limits) anyerror!Self {
            var owned_source = source;
            const envelope = try parseEnvelope(Source, &owned_source, limits);
            return .{ .source = owned_source, .envelope = envelope };
        }

        pub fn openEnvelope(source: Source) anyerror!Self {
            return open(source);
        }

        pub fn openEnvelopeWithLimits(source: Source, limits: Limits) anyerror!Self {
            return openWithLimits(source, limits);
        }

        pub fn openAndVerify(source: Source) anyerror!Self {
            var result = try open(source);
            try result.verify();
            return result;
        }

        pub fn isVerified(self: *const Self) bool {
            return self.verified;
        }

        pub fn len(self: *const Self) usize {
            return self.envelope.total_len;
        }

        pub fn edgeCount(self: *const Self) usize {
            return self.envelope.edge_count;
        }

        pub fn physicalEdgeCount(self: *const Self) usize {
            return self.envelope.edge_count;
        }

        pub fn arcCount(self: *const Self) usize {
            return self.envelope.arc_count;
        }

        pub fn membershipCount(self: *const Self) usize {
            return self.envelope.membership_count;
        }

        pub fn membershipArcCount(self: *const Self) usize {
            return self.envelope.membership_arc_count;
        }

        pub fn sectionRange(self: *const Self, section: SectionKind) ReadRange {
            return self.envelope.ranges[@intFromEnum(section)];
        }

        pub fn verify(self: *Self) anyerror!void {
            if (self.verified) return;
            self.edge_bytes = try sourceBytes(Source, &self.source, self.envelope.ranges[0].offset, self.envelope.ranges[0].length);
            self.arc_bytes = try sourceBytes(Source, &self.source, self.envelope.ranges[1].offset, self.envelope.ranges[1].length);
            self.membership_bytes = try sourceBytes(Source, &self.source, self.envelope.ranges[2].offset, self.envelope.ranges[2].length);
            self.membership_arc_bytes = try sourceBytes(Source, &self.source, self.envelope.ranges[3].offset, self.envelope.ranges[3].length);
            // Keep `open` envelope-only for authenticated sources. Alignment
            // bytes are part of the authenticated section, but are not
            // needed until full verification starts.
            for (self.envelope.ranges, 0..) |range, index| {
                if (index + 1 == self.envelope.ranges.len) break;
                const section_end = checkedAdd(range.offset, range.length) catch return error.InvalidEncoding;
                const padded_end = align8(section_end) catch return error.InvalidEncoding;
                if (self.envelope.ranges[index + 1].offset != padded_end) return error.InvalidEncoding;
                if (padded_end > section_end) {
                    const padding = try sourceBytes(Source, &self.source, section_end, padded_end - section_end);
                    if (!std.mem.allEqual(u8, padding, 0)) return error.InvalidEncoding;
                }
            }
            self.edge_table = EdgeTable.View.open(self.edge_bytes) catch return error.InvalidEncoding;
            self.arc_table = ArcTable.View.open(self.arc_bytes) catch return error.InvalidEncoding;
            self.membership_table = MembershipTable.View.open(self.membership_bytes) catch return error.InvalidEncoding;
            self.membership_arc_table = MembershipArcTable.View.open(self.membership_arc_bytes) catch return error.InvalidEncoding;
            if (self.edge_table.len() != self.envelope.edge_count or
                self.arc_table.len() != self.envelope.arc_count or
                self.membership_table.len() != self.envelope.membership_count or
                self.membership_arc_table.len() != self.envelope.membership_arc_count)
                return error.InvalidEncoding;
            self.edge_table.verify() catch return error.InvalidEncoding;
            self.arc_table.verify() catch return error.InvalidEncoding;
            self.membership_table.verify() catch return error.InvalidEncoding;
            self.membership_arc_table.verify() catch return error.InvalidEncoding;
            try self.verifyEdges();
            try self.verifyMemberships();
            self.verified = true;
        }

        fn requireVerified(self: *const Self) Error!void {
            if (!self.verified) return error.Unverified;
        }

        fn verifyEdges(self: *const Self) Error!void {
            var previous: ?PhysicalEdge = null;
            var expected_arcs: usize = 0;
            for (0..self.envelope.edge_count) |index| {
                const claim = self.edge_table.row(index) catch return error.InvalidEncoding;
                try validExplicitMask(claim);
                const normalized = try normalizeEdge(asEdgeInput(claim));
                if (!samePhysicalFields(claim, normalized)) return error.InvalidEncoding;
                if (previous) |prior| {
                    if (physicalLess({}, claim, prior)) return error.Unsorted;
                    if (physicalEqual(prior, claim)) return error.DuplicateEdge;
                }
                previous = claim;
                const spec = schema.relations.get(claim.relation);
                expected_arcs = try checkedAdd(expected_arcs, 1);
                if (spec.symmetric and !claim.source.eql(claim.target)) expected_arcs = try checkedAdd(expected_arcs, 1);
                if (spec.inverse != null) expected_arcs = try checkedAdd(expected_arcs, 1);
            }
            if (expected_arcs != self.envelope.arc_count) return error.InvalidEncoding;

            var previous_arc: ?ArcInput = null;
            for (0..self.envelope.arc_count) |index| {
                const wire_arc = self.arc_table.row(index) catch return error.InvalidEncoding;
                if (wire_arc.direction > 1 or @as(usize, wire_arc.edge_index) >= self.envelope.edge_count)
                    return error.InvalidEncoding;
                const physical = self.edge_table.row(@as(usize, wire_arc.edge_index)) catch return error.InvalidEncoding;
                const resolved = try self.resolveArc(physical, wire_arc, @as(usize, wire_arc.edge_index));
                const candidate = ArcInput{
                    .source = resolved.source,
                    .target = resolved.target,
                    .relation = resolved.relation,
                    .edge_index = wire_arc.edge_index,
                    .direction = wire_arc.direction,
                };
                if (previous_arc) |prior| {
                    if (arcLess({}, candidate, prior)) return error.Unsorted;
                    if (std.meta.eql(candidate, prior)) return error.InvalidEncoding;
                }
                previous_arc = candidate;
            }
            // Each accepted arc maps to exactly one physical-edge direction.
            // Sorted uniqueness proves injectivity; admissibility plus equal
            // cardinality with the finite expected direction set proves that
            // no required forward, symmetric, or inverse arc is missing.
        }

        fn resolveArc(self: *const Self, physical: PhysicalEdge, arc: anytype, physical_index: usize) Error!Edge {
            _ = self;
            const spec = schema.relations.get(physical.relation);
            if (arc.direction > 1) return error.InvalidEncoding;
            if (arc.direction == 1 and spec.inverse == null and
                (!spec.symmetric or physical.source.eql(physical.target))) return error.InvalidEncoding;
            const expected_relation = if (arc.direction == 0) physical.relation else if (spec.inverse) |inverse| inverse else if (spec.symmetric) physical.relation else return error.InvalidEncoding;
            if (arc.relation != expected_relation) return error.InvalidEncoding;
            const source = if (arc.direction == 0) physical.source else physical.target;
            const target = if (arc.direction == 0) physical.target else physical.source;
            if (!arc.source.eql(source)) return error.InvalidEncoding;
            const explicit_bit: u8 = @as(u8, 1) << @as(u3, @intCast(arc.direction));
            return .{
                .relation = expected_relation,
                .source = source,
                .target = target,
                .state = physical.state,
                .certainty = physical.certainty,
                .asserted_by = physical.asserted_by,
                .explicit = (physical.explicit_mask & explicit_bit) != 0,
                .physical_index = physical_index,
            };
        }

        fn verifyMemberships(self: *const Self) Error!void {
            var previous: ?MembershipInput = null;
            for (0..self.envelope.membership_count) |index| {
                const membership = self.membership_table.row(index) catch return error.InvalidEncoding;
                try validateMembership(membership);
                if (previous) |prior| {
                    if (membershipLess({}, membership, prior)) return error.Unsorted;
                    if (std.meta.eql(prior, membership)) return error.DuplicateMembership;
                }
                previous = membership;
            }
            const expected_arcs = try checkedMul(self.envelope.membership_count, 2);
            if (expected_arcs != self.envelope.membership_arc_count) return error.InvalidEncoding;
            var previous_arc: ?MembershipArcInput = null;
            for (0..self.envelope.membership_arc_count) |index| {
                const arc = self.membership_arc_table.row(index) catch return error.InvalidEncoding;
                if (arc.direction > 1 or @as(usize, arc.membership_index) >= self.envelope.membership_count)
                    return error.InvalidEncoding;
                const membership = self.membership_table.row(@as(usize, arc.membership_index)) catch return error.InvalidEncoding;
                const expected_key = if (arc.direction == 0) membership.group else membership.member;
                if (!arc.key.eql(expected_key)) return error.InvalidEncoding;
                const current = MembershipArcInput{ .key = arc.key, .membership_index = arc.membership_index, .direction = arc.direction };
                if (previous_arc) |prior| {
                    if (membershipArcLess({}, current, prior)) return error.Unsorted;
                    if (std.meta.eql(current, prior)) return error.InvalidEncoding;
                }
                previous_arc = current;
            }
            for (0..self.envelope.membership_count) |index| {
                const membership = self.membership_table.row(index) catch return error.InvalidEncoding;
                const index32 = try castU32(index);
                try self.requireMembershipArc(membership, index32, 0);
                try self.requireMembershipArc(membership, index32, 1);
            }
        }

        fn requireMembershipArc(self: *const Self, membership: MembershipInput, index: u32, direction: u8) Error!void {
            const candidate = MembershipArcInput{ .key = if (direction == 0) membership.group else membership.member, .membership_index = index, .direction = direction };
            var lo: usize = 0;
            var hi: usize = self.envelope.membership_arc_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const current_key = self.membership_arc_table.field(mid, .key) catch return error.InvalidEncoding;
                const current_index = self.membership_arc_table.field(mid, .membership_index) catch return error.InvalidEncoding;
                const current_direction = self.membership_arc_table.field(mid, .direction) catch return error.InvalidEncoding;
                const current_wire = MembershipArcInput{ .key = current_key, .membership_index = current_index, .direction = current_direction };
                if (membershipArcLess({}, current_wire, candidate)) lo = mid + 1 else hi = mid;
            }
            if (lo >= self.envelope.membership_arc_count) return error.InvalidEncoding;
            const current = self.membership_arc_table.row(lo) catch return error.InvalidEncoding;
            if (!std.meta.eql(MembershipArcInput{ .key = current.key, .membership_index = current.membership_index, .direction = current.direction }, candidate))
                return error.InvalidEncoding;
        }

        /// Both incidence projections are sorted endpoint streams. Locate
        /// their first possible row once; their cursors discover the upper
        /// boundary while producing results. Reading a range length eagerly
        /// would repeat a dependent search that no streaming caller needs.
        fn endpointLowerBound(table_view: anytype, comptime key_field: anytype, key: Endpoint) Error!usize {
            var lo: usize = 0;
            var hi: usize = table_view.len();
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const current = table_view.field(mid, key_field) catch return error.InvalidEncoding;
                if (endpointLess(current, key)) lo = mid + 1 else hi = mid;
            }
            return lo;
        }

        pub fn edge(self: *const Self, index: usize) anyerror!Edge {
            try self.requireVerified();
            if (index >= self.envelope.edge_count) return error.OutOfRange;
            const physical = self.edge_table.row(index) catch return error.InvalidEncoding;
            return .{ .relation = physical.relation, .source = physical.source, .target = physical.target, .state = physical.state, .certainty = physical.certainty, .asserted_by = physical.asserted_by, .explicit = (physical.explicit_mask & 1) != 0, .physical_index = index };
        }

        pub fn outgoing(self: *const Self, source: Endpoint, predicate: ?RelationId) anyerror!RelationIterator {
            return self.outgoingWithMode(source, predicate, false);
        }

        fn outgoingWithMode(self: *const Self, source: Endpoint, predicate: ?RelationId, explicit_only: bool) anyerror!RelationIterator {
            try self.requireVerified();
            try validateEndpointValue(source);
            if (predicate) |relation| {
                try validateRelation(relation);
                const spec = schema.relations.get(relation);
                if (!spec.domain.isSet(@intFromEnum(source.kind))) return error.DomainMismatch;
            }
            return .{ .view = self, .index = try endpointLowerBound(&self.arc_table, .source, source), .end = self.envelope.arc_count, .source = source, .predicate = predicate, .explicit_only = explicit_only };
        }

        pub fn relations(self: *const Self, source: Endpoint, predicate: ?RelationId) anyerror!RelationIterator {
            return self.outgoing(source, predicate);
        }

        /// Enumerate only logical arcs explicitly asserted by the source.
        /// Inferred inverse/symmetric arcs remain available through
        /// `relations` and carry `Edge.explicit == false`.
        pub fn outgoingExplicit(self: *const Self, source: Endpoint, predicate: ?RelationId) anyerror!RelationIterator {
            return self.outgoingWithMode(source, predicate, true);
        }

        pub fn relationsExplicit(self: *const Self, source: Endpoint, predicate: ?RelationId) anyerror!RelationIterator {
            return self.outgoingExplicit(source, predicate);
        }

        pub fn members(self: *const Self, group: Endpoint) anyerror!MembershipIterator {
            try self.requireVerified();
            try validateEndpointValue(group);
            if (group.kind != .concept and group.kind != .interlingual) return error.InvalidMembership;
            return .{ .view = self, .index = try endpointLowerBound(&self.membership_arc_table, .key, group), .end = self.envelope.membership_arc_count, .key = group, .direction = 0 };
        }

        pub fn membersByLanguage(self: *const Self, group: Endpoint, language: LanguageId) anyerror!MembershipIterator {
            var iterator = try self.members(group);
            iterator.language = language;
            return iterator;
        }

        pub fn groups(self: *const Self, member: Endpoint) anyerror!MembershipIterator {
            try self.requireVerified();
            try validateEndpointValue(member);
            if (member.kind != .sense and member.kind != .subsense) return error.InvalidMembership;
            return .{ .view = self, .index = try endpointLowerBound(&self.membership_arc_table, .key, member), .end = self.envelope.membership_arc_count, .key = member, .direction = 1 };
        }

        pub fn translations(self: *const Self, member: Endpoint, language: ?LanguageId) anyerror!TranslationIterator {
            return .{ .view = self, .groups = try self.groups(member), .original = member, .language = language };
        }

        pub fn conceptMembers(self: *const Self, concept: Rank(.concept)) anyerror!MembershipIterator {
            return self.members(try Endpoint.fromRank(.concept, concept));
        }

        pub fn traverse(self: *const Self, relation: RelationId, start: Endpoint, queue: []Endpoint, visited: []Endpoint, budget: TraversalBudget) anyerror!TraversalFor(Source) {
            try validateRelation(relation);
            if (!schema.relations.get(relation).transitive) return error.UnsupportedTraversal;
            if (queue.len == 0 or visited.len == 0) return error.TraversalBufferTooSmall;
            try validateEndpointValue(start);
            if (!schema.relations.get(relation).domain.isSet(@intFromEnum(start.kind))) return error.DomainMismatch;
            return TraversalFor(Source).init(self, relation, start, queue, visited, budget);
        }
    };
}

pub const SliceSource = struct {
    data: []const u8,

    pub fn init(data: []const u8) SliceSource {
        return .{ .data = data };
    }

    pub fn len(self: *const SliceSource) usize {
        return self.data.len;
    }

    pub fn bytes(self: *SliceSource, offset: usize, length: usize) Error![]const u8 {
        if (offset > self.data.len or length > self.data.len - offset) return error.Truncated;
        return self.data[offset..][0..length];
    }
};

pub const View = ViewFor([]const u8);

pub fn BorrowedView(comptime Source: type) type {
    return ViewFor(Source);
}

pub const TraversalBudget = struct {
    max_results: usize = 1_000_000,
    max_expansions: usize = 4_000_000,
    max_nodes: usize = 1_000_000,
    max_depth: ?usize = null,
};

/// A traversal is parameterised by its source so authenticated/mapped views
/// retain their zero-copy source contract all the way through graph walks.
/// The caller owns both scratch slices; no hidden allocation is performed.
pub fn TraversalFor(comptime Source: type) type {
    const ViewType = ViewFor(Source);
    return struct {
        const Self = @This();

        view: *const ViewType,
        relation: RelationId,
        queue: []Endpoint,
        visited: []Endpoint,
        queue_head: usize,
        queue_tail: usize,
        visited_len: usize,
        depth: usize = 0,
        level_end: usize = 1,
        budget: TraversalBudget,
        expansions: usize = 0,
        results: usize = 0,
        current: ?ViewType.RelationIterator = null,

        fn init(view: *const ViewType, relation: RelationId, start: Endpoint, queue: []Endpoint, visited: []Endpoint, budget: TraversalBudget) Error!Self {
            if (budget.max_results == 0 or budget.max_expansions == 0 or budget.max_nodes == 0) return error.TraversalBudgetExceeded;
            queue[0] = start;
            visited[0] = start;
            return .{ .view = view, .relation = relation, .queue = queue, .visited = visited, .queue_head = 0, .queue_tail = 1, .visited_len = 1, .budget = budget };
        }

        fn seen(self: *const Self, value: Endpoint) bool {
            for (self.visited[0..self.visited_len]) |candidate| if (candidate.eql(value)) return true;
            return false;
        }

        pub fn next(self: *Self) anyerror!?Endpoint {
            while (true) {
                if (self.current == null) {
                    if (self.queue_head == self.queue_tail) return null;
                    if (self.queue_head == self.level_end) {
                        self.depth += 1;
                        self.level_end = self.queue_tail;
                    }
                    if (self.budget.max_depth) |max_depth| if (self.depth >= max_depth) return null;
                    const source = self.queue[self.queue_head];
                    self.queue_head += 1;
                    if (self.expansions == self.budget.max_expansions) return error.TraversalBudgetExceeded;
                    self.expansions += 1;
                    self.current = try self.view.outgoing(source, self.relation);
                }
                while (try self.current.?.next()) |claim| {
                    if (self.seen(claim.target)) continue;
                    if (self.results == self.budget.max_results or self.visited_len == self.budget.max_nodes)
                        return error.TraversalBudgetExceeded;
                    if (self.visited_len == self.visited.len or self.queue_tail == self.queue.len)
                        return error.TraversalBufferTooSmall;
                    self.visited[self.visited_len] = claim.target;
                    self.visited_len += 1;
                    self.queue[self.queue_tail] = claim.target;
                    self.queue_tail += 1;
                    self.results += 1;
                    return claim.target;
                }
                self.current = null;
            }
        }
    };
}

pub const Traversal = TraversalFor([]const u8);

pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    view: View,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn physicalEdgeCount(self: *const Owned) usize {
        return self.view.physicalEdgeCount();
    }

    pub fn edgeCount(self: *const Owned) usize {
        return self.view.edgeCount();
    }

    pub fn arcCount(self: *const Owned) usize {
        return self.view.arcCount();
    }

    pub fn membershipCount(self: *const Owned) usize {
        return self.view.membershipCount();
    }
};

fn makeArcs(allocator: std.mem.Allocator, claims: []const PhysicalEdge) Error![]ArcInput {
    var count: usize = 0;
    for (claims) |claim| {
        count = try checkedAdd(count, 1);
        const spec = schema.relations.get(claim.relation);
        if (spec.symmetric and !claim.source.eql(claim.target)) count = try checkedAdd(count, 1);
        if (spec.inverse != null) count = try checkedAdd(count, 1);
    }
    const arcs = allocator.alloc(ArcInput, count) catch return error.OutOfMemory;
    errdefer allocator.free(arcs);
    var at: usize = 0;
    for (claims, 0..) |claim, index| {
        const index32 = try castU32(index);
        arcs[at] = .{ .source = claim.source, .target = claim.target, .relation = claim.relation, .edge_index = index32, .direction = 0 };
        at += 1;
        const spec = schema.relations.get(claim.relation);
        if (spec.symmetric and !claim.source.eql(claim.target)) {
            arcs[at] = .{ .source = claim.target, .target = claim.source, .relation = claim.relation, .edge_index = index32, .direction = 1 };
            at += 1;
        }
        if (spec.inverse != null) {
            arcs[at] = .{ .source = claim.target, .target = claim.source, .relation = spec.inverse.?, .edge_index = index32, .direction = 1 };
            at += 1;
        }
    }
    std.sort.block(ArcInput, arcs, {}, arcLess);
    return arcs;
}

fn makeMembershipArcs(allocator: std.mem.Allocator, memberships: []const MembershipInput) Error![]MembershipArcWire {
    const count = try checkedMul(memberships.len, 2);
    const arcs = allocator.alloc(MembershipArcWire, count) catch return error.OutOfMemory;
    errdefer allocator.free(arcs);
    for (memberships, 0..) |membership, index| {
        const index32 = try castU32(index);
        arcs[index * 2] = .{ .key = membership.group, .membership_index = index32, .direction = 0 };
        arcs[index * 2 + 1] = .{ .key = membership.member, .membership_index = index32, .direction = 1 };
    }
    std.sort.block(MembershipArcInput, arcs, {}, membershipArcLess);
    return arcs;
}

/// Build a deterministic section.  Memberships are never expanded into
/// pairwise edges, and input order does not affect either the bytes or query
/// order.  Repeated identical claims collapse after canonicalisation.
fn buildGraph(allocator: std.mem.Allocator, input: BuildInput, options: Options) Error!Owned {
    if (input.edges.len > options.max_edges or input.memberships.len > options.max_memberships)
        return error.InputLimitExceeded;

    const edge_storage = allocator.alloc(PhysicalEdge, input.edges.len) catch return error.OutOfMemory;
    defer allocator.free(edge_storage);
    var edges = edge_storage;
    for (input.edges, 0..) |claim, index| edges[index] = try normalizeEdge(claim);
    std.sort.block(PhysicalEdge, edges, {}, physicalLess);
    var edge_count: usize = 0;
    for (edges) |claim| {
        if (edge_count == 0 or !physicalEqual(edges[edge_count - 1], claim)) {
            edges[edge_count] = claim;
            edge_count += 1;
        } else {
            // Canonical duplicates preserve whether either logical direction
            // was actually asserted.  Qualifiers remain part of the physical
            // key, so only equivalent claims merge here.
            edges[edge_count - 1].explicit_mask |= claim.explicit_mask;
        }
    }
    edges = edges[0..edge_count];

    const membership_storage = allocator.alloc(MembershipInput, input.memberships.len) catch return error.OutOfMemory;
    defer allocator.free(membership_storage);
    var memberships = membership_storage;
    for (input.memberships, 0..) |membership, index| {
        try validateMembership(membership);
        memberships[index] = membership;
    }
    std.sort.block(MembershipInput, memberships, {}, membershipLess);
    var membership_count: usize = 0;
    for (memberships) |membership| {
        if (membership_count == 0 or !std.meta.eql(memberships[membership_count - 1], membership)) {
            memberships[membership_count] = membership;
            membership_count += 1;
        }
    }
    memberships = memberships[0..membership_count];

    const arcs = try makeArcs(allocator, edges);
    defer allocator.free(arcs);
    if (arcs.len > std.math.maxInt(u32) or arcs.len > 32 * 1024 * 1024) return error.InputLimitExceeded;
    const membership_arcs = try makeMembershipArcs(allocator, memberships);
    defer allocator.free(membership_arcs);
    if (membership_arcs.len > std.math.maxInt(u32) or membership_arcs.len > 32 * 1024 * 1024) return error.InputLimitExceeded;

    const arc_rows = allocator.alloc(ArcWire, arcs.len) catch return error.OutOfMemory;
    defer allocator.free(arc_rows);
    for (arcs, 0..) |arc, index| arc_rows[index] = .{
        .source = arc.source,
        .edge_index = arc.edge_index,
        .relation = arc.relation,
        .direction = arc.direction,
    };

    var edge_owned = EdgeTable.build(allocator, edges) catch |err| return mapTableBuildError(err);
    defer edge_owned.deinit();
    var arc_owned = ArcTable.build(allocator, arc_rows) catch |err| return mapTableBuildError(err);
    defer arc_owned.deinit();
    var membership_owned = MembershipTable.build(allocator, memberships) catch |err| return mapTableBuildError(err);
    defer membership_owned.deinit();
    var membership_arc_owned = MembershipArcTable.build(allocator, membership_arcs) catch |err| return mapTableBuildError(err);
    defer membership_arc_owned.deinit();

    const edge_len = edge_owned.bytes.len;
    const arc_len = arc_owned.bytes.len;
    const membership_len = membership_owned.bytes.len;
    const membership_arc_len = membership_arc_owned.bytes.len;
    var total = header_size;
    total = try align8(total);
    total = try checkedAdd(total, edge_len);
    total = try align8(total);
    total = try checkedAdd(total, arc_len);
    total = try align8(total);
    total = try checkedAdd(total, membership_len);
    total = try align8(total);
    total = try checkedAdd(total, membership_arc_len);

    const bytes = allocator.alloc(u8, total) catch return error.OutOfMemory;
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    var ranges: [4]ReadRange = undefined;
    var cursor = try align8(header_size);
    const lengths = [_]usize{ edge_len, arc_len, membership_len, membership_arc_len };
    for (&ranges, 0..) |*range, index| {
        range.* = .{ .offset = cursor, .length = lengths[index] };
        const section_end = try checkedAdd(cursor, lengths[index]);
        cursor = if (index + 1 < ranges.len) try align8(section_end) else section_end;
    }
    if (cursor != bytes.len) return error.InvalidEncoding;

    writeInt(u16, bytes, 4, version);
    writeInt(u16, bytes, 6, header_size);
    writeInt(u32, bytes, 8, 0);
    writeInt(u32, bytes, 12, 0);
    writeInt(u64, bytes, 16, @intCast(edges.len));
    writeInt(u64, bytes, 24, @intCast(arcs.len));
    writeInt(u64, bytes, 32, @intCast(memberships.len));
    writeInt(u64, bytes, 40, @intCast(membership_arcs.len));
    for (ranges, 0..) |range, index| {
        writeInt(u64, bytes, 48 + index * 16, @intCast(range.offset));
        writeInt(u64, bytes, 56 + index * 16, @intCast(range.length));
    }
    @memcpy(bytes[0..4], magic);
    @memcpy(bytes[ranges[0].offset..][0..edge_len], edge_owned.bytes);
    @memcpy(bytes[ranges[1].offset..][0..arc_len], arc_owned.bytes);
    @memcpy(bytes[ranges[2].offset..][0..membership_len], membership_owned.bytes);
    @memcpy(bytes[ranges[3].offset..][0..membership_arc_len], membership_arc_owned.bytes);

    var view = View.open(bytes) catch |err| return @errorCast(err);
    view.verify() catch |err| return @errorCast(err);
    return .{ .allocator = allocator, .bytes = bytes, .view = view };
}

pub fn build(allocator: std.mem.Allocator, input: BuildInput, options: Options) Error!Owned {
    return buildGraph(allocator, input, options);
}

pub fn buildRelations(allocator: std.mem.Allocator, edges: []const EdgeInput, options: Options) Error!Owned {
    return build(allocator, .{ .edges = edges }, options);
}

pub const Builder = struct {
    allocator: std.mem.Allocator,
    options: Options,
    edges: std.ArrayList(EdgeInput) = .empty,
    memberships: std.ArrayList(MembershipInput) = .empty,
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: Options) Builder {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn deinit(self: *Builder) void {
        self.edges.deinit(self.allocator);
        self.memberships.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *Builder, claim: EdgeInput) Error!void {
        if (self.finished) return error.InvalidEncoding;
        if (self.edges.items.len == self.options.max_edges) return error.InputLimitExceeded;
        try validateEdge(claim);
        self.edges.append(self.allocator, claim) catch return error.OutOfMemory;
    }

    pub fn addEdge(self: *Builder, claim: EdgeInput) Error!void {
        return self.add(claim);
    }

    pub fn addTyped(self: *Builder, comptime relation: RelationId, comptime source_kind: Kind, comptime target_kind: Kind, source: Rank(source_kind), target: Rank(target_kind), assertion: AssertionOptions) Error!void {
        return self.add(try typedEdge(relation, source_kind, target_kind, source, target, assertion));
    }

    pub fn addMembership(self: *Builder, membership: MembershipInput) Error!void {
        if (self.finished) return error.InvalidEncoding;
        if (self.memberships.items.len == self.options.max_memberships) return error.InputLimitExceeded;
        try validateMembership(membership);
        self.memberships.append(self.allocator, membership) catch return error.OutOfMemory;
    }

    pub fn finish(self: *Builder) Error!Owned {
        if (self.finished) return error.InvalidEncoding;
        self.finished = true;
        return buildGraph(self.allocator, .{ .edges = self.edges.items, .memberships = self.memberships.items }, self.options);
    }

    pub fn build(self: *Builder) Error!Owned {
        return self.finish();
    }
};

/// The relation and endpoint kinds are comptime parameters, so an illegal
/// domain/range is a compile error at the typed call site.  Rank.none remains
/// a checked runtime error rather than a representable stored endpoint.
pub fn typedEdge(comptime relation: RelationId, comptime source_kind: Kind, comptime target_kind: Kind, source: Rank(source_kind), target: Rank(target_kind), assertion: AssertionOptions) Error!EdgeInput {
    const spec = comptime schema.relations.get(relation);
    comptime {
        if (!kindAllowed(spec.domain, source_kind)) @compileError("relation source kind is outside its declared domain");
        if (!kindAllowed(spec.range, target_kind)) @compileError("relation target kind is outside its declared range");
    }
    return .{
        .relation = relation,
        .source = try Endpoint.fromRank(source_kind, source),
        .target = try Endpoint.fromRank(target_kind, target),
        .state = assertion.state,
        .certainty = assertion.certainty,
        .asserted_by = assertion.asserted_by,
    };
}

pub fn edge(comptime relation: RelationId, comptime source_kind: Kind, comptime target_kind: Kind, source: Rank(source_kind), target: Rank(target_kind), assertion: AssertionOptions) Error!EdgeInput {
    return typedEdge(relation, source_kind, target_kind, source, target, assertion);
}

pub fn typedMembership(comptime group_kind: Kind, comptime member_kind: Kind, group: Rank(group_kind), member: Rank(member_kind), language: LanguageId, confidence: Certainty, asserted_by: ?Rank(.source)) Error!MembershipInput {
    if (group_kind != .concept and group_kind != .interlingual) @compileError("membership group must be concept or interlingual");
    if (member_kind != .sense and member_kind != .subsense) @compileError("membership member must be sense or subsense");
    return .{
        .group = try Endpoint.fromRank(group_kind, group),
        .member = try Endpoint.fromRank(member_kind, member),
        .language = language,
        .confidence = confidence,
        .asserted_by = asserted_by,
    };
}

test "symmetric and inverse claims share physical records" {
    const sense_a = try Rank(.sense).fromIndex(1);
    const sense_b = try Rank(.sense).fromIndex(2);
    const edges = [_]EdgeInput{
        try typedEdge(.see_also, .sense, .sense, sense_a, sense_b, .{}),
        try typedEdge(.see_also, .sense, .sense, sense_b, sense_a, .{}),
        try typedEdge(.hypernym, .sense, .sense, sense_a, sense_b, .{}),
        try typedEdge(.hyponym, .sense, .sense, sense_b, sense_a, .{}),
        try typedEdge(.near_translation, .sense, .sense, sense_a, sense_b, .{ .state = .disputed, .certainty = .possible }),
    };
    var owned = try build(std.testing.allocator, .{ .edges = &edges }, .{});
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 3), owned.view.physicalEdgeCount());
    try std.testing.expectEqual(@as(usize, 5), owned.view.arcCount());

    var iterator = try owned.view.relations(try Endpoint.fromRank(.sense, sense_a), null);
    var count: usize = 0;
    var saw_hypernym = false;
    var saw_symmetric = false;
    while (try iterator.next()) |claim| {
        count += 1;
        saw_hypernym = saw_hypernym or claim.relation == .hypernym;
        saw_symmetric = saw_symmetric or claim.relation == .see_also;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expect(saw_hypernym);
    try std.testing.expect(saw_symmetric);
}

test "concept memberships stay linear and translations are borrowed" {
    const group = try Rank(.concept).fromIndex(0);
    const a = try Rank(.sense).fromIndex(0);
    const b = try Rank(.sense).fromIndex(1);
    const c = try Rank(.sense).fromIndex(2);
    const memberships = [_]MembershipInput{
        try typedMembership(.concept, .sense, group, a, @enumFromInt(1), .certain, null),
        try typedMembership(.concept, .sense, group, b, @enumFromInt(2), .certain, null),
        try typedMembership(.concept, .sense, group, c, @enumFromInt(2), .probable, null),
    };
    var owned = try build(std.testing.allocator, .{ .memberships = &memberships }, .{});
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 3), owned.view.membershipCount());
    try std.testing.expectEqual(@as(usize, 6), owned.view.membershipArcCount());
    var members = try owned.view.conceptMembers(group);
    var count: usize = 0;
    while (try members.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 3), count);
    var translated = try owned.view.translations(try Endpoint.fromRank(.sense, b), @enumFromInt(2));
    try std.testing.expect((try translated.next()) != null);
    try std.testing.expect((try translated.next()) == null);
}

test "open is cheap and verify rejects hostile records" {
    const a = try Rank(.sense).fromIndex(0);
    const b = try Rank(.sense).fromIndex(1);
    const edge_input = [_]EdgeInput{try typedEdge(.near_translation, .sense, .sense, a, b, .{ .state = .disputed })};
    var owned = try build(std.testing.allocator, .{ .edges = &edge_input }, .{});
    defer owned.deinit();
    var opened = try View.open(owned.bytes);
    try std.testing.expect(!opened.isVerified());
    try std.testing.expectError(error.Unverified, opened.edge(0));
    try opened.verify();
    try std.testing.expect(opened.isVerified());
    var named = try ViewFor(SliceSource).openAndVerify(SliceSource.init(owned.bytes));
    try std.testing.expectEqual(@as(usize, 1), named.edgeCount());

    var bad = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad);
    bad[0] = 'X';
    try std.testing.expectError(error.BadMagic, View.open(bad));
}

test "transitive traversal is cycle safe and budgeted" {
    const a = try Rank(.sense).fromIndex(0);
    const b = try Rank(.sense).fromIndex(1);
    const c = try Rank(.sense).fromIndex(2);
    const edges = [_]EdgeInput{
        try typedEdge(.entails, .sense, .sense, a, b, .{}),
        try typedEdge(.entails, .sense, .sense, b, c, .{}),
        try typedEdge(.entails, .sense, .sense, c, a, .{}),
    };
    var owned = try build(std.testing.allocator, .{ .edges = &edges }, .{});
    defer owned.deinit();
    var queue: [8]Endpoint = undefined;
    var visited: [8]Endpoint = undefined;
    var traversal = try owned.view.traverse(.entails, try Endpoint.fromRank(.sense, a), &queue, &visited, .{ .max_results = 3, .max_expansions = 8 });
    var count: usize = 0;
    while (try traversal.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "borrowed sources retain a zero-copy traversal view" {
    const a = try Rank(.sense).fromIndex(0);
    const b = try Rank(.sense).fromIndex(1);
    const claims = [_]EdgeInput{try typedEdge(.entails, .sense, .sense, a, b, .{})};
    var owned = try build(std.testing.allocator, .{ .edges = &claims }, .{});
    defer owned.deinit();

    const Borrowed = BorrowedView(SliceSource);
    var borrowed = try Borrowed.open(SliceSource.init(owned.bytes));
    try borrowed.verify();
    var queue: [4]Endpoint = undefined;
    var visited: [4]Endpoint = undefined;
    var walk = try borrowed.traverse(.entails, try Endpoint.fromRank(.sense, a), &queue, &visited, .{});
    try std.testing.expect((try walk.next()) != null);
    try std.testing.expect((try walk.next()) == null);
}

test "inverse arcs expose the declared predicate in each direction" {
    const form = try Rank(.form).fromIndex(3);
    const entry = try Rank(.entry).fromIndex(4);
    const claim = [_]EdgeInput{try typedEdge(.form_of, .form, .entry, form, entry, .{})};
    var owned = try build(std.testing.allocator, .{ .edges = &claim }, .{});
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 1), owned.view.physicalEdgeCount());
    try std.testing.expectEqual(@as(usize, 2), owned.view.arcCount());

    var forms = try owned.view.relations(try Endpoint.fromRank(.form, form), .form_of);
    const form_arc = (try forms.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(RelationId.form_of, form_arc.relation);
    try std.testing.expectEqual(Kind.entry, form_arc.target.kind);
    try std.testing.expect((try forms.next()) == null);

    var entries = try owned.view.relations(try Endpoint.fromRank(.entry, entry), .has_form);
    const entry_arc = (try entries.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(RelationId.has_form, entry_arc.relation);
    try std.testing.expectEqual(Kind.form, entry_arc.target.kind);
    try std.testing.expect((try entries.next()) == null);
}

test "asserted direction masks preserve inverse and symmetric provenance" {
    const sense_a = try Rank(.sense).fromIndex(1);
    const sense_b = try Rank(.sense).fromIndex(2);
    const form = try Rank(.form).fromIndex(3);
    const entry = try Rank(.entry).fromIndex(4);
    const form_endpoint = try Endpoint.fromRank(.form, form);
    const entry_endpoint = try Endpoint.fromRank(.entry, entry);
    const sense_b_endpoint = try Endpoint.fromRank(.sense, sense_b);

    // A lone canonical inverse claim exposes the reverse predicate as an
    // inferred arc, while explicit-only enumeration hides it.
    const lone_inverse = [_]EdgeInput{try typedEdge(.form_of, .form, .entry, form, entry, .{})};
    var lone_owned = try build(std.testing.allocator, .{ .edges = &lone_inverse }, .{});
    defer lone_owned.deinit();
    var forward = try lone_owned.view.relations(form_endpoint, .form_of);
    const forward_edge = (try forward.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expect(forward_edge.explicit);
    try std.testing.expect((try forward.next()) == null);
    var inferred_reverse = try lone_owned.view.relations(entry_endpoint, .has_form);
    const reverse_edge = (try inferred_reverse.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!reverse_edge.explicit);
    try std.testing.expect((try inferred_reverse.next()) == null);
    var explicit_reverse = try lone_owned.view.relationsExplicit(entry_endpoint, .has_form);
    try std.testing.expect((try explicit_reverse.next()) == null);

    // Asserting the inverse claim too merges into one physical record, but
    // both logical arcs now round-trip as explicit.
    const inverse_pair = [_]EdgeInput{
        try typedEdge(.form_of, .form, .entry, form, entry, .{}),
        try typedEdge(.has_form, .entry, .form, entry, form, .{}),
    };
    var pair_owned = try build(std.testing.allocator, .{ .edges = &inverse_pair }, .{});
    defer pair_owned.deinit();
    try std.testing.expectEqual(@as(usize, 1), pair_owned.view.physicalEdgeCount());
    var pair_forward = try pair_owned.view.relationsExplicit(form_endpoint, .form_of);
    try std.testing.expect((try pair_forward.next()).?.explicit);
    try std.testing.expect((try pair_forward.next()) == null);
    var pair_reverse = try pair_owned.view.relationsExplicit(entry_endpoint, .has_form);
    try std.testing.expect((try pair_reverse.next()).?.explicit);
    try std.testing.expect((try pair_reverse.next()) == null);

    // Symmetric claims use the same two-bit mask, including the inferred
    // reverse orientation when the source asserted only one ordering.
    const lone_symmetric = [_]EdgeInput{try typedEdge(.see_also, .sense, .sense, sense_a, sense_b, .{})};
    var symmetric_owned = try build(std.testing.allocator, .{ .edges = &lone_symmetric }, .{});
    defer symmetric_owned.deinit();
    var symmetric_inferred = try symmetric_owned.view.relations(sense_b_endpoint, .see_also);
    try std.testing.expect(!(try symmetric_inferred.next()).?.explicit);
    var symmetric_explicit = try symmetric_owned.view.relationsExplicit(sense_b_endpoint, .see_also);
    try std.testing.expect((try symmetric_explicit.next()) == null);

    const symmetric_pair = [_]EdgeInput{
        try typedEdge(.see_also, .sense, .sense, sense_a, sense_b, .{}),
        try typedEdge(.see_also, .sense, .sense, sense_b, sense_a, .{}),
    };
    var symmetric_pair_owned = try build(std.testing.allocator, .{ .edges = &symmetric_pair }, .{});
    defer symmetric_pair_owned.deinit();
    try std.testing.expectEqual(@as(usize, 1), symmetric_pair_owned.view.physicalEdgeCount());
    var symmetric_pair_explicit = try symmetric_pair_owned.view.relationsExplicit(sense_b_endpoint, .see_also);
    try std.testing.expect((try symmetric_pair_explicit.next()).?.explicit);
    try std.testing.expect((try symmetric_pair_explicit.next()) == null);

    // The asserted-direction mask is now one generated scalar column.  The
    // two explicit-only queries above are the semantic check; no fixed byte
    // offset is part of the v3 contract.
    const malformed_mask = try std.testing.allocator.dupe(u8, pair_owned.bytes);
    defer std.testing.allocator.free(malformed_mask);
    const edge_range = pair_owned.view.sectionRange(.edges);
    malformed_mask[edge_range.offset + table.header_size + 4] = 0xff;
    var malformed_view = try View.open(malformed_mask);
    try std.testing.expectError(error.InvalidEncoding, malformed_view.verify());
    std.mem.writeInt(u16, malformed_mask[4..6], 1, .little);
    try std.testing.expectError(error.UnsupportedVersion, View.open(malformed_mask));
}

test "canonical bytes, qualifiers, self loops, and inverse domains are stable" {
    const sense_a = try Rank(.sense).fromIndex(1);
    const sense_b = try Rank(.sense).fromIndex(2);
    const form = try Rank(.form).fromIndex(3);
    const entry = try Rank(.entry).fromIndex(4);
    const claims = [_]EdgeInput{
        try typedEdge(.see_also, .sense, .sense, sense_b, sense_a, .{}),
        try typedEdge(.see_also, .sense, .sense, sense_a, sense_b, .{}),
        try typedEdge(.near_translation, .sense, .sense, sense_a, sense_b, .{ .state = .disputed, .certainty = .possible }),
        try typedEdge(.near_translation, .sense, .sense, sense_a, sense_b, .{ .state = .asserted, .certainty = .possible }),
        try typedEdge(.form_of, .form, .entry, form, entry, .{}),
    };
    var forward = try build(std.testing.allocator, .{ .edges = &claims }, .{});
    defer forward.deinit();
    var reverse = claims;
    std.mem.reverse(EdgeInput, &reverse);
    var permuted = try build(std.testing.allocator, .{ .edges = &reverse }, .{});
    defer permuted.deinit();
    try std.testing.expect(std.mem.eql(u8, forward.bytes, permuted.bytes));
    try std.testing.expectEqual(@as(usize, 4), forward.view.physicalEdgeCount());
    try std.testing.expectEqual(@as(usize, 6), forward.view.arcCount());
    var near = try forward.view.relations(try Endpoint.fromRank(.sense, sense_a), .near_translation);
    var saw_asserted = false;
    var saw_disputed = false;
    while (try near.next()) |claim| {
        saw_asserted = saw_asserted or claim.state == .asserted;
        saw_disputed = saw_disputed or claim.state == .disputed;
    }
    try std.testing.expect(saw_asserted and saw_disputed);
    try std.testing.expectEqual(RelationId.form_of, physicalRelation(.has_form));
    try std.testing.expect(isTransitive(.hypernym));
    try std.testing.expect(isSymmetric(.see_also));

    const self_loop = [_]EdgeInput{try typedEdge(.see_also, .sense, .sense, sense_a, sense_a, .{})};
    var loop = try build(std.testing.allocator, .{ .edges = &self_loop }, .{});
    defer loop.deinit();
    try std.testing.expectEqual(@as(usize, 1), loop.view.arcCount());
    var neighbors = try loop.view.relations(try Endpoint.fromRank(.sense, sense_a), null);
    try std.testing.expect((try neighbors.next()) != null);
    try std.testing.expect((try neighbors.next()) == null);

    const invalid = EdgeInput{ .relation = .form_of, .source = .{ .kind = .entry, .rank = @enumFromInt(1) }, .target = .{ .kind = .form, .rank = @enumFromInt(2) } };
    try std.testing.expectError(error.DomainMismatch, build(std.testing.allocator, .{ .edges = &[_]EdgeInput{invalid} }, .{}));
}

test "hostile adjacency references fail verification and traversal budgets are explicit" {
    const a = try Rank(.sense).fromIndex(0);
    const b = try Rank(.sense).fromIndex(1);
    const claims = [_]EdgeInput{try typedEdge(.entails, .sense, .sense, a, b, .{})};
    var owned = try build(std.testing.allocator, .{ .edges = &claims }, .{});
    defer owned.deinit();

    const bad_arc = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_arc);
    const arc_range = owned.view.sectionRange(.arcs);
    bad_arc[arc_range.offset + 4] = 0xff; // generated table version
    var bad_view = try View.open(bad_arc);
    try std.testing.expectError(error.InvalidEncoding, bad_view.verify());

    var queue: [4]Endpoint = undefined;
    var visited: [4]Endpoint = undefined;
    var depth_limited = try owned.view.traverse(.entails, try Endpoint.fromRank(.sense, a), &queue, &visited, .{ .max_results = 4, .max_expansions = 4, .max_nodes = 4, .max_depth = 1 });
    try std.testing.expect((try depth_limited.next()) != null);
    try std.testing.expect((try depth_limited.next()) == null);

    try std.testing.expectError(error.TraversalBufferTooSmall, owned.view.traverse(.entails, try Endpoint.fromRank(.sense, a), queue[0..0], visited[0..0], .{}));
}

test "reserved optional-source bytes and membership order are authenticated" {
    const a = try Rank(.sense).fromIndex(0);
    const b = try Rank(.sense).fromIndex(1);
    const edge_input = [_]EdgeInput{try typedEdge(.near_translation, .sense, .sense, a, b, .{ .state = .disputed })};
    var edge_owned = try build(std.testing.allocator, .{ .edges = &edge_input }, .{});
    defer edge_owned.deinit();

    const bad_edge = try std.testing.allocator.dupe(u8, edge_owned.bytes);
    defer std.testing.allocator.free(bad_edge);
    const edge_range = edge_owned.view.sectionRange(.edges);
    bad_edge[edge_range.offset + 4] = 0xff;
    var edge_view = try View.open(bad_edge);
    try std.testing.expectError(error.InvalidEncoding, edge_view.verify());

    const group = try Rank(.concept).fromIndex(0);
    const memberships = [_]MembershipInput{
        try typedMembership(.concept, .sense, group, a, @enumFromInt(1), .certain, null),
        try typedMembership(.concept, .sense, group, b, @enumFromInt(1), .certain, null),
    };
    var membership_owned = try build(std.testing.allocator, .{ .memberships = &memberships }, .{});
    defer membership_owned.deinit();

    const bad_membership = try std.testing.allocator.dupe(u8, membership_owned.bytes);
    defer std.testing.allocator.free(bad_membership);
    const membership_range = membership_owned.view.sectionRange(.memberships);
    bad_membership[membership_range.offset + 4] = 0xff;
    var membership_view = try View.open(bad_membership);
    try std.testing.expectError(error.InvalidEncoding, membership_view.verify());

    const unsorted = try std.testing.allocator.dupe(u8, membership_owned.bytes);
    defer std.testing.allocator.free(unsorted);
    var swapped = memberships;
    std.mem.swap(MembershipInput, &swapped[0], &swapped[1]);
    var swapped_table = try table.Table(MembershipInput).build(std.testing.allocator, &swapped);
    defer swapped_table.deinit();
    try std.testing.expectEqual(membership_range.length, swapped_table.bytes.len);
    @memcpy(unsorted[membership_range.offset..][0..membership_range.length], swapped_table.bytes);
    var unsorted_view = try View.open(unsorted);
    try std.testing.expectError(error.Unsorted, unsorted_view.verify());
}

test "relation encoding propagates allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildWithFailingAllocator, .{});
}

fn buildWithFailingAllocator(allocator: std.mem.Allocator) !void {
    const a = try Rank(.sense).fromIndex(0);
    const b = try Rank(.sense).fromIndex(1);
    const claims = [_]EdgeInput{try typedEdge(.near_translation, .sense, .sense, a, b, .{})};
    var owned = try build(allocator, .{ .edges = &claims }, .{});
    owned.deinit();
}

fn buildWithFailingBuilder(allocator: std.mem.Allocator) !void {
    const a = try Rank(.sense).fromIndex(0);
    const b = try Rank(.sense).fromIndex(1);
    var builder = Builder.init(allocator, .{});
    defer builder.deinit();
    try builder.add(try typedEdge(.near_translation, .sense, .sense, a, b, .{}));
    var owned = try builder.finish();
    owned.deinit();
}

test "relation builder releases buffered claims on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildWithFailingBuilder, .{});
}
