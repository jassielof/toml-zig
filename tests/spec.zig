const std = @import("std");
const builtin = @import("builtin");

test "toml-test compliance runner" {
    const allocator = std.testing.allocator;

    const toml_test_bin = try findTomlTest(allocator);
    defer allocator.free(toml_test_bin);

    const exe_ext = if (builtin.os.tag == .windows) ".exe" else "";
    const decoder_path = try std.fmt.allocPrint(allocator, "zig-out/bin/toml-test-decoder{s}", .{exe_ext});
    defer allocator.free(decoder_path);

    const encoder_path = try std.fmt.allocPrint(allocator, "zig-out/bin/toml-test-encoder{s}", .{exe_ext});
    defer allocator.free(encoder_path);

    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{
            toml_test_bin,
            "test",
            "-decoder",
            decoder_path,
            "-encoder",
            encoder_path,
            "-color",
            "never",
            "-parallel",
            "1",
            "-skip",
            "invalid/datetime/no-secs,invalid/inline-table/linebreak-01,invalid/inline-table/linebreak-02,invalid/inline-table/linebreak-03,invalid/inline-table/linebreak-04,invalid/inline-table/trailing-comma,invalid/local-datetime/no-secs,invalid/local-time/no-secs,invalid/string/basic-byte-escapes",
        },
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("toml-test failed with exit code: {d}\n", .{code});
                std.debug.print("Stdout:\n{s}\n", .{result.stdout});
                std.debug.print("Stderr:\n{s}\n", .{result.stderr});
                return error.TestFailed;
            }
        },
        else => |term| {
            std.debug.print("toml-test terminated abnormally: {}\n", .{term});
            std.debug.print("Stdout:\n{s}\n", .{result.stdout});
            std.debug.print("Stderr:\n{s}\n", .{result.stderr});
            return error.TestFailed;
        },
    }
}

fn findTomlTest(allocator: std.mem.Allocator) ![]const u8 {
    // 1. Try running "toml-test" directly to see if it is already in PATH.
    const result = std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "toml-test", "-version" },
    }) catch |err| switch (err) {
        error.FileNotFound => {
            // 2. Not in PATH, search default Go install directories
            return findInGoPath(allocator) orelse {
                std.debug.print(
                    \\
                    \\========================================================================
                    \\Error: 'toml-test' compliance runner binary was not found.
                    \\Please install it by running:
                    \\  go install github.com/toml-lang/toml-test/v2/cmd/toml-test@latest
                    \\
                    \\Ensure that your Go bin directory is in your PATH, or that Go is installed.
                    \\========================================================================
                    \\
                    , .{}
                );
                return error.TomlTestNotFound;
            };
        },
        else => return err,
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    return try allocator.dupe(u8, "toml-test");
}

fn findInGoPath(allocator: std.mem.Allocator) ?[]const u8 {
    const os_tag = builtin.os.tag;
    const bin_name = if (os_tag == .windows) "toml-test.exe" else "toml-test";

    // Check $GOPATH/bin
    if (std.process.getEnvVarOwned(allocator, "GOPATH")) |gopath| {
        defer allocator.free(gopath);
        const path = std.fs.path.join(allocator, &.{ gopath, "bin", bin_name }) catch return null;
        if (isExecutable(path)) return path;
        allocator.free(path);
    } else |_| {}

    // Check $HOME/go/bin or %USERPROFILE%\go\bin
    const home_var = if (os_tag == .windows) "USERPROFILE" else "HOME";
    if (std.process.getEnvVarOwned(allocator, home_var)) |home| {
        defer allocator.free(home);
        const path = std.fs.path.join(allocator, &.{ home, "go", "bin", bin_name }) catch return null;
        if (isExecutable(path)) return path;
        allocator.free(path);
    } else |_| {}

    return null;
}

fn isExecutable(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}
