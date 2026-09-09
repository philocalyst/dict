//! Deterministic LEX4 assembly boundary.
//!
//! The compact section writers are intentionally independent.  This module is
//! the one place that turns their already-encoded payloads into a snapshot:
//! it checks each section in isolation, checks the rank identity contract, and
//! only then emits the authenticated container.  The input is deliberately a
//! small descriptor list rather than a semantic record wrapper.  That keeps
//! the compiler boundary useful to a streaming or separately parallelized
//! producer while making the durable section order explicit here.

const std = @import("std");
const automaton = @import("automaton.zig");
const axes = @import("axes.zig");
const cold = @import("cold.zig");
const concepts = @import("concepts.zig");
const container = @import("container.zig");
const forest = @import("forest.zig");
const grammar = @import("grammar.zig");
const relations = @import("relations.zig");
const rich_content = @import("rich_content.zig");
const schema = @import("schema.zig");
const terms = @import("terms.zig");
const text_index = @import("text_index.zig");
const wire = @import("wire.zig");

comptime {
    @setEvalBranchQuota(100_000);
}

pub const Section = struct {
    tag: container.Tag,
    bytes: []const u8,
    flags: u32 = 0,
};

pub const Input = struct {
    /// Payloads may arrive in any order.  The compiler sorts them into the
    /// canonical wire order; duplicate and unknown descriptors are rejected.
    sections: []const Section,
};

/// The three hot sections have a stable spelling so callers do not need to
/// manufacture a descriptor list merely to publish a snapshot.  `build` and
/// `buildWithExtras` copy these descriptors into a fixed-size value before
/// calling `prepare`; no returned plan ever borrows a stack array.
pub const Parts = struct {
    automaton: []const u8,
    forest: []const u8,
    prose: []const u8,
};

pub const EntryRecord = struct {
    key: []const u8,
    multiplicity: u32 = 1,
};

pub const FormRecord = struct {
    key: []const u8,
    /// Source-entry ordinal, before key ordering.  The compiler remaps these
    /// references to the final primary rank after sorting entries.  This
    /// shorthand is intentionally accepted only for single-rank entries;
    /// using it for a homograph is an error rather than an implicit choice of
    /// the first sense.
    targets: []const usize = &.{},
    /// Explicit source-entry rank ranges. `first` is relative to the
    /// homograph range of `source_entry`, and `count` may be one for an
    /// individual homograph.  A form must provide exactly one of `targets`
    /// or `rank_targets`.
    rank_targets: []const RankTarget = &.{},
};

/// A form target is a typed range in the primary entry-rank domain.  The
/// source ordinal is the ordinal in the caller's unsorted `KeyRecord` list;
/// `first` and `count` select individual homographs after that entry's
/// multiplicity has been assigned.  Keeping this as a value type makes it
/// impossible for the builder to silently collapse a homograph target.
pub const RankTarget = struct {
    source_entry: usize,
    first: u32 = 0,
    count: u32 = 1,
};

pub const KeyRecord = union(enum) {
    entry: EntryRecord,
    form: FormRecord,
};

/// A prose row is not an entry row.  Producers that have definitions,
/// examples, and glosses in one grammar stream declare their typed domains
/// here; the compiler checks the sum against the grammar's item domain but
/// never invents a row-to-entry mapping.
pub const ProseDomain = struct {
    kind: schema.Kind,
    /// First grammar rank occupied by this typed domain. Domains are
    /// contiguous in the compact declaration; a future map section can use
    /// richer per-rank ranges without changing the count invariant here.
    first: usize = 0,
    count: usize,
};

/// Optional rank-domain declarations.  These are useful for columns emitted
/// by a parallel compiler: the section writer remains independent, while the
/// assembly boundary can prove that a declared column has the same cardinality
/// as the forest's derived kind rank.
pub const KindDomain = struct {
    kind: schema.Kind,
    count: usize,
};

pub const ProseAlignment = enum {
    /// Prose rows are a separate compact domain.  No implicit row-to-entry
    /// mapping is invented by the compiler.
    independent,
    /// Require the caller's declared one-row-per-entry policy.
    one_per_entry,
};

pub const Options = struct {
    expected_schema: ?[container.digest_size]u8 = null,
    max_section_bytes: usize = std.math.maxInt(usize),
    grammar_limits: grammar.Limits = .{},
    prose_alignment: ProseAlignment = .independent,
    prose_domains: []const ProseDomain = &.{},
    require_prose_domains: bool = false,
    kind_domains: []const KindDomain = &.{},
};

pub const Error = container.Error || automaton.Error || forest.Error || grammar.Error || error{
    MissingRequiredSection,
    SectionTooLarge,
    CrossSectionMismatch,
    InvalidOptions,
    DuplicateDomain,
    MissingDomainMapping,
    InvalidDomain,
    OptionalSectionConflict,
    MissingTextMap,
    InvalidPlan,
    ForestAlignmentRequired,
    InvalidForestAlignment,
};

pub const ByteLedger = struct {
    header: usize,
    directory: usize,
    section_bytes: usize,
    alignment_padding: usize,
    page_digests: usize,
    total_bytes: usize,

    pub fn total(self: ByteLedger) usize {
        return self.header + self.directory + self.section_bytes +
            self.alignment_padding + self.page_digests;
    }
};

pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    ledger: ByteLedger,
    schema_digest: [container.digest_size]u8,
    /// Primary entry multiplicity.  This is the rank domain used by the
    /// forest; prose rows remain a separate domain unless the caller selects
    /// an explicit one-per-entry policy.
    entry_count: u32,
    /// Number of accepted automaton records, including form records.  It is
    /// intentionally reported separately from `entry_count`.
    accepted_count: u32,
    prose_item_count: usize,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

// Three required records plus the nine known optional records. The fixed
// value keeps `Prepared` allocation-free and makes its borrowed plan safe to
// return by value while still leaving room for every canonical directory tag.
const max_sections = 13;

/// A prepared plan is deliberately a value, not a slice into a local
/// `planned_storage` array.  This was a subtle but serious lifetime bug in an
/// earlier draft: the plan looked immutable, but its `sections` slice pointed
/// at a stack temporary after `prepare` returned.  The fixed array below is
/// small, copied, and returned by value; all payload slices remain explicitly
/// borrowed from the caller until `compilePrepared` finishes.
pub const Prepared = struct {
    sections_: [max_sections]container.Input,
    section_count_: usize,
    automaton_: automaton.View,
    forest_: forest.View,
    prose_: grammar.View,
    schema_digest_: [container.digest_size]u8,
    entry_count_: u32,
    accepted_count_: u32,
    prose_item_count_: usize,
    one_per_entry_: bool,
    requires_text_map_: bool,
    prose_domains_: [schema.kind_count]ProseDomain,
    prose_domain_count_: usize,
    kind_domains_: [schema.kind_count]KindDomain,
    kind_domain_count_: usize,
    max_section_bytes_: usize,
    grammar_limits_: grammar.Limits,
    /// A private stamp prevents an arbitrary `undefined`/zero-valued plan
    /// from reaching the container writer. `compilePrepared` still reopens
    /// and verifies every borrowed payload, so the stamp is only the first
    /// line of defence against forged plans.
    stamp_: u64,

    pub fn inputs(self: *const Prepared) []const container.Input {
        return self.sections_[0..self.section_count_];
    }

    pub fn deinit(self: *Prepared) void {
        // The plan owns no payload bytes.  Poisoning the value catches use
        // after deinit in debug builds without pretending it has an allocator
        // lifetime of its own.
        self.* = undefined;
    }

    pub fn emit(self: *const Prepared, allocator: std.mem.Allocator) Error!Owned {
        return compilePrepared(allocator, self.*);
    }
};

