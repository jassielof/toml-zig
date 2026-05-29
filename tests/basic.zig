const std = @import("std");
const toml = @import("toml");

const Config = struct {
    title: []const u8,
    enabled: bool,
    retries: []const usize,
    owner: struct {
        name: []const u8,
    },
};

test "parse" {
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
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    try toml.stringify(Config{
        .title = "demo",
        .enabled = true,
        .retries = &.{ 1, 2, 3 },
        .owner = .{ .name = "alice" },
    }, &aw.writer);

    const rendered = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "title = \"demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "enabled = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "retries = [1, 2, 3]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[owner]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "name = \"alice\"") != null);
}

test "dynamic parse" {
    const input =
        \\title = "demo"
        \\enabled = true
        \\retries = [1, 2, 3]
        \\[owner]
        \\name = "alice"
    ;
    var parsed = try toml.parseValue(std.testing.allocator, input);
    defer parsed.deinit(std.testing.allocator);

    const table = parsed.table;
    try std.testing.expectEqualStrings("demo", table.get("title").?.string.bytes);
    try std.testing.expect(table.get("enabled").?.boolean);
    try std.testing.expectEqual(@as(i64, 1), table.get("retries").?.array.items.items[0].integer);
    try std.testing.expectEqualStrings("alice", table.get("owner").?.table.get("name").?.string.bytes);
}

test "dynamic stringify" {
    var table = try toml.Table.create(std.testing.allocator);
    defer {
        var root = toml.DynamicValue{ .table = table };
        root.deinit(std.testing.allocator);
    }

    try table.putOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, "title"), .{
        .string = .{ .bytes = try std.testing.allocator.dupe(u8, "demo"), .allocated = true },
    });
    try table.putOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, "enabled"), .{
        .boolean = true,
    });

    var owner_table = try toml.Table.create(std.testing.allocator);
    try owner_table.putOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, "name"), .{
        .string = .{ .bytes = try std.testing.allocator.dupe(u8, "alice"), .allocated = true },
    });
    try table.putOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, "owner"), .{
        .table = owner_table,
    });

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    const root_val = toml.DynamicValue{ .table = table };
    try toml.stringify(root_val, &aw.writer);

    const rendered = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "title = \"demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[owner]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "name = \"alice\"") != null);
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
