//! Native event-layer sparse deterministic context automaton. Development
//! policy: first fit the unchanged class/bucket/PAST planner, then code every
//! selected candidate as a complete archive and keep the smallest archive.
//! The predictor uses only earlier decoded payload tokens and resets per page.
const std = @import("std");
const Allocator = std.mem.Allocator;
const bz4 = @import("bz4");
const model_ = bz4;
const lifetime_fit = @import("common/lifetime_fit.zig");

const Observation = struct { row: u16, key: u32, sym: u16 };
const Scored = struct { selector: model_.Selector, net_bits: f64 };

pub const Fit = struct {
    bytes: []u8,
    feature: model_.Feature,
    selectors: usize,
    classes: u16,
    trials: usize,
    baseline_bytes: usize,
};

fn observationLess(_: void, a: Observation, b: Observation) bool {
    if (a.row != b.row) return a.row < b.row;
    if (a.key != b.key) return a.key < b.key;
    return a.sym < b.sym;
}

fn scoreMore(_: void, a: Scored, b: Scored) bool {
    if (a.net_bits != b.net_bits) return a.net_bits > b.net_bits;
    if (a.selector.base_row != b.selector.base_row) return a.selector.base_row < b.selector.base_row;
    return a.selector.key < b.selector.key;
}

fn selectorLess(_: void, a: model_.Selector, b: model_.Selector) bool {
    if (a.base_row != b.base_row) return a.base_row < b.base_row;
    return a.key < b.key;
}

fn traceKey(feature: model_.Feature, current: bz4.TraceRow, previous: ?bz4.TraceRow, second: ?bz4.TraceRow) ?u32 {
    const p = previous;
    return switch (feature) {
        .none => null,
        .suffix1 => if (current.suffix_len >= 1) current.suffix & 0xff else null,
        .suffix2 => if (current.suffix_len >= 2) current.suffix & 0xffff else null,
        .suffix3 => if (current.suffix_len >= 3) current.suffix & 0xffffff else null,
        .suffix4 => if (current.suffix_len >= 4) current.suffix else null,
        .previous_kind => if (p) |last| last.kind else null,
        .previous_length_bin => if (p) |last| @min(16, std.math.log2_int(u32, @max(1, last.token_len))) else null,
        .second_base_row => if (p) |last| last.row else null,
        .two_kinds => if (p) |last| if (second) |before| @as(u32, before.kind) * 4 + last.kind else null else null,
        .kind_length => if (p) |last| @as(u32, last.kind) * 32 + @min(16, std.math.log2_int(u32, @max(1, last.token_len))) else null,
        .suffix1_kind => if (current.suffix_len >= 1 and p != null) (current.suffix & 0xff) * 4 + p.?.kind else null,
        .suffix2_kind => if (current.suffix_len >= 2 and p != null) (current.suffix & 0xffff) * 4 + p.?.kind else null,
        .previous_first_symbol => if (p) |last| last.sym else null,
    };
}

fn keyBits(feature: model_.Feature) u8 {
    return switch (feature) {
        .suffix1 => 8, .suffix2 => 16, .suffix3 => 24, .suffix4 => 32,
        .previous_kind => 2, .previous_length_bin => 5,
        .second_base_row, .previous_first_symbol => 16,
        .two_kinds => 4, .kind_length => 7,
        .suffix1_kind => 10, .suffix2_kind => 18,
        .none => 0,
    };
}

/// Ideal bits saved versus the base row, charging a deliberately cheap row
/// lower bound. Actual candidate trials include the complete native model.
fn candidates(gpa: Allocator, trace: []const bz4.TraceRow, model: bz4.Model, feature: model_.Feature) ![]Scored {
    var observations: std.ArrayList(Observation) = .empty;
    defer observations.deinit(gpa);
    const cells = @as(usize, model.rows) * model.alphabet;
    const base = try gpa.alloc(u32, cells);
    defer gpa.free(base);
    @memset(base, 0);
    const totals = try gpa.alloc(u32, model.rows);
    defer gpa.free(totals);
    @memset(totals, 0);
    var previous: ?bz4.TraceRow = null;
    var second: ?bz4.TraceRow = null;
    for (trace) |current| {
        if (current.suffix_len == 0) {
            previous = null;
            second = null;
        }
        if (current.row >= model.rows or current.sym >= model.alphabet) return error.BadTrace;
        base[model.cell(current.row, current.sym)] += 1;
        totals[current.row] += 1;
        if (traceKey(feature, current, previous, second)) |key| {
            try observations.append(gpa, .{ .row = current.row, .key = key, .sym = current.sym });
        }
        second = previous;
        previous = current;
    }
    std.mem.sort(Observation, observations.items, {}, observationLess);
    var scored: std.ArrayList(Scored) = .empty;
    errdefer scored.deinit(gpa);
    var i: usize = 0;
    while (i < observations.items.len) {
        const first = observations.items[i];
        var end = i + 1;
        while (end < observations.items.len and observations.items[end].row == first.row and observations.items[end].key == first.key) : (end += 1) {}
        const n: f64 = @floatFromInt(end - i);
        const total: f64 = @floatFromInt(totals[first.row]);
        var gain: f64 = 0;
        var supports: usize = 0;
        var j = i;
        while (j < end) {
            const sym = observations.items[j].sym;
            var next = j + 1;
            while (next < end and observations.items[next].sym == sym) : (next += 1) {}
            const count: f64 = @floatFromInt(next - j);
            const global: f64 = @floatFromInt(base[model.cell(first.row, sym)]);
            gain += count * @log2((count / n) / (global / total));
            supports += 1;
            j = next;
        }
        const cheap_model_bits: f64 = @floatFromInt(24 + @as(usize, keyBits(feature)) + 12 * supports);
        const net = gain - cheap_model_bits;
        if (net > 0 and end - i >= 8) try scored.append(gpa, .{
            .selector = .{ .base_row = first.row, .key = first.key }, .net_bits = net,
        });
        i = end;
    }
    std.mem.sort(Scored, scored.items, {}, scoreMore);
    return scored.toOwnedSlice(gpa);
}

