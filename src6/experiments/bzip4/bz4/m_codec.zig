//! Lane M real codec: MODEL (entry count, counts n(t), arities, spellings)
//! + BLOCKS (independently decodable token streams), all range-coded with
//! rc.zig. See PLAN.md's Lane M brief ("REAL CODEC") for the exact scheme
//! this implements:
//!
//!   - entries are numbered by DESCENDING count so the count array is
//!     non-increasing and codes as cheap adaptive deltas;
//!   - every spelling component AND every corpus token is coded with the
//!     SAME static code, built from n(t) (which already includes both
//!     corpus and lexicon uses -- "the lexicon is just more text");
//!   - arity is a small adaptive code;
//!   - forward references inside spellings are allowed (a component may
//!     name a higher-numbered entry); the decoder reads the whole model,
//!     then expands every entry by memoised DFS, rejecting cycles and
//!     oversize expansions.
//!
//! Bytes keep their natural id (0..255, decoder treats id<256 as a literal
//! byte value); only entries (256..256+entry_count-1) are reordered by
//! count, and that reordering *is* the transmission order -- no id
//! permutation is separately encoded, matching Lane B's DEF-tree philosophy
//! but simpler here since every entry is unconditionally emitted once, in
//! order (no DEF/REF flags needed).
//!
//! Wire layout (all sizes real, charged in `Encoded.total()`):
//!   [24B header: magic,version,entry_count,block_count,block_bytes,raw_len]
//!   [4B model_len][model_len bytes: one rc stream: byte counts, entry
//!     count+deltas, arities, then every spelling component's id]
//!   for each block: [4B token_count][4B payload_len][payload_len bytes:
//!     one independent rc stream, that many token ids]
//!
//! Pure Zig 0.16, std only.

const std = @import("std");
const rc = @import("rc.zig");
const mlex = @import("m_lexicon.zig");

const MAGIC: u32 = 0x314D3442; // "B4M1" little-endian

// ------------------------------------------------------------- adaptive var

/// Adaptive "unary length prefix + raw mantissa" code for a non-negative
/// integer, with a dedicated zero flag (most counts/deltas/arities are 0).
/// Same spirit as Lane B's GammaCtx (LANE_B.md) but a fresh, independent
/// implementation (Lane B's file is not shared/read-only for this lane).
const VarCtx = struct {
    zero: rc.Bit = .{},
    len_bits: [33]rc.Bit = [_]rc.Bit{.{}} ** 33,
};

fn encodeVar(enc: *rc.Encoder, ctx: *VarCtx, value: u64) !void {
    if (value == 0) {
        try enc.encodeBit(&ctx.zero, 1, 5);
        return;
    }
    try enc.encodeBit(&ctx.zero, 0, 5);
    std.debug.assert(value < (1 << 32));
    const nb: u6 = @intCast(64 - @clz(value));
    var i: u6 = 1;
    while (i < nb) : (i += 1) try enc.encodeBit(&ctx.len_bits[i], 0, 5);
    try enc.encodeBit(&ctx.len_bits[nb], 1, 5);
    if (nb > 1) {
        const mantissa: u32 = @intCast(value - (@as(u64, 1) << (nb - 1)));
        try enc.encodeDirect(mantissa, nb - 1);
    }
}

fn decodeVar(dec: *rc.Decoder, ctx: *VarCtx) u64 {
    if (dec.decodeBit(&ctx.zero, 5) == 1) return 0;
    var nb: u6 = 1;
    while (dec.decodeBit(&ctx.len_bits[nb], 5) == 0) nb += 1;
    const mantissa: u64 = if (nb > 1) dec.decodeDirect(nb - 1) else 0;
    return (@as(u64, 1) << (nb - 1)) | mantissa;
}

fn appendU32(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try list.appendSlice(alloc, &buf);
}
fn readU32(bytes: []const u8, off: *usize) u32 {
    const v = std.mem.readInt(u32, bytes[off.*..][0..4], .little);
    off.* += 4;
    return v;
}

// ---------------------------------------------------------------- encode

pub const EncodeStats = struct {
    header_bytes: usize,
    model_bytes: usize,
    payload_bytes: usize,
    total_bytes: usize,
};

