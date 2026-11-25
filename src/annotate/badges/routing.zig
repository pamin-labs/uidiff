//! Routes badge leaders around existing marks and screenshot ink.

const std = @import("std");
const values = @import("../../value.zig");
const placement = @import("../placement.zig");
const geometry = @import("../geometry.zig");
const canvas = @import("../canvas.zig");
const focus_layout = @import("../focus.zig");
const palette = @import("../palette.zig");
const Rect = geometry.Rect;
const roundSpan = canvas.roundSpan;
const Badge = focus_layout.Badge;
const white = palette.white;
const Pixel = values.Pixel;
const Image = values.Image;
const Crop = @import("../crops.zig").Crop;

/// Sheet-space endpoints of the visible connection to a mark.
pub const Leader = struct {
    first_y: usize,
    last_y: usize,
    top_x: usize,
    bottom_x: usize,

    /// Finds the badge and mark endpoints.
    pub fn init(mark: Rect, badge_box: Rect) Leader {
        const a_x = badge_box.x + badge_box.w / 2;
        const a_y = badge_box.y + badge_box.h / 2;
        const b_x = std.math.clamp(a_x, mark.x, mark.right() - 1);
        const b_y = std.math.clamp(a_y, mark.y, mark.bottom() - 1);
        return .{
            .first_y = @min(a_y, b_y),
            .last_y = @max(a_y, b_y),
            .top_x = if (a_y < b_y) a_x else b_x,
            .bottom_x = if (a_y < b_y) b_x else a_x,
        };
    }

    /// Returns the leader stroke on a sheet row outside the marked pixels.
    pub fn span(self: Leader, mark: Rect, y: usize) ?[2]usize {
        if (y < self.first_y or y > self.last_y) return null;
        const dx = @max(self.top_x, self.bottom_x) - @min(self.top_x, self.bottom_x);
        const dy = self.last_y - self.first_y;
        const start = if (dy == 0) 0 else (y - self.first_y) * dx / dy;
        const end = if (dy == 0) dx else (@min(self.last_y, y + 1) - self.first_y) * dx / dy;
        var left = if (self.top_x <= self.bottom_x) self.top_x + start else self.top_x - end;
        var right = 1 + if (self.top_x <= self.bottom_x) self.top_x + end else self.top_x - start;
        if (mark.containsRow(y)) {
            // A span reaches the mark from only one side.
            if (left < mark.x) right = @min(right, mark.x) else left = @max(left, mark.right());
        }
        return if (left < right) .{ left, right } else null;
    }
};

const LeaderClearance = enum { clear, ink, obstructed };

// Stop looking for flat paint on very long paths over scaled captures.
const max_leader_samples = 64 * 1024;

const diagonal_clearance_px = 32;

/// Chooses a badge position and checks whether its leader crosses ink.
pub fn routeBadge(mark: Rect, outside: ?Rect, image: Image, patch: Crop, diameter: usize, obstacles: []const Rect) Badge {
    if (outside) |position| {
        if (position.distanceSquared(mark) <= diameter * diameter) return .{ .plain = position };
        switch (leaderClearance(mark, position, image, patch, obstacles)) {
            .clear => return .{ .linked = position },
            .obstructed => return .{ .plain = position },
            .ink => return .{ .plain = adjacentOnPaint(mark, image, patch, diameter, obstacles) orelse position },
        }
    }
    return if (placement.place(mark, patch.to, diameter, obstacles)) |position| .{ .plain = position } else .none;
}

fn adjacentOnPaint(mark: Rect, image: Image, patch: Crop, diameter: usize, obstacles: []const Rect) ?Rect {
    const pane = patch.to;
    const around = [_]Rect{
        .{ .x = pane.x, .y = pane.y, .w = pane.w, .h = mark.y - pane.y },
        .{ .x = pane.x, .y = pane.y, .w = mark.x - pane.x, .h = pane.h },
        .{ .x = pane.x, .y = mark.bottom(), .w = pane.w, .h = pane.bottom() - mark.bottom() },
        .{ .x = mark.right(), .y = pane.y, .w = pane.right() - mark.right(), .h = pane.h },
    };
    var best: ?Rect = null;
    var distance: usize = std.math.maxInt(usize);
    for (around, 0..) |bounds, side| {
        const initial = placement.place(mark, bounds, diameter, obstacles) orelse continue;
        const radius = diameter / 2;
        const across_rows = side % 2 != 0;
        const start = if (across_rows) bounds.y else bounds.x;
        const finish = (if (across_rows) bounds.bottom() else bounds.right()) - diameter;
        const at = if (across_rows) initial.y else initial.x;
        for ([_]usize{ at, @max(start, at -| radius), @min(finish, at + radius) }) |along| {
            var candidate = initial;
            if (across_rows) candidate.y = along else candidate.x = along;
            const gap = candidate.distanceSquared(mark);
            if (gap >= distance or gap > diameter * diameter) continue;
            if (overlapsAny(candidate, obstacles) or !badgeOnPaint(image, patch, candidate)) continue;
            best = candidate;
            distance = gap;
        }
    }
    return best;
}

