const std = @import("std");
const bytes = @import("bytes.zig");
const columns = @import("columns.zig");
const sets = @import("sets.zig");
const strings = @import("strings.zig");
const model = @import("model.zig");

pub const Origin = union(enum) {
    headword: model.Ref(.entry),
    form: model.Ref(.form),
};
pub const Row = struct { key: model.StringId, origin: Origin };
const Rows = columns.Records(Row);
const Targets = sets.Projection(model.Ref(.entry), .set);
const HitEnd = struct { end: u32 };
const HitEnds = columns.Records(HitEnd);

const StateId = enum(u32) { _ };
const State = struct { arc_end: u32, suffix_count: u32, terminal: bool };
const Arc = struct { label: u8, target: StateId, before: u32 };
const States = columns.Records(State);
const Arcs = columns.Records(Arc);
const Parts = struct { rows: void, targets: void, hit_ends: void, states: void, arcs: void };
const max_index_rows = (columns.Limits{}).max_rows;

pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

const Pending = struct { input: model.KeyInput, ordinal: usize };
const TrieArc = struct { label: u8, target: u32 };
const TrieNode = struct { terminal: bool = false, children: std.ArrayList(TrieArc) = .empty };
const CanonicalArc = struct { label: u8, target: StateId };
const CanonicalState = struct { terminal: bool, arcs: []CanonicalArc, hash_next: ?u32 };

fn keyOf(input: model.KeyInput) []const u8 {
    return switch (input) {
        inline else => |value| value.key,
    };
}

fn lessThan(_: void, left: Pending, right: Pending) bool {
    const order = std.mem.order(u8, keyOf(left.input), keyOf(right.input));
    return order == .lt or (order == .eq and left.ordinal < right.ordinal);
}

fn signatureStart(terminal: bool) u64 {
    return if (terminal) 0xcbf29ce484222325 else 0x84222325cbf29ce4;
}

fn signatureStep(hash: u64, label: u8, target: StateId) u64 {
    var result = (hash ^ label) *% 0x100000001b3;
    result = (result ^ @intFromEnum(target)) *% 0x100000001b3;
    return result;
}

fn signatureHash(terminal: bool, arcs: []const CanonicalArc) u64 {
    var hash = signatureStart(terminal);
    for (arcs) |arc| {
        hash = signatureStep(hash, arc.label, arc.target);
    }
    return hash;
}

fn sameSignature(state: CanonicalState, terminal: bool, arcs: []const CanonicalArc) bool {
    if (state.terminal != terminal or state.arcs.len != arcs.len) return false;
    for (state.arcs, arcs) |left, right| {
        if (left.label != right.label or left.target != right.target) return false;
    }
    return true;
}

fn appendTrieNode(nodes: *std.ArrayList(TrieNode), allocator: std.mem.Allocator) !u32 {
    if (nodes.items.len >= max_index_rows) return error.InvalidValue;
    const result: u32 = @intCast(nodes.items.len);
    try nodes.append(allocator, .{});
    return result;
}

const Automaton = struct {
    allocator: std.mem.Allocator,
    states: []State,
    arcs: []Arc,
    hit_ends_allocation: []HitEnd,
    hit_end_count: usize,

    fn deinit(self: *Automaton) void {
        self.allocator.free(self.states);
        self.allocator.free(self.arcs);
        self.allocator.free(self.hit_ends_allocation);
        self.* = undefined;
    }

    fn hitEnds(self: Automaton) []const HitEnd {
        return self.hit_ends_allocation[0..self.hit_end_count];
    }
};

