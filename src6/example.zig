//! A complete client: author, compress, open, look up, select and render.
const std = @import("std");
const lex = @import("lex6");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    try show(init.gpa, &stdout.interface);
    try stdout.interface.flush();
}

fn show(allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    const entries = [_]lex.model.Entry{.{
        .id = "bank-finance",
        .headword = "bank",
        .meta = .{ .language = .{ .tag = "en" } },
        .content = &.{.{ .sense = .{
            .meta = .{ .id = "finance" },
            .content = &.{.{ .definition = .{
                .content = &.{.{ .text = "An institution that holds and lends money." }},
            } }},
        } }},
    }};
    var file = try lex.archive.build(allocator, .{ .entries = &entries }, .{});
    defer file.deinit();
    const dictionary = try lex.archive.Archive.open(file.bytes, .{});
    var reader = try lex.archive.Reader.init(allocator, &dictionary, .{});
    defer reader.deinit();

    var matches = try dictionary.lookup("bank");
    while (try matches.next()) |hit| {
        var loaded = try reader.load(hit.entry);
        defer loaded.deinit();
        var senses = lex.query.entry(&loaded.value).select(.sense, .children);
        while (try senses.next()) |sense| {
            var definitions = sense.select(.definition, .children);
            while (try definitions.next()) |definition| {
                try lex.render.write(definition.value.*, writer, .plain);
                try writer.writeByte('\n');
            }
        }
    }
}

test "complete client example" {
    var bytes: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try show(std.testing.allocator, &writer);
    try std.testing.expectEqualStrings("An institution that holds and lends money.\n", writer.buffered());
}
