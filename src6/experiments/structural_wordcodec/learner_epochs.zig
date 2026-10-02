//! Preserve Lane M's decisions while discarding completed-round scratch.
const std = @import("std");
const lex = @import("lex");

pub fn copyState(alloc: std.mem.Allocator, source: *const lex.State) !lex.State {
    var out: lex.State = .{ .seq = try alloc.dupe(u32, source.seq), .block_end = try alloc.dupe(usize, source.block_end), .block_bytes = source.block_bytes };
    try out.lex.comp_off.appendSlice(alloc, source.lex.comp_off.items);
    try out.lex.comp_data.appendSlice(alloc, source.lex.comp_data.items);
    try out.lex.explen.appendSlice(alloc, source.lex.explen.items);
    return out;
}

/// The proposal/reparse/delete procedures are unchanged. Every round owns
/// a private copy, so rollback never touches freed or mutated state.
pub fn iterate(parent: std.mem.Allocator, io: std.Io, current_arena: *std.heap.ArenaAllocator, state: *lex.State, raw: []const u8, options: lex.Opts, log: *std.ArrayList(lex.IterLog)) !void {
    var previous_dl: f64 = std.math.inf(f64);
    var iteration: usize = 0;
    while (iteration < options.max_iters) : (iteration += 1) {
        var scratch: std.heap.ArenaAllocator = .init(parent);
        defer scratch.deinit();
        const alloc = scratch.allocator();
        var candidate = try copyState(alloc, state);
        const start = std.Io.Clock.awake.now(io).nanoseconds;
        const pairs = try lex.proposePairs(alloc, &candidate, options);
        const triples: usize = if (options.triples) try lex.proposeTriples(alloc, &candidate, options) else 0;
        const changed = try lex.reparseRound(alloc, &candidate, raw, options);
        const deleted = try lex.deletePass(alloc, &candidate, options);
        const duration = std.Io.Clock.awake.now(io).nanoseconds - start;
        const counts = try lex.recount(alloc, &candidate);
        const description_length = lex.dlEstimate(counts.n, counts.m, candidate.lex.numEntries());
        try log.append(parent, .{ .iter = iteration, .num_entries = candidate.lex.numEntries(), .tokens = candidate.seq.len, .dl_bytes = description_length / 8, .proposed_pairs = pairs, .proposed_triples = triples, .deleted = deleted, .ms = @as(f64, @floatFromInt(duration)) / 1e6 });
        if (description_length > previous_dl) break;

        var accepted: std.heap.ArenaAllocator = .init(parent);
        errdefer accepted.deinit();
        const copied = try copyState(accepted.allocator(), &candidate);
        current_arena.deinit();
        current_arena.* = accepted;
        state.* = copied;

        if (pairs == 0 and triples == 0 and deleted == 0 and !changed) break;
        if (iteration > 0 and (previous_dl - description_length) / previous_dl < options.converge_frac) break;
        previous_dl = description_length;
    }
}
