//! JOINT REFINEMENT: PLAN.md's round-3 pipeline puts Lane M's tokens under
//! Lane K's class model and then asks a genuinely new question neither
//! lane answered alone -- now that the class model already predicts much
//! of a token's neighbourhood, does every lexicon entry still pay for
//! itself?
//!
//! For every entry, recompute its benefit under the CLASS-CONDITIONAL code:
//! `uses * [cost of its spelling in context - cost of the entry in
//! context] - its model cost`. This package's "uses" splits cleanly into
//! two populations that are coded by two different mechanisms:
//!
//!   - corpus uses (the entry appears as a block token): coded by
//!     `block_coder.zig`'s class-conditional model. The "in context" cost
//!     of the entry-as-one-token vs. its spelling-as-several-tokens is
//!     `classes.withinClassCostBits`/`classes.transitionCostBits` --
//!     boundary transitions into/out of the entry are UNCHANGED by
//!     splicing whenever the entry's target/context class equals its
//!     first/last child's (true whenever there is no override), so this
//!     reduces to the *internal* difference: one within-class pick for the
//!     whole entry vs. one within-class pick per child plus one
//!     class-transition per internal join.
//!   - spelling-internal uses (the entry is itself a component of another
//!     entry): still coded by `model_codec.zig`'s order-0 unigram table,
//!     unaffected by classes at all -- `delete.order0Benefit` (Lane M's
//!     original formula, LANE_M.md) applied to the spelling-only
//!     population is exactly this domain's benefit, model cost included.
//!
//! `its model cost` (the entry's own arity+side-info storage) is counted
//! exactly once, inside `order0Benefit`; the class-domain term above is a
//! pure correction on top of that.
//!
//! Policy per round: rank entries by combined estimated benefit, delete
//! every entry with positive benefit in one batch (Lane M's per-candidate
//! score is itself a heuristic -- see `m_lexicon.zig`'s own history of
//! "propose is a heuristic batch accept, not self-validating"), re-parse
//! (Lane M's ordinary order-0 DP, unchanged -- classes only ever affect
//! *coding*, never *parsing*, matching PLAN's pipeline literally), re-fit
//! classes, and do ONE real end-to-end re-encode. If that real total is
//! smaller than the best real total seen so far, keep it and continue; if
//! not, revert to the pre-round state and stop -- a simpler, still-honest
//! cousin of `delete.deletePass`'s per-round halving search (that one
//! reruns a cheap *exact* recount per trial; a class-conditional exact
//! recount would need a full re-fit per trial, so this stage's inner gate
//! is the CHEAP independent-estimate ranking and the round-level gate is
//! the one real, unfakeable measurement -- see LANE_Z1.md for the
//! trade-off, stated plainly). Never regresses versus order-0 M alone or
//! versus classes-with-no-refinement: both are computed up front and are
//! always eligible to win.

const std = @import("std");
const lexicon = @import("lexicon.zig");
const topology = @import("topology.zig");
const classes = @import("classes.zig");
const model_codec = @import("model_codec.zig");
const parse = @import("parse.zig");
const delete = @import("delete.zig");
const frame = @import("frame.zig");
const Corpus = lexicon.Corpus;

pub const Stage = enum { order0, classes_only, joint_refined };

pub const RoundLog = struct { round: usize, deleted: usize, total_bytes: usize, accepted: bool };

pub const Result = struct {
    final: frame.Assembled,
    stage: Stage,
    order0_bytes: usize,
    classes_bytes: usize,
    rounds: []RoundLog, // every attempted round, whether accepted or not (the last, if any, is rejected)
};

fn f(x: anytype) f64 {
    return @floatFromInt(x);
}

const Fit = struct {
    em: model_codec.EncodedModel,
    remapped: Corpus,
    remapped_g: []u64,
    built: classes.BuiltModel,
};

fn fitFor(alloc: std.mem.Allocator, work: *const Corpus, class_params: classes.Params) !Fit {
    const g = try lexicon.recountRootsOnly(alloc, work);
    const em = try model_codec.encode(alloc, &work.lex, g, model_codec.default_variant, null);
    const k = 256 + em.renumbered.numEntries();

    const remapped_g = try alloc.alloc(u64, k);
    for (g, 0..) |v, old| remapped_g[em.id_map[old].raw()] = v;
    const remapped_seq = try alloc.alloc(u32, work.seq.len);
    for (work.seq, 0..) |t, i| remapped_seq[i] = em.id_map[t].raw();
    const remapped: Corpus = .{ .lex = em.renumbered, .seq = remapped_seq, .block_end = work.block_end, .block_bytes = work.block_bytes };

    const order = try topology.topoOrder(alloc, &remapped.lex);
    const info = try topology.buildSymInfo(alloc, &remapped.lex, order);
    const built = try classes.learnAndBuild(alloc, &remapped, order, info, remapped_g, class_params);

    return .{ .em = em, .remapped = remapped, .remapped_g = remapped_g, .built = built };
}

fn classTotals(alloc: std.mem.Allocator, C: u32, resolved_b: []const u32, g: []const u64) ![]u64 {
    const G = try alloc.alloc(u64, C);
    @memset(G, 0);
    for (resolved_b, 0..) |c, s| G[c] += g[s];
    return G;
}

