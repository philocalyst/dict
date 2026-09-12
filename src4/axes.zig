//! Derived search axes for LEX4.
//!
//! An axis is not another dictionary.  It is the same rank-addressed minimal
//! automaton with a different key projection and one compact output column.
//! The output column maps the axis' lexicographic key rank to primary entry
//! ranks.  Keeping that mapping beside (rather than inside) the key automaton
//! makes the reader pleasantly small and lets every axis share the exact same
//! walk, prefix DFS, and authenticated-source boundary.
//!
//! The only part that varies at comptime is `Transform`.  A transform owns no
//! state and provides `maxLen`, `apply`, and `isIdentity`.  Reversed,
//! normalized, and phonetic axes consequently use exactly the same builder,
//! wire reader, and zero-allocation query control flow.
//!
//! This candidate intentionally stops at exact/prefix/suffix products.  The
//! compact automaton currently exposes a trusted prefix DFS but not its
//! internal state/arc cursor, so implementing fuzzy or regex by rescanning
//! every key would be a dishonest "product".  Canonical integration should
//! add a state-product hook to the shared automaton and instantiate it here;
//! this file does not duplicate that reader merely to claim a feature.

const std = @import("std");
const schema = @import("schema.zig");
const automaton = @import("automaton.zig");
const wire = @import("wire.zig");

pub const EntryRank = schema.Rank(.entry);
pub const Error = automaton.Error || error{
    EmptyInput,
    BadAxis,
    InvalidUtf8,
    InvalidOutput,
    OutputTooSmall,
    UnsupportedTransform,
};

const magic = "L4AX";
const version: u16 = 1;
const header_bytes: usize = 48;
const single_target_mode: u8 = 2;
const single_target_stride: u32 = 64;
const packed_targets_mode: u8 = 3;
const packed_boundary_stride: u32 = 256;

fn readLe(comptime T: type, bytes: []const u8, offset: usize) Error!T {
    const end = std.math.add(usize, offset, @sizeOf(T)) catch return error.Truncated;
    if (end > bytes.len) return error.Truncated;
    return std.mem.readInt(T, @as(*const [@sizeOf(T)]u8, @ptrCast(bytes[offset..end].ptr)), .little);
}

fn putLe(comptime T: type, bytes: []u8, offset: usize, value: T) Error!void {
    const end = std.math.add(usize, offset, @sizeOf(T)) catch return error.Overflow;
    if (end > bytes.len) return error.OutputTooSmall;
    std.mem.writeInt(T, @as(*[@sizeOf(T)]u8, @ptrCast(bytes[offset..end].ptr)), value, .little);
}

fn appendVar(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var n = value;
    while (n >= 0x80) : (n >>= 7) try out.append(allocator, @as(u8, @intCast(n & 0x7f)) | 0x80);
    try out.append(allocator, @intCast(n));
}

fn readVar(bytes: []const u8, cursor: *usize) Error!u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        if (cursor.* >= bytes.len) return error.Truncated;
        const b = bytes[cursor.*];
        cursor.* += 1;
        if (shift == 28 and b > 0x0f) return error.InvalidFormat;
        result |= @as(u32, b & 0x7f) << shift;
        if (b & 0x80 == 0) return result;
        if (shift == 28) return error.InvalidFormat;
        shift += 7;
    }
}

fn readVarLimited(bytes: []const u8, cursor: *usize, limit: usize) Error!u32 {
    if (cursor.* >= limit) return error.Truncated;
    const value = try readVar(bytes, cursor);
    if (cursor.* > limit) return error.InvalidOutput;
    return value;
}

fn u32Len(value: usize) Error!u32 {
    return std.math.cast(u32, value) orelse error.Overflow;
}

fn bitWidth(cardinality: u32) Error!u8 {
    if (cardinality == 0) return error.InvalidOutput;
    const value = cardinality - 1;
    return @max(@as(u8, 1), @as(u8, @intCast(32 - @clz(value))));
}

fn bitsToBytes(count: usize, width: u8) Error!usize {
    const bits = std.math.mul(usize, count, width) catch return error.Overflow;
    return std.math.divCeil(usize, bits, 8) catch return error.Overflow;
}

fn bitGet(bytes: []const u8, index: usize) bool {
    return bytes[index / 8] & (@as(u8, 1) << @intCast(index & 7)) != 0;
}

fn bitSet(bytes: []u8, index: usize) void {
    bytes[index / 8] |= @as(u8, 1) << @intCast(index & 7);
}

fn putPacked(bytes: []u8, width: u8, index: usize, value: u32) Error!void {
    const bit_offset = std.math.mul(usize, index, width) catch return error.Overflow;
    const byte_offset = bit_offset / 8;
    const shift: u6 = @intCast(bit_offset & 7);
    if (byte_offset >= bytes.len) return error.OutputTooSmall;
    const mask: u64 = if (width == 32) std.math.maxInt(u32) else (@as(u64, 1) << @intCast(width)) - 1;
    if (value > mask) return error.InvalidTarget;
    var word: u64 = 0;
    const count = @min(@as(usize, 5), bytes.len - byte_offset);
    for (0..count) |i| word |= @as(u64, bytes[byte_offset + i]) << @intCast(i * 8);
    word = (word & ~(mask << shift)) | (@as(u64, value) << shift);
    for (0..count) |i| bytes[byte_offset + i] = @truncate(word >> @intCast(i * 8));
}

fn packedAt(bytes: []const u8, width: u8, index: usize) Error!u32 {
    const bit_offset = std.math.mul(usize, index, width) catch return error.Overflow;
    const byte_offset = bit_offset / 8;
    const shift: u6 = @intCast(bit_offset & 7);
    if (byte_offset >= bytes.len) return error.Truncated;
    var word: u64 = 0;
    const count = @min(@as(usize, 5), bytes.len - byte_offset);
    for (0..count) |i| word |= @as(u64, bytes[byte_offset + i]) << @intCast(i * 8);
    const mask: u64 = if (width == 32) std.math.maxInt(u32) else (@as(u64, 1) << @intCast(width)) - 1;
    return @truncate((word >> shift) & mask);
}

