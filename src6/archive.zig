//! Immutable LEX6 archives: a hot lexical index over independently bounded
//! entry pages. Opening validates the complete metadata root without touching
//! a compressed page. Page SHA-256 digests are integrity checks, not proof of
//! origin or authenticity.
const std = @import("std");
const model = @import("model.zig");
const packet = @import("packet.zig");
const compression = @import("compression.zig");
const validate = @import("validate.zig");
const query = @import("query.zig");
const packet_view = @import("packet_view.zig");
const construction = @import("construction.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const digest_length = Sha256.digest_length;
const magic = "LEX6AR01";
const version: u16 = 3;
const header_size: usize = 112;
const directory_record_size: usize = 64;

/// The address carries a compile-time document kind, not a runtime tag. A
/// resource address cannot accidentally request an entry-shaped decode.
fn Id(comptime kind: std.meta.Tag(model.Document)) type {
    return packed struct(u32) {
        value: u32,
        const document_kind = kind;
        const Payload = @FieldType(model.Document, @tagName(kind));
    };
}

pub const EntryId = Id(.entry);
/// Physical document ordinal. Resources follow all entry documents.
pub const ResourceId = Id(.resource);

pub const ResourceKind = std.meta.Tag(model.Resource);

pub const ResourceHit = struct {
    resource: ResourceId,
    identity: []const u8,
    kind: ResourceKind,
    source_length: ?usize,
};

pub const Options = struct {
    /// An optional hot logical-identity projection. It trades fully charged
    /// metadata bytes for link preparation without decoding any entry pages.
    index_entry_ids: bool = false,
    target_page_bytes: usize = 64 * 1024,
    max_page_bytes: usize = 1024 * 1024,
    max_document_bytes: usize = 1024 * 1024,
    max_key_bytes: usize = 64 * 1024,
    max_hits: usize = 100_000_000,
    max_resources: usize = 10_000_000,
    compression: compression.Mode = .adaptive,
    packet_limits: packet.Limits = .{},
    compression_limits: compression.Limits = .{},
    validation_limits: validate.Limits = .{},
    construction_limits: construction.Limits = .{},
};

pub const Limits = struct {
    max_archive_bytes: usize = 1024 * 1024 * 1024,
    max_entries: usize = 10_000_000,
    max_resources: usize = 10_000_000,
    max_pages: usize = 1_000_000,
    max_hits: usize = 100_000_000,
    max_index_bytes: usize = 512 * 1024 * 1024,
    max_key_bytes: usize = 64 * 1024,
    max_page_bytes: usize = 1024 * 1024,
    packet_limits: packet.Limits = .{},
    compression_limits: compression.Limits = .{},
    validation_limits: validate.Limits = .{},
    construction_limits: construction.Limits = .{},
};

pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

const InspectionStorage = union(enum) {
    page: compression.Block,
    packet: struct { allocator: std.mem.Allocator, bytes: []u8 },

    fn deinit(self: *InspectionStorage) void {
        switch (self.*) {
            .page => |*page| page.deinit(),
            .packet => |owned| owned.allocator.free(owned.bytes),
        }
        self.* = undefined;
    }
};

/// Native rich document access with strings borrowed from one owned wire
/// buffer. This result survives archive destruction and cache eviction. Its
/// structural arena and wire buffer have one explicit, independent lifetime.
pub fn Inspected(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,
        packet_bytes: []const u8,
        storage: InspectionStorage,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.storage.deinit();
            self.* = undefined;
        }
    };
}

pub const KeyView = struct {
    prefix: []const u8,
    suffix: []const u8,

    pub fn eql(self: KeyView, bytes: []const u8) bool {
        return bytes.len == self.prefix.len + self.suffix.len and
            std.mem.startsWith(u8, bytes, self.prefix) and
            std.mem.eql(u8, bytes[self.prefix.len..], self.suffix);
    }

    pub fn compare(self: KeyView, bytes: []const u8) std.math.Order {
        const prefix_bytes = bytes[0..@min(self.prefix.len, bytes.len)];
        const prefix_order = std.mem.order(u8, self.prefix, prefix_bytes);
        if (prefix_order != .eq) return prefix_order;
        return std.mem.order(u8, self.suffix, bytes[self.prefix.len..]);
    }

    pub fn startsWith(self: KeyView, bytes: []const u8) bool {
        if (bytes.len > self.prefix.len + self.suffix.len) return false;
        if (bytes.len <= self.prefix.len) return std.mem.startsWith(u8, self.prefix, bytes);
        return std.mem.eql(u8, self.prefix, bytes[0..self.prefix.len]) and
            std.mem.startsWith(u8, self.suffix, bytes[self.prefix.len..]);
    }

    fn compareView(self: KeyView, other: KeyView) std.math.Order {
        if (std.mem.eql(u8, self.prefix, other.prefix)) return std.mem.order(u8, self.suffix, other.suffix);
        var left_index: usize = 0;
        var right_index: usize = 0;
        const left_length = self.prefix.len + self.suffix.len;
        const right_length = other.prefix.len + other.suffix.len;
        while (left_index < left_length and right_index < right_length) : ({
            left_index += 1;
            right_index += 1;
        }) {
            const left = if (left_index < self.prefix.len) self.prefix[left_index] else self.suffix[left_index - self.prefix.len];
            const right = if (right_index < other.prefix.len) other.prefix[right_index] else other.suffix[right_index - other.prefix.len];
            if (left != right) return std.math.order(left, right);
        }
        return std.math.order(left_length, right_length);
    }

    pub fn writeTo(self: KeyView, writer: anytype) !void {
        try writer.writeAll(self.prefix);
        try writer.writeAll(self.suffix);
    }
};

pub const Hit = struct {
    entry: EntryId,
    spelling: KeyView,
    form: ?[]const u8,
};

const IndexRecord = struct {
    spelling: []const u8,
    form: ?[]const u8,
    entry: EntryId,
};

const ResourceRecord = struct {
    identity: []const u8,
    document: ResourceId,
    kind: ResourceKind,
    source_length: ?usize,
};

const index_restart_keys: usize = 16;

const DirectoryRecord = struct {
    offset: usize,
    encoded_length: usize,
    raw_length: usize,
    first_document: usize,
    document_count: usize,
    codec: compression.Codec,
    digest: [digest_length]u8,
};

const PageBuild = struct {
    first_document: usize,
    document_count: usize,
    raw: []u8,
};

