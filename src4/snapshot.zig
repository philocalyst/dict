//! The borrowed, authenticated reader boundary for a compiled LEX4 snapshot.
//!
//! `Snapshot.open` validates only the container envelope and schema digest.
//! A section is authenticated when its view is first touched; prose keeps the
//! finer-grained `SectionSource` boundary so cold record reads authenticate
//! only the pages they intersect. The snapshot owns no mapped bytes or tables.

const std = @import("std");
const automaton = @import("automaton.zig");
const container = @import("container.zig");
const forest = @import("forest.zig");
const grammar = @import("grammar.zig");
const rank = @import("rank.zig");
const schema = @import("schema.zig");
const text_index = @import("text_index.zig");
const axes = @import("axes.zig");
const term_index = @import("terms.zig");
const cold = @import("cold.zig");
// Keep the module namespace distinct from Snapshot.concepts(), whose short
// spelling is part of the public API.
const concept_index = @import("concepts.zig");
// Likewise keep the public Snapshot.relations() method from shadowing the
// implementation namespace used by its stable cache type.
const relation_index = @import("relations.zig");
const rich_content = @import("rich_content.zig");

const AuthenticatedProseView = grammar.ViewFor(container.SectionSource);

pub const Kind = schema.Kind;
pub const Node = schema.Node;
pub const Rank = schema.Rank;
pub const NodeSet = rank.NodeSet;
pub const Interval = rank.Interval;
pub const EntryRank = Rank(.entry);
pub const RenderFrame = grammar.Frame;

pub const Error = container.Error || automaton.Error || forest.Error || grammar.Error || cold.Error || error{
    SchemaMismatch,
    CorruptSection,
    CrossSectionMismatch,
    InvalidDomain,
    MissingTextMap,
    InvalidTextMap,
    InvalidOptionalSection,
    LimitExceeded,
    QueryRequiresVerification,
};

/// A grammar item is a separate rank domain. It is never an `EntryRank`:
/// prose can contain zero, one, or many rows per entry.
pub const ProseRank = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn fromIndex(index: usize) Error!ProseRank {
        // maxInt is the reserved `.none` sentinel, never a valid row.  Do
        // this check before the cast so a 32-bit caller cannot manufacture a
        // handle that looks like absence.
        if (index >= std.math.maxInt(u32)) return error.Overflow;
        return @enumFromInt(std.math.cast(u32, index) orelse return error.Overflow);
    }
};

pub const Limits = struct {
    max_file_bytes: usize = std.math.maxInt(usize),
    max_section_bytes: usize = std.math.maxInt(usize),
    max_entries: usize = std.math.maxInt(u32),
    max_prose_items: usize = std.math.maxInt(u32),
    grammar: grammar.Limits = .{},
};

pub const Options = struct {
    limits: Limits = .{},
    expected_schema: ?[container.digest_size]u8 = null,
};

pub const Section = struct {
    tag: container.Tag,
    bytes: []const u8,

    pub fn len(self: Section) usize {
        return self.bytes.len;
    }
};

fn mapProseError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.OutputTooSmall => error.OutputTooSmall,
        error.OutputLimitExceeded => error.OutputLimitExceeded,
        error.StackLimitExceeded => error.StackLimitExceeded,
        error.DecompressionBomb => error.DecompressionBomb,
        error.IntegrityFailure => error.IntegrityFailure,
        error.Truncated => error.Truncated,
        error.InvalidItemRange => error.InvalidItemRange,
        error.IndexOutOfBounds => error.IndexOutOfBounds,
        else => error.CorruptSection,
    };
}

fn mapTextIndexError(err: anyerror) Error {
    return switch (err) {
        error.CrossSectionMismatch => error.CrossSectionMismatch,
        error.OutOfMemory => error.OutOfMemory,
        error.Overflow => error.Overflow,
        error.RankOutOfRange => error.RankOutOfRange,
        error.Truncated => error.InvalidTextMap,
        error.InvalidFormat, error.UnsupportedVersion, error.InvalidDomain, error.MissingDomain, error.DuplicateDomain => error.InvalidTextMap,
        else => error.InvalidTextMap,
    };
}

fn mapOptionalError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.LimitExceeded => error.LimitExceeded,
        error.CorruptChecksum => error.CorruptChecksum,
        error.IntegrityFailure => error.IntegrityFailure,
        error.Truncated => error.Truncated,
        error.InvalidOptionalSection => error.InvalidOptionalSection,
        else => error.InvalidOptionalSection,
    };
}

/// `forest.View.kindCount` is intentionally comptime-ranked.  Keep the one
/// runtime boundary generated from the schema so limits cannot be bypassed by
/// an untrusted dynamic kind while the public API remains strongly typed.
fn kindCountRuntime(view: *const forest.View, kind: Kind) Error!usize {
    return switch (kind) {
        inline else => |known| view.kindCount(known),
    };
}

