//! Immutable LEX2 container and typed borrowed views.
//!
//! Opening accepts the canonical semantic contract, validates its indexed
//! sections once, and retains immutable borrowed views. Scalar access never
//! reparses a column or forest. Prose decompression remains explicit; open
//! allocates nothing, and request counters never live in shared state.

const std = @import("std");
const cold_mod = @import("cold.zig");
const columns_mod = @import("columns.zig");
const edges_mod = @import("edges.zig");
const forest_mod = @import("forest.zig");
const keys_mod = @import("keys.zig");
const prose_mod = @import("prose.zig");
const schema = @import("schema.zig");
const wire = @import("wire.zig");
const text = @import("text.zig");

pub const magic = "LEX2";
pub const major: u16 = 2;
pub const minor: u16 = 1;
pub const header_bytes: usize = 64;
pub const directory_bytes: usize = 32;
pub const alignment: usize = 64;
pub const max_sections: usize = 64;
const max40: u64 = (1 << 40) - 1;

pub const Error = wire.Error || error{
    BadMagic,
    UnsupportedVersion,
    UnsupportedFeature,
    InvalidFormat,
    Overlap,
    DuplicateSection,
    MissingSection,
    CorruptChecksum,
    CorruptSection,
    LimitExceeded,
    InvalidReference,
    NoColumn,
    MissingEdges,
    ReverseUnavailable,
    ProfileMismatch,
    OutOfMemory,
    InvalidOptions,
};

pub const SectionKind = enum(u8) {
    schema = 1,
    forest = 2,
    columns = 3,
    atoms = 4,
    key_headword = 5,
    key_normalized = 6,
    key_reversed = 7,
    key_external = 8,
    key_terms = 9,
    key_shapes = 10,
    edges = 11,
    prose = 12,
    cold = 13,
};

const key_kinds = [_]SectionKind{
    .key_headword,
    .key_normalized,
    .key_reversed,
    .key_external,
    .key_terms,
    .key_shapes,
    .atoms,
};

pub const Codec = enum(u4) { raw = 0, bzip3 = 1, unknown = 15 };
pub const required: u4 = 1;
pub const cold: u4 = 2;

pub const OpenOptions = struct {
    max_file_bytes: usize = std.math.maxInt(usize),
    max_section_bytes: usize = std.math.maxInt(usize),
    max_sections: usize = max_sections,
    profile_id: ?u64 = null,
};

pub const Header = struct {
    magic: [4]u8,
    major: u16,
    minor: u16,
    flags: u32,
    section_count: u16,
    header_size: u16,
    file_length: u64,
    directory_offset: u64,
    directory_length: u64,
    root_digest: u64,
    profile_id: u64,
    reserved: u64,
};
const HeaderLayout = wire.Layout(Header);
comptime {
    if (HeaderLayout.size != header_bytes) @compileError("LEX2 header must remain exactly 64 bytes");
}

const DirWord0 = packed struct(u128) {
    kind: u8,
    codec: u4,
    flags: u4,
    items: u32,
    offset: u40,
    stored_length: u40,
};
const DirWord1 = packed struct(u128) {
    logical_length: u40,
    digest: u32,
    profile: u16,
    reserved: u40,
};

pub const Directory = struct {
    kind: u8,
    codec: Codec,
    flags: u4,
    items: u32,
    offset: u64,
    stored_length: u64,
    logical_length: u64,
    digest: u32,
    profile: u16,
};

pub const Section = struct { directory: Directory, bytes: []const u8 };
pub const SectionInput = struct {
    kind: SectionKind,
    bytes: []const u8,
    items: u32 = 0,
    codec: Codec = .raw,
    flags: u4 = required,
    logical_length: ?u64 = null,
    profile: u16 = 0,
};
pub const WriteOptions = struct { profile_id: u64 = 0, flags: u32 = 0 };

pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub fn write(allocator: std.mem.Allocator, options: WriteOptions, input: []const SectionInput) Error!Owned {
    if (options.flags != 0) return error.UnsupportedFeature;
    if (input.len == 0 or input.len > max_sections) return error.InvalidFormat;
    var total: usize = header_bytes;
    for (input, 0..) |section, i| {
        if (i != 0 and @intFromEnum(section.kind) <= @intFromEnum(input[i - 1].kind)) return error.DuplicateSection;
        if (section.flags & ~(required | cold) != 0 or section.codec != .raw) return error.UnsupportedFeature;
        const stored = std.math.cast(u64, section.bytes.len) orelse return error.LimitExceeded;
        const logical = section.logical_length orelse stored;
        if (stored > max40 or logical > max40 or section.codec == .raw and logical != stored) return error.LimitExceeded;
        total = alignForward(try wire.add(total, alignment - 1));
        total = try wire.add(total, section.bytes.len);
        if (total > max40) return error.LimitExceeded;
    }
    const directory_offset = alignForward(try wire.add(total, alignment - 1));
    total = try wire.add(directory_offset, try wire.mul(input.len, directory_bytes));
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    @memset(out, 0);
    try HeaderLayout.write(out, 0, .{
        .magic = magic.*,
        .major = major,
        .minor = minor,
        .flags = options.flags,
        .section_count = @intCast(input.len),
        .header_size = header_bytes,
        .file_length = total,
        .directory_offset = directory_offset,
        .directory_length = input.len * directory_bytes,
        .root_digest = 0,
        .profile_id = options.profile_id,
        .reserved = 0,
    });
    var at: usize = header_bytes;
    for (input, 0..) |section, i| {
        at = alignForward(try wire.add(at, alignment - 1));
        @memcpy(out[at..][0..section.bytes.len], section.bytes);
        const logical = section.logical_length orelse section.bytes.len;
        const word0 = DirWord0{
            .kind = @intFromEnum(section.kind),
            .codec = @intFromEnum(section.codec),
            .flags = section.flags,
            .items = section.items,
            .offset = @intCast(at),
            .stored_length = @intCast(section.bytes.len),
        };
        const word1 = DirWord1{
            .logical_length = @intCast(logical),
            .digest = digest(section.bytes),
            .profile = section.profile,
            .reserved = 0,
        };
        std.mem.writeInt(u128, out[directory_offset + i * directory_bytes ..][0..16], @bitCast(word0), .little);
        std.mem.writeInt(u128, out[directory_offset + i * directory_bytes + 16 ..][0..16], @bitCast(word1), .little);
        at += section.bytes.len;
    }
    const root_digest = containerDigest(out, directory_offset, input.len * directory_bytes);
    try wire.writeInt(u64, out, 40, root_digest);
    return .{ .allocator = allocator, .bytes = out };
}