const prepared_stamp: u64 = 0x4c34_5052_4550_4152;

const KeyWork = struct {
    key: []const u8,
    record_index: usize,
    multiplicity: u32 = 0,
    targets: []const usize = &.{},
    rank_targets: []const RankTarget = &.{},
    is_entry: bool,
};

fn keyLess(_: void, left: KeyWork, right: KeyWork) bool {
    const order = std.mem.order(u8, left.key, right.key);
    return switch (order) {
        .lt => true,
        .gt => false,
        // Equal keys are intentionally stable in the input-independent
        // ordering; the builder reports the duplicate rather than silently
        // coalescing an entry and a form.
        .eq => left.is_entry and !right.is_entry,
    };
}

fn sourceEntryLess(records: []const KeyRecord, left: usize, right: usize) bool {
    return std.mem.order(u8, records[left].entry.key, records[right].entry.key) == .lt;
}

/// Build the primary key automaton from semantic key records.  The caller may
/// provide entries and forms in any order.  Entry ranks are assigned only
/// after a bytewise key sort; form targets are remapped from source-entry
/// ordinals, so permutations of the input cannot change the wire bytes once
/// the source ordinals are updated with the same permutation.
pub fn buildAutomaton(allocator: std.mem.Allocator, records: []const KeyRecord) Error!automaton.Owned {
    if (records.len == 0) return error.InvalidInput;
    var entries: std.ArrayList(KeyWork) = .empty;
    defer entries.deinit(allocator);
    var forms: std.ArrayList(KeyWork) = .empty;
    defer forms.deinit(allocator);
    for (records, 0..) |record, record_index| switch (record) {
        .entry => |entry| try entries.append(allocator, .{ .key = entry.key, .record_index = record_index, .multiplicity = entry.multiplicity, .is_entry = true }),
        .form => |form| try forms.append(allocator, .{
            .key = form.key,
            .record_index = record_index,
            .targets = form.targets,
            .rank_targets = form.rank_targets,
            .is_entry = false,
        }),
    };
    if (entries.items.len == 0) return error.InvalidInput;
    std.mem.sort(KeyWork, entries.items, {}, keyLess);
    std.mem.sort(KeyWork, forms.items, {}, keyLess);

    var source_to_rank = try allocator.alloc(u32, records.len);
    defer allocator.free(source_to_rank);
    @memset(source_to_rank, std.math.maxInt(u32));
    var source_to_multiplicity = try allocator.alloc(u32, records.len);
    defer allocator.free(source_to_multiplicity);
    @memset(source_to_multiplicity, 0);
    var rank_value: u32 = 0;
    for (entries.items) |entry| {
        source_to_rank[entry.record_index] = rank_value;
        source_to_multiplicity[entry.record_index] = entry.multiplicity;
        rank_value = std.math.add(u32, rank_value, entry.multiplicity) catch return error.Overflow;
    }
    var entry_record_indices = try allocator.alloc(usize, entries.items.len);
    defer allocator.free(entry_record_indices);
    var source_entry_ordinal: usize = 0;
    for (records, 0..) |record, record_index| switch (record) {
        .entry => {
            entry_record_indices[source_entry_ordinal] = record_index;
            source_entry_ordinal += 1;
        },
        .form => {},
    };

    var builder = automaton.Builder.init(allocator);
    defer builder.deinit();
    var entry_index: usize = 0;
    var form_index: usize = 0;
    while (entry_index < entries.items.len or form_index < forms.items.len) {
        const use_entry = form_index == forms.items.len or
            (entry_index < entries.items.len and keyLess({}, entries.items[entry_index], forms.items[form_index]));
        if (use_entry) {
            const entry = entries.items[entry_index];
            try builder.addEntry(entry.key, entry.multiplicity);
            entry_index += 1;
        } else {
            const form = forms.items[form_index];
            if ((form.targets.len == 0) == (form.rank_targets.len == 0)) return error.InvalidTargets;
            var targets = std.ArrayList(u32).empty;
            defer targets.deinit(allocator);
            if (form.targets.len != 0) {
                try targets.ensureTotalCapacity(allocator, form.targets.len);
                for (form.targets) |source_entry| {
                    if (source_entry >= entry_record_indices.len) return error.InvalidTarget;
                    const source_record = entry_record_indices[source_entry];
                    // The old shorthand has no way to name which homograph
                    // it means. Reject it for multiplicity > 1 instead of
                    // quietly targeting the first rank.
                    if (source_to_multiplicity[source_record] != 1) return error.InvalidTargets;
                    try targets.append(allocator, source_to_rank[source_record]);
                }
            } else {
                for (form.rank_targets) |target| {
                    if (target.count == 0) return error.InvalidTargets;
                    if (target.source_entry >= entry_record_indices.len) return error.InvalidTarget;
                    const source_record = entry_record_indices[target.source_entry];
                    const multiplicity = source_to_multiplicity[source_record];
                    const end = std.math.add(u32, target.first, target.count) catch return error.Overflow;
                    if (end > multiplicity) return error.InvalidTarget;
                    try targets.ensureTotalCapacity(allocator, targets.items.len + target.count);
                    for (0..target.count) |offset| {
                        const rank = std.math.add(u32, source_to_rank[source_record], target.first) catch return error.Overflow;
                        try targets.append(allocator, std.math.add(u32, rank, @intCast(offset)) catch return error.Overflow);
                    }
                }
            }
            std.mem.sort(u32, targets.items, {}, std.sort.asc(u32));
            for (targets.items, 0..) |target, i| if (i != 0 and target == targets.items[i - 1]) return error.InvalidTargets;
            try builder.addForm(form.key, targets.items);
            form_index += 1;
        }
    }
    return builder.finish();
}

pub const RecordInput = struct {
    keys: []const KeyRecord,
    forest: []const u8,
    prose: []const u8,
    /// The roots in the prebuilt forest, expressed as source-entry ordinals
    /// in `keys`.  A serialized forest deliberately has no key bytes, so a
    /// caller that asks this function to combine independently-built pieces
    /// must provide this proof of ordering.  An empty proof is rejected.
    forest_source_entries: []const usize = &.{},
};

