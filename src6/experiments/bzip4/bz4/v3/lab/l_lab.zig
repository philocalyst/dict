//! l_lab: Lane L measurement harness -- driver for `l_learn.zig`.
//!
//! For every required (file, block) combo: learn a lexicon, assert the
//! parse re-expands to the exact input, print one TSV row of the est cost
//! breakdown (DEF/USE/arity/name bits, milestone-1 global total and
//! milestone-2 scoped total), and write a B4SD v2 dump under `dumps/l_*`
//! so the dump can also be fed to the lead's real v3 codec
//! (`v3/zig-out/bin/lab DATA DUMP`) for a real-bytes cross-check -- see
//! `LANE_L.md`.
//!
//! usage: l_lab   (no arguments; run from the bz4/ directory so the
//! relative `data/` and `dumps/` paths resolve, matching every other lane's
//! driver, e.g. `bin/m_lab`.)

const std = @import("std");
const Allocator = std.mem.Allocator;
const llearn = @import("l_learn.zig");

fn nowMs(io: std.Io) f64 {
    return @as(f64, @floatFromInt(std.Io.Clock.awake.now(io).nanoseconds)) / 1e6;
}

fn writeB4SDv2(alloc: Allocator, io: std.Io, path: []const u8, corpus: *const llearn.Corpus, raw_len: usize) !void {
    var out: std.ArrayList(u32) = .empty;
    try out.appendSlice(alloc, &.{
        0x44533442, // "B4SD"
        2, // version
        @intCast(corpus.lex.numEntries()),
        @intCast(corpus.block_end.len),
        @intCast(corpus.block_bytes),
        @intCast(raw_len),
    });
    for (0..corpus.lex.numEntries()) |i| {
        const cs = corpus.lex.comps(i);
        try out.append(alloc, @intCast(cs.len));
        try out.appendSlice(alloc, cs);
    }
    var start: usize = 0;
    for (corpus.block_end) |end| {
        try out.append(alloc, @intCast(end - start));
        try out.appendSlice(alloc, corpus.seq[start..end]);
        start = end;
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = std.mem.sliceAsBytes(out.items) });
}

fn escapeInto(alloc: Allocator, bytes: []const u8, out: *std.ArrayList(u8)) !void {
    for (bytes) |byte| {
        if (byte >= 0x20 and byte < 0x7f and byte != '\'' and byte != '\\' and byte != '|') {
            try out.append(alloc, byte);
        } else {
            try out.print(alloc, "\\x{x:0>2}", .{byte});
        }
    }
}

const QItem = struct { sym: u32, n: u64, len: u32 };
fn qByCountDesc(_: void, a: QItem, b: QItem) bool {
    return a.n > b.n;
}

/// PLAN's qualitative-evidence ask, ported to Lane L's own lexicon: 40
/// most-frequent multi-byte entries, and an evenly-spaced sample of up to
/// 40 entries with expansion length 6-20 (the mid-length "is it a word"
/// zone), so the listing can be compared next to LANE_M.md's directly.
fn printQualitative(alloc: Allocator, w: anytype, tag: []const u8, corpus: *const llearn.Corpus) !void {
    const n = corpus.lex.numEntries();
    const pop = try llearn.population(alloc, corpus);
    var items: std.ArrayList(QItem) = .empty;
    for (0..n) |i| {
        const c = pop[256 + i];
        if (c == 0) continue;
        try items.append(alloc, .{ .sym = @intCast(256 + i), .n = c, .len = corpus.lex.explen.items[i] });
    }
    std.mem.sort(QItem, items.items, {}, qByCountDesc);

    try w.print("\n=== {s}: top 40 entries by use count ===\n", .{tag});
    for (items.items[0..@min(40, items.items.len)]) |it| {
        const bytes = try llearn.expandEntryBytes(alloc, &corpus.lex, it.sym);
        var esc: std.ArrayList(u8) = .empty;
        try escapeInto(alloc, bytes, &esc);
        try w.print("n={d:<6} len={d:<3} |{s}|\n", .{ it.n, it.len, esc.items });
    }

    var pool: std.ArrayList(QItem) = .empty;
    for (items.items) |it| {
        if (it.len >= 6 and it.len <= 20) try pool.append(alloc, it);
    }
    try w.print("\n=== {s}: 40 sampled entries, expansion length 6-20 (pool of {d}) ===\n", .{ tag, pool.items.len });
    const stride = @max(1, pool.items.len / 40);
    var shown: usize = 0;
    var idx: usize = 0;
    while (idx < pool.items.len and shown < 40) : (idx += stride) {
        const it = pool.items[idx];
        const bytes = try llearn.expandEntryBytes(alloc, &corpus.lex, it.sym);
        var esc: std.ArrayList(u8) = .empty;
        try escapeInto(alloc, bytes, &esc);
        try w.print("n={d:<6} len={d:<3} |{s}|\n", .{ it.n, it.len, esc.items });
        shown += 1;
    }
    try w.flush();
}

