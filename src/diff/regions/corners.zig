//! Joins clipped and fully visible corners along continuous outlines.

const std = @import("std");
const pending = @import("candidate.zig");
const bounds = @import("bounds.zig");
const scrim = @import("scrim.zig");
const text_lines = @import("text_lines.zig");
const values = @import("../../value.zig");
const pixel = @import("../pixel.zig");
const Box = values.Box;
const Region = values.Region;
const Image = values.Image;

const RailDirection = struct { axis: bounds.RailAxis, exterior: bounds.RailEnd };

/// A complete rectangular outline has a mark at each of its corners.
const outline_corners = 4;

const corner_overlap = 0.75;

const corner_rail_contrast = 36;

const corner_join_rounding = 2;

const corner_join_reach_px = 4;

const max_corner_rail = values.CssPx.init(2048);

/// Groups stationary corner changes when the unchanged straight edges connect them.
pub noinline fn mergeCorners(boxes: []pending.Candidate, before: Image, after: Image, scale: values.Scale) usize {
    var len = boxes.len;
    const limit = scale.devicePixels(text_lines.line_height);
    const max_rail = scale.devicePixels(max_corner_rail);
    if (len == 2 and croppedCorners(boxes, before, after, limit, scale.devicePixels(pending.padding), max_rail)) return pending.join(boxes, len, 0, 1);
    var i: usize = 0;
    while (i + outline_corners <= len) : (i += 1) {
        const first = corner(boxes[i].region, limit) orelse continue;
        if (outlineCorners(boxes[i + 1 .. len], before, after, first, limit, max_rail)) |others| {
            // The indexes are relative to the suffix and sorted largest first.
            for (others) |j| len = pending.join(boxes, len, i, i + 1 + j);
        }
    }
    return len;
}

fn corner(region: Region, limit: f64) ?Box {
    const box = pending.stationaryBox(region) orelse return null;
    return if (@max(box.width, box.height) <= limit) box else null;
}

fn outlineCorners(boxes: []const pending.Candidate, before: Image, after: Image, top: Box, limit: f64, max_rail: f64) ?[3]usize {
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

fn croppedCorners(boxes: []const pending.Candidate, before: Image, after: Image, limit: f64, clip_slack: f64, max_rail: f64) bool {
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

    // Collector boxes use whole non-negative coordinates within the source image.
    const mid_x: usize = bounds.deviceIndex((top.right() + right.x) / 2);
    const mid_y: usize = bounds.deviceIndex((top.bottom() + bottom.y) / 2);
    const top_y: usize = bounds.deviceIndex(top.y);
    const top_end: usize = bounds.deviceIndex(top.bottom());
    const bottom_y: usize = bounds.deviceIndex(bottom.y);
    const bottom_end: usize = bounds.deviceIndex(bottom.bottom());
    const row = before.row(mid_y);
    const left_x: usize = bounds.deviceIndex(top.x);
    const left_end: usize = bounds.deviceIndex(top.right());
    const right_x: usize = bounds.deviceIndex(right.x);
    const right_end: usize = bounds.deviceIndex(right.right());
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
    const a = bounds.PixelRect.fromBox(start).oriented(direction.axis);
    const b = bounds.PixelRect.fromBox(end).oriented(direction.axis);
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
                scrim.toneDistance(ink, before.pixels[outside * across + x * along]) < corner_rail_contrast) break;
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

fn railTurns(image: Image, corner_box: Box, y: usize, ink: values.Pixel, side: enum { left, right }, exterior: bounds.RailEnd) bool {
    const left: usize = bounds.deviceIndex(corner_box.x);
    const right: usize = bounds.deviceIndex(corner_box.right());
    const outside = switch (side) {
        .left => if (left != 0) left - 1 else return false,
        .right => if (right < image.width) right else return false,
    };
    const interior_y: usize = bounds.deviceIndex(if (exterior == .start) corner_box.bottom() - 1 else corner_box.y);
    const leg_y = @min(y, interior_y) + (@max(y, interior_y) - @min(y, interior_y) + 1) / 2;
    if (leg_y == y) return false;
    const leg = image.row(leg_y);
    if (scrim.toneDistance(ink, leg[outside]) < corner_rail_contrast) return false;
    const start = if (side == .left) left else @max(left, right -| corner_join_reach_px);
    const end = if (side == .left) @min(right, left + corner_join_reach_px) else right;
    for (start..end) |x| {
        for (@min(y, leg_y)..@max(y, leg_y) + 1) |row| {
            if (scrim.toneDistance(image.row(row)[x], ink) > corner_join_rounding) break;
        } else return true;
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

test {
    std.testing.refAllDecls(@This());
}
