//! Refines provisional bands around compact elements and mixed shifts.

const std = @import("std");
const band = @import("band.zig");
const insertion = @import("insertion.zig");
const recolour = @import("recolour.zig");
const columns = @import("../columns.zig");
const value = @import("../../value.zig");
const pixel = @import("../pixel.zig");
const Image = value.Image;

const PixelSamples = struct {
    appearance: usize = 0,
    positional: usize = 0,
    shifted: usize = 0,
};

const PixelBand = struct { before_y: usize, after_y: usize, height: usize, shift: usize };

const colour_sample_columns = 96;

const silhouette_sample_columns = 64;

const sample_rows = 64;

const min_sample_support = 16;

const min_silhouette_band = 32;

const min_mixed_anchor = 4;

/// Caps the span of a two-sided replacement band.
pub const max_replacement_rows = 64;

/// Places a one-sided element at the best boundary among equivalent row matches.
pub fn refineElements(before: band.Keys, after: band.Keys, limits: band.Limits, bands: []band.Band) void {
    const sample = limits.sample orelse return;
    if (bands.len < 2) return;
    recoverGrowingEdits(sample.*, limits.scroll, bands);
    refineMixedPaths(sample.*, limits.scroll, bands);
    for (bands[0 .. bands.len - 1], bands[1..]) |*row_band, next| {
        if (row_band.mode != .regular or @min(row_band.removed, row_band.added) != 0) continue;
        const inserted = row_band.added != 0;
        const count = @max(row_band.removed, row_band.added);
        if (count <= 2 * limits.scroll or @min(next.removed, next.added) < count / 2) continue;
        if (next.before != row_band.before + row_band.removed or next.after != row_band.after + row_band.added) continue;
        const short = if (inserted) before else after;
        const long = if (inserted) after else before;
        const image = sample.pair.get(if (inserted) .after else .before);
        const original = if (inserted) row_band.after else row_band.before;
        const aligned = if (inserted) row_band.before else row_band.after;
        var distance: usize = 0;
        const max_distance = @min(aligned, original, count, insertion.max_panel_shift);
        while (distance < max_distance) : (distance += 1) {
            const key = short[aligned - distance - 1];
            const y = original - distance - 1;
            if (key != long[y] or key != long[y + count]) break;
        }
        const best = compactElement(image, original - distance, original, count, sample.columns);
        row_band.before -= original - best;
        row_band.after -= original - best;
        row_band.mode = .element;
    }
}

// Growth fixes the net offset. A locally edited head of the moved list can
// be paired against the new row instead, because it lost its exact row hashes.
fn recoverGrowingEdits(sample: band.Sample, scroll: usize, bands: []band.Band) void {
    const growth = sample.pair.after.height -| sample.pair.before.height;
    if (growth <= scroll) return;
    for (bands[0 .. bands.len - 1], 0..) |*row_band, index| {
        const next = &bands[index + 1];
        const count = row_band.removed;
        if (count == 0 or count > growth or row_band.added != count + growth or row_band.mode != .regular) continue;
        if (next.before != row_band.before + count or next.after != row_band.after + row_band.added or
            next.removed != next.added or next.removed < growth) continue;
        if (!prefersGrowthOffset(sample, row_band.*, growth)) continue;
        next.* = .{ .before = row_band.before, .after = row_band.after + growth, .removed = next.removed + count, .added = next.added + count };
        row_band.removed = 0;
        row_band.added = growth;
    }
}

fn prefersGrowthOffset(sample: band.Sample, row_band: band.Band, growth: usize) bool {
    const totals = sampleBand(.colour, sample.pair, sample.columns, .{
        .before_y = row_band.before,
        .after_y = row_band.after,
        .height = row_band.removed,
        .shift = growth,
    }, &.{});
    return totals.positional >= min_sample_support and
        recolour.paint_density_denominator * totals.shifted <= recolour.paint_density_numerator * totals.positional;
}

