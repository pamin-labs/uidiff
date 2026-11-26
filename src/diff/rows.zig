//! Hashes and aligns rows into bands for scrolling and resizing.

const std = @import("std");

const band_model = @import("rows/band.zig");
const search = @import("rows/search.zig");
const foreground = @import("rows/anchors.zig");
const assembly = @import("rows/assembly.zig");
const chrome = @import("rows/chrome.zig");
const insertion = @import("rows/insertion.zig");
const paint = @import("rows/paint.zig");
const refinement = @import("rows/refinement.zig");
const values = @import("../value.zig");
const Image = values.Image;
const Allocator = std.mem.Allocator;

/// A pair of row ranges, with any surplus treated as one-sided.
pub const Band = band_model.Band;
/// Device-pixel limits for identifying small scrolls and replacements.
pub const Limits = band_model.Limits;
/// The most row insertions plus deletions the alignment searches for. Myers'
/// search costs O((rows + max_edits) * max_edits) time, so this bounds a tall
/// unrelated pair; past it, rows are compared by position.
pub const max_edits = search.max_edits;
/// Matches a compact insertion when the rest of the column shifts exactly.
pub const compactInsertion = insertion.compactInsertion;
/// Places a one-sided element at the best boundary among equivalent row matches.
pub const refineElements = refinement.refineElements;

/// Reuses the frontier, row matches, and frequency map across column alignments.
pub const Workspace = struct {
    raw: std.ArrayList(band_model.Match) = .empty,
    content: std.ArrayList(band_model.Match) = .empty,
    frontier: std.ArrayList(search.Diagonal) = .empty,
    frequencies: std.AutoHashMapUnmanaged(u64, usize) = .empty,

    /// Releases all retained alignment buffers.
    pub fn deinit(self: *Workspace, allocator: Allocator) void {
        self.raw.deinit(allocator);
        self.content.deinit(allocator);
        self.frontier.deinit(allocator);
        self.frequencies.deinit(allocator);
        self.* = .{};
    }
};

/// Hashes each row of the column span. Asserts output.len equals the image
/// height and left + width is at most its width.
pub fn keys(source: Image, left: usize, width: usize, output: []u64) void {
    for (output, 0..) |*key, y| key.* = std.hash.Wyhash.hash(0, source.rowBytes(y, left, width));
}

