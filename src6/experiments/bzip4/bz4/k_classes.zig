//! Lane K: induced part-of-speech-style class transition model over root
//! tokens. P(x_i | x_{i-1}) = T[a(x_{i-1})][b(x_i)] * g[x_i]/G[b(x_i)] with
//! static shared tables, DAG inheritance (b(rule)=b(leftmost child),
//! a(rule)=a(rightmost child), recursively to explicit byte classes), and
//! cost-pruned overrides. See PLAN.md's "Round 3" item 3 and LANE_K.md for
//! the write-up. Pure Zig 0.16, std only.
//!
//! Pipeline: learnClasses (encoder-only exchange/EM sweep over a capped
//! high-frequency candidate set) -> finalize (DAG topo pass deciding real
//! overrides by an estimated bit-savings test, then re-fit T from the FINAL
//! classes) -> encode model bytes (byte classes + overrides + T, real rc) ->
//! decode model bytes back (genuine round trip, not reused encoder state) ->
//! real per-block rc encode/decode of the root stream, verified against the
//! dump's own root sequence.

const std = @import("std");
const kc = @import("k_common.zig");
const rc = kc.rc;

const SMOOTH: f64 = 0.5;
const OVERRIDE_COST_BITS: f64 = 24.0;
const START_SENTINEL: u32 = std.math.maxInt(u32);

pub const Params = struct {
    C: u32,
    two_maps: bool,
    inherit: bool,
    g_min: u64, // std.math.maxInt(u64) == "inf" (bytes only, no rule ever a candidate)
    sweeps: u32 = 8,
    candidate_cap: usize = 6000,
};

pub const Result = struct {
    tokens: usize = 0,
    payload_x0: usize = 0,
    payload_class: usize = 0,
    table_bytes: usize = 0,
    override_bytes: usize = 0,
    net_total: usize = 0,
    pct_vs_x0: f64 = 0,
    learn_ms: f64 = 0,
    decode_ns_per_token: f64 = 0,
    num_overrides_b: usize = 0,
    num_overrides_a: usize = 0,
    num_refined: usize = 0,
};

fn f(x: anytype) f64 {
    return @floatFromInt(x);
}
fn log2s(x: f64) f64 {
    return @log2(@max(x, 1e-12));
}

// ------------------------------------------------------------- X0 ref --

pub fn runX0(alloc: std.mem.Allocator, io: std.Io, dump: *const kc.Dump, info: []const kc.SymInfo, g: []const u64) !usize {
    _ = info;
    const key0 = try alloc.alloc(u32, dump.k);
    defer alloc.free(key0);
    @memset(key0, 0);
    var bs = try kc.buildBuckets(alloc, 1, dump.k, key0, g);
    defer bs.deinit();
    var payload: usize = 0;
    for (dump.blocks, 0..) |blk, bidx| {
        var enc = rc.Encoder.init(alloc);
        for (blk) |s| try kc.bsEncodeSym(&bs, &enc, 0, s);
        const bytes = try enc.finish();
        payload += bytes.len;
        enc.deinit();
        _ = bidx;
    }
    _ = io;
    return payload;
}

// ------------------------------------------------------- learning state --