/// Encode `state` (the converged Lane M lexicon+parse) into the real byte
/// stream described above. Returns the owned bytes; `stats` (if non-null)
/// gets a size breakdown.
pub fn encode(alloc: std.mem.Allocator, state: *const mlex.State, stats: ?*EncodeStats) ![]u8 {
    const counts = try mlex.recount(alloc, state);
    const num_entries = state.lex.numEntries();
    const k = 256 + num_entries;

    // Rank entries by descending count (stable tie-break by original id).
    const order = try alloc.alloc(u32, num_entries); // order[r] = original entry index at rank r
    for (0..num_entries) |i| order[i] = @intCast(i);
    const RankCtx = struct {
        n: []const u64,
        fn lt(self: @This(), a: u32, b: u32) bool {
            const ca = self.n[256 + a];
            const cb = self.n[256 + b];
            if (ca != cb) return ca > cb;
            return a < b;
        }
    };
    std.mem.sort(u32, order, RankCtx{ .n = counts.n }, RankCtx.lt);
    const orig_to_rank = try alloc.alloc(u32, num_entries);
    for (order, 0..) |orig, r| orig_to_rank[orig] = @intCast(r);

    const n_by_id = try alloc.alloc(u64, k);
    for (0..256) |s| n_by_id[s] = counts.n[s];
    for (order, 0..) |orig, r| n_by_id[256 + r] = counts.n[256 + orig];

    const cumfreq = try alloc.alloc(u64, k + 1);
    cumfreq[0] = 0;
    for (0..k) |s| cumfreq[s + 1] = cumfreq[s] + n_by_id[s];
    const total = cumfreq[k];
    std.debug.assert(total < (1 << 32));

    const finalId = struct {
        o2r: []const u32,
        fn f(self: @This(), s: u32) u32 {
            return if (s < 256) s else 256 + self.o2r[s - 256];
        }
    }{ .o2r = orig_to_rank };

    var enc = rc.Encoder.init(alloc);
    var ctx_bytecount: VarCtx = .{};
    var ctx_count0: VarCtx = .{};
    var ctx_delta: VarCtx = .{};
    var ctx_arity: VarCtx = .{};

    for (0..256) |s| try encodeVar(&enc, &ctx_bytecount, n_by_id[s]);
    if (num_entries > 0) {
        try encodeVar(&enc, &ctx_count0, n_by_id[256]);
        for (1..num_entries) |r| {
            const delta = n_by_id[256 + r - 1] - n_by_id[256 + r];
            try encodeVar(&enc, &ctx_delta, delta);
        }
    }
    for (order) |orig| {
        const ar = state.lex.arity(orig);
        try encodeVar(&enc, &ctx_arity, @as(u64, ar) - 2);
    }
    for (order) |orig| {
        for (state.lex.comps(orig)) |c| {
            const id = finalId.f(c);
            try enc.encodeFreq(@intCast(cumfreq[id]), @intCast(n_by_id[id]), @intCast(total));
        }
    }
    const model_bytes = try enc.finish();

    var out: std.ArrayList(u8) = .empty;
    try appendU32(&out, alloc, MAGIC);
    try appendU32(&out, alloc, 1); // version
    try appendU32(&out, alloc, @intCast(num_entries));
    try appendU32(&out, alloc, @intCast(state.block_end.len));
    try appendU32(&out, alloc, @intCast(state.block_bytes));
    try appendU32(&out, alloc, @intCast(state.seq.len)); // placeholder; overwritten below with raw_len
    // raw_len is the caller's actual raw byte length, not seq.len; fix up:
    const header_bytes = out.items.len + 4; // + model_len field
    var payload_total: usize = 0;

    try appendU32(&out, alloc, @intCast(model_bytes.len));
    try out.appendSlice(alloc, model_bytes);

    var start: usize = 0;
    for (state.block_end) |end| {
        var benc = rc.Encoder.init(alloc);
        for (state.seq[start..end]) |t| {
            const id = finalId.f(t);
            try benc.encodeFreq(@intCast(cumfreq[id]), @intCast(n_by_id[id]), @intCast(total));
        }
        const bbytes = try benc.finish();
        try appendU32(&out, alloc, @intCast(end - start));
        try appendU32(&out, alloc, @intCast(bbytes.len));
        try out.appendSlice(alloc, bbytes);
        payload_total += 8 + bbytes.len;
        start = end;
    }

    if (stats) |st| {
        st.* = .{
            .header_bytes = header_bytes,
            .model_bytes = model_bytes.len,
            .payload_bytes = payload_total,
            .total_bytes = out.items.len,
        };
    }
    return out.toOwnedSlice(alloc);
}

/// `encode` above writes `seq.len` into the raw_len header slot as a
/// placeholder (it doesn't know the true raw byte length, only the token
/// count); real callers must pass raw_len explicitly, so we expose a
/// second entry point that patches it in-place. Kept separate so `encode`
/// itself never needs the raw file, only `state`.
pub fn encodeWithRawLen(alloc: std.mem.Allocator, state: *const mlex.State, raw_len: usize, stats: ?*EncodeStats) ![]u8 {
    const bytes = try encode(alloc, state, stats);
    std.mem.writeInt(u32, bytes[20..24], @intCast(raw_len), .little);
    return bytes;
}

