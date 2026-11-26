//! Finds room for annotation badges around overview and detail marks.
const std = @import("std");
const Rect = @import("../geometry.zig").Rect;

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
            const low = if (vertical) low_x else low_y;
            const high = if (vertical) max_x else max_y;
            const cross_low = if (vertical) low_y else low_x;
            const cross_high = if (vertical) max_y else max_x;
            const edge = (if (vertical) sides_y else sides_x)[side / 2];
            const at = if (clamp_edges) std.math.clamp(edge, cross_low, cross_high) else edge;
            for (if (vertical) xs else ys) |point| {
                const along = std.math.clamp(point, low, high);
                considerAcross(mark, bounds, diameter, vertical, along, at, obstacles, &best);
            }
            for (obstacles) |b| {
                const start: isize = @intCast(if (vertical) b.x else b.y);
                const end: isize = @intCast(if (vertical) b.right() else b.bottom());
                considerAcross(mark, bounds, diameter, vertical, start - d - gap, at, obstacles, &best);
                considerAcross(mark, bounds, diameter, vertical, end + gap, at, obstacles, &best);
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

fn considerAcross(mark: Rect, bounds: Rect, diameter: usize, vertical: bool, along: isize, at: isize, obstacles: []const Rect, best: *Search) void {
    const x, const y = if (vertical) .{ along, at } else .{ at, along };
    consider(mark, bounds, diameter, x, y, obstacles, best);
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

test "blocked badge ties preserve top, left, bottom and right probe order" {
    const mark: Rect = .{ .x = 10, .y = 10, .w = 6, .h = 6 };
    const bounds: Rect = .{ .x = 0, .y = 0, .w = 30, .h = 30 };
    const diameter = 4;
    const expected = [_]Rect{
        .{ .x = 10, .y = 0, .w = diameter, .h = diameter },
        .{ .x = 0, .y = 10, .w = diameter, .h = diameter },
        .{ .x = 10, .y = 22, .w = diameter, .h = diameter },
        .{ .x = 22, .y = 10, .w = diameter, .h = diameter },
    };
    const blocked = [_]Rect{
        .{ .x = 0, .y = 0, .w = bounds.w, .h = diameter },
        .{ .x = 0, .y = 0, .w = diameter, .h = bounds.h },
        .{ .x = 0, .y = 22, .w = bounds.w, .h = bounds.h - 22 },
    };
    for (expected, 0..) |spot, n| {
        try std.testing.expectEqual(@as(?Rect, spot), place(mark, bounds, diameter, blocked[0..n]));
    }
}

test {
    std.testing.refAllDecls(@This());
}
