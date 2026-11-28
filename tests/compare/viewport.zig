//! End-to-end alignment at viewport edges and stationary chrome.

const std = @import("std");
const uidiff = @import("uidiff");
const uidiff_testing = @import("uidiff_testing");
const expect = uidiff_testing.expect;
const canvas = uidiff_testing.canvas;

const compare = uidiff.compare;
const Box = uidiff.Box;
const Pixel = uidiff.Pixel;
const Kind = uidiff.Kind;
const region_padding = uidiff.region_padding;

fn checkTallInsertion(height: usize, inserted: usize, viewport: enum { fixed, growing }) !void {
    const at = 64;
    const old_height = if (viewport == .fixed) height else height - inserted;
    const old = try std.testing.allocator.alloc(uidiff.Pixel, old_height);
    defer std.testing.allocator.free(old);
    const new = try std.testing.allocator.alloc(uidiff.Pixel, height);
    defer std.testing.allocator.free(new);
    for (old, 0..) |*pixel, row| {
        pixel.* = .{ @intCast(row % 256), @intCast(row / 256), 0, 255 };
    }
    @memcpy(new[0..at], old[0..at]);
    @memset(new[at..][0..inserted], .{ 0, 0, 255, 255 });
    @memcpy(new[at + inserted ..], old[at .. height - inserted]);
    const result = try compare(
        std.testing.allocator,
        .{
            .before = .{ .width = 1, .height = old.len, .pixels = old },
            .after = .{ .width = 1, .height = height, .pixels = new },
        },
        .{},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expectEqual(uidiff.Kind.inserted, result.regions[0].kind());
    try std.testing.expectEqual(Box.fromPixels(0, at - region_padding, 1, inserted + 2 * region_padding), result.regions[0].after.?);
}

test "short scrolling clips blank space behind the fixed header" {
    const before = try canvas.Canvas.init(180, 250);
    defer before.deinit();
    const after = try canvas.Canvas.init(180, 250);
    defer after.deinit();
    for (0..5) |i| before.line(10, 165, 44 + i * 30, i, 40);
    after.copyRows(40, before, 43, 223);
    for ([_]canvas.Canvas{ before, after }) |image| {
        image.fill(0, 0, 180, 40, .{ 220, 228, 240, 255 });
        image.fill(0, 220, 180, 30, .{ 235, 225, 220, 255 });
        image.line(12, 150, 226, 20, 40);
    }
    const result = try expect.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.regions.len);
    try std.testing.expect(result.moves.len != 0);
}

test "an interior divider does not hide a shortened spacer" {
    const before = try canvas.Canvas.init(400, 480);
    defer before.deinit();
    for (0..3) |i| before.line(12, 208, 18 + i * 18, i, 40);
    before.fill(0, 80, 400, 2, canvas.inkShade(220, 4));
    for (0..8) |i| before.line(12, 208, 122 + i * 18, 12 + i, 40);
    for ([_]usize{ 20, 30 }) |removed| {
        const after = try canvas.Canvas.init(400, 480);
        defer after.deinit();
        after.copyRows(0, before, 0, 82);
        after.copyRows(122 - removed, before, 122, before.view.height);
        const result = try expect.compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.regions.len);
        try std.testing.expectEqual(Kind.removed, result.regions[0].kind());
        try std.testing.expect(result.moves.len != 0);
    }
}

