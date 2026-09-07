const std = @import("std");
pub const Error = error{ OutOfBounds, InvalidWidth, InvalidArgument, ValueOverflow, Overflow, InvalidEncoding, NonMonotone, OutOfMemory };

/// A view never owns `bytes`; callers can keep a snapshot mmap'd and open all
/// packed columns without a second allocation. Encoders return one owned byte
/// buffer; opening that same buffer is the only reader implementation.
pub const ViewError = Error || error{BadMagic};

pub const OwnedBytes = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn deinit(self: *OwnedBytes) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

fn readLE(comptime T: type, bytes: []const u8, at: usize) ViewError!T {
    if (at > bytes.len or bytes.len - at < @sizeOf(T)) return error.InvalidEncoding;
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}
fn putLE(comptime T: type, bytes: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .little);
}
fn bytesForBits(n: usize) Error!usize {
    return (std.math.add(usize, n, 7) catch return error.Overflow) / 8;
}
fn countSet(bytes: []const u8, start: usize, end: usize) usize {
    var total: usize = 0;
    var i = start;
    while (i < end) : (i += 1) total += @intFromBool((bytes[i / 8] & (@as(u8, 1) << @as(u3, @intCast(i % 8)))) != 0);
    return total;
}
fn widthMask(width: u8) Error!u64 {
    if (width > 64) return error.InvalidWidth;
    return if (width == 0) 0 else if (width == 64) std.math.maxInt(u64) else (@as(u64, 1) << @as(u6, @intCast(width))) - 1;
}
pub fn checkedU64(value: anytype) Error!u64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => std.math.cast(u64, value) orelse error.ValueOverflow,
        .@"enum" => std.math.cast(u64, @intFromEnum(value)) orelse error.ValueOverflow,
        else => error.InvalidArgument,
    };
}
pub fn readBits(bytes: []const u8, bit_offset: usize, width: u8) Error!u64 {
    const mask = try widthMask(width);
    const end = std.math.add(usize, bit_offset, width) catch return error.Overflow;
    const total = std.math.mul(usize, bytes.len, 8) catch return error.Overflow;
    if (end > total) return error.OutOfBounds;
    if (width == 0) return 0;
    // At most nine bytes cover any 64-bit field. A bounded little-endian
    // window replaces a branch per bit without over-reading the final byte.
    const first = bit_offset / 8;
    const length = (bit_offset % 8 + width + 7) / 8;
    var window: u128 = 0;
    for (bytes[first..][0..length], 0..) |byte, i|
        window |= @as(u128, byte) << @as(u7, @intCast(i * 8));
    return @as(u64, @truncate(window >> @as(u7, @intCast(bit_offset % 8)))) & mask;
}

pub fn writeBits(bytes: []u8, bit_offset: usize, width: u8, value: u64) Error!void {
    const mask = try widthMask(width);
    if (value & ~mask != 0) return error.ValueOverflow;
    const end = std.math.add(usize, bit_offset, width) catch return error.Overflow;
    const total = std.math.mul(usize, bytes.len, 8) catch return error.Overflow;
    if (end > total) return error.OutOfBounds;
    for (0..width) |i| {
        const at = bit_offset + i;
        const bit: u8 = @as(u8, 1) << @as(u3, @intCast(at % 8));
        if ((value & (@as(u64, 1) << @as(u6, @intCast(i)))) != 0) bytes[at / 8] |= bit else bytes[at / 8] &= ~bit;
    }
}

