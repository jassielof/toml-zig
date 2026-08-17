const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const toml_mod = b.addModule("toml", .{
        .root_source_file = b.path("lib/toml/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cli_step = b.step("cli", "Run the CLI");

    const decoder_exe = b.addExecutable(.{
        .name = "toml-test-decoder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/toml-test-decode.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_mod },
            },
        }),
    });

    b.installArtifact(decoder_exe);

    const encoder_exe = b.addExecutable(.{
        .name = "toml-test-encoder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/toml-test-encoder.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_mod },
            },
        }),
    });

    b.installArtifact(encoder_exe);

    const run_decoder = b.addRunArtifact(decoder_exe);

    cli_step.dependOn(&run_decoder.step);

    if (b.args) |args| run_decoder.addArgs(args);

    const docs_step = b.step("docs", "Generate the documentation");

    const toml_lib = b.addLibrary(.{
        .name = "toml",
        .root_module = toml_mod,
    });

    const toml_docs = b.addInstallDirectory(.{
        .source_dir = toml_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    docs_step.dependOn(&toml_docs.step);

    const tests_step = b.step("test", "Run the test suite");

    const toml_spec_tests = b.addTest(.{
        .name = "Specification Conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/spec.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "toml",
                .module = toml_mod,
            }},
        }),
    });

    const run_integration_tests = b.addRunArtifact(toml_spec_tests);
    run_integration_tests.step.dependOn(b.getInstallStep());
    tests_step.dependOn(&run_integration_tests.step);

    const toml_tests = b.addTest(.{
        .name = "TOML",
        .root_module = toml_mod,
    });

    tests_step.dependOn(&b.addRunArtifact(toml_tests).step);

    const check_step = b.step("check", "Run code quality checks");

    const fmt = b.addFmt(.{
        .check = true,
        .paths = &.{"lib/"},
    });
    check_step.dependOn(&fmt.step);
}
