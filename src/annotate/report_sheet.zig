//! Row compositor for the styled comparison report.
const std = @import("std");
const report_layout = @import("report_layout.zig");
const copy = @import("copy.zig");
const values = @import("../value.zig");
const geometry = @import("geometry.zig");
const palette = @import("palette.zig");
const text = @import("text.zig");
const focus_layout = @import("focus.zig");
const crops = @import("crops.zig");
const badges = @import("badges.zig");
const alignment = @import("alignment.zig");
const Layout = geometry.Layout;
const margin = geometry.margin;
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
const kindBit = palette.kindBit;
const kindName = palette.kindName;
const tint = palette.tint;
const Line = text.Line;
const Face = text.Face;
const textWidth = text.textWidth;
const focus_caption_height = focus_layout.focus_caption_height;
const focusColumn = focus_layout.focusColumn;
const crop = crops.crop;
const drawPane = crops.drawPane;
const drawDetail = crops.drawDetail;
const paintCrop = crops.paintCrop;
const badgeDiameter = badges.badgeDiameter;
const badge = badges.badge;
const drawMark = badges.drawMark;
const overviewDiameter = badges.overviewDiameter;
const Allocator = std.mem.Allocator;
const Image = values.Image;
const Size = values.Size;
const Pixel = values.Pixel;
const Region = values.Region;
const Move = values.Move;

/// Failures laying out a styled comparison or allocating its pixels.
pub const RenderError = report_layout.RenderError;

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
    plan: report_layout.Plan,

    /// Lays out the sheet before drawing any rows.
    pub fn init(allocator: Allocator, before: Image, after: Image, regions: []const Region, moves: []const Move) RenderError!Rows {
        return .{ .plan = try report_layout.Plan.init(allocator, before, after, regions, moves) };
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
        return self.plan.before.image.isOpaque() and self.plan.after.image.isOpaque();
    }

    /// Paints one output row into storage supplied by the encoder.
    pub noinline fn row(self: Rows, y: usize, pixels: []Pixel) []const Pixel {
        const plan = self.plan;
        const line: Line = .{ .pixels = pixels, .y = y };
        const ui = plan.layout;
        const a = plan.panes[0];
        const b = plan.panes[1];
        const left_x = a.x;
        const body = ui.px(24);
        if (ui.wide or y < a.y or y >= plan.pane_end) @memset(pixels, page);
        if (y < a.y) {
            line.text(left_x, ui.px(34), plan.heading.bytes(), .bold, ui.px(34), ink);
            if (y >= ui.px(79) and y < ui.px(116)) {
                var x = left_x;
                for ([_]values.Kind{ .changed, .inserted, .removed }) |kind| {
                    if (plan.kinds & kindBit(kind) == 0) continue;
                    const swatch = ui.px(22);
                    line.rounded(.{ .x = x, .y = ui.px(86), .w = swatch, .h = swatch }, ui.px(5), tint(kind));
                    line.text(x + ui.px(34), ui.px(79), kindName(kind), .regular, body, secondary);
                    x += ui.px(56) + textWidth(.regular, body, kindName(kind));
                }
            }
            line.text(left_x, a.y - ui.px(48), copy.before, .bold, plan.pane_caption_size[0], secondary);
        } else if (!ui.wide and y < plan.pane_end) {
            line.fill(0, left_x, page);
            line.fill(b.right(), pixels.len, page);
            alignment.drawGutter(line, y - a.y, ui, plan.panes, plan.ribbons);
        }
        line.text(b.x, b.y - ui.px(48), copy.after, .bold, plan.pane_caption_size[1], secondary);
        if (y + ui.px(8) >= a.y and y < plan.pane_end + ui.px(12)) {
            if (!ui.wide or nearPane(y, a, ui)) drawPane(line, plan.before, a.x, a.y, ui);
            if (!ui.wide or nearPane(y, b, ui)) drawPane(line, plan.after, b.x, b.y, ui);
        }
        const badge_reach = overviewDiameter(ui);
        if (y + badge_reach >= a.y and y < plan.pane_end + badge_reach) {
            for (plan.details) |detail| {
                drawMark(line, detail.before_mark, detail.before_badge, detail, ui);
                drawMark(line, detail.after_mark, detail.after_badge, detail, ui);
            }
        }
        if (plan.details.len != 0 and y >= plan.pane_end) {
            if (ui.wide) {
                self.drawFocus(line);
                return pixels;
            }
            line.text(left_x, plan.pane_end + ui.px(26), copy.changes_up_close, .bold, ui.px(30), ink);
            const detail_x = plan.detail_x[0];
            const after_detail_x = plan.detail_x[1];
            for (plan.details) |detail| {
                if (y < detail.top or y >= detail.top + detail.height) continue;
                const diameter = badgeDiameter(ui);
                const center = detail.top + diameter / 2;
                badge(line, .{ .x = left_x, .y = detail.top, .w = diameter, .h = diameter }, detail.region.kind, detail.number.bytes(), ui);
                line.text(left_x + ui.px(71), center - Face.regular.height(body) / 2, kindName(detail.region.kind), .regular, body, secondary);
                drawDetail(line, detail.before, plan.before.image, detail_x, plan.detail_slot_width, detail.top, detail.height, detail.region.kind, ui);
                drawDetail(line, detail.after, plan.after.image, after_detail_x, plan.detail_slot_width, detail.top, detail.height, detail.region.kind, ui);
                break;
            }
        }
        return pixels;
    }

    noinline fn drawFocus(self: Rows, line: Line) void {
        const plan = self.plan;
        line.text(margin, plan.pane_end + 26, copy.at_full_size, .bold, 30, ink);
        const badge_reach = badgeDiameter(plan.layout) -| focus_caption_height;
        for (plan.focuses, 0..) |focus, index| {
            // A badge placed above a short crop can extend into the gap
            // before the caption. Unused merge entries have zero height.
            if (focus.height == 0 or line.y + badge_reach < focus.top or line.y >= focus.top + focus.height) continue;
            for (focus.crops, [2]Image{ plan.before.image, plan.after.image }, focus.captions, 0..) |patch, image, caption, side| {
                const x = focusColumn(side);
                line.text(x, focus.top, caption.bytes(), .regular, 22, secondary);
                if (patch) |p| {
                    paintCrop(line, p, image);
                    line.stroke(p.to.outset(1), 2, 1, outline_gray);
                } else {
                    line.text(x, focus.top + focus_caption_height, copy.not_on_side, .regular, 22, muted);
                }
            }
            for (plan.details) |detail| {
                if (detail.focus != index) continue;
                for (detail.focus_marks, detail.focus_badges) |mark, location| {
                    drawMark(line, mark, location, detail, plan.layout);
                }
            }
            return;
        }
    }
};

