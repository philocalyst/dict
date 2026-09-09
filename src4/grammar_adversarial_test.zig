const std = @import("std");
const builtin = @import("builtin");
const grammar = @import("grammar.zig");

const CountingSource = struct {
    data: []const u8,
    calls: usize = 0,
    bytes_touched: usize = 0,
    deny_offset: ?usize = null,

    pub fn len(self: *const CountingSource) usize {
        return self.data.len;
    }
    pub fn bytes(self: *CountingSource, offset: usize, length: usize) ![]const u8 {
        if (offset > self.data.len or length > self.data.len - offset) return error.Truncated;
        if (self.deny_offset) |denied| if (denied >= offset and denied < offset + length) return error.IntegrityFailure;
        self.calls += 1;
        self.bytes_touched += length;
        return self.data[offset..][0..length];
    }
};

fn nextRandom(state: *u64) u64 {
    state.* ^= state.* << 7;
    state.* ^= state.* >> 9;
    state.* ^= state.* << 8;
    return state.*;
}

test "compact grammar is deterministic, lossless, and aliases exactly" {
    const inputs = [_]grammar.ItemInput{
        .{ .text = "the same definition appears again; the same definition appears again" },
        .{ .text = "a short example" },
        .{ .text = "the same definition appears again; the same definition appears again" },
        .{ .text = "" },
        .{ .text = "" },
    };
    var first = try grammar.build(std.testing.allocator, &inputs, .{});
    defer first.deinit();
    var second = try grammar.build(std.testing.allocator, &inputs, .{});
    defer second.deinit();
    try std.testing.expectEqualSlices(u8, first.bytes, second.bytes);
    var view = try grammar.View.open(first.bytes, .{});
    try view.verify();
    var oracle = grammar.ReferenceOracle.init(&inputs);
    for (inputs, 0..) |input, index| {
        var actual: [128]u8 = undefined;
        var expected: [128]u8 = undefined;
        const actual_len = try view.extract(index, actual[0..]);
        const expected_len = try oracle.extract(index, expected[0..]);
        try std.testing.expectEqual(expected_len, actual_len);
        try std.testing.expectEqualSlices(u8, expected[0..expected_len], actual[0..actual_len]);
        var preview: [11]u8 = undefined;
        var oracle_preview: [11]u8 = undefined;
        const got = try view.snippet(index, 11, preview[0..]);
        const want = try oracle.snippet(index, 11, oracle_preview[0..]);
        try std.testing.expectEqual(want, got);
        try std.testing.expectEqualSlices(u8, oracle_preview[0..want], preview[0..got]);
        try std.testing.expectEqual(input.text.len, actual_len);
    }
    try std.testing.expectEqual(@as(?usize, 0), (try view.item(2)).alias);
    try std.testing.expectEqual(@as(?usize, 3), (try view.item(4)).alias);
    try std.testing.expect(view.bytes.len < 400);
    const source = grammar.SliceSource.init(first.bytes);
    try std.testing.expectEqual((try view.rule(0)).left, (try view.readRuleFrom(source, 0)).left);
    try std.testing.expectEqual(try view.readSequenceFrom(source, 0), try view.readSequenceFrom(source, 0));
}

test "source-backed open is cheap and extraction authenticates only touched ranges" {
    const inputs = [_]grammar.ItemInput{ .{ .text = "source backed direct prose access" }, .{ .text = "unrelated page text" } };
    var owned = try grammar.build(std.testing.allocator, &inputs, .{});
    defer owned.deinit();
    var source = CountingSource{ .data = owned.bytes };
    var raw_view = try grammar.View.openEnvelope(owned.bytes, .{});
    var raw_out: [64]u8 = undefined;
    _ = try raw_view.extractFrom(&source, 0, raw_out[0..]);
    source.calls = 0;
    source.bytes_touched = 0;
    const SourceView = grammar.ViewFor(*CountingSource);
    var view = try SourceView.open(&source, .{});
    try std.testing.expectEqual(@as(usize, 1), source.calls);
    try std.testing.expect(source.bytes_touched <= grammar.header_size);
    const denied = view.sequence_offset + view.sequence_bytes - 1;
    source.deny_offset = denied;
    var out: [8]u8 = undefined;
    // The first snippet should not authenticate the final packed-symbol byte.
    _ = try view.snippet(0, 4, out[0..]);
    var full: [64]u8 = undefined;
    try std.testing.expectEqual(inputs[0].text.len, try view.extract(0, full[0..]));
    try std.testing.expect(source.calls > 1);
    source.deny_offset = view.sequence_offset;
    try std.testing.expectError(error.IntegrityFailure, view.snippet(0, 4, out[0..]));

    // The same canonical comptime reader specializes directly for mapped
    // slices; no source adapter or parallel rendering implementation exists.
    const SliceView = grammar.ViewFor([]const u8);
    const slice_view = try SliceView.open(owned.bytes, .{});
    try slice_view.verify();
    var slice_out: [64]u8 = undefined;
    const slice_len = try slice_view.extract(1, slice_out[0..]);
    try std.testing.expectEqualSlices(u8, inputs[1].text, slice_out[0..slice_len]);
}

