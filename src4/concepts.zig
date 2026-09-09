//! Compact concept memberships for the LEX4 conceptual layer.
//!
//! A membership is a typed relation from a sense rank to either a synset
//! (`concept`) or an interlingual concept (`interlingual`).  The wire format
//! stores ranks, never source identifiers.  The forward column is a packed
//! sense-rank array with a sentinel for an unassigned sense.  The reverse
//! column is a packed list of sense ranks ordered by concept rank, with an
//! Elias--Fano unary boundary vector providing O(select) concept ranges.
//!
//! `View.open` checks only the fixed envelope and section envelopes.  It does
//! not walk the packed columns.  Call `verify` before querying untrusted
//! bytes; the resulting view is still borrowed and all queries allocate
//! nothing.

const std = @import("std");
const schema = @import("schema.zig");
const rank = @import("rank.zig");
const bitvector = @import("bitvector.zig");
const wire = @import("wire.zig");

pub const Kind = schema.Kind;
pub const Certainty = schema.Certainty;
pub const Confidence = schema.Certainty;
pub const LanguageTag = schema.LanguageTag;
pub const SenseRank = schema.Rank(.sense);
pub const Rank = schema.Rank;

pub const magic = "L4CM";
pub const version: u16 = 1;
pub const header_size: usize = 144;
pub const confidence_width: u8 = 2;

const max_rank_count = std.math.maxInt(u32);

pub const Error = rank.Error || bitvector.Error || wire.Error || std.mem.Allocator.Error || error{
    BadMagic,
    UnsupportedVersion,
    KindMismatch,
    InvalidEncoding,
    InvalidMembership,
    InvalidRank,
    InvalidRange,
    InvalidConfidence,
    Overflow,
    Truncated,
    Unverified,
    LimitExceeded,
    WrongMembershipKind,
};

/// Limits apply before any linear verification work.  They prevent a small
/// hostile envelope from forcing a reader to iterate billions of ranks.
pub const Limits = struct {
    max_senses: usize = 64 * 1024 * 1024,
    max_concepts: usize = 64 * 1024 * 1024,
    max_memberships: usize = 64 * 1024 * 1024,
    max_bytes: usize = 512 * 1024 * 1024,
};

fn requireConceptKind(comptime concept_kind: Kind) void {
    if (concept_kind != .concept and concept_kind != .interlingual)
        @compileError("concept membership kind must be .concept or .interlingual");
}

/// The only input record accepted by the builder.  `sense` and `concept`
/// have different Zig types, so a node rank or a rank from another kind
/// cannot be inserted accidentally.
pub fn MembershipRecord(comptime concept_kind: Kind) type {
    requireConceptKind(concept_kind);
    return struct {
        sense: SenseRank,
        concept: Rank(concept_kind),
        confidence: ?Confidence = null,
    };
}

pub fn Membership(comptime concept_kind: Kind) type {
    return MembershipRecord(concept_kind);
}

pub fn ConceptRank(comptime concept_kind: Kind) type {
    requireConceptKind(concept_kind);
    return Rank(concept_kind);
}

pub const ConceptMembership = MembershipRecord(.concept);
pub const InterlingualMembership = MembershipRecord(.interlingual);

pub const MemberRange = struct {
    start: usize,
    end: usize,

    pub fn len(self: @This()) usize {
        return self.end - self.start;
    }

    pub fn isEmpty(self: @This()) bool {
        return self.start == self.end;
    }
};

fn checkedAdd(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.Overflow;
}

fn checkedMul(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch error.Overflow;
}

fn toUsize(value: u64) Error!usize {
    return std.math.cast(usize, value) orelse error.Overflow;
}

fn toU64(value: usize) Error!u64 {
    return std.math.cast(u64, value) orelse error.Overflow;
}

fn align8(value: usize) Error!usize {
    return (try checkedAdd(value, 7)) & ~@as(usize, 7);
}

fn widthFor(max_value: usize) u8 {
    if (max_value == 0) return 1;
    return @intCast(@bitSizeOf(usize) - @clz(max_value));
}

fn bytesForBits(count: usize, width: u8) Error!usize {
    if (width == 0 or count == 0) return 0;
    const bits = try checkedMul(count, width);
    return (try checkedAdd(bits, 7)) / 8;
}

fn readU16(bytes: []const u8, offset: usize) Error!u16 {
    if (offset > bytes.len or bytes.len - offset < 2) return error.Truncated;
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU64(bytes: []const u8, offset: usize) Error!u64 {
    if (offset > bytes.len or bytes.len - offset < 8) return error.Truncated;
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn writeU64(bytes: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[offset..][0..8], value, .little);
}

fn paddingIsZero(bytes: []const u8, bit_count: usize) bool {
    if (bit_count == 0) return bytes.len == 0;
    if (bytes.len == 0) return false;
    const remainder = bit_count % 8;
    if (remainder == 0) return true;
    const mask: u8 = @intCast((@as(u16, 1) << @as(u4, @intCast(remainder))) - 1);
    return (bytes[bytes.len - 1] & ~mask) == 0;
}

fn zeroBytes(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

const Section = struct { offset: usize, length: usize };

/// A membership view can be backed by a raw mapped slice or by a container
/// section. Reads are borrowed and the source decides whether a range must be
/// authenticated.
fn sourceLen(comptime Source: type, source: *const Source) usize {
    if (Source == []const u8 or Source == []u8) return source.*.len;
    return source.len();
}

fn sourceError(comptime Source: type) type {
    return if (Source == []const u8 or Source == []u8) Error else anyerror;
}

fn sourceBytes(comptime Source: type, source: *Source, offset: usize, length: usize) sourceError(Source)![]const u8 {
    if (Source == []const u8 or Source == []u8) {
        if (offset > source.*.len or length > source.*.len - offset) return error.Truncated;
        return source.*[offset..][0..length];
    }
    const result = try source.bytes(offset, length);
    if (result.len != length) return error.Truncated;
    return result;
}

/// A fixed window over another source, used for the nested bitvector columns.
/// The source is still the original authenticated source; no bytes are copied.
fn NestedSource(comptime Parent: type) type {
    return struct {
        parent: Parent,
        offset: usize,
        length: usize,

        pub fn len(self: *const @This()) usize {
            return self.length;
        }

        pub fn bytes(self: *@This(), offset: usize, length: usize) anyerror![]const u8 {
            if (offset > self.length or length > self.length - offset) return error.Truncated;
            const absolute = std.math.add(usize, self.offset, offset) catch return error.Overflow;
            return sourceBytes(Parent, &self.parent, absolute, length);
        }
    };
}

fn sectionAt(bytes: []const u8, index: usize) Error!Section {
    const offset_at = 48 + index * 16;
    return .{
        .offset = try toUsize(try readU64(bytes, offset_at)),
        .length = try toUsize(try readU64(bytes, offset_at + 8)),
    };
}

fn sectionBytes(bytes: []const u8, section: Section) Error![]const u8 {
    const end = try checkedAdd(section.offset, section.length);
    if (section.offset > bytes.len or end > bytes.len) return error.Truncated;
    return bytes[section.offset..end];
}

fn nextSection(cursor: *usize, length: usize) Error!Section {
    const offset = try align8(cursor.*);
    const end = try checkedAdd(offset, length);
    cursor.* = end;
    return .{ .offset = offset, .length = length };
}

fn validRankCount(count: usize) bool {
    return count < max_rank_count;
}

/// An owning byte string.  Its `view` convenience method verifies before
/// returning; callers opening mapped bytes directly can use `View.open` and
/// choose when to pay the verification pass.
pub fn Owned(comptime concept_kind: Kind) type {
    requireConceptKind(concept_kind);
    return struct {
        allocator: std.mem.Allocator,
        bytes: []u8,

        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.bytes);
            self.* = undefined;
        }

        pub fn view(self: *const @This()) Error!ViewFor(concept_kind) {
            return ViewFor(concept_kind).openAndVerify(self.bytes);
        }

        pub fn openView(self: *const @This()) Error!ViewFor(concept_kind) {
            return ViewFor(concept_kind).open(self.bytes);
        }
    };
}

