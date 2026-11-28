//! Rectangles and region values shared by comparison, drawing, and transport.
const std = @import("std");
const image = @import("image.zig");
const Size = image.Size;

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

    /// Accepts whole, non-negative pixel coordinates with a positive area
    /// that lie within an image of the given size and within max_extent, so
    /// each converts exactly to usize. NaN fails every test.
    fn fits(self: Self, size: Size) bool {
        const geometry: @Vector(4, f64) = .{ self.x, self.y, self.width, self.height };
        const zero: @Vector(4, f64) = @splat(0);
        const width: f64 = @floatFromInt(@min(size.width, image.max_extent));
        const height: f64 = @floatFromInt(@min(size.height, image.max_extent));
        return @reduce(.And, geometry >= zero) and @reduce(.And, @floor(geometry) == geometry) and
            self.width > 0 and self.height > 0 and self.right() <= width and self.bottom() <= height;
    }
};

/// A whole-pixel rectangle in source device coordinates.
pub const PixelRect = PixelRectFor(.device);
/// A whole-pixel rectangle in rendered sheet coordinates.
pub const SheetRect = PixelRectFor(.sheet);

/// Which side contains the difference. Non-exhaustive, so a later release
/// may add a kind (a moved block, say) without breaking callers; a switch
/// over it handles the three known kinds and `_`.
pub const Kind = enum(u8) { inserted, removed, changed, _ };

/// Selects the source image for a region or annotation. Exhaustive: a
/// comparison has exactly two images.
pub const Side = enum { before, after };

/// Source dimensions per side, which caller-built regions and moves are checked against.
pub const Sizes = std.EnumArray(Side, Size);

/// One aligned row range in device pixels.
pub const RowRange = PixelRows(.device);
/// One preview row range in sheet pixels.
pub const SheetRowRange = PixelRows(.sheet);

/// A block aligned at different vertical positions, within the given columns.
pub const Move = struct {
    /// Aligned rows on the before image.
    before: RowRange,
    /// Aligned rows on the after image.
    after: RowRange,
    /// Left edge of the source columns shared by both sides, in device pixels.
    x: usize,
    /// Number of source columns in the block.
    width: usize,

    /// A move with no rows or columns, unequal heights, no displacement, or
    /// rows or columns outside either image.
    pub const CheckError = error{InvalidMove};

    /// Returns the absolute vertical displacement in source pixels.
    pub fn shift(self: Move) usize {
        return @max(self.before.y, self.after.y) - @min(self.before.y, self.after.y);
    }

    /// Checks a caller-built move against the per-side image sizes. A
    /// comparison's moves always pass.
    pub fn check(self: Move, sizes: Sizes) CheckError!void {
        if (self.before.height == 0 or self.before.height != self.after.height or self.before.y == self.after.y) return error.InvalidMove;
        const width = @min(sizes.get(.before).width, sizes.get(.after).width);
        if (self.width == 0 or self.x > width or self.width > width - self.x) return error.InvalidMove;
        inline for (.{ .before, .after }) |side| {
            const rows = @field(self, @tagName(side));
            const height = sizes.get(side).height;
            if (rows.y > height or rows.height > height - rows.y) return error.InvalidMove;
        }
    }
};

/// A numbered difference, with one box per affected side.
pub const Region = struct {
    /// One-based position in the comparison's reading order; zero until numbered.
    number: usize = 0,
    /// The box on the before image, or null when the change is only on the after side.
    before: ?Box = null,
    /// The box on the after image, or null when the change is only on the before side.
    after: ?Box = null,

    /// A region without a box, or a box that is fractional, empty or outside
    /// its image; or a region that was never numbered.
    pub const CheckError = error{ InvalidRegionBox, InvalidRegionNumber };

    /// Checks a caller-built region against the per-side image sizes. A
    /// comparison's regions always pass.
    pub fn check(self: Region, sizes: Sizes) CheckError!void {
        if (self.before == null and self.after == null) return error.InvalidRegionBox;
        for (std.enums.values(Side)) |side| {
            const box = self.boxOn(side) orelse continue;
            if (!box.fits(sizes.get(side))) return error.InvalidRegionBox;
        }
        if (self.number == 0) return error.InvalidRegionNumber;
    }

    /// Classifies the region by the sides that hold a box: after only is
    /// inserted, before only is removed, both is changed. A region without
    /// a box is invalid and reads as inserted.
    pub fn kind(self: Region) Kind {
        if (self.before == null) return .inserted;
        if (self.after == null) return .removed;
        return .changed;
    }

    /// Gets this region's rectangle for the requested side, if present.
    pub fn boxOn(self: Region, side: Side) ?Box {
        return switch (side) {
            .before => self.before,
            .after => self.after,
        };
    }
};

/// The most regions a comparison reports and a sheet accepts.
pub const max_regions = 8;