// ---------------------------------------------------------------- decode

pub const Decoded = struct {
    blocks: [][]const u8, // one slice per block, owned (concatenated allocation per block)
    raw_len: usize,
};

fn findSym(cumfreq: []const u64, v: u64) u32 {
    var lo: usize = 0;
    var hi: usize = cumfreq.len - 1;
    while (lo + 1 < hi) {
        const mid = (lo + hi) / 2;
        if (cumfreq[mid] <= v) lo = mid else hi = mid;
    }
    return @intCast(lo);
}

const MAX_EXPANSION: usize = 1 << 30;
const MAX_DEPTH: usize = 100_000;

const Expander = struct {
    comp_off: []const u32,
    comp_data: []const u32,
    cache: []?[]u8,
    color: []u8, // 0=white,1=gray,2=black
    alloc: std.mem.Allocator,

    fn expand(self: *Expander, rank: usize, depth: usize) ![]u8 {
        if (self.cache[rank]) |c| return c;
        if (depth > MAX_DEPTH) return error.TooDeep;
        if (self.color[rank] == 1) return error.Cycle;
        self.color[rank] = 1;
        var buf: std.ArrayList(u8) = .empty;
        for (self.comp_data[self.comp_off[rank]..self.comp_off[rank + 1]]) |c| {
            if (c < 256) {
                try buf.append(self.alloc, @intCast(c));
            } else {
                const cr = c - 256;
                if (cr >= self.cache.len) return error.BadRef;
                const sub = try self.expand(cr, depth + 1);
                try buf.appendSlice(self.alloc, sub);
            }
            if (buf.items.len > MAX_EXPANSION) return error.Oversize;
        }
        self.color[rank] = 2;
        const result = try buf.toOwnedSlice(self.alloc);
        self.cache[rank] = result;
        return result;
    }
};

/// Decode the whole stream. Never touches encoder internals: reads only
/// the byte slice, per PLAN's rules of evidence.
pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) !Decoded {
    var off: usize = 0;
    const magic = readU32(bytes, &off);
    if (magic != MAGIC) return error.BadMagic;
    const version = readU32(bytes, &off);
    if (version != 1) return error.BadVersion;
    const entry_count = readU32(bytes, &off);
    const block_count = readU32(bytes, &off);
    const block_bytes = readU32(bytes, &off);
    _ = block_bytes;
    const raw_len = readU32(bytes, &off);
    const model_len = readU32(bytes, &off);
    if (off + model_len > bytes.len) return error.Truncated;
    const model_bytes = bytes[off .. off + model_len];
    off += model_len;

    var dec = rc.Decoder.init(model_bytes);
    const k = 256 + @as(usize, entry_count);
    const n_by_id = try alloc.alloc(u64, k);
    var ctx_bytecount: VarCtx = .{};
    var ctx_count0: VarCtx = .{};
    var ctx_delta: VarCtx = .{};
    var ctx_arity: VarCtx = .{};
    for (0..256) |s| n_by_id[s] = decodeVar(&dec, &ctx_bytecount);
    if (entry_count > 0) {
        n_by_id[256] = decodeVar(&dec, &ctx_count0);
        for (1..entry_count) |r| {
            const delta = decodeVar(&dec, &ctx_delta);
            if (delta > n_by_id[256 + r - 1]) return error.BadDelta;
            n_by_id[256 + r] = n_by_id[256 + r - 1] - delta;
        }
    }
    const arity = try alloc.alloc(u32, entry_count);
    for (0..entry_count) |r| arity[r] = @intCast(decodeVar(&dec, &ctx_arity) + 2);

    const cumfreq = try alloc.alloc(u64, k + 1);
    cumfreq[0] = 0;
    for (0..k) |s| cumfreq[s + 1] = cumfreq[s] + n_by_id[s];
    const total = cumfreq[k];
    if (total == 0 or total >= (1 << 32)) return error.BadTotal;

    const comp_off = try alloc.alloc(u32, entry_count + 1);
    comp_off[0] = 0;
    var comp_data: std.ArrayList(u32) = .empty;
    for (0..entry_count) |r| {
        for (0..arity[r]) |_| {
            const v = dec.decodeFreq(@intCast(total));
            const id = findSym(cumfreq, v);
            if (id >= k) return error.BadSymbol;
            dec.consume(@intCast(cumfreq[id]), @intCast(n_by_id[id]));
            try comp_data.append(alloc, id);
        }
        comp_off[r + 1] = @intCast(comp_data.items.len);
    }

    var expander = Expander{
        .comp_off = comp_off,
        .comp_data = comp_data.items,
        .cache = try alloc.alloc(?[]u8, entry_count),
        .color = try alloc.alloc(u8, entry_count),
        .alloc = alloc,
    };
    @memset(expander.cache, null);
    @memset(expander.color, 0);

    var blocks = try alloc.alloc([]const u8, block_count);
    for (0..block_count) |bi| {
        const token_count = readU32(bytes, &off);
        const payload_len = readU32(bytes, &off);
        if (off + payload_len > bytes.len) return error.Truncated;
        const payload = bytes[off .. off + payload_len];
        off += payload_len;
        var bdec = rc.Decoder.init(payload);
        var outb: std.ArrayList(u8) = .empty;
        for (0..token_count) |_| {
            const v = bdec.decodeFreq(@intCast(total));
            const id = findSym(cumfreq, v);
            if (id >= k) return error.BadSymbol;
            bdec.consume(@intCast(cumfreq[id]), @intCast(n_by_id[id]));
            if (id < 256) {
                try outb.append(alloc, @intCast(id));
            } else {
                const sub = try expander.expand(id - 256, 0);
                try outb.appendSlice(alloc, sub);
            }
        }
        blocks[bi] = try outb.toOwnedSlice(alloc);
    }

    return .{ .blocks = blocks, .raw_len = raw_len };
}

