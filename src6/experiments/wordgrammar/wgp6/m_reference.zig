//! Faithful LaneA-best -> LaneM -> unchanged native-v4 reference.
//! Original learner symbol IDs and forward acyclic references are retained.
const std = @import("std");
const lex = @import("lex");
const gram = @import("gram");
const bz4 = @import("bz4");
const Budget = @import("budget.zig").Budget;
const epochs = @import("learner_epochs.zig");
const fitting = @import("lifetime_fit.zig");
fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}
const Ledger = struct {
    header_bytes: usize,
    directory_bytes: usize,
    model_dictionary_bytes: usize,
    payload_bytes: usize,
    raw_bytes: usize,
    blocks: usize,
    block_raw_lengths: std.ArrayList(usize),
};

fn ledger(gpa: std.mem.Allocator, bytes: []const u8) !Ledger {
    if (!std.mem.startsWith(u8, bytes, bz4.frame.magic)) return error.BadFrame;
    var pos = bz4.frame.magic.len;
    const header_len = try bz4.frame.takeVarint(bytes, &pos);
    if (header_len > bytes.len - pos) return error.BadFrame;
    const header_bytes = pos;
    pos += header_len;
    var model_dictionary_bytes: usize = header_len;
    var payload_bytes: usize = 0;
    var raw_bytes: usize = 0;
    var blocks: usize = 0;
    var lengths: std.ArrayList(usize) = .empty;
    errdefer lengths.deinit(gpa);
    while (try bz4.frame.Block.read(bytes, &pos)) |b| {
        model_dictionary_bytes += b.delta.len;
        payload_bytes += b.payload.len;
        raw_bytes += b.raw_len;
        if (b.items != 0) {
            blocks += 1;
            try lengths.append(gpa, b.raw_len);
        }
    }
    if (pos != bytes.len) return error.BadFrame;
    return .{ .header_bytes = header_bytes, .directory_bytes = bytes.len - header_bytes - model_dictionary_bytes - payload_bytes, .model_dictionary_bytes = model_dictionary_bytes, .payload_bytes = payload_bytes, .raw_bytes = raw_bytes, .blocks = blocks, .block_raw_lengths = lengths };
}

fn writeLedger(init: std.process.Init, stats: Ledger, codec_ns: i96, frame_bytes: usize, classes: ?u16) !void {
    try json(init, .{ .codec_ns = codec_ns, .frame_bytes = frame_bytes, .classes = classes, .header_bytes = stats.header_bytes, .directory_bytes = stats.directory_bytes, .model_dictionary_bytes = stats.model_dictionary_bytes, .payload_bytes = stats.payload_bytes, .raw_bytes = stats.raw_bytes, .blocks = stats.blocks, .block_raw_lengths = stats.block_raw_lengths.items });
}

fn json(init: std.process.Init, value: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.print("{f}\n", .{std.json.fmt(value, .{})});
    try writer.interface.flush();
}