/// Assemble a semantic key set with already-built structural/prose domains.
/// This is the deliberately small seam between importers and the section
/// writers: keys receive canonical ranks here, while a richer importer can
/// build forest and grammar sections in parallel and hand their immutable
/// bytes to the same checked assembly path.
pub fn buildFromRecords(
    allocator: std.mem.Allocator,
    input: RecordInput,
    extras: []const Section,
    options: Options,
) Error!Owned {
    var keys = try buildAutomaton(allocator, input.keys);
    defer keys.deinit();
    const forest_view = try forest.View.open(input.forest);
    try forest_view.verify();
    if (input.forest_source_entries.len != forest_view.rootCount()) return error.ForestAlignmentRequired;
    var sorted_entries = try allocator.alloc(usize, input.keys.len);
    defer allocator.free(sorted_entries);
    var count: usize = 0;
    for (input.keys, 0..) |record, index| switch (record) {
        .entry => {
            sorted_entries[count] = index;
            count += 1;
        },
        .form => {},
    };
    std.mem.sort(usize, sorted_entries[0..count], input.keys, sourceEntryLess);
    if (count != input.forest_source_entries.len) return error.InvalidForestAlignment;
    for (sorted_entries[0..count], input.forest_source_entries) |expected, actual| {
        if (expected != actual) return error.InvalidForestAlignment;
    }
    return buildWithExtras(allocator, .{ .automaton = keys.bytes, .forest = input.forest, .prose = input.prose }, extras, options);
}

/// The compiler exposes the canonical L4TX owner rather than maintaining a
/// second wire serializer.  Its `Owned` value borrows no input after return.
pub const TextMapOwned = text_index.Owned;

/// Emit the small typed text map consumed by `snapshot.Query.texts`. A
/// contiguous domain maps one prose item to each rank of its forest kind;
/// zero-length ranges are emitted for undeclared kinds. This keeps mapping
/// metadata separate from the grammar and, crucially, does not equate prose
/// rows with entry roots.
pub fn buildTextMap(
    allocator: std.mem.Allocator,
    structure: *const forest.View,
    prose_count: usize,
    domains: []const ProseDomain,
) Error!TextMapOwned {
    try validateProseDomains(prose_count, .{ .prose_domains = domains, .require_prose_domains = prose_count != 0 });
    var converted = try allocator.alloc(text_index.ContiguousDomainInput, domains.len);
    defer allocator.free(converted);
    for (domains, 0..) |domain, index| converted[index] = .{ .kind = domain.kind, .first = domain.first, .count = domain.count };
    return text_index.buildContiguous(allocator, structure, prose_count, converted) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Overflow => error.Overflow,
        error.CrossSectionMismatch => error.CrossSectionMismatch,
        error.DuplicateDomain => error.DuplicateDomain,
        error.InvalidDomain => error.InvalidDomain,
        error.MissingDomain => error.MissingDomainMapping,
        else => error.InvalidOptions,
    };
}

/// Build a snapshot and materialize the typed prose map in the optional
/// `columns` section. An explicit columns extra is rejected to prevent two
/// independent mapping authorities from disagreeing.
pub fn buildWithProseMap(
    allocator: std.mem.Allocator,
    parts: Parts,
    domains: []const ProseDomain,
    extras: []const Section,
    options: Options,
) Error!Owned {
    for (extras) |extra| if (extra.tag == .columns) return error.OptionalSectionConflict;
    const structure = try forest.View.open(parts.forest);
    try structure.verify();
    const prose_view = try grammar.View.open(parts.prose, options.grammar_limits);
    try prose_view.verify();
    var map = try buildTextMap(allocator, &structure, prose_view.item_count, domains);
    defer map.deinit();
    if (extras.len >= max_sections - 3) return error.OptionalSectionConflict;
    var all: [max_sections - 2]Section = undefined;
    all[0] = .{ .tag = .columns, .bytes = map.bytes };
    for (extras, 0..) |extra, index| all[index + 1] = extra;
    var effective = options;
    effective.prose_domains = domains;
    effective.require_prose_domains = true;
    return buildWithExtras(allocator, parts, all[0 .. extras.len + 1], effective);
}

fn checkedSectionBytes(bytes: []const u8, max_section_bytes: usize) Error!void {
    if (bytes.len == 0) return error.EmptySection;
    if (bytes.len > max_section_bytes) return error.SectionTooLarge;
    // The container stores lengths and offsets as u64.  Keep this check at
    // the integration boundary so a later container layout cannot silently
    // truncate a host-sized slice.
    _ = wire.cast(u64, bytes.len) catch return error.Overflow;
}

fn tagIndex(tag: container.Tag) ?usize {
    return switch (tag) {
        .automaton => 0,
        .forest => 1,
        .columns => 2,
        .prose => 3,
        .normalized => 4,
        .phonetic => 5,
        .reversed => 6,
        .terms => 7,
        .concepts => 8,
        .relations => 9,
        .cold => 10,
        .metadata => 11,
        .rich_content => 12,
        _ => null,
    };
}

fn validateProseDomains(item_count: usize, options: Options) Error!void {
    if (options.require_prose_domains and item_count != 0 and options.prose_domains.len == 0)
        return error.MissingDomainMapping;
    var total: usize = 0;
    for (options.prose_domains, 0..) |domain, i| {
        if (!schema.spec(domain.kind).text or domain.count == 0) return error.InvalidDomain;
        for (options.prose_domains[0..i]) |prior| if (prior.kind == domain.kind) return error.DuplicateDomain;
        const end = std.math.add(usize, domain.first, domain.count) catch return error.Overflow;
        if (end > item_count) return error.CrossSectionMismatch;
        for (options.prose_domains[0..i]) |prior| {
            const prior_end = std.math.add(usize, prior.first, prior.count) catch return error.Overflow;
            if (domain.first < prior_end and prior.first < end) return error.InvalidDomain;
        }
        total = std.math.add(usize, total, domain.count) catch return error.Overflow;
    }
    if (options.prose_domains.len != 0 and total != item_count) return error.CrossSectionMismatch;
}

fn validateKindDomains(view: *const forest.View, declarations: []const KindDomain) Error!void {
    for (declarations, 0..) |declaration, i| {
        for (declarations[0..i]) |prior| if (prior.kind == declaration.kind) return error.DuplicateDomain;
        if (schema.domainOwner(declaration.kind) == .forest) {
            const actual = kindCountRuntime(view, declaration.kind) catch return error.InvalidFormat;
            if (actual != declaration.count) return error.CrossSectionMismatch;
        }
    }
}

fn declaredKindCount(declarations: []const KindDomain, kind: schema.Kind) ?usize {
    for (declarations) |declaration| if (declaration.kind == kind) return declaration.count;
    return null;
}