fn frameCount(count: usize, frame_size: usize) Error!usize {
    if (frame_size == 0) return error.InvalidArgument;
    return if (count == 0) 0 else (std.math.add(usize, count, frame_size - 1) catch return error.Overflow) / frame_size;
}
fn frameInfo(values: anytype, start: usize, end: usize) Error!struct { base: u64, width: u8 } {
    var base: u64 = std.math.maxInt(u64);
    for (start..end) |i| base = @min(base, try checkedU64(values[i]));
    var high: u64 = 0;
    for (start..end) |i| high = @max(high, (try checkedU64(values[i])) - base);
    return .{ .base = base, .width = if (high == 0) 0 else @intCast(64 - @clz(high)) };
}
/// Self-describing FOR wire view.  The header is deliberately boring: it
/// makes corruption checks independent of the surrounding section manifest.
/// Layout: `FOV2`, version u16, frame_size u32, count u64, frame_count u64,
/// followed by frame_count u64 offsets and the ordinary 9-byte FOR frames.
pub const ForView = struct {
    bytes: []const u8,
    offsets: []const u8,
    count: usize,
    frame_size: usize,
    frames: usize,

    pub fn open(bytes: []const u8) ViewError!ForView {
        if (bytes.len < 32 or !std.mem.eql(u8, bytes[0..4], "FOV2")) return error.BadMagic;
        if (try readLE(u16, bytes, 4) != 1 or try readLE(u16, bytes, 6) != 0 or try readLE(u32, bytes, 28) != 0) return error.InvalidEncoding;
        const frame_size = try readLE(u32, bytes, 8);
        const count_u64 = try readLE(u64, bytes, 12);
        const frames_u64 = try readLE(u64, bytes, 20);
        const count = std.math.cast(usize, count_u64) orelse return error.Overflow;
        const frames = std.math.cast(usize, frames_u64) orelse return error.Overflow;
        if (frames != try frameCount(count, frame_size)) return error.InvalidEncoding;
        const table_end = std.math.add(usize, 32, std.math.mul(usize, frames, 8) catch return error.Overflow) catch return error.Overflow;
        if (table_end > bytes.len) return error.InvalidEncoding;
        var previous: usize = table_end;
        for (0..frames) |i| {
            const at = std.math.cast(usize, try readLE(u64, bytes, 32 + i * 8)) orelse return error.Overflow;
            if (at != previous or at > bytes.len or bytes.len - at < 9) return error.InvalidEncoding;
            const width = bytes[at + 8];
            if (width > 64) return error.InvalidEncoding;
            const start = i * frame_size;
            const n = @min(frame_size, count - start);
            const payload = try bytesForBits(std.math.mul(usize, n, width) catch return error.Overflow);
            const end = std.math.add(usize, at + 9, payload) catch return error.Overflow;
            if (end > bytes.len) return error.InvalidEncoding;
            const base = try readLE(u64, bytes, at);
            for (0..n) |j| {
                const d = try readBits(bytes[at + 9 .. end], j * width, width);
                _ = std.math.add(u64, base, d) catch return error.InvalidEncoding;
            }
            const used = n * width;
            if (used % 8 != 0 and payload != 0 and bytes[end - 1] >> @as(u3, @intCast(used % 8)) != 0) return error.InvalidEncoding;
            previous = end;
        }
        if (frames == 0 and bytes.len != 32) return error.InvalidEncoding;
        if (frames != 0 and previous != bytes.len) return error.InvalidEncoding;
        return .{ .bytes = bytes, .offsets = bytes[32..table_end], .count = count, .frame_size = frame_size, .frames = frames };
    }

    pub fn get(self: *const ForView, index: usize) ViewError!u64 {
        if (index >= self.count) return error.OutOfBounds;
        const frame = index / self.frame_size;
        const at = std.math.cast(usize, try readLE(u64, self.offsets, frame * 8)) orelse return error.Overflow;
        const width = self.bytes[at + 8];
        const n = @min(self.frame_size, self.count - frame * self.frame_size);
        const payload = try bytesForBits(n * width);
        const d = try readBits(self.bytes[at + 9 .. at + 9 + payload], (index % self.frame_size) * width, width);
        return std.math.add(u64, try readLE(u64, self.bytes, at), d) catch return error.Overflow;
    }
};