test "intermediate alias checkpoints must equal the measured prefix" {
    var inputs: [130]grammar.ItemInput = undefined;
    for (&inputs, 0..) |*input, index| input.* = .{ .text = if (index % 2 == 0) "x" else "y" };
    var owned = try grammar.build(std.testing.allocator, &inputs, .{});
    defer owned.deinit();
    const view = try grammar.View.open(owned.bytes, .{});
    try view.verify();
    const bad = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad);
    // A monotone but false checkpoint can redirect an alias to the other
    // valid earlier item. Bounds/cycle checks alone cannot catch this.
    const slot = view.alias_rank_offset + 4;
    const correct = std.mem.readInt(u32, bad[slot..][0..4], .little);
    std.mem.writeInt(u32, bad[slot..][0..4], correct - 1, .little);
    const raw_bad = try grammar.View.openEnvelope(bad, .{});
    try std.testing.expectError(error.Malformed, raw_bad.verify());
    var source = CountingSource{ .data = bad };
    try std.testing.expectError(error.Malformed, view.verifyFrom(&source));
    const sourced = try grammar.ViewFor(*CountingSource).open(&source, .{});
    try std.testing.expectError(error.Malformed, sourced.verify());
}

test "shared continuation machine has bounded four-byte scratch and work" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(grammar.Frame));
    const text = "abababababababababababababababababababababababababababababababab";
    var owned = try grammar.build(std.testing.allocator, &.{.{ .text = text }}, .{});
    defer owned.deinit();
    const raw = try grammar.View.open(owned.bytes, .{});
    try raw.verify();
    var output: [text.len]u8 = undefined;
    var tiny: [1]grammar.Frame = undefined;
    try std.testing.expectError(error.StackLimitExceeded, raw.extractWithStack(0, &output, &.{}));
    try std.testing.expectError(error.StackLimitExceeded, raw.extractWithStack(0, &output, &tiny));
    var stack: [32]grammar.Frame = undefined;
    try std.testing.expectEqual(text.len, try raw.extractWithStack(0, &output, &stack));
    try std.testing.expectEqualStrings(text, &output);
    const bounded = try grammar.View.open(owned.bytes, .{ .max_expansion_steps = 1 });
    try std.testing.expectError(error.DecompressionBomb, bounded.snippetWithStack(0, text.len, &output, &stack));
    const sourced = try grammar.ViewFor([]const u8).open(owned.bytes, .{});
    var raw_trace = grammar.AccessTrace{};
    var source_trace = grammar.AccessTrace{};
    _ = try raw.extractWithTrace(0, &output, &raw_trace);
    _ = try sourced.extractWithTrace(0, &output, &source_trace);
    try std.testing.expectEqual(raw_trace.rule_records, source_trace.rule_records);
    try std.testing.expectEqual(raw_trace.sequence_symbols, source_trace.sequence_symbols);
    try std.testing.expect(raw_trace.rule_records != 0);
}

