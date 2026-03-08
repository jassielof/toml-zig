const std = @import("std");

const toml = @import("toml");

test "fixtures/valid parse successfully" {
    try runFixtureDirectory("tests/fixtures/tests/valid", true);
}

test "fixtures/invalid fail to parse" {
    try runFixtureDirectory("tests/fixtures/tests/invalid", false);
}

fn runFixtureDirectory(path: []const u8, expect_valid: bool) !void {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(std.testing.allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".toml")) continue;

        const full_path = try std.fs.path.join(std.testing.allocator, &.{ path, entry.path });
        defer std.testing.allocator.free(full_path);

        const input = try std.fs.cwd().readFileAlloc(std.testing.allocator, full_path, 16 * 1024 * 1024);
        defer std.testing.allocator.free(input);

        var parser = toml.Parser.init(std.testing.allocator, input);
        const result = parser.parse();
        if (expect_valid) {
            var value = result catch |err| {
                std.debug.print("valid fixture failed: {s}\n", .{full_path});
                return err;
            };
            value.deinit(std.testing.allocator);
        } else {
            if (result) |value| {
                var parsed_value = value;
                defer parsed_value.deinit(std.testing.allocator);
                std.debug.print("invalid fixture parsed successfully: {s}\n", .{full_path});
                return error.TestUnexpectedResult;
            } else |err| {
                if (err != error.ParseFailed) return err;
            }
        }
    }
}
