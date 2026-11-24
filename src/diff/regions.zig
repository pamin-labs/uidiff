//! Coalesces and orders change boxes from the comparison domain.
const std = @import("std");
const values = @import("../value.zig");
const Size = values.Size;
const Box = values.Box;
const Region = values.Region;

/// A pending region and the number of changed pixels supporting it.
pub const Candidate = struct { region: Region, pixels: usize };

/// Whether a band's mask contributed pixels and met the reporting minimum.
pub const GroupResult = enum { empty, sparse, kept };

/// Accumulates nearby boxes in caller-provided scratch space.
pub const Collector = struct {
    boxes: []Candidate,
    len: usize = 0,
    /// Current merging distance in device pixels.
    gap: f64,
    /// The gap at which every box on a side merges.
    max_gap: f64,
    /// Minimum changed pixels in a merged region, from minPixels.
    min_pixels: usize = min_region_pixels,
    expanding: bool = false,

    /// Returns scratch capacity for the two validated image sizes.
    pub fn capacity(before: Size, after: Size, gap: usize) usize {
        return @min(max_pending_regions, cells(before, gap) + cells(after, gap));
    }

    /// Keeps a region established by geometry rather than by the pixel mask.
    pub fn add(self: *Collector, region: Region) void {
        _ = self.addPixels(region, self.min_pixels);
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

    fn cells(size: Size, gap: usize) usize {
        // Two boxes on the same side cannot survive in the same grid cell.
        return (1 + (size.width - 1) / (gap + 1)) * (1 + (size.height - 1) / (gap + 1));
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
            const supported_gap = if (box.pixels < self.min_pixels or other.pixels < self.min_pixels) @min(self.gap, evidence_gap) else self.gap;
            const gap = if (!same_kind and !self.expanding) @min(supported_gap, self.gap / 2) else supported_gap;
            if (nearby(box.region.before, other.region.before, gap) or nearby(box.region.after, other.region.after, gap)) {
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
        self.gap = if (self.gap < 0.5) std.math.frexp(self.gap).significand else @min(self.gap * 2, self.max_gap);
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
/// Seeds the flood fill keeps at once (4 bytes each); more are found again by
/// rescanning their rows, so memory stays fixed however large the mask.
pub const max_fill_seeds = 64 * 1024;
/// The component minimum, reduced to one for captures within single_pixel_area.
pub fn minPixels(before: Size, after: Size) usize {
    const smallest = @min(before.width * before.height, after.width * after.height);
    return if (smallest <= single_pixel_area) 1 else min_region_pixels;
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

fn nearby(a: ?Box, b: ?Box, gap: f64) bool {
    const p = a orelse return false;
    const q = b orelse return false;
    return p.x <= q.right() + gap and q.x <= p.right() + gap and
        p.y <= q.bottom() + gap and q.y <= p.bottom() + gap;
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
    var collector: Collector = .{ .boxes = &boxes, .gap = @floatFromInt(merge_gap.count()), .max_gap = 100 };
    const insertion = Box.fromPixels(10, 10, 30, 10);
    const recolour = Box.fromPixels(12, 32, 26, 5);
    collector.add(.{ .after = insertion });
    collector.add(.{ .before = recolour, .after = recolour });
    collector.growGap();
    try std.testing.expectEqual(@as(usize, 2), collector.len);
}

test "a full pending buffer expands and accepts another distinct box" {
    var storage: [max_pending_regions]Candidate = undefined;
    var collector: Collector = .{ .boxes = &storage, .gap = @floatFromInt(merge_gap.count()), .max_gap = 65_536 };
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
    var collector: Collector = .{ .boxes = &storage, .gap = 0, .max_gap = width };
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

test {
    std.testing.refAllDecls(@This());
}
