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

test {
    std.testing.refAllDecls(image);
    std.testing.refAllDecls(region);
    std.testing.refAllDecls(scale);
}

test {
    std.testing.refAllDecls(@This());
}
