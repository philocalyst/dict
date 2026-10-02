//! Token classes by exchange clustering.
//!
//! Maximises the class-bigram likelihood of the token sequences (each block,
//! and each entry body, is one sequence): every token in turn moves to the
//! class where `sum f(M[a][b]) - sum f(row) - sum f(col)` is largest, with
//! `f(x) = x log x` and `M` the class-to-class bigram counts. Evaluating a
//! move touches only the classes the token actually neighbours, so a sweep
//! costs about `classes * bigrams`, not `tokens * classes^2`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Parse = @import("encode_instrumented.zig").Parse;

/// Two classes are fixed. Class 0 holds the start of every sequence and raw
/// bytes; class 1 holds nothing but the point just after a cut, so that what
/// follows a shared prefix has a row of its own.
pub const start_class = 0;
pub const cut_class = 1;

const Bigram = struct { other: u32, count: u32 };

/// Returns the class of every token id (`0 .. 256 + entries`).
///
/// Only entries that `uses` says are taken from their bucket at least
/// `leader` times are clustered. A rarer entry follows its last child: it
/// takes that child's class, which is also the row its definition is named
/// in, so naming it costs almost nothing.
pub fn cluster(arena: Allocator, parse: Parse, uses: []const u32, classes: u16, sweeps: usize, leader: u32) ![]u16 {
    std.debug.assert(classes >= 3);
    const tokens = 256 + parse.entries();

    const seen = try arena.alloc(u32, tokens);
    @memset(seen[0..256], 0);
    @memcpy(seen[256..], uses);
    const anchor = try arena.alloc(u32, tokens + 2);
    for (anchor, 0..) |*a, t| a.* = @intCast(t);
    for (0..parse.entries()) |e| {
        // Entries may refer forward, so resolve each chain to its end.
        var t: u32 = @intCast(256 + e);
        while (t >= 256 and seen[t] < leader and anchor[t] == t) {
            const body = parse.body(t - 256);
            // A body that ends in a cut has no last child to follow.
            if (body[body.len - 1] >= Parse.cut) break;
            t = body[body.len - 1];
        }
        anchor[256 + e] = anchor[t];
    }

    // Distinct bigrams, as successor lists and as predecessor lists.
    var pairs: std.ArrayList(u64) = .empty;
    try pairs.ensureTotalCapacity(arena, parse.toks.len + parse.kids.len);
    for (0..parse.blocks()) |b| addSequence(&pairs, anchor, parse.block(b));
    for (0..parse.entries()) |e| addSequence(&pairs, anchor, parse.body(e));
    const succ = try Lists.init(arena, pairs.items, tokens + 2, false);
    const pred = try Lists.init(arena, pairs.items, tokens + 2, true);

    // Most frequent tokens first; the top ones seed the classes.
    const order = try arena.alloc(u32, tokens);
    const weight = try arena.alloc(u32, tokens);
    for (order, weight, 0..) |*o, *w, t| {
        o.* = @intCast(t);
        w.* = succ.total(@intCast(t)) + pred.total(@intCast(t));
    }
    const Ctx = struct {
        weight: []const u32,
        fn heavier(ctx: @This(), a: u32, b: u32) bool {
            return if (ctx.weight[a] != ctx.weight[b]) ctx.weight[a] > ctx.weight[b] else a < b;
        }
    };
    std.mem.sort(u32, order, Ctx{ .weight = weight }, Ctx.heavier);

    const class = try arena.alloc(u16, tokens + 2);
    @memset(class, start_class);
    class[tokens + 1] = cut_class;
    var movable: usize = 0;
    for (order) |t| {
        if (t < 256 or weight[t] == 0) continue;
        class[t] = @intCast(2 + movable % (classes - 2));
        movable += 1;
    }

    var x: Exchange = try .init(arena, classes);
    for (0..tokens + 2) |t| for (succ.of(@intCast(t))) |s| x.add(class[t], class[s.other], s.count);

    for (0..sweeps) |_| {
        var moved: usize = 0;
        for (order) |t| {
            if (t < 256 or weight[t] == 0) continue;
            x.gather(t, class, succ.of(t), pred.of(t));
            const from = class[t];
            x.shift(from, false);
            var best = from;
            var best_gain = x.gain(from);
            for (2..classes) |to| {
                const g = x.gain(@intCast(to));
                if (g > best_gain + 1e-9) {
                    best_gain = g;
                    best = @intCast(to);
                }
            }
            x.shift(best, true);
            class[t] = best;
            moved += @intFromBool(best != from);
        }
        if (moved == 0) break;
    }
    for (class[0..tokens], anchor[0..tokens]) |*c, a| c.* = class[a];
    return class[0..tokens];
}

/// The last two anchors stand for the start of a sequence and for a cut.
fn addSequence(pairs: *std.ArrayList(u64), anchor: []const u32, seq: []const u32) void {
    var prev = anchor[anchor.len - 2];
    for (seq) |tok| {
        if (tok >= Parse.cut) {
            prev = anchor[anchor.len - 1];
            continue;
        }
        pairs.appendAssumeCapacity(@as(u64, prev) << 32 | anchor[tok]);
        prev = anchor[tok];
    }
}

