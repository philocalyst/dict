const std = @import("std");
const lex = @import("lex6");
const shape = @import("shape.zig");
const view_api = @import("shape_view.zig");
const workloads = @import("workloads.zig");

fn expectViews(comptime Root: type, comptime T: type, view: view_api.View(Root, T), original: T) anyerror!void {
    @setEvalBranchQuota(400_000);
    if (comptime @typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice and @typeInfo(T).pointer.child == u8) {
        const text = try view.text();
        try std.testing.expectEqualStrings(original, text);
        return;
    }
    switch (@typeInfo(T)) {
        .void, .bool, .int, .@"enum" => try std.testing.expectEqual(original, try view.scalarValue()),
        .optional => |o| {
            if (original) |child| {
                const projected = (try view.optional()) orelse return error.MissingOptional;
                try expectViews(Root, o.child, projected, child);
            } else try std.testing.expect((try view.optional()) == null);
        },
        .pointer => |p| if (p.size == .one) {
            try expectViews(Root, p.child, try view.pointee(), original.*);
        } else {
            var iterator = try view.values();
            var index: usize = 0;
            while (try iterator.next()) |child| {
                try expectViews(Root, p.child, child, original[index]);
                index += 1;
            }
            try std.testing.expectEqual(original.len, index);
        },
        .array => |a| {
            var iterator = try view.values();
            var index: usize = 0;
            while (try iterator.next()) |child| {
                try expectViews(Root, a.child, child, original[index]);
                index += 1;
            }
            try std.testing.expectEqual(original.len, index);
        },
        .@"struct" => |s| inline for (s.fields) |f| try expectViews(Root, f.type, try view.field(f.name), @field(original, f.name)),
        .@"union" => {
            try std.testing.expectEqual(std.meta.activeTag(original), try view.tag());
            switch (original) {
                inline else => |child, tag| try expectViews(Root, @TypeOf(child), try view.payload(tag), child),
            }
        },
        else => return error.UnsupportedTestType,
    }
}

test "shape hole coordinates preserve every varied multilingual projected value" {
    var source = try workloads.rich(std.testing.allocator, 12);
    defer source.deinit();
    const bytes = try shape.encodePage(lex.model.Entry, std.testing.allocator, source.entries, .{ .max_page_bytes = 1024 * 1024 });
    defer std.testing.allocator.free(bytes);
    const page = try shape.open(lex.model.Entry, std.testing.allocator, bytes, .{ .max_page_bytes = 1024 * 1024 });
    try page.prepare(std.testing.allocator, .{});
    for (source.entries, 0..) |entry, i| try expectViews(lex.model.Entry, lex.model.Entry, try view_api.fromAdmittedPage(lex.model.Entry, page, i), entry);
}

test "checkpoint lookup borrows exact changing text beyond 32 leaves" {
    var source = try workloads.rich(std.testing.allocator, 2);
    defer source.deinit();
    const bytes = try shape.encodePage(lex.model.Entry, std.testing.allocator, source.entries, .{});
    defer std.testing.allocator.free(bytes);
    const page = try shape.open(lex.model.Entry, std.testing.allocator, bytes, .{});
    try page.prepare(std.testing.allocator, .{});
    const root = try view_api.fromAdmittedPage(lex.model.Entry, page, 1);
    const id = try (try root.field(.id)).text();
    try std.testing.expectEqualStrings(source.entries[1].id, id);
    const pointer = @intFromPtr(id.ptr);
    const first = @intFromPtr(bytes.ptr);
    try std.testing.expect(pointer >= first and pointer + id.len <= first + bytes.len);
    var contents = try (try root.field(.content)).values();
    while (try contents.next()) |item| {
        if (try item.tag() == .sense) {
            const sense = try item.payload(.sense);
            const label = try (try sense.field(.label)).optional();
            if (label) |value| try std.testing.expect((try value.text()).len > 0);
        }
    }
}
