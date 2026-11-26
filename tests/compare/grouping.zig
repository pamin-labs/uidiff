//! End-to-end grouping, padding, report order and region budgets.

const std = @import("std");
const diff = @import("diff_scenarios");
const sample = diff.test_support;
const values = sample.values;
const Box = values.Box;
const Kind = values.Kind;
const region_padding = diff.region_padding;
const max_regions = diff.max_regions;
const test_gap = sample.merge_gap.count();

test "one line of text joins its changed runs across word space" {
    const before = try sample.Canvas.init(120, 100);
    defer before.deinit();
    const after = try sample.Canvas.init(120, 100);
    defer after.deinit();
    after.fill(12, 35, 14, 16, sample.inkShade(30, 4));
    after.fill(53, 35, 14, 16, sample.inkShade(30, 4));
    const result = try sample.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expect(sample.hasRegion(result.regions, .after, 18, 40, .changed));
    try std.testing.expect(sample.hasRegion(result.regions, .after, 57, 40, .changed));
}

test "the exposed edges of a sideways card form one changed box" {
    const before = try sample.Canvas.init(150, 120);
    defer before.deinit();
    const after = try sample.Canvas.init(150, 120);
    defer after.deinit();
    before.fill(30, 25, 60, 70, .{ 85, 100, 145, 255 });
    after.fill(50, 25, 60, 70, .{ 85, 100, 145, 255 });
    const result = try sample.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expect(sample.hasRegion(result.regions, .before, 36, 50, .changed));
    try std.testing.expect(sample.hasRegion(result.regions, .after, 104, 50, .changed));
}

test "a stationary column divider separates two same-line changes" {
    const before = try sample.Canvas.init(280, 100);
    defer before.deinit();
    const after = try sample.Canvas.init(280, 100);
    defer after.deinit();
    for ([_]sample.Canvas{ before, after }) |canvas| {
        canvas.fill(0, 0, 110, 100, .{ 240, 242, 246, 255 });
        canvas.fill(110, 0, 1, 100, sample.inkShade(205, 4));
    }
    before.fill(92, 28, 11, 16, sample.inkShade(50, 4));
    after.fill(92, 28, 11, 16, sample.inkShade(110, 4));
    before.fill(126, 28, 25, 16, sample.inkShade(40, 4));
    after.fill(126, 28, 25, 16, sample.inkShade(95, 4));
    const result = try sample.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.regions.len);
    for (result.regions) |region| try std.testing.expectEqual(Kind.changed, region.kind);
}

test "one changed block has one padded box" {
    const before = try sample.Canvas.square();
    defer before.deinit();
    const after = try sample.Canvas.square();
    defer after.deinit();
    after.block(10, 12);
    const b = sample.paddedBox(10, 12, sample.block_size, sample.block_size);
    try sample.check(before, after, 1, &.{.{ .before = b, .after = b }});
}

test "two distant blocks are numbered top to bottom" {
    const before = try sample.Canvas.square();
    defer before.deinit();
    const after = try sample.Canvas.square();
    defer after.deinit();
    after.block(40, 40);
    after.block(10, 10);
    const first = sample.paddedBox(10, 10, sample.block_size, sample.block_size);
    const second = sample.paddedBox(40, 40, sample.block_size, sample.block_size);
    try sample.check(before, after, 1, &.{ .{ .before = first, .after = first }, .{ .before = second, .after = second } });
}

test "nearby blocks merge across the allowed gap" {
    const before = try sample.Canvas.square();
    defer before.deinit();
    const after = try sample.Canvas.square();
    defer after.deinit();
    after.block(10, 10);
    after.block(10 + sample.block_size + test_gap, 10);
    const b = sample.paddedBox(10, 10, 2 * sample.block_size + test_gap, sample.block_size);
    try sample.check(before, after, 1, &.{.{ .before = b, .after = b }});
}

test "merging joins a chain of nearby blocks" {
    const before = try sample.Canvas.square();
    defer before.deinit();
    const after = try sample.Canvas.square();
    defer after.deinit();
    for (0..3) |i| after.block(10 + i * (sample.block_size + test_gap), 10);
    try sample.count(before, after, 1);
}

