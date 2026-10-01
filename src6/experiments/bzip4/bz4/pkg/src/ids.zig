//! Distinct id types so the different numbering spaces this codec juggles
//! can never be silently mixed up at a function boundary.
//!
//! Lane V's own notebook (LANE_V.md, "the one non-obvious integration bug:
//! two id spaces") found a real defect from exactly this: a grammar
//! builder's symbol numbering and the model codec's post-order renumbering
//! looked identical (both `u32`) and every small test passed by luck until
//! real multi-thousand-symbol data exposed the mismatch. `TokenId` marks
//! "a symbol id in whatever numbering the current `Lexicon` uses" so the
//! type checker catches a stray raw index the way Lane V's tests didn't.
//!
//! Internally, the lexicon-learning engine (`lexicon.zig`, `propose.zig`,
//! `parse.zig`, `delete.zig`) still works over plain `u32` hot-loop indices
//! -- that machinery is one continuously-renumbered space throughout a
//! single pass and wrapping every temporary would only add ceremony. The
//! typed wrappers are used at the boundaries between *different* spaces:
//! the model codec's old-id -> new-id remap, the class model's resolved
//! classes, and the block coder's token stream -- precisely the seams
//! where Lane V's bug lived.

const std = @import("std");

/// A symbol id in a `Lexicon`'s numbering: values 0..255 are literal byte
/// values, 256+ index an entry (`EntryId = TokenId - 256`).
pub const TokenId = enum(u32) {
    _,

    pub inline fn of(v: u32) TokenId {
        return @enumFromInt(v);
    }
    pub inline fn raw(self: TokenId) u32 {
        return @intFromEnum(self);
    }
    pub inline fn isByte(self: TokenId) bool {
        return self.raw() < 256;
    }
    pub inline fn byteValue(self: TokenId) u8 {
        std.debug.assert(self.isByte());
        return @intCast(self.raw());
    }
    pub inline fn entry(self: TokenId) EntryId {
        std.debug.assert(!self.isByte());
        return @enumFromInt(self.raw() - 256);
    }
};

/// A 0-based index into a `Lexicon`'s entry arrays (`comp_off`/`explen`/...).
pub const EntryId = enum(u32) {
    _,

    pub inline fn of(v: u32) EntryId {
        return @enumFromInt(v);
    }
    pub inline fn raw(self: EntryId) u32 {
        return @intFromEnum(self);
    }
    pub inline fn token(self: EntryId) TokenId {
        return @enumFromInt(self.raw() + 256);
    }
};

/// An induced "part-of-speech" class id, 0..C-1 (`classes.Params.C` classes
/// plus one reserved START row/column for the block-start context).
pub const ClassId = enum(u32) {
    _,

    pub inline fn of(v: u32) ClassId {
        return @enumFromInt(v);
    }
    pub inline fn raw(self: ClassId) u32 {
        return @intFromEnum(self);
    }
};

test "TokenId/EntryId round trip" {
    const t = TokenId.of(300);
    try std.testing.expect(!t.isByte());
    try std.testing.expectEqual(@as(u32, 44), t.entry().raw());
    try std.testing.expectEqual(t, t.entry().token());

    const b = TokenId.of(65);
    try std.testing.expect(b.isByte());
    try std.testing.expectEqual(@as(u8, 65), b.byteValue());
}
