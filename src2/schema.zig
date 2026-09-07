const std = @import("std");

pub const Kind = enum(u8) { entry, lexeme, homograph, sense, subsense, form, variant, pronunciation, inflection, part, example, citation, quote, definition, gloss, note, usage, etymology, etymon, translation, assertion, participant, evidence, text, comment, pi, media, analysis, extension, any };
pub const Node = enum(u32) { none = std.math.maxInt(u32), _ };
pub const Atom = enum(u32) { none = std.math.maxInt(u32), _ };
pub const Key = enum(u32) { none = std.math.maxInt(u32), _ };
pub const Prose = enum(u32) { none = std.math.maxInt(u32), _ };

pub const Direction = enum(u2) { ltr, rtl, auto, mixed };
pub const Profile = enum(u8) { none = std.math.maxInt(u8), _ };
pub const AssertionState = enum(u8) { asserted, inferred, retracted, disputed };
pub const Certainty = enum(u8) { unknown, possible, probable, certain };
pub const ColumnId = enum(u8) { lang, pos, written, headword, normalized, reversed, text, quote, anchor, span, role, predicate, state, certainty, temporal, context, source, target, qname, external_id, shape, direction, profile };
pub const KeySpaceId = enum(u8) { headword, normalized, reversed, external_ids, terms, shapes, atoms };
pub const PredicateId = enum(u16) { translation, synonymy, etymology, see_also, form_of, sense_of, realizes, extension };
pub const Role = enum(u8) { source, target, subject, object, form, part, root, language, context, witness, value, parent, child, extension };
pub const Presence = enum { required, optional, optional_inherited };
pub const Repr = enum { atom, key, prose, node, enum_value, span, bytes, u64, i64 };
pub const Arity = enum { binary, nary };
pub const Reverse = enum { none, materialized };
pub const Cardinality = enum { one, many };
pub const SpanUnit = enum { byte, utf8_codepoint, utf16_code_unit, grapheme };
pub const Span = struct { unit: SpanUnit, start: u64, end: u64 };
/// Draft handles are scoped to the builder generation that issued them.
/// The token survives moves of the Builder; physical snapshot IDs stay tiny.
pub const AnyRef = struct { id: Node, kind: Kind, origin: u64 = 0 };

pub const KindSet = struct {
    bits: u32,
    pub fn has(self: KindSet, kind: Kind) bool {
        return kind != .any and @intFromEnum(kind) < 32 and (self.bits & (@as(u32, 1) << @as(u5, @intCast(@intFromEnum(kind))))) != 0;
    }
    pub fn all() KindSet {
        return .{ .bits = (@as(u32, 1) << (@intFromEnum(Kind.extension) + 1)) - 1 };
    }
    pub fn count(self: KindSet) usize {
        return @popCount(self.bits);
    }
};
pub fn kinds(comptime list: anytype) KindSet {
    var result = KindSet{ .bits = 0 };
    inline for (list) |literal| {
        const kind: Kind = literal;
        if (kind == .any) @compileError("Kind.any is type-level only");
        result.bits |= @as(u32, 1) << @as(u5, @intCast(@intFromEnum(kind)));
    }
    return result;
}
pub fn Ref(comptime kind: Kind) type {
    return struct {
        id: Node,
        origin: u64 = 0,
        pub const Kind = kind;
        pub fn raw(self: @This()) Node {
            return self.id;
        }
        pub fn any(self: @This()) AnyRef {
            return .{ .id = self.id, .kind = kind, .origin = self.origin };
        }
    };
}

