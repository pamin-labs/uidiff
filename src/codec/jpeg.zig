//! Probes JPEG frames and runs the bounded 8-bit libjpeg-turbo decoder.
const std = @import("std");
const c = @import("jpeg_c");
const memory = @import("codec_memory");
const values = @import("../value.zig");
const Allocator = std.mem.Allocator;
const Pixel = values.Pixel;
const Size = values.Size;

/// Malformed input or a refusal from the codec memory budget.
pub const DecodeError = memory.Error;

/// Dimensions from the first supported start-of-frame marker.
pub const Header = struct { size: Size };

const soi = "\xff\xd8";
const marker_prefix = 0xff;
const first_scan = 0xda;
const end_of_image = 0xd9;
const sample_precision = 8;
const minimum_frame_length = 8;

const quantization: [64]u8 = @splat(1);
const huffman_tail: [16]u8 = @splat(0);
// A single grayscale block with one Huffman code each for DC zero and EOB.
const gray_jpeg = "\xff\xd8".* ++
    "\xff\xdb\x00\x43\x00".* ++ quantization ++
    "\xff\xc0\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00".* ++
    "\xff\xc4\x00\x26\x00\x01".* ++ huffman_tail ++
    "\x10\x01".* ++ huffman_tail ++
    "\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x3f\xff\xd9".*;

/// Recognizes the JPEG start-of-image marker.
pub fn matches(prefix: []const u8) bool {
    return std.mem.startsWith(u8, prefix, soi);
}

/// Reads dimensions without starting entropy decode or allocating the image.
pub fn probe(_: Allocator, bytes: []const u8, _: usize) DecodeError!Header {
    if (!matches(bytes)) return error.InvalidImage;
    var offset: usize = soi.len;
    while (offset < bytes.len and bytes[offset] == marker_prefix) {
        while (offset < bytes.len and bytes[offset] == marker_prefix) offset += 1;
        if (bytes.len - offset < 1 + @sizeOf(u16)) break;
        const marker = bytes[offset];
        offset += 1;
        if (marker == first_scan or marker == end_of_image) break;
        const len = std.mem.readInt(u16, bytes[offset..][0..2], .big);
        if (len < @sizeOf(u16) or len > bytes.len - offset) break;
        switch (marker) {
            // Baseline, extended sequential and progressive Huffman frames.
            0xc0, 0xc1, 0xc2 => {
                if (len < minimum_frame_length or bytes[offset + 2] != sample_precision) return error.InvalidImage;
                const height = std.mem.readInt(u16, bytes[offset + 3 ..][0..2], .big);
                const width = std.mem.readInt(u16, bytes[offset + 5 ..][0..2], .big);
                return .{ .size = .{ .width = width, .height = height } };
            },
            else => offset += len,
        }
    }
    return error.InvalidImage;
}

/// Decodes RGBA8 under the caller's memory cap. The caller releases the result.
pub fn decode(allocator: Allocator, bytes: []const u8, header: Header, cap: usize) DecodeError![]Pixel {
    const count = header.size.pixelCount() orelse return error.ImageTooLarge;
    const width = std.math.cast(u32, header.size.width) orelse return error.ImageTooLarge;
    const height = std.math.cast(u32, header.size.height) orelse return error.ImageTooLarge;
    memory.begin(allocator, @min(cap, values.max_decode_bytes));
    defer memory.end();
    // The C bridge returns count consecutive RGBA8 pixels on success.
    const pixels: [*]Pixel = @ptrCast(c.uidiff_jpeg_decode(bytes.ptr, bytes.len, width, height) orelse return memory.failure());
    return pixels[0..count];
}

/// Releases the decoded block through the allocator recorded when it was created.
pub fn release(_: Allocator, pixels: []const Pixel) void {
    c.uidiff_codec_free(@constCast(pixels.ptr));
}

fn decodeGray(allocator: Allocator) !void {
    const header = try probe(allocator, &gray_jpeg, values.max_decode_bytes);
    const pixels = try decode(allocator, &gray_jpeg, header, values.max_decode_bytes);
    defer release(allocator, pixels);
    try std.testing.expectEqualSlices(Pixel, &.{.{ 128, 128, 128, 255 }}, pixels);
}

test "8-bit grayscale decodes to opaque RGBA and releases partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decodeGray, .{});
}

test "only complete 8-bit Huffman frame headers are accepted" {
    var header = "\xff\xd8\xff\xc2\x00\x0b\x08\x00\x01\x00\x02\x01\x01\x11\x00".*;
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(Size{ .width = 2, .height = 1 }, (try probe(allocator, &header, 0)).size);
    try std.testing.expectError(error.InvalidImage, probe(allocator, header[0 .. header.len - 1], 0));
    header[6] = 12;
    try std.testing.expectError(error.InvalidImage, probe(allocator, &header, 0));
    header[6] = sample_precision;
    header[3] = 0xca;
    try std.testing.expectError(error.InvalidImage, probe(allocator, &header, 0));
}

test {
    std.testing.refAllDecls(@This());
}
