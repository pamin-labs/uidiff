//! Decodes PNG scanlines under a budget with the stb fallback.

const std = @import("std");
const deflate = @import("deflate.zig");
const values = @import("../../value.zig");
const png_format = @import("../png_format.zig");
const stb = @import("../stb.zig");
const scanlines = @import("scanlines.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Malformed PNG bytes, a decode past the memory budget, or allocation failure.
pub const DecodeError = stb.DecodeError;

const single_rgb_header: stb.Header = .{ .size = .{ .width = 1, .height = 1 }, .sample_bytes = 1 };
const single_rgb_pixel: values.Pixel = .{ 23, 57, 91, 255 };

/// Decodes the probed dimensions through the scanline or legacy decoder.
pub fn decode(allocator: Allocator, bytes: []const u8, header: stb.Header, cap: usize) stb.DecodeError![]values.Pixel {
    return load(allocator, bytes, header, cap);
}

/// Runs bounded scanline decoding. Null requests the legacy fallback.
pub fn loadStreaming(allocator: Allocator, bytes: []const u8, header: stb.Header, cap: usize) DecodeError!?[]values.Pixel {
    return stb.withDecodeBudget(scanlines.decode, allocator, bytes, header, cap);
}

fn load(allocator: Allocator, bytes: []const u8, header: stb.Header, cap: usize) DecodeError![]values.Pixel {
    return stb.withDecodeBudget(loadPixels, allocator, bytes, header, cap);
}

fn loadPixels(bytes: []const u8, size: values.Size) DecodeError![]values.Pixel {
    if (try scanlines.decode(bytes, size)) |pixels| return pixels;
    return stb.loadStb(bytes, size);
}

fn singleRgbPng(allocator: Allocator) deflate.EncodeError!Writer.Allocating {
    var encoded: Writer.Allocating = .init(allocator);
    errdefer encoded.deinit();
    const r, const g, const b, _ = single_rgb_pixel;
    try writeTestPng(allocator, &encoded.writer, single_rgb_header.size, png_format.rgb_color, &.{ 0, r, g, b });
    return encoded;
}

fn writeTestPng(allocator: Allocator, out: *Writer, size: values.Size, color: u8, filtered_rows: []const u8) deflate.EncodeError!void {
    try out.writeAll(png_format.signature);
    var header: [png_format.header_data_bytes]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], @intCast(size.width), .big);
    std.mem.writeInt(u32, header[4..8], @intCast(size.height), .big);
    header[8] = png_format.sample_depth;
    header[9] = color;
    try deflate.chunk(out, png_format.header_type, &header);
    var staging: [deflate.chunk_bytes]u8 = undefined;
    var backing = allocator;
    var deflater: deflate.Deflater = undefined;
    try deflater.init(&backing, out, &staging);
    defer deflater.deinit();
    try deflater.write(filtered_rows);
    try deflater.finish();
    try deflate.chunk(out, "IEND", "");
}

