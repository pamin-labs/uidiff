//! End-to-end alignment of moving and repeated row bands.

const std = @import("std");
const uidiff = @import("uidiff");
const sample = uidiff.testing;
const expect = sample.expect;
const canvases = sample.canvas;

const compare = uidiff.compare;
const Box = uidiff.Box;
const Pixel = uidiff.Pixel;
const Kind = uidiff.Kind;
const region_padding = uidiff.region_padding;

test "middle insertions box only new content with and without image growth" {
    const before = try canvases.Canvas.square();
    defer before.deinit();
    before.red(10, 8, 18, 4, 0);
    before.red(28, 40, 12, 4, 0);
    for ([_][2]usize{ .{ 0, 2 }, .{ 0, 6 }, .{ 6, 6 } }) |p| {
        const after = try before.insert(24, p[1], p[0]);
        defer after.deinit();
        after.red(15, 24, 20, p[1], 0);
        try expect.checkInsertion(before, after, expect.paddedBox(15, 24, 20, p[1]));
    }
}

test "repeated row tops align at the inserted row and keep its columns together" {
    const before = try canvases.Canvas.init(260, 240);
    defer before.deinit();
    for (0..4) |i_row| {
        const y = 10 + 48 * i_row;
        before.fill(8, y, 28, 34, canvases.inkShade(80, 4));
        before.fill(76, y, 100, 12, canvases.inkShade(220, 4));
        before.line(77, 169, y + 12, i_row, 40);
        before.fill(224, y + 12, 12, 12, canvases.inkShade(60 + @as(u8, @intCast(21 * i_row)), 4));
    }
    const after = try before.insert(58, 48, 48);
    defer after.deinit();
    after.copyRows(58, before, 58, 70);
    after.fill(8, 70, 28, 22, canvases.inkShade(80, 4));
    after.line(76, 156, 70, 123, 40);
    after.fill(224, 70, 12, 12, canvases.inkShade(123, 4));

    const result = try expect.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try expect.checkRegions(result.regions, &.{.{ .after = expect.paddedBox(8, 58, 228, 34) }});
    try std.testing.expectEqual(@as(usize, 1), result.moves.len);
    try std.testing.expectEqual(@as(usize, 48), result.moves[0].after.y - result.moves[0].before.y);
}

test "exact panel shifts outrank repeated stationary paint" {
    const before = try canvases.Canvas.init(320, 320);
    defer before.deinit();
    const after = try canvases.Canvas.init(320, 320);
    defer after.deinit();
    const paint = canvases.inkShade(40, 4);
    before.fill(80, 40, 176, 240, paint);
    before.fill(81, 242, 174, 38, canvases.inkShade(55, 4));
    before.fill(92, 251, 15, 7, canvases.inkShade(190, 4));
    before.fill(100, 67, 23, 5, canvases.inkShade(180, 4));
    before.fill(94, 110, 100, 4, canvases.inkShade(155, 4));
    for (110..114) |y| before.fill(104 + y % 3, y, 8, 1, canvases.inkShade(210, 4));
    @memcpy(after.pixels, before.pixels);
    after.fill(80, 110, 176, 26, paint);
    after.fill(100, 110, 94, 4, canvases.inkShade(130, 4));
    after.copyColumns(before, 80, 256, 110, 216, 136);

    const result = try expect.compareCanvases(before, after, 2);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expect(expect.hasRegion(result.regions, .after, 150, 112, .inserted));
    try std.testing.expectEqual(@as(usize, 1), result.moves.len);
    try std.testing.expectEqual(@as(usize, 26), result.moves[0].after.y - result.moves[0].before.y);
    try std.testing.expect(result.moves[0].width.count() < before.view.width);
}

test "an inserted row against repeated background is one-sided" {
    const before = try canvases.Canvas.square();
    defer before.deinit();
    const after = try canvases.Canvas.init(64, 65);
    defer after.deinit();
    after.red(0, 24, 20, 1, 0);
    try expect.check(before, after, 1, &.{.{ .after = Box.fromPixels(0, 24 - region_padding, 20 + region_padding, 1 + 2 * region_padding) }});
}

