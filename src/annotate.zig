//! Display-space numbering, label layout and the annotated sheet.
const std = @import("std");
const report_sheet = @import("annotate/report_sheet.zig");

/// An owned side-by-side image of both inputs with their marks.
pub const Sheet = report_sheet.Sheet;
/// Invalid inputs, an oversized sheet, or an allocation failure.
pub const RenderError = report_sheet.RenderError;
/// Row source for the annotated comparison report.
pub const ReportRows = report_sheet.Rows;
/// Minimum dimensions of a styled report before laying out its details.
pub const reportSize = @import("annotate/report_layout.zig").minimumSize;
/// Renders a styled report from regions and aligned row ranges.
pub const renderReport = report_sheet.render;

test {
    std.testing.refAllDecls(report_sheet);
}

test {
    std.testing.refAllDecls(@This());
}
