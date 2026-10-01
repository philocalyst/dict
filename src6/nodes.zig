//! Reflection-derived structural traversal for admission and rich queries.
//!
//! `walk.Cursor` remains the deliberately small hot lexical/inline walker.
//! This cursor visits the complete typed schema: structs, active tagged-union
//! payloads, optionals, slices, arrays, and single-item pointers. Byte slices
//! are leaves. References are ordinary data and are never followed.
const std = @import("std");
const model = @import("model.zig");
const walk = @import("walk.zig");

pub const Error = error{ DepthLimit, WorkLimit };
pub const frame_capacity = 192;

pub const Limits = struct {
    max_depth: usize = 128,
    max_work: usize = 1_000_000,
    max_bytes: usize = std.math.maxInt(usize),
};

pub const Edge = union(enum) {
    root,
    field: []const u8,
    payload: []const u8,
    index: usize,
    dereference,
};

const Descriptor = struct {
    name: []const u8,
    metadata: *const fn (*const anyopaque) ?*const model.Metadata,
};

/// A checked, borrowed pointer to a concrete model struct or tagged union.
/// Construction is internal: `_pointer` may only be interpreted using its
/// matching per-type descriptor. `as` is the sole public cast operation.
pub const NodeRef = struct {
    _pointer: *const anyopaque,
    _descriptor: *const Descriptor,

    pub fn as(self: NodeRef, comptime T: type) ?*const T {
        ensureNodeType(T);
        if (self._descriptor != descriptor(T)) return null;
        return @ptrCast(@alignCast(self._pointer));
    }

    pub fn typeName(self: NodeRef) []const u8 {
        return self._descriptor.name;
    }

    /// Metadata belongs to its containing typed node. Metadata itself is never
    /// returned as a second identity-bearing owner.
    pub fn metadata(self: NodeRef) ?*const model.Metadata {
        return self._descriptor.metadata(self._pointer);
    }

    pub fn identity(self: NodeRef) ?[]const u8 {
        const meta = self.metadata() orelse return null;
        return meta.id;
    }

    pub fn eql(a: NodeRef, b: NodeRef) bool {
        return a._pointer == b._pointer and a._descriptor == b._descriptor;
    }
};

fn ensureNodeType(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct", .@"union" => {},
        else => @compileError("structural nodes are structs or tagged unions, not " ++ @typeName(T)),
    }
}

fn descriptor(comptime T: type) *const Descriptor {
    ensureNodeType(T);
    return &struct {
        const value: Descriptor = .{
            .name = @typeName(T),
            .metadata = metadata,
        };

        fn cast(pointer: *const anyopaque) *const T {
            return @ptrCast(@alignCast(pointer));
        }

        fn metadata(pointer: *const anyopaque) ?*const model.Metadata {
            if (T == model.Metadata) return null;
            if (comptime @typeInfo(T) == .@"struct" and @hasField(T, "meta") and
                @FieldType(T, "meta") == model.Metadata)
            {
                return &cast(pointer).meta;
            }
            return null;
        }
    }.value;
}

fn node(ptr: anytype) ?NodeRef {
    const T = @TypeOf(ptr.*);
    return switch (@typeInfo(T)) {
        .@"struct", .@"union" => .{
            ._pointer = @ptrCast(ptr),
            ._descriptor = descriptor(T),
        },
        else => null,
    };
}

/// Construct a checked reference for a known typed node. The returned pointer
/// borrows `ptr`; callers must not pass a pointer to a value that will move.
pub fn reference(ptr: anytype) NodeRef {
    const T = @TypeOf(ptr.*);
    ensureNodeType(T);
    return node(ptr).?;
}

const Frame = struct {
    pointer: *const anyopaque,
    advance: *const fn (*Frame) ?Frame,
    state: usize = 0,
    node_ref: ?NodeRef,
    parent_node: ?NodeRef,
    nearest_node: ?NodeRef,
    edge: Edge,
    language: walk.Language,
    emitted: bool = false,
    byte_length: usize,
};

fn frame(ptr: anytype, edge: Edge, parent_node: ?NodeRef, language: walk.Language) Frame {
    const T = @TypeOf(ptr.*);
    const current = node(ptr);
    return .{
        .pointer = @ptrCast(ptr),
        .advance = &Ops(T).advance,
        .node_ref = current,
        .parent_node = parent_node,
        .nearest_node = current orelse parent_node,
        .edge = edge,
        // The typed edge already supplies the context specialization. Do not
        // erase it into a second per-node language-dispatch table.
        .language = language.at(ptr),
        .byte_length = if (T == []const u8) ptr.*.len else 0,
    };
}

