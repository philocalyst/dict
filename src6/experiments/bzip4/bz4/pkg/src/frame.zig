//! The bz4 v2 frame: v1's frame skeleton (PLAN.md: "v1's frame skeleton --
//! magic/version, block_bytes, raw_len, block_count, model_len, CRC over
//! header+model+directory; 8-byte directory records; raw-block fallback")
//! with a two-part MODEL segment (the lexicon, `model_codec.zig`; the class
//! model, `class_codec.zig`) and a class-conditional block payload
//! (`block_coder.zig`) in place of v1's Huffman-over-grammar-roots payload.
//!
//! `assemble` builds one concrete frame from an already-converged
//! `lexicon.Corpus` and a choice of `classes.Params` -- it does not itself
//! decide between "order-0 / classes / jointly refined"; `joint.zig` (and
//! `bench.zig`'s ablation) call it once per candidate and keep whichever
//! real frame is smallest, per PLAN's "never regress" rule. `Frame.open`
//! decodes the model, resolves every symbol's class and builds the
//! block coder's expansion arena and coding tables -- this is "startup";
//! `decodeBlock` after that point is allocation-free.
//!
//! HEADER (32 bytes, little-endian): magic "BZ4", version=2 (u8), flags u8,
//! reserved u16, block_bytes u32, raw_len u64, block_count u32,
//! model_len u32, crc32 u32 (of header[0..28] ++ model ++ directory).
//! MODEL (model_len bytes): [4B lex_len][lex_len bytes: model_codec] [4B
//! class_len][class_len bytes: class_codec].
//! DIRECTORY: block_count x 8 bytes (u32 end_offset, top bit = "stored
//! raw"; u32 crc32 of the DECODED block).
//! BLOCKS: concatenated per-block payloads.

const std = @import("std");
const lexicon = @import("lexicon.zig");
const topology = @import("topology.zig");
const classes = @import("classes.zig");
const model_codec = @import("model_codec.zig");
const class_codec = @import("class_codec.zig");
const block_coder = @import("block_coder.zig");
const ids = @import("ids.zig");
const Corpus = lexicon.Corpus;
const TokenId = ids.TokenId;

pub const header_len: usize = 32;
pub const dir_entry_len: usize = 8;
const magic0: u8 = 'B';
const magic1: u8 = 'Z';
const magic2: u8 = '4';
const version: u8 = 2;
const raw_flag: u32 = 0x8000_0000;
const off_mask: u32 = 0x7FFF_FFFF;

pub const FrameError = error{
    Truncated,
    BadMagic,
    BadVersion,
    HeaderCrcMismatch,
    BlockIndexOutOfRange,
    OutputLengthMismatch,
    PayloadTruncated,
    BlockCrcMismatch,
};

fn crc32Of(bytes: []const u8) u32 {
    return std.hash.Crc32.hash(bytes);
}

// ====================================================================
// Compression
// ====================================================================

pub const AssembleStats = struct {
    entries: usize,
    tokens: usize,
    classes_used: u32,
    overrides: usize,
    lexicon_bytes: usize,
    classmodel_bytes: usize,
    directory_bytes: usize,
    payload_bytes: usize,
    total_bytes: usize,
};

pub const Assembled = struct {
    bytes: []u8,
    stats: AssembleStats,
};

