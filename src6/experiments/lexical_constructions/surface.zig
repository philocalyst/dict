//! Paid exact byte-surface programs. Copies name earlier lexemes and spans.
//! These are storage constructions, not automatically asserted linguistic analyses.
const std = @import("std");
const ans = @import("entropy.zig");
pub const Error = ans.Error || error{ InvalidConstruction, AllocationLimit };
pub const default_max_bytes: usize = 1024 * 1024;
pub const default_max_lexemes: usize = 100_000;
pub const absolute_max_bytes: usize = 32 * 1024 * 1024;
pub const Limits = struct { max_bytes: usize = default_max_bytes, max_lexemes: usize = default_max_lexemes, max_work: usize = ans.max_events };
const length_context: u32 = 899980;
const opcode_context: u32 = 900000;
const literal_length_context: u32 = 900010;
const donor_context: u32 = 900020;
const start_context: u32 = 900030;
const copy_length_context: u32 = 900040;
const bytes_context: u32 = 900100;
const History = struct { positions: [4]u32 = @splat(0), count: u8 = 0 };
pub const Stats = struct { literal_bytes: usize = 0, copied_bytes: usize = 0, copies: usize = 0, strings: usize = 0 };
fn donorAt(offsets: []const usize, position: usize) usize {
    var lo: usize = 0; var hi = offsets.len - 1;
    while (lo < hi) { const mid = lo + (hi - lo + 1) / 2; if (offsets[mid] <= position) lo = mid else hi = mid - 1; }
    return lo;
}
pub fn events(a: std.mem.Allocator, strings: []const []const u8, constructions: bool, stats: *Stats, limits: Limits) Error![]ans.Event {
    if (strings.len > limits.max_lexemes or limits.max_bytes > absolute_max_bytes) return error.WorkLimit;
    const offsets = try a.alloc(usize, strings.len + 1); defer a.free(offsets);
    offsets[0] = 0;
    for (strings, 0..) |s, i| {
        offsets[i + 1] = std.math.add(usize, offsets[i], s.len) catch return error.AllocationLimit;
        if (offsets[i + 1] > limits.max_bytes) return error.AllocationLimit;
    }
    var history: std.AutoHashMapUnmanaged(u64, History) = .empty; defer history.deinit(a);
    var out: std.ArrayList(ans.Event) = .empty; errdefer out.deinit(a);
    for (strings, 0..) |s, ordinal| {
        try ans.emitInteger(&out, a, length_context, s.len); stats.strings += 1;
        if (!constructions) {
            var previous: u8 = 0;
            for (s) |b| { try out.append(a, .{ .context = bytes_context + previous, .symbol = b }); previous = b; }
            stats.literal_bytes += s.len;
            continue;
        }
        var position: usize = 0; var literal_start: usize = 0;
        while (position < s.len) {
            var best_len: usize = 0; var best_donor: usize = 0; var best_start: usize = 0;
            if (s.len - position >= 8) {
                const key = std.mem.readInt(u64, s[position..][0..8], .little);
                if (history.get(key)) |bucket| for (bucket.positions[0..bucket.count]) |absolute| {
                    const donor = donorAt(offsets[0 .. ordinal + 1], absolute);
                    if (donor >= ordinal) return error.InvalidConstruction;
                    const start = absolute - offsets[donor]; const source = strings[donor];
                    var n: usize = 8;
                    while (n < source.len - start and n < s.len - position and source[start + n] == s[position + n]) : (n += 1) {}
                    if (n > best_len) { best_len = n; best_donor = donor; best_start = start; }
                };
            }
            if (best_len >= 12) {
                if (position != literal_start) try literal(&out, a, s[literal_start..position], stats);
                try out.append(a, .{ .context = opcode_context, .symbol = 1 });
                try ans.emitInteger(&out, a, donor_context, best_donor);
                try ans.emitInteger(&out, a, start_context, best_start);
                try ans.emitInteger(&out, a, copy_length_context, best_len);
                stats.copies += 1; stats.copied_bytes += best_len; position += best_len; literal_start = position;
            } else position += 1;
        }
        if (position != literal_start) try literal(&out, a, s[literal_start..position], stats);
        if (s.len >= 8) for (0..s.len - 7) |i| {
            const key = std.mem.readInt(u64, s[i..][0..8], .little);
            const e = try history.getOrPut(a, key);
            if (!e.found_existing) e.value_ptr.* = .{};
            if (e.value_ptr.count < 4) { e.value_ptr.positions[e.value_ptr.count] = @intCast(offsets[ordinal] + i); e.value_ptr.count += 1; }
            else { std.mem.copyForwards(u32, e.value_ptr.positions[0..3], e.value_ptr.positions[1..4]); e.value_ptr.positions[3] = @intCast(offsets[ordinal] + i); }
        };
    }
    if (out.items.len > ans.max_events or offsets[strings.len] > limits.max_work or out.items.len > limits.max_work - offsets[strings.len]) return error.WorkLimit;
    return out.toOwnedSlice(a);
}
fn literal(out: *std.ArrayList(ans.Event), a: std.mem.Allocator, bytes: []const u8, stats: *Stats) Error!void {
    try out.append(a, .{ .context = opcode_context, .symbol = 0 });
    try ans.emitInteger(out, a, literal_length_context, bytes.len);
    var previous: u8 = 0;
    for (bytes) |b| { try out.append(a, .{ .context = bytes_context + previous, .symbol = b }); previous = b; }
    stats.literal_bytes += bytes.len;
}
pub const Dictionary = struct {
    bytes: []u8, strings: []const []const u8,
    pub fn deinit(self: Dictionary, a: std.mem.Allocator) void { a.free(self.strings); a.free(self.bytes); }
};
pub fn decode(a: std.mem.Allocator, d: *ans.Decoder, count: usize, total_bytes: usize, constructions: bool, causal: bool, limits: Limits) Error!Dictionary {
    if (count > limits.max_lexemes or total_bytes > limits.max_bytes or total_bytes > absolute_max_bytes) return error.AllocationLimit;
    if (total_bytes > limits.max_work) return error.WorkLimit;
    // Every reconstructed byte, including overlap copies, pays one work unit
    // in addition to every entropy event. No tiny operand stream can evade
    // the caller's output-work bound by declaring an enormous expansion.
    d.event_limit = @min(d.event_limit, limits.max_work - total_bytes);
    const pool = try a.alloc(u8, total_bytes); errdefer a.free(pool);
    const strings = try a.alloc([]const u8, count); errdefer a.free(strings);
    var at: usize = 0;
    for (strings, 0..) |*target, ordinal| {
        const n64 = try d.integer(length_context);
        if (n64 > pool.len - at) return error.InvalidConstruction;
        const n: usize = @intCast(n64); target.* = pool[at..][0..n];
        var done: usize = 0;
        if (!constructions) {
            var previous: u8 = 0;
            while (done < n) : (done += 1) { const b = try d.byte(bytes_context + previous); pool[at + done] = b; previous = b; }
        } else while (done < n) {
            switch (try d.byte(opcode_context)) {
                0 => {
                    const size = try d.integer(literal_length_context);
                    if (size == 0 or size > n - done) return error.InvalidConstruction;
                    var previous: u8 = if (causal and at + done != 0) pool[at + done - 1] else 0;
                    for (0..@intCast(size)) |_| { const b = try d.byte(bytes_context + previous); pool[at + done] = b; done += 1; previous = b; }
                },
                1 => {
                    if (causal) return error.InvalidConstruction;
                    const donor = try d.integer(donor_context); const start = try d.integer(start_context); const size = try d.integer(copy_length_context);
                    if (donor >= ordinal or size == 0 or size > n - done) return error.InvalidConstruction;
                    const source = strings[@intCast(donor)];
                    if (start > source.len or size > source.len - start) return error.InvalidConstruction;
                    @memcpy(pool[at + done..][0..@intCast(size)], source[@intCast(start)..][0..@intCast(size)]); done += @intCast(size);
                },
                2 => {
                    if (!causal) return error.InvalidConstruction;
                    const distance = try d.integer(900060); const size = try d.integer(900070);
                    if (distance == 0 or distance > at + done or size == 0 or size > n - done) return error.InvalidConstruction;
                    // Positive backward distance makes overlap causal; every
                    // copied byte is already resolved when it is read.
                    for (0..@intCast(size)) |_| { pool[at + done] = pool[at + done - @as(usize, @intCast(distance))]; done += 1; }
                },
                else => return error.InvalidConstruction,
            }
        }
        at += n;
    }
    if (at != pool.len) return error.InvalidConstruction;
    return .{ .bytes = pool, .strings = strings };
}

