//! Encoding a plan: a parse of the input into tokens, a bucket for every
//! lexicon entry, and a model skeleton (everything but the frequencies).
//!
//! The encoder walks the blocks to place each definition at its first use
//! and to learn which row every symbol is coded in, counts, normalises, and
//! then writes each stream last-symbol-first. A token that is still within
//! reach in its stream's past can be coded from there instead of from its
//! bucket; the walk is repeated so that this choice is made at the prices
//! the previous walk's counts imply. The cost model is the code.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bits = @import("bits.zig");
const binary = @import("binary.zig");
const tans = @import("tans.zig");
const frame = @import("frame.zig");
const model_ = @import("model.zig");
const Model = model_.Model;

/// Token ids below 256 are bytes; `256 + e` is lexicon entry `e`. In a body,
/// `cut + n` keeps only the first `n` bytes of the child before it (which
/// must be a byte or an entry that is defined by then).
pub const Parse = struct {
    body_off: []const u32,
    kids: []const u32,
    block_off: []const u32,
    toks: []const u32,

    pub const cut: u32 = 0xffff_ff00;

    pub fn entries(p: Parse) usize {
        return p.body_off.len - 1;
    }
    pub fn blocks(p: Parse) usize {
        return p.block_off.len - 1;
    }
    pub fn body(p: Parse, e: usize) []const u32 {
        return p.kids[p.body_off[e]..p.body_off[e + 1]];
    }
    pub fn block(p: Parse, b: usize) []const u32 {
        return p.toks[p.block_off[b]..p.block_off[b + 1]];
    }

    /// Expanded byte length of every entry (bodies may refer forward).
    pub fn lengths(p: Parse, gpa: Allocator) ![]u32 {
        const len = try gpa.alloc(u32, p.entries());
        errdefer gpa.free(len);
        @memset(len, 0);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(gpa);
        for (0..p.entries()) |root| {
            try stack.append(gpa, @intCast(root));
            while (stack.items.len != 0) {
                const e = stack.items[stack.items.len - 1];
                var sum: u32 = 0;
                var last: u32 = 0;
                var ready = true;
                for (p.body(e)) |kid| {
                    if (kid >= cut) {
                        sum = sum - last + (kid - cut);
                        continue;
                    }
                    last = if (kid < 256) 1 else len[kid - 256];
                    if (last == 0) {
                        try stack.append(gpa, kid - 256);
                        ready = false;
                    }
                    sum += last;
                }
                if (ready) {
                    len[e] = sum;
                    _ = stack.pop();
                }
            }
        }
        return len;
    }
};

pub const Plan = struct {
    parse: Parse,
    /// Bucket of each entry: never the byte bucket or a past bucket.
    bucket: []const u16,
    /// Per symbol: the silent symbol that must precede it in a token row
    /// (`via`) or when naming (`name_via`); 0 for none.
    via: []const u16,
    name_via: []const u16,
    /// `norm` and `logs` are filled in by `encode`.
    model: Model,
    /// Each row's table is the smallest whose coded size stays within this
    /// fraction of the best: smaller tables are cache-hot and decode faster.
    table_slack: f64 = 0.001,
    /// Define every entry in a leading payload-less block, so that each
    /// payload depends only on that block (random access).
    hoist: bool = false,
    /// Walks over the input. The first never looks back; each later one
    /// prices its choices with the previous one's counts.
    passes: u8 = 4,
};

const Event = struct { row: u16, sym: u16, index: u32 = 0, entry: u32 = no_entry };
const no_entry = std.math.maxInt(u32);

