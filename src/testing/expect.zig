//! Assertions for comparison scenarios.
const std = @import("std");
const uidiff = @import("uidiff");
const canvas = @import("uidiff_test_canvas");
const Canvas = canvas.Painters(uidiff.Image).Canvas;

const CompareCheckError = uidiff.CompareError || error{TestExpectedEqual};

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

/// Adds the normal report padding to an expected test box.
pub fn paddedBox(x: usize, y: usize, w: usize, h: usize) uidiff.Box {
    const region_padding = uidiff.region_padding;
    return uidiff.Box.fromPixels(x - region_padding, y - region_padding, w + 2 * region_padding, h + 2 * region_padding);
}

/// Checks region geometry, kind and report numbering in order.
pub fn checkRegions(actual: []const uidiff.Region, expected: []const uidiff.Region) error{TestExpectedEqual}!void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (actual, expected, 1..) |got, want, number| {
        try std.testing.expectEqual(want.before, got.before);
        try std.testing.expectEqual(want.after, got.after);
        try std.testing.expectEqual(number, got.number);
        try std.testing.expectEqual(if (want.before == null) uidiff.Kind.inserted else if (want.after == null) uidiff.Kind.removed else uidiff.Kind.changed, got.kind);
    }
}

/// Compares two procedural canvases at the supplied scale.
pub fn compareCanvases(before: Canvas, after: Canvas, scale: f64) uidiff.CompareError!uidiff.Comparison {
    return uidiff.compare(std.testing.allocator, .{ .before = before.view, .after = after.view }, .{ .scale = .{ .factor = scale } });
}

/// Checks all reported regions against the expected boxes.
pub fn check(before: Canvas, after: Canvas, scale: f64, expected: []const uidiff.Region) CompareCheckError!void {
    const actual = try compareCanvases(before, after, scale);
    defer actual.deinit(std.testing.allocator);
    try checkRegions(actual.regions, expected);
}

/// Checks an insertion and its matching deletion when reversed.
pub fn checkInsertion(before: Canvas, after: Canvas, expected: uidiff.Box) CompareCheckError!void {
    try check(before, after, 1, &.{.{ .after = expected }});
    try check(after, before, 1, &.{.{ .before = expected }});
}

/// Checks the number of reported regions.
pub fn count(before: Canvas, after: Canvas, expected: usize) CompareCheckError!void {
    const actual = try compareCanvases(before, after, 1);
    defer actual.deinit(std.testing.allocator);
    try std.testing.expectEqual(expected, actual.regions.len);
}

test {
    std.testing.refAllDecls(@This());
}
