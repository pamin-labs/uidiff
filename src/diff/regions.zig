//! Collects and classifies the change regions produced by comparison.

const std = @import("std");
const candidate = @import("regions/candidate.zig");
const grouping = @import("regions/grouping.zig");
const swaps = @import("regions/swaps.zig");
const tabs = @import("regions/tabs.zig");
const card_grid = @import("regions/card_grid.zig");
const overlay = @import("regions/overlay.zig");
const margin = @import("regions/margin.zig");
const corners = @import("regions/corners.zig");
const logical = @import("regions/logical.zig");
const ordering = @import("regions/ordering.zig");
const moves = @import("regions/moves.zig");

/// A pending region and the number of changed pixels supporting it.
pub const Candidate = candidate.Candidate;
/// Accumulates nearby boxes in caller-provided scratch space.
pub const Collector = grouping.Collector;
/// The one-byte state of a pixel in a change mask.
pub const Cell = grouping.Cell;
/// A change mask over a band: one byte per pixel, row-major. Zero is
/// unchanged and one changed; grouping clears it as it goes.
pub const Mask = grouping.Mask;
/// Where a band's mask sits in device pixels: its first column, and its first
/// row on each side that shows it.
pub const Placement = grouping.Placement;
/// Merged regions with fewer changed pixels are ignored as noise.
pub const min_region_pixels = grouping.min_region_pixels;
/// Initial merging distance in CSS pixels.
pub const merge_gap = candidate.merge_gap;
/// Space added around each reported box, in CSS pixels.
pub const padding = candidate.padding;
/// The most regions a comparison reports; nearby ones merge to fit.
pub const max_regions = candidate.max_regions;
/// Seeds the flood fill keeps at once (4 bytes each); more are found again by
/// rescanning their rows, so memory stays fixed however large the mask.
pub const max_fill_seeds = grouping.max_fill_seeds;
/// The component minimum, reduced to one for captures within single_pixel_area.
pub const minPixels = grouping.minPixels;
/// Puts a byte-exact exchange of two adjacent row bands into one delta.
pub const mergeSwap = swaps.mergeSwap;
/// Joins a tab indicator transfer with its reciprocal label restyling.
pub const mergeTabSelection = tabs.mergeTabSelection;
/// Pairs horizontally reflowed cards and leaves the unmatched card one-sided.
pub const pairCardGrid = card_grid.pairCardGrid;
/// Joins the retained boxes that together describe a single visible edit.
pub const mergeLogical = logical.mergeLogical;
/// Groups stationary corner changes when the unchanged straight edges connect them.
pub const mergeCorners = corners.mergeCorners;
/// Compacts moves to visible runs outside the reported edits.
pub const keepMoves = moves.keepMoves;
/// Assigns the affected side when a translucent backdrop and a new opaque
/// panel explain a full-viewport change.
pub const classifyOverlay = overlay.classifyOverlay;
/// Finds a separate colour edit embedded in a flat dimmed margin. The enclosing
/// region remains available to account for the rest of the changed pixels.
pub const shadeMarginEdit = margin.shadeMarginEdit;
/// Sorts by the before box when present, then assigns kinds, numbers and padding.
pub const finish = ordering.finish;
/// Adds eight-connected components to the collector. Sparse components can
/// reach the reporting minimum together. Asserts seeds is not empty.
pub const group = grouping.group;
/// Reports the full extent of one aligned inserted or removed row band.
pub const groupElement = grouping.groupElement;
/// Finds the next mask state using the standard library's byte search.
pub const nextCell = grouping.nextCell;

test {
    std.testing.refAllDecls(@This());
}
