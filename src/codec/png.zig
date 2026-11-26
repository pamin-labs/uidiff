//! PNG format registration and encoding facade.

const std = @import("std");
const value = @import("../value.zig");
const Pixel = value.Pixel;
const Io = std.Io;
const zlib = @import("png/zlib.zig");
const encoder = @import("png/encoder.zig");
const decoder = @import("png/decoder.zig");
const png_format = @import("png_format");
const stb = @import("png/stb.zig");

/// Malformed PNG bytes, a decode past the memory budget, or allocation failure.
pub const DecodeError = decoder.DecodeError;
/// Allocation, invalid image or output failures.
pub const EncodeError = zlib.EncodeError;
/// Decodes the probed dimensions through the scanline or legacy decoder.
pub const decode = decoder.decode;
/// Encodes a valid image. Allocates the compressor's window and one filtered row.
pub const write = encoder.write;
/// Encodes PNG from a row source with the encoder's source contract.
pub const writeRows = encoder.writeRows;
/// Encodes PNG from a row source with optional I/O concurrency.
pub const writeRowsWithIo = encoder.writeRowsWithIo;

/// Probes the dimensions and channel depth.
pub const probe = stb.probe;

/// Releases decoded pixels through their PNG or fallback allocator.
pub const release = stb.release;

/// Recognizes the PNG signature.
pub fn matches(prefix: []const u8) bool {
    return std.mem.startsWith(u8, prefix, png_format.signature);
}

test "streaming PNG matches procedural RGBA across dictionary wraps" {
    const width = 193;
    const height = 257;
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(Pixel, width * height);
    defer allocator.free(pixels);
    for (pixels, 0..) |*pixel, i| {
        const x = i % width;
        const y = i / width;
        pixel.* = .{ @intCast(x), @intCast(y % 256), @intCast((x + y / 2) % 256), @intCast(i % 256) };
    }
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try write(allocator, .{ .width = width, .height = height, .pixels = pixels }, &output.writer);
    const header = try probe(allocator, output.written(), value.max_decode_bytes);
    const streamed = (try decoder.loadStreaming(allocator, output.written(), header, value.max_decode_bytes)) orelse return error.TestUnexpectedResult;
    defer stb.release(allocator, streamed);
    try std.testing.expectEqualSlices(Pixel, pixels, streamed);
}

test "RGB8 streaming preserves opaque partial rows" {
    const width = 29;
    const height = 1103;
    const allocator = std.testing.allocator;
    var pixels: [width * height]Pixel = undefined;
    for (&pixels, 0..) |*pixel, i| {
        pixel.* = .{ @intCast(i % 229), @intCast((3 * i) % 231), @intCast((i / width) % 233), 255 };
    }
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try write(allocator, .{ .width = width, .height = height, .pixels = &pixels }, &output.writer);
    const probed = try probe(allocator, output.written(), value.max_decode_bytes);
    const streamed = (try decoder.loadStreaming(allocator, output.written(), probed, value.max_decode_bytes)) orelse return error.TestUnexpectedResult;
    const legacy = try stb.loadLegacy(allocator, output.written(), probed, value.max_decode_bytes);
    defer stb.release(allocator, legacy);
    defer stb.release(allocator, streamed);
    try std.testing.expectEqualSlices(Pixel, &pixels, legacy);
    try std.testing.expectEqualSlices(Pixel, legacy, streamed);
}

test {
    std.testing.refAllDecls(stb);
    std.testing.refAllDecls(@This());
}
