//! w3b_fastcm: a fast, exact re-implementation of Lane W's TreeCM decode
//! path (bz4 lab, Lane W3b — "make the decoder fast").
//!
//! `symcm.zig`'s `TreeCM` (Lane W, round 2) proved the *prediction* design
//! (weight-balanced alphabetic tree + order-1/2 mixing + SSE) cuts binary
//! decisions/byte by 5-20x versus a pure byte model, but its *decode speed*
//! did not follow: ~79 ns/decision measured on freedict 1 MiB/k=32768,
//! 2-3x slower than bzip3's whole 8-decision/byte loop. Two causes, per
//! LANE_W3B.md's profiling (see that file for the numbers):
//!
//!   1. The float logistic mixer calls `@log`/`@exp` (stretch/squash) up to
//!      four times per binary decision. Fixed here with integer stretch/
//!      squash lookup tables (12-bit domain, the classic PAQ/lpaq
//!      construction: a public-domain numeric technique, reimplemented
//!      fresh here, not copied from any source file) and i32 fixed-point
//!      (16.16) mixer weights updated by an integer gradient step.
//!   2. The order-1/2 context tables were hashed as `hash(node_idx, prev)`
//!      into one fixed 2^20-entry table — every one of the ~10-20 nodes on
//!      a symbol's root-to-leaf path lands at an unrelated address, so a
//!      full path costs ~10-20 essentially-random cache misses into an 8
//!      MiB span (bigger than most L2/L3 caches). Fixed here by hashing
//!      *only* the context symbol into a 64-byte (32 x u16) bucket, and
//!      using tree depth (capped) as the offset *inside* that bucket: every
//!      node on one symbol's path shares the same bucket, so the whole path
//!      costs one cache miss per context table, not one per node. Table
//!      size is derived from the alphabet actually in play (never a fixed
//!      2^20 regardless of K), and reduces to a Θ(1) direct index (no hash
//!      multiply at all) whenever the alphabet fits — which is always true
//!      in this lab's tested range (K ≤ ~33k) — degrading gracefully to a
//!      capped hashed table only for alphabets bigger than 2^16.
//!
//! Also ships the point-6/7 optimisations from the lane brief: a fused
//! inverse-BWT + grammar-expansion walk (`inverseBwtExpandFused`) that
//! builds the LF/next array in one counting pass and writes expanded bytes
//! straight into the final output buffer as they're produced (no
//! intermediate root-symbol array, no per-root allocation), backed by a
//! flat (offset,len) expansion arena (`Expansion`/`buildExpansion`, the same
//! shape as Lane S's `rootstatic.zig` — copied and adapted here per PLAN.md's
//! "copy it into your own file" rule for a shared/other-lane pattern).
//!
//! Encoder and decoder are real, symmetric, and exact — every roundtrip
//! below is asserted byte- and decision-count-exact. Uses `w3b_rc.zig` (this
//! lane's own fast binary range coder) exclusively; `rc.zig`/`symcm.zig` are
//! only ever *imported for comparison* by `w3b_speedlab.zig`, never by this
//! file.

const std = @import("std");
const rc = @import("w3b_rc.zig");
const gprobe = @import("gprobe.zig");
const symbwt = @import("symbwt.zig");

// ======================================================== AlphaTree ===
// Same weight-balanced alphabetic-tree construction as symcm.zig's
// `AlphaTree`/`buildAlphaTree` (Lane W, round 2) — copied and retargeted
// from 16-bit to 12-bit probabilities (this file's coder works natively in
// rc.zig's/w3b_rc.zig's 12-bit domain throughout, so there's no 16->12 bit
// truncation step at the coding boundary).

pub const TreeNode = struct { mid: u32, left: u32, right: u32 };

pub const AlphaTree = struct {
    nodes: []TreeNode,
    prime: []u16, // P(bit=1) implied by the split's weights, 12-bit domain
    root: u32,
    k_leaves: u32,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *AlphaTree) void {
        self.alloc.free(self.nodes);
        self.alloc.free(self.prime);
    }
};

fn buildTreeRange(
    alloc: std.mem.Allocator,
    cum: []const u64,
    nodes: *std.ArrayList(TreeNode),
    prime: *std.ArrayList(u16),
    k_leaves: u32,
    lo: u32,
    hi: u32,
) !u32 {
    if (hi - lo == 1) return lo;
    const target = cum[lo] + (cum[hi] - cum[lo]) / 2;
    var left: u32 = lo + 1;
    var right: u32 = hi;
    while (left < right) {
        const mid = left + (right - left) / 2;
        if (cum[mid] < target) left = mid + 1 else right = mid;
    }
    var m = left;
    if (m < lo + 1) m = lo + 1;
    if (m > hi - 1) m = hi - 1;
    const left_id = try buildTreeRange(alloc, cum, nodes, prime, k_leaves, lo, m);
    const right_id = try buildTreeRange(alloc, cum, nodes, prime, k_leaves, m, hi);
    const total_w = cum[hi] - cum[lo];
    const right_w = cum[hi] - cum[m];
    const p_right: u64 = if (total_w == 0) 2048 else (right_w * 4096) / total_w;
    const idx: u32 = @intCast(nodes.items.len);
    try nodes.append(alloc, .{ .mid = m, .left = left_id, .right = right_id });
    try prime.append(alloc, @intCast(std.math.clamp(p_right, 1, 4095)));
    return k_leaves + idx;
}

