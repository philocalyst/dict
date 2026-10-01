//! A bounded, non-production comparison of the reflective JSON codec with
//! the schema-specialized packet codec.  This file is intentionally kept out
//! of the public module graph: it records what a possible migration would
//! preserve and where the standard JSON API needs a safety wrapper.

const std = @import("std");
// The standalone command supplies these four names as module dependencies;
// keeping the experiment in its own directory avoids adding an import alias
// or changing the production module graph.
const compression = @import("compression");
const fixtures = @import("fixtures");
const packet = @import("packet");

// `fixtures.rich` is declared as the production model.Entry.  Deriving these
// aliases from it lets the experiment compile as an isolated module while
// retaining the exact production types (the fixture module itself imports the
// model source from its own src6 module root).
const Entry = @TypeOf(fixtures.rich);
const Metadata = @TypeOf(fixtures.rich.meta);
const Language = @TypeOf(fixtures.rich.meta.language);
const Item = @TypeOf(fixtures.rich.content[0]);
pub const Error = error{
    InputTooLarge,
    OutputTooLarge,
    TokenLimit,
    DepthLimit,
};

pub const ParseError = Error || std.json.ParseError(std.json.Scanner);

pub const Limits = struct {
    /// Bounds the complete JSON document before the parser is entered.
    max_input_bytes: usize = 64 * 1024 * 1024,
    /// Bounds tokens admitted by the scanner preflight.
    max_tokens: usize = 8 * 1024 * 1024,
    /// Bounds object/array nesting.  The standard parser itself has no such
    /// option, so this is checked before reflective parsing starts.
    max_depth: usize = 128,
    /// Bounds an individual JSON string or number token in the parser.
    max_value_len: usize = 4 * 1024 * 1024,
    /// Bounds allocations made by the parser's arena and scanner.
    max_allocation_bytes: usize = 256 * 1024 * 1024,
};

const json_options: std.json.Stringify.Options = .{
    .emit_null_optional_fields = false,
    .emit_strings_as_arrays = false,
    .emit_nonportable_numbers_as_strings = false,
};

const BudgetAllocator = struct {
    child: std.mem.Allocator,
    limit: usize,
    used: usize = 0,
    hit_limit: bool = false,

    fn allocator(self: *BudgetAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *BudgetAllocator = @ptrCast(@alignCast(context));
        if (len > self.limit -| self.used) {
            self.hit_limit = true;
            return null;
        }
        const result = self.child.rawAlloc(len, alignment, return_address) orelse return null;
        self.used += len;
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *BudgetAllocator = @ptrCast(@alignCast(context));
        if (new_len > memory.len) {
            const growth = new_len - memory.len;
            if (growth > self.limit -| self.used) {
                self.hit_limit = true;
                return false;
            }
            if (!self.child.rawResize(memory, alignment, new_len, return_address)) return false;
            self.used += growth;
            return true;
        }

        if (!self.child.rawResize(memory, alignment, new_len, return_address)) return false;
        self.used -= memory.len - new_len;
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *BudgetAllocator = @ptrCast(@alignCast(context));
        if (new_len > memory.len) {
            const growth = new_len - memory.len;
            if (growth > self.limit -| self.used) {
                self.hit_limit = true;
                return null;
            }
            const result = self.child.rawRemap(memory, alignment, new_len, return_address) orelse return null;
            self.used += growth;
            return result;
        }

        const result = self.child.rawRemap(memory, alignment, new_len, return_address) orelse return null;
        self.used -= memory.len - new_len;
        return result;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *BudgetAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, return_address);
        self.used -= memory.len;
    }
};

pub const OwnedJson = struct {
    allocator: std.mem.Allocator,
    budget: *BudgetAllocator,
    arena: *std.heap.ArenaAllocator,
    value: []Entry,

    pub fn entries(self: *const @This()) []const Entry {
        return self.value;
    }

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.allocator.destroy(self.budget);
        self.* = undefined;
    }
};

