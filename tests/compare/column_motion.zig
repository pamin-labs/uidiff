//! End-to-end alignment of independent column lanes and strides.

const std = @import("std");
const diff = @import("diff_scenarios");
const sample = diff.test_support;
const values = sample.values;
const Box = values.Box;
const Pixel = values.Pixel;
const Kind = values.Kind;
const region_padding = diff.region_padding;
const min_region_pixels = sample.min_region_pixels;

fn sidebarPage() !sample.Canvas {
    const before = try sample.Canvas.init(320, 400);
    before.text(4, 56, 6, 100, 30);
    before.text(96, 316, 6, 0, 30);
    return before;
}

fn growMainColumn(before: sample.Canvas) !sample.Canvas {
    const width = before.view.width;
    const height = before.view.height;
    const inserted = 60;
    const after = try sample.Canvas.init(width, height + inserted);
    after.copyColumns(before, 0, 60, 0, height, 0);
    after.copyColumns(before, 96, width, 0, 40, 0);
    after.copyColumns(before, 96, width, 40, height, 40 + inserted);
    after.fill(100, 44, 200, 50, .{ 200, 220, 240, 255 });
    return after;
}

test "card corner edits never align their narrow border columns as moves" {
    const before = try sample.Canvas.init(800, 600);
    defer before.deinit();
    const after = try sample.Canvas.init(800, 600);
    defer after.deinit();
    @memset(before.pixels, .{ 245, 245, 247, 255 });
    @memset(after.pixels, .{ 245, 245, 247, 255 });
    for ([_]usize{ 60, 300 }) |y| {
        sample.strokeRounded(before, y, 4);
        sample.strokeRounded(after, y, 16);
        // A separator can have the same ink as the outline.
        if (y == 300) {
            const edge = before.row(y)[480];
            before.fill(222, y + 99, 536, 2, edge);
            after.fill(222, y + 99, 536, 2, edge);
        }
    }
    const result = try sample.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.moves.len);
    try std.testing.expectEqual(@as(usize, 2), result.regions.len);
    for (result.regions) |edit| {
        try std.testing.expectEqual(Kind.changed, edit.kind);
        try std.testing.expectEqual(edit.before, edit.after);
    }
}

test "a blank sidebar group keeps a new mark stationary beside inserted cards" {
    const before = try sample.Canvas.init(600, 500);
    defer before.deinit();
    const after = try sample.Canvas.init(600, 500);
    defer after.deinit();
    const sidebar: Pixel = .{ 235, 238, 245, 255 };
    before.fill(0, 0, 180, 500, sidebar);
    for (0..10) |i_row| before.line(12, 55, 20 + 36 * i_row, 19 + i_row, 40);
    sample.fillCardList(before, null);
    for ([_][2]usize{ .{ 60, 92 }, .{ 130, 122 }, .{ 160, 142 }, .{ 130, 205 }, .{ 160, 390 } }) |position| {
        const mark_x, const mark_y = position;
        @memcpy(after.pixels, before.pixels);
        after.fill(180, 0, 420, 500, @splat(255));
        sample.fillCardList(after, 3);
        after.fill(mark_x, mark_y, 17, 17, .{ 200, 40, 40, 255 });

        const result = try sample.compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), result.regions.len);
        try std.testing.expect(sample.hasRegion(result.regions, .before, mark_x + 4, mark_y + 6, .changed));
        try std.testing.expect(sample.hasRegion(result.regions, .after, mark_x + 4, mark_y + 6, .changed));
        try std.testing.expect(sample.hasRegion(result.regions, .after, 560, 150, .inserted));
        try std.testing.expectEqual(@as(usize, 1), result.moves.len);
        try std.testing.expectEqual(@as(usize, 40), result.moves[0].after.y - result.moves[0].before.y);
        try std.testing.expect(result.moves[0].x.count() >= 180);
        try std.testing.expect(result.moves[0].width.count() >= 380);
    }
}

test "added columns and changed overlap survive different strides" {
    const before = try sample.Canvas.init(40, 40);
    defer before.deinit();
    const after = try sample.Canvas.init(50, 40);
    defer after.deinit();
    after.block(10, 10);
    const mark = sample.paddedBox(10, 10, sample.block_size, sample.block_size);
    try sample.check(before, after, 1, &.{ .{ .after = Box.fromPixels(40 - region_padding, 0, 10 + region_padding, 40) }, .{ .before = mark, .after = mark } });
}

