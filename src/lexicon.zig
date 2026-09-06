const std = @import("std");

/// Rich semantic model. It remains separate from the raw snapshot's lexical
/// record sections; payload blocks may use the independent codec layer below.
pub const semantic = @import("semantic.zig");
pub const semantic_format = @import("semantic_format.zig");
pub const SemanticFormat = semantic_format;
pub const SemanticBuilder = semantic.Builder;
pub const SemanticModel = semantic.Model;
pub const query = @import("query.zig");
pub const Query = query.Evaluator;
pub const QueryOptions = query.QueryOptions;
pub const codec = @import("codec.zig");
pub const Codec = codec;

test {
    _ = @import("semantic.zig");
    _ = @import("query.zig");
    _ = @import("semantic_format.zig");
    _ = @import("codec.zig");
}

/// A deliberately small immutable snapshot format. All integers in a snapshot
/// are little endian and are decoded explicitly; no on-disk value is a Zig
/// struct or a native pointer.
pub const format_major: u16 = 1;
/// Minor three adds the bzip3 state size to each codec-tagged payload block.
/// Readers continue to accept minor zero, one and two snapshots.
pub const format_minor: u16 = 3;
pub const max_key_bytes: usize = 65_535;
pub const raw_block_bytes: usize = 65_536;

const magic = "LEXSNAP\x00";
const header_bytes = 64;
const directory_entry_bytes = 48;
const restart_interval: u16 = 8;
const format_id: u64 = 0x4c455849434f4e31;
const section_version: u16 = 1;
const required_section_flag: u16 = 1;

const RestartMeta = struct {
    ordinal: u32,
    offset: u64,
};

const KeyLayout = struct {
    stream_end: usize,
    table_offset: usize,
    restart_count: usize,
};

const DecodedKey = struct {
    key_len: usize,
    posting_start: u64,
    posting_count: u64,
};

pub const Error = error{
    InvalidFormat,
    UnsupportedVersion,
    UnsupportedFeature,
    Truncated,
    Overflow,
    CorruptChecksum,
    CorruptSection,
    DuplicateId,
    DuplicateSection,
    EmptyKey,
    KeyTooLong,
    InvalidUtf8,
    MissingSection,
    NotFound,
    BufferTooSmall,
    OutOfMemory,
};

pub const Record = struct {
    id: u64,
    key: []const u8,
    definition: []const u8,
};

const OwnedRecord = struct {
    id: u64,
    key: []u8,
    definition: []u8,
};

const KeyMeta = struct {
    key: []const u8,
    posting_start: u64,
    posting_count: u64,
};

const Definition = struct {
    bytes: []const u8,
    block: u32 = 0,
    offset: u64 = 0,
};

const BlockMeta = struct {
    offset: u64,
    length: u64,
    digest: u64,
};

const EncodedBlockMeta = struct {
    codec: codec.Kind,
    state_size: u64,
    offset: u64,
    compressed_length: u64,
    uncompressed_length: u64,
    digest: u64,
    bytes: []const u8,
};

const AtomMeta = struct {
    id: u64,
    block: u32,
    offset: u64,
    length: u64,
};

const SectionMeta = struct {
    kind: u32,
    offset: u64,
    length: u64,
    items: u64,
    digest: u64,
};

