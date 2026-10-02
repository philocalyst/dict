//! A strict live-allocation cap for the private prepared native-v4 reader.
//! The unchanged v4 Decoder owns an arena; its lifetime and the immutable Job
//! directory both use this allocator. Frames and caller buffers are bounded
//! separately by the enclosing reader and prepared_jobs preflight.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const limit_bytes: usize = 512 * 1024 * 1024;

pub const Budget = struct {
    parent: Allocator,
    limit: usize = limit_bytes,
    live: usize = 0,
    peak: usize = 0,

    pub fn allocator(self: *Budget) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc, .resize = resize, .remap = remap, .free = free,
        } };
    }

    fn permits(self: *Budget, previous: usize, next: usize) bool {
        return next <= previous or next - previous <= self.limit - self.live;
    }

    fn record(self: *Budget, previous: usize, next: usize) void {
        self.live = self.live - previous + next;
        self.peak = @max(self.peak, self.live);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (!self.permits(0, len)) return null;
        const bytes = self.parent.rawAlloc(len, alignment, ret) orelse return null;
        self.record(0, len);
        return bytes;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, length: usize, ret: usize) bool {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (!self.permits(memory.len, length) or
            !self.parent.rawResize(memory, alignment, length, ret)) return false;
        self.record(memory.len, length);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, length: usize, ret: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (!self.permits(memory.len, length)) return null;
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

test "cap rejects a growth before parent allocation and frees to zero" {
    var budget: Budget = .{ .parent = std.testing.allocator, .limit = 64 };
    const a = budget.allocator();
    const first = try a.alloc(u8, 32);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 33));
    try std.testing.expectEqual(@as(usize, 32), budget.live);
    a.free(first);
    try std.testing.expectEqual(@as(usize, 0), budget.live);
    try std.testing.expectEqual(@as(usize, 32), budget.peak);
}
