const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("toml", .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const docs_step = b.step("docs", "Generate the documentation");

    const docs_lib = b.addLibrary(.{
        .name = "toml",
        .root_module = lib_mod,
    });

    const docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    docs_step.dependOn(&docs.step);

    const tests_step = b.step("tests", "Run the test suite");

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/suite.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "toml",
                    .module = lib_mod,
                },
            },
        }),
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);
    tests_step.dependOn(&run_integration_tests.step);

    const unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    tests_step.dependOn(&run_unit_tests.step);
}
