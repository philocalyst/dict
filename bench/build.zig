const std = @import("std");

const bzip3_c_flags = &[_][]const u8{
    "-std=c99",
    "-DVERSION=\"1.5.1\"",
    "-fno-sanitize=undefined",
};

fn addBzip3(module: *std.Build.Module, b: *std.Build) void {
    module.addIncludePath(b.path("../vendor/bzip3/include"));
    module.addCSourceFile(.{
        .file = b.path("../vendor/bzip3/src/libbz3.c"),
        .flags = bzip3_c_flags,
    });
    module.link_libc = true;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lexicon = b.addModule("lexicon", .{
        .root_source_file = b.path("../src/lexicon.zig"),
        .target = target,
        .optimize = optimize,
    });
    addBzip3(lexicon, b);

    const executable = b.addExecutable(.{
        .name = "lexicon-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    executable.root_module.addImport("lexicon", lexicon);
    b.installArtifact(executable);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("lexicon", lexicon);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run benchmark fixture tests");
    test_step.dependOn(&run_tests.step);
}
