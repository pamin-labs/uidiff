//! Refines provisional bands around compact elements and mixed shifts.

const std = @import("std");
const band_model = @import("band.zig");
const insertion = @import("insertion.zig");
const paint = @import("paint.zig");
const values = @import("../../value.zig");
const pixel_ops = @import("../pixel.zig");
const Image = values.Image;

const PixelSamples = struct {
    appearance: usize = 0,
    positional: usize = 0,
    shifted: usize = 0,
};

const PixelBand = struct { before: usize, after: usize, count: usize, shift: usize };

const colour_sample_columns = 96;

const silhouette_sample_columns = 64;

const sample_rows = 64;

const min_sample_support = 16;

const min_silhouette_band = 32;

const min_mixed_anchor = 4;

/// Caps the span of a two-sided replacement band.
pub const max_replacement_rows = 64;

/// Places a one-sided element at the best boundary among equivalent row matches.
pub fn refineElements(before: band_model.Keys, after: band_model.Keys, limits: band_model.Limits, bands: []band_model.Band) void {
    const images = limits.images orelse return;
    if (bands.len < 2) return;
    recoverGrowingEdits(limits, bands);
    refineMixedPaths(limits, bands);
    for (bands[0 .. bands.len - 1], bands[1..]) |*band, next| {
        if (band.mode != .regular or @min(band.removed, band.added) != 0) continue;
        const inserted = band.added != 0;
        const count = @max(band.removed, band.added);
        if (count <= 2 * limits.scroll or @min(next.removed, next.added) < count / 2) continue;
        if (next.before != band.before + band.removed or next.after != band.after + band.added) continue;
        const short = if (inserted) before else after;
        const long = if (inserted) after else before;
        const image = images[@intFromBool(inserted)];
        const original = if (inserted) band.after else band.before;
        const aligned = if (inserted) band.before else band.after;
        var distance: usize = 0;
        const max_distance = @min(aligned, original, count, insertion.max_panel_shift);
        while (distance < max_distance) : (distance += 1) {
            const key = short[aligned - distance - 1];
            const y = original - distance - 1;
            if (key != long[y] or key != long[y + count]) break;
        }
        const best = compactElement(image, original - distance, original, count, limits);
        band.before -= original - best;
        band.after -= original - best;
        band.mode = .element;
    }
}

// Growth fixes the net offset. A locally edited head of the moved list can
// be paired against the new row instead, because it lost its exact row hashes.
fn recoverGrowingEdits(limits: band_model.Limits, bands: []band_model.Band) void {
    const images = limits.images orelse return;
    const growth = images[1].height -| images[0].height;
    if (growth <= limits.scroll) return;
    for (bands[0 .. bands.len - 1], 0..) |*band, index| {
        const next = &bands[index + 1];
        const count = band.removed;
        if (count == 0 or count > growth or band.added != count + growth or band.mode != .regular) continue;
        if (next.before != band.before + count or next.after != band.after + band.added or
            next.removed != next.added or next.removed < growth) continue;
        if (!prefersGrowthOffset(images, limits, band.*, growth)) continue;
        next.* = .{ .before = band.before, .after = band.after + growth, .removed = next.removed + count, .added = next.added + count };
        band.removed = 0;
        band.added = growth;
    }
}

fn prefersGrowthOffset(images: [2]Image, limits: band_model.Limits, band: band_model.Band, growth: usize) bool {
    const totals = sampleBand(.colour, images[0], images[1], limits, .{
        .before = band.before,
        .after = band.after,
        .count = band.removed,
        .shift = growth,
    }, &.{});
    return totals.positional >= min_sample_support and
        paint.paint_density_denominator * totals.shifted <= paint.paint_density_numerator * totals.positional;
}

