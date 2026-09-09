//! The compile-time contract for LEX4.
//!
//! Kinds are real wire domains; there is deliberately no `.any` sentinel.
//! Generic code uses `KindSet`, and durable object identity uses `Rank(kind)`.

const std = @import("std");

pub const Layer = enum(u3) {
    orthographic,
    lexical,
    semantic,
    conceptual,
    provenance,
};

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

pub const kind_count = @typeInfo(Kind).@"enum".fields.len;
pub const KindSet = std.bit_set.IntegerBitSet(kind_count);

/// Durable rank owners are explicit. A forest count is authoritative only for
/// forest-owned kinds; conceptual indexes and host metadata remain separate
/// domains even when their ranks appear in a shared reference.
pub const DomainOwner = enum { forest, concept, interlingual, external };

pub fn domainOwner(kind: Kind) DomainOwner {
    return switch (kind) {
        .concept => .concept,
        .interlingual => .interlingual,
        .source => .external,
        else => .forest,
    };
}

pub fn kinds(comptime members: []const Kind) KindSet {
    var result = KindSet.initEmpty();
    inline for (members) |kind| result.set(@intFromEnum(kind));
    return result;
}

pub const Node = enum(u32) { none = std.math.maxInt(u32), _ };

/// A rank's kind is part of its type, so a definition rank cannot silently be
/// passed where an entry rank is expected. `none` is reserved and never stored.
pub fn Rank(comptime kind: Kind) type {
    return enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub const domain = kind;

        pub inline fn index(self: @This()) ?usize {
            return if (self == .none) null else @intFromEnum(self);
        }

        pub inline fn fromIndex(index_: usize) error{RankOverflow}!@This() {
            if (index_ >= std.math.maxInt(u32)) return error.RankOverflow;
            return @enumFromInt(@as(u32, @intCast(index_)));
        }
    };
}

/// Runtime counterpart of `Rank(kind)` for generic relation/rich-content
/// records. The sentinel is rejected at construction and verification.
pub const Reference = struct {
    kind: Kind,
    rank: u32,

    pub fn fromRank(comptime kind: Kind, value: Rank(kind)) error{RankOverflow}!Reference {
        return .{ .kind = kind, .rank = std.math.cast(u32, value.index() orelse return error.RankOverflow) orelse return error.RankOverflow };
    }

    pub fn validate(self: Reference) error{RankOverflow}!void {
        if (self.rank == std.math.maxInt(u32)) return error.RankOverflow;
    }
};

pub const ColumnId = enum(u8) {
    written,
    language,
    pos,
    features,
    text,
    concept,
    membership_confidence,
    role,
    span,
    notation,
    state,
    certainty,
    temporal,
    source,
    target,
    external_id,
};

pub const KindSpec = struct {
    layer: Layer,
    parents: KindSet,
    columns: []const ColumnId = &.{},
    text: bool = false,
    searchable: bool = false,
    root: bool = false,
};