pub const Directory = struct {
    snapshot: *Snapshot,

    pub fn contains(self: Directory, tag: container.Tag) bool {
        _ = self.snapshot.envelope.find(tag) catch return false;
        return true;
    }

    pub fn source(self: Directory, tag: container.Tag) Error!container.SectionSource {
        return self.snapshot.sectionSource(tag);
    }

    pub fn read(self: Directory, tag: container.Tag) Error!Section {
        return self.snapshot.section(tag);
    }
};

pub const Snapshot = struct {
    /// All storage is borrowed. `bytes` must remain mapped and immutable for
    /// the lifetime of this value and every handle/iterator returned from it.
    /// The caller owns the `trust` bitmap passed to `open`; the container
    /// retains its address to memoize authenticated pages, so that bitmap
    /// must also remain live and writable until the snapshot is discarded.
    /// Moving a Snapshot after borrowing a handle invalidates the handle's
    /// back-pointer; keep the snapshot at a stable address (normally `var`).
    bytes: []const u8,
    envelope: container.Container,
    limits: Limits,

    // These are stable borrowed values, not allocation caches. In particular,
    // automaton.Hit.TargetList stores a pointer to its View.
    automaton_view: ?automaton.View = null,
    forest_view: ?forest.View = null,
    forest_verified: bool = false,
    prose_view: ?AuthenticatedProseView = null,
    // Verification authenticates the complete container. Afterwards prose
    // reads can use direct mapped slices instead of crossing the authenticated
    // Source boundary once per packed symbol. Before verification we retain
    // the page-lazy source path above.
    prose_mapped_view: ?grammar.View = null,
    text_map: ?text_index.View = null,
    normalized_view: ?axes.ViewFor(axes.Normalized) = null,
    phonetic_view: ?axes.ViewFor(axes.Phonetic) = null,
    reversed_view: ?axes.ViewFor(axes.Reverse) = null,
    terms_view: ?term_index.View = null,
    cold_view: ?cold.View = null,
    concepts_view: ?concept_index.ConceptView = null,
    relations_view: ?relation_index.View = null,
    rich_content_view: ?rich_content.View = null,
    counts_checked: bool = false,
    verified: bool = false,

    /// Envelope-only open. No section page or semantic section walk is hidden
    /// behind this call.
    pub fn open(bytes: []const u8, trust: []u64, options: Options) Error!Snapshot {
        if (bytes.len > options.limits.max_file_bytes) return error.LimitExceeded;
        var envelope = try container.Container.open(bytes, trust);
        const actual = envelope.schemaDigest();
        const expected = options.expected_schema orelse schema.digest();
        if (!std.mem.eql(u8, &actual, &expected)) return error.SchemaMismatch;
        return .{ .bytes = bytes, .envelope = envelope, .limits = options.limits };
    }

    pub fn openUncached(bytes: []const u8, options: Options) Error!Snapshot {
        return open(bytes, &.{}, options);
    }

    pub fn schemaDigest(self: *const Snapshot) [container.digest_size]u8 {
        return self.envelope.schemaDigest();
    }

    pub fn isVerified(self: *const Snapshot) bool {
        return self.verified;
    }

    pub fn directory(self: *Snapshot) Directory {
        return .{ .snapshot = self };
    }

    fn contains(self: *Snapshot, tag: container.Tag) bool {
        _ = self.envelope.find(tag) catch return false;
        return true;
    }

    /// Fully authenticate a bounded section before publishing its borrowed
    /// slice. Cold readers should prefer `sectionSource` below.
    pub fn section(self: *Snapshot, tag: container.Tag) Error!Section {
        var mapped = try self.envelope.find(tag);
        if (mapped.len() > self.limits.max_section_bytes) return error.LimitExceeded;
        return .{ .tag = tag, .bytes = try mapped.bytes(0, mapped.len()) };
    }

    /// A range-authenticated source. Every later read crosses Section.bytes
    /// and the caller-owned trust bitmap; no raw mapped-byte escape exists.
    pub fn sectionSource(self: *Snapshot, tag: container.Tag) Error!container.SectionSource {
        var mapped = try self.envelope.find(tag);
        if (mapped.len() > self.limits.max_section_bytes) return error.LimitExceeded;
        return .{ .section = mapped };
    }

    fn automatonView(self: *Snapshot) Error!*const automaton.View {
        if (self.automaton_view == null) {
            const payload = try self.section(.automaton);
            const opened = automaton.View.open(payload.bytes) catch return error.CorruptSection;
            if (opened.entry_count > self.limits.max_entries) return error.LimitExceeded;
            self.automaton_view = opened;
        }
        return &self.automaton_view.?;
    }

    fn forestView(self: *Snapshot) Error!*const forest.View {
        if (self.forest_view == null) {
            const payload = try self.section(.forest);
            const opened = forest.View.open(payload.bytes) catch return error.CorruptSection;
            if (opened.rootCount() > self.limits.max_entries) return error.LimitExceeded;
            self.forest_view = opened;
        }
        return &self.forest_view.?;
    }

    /// Schema-based plan rewrites require semantic topology, not just an
    /// authenticated envelope. Pay this allocation-free proof once on first
    /// structural use; exact key queries remain independent and page-lazy.
    fn structuralView(self: *Snapshot) Error!*const forest.View {
        const view = try self.forestView();
        if (!self.forest_verified) {
            try view.verify();
            self.forest_verified = true;
        }
        return view;
    }

    fn proseView(self: *Snapshot) Error!*const AuthenticatedProseView {
        if (self.prose_view == null) {
            const source = try self.sectionSource(.prose);
            const opened = AuthenticatedProseView.open(source, self.limits.grammar) catch |err| return mapProseError(err);
            if (opened.item_count > self.limits.max_prose_items) return error.LimitExceeded;
            self.prose_view = opened;
        }
        return &self.prose_view.?;
    }

    fn textMapView(self: *Snapshot) Error!*const text_index.View {
        if (self.text_map == null) {
            const payload = self.section(.columns) catch |err| return if (err == error.MissingSection) error.MissingTextMap else err;
            if (payload.bytes.len < text_index.magic.len or !std.mem.eql(u8, payload.bytes[0..text_index.magic.len], text_index.magic))
                return error.MissingTextMap;
            const opened = text_index.View.open(payload.bytes) catch |err| return mapTextIndexError(err);
            const structure = try self.structuralView();
            const prose_count = (try self.proseView()).item_count;
            // Identity descriptors are intentionally zero-byte, so a hostile
            // map can otherwise advertise billions of ranks and make verify
            // spin despite a tiny authenticated section.  Apply the same
            // caller-selected budget to every text rank before the linear
            // semantic walk.
            inline for (@typeInfo(schema.Kind).@"enum".fields) |field| {
                const kind: Kind = @enumFromInt(field.value);
                if (schema.spec(kind).text and (try kindCountRuntime(structure, kind)) > self.limits.max_prose_items)
                    return error.LimitExceeded;
            }
            opened.validate(structure, prose_count) catch |err| return mapTextIndexError(err);
            self.text_map = opened;
        }
        return &self.text_map.?;
    }

    /// Only entry multiplicity and forest root multiplicity are intrinsically
    /// the same domain. Prose is a separate rank space: one entry may have no
    /// prose rows or many rows, and its identity is carried by the durable
    /// typed map in `.columns` when a caller asks for a text projection.
    fn ensureEntryForestCount(self: *Snapshot) Error!void {
        if (self.counts_checked) return;
        const keys = try self.automatonView();
        const structure = try self.forestView();
        if (@as(usize, keys.entry_count) != structure.rootCount() or
            try structure.kindCount(.entry) != structure.rootCount()) return error.CrossSectionMismatch;
        self.counts_checked = true;
    }

    /// Authenticate and semantically validate all three hot sections. The
    /// caller supplies the only allocator used by automaton verification.
    pub fn verify(self: *Snapshot, allocator: std.mem.Allocator) Error!void {
        if (self.verified) return;
        try self.envelope.verify();
        const keys = try self.automatonView();
        try keys.verifyWithAllocator(allocator);
        _ = try self.structuralView();
        const prose_store = try self.proseView();
        prose_store.verify() catch |err| return mapProseError(err);
        const prose_payload = try self.section(.prose);
        const mapped_prose = grammar.View.open(prose_payload.bytes, self.limits.grammar) catch |err| return mapProseError(err);
        try self.ensureEntryForestCount();
        if (self.contains(.columns)) _ = try self.textMapView();
        // Optional indexes are canonical directory records, not opaque
        // offsets in `.cold`.  Verify only records that are present; opening
        // them here makes `Snapshot.verify` a complete semantic check while
        // keeping `open` envelope-only.
        if (self.contains(.normalized)) (try self.axis(axes.Normalized)).verify(allocator) catch |err| return mapOptionalError(err);
        if (self.contains(.phonetic)) (try self.axis(axes.Phonetic)).verify(allocator) catch |err| return mapOptionalError(err);
        if (self.contains(.reversed)) (try self.axis(axes.Reverse)).verify(allocator) catch |err| return mapOptionalError(err);
        if (self.contains(.terms)) (try self.terms()).verify(allocator) catch |err| return mapOptionalError(err);
        if (self.contains(.concepts)) {
            _ = try self.concepts();
            self.concepts_view.?.verify() catch |err| return mapOptionalError(err);
        }
        if (self.contains(.relations)) {
            _ = try self.relations();
            self.relations_view.?.verify() catch |err| return mapOptionalError(err);
        }
        if (self.contains(.cold)) {
            // Verification here is deliberately codec-free: authenticate the
            // encoded payload now, while reserving decompression and its
            // allocator/decode cost for an explicit cold Reader.
            const cold_payload = try self.coldView();
            cold_payload.verifyEncoded() catch |err| return mapOptionalError(err);
        }
        if (self.contains(.rich_content)) {
            _ = try self.richContent();
            self.rich_content_view.?.verify(allocator) catch |err| return mapOptionalError(err);
            const structure = try self.structuralView();
            for (0..self.rich_content_view.?.element_count) |index| if ((self.rich_content_view.?.element(@enumFromInt(index)) catch return error.InvalidOptionalSection).semantic) |binding| {
                const count: ?usize = switch (schema.domainOwner(binding.kind)) {
                    .forest => kindCountRuntime(structure, binding.kind) catch return error.InvalidOptionalSection,
                    .concept => if (self.concepts_view) |*owner| owner.conceptCount() else null,
                    .interlingual, .external => null,
                };
                if (count) |bound| if (binding.rank >= bound) return error.CrossSectionMismatch;
            };
        }
        self.prose_mapped_view = mapped_prose;
        self.verified = true;
    }

    fn renderProse(self: *Snapshot, index: usize, out: []u8, stack: []RenderFrame) Error!usize {
        if (self.prose_mapped_view) |*mapped|
            return mapped.extractWithStack(index, out, stack) catch |err| return mapProseError(err);
        return (try self.proseView()).extractWithStack(index, out, stack) catch |err| return mapProseError(err);
    }

    fn snippetProse(self: *Snapshot, index: usize, limit: usize, out: []u8, stack: []RenderFrame) Error!usize {
        if (self.prose_mapped_view) |*mapped|
            return mapped.snippetWithStack(index, limit, out, stack) catch |err| return mapProseError(err);
        return (try self.proseView()).snippetWithStack(index, limit, out, stack) catch |err| return mapProseError(err);
    }

    fn optionalBytes(self: *Snapshot, tag: container.Tag) Error![]const u8 {
        // The compact optional readers currently parse plain byte slices, so
        // this boundary deliberately authenticates the complete section once.
        // It is still not a mapped-byte escape: `section` crosses
        // `container.Section.bytes`, and any future cold/source reader can
        // replace this helper with `sectionSource` without changing tags.
        return (try self.section(tag)).bytes;
    }

    /// Open the encoded cold section without decoding or allocating.  The
    /// returned view borrows authenticated section bytes and must not outlive
    /// this snapshot (or the mapped input it references).
    pub fn coldView(self: *Snapshot) Error!*const cold.View {
        if (self.cold_view == null) {
            const payload = try self.optionalBytes(.cold);
            const opened = cold.View.open(payload) catch return error.InvalidOptionalSection;
            self.cold_view = opened;
        }
        return &self.cold_view.?;
    }

    /// Open a canonical derived axis after authenticating its complete
    /// section.  The transform is a comptime parameter, so callers cannot
    /// accidentally pair a normalized query with a phonetic wire record.
    pub fn axis(self: *Snapshot, comptime Transform: type) Error!*const axes.ViewFor(Transform) {
        comptime if (Transform != axes.Normalized and Transform != axes.Phonetic and Transform != axes.Reverse)
            @compileError("Snapshot.axis accepts only the canonical LEX4 axes");
        const tag: container.Tag = if (Transform == axes.Normalized) .normalized else if (Transform == axes.Phonetic) .phonetic else .reversed;
        const cache = if (Transform == axes.Normalized) &self.normalized_view else if (Transform == axes.Phonetic) &self.phonetic_view else &self.reversed_view;
        if (cache.* == null) {
            const opened = axes.ViewFor(Transform).open(try self.optionalBytes(tag)) catch return error.InvalidOptionalSection;
            if (opened.entry_count != (try self.entryCount())) return error.CrossSectionMismatch;
            cache.* = opened;
        }
        return &cache.*.?;
    }

    /// Open the optional term/postings index.  Its postings remain borrowed;
    /// the allocator is used only for the bounded semantic verifier.
    pub fn terms(self: *Snapshot) Error!*const term_index.View {
        if (self.terms_view == null) {
            const payload = try self.optionalBytes(.terms);
            const opened = term_index.View.open(payload) catch return error.InvalidOptionalSection;
            if (opened.entry_count != (try self.entryCount())) return error.CrossSectionMismatch;
            self.terms_view = opened;
        }
        return &self.terms_view.?;
    }

    /// Open the concept membership index.  Concept accessors enforce their
    /// own `verify` precondition; this boundary performs that check once and
    /// retains the view at a stable address for all borrowed iterators.
    pub fn concepts(self: *Snapshot) Error!*const concept_index.ConceptView {
        if (self.concepts_view == null) {
            const payload = try self.optionalBytes(.concepts);
            const opened = concept_index.ConceptView.open(payload) catch return error.InvalidOptionalSection;
            self.concepts_view = opened;
        }
        return &self.concepts_view.?;
    }

    /// Open the relation/translation graph.  All graph iterators are caller
    /// driven and the traversal API still requires caller-owned work buffers.
    pub fn relations(self: *Snapshot) Error!*const relation_index.View {
        if (self.relations_view == null) {
            const payload = try self.optionalBytes(.relations);
            const opened = relation_index.View.open(payload) catch return error.InvalidOptionalSection;
            self.relations_view = opened;
        }
        return &self.relations_view.?;
    }

    /// Ordered, namespaced source occurrences. Structural interval shortcuts
    /// become available after `verify`; scalar element/string reads remain
    /// bounded immediately after the envelope is opened.
    pub fn richContent(self: *Snapshot) Error!*rich_content.View {
        if (self.rich_content_view == null) {
            const payload = try self.optionalBytes(.rich_content);
            self.rich_content_view = rich_content.View.open(payload, self.limits.grammar) catch return error.InvalidOptionalSection;
        }
        return &self.rich_content_view.?;
    }

    pub fn entryCount(self: *Snapshot) Error!usize {
        return @intCast((try self.automatonView()).entry_count);
    }

    pub fn rootCount(self: *Snapshot) Error!usize {
        return (try self.forestView()).rootCount();
    }

    pub fn proseItemCount(self: *Snapshot) Error!usize {
        return (try self.proseView()).item_count;
    }

    pub fn query(self: *Snapshot) Error!Query {
        try self.ensureEntryForestCount();
        return .{ .snapshot = self };
    }
};

