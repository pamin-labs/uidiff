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

test {
    std.testing.refAllDecls(@This());
}