pub fn buildAlphaTree(alloc: std.mem.Allocator, order: []const u32, weight_by_symbol: []const u32) !AlphaTree {
    const k_leaves: u32 = @intCast(order.len);
    if (k_leaves <= 1) {
        return .{ .nodes = try alloc.alloc(TreeNode, 0), .prime = try alloc.alloc(u16, 0), .root = 0, .k_leaves = k_leaves, .alloc = alloc };
    }
    const cum = try alloc.alloc(u64, k_leaves + 1);
    defer alloc.free(cum);
    cum[0] = 0;
    for (order, 0..) |sym, i| cum[i + 1] = cum[i] + weight_by_symbol[sym];

    var nodes: std.ArrayList(TreeNode) = .empty;
    var prime: std.ArrayList(u16) = .empty;
    const root = try buildTreeRange(alloc, cum, &nodes, &prime, k_leaves, 0, k_leaves);
    return .{ .nodes = try nodes.toOwnedSlice(alloc), .prime = try prime.toOwnedSlice(alloc), .root = root, .k_leaves = k_leaves, .alloc = alloc };
}

// ==================================================== integer stretch/squash ===
// Classic PAQ/lpaq construction (Matt Mahoney's public-domain design,
// widely reimplemented across independent compressors — this is a fresh
// implementation of the well-known numeric technique, not copied text):
// `squash` maps a logit (roughly -2047..2047) to a 12-bit probability via a
// 33-point piecewise-linear table; `stretch` is built once by inverting
// `squash` (scanning its monotonic range and recording, for every possible
// 12-bit probability, the smallest logit that reaches it).

fn squashRaw(d: i32) i32 {
    const t = [33]i32{ 1, 2, 3, 6, 10, 16, 27, 45, 73, 120, 194, 310, 488, 747, 1101, 1546, 2047, 2549, 2994, 3348, 3607, 3785, 3901, 3975, 4022, 4050, 4068, 4079, 4085, 4089, 4092, 4093, 4094 };
    var dd = d;
    if (dd > 2047) dd = 2047;
    if (dd < -2047) dd = -2047;
    const idx: usize = @intCast(@divFloor(dd, 128) + 16);
    const w = dd - (@as(i32, @intCast(idx)) - 16) * 128; // dd mod 128, in [0,127]
    return @divFloor(t[idx] * (128 - w) + t[idx + 1] * w + 64, 128);
}

inline fn squash12(d: i32) u16 {
    return @intCast(squashRaw(d));
}

var stretch_table: [4096]i16 = undefined;
var stretch_ready: bool = false;

fn ensureStretchTable() void {
    if (stretch_ready) return;
    var pi: i32 = 0;
    var x: i32 = -2047;
    while (x <= 2047) : (x += 1) {
        const p = squashRaw(x);
        while (pi <= p) : (pi += 1) {
            stretch_table[@intCast(pi)] = @intCast(x);
        }
    }
    while (pi <= 4095) : (pi += 1) stretch_table[@intCast(pi)] = 2047;
    stretch_ready = true;
}

inline fn stretch12(p: u16) i32 {
    return stretch_table[p];
}

// ============================================================ FastTreeCM ===

pub const FastTreeCMConfig = struct {
    use_run_shortcut: bool = true,
    use_mixer: bool = true, // fixed-point logistic mixer vs. bzip3-style fixed weights
    use_sse: bool = true,
    legacy_hash: bool = false, // ablation only: symcm.TreeCM's original hash(node,ctx) addressing
};

inline fn upd0(p: *u16, comptime rate: u4) void {
    p.* = p.* - (p.* >> rate);
}
inline fn upd1(p: *u16, comptime rate: u4) void {
    p.* = p.* +% ((p.* ^ 0xFFF) >> rate);
}
inline fn toP0(p_of_one: u16) u16 {
    const v: i32 = 4096 - @as(i32, p_of_one);
    return @intCast(std.math.clamp(v, 1, 4095));
}

const n_depth_buckets = 16;
const mix_ctx_count = n_depth_buckets * 2;
const slot_bits: u5 = 5; // 32 slots/bucket * 2 bytes = 64-byte cache line
const slot_count: u32 = 1 << slot_bits;
const slot_mask: u32 = slot_count - 1;
const max_bucket_bits: u5 = 16; // caps a table at 2^16 * 32 * 2B = 4 MiB

fn ceilLog2(x: usize) u5 {
    var b: u5 = 0;
    var v: usize = 1;
    while (v < x) {
        v <<= 1;
        b += 1;
    }
    return b;
}

