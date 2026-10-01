const std = @import("std");

pub fn build(b: *std.Build) void {
    const module = b.addModule("lex6", .{
        .root_source_file = b.path("src6/root.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .link_libc = true,
    });
    module.addIncludePath(b.path("vendor/bzip3/include"));
    module.addCSourceFile(.{
        .file = b.path("vendor/bzip3/src/libbz3.c"),
        // Upstream C uses intentional arithmetic that UBSan flags. Zig code
        // retains its selected safety mode; this flag applies only to C.
        .flags = &.{ "-DVERSION=\"1.5.1\"", "-fno-sanitize=undefined" },
    });

    const unit = b.addTest(.{ .root_module = module });
    const tests = b.step("test", "Run lexical, packet and real bzip3 tests");
    tests.dependOn(&b.addRunArtifact(unit).step);
    inline for (.{
        .{ "union_child", "field projection requires a struct; switch on tagged values first" },
        .{ "union_values", "field projection requires a struct; switch on tagged values first" },
        .{ "values_bytes", "values does not enumerate UTF-8 bytes; use child for a byte-string field" },
        .{ "values_scalar", "values projection requires a slice field" },
    }) |contract| {
        const rejected = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src6/contracts/" ++ contract[0] ++ ".zig"),
            .target = module.resolved_target,
            .optimize = module.optimize,
            .imports = &.{.{ .name = "lex6", .module = module }},
        }) });
        rejected.expect_errors = .{ .contains = contract[1] };
        tests.dependOn(&rejected.step);
    }
    b.step("fmt-check", "Check LEX6 formatting")
        .dependOn(&b.addFmt(.{ .paths = &.{ "src6", "build6.zig" }, .check = true }).step);

    const example_module = b.createModule(.{
        .root_source_file = b.path("src6/example.zig"),
        .target = module.resolved_target,
        .optimize = module.optimize,
        .imports = &.{.{ .name = "lex6", .module = module }},
    });
    const example = b.addExecutable(.{ .name = "lex6-example", .root_module = example_module });
    b.step("example", "Build a dictionary, find a sense and render its definition")
        .dependOn(&b.addRunArtifact(example).step);
    b.step("test-example", "Check the independent public-API client")
        .dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = example_module })).step);
}