fn kindCountRuntime(view: *const forest.View, kind: schema.Kind) forest.Error!usize {
    return switch (kind) {
        inline else => |known| view.kindCount(known),
    };
}

fn validate(allocator: std.mem.Allocator, input: Input, options: Options) Error!Prepared {
    if (options.max_section_bytes == 0) return error.InvalidOptions;

    var sections: [max_sections]?Section = .{null} ** max_sections;
    for (input.sections) |section| {
        try checkedSectionBytes(section.bytes, options.max_section_bytes);
        const slot = tagIndex(section.tag) orelse return error.UnknownSection;
        if (sections[slot] != null) return error.DuplicateSection;
        sections[slot] = section;
    }
    for ([_]usize{ 0, 1, 3 }) |slot| if (sections[slot] == null) return error.MissingRequiredSection;

    // Every payload is opened and verified before the container exists.  The
    // container's page authentication is still required by every mapped
    // snapshot reader after assembly; this pass only validates compiler input.
    const automaton_view = automaton.View.open(sections[0].?.bytes) catch |err| switch (err) {
        error.BadMagic => return error.InvalidFormat,
        else => return err,
    };
    try automaton_view.verifyWithAllocator(allocator);
    const forest_view = forest.View.open(sections[1].?.bytes) catch |err| switch (err) {
        error.BadMagic => return error.InvalidFormat,
        else => return err,
    };
    try forest_view.verify();
    const prose_view = try grammar.View.open(sections[3].?.bytes, options.grammar_limits);
    try prose_view.verify();

    // Optional payloads are validated by their actual owners. Magic-only
    // acceptance lets malformed lengths, tables and semantic rows cross the
    // assembly boundary and merely postpones a deterministic compiler error.
    var concept_count: ?usize = null;
    if (sections[4]) |section| {
        const view = axes.ViewFor(axes.Normalized).open(section.bytes) catch return error.InvalidFormat;
        view.verify(allocator) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidFormat;
        if (view.entry_count != automaton_view.entry_count) return error.CrossSectionMismatch;
    }
    if (sections[5]) |section| {
        const view = axes.ViewFor(axes.Phonetic).open(section.bytes) catch return error.InvalidFormat;
        view.verify(allocator) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidFormat;
        if (view.entry_count != automaton_view.entry_count) return error.CrossSectionMismatch;
    }
    if (sections[6]) |section| {
        const view = axes.ViewFor(axes.Reverse).open(section.bytes) catch return error.InvalidFormat;
        view.verify(allocator) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidFormat;
        if (view.entry_count != automaton_view.entry_count) return error.CrossSectionMismatch;
    }
    if (sections[7]) |section| {
        const view = terms.View.open(section.bytes) catch return error.InvalidFormat;
        view.verify(allocator) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidFormat;
        if (view.entry_count != automaton_view.entry_count) return error.CrossSectionMismatch;
    }
    if (sections[8]) |section| {
        var view = concepts.ConceptView.open(section.bytes) catch return error.InvalidFormat;
        view.verify() catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidFormat;
        concept_count = view.conceptCount();
    }
    if (sections[9]) |section| {
        var view = relations.View.open(section.bytes) catch return error.InvalidFormat;
        view.verify() catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidFormat;
    }
    if (sections[10]) |section| {
        const view = cold.View.open(section.bytes) catch return error.InvalidFormat;
        view.verifyEncoded() catch return error.InvalidFormat;
    }
    if (sections[12]) |section| {
        var view = rich_content.View.open(section.bytes, options.grammar_limits) catch return error.InvalidFormat;
        view.verify(allocator) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidFormat;
        for (0..view.element_count) |index| if ((view.element(@enumFromInt(index)) catch return error.InvalidFormat).semantic) |binding| {
            const count: ?usize = switch (schema.domainOwner(binding.kind)) {
                .forest => kindCountRuntime(&forest_view, binding.kind) catch return error.InvalidFormat,
                .concept => concept_count orelse declaredKindCount(options.kind_domains, binding.kind),
                .interlingual, .external => declaredKindCount(options.kind_domains, binding.kind),
            };
            if (count) |bound| {
                if (binding.rank >= bound) return error.CrossSectionMismatch;
            }
        };
    }

    const entries = @as(usize, automaton_view.entry_count);
    if (entries != forest_view.rootCount()) return error.CrossSectionMismatch;
    if (options.prose_alignment == .one_per_entry and entries != prose_view.item_count)
        return error.CrossSectionMismatch;
    try validateProseDomains(prose_view.item_count, options);
    try validateKindDomains(&forest_view, options.kind_domains);
    // A canonical L4TX payload is a checked cross-section contract, not an
    // optional validation hint. Once a producer declares prose domains, the
    // mapping must be durably present in the container.
    const requires_text_map = options.prose_domains.len != 0 or options.require_prose_domains;
    if (requires_text_map) {
        const columns = sections[2] orelse return error.MissingTextMap;
        if (columns.bytes.len < text_index.magic.len or !std.mem.eql(u8, columns.bytes[0..text_index.magic.len], text_index.magic))
            return error.MissingTextMap;
    }
    if (sections[2]) |columns| {
        const map = text_index.View.open(columns.bytes) catch return error.InvalidOptions;
        map.validate(&forest_view, prose_view.item_count) catch |err| switch (err) {
            error.CrossSectionMismatch => return error.CrossSectionMismatch,
            error.OutOfMemory => return error.OutOfMemory,
            error.Overflow => return error.Overflow,
            else => return error.InvalidOptions,
        };
    }

    var canonical: [max_sections]container.Input = undefined;
    var count: usize = 0;
    for (sections) |maybe_section| {
        if (maybe_section) |section| {
            canonical[count] = .{ .tag = section.tag, .bytes = section.bytes, .flags = section.flags };
            count += 1;
        }
    }
    // `tagIndex` is intentionally the canonical slot order.  It is not the
    // numeric order of an arbitrary enum value and therefore remains stable
    // if a future section tag is inserted into the enum.
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const value = canonical[i];
        var j = i;
        while (j != 0 and @intFromEnum(canonical[j - 1].tag) > @intFromEnum(value.tag)) : (j -= 1)
            canonical[j] = canonical[j - 1];
        canonical[j] = value;
    }

    if (options.prose_domains.len > schema.kind_count or options.kind_domains.len > schema.kind_count)
        return error.InvalidOptions;
    var stored_prose_domains: [schema.kind_count]ProseDomain = undefined;
    @memset(&stored_prose_domains, undefined);
    @memcpy(stored_prose_domains[0..options.prose_domains.len], options.prose_domains);
    var stored_kind_domains: [schema.kind_count]KindDomain = undefined;
    @memset(&stored_kind_domains, undefined);
    @memcpy(stored_kind_domains[0..options.kind_domains.len], options.kind_domains);

    return .{
        .automaton_ = automaton_view,
        .forest_ = forest_view,
        .prose_ = prose_view,
        .sections_ = canonical,
        .section_count_ = count,
        .schema_digest_ = options.expected_schema orelse schema.digest(),
        .entry_count_ = automaton_view.entry_count,
        .accepted_count_ = automaton_view.accepted_count,
        .prose_item_count_ = prose_view.item_count,
        .one_per_entry_ = options.prose_alignment == .one_per_entry,
        .requires_text_map_ = requires_text_map,
        .prose_domains_ = stored_prose_domains,
        .prose_domain_count_ = options.prose_domains.len,
        .kind_domains_ = stored_kind_domains,
        .kind_domain_count_ = options.kind_domains.len,
        .max_section_bytes_ = options.max_section_bytes,
        .grammar_limits_ = options.grammar_limits,
        .stamp_ = prepared_stamp,
    };
}

