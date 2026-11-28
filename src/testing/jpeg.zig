//! Procedural one-pixel JPEGs for the bridge's warning and scan-limit tests.
const std = @import("std");

/// Frame markers used by the baseline and progressive fixtures.
pub const Frame = enum(u8) { baseline = 0xc0, progressive = 0xc2 };

/// End-of-image marker.
pub const eoi = "\xff\xd9".*;
/// A single grayscale block with one Huffman code each for DC zero and EOB.
pub const gray = frame(.baseline) ++ "\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x3f".* ++ eoi;

const scan_bytes = 11;
const most_significant_bit = 13;
const bit_planes = most_significant_bit + 1;
const coefficient_count = 64;
const progressive_header = frame(.progressive);

/// Builds the common quantization and Huffman tables for a one-block frame.
pub fn frame(kind: Frame) [124]u8 {
    const quantization: [64]u8 = @splat(1);
    const huffman_tail: [16]u8 = @splat(0);
    return "\xff\xd8\xff\xdb\x00\x43\x00".* ++ quantization ++
        [_]u8{ 0xff, @backingInt(kind) } ++ "\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00".* ++
        "\xff\xc4\x00\x26\x00\x01".* ++ huffman_tail ++ "\x10\x01".* ++ huffman_tail;
}

/// A 1×1 progressive frame whose scans each send one bit plane of one zero
/// coefficient, for the scan-limit cases.
pub fn progressive(comptime scans: usize) [progressive_header.len + scans * scan_bytes + eoi.len]u8 {
    comptime std.debug.assert(scans <= coefficient_count * bit_planes);
    var bytes: [progressive_header.len + scans * scan_bytes + eoi.len]u8 = undefined;
    @memcpy(bytes[0..progressive_header.len], &progressive_header);
    for (0..scans) |index| {
        const coefficient: u8 = @intCast(index / bit_planes);
        const low: u8 = @intCast(most_significant_bit - index % bit_planes);
        const high = if (low == most_significant_bit) 0 else low + 1;
        const start = progressive_header.len + index * scan_bytes;
        // The only Huffman symbol (or DC refinement bit) is zero; pad with ones.
        bytes[start..][0..scan_bytes].* = .{ 0xff, 0xda, 0, 8, 1, 1, 0, coefficient, coefficient, high << 4 | low, 0x7f };
    }
    @memcpy(bytes[bytes.len - eoi.len ..], &eoi);
    return bytes;
}

test {
    std.testing.refAllDecls(@This());
}
