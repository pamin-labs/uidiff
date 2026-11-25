//! Retains visible moves outside reported edits.

const std = @import("std");
const pending = @import("candidate.zig");
const values = @import("../../value.zig");
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

test {
    std.testing.refAllDecls(@This());
}
