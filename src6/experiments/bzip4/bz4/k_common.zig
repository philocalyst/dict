//! Lane K: shared B4SD reading + symbol/topology/range-coding utilities.
//! Reused/copied and generalised from `rootctx.zig` (Lane X) per PLAN.md's
//! "Round 3" instructions: same B4SD reader/expansion idea, generalised to
//! n-ary rules (B4SD version 2) and to a small-C Fenwick bucket keyed by
//! *class* instead of by first byte. Pure Zig 0.16, std only.

const std = @import("std");
pub const rc = @import("rc.zig");

pub const Timer = struct {
    io: std.Io,
    started: i96,

    pub fn start(io: std.Io) Timer {
        return .{ .io = io, .started = std.Io.Clock.awake.now(io).nanoseconds };
    }
    pub fn read(self: Timer) u64 {
        const value = std.Io.Clock.awake.now(self.io).nanoseconds - self.started;
        return @intCast(@max(@as(i96, 0), value));
    }
};

pub fn u64c(x: u64) u32 {
    return @intCast(@min(x, @as(u64, std.math.maxInt(u32))));
}

inline fn lowbit(i: usize) usize {
    return i & (0 -% i);
}

// -------------------------------------------------------------- B4SD I/O --
// Accepts both version 1 (binary rules, child ids < parent id) and version 2
// (n-ary rules, arbitrary forward references, DAG must be acyclic). Every
// rule is normalised to a `children: []u32` slice so the rest of Lane K
// never has to care which version it read.

pub const Dump = struct {
    alloc: std.mem.Allocator,
    version: u32,
    children: [][]u32, // children[i] = child ids of rule i (symbol id 256+i)
    child_store: []u32, // backing storage for all `children` slices
    blocks: [][]u32,
    block_bytes: u32,
    raw_len: u32,
    k: usize, // 256 + rules.len

    pub fn deinit(self: *Dump) void {
        for (self.blocks) |b| self.alloc.free(b);
        self.alloc.free(self.blocks);
        self.alloc.free(self.children);
        self.alloc.free(self.child_store);
    }

    /// Raw byte length of block `b`, derivable from the frame header alone.
    pub fn blockRawLen(self: *const Dump, b: usize) u32 {
        const start: u64 = @as(u64, self.block_bytes) * @as(u64, b);
        const end: u64 = @min(@as(u64, self.raw_len), @as(u64, self.block_bytes) * @as(u64, b + 1));
        return @intCast(end - start);
    }
};

fn readU32(bytes: []const u8, off: *usize) u32 {
    const v = std.mem.readInt(u32, bytes[off.*..][0..4], .little);
    off.* += 4;
    return v;
}

pub fn readDump(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !Dump {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 31));
    defer alloc.free(bytes);
    var off: usize = 0;
    const magic = readU32(bytes, &off);
    if (magic != 0x44533442) return error.BadMagic;
    const version = readU32(bytes, &off);
    if (version != 1 and version != 2) return error.BadVersion;
    const rule_count = readU32(bytes, &off);
    const block_count = readU32(bytes, &off);
    const block_bytes = readU32(bytes, &off);
    const raw_len = readU32(bytes, &off);

    const children = try alloc.alloc([]u32, rule_count);
    errdefer alloc.free(children);

    var total_arity: usize = 0;
    if (version == 1) {
        total_arity = @as(usize, rule_count) * 2;
    } else {
        // First scan to size the backing store (version 2 stores arity inline
        // and we need to know the total before allocating one flat buffer).
        var scan_off = off;
        var r: usize = 0;
        while (r < rule_count) : (r += 1) {
            const arity = readU32(bytes, &scan_off);
            if (arity < 2) return error.BadArity;
            total_arity += arity;
            scan_off += @as(usize, arity) * 4;
        }
    }

    const child_store = try alloc.alloc(u32, total_arity);
    errdefer alloc.free(child_store);
    var fill: usize = 0;
    var r: usize = 0;
    while (r < rule_count) : (r += 1) {
        var arity: usize = 2;
        if (version == 2) arity = readU32(bytes, &off);
        const slice = child_store[fill..][0..arity];
        fill += arity;
        for (slice) |*c| c.* = readU32(bytes, &off);
        children[r] = slice;
    }

    const blocks = try alloc.alloc([]u32, block_count);
    errdefer alloc.free(blocks);
    var built: usize = 0;
    errdefer for (blocks[0..built]) |b| alloc.free(b);
    for (blocks) |*blk| {
        const root_count = readU32(bytes, &off);
        const syms = try alloc.alloc(u32, root_count);
        for (syms) |*s| s.* = readU32(bytes, &off);
        blk.* = syms;
        built += 1;
    }
    if (off != bytes.len) return error.TrailingBytes;

    return .{
        .alloc = alloc,
        .version = version,
        .children = children,
        .child_store = child_store,
        .blocks = blocks,
        .block_bytes = block_bytes,
        .raw_len = raw_len,
        .k = 256 + rule_count,
    };
}