const Seed = struct { state: lex.State, chosen: []const u8, estimates: []const f64 };
fn bestSeed(alloc: std.mem.Allocator, parent: std.mem.Allocator, raw: []const u8, block: usize) !Seed {
    const Candidate = struct { name: []const u8, grammar: gram.Grammar, cost: f64 };
    var candidates: std.ArrayList(Candidate) = .empty;
    for ([_]gram.Priority{ .freq, .saving }) |priority| {
        var scratch: std.heap.ArenaAllocator = .init(parent);
        defer scratch.deinit();
        const temporary = scratch.allocator();
        var grammar = try gram.build(temporary, raw, block, .{ .min_freq = 2, .alpha_percent = 50, .priority = priority, .fast_count = true });
        if (!try gram.verifyExact(temporary, raw, &grammar)) return error.NotExact;
        try candidates.append(alloc, .{ .name = if (priority == .freq) "a1_mf2" else "a3_saving", .grammar = try grammar.clone(alloc), .cost = (try gram.costOf(temporary, &grammar, 13)).total_bytes });
    }
    for (0..2) |i| {
        var scratch: std.heap.ArenaAllocator = .init(parent);
        defer scratch.deinit();
        const temporary = scratch.allocator();
        var grammar = try candidates.items[i].grammar.clone(temporary);
        _ = try gram.mdlDelete(temporary, &grammar, 13, 8);
        if (!try gram.verifyExact(temporary, raw, &grammar)) return error.NotExact;
        try candidates.append(alloc, .{ .name = if (i == 0) "a1_mf2+a2" else "a3+a2", .grammar = try grammar.clone(alloc), .cost = (try gram.costOf(temporary, &grammar, 13)).total_bytes });
    }
    var best: usize = 0;
    for (candidates.items, 0..) |candidate, i| if (candidate.cost < candidates.items[best].cost) {
        best = i;
    };
    {
        var scratch: std.heap.ArenaAllocator = .init(parent);
        defer scratch.deinit();
        const temporary = scratch.allocator();
        var reparsed = try candidates.items[best].grammar.clone(temporary);
        _ = try gram.optimalReparse(temporary, &reparsed, raw, 13, 256, 3);
        if (!try gram.verifyExact(temporary, raw, &reparsed)) return error.NotExact;
        try candidates.append(alloc, .{ .name = "best+a4", .grammar = try reparsed.clone(alloc), .cost = (try gram.costOf(temporary, &reparsed, 13)).total_bytes });
    }
    for (candidates.items, 0..) |candidate, i| if (candidate.cost < candidates.items[best].cost) {
        best = i;
    };
    const selected = candidates.items[best];
    const rules = try alloc.alloc(lex.V1Rule, selected.grammar.rules.items.len);
    for (rules, selected.grammar.rules.items) |*rule, old| rule.* = .{ .a = old.a, .b = old.b };
    var dump: lex.V1Dump = .{ .rules = rules, .block_bytes = block, .raw_len = raw.len, .seq = selected.grammar.seq, .block_end = selected.grammar.block_end };
    const costs = try alloc.alloc(f64, candidates.items.len);
    for (candidates.items, costs) |candidate, *cost| cost.* = candidate.cost;
    return .{ .state = try lex.seedFromV1(alloc, &dump), .chosen = selected.name, .estimates = costs };
}
fn appendInt(out: *std.ArrayList(u8), alloc: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try out.appendSlice(alloc, &bytes);
}
fn appendArray(out: *std.ArrayList(u8), alloc: std.mem.Allocator, values: []const u32) !void {
    try appendInt(out, alloc, std.math.cast(u32, values.len) orelse return error.GraphBudget);
    for (values) |value| try appendInt(out, alloc, value);
}
fn asParse(alloc: std.mem.Allocator, state: *const lex.State) !bz4.Parse {
    const entries = state.lex.numEntries();
    if (entries > 500000 or state.seq.len > 64 * 1024 * 1024) return error.GraphBudget;
    for (0..entries) |entry| {
        const body = state.lex.comps(entry);
        if (body.len < 2) return error.BadGrammar;
        var length: u64 = 0;
        for (body) |child| {
            if (child >= 256) {
                if (child - 256 >= entries or state.lex.explen.items[child - 256] >= state.lex.explen.items[entry]) return error.BadGrammar;
                length += state.lex.explen.items[child - 256];
            } else length += 1;
        }
        if (length != state.lex.explen.items[entry]) return error.BadGrammar;
    }
    var offsets = state.lex.comp_off.items;
    if (entries == 0) {
        const empty = try alloc.alloc(u32, 1);
        empty[0] = 0;
        offsets = empty;
    }
    const blocks = try alloc.alloc(u32, state.block_end.len + 1);
    blocks[0] = 0;
    for (state.block_end, blocks[1..]) |end, *off| off.* = std.math.cast(u32, end) orelse return error.GraphBudget;
    return .{ .body_off = offsets, .kids = state.lex.comp_data.items, .block_off = blocks, .toks = state.seq };
}
pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const input = args.next() orelse return error.Usage;
    const frame_path = args.next() orelse return error.Usage;
    const parse_path = args.next() orelse return error.Usage;
    const block = try std.fmt.parseUnsigned(usize, args.next() orelse "65536", 10);
    const max_iters = try std.fmt.parseUnsigned(usize, args.next() orelse "20", 10);
    const seed_name = args.next() orelse "a-best";
    const triples_value = try std.fmt.parseUnsigned(u8, args.next() orelse "1", 10);
    const hoist = try std.fmt.parseUnsigned(u8, args.next() orelse "0", 10);
    if (args.next() != null) return error.Usage;
    if (block == 0 or block > 65536 or max_iters == 0 or max_iters > 32 or triples_value > 1 or hoist > 1) return error.BadPolicy;
    var budget: Budget = .{ .parent = init.gpa, .limit = 4 * 1024 * 1024 * 1024 };
    const bounded = budget.allocator();
    const raw = try std.Io.Dir.cwd().readFileAlloc(init.io, input, bounded, .limited(64 * 1024 * 1024));
    defer bounded.free(raw);
    const start = now(init.io);
    var arena: std.heap.ArenaAllocator = .init(bounded);
    defer arena.deinit();
    var state: lex.State = undefined;
    var chosen_seed: []const u8 = undefined;
    var seed_estimates: []f64 = undefined;
    {
        var seed_arena: std.heap.ArenaAllocator = .init(bounded);
        defer seed_arena.deinit();
        const temporary = seed_arena.allocator();
        const seed: Seed = if (std.mem.eql(u8, seed_name, "a-best")) try bestSeed(temporary, bounded, raw, block) else if (std.mem.eql(u8, seed_name, "bytes")) .{ .state = try lex.seedBytes(temporary, raw, block), .chosen = "bytes", .estimates = &.{} } else return error.BadPolicy;
        state = try epochs.copyState(arena.allocator(), &seed.state);
        chosen_seed = seed.chosen;
        seed_estimates = try bounded.dupe(f64, seed.estimates);
    }
    defer bounded.free(seed_estimates);
    const seed_peak = budget.peak;
    budget.peak = budget.live;
    var log: std.ArrayList(lex.IterLog) = .empty;
    defer log.deinit(bounded);
    try epochs.iterate(bounded, init.io, &arena, &state, raw, .{ .max_iters = max_iters, .triples = triples_value == 1 }, &log);
    const learning_peak = budget.peak;
    budget.peak = budget.live;
    const alloc = arena.allocator();
    if (!try lex.verifyExact(alloc, raw, &state)) return error.NotExact;
    const parse = try asParse(alloc, &state);
    var private: std.ArrayList(u8) = .empty;
    // P6F1 deliberately distinguishes preserved forward-DAG IDs from P6P1.
    try private.appendSlice(alloc, "P6F1");
    try appendArray(&private, alloc, parse.body_off);
    try appendArray(&private, alloc, parse.kids);
    try appendArray(&private, alloc, parse.block_off);
    try appendArray(&private, alloc, parse.toks);
    const fit = try fitting.fit(bounded, parse, .{ .hoist = hoist == 1 });
    defer bounded.free(fit.bytes);
    const duration = now(init.io) - start;
    var stats = try ledger(init.gpa, fit.bytes);
    defer stats.block_raw_lengths.deinit(init.gpa);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = parse_path, .data = private.items });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = frame_path, .data = fit.bytes });
    try json(init, .{ .codec_ns = duration, .frame_bytes = fit.bytes.len, .classes = fit.classes, .header_bytes = stats.header_bytes, .directory_bytes = stats.directory_bytes, .model_dictionary_bytes = stats.model_dictionary_bytes, .payload_bytes = stats.payload_bytes, .raw_bytes = stats.raw_bytes, .blocks = stats.blocks, .block_raw_lengths = stats.block_raw_lengths.items, .entries = state.lex.numEntries(), .tokens = state.seq.len, .encoder_peak_allocated_bytes = @max(seed_peak, @max(learning_peak, budget.peak)), .phase_peak_allocated_bytes = .{ .seed = seed_peak, .learning = learning_peak, .fitting = budget.peak }, .encoder_allocation_limit = budget.limit, .policy = .{ .seed = seed_name, .block_bytes = block, .max_iters = max_iters, .triples = triples_value == 1, .max_material_len = 256, .converge_frac = 0.0005, .symbol_order = "learner_original", .hoist = hoist == 1, .max_input_bytes = 64 * 1024 * 1024 }, .seed_selected = chosen_seed, .seed_estimates = seed_estimates, .iterations = log.items });
}
