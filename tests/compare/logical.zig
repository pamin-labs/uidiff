//! Regression scenario for comparison's logical rules.
const std = @import("std");
const uidiff_testing = @import("uidiff_testing");
const expect = uidiff_testing.expect;
const canvas = uidiff_testing.canvas;

test "a compact outline joins edits to its label and value without spanning cards" {
    const before, const after = try canvas.compactCardEdits();
    defer before.deinit();
    defer after.deinit();
    const result = try expect.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.regions.len);
    for ([_]usize{ 52, 286 }) |left| {
        try std.testing.expect(expect.hasRegion(result.regions, .after, left, 46, .changed));
        try std.testing.expect(expect.hasRegion(result.regions, .after, left, 90, .changed));
    }
}