pub const Snapshot = struct {
    bytes: []const u8,
    header: Header,
    directory: [max_sections]Directory = undefined,
    count: usize,
    ready: bool = false,
    forest_view: forest_mod.View = undefined,
    column_view: columns_mod.View = undefined,
    key_views: [schema.keySpaceTypes().len]keys_mod.View = undefined,
    graph_view: edges_mod.View = undefined,
    prose_view: prose_mod.Store = undefined,
    metadata_view: ?cold_mod.View = null,

    /// Pay structural validation once, then publish a movable immutable value.
    /// All cached objects borrow the original byte buffer, never this struct.
    /// The caller must keep those bytes immutable for the snapshot's lifetime.
    pub fn open(bytes: []const u8, options: OpenOptions) Error!Snapshot {
        var result = try openContainer(bytes, options);
        const contract = try result.require(.schema);
        if (!std.mem.eql(u8, contract.bytes, schema.manifest)) return error.UnsupportedFeature;
        if (result.header.profile_id != text.profile_digest) return error.ProfileMismatch;
        result.forest_view = try result.forest();
        result.column_view = try result.columns();
        inline for (schema.keySpaceTypes()) |spec| {
            const section = try result.require(key_kinds[@intFromEnum(spec.id)]);
            if (section.directory.profile != (if (spec.profile_bound) text.profile else @as(u16, 0))) return error.ProfileMismatch;
            const view = keys_mod.View.open(section.bytes) catch return error.CorruptSection;
            if (view.has_postings != spec.postings or view.key_count != section.directory.items) return error.CorruptSection;
            result.key_views[@intFromEnum(spec.id)] = view;
        }
        result.graph_view = try result.edges();
        result.prose_view = try result.prose(.{});
        result.metadata_view = result.coldMetadata(.{}) catch |err| if (err == error.MissingSection) null else return err;
        result.ready = true;
        try result.validate();
        return result;
    }

    /// Low-level envelope inspection, useful for transport tooling. A container
    /// is not query-ready until the canonical semantic manifest is accepted.
    pub fn openContainer(bytes: []const u8, options: OpenOptions) Error!Snapshot {
        if (bytes.len > options.max_file_bytes) return error.LimitExceeded;
        const header = HeaderLayout.read(bytes, 0) catch |err| return mapWire(err);
        if (!std.mem.eql(u8, &header.magic, magic)) return error.BadMagic;
        if (header.major != major or header.minor > minor) return error.UnsupportedVersion;
        if (header.header_size != header_bytes or header.reserved != 0 or header.flags != 0) return error.UnsupportedFeature;
        if (options.profile_id) |profile| if (profile != header.profile_id) return error.ProfileMismatch;
        if (header.file_length != bytes.len or header.section_count == 0 or
            header.section_count > max_sections or header.section_count > options.max_sections)
            return error.InvalidFormat;
        const directory_offset = try usizeFrom(header.directory_offset);
        const directory_length = try usizeFrom(header.directory_length);
        if (directory_length != try wire.mul(header.section_count, directory_bytes) or directory_offset % alignment != 0 or
            try wire.add(directory_offset, directory_length) != bytes.len)
            return error.InvalidFormat;
        if (containerDigest(bytes, directory_offset, directory_length) != header.root_digest) return error.CorruptChecksum;

        var result = Snapshot{ .bytes = bytes, .header = header, .count = header.section_count };
        var seen = [_]bool{false} ** 256;
        var previous_kind: u8 = 0;
        for (0..result.count) |i| {
            const entry = directory_offset + i * directory_bytes;
            const word0: DirWord0 = @bitCast(std.mem.readInt(u128, bytes[entry..][0..16], .little));
            const word1: DirWord1 = @bitCast(std.mem.readInt(u128, bytes[entry + 16 ..][0..16], .little));
            const codec: Codec = switch (word0.codec) {
                0 => .raw,
                1 => .bzip3,
                else => .unknown,
            };
            const section = Directory{
                .kind = word0.kind,
                .codec = codec,
                .flags = word0.flags,
                .items = word0.items,
                .offset = word0.offset,
                .stored_length = word0.stored_length,
                .logical_length = word1.logical_length,
                .digest = word1.digest,
                .profile = word1.profile,
            };
            if (section.kind == 0 or section.kind <= previous_kind or seen[section.kind] or word1.reserved != 0 or
                section.flags & ~(required | cold) != 0 or section.offset % alignment != 0 or section.offset < header_bytes)
                return error.InvalidFormat;
            previous_kind = section.kind;
            seen[section.kind] = true;
            if (codec == .unknown and section.flags & required != 0) return error.UnsupportedFeature;
            if (!knownSection(section.kind) and section.flags & required != 0) return error.UnsupportedFeature;
            const start = try usizeFrom(section.offset);
            const stored = try usizeFrom(section.stored_length);
            const logical = try usizeFrom(section.logical_length);
            if (stored > options.max_section_bytes or logical > options.max_section_bytes or
                section.codec == .raw and stored != logical)
                return error.LimitExceeded;
            const end = try wire.add(start, stored);
            if (end > directory_offset) return error.InvalidFormat;
            for (result.directory[0..i]) |prior| {
                const prior_start = try usizeFrom(prior.offset);
                const prior_end = try wire.add(prior_start, try usizeFrom(prior.stored_length));
                if (start < prior_end and prior_start < end) return error.Overlap;
            }
            result.directory[i] = section;
            if (section.flags & cold == 0 and digest(bytes[start..end]) != section.digest) return error.CorruptChecksum;
        }
        return result;
    }

    pub fn require(self: *const Snapshot, kind: SectionKind) Error!Section {
        for (self.directory[0..self.count]) |entry| if (entry.kind == @intFromEnum(kind)) {
            if (entry.codec != .raw) return error.UnsupportedFeature;
            const start = try usizeFrom(entry.offset);
            const end = try wire.add(start, try usizeFrom(entry.stored_length));
            if (entry.flags & cold != 0 and digest(self.bytes[start..end]) != entry.digest) return error.CorruptChecksum;
            return .{ .directory = entry, .bytes = self.bytes[start..end] };
        };
        return error.MissingSection;
    }

    pub fn forest(self: *const Snapshot) Error!forest_mod.View {
        if (self.ready) return self.forest_view;
        const section = try self.require(.forest);
        return forest_mod.View.open(section.bytes) catch error.CorruptSection;
    }

    pub fn columns(self: *const Snapshot) Error!columns_mod.View {
        if (self.ready) return self.column_view;
        const f = try self.forest();
        const section = try self.require(.columns);
        return columns_mod.View.open(section.bytes, f.count, &f) catch error.CorruptSection;
    }

    pub fn keySpace(self: *const Snapshot, id: schema.KeySpaceId) Error!keys_mod.View {
        if (self.ready) return self.key_views[@intFromEnum(id)];
        const section = try self.require(key_kinds[@intFromEnum(id)]);
        return keys_mod.View.open(section.bytes) catch error.CorruptSection;
    }

    pub fn keySpaceForProfile(self: *const Snapshot, id: schema.KeySpaceId, profile: u16) Error!keys_mod.View {
        const section = try self.require(key_kinds[@intFromEnum(id)]);
        if (schema.keySpaceSpec(id).profile_bound and section.directory.profile != profile) return error.ProfileMismatch;
        return self.keySpace(id);
    }

    pub fn prose(self: *const Snapshot, options: prose_mod.Options) Error!prose_mod.Store {
        if (self.ready and std.meta.eql(options, prose_mod.Options{})) return self.prose_view;
        const section = try self.require(.prose);
        return prose_mod.Store.open(section.bytes, options) catch |err| switch (err) {
            error.InvalidOptions => error.InvalidOptions,
            error.LimitExceeded => error.LimitExceeded,
            else => error.CorruptSection,
        };
    }

    pub fn edges(self: *const Snapshot) Error!edges_mod.View {
        if (self.ready) return self.graph_view;
        const f = try self.forest();
        const section = try self.require(.edges);
        return edges_mod.View.open(section.bytes, f.count) catch error.CorruptSection;
    }

    pub fn adjacency(self: *const Snapshot, predicate: schema.PredicateId) Error!edges_mod.Adjacency {
        const graph = try self.edges();
        return graph.adjacency(predicate, .forward) catch |err| switch (err) {
            error.ReverseUnavailable => error.ReverseUnavailable,
            else => error.CorruptSection,
        };
    }

    pub fn reverseAdjacency(self: *const Snapshot, predicate: schema.PredicateId) Error!edges_mod.Adjacency {
        const graph = try self.edges();
        return graph.adjacency(predicate, .reverse) catch |err| switch (err) {
            error.ReverseUnavailable => error.ReverseUnavailable,
            else => error.CorruptSection,
        };
    }

    pub fn coldMetadata(self: *const Snapshot, limits: cold_mod.Limits) Error!cold_mod.View {
        if (self.ready and std.meta.eql(limits, cold_mod.Limits{})) return self.metadata_view orelse error.MissingSection;
        const f = try self.forest();
        const section = try self.require(.cold);
        return cold_mod.View.open(section.bytes, f.count, limits) catch error.CorruptSection;
    }

    pub fn get(self: *const Snapshot, comptime Column: type, node: schema.Node) Error!?Column.Value {
        comptime assertColumn(Column);
        if (self.ready) return self.column_view.get(Column, node, &self.forest_view) catch error.CorruptSection;
        const f = try self.forest();
        const table = try self.columns();
        return table.get(Column, node, &f) catch error.CorruptSection;
    }

    /// Cross-section validation is an ingestion cost, never a scalar-read cost.
    /// Prose payload content is validated separately by validateDeep or pin.
    pub fn validate(self: *const Snapshot) Error!void {
        if (!self.ready) return error.InvalidFormat;
        const f = try self.forest();
        const table = try self.columns();
        const graph = try self.edges();
        inline for (@typeInfo(schema.PredicateId).@"enum".fields) |field| {
            const predicate: schema.PredicateId = @enumFromInt(field.value);
            const forward = graph.adjacency(predicate, .forward) catch return error.CorruptSection;
            try validateAdjacency(self, &f, forward, predicate, .forward);
            if (schema.reversePolicy(predicate) == .materialized) {
                const reverse = graph.adjacency(predicate, .reverse) catch return error.CorruptSection;
                try validateAdjacency(self, &f, reverse, predicate, .reverse);
            }
        }
        const store = try self.prose(.{});
        const metadata = self.coldMetadata(.{}) catch |err| if (err == error.MissingSection) null else return err;
        var prose_count: u32 = 0;
        var key_references = [_]usize{0} ** schema.keySpaceTypes().len;
        for (0..f.count) |raw| {
            const node: schema.Node = @enumFromInt(@as(u32, @intCast(raw)));
            const kind = f.kind(node) catch return error.CorruptSection;
            const parent = f.parentOf(node) catch return error.CorruptSection;
            if (!schema.legalParent(if (parent) |p| f.kind(p) catch return error.CorruptSection else null, kind)) return error.InvalidReference;
            inline for (schema.columnTypes()) |C| if (C.over.has(kind)) {
                if (table.get(C, node, &f) catch return error.CorruptSection) |value| switch (C.repr) {
                    .atom => if (@intFromEnum(value) >= (try self.keySpace(.atoms)).key_count) return error.InvalidReference,
                    .key => {
                        const space = C.keySpace().?;
                        if (@intFromEnum(value) >= (try self.keySpace(space)).key_count) return error.InvalidReference;
                        key_references[@intFromEnum(space)] += 1;
                    },
                    .prose => {
                        if (@intFromEnum(value) != prose_count or store.blockForNode(raw) == null) return error.InvalidReference;
                        prose_count += 1;
                    },
                    else => {},
                };
            };
            if (kind == .participant) {
                const target = try self.get(schema.columns.target, node);
                const record = if (metadata) |m| m.get(@intCast(raw)) catch return error.CorruptSection else null;
                const unresolved = if (record) |r| r.unresolved() catch return error.CorruptSection else null;
                if ((target != null) == (unresolved != null)) return error.InvalidReference;
            }
            if (metadata) |m| if (m.get(@intCast(raw)) catch return error.CorruptSection) |record| {
                if ((record.unresolved() catch return error.CorruptSection) != null and kind != .participant) return error.InvalidReference;
                var attributes = record.attributes();
                var shape_buffer: [keys_mod.max_key_bytes]u8 = undefined;
                var length: usize = 0;
                while (attributes.next() catch return error.CorruptSection) |attribute| {
                    if (kind != .extension) return error.InvalidReference;
                    const prefix = std.fmt.bufPrint(shape_buffer[length..], "{d}:", .{attribute.name.len}) catch return error.InvalidReference;
                    length += prefix.len;
                    if (attribute.name.len > shape_buffer.len - length) return error.InvalidReference;
                    @memcpy(shape_buffer[length..][0..attribute.name.len], attribute.name);
                    length += attribute.name.len;
                }
                const shape = try self.get(schema.columns.shape, node);
                if ((length != 0) != (shape != null)) return error.InvalidReference;
                if (shape) |value| {
                    const shapes = try self.keySpace(.shapes);
                    var key_buffer: [keys_mod.max_key_bytes]u8 = undefined;
                    const hit = (shapes.ordinal(@intFromEnum(value), &key_buffer) catch return error.CorruptSection) orelse return error.InvalidReference;
                    if (!std.mem.eql(u8, hit.key, shape_buffer[0..length])) return error.InvalidReference;
                }
            };
            if (kind == .assertion) try self.validateAssertion(node, &f);
        }
        var indexed_prose: usize = 0;
        for (0..store.block_count) |i| {
            const block = store.block(i) catch return error.CorruptSection;
            if (block.node_last >= f.count or block.root_last >= f.count) return error.InvalidReference;
            if ((f.root(@enumFromInt(@as(u32, @intCast(block.node_first)))) catch return error.CorruptSection) != @as(schema.Node, @enumFromInt(@as(u32, @intCast(block.root_first)))) or
                (f.root(@enumFromInt(@as(u32, @intCast(block.node_last)))) catch return error.CorruptSection) != @as(schema.Node, @enumFromInt(@as(u32, @intCast(block.root_last))))) return error.InvalidReference;
            indexed_prose = try wire.add(indexed_prose, block.item_count);
        }
        if (indexed_prose != prose_count or (try self.require(.prose)).directory.items != prose_count) return error.InvalidReference;
        inline for (schema.keySpaceTypes()) |spec| {
            const space = try self.keySpace(spec.id);
            if (spec.postings and spec.id != .terms and space.posting_count != key_references[@intFromEnum(spec.id)]) return error.InvalidReference;
            var scratch: [keys_mod.max_key_bytes]u8 = undefined;
            var keys = space.all(&scratch);
            while (keys.next() catch return error.CorruptSection) |hit| if (space.has_postings) {
                var postings = space.postingIterator(hit) catch return error.CorruptSection;
                while (postings.next() catch return error.CorruptSection) |node| {
                    if (node >= f.count) return error.InvalidReference;
                    const target: schema.Node = @enumFromInt(@as(u32, @intCast(node)));
                    if (!spec.targets.has(f.kind(target) catch return error.CorruptSection)) return error.InvalidReference;
                    var matched = spec.id == .terms;
                    inline for (schema.columnTypes()) |C| if (C.repr == .key and C.keySpace().? == spec.id) {
                        if (try self.get(C, target)) |value| if (@intFromEnum(value) == hit.ordinal) {
                            matched = true;
                        };
                    };
                    if (!matched) return error.InvalidReference;
                    if (spec.id == .terms and (try self.get(schema.columns.text, target)) == null and
                        (try self.get(schema.columns.quote, target)) == null) return error.InvalidReference;
                }
            };
        }
    }

    fn atomIs(self: *const Snapshot, value: schema.Atom, spelling: []const u8) Error!bool {
        const atoms = try self.keySpace(.atoms);
        var scratch: [keys_mod.max_key_bytes]u8 = undefined;
        const hit = atoms.exact(spelling, &scratch) catch return error.CorruptSection;
        return if (hit) |h| h.ordinal == @intFromEnum(value) else false;
    }

    fn validateAssertion(self: *const Snapshot, node: schema.Node, f: *const forest_mod.View) Error!void {
        const name = try self.get(schema.columns.predicate, node) orelse return error.InvalidReference;
        var participants: usize = 0;
        var child = f.firstChild(node) catch return error.CorruptSection;
        while (child) |id| : (child = f.nextSibling(id) catch return error.CorruptSection)
            if ((f.kind(id) catch return error.CorruptSection) == .participant) {
                participants += 1;
            };
        if (participants == 0) return error.InvalidReference;
        var predicate: schema.PredicateId = .extension;
        for (schema.predicateTypes()) |P| if (try self.atomIs(name, P.name)) {
            predicate = P.id;
            var counts = [_]usize{0} ** @typeInfo(schema.Role).@"enum".fields.len;
            child = f.firstChild(node) catch return error.CorruptSection;
            while (child) |id| : (child = f.nextSibling(id) catch return error.CorruptSection) {
                if ((f.kind(id) catch return error.CorruptSection) != .participant) continue;
                const role = try self.get(schema.columns.role, id) orelse return error.InvalidReference;
                var matched = false;
                for (P.roles) |rule| if (try self.atomIs(role, @tagName(rule.role))) {
                    matched = true;
                    counts[@intFromEnum(rule.role)] += 1;
                    if (try self.get(schema.columns.target, id)) |target|
                        if ((f.kind(target) catch return error.CorruptSection) != rule.kind) return error.InvalidReference;
                };
                if (!matched) return error.InvalidReference;
            }
            for (P.roles) |role| {
                const count = counts[@intFromEnum(role.role)];
                if (count == 0 or (role.cardinality == .one and count != 1)) return error.InvalidReference;
            }
        };
        const adjacency_view = try self.adjacency(predicate);
        var source_child = f.firstChild(node) catch return error.CorruptSection;
        while (source_child) |source_id| : (source_child = f.nextSibling(source_id) catch return error.CorruptSection) {
            const source_role = try self.get(schema.columns.role, source_id) orelse continue;
            if (!try self.atomIs(source_role, "source")) continue;
            const source = try self.get(schema.columns.target, source_id) orelse continue;
            var target_child = f.firstChild(node) catch return error.CorruptSection;
            while (target_child) |target_id| : (target_child = f.nextSibling(target_id) catch return error.CorruptSection) {
                const target_role = try self.get(schema.columns.role, target_id) orelse continue;
                if (!try self.atomIs(target_role, "target")) continue;
                const target = try self.get(schema.columns.target, target_id) orelse continue;
                if (!(adjacency_view.contains(source, target, node) catch return error.CorruptSection)) return error.InvalidReference;
            }
        }
    }

    fn assertionHasRole(self: *const Snapshot, assertion: schema.Node, target: schema.Node, role: []const u8, f: *const forest_mod.View) Error!bool {
        var child = f.firstChild(assertion) catch return error.CorruptSection;
        while (child) |id| : (child = f.nextSibling(id) catch return error.CorruptSection) {
            const participant_target = try self.get(schema.columns.target, id) orelse continue;
            const participant_role = try self.get(schema.columns.role, id) orelse continue;
            if (participant_target == target and try self.atomIs(participant_role, role)) return true;
        }
        return false;
    }

    /// Full semantic ingestion audit. Decoding happens outside lookup timing;
    /// every prose item must agree with its column ordinal and forest owner.
    pub fn validateDeep(self: *const Snapshot, allocator: std.mem.Allocator) Error!void {
        if (!self.ready) return error.InvalidFormat;
        const store = try self.prose(.{});
        var decoder = prose_mod.Decoder{};
        defer decoder.deinit();
        var ordinal: u32 = 0;
        for (0..store.block_count) |block| {
            var pin = store.pinUsing(allocator, block, &decoder) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.CorruptSection;
            defer pin.deinit();
            for (0..pin.meta.item_count) |i| {
                const item = pin.item(i) catch return error.CorruptSection;
                const node: schema.Node = @enumFromInt(std.math.cast(u32, item.node) orelse return error.InvalidReference);
                const value = (try self.get(schema.columns.text, node)) orelse (try self.get(schema.columns.quote, node)) orelse return error.InvalidReference;
                if (@intFromEnum(value) != ordinal) return error.InvalidReference;
                ordinal += 1;
            }
        }
    }
};