const none = kinds(&.{});
/// This single declaration is the source of truth for parent legality,
/// searchable domains, prose domains, and column domains.
pub const kind_specs = std.enums.EnumArray(Kind, KindSpec).init(.{
    .form = .{ .layer = .orthographic, .parents = kinds(&.{ .entry, .lexeme }), .columns = &.{ .written, .language, .features }, .searchable = true },
    .variant = .{ .layer = .orthographic, .parents = kinds(&.{.entry}), .columns = &.{ .written, .language, .features }, .searchable = true },
    .inflection = .{ .layer = .orthographic, .parents = kinds(&.{.entry}), .columns = &.{ .written, .language, .features }, .searchable = true },
    .part = .{ .layer = .orthographic, .parents = kinds(&.{ .form, .variant, .inflection, .part, .analysis }), .columns = &.{ .written, .features, .role, .span, .notation }, .searchable = true },
    .pronunciation = .{ .layer = .orthographic, .parents = kinds(&.{ .form, .variant, .inflection, .entry }), .columns = &.{ .written, .notation } },
    .analysis = .{ .layer = .orthographic, .parents = kinds(&.{ .form, .variant, .inflection }), .columns = &.{.features} },

    .entry = .{ .layer = .lexical, .parents = none, .columns = &.{ .written, .language, .pos, .external_id }, .searchable = true, .root = true },
    .lexeme = .{ .layer = .lexical, .parents = kinds(&.{.entry}), .columns = &.{ .written, .language, .pos, .features, .external_id }, .searchable = true },
    .homograph = .{ .layer = .lexical, .parents = kinds(&.{.entry}), .columns = &.{.external_id} },

    .sense = .{ .layer = .semantic, .parents = kinds(&.{ .entry, .lexeme, .homograph, .sense }), .columns = &.{ .language, .pos, .concept, .membership_confidence, .external_id } },
    .subsense = .{ .layer = .semantic, .parents = kinds(&.{ .sense, .subsense }), .columns = &.{ .language, .pos, .concept, .membership_confidence, .external_id } },
    .definition = .{ .layer = .semantic, .parents = kinds(&.{ .sense, .subsense }), .columns = &.{ .text, .language }, .text = true },
    .gloss = .{ .layer = .semantic, .parents = kinds(&.{ .sense, .subsense }), .columns = &.{ .text, .language }, .text = true },
    .example = .{ .layer = .semantic, .parents = kinds(&.{ .sense, .subsense }), .columns = &.{ .text, .language }, .text = true },
    .usage = .{ .layer = .semantic, .parents = kinds(&.{ .sense, .subsense }), .columns = &.{ .text, .language }, .text = true },
    .citation = .{ .layer = .semantic, .parents = kinds(&.{ .sense, .subsense, .example }), .columns = &.{ .text, .source }, .text = true },

    .concept = .{ .layer = .conceptual, .parents = none, .columns = &.{ .language, .external_id }, .root = true },
    .interlingual = .{ .layer = .conceptual, .parents = none, .columns = &.{.external_id}, .root = true },

    .source = .{ .layer = .provenance, .parents = none, .columns = &.{ .written, .external_id }, .root = true },
    .assertion = .{ .layer = .provenance, .parents = kinds(&.{ .entry, .lexeme, .sense, .subsense }), .columns = &.{ .state, .certainty, .temporal, .source } },
    .participant = .{ .layer = .provenance, .parents = kinds(&.{.assertion}), .columns = &.{ .role, .target } },
    .evidence = .{ .layer = .provenance, .parents = kinds(&.{.assertion}), .columns = &.{ .text, .source, .certainty }, .text = true },
    .annotation = .{ .layer = .provenance, .parents = kinds(&.{ .entry, .lexeme, .sense, .subsense, .concept, .interlingual, .source, .assertion, .evidence }), .columns = &.{ .text, .source }, .text = true },
});

pub fn spec(kind: Kind) KindSpec {
    return kind_specs.get(kind);
}

pub fn legalParent(parent: ?Kind, child: Kind) bool {
    const child_spec = spec(child);
    return if (parent) |owner|
        child_spec.parents.isSet(@intFromEnum(owner))
    else
        child_spec.root;
}

pub fn children(parent: Kind) KindSet {
    @setEvalBranchQuota(1_000_000);
    var result = KindSet.initEmpty();
    inline for (@typeInfo(Kind).@"enum".fields) |field| {
        const child: Kind = @enumFromInt(field.value);
        if (legalParent(parent, child)) result.set(field.value);
    }
    return result;
}