/// Where the bits went: events and bits by stream and symbol kind.
pub const Stats = struct {
    pub const Kind = enum { use, past, def, arity, cut, name, silent };
    pub const Line = struct { events: u64 = 0, coded_bits: f64 = 0, raw_bits: u64 = 0 };
    delta: std.EnumArray(Kind, Line) = .initFill(.{}),
    payload: std.EnumArray(Kind, Line) = .initFill(.{}),
    /// If set (one per plan entry): bits and count of each entry's uses from
    /// its bucket, silent steps included. The real price list.
    entry_bits: ?[]f64 = null,
    entry_uses: ?[]u32 = null,
    /// If set (one per parse token, streaming placement): every bit the
    /// token caused, its definition included.
    token_bits: ?[]f64 = null,
    /// Research-only exact first-use overhead attribution by token occurrence.
    token_name_bits: ?[]f64 = null,
    token_def_bits: ?[]f64 = null,

    fn price(m: Model, events: []const Event) f64 {
        var sum: f64 = 0;
        for (events) |ev| sum += tans.cost(m.norm[m.cell(ev.row, ev.sym)], m.logs[ev.row]) + @as(f64, @floatFromInt(m.width(ev.row, ev.sym)));
        return sum;
    }

    fn priceKind(m: Model, events: []const Event, wanted: Kind) f64 {
        var sum: f64 = 0;
        for (events) |ev| {
            const kind: Kind = if (ev.sym >= m.hush()) .silent else if (ev.row == m.arity_row) .arity else if (ev.row == m.cut_row or ev.sym == m.cut()) .cut else if (m.plain[ev.row]) .name else if (ev.sym == m.def()) .def else if (m.isPast(ev.sym)) .past else .use;
            if (kind == wanted) sum += tans.cost(m.norm[m.cell(ev.row, ev.sym)], m.logs[ev.row]) + @as(f64, @floatFromInt(m.width(ev.row, ev.sym)));
        }
        return sum;
    }

    fn add(stats: *Stats, m: Model, events: []const Event, comptime stream: Walk.Stream) void {
        for (events) |ev| {
            const kind: Kind = if (ev.sym >= m.hush()) .silent else if (ev.row == m.arity_row) .arity else if (ev.row == m.cut_row or ev.sym == m.cut()) .cut else if (m.plain[ev.row]) .name else if (ev.sym == m.def()) .def else if (m.isPast(ev.sym)) .past else .use;
            const line = @field(stats, @tagName(stream)).getPtr(kind);
            line.events += 1;
            line.coded_bits += tans.cost(m.norm[m.cell(ev.row, ev.sym)], m.logs[ev.row]);
            line.raw_bits += m.width(ev.row, ev.sym);
            if (ev.entry != no_entry) if (stats.entry_bits) |entry_bits| {
                entry_bits[ev.entry] += price(m, &.{ev});
                stats.entry_uses.?[ev.entry] += @intFromBool(ev.sym < m.def());
            };
        }
    }
};

/// The encoder's view of a stream's past: where each token was last seen,
/// and the row that followed every recent position.
const Past = struct {
    last: []u32,
    rows: [size]u16 = undefined,
    pos: u32 = 0,
    /// Positions below this are out of reach (an earlier block's payload).
    floor: u32 = 0,

    const size = 1 << model_.ring_log;

    fn distance(past: *const Past, tok: u32, reach: u32) ?u32 {
        const seen = past.last[tok];
        if (seen <= past.floor) return null;
        const d = past.pos - seen;
        return if (d < reach) d else null;
    }

    fn rowAfter(past: *const Past, d: u32) u16 {
        return past.rows[(past.pos - 1 - d) % size];
    }

    fn push(past: *Past, tok: u32, row: u16) void {
        past.rows[past.pos % size] = row;
        past.pos += 1;
        past.last[tok] = past.pos;
    }
};

