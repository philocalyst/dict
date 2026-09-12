const std = @import("std");

pub fn build(b: *std.Build) void {
    const lex = b.addModule("lex6", .{
        .root_source_file = b.path("../../root.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .link_libc = true,
    });
    lex.addIncludePath(b.path("../../../vendor/bzip3/include"));
    lex.addCSourceFile(.{
        .file = b.path("../../../vendor/bzip3/src/libbz3.c"),
        .flags = &.{ "-DVERSION=\"1.5.1\"", "-fno-sanitize=undefined" },
    });

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("repro_test.zig"),
        .target = lex.resolved_target,
        .optimize = lex.optimize,
        .imports = &.{.{ .name = "lex6", .module = lex }},
    }) });
    b.step("test", "Run richness-review reproductions").dependOn(&b.addRunArtifact(tests).step);
}
