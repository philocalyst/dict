//! m_lab: Lane M measurement harness. For every required (file, block)
//! combo: seed the compositional MDL lexicon from Lane A's best grammar
//! (dumps/a_<name>.<block>.best.b4sd), iterate to convergence (pairs, and
//! a triples-enabled variant for the ablation), verify byte-exactness,
//! run the REAL codec (m_codec.zig), verify the decode matches the raw
//! file byte-for-byte, write a B4SD v2 dump, and print one TSV row per
//! (file, block, variant) plus a qualitative listing for gcide.eval8 and
//! json.eval8. See LANE_M.md for the write-up built from this output.
//!
//! usage: m_lab                 (no arguments; paths relative to bz4/)

const std = @import("std");
const mlex = @import("m_lexicon.zig");
const mcodec = @import("m_codec.zig");

fn nowMs(io: std.Io) f64 {
    return @as(f64, @floatFromInt(std.Io.Clock.awake.now(io).nanoseconds)) / 1e6;
}

const FileSpec = struct { name: []const u8, path: []const u8, blocks: []const usize };

const files = [_]FileSpec{
    .{ .name = "freedict.eval8", .path = "data/freedict.eval8.bin", .blocks = &.{ 65536, 16384 } },
    .{ .name = "freedict.untouched", .path = "data/freedict.untouched.bin", .blocks = &.{65536} },
    .{ .name = "gcide.eval8", .path = "data/gcide.eval8.bin", .blocks = &.{ 65536, 16384 } },
    .{ .name = "gcide.untouched", .path = "data/gcide.untouched.bin", .blocks = &.{65536} },
    .{ .name = "omw.eval8", .path = "data/omw.eval8.bin", .blocks = &.{ 65536, 16384 } },
    .{ .name = "omw.untouched", .path = "data/omw.untouched.bin", .blocks = &.{65536} },
    .{ .name = "json.eval8", .path = "data/json.eval8.bin", .blocks = &.{65536} },
    .{ .name = "macho.eval8", .path = "data/macho.eval8.bin", .blocks = &.{65536} },
    .{ .name = "zigsrc.eval8", .path = "data/zigsrc.eval8.bin", .blocks = &.{65536} },
};

/// bzip3 total_bytes at the matching (file,block) from baselines.tsv,
/// parsed at runtime so there's no risk of a hand-copied typo.
fn bzip3Total(alloc: std.mem.Allocator, io: std.Io, file_bin: []const u8, block: usize) !?usize {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, "baselines.tsv", alloc, .limited(1 << 20));
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = lines.next(); // header
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const f = cols.next() orelse continue;
        const b = cols.next() orelse continue;
        const bval = std.fmt.parseUnsigned(usize, b, 10) catch continue;
        if (std.mem.eql(u8, f, file_bin) and bval == block) {
            _ = cols.next(); // block_count
            _ = cols.next(); // payload_bytes
            const tot = cols.next() orelse continue;
            return std.fmt.parseUnsigned(usize, tot, 10) catch null;
        }
    }
    return null;
}

/// PLAN's Round-3 brief: Re-Pair static path (payload Huffman + Lane B
/// model + directory) assembled from rounds 1-2, all at block 64K. Given
/// directly in the task brief (not re-derived here); labelled clearly
/// wherever printed.
const RepairStatic = struct { name: []const u8, bytes: usize };
const repair_static = [_]RepairStatic{
    .{ .name = "freedict.eval8", .bytes = 692_000 },
    .{ .name = "gcide.eval8", .bytes = 1_603_000 },
    .{ .name = "omw.eval8", .bytes = 424_000 },
    .{ .name = "freedict.untouched", .bytes = 101_000 },
    .{ .name = "gcide.untouched", .bytes = 222_000 },
    .{ .name = "omw.untouched", .bytes = 71_000 },
    .{ .name = "json.eval8", .bytes = 1_183_000 },
    .{ .name = "macho.eval8", .bytes = 3_008_000 },
    .{ .name = "zigsrc.eval8", .bytes = 1_336_000 },
};
fn repairStaticFor(name: []const u8) ?usize {
    for (repair_static) |r| if (std.mem.eql(u8, r.name, name)) return r.bytes;
    return null;
}

