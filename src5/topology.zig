const std = @import("std");
const bytes = @import("bytes.zig");
const columns = @import("columns.zig");
const model = @import("model.zig");
const strings = @import("strings.zig");
const stored = @import("stored.zig");

pub const Error = columns.Error || strings.Error || error{
    InvalidOccurrence,
    DuplicateOccurrence,
    Cycle,
    DepthExceeded,
    OutputTooSmall,
};

pub const Name = stored.Type(model.ExpandedName);
pub const Namespace = stored.Type(model.NamespaceInput);
pub const Attribute = stored.Type(model.AttributeInput);
pub const Event = union(enum) {
    open: model.OccurrenceId,
    close: model.OccurrenceId,
    text: model.StringId,
    comment: model.StringId,
    processing_instruction: struct { target: model.StringId, data: model.StringId },
};
pub const Occurrence = struct {
    parent: ?model.OccurrenceId,
    subtree_end: u32,
    event_open: u32,
    event_close: u32,
    namespace_end: u32,
    attribute_end: u32,
    name: ?Name,
};
pub const Document = struct {
    scope: model.StringId,
    occurrence_start: u32,
    occurrence_end: u32,
    content_start: u32,
    content_end: u32,
};

const Documents = columns.Records(Document);
const Occurrences = columns.Records(Occurrence);
const Events = columns.Records(Event);
const Namespaces = columns.Records(Namespace);
const Attributes = columns.Records(Attribute);
const Parts = struct { documents: void, occurrences: void, events: void, namespaces: void, attributes: void };

pub const Limits = struct {
    max_occurrences: usize = 16 * 1024 * 1024,
    max_events: usize = 64 * 1024 * 1024,
    max_depth: usize = 4096,
};
pub const Scope = union(enum) { document: model.DocumentId, occurrence: model.OccurrenceId };

pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    document_offsets: []u32,
    local_to_global: []model.OccurrenceId,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.allocator.free(self.document_offsets);
        self.allocator.free(self.local_to_global);
        self.* = undefined;
    }

    pub fn resolve(self: *const Owned, scoped: model.ScopedOccurrence) Error!model.OccurrenceId {
        const document = @intFromEnum(scoped.document);
        if (document + 1 >= self.document_offsets.len) return error.InvalidOccurrence;
        const local = @intFromEnum(scoped.occurrence);
        const start = self.document_offsets[document];
        const end = self.document_offsets[document + 1];
        if (local >= end - start) return error.InvalidOccurrence;
        return self.local_to_global[start + local];
    }

    pub fn resolveAnchor(self: *const Owned, documents: []const model.DocumentInput, anchor: model.Anchor) Error!model.SourceHandle {
        return switch (anchor) {
            .occurrence => |occurrence| .{ .occurrence = try self.resolve(occurrence) },
            .span => |span| span_result: {
                const document_index = @intFromEnum(span.owner.document);
                if (document_index >= documents.len) return error.InvalidOccurrence;
                const local_index = @intFromEnum(span.owner.occurrence);
                const document = documents[document_index];
                if (local_index >= document.occurrences.len) return error.InvalidOccurrence;
                const content = document.occurrences[local_index].content;
                if (span.start > span.end or span.end > content.len) return error.InvalidOccurrence;
                const view = try View.open(self.bytes, .{});
                const owner = try self.resolve(span.owner);
                const owner_row = try view.occurrence(owner);
                var cursor = std.math.add(u32, owner_row.event_open, 1) catch return error.Overflow;
                var range_start: ?u32 = null;
                for (content, 0..) |event, boundary| {
                    if (boundary == span.start) range_start = cursor;
                    cursor = switch (event) {
                        .child => |child| child_end: {
                            const child_id = try self.resolve(.{ .document = span.owner.document, .occurrence = child });
                            const child_row = try view.occurrence(child_id);
                            break :child_end std.math.add(u32, child_row.event_close, 1) catch return error.Overflow;
                        },
                        else => std.math.add(u32, cursor, 1) catch return error.Overflow,
                    };
                }
                if (span.start == content.len) range_start = cursor;
                const range_end = if (span.end == content.len) cursor else end: {
                    var at = std.math.add(u32, owner_row.event_open, 1) catch return error.Overflow;
                    for (content[0..span.end]) |event| at = switch (event) {
                        .child => |child| child_end: {
                            const child_id = try self.resolve(.{ .document = span.owner.document, .occurrence = child });
                            const child_row = try view.occurrence(child_id);
                            break :child_end std.math.add(u32, child_row.event_close, 1) catch return error.Overflow;
                        },
                        else => std.math.add(u32, at, 1) catch return error.Overflow,
                    };
                    break :end at;
                };
                break :span_result .{ .span = .{ .owner = owner, .start = range_start.?, .end = range_end } };
            },
        };
    }
};