fn PixelRows(comptime _: PixelSpace) type {
    return struct {
        /// First row in the range.
        y: usize,
        /// Number of rows in the half-open range.
        height: usize,
    };
}

/// Defines rectangle operations for one coordinate space.
fn PixelRectFor(comptime _: PixelSpace) type {
    return struct {
        x: usize,
        y: usize,
        width: usize,
        height: usize,

        const Self = @This();

        /// Expands the rectangle on every side, clipping at the origin.
        pub fn outset(self: Self, n: usize) Self {
            const x = self.x -| n;
            const y = self.y -| n;
            return .{ .x = x, .y = y, .width = self.x + self.width + n - x, .height = self.y + self.height + n - y };
        }

        /// Shrinks the rectangle by a uniform margin.
        pub fn inset(self: Self, n: usize) Self {
            return .{ .x = self.x + n, .y = self.y + n, .width = self.width -| (2 * n), .height = self.height -| (2 * n) };
        }

        /// Reports whether the rectangle covers the specified row.
        pub fn containsRow(self: Self, y: usize) bool {
            return y >= self.y and y - self.y < self.height;
        }

        /// Returns the exclusive right edge.
        pub fn right(self: Self) usize {
            return self.x + self.width;
        }

        /// Returns the exclusive bottom edge.
        pub fn bottom(self: Self) usize {
            return self.y + self.height;
        }

        /// Reports a positive-area overlap in the same pixel space.
        pub fn overlaps(self: Self, other: Self) bool {
            return self.x < other.right() and other.x < self.right() and self.y < other.bottom() and other.y < self.bottom();
        }

        /// Returns the squared gap in pixels between rectangles.
        pub fn distanceSquared(self: Self, other: Self) usize {
            const dx = @max(self.x -| other.right(), other.x -| self.right());
            const dy = @max(self.y -| other.bottom(), other.y -| self.bottom());
            return dx *| dx +| dy *| dy;
        }
    };
}

test "region selects its side, derives its kind, and edge-touching boxes do not overlap" {
    const here = Box.fromPixels(1, 2, 3, 4);
    const next = Box.fromPixels(4, 2, 2, 4);
    const region: Region = .{ .after = here };
    try std.testing.expectEqual(@as(?Box, null), region.boxOn(.before));
    try std.testing.expectEqual(@as(?Box, here), region.boxOn(.after));
    try std.testing.expectEqual(Kind.inserted, region.kind());
    try std.testing.expectEqual(Kind.removed, (Region{ .before = here }).kind());
    try std.testing.expectEqual(Kind.changed, (Region{ .before = here, .after = next }).kind());
    try std.testing.expectEqual(@as(f64, 0), here.overlap(next));
}

test "caller regions need whole boxes inside their image and a number" {
    const sizes: Sizes = .init(.{ .before = .{ .width = 10, .height = 8 }, .after = .{ .width = 6, .height = 8 } });
    const inside = Box.fromPixels(2, 1, 4, 7);
    try (Region{ .number = 1, .before = inside, .after = inside }).check(sizes);
    var fractional = inside;
    fractional.x += 0.5;
    const invalid = [_]Region{
        .{ .number = 1 },
        .{ .number = 1, .before = fractional },
        .{ .number = 1, .before = Box.fromPixels(2, 1, 0, 7) },
        .{ .number = 1, .after = Box.fromPixels(4, 1, 4, 7) },
        .{ .number = 1, .after = .{ .x = std.math.nan(f64), .y = 0, .width = 1, .height = 1 } },
        .{ .number = 1, .after = .{ .x = -1, .y = 0, .width = 2, .height = 1 } },
    };
    const huge: Sizes = .initFill(.{ .width = std.math.maxInt(usize), .height = 1 });
    const past_extent = Box.fromPixels(image.max_extent, 0, 1, 1);
    try std.testing.expectError(error.InvalidRegionBox, (Region{ .number = 1, .after = past_extent }).check(huge));
    for (invalid) |region| try std.testing.expectError(error.InvalidRegionBox, region.check(sizes));
    try std.testing.expectError(error.InvalidRegionNumber, (Region{ .before = inside }).check(sizes));
}

test "caller moves need equal displaced rows within both images" {
    const sizes: Sizes = .init(.{ .before = .{ .width = 10, .height = 20 }, .after = .{ .width = 6, .height = 30 } });
    const valid: Move = .{ .before = .{ .y = 2, .height = 10 }, .after = .{ .y = 20, .height = 10 }, .x = 1, .width = 5 };
    try valid.check(sizes);
    var invalid: [6]Move = @splat(valid);
    invalid[0].after.y = valid.before.y;
    invalid[1].after.height = 9;
    invalid[2].width = 0;
    invalid[3].width = 6;
    invalid[4].before.y = 11;
    invalid[5].before.height = 0;
    invalid[5].after.height = 0;
    for (invalid) |move| try std.testing.expectError(error.InvalidMove, move.check(sizes));
}

test {
    std.testing.refAllDecls(@This());
}
