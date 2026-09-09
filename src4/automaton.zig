//! The LEX4 sorted-input minimal acyclic automaton.
//!
//! Accepted entry strings are ranked by the primary-count column on states;
//! form targets are delta-coded entry ranks on their accepting state.  The
//! writer requires strictly sorted input and minimizes a mutable frontier
//! incrementally (Daciuk-style); no full trie is retained by the builder.
//! The borrowed query surface performs no allocation; structural validation is
//! explicit and separate from envelope-only open().

const std = @import("std");
const schema = @import("schema.zig");
const wire = @import("wire.zig");

/// The schema's typed rank is the only durable primary identity type.
pub const EntryRank = schema.Rank(.entry);

pub const Range = struct {
    lo: EntryRank,
    hi: EntryRank,

    pub fn len(self: Range) u32 {
        return @intFromEnum(self.hi) - @intFromEnum(self.lo);
    }
};

pub const Error = error{
    BadMagic,
    InputOutOfOrder,
    DuplicateKey,
    InvalidMultiplicity,
    InvalidTargets,
    InvalidTarget,
    KeyTooLong,
    UnsupportedVersion,
    Truncated,
    InvalidFormat,
    InvalidState,
    InvalidArc,
    TargetOutOfRange,
    RankOutOfRange,
    OutputTooSmall,
    DepthExceeded,
    Overflow,
};

pub const max_key_bytes: usize = 65_535;
pub const MatchKind = enum { entry, form };

const magic = "L4AM";
const version: u16 = 1;
pub const header_bytes: usize = 48;
const sparse_checkpoint_stride: u32 = 32;
// A dense state directory turns every state lookup into one checked u32 load.
// Charge that latency feature against the complete wire, not a state-count
// heuristic: at most one KiB may be spent beyond the sparse representation.
// This captures ordinary dictionaries (~200 canonical suffix states) while
// preserving stride-32 compactness for genuinely large automata.
const dense_checkpoint_budget: usize = 1024;
const wide_arcs_threshold: usize = 32;
const empty_u32 = std.math.maxInt(u32);

fn addUsize(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.Overflow;
}

fn toU32(value: usize) Error!u32 {
    return std.math.cast(u32, value) orelse error.Overflow;
}

