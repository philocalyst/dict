//! The public lexical model. These are also the packet's schema: no stored
//! shadow types, string ranks, or relationship tables sit between user and data.
//!
//! Ordered content is intentional. Two definitions in one language, repeated
//! examples, and duplicate but independently supported claims remain distinct.
const std = @import("std");

/// Absence inherits; `reset` explicitly removes an inherited language.
pub const Language = union(enum) { inherit, reset, tag: []const u8 };

pub const Name = struct {
    namespace: []const u8 = "",
    local: []const u8,
    prefix: []const u8 = "",
};

pub const Attribute = struct { name: Name, value: []const u8 };

/// Stable external identity is not a physical packet number. A local identity
/// is scoped to this entry; `entry` explicitly names a different entry.
pub const Address = struct { id: []const u8, fragment: ?[]const u8 = null };

pub const Reference = union(enum) {
    local: []const u8,
    entry: Address,
    resource: Address,
    iri: []const u8,
    /// Importers preserve unresolved source links as data. This is distinct
    /// from an invalid local identity in the admitted lexical document.
    unresolved: struct {
        identifier: []const u8,
        base: ?[]const u8 = null,
        /// Expected vocabulary class, including classes outside our core sum.
        expected: ?Name = null,
        display: ?[]const u8 = null,
    },
};

pub const Source = struct {
    id: []const u8,
    media_type: []const u8,
    bytes: []const u8,
    uri: ?[]const u8 = null,
};

/// Byte coordinates refer to a named source, never a guessed XML node rank.
pub const Anchor = struct { source: []const u8, start: u32, end: u32 };

/// Many semantic items may realize the same source span, and one item may
/// realize several spans. Array order preserves the importer's mapping order;
/// the source byte coordinates preserve presentation order independently.
pub const Origin = struct {
    anchor: Anchor,
    role: enum { realization, mention, annotation } = .realization,
    operation: enum { copied, normalized, split, merged, derived } = .copied,
};

pub const Locus = union(enum) {
    whole,
    name,
    value,
    field: Name,
    source: Anchor,
};

pub const Certainty = struct {
    target: ?Reference = null,
    locus: Locus = .whole,
    degree: ?[]const u8 = null,
    asserted: ?Value = null,
    given: []const Reference = &.{},
    evidence: []const Evidence = &.{},
};

pub const Evidence = struct {
    role: enum { source, responsibility, provenance } = .source,
    target: union(enum) { anchor: Anchor, reference: Reference },
};

pub const Annotation = struct {
    name: Name,
    value: []const u8,
    agent: ?Reference = null,
    when: ?[]const u8 = null,
    locus: Locus = .whole,
    content: []const Text = &.{},
    target: ?Reference = null,
};

pub const Metadata = struct {
    id: ?[]const u8 = null,
    language: Language = .inherit,
    evidence: []const Evidence = &.{},
    origins: []const Origin = &.{},
    certainty: []const Certainty = &.{},
    annotations: []const Annotation = &.{},
    attributes: []const Attribute = &.{},
};

/// Rich prose retains namespaces, arbitrary inline structure, comments and
/// processing instructions. It is not interpreted as lexical containment.
pub const Inline = union(enum) {
    text: []const u8,
    element: struct {
        name: Name,
        attributes: []const Attribute = &.{},
        language: Language = .inherit,
        content: []const Inline = &.{},
    },
    comment: []const u8,
    instruction: struct { target: []const u8, data: []const u8 },

    pub fn children(self: *const Inline) []const Inline {
        return switch (self.*) {
            .element => |element| element.content,
            else => &.{},
        };
    }

    pub fn declaredLanguage(self: *const Inline) *const Language {
        return switch (self.*) {
            .element => |*element| &element.language,
            else => &inherited_language,
        };
    }

    const inherited_language: Language = .inherit;
};

pub const Text = struct {
    meta: Metadata = .{},
    content: []const Inline = &.{},
};

