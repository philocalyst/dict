const std = @import("std");

pub const Density = enum {
    dense,
    sparse,
    very_sparse,
};

pub const Error = error{
    OutOfBounds,
    InvalidArgument,
    InvalidEncoding,
    Overflow,
    OutOfMemory,
    BadMagic,
    UnsupportedVersion,
    UnsupportedRepresentation,
    Truncated,
    NotApplicable,
    Unverified,
};

// The owning and borrowed APIs execute the same canonical wire codecs.  This
// keeps one implementation of rank/select/get for dense, Elias--Fano, and RRR
// data instead of maintaining a second host-only representation family.
pub const magic = "L4BV";
pub const version: u16 = 1;
pub const header_size: usize = 96;
pub const checkpoint_stride: usize = checkpoint_bits;
pub const checkpoint_record_size: usize = 16;

pub const Representation = enum(u8) {
    constant,
    dense,
    sparse,
    very_sparse,
};

const word_bits = 64;
const checkpoint_bits = 512;
const words_per_checkpoint = checkpoint_bits / word_bits;

fn wordCount(bit_count: usize) Error!usize {
    return bit_count / word_bits + @intFromBool(bit_count % word_bits != 0);
}

fn checkpointCount(bit_count: usize) Error!usize {
    if (bit_count == std.math.maxInt(usize)) return error.Overflow;
    return bit_count / checkpoint_bits + 1;
}

fn bitMask(bit: usize) u64 {
    return @as(u64, 1) << @as(u6, @intCast(bit % word_bits));
}

fn maskForWidth(width: u8) u64 {
    if (width == 0) return 0;
    if (width == word_bits) return std.math.maxInt(u64);
    return (@as(u64, 1) << @as(u6, @intCast(width))) - 1;
}

fn popcountPrefix(word: u64, bits: usize) usize {
    if (bits == 0) return 0;
    if (bits == word_bits) return @intCast(@popCount(word));
    return @intCast(@popCount(word & ((@as(u64, 1) << @as(u6, @intCast(bits))) - 1)));
}

fn selectInWord(word: u64, ordinal: usize) usize {
    var remaining = ordinal;
    var bit: usize = 0;
    while (bit < word_bits) : (bit += 1) {
        if ((word & (@as(u64, 1) << @as(u6, @intCast(bit)))) == 0) continue;
        if (remaining == 0) return bit;
        remaining -= 1;
    }
    return word_bits;
}

fn floorLog2(value: usize) u8 {
    if (value <= 1) return 0;
    return @intCast(@bitSizeOf(usize) - 1 - @clz(value));
}

fn choose(n: u8, k_: u8) u64 {
    if (k_ > n) return 0;
    const k = @min(k_, n - k_);
    var result: u128 = 1;
    var i: u16 = 1;
    while (i <= k) : (i += 1) {
        result = (result * (n - k + @as(u8, @intCast(i)))) / i;
    }
    return @intCast(result);
}

fn combinationWidth(class: u8) u8 {
    const count = choose(64, class);
    if (count <= 1) return 0;
    return @intCast(64 - @clz(count - 1));
}

fn combinadicRank(word: u64, class: u8) u64 {
    var result: u64 = 0;
    var ordinal: u8 = 1;
    var bit: u8 = 0;
    while (bit < 64) : (bit += 1) {
        if ((word & (@as(u64, 1) << @as(u6, @intCast(bit)))) != 0) {
            result += choose(bit, ordinal);
            ordinal += 1;
        }
    }
    _ = class;
    return result;
}

fn combinadicUnrank(rank: u64, class: u8) u64 {
    var remaining = rank;
    var result: u64 = 0;
    var next_high: i16 = 63;
    var ordinal: i16 = class;
    while (ordinal > 0) : (ordinal -= 1) {
        var candidate = next_high;
        while (candidate >= 0) : (candidate -= 1) {
            const value = choose(@intCast(candidate), @intCast(ordinal));
            if (value > remaining) continue;
            result |= @as(u64, 1) << @as(u6, @intCast(candidate));
            remaining -= value;
            next_high = candidate - 1;
            break;
        }
    }
    return result;
}

/// A static bitvector selected at comptime for the expected density.
///
/// `rank1(i)` is half-open: it counts set bits in `[0, i)`. `select1(k)` is
/// zero-based and returns the position of the k-th set bit. The backing
/// representation is the canonical dense, Elias--Fano, or RRR wire selected
/// by `density`; the owner merely retains those bytes and its checked view.
pub fn Bitvector(comptime density: Density) type {
    return struct {
        const Self = @This();

        owned: Owned,
        decoded: View,

        pub fn init(allocator: std.mem.Allocator, bits: []const bool) Error!Self {
            const representation: Representation = switch (density) {
                .dense => .dense,
                .sparse => .sparse,
                .very_sparse => .very_sparse,
            };
            var owned = try buildForced(allocator, bits, representation);
            errdefer owned.deinit();
            return .{ .decoded = try owned.view(), .owned = owned };
        }

        pub fn initFromPositions(allocator: std.mem.Allocator, bit_count: usize, positions: []const usize) Error!Self {
            var bits = try allocator.alloc(bool, bit_count);
            defer allocator.free(bits);
            @memset(bits, false);
            var previous: usize = 0;
            for (positions, 0..) |position, i| {
                if (position >= bit_count or (i != 0 and position <= previous)) return error.InvalidArgument;
                bits[position] = true;
                previous = position;
            }
            return init(allocator, bits);
        }

        pub fn deinit(self: *Self) void {
            self.owned.deinit();
            self.* = undefined;
        }

        pub fn len(self: *const Self) usize {
            return self.decoded.len();
        }

        pub fn count(self: *const Self) usize {
            return self.decoded.count();
        }

        pub fn get(self: *const Self, index: usize) Error!bool {
            return self.decoded.get(index);
        }

        pub fn rank1(self: *const Self, index: usize) Error!usize {
            return self.decoded.rank1(index);
        }

        pub fn rank1Inclusive(self: *const Self, index: usize) Error!usize {
            return self.decoded.rank1Inclusive(index);
        }

        pub fn select1(self: *const Self, which: usize) Error!usize {
            return self.decoded.select1(which);
        }
    };
}

const WireLayout = struct {
    directory_count: usize,
    directory_offset: usize,
    directory_len: usize,
    payload_offset: usize,
    payload_len: usize,
    total_len: usize,
};

fn wireAdd(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.Overflow;
}

fn wireMul(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch error.Overflow;
}

fn wireAlign8(value: usize) Error!usize {
    return (try wireAdd(value, 7)) & ~@as(usize, 7);
}

