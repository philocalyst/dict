const std = @import("std");
const bytes = @import("bytes.zig");
const columns = @import("columns.zig");
const model = @import("model.zig");
const stored = @import("stored.zig");
const strings = @import("strings.zig");
const topology = @import("topology.zig");
const targets = @import("targets.zig");

pub const External = stored.Type(model.ExternalReference);
pub const Atom = union(enum) {
    string: model.StringId,
    symbol: model.StringId,
    boolean: bool,
    integer: i64,
    decimal: model.StringId,
    reference: targets.Target,
    external_reference: External,
    product: ?model.StringId,
    list,
    set,
    bag,
    alternative,
    negation: model.ValueId,
    default_marker,
    unknown,
    unspecified,
};
pub const Row = struct { atom: Atom, child_end: u32 };
pub const Edge = union(enum) {
    field: struct { name: model.StringId, value: model.ValueId },
    member: model.ValueId,
};
const Rows = columns.Records(Row);
const Edges = columns.Records(Edge);
const Parts = struct { rows: void, edges: void };

pub const Error = columns.Error || strings.Error || topology.Error || error{ InvalidValueGraph, InvalidExternalDomain, InvalidPredicate, ConflictingDomain, OutputTooSmall };
pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub fn build(allocator: std.mem.Allocator, pool: *strings.Builder, source: *const topology.Owned, documents: []const model.DocumentInput, input: []const model.ValueInput) Error!Owned {
    const rows = try allocator.alloc(Row, input.len);
    defer allocator.free(rows);
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(allocator);
    var product_names: std.StringHashMapUnmanaged(void) = .empty;
    defer product_names.deinit(allocator);
    for (input, 0..) |value, index| {
        const atom: Atom = switch (value) {
            .string => |text| .{ .string = try pool.intern(text) },
            .symbol => |text| .{ .symbol = try pool.intern(text) },
            .boolean => |boolean| .{ .boolean = boolean },
            .integer => |integer| .{ .integer = integer },
            .decimal => |decimal| decimal_value: {
                var cursor = SliceCursor{ .value = decimal };
                if (!try validDecimalCursor(&cursor)) return error.InvalidValueGraph;
                break :decimal_value .{ .decimal = try pool.intern(decimal) };
            },
            .reference => |reference| .{ .reference = try targets.lower(pool, source, documents, reference) },
            .external_reference => |reference| .{ .external_reference = try stored.lower(pool, reference) },
            .product => |product| product_value: {
                product_names.clearRetainingCapacity();
                for (product.fields) |field| {
                    const result = try product_names.getOrPut(allocator, field.name);
                    if (result.found_existing) return error.InvalidValueGraph;
                    try edges.append(allocator, .{ .field = .{ .name = try pool.intern(field.name), .value = field.value } });
                }
                break :product_value .{ .product = if (product.type_label) |label| try pool.intern(label) else null };
            },
            .list => |items| list: {
                for (items) |item| try edges.append(allocator, .{ .member = item });
                break :list .list;
            },
            .set => |items| set: {
                const ordered = try allocator.dupe(model.ValueId, items);
                defer allocator.free(ordered);
                std.mem.sort(model.ValueId, ordered, {}, struct {
                    fn lessThan(_: void, left: model.ValueId, right: model.ValueId) bool {
                        return @intFromEnum(left) < @intFromEnum(right);
                    }
                }.lessThan);
                for (ordered, 0..) |item, item_index| {
                    if (item_index != 0 and item == ordered[item_index - 1]) return error.InvalidValueGraph;
                    try edges.append(allocator, .{ .member = item });
                }
                break :set .set;
            },
            .bag => |items| bag: {
                for (items) |item| try edges.append(allocator, .{ .member = item });
                break :bag .bag;
            },
            .alternative => |items| alternative: {
                if (items.len < 2) return error.InvalidValueGraph;
                for (items) |item| try edges.append(allocator, .{ .member = item });
                break :alternative .alternative;
            },
            .negation => |target| .{ .negation = target },
            .default_marker => .default_marker,
            .unknown => .unknown,
            .unspecified => .unspecified,
        };
        if (edges.items.len > std.math.maxInt(u32)) return error.InvalidValueGraph;
        rows[index] = .{ .atom = atom, .child_end = @intCast(edges.items.len) };
    }
    var row_store = try Rows.build(allocator, rows);
    defer row_store.deinit();
    var edge_store = try Edges.build(allocator, edges.items);
    defer edge_store.deinit();
    const output = try bytes.Bundle(Parts).build(allocator, .{ .rows = row_store.bytes, .edges = edge_store.bytes });
    return .{ .allocator = allocator, .bytes = output.bytes };
}

