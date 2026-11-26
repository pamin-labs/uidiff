//! Allocates the complete layout for a styled comparison report.
const std = @import("std");
const copy = @import("copy.zig");
const values = @import("../value.zig");
const geometry = @import("geometry.zig");
const palette = @import("palette.zig");
const text = @import("text.zig");
const focus_layout = @import("focus.zig");
const crops = @import("crops.zig");
const badges = @import("badges.zig");
const alignment = @import("alignment.zig");
const Rect = geometry.Rect;
const Layout = geometry.Layout;
const Pane = geometry.Pane;
const margin = geometry.margin;
const max_sheet_width = geometry.max_sheet_width;
const offsetMark = geometry.offsetMark;
const imageRect = geometry.imageRect;
const kindBit = palette.kindBit;
const Text = text.Text;
const textWidth = text.textWidth;
const Focus = focus_layout.Focus;
const Detail = focus_layout.Detail;
const detail_gap = focus_layout.detail_gap;
const focusWindow = focus_layout.focusWindow;
const layoutFocus = focus_layout.layoutFocus;
const cropPair = crops.cropPair;
const max_crop_w = crops.max_crop_w;
const placeBadges = badges.placeBadges;
const overviewDiameter = badges.overviewDiameter;
const Ribbon = alignment.Ribbon;
const displacement = alignment.displacement;
const previewMove = alignment.previewMove;
const earlierRibbonEnd = alignment.earlierRibbonEnd;
const wedgeTop = alignment.wedgeTop;
const Allocator = std.mem.Allocator;
const Image = values.Image;
const Size = values.Size;
const Region = values.Region;
const Move = values.Move;

/// Invalid images or regions, a sheet past the pixel cap, or an allocation failure.
pub const RenderError = Allocator.Error || Image.Invalid || error{ SheetTooLarge, InvalidRegionBox, InvalidRegionNumber };

const Captions = struct { size: usize, bounds: [2]Rect };

const Label = struct {
    x: usize,
    y: usize,
    size: usize,
    height: usize,

    pub fn containsRow(self: Label, y: usize) bool {
        return y >= self.y and y - self.y < self.height;
    }
};

const LegendEntry = struct {
    kind: values.Kind,
    box: Rect,
    radius: usize,
    label: Label,
};

const Labels = struct {
    title: Label,
    legend: [legend_kinds.len]?LegendEntry,
    details: Label,
    detail_kind_x: usize,
    detail_kind_offset: usize,
    detail_badge: usize,
    body_size: usize,
};

const DetailPlacement = struct { layout: Layout, panes: [2]Rect, top: usize, slot: usize, x: [2]usize };
const DetailPlan = struct { details: []Detail, focuses: []Focus, end: usize, kinds: u8 };

/// Owns placements and borrows the source images. Release with deinit.
pub const Plan = struct {
    before: Pane,
    after: Pane,
    details: []Detail,
    focuses: []Focus,
    ribbons: []Ribbon,
    size: Size,
    layout: Layout,
    panes: [2]Rect,
    pane_end: usize,
    detail_slot_width: usize,
    detail_x: [2]usize,
    captions: Captions,
    labels: Labels,
    heading: Text,

    /// Lays out the sheet and checks that the complete output fits image bounds.
    pub fn init(allocator: Allocator, before: Image, after: Image, regions: []const Region, moves: []const Move) RenderError!Plan {
        if (!before.valid() or !after.valid()) return error.InvalidImage;
        const layout = Layout.init(before.size(), after.size());
        var size = try minimumSize(before.size(), after.size());
        const before_pane = try Pane.init(allocator, before, layout);
        errdefer before_pane.deinit(allocator);
        const after_pane = try Pane.init(allocator, after, layout);
        errdefer after_pane.deinit(allocator);
        var panes = layout.panes(before.size(), after.size());
        reserveBadgeLanes(&panes, &size, layout, before, after, regions);
        const pane_end = @max(panes[0].bottom(), panes[1].bottom());
        size.height = pane_end + layout.px(margin);
        const detail_x = layout.px(margin) + layout.px(detail_label_w);
        const slot = layout.px(max_crop_w);
        const after_detail_x = detail_x + slot + layout.px(crop_gap);
        if (regions.len != 0) size.width = @max(size.width, after_detail_x + slot + layout.px(margin));
        const content = try planDetails(allocator, before, after, regions, .{
            .layout = layout,
            .panes = panes,
            .top = pane_end + layout.px(detail_header),
            .slot = slot,
            .x = .{ detail_x, after_detail_x },
        });
        const details = content.details;
        const focuses = content.focuses;
        errdefer allocator.free(details);
        errdefer allocator.free(focuses);
        const captions = layoutCaptions(layout, panes, size.width);
        try placeBadges(allocator, details, focuses, panes, .{ before, after }, size, layout, captions.bounds, if (moves.len != 0 and !layout.wide) .alignment else .plain);
        if (details.len != 0) size.height = content.end + layout.px(margin) - layout.px(detail_gap);
        if (size.width > max_sheet_width or size.pixelCount() == null) return error.SheetTooLarge;

        const ribbons = try planRibbons(allocator, moves, details, before.size(), after.size(), layout);
        errdefer allocator.free(ribbons);
        return .{
            .before = before_pane,
            .after = after_pane,
            .details = details,
            .focuses = focuses,
            .ribbons = ribbons,
            .size = size,
            .layout = layout,
            .panes = panes,
            .pane_end = pane_end,
            .detail_slot_width = slot,
            .detail_x = .{ detail_x, after_detail_x },
            .captions = captions,
            .labels = layoutLabels(layout, panes[0].x, pane_end, content.kinds),
            .heading = try layoutHeading(regions.len, moves),
        };
    }

    /// Releases the report's metadata.
    pub fn deinit(self: Plan, allocator: Allocator) void {
        self.after.deinit(allocator);
        self.before.deinit(allocator);
        allocator.free(self.ribbons);
        allocator.free(self.details);
        allocator.free(self.focuses);
    }

    /// Reports whether both overview sources can be written without alpha.
    pub fn isOpaque(self: Plan) bool {
        return self.before.isOpaque() and self.after.isOpaque();
    }
};

