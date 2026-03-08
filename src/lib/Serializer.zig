const std = @import("std");
const Error = @import("Error.zig");
const ValueModel = @import("Value.zig");

pub fn stringify(value: anytype, writer: anytype) Error.TomlError!void {
    try emitRoot(@TypeOf(value), value, writer);
}

fn emitRoot(comptime T: type, value: T, writer: anytype) Error.TomlError!void {
    switch (@typeInfo(T)) {
        .@"struct" => |struct_info| {
            var wrote_scalar = false;
            inline for (struct_info.fields) |field| {
                const field_value = @field(value, field.name);
                if (!(isTableLike(field.type) or isArrayOfTables(field.type))) {
                    try writer.print("{s} = ", .{field.name});
                    try emitValue(field.type, field_value, writer, false);
                    try writer.writeByte('\n');
                    wrote_scalar = true;
                }
            }

            inline for (struct_info.fields) |field| {
                const field_value = @field(value, field.name);
                if (isArrayOfTables(field.type)) {
                    if (wrote_scalar) try writer.writeByte('\n');
                    try emitArrayOfTables(field.name, field.type, field_value, writer);
                    wrote_scalar = true;
                } else if (isTableLike(field.type)) {
                    if (wrote_scalar) try writer.writeByte('\n');
                    try writer.print("[{s}]\n", .{field.name});
                    try emitRoot(field.type, field_value, writer);
                    wrote_scalar = true;
                }
            }
        },
        else => {
            try emitValue(T, value, writer, false);
            try writer.writeByte('\n');
        },
    }
}

fn emitArrayOfTables(name: []const u8, comptime T: type, value: T, writer: anytype) Error.TomlError!void {
    switch (@typeInfo(T)) {
        .pointer => |pointer_info| {
            for (value) |item| {
                try writer.print("[[{s}]]\n", .{name});
                try emitRoot(pointer_info.child, item, writer);
                try writer.writeByte('\n');
            }
        },
        .array => |array_info| {
            for (value) |item| {
                try writer.print("[[{s}]]\n", .{name});
                try emitRoot(array_info.child, item, writer);
                try writer.writeByte('\n');
            }
        },
        else => return error.UnsupportedType,
    }
}

fn emitValue(comptime T: type, value: T, writer: anytype, inline_mode: bool) Error.TomlError!void {
    switch (@typeInfo(T)) {
        .bool => try writer.print("{}", .{value}),
        .int => try writer.print("{}", .{value}),
        .float => try writer.print("{d}", .{value}),
        .pointer => |pointer_info| {
            if (pointer_info.size == .slice and pointer_info.child == u8) {
                try emitString(value, writer);
                return;
            }
            if (pointer_info.size == .slice) {
                try writer.writeByte('[');
                for (value, 0..) |item, index| {
                    if (index != 0) try writer.writeAll(", ");
                    try emitValue(pointer_info.child, item, writer, true);
                }
                try writer.writeByte(']');
                return;
            }
            return error.UnsupportedType;
        },
        .array => |array_info| {
            if (array_info.child == u8) {
                try emitString(value[0..], writer);
                return;
            }
            try writer.writeByte('[');
            for (value, 0..) |item, index| {
                if (index != 0) try writer.writeAll(", ");
                try emitValue(array_info.child, item, writer, true);
            }
            try writer.writeByte(']');
        },
        .optional => |optional_info| {
            if (value) |present| {
                try emitValue(optional_info.child, present, writer, inline_mode);
            } else {
                try emitString("", writer);
            }
        },
        .@"struct" => {
            if (T == ValueModel.Date) {
                try writer.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ value.year, value.month, value.day });
                return;
            }
            if (T == ValueModel.Time) {
                try writer.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ value.hour, value.minute, value.second });
                if (value.nanosecond != 0) {
                    try writer.print(".{d:0>9}", .{value.nanosecond});
                }
                return;
            }
            if (T == ValueModel.DateTime) {
                try emitValue(ValueModel.Date, value.date, writer, true);
                try writer.writeByte('T');
                try emitValue(ValueModel.Time, value.time, writer, true);
                if (value.offset_minutes) |offset| {
                    if (offset == 0) {
                        try writer.writeByte('Z');
                    } else {
                        const sign: u8 = if (offset < 0) '-' else '+';
                        const minutes = @abs(offset);
                        try writer.print("{c}{d:0>2}:{d:0>2}", .{ sign, @divTrunc(minutes, 60), @mod(minutes, 60) });
                    }
                }
                return;
            }

            if (!inline_mode or !canInlineTable(T)) return error.UnsupportedType;
            try writer.writeAll("{ ");
            inline for (@typeInfo(T).@"struct".fields, 0..) |field, index| {
                if (index != 0) try writer.writeAll(", ");
                try writer.print("{s} = ", .{field.name});
                try emitValue(field.type, @field(value, field.name), writer, true);
            }
            try writer.writeAll(" }");
        },
        else => return error.UnsupportedType,
    }
}

fn emitString(text: []const u8, writer: anytype) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x1b => try writer.writeAll("\\e"),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

fn isTableLike(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and T != ValueModel.Date and T != ValueModel.Time and T != ValueModel.DateTime;
}

fn isArrayOfTables(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer_info| pointer_info.size == .slice and isTableLike(pointer_info.child),
        .array => |array_info| isTableLike(array_info.child),
        else => false,
    };
}

fn canInlineTable(comptime T: type) bool {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (isTableLike(field.type) or isArrayOfTables(field.type)) return false;
    }
    return true;
}

test stringify {
    const Config = struct {
        title: []const u8,
        enabled: bool,
        owner: struct {
            name: []const u8,
        },
    };

    var list = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer list.deinit(std.testing.allocator);

    try stringify(Config{
        .title = "demo",
        .enabled = true,
        .owner = .{ .name = "alice" },
    }, list.writer(std.testing.allocator));

    try std.testing.expect(std.mem.indexOf(u8, list.items, "title = \"demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.items, "[owner]") != null);
}
