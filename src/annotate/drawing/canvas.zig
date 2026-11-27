//! Rasterizes paint and bitmap text one sheet row at a time.
const std = @import("std");
const value = @import("../../value.zig");
const geometry = @import("../geometry.zig");
const text = @import("text.zig");
const Rect = geometry.Rect;
const Pixel = value.Pixel;
const Face = text.Face;
const glyph = text.glyph;

/// A row being drawn and its absolute sheet coordinate.
pub const Line = struct {
    pixels: []Pixel,
    y: usize,

    /// Paints a span clipped to this row.
    pub fn fill(self: Line, first: usize, last: usize, color: Pixel) void {
        const a = @min(first, self.pixels.len);
        const b = @min(last, self.pixels.len);
        if (a < b) @memset(self.pixels[a..b], color);
    }

    /// Paints one row of a rounded rectangle.
    pub fn rounded(self: Line, rect: Rect, radius: usize, color: Pixel) void {
        const span = roundSpan(rect, radius, self.y) orelse return;
        self.fill(span[0], span[1], color);
    }

    /// Paints one row of a rounded outline.
    pub fn stroke(self: Line, rect: Rect, radius: usize, thickness: usize, color: Pixel) void {
        const outer = roundSpan(rect, radius, self.y) orelse return;
        if (roundSpan(rect.inset(thickness), radius -| thickness, self.y)) |inner| {
            self.fill(outer[0], inner[0], color);
            self.fill(inner[1], outer[1], color);
        } else self.fill(outer[0], outer[1], color);
    }

    /// Paints the visible part of a sheet label on this row.
    pub noinline fn text(self: Line, x: usize, top: usize, label: []const u8, face: Face, size: usize, color: Pixel) void {
        if (self.y < top or self.y - top >= face.height(size)) return;
        const em = face.em();
        const gy = (self.y - top) * em / size;
        var left = x;
        for (label) |c| {
            const g = glyph(face, c);
            if (gy >= g[2] and gy - g[2] < g[4]) {
                self.glyphRow(g, gy - g[2], .scaled, left, size, em, .{ 0, self.pixels.len }, color);
            }
            left += (g[0] * size + em / 2) / em;
        }
    }

    /// Draws centered badge digits clipped to the badge's circle.
    pub fn badgeText(self: Line, inner: Rect, number: []const u8, color: Pixel) void {
        if (number.len == 0) return;
        const em = Face.bold.em();
        var ink_width = 2 * (number.len - 1);
        var ink_height: usize = 0;
        for (number) |digit| {
            const g = glyph(.bold, digit);
            ink_width += g[3];
            ink_height = @max(ink_height, g[4]);
        }
        const size = @min(em, (inner.width -| 4) * em / ink_width);
        if (size == 0) return;
        const height = @max(1, ink_height * size / em);
        const top = inner.y + (inner.height - height) / 2;
        if (self.y < top or self.y - top >= height) return;
        const span = roundSpan(inner, inner.width / 2, self.y) orelse return;
        const start = inner.x + (inner.width - ink_width * size / em) / 2;
        var pen: usize = 0;
        for (number) |digit| {
            const g = glyph(.bold, digit);
            const first = start + pen * size / em;
            const end = start + (pen + g[3]) * size / em;
            pen += @as(usize, g[3]) + 2;
            const glyph_h = @max(1, @as(usize, g[4]) * size / em);
            const baseline = top + height;
            if (self.y < baseline - glyph_h or first == end) continue;
            const gy = (self.y - (baseline - glyph_h)) * g[4] / glyph_h;
            self.glyphRow(g, gy, .fitted, first, end - first, g[3], span, color);
        }
    }

    // Scaled captions retain atlas bearings. Fitted digits use the rounded
    // glyph endpoints as their destination range.
    fn glyphRow(self: Line, g: []const u8, gy: usize, comptime mapping: enum { scaled, fitted }, origin: usize, width: usize, denominator: usize, clip: [2]usize, color: Pixel) void {
        for (0..g[3]) |gx| {
            const sample = gy * g[3] + gx;
            const packed_ = g[5 + sample / 2];
            const alpha: u16 = if (sample % 2 == 0) packed_ & 15 else packed_ >> 4;
            if (alpha == 0) continue;
            const bearing: usize = if (mapping == .scaled) g[1] else 0;
            const rounding: usize = if (mapping == .fitted) denominator - 1 else 0;
            const first = @max(clip[0], origin + ((bearing + gx) * width + rounding) / denominator);
            const end = @min(clip[1], self.pixels.len, origin + ((bearing + gx + 1) * width + rounding) / denominator);
            if (first >= end) continue;
            for (self.pixels[first..end]) |*pixel| {
                inline for (0..3) |k| pixel[k] = @intCast((@as(u16, pixel[k]) * (15 - alpha) + @as(u16, color[k]) * alpha + 7) / 15);
                pixel[3] = 255;
            }
        }
    }
};

/// Finds the covered sheet columns of a rounded rectangle on one row.
pub noinline fn roundSpan(rect: Rect, radius: usize, y: usize) ?[2]usize {
    if (!rect.containsRow(y) or rect.width == 0) return null;
    const r = @min(radius, rect.width / 2, rect.height / 2);
    const distance = @min(y - rect.y, rect.y + rect.height - 1 - y);
    const dy = r -| distance;
    const cut = if (dy == 0) 0 else r - @as(usize, @intFromFloat(@sqrt(@as(f64, @floatFromInt(r * r - dy * dy)))));
    return .{ rect.x + cut, rect.x + rect.width - cut };
}

test {
    std.testing.refAllDecls(@This());
}
