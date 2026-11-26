//! Image dimensions and borrowed RGBA8 pixels shared across layers.
const std = @import("std");
const region = @import("region.zig");

/// Red, green, blue and alpha channels in byte order.
pub const Pixel = [4]u8;

/// Image dimensions in device pixels.
pub const Size = struct {
    width: usize,
    height: usize,

    /// Returns the pixel count if both axes and their product are supported.
    pub fn pixelCount(self: Size) ?usize {
        if (self.width == 0 or self.height == 0 or self.width > max_extent or self.height > max_extent) return null;
        if (self.height > max_pixels / self.width) return null;
        return self.width * self.height;
    }
};

/// A borrowed, tightly packed, row-major RGBA8 image in device pixels.
pub const Image = struct {
    width: usize,
    height: usize,
    pixels: []const Pixel,

    /// A malformed packed image or encoded stream.
    pub const Invalid = error{InvalidImage};

    /// Returns dimensions without inspecting the pixel buffer.
    pub fn size(self: Image) Size {
        return .{ .width = self.width, .height = self.height };
    }

    /// Checks dimensions and requires exactly one packed pixel per coordinate.
    pub fn valid(self: Image) bool {
        return self.pixels.len == (self.size().pixelCount() orelse return false);
    }

    /// Reports whether every pixel has full alpha coverage.
    pub fn isOpaque(self: Image) bool {
        const lanes = std.simd.suggestVectorLength(u32) orelse 4;
        const Words = @Vector(lanes, u32);
        const alpha: Words = @splat(@bitCast(Pixel{ 0, 0, 0, 255 }));
        var i: usize = 0;
        while (i + lanes <= self.pixels.len) : (i += lanes) {
            const rgba: Words = @bitCast(self.pixels[i..][0..lanes].*);
            if (!@reduce(.And, rgba & alpha == alpha)) return false;
        }
        for (self.pixels[i..]) |p| if (p[3] != 255) return false;
        return true;
    }

    /// Returns row y. Asserts y is less than height on a valid image.
    pub fn row(self: Image, y: usize) []const Pixel {
        return self.pixels[y * self.width ..][0..self.width];
    }

    /// Borrows a horizontal segment of a row in a validated image.
    pub fn rowSegment(self: Image, y: usize, left: usize, width: usize) []const Pixel {
        return self.row(y)[left..][0..width];
    }

    /// Borrows bytes of a row segment within a validated image.
    pub fn rowBytes(self: Image, y: usize, left: usize, width: usize) []const u8 {
        return std.mem.sliceAsBytes(self.rowSegment(y, left, width));
    }
};

/// The borrowed source images in comparison order.
pub const Pair = struct {
    before: Image,
    after: Image,

    pub fn get(self: Pair, side: region.Side) Image {
        return switch (side) {
            .before => self.before,
            .after => self.after,
        };
    }

    pub fn reversed(self: Pair) Pair {
        return .{ .before = self.after, .after = self.before };
    }
};

/// Bounds a 4K-wide capture to 32,768 rows and keeps individual RGBA8 buffers at most 512 MiB.
pub const max_pixels = 128 * 1024 * 1024;

/// Allows very tall pages while bounding scratch storage that scales with one axis.
pub const max_extent = 2 * (max_pixels / 4096);

/// The largest encoded input accepted in bytes. The allowance over an RGBA8
/// image of max_pixels covers container and row-filter overhead.
pub const max_encoded_bytes = max_pixels * @sizeOf(Pixel) / 100 * 101;

/// The most memory one decode may hold, in bytes. The PNG and JPEG binding
/// refuses a header whose budget is larger and charges every allocation
/// against that budget. WebP uses this cap for the output and scratch buffers.
pub const max_decode_bytes = 3 * 1024 * 1024 * 1024;

test "pixel count accepts a 4K tall page and rejects overflow or empty axes" {
    try std.testing.expectEqual(@as(?usize, max_pixels), (Size{ .width = 4096, .height = max_pixels / 4096 }).pixelCount());
    try std.testing.expectEqual(@as(?usize, null), (Size{ .width = max_extent, .height = max_extent }).pixelCount());
    try std.testing.expectEqual(@as(?usize, null), (Size{ .width = 0, .height = 1 }).pixelCount());
}

test "rows use the packed stride" {
    const pixels = [_]Pixel{ .{ 1, 0, 0, 255 }, .{ 2, 0, 0, 255 }, .{ 3, 0, 0, 255 }, .{ 4, 0, 0, 255 } };
    const image: Image = .{ .width = 2, .height = 2, .pixels = &pixels };
    try std.testing.expectEqualSlices(Pixel, pixels[2..], image.row(1));
    try std.testing.expectEqualSlices(Pixel, pixels[3..], image.rowSegment(1, 1, 1));
    try std.testing.expectEqualSlices(u8, &.{}, image.rowBytes(1, 2, 0));
}

test {
    std.testing.refAllDecls(@This());
}
