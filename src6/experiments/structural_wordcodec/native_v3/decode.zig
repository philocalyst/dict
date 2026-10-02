//! Decoding. Deltas run in order and leave behind, per block, a `Job` that
//! depends on nothing else; jobs can then be decoded in any order, on any
//! number of threads, straight into their place in the output.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bits = @import("bits.zig");
const binary = @import("binary.zig");
const tans = @import("tans.zig");
const frame = @import("frame.zig");
const model_ = @import("model.zig");
const Model = model_.Model;
const gen = @import("gen.zig");

/// A stream's recent tokens and the row that followed each: what the past
/// buckets address. A token copied from the past also resumes its row.
const Past = struct {
    tokens: [size]Token = undefined,
    rows: [size]tans.Row = undefined,
    pos: usize = 0,

    const size = 1 << model_.ring_log;

    /// Where the token `distance` places back lives; null if there is none.
    inline fn find(past: *const Past, cell: tans.Cell, index: usize) ?usize {
        const distance = (@as(usize, 1) << cell.width) - 1 + index;
        return if (distance < past.pos) (past.pos - 1 - distance) % size else null;
    }

    inline fn push(past: *Past, token: Token, row: tans.Row) void {
        past.tokens[past.pos % size] = token;
        past.rows[past.pos % size] = row;
        past.pos += 1;
    }
};

pub const Token = []const u8;

/// Tokens may be copied with a fixed-size overshoot, so every byte a token
/// points at is followed by at least this much readable memory.
pub const slack = 32;

const bytes_identity: [256 + slack]u8 = blk: {
    var table: [256 + slack]u8 = @splat(0);
    for (table[0..256], 0..) |*b, i| b.* = i;
    break :blk table;
};

/// A definition: its text, and the row that follows it.
const Defined = struct { token: Token, row: tans.Row };

/// A bucket's tokens. It grows into fresh memory and leaves the old slots
/// alone, because the payload jobs of earlier blocks still read them.
const Bucket = struct {
    slots: []Token = &.{},
    len: usize = 0,

    fn items(bucket: Bucket) []const Token {
        return bucket.slots[0..bucket.len];
    }

    fn append(bucket: *Bucket, arena: Allocator, token: Token) !void {
        if (bucket.len == bucket.slots.len) {
            const grown = try arena.alloc(Token, @max(16, 2 * bucket.slots.len));
            @memcpy(grown[0..bucket.len], bucket.items());
            bucket.slots = grown;
        }
        bucket.slots[bucket.len] = token;
        bucket.len += 1;
    }
};

pub const Job = struct {
    tables: []const []const Token,
    /// Top-level definitions of this block, in order of first use, each
    /// with the row that follows that use.
    firsts: []const Defined,
    stream: []const u8,
    items: u32,
    raw_len: u32,
    gens: u32,
    gen: []const u8,
};

const Cursor = struct {
    reader: bits.Reader,
    state: usize,

    fn init(stream: []const u8, log: u8) Cursor {
        var reader: bits.Reader = .init(stream);
        return .{ .state = reader.take(log), .reader = reader };
    }

    const Step = struct { cell: tans.Cell, index: usize };

    inline fn step(c: *Cursor, cells: []const tans.Cell, row: tans.Row) Step {
        const carry: u6 = row.carry;
        const cell = cells[(@as(usize, row.unit) << tans.min_log) + (c.state >> carry)];
        const v = c.reader.acc;
        c.state = (cell.base + bits.low(v, cell.nbits)) << carry | bits.low(c.state, carry);
        c.reader.consume(@as(u8, cell.nbits) + cell.width);
        c.reader.refill();
        return .{ .cell = cell, .index = bits.low(v >> cell.nbits, cell.width) };
    }

    /// The next symbol that says something; silent ones only change rows.
    inline fn symbol(c: *Cursor, cells: []const tans.Cell, hush: u16, from: tans.Row) Step {
        var row = from;
        while (true) {
            const s = c.step(cells, row);
            if (s.cell.sym < hush) return s;
            row = s.cell.next;
        }
    }
};