/// Renders the same rows as the streaming report for in-memory consumers.
pub fn render(allocator: Allocator, before: Image, after: Image, regions: []const Region, moves: []const Move) RenderError!Sheet {
    const rows = try Rows.init(allocator, before, after, regions, moves);
    defer rows.deinit(allocator);
    const pixels = try allocator.alloc(Pixel, rows.plan.size.pixelCount().?);
    for (0..rows.plan.size.height) |y| _ = rows.row(y, pixels[y * rows.plan.size.width ..][0..rows.plan.size.width]);
    return .{ .pixels = pixels, .width = rows.plan.size.width, .height = rows.plan.size.height };
}

test {
    std.testing.refAllDecls(@This());
}

test "the streaming gutter connects shifted rows and shows the insertion wedge" {
    const allocator = std.testing.allocator;
    const pixels: [32 * 128]Pixel = @splat(white);
    const image: Image = .{ .width = 32, .height = 128, .pixels = &pixels };
    const insert: Region = .{ .number = 1, .kind = .inserted, .after = values.Box.fromPixels(3, 44, 20, 10) };
    const moved: Move = .{ .before = .{ .y = 40, .height = 60 }, .after = .{ .y = 60, .height = 60 }, .x = .init(0), .width = .init(32) };
    const rows = try Rows.init(allocator, image, image, &.{insert}, &.{moved});
    defer rows.deinit(allocator);
    const storage = try allocator.alloc(Pixel, rows.plan.size.width);
    defer allocator.free(storage);
    const x = rows.plan.panes[0].right();
    const gap = rows.plan.panes[1].x - x;
    const in_wedge = rows.row(rows.plan.panes[0].y + rows.plan.layout.position(50), storage);
    try std.testing.expectEqual(moved_band, in_wedge[x + 10]);
    try std.testing.expectEqual(insert_band, in_wedge[x + gap - 10]);
    const fixed = rows.row(rows.plan.panes[0].y + rows.plan.layout.position(125), storage);
    try std.testing.expectEqual(stationary, fixed[x + gap / 2]);
}

test "wide overviews reserve no alignment strip even when rows move" {
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
        const size = try report_layout.minimumSize(source, source);
        try std.testing.expect(size.width <= max_sheet_width);
        try std.testing.expect(size.height < 2000);
        const ui = Layout.init(source, source);
        try std.testing.expect(ui.preview(source).height <= 1600);
    }
}
