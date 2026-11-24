//! Bitmap text and row drawing primitives.
const std = @import("std");
const values = @import("../value.zig");
const geometry = @import("geometry.zig");
const Rect = geometry.Rect;
const Pixel = values.Pixel;

/// An embedded glyph atlas and its metrics.
pub const Face = enum {
    regular,
    bold,

    /// Returns the row height for the requested font size.
    pub fn height(self: Face, size: usize) usize {
        return ((if (self == .bold) @as(usize, 44) else 32) * size + self.em() - 1) / self.em();
    }

    fn em(self: Face) usize {
        return if (self == .bold) 34 else 24;
    }
};

/// A formatted report label stored without heap allocation.
pub const Text = struct {
    data: [96]u8 = undefined,
    len: usize = 0,

    /// Formats a label or reports that it exceeds the inline buffer.
    pub fn format(comptime template: []const u8, args: anytype) error{SheetTooLarge}!Text {
        var result: Text = .{};
        result.len = (std.fmt.bufPrint(&result.data, template, args) catch return error.SheetTooLarge).len;
        return result;
    }

    /// Borrows the formatted label.
    pub fn bytes(self: *const Text) []const u8 {
        return self.data[0..self.len];
    }
};

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

    /// Paints the visible part of a report label on this row.
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
        const size = @min(em, (inner.w -| 4) * em / ink_width);
        if (size == 0) return;
        const height = @max(1, ink_height * size / em);
        const top = inner.y + (inner.h - height) / 2;
        if (self.y < top or self.y - top >= height) return;
        const span = roundSpan(inner, inner.w / 2, self.y) orelse return;
        const start = inner.x + (inner.w - ink_width * size / em) / 2;
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

const font_index_bytes = 2 * 95;

const ascii = @embedFile("font-ascii.bin");

/// Finds the covered sheet columns of a rounded rectangle on one row.
pub noinline fn roundSpan(rect: Rect, radius: usize, y: usize) ?[2]usize {
    if (!rect.containsRow(y) or rect.w == 0) return null;
    const r = @min(radius, rect.w / 2, rect.h / 2);
    const distance = @min(y - rect.y, rect.y + rect.h - 1 - y);
    const dy = r -| distance;
    const cut = if (dy == 0) 0 else r - @as(usize, @intFromFloat(@sqrt(@as(f64, @floatFromInt(r * r - dy * dy)))));
    return .{ rect.x + cut, rect.x + rect.w - cut };
}

/// Measures a report label at the requested font size.
pub fn textWidth(face: Face, size: usize, label: []const u8) usize {
    const em = face.em();
    var width: usize = 0;
    for (label) |c| width += (glyph(face, c)[0] * size + em / 2) / em;
    return width;
}

fn glyph(face: Face, c: u8) []const u8 {
    return findGlyph(face, c) orelse @panic("report label uses a glyph missing from the atlas");
}

fn findGlyph(face: Face, c: u8) ?[]const u8 {
    if (c < 32 or c > 126) return null;
    const regular_bytes = std.mem.readInt(u16, ascii[0..2], .little);
    const table = if (face == .bold) ascii[2 + @as(usize, regular_bytes) ..] else ascii[2..][0..regular_bytes];
    const index = @as(usize, c) - 32;
    const fallback = std.mem.readInt(u16, table[2 * ('?' - 32) ..][0..2], .little);
    const offset = std.mem.readInt(u16, table[2 * index ..][0..2], .little);
    if (offset == fallback and c != '?') return null;
    const found = table[font_index_bytes + @as(usize, offset) ..];
    return found[0 .. 5 + (@as(usize, found[3]) * found[4] + 1) / 2];
}

test "every report label can be rendered by its assigned face" {
    const copy = @import("copy.zig");
    const palette = @import("palette.zig");
    const fg = std.fmt.comptimePrint;
    const digits = "0123456789";
    const regular = [_][]const u8{
        palette.kindName(.changed), palette.kindName(.inserted),                       palette.kindName(.removed),
        copy.not_on_side,           copy.before,                                       copy.after,
        digits,                     fg(copy.focus_format, .{ copy.before, 123, 456 }), fg(copy.scaled_focus_format, .{ copy.after, 1, 2, 50 }),
    };
    const bold = [_][]const u8{
        copy.before,                          copy.after,                   copy.moved,                                   copy.changes_up_close,                         copy.at_full_size,                                                            digits,
        fg(copy.positive_shift_format, .{3}), fg(copy.shift_format, .{-2}), fg(copy.heading_format, .{ 1, copy.change }), fg(copy.heading_format, .{ 2, copy.changes }), fg(copy.moved_heading_format, .{ 1, copy.change, 1, copy.block, copy.down }), fg(copy.moved_heading_format, .{ 2, copy.changes, 2, copy.blocks, copy.up }),
    };
    for (regular) |label| for (label) |c| try std.testing.expect(findGlyph(.regular, c) != null);
    for (bold) |label| for (label) |c| try std.testing.expect(findGlyph(.bold, c) != null);
    try std.testing.expectEqual(@as(?[]const u8, null), findGlyph(.regular, '~'));
}

test "badge digits preserve native bold bitmap coverage" {
    const badges = @import("badges.zig");
    const palette = @import("palette.zig");
    const page = palette.page;
    const ui = geometry.Layout.init(.{ .width = 900, .height = 12 }, .{ .width = 900, .height = 12 });
    const diameter = badges.overviewDiameter(ui);
    const bounds: Rect = .{ .x = 0, .y = 0, .w = diameter, .h = diameter };
    const storage = try std.testing.allocator.alloc(Pixel, diameter);
    defer std.testing.allocator.free(storage);
    const base = palette.tint(.changed);
    for ("0123456789") |digit| {
        const g = glyph(.bold, digit);
        const x = (diameter - g[3]) / 2;
        const y = (diameter - g[4]) / 2;
        for (0..g[4]) |gy| {
            @memset(storage, page);
            badges.badge(.{ .pixels = storage, .y = y + gy }, bounds, .changed, &.{digit}, ui);
            for (0..g[3]) |gx| {
                const sample = gy * g[3] + gx;
                const packed_ = g[5 + sample / 2];
                const alpha: u16 = if (sample % 2 == 0) packed_ & 15 else packed_ >> 4;
                for (0..3) |channel| {
                    const expected: u8 = @intCast((@as(u16, base[channel]) * (15 - alpha) + 255 * alpha + 7) / 15);
                    try std.testing.expectEqual(expected, storage[x + gx][channel]);
                }
            }
        }
    }
}
