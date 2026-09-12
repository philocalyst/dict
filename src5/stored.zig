const std = @import("std");
const model = @import("model.zig");

fn isString(comptime T: type) bool {
    return T == []const u8;
}

pub fn Type(comptime T: type) type {
    @setEvalBranchQuota(100_000);
    if (isString(T)) return model.StringId;
    return switch (@typeInfo(T)) {
        .int, .bool, .@"enum", .void => T,
        .array => |info| if (Type(info.child) == info.child) T else [info.len]Type(info.child),
        .optional => |info| if (Type(info.child) == info.child) T else ?Type(info.child),
        .@"struct" => |info| result: {
            var names: [info.fields.len][]const u8 = undefined;
            var types: [info.fields.len]type = undefined;
            var attributes: [info.fields.len]std.builtin.Type.StructField.Attributes = undefined;
            var changed = false;
            inline for (info.fields, 0..) |field, index| {
                names[index] = field.name;
                types[index] = Type(field.type);
                changed = changed or types[index] != field.type;
                attributes[index] = .{};
            }
            if (!changed) break :result T;
            break :result @Struct(info.layout, null, &names, &types, &attributes);
        },
        .@"union" => |info| result: {
            const Tag = info.tag_type orelse @compileError("Stored requires a tagged union");
            var names: [info.fields.len][]const u8 = undefined;
            var types: [info.fields.len]type = undefined;
            var attributes: [info.fields.len]std.builtin.Type.UnionField.Attributes = undefined;
            var changed = false;
            inline for (info.fields, 0..) |field, index| {
                names[index] = field.name;
                types[index] = Type(field.type);
                changed = changed or types[index] != field.type;
                attributes[index] = .{};
            }
            if (!changed) break :result T;
            break :result @Union(info.layout, Tag, &names, &types, &attributes);
        },
        else => @compileError("unsupported Stored input: " ++ @typeName(T)),
    };
}

pub fn lower(interner: anytype, value: anytype) !Type(@TypeOf(value)) {
    @setEvalBranchQuota(100_000);
    const T = @TypeOf(value);
    if (comptime isString(T)) return interner.intern(value);
    if (comptime Type(T) == T) return value;
    return switch (@typeInfo(T)) {
        .int, .bool, .@"enum", .void => value,
        .array => |info| result: {
            var output: Type(T) = undefined;
            for (value, 0..) |item, index| output[index] = try lower(interner, @as(info.child, item));
            break :result output;
        },
        .optional => if (value) |payload| try lower(interner, payload) else null,
        .@"struct" => |info| result: {
            var output: Type(T) = undefined;
            inline for (info.fields) |field| @field(output, field.name) = try lower(interner, @field(value, field.name));
            break :result output;
        },
        .@"union" => switch (value) {
            inline else => |payload, tag| @unionInit(Type(T), @tagName(tag), try lower(interner, payload)),
        },
        else => unreachable,
    };
}

test "stored lowering interns strings through nested products and sums" {
    const strings = @import("strings.zig");
    const Input = struct { name: []const u8, value: ?union(enum) { number: i16, text: []const u8 } };
    var pool = strings.Builder.init(std.testing.allocator);
    defer pool.deinit();
    const output = try lower(&pool, Input{ .name = "n", .value = .{ .text = "v" } });
    try std.testing.expectEqual(@as(usize, 2), pool.values.items.len);
    try std.testing.expect(std.meta.activeTag(output.value.?) == .text);
}

test "stored lowering preserves unchanged nominal reference shapes" {
    const Unchanged = struct { reference: model.AnyRef, optional: ?model.Ref(.sense), many: [2]model.ValueId };
    const Mixed = struct { name: []const u8, reference: model.AnyRef };
    try std.testing.expect(Type(model.AnyRef) == model.AnyRef);
    try std.testing.expect(Type(Unchanged) == Unchanged);
    try std.testing.expect(@FieldType(Type(Mixed), "reference") == model.AnyRef);
    try std.testing.expect(@FieldType(Type(Mixed), "name") == model.StringId);
}