// Equivalent repeated rows can match at several boundaries. Prefer the
// smallest enclosure that covers the changed content.
fn compactElement(image: Image, first: usize, last: usize, count: usize, limits: band_model.Limits) usize {
    if (first == last) return last;
    var best = last;
    var best_top = image.height;
    var best_height = count + 1;
    var top = first;
    var end = first;
    var bottom_ink = first;
    for (first..last + 1) |y| {
        const bottom = y + count;
        while (end < bottom) : (end += 1) {
            if (!paint.flatPaint(image, end, end + 1, limits.left, limits.width)) bottom_ink = end + 1;
        }
        top = @max(y, top);
        while (top < bottom_ink and paint.flatPaint(image, top, top + 1, limits.left, limits.width)) : (top += 1) {}
        if (bottom_ink <= top) continue;
        const height = bottom_ink - top;
        if (height < best_height or (height == best_height and top <= best_top)) {
            best = y;
            best_top = top;
            best_height = height;
        }
    }
    return best;
}

// An opposite one-sided gap can be the tail of a recoloured element
// that lost its row anchors. Only repack it when the following match
// supports the final displacement and the foreground silhouette agrees.
fn refineMixedPaths(limits: band_model.Limits, bands: []band_model.Band) void {
    if (bands.len < 3) return;
    for (0..bands.len - 2) |i| {
        const first = bands[i];
        const second = bands[i + 1];
        const next = bands[i + 2];
        if (first.mode != .regular or second.mode != .regular or @min(first.removed, first.added) < min_mixed_anchor) continue;
        if (second.before != next.before -| second.removed or second.after != next.after -| second.added) continue;
        if (@min(next.removed, next.added) < min_mixed_anchor) continue;
        const gap: band_model.Band = .{
            .before = first.before,
            .after = first.after,
            .removed = next.before - first.before,
            .added = next.after - first.after,
        };
        const inserted = gap.added > gap.removed;
        if (inserted) {
            if (first.removed <= first.added or second.removed != 0) continue;
        } else if (first.added <= first.removed or second.added != 0) continue;
        if (!shapeKeepsOffset(limits, gap)) continue;

        const paired = @min(gap.removed, gap.added);
        const removed = gap.removed - paired;
        const added = gap.added - paired;
        bands[i] = .{ .before = gap.before, .after = gap.after, .removed = removed, .added = added };
        bands[i + 1] = .{ .before = gap.before + removed, .after = gap.after + added, .removed = paired, .added = paired };
    }
}

// A recoloured element can lose all of its row hashes. Prefer the offset
// that preserves its foreground silhouette when the surrounding hashes
// already establish a shift.
fn shapeKeepsOffset(limits: band_model.Limits, gap: band_model.Band) bool {
    const images = limits.images orelse return false;
    if (@min(gap.before, gap.after) == 0) return false;
    const count = @min(gap.removed, gap.added);
    const shift = @max(gap.removed, gap.added) - count;
    if (shift <= limits.scroll or count < min_silhouette_band) return false;
    const inserted = gap.added > gap.removed;
    const short = images[@intFromBool(!inserted)];
    const long = images[@intFromBool(inserted)];
    const short_y = if (inserted) gap.before else gap.after;
    const long_y = if (inserted) gap.after else gap.before;
    const backdrop = short.rowSegment(short_y - 1, limits.left, limits.width);
    const opposite = long.rowSegment(long_y - 1, limits.left, limits.width);
    if (!pixel_ops.sameRun(backdrop, opposite)) return false;

    const totals = sampleBand(.silhouette, short, long, limits, .{
        .before = short_y,
        .after = long_y,
        .count = count,
        .shift = shift,
    }, backdrop);
    return totals.appearance >= min_sample_support and totals.positional >= min_sample_support and totals.shifted == 0;
}

fn sampleBand(comptime mode: enum { colour, silhouette }, before: Image, after: Image, limits: band_model.Limits, band: PixelBand, backdrop: []const values.Pixel) PixelSamples {
    const columns_target = if (mode == .colour) colour_sample_columns else silhouette_sample_columns;
    const x_step = @max(1, limits.width / columns_target);
    const y_step = @max(1, band.count / sample_rows);
    var totals: PixelSamples = .{};
    var y: usize = 0;
    while (y < band.count) : (y += y_step) {
        const old = before.rowSegment(band.before + y, limits.left, limits.width);
        const same = after.rowSegment(band.after + y, limits.left, limits.width);
        const moved = after.rowSegment(band.after + band.shift + y, limits.left, limits.width);
        var x: usize = 0;
        while (x < limits.width) : (x += x_step) {
            if (mode == .colour) {
                totals.positional += @intFromBool(!pixel_ops.same(old[x], same[x]));
                totals.shifted += @intFromBool(!pixel_ops.same(old[x], moved[x]));
            } else {
                const ink = !pixel_ops.same(old[x], backdrop[x]);
                totals.appearance += @intFromBool(ink);
                totals.positional += @intFromBool(ink != !pixel_ops.same(same[x], backdrop[x]));
                totals.shifted += @intFromBool(ink != !pixel_ops.same(moved[x], backdrop[x]));
            }
        }
    }
    return totals;
}