test "stationary sidebar with a small colour difference does not prevent a 606-pixel column shift" {
    const height = 1400;
    const at = 80;
    const shift = 606;
    const before = try sample.Canvas.init(100, height);
    defer before.deinit();
    const after = try sample.Canvas.init(100, height);
    defer after.deinit();
    for (0..height) |y| before.red(2, y, 10, 1, @intCast((y * 7) % 250));
    sample.paintBands(before, 30, 70);
    @memcpy(after.pixels, before.pixels);
    for (0..height) |y| after.row(y)[2][1] = 254;
    for (at..height) |y| {
        if (y < at + shift) {
            @memset(after.row(y)[20..], .{ 255, 255, 255, 255 });
        } else @memcpy(after.row(y)[20..], before.row(y - shift)[20..]);
    }
    after.red(35, 90, 40, 40, 90);
    const result = try sample.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expectEqual(Kind.inserted, result.regions[0].kind);
    const box = result.regions[0].after.?;
    try std.testing.expect(box.x >= 20 and box.y >= at - region_padding and box.bottom() <= at + shift + region_padding);
}

test "wider viewport aligns rows and shows only the added strip" {
    const before = try sample.Canvas.init(70, 90);
    defer before.deinit();
    const after = try sample.Canvas.init(80, 90);
    defer after.deinit();
    before.red(8, 0, 15, 4, 0);
    before.red(18, 30, 22, 6, 0);
    before.red(14, 62, 10, 5, 0);
    for (0..88) |y| @memcpy(after.row(y + 2)[0..70], before.row(y));
    try sample.checkInsertion(before, after, Box.fromPixels(70 - region_padding, 0, 10 + region_padding, 90));
}

test "a growing main column aligns beside a static sidebar" {
    const before = try sidebarPage();
    defer before.deinit();
    const after = try growMainColumn(before);
    defer after.deinit();
    try sample.check(before, after, 1, &.{.{ .after = sample.paddedBox(100, 44, 200, 50) }});
}

test "growing and shrinking columns keep their insertion and independent edits" {
    const before = try sidebarPage();
    defer before.deinit();
    const cases = [_]struct { x: usize, y: usize, width: usize, height: usize, kind: Kind, tone: u8 = 30 }{
        .{ .x = 200, .y = 300, .width = 3, .height = 6, .kind = .changed },
        .{ .x = 20, .y = 300, .width = 3, .height = 6, .kind = .changed },
        .{ .x = 20, .y = 430, .width = 20, .height = 8, .kind = .inserted },
        .{ .x = 0, .y = 400, .width = 60, .height = 60, .kind = .inserted, .tone = 230 },
        .{ .x = 30, .y = 399, .width = 2, .height = 61, .kind = .changed, .tone = 120 },
        .{ .x = 150, .y = 20, .width = 3, .height = 6, .kind = .inserted },
        .{ .x = 150, .y = 150, .width = 3, .height = 6, .kind = .changed },
        .{ .x = 150, .y = 250, .width = 3, .height = 6, .kind = .changed },
        .{ .x = 150, .y = 300, .width = 3, .height = 6, .kind = .changed },
        .{ .x = 150, .y = 380, .width = 3, .height = 6, .kind = .changed },
        .{ .x = 150, .y = 440, .width = 3, .height = 6, .kind = .changed },
    };
    for (cases) |edit| {
        const after = try growMainColumn(before);
        defer after.deinit();
        after.fill(edit.x, edit.y, edit.width, edit.height, sample.inkShade(edit.tone, 4));
        const result = try sample.compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(sample.hasRegion(result.regions, .after, 120, 50, .inserted));
        try std.testing.expect(sample.hasRegion(result.regions, .after, edit.x + edit.width / 2, edit.y + edit.height / 2, edit.kind));
        if (edit.y != 20) try std.testing.expectEqual(@as(usize, 2), result.regions.len);
        if (edit.x == 200) {
            const reverse = try sample.compareCanvases(after, before, 1);
            defer reverse.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 2), reverse.regions.len);
            try std.testing.expect(sample.hasRegion(reverse.regions, .before, 120, 50, .removed));
            try std.testing.expect(sample.hasRegion(reverse.regions, .before, 201, 302, .changed));
        }
    }
}