const Compiler = struct {
    allocator: std.mem.Allocator,
    pool: *strings.Builder,
    documents: std.ArrayList(Document) = .empty,
    occurrences: std.ArrayList(Occurrence) = .empty,
    events: std.ArrayList(Event) = .empty,
    namespaces: std.ArrayList(Namespace) = .empty,
    attributes: std.ArrayList(Attribute) = .empty,
    mapping: []model.OccurrenceId,
    state: []u2,
    limits: Limits,

    fn appendEvent(self: *Compiler, event: Event) Error!void {
        if (self.events.items.len >= self.limits.max_events) return error.InvalidOccurrence;
        try self.events.append(self.allocator, event);
    }

    fn atom(self: *Compiler, input: model.EventInput, document: model.DocumentId, parent: ?model.OccurrenceId, depth: usize, source: []const model.OccurrenceInput) Error!void {
        switch (input) {
            .text => |value| try self.appendEvent(.{ .text = try self.pool.intern(value) }),
            .comment => |value| try self.appendEvent(.{ .comment = try self.pool.intern(value) }),
            .processing_instruction => |value| try self.appendEvent(.{ .processing_instruction = .{
                .target = try self.pool.intern(value.target),
                .data = try self.pool.intern(value.data),
            } }),
            .child => |child| try self.visit(document, parent, depth, source, @intFromEnum(child)),
        }
    }

    fn visit(self: *Compiler, document: model.DocumentId, parent: ?model.OccurrenceId, depth: usize, source: []const model.OccurrenceInput, source_index: usize) Error!void {
        if (source_index >= source.len) return error.InvalidOccurrence;
        if (depth > self.limits.max_depth) return error.DepthExceeded;
        if (self.state[source_index] == 1) return error.Cycle;
        if (self.state[source_index] == 2) return error.DuplicateOccurrence;
        if (self.occurrences.items.len >= self.limits.max_occurrences or self.events.items.len >= self.limits.max_events) return error.InvalidOccurrence;
        self.state[source_index] = 1;
        const id = model.OccurrenceId.fromIndex(self.occurrences.items.len) catch return error.InvalidOccurrence;
        self.mapping[source_index] = id;
        const input = source[source_index];
        try self.appendEvent(.{ .open = id });
        const event_open: u32 = @intCast(self.events.items.len - 1);
        for (input.namespaces) |namespace| try self.namespaces.append(self.allocator, try stored.lower(self.pool, namespace));
        for (input.attributes) |attribute| try self.attributes.append(self.allocator, try stored.lower(self.pool, attribute));
        const row_index = self.occurrences.items.len;
        try self.occurrences.append(self.allocator, .{
            .parent = parent,
            .subtree_end = 0,
            .event_open = event_open,
            .event_close = 0,
            .namespace_end = @intCast(self.namespaces.items.len),
            .attribute_end = @intCast(self.attributes.items.len),
            .name = if (input.name) |name| try stored.lower(self.pool, name) else null,
        });
        for (input.content) |event| try self.atom(event, document, id, depth + 1, source);
        self.occurrences.items[row_index].event_close = @intCast(self.events.items.len);
        try self.appendEvent(.{ .close = id });
        self.occurrences.items[row_index].subtree_end = @intCast(self.occurrences.items.len);
        self.state[source_index] = 2;
    }
};

