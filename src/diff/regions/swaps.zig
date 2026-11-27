//! Recognizes byte-exact row exchanges.

const std = @import("std");
const candidate = @import("candidate.zig");
const bounds = @import("bounds.zig");
const value = @import("../../value.zig");
const pixel = @import("../pixel.zig");
const Box = value.Box;

const max_swap_pitch = value.CssPx.init(128);

/// Puts a byte-exact exchange of two adjacent row bands into one delta.
pub fn mergeSwap(boxes: []candidate.Candidate, moves: []const value.Move, pair: value.Pair, scale: value.Scale) ?usize {
    if (pair.before.width != pair.after.width or pair.before.height != pair.after.height) return null;
    if (moves.len == 1 and boxes.len == 2) return reciprocalMove(boxes, moves[0], pair);
    if (moves.len != 0 or boxes.len < 3 or boxes.len > candidate.max_regions) return null;
    return positionalSwap(boxes, pair, scale.devicePixels(max_swap_pitch));
}

fn reciprocalMove(boxes: []candidate.Candidate, move: value.Move, pair: value.Pair) ?usize {
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
    if (right > pair.before.width or upper + 2 * pitch > pair.before.height or !exchangedRows(pair, cover, pitch, pitch)) return null;
    return candidate.collapse(boxes, cover);
}

fn positionalSwap(boxes: []candidate.Candidate, pair: value.Pair, max_pitch: f64) ?usize {
    var storage: [candidate.max_regions]Box = undefined;
    const stationary = candidate.stationaryBoxes(boxes, &storage) orelse return null;
    var top = stationary[0];
    var whole = top;
    for (stationary[1..]) |box| {
        if (box.y < top.y) top = box;
        whole = candidate.unite(whole, box).?;
    }
    for (stationary) |opposite| {
        const pitch = opposite.y - top.y;
        if (pitch > max_pitch or opposite.x != top.x or
            opposite.width != top.width or opposite.height != top.height) continue;
        const step: usize = bounds.deviceIndex(pitch);
        const rows = whole.height - pitch;
        if (!inSwapBands(stationary, top.y, opposite.y, rows)) continue;
        if (!exchangedRows(pair, whole, step, bounds.deviceIndex(rows))) continue;
        return candidate.collapse(boxes, whole);
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

fn exchangedRows(pair: value.Pair, bands: Box, pitch: usize, rows: usize) bool {
    const x: usize = bounds.deviceIndex(bands.x);
    const right: usize = bounds.deviceIndex(bands.right());
    const first: usize = bounds.deviceIndex(bands.y);
    for (first..first + rows) |y| {
        if (!pixel.sameRun(pair.before.row(y)[x..right], pair.after.row(y + pitch)[x..right]) or
            !pixel.sameRun(pair.after.row(y)[x..right], pair.before.row(y + pitch)[x..right])) return false;
    }
    return true;
}

test "reciprocal row moves are grouped only when both rows exchange intact" {
    const canvas = @import("uidiff_test_canvas").Painters(value.Image);
    const pair = try canvas.RowExchange.init();
    defer pair.deinit();
    const before, const after = .{ pair.before, pair.after };
    const upper, const pitch = .{ canvas.RowExchange.upper, canvas.RowExchange.pitch };
    before.line(22, 212, upper + 10, 4, 60);
    before.line(22, 212, upper + pitch + 10, 9, 60);
    pair.exchange();
    const removed = Box.fromPixels(18, upper + 6, 200, 18);
    const inserted = Box.fromPixels(18, upper + pitch + 6, 200, 18);
    const candidates = [_]candidate.Candidate{
        .{ .region = .{ .before = removed }, .pixels = 8 },
        .{ .region = .{ .after = inserted }, .pixels = 8 },
    };
    const move: value.Move = .{
        .before = .{ .y = upper + pitch, .height = pitch },
        .after = .{ .y = upper, .height = pitch },
        .x = .init(18),
        .width = .init(200),
    };
    var copy = candidates;
    try std.testing.expectEqual(@as(?usize, 1), mergeSwap(&copy, &.{move}, .{ .before = before.view, .after = after.view }, .one));
    try std.testing.expect(copy[0].region.before != null and copy[0].region.after != null);
    after.fill(22, upper + pitch + 11, 7, 7, .{ 180, 18, 36, 255 });
    copy = candidates;
    try std.testing.expectEqual(@as(?usize, null), mergeSwap(&copy, &.{move}, .{ .before = before.view, .after = after.view }, .one));
    try std.testing.expectEqualDeep(candidates, copy);
}

test "audit: a count edit between the exchanged rows remains a separate change" {
    const canvas = @import("uidiff_test_canvas").Painters(value.Image);
    const before = try canvas.Canvas.init(256, 160);
    defer before.deinit();
    const after = try canvas.Canvas.init(256, 160);
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
    var candidates: [boxes.len]candidate.Candidate = undefined;
    for (boxes, &candidates) |box, *entry| entry.* = .{
        .region = .{ .before = box, .after = box },
        .pixels = 8,
    };
    const original = candidates;
    try std.testing.expectEqual(@as(?usize, null), mergeSwap(&candidates, &.{}, .{ .before = before.view, .after = after.view }, .one));
    try std.testing.expectEqualDeep(original, candidates);
}

test {
    std.testing.refAllDecls(@This());
}
