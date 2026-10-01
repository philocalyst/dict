//! Lane Z1 measurement harness.
//!
//! usage:
//!   bench FILE BLOCK_BYTES [REPEATS]     one results_v2.tsv row
//!   bench ablation FILE BLOCK_BYTES      stage a/b/c real sizes, one line each
//!   bench csweep FILE BLOCK_BYTES        C in {32,64,128,256} at the
//!                                        classes-only stage, one line each
//!
//! FILE is a bare basename read from `../data/FILE` (this binary is meant
//! to be run from `pkg/`, matching PLAN's "../data relative to pkg").
//! `../baselines.tsv` (bzip3) and `../results_v1.tsv` (bz4 v1) are looked
//! up by (basename, block_bytes) for the pct-vs columns. Every measurement
//! is a real encode -> real decode -> byte-compare in this same run
//! (verified once, untimed, before any timing is trusted), per PLAN's
//! rules of evidence. Run SERIALLY, one file at a time.
//!
//! Pure Zig 0.16, std only.

const std = @import("std");
const bz4 = @import("bz4v2");

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}
fn elapsedMs(io: std.Io, t0: i96) f64 {
    return @as(f64, @floatFromInt(nowNs(io) - t0)) / 1e6;
}
fn medianF64(vals: []f64) f64 {
    std.mem.sort(f64, vals, {}, std.sort.asc(f64));
    const n = vals.len;
    if (n % 2 == 1) return vals[n / 2];
    return (vals[n / 2 - 1] + vals[n / 2]) / 2.0;
}

const BaselineRow = struct { total_bytes: u64, decode_mbps: f64 };

fn lookupTsv(alloc: std.mem.Allocator, io: std.Io, path: []const u8, basename: []const u8, block_bytes: usize, total_col: usize, mbps_col: usize) !?BaselineRow {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return null;
    defer alloc.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    _ = lines.next(); // header
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        var col: usize = 0;
        var f_file: ?[]const u8 = null;
        var f_block: ?[]const u8 = null;
        var f_total: ?[]const u8 = null;
        var f_mbps: ?[]const u8 = null;
        while (fields.next()) |field| : (col += 1) {
            if (col == 0) f_file = field;
            if (col == 1) f_block = field;
            if (col == total_col) f_total = field;
            if (col == mbps_col) f_mbps = field;
        }
        if (f_file == null or f_block == null or f_total == null or f_mbps == null) continue;
        if (!std.mem.eql(u8, f_file.?, basename)) continue;
        const block_val = std.fmt.parseUnsigned(usize, f_block.?, 10) catch continue;
        if (block_val != block_bytes) continue;
        const total = std.fmt.parseUnsigned(u64, f_total.?, 10) catch continue;
        const mbps = std.fmt.parseFloat(f64, f_mbps.?) catch continue;
        return .{ .total_bytes = total, .decode_mbps = mbps };
    }
    return null;
}

fn lookupBzip3(alloc: std.mem.Allocator, io: std.Io, basename: []const u8, block_bytes: usize) !?BaselineRow {
    // baselines.tsv: file block_bytes block_count payload_bytes total_bytes
    //   encode_ms decode_min_ms decode_median_ms decode_MBps
    return lookupTsv(alloc, io, "../baselines.tsv", basename, block_bytes, 4, 8);
}

fn lookupV1(alloc: std.mem.Allocator, io: std.Io, basename: []const u8, block_bytes: usize) !?BaselineRow {
    // results_v1.tsv: file block_bytes rules roots model_bytes
    //   directory_bytes payload_bytes total_bytes bzip3_total pct_vs_bzip3
    //   encode_ms startup_ms decode_min_ms decode_median_ms decode_MBps ...
    return lookupTsv(alloc, io, "../results_v1.tsv", basename, block_bytes, 7, 14);
}

const default_class_params: bz4.classes.Params = .{};

fn readInput(alloc: std.mem.Allocator, io: std.Io, basename: []const u8) ![]u8 {
    var buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "../data/{s}", .{basename});
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 30));
}