pub const ConceptOwned = Owned(.concept);
pub const InterlingualOwned = Owned(.interlingual);

fn lessBySense(comptime concept_kind: Kind, lhs: MembershipRecord(concept_kind), rhs: MembershipRecord(concept_kind)) bool {
    const left_sense = @intFromEnum(lhs.sense);
    const right_sense = @intFromEnum(rhs.sense);
    if (left_sense != right_sense) return left_sense < right_sense;
    const left_concept = @intFromEnum(lhs.concept);
    const right_concept = @intFromEnum(rhs.concept);
    if (left_concept != right_concept) return left_concept < right_concept;
    const left_confidence = if (lhs.confidence) |value| @intFromEnum(value) + 1 else 0;
    const right_confidence = if (rhs.confidence) |value| @intFromEnum(value) + 1 else 0;
    return left_confidence < right_confidence;
}

fn lessByConcept(comptime concept_kind: Kind, lhs: MembershipRecord(concept_kind), rhs: MembershipRecord(concept_kind)) bool {
    const left_concept = @intFromEnum(lhs.concept);
    const right_concept = @intFromEnum(rhs.concept);
    if (left_concept != right_concept) return left_concept < right_concept;
    const left_sense = @intFromEnum(lhs.sense);
    const right_sense = @intFromEnum(rhs.sense);
    if (left_sense != right_sense) return left_sense < right_sense;
    const left_confidence = if (lhs.confidence) |value| @intFromEnum(value) + 1 else 0;
    const right_confidence = if (rhs.confidence) |value| @intFromEnum(value) + 1 else 0;
    return left_confidence < right_confidence;
}

