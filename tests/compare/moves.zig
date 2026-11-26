//! Regression scenario for comparison's moves rules.
const std = @import("std");
const uidiff = @import("uidiff");
const uidiff_testing = @import("uidiff_testing");
const expect = uidiff_testing.expect;
const canvas = uidiff_testing.canvas;

test "replacement regions suppress enclosed and sub-line displacement" {
    const before = try canvas.Canvas.init(120, 140);
    defer before.deinit();
    const after = try canvas.Canvas.init(120, 140);
    defer after.deinit();
    before.fill(10, 20, 50, 34, canvas.inkShade(32, 4));
    after.fill(10, 20, 50, 34, canvas.inkShade(72, 4));
    const result = try expect.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expectEqual(@as(usize, 0), result.moves.len);
}
