const std = @import("std");
const lex = @import("lexicon");

pub fn main() !void {
    std.debug.print("lexicon: library build is ready (use `zig build test`)\n", .{});
    _ = lex;
}
