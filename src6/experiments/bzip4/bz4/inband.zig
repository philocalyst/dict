//! Lane I: standalone in-band grammar compression ("bzip3 file" regime).
//!
//! One block == the whole file. Build a full pair grammar (gprobe), then
//! transmit it IN-BAND as a first-occurrence (DEF/REF) item stream with
//! exact "urn" probabilities (the GLZA trick): at each DEF we transmit
//! n[s], the exact number of REF(s) events remaining in the rest of the
//! stream, and REF(s) is coded with probability remaining[s]/total via a
//! Fenwick tree, decrementing after use. See LANE_I.md for the notebook.
//!
//! Pure Zig 0.16, std only. Uses rc.zig (shared range coder) and
//! gprobe.zig (grammar builder) by @import, per PLAN.md.

const std = @import("std");
const gprobe = @import("gprobe.zig");
const rc = @import("rc.zig");

// ---------------------------------------------------------------- options --

pub const Options = packed struct {
    exact_flag: bool = false, // DEF/REF flag: exact urn (defs_left/items_left) vs adaptive Bit
    first_byte: bool = false, // REF: first-byte factorisation
    cache: bool = false, // REF: small recency cache
    _pad: u5 = 0,

    pub fn toByte(self: Options) u8 {
        return @bitCast(self);
    }
    pub fn fromByte(b: u8) Options {
        return @bitCast(b);
    }
};

const FB_INC: u32 = 24; // adaptive increment for the first-byte-given-last-byte model
const CACHE_N: usize = 16;
const RATE: u4 = 5;

// --------------------------------------------------------------- fenwick --

/// Fixed-capacity Fenwick tree (BIT) over 0-indexed slots, supporting point
/// updates and "find the slot containing cumulative position v" (order
/// statistics), used both as an exact urn (weights = remaining counts) and
/// as an adaptive frequency table (weights = smoothed counts).
const Fenwick = struct {
    alloc: std.mem.Allocator,
    tree: []u32,
    len: usize,
    hibit: usize,
    total: u64 = 0,

    fn init(alloc: std.mem.Allocator, len: usize) !Fenwick {
        const cap = @max(len, 1);
        const tree = try alloc.alloc(u32, cap + 1);
        @memset(tree, 0);
        var h: usize = 1;
        while (h * 2 <= cap) h *= 2;
        return .{ .alloc = alloc, .tree = tree, .len = cap, .hibit = h };
    }

    fn deinit(self: *Fenwick) void {
        self.alloc.free(self.tree);
    }

    fn add(self: *Fenwick, idx0: usize, delta: i64) void {
        self.total = @intCast(@as(i64, @intCast(self.total)) + delta);
        var i: usize = idx0 + 1;
        while (i <= self.len) : (i += i & (0 -% i)) {
            self.tree[i] = @intCast(@as(i64, @intCast(self.tree[i])) + delta);
        }
    }

    fn prefix(self: *const Fenwick, idx0_incl: usize) u32 {
        var i: usize = idx0_incl + 1;
        var s: u32 = 0;
        while (i > 0) : (i -= i & (0 -% i)) s += self.tree[i];
        return s;
    }

    fn cumBefore(self: *const Fenwick, idx0: usize) u32 {
        if (idx0 == 0) return 0;
        return self.prefix(idx0 - 1);
    }

    fn weightAt(self: *const Fenwick, idx0: usize) u32 {
        return self.cumBefore(idx0 + 1) - self.cumBefore(idx0);
    }

    /// Find the 0-indexed slot whose interval contains cumulative value `target`.
    fn find(self: *const Fenwick, target: u32) usize {
        var idx: usize = 0;
        var rem = target;
        var step = self.hibit;
        while (step > 0) : (step >>= 1) {
            const next = idx + step;
            if (next <= self.len and self.tree[next] <= rem) {
                idx = next;
                rem -= self.tree[next];
            }
        }
        return idx;
    }
};

