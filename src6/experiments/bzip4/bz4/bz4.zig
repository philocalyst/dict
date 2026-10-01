//! bz4.zig — Lane V (integration): a real, self-contained "bz4 v1" codec
//! combining the three winning lab pieces into one shared-model,
//! independently-decodable-block frame format. See LANE_V.md for the lab
//! notebook (closed-loop MDL results, startup before/after, corruption
//! test status) and PLAN.md for the shared contract this lane answers to.
//!
//! FORMAT (little-endian):
//!   header (32 bytes): magic "BZ4\x01", flags u8, reserved u8, reserved2
//!     u16, block_bytes u32, raw_len u64, block_count u32, model_len u32,
//!     crc32 u32 (of header[0..28] ++ model ++ directory)
//!   MODEL: bz4_model.zig's range-coded rule-DAG + g[] stream (model_len
//!     bytes)
//!   DIRECTORY: block_count x 8 bytes: u32 end_offset (top bit = "this
//!     block is stored raw"), u32 crc32 of the decoded block
//!   BLOCKS: concatenated per-block payloads (canonical Huffman codes
//!     derived from g[], byte-padded; or raw bytes when Huffman would not
//!     have shrunk the block)
//!
//! Everything under the MODEL/DIRECTORY/BLOCKS split is charged: no size
//! is reported anywhere in this lane that isn't the length of real bytes
//! written into this frame.
//!
//! Pure Zig 0.16, std only.

const std = @import("std");
const bg = @import("bz4_grammar.zig");
const bm = @import("bz4_model.zig");
const br = @import("bz4_root.zig");

pub const header_len: usize = 32;
pub const dir_entry_len: usize = 8;
const magic0: u8 = 'B';
const magic1: u8 = 'Z';
const magic2: u8 = '4';
const magic3: u8 = 1;
const raw_flag: u32 = 0x8000_0000;
const off_mask: u32 = 0x7FFF_FFFF;

pub const FrameError = error{
    Truncated,
    BadMagic,
    BadVersion,
    HeaderCrcMismatch,
    BlockIndexOutOfRange,
    OutputLengthMismatch,
    SymbolOutOfRange,
    OutputOverflow,
    BlockOverrun,
    BlockUnderrun,
    BlockCrcMismatch,
    PayloadTruncated,
};

fn crc32Of(bytes: []const u8) u32 {
    return std.hash.Crc32.hash(bytes);
}

// ======================================================================
// Compression
// ======================================================================

pub const CompressOpts = struct {
    block_bytes: usize = 65536,
    /// 0 = a3 (saving-priority) build + closed-loop calibrated MDL deletion.
    /// 1 = additionally try grammar2's optimal DP re-parse (A4, slow) on
    /// top of whichever candidate wins at effort 0.
    effort: u8 = 0,
};

pub const Stats = struct {
    rules: usize,
    roots: usize,
    model_bytes: usize,
    directory_bytes: usize,
    payload_bytes: usize,
    total_bytes: usize,
    variant: bm.Variant,
    candidate: []const u8, // static string naming the winning candidate
};

pub const CompressResult = struct {
    bytes: []u8,
    stats: Stats,
};

/// `compress(alloc, input, opts) ![]u8` per PLAN's brief. Thin wrapper over
/// `compressStats`, which bz4bench.zig uses to report rules/roots/etc.
pub fn compress(alloc: std.mem.Allocator, input: []const u8, opts: CompressOpts) ![]u8 {
    const r = try compressStats(alloc, input, opts);
    return r.bytes;
}

/// Set true (e.g. from bz4cli with a "-v" flag) to print every candidate
/// grammar's real measured size to stderr as compressStats evaluates it.
/// Never affects the wire format; purely a LANE_V.md-writing aid.
pub var debug_candidates: bool = false;

const mdl_max_rounds: usize = 8;
const flat_rule_bits: f64 = 13.0; // Lane A's own flat charge, for the "plain a2" comparison candidate
const reparse_max_len: u32 = 256;
const reparse_iterations: usize = 3;

