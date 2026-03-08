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

/// Parses TOML input directly into a Zig value of type `T`.
///
/// The returned value may borrow slices from `input` and may also allocate
/// derived data using `allocator`, depending on the target type and parser
/// behavior.
pub fn parse(comptime T: type, allocator: std.mem.Allocator, input: []const u8) TomlError!T {
    return Deserializer.parse(T, allocator, input);
}

/// Parses TOML input into the dynamic `DynamicValue` representation.
pub fn parseValue(allocator: std.mem.Allocator, input: []const u8) TomlError!DynamicValue {
    var parser = Parser.init(allocator, input);
    return parser.parse();
}

/// Serializes a Zig value as TOML using the provided writer.
pub fn stringify(value: anytype, writer: anytype) TomlError!void {
    return Serializer.stringify(value, writer);
}

/// Formats a diagnostic as `line:column: kind: message`.
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
