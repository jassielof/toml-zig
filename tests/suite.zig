const std = @import("std");

comptime {
    _ = @import("spec.zig");
    _ = @import("basic.zig");
}

test {
    std.testing.refAllDecls(@This());
}