fn buildAutomaton(allocator: std.mem.Allocator, pending: []const Pending) !Automaton {
    var trie: std.ArrayList(TrieNode) = .empty;
    defer {
        for (trie.items) |*node| node.children.deinit(allocator);
        trie.deinit(allocator);
    }
    _ = try appendTrieNode(&trie, allocator);

    const hit_ends = try allocator.alloc(HitEnd, pending.len);
    errdefer allocator.free(hit_ends);
    var distinct_count: usize = 0;
    var previous_key: ?[]const u8 = null;
    for (pending, 0..) |item, physical_index| {
        const key = keyOf(item.input);
        if (previous_key != null and std.mem.eql(u8, previous_key.?, key)) continue;
        if (distinct_count != 0) hit_ends[distinct_count - 1].end = @intCast(physical_index);
        distinct_count += 1;
        previous_key = key;

        var node_index: u32 = 0;
        for (key) |label| {
            const children = trie.items[node_index].children.items;
            if (children.len != 0 and children[children.len - 1].label == label) {
                node_index = children[children.len - 1].target;
                continue;
            }
            if (children.len != 0 and children[children.len - 1].label >= label) return error.InvalidFormat;
            const child = try appendTrieNode(&trie, allocator);
            try trie.items[node_index].children.append(allocator, .{ .label = label, .target = child });
            node_index = child;
        }
        trie.items[node_index].terminal = true;
    }
    if (distinct_count != 0) hit_ends[distinct_count - 1].end = @intCast(pending.len);

    const trie_states = try allocator.alloc(StateId, trie.items.len);
    defer allocator.free(trie_states);
    var canonical: std.ArrayList(CanonicalState) = .empty;
    defer {
        for (canonical.items) |state| allocator.free(state.arcs);
        canonical.deinit(allocator);
    }
    var hash_heads = std.AutoHashMap(u64, u32).init(allocator);
    defer hash_heads.deinit();

    var reverse = trie.items.len;
    while (reverse != 0) {
        reverse -= 1;
        const node = trie.items[reverse];
        const signature = try allocator.alloc(CanonicalArc, node.children.items.len);
        var signature_owned = true;
        defer if (signature_owned) allocator.free(signature);
        for (node.children.items, 0..) |arc, index| {
            signature[index] = .{ .label = arc.label, .target = trie_states[arc.target] };
        }
        const hash = signatureHash(node.terminal, signature);
        var candidate = hash_heads.get(hash);
        while (candidate) |state_index| {
            const state = canonical.items[state_index];
            if (sameSignature(state, node.terminal, signature)) {
                trie_states[reverse] = @enumFromInt(state_index);
                break;
            }
            candidate = state.hash_next;
        } else {
            if (canonical.items.len >= max_index_rows) return error.InvalidValue;
            const state_index: u32 = @intCast(canonical.items.len);
            try canonical.append(allocator, .{
                .terminal = node.terminal,
                .arcs = signature,
                .hash_next = hash_heads.get(hash),
            });
            errdefer {
                const removed = canonical.pop().?;
                allocator.free(removed.arcs);
            }
            signature_owned = false;
            try hash_heads.put(hash, state_index);
            trie_states[reverse] = @enumFromInt(state_index);
        }
    }

    const states = try allocator.alloc(State, canonical.items.len);
    errdefer allocator.free(states);
    var total_arcs: usize = 0;
    for (canonical.items) |state| {
        total_arcs = std.math.add(usize, total_arcs, state.arcs.len) catch return error.Overflow;
    }
    if (total_arcs > max_index_rows) return error.InvalidValue;
    const arcs = try allocator.alloc(Arc, total_arcs);
    errdefer allocator.free(arcs);

    var arc_position: usize = 0;
    for (canonical.items, 0..) |state, state_index| {
        var suffix_count: u32 = @intFromBool(state.terminal);
        for (state.arcs) |arc| {
            const target_index = @intFromEnum(arc.target);
            if (target_index >= state_index) return error.InvalidFormat;
            arcs[arc_position] = .{ .label = arc.label, .target = arc.target, .before = suffix_count };
            arc_position += 1;
            suffix_count = std.math.add(u32, suffix_count, states[target_index].suffix_count) catch return error.Overflow;
        }
        states[state_index] = .{
            .arc_end = @intCast(arc_position),
            .suffix_count = suffix_count,
            .terminal = state.terminal,
        };
    }
    if (states.len == 0 or states[states.len - 1].suffix_count != distinct_count) return error.InvalidFormat;
    return .{
        .allocator = allocator,
        .states = states,
        .arcs = arcs,
        .hit_ends_allocation = hit_ends,
        .hit_end_count = distinct_count,
    };
}

