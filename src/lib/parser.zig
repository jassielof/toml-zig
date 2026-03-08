const std = @import("std");
const Error = @import("Error.zig");
const ValueModel = @import("Value.zig");

const String = ValueModel.String;
const Value = ValueModel.Value;
const Table = ValueModel.Table;
const Array = ValueModel.Array;
const Date = ValueModel.Date;
const Time = ValueModel.Time;
const DateTime = ValueModel.DateTime;

const KeyPart = struct {
    bytes: []const u8,
    allocated: bool = false,
};

pub const Parser = @This();

allocator: std.mem.Allocator,
input: []const u8,
index: usize = 0,
line: usize = 1,
column: usize = 1,
last_diagnostic: ?Error.Diagnostic = null,

pub fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
    return .{
        .allocator = allocator,
        .input = input,
    };
}

pub fn diagnostic(self: *const Parser) ?Error.Diagnostic {
    return self.last_diagnostic;
}

pub fn parse(self: *Parser) Error.TomlError!Value {
    const root = try Table.create(self.allocator);
    errdefer {
        var root_value = Value{ .table = root };
        root_value.deinit(self.allocator);
    }
    root.defined = true;

    var current = root;

    while (true) {
        try self.skipDocumentTrivia();
        if (self.eof()) break;

        if (self.peekByte().? == '[') {
            current = try self.parseTableHeader(root);
        } else {
            try self.parseKeyValue(current);
        }

        try self.skipInlineSpace();
        if (self.eof()) break;
        if (self.peekByte().? == '#') {
            self.skipComment();
        }
        if (self.eof()) break;
        if (!self.isNewline(self.index)) {
            return self.fail(.trailing_content, "expected end of line");
        }
        self.consumeNewline();
    }

    return .{ .table = root };
}

fn eof(self: *const Parser) bool {
    return self.index >= self.input.len;
}

fn peekByte(self: *const Parser) ?u8 {
    if (self.eof()) return null;
    return self.input[self.index];
}

fn peekOffset(self: *const Parser, offset: usize) ?u8 {
    const position = self.index + offset;
    if (position >= self.input.len) return null;
    return self.input[position];
}

fn advanceByte(self: *Parser) void {
    if (self.eof()) return;
    self.index += 1;
    self.column += 1;
}

fn isNewline(self: *const Parser, index: usize) bool {
    if (index >= self.input.len) return false;
    return self.input[index] == '\n' or self.input[index] == '\r';
}

fn consumeNewline(self: *Parser) void {
    if (self.peekByte() == null) return;
    if (self.peekByte().? == '\r') {
        self.index += 1;
        if (self.index < self.input.len and self.input[self.index] == '\n') {
            self.index += 1;
        }
    } else {
        self.index += 1;
    }
    self.line += 1;
    self.column = 1;
}

fn fail(self: *Parser, kind: Error.ErrorKind, message: []const u8) Error.TomlError {
    self.last_diagnostic = .{
        .kind = kind,
        .offset = self.index,
        .line = self.line,
        .column = self.column,
        .message = message,
    };
    return error.ParseFailed;
}

fn skipInlineSpace(self: *Parser) !void {
    while (!self.eof()) {
        switch (self.peekByte().?) {
            ' ', '\t' => self.advanceByte(),
            else => return,
        }
    }
}

fn skipComment(self: *Parser) void {
    while (!self.eof()) {
        if (self.isNewline(self.index)) return;
        self.advanceByte();
    }
}

fn skipDocumentTrivia(self: *Parser) !void {
    while (!self.eof()) {
        try self.skipInlineSpace();
        if (self.eof()) return;
        if (self.peekByte().? == '#') {
            self.skipComment();
        }
        if (self.eof()) return;
        if (!self.isNewline(self.index)) return;
        self.consumeNewline();
    }
}

fn expectByte(self: *Parser, expected: u8) Error.TomlError!void {
    if (self.peekByte() == null or self.peekByte().? != expected) {
        return self.fail(.unexpected_token, "unexpected token");
    }
    self.advanceByte();
}