pub fn build(allocator: std.mem.Allocator, library: model.Library, options: Options) !Owned {
    const document_count = std.math.add(usize, library.entries.len, library.resources.len) catch return error.TooManyEntries;
    if (document_count > std.math.maxInt(u32)) return error.TooManyEntries;
    if (library.resources.len > options.max_resources) return error.TooManyResources;
    if (options.target_page_bytes == 0 or options.target_page_bytes > options.max_page_bytes) return error.InvalidPageTarget;

    var semantic_ids = std.StringHashMapUnmanaged(void).empty;
    defer semantic_ids.deinit(allocator);
    var index_records: std.ArrayList(IndexRecord) = .empty;
    defer index_records.deinit(allocator);
    var pages: std.ArrayList(PageBuild) = .empty;
    defer {
        for (pages.items) |page| allocator.free(page.raw);
        pages.deinit(allocator);
    }

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    var first_document: usize = 0;
    var documents_in_page: usize = 0;

    var sources = validate.SourceIndex{};
    defer sources.deinit(allocator);
    for (library.resources) |resource| switch (resource) {
        .source => |source| {
            if (sources.count() >= options.validation_limits.max_values) return error.ResourceLimit;
            try sources.add(allocator, source.id, source.bytes.len);
        },
        else => {},
    };

    var resource_records: std.ArrayList(ResourceRecord) = .empty;
    defer resource_records.deinit(allocator);

    for (library.entries, 0..) |entry, entry_index| {
        try validate.check(allocator, &entry, .{ .limits = options.validation_limits, .construction = options.construction_limits, .sources = &sources });
        const admission = try semantic_ids.getOrPut(allocator, entry.id);
        if (admission.found_existing) return error.DuplicateEntryId;
        if (entry.headword.len > options.max_key_bytes) return error.KeyTooLong;
        if (index_records.items.len >= options.max_hits) return error.TooManyHits;
        try index_records.append(allocator, .{
            .spelling = entry.headword,
            .form = null,
            .entry = .{ .value = @intCast(entry_index) },
        });
        for (entry.keys) |key| {
            if (key.spelling.len > options.max_key_bytes) return error.KeyTooLong;
            if (key.form) |form| if (form.len > options.max_key_bytes) return error.KeyTooLong;
            if (index_records.items.len >= options.max_hits) return error.TooManyHits;
            try index_records.append(allocator, .{
                .spelling = key.spelling,
                .form = key.form,
                .entry = .{ .value = @intCast(entry_index) },
            });
        }

        try appendDocument(allocator, &pages, &raw, &first_document, &documents_in_page, entry_index, model.Document{ .entry = entry }, options);
    }
    for (library.resources, 0..) |resource, resource_index| {
        try validate.check(allocator, &resource, .{ .limits = options.validation_limits, .construction = options.construction_limits, .sources = &sources });
        const identity = resource.identity();
        if (identity.len > options.max_key_bytes) return error.KeyTooLong;
        const admission = try semantic_ids.getOrPut(allocator, identity);
        if (admission.found_existing) return error.DuplicateEntryId;
        const document_index = library.entries.len + resource_index;
        try resource_records.append(allocator, .{
            .identity = identity,
            .document = .{ .value = @intCast(document_index) },
            .kind = std.meta.activeTag(resource),
            .source_length = switch (resource) {
                .source => |source| source.bytes.len,
                else => null,
            },
        });
        try appendDocument(allocator, &pages, &raw, &first_document, &documents_in_page, document_index, model.Document{ .resource = resource }, options);
    }
    if (documents_in_page != 0) try finishPage(allocator, &pages, &raw, first_document, documents_in_page);

    std.sort.block(IndexRecord, index_records.items, {}, indexLessThan);
    std.sort.block(ResourceRecord, resource_records.items, {}, resourceLessThan);
    var lexical_index: std.ArrayList(u8) = .empty;
    defer lexical_index.deinit(allocator);
    try buildIndex(allocator, index_records.items, &lexical_index);
    var identities: std.ArrayList(u8) = .empty;
    defer identities.deinit(allocator);
    if (options.index_entry_ids) try buildIdentityIndex(allocator, library.entries, &identities);
    var catalog: std.ArrayList(u8) = .empty;
    defer catalog.deinit(allocator);
    try buildResourceCatalog(allocator, resource_records.items, &catalog);
    var index: std.ArrayList(u8) = .empty;
    defer index.deinit(allocator);
    if (lexical_index.items.len > std.math.maxInt(u32)) return error.ArchiveTooLarge;
    try appendU32(&index, allocator, @intCast(lexical_index.items.len));
    if (identities.items.len > std.math.maxInt(u32)) return error.ArchiveTooLarge;
    try appendU32(&index, allocator, @intCast(identities.items.len));
    try appendU32(&index, allocator, @intCast(resource_records.items.len));
    try index.appendSlice(allocator, lexical_index.items);
    try index.appendSlice(allocator, identities.items);
    try index.appendSlice(allocator, catalog.items);

    const directory_length = std.math.mul(usize, pages.items.len, directory_record_size) catch return error.ArchiveTooLarge;
    const index_offset = header_size;
    const directory_offset = std.math.add(usize, index_offset, index.items.len) catch return error.ArchiveTooLarge;
    const pages_offset = std.math.add(usize, directory_offset, directory_length) catch return error.ArchiveTooLarge;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendNTimes(allocator, 0, pages_offset);
    @memcpy(out.items[index_offset..directory_offset], index.items);

    for (pages.items, 0..) |page, page_index| {
        var block = try compression.encode(allocator, page.raw, options.compression, options.compression_limits);
        defer block.deinit();
        const page_offset = out.items.len - pages_offset;
        try out.appendSlice(allocator, block.bytes);
        const record_at = directory_offset + page_index * directory_record_size;
        writeU64(out.items, record_at, @intCast(page_offset));
        writeU32(out.items, record_at + 8, @intCast(block.bytes.len));
        writeU32(out.items, record_at + 12, @intCast(page.raw.len));
        writeU32(out.items, record_at + 16, @intCast(page.first_document));
        writeU32(out.items, record_at + 20, @intCast(page.document_count));
        out.items[record_at + 24] = @intFromEnum(block.codec);
        var page_digest: [digest_length]u8 = undefined;
        Sha256.hash(block.bytes, &page_digest, .{});
        @memcpy(out.items[record_at + 32 .. record_at + 64], &page_digest);
    }

    @memcpy(out.items[0..8], magic);
    writeU16(out.items, 8, version);
    writeU16(out.items, 10, header_size);
    writeU32(out.items, 12, @intCast(library.resources.len));
    writeU32(out.items, 16, @intCast(library.entries.len));
    writeU32(out.items, 20, @intCast(pages.items.len));
    writeU64(out.items, 24, @intCast(index_records.items.len));
    writeU64(out.items, 32, index_offset);
    writeU64(out.items, 40, index.items.len);
    writeU64(out.items, 48, directory_offset);
    writeU64(out.items, 56, directory_length);
    writeU64(out.items, 64, pages_offset);
    writeU64(out.items, 72, out.items.len - pages_offset);
    const root_digest = metadataDigest(out.items[0..80], out.items[index_offset..directory_offset], out.items[directory_offset..pages_offset]);
    @memcpy(out.items[80..112], &root_digest);

    return .{ .allocator = allocator, .bytes = try out.toOwnedSlice(allocator) };
}

