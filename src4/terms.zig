//! Rank-addressed full-text terms and postings for LEX4.
//!
//! A term section is intentionally boring at the wire boundary: the term
//! dictionary is the already-reviewed compact automaton, and every term
//! points at one independently decodable posting container.  This keeps the
//! hot path tiny while letting the builder make an evidence-based choice
//! between delta gaps, run pairs, and a dense bitmap for each term.
//!
//! `bzip3` is a *requestable* cold codec, not a fictional implementation.
//! This module records that it was requested but unavailable and emits raw
//! containers.  A future codec adapter can replace the payload without
//! changing term lookup or the posting API.

const std = @import("std");
const automaton = @import("automaton.zig");
const schema = @import("schema.zig");
const wire = @import("wire.zig");

pub const EntryRank = schema.Rank(.entry);
pub const TermRank = enum(u32) { _ };

pub const Error = automaton.Error || std.mem.Allocator.Error || error{
    EmptyTerm,
    DuplicateTerm,
    InvalidPostingOrder,
    PostingOutOfRange,
    InvalidHeader,
    InvalidDirectory,
    InvalidContainer,
    UnsupportedCodec,
    CodecUnavailable,
    RankOutOfRange,
    Overflow,
};

pub const Codec = enum(u8) {
    raw = 0,
    bzip3 = 1,
};

pub const CodecState = enum(u8) {
    raw = 0,
    requested_unavailable = 1,
    encoded = 2,
};

pub const PostingCodec = enum(u8) {
    gaps = 0,
    runs = 1,
    bitmap = 2,
    /// One-entry containers can share a monotone-ish target stream. The
    /// payload is a zig-zag signed delta from the previous singleton term;
    /// checkpoints retain the preceding target for bounded random access.
    signed_single = 3,
    /// Elias--Fano: packed low bits followed by unary high bits. The entry
    /// universe and posting count are already in the term envelope/directory,
    /// so this payload has no hidden per-list header.
    ef = 4,
};

pub const Options = struct {
    /// Term containers are raw inside this section.  A real bzip3 codec is
    /// supplied by `cold.zig`, which owns the encoded bytes and decode-cost
    /// accounting.  Requesting bzip3 here therefore fails explicitly rather
    /// than pretending a boolean capability flag compressed this payload.
    requested_cold_codec: Codec = .raw,
};

pub const Owned = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

const magic = "L4TP";
// v2 makes the directory codec alphabet explicit: v1 had a four-value
// modulo-4 metadata word and cannot represent EF without ambiguity.
const version: u16 = 2;
const header_size: usize = 64;
const directory_stride: u32 = 64;
const checkpoint_record_size: usize = 12;

const Record = struct {
    term: []u8,
    postings: []EntryRank,
};

const DirectoryRecord = struct {
    offset: u32,
    length: u32,
    count: u32,
    codec: PostingCodec,
    singleton_base: u32 = 0,
};

const Checkpoint = struct {
    payload_offset: u32,
    metadata_offset: u32,
    singleton_base: u32,
};

const Chosen = struct {
    codec: PostingCodec,
    bytes: []u8,
};

fn asU32(value: usize) Error!u32 {
    return std.math.cast(u32, value) orelse error.Overflow;
}

fn spanAdd(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.Overflow;
}

fn mul(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch error.Overflow;
}

fn align8(value: usize) Error!usize {
    const rounded = spanAdd(value, 7) catch return error.Overflow;
    return rounded & ~@as(usize, 7);
}

fn appendVar(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var n = value;
    while (n >= 0x80) : (n >>= 7) try out.append(allocator, @as(u8, @intCast(n & 0x7f)) | 0x80);
    try out.append(allocator, @intCast(n));
}

fn varSize(value: u32) usize {
    var n = value;
    var result: usize = 1;
    while (n >= 0x80) : (n >>= 7) result += 1;
    return result;
}

fn readVar(bytes: []const u8, cursor: *usize, limit: usize) Error!u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        if (cursor.* >= limit) return error.InvalidContainer;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        if (shift == 28 and byte > 0x0f) return error.InvalidContainer;
        result |= @as(u32, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        if (shift == 28) return error.InvalidContainer;
        shift += 7;
    }
}

fn appendVar64(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var n = value;
    while (n >= 0x80) : (n >>= 7) try out.append(allocator, @as(u8, @intCast(n & 0x7f)) | 0x80);
    try out.append(allocator, @intCast(n));
}

fn varSize64(value: u64) usize {
    var n = value;
    var result: usize = 1;
    while (n >= 0x80) : (n >>= 7) result += 1;
    return result;
}

fn readVar64(bytes: []const u8, cursor: *usize, limit: usize) Error!u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (cursor.* >= limit) return error.InvalidContainer;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        if (shift == 63 and byte > 1) return error.InvalidContainer;
        result |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        if (shift == 63) return error.InvalidContainer;
        shift += 7;
    }
}

fn zigzag(delta: i64) u64 {
    return if (delta >= 0) @as(u64, @intCast(delta)) * 2 else @as(u64, @intCast(-(delta + 1))) * 2 + 1;
}

fn unzigzag(encoded: u64, previous: u32) Error!u32 {
    const magnitude = encoded >> 1;
    const prior = @as(i64, @intCast(previous));
    const signed = if (encoded & 1 == 0)
        std.math.add(i64, prior, @as(i64, @intCast(magnitude))) catch return error.InvalidContainer
    else
        std.math.sub(i64, prior, @as(i64, @intCast(magnitude + 1))) catch return error.InvalidContainer;
    if (signed < 0 or signed > std.math.maxInt(u32)) return error.InvalidContainer;
    return @intCast(signed);
}

/// A singleton container is overwhelmingly common in real term indexes. It
/// therefore gets a one-byte metadata code. Other records carry a packed
/// length/codec word, and only non-singletons append count-1; no fixed-width
/// 16-byte row is paid for every term.
fn appendDirectoryMeta(out: *std.ArrayList(u8), allocator: std.mem.Allocator, record: DirectoryRecord) !void {
    // Codes 0..3 have a compact one-byte singleton form. EF (code 4) uses
    // the general word even when a tiny list happens to fit in one byte.
    if (record.length == 1 and record.count == 1 and record.codec != .ef) {
        try out.append(allocator, @intFromEnum(record.codec));
        return;
    }
    const scaled = std.math.mul(u32, record.length - 1, 16) catch return error.Overflow;
    const count_flag: u32 = if (record.count == 1) 0 else 8;
    const word = std.math.add(u32, 4, std.math.add(u32, scaled, @intFromEnum(record.codec) + count_flag) catch return error.Overflow) catch return error.Overflow;
    try appendVar(out, allocator, word);
    if (record.count != 1) try appendVar(out, allocator, record.count - 1);
}

fn readDirectoryMeta(bytes: []const u8, cursor: *usize, limit: usize, payload_offset: u32) Error!DirectoryRecord {
    const word = try readVar(bytes, cursor, limit);
    if (word < 4) return .{ .offset = payload_offset, .length = 1, .count = 1, .codec = @enumFromInt(word) };
    const body = word - 4;
    const codec = body % 8;
    if (codec > @intFromEnum(PostingCodec.ef)) return error.InvalidDirectory;
    const length = std.math.add(u32, body / 16, 1) catch return error.Overflow;
    const count = if (body % 16 < 8) 1 else std.math.add(u32, try readVar(bytes, cursor, limit), 1) catch return error.Overflow;
    return .{ .offset = payload_offset, .length = length, .count = count, .codec = @enumFromInt(codec) };
}

