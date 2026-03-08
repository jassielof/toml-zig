const std = @import("std");

const toml = @import("toml");
const manifest_path = "tests/fixtures/tests/files-toml-1.1.0";
const JsonValue = std.json.Value;

test "fixtures/valid parse successfully" {
    try runFixtureManifest(true);
}

test "fixtures/invalid fail to parse" {
    try runFixtureManifest(false);
}

fn runFixtureManifest(expect_valid: bool) !void {
    const manifest = try std.fs.cwd().readFileAlloc(std.testing.allocator, manifest_path, 1024 * 1024);
    defer std.testing.allocator.free(manifest);

    var lines = std.mem.tokenizeScalar(u8, manifest, '\n');
    while (lines.next()) |line_with_maybe_cr| {
        const line = std.mem.trimRight(u8, line_with_maybe_cr, "\r");
        if (line.len == 0) continue;
        if (!std.mem.endsWith(u8, line, ".toml")) continue;

        if (expect_valid != std.mem.startsWith(u8, line, "valid/")) continue;
        if (!expect_valid and !std.mem.startsWith(u8, line, "invalid/")) continue;

        const full_path = try std.fs.path.join(std.testing.allocator, &.{ "tests/fixtures/tests", line });
        defer std.testing.allocator.free(full_path);

        const input = try std.fs.cwd().readFileAlloc(std.testing.allocator, full_path, 16 * 1024 * 1024);
        defer std.testing.allocator.free(input);

        var parser = toml.Parser.init(std.testing.allocator, input);
        const result = parser.parse();
        if (expect_valid) {
            var value = result catch |err| {
                std.debug.print("valid fixture failed: {s}\n", .{full_path});
                return err;
            };
            defer value.deinit(std.testing.allocator);

            try assertFixtureMatchesExpectedJson(full_path, line, value);
        } else {
            if (result) |value| {
                var parsed_value = value;
                defer parsed_value.deinit(std.testing.allocator);
                std.debug.print("invalid fixture parsed successfully: {s}\n", .{full_path});
                return error.TestUnexpectedResult;
            } else |err| {
                if (err != error.ParseFailed) return err;
            }
        }
    }
}

fn assertFixtureMatchesExpectedJson(full_path: []const u8, manifest_line: []const u8, value: toml.DynamicValue) !void {
    const json_relative = try std.fmt.allocPrint(std.testing.allocator, "{s}.json", .{manifest_line[0 .. manifest_line.len - 5]});
    defer std.testing.allocator.free(json_relative);

    const json_path = try std.fs.path.join(std.testing.allocator, &.{ "tests/fixtures/tests", json_relative });
    defer std.testing.allocator.free(json_path);

    const expected_json = try std.fs.cwd().readFileAlloc(std.testing.allocator, json_path, 16 * 1024 * 1024);
    defer std.testing.allocator.free(expected_json);

    const parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, expected_json, .{});
    defer parsed.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try compareTomlValueToJson(full_path, arena.allocator(), "$", value, parsed.value);
}

fn compareTomlValueToJson(fixture_path: []const u8, allocator: std.mem.Allocator, path: []const u8, actual: toml.DynamicValue, expected: JsonValue) !void {
    switch (expected) {
        .object => |expected_object| {
            if (isTaggedValueObject(expected_object)) {
                return compareTaggedScalar(fixture_path, path, actual, expected_object);
            }

            if (actual != .table) {
                return reportMismatch(fixture_path, path, "expected table");
            }
            if (actual.table.map.count() != expected_object.count()) {
                return reportMismatch(fixture_path, path, "table key count mismatch");
            }

            var iterator = expected_object.iterator();
            while (iterator.next()) |entry| {
                const key = entry.key_ptr.*;
                const child_actual = actual.table.get(key) orelse {
                    return reportMismatch(fixture_path, path, "missing table key");
                };
                const child_path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, key });
                try compareTomlValueToJson(fixture_path, allocator, child_path, child_actual, entry.value_ptr.*);
            }
        },
        .array => |expected_array| {
            if (actual != .array) {
                return reportMismatch(fixture_path, path, "expected array");
            }
            if (actual.array.items.items.len != expected_array.items.len) {
                return reportMismatch(fixture_path, path, "array length mismatch");
            }

            for (expected_array.items, 0..) |expected_item, index| {
                const child_path = try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, index });
                try compareTomlValueToJson(fixture_path, allocator, child_path, actual.array.items.items[index], expected_item);
            }
        },
        else => return reportMismatch(fixture_path, path, "unexpected JSON node"),
    }
}