pub const Archive = struct {
    bytes: []const u8,
    limits: Limits,
    entry_count: usize,
    resource_count: usize,
    page_count: usize,
    hit_count: usize,
    index: []const u8,
    catalog: []const u8,
    /// Null for legacy archives and archives built without the projection.
    identity_index: ?[]const u8,
    identity_order: []const u8,
    directory: []const u8,
    pages: []const u8,

    /// `bytes` is borrowed and must outlive this view and all `Hit` values.
    /// Loaded entries do not borrow it.
    pub fn open(bytes: []const u8, limits: Limits) !Archive {
        if (bytes.len > limits.max_archive_bytes) return error.ArchiveTooLarge;
        if (bytes.len < header_size) return error.Truncated;
        if (!std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidMagic;
        const archive_version = readU16(bytes, 8);
        if (archive_version != 2 and archive_version != version) return error.UnsupportedVersion;
        if (readU16(bytes, 10) != header_size) return error.InvalidHeader;
        const resource_count: usize = readU32(bytes, 12);
        const entry_count: usize = readU32(bytes, 16);
        const page_count: usize = readU32(bytes, 20);
        const hit_count = try u64ToUsize(readU64(bytes, 24));
        if (entry_count > limits.max_entries or resource_count > limits.max_resources or page_count > limits.max_pages or hit_count > limits.max_hits) return error.CountLimit;
        const document_count = std.math.add(usize, entry_count, resource_count) catch return error.CountLimit;
        if (document_count > std.math.maxInt(u32)) return error.CountLimit;
        const index_offset = try u64ToUsize(readU64(bytes, 32));
        const index_length = try u64ToUsize(readU64(bytes, 40));
        const directory_offset = try u64ToUsize(readU64(bytes, 48));
        const directory_length = try u64ToUsize(readU64(bytes, 56));
        const pages_offset = try u64ToUsize(readU64(bytes, 64));
        const pages_length = try u64ToUsize(readU64(bytes, 72));
        if (index_length > limits.max_index_bytes) return error.IndexTooLarge;
        if (index_offset != header_size or
            try checkedEnd(index_offset, index_length, bytes.len) != directory_offset or
            try checkedEnd(directory_offset, directory_length, bytes.len) != pages_offset or
            try checkedEnd(pages_offset, pages_length, bytes.len) != bytes.len)
            return error.InvalidLayout;
        if (directory_length != std.math.mul(usize, page_count, directory_record_size) catch return error.InvalidDirectory) return error.InvalidDirectory;
        const complete_index = bytes[index_offset..directory_offset];
        const directory = bytes[directory_offset..pages_offset];
        const pages = bytes[pages_offset..];
        const expected_root = metadataDigest(bytes[0..80], complete_index, directory);
        if (!std.crypto.timing_safe.eql([digest_length]u8, expected_root, bytes[80..112].*)) return error.MetadataDigestMismatch;
        const index_header: usize = if (archive_version >= 3) 12 else 8;
        if (complete_index.len < index_header) return error.InvalidIndex;
        const lexical_length: usize = readU32(complete_index, 0);
        const identity_length: usize = if (archive_version >= 3) readU32(complete_index, 4) else 0;
        if (readU32(complete_index, index_header - 4) != resource_count or lexical_length > complete_index.len - index_header) return error.InvalidIndex;
        const index = complete_index[index_header..][0..lexical_length];
        const identity_at = index_header + lexical_length;
        if (identity_length > complete_index.len - identity_at) return error.InvalidIndex;
        const identities = complete_index[identity_at..][0..identity_length];
        const identity_order_length = std.math.mul(usize, entry_count, 4) catch return error.InvalidIndex;
        if (identity_length != 0 and identities.len < identity_order_length) return error.InvalidIndex;
        const catalog = complete_index[identity_at + identity_length ..];

        var archive = Archive{
            .bytes = bytes,
            .limits = limits,
            .entry_count = entry_count,
            .resource_count = resource_count,
            .page_count = page_count,
            .hit_count = hit_count,
            .index = index,
            .catalog = catalog,
            .identity_index = if (identity_length != 0) identities[identity_order_length..] else null,
            .identity_order = if (identity_length != 0) identities[0..identity_order_length] else &.{},
            .directory = directory,
            .pages = pages,
        };
        try archive.validateIndex();
        try archive.validateIdentities();
        try archive.validateCatalog();
        try archive.validateDirectory();
        return archive;
    }

    pub fn lookup(self: *const Archive, wanted: []const u8) !Hits {
        if (wanted.len > self.limits.max_key_bytes) return error.KeyTooLong;
        return .{ .archive = self, .cursor = try self.lowerBound(wanted), .wanted = wanted, .prefix_mode = false };
    }

    pub fn prefix(self: *const Archive, wanted: []const u8) !Hits {
        if (wanted.len > self.limits.max_key_bytes) return error.KeyTooLong;
        return .{ .archive = self, .cursor = try self.lowerBound(wanted), .wanted = wanted, .prefix_mode = true };
    }

    /// Logical entry addresses are distinct from spellings and physical ids.
    /// This query touches only digest-checked metadata, never an entry page.
    pub fn entryIdentity(self: *const Archive, wanted: []const u8) !?EntryId {
        if (wanted.len > self.limits.max_key_bytes) return error.KeyTooLong;
        const index = self.identity_index orelse return error.DocumentCatalogRequired;
        var projection = self.*;
        projection.index = index;
        const cursor = (try projection.lowerBound(wanted)) orelse return null;
        if (!cursor.key.spelling.eql(wanted)) return null;
        var at = cursor.key.hits_at;
        return (try parseHit(index, &at, cursor.key.hits_end, self.entry_count, self.limits.max_key_bytes)).entry;
    }

    pub fn resource(self: *const Archive, wanted: []const u8) !?ResourceHit {
        if (wanted.len > self.limits.max_key_bytes) return error.KeyTooLong;
        var low: usize = 0;
        var high = self.resource_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const candidate = try self.resourceRecord(middle);
            switch (std.mem.order(u8, candidate.identity, wanted)) {
                .lt => low = middle + 1,
                .eq => return candidate,
                .gt => high = middle,
            }
        }
        return null;
    }

    /// The same admission and ownership path serves both document kinds.
    /// Its result is statically Entry or Resource, selected by the address.
    pub fn load(self: *const Archive, allocator: std.mem.Allocator, id: anytype) !packet.Decoded(@TypeOf(id).Payload) {
        const Address = @TypeOf(id);
        try self.checkAddress(id);
        const kind = Address.document_kind;
        var document = try self.loadDocument(allocator, id.value);
        errdefer document.deinit();
        var sources = try self.sourceIndex(allocator);
        defer sources.deinit(allocator);
        try self.admitDocument(allocator, &document.value, id.value, &sources);
        return packet.Decoded(Address.Payload){
            .arena = document.arena,
            .value = @field(document.value, @tagName(kind)),
        };
    }

    /// The same semantic admission as load, with byte slices borrowing a
    /// retained decode buffer rather than being separately copied. Raw pages
    /// retain only the requested packet; compressed pages retain their block.
    pub fn inspect(self: *const Archive, allocator: std.mem.Allocator, id: anytype) !Inspected(@TypeOf(id).Payload) {
        const Address = @TypeOf(id);
        try self.checkAddress(id);
        const record = try self.directoryRecord(try self.pageForDocument(id.value));
        var storage: InspectionStorage = undefined;
        const bytes = if (record.codec == .raw) raw: {
            try self.verifyPageDigest(record);
            if (record.raw_length != record.encoded_length) return error.InvalidPage;
            const borrowed = try packetAt(self.pages[record.offset..][0..record.raw_length], record, id.value);
            if (borrowed.len > self.limits.compression_limits.max_memory_bytes) return error.ResourceLimit;
            const owned = try allocator.dupe(u8, borrowed);
            storage = .{ .packet = .{ .allocator = allocator, .bytes = owned } };
            break :raw owned;
        } else compressed: {
            var block = try self.decodePage(allocator, record);
            errdefer block.deinit();
            const selected = try packetAt(block.bytes, record, id.value);
            storage = .{ .page = block };
            break :compressed selected;
        };
        errdefer storage.deinit();
        var document = try packet.decodeBorrowed(model.Document, allocator, bytes, self.limits.packet_limits);
        errdefer document.deinit();
        var sources = try self.sourceIndex(allocator);
        defer sources.deinit(allocator);
        try self.admitDocument(allocator, &document.value, id.value, &sources);
        return .{
            .arena = document.arena,
            .value = @field(document.value, @tagName(Address.document_kind)),
            .packet_bytes = bytes,
            .storage = storage,
        };
    }

    /// Full semantic verification is explicit preparation for direct typed
    /// wire projections. Immutable archive bytes must outlive the proof.
    pub fn verify(self: *const Archive, allocator: std.mem.Allocator) !VerifiedArchive {
        try self.verifyAll(allocator);
        return .{ .archive = self };
    }

    /// Cached reads, uncached reads and full verification admit exactly the
    /// same document. Caching changes storage lifetime, never trust semantics.
    fn admitDocument(self: *const Archive, allocator: std.mem.Allocator, document: *const model.Document, ordinal: u32, sources: *const validate.SourceIndex) !void {
        const expected: std.meta.Tag(model.Document) = if (ordinal < self.entry_count) .entry else .resource;
        if (document.* != expected) return error.InvalidDocumentKind;
        switch (document.*) {
            inline else => |*value| try validate.check(allocator, value, .{
                .sources = sources,
                .limits = self.limits.validation_limits,
                .construction = self.limits.construction_limits,
            }),
        }
        if (document.* == .entry) {
            if (self.identity_index != null) {
                const physical = (try self.entryIdentity(document.entry.id)) orelse return error.CatalogMismatch;
                if (physical.value != ordinal) return error.CatalogMismatch;
            }
            return;
        }
        const actual = &document.resource;
        const catalog = (try self.resource(actual.identity())) orelse return error.CatalogMismatch;
        if (catalog.resource.value != ordinal or catalog.kind != std.meta.activeTag(actual.*)) return error.CatalogMismatch;
        const source_length: ?usize = if (actual.* == .source) actual.source.bytes.len else null;
        if (source_length != catalog.source_length) return error.CatalogMismatch;
    }

    fn checkAddress(self: *const Archive, id: anytype) !void {
        const Address = @TypeOf(id);
        if (Address != EntryId and Address != ResourceId) @compileError("load requires EntryId or ResourceId");
        switch (Address.document_kind) {
            .entry => if (id.value >= self.entry_count) return error.InvalidEntryId,
            .resource => if (id.value < self.entry_count or id.value >= self.entry_count + self.resource_count) return error.InvalidResourceId,
        }
    }

    fn loadDocument(self: *const Archive, allocator: std.mem.Allocator, document_id: u32) !packet.Decoded(model.Document) {
        if (document_id >= self.entry_count + self.resource_count) return error.InvalidDocumentId;
        const page_index = try self.pageForDocument(document_id);
        const directory = try self.directoryRecord(page_index);
        var block = try self.decodePage(allocator, directory);
        defer block.deinit();
        const packet_bytes = try packetAt(block.bytes, directory, document_id);
        return packet.decode(model.Document, allocator, packet_bytes, self.limits.packet_limits);
    }

    pub fn verifyAll(self: *const Archive, allocator: std.mem.Allocator) !void {
        var expected_index: std.ArrayList(IndexRecord) = .empty;
        defer {
            for (expected_index.items) |record| {
                allocator.free(record.spelling);
                if (record.form) |form| allocator.free(form);
            }
            expected_index.deinit(allocator);
        }
        var semantic_ids = std.StringHashMapUnmanaged(void).empty;
        defer semantic_ids.deinit(allocator);
        var owned_ids: std.ArrayList([]u8) = .empty;
        defer {
            for (owned_ids.items) |id| allocator.free(id);
            owned_ids.deinit(allocator);
        }
        var sources = try self.sourceIndex(allocator);
        defer sources.deinit(allocator);

        for (0..self.page_count) |page_index| {
            const directory = try self.directoryRecord(page_index);
            var block = try self.decodePage(allocator, directory);
            defer block.deinit();
            var entry_offset: usize = 0;
            for (0..directory.document_count) |document_in_page| {
                if (entry_offset + 4 > block.bytes.len) return error.InvalidPage;
                const length: usize = readU32(block.bytes, entry_offset);
                entry_offset += 4;
                const end = std.math.add(usize, entry_offset, length) catch return error.InvalidPage;
                if (end > block.bytes.len) return error.InvalidPage;
                var decoded = try packet.decodeBorrowed(model.Document, allocator, block.bytes[entry_offset..end], self.limits.packet_limits);
                defer decoded.deinit();
                const document_id: u32 = @intCast(directory.first_document + document_in_page);
                try self.admitDocument(allocator, &decoded.value, document_id, &sources);
                const identity = switch (decoded.value) {
                    .entry => |*entry_value| identity: {
                        const physical_id = EntryId{ .value = document_id };
                        try appendExpectedRecord(allocator, &expected_index, entry_value.headword, null, physical_id);
                        for (entry_value.keys) |key| try appendExpectedRecord(allocator, &expected_index, key.spelling, key.form, physical_id);
                        break :identity entry_value.id;
                    },
                    .resource => |*resource_value| resource_value.identity(),
                };
                const id_copy = try allocator.dupe(u8, identity);
                owned_ids.append(allocator, id_copy) catch |err| {
                    allocator.free(id_copy);
                    return err;
                };
                const admission = try semantic_ids.getOrPut(allocator, id_copy);
                if (admission.found_existing) return error.DuplicateEntryId;
                entry_offset = end;
            }
            if (entry_offset != block.bytes.len) return error.InvalidPage;
        }

        if (expected_index.items.len != self.hit_count) return error.IndexMismatch;
        std.sort.block(IndexRecord, expected_index.items, {}, indexLessThan);
        var actual_hits = try self.allIndexHits();
        for (expected_index.items) |expected| {
            const actual = (try actual_hits.next()) orelse return error.IndexMismatch;
            if (expected.entry.value != actual.entry.value or
                !actual.spelling.eql(expected.spelling) or
                !optionalStringEqual(expected.form, actual.form)) return error.IndexMismatch;
        }
        if ((try actual_hits.next()) != null) return error.IndexMismatch;
    }

    fn validateIndex(self: *const Archive) !void {
        const block_count = try indexBlockCount(self.index);
        const table_end = std.math.add(usize, 4, std.math.mul(usize, block_count, 4) catch return error.InvalidIndex) catch return error.InvalidIndex;
        if (table_end > self.index.len) return error.InvalidIndex;
        var counted_hits: usize = 0;
        var previous_key: ?KeyView = null;
        for (0..block_count) |block_index| {
            const start: usize = readU32(self.index, 4 + block_index * 4);
            const end: usize = if (block_index + 1 == block_count) self.index.len else readU32(self.index, 4 + (block_index + 1) * 4);
            if ((block_index == 0 and start != table_end) or start < table_end or start >= end or end > self.index.len) return error.InvalidIndex;
            const block = try parseBlock(self.index, start, end, self.limits.max_key_bytes);
            if (block.key_count == 0 or block.key_count > index_restart_keys) return error.InvalidIndex;
            var key_at = block.keys_at;
            for (0..block.key_count) |_| {
                const key = try parseKey(self.index, &key_at, block.end, block.common, self.limits.max_key_bytes, self.entry_count);
                if (previous_key) |previous| if (previous.compareView(key.spelling) != .lt) return error.IndexOutOfOrder;
                previous_key = key.spelling;
                counted_hits = std.math.add(usize, counted_hits, key.hit_count) catch return error.InvalidIndex;
                var posting_at = key.hits_at;
                var previous_hit: ?ParsedHit = null;
                for (0..key.hit_count) |_| {
                    const hit = try parseHit(self.index, &posting_at, key.hits_end, self.entry_count, self.limits.max_key_bytes);
                    if (previous_hit) |prior| {
                        if (hit.entry.value < prior.entry.value or
                            (hit.entry.value == prior.entry.value and optionalStringOrder(prior.form, hit.form) == .gt)) return error.IndexOutOfOrder;
                    }
                    previous_hit = hit;
                }
                if (posting_at != key.hits_end) return error.InvalidIndex;
            }
            if (key_at != block.end) return error.InvalidIndex;
        }
        if (block_count == 0 and self.index.len != 4) return error.InvalidIndex;
        if (counted_hits != self.hit_count) return error.InvalidIndex;
    }

    fn validateIdentities(self: *const Archive) !void {
        const index = self.identity_index orelse return;
        var projection = self.*;
        projection.index = index;
        projection.hit_count = self.entry_count;
        try projection.validateIndex();
        var hits = try projection.allIndexHits();
        var sorted_ordinal: usize = 0;
        while (try hits.next()) |hit| : (sorted_ordinal += 1) {
            if (hits.cursor.?.key.hit_count != 1) return error.InvalidIndex;
            if (hit.form != null or hit.spelling.prefix.len + hit.spelling.suffix.len == 0) return error.InvalidIndex;
            // An inverse ordinal proves one-to-one document membership without
            // allocating a visited bitmap during Archive.open.
            if (readU32(self.identity_order, @as(usize, hit.entry.value) * 4) != sorted_ordinal) return error.InvalidIndex;
        }
        if (sorted_ordinal != self.entry_count) return error.InvalidIndex;
    }

    fn validateCatalog(self: *const Archive) !void {
        const tables_length = std.math.mul(usize, self.resource_count, 8) catch return error.InvalidCatalog;
        if (tables_length > self.catalog.len) return error.InvalidCatalog;
        var previous_identity: ?[]const u8 = null;
        for (0..self.resource_count) |ordinal| {
            const record = try self.resourceRecord(ordinal);
            if (ordinal == 0 and readU32(self.catalog, 0) != tables_length) return error.InvalidCatalog;
            if (record.identity.len > self.limits.max_key_bytes) return error.KeyTooLong;
            if (previous_identity) |previous| if (std.mem.order(u8, previous, record.identity) != .lt) return error.InvalidCatalog;
            previous_identity = record.identity;
            const document_ordinal = @as(usize, record.resource.value) - self.entry_count;
            if (document_ordinal >= self.resource_count) return error.InvalidCatalog;
            if (readU32(self.catalog, self.resource_count * 4 + document_ordinal * 4) != ordinal) return error.InvalidCatalog;
        }
        if (self.resource_count == 0 and self.catalog.len != 0) return error.InvalidCatalog;
    }

    fn resourceRecord(self: *const Archive, ordinal: usize) !ResourceHit {
        if (ordinal >= self.resource_count) return error.InvalidCatalog;
        const tables_length = self.resource_count * 8;
        const start: usize = readU32(self.catalog, ordinal * 4);
        const end: usize = if (ordinal + 1 == self.resource_count) self.catalog.len else readU32(self.catalog, (ordinal + 1) * 4);
        if (start < tables_length or start >= end or end > self.catalog.len) return error.InvalidCatalog;
        var at = start;
        const kind = std.enums.fromInt(ResourceKind, self.catalog[at]) orelse return error.InvalidCatalog;
        at += 1;
        const document_id = try readVarintUsize(self.catalog, &at, end);
        if (document_id < self.entry_count or document_id >= self.entry_count + self.resource_count) return error.InvalidCatalog;
        const identity_length = try readVarintUsize(self.catalog, &at, end);
        if (identity_length > self.limits.max_key_bytes or identity_length > end - at) return error.InvalidCatalog;
        const identity = self.catalog[at..][0..identity_length];
        at += identity_length;
        const length_plus_one = try readVarintUsize(self.catalog, &at, end);
        if (at != end) return error.InvalidCatalog;
        const source_length = if (kind == .source) blk: {
            if (length_plus_one == 0) return error.InvalidCatalog;
            break :blk length_plus_one - 1;
        } else blk: {
            if (length_plus_one != 0) return error.InvalidCatalog;
            break :blk null;
        };
        return .{ .resource = .{ .value = @intCast(document_id) }, .identity = identity, .kind = kind, .source_length = source_length };
    }

    fn sourceIndex(self: *const Archive, allocator: std.mem.Allocator) !validate.SourceIndex {
        var result = validate.SourceIndex{};
        errdefer result.deinit(allocator);
        for (0..self.resource_count) |ordinal| {
            const record = try self.resourceRecord(ordinal);
            if (record.kind == .source) {
                if (result.count() >= self.limits.validation_limits.max_values) return error.ResourceLimit;
                try result.add(allocator, record.identity, record.source_length.?);
            }
        }
        return result;
    }

    fn validateDirectory(self: *const Archive) !void {
        var expected_offset: usize = 0;
        var expected_entry: usize = 0;
        for (0..self.page_count) |page_index| {
            const record = try self.directoryRecord(page_index);
            if (record.offset != expected_offset or record.first_document != expected_entry or record.document_count == 0) return error.InvalidDirectory;
            for (self.directory[page_index * directory_record_size + 25 ..][0..7]) |reserved| if (reserved != 0) return error.InvalidDirectory;
            if (record.raw_length > self.limits.max_page_bytes or record.raw_length > self.limits.compression_limits.max_block_bytes) return error.PageTooLarge;
            switch (record.codec) {
                .raw => if (record.encoded_length != record.raw_length) return error.InvalidDirectory,
                .bzip3 => {
                    if (record.encoded_length < 8 or record.encoded_length > try compression.bound(record.raw_length)) return error.InvalidDirectory;
                },
            }
            expected_offset = try checkedEnd(record.offset, record.encoded_length, self.pages.len);
            expected_entry = std.math.add(usize, expected_entry, record.document_count) catch return error.InvalidDirectory;
        }
        const document_count = self.entry_count + self.resource_count;
        if (expected_offset != self.pages.len or expected_entry != document_count) return error.InvalidDirectory;
        if ((document_count == 0) != (self.page_count == 0)) return error.InvalidDirectory;
    }

    fn lowerBound(self: *const Archive, wanted: []const u8) !?KeyCursor {
        const block_count = try indexBlockCount(self.index);
        if (block_count == 0) return null;
        var low: usize = 0;
        var high = block_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const first = try self.firstKeyInBlock(middle);
            if (first.spelling.compare(wanted) != .gt) low = middle + 1 else high = middle;
        }
        const block_index = if (low == 0) @as(usize, 0) else low - 1;
        var cursor = try self.firstCursorInBlock(block_index);
        while (true) {
            if (cursor.key.spelling.compare(wanted) != .lt) return cursor;
            if (!try self.advanceCursor(&cursor)) return null;
        }
    }

    fn allIndexHits(self: *const Archive) !Hits {
        const cursor = if (try indexBlockCount(self.index) == 0) null else try self.firstCursorInBlock(0);
        return .{ .archive = self, .cursor = cursor, .wanted = "", .prefix_mode = true };
    }

    fn firstKeyInBlock(self: *const Archive, block_index: usize) !ParsedKey {
        const cursor = try self.firstCursorInBlock(block_index);
        return cursor.key;
    }

    fn firstCursorInBlock(self: *const Archive, block_index: usize) !KeyCursor {
        const block_count = try indexBlockCount(self.index);
        if (block_index >= block_count) return error.InvalidIndex;
        const start: usize = readU32(self.index, 4 + block_index * 4);
        const end: usize = if (block_index + 1 == block_count) self.index.len else readU32(self.index, 4 + (block_index + 1) * 4);
        const block = try parseBlock(self.index, start, end, self.limits.max_key_bytes);
        var at = block.keys_at;
        const key = try parseKey(self.index, &at, block.end, block.common, self.limits.max_key_bytes, self.entry_count);
        return .{ .block_index = block_index, .key_index = 0, .block = block, .next_key_at = at, .key = key, .next_hit_at = key.hits_at, .hits_remaining = key.hit_count };
    }

    fn advanceCursor(self: *const Archive, cursor: *KeyCursor) !bool {
        if (cursor.key_index + 1 < cursor.block.key_count) {
            cursor.key_index += 1;
            var at = cursor.next_key_at;
            cursor.key = try parseKey(self.index, &at, cursor.block.end, cursor.block.common, self.limits.max_key_bytes, self.entry_count);
            cursor.next_key_at = at;
            cursor.next_hit_at = cursor.key.hits_at;
            cursor.hits_remaining = cursor.key.hit_count;
            return true;
        }
        const block_count = try indexBlockCount(self.index);
        if (cursor.block_index + 1 >= block_count) return false;
        cursor.* = try self.firstCursorInBlock(cursor.block_index + 1);
        return true;
    }

    fn directoryRecord(self: *const Archive, page_index: usize) !DirectoryRecord {
        if (page_index >= self.page_count) return error.InvalidDirectory;
        const at = page_index * directory_record_size;
        const codec = std.enums.fromInt(compression.Codec, self.directory[at + 24]) orelse return error.InvalidCodec;
        var digest: [digest_length]u8 = undefined;
        @memcpy(&digest, self.directory[at + 32 .. at + 64]);
        return .{
            .offset = try u64ToUsize(readU64(self.directory, at)),
            .encoded_length = readU32(self.directory, at + 8),
            .raw_length = readU32(self.directory, at + 12),
            .first_document = readU32(self.directory, at + 16),
            .document_count = readU32(self.directory, at + 20),
            .codec = codec,
            .digest = digest,
        };
    }

    fn pageForDocument(self: *const Archive, document: usize) !usize {
        var low: usize = 0;
        var high = self.page_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const record = try self.directoryRecord(middle);
            if (document < record.first_document) {
                high = middle;
            } else if (document >= record.first_document + record.document_count) {
                low = middle + 1;
            } else return middle;
        }
        return error.InvalidEntryId;
    }

    fn verifyPageDigest(self: *const Archive, record: DirectoryRecord) !void {
        const end = try checkedEnd(record.offset, record.encoded_length, self.pages.len);
        var actual: [digest_length]u8 = undefined;
        Sha256.hash(self.pages[record.offset..end], &actual, .{});
        if (!std.crypto.timing_safe.eql([digest_length]u8, actual, record.digest)) return error.PageDigestMismatch;
    }

    fn decodePage(self: *const Archive, allocator: std.mem.Allocator, record: DirectoryRecord) !compression.Block {
        try self.verifyPageDigest(record);
        return compression.decode(allocator, record.codec, self.pages[record.offset..][0..record.encoded_length], record.raw_length, self.limits.compression_limits);
    }
};

