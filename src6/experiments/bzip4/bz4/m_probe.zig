//! m_probe: quick single-file driver for developing the Lane M lexicon
//! engine (m_lexicon.zig) against real data before wiring the full
//! multi-file lab harness (m_lab.zig). Not part of the final report.
//!
//! usage: m_probe FILE BLOCK_BYTES [SEED_DUMP|bytes] [MAX_ITERS] [TRIPLES 0|1]

const std = @import("std");
const lex = @import("m_lexicon.zig");

fn nowMs(io: std.Io) f64 {
    return @as(f64, @floatFromInt(std.Io.Clock.awake.now(io).nanoseconds)) / 1e6;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const path = it.next() orelse return error.Usage;
    const block_bytes = try std.fmt.parseUnsigned(usize, it.next() orelse return error.Usage, 10);
    const seed_arg = it.next() orelse "bytes";
    const max_iters = try std.fmt.parseUnsigned(usize, it.next() orelse "20", 10);
    const triples = std.mem.eql(u8, it.next() orelse "0", "1");

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const A = arena_state.allocator();

    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, A, .limited(16 << 20));
    std.debug.print("file={s} bytes={d} block={d} seed={s} max_iters={d} triples={}\n", .{ path, raw.len, block_bytes, seed_arg, max_iters, triples });

    var state: lex.State = undefined;
    if (std.mem.eql(u8, seed_arg, "bytes")) {
        state = try lex.seedBytes(A, raw, block_bytes);
    } else {
        const dump_bytes = try std.Io.Dir.cwd().readFileAlloc(io, seed_arg, A, .limited(64 << 20));
        var dump = try lex.readB4SDv1(A, dump_bytes);
        if (dump.raw_len != raw.len) std.debug.print("WARNING: dump raw_len={d} != file len={d}\n", .{ dump.raw_len, raw.len });
        state = try lex.seedFromV1(A, &dump);
    }
    if (!try lex.verifyExact(A, raw, &state)) return error.SeedNotExact;
    std.debug.print("seed ok: entries={d} tokens={d}\n", .{ state.lex.numEntries(), state.seq.len });

    var log: std.ArrayList(lex.IterLog) = .empty;
    const t0 = nowMs(io);
    try lex.iterate(A, io, &state, raw, .{ .max_iters = max_iters, .triples = triples }, &log);
    const t1 = nowMs(io);

    for (log.items) |l| {
        std.debug.print(
            "iter={d:>2} entries={d:>7} tokens={d:>8} dl_bytes={d:>10.0} proposed_pairs={d:>6} proposed_triples={d:>6} deleted={d:>6} ms={d:>8.1}\n",
            .{ l.iter, l.num_entries, l.tokens, l.dl_bytes, l.proposed_pairs, l.proposed_triples, l.deleted, l.ms },
        );
    }
    std.debug.print("total_ms={d:.1}\n", .{t1 - t0});

    const ok = try lex.verifyExact(A, raw, &state);
    std.debug.print("final verifyExact={}\n", .{ok});
    if (!ok) return error.NotExact;

    // A little qualitative peek: 10 highest-count multi-byte entries.
    const rc = try lex.recount(A, &state);
    const Item = struct { sym: u32, n: u64 };
    var items: std.ArrayList(Item) = .empty;
    for (0..state.lex.numEntries()) |i| {
        const sym: u32 = @intCast(256 + i);
        if (rc.n[sym] > 0) try items.append(A, .{ .sym = sym, .n = rc.n[sym] });
    }
    std.mem.sort(Item, items.items, {}, struct {
        fn f(_: void, x: Item, y: Item) bool {
            return x.n > y.n;
        }
    }.f);
    std.debug.print("-- top entries by count --\n", .{});
    for (items.items[0..@min(20, items.items.len)]) |it2| {
        const b = try lex.expandEntryBytes(A, &state.lex, it2.sym);
        var esc: std.ArrayList(u8) = .empty;
        for (b) |byte| {
            if (byte >= 0x20 and byte < 0x7f and byte != '\'' and byte != '\\') {
                try esc.append(A, byte);
            } else {
                try esc.print(A, "\\x{x:0>2}", .{byte});
            }
        }
        std.debug.print("  n={d:>6} arity={d:>2} len={d:>3} '{s}'\n", .{ it2.n, state.lex.arity(it2.sym - 256), b.len, esc.items });
    }
}