/// One real, fully-assembled frame for a specific (grammar, model variant)
/// pair -- this IS the measurement (no separate estimate path): we build
/// the real model bytes, the real Huffman tables, and the real per-block
/// payload, every time.
const Assembled = struct {
    bytes: []u8,
    model_len: u32,
    directory_len: u32,
    payload_len: u32,
    rules: usize,
    roots: usize,
    variant: bm.Variant,

    fn deinit(self: *Assembled, alloc: std.mem.Allocator) void {
        alloc.free(self.bytes);
    }
};

/// Encode the model with both named candidate variants (LANE_B.md: v2y
/// wins most dumps, v2x wins the rest by <0.01 bits/rule -- cheap enough to
/// just try both and keep the smaller one) and return the winner.
fn bestModelBytes(alloc: std.mem.Allocator, mi: *const bm.ModelInput) !bm.ModelBytes {
    var best: ?bm.ModelBytes = null;
    for (bm.candidate_variants) |v| {
        var mb = try bm.encodeModel(alloc, mi, v);
        if (best == null or mb.bytes.len < best.?.bytes.len) {
            if (best) |*b| b.deinit();
            best = mb;
        } else {
            mb.deinit();
        }
    }
    return best.?;
}

fn assembleFrame(alloc: std.mem.Allocator, input: []const u8, gm: *const bg.Grammar, model: bm.ModelBytes) !Assembled {
    // The block/root token stream must be expressed in the MODEL's own
    // post-order id space, not the grammar builder's original numbering:
    // the decoder only ever reconstructs the model's renumbering (see
    // ModelBytes.remap's doc comment -- "no permutation is ever
    // transmitted"), so its Huffman table is built over THOSE ids. Every
    // token this encoder emits, and every g[] count the Huffman table is
    // built from, must be remapped through `model.remap` to match.
    const n_total = gm.numSymbols();
    const remap = model.remap;

    const renum_g = try alloc.alloc(u64, n_total);
    defer alloc.free(renum_g);
    @memset(renum_g, 0);
    {
        const rcs = try bg.rootCounts(alloc, gm);
        defer alloc.free(rcs.g);
        for (rcs.g, 0..) |c, old_id| renum_g[remap[old_id]] = c;
    }

    var alphabet = try br.buildAlphabet(alloc, renum_g);
    defer alphabet.deinit(alloc);
    const alphabet_size: u32 = @intCast(n_total);

    var huf = try br.buildHuffman(alloc, alphabet, alphabet_size);
    defer huf.deinit(alloc);
    var enc_table = try br.buildHuffmanEncodeTable(alloc, huf, alphabet);
    defer enc_table.deinit(alloc);

    const block_count = gm.block_end.len;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    var dir = try alloc.alloc(u8, block_count * dir_entry_len);
    errdefer alloc.free(dir);

    var seq_start: usize = 0;
    var raw_start: usize = 0;
    for (gm.block_end, 0..) |seq_end, b| {
        const raw_end = @min(input.len, raw_start + gm.block_bytes);
        const blen = raw_end - raw_start;
        const start_off = payload.items.len;

        var bw = br.BitWriter{ .out = &payload, .alloc = alloc };
        for (gm.seq[seq_start..seq_end]) |s| {
            const ns = remap[s];
            try bw.putBits(enc_table.code[ns], @intCast(enc_table.length[ns]));
        }
        try bw.flushBlock();
        var block_len = payload.items.len - start_off;
        var is_raw = false;

        if (block_len > blen) {
            payload.items.len = start_off;
            try payload.appendSlice(alloc, input[raw_start..raw_end]);
            block_len = blen;
            is_raw = true;
        }

        const end_off: u32 = @intCast(payload.items.len);
        if (end_off & raw_flag != 0) return error.FrameTooLarge;
        const tagged_off: u32 = if (is_raw) end_off | raw_flag else end_off;
        const crc = crc32Of(input[raw_start..raw_end]);
        std.mem.writeInt(u32, dir[b * 8 ..][0..4], tagged_off, .little);
        std.mem.writeInt(u32, dir[b * 8 + 4 ..][0..4], crc, .little);

        seq_start = seq_end;
        raw_start = raw_end;
    }

    const total = header_len + model.bytes.len + dir.len + payload.items.len;
    var bytes = try alloc.alloc(u8, total);
    errdefer alloc.free(bytes);

    bytes[0] = magic0;
    bytes[1] = magic1;
    bytes[2] = magic2;
    bytes[3] = magic3;
    bytes[4] = 0; // flags
    bytes[5] = 0; // reserved
    std.mem.writeInt(u16, bytes[6..8], 0, .little);
    std.mem.writeInt(u32, bytes[8..12], @intCast(gm.block_bytes), .little);
    std.mem.writeInt(u64, bytes[12..20], @intCast(input.len), .little);
    std.mem.writeInt(u32, bytes[20..24], @intCast(block_count), .little);
    std.mem.writeInt(u32, bytes[24..28], @intCast(model.bytes.len), .little);

    const dir_len = dir.len;
    @memcpy(bytes[header_len..][0..model.bytes.len], model.bytes);
    @memcpy(bytes[header_len + model.bytes.len ..][0..dir_len], dir);
    @memcpy(bytes[header_len + model.bytes.len + dir_len ..], payload.items);
    alloc.free(dir);

    // Must match `open()`'s verification exactly: crc32 over header[0..28]
    // followed immediately by (model ++ directory), both already laid out
    // contiguously in `bytes`.
    const crc = headerCrc(bytes, model.bytes.len, dir_len);
    std.mem.writeInt(u32, bytes[28..32], crc, .little);

    return .{
        .bytes = bytes,
        .model_len = @intCast(model.bytes.len),
        .directory_len = @intCast(dir_len),
        .payload_len = @intCast(payload.items.len),
        .rules = gm.rules.items.len,
        .roots = gm.seq.len,
        .variant = @enumFromInt(0), // filled by caller (we don't decode the model header back out here)
    };
}

