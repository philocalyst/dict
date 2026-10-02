//! Direct byte-symbol context rANS; every probability and context override is paid.
const std = @import("std");
pub const Error = error{ OutOfMemory, InvalidEntropy, WorkLimit, Truncated, IntegerOverflow, NonCanonicalVarint };
pub const Event = struct { context: u32, symbol: u8 };
pub const lower: u32 = 1 << 23;
pub const scale: u5 = 12;
pub const total: u32 = 1 << scale;
pub const max_events: usize = 8_000_000;
pub const max_models: usize = 8192;
fn integerBytes(input: u64) usize { var n = input; var count: usize = 1; while (n >= 128) : (n >>= 7) count += 1; return count; }

pub fn varint(out: *std.ArrayList(u8), a: std.mem.Allocator, value: u64) Error!void {
    var x = value;
    while (x >= 128) : (x >>= 7) try out.append(a, @as(u8, @truncate(x)) | 128);
    try out.append(a, @intCast(x));
}
pub const Cursor = struct {
    bytes: []const u8,
    at: usize = 0,
    pub fn byte(self: *Cursor) Error!u8 {
        if (self.at >= self.bytes.len) return error.Truncated;
        const b = self.bytes[self.at]; self.at += 1; return b;
    }
    pub fn take(self: *Cursor, n: usize) Error![]const u8 {
        if (n > self.bytes.len - self.at) return error.Truncated;
        const b = self.bytes[self.at..][0..n]; self.at += n; return b;
    }
    pub fn integer(self: *Cursor) Error!u64 {
        var n: u64 = 0;
        for (0..10) |i| {
            const b = try self.byte();
            if (i == 9 and b > 1) return error.IntegerOverflow;
            n |= @as(u64, b & 127) << @as(u6, @intCast(i * 7));
            if (b < 128) { if (i != 0 and b == 0) return error.NonCanonicalVarint; return n; }
        }
        return error.IntegerOverflow;
    }
};

