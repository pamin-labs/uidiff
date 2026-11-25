//! Binds the in-memory PNG decoder. Its allocations go through the
//! caller's allocator and are charged against a budget sized from the header.
const std = @import("std");
const c = @import("stb_c");
const values = @import("../value.zig");
const png_format = @import("png_format.zig");
const memory = @import("codec_memory");
const Allocator = std.mem.Allocator;
const Pixel = values.Pixel;
const Size = values.Size;

/// What a probe reads from the file header.
pub const Header = struct {
    size: Size,
    /// Bytes per channel sample: 1, or 2 for a 16-bit PNG.
    sample_bytes: usize,
};

/// Malformed bytes, a decode past its memory budget, or an allocation failure.
pub const DecodeError = values.Image.Invalid || Allocator.Error || error{ImageTooLarge};

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
    return .{ .size = try size(width, height), .sample_bytes = if (sixteen) 2 else 1 };
}

/// Decodes a fallback PNG under the caller's budget.
pub fn loadLegacy(allocator: Allocator, bytes: []const u8, header: Header, cap: usize) DecodeError![]Pixel {
    return withDecodeBudget(loadStb, allocator, bytes, header, cap);
}

/// Frees pixels allocated by the bounded PNG allocator.
pub fn release(_: Allocator, pixels: []const Pixel) void {
    c.stbi_image_free(@constCast(pixels.ptr));
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
    const actual = try size(width, height);
    if (actual.width != expected.width or actual.height != expected.height) return error.InvalidImage;
    const count = actual.pixelCount() orelse return error.ImageTooLarge;
    // stb allocates the returned block through our memory hooks.
    const allocation = memory.allocatedBytes(data);
    const used = count * @sizeOf(Pixel);
    if (allocation.len < used) return error.InvalidImage;
    return std.mem.bytesAsSlice(Pixel, allocation[0..used]);
}

noinline fn beginDecode(allocator: Allocator, header: Header, len: usize, cap: usize) DecodeError!void {
    const limit = budget(header, len) orelse return error.ImageTooLarge;
    if (limit > cap) return error.ImageTooLarge;
    memory.begin(allocator, limit);
}

/// Returns the most bytes stb may hold while decoding an image with this
/// header from encoded_len bytes, or null past max_decode_bytes.
fn budget(header: Header, encoded_len: usize) ?usize {
    const width = std.math.add(usize, header.size.width, block_pixels - 1) catch return null;
    const height = std.math.add(usize, header.size.height, block_pixels - 1) catch return null;
    const blocks = std.math.mul(usize, width / block_pixels, height / block_pixels) catch return null;
    const image = std.math.mul(usize, blocks, block_pixels * block_pixels * @sizeOf(Pixel) * png_image_buffers) catch return null;
    const scaled = std.math.mul(usize, image, header.sample_bytes) catch return null;
    const total = std.math.add(usize, scaled, encoded_len +| fixed_bytes) catch return null;
    return if (total <= values.max_decode_bytes) total else null;
}

fn size(width: c_int, height: c_int) DecodeError!Size {
    return .{
        .width = std.math.cast(usize, width) orelse return error.InvalidImage,
        .height = std.math.cast(usize, height) orelse return error.InvalidImage,
    };
}

// stb replaces a failed format probe's reason with "unknown image type".
// Read PNG dimensions on that error path.
fn oversizedPng(bytes: []const u8) bool {
    if (bytes.len < png_format.header_bytes or !std.mem.startsWith(u8, bytes, png_format.header_prefix)) return false;
    const offset = png_format.dimensions_offset;
    const width = std.mem.readInt(u32, bytes[offset..][0..4], .big);
    const height = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .big);
    return width != 0 and height != 0 and (width > values.max_extent or height > values.max_extent);
}

test "a truncated PNG header is rejected" {
    try std.testing.expectError(error.InvalidImage, probe(std.testing.allocator, "\x89PNG\r\n\x1a\n", values.max_decode_bytes));
}

test "the largest 8-bit images fit the decode budget and a 16-bit one does not" {
    const tall: Size = .{ .width = values.max_pixels / values.max_extent, .height = values.max_extent };
    // A width just past a block boundary pads the most.
    const padded: Size = .{ .width = 4097, .height = values.max_pixels / 4097 };
    for ([_]Size{ tall, padded }) |largest| {
        try std.testing.expect(largest.pixelCount() != null);
        try std.testing.expect(budget(.{ .size = largest, .sample_bytes = 1 }, values.max_encoded_bytes) != null);
        try std.testing.expectEqual(@as(?usize, null), budget(.{ .size = largest, .sample_bytes = 2 }, 0));
    }
}

test {
    std.testing.refAllDecls(@This());
}
