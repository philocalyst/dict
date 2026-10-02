//! Schema-reflected root prefix construction cuts. Required leading byte fields
//! stay in a hot stream; the complete nested remainder keeps original canonical
//! packet byte adjacency in a cold stream. No descendant structure is rewritten.
const std = @import("std");
const lex = @import("lex6");
const dag = @import("dag");
const col = @import("columns.zig");
pub const Error = col.Error || lex.compression.Error || error{ UnsupportedCodec, ColdField };
pub const Limits = col.Limits;
fn get32(bytes: []const u8, at: usize) usize {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn put32(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, bytes[at..][0..4], @intCast(value), .little);
}
fn isBytes(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child == u8,
        else => false,
    };
}
pub fn cutFields(comptime Root: type) usize {
    comptime var count: usize = 0;
    inline for (@typeInfo(Root).@"struct".fields) |field| {
        if (comptime !isBytes(field.type) or lex.packet.elidable(field)) return count;
        count += 1;
    }
    return count;
}
const Cursor = struct {
    bytes: []const u8,
    at: usize = 0,
    fn varint(self: *Cursor) Error!u64 {
        var value: u64 = 0;
        for (0..10) |i| {
            if (self.at >= self.bytes.len) return error.Truncated;
            const byte = self.bytes[self.at];
            self.at += 1;
            if (i == 9 and byte > 1) return error.IntegerOverflow;
            value |= @as(u64, byte & 127) << @as(u6, @intCast(i * 7));
            if (byte < 128) {
                if (i != 0 and byte == 0) return error.NonCanonicalVarint;
                return value;
            }
        }
        return error.IntegerOverflow;
    }
    fn text(self: *Cursor, limits: lex.packet.Limits) Error![]const u8 {
        const len = try self.varint();
        if (len > limits.max_slice_length) return error.SliceTooLong;
        if (len > self.bytes.len - self.at) return error.Truncated;
        const result = self.bytes[self.at..][0..@intCast(len)];
        self.at += @intCast(len);
        return result;
    }
};
fn digest(bytes: []const u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var out: [32]u8 = undefined;
    hash.update(bytes[0..32]);
    hash.update(bytes[64..]);
    hash.final(&out);
    return out;
}
fn prefixCursor(comptime Root: type, bytes: []const u8) Error!Cursor {
    var cursor = Cursor{ .bytes = bytes };
    if (comptime lex.packet.defaultCount(Root) != 0) _ = try cursor.varint();
    return cursor;
}
/// Derived from the actual leading field declarations and canonical v3 mask.
pub fn encodePackets(comptime Root: type, allocator: std.mem.Allocator, packets: []const []const u8, limits: Limits) Error![]u8 {
    const fields = comptime cutFields(Root);
    if (fields == 0) return error.UnsupportedType;
    if (packets.len > limits.max_roots) return error.TooManyRoots;
    var size = 64 + (packets.len + 1) * 8;
    for (packets) |packet| {
        if (packet.len < 5) return error.Truncated;
        size = std.math.add(usize, size, packet.len - 5) catch return error.PageTooLarge;
    }
    if (size > limits.max_page_bytes) return error.PageTooLarge;
    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    @memset(out[0..64], 0);
    @memcpy(out[0..8], "LPP1\x01\x03\x00\x00");
    std.mem.writeInt(u16, out[6..8], fields, .little);
    put32(out, 8, packets.len);
    put32(out, 12, 2);
    put32(out, 20, size);
    std.mem.writeInt(u64, out[24..32], comptime dag.schemaFingerprint(Root), .little);
    const cuts = try allocator.alloc(usize, packets.len);
    defer allocator.free(cuts);
    var hot_len: usize = 0;
    var cold_len: usize = 0;
    for (packets, cuts, 0..) |packet, *cut, i| {
        _ = try lex.packet_view.open(Root, packet, limits.packet);
        if (packet[4] != 3) return error.UnsupportedVersion;
        var cursor = try prefixCursor(Root, packet[5..]);
        inline for (0..fields) |_| _ = try cursor.text(limits.packet);
        cut.* = 5 + cursor.at;
        put32(out, 64 + i * 8, cold_len);
        put32(out, 64 + i * 8 + 4, hot_len);
        hot_len += cursor.at;
        cold_len += packet.len - cut.*;
    }
    put32(out, 64 + packets.len * 8, cold_len);
    put32(out, 64 + packets.len * 8 + 4, hot_len);
    put32(out, 16, cold_len);
    var hot_at = 64 + (packets.len + 1) * 8;
    var cold_at = hot_at + hot_len;
    for (packets, cuts) |packet, cut| {
        @memcpy(out[hot_at..][0 .. cut - 5], packet[5..cut]);
        hot_at += cut - 5;
        @memcpy(out[cold_at..][0 .. packet.len - cut], packet[cut..]);
        cold_at += packet.len - cut;
    }
    @memcpy(out[32..64], &digest(out));
    return out;
}
pub fn Page(comptime Root: type) type {
    return struct {
        bytes: []const u8,
        count: usize,
        offsets: []const u8,
        hot: []const u8,
        cold: []const u8,
        limits: Limits,
        const Self = @This();
        pub fn restorePacket(self: Self, allocator: std.mem.Allocator, index: usize) Error![]u8 {
            if (index >= self.count) return error.InvalidReference;
            const c = get32(self.offsets, index * 8);
            const h = get32(self.offsets, index * 8 + 4);
            const nc = get32(self.offsets, (index + 1) * 8);
            const nh = get32(self.offsets, (index + 1) * 8 + 4);
            const size = 5 + nc - c + nh - h;
            if (size > self.limits.packet.max_input_bytes) return error.InputTooLarge;
            const out = try allocator.alloc(u8, size);
            @memcpy(out[0..5], "LXP6\x03");
            @memcpy(out[5..][0 .. nh - h], self.hot[h..nh]);
            @memcpy(out[5 + nh - h ..], self.cold[c..nc]);
            return out;
        }
        pub fn decode(self: Self, allocator: std.mem.Allocator, index: usize) Error!lex.packet.Decoded(Root) {
            const packet = try self.restorePacket(allocator, index);
            defer allocator.free(packet);
            return lex.packet.decode(Root, allocator, packet, self.limits.packet);
        }
    };
}
pub fn open(comptime Root: type, bytes: []const u8, limits: Limits) Error!Page(Root) {
    if (bytes.len > limits.max_page_bytes) return error.PageTooLarge;
    if (bytes.len < 64 or !std.mem.eql(u8, bytes[0..6], "LPP1\x01\x03") or std.mem.readInt(u16, bytes[6..8], .little) != (comptime cutFields(Root)) or get32(bytes, 12) != 2 or get32(bytes, 20) != bytes.len) return error.InvalidPage;
    if (std.mem.readInt(u64, bytes[24..32], .little) != comptime dag.schemaFingerprint(Root)) return error.InvalidSchema;
    if (!std.crypto.timing_safe.eql([32]u8, digest(bytes), bytes[32..64].*)) return error.DigestMismatch;
    const count = get32(bytes, 8);
    if (count > limits.max_roots) return error.TooManyRoots;
    const hot_at = 64 + (count + 1) * 8;
    const cold_len = get32(bytes, 16);
    if (hot_at > bytes.len or cold_len > bytes.len - hot_at) return error.InvalidPage;
    const cold_at = bytes.len - cold_len;
    const page = Page(Root){ .bytes = bytes, .count = count, .offsets = bytes[64..hot_at], .hot = bytes[hot_at..cold_at], .cold = bytes[cold_at..], .limits = limits };
    if (get32(page.offsets, 0) != 0 or get32(page.offsets, 4) != 0 or get32(page.offsets, count * 8) != page.cold.len or get32(page.offsets, count * 8 + 4) != page.hot.len) return error.InvalidCheckpoint;
    for (0..count) |i| {
        const c = get32(page.offsets, i * 8);
        const h = get32(page.offsets, i * 8 + 4);
        const nc = get32(page.offsets, (i + 1) * 8);
        const nh = get32(page.offsets, (i + 1) * 8 + 4);
        if (c > nc or h > nh or nc > page.cold.len or nh > page.hot.len) return error.InvalidCheckpoint;
        var cursor = try prefixCursor(Root, page.hot[h..nh]);
        inline for (0..(comptime cutFields(Root))) |_| _ = try cursor.text(limits.packet);
        if (cursor.at != cursor.bytes.len) return error.TrailingBytes;
    }
    return page;
}
const Block = struct { raw: usize, bytes: []const u8, codec: lex.compression.Codec };
fn decompress(allocator: std.mem.Allocator, block: Block, limits: Limits) Error!lex.compression.Block {
    return lex.compression.decode(allocator, block.codec, block.bytes, block.raw, .{ .max_block_bytes = @max(limits.max_page_bytes, lex.compression.min_native_block_bytes) });
}
pub fn Loaded(comptime Root: type) type {
    return struct {
        hot: lex.compression.Block,
        count: usize,
        offsets: []const u8,
        prefixes: []const u8,
        limits: Limits,
        pub fn deinit(self: *@This()) void {
            self.hot.deinit();
            self.* = undefined;
        }
        pub fn field(self: @This(), index: usize, comptime name: anytype) Error!@FieldType(Root, if (@typeInfo(@TypeOf(name)) == .enum_literal) @tagName(name) else name) {
            const selected = comptime if (@typeInfo(@TypeOf(name)) == .enum_literal) @tagName(name) else name;
            if (index >= self.count) return error.InvalidReference;
            const h = get32(self.offsets, index * 8 + 4);
            const nh = get32(self.offsets, (index + 1) * 8 + 4);
            var cursor = try prefixCursor(Root, self.prefixes[h..nh]);
            inline for (@typeInfo(Root).@"struct".fields[0..(comptime cutFields(Root))]) |f| {
                const text = try cursor.text(self.limits.packet);
                if (comptime std.mem.eql(u8, selected, f.name)) return text;
            }
            return error.ColdField;
        }
    };
}
pub fn Admitted(comptime Root: type) type {
    return struct {
        bytes: []const u8,
        hot: Block,
        cold: Block,
        count: usize,
        limits: Limits,
        pub fn loadHot(self: @This(), allocator: std.mem.Allocator) Error!Loaded(Root) {
            const hot = try decompress(allocator, self.hot, self.limits);
            const offset_bytes = (self.count + 1) * 8;
            return .{ .hot = hot, .count = self.count, .offsets = hot.bytes[0..offset_bytes], .prefixes = hot.bytes[offset_bytes..], .limits = self.limits };
        }
        pub fn restorePage(self: @This(), allocator: std.mem.Allocator) Error![]u8 {
            var hot = try decompress(allocator, self.hot, self.limits);
            defer hot.deinit();
            var cold = try decompress(allocator, self.cold, self.limits);
            defer cold.deinit();
            const out = try allocator.alloc(u8, 64 + hot.raw_len + cold.raw_len);
            @memcpy(out[0..64], self.bytes[16..80]);
            @memcpy(out[64..][0..hot.raw_len], hot.bytes);
            @memcpy(out[64 + hot.raw_len ..], cold.bytes);
            return out;
        }
    };
}
/// Full admission; immutable compressed bytes then support hot-only root reads.
pub fn admit(comptime Root: type, allocator: std.mem.Allocator, bytes: []const u8, limits: Limits, scope: lex.validate.Scope) Error!Admitted(Root) {
    if (comptime Root != lex.model.Entry) return error.SemanticAdmissionUnavailable;
    if (bytes.len < 112 or !std.mem.eql(u8, bytes[0..8], "LCP1\x01\x00\x00\x00") or get32(bytes, 8) != 2) return error.InvalidPage;
    const raw = get32(bytes, 12);
    if (raw < 64 or raw > limits.max_page_bytes) return error.PageTooLarge;
    var blocks: [2]Block = undefined;
    var at: usize = 112;
    for (&blocks, 0..) |*block, i| {
        const directory = 80 + i * 16;
        const original = get32(bytes, directory);
        const stored = get32(bytes, directory + 4);
        if (original > raw or get32(bytes, directory + 8) != at or stored > bytes.len - at or !std.mem.eql(u8, bytes[directory + 13 .. directory + 16], &.{ 0, 0, 0 })) return error.InvalidPage;
        const codec = std.enums.fromInt(lex.compression.Codec, bytes[directory + 12]) orelse return error.UnsupportedCodec;
        block.* = .{ .raw = original, .bytes = bytes[at..][0..stored], .codec = codec };
        at += stored;
    }
    if (at != bytes.len or blocks[0].raw + blocks[1].raw != raw - 64) return error.InvalidPage;
    const admitted = Admitted(Root){ .bytes = bytes, .hot = blocks[0], .cold = blocks[1], .count = get32(bytes, 24), .limits = limits };
    const restored = try admitted.restorePage(allocator);
    defer allocator.free(restored);
    const page = try open(Root, restored, limits);
    for (0..page.count) |root| {
        var native = try page.decode(allocator, root);
        defer native.deinit();
        try lex.validate.check(allocator, &native.value, scope);
    }
    return admitted;
}