pub const Decoder = struct {
    arena: std.heap.ArenaAllocator,
    model: Model,
    cells: []const tans.Cell,
    /// Rows by id; and, by the unit a row starts at, the row that names a
    /// body ending there and the row that follows a first use named there.
    rows: []const tans.Row,
    name_of: []const tans.Row,
    first_of: []const tans.Row,
    buckets: []Bucket,
    /// The past of the delta stream, which runs through the whole frame.
    past: *Past,
    bytes: []const u8,
    pos: usize,

    pub fn init(gpa: Allocator, bytes: []const u8) !Decoder {
        if (!std.mem.startsWith(u8, bytes, frame.magic)) return error.Corrupt;
        var pos: usize = frame.magic.len;
        const header_len = try frame.takeVarint(bytes, &pos);
        if (header_len > bytes.len - pos) return error.Corrupt;

        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var header: binary.Decoder = .init(bytes[pos..][0..header_len]);
        const model: Model = try .read(a, &header);
        const buckets = try a.alloc(Bucket, model.widths.len);
        @memset(buckets, .{});
        for (0..256) |b| try buckets[0].append(a, bytes_identity[b..][0..1]);

        const past = try a.create(Past);
        past.* = .{};

        const rows = try model.layout(a);
        const cells = try model.buildCells(a, rows);
        const name_of = try a.alloc(tans.Row, cells.len >> tans.min_log);
        const first_of = try a.alloc(tans.Row, cells.len >> tans.min_log);
        @memset(name_of, rows[0]);
        @memset(first_of, rows[0]);
        for (rows, model.name_row, model.first_row) |row, name, first| {
            name_of[row.unit] = rows[name];
            first_of[row.unit] = rows[first];
        }
        return .{
            .arena = arena,
            .model = model,
            .cells = cells,
            .rows = rows,
            .name_of = name_of,
            .first_of = first_of,
            .buckets = buckets,
            .past = past,
            .bytes = bytes,
            .pos = pos + header_len,
        };
    }

    pub fn deinit(d: *Decoder) void {
        d.arena.deinit();
    }

    /// Runs the next block's delta and returns its payload job, or null at
    /// the end of the frame. A payload-less block yields an empty job.
    pub fn next(d: *Decoder) !?Job {
        const block = try frame.Block.read(d.bytes, &d.pos) orelse return null;
        const a = d.arena.allocator();

        var delta: Delta = .{
            .decoder = d,
            .cursor = .init(block.delta, d.model.log),
            .gen_reader = .init(block.dgen),
            .gen_expected = block.dgens,
            .out = try a.alloc(u8, @as(usize, block.delta_bytes) + slack),
        };
        const firsts = try a.alloc(Defined, block.defs);
        for (firsts) |*first| {
            first.* = try delta.define(0);
            first.row = d.first_of[first.row.unit];
        }
        if (delta.gen_used != delta.gen_expected) return error.Corrupt;

        const tables = try a.alloc([]const Token, d.buckets.len);
        for (tables, d.buckets) |*table, bucket| table.* = bucket.items();
        return .{ .tables = tables, .firsts = firsts, .stream = block.payload, .items = block.items, .raw_len = block.raw_len, .gens = block.gens, .gen = block.gen };
    }

    /// Decodes one job into `out`, which must be exactly `raw_len` long.
    /// Touches nothing mutable: safe to call concurrently for distinct jobs.
    ///
    /// Tokens are resolved a batch at a time so that the entropy chain, the
    /// slot loads and the copies do not wait on each other's cache misses.
    pub fn run(d: *const Decoder, job: Job, out: []u8) error{Corrupt}!void {
        if (out.len != job.raw_len) return error.Corrupt;
        if (job.gens != 0) return d.runGen(job, out);
        const def = d.model.def();
        const hush = d.model.hush();
        var cursor: Cursor = .init(job.stream, d.model.log);
        var row = d.rows[d.model.start_row];
        var first: usize = 0;
        var at: usize = 0;
        var left: usize = job.items;
        var slots: [batch]*const Token = undefined;
        var tokens: [batch]Token = undefined;
        const ring = d.model.ring;
        var past: Past = .{};
        var filled: usize = 0;
        while (left != 0) {
            const n = @min(left, batch);
            left -= n;
            for (slots[0..n]) |*slot| {
                const s = cursor.symbol(d.cells, hush, row);
                if (s.cell.sym -% 1 < ring) {
                    const back = past.find(s.cell, s.index) orelse return error.Corrupt;
                    slot.* = &past.tokens[back];
                    row = past.rows[back];
                } else if (s.cell.sym < def) {
                    const table = job.tables[s.cell.sym];
                    if (s.index >= table.len) return error.Corrupt;
                    slot.* = &table[s.index];
                    row = s.cell.next;
                } else {
                    if (s.cell.sym != def or first == job.firsts.len) return error.Corrupt;
                    slot.* = &job.firsts[first].token;
                    row = job.firsts[first].row;
                    first += 1;
                }
                past.rows[past.pos % Past.size] = row;
                past.pos += 1;
                @prefetch(slot.*, .{});
            }
            for (tokens[0..n], slots[0..n]) |*token, slot| {
                token.* = slot.*;
                past.tokens[filled % Past.size] = token.*;
                filled += 1;
                @prefetch(token.ptr, .{});
            }
            for (tokens[0..n]) |token| {
                if (token.len > out.len - at) return error.Corrupt;
                if (out.len - at >= slack and token.len <= slack) {
                    out[at..][0..slack].* = token.ptr[0..slack].*;
                } else @memcpy(out[at..][0..token.len], token);
                at += token.len;
            }
        }
        if (at != out.len) return error.Corrupt;
    }

    fn runGen(d: *const Decoder, job: Job, out: []u8) error{Corrupt}!void {
        const m = d.model;
        var cursor: Cursor = .init(job.stream, m.log);
        var operands: binary.Decoder = .init(job.gen);
        var params: gen.Codec = .{};
        var row = d.rows[m.start_row];
        var past: Past = .{};
        var first: usize = 0;
        var used: usize = 0;
        var at: usize = 0;
        for (0..job.items) |_| {
            const step = cursor.symbol(d.cells, m.hush(), row);
            var token: Token = undefined;
            if (step.cell.sym -% 1 < m.ring) {
                const back = past.find(step.cell, step.index) orelse return error.Corrupt;
                token = past.tokens[back];
                row = past.rows[back];
            } else if (step.cell.sym < m.def()) {
                const table = job.tables[step.cell.sym];
                if (step.index >= table.len) return error.Corrupt;
                token = table[step.index];
                row = step.cell.next;
            } else if (step.cell.sym == m.def()) {
                if (first == job.firsts.len) return error.Corrupt;
                token = job.firsts[first].token;
                row = job.firsts[first].row;
                first += 1;
            } else if (step.cell.sym == m.gen()) {
                if (used == job.gens) return error.Corrupt;
                var literal: [96]u8 = undefined;
                const arg = params.read(&operands, &literal) catch return error.Corrupt;
                if (arg.distance >= past.pos or arg.distance >= Past.size) return error.Corrupt;
                const donor = past.tokens[(past.pos - 1 - arg.distance) % Past.size];
                if (arg.start > donor.len or arg.copy_len > donor.len - arg.start or arg.lead_len + arg.copy_len + arg.tail_len > out.len - at) return error.Corrupt;
                @memcpy(out[at..][0..arg.lead_len], literal[0..arg.lead_len]);
                @memcpy(out[at + arg.lead_len ..][0..arg.copy_len], donor[arg.start..][0..arg.copy_len]);
                @memcpy(out[at + arg.lead_len + arg.copy_len ..][0..arg.tail_len], literal[arg.lead_len..][0..arg.tail_len]);
                token = out[at..][0 .. arg.lead_len + arg.copy_len + arg.tail_len];
                at += token.len;
                row = step.cell.next;
                past.push(token, row);
                used += 1;
                continue;
            } else return error.Corrupt;
            if (token.len > out.len - at) return error.Corrupt;
            @memcpy(out[at..][0..token.len], token);
            at += token.len;
            past.push(token, row);
        }
        if (at != out.len or used != job.gens or first != job.firsts.len) return error.Corrupt;
    }

    const batch = 128;
};

