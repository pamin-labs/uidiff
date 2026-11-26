//! Sheet render-plan and drawing details inspected by scenario assertions.
const std = @import("std");
const annotate = @import("../annotate.zig");
const badges = @import("../annotate/badges.zig");
const copy = @import("../annotate/copy.zig");
const focus = @import("../annotate/focus.zig");
const geometry = @import("../annotate/geometry.zig");
const palette = @import("../annotate/palette.zig");
const placement = @import("../annotate/placement.zig");
const text = @import("../annotate/text.zig");

/// Streams the rows of a planned report.
pub const Rows = annotate.ReportRows;
/// Sheet rectangle in device pixels.
pub const Rect = geometry.Rect;
/// Preview layout for a pair of input sizes.
pub const Layout = geometry.Layout;
/// Minimum short side for the preview of a small screenshot.
pub const min_preview_side = geometry.min_preview_side;
/// Upper bound on the sheet width.
pub const max_sheet_width = geometry.max_sheet_width;
/// Width of a wide overview pane.
pub const overview_width = geometry.overview_width;
/// Space between vertically stacked overview panes.
pub const overview_caption_gap = geometry.overview_caption_gap;
/// Width available to either side of a focus row.
pub const focus_slot_width = focus.focus_slot_width;
/// Label for the before side.
pub const before_caption = copy.before;
/// Background of an annotation sheet.
pub const page = palette.page;
/// Opaque white shared with the canvas fixtures.
pub const white = palette.white;
/// Colour used for a region kind.
pub const tint = palette.tint;
/// Maps a change into a pane.
pub const offsetMark = geometry.offsetMark;
/// Selects the source area for a focus crop.
pub const focusWindow = focus.focusWindow;
/// Paints a numbered badge on one row.
pub const badge = badges.badge;
/// Measures a badge in the overview layout.
pub const overviewDiameter = badges.overviewDiameter;
/// Reads a native bitmap glyph.
pub const glyph = text.glyph;

/// Places a badge alongside a mark inside the given pane.
pub fn badgeBounds(box: ?Rect, pane: Rect, ui: Layout) ?Rect {
    const mark = box orelse return null;
    return placement.place(mark, pane, badges.badgeDiameter(ui), &.{});
}
