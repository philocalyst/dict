const std = @import("std");
const bytes = @import("bytes.zig");
const columns = @import("columns.zig");
const model = @import("model.zig");

pub const Error = columns.Error || error{ InvalidString, OutputTooSmall, WorkLimitExceeded };
const literal_count: u32 = 256;
const max_rules: usize = 256;
const max_depth: usize = 256;
const max_build_work: usize = 512 * 1024 * 1024;
const pair_sample_budget: usize = 1024 * 1024;
const max_expanded_bytes: usize = 256 * 1024 * 1024;
const max_collision_work: usize = 16 * 1024 * 1024;
const hash_base: u64 = 0x9e3779b185ebca87;

const Rule = struct { left: u32, right: u32, length: u32 };
const Item = struct { token_end: u32, data_end: u32, length: u32 };
const Token = struct { symbol: u32 };
const Rules = columns.Records(Rule);
const Items = columns.Records(Item);
const Tokens = columns.Records(Token);
const Parts = struct { rules: void, items: void, tokens: void, data: void };
pub const Owned = bytes.Owned;

pub const Builder = struct {
    map: std.StringHashMapUnmanaged(model.StringId) = .empty,
    values: std.ArrayList([]const u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        self.map.deinit(self.allocator);
        self.values.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn intern(self: *Builder, value: []const u8) Error!model.StringId {
        if (self.map.get(value)) |existing| return existing;
        const id = model.StringId.fromIndex(self.values.items.len) catch return error.InvalidString;
        try self.values.append(self.allocator, value);
        errdefer _ = self.values.pop();
        try self.map.put(self.allocator, value, id);
        return id;
    }

    pub fn build(self: *const Builder, allocator: std.mem.Allocator) Error!Owned {
        var literal = try buildLiteral(allocator, self.values.items);
        errdefer literal.deinit();

        var sequences = try allocator.alloc(std.ArrayList(u32), self.values.items.len);
        defer allocator.free(sequences);
        for (sequences) |*sequence| sequence.* = .empty;
        defer for (sequences) |*sequence| sequence.deinit(allocator);
        var total_symbols: usize = 0;
        for (self.values.items, 0..) |value, index| {
            total_symbols = std.math.add(usize, total_symbols, value.len) catch return error.Overflow;
            try sequences[index].ensureTotalCapacity(allocator, value.len);
            for (value) |byte| sequences[index].appendAssumeCapacity(byte);
        }

        var rules: std.ArrayList(Rule) = .empty;
        defer rules.deinit(allocator);
        var work: usize = 0;
        while (rules.items.len < max_rules) {
            const stride = @max(@as(usize, 1), std.math.divCeil(usize, total_symbols, pair_sample_budget) catch return error.WorkLimitExceeded);
            const sampled_work = std.math.divCeil(usize, total_symbols, stride) catch return error.WorkLimitExceeded;
            work = std.math.add(usize, work, sampled_work) catch return error.WorkLimitExceeded;
            work = std.math.add(usize, work, total_symbols) catch return error.WorkLimitExceeded;
            if (work > max_build_work) break;
            var counts: std.AutoHashMapUnmanaged(u64, u32) = .empty;
            defer counts.deinit(allocator);
            for (sequences) |sequence| {
                if (sequence.items.len < 2) continue;
                var index: usize = 0;
                while (index + 1 < sequence.items.len) : (index += stride) {
                    const key = pairKey(sequence.items[index], sequence.items[index + 1]);
                    const entry = try counts.getOrPut(allocator, key);
                    if (!entry.found_existing) entry.value_ptr.* = 0;
                    entry.value_ptr.* = std.math.add(u32, entry.value_ptr.*, 1) catch return error.WorkLimitExceeded;
                }
            }
            var best_key: u64 = 0;
            var best_count: u32 = 2;
            var iterator = counts.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.* > best_count or
                    (entry.value_ptr.* == best_count and entry.key_ptr.* < best_key))
                {
                    best_key = entry.key_ptr.*;
                    best_count = entry.value_ptr.*;
                }
            }
            if (best_count < 3) break;
            const left: u32 = @intCast(best_key >> 32);
            const right: u32 = @truncate(best_key);
            const length = std.math.add(u32, symbolLength(left, rules.items), symbolLength(right, rules.items)) catch break;
            const replacement = std.math.add(u32, literal_count, @as(u32, @intCast(rules.items.len))) catch break;
            var replaced: usize = 0;
            for (sequences) |*sequence| {
                var read: usize = 0;
                var write: usize = 0;
                while (read < sequence.items.len) {
                    if (read + 1 < sequence.items.len and sequence.items[read] == left and sequence.items[read + 1] == right) {
                        sequence.items[write] = replacement;
                        write += 1;
                        read += 2;
                        replaced += 1;
                    } else {
                        sequence.items[write] = sequence.items[read];
                        write += 1;
                        read += 1;
                    }
                }
                sequence.shrinkRetainingCapacity(write);
            }
            if (replaced < 2) break;
            total_symbols -= replaced;
            try rules.append(allocator, .{ .left = left, .right = right, .length = length });
        }

        const slices = try allocator.alloc([]const u32, sequences.len);
        defer allocator.free(slices);
        for (sequences, 0..) |sequence, index| slices[index] = sequence.items;
        var grammar = try buildCandidate(allocator, self.values.items, rules.items, slices);
        if (grammar.bytes.len < literal.bytes.len) {
            literal.deinit();
            return grammar;
        }
        grammar.deinit();
        return literal;
    }
};

