//! Procedural one-pixel JPEGs for the bridge's warning and scan-limit tests.
const std = @import("std");

/// Frame markers used by the baseline and progressive fixtures.
pub const Frame = enum(u8) { baseline = 0xc0, progressive = 0xc2 };

/// End-of-image marker.
pub const eoi = "\xff\xd9".*;
/// A single grayscale block with one Huffman code each for DC zero and EOB.
pub const gray = frame(.baseline) ++ "\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x3f".* ++ eoi;

/// Builds the common quantization and Huffman tables for a one-block frame.
pub fn frame(kind: Frame) [124]u8 {
    const quantization: [64]u8 = @splat(1);
    const huffman_tail: [16]u8 = @splat(0);
    return "\xff\xd8\xff\xdb\x00\x43\x00".* ++ quantization ++
        [_]u8{ 0xff, @backingInt(kind) } ++ "\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00".* ++
        "\xff\xc4\x00\x26\x00\x01".* ++ huffman_tail ++ "\x10\x01".* ++ huffman_tail;
}

test {
    std.testing.refAllDecls(@This());
}
