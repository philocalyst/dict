const std = @import("std");
const source_bindings = @import("bindings.zig");
const bytes = @import("bytes.zig");
const keys = @import("keys.zig");
const model = @import("model.zig");
const strings = @import("strings.zig");
const topology = @import("topology.zig");

pub const Match = union(enum) { exact: []const u8, prefix: []const u8 };

/// Capability state is owned by each root plan and iterator. `context()`
/// returns a synchronous borrow into that owner: the pointer is valid only
/// while the owner remains alive and unmoved, and operators must never retain
/// it. Returned plans, cursors, handles, and Text values instead copy the
/// Source-backed component capabilities they need.
pub fn Context(comptime Source: type) type {
    const Span = bytes.Span(Source);
    return struct {
        bindings: source_bindings.ViewFor(Span),
        topology: topology.ViewFor(Span),
        strings: strings.ViewFor(Span),
        domains: model.DomainCatalogue,
        record_space: model.RecordSpace,
    };
}

pub fn Lookup(comptime Source: type) type {
    const Span = bytes.Span(Source);
    const KeyView = keys.ViewFor(Span);
    return struct {
        strings: strings.ViewFor(Span),
        keys: KeyView,
        range: KeyView.Range,

        const Self = @This();
        pub const Targets = union(enum) { headword: model.Ref(.entry), form: KeyView.TargetCursor };
        pub const Hit = struct { key: strings.TextFor(bytes.Span(Source)), origin: keys.Origin, targets: Targets };

        pub fn iterator(self: Self) Iterator {
            return .{ .plan = self, .range = self.range };
        }

        /// Projected coordinates are relative to this selection. The absolute
        /// physical hit bounds remain available in `range`.
        pub fn ProjectionFor(comptime path: anytype) type {
            return KeyView.ProjectionFor(path);
        }

        pub fn project(self: *const Self, comptime path: anytype) !ProjectionFor(path) {
            return self.keys.projectRange(path, self.range);
        }

        pub const Iterator = struct {
            plan: Self,
            range: KeyView.Range,

            pub fn next(self: *@This()) !?Hit {
                const index = (try self.range.nextIndex()) orelse return null;
                const row = try self.plan.keys.rows.row(index);
                return .{
                    .key = self.plan.strings.text(row.key),
                    .origin = row.origin,
                    .targets = switch (row.origin) {
                        .headword => |entry| .{ .headword = entry },
                        .form => .{ .form = try self.plan.keys.targets.cursor(index) },
                    },
                };
            }
        };
    };
}

pub fn EntrySelection(comptime Source: type) type {
    const LookupType = Lookup(Source);
    return struct {
        lookup: LookupType,
        capability: Context(Source),

        const Self = @This();

        pub fn context(self: *const Self) *const Context(Source) {
            return &self.capability;
        }

        pub fn iterator(self: Self) Iterator {
            return .{ .lookup = self.lookup.iterator(), .capability = self.capability };
        }

        pub fn ProjectionFor(comptime path: anytype) type {
            return LookupType.ProjectionFor(path);
        }

        pub fn project(self: *const Self, comptime path: anytype) !ProjectionFor(path) {
            return self.lookup.project(path);
        }

        pub fn sources(self: Self, role: model.BindingRole) SourceSelection(Sources(Source), Source) {
            return .{ .producer = .{ .entries = self, .role = role } };
        }

        pub const Iterator = struct {
            lookup: LookupType.Iterator,
            capability: Context(Source),

            pub fn context(self: *const @This()) *const Context(Source) {
                return &self.capability;
            }

            pub fn next(self: *@This()) !?LookupType.Hit {
                return self.lookup.next();
            }
        };
    };
}

pub fn SourceSelection(comptime Producer: type, comptime Source: type) type {
    return struct {
        producer: Producer,

        const Self = @This();

        pub fn context(self: *const Self) *const Context(Source) {
            return self.producer.context();
        }

        pub fn iterator(self: Self) Iterator {
            return .{ .inner = self.producer.iterator() };
        }

        pub fn descendants(self: Self, comptime kind: model.Kind) SourceSelection(DescendantProducer(Self, Source, kind), Source) {
            return .{ .producer = .{ .parents = self } };
        }

        pub fn texts(self: Self) TextSelection(Self) {
            return .{ .parents = self };
        }

        pub fn bindings(self: Self, comptime kind: model.Kind, comptime mode: source_bindings.ScopeMode) BindingSelection(Self, kind, mode) {
            return .{ .parents = self };
        }

        pub const Iterator = struct {
            inner: Producer.Iterator,

            pub fn context(self: *const @This()) *const Context(Source) {
                return self.inner.context();
            }

            pub fn next(self: *@This()) !?model.SourceHandle {
                return self.inner.nextHandle();
            }
        };
    };
}

