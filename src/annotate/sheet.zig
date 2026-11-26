//! Row compositor for the styled comparison sheet.
const std = @import("std");
const drawing = @import("drawing.zig");
const plan = @import("sheet/plan.zig");
const copy = drawing.copy;
const value = @import("../value.zig");
const geometry = @import("geometry.zig");
const palette = drawing.palette;
const text = drawing.text;
const canvas = drawing.canvas;
const focus = @import("focus.zig");
const crops = @import("crops.zig");
const badges = @import("badges.zig");
const ribbons = @import("ribbons.zig");
const PaneLayout = geometry.PaneLayout;
const gutter = geometry.gutter;
const max_sheet_width = geometry.max_sheet_width;
const overview_caption_gap = geometry.overview_caption_gap;
const nearPane = geometry.nearPane;
const page = palette.page;
const ink = palette.ink;
const secondary = palette.secondary;
const muted = palette.muted;
const outline_gray = palette.outline_gray;
const white = palette.white;
const stationary = palette.stationary;
const moved_band = palette.moved_band;
const insert_band = palette.insert_band;
const kindName = palette.kindName;
const tint = palette.tint;
const Line = canvas.Line;
const focus_caption_height = focus.focus_caption_height;
const focusColumn = focus.focusColumn;
const Pane = geometry.Pane;
const paneRect = geometry.paneRect;
const roundSpan = canvas.roundSpan;
const drawDetail = crops.drawDetail;
const paintCrop = crops.paintCrop;
const badgeDiameter = badges.badgeDiameter;
const badge = badges.badge;
const drawMark = badges.drawMark;
const overviewDiameter = badges.overviewDiameter;
const Allocator = std.mem.Allocator;
const Image = value.Image;
const Size = value.Size;
const Pixel = value.Pixel;
const Region = value.Region;
const Move = value.Move;

/// Checks the minimum sheet dimensions before detail planning.
pub const minimumSize = plan.minimumSize;

/// Failures laying out a styled comparison or allocating its pixels.
pub const RenderError = plan.RenderError;

/// An owned RGBA8 sheet in whole sheet pixels, released by deinit.
pub const Sheet = struct {
    pixels: []Pixel,
    width: usize,
    height: usize,

    /// Releases the pixels with the allocator passed to render.
    pub fn deinit(self: Sheet, allocator: Allocator) void {
        allocator.free(self.pixels);
    }

    /// Borrows the sheet as an image.
    pub fn image(self: Sheet) Image {
        return .{ .width = self.width, .height = self.height, .pixels = self.pixels };
    }
};

