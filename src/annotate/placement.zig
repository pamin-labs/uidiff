//! Shared placement of annotation badges and labels around their marks.
const std = @import("std");

const gap = 6;

/// Finds a label position near its mark within the supplied bounds.
pub fn place(mark: anytype, bounds: @TypeOf(mark), width: f64, height: f64, obstacles: []const @TypeOf(mark)) ?@TypeOf(mark) {
    const reach = 2 * @max(width, height) + gap;
    return placeWithin(mark, bounds, width, height, obstacles, reach * reach);
}

/// Finds an outside spot at any distance, still preferring a nearby badge.
pub fn placeOutside(mark: anytype, bounds: @TypeOf(mark), width: f64, height: f64, obstacles: []const @TypeOf(mark)) ?@TypeOf(mark) {
    return placeWithin(mark, bounds, width, height, obstacles, std.math.inf(f64));
}

fn placeWithin(mark: anytype, bounds: @TypeOf(mark), width: f64, height: f64, obstacles: []const @TypeOf(mark), distance_limit: f64) ?@TypeOf(mark) {
    const max_x = bounds.right() - width;
    const max_y = bounds.bottom() - height;
    if (max_x < bounds.x or max_y < bounds.y) return null;
    const xs = [_]f64{ mark.x, mark.right() - width, mark.x + (mark.width - width) / 2 };
    const ys = [_]f64{ mark.y, mark.bottom() - height, mark.y + (mark.height - height) / 2 };
    const sides_x = [_]f64{ mark.x - width - gap, mark.right() + gap };
    const sides_y = [_]f64{ mark.y - height - gap, mark.bottom() + gap };
    var best: ?@TypeOf(mark) = null;
    var distance = distance_limit;

    for ([_]bool{ false, true }) |clamp_edges| {
        for ([_]bool{ true, false, true, false }, 0..) |vertical, side| {
            if (vertical) {
                const y = if (clamp_edges) std.math.clamp(sides_y[side / 2], bounds.y, max_y) else sides_y[side / 2];
                for (xs) |x| consider(mark, bounds, width, height, std.math.clamp(x, bounds.x, max_x), y, obstacles, &best, &distance);
                for (obstacles) |b| {
                    consider(mark, bounds, width, height, b.x - width - gap, y, obstacles, &best, &distance);
                    consider(mark, bounds, width, height, b.right() + gap, y, obstacles, &best, &distance);
                }
            } else {
                const x = if (clamp_edges) std.math.clamp(sides_x[side / 2], bounds.x, max_x) else sides_x[side / 2];
                for (ys) |y| consider(mark, bounds, width, height, x, std.math.clamp(y, bounds.y, max_y), obstacles, &best, &distance);
                for (obstacles) |b| {
                    consider(mark, bounds, width, height, x, b.y - height - gap, obstacles, &best, &distance);
                    consider(mark, bounds, width, height, x, b.bottom() + gap, obstacles, &best, &distance);
                }
            }
        }
        if (best != null) return best;
    }
    // A crowded mark may only have room diagonally. Look at the edges of
    // the free rectangles, still within the same distance bound.
    const edges = 2 + 2 * obstacles.len;
    for (0..edges) |i| {
        const x = axisEdge(obstacles, i, bounds.x, max_x, width, true);
        for (0..edges) |j| {
            const y = axisEdge(obstacles, j, bounds.y, max_y, height, false);
            consider(mark, bounds, width, height, x, y, obstacles, &best, &distance);
        }
    }
    return best;
}

fn axisEdge(obstacles: anytype, i: usize, min: f64, max: f64, extent: f64, horizontal: bool) f64 {
    if (i < 2) return if (i == 0) min else max;
    const box = obstacles[(i - 2) / 2];
    const start = if (horizontal) box.x else box.y;
    const end = if (horizontal) box.right() else box.bottom();
    return std.math.clamp(if (i % 2 == 0) start - extent else end, min, max);
}

fn consider(mark: anytype, bounds: @TypeOf(mark), width: f64, height: f64, x: f64, y: f64, obstacles: []const @TypeOf(mark), best: *?@TypeOf(mark), distance: *f64) void {
    if (x < bounds.x or y < bounds.y or x + width > bounds.right() or y + height > bounds.bottom()) return;
    const candidate: @TypeOf(mark) = .{ .x = x, .y = y, .width = width, .height = height };
    const distance_sq = candidate.distanceSquared(mark);
    if (distance_sq >= distance.* or candidate.overlap(mark) != 0) return;
    for (obstacles) |obstacle| if (candidate.overlap(obstacle) != 0) return;
    best.* = candidate;
    distance.* = distance_sq;
}
