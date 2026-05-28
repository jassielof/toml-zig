const std = @import("std");
const toml = @import("toml");

pub fn main(init: std.process.Init) void {
    mainInner(init) catch |err| {
        const stderr_file = std.Io.File.stderr();
        var write_buf: [4096]u8 = undefined;
        var writer_struct = stderr_file.writer(init.io, &write_buf);
        _ = writer_struct.interface.print("Unexpected error: {s}\n", .{@errorName(err)}) catch {};
        _ = writer_struct.flush() catch {};
        std.process.exit(1);
    };
}

fn mainInner(init: std.process.Init) !void {
    const stdin_file = std.Io.File.stdin();
    var read_buf: [4096]u8 = undefined;
    var reader = stdin_file.reader(init.io, &read_buf);

    var input = std.ArrayList(u8).empty;
    defer input.deinit(init.gpa);

    var read_chunk: [4096]u8 = undefined;
    while (true) {
        const amt = reader.interface.readSliceShort(&read_chunk) catch |err| {
            const stderr_file = std.Io.File.stderr();
            var write_buf: [4096]u8 = undefined;
            var writer_struct = stderr_file.writer(init.io, &write_buf);
            _ = writer_struct.interface.print("Failed to read stdin: {s}\n", .{@errorName(err)}) catch {};
            _ = writer_struct.flush() catch {};
            std.process.exit(1);
        };
        if (amt == 0) break;
        input.appendSlice(init.gpa, read_chunk[0..amt]) catch |err| {
            const stderr_file = std.Io.File.stderr();
            var write_buf: [4096]u8 = undefined;
            var writer_struct = stderr_file.writer(init.io, &write_buf);
            _ = writer_struct.interface.print("Failed to append stdin buffer: {s}\n", .{@errorName(err)}) catch {};
            _ = writer_struct.flush() catch {};
            std.process.exit(1);
        };
    }

    // Parse JSON from slice
    const parsed_json = std.json.parseFromSlice(std.json.Value, init.gpa, input.items, .{}) catch |err| {
        const stderr_file = std.Io.File.stderr();
        var write_buf: [4096]u8 = undefined;
        var writer_struct = stderr_file.writer(init.io, &write_buf);
        _ = writer_struct.interface.print("JSON parsing failed: {s}\n", .{@errorName(err)}) catch {};
        _ = writer_struct.flush() catch {};
        std.process.exit(1);
    };
    defer parsed_json.deinit();

    // Convert JSON value to toml.DynamicValue
    var val_toml = jsonToToml(init.gpa, parsed_json.value) catch |err| {
        const stderr_file = std.Io.File.stderr();
        var write_buf: [4096]u8 = undefined;
        var writer_struct = stderr_file.writer(init.io, &write_buf);
        _ = writer_struct.interface.print("JSON to TOML conversion failed: {s}\n", .{@errorName(err)}) catch {};
        _ = writer_struct.flush() catch {};
        std.process.exit(1);
    };
    defer val_toml.deinit(init.gpa);

    if (val_toml != .table) {
        const stderr_file = std.Io.File.stderr();
        var write_buf: [4096]u8 = undefined;
        var writer_struct = stderr_file.writer(init.io, &write_buf);
        _ = writer_struct.interface.print("Root JSON element must be a table (JSON object)\n", .{}) catch {};
        _ = writer_struct.flush() catch {};
        std.process.exit(1);
    }

    // Output TOML to stdout
    const stdout_file = std.Io.File.stdout();
    var write_buf: [4096]u8 = undefined;
    var writer_struct = stdout_file.writer(init.io, &write_buf);

    try writeTable(&writer_struct.interface, init.gpa, &.{}, val_toml.table);
    try writer_struct.flush();
}

fn jsonToToml(allocator: std.mem.Allocator, val: std.json.Value) !toml.DynamicValue {
    switch (val) {
        .object => |obj| {
            if (obj.get("type")) |t_val| {
                if (obj.get("value")) |v_val| {
                    if (obj.count() == 2 and t_val == .string and v_val == .string) {
                        return try parseTaggedValue(allocator, t_val.string, v_val.string);
                    }
                }
            }

            const tbl = try toml.Table.create(allocator);
            errdefer {
                tbl.deinit(allocator);
                allocator.destroy(tbl);
            }

            var it = obj.iterator();
            while (it.next()) |entry| {
                const key_dup = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key_dup);

                const val_toml = try jsonToToml(allocator, entry.value_ptr.*);
                errdefer {
                    var mut_val = val_toml;
                    mut_val.deinit(allocator);
                }

                try tbl.putOwned(allocator, key_dup, val_toml);
            }

            return .{ .table = tbl };
        },
        .array => |arr| {
            const array_ptr = try allocator.create(toml.Array);
            array_ptr.* = .{ .items = .empty };
            errdefer {
                array_ptr.deinit(allocator);
                allocator.destroy(array_ptr);
            }

            for (arr.items) |item| {
                const val_toml = try jsonToToml(allocator, item);
                errdefer {
                    var mut_val = val_toml;
                    mut_val.deinit(allocator);
                }
                try array_ptr.append(allocator, val_toml);
            }

            return .{ .array = array_ptr };
        },
        else => return error.InvalidJsonFormat,
    }
}

