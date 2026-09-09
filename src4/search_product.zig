//! Generic bounded products over the canonical LEX4 automaton.
//!
//! `Product(Machine)` owns the traversal once.  A machine supplies only a
//! fixed-size cell, initial row, transition, pruning, and acceptance.  This
//! keeps Levenshtein search and the small byte-regex dialect on precisely the
//! same state cursor, rank accounting, collision deduplication, and budgets.
//! No product enumerates accepted keys or allocates behind the caller's back.

const std = @import("std");
const schema = @import("schema.zig");
const automaton = @import("automaton.zig");

pub const EntryRank = schema.Rank(.entry);
pub const Error = automaton.Error || error{
    PatternTooLong,
    DistanceTooLarge,
    UnsupportedRegex,
    FrontierTooSmall,
    RowScratchTooSmall,
    VisitedBudgetExceeded,
    OutputBudgetExceeded,
};

pub const Frontier = struct {
    state: automaton.StateId,
    base: u32,
    row_offset: usize,
};

fn wordCount(entries: u32) usize {
    return (@as(usize, entries) + 63) / 64;
}

pub fn ScratchFor(comptime Cell: type) type {
    return struct {
        const Self = @This();
        frontier: []Frontier,
        rows: []Cell,
        seen: []u64,

        pub fn init(view: *const automaton.View, width: usize, frontier: []Frontier, rows: []Cell, seen: []u64) !Self {
            if (width == 0) return error.RowScratchTooSmall;
            const required = std.math.mul(usize, frontier.len, width) catch return error.RowScratchTooSmall;
            if (rows.len < required) return error.RowScratchTooSmall;
            if (seen.len < wordCount(view.entry_count)) return error.FrontierTooSmall;
            return .{ .frontier = frontier, .rows = rows[0..required], .seen = seen[0..wordCount(view.entry_count)] };
        }

        pub fn clear(self: *Self) void {
            @memset(self.frontier, undefined);
            @memset(self.rows, undefined);
            @memset(self.seen, 0);
        }
    };
}

pub const LevenshteinScratch = ScratchFor(u16);
pub const RegexScratch = ScratchFor(u64);
pub const Hit = struct { rank: EntryRank };

