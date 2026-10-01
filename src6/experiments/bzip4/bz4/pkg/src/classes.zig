//! Induced class-transition model over corpus tokens:
//! `P(x_i | x_{i-1}) = T[class(x_{i-1})][class(x_i)] * g[x_i]/G[class(x_i)]`
//! with static shared tables, where every entry *inherits* its class for
//! free from its children (target class from the leftmost component,
//! context class from the rightmost component, recursively down to
//! explicit byte classes) and pays only for the rare **override** where an
//! entry's learned class differs from its free inherited default and the
//! saving is estimated to beat the override's own storage cost.
//!
//! `C=1` is order-0 by construction (a single class has one possible
//! transition and the "which class" question is free) -- see PLAN.md's
//! "degenerate cases must fall out of the general code" rule; `bench.zig`
//! and `joint.zig`'s "M tokens + order-0" ablation stage is exactly this
//! module run with `Params{.C = 1}`, not a separate code path.
//!
//! Ported and reshaped from `k_classes.zig` (Lane K) per PLAN.md's
//! copy-and-reshape rule: adapted from a B4SD-dump reader to operate
//! directly on this package's in-memory `Lexicon`/`Corpus`, and narrowed
//! to Lane K's own recommended "safe default" (one learned class per
//! symbol, serving both the target and context role; DAG inheritance
//! always on) -- Lane K's own notebook found inheritance is "not a minor
//! optimisation, it is the entire reason this is affordable" and one map
//! "wins 5/8 head-to-head and never loses badly", so the two-map and
//! no-inherit ablations are not reproduced here (a documented scope cut,
//! not an oversight -- see LANE_Z1.md).

const std = @import("std");
const lexicon = @import("lexicon.zig");
const topology = @import("topology.zig");
const Corpus = lexicon.Corpus;
const Lexicon = lexicon.Lexicon;
const SymInfo = topology.SymInfo;

pub const SMOOTH: f64 = 0.5;
const OVERRIDE_COST_BITS: f64 = 24.0;
const START_SENTINEL: u32 = std.math.maxInt(u32);

pub const Params = struct {
    C: u32 = 128,
    g_min: u64 = 4, // std.math.maxInt(u64) == "inf": bytes only, no entry is ever a candidate
    sweeps: u32 = 8,
    candidate_cap: usize = 6000,
};

fn f(x: anytype) f64 {
    return @floatFromInt(x);
}
fn log2s(x: f64) f64 {
    return @log2(@max(x, 1e-12));
}

/// Root/corpus-only occurrence counts -- see `lexicon.recountRootsOnly`.
pub const computeRootCounts = lexicon.recountRootsOnly;

// ------------------------------------------------------- learning state --

const LearnState = struct {
    learned: []u32, // size k; meaningful for bytes + refined entry candidates
    is_candidate: []bool, // size k
    refine_idx: []i32, // size k; index into refine_list, -1 if not refined
    refine_list: []u32, // symbol ids: 256 bytes then up to candidate_cap entries (by g desc)
    pred_maps: []std.AutoHashMapUnmanaged(u32, u32), // per refine idx: raw predecessor token -> count (self excluded)
    succ_maps: []std.AutoHashMapUnmanaged(u32, u32), // per refine idx: raw successor token -> count (self excluded)
    self_count: []u64,
    G_final: []u64, // size C
    logT_final: []f64, // size (C+1)*C

    fn deinit(self: *LearnState, alloc: std.mem.Allocator) void {
        alloc.free(self.learned);
        alloc.free(self.is_candidate);
        alloc.free(self.refine_idx);
        alloc.free(self.refine_list);
        for (self.pred_maps) |*m| m.deinit(alloc);
        for (self.succ_maps) |*m| m.deinit(alloc);
        alloc.free(self.pred_maps);
        alloc.free(self.succ_maps);
        alloc.free(self.self_count);
        alloc.free(self.G_final);
        alloc.free(self.logT_final);
    }
};