/// Encode a canonical membership column.  Input records may be in any order;
/// they are copied, validated, and deterministically sorted by rank.
pub fn encode(
    comptime concept_kind: Kind,
    allocator: std.mem.Allocator,
    sense_count: usize,
    concept_count: usize,
    input: []const MembershipRecord(concept_kind),
) Error!Owned(concept_kind) {
    requireConceptKind(concept_kind);
    if (!validRankCount(sense_count) or !validRankCount(concept_count) or input.len > sense_count)
        return error.InvalidMembership;

    const records = try allocator.dupe(MembershipRecord(concept_kind), input);
    defer allocator.free(records);

    const ForwardSort = struct {
        const less = struct {
            fn compare(_: void, lhs: MembershipRecord(concept_kind), rhs: MembershipRecord(concept_kind)) bool {
                return lessBySense(concept_kind, lhs, rhs);
            }
        }.compare;
    };
    std.sort.heap(MembershipRecord(concept_kind), records, {}, ForwardSort.less);

    var forward_codes = try allocator.alloc(usize, sense_count);
    defer allocator.free(forward_codes);
    @memset(forward_codes, concept_count);

    var confidence_by_sense: ?[]u8 = null;
    defer if (confidence_by_sense) |values| allocator.free(values);
    var confidence_present: ?[]bool = null;
    defer if (confidence_present) |values| allocator.free(values);
    if (input.len != 0) {
        confidence_by_sense = try allocator.alloc(u8, sense_count);
        @memset(confidence_by_sense.?, 0);
        confidence_present = try allocator.alloc(bool, sense_count);
        @memset(confidence_present.?, false);
    }

    var confidence_count: usize = 0;
    for (records, 0..) |record, index| {
        const sense = @as(usize, @intFromEnum(record.sense));
        const concept = @as(usize, @intFromEnum(record.concept));
        if (sense == std.math.maxInt(u32) or sense >= sense_count or
            concept == std.math.maxInt(u32) or concept >= concept_count)
            return error.InvalidMembership;
        if (index != 0 and @intFromEnum(records[index - 1].sense) == @intFromEnum(record.sense))
            return error.InvalidMembership;
        forward_codes[sense] = concept;
        if (record.confidence) |value| {
            if (@intFromEnum(value) > @intFromEnum(Certainty.certain)) return error.InvalidConfidence;
            confidence_present.?[sense] = true;
            confidence_by_sense.?[sense] = @intFromEnum(value);
            confidence_count += 1;
        }
    }

    const forward_width = widthFor(concept_count);
    const sense_width = widthFor(if (sense_count == 0) 0 else sense_count - 1);
    const forward_len = try bytesForBits(sense_count, forward_width);
    const confidence_values_len = try bytesForBits(confidence_count, confidence_width);
    const reverse_len = try bytesForBits(records.len, sense_width);

    var presence_owned: ?bitvector.Owned = null;
    defer if (presence_owned) |*value| value.deinit();
    if (confidence_count != 0)
        presence_owned = try bitvector.build(allocator, confidence_present.?);

    const boundary_bit_count = try checkedAdd(concept_count, records.len);
    var boundary_bits = try allocator.alloc(bool, boundary_bit_count);
    defer allocator.free(boundary_bits);
    @memset(boundary_bits, false);

    const ReverseSort = struct {
        const less = struct {
            fn compare(_: void, lhs: MembershipRecord(concept_kind), rhs: MembershipRecord(concept_kind)) bool {
                return lessByConcept(concept_kind, lhs, rhs);
            }
        }.compare;
    };
    std.sort.heap(MembershipRecord(concept_kind), records, {}, ReverseSort.less);

    var reverse_cursor: usize = 0;
    for (0..concept_count) |concept| {
        const marker = try checkedAdd(reverse_cursor, concept);
        boundary_bits[marker] = true;
        while (reverse_cursor < records.len and @intFromEnum(records[reverse_cursor].concept) == concept)
            reverse_cursor += 1;
    }
    if (reverse_cursor != records.len) return error.InvalidMembership;

    // Concept ranges are monotone select positions.  Keep this column in the
    // Elias--Fano representation even when a dense bitvector happens to be
    // smaller for a tiny fixture; the representation is part of the reverse
    // membership contract and remains directly select-addressable.
    var boundary_owned = try bitvector.buildForced(allocator, boundary_bits, .sparse);
    defer boundary_owned.deinit();

    var cursor = header_size;
    const forward_section = try nextSection(&cursor, forward_len);
    const presence_section = try nextSection(&cursor, if (presence_owned) |value| value.bytes.len else 0);
    const confidence_section = try nextSection(&cursor, confidence_values_len);
    const reverse_section = try nextSection(&cursor, reverse_len);
    const boundary_section = try nextSection(&cursor, boundary_owned.bytes.len);
    const total_len = cursor;

    var bytes = try allocator.alloc(u8, total_len);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);

    @memcpy(bytes[0..4], magic);
    writeU16(bytes, 4, version);
    writeU16(bytes, 6, header_size);
    bytes[8] = @intFromEnum(concept_kind);
    bytes[9] = if (confidence_count == 0) 0 else 1;
    bytes[10] = forward_width;
    bytes[11] = confidence_width;
    writeU64(bytes, 16, try toU64(sense_count));
    writeU64(bytes, 24, try toU64(concept_count));
    writeU64(bytes, 32, try toU64(records.len));
    writeU64(bytes, 40, try toU64(confidence_count));

    const sections = [_]Section{ forward_section, presence_section, confidence_section, reverse_section, boundary_section };
    for (sections, 0..) |section, index| {
        writeU64(bytes, 48 + index * 16, try toU64(section.offset));
        writeU64(bytes, 56 + index * 16, try toU64(section.length));
    }
    writeU64(bytes, 128, try toU64(total_len));

    for (forward_codes, 0..) |code, index| {
        const bit_offset = try checkedMul(index, forward_width);
        try wire.writePacked(bytes[forward_section.offset..][0..forward_section.length], bit_offset, forward_width, try toU64(code));
    }

    if (presence_owned) |value|
        @memcpy(bytes[presence_section.offset..][0..presence_section.length], value.bytes);

    if (confidence_count != 0) {
        var ordinal: usize = 0;
        for (confidence_present.?, 0..) |present, sense| {
            if (!present) continue;
            const bit_offset = try checkedMul(ordinal, confidence_width);
            try wire.writePacked(bytes[confidence_section.offset..][0..confidence_section.length], bit_offset, confidence_width, confidence_by_sense.?[sense]);
            ordinal += 1;
        }
    }

    for (records, 0..) |record, index| {
        const bit_offset = try checkedMul(index, sense_width);
        try wire.writePacked(bytes[reverse_section.offset..][0..reverse_section.length], bit_offset, sense_width, @intFromEnum(record.sense));
    }
    @memcpy(bytes[boundary_section.offset..][0..boundary_section.length], boundary_owned.bytes);

    return .{ .allocator = allocator, .bytes = bytes };
}

pub fn build(
    comptime concept_kind: Kind,
    allocator: std.mem.Allocator,
    sense_count: usize,
    concept_count: usize,
    input: []const MembershipRecord(concept_kind),
) Error!Owned(concept_kind) {
    return encode(concept_kind, allocator, sense_count, concept_count, input);
}

/// A deliberately explicit baseline for size reports.  A directed pairwise
/// representation of a k-member equivalence cluster has k(k-1) edges.  The
/// caller supplies the bytes per edge and fixed envelope bytes for the
/// competing format; this prevents a ratio from silently dropping headers or
/// changing the baseline encoding between runs.
pub const PairwiseBaseline = struct {
    member_count: usize,
    directed_edge_count: usize,
    fixed_bytes: usize,
    edge_bytes: usize,
    total_bytes: usize,
};

pub fn pairwiseBaseline(member_count: usize, fixed_bytes: usize, edge_bytes: usize) Error!PairwiseBaseline {
    const directed_edge_count = if (member_count < 2) 0 else try checkedMul(member_count, member_count - 1);
    const edge_total = try checkedMul(directed_edge_count, edge_bytes);
    return .{
        .member_count = member_count,
        .directed_edge_count = directed_edge_count,
        .fixed_bytes = fixed_bytes,
        .edge_bytes = edge_bytes,
        .total_bytes = try checkedAdd(fixed_bytes, edge_total),
    };
}

