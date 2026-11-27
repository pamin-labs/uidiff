//! Recognizes full-viewport scrims and their opaque panels.

const std = @import("std");
const bounds = @import("bounds.zig");
const scrim = @import("scrim.zig");
const value = @import("../../value.zig");
const pixel = @import("../pixel.zig");
const Box = value.Box;
const Region = value.Region;

// Samples around the viewport imply a shared backdrop only when there is
// enough contrast to distinguish a scrim from a replacement solid colour.
const min_scrim_extent = 24;

const scrim_sample_pitch = 4;

const scrim_fit_pitch = 8;

const scrim_fit_margin_divisor = 4;

const panel_center_inset_divisor = 16;

const scrim_min_contrast = 8;

const scrim_max_transmission = 0.90;

const scrim_min_transmission = 0.12;

const scrim_shadow_radius = value.CssPx.init(24);

const max_scrim_shadow_radius = 72;

const scrim_window_contrast = 12.0;

/// Assigns the affected side when a translucent backdrop and a new opaque
/// panel explain a full-viewport change.
pub fn classifyOverlay(region: *Region, pair: value.Pair, scale: value.Scale) void {
    if (pair.before.width != pair.after.width or pair.before.height != pair.after.height) return;
    const viewport = Box.fromPixels(0, 0, pair.before.width, pair.before.height);
    const old = region.before orelse return;
    const new = region.after orelse return;
    if (!std.meta.eql(old, viewport) or !std.meta.eql(new, viewport)) return;
    const radius: usize = bounds.deviceIndex(@min(scale.devicePixels(scrim_shadow_radius), max_scrim_shadow_radius));
    if (overlaid(pair, radius)) region.before = null else if (overlaid(value.reversePair(pair), radius)) region.after = null;
}

fn checkScrimShadow(pair: value.Pair, panel: value.PixelRect, radius: usize, shade: scrim.Scrim) bool {
    const last_y = pair.before.height - 1;
    const last_x = pair.before.width - 1;
    const right = panel.right();
    const bottom = panel.bottom();
    var y: usize = 0;
    while (true) : (y = @min(y + scrim_sample_pitch, last_y)) {
        const old = pair.before.row(y);
        const new = pair.after.row(y);
        const in_panel_rows = y >= panel.y and y < bottom;
        var x: usize = 0;
        while (true) : (x = @min(x + scrim_sample_pitch, last_x)) {
            const inside = in_panel_rows and x >= panel.x and x < right;
            if (!inside) {
                const matches = shade.matches(old[x], new[x]);
                if (!matches and (y < panel.y -| radius or y >= bottom + radius or
                    x < panel.x -| radius or x >= right + radius or !shade.shadow(old[x], new[x]))) return false;
            }
            if (x == last_x) break;
        }
        if (y == last_y) break;
    }
    return true;
}

fn overlaid(pair: value.Pair, radius: usize) bool {
    const shade = fitScrim(pair) orelse return false;
    const panel = panelBounds(pair, shade) orelse return false;
    return checkScrimShadow(pair, panel, radius, shade);
}

fn panelBounds(pair: value.Pair, shade: scrim.Scrim) ?value.PixelRect {
    const y = pair.before.height / 2;
    const center = pair.before.width / 2;
    const a = pair.before.row(y);
    const b = pair.after.row(y);
    const panel = b[center];
    const inset = pair.before.width / panel_center_inset_divisor;
    const center_samples = [_]usize{ center - inset, center, center + inset };
    for (center_samples) |x| {
        if (!pixel.same(panel, b[x]) or shade.residual(a[x], b[x]) < scrim_window_contrast) return null;
    }
    const origin = y * pair.before.width + center;
    const stride: isize = @intCast(pair.before.width);
    const right_extent = pair.before.width - center - 1;
    const lower_extent = pair.before.height - y - 1;
    const left = scrimReach(pair, shade, origin, center, -1);
    const right = scrimReach(pair, shade, origin, right_extent, 1);
    const top = scrimReach(pair, shade, origin, y, -stride);
    const bottom = scrimReach(pair, shade, origin, lower_extent, stride);
    if (left == center or right == right_extent or top == y or bottom == lower_extent) return null;
    return .{ .x = center - left, .y = y - top, .width = left + right + 1, .height = top + bottom + 1 };
}

// Takes a validated ray from a pixel to its row or column boundary.
noinline fn scrimReach(pair: value.Pair, shade: scrim.Scrim, origin: usize, extent: usize, step: isize) usize {
    var pos: isize = @intCast(origin);
    for (0..extent) |distance| {
        pos += step;
        const index: usize = @intCast(pos);
        if (shade.matches(pair.before.pixels[index], pair.after.pixels[index])) return distance;
    }
    return extent;
}

noinline fn fitScrim(pair: value.Pair) ?scrim.Scrim {
    if (pair.before.width < min_scrim_extent or pair.before.height < min_scrim_extent) return null;
    // Sample through the outer page bands so low-contrast viewport chrome
    // cannot determine the transmission for high-contrast content.
    const Channels = @Vector(4, u8);
    var brightest: Channels = @splat(0);
    var darkest: Channels = @splat(255);
    var bright_overlay: Channels = undefined;
    var dark_overlay: Channels = undefined;
    const margin = pair.before.height / scrim_fit_margin_divisor;
    var y: usize = 0;
    while (y < pair.before.height) : (y += scrim_fit_pitch) {
        if (y >= margin and y < pair.before.height - margin) continue;
        const source = pair.before.row(y);
        const dimmed = pair.after.row(y);
        var x: usize = 0;
        while (x < pair.before.width) : (x += scrim_fit_pitch) {
            const a: Channels = source[x];
            const b: Channels = dimmed[x];
            if (a[3] != 255 or b[3] != 255) return null;
            bright_overlay = @select(u8, a >= brightest, b, bright_overlay);
            dark_overlay = @select(u8, a <= darkest, b, dark_overlay);
            brightest = @max(a, brightest);
            darkest = @min(a, darkest);
        }
    }
    const contrast = brightest - darkest;
    const range = @reduce(.Max, contrast);
    const signal: usize = if (range == contrast[0]) 0 else if (range == contrast[1]) 1 else 2;
    const highs: [4]u8 = bright_overlay;
    const lows: [4]u8 = dark_overlay;
    const peaks: [4]u8 = brightest;
    if (range < scrim_min_contrast or highs[signal] <= lows[signal] or highs[signal] >= peaks[signal]) return null;
    const transmission = @as(f32, @floatFromInt(highs[signal] - lows[signal])) / @as(f32, @floatFromInt(range));
    if (transmission < scrim_min_transmission or transmission > scrim_max_transmission) return null;
    const a = pair.before.pixels[0];
    const b = pair.after.pixels[0];
    const base = scrim.tone(b) - scrim.tone(a) * @as(@Vector(3, f32), @splat(transmission));
    if (@reduce(.Min, base) < -scrim.scrim_rounding or
        @reduce(.Max, base) > 255 * (1 - transmission) + scrim.scrim_rounding) return null;
    return .{ .transmission = transmission, .base = base };
}

test {
    std.testing.refAllDecls(@This());
}
