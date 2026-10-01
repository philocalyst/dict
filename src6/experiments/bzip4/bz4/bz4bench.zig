//! bz4bench: Lane V measurement harness.
//!
//! usage: bz4bench FILE BLOCK_BYTES [REPEATS]
//!
//! Encodes FILE once (encode_ms), verifies one full untimed decode
//! roundtrip byte-exact against FILE before trusting any timing (rules of
//! evidence), then times Frame.open() (startup_ms) once and REPEATS
//! further full decodeAll() passes (decode_min_ms/decode_median_ms), plus
//! a median single-block latency over 64 random blocks. Looks up the
//! matching bzip3 control row (same file basename + block_bytes) from
//! baselines.tsv for the pct-vs-bzip3 and decode-speed-vs-bzip3 columns.
//!
//! Prints ONE TSV line to stdout:
//!   file block_bytes rules roots model_bytes directory_bytes
//!   payload_bytes total_bytes bzip3_total pct_vs_bzip3 encode_ms
//!   startup_ms decode_min_ms decode_median_ms decode_MBps
//!   bzip3_decode_MBps single_block_us
//!
//! Run SERIALLY (one process at a time) per PLAN.md's rules of evidence;
//! this machine may be shared with other lab agents.
//!
//! Pure Zig 0.16, std only.

const std = @import("std");
const bz4 = @import("bz4.zig");

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn elapsedMs(io: std.Io, t0: i96) f64 {
    const dt = nowNs(io) - t0;
    return @as(f64, @floatFromInt(dt)) / 1e6;
}

fn medianF64(vals: []f64) f64 {
    std.mem.sort(f64, vals, {}, std.sort.asc(f64));
    const n = vals.len;
    if (n % 2 == 1) return vals[n / 2];
    return (vals[n / 2 - 1] + vals[n / 2]) / 2.0;
}

const BaselineRow = struct {
    total_bytes: u64,
    decode_mbps: f64,
};

