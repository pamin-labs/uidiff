//! PNG headers, chunk framing, and scanline filter definitions.
const std = @import("std");

/// The tag and payload of a complete PNG chunk.
pub const Chunk = struct {
    kind: [4]u8,
    data: []const u8,
};

/// Walks a PNG chunk stream. A partial chunk leaves the remainder intact.
pub const Chunks = struct {
    remaining: []const u8,

    pub inline fn next(self: *Chunks) ?Chunk {
        const bytes = self.remaining;
        if (bytes.len < chunk_overhead) return null;
        const length: usize = readU32(bytes, 0);
        if (length > bytes.len - chunk_overhead) return null;
        const payload = bytes[chunk_prefix..];
        // The length check leaves room for the stored checksum.
        self.remaining = payload[length +% @sizeOf(u32) ..];
        return .{ .kind = bytes[@sizeOf(u32)..chunk_prefix].*, .data = payload[0..length] };
    }

    /// Advances like next and returns the computed and stored CRC values.
    pub fn nextChecksums(self: *Chunks) ?struct { computed: u32, stored: u32 } {
        const bytes = self.remaining;
        _ = self.next() orelse return null;
        const checksum_offset = bytes.len - self.remaining.len - @sizeOf(u32);
        return .{
            .computed = std.hash.Crc32.hash(bytes[@sizeOf(u32)..checksum_offset]),
            .stored = readU32(bytes, checksum_offset),
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
/// Image data, image end, palette and transparency chunk tags.
pub const idat_type = "IDAT";
pub const iend_type = "IEND";
pub const plte_type = "PLTE";
pub const trns_type = "tRNS";
/// Number of data bytes in the first chunk.
pub const header_data_bytes = 13;
/// Signature, chunk length and chunk type before the header data.
pub const header_prefix = signature ++ [_]u8{ 0, 0, 0, header_data_bytes } ++ header_type;
/// Minimum prefix that includes the first chunk's data, excluding its CRC.
pub const header_bytes = header_prefix.len + header_data_bytes;
/// Offset of the big-endian 32-bit width and height.
pub const dimensions_offset = signature.len + @sizeOf(u32) + header_type.len;

/// First field after the two dimensions.
pub const profile_offset = dimensions_offset + dimensions_bytes;
/// Total bytes occupied by the width and height.
pub const dimensions_bytes = 2 * @sizeOf(u32);
/// Bits per sample in the streaming profiles.
pub const sample_depth = 8;
/// Offset of the first chunk after IHDR and its CRC.
pub const header_end = header_bytes + @sizeOf(u32);

/// Bytes occupied by a chunk length and tag.
pub const chunk_prefix = 2 * @sizeOf(u32);
const chunk_overhead = chunk_prefix + @sizeOf(u32);

/// Writes the signature and an eight-bit noninterlaced IHDR. The codec's
/// chunk writer supplies framing and the CRC implementation.
pub fn writeHeader(comptime writeChunk: anytype, out: *std.Io.Writer, width: u32, height: u32, colour: Colour) std.Io.Writer.Error!void {
    try out.writeAll(signature);
    var header: [header_data_bytes]u8 = undefined;
    writeDimensions(header[0..dimensions_bytes], width, height);
    header[8..13].* = .{ sample_depth, @backingInt(colour), 0, 0, 0 };
    try writeChunk(out, header_type, &header);
}

/// Writes the width and height fields of an IHDR.
pub fn writeDimensions(fields: *[dimensions_bytes]u8, width: u32, height: u32) void {
    std.mem.writeInt(u32, fields[0..@sizeOf(u32)], width, .big);
    std.mem.writeInt(u32, fields[@sizeOf(u32)..], height, .big);
}

/// Recomputes the checksum after a fixture changes IHDR fields.
pub fn rewriteHeaderCrc(bytes: *[header_end]u8) void {
    const fields = bytes[signature.len + @sizeOf(u32) .. header_bytes];
    std.mem.writeInt(u32, bytes[header_bytes..header_end], std.hash.Crc32.hash(fields), .big);
}

/// Chooses the nearest of three neighbouring 8-bit samples widened to i16.
pub fn paeth(a: i16, b: i16, c: i16) i16 {
    const left = @abs(b - c);
    const top = @abs(a - c);
    const corner = @abs(a + b - c - c);
    return if (left <= @min(top, corner)) a else if (top <= corner) b else c;
}

/// Reads a big-endian PNG field at a previously bounded offset.
pub fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..@sizeOf(u32)], .big);
}

test {
    std.testing.refAllDecls(@This());
}
