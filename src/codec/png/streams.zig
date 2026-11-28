//! Writes the synthetic PNG streams of the decoder's tests. Only test
//! declarations import it.
const std = @import("std");
const zlib = @import("zlib.zig");
const value = @import("../../value.zig");
const png_format = @import("png_format");
const stb = @import("stb.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Offset after the IHDR checksum.
pub const header_end = png_format.header_end;

/// Validated dimensions of the one-pixel RGB fixture.
pub const single_rgb_header: stb.Header = .{ .size = .{ .width = 1, .height = 1 }, .sample_bytes = 1 };
/// Expected opaque pixel in the one-pixel RGB fixture.
pub const single_rgb_pixel: value.Pixel = .{ 23, 57, 91, 255 };

/// Builds the one-pixel RGB fixture. The caller owns the output writer.
pub fn singleRgbPng(allocator: Allocator) zlib.EncodeError!Writer.Allocating {
    var encoded: Writer.Allocating = .init(allocator);
    errdefer encoded.deinit();
    const r, const g, const b, _ = single_rgb_pixel;
    try writePng(allocator, &encoded.writer, single_rgb_header.size, .rgb, &.{ 0, r, g, b });
    return encoded;
}

/// Writes a complete PNG from already filtered rows.
pub fn writePng(allocator: Allocator, out: *Writer, size: value.Size, colour: png_format.Colour, filtered_rows: []const u8) zlib.EncodeError!void {
    try writeHeader(out, size, colour);
    try writeData(allocator, out, filtered_rows);
}

/// Writes the signature and an eight-bit, noninterlaced IHDR.
pub fn writeHeader(out: *Writer, size: value.Size, colour: png_format.Colour) zlib.EncodeError!void {
    try png_format.writeHeader(zlib.chunk, out, @intCast(size.width), @intCast(size.height), colour);
}

/// Compresses the given rows and terminates the PNG stream.
pub fn writeData(allocator: Allocator, out: *Writer, filtered_rows: []const u8) zlib.EncodeError!void {
    var staging: [zlib.chunk_bytes]u8 = undefined;
    var backing = allocator;
    var deflater: zlib.Deflater = undefined;
    try deflater.init(&backing, out, &staging);
    defer deflater.deinit();
    try deflater.write(filtered_rows);
    try deflater.finish();
    try zlib.chunk(out, png_format.iend_type, "");
}

/// Applies each filter with a scalar reference predictor.
pub fn filterRows(channels: usize, width: usize, filters: []const u8, raw: []const u8, filtered: []u8) void {
    const row_bytes = width * channels;
    for (filters, 0..) |filter_byte, y| {
        const row = filtered[y * (1 + row_bytes) ..][0 .. 1 + row_bytes];
        row[0] = filter_byte;
        for (row[1..], 0..) |*out, x| {
            const at = y * row_bytes + x;
            const left = if (x >= channels) raw[at - channels] else 0;
            const above = if (y > 0) raw[at - row_bytes] else 0;
            const diagonal = if (x >= channels and y > 0) raw[at - row_bytes - channels] else 0;
            const predicted: u8 = switch (std.enums.fromInt(png_format.Filter, filter_byte) orelse .none) {
                .sub => left,
                .up => above,
                .average => @intCast((@as(u16, left) + above) / 2),
                .paeth => @intCast(png_format.paeth(left, above, diagonal)),
                .none => 0,
            };
            out.* = raw[at] -% predicted;
        }
    }
}

/// Borrows the compressed bytes from an IDAT chunk.
pub fn firstIdat(idat: []const u8) []const u8 {
    var chunks: png_format.Chunks = .{ .remaining = idat };
    const chunk = chunks.next() orelse unreachable; // The test just wrote this chunk.
    std.debug.assert(std.mem.eql(u8, &chunk.kind, png_format.idat_type));
    return chunk.data;
}

/// Writes the same compressed bytes across separate IDAT chunks.
pub fn splitIdat(out: *Writer, prefix: []const u8, data: []const u8, at: usize) zlib.EncodeError!void {
    try out.writeAll(prefix);
    try zlib.chunk(out, png_format.idat_type, data[0..at]);
    try zlib.chunk(out, png_format.idat_type, "");
    try zlib.chunk(out, png_format.idat_type, data[at..]);
    try zlib.chunk(out, png_format.iend_type, "");
}

test {
    std.testing.refAllDecls(@This());
}