fn zigzagEncode(delta: i64) u32 {
    if (delta >= 0) return @intCast(@as(u64, @intCast(delta)) * 2);
    return @intCast(@as(u64, @intCast(-delta)) * 2 - 1);
}

fn zigzagDecode(value: u32) i64 {
    const magnitude: i64 = @intCast(value >> 1);
    return if (value & 1 == 0) magnitude else -magnitude - 1;
}

/// Reversal is Unicode-scalar safe: it reverses complete UTF-8 scalar
/// encodings, never their individual continuation bytes.  The wire contract
/// deliberately rejects malformed UTF-8 rather than silently manufacturing
/// a different spelling.  ASCII/binary-only callers that need byte reversal
/// must provide a separately versioned transform; this axis is the stable
/// UTF-8 policy used by the dictionary.
pub const Reverse = struct {
    pub const name = "reverse";
    pub const strategy_version: u8 = 1;
    pub fn maxLen(input_len: usize) usize {
        return input_len;
    }
    pub fn isIdentity(input: []const u8) bool {
        if (!std.unicode.utf8ValidateSlice(input)) return false;
        var scalars: usize = 0;
        var cursor: usize = 0;
        while (cursor < input.len) {
            const width = std.unicode.utf8ByteSequenceLength(input[cursor]) catch return false;
            cursor += width;
            scalars += 1;
            if (scalars > 1) return false;
        }
        return true;
    }
    pub fn apply(input: []const u8, out: []u8) Error![]const u8 {
        if (out.len < input.len) return error.OutputTooSmall;
        if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
        var input_end = input.len;
        var output_cursor: usize = 0;
        while (input_end != 0) {
            var input_start = input_end - 1;
            while (input_start != 0 and (input[input_start] & 0xc0) == 0x80) input_start -= 1;
            const width = input_end - input_start;
            std.mem.copyForwards(u8, out[output_cursor..][0..width], input[input_start..input_end]);
            output_cursor += width;
            input_end = input_start;
        }
        return out[0..input.len];
    }
};

/// Undo a scalar reversal in an iterator-owned key buffer without allocating.
/// After reversing all bytes, each scalar is a run of continuation bytes
/// followed by its original leading byte; reversing those runs restores valid
/// UTF-8 and the original spelling.
fn reverseScalarsInPlace(bytes: []u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    std.mem.reverse(u8, bytes);
    var start: usize = 0;
    while (start < bytes.len) {
        var end = start;
        while (end < bytes.len and (bytes[end] & 0xc0) == 0x80) end += 1;
        if (end >= bytes.len) return error.InvalidUtf8;
        std.mem.reverse(u8, bytes[start .. end + 1]);
        start = end + 1;
    }
}

/// Conservative normalization that is useful for dictionary lookup without
/// pretending to be a full Unicode normalization implementation.  ASCII
/// case folding is stable, cheap, and leaves every non-ASCII byte untouched;
/// importers that need NFC can provide their own transform with this same
/// interface.
pub const Normalized = struct {
    pub const name = "normalized";
    pub const strategy_version: u8 = 1;
    pub fn maxLen(input_len: usize) usize {
        return input_len;
    }
    pub fn isIdentity(input: []const u8) bool {
        for (input) |byte| if (byte >= 'A' and byte <= 'Z') return false;
        return true;
    }
    pub fn apply(input: []const u8, out: []u8) Error![]const u8 {
        if (out.len < input.len) return error.OutputTooSmall;
        for (input, 0..) |byte, i| out[i] = if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
        return out[0..input.len];
    }
};

/// A bounded Soundex-like projection.  Four bytes are enough for the common
/// Latin case, while the `?000` spelling of a non-ASCII/non-letter initial is
/// deterministic for arbitrary byte input.  It is intentionally a search
/// axis, not a linguistic claim; applications needing Metaphone can plug in
/// another transform without changing the storage or query implementation.
pub const Phonetic = struct {
    pub const name = "phonetic";
    /// Soundex-v1 is intentionally a wire-visible strategy.  Changing its
    /// alphabet or reset rules requires a new version, never a silent rebuild.
    pub const strategy_version: u8 = 1;
    pub fn maxLen(input_len: usize) usize {
        _ = input_len;
        return 4;
    }
    pub fn isIdentity(input: []const u8) bool {
        _ = input;
        return false;
    }

    fn upper(byte: u8) ?u8 {
        if (byte >= 'a' and byte <= 'z') return byte - ('a' - 'A');
        if (byte >= 'A' and byte <= 'Z') return byte;
        return null;
    }

    fn code(byte: u8) u8 {
        return switch (byte) {
            'B', 'F', 'P', 'V' => '1',
            'C', 'G', 'J', 'K', 'Q', 'S', 'X', 'Z' => '2',
            'D', 'T' => '3',
            'L' => '4',
            'M', 'N' => '5',
            'R' => '6',
            else => '0',
        };
    }

    pub fn apply(input: []const u8, out: []u8) Error![]const u8 {
        if (out.len < 4) return error.OutputTooSmall;
        if (input.len == 0) {
            @memset(out[0..4], '0');
            return out[0..4];
        }
        const first = upper(input[0]) orelse '?';
        out[0] = first;
        out[1] = '0';
        out[2] = '0';
        out[3] = '0';
        if (first == '?') return out[0..4];
        var written: usize = 1;
        var previous = code(first);
        for (input[1..]) |raw| {
            const upper_byte = upper(raw) orelse {
                previous = '0';
                continue;
            };
            const next = code(upper_byte);
            if (next != '0' and next != previous) {
                out[written] = next;
                written += 1;
                if (written == 4) break;
            }
            previous = next;
        }
        return out[0..4];
    }
};

pub const AxisKind = enum(u8) { reversed = 1, normalized = 2, phonetic = 3 };

pub fn transformFor(kind: AxisKind) type {
    return switch (kind) {
        .reversed => Reverse,
        .normalized => Normalized,
        .phonetic => Phonetic,
    };
}

const Pair = struct { key: []u8, target: u32 };

fn pairLess(_: void, left: Pair, right: Pair) bool {
    const key_order = std.mem.order(u8, left.key, right.key);
    return switch (key_order) {
        .lt => true,
        .gt => false,
        .eq => left.target < right.target,
    };
}

