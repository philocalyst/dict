//! rootlab_ctx: Lane X driver. Reads a B4SD dump, builds the shared symbol
//! table / global counts / usage counts, runs one (or all) soft-context
//! variant(s) from rootctx.zig with a real rc.zig encode + real decode
//! verifying every block's root sequence, and prints TSV line(s).
//!
//! usage: rootlab_ctx DUMP VARIANT
//!   VARIANT one of: x0 x1i x1ii x1iii x2 x3 x4 all
//!
//! TSV columns (no header):
//!   dump  variant  payload_bytes  pct_vs_x0  table_bytes  total_bytes
//!   ns_per_root  roots_total  blocks  raw_len
//!
//! pct_vs_x0 = (x0_total - this_total) / x0_total * 100 (positive = savings
//! versus the static order-0 reference); x0's own line naturally reads 0.

const std = @import("std");
const ctx = @import("rootctx.zig");

fn usage() void {
    std.debug.print("usage: rootlab_ctx DUMP VARIANT   (VARIANT: x0 x1i x1ii x1iii x2 x3 x4 all)\n", .{});
}

const all_variants = [_]ctx.Variant{ .x0, .x1i, .x1ii, .x1iii, .x2, .x3, .x4 };

fn variantName(v: ctx.Variant) []const u8 {
    return @tagName(v);
}

fn printLine(writer: *std.Io.Writer, dump_name: []const u8, name: []const u8, rep: ctx.Report, x0_total: usize) !void {
    const total_bytes = rep.payload_bytes + rep.table_bytes;
    const pct: f64 = if (x0_total == 0) 0.0 else (@as(f64, @floatFromInt(x0_total)) - @as(f64, @floatFromInt(total_bytes))) / @as(f64, @floatFromInt(x0_total)) * 100.0;
    const ns_per_root: f64 = if (rep.roots_total == 0) 0.0 else @as(f64, @floatFromInt(rep.decode_ns)) / @as(f64, @floatFromInt(rep.roots_total));
    try writer.print("{s}\t{s}\t{d}\t{d:.3}\t{d}\t{d}\t{d:.1}\t{d}\t{d}\n", .{
        dump_name,
        name,
        rep.payload_bytes,
        pct,
        rep.table_bytes,
        total_bytes,
        ns_per_root,
        rep.roots_total,
        rep.blocks,
    });
}

fn printFail(writer: *std.Io.Writer, dump_name: []const u8, name: []const u8, err: anyerror) !void {
    try writer.print("{s}\t{s}\tFAIL\t{s}\n", .{ dump_name, name, @errorName(err) });
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
    const variant_arg = it.next() orelse {
        usage();
        return error.Usage;
    };

    const run_all = std.mem.eql(u8, variant_arg, "all");
    const single_variant: ?ctx.Variant = if (run_all) null else ctx.Variant.parse(variant_arg) orelse {
        usage();
        return error.Usage;
    };

    var dump = try ctx.readDump(alloc, io, path);
    defer dump.deinit();
    const info = try ctx.buildSymInfo(alloc, &dump);
    defer alloc.free(info);
    const g = try ctx.computeG(alloc, &dump);
    defer alloc.free(g);
    const u = try ctx.computeUsage(alloc, &dump, g);
    defer alloc.free(u);

    const dump_name = std.fs.path.basename(path);

    var output_buffer: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writerStreaming(io, &output_buffer);
    const writer = &out_writer.interface;

    // x0 always computed first: every other variant's pct_vs_x0 needs it,
    // and if VARIANT=x0 this IS the requested line.
    const x0_rep = try ctx.run(alloc, io, &dump, info, g, u, .x0);
    const x0_total = x0_rep.payload_bytes + x0_rep.table_bytes;

    if (!run_all) {
        const v = single_variant.?;
        if (v == .x0) {
            try printLine(writer, dump_name, "x0", x0_rep, x0_total);
        } else {
            const rep = ctx.run(alloc, io, &dump, info, g, u, v) catch |err| {
                try printFail(writer, dump_name, variantName(v), err);
                try writer.flush();
                return;
            };
            try printLine(writer, dump_name, variantName(v), rep, x0_total);
        }
        try writer.flush();
        return;
    }

    try printLine(writer, dump_name, "x0", x0_rep, x0_total);
    for (all_variants[1..]) |v| {
        const rep = ctx.run(alloc, io, &dump, info, g, u, v) catch |err| {
            try printFail(writer, dump_name, variantName(v), err);
            continue;
        };
        try printLine(writer, dump_name, variantName(v), rep, x0_total);
    }
    try writer.flush();
}
