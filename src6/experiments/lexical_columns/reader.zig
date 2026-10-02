//! Immutable compressed cursor-lane frames, admitted once, decoded by projection.
//! Admission checks all blocks, restored SHA256, full native semantics. Resident
//! query pages can omit the cold lane: typed skips consult admitted lengths.
const std = @import("std");
const lex = @import("lex6");
const col = @import("columns.zig");
pub const Error = col.Error || lex.compression.Error || error{UnsupportedCodec};
fn get32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
const Block = struct { raw: usize, bytes: []const u8, codec: lex.compression.Codec };
fn decompress(allocator: std.mem.Allocator, block: Block, limits: col.Limits) Error!lex.compression.Block {
    return lex.compression.decode(allocator, block.codec, block.bytes, block.raw, .{ .max_block_bytes = @max(limits.max_page_bytes, lex.compression.min_native_block_bytes) });
}
pub fn Loaded(comptime Root: type) type {
    return struct {
        hot: lex.compression.Block,
        cold: ?lex.compression.Block,
        prepared: col.PreparedPage(Root),
        pub fn deinit(self: *@This()) void {
            if (self.cold) |*b| b.deinit();
            self.hot.deinit();
            self.* = undefined;
        }
        pub fn view(self: @This(), index: usize) Error!col.View(Root, Root) {
            return self.prepared.view(index);
        }
        pub fn decodedBytes(self: @This()) usize {
            return self.hot.raw_len + if (self.cold) |b| b.raw_len else 0;
        }
    };
}
pub fn Admitted(comptime Root: type) type {
    return struct {
        bytes: []const u8,
        hot: Block,
        cold: Block,
        count: usize,
        metadata_bytes: usize,
        lane_lengths: [col.laneCount(Root)]usize,
        threshold: u16,
        limits: col.Limits,
        pub fn load(self: @This(), allocator: std.mem.Allocator, include_cold: bool) Error!Loaded(Root) {
            var hot = try decompress(allocator, self.hot, self.limits);
            errdefer hot.deinit();
            var cold: ?lex.compression.Block = null;
            errdefer {
                if (cold) |*b| b.deinit();
            }
            if (include_cold) cold = try decompress(allocator, self.cold, self.limits);
            const n = comptime col.laneCount(Root);
            const cp_at = (self.count + 1) * 4;
            const len_at = cp_at + (self.count + 1) * n * 4;
            const structure_at = len_at + n * 4;
            var page = col.Page(Root){ .bytes = self.bytes[16..80], .count = self.count, .offsets = hot.bytes[0..cp_at], .checkpoints = hot.bytes[cp_at..len_at], .skeleton = hot.bytes[structure_at..self.metadata_bytes], .lanes = undefined, .lane_lengths = self.lane_lengths, .threshold = self.threshold, .limits = self.limits };
            var at = self.metadata_bytes;
            for (&page.lanes, 0..) |*lane, i| {
                if (i == 1) {
                    lane.* = if (cold) |b| b.bytes else &.{};
                    page.resident[i] = include_cold;
                } else {
                    lane.* = hot.bytes[at..][0..self.lane_lengths[i]];
                    at += self.lane_lengths[i];
                }
            }
            return .{ .hot = hot, .cold = cold, .prepared = .{ .page = page } };
        }
    };
}
/// Input bytes must remain immutable for the lifetime of the admitted frame.
pub fn open(comptime Root: type, allocator: std.mem.Allocator, bytes: []const u8, limits: col.Limits, scope: lex.validate.Scope) Error!Admitted(Root) {
    if (bytes.len < 112 or !std.mem.eql(u8, bytes[0..8], "LCC1\x01\x01\x00\x00") or get32(bytes, 8) != 2) return error.InvalidPage;
    const raw = get32(bytes, 12);
    if (raw < col.header_size) return error.InvalidPage;
    if (raw > limits.max_page_bytes) return error.PageTooLarge;
    if (get32(bytes, 36) != raw) return error.InvalidPage;
    var blocks: [2]Block = undefined;
    var at: usize = 112;
    for (&blocks, 0..) |*block, i| {
        const dir = 80 + i * 16;
        const original = get32(bytes, dir);
        const stored = get32(bytes, dir + 4);
        if (original > raw or get32(bytes, dir + 8) != at or stored > bytes.len - at or !std.mem.eql(u8, bytes[dir + 13 .. dir + 16], &.{ 0, 0, 0 })) return error.InvalidPage;
        const codec = std.enums.fromInt(lex.compression.Codec, bytes[dir + 12]) orelse return error.UnsupportedCodec;
        block.* = .{ .raw = original, .bytes = bytes[at..][0..stored], .codec = codec };
        at += stored;
    }
    if (at != bytes.len or blocks[0].raw + blocks[1].raw != raw - col.header_size) return error.InvalidPage;
    var hot = try decompress(allocator, blocks[0], limits);
    defer hot.deinit();
    var cold = try decompress(allocator, blocks[1], limits);
    defer cold.deinit();
    if (hot.bytes.len < 16) return error.InvalidPage;
    const count = get32(bytes, 24);
    const n = comptime col.laneCount(Root);
    if (count > limits.max_roots or get32(bytes, 28) != n) return error.InvalidPage;
    const len_at = (@as(usize, count) + 1) * (n + 1) * 4;
    const meta = len_at + n * 4 + get32(bytes, 32);
    if (meta > hot.bytes.len) return error.InvalidPage;
    var lengths: [n]usize = undefined;
    for (&lengths, 0..) |*length, i| length.* = get32(hot.bytes, len_at + i * 4);
    var sum: usize = 0;
    for (lengths, 0..) |len, i| {
        if (len > raw) return error.InvalidPage;
        if (i != 1) sum += len;
    }
    if (meta + sum != hot.bytes.len or lengths[1] != cold.bytes.len) return error.InvalidPage;
    const restored = try allocator.alloc(u8, raw);
    defer allocator.free(restored);
    @memcpy(restored[0..64], bytes[16..80]);
    @memcpy(restored[64..][0 .. meta + lengths[0]], hot.bytes[0 .. meta + lengths[0]]);
    @memcpy(restored[64 + meta + lengths[0] ..][0..lengths[1]], cold.bytes);
    @memcpy(restored[64 + meta + lengths[0] + lengths[1] ..], hot.bytes[meta + lengths[0] ..]);
    const page = try col.open(Root, restored, limits);
    _ = try page.prepare(allocator, scope);
    return .{ .bytes = bytes, .hot = blocks[0], .cold = blocks[1], .count = count, .metadata_bytes = meta, .lane_lengths = lengths, .threshold = page.threshold, .limits = limits };
}
