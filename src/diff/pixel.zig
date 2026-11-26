//! Pixel equality and the SIMD lane count shared by the column and colour scans.
const std = @import("std");
const values = @import("../value.zig");
const Pixel = values.Pixel;

/// Pixels compared per vector step: the target's widest vector of 32-bit
/// words (4 on SSE2 and NEON, 8 with AVX2). Without SIMD registers the
/// compiler splits a 4-wide vector into scalars.
pub const lanes = std.simd.suggestVectorLength(u32) orelse 4;

/// Sixteen packed RGBA pixels are 64 bytes.
pub const block_pixels = 16;

/// Compares all four channels at once.
pub fn same(a: Pixel, b: Pixel) bool {
    return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
}

/// Compares packed RGBA runs without reading past either slice.
pub noinline fn sameRun(a: []const Pixel, b: []const Pixel) bool {
    if (a.len != b.len) return false;
    const end = a.len - a.len % block_pixels;
    var x: usize = 0;
    while (x < end) : (x += block_pixels) if (!sameBlock(a[x..][0..block_pixels], b[x..][0..block_pixels])) return false;
    return std.mem.eql(u8, std.mem.sliceAsBytes(a[end..]), std.mem.sliceAsBytes(b[end..]));
}

/// Compares one block of packed pixels with a single reduction.
pub inline fn sameBlock(a: *const [block_pixels]Pixel, b: *const [block_pixels]Pixel) bool {
    const va: @Vector(block_pixels, u32) = @bitCast(a.*);
    const vb: @Vector(block_pixels, u32) = @bitCast(b.*);
    return @reduce(.And, va == vb);
}

/// Loads one vector step of packed pixels as 32-bit words.
pub fn load(block: *const [lanes]Pixel) @Vector(lanes, u32) {
    return @bitCast(block.*);
}

test "same compares every channel" {
    try std.testing.expect(same(.{ 1, 2, 3, 4 }, .{ 1, 2, 3, 4 }));
    try std.testing.expect(!same(.{ 1, 2, 3, 4 }, .{ 1, 2, 3, 5 }));
    const block: [lanes]Pixel = @splat(.{ 9, 9, 9, 9 });
    try std.testing.expect(@reduce(.And, load(&block) == load(&block)));
}

test "block and tail comparisons find differences in every lane" {
    const original: [2 * block_pixels + 3]Pixel = @splat(.{ 13, 27, 92, 255 });
    var changed = original;
    try std.testing.expect(sameRun(&original, &changed));
    try std.testing.expect(!sameRun(&original, changed[1..]));
    for (&changed) |*pixel| {
        pixel[3] = 128;
        try std.testing.expect(!sameRun(&original, &changed));
        pixel[3] = 255;
    }
}

test {
    std.testing.refAllDecls(@This());
}