fn freePairs(allocator: std.mem.Allocator, pairs: *std.ArrayList(Pair)) void {
    for (pairs.items) |pair| allocator.free(pair.key);
    pairs.deinit(allocator);
}

pub const Owned = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// The normalized overlay can be omitted entirely when every input is
/// already normalized.  The caller then reuses the primary automaton exactly,
/// paying zero bytes and zero extra traversal state for that axis.
pub const OverlayOwned = union(enum) {
    identity,
    materialized: Owned,

    pub fn deinit(self: *OverlayOwned) void {
        switch (self.*) {
            .identity => {},
            .materialized => |*owned| owned.deinit(),
        }
        self.* = undefined;
    }
};

pub fn AxisBuilder(comptime Transform: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        pairs: std.ArrayList(Pair) = .empty,
        last_entry: ?[]u8 = null,
        entry_count: u32 = 0,
        all_identity: bool = true,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            freePairs(self.allocator, &self.pairs);
            if (self.last_entry) |key| self.allocator.free(key);
            self.* = undefined;
        }

        fn addPair(self: *Self, key: []const u8, target: u32) !void {
            const max_len = Transform.maxLen(key.len);
            const transformed = try self.allocator.alloc(u8, max_len);
            const result = Transform.apply(key, transformed) catch |err| {
                self.allocator.free(transformed);
                return err;
            };
            const owned = self.allocator.dupe(u8, result) catch |err| {
                self.allocator.free(transformed);
                return err;
            };
            self.allocator.free(transformed);
            errdefer self.allocator.free(owned);
            try self.pairs.append(self.allocator, .{ .key = owned, .target = target });
        }

        fn checkEntryOrder(self: *const Self, key: []const u8) Error!void {
            if (self.last_entry) |previous| switch (std.mem.order(u8, previous, key)) {
                .lt => {},
                .eq => return error.DuplicateKey,
                .gt => return error.InputOutOfOrder,
            };
        }

        /// Adds one primary headword and returns the first identity rank it
        /// owns.  Homographs are consecutive targets in every derived axis.
        pub fn addEntry(self: *Self, headword: []const u8, multiplicity: u32) !EntryRank {
            if (multiplicity == 0) return error.InvalidMultiplicity;
            try self.checkEntryOrder(headword);
            const end = std.math.add(u32, self.entry_count, multiplicity) catch return error.Overflow;
            const saved = try self.allocator.dupe(u8, headword);
            errdefer self.allocator.free(saved);
            var rank = self.entry_count;
            while (rank < end) : (rank += 1) try self.addPair(headword, rank);
            if (self.last_entry) |old| self.allocator.free(old);
            self.last_entry = saved;
            self.all_identity = self.all_identity and Transform.isIdentity(headword);
            self.entry_count = end;
            return @enumFromInt(end - multiplicity);
        }

        /// Adds a written form and its already-resolved primary identities.
        /// Targets can arrive in any order; `finish` canonicalizes and dedups
        /// them so output order is deterministic.
        pub fn addForm(self: *Self, written: []const u8, targets: []const EntryRank) !void {
            if (targets.len == 0) return error.InvalidTargets;
            self.all_identity = self.all_identity and Transform.isIdentity(written);
            for (targets) |target| try self.addPair(written, @intFromEnum(target));
        }

        fn build(self: *Self) !Owned {
            if (self.entry_count == 0) return error.EmptyInput;
            std.mem.sort(Pair, self.pairs.items, {}, pairLess);

            var inner = automaton.Builder.init(self.allocator);
            defer inner.deinit();
            var index_offsets: std.ArrayList(u32) = .empty;
            defer index_offsets.deinit(self.allocator);
            var single_targets: std.ArrayList(u32) = .empty;
            defer single_targets.deinit(self.allocator);
            var group_starts: std.ArrayList(u32) = .empty;
            defer group_starts.deinit(self.allocator);
            var flat_targets: std.ArrayList(u32) = .empty;
            defer flat_targets.deinit(self.allocator);
            var payload: std.ArrayList(u8) = .empty;
            defer payload.deinit(self.allocator);

            var i: usize = 0;
            var key_count: u32 = 0;
            var all_single = true;
            while (i < self.pairs.items.len) {
                const group_start = i;
                const key = self.pairs.items[i].key;
                try index_offsets.append(self.allocator, try u32Len(payload.items.len));
                try group_starts.append(self.allocator, try u32Len(flat_targets.items.len));
                try inner.addEntry(key, 1);
                var j = i;
                var count: u32 = 0;
                while (j < self.pairs.items.len and std.mem.eql(u8, self.pairs.items[j].key, key)) : (j += 1) {
                    if (self.pairs.items[j].target >= self.entry_count) return error.InvalidTarget;
                    if (j == group_start or self.pairs.items[j].target != self.pairs.items[j - 1].target) count += 1;
                }
                try appendVar(&payload, self.allocator, count);
                var previous: u32 = 0;
                var emitted: u32 = 0;
                var k = group_start;
                while (k < j) : (k += 1) {
                    const target_rank = self.pairs.items[k].target;
                    if (k == group_start or target_rank != self.pairs.items[k - 1].target) {
                        try flat_targets.append(self.allocator, target_rank);
                        const delta = if (emitted == 0) std.math.add(u32, target_rank, 1) catch return error.Overflow else target_rank - previous;
                        try appendVar(&payload, self.allocator, delta);
                        previous = target_rank;
                        emitted += 1;
                    }
                }
                if (count == 1) {
                    try single_targets.append(self.allocator, self.pairs.items[group_start].target);
                } else {
                    all_single = false;
                }
                i = j;
                key_count += 1;
            }
            if (key_count == 0) return error.EmptyInput;

            // A permutation-like axis is the common case: one target for
            // each derived key.  Its key rank is already an implicit address,
            // so replace the expensive per-key offset directory with a
            // checkpointed signed-delta stream.  Collision-heavy axes retain
            // the generic sparse target groups above.
            var checkpoint_targets: std.ArrayList(u32) = .empty;
            defer checkpoint_targets.deinit(self.allocator);
            var checkpoint_offsets: std.ArrayList(u32) = .empty;
            defer checkpoint_offsets.deinit(self.allocator);
            if (all_single) {
                payload.clearRetainingCapacity();
                var previous: u32 = 0;
                for (single_targets.items, 0..) |target, rank| {
                    const delta = @as(i64, target) - @as(i64, previous);
                    try appendVar(&payload, self.allocator, zigzagEncode(delta));
                    if (rank % single_target_stride == 0) {
                        try checkpoint_targets.append(self.allocator, target);
                        try checkpoint_offsets.append(self.allocator, try u32Len(payload.items.len));
                    }
                    previous = target;
                }
            }

            var inner_owned = try inner.finish();
            defer inner_owned.deinit();

            const narrow_index = !all_single and payload.items.len <= std.math.maxInt(u16);
            const index_width: usize = if (narrow_index) 2 else 4;
            const index_count = if (all_single) checkpoint_targets.items.len else index_offsets.items.len;
            const legacy_index_bytes = if (all_single)
                std.math.mul(usize, index_count, 8) catch return error.Overflow
            else
                std.math.mul(usize, index_count, index_width) catch return error.Overflow;
            var packed_permutation = flat_targets.items.len == self.entry_count and key_count <= std.math.maxInt(u16);
            if (packed_permutation) {
                const seen = try self.allocator.alloc(u8, std.math.divCeil(usize, self.entry_count, 8) catch return error.Overflow);
                defer self.allocator.free(seen);
                @memset(seen, 0);
                for (flat_targets.items) |target| {
                    if (target >= self.entry_count or bitGet(seen, target)) {
                        packed_permutation = false;
                        break;
                    }
                    bitSet(seen, target);
                }
            }
            const packed_bitmap_bytes = if (packed_permutation) std.math.divCeil(usize, self.entry_count, 8) catch return error.Overflow else 0;
            const packed_block_count = if (packed_permutation) std.math.divCeil(usize, self.entry_count, packed_boundary_stride) catch return error.Overflow else 0;
            const packed_directory_bytes = if (packed_permutation) std.math.mul(usize, packed_block_count + 1, 2) catch return error.Overflow else 0;
            const packed_payload_bytes = if (packed_permutation) try bitsToBytes(self.entry_count, try bitWidth(self.entry_count)) else 0;
            const packed_index_bytes = std.math.add(usize, packed_bitmap_bytes, packed_directory_bytes) catch return error.Overflow;
            const packed_total_bytes = std.math.add(usize, packed_index_bytes, packed_payload_bytes) catch return error.Overflow;
            const legacy_total_bytes = std.math.add(usize, legacy_index_bytes, payload.items.len) catch return error.Overflow;
            const use_packed = packed_permutation and
                packed_total_bytes < legacy_total_bytes;
            const actual_index_bytes = if (use_packed) packed_index_bytes else legacy_index_bytes;
            const actual_payload_bytes = if (use_packed) packed_payload_bytes else payload.items.len;
            const index_off = header_bytes;
            const payload_off = std.math.add(usize, index_off, actual_index_bytes) catch return error.Overflow;
            const inner_off = std.math.add(usize, payload_off, actual_payload_bytes) catch return error.Overflow;
            const total = std.math.add(usize, inner_off, inner_owned.bytes.len) catch return error.Overflow;
            const total_u32 = try u32Len(total);
            const payload_off_u32 = try u32Len(payload_off);
            const payload_len = try u32Len(actual_payload_bytes);
            const inner_len = try u32Len(inner_owned.bytes.len);
            const index_len = try u32Len(actual_index_bytes);

            var out = try self.allocator.alloc(u8, total);
            errdefer self.allocator.free(out);
            @memset(out, 0);
            std.mem.copyForwards(u8, out[0..4], magic);
            try putLe(u16, out, 4, version);
            out[6] = @intFromEnum(kindFor(Transform));
            out[7] = if (use_packed) packed_targets_mode else (if (narrow_index) @as(u8, 1) else 0) | (if (all_single) single_target_mode else 0);
            try putLe(u32, out, 8, self.entry_count);
            try putLe(u32, out, 12, key_count);
            try putLe(u32, out, 16, @intCast(inner_off));
            try putLe(u32, out, 20, inner_len);
            try putLe(u32, out, 24, @intCast(index_off));
            try putLe(u32, out, 28, index_len);
            try putLe(u32, out, 32, payload_off_u32);
            try putLe(u32, out, 36, payload_len);
            try putLe(u32, out, 40, total_u32);
            try putLe(u32, out, 44, if (use_packed) packed_boundary_stride else if (all_single) single_target_stride else 0);
            out[7] |= strategyVersionFor(Transform) << 2;
            if (use_packed) {
                const bitmap = out[index_off..][0..packed_bitmap_bytes];
                for (group_starts.items) |start| bitSet(bitmap, start);
                const directory_off = index_off + packed_bitmap_bytes;
                for (0..packed_block_count + 1) |block| {
                    const limit = @min(block * packed_boundary_stride, flat_targets.items.len);
                    var starts_before: u16 = 0;
                    for (group_starts.items) |start| {
                        if (start < limit) starts_before += 1;
                    }
                    try putLe(u16, out, directory_off + block * 2, starts_before);
                }
                const lane = out[payload_off..][0..packed_payload_bytes];
                const width = try bitWidth(self.entry_count);
                for (flat_targets.items, 0..) |target, target_index| try putPacked(lane, width, target_index, target);
            } else if (all_single) {
                for (checkpoint_targets.items, 0..) |target, index| {
                    const at = index_off + index * 8;
                    try putLe(u32, out, at, target);
                    try putLe(u32, out, at + 4, checkpoint_offsets.items[index]);
                }
            } else for (index_offsets.items, 0..) |offset, index| {
                const at = index_off + index * index_width;
                if (narrow_index) try putLe(u16, out, at, @intCast(offset)) else try putLe(u32, out, at, offset);
            }
            if (!use_packed) std.mem.copyForwards(u8, out[payload_off..][0..payload.items.len], payload.items);
            std.mem.copyForwards(u8, out[inner_off..][0..inner_owned.bytes.len], inner_owned.bytes);
            return .{ .bytes = out, .allocator = self.allocator };
        }

        pub fn finish(self: *Self) !Owned {
            return self.build();
        }

        pub fn finishOverlay(self: *Self) !(if (Transform == Normalized) OverlayOwned else Owned) {
            if (comptime Transform == Normalized) {
                if (self.all_identity) return .identity;
                return .{ .materialized = try self.build() };
            }
            return self.build();
        }
    };
}