pub fn build(allocator: std.mem.Allocator, pool: *strings.Builder, inputs: []const model.KeyInput) (columns.Error || sets.Error || strings.Error)!Owned {
    if (inputs.len > max_index_rows) return error.InvalidValue;
    const pending = try allocator.alloc(Pending, inputs.len);
    defer allocator.free(pending);
    for (inputs, 0..) |input, ordinal| pending[ordinal] = .{ .input = input, .ordinal = ordinal };
    std.mem.sort(Pending, pending, {}, lessThan);

    const rows = try allocator.alloc(Row, inputs.len);
    defer allocator.free(rows);
    const groups = try allocator.alloc([]const model.Ref(.entry), inputs.len);
    defer allocator.free(groups);
    for (pending, 0..) |item, index| {
        rows[index] = switch (item.input) {
            .headword => |headword| .{
                .key = try pool.intern(headword.key),
                .origin = .{ .headword = headword.entry },
            },
            .form => |form| .{
                .key = try pool.intern(form.key),
                .origin = .{ .form = form.form },
            },
        };
        groups[index] = switch (item.input) {
            .headword => &.{},
            .form => |form| form.targets,
        };
    }

    var automaton = try buildAutomaton(allocator, pending);
    defer automaton.deinit();
    var row_store = try Rows.build(allocator, rows);
    defer row_store.deinit();
    var target_store = try Targets.build(allocator, groups);
    defer target_store.deinit();
    var end_store = try HitEnds.build(allocator, automaton.hitEnds());
    defer end_store.deinit();
    var state_store = try States.build(allocator, automaton.states);
    defer state_store.deinit();
    var arc_store = try Arcs.build(allocator, automaton.arcs);
    defer arc_store.deinit();
    const output = try bytes.Bundle(Parts).build(allocator, .{
        .rows = row_store.bytes,
        .targets = target_store.bytes,
        .hit_ends = end_store.bytes,
        .states = state_store.bytes,
        .arcs = arc_store.bytes,
    });
    return .{ .allocator = allocator, .bytes = output.bytes };
}

