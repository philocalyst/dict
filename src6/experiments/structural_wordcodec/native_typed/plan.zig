//! The baseline planner: the least that turns a parse into a plan.
//!
//! It gives every repeated byte value an arity-1 entry, so that bytes are
//! coded by frequency like any other token instead of as 8 raw bits; it
//! clusters tokens into classes; and it buckets each class's entries by how
//! often they are reused. Recency needs no planning: the past buckets are
//! always there, and the encoder uses them wherever they are cheaper.
//!
//! Smarter planners keep this shape and change the bucket map and the rows.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model_ = @import("model.zig");
const Model = model_.Model;
const encode = @import("encode.zig");
const classes = @import("classes.zig");
const Parse = encode.Parse;

pub const Options = struct {
    log: u8 = 11,
    /// Token classes; the class of the previous token selects the row.
    /// 0 lets `fit` choose.
    classes: u16 = 0,
    sweeps: usize = 6,
    /// Occurrences a token needs to be clustered rather than follow its last child.
    leader: u32 = 3,
    /// A bucket with at least 1/`direct` of all uses is coded in one step
    /// instead of class-then-tier (0: none are).
    direct: u32 = 256,
    /// Tiers of the window on each stream's own past (0: none).
    ring: u8 = 10,
    /// Give repeated byte values entries of their own.
    alias: bool = true,
    hoist: bool = false,
    table_slack: f64 = 0.001,
    /// Allow a first-use GEN surface to enter the ordinary PAST window.
    gen: bool = true,
    /// Zero searches 12/16/24 byte minimum exact spans plus no GEN.
    gen_min_match: u8 = 0,
    /// How often each entry of the (aliased) parse was taken from its bucket
    /// in an earlier encode of the same input. An entry that the past always
    /// serves needs no class or bucket of its own. Null: assume every use.
    bucket_uses: ?[]const u32 = null,
};

fn countUses(arena: Allocator, parse: Parse) ![]u32 {
    const uses = try arena.alloc(u32, parse.entries());
    @memset(uses, 0);
    for (parse.kids) |kid| if (kid >= 256 and kid < Parse.cut) {
        uses[kid - 256] += 1;
    };
    for (parse.toks) |tok| if (tok >= 256) {
        uses[tok - 256] += 1;
    };
    return uses;
}

/// Every byte value used at least 8 times becomes an arity-1 entry (an alias
/// costs about 22 bits to define and saves 3 to 4 per use; pricing each byte
/// by its order-0 share instead was tried and lost). New entry `i` has id
/// `256 + old + i`.
fn aliasBytes(arena: Allocator, parse: Parse) !Parse {
    var seen: [256]u32 = @splat(0);
    for (parse.kids) |kid| if (kid < 256) {
        seen[kid] += 1;
    };
    for (parse.toks) |tok| if (tok < 256) {
        seen[tok] += 1;
    };
    var map: [256]u32 = undefined;
    var aliased: std.ArrayList(u32) = .empty;
    for (&map, seen, 0..) |*to, count, byte| {
        to.* = if (count >= 8) @intCast(256 + parse.entries() + aliased.items.len) else @intCast(byte);
        if (count >= 8) try aliased.append(arena, @intCast(byte));
    }
    const body_off = try arena.alloc(u32, parse.body_off.len + aliased.items.len);
    const kids = try arena.alloc(u32, parse.kids.len + aliased.items.len);
    const toks = try arena.alloc(u32, parse.toks.len);
    @memcpy(body_off[0..parse.body_off.len], parse.body_off);
    for (kids[0..parse.kids.len], parse.kids) |*to, kid| to.* = if (kid < 256) map[kid] else kid;
    for (toks, parse.toks) |*to, tok| to.* = if (tok < 256) map[tok] else tok;
    for (aliased.items, 0..) |byte, i| {
        kids[parse.kids.len + i] = byte;
        body_off[parse.body_off.len + i] = @intCast(parse.kids.len + i + 1);
    }
    return .{ .body_off = body_off, .kids = kids, .block_off = parse.block_off, .toks = toks };
}