fn stackBudgetBytes(max_depth: usize) Error!usize {
    const bytes = std.math.add(usize, max_depth, 7) catch return error.DepthLimit;
    const rounded = bytes / 8;
    // Scanner growth is capped at a small multiple of the admitted depth.
    // The explicit slack covers ArrayList growth rounding and zero-depth input.
    const doubled = std.math.mul(usize, rounded, 2) catch return error.DepthLimit;
    return std.math.add(usize, doubled, 512) catch return error.DepthLimit;
}

/// Validate syntax and admission bounds without allocating parser-owned
/// values.  A capped child allocator also prevents Scanner's nesting stack
/// from growing with an attacker-controlled depth before the depth check.
pub fn preflightJson(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) ParseError!void {
    if (bytes.len > limits.max_input_bytes) return error.InputTooLarge;

    var stack_budget = BudgetAllocator{
        .child = allocator,
        .limit = try stackBudgetBytes(limits.max_depth),
    };
    var scanner = std.json.Scanner.initCompleteInput(stack_budget.allocator(), bytes);
    defer scanner.deinit();

    scanner.ensureTotalStackCapacity(limits.max_depth) catch |err| switch (err) {
        error.OutOfMemory => if (stack_budget.hit_limit) return error.DepthLimit else return error.OutOfMemory,
    };

    var depth: usize = 0;
    var tokens: usize = 0;
    while (true) {
        const token = scanner.next() catch |err| switch (err) {
            error.OutOfMemory => if (stack_budget.hit_limit) return error.DepthLimit else return error.OutOfMemory,
            else => return err,
        };
        if (tokens == limits.max_tokens) return error.TokenLimit;
        tokens += 1;

        switch (token) {
            .object_begin, .array_begin => {
                if (depth == limits.max_depth) return error.DepthLimit;
                depth += 1;
            },
            .object_end, .array_end => {
                if (depth == 0) return error.DepthLimit;
                depth -= 1;
            },
            .end_of_document => {
                if (depth != 0) return error.DepthLimit;
                return;
            },
            else => {},
        }
    }
}

/// Parse a complete entry list with the standard reflective parser, after the
/// bounded scanner pass.  `parseFromSliceLeaky` is safe here because every
/// parser allocation is placed in the owned arena and released by `deinit`.
pub fn parseJson(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) ParseError!OwnedJson {
    if (bytes.len > limits.max_input_bytes) return error.InputTooLarge;

    const budget = allocator.create(BudgetAllocator) catch return error.OutOfMemory;
    errdefer allocator.destroy(budget);
    budget.* = .{ .child = allocator, .limit = limits.max_allocation_bytes };

    try preflightJson(budget.allocator(), bytes, limits);

    const arena = allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(budget.allocator());
    errdefer arena.deinit();

    @setEvalBranchQuota(2_000_000);
    const value = try std.json.parseFromSliceLeaky(
        []Entry,
        arena.allocator(),
        bytes,
        .{
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = false,
            .max_value_len = limits.max_value_len,
            .allocate = .alloc_always,
        },
    );

    return .{
        .allocator = allocator,
        .budget = budget,
        .arena = arena,
        .value = value,
    };
}

/// Stringify with a caller-owned temporary writer under an allocation budget.
/// The returned slice is copied to the caller allocator and is therefore
/// independent of the temporary budget's lifetime.
pub fn stringifyEntries(allocator: std.mem.Allocator, entries: []const Entry, limits: Limits) ParseError![]u8 {
    var budget = BudgetAllocator{
        .child = allocator,
        .limit = limits.max_allocation_bytes,
    };
    var writer = std.Io.Writer.Allocating.init(budget.allocator());
    defer writer.deinit();

    @setEvalBranchQuota(2_000_000);
    std.json.Stringify.value(entries, json_options, &writer.writer) catch return error.OutOfMemory;
    if (writer.written().len > limits.max_input_bytes) return error.OutputTooLarge;
    return allocator.dupe(u8, writer.written()) catch return error.OutOfMemory;
}