/// Incremental builder.  The finished byte string contains no builder state.
pub fn Builder(comptime concept_kind: Kind) type {
    requireConceptKind(concept_kind);
    const Record = MembershipRecord(concept_kind);
    return struct {
        allocator: std.mem.Allocator,
        sense_count: usize,
        concept_count: usize,
        records: std.ArrayList(Record) = .empty,
        finished: bool = false,

        pub fn init(allocator: std.mem.Allocator, sense_count: usize, concept_count: usize) @This() {
            return .{ .allocator = allocator, .sense_count = sense_count, .concept_count = concept_count };
        }

        pub fn deinit(self: *@This()) void {
            self.records.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn append(self: *@This(), record: Record) Error!void {
            if (self.finished) return error.InvalidEncoding;
            self.records.append(self.allocator, record) catch return error.OutOfMemory;
        }

        pub fn add(self: *@This(), record: Record) Error!void {
            return self.append(record);
        }

        pub fn addMembership(self: *@This(), sense: SenseRank, concept: Rank(concept_kind), confidence: ?Confidence) Error!void {
            return self.append(.{ .sense = sense, .concept = concept, .confidence = confidence });
        }

        pub fn put(self: *@This(), sense: SenseRank, concept: Rank(concept_kind)) Error!void {
            return self.addMembership(sense, concept, null);
        }

        pub fn putWithConfidence(self: *@This(), sense: SenseRank, concept: Rank(concept_kind), confidence: Confidence) Error!void {
            return self.addMembership(sense, concept, confidence);
        }

        pub fn finish(self: *@This()) Error!Owned(concept_kind) {
            if (self.finished) return error.InvalidEncoding;
            const result = try encode(concept_kind, self.allocator, self.sense_count, self.concept_count, self.records.items);
            self.finished = true;
            return result;
        }

        pub fn build(self: *@This()) Error!Owned(concept_kind) {
            return self.finish();
        }
    };
}

pub const ConceptBuilder = Builder(.concept);
pub const InterlingualBuilder = Builder(.interlingual);

fn openSection(
    bytes: []const u8,
    cursor: *usize,
    expected_length: usize,
    section_index: usize,
) Error!Section {
    const section = try sectionAt(bytes, section_index);
    const expected_offset = try align8(cursor.*);
    if (section.offset != expected_offset or section.length != expected_length) return error.InvalidEncoding;
    const end = try checkedAdd(section.offset, section.length);
    if (section.offset > bytes.len or end > bytes.len) return error.Truncated;
    if (!zeroBytes(bytes[cursor.*..section.offset])) return error.InvalidEncoding;
    cursor.* = end;
    return section;
}

/// A borrowed, typed reader for one conceptual membership kind.
fn ViewForSource(comptime concept_kind: Kind, comptime Source: type) type {
    requireConceptKind(concept_kind);
    const Record = MembershipRecord(concept_kind);
    const Nested = NestedSource(Source);
    const NestedView = if (Source == []const u8 or Source == []u8) bitvector.ViewFor([]const u8) else bitvector.ViewFor(Nested);
    const SourceError = sourceError(Source);

    return struct {
        const Self = @This();

        source: Source,
        bytes: []const u8 = &.{},
        total_len_: usize,
        sense_count_: usize,
        concept_count_: usize,
        membership_count_: usize,
        confidence_count_: usize,
        forward_width_: u8,
        sense_width_: u8,
        forward_: Section,
        presence_: ?NestedView,
        confidence_: Section,
        reverse_: Section,
        boundaries: NestedView,
        verified_: bool = false,

        pub const ConceptKind = concept_kind;
        pub const RecordType = Record;

        fn openNested(source: *Source, section: Section) SourceError!NestedView {
            if (Source == []const u8 or Source == []u8) {
                return bitvector.ViewFor([]const u8).openEnvelope(try sourceBytes(Source, source, section.offset, section.length));
            }
            const nested_source = Nested{ .parent = source.*, .offset = section.offset, .length = section.length };
            return bitvector.ViewFor(Nested).openEnvelope(nested_source);
        }

        pub fn open(source: Source) SourceError!Self {
            return Self.openWithLimits(source, .{});
        }

        pub fn openWithLimits(source: Source, limits: Limits) SourceError!Self {
            var owned_source = source;
            const source_length = sourceLen(Source, &owned_source);
            if (source_length < header_size) return error.Truncated;
            if (source_length > limits.max_bytes) return error.LimitExceeded;
            // The fixed header is the only large contiguous read performed by
            // open.  Packed payloads remain untouched until verify().
            const header = try sourceBytes(Source, &owned_source, 0, header_size);
            if (!std.mem.eql(u8, header[0..4], magic)) return error.BadMagic;
            if (try readU16(header, 4) != version) return error.UnsupportedVersion;
            if (try readU16(header, 6) != header_size) return error.InvalidEncoding;
            if (header[12] != 0 or header[13] != 0 or header[14] != 0 or header[15] != 0 or
                !zeroBytes(header[136..header_size])) return error.InvalidEncoding;

            const raw_kind = header[8];
            if (raw_kind >= schema.kind_count) return error.InvalidEncoding;
            if (@as(Kind, @enumFromInt(raw_kind)) != concept_kind) return error.KindMismatch;
            if ((header[9] & ~@as(u8, 1)) != 0 or header[11] != confidence_width) return error.InvalidEncoding;

            const sense_count = try toUsize(try readU64(header, 16));
            const concept_count = try toUsize(try readU64(header, 24));
            const membership_count = try toUsize(try readU64(header, 32));
            const confidence_count = try toUsize(try readU64(header, 40));
            if (!validRankCount(sense_count) or !validRankCount(concept_count) or
                sense_count > limits.max_senses or concept_count > limits.max_concepts or
                membership_count > limits.max_memberships or confidence_count > limits.max_memberships or
                membership_count > sense_count or confidence_count > membership_count)
                return error.LimitExceeded;

            const expected_forward_width = widthFor(concept_count);
            const expected_sense_width = widthFor(if (sense_count == 0) 0 else sense_count - 1);
            if (header[10] != expected_forward_width or header[10] == 0 or header[10] > 32)
                return error.InvalidEncoding;
            if (expected_sense_width == 0 or expected_sense_width > 32) return error.InvalidEncoding;
            const forward_width = header[10];
            const forward_len = try bytesForBits(sense_count, forward_width);
            const reverse_len = try bytesForBits(membership_count, expected_sense_width);
            const confidence_len = try bytesForBits(confidence_count, confidence_width);
            const boundary_bit_count = try checkedAdd(concept_count, membership_count);

            const presence_length = try toUsize(try readU64(header, 56 + 16));
            if (confidence_count == 0) {
                if (header[9] != 0 or presence_length != 0) return error.InvalidEncoding;
            } else if (header[9] != 1 or presence_length == 0) return error.InvalidEncoding;
            const boundary_length = try toUsize(try readU64(header, 120));
            const expected_lengths = [_]usize{ forward_len, presence_length, confidence_len, reverse_len, boundary_length };
            var sections: [5]Section = undefined;
            var cursor = header_size;
            for (expected_lengths, 0..) |expected_length, index| {
                const section = try sectionAt(header, index);
                const expected_offset = try align8(cursor);
                if (section.offset != expected_offset or section.length != expected_length)
                    return error.InvalidEncoding;
                const end = try checkedAdd(section.offset, section.length);
                if (section.offset > source_length or end > source_length) return error.Truncated;
                if (section.offset > cursor) {
                    const padding = try sourceBytes(Source, &owned_source, cursor, section.offset - cursor);
                    if (!zeroBytes(padding)) return error.InvalidEncoding;
                }
                sections[index] = section;
                cursor = end;
            }

            const total = try toUsize(try readU64(header, 128));
            if (cursor != total or total != source_length) return error.InvalidEncoding;

            var presence: ?NestedView = null;
            if (confidence_count != 0) {
                const nested = try Self.openNested(&owned_source, sections[1]);
                if (nested.len() != sense_count or nested.count() != confidence_count) return error.InvalidEncoding;
                presence = nested;
            }
            const boundary_view = try Self.openNested(&owned_source, sections[4]);
            if (boundary_view.len() != boundary_bit_count or boundary_view.count() != concept_count)
                return error.InvalidEncoding;

            return .{
                .source = owned_source,
                .total_len_ = total,
                .sense_count_ = sense_count,
                .concept_count_ = concept_count,
                .membership_count_ = membership_count,
                .confidence_count_ = confidence_count,
                .forward_width_ = forward_width,
                .sense_width_ = expected_sense_width,
                .forward_ = sections[0],
                .presence_ = presence,
                .confidence_ = sections[2],
                .reverse_ = sections[3],
                .boundaries = boundary_view,
            };
        }

        pub fn openAndVerify(source: Source) SourceError!Self {
            var result = try Self.open(source);
            try result.verify();
            return result;
        }

        pub fn isVerified(self: *const Self) bool {
            return self.verified_;
        }

        pub fn senseCount(self: *const Self) usize {
            return self.sense_count_;
        }

        pub fn conceptCount(self: *const Self) usize {
            return self.concept_count_;
        }

        pub fn membershipCount(self: *const Self) usize {
            return self.membership_count_;
        }

        pub fn confidenceCount(self: *const Self) usize {
            return self.confidence_count_;
        }

        fn ensureVerified(self: *const Self) SourceError!void {
            if (!self.verified_) return error.Unverified;
        }

        fn senseIndex(self: *const Self, value: SenseRank) SourceError!usize {
            const raw = @intFromEnum(value);
            if (raw == std.math.maxInt(u32)) return error.InvalidRank;
            const index = @as(usize, raw);
            if (index >= self.sense_count_) return error.OutOfRange;
            return index;
        }

        fn conceptIndex(self: *const Self, value: Rank(concept_kind)) SourceError!usize {
            const raw = @intFromEnum(value);
            if (raw == std.math.maxInt(u32)) return error.InvalidRank;
            const index = @as(usize, raw);
            if (index >= self.concept_count_) return error.OutOfRange;
            return index;
        }

        fn forwardCode(self: *const Self, sense: usize) SourceError!usize {
            const bit_offset = try checkedMul(sense, self.forward_width_);
            return toUsize(try wire.readPacked(self.bytes[self.forward_.offset..][0..self.forward_.length], bit_offset, self.forward_width_));
        }

        fn reverseSenseAt(self: *const Self, offset: usize) SourceError!SenseRank {
            const bit_offset = try checkedMul(offset, self.sense_width_);
            const value = try toUsize(try wire.readPacked(self.bytes[self.reverse_.offset..][0..self.reverse_.length], bit_offset, self.sense_width_));
            if (value >= self.sense_count_) return error.InvalidEncoding;
            return @enumFromInt(std.math.cast(u32, value) orelse return error.Overflow);
        }

        fn confidenceAt(self: *const Self, sense: usize) SourceError!?Confidence {
            const presence = self.presence_ orelse return null;
            if (!try presence.get(sense)) return null;
            const ordinal = try presence.rank1(sense);
            const bit_offset = try checkedMul(ordinal, confidence_width);
            const value = try wire.readPacked(self.bytes[self.confidence_.offset..][0..self.confidence_.length], bit_offset, confidence_width);
            if (value > @intFromEnum(Certainty.certain)) return error.InvalidConfidence;
            return @enumFromInt(@as(u2, @intCast(value)));
        }

        fn boundaryRange(self: *const Self, concept: usize) SourceError!MemberRange {
            const marker = try self.boundaries.select1(concept);
            if (marker < concept) return error.InvalidRange;
            const start = marker - concept;
            const end = if (concept + 1 < self.concept_count_) blk: {
                const next_marker = try self.boundaries.select1(concept + 1);
                if (next_marker < concept + 1) return error.InvalidRange;
                break :blk next_marker - (concept + 1);
            } else self.membership_count_;
            if (start > end or end > self.membership_count_) return error.InvalidRange;
            return .{ .start = start, .end = end };
        }

        /// Linear integrity validation of all packed values and both reverse
        /// projections.  It is idempotent and does not allocate.
        pub fn verify(self: *Self) SourceError!void {
            if (self.verified_) return;
            // Fetching the complete source is the authentication boundary for
            // mapped sections.  Raw slices simply return a borrowed view.
            self.bytes = try sourceBytes(Source, &self.source, 0, self.total_len_);
            if (self.presence_) |*presence| try presence.verify();
            try self.boundaries.verify();

            if (!paddingIsZero(self.bytes[self.forward_.offset..][0..self.forward_.length], try checkedMul(self.sense_count_, self.forward_width_)))
                return error.InvalidEncoding;
            if (!paddingIsZero(self.bytes[self.confidence_.offset..][0..self.confidence_.length], try checkedMul(self.confidence_count_, confidence_width)))
                return error.InvalidEncoding;
            if (!paddingIsZero(self.bytes[self.reverse_.offset..][0..self.reverse_.length], try checkedMul(self.membership_count_, self.sense_width_)))
                return error.InvalidEncoding;

            var assigned: usize = 0;
            var confident: usize = 0;
            for (0..self.sense_count_) |sense| {
                const code = try self.forwardCode(sense);
                if (code > self.concept_count_) return error.InvalidEncoding;
                if (code != self.concept_count_) assigned += 1;
                if (self.presence_) |presence| {
                    const present = try presence.get(sense);
                    if (present and code == self.concept_count_) return error.InvalidMembership;
                    if (present) {
                        _ = try self.confidenceAt(sense);
                        confident += 1;
                    }
                }
            }
            if (assigned != self.membership_count_ or confident != self.confidence_count_)
                return error.InvalidMembership;

            var seen: usize = 0;
            for (0..self.concept_count_) |concept| {
                const member_range = try self.boundaryRange(concept);
                var previous: ?usize = null;
                var offset = member_range.start;
                while (offset < member_range.end) : (offset += 1) {
                    const sense = try self.reverseSenseAt(offset);
                    const sense_index = @as(usize, @intFromEnum(sense));
                    if (previous) |prior| if (sense_index <= prior) return error.InvalidMembership;
                    previous = sense_index;
                    if (try self.forwardCode(sense_index) != concept) return error.InvalidMembership;
                    seen += 1;
                }
            }
            if (seen != self.membership_count_) return error.InvalidMembership;
            self.verified_ = true;
        }

        pub fn conceptOf(self: *const Self, sense: SenseRank) SourceError!?Rank(concept_kind) {
            try self.ensureVerified();
            const index = try self.senseIndex(sense);
            const code = try self.forwardCode(index);
            if (code == self.concept_count_) return null;
            return @enumFromInt(std.math.cast(u32, code) orelse return error.Overflow);
        }

        pub fn confidence(self: *const Self, sense: SenseRank) SourceError!?Confidence {
            try self.ensureVerified();
            const index = try self.senseIndex(sense);
            _ = try self.forwardCode(index);
            return self.confidenceAt(index);
        }

        pub fn membership(self: *const Self, sense: SenseRank) SourceError!?Record {
            const concept = try self.conceptOf(sense) orelse return null;
            return .{ .sense = sense, .concept = concept, .confidence = try self.confidence(sense) };
        }

        pub fn range(self: *const Self, concept: Rank(concept_kind)) SourceError!MemberRange {
            try self.ensureVerified();
            return self.boundaryRange(try self.conceptIndex(concept));
        }

        pub fn memberRange(self: *const Self, concept: Rank(concept_kind)) SourceError!MemberRange {
            return self.range(concept);
        }

        pub fn select(self: *const Self, concept: Rank(concept_kind), ordinal: usize) SourceError!SenseRank {
            const member_range = try self.range(concept);
            if (ordinal >= member_range.len()) return error.OutOfRange;
            return self.reverseSenseAt(member_range.start + ordinal);
        }

        pub fn reverseSelect(self: *const Self, ordinal: usize) SourceError!SenseRank {
            try self.ensureVerified();
            if (ordinal >= self.membership_count_) return error.OutOfRange;
            return self.reverseSenseAt(ordinal);
        }

        pub fn members(self: *const Self, concept: Rank(concept_kind)) SourceError!MemberIteratorFor(concept_kind, Source) {
            const member_range = try self.range(concept);
            return .{ .view = self, .cursor = member_range.start, .end = member_range.end };
        }

        pub fn conceptMembers(self: *const Self, concept: Rank(concept_kind)) SourceError!MemberIteratorFor(concept_kind, Source) {
            return self.members(concept);
        }

        pub fn synonyms(self: *const Self, sense: SenseRank) SourceError!MemberIteratorFor(concept_kind, Source) {
            if (concept_kind != .concept) return error.WrongMembershipKind;
            const concept = try self.conceptOf(sense) orelse return .{ .view = self, .cursor = 0, .end = 0 };
            const member_range = try self.range(concept);
            return .{ .view = self, .cursor = member_range.start, .end = member_range.end, .skip = sense };
        }

        /// Return interlingual members in `target` language.  `languages` is
        /// the inherited sense-language column in sense-rank order; it is
        /// borrowed for the lifetime of the iterator and never copied.
        pub fn translations(self: *const Self, sense: SenseRank, target: LanguageTag, languages: []const LanguageTag) SourceError!MemberIteratorFor(concept_kind, Source) {
            if (concept_kind != .interlingual) return error.WrongMembershipKind;
            if (languages.len != self.sense_count_) return error.InvalidEncoding;
            const concept = try self.conceptOf(sense) orelse return .{ .view = self, .cursor = 0, .end = 0, .skip = sense, .languages = languages, .target = target };
            const member_range = try self.range(concept);
            return .{ .view = self, .cursor = member_range.start, .end = member_range.end, .skip = sense, .languages = languages, .target = target };
        }

        pub fn translationsWithLanguages(self: *const Self, sense: SenseRank, languages: []const LanguageTag, target: LanguageTag) SourceError!MemberIteratorFor(concept_kind, Source) {
            return self.translations(sense, target, languages);
        }

        pub fn translationsUnfiltered(self: *const Self, sense: SenseRank) SourceError!MemberIteratorFor(concept_kind, Source) {
            if (concept_kind != .interlingual) return error.WrongMembershipKind;
            const concept = try self.conceptOf(sense) orelse return .{ .view = self, .cursor = 0, .end = 0, .skip = sense };
            const member_range = try self.range(concept);
            return .{ .view = self, .cursor = member_range.start, .end = member_range.end, .skip = sense };
        }
    };
}

pub fn MemberIteratorFor(comptime concept_kind: Kind, comptime Source: type) type {
    requireConceptKind(concept_kind);
    const View = ViewForSource(concept_kind, Source);
    const Record = MembershipRecord(concept_kind);
    const SourceError = sourceError(Source);
    return struct {
        view: *const View,
        cursor: usize,
        end: usize,
        skip: ?SenseRank = null,
        languages: ?[]const LanguageTag = null,
        target: ?LanguageTag = null,

        pub fn next(self: *@This()) SourceError!?SenseRank {
            while (self.cursor < self.end) {
                const sense = try self.view.reverseSenseAt(self.cursor);
                self.cursor += 1;
                if (self.skip) |skip| if (sense == skip) continue;
                if (self.languages) |languages| {
                    const index = @as(usize, @intFromEnum(sense));
                    if (languages[index] != self.target.?) continue;
                }
                return sense;
            }
            return null;
        }

        pub fn nextMembership(self: *@This()) SourceError!?Record {
            const sense = try self.next() orelse return null;
            return try self.view.membership(sense);
        }

        pub fn remaining(self: *const @This()) usize {
            return self.end - self.cursor;
        }
    };
}

pub fn MemberIterator(comptime concept_kind: Kind) type {
    return MemberIteratorFor(concept_kind, []const u8);
}

pub fn ViewFor(comptime concept_kind: Kind) type {
    return ViewForSource(concept_kind, []const u8);
}

pub fn SourceViewFor(comptime concept_kind: Kind, comptime Source: type) type {
    return ViewForSource(concept_kind, Source);
}

pub const ConceptView = ViewFor(.concept);
pub const InterlingualView = ViewFor(.interlingual);

/// Explicit spelling for callers that select an authenticated source at
/// comptime.  `SourceViewFor(kind, Source)` remains the primary form.
pub fn BorrowedView(comptime concept_kind: Kind, comptime Source: type) type {
    return ViewForSource(concept_kind, Source);
}

pub fn open(comptime concept_kind: Kind, bytes: []const u8) Error!ViewFor(concept_kind) {
    return ViewFor(concept_kind).open(bytes);
}

pub fn openWithLimits(comptime concept_kind: Kind, bytes: []const u8, limits: Limits) Error!ViewFor(concept_kind) {
    return ViewFor(concept_kind).openWithLimits(bytes, limits);
}

test "concept memberships are canonical and expose typed reverse access" {
    const Record = MembershipRecord(.concept);
    const records = [_]Record{
        .{ .sense = @enumFromInt(5), .concept = @enumFromInt(2), .confidence = .certain },
        .{ .sense = @enumFromInt(1), .concept = @enumFromInt(0) },
        .{ .sense = @enumFromInt(3), .concept = @enumFromInt(1), .confidence = .possible },
    };
    var owned = try build(.concept, std.testing.allocator, 8, 3, &records);
    defer owned.deinit();

    var unverified = try owned.openView();
    try std.testing.expect(!unverified.isVerified());
    try std.testing.expectError(error.Unverified, unverified.conceptOf(@enumFromInt(1)));

    var view = try owned.view();
    try std.testing.expect(view.isVerified());
    try std.testing.expectEqual(@as(usize, 8), view.senseCount());
    try std.testing.expectEqual(@as(usize, 3), view.conceptCount());
    try std.testing.expectEqual(@as(usize, 3), view.membershipCount());
    try std.testing.expectEqual(@as(usize, 2), view.confidenceCount());
    try std.testing.expectEqual(@as(usize, 0), @intFromEnum((try view.conceptOf(@enumFromInt(1))).?));
    try std.testing.expectEqual(@as(?Confidence, null), try view.confidence(@enumFromInt(1)));
    try std.testing.expectEqual(Confidence.possible, (try view.confidence(@enumFromInt(3))).?);
    try std.testing.expect((try view.conceptOf(@enumFromInt(0))) == null);

    const range = try view.range(@enumFromInt(0));
    try std.testing.expectEqual(@as(usize, 1), range.len());
    try std.testing.expectEqual(@as(usize, 1), @intFromEnum(try view.select(@enumFromInt(0), 0)));
    try std.testing.expectEqual(@as(usize, 3), @intFromEnum(try view.select(@enumFromInt(1), 0)));
    try std.testing.expectEqual(@as(usize, 5), @intFromEnum(try view.select(@enumFromInt(2), 0)));

    var members = try view.members(@enumFromInt(1));
    try std.testing.expectEqual(@as(usize, 3), @intFromEnum((try members.next()).?));
    try std.testing.expectEqual(@as(?SenseRank, null), try members.next());

    var synonyms = try view.synonyms(@enumFromInt(3));
    try std.testing.expectEqual(@as(?SenseRank, null), try synonyms.next());
}

test "concept encoding is deterministic across input order and confidence omission" {
    const Record = MembershipRecord(.concept);
    const ordered = [_]Record{
        .{ .sense = @enumFromInt(0), .concept = @enumFromInt(0) },
        .{ .sense = @enumFromInt(2), .concept = @enumFromInt(1) },
        .{ .sense = @enumFromInt(4), .concept = @enumFromInt(0) },
    };
    const permuted = [_]Record{ ordered[2], ordered[0], ordered[1] };
    var first = try build(.concept, std.testing.allocator, 7, 2, &ordered);
    defer first.deinit();
    var second = try build(.concept, std.testing.allocator, 7, 2, &permuted);
    defer second.deinit();
    try std.testing.expectEqualSlices(u8, first.bytes, second.bytes);

    try std.testing.expectEqual(@as(u8, 0), first.bytes[9]);
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, first.bytes[72..80], .little));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, first.bytes[88..96], .little));
    var view = try first.view();
    try std.testing.expectEqual(@as(?Confidence, null), try view.confidence(@enumFromInt(0)));
}