test "the closing rule of an inset list hides cards pushed past its edge" {
    const before = try canvas.Canvas.init(600, 400);
    defer before.deinit();
    const after = try canvas.Canvas.init(600, 400);
    defer after.deinit();
    const border: Pixel = .{ 20, 20, 20, 255 };
    before.fill(179, 49, 242, 1, border);
    before.fill(179, 350, 242, 1, border);
    before.fill(179, 49, 1, 302, border);
    before.fill(420, 49, 1, 302, border);
    for (0..8) |i_row| {
        before.line(12, 145, 12 + 40 * i_row, i_row, 30);
        before.line(450, 575, 12 + 40 * i_row, i_row + 1, 30);
    }
    @memcpy(after.pixels, before.pixels);
    for (0..10) |i_row| {
        const y = 64 + i_row * 30;
        if (i_row < 9) canvas.paintCard(before, 190, y, 220, 23, i_row);
        canvas.paintCard(after, 190, y, 220, 23, if (i_row == 2) 90 else i_row - @intFromBool(i_row > 2));
    }
    after.copyRows(350, before, 350, 400);
    const result = try expect.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expect(expect.hasRegion(result.regions, .after, 385, 137, .inserted));
    try std.testing.expectEqual(@as(usize, 1), result.moves.len);
    try std.testing.expectEqual(@as(usize, 30), result.moves[0].after.y - result.moves[0].before.y);
}

test "a 20,000-row image keeps a 5,000-row insertion near the top" {
    try checkTallInsertion(20_000, 5_000, .growing);
}

test "a fixed-height page aligns a large insertion and corresponding clipping" {
    const inserted = 2_050;
    try checkTallInsertion(3 * inserted, inserted, .fixed);
}

test "taller after images mark added rows and reversal marks removed rows" {
    const before = try canvas.Canvas.init(20, 20);
    defer before.deinit();
    const after = try canvas.Canvas.init(20, 30);
    defer after.deinit();
    try expect.checkInsertion(before, after, Box.fromPixels(0, 20 - region_padding, 20, 10 + region_padding));
}

test "viewport insertion ignores clipped content and its reversal reports revealed rows" {
    const before = try canvas.Canvas.init(80, 120);
    defer before.deinit();
    before.red(4, 0, 60, 10, 0);
    before.red(8, 23, 20, 6, 0);
    before.red(27, 38, 16, 8, 0);
    before.red(22, 78, 31, 8, 0);
    before.red(12, 110, 14, 10, 0);
    for ([_]usize{ 0, 2 }) |scroll| {
        const after = try canvas.Canvas.init(80, 120);
        defer after.deinit();
        after.copyRows(0, before, 0, 10);
        after.copyRows(10 + scroll, before, 10, 60);
        after.copyRows(68 + scroll, before, 60, 112 - scroll);
        after.red(58, 10, 10, scroll, 0);
        after.red(34, 60 + scroll, 20, 8, 0);
        const inserted = expect.paddedBox(34, 60 + scroll, 20, 8);
        try expect.check(before, after, 1, &.{.{ .after = inserted }});
        try expect.check(after, before, 1, &.{
            .{ .before = inserted },
            .{ .after = Box.fromPixels(8, 108 - scroll, 22, 12 + scroll) },
        });
    }
}

test "insertion above a fixed footer preserves a narrow edit inside the footer" {
    const before = try canvas.Canvas.init(780, 1688);
    defer before.deinit();
    const after = try canvas.Canvas.init(780, 1688);
    defer after.deinit();
    before.fill(32, 49, 670, 35, canvas.inkShade(80, 4));
    before.fill(100, 190, 130, 11, canvas.inkShade(100, 4));
    before.fill(100, 401, 166, 19, canvas.inkShade(100, 4));
    before.fill(308, 503, 155, 14, canvas.inkShade(100, 4));
    before.fill(100, 600, 486, 122, canvas.inkShade(220, 4));
    before.fill(40, 1487, 600, 116, canvas.inkShade(230, 4));
    before.fill(660, 1496, 88, 88, canvas.inkShade(205, 4));
    before.fill(620, 1614, 100, 26, canvas.inkShade(100, 4));
    after.copyRows(0, before, 0, 450);
    after.copyRows(520, before, 450, 1417);
    after.copyRows(1487, before, 1487, 1688);
    after.fill(257, 476, 266, 18, canvas.inkShade(90, 4));
    after.fill(660, 1496, 88, 88, canvas.inkShade(24, 4));
    const result = try expect.compareCanvases(before, after, 2);
    defer result.deinit(std.testing.allocator);
    const button = Box.fromPixels(652, 1488, 104, 104);
    try expect.checkRegions(result.regions, &.{
        .{ .after = Box.fromPixels(249, 468, 282, 34) },
        .{ .before = button, .after = button },
    });
    try std.testing.expectEqual(@as(usize, 1), result.moves.len);
    const move = result.moves[0];
    try std.testing.expectEqual(@as(usize, 70), move.after.y - move.before.y);
    try std.testing.expectEqual(@as(usize, 1487), move.after.y + move.after.height);
    try expect.check(after, before, 2, &.{
        .{ .before = Box.fromPixels(249, 468, 282, 34) },
        .{ .before = button, .after = button },
    });
}