fn valueType(comptime id: ColumnId, comptime repr: Repr) type {
    return switch (id) {
        .direction => Direction,
        .profile => Profile,
        .state => AssertionState,
        .certainty => Certainty,
        else => switch (repr) {
            .atom => Atom,
            .key => Key,
            .prose => Prose,
            .node => Node,
            .enum_value => u8,
            .span => Span,
            .bytes => []const u8,
            .u64 => u64,
            .i64 => i64,
        },
    };
}
fn inputType(comptime id: ColumnId, comptime repr: Repr) type {
    return switch (id) {
        .direction => Direction,
        .profile => Profile,
        .state => AssertionState,
        .certainty => Certainty,
        else => switch (repr) {
            .atom, .key, .prose, .bytes => []const u8,
            .node => AnyRef,
            .enum_value => u8,
            .span => Span,
            .u64 => u64,
            .i64 => i64,
        },
    };
}

/// Column descriptors carry scope, wire representation and typed API values together.
pub fn Column(comptime id: ColumnId, comptime col_name: []const u8, comptime col_over: KindSet, comptime col_repr: Repr, comptime col_presence: Presence) type {
    return struct {
        pub const Id = id;
        pub const name = col_name;
        pub const over = col_over;
        pub const repr = col_repr;
        pub const presence = col_presence;
        pub const Value = valueType(id, col_repr);
        pub const Input = inputType(id, col_repr);
        pub fn applies(comptime kind: Kind) bool {
            return kind == .any or over.has(kind);
        }
        pub fn keySpace() ?KeySpaceId {
            return switch (id) {
                .written, .headword => .headword,
                .normalized => .normalized,
                .reversed => .reversed,
                .external_id => .external_ids,
                .shape => .shapes,
                else => null,
            };
        }
    };
}

pub const columns = struct {
    pub const lang = Column(.lang, "lang", kinds(.{ .entry, .lexeme, .sense, .form, .text, .translation, .extension, .analysis }), .atom, .optional_inherited);
    pub const pos = Column(.pos, "pos", kinds(.{ .entry, .lexeme, .sense, .form }), .atom, .optional_inherited);
    pub const written = Column(.written, "written", kinds(.{ .form, .variant, .inflection, .part }), .key, .required);
    pub const headword = Column(.headword, "headword", kinds(.{ .entry, .lexeme }), .key, .required);
    // Search projections apply equally to dictionary headwords and subordinate
    // written forms.  Keeping them in columns makes the exact profile-derived
    // key for a node discoverable without re-running host locale logic.
    pub const normalized = Column(.normalized, "normalized", kinds(.{ .entry, .lexeme, .form, .variant, .inflection, .part }), .key, .optional);
    pub const reversed = Column(.reversed, "reversed", kinds(.{ .entry, .lexeme, .form, .variant, .inflection, .part }), .key, .optional);
    pub const text = Column(.text, "text", kinds(.{ .definition, .gloss, .example, .note, .text, .comment, .pi, .etymology }), .prose, .required);
    pub const quote = Column(.quote, "quote", kinds(.{.evidence}), .prose, .optional);
    pub const anchor = Column(.anchor, "anchor", kinds(.{.evidence}), .bytes, .optional);
    pub const span = Column(.span, "span", kinds(.{.part}), .span, .optional);
    pub const role = Column(.role, "role", kinds(.{ .participant, .part }), .atom, .required);
    pub const predicate = Column(.predicate, "predicate", kinds(.{.assertion}), .atom, .required);
    pub const state = Column(.state, "state", kinds(.{.assertion}), .enum_value, .required);
    pub const certainty = Column(.certainty, "certainty", kinds(.{ .assertion, .evidence }), .enum_value, .optional);
    pub const temporal = Column(.temporal, "temporal", kinds(.{.assertion}), .bytes, .optional);
    pub const context = Column(.context, "context", kinds(.{.assertion}), .bytes, .optional);
    pub const source = Column(.source, "source", kinds(.{ .assertion, .evidence }), .node, .optional);
    // A participant has exactly one semantic target, but unresolved targets
    // live in the typed cold record rather than being forged into the Node ID
    // domain. The compiler enforces the XOR across those two representations.
    pub const target = Column(.target, "target", kinds(.{.participant}), .node, .optional);
    pub const qname = Column(.qname, "qname", kinds(.{.extension}), .atom, .required);
    pub const external_id = Column(.external_id, "external_id", KindSet.all(), .key, .optional);
    pub const shape = Column(.shape, "shape", kinds(.{.extension}), .key, .optional);
    pub const direction = Column(.direction, "direction", kinds(.{ .entry, .lexeme, .sense, .form, .text, .translation, .extension }), .enum_value, .optional_inherited);
    pub const profile = Column(.profile, "profile", kinds(.{ .entry, .lexeme, .form, .text, .extension, .analysis }), .enum_value, .optional);
};

