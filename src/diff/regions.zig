//! Coalesces and orders change boxes from the comparison domain.
const std = @import("std");
const values = @import("../value.zig");
const pixel = @import("pixel.zig");
const column_bounds = @import("columns.zig");
const Size = values.Size;
const Box = values.Box;
const Region = values.Region;
const Image = values.Image;

/// A pending region and the number of changed pixels supporting it.
pub const Candidate = struct { region: Region, pixels: usize };

/// Whether a band's mask contributed pixels and met the reporting minimum.
pub const GroupResult = enum { empty, sparse, kept };

/// Accumulates nearby boxes in caller-provided scratch space.
pub const Collector = struct {
    boxes: []Candidate,
    len: usize = 0,
    /// Current merging distance in device pixels.
    gap_px: f64,
    /// The gap at which every box on a side merges.
    max_gap_px: f64,
    /// Minimum changed pixels in a merged region, from minPixels.
    min_pixels: usize = min_region_pixels,
    expanding: bool = false,

    /// Returns scratch capacity for the two validated image sizes.
    pub fn capacity(before: Size, after: Size, gap_px: usize) usize {
        return @min(max_pending_regions, cells(before, gap_px) + cells(after, gap_px));
    }

    /// Keeps a region established by geometry rather than by the pixel mask.
    pub fn add(self: *Collector, region: Region) void {
        _ = self.addPixels(region, self.min_pixels);
    }

    /// Adds a box present exclusively on one side of the comparison.
    pub fn addOn(self: *Collector, side: values.Side, box: Box) void {
        self.add(switch (side) {
            .before => .{ .before = box },
            .after => .{ .after = box },
        });
    }

    /// Merges nearby evidence, discards noise, and bounds the output count.
    pub fn growGap(self: *Collector) void {
        self.discardSparse();
        while (self.len > max_regions) self.expand();
    }

    fn addPixels(self: *Collector, region: Region, pixels: usize) bool {
        var box = self.absorb(.{ .region = region, .pixels = @min(pixels, self.min_pixels) });
        if (self.len == self.boxes.len) self.discardSparse();
        while (self.len == self.boxes.len) {
            self.expand();
            box = self.absorb(box);
        }
        self.boxes[self.len] = box;
        self.len += 1;
        return box.pixels >= self.min_pixels;
    }

    fn discardSparse(self: *Collector) void {
        var kept: usize = 0;
        for (self.boxes[0..self.len]) |box| {
            if (box.pixels < self.min_pixels) continue;
            self.boxes[kept] = box;
            kept += 1;
        }
        self.len = kept;
    }

    fn cells(size: Size, gap_px: usize) usize {
        // Two boxes on the same side cannot survive in the same grid cell.
        return (1 + (size.width - 1) / (gap_px + 1)) * (1 + (size.height - 1) / (gap_px + 1));
    }

    fn absorb(self: *Collector, candidate: Candidate) Candidate {
        var box = candidate;
        var i: usize = 0;
        while (i < self.len) {
            const other = self.boxes[i];
            // Sparse evidence may join across one empty device pixel. The
            // larger reporting gap is for regions that already have evidence.
            const a = box.region;
            const b = other.region;
            const same_kind = (a.before == null) == (b.before == null) and (a.after == null) == (b.after == null);
            const supported_gap = if (box.pixels < self.min_pixels or other.pixels < self.min_pixels) @min(self.gap_px, evidence_gap) else self.gap_px;
            const gap_px = if (!same_kind and !self.expanding) @min(supported_gap, self.gap_px / 2) else supported_gap;
            if (nearby(box.region.before, other.region.before, gap_px) or nearby(box.region.after, other.region.after, gap_px)) {
                box.region.before = unite(box.region.before, other.region.before);
                box.region.after = unite(box.region.after, other.region.after);
                box.pixels = @min(self.min_pixels, box.pixels + other.pixels);
                self.len -= 1;
                std.mem.copyForwards(Candidate, self.boxes[i..self.len], self.boxes[i + 1 .. self.len + 1]);
                i = 0;
            } else i += 1;
        }
        return box;
    }

    fn expand(self: *Collector) void {
        // The maximum spans either image. At that gap all boxes sharing a
        // side merge, leaving at most one box per side.
        self.gap_px = if (self.gap_px < 0.5) std.math.frexp(self.gap_px).significand else @min(self.gap_px * 2, self.max_gap_px);
        self.expanding = true;
        defer self.expanding = false;
        const input = self.boxes[0..self.len];
        self.len = 0;
        for (input) |region| {
            const box = self.absorb(region);
            self.boxes[self.len] = box;
            self.len += 1;
        }
    }
};

/// The one-byte state of a pixel in a change mask.
pub const Cell = enum(u8) {
    clear,
    changed,
    queued,
    needs_support,
};

/// A change mask over a band: one byte per pixel, row-major. Zero is
/// unchanged and one changed; grouping clears it as it goes.
pub const Mask = struct {
    cells: []Cell,
    /// Columns per row.
    width: usize,
};

/// Where a band's mask sits in device pixels: its first column, and its first
/// row on each side that shows it.
pub const Placement = struct { left: usize, before_y: ?usize, after_y: ?usize };

const Scrim = struct {
    transmission: f32,
    base: @Vector(3, f32),

    fn predict(self: Scrim, before: values.Pixel) @Vector(3, f32) {
        return tone(before) * @as(@Vector(3, f32), @splat(self.transmission)) + self.base;
    }

    fn residual(self: Scrim, before: values.Pixel, after: values.Pixel) f32 {
        return @reduce(.Max, @abs(tone(after) - self.predict(before)));
    }

    noinline fn matches(self: Scrim, before: values.Pixel, after: values.Pixel) bool {
        return before[3] == 255 and after[3] == 255 and self.residual(before, after) <= scrim_rounding;
    }

    noinline fn shadow(self: Scrim, before: values.Pixel, after: values.Pixel) bool {
        if (before[3] != 255 or after[3] != 255) return false;
        const predicted = self.predict(before);
        const actual = tone(after);
        const total = @reduce(.Add, predicted);
        if (total <= 0) return false;
        const transmission = @reduce(.Add, actual) / total;
        return transmission >= scrim_min_shadow_transmission and transmission < 1 and
            @reduce(.Max, @abs(actual - predicted * @as(@Vector(3, f32), @splat(transmission)))) <= scrim_rounding;
    }
};

const RailAxis = enum { horizontal, vertical };
const RailEnd = enum { start, end };
const RailDirection = struct { axis: RailAxis, exterior: RailEnd };

const PixelRect = struct {
    left: usize,
    right: usize,
    top: usize,
    bottom: usize,

    fn oriented(self: PixelRect, axis: RailAxis) PixelRect {
        return if (axis == .horizontal) self else .{
            .left = self.top,
            .right = self.bottom,
            .top = self.left,
            .bottom = self.right,
        };
    }

    fn fromBox(box: Box) PixelRect {
        return .{ .left = @intFromFloat(box.x), .right = @intFromFloat(box.right()), .top = @intFromFloat(box.y), .bottom = @intFromFloat(box.bottom()) };
    }
};

const PanelEdge = union(enum) {
    fill: values.Pixel,
    scrim: Scrim,
};

const ShadowCheck = struct {
    area: PixelRect,
    panel: PixelRect,
    mode: union(enum) { exact: values.Pixel, scrim: Scrim },
    radius: usize,
    pitch: usize,
};

const ShadowSide = enum { top, bottom, left, right };

const ShadowProfile = struct {
    transmission: f32 = 1,
    coverage: f32 = 0,

    fn predict(self: ShadowProfile, source: values.Pixel, fill: values.Pixel) @Vector(3, f32) {
        return (Scrim{
            .transmission = self.transmission * (1 - self.coverage),
            .base = tone(fill) * @as(@Vector(3, f32), @splat(self.coverage)),
        }).predict(source);
    }
};

// Intersect the coefficient intervals that keep each channel within rounding.
const BlendFit = struct {
    low: f32,
    high: f32 = 1,

    fn include(self: *BlendFit, start: @Vector(3, f32), end: @Vector(3, f32), actual: @Vector(3, f32)) bool {
        const slopes: [rgb_channels]f32 = end - start;
        const deltas: [rgb_channels]f32 = actual - start;
        for (slopes, deltas) |slope, delta| {
            if (slope == 0) {
                if (@abs(delta) > scrim_rounding) return false;
                continue;
            }
            const a = (delta - scrim_rounding) / slope;
            const b = (delta + scrim_rounding) / slope;
            self.low = @max(self.low, @min(a, b));
            self.high = @min(self.high, @max(a, b));
            if (self.low > self.high) return false;
        }
        return true;
    }

    fn coefficient(self: BlendFit) f32 {
        return (self.low + self.high) / 2;
    }
};

