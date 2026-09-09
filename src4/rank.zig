//! Typed rank arithmetic and the interval/list set boundary used by LEX4.
//!
//! A rank is an ordinal in one particular kind domain.  It is deliberately
//! not a node number, a byte offset, or a packed pair of integers.  The
//! `none` value is reserved for invalid/unset values; all real ranks are
//! constructed through checked helpers.  Intervals are half-open, so the
//! upper bound is a position and may be one past the last rank.

const std = @import("std");
const schema = @import("schema.zig");

pub const Kind = schema.Kind;
pub const Node = schema.Node;
pub const Rank = schema.Rank;
pub const KindSet = schema.KindSet;
pub const kinds = schema.kinds;
pub const kind_count: usize = schema.kind_count;

pub const Error = error{
    InvalidKind,
    InvalidRank,
    InvalidInterval,
    OutOfRange,
    RequiresMaterialization,
    InvalidProjection,
    Overflow,
    Unsorted,
    Duplicate,
    BufferTooSmall,
};

fn rankFromIndex(comptime kind: Kind, index: usize) Error!Rank(kind) {
    return Rank(kind).fromIndex(index) catch error.OutOfRange;
}

fn rankIndex(comptime kind: Kind, value: Rank(kind)) Error!usize {
    return value.index() orelse error.InvalidRank;
}

fn nodeIndex(value: Node) Error!usize {
    const raw = @intFromEnum(value);
    return if (raw == std.math.maxInt(u32)) error.InvalidRank else raw;
}

pub fn rankAdd(comptime kind: Kind, value: Rank(kind), amount: usize) Error!Rank(kind) {
    const base = try rankIndex(kind, value);
    const sum = std.math.add(usize, base, amount) catch return error.Overflow;
    return rankFromIndex(kind, sum);
}

pub fn rankBefore(comptime kind: Kind, value: Rank(kind)) Error!Rank(kind) {
    const base = try rankIndex(kind, value);
    if (base == 0) return error.OutOfRange;
    return rankFromIndex(kind, base - 1);
}

pub fn rankDistance(comptime kind: Kind, lo: Rank(kind), hi: Rank(kind)) Error!usize {
    const left = try rankIndex(kind, lo);
    const right = try rankIndex(kind, hi);
    if (right < left) return error.InvalidInterval;
    return right - left;
}

pub fn nodeRange(comptime kind: Kind, lo: Rank(kind), hi: Rank(kind)) Error!Interval(kind) {
    return Interval(kind).init(lo, hi);
}

pub fn Interval(comptime kind: Kind) type {
    const R = Rank(kind);
    return struct {
        lo: R,
        hi: R,

        pub const RankType = R;
        pub const Kind = kind;

        pub fn init(lo: R, hi: R) Error!@This() {
            const left = rankIndex(kind, lo) catch return error.InvalidInterval;
            const right = rankIndex(kind, hi) catch return error.InvalidInterval;
            if (right < left) return error.InvalidInterval;
            return .{ .lo = lo, .hi = hi };
        }

        pub fn empty() @This() {
            return .{ .lo = @enumFromInt(0), .hi = @enumFromInt(0) };
        }

        pub fn len(self: @This()) usize {
            const left = @intFromEnum(self.lo);
            const right = @intFromEnum(self.hi);
            return if (right >= left) right - left else 0;
        }

        pub fn isEmpty(self: @This()) bool {
            return self.lo == self.hi;
        }

        pub fn contains(self: @This(), value: R) bool {
            const raw = @intFromEnum(value);
            return raw != std.math.maxInt(u32) and
                raw >= @intFromEnum(self.lo) and raw < @intFromEnum(self.hi);
        }

        pub fn at(self: @This(), offset: usize) Error!R {
            if (offset >= self.len()) return error.OutOfRange;
            return rankFromIndex(kind, @intFromEnum(self.lo) + offset);
        }

        pub fn take(self: @This(), amount: usize) @This() {
            const width = @min(amount, self.len());
            return .{
                .lo = self.lo,
                .hi = @enumFromInt(@intFromEnum(self.lo) + width),
            };
        }

        /// Return the interval after skipping `amount` positions.
        pub fn after(self: @This(), amount: usize) @This() {
            const skip = @min(amount, self.len());
            return .{
                .lo = @enumFromInt(@intFromEnum(self.lo) + skip),
                .hi = self.hi,
            };
        }

        pub fn intersect(self: @This(), other: @This()) @This() {
            const left = @max(@intFromEnum(self.lo), @intFromEnum(other.lo));
            const right = @min(@intFromEnum(self.hi), @intFromEnum(other.hi));
            return .{
                .lo = @enumFromInt(left),
                .hi = @enumFromInt(@max(left, right)),
            };
        }

        /// Return the single interval containing both operands when their
        /// union is interval-closed. `null` means a materialised list is
        /// required (the intervals are disjoint and non-adjacent).
        pub fn unionClosed(self: @This(), other: @This()) ?@This() {
            if (self.isEmpty()) return other;
            if (other.isEmpty()) return self;
            if (!self.touches(other)) return null;
            const left = @min(@intFromEnum(self.lo), @intFromEnum(other.lo));
            const right = @max(@intFromEnum(self.hi), @intFromEnum(other.hi));
            return .{ .lo = @enumFromInt(left), .hi = @enumFromInt(right) };
        }

        pub fn touches(self: @This(), other: @This()) bool {
            return @intFromEnum(self.hi) >= @intFromEnum(other.lo) and
                @intFromEnum(other.hi) >= @intFromEnum(self.lo);
        }
    };
}

