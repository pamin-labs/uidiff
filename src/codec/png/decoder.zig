//! Decodes PNG scanlines under a budget with the stb fallback.

const std = @import("std");
const zlib = @import("zlib.zig");
const values = @import("../../value.zig");
const png_format = @import("png_format");
const stb = @import("stb.zig");
const scanlines = @import("scanlines.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Profile = scanlines.Profile;

/// Malformed PNG bytes, a decode past the memory budget, or allocation failure.
pub const DecodeError = stb.DecodeError;

// Writers shared by the decoder's synthetic test streams.
const PngFixture = struct {
    /// Offset after the IHDR checksum.
    const header_end = png_format.header_end;

    /// Validated dimensions of the one-pixel RGB PngFixture.
    const single_rgb_header: stb.Header = .{ .size = .{ .width = 1, .height = 1 }, .sample_bytes = 1 };
    /// Expected opaque pixel in the one-pixel RGB PngFixture.
    const single_rgb_pixel: values.Pixel = .{ 23, 57, 91, 255 };

    /// Builds the one-pixel RGB PngFixture. The caller owns the output writer.
    fn singleRgbPng(allocator: Allocator) zlib.EncodeError!Writer.Allocating {
        var encoded: Writer.Allocating = .init(allocator);
        errdefer encoded.deinit();
        const r, const g, const b, _ = single_rgb_pixel;
        try writePng(allocator, &encoded.writer, single_rgb_header.size, .rgb, &.{ 0, r, g, b });
        return encoded;
    }

    /// Writes a complete PNG from already filtered rows.
    fn writePng(allocator: Allocator, out: *Writer, size: values.Size, colour: png_format.Colour, filtered_rows: []const u8) zlib.EncodeError!void {
        try writeHeader(out, size, colour);
        try writeData(allocator, out, filtered_rows);
    }

    /// Writes the signature and an eight-bit, noninterlaced IHDR.
    fn writeHeader(out: *Writer, size: values.Size, colour: png_format.Colour) zlib.EncodeError!void {
        try png_format.writeHeader(zlib.chunk, out, @intCast(size.width), @intCast(size.height), colour);
    }

    /// Compresses the given rows and terminates the PNG stream.
    fn writeData(allocator: Allocator, out: *Writer, filtered_rows: []const u8) zlib.EncodeError!void {
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
    fn filterRows(channels: usize, width: usize, filters: []const u8, raw: []const u8, filtered: []u8) void {
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
    fn firstIdat(idat: []const u8) []const u8 {
        var chunks: png_format.Chunks = .{ .remaining = idat };
        const chunk = chunks.next() orelse unreachable; // The test just wrote this chunk.
        std.debug.assert(std.mem.eql(u8, &chunk.kind, png_format.idat_type));
        return chunk.data;
    }

    /// Writes the same compressed bytes across separate IDAT chunks.
    fn splitIdat(out: *Writer, prefix: []const u8, data: []const u8, at: usize) zlib.EncodeError!void {
        try out.writeAll(prefix);
        try zlib.chunk(out, png_format.idat_type, data[0..at]);
        try zlib.chunk(out, png_format.idat_type, "");
        try zlib.chunk(out, png_format.idat_type, data[at..]);
        try zlib.chunk(out, png_format.iend_type, "");
    }
};

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

test "PNG filters preserve RGB8 and RGBA8 across streaming and fallback" {
    const capture = struct {
        fn checkFilters(comptime channels: usize, colour: png_format.Colour, filters: []const u8) !void {
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
            PngFixture.filterRows(channels, width, filters, &raw, &filtered);

            var output: Writer.Allocating = .init(allocator);
            defer output.deinit();
            try PngFixture.writePng(allocator, &output.writer, size, colour, filtered[0 .. filters.len * (1 + row_bytes)]);
            const header = try stb.probe(allocator, output.written(), values.max_decode_bytes);
            for (filters) |filter_byte| if (filter_byte > @backingInt(png_format.Filter.paeth)) {
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
    };
    for ([_][]const u8{ &.{ 3, 3, 0 }, &.{ 1, 2, 4 }, &.{ 4, 1, 2 }, &.{ 3, 0, 5 } }) |filters| {
        try capture.checkFilters(3, .rgb, filters);
        try capture.checkFilters(4, .rgba, filters);
    }
}

test "RGB8 accepts every legal IDAT split and refuses a truncated DEFLATE body" {
    const allocator = std.testing.allocator;
    var encoded = try PngFixture.singleRgbPng(allocator);
    defer encoded.deinit();
    const payload = PngFixture.firstIdat(encoded.written()[PngFixture.header_end..]);

    var rebuilt: Writer.Allocating = .init(allocator);
    defer rebuilt.deinit();
    for (0..payload.len + 1) |at| {
        rebuilt.clearRetainingCapacity();
        try PngFixture.splitIdat(&rebuilt.writer, encoded.written()[0..PngFixture.header_end], payload, at);
        const found = try load(allocator, rebuilt.written(), PngFixture.single_rgb_header, values.max_decode_bytes);
        defer stb.release(allocator, found);
        try std.testing.expectEqual(PngFixture.single_rgb_pixel, found[0]);
    }
    rebuilt.clearRetainingCapacity();
    try PngFixture.splitIdat(&rebuilt.writer, encoded.written()[0..PngFixture.header_end], payload[0..3], 1);
    try std.testing.expectError(error.InvalidImage, load(allocator, rebuilt.written(), PngFixture.single_rgb_header, values.max_decode_bytes));
    try std.testing.expectError(error.ImageTooLarge, load(allocator, encoded.written(), PngFixture.single_rgb_header, @sizeOf(values.Pixel)));
}

test "RGB8 preserves legacy checksum tolerance" {
    const allocator = std.testing.allocator;
    var encoded = try PngFixture.singleRgbPng(allocator);
    defer encoded.deinit();
    const idat = PngFixture.header_end;
    const len = PngFixture.firstIdat(encoded.written()[PngFixture.header_end..]).len;
    const changed = try allocator.dupe(u8, encoded.written());
    defer allocator.free(changed);
    // Alter both the zlib checksum payload and the following PNG CRC.
    changed[idat + 8 + len - 1] ^= 1;
    changed[idat + 8 + len] ^= 1;
    const found = try load(allocator, changed, PngFixture.single_rgb_header, values.max_decode_bytes);
    defer stb.release(allocator, found);
    try std.testing.expectEqual(PngFixture.single_rgb_pixel, found[0]);
}

test "RGB8 transparent colour keys use the legacy decoder" {
    const allocator = std.testing.allocator;
    const raw = [_]u8{ 0, 23, 57, 91 };
    var png: Writer.Allocating = .init(allocator);
    defer png.deinit();
    try PngFixture.writePng(allocator, &png.writer, .{ .width = 1, .height = 1 }, .rgb, &raw);

    var keyed: Writer.Allocating = .init(allocator);
    defer keyed.deinit();
    try keyed.writer.writeAll(png.written()[0..PngFixture.header_end]);
    try zlib.chunk(&keyed.writer, png_format.trns_type, &.{ 0, raw[1], 0, raw[2], 0, raw[3] });
    try keyed.writer.writeAll(png.written()[PngFixture.header_end..]);

    const header = try stb.probe(allocator, keyed.written(), values.max_decode_bytes);
    try std.testing.expectEqual(@as(?[]values.Pixel, null), try loadStreaming(allocator, keyed.written(), header, values.max_decode_bytes));
    const pixels = try load(allocator, keyed.written(), header, values.max_decode_bytes);
    defer stb.release(allocator, pixels);
    try std.testing.expectEqual(values.Pixel{ raw[1], raw[2], raw[3], 0 }, pixels[0]);
}

test "Scanline decoding leaves gray-alpha, packed indices, wide samples and interlacing to stb" {
    const allocator = std.testing.allocator;
    const size: values.Size = .{ .width = 1, .height = 1 };
    const profiles = [_]struct {
        colour: png_format.Colour,
        depth: u8 = png_format.sample_depth,
        interlace: u8 = 0,
        raw: []const u8,
        palette: ?[]const u8 = null,
        expected: values.Pixel,
    }{
        .{ .colour = .gray_alpha, .raw = &.{ 0, 37, 99 }, .expected = .{ 37, 37, 37, 99 } },
        .{ .colour = .indexed, .depth = 1, .raw = &.{ 0, 0 }, .palette = &.{ 11, 22, 33 }, .expected = .{ 11, 22, 33, 255 } },
        .{ .colour = .rgb, .depth = 16, .raw = &.{ 0, 11, 0, 22, 0, 33, 0 }, .expected = .{ 11, 22, 33, 255 } },
        .{ .colour = .rgba, .interlace = 1, .raw = &.{ 0, 11, 22, 33, 44 }, .expected = .{ 11, 22, 33, 44 } },
    };
    for (profiles) |profile| {
        var encoded: Writer.Allocating = .init(allocator);
        defer encoded.deinit();
        try PngFixture.writePng(allocator, &encoded.writer, size, profile.colour, profile.raw);

        var header = encoded.written()[0..PngFixture.header_end].*;
        header[png_format.profile_offset] = profile.depth;
        header[png_format.header_bytes - 1] = profile.interlace;
        png_format.rewriteHeaderCrc(&header);
        try std.testing.expectEqual(@as(?Profile, null), scanlines.streamingProfile(&header));

        var patched: Writer.Allocating = .init(allocator);
        defer patched.deinit();
        try patched.writer.writeAll(&header);
        if (profile.palette) |palette| try zlib.chunk(&patched.writer, png_format.plte_type, palette);
        try patched.writer.writeAll(encoded.written()[PngFixture.header_end..]);

        const metadata = try stb.probe(allocator, patched.written(), values.max_decode_bytes);
        try std.testing.expectEqual(@as(?[]values.Pixel, null), try loadStreaming(allocator, patched.written(), metadata, values.max_decode_bytes));
        const pixels = try load(allocator, patched.written(), metadata, values.max_decode_bytes);
        defer stb.release(allocator, pixels);
        try std.testing.expectEqual(profile.expected, pixels[0]);
    }
}

test "Gray8 and indexed PNG reconstruct every filter across split IDATs" {
    const allocator = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(42);
    const random = prng.random();
    // Place every filter both at the top edge and below a previous row.
    const height = 7;
    const max_width = 259;
    var samples: [height * max_width]u8 = undefined;
    var filtered: [height * (1 + max_width)]u8 = undefined;
    var colours: [256 * 3]u8 = undefined;
    var alphas: [256]u8 = undefined;
    var rows: Writer.Allocating = .init(allocator);
    defer rows.deinit();
    var png: Writer.Allocating = .init(allocator);
    defer png.deinit();
    var split: Writer.Allocating = .init(allocator);
    defer split.deinit();
    for ([_]Profile{ .gray, .indexed }) |profile| {
        for ([_]usize{ 1, 17, 67, max_width }, [_]usize{ 19, 1, 255, 256 }) |width, palette_len| {
            const size: values.Size = .{ .width = width, .height = height };
            const used = samples[0 .. width * height];
            random.bytes(&colours);
            random.bytes(&alphas);
            if (profile == .indexed) {
                for (used) |*sample| sample.* = @intCast(random.uintLessThan(u16, @intCast(palette_len)));
            } else {
                random.bytes(used);
            }
            for (0..@backingInt(png_format.Filter.paeth) + 1) |first| {
                var filters: [height]u8 = undefined;
                for (&filters, 0..) |*filter, y| filter.* = @intCast((first + y) % (@backingInt(png_format.Filter.paeth) + 1));
                PngFixture.filterRows(1, width, &filters, used, &filtered);
                rows.clearRetainingCapacity();
                try PngFixture.writeData(allocator, &rows.writer, filtered[0 .. height * (width + 1)]);
                const payload = PngFixture.firstIdat(rows.written());

                png.clearRetainingCapacity();
                try PngFixture.writeHeader(&png.writer, size, @fromBackingInt(@backingInt(profile)));
                if (profile == .indexed) {
                    try zlib.chunk(&png.writer, png_format.plte_type, colours[0 .. palette_len * 3]);
                    if (first % 2 == 0) try zlib.chunk(&png.writer, png_format.trns_type, alphas[0..palette_len]);
                    if (first == 1) try zlib.chunk(&png.writer, png_format.trns_type, alphas[0 .. palette_len / 2]);
                }
                split.clearRetainingCapacity();
                try PngFixture.splitIdat(&split.writer, png.written(), payload, payload.len / 2);
                const bytes = split.written();
                const header = try stb.probe(allocator, bytes, values.max_decode_bytes);
                const streamed = (try loadStreaming(allocator, bytes, header, values.max_decode_bytes)) orelse return error.TestUnexpectedResult;
                defer stb.release(allocator, streamed);
                const legacy = try stb.loadLegacy(allocator, bytes, header, values.max_decode_bytes);
                defer stb.release(allocator, legacy);
                try std.testing.expectEqualSlices(values.Pixel, legacy, streamed);
            }
        }
    }
}

test "Gray8 colour keys and invalid palette indices preserve fallback behaviour" {
    const allocator = std.testing.allocator;
    const size: values.Size = .{ .width = 1, .height = 1 };
    const cases = [_]struct { profile: Profile, palette: []const u8, alpha: []const u8, sample: u8 }{
        .{ .profile = .gray, .palette = "", .alpha = &.{ 0, 37 }, .sample = 37 },
        .{ .profile = .indexed, .palette = &.{ 11, 22, 33 }, .alpha = &.{127}, .sample = 255 },
        .{ .profile = .indexed, .palette = &.{ 11, 22, 33 }, .alpha = &.{ 127, 255 }, .sample = 0 },
    };
    for (cases, 0..) |case, i| {
        var png: Writer.Allocating = .init(allocator);
        defer png.deinit();
        try PngFixture.writeHeader(&png.writer, size, @fromBackingInt(@backingInt(case.profile)));
        if (case.palette.len != 0) try zlib.chunk(&png.writer, png_format.plte_type, case.palette);
        try zlib.chunk(&png.writer, png_format.trns_type, case.alpha);
        try PngFixture.writeData(allocator, &png.writer, &.{ 0, case.sample });
        const header = try stb.probe(allocator, png.written(), values.max_decode_bytes);
        try std.testing.expectEqual(@as(?[]values.Pixel, null), try loadStreaming(allocator, png.written(), header, values.max_decode_bytes));
        if (i == cases.len - 1) {
            try std.testing.expectError(error.InvalidImage, stb.loadLegacy(allocator, png.written(), header, values.max_decode_bytes));
            try std.testing.expectError(error.InvalidImage, load(allocator, png.written(), header, values.max_decode_bytes));
            continue;
        }
        const legacy = try stb.loadLegacy(allocator, png.written(), header, values.max_decode_bytes);
        defer stb.release(allocator, legacy);
        const decoded = try load(allocator, png.written(), header, values.max_decode_bytes);
        defer stb.release(allocator, decoded);
        try std.testing.expectEqual(legacy.len, decoded.len);
        // stb leaves out-of-range palette entries undefined.
        if (case.profile == .gray) try std.testing.expectEqualSlices(values.Pixel, legacy, decoded);
    }
}

test "the streaming probe agrees with the PNG header layout" {
    var header: [png_format.header_bytes]u8 = @splat(0);
    @memcpy(header[0..png_format.header_prefix.len], png_format.header_prefix);
    const offset = png_format.dimensions_offset;
    png_format.writeDimensions(header[offset..][0..png_format.dimensions_bytes], 253, 58);
    const profile = header[png_format.profile_offset..];
    const depth, const colour, const interlace = .{ 0, 1, 4 };
    profile[depth] = png_format.sample_depth;
    profile[colour] = @backingInt(png_format.Colour.rgba);
    try std.testing.expectEqual(@as(?Profile, .rgba), scanlines.streamingProfile(&header));
    try std.testing.expectEqual(@as(?Profile, null), scanlines.streamingProfile(header[0 .. header.len - 1]));
    profile[colour] = @backingInt(png_format.Colour.rgb);
    try std.testing.expectEqual(@as(?Profile, .rgb), scanlines.streamingProfile(&header));
    profile[depth] = 16;
    try std.testing.expectEqual(@as(?Profile, null), scanlines.streamingProfile(&header));
    profile[depth] = png_format.sample_depth;
    profile[interlace] = 1;
    try std.testing.expectEqual(@as(?Profile, null), scanlines.streamingProfile(&header));
    profile[interlace] = 0;
    for ([_]Profile{ .indexed, .gray }) |kind| {
        profile[colour] = @backingInt(kind);
        try std.testing.expectEqual(@as(?Profile, kind), scanlines.streamingProfile(&header));
    }
    profile[colour] = @backingInt(png_format.Colour.rgba);
    for (0..png_format.header_prefix.len) |i| {
        header[i] ^= 1;
        try std.testing.expectEqual(@as(?Profile, null), scanlines.streamingProfile(&header));
        header[i] ^= 1;
    }
}

test "fuzz streaming PNG reconstruction" {
    const fuzz_profiles = std.enums.values(Profile);
    const fuzz_filter_count = @backingInt(png_format.Filter.paeth) + 2; // Five filters and the first invalid byte.
    const fuzz_split_seed = fuzz_profiles.len * fuzz_filter_count;
    const capture = struct {
        fn fuzzStreamingRows(_: void, smith: *std.testing.Smith) !void {
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
            try PngFixture.writeHeader(&output.writer, size, @fromBackingInt(@backingInt(profile)));
            switch (profile) {
                .indexed => {
                    // Every reconstructed byte must name a defined palette entry.
                    var colours: [256 * 3]u8 = undefined;
                    var alphas: [256]u8 = undefined;
                    for (&colours) |*value| value.* = smith.value(u8);
                    const alpha_count = smith.valueRangeAtMost(u16, 1, alphas.len);
                    for (alphas[0..alpha_count]) |*value| value.* = smith.value(u8);
                    try zlib.chunk(&output.writer, png_format.plte_type, &colours);
                    try zlib.chunk(&output.writer, png_format.trns_type, alphas[0..alpha_count]);
                },
                .gray => if (smith.value(bool)) try zlib.chunk(&output.writer, png_format.trns_type, &.{ 0, smith.value(u8) }),
                .rgb, .rgba => {},
            }
            const idat_offset = output.written().len;
            try PngFixture.writeData(allocator, &output.writer, valid[0..length]);
            var split: Writer.Allocating = .init(allocator);
            defer split.deinit();
            const bytes = if (seed >= fuzz_split_seed) split_bytes: {
                const payload = PngFixture.firstIdat(output.written()[idat_offset..]);
                const offset = smith.valueRangeAtMost(u16, 0, @intCast(payload.len));
                try PngFixture.splitIdat(&split.writer, output.written()[0..idat_offset], payload, offset);
                break :split_bytes split.written();
            } else output.written();
            const header: stb.Header = .{ .size = size, .sample_bytes = 1 };
            const found = try loadStreaming(allocator, bytes, header, values.max_decode_bytes) orelse return;
            defer stb.release(allocator, found);
            const legacy = try stb.loadLegacy(allocator, bytes, header, values.max_decode_bytes);
            defer stb.release(allocator, legacy);
            try std.testing.expectEqualSlices(values.Pixel, legacy, found);
        }
    };
    comptime var corpus: []const []const u8 = &.{};
    inline for (0..2 * fuzz_split_seed) |seed| corpus = corpus ++ .{&[_]u8{seed}};
    try std.testing.fuzz({}, capture.fuzzStreamingRows, .{ .corpus = corpus });
}

test {
    std.testing.refAllDecls(@This());
}