fn ledger(bytes: []const u8) Error!ByteLedger {
    const HeaderWire = wire.Layout(container.Header);
    const DescriptorWire = wire.Layout(container.Descriptor);
    const header = try HeaderWire.read(bytes, 0);
    const directory_len = try wire.cast(usize, header.directory_length);
    const digest_len = try wire.cast(usize, header.digest_length);
    var cursor = try wire.alignForward(
        try wire.add(container.header_size, directory_len),
        container.alignment,
    );
    var section_bytes: usize = 0;
    var padding: usize = cursor - try wire.add(container.header_size, directory_len);
    for (0..header.section_count) |index| {
        const descriptor = try DescriptorWire.read(bytes, container.header_size + index * container.descriptor_size);
        const offset = try wire.cast(usize, descriptor.offset);
        const length = try wire.cast(usize, descriptor.length);
        if (offset < cursor) return error.InvalidDirectory;
        padding = try wire.add(padding, offset - cursor);
        section_bytes = try wire.add(section_bytes, length);
        cursor = try wire.add(offset, length);
    }
    const digest_offset = try wire.cast(usize, header.digest_offset);
    if (digest_offset < cursor) return error.InvalidDigestTable;
    padding = try wire.add(padding, digest_offset - cursor);
    const total = try wire.cast(usize, header.file_length);
    const result = ByteLedger{
        .header = container.header_size,
        .directory = directory_len,
        .section_bytes = section_bytes,
        .alignment_padding = padding,
        .page_digests = digest_len,
        .total_bytes = total,
    };
    if (result.total() != total or total != bytes.len) return error.LengthMismatch;
    return result;
}

pub fn compilePrepared(allocator: std.mem.Allocator, prepared: Prepared) Error!Owned {
    if (prepared.stamp_ != prepared_stamp or prepared.section_count_ < 3 or prepared.section_count_ > max_sections)
        return error.InvalidPlan;
    if (prepared.prose_domain_count_ > schema.kind_count or
        prepared.kind_domain_count_ > schema.kind_count or
        prepared.max_section_bytes_ == 0)
        return error.InvalidPlan;

    // A plan borrows its section slices.  Revalidate at the consuming
    // boundary: callers may have mutated those buffers, and a public value
    // type can otherwise be forged with `undefined` even though its fields
    // are private.  This second pass also rechecks all cross-section and
    // optional L4TX invariants before any output bytes are allocated.
    const replay_options = Options{
        .expected_schema = prepared.schema_digest_,
        .max_section_bytes = prepared.max_section_bytes_,
        .grammar_limits = prepared.grammar_limits_,
        .prose_alignment = if (prepared.one_per_entry_) .one_per_entry else .independent,
        .prose_domains = prepared.prose_domains_[0..prepared.prose_domain_count_],
        .require_prose_domains = prepared.requires_text_map_,
        .kind_domains = prepared.kind_domains_[0..prepared.kind_domain_count_],
    };
    var replay_sections: [max_sections]Section = undefined;
    for (prepared.inputs(), 0..) |section, index| replay_sections[index] = .{ .tag = section.tag, .bytes = section.bytes, .flags = section.flags };
    const replay = validate(allocator, .{ .sections = replay_sections[0..prepared.section_count_] }, replay_options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPlan,
    };
    if (replay.entry_count_ != prepared.entry_count_ or
        replay.accepted_count_ != prepared.accepted_count_ or
        replay.prose_item_count_ != prepared.prose_item_count_ or
        !std.mem.eql(u8, &replay.schema_digest_, &prepared.schema_digest_) or
        replay.section_count_ != prepared.section_count_)
        return error.InvalidPlan;

    return emitValidated(allocator, replay);
}

fn emitValidated(allocator: std.mem.Allocator, prepared: Prepared) Error!Owned {
    const bytes = try container.build(allocator, prepared.schema_digest_, prepared.inputs());
    errdefer allocator.free(bytes);

    // Re-open the just-built envelope so the exact wire bounds used for the
    // ledger are checked by the same parser that hosts use for mapped files.
    const envelope = try container.Container.open(bytes, &.{});
    const measured = try ledger(bytes);
    var expected_section_bytes: usize = 0;
    for (prepared.inputs()) |section| expected_section_bytes = try wire.add(expected_section_bytes, section.bytes.len);
    if (measured.section_bytes != expected_section_bytes) return error.LengthMismatch;
    _ = envelope;

    return .{
        .allocator = allocator,
        .bytes = bytes,
        .ledger = measured,
        .schema_digest = prepared.schema_digest_,
        .entry_count = prepared.entry_count_,
        .accepted_count = prepared.accepted_count_,
        .prose_item_count = prepared.prose_item_count_,
    };
}

/// Prepare the complete assembly plan without allocating or retaining a
/// pointer to a local descriptor array.  The payloads are borrowed until the
/// returned plan is consumed by `compilePrepared`.
pub fn prepare(allocator: std.mem.Allocator, input: Input, options: Options) Error!Prepared {
    return validate(allocator, input, options);
}

/// Validate compact payloads and emit a canonical authenticated container.
/// The returned bytes are owned by the caller and remain independent of all
/// input payload lifetimes.
pub fn compile(allocator: std.mem.Allocator, input: Input, options: Options) Error!Owned {
    const prepared = try prepare(allocator, input, options);
    return emitValidated(allocator, prepared);
}

/// Publish the three required sections through the ergonomic value API.
pub fn build(allocator: std.mem.Allocator, parts: Parts, options: Options) Error!Owned {
    return buildWithExtras(allocator, parts, &.{}, options);
}

/// Publish optional sections (columns, relations, cold indexes, or metadata)
/// in addition to the three hot sections.  The caller's order is irrelevant;
/// descriptors are copied into the prepared value and sorted by wire tag.
pub fn buildWithExtras(
    allocator: std.mem.Allocator,
    parts: Parts,
    extras: []const Section,
    options: Options,
) Error!Owned {
    if (extras.len > max_sections - 3) return error.OptionalSectionConflict;
    var sections: [max_sections]Section = undefined;
    sections[0] = .{ .tag = .automaton, .bytes = parts.automaton };
    sections[1] = .{ .tag = .forest, .bytes = parts.forest };
    sections[2] = .{ .tag = .prose, .bytes = parts.prose };
    for (extras, 0..) |extra, index| sections[index + 3] = .{ .tag = extra.tag, .bytes = extra.bytes, .flags = extra.flags };
    return compile(allocator, .{ .sections = sections[0 .. extras.len + 3] }, options);
}

