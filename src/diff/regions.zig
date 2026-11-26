//! Collects and classifies the change regions produced by comparison.

const std = @import("std");
const value = @import("../value.zig");
const Allocator = std.mem.Allocator;
const Image = value.Image;
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
/// Maximum displacement treated as a short scroll.
pub const scroll_shift = moves.scroll_shift;
/// Adds eight-connected components to the collector. Sparse components can
/// reach the reporting minimum together. Asserts seeds is not empty.
pub const group = grouping.group;
/// Reports the full extent of one aligned inserted or removed row band.
pub const groupElement = grouping.groupElement;
/// Resolves collected evidence into owned, numbered regions and updates the retained moves.
pub fn resolve(allocator: Allocator, collector: *Collector, movement: *std.ArrayList(value.Move), before: Image, after: Image, scale: value.Scale, scroll_tolerance_px: f64) Allocator.Error![]value.Region {
    const retained = collector.retain();
    const storage = retained.buffer;
    var count = retained.count;
    if (swaps.mergeSwap(storage[0..count], movement.items, before, after, scale)) |len| {
        count = len;
        movement.clearRetainingCapacity();
    }
    if (count > 1) count = corners.mergeCorners(storage[0..count], before, after, scale);
    if (count > 1) count = logical.mergeLogical(storage[0..count], before, after, scale, movement.items);
    count = tabs.mergeTabSelection(storage[0..count], before, after, scale);
    if (movement.items.len == 0) card_grid.pairCardGrid(storage[0..count], before, after, scale);
    if (count == 1 and movement.items.len == 0 and storage.len > 1) {
        if (margin.shadeMarginEdit(storage[0].region, before, after, scale)) |mark| {
            // This smaller edit has independent evidence inside the shaded
            // extent. It must bypass the normal nearby-box merger.
            storage[1] = mark;
            count = 2;
        }
    }
    const out = try allocator.alloc(value.Region, count);
    for (out, storage[0..count]) |*region, box| region.* = box.region;
    if (movement.items.len != 0) movement.shrinkRetainingCapacity(moves.keepMoves(movement.items, out, scale, scroll_tolerance_px));
    if (out.len == 1 and movement.items.len == 0) overlay.classifyOverlay(&out[0], before, after, scale);
    ordering.finish(out, before.size(), after.size(), scale);
    return out;
}

test {
    std.testing.refAllDecls(@This());
}
