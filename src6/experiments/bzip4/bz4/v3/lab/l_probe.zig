const std = @import("std");
const llearn = @import("l_learn.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const path = args.next() orelse "data/gcide.eval8.bin";
    const block: usize = if (args.next()) |s| try std.fmt.parseUnsigned(usize, s, 10) else 65536;
    const iters: usize = if (args.next()) |s| try std.fmt.parseUnsigned(usize, s, 10) else 20;

    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20));
    var parse = try llearn.learn(gpa, raw, block, .{ .max_iters = iters });
    defer parse.deinit(gpa);
    for (parse.log) |l| {
        std.debug.print("iter={d:2} entries={d:6} tokens={d:8} est_B={d:.0} p2={d:5} p3={d:5} del={d:5}\n", .{ l.iter, l.entries, l.tokens, l.est_bits, l.proposed_pairs, l.proposed_triples, l.deleted });
    }
    std.debug.print("final: entries={d} tokens={d} total_B_global={d:.0} num_local={d} total_B_scoped={d:.0}\n", .{ parse.stats.num_entries, parse.stats.num_tokens, parse.stats.total_bits_global / 8.0, parse.stats.num_local_entries, parse.stats.total_bits_scoped / 8.0 });
}