test "a fixed footer hides clipped cards with either palette" {
    for ([_][4]u8{ .{ 18, 32, 26, 57 }, .{ 246, 255, 255, 222 } }) |palette| {
        const before = try canvas.Canvas.init(240, 320);
        defer before.deinit();
        const after = try canvas.Canvas.init(240, 320);
        defer after.deinit();
        @memset(before.pixels, canvas.inkShade(palette[0], 4));
        before.fill(0, 0, 240, 32, canvas.inkShade(palette[2], 4));
        before.fill(0, 31, 240, 2, canvas.inkShade(palette[3], 4));
        for (0..5) |i_card| {
            const y = 40 + 47 * i_card;
            before.fill(44, y, 140 - 8 * i_card, 37, canvas.inkShade(palette[1], 4));
            before.line(52, 169, y + 7, i_card, 110);
        }
        before.fill(0, 270, 240, 50, canvas.inkShade(palette[2], 4));
        before.fill(0, 270, 240, 2, canvas.inkShade(palette[3], 4));
        before.line(16, 210, 292, 77, 140);
        after.copyRows(0, before, 0, 134);
        after.copyRows(181, before, 134, 223);
        after.copyRows(270, before, 270, 320);
        after.fill(0, 134, 240, 47, canvas.inkShade(palette[0], 4));
        after.fill(44, 134, 140, 37, canvas.inkShade(palette[1], 4));
        after.line(52, 169, 141, 22, 110);

        const result = try expect.compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.regions.len);
        try std.testing.expectEqual(Kind.inserted, result.regions[0].kind());
        try std.testing.expect(expect.hasRegion(result.regions, .after, 82, 135, .inserted));
        try std.testing.expect(expect.hasRegion(result.regions, .after, 82, 169, .inserted));
    }
}

test "stationary backdrop above a footer does not extend a mixed edit" {
    const before = try canvas.Canvas.init(240, 400);
    defer before.deinit();
    const after = try canvas.Canvas.init(240, 400);
    defer after.deinit();
    before.line(12, 209, 40, 27, 50);
    before.fill(34, 116, 158, 72, .{ 208, 210, 223, 255 });
    before.line(18, 187, 223, 65, 90);
    before.line(23, 210, 258, 70, 60);
    before.line(18, 197, 281, 73, 45);
    before.line(28, 216, 295, 55, 40);
    before.fill(0, 340, 240, 60, canvas.inkShade(203, 4));
    before.line(12, 224, 370, 90, 60);
    after.copyRows(0, before, 0, 96);
    after.copyRows(136, before, 96, 280);
    after.copyRows(320, before, 320, 400);
    after.fill(76, 100, 112, 24, .{ 205, 119, 36, 255 });
    after.fill(34, 156, 158, 72, .{ 83, 113, 161, 255 });

    const result = try expect.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(expect.hasRegion(result.regions, .after, 140, 110, .inserted));
    try std.testing.expect(!expect.hasRegion(result.regions, .after, 100, 325, null));
    for (result.regions) |region| if (region.after) |box| {
        try std.testing.expect(box.bottom() <= 320 + region_padding);
    };
}

