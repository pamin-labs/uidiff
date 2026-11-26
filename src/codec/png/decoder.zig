//! Decodes PNG scanlines under a budget with the stb fallback.

const std = @import("std");
const deflate = @import("deflate.zig");
const values = @import("../../value.zig");
const png_format = @import("../png_format.zig");
const stb = @import("../stb.zig");
const scanlines = @import("scanlines.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Profile = scanlines.Profile;

/// Malformed PNG bytes, a decode past the memory budget, or allocation failure.
pub const DecodeError = stb.DecodeError;

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
    const fixture = @import("../../testing/png.zig");
    for ([_][]const u8{ &.{ 3, 3, 0 }, &.{ 1, 2, 4 }, &.{ 4, 1, 2 }, &.{ 3, 0, 5 } }) |filters| {
        try fixture.checkTestFilters(3, png_format.rgb_color, filters);
        try fixture.checkTestFilters(4, png_format.rgba_color, filters);
    }
}

test "RGB8 accepts every legal IDAT split and refuses a truncated DEFLATE body" {
    const fixture = @import("../../testing/png.zig");
    const allocator = std.testing.allocator;
    var encoded = try fixture.singleRgbPng(allocator);
    defer encoded.deinit();
    const payload = fixture.firstTestIdat(encoded.written()[fixture.header_end..]);

    var rebuilt: Writer.Allocating = .init(allocator);
    defer rebuilt.deinit();
    for (0..payload.len + 1) |at| {
        rebuilt.clearRetainingCapacity();
        try fixture.splitTestIdat(&rebuilt.writer, encoded.written()[0..fixture.header_end], payload, at);
        const found = try load(allocator, rebuilt.written(), fixture.single_rgb_header, values.max_decode_bytes);
        defer stb.release(allocator, found);
        try std.testing.expectEqual(fixture.single_rgb_pixel, found[0]);
    }
    rebuilt.clearRetainingCapacity();
    try fixture.splitTestIdat(&rebuilt.writer, encoded.written()[0..fixture.header_end], payload[0..3], 1);
    try std.testing.expectError(error.InvalidImage, load(allocator, rebuilt.written(), fixture.single_rgb_header, values.max_decode_bytes));
    try std.testing.expectError(error.ImageTooLarge, load(allocator, encoded.written(), fixture.single_rgb_header, @sizeOf(values.Pixel)));
}

test "RGB8 preserves legacy checksum tolerance" {
    const fixture = @import("../../testing/png.zig");
    const allocator = std.testing.allocator;
    var encoded = try fixture.singleRgbPng(allocator);
    defer encoded.deinit();
    const idat = fixture.header_end;
    const len = fixture.firstTestIdat(encoded.written()[fixture.header_end..]).len;
    const changed = try allocator.dupe(u8, encoded.written());
    defer allocator.free(changed);
    // Alter both the zlib checksum payload and the following PNG CRC.
    changed[idat + 8 + len - 1] ^= 1;
    changed[idat + 8 + len] ^= 1;
    const found = try load(allocator, changed, fixture.single_rgb_header, values.max_decode_bytes);
    defer stb.release(allocator, found);
    try std.testing.expectEqual(fixture.single_rgb_pixel, found[0]);
}

test "RGB8 transparent colour keys use the legacy decoder" {
    const fixture = @import("../../testing/png.zig");
    const allocator = std.testing.allocator;
    const raw = [_]u8{ 0, 23, 57, 91 };
    var png: Writer.Allocating = .init(allocator);
    defer png.deinit();
    try fixture.writeTestPng(allocator, &png.writer, .{ .width = 1, .height = 1 }, png_format.rgb_color, &raw);

    var keyed: Writer.Allocating = .init(allocator);
    defer keyed.deinit();
    try keyed.writer.writeAll(png.written()[0..fixture.header_end]);
    try deflate.chunk(&keyed.writer, "tRNS", &.{ 0, raw[1], 0, raw[2], 0, raw[3] });
    try keyed.writer.writeAll(png.written()[fixture.header_end..]);

    const header = try stb.probe(allocator, keyed.written(), values.max_decode_bytes);
    try std.testing.expectEqual(@as(?[]values.Pixel, null), try loadStreaming(allocator, keyed.written(), header, values.max_decode_bytes));
    const pixels = try load(allocator, keyed.written(), header, values.max_decode_bytes);
    defer stb.release(allocator, pixels);
    try std.testing.expectEqual(values.Pixel{ raw[1], raw[2], raw[3], 0 }, pixels[0]);
}

