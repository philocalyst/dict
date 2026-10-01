//! Experimental, portable shared-reference codec.
//!
//! `bzip4` is only a working experiment name.  This format deliberately
//! separates its compression horizon (a charged archive dictionary) from its
//! access horizon (independently decodable microblocks).  It is not a bzip3
//! successor and makes no production compatibility promise.

const std = @import("std");

pub const magic = "BZ4X";
pub const version: u8 = 1;
pub const header_size: usize = 32;
pub const directory_record_size: usize = 16;
pub const min_match: usize = 4;
pub const max_match: usize = 259;
pub const max_dictionary_bytes: usize = 32 * 1024;
pub const max_distance: usize = 0x7fff;
pub const max_wire_block_bytes: usize = 64 * 1024 * 1024;
pub const predictor_working_bytes: usize = 256 * 8 * 2 * @sizeOf(u16);

const BlockMode = enum(u8) {
    raw = 0,
    lz = 1,
    lz_arithmetic = 2,
};

pub const Limits = struct {
    max_frame_bytes: usize = 512 * 1024 * 1024,
    max_raw_bytes: usize = 512 * 1024 * 1024,
    max_dictionary_bytes: usize = max_dictionary_bytes,
    max_block_bytes: usize = 64 * 1024,
    max_blocks: usize = 1_000_000,
    max_decode_allocation: usize = 512 * 1024 * 1024,
};

pub const EncodeOptions = struct {
    use_arithmetic: bool = true,
};

pub const Error = error{
    OutOfMemory,
    InvalidArgument,
    InputTooLarge,
    ResourceLimit,
    InvalidMagic,
    UnsupportedVersion,
    InvalidHeader,
    InvalidLayout,
    InvalidDictionary,
    InvalidDirectory,
    InvalidMode,
    Truncated,
    TrailingBytes,
    InvalidMatch,
    ChecksumMismatch,
    OutputSizeMismatch,
    BlockOutOfRange,
};

pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const TrainedDictionary = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn deinit(self: *TrainedDictionary) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

const Candidate = struct {
    hash: u32 = 0,
    count: u32 = 0,
    position: u32 = 0,
    occupied: bool = false,
};

const Ranked = struct {
    count: u32,
    hash: u32,
    position: u32,
};

fn rankBefore(_: void, a: Ranked, b: Ranked) bool {
    if (a.count != b.count) return a.count > b.count;
    if (a.hash != b.hash) return a.hash < b.hash;
    return a.position < b.position;
}

/// Build a deterministic dictionary from training bytes only.  Frequent
/// 8-byte anchors select 64-byte source fragments.  The bounded table and
/// fixed stride keep training memory and work explicit; this is a baseline
/// reference selector, not a claim of optimal dictionary construction.
pub fn trainDictionary(
    allocator: std.mem.Allocator,
    training: []const u8,
    requested_bytes: usize,
) Error!TrainedDictionary {
    if (requested_bytes > max_dictionary_bytes) return error.InvalidArgument;
    if (training.len > std.math.maxInt(u32)) return error.InputTooLarge;
    if (requested_bytes == 0 or training.len < 8) {
        const empty = allocator.alloc(u8, 0) catch return error.OutOfMemory;
        return .{ .allocator = allocator, .bytes = empty };
    }

    const target = @min(requested_bytes, training.len);
    const table_len: usize = 16 * 1024;
    var table = allocator.alloc(Candidate, table_len) catch return error.OutOfMemory;
    defer allocator.free(table);
    @memset(table, .{});

    var position: usize = 0;
    while (position + 8 <= training.len) : (position += 4) {
        const hash = hash4(training[position..][0..4]) ^
            std.math.rotl(u32, hash4(training[position + 4 ..][0..4]), 13);
        var slot: usize = @intCast(hash & (table_len - 1));
        var probes: usize = 0;
        while (probes < 8) : (probes += 1) {
            const entry = &table[slot];
            if (!entry.occupied) {
                entry.* = .{ .hash = hash, .count = 1, .position = @intCast(position), .occupied = true };
                break;
            }
            if (entry.hash == hash) {
                entry.count +|= 1;
                entry.position = @intCast(position);
                break;
            }
            slot = (slot + 1) & (table_len - 1);
        }
    }

    var ranked: std.ArrayList(Ranked) = .empty;
    defer ranked.deinit(allocator);
    for (table) |entry| if (entry.occupied) {
        ranked.append(allocator, .{ .count = entry.count, .hash = entry.hash, .position = entry.position }) catch return error.OutOfMemory;
    };
    std.sort.block(Ranked, ranked.items, {}, rankBefore);

    var result = allocator.alloc(u8, target) catch return error.OutOfMemory;
    errdefer allocator.free(result);
    var written: usize = 0;
    const fragment_bytes: usize = 64;
    for (ranked.items) |entry| {
        if (written == target) break;
        const start: usize = entry.position;
        const available = @min(fragment_bytes, training.len - start);
        const take = @min(available, target - written);
        @memcpy(result[written..][0..take], training[start..][0..take]);
        written += take;
    }
    // Tiny or unusually collision-heavy training inputs may not supply enough
    // ranked fragments.  Fill deterministically from the training prefix.
    while (written < target) {
        const take = @min(target - written, training.len);
        @memcpy(result[written..][0..take], training[0..take]);
        written += take;
    }
    return .{ .allocator = allocator, .bytes = result };
}