pub fn Product(comptime Machine: type) type {
    return struct {
        const Self = @This();
        const Cell = Machine.Cell;
        view: *const automaton.View,
        machine: Machine,
        scratch: ScratchFor(Cell),
        width: usize,
        max_visited: usize,
        max_outputs: usize,
        head: usize = 0,
        tail: usize = 0,
        visited: usize = 0,
        outputs: usize = 0,
        pending_entry_base: u32 = 0,
        pending_entry_count: u32 = 0,
        pending_entry_index: u32 = 0,
        pending_forms: ?automaton.TargetList = null,
        pending_form_index: u32 = 0,

        pub fn init(view: *const automaton.View, machine: Machine, scratch: ScratchFor(Cell), max_visited: usize, max_outputs: usize) !Self {
            if (scratch.frontier.len == 0 or max_visited == 0 or max_visited > scratch.frontier.len) return error.FrontierTooSmall;
            if (max_outputs == 0) return error.OutputBudgetExceeded;
            const width = machine.width();
            const required_rows = std.math.mul(usize, scratch.frontier.len, width) catch return error.RowScratchTooSmall;
            if (scratch.rows.len < required_rows) return error.RowScratchTooSmall;
            if (scratch.seen.len < wordCount(view.entry_count)) return error.FrontierTooSmall;
            var product = Self{ .view = view, .machine = machine, .scratch = scratch, .width = width, .max_visited = max_visited, .max_outputs = max_outputs };
            @memset(product.scratch.seen, 0);
            product.scratch.frontier[0] = .{ .state = try view.rootState(), .base = 0, .row_offset = 0 };
            product.machine.initial(product.scratch.rows[0..width]);
            product.tail = 1;
            return product;
        }

        pub fn reset(self: *Self) !void {
            @memset(self.scratch.seen, 0);
            self.head = 0;
            self.tail = 1;
            self.visited = 0;
            self.outputs = 0;
            self.pending_entry_count = 0;
            self.pending_entry_index = 0;
            self.pending_forms = null;
            self.pending_form_index = 0;
            self.scratch.frontier[0] = .{ .state = try self.view.rootState(), .base = 0, .row_offset = 0 };
            self.machine.initial(self.scratch.rows[0..self.width]);
        }

        fn mark(self: *Self, rank: u32) !?Hit {
            if (rank >= self.view.entry_count) return error.TargetOutOfRange;
            const word = @as(usize, rank) / 64;
            const bit: u6 = @intCast(rank & 63);
            const mask = @as(u64, 1) << bit;
            if (self.scratch.seen[word] & mask != 0) return null;
            if (self.outputs >= self.max_outputs) return error.OutputBudgetExceeded;
            self.scratch.seen[word] |= mask;
            self.outputs += 1;
            return .{ .rank = @enumFromInt(rank) };
        }

        fn enqueue(self: *Self, parent: Frontier, arc: automaton.TraversalArc) !void {
            if (self.tail >= self.scratch.frontier.len) return error.FrontierTooSmall;
            const row_offset = std.math.mul(usize, self.tail, self.width) catch return error.RowScratchTooSmall;
            const previous = self.scratch.rows[parent.row_offset .. parent.row_offset + self.width];
            const next_row = self.scratch.rows[row_offset .. row_offset + self.width];
            self.machine.transition(previous, next_row, arc.label);
            if (!self.machine.canContinue(next_row)) return;
            const base = std.math.add(u32, parent.base, arc.prefix) catch return error.Overflow;
            self.scratch.frontier[self.tail] = .{ .state = arc.target, .base = base, .row_offset = row_offset };
            self.tail += 1;
        }

        fn nextPending(self: *Self) !?Hit {
            while (self.pending_entry_index < self.pending_entry_count) : (self.pending_entry_index += 1) {
                const rank = std.math.add(u32, self.pending_entry_base, self.pending_entry_index) catch return error.Overflow;
                if (try self.mark(rank)) |hit| return hit;
            }
            if (self.pending_forms) |targets| {
                while (self.pending_form_index < targets.len()) : (self.pending_form_index += 1) {
                    const rank = @intFromEnum(try targets.target(self.pending_form_index));
                    if (try self.mark(rank)) |hit| return hit;
                }
            }
            self.pending_entry_count = 0;
            self.pending_entry_index = 0;
            self.pending_forms = null;
            self.pending_form_index = 0;
            return null;
        }

        pub fn next(self: *Self) !?Hit {
            if (try self.nextPending()) |hit| return hit;
            while (self.head < self.tail) {
                if (self.visited >= self.max_visited) return error.VisitedBudgetExceeded;
                const item = self.scratch.frontier[self.head];
                self.head += 1;
                self.visited += 1;
                const cursor = try self.view.stateCursor(item.state);
                const row = self.scratch.rows[item.row_offset .. item.row_offset + self.width];
                if (self.machine.accepts(row, cursor.hasEntry() or cursor.hasForm())) {
                    if (cursor.hasEntry()) {
                        self.pending_entry_base = item.base;
                        self.pending_entry_count = cursor.entryMultiplicity();
                        self.pending_entry_index = 0;
                    }
                    if (cursor.hasForm()) {
                        self.pending_forms = cursor.formTargets();
                        self.pending_form_index = 0;
                    }
                }
                var arcs = cursor;
                while (try arcs.nextArc()) |arc| try self.enqueue(item, arc);
                if (try self.nextPending()) |hit| return hit;
            }
            return null;
        }
    };
}

