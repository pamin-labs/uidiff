//! End-to-end detection of edits inside moving or repeated content.

const std = @import("std");
const uidiff = @import("uidiff");
const sample = uidiff.testing;
const Pixel = uidiff.Pixel;
const Kind = uidiff.Kind;
const region_padding = uidiff.region_padding;
const min_region_pixels = sample.min_region_pixels;

test "stroke edits survive row movement, neighbouring dark text and a wider crop" {
    const width = 240;
    const height = 400;
    const first = 40;
    const moved = 30;
    const dark_y = 6 + 14 * 14;
    const light_y = 13 + 14 * 14;
    const before = try sample.Canvas.init(width, height);
    defer before.deinit();
    before.text(8, 232, 6, 0, 30);
    before.text(8, 232, 13, 50, 190);
    const dark_x = for (before.row(dark_y + 4)[8..], 8..) |pixel, x| {
        if (pixel[0] <= 100) break x;
    } else return error.MissingStroke;
    const light_x = for (before.row(light_y + 4)[8..], 8..) |pixel, x| {
        if (pixel[0] <= 230) break x;
    } else return error.MissingStroke;

    for ([_]bool{ false, true }) |wider_crop| {
        const after = try before.insert(0, 0, 0);
        defer after.deinit();
        after.fill(dark_x + 2, dark_y, 1, 9, sample.inkShade(30, 4));
        if (wider_crop) {
            after.fill(0, 2, 2, 2, sample.inkShade(0, 4));
            after.fill(236, 2, 2, 2, sample.inkShade(0, 4));
        }
        try sample.expectEditAt(before, after, dark_x + 2, dark_y + 4, 20);
    }

    for ([_]enum { dark_widen, light_shift, light_widen }{ .dark_widen, .light_shift, .light_widen }) |edit_kind| {
        const after = try before.insert(first, moved, moved);
        defer after.deinit();
        after.fill(10, 44, 200, 20, .{ 200, 220, 240, 255 });
        const y = light_y + moved;
        switch (edit_kind) {
            .dark_widen => after.fill(dark_x + 2, dark_y + moved, 1, 9, sample.inkShade(30, 4)),
            .light_widen => after.fill(light_x + 3, y, 1, 9, sample.inkShade(190, 4)),
            .light_shift => for (y..y + 9) |row| {
                const pixels = after.row(row);
                std.mem.copyBackwards(Pixel, pixels[light_x + 1 ..][0..5], pixels[light_x..][0..5]);
                pixels[light_x] = sample.white;
            },
        }
        if (edit_kind == .dark_widen) {
            try sample.expectEditAt(before, after, dark_x + 2, dark_y + moved + 4, 20);
        } else {
            const x = light_x + @as(usize, if (edit_kind == .light_shift) 2 else 3);
            try sample.expectEditAt(before, after, x, y + 4, 20);
        }
    }
}

test "small icon motion stays local in a textured viewport" {
    const width = 240;
    const height = 300;
    const color: Pixel = .{ 200, 40, 40, 255 };
    const before = try sample.Canvas.init(width, height);
    defer before.deinit();
    before.text(8, 232, 6, 0, 30);
    before.fill(100, 140, 20, 20, color);
    for (2..4) |shift| {
        const after = try sample.Canvas.init(width, height);
        defer after.deinit();
        after.text(8, 232, 6, 0, 30);
        after.fill(100, 140 + shift, 20, 20, color);
        try sample.expectEditAt(before, after, 110, 159 + shift, 20 + 2 * region_padding);
    }
}