/// Rows of a mask, inclusive.
const RowRange = struct { first: usize, last: usize };

/// A scanline flood fill whose seed stack is bounded. Queued pixels are
/// marked in the mask, so a seed that does not fit is found again by
/// rescanning the rows it was dropped from.
const Fill = struct {
    mask: Mask,
    seeds: []u32,
    len: usize = 0,
    /// Rows holding queued pixels that did not fit in seeds.
    pending: ?RowRange = null,

    fn push(self: *Fill, index: usize) void {
        self.mask.cells[index] = .queued;
        if (self.len < self.seeds.len) {
            // The mask is bounded by max_pixels, so every index fits u32.
            self.seeds[self.len] = @intCast(index);
            self.len += 1;
            return;
        }
        const y = index / self.mask.width;
        self.pending = widen(self.pending, .{ .first = y, .last = y });
    }

    fn pop(self: *Fill) ?usize {
        if (self.len == 0) self.refill();
        if (self.len == 0) return null;
        self.len -= 1;
        return self.seeds[self.len];
    }

    fn refill(self: *Fill) void {
        const range = self.pending orelse return;
        self.pending = null;
        const width = self.mask.width;
        for (range.first..range.last + 1) |y| {
            for (self.mask.cells[y * width ..][0..width], y * width..) |cell, index| {
                if (cell != .queued) continue;
                if (self.len == self.seeds.len) {
                    self.pending = .{ .first = y, .last = range.last };
                    return;
                }
                self.seeds[self.len] = @intCast(index);
                self.len += 1;
            }
        }
    }

    /// Clears the run holding index and queues the runs touching it above and
    /// below. Returns the run's columns, or null when it was already cleared.
    fn run(self: *Fill, index: usize) ?RowRange {
        const cells = self.mask.cells;
        if (cells[index] == .clear) return null;
        const width = self.mask.width;
        const row = index - index % width;
        var first = index - row;
        var end = first + 1;
        while (first > 0 and cells[row + first - 1] != .clear) first -= 1;
        while (end < width and cells[row + end] != .clear) end += 1;
        @memset(cells[row + first .. row + end], .clear);
        const left = first -| 1;
        const right = @min(end + 1, width);
        if (row > 0) self.queueRuns(row - width, left, right);
        if (row + width < cells.len) self.queueRuns(row + width, left, right);
        return .{ .first = first, .last = end - 1 };
    }

    fn queueRuns(self: *Fill, row: usize, first: usize, end: usize) void {
        var in_run = false;
        for (row + first..row + end) |i| {
            const state = self.mask.cells[i];
            if (state == .changed and !in_run) self.push(i);
            in_run = state != .clear;
        }
    }
};

/// Merged regions with fewer changed pixels are ignored as noise.
pub const min_region_pixels = 4;
const single_pixel_area = 1024;
/// Initial merging distance in CSS pixels.
pub const merge_gap = values.CssPx.init(12);
const evidence_gap = 1;
/// Space added around each reported box, in CSS pixels.
pub const padding = values.CssPx.init(4);
/// The most regions a comparison reports; nearby ones merge to fit.
pub const max_regions = 8;
// Bound the initial list and its quadratic merge work on highly fragmented images.
const max_pending_regions = 4096;
/// A complete rectangular outline has a mark at each of its corners.
const outline_corners = 4;
const corner_overlap = 0.75;
const line_overlap = 0.7;
const stack_overlap = 0.5;
const sideways_explained_percent = 90;
const sideways_agreement_percent = 98;
const percent_scale = 100;
const line_height = values.CssPx.init(48);
const line_gap_factor = 3;
const divider_context = 3;
const stack_gap = values.CssPx.init(20);
// Only compact cards can connect vertically separated marks. A wide panel
// or a tall list can contain multiple unrelated rows.
const compact_card_height = values.CssPx.init(128);
const compact_card_width = values.CssPx.init(360);
// Bound outline work across merge restarts.
const max_card_probes = max_regions * max_regions;
const card_corner_reach = values.CssPx.init(20);
// Samples around the viewport imply a shared backdrop only when there is
// enough contrast to distinguish a scrim from a replacement solid colour.
const min_scrim_extent = 24;
const scrim_sample_pitch = 4;
const scrim_fit_pitch = 8;
const scrim_fit_margin_divisor = 4;
const panel_center_inset_divisor = 16;
const scrim_min_contrast = 8;
const scrim_max_transmission = 0.90;
const scrim_min_transmission = 0.12;
const scrim_rounding = 2.0;
const scrim_shadow_radius = values.CssPx.init(24);
const max_scrim_shadow_radius = 72;
const scrim_min_shadow_transmission = 0.82;
const scrim_window_contrast = 12.0;
const floating_panel_height = values.CssPx.init(96);
const floating_panel_width_to_height = 3;
const floating_panel_min_width = 4;
const floating_panel_min_fill_height_divisor = 2;
const rgb_channels = 3;
const floating_panel_min_contrast = rgb_channels * 32;
const floating_panel_inset_divisor = 4;
const floating_panel_edge_fringe = 3;
const existing_panel_width_divisor = 2;
const floating_shadow_pitch = 1;
const max_swap_pitch = values.CssPx.init(128);
const tab_parts = 3;
const tab_indicator_height = values.CssPx.init(6);
const tab_label_gap = values.CssPx.init(16);
const corner_rail_contrast = 36;
const corner_join_rounding = 2;
const max_corner_rail = values.CssPx.init(2048);
const min_grid_slots = 3;
const max_grid_slots = 4;
const min_grid_card_extent = values.CssPx.init(32);
const max_grid_gutter = values.CssPx.init(48);
const blank_tolerance = 24;
const max_sideways_shift = 256;
const shift_samples = 9;
const shift_columns = 512;
const shift_min_pixels = 16;
const min_move_height = values.CssPx.init(4);
/// Seeds the flood fill keeps at once (4 bytes each); more are found again by
/// rescanning their rows, so memory stays fixed however large the mask.
pub const max_fill_seeds = 64 * 1024;
/// The component minimum, reduced to one for captures within single_pixel_area.
pub fn minPixels(before: Size, after: Size) usize {
    const smallest = @min(before.width * before.height, after.width * after.height);
    return if (smallest <= single_pixel_area) 1 else min_region_pixels;
}

/// Puts a byte-exact exchange of two adjacent row bands into one delta.
pub fn mergeSwap(boxes: []Candidate, moves: []const values.Move, before: Image, after: Image, scale: values.Scale) ?usize {
    if (before.width != after.width or before.height != after.height) return null;
    if (moves.len == 1 and boxes.len == 2) return reciprocalMove(boxes, moves[0], before, after);
    if (moves.len != 0 or boxes.len < 3 or boxes.len > max_regions) return null;
    return positionalSwap(boxes, before, after, scale.devicePixels(max_swap_pitch));
}

/// Joins a tab indicator transfer with its reciprocal label restyling.
pub fn mergeTabSelection(boxes: []Candidate, before: Image, after: Image, scale: values.Scale) usize {
    if (boxes.len != tab_parts) return boxes.len;
    var stationary: [max_regions]Box = undefined;
    const parts = stationaryBoxes(boxes, &stationary) orelse return boxes.len;
    std.sort.insertion(Box, parts, {}, boxAbove);
    const label, const first, const last = parts[0..tab_parts].*;
    const a, const b = if (first.x < last.x) .{ first, last } else .{ last, first };
    if (label.height > scale.devicePixels(line_height) or a.y != b.y or a.height != b.height or
        a.height > scale.devicePixels(tab_indicator_height) or a.y < label.bottom() or
        a.y - label.bottom() > scale.devicePixels(tab_label_gap) or a.right() >= b.x) return boxes.len;
    const background = indicatorTransfer(before, after, a, b) orelse return boxes.len;
    if (!labelTransfer(before, after, label, a, b, background)) return boxes.len;
    return collapse(boxes, unite(unite(a, b), label).?);
}

