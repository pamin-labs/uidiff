//! Matched rows, comparison bands, and alignment bounds.

const std = @import("std");
const value = @import("../../value.zig");
const columns = @import("../columns.zig");
const Image = value.Image;

/// A pair of row ranges, with any surplus treated as one-sided.
pub const Band = struct {
    before: usize,
    after: usize,
    removed: usize,
    added: usize,
    /// A verified row-hash run, or the background row for revealed content.
    mode: union(enum) { regular, hash_match, replacement, spacing, element, revealed: usize } = .regular,
};

/// The source pixels available to refine hash-based row alignment.
pub const Sample = struct {
    pair: value.Pair,
    columns: columns.Span,
};

/// Device-pixel limits for identifying small scrolls and replacements.
pub const Limits = struct {
    scroll: usize,
    replacement: usize,
    narrow_edit: bool = false,
    sample: ?Sample = null,
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

/// Hashes each row of the column span. Asserts output.len equals the image
/// height and left + width is at most its width.
pub fn keys(source: Image, left: usize, width: usize, output: []u64) void {
    for (output, 0..) |*key, y| key.* = std.hash.Wyhash.hash(0, source.rowBytes(y, left, width));
}

test "row hashes use the validated stride on one-pixel and final cropped rows" {
    const one = [_]value.Pixel{.{ 21, 22, 23, 255 }};
    var key: [1]u64 = undefined;
    keys(.{ .width = 1, .height = 1, .pixels = &one }, 0, 1, &key);
    try std.testing.expectEqual(std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&one)), key[0]);
    var data: [10]value.Pixel = undefined;
    for (&data, 0..) |*pixel, i| pixel.* = .{ @intCast(i), 0, 0, 255 };
    var hashes: [2]u64 = undefined;
    keys(.{ .width = 5, .height = 2, .pixels = &data }, 2, 3, &hashes);
    try std.testing.expectEqual(std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(data[7..])), hashes[1]);
    try std.testing.expect(hashes[0] != hashes[1]);
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