pub const Model = struct {
    frequency: [256]u16 = @splat(0),
    cumulative: [256]u16 = @splat(0),
    fn finish(self: *Model) Error!void {
        var sum: u32 = 0;
        for (&self.cumulative, self.frequency) |*c, f| {
            if (sum > total or @as(u32, f) > total - sum) return error.InvalidEntropy;
            c.* = @intCast(sum); sum += f;
        }
        if (sum != total) return error.InvalidEntropy;
    }
    fn train(counts: [256]u64) Model {
        var m = Model{}; var n: u64 = 0; var symbols: u32 = 0;
        for (counts) |c| { n += c; symbols += @intFromBool(c != 0); }
        if (n == 0) { m.frequency[0] = total; m.finish() catch unreachable; return m; }
        var used: u32 = 0;
        var remainder: [256]u64 = @splat(0);
        for (counts, 0..) |c, i| if (c != 0) {
            const numerator = c * (total - symbols);
            m.frequency[i] = @intCast(1 + numerator / n);
            remainder[i] = numerator % n;
            used += m.frequency[i];
        };
        while (used < total) : (used += 1) {
            var best: usize = 0;
            for (0..256) |i| if (remainder[i] > remainder[best]) { best = i; };
            m.frequency[best] += 1; remainder[best] = 0;
        }
        m.finish() catch unreachable; return m;
    }
    fn write(self: *const Model, out: *std.ArrayList(u8), a: std.mem.Allocator) Error!void {
        var count: usize = 0; for (self.frequency) |f| { count += @intFromBool(f != 0); }
        try varint(out, a, count);
        for (self.frequency, 0..) |f, i| if (f != 0) {
            try out.append(a, @intCast(i)); try varint(out, a, f);
        };
    }
    fn read(c: *Cursor) Error!Model {
        const n = try c.integer(); if (n == 0 or n > 256) return error.InvalidEntropy;
        var m = Model{}; var prior: ?u8 = null;
        for (0..@intCast(n)) |_| {
            const s = try c.byte(); if (prior != null and s <= prior.?) return error.InvalidEntropy;
            const f = try c.integer(); if (f == 0 or f > total) return error.InvalidEntropy;
            m.frequency[s] = @intCast(f); prior = s;
        }
        try m.finish(); return m;
    }
    fn bytes(self: *const Model) usize {
        var symbols: u64 = 0; var result: usize = 0;
        for (self.frequency) |f| if (f != 0) { symbols += 1; result += 1 + integerBytes(f); };
        result += integerBytes(symbols);
        return result;
    }
    fn bits(self: *const Model, counts: [256]u64) f64 {
        var result: f64 = 0;
        for (counts, self.frequency) |c, f| if (c != 0) {
            if (f == 0) return std.math.inf(f64);
            result += @as(f64, @floatFromInt(c)) * (12 - @log2(@as(f64, @floatFromInt(f))));
        };
        return result;
    }
};
const Override = struct { context: u32, model: Model };
pub const Models = struct {
    global: Model,
    overrides: []const Override,
    pub fn get(self: *const Models, context: u32) *const Model {
        var lo: usize = 0; var hi = self.overrides.len;
        while (lo < hi) { const mid = lo + (hi - lo) / 2; if (self.overrides[mid].context < context) lo = mid + 1 else hi = mid; }
        if (lo < self.overrides.len and self.overrides[lo].context == context) return &self.overrides[lo].model;
        return &self.global;
    }
    pub fn train(a: std.mem.Allocator, streams: []const []const Event, use_contexts: bool) Error!Models {
        var global: [256]u64 = @splat(0);
        var counts: std.AutoHashMapUnmanaged(u32, [256]u64) = .empty;
        defer counts.deinit(a);
        var events: usize = 0;
        for (streams) |s| for (s) |e| {
            events += 1; if (events > max_events) return error.WorkLimit;
            global[e.symbol] += 1;
            if (use_contexts) {
                const entry = try counts.getOrPut(a, e.context);
                if (!entry.found_existing) entry.value_ptr.* = @splat(0);
                entry.value_ptr[e.symbol] += 1;
                if (counts.count() > max_models) return error.WorkLimit;
            }
        };
        const base = Model.train(global);
        var overrides: std.ArrayList(Override) = .empty;
        errdefer overrides.deinit(a);
        var it = counts.iterator();
        while (it.next()) |entry| {
            const m = Model.train(entry.value_ptr.*);
            // Cost-aware proposal; the complete encoded frame still competes.
            if (base.bits(entry.value_ptr.*) - m.bits(entry.value_ptr.*) > @as(f64, @floatFromInt((m.bytes() + integerBytes(entry.key_ptr.*) + 1) * 8)))
                try overrides.append(a, .{ .context = entry.key_ptr.*, .model = m });
        }
        std.mem.sort(Override, overrides.items, {}, struct { fn less(_: void, x: Override, y: Override) bool { return x.context < y.context; } }.less);
        return .{ .global = base, .overrides = try overrides.toOwnedSlice(a) };
    }
    pub fn write(self: Models, out: *std.ArrayList(u8), a: std.mem.Allocator) Error!void {
        try self.global.write(out, a); try varint(out, a, self.overrides.len);
        for (self.overrides) |o| { try varint(out, a, o.context); try o.model.write(out, a); }
    }
    pub fn read(a: std.mem.Allocator, bytes: []const u8) Error!Models {
        var c = Cursor{ .bytes = bytes }; const global = try Model.read(&c);
        const n = try c.integer(); if (n > max_models) return error.WorkLimit;
        const overrides = try a.alloc(Override, @intCast(n)); errdefer a.free(overrides);
        var prior: ?u32 = null;
        for (overrides) |*o| {
            const context = try c.integer(); if (context > 1_000_000 or (prior != null and context <= prior.?)) return error.InvalidEntropy;
            o.* = .{ .context = @intCast(context), .model = try Model.read(&c) }; prior = o.context;
        }
        if (c.at != bytes.len) return error.InvalidEntropy;
        return .{ .global = global, .overrides = overrides };
    }
    pub fn deinit(self: Models, a: std.mem.Allocator) void { a.free(self.overrides); }
    pub fn ownedHeapBytes(self: Models) usize { return self.overrides.len * @sizeOf(Override); }
};

