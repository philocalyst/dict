//! LEX4's envelope and lazy integrity boundary.
//!
//! `open` validates only the header and directory. Section bytes are exposed
//! through `Section.bytes`, which authenticates every intersecting 64 KiB page
//! before returning it. Callers may supply trust bits to make that cost exactly
//! once per mapped page, or an empty slice to choose stateless re-verification.

const std = @import("std");
const wire = @import("wire.zig");

const Blake3 = std.crypto.hash.Blake3;

pub const page_size: usize = 64 * 1024;
pub const digest_size: usize = 16;
pub const alignment: usize = 8;
pub const version: u16 = 1;

pub const Tag = enum(u32) {
    automaton = 0x4154_554f,
    forest = 0x464f_5245,
    columns = 0x434f_4c53,
    prose = 0x5052_4f53,
    /// Canonical optional search/index records. Keeping these as discoverable
    /// envelope tags makes their presence visible in the authenticated
    /// directory; callers never have to guess an offset inside `.cold`.
    normalized = 0x4e4f_524d,
    phonetic = 0x5048_4f4e,
    reversed = 0x5245_5653,
    terms = 0x5445_524d,
    concepts = 0x434f_4e43,
    relations = 0x5245_4c53,
    cold = 0x434f_4c44,
    metadata = 0x4d45_5441,
    rich_content = 0x5249_4348,
    _,
};

pub const Header = struct {
    magic: [8]u8,
    version: u16,
    flags: u16,
    section_count: u32,
    directory_offset: u64,
    directory_length: u64,
    digest_offset: u64,
    digest_length: u64,
    file_length: u64,
    schema_digest: [digest_size]u8,
    directory_digest: [digest_size]u8,
};

pub const Descriptor = struct {
    tag: Tag,
    flags: u32,
    offset: u64,
    length: u64,
    first_page: u32,
    page_count: u32,
};

const HeaderWire = wire.Layout(Header);
const DescriptorWire = wire.Layout(Descriptor);
pub const header_size = HeaderWire.size;
pub const descriptor_size = DescriptorWire.size;

pub const Error = wire.Error || error{
    BadMagic,
    UnsupportedVersion,
    LengthMismatch,
    InvalidDirectory,
    UnknownSection,
    DuplicateSection,
    SectionsOutOfOrder,
    MissingSection,
    EmptySection,
    MisalignedSection,
    InvalidDigestTable,
    IntegrityFailure,
    InsufficientTrustStorage,
};

pub const Input = struct {
    tag: Tag,
    bytes: []const u8,
    flags: u32 = 0,
};

fn isKnownTag(tag: Tag) bool {
    return switch (tag) {
        .automaton, .forest, .columns, .prose, .normalized, .phonetic, .reversed, .terms, .concepts, .relations, .cold, .metadata, .rich_content => true,
        _ => false,
    };
}

fn digest(bytes: []const u8) [digest_size]u8 {
    var result: [digest_size]u8 = undefined;
    Blake3.hash(bytes, &result, .{});
    return result;
}

fn pageCount(length: usize) Error!usize {
    if (length == 0) return error.EmptySection;
    return (try wire.add(length, page_size - 1)) / page_size;
}