fn appendLe(comptime T: type, out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn readLe(comptime T: type, bytes: []const u8, offset: usize) Error!T {
    const end = try addUsize(offset, @sizeOf(T));
    if (end > bytes.len) return error.Truncated;
    return std.mem.readInt(T, @as(*const [@sizeOf(T)]u8, @ptrCast(bytes[offset..end].ptr)), .little);
}

fn appendVar(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var n = value;
    while (n >= 0x80) : (n >>= 7) try out.append(allocator, @as(u8, @intCast(n & 0x7f)) | 0x80);
    try out.append(allocator, @intCast(n));
}

fn varSize(value: u32) usize {
    var n = value;
    var size: usize = 1;
    while (n >= 0x80) : (n >>= 7) size += 1;
    return size;
}

const Record = struct {
    key: []u8,
    entry_mult: u32 = 0,
    targets: []u32 = &[_]u32{},
};

// The frontier builder keeps only the prefixes shared by the next sorted
// record.  A frontier arc either points at another live frontier state or at
// an already-registered canonical suffix; separating those identities is
// what prevents a wire state id from being confused with a temporary index.
const ActiveTarget = union(enum) {
    active: u32,
    canonical: u32,
};
const ActiveArc = struct { label: u8, target: ActiveTarget };
const ActiveState = struct {
    arcs: std.ArrayList(ActiveArc) = .empty,
    entry_mult: u32 = 0,
    targets: []u32 = &[_]u32{},
};

const CanonArc = struct { label: u8, target: u32 };
const CanonState = struct {
    arcs: []CanonArc,
    entry_mult: u32,
    targets: []u32,
    primary_count: u32,
};

fn clearActive(allocator: std.mem.Allocator, state: *ActiveState) void {
    state.arcs.deinit(allocator);
    if (state.targets.len != 0) allocator.free(state.targets);
    state.* = .{};
}

fn deinitActive(allocator: std.mem.Allocator, states: *std.ArrayList(ActiveState)) void {
    for (states.items) |*state| clearActive(allocator, state);
    states.deinit(allocator);
}

fn deinitCanon(allocator: std.mem.Allocator, states: *std.ArrayList(CanonState)) void {
    for (states.items) |state| {
        if (state.arcs.len != 0) allocator.free(state.arcs);
        if (state.targets.len != 0) allocator.free(state.targets);
    }
    states.deinit(allocator);
}

pub const Owned = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Sorted-input builder.  Entry multiplicity is identity multiplicity, not
/// accepted-string multiplicity; forms never increment the primary rank.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(Record) = .empty,
    last_key: ?[]const u8 = null,
    entry_count: u32 = 0,
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        for (self.records.items) |record| {
            self.allocator.free(record.key);
            if (record.targets.len != 0) self.allocator.free(record.targets);
        }
        self.records.deinit(self.allocator);
        self.* = undefined;
    }

    fn checkKey(self: *const Builder, key: []const u8) Error!void {
        if (key.len > max_key_bytes) return error.KeyTooLong;
        if (self.last_key) |previous| switch (std.mem.order(u8, previous, key)) {
            .lt => {},
            .eq => return error.DuplicateKey,
            .gt => return error.InputOutOfOrder,
        };
    }

    pub fn addEntry(self: *Builder, key: []const u8, multiplicity: u32) !void {
        if (self.finished) return error.InvalidFormat;
        if (multiplicity == 0) return error.InvalidMultiplicity;
        try self.checkKey(key);
        const next_count = std.math.add(u32, self.entry_count, multiplicity) catch return error.Overflow;
        if (next_count == empty_u32) return error.Overflow;
        const copied = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(copied);
        try self.records.append(self.allocator, .{ .key = copied, .entry_mult = multiplicity });
        self.last_key = self.records.items[self.records.items.len - 1].key;
        self.entry_count = next_count;
    }

    pub fn addForm(self: *Builder, key: []const u8, targets: []const u32) !void {
        if (self.finished) return error.InvalidFormat;
        return self.addFormValues(key, targets);
    }

    fn addFormValues(self: *Builder, key: []const u8, targets: []const u32) !void {
        if (self.finished) return error.InvalidFormat;
        if (targets.len == 0 or targets.len > std.math.maxInt(u32)) return error.InvalidTargets;
        var previous: ?u32 = null;
        for (targets) |target| {
            if (previous) |p| if (target <= p) return error.InvalidTargets;
            previous = target;
        }
        try self.checkKey(key);
        const copied_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(copied_key);
        const copied_targets = try self.allocator.dupe(u32, targets);
        errdefer self.allocator.free(copied_targets);
        try self.records.append(self.allocator, .{ .key = copied_key, .targets = copied_targets });
        self.last_key = self.records.items[self.records.items.len - 1].key;
    }

    fn hashActive(state: *const ActiveState) Error!u64 {
        var hash: u64 = 0xcbf29ce484222325;
        hash = (hash ^ state.entry_mult) *% 0x100000001b3;
        for (state.targets) |target| hash = (hash ^ target) *% 0x100000001b3;
        for (state.arcs.items) |arc| {
            hash = (hash ^ arc.label) *% 0x100000001b3;
            switch (arc.target) {
                .canonical => |target| hash = (hash ^ target) *% 0x100000001b3,
                .active => return error.InvalidFormat,
            }
        }
        return hash;
    }

    fn equalActive(state: *const ActiveState, canonical: []const CanonState, candidate: usize) bool {
        const other = canonical[candidate];
        if (state.entry_mult != other.entry_mult or state.targets.len != other.targets.len or state.arcs.items.len != other.arcs.len) return false;
        if (!std.mem.eql(u32, state.targets, other.targets)) return false;
        for (state.arcs.items, other.arcs) |left, right| {
            if (left.label != right.label) return false;
            switch (left.target) {
                .canonical => |target| if (target != right.target) return false,
                .active => return false,
            }
        }
        return true;
    }

    fn registerActive(self: *Builder, state: *const ActiveState, canonical: *std.ArrayList(CanonState), heads: []u32, next: []u32) !u32 {
        const hash = try hashActive(state);
        const slot = @as(usize, @intCast(hash)) & (heads.len - 1);
        var candidate = heads[slot];
        while (candidate != empty_u32) : (candidate = next[@intCast(candidate)]) {
            if (equalActive(state, canonical.items, @intCast(candidate))) return candidate;
        }

        const arcs = try self.allocator.alloc(CanonArc, state.arcs.items.len);
        errdefer self.allocator.free(arcs);
        for (state.arcs.items, arcs) |arc, *out_arc| {
            switch (arc.target) {
                .canonical => |target| out_arc.* = .{ .label = arc.label, .target = target },
                .active => return error.InvalidFormat,
            }
        }
        const targets = if (state.targets.len == 0) @constCast(&[_]u32{}) else try self.allocator.dupe(u32, state.targets);
        errdefer if (targets.len != 0) self.allocator.free(targets);
        var primary = state.entry_mult;
        for (arcs) |arc| primary = std.math.add(u32, primary, canonical.items[@intCast(arc.target)].primary_count) catch return error.Overflow;
        const id = try toU32(canonical.items.len);
        if (id >= next.len) return error.Overflow;
        try canonical.append(self.allocator, .{ .arcs = arcs, .entry_mult = state.entry_mult, .targets = targets, .primary_count = primary });
        next[@intCast(id)] = heads[slot];
        heads[slot] = id;
        return id;
    }

    fn replaceActive(state: *ActiveState, label: u8, canonical: u32) Error!void {
        for (state.arcs.items) |*arc| {
            if (arc.label != label) continue;
            switch (arc.target) {
                .active => {},
                .canonical => return error.InvalidFormat,
            }
            arc.target = .{ .canonical = canonical };
            return;
        }
        return error.InvalidFormat;
    }

    /// Daciuk-style sorted frontier minimisation.  Only the common prefix of
    /// the previous and current key remains mutable; every suffix is interned
    /// bottom-up before the next record is attached.  Canonical state ids are
    /// therefore reverse-topological by construction, with no full trie or
    /// post-hoc graph pass required for minimisation.
    fn buildIncremental(self: *Builder, canonical: *std.ArrayList(CanonState)) !u32 {
        var max_states: usize = 1;
        for (self.records.items) |record| max_states = try addUsize(max_states, record.key.len);
        _ = try toU32(max_states);
        const doubled = std.math.mul(usize, max_states, 2) catch return error.Overflow;
        const required = std.math.add(usize, doubled, 1) catch return error.Overflow;
        var capacity: usize = 1;
        while (capacity < required) capacity = std.math.mul(usize, capacity, 2) catch return error.Overflow;
        const heads = try self.allocator.alloc(u32, capacity);
        defer self.allocator.free(heads);
        @memset(heads, empty_u32);
        const next = try self.allocator.alloc(u32, max_states);
        defer self.allocator.free(next);
        @memset(next, empty_u32);

        var frontier: std.ArrayList(ActiveState) = .empty;
        defer deinitActive(self.allocator, &frontier);
        try frontier.append(self.allocator, .{}); // mutable root
        var previous: []const u8 = &[_]u8{};
        var have_previous = false;

        for (self.records.items) |record| {
            var common: usize = 0;
            if (have_previous) {
                const limit = @min(previous.len, record.key.len);
                while (common < limit and previous[common] == record.key[common]) : (common += 1) {}
            }
            if (frontier.items.len != previous.len + 1) return error.InvalidFormat;

            var depth = previous.len;
            while (depth > common) {
                const canonical_id = try registerActive(self, &frontier.items[depth], canonical, heads, next);
                clearActive(self.allocator, &frontier.items[depth]);
                try replaceActive(&frontier.items[depth - 1], previous[depth - 1], canonical_id);
                depth -= 1;
            }
            frontier.shrinkRetainingCapacity(common + 1);

            var state_index = common;
            var offset = common;
            while (offset < record.key.len) : (offset += 1) {
                const child = try toU32(frontier.items.len);
                try frontier.append(self.allocator, .{});
                try frontier.items[state_index].arcs.append(self.allocator, .{ .label = record.key[offset], .target = .{ .active = child } });
                state_index += 1;
            }
            const destination = &frontier.items[state_index];
            if (destination.entry_mult != 0 or destination.targets.len != 0) return error.DuplicateKey;
            destination.entry_mult = record.entry_mult;
            if (record.targets.len != 0) destination.targets = try self.allocator.dupe(u32, record.targets);
            previous = record.key;
            have_previous = true;
        }

        var root: u32 = 0;
        var depth = frontier.items.len;
        while (depth != 0) {
            depth -= 1;
            const canonical_id = try registerActive(self, &frontier.items[depth], canonical, heads, next);
            clearActive(self.allocator, &frontier.items[depth]);
            if (depth == 0) {
                root = canonical_id;
            } else {
                try replaceActive(&frontier.items[depth - 1], previous[depth - 1], canonical_id);
            }
        }
        return root;
    }

    fn projectedStreamSize(canonical: []const CanonState, wide: bool) Error!usize {
        var total: usize = 0;
        for (canonical, 0..) |state, state_id| {
            const degree = try toU32(state.arcs.len);
            const use_wide = wide and state.arcs.len >= wide_arcs_threshold;
            var flags: u32 = 0;
            if (state.entry_mult != 0) flags |= 1;
            if (state.entry_mult > 1) flags |= 2;
            if (state.targets.len != 0) flags |= 4;
            if (use_wide) flags |= 8;
            const header_base = std.math.mul(u32, degree, 16) catch return error.Overflow;
            const header = std.math.add(u32, header_base, flags) catch return error.Overflow;
            total = std.math.add(usize, total, varSize(header)) catch return error.Overflow;
            total = std.math.add(usize, total, varSize(state.primary_count)) catch return error.Overflow;
            if (state.entry_mult > 1) total = std.math.add(usize, total, varSize(state.entry_mult - 1)) catch return error.Overflow;
            if (state.targets.len != 0) {
                total = std.math.add(usize, total, varSize(try toU32(state.targets.len))) catch return error.Overflow;
                var previous: u32 = 0;
                for (state.targets, 0..) |target, i| {
                    const delta = if (i == 0) std.math.add(u32, target, 1) catch return error.Overflow else target - previous;
                    total = std.math.add(usize, total, varSize(delta)) catch return error.Overflow;
                    previous = target;
                }
            }
            total = std.math.add(usize, total, state.arcs.len) catch return error.Overflow;
            var prefix: u32 = state.entry_mult;
            for (state.arcs) |arc| {
                if (arc.target >= state_id) return error.InvalidFormat;
                const target_delta = try toU32(state_id - @as(usize, @intCast(arc.target)));
                if (use_wide) {
                    total = std.math.add(usize, total, 8) catch return error.Overflow;
                } else {
                    total = std.math.add(usize, total, varSize(target_delta)) catch return error.Overflow;
                    total = std.math.add(usize, total, varSize(prefix)) catch return error.Overflow;
                }
                prefix = std.math.add(u32, prefix, canonical[@intCast(arc.target)].primary_count) catch return error.Overflow;
            }
            if (prefix != state.primary_count) return error.InvalidFormat;
        }
        return total;
    }

    fn projectedTotal(stream_len: usize, state_count: usize, stride: u32) Error!usize {
        if (state_count == 0) return error.InvalidFormat;
        const checkpoints = (state_count - 1) / @as(usize, @intCast(stride)) + 1;
        const directory = std.math.mul(usize, checkpoints, 4) catch return error.Overflow;
        return std.math.add(usize, header_bytes + directory, stream_len) catch return error.Overflow;
    }

    pub fn finish(self: *Builder) !Owned {
        if (self.finished) return error.InvalidFormat;
        self.finished = true;
        var canonical: std.ArrayList(CanonState) = .empty;
        defer deinitCanon(self.allocator, &canonical);
        for (self.records.items) |record| for (record.targets) |target| if (target >= self.entry_count) return error.InvalidTarget;
        const root = try self.buildIncremental(&canonical);
        if (canonical.items[@intCast(root)].primary_count != self.entry_count) return error.InvalidFormat;

        var stream: std.ArrayList(u8) = .empty;
        defer stream.deinit(self.allocator);
        var checkpoints: std.ArrayList(u32) = .empty;
        defer checkpoints.deinit(self.allocator);
        // Fixed-width arc lanes and dense checkpoints are speed features, but
        // neither is allowed to take the snapshot over the compactness gate.
        // The estimator uses the exact varint widths and the actual target
        // prefix values, so this decision does not depend on an optimistic
        // average.  Sparse checkpoints remain the safe fallback for larger
        // graphs.
        const var_stream_len = try projectedStreamSize(canonical.items, false);
        const wide_stream_len = try projectedStreamSize(canonical.items, true);
        const wide_enabled = canonical.items.len >= wide_arcs_threshold and
            (try projectedTotal(wide_stream_len, canonical.items.len, 1) <= 40 * 1024 or
                try projectedTotal(wide_stream_len, canonical.items.len, sparse_checkpoint_stride) <= 40 * 1024);
        const selected_stream_len = if (wide_enabled) wide_stream_len else var_stream_len;
        const dense_total = try projectedTotal(selected_stream_len, canonical.items.len, 1);
        const sparse_total = try projectedTotal(selected_stream_len, canonical.items.len, sparse_checkpoint_stride);
        const dense_limit = std.math.add(usize, sparse_total, dense_checkpoint_budget) catch std.math.maxInt(usize);
        const stride: u32 = if (dense_total <= 40 * 1024 and dense_total <= dense_limit) 1 else sparse_checkpoint_stride;
        for (canonical.items, 0..) |state, state_id| {
            if (state_id % stride == 0) try checkpoints.append(self.allocator, try toU32(stream.items.len));
            var flags: u32 = 0;
            if (state.entry_mult != 0) flags |= 1;
            if (state.entry_mult > 1) flags |= 2;
            if (state.targets.len != 0) flags |= 4;
            const wide_arcs = wide_enabled and state.arcs.len >= wide_arcs_threshold;
            if (wide_arcs) flags |= 8;
            const degree = try toU32(state.arcs.len);
            const header_base = std.math.mul(u32, degree, 16) catch return error.Overflow;
            const final_header = std.math.add(u32, header_base, flags) catch return error.Overflow;
            try appendVar(&stream, self.allocator, final_header);
            try appendVar(&stream, self.allocator, state.primary_count);
            if (state.entry_mult > 1) try appendVar(&stream, self.allocator, state.entry_mult - 1);
            if (state.targets.len != 0) {
                try appendVar(&stream, self.allocator, try toU32(state.targets.len));
                var previous: u32 = 0;
                for (state.targets, 0..) |target, i| {
                    const delta = if (i == 0) std.math.add(u32, target, 1) catch return error.Overflow else target - previous;
                    try appendVar(&stream, self.allocator, delta);
                    previous = target;
                }
            }
            // Labels are contiguous: large-degree states can use binary or
            // vector lookup without a second label table in the wire.
            for (state.arcs) |arc| try stream.append(self.allocator, arc.label);
            var prefix: u32 = state.entry_mult;
            for (state.arcs, 0..) |arc, i| {
                if (arc.target >= state_id) return error.InvalidFormat;
                const target_delta = state_id - @as(usize, @intCast(arc.target));
                if (wide_arcs) {
                    try appendLe(u32, &stream, self.allocator, try toU32(target_delta));
                    try appendLe(u32, &stream, self.allocator, prefix);
                } else {
                    try appendVar(&stream, self.allocator, try toU32(target_delta));
                    try appendVar(&stream, self.allocator, prefix);
                }
                prefix = std.math.add(u32, prefix, canonical.items[@intCast(arc.target)].primary_count) catch return error.Overflow;
                _ = i;
            }
            if (prefix != state.primary_count) return error.InvalidFormat;
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.appendNTimes(self.allocator, 0, header_bytes);
        const checkpoint_off = out.items.len;
        for (checkpoints.items) |offset| try appendLe(u32, &out, self.allocator, offset);
        const stream_off = out.items.len;
        try out.appendSlice(self.allocator, stream.items);
        const total_len = try toU32(out.items.len);
        const state_count = try toU32(canonical.items.len);
        const accepted_count = try toU32(self.records.items.len);
        if (checkpoint_off > std.math.maxInt(u32) or stream_off > std.math.maxInt(u32)) return error.Overflow;
        std.mem.copyForwards(u8, out.items[0..4], magic);
        std.mem.writeInt(u16, out.items[4..6], version, .little);
        std.mem.writeInt(u16, out.items[6..8], 0, .little);
        std.mem.writeInt(u32, out.items[8..12], state_count, .little);
        std.mem.writeInt(u32, out.items[12..16], self.entry_count, .little);
        std.mem.writeInt(u32, out.items[16..20], accepted_count, .little);
        std.mem.writeInt(u32, out.items[20..24], root, .little);
        std.mem.writeInt(u32, out.items[24..28], try toU32(checkpoints.items.len), .little);
        std.mem.writeInt(u32, out.items[28..32], stride, .little);
        std.mem.writeInt(u32, out.items[32..36], try toU32(checkpoint_off), .little);
        std.mem.writeInt(u32, out.items[36..40], try toU32(stream_off), .little);
        std.mem.writeInt(u32, out.items[40..44], try toU32(stream.items.len), .little);
        std.mem.writeInt(u32, out.items[44..48], total_len, .little);
        return .{ .bytes = try out.toOwnedSlice(self.allocator), .allocator = self.allocator };
    }
};