pub fn ViewFor(comptime Source: type) type {
    return struct {
        rows: Rows.ViewFor(bytes.Span(Source)),
        edges: Edges.ViewFor(bytes.Span(Source)),
        const Self = @This();
        pub const ReadError = Error || bytes.SourceError(Source);

        pub fn open(source: Source) ReadError!Self {
            const bundle = try bytes.Bundle(Parts).ViewFor(Source).open(source);
            const Span = bytes.Span(Source);
            return .{
                .rows = try Rows.ViewFor(Span).open(bundle.part(.rows)),
                .edges = try Edges.ViewFor(Span).open(bundle.part(.edges)),
            };
        }

        pub fn value(self: *const Self, id: model.ValueId) ReadError!Atom {
            return self.rows.field(.atom, @intFromEnum(id));
        }

        pub fn memberSpan(self: *const Self, id: model.ValueId) ReadError!struct { start: u32, end: u32 } {
            const index = @intFromEnum(id);
            const end = try self.rows.field(.child_end, index);
            const start = if (index == 0) 0 else try self.rows.field(.child_end, index - 1);
            if (start > end or end > self.edges.row_count) return error.InvalidValueGraph;
            return .{ .start = start, .end = end };
        }

        pub fn handle(self: *const Self, pool: strings.ViewFor(Source), id: model.ValueId) HandleFor(Source) {
            return .{ .view = self.*, .pool = pool, .id = id };
        }

        pub fn verify(self: *const Self, allocator: std.mem.Allocator, domains: model.DomainCatalogue, source: anytype, declarations: anytype, pool: anytype) ReadError!void {
            try self.rows.verify(domains);
            try self.edges.verify(domains);
            var product_names: std.AutoHashMapUnmanaged(model.StringId, void) = .empty;
            defer product_names.deinit(allocator);
            var child_end: u32 = 0;
            for (0..self.rows.row_count) |index| {
                const row = try self.rows.row(index);
                if (row.child_end < child_end or row.child_end > self.edges.row_count) return error.InvalidValueGraph;
                const uses_members = switch (row.atom) {
                    .list, .set, .bag, .alternative => true,
                    else => false,
                };
                const uses_fields = std.meta.activeTag(row.atom) == .product;
                switch (row.atom) {
                    .reference => |target| try targets.validate(target, source, declarations),
                    .external_reference => |external| try declarations.validateExternal(external),
                    .decimal => |decimal| if (!try validDecimalText(pool.text(decimal))) return error.InvalidValueGraph,
                    else => {},
                }
                if (!uses_members and !uses_fields and row.child_end != child_end) return error.InvalidValueGraph;
                for (child_end..row.child_end) |edge_index| {
                    const edge = try self.edges.row(edge_index);
                    if (uses_fields != (std.meta.activeTag(edge) == .field)) return error.InvalidValueGraph;
                }
                if (uses_fields) {
                    product_names.clearRetainingCapacity();
                    for (child_end..row.child_end) |edge_index| {
                        const name = (try self.edges.row(edge_index)).field.name;
                        const result = try product_names.getOrPut(allocator, name);
                        if (result.found_existing) return error.InvalidValueGraph;
                    }
                }
                if (std.meta.activeTag(row.atom) == .set) {
                    var previous: ?u32 = null;
                    for (child_end..row.child_end) |edge_index| {
                        const ordinal = @intFromEnum((try self.edges.row(edge_index)).member);
                        if (previous) |prior| if (ordinal <= prior) return error.InvalidValueGraph;
                        previous = ordinal;
                    }
                }
                if (std.meta.activeTag(row.atom) == .alternative and row.child_end - child_end < 2) return error.InvalidValueGraph;
                child_end = row.child_end;
            }
            if (child_end != self.edges.row_count) return error.InvalidValueGraph;
        }

        fn validDecimalText(text: anytype) !bool {
            var cursor = try text.cursor();
            return validDecimalCursor(&cursor);
        }
    };
}