fn checkTestFilters(comptime channels: usize, color: u8, filters: []const u8) !void {
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

    var output: Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeTestPng(allocator, &output.writer, size, color, filtered[0 .. filters.len * (1 + row_bytes)]);
    const header = try stb.probe(allocator, output.written(), values.max_decode_bytes);
    for (filters) |filter_byte| if (filter_byte > png_format.paeth_filter) {
        try std.testing.expectEqual(@as(?[]values.Pixel, null), try loadStreaming(allocator, output.written(), header, values.max_decode_bytes));
        try std.testing.expectError(error.InvalidImage, load(allocator, output.written(), header, values.max_decode_bytes));
        return;
    };
    const found = try load(allocator, output.written(), header, values.max_decode_bytes);
    defer stb.release(allocator, found);
    const legacy = try stb.loadLegacy(allocator, output.written(), header, values.max_decode_bytes);
    defer stb.release(allocator, legacy);
    try std.testing.expectEqualSlices(values.Pixel, pixels[0 .. width * filters.len], legacy);
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

fn firstTestIdat(png: []const u8) []const u8 {
    const header_end = png_format.header_bytes + @sizeOf(u32);
    const idat = png[header_end..];
    std.debug.assert(std.mem.eql(u8, idat[4..8], "IDAT"));
    return idat[8..][0..std.mem.readInt(u32, idat[0..4], .big)];
}

fn splitTestIdat(out: *Writer, png: []const u8, data: []const u8, at: usize) deflate.EncodeError!void {
    const header_end = png_format.header_bytes + @sizeOf(u32);
    try out.writeAll(png[0..header_end]);
    try deflate.chunk(out, "IDAT", data[0..at]);
    try deflate.chunk(out, "IDAT", "");
    try deflate.chunk(out, "IDAT", data[at..]);
    try deflate.chunk(out, "IEND", "");
}

fn fuzzStreamingRows(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    const filter_variants = png_format.paeth_filter + 2; // Five filters and the first invalid byte.
    const seed = smith.valueRangeAtMost(u8, 0, 4 * filter_variants - 1);
    const max_width = 24;
    const max_height = 8;
    const width = smith.valueRangeAtMost(u8, 1, max_width);
    const height = smith.valueRangeAtMost(u8, 1, max_height);
    const size: values.Size = .{ .width = width, .height = height };
    const color: u8 = if (seed % 2 == 0) png_format.rgb_color else png_format.rgba_color;
    const channels: usize = if (color == png_format.rgb_color) 3 else 4;
    var rows: [max_height * (1 + max_width * 4)]u8 = undefined;
    const valid = rows[0 .. size.height * (1 + size.width * channels)];
    const length = if (smith.value(bool)) smith.slice(valid) else complete: {
        for (0..size.height) |y| {
            const at = y * (1 + size.width * channels);
            valid[at] = if (y == 0) (seed / 2) % filter_variants else smith.valueRangeAtMost(u8, 0, filter_variants - 1);
            for (valid[at + 1 ..][0 .. size.width * channels]) |*value| value.* = smith.value(u8);
        }
        break :complete valid.len;
    };
    var output: Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeTestPng(allocator, &output.writer, size, color, valid[0..length]);
    var split: Writer.Allocating = .init(allocator);
    defer split.deinit();
    const bytes = if (seed >= 2 * filter_variants) split_bytes: {
        const payload = firstTestIdat(output.written());
        const offset = smith.valueRangeAtMost(u16, 0, @intCast(payload.len));
        try splitTestIdat(&split.writer, output.written(), payload, offset);
        break :split_bytes split.written();
    } else output.written();
    const header: stb.Header = .{ .size = size, .sample_bytes = 1 };
    const found = try loadStreaming(allocator, bytes, header, values.max_decode_bytes) orelse return;
    defer stb.release(allocator, found);
    const legacy = try stb.loadLegacy(allocator, bytes, header, values.max_decode_bytes);
    defer stb.release(allocator, legacy);
    try std.testing.expectEqualSlices(values.Pixel, legacy, found);
}

test "PNG filters preserve RGB8 and RGBA8 across streaming and fallback" {
    for ([_][]const u8{ &.{ 3, 3, 0 }, &.{ 1, 2, 4 }, &.{ 4, 1, 2 }, &.{ 3, 0, 5 } }) |filters| {
        try checkTestFilters(3, png_format.rgb_color, filters);
        try checkTestFilters(4, png_format.rgba_color, filters);
    }
}

test "RGB8 accepts every legal IDAT split and refuses a truncated DEFLATE body" {
    const allocator = std.testing.allocator;
    var encoded = try singleRgbPng(allocator);
    defer encoded.deinit();
    const payload = firstTestIdat(encoded.written());

    var rebuilt: Writer.Allocating = .init(allocator);
    defer rebuilt.deinit();
    for (0..payload.len + 1) |at| {
        rebuilt.clearRetainingCapacity();
        try splitTestIdat(&rebuilt.writer, encoded.written(), payload, at);
        const found = try load(allocator, rebuilt.written(), single_rgb_header, values.max_decode_bytes);
        defer stb.release(allocator, found);
        try std.testing.expectEqual(single_rgb_pixel, found[0]);
    }
    rebuilt.clearRetainingCapacity();
    try splitTestIdat(&rebuilt.writer, encoded.written(), payload[0..3], 1);
    try std.testing.expectError(error.InvalidImage, load(allocator, rebuilt.written(), single_rgb_header, values.max_decode_bytes));
    try std.testing.expectError(error.ImageTooLarge, load(allocator, encoded.written(), single_rgb_header, @sizeOf(values.Pixel)));
}

test "RGB8 preserves legacy checksum tolerance" {
    const allocator = std.testing.allocator;
    var encoded = try singleRgbPng(allocator);
    defer encoded.deinit();
    const idat = png_format.header_bytes + @sizeOf(u32);
    const len = firstTestIdat(encoded.written()).len;
    const changed = try allocator.dupe(u8, encoded.written());
    defer allocator.free(changed);
    // Alter both the zlib checksum payload and the following PNG CRC.
    changed[idat + 8 + len - 1] ^= 1;
    changed[idat + 8 + len] ^= 1;
    const found = try load(allocator, changed, single_rgb_header, values.max_decode_bytes);
    defer stb.release(allocator, found);
    try std.testing.expectEqual(single_rgb_pixel, found[0]);
}

test "RGB8 transparent colour keys use the legacy decoder" {
    const allocator = std.testing.allocator;
    const raw = [_]u8{ 0, 23, 57, 91 };
    var png: Writer.Allocating = .init(allocator);
    defer png.deinit();
    try writeTestPng(allocator, &png.writer, .{ .width = 1, .height = 1 }, png_format.rgb_color, &raw);

    var keyed: Writer.Allocating = .init(allocator);
    defer keyed.deinit();
    const header_end = png_format.header_bytes + @sizeOf(u32); // IHDR checksum.
    try keyed.writer.writeAll(png.written()[0..header_end]);
    try deflate.chunk(&keyed.writer, "tRNS", &.{ 0, raw[1], 0, raw[2], 0, raw[3] });
    try keyed.writer.writeAll(png.written()[header_end..]);

    const header = try stb.probe(allocator, keyed.written(), values.max_decode_bytes);
    try std.testing.expectEqual(@as(?[]values.Pixel, null), try loadStreaming(allocator, keyed.written(), header, values.max_decode_bytes));
    const pixels = try load(allocator, keyed.written(), header, values.max_decode_bytes);
    defer stb.release(allocator, pixels);
    try std.testing.expectEqual(values.Pixel{ raw[1], raw[2], raw[3], 0 }, pixels[0]);
}

test "RGB8 streaming leaves grayscale, indexed, wide and interlaced PNGs to stb" {
    const allocator = std.testing.allocator;
    const size: values.Size = .{ .width = 1, .height = 1 };
    const profiles = [_]struct {
        color: u8,
        depth: u8 = png_format.sample_depth,
        interlace: u8 = 0,
        raw: []const u8,
        palette: ?[]const u8 = null,
        expected: values.Pixel,
    }{
        .{ .color = 0, .raw = &.{ 0, 37 }, .expected = .{ 37, 37, 37, 255 } },
        .{ .color = 4, .raw = &.{ 0, 37, 99 }, .expected = .{ 37, 37, 37, 99 } },
        .{ .color = 3, .depth = 1, .raw = &.{ 0, 0 }, .palette = &.{ 11, 22, 33 }, .expected = .{ 11, 22, 33, 255 } },
        .{ .color = png_format.rgb_color, .depth = 16, .raw = &.{ 0, 11, 0, 22, 0, 33, 0 }, .expected = .{ 11, 22, 33, 255 } },
        .{ .color = png_format.rgba_color, .interlace = 1, .raw = &.{ 0, 11, 22, 33, 44 }, .expected = .{ 11, 22, 33, 44 } },
    };
    for (profiles) |profile| {
        var encoded: Writer.Allocating = .init(allocator);
        defer encoded.deinit();
        try writeTestPng(allocator, &encoded.writer, size, profile.color, profile.raw);

        const checksum_start = png_format.signature.len + @sizeOf(u32);
        const header_end = png_format.header_bytes + @sizeOf(u32);
        var header = encoded.written()[0..header_end].*;
        header[png_format.profile_offset] = profile.depth;
        header[png_format.header_bytes - 1] = profile.interlace;
        std.mem.writeInt(u32, header[png_format.header_bytes..][0..4], std.hash.Crc32.hash(header[checksum_start..png_format.header_bytes]), .big);
        try std.testing.expect(!scanlines.streamingHeader(&header));

        var patched: Writer.Allocating = .init(allocator);
        defer patched.deinit();
        try patched.writer.writeAll(&header);
        if (profile.palette) |palette| try deflate.chunk(&patched.writer, "PLTE", palette);
        try patched.writer.writeAll(encoded.written()[header_end..]);

        const metadata = try stb.probe(allocator, patched.written(), values.max_decode_bytes);
        try std.testing.expectEqual(@as(?[]values.Pixel, null), try loadStreaming(allocator, patched.written(), metadata, values.max_decode_bytes));
        const pixels = try load(allocator, patched.written(), metadata, values.max_decode_bytes);
        defer stb.release(allocator, pixels);
        try std.testing.expectEqual(profile.expected, pixels[0]);
    }
}

test "the streaming probe agrees with the PNG header layout" {
    var header: [png_format.header_bytes]u8 = @splat(0);
    @memcpy(header[0..png_format.header_prefix.len], png_format.header_prefix);
    const offset = png_format.dimensions_offset;
    std.mem.writeInt(u32, header[offset..][0..4], 253, .big);
    std.mem.writeInt(u32, header[offset + 4 ..][0..4], 58, .big);
    const profile = header[offset + 2 * @sizeOf(u32) ..];
    const depth, const colour, const interlace = .{ 0, 1, 4 };
    profile[depth] = 8;
    profile[colour] = png_format.rgba_color;
    try std.testing.expect(scanlines.streamingHeader(&header));
    try std.testing.expect(!scanlines.streamingHeader(header[0 .. header.len - 1]));
    profile[colour] = png_format.rgb_color;
    try std.testing.expect(scanlines.streamingHeader(&header));
    profile[depth] = 16;
    try std.testing.expect(!scanlines.streamingHeader(&header));
    profile[depth] = 8;
    profile[interlace] = 1;
    try std.testing.expect(!scanlines.streamingHeader(&header));
    profile[interlace] = 0;
    profile[colour] = 3;
    try std.testing.expect(!scanlines.streamingHeader(&header));
    profile[colour] = png_format.rgba_color;
    for (0..png_format.header_prefix.len) |i| {
        header[i] ^= 1;
        try std.testing.expect(!scanlines.streamingHeader(&header));
        header[i] ^= 1;
    }
}

test "fuzz streaming PNG reconstruction" {
    comptime var corpus: []const []const u8 = &.{};
    inline for (0..4 * (png_format.paeth_filter + 2)) |seed| corpus = corpus ++ .{&[_]u8{seed}};
    try std.testing.fuzz({}, fuzzStreamingRows, .{ .corpus = corpus });
}

test {
    std.testing.refAllDecls(@This());
}