test "edited moved lines still report narrow changes when matching nearby strokes" {
    const before = try sample.Canvas.init(240, 400);
    defer before.deinit();
    before.text(8, 232, 6, 0, 30);
    const sizes = [_][2]usize{ .{ 3, 6 }, .{ 1, 1 }, .{ 2, 2 }, .{ 6, 2 }, .{ 12, 9 }, .{ 3, 20 }, .{ 3, 30 } };
    for ([_]usize{ 0, 60 }) |growth| {
        const base = try before.insert(40, 60, growth);
        defer base.deinit();
        base.fill(10, 44, 200, 50, .{ 200, 220, 240, 255 });
        const after = try sample.Canvas.init(base.view.width, base.view.height);
        defer after.deinit();
        @memcpy(after.pixels, base.pixels);
        const limit: usize = if (growth == 0) 380 else 440;
        for (sizes) |size| {
            var y: usize = 110;
            while (y + size[1] < limit) : (y += 3) {
                const tone = sample.inkShade(30, 4);
                var hits: usize = 0;
                for (y..y + size[1]) |row| {
                    for (base.row(row)[150..][0..size[0]]) |pixel| hits += @intFromBool(!std.meta.eql(pixel, tone));
                }
                if (hits < min_region_pixels) continue;
                after.fill(150, y, size[0], size[1], tone);
                const result = try sample.compareCanvases(before, after, 1);
                defer result.deinit(std.testing.allocator);
                const banner_kind: ?Kind = if (size[0] == 3 and size[1] == 6) .inserted else null;
                try std.testing.expect(sample.hasRegion(result.regions, .after, 30, 50, banner_kind));
                var seen = false;
                for (y..y + size[1]) |row| {
                    for (150..150 + size[0]) |x| {
                        if (!std.meta.eql(base.row(row)[x], tone) and sample.hasRegion(result.regions, .after, x, row, null)) seen = true;
                    }
                }
                try std.testing.expect(seen);
                for (result.regions) |region| {
                    if (region.after) |box| {
                        if (box.y < 100 and box.height >= 50) continue;
                    }
                    if (region.before) |box| try std.testing.expect(box.width <= @as(f64, @floatFromInt(size[0] + 60)));
                    if (region.after) |box| try std.testing.expect(box.width <= @as(f64, @floatFromInt(size[0] + 60)));
                }
                if (y == 374 and size[0] == 3 and size[1] == 6) try std.testing.expect(sample.hasRegion(result.regions, .after, 151, y + 2, .changed));
                after.copyColumns(base, 150, 150 + size[0], y, y + size[1], y);
            }
        }
    }
    const after = try before.insert(40, 60, 60);
    defer after.deinit();
    after.fill(10, 44, 200, 50, .{ 200, 220, 240, 255 });
    after.fill(29, 110, 3, 6, sample.inkShade(30, 4));
    const edit = try sample.compareCanvases(before, after, 1);
    defer edit.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), edit.regions.len);
    try std.testing.expect(sample.hasRegion(edit.regions, .after, 30, 112, .changed));
}

test "thickened or recoloured underlines on moved text stay local" {
    const before = try sample.Canvas.init(240, 400);
    defer before.deinit();
    before.text(8, 232, 6, 0, 30);
    before.fill(40, 250, 120, 1, sample.inkShade(30, 4));
    before.fill(40, 300, 120, 1, sample.inkShade(200, 4));
    for ([_]usize{ 0, 281, 331, 330 }, [_]u8{ 0, 30, 200, 230 }) |y, tone| {
        const after = try before.insert(40, 30, 30);
        defer after.deinit();
        after.fill(10, 44, 200, 20, .{ 200, 220, 240, 255 });
        if (y != 0) after.fill(40, y, 120, 1, sample.inkShade(tone, 4));
        const result = try sample.compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        if (y == 0) {
            try std.testing.expectEqual(@as(usize, 1), result.regions.len);
            continue;
        }
        try std.testing.expectEqual(@as(usize, 2), result.regions.len);
        try std.testing.expect(sample.hasRegion(result.regions, .after, 40, y, .changed));
        try std.testing.expect(sample.hasRegion(result.regions, .after, 159, y, .changed));
        for (result.regions) |region| {
            if (region.before) |box| try std.testing.expect(box.width <= 120 + 2 * region_padding);
        }
    }
}

test "thicker strokes through repeating text survive temporary row shifts" {
    const base = try sample.Canvas.init(240, 400);
    defer base.deinit();
    base.text(8, 232, 6, 0, 30);
    const before = try sample.Canvas.init(240, 400);
    defer before.deinit();
    const after = try sample.Canvas.init(240, 400);
    defer after.deinit();
    for ([_]u8{ 30, 120, 200 }) |tone| {
        for (1..3) |extra| {
            for (100..380) |y| {
                @memcpy(before.pixels, base.pixels);
                before.fill(20, y, 200, 1, sample.inkShade(tone, 4));
                @memcpy(after.pixels, before.pixels);
                after.fill(20, y + 1, 200, extra, sample.inkShade(tone, 4));
                const result = try sample.compareCanvases(before, after, 1);
                defer result.deinit(std.testing.allocator);
                if (result.regions.len == 0) {
                    std.debug.print("Missed tone {d} thickened by {d} at row {d}\n", .{ tone, extra, y });
                    return error.TestExpectedEqual;
                }
            }
        }
    }
}

test "a light stem edit stays visible beside touching dark text" {
    const before = try sample.Canvas.init(240, 400);
    defer before.deinit();
    before.text(8, 232, 6, 0, 30);
    var line: usize = 20;
    while (line + 9 < before.view.height) : (line += 28) {
        before.fill(100, line, 2, 9, sample.inkShade(30, 4));
        before.fill(103, line, 2, 9, sample.inkShade(190, 4));
    }
    const target = 20 + 28 * 6;
    for ([_]enum { control, widened, right, left, unmoved }{ .control, .widened, .right, .left, .unmoved }) |edit| {
        const shift: usize = if (edit == .unmoved) 0 else 30;
        const after = try before.insert(10, shift, shift);
        defer after.deinit();
        if (shift != 0) after.fill(10, 12, 200, 20, .{ 200, 220, 240, 255 });
        const y = target + shift;
        switch (edit) {
            .control => {
                const result = try sample.compareCanvases(before, after, 1);
                defer result.deinit(std.testing.allocator);
                try std.testing.expectEqual(@as(usize, 1), result.regions.len);
                try std.testing.expect(sample.hasRegion(result.regions, .after, 110, 22, .inserted));
                continue;
            },
            .widened, .unmoved => after.fill(105, y, 1, 9, sample.inkShade(190, 4)),
            .right => {
                after.fill(103, y, 1, 9, sample.white);
                after.fill(105, y, 1, 9, sample.inkShade(190, 4));
            },
            .left => {
                after.fill(102, y, 1, 9, sample.inkShade(190, 4));
                after.fill(104, y, 1, 9, sample.white);
            },
        }
        const x: usize = switch (edit) {
            .right => 104,
            .left => 103,
            else => 105,
        };
        try sample.expectEditAt(before, after, x, y + 4, 24);
    }
}

