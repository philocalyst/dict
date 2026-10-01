//! modellab: Lane B measurement CLI.
//!
//! usage: modellab DUMP_PATH VARIANT
//!   VARIANT is one of v0_naive v1_creation v2_lex_recency v3_urn
//!   v4_slotsplit v5_gctx, or "all" to run every variant against the same
//!   parsed dump and print one TSV line per variant.
//!
//! Each run: encodeModel -> decodeModel (a truly separate function that
//! sees only the bytes) -> verifyModel (bijection + byte-expansion check,
//! computed from outside both, purely from their public outputs). Prints
//! one TSV line to STDOUT per (dump, variant); diagnostics/header go to
//! stderr so stdout can be piped straight into a results file:
//!
//!   dump  variant  rules  model_bytes  bits_per_rule  struct_bytes
//!   struct_bits_per_rule  g_bytes  g_bits_per_rule  encode_ms  decode_ms
//!   verify  unmatched_old/unmatched_new/g_mismatches/spot_mismatches
//!
//! Pure Zig 0.16, std only.

const std = @import("std");
const codec = @import("modelcodec.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const path = it.next() orelse return error.Usage;
    const variant_name = it.next() orelse return error.Usage;
    if (it.next()) |flag| {
        if (std.mem.eql(u8, flag, "-v")) codec.debug_stats = true;
    }

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, alloc, .limited(1 << 30));
    var dump = try codec.readDump(alloc, bytes);
    defer dump.deinit();

    const dump_name = std.fs.path.basename(path);

    var outbuf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &outbuf);

    std.debug.print(
        "# dump\tvariant\trules\tmodel_bytes\tbits_per_rule\tstruct_bytes\tstruct_bpr\tg_bytes\tg_bpr\tencode_ms\tdecode_ms\tverify\tmismatches(old/new/g/spot)\n",
        .{},
    );

    if (std.mem.eql(u8, variant_name, "all")) {
        inline for (std.meta.fields(codec.Variant)) |f| {
            const v: codec.Variant = @enumFromInt(f.value);
            runOne(init, alloc, &out.interface, dump_name, &dump, v) catch |err| {
                std.debug.print("{s}\t{s}\tERROR\t{s}\n", .{ dump_name, v.name(), @errorName(err) });
            };
        }
    } else {
        const v = codec.Variant.fromName(variant_name) orelse return error.UnknownVariant;
        try runOne(init, alloc, &out.interface, dump_name, &dump, v);
    }
    try out.interface.flush();
}

fn runOne(init: std.process.Init, alloc: std.mem.Allocator, out: *std.Io.Writer, dump_name: []const u8, dump: *const codec.Dump, variant: codec.Variant) !void {
    const t0 = std.Io.Clock.awake.now(init.io).nanoseconds;
    var model = try codec.encodeModel(alloc, dump, variant);
    defer model.deinit();
    const t1 = std.Io.Clock.awake.now(init.io).nanoseconds;
    var decoded = try codec.decodeModel(alloc, model.bytes);
    defer decoded.deinit();
    const t2 = std.Io.Clock.awake.now(init.io).nanoseconds;

    const vr = try codec.verifyModel(alloc, dump, &decoded);

    const rules_f: f64 = @floatFromInt(dump.rule_count);
    const total_bytes = model.bytes.len;
    const struct_bytes = model.struct_len;
    const g_bytes = model.g_len;
    const bits_per_rule = @as(f64, @floatFromInt(total_bytes)) * 8.0 / rules_f;
    const struct_bpr = @as(f64, @floatFromInt(struct_bytes)) * 8.0 / rules_f;
    const g_bpr = @as(f64, @floatFromInt(g_bytes)) * 8.0 / rules_f;
    const encode_ms = @as(f64, @floatFromInt(t1 - t0)) / 1e6;
    const decode_ms = @as(f64, @floatFromInt(t2 - t1)) / 1e6;

    try out.print("{s}\t{s}\t{d}\t{d}\t{d:.3}\t{d}\t{d:.3}\t{d}\t{d:.3}\t{d:.3}\t{d:.3}\t{s}\t{d}/{d}/{d}/{d}\n", .{
        dump_name,
        variant.name(),
        dump.rule_count,
        total_bytes,
        bits_per_rule,
        struct_bytes,
        struct_bpr,
        g_bytes,
        g_bpr,
        encode_ms,
        decode_ms,
        if (vr.ok) "OK" else "FAIL",
        vr.unmatched_old,
        vr.unmatched_new,
        vr.g_mismatches,
        vr.spot_mismatches,
    });
    try out.flush();
}
