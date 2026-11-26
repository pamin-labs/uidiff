//! Allocates the complete layout for a styled comparison sheet.
const std = @import("std");
const drawing = @import("../drawing.zig");
const copy = drawing.copy;
const value = @import("../../value.zig");
const geometry = @import("../geometry.zig");
const palette = drawing.palette;
const text = drawing.text;
const focus = @import("../focus.zig");
const crops = @import("../crops.zig");
const badges = @import("../badges.zig");
const ribbons = @import("../ribbons.zig");
const Rect = geometry.Rect;
const PaneLayout = geometry.PaneLayout;
const Pane = geometry.Pane;
const margin = geometry.margin;
const max_sheet_width = geometry.max_sheet_width;
const offsetMark = geometry.offsetMark;
const imageRect = geometry.imageRect;
const kindBit = palette.kindBit;
const Text = text.Text;
const textWidth = text.textWidth;
const Focus = focus.Focus;
const Detail = focus.Detail;
const detail_gap = focus.detail_gap;
const focusWindow = focus.focusWindow;
const layoutFocus = focus.layoutFocus;
const cropPair = crops.cropPair;
const max_crop_w = crops.max_crop_w;
const placeBadges = badges.placeBadges;
const overviewDiameter = badges.overviewDiameter;
const Ribbon = ribbons.Ribbon;
const displacement = ribbons.displacement;
const previewMove = ribbons.previewMove;
const earlierRibbonEnd = ribbons.earlierRibbonEnd;
const wedgeTop = ribbons.wedgeTop;
const Allocator = std.mem.Allocator;
const Image = value.Image;
const Size = value.Size;
const Region = value.Region;
const Move = value.Move;

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
    kind: value.Kind,
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

const DetailPlacement = struct { pane_layout: PaneLayout, panes: [2]Rect, top: usize, slot: usize, x: [2]usize };
const DetailPlan = struct { details: []Detail, focuses: []Focus, end: usize, kinds: u8 };

/// Owns placements and borrows the source images. Release with deinit.
pub const Plan = struct {
    before: Pane,
    after: Pane,
    details: []Detail,
    focuses: []Focus,
    ribbons: []Ribbon,
    size: Size,
    pane_layout: PaneLayout,
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
        const pane_layout = PaneLayout.init(before.size(), after.size());
        var size = try minimumSize(before.size(), after.size());
        const before_pane = try Pane.init(allocator, before, pane_layout);
        errdefer before_pane.deinit(allocator);
        const after_pane = try Pane.init(allocator, after, pane_layout);
        errdefer after_pane.deinit(allocator);
        var panes = pane_layout.panes(before.size(), after.size());
        reserveBadgeLanes(&panes, &size, pane_layout, before, after, regions);
        const pane_end = @max(panes[0].bottom(), panes[1].bottom());
        size.height = pane_end + pane_layout.px(margin);
        const detail_x = pane_layout.px(margin) + pane_layout.px(detail_label_w);
        const slot = pane_layout.px(max_crop_w);
        const after_detail_x = detail_x + slot + pane_layout.px(crop_gap);
        if (regions.len != 0) size.width = @max(size.width, after_detail_x + slot + pane_layout.px(margin));
        const content = try planDetails(allocator, before, after, regions, .{
            .pane_layout = pane_layout,
            .panes = panes,
            .top = pane_end + pane_layout.px(detail_header),
            .slot = slot,
            .x = .{ detail_x, after_detail_x },
        });
        const details = content.details;
        const focuses = content.focuses;
        errdefer allocator.free(details);
        errdefer allocator.free(focuses);
        const captions = layoutCaptions(pane_layout, panes, size.width);
        try placeBadges(allocator, details, focuses, panes, .{ before, after }, size, pane_layout, captions.bounds, if (moves.len != 0 and !pane_layout.panoramic) .ribbons else .plain);
        if (details.len != 0) size.height = content.end + pane_layout.px(margin) - pane_layout.px(detail_gap);
        if (size.width > max_sheet_width or size.pixelCount() == null) return error.SheetTooLarge;

        const planned_ribbons = try planRibbons(allocator, moves, details, before.size(), after.size(), pane_layout);
        errdefer allocator.free(planned_ribbons);
        return .{
            .before = before_pane,
            .after = after_pane,
            .details = details,
            .focuses = focuses,
            .ribbons = planned_ribbons,
            .size = size,
            .pane_layout = pane_layout,
            .panes = panes,
            .pane_end = pane_end,
            .detail_slot_width = slot,
            .detail_x = .{ detail_x, after_detail_x },
            .captions = captions,
            .labels = layoutLabels(pane_layout, panes[0].x, pane_end, content.kinds),
            .heading = try layoutHeading(regions.len, moves),
        };
    }

    /// Releases the sheet's metadata.
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

