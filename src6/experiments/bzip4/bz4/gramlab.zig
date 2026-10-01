//! gramlab: Lane A measurement harness.
//!
//! Builds several grammar variants (A1 baseline sweep, A3 alt priority, A2
//! MDL deletion, A4 optimal re-parse) for every (file, block) combination
//! required by the lab, verifies each grammar is exact (every block's
//! roots expand back to the raw bytes, no rule spanning a barrier), prints
//! one TSV row per (file, block, variant), and writes the best grammar
//! found for each (file, block) to dumps/a_<file>.<block>.best.b4sd in the
//! same format gprobe uses.
//!
//! usage: gramlab   (no arguments; paths are relative to bz4/)

const std = @import("std");
const gram = @import("grammar2.zig");

const rule_bits_default: f64 = 13.0;
const reparse_max_len: u32 = 256;
const reparse_iters: usize = 3;
const mdl_max_rounds: usize = 8;

const FileSpec = struct {
    name: []const u8,
    path: []const u8,
    blocks: []const usize,
};

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

fn nowMs(io: std.Io) f64 {
    return @as(f64, @floatFromInt(std.Io.Clock.awake.now(io).nanoseconds)) / 1e6;
}

fn reportRow(
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    file: []const u8,
    block: usize,
    variant: []const u8,
    gm: *const gram.Grammar,
    build_ms: f64,
) !void {
    const rc = try gram.rootCounts(alloc, gm);
    defer alloc.free(rc.g);
    const parent = try gram.parentCounts(alloc, gm.rules.items);
    defer alloc.free(parent);
    const tv = try gram.trivialMask(alloc, parent, rc.g);
    defer alloc.free(tv);
    var trivial_count: usize = 0;
    for (tv) |t| {
        if (t) trivial_count += 1;
    }
    const c10 = gram.objective(rc.g, rc.m, gm.rules.items.len, 10.0, null);
    const c13 = gram.objective(rc.g, rc.m, gm.rules.items.len, 13.0, null);
    const c16 = gram.objective(rc.g, rc.m, gm.rules.items.len, 16.0, null);
    const cdt = gram.objective(rc.g, rc.m, gm.rules.items.len, 13.0, tv);
    try w.print("{s}\t{d}\t{s}\t{d}\t{d}\t{d}\t{d:.1}\t{d:.1}\t{d:.1}\t{d:.1}\t{d:.1}\n", .{
        file,     block,           variant,         gm.rules.items.len, gm.seq.len,
        trivial_count, c10.total_bytes, c13.total_bytes, c16.total_bytes,    cdt.total_bytes,
        build_ms,
    });
    try w.flush();
}

fn costAt13(alloc: std.mem.Allocator, gm: *const gram.Grammar) !f64 {
    const c = try gram.costOf(alloc, gm, rule_bits_default);
    return c.total_bytes;
}

fn writeDump(alloc: std.mem.Allocator, io: std.Io, path: []const u8, gm: *const gram.Grammar, raw_len: usize) !void {
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, &.{ 0x44533442, 1, @intCast(gm.rules.items.len), @intCast(gm.block_end.len), @intCast(gm.block_bytes), @intCast(raw_len) });
    for (gm.rules.items) |r| try out.appendSlice(alloc, &.{ r.a, r.b });
    var start: usize = 0;
    for (gm.block_end) |end| {
        try out.append(alloc, @intCast(end - start));
        try out.appendSlice(alloc, gm.seq[start..end]);
        start = end;
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = std.mem.sliceAsBytes(out.items) });
}

const Candidate = struct { name: []const u8, gm: gram.Grammar, cost13: f64 };

