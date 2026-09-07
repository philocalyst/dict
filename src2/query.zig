//! Composable, budgeted queries over immutable snapshot views.
//!
//! Every producer returns a sorted unique NodeSet. Forest kind indexes and
//! materialized edge directions are used directly; the only baseline operator
//! that performs a declared scan is fuzzy key matching. Prose remains untouched
//! until materialization has planned and accepted its complete pin set.

const std = @import("std");
const edge_mod = @import("edges.zig");
const forest_mod = @import("forest.zig");
const keys = @import("keys.zig");
const prose = @import("prose.zig");
const schema = @import("schema.zig");
const snapshot_mod = @import("snapshot.zig");
const text_profile = @import("text.zig");

pub const Node = schema.Node;
pub const Error = snapshot_mod.Error || keys.Error || prose.Error || forest_mod.Error || edge_mod.Error || text_profile.Error || error{
    ScanDisallowed,
    InvalidOperation,
    InvalidColumn,
    InvalidReference,
    BudgetExceeded,
    OutOfMemory,
};

pub const Options = struct {
    max_visited: usize = 1_000_000,
    max_blocks: usize = 8,
    allow_scan: bool = true,
    max_key_scratch: usize = keys.max_key_bytes,
};

pub const Mode = enum { exact, prefix, range, fuzzy };
pub const TermMode = enum { all, any };
pub const DistinctBy = enum { node, root };
pub const Compare = enum { eq, ne, lt, le, gt, ge, present, absent };

/// Textual atom/key values are accepted by spelling, not leaked ordinals.
pub const ColumnValue = union(enum) {
    atom: []const u8,
    key: []const u8,
    prose: u32,
    bytes: []const u8,
    u64: u64,
    i64: i64,
    node: Node,
    enum_value: u8,
    span: schema.Span,
};

const KeyOp = struct {
    space: schema.KeySpaceId,
    needle: []const u8,
    upper: ?[]const u8,
    mode: Mode,
    distance: u8,
};
const ColumnOp = struct { id: schema.ColumnId, cmp: Compare, value: ?ColumnValue };
const TermsOp = struct { values: []const []const u8, mode: TermMode };

pub const Op = union(enum) {
    key: KeyOp,
    terms: TermsOp,
    ids: []const Node,
    roots,
    all: schema.Kind,
    descendants,
    ancestors,
    children,
    parent,
    root,
    follow: schema.PredicateId,
    follow_named: []const u8,
    back: schema.PredicateId,
    participants: ?[]const u8,
    assertions_of: schema.PredicateId,
    kind: schema.Kind,
    lang: []const u8,
    column: ColumnOp,
    both: *const Query,
    either: *const Query,
    except: *const Query,
    distinct: DistinctBy,
    take: usize,
    after: Node,
};

pub const NodeSet = struct {
    items: []const Node,

    pub fn len(self: NodeSet) usize {
        return self.items.len;
    }

    pub fn isSorted(self: NodeSet) bool {
        if (self.items.len < 2) return true;
        for (self.items[1..], self.items[0..self.items.len -| 1]) |current, previous|
            if (@intFromEnum(current) <= @intFromEnum(previous)) return false;
        return true;
    }
};

pub const Explain = struct {
    visited: usize = 0,
    scanned: usize = 0,
    indexed: usize = 0,
    blocks: usize = 0,
    outputs: usize = 0,
    scan: bool = false,
};

pub const MaterializedValue = union(schema.Repr) {
    atom: []const u8,
    key: []const u8,
    prose: []const u8,
    node: Node,
    enum_value: u8,
    span: schema.Span,
    bytes: []const u8,
    u64: u64,
    i64: i64,
};

pub const Field = struct { id: schema.ColumnId, value: ?MaterializedValue };

pub const Row = struct {
    node: Node,
    root: Node,
    fields: []const Field,

    pub fn value(self: Row, id: schema.ColumnId) ?MaterializedValue {
        for (self.fields) |field| if (field.id == id) return field.value;
        return null;
    }

    /// Convenience for renderers: atoms, keys, prose, and opaque bytes all
    /// expose their borrowed byte slice through one accessor.
    pub fn get(self: Row, id: schema.ColumnId) ?[]const u8 {
        const materialized = self.value(id) orelse return null;
        return switch (materialized) {
            .atom => |bytes| bytes,
            .key => |bytes| bytes,
            .prose => |bytes| bytes,
            .bytes => |bytes| bytes,
            else => null,
        };
    }
};

pub const Rows = struct {
    allocator: std.mem.Allocator,
    rows: []Row,
    fields: []Field,
    pins: []prose.Pin,
    position: usize = 0,

    pub fn next(self: *Rows) ?Row {
        if (self.position == self.rows.len) return null;
        defer self.position += 1;
        return self.rows[self.position];
    }

    pub fn deinit(self: *Rows) void {
        for (self.pins) |*pin| pin.deinit();
        self.allocator.free(self.pins);
        self.allocator.free(self.fields);
        self.allocator.free(self.rows);
        self.* = undefined;
    }
};

