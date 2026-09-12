const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("src5", .{
        .root_source_file = b.path("src5/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = module;
    const unit = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src5/root.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const tests = b.step("test", "Run LEX5 tests");
    tests.dependOn(&b.addRunArtifact(unit).step);

    const fmt = b.step("fmt-check", "Check LEX5 formatting");
    fmt.dependOn(&b.addFmt(.{ .paths = &.{ "src5", "build5.zig" }, .check = true }).step);
}
