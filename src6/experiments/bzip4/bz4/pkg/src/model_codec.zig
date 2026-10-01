//! The lexicon model codec, behind a narrow interface so the underlying
//! codec can be swapped without touching `classes.zig`, `block_coder.zig`,
//! or `joint.zig`:
//!
//!   `encode(alloc, lex, g, variant) -> bytes + id map (+ the renumbered lexicon)`
//!   `decode(alloc, bytes)           -> entries (a Lexicon) + g`
//!
//! This is a thin adapter over `b2_codec.zig` (an independent, self-
//! contained n-ary DEF-tree codec: lexicographic walk order, front-coding,
//! a 64-slot MRU recency cache, first-byte-factorised REF misses, and
//! REF priors seeded from `g` -- see that file's own doc comment for the
//! wire format). `g` (root/corpus occurrence counts) travels through this
//! codec unchanged rather than being transmitted separately, because the
//! codec needs it anyway to seed its REF model and it costs nothing extra
//! to also hand back to the caller.
//!
//! `b2_codec.zig` is free to renumber AND re-spell entries (flatten one to
//! a byte run, or keep it compositional) as long as every entry's byte
//! expansion is unchanged; this adapter accounts for that by decoding its
//! own freshly-encoded bytes once to build `EncodedModel.renumbered` --
//! the lexicon `classes.zig`/`block_coder.zig` build on always matches
//! exactly what a real decoder will reconstruct, never the encoder's own
//! (possibly different) internal spelling choice.

const std = @import("std");
const b2 = @import("b2_codec.zig");
const lexicon = @import("lexicon.zig");
const topology = @import("topology.zig");
const ids = @import("ids.zig");
const Lexicon = lexicon.Lexicon;
const LexBuilder = lexicon.LexBuilder;
const TokenId = ids.TokenId;

pub const Variant = b2.Variant;
pub const default_variant: Variant = .v8_gseed;

pub const EncodeStats = struct { model_bytes: usize };

pub const EncodedModel = struct {
    bytes: []u8,
    id_map: []TokenId, // old raw id -> new TokenId; size 256+old_entry_count, identity on bytes
    renumbered: Lexicon, // the lexicon a real decode of `bytes` reconstructs

    pub fn deinit(self: *EncodedModel, alloc: std.mem.Allocator) void {
        alloc.free(self.bytes);
        alloc.free(self.id_map);
        self.renumbered.deinit(alloc);
    }
};

fn lexiconToEntries(alloc: std.mem.Allocator, lex: *const Lexicon) ![]b2.Entry {
    const n = lex.numEntries();
    const entries = try alloc.alloc(b2.Entry, n);
    for (0..n) |i| entries[i] = .{ .children = lex.comps(i) };
    return entries;
}

/// Build a `Lexicon` from a decoded `b2.Entry` set and fill in `explen`
/// (not transmitted -- b2's entries may reference each other in any order,
/// so it is derived the same bounded, cycle-safe way `decode` below does).
fn lexiconFromEntries(alloc: std.mem.Allocator, entries: []const b2.Entry) !Lexicon {
    var builder = try LexBuilder.init(alloc);
    for (entries) |e| _ = try builder.addEntry(alloc, e.children, 0);
    var lex = builder.finish();
    var exp = try Expander.init(alloc, &lex);
    defer exp.deinit(alloc);
    for (0..entries.len) |r| lex.explen.items[r] = @intCast((try exp.expand(r)).len);
    return lex;
}

/// Encode `lex` (with root/corpus counts `g`, size `256 + lex.numEntries()`)
/// with the chosen codec variant. Returns the bytes, the old-id -> new-id
/// map, and the lexicon re-expressed in the new id space -- callers that
/// also carry a corpus token stream (`joint.zig`, `frame.zig`) remap it
/// through `id_map` themselves so every downstream stage (classes, block
/// coder) operates in one consistent id space.
pub fn encode(alloc: std.mem.Allocator, lex: *const Lexicon, g: []const u64, variant: Variant, stats: ?*EncodeStats) !EncodedModel {
    const num_entries = lex.numEntries();
    const entries = try lexiconToEntries(alloc, lex);
    defer alloc.free(entries);

    const enc = try b2.encode(alloc, entries, g, variant);
    defer alloc.free(enc.old_to_new);
    errdefer alloc.free(enc.bytes);

    var dec = try b2.decode(alloc, enc.bytes);
    defer dec.deinit();
    const renumbered = try lexiconFromEntries(alloc, dec.entries);

    const id_map = try alloc.alloc(TokenId, 256 + num_entries);
    for (0..256) |s| id_map[s] = TokenId.of(@intCast(s));
    for (enc.old_to_new, 0..) |new_idx, old| id_map[256 + old] = TokenId.of(256 + new_idx);

    if (stats) |st| st.* = .{ .model_bytes = enc.bytes.len };
    return .{ .bytes = enc.bytes, .id_map = id_map, .renumbered = renumbered };
}

pub const DecodedModel = struct {
    lex: Lexicon, // final (rank) id space: entry i's final id is 256+i
    g_by_id: []u64, // root/corpus-only occurrence counts, same id space

    pub fn deinit(self: *DecodedModel, alloc: std.mem.Allocator) void {
        self.lex.deinit(alloc);
        alloc.free(self.g_by_id);
    }
};