test "authenticated source queries never fall back to raw bytes" {
    const inputs = [_]grammar.ItemInput{
        .{ .text = "repeated authenticated source content repeated authenticated source content" },
        .{ .text = "a distinct source item" },
        .{ .text = "repeated authenticated source content repeated authenticated source content" },
    };
    var owned = try grammar.build(std.testing.allocator, &inputs, .{});
    defer owned.deinit();
    const source_bytes = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(source_bytes);
    var source = CountingSource{ .data = source_bytes };
    var view = try grammar.View.openEnvelope(owned.bytes, .{});
    try std.testing.expect(view.rule_count > 0);
    try std.testing.expect(view.alias_count > 0);

    // Corrupt every packed section in the view's borrowed bytes.  The
    // authenticated copy remains valid, so all source-backed reads must come
    // from source.bytes rather than silently falling back to view.bytes.
    const raw = @constCast(view.bytes);
    for ([_]grammar.RangeKind{ .rules, .sequence, .item_ends, .alias_bits, .alias_ranks, .alias_targets }) |kind| {
        const range = try view.sectionRange(kind);
        if (range.length != 0) raw[range.offset] ^= 0x01;
    }
    try view.verifyFrom(&source);

    const item_info = try view.itemFrom(&source, 2);
    try std.testing.expectEqual(@as(?usize, 0), item_info.alias);
    try std.testing.expectEqual(inputs[2].text.len, @as(usize, @intCast(item_info.output_len)));
    const rule = try view.ruleFrom(&source, 0);
    const clean_view = try grammar.View.openEnvelope(source_bytes, .{});
    try std.testing.expectEqual((try clean_view.rule(0)).left, rule.left);
    _ = try view.readItemEndFrom(&source, 2);
    _ = try view.readSequenceFrom(&source, 0);
    _ = try view.readRuleFrom(&source, 0);

    var extracted: [128]u8 = undefined;
    const extracted_len = try view.extractFrom(&source, 2, extracted[0..]);
    try std.testing.expectEqualSlices(u8, inputs[2].text, extracted[0..extracted_len]);
    var preview: [17]u8 = undefined;
    const preview_len = try view.snippetFrom(&source, 2, preview.len, preview[0..]);
    try std.testing.expectEqualSlices(u8, inputs[2].text[0..preview_len], preview[0..preview_len]);
    try std.testing.expect(source.calls > 20);
}

test "authenticated extraction propagates sequence rule and alias lane failures" {
    const repeated = "abababababababababababababababab";
    const inputs = [_]grammar.ItemInput{
        .{ .text = repeated },
        .{ .text = repeated },
    };
    var owned = try grammar.build(std.testing.allocator, &inputs, .{});
    defer owned.deinit();
    var source = CountingSource{ .data = owned.bytes };
    const view = try grammar.View.openEnvelope(owned.bytes, .{});
    const primary = try view.itemFrom(&source, 0);
    try std.testing.expect(primary.symbol_count != 0);
    try std.testing.expect((try view.itemFrom(&source, 1)).alias != null);
    var output: [repeated.len]u8 = undefined;

    const sequence_range = try view.sequenceRange(@intCast(primary.sequence_start));
    source.deny_offset = sequence_range.offset;
    try std.testing.expectError(error.IntegrityFailure, view.extractFrom(&source, 0, output[0..]));
    source.deny_offset = null;

    var referenced_rule: ?usize = null;
    const sequence_end: usize = @intCast(primary.sequence_start + primary.symbol_count);
    for (@as(usize, @intCast(primary.sequence_start))..sequence_end) |index| {
        const symbol = try view.readSequenceFrom(&source, index);
        if (symbol >= grammar.terminal_count) {
            referenced_rule = @intCast(symbol - grammar.terminal_count);
            break;
        }
    }
    const rule_range = try view.ruleRange(referenced_rule orelse return error.InvalidRuleReference);
    source.deny_offset = rule_range.offset;
    try std.testing.expectError(error.IntegrityFailure, view.extractFrom(&source, 0, output[0..]));
    source.deny_offset = null;

    // An alias extraction must authenticate all three sparse-alias lanes:
    // membership bit, rank checkpoint, and packed backward target.
    inline for (.{ grammar.RangeKind.alias_bits, grammar.RangeKind.alias_ranks, grammar.RangeKind.alias_targets }) |kind| {
        const range = try view.sectionRange(kind);
        try std.testing.expect(range.length != 0);
        source.deny_offset = range.offset;
        try std.testing.expectError(error.IntegrityFailure, view.extractFrom(&source, 1, output[0..]));
        source.deny_offset = null;
    }
}