test "blank rows change layout with and without image growth" {
    const before = try canvas.Canvas.init(80, 120);
    defer before.deinit();
    before.red(8, 10, 24, 7, 0);
    before.red(20, 48, 28, 6, 0);
    before.red(12, 84, 18, 7, 0);
    for ([_]usize{ 0, 12 }) |growth| {
        const after = try before.insert(48, 12, growth);
        defer after.deinit();
        try expect.checkInsertion(before, after, Box.fromPixels(0, 48 - region_padding, 80, 12 + 2 * region_padding));
    }
}

test "small CSS dividers above and below stationary headers count as scroll" {
    const before = try canvas.Canvas.init(80, 120);
    defer before.deinit();
    before.red(4, 0, 60, 10, 0);
    before.red(12, 35, 27, 6, 0);
    before.red(20, 72, 36, 9, 0);
    for ([_][3]usize{ .{ 0, 1, 1 }, .{ 10, 2, 2 } }) |p| {
        const rows = p[1] * p[2];
        const after = try before.insert(p[0], rows, 0);
        defer after.deinit();
        after.red(0, p[0], 80, rows, 140);
        try expect.check(before, after, @floatFromInt(p[2]), &.{});
        try expect.check(after, before, @floatFromInt(p[2]), &.{});
    }
}

test "large viewport insertion still aligns" {
    const before = try canvas.Canvas.init(60, 1400);
    defer before.deinit();
    canvas.paintBands(before, 0, 60);
    const after = try before.insert(100, 560, 0);
    defer after.deinit();
    after.red(5, 100, 40, 560, 90);
    const result = try expect.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expectEqual(Kind.inserted, result.regions[0].kind());
    const found = result.regions[0].after.?;
    try std.testing.expect(found.y <= 100 and found.y + found.height >= 660 and found.height < 560 + 4 * region_padding);
}

test "deleting viewport rows boxes the removed and revealed content" {
    const before = try canvas.Canvas.init(80, 120);
    defer before.deinit();
    const after = try canvas.Canvas.init(80, 120);
    defer after.deinit();
    before.red(5, 10, 31, 6, 0);
    before.red(14, 44, 25, 8, 0);
    before.red(30, 71, 18, 5, 0);
    after.copyRows(0, before, 0, 44);
    after.copyRows(44, before, 52, 120);
    after.red(8, 112, 17, 8, 0);
    try expect.check(before, after, 1, &.{
        .{ .before = expect.paddedBox(14, 44, 25, 8) },
        .{ .after = Box.fromPixels(4, 108, 25, 12) },
    });
}

test "a banner added or removed at the top of a fixed viewport is boxed" {
    const before = try canvas.Canvas.init(80, 120);
    defer before.deinit();
    before.red(4, 0, 60, 10, 0);
    before.red(12, 35, 27, 6, 0);
    before.red(20, 72, 36, 9, 0);
    before.red(8, 104, 30, 8, 0);
    const banner = 40;
    const after = try canvas.Canvas.init(80, 120);
    defer after.deinit();
    after.copyRows(banner, before, 0, 120 - banner);
    after.fill(0, 0, 80, banner, .{ 130, 130, 130, 255 });
    after.red(10, 12, 30, 6, 0);
    const banner_box = expect.paddedBox(10, 12, 30, 6);
    try expect.check(before, after, 1, &.{.{ .after = banner_box }});
    try expect.check(after, before, 1, &.{
        .{ .before = banner_box },
        .{ .after = expect.paddedBox(20, 80, 36, 1) },
        .{ .after = expect.paddedBox(8, 104, 30, 8) },
    });
}