pub const LevenshteinMachine = struct {
    pattern: []const u8,
    limit: u16,
    pub const Cell = u16;

    pub fn init(pattern: []const u8, limit: u16) !LevenshteinMachine {
        if (pattern.len == std.math.maxInt(usize) or pattern.len + 1 > std.math.maxInt(u16)) return error.PatternTooLong;
        if (limit == std.math.maxInt(u16)) return error.DistanceTooLarge;
        return .{ .pattern = pattern, .limit = limit };
    }
    pub fn width(self: LevenshteinMachine) usize {
        return self.pattern.len + 1;
    }
    pub fn initial(self: LevenshteinMachine, row: []u16) void {
        _ = self;
        for (row, 0..) |*cell, i| cell.* = @intCast(i);
    }
    pub fn transition(self: LevenshteinMachine, previous: []const u16, next: []u16, label: u8) void {
        const cap = self.limit + 1;
        const bump = struct {
            fn apply(value: u16, ceiling: u16) u16 {
                return if (value >= ceiling) ceiling else value + 1;
            }
        }.apply;
        next[0] = bump(previous[0], cap);
        for (1..self.width()) |column| {
            const insertion = bump(next[column - 1], cap);
            const deletion = bump(previous[column], cap);
            const substitution = if (self.pattern[column - 1] == label) previous[column - 1] else bump(previous[column - 1], cap);
            next[column] = @min(insertion, @min(deletion, substitution));
        }
    }
    pub fn canContinue(self: LevenshteinMachine, row: []const u16) bool {
        var minimum = row[0];
        for (row[1..]) |value| minimum = @min(minimum, value);
        return minimum <= self.limit;
    }
    pub fn accepts(self: LevenshteinMachine, row: []const u16, _: bool) bool {
        return row[row.len - 1] <= self.limit;
    }
};

pub const Levenshtein1 = Product(LevenshteinMachine);
pub const Levenshtein = Product(LevenshteinMachine);

pub fn levenshtein(view: *const automaton.View, pattern: []const u8, distance: u16, scratch: LevenshteinScratch, max_visited: usize, max_outputs: usize) !Levenshtein {
    return Levenshtein.init(view, try LevenshteinMachine.init(pattern, distance), scratch, max_visited, max_outputs);
}

pub fn levenshtein1(view: *const automaton.View, pattern: []const u8, scratch: LevenshteinScratch, max_visited: usize, max_outputs: usize) !Levenshtein1 {
    return levenshtein(view, pattern, 1, scratch, max_visited, max_outputs);
}

const AtomKind = enum { literal, any };
const Quantifier = enum { one, optional, star };
const Atom = struct { kind: AtomKind, literal: u8 = 0, quantifier: Quantifier = .one };