/// Aligns rows into caller-owned bands, or returns null for positional comparison.
pub fn matchBands(allocator: Allocator, before: band_model.Keys, after: band_model.Keys, limits: band_model.Limits, bands: []band_model.Band, filtered: []u64, scratch: *Workspace) Allocator.Error!?[]band_model.Band {
    const limit = limits.scroll;
    const main = search.Problem.init(before, after);
    if (@min(main.a.len, main.b.len) == 0) return null;
    const viewport = before.len == after.len;
    if (viewport and main.prefix != 0) {
        if (paint.positionalPaintBands(before, after, main.prefix, limits, bands)) |aligned| return aligned;
    }
    if (viewport and main.prefix != 0 and limits.images != null) {
        if (insertion.panelInsertion(before, after, main.prefix, limits, bands)) |aligned| return aligned;
        var reversed = limits;
        reversed.images = .{ limits.images.?[1], limits.images.?[0] };
        if (insertion.panelInsertion(after, before, main.prefix, reversed, bands)) |aligned| {
            for (aligned) |*band| {
                std.mem.swap(usize, &band.before, &band.after);
                std.mem.swap(usize, &band.removed, &band.added);
            }
            return aligned;
        }
    }
    const positional = if (viewport)
        paint.localEditCost(before, after, main.prefix, limits)
    else
        null;
    if (viewport and positional == null and main.prefix != 0) {
        if (insertion.clippedInsertion(main, limit, bands)) |aligned| return aligned;
    }
    const overlap = @min(before.len, after.len);
    try scratch.raw.ensureTotalCapacityPrecise(allocator, overlap);
    scratch.raw.items.len = overlap;
    const raw = scratch.raw.items;
    // Both key slices come from validated image heights, which fit u32.
    const budget: usize = @min(search.max_edits, @max(before.len, after.len));
    const counts = &scratch.frequencies;
    counts.clearRetainingCapacity();
    try counts.ensureTotalCapacity(allocator, @intCast(@max(before.len, after.len)));
    const old_background = foreground.background(counts, before);
    var shared: usize = 0;
    for (after) |row| {
        const count = counts.getPtr(row) orelse continue;
        if (count.* == 0) continue;
        count.* -= 1;
        shared += 1;
    }
    if (before.len + after.len - 2 * shared > budget) return null;
    counts.clearRetainingCapacity();
    const new_background = foreground.background(counts, after);

    const frontier_budget: usize = @min(search.max_edits, before.len + after.len);
    try scratch.frontier.ensureTotalCapacityPrecise(allocator, 2 * frontier_budget + 3);
    scratch.frontier.items.len = 2 * frontier_budget + 3;
    const frontier = scratch.frontier.items;
    const distance = main.distance(budget, frontier) orelse return null;
    // A local edit's two-sided cost competes with a motion path plus the
    // penalty for leaving the alignment and returning to it.
    if (positional) |edit| {
        // A local overwrite still has same-position ink below it. A change
        // reaching the end of the column can be an insertion and clipping.
        for (before[edit.end..], after[edit.end..], edit.end..) |old, new, y| {
            if (old == new and foreground.isContent(old, old_background, new_background)) {
                if (limits.images) |images| {
                    if (y >= before.len - before.len / chrome.footer_zone_divisor and paint.flatPaint(images[0], y, y + 1, 0, images[0].width)) break;
                }
                if (edit.cost <= distance + 2 * edit.limit) return null;
                break;
            }
        }
    }
    const equal = main.matches(distance, frontier, raw) orelse return null;
    try scratch.content.ensureTotalCapacityPrecise(allocator, equal.len);
    scratch.content.items.len = equal.len;
    const content = scratch.content.items;

    var content_rows: usize = 0;
    const interior = equal.len != 0 and (equal[equal.len - 1].before != equal.len - 1 or equal[equal.len - 1].after != equal.len - 1);
    var count: usize = 0;
    for (equal) |m| {
        if (!foreground.isContent(before[m.before], old_background, new_background)) continue;
        content_rows += 1;
        foreground.extend(content, &count, m);
    }

    var first_offset = if (count > 0) content[0].offset() else 0;
    if (viewport and first_offset != 0 and @abs(first_offset) <= limit) {
        const skip = @abs(first_offset);
        const old_start = if (first_offset < 0) skip else 0;
        const new_start = if (first_offset > 0) skip else 0;
        const rows = overlap - skip;
        var explained: usize = 0;
        var ambiguous = false;
        for (before[old_start..][0..rows], after[new_start..][0..rows]) |old, new| {
            if (old != new or !foreground.isContent(old, old_background, new_background)) continue;
            explained += 1;
            if (!ambiguous) ambiguous = (counts.get(old) orelse 0) > 1;
        }

        // A short, mostly repeated shift can win Myers' row count by matching
        // background at the expense of content. Check the content-only path
        // before using the shortcut to compare everything at that offset.
        const alternative = if (ambiguous)
            foreground.alignContent(before, after, old_background, new_background, @max(content_rows, explained), frontier, raw, filtered)
        else
            null;
        if (alternative) |matches| {
            count = 0;
            for (matches) |m| foreground.extend(content, &count, m);
            first_offset = content[0].offset();
        } else if (count == 1 and explained >= content_rows) {
            var len: usize = 0;
            band_model.append(bands, &len, .{ .before = old_start, .after = new_start, .removed = rows, .added = rows });
            if (first_offset < 0) assembly.reveal(bands, &len, after, before.len, rows, new_background);
            return bands[0..len];
        }
    }
    for (content[0..count]) |m| {
        if (m.offset() != 0) break;
    } else if (viewport or !interior or equal.len != overlap) return null;

    if (viewport and !foreground.hasDisplacedContent(content[0..count], before, after)) return null;

    var footer = count;
    if (viewport and count >= 2) {
        footer = chrome.footerStart(content[0..count], before, after, old_background, new_background, limits);
        if (footer < count) {
            // Footer edits can break the stationary run into several matches.
            // Compare the entire footer by position, including those edits.
            content[footer].length = before.len - content[footer].before;
            count = footer + 1;
        }

        const after_end = if (footer == count) after.len else content[footer].after;
        const kept = foreground.visibleAnchors(content[0..footer], before, after, after_end, limit);
        if (kept < footer) {
            if (footer < count) {
                content[kept] = content[footer];
                count = kept + 1;
            } else {
                count = kept;
            }
            footer = kept;
        }
    }
    return assembly.assembleBands(before, after, limits, .{
        .rows = content[0..count],
        .footer = footer,
        .first_offset = first_offset,
        .background = .{ old_background, new_background },
    }, frontier, raw, bands);
}