test "two-pixel vertical shift boxes the edited word and any revealed content" {
    const before = try canvases.Canvas.square();
    defer before.deinit();
    const after = try canvases.Canvas.square();
    defer after.deinit();
    before.red(8, 0, 10, 4, 0);
    before.red(18, 20, 14, 4, 0);
    before.red(40, 40, 13, 4, 0);
    before.red(30, 60, 11, 4, 0);
    after.copyRows(2, before, 0, 62);
    after.red(32, 22, 3, 4, 0);
    const old = expect.paddedBox(32, 20, 3, 4);
    const new = expect.paddedBox(32, 22, 3, 4);
    try expect.check(before, after, 1, &.{.{ .before = old, .after = new }});
    try expect.check(after, before, 1, &.{
        .{ .before = new, .after = old },
        .{ .after = Box.fromPixels(26, 58, 19, 6) },
    });
}

test "solid eight-row band between distinct backgrounds gets a full-width box" {
    const before = try canvases.Canvas.init(80, 120);
    defer before.deinit();
    before.red(0, 0, 80, 40, 235);
    before.red(0, 40, 80, 80, 55);
    before.red(11, 68, 21, 7, 0);
    const after = try before.insert(40, 8, 8);
    defer after.deinit();
    after.red(0, 40, 80, 8, 130);
    try expect.check(before, after, 1, &.{.{ .after = Box.fromPixels(0, 40 - region_padding, 80, 8 + 2 * region_padding) }});
}

test "unrelated tall shots beyond the budget compare by position" {
    const before = try canvases.Canvas.init(80, 6000);
    defer before.deinit();
    const after = try canvases.Canvas.init(80, 6000);
    defer after.deinit();
    for ([_]canvases.Canvas{ before, after }, [_]usize{ 3, 12 }, [_]usize{ 100, 102 }) |shot, x, y| {
        shot.red(x, 0, 4, y, 0);
        shot.red(55, y, 10, 6, 0);
        shot.red(x, y + 6, 4, 6000 - y - 6, 0);
    }
    const result = try expect.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    const marker = expect.paddedBox(55, 100, 10, 8);
    for (result.regions) |region| {
        if (std.meta.eql(@as(?Box, marker), region.before) and std.meta.eql(@as(?Box, marker), region.after)) break;
    } else return error.MissingMarker;
}

test "a tall image against its reverse stops at the edit budget" {
    const height = uidiff.max_extent;
    const old = try std.testing.allocator.alloc(Pixel, height);
    defer std.testing.allocator.free(old);
    const new = try std.testing.allocator.alloc(Pixel, height);
    defer std.testing.allocator.free(new);
    for (old, 0..) |*pixel, row| pixel.* = .{ @intCast(row % 256), @intCast(row / 256 % 256), 0, 255 };
    for (new, 0..) |*pixel, row| pixel.* = old[height - 1 - row];
    const result = try compare(std.testing.allocator, .{ .width = 1, .height = height, .pixels = old }, .{ .width = 1, .height = height, .pixels = new }, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.regions.len > 0);
}

test "swapped and repeated lines remain visible between shifted anchors" {
    const before = try canvases.Canvas.init(240, 400);
    defer before.deinit();
    before.text(8, 232, 6, 0, 30);
    for ([_]bool{ true, false }) |swap| {
        const after = try before.insert(40, 30, 30);
        defer after.deinit();
        after.fill(10, 44, 200, 20, .{ 200, 220, 240, 255 });
        after.copyRows(232, before, if (swap) 216 else 34, if (swap) 225 else 43);
        if (swap) after.copyRows(246, before, 202, 211);
        const result = try expect.compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(expect.hasRegion(result.regions, .after, 120, 236, null));
        if (swap) try std.testing.expect(expect.hasRegion(result.regions, .after, 120, 250, null));
    }
}

