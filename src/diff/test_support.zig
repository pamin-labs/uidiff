//! Procedural canvases and painter patterns for diff tests.
const std = @import("std");
/// Pixel, geometry and region values used by the scenario fixtures.
pub const values = @import("../value.zig");
const regions = @import("regions.zig");
const engine = @import("compare.zig");
const row_alignment = @import("rows.zig");
const pixel_ops = @import("pixel.zig");
const Image = values.Image;
const Pixel = values.Pixel;

/// The row alignment edit budget.
pub const max_edits = row_alignment.max_edits;
/// The region support threshold used by the scenarios.
pub const min_region_pixels = regions.min_region_pixels;
/// The initial grouping gap.
pub const merge_gap = regions.merge_gap;
/// Exact equality of two runs of pixels.
pub const sameRun = pixel_ops.sameRun;

const test_allocator = std.testing.allocator;

/// A procedurally painted image owned by the test allocator.
pub const Canvas = struct {
    view: Image,
    pixels: []Pixel,

    /// Allocates a blank procedural image.
    pub fn init(width: usize, height: usize) !Canvas {
        const pixels = try test_allocator.alloc(Pixel, width * height);
        @memset(pixels, .{ 255, 255, 255, 255 });
        return .{ .view = .{ .width = width, .height = height, .pixels = pixels }, .pixels = pixels };
    }

    /// Releases the pixel buffer.
    pub fn deinit(self: Canvas) void {
        test_allocator.free(self.pixels);
    }

    /// Allocates the default square used by small tests.
    pub fn square() !Canvas {
        return init(64, 64);
    }

    /// Borrows a writable row of painted pixels.
    pub fn row(self: Canvas, y: usize) []Pixel {
        return self.pixels[y * self.view.width ..][0..self.view.width];
    }

    /// Copies a source interval into this image.
    pub fn copyRows(self: Canvas, dest: usize, from: Canvas, first: usize, end: usize) void {
        const w = self.view.width;
        @memcpy(self.pixels[dest * w ..][0 .. (end - first) * w], from.pixels[first * w .. end * w]);
    }

    /// Copies part of each row into the corresponding destination columns.
    pub fn copyColumns(self: Canvas, from: Canvas, left: usize, right: usize, first: usize, end: usize, dest: usize) void {
        for (first..end, dest..) |old_y, new_y| @memcpy(self.row(new_y)[left..right], from.row(old_y)[left..right]);
    }

    /// Paints repeated lines with distinct procedural strokes.
    pub fn text(self: Canvas, left: usize, right: usize, first: usize, seed: usize, ink: u8) void {
        var y = first;
        var row_seed = seed;
        while (y + 9 <= self.view.height) : ({
            y += 14;
            row_seed += 1;
        }) {
            self.line(left, right, y, row_seed, ink);
        }
    }

    /// Paints one line of procedural text.
    pub fn line(self: Canvas, left: usize, right: usize, y: usize, seed: usize, ink: u8) void {
        var x = left + seed * 5 % 7;
        var glyph: usize = 0;
        while (x + 8 < right) : ({
            x += 9;
            glyph += 1;
        }) {
            if ((seed + glyph) % 6 == 5) continue;
            const shape = seed * 3 + glyph * 7 + seed / 3;
            const stem = 1 + shape % 4;
            for (0..9) |stroke_y| {
                self.row(y + stroke_y)[x + stem - 1 ..][0..4].* =
                    .{ inkShade(ink, 1), inkShade(ink, 4), inkShade(ink, 4), inkShade(ink, 2) };
            }
            self.fill(x, y + shape % 7, 6, 1, inkShade(ink, 4));
        }
    }

    /// Paints a glyph at a fractional sample phase.
    pub fn coverageGlyph(self: Canvas, phase: i32) void {
        const samples = 8;
        const area = samples * samples;
        // Coordinates use half a sample so each point is at a cell centre.
        for (14..34) |y| {
            for (25..44) |x| {
                var covered: u32 = 0;
                for (0..samples) |sy| {
                    const dy = @as(i32, @intCast(2 * (y * samples + sy) + 1)) - 24 * 16;
                    for (0..samples) |sx| {
                        const dx = @as(i32, @intCast(2 * (x * samples + sx) + 1)) - 34 * 16 - 2 * phase;
                        const stem = @abs(8 * dx + 3 * dy) < 64 and @abs(dy) < 144;
                        const bar = @abs(dy - 4 * 16) <= 10 and @abs(dx) < 112;
                        covered += @intFromBool(stem or bar);
                    }
                }
                var pixel: Pixel = .{ 24, 26, 29, 255 };
                for (pixel[0..3]) |*channel| channel.* += @intCast(((180 - @as(u32, channel.*)) * covered + area / 2) / area);
                self.row(y)[x] = pixel;
            }
        }
    }

    /// Replaces the red channel in a rectangle.
    pub fn red(self: Canvas, x: usize, y: usize, w: usize, h: usize, value: u8) void {
        for (y..y + h) |j| for (self.row(j)[x..][0..w]) |*pixel| {
            pixel[0] = value;
        };
    }

    /// Paints the default small changed block.
    pub fn block(self: Canvas, x: usize, y: usize) void {
        self.red(x, y, block_size, block_size, 0);
    }

    /// Fills a rectangle with a single RGBA colour.
    pub fn fill(self: Canvas, x: usize, y: usize, w: usize, h: usize, color: Pixel) void {
        for (y..y + h) |j| @memset(self.row(j)[x..][0..w], color);
    }

    /// Allocates a copy with added rows.
    pub fn insert(self: Canvas, y: usize, rows: usize, growth: usize) !Canvas {
        const after = try init(self.view.width, self.view.height + growth);
        after.copyRows(0, self, 0, y);
        after.copyRows(y + rows, self, y, after.view.height - rows);
        return after;
    }
};