pub fn encode(a: std.mem.Allocator, events: []const Event, models: Models) Error![]u8 {
    if (events.len > max_events) return error.WorkLimit;
    var renormalized: std.ArrayList(u8) = .empty; defer renormalized.deinit(a);
    var state: u32 = lower;
    var i = events.len;
    while (i != 0) {
        i -= 1; const e = events[i]; const m = models.get(e.context);
        const f: u32 = m.frequency[e.symbol]; const c: u32 = m.cumulative[e.symbol];
        if (f == 0) return error.InvalidEntropy;
        const ceiling: u64 = @as(u64, ((lower >> scale) << 8)) * f;
        while (state >= ceiling) { try renormalized.append(a, @truncate(state)); state >>= 8; }
        state = @intCast((@as(u64, state / f) << scale) + state % f + c);
    }
    const out = try a.alloc(u8, 4 + renormalized.items.len);
    std.mem.writeInt(u32, out[0..4], state, .little);
    for (renormalized.items, 0..) |b, j| out[out.len - 1 - j] = b;
    return out;
}
pub const Decoder = struct {
    bytes: []const u8, at: usize = 4, state: u32, models: Models, events: usize = 0, event_limit: usize = max_events,
    pub fn init(bytes: []const u8, models: Models) Error!Decoder {
        if (bytes.len < 4) return error.Truncated;
        const s = std.mem.readInt(u32, bytes[0..4], .little);
        if (s < lower or s >= @as(u32, lower) * 256) return error.InvalidEntropy;
        return .{ .bytes = bytes, .state = s, .models = models };
    }
    pub fn byte(self: *Decoder, context: u32) Error!u8 {
        self.events += 1; if (self.events > self.event_limit or self.events > max_events) return error.WorkLimit;
        const m = self.models.get(context); const slot = self.state & (total - 1);
        var lo: usize = 0; var hi: usize = 256;
        while (lo < hi) { const mid = lo + (hi - lo) / 2; if (m.cumulative[mid] <= slot) lo = mid + 1 else hi = mid; }
        if (lo == 0) return error.InvalidEntropy;
        const symbol: u8 = @intCast(lo - 1);
        if (m.frequency[symbol] == 0 or slot >= @as(u32, m.cumulative[symbol]) + m.frequency[symbol]) return error.InvalidEntropy;
        self.state = @intCast(@as(u64, m.frequency[symbol]) * (self.state >> scale) + slot - m.cumulative[symbol]);
        while (self.state < lower) {
            if (self.at >= self.bytes.len) return error.Truncated;
            self.state = (self.state << 8) | self.bytes[self.at]; self.at += 1;
        }
        return symbol;
    }
    pub fn integer(self: *Decoder, context: u32) Error!u64 {
        var n: u64 = 0;
        for (0..10) |i| {
            const b = try self.byte(context + @as(u32, @intCast(i)));
            if (i == 9 and b > 1) return error.IntegerOverflow;
            n |= @as(u64, b & 127) << @as(u6, @intCast(i * 7));
            if (b < 128) { if (i != 0 and b == 0) return error.NonCanonicalVarint; return n; }
        }
        return error.IntegerOverflow;
    }
    pub fn finish(self: Decoder) Error!void { if (self.at != self.bytes.len or self.state != lower) return error.InvalidEntropy; }
};
pub fn emitInteger(out: *std.ArrayList(Event), a: std.mem.Allocator, context: u32, input: u64) Error!void {
    var n = input; var plane: u32 = 0;
    while (n >= 128) : ({ n >>= 7; plane += 1; }) try out.append(a, .{ .context = context + plane, .symbol = @as(u8, @truncate(n)) | 128 });
    try out.append(a, .{ .context = context + plane, .symbol = @intCast(n) });
    if (out.items.len > max_events) return error.WorkLimit;
}

test "model pointers borrow the selected owner, including independent decoder copies" {
    const a = std.testing.allocator;
    const events = [_]Event{ .{ .context = 0, .symbol = 1 }, .{ .context = 0, .symbol = 2 } };
    const models = try Models.train(a, &.{&events}, false); defer models.deinit(a);
    try std.testing.expect(models.get(123) == &models.global);
    // Immutable copies may share storage. A distinct mutable owner must retain
    // its own inline model and cannot mutate the first owner's frequencies.
    var copy = models;
    const original = models.global.frequency[1]; copy.global.frequency[1] += 1;
    try std.testing.expectEqual(original, models.global.frequency[1]);
    try std.testing.expect(copy.get(123) == &copy.global);
    try std.testing.expect(copy.get(123) != models.get(123));
    const encoded = try encode(a, &events, models); defer a.free(encoded);
    var d = try Decoder.init(encoded, models);
    try std.testing.expect(d.models.get(123) == &d.models.global);
    for (events) |e| try std.testing.expectEqual(e.symbol, try d.byte(e.context));
    try d.finish();
}
test "context rANS exact independent streams, corrupt tails and invalid models" {
    const a = std.testing.allocator;
    const events = [_]Event{ .{ .context = 1, .symbol = 17 }, .{ .context = 2, .symbol = 0 }, .{ .context = 1, .symbol = 42 }, .{ .context = 2, .symbol = 0 } };
    const models = try Models.train(a, &.{&events}, true); defer models.deinit(a);
    var wire: std.ArrayList(u8) = .empty; defer wire.deinit(a); try models.write(&wire, a);
    const decoded_models = try Models.read(a, wire.items); defer decoded_models.deinit(a);
    const stream = try encode(a, &events, decoded_models); defer a.free(stream);
    var d = try Decoder.init(stream, decoded_models);
    for (events) |e| try std.testing.expectEqual(e.symbol, try d.byte(e.context));
    try d.finish(); try std.testing.expectError(error.Truncated, Decoder.init(stream[0..3], models));
    try std.testing.expectError(error.InvalidEntropy, Models.read(a, &.{0}));
    // Both frequencies are individually legal, but their sum is not.
    try std.testing.expectError(error.InvalidEntropy, Models.read(a, &.{ 2, 0, 128, 32, 1, 128, 32, 0 }));
}
