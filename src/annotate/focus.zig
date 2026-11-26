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
const Zoom = crops.Zoom;
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

/// A positioned badge, with a leader only when its route is clear.
pub const Badge = union(enum) {
    none,
    plain: Rect,
    linked: Rect,

    /// Returns the badge rectangle when placement found room.
    pub fn position(self: Badge) ?Rect {
        return switch (self) {
            .none => null,
            .plain, .linked => |rect| rect,
        };
    }
};

/// One numbered region's crops, marks and badges in the overview and detail rows.
pub const Detail = struct {
    region: Region,
    before: ?Crop,
    after: ?Crop,
    before_mark: ?Rect,
    after_mark: ?Rect,
    before_badge: Badge = .none,
    after_badge: Badge = .none,
    focus: usize = 0,
    focus_marks: [2]?Rect = .{ null, null },
    focus_badges: [2]Badge = @splat(.none),
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
    // position in the sheet when merging a group.
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
        var zoom: Zoom = .{ .numerator = 1 };
        for (focus.windows) |window| {
            const from = window orelse continue;
            zoom = zoom.fit(from, .{ .width = focus_slot_width, .height = values.max_extent });
        }
        for (focus.windows, &focus.crops, &focus.captions, [2][]const u8{ copy.before, copy.after }, 0..) |window, *patch, *caption, name, side| {
            const from = window orelse {
                caption.* = try Text.format(copy.name_format, .{name});
                continue;
            };
            const projected = zoom.apply(from, focusColumn(side), top + focus_caption_height);
            patch.* = projected;
            caption.* = if (zoom.numerator == zoom.denominator)
                try Text.format(copy.focus_format, .{ name, from.x, from.right() })
            else
                try Text.format(copy.scaled_focus_format, .{ name, from.x, from.right(), @max(1, (100 * zoom.numerator + zoom.denominator / 2) / zoom.denominator) });
            height = @max(height, projected.to.h);
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

test {
    const tall = focusWindow(.{ .x = 240, .y = 250, .w = 10, .h = 20 }, .{ .width = 1500, .height = 600 }).?;
    try std.testing.expectEqual(@as(usize, 130), tall.y);
    try std.testing.expectEqual(@as(usize, 260), tall.h);
}