pub fn encodeFor(allocator: std.mem.Allocator, values: anytype, frame_size: usize) Error!OwnedBytes {
    const frames = try frameCount(values.len, frame_size);
    const prefix = try std.math.add(usize, 32, try std.math.mul(usize, frames, 8));
    var total = prefix;
    for (0..frames) |frame| {
        const start = frame * frame_size;
        const n = @min(frame_size, values.len - start);
        const info = try frameInfo(values, start, start + n);
        total = try std.math.add(usize, total, try std.math.add(usize, 9, try bytesForBits(try std.math.mul(usize, n, info.width))));
    }
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    @memset(out, 0);
    @memcpy(out[0..4], "FOV2");
    putLE(u16, out, 4, 1);
    putLE(u32, out, 8, std.math.cast(u32, frame_size) orelse return error.Overflow);
    putLE(u64, out, 12, values.len);
    putLE(u64, out, 20, frames);
    var at = prefix;
    for (0..frames) |frame| {
        const start = frame * frame_size;
        const n = @min(frame_size, values.len - start);
        const info = try frameInfo(values, start, start + n);
        putLE(u64, out, 32 + frame * 8, at);
        putLE(u64, out, at, info.base);
        out[at + 8] = info.width;
        const length = try bytesForBits(n * info.width);
        for (0..n) |i| try writeBits(out[at + 9 ..][0..length], i * info.width, info.width, (try checkedU64(values[start + i])) - info.base);
        at += 9 + length;
    }
    return .{ .allocator = allocator, .bytes = out };
}

/// Borrowed bitmap view.  Wire layout is `PBM2`, version, count, checkpoint
/// interval (currently 512), then checkpoint ranks and bitmap bytes.
pub const PresenceView = struct {
    bytes: []const u8,
    ranks: []const u8,
    bitmap: []const u8,
    count: usize,

    pub fn open(bytes: []const u8) ViewError!PresenceView {
        if (bytes.len < 32 or !std.mem.eql(u8, bytes[0..4], "PBM2")) return error.BadMagic;
        if (try readLE(u16, bytes, 4) != 1 or try readLE(u16, bytes, 6) != 512 or
            !std.mem.eql(u8, bytes[16..32], &[_]u8{0} ** 16)) return error.InvalidEncoding;
        const count = std.math.cast(usize, try readLE(u64, bytes, 8)) orelse return error.Overflow;
        const checkpoints = count / 512 + 1;
        const rank_bytes = try std.math.mul(usize, checkpoints, 4);
        const bitmap_bytes = try bytesForBits(count);
        const bitmap_at = try std.math.add(usize, 32, rank_bytes);
        if (bitmap_at > bytes.len or bytes.len - bitmap_at != bitmap_bytes) return error.InvalidEncoding;
        var expected: usize = 0;
        for (0..checkpoints) |i| {
            const checkpoint_rank = try readLE(u32, bytes, 32 + i * 4);
            if (checkpoint_rank != expected) return error.InvalidEncoding;
            if (i + 1 < checkpoints) expected += countSet(bytes[bitmap_at..], i * 512, @min(count, (i + 1) * 512));
        }
        if (count % 8 != 0 and bitmap_bytes != 0 and bytes[bytes.len - 1] >> @as(u3, @intCast(count % 8)) != 0) return error.InvalidEncoding;
        return .{ .bytes = bytes, .ranks = bytes[32..bitmap_at], .bitmap = bytes[bitmap_at..], .count = count };
    }
    pub fn isSet(self: *const PresenceView, index: usize) ViewError!bool {
        if (index >= self.count) return error.OutOfBounds;
        return (self.bitmap[index / 8] & (@as(u8, 1) << @as(u3, @intCast(index % 8)))) != 0;
    }
    pub fn rank(self: *const PresenceView, index: usize) ViewError!usize {
        if (index > self.count) return error.OutOfBounds;
        const checkpoint = index / 512;
        var total = try readLE(u32, self.ranks, checkpoint * 4);
        var i = checkpoint * 512;
        while (i < index) : (i += 1) total += @intFromBool((self.bitmap[i / 8] & (@as(u8, 1) << @as(u3, @intCast(i % 8)))) != 0);
        return total;
    }
};

