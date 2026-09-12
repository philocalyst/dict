const lex = @import("lex6");

test "slice projection cannot bypass an active union tag" {
    const node: lex.model.Inline = .{ .comment = "comment" };
    const match: lex.query.Match(lex.model.Inline) = .{ .value = &node, .language = .{} };
    _ = match.values(.text);
}