/// A key accepted by the primary automaton.  Forms and headwords share the
/// same prefix walk, but their identity payloads are intentionally distinct:
/// headwords expose a contiguous homograph range, while forms expose their
/// explicit borrowed target list.  `bytes` borrows the iterator's key scratch
/// and is overwritten by the next `next()` call.
pub const AcceptedKey = struct {
    bytes: []const u8,
    kind: automaton.MatchKind,
    entries: ?automaton.Range,

    /// The targets are borrowed from the snapshot's automaton section.  They
    /// remain valid while the snapshot and its mapped bytes remain alive.
    targets: automaton.TargetList,

    pub fn isEntry(self: AcceptedKey) bool {
        return self.kind == .entry;
    }

    pub fn isForm(self: AcceptedKey) bool {
        return self.kind == .form;
    }
};

pub const PrefixIterator = struct {
    inner: automaton.View.Iterator,

    pub fn next(self: *PrefixIterator) Error!?AcceptedKey {
        const item = try self.inner.next() orelse return null;
        return .{ .bytes = item.key, .kind = item.kind, .entries = item.entries(), .targets = item.targets };
    }
};

fn TextHandle(comptime semantic_kind: ?Kind) type {
    return struct {
        const Self = @This();
        snapshot: *Snapshot,
        rank: ProseRank,

        pub const Kind = semantic_kind;

        pub fn index(self: Self) usize {
            return @intFromEnum(self.rank);
        }

        pub fn render(self: Self, out: []u8, stack: []RenderFrame) Error!usize {
            return self.snapshot.renderProse(self.index(), out, stack);
        }

        pub fn snippet(self: Self, limit: usize, out: []u8, stack: []RenderFrame) Error!usize {
            return self.snapshot.snippetProse(self.index(), limit, out, stack);
        }
    };
}

