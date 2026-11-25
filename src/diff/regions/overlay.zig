//! Recognizes full-viewport scrims and their opaque panels.

const std = @import("std");
const bounds = @import("bounds.zig");
const scrim_model = @import("scrim.zig");
const values = @import("../../value.zig");
const pixel = @import("../pixel.zig");
const Box = values.Box;
const Region = values.Region;
const Image = values.Image;

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

const scrim_shadow_radius = values.CssPx.init(24);

const max_scrim_shadow_radius = 72;

const scrim_window_contrast = 12.0;

/// Assigns the affected side when a translucent backdrop and a new opaque
/// panel explain a full-viewport change.
pub fn classifyOverlay(region: *Region, before: Image, after: Image, scale: values.Scale) void {
    if (before.width != after.width or before.height != after.height) return;
    const viewport = Box.fromPixels(0, 0, before.width, before.height);
    const old = region.before orelse return;
    const new = region.after orelse return;
    if (!std.meta.eql(old, viewport) or !std.meta.eql(new, viewport)) return;
    const radius: usize = bounds.deviceIndex(@min(scale.devicePixels(scrim_shadow_radius), max_scrim_shadow_radius));
    if (overlaid(before, after, radius)) region.before = null else if (overlaid(after, before, radius)) region.after = null;
}

fn checkScrimShadow(before: Image, after: Image, panel: bounds.PixelRect, radius: usize, scrim: scrim_model.Scrim) bool {
    const last_y = before.height - 1;
    const last_x = before.width - 1;
    var y: usize = 0;
    while (true) : (y = @min(y + scrim_sample_pitch, last_y)) {
        const old = before.row(y);
        const new = after.row(y);
        const in_panel_rows = y >= panel.top and y < panel.bottom;
        var x: usize = 0;
        while (true) : (x = @min(x + scrim_sample_pitch, last_x)) {
            const inside = in_panel_rows and x >= panel.left and x < panel.right;
            if (!inside) {
                const matches = scrim.matches(old[x], new[x]);
                if (!matches and (y < panel.top -| radius or y >= panel.bottom + radius or
                    x < panel.left -| radius or x >= panel.right + radius or !scrim.shadow(old[x], new[x]))) return false;
            }
            if (x == last_x) break;
        }
        if (y == last_y) break;
    }
    return true;
}

fn overlaid(before: Image, after: Image, radius: usize) bool {
    const scrim = fitScrim(before, after) orelse return false;
    const panel = panelBounds(before, after, scrim) orelse return false;
    return checkScrimShadow(before, after, panel, radius, scrim);
}

fn panelBounds(before: Image, after: Image, scrim: scrim_model.Scrim) ?bounds.PixelRect {
    const y = before.height / 2;
    const center = before.width / 2;
    const a = before.row(y);
    const b = after.row(y);
    const panel = b[center];
    const inset = before.width / panel_center_inset_divisor;
    const center_samples = [_]usize{ center - inset, center, center + inset };
    for (center_samples) |x| {
        if (!pixel.same(panel, b[x]) or scrim.residual(a[x], b[x]) < scrim_window_contrast) return null;
    }
    const origin = y * before.width + center;
    const stride: isize = @intCast(before.width);
    const right_extent = before.width - center - 1;
    const lower_extent = before.height - y - 1;
    const left = scrimReach(before, after, scrim, origin, center, -1);
    const right = scrimReach(before, after, scrim, origin, right_extent, 1);
    const top = scrimReach(before, after, scrim, origin, y, -stride);
    const bottom = scrimReach(before, after, scrim, origin, lower_extent, stride);
    if (left == center or right == right_extent or top == y or bottom == lower_extent) return null;
    return .{ .left = center - left, .right = center + right + 1, .top = y - top, .bottom = y + bottom + 1 };
}

// Takes a validated ray from a pixel to its row or column boundary.
noinline fn scrimReach(before: Image, after: Image, scrim: scrim_model.Scrim, origin: usize, extent: usize, step: isize) usize {
    var pos: isize = @intCast(origin);
    for (0..extent) |distance| {
        pos += step;
        const index: usize = @intCast(pos);
        if (scrim.matches(before.pixels[index], after.pixels[index])) return distance;
    }
    return extent;
}

noinline fn fitScrim(before: Image, after: Image) ?scrim_model.Scrim {
    if (before.width < min_scrim_extent or before.height < min_scrim_extent) return null;
    // Sample through the outer page bands so low-contrast viewport chrome
    // cannot determine the transmission for high-contrast content.
    const Channels = @Vector(4, u8);
    var brightest: Channels = @splat(0);
    var darkest: Channels = @splat(255);
    var bright_overlay: Channels = undefined;
    var dark_overlay: Channels = undefined;
    const margin = before.height / scrim_fit_margin_divisor;
    var y: usize = 0;
    while (y < before.height) : (y += scrim_fit_pitch) {
        if (y >= margin and y < before.height - margin) continue;
        const source = before.row(y);
        const dimmed = after.row(y);
        var x: usize = 0;
        while (x < before.width) : (x += scrim_fit_pitch) {
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
    const a = before.pixels[0];
    const b = after.pixels[0];
    const base = scrim_model.tone(b) - scrim_model.tone(a) * @as(@Vector(3, f32), @splat(transmission));
    if (@reduce(.Min, base) < -scrim_model.scrim_rounding or
        @reduce(.Max, base) > 255 * (1 - transmission) + scrim_model.scrim_rounding) return null;
    return .{ .transmission = transmission, .base = base };
}

test {
    std.testing.refAllDecls(@This());
}
