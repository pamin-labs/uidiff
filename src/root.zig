//! Compares images in memory or on disk and produces reports and annotated sheets.
const std = @import("std");
const value = @import("value.zig");
const diff = @import("diff.zig");
const codec = @import("codec.zig");
const annotate = @import("annotate.zig");
const pipeline = @import("pipeline.zig");

// Keeps the codec's C hooks in every build that links the decoders.
comptime {
    _ = codec;
}

/// The versioned JSON report schema and its writer.
pub const report = @import("report.zig");
/// Borrowed packed pixels and their source dimensions.
pub const Image = value.Image;
/// Four channels in RGBA byte order.
pub const Pixel = value.Pixel;
/// Source dimensions in device pixels.
pub const Size = value.Size;
/// Rectangle in device pixels.
pub const Box = value.Box;
/// Classifies a region. This enum is non-exhaustive and switches must handle `_`.
pub const Kind = value.Kind;
/// A numbered change with boxes on the affected sides.
pub const Region = value.Region;
/// Selects the source image for a region or annotation.
pub const Side = value.Side;
/// Borrows both images for the call. The returned Comparison holds no pixel references.
pub const Pair = value.Pair;
/// Settings for comparing decoded images.
pub const CompareOptions = diff.Options;
/// Settings for comparing files and limiting each decode.
pub const FileCompareOptions = pipeline.FileCompareOptions;
/// Owns numbered regions and moves and records the combined canvas dimensions.
pub const Comparison = diff.Comparison;
/// Invalid images, invalid scale, or an allocation failure during comparison.
pub const CompareError = diff.CompareError;
/// Device pixels per CSS pixel.
pub const Scale = value.Scale;
/// Padding added around each reported box, in CSS pixels, before conversion
/// to device pixels and clipping to the corresponding image.
pub const region_padding = diff.region_padding;
/// The most regions a comparison reports and a sheet accepts.
pub const max_regions = value.max_regions;
/// Source dimensions per side, which Region.check and Move.check take.
pub const Sizes = value.Sizes;
/// The encoded format identified by the decoder.
pub const Format = codec.Format;
/// An image with decoder-owned pixels, released by deinit.
pub const Decoded = codec.Decoded;
/// Malformed, unsupported, or over-limit image inputs and decode allocation failures.
pub const DecodeError = codec.DecodeError;
/// Failures opening or reading an encoded file, including size and allocation failures.
pub const ReadError = codec.ReadError;
/// Allocation, invalid image or output failures while encoding.
pub const EncodeError = codec.EncodeError;
/// The largest encoded input file or byte stream accepted, in bytes.
pub const max_encoded_bytes = codec.max_encoded_bytes;
/// Maximum source dimension in device pixels.
pub const max_extent = value.max_extent;
/// Maximum source pixel count.
pub const max_pixels = value.max_pixels;
/// Default and largest per-image decode memory budget, in bytes.
pub const max_decode_bytes = value.max_decode_bytes;
/// Decodes PNG, JPEG, or WebP bytes of at most max_encoded_bytes within a
/// decode memory budget, clamped to max_decode_bytes. Release the result
/// with Decoded.deinit.
pub const decode = codec.decode;
/// Reads and decodes a PNG, JPEG, or WebP file of at most max_encoded_bytes
/// within a decode memory budget, clamped to max_decode_bytes. Release the
/// result with Decoded.deinit.
pub const decodeFile = codec.decodeFile;
/// Reads an image file without decoding it, up to max_encoded_bytes.
/// Free the returned bytes with the supplied allocator.
pub const readFile = codec.readFile;
/// Encodes an RGBA8 image as PNG. The caller owns the writer and its flush.
pub const encodePng = codec.encodePng;
/// Owns the RGBA8 pixels of an annotated sheet.
pub const Sheet = annotate.Sheet;
/// Invalid inputs, an oversized sheet, or an allocation failure from rendering.
pub const RenderError = annotate.RenderError;
/// A vertically moved row range and its source columns.
pub const Move = value.Move;
/// A row range in source device pixels.
pub const RowRange = value.RowRange;
/// A length in CSS pixels.
pub const CssPx = value.CssPx;
/// Renders an RGBA8 sheet from the source images, regions, and moves.
/// Release the result with Sheet.deinit and the supplied allocator.
pub const renderSheet = annotate.renderSheet;
/// Streams a comparison sheet as PNG without allocating the full sheet,
/// compressing large sheets concurrently through io. The caller owns the
/// writer and its flush.
pub const encodeSheet = pipeline.encodeSheet;
/// Borrows the two input paths and the optional sheet destination.
pub const Paths = pipeline.Paths;
/// Borrows the path of the file a failure concerns, when one is known.
pub const Diagnostics = pipeline.Diagnostics;
/// Failures laying out or encoding a streamed sheet.
pub const EncodeSheetError = pipeline.EncodeSheetError;
/// Failures reading or decoding the inputs, comparing them, or producing the sheet.
pub const FileCompareError = pipeline.FileCompareError;
/// Decodes two files, compares them, and optionally writes the sheet atomically.
/// Release the result with Comparison.deinit and the supplied allocator.
pub const compareFiles = pipeline.compareFiles;

/// Compares borrowed RGBA8 images. Release the result with Comparison.deinit
/// and the supplied allocator.
pub fn compare(allocator: std.mem.Allocator, pair: Pair, options: CompareOptions) CompareError!Comparison {
    return diff.compare(allocator, pair.before, pair.after, options);
}

test "module roots expose their API" {
    inline for (.{ value, diff, codec, annotate, report, pipeline }) |module| std.testing.refAllDecls(module);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("testing/required.zig");
}
