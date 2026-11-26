//! Scenario coverage for focus in a comparison sheet.
const std = @import("std");
const uidiff = @import("uidiff");
const sheet = uidiff.testing.sheet;
const Rows = sheet.Rows;
const white = sheet.white;
const overview_width = sheet.overview_width;
const focus_slot_width = sheet.focus_slot_width;
const Pixel = uidiff.Pixel;
const Image = uidiff.Image;
const Region = uidiff.Region;

test "wide reports use bounded overviews and merge overlapping focus crops" {
    const max_sheet_width = sheet.max_sheet_width;
    const overview_caption_gap = sheet.overview_caption_gap;
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(Pixel, 3600 * 300);
    defer allocator.free(pixels);
    @memset(pixels, white);
    const image: Image = .{ .width = 3600, .height = 300, .pixels = pixels };
    const regions = [_]Region{
        .{ .number = 1, .kind = .changed, .before = uidiff.Box.fromPixels(450, 30, 80, 20), .after = uidiff.Box.fromPixels(450, 30, 80, 20) },
        .{ .number = 2, .kind = .changed, .before = uidiff.Box.fromPixels(900, 185, 80, 20), .after = uidiff.Box.fromPixels(900, 185, 80, 20) },
        .{ .number = 3, .kind = .inserted, .after = uidiff.Box.fromPixels(1600, 40, 1950, 18) },
    };
    const rows = try Rows.init(allocator, image, image, &regions, &.{});
    defer rows.deinit(allocator);
    try std.testing.expect(rows.plan.size.width <= max_sheet_width);
    try std.testing.expectEqual(@as(usize, overview_width), rows.plan.panes[0].w);
    try std.testing.expectEqual(@as(usize, 0), rows.plan.panes[1].x - rows.plan.panes[0].x);
    try std.testing.expectEqual(@as(usize, overview_caption_gap), rows.plan.panes[1].y - rows.plan.panes[0].bottom());
    try std.testing.expectEqual(rows.plan.details[0].focus, rows.plan.details[1].focus);
    try std.testing.expect(rows.plan.details[2].focus != rows.plan.details[0].focus);
    const first = rows.plan.focuses[0];
    const before = first.crops[0].?;
    const after = first.crops[1].?;
    try std.testing.expectEqual(@as(usize, 300), before.from.h);
    try std.testing.expectEqual(before.from.w, before.to.w);
    try std.testing.expectEqual(before.from.h, before.to.h);
    try std.testing.expect(after.to.x > before.to.right());
    try std.testing.expectEqualStrings(sheet.before_caption ++ " | x 250-1180", first.captions[0].bytes());
    const shrunk = rows.plan.focuses[2].crops[1].?;
    try std.testing.expectEqual(@as(usize, focus_slot_width), shrunk.to.w);
    try std.testing.expect(shrunk.to.h < shrunk.from.h);
    for (rows.plan.details) |detail| {
        if (detail.after_badge.position()) |b| try std.testing.expect(!b.overlaps(detail.after_mark.?));
        if (detail.focus_badges[1].position()) |b| try std.testing.expect(!b.overlaps(detail.focus_marks[1].?));
    }
    const tall = sheet.focusWindow(.{ .x = 240, .y = 250, .w = 10, .h = 20 }, .{ .width = 1500, .height = 600 }).?;
    try std.testing.expectEqual(@as(usize, 130), tall.y);
    try std.testing.expectEqual(@as(usize, 260), tall.h);
}

test "wide removed strips get distinct focus badges and a scaled caption" {
    const page = sheet.page;
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(Pixel, 3800 * 120);
    defer allocator.free(pixels);
    @memset(pixels, page);
    const image: Image = .{ .width = 3800, .height = 120, .pixels = pixels };
    const regions = [_]Region{
        .{ .number = 1, .kind = .removed, .before = uidiff.Box.fromPixels(100, 4, 3100, 14) },
        .{ .number = 2, .kind = .removed, .before = uidiff.Box.fromPixels(100, 44, 3100, 14) },
    };
    const rows = try Rows.init(allocator, image, image, &regions, &.{});
    defer rows.deinit(allocator);
    const first = rows.plan.details[0].focus_badges[0].position().?;
    const second = rows.plan.details[1].focus_badges[0].position().?;
    try std.testing.expect(!first.overlaps(second));
    try std.testing.expect(!first.overlaps(rows.plan.details[1].focus_marks[0].?));
    try std.testing.expect(!second.overlaps(rows.plan.details[0].focus_marks[0].?));
    try std.testing.expect(std.mem.indexOf(u8, rows.plan.focuses[0].captions[0].bytes(), "scaled 35%") != null);
}

test "focus badges use space outside a crop when available" {
    const page = sheet.page;
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(Pixel, 1600 * 530);
    defer allocator.free(pixels);
    @memset(pixels, page);
    const image: Image = .{ .width = 1600, .height = 530, .pixels = pixels };
    const box = uidiff.Box.fromPixels(1588, 460, 8, 6);
    const rows = try Rows.init(allocator, image, image, &.{.{ .number = 1, .kind = .changed, .before = box, .after = box }}, &.{});
    defer rows.deinit(allocator);
    try std.testing.expect(!rows.plan.details[0].focus_badges[0].position().?.overlaps(rows.plan.focuses[0].crops[0].?.to));
}
