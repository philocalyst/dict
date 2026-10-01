const lex = @import("lex6");

test "non-collection fields receive a library-owned diagnostic" {
    const article: lex.model.Entry = .{ .id = "cat", .headword = "cat" };
    _ = lex.query.entry(&article).values(.kind);
}