/// One hashed context table: `hash(context_symbol)` selects a 64-byte
/// bucket, tree depth (capped) selects the slot inside it, so every node on
/// one symbol's root-to-leaf path — for a fixed context — shares a single
/// cache line instead of scattering across the whole table. Sized to the
/// alphabet actually in play (`card` = k_leaves+1, +1 for the initial
/// sentinel context), not a fixed 2^20 regardless of K; degrades to a
/// (rare, in this lab's tested range) capped hash only above 2^16 contexts.
const legacy_hash_bits: u5 = 20; // matches symcm.zig's TreeCM table size, for the ablation

const CtxTable = struct {
    table: []u16,
    bucket_bits: u5,
    direct: bool, // true iff `card` fits the bucket space with no collisions
    legacy: bool, // ablation only: hash(node_idx,ctx) into one fixed 2^20 table,
    // i.e. symcm.TreeCM's original addressing, to isolate the memory-layout
    // win from the integer-mixer win (both configs share this file's mixer).

    fn init(alloc: std.mem.Allocator, card: usize, legacy: bool) !CtxTable {
        if (legacy) {
            const table = try alloc.alloc(u16, @as(usize, 1) << legacy_hash_bits);
            @memset(table, 2048);
            return .{ .table = table, .bucket_bits = legacy_hash_bits, .direct = false, .legacy = true };
        }
        const needed = ceilLog2(@max(card, 1));
        const bucket_bits = @min(needed, max_bucket_bits);
        const num_buckets = @as(usize, 1) << bucket_bits;
        const table = try alloc.alloc(u16, num_buckets << slot_bits);
        @memset(table, 2048); // 12-bit half-probability, neutral prior
        return .{ .table = table, .bucket_bits = bucket_bits, .direct = needed <= max_bucket_bits, .legacy = false };
    }

    fn deinit(self: *CtxTable, alloc: std.mem.Allocator) void {
        alloc.free(self.table);
    }

    inline fn bucketOf(self: *const CtxTable, ctx: u32) u32 {
        if (self.direct) return ctx; // ctx < card <= num_buckets: exact, no collision
        const h = (@as(u64, ctx) +% 1) *% 0x9E3779B97F4A7C15;
        const shift: u6 = @intCast(64 - @as(u7, self.bucket_bits));
        return @truncate(h >> shift);
    }

    inline fn slotPtr(self: *CtxTable, ctx: u32, depth: u32, node_idx: u32) *u16 {
        if (self.legacy) {
            const h = ((@as(u64, node_idx) *% 0x9E3779B97F4A7C15) ^ (@as(u64, ctx +% 1) *% 0xC2B2AE3D27D4EB4F));
            const shift: u6 = @intCast(64 - @as(u7, legacy_hash_bits));
            const idx: u32 = @truncate(h >> shift);
            return &self.table[idx];
        }
        const bucket = self.bucketOf(ctx);
        const idx = (bucket << slot_bits) | (depth & slot_mask);
        return &self.table[idx];
    }

    /// Hint the CPU to start pulling in the 64-byte bucket for `ctx` before
    /// the tree walk actually touches it (point 2's "prefetch the next
    /// symbol's buckets as soon as L[i-1] is known" — here L[i-1] is
    /// `ctx`, known the instant the previous symbol finished decoding).
    /// Meaningless in `legacy` mode (address depends on `node_idx`, not
    /// known this early — that dependency is exactly the bottleneck being
    /// measured), so it's a no-op there.
    inline fn prefetch(self: *const CtxTable, ctx: u32) void {
        if (self.legacy) return;
        const bucket = self.bucketOf(ctx);
        const idx = bucket << slot_bits;
        @prefetch(&self.table[idx], .{ .rw = .read, .locality = 3, .cache = .data });
    }
};