fn directoryMetaSize(length: u32, count: u32, codec: PostingCodec) Error!usize {
    if (length == 1 and count == 1 and codec != .ef) return 1;
    const scaled = std.math.mul(u32, length - 1, 16) catch return error.Overflow;
    const count_flag: u32 = if (count == 1) 0 else 8;
    const word = std.math.add(u32, 4, std.math.add(u32, scaled, @intFromEnum(codec) + count_flag) catch return error.Overflow) catch return error.Overflow;
    return varSize(word) + @as(usize, if (count == 1) 0 else varSize(count - 1));
}

fn encodeSignedSingleton(allocator: std.mem.Allocator, target: EntryRank, previous: u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const current = @intFromEnum(target);
    const delta = @as(i64, @intCast(current)) - @as(i64, @intCast(previous));
    try appendVar64(&out, allocator, zigzag(delta));
    return out.toOwnedSlice(allocator);
}

fn encodeGaps(allocator: std.mem.Allocator, postings: []const EntryRank) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var previous: u32 = 0;
    for (postings, 0..) |rank, index| {
        const value = @intFromEnum(rank);
        const encoded = if (index == 0) std.math.add(u32, value, 1) catch return error.Overflow else std.math.sub(u32, value, previous) catch return error.InvalidPostingOrder;
        try appendVar(&out, allocator, encoded);
        previous = value;
    }
    return out.toOwnedSlice(allocator);
}