test "fenwick order statistics" {
    const alloc = std.testing.allocator;
    var fw = try Fenwick.init(alloc, 8);
    defer fw.deinit();
    const w = [_]u32{ 3, 0, 1, 5, 0, 2, 0, 4 };
    for (w, 0..) |v, i| fw.add(i, @intCast(v));
    try std.testing.expectEqual(@as(u64, 15), fw.total);
    // Walk every cumulative position and check it lands in the right slot.
    var expect_idx: usize = 0;
    var acc: u32 = 0;
    var target: u32 = 0;
    while (target < 15) : (target += 1) {
        while (target >= acc + w[expect_idx]) {
            acc += w[expect_idx];
            expect_idx += 1;
        }
        try std.testing.expectEqual(expect_idx, fw.find(target));
    }
    fw.add(3, -5);
    try std.testing.expectEqual(@as(u32, 0), fw.weightAt(3));
    try std.testing.expectEqual(@as(u64, 10), fw.total);
}

// -------------------------------------------------------- gamma bit coder --

const NUM_CTX = 8 * 8 * 3;
const POS_MAX = 24;

const GammaModels = struct {
    cont: [NUM_CTX][POS_MAX]rc.Bit = [_][POS_MAX]rc.Bit{[_]rc.Bit{.{}} ** POS_MAX} ** NUM_CTX,
    mant: [NUM_CTX][POS_MAX]rc.Bit = [_][POS_MAX]rc.Bit{[_]rc.Bit{.{}} ** POS_MAX} ** NUM_CTX,
};

fn depthBucket(d: u32) usize {
    return @intCast(@min(d, 7));
}
fn lenBucket(len: u32) usize {
    const bl = 32 - @clz(@max(len, 1));
    return @intCast(@min(bl -| 1, 7));
}
fn leftBucket(nleft: u32) usize {
    if (nleft <= 1) return 0;
    if (nleft == 2) return 1;
    return 2;
}
fn ctxIndex(depth: u32, explen: u32, nleft: u32) usize {
    return (depthBucket(depth) * 8 + lenBucket(explen)) * 3 + leftBucket(nleft);
}

/// Elias-gamma-style adaptive code for n >= 0: encodes v = n+1 as an
/// adaptive-unary exponent (context+position) followed by adaptive mantissa
/// bits (context+position). Most n are 1 or 2, so this is usually 1-3 bits.
fn encodeGamma(enc: *rc.Encoder, gm: *GammaModels, ctx: usize, n: u32) !void {
    const v = n + 1;
    const bl = 32 - @clz(v);
    const extra = bl - 1;
    var i: u32 = 0;
    while (i < extra) : (i += 1) try enc.encodeBit(&gm.cont[ctx][@min(i, POS_MAX - 1)], 1, RATE);
    try enc.encodeBit(&gm.cont[ctx][@min(extra, POS_MAX - 1)], 0, RATE);
    var j: u32 = extra;
    while (j > 0) {
        j -= 1;
        const bit: u1 = @intCast((v >> @intCast(j)) & 1);
        try enc.encodeBit(&gm.mant[ctx][@min(j, POS_MAX - 1)], bit, RATE);
    }
}

fn decodeGamma(dec: *rc.Decoder, gm: *GammaModels, ctx: usize) u32 {
    var extra: u32 = 0;
    while (dec.decodeBit(&gm.cont[ctx][@min(extra, POS_MAX - 1)], RATE) == 1) extra += 1;
    var v: u32 = 1;
    var j: u32 = extra;
    while (j > 0) {
        j -= 1;
        const bit = dec.decodeBit(&gm.mant[ctx][@min(j, POS_MAX - 1)], RATE);
        v = (v << 1) | bit;
    }
    return v - 1;
}

// ------------------------------------------------------------ flag coder --

const FlagModels = struct {
    m: [8][3]rc.Bit = [_][3]rc.Bit{[_]rc.Bit{.{}} ** 3} ** 8,
};

