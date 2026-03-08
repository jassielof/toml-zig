const std = @import("std");

/// Public error set used by the library API.
pub const TomlError = error{
    OutOfMemory,
    ParseFailed,
    TypeMismatch,
    MissingField,
    Overflow,
    UnsupportedType,
};

/// Fine-grained categories used inside `Diagnostic`.
pub const ErrorKind = enum {
    unexpected_eof,
    unexpected_token,
    invalid_escape,
    invalid_unicode_scalar,
    invalid_number,
    invalid_date_time,
    invalid_key,
    duplicate_key,
    redefined_table,
    trailing_content,
    type_mismatch,
    missing_field,
    overflow,
    unsupported_type,
};

/// Detailed parse or conversion error information with source location.
pub const Diagnostic = struct {
    kind: ErrorKind,
    offset: usize,
    line: usize,
    column: usize,
    message: []const u8,

    /// Writes the diagnostic as `line:column: kind: message`.
    pub fn format(self: Diagnostic, writer: anytype) !void {
        try writer.print("{d}:{d}: {s}: {s}", .{
            self.line,
            self.column,
            @tagName(self.kind),
            self.message,
        });
    }
};

/// Convenience wrapper around `Diagnostic.format`.
pub fn formatDiagnostic(diagnostic: Diagnostic, writer: anytype) !void {
    try diagnostic.format(writer);
}

test formatDiagnostic {
    var list = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer list.deinit(std.testing.allocator);

    try formatDiagnostic(.{
        .kind = .invalid_number,
        .offset = 3,
        .line = 1,
        .column = 4,
        .message = "invalid integer",
    }, list.writer(std.testing.allocator));

    try std.testing.expectEqualStrings("1:4: invalid_number: invalid integer", list.items);
}
