//! Sheet and pane geometry and preview sampling.
const std = @import("std");
const values = @import("../value.zig");
const Image = values.Image;
const Size = values.Size;
const Pixel = values.Pixel;
const Allocator = std.mem.Allocator;

const Space = enum { source, sheet };

/// Whole source pixels before projection into a pane.
pub const SourceRect = RectFor(.source);
/// Whole pixels in the composed sheet.
pub const Rect = RectFor(.sheet);

/// Preview scale, UI scale, and pane arrangement for a sheet.
pub const PaneLayout = struct {
    percent: usize,
    numerator: usize,
    denominator: usize,
    panoramic: bool,

    /// Chooses the preview scale and pane arrangement from source dimensions.
    pub fn init(before: Size, after: Size) PaneLayout {
        const source_width = @max(before.width, after.width);
        // A panoramic capture gets a full-width slot even beside a portrait.
        const panoramic = before.width > 2 * before.height or after.width > 2 * after.height;
        const shortest = @min(before.width, before.height, after.width, after.height);
        const source_height = @max(before.height, after.height);
        const limit = max_side_pane_width;
        const height_limit = 1600;
        const scale: [2]usize = if (source_height > height_limit and source_height * limit > source_width * height_limit)
            .{ height_limit, source_height }
        else if (source_width > limit)
            .{ limit, source_width }
        else
            .{ @min((min_preview_side + shortest - 1) / shortest, limit / source_width, height_limit / source_height), 1 };
        const view_width = @max(1, source_width * scale[0] / scale[1]);
        return .{
            .percent = if (panoramic) 100 else @min(205, @max(100, (view_width * 100 + 390) / 780)),
            .numerator = scale[0],
            .denominator = scale[1],
            .panoramic = panoramic,
        };
    }

    /// Converts a base UI length into sheet pixels.
    pub fn px(self: PaneLayout, n: usize) usize {
        return (n * self.percent + 50) / 100;
    }

    /// Projects a device coordinate into preview pixels.
    pub fn position(self: PaneLayout, n: usize) usize {
        return n * self.numerator / self.denominator;
    }

    /// Returns the scaled dimensions of a source pane.
    pub fn preview(self: PaneLayout, size: Size) Size {
        if (self.panoramic) {
            if (size.width * overview_max_height >= size.height * overview_width) return .{
                .width = overview_width,
                .height = @max(1, size.height * overview_width / size.width),
            };
            return .{
                .width = @max(1, size.width * overview_max_height / size.height),
                .height = overview_max_height,
            };
        }
        return .{ .width = self.extent(size.width), .height = self.extent(size.height) };
    }

    /// Returns the two overview rectangles in sheet coordinates.
    pub fn panes(self: PaneLayout, before: Size, after: Size) [2]Rect {
        const x = self.px(margin);
        const y = self.px(pane_top);
        const a = paneRect(x, y, self.preview(before));
        const after_size = self.preview(after);
        const b = paneRect(
            if (self.panoramic) x else a.right() + self.gutterFor(a.w, after_size.width),
            if (self.panoramic) a.bottom() + overview_caption_gap else y,
            after_size,
        );
        return .{ a, b };
    }

    fn gutterFor(self: PaneLayout, before: usize, after: usize) usize {
        return @max(48, @min(self.px(gutter), @min(before, after) / 4));
    }
    fn extent(self: PaneLayout, n: usize) usize {
        return @max(1, self.position(n));
    }
};

/// A borrowed source image with an optional owned column sampling table.
pub const Pane = struct {
    image: Image,
    dimensions: Size,
    samples: []const u16,

    /// Builds the optional column sampling table. Release with deinit.
    pub fn init(allocator: Allocator, image: Image, pane_layout: PaneLayout) Allocator.Error!Pane {
        const size = pane_layout.preview(image.size());
        if (size.width == image.width) return .{ .image = image, .dimensions = size, .samples = &.{} };
        const samples = try allocator.alloc(u16, size.width);
        for (samples, 0..) |*x, i| x.* = @intCast(i * image.width / size.width);
        return .{ .image = image, .dimensions = size, .samples = samples };
    }

    /// Releases only the sampling table.
    pub fn deinit(self: Pane, allocator: Allocator) void {
        allocator.free(self.samples);
    }

    /// Reports whether the preview's source has full alpha coverage.
    pub fn isOpaque(self: Pane) bool {
        return self.image.isOpaque();
    }

    /// Copies visible pixels from a preview row into caller-owned storage.
    pub fn copy(self: Pane, y: usize, left: usize, dest: []Pixel) void {
        const source = self.image.row(y * self.image.height / self.dimensions.height);
        if (self.samples.len == 0) {
            @memcpy(dest, source[left..][0..dest.len]);
        } else {
            for (dest, self.samples[left..][0..dest.len]) |*pixel, x| pixel.* = source[x];
        }
    }
};

/// Base outer margin around the sheet, in sheet pixels.
pub const margin = 48;

/// Base sheet row where the overview begins.
pub const pane_top = 182;

/// Preferred base width of the alignment gutter.
pub const gutter = 160;

