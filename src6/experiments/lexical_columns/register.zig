//! Compound generic literal-register/bzip3 cold blocks over reflected packets.
//! Full admission checks all inverse operators, original SHA256, native schema,
//! lexical semantics and decoded size before issuing a hot-only query proof.
const std = @import("std");
const lex = @import("lex6");
const prefix = @import("prefix.zig");
pub const Limits = prefix.Limits;
pub const Error = prefix.Error || error{ ConstructorLimit, InvalidConstructor, UnsupportedConstruction };
extern fn lex_register_inverse(mode: c_uint, source: [*]const u8, input_length: usize, output: [*]u8, output_capacity: usize, output_length: *usize) c_int;
fn get32(bytes: []const u8, at: usize) usize {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
const Block = struct { raw: usize, bytes: []const u8, codec: lex.compression.Codec, transformed: bool = false, intermediate: usize = 0 };
fn backend(allocator: std.mem.Allocator, block: Block, limits: Limits) Error!lex.compression.Block {
    return lex.compression.decode(allocator, block.codec, block.bytes, if (block.transformed) block.intermediate else block.raw, .{ .max_block_bytes = @max(limits.max_page_bytes, lex.compression.min_native_block_bytes) });
}
fn coldInverse(allocator: std.mem.Allocator, block: Block, mode: u8, limits: Limits) Error![]u8 {
    var stage = try backend(allocator, block, limits);
    defer stage.deinit();
    if (!block.transformed) return allocator.dupe(u8, stage.bytes);
    if (block.intermediate > 131072 or block.raw > 262144) return error.ConstructorLimit;
    const raw = try allocator.alloc(u8, block.raw);
    errdefer allocator.free(raw);
    var length: usize = 0;
    if (lex_register_inverse(mode, stage.bytes.ptr, stage.bytes.len, raw.ptr, raw.len, &length) != 0) return error.InvalidConstructor;
    if (length != raw.len) return error.OutputSizeMismatch;
    return raw;
}
pub fn Admitted(comptime Root: type) type {
    return struct {
        bytes: []const u8,
        hot: Block,
        cold: Block,
        mode: u8,
        count: usize,
        limits: Limits,
        pub fn loadHot(self: @This(), allocator: std.mem.Allocator) Error!prefix.Loaded(Root) {
            const hot = try backend(allocator, self.hot, self.limits);
            const offsets = (self.count + 1) * 8;
            return .{ .hot = hot, .count = self.count, .offsets = hot.bytes[0..offsets], .prefixes = hot.bytes[offsets..], .limits = self.limits };
        }
        /// Factory under this immutable complete native admission proof. All
        /// reconstruction operators and extents were checked during admit;
        /// packet views can borrow the freshly restored canonical root bytes.
        pub fn loadFull(self: @This(), allocator: std.mem.Allocator) Error!OwnedPage(Root) {
            const raw = try self.restorePage(allocator);
            const hot_at = 64 + (self.count + 1) * 8;
            const cold_at = raw.len - self.cold.raw;
            return .{ .allocator = allocator, .bytes = raw, .page = .{ .bytes = raw, .count = self.count, .offsets = raw[64..hot_at], .hot = raw[hot_at..cold_at], .cold = raw[cold_at..], .limits = self.limits } };
        }
        pub fn restorePage(self: @This(), allocator: std.mem.Allocator) Error![]u8 {
            var hot = try backend(allocator, self.hot, self.limits);
            defer hot.deinit();
            const cold = try coldInverse(allocator, self.cold, self.mode, self.limits);
            defer allocator.free(cold);
            const raw = try allocator.alloc(u8, 64 + hot.bytes.len + cold.len);
            @memcpy(raw[0..64], self.bytes[16..80]);
            @memcpy(raw[64..][0..hot.bytes.len], hot.bytes);
            @memcpy(raw[64 + hot.bytes.len ..], cold);
            return raw;
        }
    };
}
pub fn OwnedPage(comptime Root: type) type {
    return struct {
        allocator: std.mem.Allocator,
        bytes: []u8,
        page: prefix.Page(Root),
        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.bytes);
            self.* = undefined;
        }
    };
}
/// Native constructor resources are capped before every C++ call. Oversized
/// pages remain eligible for ordinary cold blocks, with no constructor flag.
pub fn admit(comptime Root: type, allocator: std.mem.Allocator, bytes: []const u8, limits: Limits, scope: lex.validate.Scope) Error!Admitted(Root) {
    if (comptime Root != lex.model.Entry) return error.SemanticAdmissionUnavailable;
    if (bytes.len < 112 or !std.mem.eql(u8, bytes[0..5], "LCP2\x01") or bytes[5] > 2 or bytes[6] != 1 or bytes[7] != 0 or get32(bytes, 8) != 2) return error.InvalidPage;
    const raw = get32(bytes, 12);
    if (raw < 64 or raw > limits.max_page_bytes) return error.PageTooLarge;
    if (get32(bytes, 36) != raw) return error.InvalidPage;
    const count = get32(bytes, 24);
    if (count > limits.max_roots) return error.TooManyRoots;
    var blocks: [2]Block = undefined;
    var at: usize = 112;
    for (&blocks, 0..) |*block, i| {
        const directory = 80 + i * 16;
        const original = get32(bytes, directory);
        const stored = get32(bytes, directory + 4);
        const tag = bytes[directory + 12];
        if (original > raw or get32(bytes, directory + 8) != at or stored > bytes.len - at or !std.mem.eql(u8, bytes[directory + 13 .. directory + 16], &.{ 0, 0, 0 })) return error.InvalidPage;
        const transformed = tag & 0x80 != 0;
        const codec = std.enums.fromInt(lex.compression.Codec, tag & 0x7f) orelse return error.UnsupportedCodec;
        var encoded = bytes[at..][0..stored];
        var intermediate: usize = 0;
        if (transformed) {
            if (i != 1 or bytes[5] == 0 or codec != .bzip3 or encoded.len < 4) return error.UnsupportedConstruction;
            intermediate = get32(encoded, 0);
            if (intermediate == 0 or intermediate > 131072 or original > 262144) return error.ConstructorLimit;
            encoded = encoded[4..];
        }
        block.* = .{ .raw = original, .bytes = encoded, .codec = codec, .transformed = transformed, .intermediate = intermediate };
        at += stored;
    }
    if (at != bytes.len or blocks[0].raw + blocks[1].raw != raw - 64) return error.InvalidPage;
    const admitted = Admitted(Root){ .bytes = bytes, .hot = blocks[0], .cold = blocks[1], .mode = bytes[5], .count = count, .limits = limits };
    const restored = try admitted.restorePage(allocator);
    defer allocator.free(restored);
    const page = try prefix.open(Root, restored, limits);
    for (0..page.count) |root| {
        var native = try page.decode(allocator, root);
        defer native.deinit();
        try lex.validate.check(allocator, &native.value, scope);
    }
    return admitted;
}