pub const ProseItem = TextHandle(null);

pub fn Text(comptime kind: Kind) type {
    comptime if (!schema.spec(kind).text) @compileError("Text requires a text-bearing kind");
    return TextHandle(kind);
}

/// A leaf plan borrows a sorted rank set. It owns no cursor: selections are
/// reusable values, and every iterator gets its own independent position.
fn Ranked(comptime kind: Kind) type {
    return struct {
        pub const Kind = kind;
        set: NodeSet(kind),

        const Iterator = struct {
            set: NodeSet(kind),
            position: usize = 0,

            fn next(self: *@This(), _: *Snapshot) Error!?Rank(kind) {
                if (self.position == self.set.len()) return null;
                const result = self.set.at(self.position) catch return error.InvalidRank;
                self.position += 1;
                return result;
            }
        };

        fn iterator(self: @This()) Iterator {
            return .{ .set = self.set };
        }
    };
}

/// An index's borrowed ordered rank stream is another selection seed. Its
/// cursor is copied for each traversal; navigation above it is the same
/// Below plan used for literal rank sets, not a separate graph-to-text path.
fn StoredRanks(comptime kind: Kind, comptime Cursor: type) type {
    return struct {
        pub const Kind = kind;
        initial: Cursor,

        const Iterator = struct {
            cursor: Cursor,
            fn next(self: *@This(), _: *Snapshot) Error!?Rank(kind) {
                return self.cursor.next() catch |err| return mapOptionalError(err);
            }
        };

        fn iterator(self: @This()) Iterator {
            return .{ .cursor = self.initial };
        }
    };
}