fn wireByteCount(bit_count: usize) Error!usize {
    if (bit_count == 0) return 0;
    const rounded = try wireAdd(bit_count, 7);
    return rounded / 8;
}

fn wireAsUsize(value: u64) Error!usize {
    return std.math.cast(usize, value) orelse error.Overflow;
}

fn wireAsU64(value: usize) Error!u64 {
    return std.math.cast(u64, value) orelse error.Overflow;
}

fn wireRead(comptime T: type, bytes: []const u8, at: usize) Error!T {
    if (at > bytes.len or bytes.len - at < @sizeOf(T)) return error.Truncated;
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

fn wireWrite(comptime T: type, bytes: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .little);
}

fn wireReadBit(bytes: []const u8, bit: usize) bool {
    return (bytes[bit / 8] & (@as(u8, 1) << @as(u3, @intCast(bit % 8)))) != 0;
}

fn wireWriteBit(bytes: []u8, bit: usize) void {
    bytes[bit / 8] |= @as(u8, 1) << @as(u3, @intCast(bit % 8));
}

fn wireReadPacked(bytes: []const u8, bit_offset: usize, width: u8) u64 {
    if (width == 0) return 0;
    var result: u64 = 0;
    var bit: usize = 0;
    while (bit < width) : (bit += 1) {
        if (wireReadBit(bytes, bit_offset + bit))
            result |= @as(u64, 1) << @as(u6, @intCast(bit));
    }
    return result;
}

fn wireWritePacked(bytes: []u8, bit_offset: usize, width: u8, value: u64) void {
    var bit: usize = 0;
    while (bit < width) : (bit += 1) {
        if ((value & (@as(u64, 1) << @as(u6, @intCast(bit)))) != 0)
            wireWriteBit(bytes, bit_offset + bit);
    }
}

fn wirePaddingIsZero(bytes: []const u8, used_bits: usize) bool {
    if (used_bits == 0) {
        for (bytes) |byte| if (byte != 0) return false;
        return true;
    }
    const remainder = used_bits % 8;
    if (remainder == 0) return true;
    if (bytes.len == 0) return false;
    const mask: u8 = @as(u8, 0xff) << @as(u3, @intCast(remainder));
    return (bytes[bytes.len - 1] & mask) == 0;
}

fn wireCheckpointCount(bit_count: usize) Error!usize {
    return checkpointCount(bit_count);
}

fn wireLayoutFor(bit_count: usize, payload_len: usize) Error!WireLayout {
    const directory_count = try wireCheckpointCount(bit_count);
    const directory_len = try wireMul(directory_count, checkpoint_record_size);
    const directory_end = try wireAdd(header_size, directory_len);
    const payload_offset = try wireAlign8(directory_end);
    const total_len = try wireAdd(payload_offset, payload_len);
    return .{
        .directory_count = directory_count,
        .directory_offset = header_size,
        .directory_len = directory_len,
        .payload_offset = payload_offset,
        .payload_len = payload_len,
        .total_len = total_len,
    };
}

fn wireLowBits(bit_count: usize, one_count: usize) u8 {
    if (one_count == 0) return 0;
    return @min(floorLog2(bit_count / one_count), @as(u8, @intCast(@bitSizeOf(usize) - 1)));
}

fn wireHighBitCount(bit_count: usize, one_count: usize, low_bits: u8) Error!usize {
    if (one_count == 0) return 0;
    if (bit_count == 0) return error.InvalidArgument;
    const max_high = bit_count - 1 >> @as(u6, @intCast(low_bits));
    return wireAdd(max_high, one_count);
}

fn wireSelectCount(one_count: usize) Error!usize {
    if (one_count == 0) return 0;
    const rounded = try wireAdd(one_count, 63);
    return rounded / 64;
}

fn wireRrrClassAt(bits: []const bool, block: usize) u8 {
    const start = block * word_bits;
    const end = @min(bits.len, start + word_bits);
    var word: u64 = 0;
    for (bits[start..end], 0..) |set, bit| {
        if (set) word |= @as(u64, 1) << @as(u6, @intCast(bit));
    }
    return @intCast(@popCount(word));
}

fn wireRrrOffsetPrefix(bits: []const bool, block_count: usize) Error!usize {
    var total: usize = 0;
    for (0..block_count) |block| total = try wireAdd(total, combinationWidth(wireRrrClassAt(bits, block)));
    return total;
}

fn wireRrrOffsetBits(bits: []const bool) Error!usize {
    const blocks = try wordCount(bits.len);
    return wireRrrOffsetPrefix(bits, blocks);
}

fn wireCandidatePayloadLen(bits: []const bool, one_count: usize, representation: Representation) Error!usize {
    return switch (representation) {
        .constant => blk: {
            if (one_count != 0 and one_count != bits.len) return error.NotApplicable;
            break :blk 8;
        },
        .dense => blk: {
            const words = try wordCount(bits.len);
            break :blk try wireAdd(32, try wireMul(words, 8));
        },
        .sparse => blk: {
            const low_bits = wireLowBits(bits.len, one_count);
            const low_len = try wireByteCount(try wireMul(one_count, low_bits));
            const high_len = try wireByteCount(try wireHighBitCount(bits.len, one_count, low_bits));
            const select_len = try wireMul(try wireSelectCount(one_count), 8);
            const high_at = try wireAlign8(try wireAdd(64, low_len));
            const select_at = try wireAlign8(try wireAdd(high_at, high_len));
            break :blk try wireAdd(select_at, select_len);
        },
        .very_sparse => blk: {
            const classes_len = try wordCount(bits.len);
            const offsets_len = try wireByteCount(try wireRrrOffsetBits(bits));
            const offsets_at = try wireAlign8(try wireAdd(48, classes_len));
            break :blk try wireAdd(offsets_at, offsets_len);
        },
    };
}

fn wireWriteHeader(bytes: []u8, representation: Representation, parameters: u16, bit_count: usize, one_count: usize, layout: WireLayout) Error!void {
    if (bytes.len != layout.total_len) return error.InvalidEncoding;
    @memcpy(bytes[0..4], magic);
    wireWrite(u16, bytes, 4, version);
    wireWrite(u16, bytes, 6, @as(u16, @intCast(header_size)));
    bytes[8] = @intFromEnum(representation);
    bytes[9] = 0;
    wireWrite(u16, bytes, 10, parameters);
    wireWrite(u32, bytes, 12, 0);
    wireWrite(u64, bytes, 16, try wireAsU64(bit_count));
    wireWrite(u64, bytes, 24, try wireAsU64(one_count));
    wireWrite(u64, bytes, 32, try wireAsU64(checkpoint_stride));
    wireWrite(u64, bytes, 40, try wireAsU64(layout.directory_count));
    wireWrite(u64, bytes, 48, try wireAsU64(layout.directory_offset));
    wireWrite(u64, bytes, 56, try wireAsU64(layout.directory_len));
    wireWrite(u64, bytes, 64, try wireAsU64(layout.payload_offset));
    wireWrite(u64, bytes, 72, try wireAsU64(layout.payload_len));
    wireWrite(u64, bytes, 80, try wireAsU64(layout.total_len));
    wireWrite(u64, bytes, 88, 0);
}