pub fn build(allocator: std.mem.Allocator, pool: *strings.Builder, inputs: []const model.DocumentInput, limits: Limits) Error!Owned {
    var local_count: usize = 0;
    for (inputs) |document| local_count = std.math.add(usize, local_count, document.occurrences.len) catch return error.Overflow;
    const mapping = try allocator.alloc(model.OccurrenceId, local_count);
    errdefer allocator.free(mapping);
    const offsets = try allocator.alloc(u32, inputs.len + 1);
    errdefer allocator.free(offsets);
    var compiler = Compiler{ .allocator = allocator, .pool = pool, .mapping = &.{}, .state = &.{}, .limits = limits };
    defer {
        compiler.documents.deinit(allocator);
        compiler.occurrences.deinit(allocator);
        compiler.events.deinit(allocator);
        compiler.namespaces.deinit(allocator);
        compiler.attributes.deinit(allocator);
    }
    var local_offset: usize = 0;
    for (inputs, 0..) |document, document_index| {
        offsets[document_index] = @intCast(local_offset);
        const state = try allocator.alloc(u2, document.occurrences.len);
        defer allocator.free(state);
        @memset(state, 0);
        compiler.mapping = mapping[local_offset..][0..document.occurrences.len];
        compiler.state = state;
        const occurrence_start: u32 = @intCast(compiler.occurrences.items.len);
        const content_start: u32 = @intCast(compiler.events.items.len);
        const document_id = model.DocumentId.fromIndex(document_index) catch return error.InvalidOccurrence;
        for (document.content) |event| try compiler.atom(event, document_id, null, 1, document.occurrences);
        for (state) |seen| if (seen != 2) return error.InvalidOccurrence;
        try compiler.documents.append(allocator, .{
            .scope = try pool.intern(document.scope),
            .occurrence_start = occurrence_start,
            .occurrence_end = @intCast(compiler.occurrences.items.len),
            .content_start = content_start,
            .content_end = @intCast(compiler.events.items.len),
        });
        local_offset += document.occurrences.len;
    }
    offsets[inputs.len] = @intCast(local_offset);

    var document_store = try Documents.build(allocator, compiler.documents.items);
    defer document_store.deinit();
    var occurrence_store = try Occurrences.build(allocator, compiler.occurrences.items);
    defer occurrence_store.deinit();
    var event_store = try Events.build(allocator, compiler.events.items);
    defer event_store.deinit();
    var namespace_store = try Namespaces.build(allocator, compiler.namespaces.items);
    defer namespace_store.deinit();
    var attribute_store = try Attributes.build(allocator, compiler.attributes.items);
    defer attribute_store.deinit();
    const output = try bytes.Bundle(Parts).build(allocator, .{
        .documents = document_store.bytes,
        .occurrences = occurrence_store.bytes,
        .events = event_store.bytes,
        .namespaces = namespace_store.bytes,
        .attributes = attribute_store.bytes,
    });
    return .{ .allocator = allocator, .bytes = output.bytes, .document_offsets = offsets, .local_to_global = mapping };
}

