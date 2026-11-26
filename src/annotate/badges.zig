//! Plans badge placement and exposes the corresponding sheet painting.

const std = @import("std");
const routing = @import("badges/routing.zig");
const paint = @import("badges/paint.zig");
const values = @import("../value.zig");
const placement = @import("placement.zig");
const geometry = @import("geometry.zig");
const text = @import("text.zig");
const focus_layout = @import("focus.zig");
const palette = @import("palette.zig");
const Rect = geometry.Rect;
const Layout = geometry.Layout;
const textWidth = text.textWidth;
const Detail = focus_layout.Detail;
const Focus = focus_layout.Focus;
const focus_slot_width = focus_layout.focus_slot_width;
const white = palette.white;
const tint = palette.tint;
const Allocator = std.mem.Allocator;
const Pixel = values.Pixel;
const Image = values.Image;
const Crop = @import("crops.zig").Crop;

/// Draws the outward halo and assigned badge on one sheet row.
pub const drawMark = paint.drawMark;
/// Paints the visible row of a numbered badge.
pub const badge = paint.badge;

/// Whether the gutter carries an alignment ribbon.
pub const Gutter = enum { plain, alignment };

const badge_r = 26;

const overview_badge_diameter = 2 * (18 + paint.badge_ring) + 1;

/// Keeps overview badges away from the pane and sheet edges on thin sheets.
pub const thin_badge_gap = 8;

/// Returns the outside diameter of a detail badge in sheet pixels.
pub fn badgeDiameter(ui: Layout) usize {
    return 2 * ui.px(badge_r + paint.badge_ring) + 1;
}

/// Returns the outside diameter of a badge over the main panes.
pub fn overviewDiameter(ui: Layout) usize {
    return if (ui.wide) overview_badge_diameter else badgeDiameter(ui);
}

/// Assigns non-overlapping overview and focus badge positions.
pub fn placeBadges(allocator: Allocator, details: []Detail, focuses: []const Focus, panes: [2]Rect, images: [2]Image, size: values.Size, ui: Layout, captions: [2]Rect, gutter: Gutter) Allocator.Error!void {
    if (details.len == 0) return;
    const storage = try allocator.alloc(Rect, 4 * details.len + panes.len);
    defer allocator.free(storage);
    placeOverview(details, storage, panes, images, size, ui, captions, gutter);
    for (focuses, 0..) |focus, group| {
        for (focus.crops, 0..) |patch, side| {
            if (patch) |p| placeFocus(details, storage, images[side], p, side, group, textWidth(.regular, text.caption_size, focus.captions[side].bytes()) + text.caption_padding, focus.top + focus.height, ui);
        }
    }
}

fn placeOverview(details: []Detail, storage: []Rect, panes: [2]Rect, images: [2]Image, size: values.Size, ui: Layout, captions: [2]Rect, gutter: Gutter) void {
    const diameter = overviewDiameter(ui);
    const clearance = if (@min(panes[0].w, panes[1].w) < diameter) ui.px(thin_badge_gap) else 0;
    var len: usize = 0;
    for (captions) |caption| {
        storage[len] = caption;
        len += 1;
    }
    for (details) |d| {
        for ([_]?Rect{ d.before_mark, d.after_mark }) |maybe| if (maybe) |mark| {
            storage[len] = mark;
            len += 1;
        };
    }
    for (panes, images, 0..) |pane, image, side| {
        const left_edge = @min(pane.x, clearance + if (!ui.wide and side == 1) panes[0].right() else 0);
        const right_edge = @max(pane.right(), (if (!ui.wide and side == 0) panes[1].x else size.width) -| clearance);
        const inner_left = pane.x -| clearance;
        const inner_right = @min(right_edge, pane.right() + clearance);
        const lower_edge = if (ui.wide and side == 0) panes[1].y - diameter else @max(panes[0].bottom(), panes[1].bottom());
        const outside: [4]Rect = .{
            .{ .x = left_edge, .y = pane.y - diameter, .w = right_edge - left_edge, .h = diameter },
            .{ .x = inner_right, .y = pane.y, .w = right_edge - inner_right, .h = pane.h },
            .{ .x = left_edge, .y = pane.y, .w = inner_left -| left_edge, .h = pane.h },
            .{ .x = pane.x, .y = pane.bottom(), .w = pane.w, .h = lower_edge -| pane.bottom() },
        };
        for (details) |*d| {
            const mark = (if (side == 0) d.before_mark else d.after_mark) orelse continue;
            const used = storage[0..len];
            const lanes = switch (gutter) {
                .plain => outside[1..3],
                .alignment => if (side == 0) outside[2..3] else outside[1..2],
            };
            const preferred = if (mark.y == pane.y and pane.w >= diameter)
                placement.placeOutside(mark, outside[0], diameter, used)
            else
                levelWithMark(mark, lanes, diameter, used);
            const route = routing.routeBadge(mark, preferred orelse nearestOutside(mark, &outside, diameter, used), image, .{
                .from = .{ .x = 0, .y = 0, .w = image.width, .h = image.height },
                .to = pane,
            }, diameter, used);
            if (side == 0) d.before_badge = route else d.after_badge = route;
            if (route.position()) |pos| {
                storage[len] = pos;
                len += 1;
            }
        }
    }
}

