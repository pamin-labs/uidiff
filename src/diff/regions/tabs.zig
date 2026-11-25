//! Recognizes tab indicator and label transfers.

const std = @import("std");
const pending = @import("candidate.zig");
const bounds = @import("bounds.zig");
const scrim = @import("scrim.zig");
const text_lines = @import("text_lines.zig");
const values = @import("../../value.zig");
const pixel = @import("../pixel.zig");
const Box = values.Box;
const Image = values.Image;

const tab_parts = 3;

const tab_indicator_height = values.CssPx.init(6);

const tab_label_gap = values.CssPx.init(16);

/// Joins a tab indicator transfer with its reciprocal label restyling.
pub fn mergeTabSelection(boxes: []pending.Candidate, before: Image, after: Image, scale: values.Scale) usize {
    if (boxes.len != tab_parts) return boxes.len;
    var stationary: [pending.max_regions]Box = undefined;
    const parts = pending.stationaryBoxes(boxes, &stationary) orelse return boxes.len;
    std.sort.insertion(Box, parts, {}, boxAbove);
    const label, const first, const last = parts[0..tab_parts].*;
    const a, const b = if (first.x < last.x) .{ first, last } else .{ last, first };
    if (label.height > scale.devicePixels(text_lines.line_height) or a.y != b.y or a.height != b.height or
        a.height > scale.devicePixels(tab_indicator_height) or a.y < label.bottom() or
        a.y - label.bottom() > scale.devicePixels(tab_label_gap) or a.right() >= b.x) return boxes.len;
    const background = indicatorTransfer(before, after, a, b) orelse return boxes.len;
    if (!labelTransfer(before, after, label, a, b, background)) return boxes.len;
    return pending.collapse(boxes, pending.unite(pending.unite(a, b), label).?);
}

fn boxAbove(_: void, a: Box, b: Box) bool {
    return a.y < b.y;
}

fn indicatorTransfer(before: Image, after: Image, a: Box, b: Box) ?values.Pixel {
    const ax: usize = bounds.deviceIndex(a.x + a.width / 2);
    const bx: usize = bounds.deviceIndex(b.x + b.width / 2);
    const y: usize = bounds.deviceIndex(a.y + a.height / 2);
    const old_indicator = before.row(y)[ax];
    const new_indicator = after.row(y)[ax];
    if (pixel.same(old_indicator, new_indicator) or !pixel.same(old_indicator, after.row(y)[bx]) or
        !pixel.same(new_indicator, before.row(y)[bx])) return null;
    const gap: usize = bounds.deviceIndex((a.right() + b.x) / 2);
    const background = before.row(y)[gap];
    if (!pixel.same(background, after.row(y)[gap]) or
        (!pixel.same(background, old_indicator) and !pixel.same(background, new_indicator))) return null;
    return background;
}

fn labelTransfer(before: Image, after: Image, label: Box, a: Box, b: Box, background: values.Pixel) bool {
    const old_a = labelInk(before, label, a, background);
    const new_a = labelInk(after, label, a, background);
    if (pixel.same(old_a, new_a) or pixel.same(old_a, background) or pixel.same(new_a, background)) return false;
    return pixel.same(old_a, labelInk(after, label, b, background)) and
        pixel.same(new_a, labelInk(before, label, b, background));
}

fn labelInk(image: Image, label: Box, indicator: Box, background: values.Pixel) values.Pixel {
    const x: usize = bounds.deviceIndex(@max(indicator.x, label.x));
    const right: usize = bounds.deviceIndex(@min(indicator.right(), label.right()));
    var ink = background;
    var contrast: f32 = 0;
    if (x >= right) return ink;
    for (@as(usize, bounds.deviceIndex(label.y))..@as(usize, bounds.deviceIndex(label.bottom()))) |y| {
        for (image.row(y)[x..right]) |p| {
            const distance = scrim.toneDistance(p, background);
            if (distance > contrast) {
                contrast = distance;
                ink = p;
            }
        }
    }
    return ink;
}

test {
    std.testing.refAllDecls(@This());
}
