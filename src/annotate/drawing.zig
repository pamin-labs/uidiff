//! Row painting, typography, colors and labels for the sheet.
const std = @import("std");

/// Paints primitives and glyphs into one output row.
pub const canvas = @import("drawing/canvas.zig");
/// Built-in labels and format strings.
pub const copy = @import("drawing/copy.zig");
/// Colors and labels for change kinds.
pub const palette = @import("drawing/palette.zig");
/// Bitmap glyphs and the metrics used to place them.
pub const text = @import("drawing/text.zig");

test {
    std.testing.refAllDecls(@This());
}
