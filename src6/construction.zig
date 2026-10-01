//! Exact lexical construction admission. Programs are ordinary public Item
//! payloads; this module only checks their meaning and realizes their bytes.
const std = @import("std");
const model = @import("model.zig");
const nodes = @import("nodes.zig");

pub const Limits = struct {
    max_programs: usize = 4096,
    max_instances: usize = 4096,
    max_parameters: usize = 256,
    max_instructions: usize = 131072,
    max_call_depth: usize = 64,
    max_surface_depth: usize = 96,
    /// Shared across graph admission and every occurrence in one Entry.
    max_work: usize = 8_000_000,
    max_output_bytes: usize = 1024 * 1024,
};

pub const Error = std.mem.Allocator.Error || error{
    ConstructionScope,
    InvalidProgram,
    InvalidBinding,
    InvalidSurfaceReference,
    InvalidAnalysisReference,
    InvalidSpan,
    InvalidUtf8,
    InvalidRealization,
    AuthoritativeMismatch,
    ConstructionCycle,
    ConstructionDepthLimit,
    ConstructionWorkLimit,
    ConstructionOutputLimit,
};

fn boundary(bytes: []const u8, position: usize) bool {
    return position == bytes.len or (position < bytes.len and bytes[position] & 0xc0 != 0x80);
}