test "empty and zero-concept membership domains remain valid" {
    const empty = [_]ConceptMembership{};
    var owned = try build(.concept, std.testing.allocator, 0, 0, &empty);
    defer owned.deinit();
    var view = try owned.view();
    try std.testing.expectEqual(@as(usize, 0), view.senseCount());
    try std.testing.expectEqual(@as(usize, 0), view.conceptCount());
    try std.testing.expectEqual(@as(usize, 0), view.membershipCount());

    var no_concepts = try build(.concept, std.testing.allocator, 5, 0, &empty);
    defer no_concepts.deinit();
    var no_concept_view = try no_concepts.view();
    try std.testing.expect((try no_concept_view.conceptOf(@enumFromInt(4))) == null);
    try std.testing.expectError(error.OutOfRange, no_concept_view.conceptOf(@enumFromInt(5)));
}

test "interlingual translations filter borrowed inherited language values" {
    const Record = MembershipRecord(.interlingual);
    const records = [_]Record{
        .{ .sense = @enumFromInt(0), .concept = @enumFromInt(0) },
        .{ .sense = @enumFromInt(2), .concept = @enumFromInt(0) },
        .{ .sense = @enumFromInt(4), .concept = @enumFromInt(0) },
        .{ .sense = @enumFromInt(1), .concept = @enumFromInt(1) },
    };
    var owned = try build(.interlingual, std.testing.allocator, 5, 2, &records);
    defer owned.deinit();
    var view = try owned.view();
    const languages = [_]LanguageTag{
        .{ .language = 1 },
        .{ .language = 2 },
        .{ .language = 2 },
        .{ .language = 3 },
        .{ .language = 2 },
    };
    var translations = try view.translations(@enumFromInt(0), .{ .language = 2 }, &languages);
    try std.testing.expectEqual(@as(usize, 2), @intFromEnum((try translations.next()).?));
    try std.testing.expectEqual(@as(usize, 4), @intFromEnum((try translations.next()).?));
    try std.testing.expectEqual(@as(?SenseRank, null), try translations.next());
    try std.testing.expectError(error.InvalidEncoding, view.translations(@enumFromInt(0), .{ .language = 2 }, languages[0..4]));
}

