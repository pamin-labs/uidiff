//! Builds comparison bands from matching row anchors.

const std = @import("std");
const band = @import("band.zig");
const search = @import("search.zig");
const chrome = @import("chrome.zig");
const recolour = @import("recolour.zig");
const refinement = @import("refinement.zig");

const Anchors = struct {
    rows: []const band.Match,
    footer: usize,
    first_offset: isize,
    background: [2]?u64,
};

// A small re-pairing can be caused by repeated rows inside one stroke.
const min_detour_rows = 8;

const detour_scroll_multiplier = 2;

// A short viewport scroll can move through several rows of blank top padding.
const leading_scroll_multiplier = 4;

/// Writes paired and one-sided comparison bands from verified row anchors.
pub fn assembleBands(before: band.Keys, after: band.Keys, limits: band.Limits, anchors: Anchors, frontier: []search.Diagonal, raw: []band.Match, bands: []band.Band) []band.Band {
    const content = anchors.rows;
    const footer = anchors.footer;
    const first_offset = anchors.first_offset;
    const old_background, const new_background = anchors.background;
    const count = content.len;
    const viewport = before.len == after.len;
    const limit = limits.scroll;
    const replacement_limit = @min(refinement.max_replacement_rows, limits.replacement);
    var len: usize = 0;
    var old_y: usize = 0;
    var new_y: usize = 0;
    var clipped_scroll: usize = 0;
    var i: usize = 0;
    while (i <= count) : (i += 1) {
        if (i != 0 and i + 1 < count and (old_y != new_y or viewport) and
            shortDetour(content[i], old_y, new_y, limit))
        {
            if (replacementEnd(content[i + 1 .. count], old_y, new_y, replacement_limit)) |skip| {
                const next = content[i + 1 + skip];
                const length = next.before - old_y;
                band.append(bands, &len, .{ .before = old_y, .after = new_y, .removed = length, .added = length, .mode = .replacement });
                old_y = next.before;
                new_y = next.after;
                i += skip;
                continue;
            }
        }
        const end = i == count;
        const m = if (end) band.Match{ .before = before.len, .after = after.len, .length = 0 } else content[i];
        const removed = m.before - old_y;
        const added = m.after - new_y;
        const paired = @min(removed, added);
        const shift = @max(removed, added) - paired;
        const under_header = i == 1 and first_offset == 0 and shift <= limit and
            (paired < shift or !std.mem.eql(u64, before[old_y..][0..shift], after[new_y..][0..shift]));
        const blank_leading = viewport and i == 1 and first_offset == 0 and old_y == new_y and
            removed > added and shift <= leading_scroll_multiplier * limit and
            old_y < before.len / chrome.footer_zone_divisor and chrome.scrollPersists(content[0..footer], i) and
            chrome.fixedHeaderPadding(limits, old_y, m.before);
        if (blank_leading) clipped_scroll = shift;
        // A leading scroll remains in the displacement until the viewport
        // ends. A later insertion can add to that displacement.
        const leading = blank_leading or (viewport and (i == 0 and shift <= limit or under_header) and
            chrome.scrollPersists(content[0..footer], i));
        if (removed == added) {
            band.append(bands, &len, .{
                .before = old_y,
                .after = new_y,
                .removed = removed,
                .added = added,
                .mode = if (i != 0 and !end and (old_y != new_y or viewport) and removed <= replacement_limit) .replacement else .regular,
            });
        } else if (viewport and (leading or end or i == footer)) {
            var visible = paired;
            if (!leading and old_y < new_y and !chrome.hasVisibleStripe(before, old_background, limits, old_y, paired)) {
                // Some stationary footer rows share the body's backdrop.
                // They remain stationary even when the first anchor is lower.
                const edge = band.changedEnd(before, after, new_y, m.after);
                visible = @min(visible, edge - new_y);
            }
            band.append(bands, &len, .{
                .before = if (leading) m.before - paired else old_y,
                .after = if (leading) m.after - paired else new_y,
                .removed = visible,
                .added = visible,
            });
            if ((end or i == footer) and added > paired) {
                const start = new_y + paired;
                // A new solid band still counts if its paint differs from the backdrop.
                const flat_tail = clipped_scroll != 0 and old_y -| new_y == clipped_scroll and
                    (after[start] == new_background or after[start] == after[start -| 1]) and
                    if (limits.sample) |sample| recolour.flatPaint(sample.pair.after, start, m.after, sample.columns.left, sample.columns.width) else false;
                if (!flat_tail) reveal(bands, &len, after[0..m.after], old_y + paired, start, new_background);
            }
        } else {
            const first_band = len;
            const problem = search.Problem.init(before[old_y..m.before], after[new_y..m.after]);
            const edits = problem.distance(@min(search.max_edits, problem.a.len + problem.b.len), frontier);
            const gap = if (edits) |found| problem.matches(found, frontier, raw) orelse &.{} else &.{};
            for (gap) |row| {
                const a = m.before - removed + row.before;
                const b = m.after - added + row.after;
                band.append(bands, &len, .{ .before = old_y, .after = new_y, .removed = a - old_y, .added = b - new_y });
                old_y = a + 1;
                new_y = b + 1;
            }
            band.append(bands, &len, .{ .before = old_y, .after = new_y, .removed = m.before - old_y, .added = m.after - new_y });
            if (shift != 0) {
                const inserted = added > removed;
                chrome.markSpacing(bands[first_band..len], if (inserted) after else before, if (inserted) new_background else old_background, inserted);
            }
        }
        // Same-offset matches span any edits between their first and last row.
        band.append(bands, &len, .{ .before = m.before, .after = m.after, .removed = m.length, .added = m.length });
        old_y = m.before + m.length;
        new_y = m.after + m.length;
    }
    return bands[0..len];
}

