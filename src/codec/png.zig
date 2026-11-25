//! PNG format registration and encoding facade.

const std = @import("std");
const deflate = @import("png/deflate.zig");
const encoder = @import("png/encoder.zig");
const decoder = @import("png/decoder.zig");
const png_format = @import("png_format.zig");
const stb = @import("stb.zig");

/// Malformed PNG bytes, a decode past the memory budget, or allocation failure.
pub const DecodeError = decoder.DecodeError;
/// Allocation, invalid image or output failures.
pub const EncodeError = deflate.EncodeError;
/// Decodes the probed dimensions through the scanline or legacy decoder.
pub const decode = decoder.decode;
/// Runs bounded scanline decoding. Null requests the legacy fallback.
pub const loadStreaming = decoder.loadStreaming;
/// Encodes a valid image. Allocates the compressor's window and one filtered row.
pub const write = encoder.write;
/// Encodes a source that supplies one row at a time. BorrowedRows can return
/// existing pixels. Other sources are consumed in strips and can fill the
/// provided row buffer or lend a row to copy into the strip.
/// Sources may supply isOpaque for RGB output.
pub const writeRows = encoder.writeRows;

/// Probes the dimensions and channel depth.
pub const probe = stb.probe;

/// Releases decoded pixels through their PNG or fallback allocator.
pub const release = stb.release;

/// Recognizes the PNG signature.
pub fn matches(prefix: []const u8) bool {
    return std.mem.startsWith(u8, prefix, png_format.signature);
}

test {
    std.testing.refAllDecls(@This());
}
