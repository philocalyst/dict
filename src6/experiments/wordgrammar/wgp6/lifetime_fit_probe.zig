//! Fit a trusted private P6F1 parse without rerunning the word learner.
//! Useful for exact-frame and allocator-peak comparisons against old fits.
const std = @import("std");
const bz4 = @import("bz4");
const fitting = @import("lifetime_fit.zig");
const Budget = @import("budget.zig").Budget;

fn takeArray(alloc: std.mem.Allocator, bytes: []const u8, at: *usize) ![]u32 {
    if (at.* > bytes.len or bytes.len - at.* < 4) return error.BadParse;
    const count = std.mem.readInt(u32, bytes[at.*..][0..4], .little);
    at.* += 4;
    if (count > (bytes.len - at.*) / 4) return error.BadParse;
    const out = try alloc.alloc(u32, count);
    for (out) |*value| {
        value.* = std.mem.readInt(u32, bytes[at.*..][0..4], .little);
        at.* += 4;
    }
    return out;
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const parse_path = args.next() orelse return error.Usage;
    const frame_path = args.next() orelse return error.Usage;
    const hoist = try std.fmt.parseUnsigned(u8, args.next() orelse "0", 10);
    const engine = args.next() orelse "lifetime";
    if (args.next() != null or hoist > 1 or (!std.mem.eql(u8, engine, "lifetime") and !std.mem.eql(u8, engine, "original"))) return error.Usage;

    var budget: Budget = .{ .parent = init.gpa, .limit = 4 * 1024 * 1024 * 1024 };
    const bounded = budget.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, parse_path, bounded, .limited(256 * 1024 * 1024));
    defer bounded.free(bytes);
    if (!std.mem.startsWith(u8, bytes, "P6F1")) return error.BadParse;
    var arena: std.heap.ArenaAllocator = .init(bounded);
    defer arena.deinit();
    var at: usize = 4;
    const parse: bz4.Parse = .{
        .body_off = try takeArray(arena.allocator(), bytes, &at),
        .kids = try takeArray(arena.allocator(), bytes, &at),
        .block_off = try takeArray(arena.allocator(), bytes, &at),
        .toks = try takeArray(arena.allocator(), bytes, &at),
    };
    if (at != bytes.len or parse.body_off.len == 0 or parse.block_off.len == 0) return error.BadParse;
    if (parse.body_off[0] != 0 or parse.body_off[parse.body_off.len - 1] != parse.kids.len) return error.BadParse;
    if (parse.block_off[0] != 0 or parse.block_off[parse.block_off.len - 1] != parse.toks.len) return error.BadParse;

    const start = std.Io.Clock.awake.now(init.io).nanoseconds;
    var legacy_arena: std.heap.ArenaAllocator = .init(bounded);
    defer legacy_arena.deinit();
    const fit: fitting.Fit = if (std.mem.eql(u8, engine, "original")) blk: {
        const old = try bz4.plan.fit(legacy_arena.allocator(), bounded, parse, .{ .hoist = hoist == 1 });
        break :blk .{ .bytes = old.bytes, .classes = old.options.classes };
    } else try fitting.fit(bounded, parse, .{ .hoist = hoist == 1 });
    defer bounded.free(fit.bytes);
    const elapsed = std.Io.Clock.awake.now(init.io).nanoseconds - start;
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = frame_path, .data = fit.bytes });
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.print("{f}\n", .{std.json.fmt(.{ .engine = engine, .frame_bytes = fit.bytes.len, .classes = fit.classes, .fit_ns = elapsed, .peak_allocated_bytes = budget.peak, .limit_bytes = budget.limit }, .{})});
    try writer.interface.flush();
}
