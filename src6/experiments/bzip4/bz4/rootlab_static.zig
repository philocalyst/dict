//! rootlab_static: measurement driver for Lane S (bz4 lab, see PLAN.md and
//! LANE_S.md). Takes a B4SD dump and its matching raw file, builds the
//! expansion table plus the two static root codecs (canonical
//! length-limited Huffman, static power-of-two range/rANS-style code),
//! verifies byte-exact roundtrip (full frame + independent single-block
//! decode) against the real raw file, and prints one TSV line per coder.
//!
//! usage: rootlab_static DUMP RAWFILE [--bench-opts]
//!
//! `--bench-opts` additionally times the naive-vs-table Huffman decode, the
//! binary-search-vs-slot-table range decode, and the memcpy-vs-overshoot
//! copy, all on this same dump, and prints `#opt` comment lines.
//!
//! Pure Zig 0.16, std only.

const std = @import("std");
const rs = @import("rootstatic.zig");

fn median7(samples: [7]u64) u64 {
    var s = samples;
    std.mem.sort(u64, &s, {}, std.sort.asc(u64));
    return s[3];
}

const Timer = struct {
    io: std.Io,
    t0: i96,
    fn start(io: std.Io) Timer {
        return .{ .io = io, .t0 = std.Io.Clock.awake.now(io).nanoseconds };
    }
    fn ns(self: Timer) u64 {
        return @intCast(std.Io.Clock.awake.now(self.io).nanoseconds - self.t0);
    }
};

fn basename(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/') return path[i..];
    }
    return path;
}

/// Run a full-file fast decode once, writing into `out` (size raw_len +
/// overscan_pad). Returns elapsed ns. Correctness is NOT checked here (see
/// the checked pass in main) -- this is purely for timing the hot loop.
fn fullDecodeHuffmanFastNs(io: std.Io, huf: *const rs.Huffman, exp: *const rs.Expansion, frame: rs.Frame, block_bytes: u32, block_count: u32, out: []u8) !u64 {
    const t = Timer.start(io);
    for (0..block_count) |b| {
        const raw_start = b * block_bytes;
        _ = try rs.decodeHuffman(false, true, true, huf, exp, frame, b, out[raw_start..]);
    }
    return t.ns();
}