/// A streamed styled sheet. The source images are borrowed.
pub const Rows = struct {
    plan: plan.Plan,

    pub const staged = true;

    /// Lays out the sheet before drawing any rows.
    pub fn init(allocator: Allocator, before: Image, after: Image, regions: []const Region, moves: []const Move) RenderError!Rows {
        return .{ .plan = try plan.Plan.init(allocator, before, after, regions, moves) };
    }

    /// Releases the layout's owned metadata.
    pub fn deinit(self: Rows, allocator: Allocator) void {
        self.plan.deinit(allocator);
    }

    /// Returns output dimensions in whole sheet pixels.
    pub fn size(self: Rows) Size {
        return self.plan.size;
    }

    /// Reports whether the encoder can represent this sheet losslessly in RGB.
    pub fn isOpaque(self: Rows) bool {
        return self.plan.isOpaque();
    }

    /// Paints one output row into storage supplied by the encoder.
    pub noinline fn row(self: Rows, y: usize, pixels: []Pixel) []const Pixel {
        const sheet_plan = self.plan;
        const line: Line = .{ .pixels = pixels, .y = y };
        const pane_layout = sheet_plan.pane_layout;
        const a = sheet_plan.panes[0];
        const b = sheet_plan.panes[1];
        const left_x = a.x;
        const labels = sheet_plan.labels;
        if (pane_layout.panoramic or y < a.y or y >= sheet_plan.pane_end) @memset(pixels, page);
        if (y < a.y) {
            const title = labels.title;
            if (title.containsRow(y)) line.text(title.x, title.y, sheet_plan.heading.bytes(), .bold, title.size, ink);
            for (labels.legend) |entry| if (entry) |e| {
                if (e.box.containsRow(y)) line.rounded(e.box, e.radius, tint(e.kind));
                if (e.label.containsRow(y)) line.text(e.label.x, e.label.y, kindName(e.kind), .regular, e.label.size, secondary);
            };
            const caption = sheet_plan.captions.bounds[0];
            if (caption.containsRow(y)) line.text(caption.x, caption.y, copy.before, .bold, sheet_plan.captions.size, secondary);
        } else if (!pane_layout.panoramic and y < sheet_plan.pane_end) {
            line.fill(0, left_x, page);
            line.fill(b.right(), pixels.len, page);
            ribbons.drawGutter(line, y - a.y, pane_layout, sheet_plan.panes, sheet_plan.ribbons);
        }
        const caption = sheet_plan.captions.bounds[1];
        if (caption.containsRow(y)) line.text(caption.x, caption.y, copy.after, .bold, sheet_plan.captions.size, secondary);
        if (y + pane_layout.px(8) >= a.y and y < sheet_plan.pane_end + pane_layout.px(12)) {
            if (!pane_layout.panoramic or nearPane(y, a, pane_layout)) drawPane(line, sheet_plan.before, a.x, a.y, pane_layout);
            if (!pane_layout.panoramic or nearPane(y, b, pane_layout)) drawPane(line, sheet_plan.after, b.x, b.y, pane_layout);
        }
        const badge_reach = overviewDiameter(pane_layout);
        if (y + badge_reach >= a.y and y < sheet_plan.pane_end + badge_reach) {
            for (sheet_plan.details) |detail| {
                drawMark(line, detail.before_mark, detail.before_badge, detail, pane_layout);
                drawMark(line, detail.after_mark, detail.after_badge, detail, pane_layout);
            }
        }
        if (sheet_plan.details.len != 0 and y >= sheet_plan.pane_end) {
            const heading = labels.details;
            if (heading.containsRow(y)) {
                const title = if (pane_layout.panoramic) copy.at_full_size else copy.detail_section_title;
                line.text(heading.x, heading.y, title, .bold, heading.size, ink);
            }
            if (pane_layout.panoramic) {
                self.drawFocus(line);
                return pixels;
            }
            const detail_x = sheet_plan.detail_x[0];
            const after_detail_x = sheet_plan.detail_x[1];
            for (sheet_plan.details) |detail| {
                if (y < detail.top or y >= detail.top + detail.height) continue;
                const diameter = labels.detail_badge;
                badge(line, .{ .x = left_x, .y = detail.top, .w = diameter, .h = diameter }, detail.region.kind, detail.number.bytes(), pane_layout);
                line.text(labels.detail_kind_x, detail.top + labels.detail_kind_offset, kindName(detail.region.kind), .regular, labels.body_size, secondary);
                drawDetail(line, detail.before, sheet_plan.before.image, detail_x, sheet_plan.detail_slot_width, detail.top, detail.height, detail.region.kind, pane_layout);
                drawDetail(line, detail.after, sheet_plan.after.image, after_detail_x, sheet_plan.detail_slot_width, detail.top, detail.height, detail.region.kind, pane_layout);
                break;
            }
        }
        return pixels;
    }

    noinline fn drawFocus(self: Rows, line: Line) void {
        const sheet_plan = self.plan;
        const badge_reach = badgeDiameter(sheet_plan.pane_layout) -| focus_caption_height;
        for (sheet_plan.focuses, 0..) |window, index| {
            // A badge placed above a short crop can extend into the gap
            // before the caption. Unused merge entries have zero height.
            if (window.height == 0 or line.y + badge_reach < window.top or line.y >= window.top + window.height) continue;
            for (window.crops, [2]Image{ sheet_plan.before.image, sheet_plan.after.image }, window.captions, 0..) |patch, image, caption, side| {
                const x = focusColumn(side);
                line.text(x, window.top, caption.bytes(), .regular, text.caption_size, secondary);
                if (patch) |p| {
                    paintCrop(line, p, image);
                    line.stroke(p.to.outset(1), 2, 1, outline_gray);
                } else {
                    line.text(x, window.top + focus_caption_height, copy.not_on_side, .regular, text.caption_size, muted);
                }
            }
            for (sheet_plan.details) |detail| {
                if (detail.focus != index) continue;
                for (detail.focus_marks, detail.focus_badges) |mark, location| {
                    drawMark(line, mark, location, detail, sheet_plan.pane_layout);
                }
            }
            return;
        }
    }
};

/// Renders the same rows as the streaming sheet for in-memory consumers.
pub fn render(allocator: Allocator, before: Image, after: Image, regions: []const Region, moves: []const Move) RenderError!Sheet {
    const rows = try Rows.init(allocator, before, after, regions, moves);
    defer rows.deinit(allocator);
    const size = rows.size();
    const pixels = try allocator.alloc(Pixel, size.pixelCount().?);
    for (0..size.height) |y| _ = rows.row(y, pixels[y * size.width ..][0..size.width]);
    return .{ .pixels = pixels, .width = size.width, .height = size.height };
}