/// The delta is text decoded into `out`; a definition is the span its
/// children wrote, so nested definitions are sub-slices of their parent.
const Delta = struct {
    decoder: *Decoder,
    cursor: Cursor,
    gen_reader: binary.Decoder,
    gen_model: gen.Codec = .{},
    gen_expected: u32,
    gen_used: u32 = 0,
    out: []u8,
    at: usize = 0,

    const max_depth = 256;

    fn define(delta: *Delta, depth: usize) !Defined {
        const d = delta.decoder;
        const m = d.model;
        const past = d.past;
        if (depth == max_depth) return error.Corrupt;
        const start = delta.at;
        const arity = delta.cursor.symbol(d.cells, m.hush(), d.rows[m.arity_row]).cell;
        var row = arity.next;
        // Where the previous child starts, if it is a copy that `CUT` may shorten.
        var copied: ?usize = null;
        for (0..arity.sym) |_| {
            const s = delta.cursor.symbol(d.cells, m.hush(), row);
            if (s.cell.sym < m.def()) {
                var token: Token = undefined;
                if (m.isPast(s.cell.sym)) {
                    const back = past.find(s.cell, s.index) orelse return error.Corrupt;
                    token = past.tokens[back];
                    row = past.rows[back];
                } else {
                    const table = d.buckets[s.cell.sym].items();
                    if (s.index >= table.len) return error.Corrupt;
                    token = table[s.index];
                    row = s.cell.next;
                }
                if (token.len > delta.out.len - slack - delta.at) return error.Corrupt;
                @memcpy(delta.out[delta.at..][0..token.len], token);
                copied = delta.at;
                delta.at += token.len;
                past.push(token, row);
            } else if (s.cell.sym == m.def()) {
                row = (try delta.define(depth + 1)).row;
                copied = null;
            } else if (s.cell.sym == m.gen()) {
                if (delta.gen_used >= delta.gen_expected) return error.Corrupt;
                var literal: [96]u8 = undefined;
                const arg = delta.gen_model.read(&delta.gen_reader, &literal) catch return error.Corrupt;
                if (arg.distance >= past.pos or arg.distance >= Past.size) return error.Corrupt;
                const donor = past.tokens[(past.pos - 1 - arg.distance) % Past.size];
                if (arg.start > donor.len or arg.copy_len > donor.len - arg.start or arg.lead_len + arg.copy_len + arg.tail_len > delta.out.len - slack - delta.at) return error.Corrupt;
                copied = delta.at;
                @memcpy(delta.out[delta.at..][0..arg.lead_len], literal[0..arg.lead_len]);
                @memcpy(delta.out[delta.at + arg.lead_len ..][0..arg.copy_len], donor[arg.start..][0..arg.copy_len]);
                @memcpy(delta.out[delta.at + arg.lead_len + arg.copy_len ..][0..arg.tail_len], literal[arg.lead_len..][0..arg.tail_len]);
                delta.at += arg.lead_len + arg.copy_len + arg.tail_len;
                row = s.cell.next;
                // CUT may retract and overwrite this part of delta.out later.
                // The PAST donor must retain the entire generated surface.
                const stable = try d.arena.allocator().dupe(u8, delta.out[copied.?..delta.at]);
                past.push(stable, row);
                delta.gen_used += 1;
            } else {
                const from = copied orelse return error.Corrupt;
                const keep = delta.cursor.symbol(d.cells, m.hush(), d.rows[m.cut_row]).cell;
                if (s.cell.sym != m.cut() or keep.sym > delta.at - from) return error.Corrupt;
                delta.at = from + keep.sym;
                row = keep.next;
                copied = null;
            }
        }
        const name = delta.cursor.symbol(d.cells, m.hush(), d.name_of[row.unit]).cell;
        if (name.sym >= m.def() or name.sym <= m.ring) return error.Corrupt;
        const bucket = &d.buckets[name.sym];
        if (bucket.len >> @intCast(m.widths[name.sym]) != 0) return error.Corrupt;
        const token = delta.out[start..delta.at];
        try bucket.append(d.arena.allocator(), token);
        past.push(token, name.next);
        return .{ .token = token, .row = name.next };
    }
};

