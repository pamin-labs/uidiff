//! Plans badge placement and exposes the corresponding sheet painting.

const std = @import("std");
const drawing = @import("drawing.zig");
const routing = @import("badges/routing.zig");
const paint = @import("badges/paint.zig");
const value = @import("../value.zig");
const placement = @import("badges/placement.zig");
const geometry = @import("geometry.zig");
const text = drawing.text;
const focus = @import("focus.zig");
const Rect = geometry.Rect;
const PaneLayout = geometry.PaneLayout;
const textWidth = text.textWidth;
const Detail = focus.Detail;
const Focus = focus.Focus;
const focus_slot_width = focus.focus_slot_width;
const Allocator = std.mem.Allocator;
const Image = value.Image;
const Crop = @import("crops.zig").Crop;

/// Draws the outward halo and assigned badge on one sheet row.
pub const drawMark = paint.drawMark;
/// Paints the visible row of a numbered badge.
pub const badge = paint.badge;

/// Whether the gutter carries an alignment ribbon.
pub const Gutter = enum { plain, ribbons };

const badge_r = 26;

const overview_badge_diameter = 2 * (18 + paint.badge_ring) + 1;

/// Keeps overview badges away from the pane and sheet edges on thin sheets.
pub const thin_badge_gap = 8;

/// Returns the outside diameter of a detail badge in sheet pixels.
pub fn badgeDiameter(pane_layout: PaneLayout) usize {
    return 2 * pane_layout.px(badge_r + paint.badge_ring) + 1;
}

/// Returns the outside diameter of a badge over the main panes.
pub fn overviewDiameter(pane_layout: PaneLayout) usize {
    return if (pane_layout.panoramic) overview_badge_diameter else badgeDiameter(pane_layout);
}

/// Assigns non-overlapping overview and focus badge positions.
pub fn placeBadges(allocator: Allocator, details: []Detail, focuses: []const Focus, panes: [2]Rect, images: [2]Image, size: value.Size, pane_layout: PaneLayout, captions: [2]Rect, gutter: Gutter) Allocator.Error!void {
    if (details.len == 0) return;
    const storage = try allocator.alloc(Rect, 4 * details.len + panes.len);
    defer allocator.free(storage);
    placeOverview(details, storage, panes, images, size, pane_layout, captions, gutter);
    for (focuses, 0..) |window, group| {
        for (window.crops, 0..) |patch, side| {
            if (patch) |p| placeFocus(details, storage, images[side], p, side, group, textWidth(.regular, text.caption_size, window.captions[side].bytes()) + text.caption_padding, window.top + window.height, pane_layout);
        }
    }
}

fn placeOverview(details: []Detail, storage: []Rect, panes: [2]Rect, images: [2]Image, size: value.Size, pane_layout: PaneLayout, captions: [2]Rect, gutter: Gutter) void {
    const diameter = overviewDiameter(pane_layout);
    const clearance = if (@min(panes[0].w, panes[1].w) < diameter) pane_layout.px(thin_badge_gap) else 0;
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
        const left_edge = @min(pane.x, clearance + if (!pane_layout.panoramic and side == 1) panes[0].right() else 0);
        const right_edge = @max(pane.right(), (if (!pane_layout.panoramic and side == 0) panes[1].x else size.width) -| clearance);
        const inner_left = pane.x -| clearance;
        const inner_right = @min(right_edge, pane.right() + clearance);
        const lower_edge = if (pane_layout.panoramic and side == 0) panes[1].y - diameter else @max(panes[0].bottom(), panes[1].bottom());
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
                .ribbons => if (side == 0) outside[2..3] else outside[1..2],
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

fn placeFocus(details: []Detail, storage: []Rect, image: Image, patch: Crop, side: usize, group: usize, caption_width: usize, row_bottom: usize, pane_layout: PaneLayout) void {
    const pane = patch.to;
    const diameter = badgeDiameter(pane_layout);
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

test {
    std.testing.refAllDecls(@This());
}

test "small panes enlarge by an integer and keep badges clear of their boxes" {
    const min_preview_side = geometry.min_preview_side;
    const offsetMark = geometry.offsetMark;
    const Size = value.Size;
    const source: Size = .{ .width = 124, .height = 114 };
    const pane_layout = PaneLayout.init(source, source);
    const panes = pane_layout.panes(source, source);
    try std.testing.expect(panes[0].w >= min_preview_side and panes[0].h >= min_preview_side);
    try std.testing.expectEqual(@as(usize, 0), panes[0].h % source.height);
    const gap = panes[1].x - panes[0].right();
    try std.testing.expect(gap >= 48 and gap <= panes[0].w / 4);
    for ([_][2]usize{ .{ 60, 50 }, .{ 60, 0 }, .{ 0, 0 } }) |at| {
        const mark = offsetMark(.{ .x = at[0], .y = at[1], .w = 2, .h = 2 }, panes[1], source).?;
        const b = placement.place(mark, panes[1], badgeDiameter(pane_layout), &.{}).?;
        try std.testing.expect(!b.overlaps(mark));
        try std.testing.expect(b.x >= panes[1].x and b.y >= panes[1].y);
        try std.testing.expect(b.right() <= panes[1].right() and b.bottom() <= panes[1].bottom());
        if (at[1] != 0) try std.testing.expect(b.bottom() <= mark.y) else if (at[0] != 0) try std.testing.expect(b.right() <= mark.x);
    }
    try std.testing.expect(placement.place(panes[1], panes[1], badgeDiameter(pane_layout), &.{}) == null);
}

test "badge digits preserve native bold bitmap coverage" {
    const palette = drawing.palette;
    const Pixel = value.Pixel;
    const page = palette.page;
    const pane_layout = PaneLayout.init(.{ .width = 900, .height = 12 }, .{ .width = 900, .height = 12 });
    const diameter = overviewDiameter(pane_layout);
    const bounds: Rect = .{ .x = 0, .y = 0, .w = diameter, .h = diameter };
    const storage = try std.testing.allocator.alloc(Pixel, diameter);
    defer std.testing.allocator.free(storage);
    const base = palette.tint(.changed);
    for ("0123456789") |digit| {
        const g = text.glyph(.bold, digit);
        const x = (diameter - g[3]) / 2;
        const y = (diameter - g[4]) / 2;
        for (0..g[4]) |gy| {
            @memset(storage, page);
            badge(.{ .pixels = storage, .y = y + gy }, bounds, .changed, &.{digit}, pane_layout);
            for (0..g[3]) |gx| {
                const sample = gy * g[3] + gx;
                const packed_ = g[5 + sample / 2];
                const alpha: u16 = if (sample % 2 == 0) packed_ & 15 else packed_ >> 4;
                for (0..3) |channel| {
                    const expected: u8 = @intCast((@as(u16, base[channel]) * (15 - alpha) + 255 * alpha + 7) / 15);
                    try std.testing.expectEqual(expected, storage[x + gx][channel]);
                }
            }
        }
    }
}
