const std = @import("std");
const toml = @import("toml");

pub fn main(init: std.process.Init) void {
    mainInner(init) catch |err| {
        // If standard error is still writable, log the error. Otherwise, exit silently.
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

    if (toml.parseValue(init.gpa, input.items)) |parsed_val| {
        var mut_val = parsed_val;
        defer mut_val.deinit(init.gpa);

        const stdout_file = std.Io.File.stdout();
        var write_buf: [4096]u8 = undefined;
        var writer_struct = stdout_file.writer(init.io, &write_buf);

        try writeValue(&writer_struct.interface, mut_val);
        try writer_struct.flush();
    } else |err| {
        const stderr_file = std.Io.File.stderr();
        var write_buf: [4096]u8 = undefined;
        var writer_struct = stderr_file.writer(init.io, &write_buf);

        _ = writer_struct.interface.print("TOML parsing failed: {s}\n", .{@errorName(err)}) catch {};
        _ = writer_struct.flush() catch {};
        std.process.exit(1);
    }
}

fn writeValue(writer: *std.Io.Writer, val: toml.DynamicValue) !void {
    switch (val) {
        .string => |str| {
            try writer.writeAll("{\"type\":\"string\",\"value\":");
            try std.json.Stringify.value(str.bytes, .{}, writer);
            try writer.writeAll("}");
        },
        .integer => |i| {
            try writer.writeAll("{\"type\":\"integer\",\"value\":\"");
            try writer.print("{d}", .{i});
            try writer.writeAll("\"}");
        },
        .float => |f| {
            if (std.math.isNan(f)) {
                try writer.writeAll("{\"type\":\"float\",\"value\":\"nan\"}");
            } else if (std.math.isInf(f)) {
                if (f < 0) {
                    try writer.writeAll("{\"type\":\"float\",\"value\":\"-inf\"}");
                } else {
                    try writer.writeAll("{\"type\":\"float\",\"value\":\"inf\"}");
                }
            } else {
                var buf: [64]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "{d}", .{f});
                try writer.writeAll("{\"type\":\"float\",\"value\":\"");
                try writer.writeAll(s);
                try writer.writeAll("\"}");
            }
        },
        .boolean => |b| {
            const s = if (b) "true" else "false";
            try writer.print("{{\"type\":\"bool\",\"value\":\"{s}\"}}", .{s});
        },
        .date => |date| {
            var buf: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d:04}-{d:02}-{d:02}", .{@as(u32, @intCast(date.year)), date.month, date.day});
            try writer.writeAll("{\"type\":\"date-local\",\"value\":\"");
            try writer.writeAll(s);
            try writer.writeAll("\"}");
        },
        .time => |time| {
            var buf: [64]u8 = undefined;
            const s = if (time.nanosecond == 0)
                try std.fmt.bufPrint(&buf, "{d:02}:{d:02}:{d:02}", .{time.hour, time.minute, time.second})
            else l: {
                var nano_buf: [16]u8 = undefined;
                const nano_s = try std.fmt.bufPrint(&nano_buf, "{d:09}", .{time.nanosecond});
                const trimmed = std.mem.trimEnd(u8, nano_s, "0");
                break :l try std.fmt.bufPrint(&buf, "{d:02}:{d:02}:{d:02}.{s}", .{time.hour, time.minute, time.second, trimmed});
            };
            try writer.writeAll("{\"type\":\"time-local\",\"value\":\"");
            try writer.writeAll(s);
            try writer.writeAll("\"}");
        },
        .datetime => |dt| {
            var buf: [64]u8 = undefined;
            var f_buf: [128]u8 = undefined;

            const time_str = if (dt.time.nanosecond == 0)
                try std.fmt.bufPrint(&buf, "{d:02}:{d:02}:{d:02}", .{dt.time.hour, dt.time.minute, dt.time.second})
            else l: {
                var nano_buf: [16]u8 = undefined;
                const nano_s = try std.fmt.bufPrint(&nano_buf, "{d:09}", .{dt.time.nanosecond});
                const trimmed = std.mem.trimEnd(u8, nano_s, "0");
                break :l try std.fmt.bufPrint(&buf, "{d:02}:{d:02}:{d:02}.{s}", .{dt.time.hour, dt.time.minute, dt.time.second, trimmed});
            };

            if (dt.offset_minutes) |offset| {
                var offset_buf: [16]u8 = undefined;
                const offset_str = if (offset == 0)
                    "Z"
                else l: {
                    const sign: u8 = if (offset > 0) '+' else '-';
                    const abs_offset = @abs(offset);
                    const hours = abs_offset / 60;
                    const mins = abs_offset % 60;
                    break :l try std.fmt.bufPrint(&offset_buf, "{c}{d:02}:{d:02}", .{sign, hours, mins});
                };

                const s = try std.fmt.bufPrint(&f_buf, "{d:04}-{d:02}-{d:02}T{s}{s}", .{
                    @as(u32, @intCast(dt.date.year)), dt.date.month, dt.date.day,
                    time_str,
                    offset_str,
                });
                try writer.writeAll("{\"type\":\"datetime\",\"value\":\"");
                try writer.writeAll(s);
                try writer.writeAll("\"}");
            } else {
                const s = try std.fmt.bufPrint(&f_buf, "{d:04}-{d:02}-{d:02}T{s}", .{
                    @as(u32, @intCast(dt.date.year)), dt.date.month, dt.date.day,
                    time_str,
                });
                try writer.writeAll("{\"type\":\"datetime-local\",\"value\":\"");
                try writer.writeAll(s);
                try writer.writeAll("\"}");
            }
        },
        .array => |arr| {
            try writer.writeAll("[");
            for (arr.items.items, 0..) |item, idx| {
                if (idx > 0) try writer.writeAll(",");
                try writeValue(writer, item);
            }
            try writer.writeAll("]");
        },
        .table => |tbl| {
            try writer.writeAll("{");
            var iterator = tbl.map.iterator();
            var idx: usize = 0;
            while (iterator.next()) |entry| {
                if (idx > 0) try writer.writeAll(",");
                try std.json.Stringify.value(entry.key_ptr.*, .{}, writer);
                try writer.writeAll(":");
                try writeValue(writer, entry.value_ptr.*);
                idx += 1;
            }
            try writer.writeAll("}");
        },
    }
}