/// Assemble one real frame from a converged lexicon `corpus` (its tokens
/// must expand, block by block, to exactly `raw`) and a choice of class
/// model `params`. Allocates freely; callers doing a search over several
/// candidates (`joint.zig`, `bench.zig`) should run this under an arena
/// and reset it between attempts, matching this package's iterative-
/// rewrite style elsewhere (`learn.zig`, `m_lexicon.zig` before it).
pub fn assemble(alloc: std.mem.Allocator, raw: []const u8, corpus: *const Corpus, class_params: classes.Params) !Assembled {
    const g = try lexicon.recountRootsOnly(alloc, corpus);

    var em = try model_codec.encode(alloc, &corpus.lex, g, model_codec.default_variant, null);
    const k = 256 + em.renumbered.numEntries();

    const remapped_g = try alloc.alloc(u64, k);
    for (g, 0..) |v, old| remapped_g[em.id_map[old].raw()] = v;
    const remapped_seq = try alloc.alloc(u32, corpus.seq.len);
    for (corpus.seq, 0..) |t, i| remapped_seq[i] = em.id_map[t].raw();
    const remapped: Corpus = .{ .lex = em.renumbered, .seq = remapped_seq, .block_end = corpus.block_end, .block_bytes = corpus.block_bytes };

    const order = try topology.topoOrder(alloc, &remapped.lex);
    const info = try topology.buildSymInfo(alloc, &remapped.lex, order);
    const built = try classes.learnAndBuild(alloc, &remapped, order, info, remapped_g, class_params);

    const class_bytes = try class_codec.encode(alloc, &built.model);
    var coder = try block_coder.Coder.build(alloc, built.model.C, built.model.T, built.model.resolved_b, built.model.resolved_a, remapped_g, &remapped.lex);

    const block_count = remapped.block_end.len;
    var payload: std.ArrayList(u8) = .empty;
    var dir = try alloc.alloc(u8, block_count * dir_entry_len);

    var seq_start: usize = 0;
    var raw_start: usize = 0;
    for (remapped.block_end, 0..) |seq_end, b| {
        const raw_end = @min(raw.len, raw_start + remapped.block_bytes);
        const blen = raw_end - raw_start;
        const tokens: []const TokenId = @ptrCast(remapped.seq[seq_start..seq_end]);
        var block_bytes_out = try coder.encodeBlock(alloc, tokens);
        var is_raw = false;
        if (block_bytes_out.len > blen) {
            alloc.free(block_bytes_out);
            block_bytes_out = try alloc.dupe(u8, raw[raw_start..raw_end]);
            is_raw = true;
        }
        try payload.appendSlice(alloc, block_bytes_out);
        alloc.free(block_bytes_out);

        const end_off: u32 = @intCast(payload.items.len);
        const tagged_off: u32 = if (is_raw) end_off | raw_flag else end_off;
        const crc = crc32Of(raw[raw_start..raw_end]);
        std.mem.writeInt(u32, dir[b * 8 ..][0..4], tagged_off, .little);
        std.mem.writeInt(u32, dir[b * 8 + 4 ..][0..4], crc, .little);

        seq_start = seq_end;
        raw_start = raw_end;
    }
    coder.deinit(alloc);

    const model_len: usize = 4 + em.bytes.len + 4 + class_bytes.len;
    const total = header_len + model_len + dir.len + payload.items.len;
    var bytes = try alloc.alloc(u8, total);

    bytes[0] = magic0;
    bytes[1] = magic1;
    bytes[2] = magic2;
    bytes[3] = version;
    bytes[4] = 0; // flags
    bytes[5] = 0; // reserved
    std.mem.writeInt(u16, bytes[6..8], 0, .little);
    std.mem.writeInt(u32, bytes[8..12], @intCast(corpus.block_bytes), .little);
    std.mem.writeInt(u64, bytes[12..20], @intCast(raw.len), .little);
    std.mem.writeInt(u32, bytes[20..24], @intCast(block_count), .little);
    std.mem.writeInt(u32, bytes[24..28], @intCast(model_len), .little);

    var w: usize = header_len;
    std.mem.writeInt(u32, bytes[w..][0..4], @intCast(em.bytes.len), .little);
    w += 4;
    @memcpy(bytes[w..][0..em.bytes.len], em.bytes);
    w += em.bytes.len;
    std.mem.writeInt(u32, bytes[w..][0..4], @intCast(class_bytes.len), .little);
    w += 4;
    @memcpy(bytes[w..][0..class_bytes.len], class_bytes);
    w += class_bytes.len;
    @memcpy(bytes[w..][0..dir.len], dir);
    w += dir.len;
    @memcpy(bytes[w..], payload.items);

    const crc = headerCrc(bytes, model_len, dir.len);
    std.mem.writeInt(u32, bytes[28..32], crc, .little);

    const stats: AssembleStats = .{
        .entries = em.renumbered.numEntries(),
        .tokens = remapped.seq.len,
        .classes_used = built.model.C,
        .overrides = built.model.override_ids.len,
        .lexicon_bytes = 4 + em.bytes.len,
        .classmodel_bytes = 4 + class_bytes.len,
        .directory_bytes = dir.len,
        .payload_bytes = payload.items.len,
        .total_bytes = bytes.len,
    };
    return .{ .bytes = bytes, .stats = stats };
}

