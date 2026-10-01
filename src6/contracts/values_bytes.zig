const lex = @import("lex6");

test "a headword is one textual value, not a collection of linguistic values" {
    const article: lex.model.Entry = .{ .id = "cat", .headword = "cat" };
    _ = lex.query.entry(&article).values(.headword);
}