fn kindFor(comptime Transform: type) AxisKind {
    if (Transform == Reverse) return .reversed;
    if (Transform == Normalized) return .normalized;
    if (Transform == Phonetic) return .phonetic;
    @compileError("axis transform must provide a known LEX4 kind");
}

fn strategyVersionFor(comptime Transform: type) u8 {
    if (@hasDecl(Transform, "strategy_version")) return Transform.strategy_version;
    @compileError("axis transform must provide a strategy_version");
}

pub const Range = struct { lo: u32, hi: u32 };

pub const TargetList = TargetListFor([]const u8);
pub const Hit = ViewForSource(Reverse, []const u8).Hit;
pub const Item = ViewForSource(Reverse, []const u8).Item;

pub const Ledger = struct {
    header: usize,
    output_index: usize,
    output_payload: usize,
    automaton: usize,
    total: usize,
    mode: u8,
};

/// Flatten an axis prefix/suffix result into a deterministic set of primary
/// identities. A form and its lemma may expose the same entry through
/// different axis keys; callers that want identity semantics use this
/// iterator with a caller-owned bitset. No hash table, allocator, or hidden
/// large stack object is involved.
pub fn UniqueIterator(comptime Transform: type) type {
    return struct {
        const Self = @This();
        iterator: Iterator(Transform),
        seen: []u64,
        current: ?TargetList = null,
        next_target: u32 = 0,

        pub fn init(iterator: Iterator(Transform), seen: []u64) !Self {
            const words = (@as(usize, iterator.view.entry_count) + 63) / 64;
            if (seen.len < words) return error.OutputTooSmall;
            return .{ .iterator = iterator, .seen = seen[0..words] };
        }

        /// Clears identity marks for a new traversal. The underlying axis
        /// iterator is intentionally not rewound; construct a fresh
        /// `UniqueIterator` when the key traversal itself should restart.
        pub fn clearSeen(self: *Self) void {
            @memset(self.seen, 0);
        }

        pub fn next(self: *Self) !?EntryRank {
            while (true) {
                if (self.current) |targets| {
                    while (self.next_target < targets.len()) : (self.next_target += 1) {
                        const value = @intFromEnum(try targets.target(self.next_target));
                        const word = value / 64;
                        const bit: u6 = @intCast(value & 63);
                        const mask = @as(u64, 1) << bit;
                        if (self.seen[word] & mask != 0) continue;
                        self.seen[word] |= mask;
                        self.next_target += 1;
                        return @enumFromInt(value);
                    }
                }
                const item = (try self.iterator.next()) orelse return null;
                self.current = item.targets;
                self.next_target = 0;
            }
        }
    };
}

