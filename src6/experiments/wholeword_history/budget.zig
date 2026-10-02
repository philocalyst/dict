//! A live-allocation budget shared by encoder arenas and native model fitting.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Budget = struct {
    parent: Allocator,
    limit: usize,
    live: usize = 0,
    peak: usize = 0,

    pub fn allocator(self: *Budget) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn grow(self: *Budget, previous: usize, next: usize) bool {
        return next <= previous or next - previous <= self.limit - self.live;
    }
    fn record(self: *Budget, previous: usize, next: usize) void {
        self.live = self.live - previous + next;
        self.peak = @max(self.peak, self.live);
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (!self.grow(0, len)) return null;
        const bytes = self.parent.rawAlloc(len, alignment, ret) orelse return null;
        self.record(0, len);
        return bytes;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, length: usize, ret: usize) bool {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (!self.grow(memory.len, length) or !self.parent.rawResize(memory, alignment, length, ret)) return false;
        self.record(memory.len, length);
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, length: usize, ret: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (!self.grow(memory.len, length)) return null;
        const bytes = self.parent.rawRemap(memory, alignment, length, ret) orelse return null;
        self.record(memory.len, length);
        return bytes;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ret);
        self.record(memory.len, 0);
    }
};

test "budget rejects allocation and growth before parent allocation" {
    var budget: Budget = .{ .parent = std.testing.allocator, .limit = 64 };
    const a = budget.allocator();
    const initial = try a.alloc(u8, 48);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 17));
    try std.testing.expectError(error.OutOfMemory, a.realloc(initial, 65));
    try std.testing.expectEqual(@as(usize, 48), budget.live);
    try std.testing.expectEqual(@as(usize, 48), budget.peak);
    a.free(initial);
    try std.testing.expectEqual(@as(usize, 0), budget.live);
    const second = try a.alloc(u8, 64);
    a.free(second);
    try std.testing.expectEqual(@as(usize, 64), budget.peak);
}
