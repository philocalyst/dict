const std = @import("std");
const lex = @import("src2");

test "public surface is complete" {
    _ = lex.Builder;
    _ = lex.Snapshot;
    _ = lex.Query;
}