pub fn ViewFor(comptime Source: type) type {
    return struct {
        rows: Rows.ViewFor(bytes.Span(Source)),
        targets: Targets.ViewFor(bytes.Span(Source)),
        hit_ends: HitEnds.ViewFor(bytes.Span(Source)),
        states: States.ViewFor(bytes.Span(Source)),
        arcs: Arcs.ViewFor(bytes.Span(Source)),

        const Self = @This();
        pub const ReadError = columns.Error || sets.Error || bytes.SourceError(Source);
        pub const TargetCursor = Targets.ViewFor(bytes.Span(Source)).Cursor;

        pub fn open(source: Source) ReadError!Self {
            const bundle = try bytes.Bundle(Parts).ViewFor(Source).open(source);
            return .{
                .rows = try Rows.ViewFor(bytes.Span(Source)).open(bundle.part(.rows)),
                .targets = try Targets.ViewFor(bytes.Span(Source)).open(bundle.part(.targets)),
                .hit_ends = try HitEnds.ViewFor(bytes.Span(Source)).open(bundle.part(.hit_ends)),
                .states = try States.ViewFor(bytes.Span(Source)).open(bundle.part(.states)),
                .arcs = try Arcs.ViewFor(bytes.Span(Source)).open(bundle.part(.arcs)),
            };
        }

        fn arcStart(self: *const Self, state_index: usize) ReadError!u32 {
            return if (state_index == 0) 0 else self.states.field(.arc_end, state_index - 1);
        }

        const Step = union(enum) {
            found: struct { state: StateId, before: u32 },
            missing: u32,
        };

        fn child(self: *const Self, state_id: StateId, label: u8) ReadError!Step {
            const state_index = @intFromEnum(state_id);
            const state = try self.states.row(state_index);
            var low: usize = try self.arcStart(state_index);
            var high: usize = state.arc_end;
            if (high > self.arcs.row_count or low > high) return error.InvalidFormat;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (try self.arcs.field(.label, middle) < label) low = middle + 1 else high = middle;
            }
            if (low == state.arc_end) return .{ .missing = state.suffix_count };
            const arc = try self.arcs.row(low);
            if (arc.label != label) return .{ .missing = arc.before };
            return .{ .found = .{ .state = arc.target, .before = arc.before } };
        }

        const Navigation = union(enum) {
            found: struct { state: StateId, ordinal: u32 },
            missing: u32,
        };

        fn root(self: *const Self) ReadError!StateId {
            if (self.states.row_count == 0 or self.states.row_count - 1 > std.math.maxInt(u32)) return error.InvalidFormat;
            return @enumFromInt(@as(u32, @intCast(self.states.row_count - 1)));
        }

        fn navigateBytes(self: *const Self, wanted: []const u8) ReadError!Navigation {
            var state = try self.root();
            var ordinal: u32 = 0;
            for (wanted) |label| switch (try self.child(state, label)) {
                .found => |step| {
                    ordinal = std.math.add(u32, ordinal, step.before) catch return error.Overflow;
                    state = step.state;
                },
                .missing => |before| {
                    ordinal = std.math.add(u32, ordinal, before) catch return error.Overflow;
                    return .{ .missing = ordinal };
                },
            };
            return .{ .found = .{ .state = state, .ordinal = ordinal } };
        }

        fn navigateText(self: *const Self, text: anytype) !Navigation {
            var state = try self.root();
            var ordinal: u32 = 0;
            var cursor = try text.cursor();
            while (try cursor.next()) |label| switch (try self.child(state, label)) {
                .found => |step| {
                    ordinal = std.math.add(u32, ordinal, step.before) catch return error.Overflow;
                    state = step.state;
                },
                .missing => |before| {
                    ordinal = std.math.add(u32, ordinal, before) catch return error.Overflow;
                    return .{ .missing = ordinal };
                },
            };
            return .{ .found = .{ .state = state, .ordinal = ordinal } };
        }

        fn hitBoundary(self: *const Self, spelling_rank: u32) ReadError!u32 {
            if (spelling_rank > self.hit_ends.row_count) return error.InvalidFormat;
            if (spelling_rank == 0) return 0;
            return (try self.hit_ends.row(spelling_rank - 1)).end;
        }

        fn physicalRange(self: *const Self, first: u32, last: u32) ReadError!Range {
            if (first > last) return error.InvalidFormat;
            const start = try self.hitBoundary(first);
            const end = try self.hitBoundary(last);
            if (start > end or end > self.rows.row_count) return error.InvalidFormat;
            return .{ .next = start, .end = end };
        }

        fn stateSignatureHash(self: *const Self, state_index: usize) ReadError!u64 {
            const state = try self.states.row(state_index);
            var hash = signatureStart(state.terminal);
            const start = try self.arcStart(state_index);
            for (start..state.arc_end) |arc_index| {
                const arc = try self.arcs.row(arc_index);
                hash = signatureStep(hash, arc.label, arc.target);
            }
            return hash;
        }

        fn sameStateSignature(self: *const Self, left_index: usize, right_index: usize) ReadError!bool {
            const left = try self.states.row(left_index);
            const right = try self.states.row(right_index);
            if (left.terminal != right.terminal) return false;
            const left_start = try self.arcStart(left_index);
            const right_start = try self.arcStart(right_index);
            const left_count = left.arc_end - left_start;
            const right_count = right.arc_end - right_start;
            if (left_count != right_count) return false;
            for (0..left_count) |offset| {
                const left_arc = try self.arcs.row(left_start + offset);
                const right_arc = try self.arcs.row(right_start + offset);
                if (left_arc.label != right_arc.label or left_arc.target != right_arc.target) return false;
            }
            return true;
        }

        pub fn exact(self: *const Self, wanted: []const u8) ReadError!Range {
            return switch (try self.navigateBytes(wanted)) {
                .missing => |ordinal| self.physicalRange(ordinal, ordinal),
                .found => |navigation| value: {
                    const state = try self.states.row(@intFromEnum(navigation.state));
                    const end = std.math.add(u32, navigation.ordinal, @intFromBool(state.terminal)) catch return error.Overflow;
                    break :value self.physicalRange(navigation.ordinal, end);
                },
            };
        }

        pub fn prefix(self: *const Self, wanted: []const u8) ReadError!Range {
            return switch (try self.navigateBytes(wanted)) {
                .missing => |ordinal| self.physicalRange(ordinal, ordinal),
                .found => |navigation| value: {
                    const state = try self.states.row(@intFromEnum(navigation.state));
                    const end = std.math.add(u32, navigation.ordinal, state.suffix_count) catch return error.Overflow;
                    break :value self.physicalRange(navigation.ordinal, end);
                },
            };
        }

        pub fn select(self: *const Self, rank: usize) ReadError!Row {
            return self.rows.row(rank);
        }

        pub fn ProjectionFor(comptime path: anytype) type {
            return Rows.ViewFor(bytes.Span(Source)).ProjectionFor(path);
        }

        pub fn project(self: *const Self, comptime path: anytype) ProjectionFor(path) {
            return self.rows.project(path);
        }

        pub fn projectRange(self: *const Self, comptime path: anytype, range: Range) ReadError!ProjectionFor(path) {
            if (range.next > range.end or range.end > self.rows.row_count) return error.IndexOutOfBounds;
            const projected = self.rows.project(path);
            return projected.slice(range.next, range.end);
        }

        pub fn spellingCount(self: *const Self) usize {
            return self.hit_ends.row_count;
        }

        pub fn hitCount(self: *const Self) usize {
            return self.rows.row_count;
        }

        pub fn verify(self: *const Self, allocator: std.mem.Allocator, pool: anytype, domains: model.DomainCatalogue) !void {
            try self.rows.verify(domains);
            const entries = try domains.countForVerify(model.Domain{ .record = .entry });
            try self.targets.verify(entries);
            try self.hit_ends.verify(.{});
            try self.states.verify(.{});
            try self.arcs.verify(.{});
            if (self.targets.group_count != self.rows.row_count or self.states.row_count == 0) return error.InvalidFormat;

            var previous_arc_end: u32 = 0;
            for (0..self.states.row_count) |state_index| {
                const state = try self.states.row(state_index);
                if (state.arc_end < previous_arc_end or state.arc_end > self.arcs.row_count) return error.InvalidFormat;
                const is_root = state_index + 1 == self.states.row_count;
                if (!is_root and state.suffix_count == 0) return error.InvalidFormat;
                if (is_root and state.suffix_count == 0 and self.states.row_count != 1) return error.InvalidFormat;
                var expected_before: u32 = @intFromBool(state.terminal);
                var previous_label: ?u8 = null;
                for (previous_arc_end..state.arc_end) |arc_index| {
                    const arc = try self.arcs.row(arc_index);
                    if (previous_label) |prior| if (prior >= arc.label) return error.InvalidFormat;
                    previous_label = arc.label;
                    const target_index = @intFromEnum(arc.target);
                    if (target_index >= state_index or arc.before != expected_before) return error.InvalidFormat;
                    const child_state = try self.states.row(target_index);
                    expected_before = std.math.add(u32, expected_before, child_state.suffix_count) catch return error.Overflow;
                }
                if (state.suffix_count != expected_before) return error.InvalidFormat;
                previous_arc_end = state.arc_end;
            }
            if (previous_arc_end != self.arcs.row_count) return error.InvalidFormat;

            // State identity is exactly terminal plus ordered labeled targets. Hashes
            // select candidates; equality of the wire signatures proves minimality.
            var signature_heads = std.AutoHashMap(u64, u32).init(allocator);
            defer signature_heads.deinit();
            const signature_next = try allocator.alloc(?u32, self.states.row_count);
            defer allocator.free(signature_next);
            @memset(signature_next, null);
            var collision_work: usize = 0;
            for (0..self.states.row_count) |state_index| {
                if (state_index > std.math.maxInt(u32)) return error.InvalidFormat;
                const hash = try self.stateSignatureHash(state_index);
                var candidate = signature_heads.get(hash);
                while (candidate) |prior| {
                    const state = try self.states.row(state_index);
                    const start = try self.arcStart(state_index);
                    collision_work = std.math.add(usize, collision_work, state.arc_end - start + 1) catch return error.WorkLimitExceeded;
                    if (collision_work > 16 * 1024 * 1024) return error.WorkLimitExceeded;
                    if (try self.sameStateSignature(state_index, prior)) return error.InvalidFormat;
                    candidate = signature_next[prior];
                }
                signature_next[state_index] = signature_heads.get(hash);
                try signature_heads.put(hash, @intCast(state_index));
            }

            const reachable = try allocator.alloc(bool, self.states.row_count);
            defer allocator.free(reachable);
            @memset(reachable, false);
            reachable[self.states.row_count - 1] = true;
            var reverse = self.states.row_count;
            while (reverse != 0) {
                reverse -= 1;
                if (!reachable[reverse]) continue;
                const start = try self.arcStart(reverse);
                const state = try self.states.row(reverse);
                for (start..state.arc_end) |arc_index| {
                    const target = @intFromEnum(try self.arcs.field(.target, arc_index));
                    if (target >= reverse) return error.InvalidFormat;
                    reachable[target] = true;
                }
            }
            for (reachable) |seen| if (!seen) return error.InvalidFormat;

            const root_state = try self.states.row(self.states.row_count - 1);
            if (root_state.suffix_count != self.hit_ends.row_count) return error.InvalidFormat;
            var previous_end: u32 = 0;
            for (0..self.hit_ends.row_count) |index| {
                const end = (try self.hit_ends.row(index)).end;
                if (end <= previous_end or end > self.rows.row_count) return error.InvalidFormat;
                previous_end = end;
            }
            if (previous_end != self.rows.row_count) return error.InvalidFormat;

            var spelling_rank: u32 = 0;
            var spelling_end: u32 = if (self.hit_ends.row_count == 0) 0 else (try self.hit_ends.row(0)).end;
            for (0..self.rows.row_count) |physical_rank| {
                while (physical_rank >= spelling_end) {
                    spelling_rank = std.math.add(u32, spelling_rank, 1) catch return error.Overflow;
                    if (spelling_rank >= self.hit_ends.row_count) return error.InvalidFormat;
                    spelling_end = (try self.hit_ends.row(spelling_rank)).end;
                }
                const key = try self.rows.field(.key, physical_rank);
                const navigation = try self.navigateText(pool.text(key));
                const found = switch (navigation) {
                    .missing => return error.InvalidFormat,
                    .found => |value| value,
                };
                if (found.ordinal != spelling_rank or !(try self.states.field(.terminal, @intFromEnum(found.state)))) return error.InvalidFormat;
                const origin = try self.rows.field(.origin, physical_rank);
                var targets = try self.targets.cursor(physical_rank);
                switch (origin) {
                    .headword => if ((try targets.nextRun()) != null) return error.InvalidFormat,
                    .form => {},
                }
            }
        }

        pub const Range = struct {
            next: usize,
            end: usize,

            pub fn nextIndex(self: *@This()) !?usize {
                if (self.next > self.end) return error.InvalidFormat;
                if (self.next == self.end) return null;
                const result = self.next;
                self.next = std.math.add(usize, self.next, 1) catch return error.Overflow;
                return result;
            }
        };
    };
}