fn Ops(comptime T: type) type {
    return struct {
        fn value(current: *Frame) *const T {
            return @ptrCast(@alignCast(current.pointer));
        }

        fn child(current: *Frame, ptr: anytype, edge: Edge) Frame {
            return frame(ptr, edge, current.nearest_node, current.language);
        }

        fn advance(current: *Frame) ?Frame {
            const ptr = value(current);
            return switch (@typeInfo(T)) {
                .@"struct" => |info| fields: {
                    inline for (info.fields, 0..) |field_info, index| {
                        if (current.state == index) {
                            current.state += 1;
                            break :fields child(current, &@field(ptr.*, field_info.name), .{ .field = field_info.name });
                        }
                    }
                    break :fields null;
                },
                .@"union" => payload: {
                    if (current.state != 0) break :payload null;
                    current.state = 1;
                    break :payload switch (ptr.*) {
                        inline else => |*active, tag| child(current, active, .{ .payload = @tagName(tag) }),
                    };
                },
                .optional => optional: {
                    if (current.state != 0) break :optional null;
                    current.state = 1;
                    if (ptr.*) |*some| break :optional child(current, some, .dereference);
                    break :optional null;
                },
                .array => |info| array: {
                    if (current.state == info.len) break :array null;
                    const index = current.state;
                    current.state += 1;
                    break :array child(current, &ptr.*[index], .{ .index = index });
                },
                .pointer => |info| pointer: {
                    if (info.child == u8 and info.size == .slice) break :pointer null;
                    switch (info.size) {
                        .slice => {
                            if (current.state == ptr.*.len) break :pointer null;
                            const index = current.state;
                            current.state += 1;
                            break :pointer child(current, &ptr.*[index], .{ .index = index });
                        },
                        .one => {
                            if (current.state != 0) break :pointer null;
                            current.state = 1;
                            break :pointer child(current, ptr.*, .dereference);
                        },
                        .many, .c => @compileError("unbounded pointers are not a supported lexical shape: " ++ @typeName(T)),
                    }
                },
                .int, .float, .bool, .@"enum", .void => null,
                else => @compileError("unsupported lexical shape: " ++ @typeName(T)),
            };
        }
    };
}

/// A cursor owns its traversal stack. Event path/ancestor views borrow that
/// exact cursor and are valid only until its next `next` call.
pub fn Cursor(comptime Root: type) type {
    return struct {
        const Self = @This();

        pub const Event = struct {
            node: NodeRef,
            parent: ?NodeRef,
            edge: Edge,
            depth: usize,
            language: walk.Language,
            _cursor: *const Self,
            _generation: usize,

            pub fn ancestors(self: Event) Ancestors {
                return .{
                    .cursor = self._cursor,
                    .generation = self._generation,
                    .position = self._cursor.depth - 1,
                };
            }
        };

        pub const Ancestors = struct {
            cursor: *const Self,
            generation: usize,
            position: usize,

            /// Advancing the owning cursor invalidates this borrowed view.
            pub fn next(self: *Ancestors) ?NodeRef {
                std.debug.assert(self.generation == self.cursor.generation);
                while (self.position != 0) {
                    self.position -= 1;
                    if (self.cursor.frames[self.position].node_ref) |ancestor| return ancestor;
                }
                return null;
            }
        };

        frames: [frame_capacity]Frame = undefined,
        depth: usize = 1,
        work: usize = 1,
        bytes: usize = 0,
        generation: usize = 0,
        failed: ?Error = null,
        limits: Limits,

        pub fn init(root: *const Root, language: walk.Language, limits: Limits) Self {
            var result: Self = .{ .limits = limits };
            result.frames[0] = frame(root, .root, null, language);
            result.bytes = result.frames[0].byte_length;
            if (limits.max_depth == 0) result.failed = error.DepthLimit else if (limits.max_work == 0) result.failed = error.WorkLimit;
            if (result.bytes > limits.max_bytes) result.failed = error.WorkLimit;
            return result;
        }

        pub fn next(self: *Self) Error!?Event {
            if (self.failed) |failure| return failure;
            self.generation +%= 1;
            while (self.depth != 0) {
                var current = &self.frames[self.depth - 1];
                if (!current.emitted) {
                    current.emitted = true;
                    if (current.node_ref) |node_ref| return .{
                        .node = node_ref,
                        .parent = current.parent_node,
                        .edge = current.edge,
                        .depth = self.depth - 1,
                        .language = current.language,
                        ._cursor = self,
                        ._generation = self.generation,
                    };
                }
                if (current.advance(current)) |next_frame| {
                    if (self.depth >= self.frames.len or self.depth >= self.limits.max_depth) {
                        self.failed = error.DepthLimit;
                        return error.DepthLimit;
                    }
                    if (self.work >= self.limits.max_work) {
                        self.failed = error.WorkLimit;
                        return error.WorkLimit;
                    }
                    self.work += 1;
                    if (next_frame.byte_length > self.limits.max_bytes -| self.bytes) {
                        self.failed = error.WorkLimit;
                        return error.WorkLimit;
                    }
                    self.bytes += next_frame.byte_length;
                    self.frames[self.depth] = next_frame;
                    self.depth += 1;
                } else {
                    self.depth -= 1;
                }
            }
            return null;
        }
    };
}
