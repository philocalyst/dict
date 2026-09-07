const std = @import("std");

const production_limit: usize = 3_000;
const bzip3_c_flags = &[_][]const u8{
    "-std=c99",
    "-DVERSION=\"1.5.1\"",
    "-fno-sanitize=undefined",
};

fn addBzip3(module: *std.Build.Module, b: *std.Build) void {
    module.addIncludePath(b.path("vendor/bzip3/include"));
    module.addCSourceFile(.{
        .file = b.path("vendor/bzip3/src/libbz3.c"),
        .flags = bzip3_c_flags,
    });
    module.link_libc = true;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const api = b.addModule("src2", .{
        .root_source_file = b.path("src2/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    addBzip3(api, b);

    const unit = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src2/root.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    addBzip3(unit.root_module, b);
    const integration = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src2/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    integration.root_module.addImport("src2", api);
    const benchmark_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("bench2.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    addBzip3(benchmark_tests.root_module, b);

    const tests = b.step("test", "Run src2 unit and integration tests");
    tests.dependOn(&b.addRunArtifact(unit).step);
    tests.dependOn(&b.addRunArtifact(integration).step);
    tests.dependOn(&b.addRunArtifact(benchmark_tests).step);
    for ([_][]const u8{
        "src2/bits_test.zig",
        "src2/forest_test.zig",
        "src2/keys_test.zig",
        "src2/prose_test.zig",
        "src2/snapshot_test.zig",
        "src2/query_test.zig",
        "src2/compile_test.zig",
        "src2/adversarial_test.zig",
    }) |path| {
        const focused = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }) });
        addBzip3(focused.root_module, b);
        tests.dependOn(&b.addRunArtifact(focused).step);
    }

    const bench = b.addExecutable(.{
        .name = "bench2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench2.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addBzip3(bench.root_module, b);
    b.installArtifact(bench);
    const run_bench = b.addRunArtifact(bench);
    run_bench.addArgs(b.args orelse &.{});
    const bench_step = b.step("bench", "Run the src2 fixture benchmark");
    bench_step.dependOn(&run_bench.step);

    const budget = b.step("line-budget", "Report the src2 production line count");
    const budget_cmd = b.addSystemCommand(&.{ "sh", "-c", line_budget_script });
    budget.dependOn(&budget_cmd.step);

    const fmt = b.step("fmt-check", "Check canonical Zig formatting for the complete Zig surface");
    const fmt_script = "set -eu\nzig fmt --check build2.zig bench2.zig\nfind src2 -type f -name '*.zig' -exec zig fmt --check {} +\n";
    const fmt_cmd = b.addSystemCommand(&.{ "sh", "-c", fmt_script });
    fmt.dependOn(&fmt_cmd.step);
}

const line_budget_script = "set -eu\n" ++
    "lines=$(find src2 -type f -name '*.zig' ! -name '*_test.zig' ! -name 'integration_test.zig' -exec awk 'END { print NR }' {} + | awk '{ total += $1 } END { print total + 0 }')\n" ++
    "printf 'src2 production lines: %s (informational limit %s)\\n' \"$lines\" \"" ++
    std.fmt.comptimePrint("{}", .{production_limit}) ++ "\"\n";