fn levelWithMark(mark: Rect, sides: []const Rect, diameter: usize, obstacles: []const Rect) ?Rect {
    var level: [2]Rect = undefined;
    for (level[0..sides.len], sides) |*lane, side| {
        if (side.h < diameter) {
            lane.* = side;
            continue;
        }
        lane.* = .{
            .x = side.x,
            .y = std.math.clamp((mark.y + mark.h / 2) -| (diameter / 2), side.y, side.bottom() - diameter),
            .w = side.w,
            .h = diameter,
        };
    }
    return nearestOutside(mark, level[0..sides.len], diameter, obstacles);
}

fn nearestOutside(mark: Rect, bounds: []const Rect, diameter: usize, obstacles: []const Rect) ?Rect {
    var best: ?Rect = null;
    var distance: usize = std.math.maxInt(usize);
    for (bounds) |area| {
        const candidate = placement.placeOutside(mark, area, diameter, obstacles) orelse continue;
        const gap = candidate.distanceSquared(mark);
        if (gap >= distance) continue;
        best = candidate;
        distance = gap;
    }
    return best;
}

fn placeFocus(details: []Detail, storage: []Rect, image: Image, patch: Crop, side: usize, group: usize, caption_width: usize, row_bottom: usize, ui: Layout) void {
    const pane = patch.to;
    const diameter = badgeDiameter(ui);
    storage[0] = Rect{ .x = pane.x, .y = pane.y -| diameter, .w = caption_width, .h = diameter };
    var len: usize = 1;
    for (details) |d| {
        if (d.focus != group) continue;
        if (d.focus_marks[side]) |r| {
            storage[len] = r;
            len += 1;
        }
    }
    const header: Rect = .{ .x = pane.x, .y = pane.y -| diameter, .w = focus_slot_width, .h = diameter };
    const beside: Rect = .{ .x = pane.right(), .y = pane.y, .w = focus_slot_width - pane.w, .h = pane.h };
    const below: Rect = .{ .x = pane.x, .y = pane.bottom(), .w = pane.w, .h = row_bottom - pane.bottom() };
    for (details) |*d| {
        if (d.focus != group) continue;
        const mark = d.focus_marks[side] orelse continue;
        const used = storage[0..len];
        const outside = placement.placeOutside(mark, header, diameter, used) orelse placement.placeOutside(mark, beside, diameter, used) orelse
            placement.placeOutside(mark, below, diameter, used);
        const route = routing.routeBadge(mark, outside, image, patch, diameter, used);
        d.focus_badges[side] = route;
        if (route.position()) |position| {
            storage[len] = position;
            len += 1;
        }
    }
}

fn badgeBounds(box: ?Rect, pane: Rect, ui: Layout) ?Rect {
    const mark = box orelse return null;
    return placement.place(mark, pane, badgeDiameter(ui), &.{});
}

test "the halo and color stroke leave the changed pixels uncovered" {
    const Region = values.Region;
    const Rows = @import("report_sheet.zig").Rows;
    const allocator = std.testing.allocator;
    const source: Pixel = .{ 17, 31, 61, 255 };
    const pixels: [160 * 100]Pixel = @splat(source);
    const image: Image = .{ .width = 160, .height = 100, .pixels = &pixels };
    const changed: Region = .{ .number = 1, .kind = .changed, .before = values.Box.fromPixels(80, 48, 30, 30) };
    const rows = try Rows.init(allocator, image, image, &.{changed}, &.{});
    defer rows.deinit(allocator);
    const storage = try allocator.alloc(Pixel, rows.plan.size.width);
    defer allocator.free(storage);
    const mark = rows.plan.details[0].before_mark.?;
    const x = mark.x;
    const line = rows.row(mark.y + mark.h / 2, storage);
    try std.testing.expectEqual(source, line[x]);
    try std.testing.expectEqual(source, line[x - 1]);
    try std.testing.expectEqual(tint(.changed), line[x - 3]);
    try std.testing.expectEqual(white, line[x - 4]);
    try std.testing.expectEqual(source, line[x - 6]);
}