pub fn ViewFor(comptime Source: type) type {
    return struct {
        documents: Documents.ViewFor(bytes.Span(Source)),
        occurrences: Occurrences.ViewFor(bytes.Span(Source)),
        events: Events.ViewFor(bytes.Span(Source)),
        namespaces: Namespaces.ViewFor(bytes.Span(Source)),
        attributes: Attributes.ViewFor(bytes.Span(Source)),
        max_depth: usize,

        const Self = @This();
        pub const ReadError = Error || bytes.SourceError(Source);

        pub fn open(source: Source, limits: Limits) ReadError!Self {
            const bundle = try bytes.Bundle(Parts).ViewFor(Source).open(source);
            const RecordLimits = columns.Limits{
                .max_rows = @max(limits.max_occurrences, limits.max_events),
                .max_cells = 256 * 1024 * 1024,
            };
            const span = bytes.Span(Source);
            return .{
                .documents = try Documents.ViewFor(span).open(bundle.part(.documents)),
                .occurrences = try Occurrences.ViewFor(span).openWithLimits(bundle.part(.occurrences), RecordLimits),
                .events = try Events.ViewFor(span).openWithLimits(bundle.part(.events), RecordLimits),
                .namespaces = try Namespaces.ViewFor(span).openWithLimits(bundle.part(.namespaces), RecordLimits),
                .attributes = try Attributes.ViewFor(span).openWithLimits(bundle.part(.attributes), RecordLimits),
                .max_depth = limits.max_depth,
            };
        }

        pub fn occurrence(self: *const Self, id: model.OccurrenceId) ReadError!Occurrence {
            return self.occurrences.row(@intFromEnum(id));
        }

        pub fn elementName(self: *const Self, id: model.OccurrenceId) ReadError!?Name {
            return (try self.occurrence(id)).name;
        }

        pub fn event(self: *const Self, index: usize) ReadError!Event {
            return self.events.row(index);
        }

        pub fn balancedRange(self: *const Self, start: u32, end: u32) ReadError!bool {
            if (start > end or end > self.events.row_count) return false;
            var depth: usize = 0;
            for (start..end) |index| switch (try self.events.row(index)) {
                .open => depth += 1,
                .close => {
                    if (depth == 0) return false;
                    depth -= 1;
                },
                else => {},
            };
            return depth == 0;
        }

        fn lowerBoundEventOpen(self: *const Self, wanted: u32) ReadError!u32 {
            // Full verify proves event_open is strictly increasing with source
            // preorder. This bounded search navigates that proof; it does not
            // independently authenticate an otherwise unverified forest.
            var low: usize = 0;
            var high = self.occurrences.row_count;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (try self.occurrences.field(.event_open, middle) < wanted) {
                    low = middle + 1;
                } else {
                    high = middle;
                }
            }
            if (low > std.math.maxInt(u32)) return error.InvalidOccurrence;
            if (low != 0 and try self.occurrences.field(.event_open, low - 1) >= wanted) return error.InvalidOccurrence;
            if (low != self.occurrences.row_count and try self.occurrences.field(.event_open, low) < wanted) return error.InvalidOccurrence;
            return @intCast(low);
        }

        pub const OccurrenceRange = struct { start: u32, end: u32 };

        pub fn occurrencesInEventRange(self: *const Self, start: u32, end: u32) ReadError!OccurrenceRange {
            if (start > end or end > self.events.row_count) return error.InvalidOccurrence;
            return .{
                .start = try self.lowerBoundEventOpen(start),
                .end = try self.lowerBoundEventOpen(end),
            };
        }

        fn enclosingOccurrence(self: *const Self, event_index: u32) ReadError!model.OccurrenceId {
            if (event_index >= self.events.row_count) return error.InvalidOccurrence;
            const after = std.math.add(u32, event_index, 1) catch return error.InvalidOccurrence;
            const upper = try self.lowerBoundEventOpen(after);
            if (upper == 0) return error.InvalidOccurrence;
            var current = upper - 1;
            var steps: usize = 0;
            while (true) {
                // Full verify proves parent containment. Strict rank progress
                // and max_depth keep this local owner lookup safe on hostile
                // standalone views as well.
                const row = try self.occurrences.row(current);
                if (row.event_open > event_index) return error.InvalidOccurrence;
                if (event_index < row.event_close) return @enumFromInt(current);
                const parent = row.parent orelse return error.InvalidOccurrence;
                const parent_index = @intFromEnum(parent);
                if (parent_index >= current) return error.InvalidOccurrence;
                current = parent_index;
                steps = std.math.add(usize, steps, 1) catch return error.DepthExceeded;
                if (steps > self.max_depth) return error.DepthExceeded;
            }
        }

        fn isContentBoundary(self: *const Self, owner_id: model.OccurrenceId, owner: Occurrence, position: u32) ReadError!bool {
            const content_start = std.math.add(u32, owner.event_open, 1) catch return error.InvalidOccurrence;
            if (position == content_start or position == owner.event_close) return true;
            if (position < content_start or position > owner.event_close) return false;
            return switch (try self.event(position)) {
                .open => |child_id| child: {
                    const child_index = @intFromEnum(child_id);
                    if (child_index >= self.occurrences.row_count) break :child false;
                    const row = try self.occurrences.row(child_index);
                    if (row.event_open != position or row.parent != owner_id or row.event_close <= row.event_open or row.event_close >= owner.event_close) break :child false;
                    break :child switch (try self.event(row.event_close)) {
                        .close => |closed| closed == child_id,
                        else => false,
                    };
                },
                .close => false,
                .text, .comment, .processing_instruction => (try self.enclosingOccurrence(position)) == owner_id,
            };
        }

        pub fn validateSpan(self: *const Self, span: model.SourceEventSpan) ReadError!void {
            const owner = try self.occurrence(span.owner);
            const content_start = std.math.add(u32, owner.event_open, 1) catch return error.InvalidOccurrence;
            if (span.start > span.end or span.start < content_start or span.end > owner.event_close) return error.InvalidOccurrence;
            if (owner.event_open >= owner.event_close or owner.event_close >= self.events.row_count) return error.InvalidOccurrence;
            switch (try self.event(owner.event_open)) {
                .open => |opened| if (opened != span.owner) return error.InvalidOccurrence,
                else => return error.InvalidOccurrence,
            }
            switch (try self.event(owner.event_close)) {
                .close => |closed| if (closed != span.owner) return error.InvalidOccurrence,
                else => return error.InvalidOccurrence,
            }
            if (!try self.isContentBoundary(span.owner, owner, span.start) or
                !try self.isContentBoundary(span.owner, owner, span.end)) return error.InvalidOccurrence;
        }

        pub fn validateHandle(self: *const Self, handle: model.SourceHandle) ReadError!void {
            switch (handle) {
                .occurrence => |occurrence_id| _ = try self.occurrence(occurrence_id),
                .span => |span| try self.validateSpan(span),
            }
        }

        fn metadataStart(self: *const Self, occurrence_index: usize, comptime field: enum { namespace, attribute }) ReadError!u32 {
            if (occurrence_index == 0) return 0;
            const previous_row = try self.occurrences.row(occurrence_index - 1);
            return switch (field) {
                .namespace => previous_row.namespace_end,
                .attribute => previous_row.attribute_end,
            };
        }

        fn stringEqual(pool: anytype, left: model.StringId, right: []const u8) !bool {
            return pool.eqlBytes(left, right);
        }

        fn expandedNameEqual(pool: anytype, left: Name, namespace_uri: []const u8, local_name: []const u8) !bool {
            return try stringEqual(pool, left.namespace_uri, namespace_uri) and try stringEqual(pool, left.local_name, local_name);
        }

        pub fn verify(self: *const Self, allocator: std.mem.Allocator, domains: model.DomainCatalogue, pool: anytype) !void {
            try self.documents.verify(domains);
            try self.occurrences.verify(domains);
            try self.events.verify(domains);
            try self.namespaces.verify(domains);
            try self.attributes.verify(domains);
            var prior_occurrence_end: u32 = 0;
            var prior_content_end: u32 = 0;
            for (0..self.documents.row_count) |document_index| {
                const document = try self.documents.row(document_index);
                if (document.occurrence_start != prior_occurrence_end or document.occurrence_end < document.occurrence_start or document.occurrence_end > self.occurrences.row_count) return error.InvalidOccurrence;
                if (document.content_start != prior_content_end or document.content_end < document.content_start or document.content_end > self.events.row_count) return error.InvalidOccurrence;
                prior_occurrence_end = document.occurrence_end;
                prior_content_end = document.content_end;
            }
            if (prior_occurrence_end != self.occurrences.row_count or prior_content_end != self.events.row_count) return error.InvalidOccurrence;

            var namespace_start: u32 = 0;
            var attribute_start: u32 = 0;
            for (0..self.occurrences.row_count) |index| {
                const row = try self.occurrences.row(index);
                if (row.subtree_end <= index or row.subtree_end > self.occurrences.row_count) return error.InvalidOccurrence;
                if (row.event_open >= row.event_close or row.event_close >= self.events.row_count) return error.InvalidOccurrence;
                if (row.namespace_end < namespace_start or row.namespace_end > self.namespaces.row_count) return error.InvalidOccurrence;
                if (row.attribute_end < attribute_start or row.attribute_end > self.attributes.row_count) return error.InvalidOccurrence;
                namespace_start = row.namespace_end;
                attribute_start = row.attribute_end;
            }
            if (namespace_start != self.namespaces.row_count or attribute_start != self.attributes.row_count) return error.InvalidOccurrence;

            const stack = try allocator.alloc(model.OccurrenceId, self.max_depth);
            defer allocator.free(stack);
            var next_occurrence: u32 = 0;
            for (0..self.documents.row_count) |document_index| {
                const document = try self.documents.row(document_index);
                var depth: usize = 0;
                for (document.content_start..document.content_end) |event_index| switch (try self.events.row(event_index)) {
                    .open => |id| {
                        if (@intFromEnum(id) != next_occurrence or depth == stack.len) return error.InvalidOccurrence;
                        const row = try self.occurrence(id);
                        const expected_parent: ?model.OccurrenceId = if (depth == 0) null else stack[depth - 1];
                        if (row.parent != expected_parent or row.event_open != event_index) return error.InvalidOccurrence;
                        stack[depth] = id;
                        depth += 1;
                        next_occurrence += 1;
                    },
                    .close => |id| {
                        if (depth == 0 or stack[depth - 1] != id) return error.InvalidOccurrence;
                        const row = try self.occurrence(id);
                        if (row.event_close != event_index or row.subtree_end != next_occurrence) return error.InvalidOccurrence;
                        depth -= 1;
                    },
                    else => {},
                };
                if (depth != 0 or next_occurrence != document.occurrence_end) return error.InvalidOccurrence;
            }
            if (next_occurrence != self.occurrences.row_count) return error.InvalidOccurrence;

            const xml_namespace = "http://www.w3.org/XML/1998/namespace";
            for (0..self.occurrences.row_count) |occurrence_index| {
                const row = try self.occurrences.row(occurrence_index);
                const namespace_span_start = try self.metadataStart(occurrence_index, .namespace);
                const attribute_span_start = try self.metadataStart(occurrence_index, .attribute);
                for (namespace_span_start..row.namespace_end) |left_index| {
                    const left = try self.namespaces.row(left_index);
                    for (namespace_span_start..left_index) |right_index| {
                        const right = try self.namespaces.row(right_index);
                        if (left.prefix == null and right.prefix == null) return error.InvalidOccurrence;
                        if (left.prefix != null and right.prefix != null and try pool.order(left.prefix.?, right.prefix.?) == .eq) return error.InvalidOccurrence;
                    }
                }
                for (attribute_span_start..row.attribute_end) |left_index| {
                    const left = try self.attributes.row(left_index);
                    for (attribute_span_start..left_index) |right_index| {
                        const right = try self.attributes.row(right_index);
                        if (left.name.namespace_uri == right.name.namespace_uri and left.name.local_name == right.name.local_name) return error.InvalidOccurrence;
                    }
                }
            }
            for (0..self.documents.row_count) |document_index| {
                const document = try self.documents.row(document_index);
                for (document.occurrence_start..document.occurrence_end) |left_occurrence| {
                    const left_id = (try self.attributeByName(pool, @enumFromInt(left_occurrence), xml_namespace, "id")) orelse continue;
                    for (document.occurrence_start..left_occurrence) |right_occurrence| {
                        const right_id = try self.attributeByName(pool, @enumFromInt(right_occurrence), xml_namespace, "id");
                        if (right_id != null and try pool.order(left_id.id, right_id.?.id) == .eq) return error.InvalidOccurrence;
                    }
                }
            }
        }

        fn nameEqual(self: *const Self, pool: anytype, row: Occurrence, namespace_uri: []const u8, local_name: []const u8) !bool {
            _ = self;
            const name = row.name orelse return false;
            return try pool.eqlBytes(name.namespace_uri, namespace_uri) and
                try pool.eqlBytes(name.local_name, local_name);
        }

        const Bounds = struct { start: u32, end: u32 };

        fn contentBounds(self: *const Self, occurrence_id: model.OccurrenceId) ReadError!Bounds {
            const row = try self.occurrence(occurrence_id);
            const start = std.math.add(u32, row.event_open, 1) catch return error.InvalidOccurrence;
            if (start > row.event_close or row.event_close >= self.events.row_count) return error.InvalidOccurrence;
            return .{ .start = start, .end = row.event_close };
        }

        pub fn descendants(self: *const Self, pool: anytype, scope: Scope, namespace_uri: []const u8, local_name: []const u8) !Descendants(@TypeOf(pool)) {
            const bounds: Bounds = switch (scope) {
                .document => |id| bounds: {
                    const document = try self.documents.row(@intFromEnum(id));
                    break :bounds .{ .start = document.occurrence_start, .end = document.occurrence_end };
                },
                .occurrence => |id| bounds: {
                    const index = @intFromEnum(id);
                    const row = try self.occurrence(id);
                    const start = std.math.add(u32, index, 1) catch return error.InvalidOccurrence;
                    break :bounds .{ .start = start, .end = row.subtree_end };
                },
            };
            return .{ .view = self.*, .pool = pool, .next = bounds.start, .end = bounds.end, .namespace_uri = namespace_uri, .local_name = local_name };
        }

        pub fn Descendants(comptime Pool: type) type {
            return struct {
                view: Self,
                pool: Pool,
                next: u32,
                end: u32,
                namespace_uri: []const u8,
                local_name: []const u8,

                pub fn nextHandle(self: *@This()) !?model.OccurrenceId {
                    while (self.next < self.end) {
                        const index = self.next;
                        self.next += 1;
                        const row = try self.view.occurrences.row(index);
                        if (try self.view.nameEqual(self.pool, row, self.namespace_uri, self.local_name)) return @enumFromInt(index);
                    }
                    return null;
                }
            };
        }

        pub fn plainText(self: *const Self, pool: anytype, occurrence_id: model.OccurrenceId, output: []u8) ![]const u8 {
            const bounds = try self.contentBounds(occurrence_id);
            var required: usize = 0;
            for (bounds.start..bounds.end) |index| switch (try self.events.row(index)) {
                .text => |text_id| required = std.math.add(usize, required, try pool.text(text_id).byteLength()) catch return error.Overflow,
                else => {},
            };
            if (required > output.len) return error.OutputTooSmall;
            var written: usize = 0;
            for (bounds.start..bounds.end) |index| switch (try self.events.row(index)) {
                .text => |text_id| {
                    const value = try pool.text(text_id).render(output[written..]);
                    written += value.len;
                },
                else => {},
            };
            return output[0..written];
        }

        pub fn plainTextSnippet(self: *const Self, pool: anytype, occurrence_id: model.OccurrenceId, output: []u8) ![]const u8 {
            const bounds = try self.contentBounds(occurrence_id);
            if (output.len == 0) return output;
            var written: usize = 0;
            for (bounds.start..bounds.end) |index| switch (try self.events.row(index)) {
                .text => |text_id| {
                    const value = try pool.text(text_id).snippet(output[written..]);
                    written += value.len;
                    if (written == output.len) return output;
                },
                else => {},
            };
            return output[0..written];
        }

        pub fn attributeByName(self: *const Self, pool: strings.ViewFor(Source), occurrence_id: model.OccurrenceId, namespace_uri: []const u8, local_name: []const u8) !?strings.TextFor(Source) {
            const index = @intFromEnum(occurrence_id);
            const row = try self.occurrence(occurrence_id);
            const start = try self.metadataStart(index, .attribute);
            for (start..row.attribute_end) |attribute_index| {
                const attribute = try self.attributes.row(attribute_index);
                if (try expandedNameEqual(pool, attribute.name, namespace_uri, local_name)) return pool.text(attribute.value);
            }
            return null;
        }

        pub fn lookupXmlId(self: *const Self, pool: anytype, document_id: model.DocumentId, wanted: []const u8) !?model.OccurrenceId {
            const document = try self.documents.row(@intFromEnum(document_id));
            for (document.occurrence_start..document.occurrence_end) |index| {
                const id = try self.attributeByName(pool, @enumFromInt(index), "http://www.w3.org/XML/1998/namespace", "id");
                if (id != null and try id.?.eqlBytes(wanted)) return @enumFromInt(index);
            }
            return null;
        }

        pub const Language = struct { value: ?strings.TextFor(Source), owner: ?model.OccurrenceId };

        pub fn effectiveLanguage(self: *const Self, pool: anytype, occurrence_id: model.OccurrenceId) !Language {
            var current: ?model.OccurrenceId = occurrence_id;
            var steps: usize = 0;
            while (current) |id| {
                if (try self.attributeByName(pool, id, "http://www.w3.org/XML/1998/namespace", "lang")) |language| return .{ .value = language, .owner = id };
                current = (try self.occurrence(id)).parent;
                steps += 1;
                if (steps > self.max_depth) return error.DepthExceeded;
            }
            return .{ .value = null, .owner = null };
        }

        pub fn eventsIn(self: *const Self, scope: Scope) ReadError!EventCursor {
            const bounds: Bounds = switch (scope) {
                .document => |id| value: {
                    const document = try self.documents.row(@intFromEnum(id));
                    break :value .{ .start = document.content_start, .end = document.content_end };
                },
                .occurrence => |id| value: {
                    const row = try self.occurrence(id);
                    break :value .{ .start = row.event_open + 1, .end = row.event_close };
                },
            };
            return .{ .view = self.*, .next = bounds.start, .end = bounds.end };
        }

        pub const EventCursor = struct {
            view: Self,
            next: u32,
            end: u32,

            pub fn nextEvent(self: *@This()) ReadError!?struct { index: u32, value: Event } {
                if (self.next == self.end) return null;
                const index = self.next;
                self.next += 1;
                return .{ .index = index, .value = try self.view.event(index) };
            }
        };

        pub fn namespacesOf(self: *const Self, id: model.OccurrenceId) ReadError!NamespaceCursor {
            const index = @intFromEnum(id);
            const row = try self.occurrence(id);
            return .{ .view = self.*, .next = try self.metadataStart(index, .namespace), .end = row.namespace_end };
        }

        pub const NamespaceCursor = struct {
            view: Self,
            next: u32,
            end: u32,
            pub fn nextNamespace(self: *@This()) ReadError!?Namespace {
                if (self.next == self.end) return null;
                defer self.next += 1;
                return try self.view.namespaces.row(self.next);
            }
        };

        pub fn attributesOf(self: *const Self, id: model.OccurrenceId) ReadError!AttributeCursor {
            const index = @intFromEnum(id);
            const row = try self.occurrence(id);
            return .{ .view = self.*, .next = try self.metadataStart(index, .attribute), .end = row.attribute_end };
        }

        pub const AttributeCursor = struct {
            view: Self,
            next: u32,
            end: u32,
            pub fn nextAttribute(self: *@This()) ReadError!?Attribute {
                if (self.next == self.end) return null;
                defer self.next += 1;
                return try self.view.attributes.row(self.next);
            }
        };
    };
}