// ------------------------------------------------------------ topology --

/// A full symbol-id order (0..k-1) such that every rule's children appear
/// before the rule itself. For B4SD v1 this is just increasing id order
/// (guaranteed by the format); for v2, forward references are allowed so we
/// do an explicit iterative (non-recursive) post-order DFS over the DAG.
pub fn topoOrder(alloc: std.mem.Allocator, dump: *const Dump) ![]u32 {
    const k = dump.k;
    var order = try std.ArrayList(u32).initCapacity(alloc, k);
    errdefer order.deinit(alloc);
    for (0..256) |i| order.appendAssumeCapacity(@intCast(i));

    const state = try alloc.alloc(u8, k); // 0 unvisited, 1 on-stack, 2 done
    defer alloc.free(state);
    @memset(state[0..256], 2);
    @memset(state[256..], 0);

    const Frame = struct { id: u32, next: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(alloc);

    var root_id: u32 = 256;
    while (root_id < k) : (root_id += 1) {
        if (state[root_id] == 2) continue;
        try stack.append(alloc, .{ .id = root_id, .next = 0 });
        state[root_id] = 1;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const kids = dump.children[top.id - 256];
            if (top.next < kids.len) {
                const child = kids[top.next];
                top.next += 1;
                if (state[child] == 0) {
                    state[child] = 1;
                    try stack.append(alloc, .{ .id = child, .next = 0 });
                } else if (state[child] == 1) {
                    return error.CycleDetected;
                }
            } else {
                state[top.id] = 2;
                try order.append(alloc, top.id);
                stack.items.len -= 1;
            }
        }
    }
    std.debug.assert(order.items.len == k);
    return order.toOwnedSlice(alloc);
}

// ---------------------------------------------------------- symbol table --

pub const SymInfo = struct {
    first1: u8,
    last1: u8,
    len: u64, // saturating; only used for display/diagnostics
};

/// Byte-level first/last byte of every symbol's expansion, computed in one
/// pass over `order` (children before parents). Works for v1 and v2 alike.
pub fn buildSymInfo(alloc: std.mem.Allocator, dump: *const Dump, order: []const u32) ![]SymInfo {
    const info = try alloc.alloc(SymInfo, dump.k);
    for (0..256) |i| {
        const b: u8 = @intCast(i);
        info[i] = .{ .first1 = b, .last1 = b, .len = 1 };
    }
    for (order) |id| {
        if (id < 256) continue;
        const kids = dump.children[id - 256];
        const first_child = info[kids[0]];
        const last_child = info[kids[kids.len - 1]];
        var total_len: u64 = 0;
        for (kids) |c| total_len +|= info[c].len;
        info[id] = .{ .first1 = first_child.first1, .last1 = last_child.last1, .len = total_len };
    }
    return info;
}

pub fn computeG(alloc: std.mem.Allocator, dump: *const Dump) ![]u64 {
    const g = try alloc.alloc(u64, dump.k);
    @memset(g, 0);
    for (dump.blocks) |blk| for (blk) |s| {
        g[s] += 1;
    };
    return g;
}

/// Total root-token count across every block.
pub fn totalRoots(dump: *const Dump) usize {
    var n: usize = 0;
    for (dump.blocks) |blk| n += blk.len;
    return n;
}

/// Expand `sym` to its literal bytes, stopping early once `out` holds
/// `max_len` bytes (display/diagnostic use only -- never used for coding).
pub fn expandTruncated(alloc: std.mem.Allocator, dump: *const Dump, sym: u32, out: *std.ArrayList(u8), max_len: usize) !void {
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(alloc);
    try stack.append(alloc, sym);
    while (stack.items.len > 0 and out.items.len < max_len) {
        const top = stack.items[stack.items.len - 1];
        stack.items.len -= 1;
        if (top < 256) {
            try out.append(alloc, @intCast(top));
        } else {
            const kids = dump.children[top - 256];
            var i = kids.len;
            while (i > 0) {
                i -= 1;
                try stack.append(alloc, kids[i]);
            }
        }
    }
}

