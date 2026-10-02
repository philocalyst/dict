//! First-class construction admission reuses familiar native semantic rules.
const std = @import("std");
const lex = @import("lex6");
const m = lex.model;
const cm = @import("construction_model.zig");
pub const Error = cm.Error || lex.validate.Error || error{ InvalidSurfaceReference, InvalidAnalysisReference };
fn step(work: *usize, n: usize, limits: cm.Limits) Error!void {
    work.* = std.math.add(usize, work.*, n) catch return error.ConstructionWorkLimit;
    if (work.* > limits.max_work) return error.ConstructionWorkLimit;
}
fn findRepresentation(comptime T: type, value: T, id: []const u8, out: *?m.Representation, work: *usize, limits: cm.Limits, depth: usize) Error!void {
    @setEvalBranchQuota(500_000);
    if (depth > limits.max_depth) return error.ConstructionDepthLimit;
    try step(work, 1, limits);
    if (comptime T == m.Representation) if (value.meta.id) |declared| if (std.mem.eql(u8, declared, id)) { out.* = value; return; };
    switch (@typeInfo(T)) {
        .optional => |o| if (value) |v| { try findRepresentation(o.child, v, id, out, work, limits, depth + 1); },
        .pointer => |p| if (p.size == .one) { try findRepresentation(p.child, value.*, id, out, work, limits, depth + 1); } else if (p.size == .slice and p.child != u8) {
            for (value) |v| try findRepresentation(p.child, v, id, out, work, limits, depth + 1);
        },
        .array => |ar| for (value) |v| try findRepresentation(ar.child, v, id, out, work, limits, depth + 1),
        .@"struct" => |s| inline for (s.fields) |f| try findRepresentation(f.type, @field(value, f.name), id, out, work, limits, depth + 1),
        .@"union" => switch (value) { inline else => |v| try findRepresentation(@TypeOf(v), v, id, out, work, limits, depth + 1) },
        else => {},
    }
}
fn textBytes(a: std.mem.Allocator, content: []const m.Inline, out: *std.ArrayList(u8), work: *usize, limits: cm.Limits, depth: usize) Error!void {
    if (depth > limits.max_depth) return error.ConstructionDepthLimit;
    for (content) |node| {
        try step(work, 1, limits);
        switch (node) {
            .text => |bytes| {
                if (bytes.len > limits.max_output - out.items.len) return error.ConstructionOutputLimit;
                try step(work, bytes.len, limits); try out.appendSlice(a, bytes);
            },
            .element => |e| try textBytes(a, e.content, out, work, limits, depth + 1),
            .comment, .instruction => {},
        }
    }
}
fn findAnalysis(comptime T: type, value: T, id: []const u8, found: *bool, work: *usize, limits: cm.Limits, depth: usize) Error!void {
    @setEvalBranchQuota(500_000);
    if (depth > limits.max_depth) return error.ConstructionDepthLimit;
    try step(work, 1, limits);
    if (comptime T == m.Analysis) if (value.meta.id) |declared| if (std.mem.eql(u8, declared, id)) { found.* = true; return; };
    switch (@typeInfo(T)) {
        .optional => |o| if (value) |v| { try findAnalysis(o.child, v, id, found, work, limits, depth + 1); },
        .pointer => |p| if (p.size == .one) { try findAnalysis(p.child, value.*, id, found, work, limits, depth + 1); } else if (p.size == .slice and p.child != u8) {
            for (value) |v| try findAnalysis(p.child, v, id, found, work, limits, depth + 1);
        },
        .array => |ar| for (value) |v| try findAnalysis(ar.child, v, id, found, work, limits, depth + 1),
        .@"struct" => |s| inline for (s.fields) |f| try findAnalysis(f.type, @field(value, f.name), id, found, work, limits, depth + 1),
        .@"union" => switch (value) { inline else => |v| try findAnalysis(@TypeOf(v), v, id, found, work, limits, depth + 1) },
        else => {},
    }
}
fn checkAnalysis(entry: m.Entry, reference: m.Reference, work: *usize, limits: cm.Limits) Error!void {
    const local: ?[]const u8 = switch (reference) {
        .local => |id| id,
        .entry => |address| if (std.mem.eql(u8, address.id, entry.id)) address.fragment orelse return error.InvalidAnalysisReference else null,
        .resource, .iri, .unresolved => null,
    };
    if (local) |id| {
        var found = false; try findAnalysis(m.Entry, entry, id, &found, work, limits, 0);
        if (!found) return error.InvalidAnalysisReference;
    }
}
fn checkSurface(a: std.mem.Allocator, entry: m.Entry, value: cm.Surface, limits: cm.Limits, work: *usize) Error!void {
    const target = value.target orelse return;
    const local: ?[]const u8 = switch (target) {
        .local => |id| id,
        .entry => |address| address: {
            if (!std.mem.eql(u8, address.id, entry.id)) break :address null;
            if (address.fragment) |fragment| break :address fragment;
            try step(work, value.bytes.len, limits);
            if (!std.mem.eql(u8, value.bytes, entry.headword)) return error.AuthoritativeMismatch;
            return;
        },
        .resource, .iri, .unresolved => null,
    };
    if (local) |id| {
        var found: ?m.Representation = null;
        try findRepresentation(m.Entry, entry, id, &found, work, limits, 0);
        const representation = found orelse return error.InvalidSurfaceReference;
        var expected: std.ArrayList(u8) = .empty; defer expected.deinit(a);
        try textBytes(a, representation.text.content, &expected, work, limits, 0);
        if (!std.mem.eql(u8, expected.items, value.bytes)) return error.AuthoritativeMismatch;
    }
}
// Temporary semantic-check items are never encoded and are not a shadow wire
// model: all familiar values come directly from first-class typed fields.
fn values(comptime T: type, a: std.mem.Allocator, value: T, entry: m.Entry, checks: *std.ArrayList(m.Item), limits: cm.Limits, work: *usize, depth: usize) Error!void {
    @setEvalBranchQuota(500_000);
    if (depth > limits.max_depth) return error.ConstructionDepthLimit;
    try step(work, 1, limits);
    if (comptime T == cm.Surface) try checkSurface(a, entry, value, limits, work);
    if (comptime T == m.Metadata) return checks.append(a, .{ .extension = .{ .name = .{ .namespace = "urn:exact-construction:admission", .local = "metadata" }, .meta = value } });
    if (comptime T == m.Name) return checks.append(a, .{ .grammar = .{ .name = value, .value = .{ .boolean = true } } });
    if (comptime T == m.Reference) return checks.append(a, .{ .component = .{ .target = value } });
    if (comptime T == m.Origin) return checks.append(a, .{ .extension = .{ .name = .{ .namespace = "urn:exact-construction:admission", .local = "origin" }, .meta = .{ .origins = try a.dupe(m.Origin, &.{value}) } } });
    switch (@typeInfo(T)) {
        .optional => |o| if (value) |v| { try values(o.child, a, v, entry, checks, limits, work, depth + 1); },
        .pointer => |p| if (p.size == .one) { try values(p.child, a, value.*, entry, checks, limits, work, depth + 1); } else if (p.size == .slice and p.child != u8) {
            for (value) |v| try values(p.child, a, v, entry, checks, limits, work, depth + 1);
        },
        .array => |ar| for (value) |v| try values(ar.child, a, v, entry, checks, limits, work, depth + 1),
        .@"struct" => |s| inline for (s.fields) |f| try values(f.type, a, @field(value, f.name), entry, checks, limits, work, depth + 1),
        .@"union" => switch (value) { inline else => |v| try values(@TypeOf(v), a, v, entry, checks, limits, work, depth + 1) },
        else => {},
    }
}
pub fn check(a: std.mem.Allocator, document: cm.Document, limits: cm.Limits, native_scope: lex.validate.Scope) Error!void {
    if (document.programs.len > limits.max_programs) return error.InvalidProgram;
    try lex.validate.check(a, &document.entry, native_scope);
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const temporary = arena.allocator();
    var identifiers: std.StringHashMapUnmanaged(void) = .empty; defer identifiers.deinit(temporary);
    var work: usize = 0; var checks: std.ArrayList(m.Item) = .empty;
    try checks.appendSlice(temporary, document.entry.content);
    for (document.programs, 0..) |p, ordinal| {
        if (p.id.len == 0 or !std.unicode.utf8ValidateSlice(p.id)) return error.InvalidProgram;
        const seen = try identifiers.getOrPut(temporary, p.id); if (seen.found_existing) return error.InvalidProgram;
        if (p.parameters.len > limits.max_parameters or p.body.len > limits.max_instructions) return error.ConstructionWorkLimit;
        for (p.body) |instruction| {
            try step(&work, 1, limits);
            switch (instruction) {
                .copy => |copy| {
                    if (copy.binding >= p.parameters.len) return error.InvalidBinding;
                    try step(&work, copy.spans.len, limits);
                    for (copy.spans) |span| if (span.start > span.end) { return error.InvalidSpan; };
                },
                .slot => |slot| if (slot.binding >= p.parameters.len) { return error.InvalidBinding; },
                .call => |call| {
                    if (call.program >= ordinal or call.arguments.len > limits.max_parameters) return error.InvalidProgram;
                    if (call.arguments.len != document.programs[call.program].parameters.len) return error.InvalidBinding;
                    for (call.arguments) |arg| if (arg == .binding and arg.binding >= p.parameters.len) { return error.InvalidBinding; };
                },
                else => {},
            }
        }
        try values(cm.Program, temporary, p, document.entry, &checks, limits, &work, 0);
    }
    for (document.instances) |instance| {
        if (instance.authoritative.target == null) return error.InvalidSurfaceReference;
        if (instance.analysis) |reference| try checkAnalysis(document.entry, reference, &work, limits);
        try values(cm.Instance, temporary, instance, document.entry, &checks, limits, &work, 0);
        var execution_work: usize = 0; var remaining = limits; remaining.max_work = limits.max_work - work;
        const bytes = try cm.executeTracked(a, document.programs, instance, remaining, &execution_work); a.free(bytes);
        try step(&work, execution_work, limits);
    }
    var augmented = document.entry; augmented.content = checks.items;
    try lex.validate.check(temporary, &augmented, native_scope);
}