/// A sorted, unique list is the materialised arm of NodeSet.  Empty lists are
/// valid and have no multiplicity; duplicate values are rejected at the
/// boundary instead of silently changing a query's cardinality.
pub fn NodeSet(comptime kind: Kind) type {
    const R = Rank(kind);
    const I = Interval(kind);
    return union(enum) {
        interval: I,
        list: []const R,

        pub const RankType = R;
        pub const Kind = kind;

        pub fn empty() @This() {
            return .{ .interval = I.empty() };
        }

        pub fn fromInterval(value: I) @This() {
            return .{ .interval = value };
        }

        pub fn fromList(values: []const R) Error!@This() {
            var previous: ?u32 = null;
            for (values) |value| {
                const raw = @intFromEnum(value);
                if (raw == std.math.maxInt(u32)) return error.InvalidRank;
                if (previous) |prior| {
                    if (raw < prior) return error.Unsorted;
                    if (raw == prior) return error.Duplicate;
                }
                previous = raw;
            }
            return .{ .list = values };
        }

        pub fn len(self: @This()) usize {
            return switch (self) {
                .interval => |value| value.len(),
                .list => |values| values.len,
            };
        }

        pub fn isEmpty(self: @This()) bool {
            return self.len() == 0;
        }

        pub fn at(self: @This(), index: usize) Error!R {
            return switch (self) {
                .interval => |value| value.at(index),
                .list => |values| if (index < values.len) values[index] else error.OutOfRange,
            };
        }

        pub fn take(self: @This(), amount: usize) @This() {
            return switch (self) {
                .interval => |value| .{ .interval = value.take(amount) },
                .list => |values| .{ .list = values[0..@min(amount, values.len)] },
            };
        }

        pub fn after(self: @This(), amount: usize) @This() {
            return switch (self) {
                .interval => |value| .{ .interval = value.after(amount) },
                .list => |values| .{ .list = values[@min(amount, values.len)..] },
            };
        }

        pub fn contains(self: @This(), value: R) bool {
            return switch (self) {
                .interval => |range| range.contains(value),
                .list => |values| binarySearch(kind, values, value) != null,
            };
        }

        pub fn validate(self: @This()) Error!void {
            switch (self) {
                .interval => |value| _ = try I.init(value.lo, value.hi),
                .list => |values| _ = try fromList(values),
            }
        }
    };
}

/// Allocation is part of the operator plan, rather than an implementation
/// detail hidden behind a read-path call.  `conditional` means that an
/// interval-closed pair stays borrowed while a disjoint/list pair needs an
/// owned materialisation.
pub const Allocation = enum { never, conditional, always };

pub const Operator = enum {
    take,
    after,
    monotone_projection,
    union_set,
    intersection,
};

pub const OperatorPlan = struct {
    preserves_interval: bool,
    allocation: Allocation,
};

pub fn operatorPlan(comptime operation: Operator) OperatorPlan {
    return switch (operation) {
        .take, .after, .monotone_projection => .{ .preserves_interval = true, .allocation = .never },
        .union_set, .intersection => .{ .preserves_interval = true, .allocation = .conditional },
    };
}

