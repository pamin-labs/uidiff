//! The byte-oriented comparison, report and annotation API.
const std = @import("std");
const values = @import("value.zig");
const diff = @import("diff.zig");
const codec = @import("codec.zig");
const annotate = @import("annotate.zig");
const files = @import("files.zig");

// Keeps the codec's C hooks in every build that links the decoders.
comptime {
    _ = codec;
}

/// The versioned JSON report schema and its writer.
pub const report = @import("report.zig");
/// Borrowed packed pixels and their source dimensions.
pub const Image = values.Image;
/// Four channels in RGBA byte order.
pub const Pixel = values.Pixel;
/// Source dimensions in device pixels.
pub const Size = values.Size;
/// Rectangle in device pixels.
pub const Box = values.Box;
/// The sides affected by a change.
pub const Kind = values.Kind;
/// A numbered change with boxes on the affected sides.
pub const Region = values.Region;
/// Selects the source image for a region or annotation.
pub const Side = values.Side;
/// Parameters for comparison and file decoding.
pub const Options = files.Options;
/// An owned set of numbered changes and the combined canvas dimensions.
pub const Comparison = diff.Comparison;
/// Input and scratch-space failures from diff.
pub const CompareError = diff.CompareError;
/// Device pixels per CSS pixel.
pub const Scale = values.Scale;
/// Space added around each reported box, in CSS pixels.
pub const region_padding = diff.region_padding;
/// The most regions a comparison reports; nearby ones merge to fit.
pub const max_regions = diff.max_regions;
/// An image with decoder-owned pixels, released by deinit.
pub const Decoded = codec.Decoded;
/// Malformed, unsupported, or over-limit encoded image inputs.
pub const DecodeError = codec.DecodeError;
/// Failures opening or reading an input file.
pub const ReadError = codec.ReadError;
/// Allocation, invalid image or output failures while encoding.
pub const EncodeError = codec.EncodeError;
/// The largest encoded input file or byte stream accepted, in bytes.
pub const max_encoded_bytes = codec.max_encoded_bytes;
/// Maximum source dimension in device pixels.
pub const max_extent = values.max_extent;
/// Maximum source area in device pixels.
pub const max_pixels = values.max_pixels;
/// Default per-image decode memory budget.
pub const max_decode_bytes = values.max_decode_bytes;
/// Decodes bounded PNG, JPEG, or WebP bytes. The caller owns the result.
pub const decode = codec.decode;
/// Reads and decodes a bounded image file. The caller owns the result.
pub const decodeFile = codec.decodeFile;
/// Reads a bounded image file without decoding it. The caller owns the bytes.
pub const readFile = codec.readFile;
/// Writes a valid image as PNG.
pub const encodePng = codec.encodePng;
/// An owned side-by-side image of both inputs with their marks.
pub const Sheet = annotate.Sheet;
/// Invalid inputs, an oversized sheet, or an allocation failure from rendering.
pub const RenderError = annotate.RenderError;
/// A vertically moved row range and its source columns.
pub const Move = values.Move;
/// One horizontal position or extent in source device pixels.
pub const DevicePx = values.DevicePx;
/// Renders the same styled comparison sheet as file annotation.
pub const renderComparisonSheet = annotate.renderSheet;
/// Streams a styled comparison sheet as PNG without a full canvas allocation.
pub const encodeComparisonSheet = files.encodeComparisonSheet;
/// The files one comparison reads and writes.
pub const Paths = files.Paths;
/// The path of the file a failure concerns.
pub const Diagnostics = files.Diagnostics;
/// Failures rendering, encoding or writing the annotated sheet.
pub const WriteError = files.WriteError;
/// File, codec, comparison and sheet failures.
pub const CompareFilesError = files.CompareError;
/// Decodes two files, compares them and writes the sheet if asked. The caller owns the result.
pub const compareFiles = files.compareFiles;

/// Compares a pair of borrowed RGBA8 values. The caller owns the result.
pub fn compare(allocator: std.mem.Allocator, before: Image, after: Image, options: Options) CompareError!Comparison {
    return diff.compare(allocator, before, after, options.comparison());
}

test "module roots expose their API" {
    inline for (.{ values, diff, codec, annotate, report, files }) |module| std.testing.refAllDecls(module);
}

test "required test selection" {
    const builtin = @import("builtin");
    const filter = @import("required_test_options").filter;
    if (filter.len == 0) return;
    for (builtin.test_functions) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".test.required test selection")) continue;
        if (std.mem.indexOf(u8, entry.name, filter) != null) return;
    }
    return error.NoSelectedTests;
}

test {
    std.testing.refAllDecls(@This());
}