/// A query facade applies a transform into caller-provided scratch and then
/// delegates to the single derived-byte reader.  No query allocates.  For a
/// reversed axis, `suffix` is the same operation as `prefix` after reversal.
pub fn Index(comptime Transform: type) type {
    return struct {
        const Self = @This();
        view: ViewFor(Transform),

        pub fn init(view: ViewFor(Transform)) Self {
            return .{ .view = view };
        }

        pub fn exact(self: *const Self, query: []const u8, transform_scratch: []u8) !?ViewFor(Transform).Hit {
            const derived = try Transform.apply(query, transform_scratch);
            return self.view.exact(derived);
        }

        pub fn prefix(self: *const Self, query: []const u8, transform_scratch: []u8, key_scratch: []u8, frames: []automaton.Frame) !Iterator(Transform) {
            const derived = try Transform.apply(query, transform_scratch);
            return self.view.prefix(derived, key_scratch, frames);
        }

        pub fn suffix(self: *const Self, query: []const u8, transform_scratch: []u8, key_scratch: []u8, frames: []automaton.Frame) !Iterator(Transform) {
            comptime if (Transform != Reverse) @compileError("suffix is only defined for the reversed axis");
            const derived = try Reverse.apply(query, transform_scratch);
            var iterator = try self.view.prefix(derived, key_scratch, frames);
            iterator.unreverse_output = true;
            return iterator;
        }
    };
}

/// A source-backed automaton layout.  This is deliberately independent of an
/// axis transform: terms use exactly the same reader for their dictionary.
/// `open` reads the automaton envelope only.  State records, labels, arcs and
/// form targets are requested through `source.bytes` at the moment they are
/// needed.  In particular, there is no `bytes(0, source.len())` escape hatch
/// hidden in this type.
pub fn TargetListFor(comptime Source: type) type {
    return struct {
        source: *const Source,
        payload_base: usize,
        offset: usize,
        limit: usize,
        count: u32,
        entry_count: u32,
        single_rank: ?EntryRank = null,
        packed_width: u8 = 0,
        packed_start: u32 = 0,

        pub fn len(self: @This()) u32 {
            return self.count;
        }

        fn readVar(self: @This(), cursor: *usize) anyerror!u32 {
            var result: u32 = 0;
            var shift: u5 = 0;
            while (true) {
                if (cursor.* >= self.limit) return error.Truncated;
                const bytes = try wire.sourceBytes(Source, self.source, self.payload_base + cursor.*, 1);
                const value = bytes[0];
                cursor.* += 1;
                if (shift == 28 and value > 0x0f) return error.InvalidFormat;
                result |= @as(u32, value & 0x7f) << shift;
                if (value & 0x80 == 0) return result;
                if (shift == 28) return error.InvalidFormat;
                shift += 7;
            }
        }

        pub fn target(self: @This(), index: u32) anyerror!EntryRank {
            if (index >= self.count) return error.RankOutOfRange;
            if (self.single_rank) |value| {
                if (index != 0) return error.RankOutOfRange;
                return value;
            }
            if (self.packed_width != 0) {
                const position = @as(usize, self.packed_start) + index;
                const bit_offset = std.math.mul(usize, position, self.packed_width) catch return error.Overflow;
                const byte_offset = bit_offset / 8;
                const shift: u6 = @intCast(bit_offset & 7);
                if (byte_offset >= self.limit) return error.Truncated;
                const available = self.limit - byte_offset;
                const count_to_read = @min(@as(usize, 5), available);
                if (count_to_read == 0) return error.Truncated;
                const bytes = try wire.sourceBytes(Source, self.source, self.payload_base + byte_offset, count_to_read);
                var word: u64 = 0;
                for (bytes, 0..) |byte, i| word |= @as(u64, byte) << @intCast(i * 8);
                const mask = (@as(u64, 1) << @intCast(self.packed_width)) - 1;
                const value: u32 = @truncate((word >> shift) & mask);
                if (value >= self.entry_count) return error.InvalidTarget;
                return @enumFromInt(value);
            }
            var cursor = self.offset;
            const encoded_count = try self.readVar(&cursor);
            if (encoded_count != self.count) return error.InvalidOutput;
            var previous: u32 = 0;
            for (0..index + 1) |i| {
                const delta = try self.readVar(&cursor);
                const value = if (i == 0) std.math.sub(u32, delta, 1) catch return error.InvalidOutput else std.math.add(u32, previous, delta) catch return error.InvalidOutput;
                if (value >= self.entry_count) return error.InvalidTarget;
                previous = value;
                if (i == index) return @enumFromInt(value);
            }
            return error.InvalidOutput;
        }
    };
}