pub const RawState = struct {
    degree: u32,
    wide_arcs: bool,
    entry_mult: u32,
    primary_count: u32,
    form_count: u32,
    form_offset: usize,
    label_offset: usize,
    arc_offset: usize,
    end: usize,
};

pub const Arc = struct { label: u8, target: u32, prefix: u32 };

/// Opaque state identity for product walks.  Callers can carry a state
/// between `step`/`stateCursor` calls but cannot confuse it with an entry
/// rank or a wire offset.
pub const StateId = enum(u32) {
    none = std.math.maxInt(u32),
    _,
};

pub const TraversalArc = struct {
    label: u8,
    target: StateId,
    /// Primary-rank count before this arc in the state's sorted arc run.
    prefix: u32,
};

pub const LookupStrategy = enum { linear, binary, vector };

pub const Frame = struct {
    state: u32 = 0,
    base: u32 = 0,
    key_len: usize = 0,
    next_arc: u32 = 0,
    arc_cursor: usize = 0,
    entered: bool = false,
};

/// One accepted key yielded by a prefix walk.
///
/// `kind` is deliberately part of the item rather than inferred from an
/// empty range: a form-only key has no primary range, while a homograph can
/// have a non-empty range of length greater than one.  `targets` is a borrowed
/// view into the automaton's authenticated bytes and is valid for as long as
/// the parent `View` remains alive.  The iterator's key slice is borrowed from
/// caller-owned scratch and is overwritten by the next call to `next`.
pub fn TargetListFor(comptime Source: type) type {
    return struct {
        const Self = @This();
        view: *const ViewFor(Source),
        offset: usize,
        count: u32,

        pub fn len(self: Self) u32 {
            return self.count;
        }

        pub fn target(self: Self, index: u32) !EntryRank {
            if (index >= self.count) return error.RankOutOfRange;
            var iter = self.iterator();
            var current: u32 = 0;
            while (try iter.next()) |value| : (current += 1) if (current == index) return value;
            return error.InvalidFormat;
        }

        pub const Iterator = struct {
            list: Self,
            index: u32 = 0,
            cursor: usize,
            previous: u32 = 0,

            pub fn next(self: *@This()) !?EntryRank {
                if (self.index >= self.list.count) return null;
                const delta = try self.list.view.readVar(&self.cursor);
                const value = if (self.index == 0)
                    std.math.sub(u32, delta, 1) catch return error.InvalidFormat
                else
                    std.math.add(u32, self.previous, delta) catch return error.InvalidFormat;
                if (value >= self.list.view.entry_count) return error.TargetOutOfRange;
                self.previous = value;
                self.index += 1;
                return @enumFromInt(value);
            }
        };

        pub fn iterator(self: Self) Iterator {
            return .{ .list = self, .cursor = self.offset };
        }
    };
}

