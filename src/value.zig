//! Shared data types and image bounds.
const std = @import("std");
const image = @import("value/image.zig");
const unfilled = @import("value/unfilled.zig");
const region = @import("value/region.zig");
const scale = @import("value/scale.zig");

/// Borrowed packed pixels and their source dimensions.
pub const Image = image.Image;
/// Borrowed images in comparison order.
pub const Pair = image.Pair;
/// Four channels in RGBA byte order.
pub const Pixel = image.Pixel;
/// The native vector width in packed RGBA8 pixels.
pub const pixel_lanes = image.pixel_lanes;
/// Source dimensions in device pixels.
pub const Size = image.Size;
/// Rectangle in device pixels.
pub const Box = region.Box;
/// Whole-pixel rectangle in device coordinates.
pub const PixelRect = region.PixelRect;
/// Whole-pixel rectangle in the rendered sheet.
pub const SheetRect = region.SheetRect;
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

/// Returns the same borrowed images with their sides exchanged.
pub const reversePair = image.reversePair;

/// Allocates storage that its owner will fully initialize.
pub const allocUnfilled = unfilled.allocUnfilled;
/// Releases storage obtained from allocUnfilled.
pub const freeUnfilled = unfilled.freeUnfilled;
/// Grows allocUnfilled storage without keeping its contents.
pub const reserveUnfilled = unfilled.reserveUnfilled;

test {
    std.testing.refAllDecls(image);
    std.testing.refAllDecls(unfilled);
    std.testing.refAllDecls(region);
    std.testing.refAllDecls(scale);
}

test {
    std.testing.refAllDecls(@This());
}
