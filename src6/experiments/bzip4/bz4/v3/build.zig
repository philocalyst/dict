const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bz4 = b.addModule("bz4", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });

    const tests = b.addTest(.{ .root_module = bz4 });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);

    // The measuring harness is always built fast, codec included.
    const fast = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = .ReleaseFast });
    const lab = b.addExecutable(.{
        .name = "lab",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lab.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "bz4", .module = fast }},
        }),
    });
    b.installArtifact(lab);

    const cli = b.addExecutable(.{
        .name = "bz4",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "bz4", .module = fast }},
        }),
    });
    b.installArtifact(cli);
}