fn wireWriteDirectory(bytes: []u8, bits: []const bool, representation: Representation, layout: WireLayout) Error!void {
    var cursor: usize = 0;
    var rank: usize = 0;
    for (0..layout.directory_count) |checkpoint| {
        const start = @min(try wireMul(checkpoint, checkpoint_stride), bits.len);
        while (cursor < start) : (cursor += 1) {
            if (bits[cursor]) rank += 1;
        }
        const at = layout.directory_offset + checkpoint * checkpoint_record_size;
        const auxiliary = switch (representation) {
            .constant => 0,
            .dense => start / word_bits,
            .very_sparse => try wireRrrOffsetPrefix(bits, start / word_bits),
            .sparse => rank,
        };
        wireWrite(u64, bytes, at, try wireAsU64(rank));
        wireWrite(u64, bytes, at + 8, try wireAsU64(auxiliary));
    }
}

fn encodeWireCandidate(allocator: std.mem.Allocator, bits: []const bool, one_count: usize, representation: Representation) Error![]u8 {
    const payload_len = try wireCandidatePayloadLen(bits, one_count, representation);
    const layout = try wireLayoutFor(bits.len, payload_len);
    const result = allocator.alloc(u8, layout.total_len) catch return error.OutOfMemory;
    errdefer allocator.free(result);
    @memset(result, 0);
    const parameters: u16 = switch (representation) {
        .constant => if (one_count == bits.len and bits.len != 0) 1 else 0,
        .dense, .very_sparse => 0,
        .sparse => wireLowBits(bits.len, one_count),
    };
    try wireWriteHeader(result, representation, parameters, bits.len, one_count, layout);
    try wireWriteDirectory(result, bits, representation, layout);
    const payload = result[layout.payload_offset .. layout.payload_offset + layout.payload_len];

    switch (representation) {
        .constant => {
            wireWrite(u64, payload, 0, @as(u64, parameters));
        },
        .dense => {
            const words = try wordCount(bits.len);
            wireWrite(u64, payload, 0, try wireAsU64(words));
            wireWrite(u64, payload, 8, 32);
            wireWrite(u64, payload, 16, try wireAsU64(try wireMul(words, 8)));
            wireWrite(u64, payload, 24, 0);
            const words_bytes = payload[32..][0 .. words * 8];
            for (bits, 0..) |set, index| {
                if (!set) continue;
                const at = index / word_bits * 8;
                const word = wireRead(u64, words_bytes, at) catch unreachable;
                wireWrite(u64, words_bytes, at, word | bitMask(index));
            }
        },
        .sparse => {
            const low_bits = wireLowBits(bits.len, one_count);
            const low_bit_count = try wireMul(one_count, low_bits);
            const high_bit_count = try wireHighBitCount(bits.len, one_count, low_bits);
            const low_len = try wireByteCount(low_bit_count);
            const high_len = try wireByteCount(high_bit_count);
            const select_count = try wireSelectCount(one_count);
            const select_len = try wireMul(select_count, 8);
            const high_at = try wireAlign8(try wireAdd(64, low_len));
            const select_at = try wireAlign8(try wireAdd(high_at, high_len));
            wireWrite(u64, payload, 0, try wireAsU64(low_bit_count));
            wireWrite(u64, payload, 8, try wireAsU64(high_bit_count));
            wireWrite(u64, payload, 16, try wireAsU64(64));
            wireWrite(u64, payload, 24, try wireAsU64(low_len));
            wireWrite(u64, payload, 32, try wireAsU64(high_at));
            wireWrite(u64, payload, 40, try wireAsU64(high_len));
            wireWrite(u64, payload, 48, try wireAsU64(select_at));
            wireWrite(u64, payload, 56, try wireAsU64(select_len));
            const low = payload[64..][0..low_len];
            const high = payload[high_at..][0..high_len];
            const select = payload[select_at..][0..select_len];
            var ordinal: usize = 0;
            for (bits, 0..) |set, position| {
                if (!set) continue;
                const low_value = position & @as(usize, @intCast(maskForWidth(low_bits)));
                wireWritePacked(low, ordinal * low_bits, low_bits, @intCast(low_value));
                const high_position = (position >> @as(u6, @intCast(low_bits))) + ordinal;
                wireWriteBit(high, high_position);
                if (ordinal % 64 == 0)
                    wireWrite(u64, select, ordinal / 64 * 8, try wireAsU64(high_position));
                ordinal += 1;
            }
        },
        .very_sparse => {
            const block_count = try wordCount(bits.len);
            const offset_bits = try wireRrrOffsetBits(bits);
            const classes_at: usize = 48;
            const classes_len = block_count;
            const offsets_at = try wireAlign8(try wireAdd(classes_at, classes_len));
            const offsets_len = try wireByteCount(offset_bits);
            wireWrite(u64, payload, 0, try wireAsU64(block_count));
            wireWrite(u64, payload, 8, try wireAsU64(classes_at));
            wireWrite(u64, payload, 16, try wireAsU64(classes_len));
            wireWrite(u64, payload, 24, try wireAsU64(offset_bits));
            wireWrite(u64, payload, 32, try wireAsU64(offsets_at));
            wireWrite(u64, payload, 40, try wireAsU64(offsets_len));
            const classes = payload[classes_at..][0..classes_len];
            const offsets = payload[offsets_at..][0..offsets_len];
            var offset: usize = 0;
            for (0..block_count) |block| {
                const start = block * word_bits;
                const end = @min(bits.len, start + word_bits);
                var word: u64 = 0;
                for (bits[start..end], 0..) |set, bit| {
                    if (set) word |= @as(u64, 1) << @as(u6, @intCast(bit));
                }
                const class: u8 = @intCast(@popCount(word));
                classes[block] = class;
                const width = combinationWidth(class);
                wireWritePacked(offsets, offset, width, combinadicRank(word, class));
                offset += width;
            }
        },
    }
    return result;
}

fn wireCountOnes(bits: []const bool) Error!usize {
    var count: usize = 0;
    for (bits) |set| {
        if (set) count = try wireAdd(count, 1);
    }
    return count;
}