fn encodeFlagUrn(enc: *rc.Encoder, defs_left: *u32, calls_left: *u32, is_def: bool) !void {
    const tot = calls_left.*;
    if (is_def) {
        try enc.encodeFreq(0, defs_left.*, tot);
        defs_left.* -= 1;
    } else {
        try enc.encodeFreq(defs_left.*, tot - defs_left.*, tot);
    }
    calls_left.* -= 1;
}

fn decodeFlagUrn(dec: *rc.Decoder, defs_left: *u32, calls_left: *u32) bool {
    const tot = calls_left.*;
    const v = dec.decodeFreq(tot);
    const is_def = v < defs_left.*;
    if (is_def) {
        dec.consume(0, defs_left.*);
        defs_left.* -= 1;
    } else {
        dec.consume(defs_left.*, tot - defs_left.*);
    }
    calls_left.* -= 1;
    return is_def;
}

// ---------------------------------------------------- adaptive byte model --

/// 256 adaptive frequency tables (one per "last output byte" context) over
/// the 256 possible first-byte values, Laplace-smoothed, incremented after
/// each use. Used only when Options.first_byte is set.
const AdaptiveByteModel = struct {
    trees: []Fenwick,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) !AdaptiveByteModel {
        const trees = try alloc.alloc(Fenwick, 256);
        for (trees) |*t| {
            t.* = try Fenwick.init(alloc, 256);
            for (0..256) |i| t.add(i, 1);
        }
        return .{ .trees = trees, .alloc = alloc };
    }
    fn deinit(self: *AdaptiveByteModel) void {
        for (self.trees) |*t| t.deinit();
        self.alloc.free(self.trees);
    }
};

// ------------------------------------------------------------------ cache --

const Cache = struct {
    ids: [CACHE_N]u32 = [_]u32{std.math.maxInt(u32)} ** CACHE_N,
    len: usize = 0,
    hit_model: rc.Bit = .{},
    pos_model: [CACHE_N]rc.Bit = [_]rc.Bit{.{}} ** CACHE_N,

    fn find(self: *const Cache, id: u32) ?usize {
        for (self.ids[0..self.len], 0..) |v, i| if (v == id) return i;
        return null;
    }
    fn touch(self: *Cache, id: u32, pos: ?usize) void {
        if (pos) |p| {
            var i = p;
            while (i > 0) : (i -= 1) self.ids[i] = self.ids[i - 1];
            self.ids[0] = id;
        } else {
            const newlen = @min(self.len + 1, CACHE_N);
            var i = newlen;
            while (i > 1) : (i -= 1) self.ids[i - 1] = self.ids[i - 2];
            self.ids[0] = id;
            self.len = newlen;
        }
    }
};

// -------------------------------------------------------------- LE header --

fn appendU32LE(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try list.appendSlice(alloc, &buf);
}
fn readU32LE(bytes: []const u8, off: *usize) u32 {
    const v = std.mem.readInt(u32, bytes[off.*..][0..4], .little);
    off.* += 4;
    return v;
}

// ----------------------------------------------------------- static prep --

const Static = struct {
    alloc: std.mem.Allocator,
    k: usize,
    reachable: []bool,
    n_arr: []u32,
    depth_arr: []u32,
    explen_arr: []u32,
    firstbyte_arr: []u8,
    num_defs_total: u32,
    class_capacity: [256]u32,

    fn deinit(self: *Static) void {
        self.alloc.free(self.reachable);
        self.alloc.free(self.n_arr);
        self.alloc.free(self.depth_arr);
        self.alloc.free(self.explen_arr);
        self.alloc.free(self.firstbyte_arr);
    }
};

