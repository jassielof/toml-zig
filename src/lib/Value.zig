const std = @import("std");

/// String storage used by the dynamic TOML model.
pub const String = struct {
    bytes: []const u8,
    allocated: bool = false,

    /// Returns the underlying UTF-8 slice.
    pub fn slice(self: String) []const u8 {
        return self.bytes;
    }
};

/// TOML local date.
pub const Date = struct {
    year: i32,
    month: u8,
    day: u8,
};

/// TOML local time.
pub const Time = struct {
    hour: u8,
    minute: u8,
    second: u8,
    nanosecond: u32 = 0,
};

/// TOML date-time, optionally including an offset in minutes.
pub const DateTime = struct {
    date: Date,
    time: Time,
    offset_minutes: ?i16 = null,
};

/// Dynamic representation of any TOML value.
pub const Value = union(enum) {
    string: String,
    integer: i64,
    float: f64,
    boolean: bool,
    date: Date,
    time: Time,
    datetime: DateTime,
    array: *Array,
    table: *Table,

    /// Returns the string bytes when this value is a TOML string.
    pub fn stringSlice(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |value| value.bytes,
            else => null,
        };
    }

    /// Releases all memory owned by this value and its descendants.
    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |string_value| {
                if (string_value.allocated) {
                    allocator.free(string_value.bytes);
                }
            },
            .array => |array_value| {
                array_value.deinit(allocator);
                allocator.destroy(array_value);
            },
            .table => |table_value| {
                table_value.deinit(allocator);
                allocator.destroy(table_value);
            },
            else => {},
        }
    }
};

/// Dynamic TOML array.
pub const Array = struct {
    items: std.ArrayListUnmanaged(Value) = .{},
    table_array: bool = false,

    /// Appends a value to the array.
    pub fn append(self: *Array, allocator: std.mem.Allocator, value: Value) !void {
        try self.items.append(allocator, value);
    }

    /// Releases the array contents and any nested allocations.
    pub fn deinit(self: *Array, allocator: std.mem.Allocator) void {
        for (self.items.items) |*item| {
            item.deinit(allocator);
        }
        self.items.deinit(allocator);
    }
};

/// Dynamic TOML table backed by a string-key hash map.
pub const Table = struct {
    map: std.StringArrayHashMapUnmanaged(Value) = .{},
    defined: bool = false,
    implicit: bool = false,
    dotted: bool = false,
    sealed: bool = false,

    /// Allocates and initializes an empty table.
    pub fn create(allocator: std.mem.Allocator) !*Table {
        const table = try allocator.create(Table);
        table.* = .{};
        return table;
    }

    /// Returns the value stored for `key`, if present.
    pub fn get(self: *const Table, key: []const u8) ?Value {
        return self.map.get(key);
    }

    /// Returns a mutable pointer to the value stored for `key`, if present.
    pub fn getPtr(self: *Table, key: []const u8) ?*Value {
        return self.map.getPtr(key);
    }

    /// Inserts a key/value pair where the key memory is already owned by the caller.
    pub fn putOwned(self: *Table, allocator: std.mem.Allocator, key: []const u8, value: Value) !void {
        try self.map.put(allocator, key, value);
    }

    /// Releases the table, its keys, and all nested values.
    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        var iterator = self.map.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.map.deinit(allocator);
    }
};

test Value {
    var table = try Table.create(std.testing.allocator);
    defer {
        var root = Value{ .table = table };
        root.deinit(std.testing.allocator);
    }

    try table.putOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, "name"), .{
        .string = .{ .bytes = try std.testing.allocator.dupe(u8, "demo"), .allocated = true },
    });

    try std.testing.expectEqualStrings("demo", table.get("name").?.string.bytes);
}