test "fixed footers with internal edits clip shifted content" {
    const before = try canvas.Canvas.init(240, 400);
    defer before.deinit();
    before.text(8, 232, 50, 0, 30);
    before.fill(0, 0, 240, 40, .{ 40, 40, 70, 255 });
    before.line(10, 200, 15, 77, 240);
    before.fill(0, 350, 240, 50, .{ 60, 60, 60, 255 });
    before.fill(170, 360, 50, 30, .{ 0, 120, 220, 255 });

    for ([_]usize{ 41, 150, 300 }) |y| {
        const after = try canvas.Canvas.init(240, 400);
        defer after.deinit();
        after.copyRows(0, before, 0, y);
        after.copyRows(y + 30, before, y, 320);
        after.copyRows(350, before, 350, 400);
        after.fill(10, y + 4, 220, 22, .{ 200, 220, 240, 255 });
        for ([_]?usize{ null, 352, 365, 385 }) |edit| {
            if (edit) |row| after.fill(30, row, 10, 10, .{ 255, 200, 0, 255 });
            const result = try expect.compareCanvases(before, after, 1);
            defer result.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, if (edit == null) 1 else 2), result.regions.len);
            try std.testing.expect(expect.hasRegion(result.regions, .after, 50, y + 10, .inserted));
            try std.testing.expectEqual(@as(usize, 1), result.moves.len);
            const move = result.moves[0];
            try std.testing.expectEqual(@as(usize, 30), move.after.y - move.before.y);
            try std.testing.expectEqual(@as(usize, 350), move.after.y + move.after.height);
            if (edit) |row| {
                const expected = Box.fromPixels(26, row - 4, 18, 18);
                try std.testing.expectEqual(expected, result.regions[1].before.?);
                try std.testing.expectEqual(expected, result.regions[1].after.?);
                after.fill(30, row, 10, 10, .{ 60, 60, 60, 255 });
            }
        }
        after.fill(5, 10, 10, 10, .{ 255, 200, 0, 255 });
        const header_edit = try expect.compareCanvases(before, after, 1);
        defer header_edit.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), header_edit.regions.len);
        try std.testing.expectEqual(@as(usize, 1), header_edit.moves.len);
        try std.testing.expect(expect.hasRegion(header_edit.regions, .after, 8, 12, .changed));
        after.fill(5, 10, 10, 10, .{ 40, 40, 70, 255 });
        const reverse = try expect.compareCanvases(after, before, 1);
        defer reverse.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), reverse.regions.len);
        try std.testing.expect(expect.hasRegion(reverse.regions, .before, 50, y + 10, .removed));
        try std.testing.expectEqual(@as(usize, 1), reverse.moves.len);
        try std.testing.expectEqual(@as(usize, 30), reverse.moves[0].before.y - reverse.moves[0].after.y);
    }
}

test "an inset item after a deletion is not a footer" {
    const before = try canvas.Canvas.init(240, 400);
    defer before.deinit();
    const after = try canvas.Canvas.init(240, 400);
    defer after.deinit();
    const clipped = try canvas.Canvas.init(240, 400);
    defer clipped.deinit();
    var y: usize = 0;
    for (0..22) |item| {
        if (y + 26 > before.view.height) break;
        if (item % 7 == 3) {
            before.fill(8, y, 225, 23, .{ 60, 145, 180, 255 });
            y += 26;
        } else {
            before.line(8, 110 + item % 5 * 9, y + 2, item * 3 + 1, 30);
            y += 18;
        }
    }
    const insertion = 116;
    const deletion = 304;
    const shift = 18;
    after.copyRows(0, before, 0, before.view.height);
    after.copyRows(insertion + shift, before, insertion, deletion);
    after.fill(8, insertion, 225, 15, .{ 40, 200, 40, 255 });
    clipped.copyRows(0, after, 0, insertion + shift);
    clipped.copyRows(insertion + shift, before, insertion, before.view.height - shift);
    try std.testing.expect(!std.mem.eql(u8, std.mem.sliceAsBytes(after.pixels), std.mem.sliceAsBytes(clipped.pixels)));
    for ([_]bool{ false, true }) |reverse| {
        const result = try expect.compareCanvases(if (reverse) after else before, if (reverse) before else after, 1);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(expect.hasRegion(result.regions, if (reverse) .after else .before, 32, deletion + 6, if (reverse) .inserted else .removed));
    }
}