pub fn RecordSources(comptime Source: type) type {
    const Span = bytes.Span(Source);
    const Positions = source_bindings.ViewFor(Span).PositionCursor;
    return struct {
        capability: Context(Source),
        record: model.AnyRef,
        role: model.BindingRole,

        const Self = @This();

        pub fn context(self: *const Self) *const Context(Source) {
            return &self.capability;
        }

        pub fn iterator(self: Self) Iterator {
            return .{ .plan = self };
        }

        pub const Iterator = struct {
            plan: Self,
            positions: ?Positions = null,
            run_next: u32 = 0,
            run_end: u32 = 0,
            last_handle: ?model.SourceHandle = null,

            pub fn context(self: *const @This()) *const Context(Source) {
                return &self.plan.capability;
            }

            pub fn nextHandle(self: *@This()) !?model.SourceHandle {
                const context_value = self.context();
                if (self.positions == null) {
                    self.positions = try context_value.bindings.positions(self.plan.record, self.plan.role, context_value.record_space);
                }
                while (true) {
                    if (self.run_next < self.run_end) {
                        const position = self.run_next;
                        self.run_next += 1;
                        const handle = (try context_value.bindings.bindingAtPosition(@enumFromInt(position))).row.source;
                        if (self.last_handle) |previous| if (std.meta.eql(previous, handle)) continue;
                        self.last_handle = handle;
                        return handle;
                    }
                    const run = (try self.positions.?.nextRun()) orelse return null;
                    self.run_next = @intFromEnum(run.lo);
                    self.run_end = @intFromEnum(run.hi);
                }
            }
        };
    };
}

pub fn SingletonSource(comptime Source: type) type {
    return struct {
        capability: Context(Source),
        handle: model.SourceHandle,

        const Self = @This();

        pub fn context(self: *const Self) *const Context(Source) {
            return &self.capability;
        }

        pub fn iterator(self: Self) Iterator {
            return .{ .plan = self };
        }

        pub const Iterator = struct {
            plan: Self,
            emitted: bool = false,

            pub fn context(self: *const @This()) *const Context(Source) {
                return &self.plan.capability;
            }

            pub fn nextHandle(self: *@This()) !?model.SourceHandle {
                if (self.emitted) return null;
                self.emitted = true;
                try self.plan.capability.topology.validateHandle(self.plan.handle);
                return self.plan.handle;
            }
        };
    };
}

pub fn BindingSelection(comptime Parent: type, comptime kind: model.Kind, comptime mode: source_bindings.ScopeMode) type {
    return struct {
        parents: Parent,

        const Self = @This();

        pub fn iterator(self: Self) Iterator {
            return .{ .plan = self };
        }

        pub const Iterator = struct {
            plan: Self,
            next_position: u32 = 0,

            fn candidateWithin(self: *@This(), selected: model.SourceHandle) !?model.SourceOrderId {
                const context_value = self.plan.parents.context();
                const bounds = try @TypeOf(context_value.bindings).searchBounds(mode, context_value.topology, selected);
                var position = (try context_value.bindings.lowerBoundStart(bounds.lo)) orelse return null;
                if (@intFromEnum(position) < self.next_position) position = @enumFromInt(self.next_position);
                while (@intFromEnum(position) < context_value.bindings.source_order.row_count) {
                    const binding = try context_value.bindings.bindingAtPosition(position);
                    if (binding.start > bounds.hi) return null;
                    if (std.meta.activeTag(binding.row.record) == kind and
                        try @TypeOf(context_value.bindings).matches(mode, context_value.topology, selected, binding.row.source)) return position;
                    position = model.SourceOrderId.fromIndex(@intFromEnum(position) + 1) catch return error.InvalidBinding;
                }
                return null;
            }

            pub fn next(self: *@This()) !?source_bindings.Match(kind) {
                const context_value = self.plan.parents.context();
                while (true) {
                    var best: ?model.SourceOrderId = null;
                    var selected = self.plan.parents.iterator();
                    while (try selected.next()) |handle| {
                        const candidate = (try self.candidateWithin(handle)) orelse continue;
                        if (best == null or @intFromEnum(candidate) < @intFromEnum(best.?)) best = candidate;
                    }
                    const position = best orelse return null;
                    self.next_position = std.math.add(u32, @intFromEnum(position), 1) catch return error.InvalidBinding;
                    const binding = try context_value.bindings.bindingAtPosition(position);
                    return .{
                        .binding_id = binding.id,
                        .record = @field(binding.row.record, @tagName(kind)),
                        .anchor = binding.row.source,
                    };
                }
            }
        };
    };
}