/// Descendants form ordered subtree unions, not an enclosing kind interval.
/// The frontier suppresses overlaps from nested selected ancestors; unrelated
/// siblings between selected subtrees can never leak into the result.
fn Below(comptime Parent: type, comptime kind: Kind) type {
    comptime if (!schema.canDescend(Parent.Kind, kind))
        @compileError("no legal descendant path from " ++ @tagName(Parent.Kind) ++ " to " ++ @tagName(kind));
    return struct {
        pub const Kind = kind;
        pub const ParentPlan = Parent;
        parent: Parent,

        const Iterator = struct {
            parents: Parent.Iterator,
            pending: Interval(kind) = Interval(kind).empty(),
            emitted_end: usize = 0,
            started: bool = false,

            fn next(self: *@This(), snapshot: *Snapshot) Error!?Rank(kind) {
                const structure = try snapshot.forestView();
                // All entry roots in a prefix interval are adjacent. Compute
                // both target boundaries from those roots once, bypassing
                // enumeration of the intermediate entries entirely.
                if (comptime Parent == Ranked(.entry)) {
                    if (!self.started and self.parents.set == .interval) {
                        const interval = self.parents.set.interval;
                        self.pending = try structure.projectRoots(kind, try forest.RootRange.init(
                            @intFromEnum(interval.lo),
                            @intFromEnum(interval.hi),
                        ));
                        self.parents.position = self.parents.set.len();
                    }
                }
                self.started = true;
                while (self.pending.isEmpty()) {
                    const parent_rank = try self.parents.next(snapshot) orelse return null;
                    const node = try structure.selectKind(Parent.Kind, parent_rank);
                    const end = try structure.subtreeEnd(node);
                    const interval = try structure.project(kind, .{ .lo = @as(usize, @intFromEnum(node)) + 1, .hi = end });
                    const lo = @max(@as(usize, @intFromEnum(interval.lo)), self.emitted_end);
                    const hi = @max(lo, @as(usize, @intFromEnum(interval.hi)));
                    self.pending = Interval(kind).init(@enumFromInt(@as(u32, @intCast(lo))), @enumFromInt(@as(u32, @intCast(hi)))) catch return error.InvalidRank;
                }
                const result = self.pending.lo;
                self.pending = self.pending.after(1);
                self.emitted_end = @as(usize, @intFromEnum(result)) + 1;
                return result;
            }
        };

        fn iterator(self: @This()) Iterator {
            return .{ .parents = self.parent.iterator() };
        }
    };
}