pub const Materialized = Rows;

pub const Query = struct {
    snapshot: *const snapshot_mod.Snapshot,
    allocator: std.mem.Allocator,
    options: Options,
    operations: std.ArrayList(Op) = .empty,
    pending: ?Error = null,
    last: Explain = .{},
    key_scratch: ?[]u8 = null,
    decoder: prose.Decoder = .{},

    pub fn init(snapshot: *const snapshot_mod.Snapshot, arena: *std.heap.ArenaAllocator, options: Options) Query {
        return .{ .snapshot = snapshot, .allocator = arena.allocator(), .options = options, .pending = if (snapshot.ready) null else error.InvalidOperation };
    }

    pub fn deinit(self: *Query) void {
        self.decoder.deinit();
        self.operations.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn explain(self: *const Query) Explain {
        return self.last;
    }

    /// The allocation-free indexed seed. Scratch and output belong to the
    /// caller, so a server can reuse one request workspace indefinitely.
    /// The returned sorted set borrows `output` until its next use. Each
    /// decoded restart key and posting is included in the work budget.
    pub fn lookup(self: *Query, space: schema.KeySpaceId, needle: []const u8, mode: Mode, key_buffer: []u8, output: []Node) Error!NodeSet {
        if (self.pending) |err| return err;
        if (mode != .exact and mode != .prefix) return error.InvalidOperation;
        self.last = .{};
        var view = try self.snapshot.keySpace(space);
        if (!view.has_postings) return error.InvalidOperation;
        view.work = .{ .visited = &self.last.visited, .indexed = &self.last.indexed, .limit = self.options.max_visited };
        var length: usize = 0;
        if (mode == .exact) {
            if (try view.exact(needle, key_buffer)) |hit| try collectInto(&view, hit, output, &length);
        } else {
            var iterator = try view.prefix(needle, key_buffer);
            while (try iterator.next()) |hit| try collectInto(&view, hit, output, &length);
        }
        const result = output[0..length];
        std.mem.sortUnstable(Node, result, {}, lessNode);
        self.last.outputs = deduplicate(result);
        return .{ .items = result[0..self.last.outputs] };
    }

    fn collectInto(view: *const keys.View, hit: keys.Hit, output: []Node, length: *usize) Error!void {
        if (hit.posting_count > output.len - length.*) return error.BufferTooSmall;
        var postings = try view.postingIterator(hit);
        while (try postings.next()) |raw| {
            output[length.*] = @enumFromInt(std.math.cast(u32, raw) orelse return error.InvalidReference);
            length.* += 1;
        }
    }

    fn scratch(self: *Query) Error![]u8 {
        if (self.key_scratch == null) self.key_scratch = try self.allocator.alloc(u8, self.options.max_key_scratch);
        return self.key_scratch.?;
    }

    pub fn key(self: *Query, space: schema.KeySpaceId, needle: []const u8, mode: Mode) *Query {
        return self.push(.{ .key = .{
            .space = space,
            .needle = self.copy(needle),
            .upper = null,
            .mode = mode,
            .distance = 0,
        } });
    }

    pub fn keyRange(self: *Query, space: schema.KeySpaceId, lower: []const u8, upper: []const u8) *Query {
        return self.push(.{ .key = .{
            .space = space,
            .needle = self.copy(lower),
            .upper = self.copy(upper),
            .mode = .range,
            .distance = 0,
        } });
    }

    pub fn fuzzy(self: *Query, space: schema.KeySpaceId, needle: []const u8, distance: u8) *Query {
        return self.push(.{ .key = .{
            .space = space,
            .needle = self.copy(needle),
            .upper = null,
            .mode = .fuzzy,
            .distance = distance,
        } });
    }

    /// Suffix matching uses the exact same UTF-8 scalar reversal profile as
    /// compilation. Byte reversal would silently create invalid search keys.
    pub fn suffix(self: *Query, needle: []const u8) *Query {
        const normalized = text_profile.normalize(self.allocator, needle) catch |err| {
            self.pending = err;
            return self;
        };
        const reversed = text_profile.reverseScalars(self.allocator, normalized) catch |err| {
            self.pending = err;
            return self;
        };
        return self.push(.{ .key = .{
            .space = .reversed,
            .needle = reversed,
            .upper = null,
            .mode = .prefix,
            .distance = 0,
        } });
    }

    /// Seed from the full-text term index. `all` intersects postings while
    /// `any` unions them; neither mode decodes prose.
    pub fn terms(self: *Query, values: anytype, mode: TermMode) *Query {
        const owned_values = self.allocator.alloc([]const u8, values.len) catch {
            self.pending = error.OutOfMemory;
            return self;
        };
        if (comptime isTupleLike(@TypeOf(values))) {
            inline for (values, 0..) |value, i| owned_values[i] = self.copy(value);
        } else {
            for (values, 0..) |value, i| owned_values[i] = self.copy(value);
        }
        return self.push(.{ .terms = .{ .values = owned_values, .mode = mode } });
    }

    pub fn ids(self: *Query, values: anytype) *Query {
        const owned_values = self.allocator.alloc(Node, values.len) catch {
            self.pending = error.OutOfMemory;
            return self;
        };
        if (comptime isTupleLike(@TypeOf(values))) {
            inline for (values, 0..) |value, i| owned_values[i] = asNode(value) catch |err| {
                self.pending = err;
                return self;
            };
        } else {
            for (values, 0..) |value, i| owned_values[i] = asNode(value) catch |err| {
                self.pending = err;
                return self;
            };
        }
        return self.push(.{ .ids = owned_values });
    }

    pub const all = pushValue("all", schema.Kind);
    pub const follow = pushValue("follow", schema.PredicateId);
    pub const back = pushValue("back", schema.PredicateId);
    pub const assertionsOf = pushValue("assertions_of", schema.PredicateId);
    pub const kind = pushValue("kind", schema.Kind);

    pub fn assertions(self: *Query, name: []const u8) *Query {
        return self.all(.assertion).column(.predicate, .eq, .{ .atom = name });
    }

    /// Runtime vocabulary is selected by its stored predicate spelling. The
    /// extension adjacency alone intentionally makes no promise about meaning.
    pub fn followNamed(self: *Query, name: []const u8) *Query {
        return self.push(.{ .follow_named = self.copy(name) });
    }

    pub fn participants(self: *Query, role: ?[]const u8) *Query {
        return self.push(.{ .participants = if (role) |value| self.copy(value) else null });
    }

    pub fn lang(self: *Query, value: []const u8) *Query {
        return self.push(.{ .lang = self.copy(value) });
    }

    pub fn column(self: *Query, id: schema.ColumnId, cmp: Compare, value: ?ColumnValue) *Query {
        return self.push(.{ .column = .{
            .id = id,
            .cmp = cmp,
            .value = if (value) |present| self.copyValue(present) else null,
        } });
    }

    pub const roots = pushTag("roots");
    pub const descendants = pushTag("descendants");
    pub const ancestors = pushTag("ancestors");
    pub const children = pushTag("children");
    pub const parent = pushTag("parent");
    pub const root = pushTag("root");
    pub const columnPresent = columnTag(.present);
    pub const columnAbsent = columnTag(.absent);
    pub const both = pushValue("both", *const Query);
    pub const either = pushValue("either", *const Query);
    pub const except = pushValue("except", *const Query);
    pub const distinct = pushValue("distinct", DistinctBy);
    pub const intersect = both;
    pub const unionWith = either;
    pub const difference = except;
    pub const distinctBy = distinct;
    pub const take = pushValue("take", usize);
    pub const after = pushValue("after", Node);

    pub fn run(self: *Query) Error!NodeSet {
        if (self.pending) |err| return err;
        self.last = .{};
        var context = Context{ .query = self, .explain = &self.last };
        const result = try runPipeline(self, &context);
        self.last.outputs = result.items.len;
        return result;
    }

    /// Materialize arbitrary schema columns. The complete distinct prose block
    /// set is counted and budgeted before the first block is decoded.
    pub fn materialize(self: *Query, set: NodeSet, requested: []const schema.ColumnId) Error!Rows {
        if (self.pending) |err| return err;
        if (!set.isSorted()) return error.InvalidOperation;
        for (requested, 0..) |id, i| {
            if (@intFromEnum(id) >= schema.columnTypes().len) return error.InvalidColumn;
            for (requested[0..i]) |prior| if (prior == id) return error.InvalidColumn;
        }
        const f = try self.snapshot.forest();
        for (set.items) |node| if (@intFromEnum(node) >= f.count) return error.InvalidReference;
        const needs_prose = columnsNeedProse(requested);
        var block_ids: std.ArrayList(usize) = .empty;
        defer block_ids.deinit(self.allocator);
        var store: ?prose.Store = null;
        if (needs_prose) {
            store = try self.snapshot.prose(.{});
            for (set.items) |node| {
                var present = false;
                for (requested) |id| inline for (schema.columnTypes()) |C|
                    if (C.repr == .prose and id == C.Id and (try self.snapshot.get(C, node)) != null) {
                        present = true;
                    };
                if (present) {
                    const block = store.?.blockForNode(@intFromEnum(node)) orelse return error.InvalidReference;
                    try block_ids.append(self.allocator, block);
                }
            }
            std.mem.sortUnstable(usize, block_ids.items, {}, std.sort.asc(usize));
            block_ids.shrinkRetainingCapacity(deduplicate(block_ids.items));
            self.last.blocks = block_ids.items.len;
            if (block_ids.items.len > self.options.max_blocks) return error.BudgetExceeded;
        }

        const pins = try self.allocator.alloc(prose.Pin, block_ids.items.len);
        var pinned: usize = 0;
        errdefer {
            for (pins[0..pinned]) |*pin| pin.deinit();
            self.allocator.free(pins);
        }
        if (store) |prose_store| for (block_ids.items, 0..) |block, i| {
            pins[i] = try prose_store.pinUsing(self.allocator, block, &self.decoder);
            pinned += 1;
        };

        const rows = try self.allocator.alloc(Row, set.items.len);
        errdefer self.allocator.free(rows);
        const field_count = std.math.mul(usize, set.items.len, requested.len) catch return error.OutOfMemory;
        const fields = try self.allocator.alloc(Field, field_count);
        errdefer self.allocator.free(fields);
        for (set.items, 0..) |node, row_index| {
            try self.consume(1, false);
            const row_fields = fields[row_index * requested.len ..][0..requested.len];
            for (requested, 0..) |id, field_index| {
                try self.consume(1, false);
                row_fields[field_index] = .{
                    .id = id,
                    .value = try self.materializeField(node, id, store, block_ids.items, pins),
                };
            }
            rows[row_index] = .{ .node = node, .root = try f.root(node), .fields = row_fields };
        }
        return .{ .allocator = self.allocator, .rows = rows, .fields = fields, .pins = pins };
    }

    fn materializeField(
        self: *Query,
        node: Node,
        id: schema.ColumnId,
        store: ?prose.Store,
        block_ids: []const usize,
        pins: []prose.Pin,
    ) Error!?MaterializedValue {
        inline for (schema.columnTypes()) |Column| if (id == Column.Id) {
            const value = try self.snapshot.get(Column, node) orelse return null;
            return switch (Column.repr) {
                .atom => .{ .atom = try self.keyText(.atoms, @intFromEnum(value)) },
                .key => .{ .key = try self.keyText(Column.keySpace().?, @intFromEnum(value)) },
                .prose => blk: {
                    const prose_store = store orelse return error.InvalidOperation;
                    const block = prose_store.blockForNode(@intFromEnum(node)) orelse return error.InvalidReference;
                    const pin_index = std.mem.indexOfScalar(usize, block_ids, block) orelse return error.InvalidOperation;
                    const item = try pins[pin_index].itemForNode(@intFromEnum(node)) orelse return error.InvalidReference;
                    break :blk .{ .prose = item.text };
                },
                .node => .{ .node = value },
                .enum_value => .{ .enum_value = enumToByte(value) },
                .span => .{ .span = value },
                .bytes => .{ .bytes = value },
                .u64 => .{ .u64 = value },
                .i64 => .{ .i64 = value },
            };
        };
        return error.InvalidColumn;
    }

    fn keyText(self: *Query, space: schema.KeySpaceId, ordinal: u32) Error![]const u8 {
        var view = try self.snapshot.keySpace(space);
        view.work = .{ .visited = &self.last.visited, .indexed = &self.last.indexed, .limit = self.options.max_visited };
        const hit = (try view.ordinal(ordinal, try self.scratch())) orelse return error.InvalidReference;
        return self.allocator.dupe(u8, hit.key) catch error.OutOfMemory;
    }

    fn consume(self: *Query, amount: usize, scan: bool) Error!void {
        if (amount > self.options.max_visited -| self.last.visited) return error.BudgetExceeded;
        self.last.visited += amount;
        if (scan) {
            self.last.scan = true;
            self.last.scanned += amount;
        } else self.last.indexed += amount;
    }

    fn push(self: *Query, op: Op) *Query {
        self.operations.append(self.allocator, op) catch |err| {
            self.pending = err;
        };
        return self;
    }

    fn copy(self: *Query, bytes: []const u8) []const u8 {
        return self.allocator.dupe(u8, bytes) catch {
            self.pending = error.OutOfMemory;
            return &.{};
        };
    }

    fn copyValue(self: *Query, value: ColumnValue) ColumnValue {
        return switch (value) {
            .atom => |bytes| .{ .atom = self.copy(bytes) },
            .key => |bytes| .{ .key = self.copy(bytes) },
            .bytes => |bytes| .{ .bytes = self.copy(bytes) },
            else => value,
        };
    }
};

fn pushTag(comptime tag: []const u8) fn (*Query) *Query {
    return struct {
        fn call(self: *Query) *Query {
            return self.push(@unionInit(Op, tag, {}));
        }
    }.call;
}

fn pushValue(comptime tag: []const u8, comptime T: type) fn (*Query, T) *Query {
    return struct {
        fn call(self: *Query, value: T) *Query {
            return self.push(@unionInit(Op, tag, value));
        }
    }.call;
}

fn columnTag(comptime comparison: Compare) fn (*Query, schema.ColumnId) *Query {
    return struct {
        fn call(self: *Query, id: schema.ColumnId) *Query {
            return self.column(id, comparison, null);
        }
    }.call;
}

const Context = struct {
    query: *Query,
    explain: *Explain,
    depth: usize = 0,

    fn consume(self: *Context, amount: usize, scan: bool) Error!void {
        if (amount > self.query.options.max_visited -| self.explain.visited) return error.BudgetExceeded;
        self.explain.visited += amount;
        if (scan) {
            self.explain.scan = true;
            self.explain.scanned += amount;
        } else self.explain.indexed += amount;
    }

    fn seed(self: *Context, current: *[]const Node, seeded: *bool, values: []const Node) Error!void {
        _ = self;
        if (seeded.*) return error.InvalidOperation;
        current.* = values;
        seeded.* = true;
    }

    fn nested(self: *Context, other: *const Query) Error!NodeSet {
        if (other.snapshot != self.query.snapshot or self.depth == 64) return error.InvalidOperation;
        if (other.pending) |err| return err;
        self.depth += 1;
        defer self.depth -= 1;
        return runPipeline(other, self);
    }

    fn ids(self: *Context, input: []const Node) Error![]const Node {
        const f = try self.query.snapshot.forest();
        for (input) |node| {
            try self.consume(1, false);
            if (@intFromEnum(node) >= f.count) return error.InvalidReference;
        }
        return normalize(self.query.allocator, input);
    }

    fn roots(self: *Context) Error![]const Node {
        const f = try self.query.snapshot.forest();
        const result = try self.query.allocator.alloc(Node, f.root_count);
        for (result, 0..) |*slot, index| {
            try self.consume(1, false);
            slot.* = (try f.rootAt(index)).?;
        }
        return result;
    }

    fn all(self: *Context, wanted: schema.Kind) Error![]const Node {
        if (wanted == .any) return error.InvalidOperation;
        const f = try self.query.snapshot.forest();
        var iterator = try f.nodes(wanted);
        var result: std.ArrayList(Node) = .empty;
        while (try iterator.next()) |node| {
            try self.consume(1, false);
            try result.append(self.query.allocator, node);
        }
        return result.toOwnedSlice(self.query.allocator);
    }

    fn key(self: *Context, operation: KeyOp) Error![]const Node {
        var view = try self.query.snapshot.keySpace(operation.space);
        view.work = .{ .visited = &self.explain.visited, .indexed = &self.explain.indexed, .limit = self.query.options.max_visited };
        if (!view.has_postings) return error.InvalidOperation;
        const key_scratch = try self.query.scratch();
        var output: std.ArrayList(Node) = .empty;
        if (operation.mode == .exact) {
            if (try view.exact(operation.needle, key_scratch)) |hit| try self.postings(&view, hit, &output);
        } else if (operation.mode == .fuzzy) {
            if (!self.query.options.allow_scan) return error.ScanDisallowed;
            const distance = try self.query.allocator.alloc(u16, operation.needle.len + 1);
            var iterator = try view.fuzzy(operation.needle, operation.distance, self.query.options.max_visited -| self.explain.visited, key_scratch, distance);
            while (true) {
                const before = iterator.visited;
                const next = iterator.next() catch |err| {
                    self.explain.scanned += iterator.visited - before;
                    self.explain.scan = true;
                    return err;
                };
                self.explain.scanned += iterator.visited - before;
                self.explain.scan = true;
                const hit = next orelse break;
                try self.postings(&view, hit, &output);
            }
        } else {
            var iterator = if (operation.mode == .prefix)
                try view.prefix(operation.needle, key_scratch)
            else
                try view.range(operation.needle, operation.upper orelse return error.InvalidOperation, key_scratch);
            while (try iterator.next()) |hit| {
                try self.postings(&view, hit, &output);
            }
        }
        return normalize(self.query.allocator, output.items);
    }

    fn postings(self: *Context, view: *const keys.View, hit: keys.Hit, output: *std.ArrayList(Node)) Error!void {
        var iterator = try view.postingIterator(hit);
        while (try iterator.next()) |raw| {
            const node = std.math.cast(u32, raw) orelse return error.InvalidReference;
            try output.append(self.query.allocator, @enumFromInt(node));
        }
    }

    fn terms(self: *Context, operation: TermsOp) Error![]const Node {
        if (operation.values.len == 0) return error.InvalidOperation;
        var result: []const Node = &.{};
        var seeded = false;
        for (operation.values) |raw| {
            const normalized = try text_profile.normalize(self.query.allocator, raw);
            const one = try self.key(.{ .space = .terms, .needle = normalized, .upper = null, .mode = .exact, .distance = 0 });
            result = if (!seeded)
                one
            else
                try merge(self.query.allocator, result, one, if (operation.mode == .all) .both else .either);
            seeded = true;
        }
        return result;
    }

    fn navigate(self: *Context, input: []const Node, operation: std.meta.Tag(Op)) Error![]const Node {
        const f = try self.query.snapshot.forest();
        var output: std.ArrayList(Node) = .empty;
        for (input) |node| switch (operation) {
            .descendants, .children => {
                var current = @as(usize, @intFromEnum(node)) + 1;
                const end = try f.subtreeEnd(node);
                while (current < end) {
                    try self.consume(1, false);
                    const child: Node = @enumFromInt(@as(u32, @intCast(current)));
                    try output.append(self.query.allocator, child);
                    current = if (operation == .children) try f.subtreeEnd(child) else current + 1;
                }
            },
            .ancestors => {
                var current = try f.parentOf(node);
                while (current) |parent| {
                    try self.consume(1, false);
                    try output.append(self.query.allocator, parent);
                    current = try f.parentOf(parent);
                }
            },
            .parent => {
                try self.consume(1, false);
                if (try f.parentOf(node)) |parent| try output.append(self.query.allocator, parent);
            },
            .root => {
                try self.consume(1, false);
                try output.append(self.query.allocator, try f.root(node));
            },
            else => unreachable,
        };
        return normalize(self.query.allocator, output.items);
    }

    fn follow(self: *Context, input: []const Node, predicate: schema.PredicateId, direction: edge_mod.Direction, qualifiers_only: bool) Error![]const Node {
        if (input.len == 0) return &.{};
        const adjacency = if (direction == .forward)
            try self.query.snapshot.adjacency(predicate)
        else
            try self.query.snapshot.reverseAdjacency(predicate);
        var output: std.ArrayList(Node) = .empty;
        for (input) |source| {
            try self.consume(1, false);
            var iterator = try adjacency.edges(source);
            while (try iterator.next()) |edge| {
                try self.consume(1, false);
                if (qualifiers_only) {
                    if (edge.qualified) |assertion| try output.append(self.query.allocator, assertion);
                } else try output.append(self.query.allocator, edge.target);
            }
        }
        return normalize(self.query.allocator, output.items);
    }

    fn participants(self: *Context, input: []const Node, role_name: ?[]const u8) Error![]const Node {
        const f = try self.query.snapshot.forest();
        const role_ordinal = if (role_name) |name| try self.ordinal(.atoms, name) else null;
        if (role_name != null and role_ordinal == null) return &.{};
        var output: std.ArrayList(Node) = .empty;
        for (input) |assertion| {
            if (try f.kind(assertion) != .assertion) continue;
            var child = try f.firstChild(assertion);
            while (child) |node| : (child = try f.nextSibling(node)) {
                try self.consume(1, false);
                if (try f.kind(node) != .participant) continue;
                if (role_ordinal) |wanted| {
                    const actual = try self.query.snapshot.get(schema.columns.role, node) orelse continue;
                    if (@intFromEnum(actual) != wanted) continue;
                }
                try output.append(self.query.allocator, node);
            }
        }
        return normalize(self.query.allocator, output.items);
    }

    fn followNamed(self: *Context, input: []const Node, name: []const u8) Error![]const Node {
        for (schema.predicateTypes()) |P| if (std.mem.eql(u8, name, P.name)) return self.follow(input, P.id, .forward, false);
        const wanted = try self.ordinal(.atoms, name) orelse return &.{};
        const adjacency = try self.query.snapshot.adjacency(.extension);
        var output: std.ArrayList(Node) = .empty;
        for (input) |source| {
            try self.consume(1, false);
            var iterator = try adjacency.edges(source);
            while (try iterator.next()) |edge| {
                try self.consume(1, false);
                const assertion = edge.qualified orelse return error.InvalidReference;
                const predicate = try self.query.snapshot.get(schema.columns.predicate, assertion) orelse return error.InvalidReference;
                if (@intFromEnum(predicate) == wanted) try output.append(self.query.allocator, edge.target);
            }
        }
        return normalize(self.query.allocator, output.items);
    }

    fn filterKind(self: *Context, input: []const Node, wanted: schema.Kind) Error![]const Node {
        if (wanted == .any) return error.InvalidOperation;
        const f = try self.query.snapshot.forest();
        var output: std.ArrayList(Node) = .empty;
        for (input) |node| {
            try self.consume(1, false);
            if (try f.kind(node) == wanted) try output.append(self.query.allocator, node);
        }
        return output.toOwnedSlice(self.query.allocator);
    }

    fn filterColumn(self: *Context, input: []const Node, operation: ColumnOp) Error![]const Node {
        var output: std.ArrayList(Node) = .empty;
        for (input) |node| {
            try self.consume(1, false);
            if (try self.columnMatches(node, operation)) try output.append(self.query.allocator, node);
        }
        return output.toOwnedSlice(self.query.allocator);
    }

    fn columnMatches(self: *Context, node: Node, operation: ColumnOp) Error!bool {
        inline for (schema.columnTypes()) |Column| if (operation.id == Column.Id) {
            const actual = self.query.snapshot.column_view.getMetered(Column, node, &self.query.snapshot.forest_view, .{ .visited = &self.explain.visited, .indexed = &self.explain.indexed, .limit = self.query.options.max_visited }) catch |err|
                return if (err == error.BudgetExceeded) error.BudgetExceeded else error.CorruptSection;
            if (operation.cmp == .present) return actual != null;
            if (operation.cmp == .absent) return actual == null;
            const value = actual orelse return false;
            const wanted = operation.value orelse return error.InvalidColumn;
            const order = try compareColumn(Column, value, wanted, self);
            return comparisonMatches(operation.cmp, order);
        };
        return error.InvalidColumn;
    }

    fn ordinal(self: *Context, space: schema.KeySpaceId, value: []const u8) Error!?u32 {
        var view = try self.query.snapshot.keySpace(space);
        view.work = .{ .visited = &self.explain.visited, .indexed = &self.explain.indexed, .limit = self.query.options.max_visited };
        const key_scratch = try self.query.scratch();
        return if (try view.exact(value, key_scratch)) |hit| hit.ordinal else null;
    }

    fn spellingOrder(self: *Context, space: schema.KeySpaceId, ordinal_value: u32, spelling: []const u8) Error!std.math.Order {
        var view = try self.query.snapshot.keySpace(space);
        view.work = .{ .visited = &self.explain.visited, .indexed = &self.explain.indexed, .limit = self.query.options.max_visited };
        const key_scratch = try self.query.scratch();
        const hit = (try view.ordinal(ordinal_value, key_scratch)) orelse return error.InvalidReference;
        return std.mem.order(u8, hit.key, spelling);
    }
};

fn runPipeline(query: *const Query, context: *Context) Error!NodeSet {
    if (query.operations.items.len == 0) return error.InvalidOperation;
    // Validate the complete plan before doing work. Navigation before a seed,
    // implicit union by reseeding, and empty pipelines have no semantics.
    for (query.operations.items, 0..) |operation, i| {
        const seed_op = switch (operation) {
            .key, .terms, .ids, .roots, .all => true,
            else => false,
        };
        if ((i == 0 and !seed_op and operation != .kind) or (i != 0 and seed_op)) return error.InvalidOperation;
    }
    var current: []const Node = &.{};
    var seeded = false;
    for (query.operations.items) |operation| switch (operation) {
        .key => |value| try context.seed(&current, &seeded, try context.key(value)),
        .terms => |value| try context.seed(&current, &seeded, try context.terms(value)),
        .ids => |value| try context.seed(&current, &seeded, try context.ids(value)),
        .roots => try context.seed(&current, &seeded, try context.roots()),
        .all => |value| try context.seed(&current, &seeded, try context.all(value)),
        .descendants, .ancestors, .children, .parent, .root => current = try context.navigate(current, std.meta.activeTag(operation)),
        .follow => |value| current = try context.follow(current, value, .forward, false),
        .follow_named => |value| current = try context.followNamed(current, value),
        .back => |value| current = try context.follow(current, value, .reverse, false),
        .assertions_of => |value| current = try context.follow(current, value, .forward, true),
        .participants => |value| current = try context.participants(current, value),
        .kind => |value| {
            current = if (seeded) try context.filterKind(current, value) else try context.all(value);
            seeded = true;
        },
        .lang => |value| {
            if (!seeded) return error.InvalidOperation;
            current = try context.filterColumn(current, .{ .id = .lang, .cmp = .eq, .value = .{ .atom = value } });
        },
        .column => |value| {
            if (!seeded) return error.InvalidOperation;
            current = try context.filterColumn(current, value);
        },
        .both => |value| current = try merge(context.query.allocator, current, (try context.nested(value)).items, .both),
        .either => |value| current = try merge(context.query.allocator, current, (try context.nested(value)).items, .either),
        .except => |value| current = try merge(context.query.allocator, current, (try context.nested(value)).items, .except),
        .distinct => |value| current = try distinctNodes(context, current, value),
        .take => |value| current = current[0..@min(value, current.len)],
        .after => |value| current = afterNode(current, value),
    };
    return .{ .items = current };
}

fn compareColumn(comptime Column: type, actual: Column.Value, wanted: ColumnValue, context: *Context) Error!std.math.Order {
    return switch (Column.repr) {
        .atom => switch (wanted) {
            .atom => |spelling| context.spellingOrder(.atoms, @intFromEnum(actual), spelling),
            .u64 => |ordinal| compareInt(@intFromEnum(actual), ordinal),
            else => error.InvalidColumn,
        },
        .key => switch (wanted) {
            .key => |spelling| context.spellingOrder(Column.keySpace().?, @intFromEnum(actual), spelling),
            .u64 => |ordinal| compareInt(@intFromEnum(actual), ordinal),
            else => error.InvalidColumn,
        },
        .prose => switch (wanted) {
            .prose => |ordinal| compareInt(@intFromEnum(actual), ordinal),
            .u64 => |ordinal| compareInt(@intFromEnum(actual), ordinal),
            else => error.InvalidColumn,
        },
        .node => switch (wanted) {
            .node => |node| compareInt(@intFromEnum(actual), @intFromEnum(node)),
            else => error.InvalidColumn,
        },
        .enum_value => switch (wanted) {
            .enum_value => |value| compareInt(enumToByte(actual), value),
            .u64 => |value| compareInt(enumToByte(actual), value),
            else => error.InvalidColumn,
        },
        .span => switch (wanted) {
            .span => |span| compareSpan(actual, span),
            else => error.InvalidColumn,
        },
        .bytes => switch (wanted) {
            .bytes => |bytes| std.mem.order(u8, actual, bytes),
            else => error.InvalidColumn,
        },
        .u64 => switch (wanted) {
            .u64 => |value| compareInt(actual, value),
            else => error.InvalidColumn,
        },
        .i64 => switch (wanted) {
            .i64 => |value| std.math.order(actual, value),
            else => error.InvalidColumn,
        },
    };
}

fn comparisonMatches(comparison: Compare, order: std.math.Order) bool {
    return switch (comparison) {
        .eq => order == .eq,
        .ne => order != .eq,
        .lt => order == .lt,
        .le => order != .gt,
        .gt => order == .gt,
        .ge => order != .lt,
        .present, .absent => unreachable,
    };
}

fn compareInt(a: anytype, b: anytype) std.math.Order {
    const A = @TypeOf(a);
    const B = @TypeOf(b);
    const Wide = std.meta.Int(.unsigned, @max(@bitSizeOf(A), @bitSizeOf(B)));
    return std.math.order(@as(Wide, @intCast(a)), @as(Wide, @intCast(b)));
}

fn compareSpan(a: schema.Span, b: schema.Span) std.math.Order {
    const unit = std.math.order(@intFromEnum(a.unit), @intFromEnum(b.unit));
    if (unit != .eq) return unit;
    const start = std.math.order(a.start, b.start);
    return if (start != .eq) start else std.math.order(a.end, b.end);
}

fn enumToByte(value: anytype) u8 {
    return switch (@typeInfo(@TypeOf(value))) {
        .@"enum" => @intCast(@intFromEnum(value)),
        .int => @intCast(value),
        else => @compileError("schema enum column lowered to an unsupported type"),
    };
}

fn asNode(value: anytype) Error!Node {
    if (@TypeOf(value) == Node) return value;
    const raw = std.math.cast(u32, value) orelse return error.InvalidReference;
    return @enumFromInt(raw);
}

fn isTupleLike(comptime T: type) bool {
    const Base = switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.child,
        else => T,
    };
    return switch (@typeInfo(Base)) {
        .@"struct" => |info| info.is_tuple,
        else => false,
    };
}

