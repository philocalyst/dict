//! Thin CLI: `bz4v2 compress IN OUT` / `bz4v2 decompress IN OUT`.

const std = @import("std");
const bz4 = @import("bz4v2");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const cmd = it.next() orelse return usage();
    const in_path = it.next() orelse return usage();
    const out_path = it.next() orelse return usage();

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const input = try std.Io.Dir.cwd().readFileAlloc(io, in_path, a, .limited(1 << 31));

    if (std.mem.eql(u8, cmd, "compress")) {
        const result = try bz4.compress(a, input, .{});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = result.bytes });
        std.debug.print("bz4v2: {s} ({d} bytes) -> {s} ({d} bytes), stage={s}, {d} entries, {d} tokens\n", .{
            in_path, input.len, out_path, result.bytes.len, @tagName(result.stage), result.entries, result.tokens,
        });
    } else if (std.mem.eql(u8, cmd, "decompress")) {
        var frame = try bz4.open(a, input);
        defer frame.deinit();
        const out = try a.alloc(u8, frame.raw_len);
        try frame.decodeAll(out);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out });
    } else {
        return usage();
    }
}

fn usage() !void {
    std.debug.print("usage: bz4v2 compress|decompress IN OUT\n", .{});
    return error.Usage;
}