test "exact surface donor programs include arbitrary bytes and paid literal fallback" {
    const a = std.testing.allocator;
    const strings = [_][]const u8{ "prefix-evlerimizden-tail", "evlerimizden-tail", "\xff\x00prefix-evlerimizden-tail", "" };
    inline for (.{false, true}) |programs| {
        var stats = Stats{}; const e = try events(a, &strings, programs, &stats, .{}); defer a.free(e);
        const model = try ans.Models.train(a, &.{e}, true); defer model.deinit(a);
        const wire = try ans.encode(a, e, model); defer a.free(wire);
        var total_bytes: usize = 0; for (strings) |s| { total_bytes += s.len; }
        var d = try ans.Decoder.init(wire, model); const dict = try decode(a, &d, strings.len, total_bytes, programs, false, .{}); defer dict.deinit(a);
        try d.finish(); for (strings, dict.strings) |x, y| try std.testing.expectEqualSlices(u8, x, y);
        if (programs) try std.testing.expect(stats.copies != 0);
    }
}

fn insert(a: std.mem.Allocator, history: *std.AutoHashMapUnmanaged(u32, History), pool: []const u8, at: usize) Error!void {
    if (pool.len - at < 4) return;
    const e = try history.getOrPut(a, std.mem.readInt(u32, pool[at..][0..4], .little));
    if (!e.found_existing) e.value_ptr.* = .{};
    if (e.value_ptr.count < 4) { e.value_ptr.positions[e.value_ptr.count] = @intCast(at); e.value_ptr.count += 1; }
    else { std.mem.copyForwards(u32, e.value_ptr.positions[0..3], e.value_ptr.positions[1..4]); e.value_ptr.positions[3] = @intCast(at); }
}
fn causalLiteral(out: *std.ArrayList(ans.Event), a: std.mem.Allocator, pool: []const u8, start: usize, end: usize, stats: *Stats) Error!void {
    try out.append(a, .{ .context = opcode_context, .symbol = 0 });
    try ans.emitInteger(out, a, literal_length_context, end - start);
    var previous: u8 = if (start == 0) 0 else pool[start - 1];
    for (pool[start..end]) |b| { try out.append(a, .{ .context = bytes_context + previous, .symbol = b }); previous = b; }
    stats.literal_bytes += end - start;
}
pub fn causalEvents(a: std.mem.Allocator, strings: []const []const u8, stats: *Stats, limits: Limits) Error![]ans.Event {
    if (strings.len > limits.max_lexemes or limits.max_bytes > absolute_max_bytes) return error.WorkLimit;
    var pool: std.ArrayList(u8) = .empty; defer pool.deinit(a);
    for (strings) |s| {
        if (s.len > limits.max_bytes - pool.items.len) return error.AllocationLimit;
        try pool.appendSlice(a, s);
    }
    var history: std.AutoHashMapUnmanaged(u32, History) = .empty; defer history.deinit(a);
    var out: std.ArrayList(ans.Event) = .empty; errdefer out.deinit(a);
    var begin: usize = 0;
    for (strings) |s| {
        try ans.emitInteger(&out, a, length_context, s.len); stats.strings += 1;
        const end = begin + s.len; var position = begin; var literal_start = begin;
        while (position < end) {
            var best_len: usize = 0; var best_distance: usize = 0;
            if (end - position >= 4) {
                const key = std.mem.readInt(u32, pool.items[position..][0..4], .little);
                if (history.get(key)) |bucket| for (bucket.positions[0..bucket.count]) |donor| {
                    if (donor >= position) return error.InvalidConstruction;
                    var n: usize = 4;
                    while (n < end - position and pool.items[donor + n] == pool.items[position + n]) : (n += 1) {}
                    if (n > best_len or (n == best_len and position - donor < best_distance)) { best_len = n; best_distance = position - donor; }
                };
            }
            if (best_len >= 6) {
                if (position != literal_start) try causalLiteral(&out, a, pool.items, literal_start, position, stats);
                try out.append(a, .{ .context = opcode_context, .symbol = 2 });
                try ans.emitInteger(&out, a, 900060, best_distance); try ans.emitInteger(&out, a, 900070, best_len);
                stats.copies += 1; stats.copied_bytes += best_len;
                for (position..position + best_len) |i| try insert(a, &history, pool.items, i);
                position += best_len; literal_start = position;
            } else { try insert(a, &history, pool.items, position); position += 1; }
        }
        if (position != literal_start) try causalLiteral(&out, a, pool.items, literal_start, position, stats);
        begin = end;
    }
    if (out.items.len > ans.max_events or pool.items.len > limits.max_work or out.items.len > limits.max_work - pool.items.len) return error.WorkLimit;
    return out.toOwnedSlice(a);
}
test "causal surface programs copy inside a lexeme, overlap and cross boundaries exactly" {
    const a = std.testing.allocator;
    const strings = [_][]const u8{ "abcabcabcabcabcabcabcabc", "abcabcabcabcabcabcabcabc\xff\x00", "<word key=\"ev\">ev</word><word key=\"ev\">ev</word>" };
    var stats = Stats{}; const e = try causalEvents(a, &strings, &stats, .{}); defer a.free(e);
    const models = try ans.Models.train(a, &.{e}, true); defer models.deinit(a);
    const encoded = try ans.encode(a, e, models); defer a.free(encoded);
    var d = try ans.Decoder.init(encoded, models); var bytes: usize = 0; for (strings) |s| { bytes += s.len; }
    const dict = try decode(a, &d, strings.len, bytes, true, true, .{}); defer dict.deinit(a); try d.finish();
    for (strings, dict.strings) |x, y| try std.testing.expectEqualSlices(u8, x, y);
    try std.testing.expect(stats.copied_bytes > strings[0].len);
    const bad_events = [_]ans.Event{ .{ .context = length_context, .symbol = 1 }, .{ .context = opcode_context, .symbol = 2 }, .{ .context = 900060, .symbol = 0 }, .{ .context = 900070, .symbol = 1 } };
    const bad_model = try ans.Models.train(a, &.{&bad_events}, true); defer bad_model.deinit(a);
    const bad = try ans.encode(a, &bad_events, bad_model); defer a.free(bad); var bad_d = try ans.Decoder.init(bad, bad_model);
    try std.testing.expectError(error.InvalidConstruction, decode(a, &bad_d, 1, 1, true, true, .{}));
    var bounded_d = try ans.Decoder.init(encoded, models);
    try std.testing.expectError(error.WorkLimit, decode(a, &bounded_d, strings.len, bytes, true, true, .{ .max_work = bytes }));
}
test "causal storage grammar preserves arbitrary byte histories and empty lexemes" {
    const a = std.testing.allocator;
    var storage: [32][96]u8 = undefined;
    var strings: [34][]const u8 = undefined;
    var state: u32 = 0x5a12beef;
    for (&storage, 0..) |*bytes, i| {
        for (bytes, 0..) |*b, j| {
            state = state *% 1664525 +% 1013904223;
            b.* = if (i != 0 and j < 40) storage[i - 1][j] else if (j >= 48) bytes[j % 16] else @truncate(state >> 16);
        }
        strings[i] = bytes;
    }
    strings[32] = ""; strings[33] = "\xff\x00\xff\x00\xff\x00\xff\x00";
    var stats = Stats{}; const e = try causalEvents(a, &strings, &stats, .{}); defer a.free(e);
    const models = try ans.Models.train(a, &.{e}, true); defer models.deinit(a);
    const encoded = try ans.encode(a, e, models); defer a.free(encoded);
    var d = try ans.Decoder.init(encoded, models);
    const dict = try decode(a, &d, strings.len, 32 * 96 + strings[33].len, true, true, .{}); defer dict.deinit(a); try d.finish();
    for (strings, dict.strings) |x, y| try std.testing.expectEqualSlices(u8, x, y);
    try std.testing.expect(stats.copied_bytes != 0);
}
