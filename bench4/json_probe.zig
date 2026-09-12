const std = @import("std");
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const value = try std.json.parseFromSlice(std.json.Value, arena.allocator(), "{\"x\":1,\"s\":\"é\"}", .{});
    const a = try std.fmt.allocPrint(arena.allocator(), "{f}", .{std.json.fmt(value.value, .{})});
    std.debug.print("{s}\n", .{a});
}
