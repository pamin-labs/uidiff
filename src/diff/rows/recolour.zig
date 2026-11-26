//! Recognizes positional paint edits among repeated rows.

const std = @import("std");
const band = @import("band.zig");
const value = @import("../../value.zig");
const pixel = @import("../pixel.zig");
const columns = @import("../columns.zig");
const Image = value.Image;

// Narrow paint can extend beyond the length of a normal row replacement.
const narrow_paint_rows = 128;

// A row cluster can contain two separate overpaints with overlapping heights.
const paint_cluster_rows = 2 * narrow_paint_rows;

/// Required changed-row proportion numerator.
// Require three quarters changed rows for one continuous overpaint.
pub const paint_density_numerator = 3;

/// Required changed-row proportion denominator.
pub const paint_density_denominator = 4;

// Separate local edits need an exact stationary run between their rows.
const paint_anchor_rows = 8;

const narrow_paint_width_divisor = 2;

// Repeated badges can match another row without moving its surrounding layout.
const repeated_badge_width_divisor = 4;

const repeated_badge_height_divisor = 2;

/// Keeps separate positional paint edits between stationary rows.
pub fn positionalPaintBands(before: band.Keys, after: band.Keys, first: usize, limits: band.Limits, bands: []band.Band) ?[]band.Band {
    const images = limits.images orelse return null;
    const max_rows = @max(paint_cluster_rows, limits.replacement);
    const bounds: columns.Span = .{ .left = limits.left, .width = limits.width };
    const max_width = @min(images[0].width, images[1].width) / narrow_paint_width_divisor;
    var len: usize = 0;
    var start = first;
    var interrupted_ink = false;
    while (start < before.len) {
        var end = start + 1;
        var stable: usize = 0;
        while (end < before.len and stable < paint_anchor_rows) : (end += 1) {
            stable = if (before[end] == after[end]) stable + 1 else 0;
            if (end - stable - start >= max_rows) return null;
        }
        const bottom = end - stable;
        if (bottom == before.len) return null;
        const span = columns.spanRows(images[0], images[1], bounds, start, bottom);
        if (span.width == 0 or span.width > max_width) return null;
        const old_flat = flatPaint(images[0], start, bottom, span.left, span.width);
        const new_flat = flatPaint(images[1], start, bottom, span.left, span.width);
        // Two distant overpaints can overlap vertically. In that case the
        // bounding rectangle includes paint and untouched space between them.
        if (!old_flat and !new_flat and !flatChanges(images, span, start, bottom) and
            (span.width > @min(images[0].width, images[1].width) / repeated_badge_width_divisor or bottom - start > limits.replacement / repeated_badge_height_divisor or
                !stationaryContour(images, span, start, bottom))) return null;
        interrupted_ink = interrupted_ink or !(old_flat and new_flat);
        band.append(bands, &len, .{ .before = start, .after = start, .removed = bottom - start, .added = bottom - start });
        start = end + (std.mem.indexOfDiff(u64, before[end..], after[end..]) orelse break);
    }
    return if (len > 1 and interrupted_ink) bands[0..len] else null;
}

/// Estimates the edit cost of a small positional replacement.
pub fn localEditCost(before: band.Keys, after: band.Keys, first: usize, limits: band.Limits) ?struct { cost: usize, end: usize, limit: usize } {
    if (first == 0) return null;
    const limit = if (limits.narrow_edit) @max(narrow_paint_rows, limits.replacement) else limits.replacement;
    const end = band.changedEnd(before, after, first, before.len);
    if (end == before.len or end - first > limit) return null;
    var replaced: usize = 0;
    for (before[first..end], after[first..end]) |old, new| replaced += @intFromBool(old != new);
    // Separated edits are weaker evidence for one overpaint. In particular,
    // a short insertion can move a distant line while leaving the rows in
    // between equal at their original positions.
    if (paint_density_denominator * replaced < paint_density_numerator * (end - first)) return null;
    if (!limits.narrow_edit) {
        const images = limits.images orelse return null;
        if (!flatPaint(images[0], first, end, limits.left, limits.width) and !flatPaint(images[1], first, end, limits.left, limits.width)) return null;
    }
    return .{ .cost = 2 * replaced, .end = end, .limit = limit };
}

/// Reports whether the strip in every row is uniformly painted.
pub fn flatPaint(image: Image, first: usize, end: usize, left: usize, width: usize) bool {
    const first_row = image.rowBytes(first, left, width);
    const pixel_bytes = @sizeOf(value.Pixel);
    if (!std.mem.eql(u8, first_row[pixel_bytes..], first_row[0 .. first_row.len - pixel_bytes])) return false;
    for (first + 1..end) |y| {
        if (!std.mem.eql(u8, image.rowBytes(y, left, width), first_row)) return false;
    }
    return true;
}

fn stationaryContour(images: [2]Image, span: columns.Span, top: usize, bottom: usize) bool {
    const right = span.left + span.width;
    if (span.left == 0 or right >= @min(images[0].width, images[1].width)) return false;
    for (top..bottom) |y| {
        const old = images[0].row(y);
        const new = images[1].row(y);
        const backdrop = old[span.left - 1];
        if (!pixel.same(backdrop, old[right]) or !pixel.same(backdrop, new[span.left - 1]) or
            !pixel.same(backdrop, new[right])) return false;
        for (old[span.left..right], new[span.left..right]) |before, after| {
            if (pixel.same(before, backdrop) != pixel.same(after, backdrop)) return false;
        }
    }
    return true;
}

fn flatChanges(images: [2]Image, span: columns.Span, top: usize, bottom: usize) bool {
    var colors: ?[2]value.Pixel = null;
    var old_flat = true;
    var new_flat = true;
    for (top..bottom) |y| {
        const before = images[0].rowSegment(y, span.left, span.width);
        const after = images[1].rowSegment(y, span.left, span.width);
        for (before, after) |old, new| {
            if (std.meta.eql(old, new)) continue;
            if (colors == null) colors = .{ old, new };
            old_flat = old_flat and std.meta.eql(old, colors.?[0]);
            new_flat = new_flat and std.meta.eql(new, colors.?[1]);
            if (!old_flat and !new_flat) return false;
        }
    }
    return colors != null;
}

test {
    std.testing.refAllDecls(@This());
}