pub const View = ViewFor([]const u8);

test "minimal key DAG preserves spelling ranks and physical claims" {
    const inputs = [_]model.KeyInput{
        .{ .form = .{ .key = "cats", .form = @enumFromInt(0), .targets = &.{@enumFromInt(0)} } },
        .{ .headword = .{ .key = "cat", .entry = @enumFromInt(0) } },
        .{ .headword = .{ .key = "cat", .entry = @enumFromInt(1) } },
        .{ .headword = .{ .key = "", .entry = @enumFromInt(0) } },
        .{ .headword = .{ .key = &.{ 0xff, 0x80 }, .entry = @enumFromInt(1) } },
    };
    var pool_builder = strings.Builder.init(std.testing.allocator);
    defer pool_builder.deinit();
    var owned = try build(std.testing.allocator, &pool_builder, &inputs);
    defer owned.deinit();
    var pool_owned = try pool_builder.build(std.testing.allocator);
    defer pool_owned.deinit();
    const pool = try strings.View.open(pool_owned.bytes);
    const view = try View.open(owned.bytes);
    var domains: model.DomainCatalogue = .{};
    try domains.setOwned(model.Domain{ .string = {} }, @intCast(pool.count()));
    try domains.setOwned(model.Domain{ .record = .entry }, 2);
    try domains.setOwned(model.Domain{ .record = .form }, 1);
    try view.verify(std.testing.allocator, pool, domains);

    var empty = try view.exact("");
    try std.testing.expectEqual(@as(usize, 0), (try empty.nextIndex()).?);
    try std.testing.expect((try empty.nextIndex()) == null);
    var exact = try view.exact("cat");
    try std.testing.expectEqual(@as(usize, 1), (try exact.nextIndex()).?);
    try std.testing.expectEqual(@as(usize, 2), (try exact.nextIndex()).?);
    try std.testing.expect((try exact.nextIndex()) == null);
    var prefix = try view.prefix("cat");
    try std.testing.expectEqual(@as(usize, 1), (try prefix.nextIndex()).?);
    try std.testing.expectEqual(@as(usize, 2), (try prefix.nextIndex()).?);
    try std.testing.expectEqual(@as(usize, 3), (try prefix.nextIndex()).?);
    try std.testing.expect((try prefix.nextIndex()) == null);
    const before = try view.exact("bat");
    try std.testing.expectEqual(@as(usize, 1), before.next);
    const between = try view.exact("catr");
    try std.testing.expectEqual(@as(usize, 3), between.next);
    const after = try view.prefix(&.{ 0xff, 0xff });
    try std.testing.expectEqual(@as(usize, inputs.len), after.next);
    const prefix_of_word = try view.prefix("ca");
    try std.testing.expectEqual(@as(usize, 1), prefix_of_word.next);
    try std.testing.expectEqual(@as(usize, 4), prefix_of_word.end);
    const absent_nonterminal = try view.exact("ca");
    try std.testing.expectEqual(absent_nonterminal.next, absent_nonterminal.end);
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    const inputs = [_]model.KeyInput{
        .{ .headword = .{ .key = "bake", .entry = @enumFromInt(0) } },
        .{ .headword = .{ .key = "cake", .entry = @enumFromInt(1) } },
        .{ .headword = .{ .key = "lake", .entry = @enumFromInt(2) } },
        .{ .headword = .{ .key = "lake", .entry = @enumFromInt(3) } },
    };
    var pool = strings.Builder.init(allocator);
    defer pool.deinit();
    var owned = try build(allocator, &pool, &inputs);
    defer owned.deinit();
}