/// A deliberately small regex machine: literals, `.`, postfix `?` and `*`,
/// plus `^`/`$` anchors. Character classes, alternation, grouping, escaping,
/// and `+` are rejected instead of silently changing query meaning.
pub const RegexMachine = struct {
    atoms: [63]Atom = undefined,
    count: u8 = 0,
    end_anchor: bool = false,
    pub const Cell = u64;

    pub fn init(pattern: []const u8) !RegexMachine {
        var machine = RegexMachine{};
        var start: usize = 0;
        var end = pattern.len;
        if (pattern.len != 0 and pattern[0] == '^') start = 1;
        if (end > start and pattern[end - 1] == '$') {
            machine.end_anchor = true;
            end -= 1;
        }
        var i = start;
        while (i < end) : (i += 1) {
            const byte = pattern[i];
            if (byte == '^' or byte == '$' or byte == '+' or byte == '(' or byte == ')' or byte == '[' or byte == ']' or byte == '|' or byte == '\\') return error.UnsupportedRegex;
            if (byte == '?' or byte == '*') {
                if (machine.count == 0) return error.UnsupportedRegex;
                const atom = &machine.atoms[machine.count - 1];
                if (atom.quantifier != .one) return error.UnsupportedRegex;
                atom.quantifier = if (byte == '?') .optional else .star;
                continue;
            }
            if (machine.count >= machine.atoms.len) return error.PatternTooLong;
            machine.atoms[machine.count] = if (byte == '.') .{ .kind = .any } else .{ .kind = .literal, .literal = byte };
            machine.count += 1;
        }
        return machine;
    }

    pub fn width(_: RegexMachine) usize {
        return 1;
    }

    fn closure(self: RegexMachine, initial_bits: u64) u64 {
        var bits = initial_bits;
        var changed = true;
        while (changed) {
            changed = false;
            for (0..self.count) |i| {
                const mask = @as(u64, 1) << @as(u6, @intCast(i));
                if (bits & mask == 0) continue;
                if (self.atoms[i].quantifier == .one) continue;
                const next = @as(u64, 1) << @as(u6, @intCast(i + 1));
                if (bits & next == 0) {
                    bits |= next;
                    changed = true;
                }
            }
        }
        return bits;
    }

    pub fn initial(self: RegexMachine, row: []u64) void {
        row[0] = self.closure(1);
    }

    pub fn transition(self: RegexMachine, previous: []const u64, next: []u64, label: u8) void {
        var bits: u64 = 0;
        for (0..self.count) |i| {
            if (previous[0] & (@as(u64, 1) << @as(u6, @intCast(i))) == 0) continue;
            const atom = self.atoms[i];
            const matches = atom.kind == .any or atom.literal == label;
            if (!matches) continue;
            const destination = if (atom.quantifier == .star) i else i + 1;
            bits |= @as(u64, 1) << @as(u6, @intCast(destination));
        }
        next[0] = self.closure(bits);
    }

    pub fn canContinue(_: RegexMachine, row: []const u64) bool {
        return row[0] != 0;
    }
    pub fn accepts(self: RegexMachine, row: []const u64, terminal: bool) bool {
        if (self.end_anchor and !terminal) return false;
        return row[0] & (@as(u64, 1) << @as(u6, @intCast(self.count))) != 0;
    }
};

pub const Regex = Product(RegexMachine);

pub fn regex(view: *const automaton.View, expression: []const u8, scratch: RegexScratch, max_visited: usize, max_outputs: usize) !Regex {
    return Regex.init(view, try RegexMachine.init(expression), scratch, max_visited, max_outputs);
}

test "generic product keeps Levenshtein behavior" {
    var builder = automaton.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.addEntry("cat", 1);
    try builder.addEntry("cot", 1);
    try builder.addEntry("dog", 1);
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);
    var frontier: [128]Frontier = undefined;
    var rows: [128 * 4]u16 = undefined;
    var seen: [1]u64 = .{0};
    const scratch = try LevenshteinScratch.init(&view, 4, &frontier, &rows, &seen);
    var product = try levenshtein1(&view, "cat", scratch, 128, 8);
    var count: usize = 0;
    while (try product.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "product validates actual row stride and establishes clean visited state" {
    var builder = automaton.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.addEntry("a", 1);
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);

    var frontier: [2]Frontier = undefined;
    var short_rows: [2]u16 = undefined;
    var seen: [1]u64 = .{std.math.maxInt(u64)};
    const short = try LevenshteinScratch.init(&view, 1, &frontier, &short_rows, &seen);
    try std.testing.expectError(error.RowScratchTooSmall, levenshtein(&view, "a", 0, short, 2, 2));

    var rows: [4]u16 = undefined;
    const scratch = try LevenshteinScratch.init(&view, 2, &frontier, &rows, &seen);
    var product = try levenshtein(&view, "a", 0, scratch, 2, 2);
    try std.testing.expectEqual(@as(u64, 0), seen[0]);
    try std.testing.expect((try product.next()) != null);
}

