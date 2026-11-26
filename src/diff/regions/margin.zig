//! Recovers distinct colour edits embedded in dimmed margins.

const std = @import("std");
const candidate = @import("candidate.zig");
const bounds = @import("bounds.zig");
const grouping = @import("grouping.zig");
const scrim = @import("scrim.zig");
const value = @import("../../value.zig");
const pixel = @import("../pixel.zig");
const Box = value.Box;
const Region = value.Region;
const Image = value.Image;

const shade_margin_width = value.CssPx.init(64);

const shade_margin_height = value.CssPx.init(12);

const shade_mark_width_divisor = 4;

const shade_support_divisor = 2;

// A small drift in shadow transmission is insufficient to separate an edit.
const shade_mark_residual: f32 = 6;

/// Finds a separate colour edit embedded in a flat dimmed margin. The enclosing
/// region remains available to account for the rest of the changed pixels.
pub fn shadeMarginEdit(region: Region, pair: value.Pair, scale: value.Scale) ?candidate.Candidate {
    if (pair.before.width != pair.after.width or pair.before.height != pair.after.height) return null;
    const box = candidate.stationaryBox(region) orelse return null;
    const viewport = Box.fromPixels(0, 0, pair.before.width, pair.before.height);
    if (std.meta.eql(box, viewport) or box.width < scale.devicePixels(shade_margin_width)) return null;
    const area = bounds.pixelRect(box);
    const extent = bounds.deviceIndex(@min(scale.devicePixels(shade_margin_height), box.height / 2));
    return shadeMargin(pair, area, extent, .start) orelse shadeMargin(pair, area, extent, .end);
}

fn shadeMargin(pair: value.Pair, area: value.PixelRect, extent: usize, edge: bounds.RailEnd) ?candidate.Candidate {
    const width = area.width;
    const area_right = area.right();
    const area_bottom = area.bottom();
    const center = area.x + width / 2;
    const max_mark_width = width / shade_mark_width_divisor;
    const min_support = width / shade_support_divisor;
    var left = area_right;
    var right = area.x;
    var top = area_bottom;
    var bottom = area.y;
    var evidence: usize = 0;
    var strongest: f32 = 0;
    // A margin must reach a stronger change. A page-wide tint alone does
    // not provide evidence that a smaller mark is independent.
    for (0..extent) |offset| {
        const y = if (edge == .start) area.y + offset else area_bottom - 1 - offset;
        const old = pair.before.row(y);
        const new = pair.after.row(y);
        const source = scrim.tone(old[center]);
        const brightness = @reduce(.Add, source);
        if (brightness == 0) break;
        const transmission = @reduce(.Add, scrim.tone(new[center])) / brightness;
        const shade: scrim.Scrim = .{ .transmission = transmission, .base = @splat(0) };
        if (transmission < scrim.scrim_min_shadow_transmission or transmission >= 1 or !shade.matches(old[center], new[center])) break;
        var support: usize = 0;
        var line_left = area_right;
        var line_right = area.x;
        var count: usize = 0;
        for (area.x..area_right) |x| {
            if (pixel.same(old[x], new[x])) continue;
            if (shade.matches(old[x], new[x])) {
                support += 1;
            } else {
                line_left = @min(line_left, x);
                line_right = x + 1;
                count += 1;
                strongest = @max(strongest, shade.residual(old[x], new[x]));
            }
        }
        if (support < min_support or line_right -| line_left > max_mark_width) break;
        if (line_right > line_left) {
            left = @min(left, line_left);
            right = @max(right, line_right);
            top = @min(top, y);
            bottom = @max(bottom, y + 1);
            evidence += count;
            if (right - left > max_mark_width) return null;
        }
    } else return null;
    if (evidence < grouping.min_region_pixels or strongest < shade_mark_residual) return null;
    const mark = Box.fromPixels(left, top, right - left, bottom - top);
    return .{ .region = .{ .before = mark, .after = mark }, .pixels = evidence };
}

test "faint shadow variation at the margin is not a separate colour edit" {
    const width = 96;
    const height = 24;
    const base: value.Pixel = .{ 22, 25, 33, 255 };
    const shade: value.Pixel = .{ 19, 21, 28, 255 };
    const near_corner: value.Pixel = .{ 22, 24, 32, 255 };
    const fill: value.Pixel = .{ 45, 50, 62, 255 };
    const old: [width * height]value.Pixel = @splat(base);
    var new: [width * height]value.Pixel = @splat(shade);
    @memset(new[width * 4 ..][0 .. width * 16], fill);
    for (0..4) |y| @memset(new[y * width ..][0..8], near_corner);
    const before: Image = .{ .pixels = &old, .width = width, .height = height };
    const after: Image = .{ .pixels = &new, .width = width, .height = height };
    const area: value.PixelRect = .{ .x = 0, .y = 0, .width = width, .height = height };
    try std.testing.expectEqual(null, shadeMargin(.{ .before = before, .after = after }, area, 8, .start));
}

test {
    std.testing.refAllDecls(@This());
}
