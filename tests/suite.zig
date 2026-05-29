const std = @import("std");
const refAllDecls = std.testing.refAllDecls;

comptime {
    refAllDecls(@import("spec.zig"));
    refAllDecls(@import("basic.zig"));
}
