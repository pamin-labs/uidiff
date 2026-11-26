//! Regression scenario for comparison's moves rules.
const std = @import("std");
const uidiff = @import("uidiff");
const sample = uidiff.testing;
const rules = sample.region_rules;

test "replacement regions suppress enclosed and sub-line displacement" {
    const before = try sample.Canvas.init(120, 140);
    defer before.deinit();
    const after = try sample.Canvas.init(120, 140);
    defer after.deinit();
    before.fill(10, 20, 50, 34, sample.inkShade(32, 4));
    after.fill(10, 20, 50, 34, sample.inkShade(72, 4));
    const result = try sample.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    var moves = [_]uidiff.Move{
        .{ .before = .{ .y = 27, .height = 10 }, .after = .{ .y = 34, .height = 10 }, .x = .init(10), .width = .init(50) },
        .{ .before = .{ .y = 61, .height = 3 }, .after = .{ .y = 70, .height = 3 }, .x = .init(10), .width = .init(50) },
        .{ .before = .{ .y = 62, .height = 10 }, .after = .{ .y = 73, .height = 10 }, .x = .init(10), .width = .init(50) },
        .{ .before = .{ .y = 27, .height = 10 }, .after = .{ .y = 34, .height = 10 }, .x = .init(80), .width = .init(40) },
        .{ .before = .{ .y = 49, .height = 12 }, .after = .{ .y = 50, .height = 12 }, .x = .init(10), .width = .init(50) },
        .{ .before = .{ .y = 4, .height = 125 }, .after = .{ .y = 6, .height = 125 }, .x = .init(10), .width = .init(50) },
    };
    try std.testing.expectEqual(@as(usize, 3), rules.keepMoves(&moves, result.regions, .one, uidiff.Scale.one.devicePixels(rules.scroll_shift)));
    try std.testing.expectEqual(@as(usize, 62), moves[0].before.y);
    try std.testing.expectEqual(@as(usize, 80), moves[1].x.count());
}