test "compiler canonicalizes compact payload order and reports primary counts separately" {
    const allocator = std.testing.allocator;
    var automaton_builder = automaton.Builder.init(allocator);
    defer automaton_builder.deinit();
    try automaton_builder.addEntry("cat", 2);
    try automaton_builder.addForm("cater", &.{0});
    try automaton_builder.addForm("cats", &.{ 0, 2 });
    try automaton_builder.addEntry("dog", 1);
    var automaton_owned = try automaton_builder.finish();
    defer automaton_owned.deinit();

    const nodes = [_]forest.NodeRecord{
        .{ .kind = .entry, .subtree_size = 1, .parent = null },
        .{ .kind = .entry, .subtree_size = 1, .parent = null },
        .{ .kind = .entry, .subtree_size = 1, .parent = null },
    };
    const roots = [_]forest.RootInput{
        .{ .start = @enumFromInt(0) },
        .{ .start = @enumFromInt(1) },
        .{ .start = @enumFromInt(2) },
    };
    var forest_owned = try forest.encode(allocator, &nodes, &roots);
    defer forest_owned.deinit();

    const prose_inputs = [_]grammar.ItemInput{
        .{ .text = "first" },
        .{ .text = "second" },
        .{ .text = "third" },
    };
    var prose_owned = try grammar.build(allocator, &prose_inputs, .{});
    defer prose_owned.deinit();

    const unordered = [_]Section{
        .{ .tag = .prose, .bytes = prose_owned.bytes },
        .{ .tag = .forest, .bytes = forest_owned.bytes },
        .{ .tag = .automaton, .bytes = automaton_owned.bytes },
    };
    const ordered = [_]Section{
        .{ .tag = .automaton, .bytes = automaton_owned.bytes },
        .{ .tag = .forest, .bytes = forest_owned.bytes },
        .{ .tag = .prose, .bytes = prose_owned.bytes },
    };
    var first = try compile(allocator, .{ .sections = &unordered }, .{});
    defer first.deinit();
    var second = try compile(allocator, .{ .sections = &ordered }, .{});
    defer second.deinit();

    try std.testing.expectEqualSlices(u8, first.bytes, second.bytes);
    try std.testing.expectEqual(@as(u32, 3), first.entry_count);
    try std.testing.expectEqual(@as(u32, 4), first.accepted_count);
    try std.testing.expectEqual(@as(usize, 3), first.prose_item_count);
    try std.testing.expectEqual(first.bytes.len, first.ledger.total());
    try std.testing.expectEqual(first.bytes.len, first.ledger.total_bytes);
    try std.testing.expectEqual(
        automaton_owned.bytes.len + forest_owned.bytes.len + prose_owned.bytes.len,
        first.ledger.section_bytes,
    );
    try std.testing.expect(first.ledger.page_digests != 0);
    std.debug.print("LEX4_COMPILER_LEDGER bytes={} header={} directory={} sections={} padding={} page_digests={} entries={} accepted={} prose={}\n", .{
        first.bytes.len,
        first.ledger.header,
        first.ledger.directory,
        first.ledger.section_bytes,
        first.ledger.alignment_padding,
        first.ledger.page_digests,
        first.entry_count,
        first.accepted_count,
        first.prose_item_count,
    });
}

test "compiler validates all components and declared cross-section cardinality" {
    const allocator = std.testing.allocator;
    var automaton_builder = automaton.Builder.init(allocator);
    defer automaton_builder.deinit();
    try automaton_builder.addEntry("a", 1);
    try automaton_builder.addEntry("b", 1);
    var automaton_owned = try automaton_builder.finish();
    defer automaton_owned.deinit();

    const one_node = [_]forest.NodeRecord{.{ .kind = .entry, .subtree_size = 1, .parent = null }};
    var forest_owned = try forest.encode(allocator, &one_node, &.{.{ .start = @enumFromInt(0) }});
    defer forest_owned.deinit();
    const prose_inputs = [_]grammar.ItemInput{ .{ .text = "first" }, .{ .text = "second" }, .{ .text = "third" } };
    var prose_owned = try grammar.build(allocator, &prose_inputs, .{});
    defer prose_owned.deinit();

    const sections = [_]Section{
        .{ .tag = .automaton, .bytes = automaton_owned.bytes },
        .{ .tag = .forest, .bytes = forest_owned.bytes },
        .{ .tag = .prose, .bytes = prose_owned.bytes },
    };
    var malformed_automaton = try allocator.dupe(u8, automaton_owned.bytes);
    defer allocator.free(malformed_automaton);
    malformed_automaton[0] = 'X';
    try std.testing.expectError(error.InvalidFormat, compile(allocator, .{ .sections = &.{
        .{ .tag = .automaton, .bytes = malformed_automaton }, sections[1], sections[2],
    } }, .{}));
    try std.testing.expectError(error.CrossSectionMismatch, compile(allocator, .{ .sections = &sections }, .{}));
    const asymmetric_nodes = [_]forest.NodeRecord{
        .{ .kind = .entry, .subtree_size = 1, .parent = null },
        .{ .kind = .entry, .subtree_size = 2, .parent = null },
        .{ .kind = .sense, .subtree_size = 1, .parent = @enumFromInt(1) },
    };
    const asymmetric_roots = [_]forest.RootInput{ .{ .start = @enumFromInt(0) }, .{ .start = @enumFromInt(1) } };
    var asymmetric_forest = try forest.encode(allocator, &asymmetric_nodes, &asymmetric_roots);
    defer asymmetric_forest.deinit();
    const asymmetric_sections = [_]Section{
        .{ .tag = .automaton, .bytes = automaton_owned.bytes },
        .{ .tag = .forest, .bytes = asymmetric_forest.bytes },
        .{ .tag = .prose, .bytes = prose_owned.bytes },
    };
    // The default policy keeps prose in its own rank domain.  A snapshot may
    // have zero, one, or many prose rows per entry until a producer declares
    // a mapping policy explicitly.
    var independent = try compile(allocator, .{ .sections = &asymmetric_sections }, .{});
    defer independent.deinit();
    try std.testing.expectEqual(@as(usize, 3), independent.prose_item_count);
    try std.testing.expectError(error.CrossSectionMismatch, compile(allocator, .{ .sections = &asymmetric_sections }, .{ .prose_alignment = .one_per_entry }));
    try std.testing.expectError(error.MissingRequiredSection, compile(allocator, .{ .sections = sections[0..2] }, .{}));
    try std.testing.expectError(error.EmptySection, compile(allocator, .{ .sections = &.{
        sections[0], sections[1], .{ .tag = .prose, .bytes = &.{} },
    } }, .{}));
    try std.testing.expectError(error.DuplicateSection, compile(allocator, .{ .sections = &.{
        sections[0], sections[0], sections[1], sections[2],
    } }, .{}));
    try std.testing.expectError(error.UnknownSection, compile(allocator, .{ .sections = &.{
        sections[0], sections[1], sections[2], .{ .tag = @enumFromInt(0xffff_ffff), .bytes = "not required" },
    } }, .{}));
}

