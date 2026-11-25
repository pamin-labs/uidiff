//! The synthetic fixture set: its cases, file names and paths, for the build,
//! the tests and the benchmark. The generator and its encoders sit in fixtures/.
const std = @import("std");
const cases = @import("fixtures/cases.zig");

/// Which image in a comparison pair to use.
pub const Side = cases.Side;
/// File suffixes for the supported fixture encoders.
pub const Format = cases.Format;
/// Change applied to the second image.
pub const Change = cases.Change;
/// One generated comparison pair.
pub const Case = cases.Case;
/// A tiny PNG whose header claims an image too large to decode.
pub const Claim = cases.Claim;
/// Device pixels per logical pixel used in every fixture.
pub const scale = cases.scale;
/// Repository directory for generated data.
pub const directory = cases.directory;
/// Every generated comparison pair.
pub const all = cases.all;
/// Headers that claim more memory than one decode may hold.
pub const claims = cases.claims;
/// Returns the first case with the given change.
pub const find = cases.find;
/// Every file the generator writes, inside the generated directory.
pub const files = cases.files;
/// JPEG profiles for decoded-pixel identity and fuzz coverage.
pub const jpeg = @import("fixtures/jpeg.zig");

test {
    std.testing.refAllDecls(@This());
}