test "minimal key DAG shares suffix states and cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});

    const inputs = [_]model.KeyInput{
        .{ .headword = .{ .key = "bake", .entry = @enumFromInt(0) } },
        .{ .headword = .{ .key = "cake", .entry = @enumFromInt(1) } },
        .{ .headword = .{ .key = "lake", .entry = @enumFromInt(2) } },
    };
    var pool = strings.Builder.init(std.testing.allocator);
    defer pool.deinit();
    var owned = try build(std.testing.allocator, &pool, &inputs);
    defer owned.deinit();
    const view = try View.open(owned.bytes);
    // The unshared trie has thirteen nodes. The suffix-language DAG has five.
    try std.testing.expectEqual(@as(usize, 5), view.states.row_count);
}

fn assembleTestWire(
    allocator: std.mem.Allocator,
    rows: []const Row,
    groups: []const []const model.Ref(.entry),
    hit_ends: []const HitEnd,
    states: []const State,
    arcs: []const Arc,
) !Owned {
    var row_store = try Rows.build(allocator, rows);
    defer row_store.deinit();
    var target_store = try Targets.build(allocator, groups);
    defer target_store.deinit();
    var end_store = try HitEnds.build(allocator, hit_ends);
    defer end_store.deinit();
    var state_store = try States.build(allocator, states);
    defer state_store.deinit();
    var arc_store = try Arcs.build(allocator, arcs);
    defer arc_store.deinit();
    const output = try bytes.Bundle(Parts).build(allocator, .{
        .rows = row_store.bytes,
        .targets = target_store.bytes,
        .hit_ends = end_store.bytes,
        .states = state_store.bytes,
        .arcs = arc_store.bytes,
    });
    return .{ .allocator = allocator, .bytes = output.bytes };
}