/// Escape bytes for safe printing in a markdown notebook.
pub fn escapeForPrint(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (bytes) |b| {
        if (b == '\n') {
            try out.appendSlice(alloc, "\\n");
        } else if (b == '\t') {
            try out.appendSlice(alloc, "\\t");
        } else if (b == '\r') {
            try out.appendSlice(alloc, "\\r");
        } else if (b == '\\') {
            try out.appendSlice(alloc, "\\\\");
        } else if (b == '|') {
            try out.appendSlice(alloc, "\\|");
        } else if (b >= 0x20 and b <= 0x7e) {
            try out.append(alloc, b);
        } else {
            const hex = "0123456789abcdef";
            try out.appendSlice(alloc, "\\x");
            try out.append(alloc, hex[b >> 4]);
            try out.append(alloc, hex[b & 0xf]);
        }
    }
    return out.toOwnedSlice(alloc);
}

// ------------------------------------------------------------- Fenwick --

/// Order-statistics Fenwick tree over non-negative u32 counts (copied from
/// rootctx.zig): prefix sum and "find index for cumulative value" both in
/// O(log n), point updates O(log n).
pub const Fenwick = struct {
    counts: []u32,
    tree: []u64,
    n: usize,
    top_pow: usize,

    pub fn init(alloc: std.mem.Allocator, n: usize) !Fenwick {
        const counts = try alloc.alloc(u32, n);
        @memset(counts, 0);
        const tree = try alloc.alloc(u64, n + 1);
        @memset(tree, 0);
        var top: usize = 0;
        if (n > 0) {
            top = 1;
            while (top * 2 <= n) top *= 2;
        }
        return .{ .counts = counts, .tree = tree, .n = n, .top_pow = top };
    }

    pub fn deinit(self: *Fenwick, alloc: std.mem.Allocator) void {
        alloc.free(self.counts);
        alloc.free(self.tree);
    }

    pub fn build(self: *Fenwick, vals: []const u32) void {
        @memcpy(self.counts, vals);
        @memset(self.tree, 0);
        for (0..self.n) |i| self.tree[i + 1] = vals[i];
        var i: usize = 1;
        while (i <= self.n) : (i += 1) {
            const j = i + lowbit(i);
            if (j <= self.n) self.tree[j] += self.tree[i];
        }
    }

    pub fn add(self: *Fenwick, idx0: usize, delta: i32) void {
        const newv: i64 = @as(i64, self.counts[idx0]) + delta;
        self.counts[idx0] = @intCast(newv);
        var i = idx0 + 1;
        while (i <= self.n) : (i += lowbit(i)) {
            const nv: i64 = @as(i64, @bitCast(self.tree[i])) + delta;
            self.tree[i] = @bitCast(nv);
        }
    }

    pub fn prefix(self: *const Fenwick, idx0: usize) u64 {
        var i = idx0;
        var s: u64 = 0;
        while (i > 0) : (i -= lowbit(i)) s += self.tree[i];
        return s;
    }

    pub fn total(self: *const Fenwick) u64 {
        return self.prefix(self.n);
    }

    /// Smallest 0-indexed idx such that prefix(idx+1) > target.
    pub fn find(self: *const Fenwick, target: u64) usize {
        var idx: usize = 0;
        var rem = target;
        var pw = self.top_pow;
        while (pw > 0) : (pw >>= 1) {
            const next = idx + pw;
            if (next <= self.n and self.tree[next] <= rem) {
                idx = next;
                rem -= self.tree[next];
            }
        }
        return idx;
    }
};

/// Symbols bucketed by an arbitrary small key in 0..num_buckets-1 (Lane X's
/// BucketSet, generalised from "first byte" (256 buckets) to "class id" (up
/// to 128 buckets) for Lane K). `local_idx` is a single K-sized array shared
/// across all buckets.
pub const BucketSet = struct {
    fenwicks: []?Fenwick,
    sym_of: [][]u32,
    local_idx: []u32,
    alloc: std.mem.Allocator,
    num_buckets: usize,

    pub fn deinit(self: *BucketSet) void {
        for (0..self.num_buckets) |f| {
            self.alloc.free(self.sym_of[f]);
            if (self.fenwicks[f]) |*fw| fw.deinit(self.alloc);
        }
        self.alloc.free(self.sym_of);
        self.alloc.free(self.fenwicks);
        self.alloc.free(self.local_idx);
    }
};

