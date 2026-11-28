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
const sourceRect = geometry.sourceRect;
const kindBit = palette.kindBit;
const Text = text.Text;
const textWidth = text.textWidth;
const Focus = focus.Focus;
const Detail = focus.Detail;
const detail_gap = focus.detail_gap;
const focusWindow = focus.focusWindow;
const layoutFocus = focus.layoutFocus;
const cropPair = crops.cropPair;
const max_crop_width = crops.max_crop_width;
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

/// Invalid images, regions or moves, more than max_regions regions, a sheet
/// past the pixel cap, or an allocation failure.
pub const RenderError = Allocator.Error || Image.Invalid || Region.CheckError || Move.CheckError || error{ SheetTooLarge, TooManyRegions };

const Captions = struct { size: usize, bounds: geometry.SideRects };

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

const DetailPlacement = struct { pane_layout: PaneLayout, panes: geometry.SideRects, top: usize, slot: usize, x: std.EnumArray(value.Side, usize) };
const DetailPlan = struct { details: []Detail, focuses: []Focus, end: usize, kinds: u8 };

/// Owns placements and borrows the source images. Release with deinit.
pub const Plan = struct {
    sources: std.EnumArray(value.Side, Pane),
    details: []Detail,
    focuses: []Focus,
    ribbons: []Ribbon,
    size: Size,
    pane_layout: PaneLayout,
    panes: geometry.SideRects,
    pane_end: usize,
    detail_slot_width: usize,
    detail_x: std.EnumArray(value.Side, usize),
    captions: Captions,
    labels: Labels,
    heading: Text,

    /// Lays out the sheet and checks that the complete output fits image bounds.
    pub fn init(allocator: Allocator, pair: value.Pair, regions: []const Region, moves: []const Move) RenderError!Plan {
        if (!pair.before.valid() or !pair.after.valid()) return error.InvalidImage;
        if (regions.len > value.max_regions) return error.TooManyRegions;
        const sizes = pair.sizes();
        for (regions) |region| try region.check(sizes);
        for (moves) |move| try move.check(sizes);
        const pane_layout = PaneLayout.init(pair.before.size(), pair.after.size());
        var size = try minimumSize(pair.before.size(), pair.after.size());
        const before_pane = try Pane.init(allocator, pair.before, pane_layout);
        errdefer before_pane.deinit(allocator);
        const after_pane = try Pane.init(allocator, pair.after, pane_layout);
        errdefer after_pane.deinit(allocator);
        var panes = pane_layout.panes(pair.before.size(), pair.after.size());
        reserveBadgeLanes(&panes, &size, pane_layout, pair, regions);
        const pane_end = @max(panes.get(.before).bottom(), panes.get(.after).bottom());
        size.height = pane_end + pane_layout.px(margin);
        const detail_x = pane_layout.px(margin) + pane_layout.px(detail_label_w);
        const slot = pane_layout.px(max_crop_width);
        const after_detail_x = detail_x + slot + pane_layout.px(crop_gap);
        if (regions.len != 0) size.width = @max(size.width, after_detail_x + slot + pane_layout.px(margin));
        const content = try planDetails(allocator, pair, regions, .{
            .pane_layout = pane_layout,
            .panes = panes,
            .top = pane_end + pane_layout.px(detail_header),
            .slot = slot,
            .x = .init(.{ .before = detail_x, .after = after_detail_x }),
        });
        const details = content.details;
        const focuses = content.focuses;
        errdefer allocator.free(details);
        errdefer allocator.free(focuses);
        const captions = layoutCaptions(pane_layout, panes, size.width);
        try placeBadges(allocator, details, focuses, panes, pair, size, pane_layout, captions.bounds, if (moves.len != 0 and pane_layout.arrangement == .side_by_side) .ribbons else .plain);
        if (details.len != 0) size.height = content.end + pane_layout.px(margin) - pane_layout.px(detail_gap);
        if (size.width > max_sheet_width or size.pixelCount() == null) return error.SheetTooLarge;

        const planned_ribbons = try planRibbons(allocator, moves, details, pane_layout);
        errdefer allocator.free(planned_ribbons);
        return .{
            .sources = .init(.{ .before = before_pane, .after = after_pane }),
            .details = details,
            .focuses = focuses,
            .ribbons = planned_ribbons,
            .size = size,
            .pane_layout = pane_layout,
            .panes = panes,
            .pane_end = pane_end,
            .detail_slot_width = slot,
            .detail_x = .init(.{ .before = detail_x, .after = after_detail_x }),
            .captions = captions,
            .labels = layoutLabels(pane_layout, panes.get(.before).x, pane_end, content.kinds),
            .heading = try layoutHeading(regions.len, moves),
        };
    }

    /// Releases the sheet's metadata.
    pub fn deinit(self: Plan, allocator: Allocator) void {
        self.sources.get(.after).deinit(allocator);
        self.sources.get(.before).deinit(allocator);
        allocator.free(self.ribbons);
        allocator.free(self.details);
        allocator.free(self.focuses);
    }

    /// Reports whether both overview sources can be written without alpha.
    pub fn isOpaque(self: Plan) bool {
        return self.sources.get(.before).isOpaque() and self.sources.get(.after).isOpaque();
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
        .width = if (pane_layout.arrangement == .panoramic)
            geometry.overview_width + 2 * pane_layout.px(margin)
        else
            @max(panes.get(.before).right(), panes.get(.after).right()) + pane_layout.px(margin),
        .height = @max(panes.get(.before).bottom(), panes.get(.after).bottom()) + pane_layout.px(margin),
    };
    if (size.width > max_sheet_width or size.pixelCount() == null) return error.SheetTooLarge;
    return size;
}

