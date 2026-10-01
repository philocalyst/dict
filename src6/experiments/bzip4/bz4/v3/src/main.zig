//! bz4 c IN OUT [BLOCK_BYTES] | bz4 d IN OUT [THREADS]

const std = @import("std");
const bz4 = @import("bz4");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const mode = args.next() orelse return usage();
    const in_path = args.next() orelse return usage();
    const out_path = args.next() orelse return usage();
    const cwd = std.Io.Dir.cwd();
    const input = try cwd.readFileAlloc(init.io, in_path, init.gpa, .limited(1 << 31));
    defer init.gpa.free(input);

    const output = if (std.mem.eql(u8, mode, "c"))
        try bz4.compress(init.gpa, input, .{ .learn = .{ .block = if (args.next()) |n| try std.fmt.parseUnsigned(usize, n, 10) else 1 << 16 } })
    else if (std.mem.eql(u8, mode, "d"))
        try bz4.decompress(init.gpa, input, if (args.next()) |n| try std.fmt.parseUnsigned(usize, n, 10) else std.Thread.getCpuCount() catch 1)
    else
        return usage();
    defer init.gpa.free(output);
    try cwd.writeFile(init.io, .{ .sub_path = out_path, .data = output });
}

fn usage() error{Usage} {
    std.debug.print("usage: bz4 c IN OUT [BLOCK_BYTES] | bz4 d IN OUT [THREADS]\n", .{});
    return error.Usage;
}