fn initByteRankClasses(C: u32, g: []const u64) [256]u32 {
    var idx: [256]u32 = undefined;
    for (0..256) |i| idx[i] = @intCast(i);
    const Ctx = struct {
        g: []const u64,
        fn lessThan(self: @This(), a: u32, b: u32) bool {
            return self.g[a] > self.g[b];
        }
    };
    std.mem.sort(u32, &idx, Ctx{ .g = g }, Ctx.lessThan);
    var cls: [256]u32 = undefined;
    for (idx, 0..) |byte, rank| {
        const bucket: u32 = @intCast((rank * C) / 256);
        cls[byte] = @min(bucket, C - 1);
    }
    return cls;
}

/// Per-sweep provisional target/context class for every symbol: refine
/// candidates use their own evolving learned class (one map: the same
/// value serves both roles); everything else follows byte-of-first/last-
/// byte inheritance from the CURRENT byte classes ("rarer tokens follow
/// inheritance during learning" -- full DAG cascading through committed
/// overrides only happens in the post-learning topo pass, `finalize`).
/// Fills both `prov_b` (target) and `prov_a` (context) in one pass since
/// they differ only in which byte of a non-candidate's expansion they
/// inherit from.
fn buildProvisional(k: usize, info: []const SymInfo, is_candidate: []const bool, learned: []const u32, prov_b: []u32, prov_a: []u32) void {
    for (0..256) |i| {
        prov_b[i] = learned[i];
        prov_a[i] = learned[i];
    }
    for (256..k) |id| {
        if (is_candidate[id]) {
            prov_b[id] = learned[id];
            prov_a[id] = learned[id];
        } else {
            prov_b[id] = prov_b[info[id].first1];
            prov_a[id] = prov_a[info[id].last1];
        }
    }
}

fn evalCost(C: u32, logT: []const f64, G: []const u64, pred_hist: []const u64, succ_hist: []const u64, self_count: u64, g_x: u64, cur: u32, c: u32) f64 {
    var cost: f64 = 0;
    for (0..C + 1) |p| {
        const w = pred_hist[p];
        if (w == 0) continue;
        cost -= f(w) * logT[p * C + c];
    }
    for (0..C) |s| {
        const w = succ_hist[s];
        if (w == 0) continue;
        cost -= f(w) * logT[c * C + s];
    }
    if (self_count > 0) cost -= f(self_count) * logT[c * C + c];
    const extra: f64 = if (c != cur) f(g_x) else 0.0;
    const denom = f(G[c]) + extra + SMOOTH;
    cost += f(g_x) * log2s(denom);
    return cost;
}