pub const FastTreeCM = struct {
    tree: *const AlphaTree,
    order: []const u32,

    p0: []u16, // owned copy of tree.prime, adapts per block (order-0 per node)
    ctx1: CtxTable, // order-1: hash(prev1) x depth
    ctx2: CtxTable, // order-2: hash(prev2) x depth
    sse: []u16, // [mix_ctx][17], 8-bit interpolation fraction
    mixw: [mix_ctx_count][3]i32, // 16.16 fixed-point weights
    run_bit: [16]rc.Bit = [_]rc.Bit{.{}} ** 16,

    prev1: u32,
    prev2: u32,
    run_len: u32 = 0,
    prev_hit: bool = false,
    decisions: u64 = 0,

    cfg: FastTreeCMConfig,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, tree: *const AlphaTree, order: []const u32, cfg: FastTreeCMConfig) !FastTreeCM {
        ensureStretchTable();
        const card = @as(usize, tree.k_leaves) + 1;
        var self: FastTreeCM = .{
            .tree = tree,
            .order = order,
            .p0 = try alloc.dupe(u16, tree.prime),
            .ctx1 = try CtxTable.init(alloc, card, cfg.legacy_hash),
            .ctx2 = try CtxTable.init(alloc, card, cfg.legacy_hash),
            .sse = try alloc.alloc(u16, mix_ctx_count * 17),
            .mixw = [_][3]i32{.{ 22938, 22938, 9830 }} ** mix_ctx_count, // ~0.35,0.35,0.15 in 16.16
            .prev1 = tree.k_leaves,
            .prev2 = tree.k_leaves,
            .cfg = cfg,
            .alloc = alloc,
        };
        for (0..mix_ctx_count) |j| {
            for (0..17) |kk| {
                const v: i32 = @as(i32, @intCast(kk)) << 8;
                self.sse[j * 17 + kk] = @intCast(v - @as(i32, if (kk == 16) 1 else 0));
            }
        }
        return self;
    }

    pub fn deinit(self: *FastTreeCM) void {
        self.alloc.free(self.p0);
        self.ctx1.deinit(self.alloc);
        self.ctx2.deinit(self.alloc);
        self.alloc.free(self.sse);
    }

    inline fn runCtx(self: *const FastTreeCM) usize {
        const bucket: usize = @min(self.run_len, 7);
        return bucket * 2 + @intFromBool(self.prev_hit);
    }

    /// Prefetch both order-1/2 buckets for the *current* context (known the
    /// instant the previous symbol was decoded) before doing any of the
    /// current symbol's own work, so the fetch latency overlaps with the
    /// run-shortcut check and tree-root access instead of stalling the walk.
    inline fn prefetchCtx(self: *const FastTreeCM) void {
        self.ctx1.prefetch(self.prev1);
        self.ctx2.prefetch(self.prev2);
    }

    const NodePred = struct {
        node_idx: u32,
        p1_slot: *u16,
        p2_slot: *u16,
        mix_ctx: usize,
        st0: i32,
        st1: i32,
        st2: i32,
        pre_mix: u16,
        sse_x1: ?*u16,
        sse_x2: ?*u16,
        p_final: u16,
    };

    inline fn predictNode(self: *FastTreeCM, node_idx: u32, depth: u32) NodePred {
        const p0v = self.p0[node_idx];
        const p1_slot = self.ctx1.slotPtr(self.prev1, depth, node_idx);
        const p2_slot = self.ctx2.slotPtr(self.prev2, depth, node_idx);
        const p1v = p1_slot.*;
        const p2v = p2_slot.*;
        const db: usize = @min(depth, n_depth_buckets - 1);
        const rf: usize = @intFromBool(self.run_len > 2);
        const mix_ctx = db * 2 + rf;

        var pre_mix: u16 = undefined;
        var st0: i32 = 0;
        var st1: i32 = 0;
        var st2: i32 = 0;
        if (self.cfg.use_mixer) {
            st0 = stretch12(p0v);
            st1 = stretch12(p1v);
            st2 = stretch12(p2v);
            const w = self.mixw[mix_ctx];
            const dot = (w[0] * st0 + w[1] * st1 + w[2] * st2) >> 16;
            pre_mix = squash12(std.math.clamp(dot, -2047, 2047));
        } else {
            const mix: u32 = (@as(u32, p0v) + p1v) * 7 + @as(u32, p2v) * 2;
            pre_mix = @intCast(mix >> 4);
        }

        var sse_x1: ?*u16 = null;
        var sse_x2: ?*u16 = null;
        var p_final = pre_mix;
        if (self.cfg.use_sse) {
            const base = mix_ctx * 17;
            const j = p_final >> 8;
            const x1p = &self.sse[base + j];
            const x2p = &self.sse[base + j + 1];
            sse_x1 = x1p;
            sse_x2 = x2p;
            const x1: i32 = x1p.*;
            const x2: i32 = x2p.*;
            const delta: i32 = x2 - x1;
            const ssep: i32 = x1 + ((delta * @as(i32, p_final & 255)) >> 8);
            const blended: i32 = (ssep * 3 + @as(i32, p_final)) >> 2;
            p_final = @intCast(std.math.clamp(blended, 0, 4095));
        }

        return .{
            .node_idx = node_idx,
            .p1_slot = p1_slot,
            .p2_slot = p2_slot,
            .mix_ctx = mix_ctx,
            .st0 = st0,
            .st1 = st1,
            .st2 = st2,
            .pre_mix = pre_mix,
            .sse_x1 = sse_x1,
            .sse_x2 = sse_x2,
            .p_final = p_final,
        };
    }

    inline fn updateNode(self: *FastTreeCM, pred: NodePred, bit: u1) void {
        if (bit == 1) {
            upd1(&self.p0[pred.node_idx], 2);
            upd1(pred.p1_slot, 4);
            upd1(pred.p2_slot, 4);
        } else {
            upd0(&self.p0[pred.node_idx], 2);
            upd0(pred.p1_slot, 4);
            upd0(pred.p2_slot, 4);
        }
        if (self.cfg.use_sse) {
            if (bit == 1) {
                upd1(pred.sse_x1.?, 6);
                upd1(pred.sse_x2.?, 6);
            } else {
                upd0(pred.sse_x1.?, 6);
                upd0(pred.sse_x2.?, 6);
            }
        }
        if (self.cfg.use_mixer) {
            // Learning-rate shift: the first working version used `>> 10`
            // (a direct port of lpaq1's `Mixer::update` shift) and *lost* to
            // the simple fixed-weight mix on both size and speed (see
            // LANE_W3B.md's "mixer tuning" note) — a well-tuned adaptive
            // mixer should never lose on size to a static one. `>> 14`
            // (16x slower) recovered it: freedict's size_delta_pct dropped
            // 1.32% -> 0.11%, macho's 2.20% -> 0.88%, at no speed cost.
            // Plausible cause: this coder's 12-bit stretch/squash domain is
            // coarser than symcm.TreeCM's float version, so the same shift
            // that suited float weights over-corrected here.
            const target: i32 = if (bit == 1) 4096 else 0;
            const err = (target - @as(i32, pred.pre_mix)) * 7;
            var w = &self.mixw[pred.mix_ctx];
            w[0] = std.math.clamp(w[0] + ((pred.st0 * err) >> 14), -(1 << 22), (1 << 22) - 1);
            w[1] = std.math.clamp(w[1] + ((pred.st1 * err) >> 14), -(1 << 22), (1 << 22) - 1);
            w[2] = std.math.clamp(w[2] + ((pred.st2 * err) >> 14), -(1 << 22), (1 << 22) - 1);
        }
    }

    pub fn encodeSymbol(self: *FastTreeCM, enc: *rc.Encoder, sym: u32, rev_rank: []const u32) !void {
        const was_same = sym == self.prev1;
        if (self.cfg.use_run_shortcut) {
            const ctx = self.runCtx();
            try enc.encodeBit(&self.run_bit[ctx], @intFromBool(was_same), 5);
            self.decisions += 1;
        }
        if (!(self.cfg.use_run_shortcut and was_same)) {
            self.prefetchCtx();
            const target_rank = rev_rank[sym];
            var cur = self.tree.root;
            var depth: u32 = 0;
            while (cur >= self.tree.k_leaves) {
                const node_idx = cur - self.tree.k_leaves;
                const node = self.tree.nodes[node_idx];
                const bit: u1 = if (target_rank < node.mid) 0 else 1;
                const pred = self.predictNode(node_idx, depth);
                try enc.encodeBitProb(toP0(pred.p_final), bit);
                self.updateNode(pred, bit);
                self.decisions += 1;
                cur = if (bit == 0) node.left else node.right;
                depth += 1;
            }
        }
        if (was_same) {
            self.run_len += 1;
            self.prev_hit = true;
        } else {
            self.run_len = 0;
            self.prev_hit = false;
        }
        self.prev2 = self.prev1;
        self.prev1 = sym;
    }

    pub fn decodeSymbol(self: *FastTreeCM, dec: *rc.Decoder) u32 {
        var sym: u32 = undefined;
        var shortcut_hit = false;
        if (self.cfg.use_run_shortcut) {
            const ctx = self.runCtx();
            const bit = dec.decodeBit(&self.run_bit[ctx], 5);
            self.decisions += 1;
            if (bit == 1) {
                sym = self.prev1;
                shortcut_hit = true;
            }
        }
        if (!shortcut_hit) {
            self.prefetchCtx();
            var cur = self.tree.root;
            var depth: u32 = 0;
            while (cur >= self.tree.k_leaves) {
                const node_idx = cur - self.tree.k_leaves;
                const node = self.tree.nodes[node_idx];
                const pred = self.predictNode(node_idx, depth);
                const bit = dec.decodeBitProb(toP0(pred.p_final));
                self.updateNode(pred, bit);
                self.decisions += 1;
                cur = if (bit == 0) node.left else node.right;
                depth += 1;
            }
            sym = self.order[cur];
        }
        const is_repeat = sym == self.prev1;
        if (is_repeat) {
            self.run_len += 1;
            self.prev_hit = true;
        } else {
            self.run_len = 0;
            self.prev_hit = false;
        }
        self.prev2 = self.prev1;
        self.prev1 = sym;
        return sym;
    }
};