test "Levenshtein distance is caller-bounded and supports exact and k two" {
    var builder = automaton.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.addEntry("cat", 1);
    try builder.addEntry("coat", 1);
    try builder.addEntry("cot", 1);
    try builder.addEntry("dog", 1);
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);

    var frontier_zero: [128]Frontier = undefined;
    var rows_zero: [128 * 4]u16 = undefined;
    var seen_zero: [1]u64 = .{0};
    const scratch_zero = try LevenshteinScratch.init(&view, 4, &frontier_zero, &rows_zero, &seen_zero);
    var exact = try levenshtein(&view, "cat", 0, scratch_zero, 128, 8);
    while (try exact.next()) |_| {}
    try std.testing.expectEqual(@as(u64, 1) << 0, seen_zero[0]);

    var frontier_two: [128]Frontier = undefined;
    var rows_two: [128 * 4]u16 = undefined;
    var seen_two: [1]u64 = .{0};
    const scratch_two = try LevenshteinScratch.init(&view, 4, &frontier_two, &rows_two, &seen_two);
    var near = try levenshtein(&view, "cat", 2, scratch_two, 128, 8);
    while (try near.next()) |_| {}
    try std.testing.expectEqual((@as(u64, 1) << 0) | (@as(u64, 1) << 1) | (@as(u64, 1) << 2), seen_two[0]);
    try std.testing.expectEqual(@as(u64, 0), seen_two[0] & (@as(u64, 1) << 3));
    try std.testing.expectError(error.DistanceTooLarge, LevenshteinMachine.init("cat", std.math.maxInt(u16)));
}

fn regexRanks(view: *const automaton.View, expression: []const u8, expected: u64) !void {
    var frontier: [512]Frontier = undefined;
    var rows: [512]u64 = undefined;
    var seen: [1]u64 = .{0};
    const scratch = try RegexScratch.init(view, 1, &frontier, &rows, &seen);
    var product = try regex(view, expression, scratch, 512, 64);
    while (try product.next()) |_| {}
    try std.testing.expectEqual(expected, seen[0]);
}

test "byte regex product matches literals wildcards quantifiers and anchors" {
    const keys = [_][]const u8{ "ant", "bat", "cat", "cot", "cut", "dog", "dot", "duck", "dug", "sun", "tan", "ton" };
    var builder = automaton.Builder.init(std.testing.allocator);
    defer builder.deinit();
    for (keys) |key| try builder.addEntry(key, 1);
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);
    // c.t -> cat, cot, cut (ranks 2, 3, 4).
    try regexRanks(&view, "c.t", (@as(u64, 1) << 2) | (@as(u64, 1) << 3) | (@as(u64, 1) << 4));
    // d.?g -> dog and dug (the dot is a wildcard with an optional quantifier).
    try regexRanks(&view, "d.?g", (@as(u64, 1) << 5) | (@as(u64, 1) << 8));
    // ^c.*$ is a full anchored match over all c-prefixed keys.
    try regexRanks(&view, "^c.*$", (@as(u64, 1) << 2) | (@as(u64, 1) << 3) | (@as(u64, 1) << 4));
    // The end anchor rejects the longer duck/dug strings.
    try regexRanks(&view, "dog$", @as(u64, 1) << 5);
}

test "regex rejects unsupported constructs and enforces product budgets" {
    try std.testing.expectError(error.UnsupportedRegex, RegexMachine.init("[abc]"));
    try std.testing.expectError(error.UnsupportedRegex, RegexMachine.init("a+"));
    try std.testing.expectError(error.UnsupportedRegex, RegexMachine.init("(ab)"));
    try std.testing.expectError(error.UnsupportedRegex, RegexMachine.init("\\d"));
    try std.testing.expectError(error.UnsupportedRegex, RegexMachine.init("a**"));
    var too_long: [64]u8 = [_]u8{'a'} ** 64;
    try std.testing.expectError(error.PatternTooLong, RegexMachine.init(&too_long));

    var builder = automaton.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.addEntry("cat", 1);
    try builder.addEntry("cot", 1);
    var owned = try builder.finish();
    defer owned.deinit();
    const view = try automaton.View.open(owned.bytes);
    var frontier: [32]Frontier = undefined;
    var rows: [32]u64 = undefined;
    var seen: [1]u64 = .{0};
    const scratch = try RegexScratch.init(&view, 1, &frontier, &rows, &seen);
    var product = try regex(&view, ".*", scratch, 1, 8);
    try std.testing.expectError(error.VisitedBudgetExceeded, product.next());
}