fn parseTaggedValue(allocator: std.mem.Allocator, t_str: []const u8, v_str: []const u8) !toml.DynamicValue {
    if (std.mem.eql(u8, t_str, "string")) {
        const dup = try allocator.dupe(u8, v_str);
        return .{ .string = .{ .bytes = dup, .allocated = true } };
    } else if (std.mem.eql(u8, t_str, "integer")) {
        const parsed = try std.fmt.parseInt(i64, v_str, 10);
        return .{ .integer = parsed };
    } else if (std.mem.eql(u8, t_str, "bool")) {
        const parsed = std.mem.eql(u8, v_str, "true");
        return .{ .boolean = parsed };
    } else if (std.mem.eql(u8, t_str, "float")) {
        if (std.mem.eql(u8, v_str, "nan")) {
            return .{ .float = std.math.nan(f64) };
        } else if (std.mem.eql(u8, v_str, "inf")) {
            return .{ .float = std.math.inf(f64) };
        } else if (std.mem.eql(u8, v_str, "-inf")) {
            return .{ .float = -std.math.inf(f64) };
        } else {
            const parsed = try std.fmt.parseFloat(f64, v_str);
            return .{ .float = parsed };
        }
    } else if (std.mem.eql(u8, t_str, "date-local")) {
        const parsed = try parseExpectedDate(v_str);
        return .{ .date = parsed };
    } else if (std.mem.eql(u8, t_str, "time-local")) {
        const parsed = try parseExpectedTime(v_str);
        return .{ .time = parsed };
    } else if (std.mem.eql(u8, t_str, "datetime-local")) {
        const parsed = try parseExpectedDateTime(v_str, false);
        return .{ .datetime = parsed };
    } else if (std.mem.eql(u8, t_str, "datetime")) {
        const parsed = try parseExpectedDateTime(v_str, true);
        return .{ .datetime = parsed };
    } else {
        return error.UnsupportedTaggedValueType;
    }
}

fn parseExpectedDate(text: []const u8) !toml.Date {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return error.InvalidCharacter;
    return .{
        .year = try std.fmt.parseInt(i32, text[0..4], 10),
        .month = try std.fmt.parseInt(u8, text[5..7], 10),
        .day = try std.fmt.parseInt(u8, text[8..10], 10),
    };
}

fn parseExpectedTime(text: []const u8) !toml.Time {
    if (text.len < 8 or text[2] != ':' or text[5] != ':') return error.InvalidCharacter;
    var time: toml.Time = .{
        .hour = try std.fmt.parseInt(u8, text[0..2], 10),
        .minute = try std.fmt.parseInt(u8, text[3..5], 10),
        .second = try std.fmt.parseInt(u8, text[6..8], 10),
    };

    if (text.len == 8) return time;
    if (text[8] != '.') return error.InvalidCharacter;

    const frac = text[9..];
    if (frac.len == 0 or frac.len > 9) return error.InvalidCharacter;
    const parsed = try std.fmt.parseInt(u32, frac, 10);
    const scale = std.math.pow(u32, 10, @intCast(9 - frac.len));
    time.nanosecond = parsed * scale;
    return time;
}

fn parseExpectedDateTime(text: []const u8, expect_offset: bool) !toml.DateTime {
    const separator = std.mem.indexOfScalar(u8, text, 'T') orelse return error.InvalidCharacter;
    const date = try parseExpectedDate(text[0..separator]);
    const rest = text[separator + 1 ..];

    if (expect_offset) {
        if (rest.len == 0) return error.InvalidCharacter;
        if (rest[rest.len - 1] == 'Z') {
            return .{ .date = date, .time = try parseExpectedTime(rest[0 .. rest.len - 1]), .offset_minutes = 0 };
        }

        var offset_index: ?usize = null;
        for (rest, 0..) |byte, index| {
            if (index == 0) continue;
            if (byte == '+' or byte == '-') {
                offset_index = index;
                break;
            }
        }
        const index = offset_index orelse return error.InvalidCharacter;
        const sign: i16 = if (rest[index] == '+') 1 else -1;
        if (index + 6 != rest.len or rest[index + 3] != ':') return error.InvalidCharacter;
        const hours = try std.fmt.parseInt(i16, rest[index + 1 .. index + 3], 10);
        const minutes = try std.fmt.parseInt(i16, rest[index + 4 .. index + 6], 10);
        return .{
            .date = date,
            .time = try parseExpectedTime(rest[0..index]),
            .offset_minutes = sign * (hours * 60 + minutes),
        };
    }

    return .{ .date = date, .time = try parseExpectedTime(rest), .offset_minutes = null };
}

fn isComplexValue(val: toml.DynamicValue) bool {
    switch (val) {
        .table => return true,
        .array => |arr| return isArrayOfTables(arr),
        else => return false,
    }
}

