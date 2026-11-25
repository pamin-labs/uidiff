//! Small procedural JPEG profiles shared by the decoder gate and fuzzer.
const std = @import("std");

/// An encoded profile and its expected SHA-256 of tightly packed RGBA8.
pub const Profile = struct {
    name: []const u8,
    file: []const u8,
    encoded: []const u8,
    rgba_sha256: []const u8,

    fn load(comptime name: []const u8, comptime file: []const u8, comptime rgba_sha256: []const u8) Profile {
        return .{ .name = name, .file = file, .encoded = @embedFile("jpeg/" ++ file), .rgba_sha256 = rgba_sha256 };
    }
};

/// Source directory that stores the generated profiles.
pub const directory = "tests/fixtures/jpeg";
/// The generator's frame width, in pixels.
pub const width = 37;
/// The generator's frame height, in pixels.
pub const height = 21;

/// Profiles spanning both chroma upsamplers, progressive scans and colour conversions.
pub const profiles = [_]Profile{
    Profile.load("4:2:0", "420.jpg", "155ab91af36853d416287c39981199af21aeef97ec597a034759246b2056adeb"),
    Profile.load("4:2:2", "422.jpg", "77eda7d32955839ae96f284e2e1581432139e3aaa70f77d71edc45c7dab274d9"),
    Profile.load("progressive 4:2:0", "progressive.jpg", "155ab91af36853d416287c39981199af21aeef97ec597a034759246b2056adeb"),
    Profile.load("grayscale", "gray.jpg", "29c3badf86322d4fd0d0ab8cbe1d90e70f2fe22c7e6c68b7d240f72c37b4b171"),
    Profile.load("Adobe CMYK", "cmyk.jpg", "18e094fd048780a9dbd22bc0b1ee7803deb0c93b6cac1bff90772d79451fd75c"),
    Profile.load("Adobe YCCK", "ycck.jpg", "e3226da81964c5bce13197b07bcecff1eda88ffc9dbc6cd452b320703d9c2876"),
};

test {
    std.testing.refAllDecls(@This());
}