pub const Representation = struct {
    meta: Metadata = .{},
    kind: enum { written, phonetic, transliteration } = .written,
    text: Text,
    script: ?[]const u8 = null,
    scheme: ?[]const u8 = null,
    features: []const Feature = &.{},
};

pub const Form = struct {
    meta: Metadata = .{},
    kind: enum { canonical, variant, inflected, stem } = .canonical,
    representations: []const Representation = &.{},
    content: []const Item = &.{},
};

pub const Sense = struct {
    meta: Metadata = .{},
    label: ?[]const u8 = null,
    content: []const Item = &.{},
    /// Ontological referents are not lexical concepts or translation senses.
    denotations: []const Denotation = &.{},
};

/// A sense-owned denotation occurrence.  Its implicit subject remains the
/// containing sense; metadata qualifies this occurrence without turning every
/// denotation into a reified Relation.
pub const Denotation = struct {
    meta: Metadata = .{},
    iri: []const u8,
};

pub const Translation = struct {
    meta: Metadata = .{},
    kind: enum { equivalent, literal, free, back } = .equivalent,
    text: []const Text = &.{},
    target: ?Reference = null,
    category: ?Name = null,
    state: ClaimState = .asserted,
    /// Citation-local grammar, usage, notes and nested examples remain in
    /// order rather than being flattened into the translated quote itself.
    content: []const Item = &.{},
};

pub const Example = struct {
    meta: Metadata = .{},
    text: []const Text = &.{},
    content: []const Item = &.{},
};

/// Exact lexical values: decimals keep their spelling; missing, unknown and
/// alternatives are different. Collections carry their mathematical meaning.
pub const Value = union(enum) {
    text: []const u8,
    symbol: Name,
    integer: i64,
    decimal: []const u8,
    boolean: bool,
    reference: Reference,
    /// Identity-bearing value sharing is distinct from copying an equal value.
    /// References to the shared identity still use `.reference`; this pointer
    /// is the native definition/embedding edge and is never followed by
    /// reference resolution implicitly.
    shared: *const SharedValue,
    structure: Structure,
    list: []const Value,
    set: []const Value,
    bag: []const Value,
    alternative: []const Value,
    negation: []const Value,
    unknown,
    unspecified,
    default,
};

pub const SharedValue = struct {
    meta: Metadata,
    value: Value,
};

pub const Structure = struct {
    meta: Metadata = .{},
    type: ?Name = null,
    fields: []const Feature = &.{},
};

pub const Feature = struct {
    meta: Metadata = .{},
    name: Name,
    value: Value,
    range: ?Reference = null,
};

pub const Usage = struct {
    meta: Metadata = .{},
    kind: enum { register, domain, region, period, frequency, style },
    value: Value,
};

pub const Etymology = struct {
    meta: Metadata = .{},
    process: ?Name = null,
    source: ?Reference = null,
    content: []const Item = &.{},
};

/// A relation is itself addressable and qualified. A lexical concept and an
/// ontology denotation are separate predicates, even when their IRIs coincide.
pub const Relation = struct {
    meta: Metadata = .{},
    predicate: union(enum) {
        denotes,
        evokes,
        lexicalized_sense,
        translation,
        synonym,
        antonym,
        broader,
        derived_from,
        custom: Name,
    },
    /// Exactly one endpoint representation is authoritative.  For a binary
    /// relation the lexical owner is the source and `binary` is its target.
    /// N-ary roles are qualified user names; no role spelling is reserved.
    endpoints: union(enum) {
        binary: Reference,
        participants: []const Participant,
    },
    category: ?Name = null,
    state: ClaimState = .asserted,
    confidence: ?[]const u8 = null,
    content: []const Item = &.{},
};

pub const ClaimState = enum { asserted, inferred, disputed, deprecated };
pub const Participant = struct { role: Name, target: Reference };

pub const Concept = struct {
    meta: Metadata = .{},
    reference: Reference,
    content: []const Item = &.{},
};

pub const Media = struct {
    meta: Metadata = .{},
    uri: []const u8,
    media_type: []const u8,
    caption: []const Text = &.{},
    alt: []const Text = &.{},
    width: ?u32 = null,
    height: ?u32 = null,
};

