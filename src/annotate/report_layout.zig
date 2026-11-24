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
const crop = crops.crop;
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
    pane_caption_size: [2]usize,
    kinds: u8,
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
        const details = try allocator.alloc(Detail, regions.len);
        errdefer allocator.free(details);
        var top = pane_end + layout.px(detail_header);
        var kinds: u8 = 0;
        const focuses = try allocator.alloc(Focus, if (layout.wide) regions.len else 0);
        errdefer allocator.free(focuses);
        for (regions, details, 0..) |region, *detail, index| {
            const old = imageRect(before, region.before);
            const new = imageRect(after, region.after);
            if ((region.before != null and old == null) or (region.after != null and new == null)) return error.InvalidRegionBox;
            if (region.number == 0 and (old != null or new != null)) return error.InvalidRegionNumber;
            kinds |= kindBit(region.kind);
            const a = if (layout.wide) null else crop(before, old, detail_x, top, slot, layout);
            const b = if (layout.wide) null else crop(after, new, after_detail_x, top, slot, layout);
            const height = @max(layout.px(min_slot_h), if (a) |p| p.to.h + 2 * layout.px(3) else 0, if (b) |p| p.to.h + 2 * layout.px(3) else 0);
            const before_mark = offsetMark(old, panes[0], before.size());
            const after_mark = offsetMark(new, panes[1], after.size());
            detail.* = .{
                .region = region,
                .before = a,
                .after = b,
                .before_mark = before_mark,
                .after_mark = after_mark,
                .before_badge = null,
                .after_badge = null,
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
        try placeBadges(allocator, details, focuses, panes, size, layout);
        if (details.len != 0) size.height = top + layout.px(margin) - layout.px(detail_gap);
        if (size.width > max_sheet_width or size.pixelCount() == null) return error.SheetTooLarge;

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
        var down: usize = 0;
        for (moves) |move| if (displacement(move) > 0) {
            down += 1;
        };
        const changes = if (regions.len == 1) copy.change else copy.changes;
        const blocks = if (moves.len == 1) copy.block else copy.blocks;
        const direction = if (down == moves.len) copy.down else if (down == 0) copy.up else "";
        const heading = if (moves.len == 0) try Text.format(copy.heading_format, .{ regions.len, changes }) else try Text.format(copy.moved_heading_format, .{ regions.len, changes, moves.len, blocks, direction });
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
            .pane_caption_size = .{
                captionSize(layout, copy.before, if (layout.wide) size.width - panes[0].x else panes[1].x - panes[0].x -| layout.px(8)),
                captionSize(layout, copy.after, size.width - panes[1].x),
            },
            .kinds = kinds,
            .heading = heading,
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
};

const detail_label_w = 260;
const detail_header = 82;
const crop_gap = 40;
const min_slot_h = 68;

/// Checks the preview dimensions before allocating report details.
pub fn minimumSize(before: Size, after: Size) error{SheetTooLarge}!Size {
    if (before.pixelCount() == null or after.pixelCount() == null) return error.SheetTooLarge;
    const ui = Layout.init(before, after);
    const panes = ui.panes(before, after);
    const size: Size = .{
        .width = @max(panes[0].right(), panes[1].right()) + ui.px(margin),
        .height = @max(panes[0].bottom(), panes[1].bottom()) + ui.px(margin),
    };
    if (size.width > max_sheet_width or size.pixelCount() == null) return error.SheetTooLarge;
    return size;
}

fn captionSize(layout: Layout, label: []const u8, available: usize) usize {
    var size = layout.px(24);
    while (size > 1 and textWidth(.bold, size, label) > available) size -= 1;
    return size;
}

fn reserveBadgeLanes(panes: *[2]Rect, size: *Size, ui: Layout, before: Image, after: Image, regions: []const Region) void {
    const diameter = overviewDiameter(ui);
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
        const extra = diameter -| panes[0].x;
        panes[0].x += extra;
        panes[1].x += extra;
        size.width += extra;
    }
    if (middle) {
        const extra = diameter -| (panes[1].x - panes[0].right());
        panes[1].x += extra;
        size.width += extra;
    }
    if (right) size.width = @max(size.width, panes[1].right() + diameter, panes[0].right() + diameter);
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
    const available = panes[1].x - panes[0].x - layout.px(8);
    try std.testing.expect(textWidth(.bold, layout.px(24), copy.before) > available);
    const size = captionSize(layout, copy.before, available);
    try std.testing.expect(textWidth(.bold, size, copy.before) <= available);
}