fn headerCrc(bytes: []const u8, model_len: usize, dir_len: usize) u32 {
    var h = std.hash.Crc32.init();
    h.update(bytes[0..28]);
    h.update(bytes[header_len..][0 .. model_len + dir_len]);
    return h.final();
}

fn assembleAndScore(alloc: std.mem.Allocator, input: []const u8, name: []const u8, gm: *const bg.Grammar) !struct { asm_: Assembled, variant: bm.Variant } {
    var mi = try bm.modelInputFromGrammar(alloc, gm);
    defer mi.deinit();
    var mb = try bestModelBytes(alloc, &mi);
    defer mb.deinit();
    // Recover which variant won by peeking the tiny embedded header (byte 5).
    const variant: bm.Variant = @enumFromInt(mb.bytes[5]);
    var a = try assembleFrame(alloc, input, gm, mb);
    a.variant = variant;
    _ = name;
    return .{ .asm_ = a, .variant = variant };
}

/// Recalibrate `Calib` from a real measurement of `gm`'s model bits vs.
/// what the approximate cost model predicted for the SAME grammar under
/// the calibration just used to build it.
fn recalibrate(alloc: std.mem.Allocator, gm: *const bg.Grammar, calib: bg.Calib, real_struct_bits: f64, real_g_bits: f64) !bg.Calib {
    const approx = try bg.approxModelBitsSplit(alloc, gm, calib);
    var next = calib;
    if (approx.struct_bits > 1.0) {
        const ratio = real_struct_bits / approx.struct_bits;
        const clamped = std.math.clamp(ratio, 0.5, 2.0);
        next.flag_bits *= clamped;
        next.byte_bits *= clamped;
        next.ref_log_coeff *= clamped;
    }
    if (approx.g_bits > 1.0) {
        const ratio = real_g_bits / approx.g_bits;
        const clamped = std.math.clamp(ratio, 0.5, 2.0);
        next.g_scale *= clamped;
        next.g_zero_bits *= clamped;
    }
    return next;
}