const detail_label_w = 260;
const detail_header = 82;
const crop_gap = 40;
const min_slot_h = 68;
const caption_gap = 16;
const caption_offset = 48;

const legend_kinds = [_]values.Kind{ .changed, .inserted, .removed };
const title_size = 34;
const title_top = 34;
const legend_top = 79;
const swatch_top = 86;
const swatch_size = 22;
const swatch_rounding = 5;
const legend_text_x = 34;
const legend_spacing = 56;
const detail_title_gap = 26;
const detail_title_size = 30;
const body_size = 24;
const detail_kind_gap = 71;

/// Checks the preview dimensions before allocating report details.
pub fn minimumSize(before: Size, after: Size) error{SheetTooLarge}!Size {
    if (before.pixelCount() == null or after.pixelCount() == null) return error.SheetTooLarge;
    const ui = Layout.init(before, after);
    const panes = ui.panes(before, after);
    const size: Size = .{
        .width = if (ui.wide)
            geometry.overview_width + 2 * ui.px(margin)
        else
            @max(panes[0].right(), panes[1].right()) + ui.px(margin),
        .height = @max(panes[0].bottom(), panes[1].bottom()) + ui.px(margin),
    };
    if (size.width > max_sheet_width or size.pixelCount() == null) return error.SheetTooLarge;
    return size;
}

fn planDetails(allocator: Allocator, before: Image, after: Image, regions: []const Region, placement: DetailPlacement) RenderError!DetailPlan {
    const layout = placement.layout;
    const panes = placement.panes;
    const slot = placement.slot;
    const detail_x, const after_detail_x = placement.x;
    const details = try allocator.alloc(Detail, regions.len);
    errdefer allocator.free(details);
    var top = placement.top;
    var kinds: u8 = 0;
    const focuses = try allocator.alloc(Focus, if (layout.wide) regions.len else 0);
    errdefer allocator.free(focuses);
    for (regions, details, 0..) |region, *detail, index| {
        const old = imageRect(before, region.before);
        const new = imageRect(after, region.after);
        if ((region.before != null and old == null) or (region.after != null and new == null)) return error.InvalidRegionBox;
        if (region.number == 0 and (old != null or new != null)) return error.InvalidRegionNumber;
        kinds |= kindBit(region.kind);
        const a, const b = if (layout.wide) .{ null, null } else cropPair(.{ before, after }, .{ old, new }, .{ detail_x, after_detail_x }, top, slot, layout);
        const height = @max(layout.px(min_slot_h), if (a) |p| p.to.h + 2 * layout.px(3) else 0, if (b) |p| p.to.h + 2 * layout.px(3) else 0);
        const before_mark = offsetMark(old, panes[0], before.size());
        const after_mark = offsetMark(new, panes[1], after.size());
        detail.* = .{
            .region = region,
            .before = a,
            .after = b,
            .before_mark = before_mark,
            .after_mark = after_mark,
            .focus = index,
            .number = try Text.format(copy.number_format, .{region.number}),
            .top = top,
            .height = height,
        };
        if (layout.wide) {
            focuses[index] = .{ .windows = .{ focusWindow(old orelse new, before.size()), focusWindow(new orelse old, after.size()) } };
        } else {
            top = std.math.add(usize, top, height + layout.px(detail_gap)) catch return error.SheetTooLarge;
            if (top > values.max_extent) return error.SheetTooLarge;
        }
    }
    if (layout.wide) top = try layoutFocus(details, focuses, .{ before.size(), after.size() }, top);
    return .{ .details = details, .focuses = focuses, .end = top, .kinds = kinds };
}

