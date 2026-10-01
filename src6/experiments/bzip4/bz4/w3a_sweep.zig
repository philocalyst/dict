//! w3a_sweep: Lane W3a experiment driver. Runs the full (file, block size,
//! determinism gate) matrix through `w3a_bwtlab.run`, auto-selects the
//! smallest REAL total per cell, compares against bzip3 (parsed from
//! `baselines.tsv`) and, at 65536-byte blocks, against the main line's
//! static full-grammar totals (given by the lead, hardcoded below and
//! labelled `given`, not derived here), and runs the idea-2 ablation on the
//! three whole-file cells the lead asked for. Every number that isn't
//! explicitly labelled `given`/`est` is a real encode+decode from
//! `w3a_bwtlab.run`. See LANE_W3A.md for the write-up.
//!
//! usage: w3a_sweep [quick]   ("quick" shrinks the grids for a fast smoke
//!                             run; omit for the full matrix)

const std = @import("std");
const w3a_gprobe = @import("w3a_gprobe.zig");
const w3a_bwtlab = @import("w3a_bwtlab.zig");

const files = [_][]const u8{ "freedict", "gcide", "omw", "json", "macho", "zigsrc" };
const blocks = [_]usize{ 0, 1048576, 65536 };
const full_grid_files = [_][]const u8{ "json", "macho", "freedict" }; // lead's explicit THETA-sweep request

const theta_full = [_]u32{ 95, 80, 60, 40, 20, 0 };
const cmin_grid = [_]u32{ 4, 16 };
const theta_handful = [_]u32{ 80, 40, 0 };

const max_passes: usize = 300; // see w3a_gprobe.buildBounded's doc comment

// Given by the lead (LANE_W3A prompt), for the 65536-block comparison only;
// not derived in this file. freedict, gcide, omw, json, macho, zigsrc order.
const main_line_64k_given = [_]usize{ 692_000, 1_603_000, 424_000, 1_183_000, 3_008_000, 1_336_000 };

fn mainLine64kGiven(file: []const u8) ?usize {
    for (files, 0..) |f, i| {
        if (std.mem.eql(u8, f, file)) return main_line_64k_given[i];
    }
    return null;
}

fn gatesFor(alloc: std.mem.Allocator, file: []const u8, block_bytes: usize) ![]w3a_gprobe.DetGate {
    var use_full = false;
    if (block_bytes == 0) {
        for (full_grid_files) |f| {
            if (std.mem.eql(u8, f, file)) use_full = true;
        }
    }
    const thetas: []const u32 = if (use_full) &theta_full else &theta_handful;
    var out: std.ArrayList(w3a_gprobe.DetGate) = .empty;
    for (thetas) |t| for (cmin_grid) |c| try out.append(alloc, .{ .theta_pct = t, .c_min = c });
    return out.toOwnedSlice(alloc);
}

/// Parse baselines.tsv (Lane D's real bz3base runs) and return the
/// total_bytes for `file`+`block_bytes`, or null if not found.
fn bzip3Total(bytes: []const u8, file: []const u8, block_bytes: usize) !?usize {
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
        const block_val = try std.fmt.parseUnsigned(usize, f_block, 10);
        if (std.mem.eql(u8, f_file, file) and block_val == block_bytes) {
            return try std.fmt.parseUnsigned(usize, f_total, 10);
        }
    }
    return null;
}

const CellResult = struct {
    report: w3a_bwtlab.Report,
    bzip3_total: ?usize,
};

fn pctVsBzip3(total: usize, bzip3: usize) f64 {
    return (@as(f64, @floatFromInt(total)) - @as(f64, @floatFromInt(bzip3))) / @as(f64, @floatFromInt(bzip3)) * 100.0;
}

fn printSweepRow(r: w3a_bwtlab.Report, bzip3: ?usize) void {
    const pct: f64 = if (bzip3) |b| pctVsBzip3(r.total_bytes, b) else 0;
    std.debug.print("SWEEP\t{s}\t{d}\ttheta={d}\tcmin={d}\trules={d}\troots={d}\tpayload_B={d}\tmodel_B={d}\ttotal_B={d}\tdpb={d:.3}\tpasses={d}\tcapped={}\tpct_vs_bzip3={d:.2}\n", .{
        r.file,       r.block_bytes,   r.theta_pct,          r.c_min,
        r.rule_count, r.root_count,    r.payload_bytes,      r.model_bytes,
        r.total_bytes, r.decisions_per_byte, r.grammar_passes, r.grammar_capped,
        pct,
    });
}