/// A typed query pipeline over one kind-rank domain.  Methods that can stay
/// interval-shaped return another borrowed `Set(kind)`; methods that may need
/// a list return `OwnedNodeSet(kind)` and require the allocator explicitly.
/// The comptime kind parameter prevents an entry set from being passed to a
/// sense-only operator or projector accidentally.
pub fn Set(comptime kind: Kind) type {
    const S = NodeSet(kind);
    return struct {
        const Self = @This();

        pub const Kind = kind;
        pub const RankType = Rank(kind);
        value: S,

        pub fn empty() Self {
            return .{ .value = S.empty() };
        }

        pub fn from(value: S) Self {
            return .{ .value = value };
        }

        pub fn fromInterval(value: Interval(kind)) Self {
            return .{ .value = S.fromInterval(value) };
        }

        pub fn borrow(self: Self) S {
            return self.value;
        }

        pub fn len(self: Self) usize {
            return self.value.len();
        }

        pub fn isEmpty(self: Self) bool {
            return self.value.isEmpty();
        }

        pub fn contains(self: Self, value: Rank(kind)) bool {
            return self.value.contains(value);
        }

        pub fn take(self: Self, amount: usize) Self {
            return .{ .value = self.value.take(amount) };
        }

        pub fn after(self: Self, amount: usize) Self {
            return .{ .value = self.value.after(amount) };
        }

        pub fn plan(comptime operation: Operator) OperatorPlan {
            return operatorPlan(operation);
        }

        /// Interval/interval union is allocation-free only when the union is
        /// itself an interval. A `null` result tells the planner to choose the
        /// explicitly allocating `unionMaterialized` path.
        pub fn unionClosed(self: Self, other: Self) ?Self {
            if (self.value == .interval and other.value == .interval) {
                if (self.value.interval.unionClosed(other.value.interval)) |joined|
                    return .{ .value = .{ .interval = joined } };
            }
            return null;
        }

        pub fn unionMaterialized(self: Self, allocator: std.mem.Allocator, other: Self) (Error || std.mem.Allocator.Error)!OwnedNodeSet(kind) {
            return unionSet(kind, allocator, self.value, other.value);
        }

        pub fn intersectMaterialized(self: Self, allocator: std.mem.Allocator, other: Self) (Error || std.mem.Allocator.Error)!OwnedNodeSet(kind) {
            return intersectSet(kind, allocator, self.value, other.value);
        }

        /// Apply a caller-supplied monotone projection while the source is an
        /// interval. The tiny trait is checked at comptime: its declared input
        /// and output domains must match this Set and the requested result.
        /// A list input is an explicit materialisation boundary.
        pub fn projectMonotoneInterval(self: Self, comptime output_kind: schema.Kind, projector: anytype) (Error || std.mem.Allocator.Error)!Set(output_kind) {
            const P = @TypeOf(projector);
            comptime {
                if (!@hasDecl(P, "input_kind") or !@hasDecl(P, "output_kind") or !@hasDecl(P, "apply"))
                    @compileError("monotone projector must declare input_kind, output_kind, and apply");
                if (P.input_kind != kind)
                    @compileError("monotone projector input domain does not match Set(kind)");
                if (P.output_kind != output_kind)
                    @compileError("monotone projector output domain does not match requested kind");
            }
            return switch (self.value) {
                .interval => |source| .{ .value = .{ .interval = projector.apply(source) catch |err| return err } },
                .list => error.RequiresMaterialization,
            };
        }
    };
}

pub fn OwnedNodeSet(comptime kind: Kind) type {
    const NodeSetType = NodeSet(kind);
    const R = Rank(kind);
    return struct {
        allocator: std.mem.Allocator,
        set: NodeSetType,
        storage: ?[]R = null,

        pub fn deinit(self: *@This()) void {
            if (self.storage) |storage| self.allocator.free(storage);
            self.* = undefined;
        }

        pub fn borrow(self: *const @This()) NodeSetType {
            return self.set;
        }
    };
}

pub fn clone(comptime kind: Kind, allocator: std.mem.Allocator, set: NodeSet(kind)) std.mem.Allocator.Error!OwnedNodeSet(kind) {
    const R = Rank(kind);
    switch (set) {
        .interval => return .{ .allocator = allocator, .set = set },
        .list => |values| {
            if (values.len == 0) return .{ .allocator = allocator, .set = .{ .list = values } };
            const storage = try allocator.dupe(R, values);
            return .{ .allocator = allocator, .set = .{ .list = storage }, .storage = storage };
        },
    }
}