/// Builds a canonical container. Inputs must be sorted by numeric tag; making
/// canonical ordering a precondition prevents accidental nondeterminism from
/// hash-map iteration in compilers.
pub fn build(allocator: std.mem.Allocator, schema_digest: [digest_size]u8, inputs: []const Input) Error![]u8 {
    if (inputs.len == 0) return error.InvalidDirectory;
    if (inputs.len > std.math.maxInt(u32)) return error.Overflow;
    var total_pages: usize = 0;
    for (inputs, 0..) |input, index| {
        if (!isKnownTag(input.tag)) return error.UnknownSection;
        if (input.bytes.len == 0) return error.EmptySection;
        if (index != 0) {
            const prior = @intFromEnum(inputs[index - 1].tag);
            const current = @intFromEnum(input.tag);
            if (prior == current) return error.DuplicateSection;
            if (prior > current) return error.SectionsOutOfOrder;
        }
        total_pages = try wire.add(total_pages, try pageCount(input.bytes.len));
    }

    const directory_length = try wire.mul(inputs.len, descriptor_size);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendNTimes(allocator, 0, try wire.add(header_size, directory_length));
    try wire.padTo(&out, allocator, alignment);

    var descriptors = try allocator.alloc(Descriptor, inputs.len);
    defer allocator.free(descriptors);
    var next_page: usize = 0;
    for (inputs, 0..) |input, index| {
        try wire.padTo(&out, allocator, alignment);
        const offset = out.items.len;
        try out.appendSlice(allocator, input.bytes);
        const count = try pageCount(input.bytes.len);
        descriptors[index] = .{
            .tag = input.tag,
            .flags = input.flags,
            .offset = try wire.cast(u64, offset),
            .length = try wire.cast(u64, input.bytes.len),
            .first_page = try wire.cast(u32, next_page),
            .page_count = try wire.cast(u32, count),
        };
        next_page = try wire.add(next_page, count);
    }

    try wire.padTo(&out, allocator, alignment);
    const digest_offset = out.items.len;
    for (inputs) |input| {
        var offset: usize = 0;
        while (offset < input.bytes.len) : (offset += page_size) {
            const end = @min(input.bytes.len, offset +| page_size);
            try out.appendSlice(allocator, &digest(input.bytes[offset..end]));
        }
    }
    if (next_page != total_pages) unreachable;

    for (descriptors, 0..) |descriptor, index|
        try DescriptorWire.write(out.items, header_size + index * descriptor_size, descriptor);
    const directory = out.items[header_size..][0..directory_length];
    try HeaderWire.write(out.items, 0, .{
        .magic = "LEX4\r\n\x1a\n".*,
        .version = version,
        .flags = 0,
        .section_count = @intCast(inputs.len),
        .directory_offset = header_size,
        .directory_length = try wire.cast(u64, directory_length),
        .digest_offset = try wire.cast(u64, digest_offset),
        .digest_length = try wire.cast(u64, try wire.mul(total_pages, digest_size)),
        .file_length = try wire.cast(u64, out.items.len),
        .schema_digest = schema_digest,
        .directory_digest = digest(directory),
    });
    return out.toOwnedSlice(allocator);
}