/// Owns records until build. add() copies caller-owned slices, so a caller may
/// reuse its input buffers immediately after the call returns.
pub const Writer = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(OwnedRecord) = .empty,
    payload_codec: codec.Kind = .raw,
    payload_codec_options: codec.Options = .{},

    pub const Options = struct {
        payload_codec: codec.Kind = .raw,
        codec_options: codec.Options = .{},
    };

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{ .allocator = allocator };
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, options: Options) Writer {
        var writer = init(allocator);
        writer.payload_codec = options.payload_codec;
        writer.payload_codec_options = options.codec_options;
        writer.payload_codec_options.kind = options.payload_codec;
        return writer;
    }

    pub fn deinit(self: *Writer) void {
        for (self.records.items) |record| {
            self.allocator.free(record.key);
            self.allocator.free(record.definition);
        }
        self.records.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *Writer, record: Record) !void {
        if (record.key.len == 0) return Error.EmptyKey;
        if (record.key.len > max_key_bytes) return Error.KeyTooLong;
        if (!std.unicode.utf8ValidateSlice(record.key)) return Error.InvalidUtf8;
        for (self.records.items) |old| {
            if (old.id == record.id) return Error.DuplicateId;
        }
        const key = try self.allocator.dupe(u8, record.key);
        errdefer self.allocator.free(key);
        const definition = try self.allocator.dupe(u8, record.definition);
        errdefer self.allocator.free(definition);
        try self.records.append(self.allocator, .{
            .id = record.id,
            .key = key,
            .definition = definition,
        });
    }

    /// Produces a deterministic, self-contained snapshot. Input order has no
    /// effect: keys, postings, atoms and raw blocks all have canonical order.
    pub fn build(self: *Writer) ![]u8 {
        std.mem.sortUnstable(OwnedRecord, self.records.items, {}, lessRecord);

        const keys = try self.encodeKeys();
        defer self.allocator.free(keys);
        const postings = try self.encodePostings();
        defer self.allocator.free(postings);
        const payload = try self.encodePayload();
        defer self.allocator.free(payload);

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);
        try result.appendNTimes(self.allocator, 0, header_bytes);

        var sections: [3]SectionMeta = undefined;
        const section_bytes = [_][]const u8{ keys, postings, payload };
        const section_kinds = [_]u32{ 1, 2, 3 };
        var section_i: usize = 0;
        while (section_i < section_bytes.len) : (section_i += 1) {
            try align8(&result, self.allocator);
            const offset = result.items.len;
            try result.appendSlice(self.allocator, section_bytes[section_i]);
            sections[section_i] = .{
                .kind = section_kinds[section_i],
                .offset = try toU64(offset),
                .length = try toU64(section_bytes[section_i].len),
                .items = try sectionItemCount(section_i, self.records.items.len, keys, postings, payload),
                .digest = checksum(section_bytes[section_i]),
            };
        }

        try align8(&result, self.allocator);
        const dir_offset: usize = result.items.len;
        for (sections) |section| {
            try putU32(&result, self.allocator, section.kind);
            try putU16(&result, self.allocator, 1);
            try putU16(&result, self.allocator, 1); // required section
            try putU64(&result, self.allocator, section.offset);
            try putU64(&result, self.allocator, section.length);
            try putU64(&result, self.allocator, section.length);
            try putU64(&result, self.allocator, section.items);
            try putU64(&result, self.allocator, section.digest);
        }
        const file_len = try toU64(result.items.len);
        const dir_len = try toU64(result.items.len - dir_offset);

        @memcpy(result.items[0..8], magic);
        std.mem.writeInt(u16, result.items[8..10], format_major, .little);
        std.mem.writeInt(u16, result.items[10..12], format_minor, .little);
        std.mem.writeInt(u32, result.items[12..16], 0, .little);
        std.mem.writeInt(u64, result.items[16..24], file_len, .little);
        std.mem.writeInt(u64, result.items[24..32], try toU64(dir_offset), .little);
        std.mem.writeInt(u64, result.items[32..40], dir_len, .little);
        std.mem.writeInt(u64, result.items[40..48], 0, .little);
        std.mem.writeInt(u64, result.items[48..56], format_id, .little);
        std.mem.writeInt(u64, result.items[56..64], 0, .little);
        const root = checksumRoot(result.items);
        std.mem.writeInt(u64, result.items[40..48], root, .little);
        return result.toOwnedSlice(self.allocator);
    }

    fn encodeKeys(self: *Writer) ![]u8 {
        var groups: std.ArrayList(KeyMeta) = .empty;
        defer groups.deinit(self.allocator);
        var postings: std.ArrayList(u64) = .empty;
        defer postings.deinit(self.allocator);

        var i: usize = 0;
        while (i < self.records.items.len) {
            const begin = i;
            const key = self.records.items[i].key;
            while (i < self.records.items.len and std.mem.eql(u8, key, self.records.items[i].key)) : (i += 1) {
                try postings.append(self.allocator, self.records.items[i].id);
            }
            try groups.append(self.allocator, .{
                .key = key,
                .posting_start = 0,
                .posting_count = try toU64(i - begin),
            });
            groups.items[groups.items.len - 1].posting_start = try toU64(postings.items.len - (i - begin));
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try putU32(&out, self.allocator, try toU32(groups.items.len));
        try putU16(&out, self.allocator, restart_interval);
        try putU16(&out, self.allocator, 0);
        try putU64(&out, self.allocator, 0);

        var restarts: std.ArrayList(RestartMeta) = .empty;
        defer restarts.deinit(self.allocator);
        var previous: []const u8 = "";
        for (groups.items, 0..) |group, group_index| {
            const restart = group_index % restart_interval == 0;
            if (restart) {
                try restarts.append(self.allocator, .{
                    .ordinal = try toU32(group_index),
                    .offset = try toU64(out.items.len),
                });
            }
            if (restart) {
                try out.append(self.allocator, 0);
                try putU32(&out, self.allocator, try toU32(group.key.len));
                try out.appendSlice(self.allocator, group.key);
            } else {
                const common = commonPrefix(previous, group.key);
                try out.append(self.allocator, 1);
                try putU16(&out, self.allocator, try toU16(common));
                try putU32(&out, self.allocator, try toU32(group.key.len - common));
                try out.appendSlice(self.allocator, group.key[common..]);
            }
            try putU64(&out, self.allocator, group.posting_start);
            try putU64(&out, self.allocator, group.posting_count);
            previous = group.key;
        }

        // Minor one appends a fixed-width restart directory.  The header
        // points at it so a reader can binary-search restart keys without
        // interpreting bytes belonging to the key stream as table entries.
        const restart_offset = try toU64(out.items.len);
        std.mem.writeInt(u64, out.items[8..16], restart_offset, .little);
        try putU32(&out, self.allocator, try toU32(restarts.items.len));
        try putU32(&out, self.allocator, 0);
        for (restarts.items) |restart| {
            try putU32(&out, self.allocator, restart.ordinal);
            try putU32(&out, self.allocator, 0);
            try putU64(&out, self.allocator, restart.offset);
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn encodePostings(self: *Writer) ![]u8 {
        var groups: std.ArrayList(KeyMeta) = .empty;
        defer groups.deinit(self.allocator);
        var i: usize = 0;
        while (i < self.records.items.len) {
            const begin = i;
            const key = self.records.items[i].key;
            while (i < self.records.items.len and std.mem.eql(u8, key, self.records.items[i].key)) : (i += 1) {}
            try groups.append(self.allocator, .{
                .key = key,
                .posting_start = try toU64(begin),
                .posting_count = try toU64(i - begin),
            });
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try putU64(&out, self.allocator, try toU64(self.records.items.len));
        for (groups.items) |group| {
            var j = try toUsize(group.posting_start);
            const end = try checkedAdd(j, try toUsize(group.posting_count));
            while (j < end) : (j += 1) try putU64(&out, self.allocator, self.records.items[j].id);
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn encodePayload(self: *Writer) ![]u8 {
        var definitions: std.ArrayList(Definition) = .empty;
        defer definitions.deinit(self.allocator);
        for (self.records.items) |record| {
            var found = false;
            for (definitions.items) |definition| {
                if (std.mem.eql(u8, definition.bytes, record.definition)) {
                    found = true;
                    break;
                }
            }
            if (!found) try definitions.append(self.allocator, .{ .bytes = record.definition });
        }
        std.mem.sortUnstable(Definition, definitions.items, {}, lessDefinition);

        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(self.allocator);
        var blocks: std.ArrayList(BlockMeta) = .empty;
        defer blocks.deinit(self.allocator);
        var current_start: usize = 0;
        for (definitions.items) |*definition| {
            const definition_len = definition.bytes.len;

            // A definition is one addressable atom. Oversized atoms therefore
            // receive a dedicated oversized block instead of being split into
            // ranges that the atom table cannot represent.
            if (definition_len > raw_block_bytes) {
                if (raw.items.len != current_start) {
                    const length = raw.items.len - current_start;
                    try blocks.append(self.allocator, .{
                        .offset = try toU64(current_start),
                        .length = try toU64(length),
                        .digest = checksum(raw.items[current_start..]),
                    });
                }
                current_start = raw.items.len;
                definition.block = try toU32(blocks.items.len);
                definition.offset = 0;
                try raw.appendSlice(self.allocator, definition.bytes);
                try blocks.append(self.allocator, .{
                    .offset = try toU64(current_start),
                    .length = try toU64(definition_len),
                    .digest = checksum(raw.items[current_start..]),
                });
                current_start = raw.items.len;
                continue;
            }

            const current_len = raw.items.len - current_start;
            const candidate_len = try checkedAdd(current_len, definition_len);
            if (current_len != 0 and candidate_len > raw_block_bytes) {
                try blocks.append(self.allocator, .{
                    .offset = try toU64(current_start),
                    .length = try toU64(current_len),
                    .digest = checksum(raw.items[current_start..]),
                });
                current_start = raw.items.len;
            }

            // Keep an explicit empty block for an empty definition. This
            // gives it a valid atom identity and keeps the raw region exact.
            if (definition_len == 0) {
                definition.block = try toU32(blocks.items.len);
                definition.offset = 0;
                try blocks.append(self.allocator, .{ .offset = try toU64(raw.items.len), .length = 0, .digest = checksum(&.{}) });
                current_start = raw.items.len;
                continue;
            }

            definition.block = try toU32(blocks.items.len);
            definition.offset = try toU64(raw.items.len - current_start);
            try raw.appendSlice(self.allocator, definition.bytes);
        }
        if (raw.items.len != current_start) {
            const length = raw.items.len - current_start;
            try blocks.append(self.allocator, .{
                .offset = try toU64(current_start),
                .length = try toU64(length),
                .digest = checksum(raw.items[current_start..]),
            });
        }

        var atoms: std.ArrayList(AtomMeta) = .empty;
        defer atoms.deinit(self.allocator);
        for (self.records.items) |record| {
            for (definitions.items) |definition| {
                if (std.mem.eql(u8, definition.bytes, record.definition)) {
                    try atoms.append(self.allocator, .{
                        .id = record.id,
                        .block = definition.block,
                        .offset = definition.offset,
                        .length = try toU64(definition.bytes.len),
                    });
                    break;
                }
            }
        }
        std.mem.sortUnstable(AtomMeta, atoms.items, {}, struct {
            fn less(_: void, a: AtomMeta, b: AtomMeta) bool {
                return a.id < b.id;
            }
        }.less);

        // Encode each independently addressable raw block separately.  When
        // bzip3 is requested, retain the compressed form only when it is
        // strictly smaller; the wire record always states the actual codec.
        var encoded_blocks: std.ArrayList(codec.OwnedBlock) = .empty;
        defer {
            for (encoded_blocks.items) |*encoded| encoded.deinit();
            encoded_blocks.deinit(self.allocator);
        }
        var encoded_meta: std.ArrayList(EncodedBlockMeta) = .empty;
        defer encoded_meta.deinit(self.allocator);
        var codec_options = self.payload_codec_options;
        codec_options.kind = self.payload_codec;
        // Validate the selected state before processing blocks. This keeps an
        // invalid bzip3 profile an explicit build error even for an empty
        // payload, while resource failures below remain eligible for raw
        // fallback on individual blocks.
        if (self.payload_codec == .bzip3) _ = try codec.bzip3.memoryNeeded(codec_options.block_size);
        for (blocks.items) |block| {
            const start = try toUsize(block.offset);
            const end = try checkedAdd(start, try toUsize(block.length));
            var encoded = codec.encodeBlock(self.allocator, raw.items[start..end], codec_options) catch |err| switch (err) {
                // Oversized definitions cannot fit bzip3's configured block
                // state. They remain addressable as raw blocks.
                error.InputTooLarge,
                error.ResourceLimit,
                error.CompressedSizeTooLarge,
                error.OutputTooLarge,
                => blk: {
                    if (self.payload_codec != .bzip3) return err;
                    var fallback = codec_options;
                    fallback.kind = .raw;
                    break :blk try codec.encodeBlock(self.allocator, raw.items[start..end], fallback);
                },
                else => return err,
            };
            if (self.payload_codec == .bzip3 and
                std.meta.activeTag(encoded) == .bzip3 and
                encoded.bytes().len >= end - start)
            {
                encoded.deinit();
                var fallback = codec_options;
                fallback.kind = .raw;
                encoded = try codec.encodeBlock(self.allocator, raw.items[start..end], fallback);
            }
            const actual_codec = std.meta.activeTag(encoded);
            const state_size: u64 = if (actual_codec == .bzip3) try toU64(codec_options.block_size) else 0;
            var owns_encoded = true;
            errdefer if (owns_encoded) encoded.deinit();
            try encoded_blocks.append(self.allocator, encoded);
            owns_encoded = false;
            try encoded_meta.append(self.allocator, .{
                .codec = actual_codec,
                .state_size = state_size,
                .offset = 0,
                .compressed_length = try toU64(encoded.bytes().len),
                .uncompressed_length = block.length,
                .digest = checksum(encoded.bytes()),
                .bytes = encoded.bytes(),
            });
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try putU32(&out, self.allocator, try toU32(atoms.items.len));
        try putU32(&out, self.allocator, try toU32(encoded_meta.items.len));
        try putU32(&out, self.allocator, try toU32(raw_block_bytes));
        try putU32(&out, self.allocator, 0);
        const block_entry_bytes: usize = 48;
        const data_base = try checkedAdd(try checkedAdd(16, try mul(atoms.items.len, 32)), try mul(encoded_meta.items.len, block_entry_bytes));
        for (atoms.items) |atom| {
            try putU64(&out, self.allocator, atom.id);
            try putU32(&out, self.allocator, atom.block);
            try putU32(&out, self.allocator, 0);
            try putU64(&out, self.allocator, atom.offset);
            try putU64(&out, self.allocator, atom.length);
        }
        var data_offset = data_base;
        for (encoded_meta.items) |*block| {
            block.offset = try toU64(data_offset);
            try putU64(&out, self.allocator, block.offset);
            try putU64(&out, self.allocator, block.compressed_length);
            try putU64(&out, self.allocator, block.uncompressed_length);
            try putU64(&out, self.allocator, block.digest);
            try out.append(self.allocator, @intFromEnum(block.codec));
            try out.appendNTimes(self.allocator, 0, 7);
            try putU64(&out, self.allocator, block.state_size);
            data_offset = try checkedAdd(data_offset, try toUsize(block.compressed_length));
        }
        for (encoded_meta.items) |block| try out.appendSlice(self.allocator, block.bytes);
        return out.toOwnedSlice(self.allocator);
    }
};

pub const Reader = struct {
    pub const Options = struct {
        /// Upper bound for the native bzip3 state and decode work buffer used
        /// by one lazy definition read. The default is deliberately bounded;
        /// callers handling larger profiles must opt in explicitly.
        max_decode_memory_bytes: usize = 64 * 1024 * 1024,
        /// Allocator used for the temporary output of a lazy bzip3
        /// definition decode. The allocation is released before definition
        /// returns, but this allocator context must remain alive while the
        /// reader is in use. Raw definitions never call it.
        decode_allocator: std.mem.Allocator = std.heap.page_allocator,
    };

    bytes: []const u8,
    keys: []const u8,
    postings: []const u8,
    payload: []const u8,
    format_minor: u16,
    key_stream_end: usize,
    restart_table_offset: usize,
    restart_count: usize,
    key_records_examined: u64 = 0,
    atom_records_examined: u64 = 0,
    payload_reads: u64 = 0,
    decode_memory_limit: usize,
    decode_allocator: std.mem.Allocator,

    pub fn open(bytes: []const u8) !Reader {
        return openWithOptions(bytes, .{});
    }

    pub fn openWithOptions(bytes: []const u8, options: Options) !Reader {
        if (options.max_decode_memory_bytes == 0) return Error.InvalidFormat;
        if (bytes.len < header_bytes) return Error.Truncated;
        if (!std.mem.eql(u8, bytes[0..8], magic)) return Error.InvalidFormat;
        if (try readU16(bytes, 8) != format_major or try readU16(bytes, 10) > format_minor) return Error.UnsupportedVersion;
        const snapshot_minor = try readU16(bytes, 10);
        if (try readU32(bytes, 12) != 0) return Error.UnsupportedFeature;
        if (try readU64(bytes, 16) != bytes.len) return Error.InvalidFormat;
        if (try readU64(bytes, 48) != format_id) return Error.UnsupportedVersion;
        const dir_offset = try readU64(bytes, 24);
        const dir_len = try readU64(bytes, 32);
        const dir_end = try addU64(dir_offset, dir_len);
        if (dir_offset < header_bytes or dir_offset % 8 != 0 or dir_end != bytes.len or dir_len == 0 or dir_len % directory_entry_bytes != 0) return Error.InvalidFormat;
        if (checksumRoot(bytes) != try readU64(bytes, 40)) return Error.CorruptChecksum;
        const dir_count = dir_len / directory_entry_bytes;
        if (dir_count > 128) return Error.InvalidFormat;

        var sections: [3]?[]const u8 = .{ null, null, null };
        var section_offsets: [3]u64 = .{ 0, 0, 0 };
        var section_ends: [3]u64 = .{ 0, 0, 0 };
        var section_items: [3]u64 = .{ 0, 0, 0 };
        var seen: [3]bool = .{ false, false, false };
        var all_offsets: [128]u64 = undefined;
        var all_ends: [128]u64 = undefined;
        var all_count: usize = 0;
        var i: u64 = 0;
        while (i < dir_count) : (i += 1) {
            const entry_offset = try addU64(dir_offset, try mulU64(i, directory_entry_bytes));
            const at = try toUsize(entry_offset);
            const kind = try readU32(bytes, at);
            const version = try readU16(bytes, at + 4);
            const flags = try readU16(bytes, at + 6);
            const offset = try readU64(bytes, at + 8);
            const length = try readU64(bytes, at + 16);
            const logical = try readU64(bytes, at + 24);
            const items = try readU64(bytes, at + 32);
            const digest = try readU64(bytes, at + 40);
            if (version != section_version) return Error.UnsupportedVersion;
            if (flags & ~required_section_flag != 0) return Error.UnsupportedFeature;
            if (logical != length) return Error.UnsupportedFeature;
            if (offset % 8 != 0 or offset < header_bytes) return Error.InvalidFormat;
            const end = try addU64(offset, length);
            if (end > dir_offset or end > bytes.len) return Error.InvalidFormat;
            if (all_count == all_offsets.len) return Error.InvalidFormat;
            for (0..all_count) |previous| {
                if (offset < all_ends[previous] and all_offsets[previous] < end) return Error.InvalidFormat;
            }
            all_offsets[all_count] = offset;
            all_ends[all_count] = end;
            all_count += 1;
            const section_bytes = bytes[try toUsize(offset)..try toUsize(end)];
            if (checksum(section_bytes) != digest) return Error.CorruptChecksum;
            if (kind < 1 or kind > 3) {
                if (flags != 0) return Error.UnsupportedFeature;
                continue;
            }
            const index: usize = @intCast(kind - 1);
            if (flags != required_section_flag) return Error.InvalidFormat;
            if (seen[index]) return Error.DuplicateSection;
            seen[index] = true;
            sections[index] = section_bytes;
            section_offsets[index] = offset;
            section_ends[index] = end;
            section_items[index] = items;
        }
        for (0..3) |a| {
            if (!seen[a]) return Error.MissingSection;
            for (a + 1..3) |b| {
                if (section_offsets[a] < section_ends[b] and section_offsets[b] < section_ends[a]) return Error.InvalidFormat;
            }
        }
        const keys = sections[0].?;
        const postings = sections[1].?;
        const payload = sections[2].?;
        if (section_items[0] != try toU64(try readU32(keys, 0)) or
            section_items[1] != try readU64(postings, 0) or
            section_items[2] != try toU64(try readU32(payload, 0))) return Error.CorruptSection;
        try validatePayload(payload, snapshot_minor);
        const key_layout = try validateKeys(keys, postings, payload, snapshot_minor);
        return .{
            .bytes = bytes,
            .keys = keys,
            .postings = postings,
            .payload = payload,
            .format_minor = snapshot_minor,
            .key_stream_end = key_layout.stream_end,
            .restart_table_offset = key_layout.table_offset,
            .restart_count = key_layout.restart_count,
            .decode_memory_limit = options.max_decode_memory_bytes,
            .decode_allocator = options.decode_allocator,
        };
    }

    pub fn payloadReadCount(self: *const Reader) u64 {
        return self.payload_reads;
    }

    /// Number of key records decoded by lookup operations.  This is an
    /// observable work counter, not a timing claim; callers can compare the
    /// indexed path with a reference scan on the same snapshot.
    pub fn keyRecordsExamined(self: *const Reader) u64 {
        return self.key_records_examined;
    }

    /// Number of atom-directory records inspected by definition lookups.
    /// Definition IDs are stored in ascending order, so successful and
    /// unsuccessful lookups use checked binary search over this directory.
    pub fn atomRecordsExamined(self: *const Reader) u64 {
        return self.atom_records_examined;
    }

    pub fn resetLookupMetrics(self: *Reader) void {
        self.key_records_examined = 0;
        self.atom_records_examined = 0;
        self.payload_reads = 0;
    }

    pub fn lookupExact(self: *Reader, key: []const u8, out: []u64) !usize {
        if (!std.unicode.utf8ValidateSlice(key)) return Error.InvalidUtf8;
        return self.lookup(key, out, false);
    }

    pub fn lookupPrefix(self: *Reader, prefix: []const u8, out: []u64) !usize {
        if (!std.unicode.utf8ValidateSlice(prefix)) return Error.InvalidUtf8;
        return self.lookup(prefix, out, true);
    }

    pub fn definition(self: *Reader, id: u64, out: []u8) !usize {
        const payload = self.payload;
        const atom_count = try readU32(payload, 0);
        const atom_base: usize = 16;
        const count = try toUsize(atom_count);

        // The atom directory is validated as strictly ID-sorted by open().
        // Keep all index arithmetic checked: this lookup is also part of the
        // reader's corruption boundary, and the directory can be untrusted.
        var low: usize = 0;
        var high: usize = count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const at = try checkedAdd(atom_base, try mul(middle, 32));
            const atom_id = try readU64(payload, at);
            self.atom_records_examined += 1;
            if (atom_id < id) low = middle + 1 else high = middle;
        }
        if (low == count) return Error.NotFound;

        const at = try checkedAdd(atom_base, try mul(low, 32));
        const atom_id = try readU64(payload, at);
        self.atom_records_examined += 1;
        if (atom_id != id) return Error.NotFound;
        const block = try readU32(payload, at + 8);
        const offset = try readU64(payload, at + 16);
        const length = try readU64(payload, at + 24);
        if (length > out.len) return Error.BufferTooSmall;
        const block_count = try readU32(payload, 4);
        if (block >= block_count) return Error.CorruptSection;
        const block_table = try checkedAdd(atom_base, try mul(count, 32));
        const block_entry_bytes: usize = if (self.format_minor >= 3) 48 else if (self.format_minor >= 2) 40 else 32;
        const block_at = try checkedAdd(block_table, try mul(try toUsize(block), block_entry_bytes));
        const block_offset = try readU64(payload, block_at);
        const compressed_length = try readU64(payload, block_at + 8);
        const uncompressed_length = if (self.format_minor >= 2)
            try readU64(payload, block_at + 16)
        else
            compressed_length;
        if (offset > uncompressed_length or length > uncompressed_length - offset) return Error.CorruptSection;
        const block_end = try addU64(block_offset, compressed_length);
        if (block_end > payload.len) return Error.CorruptSection;
        const block_start = try toUsize(block_offset);
        const block_bytes = payload[block_start..try toUsize(block_end)];
        if (checksum(block_bytes) != try readU64(payload, block_at + 24)) return Error.CorruptChecksum;
        const atom_len = try toUsize(length);
        const start = try toUsize(offset);
        const codec_tag = if (self.format_minor >= 2) try readU8(payload, block_at + 32) else @intFromEnum(codec.Kind.raw);
        if (codec_tag > @intFromEnum(codec.Kind.bzip3)) return Error.CorruptSection;
        const decoded = if (codec_tag == @intFromEnum(codec.Kind.raw)) blk: {
            if (compressed_length != uncompressed_length or compressed_length != try toU64(block_bytes.len)) return Error.CorruptSection;
            break :blk block_bytes;
        } else blk: {
            const kind: codec.Kind = @enumFromInt(codec_tag);
            const state_size = if (self.format_minor >= 3)
                try toUsize(try readU64(payload, block_at + 40))
            else
                codec.bzip3.default_block_size;
            if (kind != .bzip3 or state_size < codec.bzip3.min_block_size or state_size < try toUsize(uncompressed_length) or state_size > codec.bzip3.max_block_size) return Error.CorruptSection;
            const required_memory = codec.bzip3.memoryNeeded(state_size) catch return Error.CorruptSection;
            if (required_memory > self.decode_memory_limit) return Error.CorruptSection;
            var decoded_block = codec.decodeBlock(self.decode_allocator, block_bytes, try toUsize(uncompressed_length), .{
                .kind = kind,
                .block_size = state_size,
                .max_uncompressed_bytes = try toUsize(uncompressed_length),
                .max_compressed_bytes = block_bytes.len,
                .max_memory_bytes = self.decode_memory_limit,
            }) catch |err| switch (err) {
                error.OutOfMemory, error.AllocationFailed => return Error.OutOfMemory,
                else => return Error.CorruptSection,
            };
            defer decoded_block.deinit();
            if (decoded_block.originalSize() != try toUsize(uncompressed_length)) return Error.CorruptSection;
            if (start > decoded_block.bytes().len or atom_len > decoded_block.bytes().len - start) return Error.CorruptSection;
            @memcpy(out[0..atom_len], decoded_block.bytes()[start .. start + atom_len]);
            break :blk &[_]u8{};
        };
        if (decoded.len != 0) {
            if (start > decoded.len or atom_len > decoded.len - start) return Error.CorruptSection;
            @memcpy(out[0..atom_len], decoded[start .. start + atom_len]);
        }
        self.payload_reads += 1;
        return atom_len;
    }

    fn lookup(self: *Reader, needle: []const u8, out: []u64, prefix: bool) !usize {
        if (self.format_minor >= 1) return self.lookupIndexed(needle, out, prefix);
        return self.lookupScan(needle, out, prefix);
    }

    fn lookupScan(self: *Reader, needle: []const u8, out: []u64, prefix: bool) !usize {
        var key_buf: [max_key_bytes]u8 = undefined;
        var key_len: usize = 0;
        var previous_len: usize = 0;
        const key_count = try readU32(self.keys, 0);
        var cursor: usize = 16;
        var output_len: usize = 0;
        var i: u32 = 0;
        while (i < key_count) : (i += 1) {
            if (cursor >= self.keys.len) return Error.CorruptSection;
            const marker = self.keys[cursor];
            cursor += 1;
            if (marker == 0) {
                const full_len = try readU32(self.keys, cursor);
                cursor += 4;
                if (full_len > max_key_bytes or full_len > self.keys.len - cursor) return Error.CorruptSection;
                key_len = @intCast(full_len);
                @memcpy(key_buf[0..key_len], self.keys[cursor .. cursor + key_len]);
                cursor += key_len;
            } else if (marker == 1) {
                const common = try readU16(self.keys, cursor);
                cursor += 2;
                const suffix_len = try readU32(self.keys, cursor);
                cursor += 4;
                if (common > previous_len or suffix_len > max_key_bytes - common or suffix_len > self.keys.len - cursor) return Error.CorruptSection;
                key_len = @as(usize, common) + @as(usize, @intCast(suffix_len));
                @memcpy(key_buf[common..key_len], self.keys[cursor .. cursor + @as(usize, @intCast(suffix_len))]);
                cursor += @intCast(suffix_len);
            } else return Error.CorruptSection;
            const posting_start = try readU64(self.keys, cursor);
            const posting_count = try readU64(self.keys, cursor + 8);
            cursor += 16;
            self.key_records_examined += 1;
            const posting_total = try readU64(self.postings, 0);
            if (posting_start > posting_total or posting_count > posting_total - posting_start) return Error.CorruptSection;
            const matches = if (prefix) std.mem.startsWith(u8, key_buf[0..key_len], needle) else std.mem.eql(u8, key_buf[0..key_len], needle);
            if (matches) {
                if (posting_count > out.len -| output_len) return Error.BufferTooSmall;
                var p: u64 = 0;
                while (p < posting_count) : (p += 1) {
                    const posting_index = try addU64(posting_start, p);
                    const at = try checkedAdd(8, try mul(@as(usize, @intCast(posting_index)), 8));
                    out[output_len] = try readU64(self.postings, at);
                    output_len += 1;
                }
                if (!prefix) return output_len;
            }
            previous_len = key_len;
        }
        if (cursor != self.keys.len) return Error.CorruptSection;
        return output_len;
    }

    fn lookupIndexed(self: *Reader, needle: []const u8, out: []u64, prefix: bool) !usize {
        const key_count = try readU32(self.keys, 0);
        if (key_count == 0) return 0;

        const begin = try self.lowerBound(needle);
        if (!prefix) {
            if (begin >= key_count) return 0;
            return self.scanIndexedRange(begin, begin + 1, needle, false, out);
        }

        var end: u32 = key_count;
        var upper_storage: [max_key_bytes]u8 = undefined;
        if (nextPrefixUpper(needle, &upper_storage)) |upper| {
            end = try self.lowerBound(upper);
        }
        if (end < begin) return Error.CorruptSection;
        return self.scanIndexedRange(begin, end, needle, true, out);
    }

    /// Return the first key ordinal whose bytes are greater than or equal to
    /// needle.  The binary search probes only restart records, then decodes
    /// at most one restart interval to establish the exact boundary.
    fn lowerBound(self: *Reader, needle: []const u8) !u32 {
        const count = try readU32(self.keys, 0);
        if (count == 0) return 0;
        if (self.restart_count == 0) return Error.CorruptSection;
        const interval: usize = @intCast(try readU16(self.keys, 4));

        var low: usize = 0;
        var high: usize = self.restart_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            var key_buf: [max_key_bytes]u8 = undefined;
            const anchor = try self.decodeRestart(middle, &key_buf);
            const order = std.mem.order(u8, key_buf[0..anchor.key_len], needle);
            if (order == .lt) low = middle + 1 else high = middle;
        }

        // If the first anchor at or above needle is N, the answer is in the
        // preceding block (or exactly at N).  This keeps the sequential work
        // bounded by one restart interval even at a restart boundary.
        const anchor_index = if (low == 0) 0 else low - 1;
        const start_ordinal = try checkedMul(anchor_index, interval);
        const next_ordinal = @min(count, try checkedMul(anchor_index + 1, interval));
        var cursor = try self.restartOffset(anchor_index);
        var key_buf: [max_key_bytes]u8 = undefined;
        var previous_len: usize = 0;
        var ordinal: u32 = @intCast(start_ordinal);
        while (ordinal < next_ordinal) : (ordinal += 1) {
            const record = try self.readKeyRecord(&cursor, &previous_len, &key_buf, self.key_stream_end);
            if (std.mem.order(u8, key_buf[0..record.key_len], needle) != .lt) return ordinal;
        }
        return @intCast(next_ordinal);
    }

    fn scanIndexedRange(self: *Reader, start: u32, end: u32, needle: []const u8, prefix: bool, out: []u64) !usize {
        const key_count = try readU32(self.keys, 0);
        if (start > end or end > key_count or start == end) return 0;
        const interval: usize = @intCast(try readU16(self.keys, 4));
        const anchor_index = @as(usize, start) / interval;
        var cursor = try self.restartOffset(anchor_index);
        var key_buf: [max_key_bytes]u8 = undefined;
        var previous_len: usize = 0;
        var ordinal: u32 = @intCast(anchor_index * interval);
        var output_len: usize = 0;
        while (ordinal < end) : (ordinal += 1) {
            const record = try self.readKeyRecord(&cursor, &previous_len, &key_buf, self.key_stream_end);
            if (ordinal < start) continue;
            const current = key_buf[0..record.key_len];
            const matches = if (prefix) std.mem.startsWith(u8, current, needle) else std.mem.eql(u8, current, needle);
            if (!matches) continue;
            if (record.posting_count > out.len - output_len) return Error.BufferTooSmall;
            var p: u64 = 0;
            while (p < record.posting_count) : (p += 1) {
                const posting_index = try addU64(record.posting_start, p);
                const at = try checkedAdd(8, try mul(try toUsize(posting_index), 8));
                out[output_len] = try readU64(self.postings, at);
                output_len += 1;
            }
        }
        return output_len;
    }

    fn restartOffset(self: *const Reader, index: usize) !usize {
        if (index >= self.restart_count) return Error.CorruptSection;
        const at = try checkedAdd(self.restart_table_offset, try checkedAdd(8, try mul(index, 16)));
        const ordinal = try readU32(self.keys, at);
        if (ordinal != try toU32(try checkedMul(index, @as(usize, @intCast(try readU16(self.keys, 4)))))) return Error.CorruptSection;
        return try toUsize(try readU64(self.keys, try checkedAdd(at, 8)));
    }

    fn decodeRestart(self: *Reader, index: usize, key_buf: *[max_key_bytes]u8) !DecodedKey {
        var cursor = try self.restartOffset(index);
        var previous_len: usize = 0;
        const record = try self.readKeyRecord(&cursor, &previous_len, key_buf, self.key_stream_end);
        if (previous_len == 0 or cursor > self.key_stream_end) return Error.CorruptSection;
        return record;
    }

    fn readKeyRecord(self: *Reader, cursor: *usize, previous_len: *usize, key_buf: *[max_key_bytes]u8, limit: usize) !DecodedKey {
        if (cursor.* >= limit) return Error.CorruptSection;
        const marker = self.keys[cursor.*];
        cursor.* += 1;
        var key_len: usize = 0;
        if (marker == 0) {
            if (limit - cursor.* < 4) return Error.CorruptSection;
            const full = try readU32(self.keys, cursor.*);
            cursor.* += 4;
            const full_len = try toUsize(full);
            if (full_len == 0 or full_len > max_key_bytes or full_len > limit - cursor.*) return Error.CorruptSection;
            key_len = full_len;
            @memcpy(key_buf[0..key_len], self.keys[cursor.* .. cursor.* + key_len]);
            cursor.* += key_len;
        } else if (marker == 1) {
            if (limit - cursor.* < 6) return Error.CorruptSection;
            const common = try toUsize(try readU16(self.keys, cursor.*));
            cursor.* += 2;
            const suffix_len = try toUsize(try readU32(self.keys, cursor.*));
            cursor.* += 4;
            if (common > previous_len.* or suffix_len > max_key_bytes - common or suffix_len > limit - cursor.*) return Error.CorruptSection;
            key_len = try checkedAdd(common, suffix_len);
            if (key_len == 0) return Error.CorruptSection;
            @memcpy(key_buf[common..key_len], self.keys[cursor.* .. cursor.* + suffix_len]);
            cursor.* += suffix_len;
        } else return Error.CorruptSection;
        if (!std.unicode.utf8ValidateSlice(key_buf[0..key_len])) return Error.CorruptSection;
        if (limit - cursor.* < 16) return Error.CorruptSection;
        const posting_start = try readU64(self.keys, cursor.*);
        const posting_count = try readU64(self.keys, cursor.* + 8);
        cursor.* += 16;
        previous_len.* = key_len;
        self.key_records_examined += 1;
        return .{ .key_len = key_len, .posting_start = posting_start, .posting_count = posting_count };
    }
};

fn validateKeys(keys: []const u8, postings: []const u8, payload: []const u8, snapshot_minor: u16) !KeyLayout {
    if (keys.len < 16 or postings.len < 8) return Error.CorruptSection;
    const count = try readU32(keys, 0);
    const interval = try readU16(keys, 4);
    if (interval == 0 or try readU16(keys, 6) != 0) return Error.CorruptSection;
    const declared_table_offset = try readU64(keys, 8);
    var stream_end: usize = keys.len;
    var table_offset: usize = keys.len;
    var restart_count: usize = 0;
    if (snapshot_minor == 0) {
        if (declared_table_offset != 0) return Error.CorruptSection;
    } else if (snapshot_minor == 1 or snapshot_minor == 2 or snapshot_minor == 3) {
        table_offset = try toUsize(declared_table_offset);
        if (table_offset < 16 or table_offset > keys.len or keys.len - table_offset < 8) return Error.CorruptSection;
        stream_end = table_offset;
        restart_count = try toUsize(try readU32(keys, table_offset));
        if (try readU32(keys, table_offset + 4) != 0) return Error.CorruptSection;
        const expected_numerator = try checkedAdd(@as(usize, count), @as(usize, interval) - 1);
        const expected = expected_numerator / @as(usize, interval);
        if (restart_count != expected) return Error.CorruptSection;
        const table_bytes = try checkedAdd(8, try mul(restart_count, 16));
        if (table_bytes != keys.len - table_offset) return Error.CorruptSection;
        var previous_offset: usize = 0;
        var r: usize = 0;
        while (r < restart_count) : (r += 1) {
            const at = try checkedAdd(table_offset, try checkedAdd(8, try mul(r, 16)));
            const ordinal = try readU32(keys, at);
            if (ordinal != try toU32(try checkedMul(r, @as(usize, interval))) or try readU32(keys, at + 4) != 0) return Error.CorruptSection;
            const offset = try toUsize(try readU64(keys, at + 8));
            if (offset < 16 or offset >= stream_end or (r != 0 and offset <= previous_offset)) return Error.CorruptSection;
            previous_offset = offset;
        }
    } else return Error.UnsupportedVersion;
    const posting_count = try readU64(postings, 0);
    const atom_count = try readU32(payload, 0);
    if (posting_count != atom_count) return Error.CorruptSection;
    const posting_bytes = try mul(try toUsize(posting_count), 8);
    const expected_postings_len = try checkedAdd(8, posting_bytes);
    if (postings.len != expected_postings_len) return Error.CorruptSection;
    var cursor: usize = 16;
    var previous_len: usize = 0;
    var previous_key: [max_key_bytes]u8 = undefined;
    var current_key: [max_key_bytes]u8 = undefined;
    var covered: u64 = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const record_start = cursor;
        if (cursor >= stream_end) return Error.CorruptSection;
        const marker = keys[cursor];
        cursor += 1;
        var length: usize = 0;
        const restart = i % @as(u32, interval) == 0;
        if ((marker == 0) != restart) return Error.CorruptSection;
        if (snapshot_minor >= 1 and restart) {
            const restart_index: usize = @intCast(i / @as(u32, interval));
            const restart_at = try checkedAdd(table_offset, try checkedAdd(8, try mul(restart_index, 16)));
            if (try readU64(keys, restart_at + 8) != try toU64(record_start)) return Error.CorruptSection;
        }
        if (marker == 0) {
            if (stream_end - cursor < 4) return Error.CorruptSection;
            const full = try readU32(keys, cursor);
            cursor += 4;
            if (full > max_key_bytes or full > stream_end - cursor) return Error.CorruptSection;
            length = try toUsize(full);
            @memcpy(current_key[0..length], keys[cursor .. cursor + length]);
            cursor += length;
        } else if (marker == 1) {
            if (stream_end - cursor < 6) return Error.CorruptSection;
            const common = try readU16(keys, cursor);
            cursor += 2;
            const suffix = try readU32(keys, cursor);
            cursor += 4;
            if (common > previous_len or suffix > max_key_bytes - common or suffix > stream_end - cursor) return Error.CorruptSection;
            const suffix_len = try toUsize(suffix);
            length = try checkedAdd(common, suffix_len);
            @memcpy(current_key[0..common], previous_key[0..common]);
            @memcpy(current_key[common..length], keys[cursor .. cursor + suffix_len]);
            cursor += suffix_len;
        } else return Error.CorruptSection;
        if (length == 0 or !std.unicode.utf8ValidateSlice(current_key[0..length])) return Error.CorruptSection;
        if (i != 0 and std.mem.order(u8, previous_key[0..previous_len], current_key[0..length]) != .lt) return Error.CorruptSection;
        const start = try readU64(keys, cursor);
        const amount = try readU64(keys, cursor + 8);
        cursor += 16;
        if (amount == 0 or start != covered or amount > posting_count - start) return Error.CorruptSection;
        covered = try addU64(start, amount);
        var p: u64 = 0;
        while (p < amount) : (p += 1) {
            const posting_index = try addU64(start, p);
            const id = try readU64(postings, try checkedAdd(8, try mul(try toUsize(posting_index), 8)));
            if (!payloadHasId(payload, id)) return Error.CorruptSection;
            var prior: u64 = 0;
            while (prior < posting_index) : (prior += 1) {
                const old = try readU64(postings, try checkedAdd(8, try mul(try toUsize(prior), 8)));
                if (old == id) return Error.CorruptSection;
            }
        }
        @memcpy(previous_key[0..length], current_key[0..length]);
        previous_len = length;
    }
    if (cursor != stream_end or covered != posting_count) return Error.CorruptSection;
    return .{ .stream_end = stream_end, .table_offset = table_offset, .restart_count = restart_count };
}

fn payloadHasId(payload: []const u8, id: u64) bool {
    const count = readU32(payload, 0) catch return false;
    var low: usize = 0;
    var high: usize = toUsize(count) catch return false;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const at = checkedAdd(16, mul(middle, 32) catch return false) catch return false;
        const candidate = readU64(payload, at) catch return false;
        if (candidate < id) low = middle + 1 else high = middle;
    }
    if (low == toUsize(count) catch return false) return false;
    const at = checkedAdd(16, mul(low, 32) catch return false) catch return false;
    return (readU64(payload, at) catch return false) == id;
}

fn validatePayload(payload: []const u8, snapshot_minor: u16) !void {
    if (payload.len < 16) return Error.CorruptSection;
    const atom_count = try readU32(payload, 0);
    const block_count = try readU32(payload, 4);
    if (try readU32(payload, 12) != 0) return Error.CorruptSection;
    _ = try readU32(payload, 8); // configured target; oversized atom blocks are legal
    const atom_end = try checkedAdd(16, try mul(try toUsize(atom_count), 32));
    const block_entry_bytes: usize = if (snapshot_minor >= 3) 48 else if (snapshot_minor >= 2) 40 else 32;
    const block_end = try checkedAdd(atom_end, try mul(try toUsize(block_count), block_entry_bytes));
    if (block_end > payload.len) return Error.CorruptSection;
    var previous_id: ?u64 = null;
    var i: u32 = 0;
    while (i < atom_count) : (i += 1) {
        const at = try checkedAdd(16, try mul(try toUsize(i), 32));
        const id = try readU64(payload, at);
        if (previous_id) |old| if (id <= old) return Error.CorruptSection;
        previous_id = id;
        const block = try readU32(payload, at + 8);
        if (try readU32(payload, at + 12) != 0) return Error.CorruptSection;
        const offset = try readU64(payload, at + 16);
        const length = try readU64(payload, at + 24);
        if (block >= block_count) return Error.CorruptSection;
        const block_at = try checkedAdd(atom_end, try mul(try toUsize(block), block_entry_bytes));
        const block_offset = try readU64(payload, block_at);
        const compressed_length = try readU64(payload, block_at + 8);
        const uncompressed_length = if (snapshot_minor >= 2) try readU64(payload, block_at + 16) else compressed_length;
        if (offset > uncompressed_length or length > uncompressed_length - offset) return Error.CorruptSection;
        if (snapshot_minor < 2 and try readU64(payload, block_at + 16) != compressed_length) return Error.CorruptSection;
        const block_end_at = try addU64(block_offset, compressed_length);
        if (block_offset < block_end or block_end_at > payload.len) return Error.CorruptSection;
    }
    var b: u32 = 0;
    while (b < block_count) : (b += 1) {
        const at = try checkedAdd(atom_end, try mul(try toUsize(b), block_entry_bytes));
        const offset = try readU64(payload, at);
        const compressed_length = try readU64(payload, at + 8);
        const uncompressed_length = if (snapshot_minor >= 2) try readU64(payload, at + 16) else compressed_length;
        const end = try addU64(offset, compressed_length);
        if (offset < block_end or end > payload.len) return Error.CorruptSection;
        if (b == 0) {
            if (offset != block_end) return Error.CorruptSection;
        } else {
            const previous_at = try checkedAdd(atom_end, try mul(try toUsize(b - 1), block_entry_bytes));
            const previous_end = try addU64(try readU64(payload, previous_at), try readU64(payload, previous_at + 8));
            if (offset != previous_end) return Error.CorruptSection;
        }
        if (snapshot_minor < 2) {
            if (try readU64(payload, at + 16) != compressed_length) return Error.CorruptSection;
        } else {
            if (try readU8(payload, at + 32) > @intFromEnum(codec.Kind.bzip3)) return Error.CorruptSection;
            var reserved: usize = 33;
            while (reserved < 40) : (reserved += 1) if (try readU8(payload, at + reserved) != 0) return Error.CorruptSection;
            const kind: codec.Kind = @enumFromInt(try readU8(payload, at + 32));
            if (kind == .raw and compressed_length != uncompressed_length) return Error.CorruptSection;
            if (kind == .bzip3) {
                const state_size = if (snapshot_minor >= 3)
                    try readU64(payload, at + 40)
                else
                    try toU64(codec.bzip3.default_block_size);
                if (state_size < try toU64(codec.bzip3.min_block_size) or state_size < uncompressed_length or state_size > try toU64(codec.bzip3.max_block_size)) return Error.CorruptSection;
                if (snapshot_minor >= 3) {
                    // A raw block has no state. A bzip3 block must carry one;
                    // rejecting zero here prevents a decoder from guessing a
                    // profile that was never part of the wire contract.
                    if (state_size == 0) return Error.CorruptSection;
                }
            } else if (snapshot_minor >= 3 and try readU64(payload, at + 40) != 0) return Error.CorruptSection;
        }
        if (checksum(payload[try toUsize(offset)..try toUsize(end)]) != try readU64(payload, at + 24)) return Error.CorruptChecksum;
    }
    if (block_count == 0) {
        if (payload.len != block_end) return Error.CorruptSection;
    } else {
        const last_at = try checkedAdd(atom_end, try mul(try toUsize(block_count - 1), block_entry_bytes));
        const last_end = try addU64(try readU64(payload, last_at), try readU64(payload, last_at + 8));
        if (last_end != payload.len) return Error.CorruptSection;
    }
}

fn lessRecord(_: void, a: OwnedRecord, b: OwnedRecord) bool {
    const order = std.mem.order(u8, a.key, b.key);
    return order == .lt or (order == .eq and a.id < b.id);
}

fn lessDefinition(_: void, a: Definition, b: Definition) bool {
    return std.mem.lessThan(u8, a.bytes, b.bytes);
}

fn commonPrefix(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) : (i += 1) {}
    return i;
}

fn checkedMul(a: usize, b: usize) !usize {
    return std.math.mul(usize, a, b) catch Error.Overflow;
}

/// The half-open byte range for a literal prefix is [prefix,
/// nextPrefixUpper(prefix)).  A prefix consisting entirely of 0xff bytes has
/// no finite upper bound in the bytewise key order.
fn nextPrefixUpper(prefix: []const u8, storage: *[max_key_bytes]u8) ?[]const u8 {
    if (prefix.len == 0) return null;
    @memcpy(storage[0..prefix.len], prefix);
    var i = prefix.len;
    while (i > 0) {
        i -= 1;
        if (storage[i] != 0xff) {
            storage[i] += 1;
            return storage[0 .. i + 1];
        }
    }
    return null;
}

fn sectionItemCount(index: usize, records: usize, keys: []const u8, postings: []const u8, payload: []const u8) !u64 {
    return switch (index) {
        0 => try toU64(try readU32(keys, 0)),
        1 => try readU64(postings, 0),
        2 => try toU64(try readU32(payload, 0)),
        else => try toU64(records),
    };
}

fn align8(out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    const remainder = out.items.len % 8;
    if (remainder != 0) try out.appendNTimes(allocator, 0, 8 - remainder);
}

fn putU16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn readU8(bytes: []const u8, offset: usize) !u8 {
    if (offset >= bytes.len) return Error.Truncated;
    return bytes[offset];
}

fn putU32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn putU64(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn readU16(bytes: []const u8, at: usize) !u16 {
    if (at > bytes.len or bytes.len - at < 2) return Error.Truncated;
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

fn readU32(bytes: []const u8, at: usize) !u32 {
    if (at > bytes.len or bytes.len - at < 4) return Error.Truncated;
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn readU64(bytes: []const u8, at: usize) !u64 {
    if (at > bytes.len or bytes.len - at < 8) return Error.Truncated;
    return std.mem.readInt(u64, bytes[at..][0..8], .little);
}

fn checkedAdd(a: usize, b: usize) !usize {
    return std.math.add(usize, a, b) catch Error.Overflow;
}

fn addU64(a: u64, b: u64) !u64 {
    return std.math.add(u64, a, b) catch Error.Overflow;
}

fn mul(a: usize, b: usize) !usize {
    return std.math.mul(usize, a, b) catch Error.Overflow;
}

fn mulU64(a: u64, b: u64) !u64 {
    return std.math.mul(u64, a, b) catch Error.Overflow;
}

fn toU16(value: usize) !u16 {
    if (value > std.math.maxInt(u16)) return Error.Overflow;
    return @intCast(value);
}

fn toU32(value: anytype) !u32 {
    if (value > std.math.maxInt(u32)) return Error.Overflow;
    return @intCast(value);
}

fn toU64(value: anytype) !u64 {
    if (value > std.math.maxInt(u64)) return Error.Overflow;
    return @intCast(value);
}

fn toUsize(value: anytype) !usize {
    if (value > std.math.maxInt(usize)) return Error.Overflow;
    return @intCast(value);
}

/// FNV-1a-64 is used as a deterministic accidental-corruption checksum. It
/// is deliberately non-cryptographic; authentication belongs above the file
/// format. The root digest hashes every byte while treating header bytes
/// 40..47 as eight zero bytes.
fn checksum(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    return hash;
}

fn checksumRoot(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (bytes, 0..) |byte, index| {
        const value: u8 = if (index >= 40 and index < 48) 0 else byte;
        hash ^= value;
        hash *%= 0x100000001b3;
    }
    return hash;
}

test "deterministic exact and prefix lookup keeps payload cold" {
    var writer = Writer.init(std.testing.allocator);
    defer writer.deinit();
    try writer.add(.{ .id = 20, .key = "bank", .definition = "financial institution" });
    try writer.add(.{ .id = 7, .key = "bank", .definition = "edge of a river" });
    try writer.add(.{ .id = 99, .key = "banker", .definition = "one who works at a bank" });
    const bytes = try writer.build();
    defer std.testing.allocator.free(bytes);
    var reader = try Reader.open(bytes);
    var ids: [8]u64 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try reader.lookupExact("bank", ids[0..]));
    try std.testing.expectEqual(@as(u64, 7), ids[0]);
    try std.testing.expectEqual(@as(u64, 20), ids[1]);
    try std.testing.expectEqual(@as(usize, 3), try reader.lookupPrefix("bank", ids[0..]));
    try std.testing.expectEqual(@as(u64, 99), ids[2]);
    try std.testing.expectEqual(@as(u64, 0), reader.payloadReadCount());
}

test "shared definitions are one raw atom and definition reads are explicit" {
    var writer = Writer.init(std.testing.allocator);
    defer writer.deinit();
    try writer.add(.{ .id = 2, .key = "a", .definition = "same" });
    try writer.add(.{ .id = 1, .key = "b", .definition = "same" });
    const bytes = try writer.build();
    defer std.testing.allocator.free(bytes);
    var reader = try Reader.open(bytes);
    var out: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try reader.definition(1, out[0..]));
    try std.testing.expectEqualStrings("same", out[0..4]);
    try std.testing.expectEqual(@as(u64, 1), reader.payloadReadCount());
}

test "duplicate IDs, Unicode bytes, shuffled insertion and corruption" {
    var a = Writer.init(std.testing.allocator);
    defer a.deinit();
    try a.add(.{ .id = 3, .key = "e\u{301}", .definition = "decomposed" });
    try a.add(.{ .id = 1, .key = "é", .definition = "composed" });
    try std.testing.expectError(Error.DuplicateId, a.add(.{ .id = 1, .key = "x", .definition = "x" }));
    const first = try a.build();
    defer std.testing.allocator.free(first);

    var b = Writer.init(std.testing.allocator);
    defer b.deinit();
    try b.add(.{ .id = 1, .key = "é", .definition = "composed" });
    try b.add(.{ .id = 3, .key = "e\u{301}", .definition = "decomposed" });
    const second = try b.build();
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualSlices(u8, first, second);

    var corrupted = try std.testing.allocator.dupe(u8, first);
    defer std.testing.allocator.free(corrupted);
    corrupted[corrupted.len - 1] ^= 1;
    try std.testing.expectError(Error.CorruptChecksum, Reader.open(corrupted));
    var reader = try Reader.open(first);
    var ids: [2]u64 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try reader.lookupExact("é", ids[0..]));
    try std.testing.expectEqual(@as(u64, 1), ids[0]);
}

test "input validation and bounded output are explicit" {
    var writer = Writer.init(std.testing.allocator);
    defer writer.deinit();
    try std.testing.expectError(Error.EmptyKey, writer.add(.{ .id = 1, .key = "", .definition = "" }));
    try std.testing.expectError(Error.InvalidUtf8, writer.add(.{ .id = 2, .key = "\xff", .definition = "" }));
    var too_long: [max_key_bytes + 1]u8 = undefined;
    @memset(&too_long, 'x');
    try std.testing.expectError(Error.KeyTooLong, writer.add(.{ .id = 3, .key = &too_long, .definition = "" }));
    try writer.add(.{ .id = 4, .key = "one", .definition = "definition" });
    const bytes = try writer.build();
    defer std.testing.allocator.free(bytes);
    var reader = try Reader.open(bytes);
    var ids: [1]u64 = undefined;
    try std.testing.expectError(Error.BufferTooSmall, reader.lookupExact("one", &[_]u64{}));
    try std.testing.expectEqual(@as(usize, 1), try reader.lookupExact("one", ids[0..]));
    try std.testing.expectError(Error.InvalidUtf8, reader.lookupExact("\xff", ids[0..]));
    var definition_buf: [4]u8 = undefined;
    try std.testing.expectError(Error.BufferTooSmall, reader.definition(4, definition_buf[0..]));
}

test "open rejects truncated, wrong magic, and damaged sections" {
    var writer = Writer.init(std.testing.allocator);
    defer writer.deinit();
    try writer.add(.{ .id = 1, .key = "key", .definition = "value" });
    const bytes = try writer.build();
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(Error.Truncated, Reader.open(bytes[0 .. header_bytes - 1]));

    var wrong_magic = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(wrong_magic);
    wrong_magic[0] ^= 1;
    try std.testing.expectError(Error.InvalidFormat, Reader.open(wrong_magic));

    const damaged = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(damaged);
    const directory = try readU64(damaged, 24);
    const first_section = try readU64(damaged, @intCast(directory + 8));
    damaged[@intCast(first_section)] ^= 1;
    std.mem.writeInt(u64, damaged[40..48], checksumRoot(damaged), .little);
    try std.testing.expectError(Error.CorruptChecksum, Reader.open(damaged));
}

test "payload blocks flush exactly and preserve empty and oversized definitions" {
    var writer = Writer.init(std.testing.allocator);
    defer writer.deinit();
    const half = raw_block_bytes / 2;
    const first = try std.testing.allocator.alloc(u8, half);
    defer std.testing.allocator.free(first);
    @memset(first, 'a');
    const second = try std.testing.allocator.alloc(u8, half + 1);
    defer std.testing.allocator.free(second);
    @memset(second, 'b');
    const huge = try std.testing.allocator.alloc(u8, raw_block_bytes + 17);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'z');
    try writer.add(.{ .id = 1, .key = "empty", .definition = "" });
    try writer.add(.{ .id = 2, .key = "first", .definition = first });
    try writer.add(.{ .id = 3, .key = "second", .definition = second });
    try writer.add(.{ .id = 4, .key = "huge", .definition = huge });
    const bytes = try writer.build();
    defer std.testing.allocator.free(bytes);
    var reader = try Reader.open(bytes);
    var out = try std.testing.allocator.alloc(u8, huge.len);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 0), try reader.definition(1, out));
    try std.testing.expectEqualSlices(u8, first, out[0..try reader.definition(2, out)]);
    try std.testing.expectEqualSlices(u8, second, out[0..try reader.definition(3, out)]);
    try std.testing.expectEqualSlices(u8, huge, out[0..try reader.definition(4, out)]);
}