test "random differential extraction and bounded snippets" {
    var storage: [96][48]u8 = undefined;
    var inputs: [96]grammar.ItemInput = undefined;
    var state: u64 = 0x9e37_79b9_7f4a_7c15;
    for (&storage, 0..) |*buffer, index| {
        const mode = nextRandom(&state) % 5;
        var length: usize = @intCast(nextRandom(&state) % 42);
        if (mode == 0 and index > 0) {
            inputs[index] = .{ .text = inputs[index - 1].text };
            continue;
        }
        if (mode == 1) length = 24;
        for (buffer[0..length], 0..) |*byte, offset| {
            const alphabet = " abcd.,;!?\"'";
            byte.* = alphabet[@intCast((nextRandom(&state) + offset) % alphabet.len)];
        }
        inputs[index] = .{ .text = buffer[0..length] };
    }
    var owned = try grammar.build(std.testing.allocator, &inputs, .{});
    defer owned.deinit();
    var view = try grammar.View.open(owned.bytes, .{});
    try view.verify();
    var oracle = grammar.ReferenceOracle.init(&inputs);
    for (inputs, 0..) |_, index| {
        var actual: [64]u8 = undefined;
        var expected: [64]u8 = undefined;
        const got = try view.extract(index, actual[0..]);
        const want = try oracle.extract(index, expected[0..]);
        try std.testing.expectEqual(want, got);
        try std.testing.expectEqualSlices(u8, expected[0..want], actual[0..got]);
        var limit_state = state ^ @as(u64, @intCast(index + 1));
        for (0..8) |_| {
            const limit: usize = @intCast(nextRandom(&limit_state) % 70);
            var p: [70]u8 = undefined;
            var q: [70]u8 = undefined;
            const a = try view.snippet(index, limit, p[0..]);
            const b = try oracle.snippet(index, limit, q[0..]);
            try std.testing.expectEqual(b, a);
            try std.testing.expectEqualSlices(u8, q[0..b], p[0..a]);
        }
    }
}

test "snippet touches only relevant path and uses no decoder" {
    const inputs = [_]grammar.ItemInput{
        .{ .text = "0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz" },
        .{ .text = "unrelated item that is never decoded" },
    };
    var owned = try grammar.build(std.testing.allocator, &inputs, .{});
    defer owned.deinit();
    var view = try grammar.View.open(owned.bytes, .{});
    var trace: grammar.AccessTrace = .{};
    var out: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), try view.snippetWithTrace(0, 5, out[0..], &trace));
    try std.testing.expectEqualStrings("01234", out[0..]);
    try std.testing.expectEqual(@as(usize, 0), view.directBlockDecodeCount());
    try std.testing.expect(trace.sequence_symbols < (try view.item(0)).symbol_count or (try view.item(0)).symbol_count == 0);
}

test "malformed topology, ranges, symbols, and budgets are rejected" {
    const inputs = [_]grammar.ItemInput{ .{ .text = "abababababababab" }, .{ .text = "abababababababab" } };
    try std.testing.expectError(error.OutputLimitExceeded, grammar.build(std.testing.allocator, &inputs, .{ .max_output_bytes = 4 }));
    var owned = try grammar.build(std.testing.allocator, &inputs, .{});
    defer owned.deinit();

    const bad_symbol = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_symbol);
    var symbol_view = try grammar.View.openEnvelope(bad_symbol, .{});
    const symbol_range = try symbol_view.sequenceRange(0);
    const mutable_symbol_bytes = @constCast(symbol_view.bytes);
    for (0..symbol_view.symbol_bits) |bit| mutable_symbol_bytes[symbol_range.offset + bit / 8] |= @as(u8, 1) << @as(u3, @intCast(bit % 8));
    // Open is structural and intentionally cheap; the deferred content pass
    // catches an invalid packed symbol before any extraction can use it.
    try std.testing.expectError(error.InvalidRuleReference, symbol_view.verify());

    var bad_magic = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_magic);
    bad_magic[0] = 'X';
    try std.testing.expectError(error.Malformed, grammar.View.openEnvelope(bad_magic, .{}));

    var bad_end = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_end);
    const ends_offset = @as(usize, @intCast(std.mem.readInt(u64, bad_end[56..64], .little)));
    // All item ends are packed into this tiny section.  Setting every bit
    // makes the final cumulative end exceed sequence_count.
    bad_end[ends_offset] = 0xff;
    var bad_end_view = try grammar.View.openEnvelope(bad_end, .{});
    try std.testing.expectError(error.InvalidItemRange, bad_end_view.verify());

    if (grammar.View.openEnvelope(owned.bytes, .{ .max_rule_expansion_bytes = 1 })) |strict| {
        try std.testing.expectError(error.DecompressionBomb, strict.verify());
    } else |err| try std.testing.expectEqual(error.DecompressionBomb, err);

    const bad_alias_count = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(bad_alias_count);
    std.mem.writeInt(u64, bad_alias_count[28..36], 3, .little);
    try std.testing.expectError(error.OutputLimitExceeded, grammar.View.openEnvelope(bad_alias_count, .{}));
}

