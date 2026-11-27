//! Keeps text lines together without crossing a stationary divider.

const std = @import("std");
const bounds = @import("bounds.zig");
const value = @import("../../value.zig");
const pixel = @import("../pixel.zig");
const Box = value.Box;
const Region = value.Region;

const line_overlap = 0.7;

/// Maximum CSS height used when joining parts of a line.
pub const line_height = value.CssPx.init(48);

const line_gap_factor = 3;

const divider_context = 3;

/// Reports whether two regions belong to one line of text.
pub fn sameLine(a: Region, b: Region, pair: value.Pair, max_height: f64) bool {
    const p = a.before orelse return false;
    const q = b.before orelse return false;
    const r = a.after orelse return false;
    const s = b.after orelse return false;
    if (!lineNeighbours(p, q, max_height) or !lineNeighbours(r, s, max_height)) return false;
    return !betweenDividers(pair, p, q, r, s);
}

fn betweenDividers(pair: value.Pair, p: Box, q: Box, r: Box, s: Box) bool {
    const start = @max(@min(p.right(), q.right()), @min(r.right(), s.right()));
    const end = @min(@max(p.x, q.x), @max(r.x, s.x));
    if (start >= end) return false;
    // Boxes come from the collector and are within each validated image.
    const left: usize = @max(1, @as(usize, bounds.deviceIndex(start)));
    const right: usize = bounds.deviceIndex(end);
    if (left >= right) return false;
    const top: usize = bounds.deviceIndex(@min(p.y, q.y, r.y, s.y));
    const bottom: usize = bounds.deviceIndex(@max(p.bottom(), q.bottom(), r.bottom(), s.bottom()));
    const height = @min(pair.before.height, pair.after.height);
    if (top < divider_context or bottom + divider_context >= height) return false;
    const samples = [_]usize{ top - divider_context, (top + bottom) / 2, bottom + divider_context };
    for (left..right) |x| {
        const row = pair.before.row(samples[0]);
        const edge_left = row[x - 1];
        const edge_right = row[x];
        if (pixel.same(edge_left, edge_right)) continue;
        for (samples) |y| {
            const a = pair.before.row(y);
            const z = pair.after.row(y);
            if (!pixel.same(a[x - 1], edge_left) or !pixel.same(z[x - 1], edge_left) or
                !pixel.same(a[x], edge_right) or !pixel.same(z[x], edge_right)) break;
        } else return true;
    }
    return false;
}

fn lineNeighbours(a: Box, b: Box, max_height: f64) bool {
    const tallest = @max(a.height, b.height);
    const overlap = @min(a.bottom(), b.bottom()) - @max(a.y, b.y);
    const gap_px = @max(a.x, b.x) - @min(a.right(), b.right());
    return tallest <= max_height and overlap >= line_overlap * @min(a.height, b.height) and gap_px <= line_gap_factor * tallest;
}

test {
    std.testing.refAllDecls(@This());
}
