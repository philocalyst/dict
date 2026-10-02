const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lex = b.createModule(.{ .root_source_file = b.path("../../root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    lex.addIncludePath(b.path("../../../vendor/bzip3/include"));
    lex.addCSourceFile(.{ .file = b.path("../../../vendor/bzip3/src/libbz3.c"), .flags = &.{ "-DVERSION=\"1.5.1\"", "-fno-sanitize=undefined" } });
    const module = b.createModule(.{ .root_source_file = b.path("dag_test.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "lex6", .module = lex }} });
    b.step("test", "Test exact typed lexical DAG pages").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    const test_shape = b.step("test-shape", "Test typed construction shapes and literal field access");
    inline for (.{ "shape_test.zig", "shape_view_test.zig" }) |source| {
        const extra = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path(source), .target = target, .optimize = optimize, .imports = &.{.{ .name = "lex6", .module = lex }} }) });
        test_shape.dependOn(&b.addRunArtifact(extra).step);
    }
    const runner = b.addExecutable(.{ .name = "lexical-pages", .root_module = b.createModule(.{ .root_source_file = b.path("runner.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "lex6", .module = lex }} }) });
    b.installArtifact(runner);
    const run = b.addRunArtifact(runner);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Compare complete flat and shared lexical pages").dependOn(&run.step);
}