/// Build buckets keyed by `key_of[s]` (must be < num_buckets), weighted by
/// `weight[s]` (only symbols with weight > 0 participate -- they are the
/// only ones ever coded as roots).
pub fn buildBuckets(alloc: std.mem.Allocator, num_buckets: usize, k: usize, key_of: []const u32, weight: []const u64) !BucketSet {
    const counts = try alloc.alloc(usize, num_buckets);
    defer alloc.free(counts);
    @memset(counts, 0);
    for (0..k) |s| {
        if (weight[s] > 0) counts[key_of[s]] += 1;
    }
    const sym_of = try alloc.alloc([]u32, num_buckets);
    for (0..num_buckets) |f| sym_of[f] = try alloc.alloc(u32, counts[f]);
    const fill = try alloc.alloc(usize, num_buckets);
    defer alloc.free(fill);
    @memset(fill, 0);
    const local_idx = try alloc.alloc(u32, k);
    @memset(local_idx, 0);
    for (0..k) |s| {
        if (weight[s] > 0) {
            const f = key_of[s];
            const idx = fill[f];
            fill[f] += 1;
            sym_of[f][idx] = @intCast(s);
            local_idx[s] = @intCast(idx);
        }
    }
    const fenwicks = try alloc.alloc(?Fenwick, num_buckets);
    @memset(fenwicks, null);
    for (0..num_buckets) |f| {
        if (counts[f] == 0) continue;
        const vals = try alloc.alloc(u32, counts[f]);
        defer alloc.free(vals);
        for (sym_of[f], 0..) |s, i| vals[i] = u64c(weight[s]);
        var fw = try Fenwick.init(alloc, counts[f]);
        fw.build(vals);
        fenwicks[f] = fw;
    }
    return .{ .fenwicks = fenwicks, .sym_of = sym_of, .local_idx = local_idx, .alloc = alloc, .num_buckets = num_buckets };
}

pub fn bsEncodeSym(bs: *BucketSet, enc: *rc.Encoder, f: u32, s: u32) !void {
    const fw = &bs.fenwicks[f].?;
    const local = bs.local_idx[s];
    const freq = fw.counts[local];
    const cum = fw.prefix(local);
    const tot = fw.total();
    try enc.encodeFreq(u64c(cum), freq, u64c(tot));
}

pub fn bsDecodeSym(bs: *BucketSet, dec: *rc.Decoder, f: u32) u32 {
    const fw = &bs.fenwicks[f].?;
    const tot = fw.total();
    const v = dec.decodeFreq(u64c(tot));
    const local = fw.find(v);
    const freq = fw.counts[local];
    const cum = fw.prefix(local);
    dec.consume(u64c(cum), freq);
    return bs.sym_of[f][local];
}

// ------------------------------------------------------ adaptive gamma --

/// Adaptive Elias-gamma-style coder: encode the bit-length of (v+1) with an
/// adaptive unary "continue" prefix (so v=0 is nearly free once the model
/// adapts -- "zeros cheap"), then the mantissa bits raw. Shared by the
/// override list's gaps and the C x C count table.
pub const GAMMA_MAX_BITS: u6 = 32;

pub const GammaCtx = struct {
    cont: [GAMMA_MAX_BITS]rc.Bit = [_]rc.Bit{.{}} ** GAMMA_MAX_BITS,
};

pub fn gammaEncode(enc: *rc.Encoder, ctx: *GammaCtx, v: u32) !void {
    const n: u64 = @as(u64, v) + 1;
    const nbits: u6 = @intCast(64 - @clz(n));
    var i: u6 = 0;
    while (i < nbits - 1) : (i += 1) {
        const idx = if (i < GAMMA_MAX_BITS) i else GAMMA_MAX_BITS - 1;
        try enc.encodeBit(&ctx.cont[idx], 1, 5);
    }
    const stop_idx = if (nbits - 1 < GAMMA_MAX_BITS) nbits - 1 else GAMMA_MAX_BITS - 1;
    try enc.encodeBit(&ctx.cont[stop_idx], 0, 5);
    if (nbits > 1) {
        const mant: u32 = @intCast(n - (@as(u64, 1) << (nbits - 1)));
        try enc.encodeDirect(mant, nbits - 1);
    }
}

pub fn gammaDecode(dec: *rc.Decoder, ctx: *GammaCtx) u32 {
    var nbits: u6 = 1;
    while (true) {
        const idx = if (nbits - 1 < GAMMA_MAX_BITS) nbits - 1 else GAMMA_MAX_BITS - 1;
        const bit = dec.decodeBit(&ctx.cont[idx], 5);
        if (bit == 0) break;
        nbits += 1;
    }
    var n: u64 = 1;
    if (nbits > 1) {
        const mant = dec.decodeDirect(nbits - 1);
        n = (@as(u64, 1) << (nbits - 1)) | mant;
    }
    return @intCast(n - 1);
}

/// Number of raw bits needed to store a value in 0..n-1 (n >= 1): ceil(log2(n)).
pub fn bitsFor(n: u32) u6 {
    if (n <= 1) return 0;
    return @intCast(32 - @clz(n - 1));
}