const FixtureKind = enum { flat, prose_heavy, repeated, rich, pathological_prefix };

fn benchDefinition(kind: FixtureKind, index: usize, out: []u8) ![]const u8 {
    const common = "A deterministic lexical definition with usage, evidence, and a stable repeated phrase; it is intentionally ordinary prose rather than a synthetic byte stream. ";
    return switch (kind) {
        .flat, .rich, .pathological_prefix => std.fmt.bufPrint(out, "{s}record {d} seed {x}.", .{ common, index, @as(u64, 0x4c455832_0002_0001) }) catch error.OutputTooSmall,
        .repeated => blk: {
            const templates = [_][]const u8{
                "financial institution and money-management context.",
                "river edge, bank, and geographic sense context.",
                "to rely upon, trust, or depend on a person.",
                "a long lexical example with multilingual 東京 and banque.",
            };
            break :blk std.fmt.bufPrint(out, "{s}{s}", .{ common, templates[index % templates.len] }) catch error.OutputTooSmall;
        },
        .prose_heavy => blk: {
            var at: usize = 0;
            for (0..32) |_| {
                @memcpy(out[at .. at + common.len], common);
                at += common.len;
            }
            const suffix = std.fmt.bufPrint(out[at..], "record {d} seed {x}; end.", .{ index, @as(u64, 0x4c455832_0002_0001) }) catch return error.OutputTooSmall;
            break :blk out[0 .. at + suffix.len];
        },
    };
}

test "bench2 five-fixture compact ledger" {
    const kinds = [_]FixtureKind{ .flat, .prose_heavy, .repeated, .rich, .pathological_prefix };
    // This is a size/scaling integration gate, not a render microbenchmark.
    // Wall time includes construction of all fixtures, verification, and four
    // correctness renders per fixture (plus test-runner overhead). `build_ns`
    // below times only grammar.build for that fixture. Per-operation render
    // latency belongs to the warmed benchmark harness and must never be
    // inferred by dividing either of these integration timings.
    // The offline Re-Pair pass is O(rule_budget * corpus_bytes). Keep the
    // full 2,048-record wire gate in optimized modes while making Debug a
    // bounded scaling sample instead of a four-minute duplicate. Both print
    // their record count, elapsed time, and deterministic work bound.
    const record_count: usize = if (builtin.mode == .Debug) 256 else 2048;
    const rule_budget = 256;
    var ledger: [kinds.len]usize = undefined;
    for (kinds, 0..) |kind, slot| {
        const storage = try std.testing.allocator.alloc([6000]u8, record_count);
        defer std.testing.allocator.free(storage);
        const inputs = try std.testing.allocator.alloc(grammar.ItemInput, record_count);
        defer std.testing.allocator.free(inputs);
        for (storage, 0..) |*buffer, index| inputs[index] = .{ .text = try benchDefinition(kind, index, buffer[0..]) };
        // The fixture gate measures the compact wire and direct rendering;
        // bound offline rounds so this 10 MiB prose corpus remains a focused
        // test rather than a multi-minute build on a debug allocator.
        const started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        var owned = try grammar.build(std.testing.allocator, inputs, .{ .max_rules = rule_budget });
        const build_ns: u64 = @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds - started);
        defer owned.deinit();
        var view = try grammar.View.open(owned.bytes, .{});
        try view.verify();
        var output: [6000]u8 = undefined;
        var render_ns: u64 = 0;
        for ([_]usize{ 0, @min(173, record_count - 1), record_count / 2, record_count - 1 }) |index| {
            const render_started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
            const n = try view.extract(index, output[0..]);
            render_ns += @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds - render_started);
            try std.testing.expectEqual(inputs[index].text.len, n);
            try std.testing.expectEqualSlices(u8, inputs[index].text, output[0..n]);
        }
        ledger[slot] = owned.bytes.len;
        std.debug.print("compact grammar ledger fixture={s} records={d} bytes={d} rules={d} sequence={d} build_ns={d} render_ns={d} render_count=4 work_bound={d}\n", .{ @tagName(kind), record_count, owned.bytes.len, owned.rule_count, view.sequence_count, build_ns, render_ns, rule_budget * record_count });
    }
    // The guard is deliberately generous: it catches a regression to one
    // fixed-width item record without pretending to be a final archive gate.
    if (record_count == 2048) for (ledger) |size| try std.testing.expect(size < 128 * 1024);
}

