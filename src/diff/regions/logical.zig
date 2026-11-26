//! Joins stacked, shifted and tightly enclosed parts of a visible edit.

const std = @import("std");
const pending = @import("candidate.zig");
const bounds = @import("bounds.zig");
const text_lines = @import("text_lines.zig");
const values = @import("../../value.zig");
const pixel = @import("../pixel.zig");
const column_bounds = @import("../columns.zig");
const Scale = values.Scale;
const Box = values.Box;
const Region = values.Region;
const Image = values.Image;

const stack_overlap = 0.5;

const sideways_explained_percent = 90;

const sideways_agreement_percent = 98;

const percent_scale = 100;

const stack_gap = values.CssPx.init(20);

// Only compact cards can connect vertically separated marks. A wide panel
// or a tall list can contain multiple unrelated rows.
const compact_card_height = values.CssPx.init(128);

const compact_card_width = values.CssPx.init(360);

// Bound outline work across merge restarts.
const max_card_probes = pending.max_regions * pending.max_regions;

const card_corner_reach = values.CssPx.init(20);

const blank_tolerance = 24;

const max_sideways_shift = 256;

const shift_samples = 9;

const shift_columns = 512;

const shift_min_pixels = 16;

/// Joins the retained boxes that together describe a single visible edit.
pub noinline fn mergeLogical(boxes: []pending.Candidate, before: Image, after: Image, scale: values.Scale, moves: []const values.Move) usize {
    var len = boxes.len;
    var card_probes: usize = if (moves.len == 0) max_card_probes else 0;
    var i: usize = 0;
    while (i < len) {
        var j = i + 1;
        while (j < len) {
            const a = boxes[i].region;
            const b = boxes[j].region;
            const related = text_lines.sameLine(a, b, before, after, scale.devicePixels(text_lines.line_height)) or
                stacked(a, b, before, after, scale.devicePixels(stack_gap)) or
                shiftedSideways(a, b, before, after);
            const card = if (related or card_probes == 0) null else card: {
                card_probes -= 1;
                break :card commonCard(a, b, before, after, scale);
            };
            if (!related and card == null) {
                j += 1;
                continue;
            }
            len = pending.join(boxes, len, i, j);
            if (card) |box| {
                boxes[i].region.before = box;
                boxes[i].region.after = box;
                len = removeCardParts(boxes[0..len], i, box);
            }
            i = 0;
            j = 1;
        }
        i += 1;
    }
    return len;
}

noinline fn commonCard(a: Region, b: Region, before: Image, after: Image, scale: values.Scale) ?Box {
    const p = a.before orelse return null;
    const q = b.before orelse return null;
    const r = a.after orelse return null;
    const s = b.after orelse return null;
    if (!std.meta.eql(p, r) or !std.meta.eql(q, s)) return null;
    const overlap = @min(p.right(), q.right()) - @max(p.x, q.x);
    const gap_px = @max(p.y, q.y) - @min(p.bottom(), q.bottom());
    if (overlap <= 0 or gap_px < 0 or gap_px > scale.devicePixels(stack_gap)) return null;
    const ink = pending.unite(p, q).?;
    const max_height = scale.devicePixels(compact_card_height);
    const max_width = scale.devicePixels(compact_card_width);
    if (ink.height >= max_height or ink.width >= max_width) return null;
    const span: column_bounds.Span = .{ .left = bounds.deviceIndex(ink.x), .width = bounds.deviceIndex(ink.width) };
    const y: usize = bounds.deviceIndex(ink.y);
    const search = column_bounds.CardSearch.compact(span, max_height, scale.devicePixels(card_corner_reach));
    const old_card = column_bounds.enclosingCard(before, span, .{ .left = 0, .width = before.width }, y, search) orelse return null;
    if (old_card.top + old_card.height < @as(usize, bounds.deviceIndex(ink.bottom())) or
        @as(f64, @floatFromInt(old_card.columns.width)) > max_width) return null;
    const new_card = column_bounds.enclosingCard(after, span, .{ .left = 0, .width = after.width }, y, search) orelse return null;
    if (!std.meta.eql(old_card, new_card)) return null;
    return Box.fromPixels(old_card.columns.left, old_card.top, old_card.columns.width, old_card.height);
}