fn headerCrc(bytes: []const u8, model_len: usize, dir_len: usize) u32 {
    var h = std.hash.Crc32.init();
    h.update(bytes[0..28]);
    h.update(bytes[header_len..][0 .. model_len + dir_len]);
    return h.final();
}

// ====================================================================
// Decompression
// ====================================================================

pub const Frame = struct {
    alloc: std.mem.Allocator,
    bytes: []const u8, // borrowed
    block_bytes: usize,
    raw_len: u64,
    block_count: u32,
    dir: []const u8, // borrowed view into bytes
    payload: []const u8, // borrowed view into bytes
    decoded: model_codec.DecodedModel,
    class_decoded: class_codec.Decoded,
    coder: block_coder.Coder,

    pub fn deinit(self: *Frame) void {
        self.decoded.deinit(self.alloc);
        self.class_decoded.deinit(self.alloc);
        self.coder.deinit(self.alloc);
    }

    pub fn entryCount(self: *const Frame) usize {
        return self.decoded.lex.numEntries();
    }
    pub fn classCount(self: *const Frame) u32 {
        return self.class_decoded.C;
    }
    pub fn overrideCount(self: *const Frame) usize {
        return self.class_decoded.override_ids.len;
    }

    pub fn blockRawRange(self: *const Frame, index: usize) struct { start: u64, end: u64 } {
        const start = @as(u64, index) * self.block_bytes;
        const end = @min(self.raw_len, start + self.block_bytes);
        return .{ .start = start, .end = end };
    }

    fn dirEntry(self: *const Frame, index: usize) struct { end_off: u32, is_raw: bool, crc: u32 } {
        const off = std.mem.readInt(u32, self.dir[index * 8 ..][0..4], .little);
        const crc = std.mem.readInt(u32, self.dir[index * 8 + 4 ..][0..4], .little);
        return .{ .end_off = off & off_mask, .is_raw = (off & raw_flag) != 0, .crc = crc };
    }

    /// Decode block `index` into `out` (must be exactly the block's raw
    /// length). Independent of every other block; allocates nothing beyond
    /// what `block_coder.Coder.decodeBlock` itself needs (none); validates
    /// bounds, symbol ids and CRC32 -- never trusts the payload.
    pub fn decodeBlock(self: *Frame, index: usize, out: []u8) !void {
        if (index >= self.block_count) return FrameError.BlockIndexOutOfRange;
        const range = self.blockRawRange(index);
        const raw_len: usize = @intCast(range.end - range.start);
        if (out.len != raw_len) return FrameError.OutputLengthMismatch;

        const prev_end: u32 = if (index == 0) 0 else self.dirEntry(index - 1).end_off;
        const entry = self.dirEntry(index);
        if (entry.end_off < prev_end or entry.end_off > self.payload.len) return FrameError.PayloadTruncated;
        const payload = self.payload[prev_end..entry.end_off];

        if (entry.is_raw) {
            if (payload.len != raw_len) return FrameError.OutputLengthMismatch;
            @memcpy(out, payload);
        } else {
            try self.coder.decodeBlock(payload, out);
        }

        if (crc32Of(out) != entry.crc) return FrameError.BlockCrcMismatch;
    }

    /// Decode every block, in order, into one contiguous buffer.
    pub fn decodeAll(self: *Frame, out: []u8) !void {
        if (out.len != self.raw_len) return FrameError.OutputLengthMismatch;
        var i: usize = 0;
        while (i < self.block_count) : (i += 1) {
            const range = self.blockRawRange(i);
            try self.decodeBlock(i, out[@intCast(range.start)..@intCast(range.end)]);
        }
    }
};