const ScaleKind = enum { repeated, prose };

const ScaleMeasurement = struct {
    bytes: usize,
    rules: usize,
    sequence: usize,
    build_ns: u64,
    render_ns: u64,
};

fn measureScalePoint(kind: ScaleKind, record_count: usize) !ScaleMeasurement {
    const allocator = std.testing.allocator;
    const storage = try allocator.alloc([256]u8, record_count);
    defer allocator.free(storage);
    const inputs = try allocator.alloc(grammar.ItemInput, record_count);
    defer allocator.free(inputs);
    for (storage, 0..) |*buffer, index| {
        // The scaling table deliberately uses bounded ordinary prose records;
        // `.prose_heavy` remains in the five-fixture stress ledger above.
        // This keeps N—not per-record byte inflation—the changing variable.
        const fixture_kind: FixtureKind = switch (kind) {
            .repeated => .repeated,
            .prose => .flat,
        };
        inputs[index] = .{ .text = try benchDefinition(fixture_kind, index, buffer[0..]) };
    }

    const build_started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    var owned = try grammar.build(allocator, inputs, .{ .max_rules = 128 });
    const build_ns: u64 = @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds - build_started);
    defer owned.deinit();
    var view = try grammar.View.open(owned.bytes, .{});
    try view.verify();

    var output: [256]u8 = undefined;
    var render_ns: u64 = 0;
    for ([_]usize{ 0, record_count / 3, (record_count * 2) / 3, record_count - 1 }) |index| {
        const render_started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        const n = try view.extract(index, output[0..]);
        render_ns += @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds - render_started);
        try std.testing.expectEqualSlices(u8, inputs[index].text, output[0..n]);
    }
    return .{ .bytes = owned.bytes.len, .rules = owned.rule_count, .sequence = view.sequence_count, .build_ns = build_ns, .render_ns = render_ns };
}

test "compact grammar repeated and prose N-scaling ledger" {
    const points = [_]usize{ 256, 512, 1024, 2048 };
    // Only ReleaseFast pays for the complete table used as scaling evidence.
    // Other modes retain one deterministic point for correctness and leak
    // coverage without multiplying Debug's offline grammar-build cost.
    const point_count: usize = if (builtin.mode == .ReleaseFast) points.len else 1;
    for ([_]ScaleKind{ .repeated, .prose }) |kind| {
        var previous_bytes: usize = 0;
        for (points[0..point_count]) |record_count| {
            const result = try measureScalePoint(kind, record_count);
            try std.testing.expect(result.bytes >= previous_bytes);
            previous_bytes = result.bytes;
            std.debug.print("compact grammar scaling fixture={s} records={d} bytes={d} rules={d} sequence={d} build_ns={d} render_ns={d} render_count=4\n", .{ @tagName(kind), record_count, result.bytes, result.rules, result.sequence, result.build_ns, result.render_ns });
        }
    }
}

fn allocationFailureBuild(allocator: std.mem.Allocator) !void {
    const inputs = [_]grammar.ItemInput{
        .{ .text = "abababab" },
        .{ .text = "a different phrase" },
        .{ .text = "abababab" },
    };
    var owned = try grammar.build(allocator, &inputs, .{});
    owned.deinit();
}

test "builder cleans up at every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureBuild, .{});
}