/// Pairs horizontally reflowed cards and leaves the unmatched card one-sided.
pub fn pairCardGrid(boxes: []Candidate, before: Image, after: Image, scale: values.Scale) void {
    if (boxes.len < min_grid_slots or boxes.len > max_grid_slots) return;
    var slots: [max_regions]Box = undefined;
    const row = stationaryBoxes(boxes, &slots) orelse return;
    std.sort.insertion(Box, row, {}, boxLeftOf);
    const first = row[0];
    const pitch = row[1].x - first.x;
    const gutter = pitch - first.width;
    const min_extent = scale.devicePixels(min_grid_card_extent);
    if (gutter <= 0 or gutter > scale.devicePixels(max_grid_gutter) or first.width < min_extent) return;
    const slack = scale.devicePixels(padding);
    var top = first.y;
    var bottom = first.bottom();
    for (row, 0..) |slot, index| {
        if (slot.x != first.x + pitch * @as(f64, @floatFromInt(index)) or slot.width != first.width or
            slot.height < min_extent or @abs(slot.y - first.y) > slack or @abs(slot.bottom() - first.bottom()) > slack) return;
        top = @min(top, slot.y);
        bottom = @max(bottom, slot.bottom());
    }
    const old_to_left = shiftedGrid(before, after, row, @intFromFloat(top), @intFromFloat(bottom));
    if (!old_to_left and !shiftedGrid(after, before, row, @intFromFloat(top), @intFromFloat(bottom))) return;
    // Each translated slot has an exact counterpart. The only unpaired
    // slot is the card at the start of the row, in either direction.
    boxes[0].region = if (old_to_left) .{ .before = first } else .{ .after = first };
    for (boxes[1..], row[1..], row[0 .. row.len - 1]) |*candidate, from, to| {
        candidate.region = if (old_to_left) .{ .before = from, .after = to } else .{ .before = to, .after = from };
    }
}

/// Joins the retained boxes that together describe a single visible edit.
pub noinline fn mergeLogical(boxes: []Candidate, before: Image, after: Image, scale: values.Scale, moves: []const values.Move) usize {
    var len = boxes.len;
    var card_probes: usize = if (moves.len == 0) max_card_probes else 0;
    var i: usize = 0;
    while (i < len) {
        var j = i + 1;
        while (j < len) {
            const a = boxes[i].region;
            const b = boxes[j].region;
            const related = sameLine(a, b, before, after, scale.devicePixels(line_height)) or
                stacked(a, b, before, after, scale.devicePixels(stack_gap)) or
                shiftedSideways(a, b, before, after);
            const card = if (related or card_probes == 0) null else card: {
                card_probes -= 1;
                break :card commonCard(a, b, before, after, scale);
            };
            if (!related and card == null) {
                j += 1;
                continue;
            }
            len = join(boxes, len, i, j);
            if (card) |box| {
                boxes[i].region.before = box;
                boxes[i].region.after = box;
                len = removeCardParts(boxes[0..len], i, box);
            }
            i = 0;
            j = 1;
        }
        i += 1;
    }
    return len;
}

/// Groups stationary corner changes when the unchanged straight edges connect them.
pub noinline fn mergeCorners(boxes: []Candidate, before: Image, after: Image, scale: values.Scale) usize {
    var len = boxes.len;
    const limit = scale.devicePixels(line_height);
    const max_rail = scale.devicePixels(max_corner_rail);
    if (len == 2 and croppedCorners(boxes, before, after, limit, scale.devicePixels(padding), max_rail)) return join(boxes, len, 0, 1);
    var i: usize = 0;
    while (i + outline_corners <= len) : (i += 1) {
        const first = corner(boxes[i].region, limit) orelse continue;
        if (outlineCorners(boxes[i + 1 .. len], before, after, first, limit, max_rail)) |others| {
            // The indexes are relative to the suffix and sorted largest first.
            for (others) |j| len = join(boxes, len, i, i + 1 + j);
        }
    }
    return len;
}

/// Compacts moves to visible runs outside the reported edits.
pub fn keepMoves(moves: []values.Move, edits: []const Region, scale: values.Scale, scroll_tolerance: f64) usize {
    const minimum = scale.devicePixels(min_move_height);
    const slack = scale.devicePixels(padding);
    var len: usize = 0;
    for (moves) |move| {
        if (@as(f64, @floatFromInt(move.before.height)) < minimum) continue;
        const shift: f64 = @floatFromInt(move.shift());
        if (insideEdit(move, edits, slack, shift <= scroll_tolerance)) continue;
        moves[len] = move;
        len += 1;
    }
    return len;
}

/// Assigns the affected side when a translucent backdrop and a new opaque
/// panel explain a full-viewport change.
pub fn classifyOverlay(region: *Region, before: Image, after: Image, scale: values.Scale) void {
    if (before.width != after.width or before.height != after.height) return;
    const viewport = Box.fromPixels(0, 0, before.width, before.height);
    const old = region.before orelse return;
    const new = region.after orelse return;
    if (!std.meta.eql(old, new)) return;
    const radius: usize = @intFromFloat(@min(scale.devicePixels(scrim_shadow_radius), max_scrim_shadow_radius));
    if (!std.meta.eql(old, viewport)) {
        const max_height = scale.devicePixels(floating_panel_height);
        if (floatingPanel(before, after, new, max_height, radius)) region.before = null else if (floatingPanel(after, before, old, max_height, radius)) region.after = null;
        return;
    }
    if (overlaid(before, after, radius)) region.before = null else if (overlaid(after, before, radius)) region.after = null;
}

/// Sorts by the before box when present, then assigns kinds, numbers and padding.
pub fn finish(output: []Region, before: Size, after: Size, scale: values.Scale) void {
    // The collector caps output at max_regions. Stable insertion sort keeps
    // the ordering rule without linking a general-purpose sort into the CLI.
    std.sort.insertion(Region, output, {}, lessThan);
    const space = scale.devicePixels(padding);
    for (output, 1..) |*region, number| {
        region.number = number;
        region.kind = if (region.before == null) .inserted else if (region.after == null) .removed else .changed;
        if (region.before) |box| region.before = pad(box, before, space);
        if (region.after) |box| region.after = pad(box, after, space);
    }
}

/// Adds eight-connected components to the collector. Sparse components can
/// reach the reporting minimum together. Asserts seeds is not empty.
pub fn group(collector: *Collector, mask: Mask, seeds: []u32, at: Placement) GroupResult {
    std.debug.assert(seeds.len > 0);
    if (at.before_y != null and at.before_y == at.after_y) discardUnsupported(mask, collector.min_pixels);
    var result: GroupResult = .empty;
    var fill: Fill = .{ .mask = mask, .seeds = seeds };
    var next: usize = 0;
    // Between fills a cell is zero or changed, never queued.
    while (nextCell(mask.cells, next, .changed)) |start| {
        next = start + 1;
        fill.push(start);
        var count: usize = 0;
        var min_x = mask.width;
        var max_x: usize = 0;
        var min_y = mask.cells.len / mask.width;
        var max_y: usize = 0;
        while (fill.pop()) |index| {
            const columns = fill.run(index) orelse continue;
            const y = index / mask.width;
            count += columns.last + 1 - columns.first;
            min_x = @min(min_x, columns.first);
            max_x = @max(max_x, columns.last + 1);
            min_y = @min(min_y, y);
            max_y = @max(max_y, y);
        }
        const box = Box.fromPixels(at.left + min_x, min_y, max_x - min_x, max_y - min_y + 1);
        if (collector.addPixels(.{ .before = translated(box, at.before_y), .after = translated(box, at.after_y) }, count)) {
            result = .kept;
        } else if (result == .empty) {
            result = .sparse;
        }
    }
    return result;
}

/// Reports the full extent of one aligned inserted or removed row band.
pub fn groupElement(collector: *Collector, mask: Mask, at: Placement) bool {
    var left = mask.width;
    var right: usize = 0;
    var top = mask.cells.len / mask.width;
    var bottom: usize = 0;
    var count: usize = 0;
    for (0..top) |y| {
        const row = mask.cells[y * mask.width ..][0..mask.width];
        const first = nextCell(row, 0, .changed) orelse continue;
        const last = std.mem.lastIndexOfScalar(u8, std.mem.sliceAsBytes(row[first..]), @backingInt(Cell.changed)) orelse 0;
        left = @min(left, first);
        right = @max(right, first + last + 1);
        top = @min(top, y);
        bottom = y + 1;
        if (count < collector.min_pixels) count += std.mem.count(u8, std.mem.sliceAsBytes(row[first..][0 .. last + 1]), &.{@backingInt(Cell.changed)});
    }
    if (count < collector.min_pixels) return false;
    const box = Box.fromPixels(at.left + left, top, right - left, bottom - top);
    collector.add(.{ .before = translated(box, at.before_y), .after = translated(box, at.after_y) });
    return true;
}

/// Finds the next mask state using the standard library's byte search.
pub inline fn nextCell(cells: []const Cell, start: usize, state: Cell) ?usize {
    return std.mem.indexOfScalarPos(u8, std.mem.sliceAsBytes(cells), start, @backingInt(state));
}