fn removeCardParts(boxes: []pending.Candidate, card: usize, cover: Box) usize {
    var len: usize = 0;
    for (boxes, 0..) |part, index| {
        if (index != card) {
            if (part.region.before) |old| if (part.region.after) |new| {
                const same_position = std.meta.eql(old, new);
                if (same_position and cover.overlap(old) == old.width * old.height) continue;
            };
        }
        boxes[len] = part;
        len += 1;
    }
    return len;
}

fn stacked(a: Region, b: Region, before: Image, after: Image, max_gap_px: f64) bool {
    if ((a.before == null) != (b.before == null) or (a.after == null) != (b.after == null)) return false;
    if (a.before != null and a.after != null) return false;
    const p = a.before orelse a.after orelse return false;
    const q = b.before orelse b.after orelse return false;
    const image = if (a.before != null) before else after;
    const shared = @min(p.right(), q.right()) - @max(p.x, q.x);
    if (shared < stack_overlap * @min(p.width, q.width)) return false;
    const upper, const lower = if (p.y <= q.y) .{ p, q } else .{ q, p };
    const gap_px = lower.y - upper.bottom();
    if (gap_px > max_gap_px) return false;
    if (gap_px <= 0) return true;
    // The collector has already bounded these whole pixel boxes to their image.
    const left: usize = bounds.deviceIndex(@min(p.x, q.x));
    const right: usize = bounds.deviceIndex(@max(p.right(), q.right()));
    // Edge coverage can finish one row beyond the component bounds.
    const first: usize = bounds.deviceIndex(upper.bottom() + 1);
    const end: usize = bounds.deviceIndex(@max(upper.bottom() + 1, lower.y - 1));
    for (first..end) |y| {
        const row = image.row(y)[left..right];
        for (row[1..]) |p_ink| {
            for (0..3) |c| {
                if (@abs(@as(i16, p_ink[c]) - @as(i16, row[0][c])) > blank_tolerance) return false;
            }
        }
    }
    return true;
}

noinline fn shiftedSideways(a: Region, b: Region, before: Image, after: Image) bool {
    const p = a.before orelse return false;
    const q = b.before orelse return false;
    const pa = a.after orelse return false;
    const qa = b.after orelse return false;
    if (@abs(p.y - q.y) > 1 or @abs(p.bottom() - q.bottom()) > 1 or p.y != pa.y or q.y != qa.y) return false;
    // The collector has already bounded these whole pixel boxes to their image.
    const left: usize = bounds.deviceIndex(@min(p.x, q.x));
    const right: usize = bounds.deviceIndex(@min(@max(p.right(), q.right()), @as(f64, @floatFromInt(@min(before.width, after.width)))));
    const top: usize = bounds.deviceIndex(@min(p.y, q.y));
    const height: usize = bounds.deviceIndex(@max(p.bottom(), q.bottom()) - @as(f64, @floatFromInt(top)));
    if (right <= left + 2 or height == 0 or top + height > @min(before.height, after.height)) return false;
    const reach: usize = bounds.deviceIndex(@min(max_sideways_shift, @max(p.width, q.width)));
    const count: usize = @min(shift_samples, height);
    for (1..reach + 1) |distance| {
        for ([_]bool{ false, true }) |rightward| {
            const start = if (rightward) @max(left, distance) else left;
            const end = if (rightward) right else @min(right, before.width -| distance);
            if (start >= end) continue;
            const from = if (rightward) left -| distance else left + distance;
            const stride: usize = 1 + (end - start - 1) / shift_columns;
            const middle = shiftEvidence(before.row(top + height / 2), after.row(top + height / 2), start, end, from, stride);
            if (2 * middle.explained < middle.changed or middle.same == 0) continue;
            var seen: usize = 0;
            var same: usize = 0;
            var changed: usize = 0;
            var explained: usize = 0;
            for (0..count) |i| {
                const y = top + (2 * i + 1) * height / (2 * count);
                const row = shiftEvidence(before.row(y), after.row(y), start, end, from, stride);
                seen += 1 + (end - start - 1) / stride;
                same += row.same;
                changed += row.changed;
                explained += row.explained;
            }
            if (changed >= shift_min_pixels and percent_scale * explained >= sideways_explained_percent * changed and percent_scale * same >= sideways_agreement_percent * seen) return true;
        }
    }
    return false;
}