fn computeStatic(alloc: std.mem.Allocator, g: *const gprobe.Grammar) !Static {
    const k = 256 + g.rules.items.len;
    const root_count = try alloc.alloc(u32, k);
    defer alloc.free(root_count);
    @memset(root_count, 0);
    for (g.seq) |s| root_count[s] += 1;

    const reachable = try alloc.alloc(bool, k);
    @memset(reachable, false);
    for (0..256) |b| reachable[b] = true;
    for (0..k) |s| if (root_count[s] > 0) {
        reachable[s] = true;
    };
    {
        var i: usize = g.rules.items.len;
        while (i > 0) {
            i -= 1;
            const s = 256 + i;
            if (reachable[s]) {
                const r = g.rules.items[i];
                reachable[r.a] = true;
                reachable[r.b] = true;
            }
        }
    }

    const child_count = try alloc.alloc(u32, k);
    defer alloc.free(child_count);
    @memset(child_count, 0);
    for (0..g.rules.items.len) |i| {
        const s = 256 + i;
        if (reachable[s]) {
            const r = g.rules.items[i];
            child_count[r.a] += 1;
            child_count[r.b] += 1;
        }
    }

    const n_arr = try alloc.alloc(u32, k);
    for (0..256) |b| n_arr[b] = root_count[b] + child_count[b];
    for (0..g.rules.items.len) |i| {
        const s = 256 + i;
        n_arr[s] = if (reachable[s]) (root_count[s] + child_count[s]) -| 1 else 0;
    }

    const depth_arr = try alloc.alloc(u32, k);
    const explen_arr = try alloc.alloc(u32, k);
    const firstbyte_arr = try alloc.alloc(u8, k);
    for (0..256) |b| {
        depth_arr[b] = 0;
        explen_arr[b] = 1;
        firstbyte_arr[b] = @intCast(b);
    }
    for (0..g.rules.items.len) |i| {
        const s = 256 + i;
        const r = g.rules.items[i];
        depth_arr[s] = 1 + @max(depth_arr[r.a], depth_arr[r.b]);
        explen_arr[s] = explen_arr[r.a] + explen_arr[r.b];
        firstbyte_arr[s] = firstbyte_arr[r.a];
    }

    var num_defs_total: u32 = 0;
    var class_capacity = [_]u32{1} ** 256;
    for (0..g.rules.items.len) |i| {
        const s = 256 + i;
        if (reachable[s]) {
            num_defs_total += 1;
            class_capacity[firstbyte_arr[s]] += 1;
        }
    }

    return .{
        .alloc = alloc,
        .k = k,
        .reachable = reachable,
        .n_arr = n_arr,
        .depth_arr = depth_arr,
        .explen_arr = explen_arr,
        .firstbyte_arr = firstbyte_arr,
        .num_defs_total = num_defs_total,
        .class_capacity = class_capacity,
    };
}

// ------------------------------------------------------------------ encode --

pub const EncodeResult = struct {
    bytes: []u8,
    rules: usize,
    reachable_rules: usize,
    roots: usize,
};

