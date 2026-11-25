//! Probes JPEG frames and runs the bounded 8-bit libjpeg-turbo decoder.
const std = @import("std");
const c = @import("jpeg_c");
const test_images = @import("jpeg_test_images.zig");
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
const baseline_frame = 0xc0;
const extended_frame = 0xc1;
const progressive_frame = 0xc2;
const lossless_frame = 0xc3;
const differential_frame_first = 0xc5;
const differential_frame_last = 0xc7;
const arithmetic_frame_first = 0xc9;
const arithmetic_frame_last = 0xcb;
const differential_arithmetic_frame_first = 0xcd;
const differential_arithmetic_frame_last = 0xcf;
const sample_precision = 8;
const precision_offset = @sizeOf(u16);
const height_offset = precision_offset + @sizeOf(u8);
const width_offset = height_offset + @sizeOf(u16);
const minimum_frame_length = width_offset + @sizeOf(u16) + @sizeOf(u8);

/// Recognizes the JPEG start-of-image marker.
pub fn matches(prefix: []const u8) bool {
    return std.mem.startsWith(u8, prefix, soi);
}

/// Reads dimensions without starting entropy decode or allocating the image.
pub fn probe(_: Allocator, bytes: []const u8, cap: usize) DecodeError!Header {
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
            baseline_frame, extended_frame, progressive_frame => {
                // The trimmed C decoder has no dispatch for wider samples.
                if (len < minimum_frame_length or bytes[offset + precision_offset] != sample_precision) return error.InvalidImage;
                const height: usize = std.mem.readInt(u16, bytes[offset + height_offset ..][0..@sizeOf(u16)], .big);
                const width: usize = std.mem.readInt(u16, bytes[offset + width_offset ..][0..@sizeOf(u16)], .big);
                if (width == 0 or height == 0) return error.InvalidImage;
                if (width * height > cap / @sizeOf(Pixel)) return error.ImageTooLarge;
                return .{ .size = .{ .width = width, .height = height } };
            },
            lossless_frame,
            differential_frame_first...differential_frame_last,
            arithmetic_frame_first...arithmetic_frame_last,
            differential_arithmetic_frame_first...differential_arithmetic_frame_last,
            => return error.InvalidImage,
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
    const header = try probe(allocator, &test_images.gray, values.max_decode_bytes);
    const pixels = try decode(allocator, &test_images.gray, header, values.max_decode_bytes);
    defer release(allocator, pixels);
    try std.testing.expectEqualSlices(Pixel, &.{.{ 128, 128, 128, 255 }}, pixels);
}

test "8-bit grayscale decodes to opaque RGBA and releases partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decodeGray, .{});
}

test "only complete 8-bit Huffman frame headers are accepted" {
    var header = "\xff\xd8\xff\xc2\x00\x0b\x08\x00\x01\x00\x02\x01\x01\x11\x00".*;
    const allocator = std.testing.allocator;
    const output_bytes = 2 * @sizeOf(Pixel);
    try std.testing.expectEqual(Size{ .width = 2, .height = 1 }, (try probe(allocator, &header, output_bytes)).size);
    try std.testing.expectError(error.ImageTooLarge, probe(allocator, &header, output_bytes - 1));
    try std.testing.expectError(error.InvalidImage, probe(allocator, header[0 .. header.len - 1], output_bytes));
    header[6] = 12;
    try std.testing.expectError(error.InvalidImage, probe(allocator, &header, output_bytes));
    header[6] = sample_precision;
    const supported = header;
    for ([_]u8{ 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf }) |marker| {
        header[3] = marker;
        try std.testing.expectError(error.InvalidImage, probe(allocator, &(header ++ supported[2..].*), output_bytes));
    }
}

test "JPEG warnings reject truncated sequential and progressive streams" {
    const allocator = std.testing.allocator;
    const progressive = test_images.progressive(2);
    for ([_][]const u8{ &test_images.gray, &progressive }) |complete| {
        const bytes = complete[0 .. complete.len - test_images.eoi.len];
        const header = try probe(allocator, bytes, values.max_decode_bytes);
        try std.testing.expectError(error.InvalidImage, decode(allocator, bytes, header, values.max_decode_bytes));
    }
}

test "JPEG progressive scan limit accepts the boundary and rejects the next scan" {
    const allocator = std.testing.allocator;
    const at_limit = test_images.progressive(c.UIDIFF_JPEG_MAX_SCANS);
    const header = try probe(allocator, &at_limit, values.max_decode_bytes);
    const pixels = try decode(allocator, &at_limit, header, values.max_decode_bytes);
    defer release(allocator, pixels);
    try std.testing.expectEqual(@as(usize, 1), pixels.len);

    const past_limit = test_images.progressive(c.UIDIFF_JPEG_MAX_SCANS + 1);
    try std.testing.expectError(error.InvalidImage, decode(allocator, &past_limit, header, values.max_decode_bytes));
}

test "JPEG rejects header mismatch before allocating output" {
    var scratch: [64 * 1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
    const header: Header = .{ .size = .{ .width = 512, .height = 512 } };
    try std.testing.expectError(error.InvalidImage, decode(fixed.allocator(), &test_images.gray, header, values.max_decode_bytes));
}

test {
    std.testing.refAllDecls(@This());
}
