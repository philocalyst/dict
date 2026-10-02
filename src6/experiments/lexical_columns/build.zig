const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lex = b.createModule(.{ .root_source_file = b.path("../../root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    lex.addIncludePath(b.path("../../../vendor/bzip3/include"));
    lex.addCSourceFile(.{ .file = b.path("../../../vendor/bzip3/src/libbz3.c"), .flags = &.{ "-DVERSION=\"1.5.1\"", "-fno-sanitize=undefined" } });
    const dag = b.createModule(.{ .root_source_file = b.path("../lexical_pages/dag.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "lex6", .module = lex }} });
    const workloads = b.createModule(.{ .root_source_file = b.path("../lexical_pages/workloads.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "lex6", .module = lex }} });
    const imports: []const std.Build.Module.Import = &.{ .{ .name = "lex6", .module = lex }, .{ .name = "dag", .module = dag }, .{ .name = "workloads", .module = workloads } };
    const bridge = b.addSystemCommand(&.{ b.graph.zig_exe, "c++", "-O2", "-std=c++17", "-fPIC", "-c" });
    bridge.addFileArg(b.path("register_bridge.cpp"));
    bridge.addArg("-o");
    const bridge_object = bridge.addOutputFileArg("lex-register.o");
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test.zig"), .target = target, .optimize = optimize, .imports = imports }) });
    tests.root_module.addObjectFile(bridge_object);
    tests.root_module.linkSystemLibrary("stdc++", .{});
    b.step("test", "Check exact native semantics, corruption budgets, allocator failures, selective lane views").dependOn(&b.addRunArtifact(tests).step);
    inline for (.{ .{ "lexical-columns", "runner.zig" }, .{ "lexical-columns-access", "access.zig" }, .{ "lexical-prefix-access", "prefix_access.zig" }, .{ "lexical-register-access", "register_access.zig" } }) |item| {
        const executable = b.addExecutable(.{ .name = item[0], .root_module = b.createModule(.{ .root_source_file = b.path(item[1]), .target = target, .optimize = optimize, .imports = imports }) });
        if (comptime std.mem.eql(u8, item[1], "register_access.zig")) {
            executable.root_module.addObjectFile(bridge_object);
            executable.root_module.linkSystemLibrary("stdc++", .{});
        }
        b.installArtifact(executable);
    }
}