fn learnClasses(alloc: std.mem.Allocator, corpus: *const Corpus, info: []const SymInfo, g: []const u64, params: Params) !LearnState {
    const C = params.C;
    const k = 256 + corpus.lex.numEntries();

    const is_candidate = try alloc.alloc(bool, k);
    for (0..256) |i| is_candidate[i] = true;
    for (256..k) |id| is_candidate[id] = g[id] >= params.g_min;

    var rule_cands: std.ArrayList(u32) = .empty;
    defer rule_cands.deinit(alloc);
    for (256..k) |id| {
        if (is_candidate[id]) try rule_cands.append(alloc, @intCast(id));
    }
    const GCtx = struct {
        g: []const u64,
        fn lessThan(self: @This(), a: u32, b: u32) bool {
            return self.g[a] > self.g[b];
        }
    };
    std.mem.sort(u32, rule_cands.items, GCtx{ .g = g }, GCtx.lessThan);
    const refine_rule_n = @min(rule_cands.items.len, params.candidate_cap);

    const refine_list = try alloc.alloc(u32, 256 + refine_rule_n);
    for (0..256) |i| refine_list[i] = @intCast(i);
    for (0..refine_rule_n) |i| refine_list[256 + i] = rule_cands.items[i];

    const refine_idx = try alloc.alloc(i32, k);
    @memset(refine_idx, -1);
    for (refine_list, 0..) |id, i| refine_idx[id] = @intCast(i);

    const n_refine = refine_list.len;
    const learned = try alloc.alloc(u32, k);
    @memset(learned, 0);

    const byte_init = initByteRankClasses(C, g);
    for (0..256) |i| learned[i] = byte_init[i];
    for (0..refine_rule_n) |i| {
        const id = rule_cands.items[i];
        learned[id] = byte_init[info[id].first1];
    }

    const pred_maps = try alloc.alloc(std.AutoHashMapUnmanaged(u32, u32), n_refine);
    const succ_maps = try alloc.alloc(std.AutoHashMapUnmanaged(u32, u32), n_refine);
    for (pred_maps) |*m| m.* = .{};
    for (succ_maps) |*m| m.* = .{};
    const self_count = try alloc.alloc(u64, n_refine);
    @memset(self_count, 0);

    {
        var start: usize = 0;
        for (corpus.block_end) |end| {
            var prev: u32 = START_SENTINEL;
            for (corpus.seq[start..end]) |s| {
                if (prev != START_SENTINEL) {
                    if (prev == s) {
                        if (refine_idx[s] >= 0) self_count[@intCast(refine_idx[s])] += 1;
                    } else {
                        if (refine_idx[s] >= 0) {
                            const idx: usize = @intCast(refine_idx[s]);
                            const gop = try pred_maps[idx].getOrPut(alloc, prev);
                            if (!gop.found_existing) gop.value_ptr.* = 0;
                            gop.value_ptr.* += 1;
                        }
                        if (refine_idx[prev] >= 0) {
                            const idx: usize = @intCast(refine_idx[prev]);
                            const gop = try succ_maps[idx].getOrPut(alloc, s);
                            if (!gop.found_existing) gop.value_ptr.* = 0;
                            gop.value_ptr.* += 1;
                        }
                    }
                }
                prev = s;
            }
            start = end;
        }
    }

    const prov_b = try alloc.alloc(u32, k);
    defer alloc.free(prov_b);
    const prov_a = try alloc.alloc(u32, k);
    defer alloc.free(prov_a);
    const N = try alloc.alloc(u64, (C + 1) * C);
    defer alloc.free(N);
    const G = try alloc.alloc(u64, C);
    const logT = try alloc.alloc(f64, (C + 1) * C);
    const pred_hist = try alloc.alloc(u64, C + 1);
    defer alloc.free(pred_hist);
    const succ_hist = try alloc.alloc(u64, C);
    defer alloc.free(succ_hist);
    const next_learned = try alloc.alloc(u32, n_refine);
    defer alloc.free(next_learned);

    var sweep: u32 = 0;
    while (sweep < params.sweeps) : (sweep += 1) {
        buildProvisional(k, info, is_candidate, learned, prov_b, prov_a);

        @memset(N, 0);
        {
            var start: usize = 0;
            for (corpus.block_end) |end| {
                var ctx: u32 = C;
                for (corpus.seq[start..end]) |s| {
                    N[ctx * C + prov_b[s]] += 1;
                    ctx = prov_a[s];
                }
                start = end;
            }
        }
        @memset(G, 0);
        for (0..k) |s| G[prov_b[s]] += g[s];

        for (0..C + 1) |a| {
            var rowsum: f64 = 0;
            for (0..C) |c| rowsum += f(N[a * C + c]);
            const denom = rowsum + SMOOTH * f(C);
            for (0..C) |c| logT[a * C + c] = log2s((f(N[a * C + c]) + SMOOTH) / denom);
        }

        for (refine_list, 0..) |x, idx| {
            @memset(pred_hist, 0);
            @memset(succ_hist, 0);
            var it_p = pred_maps[idx].iterator();
            while (it_p.next()) |e| {
                const p_class: u32 = if (e.key_ptr.* == START_SENTINEL) C else prov_a[e.key_ptr.*];
                pred_hist[p_class] += e.value_ptr.*;
            }
            var it_s = succ_maps[idx].iterator();
            while (it_s.next()) |e| succ_hist[prov_b[e.key_ptr.*]] += e.value_ptr.*;
            const gx = g[x];
            const cur = prov_b[x];

            var best_c: u32 = cur;
            var best_cost = evalCost(C, logT, G, pred_hist, succ_hist, self_count[idx], gx, cur, cur);
            for (0..C) |cc| {
                const c: u32 = @intCast(cc);
                if (c == cur) continue;
                const cost = evalCost(C, logT, G, pred_hist, succ_hist, self_count[idx], gx, cur, c);
                if (cost < best_cost) {
                    best_cost = cost;
                    best_c = c;
                }
            }
            next_learned[idx] = best_c;
        }
        for (refine_list, 0..) |x, idx| learned[x] = next_learned[idx];
    }

    // Final snapshot, used by the override-savings estimate in `finalize`.
    buildProvisional(k, info, is_candidate, learned, prov_b, prov_a);
    @memset(N, 0);
    {
        var start: usize = 0;
        for (corpus.block_end) |end| {
            var ctx: u32 = C;
            for (corpus.seq[start..end]) |s| {
                N[ctx * C + prov_b[s]] += 1;
                ctx = prov_a[s];
            }
            start = end;
        }
    }
    @memset(G, 0);
    for (0..k) |s| G[prov_b[s]] += g[s];
    for (0..C + 1) |a| {
        var rowsum: f64 = 0;
        for (0..C) |c| rowsum += f(N[a * C + c]);
        const denom = rowsum + SMOOTH * f(C);
        for (0..C) |c| logT[a * C + c] = log2s((f(N[a * C + c]) + SMOOTH) / denom);
    }

    return .{
        .learned = learned,
        .is_candidate = is_candidate,
        .refine_idx = refine_idx,
        .refine_list = refine_list,
        .pred_maps = pred_maps,
        .succ_maps = succ_maps,
        .self_count = self_count,
        .G_final = G,
        .logT_final = logT,
    };
}