test "fixed chrome stays stationary across heights and button edits" {
    for ([_]usize{ 20, 50, 80 }) |footer_height| {
        const footer = 400 - footer_height;
        const before = try canvas.Canvas.init(240, 400);
        defer before.deinit();
        const after = try canvas.Canvas.init(240, 400);
        defer after.deinit();
        before.text(8, 58, 44, 0, 30);
        before.fill(0, 0, 240, 41, .{ 220, 220, 235, 255 });
        before.fill(0, footer, 240, footer_height, .{ 235, 225, 220, 255 });
        const button_h = @min(21, footer_height - 10);
        before.fill(20, footer + 10, 61, button_h, .{ 50, 50, 200, 255 });
        for ([_]usize{ 2, 16 }) |at| {
            if (at == 16 and footer_height != 50) continue;
            const y = 44 + at * 18;
            after.copyRows(0, before, 0, y);
            after.fill(0, y, 240, @min(30, footer - y), canvas.inkShade(255, 4));
            if (y + 30 < footer) after.copyRows(y + 30, before, y, footer - 30);
            after.copyRows(footer, before, footer, 400);
            after.fill(8, y, 225, @min(27, footer - y), .{ 60, 140, 90, 255 });
            const inserted = try expect.compareCanvases(before, after, 1);
            defer inserted.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 1), inserted.regions.len);
            try std.testing.expect(expect.hasRegion(inserted.regions, .after, 100, y + 3, if (at == 2) .inserted else null));
            if (at == 2 and footer_height == 50) {
                after.fill(20, footer + 10, 61, button_h, .{ 235, 225, 220, 255 });
                after.fill(120, footer + 10, 61, button_h, .{ 50, 50, 200, 255 });
                const moved = try expect.compareCanvases(before, after, 1);
                defer moved.deinit(std.testing.allocator);
                try std.testing.expect(expect.hasRegion(moved.regions, .after, 130, footer + 15, .changed));
                try std.testing.expect(expect.hasRegion(moved.regions, .before, 25, footer + 15, .changed));
            }
        }
    }
}

test "a clipped list shifts by one row without reporting the obscured tail" {
    const before = try canvas.Canvas.init(368, 390);
    defer before.deinit();
    const after = try canvas.Canvas.init(368, 390);
    defer after.deinit();
    // Lower rounded corners shorten the visible closing rule.
    for ([_]canvas.Canvas{ before, after }) |image| {
        image.fill(16, 40, 336, 224, canvas.inkShade(120, 4));
        image.fill(18, 42, 332, 218, canvas.inkShade(240, 4));
        image.fill(16, 260, 14, 4, canvas.inkShade(255, 4));
        image.fill(338, 260, 14, 4, canvas.inkShade(255, 4));
        for (1..15) |rise| {
            const x = 30 - rise;
            image.fill(x, 260 - rise, 1, 1, canvas.inkShade(120, 4));
            image.fill(367 - x, 260 - rise, 1, 1, canvas.inkShade(120, 4));
        }
    }
    for (0..4) |row| {
        before.fill(36, 70 + 48 * row, 30 + 16 * row, if (row == 3) 46 else 16, canvas.inkShade(40, 4));
        before.fill(256, 70 + 48 * row, 30 + 10 * row, if (row == 3) 46 else 16, canvas.inkShade(64, 4));
    }
    after.copyRows(70, before, 70, 86);
    for (166..260) |y| @memcpy(after.pixels[y * 368 + 34 ..][0..302], before.view.row(y - 48)[34..][0..302]);
    after.fill(36, 118, 90, 18, canvas.inkShade(80, 4));
    after.fill(256, 118, 64, 18, canvas.inkShade(38, 4));
    const result = try expect.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expectEqual(Kind.inserted, result.regions[0].kind());
    try std.testing.expectEqual(@as(usize, 1), result.moves.len);
    try std.testing.expectEqual(@as(usize, 48), result.moves[0].shift());
}
