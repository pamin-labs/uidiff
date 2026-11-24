//! Paired focus crops and their layout.
const std = @import("std");
const copy = @import("copy.zig");
const values = @import("../value.zig");
const geometry = @import("geometry.zig");
const text = @import("text.zig");
const crops = @import("crops.zig");
const Rect = geometry.Rect;
const SourceRect = geometry.SourceRect;
const margin = geometry.margin;
const overview_width = geometry.overview_width;
const rectAtSize = geometry.rectAtSize;
const mapMark = geometry.mapMark;
const Text = text.Text;
const Crop = crops.Crop;
const Region = values.Region;
const Size = values.Size;

/// A grouped pair of source windows and their planned sheet crops.
pub const Focus = struct {
    windows: [2]?SourceRect,
    crops: [2]?Crop = .{ null, null },
    captions: [2]Text = .{ .{}, .{} },
    top: usize = 0,
    height: usize = 0,
};

/// Layout of one numbered region in the overview and detail rows.
pub const Detail = struct {
    region: Region,
    before: ?Crop,
    after: ?Crop,
    before_mark: ?Rect,
    after_mark: ?Rect,
    before_badge: ?Rect,
    after_badge: ?Rect,
    focus: usize = 0,
    focus_marks: [2]?Rect = .{ null, null },
    focus_badges: [2]?Rect = .{ null, null },
    number: Text,
    top: usize,
    height: usize,
};

const focus_gap = 40;
const horizontal_context = 200;
const vertical_context = 120;
const full_height_limit = 480;

/// Space reserved above a focus crop for its caption.
pub const focus_caption_height = 36;

/// Width reserved for one pane of a panoramic focus row.
pub const focus_slot_width = (overview_width - focus_gap) / 2;

/// Vertical space between consecutive detail rows.
pub const detail_gap = 30;

/// Finds a source window with context around a reported region.
pub fn focusWindow(box: ?SourceRect, size: Size) ?SourceRect {
    const source = box orelse return null;
    const x = source.x -| horizontal_context;
    const y = if (size.height <= full_height_limit) 0 else source.y -| vertical_context;
    if (x >= size.width or y >= size.height) return null;
    const bottom = if (size.height <= full_height_limit) size.height else @min(size.height, source.bottom() + vertical_context);
    return .{ .x = x, .y = y, .w = @min(size.width, source.right() + horizontal_context) - x, .h = bottom - y };
}

/// Returns the left sheet coordinate for a focus column.
pub fn focusColumn(side: usize) usize {
    return margin + side * (focus_slot_width + focus_gap);
}

/// Groups overlapping source windows and lays out the focus rows.
pub fn layoutFocus(details: []Detail, focuses: []Focus, sizes: [2]Size, start: usize) error{SheetTooLarge}!usize {
    // Find connected crop windows on either side. Keep the first region's
    // position in the report when merging a group.
    for (focuses, 0..) |focus, i| {
        for (focuses[0..i], 0..) |prior, j| {
            if (!windowsOverlap(focus.windows, prior.windows)) continue;
            const a = focusRoot(details, i);
            const b = focusRoot(details, j);
            details[@max(a, b)].focus = @min(a, b);
        }
    }
    for (details, 0..) |*detail, i| {
        const root = focusRoot(details, i);
        detail.focus = root;
        if (root == i) continue;
        for (&focuses[root].windows, focuses[i].windows) |*to, from| to.* = unionWindow(to.*, from);
    }
    var top = start;
    for (focuses, details, 0..) |*focus, detail, index| {
        if (detail.focus != index) continue;
        focus.top = top;
        var height: usize = 32;
        for (focus.windows, &focus.crops, &focus.captions, [2][]const u8{ copy.before, copy.after }, 0..) |window, *patch, *caption, name, side| {
            const from = window orelse {
                caption.* = try Text.format(copy.name_format, .{name});
                continue;
            };
            // Draw native pixels up to the half-sheet width. Shrinking uses
            // the same box filter as the ordinary close-up renderer.
            const w: usize = @min(focus_slot_width, from.w);
            const h = @max(1, from.h * w / from.w);
            patch.* = .{ .from = from, .to = .{ .x = focusColumn(side), .y = top + focus_caption_height, .w = w, .h = h } };
            caption.* = if (w == from.w)
                try Text.format(copy.focus_format, .{ name, from.x, from.right() })
            else
                try Text.format(copy.scaled_focus_format, .{ name, from.x, from.right(), @max(1, (100 * w + from.w / 2) / from.w) });
            height = @max(height, h);
        }
        focus.height = focus_caption_height + height;
        top += focus.height + detail_gap;
        if (top > values.max_extent) return error.SheetTooLarge;
    }
    for (details) |*detail| {
        const patches = focuses[detail.focus].crops;
        for (patches, sizes, &detail.focus_marks, [2]values.Side{ .before, .after }) |maybe_patch, size, *mark, side| {
            const patch = maybe_patch orelse continue;
            const source = rectAtSize(size, detail.region.boxOn(side)) orelse continue;
            mark.* = mapMark(source, patch.from, patch.to);
        }
    }
    return top;
}