// -------------------------------------------------------------- model --

pub const Model = struct {
    C: u32,
    resolved_b: []u32, // size k, target class of every symbol
    resolved_a: []u32, // size k, context class of every symbol
    byte_class: [256]u32,
    override_ids: []u32, // rule ids (256+entry index), sorted ascending
    override_classes: []u32,
    T: []u32, // (C+1)*C real integer transition counts

    pub fn deinit(self: *Model, alloc: std.mem.Allocator) void {
        alloc.free(self.resolved_b);
        alloc.free(self.resolved_a);
        alloc.free(self.override_ids);
        alloc.free(self.override_classes);
        alloc.free(self.T);
    }
};

/// Resolve every symbol's target/context class from the transmitted model:
/// bytes from the explicit table, entries recursively from their
/// leftmost/rightmost (already-resolved) child, unless an override says
/// otherwise. Used identically encoder-side (building the model) and
/// decoder-side (after a real decode of the model bytes), so the two
/// cannot disagree -- the exact discipline Lane V's notebook found
/// necessary the hard way.
pub fn resolveFromOverrides(alloc: std.mem.Allocator, lex: *const Lexicon, order: []const u32, byte_class: [256]u32, overrides: std.AutoHashMapUnmanaged(u32, u32)) !struct { b: []u32, a: []u32 } {
    const k = 256 + lex.numEntries();
    const resolved_b = try alloc.alloc(u32, k);
    const resolved_a = try alloc.alloc(u32, k);
    for (0..256) |i| {
        resolved_b[i] = byte_class[i];
        resolved_a[i] = byte_class[i];
    }
    for (order) |id| {
        if (id < 256) continue;
        const kids = lex.comps(id - 256);
        const inh_b = resolved_b[kids[0]];
        const inh_a = resolved_a[kids[kids.len - 1]];
        if (overrides.get(id)) |c| {
            resolved_b[id] = c;
            resolved_a[id] = c;
        } else {
            resolved_b[id] = inh_b;
            resolved_a[id] = inh_a;
        }
    }
    return .{ .b = resolved_b, .a = resolved_a };
}

fn combinedCost(C: u32, logT: []const f64, G: []const u64, pred_hist: []const u64, succ_hist: []const u64, self_count: u64, g_x: u64, b_val: u32, a_val: u32, learned_val: u32) f64 {
    var cost: f64 = 0;
    for (0..C + 1) |p| {
        const w = pred_hist[p];
        if (w == 0) continue;
        cost -= f(w) * logT[p * C + b_val];
    }
    for (0..C) |s| {
        const w = succ_hist[s];
        if (w == 0) continue;
        cost -= f(w) * logT[a_val * C + s];
    }
    if (self_count > 0) cost -= f(self_count) * logT[a_val * C + b_val];
    const extra: f64 = if (b_val != learned_val) f(g_x) else 0.0;
    cost += f(g_x) * log2s(f(G[b_val]) + extra + SMOOTH);
    return cost;
}