fn DescendantPlan(comptime Plan: type, comptime target: Kind) type {
    if (@hasDecl(Plan, "ParentPlan")) {
        if (schema.dominates(Plan.ParentPlan.Kind, Plan.Kind, target))
            return DescendantPlan(Plan.ParentPlan, target);
    }
    return Below(Plan, target);
}

fn descend(plan: anytype, comptime target: Kind) DescendantPlan(@TypeOf(plan), target) {
    const Plan = @TypeOf(plan);
    if (comptime @hasDecl(Plan, "ParentPlan")) {
        if (comptime schema.dominates(Plan.ParentPlan.Kind, Plan.Kind, target))
            return descend(plan.parent, target);
    }
    return .{ .parent = plan };
}

/// A selection is an immutable, statically typed plan over stored ranks.
/// Comptime dominance proofs erase redundant navigation stages; all other
/// compositions retain exact lazy subtree semantics and caller-owned state.
pub fn Selection(comptime Plan: type) type {
    return struct {
        pub const Kind = Plan.Kind;
        snapshot: *Snapshot,
        plan: Plan,

        pub fn descendants(self: @This(), comptime target: schema.Kind) Selection(DescendantPlan(Plan, target)) {
            return .{ .snapshot = self.snapshot, .plan = descend(self.plan, target) };
        }

        pub fn texts(self: @This()) TextCursor(Plan) {
            return .{ .snapshot = self.snapshot, .ranks = self.plan.iterator() };
        }

        pub const Iterator = struct {
            snapshot: *Snapshot,
            ranks: Plan.Iterator,

            pub fn next(self: *@This()) Error!?Rank(Plan.Kind) {
                return self.ranks.next(self.snapshot);
            }
        };

        pub fn iterator(self: @This()) Iterator {
            return .{ .snapshot = self.snapshot, .ranks = self.plan.iterator() };
        }
    };
}