test "concept wire open is cheap and verify rejects packed corruption" {
    const records = [_]ConceptMembership{
        .{ .sense = @enumFromInt(0), .concept = @enumFromInt(0) },
    };
    var owned = try build(.concept, std.testing.allocator, 2, 1, &records);
    defer owned.deinit();
    const forward_at = std.mem.readInt(u64, owned.bytes[48..56], .little);
    owned.bytes[@intCast(forward_at)] ^= 0x02;
    var view = try ConceptView.open(owned.bytes);
    try std.testing.expect(!view.isVerified());
    try std.testing.expectError(error.InvalidMembership, view.verify());
}

test "nested confidence envelope opens before payload verification" {
    const records = [_]ConceptMembership{
        .{ .sense = @enumFromInt(0), .concept = @enumFromInt(0), .confidence = .certain },
    };
    var owned = try build(.concept, std.testing.allocator, 2, 1, &records);
    defer owned.deinit();
    const presence_at = std.mem.readInt(u64, owned.bytes[64..72], .little);
    const nested_payload_at = std.mem.readInt(u64, owned.bytes[@intCast(presence_at + 64)..][0..8], .little);
    owned.bytes[@intCast(presence_at + nested_payload_at)] ^= 0x01;
    var view = try ConceptView.open(owned.bytes);
    try std.testing.expect(!view.isVerified());
    try std.testing.expectError(error.InvalidEncoding, view.verify());
}