pub fn Sources(comptime Source: type) type {
    const Entries = EntrySelection(Source);
    return struct {
        entries: Entries,
        role: model.BindingRole,

        const Self = @This();

        pub fn context(self: *const Self) *const Context(Source) {
            return self.entries.context();
        }

        pub fn iterator(self: Self) Iterator {
            return .{ .entries = self.entries, .role = self.role };
        }

        pub const Iterator = struct {
            entries: Entries,
            role: model.BindingRole,
            next_position: u32 = 0,
            last_handle: ?model.SourceHandle = null,

            pub fn context(self: *const @This()) *const Context(Source) {
                return self.entries.context();
            }

            fn consider(self: *@This(), entry: model.Ref(.entry), best: *?model.SourceOrderId) !void {
                const context_value = self.context();
                var positions = try context_value.bindings.positions(.{ .entry = entry }, self.role, context_value.record_space);
                const candidate = try positions.lowerBound(@enumFromInt(self.next_position)) orelse return;
                if (best.* == null or @intFromEnum(candidate) < @intFromEnum(best.*.?)) best.* = candidate;
            }

            fn leastPosition(self: *@This()) !?model.SourceOrderId {
                var best: ?model.SourceOrderId = null;
                var hits = self.entries.iterator();
                while (try hits.next()) |hit| switch (hit.targets) {
                    .headword => |entry| try self.consider(entry, &best),
                    .form => |targets| {
                        var cursor = targets;
                        while (try cursor.nextRun()) |run| {
                            for (@intFromEnum(run.lo)..@intFromEnum(run.hi)) |rank| try self.consider(@enumFromInt(rank), &best);
                        }
                    },
                };
                return best;
            }

            pub fn nextHandle(self: *@This()) !?model.SourceHandle {
                const context_value = self.context();
                while (try self.leastPosition()) |position| {
                    self.next_position = std.math.add(u32, @intFromEnum(position), 1) catch return error.InvalidBinding;
                    const binding = try context_value.bindings.bindingAtPosition(position);
                    if (self.last_handle) |previous| if (std.meta.eql(previous, binding.row.source)) continue;
                    self.last_handle = binding.row.source;
                    return binding.row.source;
                }
                return null;
            }
        };
    };
}