const SetOperation = enum { both, either, except };

fn merge(allocator: std.mem.Allocator, a: []const Node, b: []const Node, operation: SetOperation) Error![]const Node {
    var output: std.ArrayList(Node) = .empty;
    var left: usize = 0;
    var right: usize = 0;
    while (left < a.len and right < b.len) {
        const x = @intFromEnum(a[left]);
        const y = @intFromEnum(b[right]);
        if (x == y) {
            if (operation != .except) try output.append(allocator, a[left]);
            left += 1;
            right += 1;
        } else if (x < y) {
            if (operation != .both) try output.append(allocator, a[left]);
            left += 1;
        } else {
            if (operation == .either) try output.append(allocator, b[right]);
            right += 1;
        }
    }
    if (operation == .either) try output.appendSlice(allocator, b[right..]);
    if (operation != .both) try output.appendSlice(allocator, a[left..]);
    return output.toOwnedSlice(allocator);
}

fn normalize(allocator: std.mem.Allocator, input: []const Node) Error![]const Node {
    if (input.len == 0) return &.{};
    const output = try allocator.dupe(Node, input);
    std.mem.sortUnstable(Node, output, {}, lessNode);
    return output[0..deduplicate(output)];
}

fn distinctNodes(context: *Context, input: []const Node, by: DistinctBy) Error![]const Node {
    if (by == .node) return input;
    const f = try context.query.snapshot.forest();
    var output: std.ArrayList(Node) = .empty;
    var previous: ?Node = null;
    for (input) |node| {
        try context.consume(1, false);
        const root = try f.root(node);
        if (previous == null or previous.? != root) {
            try output.append(context.query.allocator, root);
            previous = root;
        }
    }
    return output.toOwnedSlice(context.query.allocator);
}

fn afterNode(input: []const Node, after: Node) []const Node {
    var low: usize = 0;
    var high = input.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (@intFromEnum(input[middle]) <= @intFromEnum(after)) low = middle + 1 else high = middle;
    }
    return input[low..];
}

fn columnsNeedProse(requested: []const schema.ColumnId) bool {
    for (requested) |id| {
        inline for (schema.columnTypes()) |Column| if (id == Column.Id and Column.repr == .prose) return true;
    }
    return false;
}

fn lessNode(_: void, a: Node, b: Node) bool {
    return @intFromEnum(a) < @intFromEnum(b);
}

fn deduplicate(values: anytype) usize {
    if (values.len == 0) return 0;
    var write: usize = 1;
    for (values[1..]) |value| if (!std.meta.eql(value, values[write - 1])) {
        values[write] = value;
        write += 1;
    };
    return write;
}