/// The options `fit` settled on, and the frame they give.
pub const Fit = struct { options: Options, bytes: []u8 };

/// Plans and encodes with more and more classes until the frame stops
/// shrinking: a small input cannot pay for a big model. Every class count
/// is planned twice, the second time knowing which uses the past took over.
/// `bytes` belongs to `gpa`; everything else comes from `arena`.
pub fn fit(arena: Allocator, gpa: Allocator, input: Parse, options: Options) !Fit {
    if (options.gen and options.gen_min_match == 0) {
        var selected: ?Fit = null;
        errdefer if (selected) |s| gpa.free(s.bytes);
        for ([_]u8{ 12, 16, 24 }) |threshold| {
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            var trial = options;
            trial.gen_min_match = threshold;
            const candidate = try fit(scratch.allocator(), gpa, input, trial);
            if (selected) |s| {
                if (candidate.bytes.len >= s.bytes.len) {
                    gpa.free(candidate.bytes);
                    continue;
                }
                gpa.free(s.bytes);
            }
            selected = candidate;
        }
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        var baseline_options = options;
        baseline_options.gen = false;
        const control = try fit(scratch.allocator(), gpa, input, baseline_options);
        if (control.bytes.len <= selected.?.bytes.len) {
            gpa.free(selected.?.bytes);
            return control;
        }
        gpa.free(control.bytes);
        return selected.?;
    }
    var best: ?Fit = null;
    errdefer if (best) |b| gpa.free(b.bytes);
    const tries: []const u16 = if (options.classes != 0) &.{options.classes} else &.{ 1, 4, 8, 16, 32, 64, 128 };
    for (tries) |class_count| {
        var trial = options;
        trial.classes = class_count;
        trial.bucket_uses = null;
        var first = try baseline(arena, input, trial);
        var measured: encode.Stats = .{ .entry_bits = try arena.alloc(f64, first.parse.entries()), .entry_uses = try arena.alloc(u32, first.parse.entries()) };
        @memset(measured.entry_bits.?, 0);
        @memset(measured.entry_uses.?, 0);
        gpa.free(try encode.encode(gpa, &first, &measured));
        trial.bucket_uses = measured.entry_uses;
        var second = try baseline(arena, input, trial);
        const bytes = try encode.encode(gpa, &second, null);
        if (best) |b| if (bytes.len >= b.bytes.len) {
            gpa.free(bytes);
            // GEN changes the class optimum non-monotonically. Search the
            // complete declared class set and charge all rejected fits.
            if (options.gen) continue;
            break;
        } else gpa.free(b.bytes);
        best = .{ .options = trial, .bytes = bytes };
    }
    return best.?;
}

const Use = struct { entry: u32, count: u32 };

fn moreReused(_: void, a: Use, b: Use) bool {
    return if (a.count != b.count) a.count > b.count else a.entry < b.entry;
}

