//! Reflection-based TOML serializer for Zig values.

const std = @import("std");
const Error = @import("Error.zig");
const ValueModel = @import("value.zig");

/// Serializes a Zig value as TOML using the provided writer.
pub fn stringify(value: anytype, writer: *std.Io.Writer) !void {
    try emitRoot(@TypeOf(value), value, writer);
}

fn emitRoot(comptime T: type, value: T, writer: *std.Io.Writer) anyerror!void {
    if (T == ValueModel.Value) {
        switch (value) {
            .table => |tbl| return emitRoot(ValueModel.Table, tbl.*, writer),
            else => return error.UnsupportedType,
        }
    }
    if (T == *ValueModel.Table) {
        return emitRoot(ValueModel.Table, value.*, writer);
    }
    if (T == ValueModel.Table) {
        var wrote_scalar = false;
        var it = value.map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            if (!isDynamicComplex(val)) {
                try writeKey(writer, key);
                try writer.writeAll(" = ");
                try emitDynamicValue(val, writer, false);
                try writer.writeByte('\n');
                wrote_scalar = true;
            }
        }

        it = value.map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            if (val == .array and isDynamicArrayOfTables(val.array)) {
                if (wrote_scalar) try writer.writeByte('\n');
                try emitDynamicArrayOfTables(key, val.array, writer);
                wrote_scalar = true;
            } else if (val == .table) {
                if (wrote_scalar) try writer.writeByte('\n');
                try writer.writeByte('[');
                try writeKey(writer, key);
                try writer.writeAll("]\n");
                try emitRoot(ValueModel.Table, val.table.*, writer);
                wrote_scalar = true;
            }
        }
        return;
    }

    switch (@typeInfo(T)) {
        .@"struct" => |struct_info| {
            var wrote_scalar = false;
            inline for (struct_info.field_names, struct_info.field_types) |field_name, FieldType| {
                const field_value = @field(value, field_name);
                if (!(isTableLike(FieldType) or isArrayOfTables(FieldType))) {
                    try writeKey(writer, field_name);
                    try writer.writeAll(" = ");
                    try emitValue(FieldType, field_value, writer, false);
                    try writer.writeByte('\n');
                    wrote_scalar = true;
                }
            }

            inline for (struct_info.field_names, struct_info.field_types) |field_name, FieldType| {
                const field_value = @field(value, field_name);
                if (isArrayOfTables(FieldType)) {
                    if (wrote_scalar) try writer.writeByte('\n');
                    try emitArrayOfTables(field_name, FieldType, field_value, writer);
                    wrote_scalar = true;
                } else if (isTableLike(FieldType)) {
                    if (wrote_scalar) try writer.writeByte('\n');
                    try writer.writeByte('[');
                    try writeKey(writer, field_name);
                    try writer.writeAll("]\n");
                    try emitRoot(FieldType, field_value, writer);
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

fn emitArrayOfTables(name: []const u8, comptime T: type, value: T, writer: *std.Io.Writer) !void {
    switch (@typeInfo(T)) {
        .pointer => |pointer_info| {
            for (value) |item| {
                try writer.writeAll("[[");
                try writeKey(writer, name);
                try writer.writeAll("]]\n");
                try emitRoot(pointer_info.child, item, writer);
                try writer.writeByte('\n');
            }
        },
        .array => |array_info| {
            for (value) |item| {
                try writer.writeAll("[[");
                try writeKey(writer, name);
                try writer.writeAll("]]\n");
                try emitRoot(array_info.child, item, writer);
                try writer.writeByte('\n');
            }
        },
        else => return error.UnsupportedType,
    }
}

fn emitValue(comptime T: type, value: T, writer: *std.Io.Writer, inline_mode: bool) !void {
    switch (@typeInfo(T)) {
        .bool => try writer.print("{}", .{value}),
        .int => try writer.print("{}", .{value}),
        .float => try emitFloat(value, writer),
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
            const info = @typeInfo(T).@"struct";
            inline for (info.field_names, info.field_types, 0..) |field_name, FieldType, index| {
                if (index != 0) try writer.writeAll(", ");
                try writeKey(writer, field_name);
                try writer.writeAll(" = ");
                try emitValue(FieldType, @field(value, field_name), writer, true);
            }
            try writer.writeAll(" }");
        },
        .@"union" => |union_info| {
            if (T == ValueModel.Value) {
                try emitDynamicValue(value, writer, inline_mode);
                return;
            }
            if (union_info.tag_type) |_| {
                // If it's another tagged union, we don't support it by default unless it's ValueModel.Value
                return error.UnsupportedType;
            }
            return error.UnsupportedType;
        },
        else => return error.UnsupportedType,
    }
}

fn emitString(text: []const u8, writer: *std.Io.Writer) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f, 0x7f => {
                try writer.print("\\u{X:0>4}", .{byte});
            },
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

fn emitFloat(value: anytype, writer: *std.Io.Writer) !void {
    if (std.math.isNan(value)) {
        try writer.writeAll("nan");
        return;
    }
    if (std.math.isInf(value)) {
        try writer.writeAll(if (value < 0) "-inf" else "inf");
        return;
    }
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try writer.writeAll(s);
    if (std.mem.indexOfAny(u8, s, ".eE") == null) {
        try writer.writeAll(".0");
    }
}

fn isBareKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

fn writeKey(writer: *std.Io.Writer, key: []const u8) !void {
    if (isBareKey(key)) {
        try writer.writeAll(key);
    } else {
        try emitString(key, writer);
    }
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
    inline for (@typeInfo(T).@"struct".field_types) |FieldType| {
        if (isTableLike(FieldType) or isArrayOfTables(FieldType)) return false;
    }
    return true;
}

fn isDynamicComplex(val: ValueModel.Value) bool {
    return val == .table or (val == .array and isDynamicArrayOfTables(val.array));
}

fn isDynamicArrayOfTables(arr: *ValueModel.Array) bool {
    if (arr.items.items.len == 0) return false;
    for (arr.items.items) |item| {
        if (item != .table) return false;
    }
    return true;
}

fn emitDynamicArrayOfTables(name: []const u8, arr: *ValueModel.Array, writer: *std.Io.Writer) anyerror!void {
    for (arr.items.items) |item| {
        try writer.writeAll("[[");
        try writeKey(writer, name);
        try writer.writeAll("]]\n");
        try emitRoot(ValueModel.Table, item.table.*, writer);
        try writer.writeByte('\n');
    }
}

fn emitDynamicValue(val: ValueModel.Value, writer: *std.Io.Writer, inline_mode: bool) anyerror!void {
    switch (val) {
        .boolean => |b| try writer.print("{}", .{b}),
        .integer => |i| try writer.print("{}", .{i}),
        .float => |f| try emitFloat(f, writer),
        .string => |str| try emitString(str.bytes, writer),
        .date => |d| try emitValue(ValueModel.Date, d, writer, inline_mode),
        .time => |t| try emitValue(ValueModel.Time, t, writer, inline_mode),
        .datetime => |dt| try emitValue(ValueModel.DateTime, dt, writer, inline_mode),
        .array => |arr| {
            try writer.writeByte('[');
            for (arr.items.items, 0..) |item, index| {
                if (index != 0) try writer.writeAll(", ");
                try emitDynamicValue(item, writer, true);
            }
            try writer.writeByte(']');
        },
        .table => |tbl| {
            if (!inline_mode or !canInlineDynamicTable(tbl)) return error.UnsupportedType;
            try writer.writeAll("{ ");
            var it = tbl.map.iterator();
            var index: usize = 0;
            while (it.next()) |entry| {
                if (index != 0) try writer.writeAll(", ");
                try writeKey(writer, entry.key_ptr.*);
                try writer.writeAll(" = ");
                try emitDynamicValue(entry.value_ptr.*, writer, true);
                index += 1;
            }
            try writer.writeAll(" }");
        },
    }
}

fn canInlineDynamicTable(tbl: *ValueModel.Table) bool {
    var it = tbl.map.iterator();
    while (it.next()) |entry| {
        if (isDynamicComplex(entry.value_ptr.*)) return false;
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

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    try stringify(Config{
        .title = "demo",
        .enabled = true,
        .owner = .{ .name = "alice" },
    }, &aw.writer);

    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "title = \"demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "[owner]") != null);
}

test "whole-number floats serialize distinguishably from integers" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    try stringify(@as(f64, 3.0), &aw.writer);
    try std.testing.expectEqualStrings("3.0\n", aw.written());
}

test "non-bare-key struct fields are quoted" {
    const Config = struct {
        @"with space": bool,
    };

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    try stringify(Config{ .@"with space" = true }, &aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"with space\" = true") != null);
}