fn planRibbons(allocator: Allocator, moves: []const Move, details: []const Detail, before: Size, after: Size, layout: Layout) RenderError![]Ribbon {
    // A single gutter represents a single vertical path. For independent
    // columns depict the path that covers the most moved pixels.
    var area: usize = 0;
    var column: ?Move = null;
    for (moves) |move| {
        if (move.before.y > before.height or move.before.height > before.height - move.before.y or
            move.after.y > after.height or move.after.height > after.height - move.after.y or
            move.before.height == 0 or move.before.height != move.after.height or move.before.y == move.after.y or
            move.x.count() > @min(before.width, after.width) or move.width.count() > @min(before.width, after.width) - move.x.count() or
            move.width.count() == 0) return error.InvalidImage;
        const weight = move.width.count() *| move.before.height;
        if (weight > area) {
            area = weight;
            column = move;
        }
    }
    var count: usize = 0;
    if (!layout.wide) if (column) |chosen| {
        for (moves) |move| {
            if (move.x == chosen.x and move.width == chosen.width and previewMove(move, layout) != null) count += 1;
        }
    };
    const ribbons = try allocator.alloc(Ribbon, count);
    errdefer allocator.free(ribbons);
    var index: usize = 0;
    if (!layout.wide) if (column) |chosen| {
        for (moves) |move| {
            if (move.x != chosen.x or move.width != chosen.width) continue;
            const drawn = previewMove(move, layout) orelse continue;
            const delta = displacement(move);
            const wedge = wedgeTop(details, move, delta > 0);
            ribbons[index] = .{ .move = drawn, .wedge_top = if (wedge) |y| layout.position(y) else null, .label = if (delta >= 0)
                try Text.format(copy.positive_shift_format, .{delta})
            else
                try Text.format(copy.shift_format, .{delta}) };
            index += 1;
        }
    };
    std.sort.heap(Ribbon, ribbons, {}, earlierRibbonEnd);
    return ribbons;
}

fn layoutHeading(region_count: usize, moves: []const Move) RenderError!Text {
    var down: usize = 0;
    for (moves) |move| if (displacement(move) > 0) {
        down += 1;
    };
    const changes = if (region_count == 1) copy.change else copy.changes;
    const blocks = if (moves.len == 1) copy.block else copy.blocks;
    const direction = if (down == moves.len) copy.down else if (down == 0) copy.up else "";
    return if (moves.len == 0) Text.format(copy.heading_format, .{ region_count, changes }) else Text.format(copy.moved_heading_format, .{ region_count, changes, moves.len, blocks, direction });
}

fn layoutLabels(ui: Layout, left: usize, pane_end: usize, kinds: u8) Labels {
    const body = ui.px(body_size);
    const mark = badges.badgeDiameter(ui);
    var labels: Labels = .{
        .title = makeLabel(left, ui.px(title_top), ui.px(title_size), .bold),
        .legend = @splat(null),
        .details = makeLabel(if (ui.wide) ui.px(margin) else left, pane_end + ui.px(detail_title_gap), ui.px(detail_title_size), .bold),
        .detail_kind_x = left + ui.px(detail_kind_gap),
        .detail_kind_offset = mark / 2 - text.Face.regular.height(body) / 2,
        .detail_badge = mark,
        .body_size = body,
    };
    var x = left;
    const swatch = ui.px(swatch_size);
    for (legend_kinds, &labels.legend) |kind, *entry| {
        if (kinds & kindBit(kind) == 0) continue;
        entry.* = .{
            .kind = kind,
            .box = .{ .x = x, .y = ui.px(swatch_top), .w = swatch, .h = swatch },
            .radius = ui.px(swatch_rounding),
            .label = makeLabel(x + ui.px(legend_text_x), ui.px(legend_top), body, .regular),
        };
        x += ui.px(legend_spacing) + textWidth(.regular, body, palette.kindName(kind));
    }
    return labels;
}

fn makeLabel(x: usize, y: usize, size: usize, face: text.Face) Label {
    return .{ .x = x, .y = y, .size = size, .height = face.height(size) };
}