/// Compare decoded blocks against the raw file, byte for byte, per block.
pub fn verifyDecode(raw: []const u8, block_bytes: usize, decoded: *const Decoded) bool {
    var raw_start: usize = 0;
    for (decoded.blocks) |blk| {
        const raw_end = @min(raw.len, raw_start + block_bytes);
        if (!std.mem.eql(u8, blk, raw[raw_start..raw_end])) return false;
        raw_start = raw_end;
    }
    return raw_start == raw.len and decoded.raw_len == raw.len;
}

// ------------------------------------------------------------------- test

test "encode/decode round-trip on a tiny lexicon" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const A = arena_state.allocator();
    const raw = "the cat sat on the mat the cat ran";
    var state = try mlex.seedBytes(A, raw, 4096);
    const opts = mlex.Opts{};
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        _ = try mlex.proposePairs(A, &state, opts);
        _ = try mlex.reparseRound(A, &state, raw, opts);
        _ = try mlex.deletePass(A, &state, opts);
    }
    try std.testing.expect(try mlex.verifyExact(A, raw, &state));

    var stats: EncodeStats = undefined;
    const bytes = try encodeWithRawLen(A, &state, raw.len, &stats);
    var decoded = try decode(A, bytes);
    try std.testing.expect(verifyDecode(raw, state.block_bytes, &decoded));
    try std.testing.expect(stats.total_bytes == bytes.len);
}

test "decode rejects a cyclic spelling" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const A = arena_state.allocator();
    // Hand-build a 1-entry model whose only component is itself (256->256).
    var enc = rc.Encoder.init(A);
    var ctx: VarCtx = .{};
    // 256 byte counts, all zero except we need total>0 from the entry itself.
    for (0..256) |_| try encodeVar(&enc, &ctx, 0);
    var ctx0: VarCtx = .{};
    try encodeVar(&enc, &ctx0, 5); // entry 0's count = 5 (only entries[0])
    var ctxa: VarCtx = .{};
    try encodeVar(&enc, &ctxa, 0); // arity-2 = 0 => arity=2
    // spelling: two components, both referencing entry 0 itself (id 256).
    // total population = n_by_id[256] = 5 (all self-refs from the corpus,
    // which we won't actually provide -- decode should fail at expansion
    // time regardless of how we got here).
    try enc.encodeFreq(0, 5, 5);
    try enc.encodeFreq(0, 5, 5);
    const model_bytes = try enc.finish();

    var out: std.ArrayList(u8) = .empty;
    try appendU32(&out, A, MAGIC);
    try appendU32(&out, A, 1);
    try appendU32(&out, A, 1); // entry_count
    try appendU32(&out, A, 1); // block_count
    try appendU32(&out, A, 4096);
    try appendU32(&out, A, 0); // raw_len
    try appendU32(&out, A, @intCast(model_bytes.len));
    try out.appendSlice(A, model_bytes);
    // one block referencing the cyclic entry once.
    var benc = rc.Encoder.init(A);
    try benc.encodeFreq(0, 5, 5);
    const bbytes = try benc.finish();
    try appendU32(&out, A, 1);
    try appendU32(&out, A, @intCast(bbytes.len));
    try out.appendSlice(A, bbytes);

    try std.testing.expectError(error.Cycle, decode(A, out.items));
}