const packet_limits: packet.Limits = .{
    .max_input_bytes = 128 * 1024 * 1024,
    .max_allocation_bytes = 256 * 1024 * 1024,
    .max_slice_length = 1_000_000,
    .max_depth = 256,
    .max_work = 100 * 1024 * 1024,
};

const compression_limits: compression.Limits = .{
    .max_block_bytes = 128 * 1024 * 1024,
    .max_memory_bytes = 256 * 1024 * 1024,
};

pub const Measurement = struct {
    count: usize,
    packet_bytes: usize,
    json_bytes: usize,
    packet_bzip3_bytes: usize,
    json_bzip3_bytes: usize,
};

fn repeatedEntries(allocator: std.mem.Allocator, count: usize) ![]Entry {
    const result = try allocator.alloc(Entry, count);
    for (result) |*entry| entry.* = fixtures.rich;
    return result;
}

pub fn compareGroup(allocator: std.mem.Allocator, count: usize) !Measurement {
    const entries = try repeatedEntries(allocator, count);
    defer allocator.free(entries);

    const packet_bytes = try packet.encode(allocator, entries, packet_limits);
    defer allocator.free(packet_bytes);
    var packet_decoded = try packet.decode([]Entry, allocator, packet_bytes, packet_limits);
    defer packet_decoded.deinit();
    try std.testing.expectEqualDeep(entries, packet_decoded.value);

    const json_bytes = try stringifyEntries(allocator, entries, .{});
    defer allocator.free(json_bytes);
    var json_decoded = try parseJson(allocator, json_bytes, .{});
    defer json_decoded.deinit();
    try std.testing.expectEqualDeep(entries, @constCast(json_decoded.entries()));

    var packet_compressed = try compression.encode(allocator, packet_bytes, .bzip3, compression_limits);
    defer packet_compressed.deinit();
    var json_compressed = try compression.encode(allocator, json_bytes, .bzip3, compression_limits);
    defer json_compressed.deinit();

    var packet_restored = try compression.decode(
        allocator,
        packet_compressed.codec,
        packet_compressed.bytes,
        packet_compressed.raw_len,
        compression_limits,
    );
    defer packet_restored.deinit();
    var json_restored = try compression.decode(
        allocator,
        json_compressed.codec,
        json_compressed.bytes,
        json_compressed.raw_len,
        compression_limits,
    );
    defer json_restored.deinit();
    if (!std.mem.eql(u8, packet_bytes, packet_restored.bytes)) return error.PacketCompressionMismatch;
    if (!std.mem.eql(u8, json_bytes, json_restored.bytes)) return error.JsonCompressionMismatch;

    std.debug.print(
        "json-packet count={} packet={} json={} packet-bzip3={} json-bzip3={}\n",
        .{ count, packet_bytes.len, json_bytes.len, packet_compressed.bytes.len, json_compressed.bytes.len },
    );
    return .{
        .count = count,
        .packet_bytes = packet_bytes.len,
        .json_bytes = json_bytes.len,
        .packet_bzip3_bytes = packet_compressed.bytes.len,
        .json_bzip3_bytes = json_compressed.bytes.len,
    };
}

const edge_source_bytes = [_]u8{ 0xff, 0x00, 0x80, 0x41, 0xc3, 0xa9 };
const edge_items = [_]Item{
    .{ .grammar = .{
        .name = .{ .namespace = "urn:edge", .local = "minimum" },
        .value = .{ .integer = std.math.minInt(i64) },
    } },
    .{ .grammar = .{
        .name = .{ .local = "maximum" },
        .value = .{ .integer = std.math.maxInt(i64) },
    } },
    .{ .usage = .{
        .kind = .style,
        .value = .{ .default = {} },
    } },
    .{ .form = .{
        .kind = .stem,
        .representations = &.{.{
            .kind = .transliteration,
            .text = .{ .content = &.{.{ .text = "café ☕" }} },
        }},
    } },
    .{ .relation = .{
        .predicate = .{ .custom = .{ .namespace = "urn:edge", .local = "related" } },
        .endpoints = .{ .binary = .{ .unresolved = .{
            .identifier = "missing",
            .base = "urn:base",
            .expected = .{ .local = "sense" },
            .display = "display",
        } } },
        .state = .deprecated,
    } },
    .{ .concept = .{
        .reference = .{ .resource = .{ .id = "range.colors", .fragment = "blue" } },
    } },
};

