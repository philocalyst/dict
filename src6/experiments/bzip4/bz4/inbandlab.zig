//! Lane I CLI: `inbandlab FILE [MIN_FREQ] [VARIANT]`
//! Prints one TSV line: file, variant, rules, roots, total_bytes,
//! bits_per_raw_byte, encode_ms, decode_ms, decode_MBps.
//! Verifies byte-exact roundtrip against the raw file before printing.

const std = @import("std");
const inband = @import("inband.zig");

fn parseVariant(s: []const u8) inband.Options {
    var o = inband.Options{};
    if (std.mem.eql(u8, s, "all")) return .{ .exact_flag = true, .first_byte = true, .cache = true };
    if (std.mem.indexOf(u8, s, "eflag") != null) o.exact_flag = true;
    if (std.mem.indexOf(u8, s, "fb") != null) o.first_byte = true;
    if (std.mem.indexOf(u8, s, "cache") != null) o.cache = true;
    return o;
}

fn lessThanF64(_: void, a: f64, b: f64) bool {
    return a < b;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const path = it.next() orelse return error.Usage;
    const min_freq_str = it.next();
    const variant_str = it.next() orelse "base";
    const min_freq: u32 = if (min_freq_str) |s| try std.fmt.parseUnsigned(u32, s, 10) else 2;
    const opts = parseVariant(variant_str);

    const raw = try std.Io.Dir.cwd().readFileAlloc(init.io, path, alloc, .limited(1 << 30));

    const t0 = std.Io.Clock.awake.now(init.io).nanoseconds;
    const enc_result = try inband.encode(alloc, raw, min_freq, opts);
    const t1 = std.Io.Clock.awake.now(init.io).nanoseconds;
    const encode_ms = @as(f64, @floatFromInt(t1 - t0)) / 1e6;

    var times: [5]f64 = undefined;
    var decoded: []u8 = &[_]u8{};
    for (0..5) |i| {
        const d0 = std.Io.Clock.awake.now(init.io).nanoseconds;
        const dec_out = try inband.decode(alloc, enc_result.bytes);
        const d1 = std.Io.Clock.awake.now(init.io).nanoseconds;
        times[i] = @as(f64, @floatFromInt(d1 - d0)) / 1e6;
        if (i < 4) {
            alloc.free(dec_out);
        } else {
            decoded = dec_out;
        }
    }
    std.mem.sort(f64, &times, {}, lessThanF64);
    const decode_ms = times[2];

    if (!std.mem.eql(u8, decoded, raw)) {
        std.debug.print("MISMATCH file={s} variant={s} min_freq={d}\n", .{ path, variant_str, min_freq });
        return error.RoundtripMismatch;
    }

    const total_bytes = enc_result.bytes.len;
    const bits_per_raw_byte = @as(f64, @floatFromInt(total_bytes)) * 8.0 / @as(f64, @floatFromInt(raw.len));
    const decode_MBps = (@as(f64, @floatFromInt(raw.len)) / (1024.0 * 1024.0)) / (decode_ms / 1000.0);

    std.debug.print("{s}\t{s}\t{d}\t{d}\t{d}\t{d:.4}\t{d:.3}\t{d:.3}\t{d:.2}\n", .{
        path,
        variant_str,
        enc_result.rules,
        enc_result.roots,
        total_bytes,
        bits_per_raw_byte,
        encode_ms,
        decode_ms,
        decode_MBps,
    });
}
