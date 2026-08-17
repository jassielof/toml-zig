const std = @import("std");

pub const Deserializer = @import("Deserializer.zig");
pub const parse = Deserializer.parse;
pub const Error = @import("Error.zig");
pub const Diagnostic = Error.Diagnostic;
pub const ErrorKind = Error.ErrorKind;
pub const TomlError = Error.TomlError;
pub const formatDiagnostic = Error.formatDiagnostic;
pub const Parser = @import("Parser.zig");
pub const Serializer = @import("Serializer.zig");
pub const stringify = Serializer.stringify;
pub const Value = @import("Value.zig");
pub const Date = Value.Date;
pub const Time = Value.Time;
pub const DateTime = Value.DateTime;
pub const DynamicValue = Value.Value;
pub const Table = Value.Table;
pub const Array = Value.Array;

/// Parses TOML input into the dynamic `DynamicValue` representation.
pub fn parseValue(allocator: std.mem.Allocator, input: []const u8) TomlError!DynamicValue {
    var parser = Parser.init(allocator, input);
    return parser.parse();
}

test stringify {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    try stringify(Config{
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

const Config = struct {
    title: []const u8,
    enabled: bool,
    retries: []const usize,
    owner: struct {
        name: []const u8,
    },
};

test parse {
    const config = try parse(
        Config,
        std.testing.allocator,
        \\title = "demo"
        \\enabled = true
        \\retries = [1, 2, 3]
        \\[owner]
        \\name = "alice"
        ,
    );
    defer std.testing.allocator.free(config.retries);

    try std.testing.expectEqualStrings("demo", config.title);
    try std.testing.expect(config.enabled);
    try std.testing.expectEqual(@as(usize, 3), config.retries.len);
    try std.testing.expectEqualStrings("alice", config.owner.name);
}

test "windows newlines in multiline strings" {
    const actual_input = "basic = \"\"\"\nhello\r\nworld\"\"\"\nliteral = '''\nhello\r\nworld'''";

    var parsed = try parseValue(std.testing.allocator, actual_input);
    defer parsed.deinit(std.testing.allocator);

    const table = parsed.table;
    try std.testing.expectEqualStrings("hello\nworld", table.get("basic").?.string.bytes);
    try std.testing.expectEqualStrings("hello\nworld", table.get("literal").?.string.bytes);
}

test "zero-allocation slice borrowing" {
    const BorrowConfig = struct {
        title: []const u8,
    };
    const input = "title = \"borrowed\"";

    const config = try parse(BorrowConfig, std.testing.allocator, input);
    try std.testing.expect(@intFromPtr(config.title.ptr) >= @intFromPtr(input.ptr) and @intFromPtr(config.title.ptr) < @intFromPtr(input.ptr) + input.len);
    try std.testing.expectEqualStrings("borrowed", config.title);
}

test "formatDiagnostic" {
    const input =
        \\name = "ok"
        \\broken = [1,,2]
    ;
    var parser = Parser.init(std.testing.allocator, input);
    try std.testing.expectError(error.ParseFailed, parser.parse());
    try std.testing.expect(parser.diagnostic() != null);
}

test "deeply nested arrays fail instead of overflowing the stack" {
    const allocator = std.testing.allocator;
    var input = std.ArrayListUnmanaged(u8).empty;
    defer input.deinit(allocator);

    try input.appendSlice(allocator, "value = ");
    var depth: usize = 0;
    while (depth < 1000) : (depth += 1) try input.append(allocator, '[');
    depth = 0;
    while (depth < 1000) : (depth += 1) try input.append(allocator, ']');

    var parser = Parser.init(allocator, input.items);
    try std.testing.expectError(error.ParseFailed, parser.parse());
    try std.testing.expect(parser.diagnostic() != null);
}

comptime {
    std.testing.refAllDecls(@This());
}

test "dynamic parse" {
    const input =
        \\title = "demo"
        \\enabled = true
        \\retries = [1, 2, 3]
        \\[owner]
        \\name = "alice"
    ;
    var parsed = try parseValue(std.testing.allocator, input);
    defer parsed.deinit(std.testing.allocator);

    const table = parsed.table;
    try std.testing.expectEqualStrings("demo", table.get("title").?.string.bytes);
    try std.testing.expect(table.get("enabled").?.boolean);
    try std.testing.expectEqual(@as(i64, 1), table.get("retries").?.array.items.items[0].integer);
    try std.testing.expectEqualStrings("alice", table.get("owner").?.table.get("name").?.string.bytes);
}

test "dynamic stringify" {
    var table = try Table.create(std.testing.allocator);
    defer {
        var root = DynamicValue{ .table = table };
        root.deinit(std.testing.allocator);
    }

    try table.putOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, "title"), .{
        .string = .{ .bytes = try std.testing.allocator.dupe(u8, "demo"), .allocated = true },
    });
    try table.putOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, "enabled"), .{
        .boolean = true,
    });

    var owner_table = try Table.create(std.testing.allocator);
    try owner_table.putOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, "name"), .{
        .string = .{ .bytes = try std.testing.allocator.dupe(u8, "alice"), .allocated = true },
    });
    try table.putOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, "owner"), .{
        .table = owner_table,
    });

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    const root_val = DynamicValue{ .table = table };
    try stringify(root_val, &aw.writer);

    const rendered = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "title = \"demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[owner]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "name = \"alice\"") != null);
}