test "repeated table rows keep recoloured or deleted cells after a shift" {
    const before = try sample.Canvas.init(240, 400);
    defer before.deinit();
    var y: usize = 0;
    while (y + 20 <= before.view.height) : (y += 20) {
        before.fill(10, y + 2, 220, 1, sample.inkShade(220, 4));
        before.fill(20, y + 8, 40, 6, sample.inkShade(90, 4));
        before.fill(120, y + 8, 40, 6, sample.inkShade(90, 4));
    }
    for ([_]usize{ 0, 40 }) |growth| {
        const after = try before.insert(60, 40, growth);
        defer after.deinit();
        after.fill(10, 64, 200, 30, .{ 200, 220, 240, 255 });
        for ([_]Pixel{ .{ 90, 90, 160, 255 }, sample.white }) |color| {
            after.fill(120, 248, 40, 6, color);
            const result = try sample.compareCanvases(before, after, 1);
            defer result.deinit(std.testing.allocator);
            try std.testing.expect(sample.hasRegion(result.regions, .after, 140, 250, .changed));
            if (growth == 0) {
                try std.testing.expectEqual(@as(usize, 0), result.moves.len);
                try std.testing.expectEqual(@as(usize, 2), result.regions.len);
                for (result.regions) |region| {
                    try std.testing.expectEqual(Kind.changed, region.kind);
                    try std.testing.expectEqual(region.before, region.after);
                }
            }
        }
    }
}

test "anchor boundaries and translucent edits remain visible on moved rows" {
    const before = try sample.Canvas.init(240, 400);
    defer before.deinit();
    before.text(8, 232, 6, 0, 30);
    for ([_]usize{ 99, 100, 101, 113, 114, 115 }) |y| {
        const after = try before.insert(40, 60, 60);
        defer after.deinit();
        after.fill(10, 44, 200, 50, .{ 200, 220, 240, 255 });
        after.fill(60, y, 3, 3, sample.inkShade(30, 4));
        const result = try sample.compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(sample.hasRegion(result.regions, .after, 61, y + 1, null));
    }

    const transparent = try sample.Canvas.init(200, 300);
    defer transparent.deinit();
    @memset(transparent.pixels, .{ 255, 255, 255, 0 });
    transparent.text(8, 192, 6, 0, 30);
    const after = try transparent.insert(40, 30, 30);
    defer after.deinit();
    after.fill(0, 40, 200, 30, .{ 255, 255, 255, 0 });
    after.fill(10, 44, 180, 20, .{ 200, 220, 240, 255 });
    after.fill(100, 200, 4, 4, .{ 255, 0, 0, 120 });
    const result = try sample.compareCanvases(transparent, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(sample.hasRegion(result.regions, .after, 101, 201, null));
}

test "redrawn status pills in stationary rows cannot borrow each other's offset" {
    const before = try sample.Canvas.init(360, 230);
    defer before.deinit();
    const after = try sample.Canvas.init(360, 230);
    defer after.deinit();
    for ([_]sample.Canvas{ before, after }) |canvas| {
        for (0..4) |i| canvas.line(18, 220, 28 + 48 * i, i, 48);
    }
    const a: uidiff.Pixel = .{ 160, 190, 230, 255 };
    const b: uidiff.Pixel = .{ 242, 150, 120, 255 };
    const c: uidiff.Pixel = .{ 146, 210, 145, 255 };
    for ([_]usize{ 64, 112 }, [_]uidiff.Pixel{ a, b }, [_]uidiff.Pixel{ c, a }) |y, old, new| {
        before.fill(245, y, 70, 24, old);
        after.fill(245, y, 70, 24, new);
        before.fill(255, y + 9, 18, 5, sample.inkShade(60, 4));
        after.fill(255, y + 9, 18, 5, sample.inkShade(60, 4));
    }
    const result = try sample.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.regions.len);
    for (result.regions) |region| try std.testing.expectEqual(Kind.changed, region.kind);
    try std.testing.expectEqual(@as(usize, 0), result.moves.len);
}