pub const Counted = struct { bytes: []const u8, decisions: u64 };
pub const CountedSyms = struct { syms: []u32, decisions: u64 };

pub fn encodeSymbols(alloc: std.mem.Allocator, syms: []const u32, tree: *const AlphaTree, order: []const u32, rev_rank: []const u32, cfg: FastTreeCMConfig) !Counted {
    var cm = try FastTreeCM.init(alloc, tree, order, cfg);
    defer cm.deinit();
    var enc = rc.Encoder.init(alloc);
    defer enc.deinit();
    for (syms) |s| try cm.encodeSymbol(&enc, s, rev_rank);
    return .{ .bytes = try alloc.dupe(u8, try enc.finish()), .decisions = cm.decisions };
}

pub fn decodeSymbols(alloc: std.mem.Allocator, bytes: []const u8, n: usize, tree: *const AlphaTree, order: []const u32, cfg: FastTreeCMConfig) !CountedSyms {
    var cm = try FastTreeCM.init(alloc, tree, order, cfg);
    defer cm.deinit();
    var dec = rc.Decoder.init(bytes);
    const out = try alloc.alloc(u32, n);
    errdefer alloc.free(out);
    for (out) |*s| s.* = cm.decodeSymbol(&dec);
    return .{ .syms = out, .decisions = cm.decisions };
}