test "one or two displacements in a fixed thread get distinct move ranges" {
    const before = try canvases.Canvas.init(240, 400);
    defer before.deinit();
    before.text(8, 232, 50, 0, 30);
    before.fill(0, 0, 240, 40, canvases.inkShade(45, 4));
    before.fill(0, 350, 240, 50, canvases.inkShade(60, 4));
    const after = try canvases.Canvas.init(240, 400);
    defer after.deinit();
    for ([_]bool{ false, true }) |remove| {
        @memset(after.pixels, canvases.inkShade(255, 4));
        after.copyRows(0, before, 0, 100);
        after.copyRows(120, before, 100, if (remove) 244 else 230);
        after.fill(10, 104, 220, 12, .{ 200, 220, 240, 255 });
        if (remove) {
            after.copyRows(264, before, 286, 350);
        } else {
            after.fill(10, 254, 220, 12, .{ 240, 220, 200, 255 });
            after.copyRows(270, before, 230, 310);
        }
        after.copyRows(350, before, 350, 400);
        const found = try expect.compareCanvases(before, after, 1);
        defer found.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), found.regions.len);
        try std.testing.expectEqual(@as(usize, 2), found.moves.len);
        try std.testing.expectEqual(@as(usize, 20), found.moves[0].after.y - found.moves[0].before.y);
        if (remove) {
            try std.testing.expect(expect.hasRegion(found.regions, .before, 50, 255, .removed));
            try std.testing.expectEqual(@as(usize, 22), found.moves[1].before.y - found.moves[1].after.y);
        } else {
            try std.testing.expect(expect.hasRegion(found.regions, .after, 50, 260, .inserted));
            try std.testing.expectEqual(@as(usize, 40), found.moves[1].after.y - found.moves[1].before.y);
        }
    }
}

test "overpainting repeated lines does not create a row movement" {
    const before = try canvases.Canvas.init(240, 400);
    defer before.deinit();
    var y: usize = 10;
    while (y + 9 < before.view.height) : (y += 18) before.line(8, 232, y, 4, 30);
    const after = try canvases.Canvas.init(240, 400);
    defer after.deinit();
    for ([_]usize{ 8, 20, 41 }) |height| {
        for ([_]usize{ 50, 120 }) |width| {
            for (0..32) |step| {
                const top = 20 + step * 10;
                @memcpy(after.pixels, before.pixels);
                after.fill(52, top, width, height, .{ 185, 25, 40, 255 });
                const result = try expect.compareCanvases(before, after, 1);
                defer result.deinit(std.testing.allocator);
                errdefer std.debug.print("overpaint y={d} width={d} height={d}\n", .{ top, width, height });
                try std.testing.expectEqual(@as(usize, 1), result.regions.len);
                try std.testing.expectEqual(Kind.changed, result.regions[0].kind);
                try std.testing.expectEqual(@as(usize, 0), result.moves.len);
            }
        }
    }
}

test "distant overpaints on repeated lines stay positional" {
    const width = 1200;
    const height = 800;
    const before = try canvases.Canvas.init(width, height);
    defer before.deinit();
    const after = try canvases.Canvas.init(width, height);
    defer after.deinit();
    var y: usize = 10;
    while (y + 9 <= height) : (y += 40) {
        before.line(10, 175, y, y / 40, 30);
        before.line(610, 775, y, y / 40, 30);
    }
    const paint: Pixel = .{ 235, 20, 30, 255 };
    for ([_]usize{ 20, 50, 100 }) |size| {
        y = 120;
        while (y <= 700) : (y += 23) {
            @memcpy(after.pixels, before.pixels);
            after.fill(50, 50, 41, 41, paint);
            after.fill(width - 100, height - 100, 91, 91, paint);
            after.fill(width / 2, y, size, size, paint);
            const result = try expect.compareCanvases(before, after, 1);
            defer result.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 3), result.regions.len);
            try std.testing.expectEqual(@as(usize, 0), result.moves.len);
            for (result.regions) |region| {
                try std.testing.expectEqual(Kind.changed, region.kind);
                try std.testing.expectEqual(region.before, region.after);
            }
        }
    }
}

test "an exact periodic repeat chooses the stationary reading" {
    const before = try canvases.Canvas.init(200, 400);
    defer before.deinit();
    const after = try canvases.Canvas.init(200, 400);
    defer after.deinit();
    var y: usize = 6;
    while (y + 9 <= before.view.height) : (y += 14) before.line(8, 192, y, 3, 30);
    after.copyRows(0, before, 28, 400);
    y = 370;
    while (y + 9 <= after.view.height) : (y += 14) after.line(8, 192, y, 3, 30);
    after.fill(28, 176, 3, 6, canvases.inkShade(30, 4));

    const result = try expect.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.moves.len);
    try std.testing.expect(expect.hasRegion(result.regions, .after, 29, 178, .changed));
    for (result.regions) |region| {
        try std.testing.expectEqual(Kind.changed, region.kind);
        try std.testing.expectEqual(region.before, region.after);
    }
}

