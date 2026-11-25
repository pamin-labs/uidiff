//! Bitmap glyphs, typographic metrics, and formatted report labels.
const std = @import("std");

/// An embedded glyph atlas and its metrics.
pub const Face = enum {
    regular,
    bold,

    /// Returns the row height for the requested font size.
    pub fn height(self: Face, size: usize) usize {
        return ((if (self == .bold) @as(usize, bold_height) else regular_height) * size + self.em() - 1) / self.em();
    }

    /// The rasterized font's native size.
    pub fn em(self: Face) usize {
        return if (self == .bold) bold_em else regular_em;
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

const regular_em = 24;
const regular_height = 32;
const bold_em = 34;
const bold_height = 44;
const ascii_first = 32;
const ascii_last = 126;
const font_index_bytes = 2 * (ascii_last - ascii_first + 1);

/// Body size for focus captions and absent-side notices.
pub const caption_size = 22;
/// Inline space around a caption when reserving its badge obstacle.
pub const caption_padding = 12;

const ascii = @embedFile("font-ascii.bin");
const atlas_header_bytes = @sizeOf(u16);
const regular_bytes = @as(usize, std.mem.readInt(u16, ascii[0..atlas_header_bytes], .little));
const regular_atlas = ascii[atlas_header_bytes..][0..regular_bytes];
const bold_atlas = ascii[atlas_header_bytes + regular_bytes ..];
const fallback_index = @sizeOf(u16) * ('?' - ascii_first);
const regular_fallback = std.mem.readInt(u16, regular_atlas[fallback_index..][0..@sizeOf(u16)], .little);
const bold_fallback = std.mem.readInt(u16, bold_atlas[fallback_index..][0..@sizeOf(u16)], .little);

/// Measures a report label at the requested font size.
pub fn textWidth(face: Face, size: usize, label: []const u8) usize {
    const em = face.em();
    var width: usize = 0;
    for (label) |c| width += (glyph(face, c)[0] * size + em / 2) / em;
    return width;
}

/// Borrows the metrics and packed coverage for a built-in report glyph.
pub fn glyph(face: Face, c: u8) []const u8 {
    return findGlyph(face, c) orelse @panic("report label uses a glyph missing from the atlas");
}

fn findGlyph(face: Face, c: u8) ?[]const u8 {
    if (c < ascii_first or c > ascii_last) return null;
    const table = if (face == .bold) bold_atlas else regular_atlas;
    const fallback = if (face == .bold) bold_fallback else regular_fallback;
    const index = @as(usize, c) - ascii_first;
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

test {
    std.testing.refAllDecls(@This());
}
