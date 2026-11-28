//! Image dimensions and borrowed RGBA8 pixels shared across layers.
const std = @import("std");
const region = @import("region.zig");

/// Red, green, blue and alpha channels in byte order.
pub const Pixel = [4]u8;

/// Image dimensions in device pixels.
pub const Size = struct {
    /// Number of columns in device pixels.
    width: usize,
    /// Number of rows in device pixels.
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
    /// Number of pixels in each row.
    width: usize,
    /// Number of rows in the image.
    height: usize,
    /// Borrowed row-major data with exactly width * height pixels for a valid image.
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
        // One alpha test per block of four vectors instead of one per vector:
        // AND keeps an alpha byte at 255 only if every pixel's alpha is 255.
        const block = 4 * pixel_lanes;
        const Words = @Vector(block, u32);
        const alpha: u32 = @bitCast(Pixel{ 0, 0, 0, 255 });
        var i: usize = 0;
        while (i + block <= self.pixels.len) : (i += block) {
            const rgba: Words = @bitCast(self.pixels[i..][0..block].*);
            if (@reduce(.And, rgba) & alpha != alpha) return false;
        }
        for (self.pixels[i..]) |p| if (p[3] != 255) return false;
        return true;
    }

    /// Borrows row y. Requires a valid image and y less than height.
    pub fn row(self: Image, y: usize) []const Pixel {
        return self.pixels[y * self.width ..][0..self.width];
    }

    /// Borrows a segment wholly within row y of a valid image.
    pub fn rowSegment(self: Image, y: usize, left: usize, width: usize) []const Pixel {
        return self.row(y)[left..][0..width];
    }

    /// Borrows the RGBA bytes of a segment wholly within row y of a valid image.
    pub fn rowBytes(self: Image, y: usize, left: usize, width: usize) []const u8 {
        return std.mem.sliceAsBytes(self.rowSegment(y, left, width));
    }
};

/// The borrowed source images in comparison order.
pub const Pair = struct {
    /// Borrowed image from before the change.
    before: Image,
    /// Borrowed image from after the change.
    after: Image,

    /// Returns the borrowed image for the selected side.
    pub fn get(self: Pair, side: region.Side) Image {
        return switch (side) {
            .before => self.before,
            .after => self.after,
        };
    }

    /// Returns the combined canvas: the larger width and height of the two images.
    pub fn canvas(self: Pair) Size {
        return .{ .width = @max(self.before.width, self.after.width), .height = @max(self.before.height, self.after.height) };
    }
};

/// Packed RGBA8 lanes are 4 on SSE2 and NEON, and 8 on AVX2. Without SIMD the compiler splits the 4-lane fallback into scalars.
pub const pixel_lanes = std.simd.suggestVectorLength(u32) orelse 4;

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

/// Returns the same borrowed images with their sides exchanged.
pub fn reversePair(pair: Pair) Pair {
    return .{ .before = pair.after, .after = pair.before };
}

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

test "opacity finds a translucent pixel in any block and in the tail" {
    var pixels: [8 * pixel_lanes + 3]Pixel = undefined;
    @memset(&pixels, .{ 9, 8, 7, 255 });
    const image: Image = .{ .width = pixels.len, .height = 1, .pixels = &pixels };
    try std.testing.expect(image.isOpaque());
    for (&pixels) |*p| {
        p[3] = 254;
        try std.testing.expect(!image.isOpaque());
        p[3] = 255;
    }
}

test {
    std.testing.refAllDecls(@This());
}
