//! Joins clipped and fully visible corners along continuous outlines.

const std = @import("std");
const candidate = @import("candidate.zig");
const bounds = @import("bounds.zig");
const scrim = @import("scrim.zig");
const text_lines = @import("text_lines.zig");
const value = @import("../../value.zig");
const pixel = @import("../pixel.zig");
const Scale = value.Scale;
const Box = value.Box;
const Region = value.Region;
const Image = value.Image;

const RailDirection = struct { axis: bounds.RailAxis, exterior: bounds.RailEnd };

/// A complete rectangular outline has a mark at each of its corners.
const outline_corners = 4;

const corner_overlap = 0.75;

const corner_rail_contrast = 36;

const corner_join_rounding = 2;

const corner_join_reach_px = 4;

const max_corner_rail = value.CssPx.init(2048);

/// Groups stationary corner changes when the unchanged straight edges connect them.
pub noinline fn mergeCorners(boxes: []candidate.Candidate, before: Image, after: Image, scale: value.Scale) usize {
    var len = boxes.len;
    const limit = scale.devicePixels(text_lines.line_height);
    const max_rail = scale.devicePixels(max_corner_rail);
    if (len == 2 and croppedCorners(boxes, before, after, limit, scale.devicePixels(candidate.padding), max_rail)) return candidate.join(boxes, len, 0, 1);
    var i: usize = 0;
    while (i + outline_corners <= len) : (i += 1) {
        const first = corner(boxes[i].region, limit) orelse continue;
        if (outlineCorners(boxes[i + 1 .. len], before, after, first, limit, max_rail)) |others| {
            // The indexes are relative to the suffix and sorted largest first.
            for (others) |j| len = candidate.join(boxes, len, i, i + 1 + j);
        }
    }
    return len;
}

fn corner(region: Region, limit: f64) ?Box {
    const box = candidate.stationaryBox(region) orelse return null;
    return if (@max(box.width, box.height) <= limit) box else null;
}