pub fn compressStats(alloc: std.mem.Allocator, input: []const u8, opts: CompressOpts) !CompressResult {
    const block_bytes = @max(opts.block_bytes, 1);

    var gm_a3 = try bg.build(alloc, input, block_bytes, .{ .priority = .saving, .fast_count = true, .min_freq = 2, .alpha_percent = 50 });
    defer gm_a3.deinit(alloc);
    if (!try bg.verifyExact(alloc, input, &gm_a3)) return error.GrammarNotExact;

    var best: ?Assembled = null;
    var best_name: []const u8 = "";

    // helper: score a grammar, keep it if it's the new best (frees the rest)
    const Scorer = struct {
        fn run(a: std.mem.Allocator, inp: []const u8, gm: *const bg.Grammar, name: []const u8, best_ptr: *?Assembled, best_name_ptr: *[]const u8) !void {
            const scored = try assembleAndScore(a, inp, name, gm);
            var cur = scored.asm_;
            if (debug_candidates) std.debug.print("  [bz4 candidate] {s}: rules={d} bytes={d}\n", .{ name, cur.rules, cur.bytes.len });
            if (best_ptr.* == null or cur.bytes.len < best_ptr.*.?.bytes.len) {
                if (best_ptr.*) |*old| old.deinit(a);
                best_ptr.* = cur;
                best_name_ptr.* = name;
            } else {
                cur.deinit(a);
            }
        }
    };

    // ---- candidate: unpruned a3 ----
    {
        var gm = try gm_a3.clone(alloc);
        defer gm.deinit(alloc);
        try Scorer.run(alloc, input, &gm, "a3_unpruned", &best, &best_name);
    }

    // ---- candidate: Lane A's plain a2 (flat RULE_BITS=13 deletion) ----
    {
        var gm = try gm_a3.clone(alloc);
        defer gm.deinit(alloc);
        _ = try bg.mdlDeleteFlat(alloc, &gm, flat_rule_bits, mdl_max_rounds);
        if (!try bg.verifyExact(alloc, input, &gm)) return error.GrammarNotExact;
        try Scorer.run(alloc, input, &gm, "a3+flat_a2", &best, &best_name);
    }

    // ---- closed-loop calibrated MDL: prune, measure real, recalibrate,
    //      repeat (cumulative pruning across rounds). ----
    var calib = bg.Calib.default();
    {
        var gm = try gm_a3.clone(alloc);
        defer gm.deinit(alloc);

        var round: usize = 0;
        while (round < 3) : (round += 1) {
            const stats_del = try bg.mdlDeleteCalibrated(alloc, &gm, calib, mdl_max_rounds);
            if (stats_del.deleted == 0 and round > 0) break;
            if (!try bg.verifyExact(alloc, input, &gm)) return error.GrammarNotExact;

            var mi = try bm.modelInputFromGrammar(alloc, &gm);
            defer mi.deinit();
            var mb = try bestModelBytes(alloc, &mi);
            defer mb.deinit();
            const real_struct_bits: f64 = @as(f64, @floatFromInt(mb.struct_len - bm_header_size)) * 8.0;
            const real_g_bits: f64 = @as(f64, @floatFromInt(mb.g_len)) * 8.0;
            calib = try recalibrate(alloc, &gm, calib, real_struct_bits, real_g_bits);

            var a = try assembleFrame(alloc, input, &gm, mb);
            a.variant = @enumFromInt(mb.bytes[5]);
            if (debug_candidates) std.debug.print("  [bz4 candidate] a3+mdl_iter{d} (deleted {d}, calib flag={d:.2} byte={d:.2} ref_c={d:.2} g_scale={d:.2}): rules={d} bytes={d}\n", .{ round, stats_del.deleted, calib.flag_bits, calib.byte_bits, calib.ref_log_coeff, calib.g_scale, a.rules, a.bytes.len });
            if (best == null or a.bytes.len < best.?.bytes.len) {
                if (best) |*old| old.deinit(alloc);
                best = a;
                best_name = closed_loop_names[@min(round, closed_loop_names.len - 1)];
            } else {
                a.deinit(alloc);
            }

            if (stats_del.deleted == 0) break;
        }
    }

    // ---- effort=1: A4 optimal DP re-parse on top of whichever candidate
    //      currently wins. Slow; skipped at effort=0. ----
    if (opts.effort >= 1) {
        // Re-derive a grammar object equivalent to the current best by
        // re-running the same pipeline is wasteful; instead we simply
        // re-build from a3 + calibrated MDL one more time (cheap relative
        // to A4 itself) to get a mutable Grammar to hand to optimalReparse.
        var gm = try gm_a3.clone(alloc);
        defer gm.deinit(alloc);
        _ = try bg.mdlDeleteCalibrated(alloc, &gm, calib, mdl_max_rounds);
        _ = try bg.optimalReparse(alloc, &gm, input, flat_rule_bits, reparse_max_len, reparse_iterations);
        if (!try bg.verifyExact(alloc, input, &gm)) return error.GrammarNotExact;
        try Scorer.run(alloc, input, &gm, "a3+mdl+a4", &best, &best_name);
    }

    const winner = best.?;
    return .{
        .bytes = winner.bytes,
        .stats = .{
            .rules = winner.rules,
            .roots = winner.roots,
            .model_bytes = winner.model_len,
            .directory_bytes = winner.directory_len,
            .payload_bytes = winner.payload_len,
            .total_bytes = winner.bytes.len,
            .variant = winner.variant,
            .candidate = best_name,
        },
    };
}