fn buildWireAdaptive(allocator: std.mem.Allocator, bits: []const bool) Error!struct { bytes: []u8, representation: Representation } {
    const one_count = try wireCountOnes(bits);
    const order = [_]Representation{ .constant, .dense, .sparse, .very_sparse };
    const Candidate = struct { bytes: []u8, representation: Representation };
    var candidates: [order.len]Candidate = undefined;
    var candidate_count: usize = 0;
    errdefer for (candidates[0..candidate_count]) |candidate| allocator.free(candidate.bytes);

    for (order) |representation| {
        const bytes = encodeWireCandidate(allocator, bits, one_count, representation) catch |err| switch (err) {
            error.NotApplicable => continue,
            else => return err,
        };
        candidates[candidate_count] = .{ .bytes = bytes, .representation = representation };
        candidate_count += 1;
    }
    var winner: usize = 0;
    for (1..candidate_count) |index| {
        if (candidates[index].bytes.len < candidates[winner].bytes.len) winner = index;
    }
    const selected = candidates[winner];
    for (candidates[0..candidate_count], 0..) |candidate, index| if (index != winner) allocator.free(candidate.bytes);
    return .{ .bytes = selected.bytes, .representation = selected.representation };
}

pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    chosen: Representation,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn representation(self: *const Owned) Representation {
        return self.chosen;
    }

    pub fn view(self: *const Owned) Error!View {
        return View.open(self.bytes);
    }
};

/// Build the measured minimum wire representation for `bits`.
pub fn build(allocator: std.mem.Allocator, bits: []const bool) Error!Owned {
    const result = try buildWireAdaptive(allocator, bits);
    return .{ .allocator = allocator, .bytes = result.bytes, .chosen = result.representation };
}

pub fn open(bytes: []const u8) Error!View {
    return View.open(bytes);
}

/// Encode one candidate directly.  This is useful for diagnostics and makes
/// the adaptive choice testable without exposing any representation internals.
pub fn buildForced(allocator: std.mem.Allocator, bits: []const bool, representation: Representation) Error!Owned {
    const one_count = try wireCountOnes(bits);
    const bytes = try encodeWireCandidate(allocator, bits, one_count, representation);
    return .{ .allocator = allocator, .bytes = bytes, .chosen = representation };
}

pub fn measuredSize(bits: []const bool, representation: Representation) Error!usize {
    const one_count = try wireCountOnes(bits);
    const payload_len = try wireCandidatePayloadLen(bits, one_count, representation);
    return (try wireLayoutFor(bits.len, payload_len)).total_len;
}

/// Mutable caller-allocator builder.  The final byte string owns no builder
/// state, so the builder may be deinitialised immediately after finish().
pub const Builder = struct {
    allocator: std.mem.Allocator,
    bits: std.ArrayList(bool) = .empty,
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn initWithBits(allocator: std.mem.Allocator, bits: []const bool) Error!Builder {
        var result = init(allocator);
        errdefer result.deinit();
        try result.appendSlice(bits);
        return result;
    }

    pub fn deinit(self: *Builder) void {
        self.bits.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *Builder, set: bool) Error!void {
        if (self.finished) return error.InvalidEncoding;
        self.bits.append(self.allocator, set) catch return error.OutOfMemory;
    }

    pub fn appendSlice(self: *Builder, bits: []const bool) Error!void {
        if (self.finished) return error.InvalidEncoding;
        self.bits.appendSlice(self.allocator, bits) catch return error.OutOfMemory;
    }

    pub fn finish(self: *Builder) Error!Owned {
        if (self.finished) return error.InvalidEncoding;
        self.finished = true;
        const result = try buildWireAdaptive(self.allocator, self.bits.items);
        return .{ .allocator = self.allocator, .bytes = result.bytes, .chosen = result.representation };
    }
};

fn viewDirectoryRank(self: *const View, index: usize) Error!usize {
    const at = try wireAdd(self.directory_at, try wireMul(index, checkpoint_record_size));
    return wireAsUsize(try wireRead(u64, self.bytes, at));
}

fn viewDirectoryAux(self: *const View, index: usize) Error!usize {
    const at = try wireAdd(self.directory_at, try wireMul(index, checkpoint_record_size));
    return wireAsUsize(try wireRead(u64, self.bytes, try wireAdd(at, 8)));
}

