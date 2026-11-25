//! Matched rows, comparison bands, and alignment bounds.

const std = @import("std");
const values = @import("../../value.zig");
const Image = values.Image;

/// A pair of row ranges, with any surplus treated as one-sided.
pub const Band = struct {
    before: usize,
    after: usize,
    removed: usize,
    added: usize,
    /// A verified row-hash run, or the background row for revealed content.
    mode: union(enum) { regular, hash_match, replacement, spacing, element, revealed: usize } = .regular,
};

/// Device-pixel limits for identifying small scrolls and replacements.
pub const Limits = struct {
    scroll: usize,
    replacement: usize,
    narrow_edit: bool = false,
    images: ?[2]Image = null,
    left: usize = 0,
    width: usize = 0,
};

/// One run of exactly matched row keys.
pub const Match = struct {
    before: usize,
    after: usize,
    length: usize = 1,

    /// Gives the signed after-to-before displacement of the run.
    pub fn offset(self: Match) isize {
        return @as(isize, @intCast(self.after)) - @as(isize, @intCast(self.before));
    }
};

/// Borrowed row hashes in image order.
pub const Keys = []const u64;

/// Appends a non-empty row band into caller-provided storage.
pub fn append(bands: []Band, len: *usize, band: Band) void {
    if (band.removed == 0 and band.added == 0) return;
    // Each nonempty band consumes at least one distinct row across the two inputs.
    bands[len.*] = band;
    len.* += 1;
}

/// Finds the exclusive end after skipping stationary keys in the supplied range.
pub fn changedEnd(before: Keys, after: Keys, first: usize, limit: usize) usize {
    var end = limit;
    while (end > first and before[end - 1] == after[end - 1]) end -= 1;
    return end;
}

test "trailing equal keys do not consume rows below the search floor" {
    const before = [_]u64{ 2, 4, 6, 8 };
    const after = [_]u64{ 3, 4, 6, 8 };
    try std.testing.expectEqual(@as(usize, 1), changedEnd(&before, &after, 0, 4));
    try std.testing.expectEqual(@as(usize, 2), changedEnd(&before, &after, 2, 4));
    try std.testing.expectEqual(@as(usize, 4), changedEnd(&before, &after, 4, 4));
}

test {
    std.testing.refAllDecls(@This());
}