noinline fn shiftEvidence(old: []const values.Pixel, new: []const values.Pixel, start: usize, end: usize, from: usize, stride: usize) struct { changed: usize, explained: usize, same: usize } {
    const original = old[start..end];
    const shifted = old[from..][0..original.len];
    const current = new[start..end];
    var same: usize = 0;
    var changed: usize = 0;
    var explained: usize = 0;
    var i: usize = 0;
    while (i < current.len) : (i += stride) {
        const match = pixel.same(current[i], shifted[i]);
        const different = !pixel.same(current[i], original[i]);
        same += @intFromBool(match);
        changed += @intFromBool(different);
        explained += @intFromBool(different and match);
    }
    return .{ .changed = changed, .explained = explained, .same = same };
}

test "one-sided stacks join across a blank seam but keep painted rows separate" {
    const width = 55;
    const height = 52;
    const paper: values.Pixel = @splat(255);
    const ink: values.Pixel = .{ 80, 90, 140, 255 };
    var pixels: [width * height]values.Pixel = @splat(paper);
    for (4..12) |y| @memset(pixels[y * width + 4 ..][0..36], ink);
    for (29..44) |y| @memset(pixels[y * width + 6 ..][0..36], ink);
    const image: Image = .{ .width = width, .height = height, .pixels = &pixels };
    const parts = [_]pending.Candidate{
        .{ .region = .{ .after = Box.fromPixels(4, 4, 36, 8) }, .pixels = 288 },
        .{ .region = .{ .after = Box.fromPixels(6, 29, 36, 15) }, .pixels = 540 },
    };
    var boxes = parts;
    try std.testing.expectEqual(@as(usize, 1), mergeLogical(&boxes, image, image, .one, &.{}));
    boxes = parts;
    pixels[20 * width + 20] = ink;
    try std.testing.expectEqual(@as(usize, 2), mergeLogical(&boxes, image, image, .one, &.{}));
}

test "a compact outline joins edits to its label and value without spanning cards" {
    const sample = @import("../../testing.zig");
    const move_rules = @import("moves.zig");
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
    const label = Box.fromPixels(52, 44, 56, 12);
    const value = Box.fromPixels(52, 70, 82, 22);
    var candidates = [_]pending.Candidate{
        .{ .region = .{ .before = label, .after = label }, .pixels = 4 },
        .{ .region = .{ .before = value, .after = value }, .pixels = 4 },
    };
    var moves = [_]values.Move{.{
        .before = .{ .y = 56, .height = 32 },
        .after = .{ .y = 74, .height = 32 },
        .x = .init(160),
        .width = .init(24),
    }};
    const len = mergeLogical(&candidates, before.view, after.view, .one, &moves);
    var edits: [candidates.len]values.Region = undefined;
    for (edits[0..len], candidates[0..len]) |*edit, candidate| edit.* = candidate.region;
    try std.testing.expectEqual(@as(usize, 1), move_rules.keepMoves(&moves, edits[0..len], .one, Scale.one.devicePixels(move_rules.scroll_shift)));
}

test {
    std.testing.refAllDecls(@This());
}
