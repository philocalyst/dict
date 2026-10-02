const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Historical LPB-v3 screens must explicitly pin their native root.zig.
    // The portable default follows the repository's current native contract.
    const lexical_core = b.option([]const u8, "lexical-core", "Absolute native root.zig matching the source packet contract");
    const lex = b.createModule(.{ .root_source_file = if (lexical_core) |path| .{ .cwd_relative = path } else b.path("../../root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    lex.addIncludePath(b.path("../../../vendor/bzip3/include"));
    lex.addCSourceFile(.{ .file = b.path("../../../vendor/bzip3/src/libbz3.c"), .flags = &.{ "-DVERSION=\"1.5.1\"", "-fno-sanitize=undefined" } });
    const dag = b.createModule(.{ .root_source_file = b.path("../lexical_pages/dag.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "lex6", .module = lex }} });
    const workloads = b.createModule(.{ .root_source_file = b.path("../lexical_pages/workloads.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "lex6", .module = lex }} });
    const imports: []const std.Build.Module.Import = &.{ .{ .name = "lex6", .module = lex }, .{ .name = "dag", .module = dag }, .{ .name = "workloads", .module = workloads } };
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test.zig"), .target = target, .optimize = optimize, .imports = imports }) });
    b.step("test", "Exact native fields and bounded semantic/entropy constructions").dependOn(&b.addRunArtifact(tests).step);
    const runner = b.addExecutable(.{ .name = "lexical-constructions", .root_module = b.createModule(.{ .root_source_file = b.path("runner.zig"), .target = target, .optimize = optimize, .imports = imports }) });
    b.installArtifact(runner);
    const shared = b.addExecutable(.{ .name = "lexical-shared-constructions", .root_module = b.createModule(.{ .root_source_file = b.path("global_runner.zig"), .target = target, .optimize = optimize, .imports = imports }) });
    b.installArtifact(shared);
}