pub fn columnTypes() [@typeInfo(columns).@"struct".decls.len]type {
    var result: [@typeInfo(columns).@"struct".decls.len]type = undefined;
    inline for (@typeInfo(columns).@"struct".decls, 0..) |decl, i| result[i] = @field(columns, decl.name);
    return result;
}
pub fn columnById(comptime id: ColumnId) type {
    inline for (columnTypes()) |C| if (C.Id == id) return C;
    @compileError("unknown column id");
}

/// Public generic boundaries accept canonical descriptor identity, never a
/// lookalike struct whose ID and representation can disagree.
pub fn assertColumn(comptime C: type) void {
    if (!@hasDecl(C, "Id")) @compileError("expected a canonical schema column");
    if (C != columnById(C.Id)) @compileError("forged column descriptor");
}

pub fn assertPredicate(comptime P: PredicateSpec) void {
    const canonical = predicateSpec(P.id) orelse @compileError("use runtimeAssertion for extension predicates");
    if (!std.meta.eql(P, canonical)) @compileError("forged predicate descriptor");
}
pub fn columnByName(comptime wanted: []const u8) type {
    inline for (columnTypes()) |C| if (std.mem.eql(u8, wanted, C.name)) return C;
    @compileError("unknown v2 column name: " ++ wanted);
}

pub const RoleSpec = struct { role: Role, kind: Kind, cardinality: Cardinality = .one };
pub const PredicateSpec = struct { id: PredicateId, name: []const u8, owner: Kind = .any, roles: []const RoleSpec, arity: Arity = .nary, reverse: Reverse = .none };
pub fn predicate(comptime id: PredicateId, comptime name: []const u8, comptime owner: Kind, comptime roles: []const RoleSpec, comptime arity: Arity, comptime reverse: Reverse) PredicateSpec {
    return .{ .id = id, .name = name, .owner = owner, .roles = roles, .arity = arity, .reverse = reverse };
}
pub const predicates = struct {
    pub const translation = predicate(.translation, "translation", .sense, &.{ .{ .role = .source, .kind = .sense }, .{ .role = .target, .kind = .sense, .cardinality = .many } }, .binary, .materialized);
    pub const synonymy = predicate(.synonymy, "synonymy", .sense, &.{ .{ .role = .source, .kind = .sense }, .{ .role = .target, .kind = .sense, .cardinality = .many } }, .binary, .materialized);
    pub const etymology = predicate(.etymology, "etymology", .entry, &.{ .{ .role = .source, .kind = .form, .cardinality = .many }, .{ .role = .target, .kind = .form }, .{ .role = .language, .kind = .extension, .cardinality = .many } }, .nary, .materialized);
    pub const see_also = predicate(.see_also, "see_also", .entry, &.{ .{ .role = .source, .kind = .entry }, .{ .role = .target, .kind = .entry, .cardinality = .many } }, .binary, .none);
    pub const form_of = predicate(.form_of, "form_of", .entry, &.{ .{ .role = .source, .kind = .form }, .{ .role = .target, .kind = .lexeme } }, .binary, .materialized);
    pub const sense_of = predicate(.sense_of, "sense_of", .entry, &.{ .{ .role = .source, .kind = .sense }, .{ .role = .target, .kind = .lexeme } }, .binary, .materialized);
    pub const realizes = predicate(.realizes, "realizes", .entry, &.{ .{ .role = .source, .kind = .part }, .{ .role = .target, .kind = .lexeme } }, .binary, .materialized);
};

