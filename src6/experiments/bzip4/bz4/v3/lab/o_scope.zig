//! Lane O: oracle est of what first-use-free definitions (V1) and scoped
//! (bursty) local definitions (V2) are worth, on top of a V0 (global,
//! stored-separately) reference. See v3/DESIGN.md and this lane's
//! v3/lab/LANE_O.md for the write-up; PLAN.md for the B4SD v1/v2 formats
//! and the rules of evidence (est only, everything charged, validated).
//!
//! This is an ORDER-0 ESTIMATE, not a real codec: every number here is
//! computed from event counts via -log2(p), never coded to actual bits.
//! Every dump is round-tripped against its data/*.bin before any number
//! from it is trusted (see `validate`).
//!
//! usage: o_scope [namefilter]   (namefilter: substring match on dump path)

const std = @import("std");

const MAGIC: u32 = 0x44533442; // "B4SD"
const MAXS: usize = 7; // lifetimes s = 0..6
var verbose: bool = false;

// --------------------------------------------------------------- B4SD I/O --

const Dump = struct {
    alloc: std.mem.Allocator,
    version: u32,
    children: [][]u32, // children[i] = child ids of entry i (symbol 256+i)
    child_store: []u32,
    blocks: [][]u32,
    block_bytes: u32,
    raw_len: u32,

    fn deinit(self: *Dump) void {
        for (self.blocks) |b| self.alloc.free(b);
        self.alloc.free(self.blocks);
        self.alloc.free(self.children);
        self.alloc.free(self.child_store);
    }

    fn nEntries(self: *const Dump) usize {
        return self.children.len;
    }
};

fn readU32(bytes: []const u8, off: *usize) u32 {
    const v = std.mem.readInt(u32, bytes[off.*..][0..4], .little);
    off.* += 4;
    return v;
}