pub const ForestView = forest_mod.View;
pub const Adjacency = edges_mod.Adjacency;

fn validateAdjacency(snapshot: *const Snapshot, f: *const forest_mod.View, adjacency_view: edges_mod.Adjacency, predicate: schema.PredicateId, direction: edges_mod.Direction) Error!void {
    const spec = schema.predicateSpec(predicate);
    for (0..adjacency_view.source_count) |source_index| {
        const raw_source = adjacency_view.sources.get(source_index) catch return error.CorruptSection;
        const source: schema.Node = @enumFromInt(@as(u32, @intCast(raw_source)));
        if (spec) |predicate_spec| {
            const expected = roleKind(predicate_spec, if (direction == .forward) .source else .target);
            if (expected != null and (f.kind(source) catch return error.CorruptSection) != expected.?) return error.InvalidReference;
        }
        var iterator = adjacency_view.edges(source) catch return error.CorruptSection;
        while (iterator.next() catch return error.CorruptSection) |edge| {
            if (spec) |predicate_spec| {
                const expected = roleKind(predicate_spec, if (direction == .forward) .target else .source);
                if (expected != null and (f.kind(edge.target) catch return error.CorruptSection) != expected.?) return error.InvalidReference;
            }
            if (edge.qualified) |assertion| {
                if ((f.kind(assertion) catch return error.CorruptSection) != .assertion) return error.InvalidReference;
                if (spec) |P| if (!try snapshot.atomIs((try snapshot.get(schema.columns.predicate, assertion)).?, P.name)) return error.InvalidReference;
                if (!try snapshot.assertionHasRole(assertion, source, if (direction == .forward) "source" else "target", f) or
                    !try snapshot.assertionHasRole(assertion, edge.target, if (direction == .forward) "target" else "source", f)) return error.InvalidReference;
            } else if (predicate == .extension) return error.InvalidReference;
            if (schema.reversePolicy(predicate) == .materialized) {
                const opposite = if (direction == .forward) try snapshot.reverseAdjacency(predicate) else try snapshot.adjacency(predicate);
                if (!(opposite.contains(edge.target, source, edge.qualified) catch return error.CorruptSection)) return error.InvalidReference;
            }
        }
    }
}

