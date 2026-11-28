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

// Keeps overview badges away from the pane and sheet edges on thin sheets.
const thin_badge_gap = 8;

/// Returns the outside diameter of a detail badge in sheet pixels.
pub fn badgeDiameter(pane_layout: PaneLayout) usize {
    return 2 * pane_layout.px(badge_r + paint.badge_ring) + 1;
}

/// Returns the outside diameter of a badge over the main panes.
pub fn overviewDiameter(pane_layout: PaneLayout) usize {
    return if (pane_layout.panoramic) overview_badge_diameter else badgeDiameter(pane_layout);
}

/// Returns the space a badge keeps from a pane's edge, which is nonzero only
/// when a pane is thinner than an overview badge.
pub fn thinPaneClearance(panes: geometry.SideRects, pane_layout: PaneLayout) usize {
    const thin = @min(panes.get(.before).width, panes.get(.after).width) < overviewDiameter(pane_layout);
    return if (thin) pane_layout.px(thin_badge_gap) else 0;
}

/// Assigns non-overlapping overview and focus badge positions.
pub fn placeBadges(allocator: Allocator, details: []Detail, focuses: []const Focus, panes: geometry.SideRects, pair: value.Pair, size: value.Size, pane_layout: PaneLayout, captions: geometry.SideRects, gutter: Gutter) Allocator.Error!void {
    if (details.len == 0) return;
    const storage = try allocator.alloc(Rect, 4 * details.len + panes.values.len);
    defer allocator.free(storage);
    placeOverview(details, storage, panes, pair, size, pane_layout, captions, gutter);
    for (focuses, 0..) |window, group| {
        for (window.crops.values, std.enums.values(value.Side)) |patch, side| {
            if (patch) |p| placeFocus(details, storage, pair.get(side), p, side, group, textWidth(.regular, text.caption_size, window.captions.get(side).bytes()) + text.caption_padding, window.top + window.height, pane_layout);
        }
    }
}