fn pairKey(left: u32, right: u32) u64 {
    return (@as(u64, left) << 32) | right;
}

fn symbolLength(symbol: u32, rules: []const Rule) u32 {
    return if (symbol < literal_count) 1 else rules[symbol - literal_count].length;
}

fn buildLiteral(allocator: std.mem.Allocator, values: []const []const u8) Error!Owned {
    return buildCandidate(allocator, values, &.{}, &.{});
}

fn buildCandidate(allocator: std.mem.Allocator, values: []const []const u8, rules: []const Rule, sequences: []const []const u32) Error!Owned {
    const items = try allocator.alloc(Item, values.len);
    defer allocator.free(items);
    var token_count: usize = 0;
    var data_count: usize = 0;
    const literal_mode = sequences.len == 0;
    for (values, 0..) |value, index| {
        if (literal_mode) {
            data_count = std.math.add(usize, data_count, value.len) catch return error.Overflow;
        } else {
            token_count = std.math.add(usize, token_count, sequences[index].len) catch return error.Overflow;
        }
        if (token_count > std.math.maxInt(u32) or data_count > std.math.maxInt(u32) or value.len > std.math.maxInt(u32)) return error.InvalidString;
        items[index] = .{ .token_end = @intCast(token_count), .data_end = @intCast(data_count), .length = @intCast(value.len) };
    }
    const tokens = try allocator.alloc(Token, token_count);
    defer allocator.free(tokens);
    var token_index: usize = 0;
    for (sequences) |sequence| for (sequence) |symbol| {
        tokens[token_index] = .{ .symbol = symbol };
        token_index += 1;
    };
    const data = try allocator.alloc(u8, data_count);
    defer allocator.free(data);
    var data_index: usize = 0;
    if (literal_mode) for (values) |value| {
        @memcpy(data[data_index..][0..value.len], value);
        data_index += value.len;
    };
    var rule_store = try Rules.build(allocator, rules);
    defer rule_store.deinit();
    var item_store = try Items.build(allocator, items);
    defer item_store.deinit();
    var token_store = try Tokens.build(allocator, tokens);
    defer token_store.deinit();
    return bytes.Bundle(Parts).build(allocator, .{
        .rules = rule_store.bytes,
        .items = item_store.bytes,
        .tokens = token_store.bytes,
        .data = data,
    });
}

