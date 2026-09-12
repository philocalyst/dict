const lex = @import("lex6");

test "a named payload is not proof of an active union tag" {
    const item: lex.model.Item = .{ .note = .{} };
    const match: lex.query.Match(lex.model.Item) = .{ .value = &item, .language = .{} };
    _ = match.child(.sense);
}