const EncCtx = struct {
    enc: *rc.Encoder,
    raw: []const u8,
    rules: []const gprobe.Rule,
    st: *const Static,
    opts: Options,
    gm: *GammaModels,
    fm: *FlagModels,
    new_id_of_rule: []?u32,
    local_index_of_rule: []?u32,
    next_id: u32 = 256,
    write_pos: usize = 0,
    last_byte: u8 = 0,
    flat: *Fenwick,
    classes: []Fenwick,
    class_next_local: *[256]u32,
    fbyte_model: *AdaptiveByteModel,
    cache: *Cache,
    defs_left: u32,
    calls_left: u32,

    fn emit(self: *EncCtx, s: u32, call_depth: u32, slot: u2) !void {
        const already: ?u32 = if (s < 256) s else self.new_id_of_rule[s - 256];
        if (already) |target| {
            if (self.opts.exact_flag) {
                try encodeFlagUrn(self.enc, &self.defs_left, &self.calls_left, false);
            } else {
                try self.enc.encodeBit(&self.fm.m[@min(call_depth, 7)][slot], 0, RATE);
            }
            try self.encodeRef(s, target);
            const len: u32 = if (s < 256) 1 else self.st.explen_arr[s];
            self.write_pos += len;
            self.last_byte = self.raw[self.write_pos - 1];
        } else {
            if (self.opts.exact_flag) {
                try encodeFlagUrn(self.enc, &self.defs_left, &self.calls_left, true);
            } else {
                try self.enc.encodeBit(&self.fm.m[@min(call_depth, 7)][slot], 1, RATE);
            }
            const r = self.rules[s - 256];
            try self.emit(r.a, call_depth + 1, 1);
            try self.emit(r.b, call_depth + 1, 2);
            const ctx = ctxIndex(self.st.depth_arr[s], self.st.explen_arr[s], self.st.n_arr[r.a]);
            try encodeGamma(self.enc, self.gm, ctx, self.st.n_arr[s]);
            const nid = self.next_id;
            self.next_id += 1;
            self.new_id_of_rule[s - 256] = nid;
            if (self.opts.first_byte) {
                const f = self.st.firstbyte_arr[s];
                const lidx = self.class_next_local[f];
                self.class_next_local[f] += 1;
                self.local_index_of_rule[s - 256] = lidx;
                self.classes[f].add(lidx, self.st.n_arr[s]);
            } else {
                self.flat.add(nid, self.st.n_arr[s]);
            }
        }
    }

    fn encodeRef(self: *EncCtx, s_orig: u32, target_new_id: u32) !void {
        if (self.opts.cache) {
            if (self.cache.find(target_new_id)) |p| {
                try self.enc.encodeBit(&self.cache.hit_model, 1, RATE);
                var i: usize = 0;
                while (i < p) : (i += 1) try self.enc.encodeBit(&self.cache.pos_model[i], 1, RATE);
                try self.enc.encodeBit(&self.cache.pos_model[p], 0, RATE);
                self.cache.touch(target_new_id, p);
                self.decrementOnly(s_orig, target_new_id);
                return;
            }
            try self.enc.encodeBit(&self.cache.hit_model, 0, RATE);
        }
        try self.encodeRefBase(s_orig, target_new_id);
        if (self.opts.cache) self.cache.touch(target_new_id, null);
    }

    fn encodeRefBase(self: *EncCtx, s_orig: u32, target_new_id: u32) !void {
        if (self.opts.first_byte) {
            const f = self.st.firstbyte_arr[s_orig];
            const lidx: u32 = if (s_orig < 256) 0 else self.local_index_of_rule[s_orig - 256].?;
            const bt = &self.fbyte_model.trees[self.last_byte];
            const fcum = bt.cumBefore(f);
            const ffreq = bt.weightAt(f);
            try self.enc.encodeFreq(fcum, ffreq, @intCast(bt.total));
            bt.add(f, FB_INC);

            const tree = &self.classes[f];
            const cum = tree.cumBefore(lidx);
            const freq = tree.weightAt(lidx);
            try self.enc.encodeFreq(cum, freq, @intCast(tree.total));
            tree.add(lidx, -1);
        } else {
            const cum = self.flat.cumBefore(target_new_id);
            const freq = self.flat.weightAt(target_new_id);
            try self.enc.encodeFreq(cum, freq, @intCast(self.flat.total));
            self.flat.add(target_new_id, -1);
        }
    }

    fn decrementOnly(self: *EncCtx, s_orig: u32, target_new_id: u32) void {
        if (self.opts.first_byte) {
            const f = self.st.firstbyte_arr[s_orig];
            const lidx: u32 = if (s_orig < 256) 0 else self.local_index_of_rule[s_orig - 256].?;
            self.classes[f].add(lidx, -1);
        } else {
            self.flat.add(target_new_id, -1);
        }
    }
};