test "both moving columns preserve a two-sided edit in each" {
    const height = 400;
    const before = try sidebarPage();
    defer before.deinit();
    const after = try sample.Canvas.init(320, height);
    defer after.deinit();
    after.copyColumns(before, 0, 60, 0, 30, 0);
    after.copyColumns(before, 0, 60, 30, height - 20, 50);
    after.copyColumns(before, 96, 320, 0, 40, 0);
    after.copyColumns(before, 96, 320, 40, height - 60, 100);
    after.fill(4, 32, 50, 16, .{ 220, 200, 240, 255 });
    after.fill(100, 44, 200, 50, .{ 200, 220, 240, 255 });
    after.fill(28, 302, 3, 6, sample.inkShade(30, 4));
    after.fill(200, 250, 3, 6, sample.inkShade(30, 4));
    const result = try sample.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), result.regions.len);
    try std.testing.expect(sample.hasRegion(result.regions, .after, 29, 304, .changed));
    try std.testing.expect(sample.hasRegion(result.regions, .after, 201, 252, .changed));
}

test "sparse marks and real extensions survive independent column alignment" {
    const height = 400;
    const before = try sidebarPage();
    defer before.deinit();
    const after = try sample.Canvas.init(320, height + 60);
    defer after.deinit();
    after.copyColumns(before, 0, 60, 0, height, 0);
    after.copyColumns(before, 96, 320, 0, 40, 0);
    after.copyColumns(before, 96, 320, 40, height, 100);
    after.fill(100, 44, 200, 50, .{ 200, 220, 240, 255 });
    for ([_][4]usize{
        .{ 20, 430, 2, 2 }, .{ 20, 430, 1, 4 }, .{ 20, 430, 4, 1 },
        .{ 20, 450, 1, 1 }, .{ 5, 455, 30, 1 }, .{ 20, 430, 10, 10 },
    }, 0..) |m, i| {
        const tone: u8 = if (i == 5) 240 else 30;
        after.fill(m[0], m[1], m[2], m[3], sample.inkShade(tone, 4));
        const result = try sample.compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(sample.hasRegion(result.regions, .after, 120, 50, .inserted));
        try std.testing.expectEqual(m[2] * m[3] >= min_region_pixels, sample.hasRegion(result.regions, .after, m[0], m[1], .inserted));
        const reverse = try sample.compareCanvases(after, before, 1);
        defer reverse.deinit(std.testing.allocator);
        try std.testing.expectEqual(m[2] * m[3] >= min_region_pixels, sample.hasRegion(reverse.regions, .before, m[0], m[1], .removed));
        after.fill(m[0], m[1], m[2], m[3], @splat(255));
    }
}

test "independently aligned columns retain clipped text and different strides" {
    const full = try sample.Canvas.init(320, 480);
    defer full.deinit();
    full.text(4, 56, 6, 100, 30);
    full.text(96, 296, 6, 0, 30);
    for ([_]usize{ 300, 320 }, [_]usize{ 400, 403 }) |width, height| {
        const before = try sample.Canvas.init(width, height);
        defer before.deinit();
        before.copyColumns(full, 0, width, 0, height, 0);
        const after = try sample.Canvas.init(320, height + 60);
        defer after.deinit();
        after.copyColumns(full, 0, 60, 0, if (width == 300) height else height + 60, 0);
        after.copyColumns(before, 96, width, 0, 40, 0);
        after.copyColumns(before, 96, width, 40, height, 100);
        after.fill(100, 44, 180, 50, .{ 200, 220, 240, 255 });
        const x: usize = if (width == 300) 20 else 30;
        const y: usize = if (width == 300) 440 else 300;
        after.fill(x, y, if (width == 300) 6 else 3, 6, sample.inkShade(30, 4));
        const result = try sample.compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(sample.hasRegion(result.regions, .after, 120, 50, .inserted));
        try std.testing.expect(sample.hasRegion(result.regions, .after, x + 2, y + 2, null));
        if (width == 320) {
            try std.testing.expectEqual(@as(usize, 3), result.regions.len);
            try std.testing.expect(sample.hasRegion(result.regions, .after, 30, 440, .inserted));
            try std.testing.expect(sample.hasRegion(result.regions, .after, x + 2, y + 2, .changed));
            for (result.regions) |region| {
                if (region.kind != .changed) continue;
                try std.testing.expect(region.after.?.width <= 3 + 2 * region_padding);
            }
        }
    }
}

