//! Device-pixel bounds shared by region rules.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("../../value.zig");
const Box = value.Box;

/// Selects the horizontal or vertical coordinate order.
pub const RailAxis = enum { horizontal, vertical };

/// Selects the start or end edge along an axis.
pub const RailEnd = enum { start, end };

/// Converts a validated device coordinate to a pixel index.
pub const deviceIndex = if (builtin.cpu.arch == .x86_64) sharedDeviceIndex else directDeviceIndex;

/// Converts validated device-pixel box edges into integer bounds.
pub fn pixelRect(box: Box) value.PixelRect {
    const x = deviceIndex(box.x);
    const y = deviceIndex(box.y);
    return .{ .x = x, .y = y, .width = deviceIndex(box.right()) - x, .height = deviceIndex(box.bottom()) - y };
}

inline fn directDeviceIndex(coordinate: f64) usize {
    return @intFromFloat(coordinate);
}

noinline fn sharedDeviceIndex(coordinate: f64) usize {
    return directDeviceIndex(coordinate);
}

test {
    std.testing.refAllDecls(@This());
}