pub fn encode(alloc: std.mem.Allocator, raw: []const u8, min_freq: u32, opts: Options) !EncodeResult {
    var g = try gprobe.build(alloc, raw, raw.len, 1 << 24, min_freq, 50);
    var st = try computeStatic(alloc, &g);
    defer st.deinit();

    var enc = rc.Encoder.init(alloc);
    defer enc.deinit();

    var gm: GammaModels = .{};
    var fm: FlagModels = .{};
    var cache: Cache = .{};

    var fbyte_model: AdaptiveByteModel = undefined;
    if (opts.first_byte) fbyte_model = try AdaptiveByteModel.init(alloc);
    defer if (opts.first_byte) fbyte_model.deinit();

    var flat: Fenwick = try Fenwick.init(alloc, if (opts.first_byte) 1 else st.k);
    defer flat.deinit();
    var classes: []Fenwick = &[_]Fenwick{};
    if (opts.first_byte) {
        classes = try alloc.alloc(Fenwick, 256);
        for (0..256) |f| classes[f] = try Fenwick.init(alloc, st.class_capacity[f]);
    }
    defer if (opts.first_byte) {
        for (classes) |*c| c.deinit();
        alloc.free(classes);
    };

    const new_id_of_rule = try alloc.alloc(?u32, g.rules.items.len);
    defer alloc.free(new_id_of_rule);
    @memset(new_id_of_rule, null);
    var local_index_of_rule: []?u32 = &[_]?u32{};
    if (opts.first_byte) {
        local_index_of_rule = try alloc.alloc(?u32, g.rules.items.len);
        @memset(local_index_of_rule, null);
    }
    defer if (opts.first_byte) alloc.free(local_index_of_rule);

    var class_next_local = [_]u32{1} ** 256;

    var ctx = EncCtx{
        .enc = &enc,
        .raw = raw,
        .rules = g.rules.items,
        .st = &st,
        .opts = opts,
        .gm = &gm,
        .fm = &fm,
        .new_id_of_rule = new_id_of_rule,
        .local_index_of_rule = local_index_of_rule,
        .flat = &flat,
        .classes = classes,
        .class_next_local = &class_next_local,
        .fbyte_model = &fbyte_model,
        .cache = &cache,
        .defs_left = st.num_defs_total,
        .calls_left = @intCast(g.seq.len + 2 * @as(usize, st.num_defs_total)),
    };

    // Upfront: transmit n[byte] for the 256 bytes, and activate their slots.
    const byte_ctx = ctxIndex(0, 1, 0);
    for (0..256) |b| {
        try encodeGamma(&enc, &gm, byte_ctx, st.n_arr[b]);
        if (opts.first_byte) {
            classes[b].add(0, st.n_arr[b]);
        } else {
            flat.add(b, st.n_arr[b]);
        }
    }

    for (g.seq) |s| try ctx.emit(s, 0, 0);

    const coded = try enc.finish();

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "BZ4i");
    try out.append(alloc, 1);
    try out.append(alloc, opts.toByte());
    try appendU32LE(&out, alloc, @intCast(raw.len));
    try appendU32LE(&out, alloc, @intCast(g.seq.len));
    try appendU32LE(&out, alloc, st.num_defs_total);
    if (opts.first_byte) {
        for (0..256) |f| try appendU32LE(&out, alloc, st.class_capacity[f]);
    }
    try out.appendSlice(alloc, coded);

    return .{
        .bytes = try out.toOwnedSlice(alloc),
        .rules = g.rules.items.len,
        .reachable_rules = st.num_defs_total,
        .roots = g.seq.len,
    };
}

// ------------------------------------------------------------------ decode --