test "a moved main column describes its own x span beside a fixed sidebar" {
    const before = try sample.Canvas.init(320, 400);
    defer before.deinit();
    before.text(4, 56, 50, 100, 30);
    before.text(96, 316, 50, 0, 30);
    before.fill(0, 0, 320, 40, sample.inkShade(45, 4));
    before.fill(0, 350, 320, 50, sample.inkShade(60, 4));
    const after = try sample.Canvas.init(320, 400);
    defer after.deinit();
    @memcpy(after.pixels, before.pixels);
    after.fill(96, 40, 224, 310, sample.inkShade(255, 4));
    after.copyColumns(before, 96, 320, 40, 120, 40);
    after.copyColumns(before, 96, 320, 120, 310, 160);
    after.fill(100, 124, 200, 32, .{ 200, 220, 240, 255 });
    for (0..2) |pass| {
        if (pass == 1) after.fill(20, 200, 3, 6, sample.inkShade(30, 4));
        const result = try sample.compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(pass + 1, result.regions.len);
        try std.testing.expectEqual(@as(usize, 1), result.moves.len);
        try std.testing.expectEqual(@as(usize, 96), result.moves[0].x.count());
        try std.testing.expectEqual(@as(usize, 217), result.moves[0].width.count());
        try std.testing.expectEqual(@as(usize, 40), result.moves[0].after.y - result.moves[0].before.y);
    }
}

test "a compact insertion at the end of a narrow column retains its shift" {
    const before = try sample.Canvas.init(400, 600);
    defer before.deinit();
    before.fill(140, 20, 250, 520, sample.inkShade(235, 4));
    for (0..20) |i| before.fill(20, 10 + 18 * i, 18, if (i == 19) 4 else 7, sample.inkShade(@intCast(20 + i), 4));
    const after = try sample.Canvas.init(400, 600);
    defer after.deinit();
    @memcpy(after.pixels, before.pixels);
    const row = 10 + 19 * 18;
    after.copyColumns(before, 20, 38, row, 580, row + 20);
    after.fill(20, row, 18, 20, .{ 200, 220, 240, 255 });
    const found = try sample.compareCanvases(before, after, 1);
    defer found.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), found.regions.len);
    try std.testing.expectEqual(Kind.inserted, found.regions[0].kind);
    try std.testing.expect(found.moves.len != 0);
    try std.testing.expectEqual(@as(usize, 20), found.moves[0].after.y - found.moves[0].before.y);
}

test "solid overpaints of repeated lines stay two-sided across column widths" {
    for ([_]usize{ 600, 2000 }) |height| {
        const before = try sample.Canvas.init(400, height);
        defer before.deinit();
        const after = try sample.Canvas.init(400, height);
        defer after.deinit();
        var y: usize = 10;
        while (y + 10 < height) : (y += 18) before.line(10, 170, y, y / 18, 30);
        for ([_][2]usize{ .{ 50, 121 }, .{ 10, 191 }, .{ 10, 231 }, .{ 0, 400 } }) |span| {
            y = 40;
            while (y < height - 80) : (y += 37) {
                for ([_]usize{ 8, 20, 41 }) |h| {
                    @memcpy(after.pixels, before.pixels);
                    after.fill(span[0], y, span[1] - span[0], h, .{ 255, 0, 0, 255 });
                    const found = try sample.compareCanvases(before, after, 1);
                    defer found.deinit(std.testing.allocator);
                    try std.testing.expectEqual(@as(usize, 1), found.regions.len);
                    try std.testing.expectEqual(@as(usize, 0), found.moves.len);
                    try std.testing.expectEqual(found.regions[0].before.?, found.regions[0].after.?);
                }
            }
        }
    }
}