/// Appends the visible tail uncovered by a viewport scroll.
pub fn reveal(bands: []band.Band, len: *usize, after: band.Keys, before_end: usize, start: usize, key: ?u64) void {
    band.append(bands, len, .{
        .before = before_end,
        .after = start,
        .removed = 0,
        .added = after.len - start,
        .mode = .{ .revealed = if (key) |background_key| std.mem.indexOfScalar(u64, after[0..start], background_key) orelse start -| 1 else start -| 1 },
    });
}

fn shortDetour(next: band.Match, old_y: usize, new_y: usize, limit: usize) bool {
    const removed = next.before - old_y;
    const added = next.after - new_y;
    const displacement = @max(removed, added) - @min(removed, added);
    // A returned displacement can still be a real insertion and deletion.
    // Fold only shifts small enough to be alternate matches for one stroke.
    return displacement != 0 and (old_y != new_y or displacement <= @max(min_detour_rows, detour_scroll_multiplier * limit));
}

// A brief detour through repeated rows can change the alignment's offset
// more than once. Compare the covered rows together if the shift resumes.
fn replacementEnd(anchors: []const band.Match, old_y: usize, new_y: usize, limit: usize) ?usize {
    for (anchors, 0..) |anchor, i| {
        const removed = anchor.before - old_y;
        const added = anchor.after - new_y;
        if (@max(removed, added) > limit) break;
        if (removed == added) return i;
    }
    return null;
}

test "fixed-header scroll reveals content and skips flat paint" {
    const value = @import("../../value.zig");
    const canvas = @import("uidiff_test_canvas").Painters(value.Image);
    const width = 40;
    const height = 120;
    const header = 10;
    const body = 20;
    const scroll = 6;
    const backdrop = canvas.white;
    var old: [height][width]value.Pixel = @splat(@splat(backdrop));
    var new = old;
    for (old[0..header], new[0..header]) |*a, *b| {
        a.* = @splat(.{ 210, 215, 220, 255 });
        b.* = a.*;
    }
    for (old[body..], body..) |*row, y| {
        for (row[4..36]) |*ink| ink.* = .{ @intCast(y), 90, 40, 255 };
    }
    @memcpy(new[body - scroll .. height - scroll], old[body..]);
    const old_pixels = std.mem.bytesAsSlice(value.Pixel, std.mem.asBytes(&old));
    const new_pixels = std.mem.bytesAsSlice(value.Pixel, std.mem.asBytes(&new));
    const original: value.Image = .{ .width = width, .height = height, .pixels = old_pixels };
    const scrolled: value.Image = .{ .width = width, .height = height, .pixels = new_pixels };
    var a: [height]u64 = undefined;
    var b: [height]u64 = undefined;
    band.keys(original, 0, width, &a);
    const matches = [_]band.Match{
        .{ .before = 0, .after = 0, .length = header },
        .{ .before = body, .after = body - scroll, .length = height - body },
    };
    var bands: [2 * height + 1]band.Band = undefined;
    var frontier: [2 * height + 3]search.Diagonal = undefined;
    var raw: [height]band.Match = undefined;
    for ([_]bool{ false, true }) |has_content| {
        if (has_content) for (new[height - scroll ..]) |*row| {
            @memset(row[4..36], .{ 112, 96, 60, 255 });
        };
        band.keys(scrolled, 0, width, &b);
        const result = assembleBands(&a, &b, .{ .scroll = 2, .replacement = 24, .sample = &.{ .pair = .{ .before = original, .after = scrolled }, .columns = .{ .left = 0, .width = width } } }, .{
            .rows = &matches,
            .footer = matches.len,
            .first_offset = 0,
            .background = .{ a[header], b[header] },
        }, &frontier, &raw, &bands);
        try std.testing.expectEqual(@as(usize, if (has_content) 4 else 3), result.len);
        for (result[0..3]) |row_band| try std.testing.expectEqual(row_band.removed, row_band.added);
        try std.testing.expectEqual(@as(usize, scroll), result[2].before - result[2].after);
        if (has_content) {
            try std.testing.expectEqual(@as(usize, height - scroll), result[3].after);
            try std.testing.expectEqual(@as(usize, scroll), result[3].added);
            try std.testing.expect(result[3].mode == .revealed);
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