const DecCtx = struct {
    dec: *rc.Decoder,
    out: []u8,
    opts: Options,
    gm: *GammaModels,
    fm: *FlagModels,
    length_of: []u32,
    firstbyte_of: []u8,
    depth_of: []u32,
    offset_of: []u32,
    n_of: []u32,
    local_index_of_new: []u32,
    class_members: [][]u32,
    next_id: u32 = 256,
    write_pos: usize = 0,
    last_byte: u8 = 0,
    flat: *Fenwick,
    classes: []Fenwick,
    class_next_local: *[256]u32,
    fbyte_model: *AdaptiveByteModel,
    cache: *Cache,
    defs_left: u32,
    calls_left: u32,

    fn decEmit(self: *DecCtx, call_depth: u32, slot: u2) !u32 {
        const is_def = if (self.opts.exact_flag)
            decodeFlagUrn(self.dec, &self.defs_left, &self.calls_left)
        else
            self.dec.decodeBit(&self.fm.m[@min(call_depth, 7)][slot], RATE) == 1;

        if (!is_def) {
            const target = try self.decodeRef();
            if (target < 256) {
                self.out[self.write_pos] = @intCast(target);
                self.write_pos += 1;
            } else {
                const len = self.length_of[target];
                const off = self.offset_of[target];
                std.mem.copyForwards(u8, self.out[self.write_pos .. self.write_pos + len], self.out[off .. off + len]);
                self.write_pos += len;
            }
            self.last_byte = self.out[self.write_pos - 1];
            return target;
        } else {
            const start = self.write_pos;
            const left_id = try self.decEmit(call_depth + 1, 1);
            const right_id = try self.decEmit(call_depth + 1, 2);
            const depth_s = 1 + @max(self.depth_of[left_id], self.depth_of[right_id]);
            const explen_s: u32 = @intCast(self.write_pos - start);
            const ctx = ctxIndex(depth_s, explen_s, self.n_of[left_id]);
            const n_s = decodeGamma(self.dec, self.gm, ctx);
            const nid = self.next_id;
            self.next_id += 1;
            self.length_of[nid] = explen_s;
            self.firstbyte_of[nid] = self.firstbyte_of[left_id];
            self.depth_of[nid] = depth_s;
            self.offset_of[nid] = @intCast(start);
            self.n_of[nid] = n_s;
            if (self.opts.first_byte) {
                const f = self.firstbyte_of[nid];
                const lidx = self.class_next_local[f];
                self.class_next_local[f] += 1;
                self.local_index_of_new[nid] = lidx;
                self.class_members[f][lidx] = nid;
                self.classes[f].add(lidx, n_s);
            } else {
                self.flat.add(nid, n_s);
            }
            return nid;
        }
    }

    fn decodeRef(self: *DecCtx) !u32 {
        if (self.opts.cache) {
            if (self.dec.decodeBit(&self.cache.hit_model, RATE) == 1) {
                var p: usize = 0;
                while (self.dec.decodeBit(&self.cache.pos_model[p], RATE) == 1) p += 1;
                const target = self.cache.ids[p];
                self.cache.touch(target, p);
                self.decrementOnly(target);
                return target;
            }
        }
        const target = try self.decodeRefBase();
        if (self.opts.cache) self.cache.touch(target, null);
        return target;
    }

    fn decodeRefBase(self: *DecCtx) !u32 {
        if (self.opts.first_byte) {
            const bt = &self.fbyte_model.trees[self.last_byte];
            const v = self.dec.decodeFreq(@intCast(bt.total));
            const f: u8 = @intCast(bt.find(v));
            const fcum = bt.cumBefore(f);
            const ffreq = bt.weightAt(f);
            self.dec.consume(fcum, ffreq);
            bt.add(f, FB_INC);

            const tree = &self.classes[f];
            const v2 = tree.total;
            _ = v2;
            const tv = self.dec.decodeFreq(@intCast(tree.total));
            const lidx = tree.find(tv);
            const cum2 = tree.cumBefore(lidx);
            const freq2 = tree.weightAt(lidx);
            self.dec.consume(cum2, freq2);
            tree.add(lidx, -1);
            return self.class_members[f][lidx];
        } else {
            const v = self.dec.decodeFreq(@intCast(self.flat.total));
            const nid = self.flat.find(v);
            const cum = self.flat.cumBefore(nid);
            const freq = self.flat.weightAt(nid);
            self.dec.consume(cum, freq);
            self.flat.add(nid, -1);
            return @intCast(nid);
        }
    }

    fn decrementOnly(self: *DecCtx, target: u32) void {
        if (self.opts.first_byte) {
            const f = self.firstbyte_of[target];
            const lidx = self.local_index_of_new[target];
            self.classes[f].add(lidx, -1);
        } else {
            self.flat.add(target, -1);
        }
    }
};