const hash_slots: usize = 1 << 15;

fn hash4(bytes: []const u8) u32 {
    const value = std.mem.readInt(u32, bytes[0..4], .little);
    return (value *% 0x9e3779b1) >> 17;
}

const Match = struct {
    dictionary: bool = false,
    value: usize = 0,
    length: usize = 0,
};

fn matchLength(a: []const u8, b: []const u8, cap: usize) usize {
    const length = @min(cap, @min(a.len, b.len));
    var at: usize = 0;
    while (at < length and a[at] == b[at]) : (at += 1) {}
    return at;
}

fn bestMatch(
    input: []const u8,
    at: usize,
    dictionary: []const u8,
    dictionary_heads: []const i32,
    local_heads: []const i32,
) Match {
    if (at + min_match > input.len) return .{};
    const slot = hash4(input[at..][0..4]) & (hash_slots - 1);
    const cap = @min(max_match, input.len - at);
    var best: Match = .{};

    const dictionary_position = dictionary_heads[slot];
    if (dictionary_position >= 0) {
        const source: usize = @intCast(dictionary_position);
        const length = matchLength(input[at..], dictionary[source..], cap);
        if (length >= min_match) best = .{ .dictionary = true, .value = source, .length = length };
    }

    const local_position = local_heads[slot];
    if (local_position >= 0) {
        const source: usize = @intCast(local_position);
        const distance = at - source;
        if (distance > 0 and distance <= max_distance) {
            // Comparison against the input permits the overlap semantics used
            // by the byte-wise decoder for repeated runs.
            const length = matchLength(input[at..], input[source..], cap);
            if (length >= min_match and length > best.length) {
                best = .{ .dictionary = false, .value = distance, .length = length };
            }
        }
    }
    return best;
}

fn appendByte(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u8) Error!void {
    out.append(allocator, value) catch return error.OutOfMemory;
}

fn appendU16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) Error!void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    out.appendSlice(allocator, &bytes) catch return error.OutOfMemory;
}

