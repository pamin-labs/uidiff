//! Retains visible moves outside reported edits.

const std = @import("std");
const pending = @import("candidate.zig");
const values = @import("../../value.zig");
const sample = @import("../test_support.zig");
const Scale = values.Scale;
const Box = values.Box;
const Region = values.Region;

const min_move_height = values.CssPx.init(4);

/// Compacts moves to visible runs outside the reported edits.
pub fn keepMoves(moves: []values.Move, edits: []const Region, scale: values.Scale, scroll_tolerance: f64) usize {
    const minimum = scale.devicePixels(min_move_height);
    const slack = scale.devicePixels(pending.padding);
    var len: usize = 0;
    for (moves) |move| {
        if (@as(f64, @floatFromInt(move.before.height)) < minimum) continue;
        const shift: f64 = @floatFromInt(move.shift());
        if (insideEdit(move, edits, slack, shift <= scroll_tolerance)) continue;
        moves[len] = move;
        len += 1;
    }
    return len;
}

fn insideEdit(move: values.Move, edits: []const Region, slack: f64, short_shift: bool) bool {
    for (edits) |edit| {
        const before = edit.before orelse continue;
        const after = edit.after orelse continue;
        if (containsMove(before, move.before, move, slack, short_shift) and
            containsMove(after, move.after, move, slack, short_shift)) return true;
    }
    return false;
}

fn containsMove(box: Box, rows: values.RowRange, move: values.Move, slack: f64, short_shift: bool) bool {
    const top: f64 = @floatFromInt(rows.y);
    const bottom: f64 = @floatFromInt(rows.y + rows.height);
    const left: f64 = @floatFromInt(move.x.count());
    const right: f64 = @floatFromInt(move.x.count() + move.width.count());
    if (left >= box.right() or right <= box.x) return false;
    // Sub-scroll offsets at an edited edge can extend into the next
    // alignment band. The edit still explains their overlapping rows.
    if (short_shift) {
        const overlap = @min(bottom, box.bottom() + slack) - @max(top, box.y - slack);
        return 2 * overlap > bottom - top;
    }
    return top >= box.y - slack and bottom <= box.bottom() + slack;
}

test "replacement regions suppress enclosed and sub-line displacement" {
    const rows = @import("../rows.zig");
    const before = try sample.Canvas.init(120, 140);
    defer before.deinit();
    const after = try sample.Canvas.init(120, 140);
    defer after.deinit();
    before.fill(10, 20, 50, 34, sample.inkShade(32, 4));
    after.fill(10, 20, 50, 34, sample.inkShade(72, 4));
    const result = try sample.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    var moves = [_]values.Move{
        .{ .before = .{ .y = 27, .height = 10 }, .after = .{ .y = 34, .height = 10 }, .x = .init(10), .width = .init(50) },
        .{ .before = .{ .y = 61, .height = 3 }, .after = .{ .y = 70, .height = 3 }, .x = .init(10), .width = .init(50) },
        .{ .before = .{ .y = 62, .height = 10 }, .after = .{ .y = 73, .height = 10 }, .x = .init(10), .width = .init(50) },
        .{ .before = .{ .y = 27, .height = 10 }, .after = .{ .y = 34, .height = 10 }, .x = .init(80), .width = .init(40) },
        .{ .before = .{ .y = 49, .height = 12 }, .after = .{ .y = 50, .height = 12 }, .x = .init(10), .width = .init(50) },
        .{ .before = .{ .y = 4, .height = 125 }, .after = .{ .y = 6, .height = 125 }, .x = .init(10), .width = .init(50) },
    };
    try std.testing.expectEqual(@as(usize, 3), keepMoves(&moves, result.regions, .one, Scale.one.devicePixels(rows.scroll_shift)));
    try std.testing.expectEqual(@as(usize, 62), moves[0].before.y);
    try std.testing.expectEqual(@as(usize, 80), moves[1].x.count());
}

test {
    std.testing.refAllDecls(@This());
}
