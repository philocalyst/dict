//! b2_lab: Lane B2 measurement CLI.
//!
//! usage: b2_lab DUMP_PATH VARIANT
//!   VARIANT is one of the b2_lexcodec.Variant names, or "all" to run every
//!   variant against the same parsed dump and print one TSV line each.
//!
//! Each run: readDump -> encode -> decode (a genuinely separate function
//! that sees only the bytes) -> verify (bijection-by-flattened-expansion +
//! g check, computed from outside both, purely from their public outputs).
//! Prints one TSV line to STDOUT per (dump, variant); diagnostics go to
//! stderr so stdout can be piped straight into a results file.
//!
//! Pure Zig 0.16, std only.

const std = @import("std");
const b2 = @import("b2_lexcodec.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const path = it.next() orelse return error.Usage;
    const variant_name = it.next() orelse return error.Usage;
    if (it.next()) |flag| {
        if (std.mem.eql(u8, flag, "-v")) b2.debug_stats = true;
    }

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, alloc, .limited(256 << 20));
    var dump = try b2.readDump(alloc, bytes);
    defer dump.deinit();

    const dump_name = std.fs.path.basename(path);

    var outbuf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &outbuf);

    std.debug.print(
        "# dump\tvariant\tentries\tmodel_bytes\tbits_per_entry\tstruct_bytes\tstruct_bpe\tg_bytes\tg_bpe\tencode_ms\tdecode_ms\tverify\tmismatches(old/new/g/spot)\tlanem_bytes\tpct_of_lanem\n",
        .{},
    );

    if (std.mem.eql(u8, variant_name, "all")) {
        inline for (std.meta.fields(b2.Variant)) |f| {
            const v: b2.Variant = @enumFromInt(f.value);
            runOne(init, alloc, &out.interface, dump_name, &dump, v) catch |err| {
                std.debug.print("{s}\t{s}\tERROR\t{s}\n", .{ dump_name, v.name(), @errorName(err) });
            };
        }
    } else {
        const v = b2.Variant.fromName(variant_name) orelse return error.UnknownVariant;
        try runOne(init, alloc, &out.interface, dump_name, &dump, v);
    }
    try out.interface.flush();
}

/// Lane M's real model_bytes for each of the 12 required dumps, from
/// LANE_M.md's headline table -- used only to print `pct_of_lanem`, never
/// fed into the codec itself.
const LaneMEntry = struct { name: []const u8, model_bytes: u64 };
const lanem_bytes = [_]LaneMEntry{
    .{ .name = "m_freedict.eval8.65536.b4sd", .model_bytes = 80213 },
    .{ .name = "m_freedict.eval8.16384.b4sd", .model_bytes = 80338 },
    .{ .name = "m_freedict.untouched.65536.b4sd", .model_bytes = 11237 },
    .{ .name = "m_gcide.eval8.65536.b4sd", .model_bytes = 143564 },
    .{ .name = "m_gcide.eval8.16384.b4sd", .model_bytes = 142868 },
    .{ .name = "m_gcide.untouched.65536.b4sd", .model_bytes = 27486 },
    .{ .name = "m_omw.eval8.65536.b4sd", .model_bytes = 194059 },
    .{ .name = "m_omw.eval8.16384.b4sd", .model_bytes = 198208 },
    .{ .name = "m_omw.untouched.65536.b4sd", .model_bytes = 28248 },
    .{ .name = "m_json.eval8.65536.b4sd", .model_bytes = 25882 },
    .{ .name = "m_macho.eval8.65536.b4sd", .model_bytes = 499994 },
    .{ .name = "m_zigsrc.eval8.65536.b4sd", .model_bytes = 340084 },
};

fn laneMBytes(dump_name: []const u8) ?u64 {
    for (lanem_bytes) |e| if (std.mem.eql(u8, e.name, dump_name)) return e.model_bytes;
    return null;
}

fn runOne(init: std.process.Init, alloc: std.mem.Allocator, out: *std.Io.Writer, dump_name: []const u8, dump: *const b2.Dump, variant: b2.Variant) !void {
    const t0 = std.Io.Clock.awake.now(init.io).nanoseconds;
    var enc = try b2.encodeDump(alloc, dump, variant);
    defer enc.deinit();
    const t1 = std.Io.Clock.awake.now(init.io).nanoseconds;
    var dec = try b2.decode(alloc, enc.bytes);
    defer dec.deinit();
    const t2 = std.Io.Clock.awake.now(init.io).nanoseconds;

    const vr = try b2.verify(alloc, dump.entries, dump.g, dec.entries, dec.g);

    const entries_f: f64 = @floatFromInt(dump.entry_count);
    const total_bytes = enc.stats.total_bytes;
    const struct_bytes = enc.stats.struct_bytes;
    const g_bytes = enc.stats.g_bytes;
    const bits_per_entry = @as(f64, @floatFromInt(total_bytes)) * 8.0 / entries_f;
    const struct_bpe = @as(f64, @floatFromInt(struct_bytes)) * 8.0 / entries_f;
    const g_bpe = @as(f64, @floatFromInt(g_bytes)) * 8.0 / entries_f;
    const encode_ms = @as(f64, @floatFromInt(t1 - t0)) / 1e6;
    const decode_ms = @as(f64, @floatFromInt(t2 - t1)) / 1e6;

    const lm = laneMBytes(dump_name);
    const pct_of_lanem: f64 = if (lm) |b| 100.0 * @as(f64, @floatFromInt(total_bytes)) / @as(f64, @floatFromInt(b)) else -1.0;

    try out.print("{s}\t{s}\t{d}\t{d}\t{d:.3}\t{d}\t{d:.3}\t{d}\t{d:.3}\t{d:.3}\t{d:.3}\t{s}\t{d}/{d}/{d}/{d}\t{d}\t{d:.1}\n", .{
        dump_name,
        variant.name(),
        dump.entry_count,
        total_bytes,
        bits_per_entry,
        struct_bytes,
        struct_bpe,
        g_bytes,
        g_bpe,
        encode_ms,
        decode_ms,
        if (vr.ok) "OK" else "FAIL",
        vr.unmatched_old,
        vr.unmatched_new,
        vr.g_mismatches,
        vr.spot_mismatches,
        if (lm) |b| b else 0,
        pct_of_lanem,
    });
    try out.flush();
}
