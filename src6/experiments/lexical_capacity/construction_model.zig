//! An additive semantic model of exact, reusable surface construction programs.
//! This augments Entry; it neither replaces its analyses nor infers new ones.
const std = @import("std");
const m = @import("lex6").model;

pub const ByteSpan = struct { start: u32, end: u32 };
pub const Surface = struct {
    bytes: []const u8,
    /// Explicit lexical identity, not an inferred identity from equal spelling.
    target: ?m.Reference = null,
    origins: []const m.Origin = &.{},
};
pub const Parameter = struct {
    name: m.Name,
    role: ?m.Name = null,
    meta: m.Metadata = .{},
};
pub const Argument = union(enum) { binding: u32, literal: Surface };
pub const Instruction = union(enum) {
    literal: Surface,
    /// Ordered, possibly discontinuous spans, copied without a normalizer.
    copy: struct { binding: u32, spans: []const ByteSpan, role: ?m.Name = null },
    slot: struct { binding: u32, role: ?m.Name = null },
    /// Calls may only target earlier programs; the wire graph is acyclic.
    call: struct { program: u32, arguments: []const Argument, role: ?m.Name = null },
    /// Zero realization remains a typed occurrence with its own evidence.
    zero: struct { meta: m.Metadata = .{}, role: ?m.Name = null },
};
pub const Program = struct {
    id: []const u8,
    meta: m.Metadata = .{},
    process: ?m.Name = null,
    parameters: []const Parameter = &.{},
    body: []const Instruction,
};
pub const Realization = struct {
    instruction: u32,
    spans: []const ByteSpan,
    role: ?m.Name = null,
    meta: m.Metadata = .{},
};
pub const Instance = struct {
    meta: m.Metadata = .{},
    /// Existing independent Analysis identity; ambiguity stays explicit.
    analysis: ?m.Reference = null,
    program: u32,
    bindings: []const Surface = &.{},
    authoritative: Surface,
    encoding: enum { utf8, bytes } = .utf8,
    realizations: []const Realization = &.{},
};
pub const Document = struct {
    entry: m.Entry,
    programs: []const Program = &.{},
    /// Ordered alternatives and repeated independently evidenced instances.
    instances: []const Instance = &.{},
};
pub const Limits = struct {
    max_programs: usize = 4096,
    max_parameters: usize = 4096,
    max_instructions: usize = 131072,
    max_depth: usize = 64,
    max_work: usize = 8_000_000,
    max_output: usize = 1024 * 1024,
};
pub const Error = error{ OutOfMemory, InvalidProgram, InvalidBinding, InvalidSpan, InvalidUtf8, InvalidRealization, AuthoritativeMismatch, ConstructionDepthLimit, ConstructionWorkLimit, ConstructionOutputLimit };
fn boundary(bytes: []const u8, position: usize) bool {
    return position == bytes.len or (position < bytes.len and bytes[position] & 0xc0 != 0x80);
}
const Executor = struct {
    allocator: std.mem.Allocator,
    programs: []const Program,
    limits: Limits,
    utf8: bool,
    work: usize = 0,
    out: std.ArrayList(u8) = .empty,
    fn step(self: *Executor, n: usize) Error!void {
        self.work = std.math.add(usize, self.work, n) catch return error.ConstructionWorkLimit;
        if (self.work > self.limits.max_work) return error.ConstructionWorkLimit;
    }
    fn append(self: *Executor, bytes: []const u8) Error!void {
        try self.step(bytes.len);
        if (bytes.len > self.limits.max_output - self.out.items.len) return error.ConstructionOutputLimit;
        if (self.utf8 and !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        try self.out.appendSlice(self.allocator, bytes);
    }
    fn run(self: *Executor, ordinal: usize, bindings: []const Surface, depth: usize, trace: ?[]ByteSpan) Error!void {
        if (depth > self.limits.max_depth) return error.ConstructionDepthLimit;
        if (ordinal >= self.programs.len) return error.InvalidProgram;
        const p = self.programs[ordinal];
        if (p.parameters.len > self.limits.max_parameters or p.parameters.len != bindings.len) return error.InvalidBinding;
        if (p.body.len > self.limits.max_instructions) return error.ConstructionWorkLimit;
        for (p.body, 0..) |instruction, i| {
            const start = self.out.items.len;
            try self.step(1);
            switch (instruction) {
                .literal => |s| try self.append(s.bytes),
                .slot => |s| { if (s.binding >= bindings.len) return error.InvalidBinding; try self.append(bindings[s.binding].bytes); },
                .copy => |copy| {
                    if (copy.binding >= bindings.len) return error.InvalidBinding;
                    const bytes = bindings[copy.binding].bytes;
                    if (self.utf8 and !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
                    for (copy.spans) |span| {
                        try self.step(1);
                        if (span.start > span.end or span.end > bytes.len) return error.InvalidSpan;
                        if (self.utf8 and (!boundary(bytes, span.start) or !boundary(bytes, span.end))) return error.InvalidSpan;
                        try self.append(bytes[span.start..span.end]);
                    }
                },
                .call => |call| {
                    if (call.program >= ordinal or call.program >= self.programs.len or call.arguments.len > self.limits.max_parameters) return error.InvalidProgram;
                    if (call.arguments.len != self.programs[call.program].parameters.len) return error.InvalidBinding;
                    try self.step(call.arguments.len);
                    // Argument arrays are bounded and freed at each return.
                    const actual = try self.allocator.alloc(Surface, call.arguments.len);
                    defer self.allocator.free(actual);
                    for (call.arguments, actual) |arg, *value| value.* = switch (arg) {
                        .literal => |s| s,
                        .binding => |binding_index| if (binding_index < bindings.len) bindings[binding_index] else return error.InvalidBinding,
                    };
                    try self.run(call.program, actual, depth + 1, null);
                },
                .zero => {},
            }
            if (trace) |spans| spans[i] = .{ .start = @intCast(start), .end = @intCast(self.out.items.len) };
        }
    }
};
pub fn execute(a: std.mem.Allocator, programs: []const Program, instance: Instance, limits: Limits) Error![]u8 {
    var used: usize = 0;
    return executeTracked(a, programs, instance, limits, &used);
}
pub fn executeTracked(a: std.mem.Allocator, programs: []const Program, instance: Instance, limits: Limits, used: *usize) Error![]u8 {
    if (programs.len > limits.max_programs or instance.program >= programs.len) return error.InvalidProgram;
    if (limits.max_output > std.math.maxInt(u32) or programs[instance.program].body.len > limits.max_instructions) return error.ConstructionOutputLimit;
    var e = Executor{ .allocator = a, .programs = programs, .limits = limits, .utf8 = instance.encoding == .utf8 };
    errdefer e.out.deinit(a);
    const trace = if (instance.realizations.len == 0) null else try a.alloc(ByteSpan, programs[instance.program].body.len);
    defer if (trace) |owned| a.free(owned);
    try e.run(instance.program, instance.bindings, 0, trace);
    if (!std.mem.eql(u8, e.out.items, instance.authoritative.bytes)) return error.AuthoritativeMismatch;
    for (instance.realizations) |r| {
        try e.step(1);
        if (r.instruction >= programs[instance.program].body.len) return error.InvalidRealization;
        for (r.spans) |span| {
            try e.step(1);
            if (span.start > span.end or span.end > e.out.items.len) return error.InvalidRealization;
            const actual = trace.?[r.instruction];
            if (span.start < actual.start or span.end > actual.end) return error.InvalidRealization;
            if (e.utf8 and (!boundary(e.out.items, span.start) or !boundary(e.out.items, span.end))) return error.InvalidRealization;
        }
    }
    used.* = e.work;
    return e.out.toOwnedSlice(a);
}

test "Arabic discontinuous root, literal pattern, zero and independent evidence" {
    const a = std.testing.allocator;
    const programs = [_]Program{.{ .id = "arabic-root-pattern", .meta = .{ .language = .{ .tag = "ar" } }, .process = .{ .namespace = "urn:analysis", .local = "root-pattern" }, .parameters = &.{.{ .name = .{ .local = "root-source" }, .role = .{ .local = "root" } }}, .body = &.{
        .{ .copy = .{ .binding = 0, .spans = &.{.{ .start = 0, .end = 2 }} } }, .{ .literal = .{ .bytes = "َ" } },
        .{ .copy = .{ .binding = 0, .spans = &.{.{ .start = 4, .end = 6 }} } }, .{ .literal = .{ .bytes = "َ" } },
        .{ .copy = .{ .binding = 0, .spans = &.{.{ .start = 8, .end = 10 }} } }, .{ .literal = .{ .bytes = "َ" } }, .{ .zero = .{ .role = .{ .local = "person" } } },
    } }};
    const instance = Instance{ .program = 0, .bindings = &.{.{ .bytes = "كَتَبَ", .target = .{ .local = "written" } }}, .authoritative = .{ .bytes = "كَتَبَ", .target = .{ .local = "written" } }, .realizations = &.{.{ .instruction = 6, .spans = &.{.{ .start = 12, .end = 12 }} }} };
    const bytes = try execute(a, &programs, instance, .{}); defer a.free(bytes);
    try std.testing.expectEqualStrings("كَتَبَ", bytes);
    var bad = instance; bad.bindings = &.{.{ .bytes = "abc" }};
    try std.testing.expectError(error.InvalidSpan, execute(a, &programs, bad, .{}));
    try std.testing.expectError(error.ConstructionOutputLimit, execute(a, &programs, instance, .{ .max_output = 3 }));
}
test "reusable suffix call, reduplication, exact decomposed bytes and opaque fallback" {
    const a = std.testing.allocator;
    const programs = [_]Program{
        .{ .id = "base", .parameters = &.{.{ .name = .{ .local = "stem" } }}, .body = &.{.{ .slot = .{ .binding = 0 } }} },
        .{ .id = "chain", .meta = .{ .language = .{ .tag = "tr" } }, .parameters = &.{.{ .name = .{ .local = "stem" } }}, .body = &.{ .{ .call = .{ .program = 0, .arguments = &.{.{ .binding = 0 }} } }, .{ .literal = .{ .bytes = "ler" } }, .{ .literal = .{ .bytes = "imiz" } }, .{ .literal = .{ .bytes = "den" } } } },
        .{ .id = "repeat", .parameters = &.{.{ .name = .{ .local = "stem" } }}, .body = &.{ .{ .slot = .{ .binding = 0 } }, .{ .literal = .{ .bytes = "-" } }, .{ .slot = .{ .binding = 0 } } } },
    };
    for ([_]Instance{ .{ .program = 1, .bindings = &.{.{ .bytes = "ev" }}, .authoritative = .{ .bytes = "evlerimizden" } }, .{ .program = 2, .bindings = &.{.{ .bytes = "é" }}, .authoritative = .{ .bytes = "é-é" } }, .{ .program = 2, .encoding = .bytes, .bindings = &.{.{ .bytes = "\xff\x00" }}, .authoritative = .{ .bytes = "\xff\x00-\xff\x00" } } }) |instance| {
        const bytes = try execute(a, &programs, instance, .{}); defer a.free(bytes);
        try std.testing.expectEqualSlices(u8, instance.authoritative.bytes, bytes);
    }
    try std.testing.expectError(error.ConstructionWorkLimit, execute(a, &programs, .{ .program = 1, .bindings = &.{.{ .bytes = "ev" }}, .authoritative = .{ .bytes = "evlerimizden" } }, .{ .max_work = 1 }));
}
