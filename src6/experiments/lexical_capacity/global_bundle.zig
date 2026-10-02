//! A paid immutable stock shared by original groups, with independent root
//! streams inside its native grammar frame. Original grouping is retained as
//! a source/restart directory; it does not duplicate the stock per group.
const std = @import("std");
const grammar = @import("grammar.zig");
const lex = @import("lex6");
pub const header_size = 128;
pub const Group = struct { first: u32, roots: u32, original_page_bytes: u32, canonical_start: u32, canonical_end: u32 };
pub const Error = error{ OutOfMemory, InvalidBundle, BundleLimit, DigestMismatch, InvalidIndex };
const max_bundle: usize = 64 * 1024 * 1024;
fn get32(b: []const u8, at: usize) usize { return std.mem.readInt(u32, b[at..][0..4], .little); }
fn put32(b: []u8, at: usize, value: usize) void { std.mem.writeInt(u32, b[at..][0..4], @intCast(value), .little); }
pub fn digest(bytes: []const u8) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{}); h.update(bytes[0..96]); h.update(bytes[128..]); var out: [32]u8 = undefined; h.final(&out); return out;
}
pub fn reseal(bytes: []u8) void { @memcpy(bytes[96..128], &digest(bytes)); }
pub fn encode(a: std.mem.Allocator, groups: []const Group, frame: []const u8, source_hash: [32]u8) Error![]u8 {
    if (groups.len > 65535 or frame.len < grammar.header_size) return error.BundleLimit;
    const length = header_size + groups.len * 24 + frame.len;
    if (length > max_bundle) return error.BundleLimit;
    var first: usize = 0; var canonical: usize = 0; var raw: u64 = 0;
    for (groups) |group| {
        if (group.first != first or group.roots == 0 or group.canonical_start != canonical or group.canonical_end < canonical) return error.InvalidBundle;
        if (group.original_page_bytes != 64 + 4 * (@as(usize, group.roots) + 1) + group.canonical_end - canonical) return error.InvalidBundle;
        first += group.roots; canonical = group.canonical_end; raw += group.original_page_bytes;
    }
    if (first > 1_000_000 or first != get32(frame, 16) or canonical != get32(frame, 52) or !std.mem.eql(u8, frame[0..4], "LTC1")) return error.InvalidBundle;
    const bytes = try a.alloc(u8, length); @memset(bytes[0..header_size], 0); @memcpy(bytes[0..4], "LGB1"); bytes[4] = 1;
    put32(bytes, 8, groups.len); put32(bytes, 12, first); put32(bytes, 16, 24); put32(bytes, 20, header_size + groups.len * 24); put32(bytes, 24, frame.len);
    std.mem.writeInt(u64, bytes[32..40], raw, .little); std.mem.writeInt(u64, bytes[40..48], canonical, .little); @memcpy(bytes[64..96], &source_hash);
    for (groups, 0..) |group, i| {
        const row = header_size + i * 24;
        put32(bytes, row, group.first); put32(bytes, row + 4, group.roots); put32(bytes, row + 8, group.original_page_bytes); put32(bytes, row + 12, group.canonical_start); put32(bytes, row + 16, group.canonical_end); put32(bytes, row + 20, 0);
    }
    @memcpy(bytes[header_size + groups.len * 24..], frame); reseal(bytes); return bytes;
}
pub const Bundle = struct {
    bytes: []const u8, groups: usize, roots: usize,
    pub fn frame(self: Bundle) []const u8 { return self.bytes[get32(self.bytes, 20)..]; }
    pub fn group(self: Bundle, i: usize) Error!Group {
        if (i >= self.groups) return error.InvalidIndex;
        const row = header_size + i * 24;
        return .{ .first = @intCast(get32(self.bytes, row)), .roots = @intCast(get32(self.bytes, row + 4)), .original_page_bytes = @intCast(get32(self.bytes, row + 8)), .canonical_start = @intCast(get32(self.bytes, row + 12)), .canonical_end = @intCast(get32(self.bytes, row + 16)) };
    }
    pub fn find(self: Bundle, root: usize) Error!struct { group: usize, local: usize, global: usize } {
        if (root >= self.roots) return error.InvalidIndex;
        var lo: usize = 0; var hi = self.groups;
        while (lo < hi) { const mid = lo + (hi - lo) / 2; if (get32(self.bytes, header_size + mid * 24) <= root) lo = mid + 1 else hi = mid; }
        if (lo == 0) return error.InvalidBundle;
        return .{ .group = lo - 1, .local = root - get32(self.bytes, header_size + (lo - 1) * 24), .global = root };
    }
};
pub fn open(bytes: []const u8) Error!Bundle {
    if (bytes.len < header_size or bytes.len > max_bundle or !std.mem.eql(u8, bytes[0..8], "LGB1\x01\x00\x00\x00") or get32(bytes, 16) != 24 or get32(bytes, 28) != 0 or !std.mem.eql(u8, bytes[48..64], &@as([16]u8, @splat(0)))) return error.InvalidBundle;
    if (!std.mem.eql(u8, bytes[96..128], &digest(bytes))) return error.DigestMismatch;
    const groups = get32(bytes, 8); const roots = get32(bytes, 12);
    if (groups > 65535 or roots > 1_000_000 or groups > (bytes.len - header_size) / 24) return error.BundleLimit;
    const at = header_size + groups * 24; const size = get32(bytes, 24);
    if (get32(bytes, 20) != at or size < grammar.header_size or size != bytes.len - at) return error.InvalidBundle;
    const frame = bytes[at..];
    if (!std.mem.eql(u8, frame[0..4], "LTC1") or get32(frame, 16) != roots) return error.InvalidBundle;
    var first: usize = 0; var canonical: usize = 0; var raw: u64 = 0;
    for (0..groups) |i| {
        const row = header_size + i * 24; const n = get32(bytes, row + 4); const end = get32(bytes, row + 16);
        if (get32(bytes, row) != first or n == 0 or get32(bytes, row + 12) != canonical or end < canonical or get32(bytes, row + 20) != 0) return error.InvalidBundle;
        if (get32(bytes, row + 8) != 64 + (n + 1) * 4 + end - canonical) return error.InvalidBundle;
        first += n; canonical = end; raw += get32(bytes, row + 8);
    }
    if (first != roots or canonical != get32(frame, 52) or canonical != std.mem.readInt(u64, bytes[40..48], .little) or raw != std.mem.readInt(u64, bytes[32..40], .little)) return error.InvalidBundle;
    return .{ .bytes = bytes, .groups = groups, .roots = roots };
}
pub const AdmissionError = Error || grammar.Error;
pub fn Verified(comptime Root: type) type {
    return struct {
        bundle: Bundle, page: grammar.Page(Root), prepared: grammar.Prepared(Root),
        pub fn deinit(self: @This()) void { self.page.deinit(); }
        pub fn headword(self: @This(), ordinal: usize) AdmissionError![]const u8 {
            return self.prepared.headword((try self.bundle.find(ordinal)).global);
        }
        pub fn decode(self: @This(), ordinal: usize) AdmissionError!lex.packet.Decoded(Root) {
            return self.page.decode((try self.bundle.find(ordinal)).global);
        }
    };
}
/// Owns decoded shared stock/model allocations; borrows immutable whole bundle.
/// Both the bundle bytes and this owner must outlive all returned byte views.
/// Preparation includes every native semantic/program check and canonical
/// root re-encoding of each original group boundary. The source hash records
/// provenance, not an independently fetched source or an authentication claim.
pub fn prepare(comptime Root: type, a: std.mem.Allocator, indexed: Bundle, limits: grammar.Limits) AdmissionError!Verified(Root) {
    const page = try grammar.open(Root, a, indexed.frame(), limits); errdefer page.deinit();
    const prepared = try page.prepare();
    var canonical: usize = 0;
    for (0..indexed.groups) |i| {
        const group = try indexed.group(i);
        if (group.canonical_start != canonical) return error.InvalidBundle;
        for (group.first..@as(usize, group.first) + group.roots) |root| {
            var decoded = try page.decode(root); defer decoded.deinit();
            const packet = try lex.packet.encode(a, decoded.value, limits.packet); defer a.free(packet);
            canonical = std.math.add(usize, canonical, packet.len) catch return error.BundleLimit;
            if (canonical > group.canonical_end) return error.InvalidBundle;
        }
        if (canonical != group.canonical_end) return error.InvalidBundle;
    }
    return .{ .bundle = indexed, .page = page, .prepared = prepared };
}
