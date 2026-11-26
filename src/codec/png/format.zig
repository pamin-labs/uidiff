//! PNG headers, chunk framing, and scanline filter definitions.
const std = @import("std");

/// A framed PNG chunk, including the bytes covered by its stored CRC.
pub const Chunk = struct {
    offset: usize,
    end: usize,
    kind: [4]u8,
    data: []const u8,
    tag_and_data: []const u8,
    checksum: u32,
};

/// Walks chunks from offset up to the end of bytes. A truncated chunk
/// leaves offset unchanged, so callers can distinguish it from exhaustion.
pub const Chunks = struct {
    bytes: []const u8,
    offset: usize = signature.len,

    pub fn next(self: *Chunks) ?Chunk {
        const start = self.offset;
        const rest = self.bytes[start..];
        if (rest.len < chunk_overhead) return null;
        const length = readU32(rest, 0);
        if (length > rest.len - chunk_overhead) return null;
        const checksum_offset = chunk_prefix + @as(usize, length);
        const end = start + checksum_offset + @sizeOf(u32);
        self.offset = end;
        return .{
            .offset = start,
            .end = end,
            .kind = rest[@sizeOf(u32)..chunk_prefix].*,
            .data = rest[chunk_prefix..checksum_offset],
            .tag_and_data = rest[@sizeOf(u32)..checksum_offset],
            .checksum = readU32(rest, checksum_offset),
        };
    }
};

/// The colour types used by the PNG codec.
pub const Colour = enum(u8) { gray = 0, rgb = 2, indexed = 3, gray_alpha = 4, rgba = 6 };

/// PNG scanline predictor, in its wire representation.
pub const Filter = enum(u8) { none, sub, up, average, paeth };

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
/// Bits per sample in the streaming profiles.
pub const sample_depth = 8;
/// Offset of the first chunk after IHDR and its CRC.
pub const header_end = header_bytes + @sizeOf(u32);

const chunk_prefix = 2 * @sizeOf(u32);
const chunk_overhead = chunk_prefix + @sizeOf(u32);

/// Writes the signature and an eight-bit noninterlaced IHDR. The codec's
/// chunk writer supplies framing and the CRC implementation.
pub fn writeHeader(comptime writeChunk: anytype, out: *std.Io.Writer, width: u32, height: u32, colour: Colour) std.Io.Writer.Error!void {
    try out.writeAll(signature);
    var header: [header_data_bytes]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    header[8..13].* = .{ sample_depth, @backingInt(colour), 0, 0, 0 };
    try writeChunk(out, header_type, &header);
}

/// Chooses the nearest of three neighbouring 8-bit samples.
pub fn paeth(a: u8, b: u8, c: u8) u8 {
    const left = @abs(@as(i16, b) - c);
    const top = @abs(@as(i16, a) - c);
    const corner = @abs(@as(i16, a) + b - c - c);
    return if (left <= @min(top, corner)) a else if (top <= corner) b else c;
}

/// Reads a big-endian PNG field at a previously bounded offset.
pub fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..@sizeOf(u32)], .big);
}

test {
    std.testing.refAllDecls(@This());
}