pub const Argument = struct {
    role: Name,
    realization: ?Reference = null,
    referent: ?Reference = null,
    optional: bool = false,
    features: []const Feature = &.{},
};

pub const Frame = struct {
    meta: Metadata = .{},
    name: Name,
    arguments: []const Argument = &.{},
    content: []const Item = &.{},
};

pub const Component = struct {
    meta: Metadata = .{},
    target: Reference,
    role: ?Name = null,
    content: []const Item = &.{},
};

pub const Extension = struct {
    meta: Metadata = .{},
    name: Name,
    value: ?Value = null,
    content: []const Item = &.{},
};

/// Coordinates address the concatenation of a Representation's inline text
/// leaves, in exact UTF-8 bytes. Markup, comments and instructions occupy no
/// surface bytes. Both ends are scalar boundaries; a zero-length span denotes
/// a zero realization. Repeated/overlapping/discontinuous spans are permitted
/// and retain their declared order, rather than implying concatenation.
pub const RealizationSpan = struct {
    representation: Reference,
    start: u32,
    end: u32,
};

/// A qualified analysis occurrence, independent of the authoritative Form and
/// surface Representation. Multiple analyses preserve ambiguity and competing
/// evidence; no segmentation, language, or normalization is inferred.
pub const Analysis = struct {
    meta: Metadata = .{},
    kind: enum { morphology, multiword, phonology, orthography } = .morphology,
    form: ?Reference = null,
    process: ?Name = null,
    content: []const Item = &.{},
};

/// Ordered constituents form a real analysis tree through `content`. Qualified
/// roles name roots, prefixes, infixes, patterns, agreement slots, and other
/// language-specific distinctions without a closed English morphology list.
/// A root/pattern can realize discontinuous bytes; a clitic or MWE slot can
/// reference another lexical entry; allomorphs retain their exact surface.
pub const Segment = struct {
    meta: Metadata = .{},
    kind: enum { morpheme, word, slot, literal, syllable, phoneme, grapheme } = .morpheme,
    role: ?Name = null,
    target: ?Reference = null,
    realizations: []const RealizationSpan = &.{},
    content: []const Item = &.{},
};

/// An exact byte span in a construction binding or realized surface. UTF-8
/// constructions additionally require both offsets to be scalar boundaries.
pub const ConstructionSpan = struct { start: u32, end: u32 };

/// A surface supplied to a lexical construction. A local target names the
/// authoritative Representation for these exact bytes; an external target
/// preserves an outside identity without withholding the supplied bytes.
/// Origins and spelling remain explicit; equal spellings do not merge identities.
pub const ConstructionSurface = struct {
    bytes: []const u8,
    target: ?Reference = null,
    origins: []const Origin = &.{},
};

pub const ConstructionParameter = struct {
    name: Name,
    role: ?Name = null,
    meta: Metadata = .{},
};

pub const ConstructionArgument = union(enum) {
    binding: u32,
    literal: ConstructionSurface,
};

/// Ordered operations never normalize, case-fold, or infer a morpheme. A call
/// names another program by its declared local identity; admission rejects
/// cycles even when no instance currently invokes the cycle.
pub const ConstructionStep = union(enum) {
    literal: ConstructionSurface,
    copy: struct { binding: u32, spans: []const ConstructionSpan, role: ?Name = null },
    slot: struct { binding: u32, role: ?Name = null },
    call: struct {
        program: Reference,
        arguments: []const ConstructionArgument,
        role: ?Name = null,
    },
    zero: struct { meta: Metadata = .{}, role: ?Name = null },
};

/// `meta.id` is required. The same identity table used by lexical references
/// resolves programs, including calls declared before their target program.
pub const ConstructionProgram = struct {
    meta: Metadata,
    process: ?Name = null,
    parameters: []const ConstructionParameter = &.{},
    body: []const ConstructionStep,
};