fn isTaggedValueObject(object: std.json.ObjectMap) bool {
    if (object.count() != 2) return false;
    const type_value = object.get("type") orelse return false;
    const value_value = object.get("value") orelse return false;
    return type_value == .string and value_value == .string;
}

fn compareTaggedScalar(fixture_path: []const u8, path: []const u8, actual: toml.DynamicValue, expected_object: std.json.ObjectMap) !void {
    const expected_type = expected_object.get("type").?.string;
    const expected_value = expected_object.get("value").?.string;

    if (std.mem.eql(u8, expected_type, "string")) {
        if (actual != .string or !std.mem.eql(u8, actual.string.bytes, expected_value)) {
            return reportMismatch(fixture_path, path, "string mismatch");
        }
        return;
    }

    if (std.mem.eql(u8, expected_type, "integer")) {
        const parsed_expected = try std.fmt.parseInt(i64, expected_value, 10);
        if (actual != .integer or actual.integer != parsed_expected) {
            return reportMismatch(fixture_path, path, "integer mismatch");
        }
        return;
    }

    if (std.mem.eql(u8, expected_type, "bool")) {
        const parsed_expected = std.mem.eql(u8, expected_value, "true");
        if (actual != .boolean or actual.boolean != parsed_expected) {
            return reportMismatch(fixture_path, path, "bool mismatch");
        }
        return;
    }

    if (std.mem.eql(u8, expected_type, "float")) {
        return compareExpectedFloat(fixture_path, path, actual, expected_value);
    }

    if (std.mem.eql(u8, expected_type, "date-local")) {
        const expected_date = try parseExpectedDate(expected_value);
        if (actual != .date or !std.meta.eql(actual.date, expected_date)) {
            return reportMismatch(fixture_path, path, "date mismatch");
        }
        return;
    }

    if (std.mem.eql(u8, expected_type, "time-local")) {
        const expected_time = try parseExpectedTime(expected_value);
        if (actual != .time or !std.meta.eql(actual.time, expected_time)) {
            return reportMismatch(fixture_path, path, "time mismatch");
        }
        return;
    }

    if (std.mem.eql(u8, expected_type, "datetime-local")) {
        const expected_datetime = try parseExpectedDateTime(expected_value, false);
        if (actual != .datetime or !std.meta.eql(actual.datetime, expected_datetime)) {
            return reportMismatch(fixture_path, path, "local datetime mismatch");
        }
        return;
    }

    if (std.mem.eql(u8, expected_type, "datetime")) {
        const expected_datetime = try parseExpectedDateTime(expected_value, true);
        if (actual != .datetime or !std.meta.eql(actual.datetime, expected_datetime)) {
            return reportMismatch(fixture_path, path, "offset datetime mismatch");
        }
        return;
    }

    return reportMismatch(fixture_path, path, "unsupported tagged value type");
}

fn compareExpectedFloat(fixture_path: []const u8, path: []const u8, actual: toml.DynamicValue, expected_value: []const u8) !void {
    if (actual != .float) {
        return reportMismatch(fixture_path, path, "expected float");
    }

    if (std.mem.eql(u8, expected_value, "inf")) {
        if (!std.math.isInf(actual.float) or actual.float < 0) return reportMismatch(fixture_path, path, "float mismatch");
        return;
    }
    if (std.mem.eql(u8, expected_value, "-inf")) {
        if (!std.math.isInf(actual.float) or actual.float > 0) return reportMismatch(fixture_path, path, "float mismatch");
        return;
    }
    if (std.mem.eql(u8, expected_value, "nan")) {
        if (!std.math.isNan(actual.float)) return reportMismatch(fixture_path, path, "float mismatch");
        return;
    }

    const parsed_expected = try std.fmt.parseFloat(f64, expected_value);
    if (parsed_expected == 0.0 and actual.float == 0.0) {
        const expected_negative = expected_value.len > 0 and expected_value[0] == '-';
        if (std.math.signbit(parsed_expected) != std.math.signbit(actual.float) or expected_negative != std.math.signbit(actual.float)) {
            return reportMismatch(fixture_path, path, "signed zero mismatch");
        }
        return;
    }

    if (actual.float != parsed_expected) {
        return reportMismatch(fixture_path, path, "float mismatch");
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

fn reportMismatch(fixture_path: []const u8, path: []const u8, message: []const u8) error{TestUnexpectedResult} {
    std.debug.print("fixture mismatch: {s} at {s}: {s}\n", .{ fixture_path, path, message });
    return error.TestUnexpectedResult;
}
