//! Retains visible moves outside reported edits.

const std = @import("std");
const candidate = @import("candidate.zig");
const value = @import("../../value.zig");
const Scale = value.Scale;
const Box = value.Box;
const Region = value.Region;

const min_move_height = value.CssPx.init(4);
/// Maximum displacement treated as a short scroll.
pub const scroll_shift = value.CssPx.init(2);

/// Compacts moves to visible runs outside the reported edits.
pub fn keepMoves(moves: []value.Move, edits: []const Region, scale: value.Scale, scroll_tolerance: f64) usize {
    const minimum = scale.devicePixels(min_move_height);
    const slack = scale.devicePixels(candidate.padding);
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

fn insideEdit(move: value.Move, edits: []const Region, slack: f64, short_shift: bool) bool {
    for (edits) |edit| {
        const before = edit.before orelse continue;
        const after = edit.after orelse continue;
        if (containsMove(before, move.before, move, slack, short_shift) and
            containsMove(after, move.after, move, slack, short_shift)) return true;
    }
    return false;
}

fn containsMove(box: Box, rows: value.RowRange, move: value.Move, slack: f64, short_shift: bool) bool {
    const top: f64 = @floatFromInt(rows.y);
    const bottom: f64 = @floatFromInt(rows.y + rows.height);
    const left: f64 = @floatFromInt(move.x);
    const right: f64 = @floatFromInt(move.x + move.width);
    if (left >= box.right() or right <= box.x) return false;
    // Sub-scroll offsets at an edited edge can extend into the next
    // alignment band. The edit still explains their overlapping rows.
    if (short_shift) {
        const overlap = @min(bottom, box.bottom() + slack) - @max(top, box.y - slack);
        return 2 * overlap > bottom - top;
    }
    return top >= box.y - slack and bottom <= box.bottom() + slack;
}

test {
    const box = Box.fromPixels(6, 16, 58, 42);
    const edits = [_]Region{.{ .number = 1, .before = box, .after = box }};
    var moves = [_]value.Move{
        .{ .before = .{ .y = 27, .height = 10 }, .after = .{ .y = 34, .height = 10 }, .x = 10, .width = 50 },
        .{ .before = .{ .y = 61, .height = 3 }, .after = .{ .y = 70, .height = 3 }, .x = 10, .width = 50 },
        .{ .before = .{ .y = 62, .height = 10 }, .after = .{ .y = 73, .height = 10 }, .x = 10, .width = 50 },
        .{ .before = .{ .y = 27, .height = 10 }, .after = .{ .y = 34, .height = 10 }, .x = 80, .width = 40 },
        .{ .before = .{ .y = 49, .height = 12 }, .after = .{ .y = 50, .height = 12 }, .x = 10, .width = 50 },
        .{ .before = .{ .y = 4, .height = 125 }, .after = .{ .y = 6, .height = 125 }, .x = 10, .width = 50 },
    };
    try std.testing.expectEqual(@as(usize, 3), keepMoves(&moves, &edits, .one, Scale.one.devicePixels(scroll_shift)));
    try std.testing.expectEqual(@as(usize, 62), moves[0].before.y);
    try std.testing.expectEqual(@as(usize, 80), moves[1].x);
}

test {
    std.testing.refAllDecls(@This());
}