const SliceCursor = struct {
    value: []const u8,
    next_index: usize = 0,

    pub fn next(self: *SliceCursor) error{}!?u8 {
        if (self.next_index == self.value.len) return null;
        defer self.next_index += 1;
        return self.value[self.next_index];
    }
};

fn validDecimalCursor(cursor: anytype) !bool {
    var byte = try cursor.next();
    if (byte == '+' or byte == '-') byte = try cursor.next();
    const first = byte orelse return false;
    if (first == '0') {
        byte = try cursor.next();
        if (byte != null and byte.? >= '0' and byte.? <= '9') return false;
    } else if (first >= '1' and first <= '9') {
        byte = try cursor.next();
        while (byte != null and byte.? >= '0' and byte.? <= '9') byte = try cursor.next();
    } else return false;
    if (byte == null) return true;
    if (byte.? != '.') return false;
    byte = try cursor.next();
    if (byte == null or byte.? < '0' or byte.? > '9') return false;
    while (try cursor.next()) |digit| if (digit < '0' or digit > '9') return false;
    return true;
}

pub const View = ViewFor([]const u8);

pub fn HandleFor(comptime Source: type) type {
    return struct {
        view: ViewFor(Source),
        pool: strings.ViewFor(Source),
        id: model.ValueId,

        const Self = @This();
        pub const ReadError = ViewFor(Source).ReadError;

        pub fn atom(self: *const Self) ReadError!Atom {
            return self.view.value(self.id);
        }

        pub fn typeLabel(self: *const Self) ReadError!?strings.TextFor(Source) {
            return switch (try self.atom()) {
                .product => |label| if (label) |id| self.pool.text(id) else null,
                else => error.InvalidValueGraph,
            };
        }

        pub fn field(self: *const Self, name: []const u8) ReadError!?Self {
            if (std.meta.activeTag(try self.atom()) != .product) return error.InvalidValueGraph;
            const span = try self.view.memberSpan(self.id);
            for (span.start..span.end) |edge_index| switch (try self.view.edges.row(edge_index)) {
                .field => |edge| if (try self.pool.eqlBytes(edge.name, name)) {
                    return .{ .view = self.view, .pool = self.pool, .id = edge.value };
                },
                .member => return error.InvalidValueGraph,
            };
            return null;
        }

        pub fn members(self: *const Self) ReadError!MemberCursor {
            switch (std.meta.activeTag(try self.atom())) {
                .list, .set, .bag, .alternative => {},
                else => return error.InvalidValueGraph,
            }
            const span = try self.view.memberSpan(self.id);
            return .{ .handle = self.*, .next = span.start, .end = span.end };
        }

        pub fn text(self: *const Self) ReadError!strings.TextFor(Source) {
            return switch (try self.atom()) {
                .string, .symbol, .decimal => |id| self.pool.text(id),
                else => error.InvalidValueGraph,
            };
        }

        pub fn render(self: *const Self, output: []u8) ReadError![]const u8 {
            return switch (try self.atom()) {
                .string, .symbol, .decimal => |id| self.pool.text(id).render(output),
                .boolean => |value| copyLiteral(output, if (value) "true" else "false"),
                .integer => |value| std.fmt.bufPrint(output, "{d}", .{value}) catch return error.OutputTooSmall,
                .default_marker => copyLiteral(output, "default"),
                .unknown => copyLiteral(output, "unknown"),
                .unspecified => copyLiteral(output, "unspecified"),
                else => error.InvalidValueGraph,
            };
        }

        pub fn byteLength(self: *const Self) ReadError!usize {
            return switch (try self.atom()) {
                .string, .symbol, .decimal => |id| self.pool.text(id).byteLength(),
                .boolean => |value| if (value) 4 else 5,
                .integer => |value| length: {
                    var buffer: [32]u8 = undefined;
                    break :length (std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable).len;
                },
                .default_marker => 7,
                .unknown => 7,
                .unspecified => 11,
                else => error.InvalidValueGraph,
            };
        }

        pub fn snippet(self: *const Self, output: []u8) ReadError![]const u8 {
            var scalar_buffer: [32]u8 = undefined;
            const atom_value = try self.atom();
            switch (atom_value) {
                .string, .symbol, .decimal => |id| return self.pool.text(id).snippet(output),
                else => {},
            }
            const value = switch (atom_value) {
                .boolean => |boolean| if (boolean) "true" else "false",
                .integer => |integer| std.fmt.bufPrint(&scalar_buffer, "{d}", .{integer}) catch unreachable,
                .default_marker => "default",
                .unknown => "unknown",
                .unspecified => "unspecified",
                else => return error.InvalidValueGraph,
            };
            const length = @min(value.len, output.len);
            @memcpy(output[0..length], value[0..length]);
            return output[0..length];
        }

        fn copyLiteral(output: []u8, literal: []const u8) ReadError![]const u8 {
            if (literal.len > output.len) return error.OutputTooSmall;
            @memcpy(output[0..literal.len], literal);
            return output[0..literal.len];
        }

        pub const MemberCursor = struct {
            handle: Self,
            next: u32,
            end: u32,

            pub fn nextValue(self: *@This()) ReadError!?Self {
                if (self.next == self.end) return null;
                if (self.next > self.end) return error.InvalidValueGraph;
                const edge = try self.handle.view.edges.row(self.next);
                self.next = std.math.add(u32, self.next, 1) catch return error.InvalidValueGraph;
                return switch (edge) {
                    .member => |id| .{ .view = self.handle.view, .pool = self.handle.pool, .id = id },
                    .field => error.InvalidValueGraph,
                };
            }
        };
    };
}