test "bzip3 payload blocks preserve semantics and remain independently addressed" {
    const length = 100_000;
    const definition = try std.testing.allocator.alloc(u8, length);
    defer std.testing.allocator.free(definition);
    for (definition, 0..) |*byte, index| byte.* = if (index % 97 < 90) 'a' else 'b';

    var raw_writer = Writer.init(std.testing.allocator);
    defer raw_writer.deinit();
    try raw_writer.add(.{ .id = 1, .key = "compressed", .definition = definition });
    const raw_snapshot = try raw_writer.build();
    defer std.testing.allocator.free(raw_snapshot);

    var bzip_writer = Writer.initWithOptions(std.testing.allocator, .{ .payload_codec = .bzip3 });
    defer bzip_writer.deinit();
    try bzip_writer.add(.{ .id = 1, .key = "compressed", .definition = definition });
    const bzip_snapshot = try bzip_writer.build();
    defer std.testing.allocator.free(bzip_snapshot);
    const bzip_snapshot_again = try bzip_writer.build();
    defer std.testing.allocator.free(bzip_snapshot_again);
    try std.testing.expectEqualSlices(u8, bzip_snapshot, bzip_snapshot_again);

    var raw_reader = try Reader.open(raw_snapshot);
    var bzip_reader = try Reader.open(bzip_snapshot);
    var ids: [1]u64 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try bzip_reader.lookupExact("compressed", ids[0..]));
    try std.testing.expectEqual(@as(u64, 0), bzip_reader.payloadReadCount());
    var output = try std.testing.allocator.alloc(u8, definition.len);
    defer std.testing.allocator.free(output);
    const raw_len = try raw_reader.definition(1, output);
    const bzip_len = try bzip_reader.definition(1, output);
    try std.testing.expectEqual(definition.len, raw_len);
    try std.testing.expectEqual(definition.len, bzip_len);
    try std.testing.expectEqualSlices(u8, definition, output[0..bzip_len]);

    const payload = try mutableSection(bzip_snapshot, 3);
    const atom_end = 16 + 32;
    const block_at = atom_end;
    try std.testing.expectEqual(@as(u8, @intFromEnum(codec.Kind.bzip3)), try readU8(payload, block_at + 32));
    try std.testing.expect(try readU64(payload, block_at + 8) < try readU64(payload, block_at + 16));

    const damaged = try std.testing.allocator.dupe(u8, bzip_snapshot);
    defer std.testing.allocator.free(damaged);
    const damaged_payload = try mutableSection(damaged, 3);
    const compressed_offset = try toUsize(try readU64(damaged_payload, block_at));
    damaged_payload[compressed_offset] ^= 1;
    refreshIntegrity(damaged, 3);
    try std.testing.expectError(Error.CorruptChecksum, Reader.open(damaged));

    // Checksums protect the snapshot envelope, while codec validation stays
    // lazy so exact/prefix lookups remain payload-cold. Repairing both
    // checksums must therefore move the failure to the explicit definition
    // read and still return a bounded Zig error.
    const repaired = try std.testing.allocator.dupe(u8, bzip_snapshot);
    defer std.testing.allocator.free(repaired);
    const repaired_payload = try mutableSection(repaired, 3);
    repaired_payload[compressed_offset] ^= 1;
    std.mem.writeInt(
        u64,
        repaired_payload[block_at + 24 ..][0..8],
        checksum(repaired_payload[compressed_offset .. compressed_offset + try toUsize(try readU64(repaired_payload, block_at + 8))]),
        .little,
    );
    refreshIntegrity(repaired, 3);
    var lazy_reader = try Reader.open(repaired);
    try std.testing.expectError(Error.CorruptSection, lazy_reader.definition(1, output[0..]));

    const invalid_codec = try std.testing.allocator.dupe(u8, bzip_snapshot);
    defer std.testing.allocator.free(invalid_codec);
    const invalid_payload = try mutableSection(invalid_codec, 3);
    invalid_payload[block_at + 32] = 2;
    refreshIntegrity(invalid_codec, 3);
    try std.testing.expectError(Error.CorruptSection, Reader.open(invalid_codec));
}