test "minimal key DAG verification proves measures reachability and correspondence" {
    var pool_builder = strings.Builder.init(std.testing.allocator);
    defer pool_builder.deinit();
    const key = try pool_builder.intern("a");
    var pool_owned = try pool_builder.build(std.testing.allocator);
    defer pool_owned.deinit();
    const pool = try strings.View.open(pool_owned.bytes);
    const rows = [_]Row{.{ .key = key, .origin = .{ .headword = @enumFromInt(0) } }};
    const groups = [_][]const model.Ref(.entry){&.{}};
    const ends = [_]HitEnd{.{ .end = 1 }};
    const valid_states = [_]State{
        .{ .arc_end = 0, .suffix_count = 1, .terminal = true },
        .{ .arc_end = 1, .suffix_count = 1, .terminal = false },
    };
    const valid_arcs = [_]Arc{.{ .label = 'a', .target = @enumFromInt(0), .before = 0 }};
    var domains: model.DomainCatalogue = .{};
    try domains.setOwned(model.Domain{ .string = {} }, 1);
    try domains.setOwned(model.Domain{ .record = .entry }, 1);

    var valid = try assembleTestWire(std.testing.allocator, &rows, &groups, &ends, &valid_states, &valid_arcs);
    defer valid.deinit();
    try (try View.open(valid.bytes)).verify(std.testing.allocator, pool, domains);

    const wrong_measure = [_]State{
        valid_states[0],
        .{ .arc_end = 1, .suffix_count = 2, .terminal = false },
    };
    var measured = try assembleTestWire(std.testing.allocator, &rows, &groups, &ends, &wrong_measure, &valid_arcs);
    defer measured.deinit();
    try std.testing.expectError(error.InvalidFormat, (try View.open(measured.bytes)).verify(std.testing.allocator, pool, domains));

    const unreachable_states = [_]State{
        valid_states[0],
        .{ .arc_end = 1, .suffix_count = 2, .terminal = true },
        .{ .arc_end = 2, .suffix_count = 1, .terminal = false },
    };
    const unreachable_arcs = [_]Arc{
        .{ .label = 'x', .target = @enumFromInt(0), .before = 1 },
        .{ .label = 'a', .target = @enumFromInt(0), .before = 0 },
    };
    var stranded = try assembleTestWire(std.testing.allocator, &rows, &groups, &ends, &unreachable_states, &unreachable_arcs);
    defer stranded.deinit();
    try std.testing.expectError(error.InvalidFormat, (try View.open(stranded.bytes)).verify(std.testing.allocator, pool, domains));

    const no_rows = [_]Row{};
    const no_groups = [_][]const model.Ref(.entry){};
    const no_ends = [_]HitEnd{};
    const dead_states = [_]State{
        .{ .arc_end = 0, .suffix_count = 0, .terminal = false },
        .{ .arc_end = 1, .suffix_count = 0, .terminal = false },
    };
    const dead_arcs = [_]Arc{.{ .label = 'a', .target = @enumFromInt(0), .before = 0 }};
    var dead = try assembleTestWire(std.testing.allocator, &no_rows, &no_groups, &no_ends, &dead_states, &dead_arcs);
    defer dead.deinit();
    try std.testing.expectError(error.InvalidFormat, (try View.open(dead.bytes)).verify(std.testing.allocator, pool, domains));

    const wrong_arc = [_]Arc{.{ .label = 'b', .target = @enumFromInt(0), .before = 0 }};
    var mismatched = try assembleTestWire(std.testing.allocator, &rows, &groups, &ends, &valid_states, &wrong_arc);
    defer mismatched.deinit();
    try std.testing.expectError(error.InvalidFormat, (try View.open(mismatched.bytes)).verify(std.testing.allocator, pool, domains));
}