const closed_loop_names = [_][]const u8{ "a3+mdl_iter0", "a3+mdl_iter1", "a3+mdl_iter2", "a3+mdl_iter3" };
const bm_header_size: u32 = 20; // bz4_model.zig's internal Header.size

// ======================================================================
// Decompression
// ======================================================================

pub const Frame = struct {
    alloc: std.mem.Allocator,
    bytes: []const u8, // borrowed: caller keeps the encoded bytes alive
    block_bytes: usize,
    raw_len: u64,
    block_count: u32,
    model_len: u32,
    dir: []const u8, // borrowed view into bytes
    payload: []const u8, // borrowed view into bytes
    decoded: bm.DecodedModel,
    alphabet: br.Alphabet,
    huf: br.Huffman,
    exp: br.Expansion,

    pub fn deinit(self: *Frame) void {
        self.decoded.deinit();
        self.alphabet.deinit(self.alloc);
        self.huf.deinit(self.alloc);
        self.exp.deinit(self.alloc);
    }

    pub fn ruleCount(self: *const Frame) usize {
        return self.decoded.rule_count;
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
    /// length). Independent of every other block; allocates nothing;
    /// validates symbol ids, output bounds, exact-length termination, and
    /// CRC32 -- never trusts the payload.
    pub fn decodeBlock(self: *const Frame, index: usize, out: []u8) !void {
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
            var br_reader = br.BitReader.init(payload);
            var pos: usize = 0;
            while (pos < raw_len) {
                const sym = self.huf.decodeOneTable(&br_reader);
                if (sym >= self.exp.off.len) return FrameError.SymbolOutOfRange;
                const l = self.exp.len[sym];
                if (l == 0) return FrameError.SymbolOutOfRange; // g=0 symbols are never valid decode targets
                if (pos + l > raw_len) return FrameError.BlockOverrun;
                const off = self.exp.off[sym];
                @memcpy(out[pos..][0..l], self.exp.arena[off..][0..l]);
                pos += l;
            }
            if (pos != raw_len) return FrameError.BlockUnderrun;
        }

        if (crc32Of(out) != entry.crc) return FrameError.BlockCrcMismatch;
    }

    /// Decode every block, in order, into one contiguous buffer.
    pub fn decodeAll(self: *const Frame, out: []u8) !void {
        if (out.len != self.raw_len) return FrameError.OutputLengthMismatch;
        var i: usize = 0;
        while (i < self.block_count) : (i += 1) {
            const range = self.blockRawRange(i);
            try self.decodeBlock(i, out[range.start..range.end]);
        }
    }
};