/// A blank pair for exchanging adjacent rows with independent source pixels.
pub const RowExchange = struct {
    before: Canvas,
    after: Canvas,

    /// First of the two row bands.
    pub const upper = 40;
    /// Height and displacement of the exchanged bands.
    pub const pitch = 40;

    /// Allocates both canvases at the same size.
    pub fn init() !RowExchange {
        const before = try Canvas.init(256, 160);
        errdefer before.deinit();
        return .{ .before = before, .after = try Canvas.init(before.view.width, before.view.height) };
    }

    /// Releases both canvases.
    pub fn deinit(self: RowExchange) void {
        self.before.deinit();
        self.after.deinit();
    }

    /// Copies the two source bands to swapped positions.
    pub fn exchange(self: RowExchange) void {
        self.after.copyRows(upper, self.before, upper + pitch, upper + pitch * 2);
        self.after.copyRows(upper + pitch, self.before, upper, upper + pitch);
    }
};

/// Side length of a block large enough to report under the default mask.
pub const block_size = std.math.sqrt(regions.min_region_pixels);
/// Computes a coverage sample over white paper.
pub fn inkShade(ink: u8, coverage: u16) Pixel {
    const tone: u8 = @intCast(255 - @as(u16, 255 - ink) * coverage / 4);
    return .{ tone, tone, tone, 255 };
}

/// Builds a procedural regression pattern.
pub fn diagonal(shift: usize) !Canvas {
    const png = try Canvas.square();
    const samples = 8;
    for (0..png.view.height) |y| {
        for (png.row(y), 0..) |*pixel, x| {
            var covered: usize = 0;
            for (0..samples) |sy| {
                for (0..samples) |sx| {
                    // Distance in units of 1/(4*samples).
                    const distance = (int(x) - 8 - int(shift)) * 4 * samples +
                        2 * (2 * int(sx) + 1) - int(y) * 2 * samples - (2 * int(sy) + 1);
                    if (@abs(distance) < 6 * samples) covered += 1;
                }
            }
            const grey: u8 = @intCast((255 * (samples * samples - covered) + samples * samples / 2) / (samples * samples));
            pixel.* = .{ grey, grey, grey, 255 };
        }
    }
    return png;
}

/// Builds a procedural regression pattern.
pub fn int(n: usize) isize {
    return @intCast(n);
}

/// Builds a procedural regression pattern.
pub fn paintBands(canvas: Canvas, x: usize, width: usize) void {
    var top: usize = 0;
    while (top + 7 <= canvas.view.height) : (top += 7) {
        const band = top / 7;
        canvas.red(x + ((band * 7) % (width - 6)), top, 6, 5, @intCast(band % 200));
    }
}

/// Builds a procedural regression pattern.
pub fn auditPage(canvas: Canvas, chrome: bool, insertion: ?usize, deletion: ?usize, rows_count: usize) void {
    @memset(canvas.pixels, inkShade(255, 4));
    const height = canvas.view.height;
    var y: usize = if (chrome) 44 else 8;
    for (0..25) |i| {
        if (insertion == i) {
            const bottom = @min(height, y + 18 * rows_count - 3);
            if (y < bottom) canvas.fill(8, y, 225, bottom - y, .{ 60, 140, 90, 255 });
            y += 18 * rows_count;
        }
        if (deletion) |start| if (i >= start and i < start + rows_count) continue;
        if (y + 9 <= height) canvas.line(8, 58, y, i * 7, 30);
        y += 18;
    }
    if (chrome) {
        canvas.fill(0, 0, 240, 41, .{ 220, 220, 235, 255 });
        canvas.fill(0, height - 50, 240, 50, .{ 235, 225, 220, 255 });
        canvas.fill(20, height - 40, 61, 21, .{ 50, 50, 200, 255 });
    }
}

/// Builds a procedural regression pattern.
pub fn fillCardList(canvas: Canvas, inserted: ?usize) void {
    for (0..13) |index| {
        const content = if (inserted) |at| if (index == at) 90 else index - @intFromBool(index > at) else index;
        paintCard(canvas, 190, 14 + 40 * index, 401, 33, content);
    }
}

