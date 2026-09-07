//! Deterministic search-key derivation.
//!
//! The baseline profile deliberately promises less than full Unicode case
//! folding: it validates UTF-8, folds ASCII case, preserves every non-ASCII
//! scalar byte-for-byte, and reverses by scalar rather than by byte. A profile
//! ID and digest travel with derived key spaces so a richer language pack can
//! never be mistaken for this baseline.

const std = @import("std");

pub const profile: u16 = 1;
pub const profile_digest: u64 = std.hash.XxHash3.hash(0, "lex2:search:ascii-fold+unicode-scalar-reverse+word-v1");
pub const Error = error{ InvalidUtf8, OutOfMemory, Overflow };

pub fn normalize(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    const out = try allocator.dupe(u8, input);
    for (out) |*byte| byte.* = std.ascii.toLower(byte.*);
    return out;
}

pub fn reverseScalars(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    const out = try allocator.alloc(u8, input.len);
    var source_end = input.len;
    var target: usize = 0;
    while (source_end != 0) {
        var source_start = source_end - 1;
        while (source_start != 0 and input[source_start] & 0xc0 == 0x80) source_start -= 1;
        const scalar = input[source_start..source_end];
        @memcpy(out[target..][0..scalar.len], scalar);
        target += scalar.len;
        source_end = source_start;
    }
    return out;
}

pub const TermIterator = struct {
    text: []const u8,
    cursor: usize = 0,

    pub fn next(self: *TermIterator) ?[]const u8 {
        while (self.cursor < self.text.len and !termByte(self.text[self.cursor])) self.cursor += 1;
        if (self.cursor == self.text.len) return null;
        const start = self.cursor;
        while (self.cursor < self.text.len and termByte(self.text[self.cursor])) self.cursor += 1;
        return self.text[start..self.cursor];
    }
};

pub fn terms(input: []const u8) Error!TermIterator {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    return .{ .text = input };
}

fn termByte(byte: u8) bool {
    return byte >= 0x80 or std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '\'';
}

/// Stable, UTF-8-safe composite identity key. The fixed-width source prefix
/// prevents `(1,"23")` and `(12,"3")` from sharing a key.
pub fn externalId(allocator: std.mem.Allocator, source_ordinal: u32, local: []const u8) Error![]u8 {
    if (!std.unicode.utf8ValidateSlice(local)) return error.InvalidUtf8;
    return std.fmt.allocPrint(allocator, "{x:0>8}:{s}", .{ source_ordinal, local }) catch error.OutOfMemory;
}

test "derived keys preserve UTF-8 scalar boundaries" {
    const normalized = try normalize(std.testing.allocator, "BaNk-東京");
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("bank-東京", normalized);
    const reversed = try reverseScalars(std.testing.allocator, normalized);
    defer std.testing.allocator.free(reversed);
    try std.testing.expectEqualStrings("京東-knab", reversed);
}