const Walk = struct {
    gpa: Allocator,
    plan: *const Plan,
    len: []const u32,
    /// Slot of each entry in its bucket once defined, and each bucket's fill.
    slot: []u32,
    fill: []u32,
    delta: std.ArrayList(Event) = .empty,
    payload: std.ArrayList(Event) = .empty,
    blocks: std.ArrayList(Span) = .empty,
    delta_past: Past,
    payload_past: Past,
    /// Bits of `sym` in `row` as the previous walk counted them; null on the first.
    prices: ?[]const f32 = null,
    /// The previous walk did not look back, so it has no price for doing so.
    past_unpriced: bool = false,
    /// Bytes of the block's definitions written so far, and their high-water mark.
    at: u32 = 0,

    const Stream = enum { delta, payload };
    const Span = struct { delta_end: usize = 0, payload_end: usize = 0, defs: u32 = 0, delta_bytes: u32 = 0, raw_len: u32 = 0, items: u32 = 0 };
    const undefined_slot = std.math.maxInt(u32);

    fn init(arena: Allocator, plan: *const Plan, len: []const u32, prices: ?[]const f32) !Walk {
        const tokens = 256 + plan.parse.entries();
        const w: Walk = .{
            .gpa = arena,
            .plan = plan,
            .len = len,
            .slot = try arena.alloc(u32, plan.parse.entries()),
            .fill = try arena.alloc(u32, plan.model.widths.len),
            .delta_past = .{ .last = try arena.alloc(u32, tokens) },
            .payload_past = .{ .last = try arena.alloc(u32, tokens) },
            .prices = prices,
        };
        @memset(w.slot, undefined_slot);
        inline for (.{ w.fill, w.delta_past.last, w.payload_past.last }) |list| @memset(list, 0);
        return w;
    }

    /// Emits one token into a stream; returns the row that follows it.
    fn token(w: *Walk, comptime stream: Stream, row: u16, tok: u32, span: *Span) error{ OutOfMemory, BucketFull, CutOfDefinition }!u16 {
        const events = &@field(w, @tagName(stream));
        const past = &@field(w, @tagName(stream) ++ "_past");
        const m = w.plan.model;
        const known = tok < 256 or w.slot[tok - 256] != undefined_slot;
        const sym: u16 = if (tok < 256) model_.byte_bucket else if (known) w.plan.bucket[tok - 256] else m.def();

        if (past.distance(tok, (@as(u32, 1) << @intCast(m.ring)) - 1)) |d| {
            const tier = std.math.log2_int(u32, d + 1);
            const from_past: u16 = 1 + tier;
            const back: f32 = @floatFromInt(tier);
            const take = if (!known) true else if (w.prices == null) false else (if (w.past_unpriced) 2 + back else w.price(row, from_past)) + back < w.price(row, sym) + @as(f32, @floatFromInt(m.widths[sym]));
            if (take) {
                try events.append(w.gpa, .{ .row = row, .sym = from_past, .index = d + 1 - (@as(u32, 1) << tier) });
                const next = past.rowAfter(d);
                past.push(tok, next);
                return next;
            }
        }
        if (!known) {
            // A nested definition is followed by the row its name leads to,
            // and enters the delta's past by itself; a first use in the
            // payload is followed by that row's `first_row`.
            _ = try w.emit(events, w.plan.via, row, sym, 0);
            span.defs += @intFromBool(stream == .payload);
            const named = try w.define(tok - 256, span);
            if (stream == .delta) return named;
            past.push(tok, m.first_row[named]);
            return m.first_row[named];
        }
        const from = events.items.len;
        const next = try w.emit(events, w.plan.via, row, sym, if (tok < 256) tok else w.slot[tok - 256]);
        if (tok >= 256) for (events.items[from..]) |*ev| {
            ev.entry = tok - 256;
        };
        past.push(tok, next);
        return next;
    }

    /// What the previous walk's counts charge for `sym` from `row`, silent step included.
    fn price(w: *const Walk, row: u16, sym: u16) f32 {
        const m = w.plan.model;
        const via = w.plan.via[sym];
        if (via == 0) return w.prices.?[m.cell(row, sym)];
        return w.prices.?[m.cell(row, via)] + w.prices.?[m.cell(m.next[m.cell(row, via)], sym)];
    }

    /// Emits `sym`, preceded by its silent symbol if it has one.
    fn emit(w: *Walk, events: *std.ArrayList(Event), via: []const u16, from: u16, sym: u16, index: u32) !u16 {
        const m = w.plan.model;
        var row = from;
        if (via[sym] != 0) {
            try events.append(w.gpa, .{ .row = row, .sym = via[sym] });
            row = m.next[m.cell(row, via[sym])];
        }
        try events.append(w.gpa, .{ .row = row, .sym = sym, .index = index });
        return m.next[m.cell(row, sym)];
    }

    fn define(w: *Walk, e: u32, span: *Span) !u16 {
        const m = w.plan.model;
        const kids = w.plan.parse.body(e);
        try w.delta.append(w.gpa, .{ .row = m.arity_row, .sym = @intCast(kids.len) });
        var row = m.next[m.cell(m.arity_row, @intCast(kids.len))];
        var copied: ?u32 = null;
        for (kids) |kid| {
            if (kid >= Parse.cut) {
                // Only a copy can be cut: a definition's text is its own.
                const keep: u16 = @intCast(kid - Parse.cut);
                const start = copied orelse return error.CutOfDefinition;
                try w.delta.append(w.gpa, .{ .row = row, .sym = m.cut() });
                try w.delta.append(w.gpa, .{ .row = m.cut_row, .sym = keep });
                row = m.next[m.cell(m.cut_row, keep)];
                w.at = start + keep;
                copied = null;
                continue;
            }
            const nested = kid >= 256 and w.slot[kid - 256] == undefined_slot and w.delta_past.distance(kid, (@as(u32, 1) << @intCast(m.ring)) - 1) == null;
            copied = if (nested) null else w.at;
            row = try w.token(.delta, row, kid, span);
            if (!nested) w.at += if (kid < 256) 1 else w.len[kid - 256];
            span.delta_bytes = @max(span.delta_bytes, w.at);
        }

        const b = w.plan.bucket[e];
        if (w.fill[b] >> @intCast(m.widths[b]) != 0) return error.BucketFull;
        w.slot[e] = w.fill[b];
        w.fill[b] += 1;
        const next = try w.emit(&w.delta, w.plan.name_via, m.name_row[row], b, 0);
        w.delta_past.push(256 + e, next);
        return next;
    }

    fn closeBlock(w: *Walk, span: *Span) !void {
        span.delta_end = w.delta.items.len;
        span.payload_end = w.payload.items.len;
        try w.blocks.append(w.gpa, span.*);
        w.payload_past.floor = w.payload_past.pos;
        w.at = 0;
    }
};