pub fn openSource(comptime Transform: type, comptime Source: type, source: Source) !ViewForSource(Transform, Source) {
    return ViewForSource(Transform, Source).open(source);
}

fn ViewForSource(comptime Transform: type, comptime Source: type) type {
    return struct {
        const Self = @This();
        pub const Hit = struct { targets: TargetListFor(Source) };
        pub const Item = struct { key: []const u8, targets: TargetListFor(Source) };
        source: Source,
        entry_count: u32,
        key_count: u32,
        index_off: usize,
        index_len: usize,
        payload_off: usize,
        payload_len: usize,
        mode: u8,
        checkpoint_stride: u32,
        inner_base: usize,
        inner: automaton.ViewFor(wire.Span(Source)),

        fn read(self: *const Self, offset: usize, length: usize) anyerror![]const u8 {
            return wire.sourceBytes(Source, &self.source, offset, length);
        }
        fn le(self: *const Self, comptime T: type, offset: usize) anyerror!T {
            const bytes = try self.read(offset, @sizeOf(T));
            return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
        }
        fn packedDirectoryValue(self: *const Self, index: usize) anyerror!u32 {
            const bitmap_len = std.math.divCeil(usize, self.entry_count, 8) catch return error.Overflow;
            const directory_count = (std.math.divCeil(usize, self.entry_count, packed_boundary_stride) catch return error.Overflow) + 1;
            if (index >= directory_count) return error.InvalidOutput;
            return try self.le(u16, self.index_off + bitmap_len + index * 2);
        }
        fn packedStart(self: *const Self, group_rank: u32) anyerror!u32 {
            if (group_rank >= self.key_count) return error.RankOutOfRange;
            const bitmap_len = std.math.divCeil(usize, self.entry_count, 8) catch return error.Overflow;
            const blocks = std.math.divCeil(usize, self.entry_count, packed_boundary_stride) catch return error.Overflow;
            var lo: usize = 0;
            var hi = blocks;
            while (lo + 1 < hi) {
                const mid = lo + (hi - lo) / 2;
                if (try self.packedDirectoryValue(mid) <= group_rank) lo = mid else hi = mid;
            }
            const before = try self.packedDirectoryValue(lo);
            if (before > group_rank) return error.InvalidOutput;
            var needed = group_rank - before;
            const first_byte = lo * (packed_boundary_stride / 8);
            const last_byte = @min(first_byte + packed_boundary_stride / 8, bitmap_len);
            var byte_index = first_byte;
            while (byte_index < last_byte) : (byte_index += 1) {
                var bits = (try self.read(self.index_off + byte_index, 1))[0];
                const count: u32 = @popCount(bits);
                if (needed >= count) {
                    needed -= count;
                    continue;
                }
                while (needed != 0) : (needed -= 1) bits &= bits - 1;
                const position = byte_index * 8 + @as(usize, @intCast(@ctz(bits)));
                if (position >= self.entry_count) return error.InvalidOutput;
                return @intCast(position);
            }
            return error.InvalidOutput;
        }
        fn targetAt(self: *const Self, rank: u32) anyerror!TargetListFor(Source) {
            if (rank >= self.key_count) return error.RankOutOfRange;
            if (self.mode == packed_targets_mode) {
                const start = try self.packedStart(rank);
                const end = if (rank + 1 == self.key_count) self.entry_count else try self.packedStart(rank + 1);
                if (end <= start) return error.InvalidOutput;
                return .{
                    .source = &self.source,
                    .payload_base = self.payload_off,
                    .offset = 0,
                    .limit = self.payload_len,
                    .count = end - start,
                    .entry_count = self.entry_count,
                    .packed_width = try bitWidth(self.entry_count),
                    .packed_start = start,
                };
            }
            if (self.mode == single_target_mode) return .{
                .source = &self.source,
                .payload_base = 0,
                .offset = 0,
                .limit = 0,
                .count = 1,
                .entry_count = self.entry_count,
                .single_rank = try self.targetAtSingle(rank),
            };
            const width: usize = if (self.index_len == self.key_count * 2) 2 else 4;
            const index_at = self.index_off + @as(usize, rank) * width;
            const offset: usize = if (width == 2) try self.le(u16, index_at) else try self.le(u32, index_at);
            const next: usize = if (rank + 1 == self.key_count) self.payload_len else blk: {
                const at = self.index_off + @as(usize, rank + 1) * width;
                break :blk if (width == 2) try self.le(u16, at) else try self.le(u32, at);
            };
            if (next <= offset or next > self.payload_len) return error.InvalidOutput;
            const payload = self.payload_off + offset;
            var cursor = payload;
            var count: u32 = 0;
            var shift: u5 = 0;
            while (true) {
                if (cursor >= self.payload_off + next) return error.Truncated;
                const byte = (try wire.sourceBytes(Source, &self.source, cursor, 1))[0];
                cursor += 1;
                if (shift == 28 and byte > 0x0f) return error.InvalidOutput;
                count |= @as(u32, byte & 0x7f) << shift;
                if (byte & 0x80 == 0) break;
                if (shift == 28) return error.InvalidOutput;
                shift += 7;
            }
            return .{ .source = &self.source, .payload_base = 0, .offset = payload, .limit = self.payload_off + next, .count = count, .entry_count = self.entry_count };
        }

        fn targetAtSingle(self: *const Self, rank: u32) anyerror!EntryRank {
            const checkpoint = rank / self.checkpoint_stride;
            const checkpoint_at = self.index_off + @as(usize, checkpoint) * 8;
            var value = try self.le(u32, checkpoint_at);
            if (value >= self.entry_count) return error.InvalidTarget;
            if (checkpoint * self.checkpoint_stride == rank) return @enumFromInt(value);
            var cursor = self.payload_off + try self.le(u32, checkpoint_at + 4);
            for (checkpoint * self.checkpoint_stride + 1..rank + 1) |_| {
                var encoded: u64 = 0;
                var shift: u6 = 0;
                while (true) {
                    const byte = (try wire.sourceBytes(Source, &self.source, cursor, 1))[0];
                    cursor += 1;
                    encoded |= @as(u64, byte & 0x7f) << shift;
                    if (byte & 0x80 == 0) break;
                    if (shift >= 63) return error.InvalidOutput;
                    shift += 7;
                }
                const magnitude: i64 = @intCast(encoded >> 1);
                const delta = if (encoded & 1 == 0) magnitude else -magnitude - 1;
                const next = @as(i64, value) + delta;
                if (next < 0 or next >= self.entry_count) return error.InvalidTarget;
                value = @intCast(next);
            }
            return @enumFromInt(value);
        }

        pub fn open(source_value: Source) !Self {
            if (wire.sourceLen(Source, &source_value) < header_bytes) return error.Truncated;
            const header = try wire.sourceBytes(Source, &source_value, 0, header_bytes);
            if (!std.mem.eql(u8, header[0..4], magic)) return error.InvalidFormat;
            if (std.mem.readInt(u16, header[4..6], .little) != version) return error.UnsupportedVersion;
            if (header[6] != @intFromEnum(kindFor(Transform))) return error.BadAxis;
            if ((header[7] >> 2) != strategyVersionFor(Transform)) return error.UnsupportedVersion;
            const low_flags = header[7] & 3;
            const mode: u8 = if (low_flags >= single_target_mode) low_flags else 0;
            const entry_count = std.mem.readInt(u32, header[8..12], .little);
            const key_count = std.mem.readInt(u32, header[12..16], .little);
            const inner_off = std.mem.readInt(u32, header[16..20], .little);
            const inner_len = std.mem.readInt(u32, header[20..24], .little);
            const index_off = std.mem.readInt(u32, header[24..28], .little);
            const index_len = std.mem.readInt(u32, header[28..32], .little);
            const payload_off = std.mem.readInt(u32, header[32..36], .little);
            const payload_len = std.mem.readInt(u32, header[36..40], .little);
            const total = std.mem.readInt(u32, header[40..44], .little);
            const stride = std.mem.readInt(u32, header[44..48], .little);
            if (total != wire.sourceLen(Source, &source_value) or entry_count == 0 or key_count == 0) return error.InvalidFormat;
            if (mode == single_target_mode and stride != single_target_stride) return error.InvalidFormat;
            if (mode == packed_targets_mode and stride != packed_boundary_stride) return error.InvalidFormat;
            if (mode == 0 and stride != 0) return error.InvalidFormat;
            const index_width: usize = if (low_flags == 1) 2 else 4;
            const expected_index_len = if (mode == packed_targets_mode) blk: {
                if (key_count > std.math.maxInt(u16)) return error.InvalidFormat;
                const bitmap = std.math.divCeil(usize, entry_count, 8) catch return error.Overflow;
                const blocks = std.math.divCeil(usize, entry_count, packed_boundary_stride) catch return error.Overflow;
                break :blk std.math.add(usize, bitmap, std.math.mul(usize, blocks + 1, 2) catch return error.Overflow) catch return error.Overflow;
            } else blk: {
                const expected_count = if (mode == single_target_mode) (key_count - 1) / single_target_stride + 1 else key_count;
                const expected_width = if (mode == single_target_mode) 8 else index_width;
                break :blk std.math.mul(usize, expected_count, expected_width) catch return error.Overflow;
            };
            if (index_len != expected_index_len or
                (mode == packed_targets_mode and payload_len != try bitsToBytes(entry_count, try bitWidth(entry_count)))) return error.InvalidFormat;
            const index_end = std.math.add(usize, index_off, index_len) catch return error.Overflow;
            const payload_end = std.math.add(usize, payload_off, payload_len) catch return error.Overflow;
            const inner_end = std.math.add(usize, inner_off, inner_len) catch return error.Overflow;
            if (index_off < header_bytes or index_end != payload_off or payload_end != inner_off or inner_end != total) return error.InvalidFormat;
            const inner_source = try wire.Span(Source).init(source_value, inner_off, inner_len);
            const inner = try automaton.ViewFor(wire.Span(Source)).open(inner_source);
            if (inner.entry_count != key_count or inner.accepted_count != key_count) return error.InvalidFormat;
            return .{ .source = source_value, .entry_count = entry_count, .key_count = key_count, .index_off = index_off, .index_len = index_len, .payload_off = payload_off, .payload_len = payload_len, .mode = mode, .checkpoint_stride = stride, .inner_base = inner_off, .inner = inner };
        }

        pub fn exact(self: *const Self, derived: []const u8) !?Self.Hit {
            const hit = (try self.inner.exact(derived)) orelse return null;
            const range = hit.entry_range orelse return error.InvalidOutput;
            if (range.len() != 1) return error.InvalidOutput;
            const base = @intFromEnum(range.lo);
            if (self.mode == single_target_mode) {
                return .{ .targets = try self.targetAt(base) };
            }
            return .{ .targets = try self.targetAt(base) };
        }

        pub fn ledger(self: *const Self) Ledger {
            return .{
                .header = header_bytes,
                .output_index = self.index_len,
                .output_payload = self.payload_len,
                .automaton = self.inner.len(),
                .total = wire.sourceLen(Source, &self.source),
                .mode = self.mode,
            };
        }

        pub fn prefix(self: *const Self, derived_prefix: []const u8, key_scratch: []u8, frames: []automaton.Frame) !IteratorFor(Transform, Source) {
            return .{
                .view = self,
                .inner = try self.inner.prefix(derived_prefix, key_scratch, frames),
            };
        }

        fn verifyLocal(self: *const Self) !void {
            try self.inner.verify();
            if (self.mode == packed_targets_mode) {
                const bitmap_len = std.math.divCeil(usize, self.entry_count, 8) catch return error.Overflow;
                const tail = self.entry_count & 7;
                if (tail != 0) {
                    const last = (try self.read(self.index_off + bitmap_len - 1, 1))[0];
                    if (last & ~((@as(u8, 1) << @intCast(tail)) - 1) != 0) return error.InvalidOutput;
                }
                if (!bitGet(try self.read(self.index_off, bitmap_len), 0)) return error.InvalidOutput;
                var starts: u32 = 0;
                const blocks = std.math.divCeil(usize, self.entry_count, packed_boundary_stride) catch return error.Overflow;
                for (0..blocks + 1) |block| {
                    if (try self.packedDirectoryValue(block) != starts) return error.InvalidOutput;
                    if (block == blocks) continue;
                    const first = block * packed_boundary_stride;
                    const last = @min(first + packed_boundary_stride, self.entry_count);
                    const bytes = try self.read(self.index_off + first / 8, std.math.divCeil(usize, last - first, 8) catch return error.Overflow);
                    for (0..last - first) |position| {
                        if (bitGet(bytes, position)) starts += 1;
                    }
                }
                if (starts != self.key_count) return error.InvalidOutput;
                const width = try bitWidth(self.entry_count);
                const used_bits = std.math.mul(usize, self.entry_count, width) catch return error.Overflow;
                if (used_bits & 7 != 0) {
                    const last = (try self.read(self.payload_off + self.payload_len - 1, 1))[0];
                    if (last & (@as(u8, 0xff) << @intCast(used_bits & 7)) != 0) return error.InvalidOutput;
                }
                var previous: u32 = 0;
                var have_previous = false;
                for (0..self.entry_count) |position| {
                    if (bitGet(try self.read(self.index_off + position / 8, 1), position & 7)) have_previous = false;
                    const list = TargetListFor(Source){
                        .source = &self.source,
                        .payload_base = self.payload_off,
                        .offset = 0,
                        .limit = self.payload_len,
                        .count = 1,
                        .entry_count = self.entry_count,
                        .packed_width = try bitWidth(self.entry_count),
                        .packed_start = @intCast(position),
                    };
                    const value = @intFromEnum(try list.target(0));
                    if (have_previous and value <= previous) return error.InvalidTarget;
                    previous = value;
                    have_previous = true;
                }
                return;
            }
            if (self.mode == single_target_mode) {
                for (0..self.key_count) |rank| _ = try self.targetAtSingle(@intCast(rank));
                return;
            }
            for (0..self.key_count) |rank| _ = try self.targetAt(@intCast(rank));
        }

        /// Adds the global permutation proof required by packed target lanes.
        /// The ordinary source verifier remains allocation-free and proves
        /// every local range; callers performing a deep-open pass provide the
        /// one-bit-per-entry workspace through this explicit allocator seam.
        pub fn verifyWithAllocator(self: *const Self, allocator: std.mem.Allocator) !void {
            try self.verifyLocal();
            if (self.mode != packed_targets_mode) return;
            const seen = try allocator.alloc(u8, std.math.divCeil(usize, self.entry_count, 8) catch return error.Overflow);
            defer allocator.free(seen);
            @memset(seen, 0);
            const width = try bitWidth(self.entry_count);
            for (0..self.entry_count) |position| {
                const list = TargetListFor(Source){
                    .source = &self.source,
                    .payload_base = self.payload_off,
                    .offset = 0,
                    .limit = self.payload_len,
                    .count = 1,
                    .entry_count = self.entry_count,
                    .packed_width = width,
                    .packed_start = @intCast(position),
                };
                const value = @intFromEnum(try list.target(0));
                if (bitGet(seen, value)) return error.InvalidTarget;
                bitSet(seen, value);
            }
        }

        pub fn verify(self: *const Self, allocator: std.mem.Allocator) !void {
            return self.verifyWithAllocator(allocator);
        }
    };
}