pub fn ViewFor(comptime Source: type) type {
    const Span = bytes.Span(Source);
    return struct {
        rules: Rules.ViewFor(Span),
        items: Items.ViewFor(Span),
        tokens: Tokens.ViewFor(Span),
        data: Span,

        const Self = @This();
        pub const ReadError = Error || bytes.SourceError(Source);

        pub fn open(source: Source) ReadError!Self {
            const bundle = try bytes.Bundle(Parts).ViewFor(Source).open(source);
            return .{
                .rules = try Rules.ViewFor(Span).open(bundle.part(.rules)),
                .items = try Items.ViewFor(Span).open(bundle.part(.items)),
                .tokens = try Tokens.ViewFor(Span).open(bundle.part(.tokens)),
                .data = bundle.part(.data),
            };
        }

        pub fn count(self: *const Self) usize {
            return self.items.row_count;
        }

        pub fn text(self: *const Self, id: model.StringId) TextFor(Source) {
            return .{ .pool = self.*, .id = id };
        }

        pub fn eqlBytes(self: *const Self, id: model.StringId, wanted: []const u8) ReadError!bool {
            return self.text(id).eqlBytes(wanted);
        }

        pub fn orderBytes(self: *const Self, id: model.StringId, wanted: []const u8) ReadError!std.math.Order {
            return self.text(id).orderBytes(wanted);
        }

        pub fn order(self: *const Self, left: model.StringId, right: model.StringId) ReadError!std.math.Order {
            var left_cursor = try self.text(left).cursor();
            var right_cursor = try self.text(right).cursor();
            while (true) {
                const left_byte = try left_cursor.next();
                const right_byte = try right_cursor.next();
                if (left_byte == null or right_byte == null) {
                    if (left_byte == right_byte) return .eq;
                    return if (left_byte == null) .lt else .gt;
                }
                if (left_byte.? != right_byte.?) return std.math.order(left_byte.?, right_byte.?);
            }
        }

        pub fn eql(self: *const Self, left: model.StringId, right: model.StringId) ReadError!bool {
            if (try self.items.field(.length, @intFromEnum(left)) != try self.items.field(.length, @intFromEnum(right))) return false;
            var left_cursor = try self.text(left).cursor();
            var right_cursor = try self.text(right).cursor();
            while (true) {
                const left_byte = try left_cursor.next();
                const right_byte = try right_cursor.next();
                if (left_byte == null or right_byte == null) return left_byte == right_byte;
                if (left_byte.? != right_byte.?) return false;
            }
        }

        pub fn verify(self: *const Self, allocator: std.mem.Allocator) (ReadError || std.mem.Allocator.Error)!void {
            return self.verifyWithHashMask(allocator, std.math.maxInt(u64));
        }

        fn verifyWithHashMask(self: *const Self, allocator: std.mem.Allocator, hash_mask: u64) (ReadError || std.mem.Allocator.Error)!void {
            try self.rules.verify(.{});
            try self.items.verify(.{});
            try self.tokens.verify(.{});
            if (self.rules.row_count > max_rules) return error.InvalidString;

            const depths = try allocator.alloc(u16, self.rules.row_count);
            defer allocator.free(depths);
            const summaries = try allocator.alloc(Summary, self.rules.row_count);
            defer allocator.free(summaries);
            const used = try allocator.alloc(bool, self.rules.row_count);
            defer allocator.free(used);
            @memset(used, false);
            for (0..self.rules.row_count) |index| {
                const rule = try self.rules.row(index);
                const limit = std.math.add(usize, literal_count, index) catch return error.Overflow;
                if (rule.left >= limit or rule.right >= limit) return error.InvalidString;
                const left_summary = try symbolSummary(rule.left, summaries[0..index], hash_mask);
                const right_summary = try symbolSummary(rule.right, summaries[0..index], hash_mask);
                const summary = try combine(left_summary, right_summary, hash_mask);
                if (rule.length != summary.length) return error.InvalidString;
                const depth = std.math.add(u16, @max(verifiedDepth(rule.left, depths[0..index]), verifiedDepth(rule.right, depths[0..index])), 1) catch return error.InvalidString;
                if (depth > max_depth) return error.InvalidString;
                depths[index] = depth;
                summaries[index] = summary;
                if (rule.left >= literal_count) used[rule.left - literal_count] = true;
                if (rule.right >= literal_count) used[rule.right - literal_count] = true;
                for (0..index) |prior| {
                    const previous = try self.rules.row(prior);
                    if (previous.left == rule.left and previous.right == rule.right) return error.InvalidString;
                }
            }

            var previous_end: u32 = 0;
            var previous_data_end: u32 = 0;
            var total_expanded: usize = 0;
            var item_summaries = try allocator.alloc(Summary, self.items.row_count);
            defer allocator.free(item_summaries);
            for (0..self.items.row_count) |index| {
                const item = try self.items.row(index);
                if (item.token_end < previous_end or item.token_end > self.tokens.row_count or
                    item.data_end < previous_data_end or item.data_end > self.data.size)
                    return error.InvalidString;
                const token_changed = item.token_end != previous_end;
                const data_changed = item.data_end != previous_data_end;
                if (token_changed and data_changed) return error.InvalidString;
                var measured: u32 = 0;
                var summary: Summary = .{};
                if (data_changed) {
                    measured = item.data_end - previous_data_end;
                    const value = try self.data.bytes(previous_data_end, measured);
                    for (value) |byte| summary = try combine(summary, byteSummary(byte, hash_mask), hash_mask);
                } else {
                    for (previous_end..item.token_end) |position| {
                        const symbol = try self.tokens.field(.symbol, position);
                        if (symbol >= literal_count + self.rules.row_count) return error.InvalidString;
                        const symbol_summary = try symbolSummary(symbol, summaries, hash_mask);
                        measured = std.math.add(u32, measured, symbol_summary.length) catch return error.InvalidString;
                        summary = try combine(summary, symbol_summary, hash_mask);
                        if (symbol >= literal_count) used[symbol - literal_count] = true;
                    }
                }
                if (measured != item.length) return error.InvalidString;
                if (summary.length != item.length) return error.InvalidString;
                item_summaries[index] = summary;
                total_expanded = std.math.add(usize, total_expanded, item.length) catch return error.InvalidString;
                if (total_expanded > max_expanded_bytes) return error.InvalidString;
                previous_end = item.token_end;
                previous_data_end = item.data_end;
            }
            if (previous_end != self.tokens.row_count or previous_data_end != self.data.size) return error.InvalidString;
            for (used) |is_used| if (!is_used) return error.InvalidString;

            var fingerprints: std.AutoHashMapUnmanaged(Fingerprint, model.StringId) = .empty;
            defer fingerprints.deinit(allocator);
            const next = try allocator.alloc(?model.StringId, self.items.row_count);
            defer allocator.free(next);
            @memset(next, null);
            var collision_work: usize = 0;
            for (item_summaries, 0..) |summary, index| {
                const fingerprint: Fingerprint = .{ .length = summary.length, .hash = summary.hash };
                const result = try fingerprints.getOrPut(allocator, fingerprint);
                const id: model.StringId = @enumFromInt(index);
                if (!result.found_existing) {
                    result.value_ptr.* = id;
                    continue;
                }
                var prior: ?model.StringId = result.value_ptr.*;
                while (prior) |prior_id| {
                    collision_work = std.math.add(usize, collision_work, summary.length) catch return error.WorkLimitExceeded;
                    if (collision_work > max_collision_work) return error.WorkLimitExceeded;
                    if (try self.eql(prior_id, id)) return error.InvalidString;
                    prior = next[@intFromEnum(prior_id)];
                }
                next[index] = result.value_ptr.*;
                result.value_ptr.* = id;
            }
        }
    };
}