// Faint specks and weak edges cannot gain evidence just by touching
// diagonally. Keep the original cardinal support before joining corners.
fn discardUnsupported(mask: Mask, minimum: usize) void {
    var start: usize = 0;
    while (nextCell(mask.cells, start, .needs_support)) |index| {
        start = index + 1;
        var seen: [min_region_pixels]usize = undefined;
        seen[0] = index;
        var len: usize = 1;
        var read: usize = 0;
        var supported = len >= minimum;
        while (read < len and !supported) : (read += 1) {
            const p = seen[read];
            const x = p % mask.width;
            const adjacent = [_]?usize{
                if (x > 0) p - 1 else null,
                if (x + 1 < mask.width) p + 1 else null,
                if (p >= mask.width) p - mask.width else null,
                if (p + mask.width < mask.cells.len) p + mask.width else null,
            };
            for (adjacent) |maybe_q| {
                const q = maybe_q orelse continue;
                const state = mask.cells[q];
                if (state == .changed) {
                    supported = true;
                    break;
                }
                if (state != .needs_support or std.mem.indexOfScalar(usize, seen[0..len], q) != null) continue;
                seen[len] = q;
                len += 1;
                if (len == minimum) {
                    supported = true;
                    break;
                }
            }
        }
        for (seen[0..len]) |p| mask.cells[p] = if (supported) .changed else .clear;
    }
}

fn insideEdit(move: values.Move, edits: []const Region, slack: f64, short_shift: bool) bool {
    for (edits) |edit| {
        const before = edit.before orelse continue;
        const after = edit.after orelse continue;
        if (containsMove(before, move.before, move, slack, short_shift) and
            containsMove(after, move.after, move, slack, short_shift)) return true;
    }
    return false;
}

fn containsMove(box: Box, rows: values.RowRange, move: values.Move, slack: f64, short_shift: bool) bool {
    const top: f64 = @floatFromInt(rows.y);
    const bottom: f64 = @floatFromInt(rows.y + rows.height);
    const left: f64 = @floatFromInt(move.x.count());
    const right: f64 = @floatFromInt(move.x.count() + move.width.count());
    if (left >= box.right() or right <= box.x) return false;
    // Sub-scroll offsets at an edited edge can extend into the next
    // alignment band. The edit still explains their overlapping rows.
    if (short_shift) {
        const overlap = @min(bottom, box.bottom() + slack) - @max(top, box.y - slack);
        return 2 * overlap > bottom - top;
    }
    return top >= box.y - slack and bottom <= box.bottom() + slack;
}

fn floatingPanel(before: Image, after: Image, box: Box, max_height: f64, radius: usize) bool {
    if (box.height > max_height or box.width < @max(floating_panel_min_width, floating_panel_width_to_height * box.height)) return false;
    const area = PixelRect.fromBox(box);
    const panel = panelRect(after, area) orelse return false;
    const x = area.right - boxPixelInset(area.right - area.left);
    const fill = after.row(panel.top)[x];
    if (toneDistance(fill, before.row(panel.top)[x]) < floating_panel_min_contrast and
        toneDistance(fill, before.row(panel.bottom - 1)[x]) < floating_panel_min_contrast) return false;
    const shadow_y = panel.bottom + floating_panel_edge_fringe;
    if (pixel.same(before.row(shadow_y)[x], after.row(shadow_y)[x])) return false;
    return !existingPanel(before, area, panel) and checkShadow(before, after, .{
        .area = area,
        .panel = panel,
        .mode = .{ .exact = fill },
        .radius = radius,
        .pitch = floating_shadow_pitch,
    });
}

fn panelRect(image: Image, area: PixelRect) ?PixelRect {
    const x = area.right - boxPixelInset(area.right - area.left);
    const y = area.top + (area.bottom - area.top) / 2;
    const fill = image.row(y)[x];
    if (fill[3] != 255) return null;
    const edge: PanelEdge = .{ .fill = fill };
    const origin = y * image.width + x;
    const stride: isize = @intCast(image.width);
    const top = y - panelReach(image, image, edge, origin, y - area.top, -stride);
    const bottom = y + 1 + panelReach(image, image, edge, origin, area.bottom - y - 1, stride);
    const height = bottom - top;
    if (height < (area.bottom - area.top) / floating_panel_min_fill_height_divisor or
        top == 0 or bottom + floating_panel_edge_fringe >= area.bottom) return null;
    const inner = (top + boxPixelInset(height)) * image.width + x;
    const left = x - panelReach(image, image, edge, inner, x - area.left, -1);
    const right = x + 1 + panelReach(image, image, edge, inner, area.right - x - 1, 1);
    const width = right - left;
    if (width < area.right - area.left - boxPixelInset(area.right - area.left) or left == 0 or right >= image.width) return null;
    const inset = boxPixelInset(width);
    if (inset == 0) return null;
    for ([_]usize{ top, bottom - 1 }) |yy| {
        for (image.row(yy)[left + inset .. right - inset]) |px| if (!pixel.same(px, fill)) return null;
    }
    for (top + boxPixelInset(height)..bottom - boxPixelInset(height)) |yy| {
        const row = image.row(yy);
        if (!pixel.same(row[left], fill) or !pixel.same(row[right - 1], fill)) return null;
    }
    return .{ .left = left, .right = right, .top = top, .bottom = bottom };
}

fn existingPanel(before: Image, area: PixelRect, panel: PixelRect) bool {
    const minimum = (panel.right - panel.left) / existing_panel_width_divisor;
    var y = panel.top;
    while (y < panel.bottom) : (y += scrim_sample_pitch) {
        const row = before.row(y)[area.left..area.right];
        var start: usize = 0;
        for (row[1..], 1..) |p, i| {
            if (pixel.same(p, row[start])) continue;
            if (start != 0 and i - start > minimum and row[start][3] == 255) return true;
            start = i;
        }
    }
    return false;
}

fn boxPixelInset(length: usize) usize {
    return length / floating_panel_inset_divisor;
}

fn toneDistance(a: values.Pixel, b: values.Pixel) f32 {
    return @reduce(.Add, @abs(tone(a) - tone(b)));
}

fn checkShadow(before: Image, after: Image, check: ShadowCheck) bool {
    return switch (check.mode) {
        .exact => |fill| checkLocalShadow(before, after, check, fill),
        .scrim => |scrim| checkScrimShadow(before, after, check, scrim),
    };
}

fn checkLocalShadow(before: Image, after: Image, check: ShadowCheck, fill: values.Pixel) bool {
    const area = check.area;
    const panel = check.panel;
    const radius = check.radius;
    var profile: [4][max_scrim_shadow_radius]ShadowProfile = undefined;
    for (std.enums.values(ShadowSide)) |side| {
        const horizontal = side == .top or side == .bottom;
        const start = if (horizontal) panel.left else panel.top;
        const end = if (horizontal) panel.right else panel.bottom;
        const extent = switch (side) {
            .top => panel.top - area.top,
            .bottom => area.bottom - panel.bottom,
            .left => panel.left - area.left,
            .right => area.right - panel.right,
        };
        for (0..@min(extent, radius)) |offset| {
            const line = switch (side) {
                .top => panel.top - 1 - offset,
                .bottom => panel.bottom + offset,
                .left => panel.left - 1 - offset,
                .right => panel.right + offset,
            };
            profile[@backingInt(side)][offset] =
                if (fitShadowLine(before, after, horizontal, line, start, end, null)) |t|
                    .{ .transmission = t }
                else if (offset < floating_panel_edge_fringe)
                    .{ .coverage = fitShadowLine(before, after, horizontal, line, start, end, fill) orelse return false }
                else
                    return false;
        }
    }
    for (area.top..area.bottom) |y| {
        const old = before.row(y);
        const new = after.row(y);
        const dy = outsideDistance(y, panel.top, panel.bottom);
        for (area.left..area.right) |x| {
            if (pixel.same(old[x], new[x])) continue;
            const dx = outsideDistance(x, panel.left, panel.right);
            if (dx == 0 and dy == 0) continue;
            if (dx > radius or dy > radius) return false;
            // The side strips already share a fitted coefficient. Corners
            // must agree with a blend between the neighbouring side values.
            if (dx == 0 or dy == 0) continue;
            if (old[x][3] != 255 or new[x][3] != 255) return false;
            const row_side: ShadowSide = if (y < panel.top) .top else .bottom;
            const col_side: ShadowSide = if (x < panel.left) .left else .right;
            var blend: BlendFit = .{ .low = 0 };
            if (!blend.include(
                profile[@backingInt(row_side)][dy - 1].predict(old[x], fill),
                profile[@backingInt(col_side)][dx - 1].predict(old[x], fill),
                tone(new[x]),
            )) return false;
        }
    }
    return true;
}

fn outsideDistance(pixel_index: usize, start: usize, end: usize) usize {
    if (pixel_index < start) return start - pixel_index;
    return (pixel_index + 1) -| end;
}