fn fullDecodeRangeFastNs(io: std.Io, model: *const rs.RangeModel, exp: *const rs.Expansion, frame: rs.Frame, block_bytes: u32, block_count: u32, out: []u8) !u64 {
    const t = Timer.start(io);
    for (0..block_count) |b| {
        const raw_start = b * block_bytes;
        _ = try rs.decodeRange(false, true, true, model, exp, frame, b, out[raw_start..]);
    }
    return t.ns();
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const dump_path = it.next() orelse return error.Usage;
    const raw_path = it.next() orelse return error.Usage;
    var bench_opts = false;
    if (it.next()) |flag| bench_opts = std.mem.eql(u8, flag, "--bench-opts");

    const dump_bytes = try std.Io.Dir.cwd().readFileAlloc(io, dump_path, alloc, .limited(1 << 30));
    defer alloc.free(dump_bytes);
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, raw_path, alloc, .limited(1 << 30));
    defer alloc.free(raw);

    var dump = try rs.parseDump(alloc, dump_bytes);
    defer dump.deinit(alloc);
    if (dump.raw_len != raw.len) {
        std.debug.print("FATAL {s}: dump raw_len={d} != rawfile len={d}\n", .{ dump_path, dump.raw_len, raw.len });
        return error.RawMismatch;
    }

    var exp = try rs.buildExpansion(alloc, io, dump);
    defer exp.deinit(alloc);

    var alphabet = try rs.buildAlphabet(alloc, dump);
    defer alphabet.deinit(alloc);
    const h0 = rs.h0Bytes(alphabet);
    const alphabet_size = dump.alphabetSize();

    const name = basename(dump_path);

    // ---------------- Huffman ----------------
    {
        var huf = try rs.buildHuffman(alloc, io, alphabet, alphabet_size);
        defer huf.deinit(alloc);
        var enc = try rs.buildHuffmanEncodeTable(alloc, huf, alphabet);
        defer enc.deinit(alloc);

        var frame = try rs.encodeHuffmanFrame(alloc, dump, enc);
        defer frame.deinit(alloc);
        rs.stampCrcs(&frame, dump, raw);

        try rs.decodeFullHuffmanChecked(alloc, &huf, &exp, frame, raw);
        try verifySingleBlocksHuffman(alloc, &huf, &exp, frame, dump, raw);

        const out = try alloc.alloc(u8, raw.len + rs.overscan_pad);
        defer alloc.free(out);
        var samples: [7]u64 = undefined;
        for (&samples) |*s| s.* = try fullDecodeHuffmanFastNs(io, &huf, &exp, frame, dump.block_bytes, dump.block_count, out);
        const med = median7(samples);

        const mid_block = dump.block_count / 2;
        const sb_reps: u32 = 4000;
        const sb_t = Timer.start(io);
        for (0..sb_reps) |_| _ = try rs.decodeHuffman(false, true, true, &huf, &exp, frame, mid_block, out[mid_block * dump.block_bytes ..]);
        const sb_ns = sb_t.ns();

        var max_len: u32 = 0;
        for (huf.length) |l| max_len = @max(max_len, l);

        printLine(.{
            .dump = name,
            .coder = "huffman",
            .n_sym = alphabet.n,
            .alphabet_size = alphabet_size,
            .code_param = max_len,
            .payload_bytes = frame.payload.len,
            .total_bytes = frame.bytes.len,
            .h0_bytes = h0,
            .arena_bytes = exp.arena_used,
            .arena_build_ms = nsToMs(exp.build_ns),
            .table_build_ms = nsToMs(huf.build_ns),
            .decode_ms = nsToMs(med),
            .raw_len = raw.len,
            .total_roots = dump.seq.len,
            .single_block_us = @as(f64, @floatFromInt(sb_ns)) / @as(f64, @floatFromInt(sb_reps)) / 1000.0,
        });

        if (bench_opts) try benchHuffmanOpts(io, &huf, &exp, frame, dump);
    }

    // ---------------- Static range/rANS ----------------
    {
        const bits = rs.chooseRangeBits(alphabet.n);
        var model = try rs.buildRangeModel(alloc, io, alphabet, bits);
        defer model.deinit(alloc);

        var frame = try rs.encodeRangeFrame(alloc, dump, alphabet, model);
        defer frame.deinit(alloc);
        rs.stampCrcs(&frame, dump, raw);

        try rs.decodeFullRangeChecked(alloc, &model, &exp, frame, raw);
        try verifySingleBlocksRange(alloc, &model, &exp, frame, dump, raw);

        const out = try alloc.alloc(u8, raw.len + rs.overscan_pad);
        defer alloc.free(out);
        var samples: [7]u64 = undefined;
        for (&samples) |*s| s.* = try fullDecodeRangeFastNs(io, &model, &exp, frame, dump.block_bytes, dump.block_count, out);
        const med = median7(samples);

        const mid_block = dump.block_count / 2;
        const sb_reps: u32 = 4000;
        const sb_t = Timer.start(io);
        for (0..sb_reps) |_| _ = try rs.decodeRange(false, true, true, &model, &exp, frame, mid_block, out[mid_block * dump.block_bytes ..]);
        const sb_ns = sb_t.ns();

        printLine(.{
            .dump = name,
            .coder = "range",
            .n_sym = alphabet.n,
            .alphabet_size = alphabet_size,
            .code_param = bits,
            .payload_bytes = frame.payload.len,
            .total_bytes = frame.bytes.len,
            .h0_bytes = h0,
            .arena_bytes = exp.arena_used,
            .arena_build_ms = nsToMs(exp.build_ns),
            .table_build_ms = nsToMs(model.build_ns),
            .decode_ms = nsToMs(med),
            .raw_len = raw.len,
            .total_roots = dump.seq.len,
            .single_block_us = @as(f64, @floatFromInt(sb_ns)) / @as(f64, @floatFromInt(sb_reps)) / 1000.0,
        });

        if (bench_opts) try benchRangeOpts(io, &model, &exp, frame, dump);
    }
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

const Row = struct {
    dump: []const u8,
    coder: []const u8,
    n_sym: u32,
    alphabet_size: u32,
    code_param: u32, // huffman: max code length (bits); range: total bits (log2 M)
    payload_bytes: usize,
    total_bytes: usize,
    h0_bytes: f64,
    arena_bytes: usize,
    arena_build_ms: f64,
    table_build_ms: f64,
    decode_ms: f64,
    raw_len: usize,
    total_roots: usize,
    single_block_us: f64,
};

fn printLine(r: Row) void {
    const startup_ms = r.arena_build_ms + r.table_build_ms;
    const mbps = (@as(f64, @floatFromInt(r.raw_len)) / (1024.0 * 1024.0)) / (r.decode_ms / 1000.0);
    const ns_per_root = (r.decode_ms * 1e6) / @as(f64, @floatFromInt(r.total_roots));
    const pct_over_h0 = (@as(f64, @floatFromInt(r.payload_bytes)) - r.h0_bytes) / r.h0_bytes * 100.0;
    std.debug.print(
        "{s}\t{s}\tn_sym={d}\talphabet={d}\tcode_param={d}\tpayload_B={d}\ttotal_B={d}\th0_B={d:.0}\tover_h0_pct={d:.2}\tarena_B={d}\tstartup_ms={d:.3}\tdecode_ms={d:.3}\tMBps={d:.1}\tns_per_root={d:.2}\tsingle_block_us={d:.3}\troots={d}\traw_len={d}\n",
        .{ r.dump, r.coder, r.n_sym, r.alphabet_size, r.code_param, r.payload_bytes, r.total_bytes, r.h0_bytes, pct_over_h0, r.arena_bytes, startup_ms, r.decode_ms, mbps, ns_per_root, r.single_block_us, r.total_roots, r.raw_len },
    );
}