const Summary = struct { length: u32 = 0, hash: u64 = 0, power: u64 = 1 };
const Fingerprint = struct { length: u32, hash: u64 };

fn byteSummary(byte: u8, mask: u64) Summary {
    return .{ .length = 1, .hash = (@as(u64, byte) + 1) & mask, .power = hash_base & mask };
}

fn combine(left: Summary, right: Summary, mask: u64) Error!Summary {
    return .{
        .length = std.math.add(u32, left.length, right.length) catch return error.InvalidString,
        .hash = (left.hash *% right.power +% right.hash) & mask,
        .power = (left.power *% right.power) & mask,
    };
}

fn symbolSummary(symbol: u32, summaries: []const Summary, mask: u64) Error!Summary {
    if (symbol < literal_count) return byteSummary(@intCast(symbol), mask);
    const index = symbol - literal_count;
    if (index >= summaries.len) return error.InvalidString;
    return summaries[index];
}

fn verifiedDepth(symbol: u32, depths: []const u16) u16 {
    if (symbol < literal_count) return 0;
    return depths[symbol - literal_count];
}

pub fn TextFor(comptime Source: type) type {
    return struct {
        pool: ViewFor(Source),
        id: model.StringId,

        const Self = @This();
        pub const ReadError = ViewFor(Source).ReadError;

        pub fn byteLength(self: *const Self) ReadError!usize {
            return (try self.item()).length;
        }

        pub fn contiguous(self: *const Self) ReadError!?[]const u8 {
            const bounds = try self.itemBounds();
            if (!bounds.literal) return null;
            return @as(?[]const u8, try self.pool.data.bytes(bounds.data_start, bounds.item.data_end - bounds.data_start));
        }

        pub fn render(self: *const Self, output: []u8) ReadError![]const u8 {
            const length = try self.byteLength();
            if (output.len < length) return error.OutputTooSmall;
            return self.write(output[0..length], true);
        }

        pub fn snippet(self: *const Self, output: []u8) ReadError![]const u8 {
            return self.write(output, false);
        }

        pub fn eqlBytes(self: *const Self, wanted: []const u8) ReadError!bool {
            if (try self.byteLength() != wanted.len) return false;
            if (try self.contiguous()) |value| return std.mem.eql(u8, value, wanted);
            var stream = try self.cursor();
            for (wanted) |byte| {
                const next_byte = (try stream.next()) orelse return error.InvalidString;
                if (next_byte != byte) return false;
            }
            return (try stream.next()) == null;
        }

        pub fn orderBytes(self: *const Self, wanted: []const u8) ReadError!std.math.Order {
            if (try self.contiguous()) |value| return std.mem.order(u8, value, wanted);
            var stream = try self.cursor();
            for (wanted) |right| {
                const left = (try stream.next()) orelse return .lt;
                if (left != right) return std.math.order(left, right);
            }
            return if (try stream.next() == null) .eq else .gt;
        }

        fn write(self: *const Self, output: []u8, require_full: bool) ReadError![]const u8 {
            const bounds = try self.itemBounds();
            const length = bounds.item.length;
            const wanted = if (require_full) length else @min(length, output.len);
            if (require_full and output.len < length) return error.OutputTooSmall;
            if (bounds.literal) {
                const value = try self.pool.data.bytes(bounds.data_start, wanted);
                @memcpy(output[0..wanted], value);
                return output[0..wanted];
            }
            var next_token = bounds.token_start;
            var stack: [max_depth]u32 = undefined;
            var stack_len: usize = 0;
            var written: usize = 0;
            while (written < wanted) {
                var symbol = if (stack_len != 0) stacked: {
                    stack_len -= 1;
                    break :stacked stack[stack_len];
                } else token: {
                    if (next_token == bounds.item.token_end) return error.InvalidString;
                    const value = try self.pool.tokens.field(.symbol, next_token);
                    next_token += 1;
                    break :token value;
                };
                while (symbol >= literal_count) {
                    const rule = try self.checkedRule(symbol);
                    if (rule.left < literal_count and rule.right < literal_count and wanted - written >= 2) {
                        output[written] = @intCast(rule.left);
                        output[written + 1] = @intCast(rule.right);
                        written += 2;
                        break;
                    }
                    if (stack_len == stack.len) return error.InvalidString;
                    stack[stack_len] = rule.right;
                    stack_len += 1;
                    symbol = rule.left;
                }
                if (symbol < literal_count and written < wanted) {
                    output[written] = @intCast(symbol);
                    written += 1;
                }
            }
            if (require_full and (stack_len != 0 or next_token != bounds.item.token_end)) return error.InvalidString;
            return output[0..written];
        }

        fn item(self: *const Self) ReadError!Item {
            return self.pool.items.row(@intFromEnum(self.id));
        }

        const Bounds = struct { item: Item, token_start: u32, data_start: u32, literal: bool };

        fn itemBounds(self: *const Self) ReadError!Bounds {
            const index = @intFromEnum(self.id);
            const item_value = try self.pool.items.row(index);
            const token_start = if (index == 0) 0 else try self.pool.items.field(.token_end, index - 1);
            const data_start = if (index == 0) 0 else try self.pool.items.field(.data_end, index - 1);
            if (token_start > item_value.token_end or item_value.token_end > self.pool.tokens.row_count or
                data_start > item_value.data_end or item_value.data_end > self.pool.data.size)
                return error.InvalidString;
            const token_length = item_value.token_end - token_start;
            const data_length = item_value.data_end - data_start;
            if (token_length != 0 and data_length != 0) return error.InvalidString;
            if (data_length != 0 and data_length != item_value.length) return error.InvalidString;
            if (item_value.length != 0 and token_length == 0 and data_length == 0) return error.InvalidString;
            return .{
                .item = item_value,
                .token_start = token_start,
                .data_start = data_start,
                .literal = token_length == 0,
            };
        }

        fn checkedRule(self: *const Self, symbol: u32) ReadError!Rule {
            const rule_index = symbol - literal_count;
            if (rule_index >= self.pool.rules.row_count) return error.InvalidString;
            const rule = try self.pool.rules.row(rule_index);
            if (rule.left >= symbol or rule.right >= symbol) return error.InvalidString;
            return rule;
        }

        pub fn cursor(self: *const Self) ReadError!ByteCursor(Source) {
            const bounds = try self.itemBounds();
            return .{
                .pool = self.pool,
                .next_token = bounds.token_start,
                .token_end = bounds.item.token_end,
                .data_next = bounds.data_start,
                .data_end = bounds.item.data_end,
                .remaining = bounds.item.length,
            };
        }
    };
}