fn fitShadowLine(before: Image, after: Image, horizontal: bool, line: usize, start: usize, end: usize, fill: ?values.Pixel) ?f32 {
    var fit: BlendFit = .{ .low = if (fill == null) scrim_min_shadow_transmission else 0 };
    for (start..end) |pos| {
        const index = if (horizontal) line * before.width + pos else pos * before.width + line;
        const a = before.pixels[index];
        const b = after.pixels[index];
        if (a[3] != 255 or b[3] != 255) return null;
        const original = tone(a);
        const first = if (fill == null) @as(@Vector(3, f32), @splat(0)) else original;
        const last = if (fill) |ink| tone(ink) else original;
        if (!fit.include(first, last, tone(b))) return null;
    }
    return fit.coefficient();
}

fn checkScrimShadow(before: Image, after: Image, check: ShadowCheck, scrim: Scrim) bool {
    const area = check.area;
    const panel = check.panel;
    const radius = check.radius;
    const last_y = area.bottom - 1;
    const last_x = area.right - 1;
    var y = area.top;
    while (true) : (y = @min(y + check.pitch, last_y)) {
        const old = before.row(y);
        const new = after.row(y);
        const in_panel_rows = y >= panel.top and y < panel.bottom;
        var x = area.left;
        while (true) : (x = @min(x + check.pitch, last_x)) {
            const inside = in_panel_rows and x >= panel.left and x < panel.right;
            if (!inside) {
                const matches = scrim.matches(old[x], new[x]);
                if (!matches and (y < panel.top -| radius or y >= panel.bottom + radius or
                    x < panel.left -| radius or x >= panel.right + radius or !scrim.shadow(old[x], new[x]))) return false;
            }
            if (x == last_x) break;
        }
        if (y == last_y) break;
    }
    return true;
}

fn overlaid(before: Image, after: Image, radius: usize) bool {
    const scrim = fitScrim(before, after) orelse return false;
    const panel = panelBounds(before, after, scrim) orelse return false;
    return checkShadow(before, after, .{
        .area = .{ .left = 0, .right = before.width, .top = 0, .bottom = before.height },
        .panel = panel,
        .mode = .{ .scrim = scrim },
        .radius = radius,
        .pitch = scrim_sample_pitch,
    });
}

fn panelBounds(before: Image, after: Image, scrim: Scrim) ?PixelRect {
    const y = before.height / 2;
    const center = before.width / 2;
    const a = before.row(y);
    const b = after.row(y);
    const panel = b[center];
    const inset = before.width / panel_center_inset_divisor;
    const center_samples = [_]usize{ center - inset, center, center + inset };
    for (center_samples) |x| {
        if (!pixel.same(panel, b[x]) or scrim.residual(a[x], b[x]) < scrim_window_contrast) return null;
    }
    const origin = y * before.width + center;
    const stride: isize = @intCast(before.width);
    const right_extent = before.width - center - 1;
    const lower_extent = before.height - y - 1;
    const left = panelReach(before, after, .{ .scrim = scrim }, origin, center, -1);
    const right = panelReach(before, after, .{ .scrim = scrim }, origin, right_extent, 1);
    const top = panelReach(before, after, .{ .scrim = scrim }, origin, y, -stride);
    const bottom = panelReach(before, after, .{ .scrim = scrim }, origin, lower_extent, stride);
    if (left == center or right == right_extent or top == y or bottom == lower_extent) return null;
    return .{ .left = center - left, .right = center + right + 1, .top = y - top, .bottom = y + bottom + 1 };
}

// Takes a validated ray from a pixel to its row or column boundary.
noinline fn panelReach(before: Image, after: Image, edge: PanelEdge, origin: usize, extent: usize, step: isize) usize {
    var pos: isize = @intCast(origin);
    for (0..extent) |distance| {
        pos += step;
        const index: usize = @intCast(pos);
        if (switch (edge) {
            .scrim => |scrim| scrim.matches(before.pixels[index], after.pixels[index]),
            .fill => |fill| !pixel.same(after.pixels[index], fill),
        }) return distance;
    }
    return extent;
}

noinline fn fitScrim(before: Image, after: Image) ?Scrim {
    if (before.width < min_scrim_extent or before.height < min_scrim_extent) return null;
    // Sample through the outer page bands so low-contrast viewport chrome
    // cannot determine the transmission for high-contrast content.
    const Channels = @Vector(4, u8);
    var brightest: Channels = @splat(0);
    var darkest: Channels = @splat(255);
    var bright_overlay: Channels = undefined;
    var dark_overlay: Channels = undefined;
    const margin = before.height / scrim_fit_margin_divisor;
    var y: usize = 0;
    while (y < before.height) : (y += scrim_fit_pitch) {
        if (y >= margin and y < before.height - margin) continue;
        const source = before.row(y);
        const dimmed = after.row(y);
        var x: usize = 0;
        while (x < before.width) : (x += scrim_fit_pitch) {
            const a: Channels = source[x];
            const b: Channels = dimmed[x];
            if (a[3] != 255 or b[3] != 255) return null;
            bright_overlay = @select(u8, a >= brightest, b, bright_overlay);
            dark_overlay = @select(u8, a <= darkest, b, dark_overlay);
            brightest = @max(a, brightest);
            darkest = @min(a, darkest);
        }
    }
    const contrast = brightest - darkest;
    const range = @reduce(.Max, contrast);
    const signal: usize = if (range == contrast[0]) 0 else if (range == contrast[1]) 1 else 2;
    const highs: [4]u8 = bright_overlay;
    const lows: [4]u8 = dark_overlay;
    const peaks: [4]u8 = brightest;
    if (range < scrim_min_contrast or highs[signal] <= lows[signal] or highs[signal] >= peaks[signal]) return null;
    const transmission = @as(f32, @floatFromInt(highs[signal] - lows[signal])) / @as(f32, @floatFromInt(range));
    if (transmission < scrim_min_transmission or transmission > scrim_max_transmission) return null;
    const a = before.pixels[0];
    const b = after.pixels[0];
    const base = tone(b) - tone(a) * @as(@Vector(3, f32), @splat(transmission));
    if (@reduce(.Min, base) < -scrim_rounding or
        @reduce(.Max, base) > 255 * (1 - transmission) + scrim_rounding) return null;
    return .{ .transmission = transmission, .base = base };
}

fn tone(p: values.Pixel) @Vector(3, f32) {
    return @floatFromInt(@as(@Vector(3, u8), p[0..3].*));
}

fn join(boxes: []Candidate, len: usize, i: usize, j: usize) usize {
    boxes[i].region.before = unite(boxes[i].region.before, boxes[j].region.before);
    boxes[i].region.after = unite(boxes[i].region.after, boxes[j].region.after);
    std.mem.copyForwards(Candidate, boxes[j .. len - 1], boxes[j + 1 .. len]);
    return len - 1;
}

fn reciprocalMove(boxes: []Candidate, move: values.Move, before: Image, after: Image) ?usize {
    const old, const new = if (boxes[0].region.before != null)
        .{ boxes[0].region, boxes[1].region }
    else
        .{ boxes[1].region, boxes[0].region };
    const removed = old.before orelse return null;
    const inserted = new.after orelse return null;
    if (old.after != null or new.before != null) return null;
    const pitch = move.shift();
    if (pitch == 0 or move.before.height != pitch or move.after.height != pitch) return null;
    const x: usize = @min(move.x.count(), @as(usize, @intFromFloat(@min(removed.x, inserted.x))));
    const right: usize = @max(move.x.count() + move.width.count(), @as(usize, @intFromFloat(@max(removed.right(), inserted.right()))));
    const upper = @min(move.before.y, move.after.y);
    const cover = Box.fromPixels(x, upper, right - x, 2 * pitch);
    if (cover.overlap(removed) != removed.width * removed.height or cover.overlap(inserted) != inserted.width * inserted.height) return null;
    if (right > before.width or upper + 2 * pitch > before.height or !exchangedRows(before, after, cover, pitch, pitch)) return null;
    return collapse(boxes, cover);
}

fn positionalSwap(boxes: []Candidate, before: Image, after: Image, max_pitch: f64) ?usize {
    var storage: [max_regions]Box = undefined;
    const stationary = stationaryBoxes(boxes, &storage) orelse return null;
    var top = stationary[0];
    var whole = top;
    for (stationary[1..]) |box| {
        if (box.y < top.y) top = box;
        whole = unite(whole, box).?;
    }
    for (stationary) |opposite| {
        const pitch = opposite.y - top.y;
        if (pitch > max_pitch or opposite.x != top.x or
            opposite.width != top.width or opposite.height != top.height) continue;
        const step: usize = @intFromFloat(pitch);
        const rows = whole.height - pitch;
        if (!inSwapBands(stationary, top.y, opposite.y, rows)) continue;
        if (!exchangedRows(before, after, whole, step, @intFromFloat(rows))) continue;
        return collapse(boxes, whole);
    }
    return null;
}

