//! Regression scenario for comparison's logical rules.
const std = @import("std");
const uidiff = @import("uidiff");
const sample = uidiff.testing;
const expect = sample.expect;
const canvases = sample.canvas;

test "a compact outline joins edits to its label and value without spanning cards" {
    const before = try canvases.Canvas.init(480, 164);
    defer before.deinit();
    const after = try canvases.Canvas.init(480, 164);
    defer after.deinit();
    for ([_]canvases.Canvas{ before, after }) |canvas| {
        for ([_]usize{ 20, 254 }) |left| {
            canvas.fill(left, 20, 198, 112, canvases.inkShade(120, 4));
            canvas.fill(left + 2, 22, 194, 108, canvases.inkShade(240, 4));
        }
    }
    for ([_]usize{ 52, 286 }) |left| {
        before.fill(left, 44, 40, 12, canvases.inkShade(64, 4));
        after.fill(left, 44, 56, 12, canvases.inkShade(72, 4));
        before.fill(left, 70, 68, 22, canvases.inkShade(64, 4));
        after.fill(left, 70, 82, 22, canvases.inkShade(72, 4));
    }
    const result = try expect.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.regions.len);
    for ([_]usize{ 52, 286 }) |left| {
        try std.testing.expect(expect.hasRegion(result.regions, .after, left, 46, .changed));
        try std.testing.expect(expect.hasRegion(result.regions, .after, left, 90, .changed));
    }
}