pub const View = ViewFor([]const u8);

test "balanced source topology retains empty handles and renders descendant text" {
    const occurrences = [_]model.OccurrenceInput{
        .{
            .name = .{ .namespace_uri = "", .local_name = "entry" },
            .content = &.{
                .{ .text = "a" },
                .{ .child = @enumFromInt(1) },
                .{ .comment = "ignored" },
                .{ .processing_instruction = .{ .target = "test", .data = "ignored" } },
                .{ .text = "b" },
            },
        },
        .{ .name = .{ .namespace_uri = "", .local_name = "sense" }, .content = &.{.{ .text = "x" }} },
    };
    const documents = [_]model.DocumentInput{.{
        .scope = "d",
        .occurrences = &occurrences,
        .content = &.{.{ .child = @enumFromInt(0) }},
    }};
    var pool_builder = strings.Builder.init(std.testing.allocator);
    defer pool_builder.deinit();
    var owned = try build(std.testing.allocator, &pool_builder, &documents, .{});
    defer owned.deinit();
    var pool_owned = try pool_builder.build(std.testing.allocator);
    defer pool_owned.deinit();
    const pool = try strings.View.open(pool_owned.bytes);
    const view = try View.open(owned.bytes, .{});
    var domains: model.DomainCatalogue = .{};
    try domains.setOwned(model.Domain{ .document = {} }, 1);
    try domains.setOwned(model.Domain{ .occurrence = {} }, 2);
    try domains.setOwned(model.Domain{ .string = {} }, @intCast(pool.count()));
    try view.verify(std.testing.allocator, domains, pool);
    var found = try view.descendants(pool, .{ .occurrence = @enumFromInt(0) }, "", "sense");
    try std.testing.expectEqual(@as(model.OccurrenceId, @enumFromInt(1)), (try found.nextHandle()).?);
    try std.testing.expect((try found.nextHandle()) == null);
    var output: [8]u8 = undefined;
    try std.testing.expectEqualStrings("axb", try view.plainText(pool, @enumFromInt(0), &output));
    const child_span = try owned.resolveAnchor(&documents, .{ .span = .{
        .owner = .{ .document = @enumFromInt(0), .occurrence = @enumFromInt(0) },
        .start = 1,
        .end = 2,
    } });
    const child_row = try view.occurrence(@enumFromInt(1));
    try std.testing.expectEqual(child_row.event_open, child_span.span.start);
    try std.testing.expectEqual(child_row.event_close + 1, child_span.span.end);
    try std.testing.expect(try view.balancedRange(child_span.span.start, child_span.span.end));
    const root = try view.occurrence(@enumFromInt(0));
    const root_start = root.event_open + 1;
    const after_child = child_row.event_close + 1;
    for ([_]u32{ root_start, child_row.event_open, after_child, after_child + 1, after_child + 2, root.event_close }) |boundary| {
        try view.validateSpan(.{ .owner = @enumFromInt(0), .start = boundary, .end = boundary });
    }
    try view.validateSpan(.{
        .owner = @enumFromInt(0),
        .start = child_row.event_open,
        .end = after_child,
    });
    try std.testing.expectError(error.InvalidOccurrence, view.validateSpan(.{
        .owner = @enumFromInt(0),
        .start = child_row.event_open + 1,
        .end = child_row.event_open + 1,
    }));
    try std.testing.expectError(error.InvalidOccurrence, view.validateSpan(.{
        .owner = @enumFromInt(0),
        .start = child_row.event_close,
        .end = child_row.event_close,
    }));
    try std.testing.expectError(error.InvalidOccurrence, build(std.testing.allocator, &pool_builder, &documents, .{ .max_events = 2 }));
}

