//! Crop context, scaling, and pane painting.
const std = @import("std");
const copy = @import("copy.zig");
const values = @import("../value.zig");
const geometry = @import("geometry.zig");
const text = @import("text.zig");
const canvas = @import("canvas.zig");
const palette = @import("palette.zig");
const Rect = geometry.Rect;
const SourceRect = geometry.SourceRect;
const Layout = geometry.Layout;
const Line = canvas.Line;
const Face = text.Face;
const textWidth = text.textWidth;
const outline_gray = palette.outline_gray;
const muted = palette.muted;
const tint = palette.tint;
const Pixel = values.Pixel;
const Image = values.Image;

/// Maps a rectangle of source pixels to a rectangle on the sheet.
pub const Crop = struct { from: SourceRect, to: Rect };

const Axis = enum { row, column };
const Direction = enum { lower, higher };

/// Maximum detail column width at the base UI scale.
pub const max_crop_w = 360;

const max_crop_h = 220;
const detail_inset_px = 3;
const detail_zoom_target_px = 120;
const base_context_px = 20;
const edge_trim_divisor = 32;
/// Maximum source-pixel extension to recover a cut line.
const context_search_px = 48;
const wide_crop_context_px = 24;
// Require a band of empty paint: a single blank column can be between letters.
const text_row_gap_px = 3;
const text_column_gap_px = 24;
// Words and list summaries can extend farther sideways than a line is tall.
const text_column_search_px = max_crop_w;

/// Plans a detail crop with context clipped to the source and slot.
pub fn crop(image: Image, box: ?SourceRect, x: usize, y: usize, slot: usize, ui: Layout) ?Crop {
    const region = box orelse return null;
    const from = cropBounds(image, region, ui);
    const inset = ui.px(detail_inset_px);
    const slot_w = slot - 2 * inset;
    const slot_h = ui.px(max_crop_h) - 2 * inset;
    const long = @max(region.w, region.h);
    const ideal_zoom = (ui.px(detail_zoom_target_px) + long - 1) / long;
    // Keep the recovered line intact even if this lowers the enlargement.
    const zoom = @min(ideal_zoom, slot_w / from.w, slot_h / from.h);
    const out_w = if (zoom > 1) from.w * zoom else @max(1, @min(from.w, slot_w, from.w * slot_h / from.h));
    const out_h = @min(slot_h, @max(1, @divFloor(from.h * out_w, from.w)));
    return .{
        .from = from,
        .to = .{ .x = x + inset, .y = y + inset, .w = out_w, .h = out_h },
    };
}

/// Draws the detail crop or its absent-side label on one row.
pub noinline fn drawDetail(line: Line, patch: ?Crop, image: Image, x: usize, slot: usize, top: usize, height: usize, kind: values.Kind, ui: Layout) void {
    if (patch) |p| {
        const border = ui.px(3);
        const rect = p.to.outset(border);
        if (!rect.containsRow(line.y)) return;
        paintCrop(line, p, image);
        line.stroke(rect, ui.px(8), border, tint(kind));
    } else {
        const rect: Rect = .{ .x = x, .y = top, .w = slot, .h = height };
        line.stroke(rect, ui.px(12), ui.px(2), outline_gray);
        const label = copy.not_on_side;
        const size = @max(1, @min(ui.px(text.caption_size), text.caption_size * (rect.w -| 8) / textWidth(.regular, text.caption_size, label)));
        line.text(x + (rect.w -| textWidth(.regular, size, label)) / 2, top + (height - Face.regular.height(size)) / 2, label, .regular, size, muted);
    }
}

/// Paints one row of a mapped crop without allocating pixels.
pub fn paintCrop(line: Line, patch: Crop, image: Image) void {
    if (!patch.to.containsRow(line.y)) return;
    const output = line.pixels[patch.to.x..][0..patch.to.w];
    cropRow(patch, image, line.y - patch.to.y, output);
}

fn cropRow(c: Crop, image: Image, y: usize, output: []Pixel) void {
    const first_y = c.from.y + y * c.from.h / c.to.h;
    if (c.from.w <= c.to.w and c.from.h <= c.to.h) {
        const source = image.row(first_y)[c.from.x..][0..c.from.w];
        if (source.len == output.len) {
            @memcpy(output, source);
        } else {
            for (output, 0..) |*pixel, x| pixel.* = source[x * source.len / output.len];
        }
        return;
    }
    const end_y = @max(first_y + 1, c.from.y + (y + 1) * c.from.h / c.to.h);
    var first_x = c.from.x;
    for (output, 0..) |*pixel, x| {
        const edge_x = c.from.x + (x + 1) * c.from.w / c.to.w;
        const end_x = @max(first_x + 1, edge_x);
        var totals: @Vector(4, u32) = @splat(0);
        for (first_y..end_y) |source_y| {
            for (image.row(source_y)[first_x..end_x]) |p| totals += @as(@Vector(4, u8), p);
        }
        const count: u32 = @intCast((end_x - first_x) * (end_y - first_y));
        pixel.* = @as(@Vector(4, u8), @intCast((totals + @as(@Vector(4, u32), @splat(count / 2))) / @as(@Vector(4, u32), @splat(count))));
        first_x = edge_x;
    }
}