test "lazy bzip3 decode honors its allocator and releases failed output" {
    const definition = try std.testing.allocator.alloc(u8, 100_000);
    defer std.testing.allocator.free(definition);
    for (definition, 0..) |*byte, index| byte.* = if (index % 97 < 90) 'a' else 'b';

    var writer = Writer.initWithOptions(std.testing.allocator, .{ .payload_codec = .bzip3 });
    defer writer.deinit();
    try writer.add(.{ .id = 1, .key = "allocator", .definition = definition });
    const snapshot = try writer.build();
    defer std.testing.allocator.free(snapshot);

    var output: [100_000]u8 = undefined;

    var raw_writer = Writer.init(std.testing.allocator);
    defer raw_writer.deinit();
    try raw_writer.add(.{ .id = 1, .key = "allocator", .definition = definition });
    const raw_snapshot = try raw_writer.build();
    defer std.testing.allocator.free(raw_snapshot);
    var raw_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var raw_reader = try Reader.openWithOptions(raw_snapshot, .{ .decode_allocator = raw_failing.allocator() });
    try std.testing.expectEqual(definition.len, try raw_reader.definition(1, output[0..]));
    try std.testing.expectEqual(@as(usize, 0), raw_failing.allocations);
    try std.testing.expectEqual(@as(usize, 0), raw_failing.deallocations);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var reader = try Reader.openWithOptions(snapshot, .{ .decode_allocator = failing.allocator() });
    try std.testing.expectError(Error.OutOfMemory, reader.definition(1, output[0..]));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(usize, 0), failing.deallocations);

    // Repair the block checksum and envelope after damaging the compressed
    // bytes. The decoder must free its caller-owned output when the codec
    // rejects the block after allocation.
    const damaged = try std.testing.allocator.dupe(u8, snapshot);
    defer std.testing.allocator.free(damaged);
    const payload = try mutableSection(damaged, 3);
    const block_at = 16 + 32;
    const compressed_offset = try toUsize(try readU64(payload, block_at));
    const compressed_length = try toUsize(try readU64(payload, block_at + 8));
    // The first four bytes are the encoded CRC. Changing one of them leaves
    // the size/model probe intact, but guarantees the final decode-integrity
    // check fails after the caller allocator has received its output buffer.
    payload[compressed_offset] ^= 1;
    std.mem.writeInt(
        u64,
        payload[block_at + 24 ..][0..8],
        checksum(payload[compressed_offset .. compressed_offset + compressed_length]),
        .little,
    );
    refreshIntegrity(damaged, 3);

    var tracked = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var damaged_reader = try Reader.openWithOptions(damaged, .{ .decode_allocator = tracked.allocator() });
    try std.testing.expectError(Error.CorruptSection, damaged_reader.definition(1, output[0..]));
    try std.testing.expect(tracked.allocations >= 1);
    try std.testing.expectEqual(tracked.allocations, tracked.deallocations);
}

