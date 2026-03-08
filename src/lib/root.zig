const std = @import("std");

pub const Error = @import("Error.zig");
pub const Parser = @import("Parser.zig");
pub const Value = @import("Value.zig");
pub const Deserializer = @import("Deserializer.zig");
pub const Serializer = @import("Serializer.zig");

pub const Diagnostic = Error.Diagnostic;
pub const ErrorKind = Error.ErrorKind;
pub const TomlError = Error.TomlError;

pub const Date = Value.Date;
pub const Time = Value.Time;
pub const DateTime = Value.DateTime;
pub const DynamicValue = Value.Value;
pub const Table = Value.Table;

pub fn parse(comptime T: type, allocator: std.mem.Allocator, input: []const u8) TomlError!T {
    return Deserializer.parse(T, allocator, input);
}

pub fn parseValue(allocator: std.mem.Allocator, input: []const u8) TomlError!DynamicValue {
    var parser = Parser.init(allocator, input);
    return parser.parse();
}

pub fn stringify(value: anytype, writer: anytype) TomlError!void {
    return Serializer.stringify(value, writer);
}

pub fn formatDiagnostic(diagnostic: Diagnostic, writer: anytype) !void {
    try Error.formatDiagnostic(diagnostic, writer);
}

test parse {
    const Config = struct {
        title: []const u8,
        enabled: bool,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try parse(Config, arena.allocator(),
        \\title = "demo"
        \\enabled = true
    );

    try std.testing.expectEqualStrings("demo", config.title);
    try std.testing.expect(config.enabled);
}

comptime {
    _ = @import("Parser.zig");
    _ = @import("Deserializer.zig");
    _ = @import("Serializer.zig");
    _ = @import("Error.zig");
    _ = @import("Value.zig");
}

test {
    std.testing.refAllDecls(@This());
}