fn collapse(boxes: []Candidate, cover: Box) usize {
    boxes[0].region = .{ .before = cover, .after = cover };
    return 1;
}

fn inSwapBands(boxes: []const Box, upper: f64, lower: f64, height: f64) bool {
    if (height <= 0 or upper + height > lower) return false;
    for (boxes) |box| {
        const start = if (box.y < lower) upper else lower;
        if (box.y < start or box.bottom() > start + height) return false;
    }
    return true;
}

fn stationaryBoxes(boxes: []const Candidate, storage: *[max_regions]Box) ?[]Box {
    if (boxes.len > storage.len) return null;
    const result = storage[0..boxes.len];
    for (boxes, result) |candidate, *box| box.* = stationaryBox(candidate.region) orelse return null;
    return result;
}

fn stationaryBox(region: Region) ?Box {
    const before = region.before orelse return null;
    const after = region.after orelse return null;
    return if (std.meta.eql(before, after)) before else null;
}

fn exchangedRows(before: Image, after: Image, bands: Box, pitch: usize, rows: usize) bool {
    const x: usize = @intFromFloat(bands.x);
    const right: usize = @intFromFloat(bands.right());
    const first: usize = @intFromFloat(bands.y);
    for (first..first + rows) |y| {
        if (!pixel.sameRun(before.row(y)[x..right], after.row(y + pitch)[x..right]) or
            !pixel.sameRun(after.row(y)[x..right], before.row(y + pitch)[x..right])) return false;
    }
    return true;
}

fn boxAbove(_: void, a: Box, b: Box) bool {
    return a.y < b.y;
}

fn indicatorTransfer(before: Image, after: Image, a: Box, b: Box) ?values.Pixel {
    const ax: usize = @intFromFloat(a.x + a.width / 2);
    const bx: usize = @intFromFloat(b.x + b.width / 2);
    const y: usize = @intFromFloat(a.y + a.height / 2);
    const old_indicator = before.row(y)[ax];
    const new_indicator = after.row(y)[ax];
    if (pixel.same(old_indicator, new_indicator) or !pixel.same(old_indicator, after.row(y)[bx]) or
        !pixel.same(new_indicator, before.row(y)[bx])) return null;
    const gap: usize = @intFromFloat((a.right() + b.x) / 2);
    const background = before.row(y)[gap];
    if (!pixel.same(background, after.row(y)[gap]) or
        (!pixel.same(background, old_indicator) and !pixel.same(background, new_indicator))) return null;
    return background;
}

fn labelTransfer(before: Image, after: Image, label: Box, a: Box, b: Box, background: values.Pixel) bool {
    const old_a = labelInk(before, label, a, background);
    const new_a = labelInk(after, label, a, background);
    if (pixel.same(old_a, new_a) or pixel.same(old_a, background) or pixel.same(new_a, background)) return false;
    return pixel.same(old_a, labelInk(after, label, b, background)) and
        pixel.same(new_a, labelInk(before, label, b, background));
}

fn labelInk(image: Image, label: Box, indicator: Box, background: values.Pixel) values.Pixel {
    const x: usize = @intFromFloat(@max(indicator.x, label.x));
    const right: usize = @intFromFloat(@min(indicator.right(), label.right()));
    var ink = background;
    var contrast: f32 = 0;
    if (x >= right) return ink;
    for (@as(usize, @intFromFloat(label.y))..@as(usize, @intFromFloat(label.bottom()))) |y| {
        for (image.row(y)[x..right]) |p| {
            const distance = toneDistance(p, background);
            if (distance > contrast) {
                contrast = distance;
                ink = p;
            }
        }
    }
    return ink;
}

fn boxLeftOf(_: void, a: Box, b: Box) bool {
    return a.x < b.x;
}

fn shiftedGrid(before: Image, after: Image, slots: []const Box, top: usize, bottom: usize) bool {
    const width: usize = @intFromFloat(slots[0].width);
    const last: usize = @intFromFloat(slots[slots.len - 1].x);
    const background = after.row(top)[last];
    for (top..bottom) |y| {
        for (after.row(y)[last..][0..width]) |p| if (!pixel.same(p, background)) return false;
    }
    for (slots[1..], slots[0 .. slots.len - 1]) |old, new| {
        const from: usize = @intFromFloat(old.x);
        const to: usize = @intFromFloat(new.x);
        for (top..bottom) |y| {
            if (!pixel.sameRun(before.row(y)[from..][0..width], after.row(y)[to..][0..width])) return false;
        }
    }
    return true;
}

fn corner(region: Region, limit: f64) ?Box {
    const box = stationaryBox(region) orelse return null;
    return if (@max(box.width, box.height) <= limit) box else null;
}

fn outlineCorners(boxes: []const Candidate, before: Image, after: Image, top: Box, limit: f64, max_rail: f64) ?[3]usize {
    for (boxes, 0..) |tr, j| {
        const right = corner(tr.region, limit) orelse continue;
        if (right.x <= top.right() or !sameRange(top.y, top.bottom(), right.y, right.bottom())) continue;
        for (boxes, 0..) |bl, k| {
            const bottom = corner(bl.region, limit) orelse continue;
            if (bottom.y <= top.bottom() or !sameRange(top.x, top.right(), bottom.x, bottom.right())) continue;
            for (boxes, 0..) |br, l| {
                const lower_right = corner(br.region, limit) orelse continue;
                if (!sameRange(bottom.y, bottom.bottom(), lower_right.y, lower_right.bottom()) or
                    !sameRange(right.x, right.right(), lower_right.x, lower_right.right())) continue;
                if (!tracedOutline(before, after, top, right, bottom, lower_right, max_rail)) continue;
                var order = [3]usize{ j, k, l };
                std.sort.insertion(usize, &order, {}, std.sort.desc(usize));
                return order;
            }
        }
    }
    return null;
}

fn croppedCorners(boxes: []const Candidate, before: Image, after: Image, limit: f64, clip_slack: f64, max_rail: f64) bool {
    if (before.height != after.height or before.width != after.width) return false;
    const a = corner(boxes[0].region, limit) orelse return false;
    const b = corner(boxes[1].region, limit) orelse return false;
    const left, const right = if (a.x < b.x) .{ a, b } else .{ b, a };
    const height: f64 = @floatFromInt(before.height);
    if (height - @min(left.bottom(), right.bottom()) > clip_slack or
        !sameRange(left.y, left.bottom(), right.y, right.bottom())) return false;
    return rail(before, after, left, right, .{ .axis = .horizontal, .exterior = .start }, max_rail);
}

fn tracedOutline(before: Image, after: Image, top: Box, right: Box, bottom: Box, lower_right: Box, max_rail: f64) bool {
    if (rail(before, after, top, right, .{ .axis = .horizontal, .exterior = .start }, max_rail) and
        rail(before, after, bottom, lower_right, .{ .axis = .horizontal, .exterior = .end }, max_rail) and
        rail(before, after, top, bottom, .{ .axis = .vertical, .exterior = .start }, max_rail) and
        rail(before, after, right, lower_right, .{ .axis = .vertical, .exterior = .end }, max_rail)) return true;

    // Collector boxes use whole non-negative coordinates within their before.
    const mid_x: usize = @intFromFloat((top.right() + right.x) / 2);
    const mid_y: usize = @intFromFloat((top.bottom() + bottom.y) / 2);
    const top_y: usize = @intFromFloat(top.y);
    const top_end: usize = @intFromFloat(top.bottom());
    const bottom_y: usize = @intFromFloat(bottom.y);
    const bottom_end: usize = @intFromFloat(bottom.bottom());
    const row = before.row(mid_y);
    const left_x: usize = @intFromFloat(top.x);
    const left_end: usize = @intFromFloat(top.right());
    const right_x: usize = @intFromFloat(right.x);
    const right_end: usize = @intFromFloat(right.right());
    const above = before.row(top_y -| 1)[mid_x];
    const outside = row[left_x -| 1];
    for (top_y..top_end) |y| {
        const ink = before.row(y)[mid_x];
        if ((pixel.same(ink, above) and pixel.same(ink, outside)) or
            !hasInk(row[left_x..left_end], ink) or !hasInk(row[right_x..right_end], ink)) continue;
        for (bottom_y..bottom_end) |end| {
            if (pixel.same(before.row(end)[mid_x], ink)) return true;
        }
    }
    return false;
}