test "top corner badges stay above the pane and clear of the caption" {
    const page = palette.page;
    const Region = values.Region;
    const Rows = @import("report_sheet.zig").Rows;
    const allocator = std.testing.allocator;
    const pixels: [80 * 80]Pixel = @splat(page);
    const image: Image = .{ .width = 80, .height = 80, .pixels = &pixels };
    const insert: Region = .{ .number = 1, .kind = .inserted, .after = values.Box.fromPixels(0, 0, 4, 4) };
    const rows = try Rows.init(allocator, image, image, &.{insert}, &.{});
    defer rows.deinit(allocator);
    const storage = try allocator.alloc(Pixel, rows.plan.size.width);
    defer allocator.free(storage);
    const right = rows.plan.panes[1].x;
    const above = rows.row(rows.plan.panes[1].y - 8, storage);
    try std.testing.expectEqual(page, above[right + 5]);
    const bounds = rows.plan.details[0].after_badge.position().?;
    const center = rows.row(bounds.y + bounds.h / 2, storage);
    try std.testing.expectEqual(white, center[bounds.x]);
    try std.testing.expectEqual(tint(.inserted), center[bounds.x + 5]);
    try std.testing.expect(bounds.bottom() <= rows.plan.panes[1].y);
    try std.testing.expect(!bounds.overlaps(rows.plan.details[0].after_mark.?));
}

test "thin wide strips and crops draw full badges above their pixels" {
    const page = palette.page;
    const Region = values.Region;
    const Rows = @import("report_sheet.zig").Rows;
    const allocator = std.testing.allocator;
    const pixels: [900 * 12]Pixel = @splat(page);
    const image: Image = .{ .width = 900, .height = 12, .pixels = &pixels };
    const region: Region = .{ .number = 1, .kind = .changed, .after = values.Box.fromPixels(400, 0, 12, 12) };
    const rows = try Rows.init(allocator, image, image, &.{region}, &.{});
    defer rows.deinit(allocator);
    const storage = try allocator.alloc(Pixel, rows.plan.size.width);
    defer allocator.free(storage);
    const detail = rows.plan.details[0];
    const overview = detail.after_badge.position().?;
    const focus = detail.focus_badges[1].position().?;
    try std.testing.expectEqual(@as(usize, overview_badge_diameter), overview.w);
    try std.testing.expectEqual(@as(usize, 59), focus.w);
    try std.testing.expectEqual(rows.plan.panes[1].y, overview.bottom());
    try std.testing.expectEqual(rows.plan.focuses[0].crops[1].?.to.y, focus.bottom());
    for ([_]Rect{ overview, focus }) |bounds| {
        const top = rows.row(bounds.y, storage);
        try std.testing.expectEqual(white, top[bounds.x + bounds.w / 2]);
        const bottom = rows.row(bounds.bottom() - 1, storage);
        try std.testing.expectEqual(white, bottom[bounds.x + bounds.w / 2]);
    }
}

test "small panes enlarge by an integer and keep badges clear of their boxes" {
    const min_preview_side = geometry.min_preview_side;
    const offsetMark = geometry.offsetMark;
    const Size = values.Size;
    const source: Size = .{ .width = 124, .height = 114 };
    const ui = Layout.init(source, source);
    const panes = ui.panes(source, source);
    try std.testing.expect(panes[0].w >= min_preview_side and panes[0].h >= min_preview_side);
    try std.testing.expectEqual(@as(usize, 0), panes[0].h % source.height);
    const gap = panes[1].x - panes[0].right();
    try std.testing.expect(gap >= 48 and gap <= panes[0].w / 4);
    for ([_][2]usize{ .{ 60, 50 }, .{ 60, 0 }, .{ 0, 0 } }) |at| {
        const mark = offsetMark(.{ .x = at[0], .y = at[1], .w = 2, .h = 2 }, panes[1], source).?;
        const b = badgeBounds(mark, panes[1], ui).?;
        try std.testing.expect(!b.overlaps(mark));
        try std.testing.expect(b.x >= panes[1].x and b.y >= panes[1].y);
        try std.testing.expect(b.right() <= panes[1].right() and b.bottom() <= panes[1].bottom());
        if (at[1] != 0) try std.testing.expect(b.bottom() <= mark.y) else if (at[0] != 0) try std.testing.expect(b.right() <= mark.x);
    }
    try std.testing.expect(badgeBounds(panes[1], panes[1], ui) == null);
}

