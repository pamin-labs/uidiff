//! Rectangles and region values shared by comparison, drawing, and transport.
const std = @import("std");

const PixelSpace = enum { device, sheet };

/// A rectangle in source device pixels.
pub const Box = struct {
    /// Left edge.
    x: f64,
    /// Top edge.
    y: f64,
    /// Width.
    width: f64,
    /// Height.
    height: f64,

    const Self = @This();

    /// Builds a rectangle from integer pixel coordinates.
    pub fn fromPixels(x: usize, y: usize, width: usize, height: usize) Self {
        return .{ .x = @floatFromInt(x), .y = @floatFromInt(y), .width = @floatFromInt(width), .height = @floatFromInt(height) };
    }

    /// Returns the exclusive right edge.
    pub fn right(self: Self) f64 {
        return self.x + self.width;
    }

    /// Returns the exclusive bottom edge.
    pub fn bottom(self: Self) f64 {
        return self.y + self.height;
    }

    /// Returns the intersection area in square pixels.
    pub fn overlap(self: Self, other: Self) f64 {
        return @max(0, @min(self.right(), other.right()) - @max(self.x, other.x)) *
            @max(0, @min(self.bottom(), other.bottom()) - @max(self.y, other.y));
    }

    /// Returns the squared gap between two rectangles.
    pub fn distanceSquared(self: Self, other: Self) f64 {
        const dx = @max(0, other.x - self.right(), self.x - other.right());
        const dy = @max(0, other.y - self.bottom(), self.y - other.bottom());
        return dx * dx + dy * dy;
    }
};

/// Which side contains the difference. Non-exhaustive, so a later release
/// may add a kind (a moved block, say) without breaking callers; a switch
/// over it handles the three known kinds and `_`.
pub const Kind = enum(u8) { inserted, removed, changed, _ };

/// Selects the source image for a region or annotation. Exhaustive: a
/// comparison has exactly two images.
pub const Side = enum { before, after };

/// One aligned row range in device pixels.
pub const RowRange = PixelRows(.device);
/// One preview row range in sheet pixels.
pub const SheetRowRange = PixelRows(.sheet);
/// A horizontal position or extent in source device pixels.
pub const DevicePx = enum(usize) {
    _,

    /// Wraps a whole-pixel count in source coordinates.
    pub fn init(count_: usize) DevicePx {
        return @fromBackingInt(@intCast(count_));
    }

    /// Unwraps the whole-pixel count for indexing or transport.
    pub fn count(self: DevicePx) usize {
        return @backingInt(self);
    }
};

/// A block aligned at different vertical positions, within the given columns.
pub const Move = struct {
    before: RowRange,
    after: RowRange,
    x: DevicePx,
    width: DevicePx,

    /// Returns the absolute vertical displacement in source pixels.
    pub fn shift(self: Move) usize {
        return @max(self.before.y, self.after.y) - @min(self.before.y, self.after.y);
    }
};

/// A numbered difference, with one box per affected side.
pub const Region = struct {
    /// One-based position in the comparison's reading order; zero until numbered.
    number: usize = 0,
    kind: Kind = .changed,
    /// The box on the before image, or null when the change is only on the after side.
    before: ?Box = null,
    /// The box on the after image, or null when the change is only on the before side.
    after: ?Box = null,

    /// Gets this region's rectangle for the requested side, if present.
    pub fn boxOn(self: Region, side: Side) ?Box {
        return switch (side) {
            .before => self.before,
            .after => self.after,
        };
    }
};

fn PixelRows(comptime _: PixelSpace) type {
    return struct {
        y: usize,
        height: usize,
    };
}

test "region selects its side and edge-touching boxes do not overlap" {
    const here = Box.fromPixels(1, 2, 3, 4);
    const next = Box.fromPixels(4, 2, 2, 4);
    const region: Region = .{ .after = here };
    try std.testing.expectEqual(@as(?Box, null), region.boxOn(.before));
    try std.testing.expectEqual(@as(?Box, here), region.boxOn(.after));
    try std.testing.expectEqual(@as(f64, 0), here.overlap(next));
}

test {
    std.testing.refAllDecls(@This());
}