test "growth pairs an edited row head with its displaced body" {
    const canvas = @import("../../testing/canvas.zig");
    const before = try canvas.Canvas.init(200, 180);
    defer before.deinit();
    const after = try canvas.Canvas.init(200, 220);
    defer after.deinit();
    before.fill(10, 70, 22, 29, .{ 95, 125, 180, 255 });
    before.fill(100, 74, 16, 12, canvas.inkShade(45, 4));
    before.fill(30, 128, 28, 24, .{ 180, 65, 114, 255 });
    after.copyRows(0, before, 0, 70);
    after.copyRows(110, before, 70, before.view.height);
    after.fill(48, 72, 105, 29, .{ 210, 120, 90, 255 });
    after.fill(100, 114, 16, 12, canvas.inkShade(115, 4));
    var old: [180]u64 = undefined;
    var new: [220]u64 = undefined;
    band_model.keys(before.view, 0, 200, &old);
    band_model.keys(after.view, 0, 200, &new);
    var bands = [_]band_model.Band{
        .{ .before = 0, .after = 0, .removed = 70, .added = 70 },
        .{ .before = 70, .after = 70, .removed = 32, .added = 72 },
        .{ .before = 102, .after = 142, .removed = 78, .added = 78 },
    };
    refineElements(&old, &new, .{ .scroll = 2, .replacement = 24, .images = .{ before.view, after.view }, .width = 200 }, &bands);
    try std.testing.expectEqual(@as(usize, 0), bands[1].removed);
    try std.testing.expectEqual(@as(usize, 40), bands[1].added);
    try std.testing.expectEqual(@as(usize, 110), bands[2].after);
}

test "an inserted row precedes the moved recolour in an ambiguous alignment" {
    const canvas = @import("../../testing/canvas.zig");
    const before = try canvas.Canvas.init(120, 160);
    defer before.deinit();
    const after = try canvas.Canvas.init(120, 160);
    defer after.deinit();
    before.fill(30, 24, 70, 56, .{ 180, 180, 184, 255 });
    after.fill(40, 24, 50, 10, .{ 112, 141, 168, 255 });
    after.fill(30, 44, 70, 56, .{ 64, 124, 202, 255 });
    before.line(26, 112, 91, 4, 35);
    after.copyRows(110, before, 90, 130);
    var old_keys: [160]u64 = undefined;
    var new_keys: [160]u64 = undefined;
    band_model.keys(before.view, 0, 120, &old_keys);
    band_model.keys(after.view, 0, 120, &new_keys);
    // The recolour changes its row hashes. The initial alignment consumes
    // part of its old silhouette as a positional edit, then catches up.
    var bands = [_]band_model.Band{
        .{ .before = 20, .after = 20, .removed = 62, .added = 16 },
        .{ .before = 90, .after = 40, .removed = 0, .added = 70 },
        .{ .before = 90, .after = 110, .removed = 12, .added = 12 },
    };
    refineElements(&old_keys, &new_keys, .{
        .scroll = 4,
        .replacement = 48,
        .images = .{ before.view, after.view },
        .width = 120,
    }, &bands);
    try std.testing.expectEqual(@as(usize, 0), bands[0].removed);
    try std.testing.expectEqual(@as(usize, 20), bands[0].added);
    try std.testing.expectEqual(@as(usize, 20), bands[1].before);
    try std.testing.expectEqual(@as(usize, 40), bands[1].after);
    try std.testing.expectEqual(@as(usize, 70), bands[1].removed);
    try std.testing.expectEqual(@as(usize, 70), bands[1].added);
}

test {
    std.testing.refAllDecls(@This());
}