const legend_kinds = [_]value.Kind{ .changed, .inserted, .removed };
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

/// Checks the preview dimensions before allocating sheet details.
pub fn minimumSize(before: Size, after: Size) error{SheetTooLarge}!Size {
    if (before.pixelCount() == null or after.pixelCount() == null) return error.SheetTooLarge;
    const pane_layout = PaneLayout.init(before, after);
    const panes = pane_layout.panes(before, after);
    const size: Size = .{
        .width = if (pane_layout.panoramic)
            geometry.overview_width + 2 * pane_layout.px(margin)
        else
            @max(panes[0].right(), panes[1].right()) + pane_layout.px(margin),
        .height = @max(panes[0].bottom(), panes[1].bottom()) + pane_layout.px(margin),
    };
    if (size.width > max_sheet_width or size.pixelCount() == null) return error.SheetTooLarge;
    return size;
}

fn planDetails(allocator: Allocator, before: Image, after: Image, regions: []const Region, placement: DetailPlacement) RenderError!DetailPlan {
    const pane_layout = placement.pane_layout;
    const panes = placement.panes;
    const slot = placement.slot;
    const detail_x, const after_detail_x = placement.x;
    const details = try allocator.alloc(Detail, regions.len);
    errdefer allocator.free(details);
    var top = placement.top;
    var kinds: u8 = 0;
    const focuses = try allocator.alloc(Focus, if (pane_layout.panoramic) regions.len else 0);
    errdefer allocator.free(focuses);
    for (regions, details, 0..) |region, *detail, index| {
        const old = imageRect(before, region.before);
        const new = imageRect(after, region.after);
        if ((region.before != null and old == null) or (region.after != null and new == null)) return error.InvalidRegionBox;
        if (region.number == 0 and (old != null or new != null)) return error.InvalidRegionNumber;
        kinds |= kindBit(region.kind);
        const a, const b = if (pane_layout.panoramic) .{ null, null } else cropPair(.{ before, after }, .{ old, new }, .{ detail_x, after_detail_x }, top, slot, pane_layout);
        const height = @max(pane_layout.px(min_slot_h), if (a) |p| p.to.h + 2 * pane_layout.px(3) else 0, if (b) |p| p.to.h + 2 * pane_layout.px(3) else 0);
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
        if (pane_layout.panoramic) {
            focuses[index] = .{ .windows = .{ focusWindow(old orelse new, before.size()), focusWindow(new orelse old, after.size()) } };
        } else {
            top = std.math.add(usize, top, height + pane_layout.px(detail_gap)) catch return error.SheetTooLarge;
            if (top > value.max_extent) return error.SheetTooLarge;
        }
    }
    if (pane_layout.panoramic) top = try layoutFocus(details, focuses, .{ before.size(), after.size() }, top);
    return .{ .details = details, .focuses = focuses, .end = top, .kinds = kinds };
}