// Snap to a nearby band of empty paint, extending first and trimming only
// when the band can be reached without crossing the edited rectangle.
fn growContext(image: Image, initial: SourceRect, edit: SourceRect, reach: usize, column_reach: usize) SourceRect {
    var grown = initial;
    setCropRows(image, &grown, initial, edit, reach);
    const left = backgroundEdge(.column, .lower, image, grown, initial.x, edit.x, column_reach);
    const right = backgroundEdge(.column, .higher, image, grown, initial.right() - 1, edit.right() - 1, column_reach) + 1;
    grown.x = left;
    grown.w = right - left;
    // A newly included column can contain ink on a previously clear edge.
    if (grown.x != initial.x or grown.w != initial.w) setCropRows(image, &grown, initial, edit, reach);
    return grown;
}

fn setCropRows(image: Image, crop_: *SourceRect, initial: SourceRect, edit: SourceRect, reach: usize) void {
    const top = backgroundEdge(.row, .lower, image, crop_.*, initial.y, edit.y, reach);
    const bottom = backgroundEdge(.row, .higher, image, crop_.*, initial.bottom() - 1, edit.bottom() - 1, reach) + 1;
    crop_.y = top;
    crop_.h = bottom - top;
}

// Share the search between all four edges of the crop.
noinline fn backgroundEdge(axis: Axis, direction: Direction, image: Image, cut: SourceRect, edge: usize, edit_edge: usize, reach: usize) usize {
    const extent = if (axis == .row) image.height else image.width;
    const gap: usize = if (axis == .row) text_row_gap_px else text_column_gap_px;
    const lower = direction == .lower;
    const available = if (lower) edge else extent - 1 - edge;
    for ([_]bool{ false, true }) |trim| {
        const limit = if (trim) (if (lower) edit_edge - edge else edge - edit_edge) else @min(reach, available);
        const backwards = lower != trim;
        var clear: usize = 0;
        for (0..limit + 1) |step| {
            const at = if (backwards) edge - step else edge + step;
            clear = if (uniformLine(axis, image, cut, at)) clear + 1 else 0;
            if (clear == gap) return if (backwards) at + gap - 1 else at - (gap - 1);
        }
        if (!trim and limit == available) return if (lower) 0 else extent - 1;
    }
    return edge;
}

fn uniformLine(axis: Axis, image: Image, cut: SourceRect, at: usize) bool {
    const count = if (axis == .row) cut.w else cut.h;
    const trim = @divFloor(count, edge_trim_divisor);
    const stride: usize = if (axis == .row) 1 else image.width;
    const start = if (axis == .row) at * image.width + cut.x + trim else (cut.y + trim) * image.width + at;
    const first = image.pixels[start];
    for (1..count - 2 * trim) |offset| {
        if (!std.meta.eql(first, image.pixels[start + offset * stride])) return false;
    }
    return true;
}

fn cropBounds(image: Image, box: SourceRect, ui: Layout) SourceRect {
    var from = box.outset(ui.px(base_context_px));
    from.w = @min(from.w, image.width - from.x);
    from.h = @min(from.h, image.height - from.y);
    // An edit already wider than its slot needs less surrounding paint. Skip a
    // nearby partial line before it makes the whole crop smaller to read.
    const search: usize = if (box.w >= ui.px(max_crop_w)) wide_crop_context_px else context_search_px;
    return growContext(image, from, box, ui.px(search), ui.px(text_column_search_px));
}

test "close-ups enlarge a tiny edit and average samples when shrinking" {
    const ink = palette.ink;
    const white = palette.white;
    const pixels = [_]Pixel{ ink, white, ink, white };
    const image: Image = .{ .width = 4, .height = 1, .pixels = &pixels };
    const ui = Layout.init(image.size(), image.size());
    const patch = crop(image, .{ .x = 1, .y = 0, .w = 1, .h = 1 }, 0, 0, ui.px(max_crop_w), ui).?;
    try std.testing.expect(patch.to.w / patch.from.w >= 80);
    try std.testing.expectEqual(patch.to.w / patch.from.w, patch.to.h / patch.from.h);

    const down: Crop = .{ .from = .{ .x = 0, .y = 0, .w = 4, .h = 1 }, .to = .{ .x = 0, .y = 0, .w = 2, .h = 1 } };
    var output: [2]Pixel = undefined;
    cropRow(down, image, 0, &output);
    try std.testing.expectEqualSlices(Pixel, &.{ .{ 140, 140, 141, 255 }, .{ 140, 140, 141, 255 } }, &output);
}