/// Builds a procedural regression pattern.
pub fn paintCard(canvas: Canvas, x: usize, y: usize, width: usize, height: usize, seed: usize) void {
    const edge: Pixel = .{ 180, 183, 189, 255 };
    const visible = @min(height, canvas.view.height - y);
    canvas.fill(x, y, width, 1, edge);
    if (visible == height) canvas.fill(x, y + height - 1, width, 1, edge);
    canvas.fill(x, y, 1, visible, edge);
    canvas.fill(x + width - 1, y, 1, visible, edge);
    if (visible >= 17) canvas.line(x + 12, x + 86, y + 8, seed, 40);
}

/// Builds a procedural regression pattern.
pub fn strokeRounded(canvas: Canvas, top: usize, radius: usize) void {
    const left = 220;
    const width = 540;
    const height = 200;
    const stroke = 2;
    for (0..height) |y| for (0..width) |x| {
        if (!insideRounded(x, y, width, height, radius)) continue;
        if (x >= stroke and x < width - stroke and y >= stroke and y < height - stroke and
            insideRounded(x - stroke, y - stroke, width - 2 * stroke, height - 2 * stroke, radius - stroke)) continue;
        canvas.row(top + y)[left + x] = .{ 100, 100, 105, 255 };
    };
}

/// Checks that a reported region of the requested kind covers a test point.
pub fn hasRegion(found: []const values.Region, side: values.Side, x: usize, y: usize, kind: ?values.Kind) bool {
    const px: f64 = @floatFromInt(x);
    const py: f64 = @floatFromInt(y);
    for (found) |region| {
        if (kind != null and kind != region.kind) continue;
        const box = (if (side == .before) region.before else region.after) orelse continue;
        if (box.x <= px and box.right() > px and box.y <= py and box.bottom() > py) return true;
    }
    return false;
}

/// Finds a two-sided mark that excludes the body of a nearby edit.
pub fn hasSeparateMark(found: []const values.Region, x: usize, y: usize, body_x: usize, body_y: usize) bool {
    if (!hasRegion(found, .after, body_x, body_y, null)) return false;
    for (found, 0..) |_, index| {
        const mark = found[index..][0..1];
        if (hasRegion(mark, .before, x, y, null) and hasRegion(mark, .after, x, y, null) and
            !hasRegion(mark, .after, body_x, body_y, null)) return true;
    }
    return false;
}

/// Adds the normal report padding to an expected test box.
pub fn paddedBox(x: usize, y: usize, w: usize, h: usize) values.Box {
    const region_padding = regions.padding.count();
    return values.Box.fromPixels(x - region_padding, y - region_padding, w + 2 * region_padding, h + 2 * region_padding);
}

/// Checks region geometry, kind and report numbering in order.
pub fn checkRegions(actual: []const values.Region, expected: []const values.Region) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (actual, expected, 1..) |got, want, number| {
        try std.testing.expectEqual(want.before, got.before);
        try std.testing.expectEqual(want.after, got.after);
        try std.testing.expectEqual(number, got.number);
        try std.testing.expectEqual(if (want.before == null) values.Kind.inserted else if (want.after == null) values.Kind.removed else values.Kind.changed, got.kind);
    }
}

/// Checks that an edit is reported within the expected width.
pub fn expectEditAt(before: Canvas, after: Canvas, x: usize, y: usize, max_box_width: usize) !void {
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    for (result.regions) |region| {
        const box = region.after orelse continue;
        if (box.x <= @as(f64, @floatFromInt(x)) and box.right() > @as(f64, @floatFromInt(x)) and
            box.y <= @as(f64, @floatFromInt(y)) and box.bottom() > @as(f64, @floatFromInt(y)))
        {
            try std.testing.expect(box.width <= @as(f64, @floatFromInt(max_box_width)));
            return;
        }
    }
    return error.MissingEdit;
}

/// Compares two procedural canvases at the supplied scale.
pub fn compareCanvases(before: Canvas, after: Canvas, scale: f64) !engine.Comparison {
    return engine.compare(std.testing.allocator, before.view, after.view, .{ .scale = .{ .factor = scale } });
}

/// Checks all reported regions against the expected boxes.
pub fn check(before: Canvas, after: Canvas, scale: f64, expected: []const values.Region) !void {
    const actual = try compareCanvases(before, after, scale);
    defer actual.deinit(std.testing.allocator);
    try checkRegions(actual.regions, expected);
}

/// Checks an insertion and its matching deletion when reversed.
pub fn checkInsertion(before: Canvas, after: Canvas, expected: values.Box) !void {
    try check(before, after, 1, &.{.{ .after = expected }});
    try check(after, before, 1, &.{.{ .before = expected }});
}

/// Checks the number of reported regions.
pub fn count(before: Canvas, after: Canvas, expected: usize) !void {
    const actual = try compareCanvases(before, after, 1);
    defer actual.deinit(std.testing.allocator);
    try std.testing.expectEqual(expected, actual.regions.len);
}

fn insideRounded(x: usize, y: usize, width: usize, height: usize, radius: usize) bool {
    const dx = radius -| @min(x, width - 1 - x);
    const dy = radius -| @min(y, height - 1 - y);
    return dx * dx + dy * dy <= radius * radius;
}

test {
    std.testing.refAllDecls(@This());
}