pub fn ItemFor(comptime Source: type) type {
    return struct {
        key: []const u8,
        kind: MatchKind,
        entry_range: Range,
        targets: TargetListFor(Source),
        pub fn entries(self: @This()) ?Range {
            return if (self.kind == .entry) self.entry_range else null;
        }
        pub fn isEntry(self: @This()) bool {
            return self.kind == .entry;
        }
        pub fn isForm(self: @This()) bool {
            return self.kind == .form;
        }
    };
}

pub fn HitFor(comptime Source: type) type {
    return struct {
        kind: MatchKind,
        entry_range: ?Range,
        targets: TargetListFor(Source),
        pub fn isEntry(self: @This()) bool {
            return self.kind == .entry;
        }
        pub fn isForm(self: @This()) bool {
            return self.kind == .form;
        }
        pub fn target(self: @This(), index: u32) !EntryRank {
            return self.targets.target(index);
        }
    };
}
pub const PrefixInterval = struct {
    range: Range,
    state: u32,

    pub fn lo(self: PrefixInterval) EntryRank {
        return self.range.lo;
    }

    pub fn hi(self: PrefixInterval) EntryRank {
        return self.range.hi;
    }
};

pub const Selected = struct {
    key: []const u8,
    rank: EntryRank,
    identity_index: u32,
};