fn runMain(gpa: std.mem.Allocator, io: std.Io, basename: []const u8, block_bytes: usize, repeats: usize) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const input = try readInput(a, io, basename);

    const t_enc0 = nowNs(io);
    var corpus = try bz4.lexicon.seedBytes(a, input, block_bytes);
    var log: std.ArrayList(bz4.learn.IterLog) = .empty;
    try bz4.learn.iterate(a, &corpus, input, .{}, &log);
    const result = try bz4.joint.run(a, input, &corpus, default_class_params, 3);
    const encode_s = elapsedMs(io, t_enc0) / 1000.0;

    // Untimed verify before any timing is trusted.
    {
        var frame = try bz4.open(a, result.final.bytes);
        defer frame.deinit();
        const out = try a.alloc(u8, input.len);
        try frame.decodeAll(out);
        if (!std.mem.eql(u8, out, input)) return error.RoundtripMismatch;
    }

    const t_open0 = nowNs(io);
    var frame = try bz4.open(a, result.final.bytes);
    const startup_ms = elapsedMs(io, t_open0);
    defer frame.deinit();

    const out = try a.alloc(u8, input.len);
    const pass_ms = try a.alloc(f64, repeats);
    for (pass_ms) |*slot| {
        const t0 = nowNs(io);
        try frame.decodeAll(out);
        slot.* = elapsedMs(io, t0);
    }
    const decode_median_ms = medianF64(pass_ms);
    const decode_mbps = (@as(f64, @floatFromInt(input.len)) / 1.0e6) / (decode_median_ms / 1000.0);

    const v1 = try lookupV1(a, io, basename, block_bytes);
    const bz3 = try lookupBzip3(a, io, basename, block_bytes);
    const v1_total: i64 = if (v1) |v| @intCast(v.total_bytes) else -1;
    const bzip3_total: i64 = if (bz3) |b| @intCast(b.total_bytes) else -1;
    const bzip3_mbps: f64 = if (bz3) |b| b.decode_mbps else std.math.nan(f64);
    const total_f: f64 = @floatFromInt(result.final.bytes.len);
    const pct_vs_v1: f64 = if (v1) |v| (total_f - @as(f64, @floatFromInt(v.total_bytes))) / @as(f64, @floatFromInt(v.total_bytes)) * 100.0 else std.math.nan(f64);
    const pct_vs_bzip3: f64 = if (bz3) |b| (total_f - @as(f64, @floatFromInt(b.total_bytes))) / @as(f64, @floatFromInt(b.total_bytes)) * 100.0 else std.math.nan(f64);

    var outbuf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &outbuf);
    // file block entries tokens classes overrides lexicon_bytes
    // classmodel_bytes directory_bytes payload_bytes total_bytes v1_total
    // pct_vs_v1 bzip3_total pct_vs_bzip3 encode_s startup_ms
    // decode_median_ms decode_MBps bzip3_decode_MBps  (20 columns)
    try writer.interface.print(
        "{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d:.2}\t{d}\t{d:.2}\t{d:.3}\t{d:.3}\t{d:.3}\t{d:.2}\t{d:.2}\n",
        .{
            basename,
            block_bytes,
            result.final.stats.entries,
            result.final.stats.tokens,
            result.final.stats.classes_used,
            result.final.stats.overrides,
            result.final.stats.lexicon_bytes,
            result.final.stats.classmodel_bytes,
            result.final.stats.directory_bytes,
            result.final.stats.payload_bytes,
            result.final.bytes.len,
            v1_total,
            pct_vs_v1,
            bzip3_total,
            pct_vs_bzip3,
            encode_s,
            startup_ms,
            decode_median_ms,
            decode_mbps,
            bzip3_mbps,
        },
    );
    try writer.interface.flush();
}

fn runAblation(gpa: std.mem.Allocator, io: std.Io, basename: []const u8, block_bytes: usize) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const input = try readInput(a, io, basename);
    var corpus = try bz4.lexicon.seedBytes(a, input, block_bytes);
    var log: std.ArrayList(bz4.learn.IterLog) = .empty;
    try bz4.learn.iterate(a, &corpus, input, .{}, &log);

    const result = try bz4.joint.run(a, input, &corpus, default_class_params, 3);

    var outbuf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &outbuf);
    try writer.interface.print("{s}\t{d}\ta_order0\t{d}\n", .{ basename, block_bytes, result.order0_bytes });
    try writer.interface.print("{s}\t{d}\tb_classes_no_refine\t{d}\n", .{ basename, block_bytes, result.classes_bytes });
    var last = result.classes_bytes;
    for (result.rounds) |r| {
        try writer.interface.print("{s}\t{d}\tc_joint_round{d}\t{d}\t{s}\n", .{ basename, block_bytes, r.round, r.total_bytes, if (r.accepted) "accepted" else "rejected" });
        if (r.accepted) last = r.total_bytes;
    }
    try writer.interface.print("{s}\t{d}\tc_joint_final\t{d}\n", .{ basename, block_bytes, last });
    try writer.interface.flush();
}

fn runCSweep(gpa: std.mem.Allocator, io: std.Io, basename: []const u8, block_bytes: usize) !void {
    const cs = [_]u32{ 32, 64, 128, 256 };
    var outbuf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &outbuf);
    for (cs) |c| {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();

        const input = try readInput(a, io, basename);
        var corpus = try bz4.lexicon.seedBytes(a, input, block_bytes);
        var log: std.ArrayList(bz4.learn.IterLog) = .empty;
        try bz4.learn.iterate(a, &corpus, input, .{}, &log);

        const asm_ = try bz4.frame.assemble(a, input, &corpus, .{ .C = c, .g_min = default_class_params.g_min });
        try writer.interface.print("{s}\t{d}\tC={d}\t{d}\n", .{ basename, block_bytes, c, asm_.bytes.len });
        try writer.interface.flush();
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const a1 = it.next() orelse return error.Usage;

    if (std.mem.eql(u8, a1, "ablation")) {
        const file = it.next() orelse return error.Usage;
        const block = try std.fmt.parseUnsigned(usize, it.next() orelse return error.Usage, 10);
        return runAblation(gpa, io, file, block);
    } else if (std.mem.eql(u8, a1, "csweep")) {
        const file = it.next() orelse return error.Usage;
        const block = try std.fmt.parseUnsigned(usize, it.next() orelse return error.Usage, 10);
        return runCSweep(gpa, io, file, block);
    } else {
        const block = try std.fmt.parseUnsigned(usize, it.next() orelse return error.Usage, 10);
        const repeats: usize = if (it.next()) |r| try std.fmt.parseUnsigned(usize, r, 10) else 5;
        return runMain(gpa, io, a1, block, repeats);
    }
}