pub const Container = struct {
    bytes: []const u8,
    header: Header,
    directory: []const u8,
    digests: []const u8,
    trust: []u64,

    /// `trust` is optional caller-owned cache storage. If supplied, opening
    /// clears it and requires enough bits for every page in the snapshot.
    pub fn open(bytes: []const u8, trust: []u64) Error!Container {
        const header = try HeaderWire.read(bytes, 0);
        if (!std.mem.eql(u8, &header.magic, "LEX4\r\n\x1a\n")) return error.BadMagic;
        if (header.version != version) return error.UnsupportedVersion;
        if (header.flags != 0 or header.section_count == 0) return error.InvalidDirectory;
        if (header.file_length != bytes.len) return error.LengthMismatch;
        if (header.directory_offset != header_size) return error.InvalidDirectory;
        const expected_directory = try wire.mul(header.section_count, descriptor_size);
        if (header.directory_length != expected_directory) return error.InvalidDirectory;
        const directory = try wire.bytesAt(bytes, try wire.cast(usize, header.directory_offset), expected_directory);
        if (!std.mem.eql(u8, &digest(directory), &header.directory_digest)) return error.IntegrityFailure;
        const digest_bytes = try wire.bytesAt(bytes, try wire.cast(usize, header.digest_offset), try wire.cast(usize, header.digest_length));
        if (header.digest_length % digest_size != 0) return error.InvalidDigestTable;
        if (try wire.add(try wire.cast(usize, header.digest_offset), digest_bytes.len) != bytes.len)
            return error.InvalidDigestTable;

        var previous_tag: ?u32 = null;
        var expected_page: usize = 0;
        var previous_end = try wire.alignForward(header_size + expected_directory, alignment);
        for (0..header.section_count) |index| {
            const descriptor = try DescriptorWire.read(directory, index * descriptor_size);
            const tag = @intFromEnum(descriptor.tag);
            if (!isKnownTag(descriptor.tag)) return error.UnknownSection;
            if (previous_tag) |previous| {
                if (tag == previous) return error.DuplicateSection;
                if (tag < previous) return error.SectionsOutOfOrder;
            }
            previous_tag = tag;
            if (descriptor.length == 0) return error.EmptySection;
            const offset = try wire.cast(usize, descriptor.offset);
            const length = try wire.cast(usize, descriptor.length);
            if (offset % alignment != 0) return error.MisalignedSection;
            if (offset < previous_end) return error.InvalidDirectory;
            _ = try wire.bytesAt(bytes, offset, length);
            previous_end = try wire.add(offset, length);
            const pages = try pageCount(length);
            if (descriptor.first_page != expected_page or descriptor.page_count != pages)
                return error.InvalidDigestTable;
            expected_page = try wire.add(expected_page, pages);
        }
        const digest_offset = try wire.cast(usize, header.digest_offset);
        if (digest_offset % alignment != 0 or digest_offset < try wire.alignForward(previous_end, alignment))
            return error.InvalidDigestTable;
        if (try wire.mul(expected_page, digest_size) != digest_bytes.len) return error.InvalidDigestTable;
        const required_words = (try wire.add(expected_page, 63)) / 64;
        if (trust.len != 0 and trust.len < required_words) return error.InsufficientTrustStorage;
        if (trust.len != 0) @memset(trust[0..required_words], 0);
        return .{ .bytes = bytes, .header = header, .directory = directory, .digests = digest_bytes, .trust = trust };
    }

    pub fn schemaDigest(self: *const Container) [digest_size]u8 {
        return self.header.schema_digest;
    }

    pub fn find(self: *const Container, tag: Tag) Error!Section {
        var lo: usize = 0;
        var hi: usize = self.header.section_count;
        const wanted = @intFromEnum(tag);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const candidate = try DescriptorWire.read(self.directory, mid * descriptor_size);
            const value = @intFromEnum(candidate.tag);
            if (value == wanted) return .{ .mapping = self.bytes, .digests = self.digests, .trust = self.trust, .descriptor = candidate };
            if (value < wanted) lo = mid + 1 else hi = mid;
        }
        return error.MissingSection;
    }

    pub fn verify(self: *Container) Error!void {
        for (0..self.header.section_count) |index| {
            const descriptor = try DescriptorWire.read(self.directory, index * descriptor_size);
            var section = Section{ .mapping = self.bytes, .digests = self.digests, .trust = self.trust, .descriptor = descriptor };
            _ = try section.bytes(0, try wire.cast(usize, descriptor.length));
        }
    }
};

pub const Section = struct {
    mapping: []const u8,
    digests: []const u8,
    trust: []u64,
    descriptor: Descriptor,

    pub fn len(self: Section) usize {
        return @intCast(self.descriptor.length);
    }

    pub fn bytes(self: *const Section, offset: usize, length: usize) Error![]const u8 {
        if (offset > self.len() or length > self.len() - offset) return error.Truncated;
        const section_bytes = try wire.bytesAt(
            self.mapping,
            try wire.add(try wire.cast(usize, self.descriptor.offset), offset),
            length,
        );
        if (length == 0) return section_bytes;
        const first = offset / page_size;
        const last = (offset + length - 1) / page_size;
        for (first..last + 1) |local_page| {
            const global_page = try wire.add(self.descriptor.first_page, local_page);
            if (self.trust.len != 0 and self.trust[global_page / 64] & (@as(u64, 1) << @as(u6, @intCast(global_page % 64))) != 0) continue;
            const page_start = local_page * page_size;
            const page_end = @min(self.len(), page_start +| page_size);
            const entire_page = try wire.bytesAt(
                self.mapping,
                try wire.add(try wire.cast(usize, self.descriptor.offset), page_start),
                page_end - page_start,
            );
            const expected = try wire.bytesAt(self.digests, try wire.mul(global_page, digest_size), digest_size);
            if (!std.mem.eql(u8, &digest(entire_page), expected)) return error.IntegrityFailure;
            if (self.trust.len != 0) self.trust[global_page / 64] |= @as(u64, 1) << @as(u6, @intCast(global_page % 64));
        }
        return section_bytes;
    }
};

