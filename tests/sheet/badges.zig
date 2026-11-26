//! Scenario coverage for badges in a comparison sheet.
const std = @import("std");
const uidiff = @import("uidiff");
const sheet = uidiff.testing.sheet;
const Rows = sheet.Rows;
const Rect = sheet.Rect;
const Layout = sheet.Layout;
const white = sheet.white;
const Pixel = uidiff.Pixel;
const Image = uidiff.Image;
const Region = uidiff.Region;

test "the halo and color stroke leave the changed pixels uncovered" {
    const allocator = std.testing.allocator;
    const source: Pixel = .{ 17, 31, 61, 255 };
    const pixels: [160 * 100]Pixel = @splat(source);
    const image: Image = .{ .width = 160, .height = 100, .pixels = &pixels };
    const changed: Region = .{ .number = 1, .kind = .changed, .before = uidiff.Box.fromPixels(80, 48, 30, 30) };
    const rows = try Rows.init(allocator, image, image, &.{changed}, &.{});
    defer rows.deinit(allocator);
    const storage = try allocator.alloc(Pixel, rows.plan.size.width);
    defer allocator.free(storage);
    const mark = rows.plan.details[0].before_mark.?;
    const x = mark.x;
    const line = rows.row(mark.y + mark.h / 2, storage);
    try std.testing.expectEqual(source, line[x]);
    try std.testing.expectEqual(source, line[x - 1]);
    try std.testing.expectEqual(sheet.tint(.changed), line[x - 3]);
    try std.testing.expectEqual(white, line[x - 4]);
    try std.testing.expectEqual(source, line[x - 6]);
}

test "top corner badges stay above the pane and clear of the caption" {
    const page = sheet.page;
    const allocator = std.testing.allocator;
    const pixels: [80 * 80]Pixel = @splat(page);
    const image: Image = .{ .width = 80, .height = 80, .pixels = &pixels };
    const insert: Region = .{ .number = 1, .kind = .inserted, .after = uidiff.Box.fromPixels(0, 0, 4, 4) };
    const rows = try Rows.init(allocator, image, image, &.{insert}, &.{});
    defer rows.deinit(allocator);
    const storage = try allocator.alloc(Pixel, rows.plan.size.width);
    defer allocator.free(storage);
    const right = rows.plan.panes[1].x;
    const above = rows.row(rows.plan.panes[1].y - 8, storage);
    try std.testing.expectEqual(page, above[right + 5]);
    const bounds = rows.plan.details[0].after_badge.position().?;
    const center = rows.row(bounds.y + bounds.h / 2, storage);
    try std.testing.expectEqual(white, center[bounds.x]);
    try std.testing.expectEqual(sheet.tint(.inserted), center[bounds.x + 5]);
    try std.testing.expect(bounds.bottom() <= rows.plan.panes[1].y);
    try std.testing.expect(!bounds.overlaps(rows.plan.details[0].after_mark.?));
}

test "thin wide strips and crops draw full badges above their pixels" {
    const page = sheet.page;
    const allocator = std.testing.allocator;
    const pixels: [900 * 12]Pixel = @splat(page);
    const image: Image = .{ .width = 900, .height = 12, .pixels = &pixels };
    const region: Region = .{ .number = 1, .kind = .changed, .after = uidiff.Box.fromPixels(400, 0, 12, 12) };
    const rows = try Rows.init(allocator, image, image, &.{region}, &.{});
    defer rows.deinit(allocator);
    const storage = try allocator.alloc(Pixel, rows.plan.size.width);
    defer allocator.free(storage);
    const detail = rows.plan.details[0];
    const overview = detail.after_badge.position().?;
    const focus = detail.focus_badges[1].position().?;
    const ui = Layout.init(image.size(), image.size());
    try std.testing.expectEqual(sheet.overviewDiameter(ui), overview.w);
    try std.testing.expectEqual(@as(usize, 59), focus.w);
    try std.testing.expectEqual(rows.plan.panes[1].y, overview.bottom());
    try std.testing.expectEqual(rows.plan.focuses[0].crops[1].?.to.y, focus.bottom());
    for ([_]Rect{ overview, focus }) |bounds| {
        const top = rows.row(bounds.y, storage);
        try std.testing.expectEqual(white, top[bounds.x + bounds.w / 2]);
        const bottom = rows.row(bounds.bottom() - 1, storage);
        try std.testing.expectEqual(white, bottom[bounds.x + bounds.w / 2]);
    }
}