/// All plan memory comes from `arena`.
pub fn baseline(arena: Allocator, input: Parse, options: Options) !encode.Plan {
    const parse = if (options.alias) try aliasBytes(arena, input) else input;
    const n = parse.entries();
    const uses = try countUses(arena, parse);
    if (options.bucket_uses) |measured| for (uses, measured) |*count, taken| {
        count.* = 1 + taken;
    };
    const class_count: u16 = if (options.classes < 3) 1 else options.classes;
    const class = if (class_count > 1) try classes.cluster(arena, parse, uses, class_count, options.sweeps, options.leader) else blk: {
        const none = try arena.alloc(u16, 256 + n);
        @memset(none, 0);
        break :blk none;
    };

    // Buckets: the bytes, the past, then class by class. A class's entries
    // are walked from most to least reused and cut into power-of-two runs
    // whose reuse counts stay within a factor of two; entries never reused
    // are only ever named, so they share one bucket.
    const bucket = try arena.alloc(u16, n);
    var widths: std.ArrayList(u8) = .empty;
    var bucket_class: std.ArrayList(u16) = .empty;
    var reused: std.ArrayList(Use) = .empty;
    try widths.append(arena, 8);
    for (0..options.ring) |tier| try widths.append(arena, @intCast(tier));
    try bucket_class.appendNTimes(arena, classes.start_class, widths.items.len);
    for (0..class_count) |c| {
        reused.clearRetainingCapacity();
        for (uses, 0..) |count, e| if (class[256 + e] == c) try reused.append(arena, .{ .entry = @intCast(e), .count = count -| 1 });
        std.mem.sort(Use, reused.items, {}, moreReused);
        var rest = reused.items;
        while (rest.len != 0) {
            var run: usize = 1;
            while (run < rest.len and rest[run].count != 0 and rest[run].count >= rest[0].count / 2) run += 1;
            const width: u8 = if (rest[0].count == 0) std.math.log2_int_ceil(usize, rest.len) else std.math.log2_int(usize, run);
            const take = @min(rest.len, @as(usize, 1) << @intCast(width));
            for (rest[0..take]) |use| bucket[use.entry] = @intCast(widths.items.len);
            try widths.append(arena, width);
            try bucket_class.append(arena, @intCast(c));
            rest = rest[take..];
        }
    }

    // Rows, for C classes. A token is spelled class-then-tier:
    //   c          after a token of class c (row 0 starts a block, row 1
    //              follows a cut)
    //   C + f      after the first use, in the payload, of a token of class f
    //   B = 2C     starts a body
    //   T + k      which bucket of class k; leads to row k (T = B + 1)
    //   A = T+C    arities
    //   A+1 + c    names after a last child of class c: silent "class k"
    //   A+1+C + k  names which bucket of class k; leads to row k
    //   A+1+2C     bytes kept by a cut
    // Every context row (the first T) codes DEF, CUT, a past bucket, a busy
    // bucket, or a silent "class k".
    var most: usize = 1;
    for (0..n) |e| most = @max(most, parse.body(e).len);
    for (parse.kids) |kid| if (kid >= Parse.cut) {
        most = @max(most, kid - Parse.cut);
    };
    const buckets = widths.items.len;
    const hush: u16 = @intCast(@max(buckets + 2, most) + 1);
    const c_n = class_count;
    const body_row = 2 * c_n;
    const tiers = body_row + 1;
    const arity_row = tiers + c_n;
    var m: Model = try .init(arena, options.log, buckets, arity_row + 2 * c_n + 2, hush + c_n);
    m.silent = c_n;
    m.ring = options.ring;
    @memcpy(m.widths, widths.items);
    m.arity_row = arity_row;
    m.cut_row = arity_row + 2 * c_n + 1;
    for (m.plain[arity_row..]) |*plain| plain.* = true;
    for (m.name_row[0..tiers], m.first_row[0..tiers], 0..) |*name, *first, r| {
        name.* = @intCast(arity_row + 1 + if (r < c_n) r else 0);
        first.* = @intCast(c_n + if (r < c_n) r else 0);
    }

    // Busy buckets and the past are coded in one step, straight from the
    // context row; the rest go class-then-tier. Naming always does.
    const name_via = try arena.alloc(u16, m.alphabet);
    const via = try arena.alloc(u16, m.alphabet);
    @memset(name_via, 0);
    @memset(via, 0);
    const busy = try arena.alloc(u64, buckets);
    @memset(busy, 0);
    var all_uses: u64 = 0;
    for (uses, bucket) |count, b| {
        busy[b] += count -| 1;
        all_uses += count -| 1;
    }
    for (bucket_class.items, busy, 0..) |k, reuses, b| {
        name_via[b] = hush + k;
        const direct = m.isPast(@intCast(b)) or (options.direct != 0 and reuses * options.direct >= all_uses);
        if (!direct) via[b] = hush + k;
    }

    @memset(m.next[m.cell(arity_row, 0)..][0..m.alphabet], body_row);
    @memset(m.next[m.cell(m.cut_row, 0)..][0..m.alphabet], @min(classes.cut_class, c_n - 1));
    for (0..tiers) |row| for (0..c_n) |k| {
        m.next[m.cell(@intCast(row), @intCast(hush + k))] = @intCast(tiers + k);
    };
    for (0..c_n) |c| for (0..c_n) |k| {
        m.next[m.cell(@intCast(arity_row + 1 + c), @intCast(hush + k))] = @intCast(arity_row + 1 + c_n + k);
    };
    for (bucket_class.items, 0..) |k, b| {
        for (0..tiers) |row| m.next[m.cell(@intCast(row), @intCast(b))] = k;
        m.next[m.cell(tiers + k, @intCast(b))] = k;
        m.next[m.cell(arity_row + 1 + c_n + k, @intCast(b))] = k;
    }
    return .{ .parse = parse, .bucket = bucket, .via = via, .name_via = name_via, .model = m, .hoist = options.hoist, .table_slack = options.table_slack, .gen_enabled = options.gen, .gen_min_match = options.gen_min_match };
}