fn encodeRuns(allocator: std.mem.Allocator, postings: []const EntryRank) ![]u8 {
    var run_count: usize = 0;
    var index: usize = 0;
    while (index < postings.len) {
        run_count += 1;
        index += 1;
        while (index < postings.len and isSuccessor(postings[index - 1], postings[index])) index += 1;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendVar(&out, allocator, try asU32(run_count));
    index = 0;
    while (index < postings.len) {
        const start = @intFromEnum(postings[index]);
        var end = index + 1;
        while (end < postings.len and isSuccessor(postings[end - 1], postings[end])) end += 1;
        try appendVar(&out, allocator, try std.math.add(u32, start, 1));
        try appendVar(&out, allocator, try asU32(end - index));
        index = end;
    }
    return out.toOwnedSlice(allocator);
}

fn isSuccessor(previous: EntryRank, current: EntryRank) bool {
    const value = @intFromEnum(previous);
    return value != std.math.maxInt(u32) and @intFromEnum(current) == value + 1;
}

fn encodeBitmap(allocator: std.mem.Allocator, entry_count: u32, postings: []const EntryRank) ![]u8 {
    // This is only the payload of a posting container, not another public
    // bitvector implementation.  The directory already supplies its length,
    // count, and codec tag; importing the general rank/select wire header
    // here would spend more bytes than the dense posting itself.
    const length = (try spanAdd(entry_count, 7)) / 8;
    var out = try allocator.alloc(u8, length);
    @memset(out, 0);
    for (postings) |rank| {
        const value = @intFromEnum(rank);
        out[value / 8] |= @as(u8, 1) << @as(u3, @intCast(value % 8));
    }
    return out;
}

/// Choose the canonical low-bit width for Elias--Fano.  With n sorted
/// values in a universe U, floor(log2(U/n)) low bits minimizes the usual
/// low-plus-unary representation.  The result is at most 31 for u32 ranks.
fn efLowBits(entry_count: u32, count: u32) u6 {
    if (count == 0 or entry_count <= count) return 0;
    var ratio: u64 = entry_count;
    ratio /= count;
    var result: u6 = 0;
    while (ratio > 1) : (ratio >>= 1) result += 1;
    return result;
}

fn setBit(bytes: []u8, bit: usize) void {
    bytes[bit / 8] |= @as(u8, 1) << @as(u3, @intCast(bit % 8));
}

fn bitAt(bytes: []const u8, bit: usize) u1 {
    return @intCast((bytes[bit / 8] >> @as(u3, @intCast(bit % 8))) & 1);
}

fn encodeEliasFano(allocator: std.mem.Allocator, entry_count: u32, postings: []const EntryRank) ![]u8 {
    if (postings.len == 0) return error.InvalidContainer;
    const count = try asU32(postings.len);
    const low_width = efLowBits(entry_count, count);
    const low_bits = try mul(postings.len, low_width);
    const last_high: usize = @intCast(@intFromEnum(postings[postings.len - 1]) >> @as(u5, @intCast(low_width)));
    // The unary high stream contains high(last) zeros and one bit per value.
    const high_bits = try spanAdd(last_high, postings.len);
    const total_bits = try spanAdd(low_bits, high_bits);
    const total_bytes = (try spanAdd(total_bits, 7)) / 8;
    const out = try allocator.alloc(u8, total_bytes);
    @memset(out, 0);

    const low_mask: u32 = if (low_width == 0) 0 else (@as(u32, 1) << @as(u5, @intCast(low_width))) - 1;
    for (postings, 0..) |posting, index| {
        const low = @intFromEnum(posting) & low_mask;
        const low_start = try mul(index, low_width);
        for (0..@as(usize, low_width)) |bit| {
            if ((low & (@as(u32, 1) << @as(u5, @intCast(bit)))) != 0) setBit(out, low_start + bit);
        }
    }

    var zeros: usize = 0;
    for (postings, 0..) |posting, index| {
        const high: usize = @intCast(@intFromEnum(posting) >> @as(u5, @intCast(low_width)));
        // The i-th one is at high(i)+i; zeros counts only zero bits before
        // the current one, so the index term is part of the canonical EF
        // unary stream.
        const desired_zeros = try spanAdd(high, index);
        while (zeros < desired_zeros) : (zeros += 1) {}
        setBit(out, low_bits + zeros);
        zeros += 1;
    }
    return out;
}

fn chooseEncoding(allocator: std.mem.Allocator, entry_count: u32, postings: []const EntryRank) !Chosen {
    var candidates: [4][]u8 = undefined;
    candidates[0] = try encodeGaps(allocator, postings);
    errdefer allocator.free(candidates[0]);
    candidates[1] = try encodeRuns(allocator, postings);
    errdefer allocator.free(candidates[1]);
    candidates[2] = try encodeBitmap(allocator, entry_count, postings);
    errdefer allocator.free(candidates[2]);
    candidates[3] = try encodeEliasFano(allocator, entry_count, postings);
    errdefer allocator.free(candidates[3]);

    var best: usize = 0;
    const codecs = [_]PostingCodec{ .gaps, .runs, .bitmap, .ef };
    // Stable tie-breaking favours gaps (small and branch-light), then runs,
    // bitmap, then EF. The comparison includes exact directory metadata
    // bytes, not only payload bytes.
    for (1..candidates.len) |candidate| {
        const candidate_meta = try directoryMetaSize(try asU32(candidates[candidate].len), try asU32(postings.len), codecs[candidate]);
        const best_meta = try directoryMetaSize(try asU32(candidates[best].len), try asU32(postings.len), codecs[best]);
        const candidate_total = try spanAdd(candidates[candidate].len, candidate_meta);
        const best_total = try spanAdd(candidates[best].len, best_meta);
        if (candidate_total < best_total) best = candidate;
    }
    for (candidates, 0..) |bytes, index| if (index != best) allocator.free(bytes);
    return .{ .codec = codecs[best], .bytes = candidates[best] };
}

fn efLowAt(payload: []const u8, index: usize, low_width: u6) Error!u32 {
    const low_bits = std.math.mul(usize, index, low_width) catch return error.InvalidContainer;
    const end = std.math.add(usize, low_bits, low_width) catch return error.InvalidContainer;
    const bit_limit = std.math.mul(usize, payload.len, 8) catch return error.InvalidContainer;
    if (end > bit_limit) return error.InvalidContainer;
    var value: u32 = 0;
    for (0..@as(usize, low_width)) |bit| {
        if (bitAt(payload, low_bits + bit) != 0) value |= @as(u32, 1) << @as(u5, @intCast(bit));
    }
    return value;
}

pub const Builder = struct {
    allocator: std.mem.Allocator,
    entry_count: u32,
    options: Options = .{},
    records: std.ArrayList(Record) = .empty,

    pub fn init(allocator: std.mem.Allocator, entry_count: u32) Builder {
        return .{ .allocator = allocator, .entry_count = entry_count };
    }

    pub fn withOptions(allocator: std.mem.Allocator, entry_count: u32, options: Options) Builder {
        return .{ .allocator = allocator, .entry_count = entry_count, .options = options };
    }

    pub fn deinit(self: *Builder) void {
        for (self.records.items) |record| {
            self.allocator.free(record.term);
            self.allocator.free(record.postings);
        }
        self.records.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *Builder, term: []const u8, postings: []const EntryRank) !void {
        if (term.len == 0) return error.EmptyTerm;
        var previous: ?u32 = null;
        for (postings) |rank| {
            const value = @intFromEnum(rank);
            if (value >= self.entry_count) return error.PostingOutOfRange;
            if (previous) |last| if (value <= last) return error.InvalidPostingOrder;
            previous = value;
        }
        if (postings.len == 0) return error.InvalidContainer;
        const key = try self.allocator.dupe(u8, term);
        errdefer self.allocator.free(key);
        const copied = try self.allocator.dupe(EntryRank, postings);
        errdefer self.allocator.free(copied);
        try self.records.append(self.allocator, .{ .term = key, .postings = copied });
    }

    fn lessThan(_: void, left: Record, right: Record) bool {
        return std.mem.lessThan(u8, left.term, right.term);
    }

    pub fn finish(self: *Builder) !Owned {
        if (self.records.items.len == 0) return error.InvalidDirectory;
        if (self.options.requested_cold_codec != .raw) return error.CodecUnavailable;
        std.sort.heap(Record, self.records.items, {}, lessThan);
        for (self.records.items, 0..) |record, index| if (index != 0 and std.mem.eql(u8, record.term, self.records.items[index - 1].term)) return error.DuplicateTerm;

        var dictionary_builder = automaton.Builder.init(self.allocator);
        defer dictionary_builder.deinit();
        for (self.records.items) |record| try dictionary_builder.addEntry(record.term, 1);
        var dictionary = try dictionary_builder.finish();
        defer dictionary.deinit();

        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        var metadata: std.ArrayList(u8) = .empty;
        defer metadata.deinit(self.allocator);
        const checkpoint_count = (self.records.items.len - 1) / directory_stride + 1;
        var checkpoints = try self.allocator.alloc(Checkpoint, checkpoint_count);
        defer self.allocator.free(checkpoints);
        // Measure the complete singleton representation before selecting it.
        // Signed deltas are only worthwhile when the corpus's *ordered* term
        // targets have enough local monotonicity to pay for the occasional
        // backwards jump.  This is a real byte decision, not a density claim.
        var normal_single_bytes: usize = 0;
        var signed_single_bytes: usize = 0;
        var prior_single: u32 = 0;
        for (self.records.items) |record| {
            if (record.postings.len != 1) continue;
            const chosen = try chooseEncoding(self.allocator, self.entry_count, record.postings);
            defer self.allocator.free(chosen.bytes);
            normal_single_bytes = try spanAdd(normal_single_bytes, chosen.bytes.len);
            normal_single_bytes = try spanAdd(normal_single_bytes, try directoryMetaSize(try asU32(chosen.bytes.len), 1, chosen.codec));
            const target = @intFromEnum(record.postings[0]);
            const delta = @as(i64, @intCast(target)) - @as(i64, @intCast(prior_single));
            const signed_len = varSize64(zigzag(delta));
            signed_single_bytes = try spanAdd(signed_single_bytes, signed_len);
            signed_single_bytes = try spanAdd(signed_single_bytes, try directoryMetaSize(try asU32(signed_len), 1, .signed_single));
            prior_single = target;
        }
        const use_signed_singletons = signed_single_bytes < normal_single_bytes;
        prior_single = 0;
        for (self.records.items, 0..) |record, index| {
            if (index % directory_stride == 0) checkpoints[index / directory_stride] = .{ .payload_offset = try asU32(payload.items.len), .metadata_offset = try asU32(metadata.items.len), .singleton_base = prior_single };
            const use_signed = use_signed_singletons and record.postings.len == 1;
            const chosen = if (use_signed)
                Chosen{ .codec = PostingCodec.signed_single, .bytes = try encodeSignedSingleton(self.allocator, record.postings[0], prior_single) }
            else
                try chooseEncoding(self.allocator, self.entry_count, record.postings);
            defer self.allocator.free(chosen.bytes);
            const offset = try asU32(payload.items.len);
            try payload.appendSlice(self.allocator, chosen.bytes);
            try appendDirectoryMeta(&metadata, self.allocator, .{ .offset = offset, .length = try asU32(chosen.bytes.len), .count = try asU32(record.postings.len), .codec = chosen.codec });
            if (use_signed) prior_single = @intFromEnum(record.postings[0]);
        }

        const dict_offset = header_size;
        const directory_offset = try align8(try spanAdd(dict_offset, dictionary.bytes.len));
        const checkpoint_bytes = try mul(checkpoint_count, checkpoint_record_size);
        const directory_len = try spanAdd(checkpoint_bytes, metadata.items.len);
        const payload_offset = try align8(try spanAdd(directory_offset, directory_len));
        const total_len = try spanAdd(payload_offset, payload.items.len);
        if (total_len > std.math.maxInt(u32)) return error.Overflow;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.appendNTimes(self.allocator, 0, total_len);
        std.mem.copyForwards(u8, out.items[dict_offset..][0..dictionary.bytes.len], dictionary.bytes);
        for (checkpoints, 0..) |checkpoint, index| {
            const at = directory_offset + index * checkpoint_record_size;
            std.mem.writeInt(u32, out.items[at..][0..4], checkpoint.payload_offset, .little);
            std.mem.writeInt(u32, out.items[at + 4 ..][0..4], checkpoint.metadata_offset, .little);
            std.mem.writeInt(u32, out.items[at + 8 ..][0..4], checkpoint.singleton_base, .little);
        }
        std.mem.copyForwards(u8, out.items[directory_offset + checkpoint_bytes ..][0..metadata.items.len], metadata.items);
        std.mem.copyForwards(u8, out.items[payload_offset..][0..payload.items.len], payload.items);

        const requested = self.options.requested_cold_codec;
        const state: CodecState = .raw;
        std.mem.copyForwards(u8, out.items[0..4], magic);
        std.mem.writeInt(u16, out.items[4..6], version, .little);
        std.mem.writeInt(u16, out.items[6..8], @intFromEnum(state), .little);
        std.mem.writeInt(u32, out.items[8..12], self.entry_count, .little);
        std.mem.writeInt(u32, out.items[12..16], try asU32(self.records.items.len), .little);
        std.mem.writeInt(u32, out.items[16..20], try asU32(dict_offset), .little);
        std.mem.writeInt(u32, out.items[20..24], try asU32(dictionary.bytes.len), .little);
        std.mem.writeInt(u32, out.items[24..28], try asU32(directory_offset), .little);
        std.mem.writeInt(u32, out.items[28..32], try asU32(directory_len), .little);
        std.mem.writeInt(u32, out.items[32..36], try asU32(payload_offset), .little);
        std.mem.writeInt(u32, out.items[36..40], try asU32(payload.items.len), .little);
        std.mem.writeInt(u32, out.items[40..44], try asU32(total_len), .little);
        out.items[44] = @intFromEnum(requested);
        out.items[45] = @intFromEnum(state);
        std.mem.writeInt(u16, out.items[46..48], @intCast(directory_stride), .little);
        std.mem.writeInt(u32, out.items[48..52], try asU32(checkpoint_count), .little);
        // bytes 46..63 are reserved and zero by construction.
        return .{ .bytes = try out.toOwnedSlice(self.allocator), .allocator = self.allocator };
    }
};

pub const PostingList = struct {
    view: *const View,
    record: DirectoryRecord,
    payload: []const u8,

    pub fn len(self: PostingList) u32 {
        return self.record.count;
    }

    pub fn codec(self: PostingList) PostingCodec {
        return self.record.codec;
    }

    pub fn contains(self: PostingList, rank: EntryRank) !bool {
        const wanted = @intFromEnum(rank);
        if (wanted >= self.view.entry_count) return false;
        switch (self.record.codec) {
            .bitmap => {
                if (wanted / 8 >= self.payload.len) return error.InvalidContainer;
                return (self.payload[wanted / 8] & (@as(u8, 1) << @as(u3, @intCast(wanted % 8)))) != 0;
            },
            .gaps => {
                var cursor: usize = 0;
                var previous: u32 = 0;
                for (0..self.record.count) |index| {
                    const encoded = try readVar(self.payload, &cursor, self.payload.len);
                    const value = if (index == 0) std.math.sub(u32, encoded, 1) catch return error.InvalidContainer else std.math.add(u32, previous, encoded) catch return error.InvalidContainer;
                    if (value == wanted) return true;
                    if (value > wanted) return false;
                    previous = value;
                }
                return false;
            },
            .signed_single => {
                if (self.record.count != 1) return error.InvalidContainer;
                var cursor: usize = 0;
                const encoded = try readVar64(self.payload, &cursor, self.payload.len);
                if (cursor != self.payload.len) return error.InvalidContainer;
                return try unzigzag(encoded, self.record.singleton_base) == wanted;
            },
            .ef => {
                const low_width = efLowBits(self.view.entry_count, self.record.count);
                const low_bits = std.math.mul(usize, self.record.count, low_width) catch return error.InvalidContainer;
                const bit_limit = std.math.mul(usize, self.payload.len, 8) catch return error.InvalidContainer;
                var high_cursor = low_bits;
                var zeros: usize = 0;
                for (0..self.record.count) |index| {
                    while (high_cursor < bit_limit and bitAt(self.payload, high_cursor) == 0) : (high_cursor += 1) zeros += 1;
                    if (high_cursor >= bit_limit) return error.InvalidContainer;
                    const low = try efLowAt(self.payload, index, low_width);
                    const value64 = (@as(u64, @intCast(zeros)) << @as(u6, @intCast(low_width))) | low;
                    if (value64 >= self.view.entry_count) return error.InvalidContainer;
                    const value: u32 = @intCast(value64);
                    if (value == wanted) return true;
                    if (value > wanted) return false;
                    high_cursor += 1;
                }
                return false;
            },
            .runs => {
                var cursor: usize = 0;
                const run_count = try readVar(self.payload, &cursor, self.payload.len);
                for (0..run_count) |_| {
                    const start = std.math.sub(u32, try readVar(self.payload, &cursor, self.payload.len), 1) catch return error.InvalidContainer;
                    const length = try readVar(self.payload, &cursor, self.payload.len);
                    if (wanted < start) return false;
                    if (wanted - start < length) return true;
                }
                return false;
            },
        }
    }

    pub const Iterator = struct {
        list: PostingList,
        index: u32 = 0,
        cursor: usize = 0,
        previous: u32 = 0,
        run_remaining: u32 = 0,
        run_value: u32 = 0,
        run_count: u32 = 0,
        ef_low_width: u6 = 0,
        ef_low_bits: usize = 0,
        ef_high_cursor: usize = 0,
        ef_zeros: usize = 0,

        pub fn next(self: *Iterator) !?EntryRank {
            if (self.index >= self.list.record.count) return null;
            const value: u32 = switch (self.list.record.codec) {
                .bitmap => blk: {
                    const total = self.list.view.entry_count;
                    while (self.cursor < total) : (self.cursor += 1) {
                        const candidate = self.cursor;
                        if (candidate / 8 >= self.list.payload.len) return error.InvalidContainer;
                        if ((self.list.payload[candidate / 8] & (@as(u8, 1) << @as(u3, @intCast(candidate % 8)))) != 0) {
                            self.cursor += 1;
                            break :blk @as(u32, @intCast(candidate));
                        }
                    }
                    return error.InvalidContainer;
                },
                .gaps => blk: {
                    const encoded = try readVar(self.list.payload, &self.cursor, self.list.payload.len);
                    const decoded = if (self.index == 0) std.math.sub(u32, encoded, 1) catch return error.InvalidContainer else std.math.add(u32, self.previous, encoded) catch return error.InvalidContainer;
                    self.previous = decoded;
                    break :blk decoded;
                },
                .signed_single => blk: {
                    if (self.index != 0) return error.InvalidContainer;
                    const encoded = try readVar64(self.list.payload, &self.cursor, self.list.payload.len);
                    const decoded = try unzigzag(encoded, self.previous);
                    self.previous = decoded;
                    break :blk decoded;
                },
                .ef => blk: {
                    const bit_limit = std.math.mul(usize, self.list.payload.len, 8) catch return error.InvalidContainer;
                    while (self.ef_high_cursor < bit_limit and bitAt(self.list.payload, self.ef_high_cursor) == 0) : (self.ef_high_cursor += 1) self.ef_zeros += 1;
                    if (self.ef_high_cursor >= bit_limit) return error.InvalidContainer;
                    const low = try efLowAt(self.list.payload, self.index, self.ef_low_width);
                    const value64 = (@as(u64, @intCast(self.ef_zeros)) << @as(u6, @intCast(self.ef_low_width))) | low;
                    if (value64 >= self.list.view.entry_count) return error.InvalidContainer;
                    const decoded: u32 = @intCast(value64);
                    if (self.index != 0 and decoded <= self.previous) return error.InvalidContainer;
                    self.ef_high_cursor += 1;
                    self.previous = decoded;
                    if (self.index + 1 == self.list.record.count) {
                        while (self.ef_high_cursor < bit_limit) : (self.ef_high_cursor += 1) {
                            if (bitAt(self.list.payload, self.ef_high_cursor) != 0) return error.InvalidContainer;
                        }
                        // EF verification treats cursor as a bit offset so
                        // the final byte's zero padding is checked exactly.
                        self.cursor = self.ef_high_cursor;
                    }
                    break :blk decoded;
                },
                .runs => blk: {
                    if (self.run_remaining == 0) {
                        if (self.run_count == 0) self.run_count = try readVar(self.list.payload, &self.cursor, self.list.payload.len);
                        if (self.run_count == 0) return error.InvalidContainer;
                        self.run_value = std.math.sub(u32, try readVar(self.list.payload, &self.cursor, self.list.payload.len), 1) catch return error.InvalidContainer;
                        self.run_remaining = try readVar(self.list.payload, &self.cursor, self.list.payload.len);
                        if (self.run_remaining == 0) return error.InvalidContainer;
                        self.run_count -= 1;
                    }
                    const result = self.run_value;
                    if (self.run_remaining > 1) self.run_value += 1;
                    self.run_remaining -= 1;
                    break :blk result;
                },
            };
            if (value >= self.list.view.entry_count) return error.InvalidContainer;
            self.index += 1;
            return @enumFromInt(value);
        }
    };

    pub fn iterator(self: PostingList) Iterator {
        const low_width = if (self.record.codec == .ef) efLowBits(self.view.entry_count, self.record.count) else 0;
        const low_bits = if (self.record.codec == .ef) (std.math.mul(usize, self.record.count, low_width) catch 0) else 0;
        return .{ .list = self, .previous = self.record.singleton_base, .ef_low_width = low_width, .ef_low_bits = low_bits, .ef_high_cursor = low_bits };
    }
};

pub const TermHit = struct {
    rank: TermRank,
    postings: PostingList,
};

pub const Ledger = struct {
    header: usize,
    dictionary: usize,
    dictionary_padding: usize,
    checkpoint: usize,
    metadata: usize,
    directory_padding: usize,
    payload: usize,
    total: usize,
};

pub const View = struct {
    bytes: []const u8,
    entry_count: u32,
    term_count: u32,
    requested_codec: Codec,
    codec_state: CodecState,
    dictionary: automaton.View,
    directory_offset: usize,
    directory_length: usize,
    checkpoint_count: u32,
    directory_stride: u32,
    metadata_offset: usize,
    payload_offset: usize,
    payload_length: usize,

    fn u32At(bytes: []const u8, offset: usize) Error!u32 {
        if (offset > bytes.len or bytes.len - offset < 4) return error.InvalidHeader;
        return std.mem.readInt(u32, bytes[offset..][0..4], .little);
    }

    pub fn open(bytes: []const u8) !View {
        if (bytes.len < header_size) return error.Truncated;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.InvalidHeader;
        if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.UnsupportedVersion;
        const state_raw = std.mem.readInt(u16, bytes[6..8], .little);
        if (state_raw > @intFromEnum(CodecState.encoded)) return error.InvalidHeader;
        const state: CodecState = @enumFromInt(state_raw);
        const entry_count = try u32At(bytes, 8);
        const term_count = try u32At(bytes, 12);
        const dictionary_offset = try u32At(bytes, 16);
        const dictionary_length = try u32At(bytes, 20);
        const directory_offset = try u32At(bytes, 24);
        const directory_length = try u32At(bytes, 28);
        const payload_offset = try u32At(bytes, 32);
        const payload_length = try u32At(bytes, 36);
        const total_length = try u32At(bytes, 40);
        const stride = std.mem.readInt(u16, bytes[46..48], .little);
        const checkpoint_count = try u32At(bytes, 48);
        if (total_length != bytes.len or dictionary_offset != header_size) return error.InvalidHeader;
        if (bytes[44] > @intFromEnum(Codec.bzip3) or bytes[45] != state_raw) return error.InvalidHeader;
        if (stride == 0 or stride != directory_stride or term_count == 0) return error.InvalidDirectory;
        const expected_checkpoints = (term_count - 1) / stride + 1;
        if (checkpoint_count != expected_checkpoints) return error.InvalidDirectory;
        const checkpoint_bytes = try mul(checkpoint_count, checkpoint_record_size);
        if (directory_length < checkpoint_bytes) return error.InvalidDirectory;
        const dictionary_end = try spanAdd(dictionary_offset, dictionary_length);
        if (directory_offset != try align8(dictionary_end)) return error.InvalidDirectory;
        if (payload_offset != try align8(try spanAdd(directory_offset, directory_length))) return error.InvalidDirectory;
        if (dictionary_end > bytes.len or directory_offset > bytes.len or payload_offset > bytes.len) return error.Truncated;
        if (try spanAdd(payload_offset, payload_length) != bytes.len) return error.InvalidDirectory;
        const dictionary = try automaton.View.open(bytes[dictionary_offset..dictionary_end]);
        if (dictionary.entry_count != term_count) return error.InvalidDirectory;
        return .{ .bytes = bytes, .entry_count = entry_count, .term_count = term_count, .requested_codec = @enumFromInt(bytes[44]), .codec_state = state, .dictionary = dictionary, .directory_offset = directory_offset, .directory_length = directory_length, .checkpoint_count = checkpoint_count, .directory_stride = stride, .metadata_offset = try spanAdd(directory_offset, checkpoint_bytes), .payload_offset = payload_offset, .payload_length = payload_length };
    }

    pub fn verify(self: *const View, allocator: std.mem.Allocator) !void {
        if ((self.requested_codec == .raw and self.codec_state != .raw) or
            (self.requested_codec == .bzip3 and self.codec_state != .requested_unavailable)) return error.UnsupportedCodec;
        try self.dictionary.verifyWithAllocator(allocator);
        var payload_cursor: u32 = 0;
        var metadata_cursor = self.metadata_offset;
        var previous_single: u32 = 0;
        const metadata_end = self.directory_offset + self.directory_length;
        for (0..self.term_count) |index| {
            if (index % self.directory_stride == 0) {
                const checkpoint = index / self.directory_stride;
                const at = self.directory_offset + checkpoint * checkpoint_record_size;
                const expected_payload = std.mem.readInt(u32, self.bytes[at..][0..4], .little);
                const expected_metadata = std.mem.readInt(u32, self.bytes[at + 4 ..][0..4], .little);
                const expected_single = std.mem.readInt(u32, self.bytes[at + 8 ..][0..4], .little);
                if (expected_payload != payload_cursor or expected_metadata != metadata_cursor - self.metadata_offset or expected_single != previous_single) return error.InvalidDirectory;
            }
            var record = try readDirectoryMeta(self.bytes, &metadata_cursor, metadata_end, payload_cursor);
            record.singleton_base = previous_single;
            if (record.codec == .signed_single and record.count != 1) return error.InvalidContainer;
            const end = try spanAdd(record.offset, record.length);
            if (end > self.payload_length or record.length == 0) return error.InvalidDirectory;
            const payload = self.bytes[self.payload_offset + record.offset ..][0..record.length];
            if (record.codec == .bitmap) {
                const expected = (try spanAdd(self.entry_count, 7)) / 8;
                if (record.length != expected) return error.InvalidContainer;
            }
            var iterator = (PostingList{ .view = self, .record = record, .payload = payload }).iterator();
            var previous: ?u32 = null;
            var seen: u32 = 0;
            while (try iterator.next()) |rank| {
                const value = @intFromEnum(rank);
                if (previous) |prior| if (value <= prior) return error.InvalidContainer;
                previous = value;
                seen += 1;
            }
            if (seen != record.count) return error.InvalidContainer;
            if (record.codec == .bitmap) {
                var popcount: u32 = 0;
                for (payload) |byte| popcount += @popCount(byte);
                if (popcount != record.count) return error.InvalidContainer;
                const unused = self.entry_count % 8;
                if (unused != 0 and payload.len != 0 and payload[payload.len - 1] & (~((@as(u8, 1) << @as(u3, @intCast(unused))) - 1)) != 0) return error.InvalidContainer;
            } else if (record.codec == .ef) {
                const bit_limit = try mul(payload.len, 8);
                if (iterator.ef_high_cursor > bit_limit) return error.InvalidContainer;
                for (iterator.ef_high_cursor..bit_limit) |bit| if (bitAt(payload, bit) != 0) return error.InvalidContainer;
            } else if (iterator.cursor != payload.len) {
                return error.InvalidContainer;
            }
            if (record.codec == .signed_single) previous_single = iterator.previous;
            payload_cursor = try asU32(end);
        }
        if (metadata_cursor != metadata_end or payload_cursor != self.payload_length) return error.InvalidDirectory;
    }

    fn directory(self: *const View, rank: TermRank) Error!DirectoryRecord {
        const index = @intFromEnum(rank);
        if (index >= self.term_count) return error.RankOutOfRange;
        const checkpoint = index / self.directory_stride;
        const checkpoint_at = self.directory_offset + @as(usize, @intCast(checkpoint)) * checkpoint_record_size;
        var payload_cursor = std.mem.readInt(u32, self.bytes[checkpoint_at..][0..4], .little);
        const metadata_relative = std.mem.readInt(u32, self.bytes[checkpoint_at + 4 ..][0..4], .little);
        var previous_single = std.mem.readInt(u32, self.bytes[checkpoint_at + 8 ..][0..4], .little);
        const checkpoint_bytes = try mul(self.checkpoint_count, checkpoint_record_size);
        if (metadata_relative > self.directory_length - checkpoint_bytes) return error.InvalidDirectory;
        var metadata_cursor = try spanAdd(self.metadata_offset, metadata_relative);
        const metadata_end = self.directory_offset + self.directory_length;
        if (metadata_cursor > metadata_end) return error.InvalidDirectory;
        var current = checkpoint * self.directory_stride;
        while (current <= index) : (current += 1) {
            var record = try readDirectoryMeta(self.bytes, &metadata_cursor, metadata_end, payload_cursor);
            record.singleton_base = previous_single;
            if (record.codec == .signed_single) {
                if (record.count != 1) return error.InvalidContainer;
                const end = try spanAdd(record.offset, record.length);
                if (end > self.payload_length) return error.InvalidDirectory;
                var iterator = (PostingList{ .view = self, .record = record, .payload = self.bytes[self.payload_offset + record.offset ..][0..record.length] }).iterator();
                _ = (try iterator.next()) orelse return error.InvalidContainer;
                previous_single = iterator.previous;
            }
            if (current == index) return record;
            payload_cursor = try asU32(try spanAdd(payload_cursor, record.length));
        }
        return error.InvalidDirectory;
    }

    pub fn term(self: *const View, rank: TermRank, scratch: []u8) !?[]const u8 {
        if (@intFromEnum(rank) >= self.term_count) return null;
        return (try self.dictionary.select(@intFromEnum(rank), scratch)).?.key;
    }

    pub fn exact(self: *const View, key: []const u8) !?TermHit {
        const hit = (try self.dictionary.exact(key)) orelse return null;
        const range = hit.entry_range orelse return null;
        if (range.len() != 1) return error.InvalidDirectory;
        const rank: TermRank = @enumFromInt(@intFromEnum(range.lo));
        const record = try self.directory(rank);
        const end = try spanAdd(record.offset, record.length);
        if (end > self.payload_length) return error.InvalidDirectory;
        return .{ .rank = rank, .postings = .{ .view = self, .record = record, .payload = self.bytes[self.payload_offset + record.offset ..][0..record.length] } };
    }

    pub fn prefix(self: *const View, key: []const u8) !?struct { lo: TermRank, hi: TermRank } {
        const range = (try self.dictionary.prefixInterval(key)) orelse return null;
        return .{ .lo = @enumFromInt(@intFromEnum(range.range.lo)), .hi = @enumFromInt(@intFromEnum(range.range.hi)) };
    }

    pub fn codecAvailability(self: *const View) struct { requested: Codec, state: CodecState } {
        return .{ .requested = self.requested_codec, .state = self.codec_state };
    }

    pub fn ledger(self: *const View) Ledger {
        const checkpoint = @as(usize, self.checkpoint_count) * checkpoint_record_size;
        const dictionary_end = header_size + self.dictionary.len();
        const dictionary_padding = self.directory_offset - dictionary_end;
        const directory_end = self.directory_offset + self.directory_length;
        const directory_padding = self.payload_offset - directory_end;
        return .{
            .header = header_size,
            .dictionary = self.dictionary.len(),
            .dictionary_padding = dictionary_padding,
            .checkpoint = checkpoint,
            .metadata = self.directory_length - checkpoint,
            .directory_padding = directory_padding,
            .payload = self.payload_length,
            .total = self.bytes.len,
        };
    }
};

pub const SliceSource = struct {
    data: []const u8,

    pub fn len(self: *const SliceSource) usize {
        return self.data.len;
    }

    pub fn bytes(self: *const SliceSource, offset: usize, length: usize) ![]const u8 {
        if (offset > self.data.len or length > self.data.len - offset) return error.Truncated;
        return self.data[offset..][0..length];
    }
};

fn sourceBytes(comptime Source: type, source: *const Source, offset: usize, length: usize) anyerror![]const u8 {
    if (@hasDecl(Source, "bytes")) return source.bytes(offset, length);
    if (@hasDecl(Source, "read")) return source.read(offset, length);
    @compileError("LEX4 source must provide bytes(offset, length) or read(offset, length)");
}

fn sourceLength(comptime Source: type, source: *const Source) usize {
    if (@hasDecl(Source, "len")) return source.len();
    @compileError("LEX4 source must provide len()");
}

/// A posting list whose directory and payload remain on the caller's source.
/// Iteration is deliberately a source operation: a mapped snapshot authenticates
/// only the payload bytes touched by this list, and a paged source can keep its
/// resident working set bounded by its own page cache.
pub fn SourcePostingList(comptime Source: type) type {
    return struct {
        const Self = @This();
        source: *const Source,
        payload_offset: usize,
        payload_length: usize,
        entry_count: u32,
        count: u32,
        posting_codec: PostingCodec,
        singleton_base: u32,

        pub fn len(self: Self) u32 {
            return self.count;
        }
        pub fn codec(self: Self) PostingCodec {
            return self.posting_codec;
        }

        fn byte(self: Self, cursor: usize) anyerror!u8 {
            if (cursor >= self.payload_length) return error.InvalidContainer;
            return (try sourceBytes(Source, self.source, self.payload_offset + cursor, 1))[0];
        }

        fn readVar(self: Self, cursor: *usize) anyerror!u32 {
            var result: u32 = 0;
            var shift: u5 = 0;
            while (true) {
                const value = try self.byte(cursor.*);
                cursor.* += 1;
                if (shift == 28 and value > 0x0f) return error.InvalidContainer;
                result |= @as(u32, value & 0x7f) << shift;
                if (value & 0x80 == 0) return result;
                if (shift == 28) return error.InvalidContainer;
                shift += 7;
            }
        }

        fn bit(self: Self, position: usize) anyerror!u1 {
            const value = try self.byte(position / 8);
            return @intCast((value >> @as(u3, @intCast(position % 8))) & 1);
        }

        pub const Iterator = struct {
            list: Self,
            index: u32 = 0,
            cursor: usize = 0,
            previous: u32 = 0,
            run_remaining: u32 = 0,
            run_value: u32 = 0,
            run_count: u32 = 0,
            ef_low_width: u6 = 0,
            ef_low_bits: usize = 0,
            ef_high_cursor: usize = 0,
            ef_zeros: usize = 0,

            fn efLow(self: *const @This(), index: u32) anyerror!u64 {
                if (self.ef_low_width == 0) return 0;
                var value: u64 = 0;
                const start = @as(usize, index) * self.ef_low_width;
                for (0..self.ef_low_width) |bit_index| value |= @as(u64, try self.list.bit(start + bit_index)) << @as(u6, @intCast(bit_index));
                return value;
            }

            pub fn next(self: *@This()) anyerror!?EntryRank {
                if (self.index >= self.list.count) return null;
                const value: u32 = switch (self.list.posting_codec) {
                    .bitmap => blk: {
                        while (self.cursor < self.list.entry_count) : (self.cursor += 1) if ((try self.list.bit(self.cursor)) != 0) {
                            const found = self.cursor;
                            self.cursor += 1;
                            break :blk @intCast(found);
                        };
                        return error.InvalidContainer;
                    },
                    .gaps => blk: {
                        const encoded = try self.list.readVar(&self.cursor);
                        const decoded = if (self.index == 0) std.math.sub(u32, encoded, 1) catch return error.InvalidContainer else std.math.add(u32, self.previous, encoded) catch return error.InvalidContainer;
                        self.previous = decoded;
                        break :blk decoded;
                    },
                    .signed_single => blk: {
                        if (self.index != 0) return error.InvalidContainer;
                        var encoded: u64 = 0;
                        var shift: u6 = 0;
                        while (true) {
                            const encoded_byte = try self.list.byte(self.cursor);
                            self.cursor += 1;
                            encoded |= @as(u64, encoded_byte & 0x7f) << shift;
                            if (encoded_byte & 0x80 == 0) break;
                            if (shift >= 63) return error.InvalidContainer;
                            shift += 7;
                        }
                        const magnitude = encoded >> 1;
                        const delta: i64 = if (encoded & 1 == 0) @intCast(magnitude) else -@as(i64, @intCast(magnitude)) - 1;
                        const candidate = @as(i64, self.previous) + delta;
                        if (candidate < 0 or candidate >= self.list.entry_count) return error.InvalidContainer;
                        self.previous = @intCast(candidate);
                        break :blk self.previous;
                    },
                    .runs => blk: {
                        if (self.run_remaining == 0) {
                            if (self.run_count == 0) self.run_count = try self.list.readVar(&self.cursor);
                            if (self.run_count == 0) return error.InvalidContainer;
                            self.run_value = std.math.sub(u32, try self.list.readVar(&self.cursor), 1) catch return error.InvalidContainer;
                            self.run_remaining = try self.list.readVar(&self.cursor);
                            if (self.run_remaining == 0) return error.InvalidContainer;
                            self.run_count -= 1;
                        }
                        const result = self.run_value;
                        self.run_value +%= @intFromBool(self.run_remaining > 1);
                        self.run_remaining -= 1;
                        break :blk result;
                    },
                    .ef => blk: {
                        const bit_limit = self.list.payload_length * 8;
                        while (self.ef_high_cursor < bit_limit and (try self.list.bit(self.ef_high_cursor)) == 0) : (self.ef_high_cursor += 1) self.ef_zeros += 1;
                        if (self.ef_high_cursor >= bit_limit) return error.InvalidContainer;
                        const low = try self.efLow(self.index);
                        const value64 = (@as(u64, @intCast(self.ef_zeros)) << self.ef_low_width) | low;
                        if (value64 >= self.list.entry_count) return error.InvalidContainer;
                        self.ef_high_cursor += 1;
                        break :blk @intCast(value64);
                    },
                };
                if (value >= self.list.entry_count) return error.InvalidContainer;
                self.index += 1;
                return @enumFromInt(value);
            }
        };

        pub fn iterator(self: Self) Iterator {
            const width = if (self.posting_codec == .ef) efLowBits(self.entry_count, self.count) else 0;
            return .{ .list = self, .previous = self.singleton_base, .ef_low_width = width, .ef_low_bits = @as(usize, self.count) * width, .ef_high_cursor = @as(usize, self.count) * width };
        }

        pub fn contains(self: Self, wanted: EntryRank) anyerror!bool {
            var posting_iterator = self.iterator();
            while (try posting_iterator.next()) |value| {
                if (@intFromEnum(value) == @intFromEnum(wanted)) return true;
                if (@intFromEnum(value) > @intFromEnum(wanted)) return false;
            }
            return false;
        }
    };
}

pub fn SourceView(comptime Source: type) type {
    return struct {
        const Self = @This();
        pub const Posting = SourcePostingList(Source);
        pub const Hit = struct { rank: TermRank, postings: Posting };
        source: Source,
        entry_count: u32,
        term_count: u32,
        requested_codec: Codec,
        codec_state: CodecState,
        dictionary: automaton.ViewFor(wire.Span(Source)),
        directory_offset: usize,
        directory_length: usize,
        checkpoint_count: u32,
        metadata_offset: usize,
        payload_offset: usize,
        payload_length: usize,

        fn read(self: *const Self, offset: usize, length: usize) anyerror![]const u8 {
            return sourceBytes(Source, &self.source, offset, length);
        }
        fn u32At(self: *const Self, offset: usize) anyerror!u32 {
            const bytes = try self.read(offset, 4);
            return std.mem.readInt(u32, bytes[0..4], .little);
        }
        fn varAt(self: *const Self, cursor: *usize, limit: usize) anyerror!u32 {
            var result: u32 = 0;
            var shift: u5 = 0;
            while (true) {
                if (cursor.* >= limit) return error.InvalidContainer;
                const value = (try self.read(cursor.*, 1))[0];
                cursor.* += 1;
                if (shift == 28 and value > 0x0f) return error.InvalidContainer;
                result |= @as(u32, value & 0x7f) << shift;
                if (value & 0x80 == 0) return result;
                if (shift == 28) return error.InvalidContainer;
                shift += 7;
            }
        }

        fn directory(self: *const Self, rank: TermRank) anyerror!struct { offset: usize, length: usize, count: u32, codec: PostingCodec, singleton_base: u32 } {
            const index = @intFromEnum(rank);
            if (index >= self.term_count) return error.RankOutOfRange;
            const checkpoint = index / directory_stride;
            const checkpoint_at = self.directory_offset + @as(usize, checkpoint) * checkpoint_record_size;
            var payload_cursor = try self.u32At(checkpoint_at);
            var metadata_cursor = self.metadata_offset + try self.u32At(checkpoint_at + 4);
            var previous_single = try self.u32At(checkpoint_at + 8);
            const metadata_end = self.directory_offset + self.directory_length;
            var current = checkpoint * directory_stride;
            while (current <= index) : (current += 1) {
                const word = try self.varAt(&metadata_cursor, metadata_end);
                var codec: PostingCodec = undefined;
                var length: u32 = undefined;
                var count: u32 = undefined;
                if (word < 4) {
                    codec = @enumFromInt(word);
                    length = 1;
                    count = 1;
                } else {
                    const body = word - 4;
                    const code = body % 8;
                    if (code > @intFromEnum(PostingCodec.ef)) return error.InvalidDirectory;
                    codec = @enumFromInt(code);
                    length = std.math.add(u32, body / 16, 1) catch return error.Overflow;
                    count = if (body % 16 < 8) 1 else std.math.add(u32, try self.varAt(&metadata_cursor, metadata_end), 1) catch return error.Overflow;
                }
                if (current == index) return .{ .offset = payload_cursor, .length = length, .count = count, .codec = codec, .singleton_base = previous_single };
                if (codec == .signed_single) {
                    const payload = self.payload_offset + payload_cursor;
                    var cursor = payload;
                    var encoded: u64 = 0;
                    var shift: u6 = 0;
                    while (true) {
                        const byte = (try self.read(cursor, 1))[0];
                        cursor += 1;
                        encoded |= @as(u64, byte & 0x7f) << shift;
                        if (byte & 0x80 == 0) break;
                        if (shift >= 63) return error.InvalidContainer;
                        shift += 7;
                    }
                    const magnitude = encoded >> 1;
                    const delta: i64 = if (encoded & 1 == 0) @intCast(magnitude) else -@as(i64, @intCast(magnitude)) - 1;
                    const next = @as(i64, previous_single) + delta;
                    if (next < 0 or next >= self.entry_count) return error.InvalidContainer;
                    previous_single = @intCast(next);
                }
                payload_cursor = std.math.add(u32, payload_cursor, length) catch return error.Overflow;
            }
            return error.InvalidDirectory;
        }

        pub fn open(source_value: Source) !Self {
            if (sourceLength(Source, &source_value) < header_size) return error.Truncated;
            const header = try sourceBytes(Source, &source_value, 0, header_size);
            if (!std.mem.eql(u8, header[0..4], magic)) return error.InvalidHeader;
            if (std.mem.readInt(u16, header[4..6], .little) != version) return error.UnsupportedVersion;
            const state_raw = std.mem.readInt(u16, header[6..8], .little);
            if (state_raw > @intFromEnum(CodecState.encoded)) return error.InvalidHeader;
            const entry_count = std.mem.readInt(u32, header[8..12], .little);
            const term_count = std.mem.readInt(u32, header[12..16], .little);
            const dictionary_offset = std.mem.readInt(u32, header[16..20], .little);
            const dictionary_length = std.mem.readInt(u32, header[20..24], .little);
            const directory_offset = std.mem.readInt(u32, header[24..28], .little);
            const directory_length = std.mem.readInt(u32, header[28..32], .little);
            const payload_offset = std.mem.readInt(u32, header[32..36], .little);
            const payload_length = std.mem.readInt(u32, header[36..40], .little);
            const total = std.mem.readInt(u32, header[40..44], .little);
            const stride = std.mem.readInt(u16, header[46..48], .little);
            const checkpoint_count = std.mem.readInt(u32, header[48..52], .little);
            if (header[44] > @intFromEnum(Codec.bzip3) or header[45] != state_raw) return error.InvalidHeader;
            if (total != sourceLength(Source, &source_value) or dictionary_offset != header_size or term_count == 0 or stride != directory_stride or checkpoint_count != (term_count - 1) / stride + 1) return error.InvalidHeader;
            const checkpoint_bytes = std.math.mul(usize, checkpoint_count, checkpoint_record_size) catch return error.Overflow;
            const dictionary_end = std.math.add(usize, dictionary_offset, dictionary_length) catch return error.Overflow;
            const expected_directory = align8(dictionary_end) catch return error.InvalidDirectory;
            const directory_end = std.math.add(usize, directory_offset, directory_length) catch return error.Overflow;
            const expected_payload = align8(directory_end) catch return error.InvalidDirectory;
            if (directory_offset != expected_directory or directory_length < checkpoint_bytes or payload_offset != expected_payload or payload_offset + payload_length != total) return error.InvalidDirectory;
            const dictionary_source = try wire.Span(Source).init(source_value, dictionary_offset, dictionary_length);
            const dictionary = try automaton.ViewFor(wire.Span(Source)).open(dictionary_source);
            if (dictionary.entry_count != term_count or dictionary.accepted_count != term_count) return error.InvalidDirectory;
            return .{ .source = source_value, .entry_count = entry_count, .term_count = term_count, .requested_codec = @enumFromInt(header[44]), .codec_state = @enumFromInt(state_raw), .dictionary = dictionary, .directory_offset = directory_offset, .directory_length = directory_length, .checkpoint_count = checkpoint_count, .metadata_offset = directory_offset + checkpoint_bytes, .payload_offset = payload_offset, .payload_length = payload_length };
        }

        pub fn exact(self: *const Self, key: []const u8) !?Self.Hit {
            const hit = (try self.dictionary.exact(key)) orelse return null;
            const range = hit.entry_range orelse return null;
            if (range.len() != 1) return error.InvalidDirectory;
            const rank: TermRank = @enumFromInt(@intFromEnum(range.lo));
            const record = try self.directory(rank);
            if (record.length == 0 or record.offset + record.length > self.payload_length) return error.InvalidDirectory;
            return .{ .rank = rank, .postings = .{ .source = &self.source, .payload_offset = self.payload_offset + record.offset, .payload_length = record.length, .entry_count = self.entry_count, .count = record.count, .posting_codec = record.codec, .singleton_base = record.singleton_base } };
        }

        pub fn prefix(self: *const Self, key: []const u8) !?struct { lo: TermRank, hi: TermRank } {
            const range = (try self.dictionary.prefixInterval(key)) orelse return null;
            return .{ .lo = @enumFromInt(@intFromEnum(range.range.lo)), .hi = @enumFromInt(@intFromEnum(range.range.hi)) };
        }

        pub fn term(self: *const Self, rank: TermRank, scratch: []u8) !?[]const u8 {
            if (@intFromEnum(rank) >= self.term_count) return null;
            return (try self.dictionary.select(@intFromEnum(rank), scratch)).?.key;
        }

        pub fn verify(self: *const Self) !void {
            if ((self.requested_codec == .raw and self.codec_state != .raw) or (self.requested_codec == .bzip3 and self.codec_state != .requested_unavailable)) return error.UnsupportedCodec;
            try self.dictionary.verify();
            var scratch: [256]u8 = undefined;
            for (0..self.term_count) |index| {
                const hit = try self.exact((try self.term(@enumFromInt(index), &scratch)).?);
                var iterator = hit.?.postings.iterator();
                var seen: u32 = 0;
                while (try iterator.next()) |_| seen += 1;
                if (seen != hit.?.postings.count) return error.InvalidContainer;
            }
        }
    };
}

pub fn openSource(comptime Source: type, source: Source) !SourceView(Source) {
    return SourceView(Source).open(source);
}
