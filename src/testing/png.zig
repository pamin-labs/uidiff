//! Procedural PNG streams with controlled filters and IDAT boundaries.
const std = @import("std");
const deflate = @import("../codec/png/deflate.zig");
const values = @import("../value.zig");
const png_format = @import("../codec/png_format.zig");
const stb = @import("../codec/stb.zig");
const scanlines = @import("../codec/png/scanlines.zig");
const decoder = @import("../codec/png/decoder.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Profile = scanlines.Profile;

/// Offset after the IHDR checksum.
pub const header_end = png_format.header_bytes + @sizeOf(u32); // Includes the IHDR checksum.

/// Validated dimensions of the one-pixel RGB fixture.
pub const single_rgb_header: stb.Header = .{ .size = .{ .width = 1, .height = 1 }, .sample_bytes = 1 };
/// Expected opaque pixel in the one-pixel RGB fixture.
pub const single_rgb_pixel: values.Pixel = .{ 23, 57, 91, 255 };
const fuzz_profiles = std.enums.values(Profile);
const fuzz_filter_count = png_format.paeth_filter + 2; // Five filters and the first invalid byte.
/// First seed that divides the compressed stream between IDAT chunks.
pub const fuzz_split_seed = fuzz_profiles.len * fuzz_filter_count;

/// Builds the one-pixel RGB fixture. The caller owns the output writer.
pub fn singleRgbPng(allocator: Allocator) deflate.EncodeError!Writer.Allocating {
    var encoded: Writer.Allocating = .init(allocator);
    errdefer encoded.deinit();
    const r, const g, const b, _ = single_rgb_pixel;
    try writeTestPng(allocator, &encoded.writer, single_rgb_header.size, png_format.rgb_color, &.{ 0, r, g, b });
    return encoded;
}

/// Writes a complete PNG from already filtered rows.
pub fn writeTestPng(allocator: Allocator, out: *Writer, size: values.Size, color: u8, filtered_rows: []const u8) deflate.EncodeError!void {
    try writeTestHeader(out, size, color);
    try writeTestData(allocator, out, filtered_rows);
}

/// Writes the signature and an eight-bit, noninterlaced IHDR.
pub fn writeTestHeader(out: *Writer, size: values.Size, color: u8) deflate.EncodeError!void {
    try out.writeAll(png_format.signature);
    var header: [png_format.header_data_bytes]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], @intCast(size.width), .big);
    std.mem.writeInt(u32, header[4..8], @intCast(size.height), .big);
    header[8] = png_format.sample_depth;
    header[9] = color;
    try deflate.chunk(out, png_format.header_type, &header);
}

/// Compresses the given rows and terminates the PNG stream.
pub fn writeTestData(allocator: Allocator, out: *Writer, filtered_rows: []const u8) deflate.EncodeError!void {
    var staging: [deflate.chunk_bytes]u8 = undefined;
    var backing = allocator;
    var deflater: deflate.Deflater = undefined;
    try deflater.init(&backing, out, &staging);
    defer deflater.deinit();
    try deflater.write(filtered_rows);
    try deflater.finish();
    try deflate.chunk(out, "IEND", "");
}

/// Checks streaming and fallback reconstruction for a filter sequence.
pub fn checkTestFilters(comptime channels: usize, color: u8, filters: []const u8) !void {
    const allocator = std.testing.allocator;
    const width = 7;
    const row_bytes = width * channels;
    const size: values.Size = .{ .width = width, .height = filters.len };
    var pixels: [3 * width]values.Pixel = undefined;
    for (pixels[0 .. width * filters.len], 0..) |*pixel, i| {
        pixel.* = .{ @intCast(7 + 11 * i), @intCast(101 - 3 * i), @intCast(2 + i * 7), if (channels == 3) 255 else @intCast(254 - 5 * i) };
    }
    var raw: [3 * row_bytes]u8 = undefined;
    for (pixels[0 .. width * filters.len], 0..) |pixel, i| @memcpy(raw[i * channels ..][0..channels], pixel[0..channels]);
    var filtered: [3 * (1 + row_bytes)]u8 = undefined;
    filterTestRows(channels, width, filters, &raw, &filtered);

    var output: Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeTestPng(allocator, &output.writer, size, color, filtered[0 .. filters.len * (1 + row_bytes)]);
    const header = try stb.probe(allocator, output.written(), values.max_decode_bytes);
    for (filters) |filter_byte| if (filter_byte > png_format.paeth_filter) {
        try std.testing.expectEqual(@as(?[]values.Pixel, null), try decoder.loadStreaming(allocator, output.written(), header, values.max_decode_bytes));
        try std.testing.expectError(error.InvalidImage, decoder.decode(allocator, output.written(), header, values.max_decode_bytes));
        return;
    };
    const found = try decoder.decode(allocator, output.written(), header, values.max_decode_bytes);
    defer stb.release(allocator, found);
    const legacy = try stb.loadLegacy(allocator, output.written(), header, values.max_decode_bytes);
    defer stb.release(allocator, legacy);
    try std.testing.expectEqualSlices(values.Pixel, pixels[0 .. width * filters.len], legacy);
    try std.testing.expectEqualSlices(values.Pixel, legacy, found);
}