/// Allocation-free reader for the wire representation.  Every offset,
/// length, count, alignment gap, and representation-specific directory is
/// checked by open() before any public operation can consult mapped data.
pub const View = struct {
    bytes: []const u8,
    chosen: Representation,
    bit_count_: usize,
    one_count_: usize,
    checkpoint_count_: usize,
    parameters_: u16,
    directory_at: usize,
    payload_at: usize,
    payload_len_: usize,

    constant_value_: bool = false,
    dense_words_at_: usize = 0,
    dense_word_count_: usize = 0,

    sparse_low_at_: usize = 0,
    sparse_low_len_: usize = 0,
    sparse_high_at_: usize = 0,
    sparse_high_len_: usize = 0,
    sparse_high_bit_count_: usize = 0,
    sparse_select_at_: usize = 0,
    sparse_select_count_: usize = 0,

    rrr_classes_at_: usize = 0,
    rrr_block_count_: usize = 0,
    rrr_offsets_at_: usize = 0,
    rrr_offsets_len_: usize = 0,
    rrr_offset_bit_count_: usize = 0,

    pub fn open(bytes: []const u8) Error!View {
        if (bytes.len < header_size) return error.Truncated;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
        if (try wireRead(u16, bytes, 4) != version) return error.UnsupportedVersion;
        if (try wireRead(u16, bytes, 6) != header_size) return error.InvalidEncoding;
        if (bytes[9] != 0 or try wireRead(u32, bytes, 12) != 0 or try wireRead(u64, bytes, 88) != 0)
            return error.InvalidEncoding;

        const raw_representation = bytes[8];
        if (raw_representation > @intFromEnum(Representation.very_sparse)) return error.UnsupportedRepresentation;
        const rep: Representation = @enumFromInt(raw_representation);
        const parameters = try wireRead(u16, bytes, 10);
        const bit_count = try wireAsUsize(try wireRead(u64, bytes, 16));
        const one_count = try wireAsUsize(try wireRead(u64, bytes, 24));
        if (one_count > bit_count) return error.InvalidEncoding;
        const stride = try wireAsUsize(try wireRead(u64, bytes, 32));
        if (stride != checkpoint_stride) return error.InvalidEncoding;
        const checkpoint_count = try wireAsUsize(try wireRead(u64, bytes, 40));
        if (checkpoint_count != try wireCheckpointCount(bit_count)) return error.InvalidEncoding;

        const directory_at = try wireAsUsize(try wireRead(u64, bytes, 48));
        const directory_len = try wireAsUsize(try wireRead(u64, bytes, 56));
        if (directory_at != header_size or directory_len != try wireMul(checkpoint_count, checkpoint_record_size))
            return error.InvalidEncoding;
        const directory_end = try wireAdd(directory_at, directory_len);
        const payload_at = try wireAsUsize(try wireRead(u64, bytes, 64));
        if (payload_at != try wireAlign8(directory_end) or payload_at % 8 != 0) return error.InvalidEncoding;
        const payload_len = try wireAsUsize(try wireRead(u64, bytes, 72));
        const total_len = try wireAsUsize(try wireRead(u64, bytes, 80));
        const payload_end = try wireAdd(payload_at, payload_len);
        if (payload_at > bytes.len or payload_end > bytes.len) return error.Truncated;
        if (total_len != bytes.len or payload_end != total_len) return error.InvalidEncoding;
        if (!wirePaddingIsZero(bytes[directory_end..payload_at], 0)) return error.InvalidEncoding;

        var result = View{
            .bytes = bytes,
            .chosen = rep,
            .bit_count_ = bit_count,
            .one_count_ = one_count,
            .checkpoint_count_ = checkpoint_count,
            .parameters_ = parameters,
            .directory_at = directory_at,
            .payload_at = payload_at,
            .payload_len_ = payload_len,
        };
        switch (rep) {
            .constant => try result.validateConstant(),
            .dense => try result.validateDense(),
            .sparse => try result.validateSparse(),
            .very_sparse => try result.validateRrr(),
        }
        try result.validateDirectory();
        return result;
    }

    pub fn len(self: *const View) usize {
        return self.bit_count_;
    }

    pub fn count(self: *const View) usize {
        return self.one_count_;
    }

    pub fn representation(self: *const View) Representation {
        return self.chosen;
    }

    pub fn get(self: *const View, index: usize) Error!bool {
        if (index >= self.bit_count_) return error.OutOfBounds;
        return switch (self.chosen) {
            .constant => self.constant_value_,
            .dense => (try self.denseWord(index / word_bits) & bitMask(index)) != 0,
            .sparse => blk: {
                const ordinal = try self.sparseRank(index);
                break :blk ordinal < self.one_count_ and (try self.sparsePositionAt(ordinal)) == index;
            },
            .very_sparse => (try self.rrrWord(index / word_bits) & bitMask(index)) != 0,
        };
    }

    pub fn rank1(self: *const View, index: usize) Error!usize {
        if (index > self.bit_count_) return error.OutOfBounds;
        return switch (self.chosen) {
            .constant => if (self.constant_value_) index else 0,
            .dense => self.denseRank(index),
            .sparse => self.sparseRank(index),
            .very_sparse => self.rrrRank(index),
        };
    }

    pub fn rank1Inclusive(self: *const View, index: usize) Error!usize {
        if (index >= self.bit_count_) return error.OutOfBounds;
        return self.rank1(index + 1);
    }

    pub fn select1(self: *const View, which: usize) Error!usize {
        if (which >= self.one_count_) return error.OutOfBounds;
        return switch (self.chosen) {
            .constant => which,
            .dense => self.denseSelect(which),
            .sparse => self.sparsePositionAt(which),
            .very_sparse => self.rrrSelect(which),
        };
    }

    fn payload(self: *const View) []const u8 {
        return self.bytes[self.payload_at .. self.payload_at + self.payload_len_];
    }

    fn validateConstant(self: *View) Error!void {
        if (self.parameters_ > 1 or self.payload_len_ != 8) return error.InvalidEncoding;
        const payload_bytes = self.payload();
        if (try wireRead(u64, payload_bytes, 0) != self.parameters_) return error.InvalidEncoding;
        if (self.one_count_ != if (self.parameters_ == 1) self.bit_count_ else 0) return error.InvalidEncoding;
        self.constant_value_ = self.parameters_ == 1;
    }

    fn validateDense(self: *View) Error!void {
        if (self.parameters_ != 0 or self.payload_len_ < 32) return error.InvalidEncoding;
        const payload_bytes = self.payload();
        const word_count = try wireAsUsize(try wireRead(u64, payload_bytes, 0));
        const words_at = try wireAsUsize(try wireRead(u64, payload_bytes, 8));
        const words_len = try wireAsUsize(try wireRead(u64, payload_bytes, 16));
        if (word_count != try wordCount(self.bit_count_) or words_at != 32 or
            words_len != try wireMul(word_count, 8) or self.payload_len_ != try wireAdd(words_at, words_len))
            return error.InvalidEncoding;
        if (try wireRead(u64, payload_bytes, 24) != 0) return error.InvalidEncoding;
        const words = payload_bytes[words_at..][0..words_len];
        var total: usize = 0;
        for (0..word_count) |word_index| {
            const word = try wireRead(u64, words, try wireMul(word_index, 8));
            if (try wireAdd(word_index, 1) == word_count and self.bit_count_ % word_bits != 0 and
                word >> @as(u6, @intCast(self.bit_count_ % word_bits)) != 0)
                return error.InvalidEncoding;
            total = try wireAdd(total, @intCast(@popCount(word)));
        }
        if (total != self.one_count_) return error.InvalidEncoding;
        self.dense_words_at_ = self.payload_at + words_at;
        self.dense_word_count_ = word_count;
    }

    fn validateSparse(self: *View) Error!void {
        const low_bits = wireLowBits(self.bit_count_, self.one_count_);
        if (self.parameters_ != low_bits or self.payload_len_ < 64) return error.InvalidEncoding;
        const payload_bytes = self.payload();
        const low_bit_count = try wireAsUsize(try wireRead(u64, payload_bytes, 0));
        const high_bit_count = try wireAsUsize(try wireRead(u64, payload_bytes, 8));
        const low_at = try wireAsUsize(try wireRead(u64, payload_bytes, 16));
        const low_len = try wireAsUsize(try wireRead(u64, payload_bytes, 24));
        const high_at = try wireAsUsize(try wireRead(u64, payload_bytes, 32));
        const high_len = try wireAsUsize(try wireRead(u64, payload_bytes, 40));
        const select_at = try wireAsUsize(try wireRead(u64, payload_bytes, 48));
        const select_len = try wireAsUsize(try wireRead(u64, payload_bytes, 56));
        const expected_high_bits = try wireHighBitCount(self.bit_count_, self.one_count_, low_bits);
        const expected_low_bits = try wireMul(self.one_count_, low_bits);
        const expected_low_len = try wireByteCount(expected_low_bits);
        const expected_high_len = try wireByteCount(expected_high_bits);
        const expected_select_count = try wireSelectCount(self.one_count_);
        const expected_select_len = try wireMul(expected_select_count, 8);
        const expected_high_at = try wireAlign8(try wireAdd(64, expected_low_len));
        const expected_select_at = try wireAlign8(try wireAdd(expected_high_at, expected_high_len));
        if (low_bit_count != expected_low_bits or high_bit_count != expected_high_bits or
            low_at != 64 or low_len != expected_low_len or high_at != expected_high_at or
            high_len != expected_high_len or select_at != expected_select_at or
            select_len != expected_select_len or self.payload_len_ != try wireAdd(select_at, select_len))
            return error.InvalidEncoding;
        const low = payload_bytes[low_at..][0..low_len];
        const high = payload_bytes[high_at..][0..high_len];
        if (!wirePaddingIsZero(payload_bytes[low_at + low_len .. high_at], 0) or
            !wirePaddingIsZero(payload_bytes[high_at + high_len .. select_at], 0))
            return error.InvalidEncoding;
        if (!wirePaddingIsZero(low, low_bit_count) or !wirePaddingIsZero(high, high_bit_count)) return error.InvalidEncoding;

        var ordinal: usize = 0;
        var previous_position: ?usize = null;
        var bit: usize = 0;
        while (bit < high_bit_count) : (bit += 1) {
            if (!wireReadBit(high, bit)) continue;
            if (bit < ordinal) return error.InvalidEncoding;
            const high_value = bit - ordinal;
            const low_value = wireReadPacked(low, ordinal * low_bits, low_bits);
            const max_usize: usize = std.math.maxInt(usize);
            if (low_bits != 0 and high_value > (max_usize >> @as(u6, @intCast(low_bits)))) return error.InvalidEncoding;
            const position = (high_value << @as(u6, @intCast(low_bits))) | @as(usize, @intCast(low_value));
            if (position >= self.bit_count_ or (previous_position != null and position <= previous_position.?)) return error.InvalidEncoding;
            if (ordinal % 64 == 0) {
                const select_entry = try wireAdd(select_at, try wireMul(ordinal / 64, 8));
                if (try wireRead(u64, payload_bytes, select_entry) != try wireAsU64(bit)) return error.InvalidEncoding;
            }
            previous_position = position;
            ordinal += 1;
        }
        if (ordinal != self.one_count_) return error.InvalidEncoding;
        self.sparse_low_at_ = self.payload_at + low_at;
        self.sparse_low_len_ = low_len;
        self.sparse_high_at_ = self.payload_at + high_at;
        self.sparse_high_len_ = high_len;
        self.sparse_high_bit_count_ = high_bit_count;
        self.sparse_select_at_ = self.payload_at + select_at;
        self.sparse_select_count_ = expected_select_count;
    }

    fn validateRrr(self: *View) Error!void {
        if (self.parameters_ != 0 or self.payload_len_ < 48) return error.InvalidEncoding;
        const payload_bytes = self.payload();
        const block_count = try wireAsUsize(try wireRead(u64, payload_bytes, 0));
        const classes_at = try wireAsUsize(try wireRead(u64, payload_bytes, 8));
        const classes_len = try wireAsUsize(try wireRead(u64, payload_bytes, 16));
        const offset_bit_count = try wireAsUsize(try wireRead(u64, payload_bytes, 24));
        const offsets_at = try wireAsUsize(try wireRead(u64, payload_bytes, 32));
        const offsets_len = try wireAsUsize(try wireRead(u64, payload_bytes, 40));
        const expected_blocks = try wordCount(self.bit_count_);
        if (block_count != expected_blocks or classes_at != 48 or classes_len != block_count or
            offsets_at != try wireAlign8(try wireAdd(classes_at, classes_len)) or
            offsets_len != try wireByteCount(offset_bit_count) or
            self.payload_len_ != try wireAdd(offsets_at, offsets_len)) return error.InvalidEncoding;
        const classes = payload_bytes[classes_at..][0..classes_len];
        const offsets = payload_bytes[offsets_at..][0..offsets_len];
        if (!wirePaddingIsZero(payload_bytes[classes_at + classes_len .. offsets_at], 0)) return error.InvalidEncoding;
        var total: usize = 0;
        var expected_offset_bits: usize = 0;
        for (0..block_count) |block| {
            const class = classes[block];
            if (class > 64) return error.InvalidEncoding;
            const width = combinationWidth(class);
            const combinations = choose(64, class);
            const code = wireReadPacked(offsets, expected_offset_bits, width);
            if (combinations == 0 or code >= combinations) return error.InvalidEncoding;
            const word = combinadicUnrank(code, class);
            const block_start = try wireMul(block, word_bits);
            const used = @min(self.bit_count_ - @min(self.bit_count_, block_start), word_bits);
            if (used != word_bits and used != 0 and word >> @as(u6, @intCast(used)) != 0) return error.InvalidEncoding;
            total = try wireAdd(total, class);
            expected_offset_bits = try wireAdd(expected_offset_bits, width);
        }
        if (total != self.one_count_ or expected_offset_bits != offset_bit_count or
            !wirePaddingIsZero(offsets, offset_bit_count)) return error.InvalidEncoding;
        self.rrr_classes_at_ = self.payload_at + classes_at;
        self.rrr_block_count_ = block_count;
        self.rrr_offsets_at_ = self.payload_at + offsets_at;
        self.rrr_offsets_len_ = offsets_len;
        self.rrr_offset_bit_count_ = offset_bit_count;
    }

    fn validateDirectory(self: *const View) Error!void {
        switch (self.chosen) {
            .constant => {
                for (0..self.checkpoint_count_) |index| {
                    const target = @min(try wireMul(index, checkpoint_stride), self.bit_count_);
                    const expected = if (self.constant_value_) target else 0;
                    if (try viewDirectoryRank(self, index) != expected or try viewDirectoryAux(self, index) != 0)
                        return error.InvalidEncoding;
                }
            },
            .dense => {
                var word: usize = 0;
                var rank_count: usize = 0;
                for (0..self.checkpoint_count_) |index| {
                    const target = @min(try wireMul(index, checkpoint_stride), self.bit_count_);
                    const target_word = target / word_bits;
                    while (word < target_word) : (word += 1)
                        rank_count += @intCast(@popCount(try self.denseWord(word)));
                    if (try viewDirectoryRank(self, index) != rank_count or try viewDirectoryAux(self, index) != target_word)
                        return error.InvalidEncoding;
                }
            },
            .very_sparse => {
                var block: usize = 0;
                var rank_count: usize = 0;
                var offset_count: usize = 0;
                for (0..self.checkpoint_count_) |index| {
                    const target = @min(try wireMul(index, checkpoint_stride), self.bit_count_);
                    const target_block = target / word_bits;
                    while (block < target_block) : (block += 1) {
                        rank_count += self.rrrClass(block);
                        offset_count += combinationWidth(self.rrrClass(block));
                    }
                    if (try viewDirectoryRank(self, index) != rank_count or try viewDirectoryAux(self, index) != offset_count)
                        return error.InvalidEncoding;
                }
            },
            .sparse => {
                var ordinal: usize = 0;
                var next_position: ?usize = if (self.one_count_ == 0) null else try self.sparsePositionAt(0);
                var rank_count: usize = 0;
                for (0..self.checkpoint_count_) |index| {
                    const target = @min(try wireMul(index, checkpoint_stride), self.bit_count_);
                    while (next_position != null and next_position.? < target) {
                        ordinal += 1;
                        rank_count += 1;
                        next_position = if (ordinal < self.one_count_) try self.sparsePositionAt(ordinal) else null;
                    }
                    if (try viewDirectoryRank(self, index) != rank_count or try viewDirectoryAux(self, index) != rank_count)
                        return error.InvalidEncoding;
                }
            },
        }
    }

    fn directoryCheckpointForRank(self: *const View, wanted: usize) Error!usize {
        var lo: usize = 0;
        var hi: usize = self.checkpoint_count_;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (try viewDirectoryRank(self, mid) <= wanted) lo = mid else hi = mid;
        }
        return lo;
    }

    fn denseWord(self: *const View, word: usize) Error!u64 {
        if (word >= self.dense_word_count_) return error.InvalidEncoding;
        const at = try wireAdd(self.dense_words_at_, try wireMul(word, 8));
        return wireRead(u64, self.bytes, at);
    }

    fn denseRank(self: *const View, index: usize) Error!usize {
        const checkpoint = index / checkpoint_stride;
        var total = try viewDirectoryRank(self, checkpoint);
        var word = try wireMul(checkpoint, words_per_checkpoint);
        const target_word = index / word_bits;
        while (word < target_word) : (word += 1) total += @intCast(@popCount(try self.denseWord(word)));
        if (index % word_bits != 0 and target_word < self.dense_word_count_)
            total += popcountPrefix(try self.denseWord(target_word), index % word_bits);
        return total;
    }

    fn denseSelect(self: *const View, which: usize) Error!usize {
        const checkpoint = try self.directoryCheckpointForRank(which);
        var seen = try viewDirectoryRank(self, checkpoint);
        const end_word = @min(self.dense_word_count_, try wireMul(try wireAdd(checkpoint, 1), words_per_checkpoint));
        var word = try wireMul(checkpoint, words_per_checkpoint);
        while (word < end_word) : (word += 1) {
            const value = try self.denseWord(word);
            const class: usize = @intCast(@popCount(value));
            if (which < seen + class) {
                const result = word * word_bits + selectInWord(value, which - seen);
                if (result >= self.bit_count_) return error.InvalidEncoding;
                return result;
            }
            seen += class;
        }
        return error.InvalidEncoding;
    }

    fn sparseHighSelect(self: *const View, ordinal: usize) Error!usize {
        if (ordinal >= self.one_count_) return error.OutOfBounds;
        const checkpoint = ordinal / 64;
        const select_at = try wireAdd(self.sparse_select_at_, try wireMul(checkpoint, 8));
        var position = try wireAsUsize(try wireRead(u64, self.bytes, select_at));
        var seen = try wireMul(checkpoint, 64);
        while (position < self.sparse_high_bit_count_) : (position += 1) {
            if (!wireReadBit(self.bytes[self.sparse_high_at_ .. self.sparse_high_at_ + self.sparse_high_len_], position)) continue;
            if (seen == ordinal) return position;
            seen += 1;
        }
        return error.InvalidEncoding;
    }

    fn sparsePositionAt(self: *const View, ordinal: usize) Error!usize {
        const high_position = try self.sparseHighSelect(ordinal);
        const high_value = high_position - ordinal;
        const low_bits: u8 = @intCast(self.parameters_);
        const low_end = try wireAdd(self.sparse_low_at_, self.sparse_low_len_);
        const low_offset = try wireMul(ordinal, low_bits);
        const low = wireReadPacked(self.bytes[self.sparse_low_at_..low_end], low_offset, low_bits);
        const max_usize: usize = std.math.maxInt(usize);
        if (low_bits != 0 and high_value > (max_usize >> @as(u6, @intCast(low_bits)))) return error.InvalidEncoding;
        const result = (high_value << @as(u6, @intCast(low_bits))) | @as(usize, @intCast(low));
        if (result >= self.bit_count_) return error.InvalidEncoding;
        return result;
    }

    fn sparseRank(self: *const View, index: usize) Error!usize {
        var lo: usize = 0;
        var hi: usize = self.one_count_;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if ((try self.sparsePositionAt(mid)) < index) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    fn rrrClass(self: *const View, block: usize) u8 {
        return self.bytes[self.rrr_classes_at_ + block];
    }

    fn rrrOffsetAt(self: *const View, block: usize) Error!usize {
        const checkpoint = block / words_per_checkpoint;
        var offset = try viewDirectoryAux(self, checkpoint);
        var index = try wireMul(checkpoint, words_per_checkpoint);
        while (index < block) : (index += 1) offset += combinationWidth(self.rrrClass(index));
        return offset;
    }

    fn rrrWord(self: *const View, block: usize) Error!u64 {
        if (block >= self.rrr_block_count_) return error.InvalidEncoding;
        const class = self.rrrClass(block);
        const width = combinationWidth(class);
        const code = wireReadPacked(self.bytes[self.rrr_offsets_at_ .. self.rrr_offsets_at_ + self.rrr_offsets_len_], try self.rrrOffsetAt(block), width);
        if (code >= choose(64, class)) return error.InvalidEncoding;
        return combinadicUnrank(code, class);
    }

    fn rrrRank(self: *const View, index: usize) Error!usize {
        const checkpoint = index / checkpoint_stride;
        var total = try viewDirectoryRank(self, checkpoint);
        var block = try wireMul(checkpoint, words_per_checkpoint);
        const target_block = index / word_bits;
        while (block < target_block) : (block += 1) total += self.rrrClass(block);
        if (index % word_bits != 0 and target_block < self.rrr_block_count_)
            total += popcountPrefix(try self.rrrWord(target_block), index % word_bits);
        return total;
    }

    fn rrrSelect(self: *const View, which: usize) Error!usize {
        const checkpoint = try self.directoryCheckpointForRank(which);
        var seen = try viewDirectoryRank(self, checkpoint);
        const end_block = @min(self.rrr_block_count_, try wireMul(try wireAdd(checkpoint, 1), words_per_checkpoint));
        var block = try wireMul(checkpoint, words_per_checkpoint);
        while (block < end_block) : (block += 1) {
            const class = self.rrrClass(block);
            if (which < seen + class) {
                const result = block * word_bits + selectInWord(try self.rrrWord(block), which - seen);
                if (result >= self.bit_count_) return error.InvalidEncoding;
                return result;
            }
            seen += class;
        }
        return error.InvalidEncoding;
    }
};

