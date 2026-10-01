const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const portable_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("codec.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const bwt_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("bwt_codec.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const audit_module = b.createModule(.{
        .root_source_file = b.path("audit_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    audit_module.addImport("candidate", bwt_tests.root_module);
    const audit_tests = b.addTest(.{ .root_module = audit_module });
    const tests = b.step("test", "Run the pure Zig codec tests");
    tests.dependOn(&b.addRunArtifact(portable_tests).step);
    tests.dependOn(&b.addRunArtifact(bwt_tests).step);
    tests.dependOn(&b.addRunArtifact(audit_tests).step);

    const wasm_tests = b.addObject(.{ .name = "bzip4-portable-wasm", .root_module = b.createModule(.{
        .root_source_file = b.path("portable_check.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = optimize,
    }) });
    const linux_tests = b.addObject(.{ .name = "bzip4-portable-linux", .root_module = b.createModule(.{
        .root_source_file = b.path("portable_check.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu }),
        .optimize = optimize,
    }) });
    const portable_compile = b.step("portable-compile", "Compile pure Zig tests for wasm32-freestanding and x86_64-linux");
    portable_compile.dependOn(&wasm_tests.step);
    portable_compile.dependOn(&linux_tests.step);

    const bzip3_module = b.createModule(.{
        .root_source_file = b.path("../../compression.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bzip3_module.addIncludePath(b.path("../../../vendor/bzip3/include"));

    const runner_module = b.createModule(.{
        .root_source_file = b.path("runner.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "production_bzip3", .module = bzip3_module }},
    });
    runner_module.addIncludePath(b.path("../../../vendor/bzip3/include"));
    runner_module.addCSourceFile(.{
        .file = b.path("../../../vendor/bzip3/src/libbz3.c"),
        .flags = &.{ "-std=c99", "-DVERSION=\"1.5.1\"", "-fno-sanitize=undefined" },
    });
    const runner = b.addExecutable(.{ .name = "bzip4-experiment", .root_module = runner_module });
    b.installArtifact(runner);
    const run = b.addRunArtifact(runner);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run a smoke or explicitly gated measurement").dependOn(&run.step);
}