/// Authenticated range source for monomorphized section readers. A format
/// module parameterized by this type cannot accidentally index mapped bytes
/// without first crossing the page-integrity boundary.
pub const SectionSource = struct {
    section: Section,

    pub fn read(self: *const SectionSource, offset: usize, length: usize) Error![]const u8 {
        return self.section.bytes(offset, length);
    }

    pub fn bytes(self: *const SectionSource, offset: usize, length: usize) Error![]const u8 {
        return self.read(offset, length);
    }

    pub fn len(self: *const SectionSource) usize {
        return self.section.len();
    }
};

/// Plain slice source for already-trusted buffers, builders, and unit tests.
/// It deliberately has the same tiny interface as `SectionSource` so readers
/// can select integrity policy at comptime without virtual dispatch.
pub const SliceSource = struct {
    data: []const u8,

    pub fn read(self: *const SliceSource, offset: usize, length: usize) wire.Error![]const u8 {
        return wire.bytesAt(self.data, offset, length);
    }

    pub fn bytes(self: *const SliceSource, offset: usize, length: usize) wire.Error![]const u8 {
        return self.read(offset, length);
    }

    pub fn len(self: *const SliceSource) usize {
        return self.data.len;
    }
};

test "open is envelope-only and section access authenticates lazily" {
    const allocator = std.testing.allocator;
    const first = try allocator.alloc(u8, page_size + 9);
    defer allocator.free(first);
    @memset(first, 0xa5);
    const owned = try build(allocator, [_]u8{7} ** digest_size, &.{
        .{ .tag = .automaton, .bytes = first },
        .{ .tag = .prose, .bytes = "grammar symbols" },
    });
    defer allocator.free(owned);

    var trust = [_]u64{0};
    var container = try Container.open(owned, &trust);
    try std.testing.expectEqual(@as(u64, 0), trust[0]);
    var section = try container.find(.automaton);
    try std.testing.expectEqualSlices(u8, first[page_size - 2 .. page_size + 2], try section.bytes(page_size - 2, 4));
    try std.testing.expectEqual(@as(u64, 3), trust[0] & 3);
    try container.verify();
    try std.testing.expectEqual(@as(u64, 7), trust[0] & 7);
}

test "corruption is isolated until its page is touched" {
    const allocator = std.testing.allocator;
    const original = [_]u8{0x42} ** (page_size + 1);
    const encoded = try build(allocator, [_]u8{0} ** digest_size, &.{.{ .tag = .automaton, .bytes = &original }});
    defer allocator.free(encoded);
    encoded[header_size + descriptor_size + page_size] ^= 1;
    var container = try Container.open(encoded, &.{});
    var section = try container.find(.automaton);
    _ = try section.bytes(0, 1);
    try std.testing.expectError(error.IntegrityFailure, section.bytes(page_size, 1));
}

test "canonical section order is explicit" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidDirectory, build(allocator, [_]u8{0} ** digest_size, &.{}));
    try std.testing.expectError(error.SectionsOutOfOrder, build(allocator, [_]u8{0} ** digest_size, &.{
        .{ .tag = .prose, .bytes = "p" },
        .{ .tag = .automaton, .bytes = "a" },
    }));
    try std.testing.expectError(error.DuplicateSection, build(allocator, [_]u8{0} ** digest_size, &.{
        .{ .tag = .automaton, .bytes = "a" },
        .{ .tag = .automaton, .bytes = "b" },
    }));
}

test "authenticated and trusted sources share one monomorphic contract" {
    const allocator = std.testing.allocator;
    const owned = try build(allocator, [_]u8{0} ** digest_size, &.{.{ .tag = .metadata, .bytes = "abcdef" }});
    defer allocator.free(owned);
    var trust = [_]u64{0};
    var container = try Container.open(owned, &trust);
    var mapped = SectionSource{ .section = try container.find(.metadata) };
    try std.testing.expectEqualStrings("bcd", try mapped.read(1, 3));
    try std.testing.expectEqual(@as(u64, 1), trust[0]);
    const trusted = SliceSource{ .data = "abcdef" };
    try std.testing.expectEqualStrings("bcd", try trusted.read(1, 3));
}
