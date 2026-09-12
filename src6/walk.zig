//! One bounded traversal for ordered lexical and inline content. The node type
//! supplies children and a language declaration; consumers own all semantics.
const std = @import("std");
const model = @import("model.zig");

pub const Scope = enum { children, descendants };
pub const Error = error{DepthLimit};
pub const max_depth = 128;

/// Retaining the declaration distinguishes explicit reset from absent context.
/// Both pointers and slices borrow the admitted document for their lifetime.
pub const Language = struct {
    value: ?[]const u8 = null,
    declaration: ?*const model.Language = null,

    pub fn resolve(parent: Language, declaration: *const model.Language) Language {
        return switch (declaration.*) {
            .inherit => parent,
            .reset => .{ .declaration = declaration },
            .tag => |tag| .{ .value = tag, .declaration = declaration },
        };
    }

    /// Field projection and tree traversal enter the same lexical context.
    /// Tagged nodes expose their active declaration; ordinary values use meta.
    pub fn at(parent: Language, value: anytype) Language {
        const T = @TypeOf(value.*);
        const declaration = if (comptime std.meta.hasFn(T, "declaredLanguage"))
            value.declaredLanguage()
        else if (comptime @typeInfo(T) == .@"struct" and @hasField(T, "meta"))
            &value.meta.language
        else
            return parent;
        return resolve(parent, declaration);
    }
};

pub const Options = struct {
    scope: Scope = .descendants,
    leave_events: bool = false,
};

/// Specialization is deliberately narrow: no callback graph, erased payload,
/// or heap-owned iterator. A frame is a borrowed sibling slice and its context.
pub fn Cursor(comptime Node: type) type {
    return struct {
        const Self = @This();
        const Frame = struct {
            remaining: []const Node,
            owner: ?*const Node = null,
            language: Language,
        };
        pub const Event = struct {
            node: *const Node,
            phase: enum { enter, leave } = .enter,
            language: Language,
        };

        frames: [max_depth]Frame = undefined,
        depth: usize = 1,
        pending_leave: ?Event = null,
        failed: bool = false,
        options: Options,

        pub fn init(nodes: []const Node, language: Language, options: Options) Self {
            var result: Self = .{ .options = options };
            result.frames[0] = .{ .remaining = nodes, .language = language };
            return result;
        }

        pub fn next(self: *Self) Error!?Event {
            if (self.failed) return error.DepthLimit;
            if (self.pending_leave) |event| {
                self.pending_leave = null;
                return event;
            }
            while (self.depth != 0) {
                const frame = &self.frames[self.depth - 1];
                if (frame.remaining.len == 0) {
                    self.depth -= 1;
                    if (self.options.leave_events) {
                        if (frame.owner) |owner|
                            return .{ .node = owner, .phase = .leave, .language = frame.language };
                    }
                    continue;
                }
                const node = &frame.remaining[0];
                const language = frame.language.at(node);
                const children = node.children();
                const descend = self.options.scope == .descendants and children.len != 0;
                if (descend and self.depth == self.frames.len) {
                    self.failed = true;
                    return error.DepthLimit;
                }
                frame.remaining = frame.remaining[1..];
                if (descend) {
                    self.frames[self.depth] = .{ .remaining = children, .owner = node, .language = language };
                    self.depth += 1;
                } else if (self.options.leave_events) {
                    self.pending_leave = .{ .node = node, .phase = .leave, .language = language };
                }
                return .{ .node = node, .language = language };
            }
            return null;
        }
    };
}
