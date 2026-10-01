const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bz4v2 = b.addModule("bz4v2", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // `zig build test` (run it again with `-Doptimize=ReleaseSafe` for the
    // other required mode).
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the pkg test suite");
    test_step.dependOn(&run_tests.step);

    // `zig build bench -- FILE BLOCK` (and the ablation/C-sweep flags --
    // see bench.zig's own usage banner).
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bench_exe.root_module.addImport("bz4v2", bz4v2);
    b.installArtifact(bench_exe);
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run the measurement harness: zig build bench -- FILE BLOCK");
    bench_step.dependOn(&run_bench.step);

    // `zig build cli -- ...`
    const cli_exe = b.addExecutable(.{
        .name = "bz4v2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    cli_exe.root_module.addImport("bz4v2", bz4v2);
    b.installArtifact(cli_exe);
    const run_cli = b.addRunArtifact(cli_exe);
    run_cli.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cli.addArgs(args);
    const cli_step = b.step("cli", "Run the CLI: zig build cli -- compress|decompress IN OUT");
    cli_step.dependOn(&run_cli.step);
}