test "shot scale joins paragraph glyphs but leaves a separate button" {
    const scale = 3;
    const before = try sample.Canvas.init(300, 300);
    defer before.deinit();
    const after = try sample.Canvas.init(300, 300);
    defer after.deinit();
    const size = sample.block_size * scale;
    const start = 10 * scale;
    const step = size + test_gap * scale;
    for (0..2) |row| for (0..4) |column| after.red(start + column * step, start + row * step, size, size, 0);
    after.red(start, start + step + size + 16 * scale, 30 * scale, size, 0);
    const result = try sample.compareCanvases(before, after, scale);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.regions.len);
    try std.testing.expectEqual(@as(f64, 3 * step + size + 2 * region_padding * scale), result.regions[0].after.?.width);
    try std.testing.expectEqual(@as(f64, step + size + 2 * region_padding * scale), result.regions[0].after.?.height);
}

test "scattered changes are coalesced to at most eight regions" {
    const spacing = test_gap * 4;
    const side = max_regions + 1;
    const size = (side + 1) * spacing;
    const before = try sample.Canvas.init(size, size);
    defer before.deinit();
    const after = try sample.Canvas.init(size, size);
    defer after.deinit();
    for (1..side + 1) |row| for (1..side + 1) |column| after.block(column * spacing, row * spacing);
    const result = try sample.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.regions.len > 0 and result.regions.len <= max_regions);
}

test "size changes survive the noise minimum and padding clips at canvas edges" {
    const tiny = try sample.Canvas.init(1, 1);
    defer tiny.deinit();
    const tall = try sample.Canvas.init(1, 2);
    defer tall.deinit();
    try sample.check(tiny, tall, 1, &.{.{ .after = Box.fromPixels(0, 0, 1, 2) }});
    const before = try sample.Canvas.square();
    defer before.deinit();
    const after = try sample.Canvas.square();
    defer after.deinit();
    after.block(0, 0);
    const mark = Box.fromPixels(0, 0, sample.block_size + region_padding, sample.block_size + region_padding);
    try sample.check(before, after, 1, &.{.{ .before = mark, .after = mark }});
}

test "an insertion stays separate from a nearby recolour" {
    const before = try sample.Canvas.init(80, 104);
    defer before.deinit();
    before.red(8, 0, 20, 6, 0);
    before.red(20, 34, 4, 4, 0);
    before.red(58, 41, 13, 4, 0);
    before.red(33, 70, 25, 8, 0);
    const after = try before.insert(46, 6, 6);
    defer after.deinit();
    after.red(24, 34, 4, 4, 0);
    after.red(23, 46, 10, 6, 0);
    try sample.check(before, after, 1, &.{
        .{ .before = sample.paddedBox(24, 34, 4, 4), .after = sample.paddedBox(24, 34, 4, 4) },
        .{ .after = sample.paddedBox(23, 46, 10, 6) },
    });
}

test "fractional device scale is applied to box padding" {
    const before = try sample.Canvas.square();
    defer before.deinit();
    const after = try sample.Canvas.square();
    defer after.deinit();
    after.block(20, 24);
    const expected = Box.fromPixels(9, 13, 24, 24);
    try sample.check(before, after, 2.625, &.{.{ .before = expected, .after = expected }});
}

test "many spaced edits still obey the region cap on a dark page" {
    const before = try sample.Canvas.init(1200, 2000);
    defer before.deinit();
    const after = try sample.Canvas.init(1200, 2000);
    defer after.deinit();
    @memset(before.pixels, .{ 18, 18, 22, 255 });
    before.text(10, 180, 10, 5, 220);
    @memcpy(after.pixels, before.pixels);
    for (0..42) |i| {
        after.fill(60 + i % 6 * 190, 60 + i / 6 * 250, 11, 11, .{ 240, 240, 240, 255 });
    }
    const found = try sample.compareCanvases(before, after, 1);
    defer found.deinit(std.testing.allocator);
    try std.testing.expect(found.regions.len <= max_regions);
    try std.testing.expectEqual(@as(usize, 0), found.moves.len);
    for (0..42) |i| try std.testing.expect(sample.hasRegion(found.regions, .after, 65 + i % 6 * 190, 65 + i / 6 * 250, .changed));
}