const DelCand = struct { idx: u32, benefit: f64 };
fn desc(_: void, x: DelCand, y: DelCand) bool {
    return x.benefit > y.benefit;
}

/// Rank every entry of `work` by its estimated combined benefit under
/// `fit`'s just-learned class model, and return the ones worth deleting
/// (positive estimated benefit), most-beneficial first.
fn rankCandidates(alloc: std.mem.Allocator, work: *const Corpus, fit: *const Fit, calib: lexicon.Calib) ![]DelCand {
    const spelling_counts = try lexicon.recountSpellingOnly(alloc, &work.lex);
    const G = try classTotals(alloc, fit.built.model.C, fit.built.model.resolved_b, fit.remapped_g);
    const T = fit.built.model.T;
    const C = fit.built.model.C;

    var cands: std.ArrayList(DelCand) = .empty;
    for (0..work.lex.numEntries()) |i| {
        const spelling_u = spelling_counts.n[256 + i];
        const benefit_b = try delete.order0Benefit(alloc, work.lex.comps(i), spelling_counts.n, spelling_counts.m, spelling_u, calib);

        const fid = fit.em.id_map[256 + i].raw();
        const g_e = fit.remapped_g[fid];
        var benefit_a: f64 = 0;
        if (g_e > 0) {
            const rank = fid - 256;
            const kids = fit.remapped.lex.comps(rank);
            const bE = fit.built.model.resolved_b[fid];
            var cost_spelling: f64 = 0;
            for (kids, 0..) |c, ci| {
                cost_spelling += classes.withinClassCostBits(fit.remapped_g[c], G[fit.built.model.resolved_b[c]]);
                if (ci + 1 < kids.len) {
                    cost_spelling += classes.transitionCostBits(T, C, fit.built.model.resolved_a[c], fit.built.model.resolved_b[kids[ci + 1]]);
                }
            }
            const cost_entry = classes.withinClassCostBits(g_e, G[bE]);
            benefit_a = f(g_e) * (cost_entry - cost_spelling);
        }

        const total = benefit_a + benefit_b;
        if (total > 0) try cands.append(alloc, .{ .idx = @intCast(i), .benefit = total });
    }
    std.mem.sort(DelCand, cands.items, {}, desc);
    return cands.toOwnedSlice(alloc);
}

/// Run the full round-3 pipeline for one (already lexicon-converged)
/// `corpus`: order-0 M, classes with no refinement, and up to
/// `max_rounds` of joint refinement -- and keep whichever real frame is
/// smallest. `alloc` should be an arena; see `frame.assemble`'s doc
/// comment.
pub fn run(alloc: std.mem.Allocator, raw: []const u8, corpus: *const Corpus, class_params: classes.Params, max_rounds: usize, calib: lexicon.Calib) !Result {
    const stage_a = try frame.assemble(alloc, raw, corpus, .{ .C = 1 });
    const stage_b = try frame.assemble(alloc, raw, corpus, class_params);

    var best = stage_a;
    var stage: Stage = .order0;
    if (stage_b.bytes.len < best.bytes.len) {
        best = stage_b;
        stage = .classes_only;
    }

    var rounds: std.ArrayList(RoundLog) = .empty;
    var work: Corpus = corpus.*;
    var round: usize = 0;
    while (round < max_rounds) : (round += 1) {
        const snapshot = work;
        const fit = try fitFor(alloc, &work, class_params);
        const cands = try rankCandidates(alloc, &work, &fit, calib);
        if (cands.len == 0) break;

        const marked = try alloc.alloc(bool, work.lex.numEntries());
        @memset(marked, false);
        for (cands) |c| marked[c.idx] = true;

        try delete.spliceMarked(alloc, &work, marked);
        _ = try parse.reparseRound(alloc, &work, raw, .{});
        const trial = try frame.assemble(alloc, raw, &work, class_params);

        const accepted = trial.bytes.len < best.bytes.len;
        try rounds.append(alloc, .{ .round = round, .deleted = cands.len, .total_bytes = trial.bytes.len, .accepted = accepted });
        if (accepted) {
            best = trial;
            stage = .joint_refined;
        } else {
            work = snapshot;
            break;
        }
    }

    return .{
        .final = best,
        .stage = stage,
        .order0_bytes = stage_a.bytes.len,
        .classes_bytes = stage_b.bytes.len,
        .rounds = try rounds.toOwnedSlice(alloc),
    };
}

const learn = @import("learn.zig");

test "joint refinement never regresses versus either fallback stage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const raw = "the cat sat on the mat. the dog sat on the log. the cat ran and the dog ran, and the cat sat again. " ** 25;
    var corpus = try lexicon.seedBytes(a, raw, 4096);
    var log: std.ArrayList(learn.IterLog) = .empty;
    try learn.iterate(a, &corpus, raw, .{ .max_iters = 10 }, &log);

    const result = try run(a, raw, &corpus, .{ .C = 16, .g_min = 2 }, 3, .{});
    try std.testing.expect(result.final.bytes.len <= result.order0_bytes);
    try std.testing.expect(result.final.bytes.len <= result.classes_bytes);

    var frame_ = try frame.open(a, result.final.bytes);
    defer frame_.deinit();
    const out = try a.alloc(u8, raw.len);
    try frame_.decodeAll(out);
    try std.testing.expectEqualSlices(u8, raw, out);
}