const LearnState = struct {
    learned_b: []u32, // size k; meaningful for bytes + refined rule candidates
    learned_a: []u32,
    is_candidate: []bool, // size k (rules only meaningfully vary; bytes always true)
    refine_idx: []i32, // size k; index into refine_list, -1 if not refined
    refine_list: []u32, // symbol ids: 256 bytes then up to candidate_cap rules (by g desc)
    pred_maps: []std.AutoHashMapUnmanaged(u32, u32), // per refine idx: raw predecessor token -> count (self excluded)
    succ_maps: []std.AutoHashMapUnmanaged(u32, u32), // per refine idx: raw successor token -> count (self excluded)
    self_count: []u64, // per refine idx
    G_final: []u64, // size C, last sweep's snapshot
    logT_final: []f64, // size (C+1)*C, last sweep's snapshot
    learn_ms: f64,

    fn deinit(self: *LearnState, alloc: std.mem.Allocator) void {
        alloc.free(self.learned_b);
        alloc.free(self.learned_a);
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

/// Build the per-sweep provisional class arrays (size k) for every symbol:
/// refine candidates use their own evolving learned class; everything else
/// follows simple byte-of-first/last-byte inheritance from the CURRENT byte
/// classes (this is the "rarer tokens follow inheritance during learning"
/// rule from PLAN, applied to the base case only -- true DAG cascading
/// through committed overrides only happens in the post-learning topo pass).
fn buildProvisional(dump: *const kc.Dump, info: []const kc.SymInfo, is_candidate: []const bool, learned_b: []const u32, learned_a: []const u32, prov_b: []u32, prov_a: []u32) void {
    for (0..256) |i| {
        prov_b[i] = learned_b[i];
        prov_a[i] = learned_a[i];
    }
    for (256..dump.k) |id| {
        if (is_candidate[id]) {
            prov_b[id] = learned_b[id];
            prov_a[id] = learned_a[id];
        } else {
            prov_b[id] = prov_b[info[id].first1];
            prov_a[id] = prov_a[info[id].last1];
        }
    }
}

fn evalCost(C: u32, logT: []const f64, G: []const u64, pred_hist: ?[]const u64, succ_hist: ?[]const u64, self_count: u64, g_x: u64, cur: u32, c: u32, use_unigram: bool) f64 {
    var cost: f64 = 0;
    if (pred_hist) |ph| {
        for (0..C + 1) |p| {
            const w = ph[p];
            if (w == 0) continue;
            cost -= f(w) * logT[p * C + c];
        }
    }
    if (succ_hist) |sh| {
        for (0..C) |s| {
            const w = sh[s];
            if (w == 0) continue;
            cost -= f(w) * logT[c * C + s];
        }
    }
    if (self_count > 0) cost -= f(self_count) * logT[c * C + c];
    if (use_unigram) {
        const extra: f64 = if (c != cur) f(g_x) else 0.0;
        const denom = f(G[c]) + extra + SMOOTH;
        cost += f(g_x) * log2s(denom);
    }
    return cost;
}

fn learnClasses(alloc: std.mem.Allocator, io: std.Io, dump: *const kc.Dump, info: []const kc.SymInfo, g: []const u64, params: Params) !LearnState {
    const timer = kc.Timer.start(io);
    const C = params.C;
    const k = dump.k;

    const is_candidate = try alloc.alloc(bool, k);
    for (0..256) |i| is_candidate[i] = true;
    for (256..k) |id| is_candidate[id] = g[id] >= params.g_min;

    // Rank rule candidates by g descending, cap the refine set.
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
    const learned_b = try alloc.alloc(u32, k);
    const learned_a = try alloc.alloc(u32, k);
    @memset(learned_b, 0);
    @memset(learned_a, 0);

    const byte_init = initByteRankClasses(C, g);
    for (0..256) |i| {
        learned_b[i] = byte_init[i];
        learned_a[i] = byte_init[i];
    }
    for (0..refine_rule_n) |i| {
        const id = rule_cands.items[i];
        learned_b[id] = byte_init[info[id].first1];
        learned_a[id] = byte_init[info[id].last1];
    }

    // Raw predecessor/successor token adjacency for refine candidates only
    // (self-adjacency excluded and tracked separately -- see LANE_K.md for
    // why: in one-map mode a self-transition touches both the row and the
    // column of the SAME move simultaneously and must not be double counted).
    const pred_maps = try alloc.alloc(std.AutoHashMapUnmanaged(u32, u32), n_refine);
    const succ_maps = try alloc.alloc(std.AutoHashMapUnmanaged(u32, u32), n_refine);
    for (pred_maps) |*m| m.* = .{};
    for (succ_maps) |*m| m.* = .{};
    const self_count = try alloc.alloc(u64, n_refine);
    @memset(self_count, 0);

    for (dump.blocks) |blk| {
        var prev: u32 = START_SENTINEL;
        for (blk) |s| {
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
    const next_b = try alloc.alloc(u32, n_refine);
    defer alloc.free(next_b);
    const next_a = try alloc.alloc(u32, n_refine);
    defer alloc.free(next_a);

    var sweep: u32 = 0;
    while (sweep < params.sweeps) : (sweep += 1) {
        buildProvisional(dump, info, is_candidate, learned_b, learned_a, prov_b, prov_a);

        @memset(N, 0);
        for (dump.blocks) |blk| {
            var ctx: u32 = C; // START row
            for (blk) |s| {
                N[ctx * C + prov_b[s]] += 1;
                ctx = prov_a[s];
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
            while (it_s.next()) |e| {
                succ_hist[prov_b[e.key_ptr.*]] += e.value_ptr.*;
            }
            const gx = g[x];

            if (params.two_maps) {
                const cur_a = prov_a[x];
                const cur_b = prov_b[x];
                pred_hist[cur_a] += self_count[idx];
                succ_hist[cur_b] += self_count[idx];

                var best_c: u32 = cur_b;
                var best_cost = evalCost(C, logT, G, pred_hist, null, 0, gx, cur_b, cur_b, true);
                for (0..C) |cc| {
                    const c: u32 = @intCast(cc);
                    if (c == cur_b) continue;
                    const cost = evalCost(C, logT, G, pred_hist, null, 0, gx, cur_b, c, true);
                    if (cost < best_cost) {
                        best_cost = cost;
                        best_c = c;
                    }
                }
                next_b[idx] = best_c;

                var best_ca: u32 = cur_a;
                var best_costa = evalCost(C, logT, G, null, succ_hist, 0, 0, 0, cur_a, false);
                for (0..C) |cc| {
                    const c: u32 = @intCast(cc);
                    if (c == cur_a) continue;
                    const cost = evalCost(C, logT, G, null, succ_hist, 0, 0, 0, c, false);
                    if (cost < best_costa) {
                        best_costa = cost;
                        best_ca = c;
                    }
                }
                next_a[idx] = best_ca;
            } else {
                const cur = prov_b[x]; // == prov_a[x]
                var best_c: u32 = cur;
                var best_cost = evalCost(C, logT, G, pred_hist, succ_hist, self_count[idx], gx, cur, cur, true);
                for (0..C) |cc| {
                    const c: u32 = @intCast(cc);
                    if (c == cur) continue;
                    const cost = evalCost(C, logT, G, pred_hist, succ_hist, self_count[idx], gx, cur, c, true);
                    if (cost < best_cost) {
                        best_cost = cost;
                        best_c = c;
                    }
                }
                next_b[idx] = best_c;
                next_a[idx] = best_c;
            }
        }
        for (refine_list, 0..) |x, idx| {
            learned_b[x] = next_b[idx];
            learned_a[x] = next_a[idx];
        }
    }

    // Final snapshot (used by the override-savings estimate).
    buildProvisional(dump, info, is_candidate, learned_b, learned_a, prov_b, prov_a);
    @memset(N, 0);
    for (dump.blocks) |blk| {
        var ctx: u32 = C;
        for (blk) |s| {
            N[ctx * C + prov_b[s]] += 1;
            ctx = prov_a[s];
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
        .learned_b = learned_b,
        .learned_a = learned_a,
        .is_candidate = is_candidate,
        .refine_idx = refine_idx,
        .refine_list = refine_list,
        .pred_maps = pred_maps,
        .succ_maps = succ_maps,
        .self_count = self_count,
        .G_final = G,
        .logT_final = logT,
        .learn_ms = @as(f64, @floatFromInt(timer.read())) / 1e6,
    };
}

// -------------------------------------------------------------- model --

pub const Model = struct {
    C: u32,
    two_maps: bool,
    inherit: bool,
    default_b: u32,
    default_a: u32,
    resolved_b: []u32,
    resolved_a: []u32,
    byte_class_b: [256]u32,
    byte_class_a: [256]u32,
    override_b_ids: []u32,
    override_b_classes: []u32,
    override_a_ids: []u32,
    override_a_classes: []u32,
    T: []u32, // (C+1)*C real integer counts

    pub fn deinit(self: *Model, alloc: std.mem.Allocator) void {
        alloc.free(self.resolved_b);
        alloc.free(self.resolved_a);
        alloc.free(self.override_b_ids);
        alloc.free(self.override_b_classes);
        alloc.free(self.override_a_ids);
        alloc.free(self.override_a_classes);
        alloc.free(self.T);
    }
};

/// Resolve every symbol's b/a class from the transmitted model: bytes from
/// the explicit table; rules either recursively from their leftmost/
/// rightmost child (inherit mode) or from a flat transmitted default
/// (no-inherit ablation), unless an override says otherwise. Used both
/// encoder-side (to build the model) and decoder-side (to reconstruct it
/// from decoded bytes only) -- same function, so a real decode genuinely
/// exercises the same logic.
fn resolveFromOverrides(alloc: std.mem.Allocator, dump: *const kc.Dump, order: []const u32, byte_class_b: [256]u32, byte_class_a: [256]u32, override_b: std.AutoHashMapUnmanaged(u32, u32), override_a: std.AutoHashMapUnmanaged(u32, u32), inherit: bool, default_b: u32, default_a: u32) !struct { b: []u32, a: []u32 } {
    const k = dump.k;
    const resolved_b = try alloc.alloc(u32, k);
    const resolved_a = try alloc.alloc(u32, k);
    for (0..256) |i| {
        resolved_b[i] = byte_class_b[i];
        resolved_a[i] = byte_class_a[i];
    }
    if (inherit) {
        for (order) |id| {
            if (id < 256) continue;
            const kids = dump.children[id - 256];
            const inh_b = resolved_b[kids[0]];
            const inh_a = resolved_a[kids[kids.len - 1]];
            resolved_b[id] = override_b.get(id) orelse inh_b;
            resolved_a[id] = override_a.get(id) orelse inh_a;
        }
    } else {
        for (256..k) |id| {
            resolved_b[id] = override_b.get(@intCast(id)) orelse default_b;
            resolved_a[id] = override_a.get(@intCast(id)) orelse default_a;
        }
    }
    return .{ .b = resolved_b, .a = resolved_a };
}

fn finalize(alloc: std.mem.Allocator, dump: *const kc.Dump, order: []const u32, info: []const kc.SymInfo, g: []const u64, params: Params, ls: *const LearnState) !Model {
    _ = info;
    const C = params.C;
    const k = dump.k;
    var byte_class_b: [256]u32 = undefined;
    var byte_class_a: [256]u32 = undefined;
    for (0..256) |i| {
        byte_class_b[i] = ls.learned_b[i];
        byte_class_a[i] = if (params.two_maps) ls.learned_a[i] else ls.learned_b[i];
    }

    var override_b: std.AutoHashMapUnmanaged(u32, u32) = .{};
    defer override_b.deinit(alloc);
    var override_a: std.AutoHashMapUnmanaged(u32, u32) = .{};
    defer override_a.deinit(alloc);

    var default_b: u32 = 0;
    {
        var best: u64 = 0;
        for (0..C) |c| {
            if (ls.G_final[c] > best) {
                best = ls.G_final[c];
                default_b = @intCast(c);
            }
        }
    }

    var default_a: u32 = default_b;
    if (params.two_maps) {
        // a-map has no G[]-style unigram target, so just reuse the b-map's
        // busiest class as a reasonable flat default for the ablation.
        default_a = default_b;
    }

    if (!params.inherit) {
        // Ablation: every g>=g_min token gets an explicit class unconditionally;
        // everything else shares one flat default class (no DAG default).
        for (256..k) |id| {
            if (ls.is_candidate[id]) {
                try override_b.put(alloc, @intCast(id), ls.learned_b[id]);
                if (params.two_maps) try override_a.put(alloc, @intCast(id), ls.learned_a[id]);
            }
        }
    } else {
        // Inheritance mode: topological pass, children resolved before
        // parents, deciding overrides by an estimated real-bit-savings test.
        const tmp_resolved_b = try alloc.alloc(u32, k);
        defer alloc.free(tmp_resolved_b);
        const tmp_resolved_a = try alloc.alloc(u32, k);
        defer alloc.free(tmp_resolved_a);
        for (0..256) |i| {
            tmp_resolved_b[i] = byte_class_b[i];
            tmp_resolved_a[i] = byte_class_a[i];
        }
        const pred_hist = try alloc.alloc(u64, C + 1);
        defer alloc.free(pred_hist);
        const succ_hist = try alloc.alloc(u64, C);
        defer alloc.free(succ_hist);

        for (order) |id| {
            if (id < 256) continue;
            const kids = dump.children[id - 256];
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
                const p_class: u32 = if (e.key_ptr.* == START_SENTINEL) C else ls.learned_a[e.key_ptr.*];
                pred_hist[p_class] += e.value_ptr.*;
            }
            var it_s = ls.succ_maps[idx].iterator();
            while (it_s.next()) |e| {
                succ_hist[ls.learned_b[e.key_ptr.*]] += e.value_ptr.*;
            }
            const gx = g[id];
            const lb = ls.learned_b[id];
            const la = ls.learned_a[id];

            if (params.two_maps) {
                tmp_resolved_b[id] = inh_b;
                if (lb != inh_b) {
                    pred_hist[la] += ls.self_count[idx];
                    const cost_inh = evalCost(C, ls.logT_final, ls.G_final, pred_hist, null, 0, gx, lb, inh_b, true);
                    const cost_learn = evalCost(C, ls.logT_final, ls.G_final, pred_hist, null, 0, gx, lb, lb, true);
                    if (cost_inh - cost_learn > OVERRIDE_COST_BITS) {
                        tmp_resolved_b[id] = lb;
                        try override_b.put(alloc, @intCast(id), lb);
                    }
                }
                tmp_resolved_a[id] = inh_a;
                if (la != inh_a) {
                    succ_hist[lb] += ls.self_count[idx];
                    const cost_inh = evalCost(C, ls.logT_final, ls.G_final, null, succ_hist, 0, 0, 0, inh_a, false);
                    const cost_learn = evalCost(C, ls.logT_final, ls.G_final, null, succ_hist, 0, 0, 0, la, false);
                    if (cost_inh - cost_learn > OVERRIDE_COST_BITS) {
                        tmp_resolved_a[id] = la;
                        try override_a.put(alloc, @intCast(id), la);
                    }
                }
            } else {
                tmp_resolved_b[id] = inh_b;
                tmp_resolved_a[id] = inh_a;
                if (lb != inh_b or la != inh_a) {
                    const cost_no = combinedCost(C, ls.logT_final, ls.G_final, pred_hist, succ_hist, ls.self_count[idx], gx, inh_b, inh_a, lb);
                    const cost_ov = combinedCost(C, ls.logT_final, ls.G_final, pred_hist, succ_hist, ls.self_count[idx], gx, lb, lb, lb);
                    if (cost_no - cost_ov > OVERRIDE_COST_BITS) {
                        tmp_resolved_b[id] = lb;
                        tmp_resolved_a[id] = lb;
                        try override_b.put(alloc, @intCast(id), lb);
                    }
                }
            }
        }
    }

    // Canonical resolution from the committed override set alone -- the
    // exact same function a real decoder uses, so encoder and decoder can
    // never disagree about what "default" means.
    // One-map mode stores a single override list that sets BOTH roles at
    // once (see LANE_K.md); mirror it into the a-role lookup so this
    // encoder-side resolution matches what a real decoder reconstructs.
    const eff_override_a = if (params.two_maps) override_a else override_b;
    const resolved = try resolveFromOverrides(alloc, dump, order, byte_class_b, byte_class_a, override_b, eff_override_a, params.inherit, default_b, default_a);
    const T = try fitT(alloc, dump, C, resolved.b, resolved.a);
    return .{
        .C = C,
        .two_maps = params.two_maps,
        .inherit = params.inherit,
        .default_b = default_b,
        .default_a = default_a,
        .resolved_b = resolved.b,
        .resolved_a = resolved.a,
        .byte_class_b = byte_class_b,
        .byte_class_a = byte_class_a,
        .override_b_ids = try dumpKeys(alloc, override_b),
        .override_b_classes = try dumpVals(alloc, override_b),
        .override_a_ids = try dumpKeys(alloc, override_a),
        .override_a_classes = try dumpVals(alloc, override_a),
        .T = T,
    };
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

fn dumpKeys(alloc: std.mem.Allocator, m: std.AutoHashMapUnmanaged(u32, u32)) ![]u32 {
    var list: std.ArrayList(u32) = .empty;
    var it = m.iterator();
    while (it.next()) |e| try list.append(alloc, e.key_ptr.*);
    std.mem.sort(u32, list.items, {}, std.sort.asc(u32));
    return list.toOwnedSlice(alloc);
}
fn dumpVals(alloc: std.mem.Allocator, m: std.AutoHashMapUnmanaged(u32, u32)) ![]u32 {
    // classes aligned to the SORTED id order produced by dumpKeys -- recompute here.
    var list: std.ArrayList(u32) = .empty;
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(alloc);
    var it = m.iterator();
    while (it.next()) |e| try ids.append(alloc, e.key_ptr.*);
    std.mem.sort(u32, ids.items, {}, std.sort.asc(u32));
    for (ids.items) |id| try list.append(alloc, m.get(id).?);
    return list.toOwnedSlice(alloc);
}

fn fitT(alloc: std.mem.Allocator, dump: *const kc.Dump, C: u32, resolved_b: []const u32, resolved_a: []const u32) ![]u32 {
    const T = try alloc.alloc(u32, (C + 1) * C);
    @memset(T, 0);
    for (dump.blocks) |blk| {
        var ctx: u32 = C;
        for (blk) |s| {
            T[ctx * C + resolved_b[s]] += 1;
            ctx = resolved_a[s];
        }
    }
    return T;
}

// --------------------------------------------------------- model bytes --

fn rowTotal(T: []const u32, C: u32, row: u32) u32 {
    var s: u32 = 0;
    for (0..C) |c| s += T[row * C + c];
    return s;
}
fn rowEncode(T: []const u32, C: u32, row: u32, enc: *rc.Encoder, target: u32) !void {
    var cum: u32 = 0;
    for (0..target) |c| cum += T[row * C + c];
    try enc.encodeFreq(cum, T[row * C + target], rowTotal(T, C, row));
}
fn rowDecode(T: []const u32, C: u32, row: u32, dec: *rc.Decoder) u32 {
    const tot = rowTotal(T, C, row);
    const v = dec.decodeFreq(tot);
    var cum: u32 = 0;
    var i: usize = 0;
    while (true) : (i += 1) {
        const cc = T[row * C + i];
        if (v < cum + cc) break;
        cum += cc;
    }
    dec.consume(cum, T[row * C + i]);
    return @intCast(i);
}

fn encodeTableBytes(alloc: std.mem.Allocator, model: *const Model) ![]const u8 {
    var enc = rc.Encoder.init(alloc);
    defer enc.deinit();
    const bits = kc.bitsFor(model.C);
    try enc.encodeDirect(@intFromBool(model.inherit), 1);
    try enc.encodeDirect(model.default_b, bits);
    try enc.encodeDirect(model.default_a, bits);
    for (0..256) |i| try enc.encodeDirect(model.byte_class_b[i], bits);
    if (model.two_maps) {
        for (0..256) |i| try enc.encodeDirect(model.byte_class_a[i], bits);
    }
    var tctx = kc.GammaCtx{};
    for (model.T) |v| try kc.gammaEncode(&enc, &tctx, v);
    const bytes = try enc.finish();
    return try alloc.dupe(u8, bytes);
}

const DecodedTable = struct {
    inherit: bool,
    default_b: u32,
    default_a: u32,
    byte_class_b: [256]u32,
    byte_class_a: [256]u32,
    T: []u32,
};

fn decodeTableBytes(alloc: std.mem.Allocator, bytes: []const u8, C: u32, two_maps: bool) !DecodedTable {
    var dec = rc.Decoder.init(bytes);
    const bits = kc.bitsFor(C);
    const inherit = dec.decodeDirect(1) == 1;
    const default_b = dec.decodeDirect(bits);
    const default_a = dec.decodeDirect(bits);
    var byte_class_b: [256]u32 = undefined;
    var byte_class_a: [256]u32 = undefined;
    for (0..256) |i| byte_class_b[i] = dec.decodeDirect(bits);
    if (two_maps) {
        for (0..256) |i| byte_class_a[i] = dec.decodeDirect(bits);
    } else {
        byte_class_a = byte_class_b;
    }
    const T = try alloc.alloc(u32, (C + 1) * C);
    var tctx = kc.GammaCtx{};
    for (T) |*v| v.* = kc.gammaDecode(&dec, &tctx);
    return .{ .inherit = inherit, .default_b = default_b, .default_a = default_a, .byte_class_b = byte_class_b, .byte_class_a = byte_class_a, .T = T };
}

fn encodeOverrideList(enc: *rc.Encoder, ids: []const u32, classes: []const u32, bits: u6) !void {
    try enc.encodeDirect(@intCast(ids.len), 24);
    var gctx = kc.GammaCtx{};
    var prev: u32 = 0;
    for (ids, classes) |id, cls| {
        const idx0 = id - 256; // rule-index space
        const gap = idx0 - prev;
        try kc.gammaEncode(enc, &gctx, gap);
        try enc.encodeDirect(cls, bits);
        prev = idx0 + 1;
    }
}

fn decodeOverrideList(alloc: std.mem.Allocator, dec: *rc.Decoder, bits: u6) !struct { ids: []u32, classes: []u32 } {
    const n = dec.decodeDirect(24);
    const ids = try alloc.alloc(u32, n);
    const classes = try alloc.alloc(u32, n);
    var gctx = kc.GammaCtx{};
    var prev: u32 = 0;
    for (0..n) |i| {
        const gap = kc.gammaDecode(dec, &gctx);
        const idx0 = prev + gap;
        ids[i] = idx0 + 256;
        classes[i] = dec.decodeDirect(bits);
        prev = idx0 + 1;
    }
    return .{ .ids = ids, .classes = classes };
}

fn encodeOverrideBytes(alloc: std.mem.Allocator, model: *const Model) ![]const u8 {
    var enc = rc.Encoder.init(alloc);
    defer enc.deinit();
    const bits = kc.bitsFor(model.C);
    try encodeOverrideList(&enc, model.override_b_ids, model.override_b_classes, bits);
    if (model.two_maps) try encodeOverrideList(&enc, model.override_a_ids, model.override_a_classes, bits);
    const bytes = try enc.finish();
    return try alloc.dupe(u8, bytes);
}

const DecodedOverrides = struct {
    b_ids: []u32,
    b_classes: []u32,
    a_ids: []u32,
    a_classes: []u32,
};

fn decodeOverrideBytes(alloc: std.mem.Allocator, bytes: []const u8, C: u32, two_maps: bool) !DecodedOverrides {
    var dec = rc.Decoder.init(bytes);
    const bits = kc.bitsFor(C);
    const bl = try decodeOverrideList(alloc, &dec, bits);
    if (two_maps) {
        const al = try decodeOverrideList(alloc, &dec, bits);
        return .{ .b_ids = bl.ids, .b_classes = bl.classes, .a_ids = al.ids, .a_classes = al.classes };
    }
    return .{ .b_ids = bl.ids, .b_classes = bl.classes, .a_ids = &.{}, .a_classes = &.{} };
}

fn mapFromLists(alloc: std.mem.Allocator, ids: []const u32, classes: []const u32) !std.AutoHashMapUnmanaged(u32, u32) {
    var m: std.AutoHashMapUnmanaged(u32, u32) = .{};
    for (ids, classes) |id, cls| try m.put(alloc, id, cls);
    return m;
}

// ------------------------------------------------------------ pipeline --

pub const BuiltModel = struct {
    model: Model,
    learn_ms: f64,
    num_refined: usize,
};

/// Learn + resolve a model without doing the (expensive, if you just want
/// the class listing) real per-block encode/decode. Caller owns `.model`.
pub fn buildModel(alloc: std.mem.Allocator, io: std.Io, dump: *const kc.Dump, order: []const u32, info: []const kc.SymInfo, g: []const u64, params: Params) !BuiltModel {
    var ls = try learnClasses(alloc, io, dump, info, g, params);
    defer ls.deinit(alloc);
    const model = try finalize(alloc, dump, order, info, g, params, &ls);
    return .{ .model = model, .learn_ms = ls.learn_ms, .num_refined = ls.refine_list.len };
}

pub fn run(alloc: std.mem.Allocator, io: std.Io, dump: *const kc.Dump, order: []const u32, info: []const kc.SymInfo, g: []const u64, params: Params) !Result {
    const built = try buildModel(alloc, io, dump, order, info, g, params);
    var model = built.model;
    defer model.deinit(alloc);

    const table_bytes = try encodeTableBytes(alloc, &model);
    defer alloc.free(table_bytes);
    const override_bytes = try encodeOverrideBytes(alloc, &model);
    defer alloc.free(override_bytes);

    // Genuine round trip of the model bytes (not the encoder's live arrays).
    const dtab = try decodeTableBytes(alloc, table_bytes, model.C, model.two_maps);
    defer alloc.free(dtab.T);
    const dov = try decodeOverrideBytes(alloc, override_bytes, model.C, model.two_maps);
    defer alloc.free(dov.b_ids);
    defer alloc.free(dov.b_classes);
    defer alloc.free(dov.a_ids);
    defer alloc.free(dov.a_classes);

    var ov_b_map = try mapFromLists(alloc, dov.b_ids, dov.b_classes);
    defer ov_b_map.deinit(alloc);
    var ov_a_map: std.AutoHashMapUnmanaged(u32, u32) = .{};
    defer ov_a_map.deinit(alloc);
    if (model.two_maps) {
        ov_a_map = try mapFromLists(alloc, dov.a_ids, dov.a_classes);
    } else {
        ov_a_map = try mapFromLists(alloc, dov.b_ids, dov.b_classes);
    }

    const decoded_resolved = try resolveFromOverrides(alloc, dump, order, dtab.byte_class_b, dtab.byte_class_a, ov_b_map, ov_a_map, dtab.inherit, dtab.default_b, dtab.default_a);
    defer alloc.free(decoded_resolved.b);
    defer alloc.free(decoded_resolved.a);

    // Sanity: decoder-side resolution must match encoder-side exactly.
    for (0..dump.k) |i| {
        if (decoded_resolved.b[i] != model.resolved_b[i]) return error.ModelMismatchB;
        if (decoded_resolved.a[i] != model.resolved_a[i]) return error.ModelMismatchA;
    }

    // Per-class bucket for within-class coding (ordered by id via buildBuckets).
    var bs_enc = try kc.buildBuckets(alloc, model.C, dump.k, model.resolved_b, g);
    defer bs_enc.deinit();
    var bs_dec = try kc.buildBuckets(alloc, model.C, dump.k, decoded_resolved.b, g);
    defer bs_dec.deinit();

    var payload_class: usize = 0;
    var decode_ns: u64 = 0;
    var tokens: usize = 0;
    for (dump.blocks, 0..) |blk, bidx| {
        var enc = rc.Encoder.init(alloc);
        var ctx: u32 = model.C;
        for (blk) |s| {
            try rowEncode(model.T, model.C, ctx, &enc, model.resolved_b[s]);
            try kc.bsEncodeSym(&bs_enc, &enc, model.resolved_b[s], s);
            ctx = model.resolved_a[s];
        }
        const bytes = try enc.finish();
        const owned = try alloc.dupe(u8, bytes);
        enc.deinit();
        defer alloc.free(owned);
        payload_class += owned.len;
        tokens += blk.len;

        const timer = kc.Timer.start(io);
        var dec = rc.Decoder.init(owned);
        var ctxd: u32 = model.C;
        var acc: u64 = 0;
        const target = dump.blockRawLen(bidx);
        var i: usize = 0;
        while (acc < target) : (i += 1) {
            const cls = rowDecode(dtab.T, model.C, ctxd, &dec);
            const s = kc.bsDecodeSym(&bs_dec, &dec, cls);
            if (s != blk[i]) return error.RootMismatch;
            acc += info[s].len;
            ctxd = decoded_resolved.a[s];
        }
        decode_ns += timer.read();
        if (acc != target or i != blk.len) return error.LengthMismatch;
    }

    const payload_x0 = try runX0(alloc, io, dump, info, g);
    const net_total = payload_class + table_bytes.len + override_bytes.len;
    const pct = if (payload_x0 == 0) 0.0 else (f(payload_x0) - f(net_total)) / f(payload_x0) * 100.0;

    return .{
        .tokens = tokens,
        .payload_x0 = payload_x0,
        .payload_class = payload_class,
        .table_bytes = table_bytes.len,
        .override_bytes = override_bytes.len,
        .net_total = net_total,
        .pct_vs_x0 = pct,
        .learn_ms = built.learn_ms,
        .decode_ns_per_token = if (tokens == 0) 0 else f(decode_ns) / f(tokens),
        .num_overrides_b = model.override_b_ids.len,
        .num_overrides_a = model.override_a_ids.len,
        .num_refined = built.num_refined,
    };
}

// -------------------------------------------------- order-2 (exploratory) --
// T2[a(x_{i-2})][a(x_{i-1})][b(x_i)]: reuses the SAME learned/resolved
// classes as the order-1 model (b/a maps are not re-learned with an order-2
// objective -- see LANE_K.md), just fits and codes a richer static context
// table. Row index = ctx2*(C+1) + ctx1, both in 0..C (C == START). Meant for
// small C only (the table is (C+1)^2 * C cells).

fn fitT2(alloc: std.mem.Allocator, dump: *const kc.Dump, C: u32, resolved_b: []const u32, resolved_a: []const u32) ![]u32 {
    const rows = (C + 1) * (C + 1);
    const T = try alloc.alloc(u32, rows * C);
    @memset(T, 0);
    for (dump.blocks) |blk| {
        var ctx2: u32 = C;
        var ctx1: u32 = C;
        for (blk) |s| {
            const row = ctx2 * (C + 1) + ctx1;
            T[row * C + resolved_b[s]] += 1;
            ctx2 = ctx1;
            ctx1 = resolved_a[s];
        }
    }
    return T;
}

pub fn runOrder2(alloc: std.mem.Allocator, io: std.Io, dump: *const kc.Dump, order: []const u32, info: []const kc.SymInfo, g: []const u64, params: Params) !Result {
    const built = try buildModel(alloc, io, dump, order, info, g, params);
    var model = built.model;
    defer model.deinit(alloc);
    const C = model.C;

    const T2 = try fitT2(alloc, dump, C, model.resolved_b, model.resolved_a);
    defer alloc.free(T2);

    var enc_tab = rc.Encoder.init(alloc);
    defer enc_tab.deinit();
    const bits = kc.bitsFor(C);
    for (0..256) |i| try enc_tab.encodeDirect(model.byte_class_b[i], bits);
    if (model.two_maps) for (0..256) |i| try enc_tab.encodeDirect(model.byte_class_a[i], bits);
    var tctx = kc.GammaCtx{};
    for (T2) |v| try kc.gammaEncode(&enc_tab, &tctx, v);
    const table_bytes = try enc_tab.finish();

    const override_bytes = try encodeOverrideBytes(alloc, &model);
    defer alloc.free(override_bytes);

    var bs = try kc.buildBuckets(alloc, C, dump.k, model.resolved_b, g);
    defer bs.deinit();

    var payload_class: usize = 0;
    var decode_ns: u64 = 0;
    var tokens: usize = 0;
    for (dump.blocks, 0..) |blk, bidx| {
        var enc = rc.Encoder.init(alloc);
        var ctx2: u32 = C;
        var ctx1: u32 = C;
        for (blk) |s| {
            const row = ctx2 * (C + 1) + ctx1;
            try rowEncode(T2, C, row, &enc, model.resolved_b[s]);
            try kc.bsEncodeSym(&bs, &enc, model.resolved_b[s], s);
            ctx2 = ctx1;
            ctx1 = model.resolved_a[s];
        }
        const bytes = try enc.finish();
        const owned = try alloc.dupe(u8, bytes);
        enc.deinit();
        defer alloc.free(owned);
        payload_class += owned.len;
        tokens += blk.len;

        const timer = kc.Timer.start(io);
        var dec = rc.Decoder.init(owned);
        var ctxd2: u32 = C;
        var ctxd1: u32 = C;
        var acc: u64 = 0;
        const target = dump.blockRawLen(bidx);
        var i: usize = 0;
        while (acc < target) : (i += 1) {
            const row = ctxd2 * (C + 1) + ctxd1;
            const cls = rowDecode(T2, C, row, &dec);
            const s = kc.bsDecodeSym(&bs, &dec, cls);
            if (s != blk[i]) return error.RootMismatch;
            acc += info[s].len;
            ctxd2 = ctxd1;
            ctxd1 = model.resolved_a[s];
        }
        decode_ns += timer.read();
        if (acc != target or i != blk.len) return error.LengthMismatch;
    }

    const payload_x0 = try runX0(alloc, io, dump, info, g);
    const net_total = payload_class + table_bytes.len + override_bytes.len;
    const pct = if (payload_x0 == 0) 0.0 else (f(payload_x0) - f(net_total)) / f(payload_x0) * 100.0;
    return .{
        .tokens = tokens,
        .payload_x0 = payload_x0,
        .payload_class = payload_class,
        .table_bytes = table_bytes.len,
        .override_bytes = override_bytes.len,
        .net_total = net_total,
        .pct_vs_x0 = pct,
        .learn_ms = built.learn_ms,
        .decode_ns_per_token = if (tokens == 0) 0 else f(decode_ns) / f(tokens),
        .num_overrides_b = model.override_b_ids.len,
        .num_overrides_a = model.override_a_ids.len,
        .num_refined = built.num_refined,
    };
}

// --------------------------------------------------------- class listing --

pub const ClassSample = struct {
    class_id: u32,
    total_g: u64,
    n_members: usize,
    top: [10]struct { sym: u32, g: u64 } = undefined,
    n_top: usize = 0,
};

/// For the biggest `n_classes` classes (by total g), the top `n_top` most
/// frequent member tokens -- used to print the "are the classes meaningful"
/// listing into LANE_K.md. Caller owns the returned slice.
pub fn biggestClasses(alloc: std.mem.Allocator, dump: *const kc.Dump, resolved_b: []const u32, g: []const u64, n_classes: usize, C: u32) ![]ClassSample {
    const total_g = try alloc.alloc(u64, C);
    defer alloc.free(total_g);
    @memset(total_g, 0);
    for (0..dump.k) |s| total_g[resolved_b[s]] += g[s];

    var order = try alloc.alloc(u32, C);
    defer alloc.free(order);
    for (0..C) |c| order[c] = @intCast(c);
    const Ctx = struct {
        w: []const u64,
        fn lessThan(self: @This(), a: u32, b: u32) bool {
            return self.w[a] > self.w[b];
        }
    };
    std.mem.sort(u32, order, Ctx{ .w = total_g }, Ctx.lessThan);

    const n = @min(n_classes, C);
    const out = try alloc.alloc(ClassSample, n);
    for (order[0..n], 0..) |c, oi| {
        var members: std.ArrayList(struct { sym: u32, g: u64 }) = .empty;
        defer members.deinit(alloc);
        for (0..dump.k) |s| {
            if (resolved_b[s] == c and g[s] > 0) try members.append(alloc, .{ .sym = @intCast(s), .g = g[s] });
        }
        const MCtx = struct {
            fn lessThan(_: void, a: @TypeOf(members.items[0]), b: @TypeOf(members.items[0])) bool {
                return a.g > b.g;
            }
        };
        std.mem.sort(@TypeOf(members.items[0]), members.items, {}, MCtx.lessThan);
        var sample: ClassSample = .{ .class_id = c, .total_g = total_g[c], .n_members = members.items.len };
        const ntop = @min(@as(usize, 10), members.items.len);
        for (0..ntop) |i| sample.top[i] = .{ .sym = members.items[i].sym, .g = members.items[i].g };
        sample.n_top = ntop;
        out[oi] = sample;
    }
    return out;
}
