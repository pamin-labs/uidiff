//! Regression scenario for comparison's logical rules.
const std = @import("std");
const uidiff = @import("uidiff");
const sample = uidiff.testing;
const rules = sample.region_rules;

test "a compact outline joins edits to its label and value without spanning cards" {
    const before = try sample.Canvas.init(480, 164);
    defer before.deinit();
    const after = try sample.Canvas.init(480, 164);
    defer after.deinit();
    for ([_]sample.Canvas{ before, after }) |canvas| {
        for ([_]usize{ 20, 254 }) |left| {
            canvas.fill(left, 20, 198, 112, sample.inkShade(120, 4));
            canvas.fill(left + 2, 22, 194, 108, sample.inkShade(240, 4));
        }
    }
    for ([_]usize{ 52, 286 }) |left| {
        before.fill(left, 44, 40, 12, sample.inkShade(64, 4));
        after.fill(left, 44, 56, 12, sample.inkShade(72, 4));
        before.fill(left, 70, 68, 22, sample.inkShade(64, 4));
        after.fill(left, 70, 82, 22, sample.inkShade(72, 4));
    }
    const result = try sample.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.regions.len);
    for ([_]usize{ 52, 286 }) |left| {
        try std.testing.expect(sample.hasRegion(result.regions, .after, left, 46, .changed));
        try std.testing.expect(sample.hasRegion(result.regions, .after, left, 90, .changed));
    }
    const label = uidiff.Box.fromPixels(52, 44, 56, 12);
    const value = uidiff.Box.fromPixels(52, 70, 82, 22);
    var candidates = [_]rules.Candidate{
        .{ .region = .{ .before = label, .after = label }, .pixels = 4 },
        .{ .region = .{ .before = value, .after = value }, .pixels = 4 },
    };
    var moves = [_]uidiff.Move{.{
        .before = .{ .y = 56, .height = 32 },
        .after = .{ .y = 74, .height = 32 },
        .x = .init(160),
        .width = .init(24),
    }};
    const len = rules.mergeLogical(&candidates, before.view, after.view, .one, &moves);
    var edits: [candidates.len]uidiff.Region = undefined;
    for (edits[0..len], candidates[0..len]) |*edit, candidate| edit.* = candidate.region;
    try std.testing.expectEqual(@as(usize, 1), rules.keepMoves(&moves, edits[0..len], .one, uidiff.Scale.one.devicePixels(rules.scroll_shift)));
}
