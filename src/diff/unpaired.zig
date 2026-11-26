//! Compares rows aligned to a gap and suppresses unchanged background.
const std = @import("std");
const value = @import("../value.zig");
const mask = @import("mask.zig");
const columns = @import("columns.zig");
const pixel = @import("pixel.zig");
const regions = @import("regions.zig");
const yiq = @import("yiq.zig");
const Box = value.Box;
const Collector = regions.Collector;
const Image = value.Image;
const Pixel = value.Pixel;
const Raster = yiq.Raster;
const Scope = columns.Scope;

/// Rows one side has and the other does not.
pub const Rows = struct { side: value.Side, y: usize, count: usize, background: ?[]const Pixel = null, element: bool = false, opposite: ?usize = null };

const min_bar_rows = 2;

/// Collects changes for rows aligned to a gap.
pub fn collect(collector: *Collector, scope: Scope, scratch: mask.Scratch, rows: Rows) void {
    if (rows.count == 0) return;
    const source = scope.pair.get(rows.side);
    const left = scope.span.left;
    const width = scope.span.width;
    const y = rows.y;
    if (rows.element and rows.background == null) {
        if (columns.enclosingCard(source, scope.span, scope.frame orelse scope.bounds, y, columns.CardSearch.motion(scope.span, rows.count))) |card| {
            const box = Box.fromPixels(card.columns.left, card.top, card.columns.width, card.height);
            collector.addOn(rows.side, box);
            return;
        }
    }
    const a: Raster = .{ .image = source, .left = left, .top = y, .width = width, .height = rows.count };
    var b = a;
    b.background = .margin;
    if (rows.background) |background| {
        // The repeated row may come from a narrower image. Limit only the
        // virtual backdrop's extent, keeping its neighbour loads in bounds.
        b.image.width = @min(source.width, background.len);
        b.image.pixels = source.pixels[0 .. b.image.width * source.height];
        b.background = .{ .row = background };
    } else if (y > 0 and y + rows.count < source.height) {
        const above = source.rowSegment(y - 1, left, width);
        const below = source.rowSegment(y + rows.count, left, width);
        const last = source.rowSegment(y + rows.count - 1, left, width);
        if (pixel.sameRun(above, below) or
            (rows.element and pixel.sameRun(above, last)))
        {
            b.background = .{ .row = source.row(y - 1) };
        }
    }
    const mask_cells = scratch.cells[0 .. width * rows.count];
    const at: regions.Placement = .{
        .left = left,
        .rows = if (rows.side == .before) .{ .before = y } else .{ .after = y },
    };
    if (yiq.writeMask(a, b, 0, rows.count, mask_cells)) {
        const cells: mask.Mask = .{ .cells = mask_cells, .width = width };
        if (rows.element) {
            if (regions.groupElement(collector, cells, at)) return;
        } else if (regions.group(collector, cells, scratch.seeds, at) != .empty) return;
    }
    if (rows.background != null) return;
    const blank = columns.blankBand(source, y, rows.count, scope.bounds);
    // An empty band that changes layout spans its column.
    const bounds = if (blank) scope.bounds else scope.span;
    if (rows.side == .before) if (rows.opposite) |opposite| {
        // Unchanged columns outside the reported span can contain unrelated
        // paint. Test the same columns that the fallback would report.
        if ((blank or (bounds.width != scope.bounds.width and columns.blankBand(source, y, rows.count, bounds))) and
            unchangedBlank(scope, bounds, y, opposite, rows.count)) return;
    };
    const box = Box.fromPixels(bounds.left, y, bounds.width, rows.count);
    collector.addOn(rows.side, box);
}

