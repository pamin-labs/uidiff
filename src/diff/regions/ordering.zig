//! Orders, numbers and pads the finalized regions.

const std = @import("std");
const candidate = @import("candidate.zig");
const value = @import("../../value.zig");
const Size = value.Size;
const Box = value.Box;
const Region = value.Region;

/// Sorts by the before box when present, then assigns numbers and padding.
pub fn finish(output: []Region, before: Size, after: Size, scale: value.Scale) void {
    // The collector caps output at max_regions. Stable insertion sort keeps
    // the ordering rule without linking a general-purpose sort into the CLI.
    std.sort.insertion(Region, output, {}, lessThan);
    const space = scale.devicePixels(candidate.padding);
    for (output, 1..) |*region, number| {
        region.number = number;
        if (region.before) |box| region.before = pad(box, before, space);
        if (region.after) |box| region.after = pad(box, after, space);
    }
}

fn lessThan(_: void, a: Region, b: Region) bool {
    // Collected regions always contain a box. Defaults make this total for plain values.
    const empty: Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const p = a.before orelse a.after orelse empty;
    const q = b.before orelse b.after orelse empty;
    return p.y < q.y or (p.y == q.y and p.x < q.x);
}

fn pad(self: Box, size: Size, space: f64) Box {
    const x = @max(0, @floor(self.x - space));
    const y = @max(0, @floor(self.y - space));
    return .{
        .x = x,
        .y = y,
        .width = @min(@as(f64, @floatFromInt(size.width)), @ceil(self.right() + space)) - x,
        .height = @min(@as(f64, @floatFromInt(size.height)), @ceil(self.bottom() + space)) - y,
    };
}

test {
    std.testing.refAllDecls(@This());
}