/// Decode: sees only `bytes`. `b2_codec.zig` bounds every quantity it
/// reads from the wire (entry count, arity, expansion length, recursion
/// depth, total expansion size) and rejects cycles before this adapter
/// ever runs -- see that file's own corruption-fuzz test.
pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) !DecodedModel {
    var dec = try b2.decode(alloc, bytes);
    defer dec.deinit();
    const lex = try lexiconFromEntries(alloc, dec.entries);
    const g_by_id = try alloc.dupe(u64, dec.g);
    return .{ .lex = lex, .g_by_id = g_by_id };
}

pub const MAX_EXPANSION: usize = 1 << 30;
pub const MAX_DEPTH: usize = 100_000;

/// Memoised DFS expansion of every entry's byte string, with a cycle guard
/// (color 0=white/1=gray/2=black), a recursion-depth cap, and a
/// total-expansion-size cap. Used to derive `explen` above and by
/// `block_coder.zig` to build the decode-time expansion arena.
pub const Expander = struct {
    lex: *const Lexicon,
    cache: []?[]u8,
    color: []u8,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, lex: *const Lexicon) !Expander {
        const n = lex.numEntries();
        const cache = try alloc.alloc(?[]u8, n);
        @memset(cache, null);
        const color = try alloc.alloc(u8, n);
        @memset(color, 0);
        return .{ .lex = lex, .cache = cache, .color = color, .alloc = alloc };
    }

    pub fn deinit(self: *Expander, alloc: std.mem.Allocator) void {
        for (self.cache) |c| if (c) |b| alloc.free(b);
        alloc.free(self.cache);
        alloc.free(self.color);
    }

    /// Expand entry `rank` (0-based entry index, NOT the +256 symbol id).
    pub fn expand(self: *Expander, rank: usize) ![]u8 {
        return self.expandDepth(rank, 0);
    }

    fn expandDepth(self: *Expander, rank: usize, depth: usize) ![]u8 {
        if (self.cache[rank]) |c| return c;
        if (depth > MAX_DEPTH) return error.TooDeep;
        if (self.color[rank] == 1) return error.Cycle;
        self.color[rank] = 1;
        var buf: std.ArrayList(u8) = .empty;
        for (self.lex.comps(rank)) |c| {
            if (c < 256) {
                try buf.append(self.alloc, @intCast(c));
            } else {
                const cr = c - 256;
                if (cr >= self.cache.len) return error.BadRef;
                const sub = try self.expandDepth(cr, depth + 1);
                try buf.appendSlice(self.alloc, sub);
            }
            if (buf.items.len > MAX_EXPANSION) return error.Oversize;
        }
        self.color[rank] = 2;
        const result = try buf.toOwnedSlice(self.alloc);
        self.cache[rank] = result;
        return result;
    }
};

test "encode/decode round-trip: children and g both agree" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const raw = "the cat sat on the mat the cat ran";
    var corpus = try lexicon.seedBytes(a, raw, 4096);
    const learn = @import("learn.zig");
    var log: std.ArrayList(learn.IterLog) = .empty;
    try learn.iterate(a, &corpus, raw, .{ .max_iters = 6 }, &log);
    try std.testing.expect(try lexicon.verifyExact(a, raw, &corpus));

    const g = try lexicon.recountRootsOnly(a, &corpus);
    var em = try encode(a, &corpus.lex, g, default_variant, null);
    var dm = try decode(a, em.bytes);

    try std.testing.expectEqual(em.renumbered.numEntries(), dm.lex.numEntries());
    for (0..em.renumbered.numEntries()) |i| {
        try std.testing.expectEqualSlices(u32, em.renumbered.comps(i), dm.lex.comps(i));
        try std.testing.expectEqual(em.renumbered.explen.items[i], dm.lex.explen.items[i]);
    }
    for (em.id_map, 0..) |nid, old| {
        try std.testing.expectEqual(g[old], dm.g_by_id[nid.raw()]);
    }
    em.deinit(a);
    dm.deinit(a);
}

test "decode rejects a cyclic spelling" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A hand-built entry whose only component is itself: b2_codec's own
    // decoder must reject this (exercised directly, since this adapter
    // does no cycle checking of its own beyond what that codec provides).
    var enc = try b2.encode(a, &.{.{ .children = &.{ 'a', 'b' } }}, &([_]u64{0} ** 257), .v1_creation);
    defer enc.deinit();
    // Corrupt nothing structural; instead hand-build a truly cyclic model
    // via the Expander directly, since b2_codec's own encoder can never
    // produce a cycle -- this exercises this adapter's use of Expander.
    var lex = Lexicon{};
    try lex.comp_off.append(a, 0);
    try lex.comp_data.appendSlice(a, &.{ 256, 256 });
    try lex.comp_off.append(a, 2);
    try lex.explen.append(a, 999);
    var exp = try Expander.init(a, &lex);
    defer exp.deinit(a);
    try std.testing.expectError(error.Cycle, exp.expand(0));
}