test "typed value graph preserves list duplicates and exact decimal spelling" {
    const input = [_]model.ValueInput{
        .{ .decimal = "1.2300" },
        .{ .list = &.{ @enumFromInt(0), @enumFromInt(0) } },
    };
    var pool = strings.Builder.init(std.testing.allocator);
    defer pool.deinit();
    const document = [_]model.DocumentInput{};
    var source = try topology.build(std.testing.allocator, &pool, &document, .{});
    defer source.deinit();
    var owned = try build(std.testing.allocator, &pool, &source, &document, &input);
    defer owned.deinit();
    const view = try View.open(owned.bytes);
    var domains: model.DomainCatalogue = .{};
    try domains.setOwned(model.Domain{ .value = {} }, 2);
    try domains.setOwned(model.Domain{ .string = {} }, @intCast(pool.values.items.len));
    try domains.setOwned(model.Domain{ .document = {} }, 0);
    try domains.setOwned(model.Domain{ .external_domain = {} }, 0);
    const topology_view = try topology.View.open(source.bytes, .{});
    var pool_owned = try pool.build(std.testing.allocator);
    defer pool_owned.deinit();
    const pool_view = try strings.View.open(pool_owned.bytes);
    const Declarations = struct {
        pub fn validateExternal(_: @This(), _: stored.Type(model.ExternalReference)) error{}!void {}
    };
    try view.verify(std.testing.allocator, domains, topology_view, Declarations{}, pool_view);
    const span = try view.memberSpan(@enumFromInt(1));
    try std.testing.expectEqual(@as(u32, 2), span.end - span.start);
}

test "builder rejects malformed decimal lexemes and duplicate product names" {
    var pool = strings.Builder.init(std.testing.allocator);
    defer pool.deinit();
    const documents = [_]model.DocumentInput{};
    var source = try topology.build(std.testing.allocator, &pool, &documents, .{});
    defer source.deinit();
    const invalid = [_][]const u8{ "", "+", "01", "1.", ".1", "1e2", " 1", "1..0", &.{0xff} };
    for (invalid) |lexeme| {
        const input = [_]model.ValueInput{.{ .decimal = lexeme }};
        try std.testing.expectError(error.InvalidValueGraph, build(std.testing.allocator, &pool, &source, &documents, &input));
    }
    const duplicate = [_]model.ValueInput{
        .{ .string = "value" },
        .{ .product = .{ .fields = &.{
            .{ .name = "same", .value = @enumFromInt(0) },
            .{ .name = "same", .value = @enumFromInt(0) },
        } } },
    };
    try std.testing.expectError(error.InvalidValueGraph, build(std.testing.allocator, &pool, &source, &documents, &duplicate));
}
