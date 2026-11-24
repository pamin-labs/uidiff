//! Shared data types and image bounds.
const std = @import("std");
const image = @import("value/image.zig");
const region = @import("value/region.zig");
const scale = @import("value/scale.zig");

/// Borrowed packed pixels and their source dimensions.
pub const Image = image.Image;
/// Four channels in RGBA byte order.
pub const Pixel = image.Pixel;
/// Source dimensions in device pixels.
pub const Size = image.Size;
/// Rectangle in device pixels.
pub const Box = region.Box;
/// Device pixels per CSS pixel.
pub const Scale = scale.Scale;
/// CSS-pixel length.
pub const CssPx = scale.CssPx;
/// Source device-pixel position or length.
pub const DevicePx = region.DevicePx;
/// Rows in the rendered sheet's coordinate space.
pub const SheetRowRange = region.SheetRowRange;
/// The sides affected by a change.
pub const Kind = region.Kind;
/// A numbered change with boxes on the affected sides.
pub const Region = region.Region;
/// Selects the source image for a region or annotation.
pub const Side = region.Side;
/// One aligned row range in device pixels.
pub const RowRange = region.RowRange;
/// A block aligned at different vertical positions, within the given columns.
pub const Move = region.Move;
/// The most pixels one image may hold.
pub const max_pixels = image.max_pixels;
/// Arithmetic bound for a single dimension.
pub const max_extent = image.max_extent;
/// The largest encoded input file or byte stream accepted, in bytes.
pub const max_encoded_bytes = image.max_encoded_bytes;
/// The most memory one decode may hold, in bytes.
pub const max_decode_bytes = image.max_decode_bytes;

/// Allocates storage for non-zero-sized elements that the caller initializes.
pub fn allocUnfilled(comptime T: type, allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error![]T {
    if (@sizeOf(T) == 0) @compileError("unfilled storage requires non-zero-sized elements");
    const size = std.math.mul(usize, count, @sizeOf(T)) catch return error.OutOfMemory;
    if (size == 0) return &.{};
    const ptr = allocator.rawAlloc(size, .of(T), @returnAddress()) orelse return error.OutOfMemory;
    // rawAlloc guarantees this alignment for the whole byte span.
    const aligned: [*]T = @ptrCast(@alignCast(ptr));
    return aligned[0..count];
}

/// Releases storage obtained from allocUnfilled without refilling it.
pub fn freeUnfilled(comptime T: type, allocator: std.mem.Allocator, data: []const T) void {
    if (data.len == 0) return;
    allocator.rawFree(@constCast(std.mem.sliceAsBytes(data)), .of(T), @returnAddress());
}

test "unfilled storage handles empty slices and preserves element alignment" {
    const allocator = std.testing.allocator;
    const empty = try allocUnfilled(u32, allocator, 0);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    freeUnfilled(u32, allocator, empty);
    const words = try allocUnfilled(u32, allocator, 2);
    defer freeUnfilled(u32, allocator, words);
    words[0] = 37;
    words[1] = 42;
    try std.testing.expectEqualSlices(u32, &.{ 37, 42 }, words);
}

test {
    std.testing.refAllDecls(image);
    std.testing.refAllDecls(region);
    std.testing.refAllDecls(scale);
}

test {
    std.testing.refAllDecls(@This());
}