/// Return whether at least one non-empty legal child path reaches `to` from
/// `from`. Parent domains are the sole authority; reverse child sets are
/// derived by `children`. A visited bitset makes cycles in
/// recursive kinds (for example nested subsenses) finite at comptime.
fn reachable(comptime from: Kind, comptime to: Kind, comptime blocked: ?Kind) bool {
    @setEvalBranchQuota(100_000);
    if (blocked) |excluded| if (from == excluded) return false;
    comptime var frontier = [_]bool{false} ** kind_count;
    frontier[@intFromEnum(from)] = true;
    comptime var visited = [_]bool{false} ** kind_count;
    comptime var active = true;

    inline for (0..kind_count) |_| {
        if (!active) break;
        comptime var next = [_]bool{false} ** kind_count;
        active = false;
        inline for (@typeInfo(Kind).@"enum".fields) |parent_field| {
            if (!frontier[parent_field.value]) continue;
            const parent: Kind = @enumFromInt(parent_field.value);
            inline for (@typeInfo(Kind).@"enum".fields) |child_field| {
                const child: Kind = @enumFromInt(child_field.value);
                if (comptime !legalParent(parent, child)) continue;
                if (blocked) |excluded| {
                    if (parent == excluded or child == excluded) continue;
                }
                if (child == to) return true;
                if (!visited[child_field.value]) {
                    next[child_field.value] = true;
                    active = true;
                }
            }
        }
        inline for (@typeInfo(Kind).@"enum".fields) |field| {
            if (frontier[field.value]) visited[field.value] = true;
        }
        frontier = next;
    }
    return false;
}

/// True when `to` is a strict legal descendant of `from`.
pub fn canDescend(comptime from: Kind, comptime to: Kind) bool {
    return reachable(from, to, null);
}

/// True when every non-empty legal path from `from` to `to` contains
/// `via` internally.  No path means no dominance; excluding the endpoints
/// keeps this a strict intermediate-node relation even for recursive kinds.
pub fn dominates(comptime from: Kind, comptime via: Kind, comptime to: Kind) bool {
    if (from == via or via == to) return false;
    if (!reachable(from, to, null)) return false;
    return !reachable(from, to, via);
}

pub fn columnDomain(comptime column: ColumnId) KindSet {
    var result = KindSet.initEmpty();
    inline for (@typeInfo(Kind).@"enum".fields) |field| {
        inline for (kind_specs.values[field.value].columns) |candidate| {
            if (candidate == column) result.set(field.value);
        }
    }
    return result;
}

pub const LanguageTag = packed struct(u32) {
    language: u15,
    script: u7 = 0,
    region: u9 = 0,
    has_variant: bool = false,
};

pub const Pos = enum(u5) {
    adj,
    adp,
    adv,
    aux,
    cconj,
    det,
    intj,
    noun,
    num,
    part,
    pron,
    propn,
    punct,
    sconj,
    sym,
    verb,
    x,
    extension,
};

pub const AssertionState = enum(u2) { asserted, inferred, retracted, disputed };
pub const Certainty = enum(u2) { unknown, possible, probable, certain };
pub const Notation = enum(u3) { orthographic, ipa, xsampa, romanized, extension };

pub const RelationId = enum(u8) {
    synonym,
    antonym,
    hypernym,
    hyponym,
    holonym,
    meronym,
    troponym,
    entails,
    similar_to,
    also_see,
    derived_from,
    variant_of,
    form_of,
    has_form,
    sense_of,
    realizes,
    near_translation,
    etymon_of,
    cognate_of,
    see_also,
};

pub const RelationSpec = struct {
    name: []const u8,
    domain: KindSet,
    range: KindSet,
    symmetric: bool = false,
    inverse: ?RelationId = null,
    transitive: bool = false,
};

const senses = kinds(&.{ .sense, .subsense });
const forms = kinds(&.{ .form, .variant, .inflection, .part });
const lexical = kinds(&.{ .entry, .lexeme });
const semantic = senses.unionWith(kinds(&.{ .concept, .interlingual }));