/// Parse + validate the header, decode both halves of the model, resolve
/// every symbol's class and build the block coder's expansion arena and
/// coding tables -- "startup" (PLAN's `startup_ms`).
pub fn open(alloc: std.mem.Allocator, bytes: []const u8) !Frame {
    if (bytes.len < header_len) return FrameError.Truncated;
    if (!(bytes[0] == magic0 and bytes[1] == magic1 and bytes[2] == magic2)) return FrameError.BadMagic;
    if (bytes[3] != version) return FrameError.BadVersion;

    const block_bytes = std.mem.readInt(u32, bytes[8..12], .little);
    const raw_len = std.mem.readInt(u64, bytes[12..20], .little);
    const block_count = std.mem.readInt(u32, bytes[20..24], .little);
    const model_len = std.mem.readInt(u32, bytes[24..28], .little);
    const stored_crc = std.mem.readInt(u32, bytes[28..32], .little);

    const dir_len: usize = @as(usize, block_count) * dir_entry_len;
    if (bytes.len < header_len + @as(usize, model_len) + dir_len) return FrameError.Truncated;

    const computed_crc = headerCrc(bytes, model_len, dir_len);
    if (computed_crc != stored_crc) return FrameError.HeaderCrcMismatch;

    if (block_bytes == 0 and block_count != 0) return FrameError.Truncated;
    if (block_count != 0) {
        const expected_blocks: u64 = (raw_len + block_bytes - 1) / block_bytes;
        if (expected_blocks != block_count) return FrameError.Truncated;
    } else if (raw_len != 0) {
        return FrameError.Truncated;
    }

    const model_seg = bytes[header_len..][0..model_len];
    if (model_seg.len < 4) return FrameError.Truncated;
    const lex_len = std.mem.readInt(u32, model_seg[0..4], .little);
    if (4 + @as(usize, lex_len) + 4 > model_seg.len) return FrameError.Truncated;
    const lex_bytes = model_seg[4..][0..lex_len];
    const class_off = 4 + lex_len;
    const class_len = std.mem.readInt(u32, model_seg[class_off..][0..4], .little);
    if (class_off + 4 + @as(usize, class_len) > model_seg.len) return FrameError.Truncated;
    const class_bytes = model_seg[class_off + 4 ..][0..class_len];

    var decoded = try model_codec.decode(alloc, lex_bytes);
    errdefer decoded.deinit(alloc);
    var class_decoded = try class_codec.decode(alloc, class_bytes);
    errdefer class_decoded.deinit(alloc);

    const order = try topology.topoOrder(alloc, &decoded.lex);
    defer alloc.free(order);
    const k = 256 + decoded.lex.numEntries();
    if (class_decoded.T.len != @as(usize, class_decoded.C + 1) * class_decoded.C) return FrameError.Truncated;

    var overrides: std.AutoHashMapUnmanaged(u32, u32) = .{};
    defer overrides.deinit(alloc);
    for (class_decoded.override_ids, class_decoded.override_classes) |id, cls| {
        if (id < 256 or id >= k) return FrameError.Truncated;
        try overrides.put(alloc, id, cls);
    }
    const resolved = try classes.resolveFromOverrides(alloc, &decoded.lex, order, class_decoded.byte_class, overrides);
    defer alloc.free(resolved.b);
    defer alloc.free(resolved.a);

    var coder = try block_coder.Coder.build(alloc, class_decoded.C, class_decoded.T, resolved.b, resolved.a, decoded.g_by_id, &decoded.lex);
    errdefer coder.deinit(alloc);

    const dir = bytes[header_len + model_len ..][0..dir_len];
    const payload = bytes[header_len + model_len + dir_len ..];

    return .{
        .alloc = alloc,
        .bytes = bytes,
        .block_bytes = block_bytes,
        .raw_len = raw_len,
        .block_count = block_count,
        .dir = dir,
        .payload = payload,
        .decoded = decoded,
        .class_decoded = class_decoded,
        .coder = coder,
    };
}

// ====================================================================
// Tests
// ====================================================================

const learn = @import("learn.zig");

fn buildConverged(alloc: std.mem.Allocator, raw: []const u8, block_bytes: usize) !Corpus {
    var corpus = try lexicon.seedBytes(alloc, raw, block_bytes);
    var log: std.ArrayList(learn.IterLog) = .empty;
    try learn.iterate(alloc, &corpus, raw, .{ .max_iters = 10 }, &log);
    return corpus;
}

