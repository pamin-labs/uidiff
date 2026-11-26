//! Colors and labels for the sheet.
const std = @import("std");
const values = @import("../value.zig");
const Pixel = values.Pixel;

/// Sheet background color.
pub const page: Pixel = .{ 244, 244, 245, 255 };

/// Primary caption and title color.
pub const ink: Pixel = .{ 24, 24, 27, 255 };

/// Secondary caption and legend color.
pub const secondary: Pixel = .{ 82, 82, 91, 255 };

/// Absent-side label color.
pub const muted: Pixel = .{ 113, 113, 122, 255 };

/// Neutral crop and pane outline color.
pub const outline_gray: Pixel = .{ 212, 212, 216, 255 };

/// Opaque white for halos and badge glyphs.
pub const white: Pixel = .{ 255, 255, 255, 255 };

/// Gutter color for aligned rows with no displacement.
pub const stationary: Pixel = .{ 228, 228, 231, 255 };

/// Gutter color for the moved row range.
pub const moved_band: Pixel = .{ 196, 215, 245, 255 };

/// Gutter color for inserted or newly visible rows.
pub const insert_band: Pixel = .{ 133, 205, 159, 255 };

/// Gutter color for removed rows.
pub const remove_band: Pixel = .{ 242, 172, 172, 255 };

/// Alignment ribbon caption color.
pub const blue: Pixel = .{ 29, 78, 216, 255 };

/// Returns the legend mask bit for a region kind.
pub fn kindBit(kind: values.Kind) u8 {
    return switch (kind) {
        .inserted => 1,
        .removed => 2,
        else => 4,
    };
}

/// Returns the sheet label for a region kind.
pub fn kindName(kind: values.Kind) []const u8 {
    return switch (kind) {
        .inserted, .removed, .changed => @tagName(kind),
        _ => @tagName(values.Kind.changed),
    };
}

/// Returns the mark color for a region kind.
pub fn tint(kind: values.Kind) Pixel {
    return switch (kind) {
        .inserted => .{ 22, 163, 74, 255 },
        .removed => .{ 220, 38, 38, 255 },
        else => .{ 234, 148, 0, 255 },
    };
}

test {
    std.testing.refAllDecls(@This());
}
