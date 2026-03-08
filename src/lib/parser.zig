const std = @import("std");

pub fn multiply(a: i32, b: i32) i32 {
    return a * b;
}

test multiply {
    try std.testing.expect(multiply(3, 7) == 21);
}