pub fn IteratorFor(comptime Transform: type, comptime Source: type) type {
    return struct {
        const Self = @This();
        view: *const ViewForSource(Transform, Source),
        inner: automaton.ViewFor(wire.Span(Source)).Iterator,
        unreverse_output: bool = false,

        pub fn next(self: *Self) !?ViewForSource(Transform, Source).Item {
            const item = (try self.inner.next()) orelse return null;
            if (self.unreverse_output) try reverseScalarsInPlace(@constCast(item.key));
            return .{
                .key = item.key,
                .targets = try self.view.targetAt(@intFromEnum(item.entry_range.lo)),
            };
        }
    };
}

pub fn ViewFor(comptime Transform: type) type {
    return ViewForSource(Transform, []const u8);
}

pub fn SourceView(comptime Transform: type, comptime Source: type) type {
    return ViewForSource(Transform, Source);
}

pub fn Iterator(comptime Transform: type) type {
    return IteratorFor(Transform, []const u8);
}

test "transforms reverse complete UTF-8 scalars and normalize only ASCII" {
    var reverse: [8]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "猫éa", try Reverse.apply("aé猫", &reverse));
    try std.testing.expectError(error.InvalidUtf8, Reverse.apply("a\xff", &reverse));
    var normalized: [8]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "aÉ", try Normalized.apply("AÉ", &normalized));
    var phonetic: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "R163", try Phonetic.apply("Robert", &phonetic));
}