/// A source adapter for callers that want to expose a mapped section without
/// copying it.  Custom sources are expected to authenticate the requested
/// range in `bytes`; the raw-slice specialization below remains allocation
/// free and performs ordinary bounds checks.
pub const SliceSource = struct {
    bytes_: []const u8,

    pub fn init(input: []const u8) SliceSource {
        return .{ .bytes_ = input };
    }

    pub fn len(self: *const SliceSource) usize {
        return self.bytes_.len;
    }

    pub fn bytes(self: *SliceSource, offset: usize, length: usize) Error![]const u8 {
        if (offset > self.bytes_.len or length > self.bytes_.len - offset) return error.Truncated;
        return self.bytes_[offset..][0..length];
    }
};

fn sourceLen(comptime Source: type, source: *const Source) usize {
    if (Source == []const u8 or Source == []u8) return source.*.len;
    return source.len();
}

fn SourceError(comptime Source: type) type {
    return if (Source == []const u8 or Source == []u8) Error else anyerror;
}

fn sourceBytes(comptime Source: type, source: *Source, offset: usize, length: usize) SourceError(Source)![]const u8 {
    if (Source == []const u8 or Source == []u8) {
        if (offset > source.*.len or length > source.*.len - offset) return error.Truncated;
        return source.*[offset..][0..length];
    }
    return source.bytes(offset, length);
}

