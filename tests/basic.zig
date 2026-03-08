const std = @import("std");
const toml = @import("toml");

test "parse" {
    const Config = struct {
        title: []const u8,
        enabled: bool,
        retries: []u16,
        owner: struct {
            name: []const u8,
        },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try toml.parse(Config, arena.allocator(),
        \\title = "demo"
        \\enabled = true
        \\retries = [1, 2, 3]
        \\[owner]
        \\name = "alice"
    );

    try std.testing.expectEqualStrings("demo", config.title);
    try std.testing.expect(config.enabled);
    try std.testing.expectEqual(@as(usize, 3), config.retries.len);
    try std.testing.expectEqualStrings("alice", config.owner.name);
}

test "stringify" {
    const Config = struct {
        title: []const u8,
        owner: struct {
            name: []const u8,
        },
    };

    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buffer.deinit(std.testing.allocator);

    try toml.stringify(Config{
        .title = "demo",
        .owner = .{ .name = "alice" },
    }, buffer.writer(std.testing.allocator));

    const rendered = buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, rendered, "title = \"demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[owner]") != null);
}

test "formatDiagnostic" {
    const input =
        \\name = "ok"
        \\broken = [1,,2]
    ;
    var parser = toml.Parser.init(std.testing.allocator, input);
    try std.testing.expectError(error.ParseFailed, parser.parse());
    try std.testing.expect(parser.diagnostic() != null);
}
