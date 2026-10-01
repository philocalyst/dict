//! Public exact construction access. Semantic admission executes local programs
//! before this function returns their proven authoritative surface bytes.
const std = @import("std");
const model = @import("model.zig");
const core = @import("construction.zig");
const validate = @import("validate.zig");
const query = @import("query.zig");
const nodes = @import("nodes.zig");
const walk = @import("walk.zig");

pub const Limits = core.Limits;
pub const Error = validate.Error || nodes.Error || walk.Error || error{UnverifiedConstruction};

/// Returns owned, exact bytes for one identified, locally executable
/// occurrence. The entry is fully admitted first; that admission executes and
/// compares every local construction with its authoritative Representation.
/// Unavailable external programs/calls remain inspectable Item data and return
/// a distinct error until a library catalog can verify their execution.
/// External labels on supplied surface bytes do not prevent local execution.
pub fn realize(allocator: std.mem.Allocator, entry: *const model.Entry, occurrence_id: []const u8, scope: validate.Scope) Error![]u8 {
    try validate.check(allocator, entry, scope);
    const located = (try query.resolve(entry, occurrence_id)) orelse return error.InvalidProgram;
    const occurrence = located.as(model.Construction) orelse return error.InvalidProgram;
    if (occurrence.proof != .exact_local) return error.UnverifiedConstruction;
    const target_id = switch (occurrence.authoritative) {
        .local => |id| id,
        else => return error.InvalidSurfaceReference,
    };
    const target_location = (try query.resolve(entry, target_id)) orelse return error.InvalidSurfaceReference;
    const target = target_location.as(model.Representation) orelse return error.InvalidSurfaceReference;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var cursor = walk.Cursor(model.Inline).init(target.text.content, .{}, .{});
    while (try cursor.next()) |event| {
        if (event.node.* != .text) continue;
        const bytes = event.node.text;
        if (bytes.len > scope.construction.max_output_bytes - result.items.len)
            return error.ConstructionOutputLimit;
        try result.appendSlice(allocator, bytes);
    }
    return result.toOwnedSlice(allocator);
}
