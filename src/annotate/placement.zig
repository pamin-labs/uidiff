//! Finds room for annotation badges around overview and detail marks.
const std = @import("std");
const Rect = @import("geometry.zig").Rect;

const Search = struct { result: ?Rect = null, distance: usize };
const gap = 6;

/// Finds a badge position near its mark within the supplied bounds.
pub fn place(mark: Rect, bounds: Rect, diameter: usize, obstacles: []const Rect) ?Rect {
    const reach = 2 * diameter + gap;
    return placeWithin(mark, bounds, diameter, obstacles, reach * reach);
}

/// Finds an outside spot at any distance, still preferring a nearby badge.
pub fn placeOutside(mark: Rect, bounds: Rect, diameter: usize, obstacles: []const Rect) ?Rect {
    return placeWithin(mark, bounds, diameter, obstacles, std.math.maxInt(usize));
}

fn placeWithin(mark: Rect, bounds: Rect, diameter: usize, obstacles: []const Rect, limit: usize) ?Rect {
    if (bounds.w < diameter or bounds.h < diameter) return null;
    const d: isize = @intCast(diameter);
    const max_x: isize = @intCast(bounds.right() - diameter);
    const max_y: isize = @intCast(bounds.bottom() - diameter);
    const low_x: isize = @intCast(bounds.x);
    const low_y: isize = @intCast(bounds.y);
    const x: isize = @intCast(mark.x);
    const y: isize = @intCast(mark.y);
    const right: isize = @intCast(mark.right());
    const bottom: isize = @intCast(mark.bottom());
    const xs = [_]isize{ x, right - d, @divFloor(x + right - d, 2) };
    const ys = [_]isize{ y, bottom - d, @divFloor(y + bottom - d, 2) };
    const sides_x = [_]isize{ x - d - gap, right + gap };
    const sides_y = [_]isize{ y - d - gap, bottom + gap };
    var best: Search = .{ .distance = limit };

    for ([_]bool{ false, true }) |clamp_edges| {
        for ([_]bool{ true, false, true, false }, 0..) |vertical, side| {
            if (vertical) {
                const at = if (clamp_edges) std.math.clamp(sides_y[side / 2], low_y, max_y) else sides_y[side / 2];
                for (xs) |along| consider(mark, bounds, diameter, std.math.clamp(along, low_x, max_x), at, obstacles, &best);
                for (obstacles) |b| {
                    consider(mark, bounds, diameter, @as(isize, @intCast(b.x)) - d - gap, at, obstacles, &best);
                    consider(mark, bounds, diameter, @as(isize, @intCast(b.right())) + gap, at, obstacles, &best);
                }
            } else {
                const at = if (clamp_edges) std.math.clamp(sides_x[side / 2], low_x, max_x) else sides_x[side / 2];
                for (ys) |along| consider(mark, bounds, diameter, at, std.math.clamp(along, low_y, max_y), obstacles, &best);
                for (obstacles) |b| {
                    consider(mark, bounds, diameter, at, @as(isize, @intCast(b.y)) - d - gap, obstacles, &best);
                    consider(mark, bounds, diameter, at, @as(isize, @intCast(b.bottom())) + gap, obstacles, &best);
                }
            }
        }
        if (best.result != null) return best.result;
    }
    // Crowded marks may only have room diagonally.
    const edges = 2 + 2 * obstacles.len;
    for (0..edges) |i| {
        const near_x = axisEdge(obstacles, i, low_x, max_x, d, true);
        for (0..edges) |j| {
            const near_y = axisEdge(obstacles, j, low_y, max_y, d, false);
            consider(mark, bounds, diameter, near_x, near_y, obstacles, &best);
        }
    }
    return best.result;
}

fn axisEdge(obstacles: []const Rect, i: usize, min: isize, max: isize, diameter: isize, horizontal: bool) isize {
    if (i < 2) return if (i == 0) min else max;
    const box = obstacles[(i - 2) / 2];
    const start: isize = @intCast(if (horizontal) box.x else box.y);
    const end: isize = @intCast(if (horizontal) box.right() else box.bottom());
    return std.math.clamp(if (i % 2 == 0) start - diameter else end, min, max);
}

fn consider(mark: Rect, bounds: Rect, diameter: usize, x: isize, y: isize, obstacles: []const Rect, best: *Search) void {
    const left = std.math.cast(usize, x) orelse return;
    const top = std.math.cast(usize, y) orelse return;
    if (left < bounds.x or top < bounds.y or left + diameter > bounds.right() or top + diameter > bounds.bottom()) return;
    const candidate: Rect = .{ .x = left, .y = top, .w = diameter, .h = diameter };
    const distance = candidate.distanceSquared(mark);
    if (distance >= best.distance or candidate.overlaps(mark)) return;
    for (obstacles) |obstacle| if (candidate.overlaps(obstacle)) return;
    best.* = .{ .result = candidate, .distance = distance };
}

test {
    std.testing.refAllDecls(@This());
}