test "small panes enlarge by an integer and keep badges clear of their boxes" {
    const min_preview_side = sheet.min_preview_side;
    const offsetMark = sheet.offsetMark;
    const Size = uidiff.Size;
    const source: Size = .{ .width = 124, .height = 114 };
    const ui = Layout.init(source, source);
    const panes = ui.panes(source, source);
    try std.testing.expect(panes[0].w >= min_preview_side and panes[0].h >= min_preview_side);
    try std.testing.expectEqual(@as(usize, 0), panes[0].h % source.height);
    const gap = panes[1].x - panes[0].right();
    try std.testing.expect(gap >= 48 and gap <= panes[0].w / 4);
    for ([_][2]usize{ .{ 60, 50 }, .{ 60, 0 }, .{ 0, 0 } }) |at| {
        const mark = offsetMark(.{ .x = at[0], .y = at[1], .w = 2, .h = 2 }, panes[1], source).?;
        const b = sheet.badgeBounds(mark, panes[1], ui).?;
        try std.testing.expect(!b.overlaps(mark));
        try std.testing.expect(b.x >= panes[1].x and b.y >= panes[1].y);
        try std.testing.expect(b.right() <= panes[1].right() and b.bottom() <= panes[1].bottom());
        if (at[1] != 0) try std.testing.expect(b.bottom() <= mark.y) else if (at[0] != 0) try std.testing.expect(b.right() <= mark.x);
    }
    try std.testing.expect(sheet.badgeBounds(panes[1], panes[1], ui) == null);
}

test "edge badges stay near their numbered boxes and avoid all other marks" {
    const page = sheet.page;
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(Pixel, 400 * 300);
    defer allocator.free(pixels);
    @memset(pixels, page);
    const image: Image = .{ .width = 400, .height = 300, .pixels = pixels };
    const boxes = [_]uidiff.Box{
        .fromPixels(0, 0, 4, 4),   .fromPixels(396, 0, 4, 4),   .fromPixels(198, 0, 5, 3),
        .fromPixels(0, 296, 4, 4), .fromPixels(396, 296, 4, 4),
    };
    var regions: [boxes.len]Region = undefined;
    for (&regions, boxes, 1..) |*r, box, i| r.* = .{ .number = i, .kind = .changed, .before = box, .after = box };
    const rows = try Rows.init(allocator, image, image, &regions, &.{});
    defer rows.deinit(allocator);
    for (rows.plan.details, 0..) |detail, i| {
        const marker = detail.after_badge.position().?;
        try std.testing.expect(marker.distanceSquared(detail.after_mark.?) <= 144);
        for (rows.plan.details, 0..) |other, j| {
            try std.testing.expect(!marker.overlaps(other.after_mark.?));
            if (i != j) try std.testing.expect(!marker.overlaps(other.after_badge.position().?));
        }
    }
}

test "whole-image wide changes have a badge in both overviews" {
    const page = sheet.page;
    const allocator = std.testing.allocator;
    const pixels: [900 * 12]Pixel = @splat(page);
    const image: Image = .{ .width = 900, .height = 12, .pixels = &pixels };
    const box = uidiff.Box.fromPixels(0, 0, 900, 12);
    const rows = try Rows.init(allocator, image, image, &.{.{ .number = 1, .kind = .changed, .before = box, .after = box }}, &.{});
    defer rows.deinit(allocator);
    try std.testing.expect(rows.plan.details[0].before_badge.position().?.bottom() <= rows.plan.panes[0].y);
    try std.testing.expect(rows.plan.details[0].after_badge.position().?.bottom() <= rows.plan.panes[1].y);
}

test "edge badges use the gutter margins and the space above the caption" {
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(Pixel, 400 * 300);
    defer allocator.free(pixels);
    @memset(pixels, .{ 45, 67, 85, 255 });
    const image: Image = .{ .width = 400, .height = 300, .pixels = pixels };
    const regions = [_]Region{
        .{ .number = 1, .kind = .removed, .before = .fromPixels(0, 145, 5, 10) },
        .{ .number = 2, .kind = .changed, .before = .fromPixels(395, 130, 5, 10), .after = .fromPixels(395, 130, 5, 10) },
        .{ .number = 3, .kind = .inserted, .after = .fromPixels(220, 0, 10, 8) },
        .{ .number = 4, .kind = .changed, .before = .fromPixels(195, 145, 10, 10) },
    };
    const rows = try Rows.init(allocator, image, image, &regions, &.{});
    defer rows.deinit(allocator);
    const left = rows.plan.details[0].before_badge.position().?;
    const gap = rows.plan.details[1].before_badge.position().?;
    const right = rows.plan.details[1].after_badge.position().?;
    const top = rows.plan.details[2].after_badge.position().?;
    try std.testing.expect(left.right() <= rows.plan.panes[0].x);
    try std.testing.expect(gap.x >= rows.plan.panes[0].right() and gap.right() <= rows.plan.panes[1].x);
    try std.testing.expect(right.x >= rows.plan.panes[1].right());
    try std.testing.expect(top.bottom() <= rows.plan.panes[1].y);
    const center = rows.plan.details[3].before_badge.position().?;
    for ([_]Rect{ left, gap, right, top }) |badge_rect| {
        for (rows.plan.panes) |pane| try std.testing.expect(!badge_rect.overlaps(pane));
    }
    const center_mark = rows.plan.details[3].before_mark.?;
    try std.testing.expect(center.overlaps(rows.plan.panes[0]));
    try std.testing.expect(!center.overlaps(center_mark));
    try std.testing.expect(center.distanceSquared(center_mark) <= 36);
}