fn isArrayOfTables(arr: *toml.Array) bool {
    if (arr.items.items.len == 0) return false;
    for (arr.items.items) |item| {
        if (item != .table) return false;
    }
    return true;
}

fn writeKey(writer: anytype, key: []const u8) !void {
    if (isBareKey(key)) {
        try writer.writeAll(key);
    } else {
        try std.json.Stringify.value(key, .{}, writer);
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

fn writePath(writer: anytype, path: []const []const u8) !void {
    for (path, 0..) |part, idx| {
        if (idx > 0) try writer.writeByte('.');
        try writeKey(writer, part);
    }
}

fn writeTable(writer: anytype, allocator: std.mem.Allocator, path: []const []const u8, table: *toml.Table) !void {
    var it = table.map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;

        if (!isComplexValue(val)) {
            try writeKey(writer, key);
            try writer.writeAll(" = ");
            try writeInlineValue(writer, val);
            try writer.writeByte('\n');
        }
    }

    it = table.map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;

        if (val == .table) {
            try writer.writeByte('\n');

            var new_path = try allocator.alloc([]const u8, path.len + 1);
            defer allocator.free(new_path);
            @memcpy(new_path[0..path.len], path);
            new_path[path.len] = key;

            try writer.writeByte('[');
            try writePath(writer, new_path);
            try writer.writeAll("]\n");

            try writeTable(writer, allocator, new_path, val.table);
        }
    }

    it = table.map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;

        if (val == .array and isArrayOfTables(val.array)) {
            var new_path = try allocator.alloc([]const u8, path.len + 1);
            defer allocator.free(new_path);
            @memcpy(new_path[0..path.len], path);
            new_path[path.len] = key;

            for (val.array.items.items) |elem| {
                try writer.writeByte('\n');
                try writer.writeAll("[[");
                try writePath(writer, new_path);
                try writer.writeAll("]]\n");

                try writeTable(writer, allocator, new_path, elem.table);
            }
        }
    }
}

fn writeInlineValue(writer: anytype, val: toml.DynamicValue) !void {
    switch (val) {
        .string => |str| {
            try std.json.Stringify.value(str.bytes, .{}, writer);
        },
        .integer => |i| {
            try writer.print("{d}", .{i});
        },
        .float => |f| {
            if (std.math.isNan(f)) {
                try writer.writeAll("nan");
            } else if (std.math.isInf(f)) {
                if (f < 0) {
                    try writer.writeAll("-inf");
                } else {
                    try writer.writeAll("inf");
                }
            } else {
                var buf: [64]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "{d}", .{f});
                try writer.writeAll(s);
                if (std.mem.indexOfAny(u8, s, ".eE") == null) {
                    try writer.writeAll(".0");
                }
            }
        },
        .boolean => |b| {
            try writer.writeAll(if (b) "true" else "false");
        },
        .date => |date| {
            try writer.print("{d:04}-{d:02}-{d:02}", .{@as(u32, @intCast(date.year)), date.month, date.day});
        },
        .time => |time| {
            if (time.nanosecond == 0) {
                try writer.print("{d:02}:{d:02}:{d:02}", .{time.hour, time.minute, time.second});
            } else {
                var nano_buf: [16]u8 = undefined;
                const nano_s = try std.fmt.bufPrint(&nano_buf, "{d:09}", .{time.nanosecond});
                const trimmed = std.mem.trimEnd(u8, nano_s, "0");
                try writer.print("{d:02}:{d:02}:{d:02}.{s}", .{time.hour, time.minute, time.second, trimmed});
            }
        },
        .datetime => |dt| {
            try writer.print("{d:04}-{d:02}-{d:02}T", .{@as(u32, @intCast(dt.date.year)), dt.date.month, dt.date.day});
            if (dt.time.nanosecond == 0) {
                try writer.print("{d:02}:{d:02}:{d:02}", .{dt.time.hour, dt.time.minute, dt.time.second});
            } else {
                var nano_buf: [16]u8 = undefined;
                const nano_s = try std.fmt.bufPrint(&nano_buf, "{d:09}", .{dt.time.nanosecond});
                const trimmed = std.mem.trimEnd(u8, nano_s, "0");
                try writer.print("{d:02}:{d:02}:{d:02}.{s}", .{dt.time.hour, dt.time.minute, dt.time.second, trimmed});
            }
            if (dt.offset_minutes) |offset| {
                if (offset == 0) {
                    try writer.writeByte('Z');
                } else {
                    const sign: u8 = if (offset > 0) '+' else '-';
                    const abs_offset = @abs(offset);
                    const hours = abs_offset / 60;
                    const mins = abs_offset % 60;
                    try writer.print("{c}{d:02}:{d:02}", .{sign, hours, mins});
                }
            }
        },
        .array => |arr| {
            try writer.writeByte('[');
            for (arr.items.items, 0..) |item, idx| {
                if (idx > 0) try writer.writeAll(", ");
                try writeInlineValue(writer, item);
            }
            try writer.writeByte(']');
        },
        .table => return error.TableCannotBeInline,
    }
}
