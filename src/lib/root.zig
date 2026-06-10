const std = @import("std");

/// Error-related types and helpers used by the TOML parser and serializer.
pub const Error = @import("Error.zig");
/// Scannerless TOML parser that produces the dynamic value model.
pub const Parser = @import("Parser.zig");
/// Dynamic TOML value model and date/time helper types.
pub const Value = @import("Value.zig");
/// Reflection-based conversion from dynamic TOML values into Zig types.
pub const Deserializer = @import("Deserializer.zig");
/// Reflection-based TOML serializer for Zig values.
pub const Serializer = @import("Serializer.zig");

/// Structured parse diagnostic with source position and error kind.
pub const Diagnostic = Error.Diagnostic;
/// Classification for parser and conversion failures.
pub const ErrorKind = Error.ErrorKind;
/// Top-level error set returned by the public TOML API.
pub const TomlError = Error.TomlError;

/// Local date value parsed from TOML.
pub const Date = Value.Date;
/// Local time value parsed from TOML.
pub const Time = Value.Time;
/// Local or offset date-time value parsed from TOML.
pub const DateTime = Value.DateTime;
/// Untyped TOML value tree returned by `parseValue`.
pub const DynamicValue = Value.Value;
/// Dynamic TOML table node.
pub const Table = Value.Table;
/// Dynamic TOML array node.
pub const Array = Value.Array;

pub const parse = Deserializer.parse;

/// Parses TOML input into the dynamic `DynamicValue` representation.
pub fn parseValue(allocator: std.mem.Allocator, input: []const u8) TomlError!DynamicValue {
    var parser = Parser.init(allocator, input);
    return parser.parse();
}

pub const stringify = Serializer.stringify;

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

pub const formatDiagnostic = Error.formatDiagnostic;

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

comptime {
    std.testing.refAllDecls(@This());
}
