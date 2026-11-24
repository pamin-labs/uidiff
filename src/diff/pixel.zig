//! Pixel equality and the SIMD lane count shared by the column and colour scans.
const std = @import("std");
const values = @import("../value.zig");
const Pixel = values.Pixel;

/// Pixels compared per vector step: the target's widest vector of 32-bit
/// words (4 on SSE2 and NEON, 8 with AVX2). Without SIMD registers the
/// compiler splits a 4-wide vector into scalars.
pub const lanes = std.simd.suggestVectorLength(u32) orelse 4;

/// Compares all four channels at once.
pub fn same(a: Pixel, b: Pixel) bool {
    return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
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

test {
    std.testing.refAllDecls(@This());
}