// Equivalent repeated rows can match at several boundaries. Prefer the
// smallest enclosure that covers the changed content.
fn compactElement(image: Image, first: usize, last: usize, count: usize, span: columns.Span) usize {
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
            if (!columns.blankBand(image, end, 1, span)) bottom_ink = end + 1;
        }
        top = @max(y, top);
        while (top < bottom_ink and columns.blankBand(image, top, 1, span)) : (top += 1) {}
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
fn refineMixedPaths(sample: band.Sample, scroll: usize, bands: []band.Band) void {
    if (bands.len < 3) return;
    for (0..bands.len - 2) |i| {
        const first = bands[i];
        const second = bands[i + 1];
        const next = bands[i + 2];
        if (first.mode != .regular or second.mode != .regular or @min(first.removed, first.added) < min_mixed_anchor) continue;
        if (second.before != next.before -| second.removed or second.after != next.after -| second.added) continue;
        if (@min(next.removed, next.added) < min_mixed_anchor) continue;
        const gap: band.Band = .{
            .before = first.before,
            .after = first.after,
            .removed = next.before - first.before,
            .added = next.after - first.after,
        };
        const inserted = gap.added > gap.removed;
        if (inserted) {
            if (first.removed <= first.added or second.removed != 0) continue;
        } else if (first.added <= first.removed or second.added != 0) continue;
        if (!shapeKeepsOffset(sample, scroll, gap)) continue;

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
fn shapeKeepsOffset(sample: band.Sample, scroll: usize, gap: band.Band) bool {
    if (@min(gap.before, gap.after) == 0) return false;
    const count = @min(gap.removed, gap.added);
    const shift = @max(gap.removed, gap.added) - count;
    if (shift <= scroll or count < min_silhouette_band) return false;
    const inserted = gap.added > gap.removed;
    const short = sample.pair.get(if (inserted) .before else .after);
    const long = sample.pair.get(if (inserted) .after else .before);
    const short_y = if (inserted) gap.before else gap.after;
    const long_y = if (inserted) gap.after else gap.before;
    const backdrop = short.rowSegment(short_y - 1, sample.columns.left, sample.columns.width);
    const opposite = long.rowSegment(long_y - 1, sample.columns.left, sample.columns.width);
    if (!pixel.sameRun(backdrop, opposite)) return false;

    const totals = sampleBand(.silhouette, .{ .before = short, .after = long }, sample.columns, .{
        .before_y = short_y,
        .after_y = long_y,
        .height = count,
        .shift = shift,
    }, backdrop);
    return totals.appearance >= min_sample_support and totals.positional >= min_sample_support and totals.shifted == 0;
}

fn sampleBand(comptime mode: enum { colour, silhouette }, pair: value.Pair, span: columns.Span, row_band: PixelBand, backdrop: []const value.Pixel) PixelSamples {
    const columns_target = if (mode == .colour) colour_sample_columns else silhouette_sample_columns;
    const x_step = @max(1, span.width / columns_target);
    const y_step = @max(1, row_band.height / sample_rows);
    var totals: PixelSamples = .{};
    var y: usize = 0;
    while (y < row_band.height) : (y += y_step) {
        const old = pair.before.rowSegment(row_band.before_y + y, span.left, span.width);
        const same = pair.after.rowSegment(row_band.after_y + y, span.left, span.width);
        const moved = pair.after.rowSegment(row_band.after_y + row_band.shift + y, span.left, span.width);
        var x: usize = 0;
        while (x < span.width) : (x += x_step) {
            if (mode == .colour) {
                totals.positional += @intFromBool(!pixel.same(old[x], same[x]));
                totals.shifted += @intFromBool(!pixel.same(old[x], moved[x]));
            } else {
                const ink = !pixel.same(old[x], backdrop[x]);
                totals.appearance += @intFromBool(ink);
                totals.positional += @intFromBool(ink != !pixel.same(same[x], backdrop[x]));
                totals.shifted += @intFromBool(ink != !pixel.same(moved[x], backdrop[x]));
            }
        }
    }
    return totals;
}

test "growth pairs an edited row head with its displaced body" {
    const canvas = @import("uidiff_test_canvas").Painters(value.Image);
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
    band.keys(before.view, 0, 200, &old);
    band.keys(after.view, 0, 200, &new);
    var bands = [_]band.Band{
        .{ .before = 0, .after = 0, .removed = 70, .added = 70 },
        .{ .before = 70, .after = 70, .removed = 32, .added = 72 },
        .{ .before = 102, .after = 142, .removed = 78, .added = 78 },
    };
    refineElements(&old, &new, .{ .scroll = 2, .replacement = 24, .sample = &.{ .pair = .{ .before = before.view, .after = after.view }, .columns = .{ .left = 0, .width = 200 } } }, &bands);
    try std.testing.expectEqual(@as(usize, 0), bands[1].removed);
    try std.testing.expectEqual(@as(usize, 40), bands[1].added);
    try std.testing.expectEqual(@as(usize, 110), bands[2].after);
}

test "an inserted row precedes the moved recolour in an ambiguous alignment" {
    const canvas = @import("uidiff_test_canvas").Painters(value.Image);
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
    band.keys(before.view, 0, 120, &old_keys);
    band.keys(after.view, 0, 120, &new_keys);
    // The recolour changes its row hashes. The initial alignment consumes
    // part of its old silhouette as a positional edit, then catches up.
    var bands = [_]band.Band{
        .{ .before = 20, .after = 20, .removed = 62, .added = 16 },
        .{ .before = 90, .after = 40, .removed = 0, .added = 70 },
        .{ .before = 90, .after = 110, .removed = 12, .added = 12 },
    };
    refineElements(&old_keys, &new_keys, .{
        .scroll = 4,
        .replacement = 48,
        .sample = &.{ .pair = .{ .before = before.view, .after = after.view }, .columns = .{ .left = 0, .width = 120 } },
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