pub fn encode(gpa: Allocator, plan: *Plan, stats: ?*Stats) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = plan.parse;
    const m = &plan.model;

    const Mark = struct { delta: usize, payload: usize };
    var marks: std.ArrayList(Mark) = .empty;
    const counts = try arena.alloc(u32, m.norm.len);
    const lengths = try p.lengths(arena);
    var w: Walk = undefined;
    var prices: ?[]const f32 = null;
    const passes: usize = if (m.ring == 0) 1 else plan.passes;
    for (0..passes) |pass| {
        w = try .init(arena, plan, lengths, prices);
        w.past_unpriced = pass == 1;
        marks.clearRetainingCapacity();
        if (plan.hoist) {
            var span: Walk.Span = .{};
            for (p.toks) |tok| if (tok >= 256 and w.slot[tok - 256] == Walk.undefined_slot) {
                span.defs += 1;
                _ = try w.define(tok - 256, &span);
            };
            if (span.defs != 0) try w.closeBlock(&span);
        }
        for (0..p.blocks()) |b| {
            if (p.block(b).len == 0) continue;
            var span: Walk.Span = .{};
            var row = m.start_row;
            for (p.block(b)) |tok| {
                try marks.append(arena, .{ .delta = w.delta.items.len, .payload = w.payload.items.len });
                row = try w.token(.payload, row, tok, &span);
                span.raw_len += if (tok < 256) 1 else w.len[tok - 256];
                span.items += 1;
            }
            try w.closeBlock(&span);
        }

        @memset(counts, 0);
        for (w.delta.items) |ev| counts[m.cell(ev.row, ev.sym)] += 1;
        for (w.payload.items) |ev| counts[m.cell(ev.row, ev.sym)] += 1;
        if (pass + 1 == passes) break;

        // Next walk's prices: what these counts would charge, with a little
        // mass kept for symbols a row has not used yet.
        const next_prices = try arena.alloc(f32, counts.len);
        for (0..m.rows) |r| {
            const row_counts = counts[r * m.alphabet ..][0..m.alphabet];
            var total: f32 = 1;
            for (row_counts) |c| total += @floatFromInt(c);
            for (row_counts, next_prices[r * m.alphabet ..][0..m.alphabet]) |c, *bits_| {
                bits_.* = @log2(total / (@as(f32, @floatFromInt(c)) + 0.25));
            }
        }
        prices = next_prices;
    }

    const rows = try arena.alloc(tans.EncodeRow, m.rows);
    for (rows, m.logs, 0..) |*row, *row_log, r| {
        const norm = m.norm[r * m.alphabet ..][0..m.alphabet];
        row_log.* = try fitLog(counts[r * m.alphabet ..][0..m.alphabet], m.log, norm, plan.table_slack);
        row.* = if (std.mem.allEqual(u16, norm, 0)) .{ .norm = norm, .first = &.{}, .states = &.{} } else try .init(arena, norm, row_log.*);
    }

    if (stats) |st| {
        st.add(m.*, w.delta.items, .delta);
        st.add(m.*, w.payload.items, .payload);
        if (st.token_bits != null or st.token_name_bits != null or st.token_def_bits != null) {
            for (marks.items, 0..) |mark, i| {
                const end: Mark = if (i + 1 < marks.items.len) marks.items[i + 1] else .{ .delta = w.delta.items.len, .payload = w.payload.items.len };
                const pe = w.payload.items[mark.payload..end.payload];
                const de = w.delta.items[mark.delta..end.delta];
                if (st.token_bits) |v| v[i] = Stats.price(m.*, pe) + Stats.price(m.*, de);
                if (st.token_name_bits) |v| v[i] = Stats.priceKind(m.*, pe, .name) + Stats.priceKind(m.*, de, .name);
                if (st.token_def_bits) |v| v[i] = Stats.priceKind(m.*, pe, .def) + Stats.priceKind(m.*, de, .def);
            }
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var header: binary.Encoder = .{ .gpa = gpa };
    defer header.deinit();
    try m.write(gpa, &header);
    const header_bytes = try header.finish();
    try out.appendSlice(gpa, frame.magic);
    try frame.putVarint(gpa, &out, header_bytes.len);
    try out.appendSlice(gpa, header_bytes);

    var stack: bits.Stack = .{};
    defer stack.deinit(gpa);
    var delta_start: usize = 0;
    var payload_start: usize = 0;
    for (w.blocks.items) |span| {
        var delta: bits.Writer = .{};
        defer delta.deinit(gpa);
        var payload: bits.Writer = .{};
        defer payload.deinit(gpa);
        try writeStream(gpa, m.*, rows, w.delta.items[delta_start..span.delta_end], &stack, &delta);
        try writeStream(gpa, m.*, rows, w.payload.items[payload_start..span.payload_end], &stack, &payload);
        const block: frame.Block = .{
            .defs = span.defs,
            .delta_bytes = span.delta_bytes,
            .delta = try delta.finish(gpa),
            .raw_len = span.raw_len,
            .items = span.items,
            .payload = try payload.finish(gpa),
        };
        if (block.defs != 0 or block.items != 0) try block.write(gpa, &out);
        delta_start = span.delta_end;
        payload_start = span.payload_end;
    }
    try out.append(gpa, 0);
    return out.toOwnedSlice(gpa);
}

/// Normalises a row at the smallest table size that codes it within `slack`
/// of the largest.
fn fitLog(counts: []const u32, max_log: u8, norm: []u16, slack: f64) !u8 {
    var best: f64 = undefined;
    var log = max_log;
    while (true) : (log -= 1) {
        const fits = if (tans.normalize(counts, log, norm)) true else |_| false;
        var coded: f64 = 0;
        for (counts, norm) |c, n| if (c != 0 and fits) {
            coded += @as(f64, @floatFromInt(c)) * tans.cost(n, log);
        };
        if (log == max_log) best = coded;
        if (!fits or coded > best * (1 + slack)) {
            if (log == max_log) return error.TooManySymbols;
            try tans.normalize(counts, log + 1, norm);
            return log + 1;
        }
        if (log == tans.min_log) return log;
    }
}

fn writeStream(gpa: Allocator, m: Model, rows: []const tans.EncodeRow, events: []const Event, stack: *bits.Stack, out: *bits.Writer) !void {
    if (events.len == 0) return;
    var state: u16 = 0;
    var i = events.len;
    while (i > 0) {
        i -= 1;
        const ev = events[i];
        try stack.push(gpa, ev.index, m.width(ev.row, ev.sym));
        const carry: u4 = @intCast(m.log - m.logs[ev.row]);
        const step = rows[ev.row].encode(state >> carry, ev.sym, m.logs[ev.row]);
        try stack.push(gpa, step.bits, step.nbits);
        state = step.state << carry | (state & ((@as(u16, 1) << carry) - 1));
    }
    try stack.push(gpa, state, m.log);
    try stack.drain(gpa, out);
}
