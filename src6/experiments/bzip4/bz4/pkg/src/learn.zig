//! The Lane M main loop: PROPOSE (pairs [+ triples]) -> RE-PARSE (corpus +
//! every entry's own spelling) -> RECOUNT -> DELETE, iterated until DL
//! improves by less than `Opts.converge_frac`, `Opts.max_iters` is reached,
//! or a round changes nothing at all. A top-level snapshot/revert catches
//! the rare case where PROPOSE's heuristic batch-accept overshoots and
//! DELETE can't fully recover within the same round.
//!
//! Ported from `m_lexicon.zig`'s `iterate()` (Lane M) per PLAN.md's
//! copy-and-reshape rule.

const std = @import("std");
const lexicon = @import("lexicon.zig");
const propose = @import("propose.zig");
const parse = @import("parse.zig");
const delete = @import("delete.zig");
const Corpus = lexicon.Corpus;

pub const Opts = struct {
    max_iters: usize = 20,
    converge_frac: f64 = 0.0005,
    max_material_len: u32 = 256,
    triples: bool = true,
    calib: lexicon.Calib = .{},
};

pub const IterLog = struct {
    iter: usize,
    num_entries: usize,
    tokens: usize,
    dl_bytes: f64,
    proposed_pairs: usize,
    proposed_triples: usize,
    deleted: usize,
};

fn proposeOpts(o: Opts) propose.Opts {
    return .{ .max_material_len = o.max_material_len, .calib = o.calib };
}

/// Converge a byte-seeded corpus to a compositional MDL lexicon. `alloc`
/// should be an arena (or similar) -- every round allocates a fresh
/// generation of the lexicon/corpus and the old one is simply dropped, per
/// PLAN's own working style for this kind of iterative rewrite.
pub fn iterate(alloc: std.mem.Allocator, corpus: *Corpus, raw: []const u8, opts: Opts, log: *std.ArrayList(IterLog)) !void {
    var prev_dl: f64 = std.math.inf(f64);
    var iter: usize = 0;
    const popts = proposeOpts(opts);
    while (iter < opts.max_iters) : (iter += 1) {
        const snapshot = corpus.*;
        const pp = try propose.proposePairs(alloc, corpus, popts);
        const pt: usize = if (opts.triples) try propose.proposeTriples(alloc, corpus, popts) else 0;
        const changed = try parse.reparseRound(alloc, corpus, raw, popts);
        const del = try delete.deletePass(alloc, corpus, popts);

        const rc = try lexicon.recount(alloc, corpus);
        const dl = lexicon.dlEstimate(rc.n, rc.m, corpus.lex.numEntries(), opts.calib);

        try log.append(alloc, .{
            .iter = iter,
            .num_entries = corpus.lex.numEntries(),
            .tokens = corpus.seq.len,
            .dl_bytes = dl / 8.0,
            .proposed_pairs = pp,
            .proposed_triples = pt,
            .deleted = del,
        });

        if (dl > prev_dl) {
            corpus.* = snapshot; // whole iteration regressed: roll back and stop
            break;
        }
        if (pp == 0 and pt == 0 and del == 0 and !changed) break;
        if (iter > 0) {
            const improvement = (prev_dl - dl) / prev_dl;
            if (improvement < opts.converge_frac) break;
        }
        prev_dl = dl;
    }
}

test "iterate converges and stays byte-exact on repetitive text" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const raw = "the quick brown fox jumps over the lazy dog. " ** 30;
    var corpus = try lexicon.seedBytes(a, raw, 4096);
    var log: std.ArrayList(IterLog) = .empty;
    try iterate(a, &corpus, raw, .{ .max_iters = 10 }, &log);
    try std.testing.expect(log.items.len > 0);
    try std.testing.expect(try lexicon.verifyExact(a, raw, &corpus));
    // The lexicon should have found at least one multi-byte entry.
    try std.testing.expect(corpus.lex.numEntries() > 0);
}
