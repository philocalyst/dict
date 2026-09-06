const std = @import("std");

const bzip3_c_flags = &[_][]const u8{
    "-std=c99",
    "-DVERSION=\"1.5.1\"",
    // The pinned upstream libsais implementation intentionally uses signed
    // suffix-array words as packed markers and performs arithmetic that its
    // own fuzz builds treat as implementation-defined. Zig Debug enables C
    // undefined-behavior instrumentation; keep it for our Zig code while
    // leaving this unchanged upstream translation unit at its documented C
    // semantics.
    "-fno-sanitize=undefined",
};

fn addBzip3(module: *std.Build.Module, b: *std.Build) void {
    // libbz3.c is the only upstream translation unit needed for independent
    // blocks.  libsais is intentionally header-only in this pinned release;
    // no command-line tools or pthread entry points are linked.
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

    const lib = b.addModule("lexicon", .{
        .root_source_file = b.path("src/lexicon.zig"),
        .target = target,
        .optimize = optimize,
    });
    addBzip3(lib, b);

    const exe = b.addExecutable(.{
        .name = "lex",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("lexicon", lib);
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lexicon.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addBzip3(tests.root_module, b);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Lexicon tests");
    test_step.dependOn(&run_tests.step);
}