pub const ConstructionRealization = struct {
    step: u32,
    spans: []const ConstructionSpan,
    role: ?Name = null,
    meta: Metadata = .{},
};

/// An evidenced construction occurrence. `authoritative` identifies a local
/// Representation. `exact_local` proves byte-for-byte execution against it;
/// `external_unverified` preserves an unavailable program or call outside this
/// Entry until a library catalog can resolve and verify that execution. Multiple
/// occurrences may cite the same program without losing ambiguity.
pub const Construction = struct {
    meta: Metadata = .{},
    analysis: ?Reference = null,
    program: Reference,
    bindings: []const ConstructionSurface = &.{},
    authoritative: Reference,
    proof: enum { exact_local, external_unverified } = .exact_local,
    realizations: []const ConstructionRealization = &.{},
};

/// This sum is the vocabulary. Its tag enum and typed selectors are derived
/// from it, so adding a lexical kind does not require parallel declarations.
pub const Item = union(enum) {
    form: Form,
    sense: Sense,
    definition: Text,
    gloss: Text,
    example: Example,
    translation: Translation,
    grammar: Feature,
    usage: Usage,
    etymology: Etymology,
    relation: Relation,
    concept: Concept,
    note: Text,
    media: Media,
    frame: Frame,
    component: Component,
    extension: Extension,
    analysis: Analysis,
    segment: Segment,
    construction_program: ConstructionProgram,
    construction: Construction,

    pub fn metadata(self: *const Item) *const Metadata {
        return switch (self.*) {
            inline else => |*payload| &payload.meta,
        };
    }

    pub fn declaredLanguage(self: *const Item) *const Language {
        return &self.metadata().language;
    }

    /// Only lexical containment participates. Text's Inline content is a
    /// different type and therefore cannot accidentally become lexical nodes.
    pub fn children(self: *const Item) []const Item {
        return switch (self.*) {
            inline else => |*payload| children: {
                const T = @TypeOf(payload.*);
                if (comptime @hasField(T, "content") and @FieldType(T, "content") == []const Item)
                    break :children payload.content;
                break :children &.{};
            },
        };
    }
};

pub const Kind = std.meta.Tag(Item);

pub const SearchKey = struct {
    spelling: []const u8,
    /// Optional local form identity: preserves why this spelling matched.
    form: ?[]const u8 = null,
};

pub const Entry = struct {
    id: []const u8,
    headword: []const u8,
    meta: Metadata = .{},
    kind: enum { word, multiword, affix, root, homograph_group, free } = .word,
    homograph: ?u32 = null,
    keys: []const SearchKey = &.{},
    content: []const Item = &.{},
    sources: []const Source = &.{},
    /// Unmapped source material remains accounted for, never silently dropped.
    residuals: []const Anchor = &.{},
};

pub const RangeElement = struct {
    meta: Metadata = .{},
    value: Value,
    parent: ?Reference = null,
    labels: []const Text = &.{},
    abbreviations: []const Text = &.{},
    description: []const Text = &.{},
};

pub const Range = struct {
    id: []const u8,
    meta: Metadata = .{},
    external: ?Reference = null,
    labels: []const Text = &.{},
    elements: []const RangeElement = &.{},
};

/// Independently addressable, typed shared atomic or structured values.
pub const ValueLibrary = struct {
    id: []const u8,
    meta: Metadata = .{},
    values: []const SharedValue = &.{},
};

/// Sources and lexical authorities use the same independently admitted packet
/// machinery as entries, but are not disguised as headword-bearing entries.
pub const Resource = union(enum) {
    source: Source,
    range: Range,
    concept: Concept,
    values: ValueLibrary,

    pub fn identity(self: *const Resource) []const u8 {
        return switch (self.*) {
            .source => |source| source.id,
            .range => |range| range.id,
            .concept => |concept| concept.meta.id orelse "",
            .values => |values| values.id,
        };
    }
};

pub const Library = struct {
    entries: []const Entry,
    resources: []const Resource = &.{},
};

pub const Document = union(enum) { entry: Entry, resource: Resource };
