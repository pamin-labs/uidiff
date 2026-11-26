//! Assertions for comparison scenarios.
const std = @import("std");
const uidiff = @import("../root.zig");
const canvas = @import("canvas.zig");
const Canvas = canvas.Canvas;

/// Checks that a reported region of the requested kind covers a test point.
pub fn hasRegion(found: []const uidiff.Region, side: uidiff.Side, x: usize, y: usize, kind: ?uidiff.Kind) bool {
    const px: f64 = @floatFromInt(x);
    const py: f64 = @floatFromInt(y);
    for (found) |region| {
        if (kind != null and kind != region.kind) continue;
        const box = (if (side == .before) region.before else region.after) orelse continue;
        if (box.x <= px and box.right() > px and box.y <= py and box.bottom() > py) return true;
    }
    return false;
}

/// Finds a two-sided mark that excludes the body of a nearby edit.
pub fn hasSeparateMark(found: []const uidiff.Region, x: usize, y: usize, body_x: usize, body_y: usize) bool {
    if (!hasRegion(found, .after, body_x, body_y, null)) return false;
    for (found, 0..) |_, index| {
        const mark = found[index..][0..1];
        if (hasRegion(mark, .before, x, y, null) and hasRegion(mark, .after, x, y, null) and
            !hasRegion(mark, .after, body_x, body_y, null)) return true;
    }
    return false;
}

/// Adds the normal report padding to an expected test box.
pub fn paddedBox(x: usize, y: usize, w: usize, h: usize) uidiff.Box {
    const region_padding = uidiff.region_padding;
    return uidiff.Box.fromPixels(x - region_padding, y - region_padding, w + 2 * region_padding, h + 2 * region_padding);
}

/// Checks region geometry, kind and report numbering in order.
pub fn checkRegions(actual: []const uidiff.Region, expected: []const uidiff.Region) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (actual, expected, 1..) |got, want, number| {
        try std.testing.expectEqual(want.before, got.before);
        try std.testing.expectEqual(want.after, got.after);
        try std.testing.expectEqual(number, got.number);
        try std.testing.expectEqual(if (want.before == null) uidiff.Kind.inserted else if (want.after == null) uidiff.Kind.removed else uidiff.Kind.changed, got.kind);
    }
}

/// Checks that an edit is reported within the expected width.
pub fn expectEditAt(before: Canvas, after: Canvas, x: usize, y: usize, max_box_width: usize) !void {
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    for (result.regions) |region| {
        const box = region.after orelse continue;
        if (box.x <= @as(f64, @floatFromInt(x)) and box.right() > @as(f64, @floatFromInt(x)) and
            box.y <= @as(f64, @floatFromInt(y)) and box.bottom() > @as(f64, @floatFromInt(y)))
        {
            try std.testing.expect(box.width <= @as(f64, @floatFromInt(max_box_width)));
            return;
        }
    }
    return error.MissingEdit;
}

/// Compares two procedural canvases at the supplied scale.
pub fn compareCanvases(before: Canvas, after: Canvas, scale: f64) uidiff.CompareError!uidiff.Comparison {
    return uidiff.compare(std.testing.allocator, before.view, after.view, .{ .scale = .{ .factor = scale } });
}

/// Checks all reported regions against the expected boxes.
pub fn check(before: Canvas, after: Canvas, scale: f64, expected: []const uidiff.Region) !void {
    const actual = try compareCanvases(before, after, scale);
    defer actual.deinit(std.testing.allocator);
    try checkRegions(actual.regions, expected);
}

/// Checks an insertion and its matching deletion when reversed.
pub fn checkInsertion(before: Canvas, after: Canvas, expected: uidiff.Box) !void {
    try check(before, after, 1, &.{.{ .after = expected }});
    try check(after, before, 1, &.{.{ .before = expected }});
}

/// Checks the number of reported regions.
pub fn count(before: Canvas, after: Canvas, expected: usize) !void {
    const actual = try compareCanvases(before, after, 1);
    defer actual.deinit(std.testing.allocator);
    try std.testing.expectEqual(expected, actual.regions.len);
}

/// Checks the insertion fixture using the allocator supplied by the failure runner.
pub fn comparePair(allocator: std.mem.Allocator, before: uidiff.Image, after: uidiff.Image) !void {
    const result = try uidiff.compare(allocator, before, after, .{});
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expectEqual(uidiff.Kind.inserted, result.regions[0].kind);
}