fn fitT(alloc: std.mem.Allocator, corpus: *const Corpus, C: u32, resolved_b: []const u32, resolved_a: []const u32) ![]u32 {
    const T = try alloc.alloc(u32, (C + 1) * C);
    @memset(T, 0);
    var start: usize = 0;
    for (corpus.block_end) |end| {
        var ctx: u32 = C;
        for (corpus.seq[start..end]) |s| {
            T[ctx * C + resolved_b[s]] += 1;
            ctx = resolved_a[s];
        }
        start = end;
    }
    return T;
}

fn finalize(alloc: std.mem.Allocator, corpus: *const Corpus, order: []const u32, g: []const u64, params: Params, ls: *const LearnState) !Model {
    const C = params.C;
    const k = 256 + corpus.lex.numEntries();
    var byte_class: [256]u32 = undefined;
    for (0..256) |i| byte_class[i] = ls.learned[i];

    var override: std.AutoHashMapUnmanaged(u32, u32) = .{};
    defer override.deinit(alloc);

    // Topological pass, children resolved before parents, deciding
    // overrides by an estimated real-bit-savings test against the FINAL
    // learned classes and transition table.
    const tmp_resolved_b = try alloc.alloc(u32, k);
    defer alloc.free(tmp_resolved_b);
    const tmp_resolved_a = try alloc.alloc(u32, k);
    defer alloc.free(tmp_resolved_a);
    for (0..256) |i| {
        tmp_resolved_b[i] = byte_class[i];
        tmp_resolved_a[i] = byte_class[i];
    }
    const pred_hist = try alloc.alloc(u64, C + 1);
    defer alloc.free(pred_hist);
    const succ_hist = try alloc.alloc(u64, C);
    defer alloc.free(succ_hist);

    for (order) |id| {
        if (id < 256) continue;
        const kids = corpus.lex.comps(id - 256);
        const inh_b = tmp_resolved_b[kids[0]];
        const inh_a = tmp_resolved_a[kids[kids.len - 1]];
        const ridx = ls.refine_idx[id];
        if (ridx < 0) {
            tmp_resolved_b[id] = inh_b;
            tmp_resolved_a[id] = inh_a;
            continue;
        }
        const idx: usize = @intCast(ridx);
        @memset(pred_hist, 0);
        @memset(succ_hist, 0);
        var it_p = ls.pred_maps[idx].iterator();
        while (it_p.next()) |e| {
            const p_class: u32 = if (e.key_ptr.* == START_SENTINEL) C else ls.learned[e.key_ptr.*];
            pred_hist[p_class] += e.value_ptr.*;
        }
        var it_s = ls.succ_maps[idx].iterator();
        while (it_s.next()) |e| succ_hist[ls.learned[e.key_ptr.*]] += e.value_ptr.*;
        const gx = g[id];
        const lb = ls.learned[id];

        tmp_resolved_b[id] = inh_b;
        tmp_resolved_a[id] = inh_a;
        if (lb != inh_b or lb != inh_a) {
            const cost_no = combinedCost(C, ls.logT_final, ls.G_final, pred_hist, succ_hist, ls.self_count[idx], gx, inh_b, inh_a, lb);
            const cost_ov = combinedCost(C, ls.logT_final, ls.G_final, pred_hist, succ_hist, ls.self_count[idx], gx, lb, lb, lb);
            if (cost_no - cost_ov > OVERRIDE_COST_BITS) {
                tmp_resolved_b[id] = lb;
                tmp_resolved_a[id] = lb;
                try override.put(alloc, id, lb);
            }
        }
    }

    // Canonical resolution from the committed override set alone -- the
    // exact function a real decoder uses too.
    var override_owned: std.AutoHashMapUnmanaged(u32, u32) = .{};
    var it = override.iterator();
    while (it.next()) |e| try override_owned.put(alloc, e.key_ptr.*, e.value_ptr.*);
    const resolved = try resolveFromOverrides(alloc, &corpus.lex, order, byte_class, override_owned);
    override_owned.deinit(alloc);

    const T = try fitT(alloc, corpus, C, resolved.b, resolved.a);

    var ids: std.ArrayList(u32) = .empty;
    var classes: std.ArrayList(u32) = .empty;
    var it2 = override.iterator();
    while (it2.next()) |e| try ids.append(alloc, e.key_ptr.*);
    std.mem.sort(u32, ids.items, {}, std.sort.asc(u32));
    for (ids.items) |id| try classes.append(alloc, override.get(id).?);

    return .{
        .C = C,
        .resolved_b = resolved.b,
        .resolved_a = resolved.a,
        .byte_class = byte_class,
        .override_ids = try ids.toOwnedSlice(alloc),
        .override_classes = try classes.toOwnedSlice(alloc),
        .T = T,
    };
}