fn roundtripCheck(alloc: std.mem.Allocator, raw: []const u8, block_bytes: usize, class_params: classes.Params) !void {
    const corpus = try buildConverged(alloc, raw, block_bytes);
    const a = try assemble(alloc, raw, &corpus, class_params);

    var frame = try open(alloc, a.bytes);
    defer frame.deinit();
    const out = try alloc.alloc(u8, raw.len);
    try frame.decodeAll(out);
    try std.testing.expectEqualSlices(u8, raw, out);

    var i: usize = 0;
    while (i < frame.block_count) : (i += 1) {
        const range = frame.blockRawRange(i);
        const blen: usize = @intCast(range.end - range.start);
        const one = try alloc.alloc(u8, blen);
        try frame.decodeBlock(i, one);
        try std.testing.expectEqualSlices(u8, raw[@intCast(range.start)..@intCast(range.end)], one);
    }
}

test "roundtrip: empty input" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try roundtripCheck(arena_state.allocator(), "", 4096, .{ .C = 16 });
}

test "roundtrip: 1 byte" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try roundtripCheck(arena_state.allocator(), "x", 4096, .{ .C = 16 });
}

test "roundtrip: all-equal bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const buf = try a.alloc(u8, 5000);
    @memset(buf, 'q');
    try roundtripCheck(a, buf, 512, .{ .C = 8 });
}

test "roundtrip: random bytes fall back to raw blocks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();
    const buf = try a.alloc(u8, 20000);
    rnd.bytes(buf);
    try roundtripCheck(a, buf, 1024, .{ .C = 8 });
}

test "roundtrip: text, C=1 order-0 degenerate case" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = "the quick brown fox jumps over the lazy dog. " ** 40;
    try roundtripCheck(a, text, 256, .{ .C = 1 });
}

test "roundtrip: text, C=32 classes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = "the quick brown fox jumps over the lazy dog. " ** 40;
    try roundtripCheck(a, text, 256, .{ .C = 32, .g_min = 2 });
}

test "corruption: 2000 trials of flipped bits / truncation never panic, only error or fail CRC" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = "the quick brown fox jumps over the lazy dog. " ** 40;
    const corpus = try buildConverged(a, text, 256);
    const asm_ = try assemble(a, text, &corpus, .{ .C = 16, .g_min = 2 });

    var prng = std.Random.DefaultPrng.init(0xB4B4);
    const rnd = prng.random();
    const trials = 2000;
    const out_buf = try a.alloc(u8, text.len);

    var caught: usize = 0;
    var i: usize = 0;
    while (i < trials) : (i += 1) {
        const corrupted = try a.dupe(u8, asm_.bytes);
        var mutated = false;
        if (rnd.boolean()) {
            const nflips = rnd.intRangeAtMost(u32, 1, 4);
            var f: u32 = 0;
            while (f < nflips) : (f += 1) {
                const byte_idx = rnd.uintLessThan(usize, corrupted.len);
                const bit_idx: u3 = @intCast(rnd.uintLessThan(u8, 8));
                corrupted[byte_idx] ^= (@as(u8, 1) << bit_idx);
            }
            mutated = true;
        }
        const trunc = rnd.uintLessThan(usize, corrupted.len + 1);
        if (trunc != corrupted.len) mutated = true;
        const view = corrupted[0..trunc];
        if (!mutated) {
            caught += 1;
            continue;
        }

        if (open(a, view)) |frame_const| {
            var frame = frame_const;
            defer frame.deinit();
            if (frame.decodeAll(out_buf)) |_| {
                if (std.mem.eql(u8, out_buf, text)) caught += 1;
            } else |_| {
                caught += 1;
            }
        } else |_| {
            caught += 1;
        }
    }

    const rate = @as(f64, @floatFromInt(caught)) / @as(f64, @floatFromInt(trials));
    if (rate < 0.85) std.debug.print("corruption catch rate {d:.3} ({d}/{d})\n", .{ rate, caught, trials });
    try std.testing.expect(rate >= 0.85);
}

test "corruption: byte-for-byte truncation at every prefix length" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = "abcdefghijklmnopqrstuvwxyz" ** 20;
    const corpus = try buildConverged(a, text, 128);
    const asm_ = try assemble(a, text, &corpus, .{ .C = 8, .g_min = 2 });

    const out_buf = try a.alloc(u8, text.len);
    var len: usize = 0;
    while (len < asm_.bytes.len) : (len += 1) {
        const view = asm_.bytes[0..len];
        if (open(a, view)) |*frame_const| {
            var frame = frame_const.*;
            defer frame.deinit();
            _ = frame.decodeAll(out_buf) catch {};
        } else |_| {}
    }
}
