//! Paints badge faces, outlines and leaders onto one sheet row.

const std = @import("std");
const drawing = @import("../drawing.zig");
const routing = @import("routing.zig");
const value = @import("../../value.zig");
const geometry = @import("../geometry.zig");
const canvas = drawing.canvas;
const focus = @import("../focus.zig");
const palette = drawing.palette;
const Rect = geometry.Rect;
const PaneLayout = geometry.PaneLayout;
const Line = canvas.Line;
const roundSpan = canvas.roundSpan;
const Detail = focus.Detail;
const Badge = focus.Badge;
const white = palette.white;
const tint = palette.tint;
const Pixel = value.Pixel;

/// Width of the badge border at the base sheet scale.
pub const badge_ring = 3;

/// Draws the outward halo and assigned badge on one sheet row.
pub noinline fn drawMark(line: Line, box: ?Rect, route: Badge, detail: Detail, pane_layout: PaneLayout) void {
    const rect = box orelse return;
    if (route == .linked) drawLeader(line, rect, route.linked, tint(detail.region.kind));
    const width = 2;
    const halo = 2;
    const frame = rect.outset(3);
    if (line.y >= frame.y -| halo and line.y < frame.y + frame.height + halo) {
        const r = pane_layout.px(6);
        strokeOutside(line, frame.outset(halo), r + halo, halo, white, rect);
        strokeOutside(line, frame, r, width, tint(detail.region.kind), rect);
    }
    if (route.position()) |where| badge(line, where, detail.region.kind, detail.number.bytes(), pane_layout);
}

/// Paints the visible row of a numbered badge.
pub noinline fn badge(line: Line, bounds: Rect, kind: value.Kind, number: []const u8, pane_layout: PaneLayout) void {
    if (!bounds.containsRow(line.y)) return;
    const outer = bounds.width / 2;
    const ring = @min(pane_layout.px(badge_ring), outer / 3);
    const inner = bounds.inset(ring);
    line.rounded(bounds, outer, white);
    line.rounded(inner, outer - ring, tint(kind));
    line.badgeText(inner, number, white);
}

fn drawLeader(line: Line, mark: Rect, badge_box: Rect, color: Pixel) void {
    if (routing.Leader.init(mark, badge_box).span(mark, line.y)) |span| line.fill(span[0], span[1], color);
}

fn strokeOutside(line: Line, frame: Rect, radius: usize, thickness: usize, color: Pixel, protected: Rect) void {
    if (!protected.containsRow(line.y)) return line.stroke(frame, radius, thickness, color);
    const outer = roundSpan(frame, radius, line.y) orelse return;
    const inner = roundSpan(frame.inset(thickness), radius -| thickness, line.y) orelse .{ protected.x, protected.x + protected.width };
    line.fill(outer[0], @min(inner[0], protected.x, outer[1]), color);
    line.fill(@max(inner[1], protected.x + protected.width, outer[0]), outer[1], color);
}

test "a distant badge gets a leader outside the marked pixels" {
    const background: Pixel = .{ 41, 55, 70, 255 };
    var pixels: [360]Pixel = @splat(background);
    const line: Line = .{ .pixels = &pixels, .y = 30 };
    const mark: Rect = .{ .x = 20, .y = 20, .width = 30, .height = 20 };
    const badge_box: Rect = .{ .x = 258, .y = 10, .width = 40, .height = 40 };
    drawLeader(line, mark, badge_box, white);
    try std.testing.expectEqual(white, pixels[150]);
    try std.testing.expectEqual(background, pixels[49]);
    try std.testing.expectEqual(background, pixels[320]);
}

test {
    std.testing.refAllDecls(@This());
}