fn readDump(alloc: std.mem.Allocator, bytes: []const u8) !Dump {
    var off: usize = 0;
    const magic = readU32(bytes, &off);
    if (magic != MAGIC) return error.BadMagic;
    const version = readU32(bytes, &off);
    if (version != 1 and version != 2) return error.BadVersion;
    const rule_count = readU32(bytes, &off);
    const block_count = readU32(bytes, &off);
    const block_bytes = readU32(bytes, &off);
    const raw_len = readU32(bytes, &off);

    const children = try alloc.alloc([]u32, rule_count);
    var total_arity: usize = 0;
    if (version == 1) {
        total_arity = @as(usize, rule_count) * 2;
    } else {
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
    for (blocks) |*blk| {
        const root_count = readU32(bytes, &off);
        const syms = try alloc.alloc(u32, root_count);
        for (syms) |*s| s.* = readU32(bytes, &off);
        blk.* = syms;
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
    };
}

// ---------------------------------------------------------- validation ----

const Expander = struct {
    alloc: std.mem.Allocator,
    dump: *const Dump,
    cache: []?[]u8,

    fn expandInto(self: *Expander, id: u32, out: *std.ArrayList(u8)) !void {
        if (id < 256) {
            try out.append(self.alloc, @intCast(id));
            return;
        }
        const i = id - 256;
        if (self.cache[i]) |c| {
            try out.appendSlice(self.alloc, c);
            return;
        }
        var buf: std.ArrayList(u8) = .empty;
        for (self.dump.children[i]) |ch| try self.expandInto(ch, &buf);
        const owned = try buf.toOwnedSlice(self.alloc);
        self.cache[i] = owned;
        try out.appendSlice(self.alloc, owned);
    }
};

/// Re-expand every block to bytes and compare against `raw`. Returns error
/// on any mismatch. This is the only place we touch the corpus bytes.
fn validate(alloc: std.mem.Allocator, dump: *const Dump, raw: []const u8) !void {
    const cache = try alloc.alloc(?[]u8, dump.nEntries());
    defer {
        for (cache) |c| if (c) |s| alloc.free(s);
        alloc.free(cache);
    }
    @memset(cache, null);
    var exp = Expander{ .alloc = alloc, .dump = dump, .cache = cache };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var start: usize = 0;
    for (dump.blocks) |blk| {
        out.clearRetainingCapacity();
        for (blk) |t| try exp.expandInto(t, &out);
        const end = @min(raw.len, start + dump.block_bytes);
        if (end < start or !std.mem.eql(u8, out.items, raw[start..end])) return error.MismatchedBlock;
        start = end;
    }
    if (start != raw.len and !(dump.blocks.len == 0 and raw.len == 0)) {
        // Allow the last block to be short; otherwise total must match raw_len.
        if (start != dump.raw_len) return error.LengthMismatch;
    }
}

// --------------------------------------------------------- expansion len --

fn explenAll(alloc: std.mem.Allocator, dump: *const Dump) ![]u32 {
    const cache = try alloc.alloc(u32, dump.nEntries());
    @memset(cache, 0);
    const Ctx = struct {
        dump: *const Dump,
        cache: []u32,
        fn len(self: *@This(), id: u32) u32 {
            if (id < 256) return 1;
            const i = id - 256;
            if (self.cache[i] != 0) return self.cache[i];
            var total: u32 = 0;
            for (self.dump.children[i]) |ch| total += self.len(ch);
            self.cache[i] = total;
            return total;
        }
    };
    var ctx = Ctx{ .dump = dump, .cache = cache };
    var i: u32 = 0;
    while (i < dump.nEntries()) : (i += 1) _ = ctx.len(256 + i);
    return cache;
}

// -------------------------------------------------------------- helpers --

fn clampP(p: f64) f64 {
    return @max(p, 1e-12);
}
fn bits(p: f64) f64 {
    return -std.math.log2(clampP(p));
}
fn floorLog2(n: u64) u32 {
    if (n == 0) return 0;
    return 63 - @clz(n);
}

// ------------------------------------------------------- text occurrences --
// n_x for V0/V1: one count per token occurrence in "text" = every block's
// stream plus every entry's body (each body counted once, however many
// times the entry itself is referenced).

const Counts = struct {
    byte_n: [256]u64,
    entry_n: []u64,
    n_total: u64,
};

fn countText(alloc: std.mem.Allocator, dump: *const Dump) !Counts {
    var byte_n: [256]u64 = [_]u64{0} ** 256;
    const entry_n = try alloc.alloc(u64, dump.nEntries());
    @memset(entry_n, 0);
    var n_total: u64 = 0;
    for (dump.blocks) |blk| {
        for (blk) |t| {
            if (t < 256) byte_n[t] += 1 else entry_n[t - 256] += 1;
            n_total += 1;
        }
    }
    for (dump.children) |cs| {
        for (cs) |t| {
            if (t < 256) byte_n[t] += 1 else entry_n[t - 256] += 1;
            n_total += 1;
        }
    }
    return .{ .byte_n = byte_n, .entry_n = entry_n, .n_total = n_total };
}

// ------------------------------------------------------------------- V0 ---
// Every entry global, stored separately: USE(x) per occurrence, +est 2 bits
// arity per entry (flat placeholder, not entropy coded).

fn v0Bits(c: *const Counts, n_entries: usize) f64 {
    const N: f64 = @floatFromInt(c.n_total);
    var b: f64 = 0;
    for (c.byte_n) |n| if (n > 0) {
        b += @as(f64, @floatFromInt(n)) * bits(@as(f64, @floatFromInt(n)) / N);
    };
    for (c.entry_n) |n| if (n > 0) {
        b += @as(f64, @floatFromInt(n)) * bits(@as(f64, @floatFromInt(n)) / N);
    };
    b += @as(f64, @floatFromInt(n_entries)) * 2.0;
    return b;
}

// ------------------------------------------------------------------- V1 ---
// First use free: one shared DEF event per entry (its first use), all other
// occurrences are USE(x). Arity + NAME(tier) entropy-coded per definition.

fn v1Bits(alloc: std.mem.Allocator, dump: *const Dump, c: *const Counts) !f64 {
    const N: f64 = @floatFromInt(c.n_total);
    var eprime: u64 = 0;
    var arity_hist: std.AutoHashMapUnmanaged(u32, u64) = .{};
    defer arity_hist.deinit(alloc);
    var tier_hist: std.AutoHashMapUnmanaged(u32, u64) = .{};
    defer tier_hist.deinit(alloc);

    for (c.entry_n, 0..) |n, i| {
        if (n == 0) continue;
        eprime += 1;
        const u = n - 1;
        const a: u32 = @intCast(dump.children[i].len);
        const gop_a = try arity_hist.getOrPut(alloc, a);
        if (!gop_a.found_existing) gop_a.value_ptr.* = 0;
        gop_a.value_ptr.* += 1;
        const tier = floorLog2(u + 1);
        const gop_t = try tier_hist.getOrPut(alloc, tier);
        if (!gop_t.found_existing) gop_t.value_ptr.* = 0;
        gop_t.value_ptr.* += 1;
    }
    const Ef: f64 = @floatFromInt(eprime);

    var b: f64 = 0;
    for (c.byte_n) |n| if (n > 0) {
        b += @as(f64, @floatFromInt(n)) * bits(@as(f64, @floatFromInt(n)) / N);
    };
    const def_p = @as(f64, @floatFromInt(eprime)) / N;
    for (c.entry_n, 0..) |n, i| {
        if (n == 0) continue;
        const u = n - 1;
        if (u > 0) b += @as(f64, @floatFromInt(u)) * bits(@as(f64, @floatFromInt(u)) / N);
        b += bits(def_p);
        const a: u32 = @intCast(dump.children[i].len);
        const ac: f64 = @floatFromInt(arity_hist.get(a).?);
        b += bits(ac / Ef);
        const tier = floorLog2(u + 1);
        const tc: f64 = @floatFromInt(tier_hist.get(tier).?);
        b += bits(tc / Ef);
    }
    return b;
}

// ------------------------------------------------------------------- V2 ---
// Scoped (bursty) definitions. See LANE_O.md for the derivation. Iterative:
// round 0 forces everyone global (bootstraps a price table); rounds 1..R
// let each entry pick argmin cost under the previous round's frozen prices,
// processed parents-before-children (decreasing expansion length) so that
// inlining updates children's occurrence counts before they are decided.

const ScopeKind = enum(u8) { unused, global, local, dissolve };
const EntryScope = struct { kind: ScopeKind = .unused, s: u8 = 0 };

const WinItem = struct { w: u32, c: u32, minb: u32 };
const ActiveItem = struct { idx: u32, c: u32 };
const Pending = struct { ck: u64, sjkey: u32, uses: u64 };
const Accum = struct { sum: f64 = 0, cnt: u64 = 0 };

const V2Result = struct {
    bytes: f64,
    frac_local: f64,
    mean_global_bits: f64,
    mean_local_bits: f64,
    n_global: usize,
    n_local: usize,
    n_dissolved: usize,
    n_local_by_s: [MAXS]usize,
    def_instances_global: u64,
    def_instances_local: u64,
};

const Price = struct {
    n_prev: f64,
    d_prev: f64,
    arity_prob: std.AutoHashMapUnmanaged(u32, f64),
    // Raw (damped) definition-instance counts per scope kind, not yet
    // normalised: normalised with add-1 smoothing at read time (`scopeP*`)
    // so an as-yet-unused lifetime has a small but finite NAME price instead
    // of -log2(0) -- otherwise no entry would ever be willing to pay the
    // first (very expensive) definition needed to bootstrap that lifetime's
    // empirical frequency, and the search can never discover it helps.
    scope_count_global: f64,
    scope_count_local: [MAXS]f64,
    avg_local_bits: [MAXS]f64,
    // Per (s, in-window count) average per-use bit cost, from the *exact*
    // rank each count achieved last round. This is what actually breaks the
    // "pooled average" tragedy-of-the-commons: a barely-qualifying count=2
    // entry and a count=50 bursty entry get very different real ranks (and
    // so very different real cost), and without this every candidate looks
    // equally attractive, so they rush a lifetime en masse and overshoot.
    count_price: std.AutoHashMapUnmanaged(u64, f64),
    n_scope_kinds: f64, // 1 (global) + |S| (+1 more if dissolve allowed)

    fn init(n_scope_kinds: f64) Price {
        return .{
            .n_prev = 1,
            .d_prev = 1,
            .arity_prob = .{},
            .scope_count_global = 0,
            .scope_count_local = [_]f64{0} ** MAXS,
            .avg_local_bits = [_]f64{6.0} ** MAXS,
            .count_price = .{},
            .n_scope_kinds = n_scope_kinds,
        };
    }
    fn deinit(self: *Price, alloc: std.mem.Allocator) void {
        self.arity_prob.deinit(alloc);
        self.count_price.deinit(alloc);
    }
    fn arityP(self: *const Price, a: u32) f64 {
        return clampP(self.arity_prob.get(a) orelse 1.0 / (self.d_prev + 1.0));
    }
    fn scopePGlobal(self: *const Price) f64 {
        return (self.scope_count_global + 1.0) / (self.d_prev + 1.0 + self.n_scope_kinds);
    }
    fn scopePLocal(self: *const Price, s: u8) f64 {
        return (self.scope_count_local[s] + 1.0) / (self.d_prev + 1.0 + self.n_scope_kinds);
    }
    fn localUsePrice(self: *const Price, s: u8, c: u32) f64 {
        const key: u64 = (@as(u64, s) << 32) | @as(u64, @min(c, 1 << 20));
        return self.count_price.get(key) orelse self.avg_local_bits[s];
    }
};

fn inlineCost(children: []const u32, price_use_byte: *const [256]f64, price_use_entry: []const f64) f64 {
    var s: f64 = 0;
    for (children) |ch| s += if (ch < 256) price_use_byte[ch] else price_use_entry[ch - 256];
    return s;
}

fn runV2(alloc: std.mem.Allocator, dump: *const Dump, counts: *const Counts, order: []const u32, sset: []const u8, allow_dissolve: bool, rounds: u32) !V2Result {
    const n_entries = dump.nEntries();
    const block_count = dump.blocks.len;

    // Static (round-independent) per-symbol reference price, from raw text
    // occurrence counts. Used only to estimate the cost of *not* defining an
    // entry at some point (its body's children get coded directly instead,
    // recursively) -- without this, a "never twice in the same window" entry
    // looks free to the greedy per-entry decision (0 direct events) even
    // though its body still has to be coded somewhere, every time.
    const n_text: f64 = @floatFromInt(@max(counts.n_total, 1));
    var price_use_byte: [256]f64 = undefined;
    for (0..256) |b| price_use_byte[b] = bits(@as(f64, @floatFromInt(@max(counts.byte_n[b], 1))) / n_text);
    const price_use_entry = try alloc.alloc(f64, n_entries);
    defer alloc.free(price_use_entry);
    for (0..n_entries) |i| price_use_entry[i] = bits(@as(f64, @floatFromInt(@max(counts.entry_n[i], 1))) / n_text);

    var occ: []std.ArrayList(u32) = try alloc.alloc(std.ArrayList(u32), n_entries);
    for (occ) |*o| o.* = .empty;
    defer {
        for (occ) |*o| o.deinit(alloc);
        alloc.free(occ);
    }
    const total_occ = try alloc.alloc(u32, n_entries);
    defer alloc.free(total_occ);
    const scope = try alloc.alloc(EntryScope, n_entries);
    defer alloc.free(scope);

    const scratch_count = try alloc.alloc(u32, block_count + 1);
    defer alloc.free(scratch_count);
    const scratch_min = try alloc.alloc(u32, block_count + 1);
    defer alloc.free(scratch_min);
    @memset(scratch_count, 0);
    var touched: std.ArrayList(u32) = .empty;
    defer touched.deinit(alloc);
    var groups: [MAXS]std.ArrayList(WinItem) = [_]std.ArrayList(WinItem){.empty} ** MAXS;
    defer for (&groups) |*g| g.deinit(alloc);

    var price = Price.init(1.0 + @as(f64, @floatFromInt(sset.len)) + (if (allow_dissolve) @as(f64, 1.0) else 0.0));
    defer price.deinit(alloc);

    var result: V2Result = undefined;

    var round: u32 = 0;
    while (round <= rounds) : (round += 1) {
        const force_global = (round == 0);

        // reset
        @memset(total_occ, 0);
        var byte_count: [256]u64 = [_]u64{0} ** 256;
        for (occ) |*o| o.clearRetainingCapacity();
        for (dump.blocks, 0..) |blk, bidx| {
            for (blk) |t| {
                if (t < 256) byte_count[t] += 1 else try occ[t - 256].append(alloc, @intCast(bidx));
            }
        }

        var arity_hist: std.AutoHashMapUnmanaged(u32, u64) = .{};
        defer arity_hist.deinit(alloc);
        var scope_hist_global: u64 = 0;
        var scope_hist_local: [MAXS]u64 = [_]u64{0} ** MAXS;
        var d_total: u64 = 0;
        var window_active: std.AutoHashMapUnmanaged(u64, std.ArrayList(ActiveItem)) = .{};
        defer {
            var it = window_active.valueIterator();
            while (it.next()) |v| v.deinit(alloc);
            window_active.deinit(alloc);
        }
        for (order) |ei| {
            const i: usize = ei;
            total_occ[i] = @intCast(occ[i].items.len);
            if (total_occ[i] == 0) {
                scope[i] = .{ .kind = .unused };
                continue;
            }
            const arity: u32 = @intCast(dump.children[i].len);

            // group occurrences by window for every s in sset
            for (sset, 0..) |s, gi| {
                groups[gi].clearRetainingCapacity();
                touched.clearRetainingCapacity();
                for (occ[i].items) |b| {
                    const w = b >> @intCast(s);
                    if (scratch_count[w] == 0) {
                        try touched.append(alloc, w);
                        scratch_min[w] = b;
                    }
                    scratch_count[w] += 1;
                    if (b < scratch_min[w]) scratch_min[w] = b;
                }
                for (touched.items) |w| {
                    try groups[gi].append(alloc, .{ .w = w, .c = scratch_count[w], .minb = scratch_min[w] });
                    scratch_count[w] = 0;
                }
            }

            var best_kind: ScopeKind = .global;
            var best_s: u8 = 0;
            var best_cost: f64 = std.math.inf(f64);

            if (force_global) {
                best_kind = .global;
            } else {
                const def_p = clampP(price.d_prev / price.n_prev);
                const arity_p = price.arityP(arity);
                const scope_p_g = clampP(price.scopePGlobal());
                const u = total_occ[i] - 1;
                var cost_g: f64 = bits(def_p) + bits(arity_p) + bits(scope_p_g);
                if (u > 0) cost_g += @as(f64, @floatFromInt(u)) * bits(@as(f64, @floatFromInt(u)) / price.n_prev);
                best_cost = cost_g;
                best_kind = .global;
                // Require a real margin over global before switching away
                // from it: every candidate here is priced off a *pooled*
                // (or, for count_price, still partial) previous-round
                // average, so many entries look marginally attractive at
                // once. An infinitesimal "cheaper" comparison lets a whole
                // cohort rush the same lifetime in one round, only to find
                // it crowded (and genuinely more expensive) once the exact
                // ranks land -- the margin keeps round-to-round adoption to
                // the clearly-good cases and lets the rest wait for a firmer
                // (count-aware) price before they also switch.
                const margin = 0.85;
                const inline_cost = inlineCost(dump.children[i], &price_use_byte, price_use_entry);
                if (allow_dissolve) {
                    // No margin here: dissolve doesn't share a crowded,
                    // ranked resource across entries the way local(s) does,
                    // so it has none of the flood/overshoot risk to guard
                    // against -- plain cheapest-wins is fine.
                    const cost_d: f64 = @as(f64, @floatFromInt(total_occ[i])) * inline_cost;
                    if (cost_d < best_cost) {
                        best_cost = cost_d;
                        best_kind = .dissolve;
                    }
                }
                for (sset, 0..) |s, gi| {
                    const scope_p_l = clampP(price.scopePLocal(s));
                    var cost_l: f64 = 0;
                    for (groups[gi].items) |g| {
                        if (g.c >= 2) {
                            cost_l += bits(def_p) + bits(arity_p) + bits(scope_p_l);
                            cost_l += @as(f64, @floatFromInt(g.c - 1)) * price.localUsePrice(s, g.c);
                        } else {
                            cost_l += inline_cost;
                        }
                    }
                    if (cost_l < cost_g * margin and cost_l < best_cost) {
                        best_cost = cost_l;
                        best_kind = .local;
                        best_s = s;
                    }
                }
            }

            scope[i] = .{ .kind = best_kind, .s = best_s };

            // propagate to children per the chosen scope's instantiation pattern
            switch (best_kind) {
                .unused => {},
                .global => {
                    d_total += 1;
                    scope_hist_global += 1;
                    const gop = try arity_hist.getOrPut(alloc, arity);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                    var first_b: u32 = std.math.maxInt(u32);
                    for (occ[i].items) |b| first_b = @min(first_b, b);
                    for (dump.children[i]) |ch| {
                        if (ch < 256) {
                            byte_count[ch] += 1;
                        } else {
                            try occ[ch - 256].append(alloc, first_b);
                        }
                    }
                },
                .dissolve => {
                    for (occ[i].items) |b| {
                        for (dump.children[i]) |ch| {
                            if (ch < 256) {
                                byte_count[ch] += 1;
                            } else {
                                try occ[ch - 256].append(alloc, b);
                            }
                        }
                    }
                },
                .local => {
                    var gi: usize = 0;
                    for (sset, 0..) |s, k| if (s == best_s) {
                        gi = k;
                    };
                    for (groups[gi].items) |g| {
                        if (g.c >= 2) {
                            d_total += 1;
                            scope_hist_local[best_s] += 1;
                            const gop = try arity_hist.getOrPut(alloc, arity);
                            if (!gop.found_existing) gop.value_ptr.* = 0;
                            gop.value_ptr.* += 1;
                            const key: u64 = (@as(u64, best_s) << 32) | g.w;
                            const gop2 = try window_active.getOrPut(alloc, key);
                            if (!gop2.found_existing) gop2.value_ptr.* = .empty;
                            try gop2.value_ptr.append(alloc, .{ .idx = @intCast(i), .c = g.c });
                        }
                        // both c>=2 (defined) and c==1 (inlined) windows instantiate the body once.
                        for (dump.children[i]) |ch| {
                            if (ch < 256) {
                                byte_count[ch] += 1;
                            } else {
                                try occ[ch - 256].append(alloc, g.minb);
                            }
                        }
                    }
                },
            }
            occ[i].clearRetainingCapacity();
        }

        // ---- exact final accounting for this round ----
        var local_hist: std.AutoHashMapUnmanaged(u32, u64) = .{}; // key = s*64+j
        defer local_hist.deinit(alloc);
        var local_use_count: u64 = 0;
        var local_raw_bits: f64 = 0;
        var pending: std.ArrayList(Pending) = .empty;
        defer pending.deinit(alloc);

        var wit = window_active.iterator();
        while (wit.next()) |entry| {
            const s: u8 = @intCast(entry.key_ptr.* >> 32);
            const list = entry.value_ptr.items;
            std.mem.sort(ActiveItem, list, {}, struct {
                fn lt(_: void, a: ActiveItem, b: ActiveItem) bool {
                    return a.c > b.c;
                }
            }.lt);
            for (list, 0..) |it, rank| {
                const j = floorLog2(@as(u64, rank) + 1);
                const key: u32 = @as(u32, s) * 64 + j;
                const gop = try local_hist.getOrPut(alloc, key);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                const uses = it.c - 1;
                gop.value_ptr.* += uses;
                local_use_count += uses;
                local_raw_bits += @as(f64, @floatFromInt(uses)) * @as(f64, @floatFromInt(j));
                const ck: u64 = (@as(u64, s) << 32) | @as(u64, @min(it.c, 1 << 20));
                try pending.append(alloc, .{ .ck = ck, .sjkey = key, .uses = uses });
            }
        }

        var byte_bits_sum: f64 = 0;
        var byte_total: u64 = 0;
        for (byte_count) |n| {
            byte_total += n;
        }
        var global_use_count: u64 = 0;
        for (total_occ, 0..) |_, i| {
            if (scope[i].kind == .global) {
                const u = total_occ[i] - 1;
                global_use_count += u;
            }
        }
        const n_total: u64 = byte_total + d_total + global_use_count + local_use_count;
        const Nf: f64 = @floatFromInt(n_total);
        for (byte_count) |n| if (n > 0) {
            byte_bits_sum += @as(f64, @floatFromInt(n)) * bits(@as(f64, @floatFromInt(n)) / Nf);
        };

        // Now that Nf (and hence each LOCAL(s,j) event's real price) is
        // known, resolve every pending (s, in-window count) instance to its
        // real per-use bit cost and average that per (s, count) -- next
        // round's decision looks this up directly instead of a pooled mean.
        var count_price_accum: std.AutoHashMapUnmanaged(u64, Accum) = .{};
        defer count_price_accum.deinit(alloc);
        for (pending.items) |p| {
            const n_sj: f64 = @floatFromInt(local_hist.get(p.sjkey).?);
            const j: f64 = @floatFromInt(p.sjkey % 64);
            const per_use = bits(n_sj / Nf) + j;
            const gop = try count_price_accum.getOrPut(alloc, p.ck);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.sum += per_use * @as(f64, @floatFromInt(p.uses));
            gop.value_ptr.cnt += p.uses;
        }

        var def_bits_sum: f64 = 0;
        if (d_total > 0) def_bits_sum = @as(f64, @floatFromInt(d_total)) * bits(@as(f64, @floatFromInt(d_total)) / Nf);

        const Df: f64 = @floatFromInt(@max(d_total, 1));
        var arity_bits_sum: f64 = 0;
        {
            var it = arity_hist.iterator();
            while (it.next()) |e| {
                const cnt: f64 = @floatFromInt(e.value_ptr.*);
                arity_bits_sum += cnt * bits(cnt / Df);
            }
        }
        var scope_bits_sum: f64 = 0;
        if (scope_hist_global > 0) {
            const cnt: f64 = @floatFromInt(scope_hist_global);
            scope_bits_sum += cnt * bits(cnt / Df);
        }
        for (scope_hist_local) |cnt64| if (cnt64 > 0) {
            const cnt: f64 = @floatFromInt(cnt64);
            scope_bits_sum += cnt * bits(cnt / Df);
        };

        var global_use_bits_sum: f64 = 0;
        for (total_occ, 0..) |_, i| {
            if (scope[i].kind == .global) {
                const u = total_occ[i] - 1;
                if (u > 0) global_use_bits_sum += @as(f64, @floatFromInt(u)) * bits(@as(f64, @floatFromInt(u)) / Nf);
            }
        }

        var local_use_bits_sum: f64 = 0;
        {
            var it = local_hist.iterator();
            while (it.next()) |e| {
                const cnt: f64 = @floatFromInt(e.value_ptr.*);
                if (cnt > 0) local_use_bits_sum += cnt * bits(cnt / Nf);
            }
        }
        local_use_bits_sum += local_raw_bits;

        const total_bits = byte_bits_sum + def_bits_sum + arity_bits_sum + scope_bits_sum + global_use_bits_sum + local_use_bits_sum;

        // Update the price table for next round, damped (exponential moving
        // average, alpha=0.5): entries decide off *pooled averages*, so an
        // undamped update lets a whole cohort "rush" a lifetime that looked
        // cheap last round, overshoot, then evacuate next round -- damping
        // trades a slower approach to the fixed point for less oscillation.
        const alpha = 0.5;
        {
            var it = arity_hist.iterator();
            while (it.next()) |e| {
                const fresh = @as(f64, @floatFromInt(e.value_ptr.*)) / Df;
                const gop = try price.arity_prob.getOrPut(alloc, e.key_ptr.*);
                gop.value_ptr.* = if (gop.found_existing) alpha * fresh + (1 - alpha) * gop.value_ptr.* else fresh;
            }
        }
        price.scope_count_global = if (round == 0) @floatFromInt(scope_hist_global) else alpha * @as(f64, @floatFromInt(scope_hist_global)) + (1 - alpha) * price.scope_count_global;
        for (0..MAXS) |s| {
            const fresh: f64 = @floatFromInt(scope_hist_local[s]);
            price.scope_count_local[s] = if (round == 0) fresh else alpha * fresh + (1 - alpha) * price.scope_count_local[s];
        }
        price.n_prev = if (round == 0) Nf else alpha * Nf + (1 - alpha) * price.n_prev;
        price.d_prev = if (round == 0) Df else alpha * Df + (1 - alpha) * price.d_prev;
        for (0..MAXS) |s| {
            var num: f64 = 0;
            var den: f64 = 0;
            for (0..MAXS) |j| {
                const key: u32 = @as(u32, @intCast(s)) * 64 + @as(u32, @intCast(j));
                if (local_hist.get(key)) |cnt64| {
                    const cnt: f64 = @floatFromInt(cnt64);
                    if (cnt > 0) {
                        num += cnt * (bits(cnt / Nf) + @as(f64, @floatFromInt(j)));
                        den += cnt;
                    }
                }
            }
            if (den > 0) {
                const fresh = num / den;
                price.avg_local_bits[s] = if (round == 0) fresh else alpha * fresh + (1 - alpha) * price.avg_local_bits[s];
            }
        }
        {
            var it = count_price_accum.iterator();
            while (it.next()) |e| {
                const fresh = e.value_ptr.sum / @as(f64, @floatFromInt(e.value_ptr.cnt));
                const gop = try price.count_price.getOrPut(alloc, e.key_ptr.*);
                gop.value_ptr.* = if (gop.found_existing) alpha * fresh + (1 - alpha) * gop.value_ptr.* else fresh;
            }
        }

        if (verbose) std.debug.print("    round={d} bytes={d:.0} D={d} avg_local={any}\n", .{ round, total_bits / 8.0, d_total, price.avg_local_bits });

        // The greedy per-entry coordinate descent is not guaranteed monotone
        // (many entries can "rush" a lifetime in the same round based on the
        // previous round's average price, only to find it crowded once the
        // exact ranks are in); keep the best round seen rather than just the
        // last one, like a best-checkpoint search. "global" is always an
        // available choice, so this can never end up worse than round 0.
        if (round == 0 or total_bits / 8.0 < result.bytes) {
            var n_global: usize = 0;
            var n_local: usize = 0;
            var n_dissolved: usize = 0;
            var n_local_by_s: [MAXS]usize = [_]usize{0} ** MAXS;
            for (scope) |sc| switch (sc.kind) {
                .global => n_global += 1,
                .local => {
                    n_local += 1;
                    n_local_by_s[sc.s] += 1;
                },
                .dissolve => n_dissolved += 1,
                .unused => {},
            };
            result = .{
                .bytes = total_bits / 8.0,
                .frac_local = if (global_use_count + local_use_count > 0) @as(f64, @floatFromInt(local_use_count)) / @as(f64, @floatFromInt(global_use_count + local_use_count)) else 0,
                .mean_global_bits = if (global_use_count > 0) global_use_bits_sum / @as(f64, @floatFromInt(global_use_count)) else 0,
                .mean_local_bits = if (local_use_count > 0) local_use_bits_sum / @as(f64, @floatFromInt(local_use_count)) else 0,
                .n_global = n_global,
                .n_local = n_local,
                .n_dissolved = n_dissolved,
                .n_local_by_s = n_local_by_s,
                .def_instances_global = scope_hist_global,
                .def_instances_local = d_total - scope_hist_global,
            };
        }
    }
    return result;
}

// ------------------------------------------------------------------ main --

const Job = struct { dump: []const u8, raw: []const u8, label: []const u8 };

const jobs = [_]Job{
    .{ .dump = "dumps/m_freedict.eval8.16384.b4sd", .raw = "data/freedict.eval8.bin", .label = "freedict.eval8.16384 (v2 word-lex)" },
    .{ .dump = "dumps/m_freedict.eval8.65536.b4sd", .raw = "data/freedict.eval8.bin", .label = "freedict.eval8.65536 (v2 word-lex)" },
    .{ .dump = "dumps/m_freedict.untouched.65536.b4sd", .raw = "data/freedict.untouched.bin", .label = "freedict.untouched.65536 (v2 word-lex)" },
    .{ .dump = "dumps/m_gcide.eval8.16384.b4sd", .raw = "data/gcide.eval8.bin", .label = "gcide.eval8.16384 (v2 word-lex)" },
    .{ .dump = "dumps/m_gcide.eval8.65536.b4sd", .raw = "data/gcide.eval8.bin", .label = "gcide.eval8.65536 (v2 word-lex)" },
    .{ .dump = "dumps/m_gcide.untouched.65536.b4sd", .raw = "data/gcide.untouched.bin", .label = "gcide.untouched.65536 (v2 word-lex)" },
    .{ .dump = "dumps/m_omw.eval8.16384.b4sd", .raw = "data/omw.eval8.bin", .label = "omw.eval8.16384 (v2 word-lex)" },
    .{ .dump = "dumps/m_omw.eval8.65536.b4sd", .raw = "data/omw.eval8.bin", .label = "omw.eval8.65536 (v2 word-lex)" },
    .{ .dump = "dumps/m_omw.untouched.65536.b4sd", .raw = "data/omw.untouched.bin", .label = "omw.untouched.65536 (v2 word-lex)" },
    .{ .dump = "dumps/m_json.eval8.65536.b4sd", .raw = "data/json.eval8.bin", .label = "json.eval8.65536 (v2 word-lex)" },
    .{ .dump = "dumps/m_macho.eval8.65536.b4sd", .raw = "data/macho.eval8.bin", .label = "macho.eval8.65536 (v2 word-lex)" },
    .{ .dump = "dumps/m_zigsrc.eval8.65536.b4sd", .raw = "data/zigsrc.eval8.bin", .label = "zigsrc.eval8.65536 (v2 word-lex)" },
    .{ .dump = "dumps/freedict.eval8.16k.full.b4sd", .raw = "data/freedict.eval8.bin", .label = "freedict.eval8.16k (v1 full re-pair)" },
    .{ .dump = "dumps/freedict.eval8.64k.full.b4sd", .raw = "data/freedict.eval8.bin", .label = "freedict.eval8.64k (v1 full re-pair)" },
    .{ .dump = "dumps/gcide.eval8.16k.full.b4sd", .raw = "data/gcide.eval8.bin", .label = "gcide.eval8.16k (v1 full re-pair)" },
    .{ .dump = "dumps/gcide.eval8.64k.full.b4sd", .raw = "data/gcide.eval8.bin", .label = "gcide.eval8.64k (v1 full re-pair)" },
    .{ .dump = "dumps/omw.eval8.16k.full.b4sd", .raw = "data/omw.eval8.bin", .label = "omw.eval8.16k (v1 full re-pair)" },
    .{ .dump = "dumps/omw.eval8.64k.full.b4sd", .raw = "data/omw.eval8.bin", .label = "omw.eval8.64k (v1 full re-pair)" },
    .{ .dump = "dumps/json.eval8.16k.full.b4sd", .raw = "data/json.eval8.bin", .label = "json.eval8.16k (v1 full re-pair)" },
    .{ .dump = "dumps/json.eval8.64k.full.b4sd", .raw = "data/json.eval8.bin", .label = "json.eval8.64k (v1 full re-pair)" },
    .{ .dump = "dumps/macho.eval8.16k.full.b4sd", .raw = "data/macho.eval8.bin", .label = "macho.eval8.16k (v1 full re-pair)" },
    .{ .dump = "dumps/macho.eval8.64k.full.b4sd", .raw = "data/macho.eval8.bin", .label = "macho.eval8.64k (v1 full re-pair)" },
    .{ .dump = "dumps/zigsrc.eval8.16k.full.b4sd", .raw = "data/zigsrc.eval8.bin", .label = "zigsrc.eval8.16k (v1 full re-pair)" },
    .{ .dump = "dumps/zigsrc.eval8.64k.full.b4sd", .raw = "data/zigsrc.eval8.bin", .label = "zigsrc.eval8.64k (v1 full re-pair)" },
};

fn printSHist(n_local_by_s: [MAXS]usize) void {
    std.debug.print("{{", .{});
    for (0..MAXS) |s| {
        if (n_local_by_s[s] > 0) std.debug.print("{d}:{d} ", .{ s, n_local_by_s[s] });
    }
    std.debug.print("}}", .{});
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const filter = it.next();
    if (it.next()) |v2| verbose = std.mem.eql(u8, v2, "-v");

    const s_sets = [_][]const u8{
        &.{0},
        &.{ 0, 2, 4 },
        &.{ 0, 1, 2, 3, 4, 5, 6 },
    };
    const s_labels = [_][]const u8{ "S={0}", "S={0,2,4}", "S={0..6}" };

    for (jobs) |job| {
        if (filter) |f| {
            if (std.mem.indexOf(u8, job.dump, f) == null) continue;
        }
        std.debug.print("\n== {s} ==\n  dump={s}\n", .{ job.label, job.dump });

        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const a = arena_state.allocator();

        const dbytes = std.Io.Dir.cwd().readFileAlloc(io, job.dump, a, .limited(1 << 31)) catch |e| {
            std.debug.print("  SKIP (read error: {s})\n", .{@errorName(e)});
            continue;
        };
        var dump = readDump(a, dbytes) catch |e| {
            std.debug.print("  SKIP (parse error: {s})\n", .{@errorName(e)});
            continue;
        };

        const raw = std.Io.Dir.cwd().readFileAlloc(io, job.raw, a, .limited(1 << 31)) catch |e| {
            std.debug.print("  SKIP (raw read error: {s})\n", .{@errorName(e)});
            continue;
        };

        validate(a, &dump, raw) catch |e| {
            std.debug.print("  VALIDATE FAILED: {s} -- not trusting this dump\n", .{@errorName(e)});
            continue;
        };
        std.debug.print("  validate: OK ({d} blocks, {d} entries, raw_len={d})\n", .{ dump.blocks.len, dump.nEntries(), dump.raw_len });

        const explen = try explenAll(a, &dump);
        const order = try a.alloc(u32, dump.nEntries());
        for (order, 0..) |*o, i| o.* = @intCast(i);
        std.mem.sort(u32, order, explen, struct {
            fn lt(el: []const u32, x: u32, y: u32) bool {
                return el[x] > el[y];
            }
        }.lt);

        const counts = try countText(a, &dump);
        const v0 = v0Bits(&counts, dump.nEntries()) / 8.0;
        const v1 = try v1Bits(a, &dump, &counts);
        const v1b = v1 / 8.0;
        std.debug.print("  N_text_tokens={d}\n", .{counts.n_total});
        std.debug.print("  V0_bytes={d:.0}\n", .{v0});
        std.debug.print("  V1_bytes={d:.0}  pct_vs_V0={d:.2}%\n", .{ v1b, 100.0 * (v1b - v0) / v0 });

        const allow_dissolve = dump.version == 1;
        for (s_sets, s_labels) |sset, slabel| {
            const r = try runV2(a, &dump, &counts, order, sset, allow_dissolve, 8);
            std.debug.print(
                "  V2[{s}] bytes={d:.0} pct_vs_V0={d:.2}% pct_vs_V1={d:.2}% frac_local={d:.3} mean_global_bits={d:.2} mean_local_bits={d:.2} n_global={d} n_local={d} n_dissolved={d} def_inst(g={d},l={d}) s_hist=",
                .{ slabel, r.bytes, 100.0 * (r.bytes - v0) / v0, 100.0 * (r.bytes - v1b) / v1b, r.frac_local, r.mean_global_bits, r.mean_local_bits, r.n_global, r.n_local, r.n_dissolved, r.def_instances_global, r.def_instances_local },
            );
            printSHist(r.n_local_by_s);
            std.debug.print("\n", .{});
        }
    }
}
