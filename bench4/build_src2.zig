const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const src2 = b.addModule("src2", .{
        .root_source_file = b.path("../src2/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    src2.addIncludePath(b.path("../vendor/bzip3/include"));
    src2.addCSourceFile(.{
        .file = b.path("../vendor/bzip3/src/libbz3.c"),
        .flags = &.{ "-std=c99", "-DVERSION=\"1.5.1\"", "-fno-sanitize=undefined" },
    });
    src2.link_libc = true;
    const exe = b.addExecutable(.{
        .name = "src2-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src2_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "src2", .module = src2 }},
        }),
    });
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src2_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "src2", .module = src2 }},
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run actual-src2 adapter tests");
    test_step.dependOn(&run_tests.step);
}
