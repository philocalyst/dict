//! Actual complete ordinal bundle: paid directory and independent native pages.
const std = @import("std");
const grammar = @import("grammar.zig");
pub const Group = struct { first: u32, roots: u32, original_page_bytes: u32 };
pub const Error = error{ OutOfMemory, InvalidBundle, BundleLimit, DigestMismatch, InvalidIndex };
pub const max_bundle: usize = 64 * 1024 * 1024;
fn get32(b: []const u8, at: usize) u32 { return std.mem.readInt(u32, b[at..][0..4], .little); }
fn put32(b: []u8, at: usize, value: usize) void { std.mem.writeInt(u32, b[at..][0..4], @intCast(value), .little); }
pub fn digest(bytes: []const u8) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{}); h.update(bytes[0..32]); h.update(bytes[64..]); var out: [32]u8 = undefined; h.final(&out); return out;
}
pub fn encode(a: std.mem.Allocator, groups: []const Group, pages: []const []const u8) Error![]u8 {
    if (groups.len != pages.len or groups.len > 65535) return error.BundleLimit;
    var length: usize = 64 + groups.len * 24; var roots: usize = 0; var raw: usize = 0;
    for (groups, pages) |group, page| {
        if (group.first != roots or group.roots == 0 or page.len < grammar.header_size or group.roots != get32(page, 16)) return error.InvalidBundle;
        if (group.original_page_bytes != 64 + (group.roots + 1) * 4 + get32(page, 52)) return error.InvalidBundle;
        roots += group.roots; raw += group.original_page_bytes;
        length = std.math.add(usize, length, page.len) catch return error.BundleLimit;
        if (length > max_bundle or roots > 1_000_000) return error.BundleLimit;
    }
    const bytes = try a.alloc(u8, length); @memset(bytes[0..64], 0); @memcpy(bytes[0..4], "LTB1"); bytes[4] = 1;
    put32(bytes, 8, groups.len); put32(bytes, 12, roots); put32(bytes, 16, 24); std.mem.writeInt(u64, bytes[24..32], raw, .little);
    var at: usize = 64 + groups.len * 24;
    for (groups, pages, 0..) |group, page, i| {
        const row = 64 + i * 24; @memset(bytes[row..][0..24], 0);
        put32(bytes, row, group.first); put32(bytes, row + 4, group.roots); put32(bytes, row + 8, group.original_page_bytes); put32(bytes, row + 12, page.len); put32(bytes, row + 16, at);
        @memcpy(bytes[at..][0..page.len], page); at += page.len;
    }
    @memcpy(bytes[32..64], &digest(bytes)); return bytes;
}
pub const Bundle = struct {
    bytes: []const u8, pages: usize, roots: usize,
    pub fn page(self: Bundle, index: usize) Error![]const u8 {
        if (index >= self.pages) return error.InvalidIndex;
        const row = 64 + index * 24; const offset: usize = get32(self.bytes, row + 16); const size: usize = get32(self.bytes, row + 12);
        return self.bytes[offset..][0..size];
    }
    pub fn find(self: Bundle, root: usize) Error!struct { page: usize, local: usize } {
        if (root >= self.roots) return error.InvalidIndex;
        var lo: usize = 0; var hi = self.pages;
        while (lo < hi) { const mid = lo + (hi - lo) / 2; if (get32(self.bytes, 64 + mid * 24) <= root) lo = mid + 1 else hi = mid; }
        if (lo == 0) return error.InvalidBundle;
        return .{ .page = lo - 1, .local = root - get32(self.bytes, 64 + (lo - 1) * 24) };
    }
};
pub fn open(bytes: []const u8) Error!Bundle {
    if (bytes.len < 64 or bytes.len > max_bundle or !std.mem.eql(u8, bytes[0..8], "LTB1\x01\x00\x00\x00") or get32(bytes, 16) != 24 or get32(bytes, 20) != 0) return error.InvalidBundle;
    if (!std.mem.eql(u8, bytes[32..64], &digest(bytes))) return error.DigestMismatch;
    const pages: usize = get32(bytes, 8); const roots: usize = get32(bytes, 12);
    if (pages > 65535 or roots > 1_000_000 or pages > (bytes.len - 64) / 24) return error.BundleLimit;
    var at: usize = 64 + pages * 24; var first: usize = 0; var raw: u64 = 0;
    for (0..pages) |i| {
        const row = 64 + i * 24; const n: usize = get32(bytes, row + 4); const size: usize = get32(bytes, row + 12);
        if (get32(bytes, row) != first or get32(bytes, row + 16) != at or get32(bytes, row + 20) != 0 or n == 0 or size < grammar.header_size or size > bytes.len - at) return error.InvalidBundle;
        const frame = bytes[at..][0..size];
        if (!std.mem.eql(u8, frame[0..4], "LTC1") or get32(frame, 16) != n) return error.InvalidBundle;
        if (get32(bytes, row + 8) != 64 + (n + 1) * 4 + get32(frame, 52)) return error.InvalidBundle;
        raw += get32(bytes, row + 8); first += n; at += size;
    }
    if (at != bytes.len or first != roots or std.mem.readInt(u64, bytes[24..32], .little) != raw) return error.InvalidBundle;
    return .{ .bytes = bytes, .pages = pages, .roots = roots };
}