/// Whole-frame decode. Deltas run here, in order; payloads run on `workers`
/// threads (the calling thread included).
pub fn decodeAll(gpa: Allocator, bytes: []const u8, workers: usize) ![]u8 {
    var d: Decoder = try .init(gpa, bytes);
    defer d.deinit();
    var jobs: std.MultiArrayList(struct { job: Job, at: usize }) = .empty;
    defer jobs.deinit(gpa);
    var total: usize = 0;
    while (try d.next()) |job| {
        try jobs.append(gpa, .{ .job = job, .at = total });
        total += job.raw_len;
    }
    const out = try gpa.alloc(u8, total);
    errdefer gpa.free(out);

    var crew: Crew = .{ .decoder = &d, .jobs = jobs.items(.job), .at = jobs.items(.at), .out = out };
    const threads = try gpa.alloc(std.Thread, @min(workers, jobs.len) -| 1);
    defer gpa.free(threads);
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |thread| thread.join();
    for (threads) |*thread| {
        thread.* = try .spawn(.{}, Crew.work, .{&crew});
        spawned += 1;
    }
    crew.work();
    for (threads[0..spawned]) |thread| thread.join();
    spawned = 0;
    return if (crew.failed.load(.acquire)) error.Corrupt else out;
}

const Crew = struct {
    decoder: *const Decoder,
    jobs: []const Job,
    at: []const usize,
    out: []u8,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),

    fn work(crew: *Crew) void {
        while (true) {
            const i = crew.next.fetchAdd(1, .monotonic);
            if (i >= crew.jobs.len) return;
            const job = crew.jobs[i];
            crew.decoder.run(job, crew.out[crew.at[i]..][0..job.raw_len]) catch crew.failed.store(true, .release);
        }
    }
};