fn outlineCorners(boxes: []const candidate.Candidate, before: Image, after: Image, top: Box, limit: f64, max_rail: f64) ?[3]usize {
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

fn croppedCorners(boxes: []const candidate.Candidate, before: Image, after: Image, limit: f64, clip_slack: f64, max_rail: f64) bool {
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

fn railTurns(image: Image, corner_box: Box, y: usize, ink: value.Pixel, side: enum { left, right }, exterior: bounds.RailEnd) bool {
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

fn hasInk(row: []const value.Pixel, ink: value.Pixel) bool {
    for (row) |p| if (pixel.same(p, ink)) return true;
    return false;
}

test "four corners follow a continuous outline even when its straight edges differ in color" {
    const canvas = @import("uidiff_test_canvas").Painters(value.Image);
    const before = try canvas.Canvas.init(250, 150);
    defer before.deinit();
    const after = try canvas.Canvas.init(250, 150);
    defer after.deinit();
    const boxes = [_]Box{
        Box.fromPixels(32, 26, 14, 14),
        Box.fromPixels(202, 26, 14, 14),
        Box.fromPixels(32, 116, 14, 14),
        Box.fromPixels(202, 116, 14, 14),
    };
    var edits: [boxes.len]candidate.Candidate = undefined;
    for ([_]canvas.Canvas{ before, after }) |image| {
        image.fill(32, 28, 184, 3, .{ 60, 90, 150, 255 });
        image.fill(32, 124, 184, 3, .{ 120, 90, 62, 255 });
        for ([_]usize{ 32, 214 }) |x| {
            image.fill(x, 28, 2, 12, .{ 60, 90, 150, 255 });
            image.fill(x, 116, 2, 11, .{ 120, 90, 62, 255 });
        }
        image.fill(35, 40, 4, 76, canvas.inkShade(75, 4));
        image.fill(210, 40, 4, 76, canvas.inkShade(75, 4));
    }
    for (boxes, &edits) |box, *edit| {
        const x: usize = @intFromFloat(box.x);
        const y: usize = @intFromFloat(box.y);
        before.fill(x + 2, y + 3, 8, 6, canvas.inkShade(80, 4));
        after.fill(x + 3, y + 4, 6, 4, canvas.inkShade(80, 4));
        edit.* = .{ .region = .{ .before = box, .after = box }, .pixels = 8 };
    }
    var candidates = edits;
    try std.testing.expectEqual(@as(usize, 1), mergeCorners(&candidates, before.view, after.view, .one));
    for ([_]canvas.Canvas{ before, after }) |image| image.fill(104, 20, 16, 115, canvas.inkShade(255, 4));
    candidates = edits;
    try std.testing.expectEqual(edits.len, mergeCorners(&candidates, before.view, after.view, .one));
    try std.testing.expectEqualDeep(edits, candidates);
}

test "viewport clipped corners join only across a continuous straight edge" {
    const canvas = @import("uidiff_test_canvas").Painters(value.Image);
    const before = try canvas.Canvas.init(250, 64);
    defer before.deinit();
    const after = try canvas.Canvas.init(250, 64);
    defer after.deinit();
    const a = Box.fromPixels(32, 45, 14, 19);
    const b = Box.fromPixels(202, 45, 14, 19);
    const edits = [_]candidate.Candidate{
        .{ .region = .{ .before = a, .after = a }, .pixels = 8 },
        .{ .region = .{ .before = b, .after = b }, .pixels = 8 },
    };
    for ([_]canvas.Canvas{ before, after }, [_]usize{ 8, 4 }) |image, shape| {
        image.fill(32, 48, 184, 5, canvas.inkShade(88, 4));
        image.fill(32, 48, 2, 12, canvas.inkShade(88, 4));
        image.fill(214, 48, 2, 12, canvas.inkShade(88, 4));
        image.fill(34, 55, shape, 9, canvas.inkShade(68, 4));
        image.fill(205, 55, shape, 9, canvas.inkShade(68, 4));
    }
    var candidates = edits;
    try std.testing.expectEqual(@as(usize, 1), mergeCorners(&candidates, before.view, after.view, .one));
    for ([_]canvas.Canvas{ before, after }) |image| image.fill(116, 44, 18, 20, canvas.inkShade(255, 4));
    candidates = edits;
    try std.testing.expectEqual(edits.len, mergeCorners(&candidates, before.view, after.view, .one));
    try std.testing.expectEqualDeep(edits, candidates);
}

test "audit: unrelated bottom-clipped labels on one footer stay separate" {
    const canvas = @import("uidiff_test_canvas").Painters(value.Image);
    const before = try canvas.Canvas.init(280, 90);
    defer before.deinit();
    const after = try canvas.Canvas.init(280, 90);
    defer after.deinit();
    for ([_]canvas.Canvas{ before, after }, [_]usize{ 3, 4 }) |image, seed| {
        image.fill(0, 73, 280, 17, .{ 37, 40, 49, 255 });
        image.line(24, 70, 80, seed, 190);
        image.line(204, 250, 80, seed + 6, 190);
    }
    const a = Box.fromPixels(24, 73, 46, 17);
    const b = Box.fromPixels(204, 73, 46, 17);
    const edits = [_]candidate.Candidate{
        .{ .region = .{ .before = a, .after = a }, .pixels = 8 },
        .{ .region = .{ .before = b, .after = b }, .pixels = 8 },
    };
    var candidates = edits;
    try std.testing.expectEqual(edits.len, mergeCorners(&candidates, before.view, after.view, .one));
    try std.testing.expectEqualDeep(edits, candidates);
}

test "round 25 audit: glyph stems below a divider do not close the corners" {
    const canvas = @import("uidiff_test_canvas").Painters(value.Image);
    const before = try canvas.Canvas.init(280, 90);
    defer before.deinit();
    const after = try canvas.Canvas.init(280, 90);
    defer after.deinit();
    const ink: value.Pixel = .{ 51, 51, 51, 255 };
    for ([_]canvas.Canvas{ before, after }) |image| {
        image.fill(24, 73, 226, 1, ink);
        image.fill(26, 80, 2, 5, ink);
        image.fill(247, 80, 2, 5, ink);
    }
    after.fill(29, 82, 6, 5, ink);
    after.fill(239, 82, 6, 5, ink);
    const a = Box.fromPixels(24, 73, 46, 17);
    const b = Box.fromPixels(204, 73, 46, 17);
    var edits = [_]candidate.Candidate{
        .{ .region = .{ .before = a, .after = a }, .pixels = 8 },
        .{ .region = .{ .before = b, .after = b }, .pixels = 8 },
    };
    try std.testing.expectEqual(edits.len, mergeCorners(&edits, before.view, after.view, .one));
}

test "corner rail reach follows logical scale at double density" {
    const canvas = @import("uidiff_test_canvas").Painters(value.Image);
    const image = try canvas.Canvas.init(2700, 54);
    defer image.deinit();
    const ink = canvas.inkShade(63, 4);
    image.fill(22, 39, 2592, 2, ink);
    image.fill(22, 39, 1, 13, ink);
    image.fill(2613, 39, 1, 13, ink);
    const a = Box.fromPixels(20, 36, 16, 18);
    const b = Box.fromPixels(2600, 36, 16, 18);
    var edits = [_]candidate.Candidate{
        .{ .region = .{ .before = a, .after = a }, .pixels = 8 },
        .{ .region = .{ .before = b, .after = b }, .pixels = 8 },
    };
    try std.testing.expectEqual(edits.len, mergeCorners(&edits, image.view, image.view, .one));
    try std.testing.expectEqual(@as(usize, 1), mergeCorners(&edits, image.view, image.view, Scale.parse("2").?));
}

test {
    std.testing.refAllDecls(@This());
}