pub const relations = std.enums.EnumArray(RelationId, RelationSpec).init(.{
    .synonym = .{ .name = "synonym", .domain = senses, .range = senses, .symmetric = true },
    .antonym = .{ .name = "antonym", .domain = senses, .range = senses, .symmetric = true },
    .hypernym = .{ .name = "hypernym", .domain = semantic, .range = semantic, .inverse = .hyponym, .transitive = true },
    .hyponym = .{ .name = "hyponym", .domain = semantic, .range = semantic, .inverse = .hypernym, .transitive = true },
    .holonym = .{ .name = "holonym", .domain = semantic, .range = semantic, .inverse = .meronym },
    .meronym = .{ .name = "meronym", .domain = semantic, .range = semantic, .inverse = .holonym },
    .troponym = .{ .name = "troponym", .domain = senses, .range = senses },
    .entails = .{ .name = "entails", .domain = senses, .range = senses, .transitive = true },
    .similar_to = .{ .name = "similar_to", .domain = senses, .range = senses, .symmetric = true },
    .also_see = .{ .name = "also_see", .domain = semantic, .range = semantic, .symmetric = true },
    .derived_from = .{ .name = "derived_from", .domain = forms, .range = forms },
    .variant_of = .{ .name = "variant_of", .domain = forms, .range = forms },
    .form_of = .{ .name = "form_of", .domain = forms, .range = lexical, .inverse = .has_form },
    .has_form = .{ .name = "has_form", .domain = lexical, .range = forms, .inverse = .form_of },
    .sense_of = .{ .name = "sense_of", .domain = senses, .range = lexical },
    .realizes = .{ .name = "realizes", .domain = kinds(&.{.part}), .range = lexical },
    .near_translation = .{ .name = "near_translation", .domain = senses, .range = senses },
    .etymon_of = .{ .name = "etymon_of", .domain = forms, .range = forms },
    .cognate_of = .{ .name = "cognate_of", .domain = forms, .range = forms, .symmetric = true },
    .see_also = .{ .name = "see_also", .domain = KindSet.initFull(), .range = KindSet.initFull(), .symmetric = true },
});

/// Canonical text for the complete type-level contract. Snapshots store only
/// its digest; applications can ship many schemas without embedding names in
/// every file, while a mismatch remains impossible to overlook.
pub const manifest = makeManifest();

fn makeManifest() []const u8 {
    @setEvalBranchQuota(100_000);
    var out: []const u8 = "LEX4-SCHEMA/1\nidentity=rank;keys=primary-counted-automaton;integrity=blake3-page-v1\n";
    for (@typeInfo(Kind).@"enum".fields) |field| {
        const kind: Kind = @enumFromInt(field.value);
        const kind_spec = kind_specs.get(kind);
        out = out ++ std.fmt.comptimePrint("kind:{d}:{s}:{s}:{any}:{any}:{any}\n", .{
            field.value,
            field.name,
            @tagName(kind_spec.layer),
            kind_spec.root,
            kind_spec.text,
            kind_spec.searchable,
        });
        for (@typeInfo(Kind).@"enum".fields) |candidate_field| {
            if (kind_spec.parents.isSet(candidate_field.value))
                out = out ++ std.fmt.comptimePrint("parent:{s}:{s}\n", .{ field.name, candidate_field.name });
            if (children(kind).isSet(candidate_field.value))
                out = out ++ std.fmt.comptimePrint("child:{s}:{s}\n", .{ field.name, candidate_field.name });
        }
        for (kind_spec.columns) |column|
            out = out ++ std.fmt.comptimePrint("column:{s}:{s}\n", .{ field.name, @tagName(column) });
    }
    for (@typeInfo(RelationId).@"enum".fields) |field| {
        const relation = relations.get(@as(RelationId, @enumFromInt(field.value)));
        out = out ++ std.fmt.comptimePrint("relation:{d}:{s}:{any}:{any}:{s}\n", .{
            field.value,
            relation.name,
            relation.symmetric,
            relation.transitive,
            if (relation.inverse) |inverse| @tagName(inverse) else "-",
        });
        for (@typeInfo(Kind).@"enum".fields) |kind_field| {
            if (relation.domain.isSet(kind_field.value))
                out = out ++ std.fmt.comptimePrint("relation-domain:{s}:{s}\n", .{ relation.name, kind_field.name });
            if (relation.range.isSet(kind_field.value))
                out = out ++ std.fmt.comptimePrint("relation-range:{s}:{s}\n", .{ relation.name, kind_field.name });
        }
    }
    return out;
}

/// The manifest is immutable, so its exact digest is part of the reader's
/// comptime contract.  Callers still use `digest()` for the stable API; no
/// artifact-advertised schema value is trusted in its place.
pub const manifest_digest: [16]u8 = blk: {
    @setEvalBranchQuota(5_000_000);
    var result: [16]u8 = undefined;
    std.crypto.hash.Blake3.hash(manifest, &result, .{});
    break :blk result;
};