/// Copies the visible preview pixels for one row.
noinline fn drawPane(line: Line, pane: Pane, x: usize, y: usize, pane_layout: PaneLayout) void {
    const rect = paneRect(x, y, pane.dimensions);
    const radius = pane_layout.px(16);
    const shades = [_]Pixel{ .{ 241, 241, 242, 255 }, .{ 237, 237, 238, 255 }, .{ 232, 232, 234, 255 } };
    if (line.y >= y + radius + pane_layout.px(5) and line.y + radius + pane_layout.px(5) < y + rect.h) {
        const right = x + rect.w;
        var outer = pane_layout.px(8);
        for ([_]usize{ 5, 2, 0 }, shades) |inset, tone| {
            const inner = pane_layout.px(inset);
            line.fill(x - outer, x - inner, tone);
            line.fill(right + inner, right + outer, tone);
            outer = inner;
        }
        pane.copy(line.y - y, 0, line.pixels[x..right]);
        return;
    }
    const visible = roundSpan(rect, radius, line.y);
    if (visible) |span| {
        line.fill(x, span[0], page);
        line.fill(span[1], x + rect.w, page);
    } else line.fill(x, x + rect.w, page);

    // Layer short bands of softening shadow while leaving the pane interior
    // to its source copy. The extra painting only touches the perimeter.
    for ([_]usize{ 8, 5, 2 }, shades) |spread, tone| {
        var shadow = rect.outset(pane_layout.px(spread));
        shadow.y += pane_layout.px(4);
        if (roundSpan(shadow, radius + pane_layout.px(spread), line.y)) |span| {
            if (visible) |inside| {
                line.fill(span[0], @min(inside[0], span[1]), tone);
                line.fill(@max(inside[1], span[0]), span[1], tone);
            } else line.fill(span[0], span[1], tone);
        }
    }
    if (visible) |span| {
        pane.copy(line.y - y, span[0] - x, line.pixels[span[0]..span[1]]);
    }
}

test {
    std.testing.refAllDecls(@This());
}

test "the streaming gutter connects shifted rows and shows the insertion wedge" {
    const allocator = std.testing.allocator;
    const pixels: [32 * 128]Pixel = @splat(white);
    const image: Image = .{ .width = 32, .height = 128, .pixels = &pixels };
    const insert: Region = .{ .number = 1, .kind = .inserted, .after = value.Box.fromPixels(3, 44, 20, 10) };
    const moved: Move = .{ .before = .{ .y = 40, .height = 60 }, .after = .{ .y = 60, .height = 60 }, .x = .init(0), .width = .init(32) };
    const rows = try Rows.init(allocator, image, image, &.{insert}, &.{moved});
    defer rows.deinit(allocator);
    const storage = try allocator.alloc(Pixel, rows.plan.size.width);
    defer allocator.free(storage);
    const x = rows.plan.panes[0].right();
    const gap = rows.plan.panes[1].x - x;
    const in_wedge = rows.row(rows.plan.panes[0].y + rows.plan.pane_layout.position(50), storage);
    try std.testing.expectEqual(moved_band, in_wedge[x + 10]);
    try std.testing.expectEqual(insert_band, in_wedge[x + gap - 10]);
    const fixed = rows.row(rows.plan.panes[0].y + rows.plan.pane_layout.position(125), storage);
    try std.testing.expectEqual(stationary, fixed[x + gap / 2]);
}

test "panoramic overviews reserve no alignment strip even when rows move" {
    const allocator = std.testing.allocator;
    const pixels: [360 * 120]Pixel = @splat(white);
    const image: Image = .{ .width = 360, .height = 120, .pixels = &pixels };
    const move: Move = .{ .before = .{ .y = 10, .height = 30 }, .after = .{ .y = 60, .height = 30 }, .x = .init(0), .width = .init(360) };
    const rows = try Rows.init(allocator, image, image, &.{}, &.{move});
    defer rows.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), rows.plan.ribbons.len);
    try std.testing.expectEqual(@as(usize, overview_caption_gap), rows.plan.panes[1].y - rows.plan.panes[0].bottom());
}

test "short and tall strips have bounded previews" {
    for ([_]Size{
        .{ .width = 1, .height = 200 },
        .{ .width = 200, .height = 1 },
        .{ .width = 1, .height = 1000 },
        .{ .width = 2, .height = 3000 },
        .{ .width = 1, .height = 5000 },
        .{ .width = 1, .height = 20000 },
        .{ .width = 3, .height = 60000 },
    }) |source| {
        const size = try plan.minimumSize(source, source);
        try std.testing.expect(size.width <= max_sheet_width);
        try std.testing.expect(size.height < 2000);
        const pane_layout = PaneLayout.init(source, source);
        try std.testing.expect(pane_layout.preview(source).height <= 1600);
    }
}
