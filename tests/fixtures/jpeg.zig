//! Small procedural JPEG profiles shared by the decoder gate and fuzzer.
const std = @import("std");

/// An encoded profile and its expected SHA-256 of tightly packed RGBA8.
pub const Profile = struct {
    name: []const u8,
    encoded: []const u8,
    rgba_sha256: []const u8,
};

/// The generator's frame width, in pixels.
pub const width = 37;
/// The generator's frame height, in pixels.
pub const height = 21;

/// Profiles spanning both chroma upsamplers, progressive scans and colour conversions.
pub const profiles = [_]Profile{
    .{ .name = "4:2:0", .encoded = @embedFile("jpeg/420.jpg"), .rgba_sha256 = "155ab91af36853d416287c39981199af21aeef97ec597a034759246b2056adeb" },
    .{ .name = "4:2:2", .encoded = @embedFile("jpeg/422.jpg"), .rgba_sha256 = "77eda7d32955839ae96f284e2e1581432139e3aaa70f77d71edc45c7dab274d9" },
    .{ .name = "progressive 4:2:0", .encoded = @embedFile("jpeg/progressive.jpg"), .rgba_sha256 = "155ab91af36853d416287c39981199af21aeef97ec597a034759246b2056adeb" },
    .{ .name = "grayscale", .encoded = @embedFile("jpeg/gray.jpg"), .rgba_sha256 = "29c3badf86322d4fd0d0ab8cbe1d90e70f2fe22c7e6c68b7d240f72c37b4b171" },
    .{ .name = "Adobe CMYK", .encoded = @embedFile("jpeg/cmyk.jpg"), .rgba_sha256 = "18e094fd048780a9dbd22bc0b1ee7803deb0c93b6cac1bff90772d79451fd75c" },
    .{ .name = "Adobe YCCK", .encoded = @embedFile("jpeg/ycck.jpg"), .rgba_sha256 = "e3226da81964c5bce13197b07bcecff1eda88ffc9dbc6cd452b320703d9c2876" },
};

test {
    std.testing.refAllDecls(@This());
}