test "custom bzip3 state size is carried on wire and used by lazy decode" {
    const state_size = 512 * 1024;
    const definition_len = 300 * 1024;
    const definition = try std.testing.allocator.alloc(u8, definition_len);
    defer std.testing.allocator.free(definition);
    for (definition, 0..) |*byte, index| byte.* = if (index % 257 < 240) 'x' else @intCast(index & 0xff);

    var writer = Writer.initWithOptions(std.testing.allocator, .{
        .payload_codec = .bzip3,
        .codec_options = .{ .block_size = state_size },
    });
    defer writer.deinit();
    try writer.add(.{ .id = 7, .key = "custom-state", .definition = definition });
    const snapshot = try writer.build();
    defer std.testing.allocator.free(snapshot);

    const payload = try mutableSection(snapshot, 3);
    const block_at = 16 + 32;
    try std.testing.expectEqual(@as(u8, @intFromEnum(codec.Kind.bzip3)), try readU8(payload, block_at + 32));
    try std.testing.expectEqual(@as(u64, state_size), try readU64(payload, block_at + 40));

    var reader = try Reader.open(snapshot);
    const output = try std.testing.allocator.alloc(u8, definition_len);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqual(definition_len, try reader.definition(7, output));
    try std.testing.expectEqualSlices(u8, definition, output);
}