pub const KeySpaceSpec = struct { id: KeySpaceId, name: []const u8, targets: KindSet, postings: bool = true, reversed: bool = false, profile_bound: bool = false };
pub const key_spaces = struct {
    pub const headword = KeySpaceSpec{ .id = .headword, .name = "headword", .targets = kinds(.{ .entry, .lexeme, .form, .variant, .inflection, .part }) };
    pub const normalized = KeySpaceSpec{ .id = .normalized, .name = "normalized", .targets = kinds(.{ .entry, .lexeme, .form, .variant, .inflection, .part }), .profile_bound = true };
    pub const reversed = KeySpaceSpec{ .id = .reversed, .name = "reversed", .targets = kinds(.{ .entry, .lexeme, .form, .variant, .inflection, .part }), .reversed = true, .profile_bound = true };
    pub const external_ids = KeySpaceSpec{ .id = .external_ids, .name = "external_ids", .targets = KindSet.all(), .profile_bound = true };
    pub const terms = KeySpaceSpec{ .id = .terms, .name = "terms", .targets = KindSet.all(), .profile_bound = true };
    pub const shapes = KeySpaceSpec{ .id = .shapes, .name = "shapes", .targets = kinds(.{.extension}) };
    pub const atoms = KeySpaceSpec{ .id = .atoms, .name = "atoms", .targets = KindSet.all(), .postings = false };
};
pub fn keySpaceTypes() [@typeInfo(key_spaces).@"struct".decls.len]KeySpaceSpec {
    var result: [@typeInfo(key_spaces).@"struct".decls.len]KeySpaceSpec = undefined;
    inline for (@typeInfo(key_spaces).@"struct".decls, 0..) |decl, i| result[i] = @field(key_spaces, decl.name);
    return result;
}
pub fn keySpaceById(comptime id: KeySpaceId) KeySpaceSpec {
    inline for (keySpaceTypes()) |spec| if (spec.id == id) return spec;
    @compileError("unknown key-space id");
}
pub fn keySpaceSpec(id: KeySpaceId) KeySpaceSpec {
    inline for (keySpaceTypes()) |spec| if (spec.id == id) return spec;
    unreachable;
}
pub fn predicateTypes() [@typeInfo(predicates).@"struct".decls.len]PredicateSpec {
    var result: [@typeInfo(predicates).@"struct".decls.len]PredicateSpec = undefined;
    inline for (@typeInfo(predicates).@"struct".decls, 0..) |decl, i| result[i] = @field(predicates, decl.name);
    return result;
}

/// Structural role constraints stay independent from vocabulary extensions.
/// Generic lexical/document nodes may nest freely, but the identity-bearing
/// helper kinds must remain under the owner that gives them meaning.
pub fn legalParent(parent: ?Kind, child: Kind) bool {
    return switch (child) {
        .any => false,
        .participant, .evidence => parent == .assertion,
        .part => parent == .form or parent == .variant or parent == .inflection or parent == .part or parent == .analysis,
        .analysis => parent == .form or parent == .variant or parent == .inflection,
        .subsense => parent == .sense or parent == .subsense or parent == .extension,
        else => true,
    };
}

pub fn predicateSpec(id: PredicateId) ?PredicateSpec {
    inline for (predicateTypes()) |spec| if (spec.id == id) return spec;
    return null;
}

pub fn reversePolicy(id: PredicateId) Reverse {
    return if (predicateSpec(id)) |spec| spec.reverse else .none;
}

/// The manifest is the canonical serialization of the complete compile-time
/// contract. Comparing these bytes checks names, scopes, roles, cardinalities,
/// codec semantics and search profile together; a mere count/hash is not a
/// substitute for parsing a schema contract.
pub const manifest = makeManifest();