fn parseKeyValue(self: *Parser, current: *Table) Error.TomlError!void {
    var path = std.ArrayListUnmanaged(KeyPart){};
    defer self.freeKeyParts(&path);

    try self.parseKeyPath(&path);
    try self.skipInlineSpace();
    try self.expectByte('=');
    try self.skipInlineSpace();

    var value = try self.parseValue();
    errdefer value.deinit(self.allocator);

    try self.insertValue(current, path.items, value, current.sealed);
}

fn parseTableHeader(self: *Parser, root: *Table) Error.TomlError!*Table {
    try self.expectByte('[');
    const is_array_table = self.peekByte() != null and self.peekByte().? == '[';
    if (is_array_table) {
        self.advanceByte();
    }

    try self.skipInlineSpace();

    var path = std.ArrayListUnmanaged(KeyPart){};
    defer self.freeKeyParts(&path);
    try self.parseKeyPath(&path);

    try self.skipInlineSpace();
    try self.expectByte(']');
    if (is_array_table) {
        try self.expectByte(']');
        return self.defineArrayTable(root, path.items);
    }
    return self.defineTable(root, path.items);
}

fn parseKeyPath(self: *Parser, parts: *std.ArrayListUnmanaged(KeyPart)) Error.TomlError!void {
    while (true) {
        try self.skipInlineSpace();
        try parts.append(self.allocator, try self.parseKeyPart());
        try self.skipInlineSpace();

        if (self.peekByte() == null or self.peekByte().? != '.') break;
        self.advanceByte();
    }

    if (parts.items.len == 0) {
        return self.fail(.invalid_key, "expected key");
    }
}

fn parseKeyPart(self: *Parser) Error.TomlError!KeyPart {
    const current = self.peekByte() orelse return self.fail(.unexpected_eof, "unexpected end of input");

    if (current == '"') {
        const string_value = try self.parseBasicString();
        return .{ .bytes = string_value.bytes, .allocated = string_value.allocated };
    }

    if (current == '\'') {
        const string_value = try self.parseLiteralString();
        return .{ .bytes = string_value.bytes, .allocated = string_value.allocated };
    }

    const start = self.index;
    while (!self.eof()) {
        const byte = self.peekByte().?;
        if (!isBareKeyByte(byte)) break;
        self.advanceByte();
    }

    if (start == self.index) {
        return self.fail(.invalid_key, "invalid bare key");
    }

    return .{ .bytes = self.input[start..self.index] };
}