pub fn encodePresence(allocator: std.mem.Allocator, values: []const bool) Error!OwnedBytes {
    const checkpoints = values.len / 512 + 1;
    const rank_bytes = std.math.mul(usize, checkpoints, 4) catch return error.Overflow;
    const bitmap_bytes = try bytesForBits(values.len);
    const bitmap_at = std.math.add(usize, 32, rank_bytes) catch return error.Overflow;
    const out = try allocator.alloc(u8, std.math.add(usize, bitmap_at, bitmap_bytes) catch return error.Overflow);
    errdefer allocator.free(out);
    @memset(out, 0);
    @memcpy(out[0..4], "PBM2");
    putLE(u16, out, 4, 1);
    putLE(u16, out, 6, 512);
    putLE(u64, out, 8, values.len);
    var rank: u32 = 0;
    for (0..checkpoints) |checkpoint| {
        putLE(u32, out, 32 + checkpoint * 4, rank);
        const start = checkpoint * 512;
        const end = @min(values.len, start + 512);
        for (values[start..end], start..) |present, i| if (present) {
            out[bitmap_at + i / 8] |= @as(u8, 1) << @as(u3, @intCast(i % 8));
            rank = std.math.add(u32, rank, 1) catch return error.Overflow;
        };
    }
    return .{ .allocator = allocator, .bytes = out };
}

/// Borrowed Elias--Fano view.  A select checkpoint every 64 values bounds the
/// tiny unary scan without spending a machine word per item.  The high bitmap
/// and low-bit stream remain the actual representation; checkpoints are only
/// navigation metadata.
pub const EliasView = struct {
    bytes: []const u8,
    low: []const u8,
    high: []const u8,
    checkpoints: []const u8,
    count: usize,
    universe: u64,
    low_bits: u8,

    const header_bytes = 64;
    const checkpoint_shift = 6;
    const checkpoint_interval = 1 << checkpoint_shift;

    pub fn open(bytes: []const u8) ViewError!EliasView {
        if (bytes.len < header_bytes or !std.mem.eql(u8, bytes[0..4], "EFV2")) return error.BadMagic;
        if (try readLE(u16, bytes, 4) != 2 or bytes[7] != checkpoint_shift or
            !std.mem.eql(u8, bytes[48..64], &[_]u8{0} ** 16)) return error.InvalidEncoding;
        const count = std.math.cast(usize, try readLE(u64, bytes, 8)) orelse return error.Overflow;
        const universe = try readLE(u64, bytes, 16);
        const low_bits = bytes[6];
        if (low_bits > 63 or (count != 0 and universe == 0)) return error.InvalidEncoding;
        const low_bytes = try bytesForBits(std.math.mul(usize, count, low_bits) catch return error.Overflow);
        const high_bits = if (count == 0) 0 else std.math.cast(usize, std.math.add(u64, universe >> @as(u6, @intCast(low_bits)), count) catch return error.Overflow) orelse return error.Overflow;
        const high_bytes = try bytesForBits(high_bits);
        const checkpoint_count = try frameCount(count, checkpoint_interval);
        const low_at = std.math.cast(usize, try readLE(u64, bytes, 24)) orelse return error.Overflow;
        const high_at = std.math.cast(usize, try readLE(u64, bytes, 32)) orelse return error.Overflow;
        const checkpoints_at = std.math.cast(usize, try readLE(u64, bytes, 40)) orelse return error.Overflow;
        const checkpoint_bytes = std.math.mul(usize, checkpoint_count, 8) catch return error.Overflow;
        if (low_at != header_bytes or high_at != try std.math.add(usize, low_at, low_bytes) or checkpoints_at != try std.math.add(usize, high_at, high_bytes) or checkpoints_at > bytes.len or
            bytes.len - checkpoints_at != checkpoint_bytes)
            return error.InvalidEncoding;
        const result = EliasView{
            .bytes = bytes,
            .low = bytes[low_at..high_at],
            .high = bytes[high_at..checkpoints_at],
            .checkpoints = bytes[checkpoints_at..],
            .count = count,
            .universe = universe,
            .low_bits = low_bits,
        };
        var seen: usize = 0;
        var previous_value: u64 = 0;
        for (0..high_bits) |position| if (try readBits(result.high, position, 1) != 0) {
            if (seen >= count) return error.InvalidEncoding;
            if (seen % checkpoint_interval == 0 and try readLE(u64, result.checkpoints, (seen / checkpoint_interval) * 8) != position) return error.InvalidEncoding;
            const high = position - seen;
            const low = try readBits(result.low, seen * low_bits, low_bits);
            const shifted = if (low_bits == 0) high else std.math.shlExact(u64, high, @as(u6, @intCast(low_bits))) catch return error.InvalidEncoding;
            const value = shifted | low;
            if (value >= universe or (seen != 0 and value < previous_value)) return error.InvalidEncoding;
            previous_value = value;
            seen += 1;
        };
        if (seen != count) return error.InvalidEncoding;
        const low_used = count * low_bits;
        if (low_used % 8 != 0 and low_bytes != 0 and result.low[low_bytes - 1] >> @as(u3, @intCast(low_used % 8)) != 0) return error.InvalidEncoding;
        if (high_bits % 8 != 0 and high_bytes != 0 and result.high[high_bytes - 1] >> @as(u3, @intCast(high_bits % 8)) != 0) return error.InvalidEncoding;
        return result;
    }

    pub fn get(self: *const EliasView, index: usize) ViewError!u64 {
        if (index >= self.count) return error.OutOfBounds;
        const checkpoint = index / checkpoint_interval;
        var position = std.math.cast(usize, try readLE(u64, self.checkpoints, checkpoint * 8)) orelse return error.Overflow;
        var seen = checkpoint * checkpoint_interval;
        while (position < self.high.len * 8) : (position += 1) {
            if (try readBits(self.high, position, 1) == 0) continue;
            if (seen == index) break;
            seen += 1;
        }
        if (position >= self.high.len * 8) return error.InvalidEncoding;
        const high = position - index;
        const low = try readBits(self.low, index * self.low_bits, self.low_bits);
        const shifted = if (self.low_bits == 0) high else std.math.shlExact(u64, high, @as(u6, @intCast(self.low_bits))) catch return error.Overflow;
        return shifted | low;
    }

    pub fn upperBound(self: *const EliasView, needle: u64) ViewError!usize {
        var lo: usize = 0;
        var hi = self.count;
        while (lo < hi) {
            const m = lo + (hi - lo) / 2;
            if (try self.get(m) <= needle) lo = m + 1 else hi = m;
        }
        return lo;
    }
};

