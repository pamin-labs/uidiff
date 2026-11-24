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

/// Validated dimensions of an encoded WebP image.
pub const Header = struct { size: Size };

/// Recognizes the WebP RIFF form.
pub fn matches(prefix: []const u8) bool {
    return prefix.len >= 12 and std.mem.eql(u8, prefix[0..4], "RIFF") and std.mem.eql(u8, prefix[8..12], "WEBP");
}

/// Probes the WebP image without allocating decoded pixels.
pub fn probe(_: Allocator, bytes: []const u8, _: usize) DecodeError!Header {
    return .{ .size = try dimensions(bytes) };
}

/// Decodes using the validated size in the header.
pub fn decode(allocator: Allocator, bytes: []const u8, header: Header, cap: usize) DecodeError![]Pixel {
    return load(allocator, bytes, header.size, cap);
}

/// Frees the caller-owned WebP output buffer.
pub fn release(allocator: Allocator, pixels: []const Pixel) void {
    // The const view still owns the mutable decoder allocation.
    allocator.rawFree(std.mem.sliceAsBytes(@constCast(pixels)), .of(Pixel), @returnAddress());
}

/// Decodes RGBA8 pixels of a probed size. Assumes size.pixelCount() is not
/// null. The caller owns the returned slice and releases it through release.
pub fn load(allocator: Allocator, bytes: []const u8, size: Size, cap: usize) DecodeError![]Pixel {
    const count = size.width * size.height;
    const output_bytes = count * @sizeOf(Pixel);
    if (output_bytes > cap) return error.ImageTooLarge;
    // WebPDecodeRGBAInto writes every byte on success. Failure releases the block before it escapes.
    const ptr = allocator.rawAlloc(output_bytes, .of(Pixel), @returnAddress()) orelse return error.OutOfMemory;
    const out = ptr[0..output_bytes];
    const pixels = std.mem.bytesAsSlice(Pixel, out);
    errdefer release(allocator, pixels);
    // The stride is at most the pixel cap's row width in bytes, which fits c_int.
    const stride: c_int = @intCast(size.width * @sizeOf(Pixel));
    // libwebp checks that the bitstream's dimensions fit the buffer and stride.
    memory.begin(allocator, cap - output_bytes);
    defer memory.end();
    if (c.WebPDecodeRGBAInto(bytes.ptr, bytes.len, out.ptr, out.len, stride) == null) return memory.failure();
    return pixels;
}

/// Returns dimensions without decoding the pixels.
fn dimensions(bytes: []const u8) values.Image.Invalid!Size {
    var width: c_int = 0;
    var height: c_int = 0;
    if (c.WebPGetInfo(bytes.ptr, bytes.len, &width, &height) == 0) return error.InvalidImage;
    return .{
        .width = std.math.cast(usize, width) orelse return error.InvalidImage,
        .height = std.math.cast(usize, height) orelse return error.InvalidImage,
    };
}

test "a RIFF header without a WebP image is rejected" {
    try std.testing.expectError(error.InvalidImage, dimensions("RIFF\x04\x00\x00\x00WEBP"));
}

test {
    std.testing.refAllDecls(@This());
}
