//! Pending deltas and operations on the candidate list.

const std = @import("std");
const value = @import("../../value.zig");
const Box = value.Box;
const Region = value.Region;

/// A pending region and the number of changed pixels supporting it.
pub const Candidate = struct { region: Region, pixels: usize };

/// Initial merging distance in CSS pixels.
pub const merge_gap = value.CssPx.init(12);

/// Space added around each reported box, in CSS pixels.
pub const padding = value.CssPx.init(4);

/// The most regions a comparison reports; nearby ones merge to fit.
pub const max_regions = 8;

/// Merges two candidates and removes the second from the active slice.
pub fn join(boxes: []Candidate, len: usize, i: usize, j: usize) usize {
    boxes[i].region.before = unite(boxes[i].region.before, boxes[j].region.before);
    boxes[i].region.after = unite(boxes[i].region.after, boxes[j].region.after);
    std.mem.copyForwards(Candidate, boxes[j .. len - 1], boxes[j + 1 .. len]);
    return len - 1;
}

/// Replaces the candidates with one two-sided box.
pub fn collapse(boxes: []Candidate, cover: Box) usize {
    boxes[0].region = .{ .before = cover, .after = cover };
    return 1;
}

/// Copies stationary candidate bounds into caller-owned storage.
pub fn stationaryBoxes(boxes: []const Candidate, storage: *[max_regions]Box) ?[]Box {
    if (boxes.len > storage.len) return null;
    const result = storage[0..boxes.len];
    for (boxes, result) |candidate, *box| box.* = stationaryBox(candidate.region) orelse return null;
    return result;
}

/// Returns the box when its bounds are the same on both sides.
pub fn stationaryBox(region: Region) ?Box {
    const before = region.before orelse return null;
    const after = region.after orelse return null;
    return if (std.meta.eql(before, after)) before else null;
}

/// Returns the enclosing box when either side has a box.
pub fn unite(a: ?Box, b: ?Box) ?Box {
    const p = a orelse return b;
    const q = b orelse return a;
    const x = @min(p.x, q.x);
    const y = @min(p.y, q.y);
    return .{ .x = x, .y = y, .width = @max(p.right(), q.right()) - x, .height = @max(p.bottom(), q.bottom()) - y };
}

test {
    std.testing.refAllDecls(@This());
}
