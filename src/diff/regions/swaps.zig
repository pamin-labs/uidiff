//! Recognizes byte-exact row exchanges.

const std = @import("std");
const pending = @import("candidate.zig");
const bounds = @import("bounds.zig");
const values = @import("../../value.zig");
const pixel = @import("../pixel.zig");
const Box = values.Box;
const Image = values.Image;

const max_swap_pitch = values.CssPx.init(128);

/// Puts a byte-exact exchange of two adjacent row bands into one delta.
pub fn mergeSwap(boxes: []pending.Candidate, moves: []const values.Move, before: Image, after: Image, scale: values.Scale) ?usize {
    if (before.width != after.width or before.height != after.height) return null;
    if (moves.len == 1 and boxes.len == 2) return reciprocalMove(boxes, moves[0], before, after);
    if (moves.len != 0 or boxes.len < 3 or boxes.len > pending.max_regions) return null;
    return positionalSwap(boxes, before, after, scale.devicePixels(max_swap_pitch));
}

fn reciprocalMove(boxes: []pending.Candidate, move: values.Move, before: Image, after: Image) ?usize {
    const old, const new = if (boxes[0].region.before != null)
        .{ boxes[0].region, boxes[1].region }
    else
        .{ boxes[1].region, boxes[0].region };
    const removed = old.before orelse return null;
    const inserted = new.after orelse return null;
    if (old.after != null or new.before != null) return null;
    const pitch = move.shift();
    if (pitch == 0 or move.before.height != pitch or move.after.height != pitch) return null;
    const x: usize = @min(move.x.count(), @as(usize, bounds.deviceIndex(@min(removed.x, inserted.x))));
    const right: usize = @max(move.x.count() + move.width.count(), @as(usize, bounds.deviceIndex(@max(removed.right(), inserted.right()))));
    const upper = @min(move.before.y, move.after.y);
    const cover = Box.fromPixels(x, upper, right - x, 2 * pitch);
    if (cover.overlap(removed) != removed.width * removed.height or cover.overlap(inserted) != inserted.width * inserted.height) return null;
    if (right > before.width or upper + 2 * pitch > before.height or !exchangedRows(before, after, cover, pitch, pitch)) return null;
    return pending.collapse(boxes, cover);
}

fn positionalSwap(boxes: []pending.Candidate, before: Image, after: Image, max_pitch: f64) ?usize {
    var storage: [pending.max_regions]Box = undefined;
    const stationary = pending.stationaryBoxes(boxes, &storage) orelse return null;
    var top = stationary[0];
    var whole = top;
    for (stationary[1..]) |box| {
        if (box.y < top.y) top = box;
        whole = pending.unite(whole, box).?;
    }
    for (stationary) |opposite| {
        const pitch = opposite.y - top.y;
        if (pitch > max_pitch or opposite.x != top.x or
            opposite.width != top.width or opposite.height != top.height) continue;
        const step: usize = bounds.deviceIndex(pitch);
        const rows = whole.height - pitch;
        if (!inSwapBands(stationary, top.y, opposite.y, rows)) continue;
        if (!exchangedRows(before, after, whole, step, bounds.deviceIndex(rows))) continue;
        return pending.collapse(boxes, whole);
    }
    return null;
}

fn inSwapBands(boxes: []const Box, upper: f64, lower: f64, height: f64) bool {
    if (height <= 0 or upper + height > lower) return false;
    for (boxes) |box| {
        const start = if (box.y < lower) upper else lower;
        if (box.y < start or box.bottom() > start + height) return false;
    }
    return true;
}

fn exchangedRows(before: Image, after: Image, bands: Box, pitch: usize, rows: usize) bool {
    const x: usize = bounds.deviceIndex(bands.x);
    const right: usize = bounds.deviceIndex(bands.right());
    const first: usize = bounds.deviceIndex(bands.y);
    for (first..first + rows) |y| {
        if (!pixel.sameRun(before.row(y)[x..right], after.row(y + pitch)[x..right]) or
            !pixel.sameRun(after.row(y)[x..right], before.row(y + pitch)[x..right])) return false;
    }
    return true;
}

test "reciprocal row moves are grouped only when both rows exchange intact" {
    const sample = @import("../test_support.zig");
    const pair = try sample.RowExchange.init();
    defer pair.deinit();
    const before, const after = .{ pair.before, pair.after };
    const upper, const pitch = .{ sample.RowExchange.upper, sample.RowExchange.pitch };
    before.line(22, 212, upper + 10, 4, 60);
    before.line(22, 212, upper + pitch + 10, 9, 60);
    pair.exchange();
    const removed = Box.fromPixels(18, upper + 6, 200, 18);
    const inserted = Box.fromPixels(18, upper + pitch + 6, 200, 18);
    const candidates = [_]pending.Candidate{
        .{ .region = .{ .before = removed }, .pixels = 8 },
        .{ .region = .{ .after = inserted }, .pixels = 8 },
    };
    const move: values.Move = .{
        .before = .{ .y = upper + pitch, .height = pitch },
        .after = .{ .y = upper, .height = pitch },
        .x = .init(18),
        .width = .init(200),
    };
    var copy = candidates;
    try std.testing.expectEqual(@as(?usize, 1), mergeSwap(&copy, &.{move}, before.view, after.view, .one));
    try std.testing.expect(copy[0].region.before != null and copy[0].region.after != null);
    after.fill(22, upper + pitch + 11, 7, 7, .{ 180, 18, 36, 255 });
    copy = candidates;
    try std.testing.expectEqual(@as(?usize, null), mergeSwap(&copy, &.{move}, before.view, after.view, .one));
    try std.testing.expectEqualDeep(candidates, copy);
}

test "audit: a count edit between the exchanged rows remains a separate change" {
    const sample = @import("../test_support.zig");
    const before = try sample.Canvas.init(256, 160);
    defer before.deinit();
    const after = try sample.Canvas.init(256, 160);
    defer after.deinit();
    before.line(24, 160, 40, 1, 62);
    before.line(94, 145, 80, 3, 62);
    before.line(24, 160, 120, 7, 62);
    after.copyRows(40, before, 120, 134);
    after.copyRows(120, before, 40, 54);
    after.line(94, 145, 80, 4, 62);
    const boxes = [_]Box{
        Box.fromPixels(24, 40, 136, 14),
        Box.fromPixels(94, 80, 51, 14),
        Box.fromPixels(24, 120, 136, 14),
    };
    var candidates: [boxes.len]pending.Candidate = undefined;
    for (boxes, &candidates) |box, *candidate| candidate.* = .{
        .region = .{ .before = box, .after = box },
        .pixels = 8,
    };
    const original = candidates;
    try std.testing.expectEqual(@as(?usize, null), mergeSwap(&candidates, &.{}, before.view, after.view, .one));
    try std.testing.expectEqualDeep(original, candidates);
}

test {
    std.testing.refAllDecls(@This());
}