/// Smoothed estimate of `-log2 P(tgt | ctx)` from a real (unsmoothed) count
/// table -- the same Laplace-smoothed form `learnClasses`/`finalize` use
/// internally to score a hypothetical class assignment. Exposed for
/// `joint.zig`'s benefit-of-deletion estimate, which needs the cost of a
/// transition that the CURRENT corpus may never actually have realised
/// (an entry's children, once spliced apart, can create a class-to-class
/// transition that didn't exist while the entry was one token).
pub fn transitionCostBits(T: []const u32, C: u32, ctx: u32, tgt: u32) f64 {
    var row_total: u64 = 0;
    for (0..C) |c| row_total += T[ctx * C + c];
    return -log2s((f(T[ctx * C + tgt]) + SMOOTH) / (f(row_total) + SMOOTH * f(C)));
}

/// Smoothed estimate of `-log2 P(x | class)` from a symbol's own root count
/// and its class's total -- same rationale as `transitionCostBits` above.
pub fn withinClassCostBits(g_x: u64, g_class_total: u64) f64 {
    return -log2s((f(g_x) + SMOOTH) / (f(g_class_total) + SMOOTH));
}

pub const BuiltModel = struct {
    model: Model,
    num_refined: usize,
};

/// Learn + resolve a class model for `corpus`. `order` must be a valid
/// topological order over `corpus.lex` (see `topology.topoOrder`); `info`
/// its first/last-byte table (`topology.buildSymInfo`); `g` its root/
/// corpus-only occurrence counts (`computeRootCounts`).
pub fn learnAndBuild(alloc: std.mem.Allocator, corpus: *const Corpus, order: []const u32, info: []const SymInfo, g: []const u64, params: Params) !BuiltModel {
    var ls = try learnClasses(alloc, corpus, info, g, params);
    defer ls.deinit(alloc);
    const model = try finalize(alloc, corpus, order, g, params, &ls);
    return .{ .model = model, .num_refined = ls.refine_list.len };
}

test "C=1 collapses to a single class for every symbol" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const raw = "the quick brown fox jumps over the lazy dog. " ** 10;
    var corpus = try lexicon.seedBytes(a, raw, 4096);
    const learn = @import("learn.zig");
    var log: std.ArrayList(learn.IterLog) = .empty;
    try learn.iterate(a, &corpus, raw, .{ .max_iters = 5 }, &log);

    const order = try topology.topoOrder(a, &corpus.lex);
    const info = try topology.buildSymInfo(a, &corpus.lex, order);
    const g = try computeRootCounts(a, &corpus);

    var built = try learnAndBuild(a, &corpus, order, info, g, .{ .C = 1 });
    for (built.model.resolved_b) |c| try std.testing.expectEqual(@as(u32, 0), c);
    for (built.model.resolved_a) |c| try std.testing.expectEqual(@as(u32, 0), c);
    try std.testing.expectEqual(@as(usize, 0), built.model.override_ids.len);
    built.model.deinit(a);
}

test "learnAndBuild finds meaningfully different classes at C=8" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const raw = "the cat sat on the mat. the dog sat on the log. the cat ran and the dog ran. " ** 20;
    var corpus = try lexicon.seedBytes(a, raw, 4096);
    const learn = @import("learn.zig");
    var log: std.ArrayList(learn.IterLog) = .empty;
    try learn.iterate(a, &corpus, raw, .{ .max_iters = 8 }, &log);

    const order = try topology.topoOrder(a, &corpus.lex);
    const info = try topology.buildSymInfo(a, &corpus.lex, order);
    const g = try computeRootCounts(a, &corpus);

    var built = try learnAndBuild(a, &corpus, order, info, g, .{ .C = 8, .g_min = 2 });
    defer built.model.deinit(a);
    // Not every symbol should collapse onto the same class.
    var distinct = std.AutoHashMap(u32, void).init(a);
    for (built.model.resolved_b) |c| try distinct.put(c, {});
    try std.testing.expect(distinct.count() > 1);
}
