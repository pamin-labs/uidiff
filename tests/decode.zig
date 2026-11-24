//! Decodes the committed fixtures through the public API: every format, every
//! allocation failure, and headers past the image bounds.
const std = @import("std");
const uidiff = @import("uidiff");
const fixtures = @import("fixtures");
const testing = std.testing;

const blank = fixtures.find(.identical);
/// The blank fixture's files are small; this bounds the read.
const max_sample_bytes = 4096;

fn sample(comptime format: fixtures.Format) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, blank.path(.before, format), testing.allocator, .limited(max_sample_bytes));
}

fn decodeSamples(allocator: std.mem.Allocator) !void {
    inline for (comptime std.meta.tags(fixtures.Format)) |format| {
        const bytes = try sample(format);
        defer testing.allocator.free(bytes);
        var decoded = try uidiff.decode(allocator, bytes);
        defer decoded.deinit();
        try testing.expectEqual(uidiff.Size{ .width = blank.width * fixtures.scale, .height = blank.height * fixtures.scale }, decoded.image.size());
        for (decoded.image.pixels) |pixel| try testing.expectEqual(uidiff.Pixel{ 255, 255, 255, 255 }, pixel);
    }
}

test "PNG, JPEG and WebP decode to opaque RGBA8 through the given allocator" {
    try decodeSamples(testing.allocator);
    try testing.checkAllAllocationFailures(testing.allocator, decodeSamples, .{});
}

test "PNG header rejects oversized dimensions before pixel data is needed" {
    const bytes = try sample(.png);
    defer testing.allocator.free(bytes);
    var header: [41]u8 = bytes[0..41].*;
    // The IDAT marker allows stb to finish the probe without seeing compressed pixels.
    const side = @min(uidiff.max_extent, std.math.sqrt(uidiff.max_pixels));
    for ([_][2]u32{ .{ side, uidiff.max_pixels / side + 1 }, .{ uidiff.max_extent + 1, 1 }, .{ 1, uidiff.max_extent + 1 } }) |size| {
        std.mem.writeInt(u32, header[16..20], size[0], .big);
        std.mem.writeInt(u32, header[20..24], size[1], .big);
        std.mem.writeInt(u32, header[29..33], std.hash.Crc32.hash(header[12..29]), .big);
        try testing.expectError(error.ImageTooLarge, uidiff.decode(testing.allocator, &header));
    }
}

test "a JPEG frame with representable dimensions over the pixel cap is refused" {
    // SOI and a baseline SOF with representable 16-bit dimensions.
    var header = "\xff\xd8\xff\xc0\x00\x0b\x08\x00\x00\x00\x00\x01\x01\x11\x00".*;
    const height = std.math.maxInt(u16);
    std.mem.writeInt(u16, header[7..9], height, .big);
    std.mem.writeInt(u16, header[9..11], @intCast(uidiff.max_pixels / height + 1), .big);
    try testing.expectError(error.ImageTooLarge, uidiff.decode(testing.allocator, &header));
}

test "a 16-bit header past the decode budget is refused before decoding" {
    inline for (fixtures.claims) |claim| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, claim.path(), testing.allocator, .limited(max_sample_bytes));
        defer testing.allocator.free(bytes);
        try testing.expectError(error.ImageTooLarge, uidiff.decode(testing.allocator, bytes));
    }
}

test "WebP header rejects dimensions beyond the RGBA8 cap" {
    const oversized = try sample(.webp);
    defer testing.allocator.free(oversized);
    // VP8L stores width minus one and height minus one in adjacent 14-bit fields.
    const dimension_bits = 14;
    const width: u32 = 1 << dimension_bits;
    const height_minus_one: u32 = uidiff.max_pixels / width;
    std.mem.writeInt(u32, oversized[21..25], (width - 1) | (height_minus_one << dimension_bits), .little);
    try testing.expectError(error.ImageTooLarge, uidiff.decode(testing.allocator, oversized));
}

test "file comparison honors the lower decode cap in every format" {
    const output_bytes = blank.width * blank.height * fixtures.scale * fixtures.scale * @sizeOf(uidiff.Pixel);
    inline for (comptime std.meta.tags(fixtures.Format)) |format| {
        const path = comptime blank.path(.before, format);
        var diagnostics: uidiff.Diagnostics = .{};
        try testing.expectError(error.ImageTooLarge, uidiff.compareFiles(testing.io, testing.allocator, .{ .before = path, .after = path }, .{ .max_decode_bytes = output_bytes }, &diagnostics));
        try testing.expectEqualStrings(path, diagnostics.path.?);
    }
}

test {
    std.testing.refAllDecls(@This());
}