fn encodeLzBlock(
    allocator: std.mem.Allocator,
    input: []const u8,
    dictionary: []const u8,
    dictionary_heads: []const i32,
    local_heads: []i32,
) Error![]u8 {
    @memset(local_heads, -1);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendByte(&out, allocator, @intFromEnum(BlockMode.lz));
    var at: usize = 0;
    while (at < input.len) {
        const control_at = out.items.len;
        try appendByte(&out, allocator, 0);
        var control: u8 = 0;
        var bit: u4 = 0;
        while (bit < 8 and at < input.len) : (bit += 1) {
            const found = bestMatch(input, at, dictionary, dictionary_heads, local_heads);
            if (found.length >= min_match) {
                control |= @as(u8, 1) << @as(u3, @intCast(bit));
                const tagged: u16 = if (found.dictionary)
                    @as(u16, 0x8000) | @as(u16, @intCast(found.value))
                else
                    @intCast(found.value);
                try appendU16(&out, allocator, tagged);
                try appendByte(&out, allocator, @intCast(found.length - min_match));
                const end = at + found.length;
                while (at < end) : (at += 1) {
                    if (at + min_match <= input.len) {
                        local_heads[hash4(input[at..][0..4]) & (hash_slots - 1)] = @intCast(at);
                    }
                }
            } else {
                try appendByte(&out, allocator, input[at]);
                if (at + min_match <= input.len) {
                    local_heads[hash4(input[at..][0..4]) & (hash_slots - 1)] = @intCast(at);
                }
                at += 1;
            }
        }
        out.items[control_at] = control;
    }
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

const BitWriter = struct {
    out: std.ArrayList(u8) = .empty,
    current: u8 = 0,
    used: u4 = 0,
    max_bytes: usize,

    fn bit(self: *BitWriter, allocator: std.mem.Allocator, value: u1) Error!void {
        self.current = (self.current << 1) | value;
        self.used += 1;
        if (self.used == 8) {
            if (self.out.items.len >= self.max_bytes) return error.ResourceLimit;
            try appendByte(&self.out, allocator, self.current);
            self.current = 0;
            self.used = 0;
        }
    }

    fn finish(self: *BitWriter, allocator: std.mem.Allocator) Error![]u8 {
        if (self.used != 0) {
            if (self.out.items.len >= self.max_bytes) return error.ResourceLimit;
            self.current <<= @intCast(8 - self.used);
            try appendByte(&self.out, allocator, self.current);
        }
        return self.out.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }
};

const BitReader = struct {
    bytes: []const u8,
    bit_index: usize = 0,

    fn bit(self: *BitReader) u1 {
        // Arithmetic decoding conventionally shifts zero bits after the
        // finite final code. The containing block length remains exact.
        const byte_index = self.bit_index / 8;
        if (byte_index >= self.bytes.len) return 0;
        const byte = self.bytes[byte_index];
        const shift: u3 = @intCast(7 - (self.bit_index & 7));
        self.bit_index += 1;
        return @intCast((byte >> shift) & 1);
    }
};

const Predictor = struct {
    counts: [256][8][2]u16 = [_][8][2]u16{[_][2]u16{[_]u16{ 1, 1 }} ** 8} ** 256,

    fn probability(self: *Predictor, previous: u8, bit_position: usize) *[2]u16 {
        return &self.counts[previous][bit_position];
    }

    fn update(counts: *[2]u16, value: u1) void {
        counts[value] += 1;
        if (@as(u32, counts[0]) + counts[1] >= 4096) {
            counts[0] = @max(@as(u16, 1), (counts[0] + 1) / 2);
            counts[1] = @max(@as(u16, 1), (counts[1] + 1) / 2);
        }
    }
};

fn emitWithPending(writer: *BitWriter, allocator: std.mem.Allocator, value: u1, pending: *usize) Error!void {
    try writer.bit(allocator, value);
    while (pending.* != 0) : (pending.* -= 1) try writer.bit(allocator, value ^ 1);
}

/// Integer-only online previous-byte/bit-position predictor followed by a
/// classic finite-precision arithmetic coder. The model restarts at every
/// microblock, so no hidden weights or out-of-band state are required.
fn arithmeticEncode(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    return arithmeticEncodeLimited(allocator, input, std.math.maxInt(usize));
}

fn arithmeticEncodeLimited(allocator: std.mem.Allocator, input: []const u8, max_output_bytes: usize) Error![]u8 {
    const half: u64 = 0x80000000;
    const first_quarter: u64 = 0x40000000;
    const third_quarter: u64 = 0xc0000000;
    var low: u64 = 0;
    var high: u64 = 0xffffffff;
    var pending: usize = 0;
    var predictor = Predictor{};
    var previous: u8 = 0;
    var writer = BitWriter{ .max_bytes = max_output_bytes };
    errdefer writer.out.deinit(allocator);

    for (input) |byte| {
        for (0..8) |bit_position| {
            const shift: u3 = @intCast(7 - bit_position);
            const value: u1 = @intCast((byte >> shift) & 1);
            const counts = predictor.probability(previous, bit_position);
            const total: u64 = @as(u64, counts[0]) + counts[1];
            const range = high - low + 1;
            const split = low + (range * counts[0]) / total - 1;
            if (value == 0) high = split else low = split + 1;
            while (true) {
                if (high < half) {
                    try emitWithPending(&writer, allocator, 0, &pending);
                } else if (low >= half) {
                    try emitWithPending(&writer, allocator, 1, &pending);
                    low -= half;
                    high -= half;
                } else if (low >= first_quarter and high < third_quarter) {
                    pending += 1;
                    low -= first_quarter;
                    high -= first_quarter;
                } else break;
                low <<= 1;
                high = (high << 1) | 1;
            }
            Predictor.update(counts, value);
        }
        previous = byte;
    }
    pending += 1;
    try emitWithPending(&writer, allocator, if (low < first_quarter) 0 else 1, &pending);
    return writer.finish(allocator);
}

fn arithmeticDecode(encoded: []const u8, output: []u8) Error!void {
    const half: u64 = 0x80000000;
    const first_quarter: u64 = 0x40000000;
    const third_quarter: u64 = 0xc0000000;
    var reader = BitReader{ .bytes = encoded };
    var low: u64 = 0;
    var high: u64 = 0xffffffff;
    var code: u64 = 0;
    for (0..32) |_| code = (code << 1) | reader.bit();
    var predictor = Predictor{};
    var previous: u8 = 0;
    for (output) |*byte| {
        var value_byte: u8 = 0;
        for (0..8) |bit_position| {
            const counts = predictor.probability(previous, bit_position);
            const total: u64 = @as(u64, counts[0]) + counts[1];
            const range = high - low + 1;
            const split = low + (range * counts[0]) / total - 1;
            const value: u1 = if (code <= split) 0 else 1;
            if (value == 0) high = split else low = split + 1;
            while (true) {
                if (high < half) {
                    // no coordinate adjustment
                } else if (low >= half) {
                    code -= half;
                    low -= half;
                    high -= half;
                } else if (low >= first_quarter and high < third_quarter) {
                    code -= first_quarter;
                    low -= first_quarter;
                    high -= first_quarter;
                } else break;
                low <<= 1;
                high = (high << 1) | 1;
                code = (code << 1) | reader.bit();
            }
            Predictor.update(counts, value);
            value_byte = (value_byte << 1) | value;
        }
        byte.* = value_byte;
        previous = value_byte;
    }
}

fn checksum(bytes: []const u8) u32 {
    return std.hash.crc.Crc32.hash(bytes);
}

fn metadataChecksum(header_prefix: []const u8, dictionary: []const u8, directory: []const u8) u32 {
    var crc = std.hash.crc.Crc32.init();
    crc.update(header_prefix);
    crc.update(dictionary);
    crc.update(directory);
    return crc.final();
}

fn checkedAdd(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.ResourceLimit;
}

fn checkedMul(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch error.ResourceLimit;
}

pub fn encodeFrame(
    allocator: std.mem.Allocator,
    input: []const u8,
    dictionary: []const u8,
    block_bytes: usize,
    limits: Limits,
) Error!Owned {
    return encodeFrameWithOptions(allocator, input, dictionary, block_bytes, limits, .{});
}

pub fn encodeFrameWithOptions(
    allocator: std.mem.Allocator,
    input: []const u8,
    dictionary: []const u8,
    block_bytes: usize,
    limits: Limits,
    options: EncodeOptions,
) Error!Owned {
    if (block_bytes == 0 or block_bytes > limits.max_block_bytes or block_bytes > max_wire_block_bytes) return error.InvalidArgument;
    if (dictionary.len > limits.max_dictionary_bytes or dictionary.len > max_dictionary_bytes) return error.InvalidDictionary;
    if (input.len > limits.max_raw_bytes) return error.InputTooLarge;
    const block_count = if (input.len == 0) 0 else (input.len - 1) / block_bytes + 1;
    if (block_count > limits.max_blocks or block_count > std.math.maxInt(u32)) return error.ResourceLimit;
    const directory_bytes = try checkedMul(block_count, directory_record_size);
    const prefix_bytes = try checkedAdd(try checkedAdd(header_size, dictionary.len), directory_bytes);
    if (prefix_bytes > limits.max_frame_bytes) return error.ResourceLimit;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    out.appendNTimes(allocator, 0, prefix_bytes) catch return error.OutOfMemory;
    @memcpy(out.items[header_size..][0..dictionary.len], dictionary);
    const payload_base = prefix_bytes;

    // The shared reference is immutable across the frame: build its lookup
    // once. Local history is still cleared at every restart boundary.
    const dictionary_heads = allocator.alloc(i32, hash_slots) catch return error.OutOfMemory;
    defer allocator.free(dictionary_heads);
    const local_heads = allocator.alloc(i32, hash_slots) catch return error.OutOfMemory;
    defer allocator.free(local_heads);
    @memset(dictionary_heads, -1);
    if (dictionary.len >= min_match) {
        for (0..dictionary.len - min_match + 1) |at| {
            dictionary_heads[hash4(dictionary[at..][0..4]) & (hash_slots - 1)] = @intCast(at);
        }
    }

    var block_index: usize = 0;
    while (block_index < block_count) : (block_index += 1) {
        const raw_start = block_index * block_bytes;
        const raw = input[raw_start..][0..@min(input.len - raw_start, block_bytes)];
        const lz = try encodeLzBlock(allocator, raw, dictionary, dictionary_heads, local_heads);
        defer allocator.free(lz);
        const arithmetic: ?[]u8 = if (options.use_arithmetic) try arithmeticEncode(allocator, lz[1..]) else null;
        defer if (arithmetic) |bytes| allocator.free(bytes);
        const arithmetic_len = if (arithmetic) |bytes| 1 + 4 + bytes.len else std.math.maxInt(usize);
        const best_compressed_len = @min(lz.len, arithmetic_len);
        const use_compressed = best_compressed_len < raw.len + 1;
        const relative_offset = out.items.len - payload_base;
        if (relative_offset > std.math.maxInt(u32)) return error.ResourceLimit;
        if (use_compressed and arithmetic_len < lz.len) {
            try appendByte(&out, allocator, @intFromEnum(BlockMode.lz_arithmetic));
            var token_length: [4]u8 = undefined;
            std.mem.writeInt(u32, &token_length, @intCast(lz.len - 1), .little);
            out.appendSlice(allocator, &token_length) catch return error.OutOfMemory;
            out.appendSlice(allocator, arithmetic.?) catch return error.OutOfMemory;
        } else if (use_compressed) {
            out.appendSlice(allocator, lz) catch return error.OutOfMemory;
        } else {
            try appendByte(&out, allocator, @intFromEnum(BlockMode.raw));
            out.appendSlice(allocator, raw) catch return error.OutOfMemory;
        }
        if (out.items.len > limits.max_frame_bytes) return error.ResourceLimit;
        const encoded_len = out.items.len - payload_base - relative_offset;
        if (encoded_len > std.math.maxInt(u32) or raw.len > std.math.maxInt(u32)) return error.ResourceLimit;
        const record = header_size + dictionary.len + block_index * directory_record_size;
        writeU32(out.items, record, @intCast(relative_offset));
        writeU32(out.items, record + 4, @intCast(encoded_len));
        writeU32(out.items, record + 8, @intCast(raw.len));
        writeU32(out.items, record + 12, checksum(raw));
    }

    @memcpy(out.items[0..4], magic);
    out.items[4] = version;
    out.items[5] = 0;
    writeU16(out.items, 6, header_size);
    writeU32(out.items, 8, @intCast(dictionary.len));
    writeU32(out.items, 12, @intCast(block_bytes));
    writeU32(out.items, 16, @intCast(block_count));
    writeU64(out.items, 20, @intCast(input.len));
    writeU32(out.items, 28, metadataChecksum(
        out.items[0..28],
        out.items[header_size..][0..dictionary.len],
        out.items[header_size + dictionary.len .. prefix_bytes],
    ));
    return .{ .allocator = allocator, .bytes = out.toOwnedSlice(allocator) catch return error.OutOfMemory };
}

pub const Frame = struct {
    bytes: []const u8,
    dictionary: []const u8,
    directory: []const u8,
    payload: []const u8,
    block_bytes: usize,
    block_count: usize,
    raw_len: usize,
    limits: Limits,

    pub fn open(bytes: []const u8, limits: Limits) Error!Frame {
        if (bytes.len > limits.max_frame_bytes) return error.ResourceLimit;
        if (bytes.len < header_size) return error.Truncated;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.InvalidMagic;
        if (bytes[4] != version) return error.UnsupportedVersion;
        if (bytes[5] != 0 or readU16(bytes, 6) != header_size) return error.InvalidHeader;
        const dictionary_len: usize = readU32(bytes, 8);
        const block_bytes: usize = readU32(bytes, 12);
        const block_count: usize = readU32(bytes, 16);
        const raw_len64 = readU64(bytes, 20);
        if (raw_len64 > std.math.maxInt(usize)) return error.ResourceLimit;
        const raw_len: usize = @intCast(raw_len64);
        if (dictionary_len > limits.max_dictionary_bytes or dictionary_len > max_dictionary_bytes) return error.InvalidDictionary;
        if (block_bytes == 0 or block_bytes > limits.max_block_bytes or block_bytes > max_wire_block_bytes) return error.InvalidHeader;
        if (block_count > limits.max_blocks or raw_len > limits.max_raw_bytes) return error.ResourceLimit;
        const expected_blocks = if (raw_len == 0) 0 else (raw_len - 1) / block_bytes + 1;
        if (expected_blocks != block_count) return error.InvalidHeader;
        const directory_len = try checkedMul(block_count, directory_record_size);
        const payload_at = try checkedAdd(try checkedAdd(header_size, dictionary_len), directory_len);
        if (payload_at > bytes.len) return error.Truncated;
        const directory = bytes[header_size + dictionary_len .. payload_at];
        const payload = bytes[payload_at..];
        if (readU32(bytes, 28) != metadataChecksum(bytes[0..28], bytes[header_size..][0..dictionary_len], directory)) {
            return error.ChecksumMismatch;
        }
        var expected_offset: usize = 0;
        var raw_total: usize = 0;
        for (0..block_count) |block_index| {
            const record = block_index * directory_record_size;
            const offset: usize = readU32(directory, record);
            const encoded_len: usize = readU32(directory, record + 4);
            const block_raw_len: usize = readU32(directory, record + 8);
            if (offset != expected_offset or encoded_len == 0) return error.InvalidDirectory;
            if (block_raw_len == 0 or block_raw_len > block_bytes) return error.InvalidDirectory;
            if (block_index + 1 < block_count and block_raw_len != block_bytes) return error.InvalidDirectory;
            expected_offset = try checkedAdd(expected_offset, encoded_len);
            raw_total = try checkedAdd(raw_total, block_raw_len);
            if (expected_offset > payload.len) return error.Truncated;
        }
        if (expected_offset != payload.len) return error.TrailingBytes;
        if (raw_total != raw_len) return error.InvalidDirectory;
        return .{
            .bytes = bytes,
            .dictionary = bytes[header_size..][0..dictionary_len],
            .directory = directory,
            .payload = payload,
            .block_bytes = block_bytes,
            .block_count = block_count,
            .raw_len = raw_len,
            .limits = limits,
        };
    }

    pub fn blockEncodedLength(self: Frame, block_index: usize) Error!usize {
        if (block_index >= self.block_count) return error.BlockOutOfRange;
        return readU32(self.directory, block_index * directory_record_size + 4);
    }

    pub fn blockRawLength(self: Frame, block_index: usize) Error!usize {
        if (block_index >= self.block_count) return error.BlockOutOfRange;
        return readU32(self.directory, block_index * directory_record_size + 8);
    }

    pub fn decodeBlock(self: Frame, allocator: std.mem.Allocator, block_index: usize) Error!Owned {
        if (block_index >= self.block_count) return error.BlockOutOfRange;
        const record = block_index * directory_record_size;
        const raw_len: usize = readU32(self.directory, record + 8);
        if (raw_len > self.limits.max_decode_allocation) return error.ResourceLimit;
        const output = allocator.alloc(u8, raw_len) catch return error.OutOfMemory;
        errdefer allocator.free(output);
        try self.decodeBlockInto(allocator, block_index, output, raw_len);
        return .{ .allocator = allocator, .bytes = output };
    }

    fn decodeBlockInto(
        self: Frame,
        allocator: std.mem.Allocator,
        block_index: usize,
        output: []u8,
        live_output_bytes: usize,
    ) Error!void {
        if (block_index >= self.block_count) return error.BlockOutOfRange;
        const record = block_index * directory_record_size;
        const offset: usize = readU32(self.directory, record);
        const encoded_len: usize = readU32(self.directory, record + 4);
        const raw_len: usize = readU32(self.directory, record + 8);
        const expected_checksum = readU32(self.directory, record + 12);
        if (output.len != raw_len) return error.OutputSizeMismatch;
        const encoded = self.payload[offset..][0..encoded_len];
        if (encoded.len == 0) return error.Truncated;
        const mode = std.enums.fromInt(BlockMode, encoded[0]) orelse return error.InvalidMode;
        switch (mode) {
            .raw => {
                if (encoded.len != raw_len + 1) return error.OutputSizeMismatch;
                @memcpy(output, encoded[1..]);
            },
            .lz => try decodeLz(encoded[1..], self.dictionary, output),
            .lz_arithmetic => {
                if (encoded.len < 6) return error.Truncated;
                const token_len: usize = std.mem.readInt(u32, encoded[1..5], .little);
                const groups = raw_len / 8 + @intFromBool(raw_len % 8 != 0);
                const token_bound = try checkedAdd(try checkedAdd(raw_len, groups), 1);
                if (token_len == 0 or token_len > token_bound) return error.ResourceLimit;
                // Logical live-allocation budget: caller-owned output plus
                // decoded token bytes plus the canonical re-encoding.
                const decode_charge = try checkedAdd(try checkedAdd(live_output_bytes, token_len), encoded.len - 5);
                if (decode_charge > self.limits.max_decode_allocation) return error.ResourceLimit;
                const tokens = allocator.alloc(u8, token_len) catch return error.OutOfMemory;
                defer allocator.free(tokens);
                try arithmeticDecode(encoded[5..], tokens);
                // The arithmetic reader intentionally supplies conventional
                // zero extension to initialize/finalize its code register.
                // Re-encoding makes that finite representation canonical and
                // rejects ignored nonzero bytes or alternative tails.
                const canonical = arithmeticEncodeLimited(allocator, tokens, encoded.len - 5) catch |err| switch (err) {
                    error.ResourceLimit => return error.TrailingBytes,
                    else => return err,
                };
                defer allocator.free(canonical);
                if (!std.mem.eql(u8, canonical, encoded[5..])) return error.TrailingBytes;
                try decodeLz(tokens, self.dictionary, output);
            },
        }
        if (checksum(output) != expected_checksum) return error.ChecksumMismatch;
    }

    pub fn decodeAll(self: Frame, allocator: std.mem.Allocator) Error!Owned {
        if (self.raw_len > self.limits.max_decode_allocation) return error.ResourceLimit;
        var output = allocator.alloc(u8, self.raw_len) catch return error.OutOfMemory;
        errdefer allocator.free(output);
        var written: usize = 0;
        for (0..self.block_count) |block_index| {
            const block_len = try self.blockRawLength(block_index);
            try self.decodeBlockInto(allocator, block_index, output[written..][0..block_len], self.raw_len);
            written += block_len;
        }
        if (written != self.raw_len) return error.OutputSizeMismatch;
        return .{ .allocator = allocator, .bytes = output };
    }
};

fn decodeLz(encoded: []const u8, dictionary: []const u8, output: []u8) Error!void {
    var input_at: usize = 0;
    var output_at: usize = 0;
    while (output_at < output.len) {
        if (input_at >= encoded.len) return error.Truncated;
        const control = encoded[input_at];
        input_at += 1;
        var bit: u4 = 0;
        while (bit < 8 and output_at < output.len) : (bit += 1) {
            if ((control & (@as(u8, 1) << @as(u3, @intCast(bit)))) == 0) {
                if (input_at >= encoded.len) return error.Truncated;
                output[output_at] = encoded[input_at];
                output_at += 1;
                input_at += 1;
            } else {
                if (input_at + 3 > encoded.len) return error.Truncated;
                const tagged = std.mem.readInt(u16, encoded[input_at..][0..2], .little);
                const length: usize = @as(usize, encoded[input_at + 2]) + min_match;
                input_at += 3;
                if (length > output.len - output_at) return error.InvalidMatch;
                if ((tagged & 0x8000) != 0) {
                    const source: usize = tagged & 0x7fff;
                    if (source > dictionary.len or length > dictionary.len - source) return error.InvalidMatch;
                    @memcpy(output[output_at..][0..length], dictionary[source..][0..length]);
                    output_at += length;
                } else {
                    const distance: usize = tagged;
                    if (distance == 0 or distance > output_at) return error.InvalidMatch;
                    for (0..length) |_| {
                        output[output_at] = output[output_at - distance];
                        output_at += 1;
                    }
                }
            }
        }
    }
    if (input_at != encoded.len) return error.TrailingBytes;
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

test "roundtrip text binary repeated unicode and empty" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        "",
        "dictionary definition: a book of words; dictionary definition: a book of words",
        "\x00\xff\x01\x80binary\x00tail",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "日本語の辞書 — español — Ελληνικά",
    };
    const training = "dictionary definition lexical word meaning phrase日本語 español repeated repeated repeated";
    var dictionary = try trainDictionary(allocator, training, 1024);
    defer dictionary.deinit();
    for (cases) |input| {
        var encoded = try encodeFrame(allocator, input, dictionary.bytes, 16, .{});
        defer encoded.deinit();
        const frame = try Frame.open(encoded.bytes, .{});
        var decoded = try frame.decodeAll(allocator);
        defer decoded.deinit();
        try std.testing.expectEqualSlices(u8, input, decoded.bytes);
    }
}