fn planDetails(allocator: Allocator, pair: value.Pair, regions: []const Region, placement: DetailPlacement) RenderError!DetailPlan {
    const pane_layout = placement.pane_layout;
    const panes = placement.panes;
    const slot = placement.slot;
    const details = try allocator.alloc(Detail, regions.len);
    errdefer allocator.free(details);
    var top = placement.top;
    var kinds: u8 = 0;
    const focuses = try allocator.alloc(Focus, if (pane_layout.arrangement == .panoramic) regions.len else 0);
    errdefer allocator.free(focuses);
    for (regions, details, 0..) |region, *detail, index| {
        const old = sourceRect(region.before);
        const new = sourceRect(region.after);
        kinds |= kindBit(region.kind());
        const before_mark = offsetMark(old, panes.get(.before), pair.before.size());
        const after_mark = offsetMark(new, panes.get(.after), pair.after.size());
        const view: focus.View = switch (pane_layout.arrangement) {
            .side_by_side => close_ups: {
                const patches = cropPair(pair, .init(.{ .before = old, .after = new }), placement.x, top, slot, pane_layout);
                const height = @max(pane_layout.px(min_slot_h), if (patches.get(.before)) |p| p.framedHeight(pane_layout) else 0, if (patches.get(.after)) |p| p.framedHeight(pane_layout) else 0);
                const close_ups: focus.CloseUps = .{ .crops = patches, .top = top, .height = height };
                top = std.math.add(usize, top, height + pane_layout.px(detail_gap)) catch return error.SheetTooLarge;
                if (top > value.max_extent) return error.SheetTooLarge;
                break :close_ups .{ .side_by_side = close_ups };
            },
            .panoramic => shown: {
                focuses[index] = .{ .windows = .init(.{ .before = focusWindow(old orelse new, pair.before.size()), .after = focusWindow(new orelse old, pair.after.size()) }) };
                break :shown .{ .panoramic = .{ .focus = index } };
            },
        };
        detail.* = .{
            .region = region,
            .marks = .init(.{ .before = before_mark, .after = after_mark }),
            .number = try Text.format(copy.number_format, .{region.number}),
            .view = view,
        };
    }
    if (pane_layout.arrangement == .panoramic) top = try layoutFocus(details, focuses, top);
    return .{ .details = details, .focuses = focuses, .end = top, .kinds = kinds };
}

