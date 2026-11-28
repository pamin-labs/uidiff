//! Binds the in-memory PNG decoder. Its allocations go through the
//! caller's allocator and are charged against a budget sized from the header.
const std = @import("std");
const c = @import("stb_c");
const value = @import("../../value.zig");
const png_format = @import("png_format");
const memory = @import("codec_memory");
const types = @import("../types.zig");
const Allocator = std.mem.Allocator;
const Pixel = value.Pixel;
const Size = value.Size;

/// Malformed bytes, a decode past its memory budget, or an allocation failure.
pub const DecodeError = memory.Error;

/// What a probe reads from the file header.
pub const Header = struct {
    size: Size,
    /// Bytes per channel sample: 1, or 2 for a 16-bit PNG.
    sample_bytes: usize,
};

/// The peak for PNG is Adam7's inflated data, destination and current pass.
/// Charge each as a full RGBA image at the source sample depth.
const png_image_buffers = 3;
/// Round the budget's image dimensions up to a conservative block boundary.
const block_pixels = 32;
/// Headroom for the decoder context and per-row scratch.
const fixed_bytes = 1024 * 1024;

/// Returns dimensions and sample depth without decoding the pixels.
pub fn probe(allocator: Allocator, bytes: []const u8, cap: usize) DecodeError!Header {
    const len = std.math.cast(c_int, bytes.len) orelse return error.ImageTooLarge;
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    memory.begin(allocator, @min(fixed_bytes, cap));
    defer memory.end();
    if (c.stbi_info_from_memory(bytes.ptr, len, &width, &height, &channels) == 0) {
        if (oversizedPng(bytes)) return error.ImageTooLarge;
        return memory.failure();
    }
    const sixteen = c.stbi_is_16_bit_from_memory(bytes.ptr, len) != 0;
    return .{ .size = try types.fromC(width, height), .sample_bytes = if (sixteen) 2 else 1 };
}

/// Decodes a fallback PNG under the caller's budget.
pub fn loadLegacy(allocator: Allocator, bytes: []const u8, header: Header, cap: usize) DecodeError![]Pixel {
    return withDecodeBudget(loadStb, allocator, bytes, header, cap);
}

/// Runs a byte-and-size decoder within the PNG allocation scope.
pub fn withDecodeBudget(comptime decodePixels: anytype, allocator: Allocator, bytes: []const u8, header: Header, cap: usize) @typeInfo(@TypeOf(decodePixels)).@"fn".return_type.? {
    try beginDecode(allocator, header, bytes.len, cap);
    defer memory.end();
    return decodePixels(bytes, header.size);
}

/// Runs the fallback PNG decoder in an active allocation scope.
pub fn loadStb(bytes: []const u8, expected: Size) DecodeError![]Pixel {
    const len = std.math.cast(c_int, bytes.len) orelse return error.ImageTooLarge;
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const data = c.stbi_load_from_memory(bytes.ptr, len, &width, &height, &channels, @sizeOf(Pixel)) orelse return memory.failure();
    errdefer c.stbi_image_free(data);
    const actual = try types.fromC(width, height);
    if (actual.width != expected.width or actual.height != expected.height) return error.InvalidImage;
    // The matching probe dimensions have already passed the image limits.
    const count = expected.width * expected.height;
    // stb allocates the returned block through our memory hooks.
    const allocation = memory.allocatedBytes(data);
    const used = count * @sizeOf(Pixel);
    if (allocation.len < used) return error.InvalidImage;
    return std.mem.bytesAsSlice(Pixel, allocation[0..used]);
}

noinline fn beginDecode(allocator: Allocator, header: Header, len: usize, cap: usize) DecodeError!void {
    const limit = budget(header, len, cap) orelse return error.ImageTooLarge;
    memory.begin(allocator, limit);
}

/// Returns the most bytes stb may hold while decoding an image with this
/// header from encoded_len bytes, or null past the validated cap.
fn budget(header: Header, encoded_len: usize, cap: usize) ?usize {
    const width = std.math.add(usize, header.size.width, block_pixels - 1) catch return null;
    const height = std.math.add(usize, header.size.height, block_pixels - 1) catch return null;
    const blocks = std.math.mul(usize, width / block_pixels, height / block_pixels) catch return null;
    const image = std.math.mul(usize, blocks, block_pixels * block_pixels * @sizeOf(Pixel) * png_image_buffers) catch return null;
    const scaled = std.math.mul(usize, image, header.sample_bytes) catch return null;
    const total = std.math.add(usize, scaled, encoded_len +| fixed_bytes) catch return null;
    return if (total <= cap) total else null;
}

// stb replaces a failed format probe's reason with "unknown image type".
// Read PNG dimensions on that error path.
fn oversizedPng(bytes: []const u8) bool {
    if (bytes.len < png_format.header_bytes or !std.mem.startsWith(u8, bytes, png_format.header_prefix)) return false;
    const offset = png_format.dimensions_offset;
    const width: u32 = png_format.readU32(bytes, offset);
    const height: u32 = png_format.readU32(bytes, offset + @sizeOf(u32));
    if (width == 0 or height == 0) return false;
    const size: Size = .{
        .width = std.math.cast(usize, width) orelse return true,
        .height = std.math.cast(usize, height) orelse return true,
    };
    return size.pixelCount() == null;
}

test "a truncated PNG header is rejected" {
    try std.testing.expectError(error.InvalidImage, probe(std.testing.allocator, "\x89PNG\r\n\x1a\n", value.max_decode_bytes));
}

test "PNG headers outside the image limits report ImageTooLarge" {
    const cases = [_]struct { width: u32, height: u32, expected: DecodeError }{
        .{ .width = 20_000, .height = 20_000, .expected = error.ImageTooLarge },
        .{ .width = 17_000, .height = 17_000, .expected = error.ImageTooLarge },
        .{ .width = std.math.maxInt(u32), .height = 1, .expected = error.ImageTooLarge },
        .{ .width = 0, .height = 17_000, .expected = error.InvalidImage },
    };
    for (cases) |case| {
        const dimensions: [8]u8 = @splat(0);
        var header = (png_format.header_prefix ++ dimensions ++
            [_]u8{ png_format.sample_depth, @backingInt(png_format.Colour.rgba), 0, 0, 0 }).*;
        png_format.writeDimensions(header[png_format.dimensions_offset..][0..png_format.dimensions_bytes], case.width, case.height);
        try std.testing.expectError(case.expected, probe(std.testing.allocator, &header, value.max_decode_bytes));
    }
}

test "the largest 8-bit images fit the decode budget and a 16-bit one does not" {
    const tall: Size = .{ .width = value.max_pixels / value.max_extent, .height = value.max_extent };
    // A width just past a block boundary pads the most.
    const padded: Size = .{ .width = 4097, .height = value.max_pixels / 4097 };
    for ([_]Size{ tall, padded }) |largest| {
        try std.testing.expect(largest.pixelCount() != null);
        try std.testing.expect(budget(.{ .size = largest, .sample_bytes = 1 }, value.max_encoded_bytes, value.max_decode_bytes) != null);
        try std.testing.expectEqual(@as(?usize, null), budget(.{ .size = largest, .sample_bytes = 2 }, 0, value.max_decode_bytes));
    }
}

test {
    std.testing.refAllDecls(@This());
}