fn roleKind(spec: schema.PredicateSpec, wanted: schema.Role) ?schema.Kind {
    for (spec.roles) |role| if (role.role == wanted) return role.kind;
    return null;
}

fn assertColumn(comptime Column: type) void {
    schema.assertColumn(Column);
}

fn alignForward(value: usize) usize {
    return value & ~(alignment - 1);
}

fn digest(bytes: []const u8) u32 {
    return @truncate(std.hash.XxHash3.hash(0, bytes));
}

/// The root digest authenticates the routing metadata, not every payload byte;
/// per-section hashes retain lazy cold verification.
fn containerDigest(bytes: []const u8, directory_offset: usize, directory_length: usize) u64 {
    var hash = std.hash.XxHash3.init(0);
    hash.update(bytes[0..40]);
    hash.update(&[_]u8{0} ** 8);
    hash.update(bytes[48..header_bytes]);
    hash.update(bytes[directory_offset..][0..directory_length]);
    return hash.final();
}

fn usizeFrom(value: u64) Error!usize {
    return std.math.cast(usize, value) orelse error.LimitExceeded;
}

fn knownSection(kind: u8) bool {
    return kind >= @intFromEnum(SectionKind.schema) and kind <= @intFromEnum(SectionKind.cold);
}

fn mapWire(err: wire.Error) Error {
    return switch (err) {
        error.Truncated => error.InvalidFormat,
        else => err,
    };
}
