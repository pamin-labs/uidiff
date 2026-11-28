//! Decodes PNG scanlines under a budget with the stb fallback.

const std = @import("std");
const zlib = @import("zlib.zig");
const value = @import("../../value.zig");
const png_format = @import("png_format");
const memory = @import("codec_memory");
const stb = @import("stb.zig");
const scanlines = @import("scanlines.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Profile = scanlines.Profile;

/// Malformed PNG bytes, a decode past the memory budget, or allocation failure.
pub const DecodeError = stb.DecodeError;

/// Decodes the probed dimensions through the scanline or legacy decoder.
pub fn decode(allocator: Allocator, bytes: []const u8, header: stb.Header, cap: usize) stb.DecodeError![]value.Pixel {
    return load(allocator, bytes, header, cap);
}

/// Runs bounded scanline decoding. Null requests the legacy fallback.
pub fn loadStreaming(allocator: Allocator, bytes: []const u8, header: stb.Header, cap: usize) DecodeError!?[]value.Pixel {
    return stb.withDecodeBudget(scanlines.decode, allocator, bytes, header, cap);
}

fn load(allocator: Allocator, bytes: []const u8, header: stb.Header, cap: usize) DecodeError![]value.Pixel {
    return stb.withDecodeBudget(loadPixels, allocator, bytes, header, cap);
}

fn loadPixels(bytes: []const u8, size: value.Size) DecodeError![]value.Pixel {
    if (try scanlines.decode(bytes, size)) |pixels| return pixels;
    return stb.loadStb(bytes, size);
}

test "PNG filters preserve RGB8 and RGBA8 across streaming and fallback" {
    const streams = @import("streams.zig");
    const capture = struct {
        fn checkFilters(comptime channels: usize, colour: png_format.Colour, filters: []const u8) !void {
            const allocator = std.testing.allocator;
            const width = 7;
            const row_bytes = width * channels;
            const size: value.Size = .{ .width = width, .height = filters.len };
            var pixels: [3 * width]value.Pixel = undefined;
            for (pixels[0 .. width * filters.len], 0..) |*pixel, i| {
                pixel.* = .{ @intCast(7 + 11 * i), @intCast(101 - 3 * i), @intCast(2 + i * 7), if (channels == 3) 255 else @intCast(254 - 5 * i) };
            }
            var raw: [3 * row_bytes]u8 = undefined;
            for (pixels[0 .. width * filters.len], 0..) |pixel, i| @memcpy(raw[i * channels ..][0..channels], pixel[0..channels]);
            var filtered: [3 * (1 + row_bytes)]u8 = undefined;
            streams.filterRows(channels, width, filters, &raw, &filtered);

            var output: Writer.Allocating = .init(allocator);
            defer output.deinit();
            try streams.writePng(allocator, &output.writer, size, colour, filtered[0 .. filters.len * (1 + row_bytes)]);
            const header = try stb.probe(allocator, output.written(), value.max_decode_bytes);
            for (filters) |filter_byte| if (filter_byte > @backingInt(png_format.Filter.paeth)) {
                try std.testing.expectEqual(@as(?[]value.Pixel, null), try loadStreaming(allocator, output.written(), header, value.max_decode_bytes));
                try std.testing.expectError(error.InvalidImage, load(allocator, output.written(), header, value.max_decode_bytes));
                return;
            };
            const found = try load(allocator, output.written(), header, value.max_decode_bytes);
            defer memory.freeBlock(@constCast(found.ptr));
            const legacy = try stb.loadLegacy(allocator, output.written(), header, value.max_decode_bytes);
            defer memory.freeBlock(@constCast(legacy.ptr));
            try std.testing.expectEqualSlices(value.Pixel, pixels[0 .. width * filters.len], legacy);
            try std.testing.expectEqualSlices(value.Pixel, legacy, found);
        }
    };
    for ([_][]const u8{ &.{ 3, 3, 0 }, &.{ 1, 2, 4 }, &.{ 4, 1, 2 }, &.{ 3, 0, 5 } }) |filters| {
        try capture.checkFilters(3, .rgb, filters);
        try capture.checkFilters(4, .rgba, filters);
    }
}

test "RGB8 accepts every legal IDAT split and refuses a truncated DEFLATE body" {
    const streams = @import("streams.zig");
    const allocator = std.testing.allocator;
    var encoded = try streams.singleRgbPng(allocator);
    defer encoded.deinit();
    const payload = streams.firstIdat(encoded.written()[streams.header_end..]);

    var rebuilt: Writer.Allocating = .init(allocator);
    defer rebuilt.deinit();
    for (0..payload.len + 1) |at| {
        rebuilt.clearRetainingCapacity();
        try streams.splitIdat(&rebuilt.writer, encoded.written()[0..streams.header_end], payload, at);
        const found = try load(allocator, rebuilt.written(), streams.single_rgb_header, value.max_decode_bytes);
        defer memory.freeBlock(@constCast(found.ptr));
        try std.testing.expectEqual(streams.single_rgb_pixel, found[0]);
    }
    rebuilt.clearRetainingCapacity();
    try streams.splitIdat(&rebuilt.writer, encoded.written()[0..streams.header_end], payload[0..3], 1);
    try std.testing.expectError(error.InvalidImage, load(allocator, rebuilt.written(), streams.single_rgb_header, value.max_decode_bytes));
    try std.testing.expectError(error.ImageTooLarge, load(allocator, encoded.written(), streams.single_rgb_header, @sizeOf(value.Pixel)));
}

test "RGB8 preserves legacy checksum tolerance" {
    const streams = @import("streams.zig");
    const allocator = std.testing.allocator;
    var encoded = try streams.singleRgbPng(allocator);
    defer encoded.deinit();
    const idat = streams.header_end;
    const len = streams.firstIdat(encoded.written()[streams.header_end..]).len;
    const changed = try allocator.dupe(u8, encoded.written());
    defer allocator.free(changed);
    // Alter both the zlib checksum payload and the following PNG CRC.
    changed[idat + 8 + len - 1] ^= 1;
    changed[idat + 8 + len] ^= 1;
    const found = try load(allocator, changed, streams.single_rgb_header, value.max_decode_bytes);
    defer memory.freeBlock(@constCast(found.ptr));
    try std.testing.expectEqual(streams.single_rgb_pixel, found[0]);
}

test "RGB8 transparent colour keys use the legacy decoder" {
    const streams = @import("streams.zig");
    const allocator = std.testing.allocator;
    const raw = [_]u8{ 0, 23, 57, 91 };
    var png: Writer.Allocating = .init(allocator);
    defer png.deinit();
    try streams.writePng(allocator, &png.writer, .{ .width = 1, .height = 1 }, .rgb, &raw);

    var keyed: Writer.Allocating = .init(allocator);
    defer keyed.deinit();
    try keyed.writer.writeAll(png.written()[0..streams.header_end]);
    try zlib.chunk(&keyed.writer, png_format.trns_type, &.{ 0, raw[1], 0, raw[2], 0, raw[3] });
    try keyed.writer.writeAll(png.written()[streams.header_end..]);

    const header = try stb.probe(allocator, keyed.written(), value.max_decode_bytes);
    try std.testing.expectEqual(@as(?[]value.Pixel, null), try loadStreaming(allocator, keyed.written(), header, value.max_decode_bytes));
    const pixels = try load(allocator, keyed.written(), header, value.max_decode_bytes);
    defer memory.freeBlock(@constCast(pixels.ptr));
    try std.testing.expectEqual(value.Pixel{ raw[1], raw[2], raw[3], 0 }, pixels[0]);
}

test "Scanline decoding leaves gray-alpha, packed indices, wide samples and interlacing to stb" {
    const streams = @import("streams.zig");
    const allocator = std.testing.allocator;
    const size: value.Size = .{ .width = 1, .height = 1 };
    const profiles = [_]struct {
        colour: png_format.Colour,
        depth: u8 = png_format.sample_depth,
        interlace: u8 = 0,
        raw: []const u8,
        palette: ?[]const u8 = null,
        expected: value.Pixel,
    }{
        .{ .colour = .gray_alpha, .raw = &.{ 0, 37, 99 }, .expected = .{ 37, 37, 37, 99 } },
        .{ .colour = .indexed, .depth = 1, .raw = &.{ 0, 0 }, .palette = &.{ 11, 22, 33 }, .expected = .{ 11, 22, 33, 255 } },
        .{ .colour = .rgb, .depth = 16, .raw = &.{ 0, 11, 0, 22, 0, 33, 0 }, .expected = .{ 11, 22, 33, 255 } },
        .{ .colour = .rgba, .interlace = 1, .raw = &.{ 0, 11, 22, 33, 44 }, .expected = .{ 11, 22, 33, 44 } },
    };
    for (profiles) |profile| {
        var encoded: Writer.Allocating = .init(allocator);
        defer encoded.deinit();
        try streams.writePng(allocator, &encoded.writer, size, profile.colour, profile.raw);

        var header = encoded.written()[0..streams.header_end].*;
        header[png_format.profile_offset] = profile.depth;
        header[png_format.header_bytes - 1] = profile.interlace;
        png_format.rewriteHeaderCrc(&header);
        try std.testing.expectEqual(@as(?Profile, null), scanlines.streamingProfile(&header));

        var patched: Writer.Allocating = .init(allocator);
        defer patched.deinit();
        try patched.writer.writeAll(&header);
        if (profile.palette) |palette| try zlib.chunk(&patched.writer, png_format.plte_type, palette);
        try patched.writer.writeAll(encoded.written()[streams.header_end..]);

        const metadata = try stb.probe(allocator, patched.written(), value.max_decode_bytes);
        try std.testing.expectEqual(@as(?[]value.Pixel, null), try loadStreaming(allocator, patched.written(), metadata, value.max_decode_bytes));
        const pixels = try load(allocator, patched.written(), metadata, value.max_decode_bytes);
        defer memory.freeBlock(@constCast(pixels.ptr));
        try std.testing.expectEqual(profile.expected, pixels[0]);
    }
}

test "Gray8 and indexed PNG reconstruct every filter across split IDATs" {
    const streams = @import("streams.zig");
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
            const size: value.Size = .{ .width = width, .height = height };
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
                streams.filterRows(1, width, &filters, used, &filtered);
                rows.clearRetainingCapacity();
                try streams.writeData(allocator, &rows.writer, filtered[0 .. height * (width + 1)]);
                const payload = streams.firstIdat(rows.written());

                png.clearRetainingCapacity();
                try streams.writeHeader(&png.writer, size, @fromBackingInt(@backingInt(profile)));
                if (profile == .indexed) {
                    try zlib.chunk(&png.writer, png_format.plte_type, colours[0 .. palette_len * 3]);
                    if (first % 2 == 0) try zlib.chunk(&png.writer, png_format.trns_type, alphas[0..palette_len]);
                    if (first == 1) try zlib.chunk(&png.writer, png_format.trns_type, alphas[0 .. palette_len / 2]);
                }
                split.clearRetainingCapacity();
                try streams.splitIdat(&split.writer, png.written(), payload, payload.len / 2);
                const bytes = split.written();
                const header = try stb.probe(allocator, bytes, value.max_decode_bytes);
                const streamed = (try loadStreaming(allocator, bytes, header, value.max_decode_bytes)) orelse return error.TestUnexpectedResult;
                defer memory.freeBlock(@constCast(streamed.ptr));
                const legacy = try stb.loadLegacy(allocator, bytes, header, value.max_decode_bytes);
                defer memory.freeBlock(@constCast(legacy.ptr));
                try std.testing.expectEqualSlices(value.Pixel, legacy, streamed);
            }
        }
    }
}