test "compiled container authenticates pages before snapshot access" {
    const allocator = std.testing.allocator;
    var automaton_builder = automaton.Builder.init(allocator);
    defer automaton_builder.deinit();
    try automaton_builder.addEntry("a", 1);
    var automaton_owned = try automaton_builder.finish();
    defer automaton_owned.deinit();
    const nodes = [_]forest.NodeRecord{.{ .kind = .entry, .subtree_size = 1, .parent = null }};
    var forest_owned = try forest.encode(allocator, &nodes, &.{.{ .start = @enumFromInt(0) }});
    defer forest_owned.deinit();
    const prose_inputs = [_]grammar.ItemInput{.{ .text = "one" }};
    var prose_owned = try grammar.build(allocator, &prose_inputs, .{});
    defer prose_owned.deinit();
    const sections = [_]Section{
        .{ .tag = .automaton, .bytes = automaton_owned.bytes },
        .{ .tag = .forest, .bytes = forest_owned.bytes },
        .{ .tag = .prose, .bytes = prose_owned.bytes },
    };
    var compiled = try compile(allocator, .{ .sections = &sections }, .{});
    defer compiled.deinit();

    var damaged = try allocator.dupe(u8, compiled.bytes);
    defer allocator.free(damaged);
    const DescriptorWire = wire.Layout(container.Descriptor);
    const descriptor = try DescriptorWire.read(damaged, container.header_size);
    const payload_offset = try wire.cast(usize, descriptor.offset);
    damaged[payload_offset] ^= 1;

    var envelope = try container.Container.open(damaged, &.{});
    var section = try envelope.find(.automaton);
    try std.testing.expectError(error.IntegrityFailure, section.bytes(0, 1));
}

fn allocationFailureCompile(allocator: std.mem.Allocator) !void {
    var automaton_builder = automaton.Builder.init(allocator);
    defer automaton_builder.deinit();
    try automaton_builder.addEntry("a", 1);
    var automaton_owned = try automaton_builder.finish();
    defer automaton_owned.deinit();
    const nodes = [_]forest.NodeRecord{.{ .kind = .entry, .subtree_size = 1, .parent = null }};
    var forest_owned = try forest.encode(allocator, &nodes, &.{.{ .start = @enumFromInt(0) }});
    defer forest_owned.deinit();
    const prose_inputs = [_]grammar.ItemInput{.{ .text = "one" }};
    var prose_owned = try grammar.build(allocator, &prose_inputs, .{});
    defer prose_owned.deinit();
    const sections = [_]Section{
        .{ .tag = .automaton, .bytes = automaton_owned.bytes },
        .{ .tag = .forest, .bytes = forest_owned.bytes },
        .{ .tag = .prose, .bytes = prose_owned.bytes },
    };
    var compiled = try compile(allocator, .{ .sections = &sections }, .{});
    compiled.deinit();
}

test "compiler owns output and releases every allocation on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureCompile, .{});
}

test "key records sort entries and remap form targets without losing identity" {
    const records = [_]KeyRecord{
        .{ .entry = .{ .key = "dog", .multiplicity = 1 } },
        // `cat` is a two-rank homograph. The form deliberately names the
        // second rank; the old integer shorthand would be rejected here.
        .{ .form = .{ .key = "cats", .rank_targets = &.{.{ .source_entry = 1, .first = 1 }} } },
        .{ .form = .{ .key = "dogs", .targets = &.{0} } },
        .{ .entry = .{ .key = "cat", .multiplicity = 2 } },
    };
    var owned = try buildAutomaton(std.testing.allocator, &records);
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);
    try view.verifyWithAllocator(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 3), view.entry_count);
    var hit = (try view.exact("cat")).?;
    try std.testing.expectEqual(@as(u32, 2), hit.entry_range.?.len());
    hit = (try view.exact("cats")).?;
    try std.testing.expectEqual(@as(u32, 1), hit.targets.len());
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(try hit.targets.target(0)));
    hit = (try view.exact("dogs")).?;
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(try hit.targets.target(0)));
}

test "prose and kind domains are explicit and optional sections round-trip" {
    const allocator = std.testing.allocator;
    var keys = automaton.Builder.init(allocator);
    defer keys.deinit();
    try keys.addEntry("a", 1);
    var auto = try keys.finish();
    defer auto.deinit();
    var forest_builder = forest.Builder.init(allocator);
    defer forest_builder.deinit();
    const root = try forest_builder.addRoot("a", .entry);
    const sense = try forest_builder.addChild(root, .sense);
    _ = try forest_builder.addChild(sense, .definition);
    _ = try forest_builder.addChild(sense, .example);
    var tree = try forest_builder.build();
    defer tree.deinit();
    const prose_items = [_]grammar.ItemInput{ .{ .text = "definition" }, .{ .text = "example" } };
    var prose = try grammar.build(allocator, &prose_items, .{});
    defer prose.deinit();
    const structure = try forest.View.open(tree.bytes);
    var text_map = try buildTextMap(allocator, &structure, prose_items.len, &.{
        .{ .kind = .definition, .first = 0, .count = 1 },
        .{ .kind = .example, .first = 1, .count = 1 },
    });
    defer text_map.deinit();
    const extras = [_]Section{
        .{ .tag = .metadata, .bytes = "meta" },
        .{ .tag = .columns, .bytes = text_map.bytes },
    };
    var published = try buildWithExtras(allocator, .{ .automaton = auto.bytes, .forest = tree.bytes, .prose = prose.bytes }, &extras, .{
        .prose_domains = &.{ .{ .kind = .definition, .first = 0, .count = 1 }, .{ .kind = .example, .first = 1, .count = 1 } },
        .kind_domains = &.{.{ .kind = .entry, .count = 1 }},
    });
    defer published.deinit();
    var envelope = try container.Container.open(published.bytes, &.{});
    _ = try envelope.find(.columns);
    _ = try envelope.find(.metadata);
    try std.testing.expectEqual(@as(usize, 2), published.prose_item_count);
    try std.testing.expectError(error.CrossSectionMismatch, buildWithExtras(allocator, .{ .automaton = auto.bytes, .forest = tree.bytes, .prose = prose.bytes }, &extras, .{
        .prose_domains = &.{.{ .kind = .definition, .count = 1 }},
    }));
}