pub fn decode(alloc: std.mem.Allocator, coded: []const u8) ![]u8 {
    var off: usize = 0;
    if (coded.len < 4 or !std.mem.eql(u8, coded[0..4], "BZ4i")) return error.BadMagic;
    off += 4;
    const version = coded[off];
    off += 1;
    if (version != 1) return error.BadVersion;
    const opts = Options.fromByte(coded[off]);
    off += 1;
    const raw_len = readU32LE(coded, &off);
    const roots_len = readU32LE(coded, &off);
    const num_defs_total = readU32LE(coded, &off);
    var class_capacity = [_]u32{0} ** 256;
    if (opts.first_byte) {
        for (0..256) |f| class_capacity[f] = readU32LE(coded, &off);
    }

    const k = 256 + @as(usize, num_defs_total);
    const out = try alloc.alloc(u8, raw_len);
    errdefer alloc.free(out);

    var dec = rc.Decoder.init(coded[off..]);

    var gm: GammaModels = .{};
    var fm: FlagModels = .{};
    var cache: Cache = .{};

    var fbyte_model: AdaptiveByteModel = undefined;
    if (opts.first_byte) fbyte_model = try AdaptiveByteModel.init(alloc);
    defer if (opts.first_byte) fbyte_model.deinit();

    var flat: Fenwick = try Fenwick.init(alloc, if (opts.first_byte) 1 else k);
    defer flat.deinit();
    var classes: []Fenwick = &[_]Fenwick{};
    var class_members: [][]u32 = &[_][]u32{};
    if (opts.first_byte) {
        classes = try alloc.alloc(Fenwick, 256);
        class_members = try alloc.alloc([]u32, 256);
        for (0..256) |f| {
            classes[f] = try Fenwick.init(alloc, class_capacity[f]);
            class_members[f] = try alloc.alloc(u32, class_capacity[f]);
        }
    }
    defer if (opts.first_byte) {
        for (classes) |*c| c.deinit();
        alloc.free(classes);
        for (class_members) |m| alloc.free(m);
        alloc.free(class_members);
    };

    const length_of = try alloc.alloc(u32, k);
    defer alloc.free(length_of);
    const firstbyte_of = try alloc.alloc(u8, k);
    defer alloc.free(firstbyte_of);
    const depth_of = try alloc.alloc(u32, k);
    defer alloc.free(depth_of);
    const offset_of = try alloc.alloc(u32, k);
    defer alloc.free(offset_of);
    const n_of = try alloc.alloc(u32, k);
    defer alloc.free(n_of);
    var local_index_of_new: []u32 = &[_]u32{};
    if (opts.first_byte) {
        local_index_of_new = try alloc.alloc(u32, k);
    }
    defer if (opts.first_byte) alloc.free(local_index_of_new);

    for (0..256) |b| {
        length_of[b] = 1;
        firstbyte_of[b] = @intCast(b);
        depth_of[b] = 0;
        offset_of[b] = 0;
        if (opts.first_byte) local_index_of_new[b] = 0;
    }

    var class_next_local = [_]u32{1} ** 256;
    const byte_ctx = ctxIndex(0, 1, 0);
    for (0..256) |b| {
        const n_b = decodeGamma(&dec, &gm, byte_ctx);
        n_of[b] = n_b;
        if (opts.first_byte) {
            classes[b].add(0, n_b);
            class_members[b][0] = @intCast(b);
        } else {
            flat.add(b, n_b);
        }
    }

    var ctx = DecCtx{
        .dec = &dec,
        .out = out,
        .opts = opts,
        .gm = &gm,
        .fm = &fm,
        .length_of = length_of,
        .firstbyte_of = firstbyte_of,
        .depth_of = depth_of,
        .offset_of = offset_of,
        .n_of = n_of,
        .local_index_of_new = local_index_of_new,
        .class_members = class_members,
        .flat = &flat,
        .classes = classes,
        .class_next_local = &class_next_local,
        .fbyte_model = &fbyte_model,
        .cache = &cache,
        .defs_left = num_defs_total,
        .calls_left = @intCast(@as(usize, roots_len) + 2 * @as(usize, num_defs_total)),
    };

    for (0..roots_len) |_| _ = try ctx.decEmit(0, 0);

    return out;
}
