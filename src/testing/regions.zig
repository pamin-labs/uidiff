//! Internal region operations inspected by comparison scenarios.
const std = @import("std");
const regions = @import("../diff/regions.zig");
const logical = @import("../diff/regions/logical.zig");
const moves = @import("../diff/regions/moves.zig");

/// A region before filtering and report numbering.
pub const Candidate = regions.Candidate;
/// Joins edits that belong to a single element.
pub const mergeLogical = logical.mergeLogical;
/// Filters motions against visible edits.
pub const keepMoves = moves.keepMoves;
/// CSS-pixel tolerance for short scrolls.
pub const scroll_shift = moves.scroll_shift;