test "a gap can replace every row without losing surrounding anchors" {
    const before = [_]u64{ 1, 2, 10, 3, 4, 5, 6, 7, 8 };
    const replacements = [_][]const u64{ &.{ 20, 21, 22, 11 }, &.{ 20, 21, 22 }, &.{11} };
    var after: [before.len + 3]u64 = undefined;
    var bands: [2 * after.len + 1]band_model.Band = undefined;
    var filtered: [2 * after.len]u64 = undefined;
    for (replacements) |new_rows| {
        const size = before.len + new_rows.len - 1;
        @memcpy(after[0..2], before[0..2]);
        @memcpy(after[2..][0..new_rows.len], new_rows);
        @memcpy(after[2 + new_rows.len .. size], before[3..]);
        var scratch: Workspace = .{};
        defer scratch.deinit(std.testing.allocator);
        const result = try matchBands(std.testing.allocator, &before, after[0..size], .{ .scroll = 2, .replacement = 48 }, &bands, &filtered, &scratch);
        if (new_rows.len == 1) {
            try std.testing.expect(result == null); // Equal-height positional replacement.
            continue;
        }
        const actual = result orelse return error.ExpectedAlignment;
        const expected = [_]band_model.Band{
            .{ .before = 0, .after = 0, .removed = 2, .added = 2 },
            .{ .before = 2, .after = 2, .removed = 1, .added = new_rows.len },
            .{ .before = 3, .after = 2 + new_rows.len, .removed = 6, .added = 6 },
        };
        try std.testing.expectEqualDeep(@as([]const band_model.Band, &expected), @as([]const band_model.Band, actual));
    }
}

test "a two-row alias does not hide a thirty-row scroll through periodic content" {
    const height = 140;
    const period = 28;
    const scroll = 30;
    var page: [height + scroll]u64 = @splat(0);
    for (0..page.len) |y| {
        if (y % period == 0) page[y] = 1;
    }
    for ([_]usize{ 46, 67, 89, 98, 110 }, 2..) |y, marker| page[y] = marker;
    const before = page[0..height];
    const after = page[scroll..];
    var storage: [2 * height + 1]band_model.Band = undefined;
    var filtered: [2 * height]u64 = undefined;
    var scratch: Workspace = .{};
    defer scratch.deinit(std.testing.allocator);
    const bands = (try matchBands(std.testing.allocator, before, after, .{ .scroll = 2, .replacement = 48 }, &storage, &filtered, &scratch)) orelse return error.NoAlignment;
    for (bands) |band| {
        if (band.before == 46 and band.after == 16 and @min(band.removed, band.added) > 0) break;
    } else return error.AnchorMisaligned;
    const revealed = bands[bands.len - 1];
    try std.testing.expectEqual(@as(usize, 0), revealed.removed);
    try std.testing.expectEqual(@as(usize, height), revealed.after + revealed.added);
    try std.testing.expect(revealed.after <= height - scroll);
}

test "row hashes use the validated stride on one-pixel and final cropped rows" {
    const one = [_]values.Pixel{.{ 21, 22, 23, 255 }};
    var key: [1]u64 = undefined;
    keys(.{ .width = 1, .height = 1, .pixels = &one }, 0, 1, &key);
    try std.testing.expectEqual(std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&one)), key[0]);
    var data: [10]values.Pixel = undefined;
    for (&data, 0..) |*pixel, i| pixel.* = .{ @intCast(i), 0, 0, 255 };
    var hashes: [2]u64 = undefined;
    keys(.{ .width = 5, .height = 2, .pixels = &data }, 2, 3, &hashes);
    try std.testing.expectEqual(std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(data[7..])), hashes[1]);
    try std.testing.expect(hashes[0] != hashes[1]);
}

test {
    std.testing.refAllDecls(@This());
}