fn TextCursor(comptime Plan: type) type {
    const kind = Plan.Kind;
    comptime if (!schema.spec(kind).text) @compileError("texts requires a text-bearing selection");
    return struct {
        snapshot: *Snapshot,
        ranks: Plan.Iterator,
        prose_next: usize = 0,
        prose_end: usize = 0,

        pub fn next(self: *@This()) Error!?Text(kind) {
            while (true) {
                if (self.prose_next < self.prose_end) {
                    const result = Text(kind){
                        .snapshot = self.snapshot,
                        .rank = try ProseRank.fromIndex(self.prose_next),
                    };
                    self.prose_next += 1;
                    return result;
                }
                const typed_rank = try self.ranks.next(self.snapshot) orelse return null;
                const map = try self.snapshot.textMapView();
                const span = map.span(kind, typed_rank) catch |err| return mapTextIndexError(err);
                self.prose_next = span.first;
                self.prose_end = std.math.add(usize, span.first, span.count) catch return error.Overflow;
            }
        }
    };
}

pub const Entry = struct {
    snapshot: *Snapshot,
    rank: EntryRank,
    node: Node,
    key: []const u8,

    pub fn headword(self: Entry) []const u8 {
        return self.key;
    }

    pub fn children(self: Entry) Error!ChildIterator {
        const structure = try self.snapshot.structuralView();
        const start = @intFromEnum(self.node);
        const end = try structure.subtreeEnd(self.node);
        return .{ .view = structure, .cursor = std.math.add(usize, start, 1) catch return error.Overflow, .end = end };
    }

    pub fn project(self: Entry, comptime kind: Kind) Error!Interval(kind) {
        const raw = @intFromEnum(self.rank);
        const roots = try forest.RootRange.init(raw, raw + 1);
        return (try self.snapshot.structuralView()).projectRoots(kind, roots);
    }

    /// Return the zero-or-more grammar items mapped to one typed forest rank.
    /// The durable text map is required; ordinal coincidence is never used.
    pub fn texts(self: Entry, comptime kind: Kind) Error!TextCursor(Below(Ranked(.entry), kind)) {
        var query = Query{ .snapshot = self.snapshot };
        return query.textsForEntry(self.rank, kind);
    }
};

/// Direct children are recovered from canonical preorder subtree extents.
/// The iterator stores only two cursors and borrows the stable forest view;
/// no child array or temporary slice is materialized.
pub const ChildIterator = struct {
    view: *const forest.View,
    cursor: usize,
    end: usize,

    pub fn next(self: *ChildIterator) Error!?Node {
        if (self.cursor >= self.end) return null;
        const node: Node = @enumFromInt(std.math.cast(u32, self.cursor) orelse return error.Overflow);
        const size = try self.view.subtreeSize(node);
        if (size == 0 or size > self.end - self.cursor) return error.CorruptSection;
        self.cursor += size;
        return node;
    }
};