test "microblocks are independently decodable and deterministic" {
    const allocator = std.testing.allocator;
    const input = "0123456789abcdef0123456789abcdef--0123456789abcdef";
    var dictionary = try trainDictionary(allocator, "xxxx0123456789abcdefyyyy", 24);
    defer dictionary.deinit();
    var first = try encodeFrame(allocator, input, dictionary.bytes, 16, .{});
    defer first.deinit();
    var second = try encodeFrame(allocator, input, dictionary.bytes, 16, .{});
    defer second.deinit();
    try std.testing.expectEqualSlices(u8, first.bytes, second.bytes);
    const frame = try Frame.open(first.bytes, .{});
    try std.testing.expectEqual(@as(usize, 4), frame.block_count);
    var block = try frame.decodeBlock(allocator, 2);
    defer block.deinit();
    try std.testing.expectEqualSlices(u8, input[32..48], block.bytes);
}

test "raw fallback is charged and exact" {
    const allocator = std.testing.allocator;
    var input: [257]u8 = undefined;
    var state: u32 = 0x12345678;
    for (&input) |*byte| {
        state = state *% 1664525 +% 1013904223;
        byte.* = @truncate(state >> 16);
    }
    var encoded = try encodeFrame(allocator, &input, "", 128, .{});
    defer encoded.deinit();
    const frame = try Frame.open(encoded.bytes, .{});
    var decoded = try frame.decodeAll(allocator);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u8, &input, decoded.bytes);
}