fn runCombo(
    gpa: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    name: []const u8,
    input: []const u8,
    block: usize,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const A = arena_state.allocator();

    var cands: std.ArrayList(Candidate) = .empty;

    // ---- A1: baseline builder, sweep min_freq to show the curve. ----
    const min_freqs = [_]u32{ 2, 3, 4, 6 };
    var a1_mf2: ?gram.Grammar = null;
    for (min_freqs) |mf| {
        const t0 = nowMs(io);
        var gm = try gram.build(A, input, block, .{ .min_freq = mf, .alpha_percent = 50, .priority = .freq, .fast_count = true });
        const t1 = nowMs(io);
        if (!try gram.verifyExact(A, input, &gm)) return error.NotExact;
        var buf: [32]u8 = undefined;
        const label = try std.fmt.bufPrint(&buf, "a1_mf{d}", .{mf});
        try reportRow(A, w, name, block, label, &gm, t1 - t0);
        if (mf == 2) {
            a1_mf2 = gm;
            try cands.append(A, .{ .name = "a1_mf2", .gm = gm, .cost13 = try costAt13(A, &gm) });
        }
    }

    // ---- A3: saving-priority selection instead of raw frequency. ----
    {
        const t0 = nowMs(io);
        var gm = try gram.build(A, input, block, .{ .min_freq = 2, .alpha_percent = 50, .priority = .saving, .fast_count = true });
        const t1 = nowMs(io);
        if (!try gram.verifyExact(A, input, &gm)) return error.NotExact;
        try reportRow(A, w, name, block, "a3_saving", &gm, t1 - t0);
        try cands.append(A, .{ .name = "a3_saving", .gm = gm, .cost13 = try costAt13(A, &gm) });
    }

    // ---- A2: MDL deletion pass on top of a1_mf2 and a3. ----
    {
        var base = try a1_mf2.?.clone(A);
        const t0 = nowMs(io);
        const stats = try gram.mdlDelete(A, &base, rule_bits_default, mdl_max_rounds);
        const t1 = nowMs(io);
        if (!try gram.verifyExact(A, input, &base)) return error.NotExact;
        try reportRow(A, w, name, block, "a1_mf2+a2", &base, t1 - t0);
        std.debug.print("  [a2] {s} block={d}: deleted {d} rules in {d} rounds, est {d:.0}B -> {d:.0}B\n", .{ name, block, stats.deleted, stats.rounds, stats.before_bytes, stats.after_bytes });
        try cands.append(A, .{ .name = "a1_mf2+a2", .gm = base, .cost13 = try costAt13(A, &base) });
    }
    {
        var base = try cands.items[1].gm.clone(A); // a3_saving
        const t0 = nowMs(io);
        const stats = try gram.mdlDelete(A, &base, rule_bits_default, mdl_max_rounds);
        const t1 = nowMs(io);
        if (!try gram.verifyExact(A, input, &base)) return error.NotExact;
        try reportRow(A, w, name, block, "a3+a2", &base, t1 - t0);
        std.debug.print("  [a2] {s} block={d} (a3 base): deleted {d} rules in {d} rounds, est {d:.0}B -> {d:.0}B\n", .{ name, block, stats.deleted, stats.rounds, stats.before_bytes, stats.after_bytes });
        try cands.append(A, .{ .name = "a3+a2", .gm = base, .cost13 = try costAt13(A, &base) });
    }

    // ---- pick the best so far, then try A4 optimal re-parse on top. ----
    {
        var best_idx: usize = 0;
        for (cands.items, 0..) |c, i| if (c.cost13 < cands.items[best_idx].cost13) {
            best_idx = i;
        };
        var base = try cands.items[best_idx].gm.clone(A);
        const t0 = nowMs(io);
        const stats = try gram.optimalReparse(A, &base, input, rule_bits_default, reparse_max_len, reparse_iters);
        const t1 = nowMs(io);
        if (!try gram.verifyExact(A, input, &base)) return error.NotExact;
        var buf: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&buf, "{s}+a4", .{cands.items[best_idx].name});
        try reportRow(A, w, name, block, label, &base, t1 - t0);
        std.debug.print("  [a4] {s} block={d} (base {s}, trie {d} syms): est {d:.0}B -> {d:.0}B\n", .{ name, block, cands.items[best_idx].name, stats.trie_symbols, stats.before_bytes, stats.after_bytes });
        try cands.append(A, .{ .name = label, .gm = base, .cost13 = try costAt13(A, &base) });
    }

    // ---- write the overall best grammar as a B4SD dump for other lanes. ----
    {
        var best_idx: usize = 0;
        for (cands.items, 0..) |c, i| if (c.cost13 < cands.items[best_idx].cost13) {
            best_idx = i;
        };
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "dumps/a_{s}.{d}.best.b4sd", .{ name, block });
        try writeDump(A, io, path, &cands.items[best_idx].gm, input.len);
        std.debug.print("  [best] {s} block={d}: variant={s} est={d:.0}B -> {s}\n", .{ name, block, cands.items[best_idx].name, cands.items[best_idx].cost13, path });
    }

    // ---- A6: speed comparison (fast_count on vs off) on the big files. ----
    if (input.len >= 8 * 1024 * 1024) {
        const t0 = nowMs(io);
        var gm = try gram.build(A, input, block, .{ .min_freq = 2, .alpha_percent = 50, .priority = .freq, .fast_count = false });
        const t1 = nowMs(io);
        if (!try gram.verifyExact(A, input, &gm)) return error.NotExact;
        try reportRow(A, w, name, block, "a1_mf2_slow", &gm, t1 - t0);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var output_buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &output_buffer);
    const w = &stdout.interface;
    try w.print("file\tblock\tvariant\trules\troots\ttrivial_rules\test_rb10\test_rb13\test_rb16\test_deftree\tbuild_ms\n", .{});
    try w.flush();

    for (files) |fs| {
        const input = try std.Io.Dir.cwd().readFileAlloc(io, fs.path, gpa, .limited(16 << 20));
        defer gpa.free(input);
        for (fs.blocks) |block| {
            std.debug.print("=== {s} block={d} ({d} bytes) ===\n", .{ fs.name, block, input.len });
            try runCombo(gpa, io, w, fs.name, input, block);
        }
    }
    try w.flush();
}