/// Direct typed projections require complete prior semantic verification via
/// Archive.verify. This is a documented immutable-byte precondition, not an
/// unforgeable token or proof of publisher identity. Verification includes all
/// packet canonical checks and page digests. Reusing that result assumes the
/// exact archive mapping and configured limits remain immutable.
pub const VerifiedArchive = struct {
    archive: *const Archive,

    /// Raw projections borrow the archive mapping and allocate nothing.
    /// Compressed projections own one decoded page, without native document
    /// reconstruction or an arena. All child Views share this result's lifetime.
    pub fn view(self: VerifiedArchive, allocator: std.mem.Allocator, id: anytype) !Projected(@TypeOf(id).Payload) {
        try self.archive.checkAddress(id);
        const record = try self.archive.directoryRecord(try self.archive.pageForDocument(id.value));
        if (record.codec == .raw) {
            // Full verification already checked this mapped page. The exact
            // mapping and limits are immutable for the proof's lifetime.
            const bytes = try packetAt(self.archive.pages[record.offset..][0..record.raw_length], record, id.value);
            const document = try packet_view.fromVerifiedDocument(model.Document, bytes, self.archive.limits.packet_limits);
            return .{ .value = try document.payload(@TypeOf(id).document_kind), .page = null };
        }
        var block = try self.archive.decodePage(allocator, record);
        errdefer block.deinit();
        const bytes = try packetAt(block.bytes, record, id.value);
        const document = try packet_view.fromVerifiedDocument(model.Document, bytes, self.archive.limits.packet_limits);
        return .{ .value = try document.payload(@TypeOf(id).document_kind), .page = block };
    }
};