fn printAutoRow(r: w3a_bwtlab.Report, bzip3: ?usize, main_line_given: ?usize) void {
    const pct: f64 = if (bzip3) |b| pctVsBzip3(r.total_bytes, b) else -1;
    std.debug.print(
        "AUTO\t{s}\tblock={d}\tsetting=theta{d}_cmin{d}\trules={d}\troots={d}\tmodel_B={d}\tpayload_B={d}\ttotal_B={d}\tbzip3_B={?d}\tpct_vs_bzip3={d:.2}\tdecisions_per_byte={d:.3}\tmain_line_64k_given={?d}\tpasses={d}\tcapped={}\n",
        .{
            r.file,        r.block_bytes, r.theta_pct, r.c_min,
            r.rule_count,  r.root_count,  r.model_bytes, r.payload_bytes,
            r.total_bytes, bzip3,         pct,         r.decisions_per_byte,
            main_line_given, r.grammar_passes, r.grammar_capped,
        },
    );
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var io_impl = std.Io.Threaded.init(alloc, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    const baselines = try std.Io.Dir.cwd().readFileAlloc(init.io, "baselines.tsv", alloc, .limited(1 << 20));
    defer alloc.free(baselines);

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const quick = if (it.next()) |a| std.mem.eql(u8, a, "quick") else false;

    for (files) |file| {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "data/{s}.eval8.bin", .{file});
        const input = try std.Io.Dir.cwd().readFileAlloc(init.io, path, alloc, .limited(1 << 30));
        defer alloc.free(input);
        var tsv_name_buf: [256]u8 = undefined;
        const tsv_name = try std.fmt.bufPrint(&tsv_name_buf, "{s}.eval8.bin", .{file});

        for (blocks) |block_bytes| {
            const gates_full = try gatesFor(alloc, file, block_bytes);
            defer alloc.free(gates_full);
            const gates = if (quick) gates_full[0..@min(gates_full.len, 2)] else gates_full;

            var best: ?w3a_bwtlab.Report = null;
            for (gates) |gate| {
                const cfg = w3a_bwtlab.W3aConfig{ .gate = gate, .max_passes = max_passes };
                const r = w3a_bwtlab.run(alloc, io, path, input, block_bytes, cfg) catch |e| {
                    std.debug.print("ERROR\t{s}\tblock={d}\ttheta={d}\tcmin={d}\terr={s}\n", .{ file, block_bytes, gate.theta_pct, gate.c_min, @errorName(e) });
                    continue;
                };
                const bz = try bzip3Total(baselines, tsv_name, block_bytes);
                printSweepRow(r, bz);
                if (best == null or r.total_bytes < best.?.total_bytes) best = r;
            }

            if (best) |b| {
                const bz = try bzip3Total(baselines, tsv_name, block_bytes);
                const ml: ?usize = if (block_bytes == 65536) mainLine64kGiven(file) else null;
                printAutoRow(b, bz, ml);

                // Idea-2 ablation, lead's explicit request: freedict/json/macho
                // at whole-file, using this cell's auto-selected gate.
                if (block_bytes == 0) {
                    var is_target = false;
                    for (full_grid_files) |f| if (std.mem.eql(u8, f, file)) {
                        is_target = true;
                    };
                    if (is_target) {
                        const idea2_variants = [_]struct { name: []const u8, cfg: w3a_bwtlab.Idea2Config }{
                            .{ .name = "none", .cfg = .{} },
                            .{ .name = "fctx", .cfg = .{ .use_fctx = true } },
                            .{ .name = "fctx_bytes", .cfg = .{ .use_fctx_bytes = true } },
                            .{ .name = "boundary", .cfg = .{ .use_boundary_ctx = true } },
                            .{ .name = "urn", .cfg = .{ .use_urn = true } },
                            .{ .name = "all", .cfg = .{ .use_fctx = true, .use_fctx_bytes = true, .use_boundary_ctx = true, .use_urn = true } },
                        };
                        for (idea2_variants) |v| {
                            const cfg2 = w3a_bwtlab.W3aConfig{
                                .gate = .{ .theta_pct = b.theta_pct, .c_min = b.c_min },
                                .max_passes = max_passes,
                                .idea2 = v.cfg,
                            };
                            const r2 = w3a_bwtlab.run(alloc, io, path, input, block_bytes, cfg2) catch |e| {
                                std.debug.print("ABLATION_ERROR\t{s}\tvariant={s}\terr={s}\n", .{ file, v.name, @errorName(e) });
                                continue;
                            };
                            std.debug.print("ABLATION\t{s}\tvariant={s}\tpayload_B={d}\ttotal_B={d}\tdelta_vs_none_B={d}\n", .{
                                file, v.name, r2.payload_bytes, r2.total_bytes, @as(i64, @intCast(r2.total_bytes)) - @as(i64, @intCast(b.total_bytes)),
                            });
                        }
                    }
                }
            }
        }
    }
}