const Checker = struct {
    allocator: std.mem.Allocator,
    programs: []const *const model.ConstructionProgram,
    instances: []const *const model.Construction,
    ids: *const std.StringHashMapUnmanaged(nodes.NodeRef),
    limits: Limits,
    by_id: std.StringHashMapUnmanaged(usize) = .empty,
    external: []bool,
    heights: []usize,
    call_frames: []model.ConstructionSurface,
    frame_width: usize,
    trace: []model.ConstructionSpan,
    work: usize = 0,

    fn charge(self: *Checker, amount: usize) Error!void {
        self.work = std.math.add(usize, self.work, amount) catch return error.ConstructionWorkLimit;
        if (self.work > self.limits.max_work) return error.ConstructionWorkLimit;
    }

    fn programIndex(self: *Checker, reference: model.Reference) Error!?usize {
        if (reference != .local) return null;
        try self.charge(reference.local.len);
        const index = self.by_id.get(reference.local) orelse return error.InvalidProgram;
        try self.charge(reference.local.len);
        const owner = self.ids.get(reference.local) orelse return error.InvalidProgram;
        if (owner.as(model.ConstructionProgram) != self.programs[index]) return error.InvalidProgram;
        return index;
    }

    fn representation(self: *Checker, reference: model.Reference) Error!*const model.Representation {
        if (reference != .local) return error.InvalidSurfaceReference;
        try self.charge(reference.local.len);
        const owner = self.ids.get(reference.local) orelse return error.InvalidSurfaceReference;
        return owner.as(model.Representation) orelse return error.InvalidSurfaceReference;
    }

    fn flatten(self: *Checker, content: []const model.Inline, out: *std.ArrayList(u8), depth: usize) Error!void {
        if (depth > self.limits.max_surface_depth) return error.ConstructionDepthLimit;
        for (content) |node| {
            try self.charge(1);
            switch (node) {
                .text => |bytes| {
                    if (bytes.len > self.limits.max_output_bytes - out.items.len) return error.ConstructionOutputLimit;
                    try self.charge(bytes.len);
                    try out.appendSlice(self.allocator, bytes);
                },
                .element => |element| try self.flatten(element.content, out, depth + 1),
                .comment, .instruction => {},
            }
        }
    }

    fn representationBytes(self: *Checker, reference: model.Reference) Error![]u8 {
        const target = try self.representation(reference);
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(self.allocator);
        try self.flatten(target.text.content, &bytes, 0);
        return bytes.toOwnedSlice(self.allocator);
    }

    fn surface(self: *Checker, value: model.ConstructionSurface) Error!void {
        try self.charge(value.bytes.len);
        if (!std.unicode.utf8ValidateSlice(value.bytes)) return error.InvalidUtf8;
        if (value.target) |target| {
            // A foreign target identifies the supplied bytes; it does not
            // withhold those bytes from local program execution.
            if (target != .local) return;
            const expected = try self.representationBytes(target);
            defer self.allocator.free(expected);
            if (!std.mem.eql(u8, expected, value.bytes)) return error.AuthoritativeMismatch;
        }
    }

    fn visit(self: *Checker, colors: []u8, index: usize, depth: usize) Error!usize {
        if (depth > self.limits.max_call_depth) return error.ConstructionDepthLimit;
        if (colors[index] == 1) return error.ConstructionCycle;
        if (colors[index] == 2) {
            if (self.heights[index] > self.limits.max_call_depth - depth)
                return error.ConstructionDepthLimit;
            return self.heights[index];
        }
        colors[index] = 1;
        const program = self.programs[index];
        var unresolved = false;
        var height: usize = 0;
        if (program.parameters.len > self.limits.max_parameters or
            program.body.len > self.limits.max_instructions) return error.ConstructionWorkLimit;
        try self.charge(program.parameters.len);
        for (program.body) |instruction| {
            try self.charge(1);
            switch (instruction) {
                .literal => |value| try self.surface(value),
                .slot => |slot| if (slot.binding >= program.parameters.len) return error.InvalidBinding,
                .copy => |copy| {
                    if (copy.binding >= program.parameters.len) return error.InvalidBinding;
                    try self.charge(copy.spans.len);
                    for (copy.spans) |span| if (span.start > span.end) return error.InvalidSpan;
                },
                .call => |call| {
                    const called = try self.programIndex(call.program);
                    if (call.arguments.len > self.limits.max_parameters or
                        (called != null and call.arguments.len != self.programs[called.?].parameters.len))
                        return error.InvalidBinding;
                    try self.charge(call.arguments.len);
                    for (call.arguments) |argument| switch (argument) {
                        .binding => |ordinal| if (ordinal >= program.parameters.len) return error.InvalidBinding,
                        .literal => |value| try self.surface(value),
                    };
                    if (called) |local| {
                        const child_height = try self.visit(colors, local, depth + 1);
                        if (child_height >= self.limits.max_call_depth - depth)
                            return error.ConstructionDepthLimit;
                        height = @max(height, child_height + 1);
                        unresolved = self.external[local] or unresolved;
                    } else unresolved = true;
                },
                .zero => {},
            }
        }
        colors[index] = 2;
        self.external[index] = unresolved;
        self.heights[index] = height;
        return height;
    }

    fn append(self: *Checker, out: *std.ArrayList(u8), bytes: []const u8) Error!void {
        try self.charge(bytes.len);
        if (bytes.len > self.limits.max_output_bytes - out.items.len) return error.ConstructionOutputLimit;
        try out.appendSlice(self.allocator, bytes);
    }

    fn run(self: *Checker, index: usize, bindings: []const model.ConstructionSurface, out: *std.ArrayList(u8), trace: ?[]model.ConstructionSpan, depth: usize) Error!void {
        if (depth > self.limits.max_call_depth) return error.ConstructionDepthLimit;
        const program = self.programs[index];
        if (bindings.len != program.parameters.len) return error.InvalidBinding;
        for (program.body, 0..) |instruction, ordinal| {
            const start = out.items.len;
            try self.charge(1);
            switch (instruction) {
                .literal => |value| try self.append(out, value.bytes),
                .slot => |slot| try self.append(out, bindings[slot.binding].bytes),
                .copy => |copy| {
                    const bytes = bindings[copy.binding].bytes;
                    for (copy.spans) |span| {
                        try self.charge(1);
                        if (span.end > bytes.len or !boundary(bytes, span.start) or
                            !boundary(bytes, span.end)) return error.InvalidSpan;
                        try self.append(out, bytes[span.start..span.end]);
                    }
                },
                .call => |call| {
                    const called = (try self.programIndex(call.program)) orelse return error.InvalidProgram;
                    try self.charge(call.arguments.len);
                    // Reuse one frame per active call depth. An arena allocator
                    // cannot reclaim a fresh slice after every zero-output call.
                    const offset = (depth + 1) * self.frame_width;
                    const actual = self.call_frames[offset..][0..call.arguments.len];
                    for (call.arguments, actual) |argument, *value| value.* = switch (argument) {
                        .binding => |binding| bindings[binding],
                        .literal => |literal| literal,
                    };
                    try self.run(called, actual, out, null, depth + 1);
                },
                .zero => {},
            }
            if (trace) |spans| spans[ordinal] = .{ .start = @intCast(start), .end = @intCast(out.items.len) };
        }
    }

    /// Check all locally knowable operations of an open program. A foreign
    /// callee has unknown output, but local copies still have concrete binding
    /// bytes and must respect UTF-8 scalar boundaries and source extents.
    fn checkKnown(self: *Checker, index: usize, bindings: []const model.ConstructionSurface, depth: usize) Error!void {
        if (depth > self.limits.max_call_depth) return error.ConstructionDepthLimit;
        const program = self.programs[index];
        for (program.body) |instruction| {
            try self.charge(1);
            switch (instruction) {
                .copy => |copy| {
                    const bytes = bindings[copy.binding].bytes;
                    for (copy.spans) |span| {
                        try self.charge(1);
                        if (span.end > bytes.len or !boundary(bytes, span.start) or
                            !boundary(bytes, span.end)) return error.InvalidSpan;
                    }
                },
                .call => |call| {
                    const called = try self.programIndex(call.program);
                    try self.charge(call.arguments.len);
                    if (called) |local| {
                        const offset = (depth + 1) * self.frame_width;
                        const actual = self.call_frames[offset..][0..call.arguments.len];
                        for (call.arguments, actual) |argument, *value| value.* = switch (argument) {
                            .binding => |binding| bindings[binding],
                            .literal => |literal| literal,
                        };
                        try self.checkKnown(local, actual, depth + 1);
                    }
                },
                else => {},
            }
        }
    }

    fn checkInstance(self: *Checker, instance: *const model.Construction) Error!void {
        try self.charge(1);
        const index = try self.programIndex(instance.program);
        if (index) |local| {
            if (instance.bindings.len != self.programs[local].parameters.len) return error.InvalidBinding;
        } else if (instance.bindings.len > self.limits.max_parameters) return error.InvalidBinding;
        if (instance.analysis) |reference| {
            if (reference == .local) {
                try self.charge(reference.local.len);
                const owner = self.ids.get(reference.local) orelse return error.InvalidAnalysisReference;
                if (owner.as(model.Analysis) == null) return error.InvalidAnalysisReference;
            }
        }
        const unresolved = if (index) |local| self.external[local] else true;
        for (instance.bindings) |binding| try self.surface(binding);
        const authoritative = try self.representationBytes(instance.authoritative);
        defer self.allocator.free(authoritative);
        if (unresolved) {
            if (instance.proof != .external_unverified) return error.InvalidProgram;
            if (index) |local| try self.checkKnown(local, instance.bindings, 0);
            for (instance.realizations) |realization| {
                try self.charge(1);
                if (realization.step >= self.limits.max_instructions or
                    (index != null and realization.step >= self.programs[index.?].body.len))
                    return error.InvalidRealization;
                for (realization.spans) |span| {
                    try self.charge(1);
                    if (span.start > span.end or span.end > authoritative.len or
                        !boundary(authoritative, span.start) or !boundary(authoritative, span.end))
                        return error.InvalidRealization;
                }
            }
            return;
        }
        if (instance.proof != .exact_local) return error.InvalidProgram;
        const local = index.?;
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        const trace = if (instance.realizations.len == 0) null else self.trace[0..self.programs[local].body.len];
        try self.run(local, instance.bindings, &output, trace, 0);
        if (!std.mem.eql(u8, output.items, authoritative)) return error.AuthoritativeMismatch;
        for (instance.realizations) |realization| {
            try self.charge(1);
            if (realization.step >= self.programs[local].body.len) return error.InvalidRealization;
            const extent = trace.?[realization.step];
            for (realization.spans) |span| {
                try self.charge(1);
                if (span.start > span.end or span.start < extent.start or span.end > extent.end or
                    !boundary(output.items, span.start) or !boundary(output.items, span.end))
                    return error.InvalidRealization;
            }
        }
    }
};

