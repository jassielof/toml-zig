const std = @import("std");
const Error = @import("Error.zig");
const Parser = @import("Parser.zig");
const ValueModel = @import("Value.zig");

const Value = ValueModel.Value;

pub fn parse(comptime T: type, allocator: std.mem.Allocator, input: []const u8) Error.TomlError!T {
    var parser = Parser.init(allocator, input);
    var value = try parser.parse();
    defer value.deinit(allocator);
    return convert(T, allocator, value);
}

pub fn convert(comptime T: type, allocator: std.mem.Allocator, value: Value) Error.TomlError!T {
    switch (@typeInfo(T)) {
        .bool => return expectTag(T, value, .boolean),
        .int => return try convertInt(T, value),
        .float => return try convertFloat(T, value),
        .pointer => |pointer_info| return convertPointer(T, allocator, pointer_info, value),
        .array => |array_info| return convertFixedArray(T, allocator, array_info, value),
        .optional => |optional_info| return convertOptional(T, allocator, optional_info.child, value),
        .@"struct" => return convertStruct(T, allocator, value),
        else => return error.UnsupportedType,
    }
}

fn expectTag(comptime T: type, value: Value, comptime tag: std.meta.Tag(Value)) Error.TomlError!T {
    if (value != tag) return error.TypeMismatch;
    return @field(value, @tagName(tag));
}

fn convertInt(comptime T: type, value: Value) Error.TomlError!T {
    const integer_value: i64 = switch (value) {
        .integer => |integer_value| integer_value,
        else => return error.TypeMismatch,
    };
    return std.math.cast(T, integer_value) orelse error.Overflow;
}

fn convertFloat(comptime T: type, value: Value) Error.TomlError!T {
    return switch (value) {
        .float => |float_value| @floatCast(float_value),
        .integer => |integer_value| @floatFromInt(integer_value),
        else => error.TypeMismatch,
    };
}

fn convertPointer(comptime T: type, allocator: std.mem.Allocator, pointer_info: std.builtin.Type.Pointer, value: Value) Error.TomlError!T {
    if (pointer_info.size == .slice and pointer_info.child == u8) {
        const text = switch (value) {
            .string => |string_value| string_value.bytes,
            else => return error.TypeMismatch,
        };
        const duped = try allocator.dupe(u8, text);
        if (pointer_info.is_const) {
            return duped;
        }
        return duped;
    }

    if (pointer_info.size != .slice) {
        return error.UnsupportedType;
    }

    const array_value = switch (value) {
        .array => |array_value| array_value,
        else => return error.TypeMismatch,
    };

    const out = try allocator.alloc(pointer_info.child, array_value.items.items.len);
    for (array_value.items.items, 0..) |item, index| {
        out[index] = try convert(pointer_info.child, allocator, item);
    }
    return out;
}

fn convertFixedArray(comptime T: type, allocator: std.mem.Allocator, array_info: std.builtin.Type.Array, value: Value) Error.TomlError!T {
    const array_value = switch (value) {
        .array => |array_value| array_value,
        else => return error.TypeMismatch,
    };
    if (array_value.items.items.len != array_info.len) return error.TypeMismatch;

    var result: T = undefined;
    for (array_value.items.items, 0..) |item, index| {
        result[index] = try convert(array_info.child, allocator, item);
    }
    return result;
}

fn convertOptional(comptime T: type, allocator: std.mem.Allocator, child: type, value: Value) Error.TomlError!T {
    return try convert(child, allocator, value);
}

fn convertStruct(comptime T: type, allocator: std.mem.Allocator, value: Value) Error.TomlError!T {
    if (T == ValueModel.Date) {
        return switch (value) {
            .date => |date_value| date_value,
            else => error.TypeMismatch,
        };
    }
    if (T == ValueModel.Time) {
        return switch (value) {
            .time => |time_value| time_value,
            else => error.TypeMismatch,
        };
    }
    if (T == ValueModel.DateTime) {
        return switch (value) {
            .datetime => |datetime_value| datetime_value,
            else => error.TypeMismatch,
        };
    }

    const table_value = switch (value) {
        .table => |table_value| table_value,
        else => return error.TypeMismatch,
    };

    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (table_value.get(field.name)) |field_value| {
            @field(result, field.name) = try convert(field.type, allocator, field_value);
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        } else if (field.defaultValue()) |default_value| {
            @field(result, field.name) = default_value;
        } else {
            return error.MissingField;
        }
    }
    return result;
}

test parse {
    const Config = struct {
        title: []const u8,
        enabled: bool,
        ports: []i64,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try parse(Config, arena.allocator(),
        \\title = "demo"
        \\enabled = true
        \\ports = [8000, 8001]
    );

    try std.testing.expectEqualStrings("demo", config.title);
    try std.testing.expect(config.enabled);
    try std.testing.expectEqual(@as(usize, 2), config.ports.len);
}
