//! w3b_rcbench: isolated microbenchmark, rc.zig (Lane W's 64-bit carryless
//! range coder, imported read-only for comparison) vs w3b_rc.zig (this
//! lane's LZMA-style 32-bit coder) — same adaptive-bit workload, same
//! probabilities, nothing else in the loop. Answers "how much of
//! FastTreeCM's speedup is the range coder, independent of the model."
//!
//! usage: w3b_rcbench N [REPEATS]

const std = @import("std");
const rc_old = @import("rc.zig");
const rc_new = @import("w3b_rc.zig");

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn median(vals: []f64) f64 {
    std.mem.sort(f64, vals, {}, std.sort.asc(f64));
    const n = vals.len;
    if (n % 2 == 1) return vals[n / 2];
    return (vals[n / 2 - 1] + vals[n / 2]) / 2.0;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const n = try std.fmt.parseUnsigned(usize, it.next() orelse "5000000", 10);
    const repeats = try std.fmt.parseUnsigned(usize, it.next() orelse "7", 10);

    // A realistic mixed-skew bit stream: alternates a few probability
    // regimes so branch prediction can't fully hide the coder's own cost,
    // similar to a real model's spread of contexts.
    const bits = try alloc.alloc(u1, n);
    defer alloc.free(bits);
    const probs = try alloc.alloc(u16, n);
    defer alloc.free(probs);
    var prng = std.Random.DefaultPrng.init(0xB5B5);
    const rnd = prng.random();
    for (bits, probs) |*b, *p| {
        const p0: u16 = 200 + rnd.uintLessThan(u16, 3800); // 1/4096 units, avoid extremes
        p.* = p0;
        const r = rnd.uintLessThan(u16, 4096);
        b.* = @intFromBool(r >= p0);
    }

    var old_ms = try alloc.alloc(f64, repeats);
    defer alloc.free(old_ms);
    var new_ms = try alloc.alloc(f64, repeats);
    defer alloc.free(new_ms);

    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        {
            var enc = rc_old.Encoder.init(alloc);
            defer enc.deinit();
            for (bits, probs) |b, p| try enc.encodeBitProb(p, b);
            const bytes = try enc.finish();
            var dec = rc_old.Decoder.init(bytes);
            const t1 = nowNs(io);
            for (bits, probs) |b, p| std.debug.assert(dec.decodeBitProb(p) == b);
            const t2 = nowNs(io);
            old_ms[rep] = @as(f64, @floatFromInt(t2 - t1)) / 1e6; // decode only
        }
        {
            var enc = rc_new.Encoder.init(alloc);
            defer enc.deinit();
            for (bits, probs) |b, p| try enc.encodeBitProb(p, b);
            const bytes = try alloc.dupe(u8, try enc.finish());
            defer alloc.free(bytes);
            var dec = rc_new.Decoder.init(bytes);
            const t0 = nowNs(io);
            for (bits, probs) |b, p| std.debug.assert(dec.decodeBitProb(p) == b);
            const t1 = nowNs(io);
            new_ms[rep] = @as(f64, @floatFromInt(t1 - t0)) / 1e6;
        }
    }

    const old_med = median(old_ms);
    const new_med = median(new_ms);
    std.debug.print("rc.zig (64-bit carryless):  decode {d:.2} ms  ({d:.2} ns/call)\n", .{ old_med, old_med * 1e6 / @as(f64, @floatFromInt(n)) });
    std.debug.print("w3b_rc.zig (LZMA-style 32-bit): decode {d:.2} ms  ({d:.2} ns/call)\n", .{ new_med, new_med * 1e6 / @as(f64, @floatFromInt(n)) });
    std.debug.print("ratio (old/new): {d:.2}x\n", .{old_med / new_med});
}
