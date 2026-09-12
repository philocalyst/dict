//! Rendering consumes the same bounded content cursor as lexical queries.
//! It streams to Zig's Writer and never builds an intermediate markup string.
const std = @import("std");
const model = @import("model.zig");
const walk = @import("walk.zig");

pub const Error = std.Io.Writer.Error || walk.Error || error{InvalidUtf8};
pub const Format = enum { plain, xml };

/// XML is a semantic reconstruction, not a byte-exact source export. The
/// independently stored source document remains the authority for original bytes.
pub fn write(text: model.Text, writer: *std.Io.Writer, format: Format) Error!void {
    var cursor = walk.Cursor(model.Inline).init(text.content, .{}, .{ .leave_events = format == .xml });
    while (try cursor.next()) |event| {
        if (event.phase == .leave) {
            if (event.node.* == .element) {
                try writer.writeAll("</");
                try qualified(writer, event.node.element.name);
                try writer.writeByte('>');
            }
            continue;
        }
        switch (event.node.*) {
            .text => |value| switch (format) {
                .plain => try writer.writeAll(value),
                .xml => try escaped(writer, value, false),
            },
            .element => |element| if (format == .xml) {
                try writer.writeByte('<');
                try qualified(writer, element.name);
                // A default empty declaration cancels an inherited namespace.
                if (!std.mem.eql(u8, element.name.prefix, "xml"))
                    try namespace(writer, element.name);
                for (element.attributes, 0..) |attribute, index| {
                    if (needsNamespace(element.name, element.attributes[0..index], attribute.name))
                        try namespace(writer, attribute.name);
                }
                switch (element.language) {
                    .inherit => {},
                    .reset => try attributeValue(writer, .{ .prefix = "xml", .local = "lang" }, ""),
                    .tag => |tag| try attributeValue(writer, .{ .prefix = "xml", .local = "lang" }, tag),
                }
                for (element.attributes) |attribute| try attributeValue(writer, attribute.name, attribute.value);
                try writer.writeByte('>');
            },
            .comment => |comment| if (format == .xml) {
                try writer.writeAll("<!--");
                try writer.writeAll(comment);
                try writer.writeAll("-->");
            },
            .instruction => |instruction| if (format == .xml) {
                try writer.writeAll("<?");
                try writer.writeAll(instruction.target);
                if (instruction.data.len != 0) {
                    try writer.writeByte(' ');
                    try writer.writeAll(instruction.data);
                }
                try writer.writeAll("?>");
            },
        }
    }
}

fn needsNamespace(element: model.Name, earlier: []const model.Attribute, name: model.Name) bool {
    if (name.prefix.len == 0 or std.mem.eql(u8, name.prefix, "xml") or
        std.mem.eql(u8, name.prefix, element.prefix)) return false;
    for (earlier) |attribute| {
        if (std.mem.eql(u8, name.prefix, attribute.name.prefix)) return false;
    }
    return true;
}

fn namespace(writer: *std.Io.Writer, name: model.Name) std.Io.Writer.Error!void {
    const declaration: model.Name = if (name.prefix.len == 0)
        .{ .local = "xmlns" }
    else
        .{ .prefix = "xmlns", .local = name.prefix };
    try attributeValue(writer, declaration, name.namespace);
}

fn attributeValue(writer: *std.Io.Writer, name: model.Name, value: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte(' ');
    try qualified(writer, name);
    try writer.writeAll("=\"");
    try escaped(writer, value, true);
    try writer.writeByte('"');
}

fn qualified(writer: *std.Io.Writer, name: model.Name) std.Io.Writer.Error!void {
    if (name.prefix.len != 0) {
        try writer.writeAll(name.prefix);
        try writer.writeByte(':');
    }
    try writer.writeAll(name.local);
}

fn escaped(writer: *std.Io.Writer, text: []const u8, attribute: bool) std.Io.Writer.Error!void {
    var start: usize = 0;
    for (text, 0..) |byte, index| {
        const replacement: ?[]const u8 = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => if (attribute) "&quot;" else null,
            // XML normalizes literal CR and attribute whitespace on reparse.
            '\r' => "&#xD;",
            '\n' => if (attribute) "&#xA;" else null,
            '\t' => if (attribute) "&#x9;" else null,
            else => null,
        };
        if (replacement) |value| {
            try writer.writeAll(text[start..index]);
            try writer.writeAll(value);
            start = index + 1;
        }
    }
    try writer.writeAll(text[start..]);
}

/// The bound is plain-text bytes, not markup bytes or scalar count. Traversal
/// stops at the first omitted scalar, even when it straddles inline fragments.
pub fn snippet(text: model.Text, output: []u8) (walk.Error || error{InvalidUtf8})![]const u8 {
    var cursor = walk.Cursor(model.Inline).init(text.content, .{}, .{});
    var written: usize = 0;
    while (try cursor.next()) |event| {
        if (event.node.* != .text) continue;
        const value = event.node.text;
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        var take = @min(value.len, output.len - written);
        if (take < value.len) {
            while (take != 0 and value[take] & 0xc0 == 0x80) take -= 1;
        }
        @memcpy(output[written..][0..take], value[0..take]);
        written += take;
        if (take != value.len) break;
    }
    return output[0..written];
}
