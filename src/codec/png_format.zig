//! PNG signature and first-chunk fields shared by probing and writing.
const std = @import("std");

/// Marks a file as PNG, before its chunk framing.
pub const signature = "\x89PNG\r\n\x1a\n";
/// The mandatory first chunk's type.
pub const header_type = "IHDR";
/// Number of data bytes in the first chunk.
pub const header_data_bytes = 13;
/// Signature, chunk length and chunk type before the header data.
pub const header_prefix = signature ++ [_]u8{ 0, 0, 0, header_data_bytes } ++ header_type;
/// Minimum prefix that includes the first chunk's data, excluding its CRC.
pub const header_bytes = header_prefix.len + header_data_bytes;
/// Offset of the big-endian 32-bit width and height.
pub const dimensions_offset = signature.len + @sizeOf(u32) + header_type.len;

/// First field after the two dimensions.
pub const profile_offset = dimensions_offset + 2 * @sizeOf(u32);
/// Offset of the PNG colour type byte.
pub const color_offset = profile_offset + 1;
/// Bits per channel in the RGB8 and RGBA8 profiles.
pub const sample_depth = 8;
/// PNG colour type with red, green and blue channels.
pub const rgb_color = 2;
/// PNG colour type with red, green, blue and alpha channels.
pub const rgba_color = 6;

/// Up uses the previous scanline as its predictor.
pub const up_filter = 2;

/// Sub uses the preceding pixel as its predictor.
pub const sub_filter = 1;

/// Paeth chooses the nearest of three neighbouring samples.
pub const paeth_filter = 4;

test {
    std.testing.refAllDecls(@This());
}
