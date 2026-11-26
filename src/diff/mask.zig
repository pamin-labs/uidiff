//! Change mask storage and byte search.
const std = @import("std");

/// The one-byte state of a pixel in a change mask.
pub const Cell = enum(u8) {
    clear,
    changed,
    queued,
    needs_support,
};

/// A change mask over a band: one byte per pixel, row-major. Zero is
/// unchanged and one changed; grouping clears it as it goes.
pub const Mask = struct {
    cells: []Cell,
    /// Columns per row.
    width: usize,
};

/// Finds the next mask state using the standard library's byte search.
pub inline fn nextCell(cells: []const Cell, start: usize, state: Cell) ?usize {
    return std.mem.indexOfScalarPos(u8, std.mem.sliceAsBytes(cells), start, @backingInt(state));
}

test {
    std.testing.refAllDecls(@This());
}