fn runVariant(
    alloc: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    name: []const u8,
    file_bin: []const u8,
    block: usize,
    raw: []const u8,
    dump: *const mlex.V1Dump,
    variant: []const u8,
    triples: bool,
    write_dump_path: ?[]const u8,
) !void {
    var state = try mlex.seedFromV1(alloc, dump);
    if (!try mlex.verifyExact(alloc, raw, &state)) return error.SeedNotExact;

    var log: std.ArrayList(mlex.IterLog) = .empty;
    const t0 = nowMs(io);
    try mlex.iterate(alloc, io, &state, raw, .{ .max_iters = 20, .triples = triples }, &log);
    const t1 = nowMs(io);
    if (!try mlex.verifyExact(alloc, raw, &state)) return error.LexNotExact;

    var stats: mcodec.EncodeStats = undefined;
    const t2 = nowMs(io);
    const encoded = try mcodec.encodeWithRawLen(alloc, &state, raw.len, &stats);
    const t3 = nowMs(io);
    var decoded = try mcodec.decode(alloc, encoded);
    if (!mcodec.verifyDecode(raw, state.block_bytes, &decoded)) return error.CodecNotExact;

    const bz3 = try bzip3Total(alloc, io, file_bin, block);
    const rep = repairStaticFor(name);
    const bytes_per_token: f64 = @as(f64, @floatFromInt(raw.len)) / @as(f64, @floatFromInt(state.seq.len));
    const pct_bz3: f64 = if (bz3) |b| 100.0 * (1.0 - @as(f64, @floatFromInt(stats.total_bytes)) / @as(f64, @floatFromInt(b))) else 0;
    const pct_rep: f64 = if (rep) |r| 100.0 * (1.0 - @as(f64, @floatFromInt(stats.total_bytes)) / @as(f64, @floatFromInt(r))) else 0;

    try w.print(
        "{s}\t{d}\t{s}\t{d}\t{d}\t{d:.2}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d:.1}\t{d:.1}\t{d:.1}\t{d:.1}\t{d:.1}\n",
        .{
            name, block, variant, state.lex.numEntries(), state.seq.len, bytes_per_token,
            stats.model_bytes, stats.payload_bytes, stats.total_bytes, bz3 orelse 0, rep orelse 0,
            pct_bz3, pct_rep, @as(f64, @floatFromInt(log.items.len)), (t1 - t0) / 1000.0, (t3 - t2) / 1000.0,
        },
    );
    try w.flush();

    std.debug.print("  [{s} block={d} {s}] entries={d} tokens={d} model={d}B payload={d}B total={d}B iters={d} iterate_s={d:.2} encode_s={d:.3} dl_curve=[", .{
        name, block, variant, state.lex.numEntries(), state.seq.len, stats.model_bytes, stats.payload_bytes, stats.total_bytes, log.items.len, (t1 - t0) / 1000.0, (t3 - t2) / 1000.0,
    });
    for (log.items, 0..) |l, i| {
        if (i > 0) std.debug.print(",", .{});
        std.debug.print("{d:.0}", .{l.dl_bytes});
    }
    std.debug.print("]\n", .{});

    if (write_dump_path) |p| {
        try writeB4SDv2(alloc, io, p, &state, raw.len);
    }
}

fn writeB4SDv2(alloc: std.mem.Allocator, io: std.Io, path: []const u8, state: *const mlex.State, raw_len: usize) !void {
    var out: std.ArrayList(u32) = .empty;
    try out.appendSlice(alloc, &.{ 0x44533442, 2, @intCast(state.lex.numEntries()), @intCast(state.block_end.len), @intCast(state.block_bytes), @intCast(raw_len) });
    for (0..state.lex.numEntries()) |i| {
        const cs = state.lex.comps(i);
        try out.append(alloc, @intCast(cs.len));
        try out.appendSlice(alloc, cs);
    }
    var start: usize = 0;
    for (state.block_end) |end| {
        try out.append(alloc, @intCast(end - start));
        try out.appendSlice(alloc, state.seq[start..end]);
        start = end;
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = std.mem.sliceAsBytes(out.items) });
}

/// PLAN's qualitative-evidence ask: 40 most frequent multi-byte entries and
/// 40 random entries of expansion length 6-20 for the MDL lexicon, next to
/// the same listing from the Re-Pair grammar dump.
fn escapeInto(alloc: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(u8)) !void {
    for (bytes) |byte| {
        if (byte >= 0x20 and byte < 0x7f and byte != '\'' and byte != '\\' and byte != '|') {
            try out.append(alloc, byte);
        } else {
            try out.print(alloc, "\\x{x:0>2}", .{byte});
        }
    }
}

