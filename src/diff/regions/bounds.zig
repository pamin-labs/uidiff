//! Device-pixel bounds shared by region rules.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("../../value.zig");
const Box = value.Box;

/// Selects the horizontal or vertical coordinate order.
pub const RailAxis = enum { horizontal, vertical };

/// Selects the start or end edge along an axis.
pub const RailEnd = enum { start, end };

/// Exclusive device-pixel bounds for a rectangular pixel run.
pub const PixelRect = struct {
    left: usize,
    right: usize,
    top: usize,
    bottom: usize,

    /// Returns bounds expressed along the selected axis.
    pub fn oriented(self: PixelRect, axis: RailAxis) PixelRect {
        return if (axis == .horizontal) self else .{
            .left = self.top,
            .right = self.bottom,
            .top = self.left,
            .bottom = self.right,
        };
    }

    /// Converts device-pixel box edges into integer bounds.
    pub fn fromBox(box: Box) PixelRect {
        return .{ .left = deviceIndex(box.x), .right = deviceIndex(box.right()), .top = deviceIndex(box.y), .bottom = deviceIndex(box.bottom()) };
    }
};

/// Converts a validated device coordinate to a pixel index.
pub const deviceIndex = if (builtin.cpu.arch == .x86_64) sharedDeviceIndex else directDeviceIndex;

inline fn directDeviceIndex(coordinate: f64) usize {
    return @intFromFloat(coordinate);
}

noinline fn sharedDeviceIndex(coordinate: f64) usize {
    return directDeviceIndex(coordinate);
}

test {
    std.testing.refAllDecls(@This());
}