test "reject malformed headers directories tails indices and budgets" {
    const allocator = std.testing.allocator;
    const input = "abcabcabcabcabcabcabcabc";
    var encoded = try encodeFrame(allocator, input, "abc", 8, .{});
    defer encoded.deinit();

    try std.testing.expectError(error.Truncated, Frame.open(encoded.bytes[0..12], .{}));
    var bad_magic = try allocator.dupe(u8, encoded.bytes);
    defer allocator.free(bad_magic);
    bad_magic[0] = 0;
    try std.testing.expectError(error.InvalidMagic, Frame.open(bad_magic, .{}));

    const bad_dictionary = try allocator.dupe(u8, encoded.bytes);
    defer allocator.free(bad_dictionary);
    bad_dictionary[header_size] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, Frame.open(bad_dictionary, .{}));

    var bad_count = try allocator.dupe(u8, encoded.bytes);
    defer allocator.free(bad_count);
    writeU32(bad_count, 16, 999);
    writeU32(bad_count, 28, metadataChecksum(bad_count[0..28], bad_count[header_size..][0..3], bad_count[header_size + 3 ..][0..48]));
    try std.testing.expectError(error.InvalidHeader, Frame.open(bad_count, .{}));

    const bad_offset = try allocator.dupe(u8, encoded.bytes);
    defer allocator.free(bad_offset);
    writeU32(bad_offset, header_size + 3, 1);
    writeU32(bad_offset, 28, metadataChecksum(bad_offset[0..28], bad_offset[header_size..][0..3], bad_offset[header_size + 3 ..][0..48]));
    try std.testing.expectError(error.InvalidDirectory, Frame.open(bad_offset, .{}));

    var tail = try allocator.alloc(u8, encoded.bytes.len + 1);
    defer allocator.free(tail);
    @memcpy(tail[0..encoded.bytes.len], encoded.bytes);
    tail[tail.len - 1] = 0;
    try std.testing.expectError(error.TrailingBytes, Frame.open(tail, .{}));

    const frame = try Frame.open(encoded.bytes, .{});
    try std.testing.expectError(error.BlockOutOfRange, frame.decodeBlock(allocator, frame.block_count));
    try std.testing.expectError(error.ResourceLimit, Frame.open(encoded.bytes, .{ .max_raw_bytes = 4 }));
    const tight_frame = try Frame.open(encoded.bytes, .{ .max_decode_allocation = 4 });
    try std.testing.expectError(error.ResourceLimit, tight_frame.decodeAll(allocator));
}

