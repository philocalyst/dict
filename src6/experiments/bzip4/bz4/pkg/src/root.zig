//! bz4 v2 ("words + syntax"): public API.
//!
//! Pipeline: raw bytes are turned into a token lexicon two different ways
//! -- a compositional MDL lexicon (`learn.iterate`, word-like entries) and
//! a binary phrase grammar (`deepgrammar.build`, Re-Pair-style) -- an
//! induced class-transition model is learned over each candidate's tokens
//! (`classes.zig`, DAG-inherited so it costs almost nothing to store), and
//! a joint-refinement pass (`joint.zig`) recomputes every lexicon entry's
//! benefit under that class-conditional code and deletes what stops
//! paying. Whichever real, byte-exact frame comes out smallest -- either
//! lexicon, with or without classes, with or without refinement -- wins;
//! `compress` never has to guess which will do best on a given input, it
//! measures.
//!
//! Everything the decoder needs travels in the frame; `Frame.open` and
//! `Frame.decodeBlock`/`decodeAll` are the entire decode-side surface.

const std = @import("std");

pub const ids = @import("ids.zig");
pub const range_coder = @import("range_coder.zig");
pub const coding = @import("coding.zig");
pub const lexicon = @import("lexicon.zig");
pub const propose = @import("propose.zig");
pub const parse = @import("parse.zig");
pub const delete = @import("delete.zig");
pub const learn = @import("learn.zig");
pub const deepgrammar = @import("deepgrammar.zig");
pub const topology = @import("topology.zig");
pub const classes = @import("classes.zig");
pub const b2_codec = @import("b2_codec.zig");
pub const model_codec = @import("model_codec.zig");
pub const class_codec = @import("class_codec.zig");
pub const block_coder = @import("block_coder.zig");
pub const frame = @import("frame.zig");
pub const joint = @import("joint.zig");

pub const TokenId = ids.TokenId;
pub const EntryId = ids.EntryId;
pub const ClassId = ids.ClassId;
pub const Corpus = lexicon.Corpus;
pub const Frame = frame.Frame;

/// Which of the two candidate lexicon sources a compressed frame ended up
/// using -- reported for measurement, not part of the wire format (the
/// decoder never needs to know: a binary rule and a word-like entry are
/// both just `Lexicon` entries).
pub const LexiconKind = enum { word, deep };

pub const CompressOpts = struct {
    block_bytes: usize = 65536,
    learn: learn.Opts = .{},
    /// The class model's general setting: C=128, one learned class per
    /// symbol serving both roles, DAG inheritance always on, g_min=4,
    /// candidate cap 6000, 8 EM sweeps -- one fixed setting for every file.
    class_params: classes.Params = .{},
    joint_rounds: usize = 3,
    /// Rounds of order-0 MDL pruning applied to the deep-grammar candidate
    /// (calibrated the same way as the word lexicon) before it enters the
    /// class+joint-refinement tournament.
    deep_prune_rounds: usize = 8,
};

pub const CompressResult = struct {
    bytes: []u8,
    stage: joint.Stage,
    lexicon_kind: LexiconKind,
    order0_bytes: usize,
    classes_bytes: usize,
    rounds: []const joint.RoundLog,
    entries: usize,
    tokens: usize,
    /// The real, measured per-entry model cost the word lexicon's search
    /// was calibrated against (see `compress`'s doc comment) -- reported
    /// so a caller can see what the closed loop actually converged on.
    calib_entry_bits: f64,
};

/// Prune `corpus` with plain order-0 MDL deletion (`delete.deletePass`)
/// under `calib` until a round deletes nothing or `max_rounds` is reached.
fn pruneWithCalib(alloc: std.mem.Allocator, corpus: *Corpus, calib: lexicon.Calib, max_rounds: usize) !void {
    var round: usize = 0;
    while (round < max_rounds) : (round += 1) {
        const deleted = try delete.deletePass(alloc, corpus, .{ .calib = calib });
        if (deleted == 0) break;
    }
}