fn sourceReadInt(comptime T: type, bytes: []const u8, offset: usize) Error!T {
    if (offset > bytes.len or bytes.len - offset < @sizeOf(T)) return error.Truncated;
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

const SourceEnvelope = struct {
    representation: Representation,
    bit_count: usize,
    one_count: usize,
    total_len: usize,
};

fn parseSourceEnvelope(comptime Source: type, source: *Source) SourceError(Source)!SourceEnvelope {
    const length = sourceLen(Source, source);
    if (length < header_size) return error.Truncated;
    const header = try sourceBytes(Source, source, 0, header_size);
    if (!std.mem.eql(u8, header[0..4], magic)) return error.BadMagic;
    if (try sourceReadInt(u16, header, 4) != version) return error.UnsupportedVersion;
    if (try sourceReadInt(u16, header, 6) != header_size) return error.InvalidEncoding;
    if (header[9] != 0 or try sourceReadInt(u32, header, 12) != 0 or try sourceReadInt(u64, header, 88) != 0)
        return error.InvalidEncoding;

    const raw = header[8];
    if (raw > @intFromEnum(Representation.very_sparse)) return error.UnsupportedRepresentation;
    const representation: Representation = @enumFromInt(raw);
    const bit_count = try wireAsUsize(try sourceReadInt(u64, header, 16));
    const one_count = try wireAsUsize(try sourceReadInt(u64, header, 24));
    if (one_count > bit_count) return error.InvalidEncoding;
    if (try wireAsUsize(try sourceReadInt(u64, header, 32)) != checkpoint_stride) return error.InvalidEncoding;
    const checkpoints = try wireAsUsize(try sourceReadInt(u64, header, 40));
    if (checkpoints != try wireCheckpointCount(bit_count)) return error.InvalidEncoding;

    const directory_at = try wireAsUsize(try sourceReadInt(u64, header, 48));
    const directory_len = try wireAsUsize(try sourceReadInt(u64, header, 56));
    if (directory_at != header_size or directory_len != try wireMul(checkpoints, checkpoint_record_size))
        return error.InvalidEncoding;
    const directory_end = try wireAdd(directory_at, directory_len);
    const payload_at = try wireAsUsize(try sourceReadInt(u64, header, 64));
    if (payload_at != try wireAlign8(directory_end) or payload_at % 8 != 0) return error.InvalidEncoding;
    const payload_len = try wireAsUsize(try sourceReadInt(u64, header, 72));
    const total_len = try wireAsUsize(try sourceReadInt(u64, header, 80));
    const payload_end = try wireAdd(payload_at, payload_len);
    if (total_len != length or payload_end != total_len or payload_at > length) return error.Truncated;
    return .{ .representation = representation, .bit_count = bit_count, .one_count = one_count, .total_len = total_len };
}

/// A borrowed view whose source is selected at comptime.  `openEnvelope`
/// checks only fixed layout and bounds; `verify` authenticates/reads the full
/// source once and performs the representation-specific validation.  Query
/// methods never allocate and reject use before verification.  A custom
/// source's `bytes` method must return a stable borrowed slice for the source
/// lifetime (as mapped sections do); a transient scratch buffer is not a
/// valid implementation because the verified inner view retains that slice.
pub fn ViewFor(comptime Source: type) type {
    return struct {
        const Self = @This();

        source: Source,
        envelope: SourceEnvelope,
        decoded: ?View = null,
        verified: bool = false,

        pub fn openEnvelope(source: Source) SourceError(Source)!Self {
            var owned_source = source;
            const envelope = try parseSourceEnvelope(Source, &owned_source);
            return .{ .source = owned_source, .envelope = envelope };
        }

        pub fn open(source: Source) SourceError(Source)!Self {
            var result = try Self.openEnvelope(source);
            try result.verify();
            return result;
        }

        pub fn verify(self: *Self) SourceError(Source)!void {
            if (self.verified) return;
            const bytes = try sourceBytes(Source, &self.source, 0, self.envelope.total_len);
            self.decoded = try View.open(bytes);
            self.verified = true;
        }

        pub fn isVerified(self: *const Self) bool {
            return self.verified;
        }

        pub fn len(self: *const Self) usize {
            return self.envelope.bit_count;
        }

        pub fn count(self: *const Self) usize {
            return self.envelope.one_count;
        }

        pub fn representation(self: *const Self) Representation {
            return self.envelope.representation;
        }

        fn inner(self: *const Self) Error!*const View {
            if (!self.verified or self.decoded == null) return error.Unverified;
            return &self.decoded.?;
        }

        pub fn get(self: *const Self, index: usize) SourceError(Source)!bool {
            return (try self.inner()).get(index);
        }

        pub fn rank1(self: *const Self, index: usize) SourceError(Source)!usize {
            return (try self.inner()).rank1(index);
        }

        pub fn rank1Inclusive(self: *const Self, index: usize) SourceError(Source)!usize {
            return (try self.inner()).rank1Inclusive(index);
        }

        pub fn select1(self: *const Self, ordinal: usize) SourceError(Source)!usize {
            return (try self.inner()).select1(ordinal);
        }
    };
}
