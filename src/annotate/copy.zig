//! Labels and format strings of the styled comparison sheet.
/// Caption of the source pane.
pub const before = "Before";
/// Caption of the comparison pane.
pub const after = "After";
/// Verb used in the heading for displaced content.
pub const moved = "moved";
/// Detail caption when one source has no box.
pub const not_on_side = "not on this side";
/// Heading of the side-by-side detail area.
pub const detail_section_title = "Changes up close";
/// Heading above stacked panoramic focus rows.
pub const at_full_size = "Each change at full size";
/// Singular noun after the region count.
pub const change = "change";
/// Plural noun after the region count.
pub const changes = "changes";
/// Singular noun after the move count.
pub const block = "block";
/// Plural noun after the move count.
pub const blocks = "blocks";
/// Suffix for moves that all advance in the image.
pub const down = " down";
/// Suffix for moves that all move toward the top.
pub const up = " up";
/// Formats a region number for a badge.
pub const number_format = "{d}";
/// Formats the pane name when a focus crop is absent.
pub const name_format = "{s}";
/// Includes the source column range in an unscaled focus caption.
pub const focus_format = "{s} | x {d}-{d}";
/// Includes the source column range and resize percentage.
pub const scaled_focus_format = "{s} | x {d}-{d} scaled {d}%";
/// Prints a displacement with an explicit positive sign.
pub const positive_shift_format = "+{d} px";
/// Prints a displacement in source device pixels.
pub const shift_format = "{d} px";
/// Prints the region count when there are no moves.
pub const heading_format = "{d} {s}";
/// Prints region and move counts with an optional direction.
pub const moved_heading_format = "{d} {s}, {d} {s} " ++ moved ++ "{s}";
