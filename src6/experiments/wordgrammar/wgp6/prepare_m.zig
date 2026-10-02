//! Reproduce the historical Lane M byte-MDL learner as a native-v4 frontend.
//! The private P6P1 graph is an encoder artifact, not an archive format.
//! Lane M and the old native codec remain unchanged.
const std = @import("std");
const lex = @import("lex");

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
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

fn graph(alloc: std.mem.Allocator, state: *const lex.State) ![]u8 {
    const entries = state.lex.numEntries();
    if (entries > 500000 or state.seq.len > 16 * 1024 * 1024) return error.GraphBudget;
    const order = try alloc.alloc(u32, entries);
    const inverse = try alloc.alloc(u32, entries);
    for (order, 0..) |*entry, i| entry.* = @intCast(i);
    const Context = struct {
        lengths: []const u32,
        fn shorter(ctx: @This(), a: u32, b: u32) bool {
            return if (ctx.lengths[a] != ctx.lengths[b]) ctx.lengths[a] < ctx.lengths[b] else a < b;
        }
    };
    std.mem.sort(u32, order, Context{ .lengths = state.lex.explen.items }, Context.shorter);
    for (order, 0..) |original, i| inverse[original] = @intCast(256 + i);
    var offsets: std.ArrayList(u32) = .empty;
    var children: std.ArrayList(u32) = .empty;
    try offsets.append(alloc, 0);
    for (order, 0..) |original, i| {
        const body = state.lex.comps(original);
        if (body.len < 2) return error.BadGrammar;
        var length: u64 = 0;
        for (body) |child| {
            if (child >= 256) {
                if (child - 256 >= entries or inverse[child - 256] >= 256 + i) return error.BadGrammar;
                length += state.lex.explen.items[child - 256];
            } else length += 1;
            try children.append(alloc, if (child < 256) child else inverse[child - 256]);
        }
        if (length != state.lex.explen.items[original]) return error.BadGrammar;
        try offsets.append(alloc, std.math.cast(u32, children.items.len) orelse return error.GraphBudget);
    }
    const tokens = try alloc.alloc(u32, state.seq.len);
    for (state.seq, tokens) |old, *new| {
        if (old >= 256 and old - 256 >= entries) return error.BadGrammar;
        new.* = if (old < 256) old else inverse[old - 256];
    }
    const blocks = try alloc.alloc(u32, state.block_end.len + 1);
    blocks[0] = 0;
    for (state.block_end, blocks[1..]) |end, *off| off.* = std.math.cast(u32, end) orelse return error.GraphBudget;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "P6P1");
    try appendArray(&out, alloc, offsets.items);
    try appendArray(&out, alloc, children.items);
    try appendArray(&out, alloc, blocks);
    try appendArray(&out, alloc, tokens);
    return out.toOwnedSlice(alloc);
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const input = args.next() orelse return error.Usage;
    const output = args.next() orelse return error.Usage;
    const block = try std.fmt.parseUnsigned(usize, args.next() orelse "65536", 10);
    const max_iters = try std.fmt.parseUnsigned(usize, args.next() orelse "20", 10);
    const triples_value = try std.fmt.parseUnsigned(u8, args.next() orelse "1", 10);
    if (args.next() != null) return error.Usage;
    if (block == 0 or block > 65536 or max_iters == 0 or max_iters > 32 or triples_value > 1) return error.BadPolicy;
    const raw = try std.Io.Dir.cwd().readFileAlloc(init.io, input, init.gpa, .limited(16 * 1024 * 1024));
    defer init.gpa.free(raw);
    const start = now(init.io);
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var state = try lex.seedBytes(alloc, raw, block);
    var log: std.ArrayList(lex.IterLog) = .empty;
    try lex.iterate(alloc, init.io, &state, raw, .{ .max_iters = max_iters, .triples = triples_value == 1 }, &log);
    if (!try lex.verifyExact(alloc, raw, &state)) return error.NotExact;
    const bytes = try graph(alloc, &state);
    const duration = now(init.io) - start;
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output, .data = bytes });
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.print("{f}\n", .{std.json.fmt(.{ .codec_ns = duration, .input_bytes = raw.len, .entries = state.lex.numEntries(), .tokens = state.seq.len, .blocks = state.block_end.len, .private_parse_bytes = bytes.len, .policy = .{ .seed = "bytes", .block_bytes = block, .max_iters = max_iters, .triples = triples_value == 1, .max_material_len = 256, .converge_frac = 0.0005 }, .iterations = log.items }, .{})});
    try writer.interface.flush();
}