test "zero-demand text rejects a close coordinate past the event tape" {
    const no_documents = [_]Document{};
    const occurrences = [_]Occurrence{.{
        .parent = null,
        .subtree_end = 1,
        .event_open = 0,
        .event_close = 1,
        .namespace_end = 0,
        .attribute_end = 0,
        .name = null,
    }};
    const events = [_]Event{.{ .open = @enumFromInt(0) }};
    const no_namespaces = [_]Namespace{};
    const no_attributes = [_]Attribute{};
    var document_store = try Documents.build(std.testing.allocator, &no_documents);
    defer document_store.deinit();
    var occurrence_store = try Occurrences.build(std.testing.allocator, &occurrences);
    defer occurrence_store.deinit();
    var event_store = try Events.build(std.testing.allocator, &events);
    defer event_store.deinit();
    var namespace_store = try Namespaces.build(std.testing.allocator, &no_namespaces);
    defer namespace_store.deinit();
    var attribute_store = try Attributes.build(std.testing.allocator, &no_attributes);
    defer attribute_store.deinit();
    var wire = try bytes.Bundle(Parts).build(std.testing.allocator, .{
        .documents = document_store.bytes,
        .occurrences = occurrence_store.bytes,
        .events = event_store.bytes,
        .namespaces = namespace_store.bytes,
        .attributes = attribute_store.bytes,
    });
    defer wire.deinit();

    var pool_builder = strings.Builder.init(std.testing.allocator);
    defer pool_builder.deinit();
    var pool_owned = try pool_builder.build(std.testing.allocator);
    defer pool_owned.deinit();
    const pool = try strings.View.open(pool_owned.bytes);
    const view = try View.open(wire.bytes, .{});
    var output: [0]u8 = .{};
    try std.testing.expectError(error.InvalidOccurrence, view.plainTextSnippet(pool, @enumFromInt(0), &output));
}
