//! bz4cli: command-line front-end for bz4.zig.
//!
//! usage:
//!   bz4 c IN OUT [block_bytes] [effort]
//!   bz4 d IN OUT
//!
//! Pure Zig 0.16, std only.

const std = @import("std");
const bz4 = @import("bz4.zig");

fn usage() void {
    std.debug.print("usage: bz4 c IN OUT [block_bytes] [effort]\n       bz4 d IN OUT\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const mode = it.next() orelse {
        usage();
        return error.Usage;
    };
    const in_path = it.next() orelse {
        usage();
        return error.Usage;
    };
    const out_path = it.next() orelse {
        usage();
        return error.Usage;
    };

    const input = try std.Io.Dir.cwd().readFileAlloc(io, in_path, alloc, .limited(1 << 32));
    defer alloc.free(input);

    if (std.mem.eql(u8, mode, "c")) {
        var block_bytes: usize = 65536;
        if (it.next()) |b| block_bytes = try std.fmt.parseUnsigned(usize, b, 10);
        var effort: u8 = 0;
        if (it.next()) |e| {
            if (std.mem.eql(u8, e, "-v")) {
                bz4.debug_candidates = true;
            } else {
                effort = try std.fmt.parseUnsigned(u8, e, 10);
            }
        }
        if (it.next()) |flag| {
            if (std.mem.eql(u8, flag, "-v")) bz4.debug_candidates = true;
        }

        const result = try bz4.compressStats(alloc, input, .{ .block_bytes = block_bytes, .effort = effort });
        defer alloc.free(result.bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = result.bytes });
        std.debug.print(
            "bz4 c: {s} ({d} bytes) -> {s} ({d} bytes); rules={d} roots={d} model={d}B dir={d}B payload={d}B candidate={s} variant={s}\n",
            .{
                in_path,
                input.len,
                out_path,
                result.bytes.len,
                result.stats.rules,
                result.stats.roots,
                result.stats.model_bytes,
                result.stats.directory_bytes,
                result.stats.payload_bytes,
                result.stats.candidate,
                result.stats.variant.name(),
            },
        );
    } else if (std.mem.eql(u8, mode, "d")) {
        var frame = try bz4.open(alloc, input);
        defer frame.deinit();
        const out = try alloc.alloc(u8, frame.raw_len);
        defer alloc.free(out);
        try frame.decodeAll(out);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out });
        std.debug.print("bz4 d: {s} ({d} bytes) -> {s} ({d} bytes)\n", .{ in_path, input.len, out_path, out.len });
    } else {
        usage();
        return error.Usage;
    }
}