fn ByteCursor(comptime Source: type) type {
    return struct {
        pool: ViewFor(Source),
        next_token: u32,
        token_end: u32,
        data_next: u32,
        data_end: u32,
        remaining: u32,
        stack: [max_depth]u32 = undefined,
        stack_len: usize = 0,

        pub fn next(self: *@This()) ViewFor(Source).ReadError!?u8 {
            while (true) {
                if (self.remaining == 0) {
                    if (self.data_next != self.data_end or self.next_token != self.token_end or self.stack_len != 0) return error.InvalidString;
                    return null;
                }
                if (self.data_next < self.data_end) {
                    const value = try self.pool.data.bytes(self.data_next, 1);
                    self.data_next += 1;
                    self.remaining -= 1;
                    return value[0];
                }
                var symbol = if (self.stack_len != 0) stacked: {
                    self.stack_len -= 1;
                    break :stacked self.stack[self.stack_len];
                } else token: {
                    if (self.next_token == self.token_end) return error.InvalidString;
                    const value = try self.pool.tokens.field(.symbol, self.next_token);
                    self.next_token += 1;
                    break :token value;
                };
                while (symbol >= literal_count) {
                    const rule_index = symbol - literal_count;
                    if (rule_index >= self.pool.rules.row_count) return error.InvalidString;
                    const rule = try self.pool.rules.row(rule_index);
                    if (rule.left >= symbol or rule.right >= symbol) return error.InvalidString;
                    if (self.stack_len == self.stack.len) return error.InvalidString;
                    self.stack[self.stack_len] = rule.right;
                    self.stack_len += 1;
                    symbol = rule.left;
                }
                self.remaining -= 1;
                return @intCast(symbol);
            }
        }
    };
}

