//! Binds the WebP decoder and budgets its output and scratch allocations.
const std = @import("std");
const c = @import("webp_c");
const memory = @import("codec_memory");
const values = @import("../value.zig");
const Allocator = std.mem.Allocator;
const Pixel = values.Pixel;
const Size = values.Size;

/// Malformed bytes, an exceeded budget, or a failed allocation.
pub const DecodeError = memory.Error;

/// Returns dimensions without decoding the pixels.
pub fn probe(bytes: []const u8) values.Image.Invalid!Size {
    var width: c_int = 0;
    var height: c_int = 0;
    if (c.WebPGetInfo(bytes.ptr, bytes.len, &width, &height) == 0) return error.InvalidImage;
    return .{
        .width = std.math.cast(usize, width) orelse return error.InvalidImage,
        .height = std.math.cast(usize, height) orelse return error.InvalidImage,
    };
}

/// Decodes RGBA8 pixels of a probed size. Assumes size.pixelCount() is not
/// null. The caller owns the returned slice and frees it with allocator.
pub fn load(allocator: Allocator, bytes: []const u8, size: Size, cap: usize) DecodeError![]Pixel {
    const count = size.width * size.height;
    const output_bytes = count * @sizeOf(Pixel);
    if (output_bytes > cap) return error.ImageTooLarge;
    const pixels = try allocator.alloc(Pixel, count);
    errdefer allocator.free(pixels);
    const out = std.mem.sliceAsBytes(pixels);
    // The stride is at most the pixel cap's row width in bytes, which fits c_int.
    const stride: c_int = @intCast(size.width * @sizeOf(Pixel));
    // libwebp checks that the bitstream's dimensions fit the buffer and stride.
    memory.begin(allocator, cap - output_bytes);
    defer memory.end();
    if (c.WebPDecodeRGBAInto(bytes.ptr, bytes.len, out.ptr, out.len, stride) == null) return memory.failure();
    return pixels;
}

test "a RIFF header without a WebP image is rejected" {
    try std.testing.expectError(error.InvalidImage, probe("RIFF\x04\x00\x00\x00WEBP"));
}

test {
    std.testing.refAllDecls(@This());
}
