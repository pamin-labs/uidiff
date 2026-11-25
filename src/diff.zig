//! Public surface of the image comparison domain.
const std = @import("std");
const builtin = @import("builtin");
const engine = @import("diff/compare.zig");

/// Parameters for comparing decoded images.
pub const Options = engine.Options;
/// Options that passed validation.
pub const Checked = engine.Checked;
/// Owns the returned regions and moves.
pub const Comparison = engine.Comparison;
/// Input and scratch-space failures reported by comparison.
pub const CompareError = engine.CompareError;

/// Space around each reported box, in CSS pixels.
pub const region_padding = engine.region_padding;
/// The most regions a comparison reports.
pub const max_regions = engine.max_regions;

/// Compares validated images. The caller owns the result.
pub const compare = engine.compare;
/// Compares validated images with options already checked.
pub const compareChecked = engine.compareChecked;

/// Fixtures and bounds for the standalone comparison scenario tests.
pub const test_support = if (builtin.is_test) @import("diff/test_support.zig") else void;

test {
    std.testing.refAllDecls(@This());
}
