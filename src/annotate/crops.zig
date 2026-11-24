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
const Pane = geometry.Pane;
const paneRect = geometry.paneRect;
const Line = canvas.Line;
const Face = text.Face;
const roundSpan = canvas.roundSpan;
const textWidth = text.textWidth;
const page = palette.page;
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
const base_context_px = 20;
const edge_trim_divisor = 32;
/// Maximum source-pixel extension to recover a cut line.
const context_search_px = 24;

/// Plans a detail crop with context clipped to the source and slot.
pub fn crop(image: Image, box: ?SourceRect, x: usize, y: usize, slot: usize, ui: Layout) ?Crop {
    const region = box orelse return null;
    const from = cropBounds(image, region, ui);
    const inset = ui.px(3);
    const slot_w = slot - 2 * inset;
    const slot_h = ui.px(max_crop_h) - 2 * inset;
    const long = @max(region.w, region.h);
    const ideal_zoom = (ui.px(120) + long - 1) / long;
    // Keep the recovered line intact even if this lowers the enlargement.
    const zoom = @min(ideal_zoom, slot_w / from.w, slot_h / from.h);
    const out_w = if (zoom > 1) from.w * zoom else @max(1, @min(from.w, slot_w, from.w * slot_h / from.h));
    const out_h = @max(1, @divFloor(from.h * out_w, from.w));
    return .{
        .from = from,
        .to = .{ .x = x + inset, .y = y + inset, .w = out_w, .h = out_h },
    };
}

/// Copies the visible preview pixels for one row.
pub noinline fn drawPane(line: Line, pane: Pane, x: usize, y: usize, ui: Layout) void {
    const rect = paneRect(x, y, pane.dimensions);
    const radius = ui.px(16);
    const shades = [_]Pixel{ .{ 241, 241, 242, 255 }, .{ 237, 237, 238, 255 }, .{ 232, 232, 234, 255 } };
    if (line.y >= y + radius + ui.px(5) and line.y + radius + ui.px(5) < y + rect.h) {
        const right = x + rect.w;
        var outer = ui.px(8);
        for ([_]usize{ 5, 2, 0 }, shades) |inset, tone| {
            const inner = ui.px(inset);
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
        var shadow = rect.outset(ui.px(spread));
        shadow.y += ui.px(4);
        if (roundSpan(shadow, radius + ui.px(spread), line.y)) |span| {
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

/// Extends a valid source crop to the first uniform line on each edge.
fn growContext(image: Image, crop_: SourceRect, reach_px: usize) SourceRect {
    var grown = crop_;
    const top = backgroundEdge(.row, .lower, image, grown, grown.y, reach_px);
    const bottom = backgroundEdge(.row, .higher, image, grown, grown.bottom() - 1, reach_px) + 1;
    grown.y = top;
    grown.h = bottom - top;
    const left = backgroundEdge(.column, .lower, image, grown, grown.x, reach_px);
    const right = backgroundEdge(.column, .higher, image, grown, grown.right() - 1, reach_px) + 1;
    grown.x = left;
    grown.w = right - left;
    return grown;
}

noinline fn backgroundEdge(axis: Axis, direction: Direction, image: Image, cut: SourceRect, near_px: usize, reach_px: usize) usize {
    const extent = if (axis == .row) image.height else image.width;
    const available = if (direction == .lower) near_px else extent - 1 - near_px;
    const end = @min(reach_px, available);
    for (0..end + 1) |step| {
        const at = if (direction == .lower) near_px - step else near_px + step;
        if (uniformLine(axis, image, cut, at)) return at;
    }
    // Only grow when an edge is actually found.
    return near_px;
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
    return growContext(image, from, ui.px(context_search_px));
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
