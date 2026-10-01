//! Lane F driver: reads one B4SD v1/v2 dump, runs the Q1-Q4 oracle-cost
//! studies (f_bucket/f_bigram/f_direct/f_automaton), prints tagged lines to
//! stdout. This is the tool that produced every table in LANE_F.md; see
//! that file for the writeup and PLAN.md's "Round 3" for the brief.
//!
//! usage: f_lab DUMP_PATH [q1|q2|q3|q4|all]

const std = @import("std");
const fc = @import("f_common.zig");
const fbk = @import("f_bucket.zig");
const fbg = @import("f_bigram.zig");
const fdi = @import("f_direct.zig");
const fau = @import("f_automaton.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const path = it.next() orelse {
        std.debug.print("usage: f_lab DUMP_PATH [q1|q2|q3|q4|all]\n", .{});
        return error.Usage;
    };
    const which = it.next() orelse "all";
    const do_q1 = std.mem.eql(u8, which, "all") or std.mem.eql(u8, which, "q1");
    const do_q2 = std.mem.eql(u8, which, "all") or std.mem.eql(u8, which, "q2");
    const do_q3 = std.mem.eql(u8, which, "all") or std.mem.eql(u8, which, "q3");
    const do_q4 = std.mem.eql(u8, which, "all") or std.mem.eql(u8, which, "q4");

    const name = std.fs.path.stem(path);

    var dump = try fc.readDump(alloc, io, path);
    defer dump.deinit();
    var seqs = try fc.buildSequences(alloc, &dump);
    defer seqs.deinit();
    const g = try fc.computeG(alloc, dump.k, &seqs);
    defer alloc.free(g);
    const h0 = fc.exactH0Bits(g, seqs.total_tokens);

    std.debug.print("META {s} k={d} n_seq={d} tokens={d} h0_bytes={d:.1} h0_bpt={d:.4}\n", .{ name, dump.k, seqs.seqs.len, seqs.total_tokens, h0 / 8.0, h0 / fc.f(seqs.total_tokens) });

    if (do_q1) {
        const rep = try fbk.run(alloc, &seqs, dump.k, g);
        defer alloc.free(rep.rows);
        for (rep.rows) |r| {
            std.debug.print("Q1 {s} method={s} b={d} L={d} K={d} bytes={d:.1} bpt={d:.4}\n", .{ name, r.method, r.b, r.L, r.num_buckets, r.total_bytes, r.bits_per_token });
        }
    }

    if (do_q2) {
        const rep = try fbg.run(alloc, &seqs, dump.k, g);
        defer alloc.free(rep.rows);
        defer alloc.free(rep.best);
        for (rep.rows) |r| {
            std.debug.print("Q2 {s} C={d} L={d} oh={d} K={d} bytes={d:.1} bpt={d:.4}\n", .{ name, r.C, r.L, r.bucket_budget, r.num_buckets, r.total_bytes, r.bits_per_token });
        }
        for (rep.best) |r| {
            std.debug.print("Q2BEST {s} C={d} L={d} K={d} bytes={d:.1} bpt={d:.4}\n", .{ name, r.C, r.L, r.num_buckets, r.total_bytes, r.bits_per_token });
        }
    }

    if (do_q3) {
        const rep = try fdi.run(alloc, &seqs, dump.k, g);
        defer alloc.free(rep.rows);
        for (rep.rows) |r| {
            std.debug.print("Q3 {s} K={d} R={d} L={d} numB={d} bytes={d:.1} bpt={d:.4}\n", .{ name, r.K, r.R, r.L, r.num_buckets, r.total_bytes, r.bits_per_token });
        }
    }

    if (do_q4) {
        var best = try fbg.findBest(alloc, &seqs, dump.k, g);
        defer best.deinit(alloc);
        std.debug.print("Q4BASE {s} C={d} L={d} K={d} total_bytes={d:.1} bpt={d:.4}\n", .{ name, best.C, best.L, best.num_buckets, best.total_bits / 8.0, best.total_bits / fc.f(seqs.total_tokens) });

        const o2 = try fau.tryOrder2Splits(alloc, &seqs, &best);
        defer alloc.free(o2);
        var o2_net_accepted: f64 = 0;
        var o2_n_accepted: usize = 0;
        for (o2) |r| {
            std.debug.print("Q4A {s} row={d} n_ctx2={d} gain={d:.1} added={d:.1} net={d:.1} accept={}\n", .{ name, r.row, r.n_ctx2_groups, r.gain_bits, r.added_table_bits, r.net_bits, r.accepted });
            if (r.accepted) {
                o2_net_accepted += r.net_bits;
                o2_n_accepted += 1;
            }
        }
        std.debug.print("Q4ASUM {s} n_accepted={d} total_net_bits={d:.1}\n", .{ name, o2_n_accepted, o2_net_accepted });

        const st = try fau.trySickySplits(alloc, &seqs, &best, g, 10);
        defer fau.freeStickySplits(alloc, st);
        var st_net_accepted: f64 = 0;
        var st_n_accepted: usize = 0;
        for (st) |s| {
            std.debug.print("Q4B {s} row={d} pop={d} nself={d} gain={d:.1} added={d:.1} net={d:.1} accept={}\n", .{ name, s.row, s.population, s.n_self_buckets, s.gain_bits, s.added_bits, s.net_bits, s.accepted });
            if (s.accepted) {
                st_net_accepted += s.net_bits;
                st_n_accepted += 1;
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(alloc);
                for (s.example_a[0..s.n_example_a]) |tok| {
                    buf.clearRetainingCapacity();
                    try fc.expandTruncated(alloc, &dump, tok, &buf, 24);
                    const esc = try fc.escapeForPrint(alloc, buf.items);
                    defer alloc.free(esc);
                    std.debug.print("Q4B_EX {s} row={d} side=a tok=|{s}|\n", .{ name, s.row, esc });
                }
                for (s.example_b[0..s.n_example_b]) |tok| {
                    buf.clearRetainingCapacity();
                    try fc.expandTruncated(alloc, &dump, tok, &buf, 24);
                    const esc = try fc.escapeForPrint(alloc, buf.items);
                    defer alloc.free(esc);
                    std.debug.print("Q4B_EX {s} row={d} side=b tok=|{s}|\n", .{ name, s.row, esc });
                }
            }
        }
        std.debug.print("Q4BSUM {s} n_accepted={d} total_net_bits={d:.1}\n", .{ name, st_n_accepted, st_net_accepted });

        const total_headroom_bits = o2_net_accepted + st_net_accepted;
        std.debug.print("Q4HEADROOM {s} bits={d:.1} bytes={d:.1} pct_of_base={d:.4}\n", .{ name, total_headroom_bits, total_headroom_bits / 8.0, 100.0 * total_headroom_bits / best.total_bits });
    }
}