fn placeOverview(details: []Detail, storage: []Rect, panes: geometry.SideRects, pair: value.Pair, size: value.Size, pane_layout: PaneLayout, captions: geometry.SideRects, gutter: Gutter) void {
    const diameter = overviewDiameter(pane_layout);
    const clearance = thinPaneClearance(panes, pane_layout);
    var len: usize = 0;
    for (captions.values) |caption| {
        storage[len] = caption;
        len += 1;
    }
    for (details) |d| {
        for (d.marks.values) |maybe| if (maybe) |mark| {
            storage[len] = mark;
            len += 1;
        };
    }
    for (panes.values, std.enums.values(value.Side)) |pane, side| {
        const image = pair.get(side);
        const left_edge = @min(pane.x, clearance + if (!pane_layout.panoramic and side == .after) panes.get(.before).right() else 0);
        const right_edge = @max(pane.right(), (if (!pane_layout.panoramic and side == .before) panes.get(.after).x else size.width) -| clearance);
        const inner_left = pane.x -| clearance;
        const inner_right = @min(right_edge, pane.right() + clearance);
        const lower_edge = if (pane_layout.panoramic and side == .before) panes.get(.after).y - diameter else @max(panes.get(.before).bottom(), panes.get(.after).bottom());
        const outside: [4]Rect = .{
            .{ .x = left_edge, .y = pane.y - diameter, .width = right_edge - left_edge, .height = diameter },
            .{ .x = inner_right, .y = pane.y, .width = right_edge - inner_right, .height = pane.height },
            .{ .x = left_edge, .y = pane.y, .width = inner_left -| left_edge, .height = pane.height },
            .{ .x = pane.x, .y = pane.bottom(), .width = pane.width, .height = lower_edge -| pane.bottom() },
        };
        for (details) |*d| {
            const mark = d.marks.get(side) orelse continue;
            const used = storage[0..len];
            const lanes = switch (gutter) {
                .plain => outside[1..3],
                .ribbons => if (side == .before) outside[2..3] else outside[1..2],
            };
            const preferred = if (mark.y == pane.y and pane.width >= diameter)
                placement.placeOutside(mark, outside[0], diameter, used)
            else
                levelWithMark(mark, lanes, diameter, used);
            const route = routing.routeBadge(mark, preferred orelse nearestOutside(mark, &outside, diameter, used), image, .{
                .from = .{ .x = 0, .y = 0, .width = image.width, .height = image.height },
                .to = pane,
            }, diameter, used);
            d.badges.set(side, route);
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
        if (side.height < diameter) {
            lane.* = side;
            continue;
        }
        lane.* = .{
            .x = side.x,
            .y = std.math.clamp((mark.y + mark.height / 2) -| (diameter / 2), side.y, side.bottom() - diameter),
            .width = side.width,
            .height = diameter,
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

fn placeFocus(details: []Detail, storage: []Rect, image: Image, patch: Crop, side: value.Side, group: usize, caption_width: usize, row_bottom: usize, pane_layout: PaneLayout) void {
    const pane = patch.to;
    const diameter = badgeDiameter(pane_layout);
    storage[0] = Rect{ .x = pane.x, .y = pane.y -| diameter, .width = caption_width, .height = diameter };
    var len: usize = 1;
    for (details) |d| {
        if (d.focus != group) continue;
        if (d.focus_marks.get(side)) |r| {
            storage[len] = r;
            len += 1;
        }
    }
    const header: Rect = .{ .x = pane.x, .y = pane.y -| diameter, .width = focus_slot_width, .height = diameter };
    const beside: Rect = .{ .x = pane.right(), .y = pane.y, .width = focus_slot_width - pane.width, .height = pane.height };
    const below: Rect = .{ .x = pane.x, .y = pane.bottom(), .width = pane.width, .height = row_bottom - pane.bottom() };
    for (details) |*d| {
        if (d.focus != group) continue;
        const mark = d.focus_marks.get(side) orelse continue;
        const used = storage[0..len];
        const outside = placement.placeOutside(mark, header, diameter, used) orelse placement.placeOutside(mark, beside, diameter, used) orelse
            placement.placeOutside(mark, below, diameter, used);
        const route = routing.routeBadge(mark, outside, image, patch, diameter, used);
        d.focus_badges.set(side, route);
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
    try std.testing.expect(panes.get(.before).width >= min_preview_side and panes.get(.before).height >= min_preview_side);
    try std.testing.expectEqual(@as(usize, 0), panes.get(.before).height % source.height);
    const gap = panes.get(.after).x - panes.get(.before).right();
    try std.testing.expect(gap >= 48 and gap <= panes.get(.before).width / 4);
    for ([_][2]usize{ .{ 60, 50 }, .{ 60, 0 }, .{ 0, 0 } }) |at| {
        const mark = offsetMark(.{ .x = at[0], .y = at[1], .width = 2, .height = 2 }, panes.get(.after), source).?;
        const b = placement.place(mark, panes.get(.after), badgeDiameter(pane_layout), &.{}).?;
        try std.testing.expect(!b.overlaps(mark));
        try std.testing.expect(b.x >= panes.get(.after).x and b.y >= panes.get(.after).y);
        try std.testing.expect(b.right() <= panes.get(.after).right() and b.bottom() <= panes.get(.after).bottom());
        if (at[1] != 0) try std.testing.expect(b.bottom() <= mark.y) else if (at[0] != 0) try std.testing.expect(b.right() <= mark.x);
    }
    try std.testing.expect(placement.place(panes.get(.after), panes.get(.after), badgeDiameter(pane_layout), &.{}) == null);
}

test "badge digits preserve native bold bitmap coverage" {
    const palette = drawing.palette;
    const Pixel = value.Pixel;
    const page = palette.page;
    const pane_layout = PaneLayout.init(.{ .width = 900, .height = 12 }, .{ .width = 900, .height = 12 });
    const diameter = overviewDiameter(pane_layout);
    const bounds: Rect = .{ .x = 0, .y = 0, .width = diameter, .height = diameter };
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