/// Compress `raw` end to end. Two candidate lexicons are built -- a
/// compositional MDL lexicon and a binary phrase grammar -- and the
/// model-cost heuristic both use to decide what's worth keeping is
/// *closed-loop calibrated*: after the word lexicon first converges under
/// a generic starting cost, one real encode measures what the actual model
/// codec charges per entry on this file, and that real number (not a
/// hand-picked constant) becomes the price both candidates are pruned
/// against from then on. Each candidate then runs the same order-0 /
/// classes / joint-refinement tournament (`joint.run`), and the smallest
/// real frame from either candidate wins -- `compress` never regresses
/// against a simpler stage of either lexicon, by construction.
///
/// Allocates freely (`frame.assemble`'s doc comment); callers doing more
/// than one compression in a process should use a fresh arena per call.
pub fn compress(alloc: std.mem.Allocator, raw: []const u8, opts: CompressOpts) !CompressResult {
    var word_corpus = try lexicon.seedBytes(alloc, raw, opts.block_bytes);
    var log1: std.ArrayList(learn.IterLog) = .empty;
    try learn.iterate(alloc, &word_corpus, raw, opts.learn, &log1);
    if (!try lexicon.verifyExact(alloc, raw, &word_corpus)) return error.LexiconNotExact;

    var calib = opts.learn.calib;
    if (word_corpus.lex.numEntries() > 0) {
        const g0 = try lexicon.recountRootsOnly(alloc, &word_corpus);
        var stats0: model_codec.EncodeStats = undefined;
        var em0 = try model_codec.encode(alloc, &word_corpus.lex, g0, model_codec.default_variant, &stats0);
        em0.deinit(alloc);
        const real_bits_per_entry = @as(f64, @floatFromInt(stats0.model_bytes * 8)) /
            @as(f64, @floatFromInt(word_corpus.lex.numEntries()));
        calib.entry_bits = std.math.clamp(real_bits_per_entry, 4.0, 200.0);

        // Close the loop: let the learner clean up further under the real
        // price (typically a handful of additional propose/delete rounds
        // that converge quickly, since most restructuring already
        // happened under the generic starting price).
        var learn_opts2 = opts.learn;
        learn_opts2.calib = calib;
        var log2: std.ArrayList(learn.IterLog) = .empty;
        try learn.iterate(alloc, &word_corpus, raw, learn_opts2, &log2);
        if (!try lexicon.verifyExact(alloc, raw, &word_corpus)) return error.LexiconNotExact;
    }

    const word_result = try joint.run(alloc, raw, &word_corpus, opts.class_params, opts.joint_rounds, calib);

    var gm = try deepgrammar.build(alloc, raw, opts.block_bytes, .{ .priority = .saving, .fast_count = true });
    var deep_corpus = try deepgrammar.toCorpus(alloc, &gm);
    try pruneWithCalib(alloc, &deep_corpus, calib, opts.deep_prune_rounds);
    if (!try lexicon.verifyExact(alloc, raw, &deep_corpus)) return error.LexiconNotExact;
    const deep_result = try joint.run(alloc, raw, &deep_corpus, opts.class_params, opts.joint_rounds, calib);

    const deep_wins = deep_result.final.bytes.len < word_result.final.bytes.len;
    const winner = if (deep_wins) deep_result else word_result;
    return .{
        .bytes = winner.final.bytes,
        .stage = winner.stage,
        .lexicon_kind = if (deep_wins) .deep else .word,
        .order0_bytes = winner.order0_bytes,
        .classes_bytes = winner.classes_bytes,
        .rounds = winner.rounds,
        .entries = winner.final.stats.entries,
        .tokens = winner.final.stats.tokens,
        .calib_entry_bits = calib.entry_bits,
    };
}

/// `frame.open` re-exported at the top level: `Frame.open(alloc, bytes)`.
pub const open = frame.open;

test "compress/decompress round trip end to end" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const raw = "the quick brown fox jumps over the lazy dog. " ** 50;

    const result = try compress(a, raw, .{ .block_bytes = 4096, .class_params = .{ .C = 16, .g_min = 2 } });
    var f = try open(a, result.bytes);
    defer f.deinit();
    const out = try a.alloc(u8, raw.len);
    try f.decodeAll(out);
    try std.testing.expectEqualSlices(u8, raw, out);
}

test "compress picks a real lexicon_kind and never regresses either fallback" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const raw = "abababababab xyxyxyxyxyxy abab" ** 30;

    const result = try compress(a, raw, .{ .block_bytes = 4096, .class_params = .{ .C = 8, .g_min = 2 } });
    try std.testing.expect(result.bytes.len <= result.order0_bytes);
    try std.testing.expect(result.bytes.len <= result.classes_bytes);
}

test {
    std.testing.refAllDecls(@This());
}