fn planRibbons(allocator: Allocator, moves: []const Move, details: []const Detail, pane_layout: PaneLayout) RenderError![]Ribbon {
    // A single gutter represents a single vertical path. For independent
    // columns depict the path that covers the most moved pixels.
    var area: usize = 0;
    var column: ?Move = null;
    for (moves) |move| {
        const weight = move.width *| move.before.height;
        if (weight > area) {
            area = weight;
            column = move;
        }
    }
    var count: usize = 0;
    if (pane_layout.arrangement == .side_by_side) if (column) |chosen| {
        for (moves) |move| {
            if (move.x == chosen.x and move.width == chosen.width and previewMove(move, pane_layout) != null) count += 1;
        }
    };
    const planned_ribbons = try allocator.alloc(Ribbon, count);
    errdefer allocator.free(planned_ribbons);
    var index: usize = 0;
    if (pane_layout.arrangement == .side_by_side) if (column) |chosen| {
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
        .details = makeLabel(if (pane_layout.arrangement == .panoramic) pane_layout.px(margin) else left, pane_end + pane_layout.px(detail_title_gap), pane_layout.px(detail_title_size), .bold),
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
            .box = .{ .x = x, .y = pane_layout.px(swatch_top), .width = swatch, .height = swatch },
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

fn layoutCaptions(pane_layout: PaneLayout, panes: geometry.SideRects, width: usize) Captions {
    const available_before = if (pane_layout.arrangement == .panoramic) width - panes.get(.before).x else panes.get(.after).x - panes.get(.before).x -| pane_layout.px(caption_gap);
    var size = pane_layout.px(24);
    while (size > 1 and (textWidth(.bold, size, copy.before) > available_before or
        textWidth(.bold, size, copy.after) > width - panes.get(.after).x)) size -= 1;
    var result: Captions = .{ .size = size, .bounds = undefined };
    for (panes.values, copy.side_names.values, &result.bounds.values) |pane, label, *bounds| {
        bounds.* = .{ .x = pane.x, .y = pane.y - pane_layout.px(caption_offset), .width = textWidth(.bold, size, label), .height = text.Face.bold.height(size) };
    }
    return result;
}

fn reserveBadgeLanes(panes: *geometry.SideRects, size: *Size, pane_layout: PaneLayout, pair: value.Pair, regions: []const Region) void {
    const diameter = overviewDiameter(pane_layout);
    // A lane holds the badge and keeps its clearance on both sides.
    const needed = diameter + 2 * badges.thinPaneClearance(panes.*, pane_layout);
    var left = false;
    var right = false;
    var middle = false;
    for (regions) |region| {
        for (panes.values, std.enums.values(value.Side)) |pane, side| {
            const image = pair.get(side);
            const box = region.boxOn(side);
            const mark = offsetMark(sourceRect(box), pane, image.size()) orelse continue;
            const near_left = mark.x - pane.x < diameter;
            const near_right = pane.right() - mark.right() < diameter;
            left = left or (near_left and (side == .before or pane_layout.arrangement == .panoramic));
            right = right or (near_right and (side == .after or pane_layout.arrangement == .panoramic));
            middle = middle or (pane_layout.arrangement == .side_by_side and (if (side == .before) near_right else near_left));
        }
    }
    if (left) {
        const extra = needed -| panes.get(.before).x;
        panes.getPtr(.before).x += extra;
        panes.getPtr(.after).x += extra;
        size.width += extra;
    }
    if (middle) {
        const extra = needed -| (panes.get(.after).x - panes.get(.before).right());
        panes.getPtr(.after).x += extra;
        size.width += extra;
    }
    if (right) size.width = @max(size.width, panes.get(.after).right() + needed, panes.get(.before).right() + needed);
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
    try std.testing.expectEqual(captions.bounds.get(.before).height, captions.bounds.get(.after).height);
    try std.testing.expect(captions.bounds.get(.before).right() + pane_layout.px(caption_gap) <= captions.bounds.get(.after).x);
    try std.testing.expect(captions.bounds.get(.after).right() <= sheet.width);
}

test "a top change in a thin preview can use the beside lane" {
    const source: Size = .{ .width = 200, .height = 20_030 };
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(value.Pixel, source.width * source.height);
    defer allocator.free(pixels);
    @memset(pixels, .{ 240, 241, 242, 255 });
    const image: Image = .{ .width = source.width, .height = source.height, .pixels = pixels };
    const mark = value.Box.fromPixels(20, 0, 160, 160);
    const plan = try Plan.init(allocator, .{ .before = image, .after = image }, &.{.{ .number = 1, .before = mark, .after = mark }}, &.{});
    defer plan.deinit(allocator);
    const edit = plan.details[0].marks.get(.before).?;
    const badge = plan.details[0].badges.get(.before).position().?;
    try std.testing.expect(badge.y + badge.height > edit.y and badge.y < edit.bottom());
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
    const plan = try Plan.init(allocator, .{ .before = image, .after = image }, &regions, &.{});
    defer plan.deinit(allocator);
    for (plan.details) |detail| {
        const badge = detail.badges.get(.after).position() orelse return error.TestUnexpectedResult;
        const mark = detail.marks.get(.after) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(mark.y + mark.height / 2, badge.y + badge.height / 2);
    }
}

test {
    const page = palette.page;
    const Pixel = value.Pixel;
    const allocator = std.testing.allocator;
    const pixels: [80 * 80]Pixel = @splat(page);
    const image: Image = .{ .width = 80, .height = 80, .pixels = &pixels };
    const insert: Region = .{ .number = 1, .after = value.Box.fromPixels(0, 0, 4, 4) };
    const plan = try Plan.init(allocator, .{ .before = image, .after = image }, &.{insert}, &.{});
    defer plan.deinit(allocator);
    const bounds = plan.details[0].badges.get(.after).position().?;
    try std.testing.expect(bounds.bottom() <= plan.panes.get(.after).y);
    try std.testing.expect(!bounds.overlaps(plan.details[0].marks.get(.after).?));
}

test {
    const page = palette.page;
    const Pixel = value.Pixel;
    const allocator = std.testing.allocator;
    const pixels: [900 * 12]Pixel = @splat(page);
    const image: Image = .{ .width = 900, .height = 12, .pixels = &pixels };
    const region: Region = .{ .number = 1, .after = value.Box.fromPixels(400, 0, 12, 12) };
    const plan = try Plan.init(allocator, .{ .before = image, .after = image }, &.{region}, &.{});
    defer plan.deinit(allocator);
    const detail = plan.details[0];
    const overview = detail.badges.get(.after).position().?;
    const focus_badge = detail.view.panoramic.badges.get(.after).position().?;
    const pane_layout = PaneLayout.init(image.size(), image.size());
    try std.testing.expectEqual(overviewDiameter(pane_layout), overview.width);
    try std.testing.expectEqual(@as(usize, 59), focus_badge.width);
    try std.testing.expectEqual(plan.panes.get(.after).y, overview.bottom());
    try std.testing.expectEqual(plan.focuses[0].crops.get(.after).?.to.y, focus_badge.bottom());
}

test "plans refuse invalid caller regions and moves before laying out" {
    const page = palette.page;
    const Pixel = value.Pixel;
    const allocator = std.testing.allocator;
    const pixels: [40 * 40]Pixel = @splat(page);
    const image: Image = .{ .width = 40, .height = 40, .pixels = &pixels };
    const pair: value.Pair = .{ .before = image, .after = image };
    var fractional = value.Box.fromPixels(1, 1, 4, 4);
    fractional.width += 0.5;
    const many: [value.max_regions + 1]Region = @splat(.{ .number = 1, .after = value.Box.fromPixels(1, 1, 4, 4) });
    const still: Move = .{ .before = .{ .y = 4, .height = 8 }, .after = .{ .y = 4, .height = 8 }, .x = 0, .width = 40 };
    try std.testing.expectError(error.TooManyRegions, Plan.init(allocator, pair, &many, &.{}));
    try std.testing.expectError(error.InvalidRegionBox, Plan.init(allocator, pair, &.{.{ .number = 1, .after = fractional }}, &.{}));
    try std.testing.expectError(error.InvalidMove, Plan.init(allocator, pair, &.{}, &.{still}));
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
    for (&regions, boxes, 1..) |*r, box, i| r.* = .{ .number = i, .before = box, .after = box };
    const plan = try Plan.init(allocator, .{ .before = image, .after = image }, &regions, &.{});
    defer plan.deinit(allocator);
    for (plan.details, 0..) |detail, i| {
        const marker = detail.badges.get(.after).position().?;
        try std.testing.expect(marker.distanceSquared(detail.marks.get(.after).?) <= 144);
        for (plan.details, 0..) |other, j| {
            try std.testing.expect(!marker.overlaps(other.marks.get(.after).?));
            if (i != j) try std.testing.expect(!marker.overlaps(other.badges.get(.after).position().?));
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
    const plan = try Plan.init(allocator, .{ .before = image, .after = image }, &.{.{ .number = 1, .before = box, .after = box }}, &.{});
    defer plan.deinit(allocator);
    try std.testing.expect(plan.details[0].badges.get(.before).position().?.bottom() <= plan.panes.get(.before).y);
    try std.testing.expect(plan.details[0].badges.get(.after).position().?.bottom() <= plan.panes.get(.after).y);
}

test "edge badges use the gutter margins and the space above the caption" {
    const Pixel = value.Pixel;
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(Pixel, 400 * 300);
    defer allocator.free(pixels);
    @memset(pixels, .{ 45, 67, 85, 255 });
    const image: Image = .{ .width = 400, .height = 300, .pixels = pixels };
    const regions = [_]Region{
        .{ .number = 1, .before = .fromPixels(0, 145, 5, 10) },
        .{ .number = 2, .before = .fromPixels(395, 130, 5, 10), .after = .fromPixels(395, 130, 5, 10) },
        .{ .number = 3, .after = .fromPixels(220, 0, 10, 8) },
        .{ .number = 4, .before = .fromPixels(195, 145, 10, 10) },
    };
    const plan = try Plan.init(allocator, .{ .before = image, .after = image }, &regions, &.{});
    defer plan.deinit(allocator);
    const left = plan.details[0].badges.get(.before).position().?;
    const gap = plan.details[1].badges.get(.before).position().?;
    const right = plan.details[1].badges.get(.after).position().?;
    const top = plan.details[2].badges.get(.after).position().?;
    try std.testing.expect(left.right() <= plan.panes.get(.before).x);
    try std.testing.expect(gap.x >= plan.panes.get(.before).right() and gap.right() <= plan.panes.get(.after).x);
    try std.testing.expect(right.x >= plan.panes.get(.after).right());
    try std.testing.expect(top.bottom() <= plan.panes.get(.after).y);
    const center = plan.details[3].badges.get(.before).position().?;
    for ([_]Rect{ left, gap, right, top }) |badge_rect| {
        for (plan.panes.values) |pane| try std.testing.expect(!badge_rect.overlaps(pane));
    }
    const center_mark = plan.details[3].marks.get(.before).?;
    try std.testing.expect(center.overlaps(plan.panes.get(.before)));
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
        .{ .number = 1, .before = value.Box.fromPixels(450, 30, 80, 20), .after = value.Box.fromPixels(450, 30, 80, 20) },
        .{ .number = 2, .before = value.Box.fromPixels(900, 185, 80, 20), .after = value.Box.fromPixels(900, 185, 80, 20) },
        .{ .number = 3, .after = value.Box.fromPixels(1600, 40, 1950, 18) },
    };
    const plan = try Plan.init(allocator, .{ .before = image, .after = image }, &regions, &.{});
    defer plan.deinit(allocator);
    try std.testing.expect(plan.size.width <= max_sheet_width);
    try std.testing.expectEqual(@as(usize, geometry.overview_width), plan.panes.get(.before).width);
    try std.testing.expectEqual(@as(usize, 0), plan.panes.get(.after).x - plan.panes.get(.before).x);
    try std.testing.expectEqual(@as(usize, overview_caption_gap), plan.panes.get(.after).y - plan.panes.get(.before).bottom());
    try std.testing.expectEqual(plan.details[0].view.panoramic.focus, plan.details[1].view.panoramic.focus);
    try std.testing.expect(plan.details[2].view.panoramic.focus != plan.details[0].view.panoramic.focus);
    const first = plan.focuses[0];
    const before = first.crops.get(.before).?;
    const after = first.crops.get(.after).?;
    try std.testing.expectEqual(@as(usize, 300), before.from.height);
    try std.testing.expectEqual(before.from.width, before.to.width);
    try std.testing.expectEqual(before.from.height, before.to.height);
    try std.testing.expect(after.to.x > before.to.right());
    try std.testing.expectEqualStrings(copy.before ++ " | x 250-1180", first.captions.get(.before).bytes());
    const shrunk = plan.focuses[2].crops.get(.after).?;
    try std.testing.expectEqual(@as(usize, focus.focus_slot_width), shrunk.to.width);
    try std.testing.expect(shrunk.to.height < shrunk.from.height);
    for (plan.details) |detail| {
        if (detail.badges.get(.after).position()) |b| try std.testing.expect(!b.overlaps(detail.marks.get(.after).?));
        if (detail.view.panoramic.badges.get(.after).position()) |b| try std.testing.expect(!b.overlaps(detail.view.panoramic.marks.get(.after).?));
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
        .{ .number = 1, .before = value.Box.fromPixels(100, 4, 3100, 14) },
        .{ .number = 2, .before = value.Box.fromPixels(100, 44, 3100, 14) },
    };
    const plan = try Plan.init(allocator, .{ .before = image, .after = image }, &regions, &.{});
    defer plan.deinit(allocator);
    const first = plan.details[0].view.panoramic.badges.get(.before).position().?;
    const second = plan.details[1].view.panoramic.badges.get(.before).position().?;
    try std.testing.expect(!first.overlaps(second));
    try std.testing.expect(!first.overlaps(plan.details[1].view.panoramic.marks.get(.before).?));
    try std.testing.expect(!second.overlaps(plan.details[0].view.panoramic.marks.get(.before).?));
    try std.testing.expect(std.mem.indexOf(u8, plan.focuses[0].captions.get(.before).bytes(), "scaled 35%") != null);
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
    const plan = try Plan.init(allocator, .{ .before = image, .after = image }, &.{.{ .number = 1, .before = box, .after = box }}, &.{});
    defer plan.deinit(allocator);
    try std.testing.expect(!plan.details[0].view.panoramic.badges.get(.before).position().?.overlaps(plan.focuses[0].crops.get(.before).?.to));
}
