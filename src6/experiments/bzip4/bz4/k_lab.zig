//! k_lab: Lane K driver. Reads a B4SD dump, runs the induced class-transition
//! model (k_classes.zig) with a given (C, maps, inherit, g_min), and prints
//! one TSV line. See LANE_K.md for the write-up and PLAN.md's Round 3 item 3
//! for what this measures.
//!
//! usage: k_lab DUMP C MAPS(1|2) INHERIT(0|1) GMIN [SWEEPS] [CAP]
//!        k_lab DUMP C MAPS INHERIT GMIN listclasses   (prints class samples instead)
//!
//! TSV: dump C maps inherit g_min tokens payload_x0 payload_class table_bytes
//!      override_bytes net_total pct_vs_x0 learn_ms decode_ns_per_token
//!      n_overrides_b n_overrides_a n_refined

const std = @import("std");
const kc = @import("k_common.zig");
const kk = @import("k_classes.zig");

fn usage() void {
    std.debug.print("usage: k_lab DUMP C MAPS(1|2) INHERIT(0|1) GMIN(int|inf) [SWEEPS] [CAP]\n", .{});
    std.debug.print("       k_lab DUMP C MAPS INHERIT GMIN listclasses\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const path = it.next() orelse {
        usage();
        return error.Usage;
    };
    const c_arg = it.next() orelse {
        usage();
        return error.Usage;
    };
    const maps_arg = it.next() orelse {
        usage();
        return error.Usage;
    };
    const inherit_arg = it.next() orelse {
        usage();
        return error.Usage;
    };
    const gmin_arg = it.next() orelse {
        usage();
        return error.Usage;
    };
    const opt1 = it.next();
    const opt2 = it.next();
    const opt3 = it.next();
    const opt4 = it.next();

    const C: u32 = try std.fmt.parseInt(u32, c_arg, 10);
    const maps: u32 = try std.fmt.parseInt(u32, maps_arg, 10);
    const inherit: u32 = try std.fmt.parseInt(u32, inherit_arg, 10);
    const g_min: u64 = if (std.mem.eql(u8, gmin_arg, "inf")) std.math.maxInt(u64) else try std.fmt.parseInt(u64, gmin_arg, 10);

    var list_classes = false;
    var order2 = false;
    var sweeps: u32 = 8;
    var cap: usize = 6000;
    if (opt1) |a| {
        if (std.mem.eql(u8, a, "listclasses")) {
            list_classes = true;
        } else if (std.mem.eql(u8, a, "order2")) {
            order2 = true;
        } else {
            sweeps = try std.fmt.parseInt(u32, a, 10);
        }
    }
    if (opt2) |a| {
        if (std.mem.eql(u8, a, "listclasses")) {
            list_classes = true;
        } else if (std.mem.eql(u8, a, "order2")) {
            order2 = true;
        } else {
            cap = try std.fmt.parseInt(usize, a, 10);
        }
    }
    for ([_]?[]const u8{ opt3, opt4 }) |o| {
        if (o) |a| {
            if (std.mem.eql(u8, a, "listclasses")) list_classes = true;
            if (std.mem.eql(u8, a, "order2")) order2 = true;
        }
    }

    const params: kk.Params = .{
        .C = C,
        .two_maps = maps == 2,
        .inherit = inherit == 1,
        .g_min = g_min,
        .sweeps = sweeps,
        .candidate_cap = cap,
    };

    var dump = try kc.readDump(alloc, io, path);
    defer dump.deinit();
    const order = try kc.topoOrder(alloc, &dump);
    defer alloc.free(order);
    const info = try kc.buildSymInfo(alloc, &dump, order);
    defer alloc.free(info);
    const g = try kc.computeG(alloc, &dump);
    defer alloc.free(g);

    const dump_name = std.fs.path.basename(path);

    var output_buffer: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writerStreaming(io, &output_buffer);
    const writer = &out_writer.interface;

    if (list_classes) {
        var built = try kk.buildModel(alloc, io, &dump, order, info, g, params);
        defer built.model.deinit(alloc);
        const samples = try kk.biggestClasses(alloc, &dump, built.model.resolved_b, g, 12, C);
        defer alloc.free(samples);
        for (samples) |s| {
            try writer.print("## {s} class {d} (total g={d}, {d} member symbols)\n\n", .{ dump_name, s.class_id, s.total_g, s.n_members });
            for (s.top[0..s.n_top]) |m| {
                var bytes: std.ArrayList(u8) = .empty;
                defer bytes.deinit(alloc);
                try kc.expandTruncated(alloc, &dump, m.sym, &bytes, 40);
                const esc = try kc.escapeForPrint(alloc, bytes.items);
                defer alloc.free(esc);
                try writer.print("- sym {d} g={d}: `{s}`\n", .{ m.sym, m.g, esc });
            }
            try writer.print("\n", .{});
        }
        try writer.flush();
        return;
    }

    const gmin_str = if (g_min == std.math.maxInt(u64)) "inf" else blk: {
        var buf: [32]u8 = undefined;
        break :blk try std.fmt.bufPrint(&buf, "{d}", .{g_min});
    };

    const rep = (if (order2) kk.runOrder2(alloc, io, &dump, order, info, g, params) else kk.run(alloc, io, &dump, order, info, g, params)) catch |err| {
        try writer.print("{s}\t{d}\t{d}\t{d}\t{s}\tFAIL\t{s}\n", .{ dump_name, C, maps, inherit, gmin_str, @errorName(err) });
        try writer.flush();
        return;
    };

    try writer.print("{s}\t{d}\t{d}\t{d}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d:.3}\t{d:.2}\t{d:.1}\t{d}\t{d}\t{d}\n", .{
        dump_name,
        C,
        maps,
        inherit,
        gmin_str,
        rep.tokens,
        rep.payload_x0,
        rep.payload_class,
        rep.table_bytes,
        rep.override_bytes,
        rep.net_total,
        rep.pct_vs_x0,
        rep.learn_ms,
        rep.decode_ns_per_token,
        rep.num_overrides_b,
        rep.num_overrides_a,
        rep.num_refined,
    });
    try writer.flush();
}
