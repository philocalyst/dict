const model = @import("model.zig");
const stored = @import("stored.zig");
const strings = @import("strings.zig");
const topology = @import("topology.zig");

pub const External = stored.Type(model.ExternalReference);
pub const Target = union(enum) {
    record: model.AnyRef,
    occurrence: model.OccurrenceId,
    span: model.SourceEventSpan,
    value: model.ValueId,
    fact: model.FactId,
    external: External,
};

pub fn lower(pool: *strings.Builder, source: *const topology.Owned, documents: []const model.DocumentInput, input: model.TargetInput) (strings.Error || topology.Error)!Target {
    return switch (input) {
        .record => |record| .{ .record = record },
        .occurrence => |occurrence| .{ .occurrence = try source.resolve(occurrence) },
        .span => |span| value: {
            const resolved = try source.resolveAnchor(documents, .{ .span = span });
            break :value .{ .span = resolved.span };
        },
        .value => |value| .{ .value = value },
        .fact => |fact| .{ .fact = fact },
        .external => |external| .{ .external = try stored.lower(pool, external) },
    };
}

pub fn validate(target: Target, source: anytype, declarations: anytype) !void {
    switch (target) {
        .occurrence => |occurrence| try source.validateHandle(.{ .occurrence = occurrence }),
        .span => |span| try source.validateHandle(.{ .span = span }),
        .external => |external| try declarations.validateExternal(external),
        .record, .value, .fact => {},
    }
}