test "edge badges stay near their numbered boxes and avoid all other marks" {
    const page = palette.page;
    const Region = values.Region;
    const Rows = @import("report_sheet.zig").Rows;
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(Pixel, 400 * 300);
    defer allocator.free(pixels);
    @memset(pixels, page);
    const image: Image = .{ .width = 400, .height = 300, .pixels = pixels };
    const boxes = [_]values.Box{
        .fromPixels(0, 0, 4, 4),   .fromPixels(396, 0, 4, 4),   .fromPixels(198, 0, 5, 3),
        .fromPixels(0, 296, 4, 4), .fromPixels(396, 296, 4, 4),
    };
    var regions: [boxes.len]Region = undefined;
    for (&regions, boxes, 1..) |*r, box, i| r.* = .{ .number = i, .kind = .changed, .before = box, .after = box };
    const rows = try Rows.init(allocator, image, image, &regions, &.{});
    defer rows.deinit(allocator);
    for (rows.plan.details, 0..) |detail, i| {
        const marker = detail.after_badge.position().?;
        try std.testing.expect(marker.distanceSquared(detail.after_mark.?) <= 144);
        for (rows.plan.details, 0..) |other, j| {
            try std.testing.expect(!marker.overlaps(other.after_mark.?));
            if (i != j) try std.testing.expect(!marker.overlaps(other.after_badge.position().?));
        }
    }
}

test "whole-image wide changes have a badge in both overviews" {
    const page = palette.page;
    const Rows = @import("report_sheet.zig").Rows;
    const allocator = std.testing.allocator;
    const pixels: [900 * 12]Pixel = @splat(page);
    const image: Image = .{ .width = 900, .height = 12, .pixels = &pixels };
    const box = values.Box.fromPixels(0, 0, 900, 12);
    const rows = try Rows.init(allocator, image, image, &.{.{ .number = 1, .kind = .changed, .before = box, .after = box }}, &.{});
    defer rows.deinit(allocator);
    try std.testing.expect(rows.plan.details[0].before_badge.position().?.bottom() <= rows.plan.panes[0].y);
    try std.testing.expect(rows.plan.details[0].after_badge.position().?.bottom() <= rows.plan.panes[1].y);
}

test "edge badges use the gutter margins and the space above the caption" {
    const Region = values.Region;
    const Rows = @import("report_sheet.zig").Rows;
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(Pixel, 400 * 300);
    defer allocator.free(pixels);
    @memset(pixels, .{ 45, 67, 85, 255 });
    const image: Image = .{ .width = 400, .height = 300, .pixels = pixels };
    const regions = [_]Region{
        .{ .number = 1, .kind = .removed, .before = .fromPixels(0, 145, 5, 10) },
        .{ .number = 2, .kind = .changed, .before = .fromPixels(395, 130, 5, 10), .after = .fromPixels(395, 130, 5, 10) },
        .{ .number = 3, .kind = .inserted, .after = .fromPixels(220, 0, 10, 8) },
        .{ .number = 4, .kind = .changed, .before = .fromPixels(195, 145, 10, 10) },
    };
    const rows = try Rows.init(allocator, image, image, &regions, &.{});
    defer rows.deinit(allocator);
    const left = rows.plan.details[0].before_badge.position().?;
    const gap = rows.plan.details[1].before_badge.position().?;
    const right = rows.plan.details[1].after_badge.position().?;
    const top = rows.plan.details[2].after_badge.position().?;
    try std.testing.expect(left.right() <= rows.plan.panes[0].x);
    try std.testing.expect(gap.x >= rows.plan.panes[0].right() and gap.right() <= rows.plan.panes[1].x);
    try std.testing.expect(right.x >= rows.plan.panes[1].right());
    try std.testing.expect(top.bottom() <= rows.plan.panes[1].y);
    const center = rows.plan.details[3].before_badge.position().?;
    for ([_]Rect{ left, gap, right, top }) |badge_rect| {
        for (rows.plan.panes) |pane| try std.testing.expect(!badge_rect.overlaps(pane));
    }
    const center_mark = rows.plan.details[3].before_mark.?;
    try std.testing.expect(center.overlaps(rows.plan.panes[0]));
    try std.testing.expect(!center.overlaps(center_mark));
    try std.testing.expect(center.distanceSquared(center_mark) <= 36);
}

test {
    std.testing.refAllDecls(@This());
}