test "reject out of range dictionary match before copying" {
    const allocator = std.testing.allocator;
    var encoded = try encodeFrame(allocator, "abcdefgh", "", 8, .{});
    defer encoded.deinit();
    const frame = try Frame.open(encoded.bytes, .{});
    try std.testing.expectEqual(@as(usize, 9), frame.payload.len);
    encoded.bytes[encoded.bytes.len - 9] = @intFromEnum(BlockMode.lz);
    encoded.bytes[encoded.bytes.len - 8] = 1;
    std.mem.writeInt(u16, encoded.bytes[encoded.bytes.len - 7 ..][0..2], 0xffff, .little);
    encoded.bytes[encoded.bytes.len - 5] = 0;
    const malformed = try Frame.open(encoded.bytes, .{});
    try std.testing.expectError(error.InvalidMatch, malformed.decodeBlock(allocator, 0));
}

test "allocation failure is reported" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, trainDictionary(failing.allocator(), "training bytes", 8));
    try std.testing.expectError(error.OutOfMemory, encodeFrame(failing.allocator(), "input", "", 4, .{}));
}

fn exerciseAllAllocations(allocator: std.mem.Allocator) !void {
    const phrase = "lexical definition context model shared dictionary microblock; ";
    const input = try allocator.alloc(u8, 8192);
    defer allocator.free(input);
    for (input, 0..) |*byte, index| byte.* = phrase[index % phrase.len];
    var dictionary = try trainDictionary(allocator, input[0..1024], 512);
    defer dictionary.deinit();
    var encoded = try encodeFrame(allocator, input, dictionary.bytes, 4096, .{});
    defer encoded.deinit();
    const frame = try Frame.open(encoded.bytes, .{});
    var saw_arithmetic = false;
    for (0..frame.block_count) |block_index| {
        const record = block_index * directory_record_size;
        const offset: usize = readU32(frame.directory, record);
        saw_arithmetic = saw_arithmetic or frame.payload[offset] == @intFromEnum(BlockMode.lz_arithmetic);
    }
    try std.testing.expect(saw_arithmetic);
    var decoded = try frame.decodeAll(allocator);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u8, input, decoded.bytes);
}

