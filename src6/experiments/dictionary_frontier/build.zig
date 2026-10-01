const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const external = b.option([]const u8, "lex-root", "Absolute module root for a frozen comparison source");
    const vendor = b.option([]const u8, "vendor-root", "Absolute pinned bzip3 source directory");
    const lib = b.createModule(.{
        .root_source_file = if (external) |path| .{ .cwd_relative = path } else b.path("../../root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const includes: std.Build.LazyPath = if (vendor) |path|
        .{ .cwd_relative = b.pathJoin(&.{ path, "include" }) }
    else
        b.path("../../../vendor/bzip3/include");
    const source: std.Build.LazyPath = if (vendor) |path|
        .{ .cwd_relative = b.pathJoin(&.{ path, "src/libbz3.c" }) }
    else
        b.path("../../../vendor/bzip3/src/libbz3.c");
    lib.addIncludePath(includes);
    lib.addCSourceFile(.{ .file = source, .flags = &.{ "-DVERSION=\"1.5.1\"", "-fno-sanitize=undefined" } });
    const executable = b.addExecutable(.{
        .name = "dictionary-frontier",
        .root_module = b.createModule(.{
            .root_source_file = b.path("links.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lex6", .module = lib }},
        }),
    });
    b.installArtifact(executable);
    const projection = b.addExecutable(.{
        .name = "dictionary-projection",
        .root_module = b.createModule(.{
            .root_source_file = b.path("projection.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lex6", .module = lib }},
        }),
    });
    b.installArtifact(projection);
    const run = b.addRunArtifact(executable);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Measure the fully admitted rich lexical fixture").dependOn(&run.step);
    const project = b.addRunArtifact(projection);
    if (b.args) |args| project.addArgs(args);
    b.step("run-projection", "Measure native and prepared natural-text projection").dependOn(&project.step);
}
