//! Recognizes stationary header and footer chrome and intervening spacing.

const std = @import("std");
const band = @import("band.zig");
const anchors = @import("anchors.zig");
const recolour = @import("recolour.zig");
const value = @import("../../value.zig");
const pixel = @import("../pixel.zig");
const columns = @import("../columns.zig");
const Image = value.Image;

/// Fraction of image height reserved for a stationary footer.
// Footer chrome must begin within the last quarter of the image.
pub const footer_zone_divisor = 4;

// A footer edge should cross at least half the image.
const footer_edge_divisor = 2;

// An inset paint stripe that returns to the body within this many rows
// can be an item after a deletion, even close to the bottom of the image.
const max_inset_stripe_rows = 32;

/// Finds the first stationary footer anchor, or the end of the anchor list.
pub fn footerStart(matches_: []const band.Match, before: band.Keys, after: band.Keys, old_background: ?u64, new_background: ?u64, limits: band.Limits) usize {
    const last = for (0..matches_.len) |i| {
        const index = matches_.len - 1 - i;
        if (matches_[index].offset() == 0) break index;
    } else return matches_.len;
    if (!stationaryFooter(before, after, matches_[last].before, old_background, new_background, limits.scroll)) return matches_.len;

    var first = last;
    var next = last;
    while (next > 0) {
        next -= 1;
        const anchor = matches_[next];
        if (anchor.offset() != 0) continue;
        const start = anchor.before + anchor.length;
        const end = matches_[first].before;
        if (end - start > limits.replacement) break;
        first = next;
    }
    // A return to offset zero can be a deletion in the body. Require
    // separate viewport chrome at the boundary before clipping any rows.
    const sample = limits.sample orelse return matches_.len;
    const start = matches_[first].before;
    if (first == 0 or start < before.len - before.len / footer_zone_divisor) return matches_.len;
    const image = sample.pair.before;
    // Chrome begins at a shared horizontal edge. Compare the paint on
    // either side of that edge instead of assuming a single backdrop.
    const shared_width = @min(image.width, sample.pair.after.width);
    var edge: usize = 0;
    for (image.row(start - 1)[0..shared_width], image.row(start)[0..shared_width], sample.pair.after.row(start - 1)[0..shared_width], sample.pair.after.row(start)[0..shared_width]) |above, below, new_above, new_below| {
        edge += @intFromBool(!std.meta.eql(above, below) and !std.meta.eql(new_above, new_below));
    }
    if (sample.columns.width != 0 and columns.closesPanel(image, sample.columns, start)) return first;
    if (insetStripe(before, old_background, image, start)) return matches_.len;
    if (footer_edge_divisor * edge >= shared_width) return first;
    // Clipping can put paint from the moving pane immediately above the
    // fixed edge on one side. Compare the footer with the body's backdrop.
    const background_y = std.mem.indexOfScalar(u64, before, old_background orelse return matches_.len) orelse return matches_.len;
    var changed: usize = 0;
    for (image.row(start), image.row(background_y)) |chrome, body| {
        changed += @intFromBool(!std.meta.eql(chrome, body));
    }
    return if (changed >= image.width / footer_edge_divisor) first else matches_.len;
}

/// Reports whether a short run contains visible foreground paint.
pub fn hasVisibleStripe(keys_: band.Keys, background_key: ?u64, limits: band.Limits, start: usize, count: usize) bool {
    const image = (limits.sample orelse return false).pair.before;
    const background_row = background_key orelse return false;
    for (keys_[start..][0..count], start..) |key, y| {
        if (key != background_row) return insetStripe(keys_, background_row, image, y);
    }
    return false;
}

/// Marks the unmatched bands that consist of a full spacing run.
pub fn markSpacing(bands: []band.Band, keys_: band.Keys, background_key: ?u64, inserted: bool) void {
    const key = background_key orelse return;
    var content = false;
    for (bands) |row_band| {
        const paired = @min(row_band.removed, row_band.added);
        const size = if (inserted) row_band.added else row_band.removed;
        const y = if (inserted) row_band.after else row_band.before;
        if (size > paired and !std.mem.allEqual(u64, keys_[y + paired .. y + size], key)) {
            content = true;
            break;
        }
    }
    if (!content) return;
    for (bands) |*row_band| {
        const size = if (inserted) row_band.added else row_band.removed;
        const other = if (inserted) row_band.removed else row_band.added;
        const y = if (inserted) row_band.after else row_band.before;
        if (other == 0 and size != 0 and std.mem.allEqual(u64, keys_[y .. y + size], key)) row_band.mode = .spacing;
    }
}

/// Checks whether the leading clipped rows are fixed header paint.
pub fn fixedHeaderPadding(limits: band.Limits, start: usize, end: usize) bool {
    const sample = limits.sample orelse return false;
    if (sample.columns.width < 2 or start == 0 or !recolour.flatPaint(sample.pair.before, start, end, sample.columns.left, sample.columns.width)) return false;
    const left = sample.columns.left;
    const right = left + sample.columns.width - 1;
    const header = sample.pair.before.row(start - 1);
    const old = sample.pair.before.row(start);
    const new = sample.pair.after.row(start);
    if (pixel.same(header[left], old[left]) or pixel.same(header[right], old[right])) return false;
    // The stationary header and the unclipped paint meet at the same
    // position on both sides of the moving content.
    return pixel.same(old[left], new[left]) and pixel.same(old[right], new[right]);
}

/// Reports whether a scroll offset persists through the remaining anchors.
pub fn scrollPersists(remaining: []const band.Match, first: usize) bool {
    if (first >= remaining.len) return false;
    const shift = remaining[first].offset();
    for (remaining[first + 1 ..]) |anchor| {
        const offset = anchor.offset();
        if (if (shift > 0) offset < shift else offset > shift) return false;
    }
    return true;
}

fn insetStripe(keys_: band.Keys, background_key: ?u64, image: Image, start: usize) bool {
    const background_y = std.mem.indexOfScalar(u64, keys_, background_key orelse return false) orelse return false;
    const body = image.row(background_y);
    const stripe = image.row(start);
    if (!std.meta.eql(stripe[0], body[0]) or !std.meta.eql(stripe[image.width - 1], body[image.width - 1])) return false;
    const end = @min(keys_.len, start + max_inset_stripe_rows + 1);
    for (keys_[start + 1 .. end]) |key| {
        if (key != keys_[start]) return key == background_key.?;
    }
    return false;
}

fn stationaryFooter(before: band.Keys, after: band.Keys, start: usize, old_background: ?u64, new_background: ?u64, limit: usize) bool {
    if (std.mem.eql(u64, before[start..], after[start..])) return true;
    // A button or label can change inside an otherwise fixed footer.
    // Require a stationary run of content beyond its last changed row.
    var matched: usize = 0;
    var y = before.len;
    while (y > start) {
        y -= 1;
        if (before[y] != after[y]) break;
        if (anchors.isContent(before[y], old_background, new_background)) matched += 1;
    }
    return matched > 2 * limit;
}

test {
    std.testing.refAllDecls(@This());
}