pub const Query = struct {
    snapshot: *Snapshot,

    /// Seed a reusable document selection with a typed sorted rank set.
    /// Lists stay borrowed; descendants never materialize a replacement list.
    pub fn select(self: *Query, comptime kind: Kind, set: NodeSet(kind)) Error!Selection(Ranked(kind)) {
        set.validate() catch return error.InvalidRank;
        const count = try (try self.snapshot.structuralView()).kindCount(kind);
        switch (set) {
            .interval => |interval| if (@intFromEnum(interval.hi) > count) return error.InvalidRank,
            .list => |values| if (values.len != 0 and @intFromEnum(values[values.len - 1]) >= count) return error.InvalidRank,
        }
        return .{ .snapshot = self.snapshot, .plan = .{ .set = set } };
    }

    pub fn entries(self: *Query, prefix_bytes: []const u8) Error!Selection(Ranked(.entry)) {
        return self.select(.entry, .{ .interval = try self.prefixInterval(prefix_bytes) });
    }

    /// Compose an attached concept index with structural navigation. Generic
    /// snapshots may carry independent concept domains; reject that use here
    /// unless the sense domain has the forest's cardinality. Compilers must
    /// assign membership ranks in forest kind order, never source-ID order.
    pub fn members(self: *Query, concept: Rank(.concept)) Error!Selection(StoredRanks(.sense, concept_index.MemberIterator(.concept))) {
        const structure = try self.snapshot.structuralView();
        const index = try self.snapshot.concepts();
        if (index.senseCount() != try structure.kindCount(.sense)) return error.CrossSectionMismatch;
        return .{ .snapshot = self.snapshot, .plan = .{ .initial = index.members(concept) catch |err| return mapOptionalError(err) } };
    }

    /// Access a raw grammar item by its own rank domain.  This method is
    /// deliberately separate from `entry`: prose rows are not entries.
    pub fn proseItem(self: *Query, rank_value: ProseRank) Error!?ProseItem {
        if (rank_value == .none) return null;
        if (@intFromEnum(rank_value) >= (try self.snapshot.proseView()).item_count) return null;
        return .{ .snapshot = self.snapshot, .rank = rank_value };
    }

    pub fn exact(self: *Query, key: []const u8) Error!?automaton.Hit {
        return (try self.snapshot.automatonView()).exact(key);
    }

    /// Return the complete entry interval for a prefix. A miss is the empty
    /// interval at its lexical insertion rank, never an optional/error side
    /// channel; this makes interval pipelines closed over empty results.
    pub fn prefixInterval(self: *Query, prefix_bytes: []const u8) Error!Interval(.entry) {
        const keys = try self.snapshot.automatonView();
        if (try keys.prefixInterval(prefix_bytes)) |range|
            return Interval(.entry).init(range.lo(), range.hi()) catch error.CorruptSection;
        const insertion = try keys.lowerBound(prefix_bytes);
        return Interval(.entry).init(insertion, insertion) catch error.CorruptSection;
    }

    pub fn prefix(self: *Query, prefix_bytes: []const u8, key_buffer: []u8, frames: []automaton.Frame) Error!PrefixIterator {
        return .{ .inner = try (try self.snapshot.automatonView()).prefix(prefix_bytes, key_buffer, frames) };
    }

    pub fn entry(self: *Query, rank_value: EntryRank, key_buffer: []u8) Error!?Entry {
        if (rank_value == .none) return error.InvalidRank;
        const raw = @intFromEnum(rank_value);
        const selected = (try (try self.snapshot.automatonView()).select(raw, key_buffer)) orelse return null;
        const node = try (try self.snapshot.forestView()).rootAt(raw);
        return .{ .snapshot = self.snapshot, .rank = rank_value, .node = node, .key = selected.key };
    }

    /// Resolve a stored headword to its complete homograph range.  Form keys
    /// intentionally return null: callers that want form semantics should
    /// use `exact` (or the accepted-key prefix iterator) and inspect targets.
    pub fn entriesForHeadword(self: *Query, key: []const u8) Error!?Interval(.entry) {
        const hit = (try (try self.snapshot.automatonView()).exact(key)) orelse return null;
        if (!hit.isEntry()) return null;
        const range = hit.entry_range orelse return null;
        return Interval(.entry).init(range.lo, range.hi) catch error.CorruptSection;
    }

    /// Project an entry rank directly into one text-bearing domain. This is
    /// the rendering path when the caller already has identity: no headword
    /// reconstruction or temporary key buffer is required.
    pub fn textsForEntry(self: *Query, rank_value: EntryRank, comptime kind: Kind) Error!TextCursor(Below(Ranked(.entry), kind)) {
        if (rank_value == .none) return error.InvalidRank;
        const raw = @intFromEnum(rank_value);
        if (raw >= try self.snapshot.entryCount()) return error.InvalidRank;
        const selected = try self.select(.entry, .{ .interval = Interval(.entry).init(rank_value, @enumFromInt(raw + 1)) catch return error.InvalidRank });
        return selected.descendants(kind).texts();
    }

    pub fn nodesForPrefix(self: *Query, comptime kind: Kind, prefix_bytes: []const u8) Error!NodeSet(kind) {
        const roots = try self.prefixInterval(prefix_bytes);
        const first = @intFromEnum(roots.lo);
        const last = @intFromEnum(roots.hi);
        const root_range = try forest.RootRange.init(first, last);
        return .{ .interval = try (try self.snapshot.structuralView()).projectRoots(kind, root_range) };
    }

    /// Resolve the text range owned by a rank in a semantic forest domain.
    /// Results are an iterator over stable typed handles and never allocate.
    pub fn texts(self: *Query, comptime kind: Kind, rank_value: Rank(kind)) Error!TextCursor(Ranked(kind)) {
        const raw = rank_value.index() orelse return error.InvalidRank;
        const selected = try self.select(kind, .{ .interval = Interval(kind).init(rank_value, @enumFromInt(@as(u32, @intCast(raw + 1)))) catch return error.InvalidRank });
        return selected.texts();
    }
};

test "snapshot public types keep hit lifetimes and prose domains explicit" {
    comptime {
        _ = Query.exact;
        _ = Query.nodesForPrefix;
        _ = Query.texts;
        _ = Entry.texts;
        _ = ProseItem.render;
        _ = Entry.project;
    }
}
