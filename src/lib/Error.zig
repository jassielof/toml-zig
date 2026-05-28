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
    pub fn format(self: Diagnostic, writer: *std.Io.Writer) !void {
        try writer.print("{d}:{d}: {s}: {s}", .{
            self.line,
            self.column,
            @tagName(self.kind),
            self.message,
        });
    }
};

/// Convenience wrapper around `Diagnostic.format`.
pub fn formatDiagnostic(diagnostic: Diagnostic, writer: *std.Io.Writer) !void {
    try diagnostic.format(writer);
}

test formatDiagnostic {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    try formatDiagnostic(.{
        .kind = .invalid_number,
        .offset = 3,
        .line = 1,
        .column = 4,
        .message = "invalid integer",
    }, &aw.writer);

    try std.testing.expectEqualStrings("1:4: invalid_number: invalid integer", aw.written());
}