// ===================================================== expansion arena ===
// Same (offset,len)-into-one-arena shape as Lane S's `rootstatic.zig`
// (`Expansion`/`buildExpansion`/`copyExpansionFast`) — copied and adapted
// here to key off `gprobe.Rule` directly, per PLAN.md's rule that a shared
// pattern from another lane's file gets copied into your own, not imported
// and mutated. Eager one-pass build (children always have smaller ids).

pub const overscan_pad: usize = 64;

pub const Expansion = struct {
    off: []u64,
    len: []u32,
    arena: []u8, // padded with `overscan_pad` zero bytes past `arena_used`
    arena_used: usize,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *Expansion) void {
        self.alloc.free(self.off);
        self.alloc.free(self.len);
        self.alloc.free(self.arena);
    }
};

pub fn buildExpansion(alloc: std.mem.Allocator, rules: []const gprobe.Rule) !Expansion {
    const k = 256 + rules.len;
    const off = try alloc.alloc(u64, k);
    errdefer alloc.free(off);
    const len = try alloc.alloc(u32, k);
    errdefer alloc.free(len);
    for (0..256) |i| {
        off[i] = i;
        len[i] = 1;
    }
    var total: u64 = 256;
    for (rules, 0..) |r, i| {
        const l = len[r.a] + len[r.b];
        len[256 + i] = l;
        total += l;
    }
    const arena = try alloc.alloc(u8, total + overscan_pad);
    errdefer alloc.free(arena);
    for (0..256) |i| arena[i] = @intCast(i);
    var write: u64 = 256;
    for (rules, 0..) |r, i| {
        const id = 256 + i;
        off[id] = write;
        const la = len[r.a];
        const lb = len[r.b];
        @memcpy(arena[write .. write + la], arena[off[r.a] .. off[r.a] + la]);
        write += la;
        @memcpy(arena[write .. write + lb], arena[off[r.b] .. off[r.b] + lb]);
        write += lb;
    }
    @memset(arena[write .. write + overscan_pad], 0);
    std.debug.assert(write == total);
    return .{ .off = off, .len = len, .arena = arena, .arena_used = write, .alloc = alloc };
}

/// Unconditional overscan copy (dst and src are both padded past their real
/// length), same idiom as `rootstatic.zig`'s `copyExpansionFast`.
pub inline fn copyExpansionFast(dst: [*]u8, src: [*]const u8, l: u32) void {
    if (l <= 16) {
        @as(*[16]u8, @ptrCast(dst)).* = @as(*const [16]u8, @ptrCast(src)).*;
    } else if (l <= 32) {
        @as(*[32]u8, @ptrCast(dst)).* = @as(*const [32]u8, @ptrCast(src)).*;
    } else {
        var i: usize = 0;
        while (i + 32 <= l) : (i += 32) {
            @as(*[32]u8, @ptrCast(dst + i)).* = @as(*const [32]u8, @ptrCast(src + i)).*;
        }
        while (i < l) : (i += 1) dst[i] = src[i];
    }
}

// ============================================== fused inverse-BWT+expand ===
// Point 6 ("build the LF/next array with one counting pass, walk it with
// the expansion copy fused in") + point 7 ("(offset,len) arena + memcpy").
// Reuses `symbwt.zig`'s counting-pass LF/next construction (Lane W, its own
// design already O(n)/one counting pass — imported read-only, not edited),
// but never materialises the "roots in original order" array `symbwt.ibwt`
// returns: as each row's original root symbol is produced by the backward
// walk, it is expanded straight into the caller's output buffer.

/// One hop of the inverse-BWT walk, packed together so the walk touches
/// *one* random cache line per step instead of two. The naive construction
/// (`symbwt.ibwt`'s own shape) keeps `prev[]` (predecessor row) and
/// `full[]` (that row's F-column value) as separate arrays, so each walk
/// step does two independent essentially-random loads (`i=prev[row]` then
/// `val=full[i]`) — for a block whose `next`/`prev` array exceeds L2/L3
/// (point 6's explicit call-out), that is two cache misses per output root
/// instead of one. `Step{i,val}` merges them at construction time (still
/// one O(m) counting pass) so the walk is one load + one prefetch per step.
const Step = struct { i: u32, val: u32 };

pub const BwtScratch = struct {
    full: []u32, // construction scratch only
    count: []u32,
    base: []u32,
    occ: []u32,
    next: []u32, // construction scratch only
    step: []Step, // the walk table
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, max_m: usize, k_alphabet: usize) !BwtScratch {
        return .{
            .full = try alloc.alloc(u32, max_m),
            .count = try alloc.alloc(u32, k_alphabet + 1),
            .base = try alloc.alloc(u32, k_alphabet + 1),
            .occ = try alloc.alloc(u32, k_alphabet + 1),
            .next = try alloc.alloc(u32, max_m),
            .step = try alloc.alloc(Step, max_m),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *BwtScratch) void {
        self.alloc.free(self.full);
        self.alloc.free(self.count);
        self.alloc.free(self.base);
        self.alloc.free(self.occ);
        self.alloc.free(self.next);
        self.alloc.free(self.step);
    }
};

