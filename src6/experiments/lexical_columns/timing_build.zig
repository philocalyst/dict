const std = @import("std");

/// Independent runtime instrumentation. All codec/model/reader imports remain
/// the files covered by the original source freeze.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lex = b.createModule(.{ .root_source_file = b.path("../../root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    lex.addIncludePath(b.path("../../../vendor/bzip3/include"));
    lex.addCSourceFile(.{ .file = b.path("../../../vendor/bzip3/src/libbz3.c"), .flags = &.{ "-DVERSION=\"1.5.1\"", "-fno-sanitize=undefined" } });
    const dag = b.createModule(.{ .root_source_file = b.path("../lexical_pages/dag.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "lex6", .module = lex }} });
    const executable = b.addExecutable(.{
        .name = "lexical-register-order-access",
        .root_module = b.createModule(.{
            .root_source_file = b.path("timing_access.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "lex6", .module = lex }, .{ .name = "dag", .module = dag } },
        }),
    });
    const bridge = b.addSystemCommand(&.{ b.graph.zig_exe, "c++", "-O2", "-std=c++17", "-fPIC", "-c" });
    bridge.addFileArg(b.path("register_bridge.cpp"));
    bridge.addArg("-o");
    executable.root_module.addObjectFile(bridge.addOutputFileArg("lex-register.o"));
    executable.root_module.linkSystemLibrary("stdc++", .{});
    b.installArtifact(executable);
}