/// A resized edit can leave an unpaired tail against an unchanged background.
/// Verify the paint across both images before reusing it, including any vertical border.
pub fn sharedBackdrop(scope: Scope, old_y: usize, new_y: usize) ?[]const Pixel {
    if (old_y >= scope.pair.before.height or new_y >= scope.pair.after.height) return null;
    const span = scope.span;
    const new = rowRun(scope.pair.after, new_y, span);
    // The ordinary gap comparison already handles flat paint. Reuse a row
    // across the edit when both sides of the span show the same card edge.
    const edge = new[0];
    const fill = new[new.len / 2];
    if (pixel.same(edge, fill) or !pixel.same(edge, new[new.len - 1])) return null;
    var border: usize = 1;
    while (pixel.same(edge, new[border])) : (border += 1) {}
    for (new[new.len - border ..]) |p| if (!pixel.same(p, edge)) return null;
    for (new[border .. new.len - border]) |p| if (!pixel.same(p, fill)) return null;
    if (!pixel.sameRun(rowRun(scope.pair.before, old_y, span), new)) return null;
    return scope.pair.after.row(new_y);
}

fn unchangedBlank(scope: Scope, bounds: columns.Span, y: usize, opposite: usize, rows: usize) bool {
    if (opposite >= scope.pair.after.height) return true;
    const expected = rowRun(scope.pair.before, y, bounds);
    var end = y + rows;
    while (end < scope.pair.before.height and pixel.sameRun(rowRun(scope.pair.before, end, bounds), expected)) end += 1;
    if (end == scope.pair.before.height) return hasEqualRun(expected, scope.pair.after, bounds, y, opposite, rows);
    if (end == y + rows and fixedLowerEdge(scope, bounds, expected, y, end)) return true;

    var first = y;
    while (first > 0 and pixel.sameRun(rowRun(scope.pair.before, first - 1, bounds), expected)) first -= 1;
    return interiorBlank(scope.pair.after, bounds, expected, first, end, opposite -| (y - first)) or
        fixedUpperBar(scope, bounds, expected, first);
}

fn fixedLowerEdge(scope: Scope, bounds: columns.Span, paint: []const Pixel, y: usize, end: usize) bool {
    return end < scope.pair.after.height and
        pixel.sameRun(rowRun(scope.pair.before, end, bounds), rowRun(scope.pair.after, end, bounds)) and
        hasEqualRun(paint, scope.pair.after, bounds, y, y, end - y);
}

fn interiorBlank(after: Image, bounds: columns.Span, paint: []const Pixel, first: usize, end: usize, opposite: usize) bool {
    // Matching only the unpaired portion could hide space actually removed
    // between two lines of content. Match the whole interior run.
    return hasEqualRun(paint, after, bounds, first, opposite, end - first);
}

fn fixedUpperBar(scope: Scope, bounds: columns.Span, paint: []const Pixel, first: usize) bool {
    if (first < min_bar_rows or first >= scope.pair.after.height or
        !pixel.sameRun(paint, rowRun(scope.pair.after, first, bounds)) or
        !columns.blankBand(scope.pair.before, first - min_bar_rows, min_bar_rows, bounds)) return false;
    // A viewport bar reaches the top. Check its paint at both margins so
    // icons and lettering can interrupt the interior of the bar.
    const left = bounds.left;
    const right = left + bounds.width - 1;
    const bar = scope.pair.before.row(first - 1)[left];
    for (0..first) |y| {
        const a = scope.pair.before.row(y);
        const z = scope.pair.after.row(y);
        if (!pixel.same(a[left], bar) or !pixel.same(a[right], bar) or
            !pixel.same(z[left], bar) or !pixel.same(z[right], bar)) return false;
    }
    return true;
}

fn rowRun(image: Image, y: usize, bounds: columns.Span) []const Pixel {
    return image.rowSegment(y, bounds.left, bounds.width);
}

fn hasEqualRun(expected: []const Pixel, image: Image, bounds: columns.Span, y: usize, opposite: usize, needed: usize) bool {
    const start = @min(y, opposite);
    const end = @min(image.height, @max(y, opposite) + needed);
    var run: usize = 0;
    for (start..end) |row| {
        const paint = rowRun(image, row, bounds);
        run = if (pixel.sameRun(expected, paint)) run + 1 else 0;
        if (run == needed) return true;
    }
    return false;
}

