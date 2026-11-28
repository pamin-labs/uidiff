//! Dimensions shared by the JPEG, PNG and WebP bindings.
const std = @import("std");
const value = @import("../value.zig");

/// A decoder probe that needs only the image dimensions.
pub const Header = struct { size: value.Size };

/// Converts signed decoder dimensions. The registry checks the image limits.
pub fn fromC(width: c_int, height: c_int) value.Image.Invalid!value.Size {
    return .{
        .width = std.math.cast(usize, width) orelse return error.InvalidImage,
        .height = std.math.cast(usize, height) orelse return error.InvalidImage,
    };
}

test "decoder dimensions reject either negative axis" {
    try std.testing.expectError(error.InvalidImage, fromC(-1, 1));
    try std.testing.expectError(error.InvalidImage, fromC(1, -1));
    try std.testing.expectEqual(value.Size{ .width = 30, .height = 40 }, try fromC(30, 40));
}

test {
    std.testing.refAllDecls(@This());
}
