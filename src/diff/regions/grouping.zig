//! Collects and merges connected components from a pixel mask.

const std = @import("std");
const change_mask = @import("../mask.zig");
const Cell = change_mask.Cell;
const Mask = change_mask.Mask;
const pending = @import("candidate.zig");
const values = @import("../../value.zig");
const Size = values.Size;
const Box = values.Box;
const Region = values.Region;

/// Whether a band's mask contributed pixels and met the reporting minimum.
pub const GroupResult = enum { empty, sparse, kept };

/// Accumulates nearby boxes in caller-provided scratch space.
pub const Collector = struct {
    boxes: []pending.Candidate,
    len: usize = 0,
    /// Current merging distance in device pixels.
    gap_px: f64,
    /// The gap at which every box on a side merges.
    max_gap_px: f64,
    /// Minimum changed pixels in a merged region, from minPixels.
    min_pixels: usize = min_region_pixels,
    expanding: bool = false,

    /// Initializes collection over caller-owned storage and validated image dimensions.
    pub fn init(storage: []pending.Candidate, before: Size, after: Size, gap_px: f64, max_gap_px: f64) Collector {
        return .{ .boxes = storage, .gap_px = gap_px, .max_gap_px = max_gap_px, .min_pixels = minPixels(before, after) };
    }

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

    /// Returns the maximum row replacement span allowed by the current gap.
    pub fn localLimit(self: Collector) usize {
        return @intFromFloat(@min(self.max_gap_px, 2 * self.gap_px));
    }

    /// Reports whether changed pixels meet the collection threshold.
    pub fn supports(self: Collector, count: usize) bool {
        return count >= self.min_pixels;
    }

    /// Compacts the candidates and lends their storage to the resolution pass.
    pub fn retain(self: *Collector) struct { buffer: []pending.Candidate, count: usize } {
        self.growGap();
        return .{ .buffer = self.boxes, .count = self.len };
    }

    /// Merges nearby evidence, discards noise, and bounds the output count.
    fn growGap(self: *Collector) void {
        self.discardSparse();
        while (self.len > pending.max_regions) self.expand();
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

    fn absorb(self: *Collector, candidate: pending.Candidate) pending.Candidate {
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
                box.region.before = pending.unite(box.region.before, other.region.before);
                box.region.after = pending.unite(box.region.after, other.region.after);
                box.pixels = @min(self.min_pixels, box.pixels + other.pixels);
                self.len -= 1;
                std.mem.copyForwards(pending.Candidate, self.boxes[i..self.len], self.boxes[i + 1 .. self.len + 1]);
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

/// Where a band's mask sits in device pixels: its first column, and its first
/// row on each side that shows it.
pub const Placement = struct {
    left: usize,
    rows: union(enum) { paired: struct { before: usize, after: usize }, before: usize, after: usize },

    fn stationary(self: Placement) bool {
        return switch (self.rows) {
            .paired => |rows| rows.before == rows.after,
            else => false,
        };
    }

    fn place(self: Placement, box: Box) Region {
        return switch (self.rows) {
            .paired => |rows| .{ .before = translated(box, rows.before), .after = translated(box, rows.after) },
            .before => |y| .{ .before = translated(box, y) },
            .after => |y| .{ .after = translated(box, y) },
        };
    }
};

/// Inclusive endpoints of a row or column span in the fill.
const InclusiveSpan = struct { first: usize, last: usize };

/// A scanline flood fill whose seed stack is bounded. Queued pixels are
/// marked in the mask, so a seed that does not fit is found again by
/// rescanning the rows it was dropped from.
const Fill = struct {
    mask: Mask,
    seeds: []u32,
    len: usize = 0,
    /// Rows holding queued pixels that did not fit in seeds.
    pending: ?InclusiveSpan = null,

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
    fn run(self: *Fill, index: usize) ?InclusiveSpan {
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

const evidence_gap = 1;

// Bound the initial list and its quadratic merge work on highly fragmented images.
const max_pending_regions = 4096;

/// Seeds the flood fill keeps at once (4 bytes each); more are found again by
/// rescanning their rows, so memory stays fixed however large the mask.
pub const max_fill_seeds = 64 * 1024;

/// Adds eight-connected components to the collector. Sparse components can
/// reach the reporting minimum together. Asserts seeds is not empty.
pub fn group(collector: *Collector, mask: Mask, seeds: []u32, at: Placement) GroupResult {
    std.debug.assert(seeds.len > 0);
    if (at.stationary()) discardUnsupported(mask, collector.min_pixels);
    var result: GroupResult = .empty;
    var fill: Fill = .{ .mask = mask, .seeds = seeds };
    var next: usize = 0;
    // Between fills a cell is zero or changed, never queued.
    while (change_mask.nextCell(mask.cells, next, .changed)) |start| {
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
        if (collector.addPixels(at.place(box), count)) {
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
        const first = change_mask.nextCell(row, 0, .changed) orelse continue;
        const last = std.mem.lastIndexOfScalar(u8, std.mem.sliceAsBytes(row[first..]), @backingInt(Cell.changed)) orelse 0;
        left = @min(left, first);
        right = @max(right, first + last + 1);
        top = @min(top, y);
        bottom = y + 1;
        if (count < collector.min_pixels) count += std.mem.count(u8, std.mem.sliceAsBytes(row[first..][0 .. last + 1]), &.{@backingInt(Cell.changed)});
    }
    if (count < collector.min_pixels) return false;
    const box = Box.fromPixels(at.left + left, top, right - left, bottom - top);
    collector.add(at.place(box));
    return true;
}

// Faint specks and weak edges cannot gain evidence just by touching
// diagonally. Keep the original cardinal support before joining corners.
// The component minimum is one for small captures.
fn minPixels(before: Size, after: Size) usize {
    const smallest = @min(before.width * before.height, after.width * after.height);
    return if (smallest <= single_pixel_area) 1 else min_region_pixels;
}

fn discardUnsupported(mask: Mask, minimum: usize) void {
    var start: usize = 0;
    while (change_mask.nextCell(mask.cells, start, .needs_support)) |index| {
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

fn nearby(a: ?Box, b: ?Box, gap_px: f64) bool {
    const p = a orelse return false;
    const q = b orelse return false;
    return p.x <= q.right() + gap_px and q.x <= p.right() + gap_px and
        p.y <= q.bottom() + gap_px and q.y <= p.bottom() + gap_px;
}

fn widen(range: ?InclusiveSpan, more: InclusiveSpan) InclusiveSpan {
    const known = range orelse return more;
    return .{ .first = @min(known.first, more.first), .last = @max(known.last, more.last) };
}

fn translated(box: Box, top: usize) Box {
    var adjusted = box;
    adjusted.y += @floatFromInt(top);
    return adjusted;
}

test "a gap between an insertion and a recolour separates their boxes" {
    var boxes: [4]pending.Candidate = undefined;
    var collector: Collector = .{ .boxes = &boxes, .gap_px = @floatFromInt(pending.merge_gap.count()), .max_gap_px = 100 };
    const insertion = Box.fromPixels(10, 10, 30, 10);
    const recolour = Box.fromPixels(12, 32, 26, 5);
    collector.add(.{ .after = insertion });
    collector.add(.{ .before = recolour, .after = recolour });
    collector.growGap();
    try std.testing.expectEqual(@as(usize, 2), collector.len);
}

test "a full pending buffer expands and accepts another distinct box" {
    var storage: [max_pending_regions]pending.Candidate = undefined;
    var collector: Collector = .{ .boxes = &storage, .gap_px = @floatFromInt(pending.merge_gap.count()), .max_gap_px = 65_536 };
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
    var storage: [4]pending.Candidate = undefined;
    var collector: Collector = .{ .boxes = &storage, .gap_px = 0, .max_gap_px = width };
    var seeds: [2]u32 = undefined;
    try std.testing.expectEqual(GroupResult.kept, group(&collector, .{ .cells = &cells, .width = width }, &seeds, .{ .left = 3, .rows = .{ .before = 5 } }));
    try std.testing.expectEqual(@as(usize, 1), collector.len);
    try std.testing.expectEqual(@as(?Box, Box.fromPixels(3, 5, width, height)), collector.boxes[0].region.before);
    try std.testing.expectEqual(@as(?Box, null), collector.boxes[0].region.after);
    for (cells) |cell| try std.testing.expectEqual(Cell.clear, cell);
}

test "band placement translates only the sides present in the mask" {
    const box = Box.fromPixels(4, 2, 5, 3);
    const cases = [_]struct { placement: Placement, before: ?Box, after: ?Box }{
        .{ .placement = .{ .left = 0, .rows = .{ .before = 7 } }, .before = Box.fromPixels(4, 9, 5, 3), .after = null },
        .{ .placement = .{ .left = 0, .rows = .{ .after = 9 } }, .before = null, .after = Box.fromPixels(4, 11, 5, 3) },
        .{ .placement = .{ .left = 0, .rows = .{ .paired = .{ .before = 7, .after = 9 } } }, .before = Box.fromPixels(4, 9, 5, 3), .after = Box.fromPixels(4, 11, 5, 3) },
    };
    for (cases) |item| {
        const region = item.placement.place(box);
        try std.testing.expectEqual(item.before, region.before);
        try std.testing.expectEqual(item.after, region.after);
    }
}

test "an image smaller than the noise minimum keeps single-pixel changes" {
    try std.testing.expectEqual(@as(usize, 1), minPixels(.{ .width = 1, .height = 1 }, .{ .width = 64, .height = 64 }));
    try std.testing.expectEqual(@as(usize, min_region_pixels), minPixels(.{ .width = 33, .height = 33 }, .{ .width = 33, .height = 33 }));
}

test {
    std.testing.refAllDecls(@This());
}