test "close-up bounds extend outward to nearby blank rows" {
    const ink = palette.ink;
    const white = palette.white;
    var pixels: [52 * 96]Pixel = @splat(white);
    for (10..21) |y| pixels[y * 52 + 20] = ink;
    for (64..73) |y| pixels[y * 52 + 20] = ink;
    const image: Image = .{ .width = 52, .height = 96, .pixels = &pixels };
    const ui = Layout.init(image.size(), image.size());
    const cut = cropBounds(image, .{ .x = 18, .y = 38, .w = 12, .h = 8 }, ui);
    try std.testing.expectEqual(@as(usize, 9), cut.y);
    try std.testing.expectEqual(@as(usize, 74), cut.y + cut.h);
}
test "a narrow close-up keeps the complete labels above and beside an edit" {
    const width = 140;
    const height = 110;
    var pixels: [width * height]Pixel = @splat(palette.white);
    // The nominal crop starts inside the first line and cuts the label on the right.
    for (23..35) |y| @memset(pixels[y * width + 53 ..][0..24], palette.ink);
    for (48..56) |y| @memset(pixels[y * width + 68 ..][0..27], palette.ink);
    const image: Image = .{ .width = width, .height = height, .pixels = &pixels };
    const ui = Layout.init(image.size(), image.size());
    const patch = crop(image, .{ .x = 62, .y = 50, .w = 6, .h = 5 }, 0, 0, ui.px(90), ui).?;
    try std.testing.expect(patch.from.y < 23);
    try std.testing.expect(patch.from.right() > 95);
}

test "detail crop clips the height of a one-pixel-wide source" {
    const height = max_crop_h * 2;
    const pixels: [height]Pixel = @splat(palette.white);
    const image: Image = .{ .width = 1, .height = height, .pixels = &pixels };
    const ui = Layout.init(image.size(), image.size());
    const patch = crop(image, .{ .x = 0, .y = 0, .w = 1, .h = height }, 0, 0, ui.px(max_crop_w), ui).?;
    try std.testing.expectEqual(@as(usize, 1), patch.to.w);
    try std.testing.expectEqual(ui.px(max_crop_h) - 2 * ui.px(detail_inset_px), patch.to.h);
}

test "close-up edges do not stop in a gap between characters" {
    const width = 160;
    const height = 110;
    var pixels: [width * height]Pixel = @splat(palette.white);
    for (20..33) |y| {
        for ([_]usize{ 36, 43, 50, 57, 64, 71 }) |x| @memset(pixels[y * width + x ..][0..5], palette.ink);
    }
    const image: Image = .{ .width = width, .height = height, .pixels = &pixels };
    const initial: SourceRect = .{ .x = 55, .y = 27, .w = 50, .h = 50 };
    const edit: SourceRect = .{ .x = 75, .y = 48, .w = 12, .h = 8 };
    const result = growContext(image, initial, edit, context_search_px, text_column_search_px);
    try std.testing.expect(result.x < 36);
    try std.testing.expect(result.y < 20);
}

test "close-up trims an unattainable text edge while retaining the edit" {
    const width = 120;
    const height = 180;
    var pixels: [width * height]Pixel = @splat(palette.white);
    // The leading edge starts in ink whose start is beyond the outward reach.
    for (0..64) |y| pixels[y * width + width / 2] = palette.ink;
    const image: Image = .{ .width = width, .height = height, .pixels = &pixels };
    const initial: SourceRect = .{ .x = 20, .y = 27, .w = 60, .h = 95 };
    const edit: SourceRect = .{ .x = 40, .y = 80, .w = 20, .h = 8 };
    const result = growContext(image, initial, edit, 12, 12);
    try std.testing.expectEqual(@as(usize, 64), result.y);
    try std.testing.expect(result.y <= edit.y);
    try std.testing.expect(result.bottom() >= edit.bottom());
}

test "a wide close-up keeps a neighbouring partial line out of its context" {
    const width = 560;
    const height = 220;
    var pixels: [width * height]Pixel = @splat(palette.white);
    for (113..153) |y| pixels[y * width + 180] = palette.ink;
    const image: Image = .{ .width = width, .height = height, .pixels = &pixels };
    const ui: Layout = .{ .wide = false, .percent = 100, .numerator = 1, .denominator = 1 };
    const edit: SourceRect = .{ .x = 30, .y = 50, .w = 380, .h = 50 };
    const patch = crop(image, edit, 0, 0, max_crop_w, ui).?;
    try std.testing.expect(patch.from.bottom() >= edit.bottom());
    try std.testing.expect(patch.from.bottom() <= 113);
    try std.testing.expect(patch.to.w <= max_crop_w);
}