pub fn ViewFor(comptime Source: type) type {
    return struct {
        const Self = @This();
        const SourceResult = wire.SourceError(Source) || Error;
        source: Source,
        state_count: u32,
        entry_count: u32,
        accepted_count: u32,
        root_state: u32,
        checkpoint_count: u32,
        checkpoint_stride: u32,
        checkpoint_off: usize,
        stream_off: usize,
        stream_len: usize,

        pub fn open(source: Source) SourceResult!Self {
            const length = wire.sourceLen(Source, &source);
            if (length < header_bytes) return error.Truncated;
            const header = try wire.sourceBytes(Source, &source, 0, header_bytes);
            if (!std.mem.eql(u8, header[0..4], magic)) return error.BadMagic;
            if (try readLe(u16, header, 4) != version) return error.UnsupportedVersion;
            const state_count = try readLe(u32, header, 8);
            const entry_count = try readLe(u32, header, 12);
            const accepted_count = try readLe(u32, header, 16);
            const root_state = try readLe(u32, header, 20);
            const checkpoint_count = try readLe(u32, header, 24);
            const checkpoint_stride = try readLe(u32, header, 28);
            if (checkpoint_stride == 0) return error.InvalidFormat;
            const checkpoint_off = try readLe(u32, header, 32);
            const stream_off = try readLe(u32, header, 36);
            const stream_len = try readLe(u32, header, 40);
            const total_len = try readLe(u32, header, 44);
            if (total_len > length) return error.Truncated;
            if (total_len != length or state_count == 0 or root_state >= state_count or entry_count == empty_u32) return error.InvalidFormat;
            const expected_checkpoints = if (state_count == 0) 0 else (state_count - 1) / checkpoint_stride + 1;
            if (checkpoint_count != expected_checkpoints) return error.InvalidFormat;
            const checkpoint_end = try addUsize(checkpoint_off, try std.math.mul(usize, checkpoint_count, 4));
            const stream_end = try addUsize(@intCast(stream_off), @intCast(stream_len));
            if (checkpoint_off < header_bytes or checkpoint_end > length or stream_off != checkpoint_end or stream_end != length) return error.InvalidFormat;
            // Envelope validation intentionally stops here.  It does not walk the
            // state/arc graph; callers that need trust use verify().
            return .{ .source = source, .state_count = state_count, .entry_count = entry_count, .accepted_count = accepted_count, .root_state = root_state, .checkpoint_count = checkpoint_count, .checkpoint_stride = checkpoint_stride, .checkpoint_off = checkpoint_off, .stream_off = stream_off, .stream_len = stream_len };
        }

        pub fn len(self: *const Self) usize {
            return wire.sourceLen(Source, &self.source);
        }

        inline fn bytes(self: *const Self, offset: usize, length: usize) SourceResult![]const u8 {
            return wire.sourceBytes(Source, &self.source, offset, length);
        }
        inline fn byte(self: *const Self, offset: usize) SourceResult!u8 {
            return (try self.bytes(offset, 1))[0];
        }
        inline fn integer(self: *const Self, comptime T: type, offset: usize) SourceResult!T {
            const data = try self.bytes(offset, @sizeOf(T));
            return std.mem.readInt(T, data[0..@sizeOf(T)], .little);
        }
        pub fn readVar(self: *const Self, cursor: *usize) SourceResult!u32 {
            var result: u32 = 0;
            var shift: u5 = 0;
            var groups: u8 = 0;
            while (true) {
                if (cursor.* >= self.stream_off + self.stream_len) return error.Truncated;
                const value = try self.byte(cursor.*);
                cursor.* += 1;
                groups += 1;
                if (shift == 28 and value > 0x0f) return error.InvalidFormat;
                result |= @as(u32, value & 0x7f) << shift;
                if (value & 0x80 == 0) {
                    if (groups > 1 and value == 0) return error.InvalidFormat;
                    return result;
                }
                if (shift == 28) return error.InvalidFormat;
                shift += 7;
            }
        }

        fn checkpoint(self: *const Self, index: u32) SourceResult!usize {
            if (index >= self.checkpoint_count) return error.InvalidState;
            const offset = try self.integer(u32, self.checkpoint_off + @as(usize, @intCast(index)) * 4);
            if (offset > self.stream_len) return error.InvalidFormat;
            return self.stream_off + offset;
        }

        /// Decode only the fixed state prefix, form targets and label lane. Query
        /// paths deliberately stop at `arc_offset`: a dense checkpoint plus a
        /// selected label must not authenticate unrelated variable-width arcs.
        fn decodePrefix(self: *const Self, cursor: *usize) SourceResult!RawState {
            const header = try self.readVar(cursor);
            const degree = header >> 4;
            const has_entry = header & 1 != 0;
            const wide_entry = header & 2 != 0;
            const has_forms = header & 4 != 0;
            const wide_arcs = header & 8 != 0;
            if (wide_entry and !has_entry) return error.InvalidFormat;
            const primary_count = try self.readVar(cursor);
            const entry_mult = if (!has_entry) 0 else if (!wide_entry) 1 else (std.math.add(u32, try self.readVar(cursor), 1) catch return error.InvalidFormat);
            const form_count = if (has_forms) try self.readVar(cursor) else 0;
            const form_offset = cursor.*;
            for (0..form_count) |_| _ = try self.readVar(cursor);
            const label_offset = cursor.*;
            cursor.* = try addUsize(cursor.*, degree);
            if (cursor.* > self.stream_off + self.stream_len) return error.Truncated;
            const arc_offset = cursor.*;
            return .{ .degree = degree, .wide_arcs = wide_arcs, .entry_mult = entry_mult, .primary_count = primary_count, .form_count = form_count, .form_offset = form_offset, .label_offset = label_offset, .arc_offset = arc_offset, .end = 0 };
        }

        fn decodeRecord(self: *const Self, cursor: *usize) SourceResult!RawState {
            var raw = try self.decodePrefix(cursor);
            if (raw.wide_arcs) {
                cursor.* = try addUsize(cursor.*, try std.math.mul(usize, raw.degree, 8));
                if (cursor.* > self.stream_off + self.stream_len) return error.Truncated;
            } else for (0..raw.degree) |_| {
                _ = try self.readVar(cursor);
                _ = try self.readVar(cursor);
            }
            raw.end = cursor.*;
            return raw;
        }

        fn skipState(self: *const Self, cursor: *usize) SourceResult!void {
            _ = try self.decodeRecord(cursor);
        }

        pub fn decodeState(self: *const Self, index: u32) SourceResult!RawState {
            if (index >= self.state_count) return error.InvalidState;
            const checkpoint_index = index / self.checkpoint_stride;
            var cursor = try self.checkpoint(checkpoint_index);
            var current = checkpoint_index * self.checkpoint_stride;
            while (current < index) : (current += 1) try self.skipState(&cursor);
            return self.decodePrefix(&cursor);
        }

        pub fn arcAt(self: *const Self, state_index: u32, raw: RawState, arc_index: u32) SourceResult!Arc {
            if (arc_index >= raw.degree) return error.InvalidArc;
            if (raw.wide_arcs) {
                const offset = try addUsize(raw.arc_offset, try std.math.mul(usize, arc_index, 8));
                const delta = try self.integer(u32, offset);
                const arc_prefix = try self.integer(u32, try addUsize(offset, 4));
                if (delta == 0 or delta > state_index) return error.TargetOutOfRange;
                return .{ .label = try self.byte(raw.label_offset + arc_index), .target = state_index - delta, .prefix = arc_prefix };
            }
            var cursor = raw.arc_offset;
            var i: u32 = 0;
            while (i <= arc_index) : (i += 1) {
                const delta = try self.readVar(&cursor);
                const arc_prefix = try self.readVar(&cursor);
                if (i == arc_index) {
                    if (delta == 0 or delta > state_index) return error.TargetOutOfRange;
                    return .{ .label = try self.byte(raw.label_offset + arc_index), .target = state_index - delta, .prefix = arc_prefix };
                }
            }
            return error.InvalidArc;
        }

        fn arcFromStream(self: *const Self, state_index: u32, raw: RawState, cursor: *usize, arc_index: u32) SourceResult!Arc {
            if (arc_index >= raw.degree) return error.InvalidArc;
            if (raw.wide_arcs) {
                const offset = cursor.*;
                cursor.* = try addUsize(cursor.*, 8);
                if (cursor.* > self.stream_off + self.stream_len) return error.Truncated;
                const delta = try self.integer(u32, offset);
                const arc_prefix = try self.integer(u32, try addUsize(offset, 4));
                if (delta == 0 or delta > state_index) return error.TargetOutOfRange;
                return .{ .label = try self.byte(raw.label_offset + arc_index), .target = state_index - delta, .prefix = arc_prefix };
            }
            if (cursor.* >= self.stream_off + self.stream_len) return error.Truncated;
            const delta = try self.readVar(cursor);
            const arc_prefix = try self.readVar(cursor);
            if (delta == 0 or delta > state_index) return error.TargetOutOfRange;
            return .{ .label = try self.byte(raw.label_offset + arc_index), .target = state_index - delta, .prefix = arc_prefix };
        }

        pub fn lookupStrategy(degree: u32) LookupStrategy {
            if (degree <= 8) return .linear;
            if (degree <= 31) return .binary;
            return .vector;
        }

        fn findArc(self: *const Self, state_index: u32, raw: RawState, label: u8) SourceResult!?Arc {
            switch (lookupStrategy(raw.degree)) {
                .linear => {
                    var cursor = raw.arc_offset;
                    var i: u32 = 0;
                    while (i < raw.degree) : (i += 1) {
                        const candidate = try self.byte(raw.label_offset + i);
                        const arc = try self.arcFromStream(state_index, raw, &cursor, i);
                        if (candidate == label) return @as(?Arc, arc);
                        if (candidate > label) break;
                    }
                    return null;
                },
                .binary => {
                    var lo: u32 = 0;
                    var hi = raw.degree;
                    while (lo < hi) {
                        const mid = lo + (hi - lo) / 2;
                        const candidate = try self.byte(raw.label_offset + mid);
                        if (candidate < label) lo = mid + 1 else hi = mid;
                    }
                    if (lo < raw.degree and try self.byte(raw.label_offset + lo) == label) return @as(?Arc, try self.arcAt(state_index, raw, lo));
                    return null;
                },
                .vector => {
                    // The labels are a dense run.  Compare 16 labels at a time;
                    // the scalar index search only runs for a matching chunk.
                    var i: u32 = 0;
                    while (i + 16 <= raw.degree) : (i += 16) {
                        const chunk = (try self.bytes(raw.label_offset + i, 16))[0..16].*;
                        const vector: @Vector(16, u8) = chunk;
                        const needle: @Vector(16, u8) = @splat(label);
                        if (!@reduce(.Or, vector == needle)) continue;
                        var j: u32 = 0;
                        while (j < 16) : (j += 1) if (try self.byte(raw.label_offset + i + j) == label) return @as(?Arc, try self.arcAt(state_index, raw, i + j));
                    }
                    while (i < raw.degree) : (i += 1) if (try self.byte(raw.label_offset + i) == label) return @as(?Arc, try self.arcAt(state_index, raw, i));
                    return null;
                },
            }
        }

        fn stateRaw(state: StateId) Error!u32 {
            const raw = @intFromEnum(state);
            if (raw == std.math.maxInt(u32)) return error.InvalidState;
            return raw;
        }

        pub const Cursor = struct {
            view: *const Self,
            state: StateId,
            raw: RawState,
            arc_cursor: usize,
            next_arc: u32 = 0,

            pub fn stateId(self: *const Cursor) StateId {
                return self.state;
            }

            pub fn primaryCount(self: *const Cursor) u32 {
                return self.raw.primary_count;
            }

            pub fn entryMultiplicity(self: *const Cursor) u32 {
                return self.raw.entry_mult;
            }

            pub fn hasEntry(self: *const Cursor) bool {
                return self.raw.entry_mult != 0;
            }

            pub fn hasForm(self: *const Cursor) bool {
                return self.raw.form_count != 0;
            }

            pub fn formTargets(self: *const Cursor) TargetListFor(Source) {
                return .{ .view = self.view, .offset = self.raw.form_offset, .count = self.raw.form_count };
            }

            /// Return the next sorted outgoing arc without allocating.  The
            /// cursor owns only offsets and decoded metadata; all bytes remain in
            /// the borrowed View's immutable section.
            pub fn nextArc(self: *Cursor) !?TraversalArc {
                if (self.next_arc >= self.raw.degree) return null;
                const index = self.next_arc;
                const arc = try self.view.arcFromStream(@intFromEnum(self.state), self.raw, &self.arc_cursor, index);
                self.next_arc += 1;
                return .{ .label = arc.label, .target = try self.view.stateIdFromRaw(arc.target), .prefix = arc.prefix };
            }
        };

        pub fn rootState(self: *const Self) SourceResult!StateId {
            return self.stateIdFromRaw(self.root_state);
        }

        fn stateIdFromRaw(self: *const Self, raw: u32) SourceResult!StateId {
            if (raw == std.math.maxInt(u32) or raw >= self.state_count) return error.InvalidState;
            return @enumFromInt(raw);
        }

        pub fn stateCursor(self: *const Self, state: StateId) !Cursor {
            const raw_state = try stateRaw(state);
            const raw = try self.decodeState(raw_state);
            return .{ .view = self, .state = state, .raw = raw, .arc_cursor = raw.arc_offset };
        }

        pub fn rootCursor(self: *const Self) !Cursor {
            return self.stateCursor(try self.rootState());
        }

        /// Checked one-label transition for product automata.  Callers that walk
        /// many arcs should prefer `stateCursor`/`nextArc` to avoid repeating a
        /// local arc search.
        pub fn step(self: *const Self, state: StateId, label: u8) !?TraversalArc {
            const raw_state = try stateRaw(state);
            const raw = try self.decodeState(raw_state);
            const arc = (try self.findArc(raw_state, raw, label)) orelse return null;
            return .{ .label = arc.label, .target = try self.stateIdFromRaw(arc.target), .prefix = arc.prefix };
        }

        fn walk(self: *const Self, key: []const u8) SourceResult!?struct { state: u32, base: u32 } {
            var state = self.root_state;
            var base: u32 = 0;
            for (key) |label| {
                const raw = try self.decodeState(state);
                const arc = (try self.findArc(state, raw, label)) orelse return null;
                base = std.math.add(u32, base, arc.prefix) catch return error.Overflow;
                state = arc.target;
            }
            return .{ .state = state, .base = base };
        }

        pub fn exact(self: *const Self, key: []const u8) !?HitFor(Source) {
            const walked = (try self.walk(key)) orelse return null;
            const raw = try self.decodeState(walked.state);
            if (raw.entry_mult == 0 and raw.form_count == 0) return null;
            const range: ?Range = if (raw.entry_mult == 0) null else blk: {
                const end = std.math.add(u32, walked.base, raw.entry_mult) catch return error.Overflow;
                if (end > self.entry_count) return error.TargetOutOfRange;
                break :blk .{ .lo = @enumFromInt(walked.base), .hi = @enumFromInt(end) };
            };
            const cursor = raw.form_offset;
            return .{ .kind = if (raw.entry_mult != 0) .entry else .form, .entry_range = range, .targets = .{ .view = self, .offset = cursor, .count = raw.form_count } };
        }

        pub fn prefixInterval(self: *const Self, prefix_bytes: []const u8) !?PrefixInterval {
            const walked = (try self.walk(prefix_bytes)) orelse return null;
            const raw = try self.decodeState(walked.state);
            const end = std.math.add(u32, walked.base, raw.primary_count) catch return error.Overflow;
            if (end > self.entry_count) return error.TargetOutOfRange;
            return .{ .range = .{ .lo = @enumFromInt(walked.base), .hi = @enumFromInt(end) }, .state = walked.state };
        }

        /// Rank at which `key` would be inserted among primary entry strings.
        /// Unlike select-based binary search this follows at most one automaton
        /// state per input byte, and a missing transition terminates immediately.
        pub fn lowerBound(self: *const Self, key: []const u8) !EntryRank {
            var state = self.root_state;
            var base: u32 = 0;
            for (key) |label| {
                const raw = try self.decodeState(state);
                var cursor = raw.arc_offset;
                var matched = false;
                for (0..raw.degree) |arc_index| {
                    const arc = try self.arcFromStream(state, raw, &cursor, @intCast(arc_index));
                    if (arc.label > label) return @enumFromInt(std.math.add(u32, base, arc.prefix) catch return error.Overflow);
                    if (arc.label == label) {
                        base = std.math.add(u32, base, arc.prefix) catch return error.Overflow;
                        state = arc.target;
                        matched = true;
                        break;
                    }
                }
                if (!matched) return @enumFromInt(std.math.add(u32, base, raw.primary_count) catch return error.Overflow);
            }
            return @enumFromInt(base);
        }

        pub fn select(self: *const Self, rank: anytype, scratch: []u8) !?Selected {
            const wanted = rankValue(rank);
            if (wanted >= self.entry_count) return null;
            var state = self.root_state;
            var base: u32 = 0;
            var key_len: usize = 0;
            var identity: u32 = 0;
            while (true) {
                const raw = try self.decodeState(state);
                const entry_end = std.math.add(u32, base, raw.entry_mult) catch return error.InvalidFormat;
                if (wanted < entry_end) {
                    identity = wanted - base;
                    return .{ .key = scratch[0..key_len], .rank = @enumFromInt(wanted), .identity_index = identity };
                }
                var found = false;
                if (raw.degree != 0) {
                    // Stream the arc lane exactly once.  The former implementation
                    // called arcAt(i) and arcAt(i+1), rescanning the variable-width
                    // lane quadratically for high-degree states.
                    var arc_cursor = raw.arc_offset;
                    var i: u32 = 0;
                    var arc = try self.arcFromStream(state, raw, &arc_cursor, i);
                    while (true) {
                        const next = if (i + 1 < raw.degree) try self.arcFromStream(state, raw, &arc_cursor, i + 1) else null;
                        const next_prefix = if (next) |next_arc| next_arc.prefix else raw.primary_count;
                        const child_base = std.math.add(u32, base, arc.prefix) catch return error.Overflow;
                        const child_end = std.math.add(u32, base, next_prefix) catch return error.InvalidFormat;
                        if (wanted >= child_base and wanted < child_end) {
                            if (key_len >= scratch.len) return error.OutputTooSmall;
                            scratch[key_len] = arc.label;
                            key_len += 1;
                            base = child_base;
                            state = arc.target;
                            found = true;
                            break;
                        }
                        if (next) |next_arc| {
                            arc = next_arc;
                            i += 1;
                        } else break;
                    }
                }
                if (!found) return error.InvalidFormat;
            }
        }

        pub const Iterator = struct {
            view: *const Self,
            key: []u8,
            frames: []Frame,
            depth: usize,

            pub fn next(self: *Iterator) !?ItemFor(Source) {
                while (self.depth != 0) {
                    var frame = &self.frames[self.depth - 1];
                    const raw = try self.view.decodeState(frame.state);
                    if (frame.arc_cursor == 0) frame.arc_cursor = raw.arc_offset;
                    if (!frame.entered) {
                        frame.entered = true;
                        if (raw.entry_mult != 0 or raw.form_count != 0) {
                            const end = std.math.add(u32, frame.base, raw.entry_mult) catch return error.InvalidFormat;
                            return .{
                                .key = self.key[0..frame.key_len],
                                .kind = if (raw.entry_mult != 0) .entry else .form,
                                .entry_range = .{ .lo = @enumFromInt(frame.base), .hi = @enumFromInt(end) },
                                .targets = .{ .view = self.view, .offset = raw.form_offset, .count = raw.form_count },
                            };
                        }
                    }
                    if (frame.next_arc < raw.degree) {
                        const index = frame.next_arc;
                        frame.next_arc += 1;
                        const arc = try self.view.arcFromStream(frame.state, raw, &frame.arc_cursor, index);
                        if (frame.key_len >= self.key.len) return error.OutputTooSmall;
                        self.key[frame.key_len] = arc.label;
                        if (self.depth >= self.frames.len) return error.DepthExceeded;
                        const child_base = std.math.add(u32, frame.base, arc.prefix) catch return error.InvalidFormat;
                        self.frames[self.depth] = .{ .state = arc.target, .base = child_base, .key_len = frame.key_len + 1, .arc_cursor = 0 };
                        self.depth += 1;
                    } else {
                        self.depth -= 1;
                    }
                }
                return null;
            }
        };

        pub fn prefix(self: *const Self, prefix_bytes: []const u8, key: []u8, frames: []Frame) !Iterator {
            if (prefix_bytes.len > key.len) return error.OutputTooSmall;
            // A missing prefix is a normal empty result, matching exact() and
            // prefixInterval().  In particular it must not be reported as a
            // malformed state merely because the caller asked for a walk.
            const walked = (try self.walk(prefix_bytes)) orelse return .{ .view = self, .key = key, .frames = frames, .depth = 0 };
            if (frames.len == 0) return error.DepthExceeded;
            std.mem.copyForwards(u8, key[0..prefix_bytes.len], prefix_bytes);
            const raw = try self.decodeState(walked.state);
            frames[0] = .{ .state = walked.state, .base = walked.base, .key_len = prefix_bytes.len, .arc_cursor = raw.arc_offset };
            return .{ .view = self, .key = key, .frames = frames, .depth = 1 };
        }

        /// Full structural validation.  It is intentionally separate from open:
        /// every state and arc is visited a constant number of times, never a
        /// state-by-arc nested walk.
        pub fn verify(self: *const Self) !void {
            return self.verifyWithAllocator(std.heap.page_allocator);
        }

        pub fn verifyWithAllocator(self: *const Self, allocator: std.mem.Allocator) !void {
            const Summary = struct { primary: u32, accepted: u32 };
            const summaries = try allocator.alloc(Summary, self.state_count);
            defer allocator.free(summaries);
            var record_cursor = self.stream_off;
            for (0..self.state_count) |i| {
                if (i % self.checkpoint_stride == 0 and try self.checkpoint(@intCast(i / self.checkpoint_stride)) != record_cursor)
                    return error.InvalidFormat;
                const raw = try self.decodeRecord(&record_cursor);
                if (raw.primary_count < raw.entry_mult) return error.InvalidFormat;

                var form_cursor = raw.form_offset;
                var previous_target: u32 = 0;
                for (0..raw.form_count) |j| {
                    const delta = try self.readVar(&form_cursor);
                    const target = if (j == 0) std.math.sub(u32, delta, 1) catch return error.InvalidFormat else std.math.add(u32, previous_target, delta) catch return error.InvalidFormat;
                    if (target >= self.entry_count or (j != 0 and target <= previous_target)) return error.TargetOutOfRange;
                    previous_target = target;
                }
                if (form_cursor != raw.label_offset) return error.InvalidFormat;

                var accepted: u32 = @intFromBool(raw.entry_mult != 0 or raw.form_count != 0);
                var primary = raw.entry_mult;
                var previous_label: ?u8 = null;
                var arc_cursor = raw.arc_offset;
                for (0..raw.degree) |j| {
                    const arc = try self.arcFromStream(@intCast(i), raw, &arc_cursor, @intCast(j));
                    if (previous_label) |label| if (arc.label <= label) return error.InvalidArc;
                    if (arc.target >= i or arc.prefix != primary) return error.InvalidArc;
                    previous_label = arc.label;
                    primary = std.math.add(u32, primary, summaries[arc.target].primary) catch return error.Overflow;
                    accepted = std.math.add(u32, accepted, summaries[arc.target].accepted) catch return error.Overflow;
                }
                if (arc_cursor != raw.end or primary != raw.primary_count) return error.InvalidFormat;
                summaries[i] = .{ .primary = primary, .accepted = accepted };
            }
            if (record_cursor != self.stream_off + self.stream_len) return error.InvalidFormat;
            const root = summaries[self.root_state];
            if (root.accepted != self.accepted_count or root.primary != self.entry_count) return error.InvalidFormat;
        }
    };
}

pub const View = ViewFor([]const u8);
pub const TargetList = TargetListFor([]const u8);
pub const Item = ItemFor([]const u8);
pub const Hit = HitFor([]const u8);

fn rankValue(value: anytype) u32 {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .int, .comptime_int => std.math.cast(u32, value) orelse empty_u32,
        .@"enum" => blk: {
            if (T != EntryRank) @compileError("entry ranks must use Rank(.entry)");
            break :blk @intFromEnum(value);
        },
        else => @compileError("entry rank must be an integer or Rank(.entry)"),
    };
}

pub const SliceSource = wire.Slice;
pub fn SourceView(comptime Source: type) type {
    return ViewFor(Source);
}
pub fn openSource(comptime Source: type, source: Source) !ViewFor(Source) {
    return ViewFor(Source).open(source);
}