test "invalid bzip3 profiles are build errors while resource limits may fall back" {
    var invalid_size = Writer.initWithOptions(std.testing.allocator, .{
        .payload_codec = .bzip3,
        .codec_options = .{ .block_size = codec.bzip3.min_block_size - 1 },
    });
    defer invalid_size.deinit();
    try invalid_size.add(.{ .id = 1, .key = "invalid-size", .definition = "definition" });
    try std.testing.expectError(codec.Error.InvalidBlockSize, invalid_size.build());

    var invalid_limit = Writer.initWithOptions(std.testing.allocator, .{
        .payload_codec = .bzip3,
        .codec_options = .{ .max_memory_bytes = 0 },
    });
    defer invalid_limit.deinit();
    try invalid_limit.add(.{ .id = 2, .key = "invalid-limit", .definition = "definition" });
    try std.testing.expectError(codec.Error.InvalidLimit, invalid_limit.build());

    const oversized = try std.testing.allocator.alloc(u8, codec.bzip3.min_block_size + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'r');
    var resource_ceiling = Writer.initWithOptions(std.testing.allocator, .{
        .payload_codec = .bzip3,
        .codec_options = .{ .block_size = codec.bzip3.min_block_size },
    });
    defer resource_ceiling.deinit();
    try resource_ceiling.add(.{ .id = 3, .key = "resource-ceiling", .definition = oversized });
    const snapshot = try resource_ceiling.build();
    defer std.testing.allocator.free(snapshot);
    const payload = try mutableSection(snapshot, 3);
    try std.testing.expectEqual(@as(u8, @intFromEnum(codec.Kind.raw)), try readU8(payload, 16 + 32 + 32));
}

