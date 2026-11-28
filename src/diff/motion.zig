//! Records row and column moves supported by the alignment.
const std = @import("std");
const value = @import("../value.zig");
const columns = @import("columns.zig");
const rows = @import("rows.zig");
const Allocator = std.mem.Allocator;
const Scope = columns.Scope;

const min_column_motion_rows = 4;
const column_motion_scroll_factor = 2;

/// Keeps only column moves with enough displaced content.
pub fn gatherColumnMoves(allocator: Allocator, moves: *std.ArrayList(value.Move), scope: Scope, bands: []const rows.Band, keys: []const u64, limit: usize) Allocator.Error!bool {
    const first = moves.items.len;
    try gatherMoves(allocator, moves, scope, bands);
    var kept = first;
    for (moves.items[first..]) |move| {
        if (move.shift() <= limit or !columnMotion(scope, keys, move, limit)) continue;
        moves.items[kept] = move;
        kept += 1;
    }
    moves.items.len = kept;
    return kept != first;
}

/// Records aligned rows and expands moves to supported card edges.
pub fn gatherMoves(allocator: Allocator, moves: *std.ArrayList(value.Move), scope: Scope, bands: []const rows.Band) Allocator.Error!void {
    const span = scope.span;
    const first = moves.items.len;
    var previous: ?usize = null;
    for (bands, 0..) |band, i| {
        var height = @min(band.removed, band.added);
        if (height == 0 or band.before == band.after) {
            previous = null;
            continue;
        }
        if (i + 1 < bands.len) {
            const next = bands[i + 1];
            height += @min(next.before -| (band.before + band.removed), next.after -| (band.after + band.added));
        }
        if (previous) |index| {
            const move = &moves.items[index];
            if (move.before.y + move.before.height == band.before and move.after.y + move.after.height == band.after) {
                move.before.height += height;
                move.after.height += height;
                continue;
            }
        }
        previous = moves.items.len;
        try moves.append(allocator, .{
            .before = .{ .y = band.before, .height = height },
            .after = .{ .y = band.after, .height = height },
            .x = span.left,
            .width = span.width,
        });
    }
    var kept = first;
    for (moves.items[first..]) |move| {
        if (columns.blankBand(scope.pair.before, move.before.y, move.before.height, span) and
            columns.blankBand(scope.pair.after, move.after.y, move.after.height, span)) continue;
        var full = move;
        const pitch = move.shift();
        if (columns.enclosingCard(scope.pair.before, span, scope.frame orelse scope.bounds, move.before.y, columns.CardSearch.motion(span, pitch))) |card| {
            full.x = card.x;
            full.width = card.width;
        }
        moves.items[kept] = full;
        kept += 1;
    }
    moves.items.len = kept;
}

fn columnMotion(scope: Scope, keys: []const u64, move: value.Move, scroll_limit_px: usize) bool {
    // A matching edge that remains at its old position gives no evidence
    // that the column moved. Require several content rows at the new offset.
    const before = keys[0..scope.pair.before.height];
    const after = keys[scope.pair.before.height..];
    const minimum: usize = @max(min_column_motion_rows, column_motion_scroll_factor * scroll_limit_px);
    var supported: usize = 0;
    for (0..move.before.height) |i| {
        const old = move.before.y + i;
        const new = move.after.y + i;
        if (before[old] != after[new] or (old < after.len and before[old] == after[old]) or columns.blankBand(scope.pair.before, old, 1, scope.span)) continue;
        supported += 1;
        if (supported == minimum) return true;
    }
    return false;
}

test "an aligned blank tail contributes no phantom move" {
    const canvas = @import("uidiff_test_canvas").Painters(value.Image);
    const before = try canvas.Canvas.init(64, 32);
    defer before.deinit();
    const after = try canvas.Canvas.init(64, 64);
    defer after.deinit();
    const span: columns.Span = .{ .left = 0, .width = 64 };
    const scope: columns.Scope = .{ .pair = .{ .before = before.view, .after = after.view }, .span = span, .bounds = span };
    const band: rows.Band = .{ .before = 26, .after = 58, .removed = 6, .added = 6 };
    var moves: std.ArrayList(value.Move) = .empty;
    defer moves.deinit(std.testing.allocator);
    try gatherMoves(std.testing.allocator, &moves, scope, &.{band});
    try std.testing.expectEqual(@as(usize, 0), moves.items.len);
    before.fill(3, 28, 8, 2, canvas.inkShade(70, 4));
    after.fill(3, 60, 8, 2, canvas.inkShade(70, 4));
    try gatherMoves(std.testing.allocator, &moves, scope, &.{band});
    try std.testing.expectEqual(@as(usize, 1), moves.items.len);
}

test {
    std.testing.refAllDecls(@This());
}