fn runOne(gpa: Allocator, io: std.Io, w: anytype, name: []const u8, data: []const u8, block_bytes: usize, dump_dir: []const u8, qualitative: bool) !void {
    const t0 = nowMs(io);
    var parse = try llearn.learn(gpa, data, block_bytes, .{});
    defer parse.deinit(gpa);
    const t1 = nowMs(io);

    if (!try llearn.verifyExact(gpa, data, &parse.corpus)) {
        std.debug.print("FAIL roundtrip: {s} block={d}\n", .{ name, block_bytes });
        return error.RoundTripMismatch;
    }

    const s = parse.stats;
    const btoken: f64 = if (s.num_tokens == 0) 0 else @as(f64, @floatFromInt(data.len)) / @as(f64, @floatFromInt(s.num_tokens));
    try w.print("{s}\t{d}\t{d}\t{d}\t{d:.2}\t{d:.0}\t{d:.0}\t{d:.0}\t{d:.0}\t{d:.0}\t{d}\t{d:.0}\t{d}\t{d:.1}\n", .{
        name,                       block_bytes,
        s.num_entries,              s.num_tokens,
        btoken,                     s.def_bits / 8.0,
        s.use_bits / 8.0,           s.arity_bits / 8.0,
        s.name_bits / 8.0,          s.total_bits_global / 8.0,
        s.num_local_entries,        s.total_bits_scoped / 8.0,
        s.iterations,               (t1 - t0) / 1000.0,
    });
    try w.flush();

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/l_{s}.{d}.b4sd", .{ dump_dir, name, block_bytes });
    try writeB4SDv2(gpa, io, path, &parse.corpus, data.len);

    if (qualitative) try printQualitative(gpa, w, name, &parse.corpus);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var output_buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &output_buffer);
    const w = &stdout.interface;
    try w.print("name\tblock\tentries\ttokens\tB_per_token\tdef_B\tuse_B\tarity_B\tname_B\ttotal_B_global\tnum_local\ttotal_B_scoped\titers\tseconds\n", .{});
    try w.flush();

    const dump_dir = "dumps";
    const DictFile = struct { name: []const u8 };
    const dict_files = [_]DictFile{ .{ .name = "freedict" }, .{ .name = "gcide" }, .{ .name = "omw" } };

    for (dict_files) |df| {
        var file_arena = std.heap.ArenaAllocator.init(gpa);
        defer file_arena.deinit();
        const FA = file_arena.allocator();

        const eval8_path = try std.fmt.allocPrint(FA, "data/{s}.eval8.bin", .{df.name});
        const raw = try std.Io.Dir.cwd().readFileAlloc(io, eval8_path, FA, .limited(16 << 20));

        const name_65536 = try std.fmt.allocPrint(FA, "{s}.eval8", .{df.name});
        try runOne(gpa, io, w, name_65536, raw, 65536, dump_dir, true);
        try runOne(gpa, io, w, name_65536, raw, 16384, dump_dir, false);

        inline for (.{ .{ "4k", 4096 }, .{ "32k", 32768 }, .{ "256k", 262144 } }) |spec| {
            const n = @min(@as(usize, spec[1]), raw.len);
            const nm = try std.fmt.allocPrint(FA, "{s}.{s}", .{ df.name, spec[0] });
            try runOne(gpa, io, w, nm, raw[0..n], n, dump_dir, false);
        }

        const untouched_path = try std.fmt.allocPrint(FA, "data/{s}.untouched.bin", .{df.name});
        const raw_u = try std.Io.Dir.cwd().readFileAlloc(io, untouched_path, FA, .limited(2 << 20));
        const name_u = try std.fmt.allocPrint(FA, "{s}.untouched", .{df.name});
        try runOne(gpa, io, w, name_u, raw_u, 65536, dump_dir, false);
    }

    // Secondary generality files (json/macho/zigsrc), 65536 only.
    const secondary = [_][]const u8{ "json", "macho", "zigsrc" };
    for (secondary) |nm| {
        var file_arena = std.heap.ArenaAllocator.init(gpa);
        defer file_arena.deinit();
        const FA = file_arena.allocator();
        const path = try std.fmt.allocPrint(FA, "data/{s}.eval8.bin", .{nm});
        const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, FA, .limited(16 << 20));
        const name = try std.fmt.allocPrint(FA, "{s}.eval8", .{nm});
        try runOne(gpa, io, w, name, raw, 65536, dump_dir, false);
    }
}