/// Applies each filter with a scalar reference predictor.
pub fn filterTestRows(channels: usize, width: usize, filters: []const u8, raw: []const u8, filtered: []u8) void {
    const row_bytes = width * channels;
    for (filters, 0..) |filter_byte, y| {
        const row = filtered[y * (1 + row_bytes) ..][0 .. 1 + row_bytes];
        row[0] = filter_byte;
        for (row[1..], 0..) |*out, x| {
            const at = y * row_bytes + x;
            const left = if (x >= channels) raw[at - channels] else 0;
            const above = if (y > 0) raw[at - row_bytes] else 0;
            const diagonal = if (x >= channels and y > 0) raw[at - row_bytes - channels] else 0;
            const predicted: u8 = switch (filter_byte) {
                png_format.sub_filter => left,
                png_format.up_filter => above,
                3 => @intCast((@as(u16, left) + above) / 2),
                png_format.paeth_filter => referencePaeth(left, above, diagonal),
                else => 0,
            };
            out.* = raw[at] -% predicted;
        }
    }
}

/// Borrows the compressed bytes from an IDAT chunk.
pub fn firstTestIdat(idat: []const u8) []const u8 {
    std.debug.assert(std.mem.eql(u8, idat[4..8], "IDAT"));
    return idat[8..][0..std.mem.readInt(u32, idat[0..4], .big)];
}

/// Writes the same compressed bytes across separate IDAT chunks.
pub fn splitTestIdat(out: *Writer, prefix: []const u8, data: []const u8, at: usize) deflate.EncodeError!void {
    try out.writeAll(prefix);
    try deflate.chunk(out, "IDAT", data[0..at]);
    try deflate.chunk(out, "IDAT", "");
    try deflate.chunk(out, "IDAT", data[at..]);
    try deflate.chunk(out, "IEND", "");
}

/// Checks streaming reconstruction against the fallback for a Smith input.
pub fn fuzzStreamingRows(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    const profile_count: u8 = fuzz_profiles.len;
    const seed = smith.valueRangeAtMost(u8, 0, 2 * fuzz_split_seed - 1);
    const profile = fuzz_profiles[seed % profile_count];
    const max_width = 24;
    const max_height = 8;
    const width = smith.valueRangeAtMost(u8, 1, max_width);
    const height = smith.valueRangeAtMost(u8, 1, max_height);
    const size: values.Size = .{ .width = width, .height = height };
    const channels = profile.samplesPerPixel();
    var rows: [max_height * (1 + max_width * 4)]u8 = undefined;
    const row_bytes = 1 + size.width * channels;
    const valid = rows[0 .. size.height * row_bytes];
    const length = if (smith.value(bool)) smith.slice(valid) else complete: {
        for (0..size.height) |y| {
            const row = valid[y * row_bytes ..][0..row_bytes];
            row[0] = if (y == 0) (seed / profile_count) % fuzz_filter_count else smith.valueRangeAtMost(u8, 0, fuzz_filter_count - 1);
            for (row[1..]) |*value| value.* = smith.value(u8);
        }
        break :complete valid.len;
    };
    var output: Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeTestHeader(&output.writer, size, @backingInt(profile));
    switch (profile) {
        .indexed => {
            // Every reconstructed byte must name a defined palette entry.
            var colors: [256 * 3]u8 = undefined;
            var alphas: [256]u8 = undefined;
            for (&colors) |*value| value.* = smith.value(u8);
            const alpha_count = smith.valueRangeAtMost(u16, 1, alphas.len);
            for (alphas[0..alpha_count]) |*value| value.* = smith.value(u8);
            try deflate.chunk(&output.writer, "PLTE", &colors);
            try deflate.chunk(&output.writer, "tRNS", alphas[0..alpha_count]);
        },
        .gray => if (smith.value(bool)) try deflate.chunk(&output.writer, "tRNS", &.{ 0, smith.value(u8) }),
        .rgb, .rgba => {},
    }
    const idat_offset = output.written().len;
    try writeTestData(allocator, &output.writer, valid[0..length]);
    var split: Writer.Allocating = .init(allocator);
    defer split.deinit();
    const bytes = if (seed >= fuzz_split_seed) split_bytes: {
        const payload = firstTestIdat(output.written()[idat_offset..]);
        const offset = smith.valueRangeAtMost(u16, 0, @intCast(payload.len));
        try splitTestIdat(&split.writer, output.written()[0..idat_offset], payload, offset);
        break :split_bytes split.written();
    } else output.written();
    const header: stb.Header = .{ .size = size, .sample_bytes = 1 };
    const found = try decoder.loadStreaming(allocator, bytes, header, values.max_decode_bytes) orelse return;
    defer stb.release(allocator, found);
    const legacy = try stb.loadLegacy(allocator, bytes, header, values.max_decode_bytes);
    defer stb.release(allocator, legacy);
    try std.testing.expectEqualSlices(values.Pixel, legacy, found);
}

fn referencePaeth(left: u8, above: u8, diagonal: u8) u8 {
    const estimate = @as(i16, left) + above - diagonal;
    const a = @abs(estimate - left);
    const b = @abs(estimate - above);
    const c = @abs(estimate - diagonal);
    if (a <= b and a <= c) return left;
    if (b <= c) return above;
    return diagonal;
}