/// CSR adjacency: `of(t)` lists the distinct neighbours of `t` with counts.
const Lists = struct {
    off: []u32,
    items: []Bigram,

    fn init(arena: Allocator, pairs: []u64, nodes: usize, reversed: bool) !Lists {
        if (reversed) for (pairs) |*p| {
            p.* = p.* << 32 | p.* >> 32;
        };
        std.mem.sort(u64, pairs, {}, std.sort.asc(u64));
        const off = try arena.alloc(u32, nodes + 1);
        @memset(off, 0);
        var items: std.ArrayList(Bigram) = .empty;
        var i: usize = 0;
        while (i < pairs.len) {
            var j = i;
            while (j < pairs.len and pairs[j] == pairs[i]) j += 1;
            try items.append(arena, .{ .other = @truncate(pairs[i]), .count = @intCast(j - i) });
            off[@as(usize, @intCast(pairs[i] >> 32)) + 1] += 1;
            i = j;
        }
        for (off[1..], off[0 .. off.len - 1]) |*end, begin| end.* += begin;
        if (reversed) for (pairs) |*p| {
            p.* = p.* << 32 | p.* >> 32;
        };
        return .{ .off = off, .items = items.items };
    }

    fn of(l: Lists, t: u32) []const Bigram {
        return l.items[l.off[t]..l.off[t + 1]];
    }

    fn total(l: Lists, t: u32) u32 {
        var sum: u32 = 0;
        for (l.of(t)) |b| sum += b.count;
        return sum;
    }
};

const Exchange = struct {
    classes: usize,
    /// `m[a * classes + b]`: bigrams from class a to class b.
    m: []u32,
    row: []u32,
    col: []u32,
    /// The token under consideration: its bigrams to / from each class,
    /// the classes where those are non-zero, and its self-loops.
    to: []u32,
    from: []u32,
    to_touched: std.ArrayList(u16),
    from_touched: std.ArrayList(u16),
    self_loops: u32 = 0,
    out: u32 = 0,
    in: u32 = 0,

    fn init(arena: Allocator, classes: usize) !Exchange {
        const x: Exchange = .{
            .classes = classes,
            .m = try arena.alloc(u32, classes * classes),
            .row = try arena.alloc(u32, classes),
            .col = try arena.alloc(u32, classes),
            .to = try arena.alloc(u32, classes),
            .from = try arena.alloc(u32, classes),
            .to_touched = try .initCapacity(arena, classes),
            .from_touched = try .initCapacity(arena, classes),
        };
        inline for (.{ x.m, x.row, x.col, x.to, x.from }) |list| @memset(list, 0);
        return x;
    }

    fn add(x: *Exchange, a: u16, b: u16, count: u32) void {
        x.m[a * x.classes + b] += count;
        x.row[a] += count;
        x.col[b] += count;
    }

    fn gather(x: *Exchange, t: u32, class: []const u16, succ: []const Bigram, pred: []const Bigram) void {
        for (x.to_touched.items) |c| x.to[c] = 0;
        for (x.from_touched.items) |c| x.from[c] = 0;
        x.to_touched.clearRetainingCapacity();
        x.from_touched.clearRetainingCapacity();
        x.self_loops = 0;
        x.out = 0;
        x.in = 0;
        for (succ) |s| {
            x.out += s.count;
            if (s.other == t) {
                x.self_loops = s.count;
                continue;
            }
            const c = class[s.other];
            if (x.to[c] == 0) x.to_touched.appendAssumeCapacity(c);
            x.to[c] += s.count;
        }
        for (pred) |p| {
            x.in += p.count;
            if (p.other == t) continue;
            const c = class[p.other];
            if (x.from[c] == 0) x.from_touched.appendAssumeCapacity(c);
            x.from[c] += p.count;
        }
    }

    /// Adds the gathered token to class `c`, or takes it out.
    fn shift(x: *Exchange, c: u16, comptime in: bool) void {
        const Op = struct {
            inline fn apply(v: *u32, d: u32) void {
                if (in) v.* += d else v.* -= d;
            }
        };
        for (x.to_touched.items) |o| Op.apply(&x.m[c * x.classes + o], x.to[o]);
        for (x.from_touched.items) |o| Op.apply(&x.m[o * x.classes + c], x.from[o]);
        Op.apply(&x.m[c * x.classes + c], x.self_loops);
        Op.apply(&x.row[c], x.out);
        Op.apply(&x.col[c], x.in);
    }

    /// Change in the objective if the gathered token joined class `c`.
    fn gain(x: *const Exchange, c: u16) f64 {
        var g: f64 = 0;
        const diagonal = x.m[c * x.classes + c];
        var diagonal_add = x.self_loops;
        for (x.to_touched.items) |o| {
            if (o == c) diagonal_add += x.to[o] else g += delta(x.m[c * x.classes + o], x.to[o]);
        }
        for (x.from_touched.items) |o| {
            if (o == c) diagonal_add += x.from[o] else g += delta(x.m[o * x.classes + c], x.from[o]);
        }
        g += delta(diagonal, diagonal_add);
        return g - delta(x.row[c], x.out) - delta(x.col[c], x.in);
    }

    fn delta(base: u32, more: u32) f64 {
        return xlogx(base + more) - xlogx(base);
    }

    fn xlogx(v: u32) f64 {
        const f: f64 = @floatFromInt(v);
        return if (v < 2) 0 else f * @log2(f);
    }
};