fn focusRoot(details: []const Detail, index: usize) usize {
    var root = index;
    while (details[root].focus != root) root = details[root].focus;
    return root;
}

fn windowsOverlap(a: [2]?SourceRect, b: [2]?SourceRect) bool {
    for (a, b) |first, second| {
        if (first != null and second != null and first.?.overlaps(second.?)) return true;
    }
    return false;
}

fn unionWindow(a: ?SourceRect, b: ?SourceRect) ?SourceRect {
    const first = a orelse return b;
    const second = b orelse return a;
    const x = @min(first.x, second.x);
    const y = @min(first.y, second.y);
    return .{ .x = x, .y = y, .w = @max(first.right(), second.right()) - x, .h = @max(first.bottom(), second.bottom()) - y };
}

test "wide reports use bounded overviews and merge overlapping focus crops" {
    const max_sheet_width = geometry.max_sheet_width;
    const overview_caption_gap = geometry.overview_caption_gap;
    const white = @import("palette.zig").white;
    const Image = values.Image;
    const Pixel = values.Pixel;
    const Rows = @import("report_sheet.zig").Rows;
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(Pixel, 3600 * 300);
    defer allocator.free(pixels);
    @memset(pixels, white);
    const image: Image = .{ .width = 3600, .height = 300, .pixels = pixels };
    const regions = [_]Region{
        .{ .number = 1, .kind = .changed, .before = values.Box.fromPixels(450, 30, 80, 20), .after = values.Box.fromPixels(450, 30, 80, 20) },
        .{ .number = 2, .kind = .changed, .before = values.Box.fromPixels(900, 185, 80, 20), .after = values.Box.fromPixels(900, 185, 80, 20) },
        .{ .number = 3, .kind = .inserted, .after = values.Box.fromPixels(1600, 40, 1950, 18) },
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
    try std.testing.expectEqualStrings(copy.before ++ " | x 250-1180", first.captions[0].bytes());
    const shrunk = rows.plan.focuses[2].crops[1].?;
    try std.testing.expectEqual(@as(usize, focus_slot_width), shrunk.to.w);
    try std.testing.expect(shrunk.to.h < shrunk.from.h);
    for (rows.plan.details) |detail| {
        if (detail.after_badge) |b| try std.testing.expect(!b.overlaps(detail.after_mark.?));
        if (detail.focus_badges[1]) |b| try std.testing.expect(!b.overlaps(detail.focus_marks[1].?));
    }
    const tall = focusWindow(.{ .x = 240, .y = 250, .w = 10, .h = 20 }, .{ .width = 1500, .height = 600 }).?;
    try std.testing.expectEqual(@as(usize, 130), tall.y);
    try std.testing.expectEqual(@as(usize, 260), tall.h);
}

test "wide removed strips get distinct focus badges and a scaled caption" {
    const page = @import("palette.zig").page;
    const Image = values.Image;
    const Pixel = values.Pixel;
    const Rows = @import("report_sheet.zig").Rows;
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(Pixel, 3800 * 120);
    defer allocator.free(pixels);
    @memset(pixels, page);
    const image: Image = .{ .width = 3800, .height = 120, .pixels = pixels };
    const regions = [_]Region{
        .{ .number = 1, .kind = .removed, .before = values.Box.fromPixels(100, 4, 3100, 14) },
        .{ .number = 2, .kind = .removed, .before = values.Box.fromPixels(100, 44, 3100, 14) },
    };
    const rows = try Rows.init(allocator, image, image, &regions, &.{});
    defer rows.deinit(allocator);
    const first = rows.plan.details[0].focus_badges[0].?;
    const second = rows.plan.details[1].focus_badges[0].?;
    try std.testing.expect(!first.overlaps(second));
    try std.testing.expect(!first.overlaps(rows.plan.details[1].focus_marks[0].?));
    try std.testing.expect(!second.overlaps(rows.plan.details[0].focus_marks[0].?));
    try std.testing.expect(std.mem.indexOf(u8, rows.plan.focuses[0].captions[0].bytes(), "scaled 35%") != null);
}

test "focus badges use space outside a crop when available" {
    const page = @import("palette.zig").page;
    const Image = values.Image;
    const Pixel = values.Pixel;
    const Rows = @import("report_sheet.zig").Rows;
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(Pixel, 1600 * 530);
    defer allocator.free(pixels);
    @memset(pixels, page);
    const image: Image = .{ .width = 1600, .height = 530, .pixels = pixels };
    const box = values.Box.fromPixels(1588, 460, 8, 6);
    const rows = try Rows.init(allocator, image, image, &.{.{ .number = 1, .kind = .changed, .before = box, .after = box }}, &.{});
    defer rows.deinit(allocator);
    try std.testing.expect(!rows.plan.details[0].focus_badges[0].?.overlaps(rows.plan.focuses[0].crops[0].?.to));
}