test "balanced insertion and deletion detect every visible loss in both directions" {
    for ([_]usize{ 400, 400, 520 }, [_]bool{ true, false, false }) |height, chrome| {
        const before = try canvases.Canvas.init(240, height);
        defer before.deinit();
        const after = try canvases.Canvas.init(240, height);
        defer after.deinit();
        const clipped = try canvases.Canvas.init(240, height);
        defer clipped.deinit();
        canvases.auditPage(before, chrome, null, null, 0);
        for ([_]usize{ 1, 3, 6 }) |insert_at| {
            for (1..4) |rows_count| {
                canvases.auditPage(clipped, chrome, insert_at, null, rows_count);
                for (insert_at + 1..20) |delete_at| {
                    const y = (if (chrome) @as(usize, 44) else 8) + 18 * delete_at;
                    if (y + 18 * rows_count > height - (if (chrome) @as(usize, 50) else 0)) continue;
                    canvases.auditPage(after, chrome, insert_at, delete_at, rows_count);
                    const observable = !sample.sameRun(after.pixels, clipped.pixels);
                    for ([_]bool{ false, true }) |reverse| {
                        const result = try expect.compareCanvases(if (reverse) after else before, if (reverse) before else after, 1);
                        defer result.deinit(std.testing.allocator);
                        if (!observable) continue; // The two possible edits produce the same captured pixels.
                        errdefer std.debug.print("height={d}, chrome={}, insert={d}, delete={d}, rows_count={d}, reverse={}\n", .{ height, chrome, insert_at, delete_at, rows_count, reverse });
                        const kind: Kind = if (reverse) .inserted else .removed;
                        const side: uidiff.Side = if (reverse) .after else .before;
                        var visible = false;
                        for (result.regions) |r| {
                            if (r.kind != kind) continue;
                            const box = r.boxOn(side).?;
                            if (box.y < @as(f64, @floatFromInt(y + 18 * rows_count)) and box.bottom() > @as(f64, @floatFromInt(y))) visible = true;
                        }
                        errdefer std.debug.print("regions {any}, moves {any}\n", .{ result.regions, result.moves });
                        try std.testing.expect(visible);
                    }
                }
            }
        }
    }
}

test "exchanging separated cards preserves the removed card height" {
    const before = try canvases.Canvas.init(240, 520);
    defer before.deinit();
    const after = try canvases.Canvas.init(240, 520);
    defer after.deinit();
    canvases.auditPage(before, false, null, null, 0);
    const old_y = 8 + 10 * 18;
    const new_y = 8 + 18;
    before.fill(8, old_y, 220, 30, .{ 220, 30, 30, 255 });
    after.copyRows(0, before, 0, new_y);
    after.fill(8, new_y, 220, 30, .{ 30, 70, 230, 255 });
    after.copyRows(new_y + 30, before, new_y, old_y);
    after.copyRows(old_y + 30, before, old_y + 30, 520);
    const result = try expect.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.regions.len);
    try std.testing.expect(expect.hasRegion(result.regions, .after, 60, new_y + 15, .inserted));
    try std.testing.expect(expect.hasRegion(result.regions, .before, 60, old_y + 15, .removed));
    for (result.regions) |r| if (r.kind == .removed) {
        try std.testing.expectEqual(@as(f64, 38), r.before.?.height);
    };
}

test "overpainting repetitive wide pages stays positional" {
    for ([_]usize{ 1000, 3000, 10000 }, [_]usize{ 800, 1200, 4000 }) |width, height| {
        const before = try canvases.Canvas.init(width, height);
        defer before.deinit();
        const after = try canvases.Canvas.init(width, height);
        defer after.deinit();
        var y: usize = 10;
        while (y + 10 < height) : (y += 40) {
            var x: usize = 10;
            while (x + 120 < width) : (x += 600) before.line(x, x + 120, y, y / 40, 30);
        }
        @memcpy(after.pixels, before.pixels);
        after.fill(width / 2, height / 2, 100, 100, .{ 255, 0, 0, 255 });
        const found = try expect.compareCanvases(before, after, 1);
        defer found.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), found.regions.len);
        try std.testing.expectEqual(@as(usize, 0), found.moves.len);
        try std.testing.expectEqual(found.regions[0].before.?, found.regions[0].after.?);
        try std.testing.expectEqual(@as(f64, 108), found.regions[0].after.?.width);
    }
}