test "an interior blank run is ignored only if the layout retains its length" {
    const canvas = @import("uidiff_test_canvas").Painters(value.Image);
    const before = try canvas.Canvas.init(64, 80);
    defer before.deinit();
    const after = try canvas.Canvas.init(64, 80);
    defer after.deinit();
    const ink = canvas.inkShade(32, 4);
    before.fill(10, 15, 24, 5, ink);
    before.fill(10, 32, 30, 5, ink);
    after.fill(10, 20, 24, 5, ink);
    after.fill(10, 37, 30, 5, ink);
    const span: columns.Span = .{ .left = 0, .width = 64 };
    const scope: Scope = .{ .pair = .{ .before = before.view, .after = after.view }, .span = span, .bounds = span };
    try std.testing.expect(unchangedBlank(scope, span, 20, 25, 8));
    after.fill(10, 31, 30, 6, ink);
    try std.testing.expect(!unchangedBlank(scope, span, 20, 25, 8));
}

test "blank space above a fixed input bar does not inherit unrelated sidebar paint" {
    const canvas = @import("uidiff_test_canvas").Painters(value.Image);
    const before = try canvas.Canvas.init(144, 180);
    defer before.deinit();
    const after = try canvas.Canvas.init(144, 180);
    defer after.deinit();
    before.fill(28, 60, 90, 10, canvas.inkShade(32, 4));
    after.fill(28, 80, 90, 10, canvas.inkShade(32, 4));
    for ([_]canvas.Canvas{ before, after }) |image| {
        image.fill(0, 30, 18, 130, canvas.inkShade(96, 4));
        image.fill(20, 130, 110, 20, canvas.inkShade(190, 4));
        image.line(30, 112, 135, 0, 32);
    }
    const scope: Scope = .{ .pair = .{ .before = before.view, .after = after.view }, .span = .{ .left = 24, .width = 96 }, .bounds = .{ .left = 0, .width = 144 } };
    var boxes: [2]regions.Candidate = undefined;
    var collector: Collector = .{ .boxes = &boxes, .gap_px = 0, .max_gap_px = 144 };
    var mask_cells: [96 * 20]mask.Cell = undefined;
    var seeds: [20]u32 = undefined;
    collect(&collector, scope, .{ .cells = &mask_cells, .seeds = &seeds }, .{ .side = .before, .y = 110, .count = 20, .opposite = 130 });
    try std.testing.expectEqual(@as(usize, 0), collector.len);
}

test "an equal unpaired bottom margin does not produce a removal" {
    const canvas = @import("uidiff_test_canvas").Painters(value.Image);
    for ([_]Pixel{ @splat(255), .{ 18, 18, 22, 255 } }) |color| {
        const before = try canvas.Canvas.init(64, 40);
        defer before.deinit();
        const after = try canvas.Canvas.init(64, 50);
        defer after.deinit();
        @memset(before.pixels, color);
        @memset(after.pixels, .{ 96, 67, 77, 255 });
        after.fill(0, 36, 64, 6, color);
        const scope: Scope = .{
            .pair = .{ .before = before.view, .after = after.view },
            .span = .{ .left = 0, .width = 64 },
            .bounds = .{ .left = 0, .width = 64 },
        };
        var boxes: [2]regions.Candidate = undefined;
        var collector: Collector = .{ .boxes = &boxes, .gap_px = 0, .max_gap_px = 64 };
        var mask_cells: [64 * 6]mask.Cell = undefined;
        var seeds: [6]u32 = undefined;
        const margin: Rows = .{ .side = .before, .y = 34, .count = 6, .opposite = 44 };
        collect(&collector, scope, .{ .cells = &mask_cells, .seeds = &seeds }, margin);
        try std.testing.expectEqual(@as(usize, 0), collector.len);
        @memset(after.pixels, .{ 96, 67, 77, 255 });
        collect(&collector, scope, .{ .cells = &mask_cells, .seeds = &seeds }, margin);
        try std.testing.expectEqual(@as(usize, 1), collector.len);
    }
}

test {
    std.testing.refAllDecls(@This());
}