pub fn Projected(comptime T: type) type {
    return struct {
        value: packet_view.View(T),
        page: ?compression.Block,

        pub fn deinit(self: *@This()) void {
            if (self.page) |*page| page.deinit();
            self.* = undefined;
        }
    };
}

/// A direct-projection session over an explicitly verified immutable archive.
/// Raw values borrow mapped bytes; compressed values borrow one retained page.
/// Consume projections before requesting a different compressed page or closing
/// this session. Use VerifiedArchive.view to own a separate compressed page.
pub const VerifiedReader = struct {
    allocator: std.mem.Allocator,
    verified: VerifiedArchive,
    page: ?CachedPage = null,
    raw_number: ?usize = null,
    raw_next_document: usize = 0,
    raw_next_at: usize = 0,
    stats: Reader.Stats = .{},

    pub fn init(allocator: std.mem.Allocator, verified: VerifiedArchive) !VerifiedReader {
        return .{ .allocator = allocator, .verified = verified };
    }

    pub fn deinit(self: *VerifiedReader) void {
        self.evict();
        self.* = undefined;
    }

    pub fn view(self: *VerifiedReader, id: anytype) !packet_view.View(@TypeOf(id).Payload) {
        const archive = self.verified.archive;
        try archive.checkAddress(id);
        const number = try archive.pageForDocument(id.value);
        const record = try archive.directoryRecord(number);
        const bytes = if (record.codec == .raw) raw: {
            if (self.raw_number == null or self.raw_number.? != number) {
                self.evict();
                self.raw_number = number;
                self.raw_next_document = record.first_document;
            } else self.stats.cache_hits +|= 1;
            break :raw try self.rawPacketAt(record, id.value);
        } else compressed: {
            if (self.page == null or self.page.?.number != number) {
                self.evict();
                self.page = try CachedPage.open(self.allocator, archive, number);
                self.stats.page_loads +|= 1;
                self.stats.bzip3_decodes +|= @intFromBool(self.page.?.block.codec == .bzip3);
                self.stats.decoded_bytes +|= self.page.?.block.raw_len;
            } else self.stats.cache_hits +|= 1;
            break :compressed self.page.?.packetAt(id.value);
        };
        const document = try packet_view.fromVerifiedDocument(model.Document, bytes, archive.limits.packet_limits);
        return document.payload(@TypeOf(id).document_kind);
    }

    fn evict(self: *VerifiedReader) void {
        if (self.page) |*page| page.deinit(self.allocator);
        self.page = null;
        self.raw_number = null;
        self.raw_next_at = 0;
    }

    fn rawPacketAt(self: *VerifiedReader, record: DirectoryRecord, ordinal: usize) ![]const u8 {
        const bytes = self.verified.archive.pages[record.offset..][0..record.raw_length];
        var document = if (self.raw_next_document <= ordinal) self.raw_next_document else record.first_document;
        var at = if (self.raw_next_document <= ordinal) self.raw_next_at else 0;
        while (document <= ordinal) : (document += 1) {
            if (at > bytes.len or bytes.len - at < 4) return error.InvalidPage;
            const length: usize = readU32(bytes, at);
            const first = at + 4;
            const end = std.math.add(usize, first, length) catch return error.InvalidPage;
            if (end > bytes.len) return error.InvalidPage;
            if (document == ordinal) {
                self.raw_next_document = ordinal + 1;
                self.raw_next_at = end;
                return bytes[first..end];
            }
            at = end;
        }
        return error.InvalidDocumentId;
    }
};