fn rail(before: Image, after: Image, start: Box, end: Box, direction: RailDirection, max_rail: f64) bool {
    const a = PixelRect.fromBox(start).oriented(direction.axis);
    const b = PixelRect.fromBox(end).oriented(direction.axis);
    if (a.right >= b.left or @as(f64, @floatFromInt(b.left - a.right)) > max_rail) return false;
    const first = @max(a.top, b.top);
    const last = @min(a.bottom, b.bottom);
    if (first >= last) return false;
    const horizontal = direction.axis == .horizontal;
    const extent = if (horizontal) before.height else before.width;
    const outside = switch (direction.exterior) {
        .start => if (first != 0) first - 1 else return false,
        .end => if (last < extent) last else return false,
    };
    const along = if (horizontal) 1 else before.width;
    const across = if (horizontal) before.width else 1;
    for (first..last) |line| {
        for (a.right..b.left) |x| {
            const index = line * across + x * along;
            const ink = before.pixels[index];
            if (!pixel.same(ink, after.pixels[index]) or
                toneDistance(ink, before.pixels[outside * across + x * along]) < corner_rail_contrast) break;
        } else {
            if (!horizontal) return true;
            const old = before.row(line);
            if ((railTurns(before, start, line, old[a.right], .left, direction.exterior) and
                railTurns(before, end, line, old[b.left - 1], .right, direction.exterior)) or
                (railTurns(after, start, line, old[a.right], .left, direction.exterior) and
                    railTurns(after, end, line, old[b.left - 1], .right, direction.exterior))) return true;
        }
    }
    return false;
}

fn railTurns(image: Image, corner_box: Box, y: usize, ink: values.Pixel, side: enum { left, right }, exterior: RailEnd) bool {
    const left: usize = @intFromFloat(corner_box.x);
    const right: usize = @intFromFloat(corner_box.right());
    const outside = switch (side) {
        .left => if (left != 0) left - 1 else return false,
        .right => if (right < image.width) right else return false,
    };
    const interior_y: usize = @intFromFloat(if (exterior == .start) corner_box.bottom() - 1 else corner_box.y);
    const leg_y = @min(y, interior_y) + (@max(y, interior_y) - @min(y, interior_y) + 1) / 2;
    if (leg_y == y) return false;
    const edge = image.row(y);
    const leg = image.row(leg_y);
    if (toneDistance(ink, leg[outside]) < corner_rail_contrast) return false;
    for (left..right) |x| {
        if (toneDistance(edge[x], ink) + toneDistance(leg[x], ink) <= corner_join_rounding) return true;
    }
    return false;
}

fn sameRange(a: f64, b: f64, c: f64, d: f64) bool {
    return @min(b, d) - @max(a, c) >= corner_overlap * @max(b - a, d - c);
}

fn hasInk(row: []const values.Pixel, ink: values.Pixel) bool {
    for (row) |p| if (pixel.same(p, ink)) return true;
    return false;
}

fn sameLine(a: Region, b: Region, before: Image, after: Image, max_height: f64) bool {
    const p = a.before orelse return false;
    const q = b.before orelse return false;
    const r = a.after orelse return false;
    const s = b.after orelse return false;
    if (!lineNeighbours(p, q, max_height) or !lineNeighbours(r, s, max_height)) return false;
    return !betweenDividers(before, after, p, q, r, s);
}

fn betweenDividers(before: Image, after: Image, p: Box, q: Box, r: Box, s: Box) bool {
    const start = @max(@min(p.right(), q.right()), @min(r.right(), s.right()));
    const end = @min(@max(p.x, q.x), @max(r.x, s.x));
    if (start >= end) return false;
    // Boxes come from the collector and are within each validated image.
    const left: usize = @max(1, @as(usize, @intFromFloat(start)));
    const right: usize = @intFromFloat(end);
    if (left >= right) return false;
    const top: usize = @intFromFloat(@min(p.y, q.y, r.y, s.y));
    const bottom: usize = @intFromFloat(@max(p.bottom(), q.bottom(), r.bottom(), s.bottom()));
    const height = @min(before.height, after.height);
    if (top < divider_context or bottom + divider_context >= height) return false;
    const samples = [_]usize{ top - divider_context, (top + bottom) / 2, bottom + divider_context };
    for (left..right) |x| {
        const row = before.row(samples[0]);
        const edge_left = row[x - 1];
        const edge_right = row[x];
        if (pixel.same(edge_left, edge_right)) continue;
        for (samples) |y| {
            const a = before.row(y);
            const z = after.row(y);
            if (!pixel.same(a[x - 1], edge_left) or !pixel.same(z[x - 1], edge_left) or
                !pixel.same(a[x], edge_right) or !pixel.same(z[x], edge_right)) break;
        } else return true;
    }
    return false;
}

fn lineNeighbours(a: Box, b: Box, max_height: f64) bool {
    const tallest = @max(a.height, b.height);
    const overlap = @min(a.bottom(), b.bottom()) - @max(a.y, b.y);
    const gap_px = @max(a.x, b.x) - @min(a.right(), b.right());
    return tallest <= max_height and overlap >= line_overlap * @min(a.height, b.height) and gap_px <= line_gap_factor * tallest;
}

noinline fn commonCard(a: Region, b: Region, before: Image, after: Image, scale: values.Scale) ?Box {
    const p = a.before orelse return null;
    const q = b.before orelse return null;
    const r = a.after orelse return null;
    const s = b.after orelse return null;
    if (!std.meta.eql(p, r) or !std.meta.eql(q, s)) return null;
    const overlap = @min(p.right(), q.right()) - @max(p.x, q.x);
    const gap_px = @max(p.y, q.y) - @min(p.bottom(), q.bottom());
    if (overlap <= 0 or gap_px < 0 or gap_px > scale.devicePixels(stack_gap)) return null;
    const ink = unite(p, q).?;
    const max_height = scale.devicePixels(compact_card_height);
    const max_width = scale.devicePixels(compact_card_width);
    if (ink.height >= max_height or ink.width >= max_width) return null;
    const span: column_bounds.Span = .{ .left = @intFromFloat(ink.x), .width = @intFromFloat(ink.width) };
    const y: usize = @intFromFloat(ink.y);
    const search = column_bounds.CardSearch.compact(span, max_height, scale.devicePixels(card_corner_reach));
    const old_card = column_bounds.enclosingCard(before, span, .{ .left = 0, .width = before.width }, y, search) orelse return null;
    if (old_card.top + old_card.height < @as(usize, @intFromFloat(ink.bottom())) or
        @as(f64, @floatFromInt(old_card.columns.width)) > max_width) return null;
    const new_card = column_bounds.enclosingCard(after, span, .{ .left = 0, .width = after.width }, y, search) orelse return null;
    if (!std.meta.eql(old_card, new_card)) return null;
    return Box.fromPixels(old_card.columns.left, old_card.top, old_card.columns.width, old_card.height);
}

fn removeCardParts(boxes: []Candidate, card: usize, cover: Box) usize {
    var len: usize = 0;
    for (boxes, 0..) |part, index| {
        if (index != card) {
            if (part.region.before) |old| if (part.region.after) |new| {
                const same_position = std.meta.eql(old, new);
                if (same_position and cover.overlap(old) == old.width * old.height) continue;
            };
        }
        boxes[len] = part;
        len += 1;
    }
    return len;
}

fn stacked(a: Region, b: Region, before: Image, after: Image, max_gap_px: f64) bool {
    if ((a.before == null) != (b.before == null) or (a.after == null) != (b.after == null)) return false;
    if (a.before != null and a.after != null) return false;
    const p = a.before orelse a.after orelse return false;
    const q = b.before orelse b.after orelse return false;
    const image = if (a.before != null) before else after;
    const shared = @min(p.right(), q.right()) - @max(p.x, q.x);
    if (shared < stack_overlap * @min(p.width, q.width)) return false;
    const upper, const lower = if (p.y <= q.y) .{ p, q } else .{ q, p };
    const gap_px = lower.y - upper.bottom();
    if (gap_px > max_gap_px) return false;
    if (gap_px <= 0) return true;
    // The collector has already bounded these whole pixel boxes to their image.
    const left: usize = @intFromFloat(@min(p.x, q.x));
    const right: usize = @intFromFloat(@max(p.right(), q.right()));
    // Edge coverage can finish one row beyond the component bounds.
    const first: usize = @intFromFloat(upper.bottom() + 1);
    const end: usize = @intFromFloat(@max(upper.bottom() + 1, lower.y - 1));
    for (first..end) |y| {
        const row = image.row(y)[left..right];
        for (row[1..]) |p_ink| {
            for (0..3) |c| {
                if (@abs(@as(i16, p_ink[c]) - @as(i16, row[0][c])) > blank_tolerance) return false;
            }
        }
    }
    return true;
}

