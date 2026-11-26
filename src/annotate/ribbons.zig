//! Alignment ribbons between the ordinary sheet panes.
const std = @import("std");
const drawing = @import("drawing.zig");
const copy = drawing.copy;
const value = @import("../value.zig");
const geometry = @import("geometry.zig");
const text = drawing.text;
const canvas = drawing.canvas;
const focus = @import("focus.zig");
const palette = drawing.palette;
const PaneLayout = geometry.PaneLayout;
const Rect = geometry.Rect;
const pane_top = geometry.pane_top;
const Text = text.Text;
const Line = canvas.Line;
const Face = text.Face;
const textWidth = text.textWidth;
const Detail = focus.Detail;
const stationary = palette.stationary;
const moved_band = palette.moved_band;
const insert_band = palette.insert_band;
const remove_band = palette.remove_band;
const blue = palette.blue;
const Move = value.Move;
const Pixel = value.Pixel;

const PreviewMove = struct { before: value.SheetRowRange, after: value.SheetRowRange };

/// One projected move, its label, and the optional inserted or removed wedge.
pub const Ribbon = struct { move: PreviewMove, label: Text, wedge_top: ?usize };

/// Returns the signed displacement in source device pixels.
pub fn displacement(move: Move) isize {
    return @as(isize, @intCast(move.after.y)) - @as(isize, @intCast(move.before.y));
}

/// Projects a device move into sheet rows, dropping subpixel shifts.
pub fn previewMove(move: Move, pane_layout: PaneLayout) ?PreviewMove {
    const before_y = pane_layout.position(move.before.y);
    const after_y = pane_layout.position(move.after.y);
    const height = @min(
        pane_layout.position(move.before.y + move.before.height) - before_y,
        pane_layout.position(move.after.y + move.after.height) - after_y,
    );
    if (height == 0 or before_y == after_y) return null;
    return .{
        .before = .{ .y = before_y, .height = height },
        .after = .{ .y = after_y, .height = height },
    };
}

/// Orders ribbons by the last sheet row they may paint.
pub fn earlierRibbonEnd(_: void, a: Ribbon, b: Ribbon) bool {
    return ribbonEnd(a) < ribbonEnd(b);
}

/// Finds the source row where the insert or removal meets the ribbon.
pub fn wedgeTop(details: []const Detail, move: Move, down: bool) ?usize {
    const kind: value.Kind = if (down) .inserted else .removed;
    const low = @min(move.before.y, move.after.y);
    const high = @max(move.before.y, move.after.y);
    const y0: f64 = @floatFromInt(low -| (high - low));
    const y1: f64 = @floatFromInt(high);
    for (details) |detail| {
        if (detail.region.kind != kind) continue;
        if (detail.region.boxOn(if (down) .after else .before)) |b| {
            if (b.y >= 0 and b.y <= y1 and b.bottom() >= y0) {
                return @max(low -| (high - low), @min(low, @as(usize, @intFromFloat(b.y))));
            }
        }
    }
    return null;
}

/// Composites alignment ribbons for one row between the panes.
pub fn drawGutter(line: Line, y: usize, pane_layout: PaneLayout, panes: geometry.SideRects, ribbons: []const Ribbon) void {
    const x = panes.get(.before).right();
    const width = panes.get(.after).x - x;
    line.fill(x, x + width, stationary);
    var lo: usize = 0;
    var hi = ribbons.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (ribbonEnd(ribbons[mid]) <= y) lo = mid + 1 else hi = mid;
    }
    for (ribbons[lo..]) |ribbon| {
        const m = ribbon.move;
        const low = @min(m.before.y, m.after.y);
        const high = @max(m.before.y + m.before.height, m.after.y + m.after.height);
        if (y < (ribbon.wedge_top orelse low) or y >= high) continue;
        const down = m.after.y > m.before.y;
        const delta = @max(m.before.y, m.after.y) - low;
        if (y >= low) {
            const local = y - low;
            const right = edgeColumn(local + 1, delta, width);
            ribbonSpan(line, x, edgeColumn((local + 1) -| m.before.height, delta, width), right, down, width, moved_band);
            if (ribbon.wedge_top != null) ribbonSpan(line, x, right, width, down, width, if (down) insert_band else remove_band);
        } else if (ribbon.wedge_top) |top| {
            ribbonSpan(line, x, edgeColumn(low - y, low - top, width), width, down, width, if (down) insert_band else remove_band);
        }
        // A single signed value leaves space on either side of the ribbon.
        const body = pane_layout.px(20);
        const line_h = Face.bold.height(body);
        if (m.before.height >= line_h) {
            const top = low + (delta + m.before.height - line_h) / 2;
            if (y >= top and y - top < line_h) {
                const first = edgeColumn((top + line_h - low) -| m.before.height, delta, width);
                const last = edgeColumn(top - low + 1, delta, width);
                const label = ribbon.label.bytes();
                const needed = textWidth(.bold, body, label);
                if (last >= first + needed + 2 * pane_layout.px(8)) {
                    const offset = if (down) first else width - last;
                    const label_x = x + offset + (last - first - needed) / 2;
                    line.text(label_x, pane_layout.px(pane_top) + top, label, .bold, body, blue);
                }
            }
        }
        return;
    }
    const before_h = panes.get(.before).height;
    const after_h = panes.get(.after).height;
    const overlap = @min(before_h, after_h);
    if (y >= overlap and before_h != after_h) {
        const delta = @max(before_h, after_h) - overlap;
        const tail_width = (delta - (y - overlap)) * width / delta;
        if (after_h > before_h) {
            line.fill(x + width - tail_width, x + width, insert_band);
        } else {
            line.fill(x, x + tail_width, remove_band);
        }
    }
}

fn ribbonEnd(ribbon: Ribbon) usize {
    return @max(ribbon.move.before.y, ribbon.move.after.y) + ribbon.move.before.height;
}

fn edgeColumn(rows: usize, delta: usize, width: usize) usize {
    if (rows > delta) return width;
    return (rows * (width - 1) + delta - 1) / delta;
}

fn ribbonSpan(line: Line, x: usize, first: usize, end: usize, down: bool, width: usize, color: Pixel) void {
    if (down) line.fill(x + first, x + end, color) else line.fill(x + width - end, x + width - first, color);
}

test {
    std.testing.refAllDecls(@This());
}

test "a three-digit shift label leaves space at both gutter edges" {
    const size = value.Size{ .width = 400, .height = 500 };
    const pane_layout = PaneLayout.init(size, size);
    const panes = pane_layout.panes(size, size);
    const ribbons = [_]Ribbon{.{
        .move = .{ .before = .{ .y = 120, .height = 250 }, .after = .{ .y = 20, .height = 250 } },
        .label = try Text.format(copy.shift_format, .{-100}),
        .wedge_top = null,
    }};
    var pixels: [1024]Pixel = undefined;
    var painted = false;
    for (20..370) |y| {
        @memset(&pixels, stationary);
        drawGutter(.{ .pixels = &pixels, .y = pane_layout.px(pane_top) + y }, y, pane_layout, panes, &ribbons);
        for (pixels, 0..) |pixel, x| {
            if (!std.meta.eql(pixel, blue)) continue;
            painted = true;
            try std.testing.expect(x >= panes.get(.before).right() + pane_layout.px(8) and x < panes.get(.after).x - pane_layout.px(8));
        }
    }
    try std.testing.expect(painted);
}
