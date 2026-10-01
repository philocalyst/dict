//! c_fields DATA BITS... — per-XML-element cost of one or more per-byte cost
//! files (f32 bits per input byte), e.g. from `lab --bits` and `c_cm`.
//! Bytes inside tags are "(markup)"; content belongs to the last opened tag.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAlloc(init.io, args.next() orelse return error.Usage, gpa, .limited(1 << 30));
    var costs: std.ArrayList([]align(1) const f32) = .empty;
    while (args.next()) |path| {
        const bytes = try cwd.readFileAlloc(init.io, path, gpa, .limited(1 << 31));
        try costs.append(gpa, std.mem.bytesAsSlice(f32, bytes));
    }

    const Row = struct { bytes: u64 = 0, bits: [4]f64 = @splat(0) };
    var fields: std.StringArrayHashMapUnmanaged(Row) = .empty;
    var field: []const u8 = "(start)";
    var inside = false;
    for (data, 0..) |byte, i| {
        if (byte == '<') {
            inside = true;
            const end = std.mem.indexOfAnyPos(u8, data, i + 1, " >/\n") orelse data.len;
            field = if (end == i + 1) "(between)" else data[i + 1 .. end];
        }
        const white = !inside and std.mem.indexOfScalar(u8, " \n\t", byte) != null and (i + 1 == data.len or data[i + 1] == '<' or data[i + 1] == ' ' or data[i + 1] == '\n');
        const row = (try fields.getOrPutValue(gpa, if (inside or white) "(markup)" else field, .{})).value_ptr;
        row.bytes += 1;
        for (costs.items, 0..) |c, k| row.bits[k] += c[i];
        if (byte == '>') inside = false;
    }
    const Sort = struct {
        values: []const Row,
        pub fn lessThan(s: @This(), a: usize, b: usize) bool {
            return s.values[a].bits[0] > s.values[b].bits[0];
        }
    };
    fields.sort(Sort{ .values = fields.values() });
    var sums: [4]f64 = @splat(0);
    for (fields.values()) |row| for (&sums, row.bits) |*s, b| {
        s.* += b;
    };
    std.debug.print("{s:<16} {s:>9}", .{ "field", "bytes" });
    for (costs.items, 0..) |_, k| std.debug.print(" | {s:>7}{d} {s:>6} {s:>6}", .{ "bytes", k, "share", "bpc" });
    std.debug.print("\n", .{});
    for (fields.keys(), fields.values(), 0..) |name, row, i| {
        if (i >= 16) break;
        std.debug.print("{s:<16} {d:>9}", .{ name[0..@min(name.len, 16)], row.bytes });
        for (costs.items, 0..) |_, k| std.debug.print(" | {d:>8.0} {d:>5.1}% {d:>6.3}", .{ row.bits[k] / 8, 100 * row.bits[k] / sums[k], row.bits[k] / @as(f64, @floatFromInt(row.bytes)) });
        std.debug.print("\n", .{});
    }
    std.debug.print("{s:<16} {d:>9}", .{ "total", data.len });
    for (costs.items, 0..) |_, k| std.debug.print(" | {d:>8.0}               ", .{sums[k] / 8});
    std.debug.print("\n", .{});
}