/// Look up the bzip3 control row for (basename, block_bytes) from
/// baselines.tsv (Lane D's frozen output, see BASELINES.md). Returns null
/// if no exact match (caller reports "n/a" rather than guessing).
fn lookupBaseline(alloc: std.mem.Allocator, io: std.Io, basename: []const u8, block_bytes: usize) !?BaselineRow {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "baselines.tsv", alloc, .limited(1 << 20)) catch return null;
    defer alloc.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    _ = lines.next(); // header
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const f_file = fields.next() orelse continue;
        const f_block = fields.next() orelse continue;
        _ = fields.next(); // block_count
        _ = fields.next(); // payload_bytes
        const f_total = fields.next() orelse continue;
        _ = fields.next(); // encode_ms
        _ = fields.next(); // decode_min_ms
        _ = fields.next(); // decode_median_ms
        const f_mbps = fields.next() orelse continue;

        if (!std.mem.eql(u8, f_file, basename)) continue;
        const block_val = std.fmt.parseUnsigned(usize, f_block, 10) catch continue;
        if (block_val != block_bytes) continue;
        const total = std.fmt.parseUnsigned(u64, f_total, 10) catch continue;
        const mbps = std.fmt.parseFloat(f64, f_mbps) catch continue;
        return .{ .total_bytes = total, .decode_mbps = mbps };
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const path = it.next() orelse return error.Usage;
    const block_bytes = try std.fmt.parseUnsigned(usize, it.next() orelse return error.Usage, 10);
    const repeats: usize = if (it.next()) |r| try std.fmt.parseUnsigned(usize, r, 10) else 5;
    if (repeats == 0) return error.Usage;

    const input = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 30));
    defer alloc.free(input);

    // --- encode (single pass, timed) ---
    const t_enc0 = nowNs(io);
    const result = try bz4.compressStats(alloc, input, .{ .block_bytes = block_bytes });
    const encode_ms = elapsedMs(io, t_enc0);
    defer alloc.free(result.bytes);

    // --- one untimed verified roundtrip before any timing is trusted ---
    {
        var frame = try bz4.open(alloc, result.bytes);
        defer frame.deinit();
        const out = try alloc.alloc(u8, input.len);
        defer alloc.free(out);
        try frame.decodeAll(out);
        if (!std.mem.eql(u8, out, input)) return error.RoundtripMismatch;
    }

    // --- startup: Frame.open(), timed alone ---
    const t_open0 = nowNs(io);
    var frame = try bz4.open(alloc, result.bytes);
    const startup_ms = elapsedMs(io, t_open0);
    defer frame.deinit();

    // --- REPEATS timed full-decode passes (decode work only) ---
    const out = try alloc.alloc(u8, input.len);
    defer alloc.free(out);
    const pass_ms = try alloc.alloc(f64, repeats);
    defer alloc.free(pass_ms);
    for (pass_ms) |*slot| {
        const t0 = nowNs(io);
        try frame.decodeAll(out);
        slot.* = elapsedMs(io, t0);
    }
    std.mem.sort(f64, pass_ms, {}, std.sort.asc(f64));
    const decode_min_ms = pass_ms[0];
    const decode_median_ms = medianF64(pass_ms);
    const decode_mbps = (@as(f64, @floatFromInt(input.len)) / 1.0e6) / (decode_median_ms / 1000.0);

    // --- single-block latency: median over 64 random blocks, each timed
    //     over several repeats for a stable per-call estimate. ---
    var single_block_us: f64 = 0;
    if (frame.block_count > 0) {
        var prng = std.Random.DefaultPrng.init(0xB4_5E6D);
        const rnd = prng.random();
        const samples = 64;
        var lat: [samples]f64 = undefined;
        const block_reps: usize = 200;
        var max_block_len: usize = 0;
        {
            var b: usize = 0;
            while (b < frame.block_count) : (b += 1) {
                const r = frame.blockRawRange(b);
                max_block_len = @max(max_block_len, @as(usize, @intCast(r.end - r.start)));
            }
        }
        const block_out = try alloc.alloc(u8, max_block_len);
        defer alloc.free(block_out);

        for (&lat) |*l| {
            const b = rnd.uintLessThan(usize, frame.block_count);
            const r = frame.blockRawRange(b);
            const blen: usize = @intCast(r.end - r.start);
            const t0 = nowNs(io);
            var rep: usize = 0;
            while (rep < block_reps) : (rep += 1) {
                try frame.decodeBlock(b, block_out[0..blen]);
            }
            const dt_ns = nowNs(io) - t0;
            l.* = @as(f64, @floatFromInt(dt_ns)) / @as(f64, @floatFromInt(block_reps)) / 1000.0; // us/call
        }
        single_block_us = medianF64(&lat);
    }

    const basename = std.fs.path.basename(path);
    const baseline = try lookupBaseline(alloc, io, basename, block_bytes);
    const bzip3_total: i64 = if (baseline) |b| @intCast(b.total_bytes) else -1;
    const bzip3_mbps: f64 = if (baseline) |b| b.decode_mbps else -1;
    const pct_vs_bzip3: f64 = if (baseline) |b|
        (@as(f64, @floatFromInt(result.bytes.len)) - @as(f64, @floatFromInt(b.total_bytes))) / @as(f64, @floatFromInt(b.total_bytes)) * 100.0
    else
        std.math.nan(f64);

    var outbuf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &outbuf);
    try writer.interface.print(
        "{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d:.2}\t{d:.3}\t{d:.3}\t{d:.3}\t{d:.3}\t{d:.2}\t{d:.2}\t{d:.3}\n",
        .{
            basename,
            block_bytes,
            result.stats.rules,
            result.stats.roots,
            result.stats.model_bytes,
            result.stats.directory_bytes,
            result.stats.payload_bytes,
            result.bytes.len,
            bzip3_total,
            pct_vs_bzip3,
            encode_ms,
            startup_ms,
            decode_min_ms,
            decode_median_ms,
            decode_mbps,
            bzip3_mbps,
            single_block_us,
        },
    );
    try writer.interface.flush();
}