test "definition lookup binary-searches sorted atom IDs for raw and bzip snapshots" {
    const count = 1021;
    var records: [count]Record = undefined;
    var keys: [count][16]u8 = undefined;
    var definitions: [count][24]u8 = undefined;
    for (0..count) |i| {
        records[i] = .{
            .id = 100_000 + i,
            .key = std.fmt.bufPrint(&keys[i], "word-{d:0>4}", .{i}) catch unreachable,
            .definition = std.fmt.bufPrint(&definitions[i], "meaning-{d:0>8}", .{i}) catch unreachable,
        };
    }

    const options = [_]Writer.Options{
        .{},
        .{ .payload_codec = .bzip3 },
    };
    for (options) |writer_options| {
        var writer = Writer.initWithOptions(std.testing.allocator, writer_options);
        defer writer.deinit();
        // 73 and 1021 are coprime, so this exercises a deterministic
        // shuffled insertion order while preserving a sorted atom directory.
        for (0..count) |step| try writer.add(records[(step * 73) % count]);
        const snapshot = try writer.build();
        defer std.testing.allocator.free(snapshot);
        var reader = try Reader.open(snapshot);
        var output: [32]u8 = undefined;
        const logarithmic_bound = 12; // ceil(log2(1021)) + final candidate + one margin

        reader.resetLookupMetrics();
        try std.testing.expectEqual(@as(usize, records[0].definition.len), try reader.definition(records[0].id, output[0..]));
        try std.testing.expectEqualSlices(u8, records[0].definition, output[0..records[0].definition.len]);
        try std.testing.expect(reader.atomRecordsExamined() <= logarithmic_bound);

        reader.resetLookupMetrics();
        try std.testing.expectEqual(@as(usize, records[count - 1].definition.len), try reader.definition(records[count - 1].id, output[0..]));
        try std.testing.expectEqualSlices(u8, records[count - 1].definition, output[0..records[count - 1].definition.len]);
        try std.testing.expect(reader.atomRecordsExamined() <= logarithmic_bound);

        reader.resetLookupMetrics();
        try std.testing.expectError(Error.NotFound, reader.definition(99_999, output[0..]));
        try std.testing.expect(reader.atomRecordsExamined() <= logarithmic_bound);
        try std.testing.expectEqual(@as(u64, 0), reader.payloadReadCount());

        reader.resetLookupMetrics();
        try std.testing.expectError(Error.NotFound, reader.definition(101_021, output[0..]));
        try std.testing.expect(reader.atomRecordsExamined() <= logarithmic_bound);
        try std.testing.expectEqual(@as(u64, 0), reader.payloadReadCount());
    }
}