/// Merge two sorted sets.  Interval/interval unions remain allocation-free
/// when they overlap or touch; all other materialised results own their list.
pub fn unionSet(comptime kind: Kind, allocator: std.mem.Allocator, left: NodeSet(kind), right: NodeSet(kind)) (Error || std.mem.Allocator.Error)!OwnedNodeSet(kind) {
    const NodeSetType = NodeSet(kind);
    const R = Rank(kind);
    if (left.isEmpty()) return .{ .allocator = allocator, .set = right };
    if (right.isEmpty()) return .{ .allocator = allocator, .set = left };
    if (left == .interval and right == .interval) {
        const a = left.interval;
        const b = right.interval;
        if (a.unionClosed(b)) |joined| return .{ .allocator = allocator, .set = .{ .interval = joined } };
    } else if (left == .interval and right == .list) {
        if (left.interval.contains(right.list[0]) and left.interval.contains(right.list[right.list.len - 1]))
            return .{ .allocator = allocator, .set = left };
    } else if (left == .list and right == .interval) {
        if (right.interval.contains(left.list[0]) and right.interval.contains(left.list[left.list.len - 1]))
            return .{ .allocator = allocator, .set = right };
    }

    const max_len = std.math.add(usize, left.len(), right.len()) catch return error.Overflow;
    const storage = try allocator.alloc(R, max_len);
    errdefer allocator.free(storage);
    var i: usize = 0;
    var j: usize = 0;
    var out: usize = 0;
    while (i < left.len() or j < right.len()) {
        const a = if (i < left.len()) try left.at(i) else null;
        const b = if (j < right.len()) try right.at(j) else null;
        const next = if (a == null) b.? else if (b == null) a.? else if (@intFromEnum(a.?) < @intFromEnum(b.?)) a.? else b.?;
        if (out == 0 or @intFromEnum(storage[out - 1]) != @intFromEnum(next)) {
            storage[out] = next;
            out += 1;
        }
        if (a) |value| {
            if (@intFromEnum(value) == @intFromEnum(next)) i += 1;
        }
        if (b) |value| {
            if (@intFromEnum(value) == @intFromEnum(next)) j += 1;
        }
    }
    return .{ .allocator = allocator, .set = try NodeSetType.fromList(storage[0..out]), .storage = storage };
}

pub fn intersectSet(comptime kind: Kind, allocator: std.mem.Allocator, left: NodeSet(kind), right: NodeSet(kind)) (Error || std.mem.Allocator.Error)!OwnedNodeSet(kind) {
    const NodeSetType = NodeSet(kind);
    const R = Rank(kind);
    if (left == .interval and right == .interval) {
        return .{ .allocator = allocator, .set = .{ .interval = left.interval.intersect(right.interval) } };
    }

    // A sorted materialised list is already the representation required by
    // an interval/list intersection. Its surviving slice is contiguous, so
    // the operator can borrow that slice instead of allocating a second list.
    if (left == .interval and right == .list) {
        const first = lowerBound(kind, right.list, left.interval.lo);
        const last = lowerBound(kind, right.list, left.interval.hi);
        return .{ .allocator = allocator, .set = .{ .list = right.list[first..last] } };
    }
    if (left == .list and right == .interval) {
        const first = lowerBound(kind, left.list, right.interval.lo);
        const last = lowerBound(kind, left.list, right.interval.hi);
        return .{ .allocator = allocator, .set = .{ .list = left.list[first..last] } };
    }

    if (left.isEmpty() or right.isEmpty()) {
        return .{ .allocator = allocator, .set = .{ .list = &.{} } };
    }

    const capacity = @min(left.len(), right.len());
    const storage = try allocator.alloc(R, capacity);
    errdefer allocator.free(storage);
    var i: usize = 0;
    var j: usize = 0;
    var out: usize = 0;
    while (i < left.len() and j < right.len()) {
        const a = try left.at(i);
        const b = try right.at(j);
        if (@intFromEnum(a) == @intFromEnum(b)) {
            storage[out] = a;
            out += 1;
            i += 1;
            j += 1;
        } else if (@intFromEnum(a) < @intFromEnum(b)) {
            i += 1;
        } else {
            j += 1;
        }
    }
    return .{ .allocator = allocator, .set = try NodeSetType.fromList(storage[0..out]), .storage = storage };
}

fn lowerBound(comptime kind: Kind, values: []const Rank(kind), needle: Rank(kind)) usize {
    var lo: usize = 0;
    var hi: usize = values.len;
    const wanted = @intFromEnum(needle);
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (@intFromEnum(values[mid]) < wanted) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn binarySearch(comptime kind: Kind, values: []const Rank(kind), needle: Rank(kind)) ?usize {
    var lo: usize = 0;
    var hi: usize = values.len;
    const wanted = @intFromEnum(needle);
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const value = @intFromEnum(values[mid]);
        if (value == wanted) return mid;
        if (value < wanted) lo = mid + 1 else hi = mid;
    }
    return null;
}