pub fn digest() [16]u8 {
    return manifest_digest;
}

fn eqlSet(a: KindSet, b: KindSet) bool {
    return std.meta.eql(a, b);
}

fn validate() void {
    inline for (@typeInfo(Kind).@"enum".fields) |field| {
        const kind: Kind = @enumFromInt(field.value);
        const kind_spec = kind_specs.get(kind);
        if (kind_spec.root != kind_spec.parents.eql(none))
            @compileError("a root kind must have no parent domain, and vice versa");
        var seen = std.bit_set.IntegerBitSet(@typeInfo(ColumnId).@"enum".fields.len).initEmpty();
        inline for (kind_spec.columns) |column| {
            const bit = @intFromEnum(column);
            if (seen.isSet(bit)) @compileError("duplicate column in KindSpec");
            seen.set(bit);
        }
    }

    inline for (@typeInfo(RelationId).@"enum".fields) |field| {
        const id: RelationId = @enumFromInt(field.value);
        const relation = relations.get(id);
        if (relation.name.len == 0 or relation.domain.count() == 0 or relation.range.count() == 0)
            @compileError("relation must have a name and non-empty domains");
        if (relation.symmetric and !eqlSet(relation.domain, relation.range))
            @compileError("a symmetric relation must have identical domains");
        if (relation.inverse) |inverse_id| {
            if (relation.symmetric or inverse_id == id) @compileError("invalid inverse relation");
            const inverse = relations.get(inverse_id);
            if (inverse.inverse == null or inverse.inverse.? != id or
                !eqlSet(relation.domain, inverse.range) or !eqlSet(relation.range, inverse.domain))
                @compileError("inverse relation declarations must be mutual and swap domains");
        }
    }
}

comptime {
    @setEvalBranchQuota(5_000_000);
    var recomputed: [16]u8 = undefined;
    std.crypto.hash.Blake3.hash(manifest, &recomputed, .{});
    if (!std.mem.eql(u8, &manifest_digest, &recomputed)) @compileError("schema manifest digest constant drifted");
    validate();
}

test "rank domains remain distinct and checked" {
    const Entry = Rank(.entry);
    const Sense = Rank(.sense);
    try std.testing.expect(Entry != Sense);
    try std.testing.expectEqual(@as(?usize, 7), (try Entry.fromIndex(7)).index());
    try std.testing.expectEqual(@as(?usize, null), Entry.none.index());
    try std.testing.expectError(error.RankOverflow, Entry.fromIndex(std.math.maxInt(u32)));
}

test "kind contract derives legality and column domains" {
    try std.testing.expect(legalParent(null, .entry));
    try std.testing.expect(!legalParent(null, .sense));
    try std.testing.expect(legalParent(.sense, .definition));
    try std.testing.expect(!legalParent(.definition, .sense));
    try std.testing.expect(columnDomain(.concept).isSet(@intFromEnum(Kind.sense)));
    try std.testing.expect(!columnDomain(.concept).isSet(@intFromEnum(Kind.entry)));
    try std.testing.expect(manifest.len > 1_000);
    try std.testing.expect(!std.mem.eql(u8, &digest(), &([_]u8{0} ** 16)));
    var runtime: [16]u8 = undefined;
    std.crypto.hash.Blake3.hash(manifest, &runtime, .{});
    try std.testing.expectEqualSlices(u8, &manifest_digest, &runtime);
    try std.testing.expectEqualSlices(u8, &manifest_digest, &digest());
}

test "navigation reachability and strict dominance use both legality declarations" {
    try std.testing.expect(canDescend(.entry, .definition));
    try std.testing.expect(canDescend(.subsense, .subsense));
    try std.testing.expect(!canDescend(.definition, .sense));
    try std.testing.expect(dominates(.entry, .sense, .subsense));
    try std.testing.expect(!dominates(.entry, .entry, .subsense));
    try std.testing.expect(!dominates(.entry, .sense, .sense));
    try std.testing.expect(dominates(.entry, .sense, .definition));
}
