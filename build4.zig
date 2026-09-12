const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const src4 = b.addModule("src4", .{
        .root_source_file = b.path("src4/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const bench = b.addExecutable(.{ .name = "lex4-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("bench4/bench_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "src4", .module = src4 }},
    }) });
    const install_bench = b.addInstallArtifact(bench, .{});
    const bench_step = b.step("bench4", "Build the native LEX4 benchmark protocol executable");
    bench_step.dependOn(&install_bench.step);

    const unit = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src4/root.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const tests = b.step("test", "Run the complete LEX4 test surface");
    tests.dependOn(&b.addRunArtifact(unit).step);
    for ([_][]const u8{
        "src4/automaton_test.zig",
        "src4/rank_test.zig",
        "src4/forest_test.zig",
        "src4/bitvector_test.zig",
        "src4/entropy_test.zig",
        "src4/grammar_test.zig",
        "src4/compiler_test.zig",
        "src4/grammar_adversarial_test.zig",
        "src4/axes_test.zig",
        "src4/search_product.zig",
        "src4/terms_test.zig",
        "src4/concepts_test.zig",
        "src4/relations_test.zig",
        "src4/snapshot_test.zig",
        "src4/snapshot_compiler_test.zig",
        "src4/snapshot_optional_test.zig",
        "src4/text_index.zig",
        "src4/cold.zig",
    }) |path| {
        const focused = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }) });
        tests.dependOn(&b.addRunArtifact(focused).step);
    }

    const fmt = b.step("fmt-check", "Check canonical formatting for LEX4");
    const fmt_command = b.addSystemCommand(&.{
        "sh",                                                                                                "-c",
        "set -eu\nzig fmt --check build4.zig\nfind src4 -type f -name '*.zig' -exec zig fmt --check {} +\n",
    });
    fmt.dependOn(&fmt_command.step);

    const lines = b.step("lines", "Report LEX4 production and test lines");
    const line_command = b.addSystemCommand(&.{
        "sh",                                                                                                                                                                                                                                                                                                                                                                        "-c",
        "set -eu\nproduction=$(find src4 -type f -name '*.zig' ! -name '*_test.zig' -exec awk 'END { print NR }' {} + | awk '{ n += $1 } END { print n + 0 }')\ntests=$(find src4 -type f -name '*_test.zig' -exec awk 'END { print NR }' {} + | awk '{ n += $1 } END { print n + 0 }')\nprintf 'src4 production lines: %s; focused test lines: %s\n' \"$production\" \"$tests\"\n",
    });
    lines.dependOn(&line_command.step);
}