fn qualitative(alloc: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, label: []const u8, state: *const mlex.State, repair_dump_path: []const u8) !void {
    try w.print("== qualitative: {s} ==\n", .{label});
    const rc = try mlex.recount(alloc, state);
    const Item = struct { sym: u32, n: u64, len: u32 };
    var items: std.ArrayList(Item) = .empty;
    for (0..state.lex.numEntries()) |i| {
        const sym: u32 = @intCast(256 + i);
        if (rc.n[sym] > 0) try items.append(alloc, .{ .sym = sym, .n = rc.n[sym], .len = state.lex.explen.items[i] });
    }
    std.mem.sort(Item, items.items, {}, struct {
        fn f(_: void, x: Item, y: Item) bool {
            return x.n > y.n;
        }
    }.f);
    try w.print("-- MDL lexicon: top 40 by count --\n", .{});
    for (items.items[0..@min(40, items.items.len)]) |it| {
        const b = try mlex.expandEntryBytes(alloc, &state.lex, it.sym);
        var esc: std.ArrayList(u8) = .empty;
        try escapeInto(alloc, b, &esc);
        try w.print("n={d}\tlen={d}\t|{s}|\n", .{ it.n, b.len, esc.items });
    }
    try w.flush();

    var mid_candidates: std.ArrayList(Item) = .empty;
    for (items.items) |it| if (it.len >= 6 and it.len <= 20) try mid_candidates.append(alloc, it);
    var prng = std.Random.DefaultPrng.init(0xB4A5EED);
    const rnd = prng.random();
    rnd.shuffle(Item, mid_candidates.items);
    try w.print("-- MDL lexicon: 40 random entries, expansion length 6-20 (pool={d}) --\n", .{mid_candidates.items.len});
    for (mid_candidates.items[0..@min(40, mid_candidates.items.len)]) |it| {
        const b = try mlex.expandEntryBytes(alloc, &state.lex, it.sym);
        var esc: std.ArrayList(u8) = .empty;
        try escapeInto(alloc, b, &esc);
        try w.print("n={d}\tlen={d}\t|{s}|\n", .{ it.n, b.len, esc.items });
    }
    try w.flush();

    // Re-Pair comparison grammar (gprobe's "full" dump, binary rules).
    const rbytes = try std.Io.Dir.cwd().readFileAlloc(io, repair_dump_path, alloc, .limited(64 << 20));
    var rdump = try mlex.readB4SDv1(alloc, rbytes);
    var rstate = try mlex.seedFromV1(alloc, &rdump);
    const rrc = try mlex.recount(alloc, &rstate);
    var ritems: std.ArrayList(Item) = .empty;
    for (0..rstate.lex.numEntries()) |i| {
        const sym: u32 = @intCast(256 + i);
        if (rrc.n[sym] > 0) try ritems.append(alloc, .{ .sym = sym, .n = rrc.n[sym], .len = rstate.lex.explen.items[i] });
    }
    std.mem.sort(Item, ritems.items, {}, struct {
        fn f(_: void, x: Item, y: Item) bool {
            return x.n > y.n;
        }
    }.f);
    try w.print("-- Re-Pair ({s}): top 40 by count --\n", .{repair_dump_path});
    for (ritems.items[0..@min(40, ritems.items.len)]) |it| {
        const b = try mlex.expandEntryBytes(alloc, &rstate.lex, it.sym);
        var esc: std.ArrayList(u8) = .empty;
        try escapeInto(alloc, b, &esc);
        try w.print("n={d}\tlen={d}\t|{s}|\n", .{ it.n, b.len, esc.items });
    }
    try w.flush();

    var rmid: std.ArrayList(Item) = .empty;
    for (ritems.items) |it| if (it.len >= 6 and it.len <= 20) try rmid.append(alloc, it);
    var prng2 = std.Random.DefaultPrng.init(0xB4A5EED);
    const rnd2 = prng2.random();
    rnd2.shuffle(Item, rmid.items);
    try w.print("-- Re-Pair ({s}): 40 random entries, expansion length 6-20 (pool={d}) --\n", .{ repair_dump_path, rmid.items.len });
    for (rmid.items[0..@min(40, rmid.items.len)]) |it| {
        const b = try mlex.expandEntryBytes(alloc, &rstate.lex, it.sym);
        var esc: std.ArrayList(u8) = .empty;
        try escapeInto(alloc, b, &esc);
        try w.print("n={d}\tlen={d}\t|{s}|\n", .{ it.n, b.len, esc.items });
    }
    try w.flush();
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var output_buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &output_buffer);
    const w = &stdout.interface;
    try w.print("name\tblock\tvariant\tentries\ttokens\tbytes_per_token\tmodel_bytes\tpayload_bytes\ttotal_bytes\tbzip3_bytes\trepair_static_bytes\tpct_vs_bzip3\tpct_vs_repair_static\titerations\titerate_s\tencode_s\n", .{});
    try w.flush();

    for (files) |fs| {
        var file_arena = std.heap.ArenaAllocator.init(gpa);
        defer file_arena.deinit();
        const FA = file_arena.allocator();
        const raw = try std.Io.Dir.cwd().readFileAlloc(io, fs.path, FA, .limited(16 << 20));
        const file_bin = std.fs.path.basename(fs.path);

        for (fs.blocks) |block| {
            std.debug.print("=== {s} block={d} ({d} bytes) ===\n", .{ fs.name, block, raw.len });
            var combo_arena = std.heap.ArenaAllocator.init(gpa);
            defer combo_arena.deinit();
            const A = combo_arena.allocator();

            var seed_path_buf: [256]u8 = undefined;
            const seed_path = try std.fmt.bufPrint(&seed_path_buf, "dumps/a_{s}.{d}.best.b4sd", .{ fs.name, block });
            const dump_bytes = try std.Io.Dir.cwd().readFileAlloc(io, seed_path, A, .limited(64 << 20));
            var dump = try mlex.readB4SDv1(A, dump_bytes);
            if (dump.raw_len != raw.len) std.debug.print("  WARNING: seed raw_len={d} != file len={d}\n", .{ dump.raw_len, raw.len });

            var dump_path_buf: [256]u8 = undefined;
            const dump_path = try std.fmt.bufPrint(&dump_path_buf, "dumps/m_{s}.{d}.b4sd", .{ fs.name, block });

            // Primary: pairs + triples. Ablation: pairs only (no triples).
            try runVariant(A, io, w, fs.name, file_bin, block, raw, &dump, "a3seed_pairs_triples", true, dump_path);
            try runVariant(A, io, w, fs.name, file_bin, block, raw, &dump, "a3seed_pairs_only", false, null);
        }

        // Byte-seed ablation on two representative files (own arena; the
        // 8MB gcide.eval8 byte-seed run is slower to converge, per m_probe
        // exploration, but still finishes in single-digit seconds).
        if (std.mem.eql(u8, fs.name, "omw.untouched") or std.mem.eql(u8, fs.name, "gcide.eval8")) {
            var combo_arena = std.heap.ArenaAllocator.init(gpa);
            defer combo_arena.deinit();
            const A = combo_arena.allocator();
            const block: usize = 65536;
            var state = try mlex.seedBytes(A, raw, block);
            var log: std.ArrayList(mlex.IterLog) = .empty;
            const t0 = nowMs(io);
            try mlex.iterate(A, io, &state, raw, .{ .max_iters = 20, .triples = false }, &log);
            const t1 = nowMs(io);
            if (!try mlex.verifyExact(A, raw, &state)) return error.LexNotExact;
            var stats: mcodec.EncodeStats = undefined;
            const encoded = try mcodec.encodeWithRawLen(A, &state, raw.len, &stats);
            var decoded = try mcodec.decode(A, encoded);
            if (!mcodec.verifyDecode(raw, state.block_bytes, &decoded)) return error.CodecNotExact;
            try w.print(
                "{s}\t{d}\tbyteseed_pairs_only\t{d}\t{d}\t{d:.2}\t{d}\t{d}\t{d}\t0\t0\t0.0\t0.0\t{d}\t{d:.1}\t0.0\n",
                .{ fs.name, block, state.lex.numEntries(), state.seq.len, @as(f64, @floatFromInt(raw.len)) / @as(f64, @floatFromInt(state.seq.len)), stats.model_bytes, stats.payload_bytes, stats.total_bytes, log.items.len, (t1 - t0) / 1000.0 },
            );
            try w.flush();
            std.debug.print("  [byteseed ablation {s}] entries={d} tokens={d} total={d}B iters={d} dl_curve=[", .{ fs.name, state.lex.numEntries(), state.seq.len, stats.total_bytes, log.items.len });
            for (log.items, 0..) |l, i| {
                if (i > 0) std.debug.print(",", .{});
                std.debug.print("{d:.0}", .{l.dl_bytes});
            }
            std.debug.print("]\n", .{});
        }

        // Qualitative listing for gcide.eval8 and json.eval8 (block 65536).
        if (std.mem.eql(u8, fs.name, "gcide.eval8") or std.mem.eql(u8, fs.name, "json.eval8")) {
            var combo_arena = std.heap.ArenaAllocator.init(gpa);
            defer combo_arena.deinit();
            const A = combo_arena.allocator();
            const block: usize = 65536;
            var seed_path_buf: [256]u8 = undefined;
            const seed_path = try std.fmt.bufPrint(&seed_path_buf, "dumps/a_{s}.{d}.best.b4sd", .{ fs.name, block });
            const dump_bytes = try std.Io.Dir.cwd().readFileAlloc(io, seed_path, A, .limited(64 << 20));
            var dump = try mlex.readB4SDv1(A, dump_bytes);
            var state = try mlex.seedFromV1(A, &dump);
            var log: std.ArrayList(mlex.IterLog) = .empty;
            try mlex.iterate(A, io, &state, raw, .{ .max_iters = 20, .triples = true }, &log);
            if (!try mlex.verifyExact(A, raw, &state)) return error.LexNotExact;
            var repair_path_buf: [256]u8 = undefined;
            const repair_path = try std.fmt.bufPrint(&repair_path_buf, "dumps/{s}.64k.full.b4sd", .{fs.name});
            try qualitative(A, io, w, fs.name, &state, repair_path);
        }
    }
    try w.flush();
}
