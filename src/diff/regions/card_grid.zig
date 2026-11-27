//! Pairs cards that reflow horizontally in a grid.

const std = @import("std");
const candidate = @import("candidate.zig");
const bounds = @import("bounds.zig");
const value = @import("../../value.zig");
const pixel = @import("../pixel.zig");
const Box = value.Box;

const min_grid_slots = 3;

const max_grid_slots = 4;

const min_grid_card_extent = value.CssPx.init(32);

const max_grid_gutter = value.CssPx.init(48);

/// Pairs horizontally reflowed cards and leaves the unmatched card one-sided.
pub fn pairCardGrid(boxes: []candidate.Candidate, pair: value.Pair, scale: value.Scale) void {
    if (boxes.len < min_grid_slots or boxes.len > max_grid_slots) return;
    var slots: [candidate.max_regions]Box = undefined;
    const row = candidate.stationaryBoxes(boxes, &slots) orelse return;
    std.sort.insertion(Box, row, {}, boxLeftOf);
    const first = row[0];
    const pitch = row[1].x - first.x;
    const gutter = pitch - first.width;
    const min_extent = scale.devicePixels(min_grid_card_extent);
    if (gutter <= 0 or gutter > scale.devicePixels(max_grid_gutter) or first.width < min_extent) return;
    const slack = scale.devicePixels(candidate.padding);
    var top = first.y;
    var bottom = first.bottom();
    for (row, 0..) |slot, index| {
        if (slot.x != first.x + pitch * @as(f64, @floatFromInt(index)) or slot.width != first.width or
            slot.height < min_extent or @abs(slot.y - first.y) > slack or @abs(slot.bottom() - first.bottom()) > slack) return;
        top = @min(top, slot.y);
        bottom = @max(bottom, slot.bottom());
    }
    const old_to_left = shiftedGrid(pair, row, bounds.deviceIndex(top), bounds.deviceIndex(bottom));
    if (!old_to_left and !shiftedGrid(pair.reversed(), row, bounds.deviceIndex(top), bounds.deviceIndex(bottom))) return;
    // Each translated slot has an exact counterpart. The only unpaired
    // slot is the card at the start of the row, in either direction.
    boxes[0].region = if (old_to_left) .{ .before = first } else .{ .after = first };
    for (boxes[1..], row[1..], row[0 .. row.len - 1]) |*entry, from, to| {
        entry.region = if (old_to_left) .{ .before = from, .after = to } else .{ .before = to, .after = from };
    }
}

fn boxLeftOf(_: void, a: Box, b: Box) bool {
    return a.x < b.x;
}

fn shiftedGrid(pair: value.Pair, slots: []const Box, top: usize, bottom: usize) bool {
    const width: usize = bounds.deviceIndex(slots[0].width);
    const last: usize = bounds.deviceIndex(slots[slots.len - 1].x);
    const background = pair.after.row(top)[last];
    for (top..bottom) |y| {
        for (pair.after.rowSegment(y, last, width)) |p| if (!pixel.same(p, background)) return false;
    }
    for (slots[1..], slots[0 .. slots.len - 1]) |old, new| {
        const from: usize = bounds.deviceIndex(old.x);
        const to: usize = bounds.deviceIndex(new.x);
        for (top..bottom) |y| {
            if (!pixel.sameRun(pair.before.rowSegment(y, from, width), pair.after.rowSegment(y, to, width))) return false;
        }
    }
    return true;
}

test {
    std.testing.refAllDecls(@This());
}
