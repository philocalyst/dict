//! c_ctx DUMP — est: what exact-context successor lists are worth.
//!
//! The token stream of a parse is coded with keyed lists: the context (the
//! previous k tokens) owns a list of successors. A hit is a tier symbol plus
//! tier raw bits, a miss is an escape to the next shorter context and finally
//! to a static order-0 code with a free first use. All probabilities are
//! static (two passes), conditioned only on what a decoder has for free: how
//! full the list is and how the context's last two visits went.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Parse = struct {
    body_off: []u32,
    kids: []u32,
    block_off: []u32,
    toks: []u32,
};

pub fn readDump(gpa: Allocator, words: []const u32) !Parse {
    if (words.len < 6 or words[0] != 0x44533442) return error.NotADump;
    const version = words[1];
    const entries = words[2];
    const blocks = words[3];
    var at: usize = 6;
    const body_off = try gpa.alloc(u32, entries + 1);
    var kids: std.ArrayList(u32) = .empty;
    for (0..entries) |e| {
        body_off[e] = @intCast(kids.items.len);
        const arity = if (version == 1) 2 else blk: {
            at += 1;
            break :blk words[at - 1];
        };
        try kids.appendSlice(gpa, words[at..][0..arity]);
        at += arity;
    }
    body_off[entries] = @intCast(kids.items.len);
    const block_off = try gpa.alloc(u32, blocks + 1);
    var toks: std.ArrayList(u32) = .empty;
    for (0..blocks) |b| {
        block_off[b] = @intCast(toks.items.len);
        try toks.appendSlice(gpa, words[at + 1 ..][0..words[at]]);
        at += 1 + words[at];
    }
    block_off[blocks] = @intCast(toks.items.len);
    return .{ .body_off = body_off, .kids = kids.items, .block_off = block_off, .toks = toks.items };
}

/// Static two-pass code: events are (context, symbol); cost is the empirical
/// conditional entropy, which tANS reaches within a fraction of a percent.
const Tally = struct {
    pairs: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    totals: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    raw: u64 = 0,

    fn add(t: *Tally, gpa: Allocator, ctx: u32, sym: u32, raw: u32) !void {
        (try t.pairs.getOrPutValue(gpa, @as(u64, ctx) << 32 | sym, 0)).value_ptr.* += 1;
        (try t.totals.getOrPutValue(gpa, ctx, 0)).value_ptr.* += 1;
        t.raw += raw;
    }

    fn bits(t: *const Tally) f64 {
        var sum: f64 = 0;
        var it = t.pairs.iterator();
        while (it.next()) |kv| {
            const c: f64 = @floatFromInt(kv.value_ptr.*);
            const n: f64 = @floatFromInt(t.totals.get(@intCast(kv.key_ptr.* >> 32)).?);
            sum -= c * std.math.log2(c / n);
        }
        return sum + @as(f64, @floatFromInt(t.raw));
    }
};

const Order = enum { append, mtf };
const Keep = enum { always, oracle };

const List = struct {
    items: std.ArrayListUnmanaged(u32) = .empty,
    history: u2 = 0,
};

fn tier(rank: usize) u32 {
    return std.math.log2_int(usize, rank + 1);
}

const Options = struct {
    orders: u8 = 1,
    order: Order = .append,
    keep: Keep = .oracle,
    history: bool = true,
    recency: u8 = 0, // log2 size of a global recency list tried after the contexts miss
    cap: u32 = 1 << 12, // a list never grows past this
};

const esc_keep = 100;
const esc_drop = 101;
const first_use = 0xffff_ffff;

fn key(stream: []const u32, i: usize, k: u8) u64 {
    var h: u64 = k;
    for (0..k) |j| {
        const t: u64 = if (i > j) stream[i - 1 - j] else 0xffff_fff0;
        h = (h ^ t) *% 0x9e37_79b9_7f4a_7c15;
        h ^= h >> 29;
    }
    return h;
}