pub fn DescendantProducer(comptime Parent: type, comptime Source: type, comptime kind: model.Kind) type {
    return struct {
        parents: Parent,

        const Self = @This();

        pub fn context(self: *const Self) *const Context(Source) {
            return self.parents.context();
        }

        pub fn iterator(self: Self) Iterator {
            return .{ .parents = self.parents.iterator() };
        }

        pub const Iterator = struct {
            parents: Parent.Iterator,
            selected: ?model.SourceHandle = null,
            candidate: u32 = 0,
            candidate_end: u32 = 0,
            last_emitted: ?u32 = null,

            pub fn context(self: *const @This()) *const Context(Source) {
                return self.parents.context();
            }

            fn begin(self: *@This(), handle: model.SourceHandle) !void {
                self.selected = handle;
                const context_value = self.context();
                switch (handle) {
                    .occurrence => |id| {
                        const row = try context_value.topology.occurrence(id);
                        self.candidate = std.math.add(u32, @intFromEnum(id), 1) catch return error.InvalidOccurrence;
                        self.candidate_end = row.subtree_end;
                    },
                    .span => |span| {
                        try context_value.topology.validateSpan(span);
                        const range = try context_value.topology.occurrencesInEventRange(span.start, span.end);
                        self.candidate = range.start;
                        self.candidate_end = range.end;
                    },
                }
            }

            fn inScope(self: *@This(), id: model.OccurrenceId) !bool {
                return switch (self.selected.?) {
                    .occurrence => true,
                    .span => |span| scoped: {
                        const context_value = self.context();
                        const row = try context_value.topology.occurrence(id);
                        const end = std.math.add(u32, row.event_close, 1) catch return error.InvalidOccurrence;
                        break :scoped row.event_open >= span.start and end <= span.end;
                    },
                };
            }

            fn hasKind(self: *@This(), id: model.OccurrenceId) !bool {
                const context_value = self.context();
                const occurrence_row = try context_value.topology.occurrence(id);
                var position = (try context_value.bindings.lowerBoundStart(occurrence_row.event_open)) orelse return false;
                while (@intFromEnum(position) < context_value.bindings.source_order.row_count) {
                    const binding = try context_value.bindings.bindingAtPosition(position);
                    if (binding.start != occurrence_row.event_open) return false;
                    position = model.SourceOrderId.fromIndex(@intFromEnum(position) + 1) catch return error.InvalidBinding;
                    const row = binding.row;
                    if (row.role != .realization or std.meta.activeTag(row.record) != kind) continue;
                    if (std.meta.eql(row.source, model.SourceHandle{ .occurrence = id })) return true;
                }
                return false;
            }

            pub fn nextHandle(self: *@This()) !?model.SourceHandle {
                while (true) {
                    while (self.candidate < self.candidate_end) {
                        const id: model.OccurrenceId = @enumFromInt(self.candidate);
                        self.candidate = std.math.add(u32, self.candidate, 1) catch return error.InvalidOccurrence;
                        if (self.last_emitted) |previous| if (@intFromEnum(id) <= previous) continue;
                        if (try self.inScope(id) and try self.hasKind(id)) {
                            self.last_emitted = @intFromEnum(id);
                            return .{ .occurrence = id };
                        }
                    }
                    const parent = (try self.parents.next()) orelse return null;
                    try self.begin(parent);
                }
            }
        };
    };
}

pub fn TextSelection(comptime Parent: type) type {
    const Text = @TypeOf(@as(Parent, undefined).context().strings.text(@as(model.StringId, undefined)));
    return struct {
        parents: Parent,

        const Self = @This();
        const EventRange = struct { start: u32, end: u32 };

        pub fn iterator(self: Self) Iterator {
            return .{ .parents = self.parents.iterator() };
        }

        pub const Hit = struct {
            event_index: u32,
            value_id: model.StringId,
            value: Text,

            pub fn render(self: *const @This(), output: []u8) ![]const u8 {
                return self.value.render(output);
            }

            pub fn snippet(self: *const @This(), output: []u8) ![]const u8 {
                return self.value.snippet(output);
            }
        };

        pub const Iterator = struct {
            parents: Parent.Iterator,
            next_event: u32 = 0,
            event_end: u32 = 0,
            covered_until: u32 = 0,

            pub fn next(self: *@This()) !?Hit {
                while (true) {
                    while (self.next_event < self.event_end) {
                        const index = self.next_event;
                        self.next_event = std.math.add(u32, self.next_event, 1) catch return error.InvalidOccurrence;
                        const context_value = self.parents.context();
                        switch (try context_value.topology.event(index)) {
                            .text => |value| return .{ .event_index = index, .value_id = value, .value = context_value.strings.text(value) },
                            else => {},
                        }
                    }
                    const handle = (try self.parents.next()) orelse return null;
                    const context_value = self.parents.context();
                    const range: EventRange = switch (handle) {
                        .occurrence => |id| value: {
                            const row = try context_value.topology.occurrence(id);
                            break :value .{
                                .start = std.math.add(u32, row.event_open, 1) catch return error.InvalidOccurrence,
                                .end = row.event_close,
                            };
                        },
                        .span => |span| .{ .start = span.start, .end = span.end },
                    };
                    if (range.end <= self.covered_until) continue;
                    self.next_event = @max(range.start, self.covered_until);
                    self.event_end = range.end;
                    self.covered_until = range.end;
                }
            }
        };
    };
}