test "all train encode and decode allocations propagate out of memory" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllAllocations, .{});
}

test "arithmetic representation is exact and canonical" {
    const allocator = std.testing.allocator;
    const input = "literal/control/distance/length token roles are deliberately mixed here";
    const encoded = try arithmeticEncode(allocator, input);
    defer allocator.free(encoded);
    const decoded = try allocator.alloc(u8, input.len);
    defer allocator.free(decoded);
    try arithmeticDecode(encoded, decoded);
    try std.testing.expectEqualSlices(u8, input, decoded);
    const canonical = try arithmeticEncode(allocator, decoded);
    defer allocator.free(canonical);
    try std.testing.expectEqualSlices(u8, encoded, canonical);

    const tailed = try allocator.alloc(u8, encoded.len + 1);
    defer allocator.free(tailed);
    @memcpy(tailed[0..encoded.len], encoded);
    tailed[tailed.len - 1] = 1;
    try arithmeticDecode(tailed, decoded);
    const recoded = try arithmeticEncode(allocator, decoded);
    defer allocator.free(recoded);
    try std.testing.expect(!std.mem.eql(u8, tailed, recoded));
}

test "selected arithmetic frame rejects a noncanonical tail" {
    const allocator = std.testing.allocator;
    const phrase = "lexical definition context model shared dictionary microblock; ";
    var input: [4096]u8 = undefined;
    for (&input, 0..) |*byte, index| byte.* = phrase[index % phrase.len];
    var dictionary = try trainDictionary(allocator, input[0..1024], 512);
    defer dictionary.deinit();
    var encoded = try encodeFrame(allocator, &input, dictionary.bytes, input.len, .{});
    defer encoded.deinit();
    const valid = try Frame.open(encoded.bytes, .{});
    try std.testing.expectEqual(@as(usize, 1), valid.block_count);
    try std.testing.expectEqual(@intFromEnum(BlockMode.lz_arithmetic), valid.payload[0]);

    const changed = try allocator.alloc(u8, encoded.bytes.len + 1);
    defer allocator.free(changed);
    @memcpy(changed[0..encoded.bytes.len], encoded.bytes);
    changed[changed.len - 1] = 1;
    const directory_at = header_size + dictionary.bytes.len;
    const old_encoded_len = readU32(changed, directory_at + 4);
    writeU32(changed, directory_at + 4, old_encoded_len + 1);
    writeU32(changed, 28, metadataChecksum(
        changed[0..28],
        changed[header_size..directory_at],
        changed[directory_at..][0..directory_record_size],
    ));
    const malformed = try Frame.open(changed, .{});
    try std.testing.expectError(error.TrailingBytes, malformed.decodeBlock(allocator, 0));
}