/// Called after the ordinary reflected lexical walk has collected identities
/// and validated metadata, names, origins and reference syntax. The program
/// graph is checked even if there are no construction occurrences.
pub fn check(allocator: std.mem.Allocator, programs: []const *const model.ConstructionProgram, instances: []const *const model.Construction, ids: *const std.StringHashMapUnmanaged(nodes.NodeRef), limits: Limits) Error!void {
    if (programs.len > limits.max_programs or instances.len > limits.max_instances) return error.InvalidProgram;
    if (limits.max_output_bytes > std.math.maxInt(u32)) return error.ConstructionOutputLimit;
    const external = try allocator.alloc(bool, programs.len);
    defer allocator.free(external);
    @memset(external, false);
    const heights = try allocator.alloc(usize, programs.len);
    defer allocator.free(heights);
    @memset(heights, 0);
    var checker = Checker{ .allocator = allocator, .programs = programs, .instances = instances, .ids = ids, .limits = limits, .external = external, .heights = heights, .call_frames = &.{}, .frame_width = 0, .trace = &.{} };
    defer checker.by_id.deinit(allocator);
    for (programs, 0..) |program, ordinal| {
        const id = program.meta.id orelse return error.InvalidProgram;
        if (id.len == 0) return error.InvalidProgram;
        try checker.charge(id.len);
        const result = try checker.by_id.getOrPut(allocator, id);
        if (result.found_existing) return error.InvalidProgram;
        result.value_ptr.* = ordinal;
    }
    const colors = try allocator.alloc(u8, programs.len);
    defer allocator.free(colors);
    @memset(colors, 0);
    for (programs, 0..) |_, ordinal| _ = try checker.visit(colors, ordinal, 0);
    var max_height: usize = 0;
    var max_parameters: usize = 0;
    var max_body: usize = 0;
    for (programs, 0..) |program, ordinal| {
        max_height = @max(max_height, checker.heights[ordinal]);
        max_parameters = @max(max_parameters, program.parameters.len);
        max_body = @max(max_body, program.body.len);
    }
    checker.frame_width = max_parameters;
    const slots = std.math.mul(usize, max_height + 1, max_parameters) catch return error.ConstructionWorkLimit;
    checker.call_frames = try allocator.alloc(model.ConstructionSurface, slots);
    defer allocator.free(checker.call_frames);
    checker.trace = try allocator.alloc(model.ConstructionSpan, max_body);
    defer allocator.free(checker.trace);
    for (instances) |instance| try checker.checkInstance(instance);
}
