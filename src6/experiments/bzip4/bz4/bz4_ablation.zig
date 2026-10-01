//! bz4_ablation: isolates the STARTUP SPEED change bz4_root.zig made vs.
//! Lane S's original rootstatic.zig (ascending-id arena layout) -- holding
//! the grammar and Huffman table fixed, build BOTH an ascending-id arena
//! (the old layout, reimplemented here verbatim for comparison since
//! bz4_root.zig no longer keeps that code path) and bz4_root.zig's real
//! descending-g arena, then decode the SAME encoded bitstream through each
//! and report build time and decode throughput for both. This isolates the
//! arena-layout effect from the (separately reported, in LANE_V.md's main
//! table) effect of MDL pruning reducing rule count.
//!
//! usage: bz4_ablation FILE BLOCK_BYTES
//!
//! Pure Zig 0.16, std only.

const std = @import("std");
const bg = @import("bz4_grammar.zig");
const br = @import("bz4_root.zig");

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

/// Lane S's original layout: ascending id (construction order), every
/// symbol 0..alphabet_size-1 present (not just alphabet members).
fn buildExpansionAscending(alloc: std.mem.Allocator, rules: []const br.Rule, alphabet_size: u32) !br.Expansion {
    const k = alphabet_size;
    const off = try alloc.alloc(u64, k);
    const len = try alloc.alloc(u32, k);
    for (0..256) |i| {
        off[i] = i;
        len[i] = 1;
    }
    var total: u64 = 256;
    for (rules, 0..) |r, i| {
        const l = len[r.a] + len[r.b];
        len[256 + i] = l;
        total += l;
    }
    const arena = try alloc.alloc(u8, total + br.overscan_pad);
    for (0..256) |i| arena[i] = @intCast(i);
    var write: u64 = 256;
    for (rules, 0..) |r, i| {
        const id = 256 + i;
        off[id] = write;
        const la = len[r.a];
        const lb = len[r.b];
        @memcpy(arena[write .. write + la], arena[off[r.a] .. off[r.a] + la]);
        write += la;
        @memcpy(arena[write .. write + lb], arena[off[r.b] .. off[r.b] + lb]);
        write += lb;
    }
    @memset(arena[write .. write + br.overscan_pad], 0);
    return .{ .off = off, .len = len, .arena = arena, .arena_used = write };
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
    const path = it.next() orelse return error.Usage;
    const block_bytes = try std.fmt.parseUnsigned(usize, it.next() orelse return error.Usage, 10);

    const input = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 30));
    defer alloc.free(input);

    // Unpruned a3 grammar -- deliberately NOT MDL-pruned, so the rule
    // count here is comparable to what Lane S measured (a full min_freq=2
    // grammar), isolating the arena-layout effect from pruning's own
    // (separately reported) startup benefit.
    var gm = try bg.build(alloc, input, block_bytes, .{ .priority = .saving, .fast_count = true, .min_freq = 2, .alpha_percent = 50 });
    defer gm.deinit(alloc);

    const rcs = try bg.rootCounts(alloc, &gm);
    defer alloc.free(rcs.g);
    const alphabet_size: u32 = @intCast(gm.numSymbols());

    var alphabet = try br.buildAlphabet(alloc, rcs.g);
    defer alphabet.deinit(alloc);

    const rules = try alloc.alloc(br.Rule, gm.rules.items.len);
    defer alloc.free(rules);
    for (gm.rules.items, 0..) |r, i| rules[i] = .{ .a = r.a, .b = r.b };

    var huf = try br.buildHuffman(alloc, alphabet, alphabet_size);
    defer huf.deinit(alloc);
    var enc = try br.buildHuffmanEncodeTable(alloc, huf, alphabet);
    defer enc.deinit(alloc);

    // Encode the whole root stream (all blocks concatenated, byte-padded
    // per block like the real frame does) once; both arena variants decode
    // this SAME bitstream, so only the arena layout differs.
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    var block_starts: std.ArrayList(usize) = .empty;
    defer block_starts.deinit(alloc);
    var seq_start: usize = 0;
    for (gm.block_end) |seq_end| {
        try block_starts.append(alloc, payload.items.len);
        var bw = br.BitWriter{ .out = &payload, .alloc = alloc };
        for (gm.seq[seq_start..seq_end]) |s| try bw.putBits(enc.code[s], @intCast(enc.length[s]));
        try bw.flushBlock();
        seq_start = seq_end;
    }
    try block_starts.append(alloc, payload.items.len); // sentinel end

    const decodeAllWith = struct {
        fn run(exp: *const br.Expansion, huf_: *const br.Huffman, payload_: []const u8, starts: []const usize, gm_: *const bg.Grammar, raw: []const u8, out: []u8) void {
            var b: usize = 0;
            var raw_start: usize = 0;
            while (b < starts.len - 1) : (b += 1) {
                const raw_end = @min(raw.len, raw_start + gm_.block_bytes);
                const blen = raw_end - raw_start;
                var brd = br.BitReader.init(payload_[starts[b]..starts[b + 1]]);
                var pos: usize = 0;
                while (pos < blen) {
                    const sym = huf_.decodeOneTable(&brd);
                    const l = exp.len[sym];
                    const off = exp.off[sym];
                    @memcpy(out[raw_start + pos ..][0..l], exp.arena[off..][0..l]);
                    pos += l;
                }
                raw_start = raw_end;
            }
        }
    }.run;

    const out = try alloc.alloc(u8, input.len);
    defer alloc.free(out);
    const reps = 7;

    // ---- ascending-id (Lane S's original layout) ----
    {
        const t0 = nowNs(io);
        var exp = try buildExpansionAscending(alloc, rules, alphabet_size);
        const build_ms = @as(f64, @floatFromInt(nowNs(io) - t0)) / 1e6;
        defer exp.deinit(alloc);

        var samples: [reps]f64 = undefined;
        for (&samples) |*s| {
            const t1 = nowNs(io);
            decodeAllWith(&exp, &huf, payload.items, block_starts.items, &gm, input, out);
            s.* = @as(f64, @floatFromInt(nowNs(io) - t1)) / 1e6;
        }
        if (!std.mem.eql(u8, out, input)) return error.Mismatch;
        const dm = median(&samples);
        const mbps = (@as(f64, @floatFromInt(input.len)) / 1e6) / (dm / 1000.0);
        std.debug.print("ascending_id\tarena_build_ms={d:.3}\tarena_bytes={d}\tdecode_median_ms={d:.3}\tMBps={d:.1}\n", .{ build_ms, exp.arena.len, dm, mbps });
    }

    // ---- descending-g (this lane's change) ----
    {
        const t0 = nowNs(io);
        var exp = try br.buildExpansion(alloc, rules, alphabet, alphabet_size);
        const build_ms = @as(f64, @floatFromInt(nowNs(io) - t0)) / 1e6;
        defer exp.deinit(alloc);

        var samples: [reps]f64 = undefined;
        for (&samples) |*s| {
            const t1 = nowNs(io);
            decodeAllWith(&exp, &huf, payload.items, block_starts.items, &gm, input, out);
            s.* = @as(f64, @floatFromInt(nowNs(io) - t1)) / 1e6;
        }
        if (!std.mem.eql(u8, out, input)) return error.Mismatch;
        const dm = median(&samples);
        const mbps = (@as(f64, @floatFromInt(input.len)) / 1e6) / (dm / 1000.0);
        std.debug.print("descending_g\tarena_build_ms={d:.3}\tarena_bytes={d}\tdecode_median_ms={d:.3}\tMBps={d:.1}\n", .{ build_ms, exp.arena.len, dm, mbps });
    }
}