fn estimate(gpa: Allocator, stream: []const u32, opt: Options) !struct { total: f64, ctx: f64, global: f64, hits: [4]u64 } {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // How often each (context, token) pair occurs in all: the oracle.
    var future: std.AutoHashMapUnmanaged(u128, u32) = .empty;
    if (opt.keep == .oracle) for (1..opt.orders + 1) |k| for (stream, 0..) |t, i| {
        (try future.getOrPutValue(arena, @as(u128, key(stream, i, @intCast(k))) << 32 | t, 0)).value_ptr.* += 1;
    };

    var lists: std.AutoHashMapUnmanaged(u64, List) = .empty;
    var ctx_tally: Tally = .{};
    var global: Tally = .{};
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var recent: std.ArrayListUnmanaged(u32) = .empty;
    var hits: [4]u64 = @splat(0);

    for (stream, 0..) |t, i| {
        var coded = false;
        var k: u8 = opt.orders;
        while (k > 0 and !coded) : (k -= 1) {
            const slot = try lists.getOrPutValue(arena, key(stream, i, k), .{});
            const list = slot.value_ptr;
            const fill: u32 = if (list.items.items.len == 0) 0 else tier(list.items.items.len - 1) + 1;
            const ctx = (@as(u32, k) << 16) | (fill << 2) | (if (opt.history) list.history else 0);
            if (std.mem.indexOfScalar(u32, list.items.items, t)) |rank| {
                try ctx_tally.add(arena, ctx, tier(rank), tier(rank));
                if (opt.order == .mtf) {
                    std.mem.copyBackwards(u32, list.items.items[1 .. rank + 1], list.items.items[0..rank]);
                    list.items.items[0] = t;
                }
                list.history = list.history << 1 | 1;
                hits[k] += 1;
                coded = true;
            } else {
                const again = opt.keep == .always or future.get(@as(u128, key(stream, i, k)) << 32 | t).? > 1;
                if (fill != 0 or opt.keep == .oracle) try ctx_tally.add(arena, ctx, if (again) esc_keep else esc_drop, 0);
                if (again and list.items.items.len < opt.cap) switch (opt.order) {
                    .append => try list.items.append(arena, t),
                    .mtf => try list.items.insert(arena, 0, t),
                };
                list.history <<= 1;
            }
        }
        if (!coded and opt.recency != 0) {
            if (std.mem.indexOfScalar(u32, recent.items, t)) |rank| {
                try global.add(arena, 1, 200 + tier(rank), tier(rank));
                _ = recent.orderedRemove(rank);
                coded = true;
                hits[0] += 1;
            } else try global.add(arena, 1, 199, 0);
        }
        if (opt.recency != 0) {
            if (coded) {
                if (std.mem.indexOfScalar(u32, recent.items, t)) |rank| _ = recent.orderedRemove(rank);
            }
            try recent.insert(arena, 0, t);
            if (recent.items.len > @as(usize, 1) << @intCast(opt.recency)) recent.items.len -= 1;
        }
        if (!coded) {
            const new = !seen.contains(t);
            try global.add(arena, 0, if (new) first_use else t, 0);
        }
        try seen.put(arena, t, {});
    }
    const c = ctx_tally.bits();
    const g = global.bits();
    return .{ .total = (c + g) / 8, .ctx = c / 8, .global = g / 8, .hits = hits };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const dump_path = args.next() orelse return error.Usage;
    const dump = try std.Io.Dir.cwd().readFileAllocOptions(init.io, dump_path, gpa, .limited(1 << 31), .of(u32), null);
    const parse = try readDump(gpa, std.mem.bytesAsSlice(u32, dump));

    // The delta as one stream too: bodies in entry order, a boundary token between them.
    var bodies: std.ArrayList(u32) = .empty;
    for (0..parse.body_off.len - 1) |e| {
        try bodies.append(gpa, 0xffff_ff00);
        try bodies.appendSlice(gpa, parse.kids[parse.body_off[e]..parse.body_off[e + 1]]);
    }

    const streams = [_]struct { name: []const u8, toks: []const u32 }{
        .{ .name = "payload", .toks = parse.toks },
        .{ .name = "bodies", .toks = bodies.items },
    };
    for (streams) |s| {
        std.debug.print("{s}: {d} tokens\n", .{ s.name, s.toks.len });
        const base = try estimate(gpa, s.toks, .{ .orders = 0 });
        std.debug.print("  order-0 static, first use free      {d:>10.0} bytes\n", .{base.total});
        const variants = [_]Options{
            .{ .orders = 1, .keep = .always, .history = false },
            .{ .orders = 1, .keep = .always },
            .{ .orders = 1 },
            .{ .orders = 1, .order = .mtf },
            .{ .orders = 2 },
            .{ .orders = 2, .order = .mtf },
            .{ .orders = 3 },
            .{ .orders = 2, .recency = 6 },
            .{ .orders = 2, .recency = 10 },
            .{ .orders = 0, .recency = 10 },
        };
        for (variants) |v| {
            const r = try estimate(gpa, s.toks, v);
            std.debug.print("  orders={d} {s:<6} {s:<6} hist={d} rec={d:<2}  {d:>10.0} bytes ({d:>5.1} %)  ctx={d:.0} global={d:.0} hits o1={d} o2={d} o3={d} rec={d}\n", .{
                v.orders,            @tagName(v.order), @tagName(v.keep), @intFromBool(v.history), v.recency,
                r.total,             100 * r.total / base.total - 100,
                r.ctx,               r.global,
                r.hits[1],           r.hits[2],
                r.hits[3],           r.hits[0],
            });
        }
    }
}
