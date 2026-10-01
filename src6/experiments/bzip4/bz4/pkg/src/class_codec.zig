//! Wire encode/decode of a `classes.Model`: the induced byte classes, the
//! (usually tiny) override list, and the C x (C+1) transition-count table.
//! This is the "class model" half of the frame's MODEL segment (see
//! `frame.zig`); `model_codec.zig` is the other half (the lexicon itself).
//!
//! Ported and reshaped from `k_classes.zig`'s `encodeTableBytes`/
//! `decodeTableBytes`/`encodeOverrideBytes`/`decodeOverrideBytes` (Lane K)
//! per PLAN.md's copy-and-reshape rule, narrowed to the one-map model
//! `classes.zig` builds (see that file's doc comment for why) and merged
//! into a single range-coder stream. `C` is written as 4 raw bytes ahead
//! of the coded stream so `decode` is self-describing (the frame header
//! carries no class-model-specific fields).

const std = @import("std");
const rc = @import("range_coder.zig");
const coding = @import("coding.zig");
const classes = @import("classes.zig");

const MAX_C: u32 = 1 << 16;

pub fn encode(alloc: std.mem.Allocator, model: *const classes.Model) ![]u8 {
    const bits = coding.bitsFor(model.C);
    var enc = rc.Encoder.init(alloc);
    defer enc.deinit();

    for (0..256) |i| try enc.encodeDirect(model.byte_class[i], bits);

    var tctx = coding.GammaCtx{};
    for (model.T) |v| try coding.gammaEncode(&enc, &tctx, v);

    try enc.encodeDirect(@intCast(model.override_ids.len), 24);
    var gctx = coding.GammaCtx{};
    var prev: u32 = 0;
    for (model.override_ids, model.override_classes) |id, cls| {
        const idx0 = id - 256;
        try coding.gammaEncode(&enc, &gctx, idx0 - prev);
        try enc.encodeDirect(cls, bits);
        prev = idx0 + 1;
    }
    const body = try enc.finish();

    var out: std.ArrayList(u8) = .empty;
    var cbuf: [4]u8 = undefined;
    std.mem.writeInt(u32, &cbuf, model.C, .little);
    try out.appendSlice(alloc, &cbuf);
    try out.appendSlice(alloc, body);
    return out.toOwnedSlice(alloc);
}

pub const Decoded = struct {
    C: u32,
    byte_class: [256]u32,
    override_ids: []u32,
    override_classes: []u32,
    T: []u32,

    pub fn deinit(self: *Decoded, alloc: std.mem.Allocator) void {
        alloc.free(self.override_ids);
        alloc.free(self.override_classes);
        alloc.free(self.T);
    }
};

pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) !Decoded {
    if (bytes.len < 4) return error.Truncated;
    const C = std.mem.readInt(u32, bytes[0..4], .little);
    if (C == 0 or C > MAX_C) return error.CorruptModel;
    const body = bytes[4..];

    var dec = rc.Decoder.init(body);
    const bits = coding.bitsFor(C);
    var byte_class: [256]u32 = undefined;
    for (0..256) |i| {
        const c = dec.decodeDirect(bits);
        if (c >= C) return error.CorruptModel;
        byte_class[i] = c;
    }

    const table_cells: u64 = @as(u64, C + 1) * @as(u64, C);
    if (table_cells > (1 << 24)) return error.CorruptModel;
    const T = try alloc.alloc(u32, @intCast(table_cells));
    errdefer alloc.free(T);
    var tctx = coding.GammaCtx{};
    for (T) |*v| v.* = try coding.gammaDecode(&dec, &tctx);

    const n_over = dec.decodeDirect(24);
    if (n_over > (1 << 24)) return error.CorruptModel;
    const override_ids = try alloc.alloc(u32, n_over);
    errdefer alloc.free(override_ids);
    const override_classes = try alloc.alloc(u32, n_over);
    errdefer alloc.free(override_classes);
    var gctx = coding.GammaCtx{};
    var prev: u32 = 0;
    for (0..n_over) |i| {
        const gap = try coding.gammaDecode(&dec, &gctx);
        const idx0 = prev +% gap;
        if (idx0 < prev) return error.CorruptModel; // overflow guard
        override_ids[i] = idx0 + 256;
        const c = dec.decodeDirect(bits);
        if (c >= C) return error.CorruptModel;
        override_classes[i] = c;
        prev = idx0 + 1;
    }

    return .{ .C = C, .byte_class = byte_class, .override_ids = override_ids, .override_classes = override_classes, .T = T };
}

test "class model round-trips through bytes" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const lexicon = @import("lexicon.zig");
    const topology = @import("topology.zig");
    const learn = @import("learn.zig");

    const raw = "the cat sat on the mat. the dog sat on the log. the cat ran and the dog ran. " ** 15;
    var corpus = try lexicon.seedBytes(a, raw, 4096);
    var log: std.ArrayList(learn.IterLog) = .empty;
    try learn.iterate(a, &corpus, raw, .{ .max_iters = 6 }, &log);

    const order = try topology.topoOrder(a, &corpus.lex);
    const info = try topology.buildSymInfo(a, &corpus.lex, order);
    const g = try classes.computeRootCounts(a, &corpus);
    var built = try classes.learnAndBuild(a, &corpus, order, info, g, .{ .C = 8, .g_min = 2 });

    const bytes = try encode(a, &built.model);
    var decoded = try decode(a, bytes);

    try std.testing.expectEqual(built.model.C, decoded.C);
    try std.testing.expectEqualSlices(u32, &built.model.byte_class, &decoded.byte_class);
    try std.testing.expectEqualSlices(u32, built.model.T, decoded.T);
    try std.testing.expectEqualSlices(u32, built.model.override_ids, decoded.override_ids);
    try std.testing.expectEqualSlices(u32, built.model.override_classes, decoded.override_classes);

    var overrides: std.AutoHashMapUnmanaged(u32, u32) = .{};
    for (decoded.override_ids, decoded.override_classes) |id, cls| try overrides.put(a, id, cls);
    const resolved = try classes.resolveFromOverrides(a, &corpus.lex, order, decoded.byte_class, overrides);
    try std.testing.expectEqualSlices(u32, built.model.resolved_b, resolved.b);
    try std.testing.expectEqualSlices(u32, built.model.resolved_a, resolved.a);
}