noinline fn shiftedSideways(a: Region, b: Region, before: Image, after: Image) bool {
    const p = a.before orelse return false;
    const q = b.before orelse return false;
    const pa = a.after orelse return false;
    const qa = b.after orelse return false;
    if (@abs(p.y - q.y) > 1 or @abs(p.bottom() - q.bottom()) > 1 or p.y != pa.y or q.y != qa.y) return false;
    // The collector has already bounded these whole pixel boxes to their image.
    const left: usize = @intFromFloat(@min(p.x, q.x));
    const right: usize = @intFromFloat(@min(@max(p.right(), q.right()), @as(f64, @floatFromInt(@min(before.width, after.width)))));
    const top: usize = @intFromFloat(@min(p.y, q.y));
    const height: usize = @intFromFloat(@max(p.bottom(), q.bottom()) - @as(f64, @floatFromInt(top)));
    if (right <= left + 2 or height == 0 or top + height > @min(before.height, after.height)) return false;
    const reach: usize = @intFromFloat(@min(max_sideways_shift, @max(p.width, q.width)));
    const count: usize = @min(shift_samples, height);
    for (1..reach + 1) |distance| {
        for ([_]bool{ false, true }) |rightward| {
            const start = if (rightward) @max(left, distance) else left;
            const end = if (rightward) right else @min(right, before.width -| distance);
            if (start >= end) continue;
            const from = if (rightward) left -| distance else left + distance;
            const stride: usize = 1 + (end - start - 1) / shift_columns;
            const middle = shiftEvidence(before.row(top + height / 2), after.row(top + height / 2), start, end, from, stride);
            if (2 * middle.explained < middle.changed or middle.same == 0) continue;
            var seen: usize = 0;
            var same: usize = 0;
            var changed: usize = 0;
            var explained: usize = 0;
            for (0..count) |i| {
                const y = top + (2 * i + 1) * height / (2 * count);
                const row = shiftEvidence(before.row(y), after.row(y), start, end, from, stride);
                seen += 1 + (end - start - 1) / stride;
                same += row.same;
                changed += row.changed;
                explained += row.explained;
            }
            if (changed >= shift_min_pixels and percent_scale * explained >= sideways_explained_percent * changed and percent_scale * same >= sideways_agreement_percent * seen) return true;
        }
    }
    return false;
}

noinline fn shiftEvidence(old: []const values.Pixel, new: []const values.Pixel, start: usize, end: usize, from: usize, stride: usize) struct { changed: usize, explained: usize, same: usize } {
    const original = old[start..end];
    const shifted = old[from..][0..original.len];
    const current = new[start..end];
    var same: usize = 0;
    var changed: usize = 0;
    var explained: usize = 0;
    var i: usize = 0;
    while (i < current.len) : (i += stride) {
        const match = pixel.same(current[i], shifted[i]);
        const different = !pixel.same(current[i], original[i]);
        same += @intFromBool(match);
        changed += @intFromBool(different);
        explained += @intFromBool(different and match);
    }
    return .{ .changed = changed, .explained = explained, .same = same };
}

fn lessThan(_: void, a: Region, b: Region) bool {
    // Collected regions always contain a box. Defaults make this total for plain values.
    const empty: Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const p = a.before orelse a.after orelse empty;
    const q = b.before orelse b.after orelse empty;
    return p.y < q.y or (p.y == q.y and p.x < q.x);
}

fn pad(self: Box, size: Size, space: f64) Box {
    const x = @max(0, @floor(self.x - space));
    const y = @max(0, @floor(self.y - space));
    return .{
        .x = x,
        .y = y,
        .width = @min(@as(f64, @floatFromInt(size.width)), @ceil(self.right() + space)) - x,
        .height = @min(@as(f64, @floatFromInt(size.height)), @ceil(self.bottom() + space)) - y,
    };
}

fn unite(a: ?Box, b: ?Box) ?Box {
    const p = a orelse return b;
    const q = b orelse return a;
    const x = @min(p.x, q.x);
    const y = @min(p.y, q.y);
    return .{ .x = x, .y = y, .width = @max(p.right(), q.right()) - x, .height = @max(p.bottom(), q.bottom()) - y };
}

fn nearby(a: ?Box, b: ?Box, gap_px: f64) bool {
    const p = a orelse return false;
    const q = b orelse return false;
    return p.x <= q.right() + gap_px and q.x <= p.right() + gap_px and
        p.y <= q.bottom() + gap_px and q.y <= p.bottom() + gap_px;
}

fn widen(range: ?RowRange, more: RowRange) RowRange {
    const known = range orelse return more;
    return .{ .first = @min(known.first, more.first), .last = @max(known.last, more.last) };
}

fn translated(box: Box, top: ?usize) ?Box {
    var adjusted = box;
    adjusted.y += @floatFromInt(top orelse return null);
    return adjusted;
}

test "a gap between an insertion and a recolour separates their boxes" {
    var boxes: [4]Candidate = undefined;
    var collector: Collector = .{ .boxes = &boxes, .gap_px = @floatFromInt(merge_gap.count()), .max_gap_px = 100 };
    const insertion = Box.fromPixels(10, 10, 30, 10);
    const recolour = Box.fromPixels(12, 32, 26, 5);
    collector.add(.{ .after = insertion });
    collector.add(.{ .before = recolour, .after = recolour });
    collector.growGap();
    try std.testing.expectEqual(@as(usize, 2), collector.len);
}

test "a full pending buffer expands and accepts another distinct box" {
    var storage: [max_pending_regions]Candidate = undefined;
    var collector: Collector = .{ .boxes = &storage, .gap_px = @floatFromInt(merge_gap.count()), .max_gap_px = 65_536 };
    for (0..storage.len + 1) |i| collector.add(.{ .after = Box.fromPixels(i * 15, 0, 1, 1) });
    collector.growGap();
    try std.testing.expectEqual(@as(usize, 1), collector.len);
    try std.testing.expectEqual(@as(f64, 61_441), collector.boxes[0].region.after.?.width);
}

test "a serpentine larger than the seed stack is one component" {
    // Every other row is a full bar joined to the next at alternating ends,
    // so one fill queues many runs at once.
    const width = 9;
    const height = 9;
    var cells: [width * height]Cell = @splat(.clear);
    for (0..height) |y| {
        if (y % 2 == 0) {
            @memset(cells[y * width ..][0..width], .changed);
        } else for (0..width) |x| {
            if (x % 2 == 0) cells[y * width + x] = .changed;
        }
    }
    var storage: [4]Candidate = undefined;
    var collector: Collector = .{ .boxes = &storage, .gap_px = 0, .max_gap_px = width };
    var seeds: [2]u32 = undefined;
    try std.testing.expectEqual(GroupResult.kept, group(&collector, .{ .cells = &cells, .width = width }, &seeds, .{ .left = 3, .before_y = 5, .after_y = null }));
    try std.testing.expectEqual(@as(usize, 1), collector.len);
    try std.testing.expectEqual(@as(?Box, Box.fromPixels(3, 5, width, height)), collector.boxes[0].region.before);
    try std.testing.expectEqual(@as(?Box, null), collector.boxes[0].region.after);
    for (cells) |cell| try std.testing.expectEqual(Cell.clear, cell);
}

test "an image smaller than the noise minimum keeps single-pixel changes" {
    try std.testing.expectEqual(@as(usize, 1), minPixels(.{ .width = 1, .height = 1 }, .{ .width = 64, .height = 64 }));
    try std.testing.expectEqual(@as(usize, min_region_pixels), minPixels(.{ .width = 33, .height = 33 }, .{ .width = 33, .height = 33 }));
}

test "one-sided stacks join across a blank seam but keep painted rows separate" {
    const width = 55;
    const height = 52;
    const paper: values.Pixel = @splat(255);
    const ink: values.Pixel = .{ 80, 90, 140, 255 };
    var pixels: [width * height]values.Pixel = @splat(paper);
    for (4..12) |y| @memset(pixels[y * width + 4 ..][0..36], ink);
    for (29..44) |y| @memset(pixels[y * width + 6 ..][0..36], ink);
    const image: Image = .{ .width = width, .height = height, .pixels = &pixels };
    const parts = [_]Candidate{
        .{ .region = .{ .after = Box.fromPixels(4, 4, 36, 8) }, .pixels = 288 },
        .{ .region = .{ .after = Box.fromPixels(6, 29, 36, 15) }, .pixels = 540 },
    };
    var boxes = parts;
    try std.testing.expectEqual(@as(usize, 1), mergeLogical(&boxes, image, image, .one, &.{}));
    boxes = parts;
    pixels[20 * width + 20] = ink;
    try std.testing.expectEqual(@as(usize, 2), mergeLogical(&boxes, image, image, .one, &.{}));
}

test {
    std.testing.refAllDecls(@This());
}