fn makeManifest() []const u8 {
    @setEvalBranchQuota(100_000);
    var out: []const u8 = "LEX2-SCHEMA/3\n" ++
        "scalar-lanes=lsb-packed;span=unit,u64,u64;bytes=u32-offsets\n" ++
        "search=ascii-fold+unicode-scalar-reverse+word-v1\n" ++
        "keys=KSP2/2;forest=FST2/2;columns=COL2/2;edges=EDG2/2;prose=PRSE/3,PITM/2\n" ++
        "runtime-predicates=nonempty-name,one-or-more-participants,source-target-shadows\n" ++
        "shape=decimal-byte-length:UTF8-name;grapheme-spans=unsupported\n";
    for (.{ .{ "direction", Direction }, .{ "profile", Profile }, .{ "state", AssertionState }, .{ "certainty", Certainty }, .{ "span-unit", SpanUnit }, .{ "role", Role } }) |spec| {
        for (@typeInfo(spec[1]).@"enum".fields) |field|
            out = out ++ std.fmt.comptimePrint("enum:{s}:{d}:{s}\n", .{ spec[0], field.value, field.name });
    }
    for (@typeInfo(Kind).@"enum".fields) |field|
        out = out ++ std.fmt.comptimePrint("kind:{d}:{s}\n", .{ field.value, field.name });
    for (columnTypes()) |C|
        out = out ++ std.fmt.comptimePrint("col:{d}:{s}:{x}:{s}:{s}\n", .{ @intFromEnum(C.Id), C.name, C.over.bits, @tagName(C.repr), @tagName(C.presence) });
    for (predicateTypes()) |P| {
        out = out ++ std.fmt.comptimePrint("pred:{d}:{s}:{s}:{s}:{s}\n", .{ @intFromEnum(P.id), P.name, @tagName(P.owner), @tagName(P.arity), @tagName(P.reverse) });
        for (P.roles) |role|
            out = out ++ std.fmt.comptimePrint("role:{s}:{s}:{s}\n", .{ @tagName(role.role), @tagName(role.kind), @tagName(role.cardinality) });
    }
    for (keySpaceTypes()) |K|
        out = out ++ std.fmt.comptimePrint("space:{d}:{s}:{x}:{any}:{any}:{any}\n", .{ @intFromEnum(K.id), K.name, K.targets.bits, K.postings, K.reversed, K.profile_bound });
    return out;
}

fn validateSchema() void {
    const cs = columnTypes();
    inline for (cs, 0..) |C, i| {
        if (C.Id != @as(ColumnId, @enumFromInt(i)) or C.name.len == 0 or C.over.bits == 0) @compileError("invalid column descriptor");
        inline for (cs[0..i]) |Prior| if (Prior.Id == C.Id or std.mem.eql(u8, Prior.name, C.name)) @compileError("duplicate column descriptor");
    }
    const ps = predicateTypes();
    inline for (ps, 0..) |P, i| {
        if (P.name.len == 0 or P.roles.len == 0) @compileError("invalid predicate descriptor");
        inline for (ps[0..i]) |Prior| if (Prior.id == P.id or std.mem.eql(u8, Prior.name, P.name)) @compileError("duplicate predicate descriptor");
        var source: usize = 0;
        var target: usize = 0;
        inline for (P.roles) |role| {
            if (role.kind == .any) @compileError("predicate role cannot target Kind.any");
            if (role.role == .source) source += 1;
            if (role.role == .target) target += 1;
        }
        if (source == 0 or target == 0) @compileError("predicate requires source and target roles");
        if (P.arity == .binary and P.roles.len != 2) @compileError("binary predicate must have exactly two roles");
    }
    const ks = keySpaceTypes();
    inline for (ks, 0..) |K, i| {
        if (K.name.len == 0 or K.targets.bits == 0) @compileError("invalid key-space descriptor");
        inline for (ks[0..i]) |Prior| if (Prior.id == K.id or std.mem.eql(u8, Prior.name, K.name)) @compileError("duplicate key-space descriptor");
        if (!K.postings and K.reversed) @compileError("non-posting key-space cannot be reversed");
    }
}
comptime {
    validateSchema();
}