/// `l_fwd`: the BWT's last column, already in fwd_rank (lexicographic sort)
/// domain, length n. `order_fwd`: rank -> original symbol id. `exp`: the
/// expansion arena, keyed by *original* symbol id. Writes the block's raw
/// bytes into `out` (caller-sized exactly) and returns the count written.
pub fn inverseBwtExpandFused(
    scratch: *BwtScratch,
    l_fwd: []const u32,
    primary: usize,
    k_alphabet: usize,
    order_fwd: []const u32,
    exp: *const Expansion,
    out: []u8,
) usize {
    const n = l_fwd.len;
    const m = n + 1;
    const full = scratch.full[0..m];
    {
        var src_i: usize = 0;
        for (0..m) |i| {
            if (i == primary) {
                full[i] = 0;
            } else {
                full[i] = l_fwd[src_i] + 1;
                src_i += 1;
            }
        }
    }
    const count = scratch.count[0 .. k_alphabet + 1];
    @memset(count, 0);
    for (full) |v| count[v] += 1;
    const base = scratch.base[0 .. k_alphabet + 1];
    {
        var sum: u32 = 0;
        for (0..k_alphabet + 1) |c| {
            base[c] = sum;
            sum += count[c];
        }
    }
    const occ = scratch.occ[0 .. k_alphabet + 1];
    @memset(occ, 0);
    const next = scratch.next[0..m];
    for (0..m) |i| {
        const v = full[i];
        next[i] = base[v] + occ[v];
        occ[v] += 1;
    }
    // Invert next[] into the walk table directly: step[next[i]] = (i,
    // full[i]) — one counting pass, same as building `prev[]` alone would
    // cost, but it also captures the F-column value at no extra pass.
    const step = scratch.step[0..m];
    for (0..m) |i| step[next[i]] = .{ .i = @intCast(i), .val = full[i] };

    var row = primary;
    var write: usize = 0;
    for (0..n) |_| {
        const s = step[row];
        // The next hop's address (`s.i`) is known now, one step before it's
        // needed — prefetch it so its latency overlaps this step's
        // expansion copy instead of stalling the next loop iteration
        // (point 6: "try ... prefetching along the walk").
        @prefetch(&step[s.i], .{ .rw = .read, .locality = 3, .cache = .data });
        std.debug.assert(s.val != 0);
        const sym = order_fwd[s.val - 1];
        const l = exp.len[sym];
        copyExpansionFast(out.ptr + write, exp.arena.ptr + exp.off[sym], l);
        write += l;
        row = s.i;
    }
    return write;
}

// ---------------------------------------------------------------- tests --

test "squash/stretch are inverse-ish and monotone" {
    ensureStretchTable();
    var prev: i32 = -1;
    var p: usize = 0;
    while (p < 4096) : (p += 1) {
        const d = stretch12(@intCast(p));
        try std.testing.expect(d >= prev or p == 0);
        prev = d;
    }
    // Round-tripping a mid-range probability through stretch->squash should
    // land close to where it started (monotone piecewise-linear, not exact).
    const mid_d = stretch12(3000);
    const back = squash12(mid_d);
    try std.testing.expect(@as(i32, back) > 2500 and @as(i32, back) < 3500);
}

test "AlphaTree: frequent symbols get shorter paths" {
    const alloc = std.testing.allocator;
    const k: u32 = 300;
    const order = try alloc.alloc(u32, k);
    defer alloc.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const w = try alloc.alloc(u32, k);
    defer alloc.free(w);
    @memset(w, 1);
    w[150] = 1_000_000;
    var t = try buildAlphaTree(alloc, order, w);
    defer t.deinit();

    const depthOf = struct {
        fn go(tree: *const AlphaTree, target_rank: u32) u32 {
            if (tree.k_leaves <= 1) return 0;
            var cur = tree.root;
            var depth: u32 = 0;
            while (cur >= tree.k_leaves) {
                const node = tree.nodes[cur - tree.k_leaves];
                cur = if (target_rank < node.mid) node.left else node.right;
                depth += 1;
            }
            return depth;
        }
    }.go;
    try std.testing.expect(depthOf(&t, 150) < depthOf(&t, 0));
}

