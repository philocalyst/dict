//! Isolated oracle: unchanged bz4 v3 fit/Stats over a P6P1 parse.
const std = @import("std");
const enc = @import("encode_instrumented.zig");
const planner = @import("plan_instrumented.zig");
fn takeArray(gpa: std.mem.Allocator, bytes: []const u8, at: *usize) ![]u32 {
    if (bytes.len - at.* < 4) return error.BadParse;
    const n = std.mem.readInt(u32, bytes[at.*..][0..4], .little); at.* += 4;
    if (n > (bytes.len - at.*) / 4) return error.BadParse;
    const out = try gpa.alloc(u32, n);
    for (out) |*x| { x.* = std.mem.readInt(u32, bytes[at.*..][0..4], .little); at.* += 4; }
    return out;
}
fn readParse(gpa: std.mem.Allocator, bytes: []const u8) !enc.Parse {
    if (!std.mem.startsWith(u8, bytes, "P6P1")) return error.BadParse;
    var at: usize = 4;
    const body_off = try takeArray(gpa, bytes, &at);
    const kids = try takeArray(gpa, bytes, &at);
    const block_off = try takeArray(gpa, bytes, &at);
    const toks = try takeArray(gpa, bytes, &at);
    if (at != bytes.len or body_off.len == 0 or block_off.len == 0) return error.BadParse;
    if (body_off[0] != 0 or body_off[body_off.len - 1] != kids.len or block_off[0] != 0 or block_off[block_off.len - 1] != toks.len) return error.BadParse;
    for (body_off[0 .. body_off.len - 1], body_off[1..]) |a, b| if (a >= b or b > kids.len) return error.BadParse;
    for (block_off[0 .. block_off.len - 1], block_off[1..]) |a, b| if (a > b or b > toks.len) return error.BadParse;
    for (kids) |kid| if (kid >= 256 and kid < enc.Parse.cut and kid - 256 >= body_off.len - 1) return error.BadParse;
    for (toks) |tok| if (tok >= 256 and tok - 256 >= body_off.len - 1) return error.BadParse;
    return .{ .body_off = body_off, .kids = kids, .block_off = block_off, .toks = toks };
}
pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args); _ = args.next();
    const data_path = args.next() orelse return error.Usage;
    const parse_path = args.next() orelse return error.Usage;
    const prefix = args.next() orelse return error.Usage;
    const gpa = init.arena.allocator();
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, data_path, gpa, .limited(1 << 30));
    const pbytes = try std.Io.Dir.cwd().readFileAlloc(init.io, parse_path, gpa, .limited(1 << 30));
    const parse = try readParse(gpa, pbytes);
    const fit = try planner.fit(gpa, init.gpa, parse, .{});
    init.gpa.free(fit.bytes);
    var plan = try planner.baseline(gpa, parse, fit.options);
    var stats: enc.Stats = .{
        .entry_bits = try gpa.alloc(f64, plan.parse.entries()),
        .entry_uses = try gpa.alloc(u32, plan.parse.entries()),
        .token_bits = try gpa.alloc(f64, plan.parse.toks.len),
        .token_name_bits = try gpa.alloc(f64, plan.parse.toks.len),
        .token_def_bits = try gpa.alloc(f64, plan.parse.toks.len),
    };
    @memset(stats.entry_bits.?, 0); @memset(stats.entry_uses.?, 0); @memset(stats.token_bits.?, 0); @memset(stats.token_name_bits.?, 0); @memset(stats.token_def_bits.?, 0);
    const frame = try enc.encode(init.gpa, &plan, &stats); defer init.gpa.free(frame);
    const lengths = try plan.parse.lengths(gpa);
    var raw_len: usize = 0;
    for (plan.parse.toks) |tok| raw_len += if (tok < 256) 1 else lengths[tok - 256];
    if (raw_len != data.len) return error.ParseSourceLengthMismatch;
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.token_bits.f64", .{prefix}), .data = std.mem.sliceAsBytes(stats.token_bits.?) });
    try cwd.writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.entry_bits.f64", .{prefix}), .data = std.mem.sliceAsBytes(stats.entry_bits.?) });
    try cwd.writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.entry_uses.u32", .{prefix}), .data = std.mem.sliceAsBytes(stats.entry_uses.?) });
    try cwd.writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.toks.u32", .{prefix}), .data = std.mem.sliceAsBytes(plan.parse.toks) });
    try cwd.writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.lengths.u32", .{prefix}), .data = std.mem.sliceAsBytes(lengths) });
    try cwd.writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.name_bits.f64", .{prefix}), .data = std.mem.sliceAsBytes(stats.token_name_bits.?) });
    try cwd.writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.def_bits.f64", .{prefix}), .data = std.mem.sliceAsBytes(stats.token_def_bits.?) });
    const K = enc.Stats.Kind;
    var out: std.Io.Writer.Allocating = .init(gpa); defer out.deinit();
    try out.writer.print("{{\"frame_bytes\":{d},\"entries\":{d},\"tokens\":{d},\"blocks\":{d},\"classes\":{d},\"delta\":{{", .{ frame.len, plan.parse.entries(), plan.parse.toks.len, plan.parse.blocks(), fit.options.classes });
    inline for (std.enums.values(K), 0..) |kind, i| {
        const d = stats.delta.get(kind); const p = stats.payload.get(kind);
        if (i != 0) try out.writer.writeByte(',');
        try out.writer.print("\"{s}\":{{\"delta_events\":{d},\"delta_coded_bits\":{d:.6},\"delta_raw_bits\":{d},\"payload_events\":{d},\"payload_coded_bits\":{d:.6},\"payload_raw_bits\":{d}}}", .{ @tagName(kind), d.events, d.coded_bits, d.raw_bits, p.events, p.coded_bits, p.raw_bits });
    }
    try out.writer.print("}},\"token_bits_sum\":{d:.6},\"entry_bits_sum\":{d:.6},\"entry_bucket_uses_sum\":{d}}}\n", .{ sum(stats.token_bits.?), sum(stats.entry_bits.?), sumU32(stats.entry_uses.?) });
    const meta = try out.toOwnedSlice(); defer gpa.free(meta);
    try cwd.writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.stats.json", .{prefix}), .data = meta });
}
fn sum(v: []const f64) f64 { var n: f64 = 0; for (v) |x| n += x; return n; }
fn sumU32(v: []const u32) u64 { var n: u64 = 0; for (v) |x| n += x; return n; }
