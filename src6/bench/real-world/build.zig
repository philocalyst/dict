const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lex6 = b.createModule(.{
        .root_source_file = b.path("../../root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lex6.addIncludePath(b.path("../../../vendor/bzip3/include"));
    lex6.addCSourceFile(.{
        .file = b.path("../../../vendor/bzip3/src/libbz3.c"),
        .flags = &.{ "-DVERSION=\"1.5.1\"", "-fno-sanitize=undefined" },
    });
    const root = b.createModule(.{
        .root_source_file = b.path("runner.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lex6", .module = lex6 }},
    });
    const executable = b.addExecutable(.{ .name = "real-lex6", .root_module = root });
    b.installArtifact(executable);
}