pub const View = ViewFor([]const u8);
pub const Text = TextFor([]const u8);

test "one lazy grammar preserves all byte values and bounded rendering" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();
    const repeated = try builder.intern("abababababab");
    try std.testing.expectEqual(repeated, try builder.intern("abababababab"));
    const binary = try builder.intern(&.{ 0, 255, 0, 7 });
    _ = try builder.intern("");
    var owned = try builder.build(std.testing.allocator);
    defer owned.deinit();
    const view = try View.open(owned.bytes);
    try view.verify(std.testing.allocator);
    var output: [32]u8 = undefined;
    try std.testing.expectEqualStrings("ababa", try view.text(repeated).snippet(output[0..5]));
    try std.testing.expectEqualStrings("abababababab", try view.text(repeated).render(&output));
    try std.testing.expectError(error.OutputTooSmall, view.text(repeated).render(output[0..2]));
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 7 }, try view.text(binary).render(&output));
    try std.testing.expect(try view.text(repeated).eqlBytes("abababababab"));
    try std.testing.expectEqual(std.math.Order.lt, try view.text(repeated).orderBytes("b"));
    try std.testing.expectEqual(@as(?[]const u8, null), try view.text(repeated).contiguous());
}

test "fingerprint collisions still compare actual byte streams" {
    var distinct = try buildLiteral(std.testing.allocator, &.{ "a", "b" });
    defer distinct.deinit();
    const distinct_view = try View.open(distinct.bytes);
    try distinct_view.verifyWithHashMask(std.testing.allocator, 0);

    var duplicate = try buildLiteral(std.testing.allocator, &.{ "same", "same" });
    defer duplicate.deinit();
    const duplicate_view = try View.open(duplicate.bytes);
    try std.testing.expectError(error.InvalidString, duplicate_view.verifyWithHashMask(std.testing.allocator, 0));
}