fn verifySingleBlocksHuffman(alloc: std.mem.Allocator, huf: *const rs.Huffman, exp: *const rs.Expansion, frame: rs.Frame, dump: rs.Dump, raw: []const u8) !void {
    const out = try alloc.alloc(u8, dump.block_bytes + rs.overscan_pad);
    defer alloc.free(out);
    const picks = [_]usize{ 0, dump.block_count / 2, dump.block_count - 1 };
    for (picks) |b| {
        const raw_start = b * dump.block_bytes;
        const raw_end = @min(raw.len, raw_start + dump.block_bytes);
        const n = try rs.decodeHuffman(true, true, true, huf, exp, frame, b, out);
        if (n != raw_end - raw_start or !std.mem.eql(u8, out[0..n], raw[raw_start..raw_end])) return error.SingleBlockMismatch;
    }
}

fn verifySingleBlocksRange(alloc: std.mem.Allocator, model: *const rs.RangeModel, exp: *const rs.Expansion, frame: rs.Frame, dump: rs.Dump, raw: []const u8) !void {
    const out = try alloc.alloc(u8, dump.block_bytes + rs.overscan_pad);
    defer alloc.free(out);
    const picks = [_]usize{ 0, dump.block_count / 2, dump.block_count - 1 };
    for (picks) |b| {
        const raw_start = b * dump.block_bytes;
        const raw_end = @min(raw.len, raw_start + dump.block_bytes);
        const n = try rs.decodeRange(true, true, true, model, exp, frame, b, out);
        if (n != raw_end - raw_start or !std.mem.eql(u8, out[0..n], raw[raw_start..raw_end])) return error.SingleBlockMismatch;
    }
}

/// Before/after comparisons for LANE_S.md: naive bit-trie vs table-driven
/// Huffman decode, and memcpy vs overshoot copy. Bounded to one block
/// repeated many times so the (much slower) naive path stays cheap to run.
fn benchHuffmanOpts(io: std.Io, huf: *const rs.Huffman, exp: *const rs.Expansion, frame: rs.Frame, dump: rs.Dump) !void {
    const alloc = std.heap.page_allocator;
    const b: usize = dump.block_count / 2;
    const out = try alloc.alloc(u8, dump.block_bytes + rs.overscan_pad);
    defer alloc.free(out);
    const reps: u32 = 400;
    const roots = frame.dir[b].root_count;

    var t1 = Timer.start(io);
    for (0..reps) |_| _ = try rs.decodeHuffman(false, true, false, huf, exp, frame, b, out); // naive tree, fast copy
    const naive_ns = t1.ns();

    t1 = Timer.start(io);
    for (0..reps) |_| _ = try rs.decodeHuffman(false, true, true, huf, exp, frame, b, out); // table, fast copy
    const table_ns = t1.ns();

    t1 = Timer.start(io);
    for (0..reps) |_| _ = try rs.decodeHuffman(false, false, true, huf, exp, frame, b, out); // table, memcpy
    const memcpy_ns = t1.ns();

    const per = struct {
        fn ns(total: u64, r: u32, n: u32) f64 {
            return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(r)) / @as(f64, @floatFromInt(n));
        }
    };
    std.debug.print("#opt huffman naive_tree_ns_per_root={d:.2} table_ns_per_root={d:.2} speedup={d:.2}x\n", .{
        per.ns(naive_ns, reps, roots), per.ns(table_ns, reps, roots), per.ns(naive_ns, reps, roots) / per.ns(table_ns, reps, roots),
    });
    std.debug.print("#opt huffman memcpy_copy_ns_per_root={d:.2} overshoot_copy_ns_per_root={d:.2} speedup={d:.2}x\n", .{
        per.ns(memcpy_ns, reps, roots), per.ns(table_ns, reps, roots), per.ns(memcpy_ns, reps, roots) / per.ns(table_ns, reps, roots),
    });
}

fn benchRangeOpts(io: std.Io, model: *const rs.RangeModel, exp: *const rs.Expansion, frame: rs.Frame, dump: rs.Dump) !void {
    const alloc = std.heap.page_allocator;
    const b: usize = dump.block_count / 2;
    const out = try alloc.alloc(u8, dump.block_bytes + rs.overscan_pad);
    defer alloc.free(out);
    const reps: u32 = 400;
    const roots = frame.dir[b].root_count;

    var t1 = Timer.start(io);
    for (0..reps) |_| _ = try rs.decodeRange(false, true, false, model, exp, frame, b, out); // binary search, fast copy
    const bs_ns = t1.ns();

    t1 = Timer.start(io);
    for (0..reps) |_| _ = try rs.decodeRange(false, true, true, model, exp, frame, b, out); // slot table, fast copy
    const slot_ns = t1.ns();

    const per = struct {
        fn ns(total: u64, r: u32, n: u32) f64 {
            return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(r)) / @as(f64, @floatFromInt(n));
        }
    };
    std.debug.print("#opt range binarysearch_ns_per_root={d:.2} slottable_ns_per_root={d:.2} speedup={d:.2}x\n", .{
        per.ns(bs_ns, reps, roots), per.ns(slot_ns, reps, roots), per.ns(bs_ns, reps, roots) / per.ns(slot_ns, reps, roots),
    });
}