fn layoutCaptions(layout: Layout, panes: [2]Rect, width: usize) Captions {
    const available_before = if (layout.wide) width - panes[0].x else panes[1].x - panes[0].x -| layout.px(caption_gap);
    var size = layout.px(24);
    while (size > 1 and (textWidth(.bold, size, copy.before) > available_before or
        textWidth(.bold, size, copy.after) > width - panes[1].x)) size -= 1;
    var result: Captions = .{ .size = size, .bounds = undefined };
    for (panes, [_][]const u8{ copy.before, copy.after }, &result.bounds) |pane, label, *bounds| {
        bounds.* = .{ .x = pane.x, .y = pane.y - layout.px(caption_offset), .w = textWidth(.bold, size, label), .h = text.Face.bold.height(size) };
    }
    return result;
}

fn reserveBadgeLanes(panes: *[2]Rect, size: *Size, ui: Layout, before: Image, after: Image, regions: []const Region) void {
    const diameter = overviewDiameter(ui);
    const needed = diameter + if (@min(panes[0].w, panes[1].w) < diameter) 2 * ui.px(badges.thin_badge_gap) else 0;
    var left = false;
    var right = false;
    var middle = false;
    for (regions) |region| {
        for ([_]Image{ before, after }, [_]?values.Box{ region.before, region.after }, panes.*, 0..) |image, box, pane, side| {
            const mark = offsetMark(imageRect(image, box), pane, image.size()) orelse continue;
            const near_left = mark.x - pane.x < diameter;
            const near_right = pane.right() - mark.right() < diameter;
            left = left or (near_left and (side == 0 or ui.wide));
            right = right or (near_right and (side == 1 or ui.wide));
            middle = middle or (!ui.wide and (if (side == 0) near_right else near_left));
        }
    }
    if (left) {
        const extra = needed -| panes[0].x;
        panes[0].x += extra;
        panes[1].x += extra;
        size.width += extra;
    }
    if (middle) {
        const extra = needed -| (panes[1].x - panes[0].right());
        panes[1].x += extra;
        size.width += extra;
    }
    if (right) size.width = @max(size.width, panes[1].right() + needed, panes[0].right() + needed);
}

test {
    std.testing.refAllDecls(@This());
}

test "large sources fit their reduced previews" {
    const source: Size = .{ .width = 3000, .height = 22_000 };
    const size = try minimumSize(source, source);
    try std.testing.expect(size.pixelCount() != null);
    try std.testing.expect(size.height < 2000);
}

test "thin tall previews have room for both pane captions" {
    const source: Size = .{ .width = 200, .height = 20_030 };
    const layout = Layout.init(source, source);
    const panes = layout.panes(source, source);
    const sheet = try minimumSize(source, source);
    const captions = layoutCaptions(layout, panes, sheet.width);
    try std.testing.expect(captions.size < layout.px(24));
    try std.testing.expectEqual(captions.bounds[0].h, captions.bounds[1].h);
    try std.testing.expect(captions.bounds[0].right() + layout.px(caption_gap) <= captions.bounds[1].x);
    try std.testing.expect(captions.bounds[1].right() <= sheet.width);
}

test "a top change in a thin preview can use the beside lane" {
    const source: Size = .{ .width = 200, .height = 20_030 };
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(values.Pixel, source.width * source.height);
    defer allocator.free(pixels);
    @memset(pixels, .{ 240, 241, 242, 255 });
    const image: Image = .{ .width = source.width, .height = source.height, .pixels = pixels };
    const mark = values.Box.fromPixels(20, 0, 160, 160);
    const plan = try Plan.init(allocator, image, image, &.{.{ .number = 1, .before = mark, .after = mark }}, &.{});
    defer plan.deinit(allocator);
    const edit = plan.details[0].before_mark.?;
    const badge = plan.details[0].before_badge.position().?;
    try std.testing.expect(badge.y + badge.h > edit.y and badge.y < edit.bottom());
}

test "two stacked badges stay level with their own marks" {
    const size: Size = .{ .width = 320, .height = 520 };
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(values.Pixel, size.width * size.height);
    defer allocator.free(pixels);
    @memset(pixels, .{ 240, 242, 245, 255 });
    const image: Image = .{ .width = size.width, .height = size.height, .pixels = pixels };
    const regions = [_]Region{
        .{ .number = 1, .after = values.Box.fromPixels(280, 80, 25, 30) },
        .{ .number = 2, .after = values.Box.fromPixels(280, 190, 25, 30) },
    };
    const plan = try Plan.init(allocator, image, image, &regions, &.{});
    defer plan.deinit(allocator);
    for (plan.details) |detail| {
        const badge = detail.after_badge.position() orelse return error.TestUnexpectedResult;
        const mark = detail.after_mark orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(mark.y + mark.h / 2, badge.y + badge.h / 2);
    }
}