/// Dissolves every entry whose uses, at the prices a real encode measured,
/// cost more than spelling its body each time would; `overhead` is what a
/// definition adds to its body. Returns the spliced, renumbered parse.
pub fn prune(arena: Allocator, parse: Parse, entry_bits: []const f64, entry_uses: []const u32, overhead: f64) !Parse {
    const n = parse.entries();
    const price = try arena.alloc(f64, 256 + n);
    @memset(price[0..256], 10);
    for (price[256..], entry_bits[0..n], entry_uses[0..n]) |*p, bits_, count| p.* = if (count == 0) 0 else bits_ / @as(f64, @floatFromInt(count));

    // A body with a cut stays whole (the payload has no cuts), and so does
    // the source of a cut (a cut shortens one token).
    const fixed = try arena.alloc(bool, n);
    @memset(fixed, false);
    for (0..n) |e| for (parse.body(e), 0..) |kid, i| if (kid >= Parse.cut) {
        fixed[e] = true;
        if (parse.body(e)[i - 1] >= 256) fixed[parse.body(e)[i - 1] - 256] = true;
    };

    const gone = try arena.alloc(bool, n);
    var any = false;
    for (gone, 0..) |*g, e| {
        var body: f64 = 0;
        var priced = !fixed[e];
        for (parse.body(e)) |kid| {
            if (kid >= Parse.cut or price[kid] == 0) priced = false else body += price[kid];
        }
        const count: f64 = @floatFromInt(entry_uses[e]);
        g.* = priced and entry_uses[e] != 0 and parse.body(e).len > 1 and count * body < entry_bits[e] + overhead;
        any = any or g.*;
    }
    if (!any) return parse;

    const renumber = try arena.alloc(u32, n);
    var kept: u32 = 0;
    for (renumber, gone) |*to, g| {
        to.* = 256 + kept;
        kept += @intFromBool(!g);
    }
    const Splice = struct {
        parse: Parse,
        gone: []const bool,
        renumber: []const u32,
        fn into(sp: @This(), a: Allocator, out: *std.ArrayList(u32), tok: u32) !void {
            if (tok < 256 or tok >= Parse.cut) return out.append(a, tok);
            if (!sp.gone[tok - 256]) return out.append(a, sp.renumber[tok - 256]);
            for (sp.parse.body(tok - 256)) |kid| try sp.into(a, out, kid);
        }
    };
    const splice: Splice = .{ .parse = parse, .gone = gone, .renumber = renumber };
    var kids: std.ArrayList(u32) = .empty;
    var body_off: std.ArrayList(u32) = .empty;
    try body_off.append(arena, 0);
    for (0..n) |e| if (!gone[e]) {
        for (parse.body(e)) |kid| try splice.into(arena, &kids, kid);
        try body_off.append(arena, @intCast(kids.items.len));
    };
    var toks: std.ArrayList(u32) = .empty;
    const block_off = try arena.alloc(u32, parse.block_off.len);
    for (0..parse.blocks()) |b| {
        block_off[b] = @intCast(toks.items.len);
        for (parse.block(b)) |tok| try splice.into(arena, &toks, tok);
    }
    block_off[parse.blocks()] = @intCast(toks.items.len);
    return .{ .body_off = body_off.items, .kids = kids.items, .block_off = block_off, .toks = toks.items };
}