fn isBareKeyByte(byte: u8) bool {
    if (byte >= 0x80) return true;
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn parseValue(self: *Parser) Error.TomlError!Value {
    const current = self.peekByte() orelse return self.fail(.unexpected_eof, "expected value");
    return switch (current) {
        '"' => .{ .string = try self.parseBasicString() },
        '\'' => .{ .string = try self.parseLiteralString() },
        '[' => self.parseArray(),
        '{' => self.parseInlineTable(),
        else => self.parseScalar(),
    };
}

fn parseArray(self: *Parser) Error.TomlError!Value {
    try self.expectByte('[');

    const array = try self.allocator.create(Array);
    array.* = .{};
    errdefer {
        array.deinit(self.allocator);
        self.allocator.destroy(array);
    }

    while (true) {
        try self.skipArrayTrivia();
        if (self.peekByte() == null) return self.fail(.unexpected_eof, "unterminated array");
        if (self.peekByte().? == ']') {
            self.advanceByte();
            break;
        }

        try array.append(self.allocator, try self.parseValue());
        try self.skipArrayTrivia();
        if (self.peekByte() == null) return self.fail(.unexpected_eof, "unterminated array");
        if (self.peekByte().? == ',') {
            self.advanceByte();
            try self.skipArrayTrivia();
            if (self.peekByte() != null and self.peekByte().? == ']') {
                self.advanceByte();
                break;
            }
            continue;
        }
        if (self.peekByte().? == ']') {
            self.advanceByte();
            break;
        }
        return self.fail(.unexpected_token, "expected ',' or ']'");
    }

    return .{ .array = array };
}

fn skipArrayTrivia(self: *Parser) Error.TomlError!void {
    while (!self.eof()) {
        try self.skipInlineSpace();
        if (self.eof()) return;
        if (self.peekByte().? == '#') {
            self.skipComment();
        }
        if (self.eof()) return;
        if (!self.isNewline(self.index)) return;
        self.consumeNewline();
    }
}

fn parseInlineTable(self: *Parser) Error.TomlError!Value {
    try self.expectByte('{');

    const table = try Table.create(self.allocator);
    table.defined = true;
    table.sealed = true;
    errdefer {
        table.deinit(self.allocator);
        self.allocator.destroy(table);
    }

    while (true) {
        try self.skipInlineTableTrivia();
        if (self.peekByte() == null) return self.fail(.unexpected_eof, "unterminated inline table");
        if (self.peekByte().? == '}') {
            self.advanceByte();
            break;
        }

        var path = std.ArrayListUnmanaged(KeyPart){};
        defer self.freeKeyParts(&path);
        try self.parseKeyPath(&path);
        try self.skipInlineSpace();
        try self.expectByte('=');
        try self.skipInlineTableTrivia();

        var value = try self.parseValue();
        errdefer value.deinit(self.allocator);
        try self.insertValue(table, path.items, value, true);

        try self.skipInlineTableTrivia();
        if (self.peekByte() == null) return self.fail(.unexpected_eof, "unterminated inline table");
        if (self.peekByte().? == ',') {
            self.advanceByte();
            try self.skipInlineTableTrivia();
            if (self.peekByte() != null and self.peekByte().? == '}') {
                self.advanceByte();
                break;
            }
            continue;
        }
        if (self.peekByte().? == '}') {
            self.advanceByte();
            break;
        }
        return self.fail(.unexpected_token, "expected ',' or '}'");
    }

    return .{ .table = table };
}

fn skipInlineTableTrivia(self: *Parser) Error.TomlError!void {
    while (!self.eof()) {
        try self.skipInlineSpace();
        if (self.eof()) return;
        if (self.peekByte().? == '#') {
            self.skipComment();
        }
        if (self.eof()) return;
        if (!self.isNewline(self.index)) return;
        self.consumeNewline();
    }
}

fn parseScalar(self: *Parser) Error.TomlError!Value {
    const start = self.index;
    while (!self.eof()) {
        const byte = self.peekByte().?;
        if (byte == ',' or byte == ']' or byte == '}' or byte == '#') break;
        if (self.isNewline(self.index)) break;
        self.advanceByte();
    }

    const raw = self.input[start..self.index];
    const token = std.mem.trimRight(u8, raw, " \t");
    if (token.len == 0) {
        return self.fail(.unexpected_token, "expected value");
    }

    if (std.mem.eql(u8, token, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, token, "false")) return .{ .boolean = false };

    if (try parseDateTimeLike(token)) |date_time_value| return date_time_value;
    if (try self.parseInteger(token)) |integer_value| return .{ .integer = integer_value };
    if (try self.parseFloat(token)) |float_value| return .{ .float = float_value };

    return self.fail(.unexpected_token, "unsupported scalar value");
}

fn parseBasicString(self: *Parser) Error.TomlError!String {
    if (self.peekOffset(0) == '"' and self.peekOffset(1) == '"' and self.peekOffset(2) == '"') {
        return self.parseMultilineBasicString();
    }

    try self.expectByte('"');
    const start = self.index;
    var needs_unescape = false;

    while (!self.eof()) {
        const byte = self.peekByte().?;
        if (byte == '\\') {
            needs_unescape = true;
            self.advanceByte();
            if (self.eof()) {
                return self.fail(.unexpected_eof, "unterminated escape sequence");
            }
            if (self.isNewline(self.index)) {
                return self.fail(.unexpected_token, "single-line string cannot contain a newline");
            }
            self.advanceByte();
            continue;
        }
        if (byte == '"') {
            const end = self.index;
            self.advanceByte();

            if (!needs_unescape) {
                return .{ .bytes = self.input[start..end] };
            }
            return self.unescapeBasicString(self.input[start..end], false);
        }
        if (self.isNewline(self.index)) {
            return self.fail(.unexpected_token, "single-line string cannot contain a newline");
        }
        self.advanceByte();
    }

    return self.fail(.unexpected_eof, "unterminated string");
}

fn parseLiteralString(self: *Parser) Error.TomlError!String {
    if (self.peekOffset(0) == '\'' and self.peekOffset(1) == '\'' and self.peekOffset(2) == '\'') {
        return self.parseMultilineLiteralString();
    }

    try self.expectByte('\'');
    const start = self.index;
    while (!self.eof()) {
        const byte = self.peekByte().?;
        if (byte == '\'') {
            const end = self.index;
            self.advanceByte();
            return .{ .bytes = self.input[start..end] };
        }
        if (self.isNewline(self.index)) {
            return self.fail(.unexpected_token, "single-line literal string cannot contain a newline");
        }
        self.advanceByte();
    }

    return self.fail(.unexpected_eof, "unterminated literal string");
}

fn parseMultilineBasicString(self: *Parser) Error.TomlError!String {
    self.advanceByte();
    self.advanceByte();
    self.advanceByte();

    if (self.isNewline(self.index)) {
        self.consumeNewline();
    }

    var buffer = std.ArrayListUnmanaged(u8){};
    errdefer buffer.deinit(self.allocator);

    while (!self.eof()) {
        if (self.peekOffset(0) == '"' and self.peekOffset(1) == '"' and self.peekOffset(2) == '"') {
            self.advanceByte();
            self.advanceByte();
            self.advanceByte();
            return .{ .bytes = try buffer.toOwnedSlice(self.allocator), .allocated = true };
        }

        const byte = self.peekByte().?;
        if (byte == '\\') {
            self.advanceByte();
            if (self.eof()) return self.fail(.unexpected_eof, "unterminated escape sequence");
            if (self.peekByte().? == ' ' or self.peekByte().? == '\t' or self.isNewline(self.index)) {
                while (!self.eof()) {
                    if (self.peekByte().? == ' ' or self.peekByte().? == '\t') {
                        self.advanceByte();
                        continue;
                    }
                    if (self.isNewline(self.index)) {
                        self.consumeNewline();
                        continue;
                    }
                    break;
                }
                continue;
            }

            try self.appendEscape(&buffer);
            continue;
        }

        if (self.isNewline(self.index)) {
            self.consumeNewline();
            try buffer.append(self.allocator, '\n');
            continue;
        }

        try buffer.append(self.allocator, byte);
        self.advanceByte();
    }

    return self.fail(.unexpected_eof, "unterminated multiline string");
}

fn parseMultilineLiteralString(self: *Parser) Error.TomlError!String {
    self.advanceByte();
    self.advanceByte();
    self.advanceByte();

    if (self.isNewline(self.index)) {
        self.consumeNewline();
    }

    var buffer = std.ArrayListUnmanaged(u8){};
    errdefer buffer.deinit(self.allocator);

    while (!self.eof()) {
        if (self.peekOffset(0) == '\'' and self.peekOffset(1) == '\'' and self.peekOffset(2) == '\'') {
            self.advanceByte();
            self.advanceByte();
            self.advanceByte();
            return .{ .bytes = try buffer.toOwnedSlice(self.allocator), .allocated = true };
        }

        if (self.isNewline(self.index)) {
            self.consumeNewline();
            try buffer.append(self.allocator, '\n');
            continue;
        }

        try buffer.append(self.allocator, self.peekByte().?);
        self.advanceByte();
    }

    return self.fail(.unexpected_eof, "unterminated multiline literal string");
}

fn unescapeBasicString(self: *Parser, text: []const u8, multiline: bool) Error.TomlError!String {
    _ = multiline;
    var buffer = std.ArrayListUnmanaged(u8){};
    errdefer buffer.deinit(self.allocator);

    var index: usize = 0;
    while (index < text.len) {
        if (text[index] != '\\') {
            try buffer.append(self.allocator, text[index]);
            index += 1;
            continue;
        }

        index += 1;
        if (index >= text.len) return self.fail(.unexpected_eof, "unterminated escape sequence");
        const consumed = try self.decodeEscapeInto(&buffer, text[index..]);
        index += consumed;
    }

    return .{ .bytes = try buffer.toOwnedSlice(self.allocator), .allocated = true };
}

fn appendEscape(self: *Parser, buffer: *std.ArrayListUnmanaged(u8)) Error.TomlError!void {
    const current = self.input[self.index..];
    const consumed = try self.decodeEscapeInto(buffer, current);
    var remaining = consumed;
    while (remaining > 0) : (remaining -= 1) {
        self.advanceByte();
    }
}

fn decodeEscapeInto(self: *Parser, buffer: *std.ArrayListUnmanaged(u8), text: []const u8) Error.TomlError!usize {
    if (text.len == 0) return self.fail(.unexpected_eof, "unterminated escape sequence");
    switch (text[0]) {
        '"' => {
            try buffer.append(self.allocator, '"');
            return 1;
        },
        '\\' => {
            try buffer.append(self.allocator, '\\');
            return 1;
        },
        'b' => {
            try buffer.append(self.allocator, 0x08);
            return 1;
        },
        't' => {
            try buffer.append(self.allocator, '\t');
            return 1;
        },
        'n' => {
            try buffer.append(self.allocator, '\n');
            return 1;
        },
        'f' => {
            try buffer.append(self.allocator, 0x0c);
            return 1;
        },
        'r' => {
            try buffer.append(self.allocator, '\r');
            return 1;
        },
        'e' => {
            try buffer.append(self.allocator, 0x1b);
            return 1;
        },
        'x' => {
            if (text.len < 3) return self.fail(.invalid_escape, "short hex escape");
            try buffer.append(self.allocator, try self.parseHexByte(text[1..3]));
            return 3;
        },
        'u' => {
            if (text.len < 5) return self.fail(.invalid_escape, "short unicode escape");
            try self.appendUnicodeScalar(buffer, try self.parseHexScalar(text[1..5]));
            return 5;
        },
        'U' => {
            if (text.len < 9) return self.fail(.invalid_escape, "short unicode escape");
            try self.appendUnicodeScalar(buffer, try self.parseHexScalar(text[1..9]));
            return 9;
        },
        else => return self.fail(.invalid_escape, "invalid string escape"),
    }
}

fn parseHexByte(self: *Parser, text: []const u8) Error.TomlError!u8 {
    return std.fmt.parseInt(u8, text, 16) catch return self.fail(.invalid_escape, "invalid hex escape");
}

fn parseHexScalar(self: *Parser, text: []const u8) Error.TomlError!u21 {
    const value = std.fmt.parseInt(u32, text, 16) catch return self.fail(.invalid_escape, "invalid unicode escape");
    const scalar = std.math.cast(u21, value) orelse return self.fail(.invalid_unicode_scalar, "invalid unicode scalar");
    if (!std.unicode.utf8ValidCodepoint(scalar)) {
        return self.fail(.invalid_unicode_scalar, "invalid unicode scalar");
    }
    return scalar;
}

fn appendUnicodeScalar(self: *Parser, buffer: *std.ArrayListUnmanaged(u8), scalar: u21) Error.TomlError!void {
    var bytes: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(scalar, &bytes) catch return self.fail(.invalid_unicode_scalar, "invalid unicode scalar");
    try buffer.appendSlice(self.allocator, bytes[0..length]);
}

fn parseDateTimeLike(token: []const u8) Error.TomlError!?Value {
    if (parseDate(token)) |date_value| {
        return .{ .date = date_value };
    }
    if (parseTime(token)) |time_value| {
        return .{ .time = time_value };
    }
    if (try parseDateTime(token)) |date_time_value| {
        return .{ .datetime = date_time_value };
    }
    return null;
}

fn parseDate(token: []const u8) ?Date {
    if (token.len != 10 or token[4] != '-' or token[7] != '-') return null;
    const year = std.fmt.parseInt(i32, token[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, token[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, token[8..10], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    return .{ .year = year, .month = month, .day = day };
}

fn parseTime(token: []const u8) ?Time {
    return parseTimePart(token).time;
}

fn parseDateTime(token: []const u8) Error.TomlError!?DateTime {
    var separator_index: ?usize = null;
    for (token, 0..) |byte, index| {
        if (byte == 'T' or byte == 't' or byte == ' ') {
            separator_index = index;
            break;
        }
    }
    const separator = separator_index orelse return null;
    const date_value = parseDate(token[0..separator]) orelse return null;
    const time_result = parseTimePart(token[separator + 1 ..]);
    const time_value = time_result.time orelse return null;
    return .{
        .date = date_value,
        .time = time_value,
        .offset_minutes = time_result.offset_minutes,
    };
}

const TimeParseResult = struct {
    time: ?Time,
    offset_minutes: ?i16 = null,
};

fn parseTimePart(token: []const u8) TimeParseResult {
    if (token.len < 5 or token[2] != ':') return .{ .time = null };
    const hour = std.fmt.parseInt(u8, token[0..2], 10) catch return .{ .time = null };
    const minute = std.fmt.parseInt(u8, token[3..5], 10) catch return .{ .time = null };
    var second: u8 = 0;
    var index: usize = 5;
    if (index < token.len and token[index] == ':') {
        if (token.len < index + 3) return .{ .time = null };
        second = std.fmt.parseInt(u8, token[index + 1 .. index + 3], 10) catch return .{ .time = null };
        index += 3;
    }
    if (hour > 23 or minute > 59 or second > 60) return .{ .time = null };

    var nanos: u32 = 0;
    if (index < token.len and token[index] == '.') {
        index += 1;
        const frac_start = index;
        while (index < token.len and std.ascii.isDigit(token[index])) : (index += 1) {}
        if (frac_start == index) return .{ .time = null };
        const frac = token[frac_start..index];
        const limited_len = @min(frac.len, 9);
        const parsed = std.fmt.parseInt(u32, frac[0..limited_len], 10) catch return .{ .time = null };
        const scale = std.math.pow(u32, 10, @intCast(9 - limited_len));
        nanos = parsed * scale;
    }

    var offset: ?i16 = null;
    if (index < token.len) {
        if (token[index] == 'Z' or token[index] == 'z') {
            offset = 0;
            index += 1;
        } else if (token[index] == '+' or token[index] == '-') {
            if (index + 6 != token.len or token[index + 3] != ':') return .{ .time = null };
            const sign: i16 = if (token[index] == '+') 1 else -1;
            const hours = std.fmt.parseInt(i16, token[index + 1 .. index + 3], 10) catch return .{ .time = null };
            const minutes = std.fmt.parseInt(i16, token[index + 4 .. index + 6], 10) catch return .{ .time = null };
            offset = sign * (hours * 60 + minutes);
            index += 6;
        }
    }

    if (index != token.len) return .{ .time = null };
    return .{ .time = .{ .hour = hour, .minute = minute, .second = second, .nanosecond = nanos }, .offset_minutes = offset };
}

fn parseInteger(self: *Parser, token: []const u8) Error.TomlError!?i64 {
    if (token.len == 0) return null;

    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(self.allocator);

    var index: usize = 0;
    if (token[index] == '+' or token[index] == '-') {
        try buffer.append(self.allocator, token[index]);
        index += 1;
        if (index == token.len) return null;
    }

    var radix: u8 = 10;
    if (index + 1 < token.len and token[index] == '0') {
        switch (token[index + 1]) {
            'x' => {
                radix = 16;
                try buffer.appendSlice(self.allocator, "0x");
                index += 2;
            },
            'o' => {
                radix = 8;
                try buffer.appendSlice(self.allocator, "0o");
                index += 2;
            },
            'b' => {
                radix = 2;
                try buffer.appendSlice(self.allocator, "0b");
                index += 2;
            },
            else => {},
        }
    }

    if (radix == 10 and index + 1 < token.len and token[index] == '0' and token[index + 1] != '.' and token[index + 1] != 'e' and token[index + 1] != 'E') {
        return null;
    }

    var saw_digit = false;
    var previous_underscore = false;
    while (index < token.len) : (index += 1) {
        const byte = token[index];
        if (byte == '_') {
            if (!saw_digit or previous_underscore or index + 1 == token.len) return null;
            previous_underscore = true;
            continue;
        }
        if (!isDigitForRadix(byte, radix)) return null;
        try buffer.append(self.allocator, byte);
        saw_digit = true;
        previous_underscore = false;
    }

    if (!saw_digit or previous_underscore) return null;
    return std.fmt.parseInt(i64, buffer.items, 0) catch return self.fail(.invalid_number, "integer overflow");
}

fn parseFloat(self: *Parser, token: []const u8) Error.TomlError!?f64 {
    if (std.mem.eql(u8, token, "inf") or std.mem.eql(u8, token, "+inf")) return std.math.inf(f64);
    if (std.mem.eql(u8, token, "-inf")) return -std.math.inf(f64);
    if (std.mem.eql(u8, token, "nan") or std.mem.eql(u8, token, "+nan")) return std.math.nan(f64);
    if (std.mem.eql(u8, token, "-nan")) return -std.math.nan(f64);

    var saw_dot = false;
    var saw_exp = false;
    var saw_digit = false;
    var previous_underscore = false;

    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(self.allocator);

    for (token, 0..) |byte, index| {
        if (byte == '+' or byte == '-') {
            if (index != 0 and token[index - 1] != 'e' and token[index - 1] != 'E') return null;
            try buffer.append(self.allocator, byte);
            previous_underscore = false;
            continue;
        }
        if (byte == '_') {
            if (!saw_digit or previous_underscore or index + 1 == token.len) return null;
            previous_underscore = true;
            continue;
        }
        if (byte == '.') {
            if (saw_dot or saw_exp or previous_underscore) return null;
            saw_dot = true;
            try buffer.append(self.allocator, byte);
            previous_underscore = false;
            continue;
        }
        if (byte == 'e' or byte == 'E') {
            if (saw_exp or !saw_digit or previous_underscore) return null;
            saw_exp = true;
            try buffer.append(self.allocator, byte);
            previous_underscore = false;
            saw_digit = false;
            continue;
        }
        if (!std.ascii.isDigit(byte)) return null;
        try buffer.append(self.allocator, byte);
        saw_digit = true;
        previous_underscore = false;
    }

    if ((!saw_dot and !saw_exp) or !saw_digit or previous_underscore) return null;
    return std.fmt.parseFloat(f64, buffer.items) catch return self.fail(.invalid_number, "invalid float");
}

fn isDigitForRadix(byte: u8, radix: u8) bool {
    return switch (radix) {
        2 => byte == '0' or byte == '1',
        8 => byte >= '0' and byte <= '7',
        10 => std.ascii.isDigit(byte),
        16 => std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f') or (byte >= 'A' and byte <= 'F'),
        else => false,
    };
}

fn insertValue(self: *Parser, base: *Table, path: []const KeyPart, value: Value, sealed: bool) Error.TomlError!void {
    var cursor = base;
    for (path[0 .. path.len - 1]) |part| {
        if (!sealed and cursor.sealed) return self.fail(.redefined_table, "inline tables cannot be extended");

        if (cursor.getPtr(part.bytes)) |existing| {
            cursor = try self.expectInsertTable(existing);
            continue;
        }

        const child = try Table.create(self.allocator);
        child.implicit = true;
        child.sealed = sealed;
        try cursor.putOwned(self.allocator, try self.allocator.dupe(u8, part.bytes), .{ .table = child });
        cursor = child;
    }

    if (!sealed and cursor.sealed) return self.fail(.redefined_table, "inline tables cannot be extended");
    const leaf = path[path.len - 1].bytes;
    if (cursor.getPtr(leaf) != null) return self.fail(.duplicate_key, "duplicate key");

    var stored = value;
    if (sealed) {
        self.freezeValue(&stored);
    }
    try cursor.putOwned(self.allocator, try self.allocator.dupe(u8, leaf), stored);
}

fn expectTraversalTable(self: *Parser, value: *Value) Error.TomlError!*Table {
    return switch (value.*) {
        .table => |table_value| table_value,
        .array => |array_value| blk: {
            if (!array_value.table_array) return self.fail(.invalid_key, "expected table");
            if (array_value.items.items.len == 0) return self.fail(.invalid_key, "array of tables is empty");
            const last = &array_value.items.items[array_value.items.items.len - 1];
            if (last.* != .table) return self.fail(.invalid_key, "expected table in array");
            break :blk last.table;
        },
        else => self.fail(.invalid_key, "expected table"),
    };
}

fn expectInsertTable(self: *Parser, value: *Value) Error.TomlError!*Table {
    return switch (value.*) {
        .table => |table_value| table_value,
        .array => self.fail(.redefined_table, "cannot extend an array of tables with a dotted key"),
        else => self.fail(.invalid_key, "expected table"),
    };
}

fn defineTable(self: *Parser, root: *Table, path: []const KeyPart) Error.TomlError!*Table {
    var cursor = root;
    for (path[0 .. path.len - 1]) |part| {
        if (cursor.getPtr(part.bytes)) |existing| {
            cursor = try self.expectTraversalTable(existing);
            continue;
        }

        const child = try Table.create(self.allocator);
        child.implicit = true;
        try cursor.putOwned(self.allocator, try self.allocator.dupe(u8, part.bytes), .{ .table = child });
        cursor = child;
    }

    const leaf = path[path.len - 1].bytes;
    if (cursor.getPtr(leaf)) |existing| {
        const table_value = switch (existing.*) {
            .table => |table_value| table_value,
            else => return self.fail(.redefined_table, "table name collides with value"),
        };
        if (table_value.defined or table_value.sealed) {
            return self.fail(.redefined_table, "table already defined");
        }
        table_value.defined = true;
        table_value.implicit = false;
        return table_value;
    }

    const child = try Table.create(self.allocator);
    child.defined = true;
    try cursor.putOwned(self.allocator, try self.allocator.dupe(u8, leaf), .{ .table = child });
    return child;
}

fn defineArrayTable(self: *Parser, root: *Table, path: []const KeyPart) Error.TomlError!*Table {
    var cursor = root;
    for (path[0 .. path.len - 1]) |part| {
        if (cursor.getPtr(part.bytes)) |existing| {
            cursor = try self.expectTraversalTable(existing);
            continue;
        }

        const child = try Table.create(self.allocator);
        child.implicit = true;
        try cursor.putOwned(self.allocator, try self.allocator.dupe(u8, part.bytes), .{ .table = child });
        cursor = child;
    }

    const leaf = path[path.len - 1].bytes;
    var target_array: *Array = undefined;
    if (cursor.getPtr(leaf)) |existing| {
        switch (existing.*) {
            .array => |array_value| {
                if (!array_value.table_array) {
                    return self.fail(.redefined_table, "array table collides with value");
                }
                target_array = array_value;
            },
            else => return self.fail(.redefined_table, "array table collides with value"),
        }
    } else {
        target_array = try self.allocator.create(Array);
        target_array.* = .{ .table_array = true };
        try cursor.putOwned(self.allocator, try self.allocator.dupe(u8, leaf), .{ .array = target_array });
    }

    const child = try Table.create(self.allocator);
    child.defined = true;
    try target_array.append(self.allocator, .{ .table = child });
    return child;
}

fn freezeValue(self: *Parser, value: *Value) void {
    _ = self;
    switch (value.*) {
        .table => |table_value| freezeTable(table_value),
        .array => |array_value| {
            for (array_value.items.items) |*item| {
                switch (item.*) {
                    .table => |table_value| freezeTable(table_value),
                    else => {},
                }
            }
        },
        else => {},
    }
}

fn freezeTable(table: *Table) void {
    table.sealed = true;
    var iterator = table.map.iterator();
    while (iterator.next()) |entry| {
        switch (entry.value_ptr.*) {
            .table => |child| freezeTable(child),
            .array => |array_value| {
                for (array_value.items.items) |*item| {
                    if (item.* == .table) {
                        freezeTable(item.table);
                    }
                }
            },
            else => {},
        }
    }
}

fn freeKeyParts(self: *Parser, parts: *std.ArrayListUnmanaged(KeyPart)) void {
    for (parts.items) |part| {
        if (part.allocated) {
            self.allocator.free(part.bytes);
        }
    }
    parts.deinit(self.allocator);
}

test parseBasicString {
    var parser = Parser.init(std.testing.allocator, "\"hello\\nworld\"");
    const string_value = try parser.parseBasicString();
    defer if (string_value.allocated) std.testing.allocator.free(string_value.bytes);

    try std.testing.expectEqualStrings("hello\nworld", string_value.bytes);
}

test parseValue {
    var parser = Parser.init(std.testing.allocator,
        \\title = "demo"
        \\items = [1, 2, 3]
    );

    var value = try parser.parse();
    defer value.deinit(std.testing.allocator);

    try std.testing.expect(value == .table);
    try std.testing.expectEqualStrings("demo", value.table.get("title").?.string.bytes);
}
