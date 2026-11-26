//! Detects insertions followed by exact shifted rows and viewport clipping.

const std = @import("std");
const band_model = @import("band.zig");
const search = @import("search.zig");
const paint = @import("paint.zig");
const columns = @import("../columns.zig");
const values = @import("../../value.zig");

const min_panel_evidence = 4;

/// Maximum row displacement examined for a clipped or compact panel.
pub const max_panel_shift = 512;

const max_panel_candidates = 8;

/// Matches a compact insertion when the rest of the column shifts exactly.
pub fn compactInsertion(before: band_model.Keys, after: band_model.Keys, limit: usize, bands: []band_model.Band) ?[]band_model.Band {
    if (before.len != after.len) return null;
    const problem = search.Problem.init(before, after);
    if (problem.a.len < 2) return null;
    const aligned = clippedInsertion(problem, limit, bands) orelse return null;
    const gap = aligned[1];
    if (std.mem.allEqual(u64, after[gap.after .. gap.after + gap.added], after[after.len - 1])) return null;
    return aligned;
}

/// Detects a shifted list whose tail is clipped by a stationary panel.
// Some panels contain long stretches of repeated paint. Their exact moving
// rows can account for fewer edits than the stationary background in Myers.
pub fn panelInsertion(before: band_model.Keys, after: band_model.Keys, first: usize, limits: band_model.Limits, bands: []band_model.Band) ?[]band_model.Band {
    const image = (limits.images orelse return null)[0];
    const last = band_model.changedEnd(before, after, first, before.len);
    if (last == before.len) return null;
    const end = @min(last, first + max_panel_shift + 1);
    var candidate = first + limits.scroll + 1;
    for (0..max_panel_candidates) |_| {
        if (candidate >= end) return null;
        const start = std.mem.indexOfScalarPos(u64, after[0..end], candidate, before[first]) orelse return null;
        candidate = start + 1;
        const shift = start - first;
        const available = after.len - start;
        const length = std.mem.indexOfDiff(u64, before[first..][0..available], after[start..]) orelse available;
        const edge = start + length;
        if (edge < last or length < shift or edge == after.len) continue;

        // A fixed closing rule explains displaced content falling behind
        // the frame. Without that rule, require the lost tail to be paint.
        const inset: columns.Span = .{ .left = limits.left, .width = limits.width };
        const closed_panel = edge == last and columns.closesRoundedPanel(image, inset, edge, shift);
        if (!closed_panel) {
            if (length < 2 * shift or before[edge - shift - 1] != before[edge - shift] or
                !paint.flatPaint(image, edge - shift, edge, limits.left, limits.width)) continue;
        }
        var moved_rows: usize = 0;
        for (before[first..][0..length], before[start..edge]) |old, stationary| {
            moved_rows += @intFromBool(old != stationary);
            if (moved_rows >= min_panel_evidence) break;
        }
        if (moved_rows < min_panel_evidence) continue;
        bands[0] = .{ .before = 0, .after = 0, .removed = first, .added = first, .mode = .hash_match };
        bands[1] = .{ .before = first, .after = first, .removed = 0, .added = shift, .mode = if (closed_panel) .element else .regular };
        bands[2] = .{ .before = first, .after = start, .removed = length, .added = length, .mode = .hash_match };
        bands[3] = .{ .before = edge, .after = edge, .removed = after.len - edge, .added = after.len - edge, .mode = .hash_match };
        return bands[0..4];
    }
    return null;
}

/// Aligns an inserted band followed by a byte-exact shifted tail.
// A single insertion followed by an exact shifted tail needs no Myers
// frontier. Use the first distinct row as the candidate shift's anchor.
pub fn clippedInsertion(problem: search.Problem, limit: usize, bands: []band_model.Band) ?[]band_model.Band {
    const old = problem.a;
    const new = problem.b;
    const marker = for (old[1..], 1..) |key, y| {
        if (key != old[0]) break y;
    } else return null;
    const at = std.mem.indexOfScalarPos(u64, new, marker + 1, old[marker]) orelse return null;
    const shift = at - marker;
    const budget = @min(search.max_edits, old.len + problem.prefix);
    if (shift <= limit or shift > budget / 2 or !std.mem.eql(u64, old[0 .. old.len - shift], new[shift..])) return null;
    const prefix = problem.prefix;
    bands[0] = .{ .before = 0, .after = 0, .removed = prefix, .added = prefix, .mode = .hash_match };
    bands[1] = .{ .before = prefix, .after = prefix, .removed = 0, .added = shift };
    bands[2] = .{ .before = prefix, .after = prefix + shift, .removed = old.len - shift, .added = old.len - shift, .mode = .hash_match };
    return bands[0..3];
}

test "inserting and deleting above a divider preserves the deletion" {
    const sample = @import("../../testing.zig");
    const width = 96;
    const height = 120;
    const first = 24;
    const pitch = 16;
    const edge = 72;
    const white = sample.white;
    const rule: values.Pixel = .{ 130, 134, 140, 255 };
    var old: [height][width]values.Pixel = @splat(@splat(white));
    var new = old;
    for (old[first..edge], first..) |*row, y| {
        @memset(row[24..72], .{ @intCast(y), 90, 40, 255 });
    }
    @memcpy(new[first + pitch .. edge], old[first .. edge - pitch]);
    for (new[first .. first + pitch]) |*row| @memset(row[24..72], .{ 224, 36, 80, 255 });
    for ([_]*[height][width]values.Pixel{ &old, &new }) |pixels| {
        @memset(pixels[edge][20..76], rule);
        for (edge - pitch / 2..edge - pitch / 2 + 2) |y| {
            pixels[y][12] = rule;
            pixels[y][83] = rule;
        }
    }
    const a: values.Image = .{ .width = width, .height = height, .pixels = std.mem.bytesAsSlice(values.Pixel, std.mem.asBytes(&old)) };
    const b: values.Image = .{ .width = width, .height = height, .pixels = std.mem.bytesAsSlice(values.Pixel, std.mem.asBytes(&new)) };
    const limits: band_model.Limits = .{ .scroll = 2, .replacement = 24, .images = .{ a, b }, .left = 24, .width = 48 };
    var before: [height]u64 = undefined;
    var after: [height]u64 = undefined;
    sample.rowKeys(a, limits.left, limits.width, &before);
    sample.rowKeys(b, limits.left, limits.width, &after);
    var bands: [2 * height + 1]band_model.Band = undefined;
    try std.testing.expect(panelInsertion(&before, &after, first, limits, &bands) == null);
    var workspace: sample.RowWorkspace = .{};
    defer workspace.deinit(std.testing.allocator);
    var filtered: [2 * height]u64 = undefined;
    const aligned = (try sample.matchBands(std.testing.allocator, &before, &after, limits, &bands, &filtered, &workspace)) orelse return error.TestUnexpectedResult;
    var removed: usize = 0;
    var added: usize = 0;
    for (aligned) |band| {
        removed += band.removed -| band.added;
        added += band.added -| band.removed;
    }
    try std.testing.expectEqual(@as(usize, pitch), removed);
    try std.testing.expectEqual(@as(usize, pitch), added);
}

test {
    std.testing.refAllDecls(@This());
}