const edge_entry = Entry{
    .id = "edge.🌐",
    .headword = "naïve",
    .meta = .{ .language = .reset },
    .kind = .free,
    .homograph = 0,
    .keys = &.{.{ .spelling = "NAÏVE", .form = "edge" }},
    .content = &edge_items,
    .sources = &.{.{
        .id = "raw",
        .media_type = "application/octet-stream",
        .bytes = &edge_source_bytes,
    }},
};

test "reflective JSON preserves invalid bytes, extremes, enums, and union tags" {
    const allocator = std.testing.allocator;
    const entries = [_]Entry{edge_entry};
    const json_bytes = try stringifyEntries(allocator, &entries, .{});
    defer allocator.free(json_bytes);

    // Invalid UTF-8 is emitted as a numeric array by Stringify, while the
    // surrounding Unicode strings remain ordinary JSON strings.
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"bytes\":[255,0,128,65,195,169]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "café") != null);

    var parsed = try std.json.parseFromSlice(
        []Entry,
        allocator,
        json_bytes,
        .{
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = false,
            .allocate = .alloc_always,
        },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.len);
    try std.testing.expectEqualDeep(edge_entry, parsed.value[0]);
}

test "JSON missing defaults differ from explicit reset and hostile fields fail" {
    const allocator = std.testing.allocator;

    var absent = try std.json.parseFromSlice(Metadata, allocator, "{}", .{});
    defer absent.deinit();
    try std.testing.expectEqual(Language.inherit, absent.value.language);

    var reset = try std.json.parseFromSlice(
        Metadata,
        allocator,
        "{\"language\":{\"reset\":{}}}",
        .{},
    );
    defer reset.deinit();
    try std.testing.expectEqual(Language.reset, reset.value.language);

    try std.testing.expectError(
        error.UnknownField,
        std.json.parseFromSlice(
            Entry,
            allocator,
            "{\"id\":\"x\",\"headword\":\"x\",\"unknown\":1}",
            .{},
        ),
    );
    try std.testing.expectError(
        error.DuplicateField,
        std.json.parseFromSlice(
            Entry,
            allocator,
            "{\"id\":\"x\",\"id\":\"y\",\"headword\":\"x\"}",
            .{},
        ),
    );
}

fn nestedArray(allocator: std.mem.Allocator, depth: usize) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    for (0..depth) |_| try list.append(allocator, '[');
    try list.append(allocator, '0');
    for (0..depth) |_| try list.append(allocator, ']');
    return list.toOwnedSlice(allocator);
}

test "JSON preflight bounds nesting and token count before reflection" {
    const allocator = std.testing.allocator;
    const deep = try nestedArray(allocator, 33);
    defer allocator.free(deep);
    try std.testing.expectError(error.DepthLimit, parseJson(allocator, deep, .{ .max_depth = 32 }));

    try std.testing.expectError(
        error.TokenLimit,
        parseJson(allocator, "[0,0,0,0,0,0]", .{ .max_tokens = 5 }),
    );
}

test "JSON parser allocation budget is caller-visible" {
    const allocator = std.testing.allocator;
    const json = "[{\"id\":\"budget\",\"headword\":\"budget\",\"sources\":[{\"id\":\"s\",\"media_type\":\"application/octet-stream\",\"bytes\":[1,2,3,4]}]}]";
    try std.testing.expectError(
        error.OutOfMemory,
        parseJson(allocator, json, .{ .max_allocation_bytes = 1024 }),
    );
}

test "packet and JSON preserve complete rich groups through real bzip3" {
    const allocator = std.testing.allocator;
    _ = try compareGroup(allocator, 32);
    _ = try compareGroup(allocator, 256);
    _ = try compareGroup(allocator, 2048);
}