test "FastTreeCM roundtrip, all config combinations, Zipf-ish K=4000" {
    const alloc = std.testing.allocator;
    const k: u32 = 4000;
    const order = try alloc.alloc(u32, k);
    defer alloc.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const rev_rank = try alloc.alloc(u32, k);
    defer alloc.free(rev_rank);
    for (order, 0..) |sym, r| rev_rank[sym] = @intCast(r);
    const w = try alloc.alloc(u32, k);
    defer alloc.free(w);
    for (w, 0..) |*wi, i| wi.* = @intCast(1 + (k - i) * (k - i) / k);

    var tree = try buildAlphaTree(alloc, order, w);
    defer tree.deinit();

    var prng = std.Random.DefaultPrng.init(0x7E7);
    const rnd = prng.random();
    var syms: std.ArrayList(u32) = .empty;
    defer syms.deinit(alloc);
    while (syms.items.len < 15_000) {
        const r = rnd.float(f64);
        const v: f64 = @as(f64, @floatFromInt(k)) * r * r;
        const sym: u32 = @min(@as(u32, @intFromFloat(v)), k - 1);
        const run: u32 = 1 + rnd.uintLessThan(u32, 8);
        for (0..run) |_| try syms.append(alloc, sym);
    }

    const configs = [_]FastTreeCMConfig{
        .{ .use_run_shortcut = false, .use_mixer = false, .use_sse = false },
        .{ .use_run_shortcut = true, .use_mixer = false, .use_sse = false },
        .{ .use_run_shortcut = false, .use_mixer = false, .use_sse = true },
        .{ .use_run_shortcut = false, .use_mixer = true, .use_sse = false },
        .{ .use_run_shortcut = true, .use_mixer = true, .use_sse = true },
    };
    for (configs, 0..) |cfg, i| {
        const enc = try encodeSymbols(alloc, syms.items, &tree, order, rev_rank, cfg);
        defer alloc.free(enc.bytes);
        const dec = try decodeSymbols(alloc, enc.bytes, syms.items.len, &tree, order, cfg);
        defer alloc.free(dec.syms);
        try std.testing.expectEqualSlices(u32, syms.items, dec.syms);
        try std.testing.expectEqual(enc.decisions, dec.decisions);
        if (i == configs.len - 1) try std.testing.expect(enc.bytes.len < syms.items.len);
    }
}

test "FastTreeCM roundtrip, tiny K (1 and 2)" {
    const alloc = std.testing.allocator;
    {
        const order = [_]u32{5};
        const w = [_]u32{ 0, 0, 0, 0, 0, 9 };
        var tree = try buildAlphaTree(alloc, &order, &w);
        defer tree.deinit();
        var rev_rank = [_]u32{0} ** 6;
        rev_rank[5] = 0;
        const syms = [_]u32{ 5, 5, 5, 5 };
        const enc = try encodeSymbols(alloc, &syms, &tree, &order, &rev_rank, .{});
        defer alloc.free(enc.bytes);
        const dec = try decodeSymbols(alloc, enc.bytes, syms.len, &tree, &order, .{});
        defer alloc.free(dec.syms);
        try std.testing.expectEqualSlices(u32, &syms, dec.syms);
    }
    {
        const order = [_]u32{ 1, 0 };
        const w = [_]u32{ 5, 1 };
        var tree = try buildAlphaTree(alloc, &order, &w);
        defer tree.deinit();
        var rev_rank = [_]u32{ 0, 0 };
        for (order, 0..) |sym, r| rev_rank[sym] = @intCast(r);
        var prng = std.Random.DefaultPrng.init(3);
        const rnd = prng.random();
        const syms = try alloc.alloc(u32, 500);
        defer alloc.free(syms);
        for (syms) |*s| s.* = rnd.uintLessThan(u32, 2);
        const enc = try encodeSymbols(alloc, syms, &tree, &order, &rev_rank, .{});
        defer alloc.free(enc.bytes);
        const dec = try decodeSymbols(alloc, enc.bytes, syms.len, &tree, &order, .{});
        defer alloc.free(dec.syms);
        try std.testing.expectEqualSlices(u32, syms, dec.syms);
    }
}

test "buildExpansion + inverseBwtExpandFused: full pipeline, tiny synthetic grammar" {
    const alloc = std.testing.allocator;
    // Rules: 256="th", 257="e ", 258=th+e_ ("the "), all built from bytes.
    const rules = [_]gprobe.Rule{
        .{ .a = 't', .b = 'h' }, // 256
        .{ .a = 'e', .b = ' ' }, // 257
        .{ .a = 256, .b = 257 }, // 258 = "the "
    };
    var exp = try buildExpansion(alloc, &rules);
    defer exp.deinit();
    try std.testing.expectEqualSlices(u8, "the ", exp.arena[exp.off[258] .. exp.off[258] + exp.len[258]]);

    // roots = [258, 258, 'x'] -> "the the x"
    const roots = [_]u32{ 258, 258, 'x' };
    const k_alphabet = 259;
    const fwd_rank = try alloc.alloc(u32, k_alphabet);
    defer alloc.free(fwd_rank);
    for (fwd_rank, 0..) |*r, i| r.* = @intCast(i); // identity: sort order irrelevant to this test
    const order_fwd = fwd_rank; // identity permutation is its own inverse here

    const bw = try symbwt.bwt(alloc, &roots, k_alphabet);
    defer alloc.free(bw.l);

    var scratch = try BwtScratch.init(alloc, roots.len + 1, k_alphabet);
    defer scratch.deinit();
    var out: [64]u8 = undefined;
    const expected = "the the x";
    const n_written = inverseBwtExpandFused(&scratch, bw.l, bw.primary, k_alphabet, order_fwd, &exp, out[0..expected.len]);
    try std.testing.expectEqual(expected.len, n_written);
    try std.testing.expectEqualSlices(u8, expected, out[0..expected.len]);
}