pub fn encodeElias(allocator: std.mem.Allocator, values: anytype, universe: u64) Error!OwnedBytes {
    var previous: u64 = 0;
    for (values, 0..) |item, i| {
        const value = try checkedU64(item);
        if (value >= universe) return error.OutOfBounds;
        if (i != 0 and value < previous) return error.NonMonotone;
        previous = value;
    }
    var low_bits: u8 = 0;
    if (values.len != 0) {
        var ratio = universe / values.len;
        while (ratio > 1 and low_bits < 63) : (low_bits += 1) ratio >>= 1;
    }
    const low_length = try bytesForBits(try std.math.mul(usize, values.len, low_bits));
    const high_bits: usize = if (values.len == 0) 0 else std.math.cast(usize, try std.math.add(u64, universe >> @as(u6, @intCast(low_bits)), values.len)) orelse return error.Overflow;
    const low_at = EliasView.header_bytes;
    const high_at = try std.math.add(usize, low_at, low_length);
    const checkpoints_at = try std.math.add(usize, high_at, try bytesForBits(high_bits));
    const checkpoint_count = try frameCount(values.len, EliasView.checkpoint_interval);
    const total = try std.math.add(usize, checkpoints_at, try std.math.mul(usize, checkpoint_count, 8));
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    @memset(out, 0);
    @memcpy(out[0..4], "EFV2");
    putLE(u16, out, 4, 2);
    out[6] = low_bits;
    out[7] = EliasView.checkpoint_shift;
    putLE(u64, out, 8, values.len);
    putLE(u64, out, 16, universe);
    putLE(u64, out, 24, low_at);
    putLE(u64, out, 32, high_at);
    putLE(u64, out, 40, checkpoints_at);
    const mask = try widthMask(low_bits);
    for (values, 0..) |item, i| {
        const value = try checkedU64(item);
        const high = std.math.cast(usize, value >> @as(u6, @intCast(low_bits))) orelse return error.Overflow;
        const position = try std.math.add(usize, high, i);
        try writeBits(out[low_at..high_at], i * low_bits, low_bits, value & mask);
        try writeBits(out[high_at..checkpoints_at], position, 1, 1);
        if (i % EliasView.checkpoint_interval == 0)
            putLE(u64, out, checkpoints_at + (i / EliasView.checkpoint_interval) * 8, position);
    }
    return .{ .allocator = allocator, .bytes = out };
}