/// A query session owns one decoded page and its packet boundaries. The archive
/// remains immutable and borrowed; returned documents own their own arenas and
/// survive eviction, reader destruction, and archive destruction.
///
/// Logical links need explicit prepareLinks. With the optional identity index
/// preparation allocates and decodes nothing; legacy/unindexed archives retain
/// the transactional document scan and derived in-memory catalog.
pub const Reader = struct {
    allocator: std.mem.Allocator,
    archive: *const Archive,
    sources: validate.SourceIndex,
    page: ?CachedPage = null,
    links: ?std.StringHashMapUnmanaged(EntryId) = null,
    links_ready: bool = false,
    remaining_hops: usize,
    stats: Stats = .{},

    pub const Options = struct { max_link_hops: usize = 64 };
    pub const Stats = struct {
        page_loads: usize = 0,
        bzip3_decodes: usize = 0,
        decoded_bytes: usize = 0,
        cache_hits: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator, archive: *const Archive, options: Reader.Options) !Reader {
        return .{
            .allocator = allocator,
            .archive = archive,
            .sources = try archive.sourceIndex(allocator),
            .remaining_hops = options.max_link_hops,
        };
    }

    pub fn deinit(self: *Reader) void {
        self.evict();
        if (self.links) |*links| deinitLinks(self.allocator, links);
        self.sources.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn load(self: *Reader, id: anytype) !packet.Decoded(@TypeOf(id).Payload) {
        try self.archive.checkAddress(id);
        var document = try self.loadDocument(id.value);
        errdefer document.deinit();
        return .{ .arena = document.arena, .value = @field(document.value, @tagName(@TypeOf(id).document_kind)) };
    }

    /// Retain one contiguous packet rather than separately copying every
    /// string. Results remain independent of the Reader's one-page cache.
    pub fn inspect(self: *Reader, id: anytype) !Inspected(@TypeOf(id).Payload) {
        const Address = @TypeOf(id);
        try self.archive.checkAddress(id);
        const bytes = try self.allocator.dupe(u8, try self.documentBytes(id.value));
        errdefer self.allocator.free(bytes);
        var document = try packet.decodeBorrowed(model.Document, self.allocator, bytes, self.archive.limits.packet_limits);
        errdefer document.deinit();
        try self.archive.admitDocument(self.allocator, &document.value, id.value, &self.sources);
        return .{
            .arena = document.arena,
            .value = @field(document.value, @tagName(Address.document_kind)),
            .packet_bytes = bytes,
            .storage = .{ .packet = .{ .allocator = self.allocator, .bytes = bytes } },
        };
    }

    /// Build once, transactionally. Failure leaves no partially usable index;
    /// success is idempotent. No packet/node pointer is retained in the catalog.
    pub fn prepareLinks(self: *Reader) !void {
        if (self.links_ready) return;
        if (self.archive.identity_index != null) {
            self.links_ready = true;
            return;
        }
        var links: std.StringHashMapUnmanaged(EntryId) = .empty;
        errdefer deinitLinks(self.allocator, &links);
        try links.ensureTotalCapacity(self.allocator, @intCast(self.archive.entry_count));
        for (0..self.archive.entry_count) |ordinal| {
            var document = try self.loadDocument(@intCast(ordinal));
            defer document.deinit();
            const identity = document.value.entry.id;
            if ((try self.archive.resource(identity)) != null) return error.DuplicateEntryId;
            const owned = try self.allocator.dupe(u8, identity);
            const slot = links.getOrPut(self.allocator, owned) catch |err| {
                self.allocator.free(owned);
                return err;
            };
            if (slot.found_existing) {
                self.allocator.free(owned);
                return error.DuplicateEntryId;
            }
            slot.value_ptr.* = .{ .value = @intCast(ordinal) };
        }
        self.links = links;
        self.links_ready = true;
    }

    /// External logical addresses are looked up locally, not declared invalid
    /// merely because their targets are absent. Following never recurses. A hop
    /// budget bounds even caller-driven cycles; local nodes use query.resolve.
    pub fn follow(self: *Reader, reference: model.Reference) !Follow {
        if (self.remaining_hops == 0) return error.HopLimit;
        self.remaining_hops -= 1;
        const ordinal: u32, const fragment: ?[]const u8 = switch (reference) {
            .entry => |address| found: {
                if (!self.links_ready) return error.DocumentCatalogRequired;
                const target = (if (self.archive.identity_index != null)
                    try self.archive.entryIdentity(address.id)
                else
                    self.links.?.get(address.id)) orelse return .{ .unavailable = reference };
                break :found .{ target.value, address.fragment };
            },
            .resource => |address| found: {
                const target = (try self.archive.resource(address.id)) orelse return .{ .unavailable = reference };
                break :found .{ target.resource.value, address.fragment };
            },
            .iri => return .{ .unavailable = reference },
            .unresolved => |value| return .{ .unresolved = value },
            .local => return error.LocalReferenceRequiresDocument,
        };
        var document = try self.loadDocument(ordinal);
        errdefer document.deinit();
        if (fragment) |id| {
            const located = switch (document.value) {
                inline else => |*value| try query.resolve(value, id),
            };
            if (located == null) {
                document.deinit();
                return .{ .unavailable = reference };
            }
        }
        const owned_fragment = if (fragment) |id| try document.arena.allocator().dupe(u8, id) else null;
        return .{ .found = .{ .document = document, .fragment = owned_fragment } };
    }

    fn loadDocument(self: *Reader, ordinal: u32) !packet.Decoded(model.Document) {
        const bytes = try self.documentBytes(ordinal);
        var document = try packet.decode(model.Document, self.allocator, bytes, self.archive.limits.packet_limits);
        errdefer document.deinit();
        try self.archive.admitDocument(self.allocator, &document.value, ordinal, &self.sources);
        return document;
    }

    fn documentBytes(self: *Reader, ordinal: u32) ![]const u8 {
        if (ordinal >= self.archive.entry_count + self.archive.resource_count) return error.InvalidDocumentId;
        const number = try self.archive.pageForDocument(ordinal);
        if (self.page == null or self.page.?.number != number) {
            // Evict first, keeping peak cache occupancy to one page even when
            // decoding or allocating the replacement fails.
            self.evict();
            self.page = try CachedPage.open(self.allocator, self.archive, number);
            const page = &self.page.?;
            self.stats.page_loads +|= 1;
            self.stats.bzip3_decodes +|= @intFromBool(page.block.codec == .bzip3);
            self.stats.decoded_bytes +|= page.block.raw_len;
        } else self.stats.cache_hits +|= 1;
        return self.page.?.packetAt(ordinal);
    }

    fn evict(self: *Reader) void {
        if (self.page) |*page| page.deinit(self.allocator);
        self.page = null;
    }
};

/// Unavailable/unresolved results borrow the input Reference; a found result
/// owns everything, including its requested fragment. Only found needs deinit.
pub const Follow = union(enum) {
    found: Followed,
    unavailable: model.Reference,
    unresolved: @FieldType(model.Reference, "unresolved"),
};

pub const Followed = struct {
    document: packet.Decoded(model.Document),
    fragment: ?[]const u8,

    pub fn deinit(self: *Followed) void {
        self.document.deinit();
        self.* = undefined;
    }

    /// Call only after placing the owned result at its final address. Never
    /// retain a pointer to a local return-value temporary inside an owned value.
    pub fn locate(self: *const Followed) !?query.Located {
        return switch (self.document.value) {
            inline else => |*value| if (self.fragment) |id| try query.resolve(value, id) else query.located(value),
        };
    }
};

const CachedPage = struct {
    number: usize,
    first_document: usize,
    block: compression.Block,
    starts: []u32,

    fn open(allocator: std.mem.Allocator, archive: *const Archive, number: usize) !CachedPage {
        const record = try archive.directoryRecord(number);
        var block = try archive.decodePage(allocator, record);
        errdefer block.deinit();
        // At least a four-byte length belongs to every document. Validate the
        // count before allocating the directory derived from hostile bytes.
        if (record.document_count > block.bytes.len / 4) return error.InvalidPage;
        const starts = try allocator.alloc(u32, record.document_count + 1);
        errdefer allocator.free(starts);
        var at: usize = 0;
        for (starts[0..record.document_count]) |*start| {
            if (block.bytes.len - at < 4) return error.InvalidPage;
            start.* = std.math.cast(u32, at) orelse return error.InvalidPage;
            const length: usize = readU32(block.bytes, at);
            at += 4;
            if (length > block.bytes.len - at) return error.InvalidPage;
            at += length;
        }
        if (at != block.bytes.len) return error.InvalidPage;
        starts[record.document_count] = std.math.cast(u32, at) orelse return error.InvalidPage;
        return .{ .number = number, .first_document = record.first_document, .block = block, .starts = starts };
    }

    fn packetAt(self: CachedPage, ordinal: u32) []const u8 {
        const relative = ordinal - self.first_document;
        return self.block.bytes[self.starts[relative] + 4 .. self.starts[relative + 1]];
    }

    fn deinit(self: *CachedPage, allocator: std.mem.Allocator) void {
        self.block.deinit();
        allocator.free(self.starts);
        self.* = undefined;
    }
};

fn deinitLinks(allocator: std.mem.Allocator, links: *std.StringHashMapUnmanaged(EntryId)) void {
    var keys = links.keyIterator();
    while (keys.next()) |key| allocator.free(key.*);
    links.deinit(allocator);
}

pub const Hits = struct {
    archive: *const Archive,
    cursor: ?KeyCursor,
    wanted: []const u8,
    prefix_mode: bool,

    pub fn next(self: *Hits) !?Hit {
        while (self.cursor) |*cursor| {
            const matches = if (self.prefix_mode) cursor.key.spelling.startsWith(self.wanted) else cursor.key.spelling.eql(self.wanted);
            if (!matches) return null;
            if (cursor.hits_remaining != 0) {
                const decoded = try parseHit(self.archive.index, &cursor.next_hit_at, cursor.key.hits_end, self.archive.entry_count, self.archive.limits.max_key_bytes);
                cursor.hits_remaining -= 1;
                return .{ .entry = decoded.entry, .spelling = cursor.key.spelling, .form = decoded.form };
            }
            if (!try self.archive.advanceCursor(cursor)) self.cursor = null;
        }
        return null;
    }
};

const ParsedBlock = struct {
    common: []const u8,
    key_count: usize,
    keys_at: usize,
    end: usize,
};

const ParsedKey = struct {
    spelling: KeyView,
    hit_count: usize,
    hits_at: usize,
    hits_end: usize,
};

const ParsedHit = struct { entry: EntryId, form: ?[]const u8 };

const KeyCursor = struct {
    block_index: usize,
    key_index: usize,
    block: ParsedBlock,
    next_key_at: usize,
    key: ParsedKey,
    next_hit_at: usize,
    hits_remaining: usize,
};

fn finishPage(allocator: std.mem.Allocator, pages: *std.ArrayList(PageBuild), raw: *std.ArrayList(u8), first_document: usize, document_count: usize) !void {
    const owned = try raw.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    try pages.append(allocator, .{ .first_document = first_document, .document_count = document_count, .raw = owned });
}

fn appendDocument(
    allocator: std.mem.Allocator,
    pages: *std.ArrayList(PageBuild),
    raw: *std.ArrayList(u8),
    first_document: *usize,
    documents_in_page: *usize,
    document_index: usize,
    document: model.Document,
    options: Options,
) !void {
    const encoded = try packet.encode(allocator, document, options.packet_limits);
    defer allocator.free(encoded);
    if (encoded.len > options.max_document_bytes or encoded.len > std.math.maxInt(u32)) return error.DocumentTooLarge;
    const framed_length = std.math.add(usize, 4, encoded.len) catch return error.DocumentTooLarge;
    if (framed_length > options.max_page_bytes) return error.DocumentTooLarge;
    const prospective_page_length = std.math.add(usize, raw.items.len, framed_length) catch return error.DocumentTooLarge;
    if (documents_in_page.* != 0 and prospective_page_length > options.target_page_bytes) {
        try finishPage(allocator, pages, raw, first_document.*, documents_in_page.*);
        first_document.* = document_index;
        documents_in_page.* = 0;
    }
    try appendU32(raw, allocator, @intCast(encoded.len));
    try raw.appendSlice(allocator, encoded);
    documents_in_page.* += 1;
}

fn indexLessThan(_: void, left: IndexRecord, right: IndexRecord) bool {
    switch (std.mem.order(u8, left.spelling, right.spelling)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (left.entry.value != right.entry.value) return left.entry.value < right.entry.value;
    if (left.form == null and right.form != null) return true;
    if (left.form != null and right.form == null) return false;
    if (left.form) |left_form| return std.mem.lessThan(u8, left_form, right.form.?);
    return false;
}

fn resourceLessThan(_: void, left: ResourceRecord, right: ResourceRecord) bool {
    return std.mem.lessThan(u8, left.identity, right.identity);
}

fn buildIdentityIndex(allocator: std.mem.Allocator, entries: []const model.Entry, out: *std.ArrayList(u8)) !void {
    const records = try allocator.alloc(IndexRecord, entries.len);
    defer allocator.free(records);
    for (entries, records, 0..) |entry, *record, ordinal| record.* = .{
        .spelling = entry.id,
        .form = null,
        .entry = .{ .value = @intCast(ordinal) },
    };
    std.sort.block(IndexRecord, records, {}, indexLessThan);
    const table_length = std.math.mul(usize, entries.len, 4) catch return error.ArchiveTooLarge;
    try out.appendNTimes(allocator, 0, table_length);
    for (records, 0..) |record, sorted_ordinal|
        writeU32(out.items, @as(usize, record.entry.value) * 4, @intCast(sorted_ordinal));
    var index: std.ArrayList(u8) = .empty;
    defer index.deinit(allocator);
    try buildIndex(allocator, records, &index);
    try out.appendSlice(allocator, index.items);
}

fn buildResourceCatalog(allocator: std.mem.Allocator, records: []const ResourceRecord, out: *std.ArrayList(u8)) !void {
    const tables_length = std.math.mul(usize, records.len, 8) catch return error.ArchiveTooLarge;
    try out.appendNTimes(allocator, 0, tables_length);
    var minimum_document: usize = std.math.maxInt(usize);
    for (records) |record| minimum_document = @min(minimum_document, record.document.value);
    for (records, 0..) |record, ordinal| {
        if (out.items.len > std.math.maxInt(u32)) return error.ArchiveTooLarge;
        writeU32(out.items, ordinal * 4, @intCast(out.items.len));
        const document_ordinal = @as(usize, record.document.value);
        try out.append(allocator, @intCast(@intFromEnum(record.kind)));
        try appendVarint(out, allocator, document_ordinal);
        try appendVarint(out, allocator, record.identity.len);
        try out.appendSlice(allocator, record.identity);
        if (record.source_length) |length| {
            if (length == std.math.maxInt(usize)) return error.ArchiveTooLarge;
            try appendVarint(out, allocator, length + 1);
        } else try appendVarint(out, allocator, 0);
    }
    for (records, 0..) |record, ordinal| {
        writeU32(out.items, records.len * 4 + (@as(usize, record.document.value) - minimum_document) * 4, @intCast(ordinal));
    }
}

fn buildIndex(allocator: std.mem.Allocator, records: []const IndexRecord, out: *std.ArrayList(u8)) !void {
    var block_starts: std.ArrayList(usize) = .empty;
    defer block_starts.deinit(allocator);
    var record_at: usize = 0;
    while (record_at < records.len) {
        try block_starts.append(allocator, record_at);
        var distinct: usize = 0;
        var prior: ?[]const u8 = null;
        while (record_at < records.len and distinct < index_restart_keys) : (record_at += 1) {
            if (prior == null or !std.mem.eql(u8, prior.?, records[record_at].spelling)) {
                distinct += 1;
                prior = records[record_at].spelling;
            }
        }
        while (record_at < records.len and std.mem.eql(u8, records[record_at - 1].spelling, records[record_at].spelling)) record_at += 1;
    }
    if (block_starts.items.len > std.math.maxInt(u32)) return error.ArchiveTooLarge;
    try appendU32(out, allocator, @intCast(block_starts.items.len));
    const offsets_length = std.math.mul(usize, block_starts.items.len, 4) catch return error.ArchiveTooLarge;
    try out.appendNTimes(allocator, 0, offsets_length);
    for (block_starts.items, 0..) |start, block_index| {
        if (out.items.len > std.math.maxInt(u32)) return error.ArchiveTooLarge;
        writeU32(out.items, 4 + block_index * 4, @intCast(out.items.len));
        const end = if (block_index + 1 == block_starts.items.len) records.len else block_starts.items[block_index + 1];
        const common_length = commonPrefixLength(records[start].spelling, records[end - 1].spelling);
        try appendVarint(out, allocator, common_length);
        try out.appendSlice(allocator, records[start].spelling[0..common_length]);
        var key_count: usize = 0;
        for (records[start..end], 0..) |record, index| {
            if (index == 0 or !std.mem.eql(u8, records[start + index - 1].spelling, record.spelling)) key_count += 1;
        }
        try appendVarint(out, allocator, key_count);
        var key_start = start;
        while (key_start < end) {
            var key_end = key_start + 1;
            while (key_end < end and std.mem.eql(u8, records[key_start].spelling, records[key_end].spelling)) key_end += 1;
            const suffix = records[key_start].spelling[common_length..];
            try appendVarint(out, allocator, suffix.len);
            try out.appendSlice(allocator, suffix);
            try appendVarint(out, allocator, key_end - key_start);
            var postings_length: usize = 0;
            for (records[key_start..key_end]) |record| {
                postings_length = std.math.add(usize, postings_length, varintLength(record.entry.value)) catch return error.ArchiveTooLarge;
                const form_length_plus_one = if (record.form) |form| std.math.add(usize, form.len, 1) catch return error.ArchiveTooLarge else 0;
                postings_length = std.math.add(usize, postings_length, varintLength(form_length_plus_one)) catch return error.ArchiveTooLarge;
                if (record.form) |form| postings_length = std.math.add(usize, postings_length, form.len) catch return error.ArchiveTooLarge;
            }
            try appendVarint(out, allocator, postings_length);
            for (records[key_start..key_end]) |record| {
                try appendVarint(out, allocator, record.entry.value);
                if (record.form) |form| {
                    try appendVarint(out, allocator, form.len + 1);
                    try out.appendSlice(allocator, form);
                } else try appendVarint(out, allocator, 0);
            }
            key_start = key_end;
        }
    }
}

fn indexBlockCount(bytes: []const u8) !usize {
    if (bytes.len < 4) return error.InvalidIndex;
    return readU32(bytes, 0);
}

fn parseBlock(bytes: []const u8, start: usize, end: usize, max_key_bytes: usize) !ParsedBlock {
    if (start >= end or end > bytes.len) return error.InvalidIndex;
    var at = start;
    const common_length = try readVarintUsize(bytes, &at, end);
    if (common_length > max_key_bytes or common_length > end - at) return error.InvalidIndex;
    const common = bytes[at..][0..common_length];
    at += common_length;
    const key_count = try readVarintUsize(bytes, &at, end);
    return .{ .common = common, .key_count = key_count, .keys_at = at, .end = end };
}

fn parseKey(bytes: []const u8, at: *usize, end: usize, common: []const u8, max_key_bytes: usize, entry_count: usize) !ParsedKey {
    const suffix_length = try readVarintUsize(bytes, at, end);
    if (suffix_length > max_key_bytes - common.len or suffix_length > end - at.*) return error.InvalidIndex;
    const suffix = bytes[at.*..][0..suffix_length];
    at.* += suffix_length;
    const hit_count = try readVarintUsize(bytes, at, end);
    if (hit_count == 0) return error.InvalidIndex;
    const postings_length = try readVarintUsize(bytes, at, end);
    if (postings_length > end - at.*) return error.InvalidIndex;
    const hits_at = at.*;
    at.* += postings_length;
    _ = entry_count;
    return .{ .spelling = .{ .prefix = common, .suffix = suffix }, .hit_count = hit_count, .hits_at = hits_at, .hits_end = at.* };
}

fn parseHit(bytes: []const u8, at: *usize, end: usize, entry_count: usize, max_key_bytes: usize) !ParsedHit {
    const entry_id = try readVarintUsize(bytes, at, end);
    if (entry_id >= entry_count or entry_id > std.math.maxInt(u32)) return error.InvalidIndex;
    const form_length_plus_one = try readVarintUsize(bytes, at, end);
    const form_length = if (form_length_plus_one == 0) 0 else form_length_plus_one - 1;
    if (form_length > max_key_bytes or form_length > end - at.*) return error.InvalidIndex;
    const form = if (form_length_plus_one == 0) null else bytes[at.*..][0..form_length];
    at.* += form_length;
    return .{ .entry = .{ .value = @intCast(entry_id) }, .form = form };
}

fn appendVarint(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: usize) !void {
    var remaining = value;
    while (remaining >= 0x80) {
        try out.append(allocator, @as(u8, @truncate(remaining)) | 0x80);
        remaining >>= 7;
    }
    try out.append(allocator, @intCast(remaining));
}

fn varintLength(value: usize) usize {
    var remaining = value;
    var length: usize = 1;
    while (remaining >= 0x80) : (length += 1) remaining >>= 7;
    return length;
}

fn readVarintUsize(bytes: []const u8, at: *usize, end: usize) !usize {
    var value: u64 = 0;
    var shift: u6 = 0;
    var count: usize = 0;
    while (count < 10) : (count += 1) {
        if (at.* >= end) return error.InvalidIndex;
        const part = bytes[at.*];
        at.* += 1;
        if (count == 9 and part > 1) return error.InvalidIndex;
        value |= @as(u64, part & 0x7f) << shift;
        if ((part & 0x80) == 0) {
            if (count > 0 and part == 0) return error.InvalidIndex;
            if (value > std.math.maxInt(usize)) return error.InvalidIndex;
            return @intCast(value);
        }
        if (count != 9) shift += 7;
    }
    return error.InvalidIndex;
}

fn commonPrefixLength(left: []const u8, right: []const u8) usize {
    const limit = @min(left.len, right.len);
    var result: usize = 0;
    while (result < limit and left[result] == right[result]) result += 1;
    return result;
}

fn optionalStringOrder(left: ?[]const u8, right: ?[]const u8) std.math.Order {
    if (left == null) return if (right == null) .eq else .lt;
    if (right == null) return .gt;
    return std.mem.order(u8, left.?, right.?);
}

fn packetAt(raw: []const u8, directory: DirectoryRecord, entry: u32) ![]const u8 {
    if (raw.len != directory.raw_length) return error.InvalidPage;
    const ordinal = @as(usize, entry) - directory.first_document;
    var at: usize = 0;
    var result: ?[]const u8 = null;
    for (0..directory.document_count) |index| {
        if (at + 4 > raw.len) return error.InvalidPage;
        const length: usize = readU32(raw, at);
        at += 4;
        const end = std.math.add(usize, at, length) catch return error.InvalidPage;
        if (end > raw.len) return error.InvalidPage;
        if (index == ordinal) result = raw[at..end];
        at = end;
    }
    if (at != raw.len) return error.InvalidPage;
    return result orelse error.InvalidPage;
}

fn appendExpectedRecord(
    allocator: std.mem.Allocator,
    records: *std.ArrayList(IndexRecord),
    spelling: []const u8,
    form: ?[]const u8,
    entry_id: EntryId,
) !void {
    const owned_spelling = try allocator.dupe(u8, spelling);
    errdefer allocator.free(owned_spelling);
    const owned_form = if (form) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_form) |value| allocator.free(value);
    try records.append(allocator, .{ .spelling = owned_spelling, .form = owned_form, .entry = entry_id });
}

fn optionalStringEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn metadataDigest(header: []const u8, index: []const u8, directory: []const u8) [digest_length]u8 {
    var state = Sha256.init(.{});
    state.update(header);
    state.update(index);
    state.update(directory);
    var result: [digest_length]u8 = undefined;
    state.final(&result);
    return result;
}

fn checkedEnd(offset: usize, length: usize, bound: usize) !usize {
    const end = std.math.add(usize, offset, length) catch return error.InvalidLayout;
    if (end > bound) return error.InvalidLayout;
    return end;
}

fn u64ToUsize(value: u64) !usize {
    if (value > std.math.maxInt(usize)) return error.InvalidLayout;
    return @intCast(value);
}

fn appendU32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn readU16(bytes: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

fn readU32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn readU64(bytes: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, bytes[at..][0..8], .little);
}

fn writeU16(bytes: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[at..][0..2], value, .little);
}

fn writeU32(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}

fn writeU64(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}