fn prepareFromStackDescriptors(
    allocator: std.mem.Allocator,
    parts: Parts,
    options: Options,
) Error!Prepared {
    // This local array is the exact shape that used to escape through a
    // `[]const Input` field. A returned Prepared must copy descriptors before
    // this function returns.
    const local = [_]Section{
        .{ .tag = .prose, .bytes = parts.prose },
        .{ .tag = .forest, .bytes = parts.forest },
        .{ .tag = .automaton, .bytes = parts.automaton },
    };
    return prepare(allocator, .{ .sections = &local }, options);
}

test "prepared assembly owns descriptor storage rather than a stack slice" {
    const allocator = std.testing.allocator;
    var keys = automaton.Builder.init(allocator);
    defer keys.deinit();
    try keys.addEntry("safe", 1);
    var auto = try keys.finish();
    defer auto.deinit();
    const nodes = [_]forest.NodeRecord{.{ .kind = .entry, .subtree_size = 1, .parent = null }};
    var tree = try forest.encode(allocator, &nodes, &.{.{ .start = @enumFromInt(0) }});
    defer tree.deinit();
    var prose = try grammar.build(allocator, &.{.{ .text = "stable" }}, .{});
    defer prose.deinit();
    var plan = try prepareFromStackDescriptors(allocator, .{ .automaton = auto.bytes, .forest = tree.bytes, .prose = prose.bytes }, .{});
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 3), plan.inputs().len);
    var compiled = try plan.emit(allocator);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(u32, 1), compiled.entry_count);
}

fn allocationFailureKeys(allocator: std.mem.Allocator) !void {
    const records = [_]KeyRecord{
        .{ .entry = .{ .key = "dog" } },
        .{ .form = .{ .key = "dogs", .targets = &.{0} } },
        .{ .entry = .{ .key = "cat", .multiplicity = 2 } },
    };
    var owned = try buildAutomaton(allocator, &records);
    owned.deinit();
}

test "key compiler releases temporary rank maps on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureKeys, .{});
}

test "typed prose map covers asymmetric forest domains without root equality" {
    const allocator = std.testing.allocator;
    var trees = forest.Builder.init(allocator);
    defer trees.deinit();
    const root = try trees.addRoot("root", .entry);
    const sense = try trees.addChild(root, .sense);
    _ = try trees.addChild(sense, .definition);
    var tree = try trees.build();
    defer tree.deinit();
    var map = try buildTextMap(allocator, &tree.view, 1, &.{.{ .kind = .definition, .first = 0, .count = 1 }});
    defer map.deinit();
    try std.testing.expectEqualStrings("L4TX", map.bytes[0..4]);
    // One active domain and one nonzero constant field. The generated table
    // omits both zero coordinates and stores no row payload.
    try std.testing.expectEqual(@as(usize, 64), map.bytes.len);
    const view = try text_index.View.open(map.bytes);
    try std.testing.expectEqualDeep(text_index.Span{ .first = 0, .count = 1 }, try view.span(.definition, @enumFromInt(0)));
}

test "homograph form shorthand is rejected and explicit ranges preserve the selected rank" {
    const shorthand = [_]KeyRecord{
        .{ .entry = .{ .key = "cat", .multiplicity = 2 } },
        .{ .form = .{ .key = "cats", .targets = &.{0} } },
    };
    try std.testing.expectError(error.InvalidTargets, buildAutomaton(std.testing.allocator, &shorthand));

    const explicit = [_]KeyRecord{
        .{ .entry = .{ .key = "cat", .multiplicity = 2 } },
        .{ .form = .{ .key = "cats", .rank_targets = &.{.{ .source_entry = 0, .first = 1, .count = 1 }} } },
    };
    var owned = try buildAutomaton(std.testing.allocator, &explicit);
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);
    const hit = (try view.exact("cats")).?;
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(try hit.targets.target(0)));
}

test "record assembly requires a source-order proof for prebuilt forests" {
    const allocator = std.testing.allocator;
    const records = [_]KeyRecord{
        .{ .entry = .{ .key = "dog" } },
        .{ .entry = .{ .key = "cat" } },
    };
    var trees = forest.Builder.init(allocator);
    defer trees.deinit();
    _ = try trees.addRoot("cat", .entry);
    _ = try trees.addRoot("dog", .entry);
    var tree = try trees.build();
    defer tree.deinit();
    var prose = try grammar.build(allocator, &.{ .{ .text = "cat" }, .{ .text = "dog" } }, .{});
    defer prose.deinit();

    // The forest is already in canonical key order, which is source ordinals
    // [1, 0] after the compiler sorts the records.
    var published = try buildFromRecords(allocator, .{
        .keys = &records,
        .forest = tree.bytes,
        .prose = prose.bytes,
        .forest_source_entries = &.{ 1, 0 },
    }, &.{}, .{});
    defer published.deinit();
    try std.testing.expectError(error.ForestAlignmentRequired, buildFromRecords(allocator, .{
        .keys = &records,
        .forest = tree.bytes,
        .prose = prose.bytes,
    }, &.{}, .{}));
    try std.testing.expectError(error.InvalidForestAlignment, buildFromRecords(allocator, .{
        .keys = &records,
        .forest = tree.bytes,
        .prose = prose.bytes,
        .forest_source_entries = &.{ 0, 1 },
    }, &.{}, .{}));
}

test "prepared plans reject forged values and prose declarations require durable L4TX" {
    var forged: Prepared = undefined;
    forged.stamp_ = 0;
    try std.testing.expectError(error.InvalidPlan, compilePrepared(std.testing.allocator, forged));

    const allocator = std.testing.allocator;
    var keys = automaton.Builder.init(allocator);
    defer keys.deinit();
    try keys.addEntry("word", 1);
    var auto = try keys.finish();
    defer auto.deinit();
    const nodes = [_]forest.NodeRecord{.{ .kind = .entry, .subtree_size = 1, .parent = null }};
    var tree = try forest.encode(allocator, &nodes, &.{.{ .start = @enumFromInt(0) }});
    defer tree.deinit();
    var prose = try grammar.build(allocator, &.{.{ .text = "definition" }}, .{});
    defer prose.deinit();
    const sections = [_]Section{
        .{ .tag = .automaton, .bytes = auto.bytes },
        .{ .tag = .forest, .bytes = tree.bytes },
        .{ .tag = .prose, .bytes = prose.bytes },
    };
    try std.testing.expectError(error.MissingTextMap, compile(allocator, .{ .sections = &sections }, .{
        .prose_domains = &.{.{ .kind = .definition, .first = 0, .count = 1 }},
    }));
    try std.testing.expectError(error.InvalidFormat, compile(allocator, .{ .sections = &.{
        sections[0], sections[1], sections[2], .{ .tag = .terms, .bytes = "not-a-term-section" },
    } }, .{}));
}