test "Gray8 colour keys and invalid palette indices preserve fallback behaviour" {
    const streams = @import("streams.zig");
    const allocator = std.testing.allocator;
    const size: value.Size = .{ .width = 1, .height = 1 };
    const cases = [_]struct { profile: Profile, palette: []const u8, alpha: []const u8, sample: u8 }{
        .{ .profile = .gray, .palette = "", .alpha = &.{ 0, 37 }, .sample = 37 },
        .{ .profile = .indexed, .palette = &.{ 11, 22, 33 }, .alpha = &.{127}, .sample = 255 },
        .{ .profile = .indexed, .palette = &.{ 11, 22, 33 }, .alpha = &.{ 127, 255 }, .sample = 0 },
    };
    for (cases, 0..) |case, i| {
        var png: Writer.Allocating = .init(allocator);
        defer png.deinit();
        try streams.writeHeader(&png.writer, size, @fromBackingInt(@backingInt(case.profile)));
        if (case.palette.len != 0) try zlib.chunk(&png.writer, png_format.plte_type, case.palette);
        try zlib.chunk(&png.writer, png_format.trns_type, case.alpha);
        try streams.writeData(allocator, &png.writer, &.{ 0, case.sample });
        const header = try stb.probe(allocator, png.written(), value.max_decode_bytes);
        try std.testing.expectEqual(@as(?[]value.Pixel, null), try loadStreaming(allocator, png.written(), header, value.max_decode_bytes));
        if (i == cases.len - 1) {
            try std.testing.expectError(error.InvalidImage, stb.loadLegacy(allocator, png.written(), header, value.max_decode_bytes));
            try std.testing.expectError(error.InvalidImage, load(allocator, png.written(), header, value.max_decode_bytes));
            continue;
        }
        const legacy = try stb.loadLegacy(allocator, png.written(), header, value.max_decode_bytes);
        defer memory.freeBlock(@constCast(legacy.ptr));
        const decoded = try load(allocator, png.written(), header, value.max_decode_bytes);
        defer memory.freeBlock(@constCast(decoded.ptr));
        try std.testing.expectEqual(legacy.len, decoded.len);
        // stb leaves out-of-range palette entries undefined.
        if (case.profile == .gray) try std.testing.expectEqualSlices(value.Pixel, legacy, decoded);
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
    const streams = @import("streams.zig");
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
            const size: value.Size = .{ .width = width, .height = height };
            const channels = profile.samplesPerPixel();
            var rows: [max_height * (1 + max_width * 4)]u8 = undefined;
            const row_bytes = 1 + size.width * channels;
            const valid = rows[0 .. size.height * row_bytes];
            const length = if (smith.value(bool)) smith.slice(valid) else complete: {
                for (0..size.height) |y| {
                    const row = valid[y * row_bytes ..][0..row_bytes];
                    row[0] = if (y == 0) (seed / profile_count) % fuzz_filter_count else smith.valueRangeAtMost(u8, 0, fuzz_filter_count - 1);
                    for (row[1..]) |*sample| sample.* = smith.value(u8);
                }
                break :complete valid.len;
            };
            var output: Writer.Allocating = .init(allocator);
            defer output.deinit();
            try streams.writeHeader(&output.writer, size, @fromBackingInt(@backingInt(profile)));
            switch (profile) {
                .indexed => {
                    // Every reconstructed byte must name a defined palette entry.
                    var colours: [256 * 3]u8 = undefined;
                    var alphas: [256]u8 = undefined;
                    for (&colours) |*sample| sample.* = smith.value(u8);
                    const alpha_count = smith.valueRangeAtMost(u16, 1, alphas.len);
                    for (alphas[0..alpha_count]) |*sample| sample.* = smith.value(u8);
                    try zlib.chunk(&output.writer, png_format.plte_type, &colours);
                    try zlib.chunk(&output.writer, png_format.trns_type, alphas[0..alpha_count]);
                },
                .gray => if (smith.value(bool)) try zlib.chunk(&output.writer, png_format.trns_type, &.{ 0, smith.value(u8) }),
                .rgb, .rgba => {},
            }
            const idat_offset = output.written().len;
            try streams.writeData(allocator, &output.writer, valid[0..length]);
            var split: Writer.Allocating = .init(allocator);
            defer split.deinit();
            const bytes = if (seed >= fuzz_split_seed) split_bytes: {
                const payload = streams.firstIdat(output.written()[idat_offset..]);
                const offset = smith.valueRangeAtMost(u16, 0, @intCast(payload.len));
                try streams.splitIdat(&split.writer, output.written()[0..idat_offset], payload, offset);
                break :split_bytes split.written();
            } else output.written();
            const header: stb.Header = .{ .size = size, .sample_bytes = 1 };
            const found = try loadStreaming(allocator, bytes, header, value.max_decode_bytes) orelse return;
            defer memory.freeBlock(@constCast(found.ptr));
            const legacy = try stb.loadLegacy(allocator, bytes, header, value.max_decode_bytes);
            defer memory.freeBlock(@constCast(legacy.ptr));
            try std.testing.expectEqualSlices(value.Pixel, legacy, found);
        }
    };
    comptime var corpus: []const []const u8 = &.{};
    inline for (0..2 * fuzz_split_seed) |seed| corpus = corpus ++ .{&[_]u8{seed}};
    try std.testing.fuzz({}, capture.fuzzStreamingRows, .{ .corpus = corpus });
}

test {
    std.testing.refAllDecls(@This());
}