fn apply(arena: Allocator, plan: *bz4.Plan, feature: model_.Feature, scored: []const Scored, count: usize) !void {
    const old = plan.model;
    if (count == 0 or count > 64 or @as(usize, old.rows) + count > 32768) return error.SelectorBudget;
    const selectors = try arena.alloc(model_.Selector, count);
    for (selectors, scored[0..count]) |*to, source| to.* = source.selector;
    std.mem.sort(model_.Selector, selectors, {}, selectorLess);
    var next: bz4.Model = try .init(arena, old.log, old.widths.len, @intCast(@as(usize, old.rows) + count), old.alphabet);
    next.base_rows = old.rows;
    next.feature = feature;
    next.selectors = selectors;
    next.ring = old.ring;
    next.silent = old.silent;
    next.arity_row = old.arity_row;
    next.cut_row = old.cut_row;
    next.start_row = old.start_row;
    @memcpy(next.widths, old.widths);
    @memcpy(next.norm[0..old.norm.len], old.norm);
    @memcpy(next.next[0..old.next.len], old.next);
    @memcpy(next.plain[0..old.plain.len], old.plain);
    @memcpy(next.name_row[0..old.name_row.len], old.name_row);
    @memcpy(next.first_row[0..old.first_row.len], old.first_row);
    @memcpy(next.logs[0..old.logs.len], old.logs);
    for (selectors, 0..) |selector, index| {
        const target: u16 = @intCast(old.rows + index);
        const source = selector.base_row;
        @memcpy(next.norm[next.cell(target, 0)..][0..old.alphabet], old.norm[old.cell(source, 0)..][0..old.alphabet]);
        @memcpy(next.next[next.cell(target, 0)..][0..old.alphabet], old.next[old.cell(source, 0)..][0..old.alphabet]);
        next.plain[target] = old.plain[source];
        next.name_row[target] = old.name_row[source];
        next.first_row[target] = old.first_row[source];
        next.logs[target] = old.logs[source];
    }
    plan.model = next;
}

pub fn fit(gpa: Allocator, input: bz4.Parse, options: bz4.plan.Options) !Fit {
    // One arena per class trial keeps the 4 GiB raw-encoder resource contract.
    const fitted = try lifetime_fit.fit(gpa, input, options);
    var best = fitted.bytes;
    errdefer gpa.free(best);
    const baseline_bytes = best.len;
    var baseline_arena: std.heap.ArenaAllocator = .init(gpa);
    defer baseline_arena.deinit();
    const arena = baseline_arena.allocator();
    var chosen_options = options;
    chosen_options.classes = fitted.classes;
    chosen_options.bucket_uses = null;
    var first = try bz4.plan.baseline(arena, input, chosen_options);
    var first_stats: bz4.Stats = .{
        .entry_bits = try arena.alloc(f64, first.parse.entries()),
        .entry_uses = try arena.alloc(u32, first.parse.entries()),
    };
    @memset(first_stats.entry_bits.?, 0);
    @memset(first_stats.entry_uses.?, 0);
    gpa.free(try bz4.encode(gpa, &first, &first_stats));
    chosen_options.bucket_uses = first_stats.entry_uses;
    var planned = try bz4.plan.baseline(arena, input, chosen_options);
    var starts: std.ArrayList(bz4.TraceRow) = .empty;
    defer starts.deinit(gpa);
    var stats: bz4.Stats = .{ .token_starts = &starts };
    const measured = try bz4.encode(gpa, &planned, &stats);
    defer gpa.free(measured);
    if (!std.mem.eql(u8, best, measured)) return error.BaselineMismatch;
    var chosen_feature: model_.Feature = .none;
    var chosen_count: usize = 0;
    var trials: usize = 1;
    const menu = [_]model_.Feature{ .suffix1, .suffix2, .suffix3, .suffix4,
        .previous_kind, .previous_length_bin, .second_base_row, .two_kinds,
        .kind_length, .suffix1_kind, .suffix2_kind, .previous_first_symbol };
    for (menu) |feature| {
        const scored = try candidates(gpa, starts.items, planned.model, feature);
        defer gpa.free(scored);
        if (scored.len == 0) continue;
        for ([_]usize{ 1, 4, 16, 64 }) |limit| {
            const count = @min(limit, scored.len);
            if (limit > 1 and count < limit / 2) continue;
            var trial_arena: std.heap.ArenaAllocator = .init(gpa);
            defer trial_arena.deinit();
            var candidate = try bz4.plan.baseline(trial_arena.allocator(), input, chosen_options);
            try apply(trial_arena.allocator(), &candidate, feature, scored, count);
            const frame = try bz4.encode(gpa, &candidate, null);
            trials += 1;
            if (frame.len < best.len) {
                gpa.free(best);
                best = frame;
                chosen_feature = feature;
                chosen_count = count;
            } else gpa.free(frame);
            if (count == scored.len) break;
        }
    }
    return .{ .bytes = best, .feature = chosen_feature, .selectors = chosen_count,
        .classes = fitted.classes, .trials = trials, .baseline_bytes = baseline_bytes };
}