test "Scanline decoding leaves gray-alpha, packed indices, wide samples and interlacing to stb" {
    const fixture = @import("../../testing/png.zig");
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
        .{ .color = png_format.gray_alpha_color, .raw = &.{ 0, 37, 99 }, .expected = .{ 37, 37, 37, 99 } },
        .{ .color = @backingInt(Profile.indexed), .depth = 1, .raw = &.{ 0, 0 }, .palette = &.{ 11, 22, 33 }, .expected = .{ 11, 22, 33, 255 } },
        .{ .color = png_format.rgb_color, .depth = 16, .raw = &.{ 0, 11, 0, 22, 0, 33, 0 }, .expected = .{ 11, 22, 33, 255 } },
        .{ .color = png_format.rgba_color, .interlace = 1, .raw = &.{ 0, 11, 22, 33, 44 }, .expected = .{ 11, 22, 33, 44 } },
    };
    for (profiles) |profile| {
        var encoded: Writer.Allocating = .init(allocator);
        defer encoded.deinit();
        try fixture.writeTestPng(allocator, &encoded.writer, size, profile.color, profile.raw);

        const checksum_start = png_format.signature.len + @sizeOf(u32);
        var header = encoded.written()[0..fixture.header_end].*;
        header[png_format.profile_offset] = profile.depth;
        header[png_format.header_bytes - 1] = profile.interlace;
        std.mem.writeInt(u32, header[png_format.header_bytes..][0..4], std.hash.Crc32.hash(header[checksum_start..png_format.header_bytes]), .big);
        try std.testing.expectEqual(@as(?Profile, null), scanlines.streamingProfile(&header));

        var patched: Writer.Allocating = .init(allocator);
        defer patched.deinit();
        try patched.writer.writeAll(&header);
        if (profile.palette) |palette| try deflate.chunk(&patched.writer, "PLTE", palette);
        try patched.writer.writeAll(encoded.written()[fixture.header_end..]);

        const metadata = try stb.probe(allocator, patched.written(), values.max_decode_bytes);
        try std.testing.expectEqual(@as(?[]values.Pixel, null), try loadStreaming(allocator, patched.written(), metadata, values.max_decode_bytes));
        const pixels = try load(allocator, patched.written(), metadata, values.max_decode_bytes);
        defer stb.release(allocator, pixels);
        try std.testing.expectEqual(profile.expected, pixels[0]);
    }
}

test "Gray8 and indexed PNG reconstruct every filter across split IDATs" {
    const fixture = @import("../../testing/png.zig");
    const allocator = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(42);
    const random = prng.random();
    // Place every filter both at the top edge and below a previous row.
    const height = 7;
    const max_width = 259;
    var samples: [height * max_width]u8 = undefined;
    var filtered: [height * (1 + max_width)]u8 = undefined;
    var colors: [256 * 3]u8 = undefined;
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
            random.bytes(&colors);
            random.bytes(&alphas);
            if (profile == .indexed) {
                for (used) |*sample| sample.* = @intCast(random.uintLessThan(u16, @intCast(palette_len)));
            } else {
                random.bytes(used);
            }
            for (0..png_format.paeth_filter + 1) |first| {
                var filters: [height]u8 = undefined;
                for (&filters, 0..) |*filter, y| filter.* = @intCast((first + y) % (png_format.paeth_filter + 1));
                fixture.filterTestRows(1, width, &filters, used, &filtered);
                rows.clearRetainingCapacity();
                try fixture.writeTestData(allocator, &rows.writer, filtered[0 .. height * (width + 1)]);
                const payload = fixture.firstTestIdat(rows.written());

                png.clearRetainingCapacity();
                try fixture.writeTestHeader(&png.writer, size, @backingInt(profile));
                if (profile == .indexed) {
                    try deflate.chunk(&png.writer, "PLTE", colors[0 .. palette_len * 3]);
                    if (first % 2 == 0) try deflate.chunk(&png.writer, "tRNS", alphas[0..palette_len]);
                    if (first == 1) try deflate.chunk(&png.writer, "tRNS", alphas[0 .. palette_len / 2]);
                }
                split.clearRetainingCapacity();
                try fixture.splitTestIdat(&split.writer, png.written(), payload, payload.len / 2);
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
    const fixture = @import("../../testing/png.zig");
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
        try fixture.writeTestHeader(&png.writer, size, @backingInt(case.profile));
        if (case.palette.len != 0) try deflate.chunk(&png.writer, "PLTE", case.palette);
        try deflate.chunk(&png.writer, "tRNS", case.alpha);
        try fixture.writeTestData(allocator, &png.writer, &.{ 0, case.sample });
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
    std.mem.writeInt(u32, header[offset..][0..4], 253, .big);
    std.mem.writeInt(u32, header[offset + 4 ..][0..4], 58, .big);
    const profile = header[offset + 2 * @sizeOf(u32) ..];
    const depth, const colour, const interlace = .{ 0, 1, 4 };
    profile[depth] = 8;
    profile[colour] = png_format.rgba_color;
    try std.testing.expectEqual(@as(?Profile, .rgba), scanlines.streamingProfile(&header));
    try std.testing.expectEqual(@as(?Profile, null), scanlines.streamingProfile(header[0 .. header.len - 1]));
    profile[colour] = png_format.rgb_color;
    try std.testing.expectEqual(@as(?Profile, .rgb), scanlines.streamingProfile(&header));
    profile[depth] = 16;
    try std.testing.expectEqual(@as(?Profile, null), scanlines.streamingProfile(&header));
    profile[depth] = 8;
    profile[interlace] = 1;
    try std.testing.expectEqual(@as(?Profile, null), scanlines.streamingProfile(&header));
    profile[interlace] = 0;
    for ([_]Profile{ .indexed, .gray }) |kind| {
        profile[colour] = @backingInt(kind);
        try std.testing.expectEqual(@as(?Profile, kind), scanlines.streamingProfile(&header));
    }
    profile[colour] = png_format.rgba_color;
    for (0..png_format.header_prefix.len) |i| {
        header[i] ^= 1;
        try std.testing.expectEqual(@as(?Profile, null), scanlines.streamingProfile(&header));
        header[i] ^= 1;
    }
}

test "fuzz streaming PNG reconstruction" {
    const fixture = @import("../../testing/png.zig");
    comptime var corpus: []const []const u8 = &.{};
    inline for (0..2 * fixture.fuzz_split_seed) |seed| corpus = corpus ++ .{&[_]u8{seed}};
    try std.testing.fuzz({}, fixture.fuzzStreamingRows, .{ .corpus = corpus });
}

test {
    std.testing.refAllDecls(@This());
}