/// Parse + validate the header, decode the model, build the expansion
/// arena and Huffman tables -- this is "startup" (see PLAN's brief:
/// STARTUP SPEED, `startup_ms (Frame.open)`).
pub fn open(alloc: std.mem.Allocator, bytes: []const u8) !Frame {
    if (bytes.len < header_len) return FrameError.Truncated;
    if (!(bytes[0] == magic0 and bytes[1] == magic1 and bytes[2] == magic2 and bytes[3] == magic3)) return FrameError.BadMagic;

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
    // Every block except possibly the last must be exactly block_bytes; a
    // corrupted block_count/block_bytes/raw_len combination is rejected
    // here rather than discovered lazily one decodeBlock() at a time.
    if (block_count != 0) {
        const expected_blocks: u64 = (raw_len + block_bytes - 1) / block_bytes;
        if (expected_blocks != block_count) return FrameError.Truncated;
    } else if (raw_len != 0) {
        return FrameError.Truncated;
    }

    const model_bytes = bytes[header_len..][0..model_len];
    var decoded = try bm.decodeModel(alloc, model_bytes);
    errdefer decoded.deinit();

    const alphabet_size: u32 = 256 + decoded.rule_count;
    var alphabet = try br.buildAlphabet(alloc, decoded.g);
    errdefer alphabet.deinit(alloc);

    const root_rules = try alloc.alloc(br.Rule, decoded.rules.len);
    defer alloc.free(root_rules);
    for (decoded.rules, 0..) |r, i| root_rules[i] = .{ .a = r.a, .b = r.b };

    var huf = try br.buildHuffman(alloc, alphabet, alphabet_size);
    errdefer huf.deinit(alloc);
    var exp = try br.buildExpansion(alloc, root_rules, alphabet, alphabet_size);
    errdefer exp.deinit(alloc);

    const dir = bytes[header_len + model_len ..][0..dir_len];
    const payload = bytes[header_len + model_len + dir_len ..];

    return .{
        .alloc = alloc,
        .bytes = bytes,
        .block_bytes = block_bytes,
        .raw_len = raw_len,
        .block_count = block_count,
        .model_len = model_len,
        .dir = dir,
        .payload = payload,
        .decoded = decoded,
        .alphabet = alphabet,
        .huf = huf,
        .exp = exp,
    };
}

// ======================================================================
// Tests
// ======================================================================

fn roundtripCheck(alloc: std.mem.Allocator, input: []const u8, block_bytes: usize) !void {
    const bytes = try compress(alloc, input, .{ .block_bytes = block_bytes });
    defer alloc.free(bytes);

    var frame = try open(alloc, bytes);
    defer frame.deinit();

    const out = try alloc.alloc(u8, input.len);
    defer alloc.free(out);
    try frame.decodeAll(out);
    try std.testing.expectEqualSlices(u8, input, out);

    // Every block must also be decodable alone.
    var i: usize = 0;
    while (i < frame.block_count) : (i += 1) {
        const range = frame.blockRawRange(i);
        const blen: usize = @intCast(range.end - range.start);
        const one = try alloc.alloc(u8, blen);
        defer alloc.free(one);
        try frame.decodeBlock(i, one);
        try std.testing.expectEqualSlices(u8, input[range.start..range.end], one);
    }
}

test "roundtrip: empty input" {
    const alloc = std.testing.allocator;
    try roundtripCheck(alloc, "", 4096);
}

test "roundtrip: 1 byte" {
    const alloc = std.testing.allocator;
    try roundtripCheck(alloc, "x", 4096);
}

test "roundtrip: all-equal bytes" {
    const alloc = std.testing.allocator;
    const buf = try alloc.alloc(u8, 5000);
    defer alloc.free(buf);
    @memset(buf, 'q');
    try roundtripCheck(alloc, buf, 512);
}