test "rank domains are not interchangeable in the membership API" {
    try std.testing.expect(Rank(.concept) != Rank(.interlingual));
    try std.testing.expect(Rank(.sense) != Rank(.concept));
    try std.testing.expect(MembershipRecord(.concept) != MembershipRecord(.interlingual));
}

fn allocationFailureBuild(allocator: std.mem.Allocator) !void {
    const records = [_]ConceptMembership{
        .{ .sense = @enumFromInt(0), .concept = @enumFromInt(0), .confidence = .certain },
        .{ .sense = @enumFromInt(2), .concept = @enumFromInt(1) },
    };
    var owned = try build(.concept, allocator, 9, 3, &records);
    owned.deinit();
}

test "concept builder releases every allocation on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureBuild, .{});
}

fn allocationFailureBuilder(allocator: std.mem.Allocator) !void {
    var builder = Builder(.concept).init(allocator, 9, 3);
    defer builder.deinit();
    try builder.putWithConfidence(@enumFromInt(0), @enumFromInt(0), .certain);
    try builder.put(@enumFromInt(2), @enumFromInt(1));
    var owned = try builder.finish();
    owned.deinit();
}

test "incremental concept builder releases records on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureBuilder, .{});
}

test "generic membership view keeps an authenticated source borrowed" {
    const records = [_]ConceptMembership{
        .{ .sense = @enumFromInt(0), .concept = @enumFromInt(0) },
        .{ .sense = @enumFromInt(2), .concept = @enumFromInt(0) },
    };
    var owned = try build(.concept, std.testing.allocator, 4, 1, &records);
    defer owned.deinit();

    const Source = struct {
        data: []const u8,

        pub fn len(self: *const @This()) usize {
            return self.data.len;
        }

        pub fn bytes(self: *@This(), offset: usize, length: usize) anyerror![]const u8 {
            if (offset > self.data.len or length > self.data.len - offset) return error.Truncated;
            return self.data[offset..][0..length];
        }
    };

    const Borrowed = BorrowedView(.concept, Source);
    var view = try Borrowed.open(.{ .data = owned.bytes });
    try std.testing.expect(!view.isVerified());
    try std.testing.expectError(error.Unverified, view.conceptOf(@enumFromInt(0)));
    try view.verify();
    var members = try view.members(@enumFromInt(0));
    try std.testing.expectEqual(@as(usize, 0), @intFromEnum((try members.next()).?));
    try std.testing.expectEqual(@as(usize, 2), @intFromEnum((try members.next()).?));
    try std.testing.expect((try members.next()) == null);
}

test "membership cluster ablation includes all wire directories" {
    const cluster_sizes = [_]usize{ 1, 2, 4, 8, 16, 32 };
    for (cluster_sizes) |cluster_size| {
        const records = try std.testing.allocator.alloc(ConceptMembership, cluster_size);
        defer std.testing.allocator.free(records);
        for (records, 0..) |*record, sense| {
            record.* = .{ .sense = @enumFromInt(sense), .concept = @enumFromInt(0) };
        }
        var owned = try build(.concept, std.testing.allocator, cluster_size, 1, records);
        defer owned.deinit();

        // A pairwise relation pays one 32-byte physical claim and one
        // 16-byte adjacency record per directed edge, plus its fixed envelope.
        // The membership wire's nested bitvector headers/directories are all
        // included in `owned.bytes.len`.
        const pairwise = try pairwiseBaseline(cluster_size, 112, 48);
        try std.testing.expectEqual(cluster_size * (cluster_size - 1), pairwise.directed_edge_count);
        if (cluster_size >= 16)
            try std.testing.expect(owned.bytes.len * cluster_size <= pairwise.total_bytes);
    }
}
