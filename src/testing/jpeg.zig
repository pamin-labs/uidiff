//! Procedural one-pixel JPEGs for the bridge's warning and scan-limit tests.
const std = @import("std");
const decoder = @import("../codec/jpeg.zig");
const values = @import("../value.zig");

const Frame = enum(u8) { baseline = 0xc0, progressive = 0xc2 };
const CheckError = decoder.DecodeError || error{TestExpectedEqual};

/// End-of-image marker.
pub const eoi = "\xff\xd9".*;
/// A single grayscale block with one Huffman code each for DC zero and EOB.
pub const gray = frame(.baseline) ++ "\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x3f".* ++ eoi;

const header_bytes = frame(.progressive).len;
const scan_bytes = 11;
const most_significant_bit = 13;
const bit_planes = most_significant_bit + 1;
const coefficient_count = 64;

/// Sends one bit plane of one zero coefficient per scan, always in a 1×1 frame.
pub fn progressive(comptime scans: usize) [header_bytes + scans * scan_bytes + eoi.len]u8 {
    comptime std.debug.assert(scans <= coefficient_count * bit_planes);
    var bytes: [header_bytes + scans * scan_bytes + eoi.len]u8 = undefined;
    bytes[0..header_bytes].* = frame(.progressive);
    for (0..scans) |index| {
        const coefficient: u8 = @intCast(index / bit_planes);
        const low: u8 = @intCast(most_significant_bit - index % bit_planes);
        const high = if (low == most_significant_bit) 0 else low + 1;
        const start = header_bytes + index * scan_bytes;
        // The only Huffman symbol (or DC refinement bit) is zero; pad with ones.
        bytes[start..][0..scan_bytes].* = .{ 0xff, 0xda, 0, 8, 1, 1, 0, coefficient, coefficient, high << 4 | low, 0x7f };
    }
    bytes[bytes.len - eoi.len ..].* = eoi;
    return bytes;
}

/// Checks the baseline grayscale fixture with the supplied allocator.
pub fn checkGray(allocator: std.mem.Allocator) CheckError!void {
    const header = try decoder.probe(allocator, &gray, values.max_decode_bytes);
    const pixels = try decoder.decode(allocator, &gray, header, values.max_decode_bytes);
    defer decoder.release(allocator, pixels);
    try std.testing.expectEqualSlices(values.Pixel, &.{.{ 128, 128, 128, 255 }}, pixels);
}

fn frame(kind: Frame) [124]u8 {
    const quantization: [coefficient_count]u8 = @splat(1);
    const huffman_tail: [16]u8 = @splat(0);
    return "\xff\xd8\xff\xdb\x00\x43\x00".* ++ quantization ++
        [_]u8{ 0xff, @backingInt(kind) } ++ "\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00".* ++
        "\xff\xc4\x00\x26\x00\x01".* ++ huffman_tail ++ "\x10\x01".* ++ huffman_tail;
}