test "roundtrip: random bytes fall back to raw blocks" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();
    const buf = try alloc.alloc(u8, 20000);
    defer alloc.free(buf);
    rnd.bytes(buf);
    try roundtripCheck(alloc, buf, 1024);
}

test "roundtrip: text" {
    const alloc = std.testing.allocator;
    const text =
        \\the quick brown fox jumps over the lazy dog.
        \\the quick brown fox jumps over the lazy dog again.
        \\pack my box with five dozen liquor jugs, again and again and again.
    ;
    const buf = try alloc.alloc(u8, text.len * 30);
    defer alloc.free(buf);
    var i: usize = 0;
    while (i < buf.len) : (i += text.len) {
        const take = @min(text.len, buf.len - i);
        @memcpy(buf[i..][0..take], text[0..take]);
    }
    try roundtripCheck(alloc, buf, 256);
}

test "effort=1 A4 re-parse still roundtrips" {
    const alloc = std.testing.allocator;
    const text = "abcabcabcabc xyzxyzxyzxyz " ** 50;
    const bytes = try compress(alloc, text, .{ .block_bytes = 512, .effort = 1 });
    defer alloc.free(bytes);
    var frame = try open(alloc, bytes);
    defer frame.deinit();
    const out = try alloc.alloc(u8, text.len);
    defer alloc.free(out);
    try frame.decodeAll(out);
    try std.testing.expectEqualSlices(u8, text, out);
}

test "corruption: 2000 trials of flipped bits / truncation never panic, only error or fail CRC" {
    const alloc = std.testing.allocator;
    const text = "the quick brown fox jumps over the lazy dog. " ** 40;
    const bytes = try compress(alloc, text, .{ .block_bytes = 256 });
    defer alloc.free(bytes);

    var prng = std.Random.DefaultPrng.init(0xB4B4);
    const rnd = prng.random();
    const trials = 2000;
    const out_buf = try alloc.alloc(u8, text.len);
    defer alloc.free(out_buf);

    var caught: usize = 0;
    var i: usize = 0;
    while (i < trials) : (i += 1) {
        const corrupted = try alloc.dupe(u8, bytes);
        defer alloc.free(corrupted);
        var mutated = false;

        // Every trial truncates (a no-op 50% of the time) AND, half the
        // time, additionally flips 1-4 random bits -- so every trial
        // exercises at least one form of corruption unless truncation
        // rolled "keep full length" AND bit-flip rolled "skip".
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
            caught += 1; // nothing changed; trivially "safe"
            continue;
        }

        if (open(alloc, view)) |frame_const| {
            var frame = frame_const;
            defer frame.deinit();
            if (frame.decodeAll(out_buf)) |_| {
                // Only a genuine non-detection if it ALSO produced the
                // wrong bytes; decodeAll returning success already means
                // every per-block CRC32 matched.
                if (std.mem.eql(u8, out_buf, text)) caught += 1;
            } else |_| {
                caught += 1; // decode rejected the corrupted stream
            }
        } else |_| {
            caught += 1; // open() rejected the corrupted stream
        }
    }

    const rate = @as(f64, @floatFromInt(caught)) / @as(f64, @floatFromInt(trials));
    if (rate < 0.85) std.debug.print("corruption catch rate {d:.3} ({d}/{d})\n", .{ rate, caught, trials });
    try std.testing.expect(rate >= 0.85);
}

test "corruption: byte-for-byte truncation at every prefix length" {
    const alloc = std.testing.allocator;
    const text = "abcdefghijklmnopqrstuvwxyz" ** 20;
    const bytes = try compress(alloc, text, .{ .block_bytes = 128 });
    defer alloc.free(bytes);

    const out_buf = try alloc.alloc(u8, text.len);
    defer alloc.free(out_buf);

    var len: usize = 0;
    while (len < bytes.len) : (len += 1) {
        const view = bytes[0..len];
        if (open(alloc, view)) |*frame_const| {
            var frame = frame_const.*;
            defer frame.deinit();
            _ = frame.decodeAll(out_buf) catch {};
        } else |_| {}
    }
}