test "generated reference model agrees with exact and prefix lookup" {
    const count = 96;
    var writer = Writer.init(std.testing.allocator);
    defer writer.deinit();
    var expected: [count]Record = undefined;
    var keys: [count][8]u8 = undefined;
    var definitions: [count][16]u8 = undefined;
    var i: usize = count;
    while (i > 0) {
        i -= 1;
        const key = std.fmt.bufPrint(&keys[i], "k{d:0>6}", .{i}) catch unreachable;
        const definition = std.fmt.bufPrint(&definitions[i], "value-{d:0>6}", .{i}) catch unreachable;
        expected[i] = .{ .id = 10_000 + i, .key = key, .definition = definition };
        try writer.add(expected[i]);
    }
    const bytes = try writer.build();
    defer std.testing.allocator.free(bytes);
    var reader = try Reader.open(bytes);
    var ids: [count]u64 = undefined;
    for (expected) |record| {
        try std.testing.expectEqual(@as(usize, 1), try reader.lookupExact(record.key, ids[0..]));
        try std.testing.expectEqual(record.id, ids[0]);
    }
    try std.testing.expectEqual(@as(usize, count), try reader.lookupPrefix("k", ids[0..count]));
    for (ids[0..count], 0..) |id, index| try std.testing.expectEqual(@as(u64, 10_000 + index), id);
}

test "restart index bounds key work and agrees with a reference scan" {
    const count = 256;
    var writer = Writer.init(std.testing.allocator);
    defer writer.deinit();
    var records: [count]Record = undefined;
    var keys: [count][16]u8 = undefined;
    var definitions: [count][16]u8 = undefined;
    var i: usize = count;
    while (i > 0) {
        i -= 1;
        const key = std.fmt.bufPrint(&keys[i], "word-{d:0>4}", .{i}) catch unreachable;
        const definition = std.fmt.bufPrint(&definitions[i], "value-{d:0>4}", .{i}) catch unreachable;
        records[i] = .{ .id = 50_000 + i, .key = key, .definition = definition };
        try writer.add(records[i]);
    }
    const bytes = try writer.build();
    defer std.testing.allocator.free(bytes);
    var reader = try Reader.open(bytes);
    var expected: [count]u64 = undefined;
    var actual: [count]u64 = undefined;

    reader.resetLookupMetrics();
    const exact_count = try reader.lookupExact("word-0128", actual[0..]);
    try std.testing.expectEqual(@as(usize, 1), exact_count);
    try std.testing.expectEqual(@as(u64, 50_128), actual[0]);
    // Five binary-search probes plus one bounded restart interval and the
    // returned record are enough for this 256-key snapshot.  The counter is
    // the evidence; this assertion intentionally makes no timing claim.
    try std.testing.expect(reader.keyRecordsExamined() < count);

    reader.resetLookupMetrics();
    const prefix_count = try reader.lookupPrefix("word-01", actual[0..]);
    const reference_count = referenceLookup(records[0..], "word-01", true, expected[0..]);
    try std.testing.expectEqual(reference_count, prefix_count);
    try std.testing.expectEqualSlices(u64, expected[0..reference_count], actual[0..prefix_count]);
    try std.testing.expect(reader.keyRecordsExamined() < count);
    try std.testing.expectEqual(@as(u64, 0), reader.payloadReadCount());

    const queries = [_][]const u8{ "word-0000", "word-0008", "word-0007", "word-0255", "word-0256", "word-01" };
    const modes = [_]bool{ false, false, false, false, false, true };
    for (queries, modes) |query_key, is_prefix| {
        const got = if (is_prefix)
            try reader.lookupPrefix(query_key, actual[0..])
        else
            try reader.lookupExact(query_key, actual[0..]);
        const want = referenceLookup(records[0..], query_key, is_prefix, expected[0..]);
        try std.testing.expectEqual(want, got);
        try std.testing.expectEqualSlices(u64, expected[0..want], actual[0..got]);
    }
}

test "restart index handles Unicode byte prefixes and malformed tables" {
    var writer = Writer.init(std.testing.allocator);
    defer writer.deinit();
    const entries = [_]Record{
        .{ .id = 1, .key = "éclair", .definition = "one" },
        .{ .id = 2, .key = "école", .definition = "two" },
        .{ .id = 3, .key = "êta", .definition = "three" },
        .{ .id = 4, .key = "zeta", .definition = "four" },
    };
    for (entries) |entry| try writer.add(entry);
    const bytes = try writer.build();
    defer std.testing.allocator.free(bytes);
    var reader = try Reader.open(bytes);
    var ids: [8]u64 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try reader.lookupPrefix("é", ids[0..]));
    try std.testing.expectEqual(@as(u64, 1), ids[0]);
    try std.testing.expectEqual(@as(u64, 2), ids[1]);
    try std.testing.expectEqual(@as(usize, 0), try reader.lookupPrefix("ë", ids[0..]));
    try std.testing.expectEqual(@as(usize, 1), try reader.lookupExact("éclair", ids[0..]));
    try std.testing.expectEqual(@as(u64, 1), ids[0]);
    try std.testing.expectEqual(@as(u64, 0), reader.payloadReadCount());

    const damaged = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(damaged);
    const key_section = try mutableSection(damaged, 1);
    const table_offset = try toUsize(try readU64(key_section, 8));
    // The first restart must point at the first record.  Pointing it at the
    // table itself is bounded but invalid and must be rejected before lookup.
    std.mem.writeInt(u64, key_section[table_offset + 16 ..][0..8], table_offset, .little);
    refreshIntegrity(damaged, 1);
    try std.testing.expectError(Error.CorruptSection, Reader.open(damaged));

    const bad_count = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(bad_count);
    const bad_keys = try mutableSection(bad_count, 1);
    const bad_table = try toUsize(try readU64(bad_keys, 8));
    const restart_count = try readU32(bad_keys, bad_table);
    std.mem.writeInt(u32, bad_keys[bad_table..][0..4], restart_count + 1, .little);
    refreshIntegrity(bad_count, 1);
    try std.testing.expectError(Error.CorruptSection, Reader.open(bad_count));
}

fn referenceLookup(records: []Record, needle: []const u8, prefix: bool, out: []u64) usize {
    std.mem.sort(Record, records, {}, lessReferenceRecord);
    var length: usize = 0;
    for (records) |record| {
        const matches = if (prefix) std.mem.startsWith(u8, record.key, needle) else std.mem.eql(u8, record.key, needle);
        if (matches) {
            out[length] = record.id;
            length += 1;
        }
    }
    return length;
}

fn lessReferenceRecord(_: void, a: Record, b: Record) bool {
    const order = std.mem.order(u8, a.key, b.key);
    return order == .lt or (order == .eq and a.id < b.id);
}

fn mutableSection(bytes: []u8, wanted_kind: u32) ![]u8 {
    const directory = try toUsize(try readU64(bytes, 24));
    const length = try toUsize(try readU64(bytes, 32));
    var at = directory;
    const end = try checkedAdd(directory, length);
    while (at < end) : (at += directory_entry_bytes) {
        if (try readU32(bytes, at) == wanted_kind) {
            const offset = try toUsize(try readU64(bytes, at + 8));
            const section_length = try toUsize(try readU64(bytes, at + 16));
            return bytes[offset..try checkedAdd(offset, section_length)];
        }
    }
    return Error.MissingSection;
}

fn refreshIntegrity(bytes: []u8, changed_kind: u32) void {
    const directory = readU64(bytes, 24) catch unreachable;
    const length = readU64(bytes, 32) catch unreachable;
    var at: usize = @intCast(directory);
    const end: usize = @intCast(directory + length);
    while (at < end) : (at += directory_entry_bytes) {
        if (readU32(bytes, at) catch unreachable != changed_kind) continue;
        const offset: usize = @intCast(readU64(bytes, at + 8) catch unreachable);
        const section_length: usize = @intCast(readU64(bytes, at + 16) catch unreachable);
        const digest = checksum(bytes[offset .. offset + section_length]);
        std.mem.writeInt(u64, bytes[at + 40 ..][0..8], digest, .little);
    }
    std.mem.writeInt(u64, bytes[40..48], 0, .little);
    std.mem.writeInt(u64, bytes[40..48], checksumRoot(bytes), .little);
}
