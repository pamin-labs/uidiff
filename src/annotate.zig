//! Display-space numbering, label layout and the annotated sheet.
const std = @import("std");
const sheet = @import("annotate/sheet.zig");

/// An owned side-by-side image of both inputs with their marks.
pub const Sheet = sheet.Sheet;
/// Invalid inputs, an oversized sheet, or an allocation failure.
pub const RenderError = sheet.RenderError;
/// Row source for the annotated comparison sheet.
pub const SheetRows = sheet.Rows;
/// Minimum dimensions of a styled sheet before laying out its details.
pub const minimumSheetSize = @import("annotate/plan.zig").minimumSize;
/// Renders a styled sheet from regions and aligned row ranges.
pub const renderSheet = sheet.render;

test {
    std.testing.refAllDecls(sheet);
}

test {
    std.testing.refAllDecls(@This());
}