fn planRibbons(allocator: Allocator, moves: []const Move, details: []const Detail, before: Size, after: Size, pane_layout: PaneLayout) RenderError![]Ribbon {
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
    if (!pane_layout.panoramic) if (column) |chosen| {
        for (moves) |move| {
            if (move.x == chosen.x and move.width == chosen.width and previewMove(move, pane_layout) != null) count += 1;
        }
    };
    const planned_ribbons = try allocator.alloc(Ribbon, count);
    errdefer allocator.free(planned_ribbons);
    var index: usize = 0;
    if (!pane_layout.panoramic) if (column) |chosen| {
        for (moves) |move| {
            if (move.x != chosen.x or move.width != chosen.width) continue;
            const drawn = previewMove(move, pane_layout) orelse continue;
            const delta = displacement(move);
            const wedge = wedgeTop(details, move, delta > 0);
            planned_ribbons[index] = .{ .move = drawn, .wedge_top = if (wedge) |y| pane_layout.position(y) else null, .label = if (delta >= 0)
                try Text.format(copy.positive_shift_format, .{delta})
            else
                try Text.format(copy.shift_format, .{delta}) };
            index += 1;
        }
    };
    std.sort.heap(Ribbon, planned_ribbons, {}, earlierRibbonEnd);
    return planned_ribbons;
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

fn layoutLabels(pane_layout: PaneLayout, left: usize, pane_end: usize, kinds: u8) Labels {
    const body = pane_layout.px(body_size);
    const mark = badges.badgeDiameter(pane_layout);
    var labels: Labels = .{
        .title = makeLabel(left, pane_layout.px(title_top), pane_layout.px(title_size), .bold),
        .legend = @splat(null),
        .details = makeLabel(if (pane_layout.panoramic) pane_layout.px(margin) else left, pane_end + pane_layout.px(detail_title_gap), pane_layout.px(detail_title_size), .bold),
        .detail_kind_x = left + pane_layout.px(detail_kind_gap),
        .detail_kind_offset = mark / 2 - text.Face.regular.height(body) / 2,
        .detail_badge = mark,
        .body_size = body,
    };
    var x = left;
    const swatch = pane_layout.px(swatch_size);
    for (legend_kinds, &labels.legend) |kind, *entry| {
        if (kinds & kindBit(kind) == 0) continue;
        entry.* = .{
            .kind = kind,
            .box = .{ .x = x, .y = pane_layout.px(swatch_top), .w = swatch, .h = swatch },
            .radius = pane_layout.px(swatch_rounding),
            .label = makeLabel(x + pane_layout.px(legend_text_x), pane_layout.px(legend_top), body, .regular),
        };
        x += pane_layout.px(legend_spacing) + textWidth(.regular, body, palette.kindName(kind));
    }
    return labels;
}

fn makeLabel(x: usize, y: usize, size: usize, face: text.Face) Label {
    return .{ .x = x, .y = y, .size = size, .height = face.height(size) };
}

fn layoutCaptions(pane_layout: PaneLayout, panes: [2]Rect, width: usize) Captions {
    const available_before = if (pane_layout.panoramic) width - panes[0].x else panes[1].x - panes[0].x -| pane_layout.px(caption_gap);
    var size = pane_layout.px(24);
    while (size > 1 and (textWidth(.bold, size, copy.before) > available_before or
        textWidth(.bold, size, copy.after) > width - panes[1].x)) size -= 1;
    var result: Captions = .{ .size = size, .bounds = undefined };
    for (panes, [_][]const u8{ copy.before, copy.after }, &result.bounds) |pane, label, *bounds| {
        bounds.* = .{ .x = pane.x, .y = pane.y - pane_layout.px(caption_offset), .w = textWidth(.bold, size, label), .h = text.Face.bold.height(size) };
    }
    return result;
}

fn reserveBadgeLanes(panes: *[2]Rect, size: *Size, pane_layout: PaneLayout, before: Image, after: Image, regions: []const Region) void {
    const diameter = overviewDiameter(pane_layout);
    const needed = diameter + if (@min(panes[0].w, panes[1].w) < diameter) 2 * pane_layout.px(badges.thin_badge_gap) else 0;
    var left = false;
    var right = false;
    var middle = false;
    for (regions) |region| {
        for ([_]Image{ before, after }, [_]?value.Box{ region.before, region.after }, panes.*, 0..) |image, box, pane, side| {
            const mark = offsetMark(imageRect(image, box), pane, image.size()) orelse continue;
            const near_left = mark.x - pane.x < diameter;
            const near_right = pane.right() - mark.right() < diameter;
            left = left or (near_left and (side == 0 or pane_layout.panoramic));
            right = right or (near_right and (side == 1 or pane_layout.panoramic));
            middle = middle or (!pane_layout.panoramic and (if (side == 0) near_right else near_left));
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
    const pane_layout = PaneLayout.init(source, source);
    const panes = pane_layout.panes(source, source);
    const sheet = try minimumSize(source, source);
    const captions = layoutCaptions(pane_layout, panes, sheet.width);
    try std.testing.expect(captions.size < pane_layout.px(24));
    try std.testing.expectEqual(captions.bounds[0].h, captions.bounds[1].h);
    try std.testing.expect(captions.bounds[0].right() + pane_layout.px(caption_gap) <= captions.bounds[1].x);
    try std.testing.expect(captions.bounds[1].right() <= sheet.width);
}

test "a top change in a thin preview can use the beside lane" {
    const source: Size = .{ .width = 200, .height = 20_030 };
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(value.Pixel, source.width * source.height);
    defer allocator.free(pixels);
    @memset(pixels, .{ 240, 241, 242, 255 });
    const image: Image = .{ .width = source.width, .height = source.height, .pixels = pixels };
    const mark = value.Box.fromPixels(20, 0, 160, 160);
    const plan = try Plan.init(allocator, image, image, &.{.{ .number = 1, .before = mark, .after = mark }}, &.{});
    defer plan.deinit(allocator);
    const edit = plan.details[0].before_mark.?;
    const badge = plan.details[0].before_badge.position().?;
    try std.testing.expect(badge.y + badge.h > edit.y and badge.y < edit.bottom());
}

test "two stacked badges stay level with their own marks" {
    const size: Size = .{ .width = 320, .height = 520 };
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(value.Pixel, size.width * size.height);
    defer allocator.free(pixels);
    @memset(pixels, .{ 240, 242, 245, 255 });
    const image: Image = .{ .width = size.width, .height = size.height, .pixels = pixels };
    const regions = [_]Region{
        .{ .number = 1, .after = value.Box.fromPixels(280, 80, 25, 30) },
        .{ .number = 2, .after = value.Box.fromPixels(280, 190, 25, 30) },
    };
    const plan = try Plan.init(allocator, image, image, &regions, &.{});
    defer plan.deinit(allocator);
    for (plan.details) |detail| {
        const badge = detail.after_badge.position() orelse return error.TestUnexpectedResult;
        const mark = detail.after_mark orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(mark.y + mark.h / 2, badge.y + badge.h / 2);
    }
}

test {
    const page = palette.page;
    const Pixel = value.Pixel;
    const allocator = std.testing.allocator;
    const pixels: [80 * 80]Pixel = @splat(page);
    const image: Image = .{ .width = 80, .height = 80, .pixels = &pixels };
    const insert: Region = .{ .number = 1, .kind = .inserted, .after = value.Box.fromPixels(0, 0, 4, 4) };
    const plan = try Plan.init(allocator, image, image, &.{insert}, &.{});
    defer plan.deinit(allocator);
    const bounds = plan.details[0].after_badge.position().?;
    try std.testing.expect(bounds.bottom() <= plan.panes[1].y);
    try std.testing.expect(!bounds.overlaps(plan.details[0].after_mark.?));
}

test {
    const page = palette.page;
    const Pixel = value.Pixel;
    const allocator = std.testing.allocator;
    const pixels: [900 * 12]Pixel = @splat(page);
    const image: Image = .{ .width = 900, .height = 12, .pixels = &pixels };
    const region: Region = .{ .number = 1, .kind = .changed, .after = value.Box.fromPixels(400, 0, 12, 12) };
    const plan = try Plan.init(allocator, image, image, &.{region}, &.{});
    defer plan.deinit(allocator);
    const detail = plan.details[0];
    const overview = detail.after_badge.position().?;
    const focus_badge = detail.focus_badges[1].position().?;
    const pane_layout = PaneLayout.init(image.size(), image.size());
    try std.testing.expectEqual(overviewDiameter(pane_layout), overview.w);
    try std.testing.expectEqual(@as(usize, 59), focus_badge.w);
    try std.testing.expectEqual(plan.panes[1].y, overview.bottom());
    try std.testing.expectEqual(plan.focuses[0].crops[1].?.to.y, focus_badge.bottom());
}

test "edge badges stay near their numbered boxes and avoid all other marks" {
    const page = palette.page;
    const Pixel = value.Pixel;
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(Pixel, 400 * 300);
    defer allocator.free(pixels);
    @memset(pixels, page);
    const image: Image = .{ .width = 400, .height = 300, .pixels = pixels };
    const boxes = [_]value.Box{
        .fromPixels(0, 0, 4, 4),   .fromPixels(396, 0, 4, 4),   .fromPixels(198, 0, 5, 3),
        .fromPixels(0, 296, 4, 4), .fromPixels(396, 296, 4, 4),
    };
    var regions: [boxes.len]Region = undefined;
    for (&regions, boxes, 1..) |*r, box, i| r.* = .{ .number = i, .kind = .changed, .before = box, .after = box };
    const plan = try Plan.init(allocator, image, image, &regions, &.{});
    defer plan.deinit(allocator);
    for (plan.details, 0..) |detail, i| {
        const marker = detail.after_badge.position().?;
        try std.testing.expect(marker.distanceSquared(detail.after_mark.?) <= 144);
        for (plan.details, 0..) |other, j| {
            try std.testing.expect(!marker.overlaps(other.after_mark.?));
            if (i != j) try std.testing.expect(!marker.overlaps(other.after_badge.position().?));
        }
    }
}

test "whole-image wide changes have a badge in both overviews" {
    const page = palette.page;
    const Pixel = value.Pixel;
    const allocator = std.testing.allocator;
    const pixels: [900 * 12]Pixel = @splat(page);
    const image: Image = .{ .width = 900, .height = 12, .pixels = &pixels };
    const box = value.Box.fromPixels(0, 0, 900, 12);
    const plan = try Plan.init(allocator, image, image, &.{.{ .number = 1, .kind = .changed, .before = box, .after = box }}, &.{});
    defer plan.deinit(allocator);
    try std.testing.expect(plan.details[0].before_badge.position().?.bottom() <= plan.panes[0].y);
    try std.testing.expect(plan.details[0].after_badge.position().?.bottom() <= plan.panes[1].y);
}

test "edge badges use the gutter margins and the space above the caption" {
    const Pixel = value.Pixel;
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
    const plan = try Plan.init(allocator, image, image, &regions, &.{});
    defer plan.deinit(allocator);
    const left = plan.details[0].before_badge.position().?;
    const gap = plan.details[1].before_badge.position().?;
    const right = plan.details[1].after_badge.position().?;
    const top = plan.details[2].after_badge.position().?;
    try std.testing.expect(left.right() <= plan.panes[0].x);
    try std.testing.expect(gap.x >= plan.panes[0].right() and gap.right() <= plan.panes[1].x);
    try std.testing.expect(right.x >= plan.panes[1].right());
    try std.testing.expect(top.bottom() <= plan.panes[1].y);
    const center = plan.details[3].before_badge.position().?;
    for ([_]Rect{ left, gap, right, top }) |badge_rect| {
        for (plan.panes) |pane| try std.testing.expect(!badge_rect.overlaps(pane));
    }
    const center_mark = plan.details[3].before_mark.?;
    try std.testing.expect(center.overlaps(plan.panes[0]));
    try std.testing.expect(!center.overlaps(center_mark));
    try std.testing.expect(center.distanceSquared(center_mark) <= 36);
}

test "panoramic sheets use bounded overviews and merge overlapping focus crops" {
    const overview_caption_gap = geometry.overview_caption_gap;
    const Pixel = value.Pixel;
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(Pixel, 3600 * 300);
    defer allocator.free(pixels);
    const canvas = @import("uidiff_test_canvas").Painters(value.Image);
    @memset(pixels, canvas.white);
    const image: Image = .{ .width = 3600, .height = 300, .pixels = pixels };
    const regions = [_]Region{
        .{ .number = 1, .kind = .changed, .before = value.Box.fromPixels(450, 30, 80, 20), .after = value.Box.fromPixels(450, 30, 80, 20) },
        .{ .number = 2, .kind = .changed, .before = value.Box.fromPixels(900, 185, 80, 20), .after = value.Box.fromPixels(900, 185, 80, 20) },
        .{ .number = 3, .kind = .inserted, .after = value.Box.fromPixels(1600, 40, 1950, 18) },
    };
    const plan = try Plan.init(allocator, image, image, &regions, &.{});
    defer plan.deinit(allocator);
    try std.testing.expect(plan.size.width <= max_sheet_width);
    try std.testing.expectEqual(@as(usize, geometry.overview_width), plan.panes[0].w);
    try std.testing.expectEqual(@as(usize, 0), plan.panes[1].x - plan.panes[0].x);
    try std.testing.expectEqual(@as(usize, overview_caption_gap), plan.panes[1].y - plan.panes[0].bottom());
    try std.testing.expectEqual(plan.details[0].focus, plan.details[1].focus);
    try std.testing.expect(plan.details[2].focus != plan.details[0].focus);
    const first = plan.focuses[0];
    const before = first.crops[0].?;
    const after = first.crops[1].?;
    try std.testing.expectEqual(@as(usize, 300), before.from.h);
    try std.testing.expectEqual(before.from.w, before.to.w);
    try std.testing.expectEqual(before.from.h, before.to.h);
    try std.testing.expect(after.to.x > before.to.right());
    try std.testing.expectEqualStrings(copy.before ++ " | x 250-1180", first.captions[0].bytes());
    const shrunk = plan.focuses[2].crops[1].?;
    try std.testing.expectEqual(@as(usize, focus.focus_slot_width), shrunk.to.w);
    try std.testing.expect(shrunk.to.h < shrunk.from.h);
    for (plan.details) |detail| {
        if (detail.after_badge.position()) |b| try std.testing.expect(!b.overlaps(detail.after_mark.?));
        if (detail.focus_badges[1].position()) |b| try std.testing.expect(!b.overlaps(detail.focus_marks[1].?));
    }
}

test "wide removed strips get distinct focus badges and a scaled caption" {
    const page = palette.page;
    const Pixel = value.Pixel;
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(Pixel, 3800 * 120);
    defer allocator.free(pixels);
    @memset(pixels, page);
    const image: Image = .{ .width = 3800, .height = 120, .pixels = pixels };
    const regions = [_]Region{
        .{ .number = 1, .kind = .removed, .before = value.Box.fromPixels(100, 4, 3100, 14) },
        .{ .number = 2, .kind = .removed, .before = value.Box.fromPixels(100, 44, 3100, 14) },
    };
    const plan = try Plan.init(allocator, image, image, &regions, &.{});
    defer plan.deinit(allocator);
    const first = plan.details[0].focus_badges[0].position().?;
    const second = plan.details[1].focus_badges[0].position().?;
    try std.testing.expect(!first.overlaps(second));
    try std.testing.expect(!first.overlaps(plan.details[1].focus_marks[0].?));
    try std.testing.expect(!second.overlaps(plan.details[0].focus_marks[0].?));
    try std.testing.expect(std.mem.indexOf(u8, plan.focuses[0].captions[0].bytes(), "scaled 35%") != null);
}

test "focus badges use space outside a crop when available" {
    const page = palette.page;
    const Pixel = value.Pixel;
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(Pixel, 1600 * 530);
    defer allocator.free(pixels);
    @memset(pixels, page);
    const image: Image = .{ .width = 1600, .height = 530, .pixels = pixels };
    const box = value.Box.fromPixels(1588, 460, 8, 6);
    const plan = try Plan.init(allocator, image, image, &.{.{ .number = 1, .kind = .changed, .before = box, .after = box }}, &.{});
    defer plan.deinit(allocator);
    try std.testing.expect(!plan.details[0].focus_badges[0].position().?.overlaps(plan.focuses[0].crops[0].?.to));
}