fn overlapsAny(rect: Rect, obstacles: []const Rect) bool {
    for (obstacles) |obstacle| if (rect.overlaps(obstacle)) return true;
    return false;
}

fn badgeOnPaint(image: Image, patch: Crop, badge_box: Rect) bool {
    var remaining: usize = max_leader_samples;
    var background: ?Pixel = null;
    for (badge_box.y..badge_box.bottom()) |y| {
        const span = roundSpan(badge_box, badge_box.w / 2, y) orelse continue;
        const row: Rect = .{ .x = span[0], .y = y, .w = span[1] - span[0], .h = 1 };
        if (paintClearance(image, patch, row, &remaining, &background) != .clear) return false;
    }
    return true;
}

fn leaderClearance(mark: Rect, badge_box: Rect, image: Image, patch: Crop, obstacles: []const Rect) LeaderClearance {
    const leader = Leader.init(mark, badge_box);
    var remaining: usize = max_leader_samples;
    var background: ?Pixel = null;
    var obstructed = false;
    // A diagonal needs room beside it to stay visually clear of other rows.
    const padding: usize = if (leader.top_x != leader.bottom_x and leader.first_y != leader.last_y) diagonal_clearance_px else 0;
    for (leader.first_y..leader.last_y + 1) |y| {
        const span = leader.span(mark, y) orelse continue;
        const line: Rect = .{ .x = span[0], .y = y, .w = span[1] - span[0], .h = 1 };
        obstructed = obstructed or overlapsAny(line, obstacles);
        if (!line.overlaps(patch.to)) continue;
        var start = span[0] -| padding;
        var end = span[1] + padding;
        if (mark.containsRow(y)) {
            if (span[0] < mark.x) end = @min(end, mark.x) else start = @max(start, mark.right());
        }
        const top = @max(y -| padding, patch.to.y);
        const bottom = @min(y + padding + 1, patch.to.bottom());
        const guard: Rect = .{ .x = start, .y = top, .w = end - start, .h = bottom - top };
        const clearance = paintClearance(image, patch, guard, &remaining, &background);
        if (clearance != .clear) return clearance;
    }
    return if (obstructed) .obstructed else .clear;
}

fn paintClearance(image: Image, patch: Crop, area: Rect, remaining: *usize, background: *?Pixel) LeaderClearance {
    if (area.w == 0 or area.h == 0 or !area.overlaps(patch.to)) return .clear;
    const left = @max(area.x, patch.to.x) - patch.to.x;
    const right = @min(area.right(), patch.to.right()) - patch.to.x;
    const top = @max(area.y, patch.to.y) - patch.to.y;
    const bottom = @min(area.bottom(), patch.to.bottom()) - patch.to.y;
    const x0 = patch.from.x + left * patch.from.w / patch.to.w;
    const x1 = patch.from.x + (right * patch.from.w + patch.to.w - 1) / patch.to.w;
    const y0 = patch.from.y + top * patch.from.h / patch.to.h;
    const y1 = patch.from.y + (bottom * patch.from.h + patch.to.h - 1) / patch.to.h;
    const count = (x1 - x0) * (y1 - y0);
    if (count > remaining.*) return .obstructed;
    remaining.* -= count;
    for (y0..y1) |source_y| {
        const pixels = image.row(source_y)[x0..x1];
        const paint = background.* orelse pixels[0];
        for (pixels) |pixel| if (!std.meta.eql(pixel, paint)) return .ink;
        background.* = paint;
    }
    return .clear;
}

test "overview leaders move a blocked badge near the edited box" {
    const width = 320;
    const height = 200;
    var pixels: [width * height]Pixel = @splat(white);
    const image: Image = .{ .width = width, .height = height, .pixels = &pixels };
    const patch: Crop = .{
        .from = .{ .x = 0, .y = 0, .w = width, .h = height },
        .to = .{ .x = 60, .y = 0, .w = width, .h = height },
    };
    const mark: Rect = .{ .x = 330, .y = 70, .w = 20, .h = 20 };
    const aligned: Rect = .{ .x = 0, .y = 60, .w = 40, .h = 40 };
    const diagonal: Rect = .{ .x = 0, .y = 39, .w = 40, .h = 40 };
    try std.testing.expect(routeBadge(mark, aligned, image, patch, 40, &.{}) == .linked);
    for (78..83) |y| @memset(pixels[y * width + 20 ..][0..15], palette.ink);
    for (60..69) |y| @memset(pixels[y * width + 95 ..][0..18], palette.ink);
    for ([_]Rect{ aligned, diagonal }) |outside| {
        const route = routeBadge(mark, outside, image, patch, 40, &.{});
        try std.testing.expect(route != .linked);
        try std.testing.expect(!std.meta.eql(route.position().?, outside));
        try std.testing.expect(route.position().?.distanceSquared(mark) <= 40 * 40);
    }
}

test {
    std.testing.refAllDecls(@This());
}