/// Largest supported styled sheet width in pixels.
pub const max_sheet_width = 3200;

/// Maximum width of a panoramic overview, in sheet pixels.
pub const overview_width = 2400;

const overview_max_height = 240;

const max_side_pane_width = 1360;

/// Shortest preview side targeted by integer enlargement.
pub const min_preview_side = 320;

/// Vertical separation between stacked panoramic panes.
pub const overview_caption_gap = 64;

/// Creates a sheet rectangle at the supplied position and size.
pub fn paneRect(x: usize, y: usize, size: Size) Rect {
    return .{ .x = x, .y = y, .w = size.width, .h = size.height };
}

/// Reports whether a row is close enough to paint the pane frame.
pub fn nearPane(y: usize, pane: Rect, pane_layout: PaneLayout) bool {
    return y + pane_layout.px(8) >= pane.y and y < pane.bottom() + pane_layout.px(12);
}

/// Projects a source rectangle onto a pane showing the complete image.
pub noinline fn offsetMark(box: ?SourceRect, pane: Rect, size: Size) ?Rect {
    const source = box orelse return null;
    return mapMark(source, .{ .x = 0, .y = 0, .w = size.width, .h = size.height }, pane);
}

/// Projects a source rectangle onto the sheet, clipping to the shown window.
pub fn mapMark(region: SourceRect, source: SourceRect, pane: Rect) ?Rect {
    if (!region.overlaps(source)) return null;
    const left = (region.x -| source.x) * pane.w / source.w;
    const top = (region.y -| source.y) * pane.h / source.h;
    const right = (@min(region.right(), source.right()) - source.x) * pane.w;
    const bottom = (@min(region.bottom(), source.bottom()) - source.y) * pane.h;
    return .{
        .x = pane.x + left,
        .y = pane.y + top,
        .w = (right + source.w - 1) / source.w - left,
        .h = (bottom + source.h - 1) / source.h - top,
    };
}

/// Validates fractional device coordinates and rounds them outward.
pub fn imageRect(image: Image, box: ?values.Box) ?SourceRect {
    return rectAtSize(image.size(), box);
}

/// Validates and rounds a box against a known source image size.
pub noinline fn rectAtSize(size: Size, box: ?values.Box) ?SourceRect {
    const b = box orelse return null;
    const w: f64 = @floatFromInt(size.width);
    const h: f64 = @floatFromInt(size.height);
    if (!(b.x >= 0 and b.y >= 0 and b.width > 0 and b.height > 0 and b.right() <= w and b.bottom() <= h)) return null;
    const x: usize = @intFromFloat(@floor(b.x));
    const y: usize = @intFromFloat(@floor(b.y));
    return .{ .x = x, .y = y, .w = @as(usize, @intFromFloat(@ceil(b.right()))) - x, .h = @as(usize, @intFromFloat(@ceil(b.bottom()))) - y };
}

fn RectFor(comptime _: Space) type {
    return struct {
        const Self = @This();

        x: usize,
        y: usize,
        w: usize,
        h: usize,

        /// Expands the rectangle on every side, clipping at the origin.
        pub fn outset(self: Self, n: usize) Self {
            const x = self.x -| n;
            const y = self.y -| n;
            return .{ .x = x, .y = y, .w = self.x + self.w + n - x, .h = self.y + self.h + n - y };
        }

        /// Shrinks the rectangle by a uniform margin.
        pub fn inset(self: Self, n: usize) Self {
            return .{ .x = self.x + n, .y = self.y + n, .w = self.w -| (2 * n), .h = self.h -| (2 * n) };
        }

        /// Reports whether the rectangle covers the specified row.
        pub fn containsRow(self: Self, y: usize) bool {
            return y >= self.y and y - self.y < self.h;
        }

        /// Returns the exclusive right edge.
        pub fn right(self: Self) usize {
            return self.x + self.w;
        }

        /// Returns the exclusive bottom edge.
        pub fn bottom(self: Self) usize {
            return self.y + self.h;
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

test "stacked overviews fit both axes at a single scale" {
    const cases = [_]struct { sources: [2]Size, previews: [2]Size }{
        .{
            .sources = .{ .{ .width = 3440, .height = 1440 }, .{ .width = 1000, .height = 400 } },
            .previews = .{ .{ .width = 573, .height = 240 }, .{ .width = 600, .height = 240 } },
        },
        .{
            .sources = .{ .{ .width = 1000, .height = 400 }, .{ .width = 800, .height = 1000 } },
            .previews = .{ .{ .width = 600, .height = 240 }, .{ .width = 192, .height = 240 } },
        },
        .{
            .sources = .{ .{ .width = 1, .height = 20_000 }, .{ .width = 20_000, .height = 1 } },
            .previews = .{ .{ .width = 1, .height = 240 }, .{ .width = 2400, .height = 1 } },
        },
    };
    for (cases) |case| {
        const pane_layout = PaneLayout.init(case.sources[0], case.sources[1]);
        try std.testing.expect(pane_layout.panoramic);
        for (case.sources, case.previews) |source, expected| {
            try std.testing.expectEqual(expected, pane_layout.preview(source));
        }
    }
}
