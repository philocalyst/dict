//! Honor temporary frees inside unchanged legacy research helpers, then
//! release the retained outputs together after they have been copied.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Scope = struct {
    parent: Allocator,
    owned: std.AutoHashMapUnmanaged(usize, Allocation) = .empty,
    const Allocation = struct { bytes: []u8, alignment: Alignment };

    pub fn allocator(self: *Scope) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = Allocator.noRemap, .free = free } };
    }
    pub fn deinit(self: *Scope) void {
        var iter = self.owned.valueIterator();
        while (iter.next()) |item| self.parent.rawFree(item.bytes, item.alignment, @returnAddress());
        self.owned.deinit(self.parent);
        self.owned = .empty;
    }
    fn alloc(ctx: *anyopaque, length: usize, alignment: Alignment, ret: usize) ?[*]u8 {
        const self: *Scope = @ptrCast(@alignCast(ctx));
        const bytes = self.parent.rawAlloc(length, alignment, ret) orelse return null;
        self.owned.put(self.parent, @intFromPtr(bytes), .{ .bytes = bytes[0..length], .alignment = alignment }) catch {
            self.parent.rawFree(bytes[0..length], alignment, ret);
            return null;
        };
        return bytes;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, length: usize, ret: usize) bool {
        const self: *Scope = @ptrCast(@alignCast(ctx));
        const item = self.owned.getPtr(@intFromPtr(memory.ptr)) orelse return false;
        if (memory.len != item.bytes.len or alignment != item.alignment) return false;
        if (!self.parent.rawResize(item.bytes, alignment, length, ret)) return false;
        item.bytes = memory.ptr[0..length];
        return true;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret: usize) void {
        const self: *Scope = @ptrCast(@alignCast(ctx));
        const item = self.owned.fetchRemove(@intFromPtr(memory.ptr)) orelse @panic("unknown scoped allocation");
        // grammar2 returns a shortened seq view. Retaining the true allocation
        // length makes cleanup correct even for that legacy ownership shape.
        std.debug.assert(memory.len <= item.value.bytes.len and alignment == item.value.alignment);
        self.parent.rawFree(item.value.bytes, item.value.alignment, ret);
    }
};

test "individual frees and shortened legacy views release their full allocations" {
    var scope: Scope = .{ .parent = std.testing.allocator };
    defer scope.deinit();
    const alloc = scope.allocator();
    const retained = try alloc.alloc(u8, 1024);
    const temporary = try alloc.alloc(u32, 4096);
    alloc.free(temporary);
    try std.testing.expectEqual(@as(usize, 1), scope.owned.count());
    const shortened: []u8 = retained[0..17];
    alloc.free(shortened);
    try std.testing.expectEqual(@as(usize, 0), scope.owned.count());
    _ = try alloc.alloc(u8, 123); // released by scope.deinit()
}

test "reallocated buffers retain correct cleanup ownership" {
    var scope: Scope = .{ .parent = std.testing.allocator };
    defer scope.deinit();
    const alloc = scope.allocator();
    var bytes = try alloc.alloc(u8, 64);
    @memset(bytes, 42);
    bytes = try alloc.realloc(bytes, 200);
    for (bytes[0..64]) |byte| try std.testing.expectEqual(@as(u8, 42), byte);
    bytes = try alloc.realloc(bytes, 32);
    alloc.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), scope.owned.count());
}
